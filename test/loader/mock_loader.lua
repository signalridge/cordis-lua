-- Ported from cordis packages/loader/tests/utils.ts (MIT, (c) Shigma)
local cordis = require("cordis")
local L = require("cordis.loader")
local spy = require("kit.spy")
local U = require("kit.util")
local H = require("kit.harness")

local MockLoader = cordis.class("MockLoader", L.Loader)

function MockLoader:constructor(ctx)
  L.Loader.constructor(self, ctx)
  self.data = {}
  self.changes = {}
  self.modules = {}
  ctx:on("internal/get", function(ctx, prop, _, next)
    if not ctx.fiber.runtime and prop == "loader" then
      return ctx:get(prop)
    end
    return next()
  end)
end

function MockLoader:commit(change)
  self.data = self.root.data
  table.insert(self.changes, change)
end

-- `async read(data)`
function MockLoader:read(data)
  self.data = data
  return self.root:update(data):next(function()
    return self:await()
  end)
end

-- `async import(name)`
function MockLoader:import(name)
  if name == "@cordisjs/group" then
    return cordis.Future.resolve(self.ctx.host, L.Group)
  end
  return cordis.Future.resolve(self.ctx.host, self.modules[name])
end

-- `mock.fn(component)` named `name`; a class component is registered as is
-- (a spy is not a constructor), so its calls are not recorded
function MockLoader:mock(name, component)
  if cordis.class.is(component) then
    self.modules[name] = component
    return component
  end
  local fn = spy.fn(component)
  fn.name = name
  self.modules[name] = fn
  return fn
end

function MockLoader:expectEnable(component)
  H.expect(self.ctx.registry:get(component)).to.be.ok()
end

function MockLoader:expectDisable(component)
  H.expect(self.ctx.registry:get(component)).never.to.be.ok()
end

function MockLoader:expectFiber(id)
  local entry = self.store[id]
  H.expect(entry and entry.innerFiber).to.be.ok()
  return entry.innerFiber
end

local M = { MockLoader = MockLoader }

-- `sleep(ms = 0)`: a timer on the virtual clock
function M.sleep(ms)
  U.sleep(ms or 0)
end

-- `const root = new Context(); await root.use(MockLoader); loader = root.loader`
function M.setup()
  local root = U.root()
  cordis.await(root:use(MockLoader))
  return root, root.loader
end

-- the arguments of call `i` of a spy (`mock.calls[i].arguments`), 1-based
function M.args(fn, i)
  return fn.calls[i]
end

-- a JS-like object (`cordis.proto`) as a plain table of its own keys, deeply,
-- for `deep.equal`
function M.plain(value)
  local proto = cordis.proto
  if type(value) ~= "table" then
    return value
  end
  if proto.is(value) then
    local result = {}
    for _, key in ipairs(proto.ownKeys(value)) do
      result[key] = M.plain(proto.getOwn(value, key))
    end
    return result
  end
  if getmetatable(value) ~= nil then
    return value
  end
  local result = {}
  for key, item in pairs(value) do
    result[key] = M.plain(item)
  end
  return result
end

-- `Object.keys(o)`
function M.keys(value)
  return cordis.proto.ownKeys(value)
end

-- `settings.count++` inside an expression: Lua expressions have no side
-- effects of their own, so the service carries `bump`
function M.bump(self, key)
  self[key] = self[key] + 1
  return true
end

return M
