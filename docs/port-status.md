# Port status: upstream `packages/core/tests`

One row per upstream `it` / `it.each` (aligned commit in `UPSTREAM`): 178 `it`
plus 10 parameterized `it.each`, 188 rows. An `it.each` row is ported when
every parameter is covered; its Lua case name is the title without `[each] `
and with the parameter placeholder kept (one `it` looping over the parameters). Status values:

- `ported` — same case name in `test/core/<file>_spec.lua`, same rule asserted.
- `ported (rewritten: <reason>)` — same rule, different form (counts as ported).
- `n/a: <reason>` — not applicable; reason required.

Checked by `test/kit/port_check.lua` (verifies package row counts, per-file `(name, occurrence count)` matches, and rejects `todo` rows).

| upstream | case | status |
|---|---|---|
| core/tests/associate.spec.ts:5 | service injection | ported |
| core/tests/associate.spec.ts:30 | property injection | ported |
| core/tests/associate.spec.ts:58 | associated type - service injection | ported |
| core/tests/associate.spec.ts:114 | associated type - accessor injection | ported |
| core/tests/associate.spec.ts:176 | associated access follows the service fiber | ported |
| core/tests/associate.spec.ts:235 | inspect | ported (rewritten: `Function.prototype.toString` of a class is `tostring(Class)` → `class X`) |
| core/tests/component.spec.ts:8 | apply functional component | ported |
| core/tests/component.spec.ts:18 | apply object component | ported |
| core/tests/component.spec.ts:29 | apply component through deprecated ctx.plugin() | ported |
| core/tests/component.spec.ts:40 | apply invalid component | ported |
| core/tests/component.spec.ts:47 | inactive context | ported |
| core/tests/component.spec.ts:61 | context inspect | ported (rewritten: `util.inspect(ctx)` → `tostring(ctx)`; the named-function case uses a table component `{ name = "foo" }` since Lua functions have no name) |
| core/tests/component.spec.ts:88 | ctx.registry | ported |
| core/tests/component.spec.ts:97 | nested components | ported |
| core/tests/component.spec.ts:134 | compare snapshot | ported |
| core/tests/component.spec.ts:155 | root dispose | ported |
| core/tests/component.spec.ts:175 | Service.init | ported |
| core/tests/decorator.spec.ts:7 | @Inject on class method | ported |
| core/tests/dispose.spec.ts:7 | dispose by component | ported |
| core/tests/dispose.spec.ts:23 | dispose manually | ported |
| core/tests/dispose.spec.ts:37 | yield dispose | ported |
| core/tests/dispose.spec.ts:76 | async return 1 | ported |
| core/tests/dispose.spec.ts:90 | async return 2 | ported |
| core/tests/dispose.spec.ts:103 | async yield 1 | ported |
| core/tests/dispose.spec.ts:123 | async yield 2 (aborted) | ported |
| core/tests/dispose.spec.ts:143 | async yield 3 (aborted) | ported |
| core/tests/dispose.spec.ts:165 | async yield (aborted, finally) | ported (rewritten: `finally` as a `<close>` variable) |
| core/tests/dispose.spec.ts:185 | async yield 4 (await dispose) | ported |
| core/tests/dispose.spec.ts:205 | return with error | ported |
| core/tests/dispose.spec.ts:217 | yield with error | ported |
| core/tests/dispose.spec.ts:230 | async return with error | ported |
| core/tests/dispose.spec.ts:242 | async yield with error | ported |
| core/tests/dispose.spec.ts:261 | async yield invalid effect | ported (rewritten: `finally` as a `<close>` variable) |
| core/tests/events.spec.ts:18 | deprecated dispatch returns bound callbacks that respect later removal | ported |
| core/tests/events.spec.ts:35 | deprecated waterfall dispatch continues past a removed callback | ported |
| core/tests/events.spec.ts:49 | supports symbol event names across dispatch modes | ported |
| core/tests/events.spec.ts:66 | supports symbol event names with ctx.once() | ported |
| core/tests/events.spec.ts:77 | treats prototype property names as ordinary events | ported (rewritten: Lua metamethod names `__index` / `__newindex` instead of JS prototype names) |
| core/tests/events.spec.ts:96 | removes empty event buckets after disposal | ported |
| core/tests/events.spec.ts:108 | ctx.on() | ported |
| core/tests/events.spec.ts:121 | ctx.once() | ported |
| core/tests/events.spec.ts:134 | ctx.once() runs once when an earlier listener emits recursively | ported |
| core/tests/events.spec.ts:149 | ctx.once() runs once across concurrent serial dispatches | ported |
| core/tests/events.spec.ts:163 | [each] %s skips listeners removed during dispatch | ported |
| core/tests/events.spec.ts:177 | [each] %s defers added listeners until the next dispatch | ported |
| core/tests/events.spec.ts:188 | skips a listener disposed by an earlier component during dispatch | ported |
| core/tests/events.spec.ts:200 | waterfall continues past a removed listener | ported |
| core/tests/events.spec.ts:219 | waterfall defers added listeners until the next dispatch | ported |
| core/tests/events.spec.ts:233 | waterfall continues after a recursive dispatch has consumed a once listener | ported |
| core/tests/events.spec.ts:251 | internal/update continues past a removed fiber listener | ported |
| core/tests/events.spec.ts:280 | ctx.parallel() | ported |
| core/tests/events.spec.ts:311 | ctx.parallel() labels symbol events | ported |
| core/tests/events.spec.ts:322 | ctx.emit() | ported |
| core/tests/events.spec.ts:341 | ctx.serial() | ported |
| core/tests/events.spec.ts:360 | ctx.bail() | ported |
| core/tests/events.spec.ts:379 | ctx.waterfall() | ported |
| core/tests/events.spec.ts:407 | ctx.waterfall() rejects duplicate next() | ported |
| core/tests/events.spec.ts:421 | ctx.waterfall() rejects continuations from outer frames | ported |
| core/tests/events.spec.ts:442 | ctx.waterfall() rejects duplicate next() after awaiting | ported |
| core/tests/events.spec.ts:455 | ctx.waterfall() supports nested async calls | ported |
| core/tests/events.spec.ts:473 | does not accumulate across reloads | ported |
| core/tests/events.spec.ts:490 | can be disposed explicitly | ported |
| core/tests/events.spec.ts:507 | runs prepended listeners first | ported |
| core/tests/events.spec.ts:534 | global listeners are not tied to a child fiber reload | ported |
| core/tests/fiber.spec.ts:7 | inertia lock 1 | ported |
| core/tests/fiber.spec.ts:27 | inertia lock 2 | ported |
| core/tests/fiber.spec.ts:49 | inertia lock 3 | ported |
| core/tests/fiber.spec.ts:71 | component error | ported |
| core/tests/fiber.spec.ts:93 | failed fiber does not re-enter on dependency refresh | ported |
| core/tests/fiber.spec.ts:108 | update recovers a failed fiber | ported |
| core/tests/fiber.spec.ts:122 | update waits for asynchronous recovery | ported |
| core/tests/fiber.spec.ts:144 | update surfaces a failed recovery to its caller | ported |
| core/tests/fiber.spec.ts:156 | update surfaces a failed reload to its caller | ported |
| core/tests/fiber.spec.ts:171 | update does not leak a dropped failure | ported |
| core/tests/fiber.spec.ts:185 | dispose error | ported |
| core/tests/fiber.spec.ts:204 | settles a pending fiber to DISPOSED on dispose | ported (rewritten: `use()` returns the fiber itself, so `Object.getPrototypeOf(fiber)` is the fiber) |
| core/tests/fiber.spec.ts:231 | settles a failed fiber to DISPOSED on dispose | ported (rewritten: `use()` returns the fiber itself, so `Object.getPrototypeOf(fiber)` is the fiber) |
| core/tests/fiber.spec.ts:264 | keeps the active dispose sequence stable | ported (rewritten: `use()` returns the fiber itself, so `Object.getPrototypeOf(fiber)` is the fiber) |
| core/tests/fiber.spec.ts:292 | update config on wrapped fiber | ported |
| core/tests/fiber.spec.ts:312 | restart wrapped fiber | ported (rewritten: the two `Object.hasOwn(wrapper, …)` checks are dropped, there is no wrapper object) |
| core/tests/fiber.spec.ts:326 | update config while injected service reloads | ported (rewritten: wrapper-vs-base comparisons dropped, there is no wrapper object; applied order and final state asserted) |
| core/tests/fiber.spec.ts:384 | fail on first load | ported |
| core/tests/fiber.spec.ts:396 | keep a running component on update | ported |
| core/tests/fiber.spec.ts:413 | keep the issues and their paths | ported |
| core/tests/fiber.spec.ts:426 | pass the resolved config to listeners | ported |
| core/tests/fiber.spec.ts:448 | keep the source config when a listener handles the update | ported |
| core/tests/fiber.spec.ts:477 | leaves a disposer to the fiber that takes it over | ported |
| core/tests/fiber.spec.ts:492 | does not leak a disposer of another fiber | ported |
| core/tests/intercept.spec.ts:34 | merge context intercepts from outer to inner | ported |
| core/tests/intercept.spec.ts:42 | merge injected config under context intercepts | ported |
| core/tests/intercept.spec.ts:52 | take injected config from the declaring fiber | ported |
| core/tests/intercept.spec.ts:69 | stop looking for injected config at an isolation boundary | ported |
| core/tests/intercept.spec.ts:83 | take no injected config for own provisions | ported |
| core/tests/intercept.spec.ts:96 | take injected config from the def site | ported |
| core/tests/intercept.spec.ts:103 | custom merge | ported |
| core/tests/invoke.spec.ts:5 | functional service | ported |
| core/tests/invoke.spec.ts:62 | uses the service shadow for callable extensions | ported |
| core/tests/isolate.spec.ts:7 | does not expose own provisions across isolation boundaries | ported |
| core/tests/isolate.spec.ts:24 | does not inherit the injected view across isolation boundaries | ported |
| core/tests/isolate.spec.ts:55 | isolated context | ported |
| core/tests/isolate.spec.ts:106 | shared label | ported |
| core/tests/isolate.spec.ts:152 | isolated event | ported |
| core/tests/isolate.spec.ts:172 | keeps own provisions separate from the injected view | ported |
| core/tests/logger.spec.ts:18 | keeps the bounded buffer in place and chronological | ported |
| core/tests/logger.spec.ts:37 | disposes the exporter that registered the disposer | ported |
| core/tests/logger.spec.ts:55 | uses fiber name when called from outside any service | ported |
| core/tests/logger.spec.ts:61 | honours explicit name argument | ported |
| core/tests/logger.spec.ts:67 | honours intercept name | ported |
| core/tests/logger.spec.ts:73 | uses service name when called from inside a Service method (regression) | ported |
| core/tests/logger.spec.ts:91 | still lets outer caller intercept override the service-derived name | ported |
| core/tests/logger.spec.ts:109 | uses the innermost service name and restores the outer service | ported |
| core/tests/logger.spec.ts:140 | uses service name when called from inside [Service.init] (unchanged behaviour) | ported |
| core/tests/logger.spec.ts:156 | logs an error whose errors array is empty | ported |
| core/tests/logger.spec.ts:165 | flattens an aggregate error into its members | ported |
| core/tests/reflect.spec.ts:7 | Context.is() | ported (rewritten: a context object derived from `Context.prototype` stands for an instance of a `Context` subclass; contexts are not cordis classes) |
| core/tests/reflect.spec.ts:13 | access check | ported (rewritten: the `ctx['prototype']` no-throw line is dropped, `prototype` is not a reserved name in Lua) |
| core/tests/reflect.spec.ts:31 | service injection | ported |
| core/tests/reflect.spec.ts:58 | access error | ported (rewritten: the V8 stack-frame name check matches the traceback source line instead; Lua functions are anonymous) |
| core/tests/reflect.spec.ts:99 | service inject leak | ported |
| core/tests/reflect.spec.ts:109 | does not load a fiber disposed during service notification | ported |
| core/tests/replace.spec.ts:7 | swaps the implementation behind a fiber in place | ported |
| core/tests/replace.spec.ts:29 | emits internal/replace for each moved fiber | ported |
| core/tests/replace.spec.ts:46 | validates the config with the new schema | ported |
| core/tests/replace.spec.ts:60 | takes the dependencies of the new component | ported |
| core/tests/replace.spec.ts:79 | starts a pending fiber when the new component drops the missing dependency | ported |
| core/tests/replace.spec.ts:92 | starts a pending fiber when the new component injects an available service | ported |
| core/tests/replace.spec.ts:106 | stops depending on a dependency that the new component drops | ported |
| core/tests/replace.spec.ts:121 | reloads a consumer of a replaced service | ported |
| core/tests/replace.spec.ts:145 | merges the fibers into a registered component | ported |
| core/tests/replace.spec.ts:162 | restarts a failed fiber | ported |
| core/tests/replace.spec.ts:176 | leaves a fiber failed when the new component fails to apply | ported |
| core/tests/replace.spec.ts:186 | forwards the old component to the new one | ported |
| core/tests/replace.spec.ts:208 | forwards a component that is not registered | ported |
| core/tests/replace.spec.ts:220 | follows a chain of replacements | ported |
| core/tests/replace.spec.ts:234 | switches back to a replaced component | ported |
| core/tests/replace.spec.ts:248 | unregisters the new component when its last fiber is disposed | ported |
| core/tests/service-dispose.spec.ts:31 | [each] releases an injected binding after providing the same name in another realm (%s) | ported |
| core/tests/service-dispose.spec.ts:48 | waits for a disposing consumer that has already left the registry | ported |
| core/tests/service-dispose.spec.ts:73 | withdraws one binding without waiting for another binding from the same provider | ported |
| core/tests/service-dispose.spec.ts:95 | [each] retains resources during consumer cleanup (%s) | ported |
| core/tests/service-dispose.spec.ts:131 | retains transitive dependencies while a consumer providing another service drains | ported |
| core/tests/service-dispose.spec.ts:156 | [each] retains dependencies through in-flight setup and rollback (failure: %s) | ported |
| core/tests/service-dispose.spec.ts:184 | releases dependencies after a cleanup error | ported |
| core/tests/service-dispose.spec.ts:199 | keeps provider listeners alive through the final consumer event | ported |
| core/tests/service-dispose.spec.ts:214 | allows unrelated providers and sibling effects to clean up concurrently | ported |
| core/tests/service-dispose.spec.ts:238 | [each] supports composed provider effects (owner shutdown: %s) | ported |
| core/tests/service-dispose.spec.ts:271 | keeps an inherited service accessible to a child in a composed effect | ported |
| core/tests/service-dispose.spec.ts:287 | retains an ancestor injection until its child finishes cleanup | ported |
| core/tests/service-dispose.spec.ts:307 | waits for a child that explicitly injects its parent service | ported |
| core/tests/service-dispose.spec.ts:323 | [each] tracks same-name services in separate isolation realms (root shutdown: %s) | ported |
| core/tests/service-dispose.spec.ts:355 | withdraws only the old binding without waiting for the next load | ported |
| core/tests/service-dispose.spec.ts:386 | [each] waits for current and withdrawn bindings during provider disposal (withdrawn first: %s) | ported |
| core/tests/service-dispose.spec.ts:418 | replaces a binding from the same provider during consumer initialization | ported |
| core/tests/service.spec.ts:7 | pending inject | ported |
| core/tests/service.spec.ts:36 | traceable effect (with inject) | ported |
| core/tests/service.spec.ts:76 | traceable effect (without inject) | ported |
| core/tests/service.spec.ts:109 | compare snapshot | ported |
| core/tests/service.spec.ts:127 | multiple injects | ported |
| core/tests/service.spec.ts:190 | dispose dependents before provider | ported |
| core/tests/service.spec.ts:202 | dispose dependents before provider restarts | ported |
| core/tests/service.spec.ts:216 | dispose dependents before isolated provider | ported |
| core/tests/service.spec.ts:237 | answers for null and undefined | ported |
| core/tests/service.spec.ts:244 | answers for a plain object after walking to the end of the chain | ported |
| core/tests/shadow.spec.ts:5 | keeps caller metadata separate from the service shadow | ported |
| core/tests/shadow.spec.ts:60 | applies the service inject when entered from root | ported |
| core/tests/shadow.spec.ts:93 | resolves dependencies through a captured shadow | ported |
| core/tests/shadow.spec.ts:157 | resolves same-name own provisions at their definition sites | ported |
| core/tests/shadow.spec.ts:195 | keeps unchecked access for services provided on the root ctx | ported |
| core/tests/shadow.spec.ts:226 | exposes the caller without preserving shadow for noShadow services | ported |
| core/tests/shadow.spec.ts:271 | exposes the caller to callable services | ported |
| core/tests/shadow.spec.ts:313 | strips service shadow before creating components | ported (rewritten: upstream `function Consumer` is a constructor (`isConstructor`), so its returned fiber replaces the instance; Lua uses a `cordis.class` whose constructor returns the fiber) |
| core/tests/shadow.spec.ts:349 | keeps the def site when a service derives from its own ctx | ported (upstream 86f59e4; holds without a library change: context.lua `extend` keeps the def site of a shadow) |
| core/tests/update.spec.ts:7 | [each] settles concurrent updates on the latest config (inject: %s) | ported |
| core/tests/update.spec.ts:54 | skips superseded loads before executing the component | ported |
| core/tests/update.spec.ts:69 | coalesces updates during unloading | ported |
| core/tests/update.spec.ts:96 | [each] honors %s while loading even when config is unchanged | ported |
| core/tests/update.spec.ts:121 | cleans up a superseded failure without failing the latest update | ported |
| core/tests/update.spec.ts:152 | rejects all waiting updates when the latest load fails | ported |
| core/tests/update.spec.ts:188 | stops advancing an outdated async generator and collects its final yield | ported |
| core/tests/update.spec.ts:212 | waits for dependencies and loads only the latest config | ported |
| core/tests/update.spec.ts:234 | does not restart when a listener accepts an update during loading | ported |
| core/tests/update.spec.ts:259 | does not load a queued config after disposal | ported |
| core/tests/utils.spec.ts:10 | iterates unshifted entries before pushed ones | ported |
| core/tests/utils.spec.ts:20 | disposer removes its own entry after a later push | ported |
| core/tests/utils.spec.ts:32 | disposer removes its own entry after a later unshift | ported |
| core/tests/utils.spec.ts:44 | delete removes the entry it was given | ported |
| core/tests/utils.spec.ts:54 | delete removes an unshifted entry | ported |
| core/tests/utils.spec.ts:64 | clear removes every entry and returns them in order | ported |

