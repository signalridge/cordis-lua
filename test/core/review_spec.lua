-- Regression tests for upstream behavior. Each case failed
-- against 6af1bab; references point at the upstream behaviour being restored.
local cordis = require("cordis")
local U = require("kit.util")
local spy = require("kit.spy")
local F = require("core.fixtures")
local Future = cordis.Future
local FiberState = cordis.FiberState

describe("upstream behavior regressions", function()
  -- fiber.ts:327, :481: an unload that waits for a setup in progress must
  -- settle when that setup fails
  it("an unload waiting for a failing effect setup still settles", function()
    local root = U.root()
    root.logger.error = spy.fn()
    local fiber = cordis.await(root:use(function() end))
    local gate, open = Future.withResolvers(U.host())
    local setupError
    cordis.async(function()
      local ok, err = pcall(function()
        fiber.ctx:effect(function()
          gate:await()
          error(cordis.Error.new("setup failed"))
        end)
      end)
      setupError = not ok and err
    end)()
    U.sleep(0)
    local disposing = fiber:dispose()
    U.sleep(0)
    open()
    cordis.await(disposing)
    expect(fiber.state).to.equal(FiberState.DISPOSED)
    expect(setupError.message).to.equal("setup failed")
  end)

  -- registry.ts:244, events.ts:108: `use()` results and effect disposers
  -- are thenables upstream; Future adoption waits for them
  it("Future adoption waits for fibers and effect disposers", function()
    local host = U.host()
    local root = U.root()
    local gate1, open1 = Future.withResolvers(host)
    root:on(F.event, function()
      return root:use(cordis.async(function()
        gate1:await()
      end))
    end)
    local dispatched = root:parallel(F.event)
    U.sleep(0)
    expect(dispatched:state()).to.equal("pending")
    open1()
    cordis.await(dispatched)

    local gate2, open2 = Future.withResolvers(host)
    local fiber = root:use(cordis.async(function()
      gate2:await()
    end))
    local all = Future.all(host, { fiber })
    U.sleep(0)
    expect(all:state()).to.equal("pending")
    open2()
    expect(all:await()[1]).to.equal(fiber)

    local gate3, open3 = Future.withResolvers(host)
    local dispose = root:effect(cordis.async(function()
      gate3:await()
      return function() end
    end))
    local chained = Future.resolve(host, nil):next(function()
      return dispose
    end)
    U.sleep(0)
    expect(chained:state()).to.equal("pending")
    open3()
    expect(type(chained:await())).to.equal("function")
  end)

  -- events.ts:108: the synchronous prefix of an async listener is the code
  -- before it returns its Future; it runs before later listeners are invoked
  it("an async listener's synchronous prefix runs before later listeners", function()
    local root = U.root()
    local second = spy.fn()
    local disposeSecond
    root:on(F.event, function()
      disposeSecond()
      return cordis.async(function()
        U.sleep(0)
      end)()
    end)
    disposeSecond = root:on(F.event, second)
    cordis.await(root:parallel(F.event))
    expect(second.calls).to.have.length(0)
  end)

  -- events.ts:126: `serial` awaits every listener result before the next one
  it("serial continues after an await even for synchronous results", function()
    local root = U.root()
    root:on(F.event, function() end)
    local second = spy.fn()
    local disposeSecond = root:on(F.event, second)
    local dispatched = root:serial(F.event)
    disposeSecond()
    cordis.await(dispatched)
    expect(second.calls).to.have.length(0)
  end)

  -- awaiting a Future of another host releases the job queue the waiting
  -- task is draining
  it("awaiting across hosts does not starve the waiting task's queue", function()
    local hostA = U.host()
    local hostB = { spawn = hostA.spawn, latch = hostA.latch, sleep = hostA.sleep, now = hostA.now }
    local futureB, resolveB = Future.withResolvers(hostB)
    local seen
    Future.resolve(hostA, nil):next(function()
      seen = futureB:await()
    end)
    Future.resolve(hostA, nil):next(function()
      resolveB("done")
    end)
    U.sleep(0)
    U.sleep(0)
    expect(seen).to.equal("done")
  end)

  -- a failing job is reported, and the queue keeps running
  it("a failing job does not stop the host's job queue", function()
    local host = U.host()
    local sched = U.sched()
    local before = #sched.errors
    cordis.future.queueMicrotask(host, function()
      error("job failed", 0)
    end)
    local later = Future.resolve(host, 1):next(function(v)
      return v + 1
    end)
    U.sleep(0)
    expect(later:state()).to.equal("fulfilled")
    expect(#sched.errors).to.equal(before + 1)
    expect(sched.errors[#sched.errors]:find("job failed", 1, true) ~= nil).to.equal(true)
    table.remove(sched.errors)
  end)

  -- `cordis.async` finds its host from a Context argument
  it("cordis.async finds the host from a Context argument", function()
    local root = U.root()
    local child = root:extend({})
    local results = {}
    local fn = cordis.async(function(ctx)
      return ctx == child
    end)
    -- a host task the library did not start knows no host of its own
    U.host().spawn(function()
      local ok, f = pcall(fn, child)
      results.ok = ok
      results.future = ok and f or nil
    end)
    U.sleep(0)
    expect(results.ok).to.equal(true)
    expect(results.future:await()).to.equal(true)
  end)

  -- registry.ts:25, fiber.ts:158: `@Inject` on a method of a plain class
  it("Inject.method initializes on a plain class", function()
    local root = U.root()
    local calls = spy.fn()
    local Plain = cordis.class("Plain")
    function Plain:constructor(ctx)
      self.ctx = ctx
    end
    function Plain:run()
      calls(self.ctx.db)
    end
    cordis.Inject.method(Plain, "run", { "db" })
    cordis.await(root:use(Plain))
    root:provide("db", "database")
    U.sleep(0)
    expect(calls.calls).to.have.length(1)
    expect(calls.calls[1][1]).to.equal("database")
  end)

  -- registry.ts:25: repeated `@Inject` on one method share their dependencies
  it("repeated Inject.method declarations merge their dependencies", function()
    local root = U.root()
    local calls = spy.fn()
    local Svc = cordis.class("Svc", cordis.Service)
    function Svc:constructor(ctx)
      cordis.Service.constructor(self, ctx, "svc")
    end
    function Svc:run()
      calls(self.ctx.db, self.ctx.cache)
    end
    cordis.Inject.method(Svc, "run", { "db" })
    cordis.Inject.method(Svc, "run", { "cache" })
    cordis.await(root:use(Svc))
    root:provide("db", "database")
    U.sleep(0)
    expect(calls.calls).to.have.length(0)
    root:provide("cache", "memory")
    U.sleep(0)
    -- one run per declaration, as upstream adds one initializer per decorator
    expect(calls.calls).to.have.length(2)
    expect(calls.calls[1][1]).to.equal("database")
    expect(calls.calls[1][2]).to.equal("memory")
  end)

  -- events.ts:110: a rejection without a reason still fails `parallel`
  it("parallel fails on a rejection without a reason", function()
    local host = U.host()
    local root = U.root()
    root:on(F.event, function()
      return Future.reject(host, nil)
    end)
    root:on(F.event, function()
      error(nil)
    end)
    local err = expect(root:parallel(F.event)).to.reject()
    expect(err).to.be.instanceof(cordis.AggregateError)
    expect(err.errors.n or #err.errors).to.equal(2)
  end)
end)
