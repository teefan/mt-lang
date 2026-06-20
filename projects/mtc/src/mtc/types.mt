# Type system for the self-hosting Milk Tea compiler.
# Mirrors lib/milk_tea/core/types/types.rb and predicates.rb.
#
# Design: Type is a flat variant. Recursive type references use TypeId = ptr_uint
# indices into a TypeArena (vec.Vec[Type]). This avoids the infinite-size
# problem of directly recursive variants.

import std.vec
import std.str

# ── Type identification ──

public type TypeId = ptr_uint

# ═══════════════════════════════════════════════════════════════════════════════
# Type variant — all type kinds
# ═══════════════════════════════════════════════════════════════════════════════

public variant Type:
    # ── Primitives ──
    primitive(name: str)

    # ── Sentinels ──
    error_type

    # ── Type variables (for generics) ──
    type_var(name: str)
    lifetime_ref(name: str)
    literal_type_arg(value: str)

    # ── Null-related ──
    null_type(target: TypeId)
    nullable(base: TypeId)

    # ── Pointer-like ──
    pointer_type(pointee: TypeId)
    const_pointer_type(pointee: TypeId)
    ref_type(referent: TypeId, lifetime: str)

    # ── Composite ──
    array_type(element: TypeId, count: TypeId)
    span_type(element: TypeId)
    str_buffer_type(capacity: TypeId)
    atomic_type(inner: TypeId)

    # ── Async ──
    task_type(result: TypeId)

    # ── Callable ──
    proc_type(params_start: TypeId, params_len: TypeId, return_type: TypeId)
    fn_type(name: str, params_start: TypeId, params_len: TypeId, return_type: TypeId, receiver_type: TypeId, receiver_editable: bool, is_external: bool, variadic: bool)

    # ── Tuples ──
    tuple_type(element_types_start: TypeId, element_types_len: TypeId, field_names_start: TypeId, field_names_len: TypeId)

    # ── Dynamic dispatch ──
    dyn_type(interface_name: str, type_args_start: TypeId, type_args_len: TypeId)

    # ── SoA ──
    soa_type(element_type: TypeId, count: TypeId)

    # ── Native vector/matrix/quaternion ──
    vector_type(name: str)
    matrix_type(name: str)
    quaternion_type

    # ── Named struct types ──
    struct_type(name: str, module_name: str, packed: bool, alignment: int, is_external: bool, linkage_name: str)
    struct_instance(definition_id: TypeId, arguments_start: TypeId, arguments_len: TypeId)
    union_type(name: str, module_name: str)

    # ── Variant types ──
    variant_type(name: str, module_name: str)
    variant_instance(definition_id: TypeId, arguments_start: TypeId, arguments_len: TypeId)
    variant_arm_payload(variant_type_id: TypeId, arm_name: str)

    # ── Enum / Flags ──
    enum_type(name: str, module_name: str, backing_type: TypeId, is_external: bool)
    flags_type(name: str, module_name: str, backing_type: TypeId, is_external: bool)

    # ── Opaque ──
    opaque_type(name: str, module_name: str, linkage_name: str, is_external: bool)

    # ── Generic definitions ──
    generic_struct_def(name: str, type_params_start: TypeId, type_params_len: TypeId, module_name: str, is_external: bool, packed: bool, alignment: int, linkage_name: str)
    generic_variant_def(name: str, type_params_start: TypeId, type_params_len: TypeId, module_name: str)

    # ── Interface ──
    interface_type(name: str, module_name: str)
    generic_interface_def(name: str, type_params_start: TypeId, type_params_len: TypeId, module_name: str)
    interface_instance(definition_id: TypeId, arguments_start: TypeId, arguments_len: TypeId)

    # ── Events ──
    event_type(name: str, capacity: int, payload_type: TypeId, module_name: str, owner_type_name: str)

    # ── Built-in special ──
    string_view_type
    subscription_type
    handle_type

    # ── Reflection handle types (for compile-time reflection) ──
    field_handle_type
    struct_handle_type
    callable_handle_type
    attribute_handle_type
    member_handle_type
    type_meta_type

    # ── DynVtable (internal, for dyn dispatch lowering) ──
    dyn_vtable_type(interface_name: str)

