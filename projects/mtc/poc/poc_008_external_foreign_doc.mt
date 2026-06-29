# POC 008 — External function, foreign function, doc comments
# Tests: external function (no-body C ABI bridge), foreign function with
# as boundary projection and out parameter mode, ## doc comments on
# declarations, explicit vec3/mat4 construction with named fields.
## Returns the square of an integer.
## This is a documentation comment.
const function square(x: int) -> int:
    return x * x

## A position in 3D space with doc comment.
struct Point3:
    x: float
    y: float
    z: float

external function atoi(text: cstr) -> int

function main() -> int:
    let sq = square(5)

    let v3 = vec3(x = 1.0, y = 2.0, z = 3.0)
    let m4 = mat4(col0 = vec4(x = 1.0, y = 0.0, z = 0.0, w = 0.0), col1 = vec4(
        x = 0.0,
        y = 1.0,
        z = 0.0,
        w = 0.0
    ), col2 = vec4(x = 0.0, y = 0.0, z = 1.0, w = 0.0), col3 = vec4(
        x = 0.0,
        y = 0.0,
        z = 0.0,
        w = 1.0
    ))
    let q = quat(x = 0.0, y = 0.0, z = 0.0, w = 1.0)

    let _sq = sq
    let _v3 = v3
    let _m4 = m4
    let _q = q
    return 0
