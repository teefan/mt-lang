module std.hash

pub def mix_u64(value: u64) -> u64:
    var x = value
    x = (x ^ (x >> 30)) * u64<-0xbf58476d1ce4e5b9
    x = (x ^ (x >> 27)) * u64<-0x94d049bb133111eb
    return x ^ (x >> 31)

pub def u64_value(value: u64) -> u64:
    return mix_u64(value)

pub def u64_equal(left: u64, right: u64) -> bool:
    return left == right

pub def usize_value(value: usize) -> u64:
    return mix_u64(u64<-value)

pub def usize_equal(left: usize, right: usize) -> bool:
    return left == right

pub def i32_value(value: i32) -> u64:
    return mix_u64(u64<-value)

pub def i32_equal(left: i32, right: i32) -> bool:
    return left == right

pub def str_value(text: str) -> u64:
    var hash = u64<-14695981039346656037
    var index: usize = 0
    while index < text.len:
        unsafe:
            hash = hash ^ u64<-u8<-read(text.data + index)
        hash = hash * u64<-1099511628211
        index += 1

    return hash

pub def str_equal(left: str, right: str) -> bool:
    if left.len != right.len:
        return false

    var index: usize = 0
    while index < left.len:
        unsafe:
            if read(left.data + index) != read(right.data + index):
                return false
        index += 1

    return true
