function classify(v: int) -> int:
    match v:
        0:
            return 0
        1 | 2 | 3:
            return 1
        4 | 5:
            return 2
        _:
            return 9

function main() -> int:
    return classify(3)
