-- Ported from cordis packages/loader/tests/index.spec.ts (MIT, (c) Shigma)
local cordis = require("cordis")
local L = require("cordis.loader")
local T = require("loader.mock_loader")
local U = require("kit.util")
local spy = require("kit.spy")

local FiberState = cordis.FiberState
local sleep = T.sleep

describe("Loader: disabled js expression", function()
  -- `disabled: !!lua <expr>` parses to an expression node, which is truthy as
  -- a table — reading it as a value disables the entry whatever it says
  -- index.spec.ts:10
  it("evaluates the expression instead of treating the node as truthy", function()
    local _, loader = T.setup()
    loader:mock("plug", function() end)

    local id = loader:create({ id = "a", name = "plug", disabled = { __luaExpr = "false" } }):await()
    sleep()
    expect(loader.store[id].disabled).to.equal(false)

    local id2 = loader:create({ id = "b", name = "plug", disabled = { __luaExpr = "true" } }):await()
    sleep()
    expect(loader.store[id2].disabled).to.equal(true)
  end)
end)

describe("Loader: basic support", function()
  local loader, foo, bar, qux

  before_all(function()
    local _
    _, loader = T.setup()
    local function component(ctx)
      return ctx:on("internal/update", function() end)
    end
    foo = loader:mock("foo", component)
    bar = loader:mock("bar", component)
    qux = loader:mock("qux", component)
  end)

  -- index.spec.ts:43
  it("loader initiate", function()
    loader
      :read({
        { id = "1", name = "foo" },
        {
          id = "2",
          name = "@cordisjs/group",
          config = {
            { id = "3", name = "bar", config = { a = 1 } },
            { id = "4", name = "qux", disabled = true },
          },
        },
      })
      :await()

    loader:expectEnable(foo)
    loader:expectEnable(bar)
    loader:expectDisable(qux)
    expect(foo).to.have.length(1)
    expect(bar).to.have.length(1)
    expect(qux).to.have.length(0)
  end)

  -- index.spec.ts:71
  it("loader update", function()
    foo:reset()
    bar:reset()
    loader:read({ { id = "1", name = "foo" }, { id = "4", name = "qux" } }):await()

    loader:expectEnable(foo)
    loader:expectDisable(bar)
    loader:expectEnable(qux)
    expect(foo).to.have.length(0)
    expect(bar).to.have.length(0)
    expect(qux).to.have.length(1)
  end)

  -- index.spec.ts:90
  it("component self-update", function()
    loader:expectFiber("1"):update({ a = 3 })
    sleep()
    expect(loader.data).to.deep.equal({
      { id = "1", name = "foo", config = { a = 3 } },
      { id = "4", name = "qux" },
    })
  end)

  -- index.spec.ts:103
  it("component self-dispose", function()
    loader:expectFiber("1"):dispose()
    sleep()
    expect(loader.data).to.deep.equal({
      { id = "1", name = "foo", disabled = true, config = { a = 3 } },
      { id = "4", name = "qux" },
    })
  end)
end)

describe("Loader: intercept config", function()
  local loader, foo, bar, qux, resolve

  before_all(function()
    local _
    _, loader = T.setup()
    local promise
    promise, resolve = cordis.Future.withResolvers(U.host())

    loader:mock("foo", function()
      return promise
    end)
    loader:mock("bar", function(ctx)
      return ctx:on("internal/update", function() end)
    end).inject =
      { "never" }
    loader:mock("qux", function() end)
  end)

  -- index.spec.ts:139
  it("pending", function()
    foo = loader:create({ name = "foo" }):await()
    bar = loader:create({ name = "bar" }):await()
    qux = loader:create({ name = "qux", inject = { loader = { await = true } } }):await()

    sleep()
    expect(loader:expectFiber(foo).state).to.equal(FiberState.LOADING)
    expect(loader:expectFiber(bar).state).to.equal(FiberState.PENDING)
    expect(loader.store[qux].outerFiber.state).to.equal(FiberState.PENDING)
    expect(loader.store[qux].innerFiber).to.equal(nil)
  end)

  -- index.spec.ts:162
  it("resolved", function()
    resolve()
    sleep()
    expect(loader:expectFiber(foo).state).to.equal(FiberState.ACTIVE)
    expect(loader:expectFiber(bar).state).to.equal(FiberState.PENDING)
    expect(loader:expectFiber(qux).state).to.equal(FiberState.ACTIVE)
  end)
end)

