-- Checks docs/port-status.md against the ported specs:
--   * the number of rows per upstream package matches the upstream case count
--   * every `ported` row has a matching `it(<name>, ...)` declaration in the mapped
--     spec file, matching by (file, name, occurrence count)
--   * every `n/a` row gives a reason; `todo` rows are disallowed
-- Usage: lua test/kit/port_check.lua [--summary]
local M = {}

-- escape a literal for use inside a Lua pattern
local function escapePattern(s)
  return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

---How many times does `spec` (source text) declare `it(<name>, ...)`?
---Whitespace and newlines between `it(` and the name are allowed (stylua wraps
---long calls), and the name may be double- or single-quoted.
function M.countCases(spec, name)
  if not spec then
    return 0
  end
  local dq = string.format("%q", name):gsub("\\\n", "\\n")
  local sq = "'" .. name:gsub("\\", "\\\\"):gsub("'", "\\'") .. "'"
  local count = 0
  for _, quoted in ipairs({ dq, sq }) do
    local pattern = "%f[%w_]it%(%s*" .. escapePattern(quoted)
    local pos = 1
    while true do
      local _, finish = spec:find(pattern, pos)
      if not finish then
        break
      end
      count = count + 1
      pos = finish + 1
    end
  end
  return count
end

---Does `spec` (source text) declare `it(<name>, ...)` at least once?
function M.hasCase(spec, name)
  return M.countCases(spec, name) > 0
end

-- upstream `it` counts at the commit in UPSTREAM
local EXPECTED = { core = 188, timer = 25, loader = 165 }
M.EXPECTED = EXPECTED

local function unescape(s)
  return (s:gsub("\\|", "|"))
end

---Validate `status` markdown against spec files loaded via `readSpec(relPath)`.
---`relPath` is relative to the repository root (e.g. `"test/timer/index_spec.lua"`).
function M.checkStatus(status, readSpec, expected)
  expected = expected or EXPECTED
  local errors, counts, ported, total = {}, {}, {}, {}
  local specCache = {}
  local required = {}
  local requiredOrder = {}

  for line in status:gmatch("[^\n]+") do
    local pkg, file, ln, name, st = line:match("^| (%w+)/tests/([%w%-]+)%.spec%.ts:(%d+) | (.-) | (.-) |$")
    if pkg then
      name = unescape(name):gsub("^%[each%] ", "")
      counts[pkg] = (counts[pkg] or 0) + 1
      total[pkg] = (total[pkg] or 0) + 1
      local specPath = string.format("test/%s/%s_spec.lua", pkg, (file:gsub("%-", "_")))
      if st == "ported" or st:match("^ported %(") then
        ported[pkg] = (ported[pkg] or 0) + 1
        local key = specPath .. "\0" .. name
        local entry = required[key]
        if not entry then
          entry = { specPath = specPath, name = name, need = 0, firstRef = file .. ":" .. ln }
          required[key] = entry
          requiredOrder[#requiredOrder + 1] = entry
        end
        entry.need = entry.need + 1
      elseif st:match("^n/a: .+") then
        -- ok
      elseif st == "todo" then
        errors[#errors + 1] = string.format('%s:%s has disallowed status "todo"', file, ln)
      else
        errors[#errors + 1] = string.format("%s:%s has invalid status %q", file, ln, st)
      end
    end
  end

  for _, entry in ipairs(requiredOrder) do
    local specPath = entry.specPath
    if specCache[specPath] == nil then
      specCache[specPath] = readSpec(specPath) or false
    end
    local spec = specCache[specPath]
    local found = M.countCases(spec, entry.name)
    if found < entry.need then
      if found == 0 then
        errors[#errors + 1] =
          string.format("%s %q marked ported but not found in %s", entry.firstRef, entry.name, specPath)
      else
        errors[#errors + 1] = string.format(
          "%s %q marked ported %d time(s) but found %d in %s",
          entry.firstRef,
          entry.name,
          entry.need,
          found,
          specPath
        )
      end
    end
  end

  for pkg, n in pairs(expected) do
    if (counts[pkg] or 0) ~= n then
      errors[#errors + 1] = string.format("%s: %d rows, expected %d", pkg, counts[pkg] or 0, n)
    end
  end

  return errors, counts, ported, total
end

-- loaded as a module (by the kit self-test): export helpers only
if ... == "kit.port_check" then
  return M
end

local dir = (arg and arg[0] or ""):match("^(.*)/test/kit/port_check%.lua$") or "."

local function read(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local s = f:read("a")
  f:close()
  return s
end

local status = assert(read(dir .. "/docs/port-status.md"), "docs/port-status.md not found")
local errors, _, ported, total = M.checkStatus(status, function(relPath)
  return read(dir .. "/" .. relPath)
end, EXPECTED)

for pkg in pairs(EXPECTED) do
  print(string.format("%s: %d/%d ported", pkg, ported[pkg] or 0, total[pkg] or 0))
end

for _, e in ipairs(errors) do
  io.stderr:write("port_check: ", e, "\n")
end
os.exit(#errors == 0 and 0 or 1)
