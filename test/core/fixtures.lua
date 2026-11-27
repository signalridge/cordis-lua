-- Counterpart of upstream packages/core/tests/utils.ts (shared fixtures).
local cordis = require("cordis")
local F = {}

F.event = "custom-event"

local Session = cordis.class("Session")
F.Session = Session
function Session:constructor(flag)
  self.flag = flag
end
Session[cordis.Context.filter] = function(self, context)
  local filter = context.filter
  if not filter then
    return true
  end
  return filter(self)
end

local Filter = cordis.class("Filter")
F.Filter = Filter
function Filter:constructor(flag)
  local this = self
  self.flag = flag
  -- an arrow function field: dot-called
  self.filter = function(session)
    -- basic parity check
    return session.flag == this.flag
  end
end

local Counter = cordis.class("Counter")
F.Counter = Counter
function Counter:constructor(ctx)
  self[cordis.Service.tracker] = { associate = "counter", property = "ctx" }
  self.value = 0
  self.ctx = ctx
end
function Counter:increase()
  local this = self
  return self.ctx:effect(function()
    this.value = this.value + 1
    return function()
      this.value = this.value - 1
    end
  end)
end

function F.getHookSnapshot(ctx)
  local result = {}
  for name, callbacks in pairs(ctx.events._hooks) do
    if #callbacks > 0 then
      result[tostring(name)] = #callbacks
    end
  end
  return result
end

return F
