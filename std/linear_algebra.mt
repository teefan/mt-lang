import std.math as math

# ---------------------------------------------------------------------------
#  vec2 — 2-dimensional float vector
# ---------------------------------------------------------------------------

extending vec2:
    public static function zero() -> vec2:
        return zero[vec2]


    public static function fill(value: float) -> vec2:
        return vec2(x = value, y = value)


    public function dot(v: vec2) -> float:
        return this.x * v.x + this.y * v.y


    public function length_squared() -> float:
        return this.dot(this)


    public function length() -> float:
        return float<-math.sqrt(double<-(this.length_squared()))


    public function normalized() -> vec2:
        let len = this.length()
        return this / len


    public function distance_squared_to(v: vec2) -> float:
        let dx = this.x - v.x
        let dy = this.y - v.y
        return dx * dx + dy * dy


    public function distance_to(v: vec2) -> float:
        return float<-math.sqrt(double<-(this.distance_squared_to(v)))


    public function lerp(target: vec2, t: float) -> vec2:
        return this + (target - this) * t

# ---------------------------------------------------------------------------
#  vec3 — 3-dimensional float vector
# ---------------------------------------------------------------------------

extending vec3:
    public static function zero() -> vec3:
        return zero[vec3]


    public static function fill(value: float) -> vec3:
        return vec3(x = value, y = value, z = value)


    public function dot(v: vec3) -> float:
        return this.x * v.x + this.y * v.y + this.z * v.z


    public function length_squared() -> float:
        return this.dot(this)


    public function length() -> float:
        return float<-math.sqrt(double<-(this.length_squared()))


    public function normalized() -> vec3:
        let len = this.length()
        return this / len


    public function distance_squared_to(v: vec3) -> float:
        let dx = this.x - v.x
        let dy = this.y - v.y
        let dz = this.z - v.z
        return dx * dx + dy * dy + dz * dz


    public function distance_to(v: vec3) -> float:
        return float<-math.sqrt(double<-(this.distance_squared_to(v)))


    public function cross(v: vec3) -> vec3:
        return vec3(
            x = this.y * v.z - this.z * v.y,
            y = this.z * v.x - this.x * v.z,
            z = this.x * v.y - this.y * v.x,
        )


    public function lerp(target: vec3, t: float) -> vec3:
        return this + (target - this) * t

# ---------------------------------------------------------------------------
#  vec4 — 4-dimensional float vector
# ---------------------------------------------------------------------------

extending vec4:
    public static function zero() -> vec4:
        return zero[vec4]


    public static function fill(value: float) -> vec4:
        return vec4(x = value, y = value, z = value, w = value)


    public function dot(v: vec4) -> float:
        return this.x * v.x + this.y * v.y + this.z * v.z + this.w * v.w


    public function length_squared() -> float:
        return this.dot(this)


    public function length() -> float:
        return float<-math.sqrt(double<-(this.length_squared()))


    public function normalized() -> vec4:
        let len = this.length()
        return this / len


    public function distance_squared_to(v: vec4) -> float:
        let dx = this.x - v.x
        let dy = this.y - v.y
        let dz = this.z - v.z
        let dw = this.w - v.w
        return dx * dx + dy * dy + dz * dz + dw * dw


    public function distance_to(v: vec4) -> float:
        return float<-math.sqrt(double<-(this.distance_squared_to(v)))


    public function lerp(target: vec4, t: float) -> vec4:
        return this + (target - this) * t

# ---------------------------------------------------------------------------
#  ivec2 — 2-dimensional integer vector
# ---------------------------------------------------------------------------

extending ivec2:
    public static function zero() -> ivec2:
        return zero[ivec2]


    public function dot(v: ivec2) -> int:
        return this.x * v.x + this.y * v.y


    public function length_squared() -> int:
        return this.dot(this)

# ---------------------------------------------------------------------------
#  ivec3 — 3-dimensional integer vector
# ---------------------------------------------------------------------------

extending ivec3:
    public static function zero() -> ivec3:
        return zero[ivec3]


    public function dot(v: ivec3) -> int:
        return this.x * v.x + this.y * v.y + this.z * v.z


    public function length_squared() -> int:
        return this.dot(this)

# ---------------------------------------------------------------------------
#  ivec4 — 4-dimensional integer vector
# ---------------------------------------------------------------------------

extending ivec4:
    public static function zero() -> ivec4:
        return zero[ivec4]


    public function dot(v: ivec4) -> int:
        return this.x * v.x + this.y * v.y + this.z * v.z + this.w * v.w


    public function length_squared() -> int:
        return this.dot(this)

# ---------------------------------------------------------------------------
#  mat3 — 3×3 column-major matrix
# ---------------------------------------------------------------------------

extending mat3:
    public static function identity() -> mat3:
        return mat3(
            col0 = vec3(x = 1.0, y = 0.0, z = 0.0),
            col1 = vec3(x = 0.0, y = 1.0, z = 0.0),
            col2 = vec3(x = 0.0, y = 0.0, z = 1.0),
        )


    public function transpose() -> mat3:
        return mat3(
            col0 = vec3(x = this.col0.x, y = this.col1.x, z = this.col2.x),
            col1 = vec3(x = this.col0.y, y = this.col1.y, z = this.col2.y),
            col2 = vec3(x = this.col0.z, y = this.col1.z, z = this.col2.z),
        )

# ---------------------------------------------------------------------------
#  mat4 — 4×4 column-major matrix
# ---------------------------------------------------------------------------

extending mat4:
    public static function identity() -> mat4:
        return mat4(
            col0 = vec4(x = 1.0, y = 0.0, z = 0.0, w = 0.0),
            col1 = vec4(x = 0.0, y = 1.0, z = 0.0, w = 0.0),
            col2 = vec4(x = 0.0, y = 0.0, z = 1.0, w = 0.0),
            col3 = vec4(x = 0.0, y = 0.0, z = 0.0, w = 1.0),
        )


    public function transpose() -> mat4:
        return mat4(
            col0 = vec4(x = this.col0.x, y = this.col1.x, z = this.col2.x, w = this.col3.x),
            col1 = vec4(x = this.col0.y, y = this.col1.y, z = this.col2.y, w = this.col3.y),
            col2 = vec4(x = this.col0.z, y = this.col1.z, z = this.col2.z, w = this.col3.z),
            col3 = vec4(x = this.col0.w, y = this.col1.w, z = this.col2.w, w = this.col3.w),
        )

# ---------------------------------------------------------------------------
#  quat — quaternion
# ---------------------------------------------------------------------------

extending quat:
    public static function identity() -> quat:
        return quat(x = 0.0, y = 0.0, z = 0.0, w = 1.0)


    public function conjugate() -> quat:
        return quat(x = -this.x, y = -this.y, z = -this.z, w = this.w)
