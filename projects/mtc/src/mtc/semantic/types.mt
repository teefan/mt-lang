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


## One field of a variant arm's payload.  The host's `Types::VariantArmPayload`
## *is* the arm's struct (its fields are the variant's declared arm fields with
## the scrutinee's type arguments substituted), so `p.value` on a bound arm
## resolves through this list.
public struct PayloadField:
    name: str
    ty: Type


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
    ty_event(name: str, capacity: ptr_uint, payload_type: ptr[Type]?, linkage_name: str)
    # A nominal type declared in this module.  `linkage_name` carries the C
    # linkage when it differs from `<module>_<name>` — a nested struct's type is
    # named by its short name (`Edge`) but linked through its parents
    # (`<module>_Rectangle_Edge`), mirroring Ruby's `Types::Struct#linkage_name`.
    ty_named(name: str, module_name: str, linkage_name: Option[str])
    # The binding type of an `as name` variant match arm.  `variant_name` and
    # `module_name` identify the owning variant (`Option`, `std.option`); `name`
    # is the rendered payload name (`Option_some`); `c_name` is the payload
    # struct's C linkage name (`std_option_Option_some`).  Mirrors Ruby's
    # `Types::VariantArmPayload`, which the sexpr dumper tags distinctly but
    # whose fields it renders like a `Types::Struct` (`:name`, `:module_name`).
    ty_variant_arm_payload(variant_name: str, name: str, module_name: str, c_name: str, display_name: str, fields: span[PayloadField])
    ty_imported(module_name: str, name: str, args: span[Type])
    ty_var(name: str)
    # An explicit lifetime argument on a `ref` type (`ref[@a, T]`).  The host
    # keeps the raw lifetime name (`"@a"`) as the first generic argument; it
    # renders as a bare quoted string and the referent is the last argument.
    ty_lifetime(name: str)
    # A `dyn[Iface[args]]` fat pointer.  The host's `Types::Dyn` carries the
    # interface's own type arguments as well as its name.
    ty_dyn(iface: str, args: span[Type])
    # A `dyn` interface vtable type.  Mirrors Ruby's `Types::DynVtable`
    # (`interface_name` + generated `mt_vtable_<Iface>` linkage name); its field
    # map is not rendered by the sexpr dumper.
    ty_dyn_vtable(interface_name: str, linkage_name: str)
    ty_opaque(module_name: str, name: str)
    ty_generic(name: str, args: span[Type])
    # `name` is the host's `Types::Function#name`: the declared name when the
    # type came from a function *value* (`fn add`), empty for an anonymous
    # `fn(…)` annotation.  `to_s` renders `fn <name>` (the host's shape), so a
    # struct field's `fn(int) -> bool` renders `fn `.
    ty_function(params: span[Type], return_type: ptr[Type], variadic: bool, is_proc: bool, param_names: span[str], name: str)
    ty_literal_int(value: long)
    ty_tuple(elements: span[Type], field_names: Option[span[str]])


public function alloc_type(value: Type) -> ptr[Type]:
    var node = heap.must_alloc[Type](1)
    unsafe:
        read(node) = value
    return node


public function primitive(name: str) -> Type:
    return Type.ty_primitive(name = name)


## A compile-time integer used as a generic type argument (e.g. the `N` in
## `array[T, N]` / `str_buffer[N]`).  Mirrors Ruby's Types::LiteralTypeArg.
public function literal_int(value: long) -> Type:
    return Type.ty_literal_int(value = value)


