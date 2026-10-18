//! ngtcp2 bindings: the translate-c output (`c`) plus typed wrappers for every public
//! function-like macro in ngtcp2.h that splices a *_VERSION constant into a `*_versioned`
//! symbol (17 in ngtcp2 1.25.0).
//!
//! translate-c (zig-0.17.x) does translate these macros, but as `pub inline fn` with
//! `anytype` parameters and an `@TypeOf(...)` return, so a wrong argument type is only
//! caught at the call into the extern. These wrappers pin the types and the struct version
//! that the headers were built with, so the version passed always matches the layout Zig
//! sees. If a future ngtcp2 bumps e.g. NGTCP2_SETTINGS_VERSION, the constant comes from the
//! same translated header as the struct, so they stay in step.
pub const c = @import("anole_ngtcp2_c");

pub const Conn = c.ngtcp2_conn;
pub const Settings = c.ngtcp2_settings;
pub const TransportParams = c.ngtcp2_transport_params;
pub const Callbacks = c.ngtcp2_callbacks;
pub const Cid = c.ngtcp2_cid;
pub const Path = c.ngtcp2_path;
pub const PktInfo = c.ngtcp2_pkt_info;
pub const Mem = c.ngtcp2_mem;
pub const ConnInfo = c.ngtcp2_conn_info;
pub const CcErr = c.ngtcp2_ccerr;
pub const Vec = c.ngtcp2_vec;
pub const Tstamp = c.ngtcp2_tstamp;
pub const Ssize = c.ngtcp2_ssize;

pub fn settingsDefault(settings: *Settings) void {
    c.ngtcp2_settings_default_versioned(c.NGTCP2_SETTINGS_VERSION, settings);
}

pub fn transportParamsDefault(params: *TransportParams) void {
    c.ngtcp2_transport_params_default_versioned(c.NGTCP2_TRANSPORT_PARAMS_VERSION, params);
}

pub fn transportParamsEncode(dest: []u8, params: *const TransportParams) Ssize {
    return c.ngtcp2_transport_params_encode_versioned(dest.ptr, dest.len, c.NGTCP2_TRANSPORT_PARAMS_VERSION, params);
}

pub fn transportParamsDecode(params: *TransportParams, data: []const u8) c_int {
    return c.ngtcp2_transport_params_decode_versioned(c.NGTCP2_TRANSPORT_PARAMS_VERSION, params, data.ptr, data.len);
}

pub fn connServerNew(
    pconn: *?*Conn,
    dcid: *const Cid,
    scid: *const Cid,
    path: *const Path,
    client_chosen_version: u32,
    callbacks: *const Callbacks,
    settings: *const Settings,
    params: *const TransportParams,
    mem: ?*const Mem,
    user_data: ?*anyopaque,
) c_int {
    return c.ngtcp2_conn_server_new_versioned(pconn, dcid, scid, path, client_chosen_version, c.NGTCP2_CALLBACKS_VERSION, callbacks, c.NGTCP2_SETTINGS_VERSION, settings, c.NGTCP2_TRANSPORT_PARAMS_VERSION, params, mem, user_data);
}

pub fn connClientNew(
    pconn: *?*Conn,
    dcid: *const Cid,
    scid: *const Cid,
    path: *const Path,
    client_chosen_version: u32,
    callbacks: *const Callbacks,
    settings: *const Settings,
    params: *const TransportParams,
    mem: ?*const Mem,
    user_data: ?*anyopaque,
) c_int {
    return c.ngtcp2_conn_client_new_versioned(pconn, dcid, scid, path, client_chosen_version, c.NGTCP2_CALLBACKS_VERSION, callbacks, c.NGTCP2_SETTINGS_VERSION, settings, c.NGTCP2_TRANSPORT_PARAMS_VERSION, params, mem, user_data);
}

pub fn connSetLocalTransportParams(conn: *Conn, params: *const TransportParams) c_int {
    return c.ngtcp2_conn_set_local_transport_params_versioned(conn, c.NGTCP2_TRANSPORT_PARAMS_VERSION, params);
}

pub fn connReadPkt(conn: *Conn, path: *const Path, pi: ?*const PktInfo, pkt: []const u8, ts: Tstamp) c_int {
    return c.ngtcp2_conn_read_pkt_versioned(conn, path, c.NGTCP2_PKT_INFO_VERSION, pi, pkt.ptr, pkt.len, ts);
}

