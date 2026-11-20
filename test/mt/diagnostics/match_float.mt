# expect-error: match requires an enum, variant, or integer scrutinee, got float
function main() -> int:
    let x = 1.5
    match x:
        _:
            return 0
