// Adapted from lalinsky/dusty (MIT, Copyright (c) 2025 Lukas Lalinsky and
// contributors), base d3cb485, via Anole's fork xuckless/dusty 86d152f.
// See LICENSE.dusty and THIRD_PARTY_NOTICES.

const std = @import("std");

const c = @import("llhttp");

/// A request method: `.get`, `.post`, `.put`, `.delete` and the rest that
/// llhttp knows. `req.method`.
pub const Method = enum(c.llhttp_method_t) {
    delete = c.HTTP_DELETE,
    get = c.HTTP_GET,
    head = c.HTTP_HEAD,
    post = c.HTTP_POST,
    put = c.HTTP_PUT,
    connect = c.HTTP_CONNECT,
    options = c.HTTP_OPTIONS,
    trace = c.HTTP_TRACE,
    copy = c.HTTP_COPY,
    lock = c.HTTP_LOCK,
    mkcol = c.HTTP_MKCOL,
    move = c.HTTP_MOVE,
    propfind = c.HTTP_PROPFIND,
    proppatch = c.HTTP_PROPPATCH,
    search = c.HTTP_SEARCH,
    unlock = c.HTTP_UNLOCK,
    bind = c.HTTP_BIND,
    rebind = c.HTTP_REBIND,
    unbind = c.HTTP_UNBIND,
    acl = c.HTTP_ACL,
    report = c.HTTP_REPORT,
    mkactivity = c.HTTP_MKACTIVITY,
    checkout = c.HTTP_CHECKOUT,
    merge = c.HTTP_MERGE,
    msearch = c.HTTP_MSEARCH,
    notify = c.HTTP_NOTIFY,
    subscribe = c.HTTP_SUBSCRIBE,
    unsubscribe = c.HTTP_UNSUBSCRIBE,
    patch = c.HTTP_PATCH,
    purge = c.HTTP_PURGE,
    mkcalendar = c.HTTP_MKCALENDAR,
    link = c.HTTP_LINK,
    unlink = c.HTTP_UNLINK,
    source = c.HTTP_SOURCE,
    pri = c.HTTP_PRI,
    describe = c.HTTP_DESCRIBE,
    announce = c.HTTP_ANNOUNCE,
    setup = c.HTTP_SETUP,
    play = c.HTTP_PLAY,
    pause = c.HTTP_PAUSE,
    teardown = c.HTTP_TEARDOWN,
    get_parameter = c.HTTP_GET_PARAMETER,
    set_parameter = c.HTTP_SET_PARAMETER,
    redirect = c.HTTP_REDIRECT,
    record = c.HTTP_RECORD,
    flush = c.HTTP_FLUSH,
    query = c.HTTP_QUERY,

    /// The method as it goes on the wire: "GET".
    pub fn name(self: Method) [:0]const u8 {
        return std.mem.span(c.llhttp_method_name(@backingInt(self)));
    }

    pub fn format(self: Method, writer: anytype) !void {
        try writer.writeAll(self.name());
    }
};

test "Method: construct from llhttp_method_t" {
    const method: Method = @fromBackingInt(@intCast(c.HTTP_GET));
    try std.testing.expectEqual(.get, method);
}

test "Method: name() is the wire token (GET, POST, DELETE)" {
    try std.testing.expectEqualStrings("GET", Method.get.name());
    try std.testing.expectEqualStrings("POST", Method.post.name());
    try std.testing.expectEqualStrings("DELETE", Method.delete.name());
}

test "Method: {f} prints the wire token" {
    var buf: [32]u8 = undefined;
    const result = try std.fmt.bufPrint(&buf, "{f}", .{Method.get});
    try std.testing.expectEqualStrings("GET", result);
}

