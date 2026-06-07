import std.math as math

# ---------------------------------------------------------------------------
#  vec2 — 2-dimensional float vector
# ---------------------------------------------------------------------------

extending vec2:
    public static function zero() -> vec2:
        return zero[vec2]

    public static function fill(value: float) -> vec2:
        var result = zero[vec2]
        result.x = value
        result.y = value
        return result

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
        var result = zero[vec3]
        result.x = value
        result.y = value
        result.z = value
        return result

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
        var result = zero[vec3]
        result.x = this.y * v.z - this.z * v.y
        result.y = this.z * v.x - this.x * v.z
        result.z = this.x * v.y - this.y * v.x
        return result

    public function lerp(target: vec3, t: float) -> vec3:
        return this + (target - this) * t

# ---------------------------------------------------------------------------
#  vec4 — 4-dimensional float vector
# ---------------------------------------------------------------------------

extending vec4:
    public static function zero() -> vec4:
        return zero[vec4]

    public static function fill(value: float) -> vec4:
        var result = zero[vec4]
        result.x = value
        result.y = value
        result.z = value
        result.w = value
        return result

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
        var m = zero[mat3]
        m.col0.x = 1.0
        m.col1.y = 1.0
        m.col2.z = 1.0
        return m

    public function transpose() -> mat3:
        var result = zero[mat3]
        result.col0.x = this.col0.x
        result.col0.y = this.col1.x
        result.col0.z = this.col2.x
        result.col1.x = this.col0.y
        result.col1.y = this.col1.y
        result.col1.z = this.col2.y
        result.col2.x = this.col0.z
        result.col2.y = this.col1.z
        result.col2.z = this.col2.z
        return result

# ---------------------------------------------------------------------------
#  mat4 — 4×4 column-major matrix
# ---------------------------------------------------------------------------

extending mat4:
    public static function identity() -> mat4:
        var m = zero[mat4]
        m.col0.x = 1.0
        m.col1.y = 1.0
        m.col2.z = 1.0
        m.col3.w = 1.0
        return m

    public function transpose() -> mat4:
        var result = zero[mat4]
        result.col0.x = this.col0.x
        result.col0.y = this.col1.x
        result.col0.z = this.col2.x
        result.col0.w = this.col3.x
        result.col1.x = this.col0.y
        result.col1.y = this.col1.y
        result.col1.z = this.col2.y
        result.col1.w = this.col3.y
        result.col2.x = this.col0.z
        result.col2.y = this.col1.z
        result.col2.z = this.col2.z
        result.col2.w = this.col3.z
        result.col3.x = this.col0.w
        result.col3.y = this.col1.w
        result.col3.z = this.col2.w
        result.col3.w = this.col3.w
        return result

# ---------------------------------------------------------------------------
#  quat — quaternion
# ---------------------------------------------------------------------------

extending quat:
    public static function identity() -> quat:
        var q = zero[quat]
        q.w = 1.0
        return q

    public function conjugate() -> quat:
        var result = zero[quat]
        result.x = -this.x
        result.y = -this.y
        result.z = -this.z
        result.w = this.w
        return result
