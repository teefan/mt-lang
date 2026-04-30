module std.random

pub struct Random:
    state: u64

pub def create(seed: u64) -> Random:
    var generator = Random(state = 0)
    reseed(addr(generator), seed)
    return generator

pub def reseed(generator: ref[Random], seed: u64) -> void:
    value(generator).state = seed
    if value(generator).state == 0:
        value(generator).state = u64<-0x9e3779b97f4a7c15
    return

pub def next_u64(generator: ref[Random]) -> u64:
    var state = value(generator).state
    state = state + u64<-0x9e3779b97f4a7c15
    value(generator).state = state

    var mixed = state
    mixed = (mixed ^ (mixed >> 30)) * u64<-0xbf58476d1ce4e5b9
    mixed = (mixed ^ (mixed >> 27)) * u64<-0x94d049bb133111eb
    return mixed ^ (mixed >> 31)

pub def next_u32(generator: ref[Random]) -> u32:
    return u32<-(next_u64(generator) >> 32)

pub def next_bool(generator: ref[Random]) -> bool:
    return (next_u64(generator) & u64<-1) == u64<-1

pub def range_usize(generator: ref[Random], upper_bound: usize) -> usize:
    if upper_bound == 0:
        panic(c"random.range_usize upper_bound must be positive")

    return usize<-(next_u64(generator) % u64<-upper_bound)

pub def range_i32(generator: ref[Random], min_value: i32, max_value: i32) -> i32:
    if max_value < min_value:
        panic(c"random.range_i32 max_value must be >= min_value")

    let width = usize<-(i64<-max_value - i64<-min_value + 1)
    return min_value + i32<-range_usize(generator, width)