/// A response status, named as in the IANA registry: `.ok`, `.created`,
/// `.not_found`, `.internal_server_error`... `res.status`; `@intFromEnum`
/// gives the code.
pub const Status = enum(c.llhttp_status_t) {
    @"continue" = c.HTTP_STATUS_CONTINUE,
    switching_protocols = c.HTTP_STATUS_SWITCHING_PROTOCOLS,
    processing = c.HTTP_STATUS_PROCESSING,
    early_hints = c.HTTP_STATUS_EARLY_HINTS,
    response_is_stale = c.HTTP_STATUS_RESPONSE_IS_STALE,
    revalidation_failed = c.HTTP_STATUS_REVALIDATION_FAILED,
    disconnected_operation = c.HTTP_STATUS_DISCONNECTED_OPERATION,
    heuristic_expiration = c.HTTP_STATUS_HEURISTIC_EXPIRATION,
    miscellaneous_warning = c.HTTP_STATUS_MISCELLANEOUS_WARNING,
    ok = c.HTTP_STATUS_OK,
    created = c.HTTP_STATUS_CREATED,
    accepted = c.HTTP_STATUS_ACCEPTED,
    non_authoritative_information = c.HTTP_STATUS_NON_AUTHORITATIVE_INFORMATION,
    no_content = c.HTTP_STATUS_NO_CONTENT,
    reset_content = c.HTTP_STATUS_RESET_CONTENT,
    partial_content = c.HTTP_STATUS_PARTIAL_CONTENT,
    multi_status = c.HTTP_STATUS_MULTI_STATUS,
    already_reported = c.HTTP_STATUS_ALREADY_REPORTED,
    transformation_applied = c.HTTP_STATUS_TRANSFORMATION_APPLIED,
    im_used = c.HTTP_STATUS_IM_USED,
    miscellaneous_persistent_warning = c.HTTP_STATUS_MISCELLANEOUS_PERSISTENT_WARNING,
    multiple_choices = c.HTTP_STATUS_MULTIPLE_CHOICES,
    moved_permanently = c.HTTP_STATUS_MOVED_PERMANENTLY,
    found = c.HTTP_STATUS_FOUND,
    see_other = c.HTTP_STATUS_SEE_OTHER,
    not_modified = c.HTTP_STATUS_NOT_MODIFIED,
    use_proxy = c.HTTP_STATUS_USE_PROXY,
    switch_proxy = c.HTTP_STATUS_SWITCH_PROXY,
    temporary_redirect = c.HTTP_STATUS_TEMPORARY_REDIRECT,
    permanent_redirect = c.HTTP_STATUS_PERMANENT_REDIRECT,
    bad_request = c.HTTP_STATUS_BAD_REQUEST,
    unauthorized = c.HTTP_STATUS_UNAUTHORIZED,
    payment_required = c.HTTP_STATUS_PAYMENT_REQUIRED,
    forbidden = c.HTTP_STATUS_FORBIDDEN,
    not_found = c.HTTP_STATUS_NOT_FOUND,
    method_not_allowed = c.HTTP_STATUS_METHOD_NOT_ALLOWED,
    not_acceptable = c.HTTP_STATUS_NOT_ACCEPTABLE,
    proxy_authentication_required = c.HTTP_STATUS_PROXY_AUTHENTICATION_REQUIRED,
    request_timeout = c.HTTP_STATUS_REQUEST_TIMEOUT,
    conflict = c.HTTP_STATUS_CONFLICT,
    gone = c.HTTP_STATUS_GONE,
    length_required = c.HTTP_STATUS_LENGTH_REQUIRED,
    precondition_failed = c.HTTP_STATUS_PRECONDITION_FAILED,
    payload_too_large = c.HTTP_STATUS_PAYLOAD_TOO_LARGE,
    uri_too_long = c.HTTP_STATUS_URI_TOO_LONG,
    unsupported_media_type = c.HTTP_STATUS_UNSUPPORTED_MEDIA_TYPE,
    range_not_satisfiable = c.HTTP_STATUS_RANGE_NOT_SATISFIABLE,
    expectation_failed = c.HTTP_STATUS_EXPECTATION_FAILED,
    im_a_teapot = c.HTTP_STATUS_IM_A_TEAPOT,
    page_expired = c.HTTP_STATUS_PAGE_EXPIRED,
    enhance_your_calm = c.HTTP_STATUS_ENHANCE_YOUR_CALM,
    misdirected_request = c.HTTP_STATUS_MISDIRECTED_REQUEST,
    unprocessable_entity = c.HTTP_STATUS_UNPROCESSABLE_ENTITY,
    locked = c.HTTP_STATUS_LOCKED,
    failed_dependency = c.HTTP_STATUS_FAILED_DEPENDENCY,
    too_early = c.HTTP_STATUS_TOO_EARLY,
    upgrade_required = c.HTTP_STATUS_UPGRADE_REQUIRED,
    precondition_required = c.HTTP_STATUS_PRECONDITION_REQUIRED,
    too_many_requests = c.HTTP_STATUS_TOO_MANY_REQUESTS,
    request_header_fields_too_large_unofficial = c.HTTP_STATUS_REQUEST_HEADER_FIELDS_TOO_LARGE_UNOFFICIAL,
    request_header_fields_too_large = c.HTTP_STATUS_REQUEST_HEADER_FIELDS_TOO_LARGE,
    login_timeout = c.HTTP_STATUS_LOGIN_TIMEOUT,
    no_response = c.HTTP_STATUS_NO_RESPONSE,
    retry_with = c.HTTP_STATUS_RETRY_WITH,
    blocked_by_parental_control = c.HTTP_STATUS_BLOCKED_BY_PARENTAL_CONTROL,
    unavailable_for_legal_reasons = c.HTTP_STATUS_UNAVAILABLE_FOR_LEGAL_REASONS,
    client_closed_load_balanced_request = c.HTTP_STATUS_CLIENT_CLOSED_LOAD_BALANCED_REQUEST,
    invalid_x_forwarded_for = c.HTTP_STATUS_INVALID_X_FORWARDED_FOR,
    request_header_too_large = c.HTTP_STATUS_REQUEST_HEADER_TOO_LARGE,
    ssl_certificate_error = c.HTTP_STATUS_SSL_CERTIFICATE_ERROR,
    ssl_certificate_required = c.HTTP_STATUS_SSL_CERTIFICATE_REQUIRED,
    http_request_sent_to_https_port = c.HTTP_STATUS_HTTP_REQUEST_SENT_TO_HTTPS_PORT,
    invalid_token = c.HTTP_STATUS_INVALID_TOKEN,
    client_closed_request = c.HTTP_STATUS_CLIENT_CLOSED_REQUEST,
    internal_server_error = c.HTTP_STATUS_INTERNAL_SERVER_ERROR,
    not_implemented = c.HTTP_STATUS_NOT_IMPLEMENTED,
    bad_gateway = c.HTTP_STATUS_BAD_GATEWAY,
    service_unavailable = c.HTTP_STATUS_SERVICE_UNAVAILABLE,
    gateway_timeout = c.HTTP_STATUS_GATEWAY_TIMEOUT,
    http_version_not_supported = c.HTTP_STATUS_HTTP_VERSION_NOT_SUPPORTED,
    variant_also_negotiates = c.HTTP_STATUS_VARIANT_ALSO_NEGOTIATES,
    insufficient_storage = c.HTTP_STATUS_INSUFFICIENT_STORAGE,
    loop_detected = c.HTTP_STATUS_LOOP_DETECTED,
    bandwidth_limit_exceeded = c.HTTP_STATUS_BANDWIDTH_LIMIT_EXCEEDED,
    not_extended = c.HTTP_STATUS_NOT_EXTENDED,
    network_authentication_required = c.HTTP_STATUS_NETWORK_AUTHENTICATION_REQUIRED,
    web_server_unknown_error = c.HTTP_STATUS_WEB_SERVER_UNKNOWN_ERROR,
    web_server_is_down = c.HTTP_STATUS_WEB_SERVER_IS_DOWN,
    connection_timeout = c.HTTP_STATUS_CONNECTION_TIMEOUT,
    origin_is_unreachable = c.HTTP_STATUS_ORIGIN_IS_UNREACHABLE,
    timeout_occured = c.HTTP_STATUS_TIMEOUT_OCCURED,
    ssl_handshake_failed = c.HTTP_STATUS_SSL_HANDSHAKE_FAILED,
    invalid_ssl_certificate = c.HTTP_STATUS_INVALID_SSL_CERTIFICATE,
    railgun_error = c.HTTP_STATUS_RAILGUN_ERROR,
    site_is_overloaded = c.HTTP_STATUS_SITE_IS_OVERLOADED,
    site_is_frozen = c.HTTP_STATUS_SITE_IS_FROZEN,
    identity_provider_authentication_error = c.HTTP_STATUS_IDENTITY_PROVIDER_AUTHENTICATION_ERROR,
    network_read_timeout = c.HTTP_STATUS_NETWORK_READ_TIMEOUT,
    network_connect_timeout = c.HTTP_STATUS_NETWORK_CONNECT_TIMEOUT,

    /// Converts a status code to the value naming it. `Status` is
    /// exhaustive, so `@enumFromInt` on a code it does not name is illegal
    /// behaviour; a code that came from outside -- a URL, a peer -- has to
    /// come through here.
    pub fn fromCode(code: u16) error{InvalidStatusCode}!Status {
        return std.enums.fromInt(Status, code) orelse error.InvalidStatusCode;
    }

    /// The reason phrase: "Not Found".
    pub fn name(self: Status) [:0]const u8 {
        return std.mem.span(c.llhttp_status_name(@backingInt(self)));
    }

    /// The reason phrase for the status line: RFC 9110's for a standard
    /// code (`Not Found`), else llhttp's name for it.
    pub fn phrase(self: Status) []const u8 {
        return switch (@backingInt(self)) {
            100 => "Continue",
            101 => "Switching Protocols",
            102 => "Processing",
            103 => "Early Hints",
            200 => "OK",
            201 => "Created",
            202 => "Accepted",
            203 => "Non-Authoritative Information",
            204 => "No Content",
            205 => "Reset Content",
            206 => "Partial Content",
            207 => "Multi-Status",
            208 => "Already Reported",
            226 => "IM Used",
            300 => "Multiple Choices",
            301 => "Moved Permanently",
            302 => "Found",
            303 => "See Other",
            304 => "Not Modified",
            305 => "Use Proxy",
            307 => "Temporary Redirect",
            308 => "Permanent Redirect",
            400 => "Bad Request",
            401 => "Unauthorized",
            402 => "Payment Required",
            403 => "Forbidden",
            404 => "Not Found",
            405 => "Method Not Allowed",
            406 => "Not Acceptable",
            407 => "Proxy Authentication Required",
            408 => "Request Timeout",
            409 => "Conflict",
            410 => "Gone",
            411 => "Length Required",
            412 => "Precondition Failed",
            413 => "Content Too Large",
            414 => "URI Too Long",
            415 => "Unsupported Media Type",
            416 => "Range Not Satisfiable",
            417 => "Expectation Failed",
            418 => "I'm a teapot",
            421 => "Misdirected Request",
            422 => "Unprocessable Content",
            423 => "Locked",
            424 => "Failed Dependency",
            425 => "Too Early",
            426 => "Upgrade Required",
            428 => "Precondition Required",
            429 => "Too Many Requests",
            431 => "Request Header Fields Too Large",
            451 => "Unavailable For Legal Reasons",
            500 => "Internal Server Error",
            501 => "Not Implemented",
            502 => "Bad Gateway",
            503 => "Service Unavailable",
            504 => "Gateway Timeout",
            505 => "HTTP Version Not Supported",
            506 => "Variant Also Negotiates",
            507 => "Insufficient Storage",
            508 => "Loop Detected",
            510 => "Not Extended",
            511 => "Network Authentication Required",
            else => self.name(),
        };
    }

    /// Writes the reason phrase (see `phrase`).
    pub fn format(self: Status, writer: anytype) !void {
        try writer.writeAll(self.phrase());
    }
};

test "Status: reason phrases are RFC 9110's" {
    try std.testing.expectEqualStrings("OK", Status.ok.phrase());
    try std.testing.expectEqualStrings("Not Found", Status.not_found.phrase());
    try std.testing.expectEqualStrings("Content Too Large", Status.payload_too_large.phrase());
    try std.testing.expectEqualStrings("Internal Server Error", Status.internal_server_error.phrase());
}

/// An IMF-fixdate (RFC 9110 5.6.7), `Sun, 06 Nov 1994 08:49:37 GMT`, of
/// `seconds` since the epoch. A time before 1970 is given as 1970, and one
/// after the year 9999 (which four digits cannot hold) as its last second.
pub fn formatHttpDate(buf: *[29]u8, seconds: i64) []const u8 {
    // 9999-12-31T23:59:59Z.
    const last_second: i64 = 253402300799;
    const day_names = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };
    const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(std.math.clamp(seconds, 0, last_second)) };
    const day = epoch_seconds.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    return std.fmt.bufPrint(buf, "{s}, {d:0>2} {s} {d:0>4} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
        day_names[day.day % 7],
        month_day.day_index + 1,
        month_names[month_day.month.numeric() - 1],
        year_day.year,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    }) catch unreachable; // years 1970-9999 fit
}

/// Whole seconds of real time. On Linux from the coarse clock, which the
/// vDSO answers from its data page without reading the hardware counter: the
/// header is read on every response and wants only the second, and the
/// coarse clock trails by at most a tick.
fn realSeconds(io: std.Io) i64 {
    const builtin = @import("builtin");
    if (builtin.os.tag == .linux) {
        // With libc, through libc: std's own vDSO lookup reads the auxiliary
        // vector that only its own `_start` records, and would make a
        // system call of every read.
        if (builtin.link_libc) {
            var ts: std.c.timespec = undefined;
            if (std.c.clock_gettime(.REALTIME_COARSE, &ts) == 0) return @intCast(ts.sec);
        } else {
            var ts: std.os.linux.timespec = undefined;
            if (std.os.linux.clock_gettime(.REALTIME_COARSE, &ts) == 0) return @intCast(ts.sec);
        }
    }
    return std.Io.Clock.real.now(io).toSeconds();
}

