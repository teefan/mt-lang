external

link "uv"
include "sync_support.h"

opaque mt_mutex = c"mt_mutex"
opaque mt_condition = c"mt_condition"
opaque mt_semaphore = c"mt_semaphore"

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
