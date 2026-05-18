external

link "z"
include "zlib_support.h"


struct mt_zlib_bytes = c"mt_zlib_bytes":
    data: ptr[ubyte]?
    len: ptr_uint


struct mt_zlib_error = c"mt_zlib_error":
    code: int
    message_data: ptr[char]?
    message_len: ptr_uint


const MT_ZLIB_DEFAULT_COMPRESSION: int = -1
const MT_ZLIB_BEST_SPEED: int = 1
const MT_ZLIB_BEST_COMPRESSION: int = 9


external function mt_gzip_compress(data: ptr[ubyte]?, len: ptr_uint, level: int, out out_bytes: mt_zlib_bytes, out out_error: mt_zlib_error) -> int
external function mt_gzip_decompress(data: ptr[ubyte]?, len: ptr_uint, out out_bytes: mt_zlib_bytes, out out_error: mt_zlib_error) -> int
