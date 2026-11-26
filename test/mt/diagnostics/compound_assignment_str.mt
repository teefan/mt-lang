# expect-error: str += is not supported
function main() -> int:
    var text = "a"
    text += "b"
    return 0
