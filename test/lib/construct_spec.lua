-- Library-own tests: the constructor entry. `new` is an ordinary field of a class
-- table, so a class may define a method named `new` (a service contract may require one). The
-- library constructs components through `class.construct`, never through `cls.new`, so such a
-- class is still constructed as a component.
local cordis = require("cordis")
local U = require("kit.util")
local withTimers = U.withTimers
local FiberState = cordis.FiberState

describe("class.construct", function()
  it(
    "a component class with a method named `new` is constructed, its method kept",
    withTimers(function(root)
      local constructed, called = 0, nil
      local Session = cordis.class("Session", cordis.Service)
      function Session:constructor(ctx)
        cordis.Service.constructor(self, ctx, "session")
        constructed = constructed + 1
      end
      function Session:new(label)
        called = label
        return "made " .. label
      end
      local fiber = root:plugin(Session)
      U.runAll()
      expect(fiber.state).to.equal(FiberState.ACTIVE)
      expect(constructed).to.equal(1)
      local session = root:get("session")
      expect(session:new("x")).to.equal("made x")
      expect(called).to.equal("x")
    end)
  )

  it("construct builds an instance as Class.new does when nothing shadows it", function()
    local Foo = cordis.class("Foo")
    function Foo:constructor(v)
      self.v = v
    end
    local a = require("cordis.class").construct(Foo, 1)
    expect(a.v).to.equal(1)
    expect(Foo.is(a)).to.equal(true)
  end)
end)
