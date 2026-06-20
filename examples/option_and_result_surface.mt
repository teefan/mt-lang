# examples/option_and_result_surface.mt
#
# Surface test for Option[T], Result[T, E], and Nullable (T?)
# covering construction, pattern matching, unwrapping, propagation,
# identity queries, combinators, and interop.
#
# Imported automatically via prelude — no explicit import needed.
# Combinators are provided by extending blocks in std/option.mt and std/result.mt.

# =========================================================================
# Construction
# =========================================================================

function construct_option() -> Option[int]:
    let named = Option[int].some(value = 42)
    let none  = Option[int].none
    return named

function construct_result() -> Result[int, int]:
    let ok  = Result[int, int].success(value = 42)
    let err = Result[int, int].failure(error = -1)
    return ok

# =========================================================================
# Identity queries (extending methods from std/option.mt, std/result.mt)
# =========================================================================

function query_option(opt: Option[int]) -> int:
    if opt.is_some():
        return 1
    if opt.is_none():
        return 0
    return 2

function query_result(res: Result[int, int]) -> int:
    if res.is_success():
        return 1
    if res.is_failure():
        return 0
    return 2

# =========================================================================
# Pattern matching (match)
# =========================================================================

function match_option(opt: Option[int]) -> int:
    match opt:
        Option.some as payload:
            return payload.value
        Option.none:
            return -1

function match_result(res: Result[int, int]) -> int:
    match res:
        Result.success as s:
            return s.value
        Result.failure as f:
            return f.error

# =========================================================================
# let-else unwrapping
# =========================================================================

function let_else_option(opt: Option[int]) -> int:
    let value = opt else:
        return -1
    return value

function let_else_result_with_error_binding(res: Result[int, int]) -> int:
    let value = res else as error:
        return error
    return value + 1

function var_else_option(maybe: Option[int]) -> int:
    var value = maybe else:
        return 7
    value = value * 2
    return value

function let_else_nullable(nv: int?) -> int:
    let val = nv else:
        return 0
    return val

# =========================================================================
# ? propagation
# =========================================================================

function propagate_option(opt: Option[int]) -> Option[int]:
    let value = opt?
    return Option[int].some(value = value * 2)

function propagate_result(res: Result[int, int]) -> Result[int, int]:
    let value = res?
    return Result[int, int].success(value = value + 1)

function propagate_chained(
    first: Option[int],
    second: Result[int, int],
) -> Result[int, int]:
    let v = first else:
        return Result[int, int].failure(error = -1)
    let w = second?
    return Result[int, int].success(value = v + w)

# =========================================================================
# Extraction methods (extending blocks)
# =========================================================================

function unwrap_demo(opt: Option[int]) -> int:
    return opt.unwrap()

function expect_demo(opt: Option[int]) -> int:
    return opt.expect("option must be present")

function unwrap_or_demo(opt: Option[int]) -> int:
    return opt.unwrap_or(42)

function unwrap_or_else_demo(opt: Option[int]) -> int:
    return opt.unwrap_or_else(proc() -> int: 99)

function result_unwrap_demo(res: Result[int, int]) -> int:
    return res.unwrap()

function result_unwrap_error_demo(res: Result[int, int]) -> int:
    return res.unwrap_error()

function result_expect_demo(res: Result[int, int]) -> int:
    return res.expect("result must be success")

# =========================================================================
# main — exercises all sections
# =========================================================================

function check_option(opt: Option[int], expected: int, else_val: int) -> int:
    let value = opt else:
        return else_val
    if value == expected:
        return 0
    return 1

function check_result(res: Result[int, int], expected: int) -> int:
    let value = res else as error:
        return 1
    if value == expected:
        return 0
    return 1

function main() -> int:
    var failures: int = 0

    # Identity queries
    failures = failures + check_option(Option[int].some(value = 1), 1, 99)
    if query_option(Option[int].none) != 0:
        failures = failures + 1
    if query_result(Result[int, int].success(value = 1)) != 1:
        failures = failures + 1
    if query_result(Result[int, int].failure(error = 99)) != 0:
        failures = failures + 1

    # match
    if match_option(Option[int].some(value = 5)) != 5:
        failures = failures + 1
    if match_option(Option[int].none) != -1:
        failures = failures + 1
    if match_result(Result[int, int].success(value = 3)) != 3:
        failures = failures + 1
    if match_result(Result[int, int].failure(error = 7)) != 7:
        failures = failures + 1

    # let-else
    if let_else_option(Option[int].some(value = 42)) != 42:
        failures = failures + 1
    if let_else_option(Option[int].none) != -1:
        failures = failures + 1
    failures = failures + check_result(Result[int, int].success(value = 1), 1)
    if let_else_result_with_error_binding(Result[int, int].failure(error = 5)) != 5:
        failures = failures + 1
    if var_else_option(Option[int].some(value = 10)) != 20:
        failures = failures + 1
    if var_else_option(Option[int].none) != 7:
        failures = failures + 1

    # Nullable let-else
    var nv: int? = null
    if let_else_nullable(nv) != 0:
        failures = failures + 1
    nv = 10
    if let_else_nullable(nv) != 10:
        failures = failures + 1

    # Extraction
    if unwrap_demo(Option[int].some(value = 7)) != 7:
        failures = failures + 1
    if unwrap_or_demo(Option[int].none) != 42:
        failures = failures + 1
    if unwrap_or_else_demo(Option[int].none) != 99:
        failures = failures + 1

    if result_unwrap_demo(Result[int, int].success(value = 99)) != 99:
        failures = failures + 1
    if result_unwrap_error_demo(Result[int, int].failure(error = 13)) != 13:
        failures = failures + 1

    # ? propagation — value verified via let-else
    failures = failures + check_option(propagate_option(Option[int].some(value = 10)), 20, -99)
    failures = failures + check_result(propagate_result(Result[int, int].success(value = 5)), 6)

    return failures
