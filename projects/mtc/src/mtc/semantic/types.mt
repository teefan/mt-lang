## Semantic type model — the analyzer's type representation, distinct from the
## syntactic `ast.TypeRef` produced by the parser.  Mirrors a core subset of
## Ruby's `Types::*` class hierarchy (lib/milk_tea/core/types/types.rb) as a
## variant: primitives, str, nullable, named (struct/enum/…), generic
## instances (ptr/span/array/Option/…), function/proc, and the `type` meta.
##
## The analyzer is deliberately conservative: anything it cannot resolve
## concretely becomes `ty_error`, which is compatible with everything so it
## never produces a false-positive diagnostic.

import std.string as string
import std.str
import std.fmt as fmt
import std.mem.heap as heap
import std.map as map_mod
import std.vec as vec


## One field of a variant arm's payload.  The host's `Types::VariantArmPayload`
## *is* the arm's struct (its fields are the variant's declared arm fields with
## the scrutinee's type arguments substituted), so `p.value` on a bound arm
## resolves through this list.
public struct PayloadField:
    name: str
    ty: Type


## The payload of `ty_variant_arm_payload`.  Boxed: it is the largest `Type`
## variant (five `str` fields plus a span) and rare, so keeping it inline would
## make every `Type` — and every IR node embedding one — pay its size.
public struct VariantArmPayload:
    variant_name: str
    name: str
    module_name: str
    c_name: str
    display_name: str
    fields: span[PayloadField]


## The payload of `ty_function`.  Boxed like `VariantArmPayload`: it was the
## widest arm (two spans, a pointer, a `str` and two bools = 48 bytes), and a
## variant's size is its widest arm, so it set the size of *every* `Type` — and
## therefore of every IR node, analyzer map value and `Vec[Type]` slot.  Boxing
## it drops `Type` from 72 to 64 bytes.
public struct FunctionType:
    params: span[Type]
    return_type: ptr[Type]
    variadic: bool
    is_proc: bool
    param_names: span[str]
    name: str


## The payload of `ty_named`.
public struct NamedType:
    name: str
    module_name: str
    linkage_name: Option[str]


## The payload of `ty_event`.
public struct EventType:
    name: str
    capacity: ptr_uint
    payload_type: ptr[Type]?
    linkage_name: str


## The payload of `ty_imported`.
public struct ImportedType:
    module_name: str
    name: str
    args: span[Type]


## The payload of `ty_dyn`.
public struct DynType:
    iface: str
    args: span[Type]


## The payload of `ty_dyn_vtable`.
public struct DynVtableType:
    interface_name: str
    linkage_name: str


## The payload of `ty_opaque`.
public struct OpaqueType:
    module_name: str
    name: str


## The payload of `ty_generic`.
public struct GenericType:
    name: str
    args: span[Type]


## The payload of `ty_tuple`.
public struct TupleType:
    elements: span[Type]
    field_names: Option[span[str]]


public variant Type:
    ty_primitive(name: str)
    ty_str
    ty_error
    # An absent/unresolved IR node type.  The host's `IR::Node#type` is nil for
    # nodes whose type the C backend infers from context (e.g. the intermediate
    # `x.data` member of a variant access); the sexpr dumper renders it `nil`.
    ty_nil
    ty_type_meta
    # The host's `Types::Handle` singleton: the opaque `void*` returned by
    # `detach`, consumed by `gather`.
    ty_handle
    ty_nullable(base: ptr[Type])
    ty_null(target: ptr[Type]?)
    ty_event(payload: ptr[EventType])
    # A nominal type declared in this module.  `linkage_name` carries the C
    # linkage when it differs from `<module>_<name>` — a nested struct's type is
    # named by its short name (`Edge`) but linked through its parents
    # (`<module>_Rectangle_Edge`), mirroring Ruby's `Types::Struct#linkage_name`.
    ty_named(payload: ptr[NamedType])
    # The binding type of an `as name` variant match arm.  `variant_name` and
    # `module_name` identify the owning variant (`Option`, `std.option`); `name`
    # is the rendered payload name (`Option_some`); `c_name` is the payload
    # struct's C linkage name (`std_option_Option_some`).  Mirrors Ruby's
    # `Types::VariantArmPayload`, which the sexpr dumper tags distinctly but
    # whose fields it renders like a `Types::Struct` (`:name`, `:module_name`).
    ty_variant_arm_payload(payload: ptr[VariantArmPayload])
    ty_imported(payload: ptr[ImportedType])
    ty_var(name: str)
    # An explicit lifetime argument on a `ref` type (`ref[@a, T]`).  The host
    # keeps the raw lifetime name (`"@a"`) as the first generic argument; it
    # renders as a bare quoted string and the referent is the last argument.
    ty_lifetime(name: str)
    # A `dyn[Iface[args]]` fat pointer.  The host's `Types::Dyn` carries the
    # interface's own type arguments as well as its name.
    ty_dyn(payload: ptr[DynType])
    # A `dyn` interface vtable type.  Mirrors Ruby's `Types::DynVtable`
    # (`interface_name` + generated `mt_vtable_<Iface>` linkage name); its field
    # map is not rendered by the sexpr dumper.
    ty_dyn_vtable(payload: ptr[DynVtableType])
    ty_opaque(payload: ptr[OpaqueType])
    ty_generic(payload: ptr[GenericType])
    # `name` is the host's `Types::Function#name`: the declared name when the
    # type came from a function *value* (`fn add`), empty for an anonymous
    # `fn(…)` annotation.  `to_s` renders `fn <name>` (the host's shape), so a
    # struct field's `fn(int) -> bool` renders `fn `.
    ty_function(payload: ptr[FunctionType])
    ty_literal_int(value: long)
    ty_tuple(payload: ptr[TupleType])


public function alloc_type(value: Type) -> ptr[Type]:
    var node = heap.must_alloc[Type](1)
    unsafe:
        read(node) = value
    return node


public function named_type(name: str, module_name: str, linkage_name: Option[str]) -> Type:
    let payload = heap.must_alloc[NamedType](1)
    unsafe:
        read(payload) = NamedType(name = name, module_name = module_name, linkage_name = linkage_name)
    return Type.ty_named(payload = payload)


public function event_type(name: str, capacity: ptr_uint, payload_type: ptr[Type]?, linkage_name: str) -> Type:
    let payload = heap.must_alloc[EventType](1)
    unsafe:
        read(payload) = EventType(name = name, capacity = capacity, payload_type = payload_type, linkage_name = linkage_name)
    return Type.ty_event(payload = payload)


public function imported_type(module_name: str, name: str, args: span[Type]) -> Type:
    let payload = heap.must_alloc[ImportedType](1)
    unsafe:
        read(payload) = ImportedType(module_name = module_name, name = name, args = args)
    return Type.ty_imported(payload = payload)


public function dyn_type(iface: str, args: span[Type]) -> Type:
    let payload = heap.must_alloc[DynType](1)
    unsafe:
        read(payload) = DynType(iface = iface, args = args)
    return Type.ty_dyn(payload = payload)


public function dyn_vtable_type(interface_name: str, linkage_name: str) -> Type:
    let payload = heap.must_alloc[DynVtableType](1)
    unsafe:
        read(payload) = DynVtableType(interface_name = interface_name, linkage_name = linkage_name)
    return Type.ty_dyn_vtable(payload = payload)


public function opaque_type(module_name: str, name: str) -> Type:
    let payload = heap.must_alloc[OpaqueType](1)
    unsafe:
        read(payload) = OpaqueType(module_name = module_name, name = name)
    return Type.ty_opaque(payload = payload)


public function generic_type(name: str, args: span[Type]) -> Type:
    let payload = heap.must_alloc[GenericType](1)
    unsafe:
        read(payload) = GenericType(name = name, args = args)
    return Type.ty_generic(payload = payload)


public function tuple_type(elements: span[Type], field_names: Option[span[str]]) -> Type:
    let payload = heap.must_alloc[TupleType](1)
    unsafe:
        read(payload) = TupleType(elements = elements, field_names = field_names)
    return Type.ty_tuple(payload = payload)


## The one constructor for `ty_function`.  The arm's fields live in a boxed
## `FunctionType`, so callers build the payload here rather than naming the
## variant arm directly.
public function function_type(name: str, params: span[Type], return_type: ptr[Type], variadic: bool, is_proc: bool, param_names: span[str]) -> Type:
    var payload = heap.must_alloc[FunctionType](1)
    unsafe:
        read(payload) = FunctionType(
            params = params,
            return_type = return_type,
            variadic = variadic,
            is_proc = is_proc,
            param_names = param_names,
            name = name,
        )
    return Type.ty_function(payload = payload)


public function primitive(name: str) -> Type:
    return Type.ty_primitive(name = name)


