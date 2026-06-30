import std.str as text
import std.stdio as stdio


public function print_quoted_str(s: str) -> void:
    stdio.print_char('\"')
    var k: ptr_uint = 0
    while k < s.len:
        let b = s.byte_at(k)
        if b == '\n':
            stdio.print_char('\\')
            stdio.print_char('n')
        else if b == '\r':
            stdio.print_char('\\')
            stdio.print_char('r')
        else if b == '\t':
            stdio.print_char('\\')
            stdio.print_char('t')
        else if b == '\\':
            stdio.print_char('\\')
            stdio.print_char('\\')
        else if b == '\"':
            stdio.print_char('\\')
            stdio.print_char('\"')
        else:
            stdio.print_char(b)
        k += 1
    stdio.print_char('\"')


public function print_str(s: str) -> void:
    var k: ptr_uint = 0
    while k < s.len:
        stdio.print_char(s.byte_at(k))
        k += 1 
