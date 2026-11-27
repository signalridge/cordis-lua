-- Library-own tests: insertion-ordered Map / Set.
local ordered = require("cordis.ordered")
local Map, Set = ordered.Map, ordered.Set

describe("ordered", function()
  it("iterates in insertion order", function()
    local m = Map.new()
    for _, k in ipairs({ "c", "a", "b" }) do
      m:set(k, k:upper())
    end
    m:set("a", "A2")
    expect(m:keys()).to.deep.equal({ "c", "a", "b" })
    expect(m:values()).to.deep.equal({ "C", "A2", "B" })
    expect(m:size()).to.equal(3)
  end)

  it("skips entries deleted during iteration", function()
    local m = Map.new()
    for i = 1, 5 do
      m:set(i, true)
    end
    local seen = {}
    for k in m:pairs() do
      seen[#seen + 1] = k
      if k == 2 then
        m:delete(3)
        m:delete(2)
      end
    end
    expect(seen).to.deep.equal({ 1, 2, 4, 5 })
  end)

  it("visits entries added during iteration", function()
    local s = Set.new({ 1, 2 })
    local seen = {}
    for v in s:pairs() do
      seen[#seen + 1] = v
      if v == 2 then
        s:delete(2)
        s:add(3)
      end
    end
    expect(seen).to.deep.equal({ 1, 2, 3 })
  end)

  it("re-adding a deleted key appends it", function()
    local s = Set.new({ "a", "b", "c" })
    s:delete("a")
    s:add("a")
    expect(s:values()).to.deep.equal({ "b", "c", "a" })
    s:clear()
    expect(s:size()).to.equal(0)
    expect(s:values()).to.deep.equal({})
  end)

  it("preserves indices in Map:values() when an entry stores nil", function()
    local m = Map.new()
    m:set("a", 1)
    m:set("b", nil)
    m:set("c", 2)
    local vals = m:values()
    expect(vals[1]).to.equal(1)
    expect(vals[2]).to.equal(nil)
    expect(vals[3]).to.equal(2)
  end)
end)