## A compile-time integer used as a generic type argument (e.g. the `N` in
## `array[T, N]` / `str_buffer[N]`).  Mirrors Ruby's Types::LiteralTypeArg.
public function literal_int(value: long) -> Type:
    return Type.ty_literal_int(value = value)


## Construct an arm payload from already-computed parts.  `proc_renumber`
## rebuilds one with renamed `__proc_N__` symbols.
public function variant_arm_payload_raw(variant_name: str, name: str, module_name: str, c_name: str, display_name: str, fields: span[PayloadField]) -> Type:
    var payload = heap.must_alloc[VariantArmPayload](1)
    unsafe:
        read(payload) = VariantArmPayload(
            variant_name = variant_name,
            name = name,
            module_name = module_name,
            c_name = c_name,
            display_name = display_name,
            fields = fields,
        )
    return Type.ty_variant_arm_payload(payload = payload)


## The binding type of an `as name` variant match arm.  `variant_name` is the
## owning variant's declared name (`Option`), `module_name` its module
## (`std.option`), and `c_name` the payload struct's C linkage name.
public function variant_arm_payload(variant_name: str, module_name: str, c_name: str, arm_name: str) -> Type:
    var buf = string.String.create()
    buf.append(variant_name)
    buf.append("_")
    buf.append(arm_name)
    return variant_arm_payload_raw(
        variant_name = variant_name,
        name = buf.as_str(),
        module_name = module_name,
        c_name = c_name,
        display_name = "",
        fields = span[PayloadField](),
    )


## The analyzer's richer construction: the host's `VariantArmPayload#to_s`
## renders `<variant>. <arm> payload` (`Option[(str, str)].some payload`), so
## the *instantiated* variant text and the arm's substituted field list travel
## with the type instead of being recomputed at every consumer.
public function variant_arm_payload_with(variant_name: str, module_name: str, c_name: str, arm_name: str, variant_text: str, fields: span[PayloadField]) -> Type:
    var buf = string.String.create()
    buf.append(variant_name)
    buf.append("_")
    buf.append(arm_name)
    var display = string.String.create()
    display.append(variant_text)
    display.append(".")
    display.append(arm_name)
    display.append(" payload")
    return variant_arm_payload_raw(
        variant_name = variant_name,
        name = buf.as_str(),
        module_name = module_name,
        c_name = c_name,
        display_name = display.as_str(),
        fields = fields,
    )


# ---------------------------------------------------------------------------
#  Classification predicates (mirror Types::Primitive flag methods)
# ---------------------------------------------------------------------------

public function is_numeric_name(name: str) -> bool:
    return (
        name == "byte" or name == "short" or name == "int" or name == "long"
        or name == "ubyte" or name == "ushort" or name == "uint" or name == "ulong"
        or name == "ptr_int" or name == "ptr_uint" or name == "float" or name == "double"
    )


## True when `name` is one of the primitive integer types (fixed-width or
## pointer-sized).  Excludes char and the float types.
public function is_integer_name(name: str) -> bool:
    return (
        name == "byte" or name == "short" or name == "int" or name == "long"
        or name == "ubyte" or name == "ushort" or name == "uint" or name == "ulong"
        or name == "ptr_int" or name == "ptr_uint"
    )


public function is_error(t: Type) -> bool:
    match t:
        Type.ty_error:
            return true
        _:
            return false


## True when the type is, or structurally contains, an unresolved `ty_error`
## component — e.g. a generic instantiated with an unresolved type parameter
## (`Keys[<error>, ptr_uint]`).  A partially-unknown type must never force a
## mismatch diagnostic, mirroring the top-level `ty_error` suppression.
public function contains_error(t: Type) -> bool:
    match t:
        Type.ty_error:
            return true
        Type.ty_nullable as n:
            return contains_error(unsafe: read(n.base))
        Type.ty_generic as g:
            let g_bp = unsafe: read(g.payload)
            return any_contains_error(g_bp.args)
        Type.ty_imported as im:
            let im_bp = unsafe: read(im.payload)
            return any_contains_error(im_bp.args)
        Type.ty_function as f:
            let f_ft = unsafe: read(f.payload)
            if contains_error(unsafe: read(f_ft.return_type)):
                return true
            return any_contains_error(f_ft.params)
        Type.ty_tuple as tp:
            let tp_bp = unsafe: read(tp.payload)
            return any_contains_error(tp_bp.elements)
        _:
            return false


function any_contains_error(args: span[Type]) -> bool:
    var i: ptr_uint = 0
    while i < args.len:
        unsafe:
            if contains_error(read(args.data + i)):
                return true
        i += 1
    return false


## True when the type is, or structurally contains, a type variable.  A generic
## body is instantiated later, and the host does not check it at definition
## time, so no assignability rule may prove a mismatch through a variable.
public function contains_type_var(t: Type) -> bool:
    match t:
        Type.ty_var:
            return true
        Type.ty_nullable as n:
            return contains_type_var(unsafe: read(n.base))
        Type.ty_generic as g:
            let g_bp = unsafe: read(g.payload)
            return any_contains_var(g_bp.args)
        Type.ty_imported as im:
            let im_bp = unsafe: read(im.payload)
            return any_contains_var(im_bp.args)
        Type.ty_function as f:
            let f_ft = unsafe: read(f.payload)
            if contains_type_var(unsafe: read(f_ft.return_type)):
                return true
            return any_contains_var(f_ft.params)
        Type.ty_tuple as tp:
            let tp_bp = unsafe: read(tp.payload)
            return any_contains_var(tp_bp.elements)
        _:
            return false


function any_contains_var(args: span[Type]) -> bool:
    var i: ptr_uint = 0
    while i < args.len:
        unsafe:
            if contains_type_var(read(args.data + i)):
                return true
        i += 1
    return false


public function is_bool(t: Type) -> bool:
    match t:
        Type.ty_primitive as p:
            return p.name == "bool"
        _:
            return false


public function is_void(t: Type) -> bool:
    match t:
        Type.ty_primitive as p:
            return p.name == "void"
        _:
            return false


public function is_str(t: Type) -> bool:
    match t:
        Type.ty_str:
            return true
        _:
            return false


## True only for the `bool` primitive.  Conditions accept nothing else (the
## host's `ensure_assignable!(bool)`): named types, pointers, nullables, `null`
## and `str` all reject.  Callers treat an unresolved type permissively.
public function is_bool_type(t: Type) -> bool:
    match t:
        Type.ty_primitive as p:
            return p.name == "bool"
        _:
            return false


public function is_numeric(t: Type) -> bool:
    match t:
        Type.ty_primitive as p:
            return is_numeric_name(p.name)
        _:
            return false


# ---------------------------------------------------------------------------
#  Rendering (mirrors Types::* #to_s), used for diagnostics
# ---------------------------------------------------------------------------

## The host's qualified `to_s` used by semantic diagnostics: named types carry
## their defining module (`std.vec.Vec[int]`), while the display form drops it.
public function type_to_diagnostic_string(t: Type) -> str:
    match t:
        Type.ty_named as n:
            let n_np = unsafe: read(n.payload)
            if n_np.module_name.len > 0:
                var b = string.String.create()
                b.append(n_np.module_name)
                b.append(".")
                b.append(n_np.name)
                return b.as_str()
            return n_np.name
        Type.ty_opaque as o:
            let o_bp = unsafe: read(o.payload)
            if o_bp.module_name.len > 0:
                var b = string.String.create()
                b.append(o_bp.module_name)
                b.append(".")
                b.append(o_bp.name)
                return b.as_str()
            return o_bp.name
        Type.ty_imported as im:
            let im_bp = unsafe: read(im.payload)
            var b = string.String.create()
            if im_bp.module_name.len > 0:
                b.append(im_bp.module_name)
                b.append(".")
            b.append(im_bp.name)
            if im_bp.args.len > 0:
                b.append("[")
                var i: ptr_uint = 0
                while i < im_bp.args.len:
                    if i > 0:
                        b.append(", ")
                    unsafe:
                        b.append(type_to_diagnostic_string(read(im_bp.args.data + i)))
                    i += 1
                b.append("]")
            return b.as_str()
        _:
            return type_to_string(t)