# ── Type parameter representation ──

public struct TypeParamBinding:
    name: str
    constraints_start: TypeId
    constraints_len: TypeId

# ── Field descriptor for struct/union types ──

public struct FieldInfo:
    name: str
    field_type: TypeId

# ── Variant arm descriptor ──

public struct VariantArmInfo:
    name: str
    field_names_start: TypeId
    field_names_len: TypeId
    field_types_start: TypeId
    field_types_len: TypeId

# ── Enum/flags member ──

public struct EnumMemberInfo:
    name: str
    value: int

# ── Function parameter ──

public struct ParamInfo:
    name: str
    param_type: TypeId
    passing_mode: str
    boundary_type: TypeId

# ═══════════════════════════════════════════════════════════════════════════════
# TypeArena — owns all Type instances
# ═══════════════════════════════════════════════════════════════════════════════

public struct TypeArena:
    types: vec.Vec[Type]
    fields: vec.Vec[FieldInfo]
    variant_arms: vec.Vec[VariantArmInfo]
    enum_members: vec.Vec[EnumMemberInfo]
    params: vec.Vec[ParamInfo]
    type_params: vec.Vec[TypeParamBinding]
    type_id_lists: vec.Vec[TypeId]
    str_lists: vec.Vec[str]

extending TypeArena:
    public static function create() -> TypeArena:
        return TypeArena(
            types = vec.Vec[Type].create(),
            fields = vec.Vec[FieldInfo].create(),
            variant_arms = vec.Vec[VariantArmInfo].create(),
            enum_members = vec.Vec[EnumMemberInfo].create(),
            params = vec.Vec[ParamInfo].create(),
            type_params = vec.Vec[TypeParamBinding].create(),
            type_id_lists = vec.Vec[TypeId].create(),
            str_lists = vec.Vec[str].create(),
        )

    # ── Allocation ──

    public editable function alloc(ty: Type) -> TypeId:
        this.types.push(ty)
        return this.types.len - 1

    public function get(id: TypeId) -> Type:
        let t = this.types.at(id) else:
            return Type.error_type
        return t

    # ── Primitive type ids (memoized on first use) ──

    public editable function primitive_bool() -> TypeId:
        return this.ensure_primitive("bool")

    public editable function primitive_byte() -> TypeId:
        return this.ensure_primitive("byte")

    public editable function primitive_ubyte() -> TypeId:
        return this.ensure_primitive("ubyte")

    public editable function primitive_char() -> TypeId:
        return this.ensure_primitive("char")

    public editable function primitive_short() -> TypeId:
        return this.ensure_primitive("short")

    public editable function primitive_ushort() -> TypeId:
        return this.ensure_primitive("ushort")

    public editable function primitive_int() -> TypeId:
        return this.ensure_primitive("int")

    public editable function primitive_uint() -> TypeId:
        return this.ensure_primitive("uint")

    public editable function primitive_long() -> TypeId:
        return this.ensure_primitive("long")

    public editable function primitive_ulong() -> TypeId:
        return this.ensure_primitive("ulong")

    public editable function primitive_float() -> TypeId:
        return this.ensure_primitive("float")

    public editable function primitive_double() -> TypeId:
        return this.ensure_primitive("double")

    public editable function primitive_void() -> TypeId:
        return this.ensure_primitive("void")

    public editable function primitive_str() -> TypeId:
        return this.ensure_primitive("str")

    public editable function primitive_cstr() -> TypeId:
        return this.ensure_primitive("cstr")

    public editable function primitive_ptr_int() -> TypeId:
        return this.ensure_primitive("ptr_int")

    public editable function primitive_ptr_uint() -> TypeId:
        return this.ensure_primitive("ptr_uint")

    public editable function ensure_primitive(name: str) -> TypeId:
        var i: ptr_uint = 0
        while i < this.types.len:
            let t = this.types.at(i) else:
                i += 1
                continue
            match t:
                Type.primitive as p:
                    if p.name == name:
                        return i
                _:
                    pass
            i += 1
        return this.alloc(Type.primitive(name = name))

    # ── Arena allocation helpers ──

    public editable function alloc_pointer(pointee: TypeId) -> TypeId:
        return this.alloc(Type.pointer_type(pointee = pointee))

    public editable function alloc_const_pointer(pointee: TypeId) -> TypeId:
        return this.alloc(Type.const_pointer_type(pointee = pointee))

    public editable function alloc_ref(referent: TypeId) -> TypeId:
        return this.alloc(Type.ref_type(referent = referent, lifetime = ""))

    public editable function alloc_nullable(base: TypeId) -> TypeId:
        return this.alloc(Type.nullable(base = base))

    public editable function alloc_array(element: TypeId, count: TypeId) -> TypeId:
        return this.alloc(Type.array_type(element = element, count = count))

    public editable function alloc_span(element: TypeId) -> TypeId:
        return this.alloc(Type.span_type(element = element))

    public editable function alloc_error() -> TypeId:
        return this.alloc(Type.error_type)

    # ── Comparison (structural) ──

    public function types_eq(a_id: TypeId, b_id: TypeId) -> bool:
        if a_id == b_id:
            return true
        let a = this.get(a_id)
        let b = this.get(b_id)
        return this.types_variant_eq(a, b)

    function types_variant_eq(a: Type, b: Type) -> bool:
        # Use 'as name' bindings for all arms.  Struct-pattern field names
        # must match the variant arm field names exactly; some field names
        # collide with keywords, so 'as name' is more robust here.
        match a:
            Type.primitive as pa:
                match b:
                    Type.primitive as pb:
                        return pa.name == pb.name
                    _:
                        return false
            Type.error_type:
                match b:
                    Type.error_type:
                        return true
                    _:
                        return false
            Type.type_var as tv_a:
                match b:
                    Type.type_var as tv_b:
                        return tv_a.name == tv_b.name
                    _:
                        return false
            Type.lifetime_ref as lr_a:
                match b:
                    Type.lifetime_ref as lr_b:
                        return lr_a.name == lr_b.name
                    _:
                        return false
            Type.literal_type_arg as la:
                match b:
                    Type.literal_type_arg as lb:
                        return la.value == lb.value
                    _:
                        return false
            Type.null_type as na:
                match b:
                    Type.null_type as nb:
                        return this.types_eq(na.target, nb.target)
                    _:
                        return false
            Type.nullable as na:
                match b:
                    Type.nullable as nb:
                        return this.types_eq(na.base, nb.base)
                    _:
                        return false
            Type.pointer_type as pa:
                match b:
                    Type.pointer_type as pb:
                        return this.types_eq(pa.pointee, pb.pointee)
                    _:
                        return false
            Type.const_pointer_type as pa:
                match b:
                    Type.const_pointer_type as pb:
                        return this.types_eq(pa.pointee, pb.pointee)
                    _:
                        return false
            Type.ref_type as ra:
                match b:
                    Type.ref_type as rb:
                        return this.types_eq(ra.referent, rb.referent) and ra.lifetime == rb.lifetime
                    _:
                        return false
            Type.array_type as aa:
                match b:
                    Type.array_type as ba:
                        return this.types_eq(aa.element, ba.element) and this.types_eq(aa.count, ba.count)
                    _:
                        return false
            Type.span_type as sa:
                match b:
                    Type.span_type as sb:
                        return this.types_eq(sa.element, sb.element)
                    _:
                        return false
            Type.str_buffer_type as sa:
                match b:
                    Type.str_buffer_type as sb:
                        return this.types_eq(sa.capacity, sb.capacity)
                    _:
                        return false
            Type.atomic_type as aa:
                match b:
                    Type.atomic_type as ba:
                        return this.types_eq(aa.inner, ba.inner)
                    _:
                        return false
            Type.task_type as ta:
                match b:
                    Type.task_type as tb:
                        return this.types_eq(ta.result, tb.result)
                    _:
                        return false
            Type.proc_type as pa:
                match b:
                    Type.proc_type as pb:
                        return this.params_eq(pa.params_start, pa.params_len, pb.params_start, pb.params_len) and this.types_eq(pa.return_type, pb.return_type)
                    _:
                        return false
            Type.fn_type as fa:
                match b:
                    Type.fn_type as fb:
                        return fa.name == fb.name and this.params_eq(fa.params_start, fa.params_len, fb.params_start, fb.params_len) and this.types_eq(fa.return_type, fb.return_type) and this.types_eq(fa.receiver_type, fb.receiver_type) and fa.receiver_editable == fb.receiver_editable and fa.is_external == fb.is_external and fa.variadic == fb.variadic
                    _:
                        return false
            Type.tuple_type as ta:
                match b:
                    Type.tuple_type as tb:
                        return this.type_id_lists_eq(ta.element_types_start, ta.element_types_len, tb.element_types_start, tb.element_types_len) and this.str_lists_eq(ta.field_names_start, ta.field_names_len, tb.field_names_start, tb.field_names_len)
                    _:
                        return false
            Type.dyn_type as da:
                match b:
                    Type.dyn_type as db:
                        return da.interface_name == db.interface_name and this.type_id_lists_eq(da.type_args_start, da.type_args_len, db.type_args_start, db.type_args_len)
                    _:
                        return false
            Type.soa_type as sa:
                match b:
                    Type.soa_type as sb:
                        return this.types_eq(sa.element_type, sb.element_type) and this.types_eq(sa.count, sb.count)
                    _:
                        return false
            Type.vector_type as va:
                match b:
                    Type.vector_type as vb:
                        return va.name == vb.name
                    _:
                        return false
            Type.matrix_type as ma:
                match b:
                    Type.matrix_type as mb:
                        return ma.name == mb.name
                    _:
                        return false
            Type.quaternion_type:
                match b:
                    Type.quaternion_type:
                        return true
                    _:
                        return false
            Type.string_view_type:
                match b:
                    Type.string_view_type:
                        return true
                    _:
                        return false
            Type.subscription_type:
                match b:
                    Type.subscription_type:
                        return true
                    _:
                        return false
            Type.handle_type:
                match b:
                    Type.handle_type:
                        return true
                    _:
                        return false
            Type.field_handle_type:
                match b:
                    Type.field_handle_type:
                        return true
                    _:
                        return false
            Type.struct_handle_type:
                match b:
                    Type.struct_handle_type:
                        return true
                    _:
                        return false
            Type.callable_handle_type:
                match b:
                    Type.callable_handle_type:
                        return true
                    _:
                        return false
            Type.attribute_handle_type:
                match b:
                    Type.attribute_handle_type:
                        return true
                    _:
                        return false
            Type.member_handle_type:
                match b:
                    Type.member_handle_type:
                        return true
                    _:
                        return false
            Type.type_meta_type:
                match b:
                    Type.type_meta_type:
                        return true
                    _:
                        return false
            Type.struct_type as sa:
                match b:
                    Type.struct_type as sb:
                        return sa.name == sb.name and sa.module_name == sb.module_name and sa.packed == sb.packed and sa.alignment == sb.alignment and sa.is_external == sb.is_external and sa.linkage_name == sb.linkage_name
                    _:
                        return false
            Type.struct_instance as sa:
                match b:
                    Type.struct_instance as sb:
                        if not this.types_eq(sa.definition_id, sb.definition_id):
                            return false
                        return this.type_id_lists_eq(sa.arguments_start, sa.arguments_len, sb.arguments_start, sb.arguments_len)
                    _:
                        return false
            Type.union_type as ua:
                match b:
                    Type.union_type as ub:
                        return ua.name == ub.name and ua.module_name == ub.module_name
                    _:
                        return false
            Type.variant_type as va:
                match b:
                    Type.variant_type as vb:
                        return va.name == vb.name and va.module_name == vb.module_name
                    _:
                        return false
            Type.variant_instance as va:
                match b:
                    Type.variant_instance as vb:
                        if not this.types_eq(va.definition_id, vb.definition_id):
                            return false
                        return this.type_id_lists_eq(va.arguments_start, va.arguments_len, vb.arguments_start, vb.arguments_len)
                    _:
                        return false
            Type.variant_arm_payload as va:
                match b:
                    Type.variant_arm_payload as vb:
                        return this.types_eq(va.variant_type_id, vb.variant_type_id) and va.arm_name == vb.arm_name
                    _:
                        return false
            Type.enum_type as ea:
                match b:
                    Type.enum_type as eb:
                        return ea.name == eb.name and ea.module_name == eb.module_name and this.types_eq(ea.backing_type, eb.backing_type) and ea.is_external == eb.is_external
                    _:
                        return false
            Type.flags_type as fa:
                match b:
                    Type.flags_type as fb:
                        return fa.name == fb.name and fa.module_name == fb.module_name and this.types_eq(fa.backing_type, fb.backing_type) and fa.is_external == fb.is_external
                    _:
                        return false
            Type.opaque_type as oa:
                match b:
                    Type.opaque_type as ob:
                        return oa.name == ob.name and oa.module_name == ob.module_name and oa.linkage_name == ob.linkage_name and oa.is_external == ob.is_external
                    _:
                        return false
            Type.generic_struct_def as ga:
                match b:
                    Type.generic_struct_def as gb:
                        return ga.name == gb.name and this.type_params_eq(ga.type_params_start, ga.type_params_len, gb.type_params_start, gb.type_params_len) and ga.module_name == gb.module_name and ga.is_external == gb.is_external and ga.packed == gb.packed and ga.alignment == gb.alignment and ga.linkage_name == gb.linkage_name
                    _:
                        return false
            Type.generic_variant_def as ga:
                match b:
                    Type.generic_variant_def as gb:
                        return ga.name == gb.name and this.type_params_eq(ga.type_params_start, ga.type_params_len, gb.type_params_start, gb.type_params_len) and ga.module_name == gb.module_name
                    _:
                        return false
            Type.interface_type as ia:
                match b:
                    Type.interface_type as ib:
                        return ia.name == ib.name and ia.module_name == ib.module_name
                    _:
                        return false
            Type.generic_interface_def as ga:
                match b:
                    Type.generic_interface_def as gb:
                        return ga.name == gb.name and this.type_params_eq(ga.type_params_start, ga.type_params_len, gb.type_params_start, gb.type_params_len) and ga.module_name == gb.module_name
                    _:
                        return false
            Type.interface_instance as ia:
                match b:
                    Type.interface_instance as ib:
                        if not this.types_eq(ia.definition_id, ib.definition_id):
                            return false
                        return this.type_id_lists_eq(ia.arguments_start, ia.arguments_len, ib.arguments_start, ib.arguments_len)
                    _:
                        return false
            Type.event_type as ea:
                match b:
                    Type.event_type as eb:
                        return ea.name == eb.name and ea.capacity == eb.capacity and this.types_eq(ea.payload_type, eb.payload_type) and ea.module_name == eb.module_name and ea.owner_type_name == eb.owner_type_name
                    _:
                        return false
            Type.dyn_vtable_type as da:
                match b:
                    Type.dyn_vtable_type as db:
                        return da.interface_name == db.interface_name
                    _:
                        return false
        return false

    # ── List comparison helpers ──

    function type_id_lists_eq(a_start: TypeId, a_len: TypeId, b_start: TypeId, b_len: TypeId) -> bool:
        if a_len != b_len:
            return false
        var i: ptr_uint = 0
        while i < a_len:
            let aid = this.type_id_lists.at(a_start + i) else:
                return false
            let bid = this.type_id_lists.at(b_start + i) else:
                return false
            if not this.types_eq(aid, bid):
                return false
            i += 1
        return true

    function str_lists_eq(a_start: TypeId, a_len: TypeId, b_start: TypeId, b_len: TypeId) -> bool:
        if a_len != b_len:
            return false
        var i: ptr_uint = 0
        while i < a_len:
            let av = this.str_lists.at(a_start + i) else:
                return false
            let bv = this.str_lists.at(b_start + i) else:
                return false
            if av != bv:
                return false
            i += 1
        return true

    function params_eq(a_start: TypeId, a_len: TypeId, b_start: TypeId, b_len: TypeId) -> bool:
        if a_len != b_len:
            return false
        var i: ptr_uint = 0
        while i < a_len:
            let ap = this.params.at(a_start + i) else:
                return false
            let bp = this.params.at(b_start + i) else:
                return false
            if not this.types_eq(ap.param_type, bp.param_type):
                return false
            if ap.passing_mode != bp.passing_mode:
                return false
            if not this.types_eq(ap.boundary_type, bp.boundary_type):
                return false
            i += 1
        return true

    function type_params_eq(a_start: TypeId, a_len: TypeId, b_start: TypeId, b_len: TypeId) -> bool:
        if a_len != b_len:
            return false
        var i: ptr_uint = 0
        while i < a_len:
            let ap = this.type_params.at(a_start + i) else:
                return false
            let bp = this.type_params.at(b_start + i) else:
                return false
            if ap.name != bp.name:
                return false
            i += 1
        return true

    # ── List allocation helpers ──

    public editable function store_type_id_list(items: vec.Vec[TypeId]) -> TypeId:
        let start = this.type_id_lists.len
        var i: ptr_uint = 0
        while i < items.len:
            let item = items.at(i) else:
                i += 1
                continue
            this.type_id_lists.push(item)
            i += 1
        return start

    public editable function store_str_list(items: vec.Vec[str]) -> TypeId:
        let start = this.str_lists.len
        var i: ptr_uint = 0
        while i < items.len:
            let item = items.at(i) else:
                i += 1
                continue
            this.str_lists.push(item)
            i += 1
        return start

    public editable function store_params(param_vec: vec.Vec[ParamInfo]) -> TypeId:
        let start = this.params.len
        var i: ptr_uint = 0
        while i < param_vec.len:
            let item = param_vec.at(i) else:
                i += 1
                continue
            this.params.push(item)
            i += 1
        return start

    public editable function store_type_params(tp_vec: vec.Vec[TypeParamBinding]) -> TypeId:
        let start = this.type_params.len
        var i: ptr_uint = 0
        while i < tp_vec.len:
            let item = tp_vec.at(i) else:
                i += 1
                continue
            this.type_params.push(item)
            i += 1
        return start

    # ── Display ──

    public function type_to_str(id: TypeId) -> str:
        return this.type_to_str_impl(id, 0z)

    function type_to_str_impl(id: TypeId, _depth: ptr_uint) -> str:
        let t = this.get(id)
        match t:
            Type.primitive as p:
                return p.name
            Type.error_type:
                return "<error>"
            Type.type_var as tv:
                return tv.name
            Type.struct_type as st:
                if st.module_name == "":
                    return st.name
                return st.name
            Type.variant_type as vt:
                return vt.name
            Type.nullable:
                return "nullable"
            Type.pointer_type:
                return "ptr"
            Type.struct_instance:
                return "struct_instance"
            Type.variant_instance:
                return "variant_instance"
            _:
                return "<type>"

