# expect-error: static_assert condition must be bool, got int
static_assert(1, "condition must be bool")

function main() -> int:
    return 0
