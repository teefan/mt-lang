import std.tracy as tracy

public const GPU_CALIBRATION_QUERY_COUNT: int = 32


public function begin_gpu_zone(srcloc: const_ptr[tracy.SourceLocation], active: int) -> tracy.Zone:
    return tracy.emit_gpu_zone_begin(srcloc, active)


public function end_gpu_zone(zone: tracy.Zone) -> void:
    tracy.emit_gpu_zone_end(zone)


public function gpu_zone_value(zone: tracy.Zone, value: long) -> void:
    tracy.emit_gpu_zone_value(zone, value)


public function gpu_calibrate(zone: tracy.Zone) -> void:
    tracy.emit_gpu_calibration(zone)


public function submit_gpu_time(gpu_time: long, query_id: ushort, context: ubyte) -> void:
    let data = tracy.GpuTime(
        gpu_time = gpu_time,
        query_id = query_id,
        context = context
    )
    tracy.emit_gpu_time(const_ptr_of(data))


public function submit_gpu_time_sync(gpu_time: long, query_id: ushort, context: ubyte) -> void:
    let data = tracy.GpuTime(
        gpu_time = gpu_time,
        query_id = query_id,
        context = context
    )
    tracy.emit_gpu_time_sync(const_ptr_of(data))
