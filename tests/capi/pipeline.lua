-- wrk -s tests/capi/pipeline.lua: 16 requests per write (HttpArena's pipelined profile)
init = function(args)
  local path = wrk.path
  local r = {}
  for i = 1, 16 do r[i] = wrk.format(nil, path) end
  req = table.concat(r)
end
request = function() return req end
