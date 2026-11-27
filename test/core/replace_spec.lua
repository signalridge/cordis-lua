-- Ported from cordis packages/core/tests/replace.spec.ts (MIT, (c) Shigma)
local cordis = require("cordis")
local U = require("kit.util")
local spy = require("kit.spy")
local Future = cordis.Future
local FiberState = cordis.FiberState
local proto = cordis.proto

local function awaitAll(fibers)
  local list = {}
  for i, fiber in ipairs(fibers) do
    list[i] = fiber:await()
  end
  Future.all(U.host(), list):await()
end

local function contains(list, item)
  for _, v in ipairs(list) do
    if v == item then
      return true
    end
  end
  return false
end

describe("registry.replace()", function()
  -- replace.spec.ts:7
  it("swaps the implementation behind a fiber in place", function()
    local root = U.root()
    local disposeOld = spy.fn()
    local old = spy.fn(function(ctx, config)
      return function()
        disposeOld()
      end
    end)
    local nextC = spy.fn()
    local fiber = cordis.await(root:use(old, { foo = 1 }))
    local uid = fiber.uid

    local replaced = root.registry:replace(old, nextC)
    awaitAll(replaced)

    expect(replaced).to.have.length(1)
    expect(disposeOld.calls).to.have.length(1)
    expect(nextC.calls).to.have.length(1)
    expect(nextC.calls[1][2]).to.deep.equal({ foo = 1 })
    -- the reference returned by `ctx.use()` stays valid
    expect(fiber.uid).to.equal(uid)
    expect(fiber.state).to.equal(FiberState.ACTIVE)
    expect(fiber.runtime).to.equal(root.registry:get(nextC))
    local keys = root.registry:keys()
    expect(#keys).to.equal(1)
    expect(keys[1]).to.equal(nextC)
  end)

  -- replace.spec.ts:29
  it("emits internal/replace for each moved fiber", function()
    local root = U.root()
    local old = function() end
    local nextC = function() end
    local runtimes = {}
    root:on("internal/replace", function(fiber)
      runtimes[#runtimes + 1] = fiber.runtime
    end)
    local a = cordis.await(root:use(old))
    local b = cordis.await(root:use(old))

    local replaced = root.registry:replace(old, nextC)
    expect(replaced).to.have.length(2)
    expect(contains(replaced, a)).to.equal(true)
    expect(contains(replaced, b)).to.equal(true)
    -- listeners see the fiber with its new implementation
    expect(runtimes).to.have.length(2)
    expect(runtimes[1]).to.equal(root.registry:get(nextC))
    expect(runtimes[2]).to.equal(root.registry:get(nextC))
  end)

  -- replace.spec.ts:46
  it("validates the config with the new schema", function()
    local root = U.root()
    local function schema(validate)
      return {
        ["~standard"] = {
          version = 1,
          vendor = "test",
          validate = function(value)
            return { value = validate(value) }
          end,
        },
      }
    end
    local function withVersion(v)
      return function(value)
        local r = {}
        for k, x in pairs(value) do
          r[k] = x
        end
        r.version = v
        return r
      end
    end
    local apply = spy.fn()
    local old = { Config = schema(withVersion(1)), apply = function() end }
    local nextC = { Config = schema(withVersion(2)), apply = apply }
    cordis.await(root:use(old, { foo = 1 }))

    awaitAll(root.registry:replace(old, nextC))
    expect(apply.calls[1][2]).to.deep.equal({ foo = 1, version = 2 })
  end)

  -- replace.spec.ts:60
  it("takes the dependencies of the new component", function()
    local root = U.root()
    local old = { apply = function() end }
    local apply = spy.fn()
    local nextC = { inject = { "dep" }, apply = apply }
    local fiber = cordis.await(root:use(old))

    root.registry:replace(old, nextC)
    cordis.await(fiber:await())
    expect(proto.ownKeys(fiber.inject)).to.deep.equal({ "dep" })
    expect(fiber.state).to.equal(FiberState.PENDING)
    expect(apply.calls).to.have.length(0)

    root:provide("dep", {})
    cordis.await(fiber:await())
    expect(fiber.state).to.equal(FiberState.ACTIVE)
    expect(apply.calls).to.have.length(1)
  end)

  -- replace.spec.ts:79
  it("starts a pending fiber when the new component drops the missing dependency", function()
    local root = U.root()
    local old = { inject = { "missing" }, apply = function() end }
    local nextC = spy.fn()
    local fiber = cordis.await(root:use(old))
    expect(fiber.state).to.equal(FiberState.PENDING)

    root.registry:replace(old, nextC)
    cordis.await(fiber:await())
    expect(fiber.state).to.equal(FiberState.ACTIVE)
    expect(nextC.calls).to.have.length(1)
  end)

  -- replace.spec.ts:92
  it("starts a pending fiber when the new component injects an available service", function()
    local root = U.root()
    root:provide("available", {})
    local old = { inject = { "missing" }, apply = function() end }
    local apply = spy.fn()
    local fiber = cordis.await(root:use(old))
    expect(fiber.state).to.equal(FiberState.PENDING)

    root.registry:replace(old, { inject = { "available" }, apply = apply })
    cordis.await(fiber:await())
    expect(fiber.state).to.equal(FiberState.ACTIVE)
    expect(apply.calls).to.have.length(1)
  end)

  -- replace.spec.ts:106
  it("stops depending on a dependency that the new component drops", function()
    local root = U.root()
    local provider = cordis.await(root:use(function(ctx)
      ctx:provide("dep", {})
    end))
    local old = { inject = { "dep" }, apply = function() end }
    local nextC = spy.fn()
    local fiber = cordis.await(root:use(old))

    root.registry:replace(old, nextC)
    cordis.await(fiber:await())
    -- the provider does not wait for the fiber to unload, nor is the fiber reloaded
    local race, resolve, reject = Future.withResolvers(U.host())
    local cancel = U.sched().setTimeout(function()
      reject(cordis.Error.new("not settled"))
    end, 1000)
    Future.resolve(U.host(), provider:restart()):next(resolve, reject)
    race:await()
    cancel()
    expect(fiber.state).to.equal(FiberState.ACTIVE)
    expect(nextC.calls).to.have.length(1)
  end)

  -- replace.spec.ts:121
  it("reloads a consumer of a replaced service", function()
    local root = U.root()
    local old = function(ctx)
      ctx:provide("replaced", { value = "old" })
    end
    local nextC = function(ctx)
      ctx:provide("replaced", { value = "next" })
    end
    local values = {}
    cordis.await(root:use(old))
    local consumer = cordis.await(root:use({
      inject = { "replaced" },
      apply = function(ctx)
        values[#values + 1] = ctx:get("replaced").value
      end,
    }))

    local fiber = root.registry:replace(old, nextC)[1]
    cordis.await(fiber:await())
    cordis.await(consumer:await())
    expect(values).to.deep.equal({ "old", "next" })
    expect(consumer.state).to.equal(FiberState.ACTIVE)
  end)

  -- replace.spec.ts:145
  it("merges the fibers into a registered component", function()
    local root = U.root()
    local old = spy.fn()
    local nextC = spy.fn()
    local a = cordis.await(root:use(old, "a"))
    local b = cordis.await(root:use(nextC, "b"))

    root.registry:replace(old, nextC)
    cordis.await(a:await())

    expect(root.registry.size).to.equal(1)
    expect(a.runtime).to.equal(b.runtime)
    local configs = {}
    for _, fiber in ipairs(a.runtime.fibers:values()) do
      configs[#configs + 1] = fiber.config
    end
    table.sort(configs)
    expect(configs).to.deep.equal({ "a", "b" })
    -- the fiber of `next` is not restarted
    local seen = {}
    for i, call in ipairs(nextC.calls) do
      seen[i] = call[2]
    end
    expect(seen).to.deep.equal({ "b", "a" })
  end)

  -- replace.spec.ts:162
  it("restarts a failed fiber", function()
    local root = U.root()
    local old = function()
      error(cordis.Error.new("failed"))
    end
    local nextC = spy.fn()
    local fiber = root:use(old)
    fiber:await():catch(function() end):await()
    expect(fiber.state).to.equal(FiberState.FAILED)

    root.registry:replace(old, nextC)
    cordis.await(fiber:await())
    expect(fiber.state).to.equal(FiberState.ACTIVE)
    expect(nextC.calls).to.have.length(1)
  end)

  -- replace.spec.ts:176
  it("leaves a fiber failed when the new component fails to apply", function()
    local root = U.root()
    local old = function() end
    local fiber = cordis.await(root:use(old))

    root.registry:replace(old, function()
      error(cordis.Error.new("failed"))
    end)
    expect(fiber:await()).to.reject("failed")
    expect(fiber.state).to.equal(FiberState.FAILED)
  end)

  -- replace.spec.ts:186
  it("forwards the old component to the new one", function()
    local root = U.root()
    local old = spy.fn()
    local apply = spy.fn()
    local nextC = { inject = { "dep" }, apply = apply }
    cordis.await(root:use(old))
    root.registry:replace(old, nextC)

    local fiber = root:use(old)
    expect(proto.ownKeys(fiber.inject)).to.deep.equal({ "dep" })
    expect(fiber.runtime).to.equal(root.registry:get(nextC))
    expect(root.registry:get(old)).to.equal(root.registry:get(nextC))
    -- the alias is not a registered component
    expect(root.registry.size).to.equal(1)
    local keys = root.registry:keys()
    expect(#keys).to.equal(1)
    expect(keys[1]).to.equal(apply)

    root:provide("dep", {})
    U.sleep()
    expect(old.calls).to.have.length(1)
    expect(apply.calls).to.have.length(2)
  end)

  -- replace.spec.ts:208
  it("forwards a component that is not registered", function()
    local root = U.root()
    local old = spy.fn()
    local nextC = spy.fn()
    expect(root.registry:replace(old, nextC)).to.deep.equal({})
    expect(root.registry.size).to.equal(0)

    cordis.await(root:use(old))
    expect(old.calls).to.have.length(0)
    expect(nextC.calls).to.have.length(1)
  end)

  -- replace.spec.ts:220
  it("follows a chain of replacements", function()
    local root = U.root()
    local a = spy.fn()
    local b = spy.fn()
    local c = spy.fn()
    local fiber = cordis.await(root:use(a))
    root.registry:replace(a, b)
    root.registry:replace(a, c)
    cordis.await(fiber:await())

    expect(fiber.runtime).to.equal(root.registry:get(c))
    local keys = root.registry:keys()
    expect(#keys).to.equal(1)
    expect(keys[1]).to.equal(c)
  end)

  -- replace.spec.ts:234
  it("switches back to a replaced component", function()
    local root = U.root()
    local a = spy.fn()
    local b = spy.fn()
    local fiber = cordis.await(root:use(a))
    root.registry:replace(a, b)
    root.registry:replace(b, a)
    cordis.await(fiber:await())

    expect(fiber.runtime).to.equal(root.registry:get(a))
    local keys = root.registry:keys()
    expect(#keys).to.equal(1)
    expect(keys[1]).to.equal(a)
    expect(a.calls).to.have.length(2)
  end)

  -- replace.spec.ts:248
  it("unregisters the new component when its last fiber is disposed", function()
    local root = U.root()
    local old = function() end
    local nextC = function() end
    local fiber = cordis.await(root:use(old))
    root.registry:replace(old, nextC)
    cordis.await(fiber:await())

    cordis.await(fiber:dispose())
    expect(root.registry.size).to.equal(0)
    expect(root.registry:has(nextC)).to.equal(false)
  end)
end)
