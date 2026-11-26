# Spec: README.md §4 Variables And Guards

function main() -> int:
    let x: int? = null
    let value = x else:
        return 0
    return value
