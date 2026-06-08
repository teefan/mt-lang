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

external function ___tracy_emit_zone_begin(srcloc: const_ptr[TracyCSourceLocation]?, active: int) -> TracyCZoneCtx
external function ___tracy_emit_zone_begin_callstack(srcloc: const_ptr[TracyCSourceLocation]?, depth: int, active: int) -> TracyCZoneCtx
external function ___tracy_emit_zone_end(ctx: TracyCZoneCtx) -> void
external function ___tracy_emit_zone_text(ctx: TracyCZoneCtx, text: cstr, size: ptr_uint) -> void
external function ___tracy_emit_zone_name(ctx: TracyCZoneCtx, name: cstr, size: ptr_uint) -> void
external function ___tracy_emit_zone_color(ctx: TracyCZoneCtx, color: uint) -> void
external function ___tracy_emit_zone_value(ctx: TracyCZoneCtx, value: long) -> void

external function ___tracy_emit_gpu_zone_begin(srcloc: const_ptr[TracyCSourceLocation]?, active: int) -> TracyCZoneCtx
external function ___tracy_emit_gpu_zone_begin_callstack(srcloc: const_ptr[TracyCSourceLocation]?, depth: int, active: int) -> TracyCZoneCtx
external function ___tracy_emit_gpu_zone_end(ctx: TracyCZoneCtx) -> void
external function ___tracy_emit_gpu_zone_name(ctx: TracyCZoneCtx, name: cstr, size: ptr_uint) -> void
external function ___tracy_emit_gpu_zone_value(ctx: TracyCZoneCtx, value: long) -> void
external function ___tracy_emit_gpu_new_context(ctx: TracyCZoneCtx) -> void
external function ___tracy_emit_gpu_context_name(ctx: TracyCZoneCtx, name: cstr, size: ptr_uint) -> void
external function ___tracy_emit_gpu_calibration(ctx: TracyCZoneCtx) -> void
external function ___tracy_emit_gpu_time(data: const_ptr[TracyCGpuTime]) -> void
external function ___tracy_emit_gpu_time_sync(data: const_ptr[TracyCGpuTime]) -> void

external function ___tracy_emit_frame_mark(name: cstr) -> void
external function ___tracy_emit_frame_mark_start(name: cstr) -> void
external function ___tracy_emit_frame_mark_end(name: cstr) -> void

external function ___tracy_emit_plot(name: cstr, value: double) -> void
external function ___tracy_emit_plot_config(name: cstr, format_type: int, step: int, fill: int, color: uint) -> void
external function ___tracy_emit_plot_float(name: cstr, value: float) -> void
external function ___tracy_emit_plot_int(name: cstr, value: long) -> void

external function ___tracy_emit_message(text: cstr, size: ptr_uint, callstack: int) -> void
external function ___tracy_emit_message_color(text: cstr, size: ptr_uint, color: uint, callstack: int) -> void
external function ___tracy_emit_message_l(text: cstr, callstack: int) -> void
external function ___tracy_emit_message_lc(text: cstr, color: uint, callstack: int) -> void

external function ___tracy_connected() -> int

external function ___tracy_fiber_enter(fiber: cstr) -> void
external function ___tracy_fiber_leave() -> void
