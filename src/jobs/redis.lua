-- The Redis/Valkey job store's scripts (p3/jobs, design-jobs.md §4.3). One
-- script, loaded with SCRIPT LOAD and called by EVALSHA:
--   ARGV[1] = key prefix ("anole:"), ARGV[2] = the operation, ARGV[3..] = its arguments.
-- Times are Unix milliseconds. Keys are built inside the script, which is
-- why Redis Cluster is not supported (single node, as the connector).
local P = ARGV[1] .. 'jobs:'
local op = ARGV[2]
local BASE = 1577836800000
local PRIO = 4398046511104 -- 2^42

local function jk(id) return P .. 'job:' .. id end
local function qkey(queue, kind) return P .. 'q:' .. queue .. ':' .. kind end
local function kindskey(queue) return P .. 'q:' .. queue .. ':kinds' end
local function pad(id) return string.format('%016d', id) end
local function score(priority, run_at) return tonumber(priority) * PRIO + (tonumber(run_at) - BASE) end

local function load(id)
  local flat = redis.call('HGETALL', jk(id))
  if #flat == 0 then return nil end
  local j = {}
  for i = 1, #flat, 2 do j[flat[i]] = flat[i + 1] end
  return j
end

local function unindex(id, j)
  local m = pad(id)
  redis.call('ZREM', qkey(j.queue, j.kind), m)
  redis.call('ZREM', P .. 'scheduled', m)
  redis.call('ZREM', P .. 'running', m)
  redis.call('ZREM', P .. 'finished:completed', m)
  redis.call('ZREM', P .. 'finished:dead', m)
  redis.call('ZREM', P .. 'finished:cancelled', m)
end

local function index(id, j)
  local m = pad(id)
  local s = j.state
  if s == 'available' then
    redis.call('ZADD', qkey(j.queue, j.kind), score(j.priority, j.run_at), m)
    redis.call('SADD', kindskey(j.queue), j.kind)
  elseif s == 'scheduled' or s == 'retrying' then
    redis.call('ZADD', P .. 'scheduled', tonumber(j.run_at), m)
  elseif s == 'running' then
    redis.call('ZADD', P .. 'running', tonumber(j.lease_until), m)
  else
    redis.call('ZADD', P .. 'finished:' .. s, tonumber(j.finished_at or 0), m)
  end
end

local function put(id, j, k, v)
  if v == nil then
    redis.call('HDEL', jk(id), k)
    j[k] = nil
  else
    redis.call('HSET', jk(id), k, v)
    j[k] = tostring(v)
  end
end

local function covers(scope, s)
  if scope == '3' then return true end
  if s == 'scheduled' or s == 'available' or s == 'retrying' then return true end
  return scope == '2' and s == 'running'
end

-- Moves the job to state `to`; its unique key stays only while the scope covers it.
local function settle(id, j, to)
  put(id, j, 'state', to)
  if j.unique_key and not covers(j.unique_scope, to) then
    redis.call('DEL', P .. 'unique:' .. j.unique_key)
    put(id, j, 'unique_key', nil)
  end
end

local function wake(queue) redis.call('PUBLISH', P .. 'wake', queue) end

local function add_error(j, entry_json)
  local list = cjson.decode(j.errors or '[]')
  if type(list) ~= 'table' then list = {} end
  local n = #list
  list[n + 1] = cjson.decode(entry_json)
  while #list > 10 do table.remove(list, 1) end
  return cjson.encode(list)
end

