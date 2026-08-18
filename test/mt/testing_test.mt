# In-language tests for the assert/expect/expect_eq/expect_ne intrinsics
# (run by `mtc test`).


@[test]
function test_expect_not_equal_int() -> void:
    expect_ne(1, 2)


@[test]
function test_expect_not_equal_str() -> void:
    expect_ne("foo", "bar")


@[test]
function test_expect_not_equal_bool() -> void:
    expect_ne(true, false)


@[test]
function test_expect_not_null_pointer() -> void:
    var value = 42
    unsafe:
        let pointer: const_ptr[int]? = const_ptr[int]<-ref_of(value)
        expect(pointer != null)


@[test]
function test_expect_null_pointer() -> void:
    let pointer: const_ptr[int]? = null
    expect(pointer == null)


@[test]
function test_expect_error_on_failure() -> void:
    let value: Result[int, int] = Result[int, int].failure(error = 3)
    expect(value.is_failure())


@[test]
function test_expect_equal_int() -> void:
    expect_eq(2 + 2, 4)


@[test]
function test_expect_equal_uint() -> void:
    expect_eq(uint<-(3), uint<-(3))


@[test]
function test_expect_equal_long() -> void:
    expect_eq(5l, 5l)


@[test]
function test_expect_equal_float() -> void:
    expect_eq(1.5, 1.5)


@[test]
function test_expect_equal_bool() -> void:
    expect_eq(true, true)


@[test]
function test_expect_equal_str() -> void:
    expect_eq("milk", "milk")


struct Tag:
    id: int


@[test]
function test_expect_equal_struct() -> void:
    expect_eq(Tag(id = 1), Tag(id = 1))
