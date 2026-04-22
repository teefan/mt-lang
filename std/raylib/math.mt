module std.raylib.math

import std.c.raylib as rl
import std.math as math

type Vector2 = rl.Vector2
type Vector3 = rl.Vector3
type Matrix = rl.Matrix

const deg2rad: f32 = math.pi_f32 / 180.0
const rad2deg: f32 = 180.0 / math.pi_f32

def clamp(value: f32, min_value: f32, max_value: f32) -> f32:
    return math.clamp(value, min_value, max_value)

def lerp(start: f32, finish: f32, amount: f32) -> f32:
    return math.lerp_f32(start, finish, amount)

def vector2_zero() -> Vector2:
    return rl.Vector2(x = 0.0, y = 0.0)

def vector2_one() -> Vector2:
    return rl.Vector2(x = 1.0, y = 1.0)

def vector2_add(v1: Vector2, v2: Vector2) -> Vector2:
    return rl.Vector2(x = v1.x + v2.x, y = v1.y + v2.y)

def vector2_subtract(v1: Vector2, v2: Vector2) -> Vector2:
    return rl.Vector2(x = v1.x - v2.x, y = v1.y - v2.y)

def vector2_scale(v: Vector2, scale: f32) -> Vector2:
    return rl.Vector2(x = v.x * scale, y = v.y * scale)

def vector2_multiply(v1: Vector2, v2: Vector2) -> Vector2:
    return rl.Vector2(x = v1.x * v2.x, y = v1.y * v2.y)

def vector2_clamp(v: Vector2, min_value: Vector2, max_value: Vector2) -> Vector2:
    return rl.Vector2(
        x = clamp(v.x, min_value.x, max_value.x),
        y = clamp(v.y, min_value.y, max_value.y),
    )

def vector3_zero() -> Vector3:
    return rl.Vector3(x = 0.0, y = 0.0, z = 0.0)

def vector3_one() -> Vector3:
    return rl.Vector3(x = 1.0, y = 1.0, z = 1.0)

def vector3_add(v1: Vector3, v2: Vector3) -> Vector3:
    return rl.Vector3(x = v1.x + v2.x, y = v1.y + v2.y, z = v1.z + v2.z)

def vector3_subtract(v1: Vector3, v2: Vector3) -> Vector3:
    return rl.Vector3(x = v1.x - v2.x, y = v1.y - v2.y, z = v1.z - v2.z)

def vector3_scale(v: Vector3, scale: f32) -> Vector3:
    return rl.Vector3(x = v.x * scale, y = v.y * scale, z = v.z * scale)

def vector3_dot_product(v1: Vector3, v2: Vector3) -> f32:
    return v1.x * v2.x + v1.y * v2.y + v1.z * v2.z

def vector3_cross_product(v1: Vector3, v2: Vector3) -> Vector3:
    return rl.Vector3(
        x = v1.y * v2.z - v1.z * v2.y,
        y = v1.z * v2.x - v1.x * v2.z,
        z = v1.x * v2.y - v1.y * v2.x,
    )

def vector3_negate(v: Vector3) -> Vector3:
    return rl.Vector3(x = -v.x, y = -v.y, z = -v.z)

def vector3_lerp(v1: Vector3, v2: Vector3, amount: f32) -> Vector3:
    return rl.Vector3(
        x = lerp(v1.x, v2.x, amount),
        y = lerp(v1.y, v2.y, amount),
        z = lerp(v1.z, v2.z, amount),
    )

def vector3_transform(v: Vector3, mat: Matrix) -> Vector3:
    let x = v.x
    let y = v.y
    let z = v.z
    return rl.Vector3(
        x = mat.m0 * x + mat.m4 * y + mat.m8 * z + mat.m12,
        y = mat.m1 * x + mat.m5 * y + mat.m9 * z + mat.m13,
        z = mat.m2 * x + mat.m6 * y + mat.m10 * z + mat.m14,
    )

