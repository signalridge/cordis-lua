-- Library-own tests: loader defects found in review, each against
-- the upstream behaviour it restores.
local cordis = require("cordis")
local L = require("cordis.loader")
local T = require("loader.mock_loader")

local FiberState = cordis.FiberState
local proto = cordis.proto

local function expr(source)
  return { __luaExpr = source }
end

describe("loader fixes", function()
  -- an inject value that evaluates to nil keeps the dependency
  -- (upstream entry.ts:151-157 keeps the key; registry.ts:43 reads an empty
  -- config as a dependency without config)
  it("keeps a dependency whose inject value evaluates to nil", function()
    local root, loader = T.setup()
    local plug = loader:mock("plug", function() end)

    loader:create({ id = "a", name = "plug", inject = { db = expr("nil") } }):await()
    loader:await():await()
    local entry = loader.store.a
    expect(T.keys(entry.inject)).to.deep.equal({ "db" })
    expect(entry.outerFiber.state).to.equal(FiberState.PENDING)
    expect(plug).to.have.length(0)

    root:provide("db", {})
    loader:await():await()
    expect(plug).to.have.length(1)
  end)

  -- a name that is neither in the context nor a global raises, as an
  -- unbound identifier does in JS (utils.ts:7), which disables the entry
  -- (entry.ts:105-113)
  it("disables an entry whose disabled expression reads an unknown name", function()
    local _, loader = T.setup()
    local plug = loader:mock("plug", function() end)

    loader:create({ id = "a", name = "plug", disabled = expr("missingFlag") }):await()
    loader:await():await()
    expect(loader.store.a.disabled).to.equal(true)
    expect(plug).to.have.length(0)
    expect(function()
      L.evaluate(cordis.proto.create(nil), "missingFlag")
    end).to.throw("missingFlag is not defined")
    -- globals are still reachable
    expect(L.evaluate(cordis.proto.create(nil), "math.max(1, 2)")).to.equal(2)
  end)

  -- options given as JS-like objects are merged and copied by their own
  -- keys (entry.ts:76-85, tree.ts:160-163)
  it("applies options and patches given as JS-like objects", function()
    local _, loader = T.setup()
    local plug = loader:mock("plug", function() end)

    local id = loader:create(proto.create(nil, { id = "a", name = "plug", config = { n = 1 } })):await()
    loader:await():await()
    expect(loader:expectFiber(id).state).to.equal(FiberState.ACTIVE)

    loader:update(id, proto.create(nil, { config = { n = 2 } })):await()
    loader:await():await()
    expect(T.args(plug, #plug.calls)[2]).to.deep.equal({ n = 2 })

    loader:update(id, proto.create(nil, { disabled = true })):await()
    loader:await():await()
    expect(loader.store[id].disabled).to.equal(true)
    expect(loader.store[id].innerFiber.uid).to.equal(nil)
  end)

  -- a sequence with a hole is not an array, so a group with such
  -- a config is rejected before the tree changes (utils.ts:163-208)
  it("rejects a group config with a hole", function()
    local _, loader = T.setup()
    loader:mock("plug", function() end)

    -- a generated list with a hole at 2, for which `#` still reports 5
    local config = {}
    for i = 1, 5 do
      config[i] = { id = "x" .. i, name = "plug" }
    end
    config[2] = nil
    expect(#config).to.equal(5)
    expect(L.validateOptions({ name = "group", group = true, config = config }, ":")).to.deep.equal({
      { message = "config must be an array", path = { "config" } },
    })
    expect(loader:create({ name = "@cordisjs/group", group = true, config = config })).to.reject(
      "config must be an array"
    )
    expect(loader.root.data).to.deep.equal({})
    expect(loader.store.x5).to.equal(nil)
  end)

  -- expressions inside a table with a metatable are evaluated through its
  -- own fields (utils.ts:33-43); the metatable is kept
  it("evaluates expressions inside a config table with a metatable", function()
    local _, loader = T.setup()
    loader:mock("settings", function(ctx)
      ctx:provide("settings", { token = "t1" })
    end)
    local plug = loader:mock("plug", function() end)

    local config = setmetatable({ token = expr("settings.token") }, { __index = { region = "eu" } })
    loader
      :read({
        { id = "settings", name = "settings" },
        { id = "a", name = "plug", inject = { "settings" }, config = config },
      })
      :await()
    expect(plug).to.have.length(1)
    local received = T.args(plug, 1)[2]
    expect(rawget(received, "token")).to.equal("t1")
    expect(received.region).to.equal("eu")
  end)
end)

describe("loader interpolation of opaque values", function()
  -- a value whose metatable is protected (`__metatable`): getmetatable returns that field, not the
  -- metatable, so it cannot be copied; it is kept as an opaque value
  it("keeps a config value with a protected metatable as it is", function()
    for _, protection in ipairs({ false, "locked" }) do
      local value = setmetatable({ token = expr("1 + 1") }, { __metatable = protection })
      local out = L.interpolate(cordis.proto.create(nil), { client = value, n = expr("2") })
      expect(rawequal(out.client, value)).to.equal(true)
      expect(out.n).to.equal(2)
    end
  end)
end)

describe("loader release fixes", function()
  it("rejects duplicate IDs on create and ID changes on update before mutating rows or committing", function()
    local _, loader = T.setup()
    loader:mock("plug", function() end)
    loader:create({ id = "x", name = "plug" }):await()
    local commits = {}
    loader.commit = function(_, change)
      commits[#commits + 1] = change
    end

    expect(loader:create({ id = "x", name = "plug" })).to.reject("already exists")
    expect(loader.root.data).to.have.length(1)
    expect(commits).to.have.length(0)

    expect(loader:update("x", { id = "y" })).to.reject("cannot change entry id")
    expect(loader.store.x.options.id).to.equal("x")
    expect(commits).to.have.length(0)

    expect(loader:update("x", { id = cordis.null })).to.reject("cannot change entry id")
    expect(loader.store.x.options.id).to.equal("x")
    expect(commits).to.have.length(0)
  end)

  it("rejects moving a group into itself or its descendant", function()
    local _, loader = T.setup()
    local a = loader:create({ id = "a", name = "@cordisjs/group", group = true, config = {} }):await()
    local b = loader:create({ id = "b", name = "@cordisjs/group", group = true, config = {} }, a):await()
    local commits = {}
    loader.commit = function(_, change)
      commits[#commits + 1] = change
    end

    expect(loader:update(a, {}, a)).to.reject("cannot move group")
    expect(loader:update(a, {}, b)).to.reject("cannot move group")
    expect(loader.store.a.parent).to.equal(loader.root)
    expect(loader.store.b.parent).to.equal(loader.store.a.subgroup)
    expect(commits).to.have.length(0)
  end)

  it(
    "supports reentrant interpolation on shared metatable tables, deterministic key order, and proto.defineOwn swap",
    function()
      local order = {}
      local shared = setmetatable({ a = expr("1 + 1") }, { __index = { fallback = true } })
      local res = L.interpolate({
        bump = function(k)
          order[#order + 1] = k
          if k == "nested" then
            -- reentrant interpolate call on the same metatable table
            local inner = L.interpolate(cordis.proto.create(nil), shared)
            expect(inner.a).to.equal(2)
          end
          return k
        end,
      }, {
        z = expr('bump("z")'),
        a = expr('bump("a")'),
        m = expr('bump("m")'),
        nested = expr('bump("nested")'),
        shared1 = shared,
        shared2 = shared,
      })
      expect(order).to.deep.equal({ "a", "m", "nested", "z" })
      expect(res.shared1.a).to.equal(2)
      expect(res.shared2.a).to.equal(2)
      expect(res.shared1.fallback).to.equal(true)

      local setterCalled = false
      local base = proto.proxy(proto.create(nil), {
        set = function()
          setterCalled = true
          return true
        end,
      })
      local target = proto.create(base)
      local src = proto.create(nil, { x = 42 })
      L.swap(target, src)
      expect(setterCalled).to.equal(false)
      expect(proto.getOwn(target, "x")).to.equal(42)
    end
  )
end)
