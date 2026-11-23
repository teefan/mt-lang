# expect-error: if condition must be bool, got int?
function main() -> int:
    let value: int? = null
    if value:
        return 1
    return 0
