external

link "ssl"
link "crypto"
include "crypto_support.h"

const SHA256_DIGEST_LENGTH: ptr_uint = 32

external function mt_sha256(data: ptr[ubyte]?, data_len: ptr_uint, out_digest: ptr[ubyte]) -> int
external function mt_hmac_sha256(key: ptr[ubyte]?, key_len: ptr_uint, data: ptr[ubyte]?, data_len: ptr_uint, out_digest: ptr[ubyte]) -> int
external function mt_random_bytes(buffer: ptr[ubyte], count: ptr_uint) -> int
