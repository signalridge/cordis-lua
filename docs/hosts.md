# Running on other hosts

Run the test suite on an external scheduler with `lua test/run.lua --host <module>`, or call `require("kit.runner").run({ files = ..., scheduler = factory })` from your embedder's own test environment.

## Runner scheduler adapter

The test runner does not take a bare `cordis.Host`; it takes a **scheduler factory** `factory(options)` (defined in [`test/kit/runner.lua`](../test/kit/runner.lua)) returning:

```text
{
  host   = cordisHost,               -- cordis.Host: spawn, latch, sleep(ms, latch?) (used by U.sleep in
                                     -- core/loader/lib specs; honor optional latch for early-wakeup tests),
                                     -- plus now (required by timer specs and virtual-time tests in test/lib/)
                                     -- and optional capture
  drive  = function(fn) -> ok, err,  -- spawn fn, drive until done or stalled
  errors = {},                       -- uncaught errors raised by spawned tasks (fail the test)
  setTimeout = function(fn, ms) -> cancel, -- required by non-virtual specs too (e.g. core/replace_spec.lua)
  -- optional virtual-time capabilities (enables fake-timer specs instead of skipping them):
  virtual = true,
  auto    = boolean,                 -- writable; false under U.withTimers
  advance = function(ms),
  runAll  = function(),
}
```

Note that running the full test suite requires more than the bare minimum core `cordis.Host` (`spawn` and `latch`): ordinary non-virtual specs call `host.sleep` (through `U.sleep`) and `sched.setTimeout(fn, ms) -> cancel`. For full virtual-time suite coverage, `host.sleep(ms, latch)` must honor the optional `latch` so early-wakeup/cancellation tests pass (`test/timer/fixes_spec.lua`), and `host.now` is required both by `test/timer/` specs and by two virtual-time tests in `test/lib/` (`test/lib/future_spec.lua` and `test/lib/host_spec.lua`).

### Packaging notes for external hosts

- **Reference scheduler specs**: `test/run.lua` discovers every `*_spec.lua` file by default. `test/lib/host_spec.lua` and `test/lib/capture_spec.lua` call `require("cordis.host.coroutine")` at file top level, so if your embedder does not ship `cordis.host.coroutine`, loading those two files fails unless you omit them from the `files` list passed to `kit.runner.run`. `test/timer/fixes_spec.lua` handles its reference-scheduler test via `U.requires("reference scheduler")` and skips cleanly.
- **Missing virtual time or `debug`**: cases requiring fake timers (`U.withTimers`, `U.advance`, `U.runAll`) or Lua's `debug` library (`U.requires("debug")`) skip themselves and report their reasons (see [deviations.md](deviations.md#host-notes)).

## Hosts with `capture`

On a host that offers `capture` (`lua test/run.lua --contexts` runs the reference scheduler that way),
a component's `apply` runs as its own spawned task (`scope.spawn`), so on deferred `capture` hosts
(such as tokio/mlua embedders) `fiber:await()` on a still-`PENDING` dependent settles before the
provider's spawned `apply` task activates it. As a **host coverage limitation**, the two upstream-ported
cases that assert upstream's exact microtask-order settlement skip themselves via
`U.requires("microtask order")` on `capture` hosts (both pass without `capture`, and also happen to
pass when `spawn` is eager):

| case | reason |
|---|---|
| core/fiber_spec.lua > Fiber > update config while injected service reloads | relies on microtask order (host with capture) |
| core/service_dispose_spec.lua > Service disposal > retains transitive dependencies while a consumer providing another service drains | relies on microtask order (host with capture) |

The underlying lifecycle guarantees (applying a config update across a provider reload, and retaining
transitive dependencies while a draining consumer finishes) are covered under both deferred and eager
`capture` in [`test/lib/capture_spec.lua`](../test/lib/capture_spec.lua) (`lifecycle coverage under
capture`) using explicit activation synchronization instead of microtask-order timing.

See the execution contexts entry in [deviations.md](deviations.md#extensions) (upstream `fiber.spec.ts:326`,
`service-dispose.spec.ts:131`).

## Historical real-time host measurement

On a real-time scheduler without virtual time or the `debug` library (an embedder's task executor where spawned tasks
start later, measured 2026-11-17 at cordis-lua `7be5864`), 376 cases passed, 0 failed, and 41 skipped:

