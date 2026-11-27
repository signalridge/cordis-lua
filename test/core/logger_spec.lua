-- Ported from cordis packages/core/tests/logger.spec.ts (MIT, (c) Shigma)
local cordis = require("cordis")
local U = require("kit.util")

local function setup()
  local ctx = U.root()
  local captured = {}
  ctx.logger:exporter({
    colors = 0,
    levels = { default = 3 },
    export = function(msg)
      captured[#captured + 1] = msg
    end,
  })
  return ctx, captured
end

local function names(captured)
  local r = {}
  for i, m in ipairs(captured) do
    r[i] = m.name
  end
  return r
end

local function first(buffer)
  local r = {}
  for i, m in ipairs(buffer) do
    r[i] = m.args[1]
  end
  return r
end

local function contains(list, value)
  for _, v in ipairs(list) do
    if v == value then
      return true
    end
  end
  return false
end

describe("Logger", function()
  -- logger.spec.ts:18
  it("keeps the bounded buffer in place and chronological", function()
    local ctx = U.root()
    local buffer = ctx.logger.buffer
    ctx.logger.bufferSize = 2
    ctx.logger:info("one")
    ctx.logger:info("two")
    ctx.logger:info("three")
    expect(ctx.logger.buffer).to.equal(buffer)
    expect(first(buffer)).to.deep.equal({ "two", "three" })

    ctx.logger.bufferSize = 1
    ctx.logger:info("four")
    expect(first(buffer)).to.deep.equal({ "four" })

    ctx.logger.bufferSize = 0
    ctx.logger:info("five")
    expect(buffer).to.deep.equal({})
  end)

  -- logger.spec.ts:37
  it("disposes the exporter that registered the disposer", function()
    local ctx = U.root()
    ctx.logger.exporters:clear()
    local first_, second = {}, {}
    local disposeFirst = ctx.logger:exporter({
      export = function(message)
        first_[#first_ + 1] = message
      end,
    })
    local disposeSecond = ctx.logger:exporter({
      export = function(message)
        second[#second + 1] = message
      end,
    })

    disposeFirst()
    ctx.logger:info("test")
    expect(first_).to.deep.equal({})
    expect(second).to.have.length(1)

    disposeSecond()
    ctx.logger:info("test")
    expect(second).to.have.length(1)
  end)

  -- logger.spec.ts:55
  it("uses fiber name when called from outside any service", function()
    local ctx, captured = setup()
    ctx.logger:debug("hello")
    expect(names(captured)).to.deep.equal({ "root" })
  end)

  -- logger.spec.ts:61
  it("honours explicit name argument", function()
    local ctx, captured = setup()
    ctx.logger("custom"):debug("hello")
    expect(names(captured)).to.deep.equal({ "custom" })
  end)

  -- logger.spec.ts:67
  it("honours intercept name", function()
    local ctx, captured = setup()
    ctx:intercept("logger", { name = "intercepted" }).logger:debug("hello")
    expect(names(captured)).to.deep.equal({ "intercepted" })
  end)

  -- logger.spec.ts:73
  it("uses service name when called from inside a Service method (regression)", function()
    local ctx, captured = setup()

    local FooService = cordis.class("foo:driver", cordis.Service)
    function FooService:constructor(c)
      cordis.Service.constructor(self, c, "foo")
    end
    function FooService:action()
      self.ctx.logger:debug("from action")
    end

    cordis.await(ctx:use(FooService))
    ctx.foo:action()
    U.sleep()
    expect(contains(names(captured), "foo:driver")).to.be.ok()
    expect(contains(names(captured), "root")).to.equal(false)
  end)

  -- logger.spec.ts:91
  it("still lets outer caller intercept override the service-derived name", function()
    local ctx, captured = setup()

    local FooService = cordis.class("foo:driver", cordis.Service)
    function FooService:constructor(c)
      cordis.Service.constructor(self, c, "foo")
    end
    function FooService:action()
      self.ctx.logger:debug("from action")
    end

    cordis.await(ctx:use(FooService))
    ctx:intercept("logger", { name = "caller-override" }).foo:action()
    U.sleep()
    expect(contains(names(captured), "caller-override")).to.be.ok()
    expect(contains(names(captured), "foo:driver")).to.equal(false)
  end)

  -- logger.spec.ts:109
  it("uses the innermost service name and restores the outer service", function()
    local ctx, captured = setup()

    local BarService = cordis.class("bar:driver", cordis.Service)
    function BarService:constructor(c)
      cordis.Service.constructor(self, c, "bar")
    end
    function BarService:action()
      self.ctx.logger:debug("from bar")
    end

    local FooService = cordis.class("foo:driver", cordis.Service)
    FooService.inject = { "bar" }
    function FooService:constructor(c)
      cordis.Service.constructor(self, c, "foo")
    end
    function FooService:action()
      self.ctx.bar:action()
      self.ctx.logger:debug("from foo")
    end

    cordis.await(ctx:use(BarService))
    cordis.await(ctx:use(FooService))
    cordis.await(ctx:inject({ "foo" }, function(c)
      c.foo:action()
    end))

    local got = {}
    for i, m in ipairs(captured) do
      got[i] = { m.name, m.args[1] }
    end
    expect(got).to.deep.equal({
      { "bar:driver", "from bar" },
      { "foo:driver", "from foo" },
    })
  end)

  -- logger.spec.ts:140
  it("uses service name when called from inside [Service.init] (unchanged behaviour)", function()
    local ctx, captured = setup()

    local FooService = cordis.class("foo:driver", cordis.Service)
    function FooService:constructor(c)
      cordis.Service.constructor(self, c, "foo")
    end
    FooService[cordis.Service.init] = function(self)
      self.ctx.logger:debug("from init")
    end

    cordis.await(ctx:use(FooService))
    U.sleep()
    expect(contains(names(captured), "foo:driver")).to.be.ok()
  end)

  -- logger.spec.ts:156
  it("logs an error whose errors array is empty", function()
    local ctx, captured = setup()
    local err = cordis.AggregateError.new({}, "empty aggregate")
    ctx.logger:warn(err)
    expect(captured).to.have.length(1)
    expect(captured[1].args[1]).to.equal(err)
  end)

  -- logger.spec.ts:165
  it("flattens an aggregate error into its members", function()
    local ctx, captured = setup()
    local inner = cordis.Error.new("inner")
    local outer = cordis.AggregateError.new({ inner }, "outer")
    ctx.logger:warn(outer)
    expect(captured).to.have.length(1)
    expect(captured[1].args[1]).to.equal(inner)
  end)
end)
