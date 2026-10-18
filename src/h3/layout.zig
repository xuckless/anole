//! C-side sizes/offsets exported by layout.c (compiled with the same headers and macros).

extern const anole_layout_ngtcp2_settings_size: usize;
extern const anole_layout_ngtcp2_transport_params_size: usize;
extern const anole_layout_ngtcp2_callbacks_size: usize;
extern const anole_layout_ngtcp2_cid_size: usize;
extern const anole_layout_ngtcp2_path_size: usize;
extern const anole_layout_ngtcp2_pkt_info_size: usize;
extern const anole_layout_ngtcp2_pkt_info_align: usize;
extern const anole_layout_ngtcp2_conn_info_size: usize;
extern const anole_layout_ngtcp2_settings_initial_ts_off: usize;
extern const anole_layout_ngtcp2_settings_pmtud_probes_off: usize;
extern const anole_layout_ngtcp2_transport_params_original_dcid_present_off: usize;
extern const anole_layout_ngtcp2_callbacks_stream_close2_off: usize;
extern const anole_layout_nghttp3_settings_size: usize;
extern const anole_layout_nghttp3_callbacks_size: usize;
extern const anole_layout_nghttp3_pri_size: usize;
extern const anole_layout_nghttp3_pri_align: usize;

pub fn ngtcp2_settings_size_get() usize {
    return anole_layout_ngtcp2_settings_size;
}
pub fn ngtcp2_transport_params_size_get() usize {
    return anole_layout_ngtcp2_transport_params_size;
}
pub fn ngtcp2_callbacks_size_get() usize {
    return anole_layout_ngtcp2_callbacks_size;
}
pub fn ngtcp2_cid_size_get() usize {
    return anole_layout_ngtcp2_cid_size;
}
pub fn ngtcp2_path_size_get() usize {
    return anole_layout_ngtcp2_path_size;
}
pub fn ngtcp2_pkt_info_size_get() usize {
    return anole_layout_ngtcp2_pkt_info_size;
}
pub fn ngtcp2_pkt_info_align_get() usize {
    return anole_layout_ngtcp2_pkt_info_align;
}
pub fn ngtcp2_conn_info_size_get() usize {
    return anole_layout_ngtcp2_conn_info_size;
}
pub fn ngtcp2_settings_initial_ts_off_get() usize {
    return anole_layout_ngtcp2_settings_initial_ts_off;
}
pub fn ngtcp2_settings_pmtud_probes_off_get() usize {
    return anole_layout_ngtcp2_settings_pmtud_probes_off;
}
pub fn ngtcp2_transport_params_original_dcid_present_off_get() usize {
    return anole_layout_ngtcp2_transport_params_original_dcid_present_off;
}
pub fn ngtcp2_callbacks_stream_close2_off_get() usize {
    return anole_layout_ngtcp2_callbacks_stream_close2_off;
}
pub fn nghttp3_settings_size_get() usize {
    return anole_layout_nghttp3_settings_size;
}
pub fn nghttp3_callbacks_size_get() usize {
    return anole_layout_nghttp3_callbacks_size;
}
pub fn nghttp3_pri_size_get() usize {
    return anole_layout_nghttp3_pri_size;
}
pub fn nghttp3_pri_align_get() usize {
    return anole_layout_nghttp3_pri_align;
}
