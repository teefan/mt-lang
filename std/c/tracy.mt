external

link "tracyclient"
link "stdc++"
include "TracyC.h"

opaque TracyCZoneCtx = c"TracyCZoneCtx"

opaque TracyCSourceLocation

struct TracyCGpuTime:
    gpu_time: long
    query_id: ushort
    context: ubyte

struct TracyCGpuZoneName:
    query_id: ushort
    context: ubyte
    name: cstr

external function tracy_emit_zone_begin(srcloc: const_ptr[TracyCSourceLocation]?, active: int) -> TracyCZoneCtx = c"___tracy_emit_zone_begin"
external function tracy_emit_zone_begin_callstack(srcloc: const_ptr[TracyCSourceLocation]?, depth: int, active: int) -> TracyCZoneCtx = c"___tracy_emit_zone_begin_callstack"
external function tracy_emit_zone_end(ctx: TracyCZoneCtx) -> void = c"___tracy_emit_zone_end"
external function tracy_emit_zone_text(ctx: TracyCZoneCtx, text: cstr, size: ptr_uint) -> void = c"___tracy_emit_zone_text"
external function tracy_emit_zone_name(ctx: TracyCZoneCtx, name: cstr, size: ptr_uint) -> void = c"___tracy_emit_zone_name"
external function tracy_emit_zone_color(ctx: TracyCZoneCtx, color: uint) -> void = c"___tracy_emit_zone_color"
external function tracy_emit_zone_value(ctx: TracyCZoneCtx, value: long) -> void = c"___tracy_emit_zone_value"
external function tracy_emit_gpu_zone_begin(srcloc: const_ptr[TracyCSourceLocation]?, active: int) -> TracyCZoneCtx = c"___tracy_emit_gpu_zone_begin"
external function tracy_emit_gpu_zone_begin_callstack(srcloc: const_ptr[TracyCSourceLocation]?, depth: int, active: int) -> TracyCZoneCtx = c"___tracy_emit_gpu_zone_begin_callstack"
external function tracy_emit_gpu_zone_end(ctx: TracyCZoneCtx) -> void = c"___tracy_emit_gpu_zone_end"
external function tracy_emit_gpu_zone_name(ctx: TracyCZoneCtx, name: cstr, size: ptr_uint) -> void = c"___tracy_emit_gpu_zone_name"
external function tracy_emit_gpu_zone_value(ctx: TracyCZoneCtx, value: long) -> void = c"___tracy_emit_gpu_zone_value"
external function tracy_emit_gpu_new_context(ctx: TracyCZoneCtx) -> void = c"___tracy_emit_gpu_new_context"
external function tracy_emit_gpu_context_name(ctx: TracyCZoneCtx, name: cstr, size: ptr_uint) -> void = c"___tracy_emit_gpu_context_name"
external function tracy_emit_gpu_calibration(ctx: TracyCZoneCtx) -> void = c"___tracy_emit_gpu_calibration"
external function tracy_emit_gpu_time(data: const_ptr[TracyCGpuTime]) -> void = c"___tracy_emit_gpu_time"
external function tracy_emit_gpu_time_sync(data: const_ptr[TracyCGpuTime]) -> void = c"___tracy_emit_gpu_time_sync"
external function tracy_emit_frame_mark(name: cstr) -> void = c"___tracy_emit_frame_mark"
external function tracy_emit_frame_mark_start(name: cstr) -> void = c"___tracy_emit_frame_mark_start"
external function tracy_emit_frame_mark_end(name: cstr) -> void = c"___tracy_emit_frame_mark_end"
external function tracy_emit_plot(name: cstr, value: double) -> void = c"___tracy_emit_plot"
external function tracy_emit_plot_config(name: cstr, format_type: int, step: int, fill: int, color: uint) -> void = c"___tracy_emit_plot_config"
external function tracy_emit_plot_float(name: cstr, value: float) -> void = c"___tracy_emit_plot_float"
external function tracy_emit_plot_int(name: cstr, value: long) -> void = c"___tracy_emit_plot_int"
external function tracy_emit_message(text: cstr, size: ptr_uint, callstack: int) -> void = c"___tracy_emit_message"
external function tracy_emit_message_color(text: cstr, size: ptr_uint, color: uint, callstack: int) -> void = c"___tracy_emit_message_color"
external function tracy_emit_message_l(text: cstr, callstack: int) -> void = c"___tracy_emit_message_l"
external function tracy_emit_message_lc(text: cstr, color: uint, callstack: int) -> void = c"___tracy_emit_message_lc"
external function tracy_connected() -> int = c"___tracy_connected"
external function tracy_fiber_enter(fiber: cstr) -> void = c"___tracy_fiber_enter"
external function tracy_fiber_leave() -> void = c"___tracy_fiber_leave"
external function tracy_startup_profiler() -> void = c"___tracy_startup_profiler"
external function tracy_shutdown_profiler() -> void = c"___tracy_shutdown_profiler"
