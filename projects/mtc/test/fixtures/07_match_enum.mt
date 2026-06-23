enum Kind: int
    none = 0
    first = 1
    second = 2

function classify(k: Kind) -> int:
    match k:
        Kind.none:
            return 0
        Kind.first:
            return 10
        Kind.second:
            return 20
        _:
            return 99

function main() -> int:
    return classify(Kind.second)
