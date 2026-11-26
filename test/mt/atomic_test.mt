# In-language tests for atomic[T].compare_exchange (run by `mtc test`).

@[test]
function test_atomic_compare_exchange_success_and_failure() -> void:
    var value: atomic[int]
    value.store(5)

    var expected: int = 5
    let succeeded = value.compare_exchange(ref_of(expected), 9)
    expect(succeeded, "compare_exchange succeeds on a matching expected value")
    expect_eq(value.load(), 9)

    expected = 4
    let failed = value.compare_exchange(ref_of(expected), 11)
    expect(not failed, "compare_exchange fails on a mismatched expected value")
    expect_eq(value.load(), 9)
    expect_eq(expected, 9)