## The host's `Types::*#to_s` as the IR renderer needs it: a named type always
## carries its defining module (`examples.sdl3.demo.woodeneye.Player`), including
## when the type is local to the module being rendered, and every nested type
## argument is rendered the same way.  `type_to_string` is the *display* form
## (module dropped) used by the LSP and diagnostics, so the IR dump — which the
## host produces from `to_s` — needs this variant.
##
## The IR formatter writes straight into its output buffer; that is the only
## caller, so there is no string-returning wrapper.
public function append_qualified_type(target: ref[string.String], t: Type) -> void:
    match t:
        Type.ty_named as n:
            let n_np = unsafe: read(n.payload)
            if n_np.module_name.len > 0:
                target.append(n_np.module_name)
                target.append(".")
                target.append(n_np.name)
                return
            target.append(n_np.name)
        Type.ty_opaque as o:
            let o_bp = unsafe: read(o.payload)
            if o_bp.module_name.len > 0:
                target.append(o_bp.module_name)
                target.append(".")
                target.append(o_bp.name)
                return
            target.append(o_bp.name)
        Type.ty_imported as im:
            let im_bp = unsafe: read(im.payload)
            if im_bp.module_name.len > 0:
                target.append(im_bp.module_name)
                target.append(".")
            target.append(im_bp.name)
            if im_bp.args.len > 0:
                target.append("[")
                var i: ptr_uint = 0
                while i < im_bp.args.len:
                    if i > 0:
                        target.append(", ")
                    unsafe:
                        append_qualified_type(target, read(im_bp.args.data + i))
                    i += 1
                target.append("]")
        Type.ty_nullable as nl:
            unsafe:
                append_qualified_type(target, read(nl.base))
            target.append("?")
        Type.ty_generic as g:
            let g_bp = unsafe: read(g.payload)
            target.append(g_bp.name)
            target.append("[")
            var i: ptr_uint = 0
            while i < g_bp.args.len:
                if i > 0:
                    target.append(", ")
                unsafe:
                    append_qualified_type(target, read(g_bp.args.data + i))
                i += 1
            target.append("]")
        _:
            target.append(type_to_string(t))


public function type_to_string(t: Type) -> str:
    match t:
        Type.ty_primitive as p:
            return p.name
        Type.ty_str:
            return "str"
        Type.ty_error:
            return "<error>"
        Type.ty_nil:
            return "nil"
        Type.ty_type_meta:
            return "type"
        Type.ty_handle:
            return "Handle"
        Type.ty_named as n:
            let n_np = unsafe: read(n.payload)
            return n_np.name
        Type.ty_variant_arm_payload as ap:
            # The host's `VariantArmPayload#to_s` is `<variant>.<arm> payload`;
            # the lowering's constructions carry no display text, so they keep
            # the payload struct's own name.
            let payload = unsafe: read(ap.payload)
            if payload.display_name.len > 0:
                return payload.display_name
            return payload.name
        Type.ty_imported as im:
            let im_bp = unsafe: read(im.payload)
            if im_bp.args.len == 0:
                return im_bp.name
            return type_to_string(generic_type(name = im_bp.name, args = im_bp.args))
        Type.ty_var as v:
            return v.name
        Type.ty_lifetime as lt:
            return lt.name
        Type.ty_dyn as d:
            let d_bp = unsafe: read(d.payload)
            if d_bp.args.len == 0:
                var dbuf = string.String.create()
                dbuf.append("dyn[")
                dbuf.append(d_bp.iface)
                dbuf.append("]")
                return dbuf.as_str()
            var dbuf = string.String.create()
            dbuf.append("dyn[")
            dbuf.append(d_bp.iface)
            dbuf.append("[")
            var di: ptr_uint = 0
            while di < d_bp.args.len:
                if di > 0:
                    dbuf.append(", ")
                unsafe:
                    dbuf.append(type_to_string(read(d_bp.args.data + di)))
                di += 1
            dbuf.append("]]")
            return dbuf.as_str()
        Type.ty_dyn_vtable as dv:
            let dv_bp = unsafe: read(dv.payload)
            return dv_bp.linkage_name
        Type.ty_opaque as o:
            let o_bp = unsafe: read(o.payload)
            return o_bp.name
        Type.ty_nullable as nl:
            var buf = string.String.create()
            unsafe:
                buf.append(type_to_string(read(nl.base)))
            buf.append("?")
            return buf.as_str()
        Type.ty_null as nt:
            let target = nt.target else:
                return "null"
            var buf = string.String.create()
            buf.append("null[")
            unsafe:
                buf.append(type_to_string(read(target)))
            buf.append("]")
            return buf.as_str()
        Type.ty_event as ev:
            let ev_bp = unsafe: read(ev.payload)
            return ev_bp.name
        Type.ty_generic as g:
            let g_bp = unsafe: read(g.payload)
            var buf = string.String.create()
            buf.append(g_bp.name)
            buf.append("[")
            var i: ptr_uint = 0
            while i < g_bp.args.len:
                if i > 0:
                    buf.append(", ")
                unsafe:
                    buf.append(type_to_string(read(g_bp.args.data + i)))
                i += 1
            buf.append("]")
            return buf.as_str()
        Type.ty_function as fnt:
            let fnt_ft = unsafe: read(fnt.payload)
            if not fnt_ft.is_proc:
                # The host's `Types::Function#to_s` is `fn <name>` — an
                # anonymous function type (a field's `fn(…)` annotation) with no
                # name renders `fn `.
                var fbuf = string.String.create()
                fbuf.append("fn ")
                fbuf.append(fnt_ft.name)
                return fbuf.as_str()
            # The host's `Types::Proc#to_s` renders its parameters by *type*
            # alone (`proc(int) -> int`); a source annotation's names appear
            # only where the outline renders the annotation itself.
            var buf = string.String.create()
            buf.append("proc(")
            var i: ptr_uint = 0
            while i < fnt_ft.params.len:
                if i > 0:
                    buf.append(", ")
                unsafe:
                    buf.append(type_to_string(read(fnt_ft.params.data + i)))
                i += 1
            buf.append(") -> ")
            unsafe:
                buf.append(type_to_string(read(fnt_ft.return_type)))
            return buf.as_str()
        Type.ty_literal_int as lit:
            var buf = string.String.create()
            fmt.append_long(ref_of(buf), lit.value)
            return buf.as_str()
        Type.ty_tuple as tup:
            let tup_bp = unsafe: read(tup.payload)
            var buf = string.String.create()
            buf.append("(")
            var i: ptr_uint = 0
            while i < tup_bp.elements.len:
                if i > 0:
                    buf.append(", ")
                unsafe:
                    buf.append(type_to_string(read(tup_bp.elements.data + i)))
                i += 1
            buf.append(")")
            return buf.as_str()


# ---------------------------------------------------------------------------
#  Category-based incompatibility (mirrors Ruby's types_compatible? chain).
#  Returns true ONLY when concrete evidence proves target and source are
#  incompatible (e.g. narrowing an int to a byte, assigning a str to a bool).
#  Any uncertainty returns false (not flagged), so the analyzer never
#  false-positives.  When the predicate cannot decide, the types are treated
#  as compatible.
# ---------------------------------------------------------------------------

const CAT_BOOL: int = 1
const CAT_NUMERIC: int = 2
const CAT_STR: int = 3
const CAT_CSTR: int = 4
const CAT_OTHER: int = 0


function scalar_category(t: Type) -> int:
    match t:
        Type.ty_primitive as p:
            if p.name == "bool":
                return CAT_BOOL
            if p.name == "cstr":
                return CAT_CSTR
            if p.name == "str":
                return CAT_STR
            if is_numeric_name(p.name):
                return CAT_NUMERIC
            return CAT_OTHER
        Type.ty_str:
            return CAT_STR
        _:
            return CAT_OTHER


## Width in bits of an integer primitive, 0 for non-integers.  Pointer-sized
## integers are as wide as a pointer on the host platform (64), mirroring
## Ruby's `Primitive#integer_width` and its `POINTER_INTEGER_WIDTH`.
public function integer_width(name: str) -> int:
    if name == "byte" or name == "ubyte" or name == "char":
        return 8
    if name == "short" or name == "ushort":
        return 16
    if name == "int" or name == "uint":
        return 32
    if name == "long" or name == "ulong":
        return 64
    if name == "ptr_int" or name == "ptr_uint":
        return 64
    return 0


## True when `name` is a primitive integer with a known width — the host's
## `fixed_width_integer?`, which includes the pointer-sized integers.
public function is_fixed_width_integer_name(name: str) -> bool:
    return integer_width(name) != 0


## True for signed integer primitives, including the pointer-sized `ptr_int`
## (the host's `Primitive#signed_integer?`).  Unsigned types and non-integers
## return false.
public function is_signed_integer_name(name: str) -> bool:
    return (
        name == "byte" or name == "short" or name == "int"
        or name == "long" or name == "ptr_int"
    )


## True for unsigned integer primitives, mirroring the host's
## `Types::Primitive#unsigned_integer?` (`char` is neither signed nor unsigned
## and is handled by the char rules).  Used to render an integer literal in the
## unsigned domain: the host rejects a negated literal for these types
## (`negated value -1 does not fit in type ptr_uint`), so their literals are
## always meant as unsigned values and a `long` carrying the high bit set must
## print as `18446744073709551615`, not `-1`.
public function is_unsigned_integer_name(name: str) -> bool:
    return (
        name == "ubyte" or name == "ushort" or name == "uint"
        or name == "ulong" or name == "ptr_uint"
    )