# ═══════════════════════════════════════════════════════════════════════════════
# Type predicates (mirrors lib/milk_tea/core/types/predicates.rb)
# ═══════════════════════════════════════════════════════════════════════════════

public function is_primitive(arena: TypeArena, id: TypeId, name: str) -> bool:
    match arena.get(id):
        Type.primitive as p:
            return p.name == name
        _:
            return false

public function is_integer_type(arena: TypeArena, id: TypeId) -> bool:
    match arena.get(id):
        Type.primitive as p:
            return p.name == "byte" or p.name == "short" or p.name == "int" or p.name == "long" or p.name == "ubyte" or p.name == "ushort" or p.name == "uint" or p.name == "ulong" or p.name == "ptr_int" or p.name == "ptr_uint"
        Type.enum_type:
            return true
        Type.flags_type:
            return false
        _:
            return false

public function is_float_type(arena: TypeArena, id: TypeId) -> bool:
    match arena.get(id):
        Type.primitive as p:
            return p.name == "float" or p.name == "double"
        _:
            return false

public function is_numeric_type(arena: TypeArena, id: TypeId) -> bool:
    return is_integer_type(arena, id) or is_float_type(arena, id)

public function is_bool_type(arena: TypeArena, id: TypeId) -> bool:
    return is_primitive(arena, id, "bool")

