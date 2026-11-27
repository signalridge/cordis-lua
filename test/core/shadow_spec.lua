-- Ported from cordis packages/core/tests/shadow.spec.ts (MIT, (c) Shigma)
local cordis = require("cordis")
local U = require("kit.util")

local Service = cordis.Service
local symbols = cordis.symbols

describe("Traceable caller", function()
  -- shadow.spec.ts:5
  it("keeps caller metadata separate from the service shadow", function()
    local innerOrigin
    local outerOrigin

    local Inner = cordis.class("Inner", Service)
    function Inner:constructor(ctx)
      Service.constructor(self, ctx, "inner")
      innerOrigin = ctx
    end
    function Inner:inspect()
      return {
        caller = self[symbols.caller],
        shadow = self.ctx[symbols.shadow],
      }
    end

    local Outer = cordis.class("Outer", Service)
    Outer.inject = { "inner" }
    function Outer:constructor(ctx)
      Service.constructor(self, ctx, "outer")
      outerOrigin = ctx
    end
    function Outer:inspect()
      local result = self.ctx["inner"]:inspect()
      return {
        caller = result.caller,
        shadow = result.shadow,
        outerShadow = self.ctx[symbols.shadow],
      }
    end

    local root = U.root()
    cordis.await(root:use(Inner))
    cordis.await(root:use(Outer))

    local result
    cordis.await(root:inject({ "outer" }, function(ctx)
      result = ctx["outer"]:inspect()
    end))

    expect(result.caller).to.equal(outerOrigin)
    expect(result.shadow).to.equal(innerOrigin)
    expect(result.outerShadow).to.equal(outerOrigin)

    -- accessing the service from root must not collapse the shadow
    local direct = root["outer"]:inspect()
    expect(direct.caller).to.equal(outerOrigin)
    expect(direct.shadow).to.equal(innerOrigin)
    expect(direct.outerShadow).to.equal(outerOrigin)
  end)

  -- shadow.spec.ts:60
  it("applies the service inject when entered from root", function()
    local Inner = cordis.class("Inner", Service)
    function Inner:constructor(ctx)
      Service.constructor(self, ctx, "inner")
    end
    function Inner:hello()
      return "hello"
    end

    local Outer = cordis.class("Outer", Service)
    -- deliberately does not inject `inner`
    function Outer:constructor(ctx)
      Service.constructor(self, ctx, "outer")
    end
    function Outer:probe()
      return self.ctx["inner"]:hello()
    end

    local root = U.root()
    cordis.await(root:use(Inner))
    cordis.await(root:use(Outer))

    local message = 'cannot get property "inner" without inject'
    expect(function()
      return root["outer"]:probe()
    end).to.throw(message)
    cordis.await(root:inject({ "outer" }, function(ctx)
      expect(function()
        return ctx["outer"]:probe()
      end).to.throw(message)
    end))
  end)

  -- shadow.spec.ts:93
  it("resolves dependencies through a captured shadow", function()
    local Inner = cordis.class("Inner", Service)
    function Inner:constructor(ctx)
      Service.constructor(self, ctx, "inner")
    end
    function Inner:hello()
      return "hello"
    end

    -- a plain object handed out by a service, capturing its `this.ctx`
    local Holder = cordis.class("Holder")
    function Holder:constructor(ctx)
      self[Service.tracker] = { property = "ctx" }
      self.ctx = ctx
    end
    function Holder:probe()
      return { self.ctx["outer"]:tag(), self.ctx["inner"]:hello() }
    end
    function Holder:depth()
      local depth = 0
      local cursor = self.ctx
      while cursor and cursor[symbols.shadow] do
        depth = depth + 1
        cursor = cursor[symbols.shadow]
      end
      return depth
    end

    local Outer = cordis.class("Outer", Service)
    Outer.inject = { "inner" }
    function Outer:constructor(ctx)
      Service.constructor(self, ctx, "outer")
    end
    function Outer:tag()
      return "outer"
    end
    function Outer:create()
      return Holder.new(self.ctx)
    end

    local root = U.root()
    cordis.await(root:use(Inner))
    cordis.await(root:use(Outer))

    -- the holder's own ctx is a shadow, but the shadow it is accessed through
    -- must stay exactly one level deep
    expect(root["outer"]:create():probe()).to.deep.equal({ "outer", "hello" })
    expect(root["outer"]:create():depth()).to.equal(1)
    cordis.await(root:inject({ "outer" }, function(ctx)
      expect(ctx["outer"]:create():probe()).to.deep.equal({ "outer", "hello" })
      expect(ctx["outer"]:create():depth()).to.equal(1)
    end))
  end)

  -- shadow.spec.ts:157
  it("resolves same-name own provisions at their definition sites", function()
    local first = cordis.symbol("first")
    local second = cordis.symbol("second")
    local Probe = cordis.class("Probe", Service)
    function Probe:constructor(ctx, tag)
      Service.constructor(self, ctx, "foo")
      self.tag = tag
    end
    function Probe:inspect()
      return { self.ctx.foo.tag, self.ctx[cordis.Context.isolate].foo }
    end

    local Relay = cordis.class("Relay", Service)
    Relay.inject = { "foo" }
    function Relay:constructor(ctx)
      Service.constructor(self, ctx, "relay")
    end
    function Relay:inspect()
      return self.ctx.foo:inspect()
    end

    local root = U.root()
    cordis.await(root:use(function(ctx)
      Probe.new(ctx:isolate("foo", first), "first")
      Probe.new(ctx:isolate("foo", second), "second")
    end))
    cordis.await(root:isolate("foo", first):use(Relay))
    -- The use site changes, while the definition sites of the relay and the
    -- probe it injects stay in the first realm.
    expect(root:isolate("foo", second)["relay"]:inspect()).to.deep.equal({ "first", second })
    expect(root:isolate("foo", second).foo:inspect()).to.deep.equal({ "second", second })
    cordis.await(root.fiber:dispose())
  end)

  -- shadow.spec.ts:195
  it("keeps unchecked access for services provided on the root ctx", function()
    local Inner = cordis.class("Inner", Service)
    function Inner:constructor(ctx)
      Service.constructor(self, ctx, "inner")
    end
    function Inner:hello()
      return "hello"
    end

    -- provided outside the fiber system, so it can never declare `inject`
    local Rooted = cordis.class("Rooted")
    function Rooted:constructor(ctx)
      self[Service.tracker] = { property = "ctx" }
      self.ctx = ctx
    end
    function Rooted:probe()
      return self.ctx["inner"]:hello()
    end

    local root = U.root()
    cordis.await(root:use(Inner))
    root:provide("rooted", Rooted.new(root))

    expect(root["rooted"]:probe()).to.equal("hello")
  end)

  -- shadow.spec.ts:226
  it("exposes the caller without preserving shadow for noShadow services", function()
    local outerOrigin

    local Probe = cordis.class("Probe")
    function Probe:constructor(ctx)
      self[Service.tracker] = { property = "ctx", noShadow = true }
      self.ctx = ctx
    end
    function Probe:inspect()
      return {
        caller = self[symbols.caller],
        shadow = self.ctx[symbols.shadow],
      }
    end

    local Outer = cordis.class("Outer", Service)
    Outer.inject = { "probe" }
    function Outer:constructor(ctx)
      Service.constructor(self, ctx, "outer")
      outerOrigin = ctx
    end
    function Outer:inspect()
      return self.ctx["probe"]:inspect()
    end

    local root = U.root()
    root:provide("probe", Probe.new(root))
    cordis.await(root:use(Outer))

    local result
    cordis.await(root:inject({ "outer" }, function(ctx)
      result = ctx["outer"]:inspect()
    end))

    expect(result.caller).to.equal(outerOrigin)
    expect(result.shadow).to.equal(nil)
  end)

  -- shadow.spec.ts:271
  it("exposes the caller to callable services", function()
    local outerOrigin

    local Callable = cordis.class("Callable", Service)
    function Callable:constructor(ctx)
      Service.constructor(self, ctx, "callable")
    end
    Callable[Service.invoke] = function(self)
      return self[symbols.caller]
    end

    local Outer = cordis.class("Outer", Service)
    Outer.inject = { "callable" }
    function Outer:constructor(ctx)
      Service.constructor(self, ctx, "outer")
      outerOrigin = ctx
    end
    function Outer:call()
      return self.ctx["callable"]()
    end

    local root = U.root()
    cordis.await(root:use(Callable))
    cordis.await(root:use(Outer))

    local caller
    cordis.await(root:inject({ "outer" }, function(ctx)
      caller = ctx["outer"]:call()
    end))

    expect(caller).to.equal(outerOrigin)
  end)

  -- shadow.spec.ts:313
  it("strips service shadow before creating components", function()
    local Loader = cordis.class("Loader", Service)
    function Loader:constructor(ctx)
      Service.constructor(self, ctx, "loader")
    end
    function Loader:load(component)
      return self.ctx:use(component)
    end

    local Server = cordis.class("Server", Service)
    function Server:constructor(ctx)
      Service.constructor(self, ctx, "server")
    end

    local injected = false
    -- a JS `function Consumer` is a constructor (it has a prototype), so its
    -- returned fiber replaces the instance and is never treated as an effect;
    -- in Lua that is a class whose constructor returns the fiber
    local Consumer = cordis.class("Consumer")
    function Consumer:constructor(ctx)
      return ctx:inject({ "server" }, function(ctx)
        injected = Server.is(ctx.server)
      end)
    end

    local root = U.root()
    cordis.await(root:use(Loader))
    cordis.await(root:inject(
      { "loader" },
      cordis.async(function(ctx)
        local loader = ctx["loader"]
        cordis.await(loader:load(Server))
        cordis.await(loader:load(Consumer))
      end)
    ))

    expect(injected).to.equal(true)
    local errors = {}
    for _, message in ipairs(root.logger.buffer) do
      if message.type == "error" then
        errors[#errors + 1] = message
      end
    end
    expect(errors).to.have.length(0)
  end)

  -- Lua-only: a method reached through the traceable proxy keeps
  -- every value it returns; the first is traced like upstream's single result
  it("passes every return value of a traced method through", function()
    local Multi = cordis.class("Multi", Service)
    function Multi:constructor(ctx)
      Service.constructor(self, ctx, "multi")
    end
    function Multi:pair()
      return self, "second", nil, 4
    end
    function Multi:fail()
      return nil, "reason"
    end

    local root = U.root()
    cordis.await(root:use(Multi))

    local first, second, third, fourth, count, none, reason
    cordis.await(root:inject({ "multi" }, function(ctx)
      local packed = table.pack(ctx["multi"]:pair())
      first, second, third, fourth, count = packed[1], packed[2], packed[3], packed[4], packed.n
      none, reason = ctx["multi"]:fail()
    end))

    expect(count).to.equal(4)
    expect(Multi.is(first)).to.equal(true)
    expect(second).to.equal("second")
    expect(third).to.equal(nil)
    expect(fourth).to.equal(4)
    expect(none).to.equal(nil)
    expect(reason).to.equal("reason")
  end)

  -- Lua-only: a method that is a Lua function is read as a function, as
  -- upstream's Proxy of a function is `typeof === "function"`: stable across reads, the
  -- receiver still swapped for the shadow, results still traced. A callable table stays a proxy.
  it("reads a function method as a function, stable, with the shadow as receiver", function()
    local Probe = cordis.class("Probe", Service)
    function Probe:constructor(ctx)
      Service.constructor(self, ctx, "probe")
    end
    function Probe:who()
      return self, self[symbols.caller]
    end
    local spied = setmetatable({}, {
      __call = function(_, self)
        return self
      end,
    })

    local root = U.root()
    cordis.await(root:use(Probe))
    rawset(root["probe"][symbols.original] or root["probe"], "spied", spied)

    local kind, same, traced, caller, callerCtx, spiedKind
    cordis.await(root:inject({ "probe" }, function(ctx)
      local probe = ctx["probe"]
      kind = type(probe.who)
      same = rawequal(probe.who, probe.who)
      local receiver
      receiver, caller = probe:who()
      traced = Probe.is(receiver) and not rawequal(receiver, probe)
      callerCtx = ctx
      spiedKind = type(probe.spied)
    end))

    expect(kind).to.equal("function")
    expect(same).to.equal(true)
    expect(traced).to.equal(true)
    expect(caller).to.equal(callerCtx)
    expect(spiedKind).to.equal("table")
  end)

  -- shadow.spec.ts:349
  it("keeps the def site when a service derives from its own ctx", function()
    local outerOrigin

    local Inner = cordis.class("Inner", Service)
    function Inner:constructor(ctx)
      Service.constructor(self, ctx, "inner")
    end
    function Inner:inspect()
      return self[symbols.caller]
    end

    local Outer = cordis.class("Outer", Service)
    Outer.inject = { "inner" }
    function Outer:constructor(ctx)
      Service.constructor(self, ctx, "outer")
      outerOrigin = ctx
    end
    function Outer:derive()
      local derived = self.ctx:extend({ tag = "derived" })
      return {
        tag = derived.tag,
        caller = derived["inner"]:inspect(),
      }
    end

    local root = U.root()
    cordis.await(root:use(Inner))
    cordis.await(root:use(Outer))

    local result
    cordis.await(root:inject({ "outer" }, function(ctx)
      result = ctx["outer"]:derive()
    end))

    -- `self.ctx` is a shadow inside a service method; deriving from it must keep the def site, or
    -- the derived ctx resolves services from the wrong site
    expect(result.tag).to.equal("derived")
    expect(result.caller).to.equal(outerOrigin)
  end)
end)
