-- Tests for fixes to upstream behavior (docs/deviations.md). Each case
-- fails against the upstream behaviour at the commit in UPSTREAM.
local cordis = require("cordis")
local U = require("kit.util")
local spy = require("kit.spy")
local FiberState = cordis.FiberState

describe("fix-type deviations", function()
  -- fiber.ts:329,355 registers the effect wrapper only after setup
  it("an unload started inside effect setup still disposes that effect", function()
    local root = U.root()
    local fiber = cordis.await(root:use(function() end))
    local cleanup = spy.fn()
    fiber.ctx:effect(function()
      -- unloads the owner synchronously while this setup is still running
      fiber:dispose()
      return cleanup
    end)
    U.sleep(0)
    expect(fiber.state).to.equal(FiberState.DISPOSED)
    expect(cleanup.calls).to.have.length(1)
  end)

  it("a failed synchronous setup leaves no wrapper behind", function()
    local root = U.root()
    local fiber = cordis.await(root:use(function() end))
    local before = #fiber:getEffects()
    expect(function()
      fiber.ctx:effect(function()
        error(cordis.Error.new("setup failed"))
      end)
    end).to.throw("setup failed")
    expect(#fiber:getEffects()).to.equal(before)
  end)

  -- fiber.ts:231-234 only checks `uid`; effects created while UNLOADING
  -- escape the `_unload` snapshot (`:492`)
  it("effects cannot be created while the fiber is unloading", function()
    local root = U.root()
    root.logger.error = spy.fn()
    local leaked = spy.fn()
    local result = {}
    local fiber = root:use(function(ctx)
      return function()
        result.state = ctx.fiber.state
        result.ok, result.err = pcall(function()
          ctx:effect(function()
            return leaked
          end)
        end)
      end
    end)
    cordis.await(fiber)
    cordis.await(fiber:restart())
    expect(result.state).to.equal(FiberState.UNLOADING)
    expect(result.ok).to.equal(false)
    expect(result.err.message).to.equal("cannot create effect on inactive context")
    expect(fiber.state).to.equal(FiberState.ACTIVE)
    -- nothing leaked into the reloaded fiber: only the component's own disposer
    expect(fiber._disposables:length()).to.equal(1)
  end)

  -- fiber.ts:172,178 publishes internal/plugin before `dispose` exists
  it("internal/plugin observers see a fiber that can already be disposed", function()
    local root = U.root()
    local seen = {}
    root:on("internal/plugin", function(fiber)
      if fiber.uid ~= nil then
        seen[#seen + 1] = fiber.dispose ~= nil
      end
    end)
    local fiber = root:use(function() end)
    expect(seen).to.deep.equal({ true })
    cordis.await(fiber)
  end)

  -- events.ts:119-124 with fiber.ts:188: one throwing observer on the
  -- dispose path skips unregistration and the epoch update
  it("a throwing internal/plugin observer does not interrupt disposal", function()
    local root = U.root()
    local logged = spy.fn()
    root.logger.error = logged
    local later = spy.fn()
    root:on("internal/plugin", function(fiber)
      if fiber.uid == nil then
        error(cordis.Error.new("observer failed"))
      end
    end)
    root:on("internal/plugin", later)
    local cleanup = spy.fn()
    local component = function()
      return cleanup
    end
    local fiber = cordis.await(root:use(component))
    later:reset()
    cordis.await(fiber:dispose())
    expect(later.calls).to.have.length(1)
    expect(root.registry:has(component)).to.equal(false)
    expect(cleanup.calls).to.have.length(1)
    expect(fiber.state).to.equal(FiberState.DISPOSED)
    expect(logged.calls).to.have.length(1)
  end)
end)

describe("release fixes: trace, effects, services, registry", function()
  it("invokes cordis.async and callable-table Service methods through trace proxies and preserves 0 returns", function()
    local root = U.root()
    local MySvc = cordis.class("MySvc", cordis.Service)
    function MySvc:constructor(ctx)
      cordis.Service.constructor(self, ctx, "mysvc")
      self.base = 10
    end
    MySvc.fetch = cordis.async(function(self, x)
      U.sleep(0)
      return self.base + x
    end)
    MySvc.functor = setmetatable({ tag = "ok" }, {
      __call = function(callable, svc, x)
        return callable.tag .. ":" .. tostring(svc.base + x)
      end,
    })
    function MySvc:noop() end
    function MySvc:multi()
      return nil, "second"
    end

    cordis.await(root:use(MySvc))
    expect(root.mysvc:fetch(32):await()).to.equal(42)
    expect(root.mysvc:functor(5)).to.equal("ok:15")
    expect(select("#", root.mysvc:noop())).to.equal(0)
    local n = select("#", root.mysvc:multi())
    local a, b = root.mysvc:multi()
    expect(n).to.equal(2)
    expect(a).to.equal(nil)
    expect(b).to.equal("second")
  end)

  it("settles disposal when an async-suspending effect setup is disposed and its disposer throws", function()
    local root = U.root()
    root.logger.error = spy.fn()
    local fiber = cordis.await(root:use(function() end))
    local gate, open = cordis.Future.withResolvers(U.host())
    local setupDone = false
    cordis.async(function()
      fiber.ctx:effect(function()
        gate:await()
        setupDone = true
        return function()
          error(cordis.Error.new("disposer boom"))
        end
      end)
    end)()
    U.sleep(0)
    local disposing = fiber:dispose()
    U.sleep(0)
    open()
    cordis.await(disposing)
    expect(setupDone).to.equal(true)
    expect(fiber.state).to.equal(FiberState.DISPOSED)
    expect(root.logger.error.calls).to.have.length(1)
  end)

  it("rolls back service binding when an internal/service observer throws during provide", function()
    local root = U.root()
    local shouldThrow = true
    root:on("internal/service", function(_, name)
      if name == "svc" and shouldThrow then
        error(cordis.Error.new("observer boom"))
      end
    end)
    expect(function()
      root:provide("svc", { v = 1 })
    end).to.throw("observer boom")
    expect(root.svc).to.equal(nil)
    shouldThrow = false
    root:provide("svc", { v = 2 })
    expect(root.svc.v).to.equal(2)
    cordis.await(root:close())
  end)

  it("completes all dependency transitions during deactivation even when one observer throws", function()
    local root = U.root()
    root:on("internal/service", function(_, name, val)
      if name == "s1" and val == nil then
        error(cordis.Error.new("s1 deactivate boom"))
      end
    end)
    root:provide("s1", { v = 1 })
    root:provide("s2", { v = 2 })
    local c1 = cordis.await(root:inject({ "s1" }, function() end))
    local c2 = cordis.await(root:inject({ "s2" }, function() end))
    pcall(function()
      root:close()
    end)
    cordis.await(root:close())
    expect(c1.state).to.equal(FiberState.DISPOSED)
    expect(c2.state).to.equal(FiberState.DISPOSED)
    expect(root.fiber.state).to.equal(FiberState.DISPOSED)
  end)

  it("waits for a natively blocking manual disposer before reaching DISPOSED", function()
    local root = U.root()
    local latch = U.host().latch()
    local finished = false
    local disposeEffect
    local fiber = cordis.await(root:use(function(ctx)
      disposeEffect = ctx:effect(function()
        return function()
          latch:wait()
          finished = true
        end
      end)
    end))
    cordis.async(function()
      disposeEffect()
    end)()
    U.sleep(0)
    local disposing = fiber:dispose()
    U.sleep(0)
    expect(finished).to.equal(false)
    expect(fiber.state).to.equal(FiberState.UNLOADING)
    latch:open()
    cordis.await(disposing)
    expect(finished).to.equal(true)
    expect(fiber.state).to.equal(FiberState.DISPOSED)
  end)

  it("joins in-flight cleanup from deferred settingUp disposal and repeated disposeAsync", function()
    local root = U.root()
    local gate1, open1 = cordis.Future.withResolvers(U.host())
    local gate2, open2 = cordis.Future.withResolvers(U.host())
    local done1 = false
    local fiber = cordis.await(root:use(function() end))
    cordis.async(function()
      fiber.ctx:effect(function()
        gate1:await()
        return cordis.async(function()
          gate2:await()
          done1 = true
        end)
      end)
    end)()
    U.sleep(0)
    local disposing = fiber:dispose()
    U.sleep(0)
    open1()
    U.sleep(0)
    expect(done1).to.equal(false)
    expect(fiber.state).to.equal(FiberState.UNLOADING)
    open2()
    cordis.await(disposing)
    expect(done1).to.equal(true)
    expect(fiber.state).to.equal(FiberState.DISPOSED)

    local gate3, open3 = cordis.Future.withResolvers(U.host())
    local d = cordis.await(root:effect(function()
      return function()
        return cordis.async(function()
          gate3:await()
        end)
      end
    end))
    local f1 = d()
    local f2 = d()
    expect(f1).to.equal(f2)
    open3()
    cordis.await(f2)
  end)

  it("runs all remaining iterator disposers in reverse order even when earlier ones fail", function()
    local root = U.root()
    local order = {}
    local disposeSync = root:effect(cordis.iter(function(yield)
      yield(function()
        order[#order + 1] = 1
      end)
      yield(function()
        order[#order + 1] = 2
        error(cordis.Error.new("d2 boom"))
      end)
      yield(function()
        order[#order + 1] = 3
        error(cordis.Error.new("d3 boom"))
      end)
    end))
    local ok, err = pcall(disposeSync)
    expect(ok).to.equal(false)
    expect(err).to.be.instanceof(cordis.AggregateError)
    expect(order).to.deep.equal({ 3, 2, 1 })

    local asyncOrder = {}
    local disposeAsync = root:effect(cordis.iter(function(yield)
      yield(function()
        asyncOrder[#asyncOrder + 1] = "first"
      end)
      yield(cordis.async(function()
        U.sleep(0)
        asyncOrder[#asyncOrder + 1] = "second"
        error(cordis.Error.new("async fail"))
      end))
    end))
    local p = disposeAsync()
    expect(p).to.reject("async fail")
    expect(asyncOrder).to.deep.equal({ "second", "first" })
  end)

  it("does not strand a failed component in LOADING when a log exporter throws", function()
    local root = U.root()
    local cleaned = 0
    root.logger:exporter({
      levels = { default = 3 },
      export = function()
        error("exporter boom")
      end,
    })
    local fiber = root:use(function(ctx)
      ctx:effect(function()
        return function()
          cleaned = cleaned + 1
        end
      end)
      error(cordis.Error.new("apply boom"))
    end)
    expect(fiber:await()).to.reject("apply boom")
    expect(fiber.state).to.equal(FiberState.FAILED)
    expect(cleaned).to.equal(1)
    cordis.await(root:close())
    expect(fiber.state).to.equal(FiberState.DISPOSED)
  end)

  it("revalidates selected service implementation after reentrant check callback", function()
    local root = U.root()
    local withdraw1
    withdraw1 = root:provide("svc", { ver = 1 }, function()
      withdraw1()
      root:provide("svc", { ver = 2 })
      return true
    end)
    local seen
    local consumer = cordis.await(root:inject({ "svc" }, function(ctx)
      seen = ctx.svc.ver
    end))
    expect(root.svc.ver).to.equal(2)
    expect(seen).to.equal(2)
    expect(consumer.ctx.svc.ver).to.equal(2)
  end)

  it("awaits async rollback disposers before settling fiber:dispose() when asyncIter fails", function()
    local root = U.root()
    root.logger.error = spy.fn()
    local rollbackStarted, markRollbackStarted = cordis.Future.withResolvers(U.host())
    local gate, open = cordis.Future.withResolvers(U.host())
    local cleanupFinished = false
    local fiber = root:use(cordis.asyncIter(function(yield)
      yield(cordis.async(function()
        markRollbackStarted()
        gate:await()
        cleanupFinished = true
      end))
      U.sleep(0)
      error(cordis.Error.new("iter boom"))
    end))
    cordis.await(rollbackStarted)
    local disposing = fiber:dispose()
    U.sleep(0)
    expect(cleanupFinished).to.equal(false)
    expect(fiber.state).to.equal(FiberState.UNLOADING)
    open()
    cordis.await(disposing)
    expect(cleanupFinished).to.equal(true)
    expect(fiber.state).to.equal(FiberState.DISPOSED)
  end)

  it("accepts proto objects, metatable __index apply tables, and callable proto proxies in registry", function()
    local root = U.root()
    local seen = {}
    local protoComp = cordis.proto.create(nil, {
      apply = function()
        seen[#seen + 1] = "proto"
      end,
    })
    local mtComp = setmetatable({}, {
      __index = {
        apply = function()
          seen[#seen + 1] = "mt"
        end,
      },
    })
    local boundComp = root.reflect:bind(function()
      seen[#seen + 1] = "bound"
    end)

    cordis.await(root:use(protoComp))
    cordis.await(root:use(mtComp))
    cordis.await(root:use(boundComp))
    expect(seen).to.deep.equal({ "proto", "mt", "bound" })
  end)

  -- events.ts:70-75 shares one _next closure across local internal/update listeners,
  -- allowing an earlier listener calling next() twice to bypass a later listener's veto
  it("internal/update rejects duplicate next() and preserves a later listener veto", function()
    local root = U.root()
    local applyCount = 0
    local vetoCount = 0
    local fiber = cordis.await(root:use(function(ctx)
      applyCount = applyCount + 1
      ctx:on("internal/update", function(_, _, nextFn)
        nextFn()
        return nextFn()
      end)
      ctx:on("internal/update", function()
        vetoCount = vetoCount + 1
        return nil
      end)
    end, { value = 1 }))

    expect(applyCount).to.equal(1)
    expect(function()
      fiber:update({ value = 2 })
    end).to.throw("next() called multiple times")
    U.sleep(0)
    expect(vetoCount).to.equal(1)
    expect(applyCount).to.equal(1)
  end)

  it("internal/update rejects continuations from outer local listener frames", function()
    local root = U.root()
    local applyCount = 0
    local outerNext
    local fiber = cordis.await(root:use(function(ctx)
      applyCount = applyCount + 1
      ctx:on("internal/update", function(_, _, nextFn)
        outerNext = nextFn
        return nextFn()
      end)
      ctx:on("internal/update", function()
        return outerNext()
      end)
    end, { value = 1 }))

    expect(applyCount).to.equal(1)
    expect(function()
      fiber:update({ value = 2 })
    end).to.throw("next() called multiple times")
    U.sleep(0)
    expect(applyCount).to.equal(1)
  end)
end)