## True when the integer constant `value` fits `name`'s range — the host's
## `value_fits_integer_type?` (`predicates.rb:123`).  A fixed-width integer's
## range is `[-2^(w-1), 2^(w-1)-1]` signed, `[0, 2^w-1]` unsigned.
public function integer_constant_fits(name: str, value: long) -> bool:
    if not is_fixed_width_integer_name(name):
        return false
    # `char` is a byte-sized unsigned code unit but neither signed nor unsigned
    # in the host's predicates; its literal range is the host's
    # `integer_constant_fits_in_char?`: 0..255.
    if name == "char":
        return value >= 0 and value <= 255
    let width = integer_width(name)
    if is_signed_integer_name(name):
        let max_value: long = (long<-1 << (width - 1)) - 1
        let min_value: long = -(long<-1 << (width - 1))
        return value >= min_value and value <= max_value
    if is_unsigned_integer_name(name):
        # `2^w - 1` does not fit a signed `long` for w=64, so every non-negative
        # value fits there.
        if value < 0:
            return false
        if width >= 64:
            return true
        let max_value: long = (long<-1 << width) - 1
        return value <= max_value
    return false


## Structural equality of two types.  Needed because variant == is not
## supported in the self-host C backend; this function pattern-matches
## both sides and compares fields manually.
public function type_equals(a: Type, b: Type) -> bool:
    match a:
        Type.ty_str:
            match b:
                Type.ty_str:
                    return true
                _:
                    return false
        Type.ty_error:
            match b:
                Type.ty_error:
                    return true
                _:
                    return false
        Type.ty_nil:
            match b:
                Type.ty_nil:
                    return true
                _:
                    return false
        Type.ty_type_meta:
            match b:
                Type.ty_type_meta:
                    return true
                _:
                    return false
        Type.ty_handle:
            match b:
                Type.ty_handle:
                    return true
                _:
                    return false
        Type.ty_primitive as pa:
            match b:
                Type.ty_primitive as pb:
                    return pa.name == pb.name
                _:
                    return false
        Type.ty_nullable as na:
            match b:
                Type.ty_nullable as nb:
                    return type_equals(unsafe: read(na.base), unsafe: read(nb.base))
                _:
                    return false
        Type.ty_null as na:
            match b:
                Type.ty_null as nb:
                    let ta = na.target
                    let tb = nb.target
                    if ta == null:
                        return tb == null
                    if tb == null:
                        return false
                    return type_equals(unsafe: read(ta), unsafe: read(tb))
                _:
                    return false
        Type.ty_event as ea:
            let ea_bp = unsafe: read(ea.payload)
            match b:
                Type.ty_event as eb:
                    let eb_bp = unsafe: read(eb.payload)
                    if ea_bp.name != eb_bp.name or ea_bp.capacity != eb_bp.capacity or ea_bp.linkage_name != eb_bp.linkage_name:
                        return false
                    let pa = ea_bp.payload_type
                    let pb = eb_bp.payload_type
                    if pa == null:
                        return pb == null
                    if pb == null:
                        return false
                    return type_equals(unsafe: read(pa), unsafe: read(pb))
                _:
                    return false
        Type.ty_named as na:
            let na_np = unsafe: read(na.payload)
            match b:
                Type.ty_named as nb:
                    let nb_np = unsafe: read(nb.payload)
                    return na_np.name == nb_np.name
                Type.ty_imported as ib:
                    let ib_bp = unsafe: read(ib.payload)
                    return na_np.name == ib_bp.name
                _:
                    return false
        Type.ty_variant_arm_payload as apa:
            match b:
                Type.ty_variant_arm_payload as apb:
                    return unsafe: read(apa.payload).c_name == unsafe: read(apb.payload).c_name
                _:
                    return false
        Type.ty_imported as ia:
            let ia_bp = unsafe: read(ia.payload)
            return imported_type_matches(ia_bp.module_name, ia_bp.name, ia_bp.args, b)
        Type.ty_var as va:
            match b:
                Type.ty_var as vb:
                    return va.name == vb.name
                _:
                    return false
        Type.ty_lifetime as la:
            match b:
                Type.ty_lifetime as lb:
                    return la.name == lb.name
                _:
                    return false
        Type.ty_dyn as da:
            let da_bp = unsafe: read(da.payload)
            match b:
                Type.ty_dyn as db:
                    let db_bp = unsafe: read(db.payload)
                    if da_bp.iface != db_bp.iface or da_bp.args.len != db_bp.args.len:
                        return false
                    var di: ptr_uint = 0
                    while di < da_bp.args.len:
                        unsafe:
                            if not type_equals(read(da_bp.args.data + di), read(db_bp.args.data + di)):
                                return false
                        di += 1
                    return true
                _:
                    return false
        Type.ty_dyn_vtable as dva:
            let dva_bp = unsafe: read(dva.payload)
            match b:
                Type.ty_dyn_vtable as dvb:
                    let dvb_bp = unsafe: read(dvb.payload)
                    return dva_bp.linkage_name == dvb_bp.linkage_name
                _:
                    return false
        Type.ty_opaque as oa:
            let oa_bp = unsafe: read(oa.payload)
            match b:
                Type.ty_opaque as ob:
                    let ob_bp = unsafe: read(ob.payload)
                    return oa_bp.module_name == ob_bp.module_name and oa_bp.name == ob_bp.name
                _:
                    return false
        Type.ty_generic as ga:
            let ga_bp = unsafe: read(ga.payload)
            return generic_type_matches(ga_bp.name, ga_bp.args, b)
        Type.ty_function as fa:
            let fa_ft = unsafe: read(fa.payload)
            match b:
                Type.ty_function as fb:
                    let fb_ft = unsafe: read(fb.payload)
                    if fa_ft.variadic != fb_ft.variadic:
                        return false
                    if fa_ft.params.len != fb_ft.params.len:
                        return false
                    if not type_equals(unsafe: read(fa_ft.return_type), unsafe: read(fb_ft.return_type)):
                        return false
                    var i: ptr_uint = 0
                    while i < fa_ft.params.len:
                        unsafe:
                            if not type_equals(read(fa_ft.params.data + i), read(fb_ft.params.data + i)):
                                return false
                        i += 1
                    return true
                _:
                    return false
        Type.ty_literal_int as la:
            match b:
                Type.ty_literal_int as lb:
                    return la.value == lb.value
                _:
                    return false
        Type.ty_tuple as ta:
            let ta_bp = unsafe: read(ta.payload)
            match b:
                Type.ty_tuple as tb:
                    let tb_bp = unsafe: read(tb.payload)
                    if ta_bp.elements.len != tb_bp.elements.len:
                        return false
                    var i: ptr_uint = 0
                    while i < ta_bp.elements.len:
                        unsafe:
                            if not type_equals(read(ta_bp.elements.data + i), read(tb_bp.elements.data + i)):
                                return false
                        i += 1
                    return true
                _:
                    return false


## Equality of an imported type against another type (imported, named, or the
## prelude generic spelling).
function imported_type_matches(module_name: str, name: str, args: span[Type], b: Type) -> bool:
    match b:
        Type.ty_imported as ib:
            let ib_bp = unsafe: read(ib.payload)
            if not module_name == ib_bp.module_name or not name == ib_bp.name:
                return false
            if args.len != ib_bp.args.len:
                return false
            var i: ptr_uint = 0
            while i < args.len:
                unsafe:
                    if not type_equals(read(args.data + i), read(ib_bp.args.data + i)):
                        return false
                i += 1
            return true
        Type.ty_named as nb:
            let nb_np = unsafe: read(nb.payload)
            return name == nb_np.name and args.len == 0
        Type.ty_generic as gb:
            let gb_bp = unsafe: read(gb.payload)
            if not name == gb_bp.name or args.len != gb_bp.args.len:
                return false
            let prelude = (name == "Option" and module_name == "std.option") or (name == "Result" and module_name == "std.result")
            if not prelude:
                return false
            var i3: ptr_uint = 0
            while i3 < args.len:
                unsafe:
                    if not type_equals(read(args.data + i3), read(gb_bp.args.data + i3)):
                        return false
                i3 += 1
            return true
        _:
            return false


