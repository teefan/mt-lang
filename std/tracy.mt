import std.c.tracy as c

public type Zone = c.TracyCZoneCtx
public type SourceLocation = c.TracyCSourceLocation
public type GpuTime = c.TracyCGpuTime
public type GpuZoneName = c.TracyCGpuZoneName

const PLOT_FORMAT_NUMBER: int = 0
const PLOT_FORMAT_MEMORY: int = 1
const PLOT_FORMAT_PERCENTAGE: int = 2
const PLOT_FORMAT_WATT: int = 3

public foreign function zone_begin(srcloc: const_ptr[SourceLocation]?, active: int) -> Zone = c.___tracy_emit_zone_begin
public foreign function zone_end(zone: Zone) -> void = c.___tracy_emit_zone_end
public foreign function zone_text(zone: const_ptr[Zone], text: str as cstr, size: ptr_uint) -> void = c.___tracy_emit_zone_text
public foreign function zone_name(zone: const_ptr[Zone], name: str as cstr, size: ptr_uint) -> void = c.___tracy_emit_zone_name
public foreign function zone_value(zone: const_ptr[Zone], value: long) -> void = c.___tracy_emit_zone_value

public foreign function gpu_zone_begin(srcloc: const_ptr[SourceLocation]?, active: int) -> Zone = c.___tracy_emit_gpu_zone_begin
public foreign function gpu_zone_end(zone: const_ptr[Zone]) -> void = c.___tracy_emit_gpu_zone_end
public foreign function gpu_zone_name(zone: const_ptr[Zone], name: str as cstr, size: ptr_uint) -> void = c.___tracy_emit_gpu_zone_name
public foreign function gpu_zone_value(zone: const_ptr[Zone], value: long) -> void = c.___tracy_emit_gpu_zone_value
public foreign function gpu_new_context(zone: const_ptr[Zone]) -> void = c.___tracy_emit_gpu_new_context
public foreign function gpu_context_name(zone: const_ptr[Zone], name: str as cstr, size: ptr_uint) -> void = c.___tracy_emit_gpu_context_name
public foreign function gpu_calibration(zone: const_ptr[Zone]) -> void = c.___tracy_emit_gpu_calibration
public foreign function gpu_time(data: const_ptr[GpuTime]) -> void = c.___tracy_emit_gpu_time
public foreign function gpu_time_sync(data: const_ptr[GpuTime]) -> void = c.___tracy_emit_gpu_time_sync

public foreign function frame_mark(name: str as cstr) -> void = c.___tracy_emit_frame_mark
public foreign function frame_mark_start(name: str as cstr) -> void = c.___tracy_emit_frame_mark_start
public foreign function frame_mark_end(name: str as cstr) -> void = c.___tracy_emit_frame_mark_end

public foreign function plot(name: str as cstr, value: double) -> void = c.___tracy_emit_plot
public foreign function plot_float(name: str as cstr, value: float) -> void = c.___tracy_emit_plot_float
public foreign function plot_int(name: str as cstr, value: long) -> void = c.___tracy_emit_plot_int

public foreign function message(text: str as cstr, size: ptr_uint, callstack: int) -> void = c.___tracy_emit_message
public foreign function message_l(text: str as cstr, callstack: int) -> void = c.___tracy_emit_message_l
public foreign function message_lc(text: str as cstr, color: uint, callstack: int) -> void = c.___tracy_emit_message_lc

public foreign function is_connected() -> int = c.___tracy_connected

public foreign function fiber_enter(fiber: str as cstr) -> void = c.___tracy_fiber_enter
public foreign function fiber_leave() -> void = c.___tracy_fiber_leave
