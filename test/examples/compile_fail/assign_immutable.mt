# A compile-fail fixture for `mtc test`.
#
# `mtc test` runs this file through the compiler and passes iff it is rejected
# with a diagnostic containing the `# expect-error:` substring below.
# This file is intentionally NOT valid Milk Tea and is excluded from normal builds.
#
# expect-error: cannot assign to immutable
function main() -> int:
    let x = 1
    x = 2
    return 0
