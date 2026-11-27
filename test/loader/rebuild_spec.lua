-- Ported from cordis packages/loader/tests/rebuild.spec.ts (MIT, (c) Shigma)
local cordis = require("cordis")
local L = require("cordis.loader")
local T = require("loader.mock_loader")
local U = require("kit.util")

local FiberState = cordis.FiberState
local Entry = L.Entry
local Future = cordis.Future
local sleep = T.sleep

local function hasDisabledChange(changes)
  for _, change in ipairs(changes) do
    if change.options and change.options.disabled then
      return true
    end
  end
  return false
end

local function activeFibers(loader, component)
  local count = 0
  for _, fiber in ipairs(loader.ctx.registry:get(component).fibers:values()) do
    if fiber.state == FiberState.ACTIVE then
      count = count + 1
    end
  end
  return count
end

-- replace `Entry:_patchContext` (vi.spyOn on the prototype) for one case
local function spyPatch(impl)
  local patch = Entry._patchContext
  Entry._patchContext = function(self, diff)
    return impl(self, diff, patch)
  end
  return function()
    Entry._patchContext = patch
  end
end

describe("Loader: entry rebuild", function()
  local loader, a, b, c
  local disposeA = function() end

  before_all(function()
    local _
    _, loader = T.setup()
    loader:mock("settings", function(ctx)
      ctx:provide("settings", {})
    end)
    a = loader:mock("a", function()
      return function()
        return disposeA()
      end
    end)
    b = loader:mock("b", function() end)
    c = loader:mock("c", function() end)
  end)

  before_each(function()
    loader:read({}):await()
    for _, fn in ipairs({ a, b, c }) do
      fn:reset()
    end
    disposeA = function() end
    loader.changes = {}
  end)

  -- a file reload replays the options through the group
  local function replay(name, inject)
    return loader.root:update({ { id = "settings", name = "settings" }, { id = "x", name = name, inject = inject } })
  end

  -- rebuild.spec.ts:45
  local function rebuildsOnRename(inject)
    return function()
      loader:read({ { id = "settings", name = "settings" }, { id = "x", name = "a", inject = inject } }):await()
      local previous = loader.store.x.innerFiber

      replay("b", inject):await()
      loader:await():await()
      expect(previous.uid).to.equal(nil)
      expect(loader.store.x.innerFiber.state).to.equal(FiberState.ACTIVE)
      expect(a).to.have.length(1)
      expect(b).to.have.length(1)
      expect(loader.store.x.options.disabled).to.equal(nil)
      expect(hasDisabledChange(loader.changes)).to.equal(false)
    end
  end
  it("rebuilds an active entry when its name changes (inject=undefined)", rebuildsOnRename(nil))
  it("rebuilds an active entry when its name changes (inject=['settings'])", rebuildsOnRename({ "settings" }))

  -- rebuild.spec.ts:59 (rewritten: `vi.spyOn(Entry.prototype, '_patchContext')`
  -- replaces the class method for the duration of the case)
  local function usesNewName(window)
    return function()
      local host = U.host()
      local promise, resolve = Future.withResolvers(host)
      local entered, enter = Future.withResolvers(host)
      local original = loader.import
      local stop
      if window == "import" then
        -- the old name fails to import, as when the rename fixes a wrong name
        loader.import = cordis.async(function(self, name)
          if name == "a" then
            enter()
            promise:await()
            error(cordis.Error.new("cannot find module a"), 0)
          end
          return original(self, name):await()
        end)
      else
        stop = spyPatch(function(self, diff, patch)
          return cordis.future.AsyncFunction.spawn(
            cordis.async(function()
              if self.options.name == "a" then
                enter()
                promise:await()
              end
              return patch(self, diff):await()
            end),
            host
          )
        end)
      end
      local ok, err = pcall(function()
        local creating = loader.root:update({ { id = "x", name = "a" } })
        entered:await()
        local updating = loader.root:update({ { id = "x", name = "b" } })
        resolve()
        Future.all(host, { creating, updating }):await()
        loader:await():await()
      end)
      loader.import = nil
      if stop then
        stop()
      end
      if not ok then
        error(err, 0)
      end
      expect(a).to.have.length(0)
      expect(b).to.have.length(1)
    end
  end
  it("uses the new name when it changes during the import", usesNewName("import"))
  it("uses the new name when it changes during the patch", usesNewName("patch"))

  -- rebuild.spec.ts:101
  local function joinsSecondRename(inject)
    return function()
      local host = U.host()
      local held, release = Future.withResolvers(host)
      local entered, enter = Future.withResolvers(host)
      disposeA = function()
        enter()
        return held
      end
      loader:read({ { id = "settings", name = "settings" }, { id = "x", name = "a", inject = inject } }):await()

      local first = replay("b", inject)
      entered:await()
      local second = replay("c", inject)
      release()
      Future.all(host, { first, second }):await()
      loader:await():await()
      expect(b).to.have.length(0)
      expect(c).to.have.length(1)
      expect(loader.store.x.innerFiber.state).to.equal(FiberState.ACTIVE)
    end
  end
  it("joins a second rename while the first disposal is pending (inject=undefined)", joinsSecondRename(nil))
  it(
    "joins a second rename while the first disposal is pending (inject=['settings'])",
    joinsSecondRename({ "settings" })
  )

  -- rebuild.spec.ts:121
  it("applies nothing when the entry is removed during the disposal", function()
    local host = U.host()
    local held, release = Future.withResolvers(host)
    local entered, enter = Future.withResolvers(host)
    disposeA = function()
      enter()
      return held
    end
    loader:read({ { id = "settings", name = "settings" }, { id = "x", name = "a", inject = { "settings" } } }):await()
    local entry = loader.store.x

    local renaming = replay("b", { "settings" })
    entered:await()
    loader:remove("x")
    release()
    renaming:await()
    loader:await():await()
    sleep()
    expect(b).to.have.length(0)
    expect(entry.outerFiber).to.equal(nil)
    expect(entry.innerFiber and entry.innerFiber.uid).to.equal(nil)
  end)

  -- rebuild.spec.ts:143
  it("rebuilds when the component renames its own entry", function()
    local held, release = Future.withResolvers(U.host())
    local renaming = loader:mock("renaming", function()
      loader:update("x", { name = "b" })
      return function()
        return held
      end
    end)
    loader.root:update({ { id = "x", name = "renaming" } })
    sleep()
    -- the rebuild is a task until the old instance is disposed
    expect(#loader:getTasks() > 0).to.equal(true)
    expect(b).to.have.length(0)
    release()
    loader:await():await()
    expect(renaming).to.have.length(1)
    expect(b).to.have.length(1)
    expect(loader.store.x.innerFiber.state).to.equal(FiberState.ACTIVE)
  end)
end)

describe("Loader: active entry rebuild (#218)", function()
  -- rebuild.spec.ts:163
  it("starts a pending entry when inject is cleared", function()
    local _, loader = T.setup()
    local plug = loader:mock("plug", function() end)

    local id = loader:create({ name = "plug", inject = { "never" } }):await()
    sleep()
    local old = loader.store[id].outerFiber
    expect(old.state).to.equal(FiberState.PENDING)
    expect(loader.store[id].innerFiber).to.equal(nil)
    expect(plug).to.have.length(0)

    loader.changes = {}
    loader:update(id, { inject = cordis.null }):await()
    sleep()

    local nextFiber = loader:expectFiber(id)
    expect(nextFiber.state).to.equal(FiberState.ACTIVE)
    expect(nextFiber).never.to.equal(old)
    expect(old.state).to.equal(FiberState.DISPOSED)
    expect(plug).to.have.length(1)
    expect(loader.store[id].options.inject).to.equal(nil)
    expect(loader.store[id].options.disabled).to.equal(nil)
    for _, change in ipairs(loader.changes) do
      expect(change.options and change.options.disabled == true).never.to.equal(true)
    end
  end)

  -- rebuild.spec.ts:190
  it("reapplies when inject gains a service that is already provided", function()
    local root, loader = T.setup()
    root:provide("foo", { n = 1 })
    local reads = {}
    local applied = 0
    local plug = loader:mock("plug", function(ctx)
      applied = applied + 1
      if applied == 2 then
        table.insert(reads, ctx.foo)
      end
    end)

    local id = loader:create({ name = "plug" }):await()
    sleep()
    local old = loader:expectFiber(id)
    expect(old.state).to.equal(FiberState.ACTIVE)
    expect(plug).to.have.length(1)

    loader:update(id, { inject = { "foo" } }):await()
    sleep()

    expect(plug).to.have.length(2)
    expect(reads).to.deep.equal({ { n = 1 } })
    expect(old.state).to.equal(FiberState.DISPOSED)
    expect(loader:expectFiber(id)).never.to.equal(old)
    expect(loader.store[id].options.disabled).to.equal(nil)
  end)

  -- rebuild.spec.ts:217
  it("keeps the new outer fiber pending and drops the old listener when inject is missing", function()
    local root, loader = T.setup()
    local ping = cordis.symbol("rebuild")
    local hits = 0
    loader:mock("plug", function(ctx)
      ctx:on(ping, function()
        hits = hits + 1
      end)
    end)

    local id = loader:create({ name = "plug" }):await()
    sleep()
    local old = loader:expectFiber(id)
    expect(old.state).to.equal(FiberState.ACTIVE)
    root:emit(ping)
    expect(hits).to.equal(1)

    loader:update(id, { inject = { "foo" } }):await()
    sleep()

    expect(old.state).to.equal(FiberState.DISPOSED)
    expect(loader.store[id].outerFiber.state).to.equal(FiberState.PENDING)
    expect(loader.store[id].innerFiber.uid).to.equal(nil)
    root:emit(ping)
    expect(hits).to.equal(1)
    expect(loader.store[id].options.disabled).to.equal(nil)
  end)

  -- rebuild.spec.ts:247
  it("joins a second inject update while the first rebuild is disposing", function()
    local root = U.root()
    root:provide("foo", { n = 1 })
    root:provide("bar", { n = 2 })
    cordis.await(root:use(T.MockLoader))
    local loader = root.loader
    local gate, release = Future.withResolvers(U.host())
    local applies = 0
    local plug = loader:mock("plug", function()
      applies = applies + 1
      return cordis.async(function()
        gate:await()
      end)
    end)

    local id = loader:create({ name = "plug" }):await()
    sleep()
    expect(applies).to.equal(1)

    local first = loader:update(id, { inject = { "foo" } })
    local second = loader:update(id, { inject = { "bar" } })
    sleep()
    expect(#loader:getTasks() > 0).to.equal(true)
    expect(applies).to.equal(1)

    release()
    first:await()
    second:await()
    sleep()

    expect(applies).to.equal(2)
    expect(loader.store[id].options.inject).to.deep.equal({ "bar" })
    expect(activeFibers(loader, plug)).to.equal(1)
    expect(loader:expectFiber(id).state).to.equal(FiberState.ACTIVE)
    expect(loader.store[id].options.disabled).to.equal(nil)
  end)

  -- rebuild.spec.ts:284 (rewritten: `vi.spyOn(Entry.prototype, '_patchContext')`
  -- replaces the class method for the duration of the case)
  local function usesLatestName(stage)
    return function()
      local host = U.host()
      local _, loader = T.setup()
      loader:mock("a", function() end)
      local b = loader:mock("b", function() end)
      local c = loader:mock("c", function() end)
      loader:read({ { id = "x", name = "a" } }):await()

      local entered, enter = Future.withResolvers(host)
      local gate, open = Future.withResolvers(host)
      local load = loader.import
      loader.import = cordis.async(function(self, name)
        if name == "b" and stage ~= "context patch" then
          enter()
          gate:await()
          if stage == "failed import" then
            error(cordis.Error.new("superseded import"), 0)
          end
        end
        return load(self, name):await()
      end)
      local stop = spyPatch(function(self, diff, patch)
        return cordis.future.AsyncFunction.spawn(
          cordis.async(function()
            patch(self, diff):await()
            if self.options.name ~= "b" or stage ~= "context patch" then
              return
            end
            enter()
            gate:await()
          end),
          host
        )
      end)

      local ok, err = pcall(function()
        local first = loader.root:update({ { id = "x", name = "b" } })
        entered:await()
        local second = loader.root:update({ { id = "x", name = "c" } })
        expect(#loader:getTasks() > 0).to.equal(true)
        open()
        Future.all(host, { first, second }):await()
        loader:await():await()
      end)
      stop()
      if not ok then
        error(err, 0)
      end

      expect(loader.store.x.options.name).to.equal("c")
      expect(b).to.have.length(0)
      expect(c).to.have.length(1)
      expect(loader.store.x.innerFiber.runtime.callback).to.equal(c)
      expect(loader.store.x.options.disabled).to.equal(nil)
    end
  end
  it("uses the latest name during a pending import", usesLatestName("import"))
  it("uses the latest name during a pending failed import", usesLatestName("failed import"))
  it("uses the latest name during a pending context patch", usesLatestName("context patch"))

  -- rebuild.spec.ts:332
  it("does not apply a fiber removed while rebuild is disposing", function()
    local root = U.root()
    root:provide("foo", { n = 1 })
    cordis.await(root:use(T.MockLoader))
    local loader = root.loader
    local gate, release = Future.withResolvers(U.host())
    local applies = 0
    local plug = loader:mock("plug", function()
      applies = applies + 1
      return cordis.async(function()
        gate:await()
      end)
    end)

    local id = loader:create({ name = "plug" }):await()
    sleep()
    local pending = loader:update(id, { inject = { "foo" } })
    sleep()
    loader:remove(id)
    release()
    pending:await()
    sleep()

    expect(applies).to.equal(1)
    expect(loader.store[id]).to.equal(nil)
    expect(loader.ctx.registry:get(plug)).to.equal(nil)
  end)

  -- rebuild.spec.ts:359
  it("keeps a rebuild started during apply until its disposer settles", function()
    local root = U.root()
    root:provide("foo", { n = 1 })
    root:provide("bar", { n = 2 })
    root:provide("qux", { n = 3 })
    cordis.await(root:use(T.MockLoader))
    local loader = root.loader
    local gate, release = Future.withResolvers(U.host())
    local applies = 0
    local id = ""
    local plug = loader:mock("plug", function()
      applies = applies + 1
      local n = applies
      if n == 2 then
        loader:update(id, { inject = { "bar" } })
      end
      return cordis.async(function()
        if n == 2 then
          gate:await()
        end
      end)
    end)

    id = loader:create({ name = "plug" }):await()
    sleep()
    loader:update(id, { inject = { "foo" } }):await()
    sleep()

    expect(#loader:getTasks() > 0).to.equal(true)
    local idle = false
    local waiting = loader:await():next(function()
      idle = true
    end)
    sleep()
    expect(idle).to.equal(false)
    expect(applies).to.equal(2)

    local third = loader:update(id, { inject = { "qux" } })
    sleep()
    expect(applies).to.equal(2)

    release()
    third:await()
    waiting:await()
    sleep()

    expect(applies).to.equal(3)
    expect(loader.store[id].options.inject).to.deep.equal({ "qux" })
    expect(activeFibers(loader, plug)).to.equal(1)
    expect(loader.store[id].options.disabled).to.equal(nil)
  end)
end)
