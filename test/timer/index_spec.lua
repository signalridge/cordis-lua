-- Ported from cordis packages/timer/tests/index.spec.ts (MIT, (c) Shigma)
local cordis = require("cordis")
local Timer = require("cordis.timer")
local U = require("kit.util")
local spy = require("kit.spy")

-- index.spec.ts:7
local function withContext(callback, config)
  return U.withTimers(function()
    local ctx = U.root()
    cordis.await(ctx:use(Timer))
    cordis.await(ctx:use({ inject = { "timer" }, apply = cordis.async(callback) }))
  end, config)
end

local advance = U.advance

local function calls(fn)
  return #fn.calls
end

-- `for await (const _ of iterator) body()`: `body` returns true to
-- `break`; leaving early (break or error) calls `return` as JS does.
local function forAwait(iterator, body)
  while true do
    local result = iterator:next():await()
    if result.done then
      return
    end
    local ok, stop = pcall(body)
    if not ok or stop then
      iterator["return"](iterator):await()
      if not ok then
        error(stop, 0)
      end
      return
    end
  end
end

local function same(reason)
  return function(e)
    return rawequal(e, reason)
  end
end

describe("ctx.timer", function()
  describe("ctx.timeout()", function()
    -- index.spec.ts:22
    it(
      "basic support",
      withContext(function(ctx)
        local callback = spy.fn()
        ctx:timeout(callback, 1000)
        expect(calls(callback)).to.equal(0)
        advance(1000)
        expect(calls(callback)).to.equal(1)
        advance(1000)
        expect(calls(callback)).to.equal(1)
      end)
    )

    -- index.spec.ts:32
    it(
      "dispose",
      withContext(function(ctx)
        local callback = spy.fn()
        local dispose = ctx:timeout(callback, 1000)
        expect(calls(callback)).to.equal(0)
        dispose()
        advance(2000)
        expect(calls(callback)).to.equal(0)
      end)
    )

    -- index.spec.ts:41
    it(
      "promise",
      withContext(function(ctx)
        local resolve = spy.fn()
        local reject = spy.fn()
        ctx:timeout(1000):next(resolve, reject)
        advance(500)
        expect(calls(resolve)).to.equal(0)
        expect(calls(reject)).to.equal(0)
        advance(500)
        expect(calls(resolve)).to.equal(1)
        expect(calls(reject)).to.equal(0)
        ctx.fiber:dispose()
        advance(2000)
        expect(calls(resolve)).to.equal(1)
        expect(calls(reject)).to.equal(0)
      end)
    )
  end)

  describe("ctx.interval()", function()
    -- index.spec.ts:59
    it(
      "basic support",
      withContext(function(ctx)
        local callback = spy.fn()
        local dispose = ctx:interval(callback, 1000)
        expect(calls(callback)).to.equal(0)
        advance(1000)
        expect(calls(callback)).to.equal(1)
        advance(1000)
        expect(calls(callback)).to.equal(2)
        dispose()
        advance(2000)
        expect(calls(callback)).to.equal(2)
      end)
    )

    -- index.spec.ts:72
    it(
      "async iterator (manual return)",
      withContext(function(ctx)
        local callback = spy.fn()
        local iterator = ctx:interval(1000)
        local iterate = cordis.async(function()
          forAwait(iterator, function()
            callback()
          end)
        end)
        local resolve = spy.fn()
        local reject = spy.fn()
        iterate(ctx):next(resolve, reject)
        expect(calls(callback)).to.equal(0)
        advance(1000)
        expect(calls(callback)).to.equal(1)
        advance(1000)
        expect(calls(callback)).to.equal(2)
        iterator["return"](iterator)
        advance(1000)
        expect(calls(callback)).to.equal(2)
        expect(calls(resolve)).to.equal(1)
        expect(calls(reject)).to.equal(0)
      end)
    )

    -- index.spec.ts:95
    it(
      "async iterator (concurrent reads)",
      withContext(function(ctx)
        local iterator = ctx:interval(1000)
        local first = iterator:next()
        local second = iterator:next()
        local firstResolve = spy.fn()
        local secondResolve = spy.fn()
        first:next(firstResolve)
        second:next(secondResolve)

        advance(1000)
        expect(calls(firstResolve)).to.equal(1)
        expect(calls(secondResolve)).to.equal(0)

        advance(1000)
        expect(calls(firstResolve)).to.equal(1)
        expect(calls(secondResolve)).to.equal(1)
        expect(cordis.Future.all(ctx.host, { first, second }):await()).to.deep.equal({
          { done = false, value = nil },
          { done = false, value = nil },
        })
      end)
    )

    -- index.spec.ts:117
    it(
      "async iterator (return with concurrent reads)",
      withContext(function(ctx)
        local iterator = ctx:interval(1000)
        local reads = { iterator:next(), iterator:next(), iterator:next() }

        expect(iterator["return"](iterator, 42):await()).to.deep.equal({ done = true, value = 42 })
        expect(cordis.Future.all(ctx.host, reads):await()).to.deep.equal({
          { done = true, value = 42 },
          { done = true, value = 42 },
          { done = true, value = 42 },
        })
        expect(iterator:next():await()).to.deep.equal({ done = true, value = 42 })
      end)
    )

    -- index.spec.ts:130
    it(
      "async iterator (throw with concurrent reads)",
      withContext(function(ctx)
        local iterator = ctx:interval(1000)
        local reads = { iterator:next(), iterator:next(), iterator:next() }
        local reason = cordis.Error.new("test")

        expect(iterator:throw(reason):await()).to.deep.equal({ done = true, value = nil })
        for _, read in ipairs(reads) do
          expect(read).to.reject(same(reason))
        end
        expect(iterator:next()).to.reject(same(reason))
      end)
    )

    -- index.spec.ts:140
    it(
      "async iterator (manual throw)",
      withContext(function(ctx)
        local callback = spy.fn()
        local iterator = ctx:interval(1000)
        local iterate = cordis.async(function()
          forAwait(iterator, function()
            callback()
          end)
        end)
        local resolve = spy.fn()
        local reject = spy.fn()
        iterate(ctx):next(resolve, reject)
        expect(calls(callback)).to.equal(0)
        advance(1000)
        expect(calls(callback)).to.equal(1)
        advance(1000)
        expect(calls(callback)).to.equal(2)
        iterator:throw()
        advance(1000)
        expect(calls(callback)).to.equal(2)
        expect(calls(resolve)).to.equal(0)
        expect(calls(reject)).to.equal(1)
      end)
    )

    -- index.spec.ts:163
    it(
      "async iterator (break return)",
      withContext(function(ctx)
        local callback = spy.fn()
        local iterator = ctx:interval(1000)
        local iterate = cordis.async(function()
          local i = 0
          forAwait(iterator, function()
            i = i + 1
            if i > 2 then
              return true
            end
            callback()
          end)
        end)
        local resolve = spy.fn()
        local reject = spy.fn()
        iterate(ctx):next(resolve, reject)
        expect(calls(callback)).to.equal(0)
        advance(1000)
        expect(calls(callback)).to.equal(1)
        advance(1000)
        expect(calls(callback)).to.equal(2)
        advance(1000)
        expect(calls(callback)).to.equal(2)
        expect(calls(resolve)).to.equal(1)
        expect(calls(reject)).to.equal(0)
      end)
    )

    -- index.spec.ts:187
    it(
      "async iterator (break throw)",
      withContext(function(ctx)
        local callback = spy.fn()
        local iterator = ctx:interval(1000)
        local iterate = cordis.async(function()
          local i = 0
          forAwait(iterator, function()
            i = i + 1
            if i > 2 then
              error(cordis.Error.new("test"))
            end
            callback()
          end)
        end)
        local resolve = spy.fn()
        local reject = spy.fn()
        iterate(ctx):next(resolve, reject)
        expect(calls(callback)).to.equal(0)
        advance(1000)
        expect(calls(callback)).to.equal(1)
        advance(1000)
        expect(calls(callback)).to.equal(2)
        advance(1000)
        expect(calls(callback)).to.equal(2)
        expect(calls(resolve)).to.equal(0)
        expect(calls(reject)).to.equal(1)
      end)
    )

    -- index.spec.ts:211
    it(
      "async iterator (context dispose)",
      withContext(function(ctx)
        local callback = spy.fn()
        local iterator
        local fiber = cordis.await(ctx:use({
          inject = { "timer" },
          apply = function(ctx)
            iterator = ctx:interval(1000)
          end,
        }))
        local iterate = cordis.async(function()
          forAwait(iterator, function()
            callback()
          end)
        end)
        local resolve = spy.fn()
        local reject = spy.fn()
        iterate(ctx):next(resolve, reject)
        expect(calls(callback)).to.equal(0)
        advance(1000)
        expect(calls(callback)).to.equal(1)
        advance(1000)
        expect(calls(callback)).to.equal(2)
        cordis.await(fiber:dispose())
        advance(1000)
        expect(calls(callback)).to.equal(2)
        expect(calls(resolve)).to.equal(0)
        expect(calls(reject)).to.equal(1)
      end)
    )

    -- index.spec.ts:240
    it(
      "async iterator (context dispose with concurrent reads)",
      withContext(function(ctx)
        local iterator
        local fiber = cordis.await(ctx:use({
          inject = { "timer" },
          apply = function(ctx)
            iterator = ctx:interval(1000)
          end,
        }))
        local reads = { iterator:next(), iterator:next(), iterator:next() }
        cordis.await(fiber:dispose())
        for _, read in ipairs(reads) do
          expect(read).to.reject("Context has been disposed")
        end
      end)
    )
  end)

  describe("ctx.throttle()", function()
    -- index.spec.ts:257
    it(
      "basic support",
      withContext(function(ctx)
        local callback = spy.fn()
        local throttled = ctx:throttle(callback, 1000)
        throttled()
        expect(calls(callback)).to.equal(1)
        advance(600)
        throttled()
        expect(calls(callback)).to.equal(1)
        advance(600)
        throttled()
        expect(calls(callback)).to.equal(2)
        advance(2000)
        expect(calls(callback)).to.equal(3)
      end)
    )

    -- index.spec.ts:272
    it(
      "trailing mode",
      withContext(function(ctx)
        local callback = spy.fn()
        local throttled = ctx:throttle(callback, 1000)
        throttled()
        expect(calls(callback)).to.equal(1)
        advance(500)
        throttled()
        expect(calls(callback)).to.equal(1)
        advance(500)
        expect(calls(callback)).to.equal(2)
        advance(2000)
        expect(calls(callback)).to.equal(2)
      end)
    )

    -- index.spec.ts:286
    it(
      "no trailing mode",
      withContext(function(ctx)
        local callback = spy.fn()
        local throttled = ctx:throttle(callback, 1000, true)
        throttled()
        expect(calls(callback)).to.equal(1)
        advance(500)
        throttled()
        expect(calls(callback)).to.equal(1)
        advance(2000)
        expect(calls(callback)).to.equal(1)
        throttled()
        expect(calls(callback)).to.equal(2)
      end)
    )

    -- The wall clock is moved by replacing `os.time` / `os.clock`, which the
    -- timer must not read; upstream moves `Date.now` with
    -- `vi.setSystemTime` while `performance.now` keeps elapsing.
    local function withWallClock(at, fn)
      local time, clock = os.time, os.clock
      os.time = function()
        return at
      end
      os.clock = function()
        return at
      end
      local ok, err = pcall(fn)
      os.time, os.clock = time, clock
      if not ok then
        error(err, 0)
      end
    end

    -- index.spec.ts:300
    it(
      "uses elapsed time when the wall clock moves backwards",
      withContext(function(ctx)
        withWallClock(1767229200, function() -- 2026-01-01T01:00:00Z
          local callback = spy.fn()
          local throttled = ctx:throttle(callback, 1000)
          throttled()
          advance(400)
          os.time = function()
            return 1767225600 -- 2026-01-01T00:00:00Z
          end
          throttled()
          advance(600)
          expect(calls(callback)).to.equal(2)
        end)
      end)
    )

    -- index.spec.ts:311
    it(
      "does not release the throttle early when the wall clock moves forwards",
      withContext(function(ctx)
        withWallClock(1767225600, function() -- 2026-01-01T00:00:00Z
          local callback = spy.fn()
          local throttled = ctx:throttle(callback, 1000)
          throttled()
          advance(400)
          os.time = function()
            return 1767229200 -- 2026-01-01T01:00:00Z
          end
          throttled()
          expect(calls(callback)).to.equal(1)
          advance(600)
          expect(calls(callback)).to.equal(2)
        end)
      end)
    )

    -- index.spec.ts:323
    it(
      "context dispose",
      withContext(function(ctx)
        local callback = spy.fn()
        local throttled
        local fiber = cordis.await(ctx:use({
          inject = { "timer" },
          apply = function(ctx)
            throttled = ctx:throttle(callback, 1000)
          end,
        }))
        throttled()
        expect(calls(callback)).to.equal(1)
        advance(500)
        throttled()
        cordis.await(fiber:dispose())
        advance(2000)
        expect(calls(callback)).to.equal(1)
        throttled()
        expect(calls(callback)).to.equal(1)
      end)
    )

    -- index.spec.ts:343
    it(
      "disposed",
      withContext(function(ctx)
        local callback = spy.fn()
        local throttled = ctx:throttle(callback, 1000)
        throttled.dispose()
        throttled()
        expect(calls(callback)).to.equal(0)
        advance(500)
        throttled()
        advance(2000)
        expect(calls(callback)).to.equal(0)
      end)
    )

    -- index.spec.ts:355
    it(
      "disposed with noTrailing",
      withContext(function(ctx)
        local callback = spy.fn()
        local throttled = ctx:throttle(callback, 1000, true)
        throttled.dispose()
        throttled()
        expect(calls(callback)).to.equal(0)
        advance(2000)
        throttled()
        expect(calls(callback)).to.equal(0)
      end)
    )

    -- index.spec.ts:366
    it(
      "context dispose with re-entrant callback",
      withContext(function(ctx)
        local callback = spy.fn()
        local throttled
        local fiber = cordis.await(ctx:use({
          inject = { "timer" },
          apply = function(ctx)
            throttled = ctx:throttle(function()
              callback()
              throttled()
            end, 1000)
          end,
        }))
        throttled()
        expect(calls(callback)).to.equal(1)
        cordis.await(fiber:dispose())
        advance(2000)
        expect(calls(callback)).to.equal(1)
      end)
    )
  end)

  describe("ctx.debounce()", function()
    -- index.spec.ts:387
    it(
      "basic support",
      withContext(function(ctx)
        local callback = spy.fn()
        local debounced = ctx:debounce(callback, 1000)
        debounced()
        expect(calls(callback)).to.equal(0)
        advance(400)
        debounced()
        expect(calls(callback)).to.equal(0)
        advance(400)
        debounced()
        expect(calls(callback)).to.equal(0)
        advance(1000)
        expect(calls(callback)).to.equal(1)
      end)
    )

    -- index.spec.ts:402
    it(
      "disposed",
      withContext(function(ctx)
        local callback = spy.fn()
        local debounced = ctx:debounce(callback, 1000)
        debounced.dispose()
        debounced()
        expect(calls(callback)).to.equal(0)
        advance(2000)
        expect(calls(callback)).to.equal(0)
      end)
    )

    -- index.spec.ts:412
    it(
      "context dispose",
      withContext(function(ctx)
        local callback = spy.fn()
        local debounced
        local fiber = cordis.await(ctx:use({
          inject = { "timer" },
          apply = function(ctx)
            debounced = ctx:debounce(callback, 1000)
          end,
        }))
        debounced()
        cordis.await(fiber:dispose())
        advance(2000)
        expect(calls(callback)).to.equal(0)
        debounced()
        advance(2000)
        expect(calls(callback)).to.equal(0)
      end)
    )
  end)
end)