public function is_void_type(arena: TypeArena, id: TypeId) -> bool:
    return is_primitive(arena, id, "void")

public function is_str_type(arena: TypeArena, id: TypeId) -> bool:
    return is_primitive(arena, id, "str")

public function is_cstr_type(arena: TypeArena, id: TypeId) -> bool:
    return is_primitive(arena, id, "cstr")

public function is_char_type(arena: TypeArena, id: TypeId) -> bool:
    return is_primitive(arena, id, "char")

public function is_pointer_type(arena: TypeArena, id: TypeId) -> bool:
    match arena.get(id):
        Type.pointer_type:
            return true
        Type.const_pointer_type:
            return true
        _:
            return false

public function is_ref_type(arena: TypeArena, id: TypeId) -> bool:
    match arena.get(id):
        Type.ref_type:
            return true
        _:
            return false

public function is_nullable_type(arena: TypeArena, id: TypeId) -> bool:
    match arena.get(id):
        Type.nullable:
            return true
        _:
            return false

public function is_error_type(arena: TypeArena, id: TypeId) -> bool:
    match arena.get(id):
        Type.error_type:
            return true
        _:
            return false

public function is_type_var(arena: TypeArena, id: TypeId) -> bool:
    match arena.get(id):
        Type.type_var:
            return true
        _:
            return false

# ═══════════════════════════════════════════════════════════════════════════════
# Reserved name sets (mirrors Ruby constants)
# ═══════════════════════════════════════════════════════════════════════════════

public function is_reserved_type_name(name: str) -> bool:
    return name == "bool" or name == "byte" or name == "ubyte" or name == "char" or name == "short" or name == "ushort" or name == "int" or name == "uint" or name == "long" or name == "ulong" or name == "ptr_int" or name == "ptr_uint" or name == "float" or name == "double" or name == "void" or name == "str" or name == "cstr" or name == "vec2" or name == "vec3" or name == "vec4" or name == "ivec2" or name == "ivec3" or name == "ivec4" or name == "mat3" or name == "mat4" or name == "quat" or name == "ptr" or name == "const_ptr" or name == "ref" or name == "span" or name == "array" or name == "str_buffer" or name == "atomic" or name == "Task" or name == "Option" or name == "Result" or name == "SoA" or name == "type"

public function is_reserved_import_alias(name: str) -> bool:
    return name == "Option" or name == "Result"
