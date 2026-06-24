# In-language tests for std.errno (migrated from
# test/std/std_errno_test.rb, run by `mtc test`).

import std.testing as t
import std.errno as errno

@[test]
function test_errno_helpers() -> t.Check:
    errno.clear()
    t.expect(errno.current() == errno.NONE, "current == NONE after clear")?

    errno.set_current(errno.ENOENT)
    t.expect(errno.current() == errno.ENOENT, "current == ENOENT")?
    t.expect(errno.message(errno.ENOENT) != null, "ENOENT message non-null")?
    t.expect(errno.current_message() != null, "current_message non-null")?

    errno.set_current(errno.EINVAL)
    t.expect(errno.current() == errno.EINVAL, "current == EINVAL")?
    t.expect(errno.message(errno.EPERM) != null, "EPERM message non-null")?

    errno.clear()
    return t.expect(errno.current() == errno.NONE, "current == NONE after second clear")
