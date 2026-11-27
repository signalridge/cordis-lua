-- Reference host: a pure-Lua cooperative scheduler with virtual time.
--
-- For standalone Lua programs and the test suite. Embedders that own their own
-- executor (e.g. an mlua runtime) should supply their own `cordis.Host` instead.
--
--   local sched = require("cordis.host.coroutine").new({ eager = false })
--   sched.host           -- cordis.Host (spawn, latch, sleep, now)
--   sched.run()          -- run until no task is runnable (auto mode: also fires timers)
--   sched.advance(ms)    -- advance virtual time by `ms`, running everything due
--   sched.runAll()       -- fire every pending timer
--
-- `eager = true`: `spawn` runs the task immediately until it first blocks.
-- `eager = false`: `spawn` queues the task.
-- `auto = true` (default): when idle, virtual time jumps to the next timer.
-- `auto = false`: time only moves through `advance` / `runAll` (fake timers).
-- `contexts = true`: tasks carry an execution context (a label), and the host
-- offers `capture`. `spawn` then starts tasks in the root
-- context "host", `sched.spawnAs(label, fn)` in another one, and
-- `sched.context()` names the running task's context.
local M = {}

local BLOCK = setmetatable({}, { __name = "cordis.host.block" })

local WAKERS_MT = {
  __len = function(w)
    return w._n
  end,
}

local CLOSE_MT = {
  __close = function(guard)
    guard[1]()
  end,
}

local function traceback(coOrMsg, msgOrLevel)
  local dbg = rawget(_G, "debug")
  if type(dbg) == "table" and type(dbg.traceback) == "function" then
    return dbg.traceback(coOrMsg, msgOrLevel)
  end
  if type(coOrMsg) == "thread" then
    return tostring(msgOrLevel)
  end
  return tostring(coOrMsg or "")
end

