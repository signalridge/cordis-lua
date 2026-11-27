-- Ported from cordis packages/loader/tests/isolate.spec.ts (MIT, (c) Shigma)
local cordis = require("cordis")
local T = require("loader.mock_loader")
local U = require("kit.util")
local spy = require("kit.spy")

local FiberState = cordis.FiberState
local sleep = T.sleep

local function makeBar()
  local Bar = cordis.class("Bar", cordis.Service)
  function Bar:constructor(ctx)
    Bar.super.constructor(self, ctx, "bar")
  end
  return Bar
end

-- `(ctx, config = {}) => ctx.provide('bar', config)`
local function provideBar(ctx, config)
  ctx:provide("bar", config or {})
end

describe("Service Isolation: basic", function()
  local dispose = spy.fn()
  local loader, foo
  local provider, injector

  before_all(function()
    local _
    _, loader = T.setup()
    foo = loader:mock("foo", function()
      return dispose
    end)
    foo.inject = { "bar" }
    loader:mock("bar", makeBar())
  end)

  before_each(function()
    if foo then
      foo:reset()
    end
    dispose:reset()
  end)

  -- isolate.spec.ts:38
  it("initiate", function()
    provider = loader:create({ name = "bar" }):await()
    injector = loader:create({ name = "foo" }):await()

    sleep()
    expect(foo).to.have.length(1)
    expect(dispose).to.have.length(0)
  end)

  -- isolate.spec.ts:47
  it("add isolate on injector (relevant)", function()
    loader:update(injector, { isolate = { bar = true } }):await()

    sleep()
    expect(foo).to.have.length(0)
    expect(dispose).to.have.length(1)
  end)

  -- isolate.spec.ts:59
  it("add isolate on injector (irrelevant)", function()
    loader:update(injector, { isolate = { bar = true, qux = true } }):await()

    sleep()
    expect(foo).to.have.length(0)
    expect(dispose).to.have.length(0)
  end)

  -- isolate.spec.ts:72
  it("remove isolate on injector (relevant)", function()
    loader:update(injector, { isolate = { qux = true } }):await()

    sleep()
    expect(foo).to.have.length(1)
    expect(dispose).to.have.length(0)
  end)

  -- isolate.spec.ts:84
  it("remove isolate on injector (irrelevant)", function()
    loader:update(injector, { isolate = cordis.null }):await()

    sleep()
    expect(foo).to.have.length(0)
    expect(dispose).to.have.length(0)
  end)

  -- isolate.spec.ts:94
  it("add isolate on provider (relevant)", function()
    loader:update(provider, { isolate = { bar = true } }):await()

    sleep()
    expect(foo).to.have.length(0)
    expect(dispose).to.have.length(1)
  end)

  -- isolate.spec.ts:106
  it("add isolate on provider (irrelevant)", function()
    loader:update(provider, { isolate = { bar = true, qux = true } }):await()

    sleep()
    expect(foo).to.have.length(0)
    expect(dispose).to.have.length(0)
  end)

  -- isolate.spec.ts:119
  it("remove isolate on provider (relevant)", function()
    loader:update(provider, { isolate = { qux = true } }):await()

    sleep()
    expect(foo).to.have.length(1)
    expect(dispose).to.have.length(0)
  end)

  -- isolate.spec.ts:131
  it("remove isolate on provider (irrelevant)", function()
    loader:update(provider, { isolate = cordis.null }):await()

    sleep()
    expect(foo).to.have.length(0)
    expect(dispose).to.have.length(0)
  end)
end)

