# POC 015 — Extending methods: extending blocks on structs with function,
# editable function, static function. Value and editable receivers.

struct Counter:
    value: int

extending Counter:
    function get() -> int:
        return this.value

    editable function increment(amount: int):
        this.value = this.value + amount

    static function zero() -> Counter:
        return Counter(value = 0)

function main() -> int:
    var c = Counter(value = 0)

    # value receiver
    let v = c.get()
    let _v = v

    # editable receiver
    c.increment(amount = 5)
    let v2 = c.get()
    let _v2 = v2

    # static function
    let z = Counter.zero()
    let _z = z

    return 0
