-- Counterpart of `mock.fn()` (node:test) / `vi.fn()`: a callable table that
-- records its calls. `spy.calls[i]` is the packed argument list of call i;
-- `spy.results[i]` is its return value.
local S = {}

local Spy = { __spy = true, __name = "spy" }
Spy.__index = Spy

function Spy:__call(...)
  local args = table.pack(...)
  table.insert(self.calls, args)
  local impl = table.remove(self.once, 1) or self.impl
  if not impl then
    table.insert(self.results, nil)
    return nil
  end
  local result = table.pack(impl(...))
  self.results[#self.calls] = result[1]
  return table.unpack(result, 1, result.n)
end

function Spy:mockImplementationOnce(fn)
  table.insert(self.once, fn)
end

function Spy:mockImplementation(fn)
  self.impl = fn
end

function Spy:reset()
  self.calls = {}
  self.results = {}
end

-- the argument list of call i (1-based)
function Spy:args(i)
  return self.calls[i]
end

function S.fn(impl)
  return setmetatable({ impl = impl, calls = {}, results = {}, once = {} }, Spy)
end

function S.is(x)
  return getmetatable(x) == Spy
end

return S