threadlocal var date_cache: [29]u8 = undefined;
threadlocal var date_cache_len: usize = 0;
threadlocal var date_cache_seconds: i64 = -1;

/// The current time for a `Date` header (RFC 9110 6.6.1), formatted at most
/// once a second per thread. The slice is valid until the next call on this
/// thread; copy it to keep it.
pub fn currentHttpDate(io: std.Io) []const u8 {
    const now = realSeconds(io);
    if (now != date_cache_seconds) {
        date_cache_len = formatHttpDate(&date_cache, now).len;
        date_cache_seconds = now;
    }
    return date_cache[0..date_cache_len];
}

test "formatHttpDate: IMF-fixdate" {
    var buf: [29]u8 = undefined;
    try std.testing.expectEqualStrings("Sun, 06 Nov 1994 08:49:37 GMT", formatHttpDate(&buf, 784111777));
    try std.testing.expectEqualStrings("Thu, 01 Jan 1970 00:00:00 GMT", formatHttpDate(&buf, -5));
    // A file time past the year 9999 (a stored mtime is anything) is
    // given as the last second that fits.
    try std.testing.expectEqualStrings("Fri, 31 Dec 9999 23:59:59 GMT", formatHttpDate(&buf, 253402300799));
    try std.testing.expectEqualStrings("Fri, 31 Dec 9999 23:59:59 GMT", formatHttpDate(&buf, 253402300800));
    try std.testing.expectEqualStrings("Fri, 31 Dec 9999 23:59:59 GMT", formatHttpDate(&buf, std.math.maxInt(i64)));
}

test "Status: construct from llhttp_status_t" {
    const status: Status = @fromBackingInt(@intCast(c.HTTP_STATUS_OK));
    try std.testing.expectEqual(.ok, status);
}

test "Status.fromCode: named codes map, unassigned/0/600 are InvalidStatusCode" {
    try std.testing.expectEqual(.ok, try Status.fromCode(200));
    try std.testing.expectEqual(.not_found, try Status.fromCode(404));
    try std.testing.expectEqual(.im_a_teapot, try Status.fromCode(418));
    // Unassigned, past the end of the range, and zero are all codes the
    // enum does not name.
    try std.testing.expectError(error.InvalidStatusCode, Status.fromCode(250));
    try std.testing.expectError(error.InvalidStatusCode, Status.fromCode(600));
    try std.testing.expectError(error.InvalidStatusCode, Status.fromCode(0));
}

test "Status: fromCode round-trips every named status" {
    inline for (comptime std.meta.fieldNames(Status)) |name| {
        const status = @field(Status, name);
        try std.testing.expectEqual(status, try Status.fromCode(comptime @backingInt(status)));
    }
}

test "Status.name: the upper-snake tag (NOT_FOUND)" {
    try std.testing.expectEqualStrings("OK", Status.ok.name());
    try std.testing.expectEqualStrings("NOT_FOUND", Status.not_found.name());
    try std.testing.expectEqualStrings("INTERNAL_SERVER_ERROR", Status.internal_server_error.name());
}

test "Status: {f} prints the reason phrase" {
    var buf: [32]u8 = undefined;
    const result = try std.fmt.bufPrint(&buf, "{f}", .{Status.not_found});
    try std.testing.expectEqualStrings("Not Found", result);
}

/// Case-insensitive multi-value HTTP header map backed by parallel arrays in a
/// single pre-allocated block.  A 1-byte hash filters most mismatches before
/// the full case-insensitive string compare, keeping the linear scan cheap for
/// the small number of headers in a typical HTTP message.
pub const Headers = struct {
    keys: [][]const u8 = &.{},
    values: [][]const u8 = &.{},
    hashes: []u8 = &.{},
    len: usize = 0,

    const slice_size = @sizeOf([]const u8);
    const slice_align = @alignOf([]const u8);

    const max_count = std.math.maxInt(usize) / (slice_size * 2 + 1);

    pub fn init(allocator: std.mem.Allocator, max: usize) !Headers {
        if (max == 0) return .{};
        const capped = @min(max, max_count);
        const keys_bytes = capped * slice_size;
        const hashes_offset = keys_bytes * 2;
        const total_size = hashes_offset + capped;
        const buf = try allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(slice_align), total_size);
        const keys: [][]const u8 = @as([*][]const u8, @ptrCast(@alignCast(buf.ptr)))[0..capped];
        const values: [][]const u8 = @as([*][]const u8, @ptrCast(@alignCast(buf[keys_bytes..].ptr)))[0..capped];
        return .{ .keys = keys, .values = values, .hashes = buf[hashes_offset..] };
    }

    /// Room for more in a full table, up to `max` entries: a table twice
    /// the size from `allocator`, the entries copied over. For a table in
    /// an arena, which keeps the old one: it starts small, so an ordinary
    /// message's headers take little of the arena, and grows to its limit
    /// for one with more. False at `max`, or without the memory.
    pub fn grow(self: *Headers, allocator: std.mem.Allocator, max: usize) bool {
        if (self.keys.len >= max) return false;
        var bigger = Headers.init(allocator, @min(max, @max(8, self.keys.len * 2))) catch return false;
        @memcpy(bigger.keys[0..self.len], self.keys[0..self.len]);
        @memcpy(bigger.values[0..self.len], self.values[0..self.len]);
        @memcpy(bigger.hashes[0..self.len], self.hashes[0..self.len]);
        bigger.len = self.len;
        self.* = bigger;
        return true;
    }

    pub fn deinit(self: *Headers, allocator: std.mem.Allocator) void {
        const max = self.keys.len;
        if (max == 0) return;
        const ptr: [*]align(slice_align) u8 = @ptrCast(@alignCast(self.keys.ptr));
        allocator.free(ptr[0 .. max * slice_size * 2 + max]);
        self.* = .{};
    }

    inline fn hashFn(name: []const u8) u8 {
        if (name.len == 0) return 0;
        return @as(u8, @truncate(name.len)) | (std.ascii.toLower(name[0]) ^ std.ascii.toLower(name[name.len - 1]));
    }

    /// Replaces the value of the first entry matching name (case-insensitive),
    /// or appends a new entry. Returns error.TooManyHeaders if at capacity.
    pub fn put(self: *Headers, name: []const u8, value: []const u8) !void {
        const h = hashFn(name);
        for (self.hashes[0..self.len], 0..) |hh, i| {
            if (hh == h and std.ascii.eqlIgnoreCase(self.keys[i], name)) {
                self.values[i] = value;
                return;
            }
        }
        try self.add(name, value);
    }

    /// Always appends a new entry regardless of existing keys.
    /// Returns error.TooManyHeaders if at capacity.
    pub fn add(self: *Headers, name: []const u8, value: []const u8) !void {
        const i = self.len;
        if (i >= self.keys.len) return error.TooManyHeaders;
        self.keys[i] = name;
        self.values[i] = value;
        self.hashes[i] = hashFn(name);
        self.len = i + 1;
    }

    /// Adds one field of an HTTP/2 or HTTP/3 request, as the HTTP/1.1
    /// parser does: another entry for a repeated name, except `cookie`,
    /// whose fields are joined onto the first one with "; " (RFC 9113
    /// §8.2.3, RFC 9114 §4.2.1), in `allocator` (the request's arena).
    pub fn addRequestField(self: *Headers, allocator: std.mem.Allocator, name: []const u8, value: []const u8) error{ TooManyHeaders, OutOfMemory }!void {
        if (std.ascii.eqlIgnoreCase(name, "cookie")) {
            const h = hashFn(name);
            for (self.hashes[0..self.len], 0..) |hh, i| {
                if (hh == h and std.ascii.eqlIgnoreCase(self.keys[i], name)) {
                    self.values[i] = try std.mem.concat(allocator, u8, &.{ self.values[i], "; ", value });
                    return;
                }
            }
        }
        try self.add(name, value);
    }

    /// Returns the value of the first matching entry (case-insensitive), or null.
    pub fn get(self: *const Headers, name: []const u8) ?[]const u8 {
        const h = hashFn(name);
        for (self.hashes[0..self.len], 0..) |hh, i| {
            if (hh == h and std.ascii.eqlIgnoreCase(self.keys[i], name)) {
                return self.values[i];
            }
        }
        return null;
    }

    /// Drops every entry matching name (case-insensitive), keeping the
    /// order of the rest. Returns how many went.
    pub fn remove(self: *Headers, name: []const u8) usize {
        const h = hashFn(name);
        var kept: usize = 0;
        for (0..self.len) |i| {
            if (self.hashes[i] == h and std.ascii.eqlIgnoreCase(self.keys[i], name)) continue;
            if (kept != i) {
                self.keys[kept] = self.keys[i];
                self.values[kept] = self.values[i];
                self.hashes[kept] = self.hashes[i];
            }
            kept += 1;
        }
        defer self.len = kept;
        return self.len - kept;
    }

    /// How many entries there are, repeated names counted each time.
    pub fn count(self: *const Headers) usize {
        return self.len;
    }

    /// The next entry matching `name` at or after `from`, or null.
    fn find(self: *const Headers, name: []const u8, h: u8, from: usize) ?usize {
        for (self.hashes[from..self.len], from..) |hh, i| {
            if (hh == h and std.ascii.eqlIgnoreCase(self.keys[i], name)) return i;
        }
        return null;
    }

    /// Serializes as a JSON object. HTTP lets a name appear more than
    /// once and a JSON object cannot hold the same key twice, so those
    /// become an array rather than a repeated key that a parser would
    /// silently reduce to whichever copy it saw last.
    pub fn jsonStringify(self: Headers, jw: anytype) !void {
        try jw.beginObject();
        for (self.keys[0..self.len], self.hashes[0..self.len], 0..) |name, h, i| {
            // Later copies are written with the first, so skip them here.
            if (self.find(name, h, 0).? != i) continue;

            try jw.objectField(name);
            const second = self.find(name, h, i + 1) orelse {
                try jw.write(self.values[i]);
                continue;
            };
            try jw.beginArray();
            try jw.write(self.values[i]);
            var next: ?usize = second;
            while (next) |j| : (next = self.find(name, h, j + 1)) {
                try jw.write(self.values[j]);
            }
            try jw.endArray();
        }
        try jw.endObject();
    }

    /// Every entry in order, repeated names included.
    pub fn iterator(self: *const Headers) Iterator {
        return .{ .keys = self.keys[0..self.len], .values = self.values[0..self.len], .pos = 0 };
    }

    pub const Iterator = struct {
        keys: [][]const u8,
        values: [][]const u8,
        pos: usize,

        pub const Entry = struct {
            key: []const u8,
            value: []const u8,
        };

        pub fn next(self: *Iterator) ?Entry {
            if (self.pos >= self.keys.len) return null;
            const i = self.pos;
            self.pos += 1;
            return .{ .key = self.keys[i], .value = self.values[i] };
        }
    };
};

