-- Ported from cordis packages/core/tests/utils.spec.ts (MIT, (c) Shigma)
local cordis = require("cordis")
local DisposableList = cordis.DisposableList

local function list(l)
  return l:values()
end

describe("DisposableList", function()
  local a = { name = "a" }
  local b = { name = "b" }
  local c = { name = "c" }
  local d = { name = "d" }

  -- utils.spec.ts:10
  it("iterates unshifted entries before pushed ones", function()
    local l = DisposableList.new()
    l:push(a)
    l:unshift(b)
    l:push(c)
    l:unshift(d)
    expect(list(l)).to.deep.equal({ d, b, a, c })
    expect(l:length()).to.equal(4)
  end)

  -- utils.spec.ts:20
  it("disposer removes its own entry after a later push", function()
    local l = DisposableList.new()
    local disposeA = l:push(a)
    local disposeB = l:push(b)

    disposeA()
    expect(list(l)).to.deep.equal({ b })

    disposeB()
    expect(list(l)).to.deep.equal({})
  end)

  -- utils.spec.ts:32
  it("disposer removes its own entry after a later unshift", function()
    local l = DisposableList.new()
    local disposeA = l:unshift(a)
    local disposeB = l:unshift(b)

    disposeA()
    expect(list(l)).to.deep.equal({ b })

    disposeB()
    expect(list(l)).to.deep.equal({})
  end)

  -- utils.spec.ts:44
  it("delete removes the entry it was given", function()
    local l = DisposableList.new()
    l:push(a)
    l:push(b)

    expect(l:delete(a)).to.equal(true)
    expect(list(l)).to.deep.equal({ b })
    expect(l:delete(a)).to.equal(false)
  end)

  -- utils.spec.ts:54
  it("delete removes an unshifted entry", function()
    local l = DisposableList.new()
    l:push(a)
    l:unshift(b)

    expect(l:delete(b)).to.equal(true)
    expect(list(l)).to.deep.equal({ a })
    expect(l:delete(b)).to.equal(false)
  end)

  -- utils.spec.ts:64
  it("clear removes every entry and returns them in order", function()
    local l = DisposableList.new()
    l:push(a)
    l:unshift(b)

    expect(l:clear()).to.deep.equal({ b, a })
    expect(list(l)).to.deep.equal({})
    expect(l:length()).to.equal(0)
  end)
end)
