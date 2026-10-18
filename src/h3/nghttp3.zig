//! nghttp3 bindings: the translate-c output (`c`) plus typed wrappers for the 7 public
//! function-like macros in nghttp3.h that splice a *_VERSION constant into a `*_versioned`
//! symbol. See ngtcp2.zig for why typed wrappers are kept even though
//! translate-c (zig-0.17.x) emits `anytype` inline fns for these macros.
pub const c = @import("anole_nghttp3_c");

pub const Conn = c.nghttp3_conn;
pub const Settings = c.nghttp3_settings;
pub const Callbacks = c.nghttp3_callbacks;
pub const Mem = c.nghttp3_mem;
pub const Pri = c.nghttp3_pri;

pub fn settingsDefault(settings: *Settings) void {
    c.nghttp3_settings_default_versioned(c.NGHTTP3_SETTINGS_VERSION, settings);
}

pub fn connServerNew(pconn: *?*Conn, callbacks: *const Callbacks, settings: *const Settings, mem: ?*const Mem, user_data: ?*anyopaque) c_int {
    return c.nghttp3_conn_server_new_versioned(pconn, c.NGHTTP3_CALLBACKS_VERSION, callbacks, c.NGHTTP3_SETTINGS_VERSION, settings, mem, user_data);
}

pub fn connClientNew(pconn: *?*Conn, callbacks: *const Callbacks, settings: *const Settings, mem: ?*const Mem, user_data: ?*anyopaque) c_int {
    return c.nghttp3_conn_client_new_versioned(pconn, c.NGHTTP3_CALLBACKS_VERSION, callbacks, c.NGHTTP3_SETTINGS_VERSION, settings, mem, user_data);
}

pub fn connSetServerStreamPriority(conn: *Conn, stream_id: i64, pri: *const Pri) c_int {
    return c.nghttp3_conn_set_server_stream_priority_versioned(conn, stream_id, c.NGHTTP3_PRI_VERSION, pri);
}

pub fn connGetStreamPriority(conn: *Conn, dest: *Pri, stream_id: i64) c_int {
    return c.nghttp3_conn_get_stream_priority_versioned(conn, c.NGHTTP3_PRI_VERSION, dest, stream_id);
}

pub fn connGetStreamPriority2(conn: *const Conn, dest: *Pri, stream_id: i64) c_int {
    return c.nghttp3_conn_get_stream_priority2_versioned(conn, c.NGHTTP3_PRI_VERSION, dest, stream_id);
}

pub fn priParsePriority(dest: *Pri, value: []const u8) c_int {
    return c.nghttp3_pri_parse_priority_versioned(c.NGHTTP3_PRI_VERSION, dest, value.ptr, value.len);
}