/// Path parameters and query string values. A string map, with typed
/// lookups for the values that are meant to be numbers.
pub const Params = struct {
    map: std.StringHashMapUnmanaged([]const u8) = .{},

    /// The value of `name`, or null. Query values are already
    /// percent-decoded.
    pub fn get(self: Params, name: []const u8) ?[]const u8 {
        return self.map.get(name);
    }

    /// How many names there are.
    pub fn count(self: Params) usize {
        return self.map.count();
    }

    /// Null when the value is missing, or is not a `T`.
    pub fn getInt(self: Params, comptime T: type, name: []const u8) ?T {
        const raw = self.get(name) orelse return null;
        return std.fmt.parseInt(T, raw, 10) catch null;
    }

    /// Null when the value is missing, is not a `T`, or is not finite:
    /// `parseFloat` reads "nan" and "inf", which are not quantities.
    pub fn getFloat(self: Params, comptime T: type, name: []const u8) ?T {
        const raw = self.get(name) orelse return null;
        const value = std.fmt.parseFloat(T, raw) catch return null;
        return if (std.math.isFinite(value)) value else null;
    }

    /// Every name and value, in no particular order.
    pub fn iterator(self: *const Params) Iterator {
        return .{ .inner = self.map.iterator() };
    }

    /// Serializes as a JSON object. Keys are unique here, so unlike
    /// `Headers` every value is a plain string.
    pub fn jsonStringify(self: Params, jw: anytype) !void {
        try jw.beginObject();
        var it = self.map.iterator();
        while (it.next()) |entry| {
            try jw.objectField(entry.key_ptr.*);
            try jw.write(entry.value_ptr.*);
        }
        try jw.endObject();
    }

    /// Yields the same `Entry` shape as `Headers.Iterator`, so a loop over
    /// either reads the same.
    pub const Iterator = struct {
        inner: std.StringHashMapUnmanaged([]const u8).Iterator,

        pub const Entry = struct {
            key: []const u8,
            value: []const u8,
        };

        pub fn next(self: *Iterator) ?Entry {
            const entry = self.inner.next() orelse return null;
            return .{ .key = entry.key_ptr.*, .value = entry.value_ptr.* };
        }
    };
};

test "Params.getInt: null for missing, junk, negative-into-unsigned and too-wide values" {
    var params: Params = .{};
    defer params.map.deinit(std.testing.allocator);
    try params.map.put(std.testing.allocator, "n", "42");
    try params.map.put(std.testing.allocator, "neg", "-1");
    try params.map.put(std.testing.allocator, "big", "300");
    try params.map.put(std.testing.allocator, "junk", "12abc");
    try params.map.put(std.testing.allocator, "empty", "");

    try std.testing.expectEqual(@as(?u16, 42), params.getInt(u16, "n"));
    try std.testing.expectEqual(@as(?i32, -1), params.getInt(i32, "neg"));
    // Negative into an unsigned, and a value too wide for the type, are
    // both "not a T" rather than a wrapped number.
    try std.testing.expectEqual(@as(?u16, null), params.getInt(u16, "neg"));
    try std.testing.expectEqual(@as(?u8, null), params.getInt(u8, "big"));
    try std.testing.expectEqual(@as(?u16, null), params.getInt(u16, "junk"));
    try std.testing.expectEqual(@as(?u16, null), params.getInt(u16, "empty"));
    try std.testing.expectEqual(@as(?u16, null), params.getInt(u16, "absent"));
}

test "Params.getFloat: null for missing, junk, nan and inf" {
    var params: Params = .{};
    defer params.map.deinit(std.testing.allocator);
    try params.map.put(std.testing.allocator, "half", "0.5");
    try params.map.put(std.testing.allocator, "nan", "nan");
    try params.map.put(std.testing.allocator, "inf", "inf");
    try params.map.put(std.testing.allocator, "junk", "abc");

    try std.testing.expectEqual(@as(?f64, 0.5), params.getFloat(f64, "half"));
    try std.testing.expectEqual(@as(?f64, null), params.getFloat(f64, "nan"));
    try std.testing.expectEqual(@as(?f64, null), params.getFloat(f64, "inf"));
    try std.testing.expectEqual(@as(?f64, null), params.getFloat(f64, "junk"));
    try std.testing.expectEqual(@as(?f64, null), params.getFloat(f64, "absent"));
}

test "Params: iterator yields the same shape as Headers" {
    var params: Params = .{};
    defer params.map.deinit(std.testing.allocator);
    try params.map.put(std.testing.allocator, "a", "1");

    var it = params.iterator();
    const entry = it.next().?;
    try std.testing.expectEqualStrings("a", entry.key);
    try std.testing.expectEqualStrings("1", entry.value);
    try std.testing.expectEqual(@as(?Params.Iterator.Entry, null), it.next());
}

test "Headers: put/get case insensitive" {
    var headers = try Headers.init(std.testing.allocator, 8);
    defer headers.deinit(std.testing.allocator);

    try headers.put("FOO", "bar");

    try std.testing.expectEqualStrings("bar", headers.get("foo").?);
    try std.testing.expectEqualStrings("bar", headers.get("FOO").?);
}

test "Headers: put replaces, add appends" {
    var headers = try Headers.init(std.testing.allocator, 4);
    defer headers.deinit(std.testing.allocator);

    try headers.put("Set-Cookie", "a=1");
    try headers.add("Set-Cookie", "b=2");
    try headers.put("Set-Cookie", "c=3"); // replaces first

    try std.testing.expectEqualStrings("c=3", headers.get("set-cookie").?);
    try std.testing.expectEqual(2, headers.count());

    var it = headers.iterator();
    try std.testing.expectEqualStrings("c=3", it.next().?.value);
    try std.testing.expectEqualStrings("b=2", it.next().?.value);
    try std.testing.expectEqual(null, it.next());
}

