# cordis-lua documentation

These documents cover how to use `cordis-lua`, embed it on a host executor, and verify parity against upstream `cordiverse/cordis`.

## Guides and references

| Document | Scope |
| :-- | :-- |
| [Getting started](getting-started.md) | Walkthrough of contexts, `provide`/`inject`, effect cleanup, events, timers, loader, and writing a custom host |
| [Core API reference](api-core.md) | Core Lua API (1.0 contract and optional extensions): host contract (§1), `Future`/`async`, object model, `Context`, `Fiber`, `Events`, `Service`, `Registry`, and `Logger` |
| [Running on other hosts](hosts.md) | Running the test suite against an external scheduler (`--host`, `kit.runner`) and `host.capture` behavior |
| [Deviations from upstream](deviations.md) | Language-level deviations, adopted fixes, host notes, optional extensions, performance paths, and [unported upstream packages](deviations.md#unported-upstream-packages) |
| [Port status](port-status.md) | Case-by-case parity table against upstream `core`, `timer`, and `loader` specs (checked by [`test/kit/port_check.lua`](../test/kit/port_check.lua)) |

## Module map

All 27 source modules live under [`lua/cordis/`](../lua/cordis/).

### Public entry points

Embedders and plugins should import only these four public modules; all other `cordis.*` and `cordis.loader.*` modules listed below are internal implementation modules:

| Module | File | Role |
| :-- | :-- | :-- |
| `cordis` | [`init.lua`](../lua/cordis/init.lua) | Core public entry point re-exporting core symbols, classes, async helpers, and errors |
| `cordis.timer` | [`timer.lua`](../lua/cordis/timer.lua) | Optional `TimerService` (`timeout`, `interval`, `throttle`, `debounce`) built on `host.sleep` and `host.now` |
| `cordis.loader` | [`loader/init.lua`](../lua/cordis/loader/init.lua) | Optional `Loader` service, `unwrapExports`, and public re-exports for the loader package |
| `cordis.host.coroutine` | [`host/coroutine.lua`](../lua/cordis/host/coroutine.lua) | Optional pure-Lua cooperative scheduler with virtual time and `capture` contexts |

### Core runtime (internal modules)

| Module | File | Role |
| :-- | :-- | :-- |
| `cordis.context` | [`context.lua`](../lua/cordis/context.lua) | `Context.new`, `extend`, `isolate`, `intercept`, `close`, and context symbols |
| `cordis.fiber` | [`fiber.lua`](../lua/cordis/fiber.lua) | `Fiber`, `FiberState`, `iter`, `asyncIter`, effect collection, reload/unload state machine |
| `cordis.registry` | [`registry.lua`](../lua/cordis/registry.lua) | `RegistryService`, `Inject`, `use`, `inject`, `replace`, and component resolution |
| `cordis.reflect` | [`reflect.lua`](../lua/cordis/reflect.lua) | `ReflectService`, `provide`, `get`, `getImpl`, `set`, `accessor`, `mixin`, `notify`, `locate` |
| `cordis.service` | [`service.lua`](../lua/cordis/service.lua) | `Service` base class (`init`, `check`, `invoke`, `tracker`, `resolveIntercept`, `filter`) |
| `cordis.events` | [`events.lua`](../lua/cordis/events.lua) | `EventsService` (`on`, `once`, `emit`, `bail`, `waterfall`, `parallel`, `serial`, `resolve`, `listeners`, `listenerCount`, `isBailed`) |
| `cordis.logger` | [`logger.lua`](../lua/cordis/logger.lua) | `Logger`, `LoggerService`, `LoggerLevel`, bounded log buffer, and custom exporters |

### Async, object model, and internals

| Module | File | Role |
| :-- | :-- | :-- |
| `cordis.future` | [`future.lua`](../lua/cordis/future.lua) | `Future`, `async`, `await`, `tick`, `queueMicrotask`, job-queue drainer, and `capture` integration |
| `cordis.proto` | [`proto.lua`](../lua/cordis/proto.lua) | Prototype-chained JS-like objects with insertion-ordered own keys |
| `cordis.class` | [`class.lua`](../lua/cordis/class.lua) | Class builder (`cordis.class`), `construct`, inheritance, `__get`/`__set`, and `.is()` checks |
| `cordis.ordered` | [`ordered.lua`](../lua/cordis/ordered.lua) | Insertion-ordered `Map` and `Set` |
| `cordis.list` | [`list.lua`](../lua/cordis/list.lua) | `DisposableList` for ordered registration and teardown |
| `cordis.symbols` | [`symbols.lua`](../lua/cordis/symbols.lua) | `symbol`, `symbolFor`, `isSymbol`, `null`, `isNullable`, and internal symbol table |
| `cordis.error` | [`error.lua`](../lua/cordis/error.lua) | `Error`, `TypeError`, `AggregateError`, `CordisError`, and `debug`-optional tracebacks |
| `cordis.config` | [`config.lua`](../lua/cordis/config.lua) | `ValidationError` and Standard Schema `resolveConfig` |
| `cordis.trace` | [`trace.lua`](../lua/cordis/trace.lua) | Traceable service proxies, `composeError`, `buildOuterStack`, `getTraceable` |
| `cordis.inject_index` | [`inject_index.lua`](../lua/cordis/inject_index.lua) | Fiber index keyed by injected service name for `ReflectService:notify` |
| `cordis.resolve_epoch` | [`resolve_epoch.lua`](../lua/cordis/resolve_epoch.lua) | Epoch counter invalidating cached context service resolutions |

### Loader internals

| Module | File | Role |
| :-- | :-- | :-- |
| `cordis.loader.tree` | [`loader/tree.lua`](../lua/cordis/loader/tree.lua) | `EntryTree` create/update/remove/move operations, module imports, and tree settlement (`await`) |
| `cordis.loader.group` | [`loader/group.lua`](../lua/cordis/loader/group.lua) | `EntryGroup` child list management and `Group` component |
| `cordis.loader.entry` | [`loader/entry.lua`](../lua/cordis/loader/entry.lua) | `Entry` lifecycle, option merging, outer/inner fibers, and validation error tracing |
| `cordis.loader.isolate` | [`loader/isolate.lua`](../lua/cordis/loader/isolate.lua) | `LocalRealm` and isolation map helpers |
| `cordis.loader.utils` | [`loader/utils.lua`](../lua/cordis/loader/utils.lua) | `{ __luaExpr = "..." }` compilation/evaluation, interpolation, `ReferenceError`, shallow copy and deep comparison |

## Keeping docs accurate

When you change a contract, interface, or deviation, update the owning document in the same commit:

- Host and core Lua API shapes belong in [`docs/api-core.md`](api-core.md) (keep `§1` intact for embedders).
- Behavioral differences from [`UPSTREAM`](../UPSTREAM) belong in [`docs/deviations.md`](deviations.md).
- Test parity rows in [`docs/port-status.md`](port-status.md) must match upstream counts and spec names; run `just check` after edits to verify `port_check.lua` and both test modes.