-- a failing entry is reported by the fiber itself; it must not escape as an
-- uncaught task error, which would take the whole process down with it
describe("Loader: entry failure", function()
  local loader

  before_all(function()
    local _
    _, loader = T.setup()
    loader:mock("bad", function()
      error(cordis.Error.new("boom"))
    end)
    loader:mock("good", function() end)
  end)

  -- index.spec.ts:188
  it("on load", function()
    loader:read({ { id = "1", name = "bad" }, { id = "2", name = "good" } }):await()

    expect(loader:expectFiber("1").state).to.equal(FiberState.FAILED)
    expect(loader:expectFiber("2").state).to.equal(FiberState.ACTIVE)
  end)

  -- index.spec.ts:201
  it("on config update", function()
    loader:read({ { id = "1", name = "bad", config = { a = 1 } }, { id = "2", name = "good" } }):await()

    expect(loader:expectFiber("1").state).to.equal(FiberState.FAILED)
    expect(loader:expectFiber("2").state).to.equal(FiberState.ACTIVE)
  end)

  -- index.spec.ts:215
  it("on an id containing the separator", function()
    loader:read({ { id = "2", name = "good" }, { id = "3:4", name = "good" } }):await()

    expect(loader.store["3:4"]).to.equal(nil)
    expect(loader:expectFiber("2").state).to.equal(FiberState.ACTIVE)
  end)
end)

-- interpolated expressions read from the context, so they can only be
-- evaluated once the entry's dependencies are ready
describe("Loader: config interpolation", function()
  local loader, consumer

  before_all(function()
    local _
    _, loader = T.setup()
    loader:mock("provider", function(ctx, config)
      ctx:provide("foo", { value = config.value })
    end)
    consumer = loader:mock("consumer", function() end)
  end)

  -- index.spec.ts:247
  it("wait for dependencies", function()
    loader
      :read({
        { id = "1", name = "consumer", inject = { "foo" }, config = { value = { __luaExpr = "foo.value" } } },
      })
      :await()
    sleep()

    expect(loader.store["1"].outerFiber.state).to.equal(FiberState.PENDING)
    expect(loader.store["1"].innerFiber).to.equal(nil)
    expect(consumer).to.have.length(0)
  end)

  -- index.spec.ts:261
  it("evaluate after dependencies are ready", function()
    loader
      :read({
        { id = "1", name = "consumer", inject = { "foo" }, config = { value = { __luaExpr = "foo.value" } } },
        { id = "2", name = "provider", config = { value = 1 } },
      })
      :await()
    sleep()

    expect(loader:expectFiber("1").state).to.equal(FiberState.ACTIVE)
    expect(consumer).to.have.length(1)
    expect(T.args(consumer, 1)[2]).to.deep.equal({ value = 1 })
  end)

  -- index.spec.ts:279
  it("re-evaluate when dependencies reload", function()
    loader:update("2", { config = { value = 2 } }):await()
    sleep()

    expect(consumer).to.have.length(2)
    expect(T.args(consumer, 2)[2]).to.deep.equal({ value = 2 })
  end)

  -- index.spec.ts:287
  it("keep the source config unevaluated", function()
    expect(loader:expectFiber("1").config).to.deep.equal({ value = { __luaExpr = "foo.value" } })
  end)
end)

-- a component created inside an entry inherits `entry` through the context
-- prototype chain, but its config comes from code rather than the config file
describe("Loader: nested component config", function()
  local loader, child

  before_all(function()
    local _
    _, loader = T.setup()
    child = loader:mock("child", function() end)
  end)

  -- index.spec.ts:307
  it("skip nested components", function()
    local config = { value = { __luaExpr = "foo.value" } }
    loader:mock("parent", function(ctx)
      ctx:use(child, config)
    end)

    loader:read({ { id = "1", name = "parent" } }):await()
    sleep()

    expect(child).to.have.length(1)
    -- same reference: neither interpolated nor rebuilt
    expect(T.args(child, 1)[2]).to.equal(config)
  end)
end)

