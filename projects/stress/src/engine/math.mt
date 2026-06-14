## engine/math.mt — native vector, matrix, quaternion types + SoA + str_buffer + format

import std.linear_algebra

# ---------------------------------------------------------------------------
# Native type arithmetic
# ---------------------------------------------------------------------------

public function vector_math_demo() -> float:
    let v2 = vec2(x = 1.0, y = 2.0)
    let v3 = vec3(x = 1.0, y = 2.0, z = 3.0)
    let v4 = vec4(x = 1.0, y = 2.0, z = 3.0, w = 4.0)

    let iv2 = ivec2(x = 1, y = 2)
    let iv3 = ivec3(x = 1, y = 2, z = 3)

    # component-wise same-type arithmetic
    let vsum = v3 + v3
    let vdiff = v3 - v3
    let vmul = v3 * v3
    let vneg = -v3

    # scalar arithmetic
    let scaled = v3 * 2.0
    let reversed = 3.0 * v3
    let divided = v3 / 2.0

    # integer vectors
    let isum = iv3 + iv3
    let iscaled = iv3 * 3
    let ineg = -iv3

    # vector from std.linear_algebra
    let dot_val = v3.dot(v3)
    let len_val = v3.length()

    # cross product
    let cross_val = v3.cross(v3)

    return (
        vsum.x + vdiff.y + vmul.z
        + vneg.x + scaled.y + reversed.z + divided.x
        + float<-(isum.x) + float<-(iscaled.y) + float<-(ineg.z)
        + dot_val + len_val + cross_val.x
        + v2.x + v2.y + v4.w + float<-(iv2.x) + float<-(iv2.y)
    )

# ---------------------------------------------------------------------------
# Matrix types
# ---------------------------------------------------------------------------

public function matrix_math_demo() -> float:
    let m3 = mat3(
        col0 = vec3(x = 1.0, y = 0.0, z = 0.0),
        col1 = vec3(x = 0.0, y = 1.0, z = 0.0),
        col2 = vec3(x = 0.0, y = 0.0, z = 1.0),
    )
    let m4 = mat4(
        col0 = vec4(x = 1.0, y = 0.0, z = 0.0, w = 0.0),
        col1 = vec4(x = 0.0, y = 1.0, z = 0.0, w = 0.0),
        col2 = vec4(x = 0.0, y = 0.0, z = 1.0, w = 0.0),
        col3 = vec4(x = 0.0, y = 0.0, z = 0.0, w = 1.0),
    )

    let msum = m4 + m4
    let mdiff = m4 - m4
    let mscaled = m4 * 2.0
    let mneg = -m4
    let identity_mat = mat4.identity()

    let _m3 = m3

    return msum.col0.x + mdiff.col1.y + mscaled.col2.z + mneg.col3.w + identity_mat.col0.x

# ---------------------------------------------------------------------------
# Quaternion
# ---------------------------------------------------------------------------

public function quat_math_demo() -> float:
    let q = quat(x = 0.0, y = 0.0, z = 0.0, w = 1.0)
    let qsum = q + q
    let qneg = -q
    let identity_quat = quat.identity()

    return qsum.x + qneg.y + identity_quat.w

# ---------------------------------------------------------------------------
# SoA (Structure-of-Arrays)
# ---------------------------------------------------------------------------

struct Point3D:
    x: double
    y: double
    z: double

public function soa_math_demo() -> float:
    var points: SoA[Point3D, 4]
    points[0].x = 1.0
    points[0].y = 2.0
    points[1].x = 3.0
    points[1].y = 4.0
    points[2].x = 5.0
    points[3].x = 6.0

    # read back
    let p0x = points[0].x
    let p1x = points[1].x
    let p2x = points[2].x
    let p3x = points[3].x
    let p0y = points[0].y

    return float<-(p0x + p1x + p2x + p3x + p0y)

# ---------------------------------------------------------------------------
# str_buffer usage
# ---------------------------------------------------------------------------

public function str_buffer_math_demo() -> str:
    var buf: str_buffer[64]
    buf.assign("score=")
    buf.append("100")
    buf.append_format(f"+#{50}")

    let s = buf.as_str()
    let _c = buf.as_cstr()
    let len = buf.len()
    let cap = buf.capacity()

    buf.clear()
    return s

# ---------------------------------------------------------------------------
# Format string with all specifiers and interpolation kinds
# ---------------------------------------------------------------------------

public function format_strings_demo(value: int, fraction: double) -> str:
    let hex = f"hex=#{value:x}"
    let hex_upper = f"hex_upper=#{value:X}"
    let octal = f"oct=#{value:o}"
    let octal_upper = f"oct_upper=#{value:O}"
    let binary = f"bin=#{value:b}"
    let binary_upper = f"bin_upper=#{value:B}"
    let precise = f"precise=#{fraction:.4}"
    let combined = f"#{hex} #{precise}"

    let _h = hex_upper
    let _o = octal
    let _ou = octal_upper
    let _b = binary
    let _bu = binary_upper

    return combined

# ---------------------------------------------------------------------------
# Heredoc strings
# ---------------------------------------------------------------------------

public function heredoc_demo() -> str:
    let block = <<-TEXT
    line one
    line two
    TEXT
    return block
