## Semantic type model — the analyzer's type representation, distinct from the
## syntactic `ast.TypeRef` produced by the parser.  Mirrors a core subset of
## Ruby's `Types::*` class hierarchy (lib/milk_tea/core/types/types.rb) as a
## variant: primitives, str, nullable, named (struct/enum/…), generic
## instances (ptr/span/array/Option/…), function/proc, and the `type` meta.
##
## Phase 1 is deliberately conservative: anything the analyzer cannot resolve
## concretely becomes `ty_error`, which is compatible with everything so it
## never produces a false-positive diagnostic (mirroring Ruby's Error type,
## which suppresses cascading errors).

import std.string as string
import std.str
import std.fmt as fmt
import std.mem.heap as heap


public variant Type:
    ty_primitive(name: str)
    ty_str
    ty_error
    ty_type_meta
    ty_nullable(base: ptr[Type])
    ty_named(name: str, module_name: str)
    ty_imported(module_name: str, name: str, args: span[Type])
    ty_var(name: str)
    ty_dyn(iface: str)
    ty_generic(name: str, args: span[Type])
    ty_function(params: span[Type], return_type: ptr[Type], variadic: bool, is_proc: bool)
    ty_literal_int(value: long)
    ty_tuple(elements: span[Type], field_names: Option[span[str]])


public function alloc_type(value: Type) -> ptr[Type]:
heap.must_alloc[Type](1)
    unsafe:
        read(node) = value
    return node


public function primitive(name: str) -> Type:
    return Type.ty_primitive(name = name)


## A compile-time integer used as a generic type argument (e.g. the `N` in
## `array[T, N]` / `str_buffer[N]`).  Mirrors Ruby's Types::LiteralTypeArg.
public function literal_int(value: long) -> Type:
    return Type.ty_literal_int(value = value)


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


public function is_numeric(t: Type) -> bool:
    match t:
        Type.ty_primitive as p:
            return is_numeric_name(p.name)
        _:
            return false


# ---------------------------------------------------------------------------
#  Rendering (mirrors Types::* #to_s), used for diagnostics
# ---------------------------------------------------------------------------

public function type_to_string(t: Type) -> str:
    match t:
        Type.ty_primitive as p:
            return p.name
        Type.ty_str:
            return "str"
        Type.ty_error:
            return "<error>"
        Type.ty_type_meta:
            return "type"
        Type.ty_named as n:
            return n.name
        Type.ty_imported as im:
            if im.args.len == 0:
                return im.name
            return type_to_string(Type.ty_generic(name = im.name, args = im.args))
        Type.ty_var as v:
            return v.name
        Type.ty_dyn as d:
            return d.iface
        Type.ty_nullable as nl:
            var buf = string.String.create()
            unsafe:
                buf.append(type_to_string(read(nl.base)))
            buf.append("?")
            return buf.as_str()
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
            var buf = string.String.create()
            buf.append("fn(")
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

const cat_bool: int = 1
const cat_numeric: int = 2
const cat_str: int = 3
const cat_other: int = 0


function scalar_category(t: Type) -> int:
    match t:
        Type.ty_primitive as p:
            if p.name == "bool":
                return cat_bool
            if is_numeric_name(p.name):
                return cat_numeric
            return cat_other
        Type.ty_str:
            return cat_str
        _:
            return cat_other


## Width in bits of a fixed-width integer primitive, 0 for pointer-sized integer
## types and non-integers.  Mirrors Ruby’s Primitive#integer_width.
public function integer_width(name: str) -> int:
    if name == "byte" or name == "ubyte" or name == "char":
        return 8
    if name == "short" or name == "ushort":
        return 16
    if name == "int" or name == "uint":
        return 32
    if name == "long" or name == "ulong":
        return 64
    return 0


## True when `name` is a primitive integer type with a platform-independent
## width (not ptr_int / ptr_uint).
public function is_fixed_width_integer_name(name: str) -> bool:
    return integer_width(name) != 0


