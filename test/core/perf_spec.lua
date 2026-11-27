-- Library-own tests: ReflectService:notify skips the walk over every fiber
-- when no fiber injects the notified names. What the
-- fibers see is unchanged; these cases pin it down around the index.
local cordis = require("cordis")
local U = require("kit.util")
local DisposableList = require("cordis.list").DisposableList or require("cordis.list")

local FiberState = cordis.FiberState

local function countValues(fn)
  local values = DisposableList.values
  local n = 0
  DisposableList.values = function(...)
    n = n + 1
    return values(...)
  end
  local ok, err = pcall(fn)
  DisposableList.values = values
  if not ok then
    error(err, 0)
  end
  return n
end

describe("reflect notify", function()
  it("does not walk the fibers for a service nobody injects", function()
    local root = U.root()
    for i = 1, 30 do
      cordis.await(root:plugin({ name = "p" .. i, apply = function() end }))
    end
    local walks = countValues(function()
      root:provide("lonely", { v = 1 })
      root.lonely = { v = 2 }
    end)
    expect(walks).to.equal(0)
  end)

  it("still starts a consumer of the service, and keeps it on a new value", function()
    local root = U.root()
    for i = 1, 5 do
      cordis.await(root:plugin({ name = "p" .. i, apply = function() end }))
    end
    local seen = {}
    local consumer = root:plugin({
      name = "consumer",
      inject = { "svc" },
      apply = function(ctx)
        seen[#seen + 1] = ctx.svc.v
      end,
    })
    U.sleep(0)
    expect(consumer.state).to.equal(FiberState.PENDING)
    root:provide("svc")
    root.svc = { v = 1 }
    U.sleep(0)
    expect(consumer.state).to.equal(FiberState.ACTIVE)
    root.svc = { v = 2 }
    U.sleep(0)
    expect(table.concat(seen, ",")).to.equal("1")
    expect(consumer.state).to.equal(FiberState.ACTIVE)
  end)

  it("notifies a fiber whose inject gained the name through replace", function()
    local root = U.root()
    local seen = 0
    local v1 = { name = "late", apply = function() end }
    local v2 = {
      name = "late",
      inject = { "svc2" },
      apply = function(ctx)
        seen = seen + (ctx.svc2 and 1 or 0)
      end,
    }
    local fiber = root:plugin(v1)
    cordis.await(fiber)
    root.registry:replace(v1, v2)
    U.sleep(0)
    expect(fiber.state).to.equal(FiberState.PENDING)
    root:provide("svc2")
    root.svc2 = {}
    U.sleep(0)
    expect(fiber.state).to.equal(FiberState.ACTIVE)
    expect(seen).to.equal(1)
  end)

  it("no longer notifies a disposed consumer", function()
    local root = U.root()
    local applied = 0
    local consumer = root:plugin({
      name = "c",
      inject = { "svc3" },
      apply = function()
        applied = applied + 1
      end,
    })
    root:provide("svc3")
    root.svc3 = {}
    U.sleep(0)
    expect(applied).to.equal(1)
    cordis.await(consumer:dispose())
    root.svc3 = { again = true }
    U.sleep(0)
    expect(applied).to.equal(1)
    expect(consumer.state).to.equal(FiberState.DISPOSED)
  end)

  it("skips unrelated runtimes per-runtime during notify", function()
    local root = U.root()
    local injectIndex = require("cordis.inject_index")
    for i = 1, 50 do
      cordis.await(root:plugin({ name = "u" .. i, apply = function() end }))
    end
    local seen = 0
    cordis.await(root:plugin({
      name = "consumer",
      inject = { "perRuntimeSvc" },
      apply = function()
        seen = seen + 1
      end,
    }))

    local injectsCalls = 0
    local origInjects = injectIndex.injects
    injectIndex.injects = function(...)
      injectsCalls = injectsCalls + 1
      return origInjects(...)
    end
    local walks = countValues(function()
      root:provide("perRuntimeSvc", { v = 1 })
    end)
    injectIndex.injects = origInjects
    U.sleep(0)
    expect(walks).to.equal(1)
    expect(injectsCalls).to.equal(1)
    expect(seen).to.equal(1)
  end)

  it("skips runtimes in another root even when the first root has a consumer", function()
    local rootA = U.root()
    local rootB = U.root()
    cordis.await(rootA:plugin({ name = "cA", inject = { "sharedName" }, apply = function() end }))
    for i = 1, 20 do
      cordis.await(rootB:plugin({ name = "b" .. i, apply = function() end }))
    end
    local walks = countValues(function()
      rootB:provide("sharedName", { v = 1 })
    end)
    expect(walks).to.equal(0)
  end)

  it("updates per-runtime index on replace and supports dynamic inject", function()
    local root = U.root()
    local c1 = { name = "c1", inject = { "svcR1" }, apply = function() end }
    local c2 = { name = "c2", inject = { "svcR2" }, apply = function() end }
    local fiber = cordis.await(root:plugin(c1))
    root.registry:replace(c1, c2)
    U.sleep(0)

    expect(countValues(function()
      root:provide("svcR1", {})
    end)).to.equal(0)
    expect(countValues(function()
      root:provide("svcR2", {})
    end)).to.equal(1)
    U.sleep(0)
    expect(fiber.state).to.equal(FiberState.ACTIVE)

    -- truly unindexable inject (plain table with metatable) goes to always bucket
    local injectIndex = require("cordis.inject_index")
    local dynSeen = 0
    local dynFiber = cordis.await(root:plugin({
      name = "dyn",
      apply = function()
        dynSeen = dynSeen + 1
      end,
    }))
    dynSeen = 0
    local unindexable = setmetatable({ dynSvc = cordis.null }, {})
    dynFiber:_replace(dynFiber.runtime, unindexable)
    U.sleep(0)
    expect(dynFiber.state).to.equal(FiberState.PENDING)
    expect(injectIndex.anyIn(dynFiber.runtime, { "unrelatedName" })).to.equal(true)
    root:provide("dynSvc", {})
    U.sleep(0)
    expect(dynFiber.state).to.equal(FiberState.ACTIVE)
    expect(dynSeen).to.equal(1)
  end)

  it("handles re-entrant dispose of a later runtime during notify and keeps internal/service order", function()
    local root = U.root()
    local fiber2
    local fiber1 = root:plugin({
      name = "first",
      inject = { "svcReent" },
      apply = function() end,
    })
    local f2Applied = 0
    fiber2 = root:plugin({
      name = "second",
      inject = { "svcReent" },
      apply = function()
        f2Applied = f2Applied + 1
      end,
    })
    root:on("internal/status", function(f)
      if f == fiber1 and f.state == FiberState.LOADING then
        fiber2:dispose()
      end
    end)
    local events = {}
    root:on("internal/service", function(_, name)
      events[#events + 1] = name
    end)
    root:provide("svcReent", { ok = true })
    cordis.await(fiber1)
    expect(fiber1.state).to.equal(FiberState.ACTIVE)
    expect(fiber2.state).to.equal(FiberState.DISPOSED)
    expect(f2Applied).to.equal(0)
    expect(events[#events]).to.equal("svcReent")
    -- disposing a second service in a single notify preserves name order
    local order = {}
    root:on("internal/service", function(_, name)
      order[#order + 1] = name
    end)
    root.reflect:notify({ "a", "b", "c" })
    expect(order).to.deep.equal({ "a", "b", "c" })
  end)
end)

describe("fiber refresh epoch", function()
  it("produces exact epoch strings for 0, 1, and many dependencies and exits early on missing", function()
    local root = U.root()
    local f0 = cordis.await(root:plugin({ name = "d0", apply = function() end }))
    expect(f0._runner.epoch).to.equal("0")

    root:provide("depA", { a = 1 })
    local f1 = cordis.await(root:plugin({ name = "d1", inject = { "depA" }, apply = function() end }))
    local uidA = root.reflect:getImpl("depA", true).uid
    expect(f1._runner.epoch).to.equal("0:" .. uidA)

    local injectMany = {}
    local uids = { "0" }
    for i = 1, 16 do
      local name = "depM" .. i
      injectMany[i] = name
      if i > 1 then
        root:provide(name, { i = i })
      end
      local impl = root.reflect:getImpl(i == 1 and "depA" or name, true)
      if i == 1 then
        injectMany[i] = "depA"
      end
      uids[#uids + 1] = tostring(impl.uid)
    end
    local fMany = cordis.await(root:plugin({ name = "dMany", inject = injectMany, apply = function() end }))
    expect(fMany._runner.epoch).to.equal(table.concat(uids, ":"))

    local fMissing = root:plugin({ name = "dMiss", inject = { "depA", "missingSvc" }, apply = function() end })
    U.sleep(0)
    expect(fMissing.state).to.equal(FiberState.PENDING)
    expect(fMissing._runner.epoch).to.equal("__INACTIVE__")
  end)

  it("keeps multi-dependency _refresh epoch isolated under re-entrant _refresh", function()
    local root = U.root()
    root:provide("rDep1", { v = 1 })
    root:provide("rDep2", { v = 2 })
    root:provide("rDep3", { v = 3 })
    root:provide("rDep4", { v = 4 })

    local aRuns = 0
    local fiberA = cordis.await(root:plugin({
      name = "fiberA",
      inject = { "rDep1", "rDep2" },
      apply = function()
        aRuns = aRuns + 1
      end,
    }))
    local fiberB = cordis.await(root:plugin({
      name = "fiberB",
      inject = { "rDep3", "rDep4" },
      apply = function() end,
    }))
    local expectedEpoch = fiberA._runner.epoch
    local uid3 = root.reflect:getImpl("rDep3", true).uid
    local uid4 = root.reflect:getImpl("rDep4", true).uid

    -- re-enter fiberB:_refresh() during fiberA's second dependency lookup
    -- (after parts[1] and parts[2] are populated, before table.concat)
    local reentered = false
    local lookups = 0
    local origStore = fiberA._store
    fiberA._store = cordis.proto.proxy(origStore, {
      get = function(target, k, receiver)
        lookups = lookups + 1
        if lookups == 2 and not reentered then
          reentered = true
          fiberB._revision = fiberB._revision + 1
          fiberB:_refresh()
        end
        return cordis.proto.get(target, k, receiver)
      end,
    })
    fiberA:_refresh()
    fiberA._store = origStore
    U.sleep(0)
    expect(reentered).to.equal(true)
    expect(fiberA._runner.epoch).to.equal(expectedEpoch)
    expect(fiberB._runner.epoch).to.equal("1:" .. uid3 .. ":" .. uid4)
    expect(aRuns).to.equal(1)
  end)
end)

describe("events snapshot and parallel single-pass", function()
  it("invalidates cached unfiltered snapshots on add/remove and internal/dispatch edits", function()
    local root = U.root()
    local seen = {}
    local off1 = root:on("snap", function(v)
      seen[#seen + 1] = "1:" .. v
    end)
    root:emit("snap", "a")
    local off2 = root:on("snap", function(v)
      seen[#seen + 1] = "2:" .. v
    end)
    root:emit("snap", "b")
    off1()
    root:emit("snap", "c")
    off2()
    root:emit("snap", "d")
    expect(seen).to.deep.equal({ "1:a", "1:b", "2:b", "2:c" })

    -- internal/dispatch adding/removing listeners takes effect in the current dispatch
    local dispatchSeen = {}
    local targetOff
    targetOff = root:on("dispEv", function()
      dispatchSeen[#dispatchSeen + 1] = "initial"
    end)
    local dispOff = root:on("internal/dispatch", function(_, name)
      if name == "dispEv" then
        if targetOff then
          targetOff()
          targetOff = nil
        end
        root:on("dispEv", function()
          dispatchSeen[#dispatchSeen + 1] = "added-by-dispatch"
        end)
      end
    end)
    root:emit("dispEv")
    dispOff()
    expect(dispatchSeen).to.deep.equal({ "added-by-dispatch" })
  end)

  it("handles recursive emit with listener mutation without corrupting outer iteration", function()
    local root = U.root()
    local log = {}
    local nested = false
    local off2
    root:on("rec", function(tag)
      log[#log + 1] = "L1:" .. tag
      if not nested then
        nested = true
        off2()
        root:on("rec", function(t)
          log[#log + 1] = "L3:" .. t
        end)
        root:emit("rec", "inner")
      end
    end)
    off2 = root:on("rec", function(tag)
      log[#log + 1] = "L2:" .. tag
    end)
    root:emit("rec", "outer")
    -- outer iteration still skips L2 (removed) and defers L3; inner iteration sees L3
    expect(log).to.deep.equal({ "L1:outer", "L1:inner", "L3:inner" })
  end)

  it("parallel single-pass handles removed hooks and nil rejections as cordis.null", function()
    local root = U.root()
    local offRemoved
    root:on("parEdge", function()
      offRemoved()
      return cordis.Future.reject(root.host, nil)
    end)
    offRemoved = root:on("parEdge", function()
      error(cordis.Error.new("should not run"))
    end)
    root:on("parEdge", function()
      error("second-err", 0)
    end)
    local ok, err = pcall(function()
      cordis.await(root:parallel("parEdge"))
    end)
    expect(ok).to.equal(false)
    expect(cordis.AggregateError.is(err)).to.equal(true)
    expect(#err.errors).to.equal(2)
    expect(err.errors[1]).to.equal(cordis.null)
    expect(err.errors[2]).to.equal("second-err")
  end)

  it("returns independent hook arrays from EventsService:resolve", function()
    local rootA = U.root()
    local rootB = U.root()
    local callsA, callsB = 0, 0
    rootA:on("mut", function()
      callsA = callsA + 1
    end)
    rootB:on("other", function()
      callsB = callsB + 1
    end)

    -- mutating a non-empty resolve result must not corrupt the cached snapshot
    local _, hooks = rootA.events:resolve("emit", "mut")
    hooks[1] = nil
    hooks[2] = { callback = function() end, ctx = rootA }
    rootA:emit("mut")
    expect(callsA).to.equal(1)

    -- mutating an empty resolve result must not leak to another event or root
    local _, emptyHooks = rootA.events:resolve("emit", "missing")
    emptyHooks[1] = {
      ctx = rootA,
      callback = function()
        error("leaked")
      end,
    }
    rootA:emit("missing")
    rootB:emit("missing")
    rootB:emit("other")
    expect(callsB).to.equal(1)
  end)
end)

describe("traceable cache", function()
  it("gives one proxy per service and reading context", function()
    local root = U.root()
    local Svc = cordis.class("PerfSvc", cordis.Service)
    function Svc:constructor(ctx)
      cordis.Service.constructor(self, ctx, "perfsvc")
    end
    function Svc:who()
      return self.ctx
    end
    root:plugin(Svc)
    U.sleep(0)
    local first, second, caller
    cordis.await(root:plugin({
      name = "reader",
      inject = { "perfsvc" },
      apply = function(ctx)
        first = ctx.perfsvc
        second = ctx.perfsvc
        caller = ctx.perfsvc:who()
      end,
    }))
    expect(rawequal(first, second)).to.equal(true)
    -- the method still runs with the caller's context (shadow), as before
    expect(caller ~= nil).to.equal(true)
  end)
end)

describe("traced method shadow cache", function()
  -- the caller / shadow semantics of traced methods are pinned by
  -- test/core/shadow_spec.lua; these cases cover the cache itself
  local function setup()
    local root = U.root()
    local instance
    local Svc = cordis.class("P4Svc", cordis.Service)
    function Svc:constructor(ctx)
      cordis.Service.constructor(self, ctx, "p4svc")
      instance = self
      self.n = 0
    end
    function Svc:who()
      return "who"
    end
    function Svc:inc()
      self.n = self.n + 1
      return self.n
    end
    cordis.await(root:use(Svc))
    return root, function()
      return instance
    end
  end

  it("gives one method per service proxy and name", function()
    local root = setup()
    local a, b
    cordis.await(root:inject({ "p4svc" }, function(ctx)
      a = ctx.p4svc.who
      b = ctx.p4svc.who
    end))
    expect(rawequal(a, b)).to.equal(true)
  end)

  it("keeps the service's state across calls from several readers", function()
    local root = setup()
    local seen = {}
    for i = 1, 2 do
      cordis.await(root:plugin({
        name = "reader" .. i,
        inject = { "p4svc" },
        apply = function(ctx)
          seen[#seen + 1] = ctx.p4svc:inc()
          seen[#seen + 1] = ctx.p4svc:inc()
        end,
      }))
    end
    expect(table.concat(seen, ",")).to.equal("1,2,3,4")
  end)

  it("runs a method replaced on the service", function()
    local root, instance = setup()
    local results = {}
    cordis.await(root:inject({ "p4svc" }, function(ctx)
      results[#results + 1] = ctx.p4svc:inc()
      rawset(instance(), "inc", function()
        return "replaced"
      end)
      results[#results + 1] = ctx.p4svc:inc()
    end))
    expect(results[1]).to.equal(1)
    expect(results[2]).to.equal("replaced")
  end)
end)

describe("hot paths", function()
  local R = require("cordis.reflect")
  -- the definition before the property lookup optimization, the reference
  local function reference(prop)
    if type(prop) ~= "string" then
      return true
    end
    if prop:sub(1, 1) == "_" then
      return true
    end
    local n = math.tointeger(tonumber(prop))
    return n ~= nil and tostring(n) == prop
  end

  it("isSpecialProperty answers as the reference for every first byte and edge case", function()
    local cases = {
      "",
      "_",
      "_x",
      "a",
      "0",
      "1",
      "12",
      "-1",
      "+1",
      " 1",
      "1 ",
      "01",
      "1.0",
      "1e2",
      "0x10",
      "-0",
      ".5",
      "\t5",
      "x_y",
      1,
      true,
    }
    for i = 0, 255 do
      cases[#cases + 1] = string.char(i)
      cases[#cases + 1] = string.char(i) .. "1"
    end
    for _, c in ipairs(cases) do
      expect(R.isSpecialProperty(c)).to.equal(reference(c))
    end
  end)

  it("proto.get finds own, inherited and proxied values as before", function()
    local proto = cordis.proto
    local a = proto.create(nil)
    a.x = 1
    local b = proto.create(a)
    b.y = 2
    local c = proto.create(b)
    local p = proto.proxy(c, {})
    expect(proto.get(c, "x")).to.equal(1)
    expect(proto.get(c, "y")).to.equal(2)
    expect(proto.get(c, "z")).to.equal(nil)
    expect(proto.get(p, "x")).to.equal(1)
    c.x = 3
    expect(proto.get(c, "x")).to.equal(3)
    expect(proto.has(c, "y")).to.equal(true)
    expect(proto.hasOwn(c, "y")).to.equal(false)
  end)

  it("reads a plain object's own values after its keys are deleted or promoted", function()
    local proto = cordis.proto
    local o = proto.create(nil)
    o.x = 1
    expect(proto.delete(o, "x")).to.equal(true)
    expect(proto.get(o, "x")).to.equal(nil)
    expect(proto.hasOwn(o, "x")).to.equal(false)
    o.y = 2
    o.z = 3
    expect(proto.get(o, "y")).to.equal(2)
    expect(proto.has(o, "y")).to.equal(true)
    expect(proto.hasOwn(o, "y")).to.equal(true)
    expect(proto.delete(o, "y")).to.equal(true)
    expect(proto.get(o, "y")).to.equal(nil)
    expect(proto.get(o, "z")).to.equal(3)
  end)
end)

describe("context read cache", function()
  local proto = cordis.proto
  local S = cordis.symbols

  -- the object behind a reader's context proxy: an own property there is seen by the read
  local function proxyTarget(ctx)
    local o = ctx
    while not proto._state[o].handler do
      o = proto._state[o].proto
    end
    return proto._state[o].target
  end

  local function reader(root, name)
    return cordis.await(root:inject({ name }, function() end)).ctx
  end

  it("reads a provision's value set again directly on the reflect service", function()
    local root = U.root()
    root:provide("p6set", "one")
    local ctx = reader(root, "p6set")
    expect(ctx.p6set).to.equal("one")
    root.reflect:set("p6set", "two")
    expect(ctx.p6set).to.equal("two")
  end)

  -- a reader still registered keeps nothing of a provision that went away; the
  -- lookup reads the value from the provision each time
  it("follows the provider going away and a new provision, and keeps nothing of the old one", function()
    local root = U.root()
    local provider = cordis.await(root:plugin({
      name = "p6prov",
      apply = function(ctx)
        ctx:provide("p6gone", { name = "first" })
      end,
    }))
    local ctx = reader(root, "p6gone")
    local seen = setmetatable({}, { __mode = "v" })
    -- read in its own frame, so no register of this one holds the service
    local function remember()
      seen[1] = ctx.p6gone
      return seen[1].name
    end
    expect(remember()).to.equal("first")
    cordis.await(provider:dispose())
    provider = nil
    collectgarbage()
    collectgarbage()
    expect(seen[1]).to.equal(nil)
    local ok = pcall(function()
      return ctx.p6gone
    end)
    expect(ok).to.equal(false)
    root:provide("p6gone", "second")
    U.sleep(0)
    expect(ctx.p6gone).to.equal("second")
  end)

  it("sees an own property defined on the context chain after a read", function()
    local root = U.root()
    root:provide("p6own", "service")
    local ctx = reader(root, "p6own")
    expect(ctx.p6own).to.equal("service")
    proto.defineOwn(proxyTarget(ctx), "p6own", "own")
    expect(ctx.p6own).to.equal("own")
  end)

  -- only the plain lookup is remembered: a listener's answer is never reused once it is gone
  it("never remembers an internal/get listener's answer", function()
    local root = U.root()
    root:provide("p6hook", "real")
    local ctx = reader(root, "p6hook")
    local off = root:on("internal/get", function(_, name, _, next)
      if name == "p6hook" then
        return next() .. "!"
      end
      return next()
    end)
    expect(ctx.p6hook).to.equal("real!")
    off()
    expect(ctx.p6hook).to.equal("real")
  end)

  it("gives each reader the service of its own isolate", function()
    local root = U.root()
    local first, second = {}, {}
    cordis.await(root:isolate("p6iso", first):plugin({
      name = "a",
      apply = function(ctx)
        ctx:provide("p6iso", "first")
      end,
    }))
    cordis.await(root:isolate("p6iso", second):plugin({
      name = "b",
      apply = function(ctx)
        ctx:provide("p6iso", "second")
      end,
    }))
    local a = reader(root:isolate("p6iso", first), "p6iso")
    local b = reader(root:isolate("p6iso", second), "p6iso")
    for _ = 1, 2 do
      expect(a.p6iso).to.equal("first")
      expect(b.p6iso).to.equal("second")
    end
  end)

  it("still makes the traceable per read: a reader gets its own proxy of a traced service", function()
    local root = U.root()
    local Svc = cordis.class("P6Svc", cordis.Service)
    function Svc:constructor(ctx)
      cordis.Service.constructor(self, ctx, "p6svc")
    end
    function Svc:caller()
      return self.ctx
    end
    cordis.await(root:use(Svc))
    local a = reader(root, "p6svc")
    local b = reader(root, "p6svc")
    local first = a.p6svc
    expect(rawequal(a.p6svc, first)).to.equal(true)
    expect(rawequal(b.p6svc, first)).to.equal(false)
    expect(rawequal(a.p6svc:caller(), b.p6svc:caller())).to.equal(false)
  end)
end)

describe("trace fast paths", function()
  local proto = cordis.proto
  local S = cordis.symbols
  local trace = require("cordis.trace")

  it("traces a plain table and a class instance as the general path does", function()
    local tracker = { property = "ctx" }
    local ctx = U.root()
    local plain = { [S.tracker] = tracker }
    local traced = trace.getTraceable(ctx, plain)
    expect(rawequal(traced, plain)).to.equal(false)
    expect(rawequal(proto.get(traced, S.original), plain)).to.equal(true)
    local bare = {}
    expect(rawequal(trace.getTraceable(ctx, bare), bare)).to.equal(true)
    local shadowed = { [S.shadow] = true }
    expect(trace.getTraceable(ctx, shadowed)).to.equal(proto.getPrototypeOf(shadowed))
    -- a class instance whose tracker comes from its class (a getter here)
    local C = cordis.class("P7Traced")
    C.__get[S.tracker] = function()
      return tracker
    end
    local inst = C.new()
    local tracedInst = trace.getTraceable(ctx, inst)
    expect(rawequal(proto.get(tracedInst, S.original), inst)).to.equal(true)
    local D = cordis.class("P7Plain")
    local plainInst = D.new()
    expect(rawequal(trace.getTraceable(ctx, plainInst), plainInst)).to.equal(true)
  end)

  local function setup()
    local root = U.root()
    local instance
    local Svc = cordis.class("P7Svc", cordis.Service)
    function Svc:constructor(ctx)
      cordis.Service.constructor(self, ctx, "p7svc")
      instance = self
    end
    function Svc:who()
      return "class"
    end
    function Svc:site()
      return proto.get(self.ctx, S.shadow)
    end
    cordis.await(root:use(Svc))
    local ctx = cordis.await(root:inject({ "p7svc" }, function() end)).ctx
    return root, ctx, Svc, function()
      return instance
    end
  end

  it("runs a method replaced on the class", function()
    local _, ctx, Svc = setup()
    expect(ctx.p7svc:who()).to.equal("class")
    Svc.who = function()
      return "replaced"
    end
    expect(ctx.p7svc:who()).to.equal("replaced")
  end)

  it("reads a getter added on the class for a method name", function()
    local _, ctx, Svc = setup()
    expect(ctx.p7svc:who()).to.equal("class")
    Svc.__get.who = function()
      return function()
        return "getter"
      end
    end
    expect(ctx.p7svc:who()).to.equal("getter")
  end)

  it("gives a method the def site the service carries now", function()
    local root, ctx, _, instance = setup()
    local before = ctx.p7svc:site()
    local other = root:extend({})
    rawset(instance(), "ctx", other)
    local after = ctx.p7svc:site()
    expect(rawequal(before, after)).to.equal(false)
    expect(rawequal(after, other)).to.equal(true)
  end)

  it("reads an associated accessor declared after the method was read", function()
    local root, ctx = setup()
    expect(ctx.p7svc:who()).to.equal("class")
    root.reflect:accessor("p7svc.who", {
      get = function()
        return function()
          return "accessor"
        end
      end,
    })
    expect(ctx.p7svc.who()).to.equal("accessor")
  end)
end)

describe("allocation and hot-path invariants", function()
  local proto = cordis.proto
  local S = cordis.symbols
  local trace = require("cordis.trace")
  local resolveEpoch = require("cordis.resolve_epoch")
  local ordered = require("cordis.ordered")

  it("shares proxy handlers across traceable proxies and withProps/withProp wrappers", function()
    local root = U.root()
    local Svc = cordis.class("AllocSvc", cordis.Service)
    function Svc:constructor(ctx)
      cordis.Service.constructor(self, ctx, "allocsvc")
    end
    function Svc:who()
      return self.ctx
    end
    cordis.await(root:use(Svc))
    local a = cordis.await(root:inject({ "allocsvc" }, function() end)).ctx
    local b = cordis.await(root:inject({ "allocsvc" }, function() end)).ctx
    local pa, pb = a.allocsvc, b.allocsvc
    expect(rawequal(pa, pb)).to.equal(false)
    expect(rawequal(proto._state[pa].handler, proto._state[pb].handler)).to.equal(true)
    expect(rawequal(pa:who(), pb:who())).to.equal(false)

    -- withProps and withProp share handlers and preserve get/set/constructor/nil/false semantics
    local t1 = { a = 1, b = 2, constructor = "orig" }
    local wp1 = trace.withProp(t1, "a", 10)
    local wp2 = trace.withProp(t1, "a", false)
    local wpNil = trace.withProp(t1, "a", nil)
    local wpCtor = trace.withProp(t1, "constructor", "override")
    expect(rawequal(proto._state[wp1].handler, proto._state[wp2].handler)).to.equal(true)
    expect(wp1.a).to.equal(10)
    expect(wp1.b).to.equal(2)
    expect(wp2.a).to.equal(false)
    expect(wpNil.a).to.equal(1)
    expect(wpCtor.constructor).to.equal("orig")
    wp1.a = 99
    expect(t1.a).to.equal(99)
    expect(wp1.a).to.equal(10)
  end)

  it(
    "does not bump resolveEpoch on ctx:extend or trace.withProp, while mutating existing objects still does",
    function()
      local root = U.root()
      local target = { x = 1 }
      local before = resolveEpoch.n
      local child = root:extend({ extra = 1 })
      local shadow = child:extend({ [S.shadow] = root })
      local shadowed = shadow:extend({ extra2 = 2 })
      local wp = trace.withProp(target, "ctx", child)
      expect(resolveEpoch.n).to.equal(before)
      expect(child.extra).to.equal(1)
      expect(shadowed.extra2).to.equal(2)
      expect(rawequal(proto.getOwn(shadowed, S.shadow), root)).to.equal(true)
      expect(rawequal(wp.ctx, child)).to.equal(true)

      -- mutating an existing object must still bump resolveEpoch
      child.extra = 2
      expect(resolveEpoch.n > before).to.equal(true)
    end
  )

  it("lazily allocates empty proto own maps, DisposableList head, and Future reactions", function()
    local empty = proto.create(nil)
    expect(proto._state[empty].own).to.equal(nil)
    expect(proto.has(empty, "x")).to.equal(false)
    expect(proto.hasOwn(empty, "x")).to.equal(false)
    expect(proto.getOwn(empty, "x")).to.equal(nil)
    expect(proto.ownKeys(empty)).to.deep.equal({})
    expect(proto.delete(empty, "x")).to.equal(false)
    empty.x = 42
    expect(empty.x).to.equal(42)
    empty.y = 43
    expect(proto._state[empty].own ~= nil).to.equal(true)
    expect(empty.y).to.equal(43)

    local list = DisposableList.new()
    expect(list.head).to.equal(nil)
    expect(list:length()).to.equal(0)
    expect(list:values()).to.deep.equal({})
    local rm1 = list:push("p1")
    local rm2 = list:push("p2")
    expect(list.head).to.equal(nil)
    expect(list:values()).to.deep.equal({ "p1", "p2" })
    local rm3 = list:unshift("u1")
    list:unshift("u2")
    expect(list:values()).to.deep.equal({ "u2", "u1", "p1", "p2" })
    rm1()
    rm3()
    expect(list:values()).to.deep.equal({ "u2", "p2" })
    rm2()
    expect(list:values()).to.deep.equal({ "u2" })

    local root = U.root()
    local pending, resolve = cordis.Future.withResolvers(root.host)
    expect(pending._reactions).to.equal(nil)
    resolve("ok")
    expect(cordis.await(pending)).to.equal("ok")
    local settled = cordis.Future.resolve(root.host, "fast")
    expect(settled._reactions).to.equal(nil)
    expect(cordis.await(settled)).to.equal("fast")
  end)

  it("reuses bound mixin methods on unchanged service/method while tracking live replacements", function()
    local root = U.root()
    local f1, f2 = root.on, root.on
    expect(rawequal(f1, f2)).to.equal(true)

    local svc = {
      ping = function(self, x)
        return "v1:" .. tostring(x)
      end,
    }
    root:provide("allocmix", svc)
    root:mixin("allocmix", { "ping" })
    local m1, m2 = root.ping, root.ping
    expect(rawequal(m1, m2)).to.equal(true)
    expect(root:ping(1)).to.equal("v1:1")

    svc.ping = function(self, x)
      return "v2:" .. tostring(x)
    end
    local m3 = root.ping
    expect(rawequal(m1, m3)).to.equal(false)
    expect(root:ping(2)).to.equal("v2:2")
  end)

  it("preserves Map:forEach and Set:pairs live mutation semantics", function()
    local m = ordered.Map.new()
    m:set("a", 1)
    m:set("b", 2)
    m:set("c", 3)
    local seen = {}
    m:forEach(function(v, k)
      seen[#seen + 1] = k .. "=" .. v
      if k == "a" then
        m:delete("b")
      elseif k == "c" then
        m:delete("c")
        m:set("d", 4)
      end
    end)
    expect(seen).to.deep.equal({ "a=1", "c=3", "d=4" })

    local s = ordered.Set.new({ 1, 2 })
    local sSeen = {}
    for v in s:pairs() do
      sSeen[#sSeen + 1] = v
      if v == 2 then
        s:delete(2)
        s:add(3)
      end
    end
    expect(sSeen).to.deep.equal({ 1, 2, 3 })
  end)

  it("preserves select('#') for embedded and trailing nil arguments in emit and bail fast paths", function()
    local root = U.root()
    local emitLog = {}
    root:on("perf/nil-emit", function(...)
      local n = select("#", ...)
      emitLog[#emitLog + 1] = { n = n, a = select(1, ...), b = select(2, ...), c = select(3, ...), d = select(4, ...) }
    end)
    root:emit("perf/nil-emit", "first", nil, "third", nil)
    root:emit("perf/nil-emit", nil, nil)
    expect(#emitLog).to.equal(2)
    expect(emitLog[1].n).to.equal(4)
    expect(emitLog[1].a).to.equal("first")
    expect(emitLog[1].b).to.equal(nil)
    expect(emitLog[1].c).to.equal("third")
    expect(emitLog[1].d).to.equal(nil)
    expect(emitLog[2].n).to.equal(2)
    expect(emitLog[2].a).to.equal(nil)
    expect(emitLog[2].b).to.equal(nil)

    local bailLog = {}
    root:on("perf/nil-bail", function(...)
      local n = select("#", ...)
      bailLog[#bailLog + 1] = { n = n, a = select(1, ...), b = select(2, ...), c = select(3, ...) }
      return "bailed:" .. n
    end)
    local res = root:bail("perf/nil-bail", nil, "mid", nil)
    expect(res).to.equal("bailed:3")
    expect(#bailLog).to.equal(1)
    expect(bailLog[1].n).to.equal(3)
    expect(bailLog[1].a).to.equal(nil)
    expect(bailLog[1].b).to.equal("mid")
    expect(bailLog[1].c).to.equal(nil)
  end)
end)

describe("cordis hot-path storage and dispatch invariants", function()
  local proto = require("cordis.proto")
  local trace = require("cordis.trace")
  local classlib = require("cordis.class")
  local S = cordis.symbols

  it("stores single-key plain proto objects inline with direct pstate links and promotes cleanly", function()
    local base = proto.create(nil, { a = 1 })
    local sb = proto._state[base]
    expect(sb.own).to.equal(nil)
    expect(sb.kv).to.equal(nil)
    expect(sb.k1).to.equal("a")
    expect(sb.v1).to.equal(1)
    expect(proto.ownKeys(base)).to.deep.equal({ "a" })

    local child = proto._createSingle(base, "b", 2)
    local sc = proto._state[child]
    expect(sc.own).to.equal(nil)
    expect(rawequal(sc.pstate, sb)).to.equal(true)
    expect(child.a).to.equal(1)
    expect(child.b).to.equal(2)
    expect(child[nil]).to.equal(nil)

    -- promote 1-key -> 2-key preserves insertion order
    child.c = 3
    expect(sc.k1).to.equal(nil)
    expect(sc.kv.b).to.equal(2)
    expect(sc.kv.c).to.equal(3)
    expect(proto.ownKeys(child)).to.deep.equal({ "b", "c" })

    -- delete single key returns to empty
    expect(proto.delete(base, "a")).to.equal(true)
    expect(sb.k1).to.equal(nil)
    expect(proto.ownKeys(base)).to.deep.equal({})
    expect(child.a).to.equal(nil)

    -- setPrototypeOf updates pstate link
    local alt = proto.create(nil, { a = 99 })
    proto.setPrototypeOf(child, alt)
    expect(rawequal(sc.pstate, proto._state[alt])).to.equal(true)
    expect(child.a).to.equal(99)

    -- proxy uses dedicated proxy metatable while preserving __name
    local p = proto.proxy({}, {})
    expect(getmetatable(p).__name).to.equal("cordis.Object")
    expect(rawequal(getmetatable(p), proto.OBJ)).to.equal(false)
  end)

  it("uses table __index on getter-free root classes and upgrades live when a getter is added", function()
    local Box = classlib.class("FastBox")
    function Box:constructor(v)
      self.v = v
    end
    function Box:get()
      return self.v
    end
    expect(rawequal(Box.__index, Box)).to.equal(true)
    expect(rawget(Box, "__newindex")).to.equal(nil)
    local SubBox = classlib.class("FastSubBox", Box)
    expect(rawget(SubBox, "__newindex")).to.equal(nil)
    local b = Box.new(10)
    local sb = SubBox.new(15)
    expect(b:get()).to.equal(10)
    expect(sb:get()).to.equal(15)

    -- adding a getter after construction upgrades __index and __newindex live (including subclasses)
    Box.__get.doubled = function(self)
      return self.v * 2
    end
    expect(type(Box.__index)).to.equal("function")
    expect(type(rawget(Box, "__newindex"))).to.equal("function")
    expect(type(rawget(SubBox, "__newindex"))).to.equal("function")
    expect(b.doubled).to.equal(20)
    expect(sb.doubled).to.equal(30)
    expect(b:get()).to.equal(10)
    expect(function()
      sb.doubled = 1
    end).to.throw("read-only")

    -- adding a setter to a subclass enables setter dispatch live
    local setSeen
    SubBox.__set.val = function(self, v)
      setSeen = v
      self.v = v
    end
    sb.val = 42
    expect(setSeen).to.equal(42)
    expect(sb.v).to.equal(42)
  end)

  it("caches root properties and mixin accessors while honoring replacements, receivers, and internal/get", function()
    local root = U.root()
    local child = root:extend({ extra = 1 }):extend({ extra2 = 2 })

    -- warm reads of mixin and root own properties
    local on1 = child.on
    local host1 = child.host
    local ev1 = child.events
    local ext1 = child.extend

    -- subsequent reads must not invoke proto.has
    local hasCalls = 0
    local origHas = proto.has
    proto.has = function(...)
      hasCalls = hasCalls + 1
      return origHas(...)
    end
    local ok, err = pcall(function()
      for _ = 1, 20 do
        expect(rawequal(child.on, on1)).to.equal(true)
        expect(rawequal(child.host, host1)).to.equal(true)
        expect(rawequal(child.events, ev1)).to.equal(true)
        expect(rawequal(child.extend, ext1)).to.equal(true)
      end
    end)
    proto.has = origHas
    if not ok then
      error(err, 0)
    end
    expect(hasCalls).to.equal(0)

    -- mutating a mixed-in method on the underlying class or instance invalidates the cached bound method
    local svc = classlib.class("FastMixSvc")
    function svc:ping()
      return "v1"
    end
    local inst = svc.new()
    root:provide("fastmix", inst)
    root:mixin("fastmix", { "ping" })
    expect(child:ping()).to.equal("v1")
    -- class-level method swap (without bumping resolveEpoch)
    svc.ping = function()
      return "v2"
    end
    expect(child:ping()).to.equal("v2")
    -- instance-level override
    proto.defineOwn(inst, "ping", function()
      return "v3"
    end)
    expect(child:ping()).to.equal("v3")

    -- overriding receiver via withProp still receives custom receiver
    local sawSelf
    root:provide("fastrecv", {
      who = function(self)
        sawSelf = self.tag
      end,
    })
    root:mixin("fastrecv", { "who" })
    child:who()
    expect(sawSelf).to.equal(nil)
    local wrapped = trace.withProp(child, S.receiver, { tag = "custom" })
    wrapped:who()
    expect(sawSelf).to.equal("custom")

    -- adding internal/get listener still intercepts plugin-fiber service reads
    local consumerCtx
    cordis.await(root:plugin({
      name = "fast-consumer",
      inject = { "fastmix" },
      apply = function(c)
        consumerCtx = c
      end,
    }))
    local _ = consumerCtx.fastmix -- warm cache
    local intercepted = 0
    local off = root:on("internal/get", function(c, name, _, next)
      if name == "fastmix" then
        intercepted = intercepted + 1
      end
      return next()
    end)
    local _ = consumerCtx.fastmix
    off()
    expect(intercepted).to.equal(1)
  end)

  it("skips internal/listener bail for ordinary events and preserves nil args + filter on thisArg emit/bail", function()
    local root = U.root()
    local bailCalls = 0
    local eventsRaw = root.events[S.original]
    local origBail = eventsRaw.bail
    rawset(eventsRaw, "bail", function(...)
      bailCalls = bailCalls + 1
      return origBail(...)
    end)
    local ok, err = pcall(function()
      root:on("fast/plain", function() end)
    end)
    rawset(eventsRaw, "bail", nil)
    if not ok then
      error(err, 0)
    end
    expect(bailCalls).to.equal(0)

    -- custom internal/listener still fires
    local sawListener
    local offL = root:on("internal/listener", function(_, name)
      sawListener = name
    end)
    root:on("fast/custom", function() end)
    offL()
    expect(sawListener).to.equal("fast/custom")

    -- thisArg emit/bail preserves nil args and S.filter
    local seen = {}
    local c1 = root:extend({ tag = "keep" })
    local c2 = root:extend({ tag = "skip" })
    c1:on("fast/this", function(thisArg, ...)
      seen[#seen + 1] = { tag = "c1", n = select("#", ...), a = select(1, ...), b = select(2, ...), c = select(3, ...) }
      return "from-c1:" .. select("#", ...)
    end)
    c2:on("fast/this", function()
      seen[#seen + 1] = { tag = "c2" }
      return "from-c2"
    end)
    local thisArg = proto.create(root)
    thisArg[S.filter] = function(_, target)
      return target.tag == "keep"
    end
    root:emit(thisArg, "fast/this", nil, "mid", nil)
    local bailed = root:bail(thisArg, "fast/this", nil, "mid", nil)
    expect(#seen).to.equal(2)
    expect(seen[1].tag).to.equal("c1")
    expect(seen[1].n).to.equal(3)
    expect(seen[1].a).to.equal(nil)
    expect(seen[1].b).to.equal("mid")
    expect(seen[1].c).to.equal(nil)
    expect(bailed).to.equal("from-c1:3")
  end)

  it("reuses a shared zero-allocation outer-stack function when debug library is absent", function()
    local saved = rawget(_G, "debug")
    rawset(_G, "debug", nil)
    local ok, f1, f2, empty = pcall(function()
      local a = trace.buildOuterStack()
      local b = trace.buildOuterStack()
      return a, b, a()
    end)
    rawset(_G, "debug", saved)
    if not ok then
      error(f1, 0)
    end
    expect(rawequal(f1, f2)).to.equal(true)
    expect(empty).to.deep.equal({})
  end)

  it("invalidates string-key proxy shortcut when a prototype gains, deletes, or rewires string keys", function()
    local root = U.root()
    local rootTarget = proto._state[root].target
    proto.defineOwn(rootTarget, "customProp", "from-root")
    local mid = root:extend({ [S.isolate] = proto.create(root[S.isolate]) })
    local leaf = mid:extend()
    local otherLeaf = root:extend():extend()
    -- Warm string-key shortcut through mid -> root and otherLeaf -> root
    expect(leaf.customProp).to.equal("from-root")
    expect(otherLeaf.customProp).to.equal("from-root")
    -- Adding a string key on an intermediate prototype invalidates children's shortcut
    proto.defineOwn(mid, "customProp", "from-mid")
    expect(leaf.customProp).to.equal("from-mid")
    -- Unaffected branch falls through once and re-arms its shortcut
    expect(otherLeaf.customProp).to.equal("from-root")
    expect(proto._state[otherLeaf].strEpoch ~= nil).to.equal(true)
    -- Deleting the string key restores fallback to root via real property read
    proto.delete(mid, "customProp")
    expect(leaf.customProp).to.equal("from-root")
    -- Rewiring prototype via setPrototypeOf invalidates shortcut
    local alt = proto.create(nil, { customProp = "from-alt" })
    local leaf2 = proto.create(proto.create(root))
    expect(leaf2.customProp).to.equal("from-root")
    proto.setPrototypeOf(proto.getPrototypeOf(leaf2), alt)
    expect(leaf2.customProp).to.equal("from-alt")
  end)

  it("preserves false values in multi-key plain objects across getOwn, entries, and assign", function()
    local src = proto.create(nil, { a = 1, disabled = false })
    expect(proto.getOwn(src, "disabled")).to.equal(false)
    expect(proto.getOwn(src, "a")).to.equal(1)

    local ents = proto.entries(src)
    local byKey = {}
    for _, pair in ipairs(ents) do
      byKey[pair[1]] = pair[2]
    end
    expect(byKey.a).to.equal(1)
    expect(byKey.disabled).to.equal(false)

    local dst = proto.create(nil, { a = 0, disabled = true })
    proto.assign(dst, src)
    expect(proto.hasOwn(dst, "disabled")).to.equal(true)
    expect(proto.getOwn(dst, "disabled")).to.equal(false)
    expect(dst.disabled).to.equal(false)
    expect(dst.a).to.equal(1)
  end)

  it("traces class-level and inherited-getter trackers on root target own properties", function()
    local root = U.root()
    local rootTarget = proto._state[root].target
    local tracker = { property = "ctx" }

    local Cls = cordis.class("FastClassTracker")
    Cls[S.tracker] = tracker
    function Cls:constructor(ctx)
      self.ctx = ctx
    end
    function Cls:who()
      return self.ctx
    end
    local inst1 = Cls.new(root)
    proto.defineOwn(rootTarget, "clsTracked", inst1)

    local Parent = cordis.class("FastParentGetterTracker")
    Parent.__get[S.tracker] = function()
      return tracker
    end
    local Child = cordis.class("FastChildGetterTracker", Parent)
    function Child:constructor(ctx)
      self.ctx = ctx
    end
    function Child:who()
      return self.ctx
    end
    local inst2 = Child.new(root)
    proto.defineOwn(rootTarget, "parentTracked", inst2)

    local childCtx = root:extend()
    local t1 = childCtx.clsTracked
    expect(rawequal(t1, inst1)).to.equal(false)
    expect(rawequal(proto.get(t1, S.original), inst1)).to.equal(true)
    expect(rawequal(t1:who(), childCtx)).to.equal(true)

    local t2 = childCtx.parentTracked
    expect(rawequal(t2, inst2)).to.equal(false)
    expect(rawequal(proto.get(t2, S.original), inst2)).to.equal(true)
    expect(rawequal(t2:who(), childCtx)).to.equal(true)
  end)

  it("reads single-key prototype properties and k1 receiver/shadow fallbacks in reflect.handler", function()
    local reflect = require("cordis.reflect")
    local root = U.root()

    -- Single-key terminal prototype (`k1` mode on `tp`)
    local singleProto = proto.create(nil, {
      onlyMethod = function()
        return "from-k1-proto"
      end,
    })
    expect(proto._state[singleProto].k1).to.equal("onlyMethod")
    local target = proto.create(singleProto, { a = 1, b = 2 })
    local wrapped = proto.proxy(target, reflect.handler)
    expect(wrapped.onlyMethod()).to.equal("from-k1-proto")

    -- Single-key `target` holding `S.receiver` in `k1` mode (mixin accessor fallback)
    local customReceiver = { tag = "k1-recv" }
    local seenReceiver
    local mixSvc = {
      ping = function(self)
        seenReceiver = self
        return "mix-ok"
      end,
    }
    local baseTarget = proto.create(nil, {
      reflect = root.reflect,
      events = root.events,
      [S.isolate] = root[S.isolate],
      k1MixHost = mixSvc,
    })
    local recvTarget = proto.create(baseTarget)
    proto.defineOwn(recvTarget, S.receiver, customReceiver)
    expect(proto._state[recvTarget].k1).to.equal(S.receiver)
    local offMix = root:mixin("k1MixHost", { "ping" })
    local recvProxy = proto.proxy(recvTarget, reflect.handler)
    expect(recvProxy.ping()).to.equal("mix-ok")
    expect(seenReceiver.tag).to.equal("k1-recv")
    offMix()

    -- Single-key `target` holding `S.shadow` in `k1` mode
    local shadowTarget = proto.create(baseTarget)
    proto.defineOwn(shadowTarget, S.shadow, root)
    expect(proto._state[shadowTarget].k1).to.equal(S.shadow)
    root:provide("k1ShadowSvc", "visible-from-root")
    local shadowProxy = proto.proxy(shadowTarget, reflect.handler)
    expect(shadowProxy.k1ShadowSvc).to.equal("visible-from-root")
  end)

  it("invalidates traceable self-method cache when a plain or class method is replaced", function()
    local root = U.root()
    local plain = {
      ctx = root,
      [S.tracker] = { property = "ctx" },
      ping = function(self)
        return "v1", self.ctx
      end,
    }
    local tp = trace.getTraceable(root:extend(), plain)
    local r1 = tp:ping()
    expect(r1).to.equal("v1")
    plain.ping = function()
      return "v2"
    end
    expect(tp:ping()).to.equal("v2")

    local Cls = cordis.class("FastTraceSvc")
    function Cls:constructor(ctx)
      self.ctx = ctx
      self[S.tracker] = { property = "ctx" }
    end
    function Cls:ping()
      return "cls-v1"
    end
    local inst = Cls.new(root)
    local ti = trace.getTraceable(root:extend(), inst)
    expect(ti:ping()).to.equal("cls-v1")
    Cls.ping = function()
      return "cls-v2"
    end
    expect(ti:ping()).to.equal("cls-v2")
  end)

  it(
    "keeps context strEpoch valid across unrelated isolate/plain writes while invalidating underProxy ancestors",
    function()
      local root = U.root()
      local c1 = root:extend({ [cordis.symbol("tag1")] = 1 })
      local c2 = c1:extend({ [cordis.symbol("tag2")] = 2 })
      expect(c2.host).to.equal(root.host)

      local s2 = proto._state[c2]
      local epochBefore = s2.strEpoch
      expect(epochBefore).to.be.ok()

      -- Writing string keys on unrelated plain objects (root isolate, detached proto map)
      -- must not invalidate context ancestor-proxy skip caches.
      root:provide("unrelatedSvc", { ok = true })
      local detached = proto.create(nil)
      local detachedChild = proto.create(detached)
      detached.foo = "bar"
      expect(detachedChild.foo).to.equal("bar")
      expect(c2.host).to.equal(root.host)
      expect(s2.strEpoch).to.equal(epochBefore)

      -- Writing a string key on an ancestor in c2's proxy chain MUST shadow the proxy.
      proto.defineOwn(c1, "host", "shadowed-host")
      expect(c2.host).to.equal("shadowed-host")
      proto.delete(c1, "host")
      expect(c2.host).to.equal(root.host)

      -- Rewiring a detached plain chain under a proxy via setPrototypeOf must still invalidate
      -- when an intermediate node later gains a string property.
      local mid = proto.create(nil)
      local leaf = proto.create(mid)
      proto.setPrototypeOf(mid, root)
      expect(leaf.host).to.equal(root.host)
      proto.defineOwn(mid, "host", "rewired-host")
      expect(leaf.host).to.equal("rewired-host")
      proto.delete(mid, "host")
      expect(leaf.host).to.equal(root.host)
    end
  )

  it("invalidates watched symbol fast checks across extend, defineOwn, delete, and setPrototypeOf", function()
    local root = U.root()
    -- Provide watchSvc from a sibling plugin so childCtx genuinely requires inject
    local prov = root:plugin({
      name = "watch-provider",
      apply = function(ctx)
        ctx:provide("watchSvc", "root-val")
      end,
    })
    cordis.await(prov)

    -- Child fiber without inject cannot read watchSvc unless S.shadow points to root
    local childCtx
    local f = root:plugin({
      name = "no-inject",
      apply = function(ctx)
        childCtx = ctx
      end,
    })
    cordis.await(f)
    expect(function()
      return childCtx.watchSvc
    end).to.throw("without inject")

    -- Adding S.shadow via proto.defineOwn on an ancestor must be observed immediately
    local mid = childCtx:extend({ [cordis.symbol("m")] = true })
    local leaf = mid:extend({ [cordis.symbol("l")] = true })
    expect(function()
      return leaf.watchSvc
    end).to.throw("without inject")
    proto.defineOwn(mid, S.shadow, root)
    expect(leaf.watchSvc).to.equal("root-val")
    proto.delete(mid, S.shadow)
    expect(function()
      return leaf.watchSvc
    end).to.throw("without inject")

    -- Adding S.receiver dynamically on an ancestor must reach mixin getters
    local seenRecv
    local recvSvc = {
      ping = function(self)
        seenRecv = self
        return "ok"
      end,
    }
    proto.defineOwn(proto.proxyTarget(root), "watchMixSvc", recvSvc)
    local off = root:mixin("watchMixSvc", { "ping" })
    local custom = { marker = "dyn-recv" }
    proto.defineOwn(mid, S.receiver, custom)
    expect(leaf.ping()).to.equal("ok")
    expect(seenRecv.marker).to.equal("dyn-recv")
    proto.delete(mid, S.receiver)
    off()

    -- Rewiring via setPrototypeOf onto a shadowed chain must expose S.shadow
    local shadowed = childCtx:extend({ [S.shadow] = root })
    local detached = proto.create(nil)
    proto.setPrototypeOf(detached, shadowed)
    expect(detached.watchSvc).to.equal("root-val")
  end)

  it("invalidates traceable cache-first method reads on own shadowing, getter override, and def-site change", function()
    local root = U.root()
    local c1 = root:extend({ [cordis.symbol("c1")] = 1 })
    local c2 = root:extend({ [cordis.symbol("c2")] = 2 })

    local Svc = cordis.class("CacheFirstSvc")
    function Svc:constructor(ctx)
      self.ctx = ctx
      self[S.tracker] = { property = "ctx" }
    end
    function Svc:who()
      return "class", self.ctx
    end
    local inst = Svc.new(c1)
    local tp = trace.getTraceable(c2, inst)

    -- Warm selfMethods cache
    local tag1, ctx1 = tp:who()
    expect(tag1).to.equal("class")
    expect(rawequal(proto.get(ctx1, S.shadow), c1)).to.equal(true)

    -- Def-site mutation (`inst.ctx = root`) must invalidate cached shadow
    inst.ctx = root
    local tag2, ctx2 = tp:who()
    expect(tag2).to.equal("class")
    expect(rawequal(proto.get(ctx2, S.shadow), root)).to.equal(true)

    -- Own property shadowing class method must invalidate cache
    rawset(inst, "who", function(self)
      return "own", self.ctx
    end)
    local tag3 = tp:who()
    expect(tag3).to.equal("own")
    rawset(inst, "who", nil)
    expect((tp:who())).to.equal("class")

    -- Adding a class getter for `who` must bypass data-method cache and run the getter
    Svc.__get.who = function()
      return function()
        return "getter"
      end
    end
    expect((tp:who())).to.equal("getter")
  end)

  it("preserves shadow ctx and custom subclassing when unwrapping built-in services", function()
    local root = U.root()
    local seen = {}
    local f = root:plugin({
      name = "events-owner",
      apply = function(ctx)
        local off = ctx:on("unwrap/test", function(v)
          seen[#seen + 1] = v
        end)
        ctx:emit("unwrap/test", "a")
        ctx.events:emit("unwrap/test", "b")
        off()
        ctx:emit("unwrap/test", "c")
      end,
    })
    cordis.await(f)
    expect(table.concat(seen, ",")).to.equal("a,b")
  end)

  it("uses table __index for getter-free subclasses and upgrades descendants when a parent getter is added", function()
    local Base = cordis.class("FastSubBase")
    function Base:greet()
      return "base"
    end
    local Mid = cordis.class("FastSubMid", Base)
    local Leaf = cordis.class("FastSubLeaf", Mid)

    -- Getter-free subclasses use direct table `__index = cls`
    expect(rawget(Mid, "__index")).to.equal(Mid)
    expect(rawget(Leaf, "__index")).to.equal(Leaf)
    local inst = Leaf.new()
    expect(inst:greet()).to.equal("base")

    -- Adding a getter to the base class upgrades both Mid and Leaf immediately
    Base.__get.computed = function(self)
      return "got:" .. self:greet()
    end
    expect(type(rawget(Mid, "__index"))).to.equal("function")
    expect(type(rawget(Leaf, "__index"))).to.equal("function")
    expect(inst.computed).to.equal("got:base")
  end)

  it(
    "keeps root mixin cache valid across unrelated resolveEpoch bumps and invalidates on shadow or method change",
    function()
      local root = U.root()
      local c = root:extend({ [cordis.symbol("m")] = true })
      local on1 = c.on
      expect(type(on1)).to.equal("function")

      -- Unrelated provide bumps resolveEpoch but must keep cached `c.on` identical and working
      root:provide("unrelatedForMixin", { ok = true })
      local on2 = c.on
      expect(rawequal(on1, on2)).to.equal(true)

      -- Shadowing `"events"` on an ancestor invalidates the mixin cache
      local customEvents = {
        on = function()
          return "custom-on"
        end,
      }
      local mid = root:extend({ [cordis.symbol("m2")] = true })
      local leaf = mid:extend({ [cordis.symbol("m3")] = true })
      expect(type(leaf.on)).to.equal("function")
      proto.defineOwn(mid, "events", customEvents)
      expect(leaf:on("x", function() end)).to.equal("custom-on")
      proto.delete(mid, "events")
      local off = leaf:on("x", function() end)
      expect(proto.callable(off)).to.equal(true)
      off()

      -- Shadowing `"events"` directly on a leaf context (never a prototype itself)
      -- must also invalidate its cached root mixin and restore it on deletion.
      local pureLeaf = root:extend({ [cordis.symbol("leaf")] = true })
      expect(type(pureLeaf.on)).to.equal("function")
      proto.defineOwn(pureLeaf, "events", customEvents)
      expect(pureLeaf:on("x", function() end)).to.equal("custom-on")
      proto.delete(pureLeaf, "events")
      local leafOff = pureLeaf:on("x", function() end)
      expect(proto.callable(leafOff)).to.equal(true)
      leafOff()

      -- Same when the leaf holds a single own string key (`k1` fast storage path).
      local k1Leaf = root:extend()
      expect(type(k1Leaf.on)).to.equal("function")
      proto.defineOwn(k1Leaf, "events", customEvents)
      expect(k1Leaf:on("x", function() end)).to.equal("custom-on")
      proto.delete(k1Leaf, "events")
      local k1Off = k1Leaf:on("x", function() end)
      expect(proto.callable(k1Off)).to.equal(true)
      k1Off()
    end
  )

  it("does not bypass custom proxy get traps in _getWatched (withProp / withProps)", function()
    local trace = require("cordis.trace")
    local Context = cordis.Context
    local root = U.root()

    local blocked = function()
      return false
    end
    local wrappedProp = trace.withProp(proto.create(nil), Context.filter, blocked)
    expect(proto._getWatched(wrappedProp, Context.filter)).to.equal(blocked)

    local wrappedProps = trace.withProps(proto.create(nil), { [Context.filter] = blocked })
    expect(proto._getWatched(wrappedProps, Context.filter)).to.equal(blocked)

    local customProxy = proto.proxy(proto.create(nil), {
      get = function(_, k)
        if k == Context.filter then
          return blocked
        end
        return nil
      end,
    })
    expect(proto._getWatched(customProxy, Context.filter)).to.equal(blocked)

    -- End-to-end: a withProp-wrapped filter on an emitted receiver (both plain target and root)
    -- must still enforce isolation instead of bypassing the proxy get trap
    local received = 0
    root:on("watched/proxy-filter", function()
      received = received + 1
    end)
    local plainFiltered = trace.withProp(proto.create(nil), Context.filter, function()
      return false
    end)
    root.events:emit(plainFiltered, "watched/proxy-filter")
    expect(received).to.equal(0)

    local filteredCtx = trace.withProp(root, Context.filter, function()
      return false
    end)
    root.events:emit(filteredCtx, "watched/proxy-filter")
    expect(received).to.equal(0)

    local allowedPlain = trace.withProp(proto.create(nil), Context.filter, function()
      return true
    end)
    root.events:emit(allowedPlain, "watched/proxy-filter")
    expect(received).to.equal(1)
  end)
end)
