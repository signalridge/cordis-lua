-- Ported from cordis packages/core/tests/service-dispose.spec.ts (MIT, (c) Shigma)
local cordis = require("cordis")
local U = require("kit.util")
local spy = require("kit.spy")
local Service = cordis.Service
local Future = cordis.Future

local function settle(x)
  return Future.resolve(U.host(), x)
end

local function gateFuture()
  local f, resolve = Future.withResolvers(U.host())
  return f, resolve
end

-- `await setImmediate()`
local function immediate()
  U.sleep(0)
end

local function fixture()
  local root = U.root()
  local timeline = {}
  local gate, openGate = gateFuture()
  local closed = false
  local Provider = cordis.class("Provider", Service)
  function Provider:constructor(ctx)
    Service.constructor(self, ctx, "foo")
  end
  Provider[Service.init] = cordis.iter(function(yield)
    closed = false
    yield(function()
      closed = true
      table.insert(timeline, "provider closed")
    end)
  end)
  function Provider:read()
    table.insert(timeline, "consumer read: " .. (closed and "closed" or "open"))
  end
  return {
    root = root,
    Provider = Provider,
    gate = gate,
    openGate = openGate,
    timeline = timeline,
    isClosed = function()
      return closed
    end,
  }
end

describe("Service disposal", function()
  -- service-dispose.spec.ts:31
  it("releases an injected binding after providing the same name in another realm (%s)", function()
    for _, action in ipairs({ "consumer", "provider", "root" }) do
      local root = U.root()
      local provider = cordis.await(root:use(function(ctx)
        ctx:provide("foo", { value = 1 })
      end))
      local consumer = cordis.await(root:inject({ "foo" }, function(ctx)
        ctx:isolate("foo"):provide("foo", { outer = ctx.foo })
      end))
      local task
      if action == "root" then
        task = settle(root.fiber:dispose())
      elseif action == "provider" then
        task = settle(provider:dispose())
      else
        task = settle(consumer:dispose()):next(function()
          return provider:dispose()
        end)
      end
      local disposed = false
      task:next(function()
        disposed = true
      end)
      immediate()
      expect(disposed).to.equal(true)
      cordis.await(task)
      cordis.await(root.fiber:dispose())
    end
  end)

  -- service-dispose.spec.ts:48
  it("waits for a disposing consumer that has already left the registry", function()
    local root = U.root()
    local gate, openGate = gateFuture()
    local timeline = {}
    local provider = cordis.await(root:use(function() end))
    local withdraw = provider.ctx:provide("foo", {})
    local consumer = cordis.await(root:inject({ "foo" }, function()
      return cordis.async(function()
        gate:await()
        table.insert(timeline, "consumer finished")
      end)
    end))
    local disposing = settle(consumer:dispose())
    local withdrawn = false
    local withdrawing = settle(withdraw()):next(function()
      withdrawn = true
      table.insert(timeline, "withdraw completed")
    end)
    immediate()
    local withdrawnDuringCleanup = withdrawn
    openGate()
    Future.all(U.host(), { disposing, withdrawing }):await()
    expect(withdrawnDuringCleanup).to.equal(false)
    expect(timeline).to.deep.equal({ "consumer finished", "withdraw completed" })
    cordis.await(root.fiber:dispose())
  end)

  -- service-dispose.spec.ts:73
  it("withdraws one binding without waiting for another binding from the same provider", function()
    local root = U.root()
    local gate, openGate = gateFuture()
    local provider = cordis.await(root:use(function() end))
    local withdraw = provider.ctx:provide("foo", {})
    provider.ctx:provide("bar", {})
    local first = cordis.await(root:inject({ "foo" }, function() end))
    local second = cordis.await(root:inject({ "bar" }, function()
      return cordis.async(function()
        gate:await()
      end)
    end))
    local disposing = settle(second:dispose())
    local withdrawn = false
    local withdrawing = settle(withdraw()):next(function()
      withdrawn = true
    end)
    immediate()
    local withdrawnDuringOtherCleanup = withdrawn
    openGate()
    Future.all(U.host(), { disposing, withdrawing }):await()
    expect(withdrawnDuringOtherCleanup).to.equal(true)
    cordis.await(first:dispose())
    cordis.await(root.fiber:dispose())
  end)

  -- service-dispose.spec.ts:95
  it("retains resources during consumer cleanup (%s)", function()
    for _, action in ipairs({ "provider", "root", "provider first", "consumer first", "restart" }) do
      local fx = fixture()
      local root, Provider, gate, openGate, timeline, isClosed =
        fx.root, fx.Provider, fx.gate, fx.openGate, fx.timeline, fx.isClosed
      local provider = cordis.await(root:use(Provider))
      local consumer = cordis.await(root:inject({ "foo" }, function(ctx)
        ctx:effect(function()
          return cordis.async(function()
            gate:await()
            ctx.foo:read()
          end)
        end)
      end))
      local task
      if action == "root" then
        task = settle(root.fiber:dispose())
      elseif action == "restart" then
        task = settle(provider:restart())
      elseif action == "consumer first" then
        task = Future.all(U.host(), { settle(consumer:dispose()), settle(provider:dispose()) })
      elseif action == "provider first" then
        task = Future.all(U.host(), { settle(provider:dispose()), settle(consumer:dispose()) })
      else
        task = settle(provider:dispose())
      end
      immediate()
      local closedDuringDrain = isClosed()
      openGate()
      cordis.await(task)
      expect(closedDuringDrain).to.equal(false)
      expect(timeline).to.deep.equal({ "consumer read: open", "provider closed" })
      if action == "restart" then
        cordis.await(consumer:await())
        expect(consumer.ctx.foo ~= nil).to.equal(true)
      end
      cordis.await(root.fiber:dispose())
    end
  end)

  -- service-dispose.spec.ts:131
  it("retains transitive dependencies while a consumer providing another service drains", function()
    U.requires("microtask order")
    local fx = fixture()
    local root, Provider, gate, openGate, timeline, isClosed =
      fx.root, fx.Provider, fx.gate, fx.openGate, fx.timeline, fx.isClosed
    local fibers = {}
    local owner = cordis.await(root:use(function(ctx)
      table.insert(fibers, ctx:use(Provider))
      table.insert(
        fibers,
        ctx:inject({ "foo" }, function(ctx)
          ctx:provide("bar", {})
          return function()
            ctx.foo:read()
          end
        end)
      )
      table.insert(
        fibers,
        ctx:inject({ "bar" }, function()
          return cordis.async(function()
            table.insert(timeline, "consumer draining")
            gate:await()
            table.insert(timeline, "consumer finished")
          end)
        end)
      )
    end))
    local awaits = {}
    for i, fiber in ipairs(fibers) do
      awaits[i] = fiber:await()
    end
    Future.all(U.host(), awaits):await()
    local task = settle(owner:dispose())
    immediate()
    local closedDuringDrain = isClosed()
    openGate()
    cordis.await(task)
    expect(closedDuringDrain).to.equal(false)
    expect(timeline).to.deep.equal({
      "consumer draining",
      "consumer finished",
      "consumer read: open",
      "provider closed",
    })
  end)

  -- service-dispose.spec.ts:156
  it("retains dependencies through in-flight setup and rollback (failure: %s)", function()
    for _, fail in ipairs({ false, true }) do
      local fx = fixture()
      local root, Provider, gate, openGate, timeline, isClosed =
        fx.root, fx.Provider, fx.gate, fx.openGate, fx.timeline, fx.isClosed
      local err = cordis.Error.new("setup failed")
      local log = spy.fn()
      root.logger.error = log
      local provider = cordis.await(root:use(Provider))
      local consumer = root:inject(
        { "foo" },
        cordis.asyncIter(function(yield, ctx)
          table.insert(timeline, "setup started")
          yield(function()
            ctx.foo:read()
            table.insert(timeline, "setup rolled back")
          end)
          gate:await()
          ctx.foo:read()
          if fail then
            error(err)
          end
        end)
      )
      immediate()
      local task = settle(provider:dispose())
      immediate()
      local closedDuringSetup = isClosed()
      openGate()
      cordis.await(task)
      cordis.await(consumer:dispose())
      expect(closedDuringSetup).to.equal(false)
      expect(timeline).to.deep.equal({
        "setup started",
        "consumer read: open",
        "consumer read: open",
        "setup rolled back",
        "provider closed",
      })
      expect(log.calls).to.have.length(fail and 1 or 0)
    end
  end)

  -- service-dispose.spec.ts:184
  it("releases dependencies after a cleanup error", function()
    local fx = fixture()
    local root, Provider, timeline = fx.root, fx.Provider, fx.timeline
    local err = cordis.Error.new("cleanup failed")
    local log = spy.fn()
    root.logger.error = log
    cordis.await(root:use(Provider))
    cordis.await(root:inject({ "foo" }, function(ctx)
      return function()
        ctx.foo:read()
        error(err)
      end
    end))
    cordis.await(root.fiber:dispose())
    expect(timeline).to.deep.equal({ "consumer read: open", "provider closed" })
    -- called as a method: `self` is argument 1
    expect(log.calls[1][2]).to.equal(err)
  end)

  -- service-dispose.spec.ts:199
  it("keeps provider listeners alive through the final consumer event", function()
    local root = U.root()
    local received = spy.fn()
    cordis.await(root:use(function(ctx)
      ctx:provide("foo", {})
      ctx:on("custom-event", received)
    end))
    cordis.await(root:inject({ "foo" }, function(ctx)
      return cordis.async(function()
        immediate()
        ctx:emit("custom-event")
      end)
    end))
    cordis.await(root.fiber:dispose())
    expect(received.calls).to.have.length(1)
  end)

  -- service-dispose.spec.ts:214
  it("allows unrelated providers and sibling effects to clean up concurrently", function()
    local fx = fixture()
    local root, Provider, gate, openGate, isClosed = fx.root, fx.Provider, fx.gate, fx.openGate, fx.isClosed
    local independent = spy.fn()
    local sibling = spy.fn()
    cordis.await(root:use(Provider))
    cordis.await(root:use(function(ctx)
      ctx:provide("bar", {})
      return independent
    end))
    cordis.await(root:inject({ "foo" }, function(ctx)
      ctx:effect(function()
        return cordis.async(function()
          gate:await()
          ctx.foo:read()
        end)
      end)
      ctx:effect(function()
        return sibling
      end)
    end))
    local task = settle(root.fiber:dispose())
    immediate()
    local duringDrain = { isClosed(), #independent.calls, #sibling.calls }
    openGate()
    cordis.await(task)
    expect(duringDrain).to.deep.equal({ false, 1, 1 })
  end)

  -- service-dispose.spec.ts:238
  it("supports composed provider effects (owner shutdown: %s)", function()
    for _, ownerShutdown in ipairs({ false, true }) do
      local root = U.root()
      local gate, openGate = gateFuture()
      local timeline = {}
      local closed = false
      local provider, consumer
      local owner = cordis.await(root:use(function(ctx)
        provider = ctx:use(function(ctx)
          ctx:effect(cordis.iter(function(yield)
            yield(ctx:effect(function()
              return function()
                closed = true
                table.insert(timeline, "provider closed")
              end
            end))
            yield(ctx:provide("foo", {
              read = function()
                table.insert(timeline, "consumer read: " .. (closed and "closed" or "open"))
              end,
            }))
          end))
        end)
        consumer = ctx:inject({ "foo" }, function(ctx)
          return cordis.async(function()
            gate:await()
            ctx.foo:read()
          end)
        end)
      end))
      Future.all(U.host(), { provider:await(), consumer:await() }):await()
      local task = settle(ownerShutdown and owner:dispose() or provider:dispose())
      immediate()
      local closedDuringDrain = closed
      openGate()
      cordis.await(task)
      expect(closedDuringDrain).to.equal(false)
      expect(timeline).to.deep.equal({ "consumer read: open", "provider closed" })
      cordis.await(owner:dispose())
    end
  end)

  -- service-dispose.spec.ts:271
  it("keeps an inherited service accessible to a child in a composed effect", function()
    local root = U.root()
    local read = spy.fn()
    local child
    local owner = cordis.await(root:use(function(ctx)
      ctx:provide("foo", { read = read })
      ctx:effect(cordis.iter(function(yield)
        child = ctx:use(function(ctx)
          return function()
            ctx.foo:read()
          end
        end)
        yield(function()
          return child:dispose()
        end)
      end))
    end))
    cordis.await(child:await())
    cordis.await(owner:dispose())
    expect(read.calls).to.have.length(1)
  end)

  -- service-dispose.spec.ts:287
  it("retains an ancestor injection until its child finishes cleanup", function()
    local fx = fixture()
    local root, Provider, gate, openGate, timeline, isClosed =
      fx.root, fx.Provider, fx.gate, fx.openGate, fx.timeline, fx.isClosed
    cordis.await(root:use(Provider))
    local child
    cordis.await(root:inject({ "foo" }, function(ctx)
      child = ctx:use(function(ctx)
        return cordis.async(function()
          gate:await()
          ctx.foo:read()
        end)
      end)
    end))
    cordis.await(child:await())
    local task = settle(root.fiber:dispose())
    immediate()
    local closedDuringDrain = isClosed()
    openGate()
    cordis.await(task)
    expect(closedDuringDrain).to.equal(false)
    expect(timeline).to.deep.equal({ "consumer read: open", "provider closed" })
  end)

  -- service-dispose.spec.ts:307
  it("waits for a child that explicitly injects its parent service", function()
    local fx = fixture()
    local root, Provider, gate, openGate, timeline, isClosed =
      fx.root, fx.Provider, fx.gate, fx.openGate, fx.timeline, fx.isClosed
    local provider = cordis.await(root:use(Provider))
    cordis.await(provider.ctx:inject({ "foo" }, function(ctx)
      return cordis.async(function()
        gate:await()
        ctx.foo:read()
      end)
    end))
    local task = settle(provider:dispose())
    immediate()
    local closedDuringDrain = isClosed()
    openGate()
    cordis.await(task)
    expect(closedDuringDrain).to.equal(false)
    expect(timeline).to.deep.equal({ "consumer read: open", "provider closed" })
  end)

  -- service-dispose.spec.ts:323
  it("tracks same-name services in separate isolation realms (root shutdown: %s)", function()
    for _, rootShutdown in ipairs({ false, true }) do
      local root = U.root()
      local gate, openGate = gateFuture()
      local first = cordis.symbol("first")
      local second = cordis.symbol("second")
      local closed = spy.fn()
      local read = spy.fn()
      local provider = cordis.await(root:use(function(ctx)
        ctx:isolate("foo", first):provide("foo", { read = read })
        ctx:isolate("foo", second):provide("foo", {})
        return closed
      end))
      local draining = false
      local consumer = cordis.await(root:isolate("foo", first):inject({ "foo" }, function(ctx)
        return cordis.async(function()
          draining = true
          gate:await()
          ctx.foo:read()
        end)
      end))
      local task = settle(rootShutdown and root.fiber:dispose() or provider:dispose())
      immediate()
      local closedDuringDrain = #closed.calls
      local notified = draining
      openGate()
      cordis.await(consumer:dispose())
      cordis.await(task)
      expect(closedDuringDrain).to.equal(0)
      expect(notified).to.equal(true)
      expect(read.calls).to.have.length(1)
      expect(closed.calls).to.have.length(1)
      cordis.await(root.fiber:dispose())
    end
  end)

  -- service-dispose.spec.ts:355
  it("withdraws only the old binding without waiting for the next load", function()
    local root = U.root()
    local oldCleanup, resolveOld = gateFuture()
    local newSetup, resolveNew = gateFuture()
    local versions = {}
    local provider = cordis.await(root:use(function() end))
    local withdraw = provider.ctx:provide("foo", { version = 1 })
    local consumer = cordis.await(root:inject(
      { "foo" },
      cordis.async(function(ctx)
        table.insert(versions, ctx.foo.version)
        if ctx.foo.version == 2 then
          newSetup:await()
        end
        return cordis.async(function()
          oldCleanup:await()
          table.insert(versions, ctx.foo.version)
        end)
      end)
    ))
    local withdrawn = false
    local task = settle(withdraw()):next(function()
      withdrawn = true
    end)
    provider.ctx:provide("foo", { version = 2 })
    resolveOld()
    immediate()
    local withdrawnBeforeSetup = withdrawn
    local foo = provider.ctx.foo
    local currentVersion = foo and foo.version
    resolveNew()
    cordis.await(task)
    cordis.await(consumer:await())
    expect(withdrawnBeforeSetup).to.equal(true)
    expect(currentVersion).to.equal(2)
    expect(versions).to.deep.equal({ 1, 1, 2 })
    cordis.await(root.fiber:dispose())
  end)

  -- service-dispose.spec.ts:386
  it("waits for current and withdrawn bindings during provider disposal (withdrawn first: %s)", function()
    for _, withdrawnFirst in ipairs({ false, true }) do
      local fx = fixture()
      local root, Provider, gate, openGate, timeline, isClosed =
        fx.root, fx.Provider, fx.gate, fx.openGate, fx.timeline, fx.isClosed
      local current, openCurrent = gateFuture()
      local provider = cordis.await(root:use(Provider))
      local withdraw = provider.ctx:provide("bar", {})
      cordis.await(root:inject({ "foo" }, function(ctx)
        return cordis.async(function()
          current:await()
          ctx.foo:read()
        end)
      end))
      cordis.await(root:inject({ "bar" }, function()
        return cordis.async(function()
          gate:await()
          table.insert(timeline, "consumer finished")
        end)
      end))
      local withdrawal = settle(withdraw())
      provider.ctx:provide("bar", {})
      local task = settle(provider:dispose())
      immediate()
      local closedDuringDrain = isClosed()
      local firstOpen, secondOpen
      if withdrawnFirst then
        firstOpen, secondOpen = openGate, openCurrent
      else
        firstOpen, secondOpen = openCurrent, openGate
      end
      firstOpen()
      immediate()
      local closedAfterFirst = isClosed()
      secondOpen()
      Future.all(U.host(), { withdrawal, task }):await()
      expect(closedDuringDrain).to.equal(false)
      expect(closedAfterFirst).to.equal(false)
      expect(timeline).to.deep.equal(
        withdrawnFirst and { "consumer finished", "consumer read: open", "provider closed" }
          or { "consumer read: open", "consumer finished", "provider closed" }
      )
      cordis.await(root.fiber:dispose())
    end
  end)

  -- service-dispose.spec.ts:418
  it("replaces a binding from the same provider during consumer initialization", function()
    local root = U.root()
    local setup, resolveSetup = gateFuture()
    local versions = {}
    local withdraw = root:provide("foo", { version = 1 })
    local consumer = root:inject(
      { "foo" },
      cordis.async(function(ctx)
        table.insert(versions, ctx.foo.version)
        setup:await()
        return function()
          table.insert(versions, -ctx.foo.version)
        end
      end)
    )
    immediate()
    local withdrawn = false
    local task = settle(withdraw()):next(function()
      withdrawn = true
    end)
    root:provide("foo", { version = 2 })
    resolveSetup()
    cordis.await(consumer:await())
    immediate()
    local withdrawnAfterSetup = withdrawn
    local currentVersion = consumer.ctx.foo.version
    cordis.await(consumer:dispose())
    cordis.await(task)
    expect(withdrawnAfterSetup).to.equal(true)
    expect(currentVersion).to.equal(2)
    expect(versions).to.deep.equal({ 1, -1, 2, -2 })
    cordis.await(root.fiber:dispose())
  end)
end)