## Equality of a generic type against another generic or the imported prelude
## spelling (`std.option.Option` / `std.result.Result`).
function generic_type_matches(name: str, args: span[Type], b: Type) -> bool:
    match b:
        Type.ty_generic as gb:
            let gb_bp = unsafe: read(gb.payload)
            if not name == gb_bp.name:
                return false
            if args.len != gb_bp.args.len:
                return false
            var i: ptr_uint = 0
            while i < args.len:
                unsafe:
                    if not type_equals(read(args.data + i), read(gb_bp.args.data + i)):
                        return false
                i += 1
            return true
        Type.ty_imported as ib:
            let ib_bp = unsafe: read(ib.payload)
            # The prelude variants appear both as the bare generic
            # (`Option[T]`/`Result[T, E]`) and as their imported definition
            # (`std.option.Option`/`std.result.Result`).
            if not name == ib_bp.name or args.len != ib_bp.args.len:
                return false
            let prelude = (name == "Option" and ib_bp.module_name == "std.option") or (name == "Result" and ib_bp.module_name == "std.result")
            if not prelude:
                return false
            var i2: ptr_uint = 0
            while i2 < args.len:
                unsafe:
                    if not type_equals(read(args.data + i2), read(ib_bp.args.data + i2)):
                        return false
                i2 += 1
            return true
        _:
            return false


## True when `t` is a raw pointer (ptr[T] or const_ptr[T]), excluding ref,
## span, and array.
public function is_raw_pointer(t: Type) -> bool:
    match t:
        Type.ty_generic as g:
            let g_bp = unsafe: read(g.payload)
            return g_bp.name == "ptr" or g_bp.name == "const_ptr"
        Type.ty_nullable as nl:
            return is_raw_pointer(unsafe: read(nl.base))
        _:
            return false


## True when `t` is an owning heap pointer (own[T] or own[T]?).  An `own[T]`
## auto-dereferences at the language level: member access and `read()` treat it
## like a pointer to its referent (mirrors Ruby's `own_type?`, and `own` being
## part of `pointer_type?`).
public function is_own_type(t: Type) -> bool:
    match t:
        Type.ty_generic as g:
            let g_bp = unsafe: read(g.payload)
            return g_bp.name == "own"
        Type.ty_nullable as nl:
            return is_own_type(unsafe: read(nl.base))
        _:
            return false


## True when `t` is a raw or owning pointer (`ptr`/`const_ptr`/`own`).  Unlike
## `is_raw_pointer` it does not unwrap a nullable and excludes `ref` — the host's
## `pointer_type?`, which `pointer_cast_type?` and `cast_numeric_type` build on.
public function is_pointer_type(t: Type) -> bool:
    match t:
        Type.ty_generic as g:
            let g_bp = unsafe: read(g.payload)
            return g_bp.name == "ptr" or g_bp.name == "const_ptr" or g_bp.name == "own"
        _:
            return false


## True when `t` is a pointer-represented value a cast may reinterpret: a
## pointer (`ptr`/`const_ptr`/`own`), `cstr`, a function value, a nullable of a
## pointer or function, or a typed null to one of those.  Mirrors the host's
## `pointer_cast_type?`, which gates both cast diagnostics.
public function is_pointer_cast_type(t: Type) -> bool:
    match t:
        Type.ty_primitive as p:
            return p.name == "cstr"
        Type.ty_null as n:
            let target = n.target else:
                return false
            return is_typed_null_target(unsafe: read(target))
        Type.ty_nullable as nl:
            let base = unsafe: read(nl.base)
            match base:
                Type.ty_function:
                    return true
                _:
                    return is_pointer_type(base)
        Type.ty_function:
            return true
        _:
            return is_pointer_type(t)


## The host's `typed_null_target_type?`: a typed null is castable to `cstr`, a
## pointer, or a function value.
public function is_typed_null_target(t: Type) -> bool:
    match t:
        Type.ty_primitive as p:
            return p.name == "cstr"
        Type.ty_function:
            return true
        _:
            return is_pointer_type(t)


## The host's `cast_numeric_type`: the type a numeric cast goes through, when
## there is one.  Primitives (numeric, `bool`, `char`) qualify; an `EnumBase`
## qualifies through its backing type, which the caller decides (it owns the
## declaration tables).
public function cast_numeric_type(t: Type) -> Option[Type]:
    match t:
        Type.ty_primitive as p:
            if is_numeric_name(p.name) or p.name == "bool" or p.name == "char":
                return Option[Type].some(value = t)
            return Option[Type].none
        _:
            return Option[Type].none


## The element type of a pointer or array-like type.  Returns ty_error for
## anything that is not ptr / const_ptr / ref / span / array.  A `ref` may carry
## an explicit lifetime as its first argument (`ref[@a, T]`), so its referent is
## the last argument (mirrors the host's `referenced_type`).
public function pointer_element(t: Type) -> Type:
    match t:
        Type.ty_generic as g:
            let g_bp = unsafe: read(g.payload)
            if g_bp.args.len >= 1:
                if g_bp.name == "ref":
                    return unsafe: read(g_bp.args.data + (g_bp.args.len - 1))
                return unsafe: read(g_bp.args.data + 0)
            return Type.ty_error
        _:
            return Type.ty_error


## True when `t` is a ref type (ref[T] or ref[@a, T]).
public function is_ref_type(t: Type) -> bool:
    match t:
        Type.ty_generic as g:
            let g_bp = unsafe: read(g.payload)
            return g_bp.name == "ref"
        _:
            return false


## True when `t` is a SIMD vector type (simd[E, N]).
public function is_simd_type(t: Type) -> bool:
    match t:
        Type.ty_generic as g:
            let g_bp = unsafe: read(g.payload)
            return g_bp.name == "simd" and g_bp.args.len == 2
        _:
            return false


## The lane element type of a simd[E, N] type, or ty_error.
public function simd_element_type(t: Type) -> Type:
    match t:
        Type.ty_generic as g:
            let g_bp = unsafe: read(g.payload)
            if g_bp.name == "simd" and g_bp.args.len >= 1:
                return unsafe: read(g_bp.args.data + 0)
            return Type.ty_error
        _:
            return Type.ty_error


## The lane count of a simd[E, N] type, or 0 when unknown.
public function simd_lane_count(t: Type) -> long:
    match t:
        Type.ty_generic as g:
            let g_bp = unsafe: read(g.payload)
            if g_bp.name == "simd" and g_bp.args.len >= 2:
                match unsafe: read(g_bp.args.data + 1):
                    Type.ty_literal_int as lit:
                        return lit.value
                    _:
                        return 0
            return 0
        _:
            return 0


## True when `t` is a primitive integer (fixed-width or pointer-sized).
public function is_integer_type(t: Type) -> bool:
    match t:
        Type.ty_primitive as p:
            return is_integer_name(p.name)
        _:
            return false


## True when `t` is an unsigned primitive integer (`ubyte`/`ushort`/`uint`/
## `ulong`/`ptr_uint`).  Integer literals of these types are rendered in the
## unsigned domain — see `is_unsigned_integer_name`.
public function is_unsigned_integer_type(t: Type) -> bool:
    match t:
        Type.ty_primitive as p:
            return is_unsigned_integer_name(p.name)
        _:
            return false


## True when `t` is a primitive float (float or double).
public function is_float_type(t: Type) -> bool:
    match t:
        Type.ty_primitive as p:
            return p.name == "float" or p.name == "double"
        _:
            return false


## True when `t` is the char primitive.
public function is_char_type(t: Type) -> bool:
    match t:
        Type.ty_primitive as p:
            return p.name == "char"
        _:
            return false


## True when `t` is nullable (ty_nullable variant).
public function is_nullable_type(t: Type) -> bool:
    match t:
        Type.ty_nullable:
            return true
        _:
            return false


## Lossless integer assignment: source can be stored in target without
## truncation.  Same-bit signed source → unsigned target is treated as
## incompatible unless target is strictly wider.  Mirrors Ruby’s
## lossless_integer_compatibility?.
public function lossless_integer_assignable(target_name: str, source_name: str) -> bool:
    let tw = integer_width(target_name)
    let sw = integer_width(source_name)
    if tw == 0 or sw == 0:
        return false
    let tsig = is_signed_integer_name(target_name)
    let ssig = is_signed_integer_name(source_name)
    if tsig == ssig:
        return tw >= sw
    if not ssig and tsig:
        # unsigned source fits into wider signed target
        return tw > sw
    # signed source → unsigned target: not lossless (sign bit)
    return false


## The referent of a nullable type, or `t` itself when it is not nullable.
public function unwrap_nullable(t: Type) -> Type:
    match t:
        Type.ty_nullable as n:
            return unsafe: read(n.base)
        _:
            return t


## True when `t` is a nominal type (a user-declared struct / enum / flags /
## variant / opaque), either local (`ty_named`) or imported (`ty_imported`).
public function is_nominal_type(t: Type) -> bool:
    match t:
        Type.ty_named:
            return true
        Type.ty_imported:
            return true
        _:
            return false


## True when `t` is a builtin generic instance (ptr / const_ptr / ref / span /
## array / Option / Result / ...).  User generic structs resolve to ty_error, so
## every ty_generic here is a builtin container.
public function is_generic_type(t: Type) -> bool:
    match t:
        Type.ty_generic:
            return true
        _:
            return false


