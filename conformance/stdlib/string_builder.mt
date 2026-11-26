# Spec: README.md §12 Strings, Text, And Builders

import std.string as string

function main() -> int:
    var text = string.String.create()
    defer: text.release()
    text.append("ab")
    text.append("cd")
    if text.as_str() != "abcd":
        return 1
    return 0
