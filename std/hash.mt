module std.hash


pub def mix_ulong(value: ulong) -> ulong:
    var x = value
    x = (x ^ (x >> 30)) * ulong<-0xbf58476d1ce4e5b9
    x = (x ^ (x >> 27)) * ulong<-0x94d049bb133111eb
    return x ^ (x >> 31)


pub def ulong_value(value: ulong) -> ulong:
    return mix_ulong(value)


pub def ulong_equal(left: ulong, right: ulong) -> bool:
    return left == right


pub def ptr_uint_value(value: ptr_uint) -> ulong:
    return mix_ulong(ulong<-value)


pub def ptr_uint_equal(left: ptr_uint, right: ptr_uint) -> bool:
    return left == right


pub def int_value(value: int) -> ulong:
    return mix_ulong(ulong<-value)


pub def int_equal(left: int, right: int) -> bool:
    return left == right


pub def str_value(text: str) -> ulong:
    var hash = ulong<-14695981039346656037
    var index: ptr_uint = 0
    while index < text.len:
        unsafe:
            hash = hash ^ ulong<-ubyte<-read(text.data + index)
        hash = hash * ulong<-1099511628211
        index += 1

    return hash


pub def str_equal(left: str, right: str) -> bool:
    if left.len != right.len:
        return false

    var index: ptr_uint = 0
    while index < left.len:
        unsafe:
            if read(left.data + index) != read(right.data + index):
                return false
        index += 1

    return true
