module std.raylib.math

import std.c.libm as libm
import std.c.raylib as rl
import std.math as math

pub type Vector2 = rl.Vector2
pub type Vector3 = rl.Vector3
pub type Matrix = rl.Matrix
pub type Quaternion = rl.Quaternion
pub type Color = rl.Color

pub const deg2rad: float = math.deg2rad
pub const rad2deg: float = math.rad2deg
const quaternion_slerp_epsilon: float = 0.000001
const quaternion_slerp_linear_threshold: float = 0.95


pub def clamp(value: float, min_value: float, max_value: float) -> float:
    if value < min_value:
        return min_value
    if value > max_value:
        return max_value
    return value


pub def lerp(start: float, finish: float, amount: float) -> float:
    return start + (finish - start) * amount


pub def abs(value: float) -> float:
    return libm.fabsf(value)


pub def ceil(value: float) -> float:
    return libm.ceilf(value)


pub def floor(value: float) -> float:
    return libm.floorf(value)


pub def trunc(value: float) -> float:
    return libm.truncf(value)


pub def sqrt(value: float) -> float:
    return libm.sqrtf(value)


pub def sin(value: float) -> float:
    return libm.sinf(value)


pub def cos(value: float) -> float:
    return libm.cosf(value)


pub def tan(value: float) -> float:
    return libm.tanf(value)


pub def atan2(y: float, x: float) -> float:
    return libm.atan2f(y, x)


pub def acos(value: float) -> float:
    return libm.acosf(value)

methods rl.Color:
    pub static def from_hsv(hue: float, saturation: float, value: float) -> Color:
        return rl.ColorFromHSV(hue, saturation, value)

methods rl.Vector2:
    pub static def zero() -> Vector2:
        return rl.Vector2(x = 0.0, y = 0.0)


    pub static def one() -> Vector2:
        return rl.Vector2(x = 1.0, y = 1.0)


    pub def add(other: Vector2) -> Vector2:
        return rl.Vector2(x = this.x + other.x, y = this.y + other.y)


    pub def subtract(other: Vector2) -> Vector2:
        return rl.Vector2(x = this.x - other.x, y = this.y - other.y)


    pub def scale(factor: float) -> Vector2:
        return rl.Vector2(x = this.x * factor, y = this.y * factor)


    pub def multiply(other: Vector2) -> Vector2:
        return rl.Vector2(x = this.x * other.x, y = this.y * other.y)


    pub def length() -> float:
        return libm.sqrtf(this.x * this.x + this.y * this.y)


    pub def distance(other: Vector2) -> float:
        let dx = this.x - other.x
        let dy = this.y - other.y
        return libm.sqrtf(dx * dx + dy * dy)


    pub def angle(other: Vector2) -> float:
        let dot = this.x * other.x + this.y * other.y
        let det = this.x * other.y - this.y * other.x
        return libm.atan2f(det, dot)


    pub def normalize() -> Vector2:
        let length = this.length()
        if length > 0.0:
            let inv_length = 1.0 / length
            return rl.Vector2(x = this.x * inv_length, y = this.y * inv_length)
        return Vector2.zero()


    pub def rotate(angle: float) -> Vector2:
        let cos_angle = libm.cosf(angle)
        let sin_angle = libm.sinf(angle)
        return rl.Vector2(
            x = this.x * cos_angle - this.y * sin_angle,
            y = this.x * sin_angle + this.y * cos_angle,
        )


    pub def clamp(min_value: Vector2, max_value: Vector2) -> Vector2:
        return rl.Vector2(
            x = clamp(this.x, min_value.x, max_value.x),
            y = clamp(this.y, min_value.y, max_value.y),
        )

