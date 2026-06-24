# In-language tests for the `pass` statement (migrated from
# test/std/std_pass_test.rb, run by `mtc test`).

import std.testing as t

@[test]
function test_pass_statements_are_no_ops() -> t.Check:
    defer:
        pass

    if true:
        pass
    else:
        return t.fail("if-true branch was skipped")

    while false:
        pass

    match 2:
        1:
            return t.fail("match selected 1")
        2:
            pass
        _:
            return t.fail("match selected wildcard")

    return t.ok()
