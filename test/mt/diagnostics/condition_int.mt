# expect-error: if condition must be bool, got int
function main() -> int:
    if 1:
        return 1
    return 0