methods rl.Vector3:
    pub static def zero() -> Vector3:
        return rl.Vector3(x = 0.0, y = 0.0, z = 0.0)


    pub static def one() -> Vector3:
        return rl.Vector3(x = 1.0, y = 1.0, z = 1.0)


    pub def add(other: Vector3) -> Vector3:
        return rl.Vector3(x = this.x + other.x, y = this.y + other.y, z = this.z + other.z)


    pub def subtract(other: Vector3) -> Vector3:
        return rl.Vector3(x = this.x - other.x, y = this.y - other.y, z = this.z - other.z)


    pub def scale(factor: float) -> Vector3:
        return rl.Vector3(x = this.x * factor, y = this.y * factor, z = this.z * factor)


    pub def dot(other: Vector3) -> float:
        return this.x * other.x + this.y * other.y + this.z * other.z


    pub def length() -> float:
        return libm.sqrtf(this.x * this.x + this.y * this.y + this.z * this.z)


    pub def distance(other: Vector3) -> float:
        let dx = other.x - this.x
        let dy = other.y - this.y
        let dz = other.z - this.z
        return libm.sqrtf(dx * dx + dy * dy + dz * dz)


    pub def cross(other: Vector3) -> Vector3:
        return rl.Vector3(
            x = this.y * other.z - this.z * other.y,
            y = this.z * other.x - this.x * other.z,
            z = this.x * other.y - this.y * other.x,
        )


    pub def angle(other: Vector3) -> float:
        let cross = this.cross(other)
        let length = cross.length()
        let dot = this.dot(other)
        return libm.atan2f(length, dot)


    pub def negate() -> Vector3:
        return rl.Vector3(x = -this.x, y = -this.y, z = -this.z)


    pub def normalize() -> Vector3:
        let length = this.length()
        if length != 0.0:
            let inv_length = 1.0 / length
            return rl.Vector3(x = this.x * inv_length, y = this.y * inv_length, z = this.z * inv_length)
        return this


    pub def lerp(other: Vector3, amount: float) -> Vector3:
        return rl.Vector3(
            x = lerp(this.x, other.x, amount),
            y = lerp(this.y, other.y, amount),
            z = lerp(this.z, other.z, amount),
        )


    pub def rotate_by_axis_angle(axis: Vector3, angle: float) -> Vector3:
        let normalized_axis = axis.normalize()
        let half_angle = angle / 2.0
        let sin_half_angle = libm.sinf(half_angle)
        let scalar = libm.cosf(half_angle)
        let w = rl.Vector3(
            x = normalized_axis.x * sin_half_angle,
            y = normalized_axis.y * sin_half_angle,
            z = normalized_axis.z * sin_half_angle,
        )
        let wv = w.cross(this)
        let wwv = w.cross(wv)
        let scaled_wv = wv.scale(2.0 * scalar)
        let scaled_wwv = wwv.scale(2.0)
        return this.add(scaled_wv).add(scaled_wwv)


    pub def transform(mat: Matrix) -> Vector3:
        let x = this.x
        let y = this.y
        let z = this.z
        return rl.Vector3(
            x = mat.m0 * x + mat.m4 * y + mat.m8 * z + mat.m12,
            y = mat.m1 * x + mat.m5 * y + mat.m9 * z + mat.m13,
            z = mat.m2 * x + mat.m6 * y + mat.m10 * z + mat.m14,
        )

