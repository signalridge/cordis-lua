-- Minimal BDD harness: describe / it / before_each / after_each / expect.
-- Every `it` body runs as a task on a fresh reference scheduler (see util.lua).
local H = {}

local root = { name = "", children = {}, before = {}, after = {} }
local current = root
H.root = root

function H.describe(name, fn)
  local suite = { name = name, children = {}, before = {}, after = {}, parent = current, beforeAll = nil }
  table.insert(current.children, suite)
  local prev = current
  current = suite
  fn()
  current = prev
end

function H.it(name, fn)
  table.insert(current.children, { name = name, fn = fn, test = true, parent = current })
end

function H.before_each(fn)
  table.insert(current.before, fn)
end

function H.after_each(fn)
  table.insert(current.after, fn)
end

-- `beforeAll`: every `it` below this describe shares one scheduler / host,
-- created before the first of them; the hooks run once inside it
function H.before_all(fn)
  current.beforeAll = current.beforeAll or {}
  table.insert(current.beforeAll, fn)
end

function H.reset()
  root.children, root.before, root.after = {}, {}, {}
  current = root
end

-- deep equality -----------------------------------------------------------------

local function deepEqual(a, b, seen)
  if rawequal(a, b) then
    return true
  end
  if type(a) ~= "table" or type(b) ~= "table" then
    if type(a) == "number" and type(b) == "number" then
      return a == b
    end
    return false
  end
  local ma, mb = getmetatable(a), getmetatable(b)
  if ma ~= mb then
    return false
  end
  if ma and ma.__eq then
    return a == b
  end
  seen = seen or {}
  if seen[a] == b then
    return true
  end
  seen[a] = b
  for k, v in next, a do
    if not deepEqual(v, rawget(b, k), seen) then
      return false
    end
  end
  for k in next, b do
    if rawget(a, k) == nil then
      return false
    end
  end
  return true
end
H.deepEqual = deepEqual

local function show(v, depth)
  depth = depth or 0
  if type(v) == "string" then
    return string.format("%q", v)
  end
  if type(v) ~= "table" or depth > 2 then
    return tostring(v)
  end
  local mt = getmetatable(v)
  if mt and mt.__tostring then
    return tostring(v)
  end
  local parts, n = {}, 0
  for k, x in next, v do
    n = n + 1
    if n > 20 then
      parts[#parts + 1] = "..."
      break
    end
    if math.type(k) == "integer" then
      parts[#parts + 1] = show(x, depth + 1)
    else
      parts[#parts + 1] = tostring(k) .. " = " .. show(x, depth + 1)
    end
  end
  return "{ " .. table.concat(parts, ", ") .. " }"
end
H.show = show

-- error messages ------------------------------------------------------------------

local function messageOf(e)
  if type(e) == "table" then
    if e.message ~= nil then
      return tostring(e.message)
    end
    return tostring(e)
  end
  return tostring(e)
end
H.messageOf = messageOf

local function matches(e, expected)
  if expected == nil then
    return true
  end
  local msg = messageOf(e)
  if type(expected) == "string" then
    return msg:find(expected, 1, true) ~= nil
  end
  if type(expected) == "function" then
    return expected(e)
  end
  if type(expected) == "table" then
    if expected.pattern then
      return msg:find(expected.pattern) ~= nil
    end
    if expected.is then
      return expected.is(e)
    end
  end
  return false
end

-- expect --------------------------------------------------------------------------

local Assertion = {}

local function fail(msg, level)
  error(
    setmetatable({ message = msg, assertion = true }, {
      __tostring = function(self)
        return self.message
      end,
    }),
    level or 3
  )
end
H.fail = fail

local function check(self, ok, msg, negmsg)
  if rawget(self, "negate") then
    if ok then
      fail(negmsg or ("not: " .. msg), 4)
    end
  else
    if not ok then
      fail(msg, 4)
    end
  end
end

local methods = {}

function methods.equal(self, expected)
  local actual = rawget(self, "value")
  if rawget(self, "deep") then
    check(
      self,
      deepEqual(actual, expected),
      "expected " .. show(actual) .. " to deeply equal " .. show(expected),
      "expected " .. show(actual) .. " not to deeply equal " .. show(expected)
    )
  else
    check(
      self,
      rawequal(actual, expected) or actual == expected,
      "expected " .. show(actual) .. " to equal " .. show(expected),
      "expected " .. show(actual) .. " not to equal " .. show(expected)
    )
  end
end

function methods.length(self, n)
  local actual = rawget(self, "value")
  local len
  if type(actual) == "table" and actual.calls and getmetatable(actual) and getmetatable(actual).__spy then
    len = #actual.calls
  elseif type(actual) == "table" and type(actual.size) == "function" then
    len = actual:size()
  else
    len = #actual
  end
  check(self, len == n, "expected length " .. tostring(len) .. " to equal " .. tostring(n))
end

function methods.ok(self)
  check(
    self,
    rawget(self, "value") ~= nil and rawget(self, "value") ~= false,
    "expected " .. show(rawget(self, "value")) .. " to be truthy"
  )
end

function methods.instanceof(self, cls)
  local ok = type(cls) == "table" and type(cls.is) == "function" and cls.is(rawget(self, "value"))
  check(self, ok, "expected " .. show(rawget(self, "value")) .. " to be an instance of " .. tostring(cls))
end

function methods.throw(self, expected)
  local fn = rawget(self, "value")
  local ok, e = pcall(fn)
  if rawget(self, "negate") then
    if not ok then
      fail("expected no error, got: " .. messageOf(e), 3)
    end
    return
  end
  if ok then
    fail("expected function to throw " .. tostring(expected or ""), 3)
  end
  if not matches(e, expected) then
    fail("expected error matching " .. show(expected) .. ", got: " .. messageOf(e), 3)
  end
  return e
end

-- `value` is a Future: await it and expect a rejection
function methods.reject(self, expected)
  local ok, e = pcall(function()
    return rawget(self, "value"):await()
  end)
  if ok then
    fail("expected future to reject with " .. tostring(expected or ""), 3)
  end
  if not matches(e, expected) then
    fail("expected rejection matching " .. show(expected) .. ", got: " .. messageOf(e), 3)
  end
  return e
end

-- `value` is a Future: await it and expect it to fulfill
function methods.resolve(self, expected)
  local ok, v = pcall(function()
    return rawget(self, "value"):await()
  end)
  if not ok then
    fail("expected future to fulfill, got rejection: " .. messageOf(v), 3)
  end
  if expected ~= nil and not deepEqual(v, expected) then
    fail("expected fulfillment " .. show(expected) .. ", got " .. show(v), 3)
  end
  return v
end

-- spies
function methods.called(self, n)
  local calls = #rawget(self, "value").calls
  if n == nil then
    check(self, calls > 0, "expected spy to have been called", "expected spy not to have been called, called " .. calls)
  else
    check(self, calls == n, "expected spy to be called " .. n .. " times, called " .. calls)
  end
end

-- chainable words (to, be, have, deep, never) as in chai
local words = { to = true, be = true, have = true, been = true, is = true, that = true, a = true, an = true }

Assertion.__index = function(self, key)
  if words[key] then
    return self
  end
  if key == "deep" then
    rawset(self, "deep", true)
    return self
  end
  if key == "never" or key == "no" then
    rawset(self, "negate", true)
    return self
  end
  local m = methods[key]
  if m then
    return function(...)
      return m(self, ...)
    end
  end
  error("unknown assertion: " .. tostring(key), 2)
end

function H.expect(value)
  return setmetatable({ value = value }, Assertion)
end

return H
