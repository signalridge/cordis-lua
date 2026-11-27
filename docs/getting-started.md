# Getting started

This guide walks through creating a root context, providing and injecting services, managing scoped cleanup, dispatching events, using timers and the loader, and embedding `cordis-lua` on a custom host.

For exact signatures and edge-case rules, see [docs/api-core.md](api-core.md).

## 1. Setup and driving tasks

`cordis-lua` requires Lua 5.5 and includes no C extensions (Lua 5.4 is not supported because `nil` error propagation differs from 5.5). Add `lua/?.lua;lua/?/init.lua` to `LUA_PATH` (or `package.path`) and require `cordis`:

```lua
local cordis = require("cordis")
local sched = require("cordis.host.coroutine").new()

local ok, err = sched.drive(function()
  local root = cordis.Context.new({ host = sched.host })
  print(tostring(root)) -- Context <root>
  root:close():await()
end)
assert(ok, err)
assert(#sched.errors == 0, sched.errors[1])
```

Blocking on an unsettled `Future` (`future:await()`, `cordis.await(x)`) or calling `cordis.tick(host)` requires a host task. Reading an already-settled `Future` or calling `cordis.await` on a plain non-thenable value does not block and works outside tasks (including the main thread).

`sched.drive(fn)` spawns `fn` on the reference scheduler, runs the loop until idle, and reports uncaught errors from `fn` or stalls. Uncaught errors raised inside other spawned host tasks are collected in `sched.errors` (and `sched.drive` can still return `true, nil`), so check `#sched.errors == 0` when you need to catch background task failures.

The snippets in sections 2 through 6 share a live `root = cordis.Context.new({ host = sched.host })` inside `sched.drive(function() ... end)`. Call `root:close():await()` only once at the end when shutting down the tree.

## 2. Contexts, fibers, and scopes

`Context.new({ host = ... })` creates the root context and root fiber. You build child scopes in two ways:

- **Derived contexts** (`ctx:extend(meta)`, `ctx:isolate(name, label?)`, `ctx:intercept(name, config)`): return a new `Context` proxy inheriting from `ctx` on the prototype chain while sharing the same owning fiber.
- **Child fibers** (`ctx:use(component, config?)`, `ctx:inject(deps, callback)`): create a child `Fiber` with its own context and disposable list.

`ctx:use` accepts three component forms. Provide `"db"` first so components that inject `"db"` can load:

```lua
root:provide("db", {
  query = function(_, sql)
    return "rows:" .. sql
  end,
})

-- 1. Function
root:use(function(ctx, cfg)
  ctx.logger:info("started with %s", cfg.mode)
end, { mode = "fast" })

-- 2. Table with apply(ctx, cfg) and static metadata
local Plugin = {
  name = "metrics",
  inject = { "db" },
  apply = function(ctx, cfg)
    print(ctx.db:query("SELECT 1")) -- rows:SELECT 1
  end,
}
local fiber = root:use(Plugin)

-- 3. Class created with cordis.class
local Worker = cordis.class("Worker")
Worker.inject = { "db" }
function Worker:constructor(ctx, cfg)
  self.ctx = ctx
end
local workerFiber = root:use(Worker)

cordis.await(fiber)
cordis.await(workerFiber)
```

`ctx:use` and `ctx:inject` return the `Fiber` at once. `cordis.await(fiber)` waits for any in-flight load or unload (`fiber.inertia`) to finish and propagates a load error if the fiber failed. If a required dependency is missing and no work is in flight, the fiber stays in `PENDING` (`state == 0`) and `cordis.await(fiber)` settles on a queue turn without waiting for the missing dependency and without running `apply`.

Dispose child fibers when you no longer need them:

```lua
cordis.await(fiber:dispose())
cordis.await(workerFiber:dispose())
```

When shutting down the whole application, call `root:close():await()`. Because `close()` marks the root fiber disposed permanently, do not reuse `root` afterwards.

## 3. Providing and injecting services

Call `ctx:provide(name, value, check?)` inside a context or fiber to publish a service into the current isolation slot. Access permission and load readiness are distinct rules:

- **Who can read `ctx.<name>`**: a fiber can read its own provision in the same isolation slot, an ancestor's provision or committed injection (unless an intermediate `ctx:isolate(name)` cuts off inheritance), a service it declares in `inject`, or any service when reading from the root context (which has no `fiber.runtime`).
- **When a dependent fiber loads**: declaring `inject = { "store" }` also gates the fiber's lifecycle. The fiber stays in `PENDING` until the provider's fiber is `ACTIVE` and any optional `check(value)` predicate returns true.

```lua
local fiberA = root:use(function(ctx)
  ctx:provide("store", {
    get = function(self, k)
      return "value:" .. k
    end,
  })
end)

local fiberB = root:inject({ "store" }, function(ctx)
  print(ctx.store:get("user")) -- value:user
end)

cordis.await(fiberA)
cordis.await(fiberB)
```

If `fiberA` disposes or reloads, `fiberB` unloads and waits in `PENDING` until `"store"` becomes active again.

