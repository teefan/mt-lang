## engine/compile.mt — compile-time evaluation, emit, when, inline, reflection

import engine.types as types

# ---------------------------------------------------------------------------
# const function — evaluable at compile time AND runtime
# ---------------------------------------------------------------------------

public const function fibonacci(n: int) -> int:
    if n <= 1:
        return n
    return fibonacci(n - 1) + fibonacci(n - 2)

public const FIB_10: int = fibonacci(10)

# ---------------------------------------------------------------------------
# Block-bodied const with compile-time loop
# ---------------------------------------------------------------------------

public const POW2_ABOVE_500 -> int:
    var n: int = 1
    while n < 512:
        n = n * 2
    return n

# ---------------------------------------------------------------------------
# FNV-1a hash computed at compile time over byte array
# ---------------------------------------------------------------------------

public const FNV_OFFSET: uint = 0x811c9dc5
public const FNV_PRIME: uint = 0x01000193

public const MAGIC_BYTES: array[ubyte, 8] = (0x53, 0x54, 0x52, 0x45, 0x53, 0x53, 0x30, 0x31)
public const MAGIC_HASH -> uint:
    var h = FNV_OFFSET
    for b in MAGIC_BYTES:
        h = (h ^ b) * FNV_PRIME
    return h

# ---------------------------------------------------------------------------
# when — compile-time conditional (only chosen branch type-checked)
# ---------------------------------------------------------------------------

enum Platform: ubyte
    linux = 1
    windows = 2
    wasm = 3

public const TARGET: Platform = Platform.linux

public function platform_name() -> str:
    when TARGET:
        Platform.linux:
            return "linux"
        Platform.windows:
            return "windows"
        Platform.wasm:
            return "wasm"

# ---------------------------------------------------------------------------
# inline for — compile-time unrolled loop over reflection results
# ---------------------------------------------------------------------------

public function all_transform_fields_are_double() -> bool:
    inline for field in fields_of(types.Transform):
        if field.type != double:
            return false
    return true

public function entity_kind_count() -> int:
    var count: int = 0
    inline for member in members_of(types.EntityKind):
        let _name = member.name
        count += 1
    return count

# ---------------------------------------------------------------------------
# inline while — compile-time bounded loop
# ---------------------------------------------------------------------------

public const NEXT_POW2 -> int:
    var n: int = 1
    inline while n < 256:
        n = n * 2
    return n

# ---------------------------------------------------------------------------
# inline match — compile-time dispatch
# ---------------------------------------------------------------------------

public const MODE: types.EntityKind = types.EntityKind.player

public function mode_label() -> str:
    inline match MODE:
        types.EntityKind.player:
            return "player_mode"
        types.EntityKind.enemy:
            return "enemy_mode"
        types.EntityKind.item:
            return "item_mode"
        types.EntityKind.projectile:
            return "projectile_mode"

# ---------------------------------------------------------------------------
# inline if — compile-time conditional with dead-branch elimination
# ---------------------------------------------------------------------------

public const DEBUG_ENABLED: bool = false

public function debug_log(message: str) -> void:
    inline if DEBUG_ENABLED:
        pass

# ---------------------------------------------------------------------------
# type-returning function (compile-time type selection)
# ---------------------------------------------------------------------------

public function int_for_bits[N: int]() -> type:
    if N == 8:
        return byte
    else if N == 16:
        return short
    else if N == 32:
        return int
    else if N == 64:
        return long
    static_assert(false, "unsupported bit width")

public const Int32: type = int_for_bits[32]

# ---------------------------------------------------------------------------
# has_attribute, attribute_arg — compile-time attribute reflection
# ---------------------------------------------------------------------------

static_assert(
    has_attribute(types.Header16, packed),
    "Header16 must be packed"
)

public function all_packed_attributes() -> int:
    var count: int = 0
    inline for attr in attributes_of(types.Header16):
        count += 1
    inline for attr in attributes_of(types.Header16, packed):
        count += 1
    return count

# ---------------------------------------------------------------------------
# Compile-time generic function using reflection
# ---------------------------------------------------------------------------

public function field_info[T]() -> str:
    var result: str = ""
    inline for field in fields_of(T):
        let info = f"#{field.name}=#{size_of(field.type)}"
        var _info = info
    return result

# ---------------------------------------------------------------------------
# Compile-time static_assert in const context
# ---------------------------------------------------------------------------

public const function verify_sizes() -> bool:
    static_assert(size_of(int) == 4, "int must be 4 bytes")
    static_assert(size_of(double) == 8, "double must be 8 bytes")
    return true

# ---------------------------------------------------------------------------
# when at module level — conditional top-level declaration
# ---------------------------------------------------------------------------

public function platform_suffix() -> str:
    when TARGET:
        Platform.linux:
            return ".so"
        Platform.windows:
            return ".dll"
        Platform.wasm:
            return ".wasm"

# ---------------------------------------------------------------------------
# Literal suffixes, underscores, deprecated, attributes_of
# ---------------------------------------------------------------------------

public const STRICT_FLOAT: float = 3.14f
public const STRICT_DOUBLE: double = 3.14d
public const ONE_MILLION: int = 1_000_000
public const HEX_WITH_SEP: uint = 0xff_ff_00_00

@[deprecated("use new_identity instead")]
public function identity_4x4() -> mat4:
    return mat4(
        col0 = vec4(x = 1.0, y = 0.0, z = 0.0, w = 0.0),
        col1 = vec4(x = 0.0, y = 1.0, z = 0.0, w = 0.0),
        col2 = vec4(x = 0.0, y = 0.0, z = 1.0, w = 0.0),
        col3 = vec4(x = 0.0, y = 0.0, z = 0.0, w = 1.0),
    )

# emit: compile-time code generation from const function
public const function generate_check() -> void:
    emit function compile_check() -> int:
        return 1