pub fn connWritePkt(conn: *Conn, path: ?*Path, pi: ?*PktInfo, dest: []u8, ts: Tstamp) Ssize {
    return c.ngtcp2_conn_write_pkt_versioned(conn, path, c.NGTCP2_PKT_INFO_VERSION, pi, dest.ptr, dest.len, ts);
}

pub fn connWriteStream(conn: *Conn, path: ?*Path, pi: ?*PktInfo, dest: []u8, pdatalen: ?*Ssize, flags: u32, stream_id: i64, data: []const u8, ts: Tstamp) Ssize {
    return c.ngtcp2_conn_write_stream_versioned(conn, path, c.NGTCP2_PKT_INFO_VERSION, pi, dest.ptr, dest.len, pdatalen, flags, stream_id, data.ptr, data.len, ts);
}

pub fn connWritevStream(conn: *Conn, path: ?*Path, pi: ?*PktInfo, dest: []u8, pdatalen: ?*Ssize, flags: u32, stream_id: i64, datav: []const Vec, ts: Tstamp) Ssize {
    return c.ngtcp2_conn_writev_stream_versioned(conn, path, c.NGTCP2_PKT_INFO_VERSION, pi, dest.ptr, dest.len, pdatalen, flags, stream_id, datav.ptr, datav.len, ts);
}

pub fn connWriteDatagram(conn: *Conn, path: ?*Path, pi: ?*PktInfo, dest: []u8, paccepted: ?*c_int, flags: u32, dgram_id: u64, data: []const u8, ts: Tstamp) Ssize {
    return c.ngtcp2_conn_write_datagram_versioned(conn, path, c.NGTCP2_PKT_INFO_VERSION, pi, dest.ptr, dest.len, paccepted, flags, dgram_id, data.ptr, data.len, ts);
}

pub fn connWritevDatagram(conn: *Conn, path: ?*Path, pi: ?*PktInfo, dest: []u8, paccepted: ?*c_int, flags: u32, dgram_id: u64, datav: []const Vec, ts: Tstamp) Ssize {
    return c.ngtcp2_conn_writev_datagram_versioned(conn, path, c.NGTCP2_PKT_INFO_VERSION, pi, dest.ptr, dest.len, paccepted, flags, dgram_id, datav.ptr, datav.len, ts);
}

pub fn connWriteConnectionClose(conn: *Conn, path: ?*Path, pi: ?*PktInfo, dest: []u8, ccerr: *const CcErr, ts: Tstamp) Ssize {
    return c.ngtcp2_conn_write_connection_close_versioned(conn, path, c.NGTCP2_PKT_INFO_VERSION, pi, dest.ptr, dest.len, ccerr, ts);
}

pub fn connWriteAggregatePkt(conn: *Conn, path: ?*Path, pi: ?*PktInfo, buf: []u8, pgsolen: *usize, write_pkt: c.ngtcp2_write_pkt, ts: Tstamp) Ssize {
    return c.ngtcp2_conn_write_aggregate_pkt_versioned(conn, path, c.NGTCP2_PKT_INFO_VERSION, pi, buf.ptr, buf.len, pgsolen, write_pkt, ts);
}

pub fn connWriteAggregatePkt2(conn: *Conn, path: ?*Path, pi: ?*PktInfo, buf: []u8, pgsolen: *usize, write_pkt: c.ngtcp2_write_pkt, num_pkts: usize, ts: Tstamp) Ssize {
    return c.ngtcp2_conn_write_aggregate_pkt2_versioned(conn, path, c.NGTCP2_PKT_INFO_VERSION, pi, buf.ptr, buf.len, pgsolen, write_pkt, num_pkts, ts);
}

pub fn connGetConnInfo(conn: *Conn, cinfo: *ConnInfo) void {
    c.ngtcp2_conn_get_conn_info_versioned(conn, c.NGTCP2_CONN_INFO_VERSION, cinfo);
}

pub fn connGetConnInfo2(conn: *const Conn, cinfo: *ConnInfo) void {
    c.ngtcp2_conn_get_conn_info2_versioned(conn, c.NGTCP2_CONN_INFO_VERSION, cinfo);
}
