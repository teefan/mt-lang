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
                return id
            unsafe:
                return read(existing)

        let existing = this.ptr_of.get(key) else:
            this.counter += 1
            let id = TypeId<-this.counter
            let _ = this.ptr_of.set(key, id)
            return id
        unsafe:
            return read(existing)


    public editable function ref(pointee: TypeId) -> TypeId:
        let key = ptr_uint<-pointee
        let existing = this.ref_of.get(key) else:
            this.counter += 1
            let id = TypeId<-this.counter
            let _ = this.ref_of.set(key, id)
            return id
        unsafe:
            return read(existing)


    public editable function span(element: TypeId) -> TypeId:
        let key = ptr_uint<-element
        let existing = this.span_of.get(key) else:
            this.counter += 1
            let id = TypeId<-this.counter
            let _ = this.span_of.set(key, id)
            return id
        unsafe:
            return read(existing)


    public editable function nullable(inner: TypeId) -> TypeId:
        let key = ptr_uint<-inner
        let existing = this.nullable_of.get(key) else:
            this.counter += 1
            let id = TypeId<-this.counter
            let _ = this.nullable_of.set(key, id)
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


    public function lookup_named(name: ptr_uint) -> TypeId:
        ## Returns the existing TypeId for name, or 0 if not found.
        for entry in this.named.as_span():
            if entry.name == name:
                return entry.id
        return TypeId<-0


    public editable function named_type(name: ptr_uint) -> TypeId:
        for entry in this.named.as_span():
            if entry.name == name:
                return entry.id

        this.counter += 1
        let id = TypeId<-this.counter
        this.named.push(NamedEntry(name = name, id = id))
        return id
