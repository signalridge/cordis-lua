-- Regression tests for behavior reviewed against upstream Cordis.
-- Each case failed before its fix.
local cordis = require("cordis")
local U = require("kit.util")
local spy = require("kit.spy")
local FiberState = cordis.FiberState

describe("fidelity review", function()
  -- events.ts:108, :126: parallel / serial are async upstream, so an error while
  -- resolving the dispatch rejects the returned Future instead of raising
  it("parallel and serial reject on a failing dispatch", function()
    local root = U.root()
    root:on("internal/dispatch", function()
      error(cordis.Error.new("dispatch failed"))
    end)
    local ok, p = pcall(root.parallel, root, "probe")
    expect(ok).to.equal(true)
    expect(p).to.reject("dispatch failed")
    local ok2, s = pcall(root.serial, root, "probe")
    expect(ok2).to.equal(true)
    expect(s).to.reject("dispatch failed")
  end)

  -- events.ts:96-106: the deprecated dispatch's closures pass only their own arguments
  it("deprecated dispatch passes the closure's arguments only", function()
    local root = U.root()
    local listener = spy.fn()
    root:on("probe", listener)
    local invoke = root.events:dispatch("emit", { "probe", "pre" })[1]
    invoke("own")
    expect(listener.calls[1].n).to.equal(1)
    expect(listener.calls[1][1]).to.equal("own")
  end)

  -- a PENDING fiber's effects are disposed with it
  it("disposes the effects of a PENDING fiber", function()
    local root = U.root()
    local cleanup = spy.fn()
    local fiber = root:inject({ "never-provided" }, function() end)
    expect(fiber.state).to.equal(FiberState.PENDING)
    fiber.ctx:effect(function()
      return cleanup
    end)
    cordis.await(fiber:dispose())
    expect(cleanup.calls).to.have.length(1)
    expect(fiber.state).to.equal(FiberState.DISPOSED)
  end)

  -- unloading waits for a cleanup that was started by hand and is still running
  it("waits for an effect cleanup already in progress", function()
    local root = U.root()
    local done = false
    local dispose
    local fiber = cordis.await(root:use(function(ctx)
      dispose = ctx:effect(function()
        return cordis.async(function()
          U.sleep(50)
          done = true
        end)
      end)
    end))
    dispose()
    cordis.await(fiber:dispose())
    expect(done).to.equal(true)
  end)
end)

describe("reflect read fast path", function()
  -- the waterfall is skipped only while nothing listens on internal/get: a listener added
  -- later is consulted, and removing it restores the plain read
  it("consults an internal/get listener added after earlier reads", function()
    local root = U.root()
    root:provide("p1probe", "real")
    local fiber = cordis.await(root:inject({ "p1probe" }, function() end))
    local ctx = fiber.ctx
    expect(ctx.p1probe).to.equal("real")
    local off = root:on("internal/get", function(_, name, _, next)
      if name == "p1probe" then
        return "intercepted"
      end
      return next()
    end)
    expect(ctx.p1probe).to.equal("intercepted")
    off()
    expect(ctx.p1probe).to.equal("real")
  end)

  -- an accessor's own error comes out as before (rethrown with the access error)
  it("rethrows an accessor's error unchanged", function()
    local root = U.root()
    root.reflect:accessor("p1acc", {
      get = function()
        error(cordis.Error.new("accessor failed"), 0)
      end,
    })
    local ok, err = pcall(function()
      return root.p1acc
    end)
    expect(ok).to.equal(false)
    expect(tostring(err):find("accessor failed", 1, true) ~= nil).to.equal(true)
  end)
end)
