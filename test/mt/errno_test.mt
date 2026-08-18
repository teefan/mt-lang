# In-language tests for std.errno (migrated from
# test/std/std_errno_test.rb, run by `mtc test`).

import std.errno as errno

@[test]
function test_errno_helpers() -> void:
    errno.clear()
    expect(errno.current() == errno.NONE, "current == NONE after clear")

    errno.set_current(errno.ENOENT)
    expect(errno.current() == errno.ENOENT, "current == ENOENT")
    expect(errno.message(errno.ENOENT) != null, "ENOENT message non-null")
    expect(errno.current_message() != null, "current_message non-null")

    errno.set_current(errno.EINVAL)
    expect(errno.current() == errno.EINVAL, "current == EINVAL")
    expect(errno.message(errno.EPERM) != null, "EPERM message non-null")

    errno.clear()
    expect(errno.current() == errno.NONE, "current == NONE after second clear")
