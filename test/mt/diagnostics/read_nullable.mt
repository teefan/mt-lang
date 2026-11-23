# expect-error: read expects ref[...] or ptr[...], got ptr[int]?
function main() -> int:
    let value: ptr[int]? = null
    unsafe:
        return read(value)