test "Headers: addRequestField joins cookie crumbs and adds other repeats" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var headers = try Headers.init(a, 4);
    try headers.addRequestField(a, "cookie", "a=1");
    try headers.addRequestField(a, "accept", "text/html");
    try headers.addRequestField(a, "Cookie", "b=2");
    try headers.addRequestField(a, "accept", "application/json");
    try headers.addRequestField(a, "cookie", "c=3");
    try std.testing.expectEqualStrings("a=1; b=2; c=3", headers.get("cookie").?);
    try std.testing.expectEqual(3, headers.count());
    var it = headers.iterator();
    _ = it.next();
    try std.testing.expectEqualStrings("text/html", it.next().?.value);
    try std.testing.expectEqualStrings("application/json", it.next().?.value);
    try headers.addRequestField(a, "x", "y");
    try std.testing.expectError(error.TooManyHeaders, headers.addRequestField(a, "z", "y"));
    // A crumb joins even at capacity: it takes no entry.
    try headers.addRequestField(a, "cookie", "d=4");
    try std.testing.expectEqualStrings("a=1; b=2; c=3; d=4", headers.get("cookie").?);
}

test "Headers: error on overflow" {
    var headers = try Headers.init(std.testing.allocator, 1);
    defer headers.deinit(std.testing.allocator);

    try headers.add("A", "1");
    try std.testing.expectError(error.TooManyHeaders, headers.add("B", "2"));
}

// Bytes that would break "Name: Value\r\n" framing on the wire.
const invalid_header_value_bytes = "\r\n\x00";

// RFC 7230 token chars (tchar): the only bytes allowed in a header field-name.
const allowed_header_name_bytes = "!#$%&'*+-.^_`|~" ++
    "0123456789" ++
    "abcdefghijklmnopqrstuvwxyz" ++
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ";

const tchar_table: [256]bool = blk: {
    var table: [256]bool = @splat(false);
    for (allowed_header_name_bytes) |byte| table[byte] = true;
    break :blk table;
};

pub fn validateHeaderName(name: []const u8) error{InvalidHeaderName}!void {
    if (name.len == 0) return error.InvalidHeaderName;
    for (name) |byte| {
        if (!tchar_table[byte]) return error.InvalidHeaderName;
    }
}

pub fn validateHeaderValue(value: []const u8) error{InvalidHeaderValue}!void {
    if (std.mem.indexOfAny(u8, value, invalid_header_value_bytes) != null) return error.InvalidHeaderValue;
}

test "validateHeaderValue: rejects CR/LF/NUL" {
    try std.testing.expectError(error.InvalidHeaderValue, validateHeaderValue("a\rb"));
    try std.testing.expectError(error.InvalidHeaderValue, validateHeaderValue("a\nb"));
    try std.testing.expectError(error.InvalidHeaderValue, validateHeaderValue("a\x00b"));
    try validateHeaderValue("safe value with spaces and !@#$%");
    try validateHeaderValue("");
}

test "validateHeaderName: rejects empty, whitespace, colon, control" {
    try std.testing.expectError(error.InvalidHeaderName, validateHeaderName(""));
    try std.testing.expectError(error.InvalidHeaderName, validateHeaderName("X-Foo:"));
    try std.testing.expectError(error.InvalidHeaderName, validateHeaderName("X Foo"));
    try std.testing.expectError(error.InvalidHeaderName, validateHeaderName("X-Foo\r"));
    try std.testing.expectError(error.InvalidHeaderName, validateHeaderName("X(Foo)"));
    try std.testing.expectError(error.InvalidHeaderName, validateHeaderName("X,Foo"));
    try validateHeaderName("X-Custom-Header");
}

/// Percent-decodes `text` (%XX to a byte; with `plus_is_space`, '+' to a
/// space, as in a query string or a form). Returns `text` itself when there
/// is nothing to decode, else a copy in `arena`. `error.BadRequest` for a
/// '%' not followed by two hex digits.
pub fn percentDecode(arena: std.mem.Allocator, text: []const u8, plus_is_space: bool) error{ BadRequest, OutOfMemory }![]const u8 {
    var decoded_len = text.len;
    var changed = false;
    var i: usize = 0;
    while (i < text.len) {
        const b = text[i];
        if (b == '%') {
            if (i + 2 >= text.len or !std.ascii.isHex(text[i + 1]) or !std.ascii.isHex(text[i + 2])) return error.BadRequest;
            i += 3;
            decoded_len -= 2;
            changed = true;
        } else {
            if (b == '+' and plus_is_space) changed = true;
            i += 1;
        }
    }
    if (!changed) return text;
    const out = try arena.alloc(u8, decoded_len);
    i = 0;
    for (out) |*o| {
        const b = text[i];
        if (b == '%') {
            o.* = (hexValue(text[i + 1]) << 4) | hexValue(text[i + 2]);
            i += 3;
        } else {
            o.* = if (b == '+' and plus_is_space) ' ' else b;
            i += 1;
        }
    }
    return out;
}

fn hexValue(digit: u8) u8 {
    return switch (digit) {
        '0'...'9' => digit - '0',
        'A'...'F' => digit - 'A' + 10,
        else => digit - 'a' + 10,
    };
}

/// The media types the server knows by name, for `res.content_type` and
/// `req.content_type`; `.unknown` for anything else (set the
/// `Content-Type` header yourself for those).
/// Using a request or response out of order: a second `req.reader()`,
/// `res.stream` after `res.body` was set, writing after the head went out.
/// Answered 500.
pub const MisuseError = error{ BodyReaderTaken, BodyAlreadySet, BodyWriterOpen, HeadersAlreadySent };

/// One problem found in a request: a body, query or header field that does
/// not fit or breaks a rule. `req.bind`, `req.bindQuery` and `req.invalid`
/// record them; the 422 answer lists them.
pub const Violation = struct {
    pub const Source = enum { body, query, header };
    in: Source = .body,
    /// Dotted path by outside names (`items[2].name`); the canonical name
    /// for headers; null for the root value.
    field: ?[]const u8 = null,
    code: []const u8,
    message: []const u8,
};

/// The violations of one request (at most 100 are kept).
pub const Violations = struct { items: []const Violation = &.{}, truncated: bool = false };

/// An RFC 9457 problem document (`res.problem`).
pub const Problem = struct {
    status: Status = .unprocessable_entity,
    type: []const u8 = "about:blank",
    /// Null: the status's reason phrase.
    title: ?[]const u8 = null,
    /// Null: a count of `errors` when there are any ("2 fields are invalid."), else left out.
    detail: ?[]const u8 = null,
    instance: ?[]const u8 = null,
    errors: []const Violation = &.{},
    /// More violations existed than `errors` holds (changes the default detail).
    truncated: bool = false,
};

