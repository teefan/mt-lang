import std.c.time as c

public type Timestamp = c.time_t
public type ClockId = c.clockid_t
public type DateTime = c.tm
public type TimeSpec = c.timespec

public const REALTIME_CLOCK: ClockId = c.CLOCK_REALTIME
public const MONOTONIC_CLOCK: ClockId = c.CLOCK_MONOTONIC
public const NANOSECONDS_PER_SECOND: ptr_uint = 1000000000
public const NANOSECONDS_PER_MILLISECOND: ptr_uint = 1000000

public foreign function current_timestamp(out value: Timestamp) -> Timestamp = c.time
public foreign function timestamp_from_local_time(value: ptr[DateTime]) -> Timestamp = c.mktime
public foreign function seconds_between(left: Timestamp, right: Timestamp) -> double = c.difftime
public foreign function format_date_time(buffer: ptr[char], max_size: ptr_uint, format: str as cstr, value: ptr[DateTime]) -> ptr_uint = c.strftime
public foreign function clock_resolution_into(clock_id: ClockId, out resolution: TimeSpec) -> int = c.clock_getres
public foreign function clock_time_into(clock_id: ClockId, out value: TimeSpec) -> int = c.clock_gettime
public foreign function sleep_for(duration: const_ptr[TimeSpec], remaining: ptr[TimeSpec]?) -> int = c.nanosleep


public function now() -> Timestamp:
    return c.time(null)


public function local_time_ptr(value: Timestamp) -> ptr[DateTime]?:
    var copy = value
    return c.localtime(ptr_of(copy))


public function utc_time_ptr(value: Timestamp) -> ptr[DateTime]?:
    var copy = value
    return c.gmtime(ptr_of(copy))


public function format_into(buffer: ptr[char], max_size: ptr_uint, format: str, value: ptr[DateTime]?) -> ptr_uint:
    if value == null:
        return 0

    return format_date_time(buffer, max_size, format, ptr[DateTime]<-value)


public function format_local_time_into(
    buffer: ptr[char],
    max_size: ptr_uint,
    format: str,
    value: Timestamp
) -> ptr_uint:
    return format_into(buffer, max_size, format, local_time_ptr(value))


public function format_utc_time_into(buffer: ptr[char], max_size: ptr_uint, format: str, value: Timestamp) -> ptr_uint:
    return format_into(buffer, max_size, format, utc_time_ptr(value))


public function clock_resolution(clock_id: ClockId, resolution: ref[TimeSpec]) -> int:
    return c.clock_getres(clock_id, ptr_of(resolution))


public function clock_time(clock_id: ClockId, value: ref[TimeSpec]) -> int:
    return c.clock_gettime(clock_id, ptr_of(value))


public function realtime(value: ref[TimeSpec]) -> int:
    return clock_time(REALTIME_CLOCK, value)


public function monotonic(value: ref[TimeSpec]) -> int:
    return clock_time(MONOTONIC_CLOCK, value)


public function seconds(value: ptr_int) -> TimeSpec:
    return c.timespec(tv_sec = value, tv_nsec = 0)


public function milliseconds(value: ptr_uint) -> TimeSpec:
    let seconds_part = ptr_int<-(value / ptr_uint<-1000)
    let nanoseconds_part = ptr_int<-((value % ptr_uint<-1000) * NANOSECONDS_PER_MILLISECOND)
    return c.timespec(tv_sec = seconds_part, tv_nsec = nanoseconds_part)


public function nanoseconds(value: ptr_uint) -> TimeSpec:
    let seconds_part = ptr_int<-(value / NANOSECONDS_PER_SECOND)
    let nanoseconds_part = ptr_int<-(value % NANOSECONDS_PER_SECOND)
    return c.timespec(tv_sec = seconds_part, tv_nsec = nanoseconds_part)


public function sleep(duration: TimeSpec) -> int:
    var requested = duration
    return sleep_for(ptr_of(requested), null)


public function sleep_seconds(value: ptr_uint) -> int:
    var requested = seconds(ptr_int<-value)
    return sleep_for(ptr_of(requested), null)


public function sleep_milliseconds(value: ptr_uint) -> int:
    var requested = milliseconds(value)
    return sleep_for(ptr_of(requested), null)


public function sleep_nanoseconds(value: ptr_uint) -> int:
    var requested = nanoseconds(value)
    return sleep_for(ptr_of(requested), null)