## The binding type of an `as name` variant match arm.  `variant_name` is the
## owning variant's declared name (`Option`), `module_name` its module
## (`std.option`), and `c_name` the payload struct's C linkage name.
public function variant_arm_payload(variant_name: str, module_name: str, c_name: str, arm_name: str) -> Type:
    var buf = string.String.create()
    buf.append(variant_name)
    buf.append("_")
    buf.append(arm_name)
    return Type.ty_variant_arm_payload(
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
    return Type.ty_variant_arm_payload(
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
            return any_contains_error(g.args)
        Type.ty_imported as im:
            return any_contains_error(im.args)
        Type.ty_function as f:
            if contains_error(unsafe: read(f.return_type)):
                return true
            return any_contains_error(f.params)
        Type.ty_tuple as tp:
            return any_contains_error(tp.elements)
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
            return any_contains_var(g.args)
        Type.ty_imported as im:
            return any_contains_var(im.args)
        Type.ty_function as f:
            if contains_type_var(unsafe: read(f.return_type)):
                return true
            return any_contains_var(f.params)
        Type.ty_tuple as tp:
            return any_contains_var(tp.elements)
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
            if n.module_name.len > 0:
                var b = string.String.create()
                b.append(n.module_name)
                b.append(".")
                b.append(n.name)
                return b.as_str()
            return n.name
        Type.ty_opaque as o:
            if o.module_name.len > 0:
                var b = string.String.create()
                b.append(o.module_name)
                b.append(".")
                b.append(o.name)
                return b.as_str()
            return o.name
        Type.ty_imported as im:
            var b = string.String.create()
            if im.module_name.len > 0:
                b.append(im.module_name)
                b.append(".")
            b.append(im.name)
            if im.args.len > 0:
                b.append("[")
                var i: ptr_uint = 0
                while i < im.args.len:
                    if i > 0:
                        b.append(", ")
                    unsafe:
                        b.append(type_to_diagnostic_string(read(im.args.data + i)))
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
public function type_to_qualified_string(t: Type) -> str:
    match t:
        Type.ty_named as n:
            if n.module_name.len > 0:
                var b = string.String.create()
                b.append(n.module_name)
                b.append(".")
                b.append(n.name)
                return b.as_str()
            return n.name
        Type.ty_opaque as o:
            if o.module_name.len > 0:
                var b = string.String.create()
                b.append(o.module_name)
                b.append(".")
                b.append(o.name)
                return b.as_str()
            return o.name
        Type.ty_imported as im:
            var b = string.String.create()
            if im.module_name.len > 0:
                b.append(im.module_name)
                b.append(".")
            b.append(im.name)
            if im.args.len > 0:
                b.append("[")
                var i: ptr_uint = 0
                while i < im.args.len:
                    if i > 0:
                        b.append(", ")
                    unsafe:
                        b.append(type_to_qualified_string(read(im.args.data + i)))
                    i += 1
                b.append("]")
            return b.as_str()
        Type.ty_nullable as nl:
            var b = string.String.create()
            unsafe:
                b.append(type_to_qualified_string(read(nl.base)))
            b.append("?")
            return b.as_str()
        Type.ty_generic as g:
            var b = string.String.create()
            b.append(g.name)
            b.append("[")
            var i: ptr_uint = 0
            while i < g.args.len:
                if i > 0:
                    b.append(", ")
                unsafe:
                    b.append(type_to_qualified_string(read(g.args.data + i)))
                i += 1
            b.append("]")
            return b.as_str()
        _:
            return type_to_string(t)


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
            return n.name
        Type.ty_variant_arm_payload as ap:
            # The host's `VariantArmPayload#to_s` is `<variant>.<arm> payload`;
            # the lowering's constructions carry no display text, so they keep
            # the payload struct's own name.
            if ap.display_name.len > 0:
                return ap.display_name
            return ap.name
        Type.ty_imported as im:
            if im.args.len == 0:
                return im.name
            return type_to_string(Type.ty_generic(name = im.name, args = im.args))
        Type.ty_var as v:
            return v.name
        Type.ty_lifetime as lt:
            return lt.name
        Type.ty_dyn as d:
            if d.args.len == 0:
                var dbuf = string.String.create()
                dbuf.append("dyn[")
                dbuf.append(d.iface)
                dbuf.append("]")
                return dbuf.as_str()
            var dbuf = string.String.create()
            dbuf.append("dyn[")
            dbuf.append(d.iface)
            dbuf.append("[")
            var di: ptr_uint = 0
            while di < d.args.len:
                if di > 0:
                    dbuf.append(", ")
                unsafe:
                    dbuf.append(type_to_string(read(d.args.data + di)))
                di += 1
            dbuf.append("]]")
            return dbuf.as_str()
        Type.ty_dyn_vtable as dv:
            return dv.linkage_name
        Type.ty_opaque as o:
            return o.name
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
            return ev.name
        Type.ty_generic as g:
            var buf = string.String.create()
            buf.append(g.name)
            buf.append("[")
            var i: ptr_uint = 0
            while i < g.args.len:
                if i > 0:
                    buf.append(", ")
                unsafe:
                    buf.append(type_to_string(read(g.args.data + i)))
                i += 1
            buf.append("]")
            return buf.as_str()
        Type.ty_function as fnt:
            if not fnt.is_proc:
                # The host's `Types::Function#to_s` is `fn <name>` — an
                # anonymous function type (a field's `fn(…)` annotation) with no
                # name renders `fn `.
                var fbuf = string.String.create()
                fbuf.append("fn ")
                fbuf.append(fnt.name)
                return fbuf.as_str()
            # The host's `Types::Proc#to_s` renders its parameters by *type*
            # alone (`proc(int) -> int`); a source annotation's names appear
            # only where the outline renders the annotation itself.
            var buf = string.String.create()
            buf.append("proc(")
            var i: ptr_uint = 0
            while i < fnt.params.len:
                if i > 0:
                    buf.append(", ")
                unsafe:
                    buf.append(type_to_string(read(fnt.params.data + i)))
                i += 1
            buf.append(") -> ")
            unsafe:
                buf.append(type_to_string(read(fnt.return_type)))
            return buf.as_str()
        Type.ty_literal_int as lit:
            var buf = string.String.create()
            fmt.append_long(ref_of(buf), lit.value)
            return buf.as_str()
        Type.ty_tuple as tup:
            var buf = string.String.create()
            buf.append("(")
            var i: ptr_uint = 0
            while i < tup.elements.len:
                if i > 0:
                    buf.append(", ")
                unsafe:
                    buf.append(type_to_string(read(tup.elements.data + i)))
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
            match b:
                Type.ty_event as eb:
                    if ea.name != eb.name or ea.capacity != eb.capacity or ea.linkage_name != eb.linkage_name:
                        return false
                    let pa = ea.payload_type
                    let pb = eb.payload_type
                    if pa == null:
                        return pb == null
                    if pb == null:
                        return false
                    return type_equals(unsafe: read(pa), unsafe: read(pb))
                _:
                    return false
        Type.ty_named as na:
            match b:
                Type.ty_named as nb:
                    return na.name == nb.name
                Type.ty_imported as ib:
                    return na.name == ib.name
                _:
                    return false
        Type.ty_variant_arm_payload as apa:
            match b:
                Type.ty_variant_arm_payload as apb:
                    return apa.c_name == apb.c_name
                _:
                    return false
        Type.ty_imported as ia:
            return imported_type_matches(ia.module_name, ia.name, ia.args, b)
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
            match b:
                Type.ty_dyn as db:
                    if da.iface != db.iface or da.args.len != db.args.len:
                        return false
                    var di: ptr_uint = 0
                    while di < da.args.len:
                        unsafe:
                            if not type_equals(read(da.args.data + di), read(db.args.data + di)):
                                return false
                        di += 1
                    return true
                _:
                    return false
        Type.ty_dyn_vtable as dva:
            match b:
                Type.ty_dyn_vtable as dvb:
                    return dva.linkage_name == dvb.linkage_name
                _:
                    return false
        Type.ty_opaque as oa:
            match b:
                Type.ty_opaque as ob:
                    return oa.module_name == ob.module_name and oa.name == ob.name
                _:
                    return false
        Type.ty_generic as ga:
            return generic_type_matches(ga.name, ga.args, b)
        Type.ty_function as fa:
            match b:
                Type.ty_function as fb:
                    if fa.variadic != fb.variadic:
                        return false
                    if fa.params.len != fb.params.len:
                        return false
                    if not type_equals(unsafe: read(fa.return_type), unsafe: read(fb.return_type)):
                        return false
                    var i: ptr_uint = 0
                    while i < fa.params.len:
                        unsafe:
                            if not type_equals(read(fa.params.data + i), read(fb.params.data + i)):
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
            match b:
                Type.ty_tuple as tb:
                    if ta.elements.len != tb.elements.len:
                        return false
                    var i: ptr_uint = 0
                    while i < ta.elements.len:
                        unsafe:
                            if not type_equals(read(ta.elements.data + i), read(tb.elements.data + i)):
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
            if not module_name == ib.module_name or not name == ib.name:
                return false
            if args.len != ib.args.len:
                return false
            var i: ptr_uint = 0
            while i < args.len:
                unsafe:
                    if not type_equals(read(args.data + i), read(ib.args.data + i)):
                        return false
                i += 1
            return true
        Type.ty_named as nb:
            return name == nb.name and args.len == 0
        Type.ty_generic as gb:
            if not name == gb.name or args.len != gb.args.len:
                return false
            let prelude = (name == "Option" and module_name == "std.option") or (name == "Result" and module_name == "std.result")
            if not prelude:
                return false
            var i3: ptr_uint = 0
            while i3 < args.len:
                unsafe:
                    if not type_equals(read(args.data + i3), read(gb.args.data + i3)):
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
            if not name == gb.name:
                return false
            if args.len != gb.args.len:
                return false
            var i: ptr_uint = 0
            while i < args.len:
                unsafe:
                    if not type_equals(read(args.data + i), read(gb.args.data + i)):
                        return false
                i += 1
            return true
        Type.ty_imported as ib:
            # The prelude variants appear both as the bare generic
            # (`Option[T]`/`Result[T, E]`) and as their imported definition
            # (`std.option.Option`/`std.result.Result`).
            if not name == ib.name or args.len != ib.args.len:
                return false
            let prelude = (name == "Option" and ib.module_name == "std.option") or (name == "Result" and ib.module_name == "std.result")
            if not prelude:
                return false
            var i2: ptr_uint = 0
            while i2 < args.len:
                unsafe:
                    if not type_equals(read(args.data + i2), read(ib.args.data + i2)):
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
            return g.name == "ptr" or g.name == "const_ptr"
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
            return g.name == "own"
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
            return g.name == "ptr" or g.name == "const_ptr" or g.name == "own"
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
            if g.args.len >= 1:
                if g.name == "ref":
                    return unsafe: read(g.args.data + (g.args.len - 1))
                return unsafe: read(g.args.data + 0)
            return Type.ty_error
        _:
            return Type.ty_error


## True when `t` is a ref type (ref[T] or ref[@a, T]).
public function is_ref_type(t: Type) -> bool:
    match t:
        Type.ty_generic as g:
            return g.name == "ref"
        _:
            return false


## True when `t` is a SIMD vector type (simd[E, N]).
public function is_simd_type(t: Type) -> bool:
    match t:
        Type.ty_generic as g:
            return g.name == "simd" and g.args.len == 2
        _:
            return false


## The lane element type of a simd[E, N] type, or ty_error.
public function simd_element_type(t: Type) -> Type:
    match t:
        Type.ty_generic as g:
            if g.name == "simd" and g.args.len >= 1:
                return unsafe: read(g.args.data + 0)
            return Type.ty_error
        _:
            return Type.ty_error


## The lane count of a simd[E, N] type, or 0 when unknown.
public function simd_lane_count(t: Type) -> long:
    match t:
        Type.ty_generic as g:
            if g.name == "simd" and g.args.len >= 2:
                match unsafe: read(g.args.data + 1):
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
            return n.name
        Type.ty_imported as im:
            var buf = string.String.create()
            buf.append(im.module_name)
            buf.append(".")
            buf.append(im.name)
            return buf.as_str()
        _:
            return ""


## Bare (unqualified) nominal type name, "" for non-nominal types.
public function nominal_name(t: Type) -> str:
    match t:
        Type.ty_named as n:
            return n.name
        Type.ty_imported as im:
            return im.name
        _:
            return ""


## Module qualifier of a nominal type, "" when unqualified/unknown.
public function nominal_module(t: Type) -> str:
    match t:
        Type.ty_named as n:
            return n.module_name
        Type.ty_imported as im:
            return im.module_name
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
            match b:
                Type.ty_generic as gb:
                    # Different constructors stay permissive: mutable→const
                    # pointer and array→span coercions are legal, so a bare
                    # name mismatch is not proof of incompatibility.
                    if not ga.name == gb.name:
                        return false
                    if ga.args.len != gb.args.len:
                        return false
                    var i: ptr_uint = 0
                    while i < ga.args.len:
                        unsafe:
                            if definitely_different(read(ga.args.data + i), read(gb.args.data + i)):
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


public function is_definitely_non_str(t: Type) -> bool:
    match t:
        Type.ty_str:
            return false
        Type.ty_primitive:
            return true
        _:
            return false
