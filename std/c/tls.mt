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


opaque mt_tls_client = c"mt_tls_client"


external function mt_tls_client_create(host: cstr, fd: int, out out_client: ptr[mt_tls_client]?, out out_error: mt_tls_error) -> int
external function mt_tls_client_handshake(client: ptr[mt_tls_client], out out_error: mt_tls_error) -> int
external function mt_tls_client_write(client: ptr[mt_tls_client], data: ptr[ubyte]?, len: ptr_uint, out out_written: ptr_uint, out out_error: mt_tls_error) -> int
external function mt_tls_client_read(client: ptr[mt_tls_client], buffer: ptr[ubyte]?, capacity: ptr_uint, out out_read: ptr_uint, out out_error: mt_tls_error) -> int
external function mt_tls_client_shutdown(client: ptr[mt_tls_client], out out_error: mt_tls_error) -> int
external function mt_tls_client_release(client: ptr[mt_tls_client]?) -> void


external function mt_tls_exchange(host: cstr, port: int, request_data: ptr[ubyte]?, request_len: ptr_uint, out out_response: mt_tls_bytes, out out_error: mt_tls_error) -> int
