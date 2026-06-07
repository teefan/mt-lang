import std.bytes as bytes
import std.curl as curl
import std.c.curl as c
import std.mem.arena as arena
import std.mem.heap as heap
import std.str as text
import std.string as string
import std.vec as vec


const CURLE_OK_CODE: int = 0
const CURLE_FAILED_INIT_CODE: int = 2
const CURLE_URL_MALFORMAT_CODE: int = 3


foreign function easy_setopt_writedata(curl_handle: ptr[c.CURL], user_data: ptr[void]) -> c.CURLcode = c.curl_easy_setopt(curl_handle, c.CURLoption<-10001, user_data)
foreign function easy_setopt_url(curl_handle: ptr[c.CURL], url: cstr) -> c.CURLcode = c.curl_easy_setopt(curl_handle, c.CURLoption<-10002, url)
foreign function easy_setopt_writefunction(curl_handle: ptr[c.CURL], write_callback: c.curl_write_callback) -> c.CURLcode = c.curl_easy_setopt(curl_handle, c.CURLoption<-20011, write_callback)
foreign function easy_setopt_followlocation(curl_handle: ptr[c.CURL], follow: ptr_int) -> c.CURLcode = c.curl_easy_setopt(curl_handle, c.CURLoption<-52, follow)
foreign function easy_setopt_timeout(curl_handle: ptr[c.CURL], timeout: int) -> c.CURLcode = c.curl_easy_setopt(curl_handle, c.CURLoption<-13, timeout)
foreign function easy_setopt_postfields(curl_handle: ptr[c.CURL], body: cstr) -> c.CURLcode = c.curl_easy_setopt(curl_handle, c.CURLoption<-10015, body)
foreign function easy_setopt_customrequest(curl_handle: ptr[c.CURL], method: cstr) -> c.CURLcode = c.curl_easy_setopt(curl_handle, c.CURLoption<-10036, method)
foreign function easy_setopt_nobody(curl_handle: ptr[c.CURL]) -> c.CURLcode = c.curl_easy_setopt(curl_handle, c.CURLoption<-44, 1)
foreign function easy_getinfo_long(curl_handle: ptr[c.CURL], value: ptr[int]) -> c.CURLcode = c.curl_easy_getinfo(curl_handle, c.CURLINFO<-2097154, value)


public struct HttpError:
    code: curl.Code
    message: string.String

public struct HttpResponse:
    status_code: int
    body: bytes.Bytes


extending HttpError:
    public editable function release() -> void:
        this.message.release()


extending HttpResponse:
    public editable function release() -> void:
        this.body.release()

    public function body_as_str() -> Option[str]:
        return this.body.as_str()


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


function http_error(code: curl.Code) -> HttpError:
    let detail = text.cstr_as_str(curl.easy_strerror(code))
    return HttpError(code = code, message = string.String.from_str(detail))


public function get(url: str) -> Result[HttpResponse, HttpError]:
    return do_request("GET", url, Option[str].none, 0)


public function get_with_timeout(url: str, timeout_seconds: int) -> Result[HttpResponse, HttpError]:
    return do_request("GET", url, Option[str].none, timeout_seconds)


public function head(url: str) -> Result[HttpResponse, HttpError]:
    return do_request("HEAD", url, Option[str].none, 0)


public function head_with_timeout(url: str, timeout_seconds: int) -> Result[HttpResponse, HttpError]:
    return do_request("HEAD", url, Option[str].none, timeout_seconds)


public function delete(url: str) -> Result[HttpResponse, HttpError]:
    return do_request("DELETE", url, Option[str].none, 0)


public function delete_with_timeout(url: str, timeout_seconds: int) -> Result[HttpResponse, HttpError]:
    return do_request("DELETE", url, Option[str].none, timeout_seconds)


public function options(url: str) -> Result[HttpResponse, HttpError]:
    return do_request("OPTIONS", url, Option[str].none, 0)


