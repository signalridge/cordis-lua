-- Test runner: `lua test/run.lua [--eager] [--contexts] [--host <module>] [--filter <substring>] [files...]`
--
-- `--contexts`: the reference scheduler with execution contexts, so the host
-- offers `capture` (see docs/deviations.md).
--
-- `--host <module>`: run on an external scheduler; the module returns the
-- scheduler factory described in test/kit/runner.lua. Cases that need virtual
-- time are then skipped and listed.
assert(_VERSION == "Lua 5.5", "cordis-lua requires Lua 5.5, got " .. _VERSION)

local dir = (arg and arg[0] or "test/run.lua"):match("^(.*)/test/run%.lua$") or "."
package.path = table.concat({
  dir .. "/lua/?.lua",
  dir .. "/lua/?/init.lua",
  dir .. "/test/?.lua",
  package.path,
}, ";")

local runner = require("kit.runner")

local eager, contexts, filter, hostModule, files = false, false, nil, nil, {}
local i = 1
while arg[i] do
  local a = arg[i]
  if a == "--eager" then
    eager = true
  elseif a == "--contexts" then
    contexts = true
  elseif a == "--filter" then
    i = i + 1
    filter = arg[i]
  elseif a == "--host" then
    i = i + 1
    hostModule = arg[i]
  else
    files[#files + 1] = a
  end
  i = i + 1
end

if #files == 0 then
  local p = io.popen('find "' .. dir .. '/test" -name "*_spec.lua" | sort')
  for line in p:lines() do
    files[#files + 1] = line
  end
  p:close()
end

local factory
if hostModule then
  local m = require(hostModule)
  factory = type(m) == "table" and m.new or m
elseif contexts then
  factory = function(options)
    options.contexts = true
    return runner.reference(options)
  end
end

local result = runner.run({ files = files, filter = filter, eager = eager, scheduler = factory })

for _, f in ipairs(result.failures) do
  io.stderr:write("FAIL ", f, "\n\n")
end
for _, s in ipairs(result.skipped) do
  io.stderr:write("SKIP ", s.file, " > ", s.name, " (", s.reason, ")\n")
end
local mode = hostModule and ("host " .. hostModule)
  or ((eager and "eager" or "deferred") .. (contexts and "+contexts" or ""))
print(
  string.format(
    "%s mode: %d passed, %d failed%s",
    mode,
    result.passed,
    result.failed,
    #result.skipped > 0 and (", " .. #result.skipped .. " skipped") or ""
  )
)
os.exit(result.failed == 0 and 0 or 1)
