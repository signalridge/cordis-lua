-- Library-own tests: public introspection and event adapter APIs.
local cordis = require("cordis")
local U = require("kit.util")
local spy = require("kit.spy")
local Context = cordis.Context
local FiberState = cordis.FiberState
local Future = cordis.Future

describe("public introspection and adapter APIs", function()
  describe("EventsService:resolve", function()
    it("resolves hooks as an independent copy, filters by thisArg, and notifies internal/dispatch", function()
      local root = U.root()
      local dispatches = {}
      root:on("internal/dispatch", function(mode, name, args, thisArg)
        dispatches[#dispatches + 1] = { mode = mode, name = name, args = args, thisArg = thisArg }
      end)

      local cb1 = spy.fn()
      local cb2 = spy.fn()
      local cbGlobal = spy.fn()
      local subA = root:extend({ tag = "a" })
      local subB = root:extend({ tag = "b" })
      subA:on("ev", cb1)
      subB:on("ev", cb2)
      subB:on("ev", cbGlobal, { global = true })

      -- plain resolution without thisArg returns all hooks in order
      local thisArg, hooks, name, args = root.events:resolve("serial", "ev", 10, nil, 30)
      expect(thisArg).to.equal(nil)
      expect(name).to.equal("ev")
      expect(args.n).to.equal(3)
      expect(args[1]).to.equal(10)
      expect(args[2]).to.equal(nil)
      expect(args[3]).to.equal(30)
      expect(#hooks).to.equal(3)
      expect(hooks[1].ctx).to.equal(subA)
      expect(hooks[2].ctx).to.equal(subB)
      expect(hooks[3].global).to.equal(true)

      -- mutating returned array does not affect internal state or subsequent resolves
      hooks[#hooks + 1] = { callback = spy.fn() }
      local _, hooksAgain = root.events:resolve("emit", "ev")
      expect(#hooksAgain).to.equal(3)

      -- mutating an empty resolve result does not leak to other events
      local _, emptyHooks = root.events:resolve("emit", "missing")
      expect(#emptyHooks).to.equal(0)
      emptyHooks[1] = { callback = spy.fn() }
      local _, stillEmpty = root.events:resolve("emit", "missing2")
      expect(#stillEmpty).to.equal(0)

      -- thisArg filter keeps matching hooks and global hooks
      local target = cordis.proto.create(nil, {
        [Context.filter] = function(_, ctx)
          return ctx.tag == "a"
        end,
      })
      local resolvedThis, filtered, resolvedName, resolvedArgs = root.events:resolve("bail", target, "ev", "x")
      expect(resolvedThis).to.equal(target)
      expect(resolvedName).to.equal("ev")
      expect(resolvedArgs.n).to.equal(1)
      expect(resolvedArgs[1]).to.equal("x")
      expect(#filtered).to.equal(2)
      expect(filtered[1].ctx).to.equal(subA)
      expect(filtered[2].global).to.equal(true)

      -- internal/* events do not trigger internal/dispatch
      local before = #dispatches
      root.events:resolve("emit", "internal/custom", 1)
      expect(#dispatches).to.equal(before)
      expect(dispatches[1].mode).to.equal("serial")
      expect(dispatches[1].name).to.equal("ev")
      expect(dispatches[1].args.n).to.equal(3)

      -- private _resolve is removed
      expect(root.events._resolve).to.equal(nil)
    end)
  end)

  describe("EventsService:listeners and :listenerCount", function()
    it("returns independent hook copies in dispatch order and accurate counts", function()
      local root = U.root()
      local sym = cordis.symbol("custom")

      expect(root.events:listeners("ev")).to.deep.equal({})
      expect(root.events:listenerCount("ev")).to.equal(0)

      local f1 = root:use(function(ctx)
        ctx:on("ev", function() end)
      end)
      local f2 = root:use(function(ctx)
        ctx:on("ev", function() end, { prepend = true })
      end)
      local dSym = root:on(sym, function() end)
      cordis.await(f1)
      cordis.await(f2)

      expect(root.events:listenerCount("ev")).to.equal(2)
      expect(root.events:listenerCount(sym)).to.equal(1)

      local list = root.events:listeners("ev")
      expect(#list).to.equal(2)
      expect(list[1].ctx.fiber).to.equal(f2)
      expect(list[1].prepend).to.equal(true)
      expect(list[2].ctx.fiber).to.equal(f1)

      -- mutating returned copy does not mutate internal hook list
      list[1] = nil
      list[3] = { callback = function() end }
      expect(root.events:listenerCount("ev")).to.equal(2)
      expect(#root.events:listeners("ev")).to.equal(2)

      -- disposing removes listeners from both listeners() and listenerCount()
      cordis.await(f2:dispose())
      dSym()
      expect(root.events:listenerCount("ev")).to.equal(1)
      expect(root.events:listeners("ev")[1].ctx.fiber).to.equal(f1)
      expect(root.events:listenerCount(sym)).to.equal(0)
      expect(root.events:listeners(sym)).to.deep.equal({})
    end)
  end)

  describe("Fiber.error", function()
    it("exposes load failure as a read-only property and clears on recovery", function()
      local root = U.root()
      root.logger.error = spy.fn()
      local boom = cordis.Error.new("boom")

      expect(root.fiber.error).to.equal(nil)

      local shouldFail = true
      local fiber = root:use(function()
        if shouldFail then
          error(boom, 0)
        end
      end, { n = 1 })

      local ok, err = pcall(cordis.await, fiber)
      expect(ok).to.equal(false)
      expect(rawequal(err, boom)).to.equal(true)
      expect(fiber.state).to.equal(FiberState.FAILED)
      expect(rawequal(fiber.error, boom)).to.equal(true)

      -- error property is read-only
      expect(function()
        fiber.error = "overwrite"
      end).to.throw('cannot set read-only property "error"')
      expect(rawequal(fiber.error, boom)).to.equal(true)

      -- update clears error on recovery
      shouldFail = false
      cordis.await(fiber:update({ n = 2 }))
      expect(fiber.state).to.equal(FiberState.ACTIVE)
      expect(fiber.error).to.equal(nil)
    end)

    it("clears error on registry:replace recovery", function()
      local root = U.root()
      root.logger.error = spy.fn()
      local boom = cordis.Error.new("replace boom")
      local bad = function()
        error(boom, 0)
      end
      local good = function() end

      local fiber = root:use(bad)
      pcall(cordis.await, fiber)
      expect(fiber.state).to.equal(FiberState.FAILED)
      expect(rawequal(fiber.error, boom)).to.equal(true)

      root.registry:replace(bad, good)
      cordis.await(fiber)
      expect(fiber.state).to.equal(FiberState.ACTIVE)
      expect(fiber.error).to.equal(nil)
    end)
  end)

  describe("Fiber:pending", function()
    it("lists missing injected services in declaration order and updates with provider state", function()
      local root = U.root()
      expect(root.fiber:pending()).to.deep.equal({})

      local consumer = root:use({
        inject = { "alpha", "beta", "gamma" },
        apply = function() end,
      })
      U.sleep(0)
      expect(consumer.state).to.equal(FiberState.PENDING)
      local missing = consumer:pending()
      expect(missing).to.deep.equal({ "alpha", "beta", "gamma" })

      -- mutating returned list does not affect fiber
      missing[1] = "mutated"
      expect(consumer:pending()).to.deep.equal({ "alpha", "beta", "gamma" })

      -- a service failing its check predicate remains pending
      local allowAlpha = false
      local dAlpha = root:provide("alpha", { ok = true }, function()
        return allowAlpha
      end)
      expect(consumer:pending()).to.deep.equal({ "alpha", "beta", "gamma" })

      allowAlpha = true
      root.reflect:notify({ "alpha" })
      expect(consumer:pending()).to.deep.equal({ "beta", "gamma" })

      -- a service provided by a still-LOADING fiber remains pending until ACTIVE
      local gate, openGate = Future.withResolvers(U.host())
      local started, markStarted = Future.withResolvers(U.host())
      local betaFiber = root:use(cordis.async(function(ctx)
        ctx:provide("beta", { v = 2 })
        markStarted()
        gate:await()
      end))
      started:await()
      expect(betaFiber.state).to.equal(FiberState.LOADING)
      expect(consumer:pending()).to.deep.equal({ "beta", "gamma" })

      openGate()
      cordis.await(betaFiber)
      expect(consumer:pending()).to.deep.equal({ "gamma" })

      local dGamma = root:provide("gamma", { v = 3 })
      cordis.await(consumer)
      expect(consumer.state).to.equal(FiberState.ACTIVE)
      expect(consumer:pending()).to.deep.equal({})

      -- withdrawing a dependency puts it back into pending()
      cordis.await(dGamma())
      expect(consumer:pending()).to.deep.equal({ "gamma" })

      cordis.await(dAlpha())
    end)
  end)

  describe("ReflectService:getImpl", function()
    it("supports occupancy, ownership, strictness, and isolation checks", function()
      local root = U.root()

      expect(root.reflect:getImpl("svc")).to.equal(nil)
      expect(root.reflect:getImpl("svc", false)).to.equal(nil)

      -- placeholder provision with value == nil: get(name, false) is nil, getImpl(name, false) is non-nil
      local gate, openGate = Future.withResolvers(U.host())
      local started, markStarted = Future.withResolvers(U.host())
      local ownerFiber = root:use(cordis.async(function(ctx)
        ctx:provide("svc", nil)
        markStarted()
        gate:await()
      end))
      started:await()

      expect(ownerFiber.state).to.equal(FiberState.LOADING)
      expect(root:get("svc", false)).to.equal(nil)
      -- strict defaults to true: LOADING provider is hidden
      expect(root.reflect:getImpl("svc")).to.equal(nil)
      expect(root.reflect:getImpl("svc", true)).to.equal(nil)
      -- strict = false exposes occupied slot and provider ownership
      local impl = root.reflect:getImpl("svc", false)
      expect(impl ~= nil).to.equal(true)
      expect(impl.name).to.equal("svc")
      expect(impl.ctx.fiber).to.equal(ownerFiber)
      expect(impl.value).to.equal(nil)

      -- once ACTIVE, strict = true returns the same impl
      openGate()
      cordis.await(ownerFiber)
      local activeImpl = root.reflect:getImpl("svc")
      expect(activeImpl).to.equal(impl)
      expect(activeImpl.ctx.fiber).to.equal(ownerFiber)

      -- isolation scopes getImpl independently
      local isolated = root:isolate("svc")
      expect(isolated.reflect:getImpl("svc", false)).to.equal(nil)
      local isoFiber = cordis.await(isolated:use(function(ctx)
        ctx:provide("svc", { isolated = true })
      end))
      local isoImpl = isolated.reflect:getImpl("svc", false)
      expect(isoImpl ~= nil).to.equal(true)
      expect(isoImpl.ctx.fiber).to.equal(isoFiber)
      expect(isoImpl.ctx.fiber ~= ownerFiber).to.equal(true)
      expect(root.reflect:getImpl("svc", false).ctx.fiber).to.equal(ownerFiber)

      -- private _getImpl is removed
      expect(root.reflect._getImpl).to.equal(nil)
    end)
  end)
end)
