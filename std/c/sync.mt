external

link "uv"
include "sync_support.h"

opaque mt_mutex = c"mt_mutex"
opaque mt_condition = c"mt_condition"
opaque mt_semaphore = c"mt_semaphore"
opaque mt_atomic_uint = c"mt_atomic_uint"

external function mt_mutex_create(out out_mutex: ptr[mt_mutex]?) -> int
external function mt_mutex_create_recursive(out out_mutex: ptr[mt_mutex]?) -> int
external function mt_mutex_destroy(handle: ptr[mt_mutex]?) -> void
external function mt_mutex_lock(handle: ptr[mt_mutex]) -> void
external function mt_mutex_try_lock(handle: ptr[mt_mutex]) -> int
external function mt_mutex_unlock(handle: ptr[mt_mutex]) -> void
external function mt_condition_create(out out_condition: ptr[mt_condition]?) -> int
external function mt_condition_destroy(handle: ptr[mt_condition]?) -> void
external function mt_condition_signal(handle: ptr[mt_condition]) -> void
external function mt_condition_broadcast(handle: ptr[mt_condition]) -> void
external function mt_condition_wait(handle: ptr[mt_condition], mutex: ptr[mt_mutex]) -> void
external function mt_semaphore_create(initial_value: uint, out out_semaphore: ptr[mt_semaphore]?) -> int
external function mt_semaphore_destroy(handle: ptr[mt_semaphore]?) -> void
external function mt_semaphore_post(handle: ptr[mt_semaphore]) -> void
external function mt_semaphore_wait(handle: ptr[mt_semaphore]) -> void
external function mt_semaphore_try_wait(handle: ptr[mt_semaphore]) -> int
external function mt_atomic_uint_create(out out_atomic: ptr[mt_atomic_uint]?, initial_value: uint) -> int
external function mt_atomic_uint_destroy(handle: ptr[mt_atomic_uint]?) -> void
external function mt_atomic_uint_load(atomic: ptr[mt_atomic_uint]) -> uint
external function mt_atomic_uint_store(atomic: ptr[mt_atomic_uint], new_value: uint) -> void
external function mt_atomic_uint_fetch_add(atomic: ptr[mt_atomic_uint], delta: uint) -> uint
external function mt_atomic_uint_fetch_sub(atomic: ptr[mt_atomic_uint], delta: uint) -> uint
external function mt_atomic_uint_compare_exchange(atomic: ptr[mt_atomic_uint], expected: ptr[uint], desired: uint) -> bool
