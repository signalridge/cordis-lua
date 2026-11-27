-- Ported from cordis packages/core/tests/invoke.spec.ts (MIT, (c) Shigma)
local cordis = require("cordis")
local U = require("kit.util")
local proto = cordis.proto
local Service = cordis.Service

local function merge(...)
  local result = {}
  for i = 1, select("#", ...) do
    local t = select(i, ...)
    if t ~= nil then
      for k, v in pairs(t) do
        result[k] = v
      end
    end
  end
  return result
end

describe("Functional Service", function()
  -- invoke.spec.ts:5
  it("functional service", function()
    local Foo = cordis.class("Foo", Service)

    function Foo:constructor(ctx, config)
      Service.constructor(self, ctx, "foo")
      self.config = config
    end

    Foo[Service.invoke] = function(self, init)
      expect(cordis.Context.is(self.ctx)).to.equal(true)
      local result = merge(self.config)
      local intercept = self.ctx[cordis.Context.intercept]
      while intercept do
        result = merge(result, intercept.foo)
        intercept = proto.getPrototypeOf(intercept)
      end
      result = merge(result, init)
      return result
    end

    function Foo:invoke()
      return self()
    end

    function Foo:extend(config)
      return self[Service.extend](self, {
        config = merge(self.config, config),
      })
    end

    local root = U.root()
    cordis.await(root:use(Foo, { a = 1 }))

    -- access from context
    expect(root.foo()).to.deep.equal({ a = 1 })
    local ctx1 = root:intercept("foo", { b = 2 })
    expect(ctx1.foo()).to.deep.equal({ a = 1, b = 2 })
    local foo1 = ctx1.foo
    expect(Foo.is(foo1)).to.equal(true)

    -- create extension
    local foo2 = root.foo:extend({ c = 3 })
    expect(Foo.is(foo2)).to.equal(true)
    expect(foo2()).to.deep.equal({ a = 1, c = 3 })
    local foo3 = foo1:extend({ d = 4 })
    expect(Foo.is(foo3)).to.equal(true)
    expect(foo3:invoke()).to.deep.equal({ a = 1, b = 2, d = 4 })

    -- context traceability
    expect(foo1:invoke()).to.deep.equal({ a = 1, b = 2 })
  end)

  -- invoke.spec.ts:62
  it("uses the service shadow for callable extensions", function()
    local Dependency = cordis.class("Dependency", Service)
    function Dependency:constructor(ctx)
      Service.constructor(self, ctx, "dependency")
    end

    local Callable = cordis.class("Callable", Service)
    Callable.inject = { "dependency" }
    function Callable:constructor(ctx)
      Service.constructor(self, ctx, "callable")
    end
    Callable[Service.invoke] = function(self)
      return self.ctx["dependency"]
    end
    function Callable:extend()
      return self[Service.extend](self)
    end

    local Outer = cordis.class("Outer", Service)
    Outer.inject = { "callable" }
    function Outer:constructor(ctx)
      Service.constructor(self, ctx, "outer")
    end
    function Outer:call()
      local callable = self.ctx["callable"]
      return { callable(), callable:extend()() }
    end

    local root = U.root()
    cordis.await(root:use(Dependency))
    cordis.await(root:use(Callable))
    cordis.await(root:use(Outer))

    local result
    cordis.await(root:inject({ "outer" }, function(ctx)
      result = ctx["outer"]:call()
    end))

    expect(Dependency.is(result[1])).to.equal(true)
    expect(Dependency.is(result[2])).to.equal(true)
  end)
end)
