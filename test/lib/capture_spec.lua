-- Library-own tests: `host.capture()`. Each case drives its own
-- reference scheduler with `contexts = true`, where tasks carry a label.
local cordis = require("cordis")
local scheduler = require("cordis.host.coroutine")
local future = require("cordis.future")
local Future = cordis.Future
local FiberState = cordis.FiberState

local function withContexts(options, body)
  local sched = scheduler.new({ contexts = true, auto = options.auto ~= false, eager = options.eager })
  local ok, err = sched.drive(function()
    future.enter(sched.host)
    body(sched, cordis.Context.new({ host = sched.host }))
  end)
  if not ok then
    error(err, 0)
  end
  if #sched.errors > 0 then
    error(sched.errors[1], 0)
  end
end

local function both(body)
  for _, eager in ipairs({ false, true }) do
    withContexts({ eager = eager }, body)
  end
end

describe("host.capture", function()
  it("runs callbacks in the context they were registered in", function()
    both(function(sched, root)
      local seen = {}
      local function record(name)
        return function()
          seen[name] = sched.context()
        end
      end
      local f, resolve = Future.withResolvers(sched.host)
      local component, disposeEffect
      local done = sched.host.latch()
      -- a tool call registers everything
      sched.spawnAs("tool", function()
        future.enter(sched.host)
        disposeEffect = root:effect(function()
          return record("disposer")
        end)
        f:next(record("reaction"))
        root:on("probe", record("listener"))
        cordis.async(record("async"))()
        component = root:use(function(ctx)
          seen.component = sched.context()
          return record("component disposer")
        end)
        done:open()
      end)
      done:wait()
      cordis.await(component)
      -- a peer request triggers everything
      local triggered = sched.host.latch()
      sched.spawnAs("peer", function()
        future.enter(sched.host)
        resolve(true)
        root:emit("probe")
        disposeEffect()
        cordis.await(component:dispose())
        triggered:open()
      end)
      triggered:wait()
      sched.host.sleep(0)
      expect(seen).to.deep.equal({
        disposer = "tool",
        reaction = "tool",
        listener = "tool",
        async = "tool",
        component = "tool",
        ["component disposer"] = "tool",
      })
    end)
  end)

  it("runs reactions of a pending Future completed elsewhere in the registrant's context", function()
    both(function(sched)
      local f, resolve = Future.withResolvers(sched.host)
      local seen = {}
      local registered = sched.host.latch()
      sched.spawnAs("tool", function()
        future.enter(sched.host)
        f:next(function(v)
          seen.next = { v, sched.context() }
        end)
        f:finally(function()
          seen.finally = sched.context()
        end)
        registered:open()
      end)
      registered:wait()
      sched.spawnAs("peer", function()
        resolve("value")
      end)
      sched.host.sleep(0)
      expect(seen).to.deep.equal({ next = { "value", "tool" }, finally = "tool" })
    end)
  end)

  it("keeps fibers loading and Futures settling while a disposer blocks natively", function()
    withContexts({ auto = false }, function(sched, root)
      local blocking = cordis.await(root:use(function()
        return function()
          sched.host.sleep(3000) -- blocks its own task, natively
        end
      end))
      local disposing = blocking:dispose()
      sched.advance(10)
      expect(blocking.state).to.equal(FiberState.UNLOADING)
      local loaded = root:use(function() end)
      local reacted
      Future.resolve(sched.host, 1):next(function(v)
        reacted = v + 1
      end)
      sched.advance(10)
      expect(loaded.state).to.equal(FiberState.ACTIVE)
      expect(reacted).to.equal(2)
      expect(blocking.state).to.equal(FiberState.UNLOADING)
      sched.advance(3000)
      cordis.await(disposing)
      expect(blocking.state).to.equal(FiberState.DISPOSED)
    end)
  end)

  it("keeps other fibers loading while a component blocks natively in apply", function()
    withContexts({ auto = false }, function(sched, root)
      local slow = root:use(function()
        sched.host.sleep(3000)
      end)
      local fast = root:use(function() end)
      sched.advance(10)
      expect(slow.state).to.equal(FiberState.LOADING)
      expect(fast.state).to.equal(FiberState.ACTIVE)
      sched.advance(3000)
      expect(slow.state).to.equal(FiberState.ACTIVE)
    end)
  end)

  it("leaves hosts without capture unchanged", function()
    local sched = scheduler.new({})
    expect(sched.host.capture).to.equal(nil)
    expect(future.capture(sched.host)).to.equal(nil)
  end)
end)

