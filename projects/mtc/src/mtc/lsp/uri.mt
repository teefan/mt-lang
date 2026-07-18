## URI helpers for the LSP — percent-decode file:// URIs into local paths.

import std.str
import std.string as string


## Decode a percent-encoded hex byte pair (e.g. "3A" → 58 / ':').  Returns
## 0 for invalid input.
function decode_hex_pair(text: str, index: ptr_uint) -> ubyte:
    if index + 1 >= text.len:
        return 0
    var value: ubyte = 0
    var i = index
    while i <= index + 1:
        let b = text.byte_at(i)
        if b >= '0' and b <= '9':
            value = value * 16 + (b - '0')
        else if b >= 'A' and b <= 'F':
            value = value * 16 + (b - 'A' + 10)
        else if b >= 'a' and b <= 'f':
            value = value * 16 + (b - 'a' + 10)
        else:
            return 0
        i += 1
    return value


## Convert a file:// URI to a local file path.  Strips the "file://" prefix
## and percent-decodes the remainder.  Returns none for non-file URIs or
## invalid encoding.
public function file_uri_to_path(uri: str) -> Option[string.String]:
    # Strip "file://" prefix.
    let prefix = "file://"
    if not uri.starts_with(prefix):
        return Option[string.String].none

    var pos = prefix.len

    var result = string.String.with_capacity(uri.len)
    while pos < uri.len:
        let b = uri.byte_at(pos)
        if b == '%':
            let decoded = decode_hex_pair(uri, pos + 1)
            if decoded == 0 and uri.byte_at(pos + 1) == '%':
                result.push_byte(37)
                pos += 3
            else:
                result.push_byte(decoded)
                pos += 3
        else:
            result.push_byte(b)
            pos += 1
    return Option[string.String].some(value = result)