local function flat(j)
  local out = {}
  for k, v in pairs(j) do
    out[#out + 1] = k
    out[#out + 1] = v
  end
  return out
end

-- enqueue at ARGV[o..]: now, queue, kind, args, meta, priority, max_attempts,
-- run_at, timeout_ms, unique_hex, unique_scope, notify
local function enqueue(o)
  local now, queue, kind = tonumber(ARGV[o]), ARGV[o + 1], ARGV[o + 2]
  local unique, notify = ARGV[o + 9], ARGV[o + 11]
  if unique ~= '' then
    local ex = redis.call('GET', P .. 'unique:' .. unique)
    if ex then return {tonumber(ex), 0} end
  end
  local run_at = tonumber(ARGV[o + 7])
  local id = redis.call('INCR', P .. 'seq')
  local j = {
    id = tostring(id), queue = queue, kind = kind, state = (run_at <= now) and 'available' or 'scheduled',
    priority = ARGV[o + 5], attempt = '0', max_attempts = ARGV[o + 6], args = ARGV[o + 3], meta = ARGV[o + 4],
    run_at = ARGV[o + 7], created_at = ARGV[o], errors = '[]',
  }
  if ARGV[o + 8] ~= '' then j.timeout_ms = ARGV[o + 8] end
  if unique ~= '' then
    j.unique_key = unique
    j.unique_scope = ARGV[o + 10]
    redis.call('SET', P .. 'unique:' .. unique, id)
  end
  redis.call('HSET', jk(id), unpack(flat(j)))
  redis.call('SADD', P .. 'queues', queue)
  index(id, j)
  if j.state == 'available' and notify == '1' then wake(queue) end
  return {id, 1}
end

if op == 'enqueue' then
  return enqueue(3)

elseif op == 'claim' then
  local now, lease_until, worker, queue, n = ARGV[3], ARGV[4], ARGV[5], ARGV[6], tonumber(ARGV[7])
  local kinds = {}
  if #ARGV >= 8 then
    for i = 8, #ARGV do kinds[#kinds + 1] = ARGV[i] end
  else
    kinds = redis.call('SMEMBERS', kindskey(queue))
  end
  local out = {}
  for _ = 1, n do
    local best, best_kind, best_score
    for _, kind in ipairs(kinds) do
      local head = redis.call('ZRANGE', qkey(queue, kind), 0, 0, 'WITHSCORES')
      if #head == 0 then
        redis.call('SREM', kindskey(queue), kind)
      else
        local sc = tonumber(head[2])
        if best == nil or sc < best_score or (sc == best_score and head[1] < best) then
          best, best_kind, best_score = head[1], kind, sc
        end
      end
    end
    if best == nil then break end
    redis.call('ZREM', qkey(queue, best_kind), best)
    local id = tonumber(best)
    local j = load(id)
    if j then
      put(id, j, 'state', 'running')
      put(id, j, 'attempt', tonumber(j.attempt) + 1)
      put(id, j, 'attempted_at', now)
      put(id, j, 'lease_until', lease_until)
      put(id, j, 'worker', worker)
      if j.unique_key and j.unique_scope == '1' then
        redis.call('DEL', P .. 'unique:' .. j.unique_key)
        put(id, j, 'unique_key', nil)
      end
      redis.call('ZADD', P .. 'running', tonumber(lease_until), best)
      out[#out + 1] = flat(j)
    end
  end
  return out

elseif op == 'stage' then
  local now, limit, notify = ARGV[3], tonumber(ARGV[4]), ARGV[5]
  local ids = redis.call('ZRANGEBYSCORE', P .. 'scheduled', '-inf', now, 'LIMIT', 0, limit)
  local queues, count = {}, 0
  for _, m in ipairs(ids) do
    local id = tonumber(m)
    local j = load(id)
    redis.call('ZREM', P .. 'scheduled', m)
    if j and (j.state == 'scheduled' or j.state == 'retrying') then
      put(id, j, 'state', 'available')
      index(id, j)
      queues[j.queue] = true
      count = count + 1
    end
  end
  if notify == '1' then for q in pairs(queues) do wake(q) end end
  return count

elseif op == 'heartbeat' then
  local until_ms = ARGV[3]
  local out = {}
  for i = 4, #ARGV, 2 do
    local id = tonumber(ARGV[i])
    local j = load(id)
    if j and j.state == 'running' and j.attempt == ARGV[i + 1] then
      put(id, j, 'lease_until', until_ms)
      redis.call('ZADD', P .. 'running', tonumber(until_ms), pad(id))
      out[#out + 1] = id
      out[#out + 1] = tonumber(j.attempt)
    end
  end
  return out

elseif op == 'finish' then
  local id, attempt, to, delta = tonumber(ARGV[3]), ARGV[4], ARGV[5], tonumber(ARGV[6])
  local run_at, finished_at, err, notify = ARGV[7], ARGV[8], ARGV[9], ARGV[10]
  local j = load(id)
  if not j or j.state ~= 'running' or j.attempt ~= attempt then return 0 end
  unindex(id, j)
  settle(id, j, to)
  put(id, j, 'attempt', tonumber(j.attempt) + delta)
  if run_at ~= '' then put(id, j, 'run_at', run_at) end
  if finished_at ~= '' then put(id, j, 'finished_at', finished_at) else put(id, j, 'finished_at', nil) end
  put(id, j, 'lease_until', nil)
  if to == 'available' or to == 'scheduled' then put(id, j, 'worker', nil) end
  if err ~= '' then put(id, j, 'errors', add_error(j, err)) end
  index(id, j)
  if to == 'available' and notify == '1' then wake(j.queue) end
  return 1

elseif op == 'rescue' then
  local now, limit, at, notify = ARGV[3], tonumber(ARGV[4]), ARGV[5], ARGV[6]
  local ids = redis.call('ZRANGEBYSCORE', P .. 'running', '-inf', '(' .. now, 'LIMIT', 0, limit)
  local out = {}
  for _, m in ipairs(ids) do
    local id = tonumber(m)
    local j = load(id)
    redis.call('ZREM', P .. 'running', m)
    if j and j.state == 'running' then
      local dead = tonumber(j.attempt) >= tonumber(j.max_attempts)
      unindex(id, j)
      settle(id, j, dead and 'dead' or 'available')
      if dead then put(id, j, 'finished_at', now) else put(id, j, 'finished_at', nil) end
      put(id, j, 'lease_until', nil)
      put(id, j, 'worker', nil)
      put(id, j, 'errors', add_error(j, cjson.encode({attempt = tonumber(j.attempt), at = at, error = 'LeaseExpired', message = 'the worker running it stopped or lost the database'})))
      index(id, j)
      if not dead and notify == '1' then wake(j.queue) end
      out[#out + 1] = id
      out[#out + 1] = dead and 1 or 0
    end
  end
  return out

elseif op == 'cancel' then
  local id, now = tonumber(ARGV[3]), ARGV[4]
  local j = load(id)
  if not j then return 0 end
  local s = j.state
  if not (s == 'scheduled' or s == 'available' or s == 'retrying' or s == 'running') then return 0 end
  unindex(id, j)
  settle(id, j, 'cancelled')
  put(id, j, 'finished_at', now)
  put(id, j, 'lease_until', nil)
  index(id, j)
  return 1

elseif op == 'retry' then
  local id, now, notify = tonumber(ARGV[3]), ARGV[4], ARGV[5]
  local j = load(id)
  if not j then return 0 end
  local s = j.state
  if not (s == 'dead' or s == 'cancelled' or s == 'retrying' or s == 'scheduled') then return 0 end
  unindex(id, j)
  settle(id, j, 'available')
  put(id, j, 'run_at', now)
  put(id, j, 'finished_at', nil)
  put(id, j, 'max_attempts', math.max(tonumber(j.max_attempts), tonumber(j.attempt) + 1))
  index(id, j)
  if notify == '1' then wake(j.queue) end
  return 1

elseif op == 'delete' then
  local id = tonumber(ARGV[3])
  local j = load(id)
  if not j then return 0 end
  local s = j.state
  if not (s == 'completed' or s == 'dead' or s == 'cancelled') then return 0 end
  unindex(id, j)
  if j.unique_key then redis.call('DEL', P .. 'unique:' .. j.unique_key) end
  redis.call('DEL', jk(id))
  return 1

elseif op == 'prune' then
  local state, before, limit = ARGV[3], ARGV[4], tonumber(ARGV[5])
  local ids = redis.call('ZRANGEBYSCORE', P .. 'finished:' .. state, '-inf', '(' .. before, 'LIMIT', 0, limit)
  for _, m in ipairs(ids) do
    local id = tonumber(m)
    local j = load(id)
    if j and j.unique_key then redis.call('DEL', P .. 'unique:' .. j.unique_key) end
    redis.call('DEL', jk(id))
    redis.call('ZREM', P .. 'finished:' .. state, m)
  end
  return #ids

elseif op == 'list' then
  -- state, queue, kind, before (each '' for none), limit
  local state, queue, kind, before, limit = ARGV[3], ARGV[4], ARGV[5], ARGV[6], tonumber(ARGV[7])
  local sets = {}
  local function add(key) sets[#sets + 1] = key end
  local function add_available()
    local queues = (queue ~= '') and {queue} or redis.call('SMEMBERS', P .. 'queues')
    for _, q in ipairs(queues) do
      for _, k in ipairs(redis.call('SMEMBERS', kindskey(q))) do add(qkey(q, k)) end
    end
  end
  if state == '' then
    add_available(); add(P .. 'scheduled'); add(P .. 'running')
    add(P .. 'finished:completed'); add(P .. 'finished:dead'); add(P .. 'finished:cancelled')
  elseif state == 'available' then add_available()
  elseif state == 'scheduled' or state == 'retrying' then add(P .. 'scheduled')
  elseif state == 'running' then add(P .. 'running')
  else add(P .. 'finished:' .. state) end
  local hits = {}
  for _, key in ipairs(sets) do
    for _, m in ipairs(redis.call('ZRANGE', key, 0, 19999)) do
      local id = tonumber(m)
      local j = load(id)
      if j and (state == '' or j.state == state) and (queue == '' or j.queue == queue)
         and (kind == '' or j.kind == kind) and (before == '' or id < tonumber(before)) then
        hits[#hits + 1] = {id, j}
      end
    end
  end
  table.sort(hits, function(a, b) return a[1] > b[1] end)
  local out = {}
  for i = 1, math.min(#hits, limit) do out[i] = flat(hits[i][2]) end
  return out

elseif op == 'counts' then
  local tally, order = {}, {}
  local function bump(queue, state)
    local key = queue .. '\0' .. state
    if not tally[key] then tally[key] = 0; order[#order + 1] = {queue, state} end
    tally[key] = tally[key] + 1
  end
  for _, q in ipairs(redis.call('SMEMBERS', P .. 'queues')) do
    local n = 0
    for _, k in ipairs(redis.call('SMEMBERS', kindskey(q))) do n = n + redis.call('ZCARD', qkey(q, k)) end
    if n > 0 then tally[q .. '\0available'] = n; order[#order + 1] = {q, 'available'} end
  end
  for _, key in ipairs({P .. 'scheduled', P .. 'running', P .. 'finished:dead'}) do
    for _, m in ipairs(redis.call('ZRANGE', key, 0, -1)) do
      local q = redis.call('HGET', jk(tonumber(m)), 'queue')
      local s = redis.call('HGET', jk(tonumber(m)), 'state')
      if q and s then bump(q, s) end
    end
  end
  local out = {}
  for _, e in ipairs(order) do
    out[#out + 1] = {e[1], e[2], tally[e[1] .. '\0' .. e[2]]}
  end
  return out

elseif op == 'cron_set' then
  local name, spec, tick = ARGV[3], ARGV[4], ARGV[5]
  redis.call('HSET', P .. 'cron:' .. name, 'spec', spec, 'last_tick', tick)
  redis.call('SADD', P .. 'crons', name)
  return 1

elseif op == 'cron_tick' then
  -- name, spec, tick, then an enqueue (12 args) when the tick has a job
  local name, spec, tick = ARGV[3], ARGV[4], tonumber(ARGV[5])
  local key = P .. 'cron:' .. name
  local last = redis.call('HGET', key, 'last_tick')
  if last and tonumber(last) >= tick then return {0, 0, 0} end
  redis.call('HSET', key, 'spec', spec, 'last_tick', ARGV[5])
  redis.call('SADD', P .. 'crons', name)
  if #ARGV >= 17 then
    local r = enqueue(6)
    return {1, r[1], r[2]}
  end
  return {1, 0, 0}

elseif op == 'leader_take' then
  local owner, ttl = ARGV[3], ARGV[4]
  local key = P .. 'leader'
  if redis.call('SET', key, owner, 'NX', 'PX', ttl) then return 1 end
  if redis.call('GET', key) == owner then
    redis.call('PEXPIRE', key, ttl)
    return 1
  end
  return 0

elseif op == 'leader_release' then
  local key = P .. 'leader'
  if redis.call('GET', key) == ARGV[3] then redis.call('DEL', key) end
  return 1
end

return redis.error_reply('unknown jobs operation ' .. tostring(op))