describe("Service Isolation: realm", function()
  local dispose = spy.fn()
  local root, loader, foo, bar
  local alpha, beta
  local nested1, nested2, nested3

  before_all(function()
    root, loader = T.setup()
    foo = loader:mock("foo", function()
      return dispose
    end)
    foo.inject = { "bar" }
    bar = loader:mock("bar", provideBar)
  end)

  before_each(function()
    if foo then
      foo:reset()
      bar:reset()
    end
    dispose:reset()
  end)

  local function fibers()
    local runtime = root.registry:get(bar)
    return runtime and runtime.fibers:length() or 0
  end

  -- isolate.spec.ts:172
  it("add isolate group", function()
    alpha = loader
      :create({
        name = "@cordisjs/group",
        isolate = { bar = true },
        config = { { name = "bar", config = { value = "alpha" } } },
      })
      :await()
    beta = loader
      :create({
        name = "@cordisjs/group",
        isolate = { bar = "beta" },
        config = { { name = "bar", config = { value = "beta" } } },
      })
      :await()

    sleep()
    expect(fibers()).to.equal(2)
    expect(foo).to.have.length(0)
    expect(dispose).to.have.length(0)
  end)

  -- isolate.spec.ts:201
  it("update isolate group (no change)", function()
    loader:update(alpha, { isolate = { bar = true } }):await()

    sleep()
    expect(fibers()).to.equal(2)
    expect(foo).to.have.length(0)
    expect(dispose).to.have.length(0)
  end)

  -- isolate.spec.ts:218
  it("realm reference", function()
    nested1 = loader:create({ name = "foo" }, alpha):await()
    nested2 = loader:create({ name = "foo", isolate = { bar = "beta" } }, alpha):await()
    nested3 = loader:create({ name = "foo", isolate = { bar = true } }, alpha):await()

    sleep()
    expect(foo).to.have.length(2)
    expect(dispose).to.have.length(0)
    local fiber1 = loader:expectFiber(nested1)
    expect(fiber1.ctx:get("bar").value).to.equal("alpha")
    expect(fiber1.state).to.equal(FiberState.ACTIVE)
    local fiber2 = loader:expectFiber(nested2)
    expect(fiber2.ctx:get("bar").value).to.equal("beta")
    expect(fiber2.state).to.equal(FiberState.ACTIVE)
    local fiber3 = loader:expectFiber(nested3)
    expect(fiber3.ctx:get("bar")).to.equal(nil)
    expect(fiber3.state).to.equal(FiberState.PENDING)
  end)

  -- isolate.spec.ts:251
  it("special case: nested realms", function()
    local _, loader = T.setup()
    local dispose = spy.fn()
    local foo = loader:mock("foo", function()
      return dispose
    end)
    foo.inject = { "bar" }
    loader:mock("bar", provideBar)

    local outer = loader:create({ name = "@cordisjs/group", config = {} }):await()
    local inner = loader:create({ name = "@cordisjs/group", isolate = { bar = "custom" }, config = {} }, outer):await()
    loader:create({ name = "bar", config = { value = "custom" } }, inner):await()
    local alpha = loader:create({ name = "foo", isolate = { bar = "custom" } }):await()
    local beta = loader:create({ name = "foo" }, inner):await()

    sleep()
    local fiber1 = loader:expectFiber(alpha)
    local fiber2 = loader:expectFiber(beta)
    expect(fiber1.ctx:get("bar").value).to.equal("custom")
    expect(fiber2.ctx:get("bar").value).to.equal("custom")

    foo:reset()
    dispose:reset()

    loader:update(outer, { isolate = { bar = "custom" } }):await()

    sleep()
    expect(foo).to.have.length(0)
    expect(dispose).to.have.length(0)

    foo:reset()
    dispose:reset()

    loader:update(outer, { isolate = {} }):await()

    sleep()
    expect(foo).to.have.length(0)
    expect(dispose).to.have.length(0)
  end)

  -- isolate.spec.ts:326
  it("special case: change provider", function()
    local _, loader = T.setup()
    local dispose = spy.fn()
    local foo = loader:mock("foo", function()
      return dispose
    end)
    foo.inject = { "bar" }
    loader:mock("bar", provideBar)

    loader:create({ name = "bar", isolate = { bar = "alpha" }, config = { value = "alpha" } }):await()
    loader:create({ name = "bar", isolate = { bar = "beta" }, config = { value = "beta" } }):await()
    local group = loader:create({ name = "@cordisjs/group", isolate = { bar = "alpha" }, config = {} }):await()
    local id = loader:create({ name = "foo" }, group):await()

    sleep()
    expect(foo).to.have.length(1)
    expect(dispose).to.have.length(0)
    local fiber = loader:expectFiber(id)
    expect(fiber.ctx:get("bar").value).to.equal("alpha")

    foo:reset()
    dispose:reset()

    loader:update(group, { isolate = { bar = "beta" } }):await()

    sleep()
    expect(foo).to.have.length(1)
    expect(dispose).to.have.length(1)
    expect(fiber.ctx:get("bar").value).to.equal("beta")
  end)

  -- isolate.spec.ts:390
  it("special case: change injector", function()
    local _, loader = T.setup()
    local dispose = spy.fn()
    local foo = loader:mock("foo", function()
      return dispose
    end)
    foo.inject = { "bar" }
    loader:mock("bar", provideBar)

    local alpha = loader:create({ name = "foo", isolate = { bar = "alpha" } }):await()
    local beta = loader:create({ name = "foo", isolate = { bar = "beta" } }):await()
    local group = loader:create({ name = "@cordisjs/group", isolate = { bar = "alpha" }, config = {} }):await()
    local inner = loader:create({ name = "bar" }, group):await()

    loader:expectFiber(inner)
    sleep()
    expect(foo).to.have.length(1)
    expect(dispose).to.have.length(0)
    local fiber1 = loader:expectFiber(alpha)
    expect(fiber1.ctx:get("bar")).to.be.ok()
    local fiber2 = loader:expectFiber(beta)
    expect(fiber2.ctx:get("bar")).to.equal(nil)

    foo:reset()
    dispose:reset()

    loader:update(group, { isolate = { bar = "beta" } }):await()

    sleep()
    expect(foo).to.have.length(1)
    expect(dispose).to.have.length(1)
    expect(fiber1.ctx:get("bar")).to.equal(nil)
    expect(fiber2.ctx:get("bar")).to.be.ok()
  end)
end)