-- resolution reads services through `fiber.committed`, which a failed fiber no
-- longer has, so recovery must not depend on resolving the new config first
describe("Loader: failed entry recovery", function()
  local loader, consumer
  local fail = true

  before_all(function()
    local root
    root, loader = T.setup()
    root.logger.error = spy.fn()

    loader:mock("provider", function(ctx)
      ctx:provide("foo", { value = 1 })
    end)
    consumer = loader:mock("consumer", function()
      if fail then
        error(cordis.Error.new("boom"))
      end
    end)
  end)

  -- index.spec.ts:344
  it("fail with dependencies available", function()
    loader
      :read({
        { id = "1", name = "consumer", inject = { "foo" }, config = { value = { __luaExpr = "foo.value" } } },
        { id = "2", name = "provider" },
      })
      :await()
    sleep()

    expect(loader:expectFiber("1").state).to.equal(FiberState.FAILED)
    expect(loader:expectFiber("1").committed).to.equal(nil)
  end)

  -- index.spec.ts:360
  it("recover through update", function()
    fail = false
    loader:update("1", { config = { value = { __luaExpr = "foo.value" }, fixed = true } }):await()
    sleep()

    expect(loader:expectFiber("1").state).to.equal(FiberState.ACTIVE)
    expect(T.args(consumer, 2)[2]).to.deep.equal({ value = 1, fixed = true })
  end)
end)

-- persistence must not depend on whether the fiber can act on the update
describe("Loader: pending entry update", function()
  local loader

  before_all(function()
    local _
    _, loader = T.setup()
    loader:mock("foo", function() end).inject = { "never" }
  end)

  -- index.spec.ts:383
  it("persist an update to a pending fiber", function()
    loader:read({ { id = "1", name = "foo" } }):await()
    sleep()
    expect(loader:expectFiber("1").state).to.equal(FiberState.PENDING)

    loader:expectFiber("1"):update({ a = 3 })
    sleep()

    expect(loader.data).to.deep.equal({ { id = "1", name = "foo", config = { a = 3 } } })
  end)
end)

-- an entry disposed by the teardown of its parent has not disposed itself,
-- even when the parent is still registered
describe("Loader: parent teardown", function()
  local root, loader
  local changes = {}

  local Tree = cordis.class("Tree", L.EntryTree)
  Tree.inject = { "foo" }

  function Tree:commit(change)
    table.insert(changes, change)
  end

  function Tree:import(name)
    return loader:import(name)
  end

  Tree[cordis.symbols.init] = function(self)
    return cordis.asyncIter(function(yield)
      yield(cordis.async(function()
        -- the children are disposed before they are unregistered
        sleep()
        self.root:stop()
      end))
      self.root:update({ { id = "a", name = "bar" } }):await()
    end)()
  end

  before_all(function()
    root, loader = T.setup()
    loader:mock("bar", function() end)
    loader.modules["tree"] = Tree
  end)

  -- index.spec.ts:436
  it("keep children enabled when the parent loses a dependency", function()
    local dispose = root:provide("foo", {})
    loader:read({ { id = "1", name = "tree" } }):await()
    sleep()
    expect(loader:expectFiber("1").state).to.equal(FiberState.ACTIVE)
    expect(loader:resolve("1:a").innerFiber.state).to.equal(FiberState.ACTIVE)

    dispose()
    loader:await():await()
    expect(loader:expectFiber("1").state).to.equal(FiberState.PENDING)
    expect(changes).to.deep.equal({})
  end)
end)

describe("Loader: replaced component", function()
  -- index.spec.ts:451
  it("keeps the entry of a component replaced in place", function()
    local root, loader = T.setup()
    local foo = loader:mock("foo", function() end)
    loader:read({ { id = "1", name = "foo", config = { a = 1 } } }):await()
    local fiber = loader:expectFiber("1")

    local nextFn = spy.fn()
    root.registry:replace(foo, nextFn)
    fiber:await():await()

    expect(loader:expectFiber("1")).to.equal(fiber)
    expect(nextFn).to.have.length(1)
    expect(T.args(nextFn, 1)[2]).to.deep.equal({ a = 1 })
    expect(loader.store["1"].disabled).to.equal(false)
    expect(loader.data).to.deep.equal({ { id = "1", name = "foo", config = { a = 1 } } })
  end)
end)
