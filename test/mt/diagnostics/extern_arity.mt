# expect-error: function puts expects 1 arguments, got 0
external function puts(s: cstr) -> int

function main() -> int:
    return puts()
