-- Ported from cordis packages/loader/tests/isolate-provide.spec.ts (MIT, (c) Shigma)
local cordis = require("cordis")
local L = require("cordis.loader")
local T = require("loader.mock_loader")
local U = require("kit.util")

local FiberState = cordis.FiberState
local accessGlobal = L.accessGlobal

-- the slots of `name` in the service store: { key, description, impl, tag }
local function slots(ctx, name)
  local found = {}
  for key, impl in pairs(ctx.reflect.store) do
    if cordis.isSymbol(key) and impl and impl.name == name then
      found[#found + 1] = {
        key = key,
        description = key.description or "",
        impl = impl,
        tag = type(impl.value) == "table" and impl.value.tag or nil,
      }
    end
  end
  return found
end

local function find(list, predicate)
  for _, item in ipairs(list) do
    if predicate(item) then
      return item
    end
  end
end

local function some(list, predicate)
  return find(list, predicate) ~= nil
end

-- components: name -> function, or { fn, inject = ... } for a component
-- that carries `inject`
local function boot(components)
  local root, loader = T.setup()
  for name, component in pairs(components) do
    if type(component) == "table" then
      loader:mock(name, component[1]).inject = component.inject
    else
      loader:mock(name, component)
    end
  end
  return root, loader
end

local function started(loader, id)
  local entry = loader.store[id]
  local fiber = entry and entry.innerFiber
  expect(fiber).to.be.ok()
  fiber:await():await()
  return fiber
end

-- `setImmediate()`: one turn of the timer queue
local function setImmediate()
  T.sleep(0)
end

