-- Ported from cordis packages/core/tests/associate.spec.ts (MIT, (c) Shigma)
local cordis = require("cordis")
local U = require("kit.util")

local Service = cordis.Service

describe("Association", function()
  -- associate.spec.ts:5
  it("service injection", function()
    local root = U.root()

    local Foo = cordis.class("Foo", Service)
    function Foo:constructor(ctx)
      self.qux = 1
      Service.constructor(self, ctx, "foo")
    end

    local FooBar = cordis.class("FooBar", Service)
    function FooBar:constructor(ctx)
      Service.constructor(self, ctx, "foo.bar")
    end

    cordis.await(root:use(Foo))
    local fiber = cordis.await(root:use(FooBar))
    expect(root.foo).to.be.instanceof(Foo)
    expect(root.foo.bar).to.be.instanceof(FooBar)
    expect(root.foo.qux).to.equal(1)
    cordis.await(fiber:dispose())
    expect(root.foo.bar).to.equal(nil)
  end)

  -- associate.spec.ts:30
  it("property injection", function()
    local root = U.root()

    local Foo = cordis.class("Foo", Service)
    function Foo:constructor(ctx)
      Service.constructor(self, ctx, "foo")
    end

    root:provide("foo.bar")
    root:provide("foo.baz")
    cordis.await(root:use(Foo))
    expect(root.foo).to.be.instanceof(Foo)
    root.foo.qux = 2
    root.foo.bar = 3
    root.foo.baz = function(this)
      return this
    end

    cordis.await(root:inject({ "foo" }, function(ctx)
      expect(ctx.foo.qux).to.equal(2)
      expect(ctx.foo.bar).to.equal(3)
      expect(function()
        return ctx["foo.qux"]
      end).to.throw('cannot get property "foo.qux" without inject')
      expect(ctx["foo.bar"]).to.equal(3)
      expect(ctx.foo:baz()).to.be.instanceof(Foo)
    end))
  end)

  -- associate.spec.ts:58
  it("associated type - service injection", function()
    local Session = cordis.class("Session")
    function Session:constructor(ctx)
      self[Service.tracker] = { property = "ctx", associate = "session" }
      self.ctx = ctx
    end

    local Foo = cordis.class("Foo", Service)
    function Foo:constructor(ctx)
      Service.constructor(self, ctx, "foo")
    end
    function Foo:createSession()
      return Session.new(self.ctx)
    end

    local Bar = cordis.class("Bar", Service)
    function Bar:constructor(ctx)
      Service.constructor(self, ctx, "bar")
      -- an instance field upstream (not static), set after `super()`
      self.inject = { "foo" }
      ctx:mixin("bar", {
        answer = "session.answer",
      })
    end
    function Bar:answer()
      return 42
    end

    local root = U.root()
    cordis.await(root:use(Foo))

    cordis.await(root:inject(
      { "foo" },
      cordis.async(function(ctx)
        local session = ctx.foo:createSession()
        expect(session).to.be.instanceof(Session)
        expect(session.bar).to.equal(nil)

        cordis.await(ctx:use(Bar))
        cordis.await(ctx:inject({ "bar" }, function(ctx)
          local session = ctx.foo:createSession()
          expect(session).to.be.instanceof(Session)
          expect(session:answer()).to.equal(42)
        end))
      end)
    ))
  end)

  -- associate.spec.ts:114
  it("associated type - accessor injection", function()
    local Session = cordis.class("Session")
    function Session:constructor(ctx)
      self[Service.tracker] = { property = "ctx", associate = "session" }
      self.ctx = ctx
    end

    local Foo = cordis.class("Foo", Service)
    function Foo:constructor(ctx)
      Service.constructor(self, ctx, "foo")
    end
    function Foo:session()
      return Session.new(self.ctx)
    end

    local Bar = cordis.class("Bar")
    function Bar:constructor(ctx)
      ctx:mixin(self, {
        bar = "session.bar",
      })
    end
    Bar.__get.bar = function(self)
      return self.secret
    end
    Bar.__set.bar = function(self, value)
      self.secret = value + 1
    end

    local root = U.root()
    cordis.await(root:use(Foo))
    cordis.await(root:use(Bar))

    cordis.await(root:inject(
      { "foo" },
      cordis.async(function(ctx)
        local session = ctx.foo:session()
        expect(session).to.be.instanceof(Session)
        expect(function()
          return session.bar
        end).to.throw()

        cordis.await(ctx:inject({ "bar" }, function(ctx)
          local session = ctx.foo:session()
          expect(session.bar).to.equal(nil)
          session.bar = 100
          expect(session.bar).to.equal(101)
        end))
      end)
    ))
  end)

  -- associate.spec.ts:176
  it("associated access follows the service fiber", function()
    local Foo = cordis.class("Foo", Service)
    function Foo:constructor(ctx)
      Service.constructor(self, ctx, "foo")
    end

    local FooBar = cordis.class("FooBar", Service)
    function FooBar:constructor(ctx)
      Service.constructor(self, ctx, "foo.bar")
    end
    function FooBar:hello()
      return "bar"
    end

    local Baz = cordis.class("Baz", Service)
    Baz.inject = { "foo", "foo.bar" }
    function Baz:constructor(ctx)
      Service.constructor(self, ctx, "baz")
    end
    function Baz:probe()
      return self.ctx.foo.bar:hello()
    end

    local Qux = cordis.class("Qux", Service)
    -- injects `foo` but not `foo.bar`
    Qux.inject = { "foo" }
    function Qux:constructor(ctx)
      Service.constructor(self, ctx, "qux")
    end
    function Qux:probe()
      return self.ctx.foo.bar:hello()
    end

    local root = U.root()
    cordis.await(root:use(Foo))
    cordis.await(root:use(FooBar))
    cordis.await(root:use(Baz))
    cordis.await(root:use(Qux))

    -- `ctx.foo.bar` must be governed by the same fiber as `ctx['foo.bar']`,
    -- i.e. the service that runs the access, not whoever called it
    expect(root.baz:probe()).to.equal("bar")
    expect(function()
      return root.qux:probe()
    end).to.throw('cannot get property "foo.bar" without inject')
    cordis.await(root:inject({ "baz", "qux" }, function(ctx)
      expect(ctx.baz:probe()).to.equal("bar")
      expect(function()
        return ctx.qux:probe()
      end).to.throw('cannot get property "foo.bar" without inject')
    end))
  end)

  -- https://github.com/cordiverse/cordis/issues/14
  -- associate.spec.ts:235
  it("inspect", function()
    local Foo = cordis.class("Foo", Service)
    function Foo:constructor(ctx)
      Service.constructor(self, ctx, "foo")
    end
    -- `arg.toString()` of a JS class is `tostring(arg)` ("class X") here
    function Foo:bar(arg)
      expect(string.find(tostring(arg), "class X", 1, true) ~= nil).to.equal(true)
      self:baz(arg)
    end
    function Foo:baz(arg)
      expect(string.find(tostring(arg), "class X", 1, true) ~= nil).to.equal(true)
    end

    local root = U.root()
    cordis.await(root:use(Foo))
    local X = cordis.class("X")
    root.foo:bar(X)
  end)
end)
