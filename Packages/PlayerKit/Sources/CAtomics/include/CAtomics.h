#ifndef CATOMICS_H
#define CATOMICS_H

#include <stdatomic.h>
#include <stdint.h>

/// Minimal acquire/release access to a plain, naturally aligned `int64_t` so Swift can publish a
/// counter between two threads without locks. (`Synchronization.Atomic` needs macOS 15.)
static inline int64_t ca_load_acquire(const int64_t *p) {
    return atomic_load_explicit((const _Atomic int64_t *)p, memory_order_acquire);
}

static inline void ca_store_release(int64_t *p, int64_t v) {
    atomic_store_explicit((_Atomic int64_t *)p, v, memory_order_release);
}

#endif
