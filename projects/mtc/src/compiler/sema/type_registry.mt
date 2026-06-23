## TypeRegistry — canonical integer TypeId for every type.
##
## All type comparison becomes integer ==. Zero struct equality.
## Backed by hash maps for single-arg generics, Vec linear scan
## for multi-arg types (fn, tuple, array).

import compiler.sema.generic_kind as gk
import compiler.sema.primitive_kind as pk
import std.hash
import std.map
import std.vec

public type TypeId = uint

type P = pk.PrimitiveKind

struct FnEntry:
    params: span[TypeId]
    ret: TypeId
    id: TypeId

struct ArrayEntry:
    element: TypeId
    size: ptr_uint
    id: TypeId

struct TupleEntry:
    elements: span[TypeId]
    id: TypeId

struct NamedEntry:
    name: ptr_uint
    id: TypeId

struct PtrRevEntry:
    pointee: TypeId
    is_const: bool
    id: TypeId

struct SpanRevEntry:
    element: TypeId
    id: TypeId

struct RefRevEntry:
    element: TypeId
    id: TypeId

struct NullableRevEntry:
    inner: TypeId
    id: TypeId

struct VecEntry:
    element: TypeId
    id: TypeId

struct MapEntry:
    key_type: TypeId
    val_type: TypeId
    id: TypeId

public struct Registry:
    counter: TypeId
    primitives: vec.Vec[TypeId]
    ptr_of: map.Map[ptr_uint, TypeId]
    const_ptr_of: map.Map[ptr_uint, TypeId]
    ref_of: map.Map[ptr_uint, TypeId]
    span_of: map.Map[ptr_uint, TypeId]
    nullable_of: map.Map[ptr_uint, TypeId]
    arrays: vec.Vec[ArrayEntry]
    functions: vec.Vec[FnEntry]
    tuples: vec.Vec[TupleEntry]
    named: vec.Vec[NamedEntry]
    alias_map: map.Map[ptr_uint, TypeId]

    ptr_rev: vec.Vec[PtrRevEntry]
    span_rev: vec.Vec[SpanRevEntry]
    ref_rev: vec.Vec[RefRevEntry]
    nullable_rev: vec.Vec[NullableRevEntry]
    vecs: vec.Vec[VecEntry]
    maps: vec.Vec[MapEntry]


public function create() -> Registry:
    var prims = vec.Vec[TypeId].with_capacity(32)
    var i: ptr_uint = 0
    while i < 32:
        prims.push(TypeId<-0)
        i += 1
    var r = Registry(
        counter = 0,
        primitives = prims,
        ptr_of = map.Map[ptr_uint, TypeId].with_capacity(32),
        const_ptr_of = map.Map[ptr_uint, TypeId].with_capacity(16),
        ref_of = map.Map[ptr_uint, TypeId].with_capacity(16),
        span_of = map.Map[ptr_uint, TypeId].with_capacity(16),
        nullable_of = map.Map[ptr_uint, TypeId].with_capacity(16),
        arrays = vec.Vec[ArrayEntry].with_capacity(8),
        functions = vec.Vec[FnEntry].with_capacity(32),
        tuples = vec.Vec[TupleEntry].with_capacity(8),
        named = vec.Vec[NamedEntry].with_capacity(32),
        alias_map = map.Map[ptr_uint, TypeId].with_capacity(16),
        ptr_rev = vec.Vec[PtrRevEntry].with_capacity(32),
        span_rev = vec.Vec[SpanRevEntry].with_capacity(16),
        ref_rev = vec.Vec[RefRevEntry].with_capacity(8),
        nullable_rev = vec.Vec[NullableRevEntry].with_capacity(8),
        vecs = vec.Vec[VecEntry].with_capacity(16),
        maps = vec.Vec[MapEntry].with_capacity(16),
    )
    r.init_primitives()
    return r


