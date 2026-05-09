module examples.language_standard.async_showcase

import std.async as tasks


function bias() -> int:
    return 2


public async function accumulate(values: span[int]) -> int:
    var total = 0
    for value in values:
        if value < 0:
            continue
        let extra = await tasks.work[int](bias)
        total += value + extra
    return total
