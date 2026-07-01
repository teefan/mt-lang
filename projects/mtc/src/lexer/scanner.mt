import std.str

public function is_alpha(ch: ubyte) -> bool:
    return (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or ch == '_'


public function is_digit(ch: ubyte) -> bool:
    return ch >= '0' and ch <= '9'


public function is_alphanumeric(ch: ubyte) -> bool:
    return is_alpha(ch) or is_digit(ch)


public function is_hex_digit(ch: ubyte) -> bool:
    return is_digit(ch) or (ch >= 'A' and ch <= 'F') or (ch >= 'a' and ch <= 'f')


public function is_bin_digit(ch: ubyte) -> bool:
    return ch == '0' or ch == '1'


public function is_space(ch: ubyte) -> bool:
    return ch == ' ' or ch == '\t' or ch == '\r'


public function is_newline(ch: ubyte) -> bool:
    return ch == '\n'


public function is_identifier_continuation(ch: ubyte) -> bool:
    return is_alphanumeric(ch) or ch == '_'


public function scan_identifier_text(line: str, start: ptr_uint) -> str:
    var idx = start
    while idx < line.len and is_identifier_continuation(line.byte_at(idx)):
        idx += 1
    return line.slice(start, idx - start)
