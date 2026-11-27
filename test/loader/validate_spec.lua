-- Ported from cordis packages/loader/tests/validate.spec.ts (MIT, (c) Shigma)
local cordis = require("cordis")
local L = require("cordis.loader")
local T = require("loader.mock_loader")

local FiberState = cordis.FiberState

describe("Loader: entry options validation", function()
  local function validate(options)
    return L.validateOptions(options, ":")
  end

  local function paths(issues)
    local result = {}
    for i, issue in ipairs(issues) do
      result[i] = issue.path
    end
    return result
  end

  -- validate.spec.ts:9
  it("accept valid options", function()
    expect(validate({ name = "foo" })).to.deep.equal({})
    expect(validate({
      id = "a",
      name = "foo",
      group = false,
      disabled = { __luaExpr = "true" },
      inject = { "bar" },
      intercept = { bar = {} },
      isolate = { bar = true, baz = "label" },
      config = { __luaExpr = "whatever" },
    })).to.deep.equal({})
    -- nullish fields are absent
    expect(validate({ name = "foo", group = cordis.null, disabled = cordis.null, inject = cordis.null })).to.deep.equal({})
    expect(validate({ name = "foo", inject = { bar = { required = true } } })).to.deep.equal({})
    expect(validate({ name = "group", group = true, config = {} })).to.deep.equal({})
  end)

  -- validate.spec.ts:27 (rewritten: an empty table is both an array and
  -- an object, so the non-array / non-object cases use non-empty tables;
  -- issue paths count from 1)
  it("reject a missing or invalid field", function()
    expect(validate(nil)).to.deep.equal({ { message = "entry must be an object", path = {} } })
    expect(validate({ "foo" })).to.deep.equal({ { message = "entry must be an object", path = {} } })
    expect(validate({})).to.deep.equal({ { message = "name is required", path = { "name" } } })
    expect(validate({ id = 1, name = "foo" })).to.deep.equal({ { message = "id must be a string", path = { "id" } } })
    expect(validate({ id = "a:b", name = "foo" })).to.deep.equal({
      { message = 'id must not contain ":"', path = { "id" } },
    })
    expect(validate({ name = "group", group = true })).to.deep.equal({
      { message = "config is required", path = { "config" } },
    })
    expect(validate({ name = "group", group = true, config = { a = 1 } })).to.deep.equal({
      { message = "config must be an array", path = { "config" } },
    })
    expect(validate({ name = "foo", inject = { "bar", 1 } })).to.deep.equal({
      { message = "inject.2 must be a string", path = { "inject", 2 } },
    })
    expect(validate({ name = "foo", inject = "bar" })).to.deep.equal({
      { message = "inject must be an array or an object", path = { "inject" } },
    })
    expect(validate({ name = "foo", intercept = { "bar" } })).to.deep.equal({
      { message = "intercept must be an object", path = { "intercept" } },
    })
    expect(validate({ name = "foo", isolate = { bar = false } })).to.deep.equal({
      { message = "isolate.bar must be true or a string", path = { "isolate", "bar" } },
    })
  end)

  -- validate.spec.ts:41
  it("accept an expression only for disabled", function()
    local expr = { __luaExpr = "true" }
    expect(validate({ name = "foo", disabled = "yes" })).to.deep.equal({
      { message = "disabled must be a boolean", path = { "disabled" } },
    })
    expect(validate({ name = "foo", disabled = { __luaExpr = 1 } })).to.have.length(1)
    expect(paths(validate({ name = expr, group = expr, inject = expr, intercept = expr, isolate = expr }))).to.deep.equal({
      { "name" },
      { "group" },
      { "inject" },
      { "intercept" },
      { "isolate" },
    })
  end)

  -- validate.spec.ts:52
  it("reject invalid options at runtime before they are committed", function()
    local _, loader = T.setup()
    loader:mock("foo", function() end)

    expect(loader:create({ name = 1 })).to.reject(L.EntryValidationError)
    expect(loader:create({ name = 1 })).to.reject("invalid entry options:\n  - name must be a string (at name)")
    expect(loader.changes).to.deep.equal({})
    expect(loader.root.data).to.deep.equal({})

    local id = loader:create({ name = "foo" }):await()
    loader.changes = {}
    expect(loader:update(id, { disabled = "yes" })).to.reject(L.EntryValidationError)
    expect(loader.changes).to.deep.equal({})
    expect(loader.store[id].options).to.deep.equal({ id = id, name = "foo" })
    expect(loader:expectFiber(id).state).to.equal(FiberState.ACTIVE)
  end)

  -- validate.spec.ts:71 (rewritten: the `null` entry is `cordis.null`;
  -- issue paths count from 1)
  it("check the entries of a group passed at runtime as a whole", function()
    local _, loader = T.setup()
    loader:mock("foo", function() end)

    local config = { cordis.null, { id = "child", name = "foo" }, { name = "foo", inject = { 1 } } }
    expect(loader:create({ name = "@cordisjs/group", group = true, config = config })).to.reject(table.concat({
      "invalid entry options:",
      "  - entry must be an object (at config.1)",
      "  - inject.1 must be a string (at config.3.inject.1)",
    }, "\n"))
    expect(loader.changes).to.deep.equal({})
    expect(loader.store["child"]).to.equal(nil)

    local id = loader:create({ name = "@cordisjs/group", group = true, config = {} }):await()
    loader.changes = {}
    expect(loader:update(id, { config = { { id = "child" } } })).to.reject("name is required (at config.1.name)")
    expect(loader.changes).to.deep.equal({})
    expect(loader.store[id].options.config).to.deep.equal({})

    -- a source hands its entries over one at a time
    expect(validate({ name = "group", group = true, config = { cordis.null } })).to.deep.equal({})
  end)

  -- validate.spec.ts:96
  it("unload an entry whose options turn invalid, and reload it once fixed", function()
    local _, loader = T.setup()
    local foo = loader:mock("foo", function() end)

    loader:read({ { id = "a", name = "foo" }, { id = "b", name = "foo" } }):await()
    local fiber = loader:expectFiber("a")

    loader:read({ { id = "a", name = "foo", group = "no" }, { id = "b", name = "foo" }, "oops" }):await()
    expect(loader.store["a"]).to.equal(nil)
    expect(fiber.state).to.equal(FiberState.DISPOSED)
    expect(loader:expectFiber("b").state).to.equal(FiberState.ACTIVE)
    -- the disposal is not mistaken for a self-dispose, which writes `disabled`
    expect(loader.changes).to.deep.equal({})

    loader:read({ { id = "a", name = "foo" }, { id = "b", name = "foo" } }):await()
    expect(loader:expectFiber("a").state).to.equal(FiberState.ACTIVE)
    expect(foo).to.have.length(3)
  end)
end)
