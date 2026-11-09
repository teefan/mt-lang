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


## The host's `sanitize_identifier` (`c_backend/type_system.rb:247-250`): every
## non-alphanumeric byte to `_`, runs of `_` collapsed, leading/trailing `_`
## stripped (`proc(int) -> int` -> `proc_int_int`).  Empty text becomes `value`.
public function sanitize_c_identifier(text: str) -> str:
    var buf = string.String.create()
    var previous_underscore = false
    var i: ptr_uint = 0
    while i < text.len:
        let b = text.byte_at(i)
        if is_alnum_byte(b):
            buf.push_byte(b)
            previous_underscore = false
        else:
            if not previous_underscore:
                buf.push_byte('_')
            previous_underscore = true
        i += 1
    var result = buf.as_str()
    while result.len > 0 and result.byte_at(0) == '_':
        result = result.slice(1, result.len - 1)
    while result.len > 0 and result.byte_at(result.len - 1) == '_':
        result = result.slice(0, result.len - 1)
    if result.len == 0:
        return "value"
    return result


## The host's event-linkage part sanitizer (`Types::Event#linkage_name`,
## `types.rb:750-755`): every maximal run of bytes outside `[A-Za-z0-9_]`
## becomes one `_` — the regex's `+`, so unlike `sanitize_identifier` nothing is
## collapsed or stripped beyond that (a generic payload's `Vec[int]` keeps its
## trailing `_`: `Vec_int_`).
public function sanitize_event_part(text: str) -> str:
    var buf = string.String.create()
    var previous_invalid = false
    var i: ptr_uint = 0
    while i < text.len:
        let b = text.byte_at(i)
        if is_alnum_byte(b) or b == '_':
            buf.push_byte(b)
            previous_invalid = false
        else:
            if not previous_invalid:
                buf.push_byte('_')
            previous_invalid = true
        i += 1
    return buf.as_str()


## The host's `Types::Event#linkage_name`: `mt_event` + the sanitized module,
## owner, name and payload `to_s` parts (empty ones dropped) + the capacity —
## `mt_event_<module>_<owner>_<name>[_<payload>]_<capacity>`.
public function event_linkage_name(module_name: str, owner: str, name: str, payload: Option[str], capacity: long) -> str:
    var buf = string.String.create()
    buf.append("mt_event")
    append_event_part(ref_of(buf), module_name)
    append_event_part(ref_of(buf), owner)
    append_event_part(ref_of(buf), name)
    match payload:
        Option.some as p:
            append_event_part(ref_of(buf), p.value)
        Option.none:
            pass
    var cap_buf = string.String.create()
    fmt.append_long(ref_of(cap_buf), capacity)
    buf.append("_")
    buf.append(cap_buf.as_str())
    return buf.as_str()


function append_event_part(buf: ref[string.String], text: str) -> void:
    if text.len == 0:
        return
    buf.append("_")
    buf.append(sanitize_event_part(text))


## The C struct name for a proc (closure) type — the host's `proc_type_name`
## (`type_system.rb:213-215`): `mt_proc_` + the sanitized `proc(<params>) -> <ret>`
## spelling (`Types::Proc#to_s`), so `proc(int) -> int` -> `mt_proc_proc_int_int`.
## The elements render *module-qualified* (`ptr[std.toml.Entry]`, the host's
## `to_s`), so same-named types from different modules get distinct C names.
public function proc_type_c_name(t: types.Type) -> str:
    var raw = string.String.create()
    match t:
        types.Type.ty_function as fnt:
            raw.append("proc(")
            var i: ptr_uint = 0
            while i < fnt.params.len:
                if i > 0:
                    raw.append(", ")
                unsafe:
                    raw.append(type_to_s_qualified(read(fnt.params.data + i)))
                i += 1
            raw.append(") -> ")
            unsafe:
                raw.append(type_to_s_qualified(read(fnt.return_type)))
        _:
            raw.append(type_to_s_qualified(t))
    return j2("mt_proc_", sanitize_c_identifier(raw.as_str()))


## The C identifier prefix for a module (`std.str` -> `std_str`).
public function module_c_prefix(module_name: str) -> str:
    return sanitize_identifier(module_name)


## Whether `text` is a plain C identifier (`[A-Za-z_][A-Za-z0-9_]*`) — the
## host's `opaque_forward_declarable?` name check, so a backing name like
## `struct b2TreeNode` cannot be forward-declared under its own spelling.
public function is_c_identifier(text: str) -> bool:
    if text.len == 0:
        return false

    var i: ptr_uint = 0
    while i < text.len:
        let b = text.byte_at(i)
        let is_letter = (b >= 'A' and b <= 'Z') or (b >= 'a' and b <= 'z')
        let is_digit = i > 0 and b >= '0' and b <= '9'
        if not (is_letter or is_digit or b == '_'):
            return false
        i += 1
    return true


## The declared name of the interface a `dyn[I]` / `adapt[I]` use refers to: the
## text after the last `.`, so that an import-alias prefix (`ifaces.Identifiable`)
## and the bare spelling (`Identifiable`) yield one `mt_dyn_*` / `mt_vtable_*`
## symbol.  The host names these after the declaration alone, with no module
## qualification, so a qualified spelling must not leak into the symbol.
public function dyn_iface_declared_name(use_name: str) -> str:
    var last_dot: ptr_uint = 0
    var has_dot = false
    var i: ptr_uint = 0
    while i < use_name.len:
        if use_name.byte_at(i) == 46:  # '.'
            last_dot = i
            has_dot = true
        i += 1
    if has_dot:
        return sanitize_identifier(use_name.slice(last_dot + 1, use_name.len - last_dot - 1))
    return sanitize_identifier(use_name)


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
        types.Type.ty_opaque as op:
            return qualified_c_name(op.module_name, op.name)
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
            if g.name == "Option":
                buf.append("std_option_")
            else if g.name == "Result":
                buf.append("std_result_")
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