describe("Service Isolation: transfer", function()
  local dispose = spy.fn()
  local loader, foo
  local group, provider, injector

  before_all(function()
    local _
    _, loader = T.setup()
    foo = loader:mock("foo", function()
      return dispose
    end)
    foo.inject = { "bar" }
    loader:mock("bar", makeBar())
  end)

  before_each(function()
    if foo then
      foo:reset()
    end
    dispose:reset()
  end)

  -- isolate.spec.ts:490
  it("initiate", function()
    group = loader:create({ name = "@cordisjs/group", isolate = { bar = true }, config = {} }):await()
    provider = loader:create({ name = "bar" }):await()
    injector = loader:create({ name = "foo" }):await()

    sleep()
    expect(foo).to.have.length(1)
    expect(dispose).to.have.length(0)
  end)

  -- isolate.spec.ts:507
  it("transfer injector into group", function()
    loader:update(injector, {}, group)

    sleep()
    expect(foo).to.have.length(0)
    expect(dispose).to.have.length(1)
  end)

  -- isolate.spec.ts:515
  it("transfer provider into group", function()
    loader:update(provider, {}, group)

    sleep()
    expect(foo).to.have.length(1)
    expect(dispose).to.have.length(0)
  end)

  -- isolate.spec.ts:523
  it("transfer injector out of group", function()
    loader:update(injector, {}, cordis.null)

    sleep()
    expect(foo).to.have.length(0)
    expect(dispose).to.have.length(1)
  end)

  -- isolate.spec.ts:531
  it("transfer provider out of group", function()
    loader:update(provider, {}, cordis.null)

    sleep()
    expect(foo).to.have.length(1)
    expect(dispose).to.have.length(0)
  end)
end)

describe("Service Isolation: migration", function()
  -- isolate.spec.ts:541
  it("keeps the committed views of a parent and a pinned child across a realm transfer", function()
    local root, loader = T.setup()
    local loads, unloads = {}, {}

    local Bar = cordis.class("Bar", cordis.Service)
    function Bar:constructor(ctx, config)
      Bar.super.constructor(self, ctx, "bar")
      self.config = config
    end
    loader:mock("bar", Bar)

    local parent = loader:mock("parent", function(ctx)
      -- the child is pinned to the realm the parent resolves `bar` in
      ctx:isolate("bar", ctx[cordis.Context.isolate].bar):inject({ "bar" }, function(ctx)
        table.insert(loads, "child:" .. ctx.bar.config.tag)
        return function()
          table.insert(unloads, "child:" .. ctx.bar.config.tag)
        end
      end)
      return function()
        table.insert(unloads, "parent:" .. ctx.bar.config.tag)
      end
    end)
    parent.inject = { "bar" }

    loader:create({ name = "bar", isolate = { bar = "a" }, config = { tag = "a" } }):await()
    loader:create({ name = "bar", isolate = { bar = "b" }, config = { tag = "b" } }):await()
    local id = loader:create({ name = "parent", isolate = { bar = "a" } }):await()
    sleep()
    expect(loads).to.deep.equal({ "child:a" })

    -- the loader moves the isolation of the parent before unloading it, while
    -- the old activation still tears down against the view committed in realm a
    loader:update(id, { isolate = { bar = "b" } }):await()
    sleep()
    expect(loads).to.deep.equal({ "child:a", "child:b" })
    table.sort(unloads)
    expect(unloads).to.deep.equal({ "child:a", "parent:a" })
    local errors = 0
    for _, message in ipairs(root.logger.buffer) do
      if message.type == "error" then
        errors = errors + 1
      end
    end
    expect(errors).to.equal(0)
    cordis.await(root.fiber:dispose())
  end)
end)
