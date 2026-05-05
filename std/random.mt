module std.random

pub struct Random:
    state: ulong


pub def create(seed: ulong) -> Random:
    var generator = Random(state = 0)
    reseed(ref_of(generator), seed)
    return generator


pub def reseed(generator: ref[Random], seed: ulong) -> void:
    generator.state = seed
    if generator.state == 0:
        generator.state = ulong<-0x9e3779b97f4a7c15
    return


pub def next_ulong(generator: ref[Random]) -> ulong:
    var state = generator.state
    state = state + ulong<-0x9e3779b97f4a7c15
    generator.state = state

    var mixed = state
    mixed = (mixed ^ (mixed >> 30)) * ulong<-0xbf58476d1ce4e5b9
    mixed = (mixed ^ (mixed >> 27)) * ulong<-0x94d049bb133111eb
    return mixed ^ (mixed >> 31)


pub def next_uint(generator: ref[Random]) -> uint:
    return uint<-(next_ulong(generator) >> 32)


pub def next_bool(generator: ref[Random]) -> bool:
    return (next_ulong(generator) & ulong<-1) == ulong<-1


pub def range_ptr_uint(generator: ref[Random], upper_bound: ptr_uint) -> ptr_uint:
    if upper_bound == 0:
        panic(c"random.range_ptr_uint upper_bound must be positive")

    return ptr_uint<-(next_ulong(generator) % ulong<-upper_bound)


pub def range_int(generator: ref[Random], min_value: int, max_value: int) -> int:
    if max_value < min_value:
        panic(c"random.range_int max_value must be >= min_value")

    let width = ptr_uint<-(long<-max_value - long<-min_value + 1)
    return min_value + int<-range_ptr_uint(generator, width)