methods rl.Matrix:
    pub static def identity() -> Matrix:
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


    pub def multiply(other: Matrix) -> Matrix:
        return rl.Matrix(
            m0 = this.m0 * other.m0 + this.m1 * other.m4 + this.m2 * other.m8 + this.m3 * other.m12,
            m4 = this.m4 * other.m0 + this.m5 * other.m4 + this.m6 * other.m8 + this.m7 * other.m12,
            m8 = this.m8 * other.m0 + this.m9 * other.m4 + this.m10 * other.m8 + this.m11 * other.m12,
            m12 = this.m12 * other.m0 + this.m13 * other.m4 + this.m14 * other.m8 + this.m15 * other.m12,
            m1 = this.m0 * other.m1 + this.m1 * other.m5 + this.m2 * other.m9 + this.m3 * other.m13,
            m5 = this.m4 * other.m1 + this.m5 * other.m5 + this.m6 * other.m9 + this.m7 * other.m13,
            m9 = this.m8 * other.m1 + this.m9 * other.m5 + this.m10 * other.m9 + this.m11 * other.m13,
            m13 = this.m12 * other.m1 + this.m13 * other.m5 + this.m14 * other.m9 + this.m15 * other.m13,
            m2 = this.m0 * other.m2 + this.m1 * other.m6 + this.m2 * other.m10 + this.m3 * other.m14,
            m6 = this.m4 * other.m2 + this.m5 * other.m6 + this.m6 * other.m10 + this.m7 * other.m14,
            m10 = this.m8 * other.m2 + this.m9 * other.m6 + this.m10 * other.m10 + this.m11 * other.m14,
            m14 = this.m12 * other.m2 + this.m13 * other.m6 + this.m14 * other.m10 + this.m15 * other.m14,
            m3 = this.m0 * other.m3 + this.m1 * other.m7 + this.m2 * other.m11 + this.m3 * other.m15,
            m7 = this.m4 * other.m3 + this.m5 * other.m7 + this.m6 * other.m11 + this.m7 * other.m15,
            m11 = this.m8 * other.m3 + this.m9 * other.m7 + this.m10 * other.m11 + this.m11 * other.m15,
            m15 = this.m12 * other.m3 + this.m13 * other.m7 + this.m14 * other.m11 + this.m15 * other.m15,
        )


    pub def transpose() -> Matrix:
        return rl.Matrix(
            m0 = this.m0,
            m4 = this.m1,
            m8 = this.m2,
            m12 = this.m3,
            m1 = this.m4,
            m5 = this.m5,
            m9 = this.m6,
            m13 = this.m7,
            m2 = this.m8,
            m6 = this.m9,
            m10 = this.m10,
            m14 = this.m11,
            m3 = this.m12,
            m7 = this.m13,
            m11 = this.m14,
            m15 = this.m15,
        )


    pub def invert() -> Matrix:
        let a00 = this.m0
        let a01 = this.m1
        let a02 = this.m2
        let a03 = this.m3
        let a10 = this.m4
        let a11 = this.m5
        let a12 = this.m6
        let a13 = this.m7
        let a20 = this.m8
        let a21 = this.m9
        let a22 = this.m10
        let a23 = this.m11
        let a30 = this.m12
        let a31 = this.m13
        let a32 = this.m14
        let a33 = this.m15

        let b00 = a00 * a11 - a01 * a10
        let b01 = a00 * a12 - a02 * a10
        let b02 = a00 * a13 - a03 * a10
        let b03 = a01 * a12 - a02 * a11
        let b04 = a01 * a13 - a03 * a11
        let b05 = a02 * a13 - a03 * a12
        let b06 = a20 * a31 - a21 * a30
        let b07 = a20 * a32 - a22 * a30
        let b08 = a20 * a33 - a23 * a30
        let b09 = a21 * a32 - a22 * a31
        let b10 = a21 * a33 - a23 * a31
        let b11 = a22 * a33 - a23 * a32
        let inv_det = 1.0 / (b00 * b11 - b01 * b10 + b02 * b09 + b03 * b08 - b04 * b07 + b05 * b06)

        return rl.Matrix(
            m0 = (a11 * b11 - a12 * b10 + a13 * b09) * inv_det,
            m1 = (-a01 * b11 + a02 * b10 - a03 * b09) * inv_det,
            m2 = (a31 * b05 - a32 * b04 + a33 * b03) * inv_det,
            m3 = (-a21 * b05 + a22 * b04 - a23 * b03) * inv_det,
            m4 = (-a10 * b11 + a12 * b08 - a13 * b07) * inv_det,
            m5 = (a00 * b11 - a02 * b08 + a03 * b07) * inv_det,
            m6 = (-a30 * b05 + a32 * b02 - a33 * b01) * inv_det,
            m7 = (a20 * b05 - a22 * b02 + a23 * b01) * inv_det,
            m8 = (a10 * b10 - a11 * b08 + a13 * b06) * inv_det,
            m9 = (-a00 * b10 + a01 * b08 - a03 * b06) * inv_det,
            m10 = (a30 * b04 - a31 * b02 + a33 * b00) * inv_det,
            m11 = (-a20 * b04 + a21 * b02 - a23 * b00) * inv_det,
            m12 = (-a10 * b09 + a11 * b07 - a12 * b06) * inv_det,
            m13 = (a00 * b09 - a01 * b07 + a02 * b06) * inv_det,
            m14 = (-a30 * b03 + a31 * b01 - a32 * b00) * inv_det,
            m15 = (a20 * b03 - a21 * b01 + a22 * b00) * inv_det,
        )


    pub static def translate(x: float, y: float, z: float) -> Matrix:
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


    pub static def scale(x: float, y: float, z: float) -> Matrix:
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


    pub static def rotate_z(angle: float) -> Matrix:
        let cosz = libm.cosf(angle)
        let sinz = libm.sinf(angle)
        return rl.Matrix(
            m0 = cosz,
            m4 = -sinz,
            m8 = 0.0,
            m12 = 0.0,
            m1 = sinz,
            m5 = cosz,
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


    pub static def rotate_xyz(angle: Vector3) -> Matrix:
        let cosz = libm.cosf(-angle.z)
        let sinz = libm.sinf(-angle.z)
        let cosy = libm.cosf(-angle.y)
        let siny = libm.sinf(-angle.y)
        let cosx = libm.cosf(-angle.x)
        let sinx = libm.sinf(-angle.x)
        return rl.Matrix(
            m0 = cosz * cosy,
            m4 = sinz * cosy,
            m8 = -siny,
            m12 = 0.0,
            m1 = (cosz * siny * sinx) - (sinz * cosx),
            m5 = (sinz * siny * sinx) + (cosz * cosx),
            m9 = cosy * sinx,
            m13 = 0.0,
            m2 = (cosz * siny * cosx) + (sinz * sinx),
            m6 = (sinz * siny * cosx) - (cosz * sinx),
            m10 = cosy * cosx,
            m14 = 0.0,
            m3 = 0.0,
            m7 = 0.0,
            m11 = 0.0,
            m15 = 1.0,
        )


    pub static def perspective(fov_y: float, aspect: float, near_plane: float, far_plane: float) -> Matrix:
        let top = near_plane * libm.tanf(fov_y * 0.5)
        let bottom = -top
        let right = top * aspect
        let left = -right
        let rl_width = right - left
        let tb = top - bottom
        let far_n = far_plane - near_plane
        return rl.Matrix(
            m0 = near_plane * 2.0 / rl_width,
            m4 = 0.0,
            m8 = (right + left) / rl_width,
            m12 = 0.0,
            m1 = 0.0,
            m5 = near_plane * 2.0 / tb,
            m9 = (top + bottom) / tb,
            m13 = 0.0,
            m2 = 0.0,
            m6 = 0.0,
            m10 = -(far_plane + near_plane) / far_n,
            m14 = -(far_plane * near_plane * 2.0) / far_n,
            m3 = 0.0,
            m7 = 0.0,
            m11 = -1.0,
            m15 = 0.0,
        )


    pub static def ortho(left: float, right: float, bottom: float, top: float, near_plane: float, far_plane: float) -> Matrix:
        let rl_width = right - left
        let tb = top - bottom
        let far_n = far_plane - near_plane
        return rl.Matrix(
            m0 = 2.0 / rl_width,
            m4 = 0.0,
            m8 = 0.0,
            m12 = -(left + right) / rl_width,
            m1 = 0.0,
            m5 = 2.0 / tb,
            m9 = 0.0,
            m13 = -(top + bottom) / tb,
            m2 = 0.0,
            m6 = 0.0,
            m10 = -2.0 / far_n,
            m14 = -(far_plane + near_plane) / far_n,
            m3 = 0.0,
            m7 = 0.0,
            m11 = 0.0,
            m15 = 1.0,
        )


    pub static def look_at(eye: Vector3, target: Vector3, up: Vector3) -> Matrix:
        let vz = eye.subtract(target).normalize()
        let vx = up.cross(vz).normalize()
        let vy = vz.cross(vx)
        return rl.Matrix(
            m0 = vx.x,
            m4 = vx.y,
            m8 = vx.z,
            m12 = -vx.dot(eye),
            m1 = vy.x,
            m5 = vy.y,
            m9 = vy.z,
            m13 = -vy.dot(eye),
            m2 = vz.x,
            m6 = vz.y,
            m10 = vz.z,
            m14 = -vz.dot(eye),
            m3 = 0.0,
            m7 = 0.0,
            m11 = 0.0,
            m15 = 1.0,
        )

methods rl.Quaternion:
    pub static def identity() -> Quaternion:
        return rl.Vector4(x = 0.0, y = 0.0, z = 0.0, w = 1.0)


    pub def length() -> float:
        return libm.sqrtf(this.x * this.x + this.y * this.y + this.z * this.z + this.w * this.w)


    pub def normalize() -> Quaternion:
        let length = this.length()
        if length == 0.0:
            return this
        let inv_length = 1.0 / length
        return rl.Vector4(
            x = this.x * inv_length,
            y = this.y * inv_length,
            z = this.z * inv_length,
            w = this.w * inv_length,
        )


    pub def invert() -> Quaternion:
        let length_sq = this.x * this.x + this.y * this.y + this.z * this.z + this.w * this.w
        if length_sq == 0.0:
            return this
        let inv_length = 1.0 / length_sq
        return rl.Vector4(
            x = -this.x * inv_length,
            y = -this.y * inv_length,
            z = -this.z * inv_length,
            w = this.w * inv_length,
        )


    pub def multiply(other: Quaternion) -> Quaternion:
        return rl.Vector4(
            x = this.x * other.w + this.w * other.x + this.y * other.z - this.z * other.y,
            y = this.y * other.w + this.w * other.y + this.z * other.x - this.x * other.z,
            z = this.z * other.w + this.w * other.z + this.x * other.y - this.y * other.x,
            w = this.w * other.w - this.x * other.x - this.y * other.y - this.z * other.z,
        )


    pub def to_matrix() -> Matrix:
        let a2 = this.x * this.x
        let b2 = this.y * this.y
        let c2 = this.z * this.z
        let ac = this.x * this.z
        let ab = this.x * this.y
        let bc = this.y * this.z
        let ad = this.w * this.x
        let bd = this.w * this.y
        let cd = this.w * this.z
        return rl.Matrix(
            m0 = 1.0 - 2.0 * (b2 + c2),
            m4 = 2.0 * (ab - cd),
            m8 = 2.0 * (ac + bd),
            m12 = 0.0,
            m1 = 2.0 * (ab + cd),
            m5 = 1.0 - 2.0 * (a2 + c2),
            m9 = 2.0 * (bc - ad),
            m13 = 0.0,
            m2 = 2.0 * (ac - bd),
            m6 = 2.0 * (bc + ad),
            m10 = 1.0 - 2.0 * (a2 + b2),
            m14 = 0.0,
            m3 = 0.0,
            m7 = 0.0,
            m11 = 0.0,
            m15 = 1.0,
        )


    pub static def from_axis_angle(axis: Vector3, angle: float) -> Quaternion:
        let axis_length = axis.length()
        if axis_length == 0.0:
            return Quaternion.identity()
        let half_angle = angle * 0.5
        let normalized_axis = axis.scale(1.0 / axis_length)
        let sin_half_angle = libm.sinf(half_angle)
        let cos_half_angle = libm.cosf(half_angle)
        return rl.Vector4(
            x = normalized_axis.x * sin_half_angle,
            y = normalized_axis.y * sin_half_angle,
            z = normalized_axis.z * sin_half_angle,
            w = cos_half_angle,
        ).normalize()


    pub static def from_matrix(mat: Matrix) -> Quaternion:
        let four_w_squared_minus_one = mat.m0 + mat.m5 + mat.m10
        let four_x_squared_minus_one = mat.m0 - mat.m5 - mat.m10
        let four_y_squared_minus_one = mat.m5 - mat.m0 - mat.m10
        let four_z_squared_minus_one = mat.m10 - mat.m0 - mat.m5

        var biggest_index = 0
        var four_biggest_squared_minus_one = four_w_squared_minus_one
        if four_x_squared_minus_one > four_biggest_squared_minus_one:
            four_biggest_squared_minus_one = four_x_squared_minus_one
            biggest_index = 1
        if four_y_squared_minus_one > four_biggest_squared_minus_one:
            four_biggest_squared_minus_one = four_y_squared_minus_one
            biggest_index = 2
        if four_z_squared_minus_one > four_biggest_squared_minus_one:
            four_biggest_squared_minus_one = four_z_squared_minus_one
            biggest_index = 3

        let biggest_value = libm.sqrtf(four_biggest_squared_minus_one + 1.0) * 0.5
        let mult = 0.25 / biggest_value

        if biggest_index == 0:
            return rl.Vector4(
                x = (mat.m6 - mat.m9) * mult,
                y = (mat.m8 - mat.m2) * mult,
                z = (mat.m1 - mat.m4) * mult,
                w = biggest_value,
            )
        if biggest_index == 1:
            return rl.Vector4(
                x = biggest_value,
                y = (mat.m1 + mat.m4) * mult,
                z = (mat.m8 + mat.m2) * mult,
                w = (mat.m6 - mat.m9) * mult,
            )
        if biggest_index == 2:
            return rl.Vector4(
                x = (mat.m1 + mat.m4) * mult,
                y = biggest_value,
                z = (mat.m6 + mat.m9) * mult,
                w = (mat.m8 - mat.m2) * mult,
            )
        return rl.Vector4(
            x = (mat.m8 + mat.m2) * mult,
            y = (mat.m6 + mat.m9) * mult,
            z = biggest_value,
            w = (mat.m1 - mat.m4) * mult,
        )


    pub def nlerp(other: Quaternion, amount: float) -> Quaternion:
        return rl.Vector4(
            x = this.x + amount * (other.x - this.x),
            y = this.y + amount * (other.y - this.y),
            z = this.z + amount * (other.z - this.z),
            w = this.w + amount * (other.w - this.w),
        ).normalize()


    pub def slerp(other: Quaternion, amount: float) -> Quaternion:
        var target = other
        var cos_half_theta = this.x * other.x + this.y * other.y + this.z * other.z + this.w * other.w

        if cos_half_theta < 0.0:
            target.x = -target.x
            target.y = -target.y
            target.z = -target.z
            target.w = -target.w
            cos_half_theta = -cos_half_theta

        if libm.fabsf(cos_half_theta) >= 1.0:
            return this
        if cos_half_theta > quaternion_slerp_linear_threshold:
            return this.nlerp(target, amount)

        let half_theta = libm.acosf(cos_half_theta)
        let sin_half_theta = libm.sqrtf(1.0 - cos_half_theta * cos_half_theta)
        if libm.fabsf(sin_half_theta) < quaternion_slerp_epsilon:
            return rl.Vector4(
                x = this.x * 0.5 + target.x * 0.5,
                y = this.y * 0.5 + target.y * 0.5,
                z = this.z * 0.5 + target.z * 0.5,
                w = this.w * 0.5 + target.w * 0.5,
            )

        let ratio_a = libm.sinf((1.0 - amount) * half_theta) / sin_half_theta
        let ratio_b = libm.sinf(amount * half_theta) / sin_half_theta
        return rl.Vector4(
            x = this.x * ratio_a + target.x * ratio_b,
            y = this.y * ratio_a + target.y * ratio_b,
            z = this.z * ratio_a + target.z * ratio_b,
            w = this.w * ratio_a + target.w * ratio_b,
        )
