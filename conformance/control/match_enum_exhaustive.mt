# Spec: docs/language-manual.md §4.2 Match

enum Color: int
    red = 0
    blue = 1

function main() -> int:
    let c = Color.red
    return match c:
        Color.red: 0
