module test.fixtures.language_fixture.types

public struct Counter:
    total: int

methods Counter:
    public static function zero() -> Counter:
        return Counter(total = 0)

    public editable function bump(step: int) -> void:
        this.total += step
