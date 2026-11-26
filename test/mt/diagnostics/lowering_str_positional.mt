# expect-error: str construction requires named fields
function main() -> int:
    var a = array[ubyte, 2](65, 66)
    let s = unsafe: str(ptr_of(a[0]), 2)
    return 0
