-- Ported from cordis packages/core/tests/events.spec.ts (MIT, (c) Shigma)
local cordis = require("cordis")
local U = require("kit.util")
local spy = require("kit.spy")
local F = require("core.fixtures")
local event, Filter, Session = F.event, F.Filter, F.Session

local function setup()
  local root = U.root()
  local warn = spy.fn()
  root.logger.warn = warn
  return root, warn
end

local function firstArgs(s)
  local r = {}
  for i, call in ipairs(s.calls) do
    r[i] = call[1]
  end
  return r
end

local function dispatch(root, mode, ...)
  return cordis.await(root[mode](root, ...))
end

local function add(value, nextFn)
  return value + nextFn()
end

describe("Events", function()
  -- events.spec.ts:18
  it("deprecated dispatch returns bound callbacks that respect later removal", function()
    local root = setup()
    local name = cordis.symbol("legacy")
    local target = {}
    local callback = spy.fn(function(this, value)
      expect(this).to.equal(target)
      return value
    end)
    local dispose = root:on(name, callback)
    local invoke = root.events:dispatch("bail", { target, name })[1]

    expect(invoke("value")).to.equal("value")
    dispose()
    expect(invoke("removed")).to.equal(nil)
    expect(callback.calls).to.have.length(1)
  end)

  -- events.spec.ts:35
  it("deprecated waterfall dispatch continues past a removed callback", function()
    local root = setup()
    local name = cordis.symbol("legacy waterfall")
    local callback = spy.fn()
    local dispose = root:on(name, callback)
    local invoke = root.events:dispatch("waterfall", { name })[1]
    local nextFn = spy.fn(function()
      return "continued"
    end)

    dispose()
    expect(invoke("value", nextFn)).to.equal("continued")
    expect(callback.calls).to.have.length(0)
    expect(nextFn.calls).to.have.length(1)
  end)

  -- events.spec.ts:49
  it("supports symbol event names across dispatch modes", function()
    local root = setup()
    local ev = cordis.symbol("event")
    local callback = spy.fn(function(value)
      return value
    end)
    local dispose = root:on(ev, callback)

    root:emit(ev, 1)
    expect(root:bail(ev, 2)).to.equal(2)
    expect(cordis.await(root:serial(ev, 3))).to.equal(3)
    cordis.await(root:parallel(ev, 4))
    expect(firstArgs(callback)).to.deep.equal({ 1, 2, 3, 4 })

    dispose()
    root:emit(ev, 5)
    expect(callback.calls).to.have.length(4)
  end)

  -- events.spec.ts:66
  it("supports symbol event names with ctx.once()", function()
    local root = setup()
    local ev = cordis.symbol("once")
    local callback = spy.fn()
    root:once(ev, callback)

    root:emit(ev)
    root:emit(ev)
    expect(callback.calls).to.have.length(1)
  end)

  -- events.spec.ts:77 (rewritten: Lua's metamethod names instead of JS prototype names)
  it("treats prototype property names as ordinary events", function()
    local root = setup()

    -- dispatching an unregistered name must not reach a metatable
    expect(function()
      root:emit("__index")
    end).never.to.throw()

    for _, name in ipairs({ "__index", "__newindex", "toString", "constructor" }) do
      local callback = spy.fn()
      local dispose = root:on(name, callback)

      root:emit(name)
      expect(callback.calls).to.have.length(1)
      dispose()
      root:emit(name)
      expect(callback.calls).to.have.length(1)
      expect(rawget(root.events._hooks, name)).to.equal(nil)
    end
  end)

  -- events.spec.ts:96
  it("removes empty event buckets after disposal", function()
    local root = setup()
    local ev = cordis.symbol("temporary")
    local first = root:on(ev, function() end)
    local second = root:on(ev, function() end)

    first()
    expect(root.events._hooks[ev] ~= nil).to.equal(true)
    second()
    expect(root.events._hooks[ev] ~= nil).to.equal(false)
  end)

  -- events.spec.ts:108
  it("ctx.on()", function()
    local root = setup()
    local callback = spy.fn()
    local dispose = root:on(event, callback)
    root:emit(event)
    expect(callback.calls).to.have.length(1)
    root:emit(event)
    expect(callback.calls).to.have.length(2)
    dispose()
    root:emit(event)
    expect(callback.calls).to.have.length(2)
  end)

  -- events.spec.ts:121
  it("ctx.once()", function()
    local root = setup()
    local callback = spy.fn()
    local dispose = root:once(event, callback)
    root:emit(event)
    expect(callback.calls).to.have.length(1)
    root:emit(event)
    expect(callback.calls).to.have.length(1)
    dispose()
    root:emit(event)
    expect(callback.calls).to.have.length(1)
  end)

  -- events.spec.ts:134
  it("ctx.once() runs once when an earlier listener emits recursively", function()
    local root = setup()
    local nested = false
    root:on(event, function()
      if nested then
        return
      end
      nested = true
      root:emit(event)
    end)
    local callback = spy.fn()
    root:once(event, callback)

    root:emit(event)
    expect(callback.calls).to.have.length(1)
  end)

  -- events.spec.ts:149
  it("ctx.once() runs once across concurrent serial dispatches", function()
    local root = setup()
    local barrier, resolve = cordis.Future.withResolvers(U.host())
    root:on(event, function()
      return barrier
    end)
    local callback = spy.fn()
    root:once(event, callback)

    local first = root:serial(event)
    local second = root:serial(event)
    resolve()
    cordis.Future.all(U.host(), { first, second }):await()
    expect(callback.calls).to.have.length(1)
  end)

  -- events.spec.ts:163 (it.each over emit, parallel, serial, bail)
  it("%s skips listeners removed during dispatch", function()
    for _, mode in ipairs({ "emit", "parallel", "serial", "bail" }) do
      local root = setup()
      local dispose
      root:on(event, function()
        dispose()
      end)
      local removed = spy.fn()
      dispose = root:on(event, removed)
      local remaining = spy.fn()
      root:on(event, remaining)

      dispatch(root, mode, event)
      expect(removed.calls).to.have.length(0)
      expect(remaining.calls).to.have.length(1)
    end
  end)

  -- events.spec.ts:177 (it.each over emit, parallel, serial, bail)
  it("%s defers added listeners until the next dispatch", function()
    for _, mode in ipairs({ "emit", "parallel", "serial", "bail" }) do
      local root = setup()
      local added = spy.fn()
      root:on(event, function()
        root:on(event, added)
      end)

      dispatch(root, mode, event)
      expect(added.calls).to.have.length(0)
      dispatch(root, mode, event)
      expect(added.calls).to.have.length(1)
    end
  end)

  -- events.spec.ts:188
  it("skips a listener disposed by an earlier component during dispatch", function()
    local root = setup()
    local child
    root:on(
      event,
      cordis.async(function()
        cordis.await(child:dispose())
      end)
    )
    local removed = spy.fn()
    child = root:use(function(ctx)
      ctx:on(event, removed)
    end)
    cordis.await(child)

    cordis.await(root:serial(event))
    expect(removed.calls).to.have.length(0)
  end)

  -- events.spec.ts:200
  it("waterfall continues past a removed listener", function()
    local root = setup()
    local dispose
    root:on("test/waterfall", function(value, nextFn)
      dispose()
      return value + nextFn()
    end)
    local removed = spy.fn(add)
    dispose = root:on("test/waterfall", removed)
    local remaining = spy.fn(add)
    root:on("test/waterfall", remaining)
    local terminal = spy.fn(function()
      return 2
    end)

    expect(root:waterfall("test/waterfall", 1, terminal)).to.equal(4)
    expect(removed.calls).to.have.length(0)
    expect(remaining.calls).to.have.length(1)
    expect(terminal.calls).to.have.length(1)
  end)

  -- events.spec.ts:219
  it("waterfall defers added listeners until the next dispatch", function()
    local root = setup()
    local added = spy.fn(add)
    root:on("test/waterfall", function(_, nextFn)
      root:on("test/waterfall", added)
      return nextFn()
    end)

    local function two()
      return 2
    end
    expect(root:waterfall("test/waterfall", 1, two)).to.equal(2)
    expect(added.calls).to.have.length(0)
    expect(root:waterfall("test/waterfall", 1, two)).to.equal(3)
    expect(added.calls).to.have.length(1)
  end)

  -- events.spec.ts:233
  it("waterfall continues after a recursive dispatch has consumed a once listener", function()
    local root = setup()
    local nested = false
    local function two()
      return 2
    end
    root:on("test/waterfall", function(value, nextFn)
      if not nested then
        nested = true
        root:waterfall("test/waterfall", value, two)
      end
      return nextFn()
    end)
    local once = spy.fn(add)
    root:once("test/waterfall", once)
    root:on("test/waterfall", add)

    expect(root:waterfall("test/waterfall", 1, two)).to.equal(3)
    expect(once.calls).to.have.length(1)
  end)

  -- events.spec.ts:251 (internal/update listeners receive the fiber first)
  it("internal/update continues past a removed fiber listener", function()
    local root = setup()
    local removed = spy.fn()
    local remaining = spy.fn()
    local loaded = {}
    local child = root:use(function(ctx, config)
      loaded[#loaded + 1] = config.n
      local dispose
      ctx:on("internal/update", function(_, _, nextFn)
        dispose()
        return nextFn()
      end)
      dispose = ctx:on("internal/update", function(_, _, nextFn)
        removed()
        return nextFn()
      end)
      ctx:on("internal/update", function(_, _, nextFn)
        remaining()
        return nextFn()
      end)
    end, { n = 0 })
    cordis.await(child)

    cordis.await(child:update({ n = 1 }))
    expect(removed.calls).to.have.length(0)
    expect(remaining.calls).to.have.length(1)
    expect(loaded).to.deep.equal({ 0, 1 })
  end)

  -- events.spec.ts:280
  it("ctx.parallel()", function()
    local root = setup()
    cordis.await(root:parallel(event))
    local callback = spy.fn()
    root:extend(Filter.new(true)):on(event, callback)

    cordis.await(root:parallel(event))
    expect(callback.calls).to.have.length(1)
    cordis.await(root:parallel(Session.new(false), event))
    expect(callback.calls).to.have.length(1)
    cordis.await(root:parallel(Session.new(true), event))
    expect(callback.calls).to.have.length(2)

    -- a rejecting listener must not short-circuit the others
    local settled = false
    local dispose = root:on(
      event,
      cordis.async(function()
        U.sleep(0)
        settled = true
        error(cordis.Error.new("async"))
      end)
    )
    callback:mockImplementation(function()
      error(cordis.Error.new("test"))
    end)
    local err = expect(root:parallel(event)).to.reject()
    expect(err).to.be.instanceof(cordis.AggregateError)
    expect(err.message).to.equal('one or more listeners of event "custom-event" failed')
    local messages = {}
    for _, e in ipairs(err.errors) do
      messages[#messages + 1] = e.message
    end
    table.sort(messages)
    expect(messages).to.deep.equal({ "async", "test" })
    expect(settled).to.equal(true)
    dispose()
  end)

  -- events.spec.ts:311
  it("ctx.parallel() labels symbol events", function()
    local root = setup()
    local ev = cordis.symbol("parallel")
    root:on(ev, function()
      error(cordis.Error.new("test"))
    end)
    local err = expect(root:parallel(ev)).to.reject()
    expect(err).to.be.instanceof(cordis.AggregateError)
    expect(err.message).to.equal("one or more listeners of event Symbol(parallel) failed")
  end)

  -- events.spec.ts:322
  it("ctx.emit()", function()
    local root = setup()
    root:emit(event)
    local callback = spy.fn()
    root:extend(Filter.new(true)):on(event, callback)

    root:emit(event)
    expect(callback.calls).to.have.length(1)
    root:emit(Session.new(false), event)
    expect(callback.calls).to.have.length(1)
    root:emit(Session.new(true), event)
    expect(callback.calls).to.have.length(2)

    callback:mockImplementation(function()
      error(cordis.Error.new("test"))
    end)
    expect(function()
      root:emit(event)
    end).to.throw("test")
  end)

  -- events.spec.ts:341
  it("ctx.serial()", function()
    local root = setup()
    root:serial(event)
    local callback = spy.fn()
    root:extend(Filter.new(true)):on(event, callback)

    root:serial(event)
    expect(callback.calls).to.have.length(1)
    root:serial(Session.new(false), event)
    expect(callback.calls).to.have.length(1)
    root:serial(Session.new(true), event)
    expect(callback.calls).to.have.length(2)

    callback:mockImplementation(function()
      error(cordis.Error.new("message"))
    end)
    expect(root:serial(event)).to.reject("message")
  end)

  -- events.spec.ts:360
  it("ctx.bail()", function()
    local root = setup()
    root:bail(event)
    local callback = spy.fn()
    root:extend(Filter.new(true)):on(event, callback)

    root:bail(event)
    expect(callback.calls).to.have.length(1)
    root:bail(Session.new(false), event)
    expect(callback.calls).to.have.length(1)
    root:bail(Session.new(true), event)
    expect(callback.calls).to.have.length(2)

    callback:mockImplementation(function()
      error(cordis.Error.new("message"))
    end)
    expect(function()
      root:bail(event)
    end).to.throw("message")
  end)

  -- events.spec.ts:379
  it("ctx.waterfall()", function()
    local root = setup()
    local function two()
      return 2
    end
    local cb1 = spy.fn(add)
    root:on("test/waterfall", cb1)
    local cb2 = spy.fn(add)
    root:on("test/waterfall", cb2)

    expect(root:waterfall("test/waterfall", 1, two)).to.equal(4)
    expect(cb1.calls).to.have.length(1)
    expect(cb2.calls).to.have.length(1)
    cb1:reset()
    cb2:reset()

    local cb3 = spy.fn(function(value)
      return value
    end)
    root:on("test/waterfall", cb3)
    local cb4 = spy.fn(add)
    root:on("test/waterfall", cb4)
    expect(root:waterfall("test/waterfall", 1, two)).to.equal(3)
    expect(cb1.calls).to.have.length(1)
    expect(cb2.calls).to.have.length(1)
    expect(cb3.calls).to.have.length(1)
    expect(cb4.calls).to.have.length(0)
  end)

  -- events.spec.ts:407
  it("ctx.waterfall() rejects duplicate next()", function()
    local root = setup()
    local terminal = spy.fn(function()
      return 2
    end)
    local callback = spy.fn(function(_, nextFn)
      nextFn()
      return nextFn()
    end)
    root:on("test/waterfall", callback)

    expect(function()
      root:waterfall("test/waterfall", 1, terminal)
    end).to.throw("next() called multiple times")
    expect(callback.calls).to.have.length(1)
    expect(terminal.calls).to.have.length(1)
  end)

  -- events.spec.ts:421
  it("ctx.waterfall() rejects continuations from outer frames", function()
    local root = setup()
    local calls = {}
    local outerNext
    root:on("test/waterfall", function(_, nextFn)
      outerNext = nextFn
      calls[#calls + 1] = "first"
      return nextFn()
    end)
    root:on("test/waterfall", function(_, nextFn)
      calls[#calls + 1] = "second"
      return nextFn()
    end)

    expect(function()
      root:waterfall("test/waterfall", 1, function()
        calls[#calls + 1] = "terminal"
        return outerNext()
      end)
    end).to.throw("next() called multiple times")
    expect(calls).to.deep.equal({ "first", "second", "terminal" })
  end)

  -- events.spec.ts:442
  it("ctx.waterfall() rejects duplicate next() after awaiting", function()
    local root = setup()
    local terminal = spy.fn(function()
      return 2
    end)
    root:on(
      "test/async-waterfall",
      cordis.async(function(value, nextFn)
        local result = cordis.await(nextFn())
        expect(function()
          nextFn()
        end).to.throw("next() called multiple times")
        return value + result
      end)
    )

    expect(cordis.await(root:waterfall("test/async-waterfall", 1, terminal))).to.equal(3)
    expect(terminal.calls).to.have.length(1)
  end)

  -- events.spec.ts:455
  it("ctx.waterfall() supports nested async calls", function()
    local root = setup()
    local terminal = spy.fn(function()
      return 2
    end)
    local callback = spy.fn(cordis.async(function(value, nextFn)
      local result = cordis.await(nextFn())
      if value == 1 then
        return result + cordis.await(root:waterfall("test/async-waterfall", 2, terminal))
      end
      return result
    end))
    root:on("test/async-waterfall", callback)

    expect(cordis.await(root:waterfall("test/async-waterfall", 1, terminal))).to.equal(4)
    expect(callback.calls).to.have.length(2)
    expect(terminal.calls).to.have.length(2)
  end)

  describe("internal/update", function()
    -- events.spec.ts:473
    it("does not accumulate across reloads", function()
      local root = setup()
      local calls = {}
      local fiber = root:use(function(ctx)
        ctx:on("internal/update", function(_, config, nextFn)
          calls[#calls + 1] = config.n
          return nextFn()
        end)
      end, { n = 0 })

      cordis.await(fiber)
      cordis.await(fiber:update({ n = 1 }))
      cordis.await(fiber:update({ n = 2 }))
      cordis.await(fiber:update({ n = 3 }))
      expect(calls).to.deep.equal({ 1, 2, 3 })
    end)

    -- events.spec.ts:490
    it("can be disposed explicitly", function()
      local root = setup()
      local calls = {}
      local dispose
      local fiber = root:use(function(ctx)
        dispose = ctx:on("internal/update", function(_, config, nextFn)
          calls[#calls + 1] = config.n
          return nextFn()
        end)
      end, { n = 0 })

      cordis.await(fiber)
      dispose()
      cordis.await(fiber:update({ n = 1 }))
      expect(calls).to.deep.equal({})
    end)

    -- events.spec.ts:507
    it("runs prepended listeners first", function()
      local root = setup()
      local order = {}
      local dispose
      local fiber = root:use(function(ctx)
        local function listen(name, prepend)
          return ctx:on("internal/update", function(_, _, nextFn)
            order[#order + 1] = name
            return nextFn()
          end, { prepend = prepend })
        end
        listen("a")
        dispose = listen("b", true)
        listen("c")
        listen("d", true)
      end, { n = 0 })

      cordis.await(fiber)
      cordis.await(fiber:update({ n = 1 }))
      expect(order).to.deep.equal({ "d", "b", "a", "c" })

      order = {}
      dispose()
      cordis.await(fiber:update({ n = 2 }))
      expect(order).to.deep.equal({ "d", "a", "c" })
    end)

    -- events.spec.ts:534
    it("global listeners are not tied to a child fiber reload", function()
      local root = setup()
      local globalCalls = {}
      local localCalls = {}
      root:on("internal/update", function(_, config, nextFn)
        globalCalls[#globalCalls + 1] = config.n
        return nextFn()
      end, { global = true })

      local fiber = root:use(function(ctx)
        ctx:on("internal/update", function(_, config, nextFn)
          localCalls[#localCalls + 1] = config.n
          return nextFn()
        end)
      end, { n = 0 })

      cordis.await(fiber)
      cordis.await(fiber:update({ n = 1 }))
      cordis.await(fiber:update({ n = 2 }))
      expect(globalCalls).to.deep.equal({ 1, 2 })
      expect(localCalls).to.deep.equal({ 1, 2 })
    end)
  end)
end)
