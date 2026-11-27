-- Library-own tests: the loader runs in sandboxes without the `debug` library
-- (sandboxed embedders may have none), like the core (test/lib/sandbox_spec.lua).
local U = require("kit.util")

local function withoutDebug(fn)
  local saved = {}
  for name, mod in pairs(package.loaded) do
    if name == "cordis" or name:sub(1, 7) == "cordis." then
      saved[name] = mod
      package.loaded[name] = nil
    end
  end
  local savedDebug = debug
  _G.debug = nil
  local ok, err = pcall(fn)
  _G.debug = savedDebug
  for name in pairs(package.loaded) do
    if name == "cordis" or name:sub(1, 7) == "cordis." then
      package.loaded[name] = nil
    end
  end
  for name, mod in pairs(saved) do
    package.loaded[name] = mod
  end
  if not ok then
    error(err, 0)
  end
end

describe("loader sandbox", function()
  it("evaluates and traces expressions without the debug library", function()
    withoutDebug(function()
      local L = require("cordis.loader")
      local trace = {
        label = "disabled",
        locate = function()
          return { filename = "app.yml", line = 3, column = 5 }
        end,
        getOuterStack = function()
          return { "    at worker (app.yml:1:3)" }
        end,
      }
      expect(L.evaluate({ value = 1 }, "value + 1", trace)).to.equal(2)
      local ok, err = pcall(L.evaluate, {}, "missing.value", trace)
      expect(ok).to.equal(false)
      expect(err.message).to.equal("missing is not defined")
      expect(err.traceback:find("    at worker (app.yml:1:3)", 1, true) ~= nil).to.equal(true)
    end)
  end)

  it("loads entries without the debug library", function()
    withoutDebug(function()
      local cordis = require("cordis")
      local L = require("cordis.loader")
      local root = cordis.Context.new({ host = U.host() })
      cordis.await(root:use(L.Loader))
      local loader = root.loader
      local calls = 0
      loader.internal = {
        import = function()
          return function()
            calls = calls + 1
          end
        end,
      }
      loader:create({ id = "a", name = "plug" }):await()
      loader:create({ id = "b", name = "plug", disabled = { __luaExpr = "missing.value" } }):await()
      loader:await():await()
      expect(calls).to.equal(1)
      expect(loader.store.a.innerFiber.state).to.equal(cordis.FiberState.ACTIVE)
      expect(loader.store.b.disabled).to.equal(true)
    end)
  end)

  it("constructs Loader and logs when global os is nil", function()
    local savedOs = _G.os
    _G.os = nil
    local ok, err = pcall(function()
      local cordis = require("cordis")
      local L = require("cordis.loader")
      local root = cordis.Context.new({ host = U.host() })
      cordis.await(root:use(L.Loader))
      expect(type(root.loader.envData.startTime)).to.equal("number")
      root.logger:info("no os")
      expect(#root.logger.buffer >= 1).to.equal(true)
    end)
    _G.os = savedOs
    if not ok then
      error(err, 0)
    end
  end)
end)
