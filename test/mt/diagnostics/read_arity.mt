# expect-error: read expects 1 argument, got 0
function main() -> int:
    unsafe:
        return read()
