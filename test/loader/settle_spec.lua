-- Library-own tests for efficient loader settlement. Upstream checks
-- `loader.getTasks()` after every entry's init settles (entry.ts init), a walk
-- over all entries per entry; the port counts the entries still settling per
-- tree and walks once when the count drops to zero. What a consumer sees is
-- unchanged: a component injecting `loader` with `await: true` starts once
-- every entry has settled, and not before.
local cordis = require("cordis")
local T = require("loader.mock_loader")

local FiberState = cordis.FiberState
local sleep = T.sleep

describe("loader settle", function()
  it("checks the loader's tasks once per wave, not once per entry", function()
    local _, loader = T.setup()
    loader:mock("plug", function() end)
    local calls = 0
    local getTasks = loader.getTasks
    loader.getTasks = function(...)
      calls = calls + 1
      return getTasks(...)
    end
    local rows = {}
    for i = 1, 40 do
      rows[i] = { id = "p" .. i, name = "plug" }
    end
    loader:read(rows):await()
    loader:await():await()
    expect(loader:expectFiber("p40").state).to.equal(FiberState.ACTIVE)
    -- upstream: one call per entry (40) plus the awaits'
    expect(calls < 10).to.equal(true)
  end)

  it("starts a loader consumer with await only after every entry settled", function()
    local _, loader = T.setup()
    local resolve
    local slow = cordis.Future.withResolvers
    loader:mock("slow", function(ctx)
      local f, res = slow(ctx.host)
      resolve = res
      return f
    end)
    loader:mock("fast", function() end)
    local started = 0
    loader:mock("consumer", function()
      started = started + 1
    end)
    -- not read(): it would await every entry, the slow one included
    loader.root
      :update({
        { id = "s", name = "slow" },
        { id = "f", name = "fast" },
        { id = "c", name = "consumer", inject = { loader = { await = true } } },
      })
      :await()
    sleep()
    expect(started).to.equal(0)
    expect(loader.store.c.outerFiber.state).to.equal(FiberState.PENDING)
    resolve()
    sleep()
    expect(loader:expectFiber("s").state).to.equal(FiberState.ACTIVE)
    expect(loader:expectFiber("c").state).to.equal(FiberState.ACTIVE)
    expect(started).to.equal(1)
    -- a second wave: the consumer goes pending while it settles, and comes back
    loader:mock("late", function() end)
    loader:create({ id = "l", name = "late" }):await()
    sleep()
    expect(loader:expectFiber("l").state).to.equal(FiberState.ACTIVE)
    expect(loader:expectFiber("c").state).to.equal(FiberState.ACTIVE)
  end)
end)

