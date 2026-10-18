/* Sizes/offsets as the C compiler sees them, compared against translate-c output in tests. */
#include <stddef.h>
#include <ngtcp2/ngtcp2.h>
#include <nghttp3/nghttp3.h>

#define L(name, expr) const size_t anole_layout_##name = (expr);
L(ngtcp2_settings_size, sizeof(ngtcp2_settings))
L(ngtcp2_transport_params_size, sizeof(ngtcp2_transport_params))
L(ngtcp2_callbacks_size, sizeof(ngtcp2_callbacks))
L(ngtcp2_cid_size, sizeof(ngtcp2_cid))
L(ngtcp2_path_size, sizeof(ngtcp2_path))
L(ngtcp2_pkt_info_size, sizeof(ngtcp2_pkt_info))
L(ngtcp2_pkt_info_align, _Alignof(ngtcp2_pkt_info))
L(ngtcp2_conn_info_size, sizeof(ngtcp2_conn_info))
L(ngtcp2_settings_initial_ts_off, offsetof(ngtcp2_settings, initial_ts))
L(ngtcp2_settings_pmtud_probes_off, offsetof(ngtcp2_settings, pmtud_probes))
L(ngtcp2_transport_params_original_dcid_present_off, offsetof(ngtcp2_transport_params, original_dcid_present))
L(ngtcp2_callbacks_stream_close2_off, offsetof(ngtcp2_callbacks, stream_close2))
L(nghttp3_settings_size, sizeof(nghttp3_settings))
L(nghttp3_callbacks_size, sizeof(nghttp3_callbacks))
L(nghttp3_pri_size, sizeof(nghttp3_pri))
L(nghttp3_pri_align, _Alignof(nghttp3_pri))