## A canonical identity string for a nominal type, used to decide whether two
## nominals denote the same type.  Local names compare by bare name; imported
## names compare by `module.name`.
public function nominal_key(t: Type) -> str:
    match t:
        Type.ty_named as n:
            let n_np = unsafe: read(n.payload)
            return n_np.name
        Type.ty_imported as im:
            let im_bp = unsafe: read(im.payload)
            var buf = string.String.create()
            buf.append(im_bp.module_name)
            buf.append(".")
            buf.append(im_bp.name)
            return buf.as_str()
        _:
            return ""


## Bare (unqualified) nominal type name, "" for non-nominal types.
public function nominal_name(t: Type) -> str:
    match t:
        Type.ty_named as n:
            let n_np = unsafe: read(n.payload)
            return n_np.name
        Type.ty_imported as im:
            let im_bp = unsafe: read(im.payload)
            return im_bp.name
        _:
            return ""


## Module qualifier of a nominal type, "" when unqualified/unknown.
public function nominal_module(t: Type) -> str:
    match t:
        Type.ty_named as n:
            let n_np = unsafe: read(n.payload)
            return n_np.module_name
        Type.ty_imported as im:
            let im_bp = unsafe: read(im.payload)
            return im_bp.module_name
        _:
            return ""


## Two nominal types are provably distinct only when their bare names differ,
## or when both carry a known module qualifier and the modules differ.  A bare
## `ty_named` is often a degraded representation of the same imported type
## (e.g. an imported method's return type resolved without its module), so a
## missing qualifier on either side stays permissive.
function nominal_definitely_different(a: Type, b: Type) -> bool:
    if not nominal_name(a) == nominal_name(b):
        return true

    let module_a = nominal_module(a)
    let module_b = nominal_module(b)
    if module_a.len == 0 or module_b.len == 0:
        return false

    return not module_a == module_b


const KIND_UNKNOWN: int = 0
const KIND_SCALAR: int = 1
const KIND_NOMINAL: int = 2
const KIND_GENERIC: int = 3


## Coarse structural kind for definite-difference comparison.  Error, type
## variable, nullable, dyn, function, and the type-meta all map to `unknown`
## so they never force a mismatch.
function type_kind(t: Type) -> int:
    match t:
        Type.ty_primitive:
            return KIND_SCALAR
        Type.ty_str:
            return KIND_SCALAR
        Type.ty_named:
            return KIND_NOMINAL
        Type.ty_imported:
            return KIND_NOMINAL
        Type.ty_generic:
            return KIND_GENERIC
        _:
            return KIND_UNKNOWN


function scalar_definitely_different(a: Type, b: Type) -> bool:
    match a:
        Type.ty_primitive as pa:
            match b:
                Type.ty_primitive as pb:
                    return not pa.name == pb.name
                Type.ty_str:
                    return true
                _:
                    return false
        Type.ty_str:
            match b:
                Type.ty_str:
                    return false
                Type.ty_primitive:
                    return true
                _:
                    return false
        _:
            return false


function generic_definitely_different(a: Type, b: Type) -> bool:
    match a:
        Type.ty_generic as ga:
            let ga_bp = unsafe: read(ga.payload)
            match b:
                Type.ty_generic as gb:
                    let gb_bp = unsafe: read(gb.payload)
                    # Different constructors stay permissive: mutable→const
                    # pointer and array→span coercions are legal, so a bare
                    # name mismatch is not proof of incompatibility.
                    if not ga_bp.name == gb_bp.name:
                        return false
                    if ga_bp.args.len != gb_bp.args.len:
                        return false
                    var i: ptr_uint = 0
                    while i < ga_bp.args.len:
                        unsafe:
                            if definitely_different(read(ga_bp.args.data + i), read(gb_bp.args.data + i)):
                                return true
                        i += 1
                    return false
                _:
                    return false
        _:
            return false


## True when `a` and `b` are provably distinct types (invariant equality with a
## permissive fallback).  Used for nominal identity and generic type arguments,
## where Ruby requires exact `==` rather than assignability.  Any uncertainty
## (error, type variable, mismatched nullability, differing generic
## constructors) returns false.
public function definitely_different(a: Type, b: Type) -> bool:
    if is_error(a) or is_error(b):
        return false
    match a:
        Type.ty_var:
            return false
        _:
            pass
    match b:
        Type.ty_var:
            return false
        _:
            pass
    if is_nullable_type(a) and is_nullable_type(b):
        return definitely_different(unwrap_nullable(a), unwrap_nullable(b))
    if is_nullable_type(a) or is_nullable_type(b):
        return false

    let ka = type_kind(a)
    let kb = type_kind(b)
    if ka == KIND_UNKNOWN or kb == KIND_UNKNOWN:
        return false
    if ka == KIND_SCALAR and kb == KIND_SCALAR:
        return scalar_definitely_different(a, b)
    if ka == KIND_NOMINAL and kb == KIND_NOMINAL:
        return nominal_definitely_different(a, b)
    if ka == KIND_GENERIC and kb == KIND_GENERIC:
        return generic_definitely_different(a, b)
    # Cross-kind: only a nominal-vs-scalar pair is provably incompatible.  Any
    # pairing that involves a generic stays permissive because of implicit
    # coercions — a `ref[T]` parameter borrows a `T` argument, an array coerces
    # to a span, and a mutable pointer coerces to a const pointer.
    if ka == KIND_NOMINAL and kb == KIND_SCALAR:
        return true
    if ka == KIND_SCALAR and kb == KIND_NOMINAL:
        return true
    return false


public function definitely_incompatible(target: Type, source: Type) -> bool:
    if is_error(target) or is_error(source):
        return false

    # Nullability.  T? ← T? compares bases; T? ← T checks the base; T ← T? is a
    # mismatch — the host's `types_compatible?` has no coercion for it and a
    # guarded use is narrowed to its base by the flow refinement before it
    # reaches here.  Unresolved components (type variables, errors) stay
    # permissive.
    let tn = is_nullable_type(target)
    let sn = is_nullable_type(source)
    if tn and sn:
        return definitely_incompatible(unwrap_nullable(target), unwrap_nullable(source))
    if tn:
        return definitely_incompatible(unwrap_nullable(target), source)
    if sn:
        if type_kind(target) == KIND_UNKNOWN or type_kind(unwrap_nullable(source)) == KIND_UNKNOWN:
            return false
        if contains_type_var(target) or contains_type_var(source):
            return false
        return true

    # Integer ↔ char: any integer (including untagged literals) is assignable
    # to char; char is assignable to any integer.
    if is_char_type(target) and is_integer_type(source):
        return false
    if is_integer_type(target) and is_char_type(source):
        return false

    # Lossless integer assignment: a smaller or same-sign wider integer is
    # always compatible.  A definite fixed-width narrowing (int→byte) or a
    # same-width sign change (int→uint) is flagged, matching Ruby's
    # lossless_integer_compatibility?.  Numeric literals bypass this at the
    # call site (see incompatible_value), just as Ruby const-evaluates them.
    # Pointer-sized integers (ptr_int/ptr_uint) are not fixed-width, so they
    # stay permissive.
    if is_integer_type(target) and is_integer_type(source):
        match target:
            Type.ty_primitive as tp:
                match source:
                    Type.ty_primitive as sp:
                        if is_fixed_width_integer_name(tp.name) and is_fixed_width_integer_name(sp.name):
                            if lossless_integer_assignable(tp.name, sp.name):
                                return false
                            return true
                        return false
                    _:
                        pass
            _:
                pass
        return false

    # Integer → float: contextual coercion, always permitted.
    if is_float_type(target) and is_integer_type(source):
        return false
    # Float → integer: requires an explicit cast (float literals are gated at
    # the call site via incompatible_value).
    if is_integer_type(target) and is_float_type(source):
        return true

    # Nominal / generic mismatch: two structs, enums, or containers are
    # compatible only when they denote the same type (invariant), and are never
    # compatible with a scalar.
    if is_nominal_type(target) or is_generic_type(target) or is_nominal_type(source) or is_generic_type(source):
        return definitely_different(target, source)

    let tc = scalar_category(target)
    let sc = scalar_category(source)
    if tc == CAT_OTHER or sc == CAT_OTHER:
        return false
    return tc != sc


# ---------------------------------------------------------------------------
#  Interning — one canonical node per distinct type
# ---------------------------------------------------------------------------
#  A `TypeId` is an index into a compilation-wide table, so a recursive IR node
#  carries 4 bytes instead of a 72-byte `Type` value.  The relation used to
#  deduplicate is *stricter* than `type_equals`: that predicate deliberately
#  treats the prelude spellings `Option[T]`/`std.option.Option[T]` as equal and
#  a `ty_named` as equal to a matching `ty_imported`, because assignment is
#  allowed between them.  They *render* differently, so merging them here would
#  silently rewrite every IR dump and every generated C type.  `type_identical`
#  therefore compares the variant tag first and never crosses variants.