extending Registry:
    editable function init_primitives() -> void:
        this.define_prim(P.pk_bool)
        this.define_prim(P.pk_byte)
        this.define_prim(P.pk_ubyte)
        this.define_prim(P.pk_char)
        this.define_prim(P.pk_short)
        this.define_prim(P.pk_ushort)
        this.define_prim(P.pk_int)
        this.define_prim(P.pk_uint)
        this.define_prim(P.pk_long)
        this.define_prim(P.pk_ulong)
        this.define_prim(P.pk_ptr_int)
        this.define_prim(P.pk_ptr_uint)
        this.define_prim(P.pk_float)
        this.define_prim(P.pk_double)
        this.define_prim(P.pk_void)
        this.define_prim(P.pk_str)
        this.define_prim(P.pk_cstr)
        this.define_prim(P.pk_vec2)
        this.define_prim(P.pk_vec3)
        this.define_prim(P.pk_vec4)
        this.define_prim(P.pk_ivec2)
        this.define_prim(P.pk_ivec3)
        this.define_prim(P.pk_ivec4)
        this.define_prim(P.pk_mat3)
        this.define_prim(P.pk_mat4)
        this.define_prim(P.pk_quat)


    editable function define_prim(kind: P) -> void:
        this.counter += 1
        let i = ptr_uint<-kind
        let tid = TypeId<-this.counter
        unsafe:
            let elem = this.primitives.as_span().data + i
            read(elem) = tid


    public function primitive(kind: P) -> TypeId:
        let i = ptr_uint<-kind
        unsafe:
            return read(this.primitives.as_span().data + i)


    public editable function pointer(pointee: TypeId, is_const: bool) -> TypeId:
        let key = ptr_uint<-pointee
        if is_const:
            let existing = this.const_ptr_of.get(key) else:
                this.counter += 1
                let id = TypeId<-this.counter
                let _ = this.const_ptr_of.set(key, id)
                this.ptr_rev.push(PtrRevEntry(pointee = pointee, is_const = true, id = id))
                return id
            unsafe:
                return read(existing)

        let existing = this.ptr_of.get(key) else:
            this.counter += 1
            let id = TypeId<-this.counter
            let _ = this.ptr_of.set(key, id)
            this.ptr_rev.push(PtrRevEntry(pointee = pointee, is_const = false, id = id))
            return id
        unsafe:
            return read(existing)


    public editable function ref(pointee: TypeId) -> TypeId:
        let key = ptr_uint<-pointee
        let existing = this.ref_of.get(key) else:
            this.counter += 1
            let id = TypeId<-this.counter
            let _ = this.ref_of.set(key, id)
            this.ref_rev.push(RefRevEntry(element = pointee, id = id))
            return id
        unsafe:
            return read(existing)


    public editable function span(element: TypeId) -> TypeId:
        let key = ptr_uint<-element
        let existing = this.span_of.get(key) else:
            this.counter += 1
            let id = TypeId<-this.counter
            let _ = this.span_of.set(key, id)
            this.span_rev.push(SpanRevEntry(element = element, id = id))
            return id
        unsafe:
            return read(existing)


    public editable function nullable(inner: TypeId) -> TypeId:
        let key = ptr_uint<-inner
        let existing = this.nullable_of.get(key) else:
            this.counter += 1
            let id = TypeId<-this.counter
            let _ = this.nullable_of.set(key, id)
            this.nullable_rev.push(NullableRevEntry(inner = inner, id = id))
            return id
        unsafe:
            return read(existing)


    public editable function array(element: TypeId, size: ptr_uint) -> TypeId:
        for entry in this.arrays.as_span():
            if entry.element == element and entry.size == size:
                return entry.id

        this.counter += 1
        let id = TypeId<-this.counter
        this.arrays.push(ArrayEntry(element = element, size = size, id = id))
        return id


    editable function fn_type(
        params: span[TypeId],
        ret: TypeId,
    ) -> TypeId:
        for entry in this.functions.as_span():
            if entry.ret != ret:
                continue
            if entry.params.len != params.len:
                continue
            var eq = true
            var i: ptr_uint = 0
            while i < params.len:
                if unsafe: read(entry.params.data + i) != unsafe: read(params.data + i):
                    eq = false
                    break
                i += 1
            if eq:
                return entry.id

        this.counter += 1
        let id = TypeId<-this.counter
        this.functions.push(FnEntry(params = params, ret = ret, id = id))
        return id


    editable function tuple_type(elements: span[TypeId]) -> TypeId:
        for entry in this.tuples.as_span():
            if entry.elements.len != elements.len:
                continue
            var eq = true
            var i: ptr_uint = 0
            while i < elements.len:
                if unsafe: read(entry.elements.data + i) != unsafe: read(elements.data + i):
                    eq = false
                    break
                i += 1
            if eq:
                return entry.id

        this.counter += 1
        let id = TypeId<-this.counter
        this.tuples.push(TupleEntry(elements = elements, id = id))
        return id


    public function is_primitive(tid: TypeId, kind: P) -> bool:
        return tid == this.primitive(kind) and tid != TypeId<-0


    public function pointer_pointee(tid: TypeId) -> TypeId:
        for entry in this.ptr_rev.as_span():
            if entry.id == tid:
                return entry.pointee
        return TypeId<-0


    public function pointer_is_const(tid: TypeId) -> bool:
        for entry in this.ptr_rev.as_span():
            if entry.id == tid:
                return entry.is_const
        return false


    public editable function vec(element: TypeId) -> TypeId:
        var ei: ptr_uint = 0
        while ei < this.vecs.len:
            let entry = this.vecs.at(ei) else:
                break
            if entry.element == element:
                return entry.id
            ei += 1
        this.counter += 1
        let id = TypeId<-this.counter
        this.vecs.push(VecEntry(element = element, id = id))
        return id


    public function vec_element(tid: TypeId) -> TypeId:
        var ei: ptr_uint = 0
        while ei < this.vecs.len:
            let entry = this.vecs.at(ei) else:
                return TypeId<-0
            if entry.id == tid:
                return entry.element
            ei += 1
        return TypeId<-0


    public editable function map(key_type: TypeId, val_type: TypeId) -> TypeId:
        var ei: ptr_uint = 0
        while ei < this.maps.len:
            let entry = this.maps.at(ei) else:
                break
            if entry.key_type == key_type and entry.val_type == val_type:
                return entry.id
            ei += 1
        this.counter += 1
        let id = TypeId<-this.counter
        this.maps.push(MapEntry(key_type = key_type, val_type = val_type, id = id))
        return id


    public function map_key(tid: TypeId) -> TypeId:
        var ei: ptr_uint = 0
        while ei < this.maps.len:
            let entry = this.maps.at(ei) else:
                return TypeId<-0
            if entry.id == tid:
                return entry.key_type
            ei += 1
        return TypeId<-0


    public function map_val(tid: TypeId) -> TypeId:
        var ei: ptr_uint = 0
        while ei < this.maps.len:
            let entry = this.maps.at(ei) else:
                return TypeId<-0
            if entry.id == tid:
                return entry.val_type
            ei += 1
        return TypeId<-0


    public function span_element(tid: TypeId) -> TypeId:
        for entry in this.span_rev.as_span():
            if entry.id == tid:
                return entry.element
        return TypeId<-0


    public function ref_pointee(tid: TypeId) -> TypeId:
        for entry in this.ref_rev.as_span():
            if entry.id == tid:
                return entry.element
        return TypeId<-0


    public function nullable_inner(tid: TypeId) -> TypeId:
        for entry in this.nullable_rev.as_span():
            if entry.id == tid:
                return entry.inner
        return TypeId<-0


    public function lookup_named(name: ptr_uint) -> TypeId:
        ## Returns the existing TypeId for name, or 0 if not found.
        ## Also checks aliases.
        let aid = this.alias_map.get(name)
        if aid != null:
            unsafe: return read(aid)
        for entry in this.named.as_span():
            if entry.name == name:
                return entry.id
        return TypeId<-0


    public editable function set_alias(alias_name: ptr_uint, target: TypeId) -> void:
        let _ = this.alias_map.set(alias_name, target)


    public editable function register_named_with_id(name: ptr_uint, id: TypeId) -> void:
        ## Register a named entry with a pre-assigned TypeId (for aliases).
        for entry in this.named.as_span():
            if entry.name == name:
                return
        this.named.push(NamedEntry(name = name, id = id))


    public editable function named_type(name: ptr_uint) -> TypeId:
        for entry in this.named.as_span():
            if entry.name == name:
                return entry.id

        this.counter += 1
        let id = TypeId<-this.counter
        this.named.push(NamedEntry(name = name, id = id))
        return id
