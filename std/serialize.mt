## Raw struct pack/unpack for trivially-copyable (POD) layouts.  A struct must
## opt in with `@[serializable]`; a non-opted-in type emits a C static assertion
## when the specialized function is built.  Padding is copied, so prefer
## `@[packed]` for wire or on-disk layouts.

import std.binary as bin
import std.bytes as bytes
import std.string as string


## Opt-in marker for raw struct serialization.  The marker promises that the
## struct (and every nested field) is POD/trivially-copyable and contains no
## pointers, spans, strings, or owned containers.
public attribute[struct] serializable()


## Reject a raw pack/unpack target that has not opted in.  `has_attribute` is
## resolved at compile time; the false branch emits a C `_Static_assert` in the
## specialized function, so `mtc build`/`run` fails before any bytes move.
function require_serializable[T]() -> void:
    inline if not has_attribute(T, serializable):
        static_assert(false, "serialize.pack requires @[serializable] on T")


function raw_unpack_error(message: str) -> bin.Error:
    return bin.Error(code = -1, message = string.String.from_str(message))


public function pack[T](v: ref[T]) -> bytes.Bytes:
    require_serializable[T]()
    let total = size_of(T)
    var w = bin.Writer.with_capacity(total)
    var src = unsafe: ptr[ubyte]<-ptr_of(v)
    var i: ptr_uint = 0
    while i < total:
        w.write_ubyte(unsafe: read(src + i))
        i += 1
    return w.finish()


public function unpack[T](source: span[ubyte]) -> Result[T, bin.Error]:
    require_serializable[T]()
    let total = size_of(T)
    if source.len < total:
        return Result[T, bin.Error].failure(
            error = raw_unpack_error("source too short for target type")
        )

    var result = zero[T]
    var dest = unsafe: ptr[ubyte]<-ptr_of(result)
    var i: ptr_uint = 0
    while i < total:
        unsafe: read(dest + i) = source[i]
        i += 1
    return Result[T, bin.Error].success(value = result)


extending bin.Writer:
    public editable function pack[T](v: ref[T]) -> void:
        require_serializable[T]()
        let total = size_of(T)
        var src = unsafe: ptr[ubyte]<-ptr_of(v)
        var i: ptr_uint = 0
        while i < total:
            this.write_ubyte(unsafe: read(src + i))
            i += 1


extending bin.Reader:
    public editable function unpack[T]() -> Result[T, bin.Error]:
        require_serializable[T]()
        let total = size_of(T)
        match this.read_bytes(total):
            Result.failure as p:
                return Result[T, bin.Error].failure(error = p.error)
            Result.success as bp:
                var raw_bytes = bp.value
                defer: raw_bytes.release()

                let src_ptr = raw_bytes.data else:
                    return Result[T, bin.Error].failure(
                        error = raw_unpack_error("reader returned empty data")
                    )

                var result = zero[T]
                var dest = unsafe: ptr[ubyte]<-ptr_of(result)
                var i: ptr_uint = 0
                while i < total:
                    unsafe: read(dest + i) = read(src_ptr + i)
                    i += 1
                return Result[T, bin.Error].success(value = result)
