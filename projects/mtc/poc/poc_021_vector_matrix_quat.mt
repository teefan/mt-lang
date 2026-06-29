# POC 021 — Vector, matrix, quaternion: construction, arithmetic (+, -, *, /,
# unary -), dot, cross, length, squared_len, identity.

import std.linear_algebra

function main() -> int:
    # vec2 construction and arithmetic
    let v2 = vec2(x = 1.0, y = 2.0)
    let v2b = vec2(x = 3.0, y = 4.0)
    let v2_add = v2 + v2b
    let v2_sub = v2 - v2b
    let v2_mul = v2 * 2.0
    let v2_div = v2 / 2.0
    let v2_neg = -v2
    let _v2a = v2_add
    let _v2s = v2_sub
    let _v2m = v2_mul
    let _v2d = v2_div
    let _v2n = v2_neg

    # vec3 construction and dot/cross/length
    let v3 = vec3(x = 1.0, y = 0.0, z = 0.0)
    let v3b = vec3(x = 0.0, y = 1.0, z = 0.0)
    let v3_cross = v3.cross(v3b)
    let _v3c = v3_cross
    let v3_dot = v3.dot(v3b)
    let _v3d = v3_dot
    let v3_len = v3.length()
    let _v3l = v3_len
    let v3_sq = v3.length_squared()
    let _v3s = v3_sq

    # vec4 construction
    let v4 = vec4(x = 1.0, y = 0.0, z = 0.0, w = 1.0)
    let _v4 = v4

    # ivec3 construction and arithmetic
    let iv = ivec3(x = 1, y = 2, z = 3)
    let ivb = ivec3(x = 4, y = 5, z = 6)
    let iv_add = iv + ivb
    let _iv = iv_add

    # mat4 construction and identity
    let m = mat4(
        col0 = vec4(x = 1.0, y = 0.0, z = 0.0, w = 0.0),
        col1 = vec4(x = 0.0, y = 1.0, z = 0.0, w = 0.0),
        col2 = vec4(x = 0.0, y = 0.0, z = 1.0, w = 0.0),
        col3 = vec4(x = 0.0, y = 0.0, z = 0.0, w = 1.0),
    )
    let _m = m
    let mi = mat4.identity()
    let _mi = mi

    # quat construction
    let q = quat(x = 0.0, y = 0.0, z = 0.0, w = 1.0)
    let _q = q

    return 0
