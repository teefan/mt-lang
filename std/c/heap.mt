external

include "heap_support.h"

external function mt_heap_get_active_region() -> ptr[void]?
external function mt_heap_set_active_region(region: ptr[void]?) -> void
external function mt_heap_get_live_regions() -> ptr[void]?
external function mt_heap_set_live_regions(region: ptr[void]?) -> void
external function mt_thread_id() -> ptr_uint
