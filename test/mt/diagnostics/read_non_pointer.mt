# expect-error: read expects ref[...] or ptr[...], got int
function main() -> int:
    unsafe:
        return read(1)
