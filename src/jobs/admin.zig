//! The admin JSON routes (§7.3), mounted by `Client.adminRoutes(group)`:
//!
//!     GET    /jobs?state=&queue=&kind=&limit=&before=   {"jobs":[...],"next":id|null}
//!     GET    /jobs/:id                                  the job, or 404
//!     POST   /jobs/:id/retry, /jobs/:id/cancel          {"ok":true}, or 409
//!     DELETE /jobs/:id                                  204, or 409 unless finished
//!     GET    /counts                                    {"counts":[...]}
//!     GET    /cron                                      {"cron":[...]}
//!     POST   /cron/:name/trigger                        {"id":..,"inserted":..}
//!
//! Mount it behind your own authentication. The routes serve the jobs client
//! of the process (one per process).
const std = @import("std");
const dusty = @import("dusty");
const root = @import("root.zig");

var active: ?*root.Client = null;

pub fn mount(client: *root.Client, group: anytype) void {
    active = client;
    group.get("/jobs", list);
    group.get("/jobs/:id", getOne);
    group.post("/jobs/:id/retry", retry);
    group.post("/jobs/:id/cancel", cancel);
    group.delete("/jobs/:id", remove);
    group.get("/counts", counts);
    group.get("/cron", cronList);
    group.post("/cron/:name/trigger", trigger);
}

fn needClient(res: *dusty.Response) ?*root.Client {
    if (active) |c| return c;
    res.fail(.service_unavailable, "the job queue is not running");
    return null;
}

fn fromError(res: *dusty.Response, err: root.Error) !void {
    switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        error.NotFound => res.fail(.not_found, "not found"),
        error.ServiceUnavailable => res.fail(.service_unavailable, "the job store is unavailable"),
        error.GatewayTimeout => res.fail(.gateway_timeout, "the job store timed out"),
        else => res.fail(.internal_server_error, "the job store failed"),
    }
}

fn idOf(req: *dusty.Request, res: *dusty.Response) ?root.Id {
    const text = req.param("id") orelse {
        res.fail(.bad_request, "missing job id");
        return null;
    };
    return std.fmt.parseInt(root.Id, text, 10) catch {
        res.fail(.bad_request, "bad job id");
        return null;
    };
}

fn stateOf(text: []const u8) ?root.State {
    return std.meta.stringToEnum(root.State, text);
}

fn list(req: *dusty.Request, res: *dusty.Response) !void {
    const c = needClient(res) orelse return;
    var f: root.Filter = .{};
    if (req.queryParam("state")) |s| f.state = stateOf(s) orelse return res.fail(.bad_request, "unknown state");
    f.queue = req.queryParam("queue");
    f.kind = req.queryParam("kind");
    if (req.queryParam("limit")) |l| f.limit = @intCast(std.math.clamp(std.fmt.parseInt(u32, l, 10) catch return res.fail(.bad_request, "bad limit"), 1, 500));
    if (req.queryParam("before")) |b| f.before = std.fmt.parseInt(root.Id, b, 10) catch return res.fail(.bad_request, "bad before");
    const jobs = c.list(req, f) catch |e| return fromError(res, e);
    const next: ?root.Id = if (jobs.len == f.limit and jobs.len > 0) jobs[jobs.len - 1].id else null;
    try res.json(.{ .jobs = jobs, .next = next });
}

fn getOne(req: *dusty.Request, res: *dusty.Response) !void {
    const c = needClient(res) orelse return;
    const id = idOf(req, res) orelse return;
    const job = c.get(req, id) catch |e| return fromError(res, e);
    if (job) |j| return res.json(j);
    res.fail(.not_found, "no such job");
}

fn retry(req: *dusty.Request, res: *dusty.Response) !void {
    const c = needClient(res) orelse return;
    const id = idOf(req, res) orelse return;
    const ok = c.retry(req, id) catch |e| return fromError(res, e);
    if (!ok) return res.fail(.conflict, "the job is not in a state that can be retried");
    try res.json(.{ .ok = true });
}

fn cancel(req: *dusty.Request, res: *dusty.Response) !void {
    const c = needClient(res) orelse return;
    const id = idOf(req, res) orelse return;
    const ok = c.cancel(req, id) catch |e| return fromError(res, e);
    if (!ok) return res.fail(.conflict, "the job has finished already");
    try res.json(.{ .ok = true });
}

fn remove(req: *dusty.Request, res: *dusty.Response) !void {
    const c = needClient(res) orelse return;
    const id = idOf(req, res) orelse return;
    const ok = c.delete(req, id) catch |e| return fromError(res, e);
    if (!ok) return res.fail(.conflict, "only finished jobs can be deleted");
    res.status = .no_content;
}

fn counts(req: *dusty.Request, res: *dusty.Response) !void {
    const c = needClient(res) orelse return;
    const rows = c.counts(req) catch |e| return fromError(res, e);
    try res.json(.{ .counts = rows });
}

fn cronList(req: *dusty.Request, res: *dusty.Response) !void {
    const c = needClient(res) orelse return;
    const rows = c.cronList(req) catch |e| return fromError(res, e);
    try res.json(.{ .cron = rows });
}

fn trigger(req: *dusty.Request, res: *dusty.Response) !void {
    const c = needClient(res) orelse return;
    const name = req.param("name") orelse return res.fail(.bad_request, "missing schedule name");
    const r = c.cronTrigger(req, name) catch |e| return fromError(res, e);
    try res.json(r);
}
