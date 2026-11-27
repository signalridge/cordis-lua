-- Ported from cordis packages/core/tests/decorator.spec.ts (MIT, (c) Shigma)
local cordis = require("cordis")
local U = require("kit.util")
local spy = require("kit.spy")

describe("Decorator", function()
  -- decorator.spec.ts:7
  it("@Inject on class method", function()
    local callback = spy.fn()
    local dispose = spy.fn()

    local Foo = cordis.class("Foo", cordis.Service)
    function Foo:constructor(ctx)
      cordis.Service.constructor(self, ctx, "foo")
    end

    local Bar = cordis.class("Bar", cordis.Service)
    function Bar:constructor(ctx)
      cordis.Service.constructor(self, ctx, "bar")
    end
    -- @Inject('foo')
    function Bar:method()
      callback()
      return dispose
    end
    cordis.Inject.method(Bar, "method", { foo = cordis.null })

    local root = U.root()
    cordis.await(root:use(Bar))
    expect(callback.calls).to.have.length(0)
    expect(dispose.calls).to.have.length(0)
    local fiber = cordis.await(root:use(Foo))
    expect(callback.calls).to.have.length(1)
    expect(dispose.calls).to.have.length(0)
    cordis.await(fiber:dispose())
    expect(callback.calls).to.have.length(1)
    expect(dispose.calls).to.have.length(1)
  end)
end)