describe("host.capture with timers", function()
  it("runs timer callbacks in the context they were scheduled in", function()
    withContexts({ auto = false }, function(sched, root)
      local TimerService = require("cordis.timer").TimerService or require("cordis.timer")
      cordis.await(root:use(TimerService))
      local seen = {}
      local scheduled = sched.host.latch()
      sched.spawnAs("tool", function()
        future.enter(sched.host)
        root:timeout(function()
          seen.timeout = sched.context()
        end, 10)
        root:interval(function()
          seen.interval = seen.interval or sched.context()
        end, 10)
        scheduled:open()
      end)
      scheduled:wait()
      sched.advance(15)
      expect(seen).to.deep.equal({ timeout = "tool", interval = "tool" })
    end)
  end)
end)

describe("host.capture callback contexts", function()
  -- the terminal of a waterfall belongs to its caller
  it("runs a waterfall's terminal in the caller's context", function()
    withContexts({}, function(sched, root)
      local seen
      local registered = sched.host.latch()
      sched.spawnAs("tool", function()
        future.enter(sched.host)
        root:on("probe", function(value, nextFn)
          return nextFn()
        end)
        registered:open()
      end)
      registered:wait()
      local done = sched.host.latch()
      sched.spawnAs("peer", function()
        future.enter(sched.host)
        root:waterfall("probe", 1, function()
          seen = sched.context()
        end)
        done:open()
      end)
      done:wait()
      expect(seen).to.equal("peer")
    end)
  end)

  -- per-fiber internal/update listeners keep their registrant's context
  it("runs internal/update listeners in their registrant's context", function()
    withContexts({}, function(sched, root)
      local seen
      local fiber
      local registered = sched.host.latch()
      sched.spawnAs("tool", function()
        future.enter(sched.host)
        fiber = root:use(function(ctx)
          ctx:on("internal/update", function(_, _, nextFn)
            seen = sched.context()
            return nextFn()
          end)
        end, { n = 0 })
        cordis.await(fiber)
        registered:open()
      end)
      registered:wait()
      local done = sched.host.latch()
      sched.spawnAs("peer", function()
        future.enter(sched.host)
        cordis.await(fiber:update({ n = 1 }))
        done:open()
      end)
      done:wait()
      expect(seen).to.equal("tool")
    end)
  end)

  -- one disposer function collected from two contexts keeps both
  it("keeps each registration's context for a shared disposer", function()
    withContexts({}, function(sched, root)
      local seen = {}
      local function shared()
        seen[#seen + 1] = sched.context()
      end
      local disposers = {}
      local count = 0
      local registered = sched.host.latch()
      for _, label in ipairs({ "tool", "peer" }) do
        sched.spawnAs(label, function()
          future.enter(sched.host)
          disposers[#disposers + 1] = root:effect(function()
            return shared
          end)
          count = count + 1
          if count == 2 then
            registered:open()
          end
        end)
      end
      registered:wait()
      for _, d in ipairs(disposers) do
        d()
      end
      sched.host.sleep(0)
      table.sort(seen)
      expect(seen).to.deep.equal({ "peer", "tool" })
    end)
  end)

  -- a parallel listener blocking natively does not delay the others
  it("starts parallel listeners independently", function()
    withContexts({ auto = false }, function(sched, root)
      local second = false
      root:on("probe", function()
        sched.host.sleep(3000)
      end)
      root:on("probe", function()
        second = true
      end)
      local dispatched = root:parallel("probe")
      sched.advance(10)
      expect(second).to.equal(true)
      expect(dispatched:state()).to.equal("pending")
      sched.advance(3000)
      cordis.await(dispatched)
    end)
  end)
end)

describe("host.capture, fidelity review", function()
  -- the host reachable from a context or a Future cannot start work in the host's own
  -- context; its `spawn` runs in the caller's context
  it("never escalates through ctx.host or a Future's host", function()
    withContexts({}, function(sched, root)
      local seen = {}
      local done = sched.host.latch()
      sched.spawnAs("tool", function()
        future.enter(sched.host)
        root.host.spawn(function()
          seen.ctx = sched.context()
        end)
        local f = Future.resolve(root.host, 1)
        f._host.spawn(function()
          seen.future = sched.context()
        end)
        expect(rawequal(root.host, sched.host)).to.equal(false)
        done:open()
      end)
      done:wait()
      sched.host.sleep(0)
      expect(seen).to.deep.equal({ ctx = "tool", future = "tool" })
    end)
  end)
end)

describe("host.capture, fidelity review (public spawn)", function()
  it("cordis.future.spawn starts in the caller's context", function()
    withContexts({}, function(sched, root)
      local seen
      local done = sched.host.latch()
      sched.spawnAs("tool", function()
        future.spawn(root.host, function()
          seen = sched.context()
        end)
        done:open()
      end)
      done:wait()
      sched.host.sleep(0)
      expect(seen).to.equal("tool")
    end)
  end)
end)

describe("host.capture, cancellable apply", function()
  -- disposing a LOADING fiber cancels its apply task when the host's spawn handle can be
  -- cancelled: the rest of the component never runs, its to-be-closed values close
  it("cancels the apply task of a fiber disposed while loading", function()
    withContexts({}, function(sched, root)
      local gate = sched.host.latch()
      local log = {}
      local fiber = root:use(function()
        local _ <close> = setmetatable({}, {
          __close = function()
            log[#log + 1] = "closed"
          end,
        })
        log[#log + 1] = "applying"
        gate:wait()
        log[#log + 1] = "resumed"
      end)
      sched.host.sleep(0)
      expect(fiber.state).to.equal(FiberState.LOADING)
      cordis.await(fiber:dispose())
      gate:open()
      sched.host.sleep(0)
      expect(fiber.state).to.equal(FiberState.DISPOSED)
      expect(log).to.deep.equal({ "applying", "closed" })
    end)
  end)

  it("does not prematurely reject or abort apply on self-dispose inside apply", function()
    withContexts({}, function(sched, root)
      local cleaned = false
      local stateDuringSleep
      local fiber
      fiber = root:use(function(ctx)
        ctx.fiber:dispose()
        sched.host.sleep(20)
        stateDuringSleep = fiber.state
        return function()
          cleaned = true
        end
      end)
      sched.host.sleep(0)
      cordis.await(fiber:await())
      expect(stateDuringSleep).to.equal(FiberState.LOADING)
      expect(cleaned).to.equal(true)
      expect(fiber.state).to.equal(FiberState.DISPOSED)
    end)
  end)

  it("cancels LOADING child fibers injecting root-provided services on root:close()", function()
    withContexts({}, function(sched, root)
      root:provide("svc", { ok = true })
      local gate = sched.host.latch()
      local closed = false
      local child = root:inject({ "svc" }, function()
        local _ <close> = setmetatable({}, {
          __close = function()
            closed = true
          end,
        })
        gate:wait()
      end)
      sched.host.sleep(0)
      expect(child.state).to.equal(FiberState.LOADING)
      cordis.await(root:close())
      expect(closed).to.equal(true)
      expect(child.state).to.equal(FiberState.DISPOSED)
      expect(root.fiber.state).to.equal(FiberState.DISPOSED)
      gate:open()
    end)
  end)

  it("runs provider check predicates and logger exporters in their registration context", function()
    both(function(sched, root)
      local seen = {}
      local registered = sched.host.latch()
      sched.spawnAs("tool", function()
        future.enter(sched.host)
        root.logger:exporter({
          levels = { default = 3 },
          export = function(msg)
            if msg.args[1] == "probe-log" then
              seen.exporter = sched.context()
            end
          end,
        })
        root:provide("guarded", { ok = true }, function()
          seen.check = sched.context()
          return true
        end)
        registered:open()
      end)
      registered:wait()
      local done = sched.host.latch()
      sched.spawnAs("peer", function()
        future.enter(sched.host)
        root.logger:info("probe-log")
        cordis.await(root:inject({ "guarded" }, function() end))
        done:open()
      end)
      done:wait()
      expect(seen).to.deep.equal({ exporter = "tool", check = "tool" })
    end)
  end)

  describe("lifecycle coverage under capture", function()
    local function waitActive(root, fiber)
      if fiber.state == FiberState.ACTIVE then
        return
      end
      local latch = root.host.latch()
      local dispose
      dispose = root:on("internal/status", function(f)
        if f == fiber and f.state == FiberState.ACTIVE then
          dispose()
          latch:open()
        end
      end)
      if fiber.state == FiberState.ACTIVE then
        dispose()
        return
      end
      latch:wait()
    end

    it("applies a consumer config update after its injected provider reloads under capture", function()
      both(function(_, root)
        local applied = {}
        local Provider = cordis.class("CaptureProvider", cordis.Service)
        function Provider:constructor(ctx, config)
          cordis.Service.constructor(self, ctx, "provider")
          self.value = config.value
        end

        local Consumer = {
          inject = { "provider" },
          apply = function(ctx, config)
            applied[#applied + 1] = { ctx.provider.value, config.mode }
          end,
        }

        local provider = root:use(Provider, { value = 1 })
        local consumer = root:use(Consumer, { mode = "old" })
        waitActive(root, provider)
        waitActive(root, consumer)

        provider:update({ value = 2 })
        consumer:update({ mode = "new" })
        cordis.await(provider)
        waitActive(root, consumer)

        expect(applied).to.deep.equal({
          { 1, "old" },
          { 2, "new" },
        })
        expect(consumer.state).to.equal(FiberState.ACTIVE)
      end)
    end)

    it("retains transitive dependencies while a draining consumer finishes under capture", function()
      both(function(sched, root)
        local timeline = {}
        local closed = false
        local gate, openGate = Future.withResolvers(sched.host)

        local Provider = cordis.class("CaptureTransitiveProvider", cordis.Service)
        function Provider:constructor(ctx)
          cordis.Service.constructor(self, ctx, "foo")
        end
        function Provider:read()
          timeline[#timeline + 1] = "consumer read: " .. (closed and "closed" or "open")
        end
        Provider[cordis.Service.init] = function()
          return function()
            closed = true
            timeline[#timeline + 1] = "provider closed"
          end
        end

        local fibers = {}
        local owner = cordis.await(root:use(function(ctx)
          fibers[1] = ctx:use(Provider)
          fibers[2] = ctx:inject({ "foo" }, function(inner)
            inner:provide("bar", {})
            return function()
              inner.foo:read()
            end
          end)
          fibers[3] = ctx:inject({ "bar" }, function()
            return cordis.async(function()
              timeline[#timeline + 1] = "consumer draining"
              gate:await()
              timeline[#timeline + 1] = "consumer finished"
            end)
          end)
        end))

        for _, f in ipairs(fibers) do
          waitActive(root, f)
        end

        local disposing = owner:dispose()
        sched.host.sleep(0)
        local closedDuringDrain = closed
        openGate()
        cordis.await(disposing)

        expect(closedDuringDrain).to.equal(false)
        expect(timeline).to.deep.equal({
          "consumer draining",
          "consumer finished",
          "consumer read: open",
          "provider closed",
        })
      end)
    end)
  end)
end)
