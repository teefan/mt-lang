# In-language tests for the std.testing helper surface itself
# (the assertion additions; run by `mtc test`).

import std.testing as t

@[test]
function test_expect_not_equal_int() -> t.Check:
    return t.expect_not_equal_int(1, 2)


@[test]
function test_expect_not_equal_str() -> t.Check:
    return t.expect_not_equal_str("foo", "bar")


@[test]
function test_expect_not_equal_bool() -> t.Check:
    return t.expect_not_equal_bool(true, false)


@[test]
function test_expect_not_null_pointer() -> t.Check:
    var value = 42
    unsafe:
        let pointer: const_ptr[int]? = const_ptr[int]<-ref_of(value)
        return t.expect_not_null[int](pointer)


@[test]
function test_expect_null_pointer() -> t.Check:
    let pointer: const_ptr[int]? = null
    return t.expect_null[int](pointer)


@[test]
function test_expect_error_on_failure() -> t.Check:
    let value: Result[int, int] = Result[int, int].failure(error = 3)
    return t.expect_error[int, int](value)


@[test]
function test_expect_equal_int() -> t.Check:
    return t.expect_equal[int](2 + 2, 4)


@[test]
function test_expect_equal_uint() -> t.Check:
    return t.expect_equal[uint](uint<-(3), uint<-(3))


@[test]
function test_expect_equal_long() -> t.Check:
    return t.expect_equal[long](5l, 5l)


@[test]
function test_expect_equal_float() -> t.Check:
    return t.expect_equal[float](1.5, 1.5)


@[test]
function test_expect_equal_bool() -> t.Check:
    return t.expect_equal[bool](true, true)


@[test]
function test_expect_equal_str() -> t.Check:
    return t.expect_equal[str]("milk", "milk")


struct Tag:
    id: int


extending Tag:
    static function equal(left: const_ptr[Tag], right: const_ptr[Tag]) -> bool:
        unsafe:
            return read(ptr[Tag]<-left).id == read(ptr[Tag]<-right).id


@[test]
function test_expect_equal_struct() -> t.Check:
    return t.expect_equal[Tag](Tag(id = 1), Tag(id = 1))
