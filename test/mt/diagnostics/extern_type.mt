# expect-error: argument s to puts expects cstr, got int
external function puts(s: cstr) -> int

function main() -> int:
    return puts(1)
