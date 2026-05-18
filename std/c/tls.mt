external

link "ssl"
link "crypto"
include "tls_support.h"


struct mt_tls_bytes = c"mt_tls_bytes":
    data: ptr[ubyte]?
    len: ptr_uint


struct mt_tls_error = c"mt_tls_error":
    code: int
    message_data: ptr[char]?
    message_len: ptr_uint


external function mt_tls_exchange(host: cstr, port: int, request_data: ptr[ubyte]?, request_len: ptr_uint, out out_response: mt_tls_bytes, out out_error: mt_tls_error) -> int
