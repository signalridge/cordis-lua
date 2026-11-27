-- Ported from cordis packages/core/tests/service.spec.ts (MIT, (c) Shigma)
local cordis = require("cordis")
local U = require("kit.util")
local spy = require("kit.spy")
local F = require("core.fixtures")
local sleep = U.sleep
local Service = cordis.Service

describe("Service", function()
  -- service.spec.ts:7
  it("pending inject", function()
    local Foo = cordis.class("Foo", Service)
    function Foo:constructor(ctx)
      Service.constructor(self, ctx, "foo")
    end
    Foo[Service.init] = cordis.async(function(self)
      local f, resolve = cordis.Future.withResolvers(U.host())
      self.ctx:on("custom-event", resolve)
      f:await()
    end)

    local root = U.root()

    local callback = spy.fn()
    root:inject({ "foo" }, callback)
    expect(callback.calls).to.have.length(0)

    -- inject should be blocked by `Service.init`
    root:use(Foo)
    sleep()
    expect(callback.calls).to.have.length(0)

    root:emit("custom-event")
    sleep()
    expect(callback.calls).to.have.length(1)
  end)

  -- service.spec.ts:36
  it("traceable effect (with inject)", function()
    local Foo = cordis.class("Foo", Service)
    Foo.inject = { "counter" }
    function Foo:constructor(ctx)
      Service.constructor(self, ctx, "foo")
    end
    Foo.__get.value = function(self)
      return self.ctx.counter.value
    end
    function Foo:increase()
      return self.ctx.counter:increase()
    end

    local root = U.root()
    local warning = spy.fn()
    root.logger.warn = warning
    root:provide("counter")
    root:set("counter", F.Counter.new(root))

    cordis.await(root:use(Foo))
    root.foo:increase()
    expect(root.foo.value).to.equal(1)
    expect(warning.calls).to.have.length(0)

    local fiber = cordis.await(root:inject({ "foo" }, function(ctx)
      root.foo:increase()
      expect(ctx.foo.value).to.equal(2)
      expect(warning.calls).to.have.length(0)
    end))

    cordis.await(fiber:dispose())
    root.foo:increase()
    expect(root.foo.value).to.equal(3)
    expect(warning.calls).to.have.length(0)
  end)

  -- service.spec.ts:76
  it("traceable effect (without inject)", function()
    local Foo = cordis.class("Foo", Service)
    function Foo:constructor(ctx)
      Service.constructor(self, ctx, "foo")
    end
    Foo.__get.value = function(self)
      return self.ctx.counter.value
    end
    function Foo:increase()
      return self.ctx.counter:increase()
    end

    local root = U.root()
    root:provide("counter")
    root:set("counter", F.Counter.new(root))

    cordis.await(root:use(Foo))
    root.foo:increase()
    expect(root.foo.value).to.equal(1)

    local fiber = cordis.await(root:inject({ "foo" }, function(ctx)
      root.foo:increase()
      expect(root.foo.value).to.equal(2)
    end))

    cordis.await(fiber:dispose())
    root.foo:increase()
    expect(root.foo.value).to.equal(3)
  end)

  -- service.spec.ts:109
  it("compare snapshot", function()
    local Test = cordis.class("Test", Service)
    function Test:constructor(ctx)
      Service.constructor(self, ctx, "test")
      ctx:inject({ "test" }, function() end)
    end

    local root = U.root()
    local before = F.getHookSnapshot(root)
    local fiber = cordis.await(root:use(Test))
    local after = F.getHookSnapshot(root)
    cordis.await(fiber:dispose())
    expect(before).to.deep.equal(F.getHookSnapshot(root))
    root:use(Test)
    expect(after).to.deep.equal(F.getHookSnapshot(root))
  end)

  -- service.spec.ts:127
  it("multiple injects", function()
    local foo = spy.fn()
    local bar = spy.fn()
    local qux = spy.fn()

    local Foo = cordis.class("Foo", Service)
    Foo.inject = { "qux" }
    function Foo:constructor(ctx)
      Service.constructor(self, ctx, "foo")
    end
    Foo[Service.init] = foo

    local Bar = cordis.class("Bar", Service)
    Bar.inject = { "foo", "qux" }
    function Bar:constructor(ctx)
      Service.constructor(self, ctx, "bar")
    end
    Bar[Service.init] = bar

    local Qux = cordis.class("Qux", Service)
    function Qux:constructor(ctx)
      Service.constructor(self, ctx, "qux")
    end
    Qux[Service.init] = qux

    local root = U.root()
    cordis.await(root:use(Foo))
    cordis.await(root:use(Bar))
    cordis.await(root:use(Qux))
    sleep()
    expect(foo.calls).to.have.length(1)
    expect(bar.calls).to.have.length(1)
    expect(qux.calls).to.have.length(1)
  end)

  local Foo = cordis.class("Foo", Service)
  function Foo:constructor(ctx, seq)
    Service.constructor(self, ctx, "foo")
    self.active = false
    self.seq = seq
  end
  Foo[Service.init] = cordis.iter(function(yield, self)
    self.active = true
    yield(function()
      self.active = false
      table.insert(self.seq, "foo")
    end)
  end)

  local function dependent(seq)
    return function(ctx)
      ctx:effect(function()
        return cordis.async(function()
          sleep(10)
          table.insert(seq, ctx.foo.active and "dependent" or "dependent (stale)")
        end)
      end)
    end
  end

  -- service.spec.ts:190
  it("dispose dependents before provider", function()
    local root = U.root()
    local seq = {}
    local fiber = root:use(function(ctx)
      ctx:use(Foo, seq)
      ctx:inject({ "foo" }, dependent(seq))
    end)
    sleep()
    cordis.await(fiber:dispose())
    expect(seq).to.deep.equal({ "dependent", "foo" })
  end)

  -- service.spec.ts:202
  it("dispose dependents before provider restarts", function()
    local root = U.root()
    local seq = {}
    local fiber = root:use(Foo, seq)
    local callback = spy.fn(dependent(seq))
    root:inject({ "foo" }, callback)
    sleep()
    expect(callback.calls).to.have.length(1)
    cordis.await(fiber:restart())
    expect(seq).to.deep.equal({ "dependent", "foo" })
    sleep()
    expect(callback.calls).to.have.length(2)
  end)

  -- service.spec.ts:216
  it("dispose dependents before isolated provider", function()
    local root = U.root()
    local label = cordis.symbol("realm")
    local callback = spy.fn()
    local dispose = spy.fn()
    root:isolate("foo", label):inject({ "foo" }, function()
      callback()
      return dispose
    end)
    local fiber = root:use(function(ctx)
      ctx:isolate("foo", label):provide("foo", {})
    end)
    sleep()
    expect(callback.calls).to.have.length(1)
    cordis.await(fiber:dispose())
    expect(dispose.calls).to.have.length(1)
  end)
end)

describe("Service[Symbol.hasInstance]", function()
  -- a value with no `constructor` must answer the question instead of throwing
  -- service.spec.ts:237
  it("answers for null and undefined", function()
    expect(Service.is(nil)).to.equal(false)
    expect(Service.is(cordis.null)).to.equal(false)
  end)

  -- `Function.prototype` has no `prototype` of its own, so this walks the chain
  -- to its end before answering
  -- service.spec.ts:244
  it("answers for a plain object after walking to the end of the chain", function()
    expect(Service.is({})).to.equal(false)
    expect(Service.is({ 1 })).to.equal(false)
  end)
end)
