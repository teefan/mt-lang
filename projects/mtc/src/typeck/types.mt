import std.vec as vec

public type TypeHandle = uint

public const TYPE_HANDLE_VOID: TypeHandle = 0
public const TYPE_HANDLE_BOOL: TypeHandle = 1
public const TYPE_HANDLE_BYTE: TypeHandle = 2
public const TYPE_HANDLE_SHORT: TypeHandle = 3
public const TYPE_HANDLE_INT: TypeHandle = 4
public const TYPE_HANDLE_LONG: TypeHandle = 5
public const TYPE_HANDLE_UBYTE: TypeHandle = 6
public const TYPE_HANDLE_USHORT: TypeHandle = 7
public const TYPE_HANDLE_UINT: TypeHandle = 8
public const TYPE_HANDLE_ULONG: TypeHandle = 9
public const TYPE_HANDLE_PTR_INT: TypeHandle = 10
public const TYPE_HANDLE_PTR_UINT: TypeHandle = 11
public const TYPE_HANDLE_FLOAT: TypeHandle = 12
public const TYPE_HANDLE_DOUBLE: TypeHandle = 13
public const TYPE_HANDLE_CHAR: TypeHandle = 14
public const TYPE_HANDLE_STR: TypeHandle = 15
public const TYPE_HANDLE_CSTR: TypeHandle = 16

public enum PrimitiveKind: ubyte
    void_type  = 0
    bool_type  = 1
    byte_type  = 2
    short_type = 3
    int_type   = 4
    long_type  = 5
    ubyte_type = 6
    ushort_type = 7
    uint_type  = 8
    ulong_type = 9
    ptr_int_type = 10
    ptr_uint_type = 11
    float_type = 12
    double_type = 13
    char_type  = 14
    str_type   = 15
    cstr_type  = 16

public struct TypeLayout:
    size: ptr_uint
    alignment: ptr_uint

public struct StructFieldInfo:
    name: str
    type_handle: TypeHandle
    offset: ptr_uint

public enum TypeEntryKind: ubyte
    primitive      = 0
    pointer        = 1
    const_pointer  = 2
    reference      = 3
    span_kind      = 4
    array_fixed    = 5
    nullable       = 6
    fn_ptr         = 7
    proc_type      = 8
    tuple_type     = 9
    dyn_type       = 10
    soa_type       = 11
    str_buf        = 12
    task_type      = 13
    atomic_type    = 14
    named          = 15
    struct_def     = 16
    struct_inst    = 17
    union_type     = 18
    variant_def    = 19
    variant_inst   = 20
    enum_def       = 21
    flags_def      = 22
    opaque_def     = 23
    iface          = 24
    type_var       = 25
    value_param    = 26
    error          = 27

public struct TypeEntry:
    kind: TypeEntryKind
    name: str
    pointee_handle: TypeHandle
    element_handle: TypeHandle
    array_size: ptr_uint
    primitive_kind: PrimitiveKind
    is_packed: bool
    alignment: ptr_uint
    is_external: bool
    module_id: uint
    field_handles: vec.Vec[TypeHandle]
    field_names: vec.Vec[str]
    type_param_handles: vec.Vec[TypeHandle]

public struct TypeRegistry:
    entries: vec.Vec[TypeEntry]
    layouts: vec.Vec[TypeLayout]
    primitive_map: vec.Vec[str]
    pointee_handle: TypeHandle

