module std.span


pub def from_ptr[T](data: ptr[T], len: ptr_uint) -> span[T]:
    return span[T](data = data, len = len)


pub def from_nullable_ptr[T](data: ptr[T]?, len: ptr_uint) -> span[T]:
    if data == null and len != 0:
        panic(c"span.from_nullable_ptr requires non-null data when len > 0")

    unsafe:
        return span[T](data = ptr[T]<-data, len = len)


pub def empty[T]() -> span[T]:
    return zero[span[T]]
