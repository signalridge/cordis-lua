-- Library-own tests: the reference scheduler (cordis.host.coroutine).
local U = require("kit.util")
local scheduler = require("cordis.host.coroutine")

describe("host", function()
  it("latch wakes every waiter and lets late waiters through", function()
    local host = U.host()
    local latch = host.latch()
    local woken = 0
    for _ = 1, 3 do
      host.spawn(function()
        latch:wait()
        woken = woken + 1
      end)
    end
    U.sleep(0)
    expect(woken).to.equal(0)
    latch:open()
    latch:open()
    U.sleep(0)
    expect(woken).to.equal(3)
    latch:wait()
  end)

  it(
    "advance fires timers in due order",
    U.withTimers(function()
      local host = U.host()
      local order = {}
      for _, ms in ipairs({ 30, 10, 20, 10 }) do
        host.spawn(function()
          host.sleep(ms)
          order[#order + 1] = ms .. "@" .. host.now()
        end)
      end
      U.advance(15)
      expect(order).to.deep.equal({ "10@10", "10@10" })
      expect(host.now()).to.equal(15)
      U.advance(100)
      expect(order).to.deep.equal({ "10@10", "10@10", "20@20", "30@30" })
      expect(host.now()).to.equal(115)
    end)
  )

  it("eager spawn runs to the first block, deferred spawn queues", function()
    for _, eager in ipairs({ true, false }) do
      local s = scheduler.new({ eager = eager })
      local trace = {}
      s.drive(function()
        s.host.spawn(function()
          trace[#trace + 1] = "start"
          s.host.sleep(1)
          trace[#trace + 1] = "end"
        end)
        trace[#trace + 1] = "after spawn"
      end)
      s.run()
      if eager then
        expect(trace).to.deep.equal({ "start", "after spawn", "end" })
      else
        expect(trace).to.deep.equal({ "after spawn", "start", "end" })
      end
    end
  end)

  it("opening a latch never resumes waiters inline", function()
    local host = U.host()
    local latch = host.latch()
    local trace = {}
    host.spawn(function()
      latch:wait()
      trace[#trace + 1] = "woken"
    end)
    U.sleep(0)
    latch:open()
    trace[#trace + 1] = "opened"
    U.sleep(0)
    expect(trace).to.deep.equal({ "opened", "woken" })
  end)

  it("drive reports a stalled task", function()
    local s = scheduler.new({ auto = false })
    local ok, err = s.drive(function()
      s.host.sleep(10)
    end)
    expect(ok).to.equal(false)
    expect(tostring(err)).to.equal("stalled: the test task never completed (deadlock or missing advance)")
  end)

  it("unlinks expired sleep wakers from latch.wakers while waking concurrent waiters", function()
    local s = scheduler.new({ eager = false, auto = false })
    local latch = s.host.latch()
    local ticks = 0
    s.host.spawn(function()
      for _ = 1, 200 do
        s.host.sleep(10, latch)
        ticks = ticks + 1
      end
    end)
    for i = 1, 200 do
      s.advance(10)
      expect(#latch.wakers).to.equal(i < 200 and 1 or 0)
    end
    expect(ticks).to.equal(200)

    -- concurrent sleepers on one latch: one expires naturally, the other wakes on open()
    local s2 = scheduler.new({ eager = false, auto = false })
    local l3 = s2.host.latch()
    local w2 = {}
    s2.host.spawn(function()
      s2.host.sleep(10, l3)
      w2[#w2 + 1] = "first"
    end)
    s2.host.spawn(function()
      s2.host.sleep(50, l3)
      w2[#w2 + 1] = "second"
    end)
    s2.advance(0)
    expect(#l3.wakers).to.equal(2)
    s2.advance(10)
    expect(w2).to.deep.equal({ "first" })
    expect(#l3.wakers).to.equal(1)
    l3:open()
    s2.advance(0)
    expect(w2).to.deep.equal({ "first", "second" })
    expect(l3.wakers).to.equal(nil)
  end)

  it("preserves registration order across >=3 live sleepers after an earlier sleep expires", function()
    local s = scheduler.new({ eager = false, auto = false })
    local latch = s.host.latch()
    local order = {}
    for i, ms in ipairs({ 1, 10, 10, 10 }) do
      s.host.spawn(function()
        s.host.sleep(ms, latch)
        order[#order + 1] = i
      end)
    end
    s.advance(1)
    expect(order).to.deep.equal({ 1 })
    expect(#latch.wakers).to.equal(3)
    latch:open()
    s.advance(0)
    expect(order).to.deep.equal({ 1, 2, 3, 4 })
  end)

  it("does not retain latches on early wakeup until the original deadline", function()
    local s = scheduler.new({ eager = false, auto = false })
    local weak = setmetatable({}, { __mode = "v" })
    for i = 1, 1000 do
      local latch = s.host.latch()
      weak[i] = latch
      s.host.spawn(function()
        s.host.sleep(100000, latch)
      end)
      s.advance(0)
      latch:open()
    end
    s.advance(0)
    collectgarbage()
    collectgarbage()
    local alive = 0
    for i = 1, 1000 do
      if weak[i] ~= nil then
        alive = alive + 1
      end
    end
    expect(alive).to.equal(0)
  end)

  it("does not delay finite timers behind a NaN deadline", function()
    local s = scheduler.new({ eager = false, auto = false })
    local fired = {}
    s.setTimeout(function()
      fired[#fired + 1] = 100
    end, 100)
    s.setTimeout(function()
      fired[#fired + 1] = "nan"
    end, 0 / 0)
    s.setTimeout(function()
      fired[#fired + 1] = 200
    end, 200)
    s.setTimeout(function()
      fired[#fired + 1] = 1
    end, 1)
    s.advance(1)
    local seenOne = false
    for _, v in ipairs(fired) do
      if v == 1 then
        seenOne = true
      end
      expect(v ~= 100 and v ~= 200).to.equal(true)
    end
    expect(seenOne).to.equal(true)
  end)

  it("long-lived interval keeps reference scheduler latch.wakers bounded", function()
    local cordis = require("cordis")
    local Timer = require("cordis.timer")
    local s = scheduler.new({ eager = false, auto = false })
    local intervalLatch
    local captureNext = false
    local baseLatch = s.host.latch
    s.host.latch = function()
      local l = baseLatch()
      if captureNext then
        intervalLatch = l
        captureNext = false
      end
      return l
    end
    local count = 0
    local dispose
    local ok, err = s.drive(function()
      local root = cordis.Context.new({ host = s.host })
      cordis.await(root:use(Timer))
      captureNext = true
      dispose = root:interval(function()
        count = count + 1
      end, 10)
    end)
    if not ok then
      error(err, 0)
    end
    for _ = 1, 500 do
      s.advance(10)
      expect(#intervalLatch.wakers <= 1).to.equal(true)
    end
    expect(count).to.equal(500)
    dispose()
  end)

  it("fires same-tick and re-entrant timers in exact (at, seq) FIFO order", function()
    local s = scheduler.new({ eager = false, auto = false })
    local order = {}
    for i = 1, 64 do
      s.setTimeout(function()
        order[#order + 1] = "t" .. i
        if i == 1 then
          s.setTimeout(function()
            order[#order + 1] = "reentrant-0"
          end, 0)
        end
      end, 10)
    end
    s.setTimeout(function()
      order[#order + 1] = "later"
    end, 20)
    s.advance(10)
    expect(#order).to.equal(65)
    expect(order[1]).to.equal("t1")
    expect(order[64]).to.equal("t64")
    expect(order[65]).to.equal("reentrant-0")
    expect(s.pending()).to.equal(1)
    s.advance(10)
    expect(order[66]).to.equal("later")
    expect(s.pending()).to.equal(0)
  end)

  it("cancelling a sleeping task removes its timer and avoids advancing virtual time", function()
    local s = scheduler.new({ eager = false, auto = true, contexts = true })
    local latch = s.host.latch()
    local ok, err = s.drive(function()
      local scope = s.host.capture()
      local handle = scope.spawn(function()
        s.host.sleep(999999, latch)
      end)
      s.host.sleep(0)
      expect(s.pending()).to.equal(1)
      expect(#latch.wakers).to.equal(1)
      expect(handle.cancel()).to.equal(true)
      expect(s.pending()).to.equal(0)
      expect(#latch.wakers).to.equal(0)
    end)
    if not ok then
      error(err, 0)
    end
    expect(s.now()).to.equal(0)
    expect(s.pending()).to.equal(0)
  end)

  it("cancelling a task waiting in latch:wait() leaves later waiters intact", function()
    local s = scheduler.new({ eager = false, auto = false, contexts = true })
    local latch = s.host.latch()
    local secondWoken = false
    local scope = s.host.capture()
    local h1 = scope.spawn(function()
      latch:wait()
    end)
    scope.spawn(function()
      latch:wait()
      secondWoken = true
    end)
    s.advance(0)
    expect(h1.cancel()).to.equal(true)
    latch:open()
    s.advance(0)
    expect(secondWoken).to.equal(true)
  end)

  it("runs without debug global, rejects reentrant advanceTo, and captures close errors", function()
    local savedDebug = _G.debug
    _G.debug = nil
    local ok, err = pcall(function()
      local s = scheduler.new({ eager = false, auto = false, contexts = true })
      local scope = s.host.capture()
      local h = scope.spawn(function()
        local _ <close> = setmetatable({}, {
          __close = function()
            error("close boom")
          end,
        })
        s.host.sleep(100)
      end)
      s.advance(0)
      h.cancel()
      expect(#s.errors).to.equal(1)
      expect(s.errors[1]:find("close boom", 1, true) ~= nil).to.equal(true)

      s.host.spawn(function()
        error("task boom")
      end)
      s.advance(0)
      expect(#s.errors).to.equal(2)

      local reentrantOk, reentrantErr = s.drive(function()
        -- inside a coroutine not registered as a task
        local co = coroutine.create(function()
          s.advance(1)
        end)
        local okCo, errCo = coroutine.resume(co)
        if not okCo then
          error(errCo, 0)
        end
      end)
      expect(reentrantOk).to.equal(false)
      expect(tostring(reentrantErr):find("not reentrant", 1, true) ~= nil).to.equal(true)
    end)
    _G.debug = savedDebug
    if not ok then
      error(err, 0)
    end
  end)
end)
