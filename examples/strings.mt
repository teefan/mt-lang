# module demo.strings

import std.stdio as stdio

function main() -> int:
    #
    # ── plain strings ──
    #

    let plain = "hello world"
    stdio.print("plain:   %s\n", plain)

    #
    # ── escape sequences ──
    #

    let escaped = "line1\nline2\ttabbed\\ quote \" end"
    stdio.print("escaped: %s\n", escaped)

    #
    # ── adjacent (multiline concat) strings ──
    #

    let adjacent = "hello "
        "from multiple "
        "indented lines"
    stdio.print("adjacent: %s\n", adjacent)

    #
    # ── C strings (null-terminated) ──
    #

    let my_cstr = c"null-terminated"
    stdio.print("cstr:    %s\n", my_cstr)

    #
    # ── format strings f"..." ──
    #

    var name = "MilkTea"
    var count = 42
    let greeting = f"format:  hello #{name}, count = #{count}"
    stdio.print("%s\n", greeting)

    #
    # ── format specifiers ──
    #

    var value = 255
    var pi = 3.14159
    let hex_lo = f"hex lower: #{value:x}"
    let hex_up = f"hex upper: #{value:X}"
    let oct_lo = f"oct lower: #{value:o}"
    let oct_up = f"oct upper: #{value:O}"
    let bin_lo = f"bin lower: #{value:b}"
    let bin_up = f"bin upper: #{value:B}"
    let pi_str = f"pi: #{pi:.2}"
    stdio.print("%s\n", hex_lo)
    stdio.print("%s\n", hex_up)
    stdio.print("%s\n", oct_lo)
    stdio.print("%s\n", oct_up)
    stdio.print("%s\n", bin_lo)
    stdio.print("%s\n", bin_up)
    stdio.print("%s\n", pi_str)

    #
    # ── nested expressions in interpolation ──
    #

    let calc = f"calc:    #{count * 2 + 1:b}"
    stdio.print("%s\n", calc)

    #
    # ── heredoc <<-TAG ──
    #

    let heredoc = <<-MSG
        This is a heredoc.
        Leading whitespace is stripped.

            Indented content preserves
            relative indentation.

        Escape \n works inside heredocs.
    MSG
    stdio.print("heredoc:\n%s\n", heredoc)

    #
    # ── C heredoc c<<-TAG ──
    #

    let c_heredoc = c<<-CSTR
        This is a C heredoc.
        Produces null-terminated string.
    CSTR
    stdio.print("c heredoc: %s\n", c_heredoc)

    #
    # ── format heredoc f<<-TAG ──
    #

    var port = 8080
    var host = "localhost"
    let html = f<<-HTML
        <!DOCTYPE html>
        <html>
        <head><title>#{name}</title></head>
        <body>
            <h1>Welcome to #{name}</h1>
            <p>Serving on #{host}:#{port}</p>
            <p>Hex port: #{port:x}</p>
        </body>
        </html>
    HTML
    stdio.print("%s\n", html)

    #
    # ── f-string in a function call argument ──
    #

    let inline_msg = f"inline f-string in call: #{name}"
    stdio.print("%s\n", inline_msg)

    return 0
