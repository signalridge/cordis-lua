-- Ported from cordis packages/core/tests/update.spec.ts (MIT, (c) Shigma)
local cordis = require("cordis")
local U = require("kit.util")
local spy = require("kit.spy")
local Future = cordis.Future
local FiberState = cordis.FiberState

local function withResolvers()
  return Future.withResolvers(U.host())
end

local function wrap(v)
  return Future.resolve(U.host(), v)
end

local function all(list)
  return Future.all(U.host(), list):await()
end

describe("Fiber: concurrent updates", function()
  -- update.spec.ts:7 (#34: a restart during loading must not disappear when dependencies match.)
  it("settles concurrent updates on the latest config (inject: %s)", function()
    for _, inject in ipairs({ false, true }) do
      local root = U.root()
      root:provide("foo", 1)
      local started, startedResolve = withResolvers()
      local release, releaseResolve = withResolvers()
      local latestStarted, latestStartedResolve = withResolvers()
      local latestRelease, latestReleaseResolve = withResolvers()
      local applied = {}
      local disposed = {}
      local settled = spy.fn()
      local fiber = cordis.await(root:use({
        inject = inject and { "foo" } or {},
        apply = cordis.async(function(ctx, config)
          applied[#applied + 1] = config.value
          if inject then
            expect(ctx.foo).to.equal(1)
          end
          if config.value == 1 then
            startedResolve()
            release:await()
          elseif config.value == 3 then
            latestStartedResolve()
            latestRelease:await()
          end
          return function()
            disposed[#disposed + 1] = config.value
          end
        end),
      }, { value = 0 }))

      local first = wrap(fiber:update({ value = 1 })):next(settled)
      started:await()
      local second = wrap(fiber:update({ value = 2 })):next(settled)
      local third = wrap(fiber:update({ value = 3 })):next(settled)
      releaseResolve()
      latestStarted:await()

      expect(applied).to.deep.equal({ 0, 1, 3 })
      expect(disposed).to.deep.equal({ 0, 1 })
      expect(settled.calls).to.have.length(0)
      expect(fiber.state).to.equal(FiberState.LOADING)
      latestReleaseResolve()
      all({ first, second, third })

      expect(settled.calls).to.have.length(3)
      expect(fiber.config).to.deep.equal({ value = 3 })
      expect(fiber.state).to.equal(FiberState.ACTIVE)
      cordis.await(root.fiber:dispose())
      expect(disposed).to.deep.equal({ 0, 1, 3 })
    end
  end)

  -- update.spec.ts:54
  it("skips superseded loads before executing the component", function()
    local root = U.root()
    local applied = {}
    local fiber = root:use(function(_, config)
      applied[#applied + 1] = config.value
    end, { value = 1 })
    local first = fiber:update({ value = 2 })
    local second = fiber:update({ value = 3 })
    all({ wrap(first), wrap(second), fiber:await() })

    expect(applied).to.deep.equal({ 3 })
    expect(fiber.state).to.equal(FiberState.ACTIVE)
    cordis.await(root.fiber:dispose())
  end)

  -- update.spec.ts:69
  it("coalesces updates during unloading", function()
    local root = U.root()
    local unloading, unloadingResolve = withResolvers()
    local release, releaseResolve = withResolvers()
    local applied = {}
    local fiber = cordis.await(root:use(function(_, config)
      applied[#applied + 1] = config.value
      return cordis.async(function()
        if config.value ~= 0 then
          return
        end
        unloadingResolve()
        release:await()
      end)
    end, { value = 0 }))

    local first = fiber:update({ value = 1 })
    unloading:await()
    local second = fiber:update({ value = 2 })
    expect(applied).to.deep.equal({ 0 })
    expect(fiber.state).to.equal(FiberState.UNLOADING)
    releaseResolve()
    all({ wrap(first), wrap(second) })

    expect(applied).to.deep.equal({ 0, 2 })
    expect(fiber.state).to.equal(FiberState.ACTIVE)
    cordis.await(root.fiber:dispose())
  end)

  -- update.spec.ts:96
  it("honors %s while loading even when config is unchanged", function()
    for _, mode in ipairs({ "restart", "config ABA" }) do
      local root = U.root()
      local started, startedResolve = withResolvers()
      local release, releaseResolve = withResolvers()
      local original = { value = 1 }
      local applied = {}
      local fiber = root:use(
        cordis.async(function(_, config)
          applied[#applied + 1] = config.value
          startedResolve()
          release:await()
        end),
        original
      )

      started:await()
      local updates
      if mode == "restart" then
        updates = { wrap(fiber:restart()) }
      else
        updates = { wrap(fiber:update({ value = 2 })), wrap(fiber:update(original)) }
      end
      releaseResolve()
      all(updates)

      expect(applied).to.deep.equal({ 1, 1 })
      expect(fiber.config).to.equal(original)
      expect(fiber.state).to.equal(FiberState.ACTIVE)
      cordis.await(root.fiber:dispose())
    end
  end)

  -- update.spec.ts:121
  it("cleans up a superseded failure without failing the latest update", function()
    local root = U.root()
    local logged = spy.fn()
    root.logger.error = logged
    local started, startedResolve = withResolvers()
    local release, releaseResolve = withResolvers()
    local failure = cordis.Error.new("superseded load")
    local applied = {}
    local disposed = {}
    local fiber = root:use(
      cordis.async(function(ctx, config)
        applied[#applied + 1] = config.value
        ctx:effect(function()
          return function()
            disposed[#disposed + 1] = config.value
          end
        end)
        if config.value ~= 1 then
          return
        end
        startedResolve()
        release:await()
        error(failure)
      end),
      { value = 1 }
    )

    started:await()
    local updating = fiber:update({ value = 2 })
    releaseResolve()
    all({ wrap(updating), fiber:await() })

    expect(applied).to.deep.equal({ 1, 2 })
    expect(disposed).to.deep.equal({ 1 })
    expect(logged.calls).to.have.length(1)
    expect(fiber.state).to.equal(FiberState.ACTIVE)
    cordis.await(root.fiber:dispose())
    expect(disposed).to.deep.equal({ 1, 2 })
  end)

  -- update.spec.ts:152
  it("rejects all waiting updates when the latest load fails", function()
    local root = U.root()
    root.logger.error = spy.fn()
    local started, startedResolve = withResolvers()
    local release, releaseResolve = withResolvers()
    local applied = {}
    local disposed = {}
    local fiber = cordis.await(root:use(
      cordis.async(function(ctx, config)
        applied[#applied + 1] = config.value
        ctx:effect(function()
          return function()
            disposed[#disposed + 1] = config.value
          end
        end)
        if config.value == 1 then
          startedResolve()
          release:await()
        elseif config.value == 2 then
          error(cordis.Error.new("latest load failed"))
        end
      end),
      { value = 0 }
    ))

    local first = fiber:update({ value = 1 })
    started:await()
    local second = fiber:update({ value = 2 })
    local results = Future.allSettled(U.host(), { wrap(first), wrap(second) })
    releaseResolve()

    for _, result in ipairs(results:await()) do
      expect(result.status).to.equal("rejected")
      if result.status == "rejected" then
        expect(result.reason.message).to.equal("latest load failed")
      end
    end
    expect(applied).to.deep.equal({ 0, 1, 2 })
    expect(disposed).to.deep.equal({ 0, 1, 2 })
    expect(fiber.state).to.equal(FiberState.FAILED)
    cordis.await(root.fiber:dispose())
  end)

  -- update.spec.ts:188
  it("stops advancing an outdated async generator and collects its final yield", function()
    local root = U.root()
    local started, startedResolve = withResolvers()
    local release, releaseResolve = withResolvers()
    local events = {}
    local fiber = root:use(
      cordis.asyncIter(function(yield, _, config)
        events[#events + 1] = "load " .. config.value
        if config.value ~= 1 then
          return
        end
        startedResolve()
        release:await()
        yield(function()
          events[#events + 1] = "dispose 1"
        end)
        events[#events + 1] = "outdated continuation"
      end),
      { value = 1 }
    )

    started:await()
    local updating = fiber:update({ value = 2 })
    releaseResolve()
    wrap(updating):await()

    expect(events).to.deep.equal({ "load 1", "dispose 1", "load 2" })
    expect(fiber.state).to.equal(FiberState.ACTIVE)
    cordis.await(root.fiber:dispose())
  end)

  -- update.spec.ts:212
  it("waits for dependencies and loads only the latest config", function()
    local root = U.root()
    local applied = {}
    local fiber = root:use({
      inject = { "foo" },
      apply = function(ctx, config)
        expect(ctx.foo).to.equal("available")
        applied[#applied + 1] = config.value
      end,
    }, { value = 0 })

    all({ wrap(fiber:update({ value = 1 })), wrap(fiber:update({ value = 2 })) })
    expect(fiber.state).to.equal(FiberState.PENDING)
    expect(applied).to.deep.equal({})
    root:provide("foo", "available")
    cordis.await(fiber)

    expect(applied).to.deep.equal({ 2 })
    expect(fiber.state).to.equal(FiberState.ACTIVE)
    cordis.await(root.fiber:dispose())
  end)

  -- update.spec.ts:234
  it("does not restart when a listener accepts an update during loading", function()
    local root = U.root()
    local started, startedResolve = withResolvers()
    local release, releaseResolve = withResolvers()
    local applied = {}
    local received = {}
    local fiber = root:use(
      cordis.async(function(ctx, config)
        applied[#applied + 1] = config.value
        ctx:on("internal/update", function(_, cfg)
          received[#received + 1] = cfg.value
        end)
        startedResolve()
        release:await()
      end),
      { value = 1 }
    )

    started:await()
    wrap(fiber:update({ value = 2 })):await()
    releaseResolve()
    cordis.await(fiber)

    expect(applied).to.deep.equal({ 1 })
    expect(received).to.deep.equal({ 2 })
    expect(fiber.config).to.deep.equal({ value = 2 })
    expect(fiber.state).to.equal(FiberState.ACTIVE)
    cordis.await(root.fiber:dispose())
  end)

  -- update.spec.ts:259
  it("does not load a queued config after disposal", function()
    local root = U.root()
    local started, startedResolve = withResolvers()
    local release, releaseResolve = withResolvers()
    local applied = {}
    local disposed = spy.fn()
    local fiber = root:use(
      cordis.async(function(_, config)
        applied[#applied + 1] = config.value
        startedResolve()
        release:await()
        return disposed
      end),
      { value = 1 }
    )

    started:await()
    local updating = fiber:update({ value = 2 })
    local disposing = fiber:dispose()
    releaseResolve()
    all({ wrap(updating), wrap(disposing) })

    expect(applied).to.deep.equal({ 1 })
    expect(disposed.calls).to.have.length(1)
    expect(fiber.state).to.equal(FiberState.DISPOSED)
    cordis.await(root.fiber:dispose())
  end)
end)
