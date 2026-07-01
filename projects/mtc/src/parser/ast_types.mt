import std.vec

public struct Import:
    path: str
    alias: str

public struct Param:
    name: str
    param_type: str

public variant Decl:
    import_decl(path: str, alias: str, head_start: ptr_uint, head_end: ptr_uint)
    attribute_decl(name: str, head_start: ptr_uint, head_end: ptr_uint)
    const_decl(name: str, const_type: str, has_block_body: bool, is_const_fn: bool, head_start: ptr_uint, head_end: ptr_uint, body_start: ptr_uint, body_end: ptr_uint)
    var_decl(name: str, var_type: str, head_start: ptr_uint, head_end: ptr_uint)
    type_alias(name: str, target: str, head_start: ptr_uint, head_end: ptr_uint)
    struct_decl(name: str, type_params: str, head_start: ptr_uint, head_end: ptr_uint, body_start: ptr_uint, body_end: ptr_uint)
    union_decl(name: str, head_start: ptr_uint, head_end: ptr_uint, body_start: ptr_uint, body_end: ptr_uint)
    enum_decl(name: str, backing: str, head_start: ptr_uint, head_end: ptr_uint, body_start: ptr_uint, body_end: ptr_uint)
    flags_decl(name: str, backing: str, head_start: ptr_uint, head_end: ptr_uint, body_start: ptr_uint, body_end: ptr_uint)
    variant_decl(name: str, type_params: str, head_start: ptr_uint, head_end: ptr_uint, body_start: ptr_uint, body_end: ptr_uint)
    opaque_decl(name: str, head_start: ptr_uint, head_end: ptr_uint)
    interface_decl(name: str, type_params: str, head_start: ptr_uint, head_end: ptr_uint, body_start: ptr_uint, body_end: ptr_uint)
    extending_block(target: str, head_start: ptr_uint, head_end: ptr_uint, body_start: ptr_uint, body_end: ptr_uint)
    function_decl(name: str, type_params: str, params: str, return_type: str, is_async: bool, is_foreign: bool, is_const: bool, head_start: ptr_uint, head_end: ptr_uint, body_start: ptr_uint, body_end: ptr_uint)
    extern_function(name: str, params: str, return_type: str, head_start: ptr_uint, head_end: ptr_uint)
    static_assert_decl(condition: str, message: str, head_start: ptr_uint, head_end: ptr_uint)
    when_block(discriminant_text: str, head_start: ptr_uint, head_end: ptr_uint, body_start: ptr_uint, body_end: ptr_uint)
    event_decl(name: str, payload: str, head_start: ptr_uint, head_end: ptr_uint)
    empty
