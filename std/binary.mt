import std.bytes as bytes
import std.str as text
import std.string as string
import std.vec as vec

public struct Error:
    code: int
    message: string.String

public struct Writer:
    buffer: vec.Vec[ubyte]

public struct Reader:
    data: span[ubyte]
    position: ptr_uint


function binary_error(code: int, message: str) -> Error:
    return Error(code = code, message = string.String.from_str(message))


function writer_append_byte(writer: ref[Writer], value: ubyte) -> void:
    writer.buffer.push(value)


function writer_append_span(writer: ref[Writer], data: span[ubyte]) -> void:
    writer.buffer.append_span(data)


extending Error:
    public editable function release() -> void:
        this.message.release()


extending Writer:
    public static function create() -> Writer:
        return Writer(buffer = vec.Vec[ubyte].create())


    public static function with_capacity(capacity: ptr_uint) -> Writer:
        return Writer(buffer = vec.Vec[ubyte].with_capacity(capacity))


    public editable function write_ubyte(value: ubyte) -> void:
        writer_append_byte(ref_of(this), value)


    public editable function write_ushort(value: ushort) -> void:
        writer_append_byte(ref_of(this), ubyte<-(value & 0xFF))
        writer_append_byte(ref_of(this), ubyte<-((value >> 8) & 0xFF))


    public editable function write_uint(value: uint) -> void:
        writer_append_byte(ref_of(this), ubyte<-(value & 0xFF))
        writer_append_byte(ref_of(this), ubyte<-((value >> 8) & 0xFF))
        writer_append_byte(ref_of(this), ubyte<-((value >> 16) & 0xFF))
        writer_append_byte(ref_of(this), ubyte<-((value >> 24) & 0xFF))


    public editable function write_ulong(value: ulong) -> void:
        writer_append_byte(ref_of(this), ubyte<-(value & 0xFF))
        writer_append_byte(ref_of(this), ubyte<-((value >> 8) & 0xFF))
        writer_append_byte(ref_of(this), ubyte<-((value >> 16) & 0xFF))
        writer_append_byte(ref_of(this), ubyte<-((value >> 24) & 0xFF))
        writer_append_byte(ref_of(this), ubyte<-((value >> 32) & 0xFF))
        writer_append_byte(ref_of(this), ubyte<-((value >> 40) & 0xFF))
        writer_append_byte(ref_of(this), ubyte<-((value >> 48) & 0xFF))
        writer_append_byte(ref_of(this), ubyte<-((value >> 56) & 0xFF))


    public editable function write_byte(value: byte) -> void:
        writer_append_byte(ref_of(this), ubyte<-value)


    public editable function write_short(value: short) -> void:
        this.write_ushort(ushort<-value)


    public editable function write_int(value: int) -> void:
        this.write_uint(uint<-value)


    public editable function write_long(value: long) -> void:
        this.write_ulong(ulong<-value)


    public editable function write_float(value: float) -> void:
        let bits = unsafe: reinterpret[uint](value)
        this.write_uint(bits)


    public editable function write_double(value: double) -> void:
        let bits = unsafe: reinterpret[ulong](value)
        this.write_ulong(bits)


    public editable function write_bool(value: bool) -> void:
        if value:
            writer_append_byte(ref_of(this), 1)
        else:
            writer_append_byte(ref_of(this), 0)


    public editable function write_bytes(data: span[ubyte]) -> void:
        writer_append_span(ref_of(this), data)


    public editable function write_str(value: str) -> void:
        this.write_uint(uint<-value.len)
        if value.len > 0:
            writer_append_span(ref_of(this), text.as_byte_span(value))


    public editable function write_uint_at(position: ptr_uint, value: uint) -> void:
        let buffer_span = this.buffer.as_span()
        if position + 4 > buffer_span.len:
            fatal(c"binary.write_u32_at position out of bounds")
        unsafe:
            read(buffer_span.data + position) = ubyte<-(value & 0xFF)
            read(buffer_span.data + position + 1) = ubyte<-((value >> 8) & 0xFF)
            read(buffer_span.data + position + 2) = ubyte<-((value >> 16) & 0xFF)
            read(buffer_span.data + position + 3) = ubyte<-((value >> 24) & 0xFF)


    public function len() -> ptr_uint:
        return this.buffer.len()


    public function as_span() -> span[ubyte]:
        return this.buffer.as_span()


    public editable function finish() -> bytes.Bytes:
        let result = bytes.Bytes.copy(this.buffer.as_span())
        this.buffer.release()
        return result


    public editable function reset() -> void:
        this.buffer.clear()


    public editable function release() -> void:
        this.buffer.release()


public function reader(data: span[ubyte]) -> Reader:
    return Reader(data = data, position = 0)


public function reader_from_bytes(data: bytes.Bytes) -> Reader:
    return Reader(data = data.as_span(), position = 0)


function reader_check_remaining(reader: ref[Reader], count: ptr_uint) -> Result[bool, Error]:
    if reader.position > reader.data.len:
        return Result[bool, Error].failure(error = binary_error(-1, "binary reader position overflow"))
    if reader.data.len - reader.position < count:
        return Result[bool, Error].failure(error = binary_error(-1, "binary reader unexpected end of buffer"))
    return Result[bool, Error].success(value = true)


