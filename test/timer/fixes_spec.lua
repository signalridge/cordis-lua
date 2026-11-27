-- Library-own tests: timer defects found in review.
local cordis = require("cordis")
local Timer = require("cordis.timer")
local U = require("kit.util")
local spy = require("kit.spy")

-- A host whose `spawn` may start a task later (allowed by the host contract):
-- while `held` is set, new tasks wait for `release()` before they run.
local function lateHost()
  local base = U.host()
  local gate, held = nil, false
  local host = setmetatable({}, { __index = base })
  function host.spawn(fn)
    if held then
      local latch = gate
      base.spawn(function()
        latch:wait()
        fn()
      end)
    else
      base.spawn(fn)
    end
  end
  local control = {}
  function control.hold()
    gate = base.latch()
    held = true
  end
  function control.release()
    held = false
    gate:open()
  end
  return host, control
end

local function setup()
  local host, control = lateHost()
  local root = cordis.Context.new({ host = host })
  cordis.await(root:use(Timer))
  local ctx
  cordis.await(root:use({
    inject = { "timer" },
    apply = function(c)
      ctx = c
    end,
  }))
  return ctx, control
end

describe("timer fixes", function()
  -- the delay counts from registration, as `setTimeout` does
  -- (timer/index.ts:33), even when the host starts the task late
  it(
    "counts a timeout from registration on a host that starts tasks late",
    U.withTimers(function()
      local ctx, control = setup()
      local callback = spy.fn()
      control.hold()
      ctx:timeout(callback, 1000)
      control.release = control.release
      U.advance(800)
      control.release()
      U.advance(200)
      expect(callback).to.have.length(1)
    end)
  )

  -- the same for the trailing call of `debounce` (timer/index.ts:133-148)
  it(
    "counts a debounce delay from the call on a host that starts tasks late",
    U.withTimers(function()
      local ctx, control = setup()
      local callback = spy.fn()
      local debounced = ctx:debounce(callback, 1000)
      control.hold()
      debounced()
      U.advance(800)
      control.release()
      U.advance(200)
      expect(callback).to.have.length(1)
    end)
  )

  -- the first tick of an interval counts from registration (setInterval)
  it(
    "counts the first interval tick from registration on a host that starts tasks late",
    U.withTimers(function()
      local ctx, control = setup()
      local callback = spy.fn()
      control.hold()
      ctx:interval(callback, 1000)
      U.advance(800)
      control.release()
      U.advance(200)
      expect(callback).to.have.length(1)
      U.advance(1000)
      expect(callback).to.have.length(2)
    end)
  )
end)

-- Regression tests for timer behavior and callback execution contexts.
describe("timer fixes (fidelity review)", function()
  -- a root with the timer and a context that injects it, on `host`
  local function timerCtx(host)
    local root = cordis.Context.new({ host = host })
    cordis.await(root:use(Timer))
    local ctx
    cordis.await(root:use({
      inject = { "timer" },
      apply = function(c)
        ctx = c
      end,
    }))
    return ctx
  end

  -- a zero (or negative) interval takes the minimum delay of 1 ms, as Node's setInterval
  -- does, so it cannot run its callback in a loop that never yields
  it(
    "runs a zero interval at the minimum delay instead of in a tight loop",
    U.withTimers(function()
      local ctx = timerCtx(U.host())
      local count, dispose = 0, nil
      dispose = ctx:interval(function()
        count = count + 1
        if count > 100 then
          dispose() -- a guard for the failing case: stop a runaway loop
        end
      end, 0)
      U.advance(5)
      expect(count >= 4 and count <= 6).to.equal(true)
      dispose()
    end)
  )

  -- clearing a timer wakes the task that sleeps for it, on a host whose sleep takes the
  -- latch (an optional host capability); the task does not linger until the old deadline
  it(
    "wakes the sleeping task of a cleared timer early",
    U.withTimers(function()
      local base = U.host()
      local slept = {}
      local host = setmetatable({
        sleep = function(ms, latch)
          local t0 = base.now()
          base.sleep(ms, latch)
          slept[#slept + 1] = base.now() - t0
        end,
      }, { __index = base })
      local ctx = timerCtx(host)
      local before = #slept
      local dispose = ctx:timeout(function() end, 10000)
      U.advance(1)
      dispose()
      U.advance(1)
      expect(#slept).to.equal(before + 1)
      expect(slept[#slept] < 10000).to.equal(true)
    end)
  )

  -- throttle and debounce run their callback in the context it was handed in, for the
  -- leading call and for trailing ones, not in the context of whoever calls the wrapper
  it("runs throttle and debounce callbacks in the context they were created in", function()
    U.requires("reference scheduler")
    local scheduler = require("cordis.host.coroutine")
    local future = require("cordis.future")
    local sched = scheduler.new({ contexts = true })
    local ok, err = sched.drive(function()
      future.enter(sched.host)
      local ctx = timerCtx(sched.host)
      local seen = {}
      local throttled, debounced
      local created = sched.host.latch()
      sched.spawnAs("tool", function()
        future.enter(sched.host)
        throttled = ctx:throttle(function()
          seen[#seen + 1] = "throttle:" .. tostring(sched.context())
        end, 10)
        debounced = ctx:debounce(function()
          seen[#seen + 1] = "debounce:" .. tostring(sched.context())
        end, 10)
        created:open()
      end)
      created:wait()
      throttled() -- leading, now
      throttled() -- trailing, later
      debounced()
      sched.host.sleep(50)
      table.sort(seen)
      expect(seen).to.deep.equal({ "debounce:tool", "throttle:tool", "throttle:tool" })
    end)
    if not ok then
      error(err, 0)
    end
  end)

  it(
    "interval async iterator drains queued next() calls in FIFO order across refill cycles",
    U.withTimers(function()
      local ctx = timerCtx(U.host())
      local iterator = ctx:interval(100)
      local log = {}
      for i = 1, 4 do
        iterator:next():next(function()
          log[#log + 1] = "cycle1-" .. i
        end)
      end
      U.advance(400)
      expect(log).to.deep.equal({ "cycle1-1", "cycle1-2", "cycle1-3", "cycle1-4" })

      -- queue emptied and reset; a second burst still settles in FIFO order
      for i = 1, 3 do
        iterator:next():next(function()
          log[#log + 1] = "cycle2-" .. i
        end)
      end
      U.advance(300)
      expect(log).to.deep.equal({
        "cycle1-1",
        "cycle1-2",
        "cycle1-3",
        "cycle1-4",
        "cycle2-1",
        "cycle2-2",
        "cycle2-3",
      })
      iterator["return"](iterator):await()
    end)
  )
end)