const TYPE_SEED: uint = 0x811C9DC5
const TYPE_PRIME: uint = 0x01000193


## Fold one more byte into a running FNV-1a hash.
function hash_byte(current: uint, byte_value: ubyte) -> uint:
    return (current ^ uint<-byte_value) * TYPE_PRIME


## Fold a string into a running hash (length-prefixed so `"ab"` + `"c"` and
## `"a"` + `"bc"` cannot collide across fields).
function hash_str(current: uint, text: str) -> uint:
    var h = current
    h = hash_byte(h, ubyte<-(text.len & 0xFF))
    h = hash_byte(h, ubyte<-((text.len >> 8) & 0xFF))
    var i: ptr_uint = 0
    while i < text.len:
        h = hash_byte(h, text.byte_at(i))
        i += 1
    return h


## Fold a 64-bit value into a running hash.
function hash_word(current: uint, value: ulong) -> uint:
    var h = current
    var remaining = value
    var i: ptr_uint = 0
    while i < 8:
        h = hash_byte(h, ubyte<-(remaining & 0x00000000000000FF))
        remaining = remaining >> 8
        i += 1
    return h


## The variant tag, so two variants with coincidentally equal payload bytes do
## not hash alike.
public function type_tag_index(t: Type) -> uint:
    match t:
        Type.ty_primitive:
            return 1
        Type.ty_str:
            return 2
        Type.ty_error:
            return 3
        Type.ty_nil:
            return 4
        Type.ty_type_meta:
            return 5
        Type.ty_handle:
            return 6
        Type.ty_nullable:
            return 7
        Type.ty_null:
            return 8
        Type.ty_event:
            return 9
        Type.ty_named:
            return 10
        Type.ty_variant_arm_payload:
            return 11
        Type.ty_imported:
            return 12
        Type.ty_var:
            return 13
        Type.ty_lifetime:
            return 14
        Type.ty_dyn:
            return 15
        Type.ty_dyn_vtable:
            return 16
        Type.ty_opaque:
            return 17
        Type.ty_generic:
            return 18
        Type.ty_function:
            return 19
        Type.ty_literal_int:
            return 20
        Type.ty_tuple:
            return 21


## The structural hash of `t` under the interning relation.
public function type_hash(t: Type) -> uint:
    var h = hash_word(TYPE_SEED, ulong<-type_tag_index(t))
    match t:
        Type.ty_primitive as p:
            return hash_str(h, p.name)
        Type.ty_str:
            return h
        Type.ty_error:
            return h
        Type.ty_nil:
            return h
        Type.ty_type_meta:
            return h
        Type.ty_handle:
            return h
        Type.ty_nullable as n:
            return hash_word(h, ulong<-type_hash(unsafe: read(n.base)))
        Type.ty_null as n:
            let target = n.target
            if target == null:
                return h
            return hash_word(h, ulong<-type_hash(unsafe: read(target)))
        Type.ty_event as e:
            let e_bp = unsafe: read(e.payload)
            h = hash_str(h, e_bp.name)
            h = hash_word(h, ulong<-e_bp.capacity)
            h = hash_str(h, e_bp.linkage_name)
            let payload_type = e_bp.payload_type
            if payload_type == null:
                return h
            return hash_word(h, ulong<-type_hash(unsafe: read(payload_type)))
        Type.ty_named as n:
            let n_np = unsafe: read(n.payload)
            h = hash_str(h, n_np.name)
            h = hash_str(h, n_np.module_name)
            match n_np.linkage_name:
                Option.some as linkage:
                    h = hash_byte(h, ubyte<-1)
                    return hash_str(h, linkage.value)
                Option.none:
                    return hash_byte(h, ubyte<-0)
        Type.ty_variant_arm_payload as p:
            let payload = unsafe: read(p.payload)
            h = hash_str(h, payload.c_name)
            h = hash_str(h, payload.display_name)
            h = hash_str(h, payload.name)
            h = hash_str(h, payload.variant_name)
            h = hash_str(h, payload.module_name)
            h = hash_word(h, ulong<-payload.fields.len)
            var fi: ptr_uint = 0
            while fi < payload.fields.len:
                var field: PayloadField
                unsafe:
                    field = read(payload.fields.data + fi)
                h = hash_str(h, field.name)
                h = hash_word(h, ulong<-type_hash(field.ty))
                fi += 1
            return h
        Type.ty_imported as i:
            let i_bp = unsafe: read(i.payload)
            h = hash_str(h, i_bp.module_name)
            h = hash_str(h, i_bp.name)
            return hash_types(h, i_bp.args)
        Type.ty_var as v:
            return hash_str(h, v.name)
        Type.ty_lifetime as l:
            return hash_str(h, l.name)
        Type.ty_dyn as d:
            let d_bp = unsafe: read(d.payload)
            h = hash_str(h, d_bp.iface)
            return hash_types(h, d_bp.args)
        Type.ty_dyn_vtable as d:
            let d_bp = unsafe: read(d.payload)
            return hash_str(h, d_bp.linkage_name)
        Type.ty_opaque as o:
            let o_bp = unsafe: read(o.payload)
            h = hash_str(h, o_bp.module_name)
            return hash_str(h, o_bp.name)
        Type.ty_generic as g:
            let g_bp = unsafe: read(g.payload)
            h = hash_str(h, g_bp.name)
            return hash_types(h, g_bp.args)
        Type.ty_function as f:
            let f_ft = unsafe: read(f.payload)
            h = hash_str(h, f_ft.name)
            h = hash_word(h, ulong<-type_hash(unsafe: read(f_ft.return_type)))
            h = hash_types(h, f_ft.params)
            var pi: ptr_uint = 0
            while pi < f_ft.param_names.len:
                var pname: str
                unsafe:
                    pname = read(f_ft.param_names.data + pi)
                h = hash_str(h, pname)
                pi += 1
            h = hash_word(h, ulong<-f_ft.param_names.len)
            h = hash_byte(h, ubyte<-1)
            if f_ft.variadic:
                h = hash_byte(h, ubyte<-1)
            else:
                h = hash_byte(h, ubyte<-0)
            if f_ft.is_proc:
                return hash_byte(h, ubyte<-1)
            return hash_byte(h, ubyte<-0)
        Type.ty_literal_int as l:
            return hash_word(h, ulong<-l.value)
        Type.ty_tuple as tp:
            let tp_bp = unsafe: read(tp.payload)
            h = hash_types(h, tp_bp.elements)
            match tp_bp.field_names:
                Option.some as names:
                    h = hash_byte(h, ubyte<-1)
                    var ni: ptr_uint = 0
                    while ni < names.value.len:
                        var field_name: str
                        unsafe:
                            field_name = read(names.value.data + ni)
                        h = hash_str(h, field_name)
                        ni += 1
                    return h
                Option.none:
                    return hash_byte(h, ubyte<-0)


## Fold a type sequence into a running hash.
function hash_types(current: uint, items: span[Type]) -> uint:
    var h = hash_word(current, ulong<-items.len)
    var i: ptr_uint = 0
    while i < items.len:
        var item: Type
        unsafe:
            item = read(items.data + i)
        h = hash_word(h, ulong<-type_hash(item))
        i += 1
    return h


## Strict structural identity: the interning relation.  Equal only when the
## variant tags match and every field is identical under this same relation.
public function type_identical(a: Type, b: Type) -> bool:
    if type_tag_index(a) != type_tag_index(b):
        return false
    match a:
        Type.ty_primitive as pa:
            match b:
                Type.ty_primitive as pb:
                    return pa.name == pb.name
                _:
                    return false
        Type.ty_str:
            return true
        Type.ty_error:
            return true
        Type.ty_nil:
            return true
        Type.ty_type_meta:
            return true
        Type.ty_handle:
            return true
        Type.ty_nullable as na:
            match b:
                Type.ty_nullable as nb:
                    return type_identical(unsafe: read(na.base), unsafe: read(nb.base))
                _:
                    return false
        Type.ty_null as na:
            match b:
                Type.ty_null as nb:
                    let ta = na.target
                    let tb = nb.target
                    if ta == null:
                        return tb == null
                    if tb == null:
                        return false
                    return type_identical(unsafe: read(ta), unsafe: read(tb))
                _:
                    return false
        _:
            return identical_aggregate_arm(a, b)

