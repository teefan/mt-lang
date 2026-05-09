module std.hash


public function mix_ulong(value: ulong) -> ulong:
    var x = value
    x = (x ^ (x >> 30)) * ulong<-0xbf58476d1ce4e5b9
    x = (x ^ (x >> 27)) * ulong<-0x94d049bb133111eb
    return x ^ (x >> 31)


public function ulong_value(value: ulong) -> ulong:
    return mix_ulong(value)


public function ulong_equal(left: ulong, right: ulong) -> bool:
    return left == right


public function ptr_uint_value(value: ptr_uint) -> ulong:
    return mix_ulong(ulong<-value)


public function ptr_uint_equal(left: ptr_uint, right: ptr_uint) -> bool:
    return left == right


public function int_value(value: int) -> ulong:
    return mix_ulong(ulong<-value)


public function int_equal(left: int, right: int) -> bool:
    return left == right


public function str_value(text: str) -> ulong:
    var hash = ulong<-14695981039346656037
    var index: ptr_uint = 0
    while index < text.len:
        hash = unsafe: hash ^ ulong<-ubyte<-read(text.data + index)
        hash = hash * ulong<-1099511628211
        index += 1

    return hash


public function str_equal(left: str, right: str) -> bool:
    if left.len != right.len:
        return false

    var index: ptr_uint = 0
    while index < left.len:
        unsafe:
            if read(left.data + index) != read(right.data + index):
                return false
        index += 1

    return true