function reader_read_byte(reader: ref[Reader]) -> Result[ubyte, Error]:
    reader_check_remaining(reader, 1)?
    let value = unsafe: read(reader.data.data + reader.position)
    reader.position += 1
    return Result[ubyte, Error].success(value = value)


extending Reader:
    public editable function read_ubyte() -> Result[ubyte, Error]:
        return reader_read_byte(ref_of(this))


    public editable function read_ushort() -> Result[ushort, Error]:
        reader_check_remaining(ref_of(this), 2)?
        let low = ushort<-unsafe: read(this.data.data + this.position)
        let high = ushort<-unsafe: read(this.data.data + this.position + 1)
        this.position += 2
        return Result[ushort, Error].success(value = (high << 8) | low)


    public editable function read_uint() -> Result[uint, Error]:
        reader_check_remaining(ref_of(this), 4)?
        var value: uint = 0
        unsafe:
            let b0 = uint<-read(this.data.data + this.position)
            let b1 = uint<-read(this.data.data + this.position + 1)
            let b2 = uint<-read(this.data.data + this.position + 2)
            let b3 = uint<-read(this.data.data + this.position + 3)
            value = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
        this.position += 4
        return Result[uint, Error].success(value = value)


    public editable function read_ulong() -> Result[ulong, Error]:
        reader_check_remaining(ref_of(this), 8)?
        var value: ulong = 0
        unsafe:
            let b0 = ulong<-read(this.data.data + this.position)
            let b1 = ulong<-read(this.data.data + this.position + 1)
            let b2 = ulong<-read(this.data.data + this.position + 2)
            let b3 = ulong<-read(this.data.data + this.position + 3)
            let b4 = ulong<-read(this.data.data + this.position + 4)
            let b5 = ulong<-read(this.data.data + this.position + 5)
            let b6 = ulong<-read(this.data.data + this.position + 6)
            let b7 = ulong<-read(this.data.data + this.position + 7)
            value = (
                b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
                | (b4 << 32) | (b5 << 40) | (b6 << 48) | (b7 << 56)
            )
        this.position += 8
        return Result[ulong, Error].success(value = value)


    public editable function read_byte() -> Result[byte, Error]:
        let value = this.read_ubyte()?
        return Result[byte, Error].success(value = byte<-value)


    public editable function read_short() -> Result[short, Error]:
        let value = this.read_ushort()?
        return Result[short, Error].success(value = short<-value)


    public editable function read_int() -> Result[int, Error]:
        let value = this.read_uint()?
        return Result[int, Error].success(value = int<-value)


    public editable function read_long() -> Result[long, Error]:
        let value = this.read_ulong()?
        return Result[long, Error].success(value = long<-value)


    public editable function read_float() -> Result[float, Error]:
        let value = this.read_uint()?
        return Result[float, Error].success(value = unsafe: reinterpret[float](value))


    public editable function read_double() -> Result[double, Error]:
        let value = this.read_ulong()?
        return Result[double, Error].success(value = unsafe: reinterpret[double](value))


    public editable function read_bool() -> Result[bool, Error]:
        let value = this.read_ubyte()?
        if value == 0:
            return Result[bool, Error].success(value = false)
        if value == 1:
            return Result[bool, Error].success(value = true)
        return Result[bool, Error].failure(error = binary_error(-2, "binary reader invalid bool value"))


    public editable function read_bytes(count: ptr_uint) -> Result[bytes.Bytes, Error]:
        if count == 0:
            return Result[bytes.Bytes, Error].success(value = bytes.Bytes.empty())

        reader_check_remaining(ref_of(this), count)?
        unsafe:
            let result = bytes.Bytes.copy(span[ubyte](
                data = this.data.data + this.position,
                len = count
            ))
            this.position += count
            return Result[bytes.Bytes, Error].success(value = result)


    public editable function read_span(count: ptr_uint) -> Result[span[ubyte], Error]:
        if count == 0:
            let empty = unsafe: span[ubyte](data = this.data.data, len = 0)
            return Result[span[ubyte], Error].success(value = empty)

        reader_check_remaining(ref_of(this), count)?
        unsafe:
            let result = span[ubyte](data = this.data.data + this.position, len = count)
            this.position += count
            return Result[span[ubyte], Error].success(value = result)


    public editable function read_str() -> Result[string.String, Error]:
        let length = ptr_uint<-this.read_uint()?
        if length == 0:
            return Result[string.String, Error].success(value = string.String.create())

        var data = this.read_bytes(length)?
        let str_opt = text.utf8_byte_span_as_str(data.as_span())
        match str_opt:
            Option.none:
                data.release()
                return Result[string.String, Error].failure(error = binary_error(
                    -2,
                    "binary reader invalid UTF-8 string"
                ))
            Option.some as str_payload:
                let result = string.String.from_str(str_payload.value)
                data.release()
                return Result[string.String, Error].success(value = result)


    public editable function skip(count: ptr_uint) -> Result[bool, Error]:
        reader_check_remaining(ref_of(this), count)?
        this.position += count
        return Result[bool, Error].success(value = true)


    public function remaining() -> ptr_uint:
        if this.position >= this.data.len:
            return 0
        return this.data.len - this.position


    public function has_more() -> bool:
        return this.position < this.data.len