| case | reason |
|---|---|
| core/dispose_spec.lua > Effects > async return 1 | needs virtual time (fake timers) |
| core/dispose_spec.lua > Effects > async return 2 | needs virtual time (fake timers) |
| core/dispose_spec.lua > Effects > async yield (aborted, finally) | needs virtual time (fake timers) |
| core/dispose_spec.lua > Effects > async yield 1 | needs virtual time (fake timers) |
| core/dispose_spec.lua > Effects > async yield 2 (aborted) | needs virtual time (fake timers) |
| core/dispose_spec.lua > Effects > async yield 3 (aborted) | needs virtual time (fake timers) |
| core/dispose_spec.lua > Effects > async yield 4 (await dispose) | needs virtual time (fake timers) |
| core/fiber_spec.lua > Fiber > inertia lock 1 | needs virtual time (fake timers) |
| core/fiber_spec.lua > Fiber > inertia lock 2 | needs virtual time (fake timers) |
| core/fiber_spec.lua > Fiber > inertia lock 3 | needs virtual time (fake timers) |
| core/reflect_spec.lua > Reflect > access error | needs the debug library |
| lib/future_spec.lua > Future > await on a settled future returns immediately | needs virtual time |
| lib/host_spec.lua > host > advance fires timers in due order | needs virtual time (fake timers) |
| timer/fixes_spec.lua > timer fixes > counts a debounce delay from the call on a host that starts tasks late | needs virtual time (fake timers) |
| timer/fixes_spec.lua > timer fixes > counts a timeout from registration on a host that starts tasks late | needs virtual time (fake timers) |
| timer/fixes_spec.lua > timer fixes > counts the first interval tick from registration on a host that starts tasks late | needs virtual time (fake timers) |
| timer/index_spec.lua > ctx.timer > ctx.debounce() > basic support | needs virtual time (fake timers) |
| timer/index_spec.lua > ctx.timer > ctx.debounce() > context dispose | needs virtual time (fake timers) |
| timer/index_spec.lua > ctx.timer > ctx.debounce() > disposed | needs virtual time (fake timers) |
| timer/index_spec.lua > ctx.timer > ctx.interval() > async iterator (break return) | needs virtual time (fake timers) |
| timer/index_spec.lua > ctx.timer > ctx.interval() > async iterator (break throw) | needs virtual time (fake timers) |
| timer/index_spec.lua > ctx.timer > ctx.interval() > async iterator (concurrent reads) | needs virtual time (fake timers) |
| timer/index_spec.lua > ctx.timer > ctx.interval() > async iterator (context dispose with concurrent reads) | needs virtual time (fake timers) |
| timer/index_spec.lua > ctx.timer > ctx.interval() > async iterator (context dispose) | needs virtual time (fake timers) |
| timer/index_spec.lua > ctx.timer > ctx.interval() > async iterator (manual return) | needs virtual time (fake timers) |
| timer/index_spec.lua > ctx.timer > ctx.interval() > async iterator (manual throw) | needs virtual time (fake timers) |
| timer/index_spec.lua > ctx.timer > ctx.interval() > async iterator (return with concurrent reads) | needs virtual time (fake timers) |
| timer/index_spec.lua > ctx.timer > ctx.interval() > async iterator (throw with concurrent reads) | needs virtual time (fake timers) |
| timer/index_spec.lua > ctx.timer > ctx.interval() > basic support | needs virtual time (fake timers) |
| timer/index_spec.lua > ctx.timer > ctx.throttle() > basic support | needs virtual time (fake timers) |
| timer/index_spec.lua > ctx.timer > ctx.throttle() > context dispose with re-entrant callback | needs virtual time (fake timers) |
| timer/index_spec.lua > ctx.timer > ctx.throttle() > context dispose | needs virtual time (fake timers) |
| timer/index_spec.lua > ctx.timer > ctx.throttle() > disposed with noTrailing | needs virtual time (fake timers) |
| timer/index_spec.lua > ctx.timer > ctx.throttle() > disposed | needs virtual time (fake timers) |
| timer/index_spec.lua > ctx.timer > ctx.throttle() > does not release the throttle early when the wall clock moves forwards | needs virtual time (fake timers) |
| timer/index_spec.lua > ctx.timer > ctx.throttle() > no trailing mode | needs virtual time (fake timers) |
| timer/index_spec.lua > ctx.timer > ctx.throttle() > trailing mode | needs virtual time (fake timers) |
| timer/index_spec.lua > ctx.timer > ctx.throttle() > uses elapsed time when the wall clock moves backwards | needs virtual time (fake timers) |
| timer/index_spec.lua > ctx.timer > ctx.timeout() > basic support | needs virtual time (fake timers) |
| timer/index_spec.lua > ctx.timer > ctx.timeout() > dispose | needs virtual time (fake timers) |
| timer/index_spec.lua > ctx.timer > ctx.timeout() > promise | needs virtual time (fake timers) |

In that 2026-11-17 measurement, every timer case required fake timers, and the remaining skips required virtual time except core `reflect` "access error", which requires the `debug` library.
