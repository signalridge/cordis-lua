-- Library-own tests: `root:close()`: a terminal close of the
-- root context (upstream's root dispose is a restart and leaves it usable).
local cordis = require("cordis")
local U = require("kit.util")
local spy = require("kit.spy")
local FiberState = cordis.FiberState

describe("root:close", function()
  it("disposes everything and waits for asynchronous cleanup", function()
    local root = U.root()
    local order = {}
    local child = cordis.await(root:use(function(ctx)
      ctx:effect(function()
        return cordis.async(function()
          U.sleep(10)
          order[#order + 1] = "async cleanup"
        end)
      end)
    end))
    local direct = spy.fn()
    root:effect(function()
      return direct
    end)
    cordis.await(root:close())
    order[#order + 1] = "closed"
    expect(order).to.deep.equal({ "async cleanup", "closed" })
    expect(direct.calls).to.have.length(1)
    expect(child.state).to.equal(FiberState.DISPOSED)
    expect(root.fiber.state).to.equal(FiberState.DISPOSED)
  end)

  it("rejects every new registration once closed", function()
    local root = U.root()
    cordis.await(root:close())
    local inactive = "cannot create effect on inactive context"
    expect(function()
      root:use(function() end)
    end).to.throw(inactive)
    expect(function()
      root:effect(function() end)
    end).to.throw(inactive)
    expect(function()
      root:on("event", function() end)
    end).to.throw(inactive)
    expect(function()
      root:provide("foo", 1)
    end).to.throw(inactive)
    -- upstream's root dispose (a restart) is refused too
    expect(root.fiber:dispose()).to.reject(inactive)
  end)

  it("rejects registrations made by cleanup that runs during the close", function()
    local root = U.root()
    local result = {}
    root:effect(function()
      return function()
        result.ok = pcall(function()
          root:effect(function() end)
        end)
      end
    end)
    cordis.await(root:close())
    expect(result.ok).to.equal(false)
    expect(#root.fiber:getEffects()).to.equal(0)
  end)

  it("returns the same close to every caller", function()
    local root = U.root()
    local first = root:close()
    local second = root:close()
    expect(second).to.equal(first)
    cordis.await(first)
  end)

  it("returns the same close Future to re-entrant internal/status listeners without deadlock", function()
    local root = U.root()
    local seenFromRoot, seenFromDerived
    local awaited = false
    root:on("internal/status", function(fiber)
      if fiber == root.fiber then
        seenFromRoot = root:close()
        seenFromDerived = root:extend():close()
        seenFromDerived:await()
        awaited = true
      end
    end)
    local outer = root:close()
    expect(awaited).to.equal(true)
    expect(rawequal(seenFromRoot, outer)).to.equal(true)
    expect(rawequal(seenFromDerived, outer)).to.equal(true)
    expect(root.fiber.state).to.equal(FiberState.DISPOSED)
    cordis.await(outer)
  end)

  it("settles on the root scheduler even when closed via a context with a foreign host", function()
    U.requires("reference scheduler")
    local scheduler = require("cordis.host.coroutine")
    local s1 = scheduler.new({ eager = U.state.eager })
    local s2 = scheduler.new({ eager = U.state.eager })
    local done = false
    local ok, err = s1.drive(function()
      local root = cordis.Context.new({ host = s1.host })
      cordis.await(root:extend({ host = s2.host }):close():next(function()
        done = true
      end))
    end)
    if not ok then
      error(err, 0)
    end
    expect(done).to.equal(true)
  end)

  it("preserves close Future identity when a status listener throws", function()
    local root = U.root()
    local saved
    root:on("internal/status", function(fiber)
      if fiber == root.fiber then
        saved = root:close()
        error("status failed", 0)
      end
    end)
    local ok = pcall(function()
      root:close()
    end)
    expect(ok).to.equal(false)
    local retried = root:close()
    expect(rawequal(saved, retried)).to.equal(true)
    cordis.await(retried)
    expect(root.fiber.state).to.equal(FiberState.DISPOSED)
  end)

  it("completes re-entrant close await when a child injects a root-provided service", function()
    local root = U.root()
    root:provide("svc", { ok = true })
    local child = cordis.await(root:inject({ "svc" }, function() end))
    expect(child.state).to.equal(FiberState.ACTIVE)

    local seenFromRoot, seenFromDerived
    local awaited = false
    root:on("internal/status", function(fiber)
      if fiber == root.fiber then
        seenFromRoot = root:close()
        seenFromDerived = root:extend():close()
        seenFromDerived:await()
        awaited = true
      end
    end)
    local outer = root:close()
    expect(awaited).to.equal(true)
    expect(rawequal(seenFromRoot, outer)).to.equal(true)
    expect(rawequal(seenFromDerived, outer)).to.equal(true)
    cordis.await(outer)
    expect(root.fiber.state).to.equal(FiberState.DISPOSED)
    expect(child.state).to.equal(FiberState.DISPOSED)
  end)

  it("completes retried close when a status listener throws with an active service consumer", function()
    local root = U.root()
    root:provide("svc", { ok = true })
    local child = cordis.await(root:inject({ "svc" }, function() end))
    expect(child.state).to.equal(FiberState.ACTIVE)

    local saved
    root:on("internal/status", function(fiber)
      if fiber == root.fiber then
        saved = root:close()
        error("status failed", 0)
      end
    end)
    local ok = pcall(function()
      root:close()
    end)
    expect(ok).to.equal(false)
    local retried = root:close()
    expect(rawequal(saved, retried)).to.equal(true)
    cordis.await(retried)
    expect(root.fiber.state).to.equal(FiberState.DISPOSED)
    expect(child.state).to.equal(FiberState.DISPOSED)
  end)

  it("is only available on the root context", function()
    local root = U.root()
    local fiber = cordis.await(root:use(function() end))
    expect(function()
      fiber.ctx:close()
    end).to.throw("only the root context can be closed")
  end)
end)
