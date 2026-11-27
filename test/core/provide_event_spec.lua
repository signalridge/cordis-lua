local cordis = require("cordis")
local U = require("kit.util")

describe("internal/provide", function()
  it("passes the providing context, name and value to a listener", function()
    local root = U.root()
    local fiber = cordis.await(root:use(function() end))
    local value = {}
    local seenCtx, seenName, seenValue
    root:on("internal/provide", function(ctx, name, given)
      seenCtx, seenName, seenValue = ctx, name, given
    end)

    fiber.ctx:provide("event-probe", value)
    expect(rawequal(seenCtx, fiber.ctx)).to.equal(true)
    expect(seenName).to.equal("event-probe")
    expect(rawequal(seenValue, value)).to.equal(true)
  end)

  it("propagates a refusal without registering anything and permits a later provide", function()
    local root = U.root()
    local fiber = cordis.await(root:use(function() end))
    local refusal = {}
    local before = fiber.provisions:size()
    local off = root:on("internal/provide", function()
      error(refusal, 0)
    end)

    local ok, err = pcall(function()
      fiber.ctx:provide("refused-probe", "first")
    end)
    expect(ok).to.equal(false)
    expect(rawequal(err, refusal)).to.equal(true)
    expect(root:get("refused-probe")).to.equal(nil)
    expect(fiber.provisions:size()).to.equal(before)
    expect(root.reflect.props["refused-probe"]).to.equal(nil)

    off()
    fiber.ctx:provide("refused-probe", "later")
    expect(root:get("refused-probe")).to.equal("later")
  end)

  it("provides as before when there is no listener", function()
    local root = U.root()
    root:provide("plain-probe", "value")
    expect(root:get("plain-probe")).to.equal("value")
  end)

  it("delivers an isolated child's provide to a root listener", function()
    local root = U.root()
    local fiber = cordis.await(root:use(function() end))
    local isolated = fiber.ctx:isolate("isolated-probe", cordis.symbol("private"))
    local seenCtx, seenName
    root:on("internal/provide", function(ctx, name)
      seenCtx, seenName = ctx, name
    end)

    isolated:provide("isolated-probe", "value")
    expect(rawequal(seenCtx, isolated)).to.equal(true)
    expect(seenName).to.equal("isolated-probe")
  end)

  it("fires on set and preserves the previous value on refusal", function()
    local root = U.root()
    local fiber = cordis.await(root:use(function() end))
    fiber.ctx:provide("set-probe", "initial")

    local seenCtx, seenName, seenValue
    local refuse = false
    root:on("internal/provide", function(ctx, name, given)
      seenCtx, seenName, seenValue = ctx, name, given
      if refuse then
        error("denied", 0)
      end
    end)

    fiber.ctx:set("set-probe", "updated")
    expect(rawequal(seenCtx, fiber.ctx)).to.equal(true)
    expect(seenName).to.equal("set-probe")
    expect(seenValue).to.equal("updated")
    expect(root:get("set-probe")).to.equal("updated")

    refuse = true
    local ok = pcall(function()
      fiber.ctx:set("set-probe", "blocked")
    end)
    expect(ok).to.equal(false)
    expect(root:get("set-probe")).to.equal("updated")
  end)

  it("does not emit duplicate internal/service notifications on active set", function()
    local root = U.root()
    local fiber = cordis.await(root:use(function() end))
    local notifications = 0
    root:on("internal/service", function(_, name)
      if name == "notify-probe" then
        notifications = notifications + 1
      end
    end)

    fiber.ctx:provide("notify-probe", "v1")
    expect(notifications).to.equal(1)
    fiber.ctx:set("notify-probe", "v2")
    expect(notifications).to.equal(1)
  end)

  it("fires before accessor and mixin registration and aborts on refusal", function()
    local root = U.root()
    local fiber = cordis.await(root:use(function() end))
    fiber.ctx:provide("mixin-source", {
      fn = function()
        return 1
      end,
    })

    local refused = { ["acc-probe"] = true, ["mix-probe"] = true }
    root:on("internal/provide", function(_, name)
      if refused[name] then
        error("denied", 0)
      end
    end)

    local okAcc = pcall(function()
      fiber.ctx:accessor("acc-probe", {
        get = function()
          return "bad"
        end,
      })
    end)
    expect(okAcc).to.equal(false)
    expect(root.reflect.props["acc-probe"]).to.equal(nil)

    local okMix = pcall(function()
      fiber.ctx:mixin("mixin-source", { fn = "mix-probe" })
    end)
    expect(okMix).to.equal(false)
    expect(root.reflect.props["mix-probe"]).to.equal(nil)
  end)

  it("fires on pre-provide root property writes and leaves root clean on refusal", function()
    local root = U.root()
    root:on("internal/provide", function(_, name)
      if name == "blocked-root-prop" then
        error("denied", 0)
      end
    end)

    local ok = pcall(function()
      root["blocked-root-prop"] = "leak"
    end)
    expect(ok).to.equal(false)
    expect(root["blocked-root-prop"]).to.equal(nil)

    root["allowed-root-prop"] = "ok"
    expect(root["allowed-root-prop"]).to.equal("ok")
  end)
end)