function M.new(options)
  options = options or {}
  local eager = options.eager and true or false
  local sched = { eager = eager, auto = options.auto ~= false, errors = {} }
  local queue, qhead, qtail = {}, 1, 0
  local timers, timerSeq = {}, 0
  local now = options.now or 0
  local advancer -- { co, target, all }
  local tasks = setmetatable({}, { __mode = "k" })
  local contexts = options.contexts and true or false
  local taskContext = setmetatable({}, { __mode = "k" })
  local running = 0

  local function current()
    local co, main = coroutine.running()
    if main or not tasks[co] then
      return nil
    end
    return co
  end

  local function enqueue(co)
    qtail = qtail + 1
    queue[qtail] = co
  end

  local function step(co)
    running = running + 1
    local ok, res = coroutine.resume(co)
    running = running - 1
    if not ok then
      sched.errors[#sched.errors + 1] = traceback(co, tostring(res))
      tasks[co] = nil
    elseif coroutine.status(co) == "dead" then
      tasks[co] = nil
    elseif res ~= BLOCK then
      sched.errors[#sched.errors + 1] = "task yielded a foreign value: " .. tostring(res)
    end
  end

  local function block()
    local co = current()
    if not co then
      error("cannot block outside of a task", 3)
    end
    coroutine.yield(BLOCK)
  end

  local host = {}

  -- the handle cancels a task that is not running (closes its coroutine, so its
  -- to-be-closed values close); a running or finished task is left alone
  local function spawnWith(label, fn)
    local co = coroutine.create(fn)
    tasks[co] = true
    taskContext[co] = label
    if eager then
      step(co)
    else
      enqueue(co)
    end
    return {
      cancel = function()
        if coroutine.status(co) == "suspended" then
          tasks[co] = nil
          local ok, err = coroutine.close(co)
          if not ok then
            sched.errors[#sched.errors + 1] = traceback(co, tostring(err))
          end
          return true
        end
        return false
      end,
    }
  end

  -- `scope.run` switches the running code's context for the duration of a call
  local override = setmetatable({}, { __mode = "k" })
  local MAIN = {}

  local function currentContext()
    local co = current()
    local key = co or MAIN
    local stack = override[key]
    if stack and #stack > 0 then
      return stack[#stack]
    end
    return co and taskContext[co] or "host"
  end

  function host.spawn(fn)
    spawnWith("host", fn)
  end

  if contexts then
    function host.capture()
      local label = currentContext()
      return {
        spawn = function(fn)
          return spawnWith(label, fn)
        end,
        run = function(fn, ...)
          local key = current() or MAIN
          local stack = override[key] or {}
          override[key] = stack
          stack[#stack + 1] = label
          local result = table.pack(pcall(fn, ...))
          table.remove(stack)
          if not result[1] then
            error(result[2], 0)
          end
          return table.unpack(result, 2, result.n)
        end,
      }
    end
  end

  function sched.spawnAs(label, fn)
    spawnWith(label, fn)
  end

  function sched.context()
    return currentContext()
  end

  function host.latch()
    local latch = { opened = false, waiters = { n = 0 }, wakers = setmetatable({ _n = 0 }, WAKERS_MT) }
    function latch.open(_)
      if latch.opened then
        return
      end
      latch.opened = true
      local waiters, wakers = latch.waiters, latch.wakers
      latch.waiters, latch.wakers = nil, nil
      for i = 1, waiters.n do
        local co = waiters[i]
        if co then
          enqueue(co)
        end
      end
      -- sleeps that wait on this latch too (`host.sleep(ms, latch)`)
      local node = wakers._head
      wakers._head, wakers._tail, wakers._n = nil, nil, 0
      while node do
        local nxt = node.next
        node.prev, node.next = nil, nil
        node.wake()
        node = nxt
      end
    end
    function latch.wait(_)
      if latch.opened then
        return
      end
      local co = current()
      if not co then
        error("latch:wait() called outside of a task", 2)
      end
      local waiters = latch.waiters
      local idx = waiters.n + 1
      waiters.n = idx
      waiters[idx] = co
      local _ <close> = setmetatable({
        function()
          if not latch.opened and waiters[idx] == co then
            waiters[idx] = nil
          end
        end,
      }, CLOSE_MT)
      block()
    end
    return latch
  end

  local function before(a, b)
    return a.at < b.at or (a.at == b.at and a.seq < b.seq)
  end

  local function siftDown(i, item, n)
    while true do
      local left = i * 2
      if left > n then
        break
      end
      local child = timers[left]
      local right = left + 1
      if right <= n and before(timers[right], child) then
        left = right
        child = timers[right]
      end
      if not before(child, item) then
        break
      end
      timers[i] = child
      child.idx = i
      i = left
    end
    timers[i] = item
    item.idx = i
  end

  local function addTimer(at, fn)
    if at ~= at then
      at = now
    end
    timerSeq = timerSeq + 1
    local t = { at = at, seq = timerSeq, fn = fn, idx = nil }
    local i = #timers + 1
    while i > 1 do
      local p = i // 2
      local parent = timers[p]
      if not before(t, parent) then
        break
      end
      timers[i] = parent
      parent.idx = i
      i = p
    end
    timers[i] = t
    t.idx = i
    return t
  end

  local function popTimer()
    local n = #timers
    local first = timers[1]
    if first then
      first.idx = nil
    end
    if n == 1 then
      timers[1] = nil
      return
    end
    local last = timers[n]
    timers[n] = nil
    siftDown(1, last, n - 1)
  end

  local function removeTimer(t)
    local i = t and t.idx
    if not i then
      return
    end
    t.idx = nil
    t.fn = nil
    local n = #timers
    if i == n then
      timers[n] = nil
      return
    end
    local last = timers[n]
    timers[n] = nil
    n = n - 1
    while i > 1 do
      local p = i // 2
      local parent = timers[p]
      if not before(last, parent) then
        break
      end
      timers[i] = parent
      parent.idx = i
      i = p
    end
    siftDown(i, last, n)
  end

  -- `latch` (optional host capability): the sleep also ends when the latch opens
  function host.sleep(ms, latch)
    local co = current()
    if not co then
      error("sleep() called outside of a task", 2)
    end
    if latch and latch.opened then
      return
    end
    local targetCo = co
    local targetLatch = latch
    local wakerNode
    local woken = false
    local timer
    local function unlink()
      local l = targetLatch
      local node = wakerNode
      targetCo, targetLatch, wakerNode = nil, nil, nil
      if l and l.wakers and node then
        local wakers = l.wakers
        if node.prev then
          node.prev.next = node.next
        else
          wakers._head = node.next
        end
        if node.next then
          node.next.prev = node.prev
        else
          wakers._tail = node.prev
        end
        node.prev, node.next = nil, nil
        wakers._n = wakers._n - 1
      end
    end
    local function wake()
      if not woken then
        woken = true
        local c = targetCo
        unlink()
        removeTimer(timer)
        enqueue(c)
      end
    end
    timer = addTimer(now + (ms or 0), wake)
    if latch and latch.wakers then
      local wakers = latch.wakers
      local tail = wakers._tail
      wakerNode = { wake = wake, prev = tail }
      if tail then
        tail.next = wakerNode
      else
        wakers._head = wakerNode
      end
      wakers._tail = wakerNode
      wakers._n = wakers._n + 1
    end
    local _ <close> = setmetatable({
      function()
        if not woken then
          woken = true
          unlink()
        end
        removeTimer(timer)
      end,
    }, CLOSE_MT)
    block()
  end

  function host.now()
    return now
  end

  sched.host = host

  -- schedule a plain callback (not a task) at `now + ms`; returns a canceller
  function sched.setTimeout(fn, ms)
    local t
    t = addTimer(now + (ms or 0), function()
      if not t.cancelled then
        fn()
      end
    end)
    return function()
      t.cancelled = true
      removeTimer(t)
    end
  end

  function sched.now()
    return now
  end

  function sched.pending()
    return #timers
  end

  local function drain()
    while qhead <= qtail do
      local co = queue[qhead]
      queue[qhead] = nil
      qhead = qhead + 1
      if coroutine.status(co) == "suspended" then
        step(co)
      end
    end
    qhead, qtail = 1, 0
  end

  -- fire every timer due at the earliest instant not later than `limit`
  local function fireNext(limit)
    while timers[1] and timers[1].cancelled do
      popTimer()
    end
    local t = timers[1]
    if not t or (limit and t.at > limit) then
      return false
    end
    if t.at > now then
      now = t.at
    end
    -- fire all timers at this instant in order of creation
    while true do
      local u = timers[1]
      if not u or u.at > now then
        break
      end
      popTimer()
      if not u.cancelled and u.fn then
        u.fn()
      end
    end
    return true
  end

  local function loop()
    while true do
      drain()
      if advancer then
        local a = advancer
        if fireNext(a.target) then
          -- keep going: newly runnable tasks are drained on the next iteration
        else
          if a.target ~= math.huge then
            now = math.max(now, a.target)
          end
          advancer = nil
          if a.co then
            enqueue(a.co)
          else
            return
          end
        end
      elseif sched.auto and fireNext() then
        -- continue
      else
        return
      end
    end
  end

  function sched.run()
    if running > 0 then
      error("sched.run() is not reentrant", 2)
    end
    loop()
  end

  local function advanceTo(target)
    local co = current()
    if co then
      if advancer then
        error("concurrent advance", 3)
      end
      advancer = { co = co, target = target }
      block()
    else
      if running > 0 then
        error("sched.advance() / sched.runAll() is not reentrant", 3)
      end
      advancer = { target = target }
      loop()
    end
  end

  function sched.advance(ms)
    advanceTo(now + ms)
  end

  function sched.runAll()
    advanceTo(math.huge)
  end

  -- run `fn` as a task and drive the scheduler until it finishes or stalls;
  -- returns ok, err (err is "stalled" if the task never completed)
  function sched.drive(fn)
    local done, ok, err = false, true, nil
    host.spawn(function()
      local success, e = xpcall(fn, function(e)
        if type(e) == "table" or type(e) == "userdata" then
          return e
        end
        return traceback(tostring(e), 2)
      end)
      done, ok, err = true, success, e
    end)
    loop()
    if not done then
      return false, "stalled: the test task never completed (deadlock or missing advance)"
    end
    return ok, err
  end

  return sched
end

M.BLOCK = BLOCK

return M
