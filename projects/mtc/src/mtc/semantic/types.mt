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
#  Category-based incompatibility (conservative subset of Ruby's
#  types_compatible?).  Returns true ONLY when both types are concretely known
#  and belong to clearly different scalar categories (bool / numeric / str) —
#  the mismatches Ruby definitely rejects and that carry no numeric-literal
#  coercion subtlety.  Any uncertainty returns false (not flagged), so the
#  analyzer never false-positives.
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


public function definitely_incompatible(target: Type, source: Type) -> bool:
    if is_error(target) or is_error(source):
        return false
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