describe("Service Isolation: provide migration", function()
  -- isolate-provide.spec.ts:52
  it("keeps self access while the provision context changes realms", function()
    local reads = {}
    local root, loader = boot({
      prov = function(ctx)
        ctx:provide("svc", { tag = "prov" })
        ctx:on("internal/update", function()
          table.insert(reads, ctx.svc.tag)
        end)
      end,
    })
    local id = loader:create({ name = "prov", config = { revision = 1 } }):await()
    local fiber = started(loader, id)
    loader:update(id, { isolate = { svc = "A" }, config = { revision = 2 } }):await()
    expect(reads).to.deep.equal({ "prov" })
    expect(fiber.ctx.svc.tag).to.equal("prov")
    cordis.await(root.fiber:dispose())
  end)

  -- isolate-provide.spec.ts:70
  it("reloads a self-provider after an isolate-only transfer", function()
    local calls = 0
    local duringReload
    local root, loader = boot({
      prov = function(ctx, config)
        calls = calls + 1
        if calls > 1 then
          duringReload = slots(ctx, "svc")
        end
        ctx:provide("svc", { tag = config and config.tag or "init" })
      end,
    })

    local id = loader:create({ name = "prov", config = { tag = "init" } }):await()
    started(loader, id)
    expect(calls).to.equal(1)
    local before = slots(root, "svc")
    expect(before).to.have.length(1)

    loader:update(id, { isolate = { svc = true } }):await()
    expect(calls).to.equal(1)
    local after = slots(root, "svc")
    expect(after).to.have.length(1)
    expect(after[1].impl).to.equal(before[1].impl)
    expect(after[1].key).never.to.equal(before[1].key)
    expect(root.reflect.store[before[1].key]).to.equal(nil)
    expect(after[1].description).to.equal("svc#" .. loader.store[id].options.id)

    loader:update(id, { config = { tag = "reloaded" } }):await()
    started(loader, id)
    expect(calls).to.equal(2)
    expect(duringReload).to.have.length(0)
    local reloaded = slots(root, "svc")
    expect(reloaded).to.have.length(1)
    expect(reloaded[1].impl).never.to.equal(before[1].impl)
    expect(reloaded[1].tag).to.equal("reloaded")
    expect(reloaded[1].description).to.equal(after[1].description)
  end)

  -- isolate-provide.spec.ts:107
  it("keeps an impl that reused the abandoned symbol", function()
    local calls = 0
    local root, loader = boot({
      prov = function(ctx)
        calls = calls + 1
        ctx:provide("svc", { tag = "prov" })
      end,
      other = function(ctx)
        ctx:provide("svc", { tag = "other" })
      end,
    })

    local id = loader:create({ name = "prov" }):await()
    started(loader, id)
    local before = slots(root, "svc")
    expect(before).to.have.length(1)

    loader:update(id, { isolate = { svc = true } }):await()
    expect(calls).to.equal(1)
    local moved = slots(root, "svc")
    expect(moved).to.have.length(1)
    expect(moved[1].impl).to.equal(before[1].impl)
    expect(moved[1].key).never.to.equal(before[1].key)
    expect(moved[1].description).to.equal("svc#" .. loader.store[id].options.id)
    expect(root.reflect.store[before[1].key]).to.equal(nil)

    local otherId = loader:create({ name = "other" }):await()
    started(loader, otherId)
    local other = find(slots(root, "svc"), function(slot)
      return slot.tag == "other"
    end)
    expect(other and other.key).to.equal(before[1].key)

    cordis.await(loader.store[id].innerFiber:dispose())
    local left = slots(root, "svc")
    expect(some(left, function(slot)
      return slot.impl == before[1].impl
    end)).to.equal(false)
    expect(some(left, function(slot)
      return slot.impl == other.impl
    end)).to.equal(true)
  end)

  -- isolate-provide.spec.ts:144
  it("retains a transferred provider until its consumers finish cleanup", function()
    local gate, open = cordis.Future.withResolvers(U.host())
    local timeline = {}
    local root, loader = boot({
      provider = function(ctx, config)
        ctx:provide("svc", { tag = config.tag })
        return function()
          table.insert(timeline, "closed: " .. config.tag)
        end
      end,
      consumer = {
        function(ctx)
          return cordis.async(function()
            gate:await()
            table.insert(timeline, "read: " .. ctx.svc.tag)
          end)
        end,
        inject = { "svc" },
      },
    })
    local id = loader:create({ name = "provider", config = { tag = "moved" } }):await()
    local provider = started(loader, id)
    local original = slots(root, "svc")[1]
    local uid = original.impl.uid
    loader:update(id, { isolate = { svc = "B" } }):await()
    local moved = slots(root, "svc")[1]
    expect(moved.impl).to.equal(original.impl)
    expect(moved.impl.uid).to.equal(uid)

    local otherId = loader:create({ name = "provider", config = { tag = "other" } }):await()
    started(loader, otherId)
    local other = find(slots(root, "svc"), function(slot)
      return slot.tag == "other"
    end)
    expect(other.key).to.equal(original.key)
    local consumerId = loader:create({ name = "consumer", isolate = { svc = "B" } }):await()
    started(loader, consumerId)

    local task = provider:dispose()
    setImmediate()
    local duringCleanup = table.move(timeline, 1, #timeline, 1, {})
    open()
    cordis.await(task)
    loader:await():await()
    expect(duringCleanup).to.deep.equal({})
    expect(timeline).to.deep.equal({ "read: moved", "closed: moved" })
    expect(root.reflect.store[moved.key]).to.equal(nil)
    expect(root.reflect.store[other.key]).to.equal(other.impl)
    expect(loader:expectFiber(consumerId).state).to.equal(FiberState.PENDING)
    cordis.await(root.fiber:dispose())
  end)

  -- isolate-provide.spec.ts:187
  it("keeps impls on intermediate symbols across repeated transfers", function()
    local calls = 0
    local root, loader = boot({
      prov = function(ctx)
        calls = calls + 1
        ctx:provide("svc", { tag = "prov" })
      end,
      rootUser = function(ctx)
        ctx:provide("svc", { tag = "rootUser" })
      end,
      keep = function() end,
      onA = function(ctx)
        ctx:provide("svc", { tag = "onA" })
      end,
    })

    local id = loader:create({ name = "prov" }):await()
    started(loader, id)
    local rootSlot = slots(root, "svc")[1]
    local original = rootSlot.impl

    loader:update(id, { isolate = { svc = "A" } }):await()
    expect(calls).to.equal(1)
    local atA = slots(root, "svc")
    expect(atA).to.have.length(1)
    expect(atA[1].impl).to.equal(original)
    expect(atA[1].key).to.equal(accessGlobal("svc", "A"))
    expect(root.reflect.store[rootSlot.key]).to.equal(nil)

    local rootUserId = loader:create({ name = "rootUser" }):await()
    started(loader, rootUserId)
    local rootUser = find(slots(root, "svc"), function(slot)
      return slot.tag == "rootUser"
    end)
    expect(rootUser and rootUser.key).to.equal(rootSlot.key)

    local keepId = loader:create({ name = "keep", isolate = { svc = "A" } }):await()
    started(loader, keepId)
    loader:update(id, { isolate = { svc = "B" } }):await()
    expect(calls).to.equal(1)
    local atB = find(slots(root, "svc"), function(slot)
      return slot.impl == original
    end)
    expect(atB and atB.key).to.equal(accessGlobal("svc", "B"))
    expect(root.reflect.store[atA[1].key]).to.equal(nil)

    local onAId = loader:create({ name = "onA", isolate = { svc = "A" } }):await()
    started(loader, onAId)
    local onA = find(slots(root, "svc"), function(slot)
      return slot.tag == "onA"
    end)
    expect(onA and onA.key).to.equal(atA[1].key)

    loader:update(id, { isolate = { svc = "C" } }):await()
    expect(calls).to.equal(1)
    local atC = find(slots(root, "svc"), function(slot)
      return slot.impl == original
    end)
    expect(atC and atC.key).to.equal(accessGlobal("svc", "C"))

    cordis.await(loader.store[id].innerFiber:dispose())
    local left = slots(root, "svc")
    expect(some(left, function(slot)
      return slot.impl == original
    end)).to.equal(false)
    expect(some(left, function(slot)
      return slot.impl == rootUser.impl
    end)).to.equal(true)
    expect(some(left, function(slot)
      return slot.impl == onA.impl
    end)).to.equal(true)
  end)

  -- isolate-provide.spec.ts:246
  it("does not delete another realm when one impl is transferred", function()
    local calls = 0
    local root, loader = boot({
      stay = function(ctx)
        ctx:provide("svc", { tag = "stay" })
      end,
      move = function(ctx)
        calls = calls + 1
        ctx:provide("svc", { tag = "move" })
      end,
    })

    local stayId = loader:create({ name = "stay", isolate = { svc = "stay" } }):await()
    local moveId = loader:create({ name = "move", isolate = { svc = "from" } }):await()
    started(loader, stayId)
    started(loader, moveId)
    local stay = find(slots(root, "svc"), function(slot)
      return slot.tag == "stay"
    end)
    local move = find(slots(root, "svc"), function(slot)
      return slot.tag == "move"
    end)
    expect(stay.key).to.equal(accessGlobal("svc", "stay"))
    expect(move.key).to.equal(accessGlobal("svc", "from"))

    loader:update(moveId, { isolate = { svc = "to" } }):await()
    expect(calls).to.equal(1)
    local moved = find(slots(root, "svc"), function(slot)
      return slot.impl == move.impl
    end)
    local stayAfter = find(slots(root, "svc"), function(slot)
      return slot.impl == stay.impl
    end)
    expect(moved and moved.key).to.equal(accessGlobal("svc", "to"))
    expect(moved and moved.key).never.to.equal(move.key)
    expect(stayAfter and stayAfter.key).to.equal(stay.key)

    cordis.await(loader.store[moveId].innerFiber:dispose())
    local left = slots(root, "svc")
    expect(some(left, function(slot)
      return slot.impl == stay.impl
    end)).to.equal(true)
    expect(some(left, function(slot)
      return slot.impl == move.impl
    end)).to.equal(false)
  end)

  -- isolate-provide.spec.ts:281 (rewritten: an `undefined` service value is recorded as `cordis.null`, as a list cannot hold nil)
  it("reports the service of each realm when a provider is transferred", function()
    local root, loader = boot({
      prov = function(ctx)
        ctx:provide("svc", { tag = "prov" })
      end,
    })
    local id = loader:create({ name = "prov" }):await()
    started(loader, id)

    local outside, inside = {}, {}
    local function tagOf(value)
      return type(value) == "table" and value.tag or cordis.null
    end
    root:on("internal/service", function(_, name, value)
      if name == "svc" then
        table.insert(outside, tagOf(value))
      end
    end)
    root:isolate("svc", accessGlobal("svc", "A")):on("internal/service", function(_, name, value)
      if name == "svc" then
        table.insert(inside, tagOf(value))
      end
    end)
    loader:update(id, { isolate = { svc = "A" } }):await()
    expect(root:get("svc")).to.equal(nil)
    expect(outside).to.deep.equal({ cordis.null })
    expect(inside).to.deep.equal({ "prov" })
  end)

  -- isolate-provide.spec.ts:304
  it("keeps a provider pinned by an isolated context when its entry is transferred", function()
    local inner
    local consumer = {
      inject = { "svc" },
      apply = function(ctx)
        inner = ctx.fiber
      end,
    }
    local root, loader = boot({
      prov = function(ctx)
        local pinned = ctx:isolate("svc", accessGlobal("svc", "A"))
        pinned:provide("svc", { tag = "pinned" })
        pinned:plugin(consumer)
      end,
      outer = { function() end, inject = { "svc" } },
    })

    local id = loader:create({ name = "prov", isolate = { svc = "A" } }):await()
    started(loader, id)
    local outerId = loader:create({ name = "outer", isolate = { svc = "B" } }):await()
    inner:await():await()
    expect(inner.state).to.equal(FiberState.ACTIVE)

    loader:update(id, { isolate = { svc = "B" } }):await()
    loader:await():await()
    local pinned = root.reflect.store[accessGlobal("svc", "A")]
    expect(pinned and pinned.value.tag).to.equal("pinned")
    expect(root.reflect.store[accessGlobal("svc", "B")]).to.equal(nil)
    expect(inner.state).to.equal(FiberState.ACTIVE)
    expect(loader:expectFiber(outerId).state).to.equal(FiberState.PENDING)
  end)

  -- isolate-provide.spec.ts:332 (rewritten: an `undefined` service value is recorded as `cordis.null`, as a list cannot hold nil)
  local function notifies(mode)
    return function()
      local gate, open = cordis.Future.withResolvers(U.host())
      local disposers, consumers = {}, {}
      local starts, stops = {}, {}
      local root, loader = boot({
        provider = function(ctx, config)
          disposers[config.tag] = ctx:provide("svc", { tag = config.tag })
        end,
        consumer = {
          function(ctx, config)
            consumers[config.tag] = ctx
            table.insert(starts, ctx.svc.tag)
            return cordis.async(function()
              gate:await()
              table.insert(stops, ctx.svc.tag)
            end)
          end,
          inject = { "svc" },
        },
      })
      local first = loader:create({ name = "provider", config = { tag = "first" }, isolate = { svc = "A" } }):await()
      local second = loader:create({ name = "provider", config = { tag = "second" }, isolate = { svc = "B" } }):await()
      local ca = loader:create({ name = "consumer", config = { tag = "A" }, isolate = { svc = "A" } }):await()
      local cb = loader:create({ name = "consumer", config = { tag = "B" }, isolate = { svc = "B" } }):await()
      for _, id in ipairs({ first, second, ca, cb }) do
        started(loader, id)
      end
      local a = find(slots(root, "svc"), function(slot)
        return slot.tag == "first"
      end)
      local b = find(slots(root, "svc"), function(slot)
        return slot.tag == "second"
      end)

      loader:update(first, { isolate = { svc = "B" } }):await()
      expect(root.reflect.store[a.key]).to.equal(a.impl)
      expect(root.reflect.store[b.key]).to.equal(b.impl)
      expect(loader:expectFiber(first).ctx.svc.tag).to.equal("first")
      expect(starts).to.deep.equal({ "first", "second" })
      expect(stops).to.deep.equal({})

      local eventsA, eventsB = {}, {}
      local function tagOf(value)
        return type(value) == "table" and value.tag or cordis.null
      end
      root:isolate("svc", a.key):on("internal/service", function(_, name, value)
        if name == "svc" then
          table.insert(eventsA, tagOf(value))
        end
      end)
      root:isolate("svc", b.key):on("internal/service", function(_, name, value)
        if name == "svc" then
          table.insert(eventsB, tagOf(value))
        end
      end)
      local completed = false
      local result
      if mode == "fiber" then
        result = loader:expectFiber(first):dispose()
      else
        result = disposers.first()
      end
      local task = cordis.Future.resolve(U.host(), result):next(function()
        completed = true
      end)
      setImmediate()
      local completedDuringCleanup = completed
      open()
      task:await()
      loader:await():await()
      expect(completedDuringCleanup).to.equal(false)
      expect(stops).to.deep.equal({ "first" })
      expect(loader:expectFiber(ca).state).to.equal(FiberState.PENDING)
      expect(function()
        return consumers.A.svc
      end).to.throw("inactive context")
      expect(loader:expectFiber(cb).state).to.equal(FiberState.ACTIVE)
      expect(consumers.B.svc.tag).to.equal("second")
      expect(root.reflect.store[a.key]).to.equal(nil)
      expect(root.reflect.store[b.key]).to.equal(b.impl)
      expect(eventsA).to.deep.equal(mode == "fiber" and { "first", cordis.null } or { cordis.null })
      expect(eventsB).to.deep.equal({})

      local replacement =
        loader:create({ name = "provider", config = { tag = "replacement" }, isolate = { svc = "A" } }):await()
      started(loader, replacement)
      loader:await():await()
      expect(loader:expectFiber(ca).state).to.equal(FiberState.ACTIVE)
      expect(consumers.A.svc.tag).to.equal("replacement")
      expect(starts).to.deep.equal({ "first", "second", "replacement" })
      expect(stops).to.deep.equal({ "first" })
      expect(loader:expectFiber(cb).state).to.equal(FiberState.ACTIVE)
      expect(consumers.B.svc.tag).to.equal("second")
      expect(eventsB).to.deep.equal({})
    end
  end
  it("notifies the retained realm on fiber disposal after a blocked transfer", notifies("fiber"))
  it("notifies the retained realm on provide disposal after a blocked transfer", notifies("provide"))
end)
