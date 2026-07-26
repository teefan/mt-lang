## SIMD Features Demo
##
## This file exercises the complete simd[T, N] type surface:
## construction, arithmetic, lane access, compound assignment,
## and interaction with arrays/spans.
##
## simd[T, N] is a built-in SIMD vector type that lowers to
## GCC/Clang vector extensions for portable, readable C output.

# =============================================================================
# 1  Construction and zero initialization
# =============================================================================

function construction_demo() -> int:
    var total: int = 0

    let f4 = simd[float, 4](1.0, 2.0, 3.0, 4.0)
    let d2 = simd[double, 2](0.5, 1.5)
    let i4 = simd[int, 4](10, 20, 30, 40)
    let u4 = simd[uint, 4](100, 200, 300, 400)
    let s8 = simd[short, 8](1, 2, 3, 4, 5, 6, 7, 8)
    let b16 = simd[ubyte, 16](
        1, 2, 3, 4, 5, 6, 7, 8,
        9, 10, 11, 12, 13, 14, 15, 16,
    )

    let _d2 = d2
    let _u4 = u4
    let _s8 = s8
    let _b16 = b16

    total += int<-(f4[0]) + int<-(i4[0])
    return total

# =============================================================================
# 2  Arithmetic operators (component-wise)
# =============================================================================

function arithmetic_demo() -> int:
    var total: int = 0

    let a = simd[float, 4](1.0, 2.0, 3.0, 4.0)
    let b = simd[float, 4](5.0, 6.0, 7.0, 8.0)

    let sum  = a + b
    let diff = a - b
    let prod = a * b
    let quot = a / b

    let neg   = -a

    let scaled = a * 2.0
    let left_scaled = 3.0 * a
    let div_scaled = a / 4.0

    if sum[0] > 0.0:
        total += 1
    if neg[0] < 0.0:
        total += 1

    let _diff = diff
    let _prod = prod
    let _quot = quot
    let _scaled = scaled
    let _left_scaled = left_scaled
    let _div_scaled = div_scaled

    return total

# =============================================================================
# 3  Integer SIMD arithmetic and bitwise ops
# =============================================================================

function integer_simd_demo() -> int:
    var total: int = 0

    let a = simd[int, 4](10, 20, 30, 40)
    let b = simd[int, 4](3, 4, 5, 6)

    let sum  = a + b
    let diff = a - b
    let prod = a * b
    let quot = a / b
    let rem  = a % b

    let neg = -a

    let and_val = a & b
    let or_val  = a | b
    let xor_val = a ^ b
    let not_val = ~a

    let shl = a << 2
    let shr = b >> 1

    total += int<-(sum[0] + diff[0] + prod[0] + quot[0] + rem[0])

    let _neg = neg
    let _and = and_val
    let _or = or_val
    let _xor = xor_val
    let _not = not_val
    let _shl = shl
    let _shr = shr

    return total

# =============================================================================
# 4  Lane access (compile-time constant index)
# =============================================================================

function lane_access_demo() -> float:
    let v = simd[float, 4](10.0, 20.0, 30.0, 40.0)

    let first  = v[0]
    let second = v[1]
    let third  = v[2]
    let fourth = v[3]

    return first + second + third + fourth

# =============================================================================
# 5  Compound assignment operators
# =============================================================================

function compound_assignment_demo() -> float:
    var a = simd[float, 4](1.0, 2.0, 3.0, 4.0)
    var b = simd[float, 4](5.0, 6.0, 7.0, 8.0)

    a += b
    a -= b
    a *= 2.0
    a /= 2.0

    var c = simd[int, 4](10, 20, 30, 40)
    var d = simd[int, 4](3, 4, 5, 6)

    c += d
    c -= d
    c *= d
    c /= 2
    c %= 3

    c &= d
    c |= d
    c ^= d
    c <<= 1
    c >>= 1

    let _c = c
    return a[0]

# =============================================================================
# 6  Interaction with arrays
# =============================================================================

function array_interaction_demo() -> float:
    var data: array[float, 12] = array[float, 12](
        1.0, 2.0, 3.0, 4.0,
        5.0, 6.0, 7.0, 8.0,
        9.0, 10.0, 11.0, 12.0,
    )
    var acc = simd[float, 4](0.0, 0.0, 0.0, 0.0)
    var i: int = 0
    while i < 12:
        let v = simd[float, 4](data[i], data[i + 1], data[i + 2], data[i + 3])
        acc += v
        i += 4
    return acc[0] + acc[1] + acc[2] + acc[3]

# =============================================================================
# 7  Type annotations and var declarations
# =============================================================================

function typed_declarations_demo() -> float:
    let explicit: simd[float, 4] = simd[float, 4](1.0, 2.0, 3.0, 4.0)
    let inferred = simd[float, 4](5.0, 6.0, 7.0, 8.0)

    var mutable: simd[float, 4] = simd[float, 4](0.0, 0.0, 0.0, 0.0)
    mutable += explicit
    mutable += inferred

    return explicit[0] + inferred[0] + mutable[0]

# =============================================================================
# 8  Nested expressions
# =============================================================================

function nested_expression_demo() -> float:
    let a = simd[float, 4](1.0, 2.0, 3.0, 4.0)
    let b = simd[float, 4](5.0, 6.0, 7.0, 8.0)
    let c = simd[float, 4](9.0, 10.0, 11.0, 12.0)

    let result = (a + b) * c - (a - b)
    let combined = a + b * c + a

    return result[0] + combined[0]

# =============================================================================
# 9  Entrypoint
# =============================================================================

function main() -> int:
    var total: int = 0

    total += construction_demo()
    total += arithmetic_demo()
    total += integer_simd_demo()

    total += int<-(lane_access_demo())
    total += int<-(compound_assignment_demo())
    total += int<-(array_interaction_demo())
    total += int<-(typed_declarations_demo())
    total += int<-(nested_expression_demo())

    let _total = total
    return 0