## True for signed integer primitives.  Unsigned types, pointer integers,
## and non-integers return false.
public function is_signed_integer_name(name: str) -> bool:
    return (
        name == "byte" or name == "short" or name == "int"
        or name == "long"
    )


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
        Type.ty_type_meta:
            match b:
                Type.ty_type_meta:
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
        Type.ty_named as na:
            match b:
                Type.ty_named as nb:
                    return na.name == nb.name
                Type.ty_imported as ib:
                    return na.name == ib.name
                _:
                    return false
        Type.ty_imported as ia:
            match b:
                Type.ty_imported as ib:
                    if not ia.module_name == ib.module_name or not ia.name == ib.name:
                        return false
                    if ia.args.len != ib.args.len:
                        return false
                    var i: ptr_uint = 0
                    while i < ia.args.len:
                        unsafe:
                            if not type_equals(read(ia.args.data + i), read(ib.args.data + i)):
                                return false
                        i += 1
                    return true
                Type.ty_named as nb:
                    return ia.name == nb.name and ia.args.len == 0
                _:
                    return false
        Type.ty_var as va:
            match b:
                Type.ty_var as vb:
                    return va.name == vb.name
                _:
                    return false
        Type.ty_dyn as da:
            match b:
                Type.ty_dyn as db:
                    return da.iface == db.iface
                _:
                    return false
        Type.ty_generic as ga:
            match b:
                Type.ty_generic as gb:
                    if not ga.name == gb.name:
                        return false
                    if ga.args.len != gb.args.len:
                        return false
                    var i: ptr_uint = 0
                    while i < ga.args.len:
                        unsafe:
                            if not type_equals(read(ga.args.data + i), read(gb.args.data + i)):
                                return false
                        i += 1
                    return true
                _:
                    return false
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


## The element type of a pointer or array-like type.  Returns ty_error for
## anything that is not ptr / const_ptr / ref / span / array.
public function pointer_element(t: Type) -> Type:
    match t:
        Type.ty_generic as g:
            if g.args.len >= 1:
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


## True when `t` is a primitive integer (fixed-width or pointer-sized).
public function is_integer_type(t: Type) -> bool:
    match t:
        Type.ty_primitive as p:
            return is_integer_name(p.name)
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


const kind_unknown: int = 0
const kind_scalar: int = 1
const kind_nominal: int = 2
const kind_generic: int = 3


## Coarse structural kind for definite-difference comparison.  Error, type
## variable, nullable, dyn, function, and the type-meta all map to `unknown`
## so they never force a mismatch.
function type_kind(t: Type) -> int:
    match t:
        Type.ty_primitive:
            return kind_scalar
        Type.ty_str:
            return kind_scalar
        Type.ty_named:
            return kind_nominal
        Type.ty_imported:
            return kind_nominal
        Type.ty_generic:
            return kind_generic
        _:
            return kind_unknown


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
    if ka == kind_unknown or kb == kind_unknown:
        return false
    if ka == kind_scalar and kb == kind_scalar:
        return scalar_definitely_different(a, b)
    if ka == kind_nominal and kb == kind_nominal:
        return not nominal_key(a) == nominal_key(b)
    if ka == kind_generic and kb == kind_generic:
        return generic_definitely_different(a, b)
    # Cross-kind: only a nominal-vs-scalar pair is provably incompatible.  Any
    # pairing that involves a generic stays permissive because of implicit
    # coercions — a `ref[T]` parameter borrows a `T` argument, an array coerces
    # to a span, and a mutable pointer coerces to a const pointer.
    if ka == kind_nominal and kb == kind_scalar:
        return true
    if ka == kind_scalar and kb == kind_nominal:
        return true
    return false


public function definitely_incompatible(target: Type, source: Type) -> bool:
    if is_error(target) or is_error(source):
        return false

    # Nullability.  T? ← T? compares bases; T? ← T checks the base; T ← T?
    # stays permissive because narrowing an optional to its base requires flow
    # refinement the self-host does not model yet (gap #4).
    let tn = is_nullable_type(target)
    let sn = is_nullable_type(source)
    if tn and sn:
        return definitely_incompatible(unwrap_nullable(target), unwrap_nullable(source))
    if sn:
        return false
    if tn:
        return definitely_incompatible(unwrap_nullable(target), source)

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
    if tc == cat_other or sc == cat_other:
        return false
    return tc != sc


## True when `t` is a concretely-known type that is definitely not `bool`
## (a non-bool primitive or str).  Condition checking flags a non-bool
## `if`/`while` condition only when the type is concrete; unknown types
## (`ty_error`, named, generic, …) stay permissive.
public function is_definitely_non_bool(t: Type) -> bool:
    match t:
        Type.ty_primitive as p:
            return not p.name == "bool"
        Type.ty_str:
            return true
        _:
            return false


public function is_definitely_non_str(t: Type) -> bool:
    match t:
        Type.ty_str:
            return false
        Type.ty_primitive:
            return true
        _:
            return false
