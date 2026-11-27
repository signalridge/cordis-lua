# cordis-lua core API

Status: **1.0** public API contract (shapes and names); optional host, lifecycle, and introspection extensions (`root:close()`, `host.capture()`, cancellable `TaskHandle`, `internal/provide`, `EventsService:resolve` / `:listeners` / `:listenerCount`, `fiber.error`, `fiber:pending()`, `ReflectService:getImpl`) are documented in place and tracked in [deviations.md](deviations.md#extensions).

Upstream: `cordiverse/cordis` `packages/core` at the commit in [`UPSTREAM`](../UPSTREAM). Names
and semantics follow upstream; the Lua shape of each construct follows the
language-level deviations ([deviations.md](deviations.md)). This file is the contract for code built
on core (`timer`, `loader`, and embedders).

```lua
local cordis = require("cordis")
```

## 0. Conventions

- **Methods are colon calls**: `ctx:on(...)`, `ctx.reflect:provide(...)`,
  `fiber:update(...)`, `logger:info(...)`. Methods reached through `ctx`
  (mixins, traced services) discard the receiver you pass and substitute the
  right one, so `ctx:foo()` and `ctx.svc:bar()` always work. Callable services
  are dot-called: `ctx.logger("name")`.
- **Promise → Future**: every upstream method that returns a Promise
  returns a `cordis.Future` at once. Blocking happens only when awaiting an
  unsettled Future in `future:await()` / `cordis.await(x)` (or calling
  `cordis.tick(host)`), which requires a host task. Reading an already-settled
  Future or awaiting a plain value returns at once.
- **null**: Lua has one empty value. Where upstream distinguishes `null`
  from `undefined`, the null side is the sentinel `cordis.null`.
  `cordis.isNullable(v)` is `v == nil or v == cordis.null`.
- **Symbols**: `cordis.symbol(description)` returns a fresh unique table;
  `cordis.symbolFor(key)` returns the per-Lua-state registered one
  (`Symbol.for`). Symbols are valid event names, table keys and isolate labels.
  `cordis.isSymbol(x)`.
- **Errors**: most errors raised by the library are tables
  `{ name, message, traceback, code?, cause?, errors?, issues? }` with
  `__tostring` returning `name .. ": " .. message`. `cordis.Error.new(message)`
  makes one; `cordis.Error.is(x)`. A few precondition assertions (such as
  missing `options.host` in `Context.new` or no host in `cordis.async`) raise
  plain Lua strings. User code may raise any value.

## 1. Host and async primitives

```lua
---@class cordis.Host
---@field spawn fun(fn: fun())     -- run fn as an independent task (eager or deferred)
---@field latch fun(): cordis.Latch
---@field sleep? fun(ms: number, latch?: cordis.Latch)   -- block the current task; required by timer.
---                                -- Optional: with `latch`, also return as soon as it opens (a cleared timer
---                                -- then wakes at once); a host may ignore it (the timer checks a flag)
---@field now? fun(): number       -- monotonic ms; required by timer; logger uses it when present (else os.time() * 1000, or 0 without os.time)
---@field capture? fun(): cordis.Scope  -- capture: the running code's execution context

---@class cordis.Scope
---@field run fun(fn: function, ...): ...  -- call fn now in the captured context; the caller waits
---@field spawn fun(fn: fun()): cordis.TaskHandle?  -- start fn as a task in the captured context;
---                                -- cancellable task: optionally return a handle that can cancel it

---@class cordis.TaskHandle  -- optional cancellable task
---@field cancel fun()          -- stop the task where it is suspended; its to-be-closed values close

---@class cordis.Latch
---@field open fun(self)           -- idempotent; never resumes waiters inline
---@field wait fun(self)           -- block current task until open; returns at once if open
```

Host contract: `spawn` may run `fn` immediately up to its first block or
later; `latch:open()` may be called outside tasks and must not resume waiters
synchronously. The library never creates or resumes coroutines itself.

Execution contexts (see [deviations.md](deviations.md#extensions)). A host whose tasks
carry an execution context (who the work acts for, what it may do) offers
`capture`. The library captures the context when a user hands it
a callback and runs the callback in that context, rather than in the context of
whoever triggers it:

| callback | captured at | runs through |
|---|---|---|
| listener of `emit` / `bail` / `waterfall` / `serial` | `ctx:on` / `ctx:once` | `scope.run` on the calling task (can be a drainer for events like `internal/status` or later `serial` steps) |
| listener of `parallel` | `ctx:on` / `ctx:once` | `scope.spawn` (one task per listener with a captured scope) |
| component (`apply`, class constructor, `[Service.init]`) and the effect shapes it returns | `ctx:use` / `ctx:inject` | `scope.spawn` from the job queue |
| disposer returned to `ctx:effect` (sync or async) | `ctx:effect` call | `scope.run` outside a drainer, `scope.spawn` from a drainer |
| disposer returned by a component | `ctx:use` / `ctx:inject` | `scope.run` outside a drainer, `scope.spawn` from a drainer |
| `future:next` / `catch` / `finally` handler | the `next` / `catch` / `finally` call | `scope.spawn` from the job queue |
| `cordis.async` body, `cordis.asyncIter` body, timer tasks (`timeout`, `interval`, `debounce`) | the call / effect / scheduling (or `debounce` creation) | `scope.spawn` (errors raised synchronously during timer callback invocation log to `ctx.logger("timer")`) |
| `throttle` trailing call | timer task scheduled in the triggering call's scope; callback captured at `ctx:throttle` creation | timer task via `spawn`; callback runs inside it via `scope.run` in the creation scope (errors raised synchronously during invocation log to `ctx.logger("timer")`) |
| `throttle` leading call | `ctx:throttle` creation | `scope.run` synchronously (errors propagate directly to the caller, not `ctx.logger("timer")`) |
| provider `check(value)` predicate and logger exporter (`export`) | `ctx:provide` / `ctx.logger:exporter` | `scope.run` synchronously on the notifying or logging task (errors are caught) |

With `capture`, queued user callbacks (components, queued disposers, Future
reactions, and `parallel` listeners) run in their own spawned tasks instead of
blocking the job-queue drainer. Synchronous dispatches (`emit`, `bail`,
`waterfall`, and `serial` steps) still invoke listeners via `scope.run` on the
calling task, so `cordis.future.inDrainer()` can be true inside a listener
triggered from the job queue (for example `internal/status` or a later `serial`
listener). Raw `host.spawn` starts library-internal tasks in the host's root
context, while `Context` exposes a facade (`ctx.host`) whose `spawn` routes
through `capture().spawn`. By contrast, `Future:host()` returns the exact host
object passed when the `Future` was constructed, so pass `ctx.host` (not the raw
host) when creating a `Future` handed to plugin code. Without `capture`,
`cordis.async`, `cordis.asyncIter`, and timer tasks still call `spawn`; all
other callbacks run inline.

Reference host (tests, standalone programs):

```text
local sched = require("cordis.host.coroutine").new({ eager = false, auto = true })
sched.host            -- cordis.Host with virtual-time sleep / now
sched.run()           -- run until idle (auto = true: idle jumps to the next timer)
sched.advance(ms)     -- vi.advanceTimersByTimeAsync(ms); callable inside or outside a task
sched.runAll()        -- vi.runAllTimersAsync()
sched.setTimeout(fn, ms) -> cancel   -- plain callback timer on virtual time
sched.drive(fn) -> ok, err           -- spawn fn, run, report stall (other task errors in sched.errors)
```

Future (`cordis.Future`, module `cordis.future`):

| JS | Lua |
|---|---|
| `new Promise(executor)` | `Future.new(host, function(resolve, reject) ... end)` |
| `Promise.withResolvers()` | `local f, resolve, reject = Future.withResolvers(host)` |
| `Promise.resolve(v)` / `reject(r)` | `Future.resolve(host, v)` / `Future.reject(host, r)` |
| `p.then(f, g)` / `catch` / `finally` | `p:next(f, g)` / `p:catch(g)` / `p:finally(h)` |
| `await p` | `p:await()` (settled → returns at once; rejected → `error(reason, 0)`) |
| `await x` (maybe not a promise) | `cordis.await(x)` (Futures, fibers (`use` result) and effect disposers are awaitable) |
| `await Promise.resolve()` | `cordis.tick(host)` (yields once through the job queue, on eager hosts too) |
| `async function f` | `local f = cordis.async(function(...) ... end)` (see below) |
| `Promise.all` / `allSettled` | `Future.all(host, list)` / `Future.allSettled(host, list)` |
| `queueMicrotask` | `cordis.future.queueMicrotask(host, fn)` |
| (Lua only) | `Future.is(x)`, `p:state()` (`"pending"`, `"fulfilled"`, or `"rejected"`) |

Reactions run on a per-host job queue (never synchronously in `resolve`). A
job that raises is reported as an uncaught error of its own host task; the queue
keeps running. A job that blocks through `future:await()` / `cordis.tick` hands
its queue to a new drainer, whichever host the awaited Future belongs to.

Thenables: fibers (`use()` / `inject()` results) and effect disposers carry a
`__future` metamethod. Future adoption (`resolve(x)`, a `next` handler
returning `x`, `Future.resolve`, `Future.all` / `allSettled`, listener results
of `parallel` / `serial`) waits for them as upstream's Promise adoption waits
for thenables: a fiber settles with itself once any in-flight load or unload
finishes (or rejects with its load error; a `PENDING` fiber with missing
dependencies and no in-flight work settles on a queue turn without waiting for
the missing dependency and without running `apply`); a disposer settles with a
plain disposer function once its setup finishes.

`cordis.async(fn)` returns a callable *AsyncFunction*. Calling it spawns `fn`
in a new host task and returns a Future of its result. The host is taken from
the calling task (tasks started by the library, or the test runner, know their
host) or else from the first Context / Future argument. The library, when it
calls an AsyncFunction it was handed (component, listener, disposer, effect),
always passes its own host. A Context argument (root, derived, isolated or
traced) gives its `host`.

`cordis.async` has **no synchronous prefix**: depending on the host, `fn` starts
before or after the call returns (a host built on a spawn that always defers, such as tokio's `spawn_local`, starts it later).
Upstream code that runs before the first `await` of an async callback must stay
synchronous in Lua: write the callback as a plain function that does that part
and then returns a Future (for instance `cordis.async(rest)(ctx)`). This keeps the
causal order of a dispatch: an async listener that removes a later listener
before its first `await` does so before that listener is reached.

```lua
ctx:use(cordis.async(function(ctx, config)
  ctx.host.sleep(100)            -- blocks this task only
end))

ctx:on("event", function()
  disposeOther()                 -- upstream: before the first `await`
  return cordis.async(function(c)
    c.host.sleep(10)             -- upstream: after it (pass ctx so host is known from any task)
  end)(ctx)
end)
```

## 2. Object model helpers

Contexts and the isolate / intercept / inject tables are *JS-like objects*:
proxies with own keys in insertion order and a prototype link. Read
and write them with ordinary indexing; inspect them only through `cordis.proto`
(`rawget`, `next`, `pairs` see an empty table).

```text
local proto = cordis.proto
proto.create(parent?, own?)          -- Object.create(parent) (+ Object.assign(own))
proto.getPrototypeOf(o)              -- nil at the top
proto.setPrototypeOf(o, parent)      -- plain proto objects and derived contexts only (asserts on root Context proxies; rejects cycles)
proto.hasOwn(o, k)                   -- Object.hasOwn
proto.has(o, k)                      -- `k in o` (walks prototypes; contexts: Context.has)
proto.ownKeys(o)                     -- own keys, insertion order (Reflect.ownKeys)
proto.keys(o)                        -- for..in order: own keys first, then up the chain, deduplicated
proto.delete(o, k)                   -- delete o[k] (own only)
proto.is(o)
```

Classes:

```text
local Foo = cordis.class("Foo", Parent?)   -- Foo.name == "Foo", Foo.super == Parent
function Foo:constructor(ctx, config) Foo.super.constructor(self, ctx, "foo") end
function Foo:method() end
Foo.__get.size = function(self) return #self.items end        -- getter
Foo.__set.size = function(self, v) end                        -- setter
local foo = Foo.new(ctx, config)       -- constructor may return a replacement object
Foo.is(x)                              -- instanceof (walks the class chain)
cordis.class.is(x)                     -- x is a class table (isConstructor)
```

Methods, statics, getters, setters and metamethods (`__call`, `__tostring`, ...)
are inherited. Statics are visible from instances (`foo.inject` reads
`Foo.inject`); instance fields shadow them.

Other utilities: `cordis.DisposableList` (`push`/`unshift` → disposer,
`delete`, `clear` → values, `length()`, `values()`, `pairs()`),
`cordis.ordered.Map` / `Set`, `cordis.symbols` (the internal symbol table of
upstream `utils.ts`), `cordis.composeError(fn, getOuterStack)`,
`cordis.buildOuterStack(offset?)`, `cordis.isBailed(v)` (`v ~= nil and v ~= false and v ~= cordis.null`).

## 3. Context

```text
local root = cordis.Context.new({ host = host })  -- host is required
root.host                                       -- the cordis.Host facade
cordis.Context.is(x)
cordis.Context.has(ctx, name)                   -- `name in ctx`
cordis.Context.root / .effect / .filter / .isolate / .intercept   -- symbols
```

| Upstream | Lua |
|---|---|
| `ctx.extend(meta)` | `ctx:extend(meta?)` (meta keys, strings or symbols, become own properties) |
| `ctx.isolate(name, label?)` | `ctx:isolate(name, label?)` |
| `ctx.intercept(name, config)` | `ctx:intercept(name, config)` |
| `ctx[Context.isolate]` | `ctx[cordis.Context.isolate]` (proto object `name → symbol` whose prototype chain is the parent's table) |
| `ctx[Context.intercept]` | same shape, `name → config` |
| `ctx[Context.root]` | the root context |
| `util.inspect(ctx)` | `tostring(ctx)` → `Context <fiber-name>` |
| (Lua only) | `root:close()` → Future: terminal close of the root tree; checks `self.fiber.runtime == nil`, so `root:extend():close()` (or any derived context sharing the root fiber) also closes the root tree; repeated calls (including re-entrant calls from a synchronous `internal/status` listener during the first close) return the same Future; afterwards every registration on it raises |

Built-in properties: `ctx.fiber`, `ctx.reflect`, `ctx.registry`, `ctx.events`,
`ctx.logger`, `ctx.host`, `ctx.runtime` (mixin of `fiber.runtime`).

Mixed-in methods (`reflect.ts:182-185`): `ctx:get ctx:set ctx:provide
ctx:accessor ctx:mixin ctx:effect ctx:inject ctx:use ctx:plugin ctx:on
ctx:once ctx:parallel ctx:emit ctx:serial ctx:bail ctx:waterfall`.

Property access follows `reflect.ts:104-175`: names that are symbols, numeric
strings or start with `_` bypass the service machinery (Lua drops the JS
reserved words `then` / `prototype`). Reading an unknown service name from a
plugin context (a context whose def site has a `fiber.runtime`) raises
`cannot get property "x" without inject`; reading from a fiber-less root
context (or a derived context whose def site is root) bypasses the inject check
and returns the service value or `nil`. Assignment to an undeclared name from a
plugin context raises `cannot set property "x" without provide` (root writes
emit `internal/provide` and assign directly).

## 4. Effects and fibers

```text
local dispose = ctx:effect(execute, label?)
```

`execute()` may return:

| Upstream | Lua |
|---|---|
| disposer function | function or callable table |
| `undefined` | nil |
| `Promise<Disposable>` | Future of a disposer (or `cordis.async` execute) |
| `function*` (sync generator) | `cordis.iter(function(yield, ...) yield(d1) ... end)`: `cordis.iter(fn)` returns a function; calling it with `...` makes the iterable, so it also serves as a method (`Foo[Service.init] = cordis.iter(function(yield, self) ... end)`) |
| `async function*` | `cordis.asyncIter(function(yield, ...) yield(d1) ... end)` (same calling shape): runs in a host task; stops when the effect is disposed (the next `yield` raises a private abort that unwinds the body; use `pcall`-free cleanup or a `<close>` variable for finally blocks) |

`dispose` is a callable table (`EffectDisposer`): `dispose()` returns a Future
or nil; `dispose:await()` (= `await dispose` upstream) blocks until setup
finishes and returns a plain disposer function; `dispose[cordis.Context.effect]`
is the `EffectMeta` `{ label, children }`.

`cordis.FiberState`: `PENDING = 0, LOADING = 1, ACTIVE = 2, FAILED = 3,
DISPOSED = 4, UNLOADING = 5`. `cordis.CordisError` (`code`, `CordisError.Code`).

Fiber fields: `uid` (nil once disposed), `ctx`, `parent`, `state`, `config`,
`inject` (proto object, see §6), `runtime`, `committed` (name → impl or nil),
`provisions` (`ordered.Set` of impls), `inertia` (Future or nil), `name`
(read-only getter), `error` (read-only getter; the failure value while `FAILED`,
cleared on `update` / `replace`, nil otherwise).

Diagnostics for a host (`/plugins`-style listings, health checks) use the
fields, methods, and internal events below:

| question | answer |
|---|---|
| state changes | `ctx:on("internal/status", function(fiber, oldState) end)`; `fiber.state` |
| which plugin | `fiber.name`, `fiber.runtime` (`name`, `callback`, `Config`), `fiber.uid` |
| which services a PENDING fiber still waits for | `fiber:pending()` → fresh array of names from `fiber.inject` (in declaration order) without an admitted impl |
| which effects a fiber holds | `fiber:getEffects()` → `{ label, children }` per effect, in registration order |
| why it failed | `fiber.state == FAILED`; `fiber.error` holds the failure value (also sent to `ctx.logger`, and raised by `cordis.await(fiber:await())`) |
| which services it provides | `fiber.provisions` (impls with `name`, `uid`, `dependents`) |

| Upstream | Lua |
|---|---|
| `fiber.dispose()` | `fiber:dispose()` → Future or nil |
| `fiber.await()` | `fiber:await()` → Future of the fiber (waits for in-flight `inertia`, rejects with load error) |
| `await ctx.use(x)` | `cordis.await(ctx:use(x))` → fiber, or raises |
| `fiber.restart()` | `fiber:restart()` → Future |
| `fiber.update(config, noSave)` | `fiber:update(config, noSave?)` → Future, or nil when an `internal/update` listener vetoed the restart |
| `fiber.effect` / `leak` / `getEffects` / `assertActive` | `fiber:effect(...)` / `fiber:leak(dispose)` / `fiber:getEffects()` / `fiber:assertActive()` |
| (Lua only) | `fiber.error` (read-only getter) / `fiber:pending()` → array of missing inject names |

Upstream lifecycle fixes adopted in `cordis-lua` ([deviations.md](deviations.md#fix-type-deviations)):
the effect wrapper is registered before `execute` runs; `fiber:assertActive()`
checks only `uid ~= nil`, while `fiber:effect()` additionally rejects new
effects when `state == UNLOADING`; a child fiber gets its `dispose` before
`internal/plugin` is emitted; observers of the dispose-path `internal/plugin`
emission are isolated from one another.

## 5. Events

`ctx:emit / bail / waterfall` are synchronous; `ctx:parallel / serial` return
Futures. An optional first argument that is a table or function (and not a
symbol or `cordis.null`) is the `thisArg`; listeners then receive `(thisArg, ...)`, otherwise
`(...)`. The `thisArg`'s `[cordis.Context.filter]` method filters hooks (unless a
listener was registered with `{ global = true }`).

```text
ctx:on(name, listener, options?)   -- options: true (= prepend) or { prepend, global }
ctx:once(name, listener, options?)
ctx.events:resolve(mode, [thisArg,] name, ...) -> thisArg, hooks, name, args
ctx.events:listeners(name) -> hooks          -- fresh array copy in dispatch order
ctx.events:listenerCount(name) -> integer    -- zero-allocation live listener count
```

Each hook record returned by `resolve` / `listeners` has shape
`{ ctx, callback, prepend?, global?, scope?, removed? }` (`scope` is the
captured `cordis.Scope` when `host.capture` is present; `removed` is set to
`true` once unregistered). `resolve` follows the same `[thisArg,] name, ...`
convention as built-in dispatch methods, emits `internal/dispatch` for
non-`internal/*` events, applies `thisArg[Context.filter]` when present, and
returns an independent `hooks` array copy plus packed `args` (`table.pack`).

Internal events, with listener parameters in Lua:

| event | dispatch | listener |
|---|---|---|
| `internal/plugin` | emit | `(fiber)` |
| `internal/replace` | emit | `(fiber)` |
| `internal/status` | emit | `(fiber, oldState)` |
| `internal/service` | emit with thisArg | `(ctx, name, value)` |
| `internal/provide` | emit with thisArg | `(ctx, name, value)` before registration; a listener error aborts the provide |
| `internal/update` | waterfall with thisArg | `(fiber, resolvedConfig, next)` (per-fiber unless `{ global = true }`) |
| `internal/config` | waterfall | `(fiber, next)` |
| `internal/get` | waterfall | `(ctx, name, error, next)` |
| `internal/set` | waterfall | `(ctx, name, value, error, next)` |
| `internal/listener` | bail with thisArg | `(ctx, name, listener, options)` |
| `internal/dispatch` | emit | `(mode, name, args, thisArg)` |

`waterfall`'s `next()` raises `next() called multiple times` on reuse (any
extra arguments passed to `next` are ignored).
`parallel` resolves to `nil` when every listener settles. If one or more
listeners throw or reject, it rejects with an `AggregateError` (`errors` field)
labelled `one or more listeners of event "x" failed`; if dispatch resolution
itself fails (for example a throwing `[cordis.Context.filter]`), it rejects
directly with the original error reason.
`serial` awaits listeners in sequence and resolves with the first result passing
`cordis.isBailed(v)` (skipping later listeners), or `nil` if none bail.

## 6. Services, reflect, registry

```text
ctx:provide(name, value?, check?) -> dispose     -- check(value) -> boolean (reflect.ts:213)
ctx:get(name, strict?)                           -- strict defaults to true
ctx:set(name, value)
ctx:accessor(name, { get = function(ctx, receiver, error) end, set = function(ctx, value, receiver, error) end })
ctx:mixin(source, { "a", "b" } | { sourceField = "exposedAlias" })  -- source: service name or symbol (table follows JS key coercion)
ctx.reflect.props      -- name -> { type = "service" | "accessor", ... }
ctx.reflect.store      -- isolate symbol -> impl { uid, name, ctx, value, check, isolate, dependents, release }
ctx.reflect:provide(name, value, check) / :get / :getImpl(name, strict?) / :set / :notify(names, filter?) / :accessor / :mixin / :trace(v) / :bind(fn)
cordis.locate(ctx, name)  -- reflect.ts:83 -> { fiber?, impl? } or nil
```

`ctx.reflect:getImpl(name, strict?)` looks up the registered `impl` record in
`ctx`'s isolation slot for `name` (or `nil`). Like `get`, `strict` defaults to
`true` (returns `nil` unless `impl.ctx.fiber.state == FiberState.ACTIVE`);
passing `strict = false` returns any registered provision regardless of state
or `impl.value == nil`, enabling occupancy (`getImpl(name, false) ~= nil`) and
provider-ownership (`impl.ctx.fiber == ctx.fiber`) checks.

`Service`:

```lua
local Foo = cordis.class("Foo", cordis.Service)
Foo.inject = { "bar" }                 -- or { bar = config }
function Foo:constructor(ctx, config)
  Foo.super.constructor(self, ctx, "foo")   -- name defaults to Foo.provide
end
Foo[cordis.Service.init] = function(self) end          -- may return Future / AsyncFunction result
Foo[cordis.Service.check] = function(self) return true end
Foo[cordis.Service.invoke] = function(self, ...) end    -- makes instances callable: ctx.foo(...)
-- also Service.tracker, .metadata, .extend, .mergeIntercept, .resolveIntercept, .filter
-- cordis.Service.is(x) checks instanceof Service (or a subclass: Foo.is(x))
```

Registry:

```text
ctx:use(component, config?, options?) -> fiber -- awaitable with cordis.await; options: { getOuterStack?, config?, commit?, dispose? }
ctx:inject(deps, callback) -> fiber            -- deps: { "a", "b" } | { a = config }
ctx:plugin(...)                                -- deprecated alias of use
ctx.registry:use(component, config?, options?)
ctx.registry:get(c) / :has(c) / :resolve(c) / :replace(old, new)
ctx.registry:keys() / :values() / :entries() / :forEach(cb) / registry.size (getter)
cordis.Inject.resolve(inject, result?) -> proto object name -> config | cordis.null (key order kept)
cordis.Inject(Class, name, config?)            -- @Inject on a class
cordis.Inject.method(Class, methodName, deps)  -- @Inject on a method (any class; repeated
                                               -- declarations on one method merge their deps)
```

Component forms: a function or callable table `(ctx, config)`; a table with
`apply(ctx, config)` (dot-called, registered by its `apply`); a class from
`cordis.class` (instantiated with `require("cordis.class").construct(Class, ctx, config)`
so a class may define an ordinary `new` method, registered by the class table).
Static metadata on the component: `name`, `Config`, `inject`, `provide`,
`intercept`.

`runtime`: `{ name, callback, fibers = DisposableList, Config }`.

Config validation is Standard Schema: `Config["~standard"].validate(value)`
returns `{ value = v }` or `{ issues = { { message, path? }, ... } }`;
failures raise `cordis.ValidationError` (`issues`, `ValidationError.is`,
`ValidationError.normalizePath(path)`, `ValidationError.formatPath(path)`).
`cordis.resolveConfig(runtime, config)`.

## 7. Logger

```text
local logger = ctx.logger("name")     -- name defaults to intercept name, then hyphenated fiber name
logger:info(fmt, ...)  logger:warn  logger:error  logger:debug
ctx.logger:info(...)                  -- shorthand of ctx.logger():info(...)
ctx.logger:exporter({ export = function(message) end, levels = {}, colors = 0|1|2|3, maxLength, formatters = {} }) -> dispose
cordis.Logger.format(exporter, message) / .color(exporter, code, value, decoration?) / .code(name, colors)
cordis.LoggerLevel = { ERROR = 0, WARN = 1, INFO = 2, DEBUG = 3 }
```

Format directives `%s %d %i %f %o %O %c %C %%`; `message` is
`{ sn, ts, name, type, level, args, fiber }` (`fiber` is a weak reference
table `{ deref = function() end }`). Timestamps use `host.now()` when present,
falling back to `os.time() * 1000` (or `0` when `os.time` is unavailable).
