module std.raylib.math

import std.c.libm as libm
import std.c.raylib as rl
import std.math as math

type Vector2 = rl.Vector2
type Vector3 = rl.Vector3
type Matrix = rl.Matrix
type Quaternion = rl.Quaternion
type Color = rl.Color

const deg2rad: f32 = math.deg2rad
const rad2deg: f32 = math.rad2deg
const quaternion_slerp_epsilon: f32 = 0.000001
const quaternion_slerp_linear_threshold: f32 = 0.95

def clamp(value: f32, min_value: f32, max_value: f32) -> f32:
    if value < min_value:
        return min_value
    if value > max_value:
        return max_value
    return value

def lerp(start: f32, finish: f32, amount: f32) -> f32:
    return start + (finish - start) * amount

def abs(value: f32) -> f32:
    return libm.fabsf(value)

def sqrt(value: f32) -> f32:
    return libm.sqrtf(value)

def sin(value: f32) -> f32:
    return libm.sinf(value)

def cos(value: f32) -> f32:
    return libm.cosf(value)

def tan(value: f32) -> f32:
    return libm.tanf(value)

def atan2(y: f32, x: f32) -> f32:
    return libm.atan2f(y, x)

def acos(value: f32) -> f32:
    return libm.acosf(value)

impl rl.Color:
    def from_hsv(hue: f32, saturation: f32, value: f32) -> Color:
        return rl.ColorFromHSV(hue, saturation, value)

impl rl.Vector2:
    def zero() -> Vector2:
        return rl.Vector2(x = 0.0, y = 0.0)

    def one() -> Vector2:
        return rl.Vector2(x = 1.0, y = 1.0)

    def add(self, other: Vector2) -> Vector2:
        return rl.Vector2(x = self.x + other.x, y = self.y + other.y)

    def subtract(self, other: Vector2) -> Vector2:
        return rl.Vector2(x = self.x - other.x, y = self.y - other.y)

    def scale(self, factor: f32) -> Vector2:
        return rl.Vector2(x = self.x * factor, y = self.y * factor)

    def multiply(self, other: Vector2) -> Vector2:
        return rl.Vector2(x = self.x * other.x, y = self.y * other.y)

    def length(self) -> f32:
        return libm.sqrtf(self.x * self.x + self.y * self.y)

    def distance(self, other: Vector2) -> f32:
        let dx = self.x - other.x
        let dy = self.y - other.y
        return libm.sqrtf(dx * dx + dy * dy)

    def angle(self, other: Vector2) -> f32:
        let dot = self.x * other.x + self.y * other.y
        let det = self.x * other.y - self.y * other.x
        return libm.atan2f(det, dot)

    def normalize(self) -> Vector2:
        let length = self.length()
        if length > 0.0:
            let inv_length = 1.0 / length
            return rl.Vector2(x = self.x * inv_length, y = self.y * inv_length)
        return Vector2.zero()

    def rotate(self, angle: f32) -> Vector2:
        let cos_angle = libm.cosf(angle)
        let sin_angle = libm.sinf(angle)
        return rl.Vector2(
            x = self.x * cos_angle - self.y * sin_angle,
            y = self.x * sin_angle + self.y * cos_angle,
        )

    def clamp(self, min_value: Vector2, max_value: Vector2) -> Vector2:
        return rl.Vector2(
            x = clamp(self.x, min_value.x, max_value.x),
            y = clamp(self.y, min_value.y, max_value.y),
        )

