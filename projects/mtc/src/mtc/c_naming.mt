## Shared C ABI naming conventions, used by both the Lowering stage (linkage-name
## generation) and the C backend (named-type C names).
##
## These are pure string utilities that depend on neither stage, so both may
## import them without an import cycle.  Centralizing them keeps the two stages'
## C-name mangling identical by construction (mirrors the Ruby compiler, where
## `module_c_prefix` / `sanitize_identifier` live in one place and are shared).

import std.str
import std.string as string
import std.fmt as fmt

import mtc.semantic.types as types


## Replace every maximal run of non-alphanumeric characters (and underscores)
## with a single `_`, strip a trailing `_`, and map the empty result to `value`
## — matching the Ruby compiler's `sanitize_identifier`.
public function sanitize_identifier(text: str) -> str:
    var buf = string.String.create()
    var i: ptr_uint = 0
    while i < text.len:
        let b = text.byte_at(i)
        if is_alnum_byte(b):
            buf.push_byte(b)
        else:
            buf.push_byte('_')
        i += 1

    var result = buf.as_str()
    if result.len > 0 and result.byte_at(result.len - 1) == '_':
        result = result.slice(0, result.len - 1)
    if result.len == 0:
        return "value"
    return result


## The C identifier prefix for a module (`std.str` -> `std_str`).
public function module_c_prefix(module_name: str) -> str:
    return sanitize_identifier(module_name)


## A module-qualified C name (`en` + `State` -> `en_State`).  Used for function
## and type linkage names and for named-type C names in the backend.
public function qualified_c_name(module_name: str, name: str) -> str:
    var buf = string.String.create()
    buf.append(module_c_prefix(module_name))
    buf.append("_")
    buf.append(name)
    return buf.as_str()


## A module-qualified member C name (`en` + `State` + `idle` -> `en_State_idle`).
## Used for enum/flags member constants.
public function qualified_member_c_name(module_name: str, owner: str, member: str) -> str:
    var buf = string.String.create()
    buf.append(module_c_prefix(module_name))
    buf.append("_")
    buf.append(owner)
    buf.append("_")
    buf.append(member)
    return buf.as_str()


function is_alnum_byte(b: ubyte) -> bool:
    return (b >= '0' and b <= '9') or (b >= 'A' and b <= 'Z') or (b >= 'a' and b <= 'z')


## A stable, module-qualified C identifier fragment for a type, used as the
## suffix in generic-instance names (`Vec[ir.Field]` -> `Vec_mtc_ir_Field`) and
## span/tuple type names.  Unlike `type_to_string`, imported and generic types
## carry their defining module, so same-named types from different modules
## (ir.Field vs ast.Field) do not collide.  Primitives, `str`, and already-
## qualified `ty_named` concrete names pass through so simple instances such as
## `Vec[int]` keep their existing names.
public function type_c_key(t: types.Type) -> str:
    match t:
        types.Type.ty_primitive as p:
            return p.name
        types.Type.ty_str:
            return "str"
        types.Type.ty_error:
            return "error"
        types.Type.ty_type_meta:
            return "type"
        types.Type.ty_named as n:
            if n.module_name.len > 0:
                var buf = string.String.create()
                buf.append(module_c_prefix(n.module_name))
                buf.append("_")
                buf.append(sanitize_identifier(n.name))
                return buf.as_str()
            return sanitize_identifier(n.name)
        types.Type.ty_var as v:
            return sanitize_identifier(v.name)
        types.Type.ty_dyn as d:
            return j2("dyn_", sanitize_identifier(d.iface))
        types.Type.ty_imported as im:
            var buf = string.String.create()
            buf.append(qualified_c_name(im.module_name, im.name))
            var i: ptr_uint = 0
            while i < im.args.len:
                buf.append("_")
                buf.append(type_c_key(unsafe: read(im.args.data + i)))
                i += 1
            return buf.as_str()
        types.Type.ty_generic as g:
            var buf = string.String.create()
            buf.append(sanitize_identifier(g.name))
            var i: ptr_uint = 0
            while i < g.args.len:
                buf.append("_")
                buf.append(type_c_key(unsafe: read(g.args.data + i)))
                i += 1
            return buf.as_str()
        types.Type.ty_nullable as nl:
            return type_c_key(unsafe: read(nl.base))
        types.Type.ty_literal_int as lit:
            var buf = string.String.create()
            fmt.append_long(ref_of(buf), lit.value)
            return buf.as_str()
        types.Type.ty_tuple as tup:
            var buf = string.String.create()
            buf.append("tuple")
            var i: ptr_uint = 0
            while i < tup.elements.len:
                buf.append("_")
                buf.append(type_c_key(unsafe: read(tup.elements.data + i)))
                i += 1
            return buf.as_str()
        _:
            return sanitize_identifier(types.type_to_string(t))


function j2(a: str, b: str) -> str:
    var buf = string.String.create()
    buf.append(a)
    buf.append(b)
    return buf.as_str()
