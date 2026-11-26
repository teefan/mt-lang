# expect-error: unknown event method
event tick[4]

function main() -> int:
    tick.foo()
    return 0
