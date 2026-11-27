-- Ported from cordis packages/core/tests/fiber.spec.ts (MIT, (c) Shigma)
local cordis = require("cordis")
local U = require("kit.util")
local spy = require("kit.spy")
local F = require("core.fixtures")
local event = F.event
local sleep, withTimers, advance, runAll = U.sleep, U.withTimers, U.advance, U.runAll
local FiberState = cordis.FiberState

-- `try { ... } finally { off() }`
local function try(body, finally)
  local ok, err = pcall(body)
  finally()
  if not ok then
    error(err, 0)
  end
end

describe("Fiber", function()
  -- fiber.spec.ts:7
  it(
    "inertia lock 1",
    withTimers(function(root)
      local dispose = root:provide("foo", 1)
      local fiber = root:inject(
        { "foo" },
        cordis.async(function()
          sleep(1000)
          return cordis.async(function()
            sleep(1000)
          end)
        end)
      )
      advance(400) -- 400
      expect(fiber.state).to.equal(FiberState.LOADING)
      dispose()
      advance(400) -- 800
      expect(fiber.state).to.equal(FiberState.LOADING)
      advance(400) -- 1200
      expect(fiber.state).to.equal(FiberState.UNLOADING)
      root:provide("foo", 1)
      advance(1000) -- 2200
      expect(fiber.state).to.equal(FiberState.LOADING)
      advance(1000) -- 3200
      expect(fiber.state).to.equal(FiberState.ACTIVE)
    end)
  )

  -- fiber.spec.ts:27
  it(
    "inertia lock 2",
    withTimers(function(root)
      local dispose = root:provide("foo", 1)
      local fiber = root:inject(
        { "foo" },
        cordis.async(function()
          sleep(1000)
          return cordis.async(function()
            sleep(1000)
          end)
        end)
      )
      advance(400) -- 400
      expect(fiber.state).to.equal(FiberState.LOADING)
      dispose()
      advance(400) -- 800
      expect(fiber.state).to.equal(FiberState.LOADING)
      root:provide("foo", 2)
      advance(400) -- 1200
      -- A new binding from the same provider still supersedes the old load.
      expect(fiber.state).to.equal(FiberState.UNLOADING)
      advance(1000) -- 2200
      expect(fiber.state).to.equal(FiberState.LOADING)
      advance(1000) -- 3200
      expect(fiber.state).to.equal(FiberState.ACTIVE)
      expect(fiber.ctx.foo).to.equal(2)
    end)
  )

  -- fiber.spec.ts:49
  it(
    "inertia lock 3",
    withTimers(function(root)
      local Foo = cordis.class("Foo", cordis.Service)
      function Foo:constructor(ctx)
        cordis.Service.constructor(self, ctx, "foo")
      end
      local provider = cordis.await(root:use(Foo))
      local fiber = root:inject(
        { "foo" },
        cordis.async(function()
          sleep(1000)
          return cordis.async(function()
            sleep(1000)
          end)
        end)
      )
      advance(400) -- 400
      expect(fiber.state).to.equal(FiberState.LOADING)
      runAll() -- 1000
      expect(fiber.state).to.equal(FiberState.ACTIVE)
      cordis.Future
        .all(U.host(), {
          cordis.async(function()
            cordis.await(provider:dispose())
          end)(),
          cordis.async(function()
            runAll() -- 2000
          end)(),
        })
        :await()
      expect(fiber.state).to.equal(FiberState.PENDING)
    end)
  )

  -- fiber.spec.ts:71
  it("component error", function()
    local root = U.root()
    local callback = spy.fn()
    local error_ = spy.fn()
    root.logger.error = error_
    local apply = spy.fn(function(ctx, config)
      ctx:on(event, callback)
      if not (config and config.foo) then
        error(cordis.Error.new("component error"))
      end
    end)

    local fiber1 = root:use(apply)
    local fiber2 = root:use(apply, { foo = true })
    sleep()
    expect(fiber1.state).to.equal(FiberState.FAILED)
    expect(fiber2.state).to.equal(FiberState.ACTIVE)
    -- expect(apply.calls).to.have.length(2)
    expect(error_.calls).to.have.length(1)

    root:emit(event)
    expect(callback.calls).to.have.length(1)
  end)

  -- fiber.spec.ts:93
  it("failed fiber does not re-enter on dependency refresh", function()
    local root = U.root()
    root.logger.error = spy.fn()
    local apply = spy.fn(function()
      error(cordis.Error.new("boom"))
    end)
    local dispose = root:provide("foo", 1)
    local fiber = root:inject({ "foo" }, apply)
    sleep()
    expect(fiber.state).to.equal(FiberState.FAILED)
    cordis.await(dispose())
    root:provide("foo", 2)
    sleep()
    expect(apply.calls).to.have.length(1)
    expect(fiber.state).to.equal(FiberState.FAILED)
  end)

  -- fiber.spec.ts:108
  it("update recovers a failed fiber", function()
    local root = U.root()
    root.logger.error = spy.fn()
    local apply = spy.fn(function()
      error(cordis.Error.new("boom"))
    end)
    root:provide("foo", 1)
    local fiber = root:inject({ "foo" }, apply)
    sleep()
    expect(fiber.state).to.equal(FiberState.FAILED)
    apply:mockImplementationOnce(function() end)
    cordis.await(fiber:update(nil))
    expect(apply.calls).to.have.length(2)
    expect(fiber.state).to.equal(FiberState.ACTIVE)
  end)

  -- fiber.spec.ts:122
  it("update waits for asynchronous recovery", function()
    local root = U.root()
    root.logger.error = spy.fn()
    local promise, resolve = cordis.Future.withResolvers(U.host())
    local fiber = root:use(
      cordis.async(function(_, config)
        if not config.fixed then
          error(cordis.Error.new("boom"))
        end
        cordis.await(promise)
      end),
      { fixed = false }
    )
    expect(fiber:await()).to.reject("boom")

    local settled = spy.fn()
    local task = fiber:update({ fixed = true }):next(settled)
    try(function()
      sleep()
      expect(settled.calls).to.have.length(0)
    end, function()
      resolve()
      cordis.await(task)
    end)
    expect(fiber.state).to.equal(FiberState.ACTIVE)
  end)

  -- fiber.spec.ts:144
  it("update surfaces a failed recovery to its caller", function()
    local root = U.root()
    root.logger.error = spy.fn()
    local fiber = root:use(function(_, config)
      error(cordis.Error.new(config.message))
    end, { message = "initial failure" })
    expect(fiber:await()).to.reject("initial failure")

    expect(fiber:update({ message = "retry failure" })).to.reject("retry failure")
    expect(fiber.state).to.equal(FiberState.FAILED)
  end)

  -- fiber.spec.ts:156
  it("update surfaces a failed reload to its caller", function()
    local root = U.root()
    root.logger.error = spy.fn()
    local apply = spy.fn(function() end)
    local fiber = root:use(apply)
    cordis.await(fiber)
    apply:mockImplementationOnce(function()
      error(cordis.Error.new("boom"))
    end)
    expect(fiber:update({})).to.reject("boom")
    expect(fiber.state).to.equal(FiberState.FAILED)
  end)

  -- fiber.spec.ts:171
  -- the fiber reports the failure itself, so a caller that never asks for the
  -- result must not be punished with an unhandled rejection
  it("update does not leak a dropped failure", function()
    local root = U.root()
    root.logger.error = spy.fn()
    local apply = spy.fn(function() end)
    local fiber = root:use(apply)
    cordis.await(fiber)
    apply:mockImplementationOnce(function()
      error(cordis.Error.new("boom"))
    end)
    fiber:update({})
    sleep()
    expect(fiber.state).to.equal(FiberState.FAILED)
  end)

  -- fiber.spec.ts:185
  it("dispose error", function()
    local root = U.root()
    local error_ = spy.fn()
    root.logger.error = error_
    local dispose = spy.fn(function()
      error(cordis.Error.new("test"))
    end)
    local component = function(ctx)
      return dispose
    end

    local fiber = cordis.await(root:use(component))
    expect(dispose.calls).to.have.length(0)
    expect(cordis.await(fiber:dispose())).to.equal(nil)
    sleep()
    expect(dispose.calls).to.have.length(1)
    expect(error_.calls).to.have.length(1)
  end)

  -- fiber.spec.ts:204 (rewritten: Object.getPrototypeOf(fiber) is the fiber itself)
  it("settles a pending fiber to DISPOSED on dispose", function()
    local root = U.root()
    local fiber = root:inject({ "never-provided" }, function() end)
    local target = fiber
    local transitions = {}
    local off = root:on("internal/status", function(current, oldState)
      if current == target then
        transitions[#transitions + 1] = { oldState, current.state }
      end
    end)

    try(function()
      expect(fiber.state).to.equal(FiberState.PENDING)

      cordis.await(fiber:dispose())

      expect(fiber.uid).to.equal(nil)
      expect(fiber.inertia).to.equal(nil)
      expect(fiber.state).to.equal(FiberState.DISPOSED)
      expect(transitions).to.deep.equal({
        { FiberState.PENDING, FiberState.DISPOSED },
      })
    end, off)
  end)

  -- fiber.spec.ts:231 (rewritten: Object.getPrototypeOf(fiber) is the fiber itself)
  it("settles a failed fiber to DISPOSED on dispose", function()
    local root = U.root()
    root.logger.error = spy.fn()

    local fiber = root:use(function()
      error(cordis.Error.new("boom"))
    end)
    local target = fiber
    local transitions = {}

    expect(fiber:await()).to.reject("boom")
    expect(fiber.state).to.equal(FiberState.FAILED)
    local off = root:on("internal/status", function(current, oldState)
      if current == target then
        transitions[#transitions + 1] = { oldState, current.state }
      end
    end)

    try(function()
      cordis.await(fiber:dispose())

      expect(fiber.uid).to.equal(nil)
      expect(fiber.inertia).to.equal(nil)
      expect(fiber.state).to.equal(FiberState.DISPOSED)
      expect(transitions).to.deep.equal({
        { FiberState.FAILED, FiberState.DISPOSED },
      })
    end, off)
  end)

  -- fiber.spec.ts:264 (rewritten: Object.getPrototypeOf(fiber) is the fiber itself)
  it("keeps the active dispose sequence stable", function()
    local root = U.root()
    local fiber = root:use(function() end)
    cordis.await(fiber:await())

    local target = fiber
    local transitions = {}
    local off = root:on("internal/status", function(current, oldState)
      if current == target then
        transitions[#transitions + 1] = { oldState, current.state }
      end
    end)

    try(function()
      cordis.await(fiber:dispose())

      expect(fiber.uid).to.equal(nil)
      expect(fiber.inertia).to.equal(nil)
      expect(fiber.state).to.equal(FiberState.DISPOSED)
      expect(transitions).to.deep.equal({
        { FiberState.ACTIVE, FiberState.UNLOADING },
        { FiberState.UNLOADING, FiberState.DISPOSED },
      })
    end, off)
  end)

  -- fiber.spec.ts:292
  it("update config on wrapped fiber", function()
    local root = U.root()
    local callback = spy.fn()

    local fiber = root:use(callback, { msg = "hello" })
    cordis.await(fiber)
    expect(callback.calls).to.have.length(1)
    expect(callback.calls[1][2]).to.deep.equal({ msg = "hello" })

    fiber:update({ msg = "world" })
    cordis.await(fiber)
    expect(callback.calls).to.have.length(2)
    expect(callback.calls[2][2]).to.deep.equal({ msg = "world" })

    fiber:update({ msg = "!!!" })
    cordis.await(fiber)
    expect(callback.calls).to.have.length(3)
    expect(callback.calls[3][2]).to.deep.equal({ msg = "!!!" })
  end)

  -- fiber.spec.ts:312 (the Object.hasOwn checks on a wrapper are n/a: there is no wrapper)
  it("restart wrapped fiber", function()
    local root = U.root()
    local callback = spy.fn()
    local fiber = root:use(callback)

    cordis.await(fiber)
    cordis.await(fiber:restart())

    expect(callback.calls).to.have.length(2)
    expect(fiber.state).to.equal(FiberState.ACTIVE)
  end)

  -- fiber.spec.ts:326 (the Object.getPrototypeOf / Object.hasOwn checks on a wrapper are n/a)
  it("update config while injected service reloads", function()
    U.requires("microtask order")
    local applied = {}

    local Provider = cordis.class("Provider", cordis.Service)
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

    local root = U.root()
    local provider = root:use(Provider, { value = 1 })
    local consumer = root:use(Consumer, { mode = "old" })

    cordis.await(provider)
    cordis.await(consumer)

    provider:update({ value = 2 })
    consumer:update({ mode = "new" })

    cordis.Future.all(U.host(), { provider:await(), consumer:await() }):await()

    expect(applied).to.deep.equal({
      { 1, "old" },
      { 2, "new" },
    })
    expect(consumer.state).to.equal(FiberState.ACTIVE)
  end)
end)

-- config is resolved on every reload, so an invalid config can only be
-- detected up front while the dependencies are satisfied
describe("Fiber: config validation", function()
  local Config = {
    ["~standard"] = {
      version = 1,
      vendor = "test",
      validate = function(value)
        if value and value.ok then
          local copy = {}
          for k, v in pairs(value) do
            copy[k] = v
          end
          copy.resolved = true
          return { value = copy }
        end
        return { issues = { { message = "not ok" } } }
      end,
    },
  }

  -- fiber.spec.ts:384
  it("fail on first load", function()
    local root = U.root()
    root.logger.error = spy.fn()
    local apply = spy.fn(function() end)

    local fiber = root:use({ apply = apply, Config = Config }, { ok = false })
    sleep()

    expect(apply.calls).to.have.length(0)
    expect(fiber.state).to.equal(FiberState.FAILED)
  end)

  -- fiber.spec.ts:396
  it("keep a running component on update", function()
    local root = U.root()
    root.logger.error = spy.fn()
    local apply = spy.fn(function() end)

    local fiber = root:use({ apply = apply, Config = Config }, { ok = true })
    cordis.await(fiber)
    expect(apply.calls).to.have.length(1)

    expect(function()
      fiber:update({ ok = false })
    end).to.throw("invalid config")
    sleep()

    expect(apply.calls).to.have.length(1)
    expect(fiber.state).to.equal(FiberState.ACTIVE)
    expect(fiber.config).to.deep.equal({ ok = true })
  end)

  -- fiber.spec.ts:413
  it("keep the issues and their paths", function()
    local issues = {
      { message = "not a number", path = { { key = "items" }, 0 } },
      { message = "required", path = {} },
    }
    local error_ = cordis.ValidationError.new(issues)
    expect(error_.issues).to.equal(issues)
    expect(cordis.ValidationError.is(error_)).to.equal(true)
    expect(cordis.ValidationError.is(cordis.TypeError.new())).to.equal(false)
    expect(error_.message).to.equal("invalid config:\n  - not a number (at items.0)\n  - required")
  end)

  -- fiber.spec.ts:426
  -- listeners see what the component would see, while the fiber keeps the source
  it("pass the resolved config to listeners", function()
    local root = U.root()
    local received = {}
    local applied = {}
    local apply = spy.fn(function(ctx, config)
      applied[#applied + 1] = config
      ctx:on("internal/update", function(_, config2, next)
        received[#received + 1] = config2
        return next()
      end)
    end)

    local fiber = root:use({ apply = apply, Config = Config }, { ok = true })
    cordis.await(fiber)
    expect(applied).to.deep.equal({ { ok = true, resolved = true } })

    cordis.await(fiber:update({ ok = true, extra = 1 }))

    expect(received).to.deep.equal({ { ok = true, extra = 1, resolved = true } })
    expect(fiber.config).to.deep.equal({ ok = true, extra = 1 })
  end)

  -- fiber.spec.ts:448
  it("keep the source config when a listener handles the update", function()
    local root = U.root()
    local received = {}
    local applied = {}
    local fiber = cordis.await(root:use({
      Config = Config,
      apply = function(ctx, config)
        applied[#applied + 1] = config
        ctx:on("internal/update", function(_, config2)
          received[#received + 1] = config2
        end)
      end,
    }, { ok = true }))

    local source = { ok = true, extra = 1 }
    cordis.await(fiber:update(source))
    expect(received).to.deep.equal({ { ok = true, extra = 1, resolved = true } })
    expect(applied).to.have.length(1)
    expect(fiber.config).to.equal(source)

    cordis.await(fiber:restart())
    expect(applied).to.deep.equal({
      { ok = true, resolved = true },
      { ok = true, extra = 1, resolved = true },
    })
  end)
end)

describe("fiber.leak()", function()
  -- fiber.spec.ts:477
  it("leaves a disposer to the fiber that takes it over", function()
    local root = U.root()
    local source = cordis.await(root:use(function() end))
    local target = cordis.await(root:use(function() end))
    local dispose = spy.fn()
    local child = source.ctx:effect(function()
      return dispose
    end)
    expect(source:leak(child)).to.equal(true)
    target.ctx:effect(function()
      return child
    end)

    cordis.await(source:dispose())
    expect(dispose).to.have.length(0)
    cordis.await(target:dispose())
    expect(dispose).to.have.length(1)
  end)

  -- fiber.spec.ts:492
  it("does not leak a disposer of another fiber", function()
    local root = U.root()
    local source = cordis.await(root:use(function() end))
    local other = cordis.await(root:use(function() end))
    local dispose = spy.fn()
    local child = source.ctx:effect(function()
      return dispose
    end)
    expect(other:leak(child)).to.equal(false)
    cordis.await(source:dispose())
    expect(dispose).to.have.length(1)
  end)
end)

describe("Fiber.Options", function()
  it("runs config, commit, and dispose hooks passed via use() options", function()
    local root = U.root()
    local events = {}
    local seen
    local fiber = cordis.await(root:use(function(_, cfg)
      seen = cfg
    end, { n = 1 }, {
      config = function(_, cfg, resolve)
        events[#events + 1] = "config:" .. tostring(cfg.n)
        return resolve({ n = cfg.n * 10 })
      end,
      commit = function(_, cfg)
        events[#events + 1] = "commit:" .. tostring(cfg.n)
      end,
      dispose = function()
        events[#events + 1] = "dispose"
      end,
    }))
    expect(seen).to.deep.equal({ n = 10 })
    cordis.await(fiber:update({ n = 2 }))
    expect(seen).to.deep.equal({ n = 20 })
    cordis.await(fiber:dispose())
    expect(events).to.deep.equal({ "config:1", "config:2", "commit:2", "config:2", "dispose" })
  end)
end)