extending TypeRegistry:
    public static function create() -> TypeRegistry:
        var reg = TypeRegistry(
            entries = vec.Vec[TypeEntry].create(),
            layouts = vec.Vec[TypeLayout].create(),
            primitive_map = vec.Vec[str].create()
        )
        reg.install_primitives()
        return reg

    editable function install_primitives() -> void:
        this.install_primitive("void", PrimitiveKind.void_type, 0, 1)
        this.install_primitive("bool", PrimitiveKind.bool_type, 1, 1)
        this.install_primitive("byte", PrimitiveKind.byte_type, 1, 1)
        this.install_primitive("short", PrimitiveKind.short_type, 2, 2)
        this.install_primitive("int", PrimitiveKind.int_type, 4, 4)
        this.install_primitive("long", PrimitiveKind.long_type, 8, 8)
        this.install_primitive("ubyte", PrimitiveKind.ubyte_type, 1, 1)
        this.install_primitive("ushort", PrimitiveKind.ushort_type, 2, 2)
        this.install_primitive("uint", PrimitiveKind.uint_type, 4, 4)
        this.install_primitive("ulong", PrimitiveKind.ulong_type, 8, 8)
        this.install_primitive("ptr_int", PrimitiveKind.ptr_int_type, 8, 8)
        this.install_primitive("ptr_uint", PrimitiveKind.ptr_uint_type, 8, 8)
        this.install_primitive("float", PrimitiveKind.float_type, 4, 4)
        this.install_primitive("double", PrimitiveKind.double_type, 8, 8)
        this.install_primitive("char", PrimitiveKind.char_type, 1, 1)
        this.install_primitive("str", PrimitiveKind.str_type, 16, 8)
        this.install_primitive("cstr", PrimitiveKind.cstr_type, 8, 8)

    editable function install_primitive(name: str, kind: PrimitiveKind, size: ptr_uint, alignment: ptr_uint) -> void:
        var entry = TypeEntry(
            kind = TypeEntryKind.primitive,
            name = name,
            pointee_handle = 0,
            element_handle = 0,
            array_size = 0,
            primitive_kind = kind,
            is_packed = false,
            alignment = 0,
            is_external = false,
            module_id = 0,
            field_handles = vec.Vec[TypeHandle].create(),
            field_names = vec.Vec[str].create(),
            type_param_handles = vec.Vec[TypeHandle].create()
        )
        this.entries.push(entry)
        this.layouts.push(TypeLayout(size = size, alignment = alignment))

    public function entry(handle: TypeHandle) -> TypeEntry:
        let ptr = this.entries.get(ptr_uint<-(handle)) else:
            fatal(c"type_registry.entry invalid handle")
        unsafe:
            return read(ptr)

    public function layout(handle: TypeHandle) -> TypeLayout:
        let ptr = this.layouts.get(ptr_uint<-(handle)) else:
            fatal(c"type_registry.layout invalid handle")
        unsafe:
            return read(ptr)

    public function is_primitive(handle: TypeHandle) -> bool:
        return this.entry(handle).kind == TypeEntryKind.primitive

    public editable function pointer_type(pointee: TypeHandle) -> TypeHandle:
        var i: ptr_uint = 0
        while i < this.entries.len():
            let e = this.entry(uint<-(i))
            if e.kind == TypeEntryKind.pointer and e.pointee_handle == pointee:
                return uint<-(i)
            i += 1
        var entry = TypeEntry(
            kind = TypeEntryKind.pointer,
            name = "",
            pointee_handle = pointee,
            element_handle = 0,
            array_size = 0,
            primitive_kind = PrimitiveKind.void_type,
            is_packed = false,
            alignment = 0,
            is_external = false,
            module_id = 0,
            field_handles = vec.Vec[TypeHandle].create(),
            field_names = vec.Vec[str].create(),
            type_param_handles = vec.Vec[TypeHandle].create()
        )
        this.entries.push(entry)
        this.layouts.push(TypeLayout(size = 8, alignment = 8))
        return uint<-(this.entries.len() - 1)

    public editable function const_ptr_type(pointee: TypeHandle) -> TypeHandle:
        var i: ptr_uint = 0
        while i < this.entries.len():
            let e = this.entry(uint<-(i))
            if e.kind == TypeEntryKind.const_pointer and e.pointee_handle == pointee:
                return uint<-(i)
            i += 1
        var entry = TypeEntry(
            kind = TypeEntryKind.const_pointer,
            name = "",
            pointee_handle = pointee,
            element_handle = 0,
            array_size = 0,
            primitive_kind = PrimitiveKind.void_type,
            is_packed = false,
            alignment = 0,
            is_external = false,
            module_id = 0,
            field_handles = vec.Vec[TypeHandle].create(),
            field_names = vec.Vec[str].create(),
            type_param_handles = vec.Vec[TypeHandle].create()
        )
        this.entries.push(entry)
        this.layouts.push(TypeLayout(size = 8, alignment = 8))
        return uint<-(this.entries.len() - 1)

    public editable function span_type(element: TypeHandle) -> TypeHandle:
        var i: ptr_uint = 0
        while i < this.entries.len():
            let e = this.entry(uint<-(i))
            if e.kind == TypeEntryKind.span_kind and e.element_handle == element:
                return uint<-(i)
            i += 1
        var entry = TypeEntry(
            kind = TypeEntryKind.span_kind,
            name = "",
            pointee_handle = 0,
            element_handle = element,
            array_size = 0,
            primitive_kind = PrimitiveKind.void_type,
            is_packed = false,
            alignment = 0,
            is_external = false,
            module_id = 0,
            field_handles = vec.Vec[TypeHandle].create(),
            field_names = vec.Vec[str].create(),
            type_param_handles = vec.Vec[TypeHandle].create()
        )
        this.entries.push(entry)
        this.layouts.push(TypeLayout(size = 16, alignment = 8))
        return uint<-(this.entries.len() - 1)

    public editable function array_type(element: TypeHandle, size: ptr_uint) -> TypeHandle:
        var i: ptr_uint = 0
        while i < this.entries.len():
            let e = this.entry(uint<-(i))
            if e.kind == TypeEntryKind.array_fixed and e.element_handle == element and e.array_size == size:
                return uint<-(i)
            i += 1
        let elem_layout = this.layout(element)
        var entry = TypeEntry(
            kind = TypeEntryKind.array_fixed,
            name = "",
            pointee_handle = 0,
            element_handle = element,
            array_size = size,
            primitive_kind = PrimitiveKind.void_type,
            is_packed = false,
            alignment = 0,
            is_external = false,
            module_id = 0,
            field_handles = vec.Vec[TypeHandle].create(),
            field_names = vec.Vec[str].create(),
            type_param_handles = vec.Vec[TypeHandle].create()
        )
        this.entries.push(entry)
        this.layouts.push(TypeLayout(size = elem_layout.size * size, alignment = elem_layout.alignment))
        return uint<-(this.entries.len() - 1)

    public editable function nullable_type(inner: TypeHandle) -> TypeHandle:
        var i: ptr_uint = 0
        while i < this.entries.len():
            let e = this.entry(uint<-(i))
            if e.kind == TypeEntryKind.nullable and e.pointee_handle == inner:
                return uint<-(i)
            i += 1
        var entry = TypeEntry(
            kind = TypeEntryKind.nullable,
            name = "",
            pointee_handle = inner,
            element_handle = 0,
            array_size = 0,
            primitive_kind = PrimitiveKind.void_type,
            is_packed = false,
            alignment = 0,
            is_external = false,
            module_id = 0,
            field_handles = vec.Vec[TypeHandle].create(),
            field_names = vec.Vec[str].create(),
            type_param_handles = vec.Vec[TypeHandle].create()
        )
        this.entries.push(entry)
        let inner_layout = this.layout(inner)
        this.layouts.push(inner_layout)
        return uint<-(this.entries.len() - 1)

    public editable function struct_type(name: str, field_types: vec.Vec[TypeHandle], field_names: vec.Vec[str], is_packed: bool, alignment_val: ptr_uint, is_external: bool, module_id: uint) -> TypeHandle:
        var entry = TypeEntry(
            kind = TypeEntryKind.struct_def,
            name = name,
            pointee_handle = 0,
            element_handle = 0,
            array_size = 0,
            primitive_kind = PrimitiveKind.void_type,
            is_packed = is_packed,
            alignment = alignment_val,
            is_external = is_external,
            module_id = module_id,
            field_handles = field_types,
            field_names = field_names,
            type_param_handles = vec.Vec[TypeHandle].create()
        )
        let layout = this.compute_struct_layout(field_types, is_packed, alignment_val)
        this.entries.push(entry)
        this.layouts.push(layout)
        return uint<-(this.entries.len() - 1)

    public editable function enum_type(name: str, backing: TypeHandle, is_external: bool, module_id: uint) -> TypeHandle:
        var entry = TypeEntry(
            kind = TypeEntryKind.enum_def,
            name = name,
            pointee_handle = backing,
            element_handle = 0,
            array_size = 0,
            primitive_kind = PrimitiveKind.void_type,
            is_packed = false,
            alignment = 0,
            is_external = is_external,
            module_id = module_id,
            field_handles = vec.Vec[TypeHandle].create(),
            field_names = vec.Vec[str].create(),
            type_param_handles = vec.Vec[TypeHandle].create()
        )
        let backing_layout = this.layout(backing)
        this.entries.push(entry)
        this.layouts.push(backing_layout)
        return uint<-(this.entries.len() - 1)

    public editable function flags_type(name: str, backing: TypeHandle, is_external: bool, module_id: uint) -> TypeHandle:
        var entry = TypeEntry(
            kind = TypeEntryKind.flags_def,
            name = name,
            pointee_handle = backing,
            element_handle = 0,
            array_size = 0,
            primitive_kind = PrimitiveKind.void_type,
            is_packed = false,
            alignment = 0,
            is_external = is_external,
            module_id = module_id,
            field_handles = vec.Vec[TypeHandle].create(),
            field_names = vec.Vec[str].create(),
            type_param_handles = vec.Vec[TypeHandle].create()
        )
        let backing_layout = this.layout(backing)
        this.entries.push(entry)
        this.layouts.push(backing_layout)
        return uint<-(this.entries.len() - 1)

    public editable function union_type(name: str, field_types: vec.Vec[TypeHandle], is_external: bool) -> TypeHandle:
        var entry = TypeEntry(
            kind = TypeEntryKind.union_type,
            name = name,
            pointee_handle = 0,
            element_handle = 0,
            array_size = 0,
            primitive_kind = PrimitiveKind.void_type,
            is_packed = false,
            alignment = 0,
            is_external = is_external,
            module_id = 0,
            field_handles = field_types,
            field_names = vec.Vec[str].create(),
            type_param_handles = vec.Vec[TypeHandle].create()
        )
        let layout = this.compute_union_layout(field_types)
        this.entries.push(entry)
        this.layouts.push(layout)
        return uint<-(this.entries.len() - 1)

    public editable function opaque_type(name: str, is_external: bool, module_id: uint) -> TypeHandle:
        var entry = TypeEntry(
            kind = TypeEntryKind.opaque_def,
            name = name,
            pointee_handle = 0,
            element_handle = 0,
            array_size = 0,
            primitive_kind = PrimitiveKind.void_type,
            is_packed = false,
            alignment = 0,
            is_external = is_external,
            module_id = module_id,
            field_handles = vec.Vec[TypeHandle].create(),
            field_names = vec.Vec[str].create(),
            type_param_handles = vec.Vec[TypeHandle].create()
        )
        this.entries.push(entry)
        this.layouts.push(TypeLayout(size = 0, alignment = 1))
        return uint<-(this.entries.len() - 1)

    function compute_struct_layout(field_types: vec.Vec[TypeHandle], is_packed: bool, forced_alignment: ptr_uint) -> TypeLayout:
        var size: ptr_uint = 0
        var alignment: ptr_uint = 1

        var i: ptr_uint = 0
        while i < field_types.len():
            let fh = field_types.get(i) else:
                fatal(c"type_registry.compute_struct_layout missing field")
            unsafe:
                let handle = read(fh)
                let field_layout = this.layout(handle)
                let field_align = if is_packed: 1 else: field_layout.alignment
                if field_align > alignment:
                    alignment = field_align
                if size % field_align != 0:
                    size = size + field_align - (size % field_align)
                size = size + field_layout.size
            i += 1

        if forced_alignment > alignment:
            alignment = forced_alignment
        if alignment > 0 and size % alignment != 0:
            size = size + alignment - (size % alignment)

        return TypeLayout(size = size, alignment = alignment)

    function compute_union_layout(field_types: vec.Vec[TypeHandle]) -> TypeLayout:
        var size: ptr_uint = 0
        var alignment: ptr_uint = 1

        var i: ptr_uint = 0
        while i < field_types.len():
            let fh = field_types.get(i) else:
                fatal(c"type_registry.compute_union_layout missing field")
            unsafe:
                let handle = read(fh)
                let field_layout = this.layout(handle)
                if field_layout.size > size:
                    size = field_layout.size
                if field_layout.alignment > alignment:
                    alignment = field_layout.alignment
            i += 1

        return TypeLayout(size = size, alignment = alignment)

    public function len() -> ptr_uint:
        return this.entries.len()

    public function lookup_primitive(name: str) -> Option[TypeHandle]:
        if name == "void":
            return Option[TypeHandle].some(value = TYPE_HANDLE_VOID)
        else if name == "bool":
            return Option[TypeHandle].some(value = TYPE_HANDLE_BOOL)
        else if name == "byte":
            return Option[TypeHandle].some(value = TYPE_HANDLE_BYTE)
        else if name == "short":
            return Option[TypeHandle].some(value = TYPE_HANDLE_SHORT)
        else if name == "int":
            return Option[TypeHandle].some(value = TYPE_HANDLE_INT)
        else if name == "long":
            return Option[TypeHandle].some(value = TYPE_HANDLE_LONG)
        else if name == "ubyte":
            return Option[TypeHandle].some(value = TYPE_HANDLE_UBYTE)
        else if name == "ushort":
            return Option[TypeHandle].some(value = TYPE_HANDLE_USHORT)
        else if name == "uint":
            return Option[TypeHandle].some(value = TYPE_HANDLE_UINT)
        else if name == "ulong":
            return Option[TypeHandle].some(value = TYPE_HANDLE_ULONG)
        else if name == "ptr_int":
            return Option[TypeHandle].some(value = TYPE_HANDLE_PTR_INT)
        else if name == "ptr_uint":
            return Option[TypeHandle].some(value = TYPE_HANDLE_PTR_UINT)
        else if name == "float":
            return Option[TypeHandle].some(value = TYPE_HANDLE_FLOAT)
        else if name == "double":
            return Option[TypeHandle].some(value = TYPE_HANDLE_DOUBLE)
        else if name == "char":
            return Option[TypeHandle].some(value = TYPE_HANDLE_CHAR)
        else if name == "str":
            return Option[TypeHandle].some(value = TYPE_HANDLE_STR)
        else if name == "cstr":
            return Option[TypeHandle].some(value = TYPE_HANDLE_CSTR)
        return Option[TypeHandle].none
