# In-language tests for builtin span (migrated from
# test/std/std_span_test.rb, run by `mtc test`).


@[test]
function test_span_constructor_len() -> void:
    var values = array[int, 3](7, 8, 9)
    let view = span[int](data = ptr_of(values[0]), len = 3)
    expect(view.len == 3, "constructed span len should be 3")


@[test]
function test_span_sum() -> void:
    var values = array[int, 3](7, 8, 9)
    let view = span[int](data = ptr_of(values[0]), len = 3)
    var total = 0
    var index: ptr_uint = 0
    while index < view.len:
        unsafe:
            total += read(view.data + index)
        index += 1
    expect_eq(total, 24)


@[test]
function test_zero_span_is_empty() -> void:
    let empty = zero[span[int]]
    expect(empty.len == 0, "zero span len should be 0")


@[test]
function test_null_view_is_empty() -> void:
    let missing: ptr[int]? = null
    let null_view = unsafe: span[int](data = ptr[int]<-missing, len = 0)
    expect(null_view.len == 0, "null view len should be 0")
