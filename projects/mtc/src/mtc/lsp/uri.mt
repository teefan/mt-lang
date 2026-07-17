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
        if b >= 48 and b <= 57:
            value = value * 16 + (b - 48)
        else if b >= 65 and b <= 70:
            value = value * 16 + (b - 65 + 10)
        else if b >= 97 and b <= 102:
            value = value * 16 + (b - 97 + 10)
        else:
            return 0
        i += 1
    return value


## Convert a file:// URI to a local file path.  Strips the "file://" prefix
## and percent-decodes the remainder.  Returns none for non-file URIs or
## invalid encoding.
public function file_uri_to_path(uri: str) -> Option[string.String]:
    var text_view: str = uri
    # Strip "file://" prefix.
    let prefix = "file://"
    if not text_view.starts_with(prefix):
        return Option[string.String].none

    var pos = prefix.len

    # On Windows, file:///C:/... — the third slash is a host separator.
    # Skip it when present.
    if text_view.len > pos and text_view.byte_at(pos) == 47:
        pos += 1

    var result = string.String.with_capacity(text_view.len)
    while pos < text_view.len:
        let b = text_view.byte_at(pos)
        if b == 37:
            let decoded = decode_hex_pair(text_view, pos + 1)
            if decoded == 0 and text_view.byte_at(pos + 1) == 37:
                result.push_byte(37)
                pos += 3
            else:
                result.push_byte(decoded)
                pos += 3
        else:
            result.push_byte(b)
            pos += 1
    return Option[string.String].some(value = result)
