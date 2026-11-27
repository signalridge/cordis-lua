-- Library-own tests: the loader as the runtime tree of an embedder that
-- evaluates its own definitions (through `loader.internal:import`) and hands
-- the loader a list of rows; a later list updates the whole tree. Runs on the
-- reference scheduler and on external hosts (test/kit/runner.lua).
local cordis = require("cordis")
local L = require("cordis.loader")
local U = require("kit.util")

local FiberState = cordis.FiberState

-- definitions by name, each recording its applications, configs and disposals
local function definitions(n)
  local defs, log = {}, { applied = {}, disposed = {} }
  for i = 1, n do
    local name = string.format("p%02d", i)
    defs[name] = {
      name = name,
      apply = function(ctx, config)
        log.applied[name] = (log.applied[name] or 0) + 1
        log.config = log.config or {}
        log.config[name] = config
        ctx:effect(function()
          return function()
            log.disposed[name] = (log.disposed[name] or 0) + 1
          end
        end)
      end,
    }
  end
  return defs, log
end

local function rows(n, extra)
  local list = {}
  for i = 1, n do
    local name = string.format("p%02d", i)
    local row = { id = name, name = name, config = { n = 1 } }
    if extra then
      extra(row, i)
    end
    list[#list + 1] = row
  end
  return list
end

local function setup(n)
  local root = U.root()
  cordis.await(root:use(L.Loader))
  local loader = root.loader
  local defs, log = definitions(n)
  loader.internal = {
    import = function(_, name)
      return defs[name] or error("module '" .. name .. "' not found:\n\tno definition", 0)
    end,
  }
  return root, loader, log
end

local function active(loader, id)
  local entry = loader.store[id]
  return entry ~= nil and entry.innerFiber ~= nil and entry.innerFiber.state == FiberState.ACTIVE
end

describe("loader rows", function()
  it("applies a list of 48 rows through the import hook", function()
    local _, loader, log = setup(48)
    loader.root:update(rows(48)):await()
    loader:await():await()
    local count = 0
    for i = 1, 48 do
      local id = string.format("p%02d", i)
      expect(active(loader, id)).to.equal(true)
      expect(log.applied[id]).to.equal(1)
      count = count + 1
    end
    expect(count).to.equal(48)
  end)

  it("updates the whole tree: adds, removes, disables and reconfigures rows", function()
    local _, loader, log = setup(50)
    loader.root:update(rows(48)):await()
    loader:await():await()

    -- p01 removed, p02 disabled, p03 reconfigured, p49 added; the rest unchanged
    local list = {}
    for _, row in ipairs(rows(49)) do
      if row.id ~= "p01" then
        if row.id == "p02" then
          row.disabled = true
        elseif row.id == "p03" then
          row.config = { n = 2 }
        end
        list[#list + 1] = row
      end
    end
    loader.root:update(list):await()
    loader:await():await()

    expect(loader.store.p01).to.equal(nil)
    expect(log.disposed.p01).to.equal(1)
    expect(loader.store.p02.disabled).to.equal(true)
    expect(log.disposed.p02).to.equal(1)
    expect(active(loader, "p03")).to.equal(true)
    expect(log.applied.p03).to.equal(2)
    expect(log.config.p03).to.deep.equal({ n = 2 })
    expect(active(loader, "p49")).to.equal(true)
    expect(log.applied.p49).to.equal(1)
    for i = 4, 48 do
      local id = string.format("p%02d", i)
      expect(log.applied[id]).to.equal(1)
      expect(log.disposed[id]).to.equal(nil)
    end

    -- re-enabling and removing the reconfiguration go back the same way
    loader.root:update(rows(49)):await()
    loader:await():await()
    expect(active(loader, "p01")).to.equal(true)
    expect(active(loader, "p02")).to.equal(true)
    expect(log.applied.p02).to.equal(2)
    expect(log.config.p03).to.deep.equal({ n = 1 })
  end)

  it("reports a row whose definition cannot be imported and keeps the others", function()
    local root, loader = setup(3)
    local errors = {}
    root.logger:exporter({
      export = function(message)
        if message.type == "error" then
          errors[#errors + 1] = message
        end
      end,
    })
    loader.root:update({ { id = "p01", name = "p01" }, { id = "nope", name = "nope" } }):await()
    loader:await():await()
    expect(active(loader, "p01")).to.equal(true)
    expect(loader.store.nope.innerFiber).to.equal(nil)
    expect(#errors).to.equal(1)
    expect(L.ModuleNotFoundError.is(errors[1].args[1])).to.equal(true)
  end)
end)
