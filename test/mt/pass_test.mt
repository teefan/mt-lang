# In-language tests for the `pass` statement (migrated from
# test/std/std_pass_test.rb, run by `mtc test`).


@[test]
function test_pass_statements_are_no_ops() -> void:
    defer:
        pass

    if true:
        pass
    else:
        expect(false, "if-true branch was skipped")

    while false:
        pass

    match 2:
        1:
            expect(false, "match selected 1")
        2:
            pass
        _:
            expect(false, "match selected wildcard")

