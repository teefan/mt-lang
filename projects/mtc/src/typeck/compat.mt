import typeck.types as types

public struct TypeChecker:
    registry: types.TypeRegistry

extending TypeChecker:
    public static function create() -> TypeChecker:
        return TypeChecker(registry = types.TypeRegistry.create())

    public function is_compatible(expected: types.TypeHandle, actual: types.TypeHandle) -> bool:
        if expected == actual:
            return true
        if expected == types.TYPE_HANDLE_VOID:
            return true
        let e = this.registry.entry(uint<-(expected))
        let a = this.registry.entry(uint<-(actual))
        if e.kind == types.TypeEntryKind.error or a.kind == types.TypeEntryKind.error:
            return true
        return false

    public function is_integer(handle: types.TypeHandle) -> bool:
        let e = this.registry.entry(uint<-(handle))
        if e.kind != types.TypeEntryKind.primitive:
            return false
        let k = e.primitive_kind
        return k == types.PrimitiveKind.byte_type or k == types.PrimitiveKind.short_type or k == types.PrimitiveKind.int_type or k == types.PrimitiveKind.long_type or k == types.PrimitiveKind.ubyte_type or k == types.PrimitiveKind.ushort_type or k == types.PrimitiveKind.uint_type or k == types.PrimitiveKind.ulong_type or k == types.PrimitiveKind.ptr_int_type or k == types.PrimitiveKind.ptr_uint_type

    public function is_float(handle: types.TypeHandle) -> bool:
        let e = this.registry.entry(uint<-(handle))
        if e.kind != types.TypeEntryKind.primitive:
            return false
        let k = e.primitive_kind
        return k == types.PrimitiveKind.float_type or k == types.PrimitiveKind.double_type

    public function is_numeric(handle: types.TypeHandle) -> bool:
        return this.is_integer(handle) or this.is_float(handle)

    public function is_bool(handle: types.TypeHandle) -> bool:
        let e = this.registry.entry(uint<-(handle))
        if e.kind != types.TypeEntryKind.primitive:
            return false
        return e.primitive_kind == types.PrimitiveKind.bool_type

    public function is_pointer_like(handle: types.TypeHandle) -> bool:
        let e = this.registry.entry(uint<-(handle))
        return e.kind == types.TypeEntryKind.pointer or e.kind == types.TypeEntryKind.const_pointer or e.kind == types.TypeEntryKind.nullable

    public function is_nullable(handle: types.TypeHandle) -> bool:
        let e = this.registry.entry(uint<-(handle))
        return e.kind == types.TypeEntryKind.nullable

    public function is_struct(handle: types.TypeHandle) -> bool:
        let e = this.registry.entry(uint<-(handle))
        return e.kind == types.TypeEntryKind.struct_def

    public function is_enum(handle: types.TypeHandle) -> bool:
        let e = this.registry.entry(uint<-(handle))
        return e.kind == types.TypeEntryKind.enum_def

    public function is_flags(handle: types.TypeHandle) -> bool:
        let e = this.registry.entry(uint<-(handle))
        return e.kind == types.TypeEntryKind.flags_def

    public function is_array(handle: types.TypeHandle) -> bool:
        let e = this.registry.entry(uint<-(handle))
        return e.kind == types.TypeEntryKind.array_fixed

    public function is_span(handle: types.TypeHandle) -> bool:
        let e = this.registry.entry(uint<-(handle))
        return e.kind == types.TypeEntryKind.span_kind

    public function is_str(handle: types.TypeHandle) -> bool:
        return handle == types.TYPE_HANDLE_STR

    public function is_cstr(handle: types.TypeHandle) -> bool:
        return handle == types.TYPE_HANDLE_CSTR

    public function unify_int_float(left: types.TypeHandle, right: types.TypeHandle) -> types.TypeHandle:
        if this.is_float(left) and this.is_integer(right):
            return left
        if this.is_integer(left) and this.is_float(right):
            return right
        if left == right:
            return left
        return left

    public function lookup_type(name: str) -> Option[types.TypeHandle]:
        return this.registry.lookup_primitive(name)