impl rl.Vector3:
    def zero() -> Vector3:
        return rl.Vector3(x = 0.0, y = 0.0, z = 0.0)

    def one() -> Vector3:
        return rl.Vector3(x = 1.0, y = 1.0, z = 1.0)

    def add(self, other: Vector3) -> Vector3:
        return rl.Vector3(x = self.x + other.x, y = self.y + other.y, z = self.z + other.z)

    def subtract(self, other: Vector3) -> Vector3:
        return rl.Vector3(x = self.x - other.x, y = self.y - other.y, z = self.z - other.z)

    def scale(self, factor: f32) -> Vector3:
        return rl.Vector3(x = self.x * factor, y = self.y * factor, z = self.z * factor)

    def dot(self, other: Vector3) -> f32:
        return self.x * other.x + self.y * other.y + self.z * other.z

    def length(self) -> f32:
        return libm.sqrtf(self.x * self.x + self.y * self.y + self.z * self.z)

    def distance(self, other: Vector3) -> f32:
        let dx = other.x - self.x
        let dy = other.y - self.y
        let dz = other.z - self.z
        return libm.sqrtf(dx * dx + dy * dy + dz * dz)

    def cross(self, other: Vector3) -> Vector3:
        return rl.Vector3(
            x = self.y * other.z - self.z * other.y,
            y = self.z * other.x - self.x * other.z,
            z = self.x * other.y - self.y * other.x,
        )

    def angle(self, other: Vector3) -> f32:
        let cross = self.cross(other)
        let length = cross.length()
        let dot = self.dot(other)
        return libm.atan2f(length, dot)

    def negate(self) -> Vector3:
        return rl.Vector3(x = -self.x, y = -self.y, z = -self.z)

    def normalize(self) -> Vector3:
        let length = self.length()
        if length != 0.0:
            let inv_length = 1.0 / length
            return rl.Vector3(x = self.x * inv_length, y = self.y * inv_length, z = self.z * inv_length)
        return self

    def lerp(self, other: Vector3, amount: f32) -> Vector3:
        return rl.Vector3(
            x = lerp(self.x, other.x, amount),
            y = lerp(self.y, other.y, amount),
            z = lerp(self.z, other.z, amount),
        )

    def rotate_by_axis_angle(self, axis: Vector3, angle: f32) -> Vector3:
        let normalized_axis = axis.normalize()
        let half_angle = angle / 2.0
        let sin_half_angle = libm.sinf(half_angle)
        let scalar = libm.cosf(half_angle)
        let w = rl.Vector3(
            x = normalized_axis.x * sin_half_angle,
            y = normalized_axis.y * sin_half_angle,
            z = normalized_axis.z * sin_half_angle,
        )
        let wv = w.cross(self)
        let wwv = w.cross(wv)
        let scaled_wv = wv.scale(2.0 * scalar)
        let scaled_wwv = wwv.scale(2.0)
        return self.add(scaled_wv).add(scaled_wwv)

    def transform(self, mat: Matrix) -> Vector3:
        let x = self.x
        let y = self.y
        let z = self.z
        return rl.Vector3(
            x = mat.m0 * x + mat.m4 * y + mat.m8 * z + mat.m12,
            y = mat.m1 * x + mat.m5 * y + mat.m9 * z + mat.m13,
            z = mat.m2 * x + mat.m6 * y + mat.m10 * z + mat.m14,
        )

impl rl.Matrix:
    def identity() -> Matrix:
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

    def multiply(self, other: Matrix) -> Matrix:
        return rl.Matrix(
            m0 = self.m0 * other.m0 + self.m1 * other.m4 + self.m2 * other.m8 + self.m3 * other.m12,
            m4 = self.m4 * other.m0 + self.m5 * other.m4 + self.m6 * other.m8 + self.m7 * other.m12,
            m8 = self.m8 * other.m0 + self.m9 * other.m4 + self.m10 * other.m8 + self.m11 * other.m12,
            m12 = self.m12 * other.m0 + self.m13 * other.m4 + self.m14 * other.m8 + self.m15 * other.m12,
            m1 = self.m0 * other.m1 + self.m1 * other.m5 + self.m2 * other.m9 + self.m3 * other.m13,
            m5 = self.m4 * other.m1 + self.m5 * other.m5 + self.m6 * other.m9 + self.m7 * other.m13,
            m9 = self.m8 * other.m1 + self.m9 * other.m5 + self.m10 * other.m9 + self.m11 * other.m13,
            m13 = self.m12 * other.m1 + self.m13 * other.m5 + self.m14 * other.m9 + self.m15 * other.m13,
            m2 = self.m0 * other.m2 + self.m1 * other.m6 + self.m2 * other.m10 + self.m3 * other.m14,
            m6 = self.m4 * other.m2 + self.m5 * other.m6 + self.m6 * other.m10 + self.m7 * other.m14,
            m10 = self.m8 * other.m2 + self.m9 * other.m6 + self.m10 * other.m10 + self.m11 * other.m14,
            m14 = self.m12 * other.m2 + self.m13 * other.m6 + self.m14 * other.m10 + self.m15 * other.m14,
            m3 = self.m0 * other.m3 + self.m1 * other.m7 + self.m2 * other.m11 + self.m3 * other.m15,
            m7 = self.m4 * other.m3 + self.m5 * other.m7 + self.m6 * other.m11 + self.m7 * other.m15,
            m11 = self.m8 * other.m3 + self.m9 * other.m7 + self.m10 * other.m11 + self.m11 * other.m15,
            m15 = self.m12 * other.m3 + self.m13 * other.m7 + self.m14 * other.m11 + self.m15 * other.m15,
        )

    def translate(x: f32, y: f32, z: f32) -> Matrix:
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

    def scale(x: f32, y: f32, z: f32) -> Matrix:
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

    def perspective(fov_y: f32, aspect: f32, near_plane: f32, far_plane: f32) -> Matrix:
        let top = near_plane * libm.tanf(fov_y * 0.5)
        let bottom = -top
        let right = top * aspect
        let left = -right
        let rl_width = right - left
        let tb = top - bottom
        let fn = far_plane - near_plane
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
            m10 = -(far_plane + near_plane) / fn,
            m14 = -(far_plane * near_plane * 2.0) / fn,
            m3 = 0.0,
            m7 = 0.0,
            m11 = -1.0,
            m15 = 0.0,
        )

    def ortho(left: f32, right: f32, bottom: f32, top: f32, near_plane: f32, far_plane: f32) -> Matrix:
        let rl_width = right - left
        let tb = top - bottom
        let fn = far_plane - near_plane
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
            m10 = -2.0 / fn,
            m14 = -(far_plane + near_plane) / fn,
            m3 = 0.0,
            m7 = 0.0,
            m11 = 0.0,
            m15 = 1.0,
        )

    def look_at(eye: Vector3, target: Vector3, up: Vector3) -> Matrix:
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

