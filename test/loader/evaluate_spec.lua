-- Ported from cordis packages/loader/tests/evaluate.spec.ts (MIT, (c) Shigma)
--
-- Expressions are Lua: `!x` is `not x`, `a && b` is `a and b`, `+` on
-- strings is `..`, and `x++` becomes a call to the service's `bump` method.
local cordis = require("cordis")
local L = require("cordis.loader")
local T = require("loader.mock_loader")
local U = require("kit.util")

local FiberState = cordis.FiberState
local Context = function()
  return cordis.Context
end
local Entry = L.Entry
local plain, keys = T.plain, T.keys

-- `{ ...t }`; spreading `undefined` gives `{}`
local function copy(t)
  local r = {}
  for k, v in pairs(t or {}) do
    r[k] = v
  end
  return r
end

local function expr(source)
  return { __luaExpr = source }
end

describe("Loader: entry evaluation context", function()
  local root, loader, worker, needy
  local seen = {}

  before_all(function()
    root, loader = T.setup()
    loader:mock("settings", function(ctx, config)
      ctx:provide("settings", copy(config))
    end)
    loader:mock("env", function(ctx, config)
      ctx:provide("env", copy(config))
    end)
    worker = loader:mock("worker", function(ctx)
      seen = { intercept = ctx[Context().intercept], inject = ctx.fiber.inject }
    end)
    needy = loader:mock("needy", function() end)
    needy.inject = { "http" }
  end)

  before_each(function()
    loader:read({}):await()
    worker:reset()
    needy:reset()
    seen = {}
  end)

  local function settings(config)
    return { id = "settings", name = "settings", config = config }
  end

  -- evaluate.spec.ts:39
  it("creates no outer fiber for an entry without inject", function()
    loader:read({ { id = "worker", name = "worker", disabled = expr("false") } }):await()

    local entry = loader.store.worker
    expect(entry.outerFiber).to.equal(nil)
    expect(entry.innerFiber.state).to.equal(FiberState.ACTIVE)
    expect(worker).to.have.length(1)
  end)

  -- evaluate.spec.ts:48
  it("nests the inner fiber under the outer fiber", function()
    loader:read({ settings({}), { id = "worker", name = "worker", inject = { "settings" } } }):await()

    local entry = loader.store.worker
    expect(entry.innerFiber.parent.fiber.uid).to.equal(entry.outerFiber.uid)
    expect(keys(entry.outerFiber.inject)).to.deep.equal({ "settings" })
    expect(keys(entry.innerFiber.inject)).to.deep.equal({})
    expect(entry.innerFiber.ctx[Entry.key]).to.equal(entry)
    expect(entry.outerFiber.entry).to.equal(nil)
    expect(entry.innerFiber.entry).to.equal(nil)
  end)

  -- evaluate.spec.ts:63
  it("evaluates disabled with the entry inject", function()
    loader
      :read({
        settings({ enabled = false }),
        { id = "worker", name = "worker", inject = { "settings" }, disabled = expr("not settings.enabled") },
      })
      :await()

    local entry = loader.store.worker
    expect(entry.disabled).to.equal(true)
    expect(entry.outerFiber.state).to.equal(FiberState.ACTIVE)
    expect(entry.innerFiber).to.equal(nil)
    expect(worker).to.have.length(0)

    loader:update("settings", { config = { enabled = true } }):await()
    loader:await():await()
    expect(entry.disabled).to.equal(false)
    expect(worker).to.have.length(1)
  end)

  -- evaluate.spec.ts:83
  it("decides disabled before the component dependencies", function()
    loader
      :read({
        settings({ enabled = false }),
        { id = "needy", name = "needy", inject = { "settings" }, disabled = expr("not settings.enabled") },
      })
      :await()

    local entry = loader.store.needy
    expect(entry.outerFiber.state).to.equal(FiberState.ACTIVE)
    expect(entry.innerFiber).to.equal(nil)

    loader:update("settings", { config = { enabled = true } }):await()
    loader:await():await()
    expect(entry.innerFiber.state).to.equal(FiberState.PENDING)
  end)

  -- evaluate.spec.ts:100
  it("waits for the entry inject while it is missing", function()
    loader
      :read({ { id = "worker", name = "worker", inject = { "settings" }, disabled = expr("not settings.enabled") } })
      :await()

    local entry = loader.store.worker
    expect(entry.outerFiber.state).to.equal(FiberState.PENDING)
    expect(entry.disabled).to.equal(true)

    loader:create(settings({ enabled = true })):await()
    loader:await():await()
    expect(entry.disabled).to.equal(false)
    expect(worker).to.have.length(1)
  end)

  -- evaluate.spec.ts:118
  it("treats a failing expression as disabled", function()
    loader
      :read({
        settings({}),
        { id = "worker", name = "worker", inject = { "settings" }, disabled = expr("settings.missing.value") },
      })
      :await()

    expect(loader.store.worker.innerFiber).to.equal(nil)
    expect(worker).to.have.length(0)
  end)

  -- evaluate.spec.ts:130
  it("evaluates inject values in the parent context", function()
    local inject = { settings = { namespace = expr("env.namespace") } }
    loader
      :read({
        { id = "env", name = "env", config = { namespace = "ns" } },
        settings({}),
        {
          id = "group",
          name = "@cordisjs/group",
          group = true,
          inject = { "env" },
          config = { { id = "worker", name = "worker", inject = inject } },
        },
      })
      :await()

    local entry = loader.store.worker
    expect(plain(entry.inject)).to.deep.equal({ settings = { namespace = "ns" } })
    expect(plain(entry.outerFiber.inject)).to.deep.equal({ settings = { namespace = "ns" } })
    expect(entry.options.inject).to.deep.equal(inject)
    expect(worker).to.have.length(1)
  end)

  -- evaluate.spec.ts:147
  it("cannot read the entry inject from an inject value", function()
    loader
      :read({
        settings({ namespace = "ns" }),
        { id = "worker", name = "worker", inject = { settings = true, other = expr("settings.namespace") } },
      })
      :await()

    local entry = loader.store.worker
    expect(entry.outerFiber).to.equal(nil)
    expect(entry.innerFiber).to.equal(nil)
    expect(worker).to.have.length(0)
  end)

  -- evaluate.spec.ts:160
  it("keeps an inject value on the outer fiber when the component declares the service itself", function()
    local own = loader:mock("own", function() end)
    own.inject = { settings = { own = 1 } }
    loader:read({ settings({}), { id = "own", name = "own", inject = { settings = { namespace = "ns" } } } }):await()

    local entry = loader.store.own
    expect(own).to.have.length(1)
    expect(plain(entry.outerFiber.inject)).to.deep.equal({ settings = { namespace = "ns" } })
    -- the component keeps its own declaration; the entry configures it through `intercept`
    expect(plain(entry.innerFiber.inject)).to.deep.equal({ settings = { own = 1 } })
  end)

  -- evaluate.spec.ts:175
  it("evaluates intercept with the entry inject, for the component only", function()
    loader
      :read({
        settings({ proxy = "p1" }),
        {
          id = "worker",
          name = "worker",
          inject = { "settings" },
          intercept = { http = { proxy = expr("settings.proxy") } },
        },
      })
      :await()

    local entry = loader.store.worker
    expect(seen.intercept.http).to.deep.equal({ proxy = "p1" })
    expect(entry.outerFiber.ctx[Context().intercept].http).to.equal(nil)
    expect(entry.options.intercept).to.deep.equal({ http = { proxy = expr("settings.proxy") } })
  end)

  -- evaluate.spec.ts:189
  it("updates intercept in place", function()
    loader
      :read({
        settings({ proxy = "p1" }),
        {
          id = "worker",
          name = "worker",
          inject = { "settings" },
          intercept = { http = { proxy = expr("settings.proxy") } },
        },
      })
      :await()
    local tbl = seen.intercept

    loader:update("worker", { intercept = { http = { proxy = expr('settings.proxy .. "!"') } } }):await()
    expect(tbl.http).to.deep.equal({ proxy = "p1!" })
    loader:update("worker", { intercept = cordis.null }):await()
    expect(tbl.http).to.equal(nil)
    expect(worker).to.have.length(1)
  end)

  -- evaluate.spec.ts:205
  it("keeps the options when a dependency is lost and recovered", function()
    loader
      :read({
        settings({ enabled = true }),
        { id = "worker", name = "worker", inject = { "settings" }, disabled = expr("not settings.enabled") },
      })
      :await()
    local entry = loader.store.worker
    local outer = entry.outerFiber
    local inner = entry.innerFiber

    loader:remove("settings")
    loader:await():await()
    expect(inner.uid).to.equal(nil)
    expect(entry.outerFiber).to.equal(outer)
    expect(entry.options.disabled).to.deep.equal(expr("not settings.enabled"))

    loader:create(settings({ enabled = true })):await()
    loader:await():await()
    expect(entry.innerFiber.state).to.equal(FiberState.ACTIVE)
    expect(worker).to.have.length(2)
  end)

  -- evaluate.spec.ts:228
  it("reloads the outer fiber when the verdict changes", function()
    loader
      :read({
        settings({ enabled = true }),
        { id = "worker", name = "worker", inject = { "settings" }, disabled = expr("not settings.enabled") },
      })
      :await()
    local entry = loader.store.worker
    local outer = entry.outerFiber

    loader:update("worker", { disabled = expr("settings.enabled") }):await()
    expect(entry.innerFiber.uid).to.equal(nil)
    expect(entry.outerFiber).to.equal(outer)

    -- same verdict, no reload
    loader:update("worker", { disabled = expr("not settings.enabled") }):await()
    loader:update("worker", { disabled = expr("settings.enabled and false") }):await()
    expect(entry.innerFiber.uid).never.to.equal(nil)
    expect(worker).to.have.length(2)
  end)

  -- evaluate.spec.ts:249
  it("rebuilds the entry when inject changes", function()
    loader
      :read({ settings({}), { id = "env", name = "env" }, { id = "worker", name = "worker", inject = { "settings" } } })
      :await()
    local entry = loader.store.worker
    local outer = entry.outerFiber

    loader:update("worker", { inject = { "settings", "env" } }):await()
    loader:await():await()
    expect(outer.uid).to.equal(nil)
    expect(keys(entry.outerFiber.inject)).to.deep.equal({ "settings", "env" })

    loader:update("worker", { inject = cordis.null }):await()
    loader:await():await()
    expect(entry.outerFiber).to.equal(nil)
    expect(Entry.isOuter(entry.innerFiber.parent.fiber)).to.equal(false)
    expect(worker).to.have.length(3)
  end)

  -- evaluate.spec.ts:270
  it("disposes the outer fiber when the component disposes itself", function()
    loader:read({ settings({}), { id = "worker", name = "worker", inject = { "settings" } } }):await()
    local entry = loader.store.worker
    local outer = entry.outerFiber

    cordis.await(entry.innerFiber:dispose())
    loader:await():await()
    expect(entry.options.disabled).to.equal(true)
    expect(outer.uid).to.equal(nil)
    expect(entry.outerFiber).to.equal(nil)
  end)

  -- evaluate.spec.ts:286
  it("disposes both fibers when the entry is removed", function()
    loader:read({ settings({}), { id = "worker", name = "worker", inject = { "settings" } } }):await()
    local entry = loader.store.worker
    local outerFiber, innerFiber = entry.outerFiber, entry.innerFiber

    loader:remove("worker")
    loader:await():await()
    expect(outerFiber.uid).to.equal(nil)
    expect(innerFiber.uid).to.equal(nil)
  end)

  -- evaluate.spec.ts:301
  it("keeps a group structural and passes its verdict to the children", function()
    loader
      :read({
        settings({ enabled = false }),
        {
          id = "group",
          name = "@cordisjs/group",
          group = true,
          inject = { "settings" },
          disabled = expr("not settings.enabled"),
          config = { { id = "worker", name = "worker" } },
        },
      })
      :await()

    local group = loader.store.group
    expect(group.innerFiber.state).to.equal(FiberState.ACTIVE)
    expect(loader.store.worker.innerFiber).to.equal(nil)

    loader:update("group", { disabled = expr("false") }):await()
    loader:await():await()
    expect(loader.store.worker.innerFiber.state).to.equal(FiberState.ACTIVE)
    expect(group.options.disabled).to.deep.equal(expr("false"))
  end)

  -- evaluate.spec.ts:321
  it("keeps the entry isolate without an inject", function()
    loader
      :read({
        settings({ enabled = true }),
        {
          id = "group",
          name = "@cordisjs/group",
          group = true,
          inject = { "settings" },
          config = {
            {
              id = "worker",
              name = "worker",
              isolate = { settings = "other" },
              disabled = expr("not settings.enabled"),
            },
          },
        },
      })
      :await()

    expect(loader.store.worker.disabled).to.equal(true)
    expect(worker).to.have.length(0)
  end)

  -- evaluate.spec.ts:339
  it("rebuilds without a write-back when inject is added", function()
    loader:read({ settings({}), { id = "worker", name = "worker" } }):await()
    loader.changes = {}

    loader:update("worker", { inject = { "settings" } }):await()
    loader:await():await()
    local entry = loader.store.worker
    expect(entry.options.disabled).to.equal(nil)
    for _, change in ipairs(loader.changes) do
      expect(change.options and change.options.disabled).to.never.be.ok()
    end
    expect(entry.innerFiber.state).to.equal(FiberState.ACTIVE)
    expect(worker).to.have.length(2)
  end)

  -- evaluate.spec.ts:352
  it("drops an activation whose dependency is lost during the import", function()
    loader:read({ settings({}) }):await()
    local host = U.host()
    local promise, resolve = cordis.Future.withResolvers(host)
    local importing, entered = cordis.Future.withResolvers(host)
    local original = loader.import
    local count = 0
    loader.import = cordis.async(function(self, name)
      -- the second import is the outer fiber's
      if name == "worker" then
        count = count + 1
        if count == 2 then
          entered()
          promise:await()
        end
      end
      return original(self, name):await()
    end)
    local ok, err = pcall(function()
      loader:create({ id = "worker", name = "worker", inject = { "settings" } }):await()
      importing:await()
      loader:remove("settings")
      resolve()
      loader:await():await()
    end)
    loader.import = nil
    if not ok then
      error(err, 0)
    end

    expect(worker).to.have.length(0)
    expect(loader.store.worker.outerFiber.state).to.equal(FiberState.PENDING)
  end)

  -- evaluate.spec.ts:380
  it("re-evaluates a failing inject value on refresh", function()
    loader:read({ { id = "worker", name = "worker", inject = { missing = expr("doesNotExist.value") } } }):await()
    loader.store.worker:refresh():await()
    loader:await():await()

    expect(loader.store.worker.innerFiber).to.equal(nil)
    expect(loader.store.worker.disabled).to.equal(true)
    expect(worker).to.have.length(0)
  end)

  -- evaluate.spec.ts:394 (rewritten: the counting getter is a metatable
  -- `__index` on the service table)
  local function caches(group)
    return function()
      loader:read({ settings({ enabled = true }) }):await()
      local reads = 0
      local enabled = true
      local state = root:get("settings")
      state.enabled = nil
      setmetatable(state, {
        __index = function(_, k)
          if k == "enabled" then
            reads = reads + 1
            return enabled
          end
        end,
      })
      loader
        :create({
          id = "owner",
          name = group and "@cordisjs/group" or "worker",
          group = group,
          inject = { "settings" },
          disabled = expr("not settings.enabled"),
          config = group and { { id = "child", name = "worker" }, { id = "sibling", name = "worker" } } or nil,
        })
        :await()
      loader:await():await()
      local owner = loader.store.owner
      local entry = group and loader.store.child or owner
      expect(reads).to.equal(1)

      enabled = false
      for _ = 1, 3 do
        expect(entry.disabled).to.equal(false)
      end
      expect(reads).to.equal(1)
      expect(entry.innerFiber.state).to.equal(FiberState.ACTIVE)

      -- an explicit update re-evaluates; the group itself still runs
      loader:update("owner", { config = owner.options.config }):await()
      loader:await():await()
      expect(entry.disabled).to.equal(true)
      expect(entry.innerFiber.uid).to.equal(nil)
      if group then
        expect(owner.innerFiber.state).to.equal(FiberState.ACTIVE)
      end
    end
  end
  it("caches the verdict independently of reads and service mutations (group=false)", caches(false))
  it("caches the verdict independently of reads and service mutations (group=true)", caches(true))

  -- evaluate.spec.ts:427
  it("does not repeat a failing disabled expression when its verdict is read", function()
    loader
      :read({
        settings({ attempts = 0, bump = T.bump }),
        {
          id = "worker",
          name = "worker",
          inject = { "settings" },
          disabled = expr('settings:bump("attempts") and settings.missing.value'),
        },
      })
      :await()
    for _ = 1, 3 do
      expect(loader.store.worker.disabled).to.equal(true)
    end
    expect(root:get("settings").attempts).to.equal(1)
  end)

  -- evaluate.spec.ts:438
  it("evaluates a changed disabled expression once in either direction", function()
    loader
      :read({
        settings({ count = 0, bump = T.bump }),
        {
          id = "worker",
          name = "worker",
          inject = { "settings" },
          disabled = expr('settings:bump("count") and false'),
        },
      })
      :await()
    local state = root:get("settings")
    local entry = loader.store.worker
    expect(state.count).to.equal(1)

    -- a failing expression disables the component and is reported once
    loader:update("worker", { disabled = expr('settings:bump("count") and settings.missing.value') }):await()
    loader:await():await()
    expect(state.count).to.equal(2)
    expect(entry.innerFiber.uid).to.equal(nil)

    loader:update("worker", { disabled = expr('settings:bump("count") and false') }):await()
    loader:await():await()
    expect(state.count).to.equal(3)
    expect(entry.innerFiber.state).to.equal(FiberState.ACTIVE)
    expect(worker).to.have.length(2)
  end)

  -- evaluate.spec.ts:462
  it("invalidates the verdict before an asynchronous dependency unload", function()
    local host = U.host()
    local entered, enter = cordis.Future.withResolvers(host)
    local released, release = cordis.Future.withResolvers(host)
    local disabledDuringUnload
    loader:mock("held", function(ctx)
      return function()
        disabledDuringUnload = ctx[Entry.key].disabled
        enter()
        return released
      end
    end)
    loader
      :read({
        settings({ enabled = true }),
        { id = "held", name = "held", inject = { "settings" }, disabled = expr("not settings.enabled") },
      })
      :await()
    local entry = loader.store.held
    local outer = entry.outerFiber
    local ok, err = pcall(function()
      loader:remove("settings")
      -- the verdict expires as soon as the outer fiber starts to unload
      expect(entry.disabled).to.equal(true)
      entered:await()
      expect(entry.disabled).to.equal(true)
      expect(disabledDuringUnload).to.equal(true)
      expect(entry.outerFiber).to.equal(outer)
      expect(entry.options.disabled).to.deep.equal(expr("not settings.enabled"))
    end)
    release()
    loader:await():await()
    if not ok then
      error(err, 0)
    end
    -- an update while pending keeps the outer fiber
    loader:update("held", { config = { value = 1 } }):await()
    expect(entry.outerFiber).to.equal(outer)
    loader:create(settings({ enabled = true })):await()
    loader:await():await()
    expect(entry.disabled).to.equal(false)
    expect(entry.innerFiber.state).to.equal(FiberState.ACTIVE)
  end)

  -- evaluate.spec.ts:496
  it("keeps a disabled group verdict undecided when its dependency disappears", function()
    loader
      :read({
        settings({ enabled = false }),
        {
          id = "owner",
          name = "@cordisjs/group",
          group = true,
          inject = { "settings" },
          disabled = expr("not settings.enabled"),
          config = { { id = "child", name = "worker" } },
        },
      })
      :await()
    local owner = loader.store.owner
    loader:remove("settings")
    loader:await():await()
    expect(owner._verdict).to.equal(nil)
    expect(owner.disabled).to.equal(false)
    expect(owner.options.disabled).to.deep.equal(expr("not settings.enabled"))
    loader:create(settings({ enabled = true })):await()
    loader:await():await()
    expect(loader.store.child.disabled).to.equal(false)
    expect(worker).to.have.length(1)
  end)

  -- evaluate.spec.ts:513
  local function reevaluates(field)
    return function()
      local child = { id = "worker", name = "worker" }
      if field == "disabled" then
        child.disabled = expr("not env.enabled")
      else
        child.inject = { settings = { namespace = expr("env.namespace") } }
        child.disabled = expr("false")
      end
      local data = { settings({}) }
      for _, id in ipairs({ "a", "b" }) do
        data[#data + 1] = {
          id = id,
          name = "@cordisjs/group",
          group = true,
          inject = { "env" },
          isolate = { env = id },
          config = id == "a" and { child } or {},
        }
      end
      for _, id in ipairs({ "a", "b" }) do
        data[#data + 1] =
          { id = "env-" .. id, name = "env", isolate = { env = id }, config = { enabled = id == "a", namespace = id } }
      end
      loader:read(data):await()
      local entry = loader.store.worker
      loader:update("worker", {}, "b"):await()
      loader:await():await()
      if field == "disabled" then
        expect(entry.disabled).to.equal(true)
        expect(entry.innerFiber.uid).to.equal(nil)
      else
        expect(plain(entry.inject.settings)).to.deep.equal({ namespace = "b" })
        expect(plain(entry.outerFiber.inject.settings)).to.deep.equal({ namespace = "b" })
        expect(entry.innerFiber.state).to.equal(FiberState.ACTIVE)
      end
    end
  end
  it("re-evaluates disabled in the new parent context after a transfer", reevaluates("disabled"))
  it("re-evaluates inject in the new parent context after a transfer", reevaluates("inject"))

  -- evaluate.spec.ts:540
  it("re-evaluates the verdict after changing the entry isolation", function()
    local data = {}
    for _, id in ipairs({ "a", "b" }) do
      data[#data + 1] = { id = id, name = "settings", isolate = { settings = id }, config = { enabled = id == "a" } }
    end
    loader:read(data):await()
    loader
      :create({
        id = "worker",
        name = "worker",
        inject = { "settings" },
        isolate = { settings = "a" },
        disabled = expr("not settings.enabled"),
      })
      :await()
    loader:await():await()
    local entry = loader.store.worker
    expect(entry.disabled).to.equal(false)
    loader:update("worker", { isolate = { settings = "b" } }):await()
    loader:await():await()
    expect(entry.disabled).to.equal(true)
    expect(entry.innerFiber.uid).to.equal(nil)
    expect(entry.options.disabled).to.deep.equal(expr("not settings.enabled"))
  end)

  -- evaluate.spec.ts:558 (rewritten: `vi.spyOn(Entry.prototype, '_patchContext')`
  -- replaces the class method for the duration of the case)
  local function drops(window)
    return function()
      local host = U.host()
      loader:read({ settings({}) }):await()
      local original = loader.import
      local patch = Entry._patchContext
      local ok, err = pcall(function()
        for _, inject in ipairs({ false, { "settings" } }) do
          inject = inject or nil
          for _, action in ipairs({ "remove", "disable" }) do
            local entered, enter = cordis.Future.withResolvers(host)
            local released, release = cordis.Future.withResolvers(host)
            if window == "import" then
              loader.import = cordis.async(function(self, name)
                if name == "worker" then
                  enter()
                  released:await()
                end
                return original(self, name):await()
              end)
            else
              Entry._patchContext = function(self, diff)
                return cordis.future.AsyncFunction.spawn(
                  cordis.async(function()
                    if self.options.id == "worker" then
                      enter()
                      released:await()
                    end
                    return patch(self, diff):await()
                  end),
                  host
                )
              end
            end
            local creating = loader:create({ id = "worker", name = "worker", inject = inject })
            local entry
            local ok1, err1 = pcall(function()
              entered:await()
              entry = loader.store.worker
              if action == "remove" then
                loader:remove("worker")
              else
                loader:update("worker", { disabled = true }):await()
              end
            end)
            release()
            -- `await creating` in upstream's `finally`: a rejection propagates
            local ok2, err2 = pcall(function()
              creating:await()
            end)
            loader.import = nil
            Entry._patchContext = patch
            if not ok1 then
              error(err1, 0)
            end
            if not ok2 then
              error(err2, 0)
            end
            loader:await():await()
            expect(entry.outerFiber).to.equal(nil)
            expect(entry.innerFiber).to.equal(nil)
            expect(worker).to.have.length(0)

            -- a dropped init does not block a later create or re-enable
            if action == "remove" then
              loader:create({ id = "worker", name = "worker", inject = inject }):await()
            else
              loader:update("worker", { disabled = false }):await()
            end
            loader:await():await()
            expect(loader.store.worker.innerFiber.state).to.equal(FiberState.ACTIVE)
            expect(worker).to.have.length(1)
            loader:remove("worker")
            loader:await():await()
            worker:reset()
          end
        end
      end)
      loader.import = nil
      Entry._patchContext = patch
      if not ok then
        error(err, 0)
      end
    end
  end
  it("drops entries removed or disabled during import", drops("import"))
  it("drops entries removed or disabled during patch", drops("patch"))
end)

describe("Loader: entry evaluation boundaries", function()
  local root, loader, worker
  local seen = {}

  before_all(function()
    root, loader = T.setup()
    loader:mock("settings", function(ctx, config)
      ctx:provide("settings", copy(config))
    end)
    loader:mock("env", function(ctx, config)
      ctx:provide("env", copy(config))
    end)
    worker = loader:mock("worker", function(ctx, config)
      seen = { intercept = ctx[Context().intercept], config = config }
    end)
  end)

  before_each(function()
    loader:read({}):await()
    worker:reset()
    seen = {}
  end)

  local function settings(config)
    return { id = "settings", name = "settings", config = config }
  end

  local function proxy(source)
    return { http = { proxy = expr(source) } }
  end

  -- evaluate.spec.ts:652
  it("does not start the component when intercept cannot be evaluated", function()
    loader
      :read({
        settings({}),
        { id = "worker", name = "worker", inject = { "settings" }, intercept = proxy("settings.missing.value") },
      })
      :await()

    expect(loader.store.worker.disabled).to.equal(true)
    expect(worker).to.have.length(0)
  end)

  -- evaluate.spec.ts:664
  it("disposes the component when intercept stops evaluating on an update", function()
    loader
      :read({
        settings({ proxy = "p1" }),
        { id = "worker", name = "worker", inject = { "settings" }, intercept = proxy("settings.proxy") },
      })
      :await()
    local entry = loader.store.worker
    expect(seen.intercept.http).to.deep.equal({ proxy = "p1" })

    loader:update("worker", { intercept = proxy("settings.missing.value") }):await()
    loader:await():await()
    expect(entry.disabled).to.equal(true)
    expect(entry.innerFiber.uid).to.equal(nil)

    -- a later update does not restart the component with the previous table
    loader:update("worker", { config = { tag = "v2" } }):await()
    loader:await():await()
    expect(entry.innerFiber.uid).to.equal(nil)
    expect(worker).to.have.length(1)

    loader:update("worker", { intercept = proxy("settings.proxy") }):await()
    loader:await():await()
    expect(entry.disabled).to.equal(false)
    expect(entry.innerFiber.state).to.equal(FiberState.ACTIVE)
    expect(worker).to.have.length(2)
  end)

  -- evaluate.spec.ts:692
  it("stops a group whose intercept stops evaluating on an update", function()
    loader
      :read({
        settings({ proxy = "p1" }),
        {
          id = "group",
          name = "@cordisjs/group",
          group = true,
          inject = { "settings" },
          intercept = proxy("settings.proxy"),
          config = { { id = "worker", name = "worker" } },
        },
      })
      :await()
    local group = loader.store.group
    -- an expression on a group reaches the components of its children
    expect(seen.intercept.http).to.deep.equal({ proxy = "p1" })

    loader:update("group", { intercept = proxy("settings.missing.value") }):await()
    loader:await():await()
    expect(group.innerFiber.uid).to.equal(nil)
    expect(loader.store.worker).to.equal(nil)
  end)

  -- evaluate.spec.ts:711
  it("does not evaluate intercept while disabled", function()
    loader
      :read({
        settings({ count = 0, bump = T.bump }),
        {
          id = "worker",
          name = "worker",
          inject = { "settings" },
          disabled = expr("true"),
          intercept = { http = { count = expr('settings:bump("count")') } },
        },
      })
      :await()

    expect(root:get("settings").count).to.equal(0)
    expect(worker).to.have.length(0)
  end)

  -- evaluate.spec.ts:724
  it("cannot read a service outside the parent context and the entry inject in disabled", function()
    loader
      :read({
        settings({ enabled = true }),
        { id = "env", name = "env" },
        { id = "worker", name = "worker", inject = { "env" }, disabled = expr("not settings.enabled") },
      })
      :await()

    expect(loader.store.worker.outerFiber.state).to.equal(FiberState.ACTIVE)
    expect(loader.store.worker.disabled).to.equal(true)
    expect(worker).to.have.length(0)
  end)

  -- evaluate.spec.ts:737
  it("cannot read a service provided by a sibling in an inject value", function()
    loader
      :read({
        { id = "env", name = "env", config = { namespace = "ns" } },
        settings({}),
        { id = "worker", name = "worker", inject = { settings = { namespace = expr("env.namespace") } } },
      })
      :await()

    expect(loader.store.worker.outerFiber).to.equal(nil)
    expect(worker).to.have.length(0)
  end)

  -- evaluate.spec.ts:748
  it("evaluates config with the component inject", function()
    local own = loader:mock("own", function(_, config)
      seen = { config = config }
    end)
    own.inject = { "settings" }
    loader
      :read({ settings({ value = 1 }), { id = "own", name = "own", config = { value = expr("settings.value") } } })
      :await()

    expect(own).to.have.length(1)
    expect(seen.config).to.deep.equal({ value = 1 })
  end)

  -- evaluate.spec.ts:762
  it("cannot read a service outside every inject in config", function()
    loader
      :read({ settings({ value = 1 }), { id = "worker", name = "worker", config = { value = expr("settings.value") } } })
      :await()

    expect(loader.store.worker.innerFiber.state).to.equal(FiberState.FAILED)
    expect(worker).to.have.length(0)
  end)
end)
