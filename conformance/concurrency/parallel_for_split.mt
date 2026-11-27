# Spec: docs/language-manual.md §4.3a Parallel For

function main() -> int:
    var values = array[int, 4](0, 0, 0, 0)
    parallel for i in 0..4:
        values[i] = i + 1
    var total = 0
    for value in values:
        total += value
    if total != 10:
        return 1
    return 0
