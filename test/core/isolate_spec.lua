-- Ported from cordis packages/core/tests/isolate.spec.ts (MIT, (c) Shigma)
local cordis = require("cordis")
local U = require("kit.util")
local spy = require("kit.spy")
local F = require("core.fixtures")
local event = F.event
local sleep = U.sleep

local NO_INJECT = 'cannot get property "foo" without inject'

describe("Isolation", function()
  -- isolate.spec.ts:7
  it("does not expose own provisions across isolation boundaries", function()
    local root = U.root()
    cordis.await(root:use(cordis.async(function(ctx)
      local isolated = ctx:isolate("foo")
      isolated:provide("foo", {})
      expect(isolated.foo).to.be.ok()
      expect(function()
        return ctx.foo
      end).to.throw(NO_INJECT)
      cordis.await(isolated:use(function(ctx)
        expect(ctx.foo).to.be.ok()
      end))
      cordis.await(ctx:use(function(ctx)
        expect(function()
          return ctx.foo
        end).to.throw(NO_INJECT)
      end))
    end)))
    cordis.await(root.fiber:dispose())
  end)

  -- isolate.spec.ts:24
  it("does not inherit the injected view across isolation boundaries", function()
    local root = U.root()
    root:provide("foo", { value = "outer" })
    local function access(ctx)
      local ok, result = pcall(function()
        return ctx.foo.value
      end)
      if ok then
        return result
      end
      return type(result) == "table" and result.message or tostring(result)
    end
    local results = {}
    cordis.await(root:inject(
      { "foo" },
      cordis.async(function(ctx)
        cordis.await(ctx:use(function(ctx)
          results[#results + 1] = access(ctx)
        end))
        cordis.await(ctx:isolate("foo"):use(function(ctx)
          results[#results + 1] = access(ctx)
        end))
        -- pinning the same realm still derives an isolation of its own
        cordis.await(ctx:isolate("foo", ctx[cordis.Context.isolate].foo):use(function(ctx)
          results[#results + 1] = access(ctx)
        end))
      end)
    ))
    expect(results).to.deep.equal({
      "outer",
      NO_INJECT,
      NO_INJECT,
    })
    cordis.await(root.fiber:dispose())
  end)

  -- isolate.spec.ts:55
  it("isolated context", function()
    local root = U.root()
    local callback = spy.fn(function() end)
    local dispose = spy.fn(function() end)
    local component = {
      inject = { "foo" },
      apply = function(ctx)
        callback()
        return dispose
      end,
    }

    cordis.await(root:use(component))
    local ctx1 = root:isolate("foo")
    cordis.await(ctx1:use(component))
    local ctx2 = root:isolate("foo")
    cordis.await(ctx2:use(component))

    local dispose0 = root:provide("foo", { bar = 100 })
    expect(root.foo.bar).to.equal(100)
    expect(ctx1.foo).to.equal(nil)
    expect(ctx2.foo).to.equal(nil)
    sleep()
    expect(callback.calls).to.have.length(1)
    expect(dispose.calls).to.have.length(0)

    local dispose1 = ctx1:provide("foo", { bar = 200 })
    expect(root.foo.bar).to.equal(100)
    expect(ctx1.foo.bar).to.equal(200)
    expect(ctx2.foo).to.equal(nil)
    sleep()
    expect(callback.calls).to.have.length(2)
    expect(dispose.calls).to.have.length(0)

    dispose0()
    expect(root.foo).to.equal(nil)
    expect(ctx1.foo.bar).to.equal(200)
    expect(ctx2.foo).to.equal(nil)
    sleep()
    expect(callback.calls).to.have.length(2)
    expect(dispose.calls).to.have.length(1)

    local dispose2 = ctx2:provide("foo", { bar = 300 })
    expect(root.foo).to.equal(nil)
    expect(ctx1.foo.bar).to.equal(200)
    expect(ctx2.foo.bar).to.equal(300)
    sleep()
    expect(callback.calls).to.have.length(3)
    expect(dispose.calls).to.have.length(1)
  end)

  -- isolate.spec.ts:106
  it("shared label", function()
    local root = U.root()
    local callback = spy.fn(function() end)
    local dispose = spy.fn(function() end)
    local component = {
      inject = { "foo" },
      apply = function(ctx)
        callback()
        return dispose
      end,
    }

    local label = cordis.symbol("test")
    cordis.await(root:use(component))
    local ctx1 = root:isolate("foo", label)
    cordis.await(ctx1:use(component))
    local ctx2 = root:isolate("foo", label)
    cordis.await(ctx2:use(component))
    sleep()
    expect(callback.calls).to.have.length(0)

    local dispose0 = root:provide("foo", { bar = 100 })
    expect(root.foo.bar).to.equal(100)
    expect(ctx1.foo).to.equal(nil)
    expect(ctx2.foo).to.equal(nil)
    sleep()
    expect(callback.calls).to.have.length(1)
    expect(dispose.calls).to.have.length(0)

    local dispose12 = ctx1:provide("foo", { bar = 200 })
    expect(root.foo.bar).to.equal(100)
    expect(ctx1.foo.bar).to.equal(200)
    expect(ctx2.foo.bar).to.equal(200)
    sleep()
    expect(callback.calls).to.have.length(3)
    expect(dispose.calls).to.have.length(0)

    dispose12()
    expect(root.foo.bar).to.equal(100)
    expect(ctx1.foo).to.equal(nil)
    expect(ctx2.foo).to.equal(nil)
    sleep()
    expect(callback.calls).to.have.length(3)
    expect(dispose.calls).to.have.length(2)
  end)

  -- isolate.spec.ts:152
  it("isolated event", function()
    local Foo = cordis.class("Foo", cordis.Service)
    function Foo:constructor(ctx)
      cordis.Service.constructor(self, ctx, "foo")
      self.ctx:emit(self, event)
    end

    local root = U.root()
    local ctx = root:isolate("foo")
    local outer = spy.fn()
    local inner = spy.fn()
    root:on(event, outer)
    ctx:on(event, inner)
    cordis.await(ctx:use(Foo))

    expect(outer.calls).to.have.length(0)
    expect(inner.calls).to.have.length(1)
  end)

  -- isolate.spec.ts:172
  it("keeps own provisions separate from the injected view", function()
    local root = U.root()
    root:provide("foo", { value = "outer" })
    local fiber = cordis.await(root:inject(
      { "foo" },
      cordis.async(function(ctx)
        local first = ctx:isolate("foo")
        local second = ctx:isolate("foo")
        local withdraw = first:provide("foo", { value = "first" })
        second:provide("foo", { value = "second" })

        expect(ctx.foo.value).to.equal("outer")
        expect(first.foo.value).to.equal("first")
        expect(second.foo.value).to.equal("second")
        cordis.await(first:use(function(ctx)
          expect(ctx.foo.value).to.equal("first")
        end))
        cordis.await(second:use(function(ctx)
          expect(ctx.foo.value).to.equal("second")
        end))

        cordis.await(withdraw())
        expect(ctx.foo.value).to.equal("outer")
        expect(function()
          return first.foo
        end).to.throw(NO_INJECT)
        expect(second.foo.value).to.equal("second")
        return function()
          expect(ctx.foo.value).to.equal("outer")
        end
      end)
    ))
    cordis.await(fiber:dispose())
    local errors = {}
    for _, message in ipairs(root.logger.buffer) do
      if message.type == "error" then
        errors[#errors + 1] = message
      end
    end
    expect(errors).to.have.length(0)
    cordis.await(root.fiber:dispose())
  end)
end)
