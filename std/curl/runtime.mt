import std.bytes as bytes
import std.curl as curl
import std.c.curl as c
import std.mem.arena as arena
import std.mem.heap as heap
import std.str as text
import std.vec as vec

const CURLE_OK_CODE: int = 0
const CURLE_FAILED_INIT_CODE: int = 2
const CURLE_URL_MALFORMAT_CODE: int = 3

foreign function easy_setopt_writedata(curl_handle: ptr[c.CURL], user_data: ptr[void]) -> c.CURLcode = c.curl_easy_setopt(curl_handle, c.CURLoption<-10001, user_data)
foreign function easy_setopt_url(curl_handle: ptr[c.CURL], url: cstr) -> c.CURLcode = c.curl_easy_setopt(curl_handle, c.CURLoption<-10002, url)
foreign function easy_setopt_writefunction(curl_handle: ptr[c.CURL], write_callback: c.curl_write_callback) -> c.CURLcode = c.curl_easy_setopt(curl_handle, c.CURLoption<-20011, write_callback)
foreign function easy_setopt_followlocation(curl_handle: ptr[c.CURL], follow: ptr_int) -> c.CURLcode = c.curl_easy_setopt(curl_handle, c.CURLoption<-52, follow)


function write_response_chunk(data: ptr[char], size: ptr_uint, count: ptr_uint, user_data: ptr[void]) -> ptr_uint:
    if size != 0 and count > heap.ptr_uint_max / size:
        return 0

    let total = size * count
    if total == 0:
        return 0

    unsafe:
        let buffer = ptr[vec.Vec[ubyte]]<-user_data
        let chunk = span[ubyte](data = ptr[ubyte]<-data, len = total)
        read(buffer).append_span(chunk)

    return total


public function code_message(code: curl.Code) -> str:
    return text.cstr_as_str(curl.easy_strerror(code))


public function get_bytes(url: str) -> Result[bytes.Bytes, curl.Code]:
    if url.len == heap.ptr_uint_max:
        return Result[bytes.Bytes, curl.Code].failure(error= curl.Code<-CURLE_URL_MALFORMAT_CODE)

    var scratch = arena.create(url.len + 1)
    defer scratch.release()

    let url_cstr = scratch.to_cstr(url)

    let global_status = curl.global_init(curl.CURL_GLOBAL_NOTHING)
    if int<-global_status != CURLE_OK_CODE:
        return Result[bytes.Bytes, curl.Code].failure(error= global_status)
    defer curl.global_cleanup()

    let handle = curl.easy_init() else:
        return Result[bytes.Bytes, curl.Code].failure(error= curl.Code<-CURLE_FAILED_INIT_CODE)
    defer curl.easy_cleanup(handle)

    var body = vec.Vec[ubyte].create()
    defer body.release()

    let write_function_status = easy_setopt_writefunction(handle, write_response_chunk)
    if int<-write_function_status != CURLE_OK_CODE:
        return Result[bytes.Bytes, curl.Code].failure(error= write_function_status)

    let write_data_status = easy_setopt_writedata(handle, unsafe: ptr[void]<-ptr_of(body))
    if int<-write_data_status != CURLE_OK_CODE:
        return Result[bytes.Bytes, curl.Code].failure(error= write_data_status)

    let url_status = easy_setopt_url(handle, url_cstr)
    if int<-url_status != CURLE_OK_CODE:
        return Result[bytes.Bytes, curl.Code].failure(error= url_status)

    let follow_status = easy_setopt_followlocation(handle, 1)
    if int<-follow_status != CURLE_OK_CODE:
        return Result[bytes.Bytes, curl.Code].failure(error= follow_status)

    let perform_status = curl.easy_perform(handle)
    if int<-perform_status != CURLE_OK_CODE:
        return Result[bytes.Bytes, curl.Code].failure(error= perform_status)

    return Result[bytes.Bytes, curl.Code].success(value= bytes.Bytes.copy(body.as_span()))
