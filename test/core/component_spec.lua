-- Ported from cordis packages/core/tests/component.spec.ts (MIT, (c) Shigma)
local cordis = require("cordis")
local U = require("kit.util")
local spy = require("kit.spy")
local F = require("core.fixtures")
local event, getHookSnapshot = F.event, F.getHookSnapshot

describe("Component", function()
  -- component.spec.ts:8
  it("apply functional component", function()
    local root = U.root()
    local callback = spy.fn()
    local options = { foo = "bar" }
    cordis.await(root:use(callback, options))

    expect(callback.calls).to.have.length(1)
    expect(callback.calls[1][2]).to.deep.equal(options)
  end)

  -- component.spec.ts:18
  it("apply object component", function()
    local root = U.root()
    local callback = spy.fn()
    local options = { bar = "foo" }
    local component = { apply = callback }
    cordis.await(root:use(component, options))

    expect(callback.calls).to.have.length(1)
    expect(callback.calls[1][2]).to.deep.equal(options)
  end)

  -- component.spec.ts:29
  it("apply component through deprecated ctx.plugin()", function()
    local root = U.root()
    local callback = spy.fn()
    local options = { foo = "bar" }
    local fiber = cordis.await(root:plugin(callback, options))

    expect(callback.calls).to.have.length(1)
    expect(callback.calls[1][2]).to.deep.equal(options)
    expect(fiber.runtime).to.equal(root.registry:get(callback))
  end)

  -- component.spec.ts:40
  it("apply invalid component", function()
    local root = U.root()
    expect(function()
      root:use(nil)
    end).to.throw()
    expect(function()
      root:use({})
    end).to.throw()
    expect(function()
      root:use({ apply = {} })
    end).to.throw()
  end)

  -- component.spec.ts:47
  it("inactive context", function()
    local root = U.root()
    local callback = spy.fn()
    local fiber = root:use(function(ctx)
      return function()
        expect(function()
          ctx:use(callback)
        end).to.throw("inactive context")
        expect(function()
          ctx:effect(function()
            return function() end
          end)
        end).to.throw("inactive context")
        expect(function()
          ctx:on("custom-event", function() end)
        end).to.throw("inactive context")
      end
    end)
    cordis.await(fiber:dispose())
    expect(callback.calls).to.have.length(0)
  end)

  -- component.spec.ts:61 (rewritten: inspect is tostring; `function foo` is a table
  -- component with a name; the anonymous function keeps the parent's name)
  it("context inspect", function()
    local root = U.root()

    expect(tostring(root)).to.equal("Context <root>")

    cordis.await(root:use(function(ctx)
      expect(tostring(ctx)).to.equal("Context <root>")
    end))

    cordis.await(root:use({
      name = "foo",
      apply = function(ctx)
        expect(tostring(ctx)).to.equal("Context <foo>")
      end,
    }))

    cordis.await(root:use({
      name = "bar",
      apply = function(ctx)
        expect(tostring(ctx)).to.equal("Context <bar>")
      end,
    }))

    local Qux = cordis.class("Qux")
    function Qux:constructor(ctx)
      expect(tostring(ctx)).to.equal("Context <Qux>")
    end
    cordis.await(root:use(Qux))
  end)

  -- component.spec.ts:88
  it("ctx.registry", function()
    -- make coverage happy
    local root = U.root()
    root.registry:keys()
    root.registry:values()
    root.registry:entries()
    root.registry:forEach(function() end)
  end)

  -- component.spec.ts:97
  it("nested components", function()
    local root = U.root()
    local callback = spy.fn()
    local component = cordis.async(function(ctx)
      ctx:on(event, callback)
      cordis.await(ctx:use(cordis.async(function(ctx2)
        ctx2:on(event, callback)
        cordis.await(ctx2:use(function(ctx3)
          ctx3:on(event, callback)
        end))
      end)))
    end)

    root:on(event, callback)
    local fiber = cordis.await(root:use(component))

    -- 4 handlers by now
    expect(callback.calls).to.have.length(0)
    expect(root.registry.size).to.equal(3)
    root:emit(event)
    expect(callback.calls).to.have.length(4)

    -- only 1 handler left
    callback:reset()
    cordis.await(fiber:dispose())
    expect(root.registry.size).to.equal(0)
    root:emit(event)
    expect(callback.calls).to.have.length(1)

    -- subsequent calls should be noop
    callback:reset()
    cordis.await(fiber:dispose())
    expect(root.registry.size).to.equal(0)
    root:emit(event)
    expect(callback.calls).to.have.length(1)
  end)

  -- component.spec.ts:134
  it("compare snapshot", function()
    local component = cordis.async(function(ctx)
      ctx:on(event, function() end)
      cordis.await(ctx:use(cordis.async(function(ctx2)
        ctx2:on(event, function() end)
        cordis.await(ctx2:use(function(ctx3)
          ctx3:on(event, function() end)
        end))
      end)))
    end)

    local root = U.root()
    local before = getHookSnapshot(root)
    local fiber = cordis.await(root:use(component))
    local after = getHookSnapshot(root)
    cordis.await(fiber:dispose())
    expect(before).to.deep.equal(getHookSnapshot(root))
    cordis.await(root:use(component))
    expect(after).to.deep.equal(getHookSnapshot(root))
  end)

  -- component.spec.ts:155
  it("root dispose", function()
    local root = U.root()
    local dispose = spy.fn()
    local fiber = root:use(function()
      return dispose
    end)
    expect(root.fiber.uid).to.equal(0)
    expect(fiber.uid).to.equal(1)
    expect(dispose.calls).to.have.length(0)
    expect(root.fiber._disposables:length()).to.equal(1)
    cordis.await(root.fiber:dispose())
    expect(root.fiber.uid).to.equal(0)
    expect(fiber.uid).to.equal(nil)
    expect(dispose.calls).to.have.length(1)
    expect(root.fiber._disposables:length()).to.equal(0)
    cordis.await(root.fiber:dispose())
    expect(root.fiber.uid).to.equal(0)
    expect(fiber.uid).to.equal(nil)
    expect(dispose.calls).to.have.length(1)
    expect(root.fiber._disposables:length()).to.equal(0)
  end)

  -- component.spec.ts:175
  it("Service.init", function()
    local start = spy.fn()
    local stop = spy.fn()

    local Foo = cordis.class("Foo")
    Foo[cordis.Service.init] = function(self)
      start()
      return stop
    end

    local root = U.root()
    local fiber = cordis.await(root:use(Foo))
    expect(start.calls).to.have.length(1)
    expect(stop.calls).to.have.length(0)
    cordis.await(fiber:dispose())
    expect(start.calls).to.have.length(1)
    expect(stop.calls).to.have.length(1)
  end)
end)
