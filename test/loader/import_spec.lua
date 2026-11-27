-- Ported from cordis packages/loader/tests/import.spec.ts (MIT, (c) Shigma)
--
-- Rewritten: components are loaded with `require`, whose "module not
-- found" error stands for Node's ERR_MODULE_NOT_FOUND; the searcher lines of
-- that error stand for Node's hints.
local cordis = require("cordis")
local L = require("cordis.loader")
local U = require("kit.util")

describe("Loader: component import", function()
  local function frames()
    return { "    at a (/app/components.yml:1:3)" }
  end

  local function setup()
    local root = U.root()
    cordis.await(root:use(L.Loader))
    return root.loader
  end

  -- import.spec.ts:25
  it("keep the hints of Node after the first line", function()
    local loader = setup()
    local name = "cordis_test.missing_component"

    local ok, err = pcall(function()
      return loader:import(name, frames):await()
    end)
    expect(ok).to.equal(false)
    expect(err).to.be.instanceof(L.ModuleNotFoundError)
    expect(err.specifier).to.equal(name)
    local first, second = err.message:match("^([^\n]*)\n([^\n]*)")
    expect(first).to.equal("module '" .. name .. "' not found")
    -- the searcher lines follow; their wording belongs to the host's `require`
    expect(second ~= nil and second ~= "").to.equal(true)
    expect(err.traceback).to.equal(
      table.concat({ "ModuleNotFoundError: " .. err.message, "    at a (/app/components.yml:1:3)" }, "\n")
    )
  end)

  -- import.spec.ts:42
  it("leave a module imported by another one to Node", function()
    local loader = setup()
    local name = "cordis_test.component"
    package.preload[name] = function()
      return require("cordis_test.missing_dependency")
    end

    local ok, err = pcall(function()
      return loader:import(name, frames):await()
    end)
    package.preload[name] = nil
    expect(ok).to.equal(false)
    expect(L.ModuleNotFoundError.is(err)).to.equal(false)
    expect(tostring(err):find("module 'cordis_test.missing_dependency' not found", 1, true) ~= nil).to.equal(true)
  end)
end)
