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
import std.mem.heap as heap


public variant Type:
    ty_primitive(name: str)
    ty_str
    ty_error
    ty_type_meta
    ty_nullable(base: ptr[Type])
    ty_named(name: str)
    ty_imported(module_name: str, name: str)
    ty_var(name: str)
    ty_dyn(iface: str)
    ty_generic(name: str, args: span[Type])
    ty_function(params: span[Type], return_type: ptr[Type], variadic: bool)


public function alloc_type(value: Type) -> ptr[Type]:
    var node = heap.must_alloc[Type](1)
    unsafe:
        read(node) = value
    return node


public function primitive(name: str) -> Type:
    return Type.ty_primitive(name = name)


# ---------------------------------------------------------------------------
#  Classification predicates (mirror Types::Primitive flag methods)
# ---------------------------------------------------------------------------

public function is_numeric_name(name: str) -> bool:
    return (
        name.equal("byte") or name.equal("short") or name.equal("int") or name.equal("long")
        or name.equal("ubyte") or name.equal("ushort") or name.equal("uint") or name.equal("ulong")
        or name.equal("ptr_int") or name.equal("ptr_uint") or name.equal("float") or name.equal("double")
    )


## True when `name` is one of the primitive integer types (fixed-width or
## pointer-sized).  Excludes char and the float types.
public function is_integer_name(name: str) -> bool:
    return (
        name.equal("byte") or name.equal("short") or name.equal("int") or name.equal("long")
        or name.equal("ubyte") or name.equal("ushort") or name.equal("uint") or name.equal("ulong")
        or name.equal("ptr_int") or name.equal("ptr_uint")
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
            return p.name.equal("bool")
        _:
            return false


public function is_void(t: Type) -> bool:
    match t:
        Type.ty_primitive as p:
            return p.name.equal("void")
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
            return im.name
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
            if p.name.equal("bool"):
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
    if name.equal("byte") or name.equal("ubyte") or name.equal("char"):
        return 8
    if name.equal("short") or name.equal("ushort"):
        return 16
    if name.equal("int") or name.equal("uint"):
        return 32
    if name.equal("long") or name.equal("ulong"):
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
        name.equal("byte") or name.equal("short") or name.equal("int")
        or name.equal("long")
    )


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
            return p.name.equal("float") or p.name.equal("double")
        _:
            return false


## True when `t` is the char primitive.
public function is_char_type(t: Type) -> bool:
    match t:
        Type.ty_primitive as p:
            return p.name.equal("char")
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


public function definitely_incompatible(target: Type, source: Type) -> bool:
    if is_error(target) or is_error(source):
        return false

    # Nullable on either side stays permissive: T→T?, null→T?, and unwrap
    # narrowing are handled elsewhere; the base-compatibility check would need
    # more modeling, so uncertainty means "not flagged".
    if is_nullable_type(target) or is_nullable_type(source):
        return false

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
    # Float → integer: scalar-category mismatch, fall through to scalar check.

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
            return not p.name.equal("bool")
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
