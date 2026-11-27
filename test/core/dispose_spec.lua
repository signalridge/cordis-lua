-- Ported from cordis packages/core/tests/dispose.spec.ts (MIT, (c) Shigma)
local cordis = require("cordis")
local U = require("kit.util")
local spy = require("kit.spy")
local sleep, withTimers, advance = U.sleep, U.withTimers, U.advance

local function pusher(seq, n)
  return function()
    seq[#seq + 1] = n
  end
end

describe("Effects", function()
  -- dispose.spec.ts:7
  it("dispose by component", function()
    local root = U.root()
    local dispose = spy.fn()
    local fiber = cordis.await(root:use(function(ctx)
      ctx:effect(function()
        return dispose
      end, "test")
    end))
    expect(fiber:getEffects()).to.deep.equal({
      { label = "test", children = {} },
    })
    expect(dispose.calls).to.have.length(0)
    cordis.await(fiber:dispose())
    expect(dispose.calls).to.have.length(1)
    cordis.await(fiber:dispose())
    expect(dispose.calls).to.have.length(1)
  end)

  -- dispose.spec.ts:23
  it("dispose manually", function()
    local root = U.root()
    local dispose1 = spy.fn()
    local dispose2 = root:effect(function()
      return dispose1
    end)
    expect(root.fiber:getEffects()).to.deep.equal({
      { label = "anonymous", children = {} },
    })
    expect(dispose1.calls).to.have.length(0)
    dispose2()
    expect(dispose1.calls).to.have.length(1)
    dispose2()
    expect(dispose1.calls).to.have.length(1)
  end)

  -- dispose.spec.ts:37
  it("yield dispose", function()
    local root = U.root()
    local seq = {}
    local dispose1 = spy.fn(pusher(seq, 1))
    local dispose2 = spy.fn(pusher(seq, 2))
    local dispose3 = spy.fn(pusher(seq, 3))
    local dispose = root:effect(cordis.iter(function(yield)
      yield(dispose1)
      yield(root:on("custom-event", function() end))
      yield(dispose2)
      yield(root:effect(cordis.iter(function(yield2)
        yield2(root:on("custom-event", function() end))
        yield2(dispose3)
      end)))
    end))
    root:on("custom-event", function() end)
    expect(root.fiber:getEffects()).to.deep.equal({
      {
        label = "anonymous",
        children = {
          -- only root level anonymous effects are included
          { label = 'ctx.on("custom-event")', children = {} },
          {
            label = "anonymous",
            children = {
              { label = 'ctx.on("custom-event")', children = {} },
            },
          },
        },
      },
      { label = 'ctx.on("custom-event")', children = {} },
    })
    expect(seq).to.deep.equal({})
    dispose()
    expect(seq).to.deep.equal({ 3, 2, 1 })
    dispose()
    expect(seq).to.deep.equal({ 3, 2, 1 })
  end)

  -- dispose.spec.ts:76
  it(
    "async return 1",
    withTimers(function(root)
      local seq = {}
      local dispose = root:effect(cordis.async(function()
        sleep(100)
        seq[#seq + 1] = 1
        return pusher(seq, 2)
      end))
      expect(seq).to.deep.equal({})
      advance(100)
      expect(seq).to.deep.equal({ 1 })
      cordis.await(dispose())
      expect(seq).to.deep.equal({ 1, 2 })
    end)
  )

  -- dispose.spec.ts:90
  it(
    "async return 2",
    withTimers(function(root)
      local seq = {}
      local dispose = root:effect(cordis.async(function()
        sleep(100)
        seq[#seq + 1] = 1
        return pusher(seq, 2)
      end))
      dispose()
      expect(seq).to.deep.equal({})
      advance(100)
      expect(seq).to.deep.equal({ 1, 2 })
    end)
  )

  local function threeSteps(seq)
    return cordis.asyncIter(function(yield)
      sleep(100)
      seq[#seq + 1] = 1
      yield(pusher(seq, 2))
      sleep(100)
      seq[#seq + 1] = 3
      yield(pusher(seq, 4))
      sleep(100)
      seq[#seq + 1] = 5
      yield(pusher(seq, 6))
    end)
  end

  -- dispose.spec.ts:103
  it(
    "async yield 1",
    withTimers(function(root)
      local seq = {}
      local dispose = root:effect(threeSteps(seq))
      expect(seq).to.deep.equal({})
      advance(300)
      expect(seq).to.deep.equal({ 1, 3, 5 })
      cordis.await(dispose())
      expect(seq).to.deep.equal({ 1, 3, 5, 6, 4, 2 })
    end)
  )

  -- dispose.spec.ts:123
  it(
    "async yield 2 (aborted)",
    withTimers(function(root)
      local seq = {}
      local dispose = root:effect(threeSteps(seq))
      advance(50)
      dispose()
      expect(seq).to.deep.equal({})
      advance(300)
      expect(seq).to.deep.equal({ 1, 2 })
    end)
  )

  -- dispose.spec.ts:143
  it(
    "async yield 3 (aborted)",
    withTimers(function(root)
      local seq = {}
      local dispose = root:effect(threeSteps(seq))
      expect(seq).to.deep.equal({})
      advance(100)
      expect(seq).to.deep.equal({ 1 })
      dispose()
      expect(seq).to.deep.equal({ 1 })
      advance(200)
      expect(seq).to.deep.equal({ 1, 3, 4, 2 })
    end)
  )

  -- dispose.spec.ts:165 (`finally` is a `<close>` variable)
  it(
    "async yield (aborted, finally)",
    withTimers(function(root)
      local seq = {}
      local dispose = root:effect(cordis.asyncIter(function(yield)
        local _ <close> = setmetatable({}, {
          __close = function()
            seq[#seq + 1] = 0
          end,
        })
        yield(pusher(seq, 1))
        sleep(100)
        yield(pusher(seq, 2))
        sleep(100)
        yield(pusher(seq, 3))
      end))
      advance(50)
      local disposing = dispose()
      advance(100)
      cordis.await(disposing)
      expect(seq).to.deep.equal({ 0, 2, 1 })
    end)
  )

  -- dispose.spec.ts:185
  it(
    "async yield 4 (await dispose)",
    withTimers(function(root)
      local seq = {}
      local dispose = root:effect(threeSteps(seq))
      expect(seq).to.deep.equal({})
      local host = U.host()
      local all = cordis.Future.all(host, {
        cordis.async(function()
          return dispose:await()
        end)(),
        cordis.async(function()
          advance(300)
        end)(),
      })
      local dispose2 = all:await()[1]
      expect(seq).to.deep.equal({ 1, 3, 5 })
      cordis.await(dispose2())
      expect(seq).to.deep.equal({ 1, 3, 5, 6, 4, 2 })
    end)
  )

  -- dispose.spec.ts:205
  it("return with error", function()
    local root = U.root()
    local seq = {}
    expect(function()
      root:effect(function()
        error(cordis.Error.new("test"))
      end)
    end).to.throw("test")
    expect(seq).to.deep.equal({})
  end)

  -- dispose.spec.ts:217
  it("yield with error", function()
    local root = U.root()
    local seq = {}
    expect(function()
      root:effect(cordis.iter(function(yield)
        yield(pusher(seq, 1))
        error(cordis.Error.new("test"))
      end))
    end).to.throw("test")
    expect(seq).to.deep.equal({ 1 })
  end)

  -- dispose.spec.ts:230
  it("async return with error", function()
    local root = U.root()
    local seq = {}
    local dispose = root:effect(cordis.async(function()
      error(cordis.Error.new("test"))
    end))
    expect(seq).to.deep.equal({})
    expect(dispose).to.reject()
    expect(seq).to.deep.equal({})
  end)

  -- dispose.spec.ts:242
  it("async yield with error", function()
    local root = U.root()
    local seq = {}
    local dispose = root:effect(cordis.asyncIter(function(yield)
      yield(pusher(seq, 1))
      error(cordis.Error.new("test"))
    end))
    expect(seq).to.deep.equal({})
    local ok, caught = pcall(cordis.await, dispose)
    expect(ok).to.equal(false)
    expect(caught).to.be.instanceof(cordis.Error)
    expect(seq).to.deep.equal({ 1 })
  end)

  -- dispose.spec.ts:261
  it("async yield invalid effect", function()
    local root = U.root()
    local seq = {}
    local dispose = root:effect(cordis.asyncIter(function(yield)
      local _ <close> = setmetatable({}, {
        __close = function()
          seq[#seq + 1] = 0
        end,
      })
      yield(pusher(seq, 1))
      yield(1)
    end))
    local ok, caught = pcall(cordis.await, dispose)
    expect(ok).to.equal(false)
    expect(caught).to.be.instanceof(cordis.TypeError)
    expect(seq).to.deep.equal({ 0, 1 })
  end)
end)
