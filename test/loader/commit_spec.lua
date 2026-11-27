-- Ported from cordis packages/loader/tests/commit.spec.ts (MIT, (c) Shigma)
local cordis = require("cordis")
local L = require("cordis.loader")
local T = require("loader.mock_loader")
local spy = require("kit.spy")

local sleep = T.sleep

local function includes(list, value)
  for _, v in ipairs(list) do
    if rawequal(v, value) then
      return true
    end
  end
  return false
end

local function copy(t)
  local r = {}
  for k, v in pairs(t) do
    r[k] = v
  end
  return r
end

describe("EntryTree.commit: change reports", function()
  local loader, foo
  local id, group

  before_all(function()
    local _
    _, loader = T.setup()
    foo = loader:mock("foo", function() end)
  end)

  before_each(function()
    if loader then
      loader.changes = {}
    end
  end)

  -- commit.spec.ts:26
  it("create reports a created entry with its id assigned", function()
    id = loader:create({ name = "foo", config = { a = 1 } }):await()
    group = loader:create({ name = "@cordisjs/group", group = true, config = {} }):await()

    expect(loader.changes).to.have.length(2)
    local change = loader.changes[1]
    expect(change.id).to.equal(id)
    expect(change.group).to.equal(loader.root)
    expect(change.legacy).to.equal(nil)
    expect(change.options).to.deep.equal({ id = id, name = "foo", config = { a = 1 } })
    expect(includes(loader.root.data, change.options)).to.equal(true)
  end)

  -- commit.spec.ts:43
  it("update reports the new options together with the previous ones", function()
    loader:update(id, { config = { a = 2 } }):await()

    expect(loader.changes).to.have.length(1)
    local change = loader.changes[1]
    expect(change.id).to.equal(id)
    expect(change.legacy).to.deep.equal({ id = id, name = "foo", config = { a = 1 } })
    expect(change.options).to.deep.equal({ id = id, name = "foo", config = { a = 2 } })
    -- reported after the mutation
    expect(change.options).to.equal(loader.store[id].options)
  end)

  -- commit.spec.ts:55
  it("transfer reports the target group", function()
    loader:update(id, {}, group):await()

    expect(loader.changes).to.have.length(1)
    local change = loader.changes[1]
    expect(change.group).to.equal(loader.store[group].subgroup)
    expect(change.from).to.equal(loader.root)
    expect(change.options).to.deep.equal(change.legacy)
  end)

  -- commit.spec.ts:65
  it("update in place does not report a transfer", function()
    loader:update(id, { config = { a = 4 } }):await()

    expect(loader.changes).to.have.length(1)
    expect(loader.changes[1].from).to.equal(nil)
  end)

  -- commit.spec.ts:72
  it("fiber.update from inside the component reports a config change", function()
    local fiber = loader:expectFiber(id)
    cordis.await(fiber:update({ a = 5 }))

    expect(loader.changes).to.have.length(1)
    local change = loader.changes[1]
    expect(change.legacy.config).to.deep.equal({ a = 4 })
    expect(change.options.config).to.deep.equal({ a = 5 })
  end)

  -- commit.spec.ts:82
  it("remove reports the removed entry", function()
    loader:remove(id)

    expect(loader.changes).to.have.length(1)
    local change = loader.changes[1]
    expect(change.id).to.equal(id)
    expect(change.options).to.equal(nil)
    expect(change.legacy.name).to.equal("foo")
    expect(loader.store[id]).to.equal(nil)
  end)

  -- commit.spec.ts:93
  it("does not mistake a child fiber disposing itself for the entry (#19)", function()
    loader:mock("parent", function(ctx)
      local child = ctx:use(function() end)
      child:dispose()
    end)
    local parent = loader:create({ name = "parent" }):await()
    sleep()

    loader:expectFiber(parent)
    expect(loader.store[parent].options.disabled).to.equal(nil)
    local disabled = 0
    for _, change in ipairs(loader.changes) do
      if change.options and change.options.disabled then
        disabled = disabled + 1
      end
    end
    expect(disabled).to.equal(0)
    loader:remove(parent)
  end)

  -- commit.spec.ts:107
  it("does not report anything for reads", function()
    expect(#foo.calls > 0).to.equal(true)
    loader
      :read({
        { id = "x", name = "foo" },
        { id = group, name = "@cordisjs/group", group = true, config = {} },
      })
      :await()
    loader.changes = {}

    -- a removal driven by the config file is a read, so nothing is reported
    loader:read({ { id = group, name = "@cordisjs/group", group = true, config = {} } }):await()
    sleep()
    expect(loader.changes).to.have.length(0)
    expect(loader.store["x"]).to.equal(nil)
  end)
end)

describe("EntryGroup.remove: file-driven moves", function()
  local dispose = spy.fn()
  local loader, foo

  before_all(function()
    local _
    _, loader = T.setup()
    foo = loader:mock("foo", function()
      return dispose
    end)
  end)

  -- commit.spec.ts:138
  it("keeps an entry that another group adopted", function()
    loader
      :read({
        { id = "x", name = "foo" },
        { id = "g", name = "@cordisjs/group", group = true, config = {} },
      })
      :await()
    expect(foo).to.have.length(1)

    loader
      :read({ { id = "g", name = "@cordisjs/group", group = true, config = { { id = "x", name = "foo" } } } })
      :await()
    sleep()

    -- whichever of remove / adopt ran first, the entry survives in the store
    expect(loader.store["x"]).to.be.ok()
    expect(loader.store["x"].parent).to.equal(loader.store["g"].subgroup)
    loader:expectFiber("x")
    loader:expectEnable(foo)
  end)
end)

describe("EntryTree.update: cross-tree moves", function()
  local root, loader, foo
  local changes = {}

  local Tree = cordis.class("Tree", L.EntryTree)
  Tree.inject = { "loader" }

  function Tree:commit(change)
    table.insert(changes, change)
  end

  function Tree:import()
    return cordis.Future.resolve(self.ctx.host, L.Group)
  end

  Tree[cordis.symbols.init] = function(self)
    return self.root:update({ { id = "g", name = "@cordisjs/group", group = true, config = {} } })
  end

  before_all(function()
    root, loader = T.setup()
    foo = loader:mock("foo", function() end)
    loader.modules["tree"] = Tree
  end)

  before_each(function()
    if loader then
      loader.changes = {}
    end
    for i = #changes, 1, -1 do
      changes[i] = nil
    end
  end)

  local function setup()
    local id = loader:create({ name = "tree" }):await()
    loader:await():await()
    loader.changes = {}
    return id, loader.store[id].subtree
  end

  local function running()
    local runtime = root.registry:get(foo)
    return runtime and runtime.fibers:length() or 0
  end

  -- commit.spec.ts:202
  it("reports a removal to the source tree and a creation to the target tree", function()
    local tree, subtree = setup()
    local id = loader:create({ name = "foo", config = { a = 1 } }):await()
    loader:await():await()
    loader.changes = {}

    loader:update(id, { config = { a = 2 } }, tree .. ":g"):await()

    expect(loader.changes).to.have.length(1)
    expect(loader.changes[1].group).to.equal(loader.root)
    expect(loader.changes[1].options).to.equal(nil)
    expect(loader.changes[1].legacy).to.deep.equal({ id = id, name = "foo", config = { a = 1 } })

    expect(changes).to.have.length(1)
    local change = changes[1]
    expect(change.group).to.equal(subtree.store["g"].subgroup)
    expect(change.legacy).to.equal(nil)
    expect(change.from).to.equal(nil)
    expect(change.options).to.deep.equal({ id = id, name = "foo", config = { a = 2 } })
    loader:remove(tree .. ":" .. id)
  end)

  -- commit.spec.ts:224
  it("transfers the entry to the store of the target tree", function()
    local tree, subtree = setup()
    local id = loader:create({ name = "foo" }):await()
    loader:await():await()
    local entry = loader.store[id]

    loader:update(id, {}, tree .. ":g"):await()
    loader:await():await()

    expect(loader.store[id]).to.equal(nil)
    expect(subtree.store[id]).to.equal(entry)
    expect(loader:resolve(tree .. ":" .. id)).to.equal(entry)
    expect(entry.id).to.equal(tree .. ":" .. id)
    expect(running()).to.equal(1)

    -- the target tree adopts the entry when it reconciles its source
    subtree.store["g"].subgroup:update({ copy(entry.options) }):await()
    loader:await():await()
    expect(subtree.store[id]).to.equal(entry)
    expect(running()).to.equal(1)

    loader:remove(tree .. ":" .. id)
    loader:await():await()
    expect(running()).to.equal(0)
  end)

  -- commit.spec.ts:250
  it("transfers the members of a transferred group", function()
    local tree, subtree = setup()
    local group =
      loader:create({ name = "@cordisjs/group", group = true, config = { { id = "member", name = "foo" } } }):await()
    loader:await():await()
    local member = loader.store["member"]
    expect(running()).to.equal(1)

    loader:update(group, {}, tree .. ":g"):await()
    loader:await():await()

    expect(loader.store[group]).to.equal(nil)
    expect(loader.store["member"]).to.equal(nil)
    expect(subtree.store["member"]).to.equal(member)
    expect(subtree.store[group].subgroup.tree).to.equal(subtree)
    expect(member.id).to.equal(tree .. ":member")
    expect(running()).to.equal(1)

    loader:remove(tree .. ":" .. group)
    loader:await():await()
    expect(running()).to.equal(0)
  end)

  -- commit.spec.ts:276
  it("rejects a transfer onto an id that the target tree already uses", function()
    local tree, subtree = setup()
    local id = loader:create({ id = "g", name = "foo" }):await()
    loader:await():await()
    local entry = loader.store[id]
    loader.changes = {}

    expect(loader:update(id, {}, tree .. ":g")).to.reject()

    expect(loader.store[id]).to.equal(entry)
    expect(entry.parent).to.equal(loader.root)
    expect(includes(loader.root.data, entry.options)).to.equal(true)
    expect(subtree.store["g"].subgroup.data).to.have.length(0)
    expect(loader.changes).to.have.length(0)
    expect(changes).to.have.length(0)
    loader:remove(id)
  end)
end)

describe("EntryTree disposal", function()
  -- commit.spec.ts:296
  it("does not persist child disposal while the tree loses its loader", function()
    local T2 = require("kit.util")
    local root = T2.root()
    local loader = cordis.await(root:use(T.MockLoader))
    local commit = spy.fn()
    local tree
    local Tree = cordis.class("Tree", L.EntryTree)
    Tree.inject = { "loader" }
    Tree.commit = commit
    function Tree:import()
      return cordis.Future.resolve(self.ctx.host, function() end)
    end
    Tree[cordis.symbols.init] = function(self)
      return cordis.asyncIter(function(yield)
        tree = self
        self.root:update({ { id = "child", name = "child" } }):await()
        yield(cordis.async(function()
          -- Include flushes pending writes before stopping its entry group.
          cordis.tick(self.ctx.host)
          self.root:stop()
        end))
      end)()
    end
    local fiber = cordis.await(loader.ctx:use(Tree))
    local options = tree.root.data[1]
    cordis.await(loader:dispose())
    expect(options.disabled).to.equal(nil)
    expect(commit).to.have.length(0)
    cordis.await(fiber:dispose())
  end)
end)

describe("Loader.showLog: reloads", function()
  local function setup()
    local root, loader = T.setup()
    loader.enableLogs = true
    local logs = {}
    root.logger:exporter({
      levels = { default = 3 },
      export = function(message)
        if message.name == "loader" then
          local rest = {}
          for i = 2, #message.args do
            rest[#rest + 1] = message.args[i]
          end
          logs[#logs + 1] = rest
        end
      end,
    })
    local function reloads()
      local out = {}
      for _, row in ipairs(logs) do
        if row[1] == "reload" then
          out[#out + 1] = row[2]
        end
      end
      return out
    end
    return loader, reloads
  end

  -- commit.spec.ts:346
  it("logs a config change from outside the component", function()
    local loader, reloads = setup()
    loader:mock("foo", function() end)
    local id = loader:create({ name = "foo", config = { a = 1 } }):await()
    loader:await():await()
    loader:update(id, { config = { a = 2 } }):await()
    expect(reloads()).to.deep.equal({ "foo" })
  end)

  -- commit.spec.ts:355
  it("does not log an update by the component itself", function()
    local loader, reloads = setup()
    loader:mock("foo", function() end)
    local id = loader:create({ name = "foo", config = { a = 1 } }):await()
    loader:await():await()
    cordis.await(loader:expectFiber(id):update({ a = 2 }))
    expect(reloads()).to.deep.equal({})
  end)
end)
