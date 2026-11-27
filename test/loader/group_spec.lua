-- Ported from cordis packages/loader/tests/group.spec.ts (MIT, (c) Shigma)
local cordis = require("cordis")
local T = require("loader.mock_loader")
local spy = require("kit.spy")

local sleep = T.sleep
local proto = cordis.proto

describe("Group: basic support", function()
  local dispose = spy.fn()
  local loader, foo
  local outer, inner

  before_all(function()
    local _
    _, loader = T.setup()
    foo = loader:mock("foo", function()
      return dispose
    end)
  end)

  before_each(function()
    if foo then
      foo:reset()
    end
    dispose:reset()
  end)

  -- group.spec.ts:27
  it("initialize", function()
    outer = loader:create({ name = "@cordisjs/group", group = true, config = { { name = "foo" } } }):await()
    inner = loader:create({ name = "@cordisjs/group", group = true, config = { { name = "foo" } } }, outer):await()

    sleep()
    loader:expectFiber(outer)
    loader:expectFiber(inner)
    expect(foo).to.have.length(2)
    expect(dispose).to.have.length(0)
    expect(loader:entries()).to.have.length(4)
  end)

  -- group.spec.ts:52
  it("disable inner", function()
    loader:update(inner, { disabled = true }):await()

    expect(foo).to.have.length(0)
    expect(dispose).to.have.length(1)
    expect(loader:entries()).to.have.length(4)
  end)

  -- group.spec.ts:60
  it("disable outer", function()
    loader:update(outer, { disabled = true }):await()

    expect(foo).to.have.length(0)
    expect(dispose).to.have.length(1)
    expect(loader:entries()).to.have.length(4)
  end)

  -- group.spec.ts:68
  it("enable inner", function()
    loader:update(inner, { disabled = cordis.null }):await()

    expect(foo).to.have.length(0) -- outer is still disabled
    expect(dispose).to.have.length(0)
    expect(loader:entries()).to.have.length(4)
  end)

  -- group.spec.ts:76
  it("enable outer", function()
    loader:update(outer, { disabled = cordis.null }):await()

    sleep()
    expect(foo).to.have.length(2)
    expect(dispose).to.have.length(0)
    expect(loader:entries()).to.have.length(4)
  end)
end)

describe("Group: transfer", function()
  local dispose = spy.fn()
  local loader, foo
  local alpha, beta, gamma, id

  before_all(function()
    local _
    _, loader = T.setup()
    foo = loader:mock("foo", function()
      return dispose
    end)
  end)

  before_each(function()
    if foo then
      foo:reset()
    end
    dispose:reset()
  end)

  -- group.spec.ts:109
  it("initialize", function()
    id = loader:create({ name = "foo" }):await()
    alpha = loader:create({ name = "@cordisjs/group", group = true, config = {} }):await()
    beta = loader:create({ name = "@cordisjs/group", group = true, disabled = true, config = {} }, alpha):await()
    gamma = loader:create({ name = "@cordisjs/group", group = true, config = {} }, beta):await()

    expect(foo).to.have.length(1)
    expect(dispose).to.have.length(0)
    expect(loader:entries()).to.have.length(4)
  end)

  -- group.spec.ts:138
  it("enabled -> enabled", function()
    loader:update(id, {}, alpha):await()

    expect(foo).to.have.length(0)
    expect(dispose).to.have.length(0)
    expect(loader:entries()).to.have.length(4)
  end)

  -- group.spec.ts:146 (rewritten: timing — the disposal is awaited to
  -- quiescence; upstream sees it settle within the microtasks of the update)
  it("enabled -> disabled", function()
    loader:update(id, {}, beta):await()
    loader:await():await()

    expect(foo).to.have.length(0)
    expect(dispose).to.have.length(1)
    expect(loader:entries()).to.have.length(4)
  end)

  -- group.spec.ts:154
  it("disabled -> disabled", function()
    loader:update(id, {}, gamma):await()

    expect(foo).to.have.length(0) -- outer is still disabled
    expect(dispose).to.have.length(0)
    expect(loader:entries()).to.have.length(4)
  end)

  -- group.spec.ts:162 (`null` parent: the root group)
  it("disabled -> enabled", function()
    loader:update(id, {}, cordis.null):await()

    expect(foo).to.have.length(1)
    expect(dispose).to.have.length(0)
    expect(loader:entries()).to.have.length(4)
  end)
end)

describe("Group: awaited reconciliation", function()
  local loader, foo, bar
  local group

  before_all(function()
    local _
    _, loader = T.setup()
    foo = loader:mock("foo", function() end)
    bar = loader:mock("bar", function() end)
  end)

  -- group.spec.ts:187
  it("initialize", function()
    group = loader:create({ name = "@cordisjs/group", group = true, config = { { id = "1", name = "foo" } } }):await()

    sleep()
    loader:expectEnable(foo)
    loader:expectDisable(bar)
  end)

  -- group.spec.ts:202
  it("config update settles children", function()
    -- The group vetoes its own restart and reconciles children instead, so
    -- that reconciliation is what the caller is really waiting for. A slow
    -- import makes the difference observable: without the awaited chain the
    -- update resolves while the new child is still being imported.
    local load = loader.import
    loader.import = cordis.async(function(self, name)
      sleep(20)
      return load(self, name):await()
    end)
    local ok, err = pcall(function()
      loader:update(group, { config = { { id = "1", name = "foo" }, { id = "2", name = "bar" } } }):await()
    end)
    loader.import = nil
    if not ok then
      error(err, 0)
    end

    loader:expectEnable(bar)
    loader:expectFiber("2")
  end)
end)

