-- Library-own tests: the library runs in sandboxes without the `debug` library
-- (sandboxed embedders may have none); tracebacks then degrade to empty text.
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

describe("sandbox", function()
  it("works without the debug library", function()
    withoutDebug(function()
      local cordis = require("cordis")
      local root = cordis.Context.new({ host = U.host() })
      local e = cordis.Error.new("boom")
      expect(e.message).to.equal("boom")
      local seen = {}
      local fiber = root:use(function(ctx)
        ctx:effect(cordis.iter(function(yield)
          yield(function()
            seen[#seen + 1] = "iter"
          end)
        end))
        cordis.await(ctx:effect(cordis.asyncIter(function(yield)
          yield(function()
            seen[#seen + 1] = "async"
          end)
        end)))
      end)
      cordis.await(fiber)
      expect(fiber.state).to.equal(cordis.FiberState.ACTIVE)
      cordis.await(fiber:dispose())
      table.sort(seen)
      expect(seen).to.deep.equal({ "async", "iter" })
    end)
  end)
end)
