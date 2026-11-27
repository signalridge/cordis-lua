-- Ported from cordis packages/core/tests/intercept.spec.ts (MIT, (c) Shigma)
local cordis = require("cordis")
local U = require("kit.util")

local Service = cordis.Service

local Foo = cordis.class("Foo", Service)
function Foo:constructor(ctx)
  Service.constructor(self, ctx, "foo")
end
function Foo:config()
  return self[Service.resolveIntercept](self)
end

local Bar = cordis.class("Bar", Service)
Bar.inject = { foo = { a = 2 } }
function Bar:constructor(ctx)
  Service.constructor(self, ctx, "bar")
end
function Bar:config()
  return self.ctx.foo:config()
end

describe("Intercept", function()
  -- intercept.spec.ts:34
  it("merge context intercepts from outer to inner", function()
    local root = U.root()
    cordis.await(root:use(Foo))
    expect(root.foo:config()).to.deep.equal({})
    local ctx = root:intercept("foo", { a = 1, b = 1 }):intercept("foo", { b = 2 })
    expect(ctx.foo:config()).to.deep.equal({ a = 1, b = 2 })
  end)

  -- intercept.spec.ts:42
  it("merge injected config under context intercepts", function()
    local root = U.root()
    cordis.await(root:use(Foo))
    local config
    cordis.await(root:intercept("foo", { b = 2 }):inject({ foo = { a = 1, b = 1 } }, function(ctx)
      config = ctx:intercept("foo", { c = 3 }).foo:config()
    end))
    expect(config).to.deep.equal({ a = 1, b = 2, c = 3 })
  end)

  -- intercept.spec.ts:52
  it("take injected config from the declaring fiber", function()
    local root = U.root()
    cordis.await(root:use(Foo))
    local configs = {}
    cordis.await(root:inject(
      { foo = { a = 1 } },
      cordis.async(function(ctx)
        -- no declaration of its own, so the access is admitted by the outer fiber
        cordis.await(ctx:use(function(ctx)
          configs[#configs + 1] = ctx.foo:config()
        end))
        -- the nearest declaration wins, and the outer one is not merged in
        cordis.await(ctx:inject({ foo = { b = 2 } }, function(ctx)
          configs[#configs + 1] = ctx.foo:config()
        end))
      end)
    ))
    expect(configs).to.deep.equal({ { a = 1 }, { b = 2 } })
  end)

  -- intercept.spec.ts:69
  it("stop looking for injected config at an isolation boundary", function()
    local root = U.root()
    cordis.await(root:use(Foo))
    local label = cordis.symbol("foo")
    cordis.await(root:isolate("foo", label):use(Foo))
    local config
    cordis.await(root:inject(
      { foo = { a = 1 } },
      cordis.async(function(ctx)
        cordis.await(ctx:use(function(ctx)
          config = ctx:isolate("foo", label):get("foo"):config()
        end))
      end)
    ))
    expect(config).to.deep.equal({})
  end)

  -- intercept.spec.ts:83
  it("take no injected config for own provisions", function()
    local root = U.root()
    cordis.await(root:use(Foo))
    local configs
    cordis.await(root:inject({ foo = { a = 1 } }, function(ctx)
      local isolated = ctx:isolate("foo")
      Foo.new(isolated)
      -- the injected config belongs to the dependency, not to the service the fiber provides itself
      configs = { ctx.foo:config(), isolated.foo:config(), isolated:intercept("foo", { b = 2 }).foo:config() }
    end))
    expect(configs).to.deep.equal({ { a = 1 }, {}, { b = 2 } })
  end)

  -- intercept.spec.ts:96
  it("take injected config from the def site", function()
    local root = U.root()
    cordis.await(root:use(Foo))
    cordis.await(root:use(Bar))
    expect(root:intercept("foo", { b = 1 }).bar:config()).to.deep.equal({ a = 2, b = 1 })
  end)

  -- intercept.spec.ts:103
  it("custom merge", function()
    local Tagged = cordis.class("Tagged", Foo)
    Tagged[Service.mergeIntercept] = function(self, ...)
      local tags = {}
      for i = 1, select("#", ...) do
        local config = select(i, ...)
        for _, tag in ipairs(config.tags or {}) do
          tags[#tags + 1] = tag
        end
      end
      return { tags = tags }
    end

    local root = U.root()
    cordis.await(root:use(Tagged))
    local config
    cordis.await(root:intercept("foo", { tags = { "outer" } }):inject({ foo = { tags = { "inject" } } }, function(ctx)
      config = ctx:intercept("foo", { tags = { "inner" } }).foo:config()
    end))
    expect(config).to.deep.equal({ tags = { "inject", "outer", "inner" } })
  end)
end)
