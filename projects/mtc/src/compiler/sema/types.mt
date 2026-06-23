## SemType — semantic type classification predicates on TypeId.

import compiler.sema.primitive_kind as pk
import compiler.sema.type_registry as reg

public type TypeId = reg.TypeId
type P = pk.PrimitiveKind


public struct Types:
    int_ids: array[TypeId, 11]
    int_count: ptr_uint
    float_ids: array[TypeId, 2]
    float_count: ptr_uint
    bool_id: TypeId
    void_id: TypeId
    str_id: TypeId


public function create(registry: ref[reg.Registry]) -> Types:
    var t = Types(
        int_ids = array[TypeId, 11](),
        int_count = 0,
        float_ids = array[TypeId, 2](),
        float_count = 0,
        bool_id = TypeId<-0,
        void_id = TypeId<-0,
        str_id = TypeId<-0,
    )
    t.init(registry)
    return t


extending Types:
    editable function init(r: ref[reg.Registry]) -> void:
        this.add_int(r.primitive(P.pk_byte))
        this.add_int(r.primitive(P.pk_ubyte))
        this.add_int(r.primitive(P.pk_char))
        this.add_int(r.primitive(P.pk_short))
        this.add_int(r.primitive(P.pk_ushort))
        this.add_int(r.primitive(P.pk_int))
        this.add_int(r.primitive(P.pk_uint))
        this.add_int(r.primitive(P.pk_long))
        this.add_int(r.primitive(P.pk_ulong))
        this.add_int(r.primitive(P.pk_ptr_int))
        this.add_int(r.primitive(P.pk_ptr_uint))
        this.add_float(r.primitive(P.pk_float))
        this.add_float(r.primitive(P.pk_double))
        this.bool_id = r.primitive(P.pk_bool)
        this.void_id = r.primitive(P.pk_void)
        this.str_id = r.primitive(P.pk_str)


    editable function add_int(tid: TypeId) -> void:
        this.int_ids[this.int_count] = tid
        this.int_count += 1


    editable function add_float(tid: TypeId) -> void:
        this.float_ids[this.float_count] = tid
        this.float_count += 1


    public function is_integer(id: TypeId) -> bool:
        var i: ptr_uint = 0
        while i < this.int_count:
            if this.int_ids[i] == id:
                return true
            i += 1
        return false


    public function is_float(id: TypeId) -> bool:
        var i: ptr_uint = 0
        while i < this.float_count:
            if this.float_ids[i] == id:
                return true
            i += 1
        return false


    public function is_numeric(id: TypeId) -> bool:
        return this.is_integer(id) or this.is_float(id)


    public function is_bool(id: TypeId) -> bool:
        return id == this.bool_id


    public function is_void(id: TypeId) -> bool:
        return id == this.void_id


    public function is_str(id: TypeId) -> bool:
        return id == this.str_id
