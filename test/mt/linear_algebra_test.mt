# In-language tests for std.linear_algebra native vector/matrix/quaternion
# arithmetic, exercising the builtin constructor types (`vec3(...)`) and both
# scalar operand orders (`2.0 * v` and `v * 2.0`).

import std.linear_algebra


@[test]
function test_vector_component_wise_arithmetic() -> void:
    let a = vec3(x = 1.0, y = 2.0, z = 3.0)
    let b = vec3(x = 4.0, y = 5.0, z = 6.0)
    let sum = a + b
    let diff = b - a
    let product = a * b
    let negated = -a

    expect_eq(sum.x, 5.0)
    expect_eq(sum.y, 7.0)
    expect_eq(sum.z, 9.0)
    expect_eq(diff.x, 3.0)
    expect_eq(diff.y, 3.0)
    expect_eq(diff.z, 3.0)
    expect_eq(product.x, 4.0)
    expect_eq(product.y, 10.0)
    expect_eq(product.z, 18.0)
    expect_eq(negated.x, -1.0)
    expect_eq(negated.y, -2.0)
    expect_eq(negated.z, -3.0)


@[test]
function test_vector_scalar_arithmetic_both_orders() -> void:
    let v = vec3(x = 1.0, y = 2.0, z = 3.0)
    let scaled = v * 2.0
    let reversed = 2.0 * v
    let divided = v / 2.0

    expect_eq(scaled.x, 2.0)
    expect_eq(scaled.y, 4.0)
    expect_eq(scaled.z, 6.0)
    expect_eq(reversed.x, 2.0)
    expect_eq(reversed.y, 4.0)
    expect_eq(reversed.z, 6.0)
    expect_eq(divided.x, 0.5)
    expect_eq(divided.y, 1.0)
    expect_eq(divided.z, 1.5)


@[test]
function test_integer_vector_arithmetic() -> void:
    let iv = ivec3(x = 1, y = 2, z = 3)
    let isum = iv + iv
    let iscaled = iv * 3
    let ireversed = 3 * iv
    let inegated = -iv

    expect_eq(isum.x, 2)
    expect_eq(isum.y, 4)
    expect_eq(isum.z, 6)
    expect_eq(iscaled.x, 3)
    expect_eq(iscaled.y, 6)
    expect_eq(iscaled.z, 9)
    expect_eq(ireversed.x, 3)
    expect_eq(ireversed.y, 6)
    expect_eq(ireversed.z, 9)
    expect_eq(inegated.z, -3)


@[test]
function test_vector_methods() -> void:
    let v = vec3(x = 3.0, y = 0.0, z = 0.0)
    expect_eq(v.dot(v), 9.0)
    expect_eq(v.length(), 3.0)

    let cross = v.cross(vec3(x = 0.0, y = 1.0, z = 0.0))
    expect_eq(cross.z, 3.0)

    let filled = vec2.fill(2.5)
    expect_eq(filled.x, 2.5)
    expect_eq(filled.y, 2.5)


@[test]
function test_matrix_and_quaternion_arithmetic() -> void:
    let identity = mat4.identity()
    let msum = identity + identity
    let mscaled = identity * 2.0
    let mnegated = -identity

    expect_eq(msum.col0.x, 2.0)
    expect_eq(mscaled.col1.y, 2.0)
    expect_eq(mscaled.col2.z, 2.0)
    expect_eq(mnegated.col3.w, -1.0)

    let q = quat(x = 0.0, y = 0.0, z = 0.0, w = 1.0)
    let qsum = q + q
    let qnegated = -q
    expect_eq(qsum.w, 2.0)
    expect_eq(qnegated.w, -1.0)
