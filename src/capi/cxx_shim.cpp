// libanole on Linux: the few C++ runtime symbols BoringSSL's objects (built
// against Zig's libc++ headers) still reference, so that libanole.a links
// into a Node addon or a Python extension with no C++ runtime at all, and
// never against the system's libstdc++ (which has no std::__1). The pack
// step (tools/capi-pack.sh) makes them local like everything but anole_*.
#include <algorithm>
#include <bit>
#include <cstdarg>
#include <cstddef>
#include <cstdio>
#include <cstdlib>

_LIBCPP_BEGIN_NAMESPACE_STD

[[noreturn]] void __libcpp_verbose_abort(const char *format, ...) noexcept {
  va_list ap;
  va_start(ap, format);
  std::vfprintf(stderr, format, ap);
  va_end(ap);
  std::abort();
}

// As libc++'s src/algorithm.cpp, which instantiates it in the library only.
template <class Comp, class RandomAccessIterator>
void __sort(RandomAccessIterator first, RandomAccessIterator last, Comp) {
  if (first == last) return;
  auto depth_limit = 2 * std::__bit_log2(static_cast<size_t>(last - first));
  std::__introsort<_ClassicAlgPolicy, ranges::less, RandomAccessIterator,
                   __use_branchless_sort<ranges::less, RandomAccessIterator>>(first, last, ranges::less{}, depth_limit);
}
template void __sort<__less<unsigned short> &, unsigned short *>(unsigned short *, unsigned short *,
                                                                  __less<unsigned short> &);

_LIBCPP_END_NAMESPACE_STD

// BoringSSL never allocates with operator new (nothing references it), so a
// sized delete is unreachable: it is here only for vtables' deleting
// destructors.
void operator delete(void *, std::size_t) noexcept { std::abort(); }
extern "C" void __cxa_pure_virtual() { std::abort(); }
