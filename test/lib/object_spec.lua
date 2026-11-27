-- Library-own tests: cordis.class and cordis.proto.
local cordis = require("cordis")
local proto = cordis.proto

describe("class", function()
  it("inherits methods, statics, getters and metamethods", function()
    local A = cordis.class("A")
    A.kind = "a"
    function A:constructor(x)
      self.x = x
    end
    function A:double()
      return self.x * 2
    end
    A.__get.triple = function(self)
      return self.x * 3
    end
    A.__tostring = function(self)
      return "A(" .. self.x .. ")"
    end
    local B = cordis.class("B", A)
    function B:constructor(x)
      B.super.constructor(self, x + 1)
    end
    local b = B.new(1)
    expect(b.x).to.equal(2)
    expect(b:double()).to.equal(4)
    expect(b.triple).to.equal(6)
    expect(b.kind).to.equal("a")
    expect(tostring(b)).to.equal("A(2)")
    expect(A.is(b)).to.equal(true)
    expect(B.is(A.new(1))).to.equal(false)
    expect(cordis.class.is(B)).to.equal(true)
    expect(cordis.class.is(b)).to.equal(false)
  end)

  it("a constructor may return a replacement object", function()
    local A = cordis.class("A")
    local other = {}
    function A:constructor()
      return other
    end
    expect(A.new()).to.equal(other)
  end)
end)

describe("proto", function()
  it("reads through the prototype chain and writes own keys", function()
    local base = proto.create(nil, { a = 1 })
    local child = proto.create(base)
    expect(child.a).to.equal(1)
    child.a = 2
    expect(base.a).to.equal(1)
    expect(proto.hasOwn(child, "a")).to.equal(true)
    expect(proto.has(child, "b")).to.equal(false)
    expect(rawget(child, "a")).to.equal(nil)
  end)

  it("keeps own keys in insertion order and enumerates like for..in", function()
    local base = proto.create()
    base.z = 1
    base.y = 2
    local child = proto.create(base)
    child.b = 1
    child.a = 2
    child.y = 3
    expect(proto.ownKeys(child)).to.deep.equal({ "b", "a", "y" })
    expect(proto.keys(child)).to.deep.equal({ "b", "a", "y", "z" })
  end)

  it("re-parents with setPrototypeOf", function()
    local p1, p2 = proto.create(nil, { v = 1 }), proto.create(nil, { v = 2 })
    local o = proto.create(p1)
    proto.setPrototypeOf(o, p2)
    expect(o.v).to.equal(2)
    expect(proto.getPrototypeOf(o)).to.equal(p2)
  end)

  it("proxies trap get, set, has and apply with the receiver", function()
    local log = {}
    local target = { x = 1 }
    local p = proto.proxy(target, {
      get = function(t, k, receiver)
        log[#log + 1] = receiver
        return t[k]
      end,
      set = function(t, k, v)
        t[k] = v * 10
        return true
      end,
      apply = function(_, _, a, b)
        return a + b
      end,
    })
    local child = proto.create(p)
    expect(child.x).to.equal(1)
    expect(log[1]).to.equal(child)
    p.y = 2
    expect(target.y).to.equal(20)
    expect(p(1, 2)).to.equal(3)
  end)

  it("class getters receive the receiver through a chain", function()
    local A = cordis.class("A")
    A.__get.me = function(self)
      return self
    end
    local a = A.new()
    local child = proto.create(a)
    expect(child.me).to.equal(child)
  end)

  it("rejects prototype cycles in setPrototypeOf without mutating state", function()
    local a = proto.create(nil, { v = 1 })
    local b = proto.create(a, { w = 2 })
    expect(function()
      proto.setPrototypeOf(a, a)
    end).to.throw("Cyclic __proto__ value")
    expect(function()
      proto.setPrototypeOf(a, b)
    end).to.throw("Cyclic __proto__ value")
    local p = proto.proxy(a, {})
    expect(function()
      proto.setPrototypeOf(a, p)
    end).to.throw("Cyclic __proto__ value")
    expect(proto.getPrototypeOf(a)).to.equal(nil)
    expect(b.missing).to.equal(nil)
  end)
end)