# Port status: upstream `packages/timer/tests`

Same rules as above. Specs live in `test/timer/<file>_spec.lua`.

| upstream | case | status |
|---|---|---|
| timer/tests/index.spec.ts:22 | basic support | ported |
| timer/tests/index.spec.ts:32 | dispose | ported |
| timer/tests/index.spec.ts:41 | promise | ported |
| timer/tests/index.spec.ts:59 | basic support | ported |
| timer/tests/index.spec.ts:72 | async iterator (manual return) | ported (rewritten: no for-await; `return` is a keyword) |
| timer/tests/index.spec.ts:95 | async iterator (concurrent reads) | ported (rewritten: no for-await; `return` is a keyword) |
| timer/tests/index.spec.ts:117 | async iterator (return with concurrent reads) | ported (rewritten: no for-await; `return` is a keyword) |
| timer/tests/index.spec.ts:130 | async iterator (throw with concurrent reads) | ported (rewritten: no for-await; `return` is a keyword) |
| timer/tests/index.spec.ts:140 | async iterator (manual throw) | ported (rewritten: no for-await; `return` is a keyword) |
| timer/tests/index.spec.ts:163 | async iterator (break return) | ported (rewritten: no for-await; `return` is a keyword) |
| timer/tests/index.spec.ts:187 | async iterator (break throw) | ported (rewritten: no for-await; `return` is a keyword) |
| timer/tests/index.spec.ts:211 | async iterator (context dispose) | ported (rewritten: no for-await; `return` is a keyword) |
| timer/tests/index.spec.ts:240 | async iterator (context dispose with concurrent reads) | ported (rewritten: no for-await; `return` is a keyword) |
| timer/tests/index.spec.ts:257 | basic support | ported |
| timer/tests/index.spec.ts:272 | trailing mode | ported |
| timer/tests/index.spec.ts:286 | no trailing mode | ported |
| timer/tests/index.spec.ts:300 | uses elapsed time when the wall clock moves backwards | ported (rewritten: the wall clock is moved through os.time / os.clock) |
| timer/tests/index.spec.ts:311 | does not release the throttle early when the wall clock moves forwards | ported (rewritten: the wall clock is moved through os.time / os.clock) |
| timer/tests/index.spec.ts:323 | context dispose | ported |
| timer/tests/index.spec.ts:343 | disposed | ported |
| timer/tests/index.spec.ts:355 | disposed with noTrailing | ported |
| timer/tests/index.spec.ts:366 | context dispose with re-entrant callback | ported |
| timer/tests/index.spec.ts:387 | basic support | ported |
| timer/tests/index.spec.ts:402 | disposed | ported |
| timer/tests/index.spec.ts:412 | context dispose | ported |