describe("loader isolate without changes", function()
  -- an entry whose isolation does not change moves no service: step 6 of
  -- patchIsolate would notify no names, yet each notify walks every fiber
  it("does not notify when the isolate map is unchanged", function()
    local _, loader = T.setup()
    loader:mock("plug", function() end)
    local calls = 0
    local cls = require("cordis.reflect").ReflectService
    local before = cls.notify
    cls.notify = function(self, names, ...)
      if #names == 0 then
        calls = calls + 1
      end
      return before(self, names, ...)
    end
    local rows = {}
    for i = 1, 10 do
      rows[i] = { id = "p" .. i, name = "plug" }
    end
    loader:read(rows):await()
    cls.notify = before
    expect(calls).to.equal(0)
    expect(loader:expectFiber("p10").state).to.equal(FiberState.ACTIVE)
  end)

  it("skips proto.keys on empty-isolate entries even with pre-provided services", function()
    local root, loader = T.setup()
    for i = 1, 64 do
      root:provide("svc" .. i, { i = i })
    end
    loader:mock("plug", function() end)
    local proto = cordis.proto
    local keys = proto.keys
    local keyCalls = 0
    proto.keys = function(...)
      keyCalls = keyCalls + 1
      return keys(...)
    end
    local rows = {}
    for i = 1, 16 do
      rows[i] = { id = "p" .. i, name = "plug" }
    end
    local ok, err = pcall(function()
      loader:read(rows):await()
    end)
    proto.keys = keys
    if not ok then
      error(err, 0)
    end
    expect(keyCalls).to.equal(0)
    expect(loader:expectFiber("p16").state).to.equal(FiberState.ACTIVE)
  end)

  it("falls back to full diff when options.isolate is removed or parent changes", function()
    local L = require("cordis.loader")
    local root, loader = T.setup()
    root:provide("svc", { tag = "root" })
    root:isolate("svc", L.accessGlobal("svc", "A")):provide("svc", { tag = "A" })
    local seen = {}
    loader.modules.consumer = {
      name = "consumer",
      inject = { "svc" },
      apply = function(ctx)
        seen[#seen + 1] = ctx.svc.tag
      end,
    }
    local id = loader:create({ name = "consumer", isolate = { svc = "A" } }):await()
    loader:await():await()
    expect(seen).to.deep.equal({ "A" })

    -- remove options.isolate (using cordis.null via update, then updating again with options.isolate == nil)
    loader:update(id, { isolate = cordis.null }):await()
    loader:await():await()
    expect(loader.store[id].options.isolate).to.equal(nil)
    expect(seen).to.deep.equal({ "A", "root" })

    -- subsequent update with options.isolate == nil hits fast path without breaking isolation
    loader:update(id, { disabled = false }):await()
    loader:await():await()
    expect(loader:expectFiber(id).ctx.svc.tag).to.equal("root")

    -- parent isolate change triggers full diff fallback when moving between distinct parent maps
    local group1 = loader:create({ id = "g1", name = "@cordisjs/group", group = true, config = {} }):await()
    local group2 =
      loader:create({ id = "g2", name = "@cordisjs/group", group = true, isolate = { svc = "A" }, config = {} }):await()
    local childId = loader:create({ name = "consumer" }, group1):await()
    loader:await():await()
    expect(loader:expectFiber(childId).ctx.svc.tag).to.equal("root")
    loader:update(childId, {}, group2):await()
    loader:await():await()
    expect(loader:expectFiber(childId).ctx.svc.tag).to.equal("A")
  end)

  it("falls back to full diff when a proxy ancestor depends on receiver and reads options.isolate once", function()
    local L = require("cordis.loader")
    local Context = cordis.Context
    local proto = cordis.proto
    local symA = L.accessGlobal("svc", "A")
    local symB = L.accessGlobal("svc", "B")
    local root, loader = T.setup()
    loader.modules.prov = {
      name = "prov",
      apply = function(ctx)
        ctx:provide("svc", { tag = "moved" })
      end,
    }
    local groupId = loader:create({ id = "gProxy", name = "@cordisjs/group", group = true, config = {} }):await()
    local groupEntry = loader.store[groupId]
    local childIsolate
    local origParentIsolate = groupEntry.ctx[Context.isolate]
    local proxyMap = proto.proxy(proto.create(origParentIsolate, { svc = symA }), {
      get = function(target, k, receiver)
        if k == "svc" then
          if childIsolate and not rawequal(receiver, childIsolate) then
            return symB
          end
          return symA
        end
        return proto.get(target, k, receiver)
      end,
    })
    proto.defineOwn(groupEntry.ctx, Context.isolate, proxyMap)
    local childId = loader:create({ name = "prov" }, groupId):await()
    loader:await():await()
    local childEntry = loader.store[childId]
    childIsolate = childEntry.ctx[Context.isolate]
    local impl = root.reflect.store[symA]
    expect(impl).to.be.ok()

    loader:update(childId, { disabled = false }):await()
    loader:await():await()
    expect(root.reflect.store[symA]).to.equal(nil)
    expect(root.reflect.store[symB]).to.equal(impl)

    -- options.isolate getter returning a table once and nil on subsequent reads
    local singleId = loader:create({ name = "prov" }):await()
    loader:await():await()
    local singleEntry = loader.store[singleId]
    local rootSym = root[Context.isolate].svc
    local singleImpl = root.reflect.store[rootSym]
    expect(singleImpl).to.be.ok()
    local reads = 0
    local opts = setmetatable({ id = singleEntry.options.id, name = "prov" }, {
      __index = function(_, k)
        if k == "isolate" then
          reads = reads + 1
          if reads == 1 then
            return { svc = "C" }
          end
          return nil
        end
      end,
    })
    singleEntry.options = opts
    singleEntry:_patchContext({}):await()
    expect(reads).to.equal(1)
    expect(root.reflect.store[rootSym]).to.equal(nil)
    expect(root.reflect.store[L.accessGlobal("svc", "C")]).to.equal(singleImpl)
  end)
end)