## The host's Ruby `to_s` for a type — the rendering its tuple struct
## declarations carry (`Types::Tuple#to_s`, e.g. `(main.P, int)`,
## `(std.vec.Vec[main.P], main.P)`), where named and imported types are
## module-qualified.  This is distinct from `types.type_to_string`, whose
## unqualified rendering the diagnostics and hovers use.
public function type_to_s_qualified(t: types.Type) -> str:
    match t:
        types.Type.ty_named as n:
            if n.module_name.len > 0:
                return j3(n.module_name, ".", n.name)
            return n.name
        types.Type.ty_imported as im:
            if im.args.len == 0:
                return j3(im.module_name, ".", im.name)
            var buf = string.String.create()
            buf.append(im.module_name)
            buf.append(".")
            buf.append(im.name)
            buf.append("[")
            var i: ptr_uint = 0
            while i < im.args.len:
                if i > 0:
                    buf.append(", ")
                unsafe:
                    buf.append(type_to_s_qualified(read(im.args.data + i)))
                i += 1
            buf.append("]")
            return buf.as_str()
        types.Type.ty_generic as g:
            var buf = string.String.create()
            buf.append(g.name)
            buf.append("[")
            var i: ptr_uint = 0
            while i < g.args.len:
                if i > 0:
                    buf.append(", ")
                unsafe:
                    buf.append(type_to_s_qualified(read(g.args.data + i)))
                i += 1
            buf.append("]")
            return buf.as_str()
        types.Type.ty_nullable as nl:
            var buf = string.String.create()
            unsafe:
                buf.append(type_to_s_qualified(read(nl.base)))
            buf.append("?")
            return buf.as_str()
        types.Type.ty_tuple as tup:
            var buf = string.String.create()
            # The host's `Types::Tuple#to_s`: default positional names render as
            # `(T1, T2)`, non-default names as `(n1: T1, n2: T2)`.
            var named = false
            match tup.field_names:
                Option.some as names:
                    if not tuple_names_are_default(names.value):
                        named = true
                Option.none:
                    pass
            buf.append("(")
            var i: ptr_uint = 0
            while i < tup.elements.len:
                if i > 0:
                    buf.append(", ")
                if named:
                    match tup.field_names:
                        Option.some as names:
                            unsafe:
                                buf.append(read(names.value.data + i))
                            buf.append(": ")
                        Option.none:
                            pass
                unsafe:
                    buf.append(type_to_s_qualified(read(tup.elements.data + i)))
                i += 1
            buf.append(")")
            return buf.as_str()
        _:
            return types.type_to_string(t)


## The host's `sanitize_type_name_for_tuple`: every non-alphanumeric byte to
## `_`, runs of `_` collapsed, one leading/trailing `_` stripped.
public function sanitize_tuple_type_name(text: str) -> str:
    var buf = string.String.create()
    var previous_underscore = false
    var i: ptr_uint = 0
    while i < text.len:
        let b = text.byte_at(i)
        if is_alnum_byte(b):
            buf.push_byte(b)
            previous_underscore = false
        else:
            if not previous_underscore:
                buf.push_byte('_')
            previous_underscore = true
        i += 1
    var result = buf.as_str()
    if result.len > 0 and result.byte_at(result.len - 1) == '_':
        result = result.slice(0, result.len - 1)
    if result.len > 0 and result.byte_at(0) == '_':
        result = result.slice(1, result.len - 1)
    return result


## The C name of a tuple type (`(int, int)` -> `mt_tuple_int_int`, a named
## `(x: int, y: int)` -> `mt_tuple_int_int_x_y`), mirroring the host's
## `tuple_type_name`: elements sanitized and joined, plus a suffix of the
## sanitized field names when they are not the default `_0..`.
public function tuple_type_c_name(t: types.Type) -> str:
    var buf = string.String.create()
    buf.append("mt_tuple")
    match t:
        types.Type.ty_tuple as tup:
            var i: ptr_uint = 0
            while i < tup.elements.len:
                buf.append("_")
                unsafe:
                    buf.append(sanitize_tuple_type_name(type_to_s_qualified(read(tup.elements.data + i))))
                i += 1
            match tup.field_names:
                Option.some as names:
                    if not tuple_names_are_default(names.value):
                        var ni: ptr_uint = 0
                        while ni < names.value.len:
                            buf.append("_")
                            unsafe:
                                buf.append(sanitize_tuple_type_name(read(names.value.data + ni)))
                            ni += 1
                Option.none:
                    pass
        _:
            pass
    return buf.as_str()


## True when a tuple's field names are the default positional names (`_0`,
## `_1`, …), for which the host omits the name suffix in the C name.
function tuple_names_are_default(names: span[str]) -> bool:
    var i: ptr_uint = 0
    while i < names.len:
        var expected = string.String.create()
        expected.append("_")
        fmt.append_ptr_uint(ref_of(expected), i)
        unsafe:
            if not read(names.data + i).equal(expected.as_str()):
                return false
        i += 1
    return true


function j2(a: str, b: str) -> str:
    var buf = string.String.create()
    buf.append(a)
    buf.append(b)
    return buf.as_str()


function j3(a: str, b: str, c: str) -> str:
    var buf = string.String.create()
    buf.append(a)
    buf.append(b)
    buf.append(c)
    return buf.as_str()