pub const ContentType = enum(u32) {
    text,
    html,
    css,
    js,
    xml,
    json,
    msgpack,
    yaml,
    png,
    jpeg,
    webp,
    gif,
    svg,
    ico,
    mp4,
    webm,
    mp3,
    wav,
    ogg,
    woff,
    woff2,
    ttf,
    wasm,
    pdf,
    avif,
    bmp,
    otf,
    csv,
    markdown,
    manifest,
    calendar,
    rss,
    atom,
    zip,
    mov,
    m4a,
    aac,
    flac,
    event_stream,
    form,
    multipart_form,
    /// `application/problem+json` (RFC 9457), `res.problem`.
    problem_json,
    unknown,

    /// The type a `Content-Type` value names, parameters ignored.
    pub fn fromContentType(value: []const u8) ContentType {
        if (value.len == 0) {
            return .unknown;
        }

        var main_buffer: [33]u8 = undefined;
        var main_length: usize = 0;

        while (main_length < value.len) {
            if (value[main_length] == ';') {
                break;
            }

            if (main_length >= main_buffer.len) {
                return .unknown;
            }

            main_buffer[main_length] = std.ascii.toLower(value[main_length]);
            main_length += 1;
        }

        if (main_length < 8) {
            return .unknown;
        }

        const main = main_buffer[0..main_length];
        const hash = std.hash.Fnv1a_32.hash(main);

        if ((hash == comptime std.hash.Fnv1a_32.hash("text/plain")) and std.mem.eql(u8, main, "text/plain")) return .text;
        if ((hash == comptime std.hash.Fnv1a_32.hash("text/html")) and std.mem.eql(u8, main, "text/html")) return .html;
        if ((hash == comptime std.hash.Fnv1a_32.hash("text/css")) and std.mem.eql(u8, main, "text/css")) return .css;
        if ((hash == comptime std.hash.Fnv1a_32.hash("application/javascript")) and std.mem.eql(u8, main, "application/javascript")) return .js;
        if ((hash == comptime std.hash.Fnv1a_32.hash("application/xml")) and std.mem.eql(u8, main, "application/xml")) return .xml;
        if ((hash == comptime std.hash.Fnv1a_32.hash("application/json")) and std.mem.eql(u8, main, "application/json")) return .json;
        if ((hash == comptime std.hash.Fnv1a_32.hash("application/problem+json")) and std.mem.eql(u8, main, "application/problem+json")) return .problem_json;
        if ((hash == comptime std.hash.Fnv1a_32.hash("application/vnd.msgpack")) and std.mem.eql(u8, main, "application/vnd.msgpack")) return .msgpack;
        if ((hash == comptime std.hash.Fnv1a_32.hash("application/yaml")) and std.mem.eql(u8, main, "application/yaml")) return .yaml;
        if ((hash == comptime std.hash.Fnv1a_32.hash("image/png")) and std.mem.eql(u8, main, "image/png")) return .png;
        if ((hash == comptime std.hash.Fnv1a_32.hash("image/jpeg")) and std.mem.eql(u8, main, "image/jpeg")) return .jpeg;
        if ((hash == comptime std.hash.Fnv1a_32.hash("image/webp")) and std.mem.eql(u8, main, "image/webp")) return .webp;
        if ((hash == comptime std.hash.Fnv1a_32.hash("image/gif")) and std.mem.eql(u8, main, "image/gif")) return .gif;
        if ((hash == comptime std.hash.Fnv1a_32.hash("image/svg+xml")) and std.mem.eql(u8, main, "image/svg+xml")) return .svg;
        if ((hash == comptime std.hash.Fnv1a_32.hash("image/x-icon")) and std.mem.eql(u8, main, "image/x-icon")) return .ico;
        if ((hash == comptime std.hash.Fnv1a_32.hash("video/mp4")) and std.mem.eql(u8, main, "video/mp4")) return .mp4;
        if ((hash == comptime std.hash.Fnv1a_32.hash("video/webm")) and std.mem.eql(u8, main, "video/webm")) return .webm;
        if ((hash == comptime std.hash.Fnv1a_32.hash("audio/mpeg")) and std.mem.eql(u8, main, "audio/mpeg")) return .mp3;
        if ((hash == comptime std.hash.Fnv1a_32.hash("audio/wav")) and std.mem.eql(u8, main, "audio/wav")) return .wav;
        if ((hash == comptime std.hash.Fnv1a_32.hash("audio/ogg")) and std.mem.eql(u8, main, "audio/ogg")) return .ogg;
        if ((hash == comptime std.hash.Fnv1a_32.hash("font/woff")) and std.mem.eql(u8, main, "font/woff")) return .woff;
        if ((hash == comptime std.hash.Fnv1a_32.hash("font/woff2")) and std.mem.eql(u8, main, "font/woff2")) return .woff2;
        if ((hash == comptime std.hash.Fnv1a_32.hash("text/event-stream")) and std.mem.eql(u8, main, "text/event-stream")) return .event_stream;
        if ((hash == comptime std.hash.Fnv1a_32.hash("application/x-www-form-urlencoded")) and std.mem.eql(u8, main, "application/x-www-form-urlencoded")) return .form;
        if ((hash == comptime std.hash.Fnv1a_32.hash("multipart/form-data")) and std.mem.eql(u8, main, "multipart/form-data")) return .multipart_form;
        if ((hash == comptime std.hash.Fnv1a_32.hash("font/ttf")) and std.mem.eql(u8, main, "font/ttf")) return .ttf;
        if ((hash == comptime std.hash.Fnv1a_32.hash("application/wasm")) and std.mem.eql(u8, main, "application/wasm")) return .wasm;
        if ((hash == comptime std.hash.Fnv1a_32.hash("application/pdf")) and std.mem.eql(u8, main, "application/pdf")) return .pdf;

        return .unknown;
    }

    /// The type a file extension stands for (".css" or "css").
    pub fn fromExtension(value: []const u8) ContentType {
        if (value.len == 0) {
            return .unknown;
        }

        const name = if (value[0] == '.') value[1..] else value;
        const hash = std.hash.Fnv1a_32.hash(name);

        if (name.len < 2) {
            return .unknown;
        }

        if ((hash == comptime std.hash.Fnv1a_32.hash("txt")) and std.mem.eql(u8, name, "txt")) return .text;
        if ((hash == comptime std.hash.Fnv1a_32.hash("html")) and std.mem.eql(u8, name, "html")) return .html;
        if ((hash == comptime std.hash.Fnv1a_32.hash("htm")) and std.mem.eql(u8, name, "htm")) return .html;
        if ((hash == comptime std.hash.Fnv1a_32.hash("css")) and std.mem.eql(u8, name, "css")) return .css;
        if ((hash == comptime std.hash.Fnv1a_32.hash("js")) and std.mem.eql(u8, name, "js")) return .js;
        if ((hash == comptime std.hash.Fnv1a_32.hash("mjs")) and std.mem.eql(u8, name, "mjs")) return .js;
        if ((hash == comptime std.hash.Fnv1a_32.hash("xml")) and std.mem.eql(u8, name, "xml")) return .xml;
        if ((hash == comptime std.hash.Fnv1a_32.hash("json")) and std.mem.eql(u8, name, "json")) return .json;
        if ((hash == comptime std.hash.Fnv1a_32.hash("yaml")) and std.mem.eql(u8, name, "yaml")) return .yaml;
        if ((hash == comptime std.hash.Fnv1a_32.hash("png")) and std.mem.eql(u8, name, "png")) return .png;
        if ((hash == comptime std.hash.Fnv1a_32.hash("jpg")) and std.mem.eql(u8, name, "jpg")) return .jpeg;
        if ((hash == comptime std.hash.Fnv1a_32.hash("jpeg")) and std.mem.eql(u8, name, "jpeg")) return .jpeg;
        if ((hash == comptime std.hash.Fnv1a_32.hash("webp")) and std.mem.eql(u8, name, "webp")) return .webp;
        if ((hash == comptime std.hash.Fnv1a_32.hash("gif")) and std.mem.eql(u8, name, "gif")) return .gif;
        if ((hash == comptime std.hash.Fnv1a_32.hash("svg")) and std.mem.eql(u8, name, "svg")) return .svg;
        if ((hash == comptime std.hash.Fnv1a_32.hash("ico")) and std.mem.eql(u8, name, "ico")) return .ico;
        if ((hash == comptime std.hash.Fnv1a_32.hash("mp4")) and std.mem.eql(u8, name, "mp4")) return .mp4;
        if ((hash == comptime std.hash.Fnv1a_32.hash("webm")) and std.mem.eql(u8, name, "webm")) return .webm;
        if ((hash == comptime std.hash.Fnv1a_32.hash("mp3")) and std.mem.eql(u8, name, "mp3")) return .mp3;
        if ((hash == comptime std.hash.Fnv1a_32.hash("wav")) and std.mem.eql(u8, name, "wav")) return .wav;
        if ((hash == comptime std.hash.Fnv1a_32.hash("ogg")) and std.mem.eql(u8, name, "ogg")) return .ogg;
        if ((hash == comptime std.hash.Fnv1a_32.hash("woff")) and std.mem.eql(u8, name, "woff")) return .woff;
        if ((hash == comptime std.hash.Fnv1a_32.hash("woff2")) and std.mem.eql(u8, name, "woff2")) return .woff2;
        if ((hash == comptime std.hash.Fnv1a_32.hash("ttf")) and std.mem.eql(u8, name, "ttf")) return .ttf;
        if ((hash == comptime std.hash.Fnv1a_32.hash("wasm")) and std.mem.eql(u8, name, "wasm")) return .wasm;
        if ((hash == comptime std.hash.Fnv1a_32.hash("pdf")) and std.mem.eql(u8, name, "pdf")) return .pdf;
        if ((hash == comptime std.hash.Fnv1a_32.hash("cjs")) and std.mem.eql(u8, name, "cjs")) return .js;
        if ((hash == comptime std.hash.Fnv1a_32.hash("map")) and std.mem.eql(u8, name, "map")) return .json;
        if ((hash == comptime std.hash.Fnv1a_32.hash("yml")) and std.mem.eql(u8, name, "yml")) return .yaml;
        if ((hash == comptime std.hash.Fnv1a_32.hash("avif")) and std.mem.eql(u8, name, "avif")) return .avif;
        if ((hash == comptime std.hash.Fnv1a_32.hash("bmp")) and std.mem.eql(u8, name, "bmp")) return .bmp;
        if ((hash == comptime std.hash.Fnv1a_32.hash("otf")) and std.mem.eql(u8, name, "otf")) return .otf;
        if ((hash == comptime std.hash.Fnv1a_32.hash("csv")) and std.mem.eql(u8, name, "csv")) return .csv;
        if ((hash == comptime std.hash.Fnv1a_32.hash("md")) and std.mem.eql(u8, name, "md")) return .markdown;
        if ((hash == comptime std.hash.Fnv1a_32.hash("webmanifest")) and std.mem.eql(u8, name, "webmanifest")) return .manifest;
        if ((hash == comptime std.hash.Fnv1a_32.hash("ics")) and std.mem.eql(u8, name, "ics")) return .calendar;
        if ((hash == comptime std.hash.Fnv1a_32.hash("rss")) and std.mem.eql(u8, name, "rss")) return .rss;
        if ((hash == comptime std.hash.Fnv1a_32.hash("atom")) and std.mem.eql(u8, name, "atom")) return .atom;
        if ((hash == comptime std.hash.Fnv1a_32.hash("zip")) and std.mem.eql(u8, name, "zip")) return .zip;
        if ((hash == comptime std.hash.Fnv1a_32.hash("mov")) and std.mem.eql(u8, name, "mov")) return .mov;
        if ((hash == comptime std.hash.Fnv1a_32.hash("m4a")) and std.mem.eql(u8, name, "m4a")) return .m4a;
        if ((hash == comptime std.hash.Fnv1a_32.hash("aac")) and std.mem.eql(u8, name, "aac")) return .aac;
        if ((hash == comptime std.hash.Fnv1a_32.hash("flac")) and std.mem.eql(u8, name, "flac")) return .flac;

        return .unknown;
    }

    /// The `Content-Type` value it is sent as ("text/plain; charset=UTF-8").
    pub fn toContentType(self: ContentType) []const u8 {
        return switch (self) {
            .text => "text/plain; charset=UTF-8",
            .html => "text/html; charset=UTF-8",
            .css => "text/css; charset=UTF-8",
            .js => "application/javascript; charset=UTF-8",
            .xml => "application/xml; charset=UTF-8",
            .json => "application/json; charset=UTF-8",
            .msgpack => "application/vnd.msgpack",
            .yaml => "application/yaml; charset=UTF-8",
            .png => "image/png",
            .jpeg => "image/jpeg",
            .webp => "image/webp",
            .gif => "image/gif",
            .svg => "image/svg+xml",
            .ico => "image/x-icon",
            .mp4 => "video/mp4",
            .webm => "video/webm",
            .mp3 => "audio/mpeg",
            .wav => "audio/wav",
            .ogg => "audio/ogg",
            .woff => "font/woff",
            .woff2 => "font/woff2",
            .ttf => "font/ttf",
            .wasm => "application/wasm",
            .pdf => "application/pdf",
            .avif => "image/avif",
            .bmp => "image/bmp",
            .otf => "font/otf",
            .csv => "text/csv; charset=UTF-8",
            .markdown => "text/markdown; charset=UTF-8",
            .manifest => "application/manifest+json",
            .calendar => "text/calendar; charset=UTF-8",
            .rss => "application/rss+xml",
            .atom => "application/atom+xml",
            .zip => "application/zip",
            .mov => "video/quicktime",
            .m4a => "audio/mp4",
            .aac => "audio/aac",
            .flac => "audio/flac",
            .event_stream => "text/event-stream",
            .form => "application/x-www-form-urlencoded",
            .multipart_form => "multipart/form-data",
            .problem_json => "application/problem+json",
            .unknown => "application/octet-stream",
        };
    }
};

