## Shared C ABI naming conventions, used by both the Lowering stage (linkage-name
## generation) and the C backend (named-type C names).
##
## These are pure string utilities that depend on neither stage, so both may
## import them without an import cycle.  Centralizing them keeps the two stages'
## C-name mangling identical by construction (mirrors the Ruby compiler, where
## `module_c_prefix` / `sanitize_identifier` live in one place and are shared).

import std.str
import std.string as string


## Replace every maximal run of non-alphanumeric characters (and underscores)
## with a single `_`, strip a trailing `_`, and map the empty result to `value`
## — matching the Ruby compiler's `sanitize_identifier`.
public function sanitize_identifier(text: str) -> str:
    var buf = string.String.create()
    var prev_underscore = false
    var i: ptr_uint = 0
    while i < text.len:
        let b = text.byte_at(i)
        if is_alnum_byte(b):
            buf.push_byte(b)
            prev_underscore = false
        else:
            if not prev_underscore:
                buf.push_byte('_')
                prev_underscore = true
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
