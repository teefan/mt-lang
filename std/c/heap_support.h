#ifndef MT_HEAP_SUPPORT_H
#define MT_HEAP_SUPPORT_H

#include <stddef.h>
#include <stdint.h>

#if defined(_MSC_VER)
#define MT_HEAP_THREAD_LOCAL __declspec(thread)
#else
#define MT_HEAP_THREAD_LOCAL _Thread_local
#endif

/* Per-thread heap state.  The generated program is currently one translation
 * unit, so these definitions are shared by every heap call in the program.
 * A future split-TU build must move them into one runtime unit. */
static MT_HEAP_THREAD_LOCAL void* mt_heap_active_region = NULL;
static MT_HEAP_THREAD_LOCAL void* mt_heap_live_regions = NULL;

static inline void* mt_heap_get_active_region(void) {
  return mt_heap_active_region;
}

static inline void mt_heap_set_active_region(void* region) {
  mt_heap_active_region = region;
}

static inline void* mt_heap_get_live_regions(void) {
  return mt_heap_live_regions;
}

static inline void mt_heap_set_live_regions(void* region) {
  mt_heap_live_regions = region;
}

#if defined(__EMSCRIPTEN__)
static inline uintptr_t mt_thread_id(void) {
  return 0;
}
#elif defined(_WIN32)
#include <windows.h>
static inline uintptr_t mt_thread_id(void) {
  return (uintptr_t)GetCurrentThreadId();
}
#else
#include <pthread.h>
static inline uintptr_t mt_thread_id(void) {
  return (uintptr_t)pthread_self();
}
#endif

#endif