test "ContentType: parse from Content-Type" {
    try std.testing.expectEqual(ContentType.text, ContentType.fromContentType("text/plain"));
    try std.testing.expectEqual(ContentType.text, ContentType.fromContentType("TEXT/PLAIN"));
    try std.testing.expectEqual(ContentType.jpeg, ContentType.fromContentType("image/jpeg"));
    try std.testing.expectEqual(ContentType.json, ContentType.fromContentType("application/json; charset=UTF-8"));
    try std.testing.expectEqual(ContentType.form, ContentType.fromContentType("application/x-www-form-urlencoded; charset=UTF-8"));
    try std.testing.expectEqual(ContentType.unknown, ContentType.fromContentType(""));
}

test "ContentType: parse from file extension" {
    try std.testing.expectEqual(ContentType.text, ContentType.fromExtension("txt"));
    try std.testing.expectEqual(ContentType.text, ContentType.fromExtension(".txt"));
    try std.testing.expectEqual(ContentType.jpeg, ContentType.fromExtension(".jpg"));
    try std.testing.expectEqual(ContentType.jpeg, ContentType.fromExtension(".jpeg"));
    try std.testing.expectEqual(ContentType.unknown, ContentType.fromExtension(""));
}

/// A body's `Content-Encoding`, as the server reads it on a request.
pub const ContentEncoding = enum {
    identity,
    gzip,
    deflate,
    zstd,
    unknown,

    pub fn fromString(value: []const u8) ContentEncoding {
        if (std.ascii.eqlIgnoreCase(value, "gzip")) return .gzip;
        if (std.ascii.eqlIgnoreCase(value, "x-gzip")) return .gzip;
        if (std.ascii.eqlIgnoreCase(value, "deflate")) return .deflate;
        if (std.ascii.eqlIgnoreCase(value, "zstd")) return .zstd;
        if (std.ascii.eqlIgnoreCase(value, "identity")) return .identity;
        return .unknown;
    }
};

/// Whether a body of this media type (a Content-Type value, parameters
/// allowed) is worth compressing: text, and the structured and script
/// formats that are text underneath. Images other than SVG, audio, video,
/// fonts other than TTF/OTF, and archives are already compressed. No type at
/// all counts as compressible (it goes out as text/plain by default).
pub fn isCompressible(content_type: ?[]const u8) bool {
    const full = content_type orelse return true;
    const essence = std.mem.trim(u8, full[0 .. std.mem.indexOfScalar(u8, full, ';') orelse full.len], " \t");
    const slash = std.mem.indexOfScalar(u8, essence, '/') orelse return false;
    const top = essence[0..slash];
    const sub = essence[slash + 1 ..];
    if (std.ascii.eqlIgnoreCase(top, "text")) return true;
    // Structured syntax suffixes (RFC 6839): +json, +xml, +yaml.
    inline for (.{ "+json", "+xml", "+yaml" }) |suffix| {
        if (std.ascii.endsWithIgnoreCase(sub, suffix)) return true;
    }
    if (std.ascii.eqlIgnoreCase(top, "application")) {
        inline for (.{ "json", "javascript", "ecmascript", "xml", "wasm", "yaml", "x-yaml", "x-ndjson", "x-www-form-urlencoded", "graphql", "x-javascript", "x-sh", "toml", "sql", "csv", "rtf" }) |name| {
            if (std.ascii.eqlIgnoreCase(sub, name)) return true;
        }
        return false;
    }
    if (std.ascii.eqlIgnoreCase(top, "image")) return std.ascii.eqlIgnoreCase(sub, "svg+xml") or std.ascii.eqlIgnoreCase(sub, "x-icon") or std.ascii.eqlIgnoreCase(sub, "bmp");
    if (std.ascii.eqlIgnoreCase(top, "font")) return std.ascii.eqlIgnoreCase(sub, "ttf") or std.ascii.eqlIgnoreCase(sub, "otf");
    return false;
}

test "isCompressible: text and structured types yes, compressed media no" {
    try std.testing.expect(isCompressible("text/html; charset=utf-8"));
    try std.testing.expect(isCompressible("application/json"));
    try std.testing.expect(isCompressible("application/vnd.api+json"));
    try std.testing.expect(isCompressible("application/problem+json"));
    try std.testing.expect(isCompressible("image/svg+xml"));
    try std.testing.expect(isCompressible(null));
    try std.testing.expect(!isCompressible("image/png"));
    try std.testing.expect(!isCompressible("video/mp4"));
    try std.testing.expect(!isCompressible("application/zip"));
    try std.testing.expect(!isCompressible("application/octet-stream"));
    try std.testing.expect(!isCompressible("font/woff2"));
}

/// Whether the request's `Accept-Encoding` (RFC 9110 §12.5.3) lets a
/// response be sent gzipped: gzip, or failing that `*`, listed without
/// `q=0`. A field sent on several lines is one list.
pub fn acceptsGzip(headers: *const Headers) bool {
    return acceptsEncoding(headers, "gzip");
}

/// `acceptsGzip` for any content coding, by its registered name. `x-gzip`
/// counts as gzip.
pub fn acceptsEncoding(headers: *const Headers, name: []const u8) bool {
    return encodingQuality(headers, name) > 0;
}