def matrix_identity() -> Matrix:
    return rl.Matrix(
        m0 = 1.0,
        m4 = 0.0,
        m8 = 0.0,
        m12 = 0.0,
        m1 = 0.0,
        m5 = 1.0,
        m9 = 0.0,
        m13 = 0.0,
        m2 = 0.0,
        m6 = 0.0,
        m10 = 1.0,
        m14 = 0.0,
        m3 = 0.0,
        m7 = 0.0,
        m11 = 0.0,
        m15 = 1.0,
    )

def matrix_multiply(left: Matrix, right: Matrix) -> Matrix:
    return rl.Matrix(
        m0 = left.m0 * right.m0 + left.m1 * right.m4 + left.m2 * right.m8 + left.m3 * right.m12,
        m4 = left.m4 * right.m0 + left.m5 * right.m4 + left.m6 * right.m8 + left.m7 * right.m12,
        m8 = left.m8 * right.m0 + left.m9 * right.m4 + left.m10 * right.m8 + left.m11 * right.m12,
        m12 = left.m12 * right.m0 + left.m13 * right.m4 + left.m14 * right.m8 + left.m15 * right.m12,
        m1 = left.m0 * right.m1 + left.m1 * right.m5 + left.m2 * right.m9 + left.m3 * right.m13,
        m5 = left.m4 * right.m1 + left.m5 * right.m5 + left.m6 * right.m9 + left.m7 * right.m13,
        m9 = left.m8 * right.m1 + left.m9 * right.m5 + left.m10 * right.m9 + left.m11 * right.m13,
        m13 = left.m12 * right.m1 + left.m13 * right.m5 + left.m14 * right.m9 + left.m15 * right.m13,
        m2 = left.m0 * right.m2 + left.m1 * right.m6 + left.m2 * right.m10 + left.m3 * right.m14,
        m6 = left.m4 * right.m2 + left.m5 * right.m6 + left.m6 * right.m10 + left.m7 * right.m14,
        m10 = left.m8 * right.m2 + left.m9 * right.m6 + left.m10 * right.m10 + left.m11 * right.m14,
        m14 = left.m12 * right.m2 + left.m13 * right.m6 + left.m14 * right.m10 + left.m15 * right.m14,
        m3 = left.m0 * right.m3 + left.m1 * right.m7 + left.m2 * right.m11 + left.m3 * right.m15,
        m7 = left.m4 * right.m3 + left.m5 * right.m7 + left.m6 * right.m11 + left.m7 * right.m15,
        m11 = left.m8 * right.m3 + left.m9 * right.m7 + left.m10 * right.m11 + left.m11 * right.m15,
        m15 = left.m12 * right.m3 + left.m13 * right.m7 + left.m14 * right.m11 + left.m15 * right.m15,
    )

def matrix_translate(x: f32, y: f32, z: f32) -> Matrix:
    return rl.Matrix(
        m0 = 1.0,
        m4 = 0.0,
        m8 = 0.0,
        m12 = x,
        m1 = 0.0,
        m5 = 1.0,
        m9 = 0.0,
        m13 = y,
        m2 = 0.0,
        m6 = 0.0,
        m10 = 1.0,
        m14 = z,
        m3 = 0.0,
        m7 = 0.0,
        m11 = 0.0,
        m15 = 1.0,
    )

def matrix_scale(x: f32, y: f32, z: f32) -> Matrix:
    return rl.Matrix(
        m0 = x,
        m4 = 0.0,
        m8 = 0.0,
        m12 = 0.0,
        m1 = 0.0,
        m5 = y,
        m9 = 0.0,
        m13 = 0.0,
        m2 = 0.0,
        m6 = 0.0,
        m10 = z,
        m14 = 0.0,
        m3 = 0.0,
        m7 = 0.0,
        m11 = 0.0,
        m15 = 1.0,
    )
