/* tests/capi/tls_start.c - a TLS listener on libanole.a, in a program linked
 * with dead-stripping (Mach-O -dead_strip, ELF --gc-sections), as bindings
 * and release links are. tests/capi/tls_start.zig runs it: this prints the
 * listener's port, serves until its stdin closes, then drains and exits 0.
 *
 * Regression check for the packed object losing Mach-O N_ALT_ENTRY flags:
 * a dead-stripped link cut BoringSSL's assembly apart and the first TLS
 * listener crashed while making its key (tools/capi_symbols.zig).
 */
#include "anole.h"

#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(void) {
  const char *json =
      "{\"listeners\": [{\"address\": \"127.0.0.1\", \"port\": 0, \"tls\": {\"self_signed\": true}}],"
      " \"routes\": [{\"path\": \"/\", \"respond\": {\"body\": \"dead-strip ok\"}}]}";
  anole_server_options o = {sizeof o, {json, strlen(json)}, 0, 0, NULL, NULL};
  anole_server *s = NULL;
  if (anole_server_create(&o, &s) != ANOLE_OK || anole_server_start(s) != ANOLE_OK) {
    anole_str e = anole_last_error();
    fprintf(stderr, "tls_start: %.*s\n", (int)e.len, e.ptr);
    return 1;
  }
  uint16_t port = 0;
  if (anole_server_port(s, 0, &port) != ANOLE_OK) return 1;
  printf("%u\n", port);
  fflush(stdout);
  char buf[64];
  while (read(0, buf, sizeof buf) > 0) {
  }
  anole_server_drain(s);
  if (anole_server_wait(s, 10000) != ANOLE_OK) return 1;
  anole_server_destroy(s);
  return 0;
}