# Port status: upstream `packages/loader/tests`

Same rules. One row per `it`; each `it.each` parameter row is its own row (151 `it` calls expand to 165 rows). Specs live in `test/loader/<file>_spec.lua`; the test double of upstream `tests/utils.ts` is `test/loader/mock_loader.lua`.

| upstream | case | status |
|---|---|---|
| loader/tests/commit.spec.ts:26 | create reports a created entry with its id assigned | ported |
| loader/tests/commit.spec.ts:43 | update reports the new options together with the previous ones | ported |
| loader/tests/commit.spec.ts:55 | transfer reports the target group | ported |
| loader/tests/commit.spec.ts:65 | update in place does not report a transfer | ported |
| loader/tests/commit.spec.ts:72 | fiber.update from inside the component reports a config change | ported |
| loader/tests/commit.spec.ts:82 | remove reports the removed entry | ported |
| loader/tests/commit.spec.ts:93 | does not mistake a child fiber disposing itself for the entry (#19) | ported |
| loader/tests/commit.spec.ts:107 | does not report anything for reads | ported |
| loader/tests/commit.spec.ts:138 | keeps an entry that another group adopted | ported |
| loader/tests/commit.spec.ts:202 | reports a removal to the source tree and a creation to the target tree | ported |
| loader/tests/commit.spec.ts:224 | transfers the entry to the store of the target tree | ported |
| loader/tests/commit.spec.ts:250 | transfers the members of a transferred group | ported |
| loader/tests/commit.spec.ts:276 | rejects a transfer onto an id that the target tree already uses | ported |
| loader/tests/commit.spec.ts:296 | does not persist child disposal while the tree loses its loader | ported |
| loader/tests/commit.spec.ts:346 | logs a config change from outside the component | ported |
| loader/tests/commit.spec.ts:355 | does not log an update by the component itself | ported |
| loader/tests/evaluate.spec.ts:39 | creates no outer fiber for an entry without inject | ported |
| loader/tests/evaluate.spec.ts:48 | nests the inner fiber under the outer fiber | ported |
| loader/tests/evaluate.spec.ts:63 | evaluates disabled with the entry inject | ported (rewritten: Lua expressions) |
| loader/tests/evaluate.spec.ts:83 | decides disabled before the component dependencies | ported (rewritten: Lua expressions) |
| loader/tests/evaluate.spec.ts:100 | waits for the entry inject while it is missing | ported (rewritten: Lua expressions) |
| loader/tests/evaluate.spec.ts:118 | treats a failing expression as disabled | ported |
| loader/tests/evaluate.spec.ts:130 | evaluates inject values in the parent context | ported |
| loader/tests/evaluate.spec.ts:147 | cannot read the entry inject from an inject value | ported |
| loader/tests/evaluate.spec.ts:160 | keeps an inject value on the outer fiber when the component declares the service itself | ported |
| loader/tests/evaluate.spec.ts:175 | evaluates intercept with the entry inject, for the component only | ported |
| loader/tests/evaluate.spec.ts:189 | updates intercept in place | ported (rewritten: Lua expressions) |
| loader/tests/evaluate.spec.ts:205 | keeps the options when a dependency is lost and recovered | ported (rewritten: Lua expressions) |
| loader/tests/evaluate.spec.ts:228 | reloads the outer fiber when the verdict changes | ported (rewritten: Lua expressions) |
| loader/tests/evaluate.spec.ts:249 | rebuilds the entry when inject changes | ported |
| loader/tests/evaluate.spec.ts:270 | disposes the outer fiber when the component disposes itself | ported |
| loader/tests/evaluate.spec.ts:286 | disposes both fibers when the entry is removed | ported |
| loader/tests/evaluate.spec.ts:301 | keeps a group structural and passes its verdict to the children | ported (rewritten: Lua expressions) |
| loader/tests/evaluate.spec.ts:321 | keeps the entry isolate without an inject | ported (rewritten: Lua expressions) |
| loader/tests/evaluate.spec.ts:339 | rebuilds without a write-back when inject is added | ported |
| loader/tests/evaluate.spec.ts:352 | drops an activation whose dependency is lost during the import | ported |
| loader/tests/evaluate.spec.ts:380 | re-evaluates a failing inject value on refresh | ported |
| loader/tests/evaluate.spec.ts:394 | caches the verdict independently of reads and service mutations (group=false) | ported (rewritten: the counting getter is a metatable `__index` on the service table) |
| loader/tests/evaluate.spec.ts:394 | caches the verdict independently of reads and service mutations (group=true) | ported (rewritten: the counting getter is a metatable `__index` on the service table) |
| loader/tests/evaluate.spec.ts:427 | does not repeat a failing disabled expression when its verdict is read | ported (rewritten: Lua expressions) |
| loader/tests/evaluate.spec.ts:438 | evaluates a changed disabled expression once in either direction | ported (rewritten: Lua expressions) |
| loader/tests/evaluate.spec.ts:462 | invalidates the verdict before an asynchronous dependency unload | ported (rewritten: Lua expressions) |
| loader/tests/evaluate.spec.ts:496 | keeps a disabled group verdict undecided when its dependency disappears | ported (rewritten: Lua expressions) |
| loader/tests/evaluate.spec.ts:514 | re-evaluates disabled in the new parent context after a transfer | ported (rewritten: Lua expressions) |
| loader/tests/evaluate.spec.ts:514 | re-evaluates inject in the new parent context after a transfer | ported (rewritten: Lua expressions) |
| loader/tests/evaluate.spec.ts:540 | re-evaluates the verdict after changing the entry isolation | ported (rewritten: Lua expressions) |
| loader/tests/evaluate.spec.ts:558 | drops entries removed or disabled during import | ported (rewritten: `vi.spyOn(Entry.prototype, '_patchContext')` replaces the class method for the duration of the case) |
| loader/tests/evaluate.spec.ts:558 | drops entries removed or disabled during patch | ported (rewritten: `vi.spyOn(Entry.prototype, '_patchContext')` replaces the class method for the duration of the case) |
| loader/tests/evaluate.spec.ts:652 | does not start the component when intercept cannot be evaluated | ported |
| loader/tests/evaluate.spec.ts:664 | disposes the component when intercept stops evaluating on an update | ported |
| loader/tests/evaluate.spec.ts:692 | stops a group whose intercept stops evaluating on an update | ported |
| loader/tests/evaluate.spec.ts:711 | does not evaluate intercept while disabled | ported (rewritten: Lua expressions) |
| loader/tests/evaluate.spec.ts:724 | cannot read a service outside the parent context and the entry inject in disabled | ported (rewritten: Lua expressions) |
| loader/tests/evaluate.spec.ts:737 | cannot read a service provided by a sibling in an inject value | ported |
| loader/tests/evaluate.spec.ts:748 | evaluates config with the component inject | ported |
| loader/tests/evaluate.spec.ts:762 | cannot read a service outside every inject in config | ported |
| loader/tests/group.spec.ts:27 | initialize | ported |
| loader/tests/group.spec.ts:52 | disable inner | ported |
| loader/tests/group.spec.ts:60 | disable outer | ported |
| loader/tests/group.spec.ts:68 | enable inner | ported |
| loader/tests/group.spec.ts:76 | enable outer | ported |
| loader/tests/group.spec.ts:109 | initialize | ported |
| loader/tests/group.spec.ts:138 | enabled -> enabled | ported |
| loader/tests/group.spec.ts:146 | enabled -> disabled | ported (rewritten: timing — the disposal is awaited to quiescence; upstream sees it settle within the microtasks of the update) |
| loader/tests/group.spec.ts:154 | disabled -> disabled | ported |
| loader/tests/group.spec.ts:162 | disabled -> enabled | ported |
| loader/tests/group.spec.ts:201 | keeps an entry transferred out of a removed group (inject=undefined) | ported |
| loader/tests/group.spec.ts:201 | keeps an entry transferred out of a removed group (inject=['settings']) | ported |
| loader/tests/group.spec.ts:215 | keeps an entry transferred by a config file out of a removed group | ported |
| loader/tests/group.spec.ts:225 | leaves nothing to a former group after the entry disposes itself | ported |
| loader/tests/group.spec.ts:236 | transfers an entry into a group that is being rebuilt | ported |
| loader/tests/group.spec.ts:264 | initialize | ported |
| loader/tests/group.spec.ts:279 | config update settles children | ported |
| loader/tests/group.spec.ts:330 | initialize | ported |
| loader/tests/import.spec.ts:25 | keep the hints of Node after the first line | ported (rewritten: require stands for Node's module loader) |
| loader/tests/import.spec.ts:42 | leave a module imported by another one to Node | ported (rewritten: require stands for Node's module loader) |
| loader/tests/index.spec.ts:10 | evaluates the expression instead of treating the node as truthy | ported |
| loader/tests/index.spec.ts:43 | loader initiate | ported |
| loader/tests/index.spec.ts:71 | loader update | ported |
| loader/tests/index.spec.ts:90 | component self-update | ported |
| loader/tests/index.spec.ts:103 | component self-dispose | ported |
| loader/tests/index.spec.ts:139 | pending | ported |
| loader/tests/index.spec.ts:162 | resolved | ported |
| loader/tests/index.spec.ts:188 | on load | ported |
| loader/tests/index.spec.ts:201 | on config update | ported |
| loader/tests/index.spec.ts:215 | on an id containing the separator | ported |
| loader/tests/index.spec.ts:247 | wait for dependencies | ported |
| loader/tests/index.spec.ts:261 | evaluate after dependencies are ready | ported |
| loader/tests/index.spec.ts:279 | re-evaluate when dependencies reload | ported |
| loader/tests/index.spec.ts:287 | keep the source config unevaluated | ported |
| loader/tests/index.spec.ts:307 | skip nested components | ported |
| loader/tests/index.spec.ts:344 | fail with dependencies available | ported |
| loader/tests/index.spec.ts:360 | recover through update | ported |
| loader/tests/index.spec.ts:383 | persist an update to a pending fiber | ported |
| loader/tests/index.spec.ts:436 | keep children enabled when the parent loses a dependency | ported |
| loader/tests/index.spec.ts:451 | keeps the entry of a component replaced in place | ported |
| loader/tests/isolate-provide.spec.ts:52 | keeps self access while the provision context changes realms | ported |
| loader/tests/isolate-provide.spec.ts:70 | reloads a self-provider after an isolate-only transfer | ported |
| loader/tests/isolate-provide.spec.ts:107 | keeps an impl that reused the abandoned symbol | ported |
| loader/tests/isolate-provide.spec.ts:144 | retains a transferred provider until its consumers finish cleanup | ported |
| loader/tests/isolate-provide.spec.ts:187 | keeps impls on intermediate symbols across repeated transfers | ported |
| loader/tests/isolate-provide.spec.ts:246 | does not delete another realm when one impl is transferred | ported |
| loader/tests/isolate-provide.spec.ts:281 | reports the service of each realm when a provider is transferred | ported (rewritten: an `undefined` service value is recorded as `cordis.null`, as a list cannot hold nil) |
| loader/tests/isolate-provide.spec.ts:304 | keeps a provider pinned by an isolated context when its entry is transferred | ported |
| loader/tests/isolate-provide.spec.ts:332 | notifies the retained realm on fiber disposal after a blocked transfer | ported (rewritten: an `undefined` service value is recorded as `cordis.null`, as a list cannot hold nil) |
| loader/tests/isolate-provide.spec.ts:332 | notifies the retained realm on provide disposal after a blocked transfer | ported (rewritten: an `undefined` service value is recorded as `cordis.null`, as a list cannot hold nil) |
| loader/tests/isolate.spec.ts:38 | initiate | ported |
| loader/tests/isolate.spec.ts:47 | add isolate on injector (relevant) | ported |
| loader/tests/isolate.spec.ts:59 | add isolate on injector (irrelevant) | ported |
| loader/tests/isolate.spec.ts:72 | remove isolate on injector (relevant) | ported |
| loader/tests/isolate.spec.ts:84 | remove isolate on injector (irrelevant) | ported |
| loader/tests/isolate.spec.ts:94 | add isolate on provider (relevant) | ported |
| loader/tests/isolate.spec.ts:106 | add isolate on provider (irrelevant) | ported |
| loader/tests/isolate.spec.ts:119 | remove isolate on provider (relevant) | ported |
| loader/tests/isolate.spec.ts:131 | remove isolate on provider (irrelevant) | ported |
| loader/tests/isolate.spec.ts:172 | add isolate group | ported |
| loader/tests/isolate.spec.ts:201 | update isolate group (no change) | ported |
| loader/tests/isolate.spec.ts:218 | realm reference | ported |
| loader/tests/isolate.spec.ts:251 | special case: nested realms | ported |
| loader/tests/isolate.spec.ts:326 | special case: change provider | ported |
| loader/tests/isolate.spec.ts:390 | special case: change injector | ported |
| loader/tests/isolate.spec.ts:490 | initiate | ported |
| loader/tests/isolate.spec.ts:507 | transfer injector into group | ported |
| loader/tests/isolate.spec.ts:515 | transfer provider into group | ported |
| loader/tests/isolate.spec.ts:523 | transfer injector out of group | ported |
| loader/tests/isolate.spec.ts:531 | transfer provider out of group | ported |
| loader/tests/isolate.spec.ts:541 | keeps the committed views of a parent and a pinned child across a realm transfer | ported |
| loader/tests/rebuild.spec.ts:45 | rebuilds an active entry when its name changes (inject=undefined) | ported |
| loader/tests/rebuild.spec.ts:45 | rebuilds an active entry when its name changes (inject=['settings']) | ported |
| loader/tests/rebuild.spec.ts:59 | uses the new name when it changes during the import | ported (rewritten: `vi.spyOn(Entry.prototype, '_patchContext')` replaces the class method for the duration of the case) |
| loader/tests/rebuild.spec.ts:59 | uses the new name when it changes during the patch | ported (rewritten: `vi.spyOn(Entry.prototype, '_patchContext')` replaces the class method for the duration of the case) |
| loader/tests/rebuild.spec.ts:101 | joins a second rename while the first disposal is pending (inject=undefined) | ported |
| loader/tests/rebuild.spec.ts:101 | joins a second rename while the first disposal is pending (inject=['settings']) | ported |
| loader/tests/rebuild.spec.ts:121 | applies nothing when the entry is removed during the disposal | ported |
| loader/tests/rebuild.spec.ts:143 | rebuilds when the component renames its own entry | ported |
| loader/tests/rebuild.spec.ts:163 | starts a pending entry when inject is cleared | ported |
| loader/tests/rebuild.spec.ts:190 | reapplies when inject gains a service that is already provided | ported |
| loader/tests/rebuild.spec.ts:217 | keeps the new outer fiber pending and drops the old listener when inject is missing | ported |
| loader/tests/rebuild.spec.ts:247 | joins a second inject update while the first rebuild is disposing | ported |
| loader/tests/rebuild.spec.ts:284 | uses the latest name during a pending import | ported (rewritten: `vi.spyOn(Entry.prototype, '_patchContext')` replaces the class method for the duration of the case) |
| loader/tests/rebuild.spec.ts:284 | uses the latest name during a pending failed import | ported (rewritten: `vi.spyOn(Entry.prototype, '_patchContext')` replaces the class method for the duration of the case) |
| loader/tests/rebuild.spec.ts:284 | uses the latest name during a pending context patch | ported (rewritten: `vi.spyOn(Entry.prototype, '_patchContext')` replaces the class method for the duration of the case) |
| loader/tests/rebuild.spec.ts:332 | does not apply a fiber removed while rebuild is disposing | ported |
| loader/tests/rebuild.spec.ts:359 | keeps a rebuild started during apply until its disposer settles | ported |
| loader/tests/resolve.spec.ts:48 | resolves bare specifiers against the project, not the loader | n/a: Node ESM resolution helper (.cordis/resolve.mjs, bare and relative specifiers, drive letters); Lua uses require |
| loader/tests/resolve.spec.ts:59 | keeps subpath imports and self references working | n/a: Node ESM resolution helper (.cordis/resolve.mjs, bare and relative specifiers, drive letters); Lua uses require |
| loader/tests/resolve.spec.ts:66 | anchors the helper at the package.json, not at the base url | n/a: Node ESM resolution helper (.cordis/resolve.mjs, bare and relative specifiers, drive letters); Lua uses require |
| loader/tests/resolve.spec.ts:73 | makes the helper directory ignore itself | n/a: Node ESM resolution helper (.cordis/resolve.mjs, bare and relative specifiers, drive letters); Lua uses require |
| loader/tests/resolve.spec.ts:80 | reuses one helper per scope | n/a: Node ESM resolution helper (.cordis/resolve.mjs, bare and relative specifiers, drive letters); Lua uses require |
| loader/tests/resolve.spec.ts:87 | declines when there is no project to anchor to | n/a: Node ESM resolution helper (.cordis/resolve.mjs, bare and relative specifiers, drive letters); Lua uses require |
| loader/tests/resolve.spec.ts:135 | reuses an identical helper without attempting rename | n/a: Node ESM resolution helper (.cordis/resolve.mjs, bare and relative specifiers, drive letters); Lua uses require |
| loader/tests/resolve.spec.ts:148 | retries a stale helper after EACCES | n/a: Node ESM resolution helper (.cordis/resolve.mjs, bare and relative specifiers, drive letters); Lua uses require |
| loader/tests/resolve.spec.ts:148 | retries a stale helper after EPERM | n/a: Node ESM resolution helper (.cordis/resolve.mjs, bare and relative specifiers, drive letters); Lua uses require |
| loader/tests/resolve.spec.ts:148 | retries a stale helper after EBUSY | n/a: Node ESM resolution helper (.cordis/resolve.mjs, bare and relative specifiers, drive letters); Lua uses require |
| loader/tests/resolve.spec.ts:158 | cleans up after EBUSY and recovers on a later call | n/a: Node ESM resolution helper (.cordis/resolve.mjs, bare and relative specifiers, drive letters); Lua uses require |
| loader/tests/resolve.spec.ts:158 | cleans up after ENOSPC and recovers on a later call | n/a: Node ESM resolution helper (.cordis/resolve.mjs, bare and relative specifiers, drive letters); Lua uses require |
| loader/tests/resolve.spec.ts:190 | routes bare specifiers to the project helper | n/a: Node ESM resolution helper (.cordis/resolve.mjs, bare and relative specifiers, drive letters); Lua uses require |
| loader/tests/resolve.spec.ts:197 | still resolves relative specifiers against the base url | n/a: Node ESM resolution helper (.cordis/resolve.mjs, bare and relative specifiers, drive letters); Lua uses require |
| loader/tests/resolve.spec.ts:205 | accepts a drive-letter path | n/a: Node ESM resolution helper (.cordis/resolve.mjs, bare and relative specifiers, drive letters); Lua uses require |
| loader/tests/validate.spec.ts:9 | accept valid options | ported |
| loader/tests/validate.spec.ts:27 | reject a missing or invalid field | ported (rewritten: an empty table is both an array and an object, so the non-array / non-object cases use non-empty tables; issue paths count from 1) |
| loader/tests/validate.spec.ts:41 | accept an expression only for disabled | ported |
| loader/tests/validate.spec.ts:52 | reject invalid options at runtime before they are committed | ported |
| loader/tests/validate.spec.ts:71 | check the entries of a group passed at runtime as a whole | ported (rewritten: the `null` entry is `cordis.null`; issue paths count from 1) |
| loader/tests/validate.spec.ts:96 | unload an entry whose options turn invalid, and reload it once fixed | ported |