For structured services, subclass `cordis.Service`. Calling `Cache.super.constructor(self, ctx, "cache")` registers the service via `ctx.reflect:provide` and attaches the caller-context tracker so methods preserve their caller's context. After construction finishes, the owning `Fiber` invokes `instance[cordis.Service.init](instance)`. If `[Service.init]` returns a `Future`, dependent consumers wait for it to settle before the provider enters `ACTIVE`:

```lua
local Cache = cordis.class("Cache", cordis.Service)
Cache.inject = { "store" }

function Cache:constructor(ctx, config)
  Cache.super.constructor(self, ctx, "cache")
  self.items = {}
end

Cache[cordis.Service.init] = function(self)
  self.items.booted = true
end

function Cache:get(key)
  return self.items[key]
end

cordis.await(root:use(Cache))
print(root.cache:get("booted")) -- true
```

`ctx:accessor(name, { get = ..., set = ... })` defines dynamic properties on contexts, and `ctx:mixin(source, keys)` forwards fields or bound methods from a service onto `ctx` (using `{ "a", "b" }` or `{ sourceField = "exposedAlias" }`).

## 4. Scopes and effect cleanup

Register plugin-managed resources with `ctx:effect(execute, label?)`. `ctx:effect` returns a callable, awaitable `EffectDisposer` table. When `execute` returns a cleanup function (or a `Future` resolving to one), the owning fiber tracks it and runs teardown on unload or reload:

- **Sibling disposers on one fiber** start in reverse registration order and await concurrently. One slow async disposer does not block an earlier sibling from starting.
- **Disposers yielded inside one `cordis.iter` / `cordis.asyncIter` effect** chain sequentially in reverse order.
- **Service providers** wait for every dependent consumer to finish unloading before running their own teardown, so consumers can keep reading committed services while unloading.

```lua
local f = root:use(function(ctx)
  ctx:effect(function()
    local handle = { open = true }
    print("opened")
    return function()
      handle.open = false
      print("closed")
    end
  end, "resource")
end)

cordis.await(f)
cordis.await(f:dispose())
```

Built-in registrations (`ctx:provide`, `ctx:on`, `ctx:accessor`, `ctx:mixin`, `ctx:timeout`, `ctx:interval`) all build on `ctx:effect`, so plugins do not need to track disposer lists by hand.

For multi-step setup with intermediate disposers that should tear down sequentially in reverse, use `cordis.iter` (synchronous) or `cordis.asyncIter` (runs in a host task and aborts at the next `yield` on disposal):

```lua
local iterFiber = root:use(function(ctx)
  ctx:effect(cordis.iter(function(yield)
    yield(ctx:on("ping", function() end))
    yield(ctx:provide("ready", true))
  end))
end)

cordis.await(iterFiber)
cordis.await(iterFiber:dispose())
```

## 5. Events

`ctx:on(name, listener, options?)` and `ctx:once(name, listener, options?)` bind listeners to the calling fiber's lifetime. Pick the dispatch method based on result and concurrency semantics:

| Method | Execution | Return value and error behavior |
| :-- | :-- | :-- |
| `ctx:emit(name, ...)` | Synchronous | `nil`. Runs matching listeners in order; a synchronous error aborts dispatch and propagates to the caller. |
| `ctx:bail(name, ...)` | Synchronous | First result passing `cordis.isBailed(v)` (`v ~= nil`, `v ~= false`, `v ~= cordis.null`), stopping remaining listeners; otherwise `nil`. |
| `ctx:waterfall(name, ..., fallback)` | Synchronous | Result of the middleware chain. Listeners receive `(..., next)` (or `(thisArg, ..., next)`), call `next()` at most once with no extra arguments (extra arguments are ignored and later listeners receive the original arguments), and the terminal `fallback()` runs with zero arguments. |
| `ctx:parallel(name, ...)` | Concurrent `Future`s | `Future` resolving to `nil` once all listeners settle, rejecting with `AggregateError` if any listener fails, or rejecting directly with the original error if dispatch resolution fails. |
| `ctx:serial(name, ...)` | Sequential `Future`s | `Future` awaiting listeners one by one, short-circuiting with the first result passing `cordis.isBailed(v)` (skipping later listeners), or resolving to `nil` if none bail. Rejects and stops on the first error or rejection. |

Pass a `thisArg` table or function as the first argument to supply a receiver and filter listeners through `thisArg[cordis.Context.filter](thisArg, targetCtx)`. Listeners registered with `{ global = true }` bypass that filter:

```lua
local scopeA = root:isolate("orders")
local scopeB = root:isolate("orders")

scopeA:on("item/created", function(svc, id)
  print("scopeA:", svc.name, id)
end)
scopeB:on("item/created", function(svc, id)
  print("scopeB:", svc.name, id) -- skipped: different isolation slot
end)
scopeB:on("item/created", function(svc, id)
  print("global:", svc.name, id) -- runs: { global = true } bypasses filter
end, { global = true })

local svc = {
  name = "orders",
  [cordis.Context.filter] = function(_, targetCtx)
    return targetCtx[cordis.Context.isolate].orders == scopeA[cordis.Context.isolate].orders
  end,
}
root:emit(svc, "item/created", 42)
-- scopeA:	orders	42
-- global:	orders	42
```

