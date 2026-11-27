-- Counterpart of upstream `packages/core/tests/utils.ts` plus per-test host access.
local U = {}

-- set by the runner for the test being executed
U.state = { sched = nil, eager = false }

function U.sched()
  return U.state.sched
end

function U.host()
  return U.state.sched.host
end

-- `sleep(ms)`: a real-time sleep in upstream; virtual time here
function U.sleep(ms)
  U.state.sched.host.sleep(ms or 0)
end

-- A case that cannot run on the current scheduler raises a skip; the runner
-- reports it as skipped with its reason (test/kit/runner.lua).
local Skip = { __name = "kit.skip" }
Skip.__tostring = function(self)
  return "skipped: " .. self.reason
end
function U.skip(reason)
  error(setmetatable({ reason = reason }, Skip), 0)
end
function U.isSkip(x)
  return getmetatable(x) == Skip
end

-- `U.requires("virtual time")`: the scheduler runs on virtual time (the
-- reference scheduler); `U.requires("debug")`: the `debug` library exists;
-- `U.requires("microtask order")`: user callbacks run inside the job queue
-- (no `capture`); `U.requires("reference scheduler")`: `cordis.host.coroutine`
-- is available (an embedder's run of this suite may not ship it)
function U.requires(feature)
  if feature == "virtual time" then
    if not U.state.sched.virtual then
      U.skip("needs virtual time")
    end
  elseif feature == "microtask order" then
    -- on a host with `capture` a component's apply runs as its own task, so
    -- cases that rely on upstream's exact microtask order do not apply (docs/deviations.md)
    if U.state.sched.host.capture then
      U.skip("relies on microtask order (host with capture)")
    end
  elseif feature == "reference scheduler" then
    -- the case drives its own `cordis.host.coroutine`, which an embedder may not ship
    if not pcall(require, "cordis.host.coroutine") then
      U.skip("needs the reference scheduler (cordis.host.coroutine)")
    end
  elseif feature == "debug" then
    if type(debug) ~= "table" or type(debug.getinfo) ~= "function" then
      U.skip("needs the debug library")
    end
  else
    error("unknown feature: " .. tostring(feature), 2)
  end
end

local function virtual()
  U.requires("virtual time")
  return U.state.sched
end

-- `vi.advanceTimersByTimeAsync(ms)`
function U.advance(ms)
  virtual().advance(ms)
end

-- `vi.runAllTimersAsync()`
function U.runAll()
  virtual().runAll()
end

-- `withTimers(fn)`: the test runs with manual virtual time (fake timers)
-- and receives a fresh root context
function U.withTimers(fn, config)
  return setmetatable({
    timers = true,
    now = config and config.now,
    run = function()
      -- a function without parameters gets no root context
      local info = debug and debug.getinfo and debug.getinfo(fn, "u")
      if info and info.nparams == 0 then
        return fn()
      end
      return fn(U.root())
    end,
  }, {
    __call = function(self)
      return self.run()
    end,
  })
end

-- `new Context()`
function U.root(options)
  local cordis = require("cordis")
  options = options or {}
  options.host = options.host or U.host()
  return cordis.Context.new(options)
end

-- packed-call helpers for spies
function U.argsOf(spy)
  local r = {}
  for i, call in ipairs(spy.calls) do
    r[i] = table.move(call, 1, call.n, 1, {})
  end
  return r
end

return U
