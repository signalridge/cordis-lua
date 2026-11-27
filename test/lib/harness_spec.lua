-- Library-own tests: the test harness itself (before_all sharing).
local U = require("kit.util")

local first
describe("before_all", function()
  local state = {}
  before_all(function()
    state.host = U.host()
    state.count = (state.count or 0) + 1
  end)

  it("runs once before the first test", function()
    expect(state.count).to.equal(1)
    expect(U.host()).to.equal(state.host)
    first = U.sched()
  end)

  it("shares the scheduler with later tests", function()
    expect(state.count).to.equal(1)
    expect(U.sched()).to.equal(first)
  end)
end)

describe("without before_all", function()
  it("gets a fresh scheduler", function()
    expect(U.sched() == first).to.equal(false)
  end)
end)
