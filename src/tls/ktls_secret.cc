// C entry points for the two BoringSSL functions src/tls/ktls.zig needs that
// ssl.h declares for C++ only (inside BSSL_NAMESPACE). Linux only: build.zig
// compiles this file into the BoringSSL library there.
#include <openssl/ssl.h>

// The current TLS 1.3 write traffic secret: a view into the SSL, valid until
// the next SSL call on it. 0 before the handshake ends or below TLS 1.3.
extern "C" int anole_ssl_write_traffic_secret(const SSL *ssl, const uint8_t **out,
                                              size_t *out_len) {
  bssl::Span<const uint8_t> read, write;
  if (!bssl::SSL_get_traffic_secrets(ssl, &read, &write)) {
    return 0;
  }
  *out = write.data();
  *out_len = write.size();
  return 1;
}

// For tests: behave as if the CPU had no AES instructions, so a TLS 1.3
// handshake between two such ends picks ChaCha20-Poly1305.
extern "C" void anole_ssl_ctx_no_aes_hw_for_testing(SSL_CTX *ctx) {
  bssl::SSL_CTX_set_aes_hw_override_for_testing(ctx, false);
}