/// The quality `Accept-Encoding` gives a content coding, in thousandths
/// (RFC 9110 §12.4.2): 1000 when listed without `q`, 0 when refused or not
/// listed. `*` stands in for a coding not named; `x-gzip` for gzip. A
/// malformed `q` counts as 1, as most servers read it.
pub fn encodingQuality(headers: *const Headers, name: []const u8) u16 {
    var wildcard: u16 = 0;
    var fields = headers.iterator();
    while (fields.next()) |field| {
        if (!std.ascii.eqlIgnoreCase(field.key, "Accept-Encoding")) continue;
        var it = std.mem.splitScalar(u8, field.value, ',');
        while (it.next()) |item| {
            var parts = std.mem.splitScalar(u8, item, ';');
            const coding = std.mem.trim(u8, parts.first(), " \t");
            var quality: u16 = 1000;
            while (parts.next()) |part| {
                const param = std.mem.trim(u8, part, " \t");
                if (param.len >= 2 and (param[0] == 'q' or param[0] == 'Q') and param[1] == '=') {
                    quality = parseQuality(std.mem.trim(u8, param[2..], " \t"));
                }
            }
            if (std.ascii.eqlIgnoreCase(coding, name)) return quality;
            if (std.ascii.eqlIgnoreCase(name, "gzip") and std.ascii.eqlIgnoreCase(coding, "x-gzip")) return quality;
            if (std.mem.eql(u8, coding, "*")) wildcard = quality;
        }
    }
    return wildcard;
}

/// A `qvalue` ("0", "0.5", "1.000") in thousandths.
fn parseQuality(value: []const u8) u16 {
    if (value.len == 0 or value.len > 5 or value[0] != '0') return 1000;
    if (value.len == 1) return 0;
    if (value[1] != '.') return 1000;
    var q: u16 = 0;
    var scale: u16 = 100;
    for (value[2..]) |ch| {
        if (!std.ascii.isDigit(ch)) return 1000;
        q += (ch - '0') * scale;
        scale /= 10;
    }
    return q;
}

test "encodingQuality: q-values, wildcard and refusal" {
    var headers = try Headers.init(std.testing.allocator, 4);
    defer headers.deinit(std.testing.allocator);
    try headers.add("Accept-Encoding", "gzip;q=1.0, zstd;q=0.25, br;q=0, *;q=0.1");
    try std.testing.expectEqual(@as(u16, 1000), encodingQuality(&headers, "gzip"));
    try std.testing.expectEqual(@as(u16, 250), encodingQuality(&headers, "zstd"));
    try std.testing.expectEqual(@as(u16, 0), encodingQuality(&headers, "br"));
    try std.testing.expectEqual(@as(u16, 100), encodingQuality(&headers, "deflate"));
    try std.testing.expect(!acceptsEncoding(&headers, "br"));
}

fn testAcceptsGzip(values: []const []const u8) !bool {
    var headers = try Headers.init(std.testing.allocator, 4);
    defer headers.deinit(std.testing.allocator);
    try headers.add("Host", "example.com");
    for (values) |value| try headers.add("Accept-Encoding", value);
    return acceptsGzip(&headers);
}

test "acceptsGzip: gzip, x-gzip or * without q=0, across repeated fields" {
    try std.testing.expect(try testAcceptsGzip(&.{"gzip"}));
    try std.testing.expect(try testAcceptsGzip(&.{"deflate, gzip;q=0.5, br"}));
    try std.testing.expect(try testAcceptsGzip(&.{"x-gzip"}));
    try std.testing.expect(try testAcceptsGzip(&.{"GZIP ; Q=1"}));
    try std.testing.expect(try testAcceptsGzip(&.{"*"}));
    try std.testing.expect(try testAcceptsGzip(&.{"br, *;q=0.1"}));
    try std.testing.expect(!try testAcceptsGzip(&.{""}));
    try std.testing.expect(!try testAcceptsGzip(&.{"identity"}));
    try std.testing.expect(!try testAcceptsGzip(&.{"deflate, br"}));
    try std.testing.expect(!try testAcceptsGzip(&.{"gzip;q=0"}));
    try std.testing.expect(!try testAcceptsGzip(&.{"gzip;q=0.000"}));
    try std.testing.expect(!try testAcceptsGzip(&.{"*, gzip;q=0"}));
    try std.testing.expect(!try testAcceptsGzip(&.{"*;q=0"}));
    try std.testing.expect(try testAcceptsGzip(&.{"gzip;q=0.001"}));
    try std.testing.expect(try testAcceptsGzip(&.{ "br", "gzip" }));
    try std.testing.expect(!try testAcceptsGzip(&.{ "*", "gzip;q=0" }));
    try std.testing.expect(!try testAcceptsGzip(&.{}));
}

test "ContentEncoding.fromString: case-insensitive, x-gzip is gzip, br is unknown" {
    try std.testing.expectEqual(ContentEncoding.identity, ContentEncoding.fromString("identity"));
    try std.testing.expectEqual(ContentEncoding.gzip, ContentEncoding.fromString("gzip"));
    try std.testing.expectEqual(ContentEncoding.gzip, ContentEncoding.fromString("x-gzip"));
    try std.testing.expectEqual(ContentEncoding.gzip, ContentEncoding.fromString("GZIP"));
    try std.testing.expectEqual(ContentEncoding.deflate, ContentEncoding.fromString("deflate"));
    try std.testing.expectEqual(ContentEncoding.unknown, ContentEncoding.fromString("br"));
    try std.testing.expectEqual(ContentEncoding.zstd, ContentEncoding.fromString("zstd"));
}

test "Headers.remove: case-insensitive, every copy, returns the count" {
    var headers = try Headers.init(std.testing.allocator, 8);
    defer headers.deinit(std.testing.allocator);

    try headers.put("Content-Type", "application/json");
    try headers.put("Host", "example.com");
    try headers.add("X-Tag", "a");
    try headers.add("X-Tag", "b");

    // Case-insensitive, and every copy goes.
    try std.testing.expectEqual(@as(usize, 1), headers.remove("content-type"));
    try std.testing.expectEqual(@as(?[]const u8, null), headers.get("Content-Type"));
    try std.testing.expectEqual(@as(usize, 2), headers.remove("X-Tag"));
    try std.testing.expectEqual(@as(usize, 0), headers.remove("X-Tag"));
    try std.testing.expectEqual(@as(usize, 0), headers.remove("Never-Set"));

    // What is left keeps its order and its values.
    try std.testing.expectEqual(@as(usize, 1), headers.count());
    try std.testing.expectEqualStrings("example.com", headers.get("Host").?);
}

test "Headers: remove compacts so later entries stay reachable" {
    var headers = try Headers.init(std.testing.allocator, 8);
    defer headers.deinit(std.testing.allocator);

    try headers.put("A", "1");
    try headers.put("B", "2");
    try headers.put("C", "3");
    _ = headers.remove("A");

    try std.testing.expectEqualStrings("2", headers.get("B").?);
    try std.testing.expectEqualStrings("3", headers.get("C").?);

    var it = headers.iterator();
    try std.testing.expectEqualStrings("B", it.next().?.key);
    try std.testing.expectEqualStrings("C", it.next().?.key);
    try std.testing.expectEqual(@as(?Headers.Iterator.Entry, null), it.next());
}
fn expectJson(expected: []const u8, value: anytype) !void {
    var buf: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    try std.json.Stringify.value(value, .{}, &out);
    try std.testing.expectEqualStrings(expected, out.buffered());
}

test "Headers: JSON object in insertion order" {
    var headers = try Headers.init(std.testing.allocator, 8);
    defer headers.deinit(std.testing.allocator);

    try headers.put("Host", "example.com");
    try headers.put("Accept", "*/*");
    try expectJson(
        \\{"Host":"example.com","Accept":"*/*"}
    , headers);
}

test "Headers: jsonStringify groups a repeated name into an array" {
    var headers = try Headers.init(std.testing.allocator, 8);
    defer headers.deinit(std.testing.allocator);

    try headers.add("Host", "example.com");
    try headers.add("X-Tag", "a");
    try headers.add("X-Tag", "b");
    try headers.add("X-Tag", "c");
    // The array is written where the name first appeared, and the name is
    // never repeated as a second key.
    try expectJson(
        \\{"Host":"example.com","X-Tag":["a","b","c"]}
    , headers);
}

test "Headers: jsonStringify groups case-insensitively" {
    var headers = try Headers.init(std.testing.allocator, 8);
    defer headers.deinit(std.testing.allocator);

    try headers.add("X-Tag", "a");
    try headers.add("x-tag", "b");
    try expectJson(
        \\{"X-Tag":["a","b"]}
    , headers);
}

test "Headers: jsonStringify escapes names and values" {
    var headers = try Headers.init(std.testing.allocator, 8);
    defer headers.deinit(std.testing.allocator);

    try headers.put("X-Quote", "a\"b");
    try expectJson(
        \\{"X-Quote":"a\"b"}
    , headers);
}

test "Headers: jsonStringify of an empty map" {
    const headers: Headers = .{};
    try expectJson("{}", headers);
}

test "Params: JSON object of string values, {} when empty" {
    var params: Params = .{};
    defer params.map.deinit(std.testing.allocator);
    try params.map.put(std.testing.allocator, "a", "1");
    try expectJson(
        \\{"a":"1"}
    , params);

    const empty: Params = .{};
    try expectJson("{}", empty);
}
