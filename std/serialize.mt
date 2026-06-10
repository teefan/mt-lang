import std.binary as bin
import std.bytes as bytes
import std.string as string


function raw_unpack_error(message: str) -> bin.Error:
    return bin.Error(code = -1, message = string.String.from_str(message))


public function pack[T](v: ref[T]) -> bytes.Bytes:
    let total = size_of(T)
    var w = bin.Writer.with_capacity(total)
    var src = unsafe: ptr[ubyte]<-ptr_of(v)
    var i: ptr_uint = 0
    while i < total:
        w.write_ubyte(unsafe: read(src + i))
        i += 1
    return w.finish()


public function unpack[T](source: span[ubyte]) -> Result[T, bin.Error]:
    let total = size_of(T)
    if source.len < total:
        return Result[T, bin.Error].failure(
            error = raw_unpack_error("source too short for target type")
        )

    var result = unsafe: zero[T]
    var dest = unsafe: ptr[ubyte]<-ptr_of(result)
    var i: ptr_uint = 0
    while i < total:
        unsafe: read(dest + i) = source[i]
        i += 1
    return Result[T, bin.Error].success(value = result)


extending bin.Writer:
    public editable function pack[T](v: ref[T]) -> void:
        let total = size_of(T)
        var src = unsafe: ptr[ubyte]<-ptr_of(v)
        var i: ptr_uint = 0
        while i < total:
            this.write_ubyte(unsafe: read(src + i))
            i += 1


extending bin.Reader:
    public editable function unpack[T]() -> Result[T, bin.Error]:
        let total = size_of(T)
        match this.read_bytes(total):
            Result.failure as p:
                return Result[T, bin.Error].failure(error = p.error)
            Result.success as bp:
                var raw_bytes = bp.value
                defer raw_bytes.release()

                let src_ptr = raw_bytes.data else:
                    return Result[T, bin.Error].failure(
                        error = raw_unpack_error("reader returned empty data")
                    )

                var result = unsafe: zero[T]
                var dest = unsafe: ptr[ubyte]<-ptr_of(result)
                var i: ptr_uint = 0
                while i < total:
                    unsafe: read(dest + i) = read(src_ptr + i)
                    i += 1
                return Result[T, bin.Error].success(value = result)
