/* spike/python/wake_socket.c - THROWAWAY: the doorbell anole-py would use on
 * Windows' ProactorEventLoop (no add_reader): Anole's wake callback sends one
 * byte on the write end of a socketpair, and a coroutine awaits
 * loop.sock_recv() on the read end, which the Proactor serves with an
 * overlapped WSARecv: asyncio's own cross-thread wake (_loop_self_reading).
 * No GIL, no Python on the executor. On Windows: send((SOCKET)ud, ...) from
 * ws2_32, the same three lines. */
#include <stdint.h>
#ifdef _WIN32
#include <winsock2.h>
#define EXPORT __declspec(dllexport)
void anole_py_wake_socket(void *ud) { send((SOCKET)(uintptr_t)ud, "", 1, 0); }
#else
#include <sys/socket.h>
#define EXPORT __attribute__((visibility("default")))
EXPORT void anole_py_wake_socket(void *ud) { send((int)(intptr_t)ud, "", 1, MSG_DONTWAIT); }
#endif
