-- Ported from cordis packages/core/tests/reflect.spec.ts (MIT, (c) Shigma)
local cordis = require("cordis")
local U = require("kit.util")
local spy = require("kit.spy")

describe("Reflect", function()
  -- reflect.spec.ts:7 (rewritten: contexts are not classes in Lua; a derived
  -- context object stands for an instance of a Context subclass)
  it("Context.is()", function()
    local sub = cordis.proto.create(cordis.Context.prototype)

    expect(cordis.Context.is(sub)).to.equal(true)
  end)

  -- reflect.spec.ts:13 (rewritten: the `ctx['prototype']` line is dropped, `prototype` is not a reserved name in Lua)
  it("access check", function()
    local root = U.root()

    cordis.await(root:use(function(ctx)
      -- (`ctx.prototype` is not a reserved name in Lua: line dropped)
      expect(function()
        return ctx.constructor
      end).never.to.throw()
      expect(function()
        return ctx.bar
      end).to.throw('cannot get property "bar" without inject')
      expect(function()
        ctx.bar = 0
      end).to.throw('cannot set property "bar" without provide')
    end))

    cordis.await(root:use(function(ctx)
      expect(function()
        ctx.foo = 0
      end).to.throw('cannot set property "foo" without provide')
      expect(function()
        ctx:provide("foo")
      end).never.to.throw()
      expect(function()
        ctx:provide("foo")
      end).to.throw('service "foo" has been registered at <root>')
      expect(function()
        ctx.foo = 0
      end).never.to.throw()
    end))
  end)

  -- reflect.spec.ts:31
  it("service injection", function()
    local root = U.root()
    local warn = spy.fn()
    root.logger.warn = warn
    root:mixin("foo", { "bar" })
    root:provide("foo")
    root:set("foo", { bar = 1 })

    -- foo is a service
    expect(root:get("foo")).to.be.ok()
    -- bar is a mixin
    expect(root:get("bar")).to.equal(nil)
    -- baz is a property
    expect(root:extend({ baz = 1 }):get("baz")).to.equal(nil)

    root:inject({ "foo" }, function(ctx)
      warn:reset()
      expect(warn.calls).to.have.length(0)

      ctx:extend({ baz = 2 }):use(function(ctx)
        warn:reset()
        expect(ctx.baz).to.equal(2)
        expect(warn.calls).to.have.length(0)
      end)
    end)
  end)

  -- reflect.spec.ts:58 (rewritten: stack frame name -> source line of the first non-library frame; isNativeError -> Error.is)
  it("access error", function()
    local root = U.root()
    root:provide("foo")
    root:set("foo", { bar = 1 })

    local function capture(callback)
      local ok, err = pcall(callback)
      if not ok then
        return err
      end
      error(cordis.Error.new("expected an access error"))
    end

    -- Lua functions have no names, so the first frame outside the library is
    -- matched by source line instead of `at <name> ` (rewritten)
    local function firstUserFrame(err)
      for line in err.traceback:gmatch("[^\n]+") do
        if
          not (
            line:find("stack traceback", 1, true)
            or line:find("lua/cordis/", 1, true)
            or line:find("tail calls", 1, true)
            or line:find("%[C%]")
          )
        then
          return line
        end
      end
    end

    local function getBar(ctx)
      return ctx.bar
    end

    local function setBar(ctx)
      ctx.bar = 0
    end

    -- the line check reads `debug.getinfo`
    U.requires("debug")
    local fiber = cordis.await(root:inject({ "foo" }, function(ctx)
      for _, callback in ipairs({ getBar, setBar }) do
        local err = capture(function()
          local result = callback(ctx)
          return result
        end)
        expect(cordis.Error.is(err)).to.equal(true)
        local line = debug.getinfo(callback, "S").linedefined + 1
        expect(firstUserFrame(err):find(":" .. line .. ":", 1, true) ~= nil).to.equal(true)
      end
    end))
    cordis.await(fiber:dispose())

    local function getFoo()
      return fiber.ctx.foo
    end

    local err = capture(getFoo)
    expect(cordis.Error.is(err)).to.equal(true)
    expect(err.message).to.equal('cannot get required service "foo" in inactive context')
    local line = debug.getinfo(getFoo, "S").linedefined + 1
    expect(firstUserFrame(err):find(":" .. line .. ":", 1, true) ~= nil).to.equal(true)
  end)

  -- reflect.spec.ts:99
  it("service inject leak", function()
    local root = U.root()
    root:provide("foo")
    root:set("foo", { bar = 1 })
    local fiber = cordis.await(root:inject({ "foo" }, function() end))
    expect(fiber.ctx.foo).to.be.ok()
    cordis.await(fiber:dispose())
    expect(function()
      return fiber.ctx.foo
    end).to.throw('cannot get required service "foo" in inactive context')
  end)

  -- reflect.spec.ts:109
  it("does not load a fiber disposed during service notification", function()
    local root = U.root()
    local apply = spy.fn(function(ctx, config) end)
    local component = { inject = { "foo" }, apply = apply }
    local fiber1 = root:use(component, { id = 1 })
    local fiber2 = root:use(component, { id = 2 })
    root:on("internal/status", function(fiber)
      if fiber == fiber1 and fiber.state == cordis.FiberState.LOADING then
        fiber2:dispose()
      end
    end)

    root:provide("foo", {})
    cordis.await(fiber1)
    local ids = {}
    for i, call in ipairs(apply.calls) do
      ids[i] = call[2].id
    end
    expect(ids).to.deep.equal({ 1 })
    expect(fiber2.state).to.equal(cordis.FiberState.DISPOSED)
    cordis.await(root.fiber:dispose())
  end)
end)
