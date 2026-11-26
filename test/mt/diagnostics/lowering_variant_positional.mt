# expect-error: variant arm construction requires named fields
variant Token:
    ident(text: str)
    eof

function main() -> int:
    let token = Token.ident("x")
    return 0