describe("Group: intercept", function()
  local callback = spy.fn()
  local loader
  local outer, inner

  before_all(function()
    local _
    _, loader = T.setup()
    loader:mock("foo", function(ctx)
      callback(ctx[cordis.Context.intercept])
    end)
  end)

  before_each(function()
    callback:reset()
  end)

  -- group.spec.ts:253
  it("initialize", function()
    outer =
      loader:create({ name = "@cordisjs/group", group = true, intercept = { foo = { a = 1 } }, config = {} }):await()
    inner = loader
      :create({ name = "@cordisjs/group", group = true, intercept = { foo = { b = 2 } }, config = {} }, outer)
      :await()
    loader:create({ name = "foo", intercept = { foo = { c = 3 } } }, inner):await()

    expect(callback).to.have.length(1)
    local intercept = T.args(callback, 1)[1]
    expect(intercept.foo).to.deep.equal({ c = 3 })
    expect(proto.getPrototypeOf(intercept).foo).to.deep.equal({ b = 2 })
    expect(proto.getPrototypeOf(proto.getPrototypeOf(intercept)).foo).to.deep.equal({ a = 1 })
  end)
end)

-- PR #370: Group ownership transfer
describe("Group: ownership transfer", function()
  local function setupTransfer(options)
    local root, loader = T.setup()
    local dispose = spy.fn()
    local foo = loader:mock("foo", function()
      return dispose
    end)
    loader:mock("settings", function(ctx)
      ctx:provide("settings", { ok = true })
    end)
    loader
      :read({
        { id = "settings", name = "settings" },
        {
          id = "a",
          name = "@cordisjs/group",
          group = true,
          config = { { id = "x", name = "foo", inject = options.inject } },
        },
        { id = "b", name = "@cordisjs/group", group = true, config = {} },
      })
      :await()
    local entry = loader.store.x
    local outerFiber, innerFiber = entry.outerFiber, entry.innerFiber
    local function expectKept()
      local cur = loader.store.x
      for _, pair in ipairs({ { cur.outerFiber, outerFiber }, { cur.innerFiber, innerFiber } }) do
        local f, expected = pair[1], pair[2]
        if expected then
          expect(f.uid).to.equal(expected.uid)
          expect(expected.state).to.equal(cordis.FiberState.ACTIVE)
        end
      end
      expect(dispose).to.have.length(0)
      expect(cur.options.disabled).to.equal(nil)
    end
    return root, loader, foo, dispose, innerFiber, expectKept
  end

  local function keepsTransferred(opts)
    return function()
      local _, loader, _, dispose, _, expectKept = setupTransfer(opts)
      local commits = {}
      loader.commit = function(_, change)
        commits[#commits + 1] = change
      end
      loader:update("x", {}, "b")
      loader:remove("a")
      loader:await():await()
      expectKept()
      for _, c in ipairs(commits) do
        expect(not (c.options and c.options.disabled)).to.equal(true)
      end

      -- the target group owns the entry now
      loader:remove("b")
      sleep()
      expect(dispose).to.have.length(1)
    end
  end

  it("keeps an entry transferred out of a removed group (inject=undefined)", keepsTransferred({}))
  it(
    "keeps an entry transferred out of a removed group (inject=['settings'])",
    keepsTransferred({ inject = { "settings" } })
  )

  it("keeps an entry transferred by a config file out of a removed group", function()
    local _, loader, _, _, _, expectKept = setupTransfer({})
    loader
      :read({
        { id = "settings", name = "settings" },
        { id = "b", name = "@cordisjs/group", group = true, config = { { id = "x", name = "foo" } } },
      })
      :await()
    loader:await():await()
    expectKept()
  end)

  it("leaves nothing to a former group after the entry disposes itself", function()
    local _, loader, _, _, innerFiber = setupTransfer({})
    local function effects(id)
      return #loader:expectFiber(id):getEffects()
    end
    local beforeA, beforeB = effects("a"), effects("b")
    loader:update("x", {}, "b"):await()
    loader:update("x", {}, "a"):await()
    cordis.await(innerFiber:dispose())
    expect(loader.store.x.options.disabled).to.equal(true)
    expect({ effects("a"), effects("b") }).to.deep.equal({ beforeA - 1, beforeB })
  end)

  it("transfers an entry into a group that is being rebuilt", function()
    local root, loader, foo, dispose = setupTransfer({})
    loader:update("b", { inject = { "settings", "missing" } })
    loader:update("x", {}, "b"):await()
    loader:await():await()
    -- the entry is disposed once, with the group that holds it, and leaves no fiber behind
    cordis.await(loader.ctx.fiber:dispose())
    expect(dispose).to.have.length(1)
    local rt = root.registry:get(foo)
    expect(rt and rt.fibers:length() or 0).to.equal(0)
  end)
end)