## The aggregate `Type` arms of `type_identical`: every arm whose fields
## live behind a boxed payload.  Split out so the dispatcher stays within
## the function-size limit; the caller has already established that both
## values carry the same variant tag.
function identical_aggregate_arm(a: Type, b: Type) -> bool:
    match a:
        Type.ty_event as ea:
            let ea_bp = unsafe: read(ea.payload)
            match b:
                Type.ty_event as eb:
                    let eb_bp = unsafe: read(eb.payload)
                    if ea_bp.name != eb_bp.name or ea_bp.capacity != eb_bp.capacity or ea_bp.linkage_name != eb_bp.linkage_name:
                        return false
                    let pa = ea_bp.payload_type
                    let pb = eb_bp.payload_type
                    if pa == null:
                        return pb == null
                    if pb == null:
                        return false
                    return type_identical(unsafe: read(pa), unsafe: read(pb))
                _:
                    return false
        Type.ty_named as na:
            let na_np = unsafe: read(na.payload)
            match b:
                Type.ty_named as nb:
                    let nb_np = unsafe: read(nb.payload)
                    if na_np.name != nb_np.name or na_np.module_name != nb_np.module_name:
                        return false
                    match na_np.linkage_name:
                        Option.some as la:
                            match nb_np.linkage_name:
                                Option.some as lb:
                                    return la.value == lb.value
                                Option.none:
                                    return false
                        Option.none:
                            match nb_np.linkage_name:
                                Option.some:
                                    return false
                                Option.none:
                                    return true
                _:
                    return false
        Type.ty_variant_arm_payload as pa:
            match b:
                Type.ty_variant_arm_payload as pb:
                    let left = unsafe: read(pa.payload)
                    let right = unsafe: read(pb.payload)
                    if left.c_name != right.c_name or left.display_name != right.display_name:
                        return false
                    if left.name != right.name or left.variant_name != right.variant_name:
                        return false
                    if left.module_name != right.module_name or left.fields.len != right.fields.len:
                        return false
                    var fi: ptr_uint = 0
                    while fi < left.fields.len:
                        var lf: PayloadField
                        var rf: PayloadField
                        unsafe:
                            lf = read(left.fields.data + fi)
                            rf = read(right.fields.data + fi)
                        if lf.name != rf.name or not type_identical(lf.ty, rf.ty):
                            return false
                        fi += 1
                    return true
                _:
                    return false
        Type.ty_imported as ia:
            let ia_bp = unsafe: read(ia.payload)
            match b:
                Type.ty_imported as ib:
                    let ib_bp = unsafe: read(ib.payload)
                    return ia_bp.module_name == ib_bp.module_name and ia_bp.name == ib_bp.name and types_identical(ia_bp.args, ib_bp.args)
                _:
                    return false
        Type.ty_var as va:
            match b:
                Type.ty_var as vb:
                    return va.name == vb.name
                _:
                    return false
        Type.ty_lifetime as la:
            match b:
                Type.ty_lifetime as lb:
                    return la.name == lb.name
                _:
                    return false
        Type.ty_dyn as da:
            let da_bp = unsafe: read(da.payload)
            match b:
                Type.ty_dyn as db:
                    let db_bp = unsafe: read(db.payload)
                    return da_bp.iface == db_bp.iface and types_identical(da_bp.args, db_bp.args)
                _:
                    return false
        Type.ty_dyn_vtable as da:
            let da_bp = unsafe: read(da.payload)
            match b:
                Type.ty_dyn_vtable as db:
                    let db_bp = unsafe: read(db.payload)
                    return da_bp.linkage_name == db_bp.linkage_name
                _:
                    return false
        Type.ty_opaque as oa:
            let oa_bp = unsafe: read(oa.payload)
            match b:
                Type.ty_opaque as ob:
                    let ob_bp = unsafe: read(ob.payload)
                    return oa_bp.module_name == ob_bp.module_name and oa_bp.name == ob_bp.name
                _:
                    return false
        Type.ty_generic as ga:
            let ga_bp = unsafe: read(ga.payload)
            match b:
                Type.ty_generic as gb:
                    let gb_bp = unsafe: read(gb.payload)
                    return ga_bp.name == gb_bp.name and types_identical(ga_bp.args, gb_bp.args)
                _:
                    return false
        Type.ty_function as fa:
            let fa_ft = unsafe: read(fa.payload)
            match b:
                Type.ty_function as fb:
                    let fb_ft = unsafe: read(fb.payload)
                    if fa_ft.variadic != fb_ft.variadic or fa_ft.is_proc != fb_ft.is_proc:
                        return false
                    if fa_ft.name != fb_ft.name:
                        return false
                    if not type_identical(unsafe: read(fa_ft.return_type), unsafe: read(fb_ft.return_type)):
                        return false
                    if fa_ft.param_names.len != fb_ft.param_names.len:
                        return false
                    var pni: ptr_uint = 0
                    while pni < fa_ft.param_names.len:
                        unsafe:
                            if read(fa_ft.param_names.data + pni) != read(fb_ft.param_names.data + pni):
                                return false
                        pni += 1
                    return types_identical(fa_ft.params, fb_ft.params)
                _:
                    return false
        Type.ty_literal_int as la:
            match b:
                Type.ty_literal_int as lb:
                    return la.value == lb.value
                _:
                    return false
        Type.ty_tuple as ta:
            let ta_bp = unsafe: read(ta.payload)
            match b:
                Type.ty_tuple as tb:
                    let tb_bp = unsafe: read(tb.payload)
                    if not types_identical(ta_bp.elements, tb_bp.elements):
                        return false
                    match ta_bp.field_names:
                        Option.some as na:
                            match tb_bp.field_names:
                                Option.some as nb:
                                    if na.value.len != nb.value.len:
                                        return false
                                    var ni: ptr_uint = 0
                                    while ni < na.value.len:
                                        unsafe:
                                            if read(na.value.data + ni) != read(nb.value.data + ni):
                                                return false
                                        ni += 1
                                    return true
                                Option.none:
                                    return false
                        Option.none:
                            match tb_bp.field_names:
                                Option.some:
                                    return false
                                Option.none:
                                    return true
                _:
                    return false
        _:
            return false

## Identity of two type sequences.
function types_identical(a: span[Type], b: span[Type]) -> bool:
    if a.len != b.len:
        return false
    var i: ptr_uint = 0
    while i < a.len:
        var left: Type
        var right: Type
        unsafe:
            left = read(a.data + i)
            right = read(b.data + i)
        if not type_identical(left, right):
            return false
        i += 1
    return true


## The interning table.  `entries` is the id → type mapping (id 0 is `ty_nil`,
## so a zero-initialised id is meaningful); `buckets` maps a structural hash to
## the ids that share it, and a candidate is confirmed with `type_identical`.
public struct TypeStore:
    entries: vec.Vec[Type]
    buckets: map_mod.Map[uint, vec.Vec[uint]]
    hits: ptr_uint
    misses: ptr_uint


public function create_type_store() -> TypeStore:
    var store = TypeStore(
        entries = vec.Vec[Type].create(),
        buckets = map_mod.Map[uint, vec.Vec[uint]].create(),
        hits = 0,
        misses = 0,
    )
    let nil_id = store.intern(Type.ty_nil)
    if nil_id != 0:
        fatal(c"type interning: ty_nil must take id 0")
    return store


extending TypeStore:
    public editable function len() -> ptr_uint:
        return this.entries.len()


    ## The canonical id for `t`.  Reuses an existing node whose entry is
    ## `type_identical`; otherwise appends and returns the new id.
    public editable function intern(t: Type) -> uint:
        let key = type_hash(t)
        let bucket = this.buckets.get(key)
        if bucket != null:
            var i: ptr_uint = 0
            unsafe:
                let id_list = read(bucket)
                while i < id_list.len():
                    let id_ptr = id_list.get(i) else:
                        break
                    let candidate = read(id_ptr)
                    let stored = this.entries.get(ptr_uint<-candidate) else:
                        break
                    if type_identical(read(stored), t):
                        this.hits += 1
                        return candidate
                    i += 1
        let new_id = uint<-this.entries.len()
        this.entries.push(t)
        this.misses += 1
        if bucket == null:
            var fresh = vec.Vec[uint].create()
            fresh.push(new_id)
            this.buckets.set(key, fresh)
        else:
            unsafe:
                read(bucket).push(new_id)
        return new_id


    ## The type behind `id`; `ty_error` for an out-of-range id (a malformed IR
    ## node, which the C backend reports as an ordinary type error).
    public function get(id: uint) -> Type:
        let slot = this.entries.get(ptr_uint<-id) else:
            return Type.ty_error
        return unsafe: read(slot)


    ## The table as a span, for `ir.Program.type_table`.  The caller keeps the
    ## store's vector alive; the program borrows it.
    public function as_table() -> span[Type]:
        return this.entries.as_span()


    public editable function release() -> void:
        var iter = this.buckets.values()
        while true:
            let bucket_ptr = iter.next() else:
                break
            unsafe:
                read(bucket_ptr).release()
        this.buckets.release()
        this.entries.release()