## 6. Timers and loader

Optional packages install onto a context in the same way as core plugins, with one module-export difference to watch for:

- **`cordis.timer`**: `require("cordis.timer")` returns the `TimerService` class directly. Installing it provides `ctx.timer` and mixes `ctx:timeout`, `ctx:interval`, `ctx:throttle`, and `ctx:debounce` onto contexts. Plugins that use timers declare `inject = { "timer" }`. `TimerService` requires both `host.sleep` and `host.now`:

```lua
cordis.await(root:use(require("cordis.timer")))

local job = root:inject({ "timer" }, cordis.async(function(ctx)
  ctx:timeout(10):await()
  print("timer fired at", ctx.host.now()) -- timer fired at	10
end))
cordis.await(job)
```

- **`cordis.loader`**: `require("cordis.loader")` returns a module table whose component class is `.Loader` (also aliased as `.default`). Passing the module table directly to `root:use` raises `invalid component`. Install `require("cordis.loader").Loader`:

```lua
cordis.await(root:use(require("cordis.loader").Loader))

package.preload["hello"] = function()
  return {
    name = "hello",
    apply = function(ctx, cfg)
      print("loaded:", cfg.greeting) -- loaded:	hi from hello
    end,
  }
end

root.loader:create({
  name = "hello",
  config = { greeting = { __luaExpr = '"hi from " .. tostring(fiber.name)' } },
}):await()
root.loader:await():await()
```

**Trust boundary for `{ __luaExpr = "..." }`**: loader expressions evaluate with a scope that checks `ctx` first and falls back to the host's `_G`. Any global your host leaves in `_G` (`os`, `io`, `require`, `load`, and so on) is reachable from config expressions. Treat config expressions as trusted code or restrict `_G` in your sandbox; see [docs/deviations.md](deviations.md#loader-packagesloader-100-rc10).

## 7. Embedding with a custom host

`cordis-lua` never creates coroutines on its own. To run it on an external event loop (such as `mlua` + `tokio`, `luv`, or a game engine loop), implement a `cordis.Host` table with `spawn(fn)` and `latch()`:

```lua
local function makeHost(executor)
  return {
    spawn = function(fn)
      executor.spawn(fn)
    end,
    latch = function()
      local opened = false
      local waiters = {}
      return {
        open = function(_)
          if opened then
            return
          end
          opened = true
          for _, waker in ipairs(waiters) do
            executor.schedule(waker) -- never resume inline
          end
          waiters = nil
        end,
        wait = function(_)
          if opened then
            return
          end
          local waker = executor.currentWaker()
          waiters[#waiters + 1] = waker
          executor.suspend()
        end,
      }
    end,
  }
end
```

### Optional host capabilities and embedder notes

- **`sleep(ms, latch?)` and `now()`**: `cordis.timer` strictly requires both `host.sleep` and `host.now` (constructing `TimerService` fails without them). Passing the optional `latch` to `sleep(ms, latch)` lets cleared timers wake right away instead of waiting out the deadline. `Logger` does not require `host.sleep` or `host.now`: it reads `host.now()` when present, falls back to `os.time() * 1000`, and uses `0` if your sandbox removes `os.time` as well.
- **Two task paths with `capture()`**: if your host isolates task execution contexts (for example plugin identity or permissions), implement `host.capture() -> { run, spawn }`. Raw `host.spawn` starts library-internal tasks (such as job-queue drainers) in the host's root context, while `Context` exposes a host facade (`ctx.host`) whose `spawn` routes through `capture().spawn` so plugin-spawned tasks keep their caller's context. `Future:host()` returns the exact host object passed at construction, so construct Futures handed to plugin code with `ctx.host`, not the raw host. Note that `cordis.Future.resolve(ctx.host, value)` creates a `ctx.host`-bound Future only when `value` is a plain non-Future value (`Future.resolve` returns an existing Future unchanged, keeping its original host). To adopt an existing raw-host Future into a facade-owned one, wrap it with `cordis.Future.new(ctx.host, function(resolve) resolve(value) end)`.
- **Cancellable `apply`**: if `scope.spawn(fn)` returns a handle `{ cancel = fn }`, disposing a fiber while it is `LOADING` cancels the directly executing component task while it is suspended. If the fiber is already tracking async work whose completion `apply` returned (for example `root:use(cordis.async(...))` or `return cordis.async(fn)(ctx)`) and that tracked work remains suspended on an unopened latch, disposal still waits for it to settle. Fire-and-forget async tasks that are not returned to `apply` are not tracked by the fiber and do not block disposal.

See [docs/api-core.md §1](api-core.md#1-host-and-async-primitives) for the exact host contract and [docs/hosts.md](hosts.md) to run the test suite against your scheduler.
