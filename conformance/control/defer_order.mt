# Spec: docs/language-manual.md §4.4 Defer

import std.stdio as stdio

function main() -> int:
    defer: stdio.print_line("first")
    defer: stdio.print_line("second")
    return 0
