-- The test runner as a library: `test/run.lua` is its command line; an
-- embedder can call it from its own test environment with its own host.
--
--   local runner = require("kit.runner")
--   local result = runner.run({
--     files = { ... },          -- spec files
--     filter = "substring",     -- optional
--     eager = false,            -- reference scheduler only
--     scheduler = factory,      -- optional, see below
--   })
--   -- result = { passed, failed, skipped = { { file, name, reason } }, failures = { text } }
--
-- `scheduler(options)` returns a scheduler for one test (or one shared
-- `before_all` suite): `{ host, drive = function(fn) -> ok, err, errors = {} }`,
-- optionally `virtual = true` with `advance(ms)`, `runAll()` and a writable
-- `auto` field (virtual time, as the reference scheduler has), and
-- `setTimeout(fn, ms) -> cancel`. `errors` collects the errors raised by tasks
-- (uncaught task errors fail the case). `options` is `{ eager, auto, now }`.
-- Without virtual time, cases written for fake timers (`U.withTimers`) and
-- cases that call `U.advance` / `U.runAll` are skipped and reported; a case
-- may also skip itself with `U.requires(feature)` / `U.skip(reason)`. The
-- default is the reference scheduler (cordis.host.coroutine).
local H = require("kit.harness")
local U = require("kit.util")
local future = require("cordis.future")

local M = {}

function M.reference(options)
  local sched = require("cordis.host.coroutine").new(options)
  sched.virtual = true
  return sched
end

local function fullName(node)
  local parts = {}
  while node and node.name do
    if node.name ~= "" then
      table.insert(parts, 1, node.name)
    end
    node = node.parent
  end
  return table.concat(parts, " > ")
end

local function collectHooks(node, field)
  local chain = {}
  local n = node
  while n do
    table.insert(chain, 1, n)
    n = n.parent
  end
  local list = {}
  for _, s in ipairs(chain) do
    for _, h in ipairs(s[field] or {}) do
      list[#list + 1] = h
    end
  end
  return list
end

function M.run(options)
  local eager, filter = options.eager or false, options.filter
  local factory = options.scheduler or M.reference
  local passed, failed, skipped, failures = 0, 0, {}, {}

  -- expose the harness as globals for spec files
  _G.describe, _G.it, _G.before_each, _G.after_each, _G.expect = H.describe, H.it, H.before_each, H.after_each, H.expect
  _G.before_all = H.before_all

  local function runTest(file, test)
    local name = fullName(test)
    if filter and not (file .. " " .. name):find(filter, 1, true) then
      return
    end
    local body = test.fn
    local timers = type(body) == "table" and body.timers
    -- the outermost describe with `before_all` owns a scheduler shared by its tests
    local owner
    local node = test.parent
    while node do
      if node.beforeAll then
        owner = node
      end
      node = node.parent
    end
    local function newScheduler()
      return factory({ eager = eager, auto = not timers, now = type(body) == "table" and body.now or nil })
    end
    local sched
    local setup = {}
    if owner then
      sched = owner._sched
      if not sched then
        sched = newScheduler()
        owner._sched = sched
        -- run every before_all from the owner down to (and including) nested suites, once
        local chain, n = {}, test.parent
        while n do
          table.insert(chain, 1, n)
          if n == owner then
            break
          end
          n = n.parent
        end
        for _, s2 in ipairs(chain) do
          for _, h in ipairs(s2.beforeAll or {}) do
            setup[#setup + 1] = h
          end
          s2._beforeAllDone = true
        end
      elseif sched.virtual then
        sched.auto = not timers
      end
      -- nested suites below the owner whose before_all has not run yet
      local n2 = test.parent
      local pending = {}
      while n2 and n2 ~= owner do
        if n2.beforeAll and not n2._beforeAllDone then
          table.insert(pending, 1, n2)
        end
        n2 = n2.parent
      end
      for _, s2 in ipairs(pending) do
        for _, h in ipairs(s2.beforeAll) do
          setup[#setup + 1] = h
        end
        s2._beforeAllDone = true
      end
    else
      sched = newScheduler()
    end
    if timers and not sched.virtual then
      skipped[#skipped + 1] = { file = file, name = name, reason = "needs virtual time (fake timers)" }
      return
    end
    U.state.sched = sched
    U.state.eager = eager
    local errorsBefore = #sched.errors
    local ok, err = sched.drive(function()
      future.enter(sched.host)
      for _, h in ipairs(setup) do
        h()
      end
      for _, h in ipairs(collectHooks(test.parent, "before")) do
        h()
      end
      local ok1, err1 = pcall(body)
      for _, h in ipairs(collectHooks(test.parent, "after")) do
        h()
      end
      if not ok1 then
        error(err1, 0)
      end
    end)
    if not ok and U.isSkip(err) then
      skipped[#skipped + 1] = { file = file, name = name, reason = err.reason }
      return
    end
    if ok and #sched.errors > errorsBefore then
      ok, err = false, "uncaught task error: " .. tostring(sched.errors[errorsBefore + 1])
    end
    if ok then
      passed = passed + 1
    else
      failed = failed + 1
      local msg = H.messageOf(err)
      if type(err) == "table" and not err.assertion and err.traceback then
        msg = msg .. "\n" .. err.traceback
      end
      failures[#failures + 1] = string.format("%s\n  %s\n    %s", file, name, (msg:gsub("\n", "\n    ")))
    end
  end

  local function walk(file, node)
    for _, child in ipairs(node.children) do
      if child.test then
        runTest(file, child)
      else
        walk(file, child)
      end
    end
  end

  for _, file in ipairs(options.files) do
    H.reset()
    local chunk, lerr = loadfile(file)
    if not chunk then
      failed = failed + 1
      failures[#failures + 1] = file .. "\n  (load error) " .. lerr
    else
      local ok, err = pcall(chunk)
      if not ok then
        failed = failed + 1
        failures[#failures + 1] = file .. "\n  (spec error) " .. tostring(err)
      else
        walk(file, H.root)
      end
    end
  end

  return { passed = passed, failed = failed, skipped = skipped, failures = failures }
end

return M
