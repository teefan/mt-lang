# expect-error: while condition must be bool, got int
function main() -> int:
    var i = 0
    while i:
        i += 1
    return i
