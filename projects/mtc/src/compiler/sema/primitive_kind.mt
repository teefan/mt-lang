## PrimitiveKind enum — every built-in primitive type in Milk Tea.
##
## Used by the type registry and semantic analyzer to identify built-in types
## without string comparison.
##
## Prefix convention: `pk_` to avoid collisions with C keywords (int, float,
## void, char, etc.) and type alias names.

public enum PrimitiveKind: int
    pk_bool = 0
    pk_byte = 1
    pk_ubyte = 2
    pk_char = 3
    pk_short = 4
    pk_ushort = 5
    pk_int = 6
    pk_uint = 7
    pk_long = 8
    pk_ulong = 9
    pk_ptr_int = 10
    pk_ptr_uint = 11
    pk_float = 12
    pk_double = 13
    pk_void = 14
    pk_str = 15
    pk_cstr = 16

    # vector / matrix / quaternion
    pk_vec2 = 17
    pk_vec3 = 18
    pk_vec4 = 19
    pk_ivec2 = 20
    pk_ivec3 = 21
    pk_ivec4 = 22
    pk_mat3 = 23
    pk_mat4 = 24
    pk_quat = 25
