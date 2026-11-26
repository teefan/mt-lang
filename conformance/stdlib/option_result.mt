# Spec: README.md §11 Built-In Callable Surface
function main() -> int:
    let o: Option[int] = Option[int].some(value = 4)
    match o:
        Option.some as some:
            if some.value != 4:
                return 1
        Option.none:
            return 1
    let r: Result[int, str] = Result[int, str].success(value = 2)
    match r:
        Result.success as success:
            if success.value != 2:
                return 1
        Result.failure:
            return 1
    return 0
