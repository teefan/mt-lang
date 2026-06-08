import std.bytes as bytes
import std.mem.heap as heap
import std.str as text
import std.string as string

const BASE64_ALPHABET: str = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
const BASE64_URL_ALPHABET: str = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
const BASE64_PAD: ubyte = 61


function lookup(value: ubyte) -> Option[ubyte]:
    if value >= 65 and value <= 90:
        return Option[ubyte].some(value = value - 65)

    if value >= 97 and value <= 122:
        return Option[ubyte].some(value = value - 71)

    if value >= 48 and value <= 57:
        return Option[ubyte].some(value = value + 4)

    if value == 43 or value == 45:
        return Option[ubyte].some(value = 62)

    if value == 47 or value == 95:
        return Option[ubyte].some(value = 63)

    return Option[ubyte].none


function encoded_len(input_len: ptr_uint) -> ptr_uint:
    var padded_len = input_len
    let remainder = padded_len % 3
    if remainder != 0:
        padded_len += 3 - remainder

    return (padded_len / 3) * 4


function decoded_len(input_len: ptr_uint) -> ptr_uint:
    if input_len == 0:
        return 0

    return (input_len / 4) * 3


function encode_impl(input: span[ubyte], alphabet: str, use_padding: bool) -> string.String:
    if input.len == 0:
        return string.String.create()

    let output_len = encoded_len(input.len)
    var output = string.String.with_capacity(output_len)

    var index: ptr_uint = 0
    while index < input.len:
        var triple: array[ubyte, 3]
        var group_len: ubyte = 0

        triple[0] = unsafe: read(input.data + index)
        group_len += 1
        index += 1

        if index < input.len:
            triple[1] = unsafe: read(input.data + index)
            group_len += 1
            index += 1
        else:
            triple[1] = 0

        if index < input.len:
            triple[2] = unsafe: read(input.data + index)
            group_len += 1
            index += 1
        else:
            triple[2] = 0

        let combined = (ulong<-triple[0] << 16) | (ulong<-triple[1] << 8) | ulong<-triple[2]

        let char0 = alphabet.byte_at(ptr_uint<-( (combined >> 18) & 0x3F) )
        let char1 = alphabet.byte_at(ptr_uint<-( (combined >> 12) & 0x3F) )
        output.push_byte(char0)
        output.push_byte(char1)

        if group_len >= 2:
            let char2 = alphabet.byte_at(ptr_uint<-( (combined >> 6) & 0x3F) )
            output.push_byte(char2)
        else if use_padding:
            output.push_byte(BASE64_PAD)

        if group_len >= 3:
            let char3 = alphabet.byte_at(ptr_uint<-(combined & 0x3F))
            output.push_byte(char3)
        else if use_padding:
            output.push_byte(BASE64_PAD)

    return output


public function encode(input: span[ubyte]) -> string.String:
    return encode_impl(input, BASE64_ALPHABET, true)


public function encode_urlsafe(input: span[ubyte]) -> string.String:
    return encode_impl(input, BASE64_URL_ALPHABET, false)


public struct Error:
    message: string.String


function error_message(message: str) -> Error:
    return Error(message = string.String.from_str(message))


public function decode(text_value: str) -> Result[bytes.Bytes, Error]:
    if text_value.len == 0:
        return Result[bytes.Bytes, Error].success(value = bytes.Bytes.empty())

    var effective_len = text_value.len
    while effective_len > 0 and text_value.byte_at(effective_len - 1) == BASE64_PAD:
        effective_len -= 1

    if effective_len == 0:
        return Result[bytes.Bytes, Error].success(value = bytes.Bytes.empty())

    let remainder = effective_len % 4
    if remainder == 1:
        return Result[bytes.Bytes, Error].failure(error = error_message("base64: invalid input length"))

    var output_len = (effective_len / 4) * 3
    if remainder != 0:
        output_len = output_len + remainder - 1

    let output = heap.must_alloc[ubyte](output_len)
    var out_index: ptr_uint = 0
    var index: ptr_uint = 0

    while index < effective_len:
        let c0 = text_value.byte_at(index)
        index += 1
        let raw0_opt = lookup(c0) else:
            heap.release(output)
            return Result[bytes.Bytes, Error].failure(error = error_message("base64: invalid character"))
        let raw0 = raw0_opt

        var raw1: ubyte = 0
        if index < effective_len:
            let c1 = text_value.byte_at(index)
            index += 1
            let raw1_opt = lookup(c1) else:
                heap.release(output)
                return Result[bytes.Bytes, Error].failure(error = error_message("base64: invalid character"))
            raw1 = raw1_opt

        var raw2: ubyte = 0
        if index < effective_len:
            let c2 = text_value.byte_at(index)
            index += 1
            let raw2_opt = lookup(c2) else:
                heap.release(output)
                return Result[bytes.Bytes, Error].failure(error = error_message("base64: invalid character"))
            raw2 = raw2_opt

        var raw3: ubyte = 0
        if index < effective_len:
            let c3 = text_value.byte_at(index)
            index += 1
            let raw3_opt = lookup(c3) else:
                heap.release(output)
                return Result[bytes.Bytes, Error].failure(error = error_message("base64: invalid character"))
            raw3 = raw3_opt

        let combined = (ulong<-raw0 << 18) | (ulong<-raw1 << 12) | (ulong<-raw2 << 6) | ulong<-raw3

        unsafe:
            read(output + out_index) = ubyte<-( (combined >> 16) & 0xFF)
        out_index += 1

        if out_index < output_len:
            unsafe:
                read(output + out_index) = ubyte<-( (combined >> 8) & 0xFF)
            out_index += 1

        if out_index < output_len:
            unsafe:
                read(output + out_index) = ubyte<-(combined & 0xFF)
            out_index += 1

    return Result[bytes.Bytes, Error].success(value = bytes.Bytes(data = output, len = output_len))


extending Error:
    public editable function release() -> void:
        this.message.release()