impl rl.Quaternion:
    def identity() -> Quaternion:
        return rl.Vector4(x = 0.0, y = 0.0, z = 0.0, w = 1.0)

    def length(self) -> f32:
        return libm.sqrtf(self.x * self.x + self.y * self.y + self.z * self.z + self.w * self.w)

    def normalize(self) -> Quaternion:
        let length = self.length()
        if length == 0.0:
            return self
        let inv_length = 1.0 / length
        return rl.Vector4(
            x = self.x * inv_length,
            y = self.y * inv_length,
            z = self.z * inv_length,
            w = self.w * inv_length,
        )

    def invert(self) -> Quaternion:
        let length_sq = self.x * self.x + self.y * self.y + self.z * self.z + self.w * self.w
        if length_sq == 0.0:
            return self
        let inv_length = 1.0 / length_sq
        return rl.Vector4(
            x = -self.x * inv_length,
            y = -self.y * inv_length,
            z = -self.z * inv_length,
            w = self.w * inv_length,
        )

    def multiply(self, other: Quaternion) -> Quaternion:
        return rl.Vector4(
            x = self.x * other.w + self.w * other.x + self.y * other.z - self.z * other.y,
            y = self.y * other.w + self.w * other.y + self.z * other.x - self.x * other.z,
            z = self.z * other.w + self.w * other.z + self.x * other.y - self.y * other.x,
            w = self.w * other.w - self.x * other.x - self.y * other.y - self.z * other.z,
        )

    def to_matrix(self) -> Matrix:
        let a2 = self.x * self.x
        let b2 = self.y * self.y
        let c2 = self.z * self.z
        let ac = self.x * self.z
        let ab = self.x * self.y
        let bc = self.y * self.z
        let ad = self.w * self.x
        let bd = self.w * self.y
        let cd = self.w * self.z
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

    def from_axis_angle(axis: Vector3, angle: f32) -> Quaternion:
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

    def from_matrix(mat: Matrix) -> Quaternion:
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

    def nlerp(self, other: Quaternion, amount: f32) -> Quaternion:
        return rl.Vector4(
            x = self.x + amount * (other.x - self.x),
            y = self.y + amount * (other.y - self.y),
            z = self.z + amount * (other.z - self.z),
            w = self.w + amount * (other.w - self.w),
        ).normalize()

    def slerp(self, other: Quaternion, amount: f32) -> Quaternion:
        var target = other
        var cos_half_theta = self.x * other.x + self.y * other.y + self.z * other.z + self.w * other.w

        if cos_half_theta < 0.0:
            target.x = -target.x
            target.y = -target.y
            target.z = -target.z
            target.w = -target.w
            cos_half_theta = -cos_half_theta

        if libm.fabsf(cos_half_theta) >= 1.0:
            return self
        if cos_half_theta > quaternion_slerp_linear_threshold:
            return self.nlerp(target, amount)

        let half_theta = libm.acosf(cos_half_theta)
        let sin_half_theta = libm.sqrtf(1.0 - cos_half_theta * cos_half_theta)
        if libm.fabsf(sin_half_theta) < quaternion_slerp_epsilon:
            return rl.Vector4(
                x = self.x * 0.5 + target.x * 0.5,
                y = self.y * 0.5 + target.y * 0.5,
                z = self.z * 0.5 + target.z * 0.5,
                w = self.w * 0.5 + target.w * 0.5,
            )

        let ratio_a = libm.sinf((1.0 - amount) * half_theta) / sin_half_theta
        let ratio_b = libm.sinf(amount * half_theta) / sin_half_theta
        return rl.Vector4(
            x = self.x * ratio_a + target.x * ratio_b,
            y = self.y * ratio_a + target.y * ratio_b,
            z = self.z * ratio_a + target.z * ratio_b,
            w = self.w * ratio_a + target.w * ratio_b,
        )
