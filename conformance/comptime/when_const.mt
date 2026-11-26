# Spec: docs/language-manual.md §4.7 When
const N: int = 3

function main() -> int:
    var values: array[int, N] = (1, 2, 3)
    when N:
        3:
            return 0
        else:
            return 1
