# cordis-lua

Pure Lua 5.5 port of [Cordis](https://github.com/cordiverse/cordis) 4.x: contexts, fibers with effect cleanup, dependency-tracked services, and event dispatch. Zero native dependencies, MIT licensed. Aligned upstream commit: [`UPSTREAM`](UPSTREAM).

English | [简体中文](README.zh-CN.md)

## When to use it

When you embed Lua plugins, reloading or disabling a plugin often leaves stale event listeners, timers, or services behind. `cordis-lua` ties plugin resources to a fiber through `ctx:effect` (which also backs `provide`, `on`, and timers). On reload or disposal, sibling disposers on a fiber start in reverse registration order and await concurrently (disposers yielded inside one effect iterator chain sequentially in reverse), service providers wait for dependent consumers to unload before tearing down, and `ctx:isolate` scopes individual service names to a subtree.

Core never calls `coroutine.create` or `coroutine.resume`. Pass a host (`spawn` and `latch`) from your executor (`mlua`, `tokio`, or a frame loop), or use `cordis.host.coroutine` in standalone Lua.

If you have a small script or a fixed set of modules loaded once at startup, plain `require` and Lua tables are simpler. Reach for `cordis-lua` when you need runtime reloads, dependency injection, or isolated plugin scopes.

## Quick start

Put `lua/` on `package.path`, create a host scheduler, and run inside a task:

```lua
local cordis = require("cordis")
local sched = require("cordis.host.coroutine").new()

local ok, err = sched.drive(function()
  local root = cordis.Context.new({ host = sched.host })

  -- Subscribe on the root context
  root:on("ready", function(msg)
    print("event:", msg)
  end)

  -- Provide a service; returns a callable, awaitable EffectDisposer
  root:provide("greeting", "hello")

  -- Create a child scope (fiber) that injects "greeting" and registers cleanup
  local child = root:inject({ "greeting" }, function(ctx)
    ctx:effect(function()
      print("child active:", ctx.greeting)
      return function()
        print("child disposed")
      end
    end)
    ctx:emit("ready", ctx.greeting .. " from child")
  end)

  cordis.await(child)
  cordis.await(child:dispose())
  root:close():await()
end)
assert(ok, err)
```

Save the snippet above as `quickstart.lua` and run it from the repository root:

```sh
LUA_PATH="lua/?.lua;lua/?/init.lua;;" lua quickstart.lua
```

Output:

```text
child active:	hello
event:	hello from child
child disposed
```

`root:inject` creates a child fiber that waits until `"greeting"` is active and runs the callback. Inside it, `ctx:effect` returns a callable, awaitable `EffectDisposer` table and binds the cleanup function returned by the setup callback to that child fiber. `child:dispose()` runs the cleanup and removes the fiber from the registry. `root:close()` returns a `Future` that shuts down the root context, and `:await()` waits for teardown to settle.

## How it fits together

- **Context tree**: `Context` nodes inherit properties, isolations, and intercepts down a prototype chain (`extend`, `isolate`, `intercept`) while routing registrations to their owning fiber.
- **Fibers and effects**: `ctx:use` and `ctx:inject` create a `Fiber` (`PENDING`, `LOADING`, `ACTIVE`, `FAILED`, `UNLOADING`, `DISPOSED`). The owning fiber unloads resources registered via `ctx:effect` when it reloads or disposes.
- **Services and DI**: `ctx:provide` binds a value into the current isolation slot. Consumers read `ctx.<name>` after declaring it in `inject` (or from an ancestor or root scope), or subclass `cordis.Service` for `[Service.init]` hooks and methods that preserve caller context.
- **Events**: `ctx:on` and `ctx:once` bind listeners to a fiber. `emit`, `bail`, and `waterfall` dispatch synchronously; `parallel` and `serial` return `Future`s; `thisArg` carrying `[cordis.Context.filter]` scopes dispatches by isolation.
- **Pluggable host**: `Context.new({ host = ... })` takes any `cordis.Host` implementing `spawn` and `latch` (plus optional `sleep`, `now`, and `capture`); see [docs/api-core.md §1](docs/api-core.md#1-host-and-async-primitives). `cordis.host.coroutine` ships as the reference scheduler for standalone Lua and tests.

## Modules

| Module | Contents |
| :-- | :-- |
| `cordis` ([`lua/cordis/init.lua`](lua/cordis/init.lua)) | Public entry point exporting core classes, async helpers, symbols, and errors |
| Core runtime and helpers (`lua/cordis/*.lua`) | Context tree, fiber lifecycle, DI/reflection, `Service`, events, logger, `Future`/async, object model, and internal caches; see [docs/README.md](docs/README.md) for all 27 modules |
| `cordis.timer` ([`lua/cordis/timer.lua`](lua/cordis/timer.lua)) | `TimerService` (`ctx:timeout`, `ctx:interval`, `ctx:throttle`, `ctx:debounce`) on `host.sleep` and `host.now` |
| `cordis.loader` ([`lua/cordis/loader/init.lua`](lua/cordis/loader/init.lua)) | `Loader`, `EntryTree`, `EntryGroup`, `Entry`, `LocalRealm`, `{ __luaExpr = "..." }` evaluation and interpolation |
| `cordis.host.coroutine` ([`lua/cordis/host/coroutine.lua`](lua/cordis/host/coroutine.lua)) | Reference cooperative scheduler with virtual time (`eager`, `auto`, `contexts`, `advance`, `runAll`, `drive`) |

## Embedding a tagged release

To vendor a tagged release, copy [`lua/cordis/`](lua/cordis/) into your Lua load path (omit `lua/cordis/host/` if you supply your own `cordis.Host`) alongside [`LICENSE`](LICENSE). See [`CONTRIBUTING.md`](CONTRIBUTING.md) for contribution guidelines and [`SECURITY.md`](SECURITY.md) for reporting vulnerabilities.

## Documentation

- [docs/README.md](docs/README.md): documentation index and full 27-module map
- [docs/getting-started.md](docs/getting-started.md): walkthrough of contexts, services, effects, events, timers, loader, and custom hosts
- [docs/api-core.md](docs/api-core.md): core Lua API and host contract (§1)
- [docs/hosts.md](docs/hosts.md): running the test suite on an external scheduler (`--host`, `kit.runner`)
- [docs/deviations.md](docs/deviations.md): language-level deviations, adopted fixes, optional extensions, and performance paths

## Tests and compatibility

Requires Lua 5.5 (`mise install`). Lua 5.4 is not supported: although the modules compile under 5.4, `nil` error propagation differs from Lua 5.5 and can leave a failed fiber in `PENDING`. Case-by-case upstream parity is tracked in [docs/port-status.md](docs/port-status.md) and checked by [`test/kit/port_check.lua`](test/kit/port_check.lua).

```sh
lua test/run.lua             # deferred spawn
lua test/run.lua --eager     # eager spawn
lua test/run.lua --contexts  # execution context capture
lua test/run.lua --filter fiber
just check                   # all 4 test modes (deferred/eager x capture), stylua, luac -p, port_check
```

The suite also runs on an embedder's scheduler via `lua test/run.lua --host <module>`, or `require("kit.runner").run({ files = ..., scheduler = factory })` from the embedder's test environment ([`test/kit/runner.lua`](test/kit/runner.lua)). Cases that need virtual time or the `debug` library skip and list their reasons when those capabilities are absent ([docs/hosts.md](docs/hosts.md)).

## License

Distributed under the [MIT License](LICENSE).