public function options_with_timeout(url: str, timeout_seconds: int) -> Result[HttpResponse, HttpError]:
    return do_request("OPTIONS", url, Option[str].none, timeout_seconds)


public function post(url: str, body: str) -> Result[HttpResponse, HttpError]:
    return do_request("POST", url, Option[str].some(value = body), 0)


public function post_with_timeout(
    url: str,
    body: str,
    timeout_seconds: int
) -> Result[HttpResponse, HttpError]:
    return do_request("POST", url, Option[str].some(value = body), timeout_seconds)


public function put(url: str, body: str) -> Result[HttpResponse, HttpError]:
    return do_request("PUT", url, Option[str].some(value = body), 0)


public function put_with_timeout(
    url: str,
    body: str,
    timeout_seconds: int
) -> Result[HttpResponse, HttpError]:
    return do_request("PUT", url, Option[str].some(value = body), timeout_seconds)


public function patch(url: str, body: str) -> Result[HttpResponse, HttpError]:
    return do_request("PATCH", url, Option[str].some(value = body), 0)


public function patch_with_timeout(
    url: str,
    body: str,
    timeout_seconds: int
) -> Result[HttpResponse, HttpError]:
    return do_request("PATCH", url, Option[str].some(value = body), timeout_seconds)


public function request(
    method: str,
    url: str,
    body: Option[str],
    timeout: int
) -> Result[HttpResponse, HttpError]:
    return do_request(method, url, body, timeout)


function do_request(
    method: str,
    url: str,
    body: Option[str],
    timeout: int
) -> Result[HttpResponse, HttpError]:
    let global_status = curl.global_init(curl.CURL_GLOBAL_NOTHING)
    if int<-global_status != CURLE_OK_CODE:
        return Result[HttpResponse, HttpError].failure(error = http_error(global_status))
    defer curl.global_cleanup()

    let handle = curl.easy_init() else:
        return Result[HttpResponse, HttpError].failure(
            error = HttpError(
                code = curl.Code<-CURLE_FAILED_INIT_CODE,
                message = string.String.from_str("curl_easy_init failed")
            )
        )
    defer curl.easy_cleanup(handle)

    var buffer = vec.Vec[ubyte].create()
    defer buffer.release()

    let _wfn = easy_setopt_writefunction(handle, write_response_chunk)
    let _wdata = easy_setopt_writedata(handle, unsafe: ptr[void]<-ptr_of(buffer))

    if url.len == heap.ptr_uint_max:
        return Result[HttpResponse, HttpError].failure(
            error = HttpError(
                code = curl.Code<-CURLE_URL_MALFORMAT_CODE,
                message = string.String.from_str("url too long")
            )
        )

    var scratch = arena.create(url.len + 1)
    defer scratch.release()

    let url_cstr = scratch.to_cstr(url)
    let _url = easy_setopt_url(handle, url_cstr)
    let _follow = easy_setopt_followlocation(handle, 1)

    if timeout > 0:
        let _timeout = easy_setopt_timeout(handle, timeout)

    match body:
        Option.none:
            pass
        Option.some as body_content:
            var body_scratch = arena.create(body_content.value.len + 1)
            defer body_scratch.release()
            let _pf = easy_setopt_postfields(handle, body_scratch.to_cstr(body_content.value))

    if method.len > 0 and not method.starts_with("GET"):
        var method_scratch = arena.create(method.len + 1)
        defer method_scratch.release()
        let _method = easy_setopt_customrequest(handle, method_scratch.to_cstr(method))

    if method.starts_with("HEAD"):
        let _nobody = easy_setopt_nobody(handle)

    let code = curl.easy_perform(handle)
    if int<-code != CURLE_OK_CODE:
        return Result[HttpResponse, HttpError].failure(error = http_error(code))

    var status: int = 0
    let _info = easy_getinfo_long(handle, ptr_of(status))

    let response_body = bytes.Bytes.copy(buffer.as_span())
    return Result[HttpResponse, HttpError].success(
        value = HttpResponse(status_code = status, body = response_body)
    )
