# POC 004 — String and cstring literals, heredoc, format strings
# Tests: str literals, cstr literals, heredoc (<<-TAG), format strings (f"..."),
# string escapes (\n, \t, \\, \", \', \r), f<<-TAG format heredoc,
# adjacent string literal concatenation.
const GREETING: str    = "hello"
const C_HELLO: cstr     = c"hello from C"
const ESCAPED: str      = "line1\nline2\ttabbed\\backslash \"quote\" \'single\' \rreturn"

const PLAIN_HDOC: str = <<-MSG
    Hello world from heredoc.
MSG

const SHADER: cstr = c<<-GLSL
    #version 330
    void main() {}
GLSL

function main() -> int:
    let name = "world"
    let fmt = f"hello #{name}"
    let concat = "hello "
        "from "
        "indented lines"

    let fmt_heredoc = f<<-SQL
        SELECT * FROM items
        WHERE name = #{name}
    SQL

    let _f = fmt
    let _c = concat
    let _g = GREETING
    let _fh = fmt_heredoc
    return 0
