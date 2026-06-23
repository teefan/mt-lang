struct Counter:
    value: int

extending Counter:
    function read() -> int:
        return this.value

function main() -> int:
    var c: Counter = Counter(value = 42)
    return c.read()
