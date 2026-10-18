-- POST /echo with a 1 MiB body, reporting like report.lua.
wrk.method = "POST"
wrk.body = string.rep("a", 1048576)
wrk.headers["Content-Type"] = "application/octet-stream"
dofile("/bench/loadgen/report.lua")
