public struct Counter:
    total: int

extending Counter:
    public static function zero() -> Counter:
        return Counter(total = 0)

    public mutable function bump(step: int) -> void:
        this.total += step
