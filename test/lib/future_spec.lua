-- Library-own tests: Future (no upstream counterpart).
local U = require("kit.util")
local spy = require("kit.spy")
local F = require("cordis.future")
local Future = F.Future

describe("Future", function()
  it("resolves and chains through next", function()
    local f, resolve = Future.withResolvers(U.host())
    local g = f:next(function(v)
      return v + 1
    end):next(function(v)
      return v * 2
    end)
    resolve(1)
    expect(g:await()).to.equal(4)
  end)

  it("rejects and propagates to catch", function()
    local f = Future.new(U.host(), function()
      error({ message = "boom" })
    end)
    local seen
    local g = f:next(function()
      return "unreachable"
    end):catch(function(e)
      seen = e.message
      return "recovered"
    end)
    expect(g:await()).to.equal("recovered")
    expect(seen).to.equal("boom")
  end)

  it("await raises the rejection reason", function()
    local f = Future.reject(U.host(), "bad")
    expect(f).to.reject("bad")
  end)

  it("reactions never run synchronously", function()
    local cb = spy.fn()
    local f = Future.resolve(U.host(), 1)
    f:next(cb)
    expect(cb).to.have.been.called(0)
    U.sleep(0)
    expect(cb).to.have.been.called(1)
  end)

  it("adopts a returned future", function()
    local inner, resolve = Future.withResolvers(U.host())
    local outer = Future.resolve(U.host(), 0):next(function()
      return inner
    end)
    U.sleep(0)
    expect(outer:state()).to.equal("pending")
    resolve("x")
    expect(outer:await()).to.equal("x")
  end)

  it("finally runs on both outcomes and keeps the value", function()
    local cb = spy.fn()
    expect(Future.resolve(U.host(), 3):finally(cb):await()).to.equal(3)
    expect(Future.reject(U.host(), "e"):finally(cb)).to.reject("e")
    expect(cb).to.have.been.called(2)
  end)

  it("all collects in order and fails fast", function()
    local host = U.host()
    local a, ra = Future.withResolvers(host)
    local b, rb = Future.withResolvers(host)
    local all = Future.all(host, { a, b, 3 })
    rb(2)
    ra(1)
    expect(all:await()).to.deep.equal({ 1, 2, 3 })
    expect(Future.all(host, { Future.reject(host, "x"), a })).to.reject("x")
    expect(Future.all(host, {}):await()).to.deep.equal({})
  end)

  it("allSettled reports every outcome", function()
    local host = U.host()
    local r = Future.allSettled(host, { Future.resolve(host, 1), Future.reject(host, "e") }):await()
    expect(r).to.deep.equal({ { status = "fulfilled", value = 1 }, { status = "rejected", reason = "e" } })
  end)

  it("await on a settled future returns immediately", function()
    -- "immediately" is checked on the virtual clock
    U.requires("virtual time")
    local host = U.host()
    local f = Future.resolve(host, 7)
    local t0 = host.now()
    expect(f:await()).to.equal(7)
    expect(f:await()).to.equal(7)
    expect(host.now()).to.equal(t0)
  end)

  it("async runs in a task and returns a future", function()
    local fn = F.async(function(a, b)
      U.sleep(10)
      return a + b
    end)
    local f = fn(1, 2)
    expect(f:state()).to.equal("pending")
    expect(f:await()).to.equal(3)
    local bad = F.async(function()
      error("nope", 0)
    end)
    expect(bad()).to.reject("nope")
  end)

  it("tick yields until queued jobs ran, on both spawn modes", function()
    local cb = spy.fn()
    Future.resolve(U.host(), 1):next(cb)
    F.tick(U.host())
    expect(cb).to.have.been.called(1)
  end)

  it("a job that awaits does not starve later jobs", function()
    local host = U.host()
    local gate, open = Future.withResolvers(host)
    local order = {}
    Future.resolve(host):next(function()
      gate:await()
      order[#order + 1] = "first"
    end)
    Future.resolve(host):next(function()
      order[#order + 1] = "second"
      open()
    end)
    U.sleep(0)
    expect(order).to.deep.equal({ "second", "first" })
  end)
end)

describe("Future regressions", function()
  it("catch does not run on fulfillment", function()
    local cb = spy.fn()
    expect(Future.resolve(U.host(), 1):catch(cb):await()).to.equal(1)
    expect(cb).to.have.been.called(0)
  end)

  it(
    "runSync preserves interior/trailing nils, multiple returns, and AsyncFunction across scope and nil scope",
    function()
      local host = U.host()
      local seenArgs
      local function probe(...)
        seenArgs = table.pack(...)
        return nil, "mid", nil
      end

      local r1 = table.pack(F.runSync(host, nil, probe, nil, "x", nil))
      expect(seenArgs.n).to.equal(3)
      expect(seenArgs[1]).to.equal(nil)
      expect(seenArgs[2]).to.equal("x")
      expect(seenArgs[3]).to.equal(nil)
      expect(r1.n).to.equal(3)
      expect(r1[1]).to.equal(nil)
      expect(r1[2]).to.equal("mid")
      expect(r1[3]).to.equal(nil)

      local ranInScope = false
      local scope = {
        run = function(fn, ...)
          ranInScope = true
          return fn(...)
        end,
        spawn = function(fn)
          host.spawn(fn)
        end,
      }
      local r2 = table.pack(F.runSync(host, scope, probe, nil, "y", nil))
      expect(ranInScope).to.equal(true)
      expect(seenArgs.n).to.equal(3)
      expect(seenArgs[1]).to.equal(nil)
      expect(seenArgs[2]).to.equal("y")
      expect(seenArgs[3]).to.equal(nil)
      expect(r2.n).to.equal(3)
      expect(r2[1]).to.equal(nil)
      expect(r2[2]).to.equal("mid")
      expect(r2[3]).to.equal(nil)

      local afn = F.async(function(...)
        local p = table.pack(...)
        return p.n
      end)
      expect(F.runSync(host, scope, afn, nil, 1, nil):await()).to.equal(3)
    end
  )

  it("does not re-adopt already-fulfilled fiber thenables in catch/finally and supports finally(nil)", function()
    local cordis = require("cordis")
    local root = cordis.Context.new({ host = U.host() })
    local fail = false
    local fiber = cordis.await(root:use(function()
      if fail then
        error(cordis.Error.new("reload boom"))
      end
    end))
    local settled = fiber:await()
    expect(settled:await()).to.equal(fiber)

    fail = true
    local failingRestart = fiber:restart()
    local caught = false
    expect(settled
      :catch(function()
        caught = true
      end)
      :await()).to.equal(fiber)
    expect(caught).to.equal(false)

    local ranFinally = false
    expect(settled
      :finally(function()
        ranFinally = true
      end)
      :await()).to.equal(fiber)
    expect(ranFinally).to.equal(true)
    expect(settled:finally(nil):await()).to.equal(fiber)
    expect(Future.reject(U.host(), "rej"):finally(nil)).to.reject("rej")
    expect(failingRestart).to.reject("reload boom")
  end)

  it("shares one FIFO job queue between raw host and context facades", function()
    local cordis = require("cordis")
    local raw = U.host()
    local root1 = cordis.Context.new({ host = raw })
    local root2 = cordis.Context.new({ host = raw })
    local order = {}
    Future.resolve(root1.host, 1):next(function()
      order[#order + 1] = "facade-1"
    end)
    Future.resolve(raw, 1):next(function()
      order[#order + 1] = "raw-1"
    end)
    Future.resolve(root2.host, 1):next(function()
      order[#order + 1] = "facade-2"
    end)
    F.tick(raw)
    expect(order).to.deep.equal({ "facade-1", "raw-1", "facade-2" })
  end)
end)
