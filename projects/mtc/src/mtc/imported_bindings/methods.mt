## Method extension emitter — builds `extending Type:` wrappers from the
## generated foreign-function entries (not the raw declarations), matching the
## host's `emit_methods`: the receiver is detected on the generated public type
## and the inout/instance/static kind comes from the entry's parameter mode.

import std.str
import std.string as string
import std.vec as vec

import mtc.imported_bindings.policy as policy
import mtc.imported_bindings.naming as naming

# =============================================================================
#  Types
# =============================================================================

public struct MethodParam:
    name: string.String
    param_type: string.String
    mode: string.String
    boundary_type: string.String


extending MethodParam:
    public editable function release() -> void:
        this.name.release()
        this.param_type.release()
        this.mode.release()
        this.boundary_type.release()


public struct MethodFunc:
    public_name: string.String
    raw_name: string.String
    params: vec.Vec[MethodParam]
    return_type: string.String


extending MethodFunc:
    public editable function release() -> void:
        this.public_name.release()
        this.raw_name.release()
        release_params(ref_of(this.params))
        this.return_type.release()


function release_params(v: ref[vec.Vec[MethodParam]]) -> void:
    var i: ptr_uint = 0
    while i < v.len():
        let p = v.get(i)
        if p != null:
            unsafe: read(p).release()
        i += 1
    v.release()


public function release_method_funcs(v: ref[vec.Vec[MethodFunc]]) -> void:
    var i: ptr_uint = 0
    while i < v.len():
        let p = v.get(i)
        if p != null:
            unsafe: read(p).release()
        i += 1
    v.release()


function release_strings(v: ref[vec.Vec[string.String]]) -> void:
    var i: ptr_uint = 0
    while i < v.len():
        let p = v.get(i)
        if p != null:
            unsafe: read(p).release()
        i += 1
    v.release()


# =============================================================================
#  Generated module scanner
# =============================================================================

public function scan_generated_module(source: str) -> vec.Vec[MethodFunc]:
    var result = vec.Vec[MethodFunc].create()
    var pos: ptr_uint = 0
    var line_start: ptr_uint = 0
    while pos < source.len:
        if source.byte_at(pos) == '\n' or pos + 1 == source.len:
            let end_pos = if pos + 1 == source.len: pos + 1 else: pos
            let line = source.slice(line_start, end_pos - line_start)
            match scan_method_line(line):
                Option.some as mf:
                    result.push(mf.value)
                Option.none:
                    pass
            line_start = pos + 1
        pos += 1
    return result


public function scan_generated_lines(lines: span[string.String]) -> vec.Vec[MethodFunc]:
    var result = vec.Vec[MethodFunc].create()
    var i: ptr_uint = 0
    while i < lines.len:
        unsafe:
            let line = read(lines.data + i)
            match scan_method_line(line.as_str()):
                Option.some as mf:
                    result.push(mf.value)
                Option.none:
                    pass
        i += 1
    return result


function scan_method_line(line: str) -> Option[MethodFunc]:
    var trimmed = line
    var si: ptr_uint = 0
    while si < trimmed.len and trimmed.byte_at(si) == ' ':
        si += 1
    if si >= trimmed.len:
        return Option[MethodFunc].none
    trimmed = trimmed.slice(si, trimmed.len - si)
    if not trimmed.starts_with("public foreign function "):
        return Option[MethodFunc].none

    let kw = "public foreign function "
    let after_kw = trimmed.slice(kw.len, trimmed.len - kw.len)
    var i: ptr_uint = 0
    while i < after_kw.len and after_kw.byte_at(i) != '(':
        i += 1
    if i == 0 or i >= after_kw.len:
        return Option[MethodFunc].none
    let pub_name = after_kw.slice(0, i)

    i += 1
    let params_start = i
    var depth: int = 1
    while i < after_kw.len and depth > 0:
        let ch = after_kw.byte_at(i)
        if ch == '(':
            depth += 1
        else if ch == ')':
            depth -= 1
        i += 1
    var params = vec.Vec[MethodParam].create()
    if params_start < i - 1:
        params = parse_param_list(after_kw.slice(params_start, i - 1 - params_start))

    i = skip_arrow(after_kw, i)
    var return_type: str = "void"
    if i < after_kw.len:
        let rt_start = i
        var rt_end = after_kw.len
        let mapping = after_kw.slice(i, after_kw.len - i).find_substring(" = ")
        match mapping:
            Option.some as sep:
                rt_end = i + sep.value
            Option.none:
                pass
        while rt_end > rt_start and after_kw.byte_at(rt_end - 1) == ' ':
            rt_end -= 1
        if rt_end > rt_start:
            return_type = after_kw.slice(rt_start, rt_end - rt_start)

    var raw_name: str = ""
    let eq = after_kw.find_substring(" = ")
    let eq_pos = eq else:
        return Option[MethodFunc].some(value = MethodFunc(
            public_name = string.String.from_str(pub_name), raw_name = string.String.create(),
            params = params, return_type = string.String.from_str(return_type)))
    let after_eq = after_kw.slice(eq_pos + 3, after_kw.len - eq_pos - 3)
    let dot = after_eq.find_substring(".")
    let dot_pos = dot else:
        return Option[MethodFunc].some(value = MethodFunc(
            public_name = string.String.from_str(pub_name), raw_name = string.String.create(),
            params = params, return_type = string.String.from_str(return_type)))
    let mapped = after_eq.slice(dot_pos + 1, after_eq.len - dot_pos - 1)
    var mapped_end: ptr_uint = 0
    while mapped_end < mapped.len and mapped.byte_at(mapped_end) != '(' and
            mapped.byte_at(mapped_end) != ' ':
        mapped_end += 1
    raw_name = mapped.slice(0, mapped_end)
    return Option[MethodFunc].some(value = MethodFunc(
        public_name = string.String.from_str(pub_name), raw_name = string.String.from_str(raw_name),
        params = params, return_type = string.String.from_str(return_type)))


function parse_param_list(text: str) -> vec.Vec[MethodParam]:
    var result = vec.Vec[MethodParam].create()
    var pi: ptr_uint = 0
    while pi < text.len:
        while pi < text.len and text.byte_at(pi) == ' ':
            pi += 1
        if pi >= text.len:
            return result

        # Optional parameter mode (`inout value: T`, `out x: T`).
        var mode: str = ""
        if starts_at(text, pi, "inout "):
            mode = "inout"
            pi += 6
        else if starts_at(text, pi, "out "):
            mode = "out"
            pi += 4
        else if starts_at(text, pi, "in "):
            mode = "in"
            pi += 3

        while pi < text.len and text.byte_at(pi) == ' ':
            pi += 1
        if pi >= text.len:
            return result

        let pname_start = pi
        while pi < text.len and text.byte_at(pi) != ':' and text.byte_at(pi) != ' ' and text.byte_at(pi) != ',':
            pi += 1
        if pi <= pname_start:
            return result
        let pname = text.slice(pname_start, pi - pname_start)
        while pi < text.len and (text.byte_at(pi) == ' ' or text.byte_at(pi) == ':'):
            pi += 1

        let ptype_start = pi
        var depth: int = 0
        while pi < text.len:
            let ch = text.byte_at(pi)
            if ch == '[' or ch == '(' or ch == '{':
                depth += 1
            else if ch == ']' or ch == ')' or ch == '}':
                if depth > 0:
                    depth -= 1
            else if ch == ',' and depth == 0:
                break
            pi += 1
        var ptype_end = pi
        while ptype_end > ptype_start and text.byte_at(ptype_end - 1) == ' ':
            ptype_end -= 1
        let ptype_text = text.slice(ptype_start, ptype_end - ptype_start)

        var ptype: str = ptype_text
        var boundary: str = ""
        let as_pos = ptype_text.find_substring(" as ")
        match as_pos:
            Option.some as pos:
                ptype = ptype_text.slice(0, pos.value)
                boundary = ptype_text.slice(pos.value + 4, ptype_text.len - pos.value - 4)
            Option.none:
                pass

        if pname.len > 0 and ptype.len > 0:
            result.push(MethodParam(
                name = string.String.from_str(pname),
                param_type = string.String.from_str(ptype),
                mode = string.String.from_str(mode),
                boundary_type = string.String.from_str(boundary),
            ))
        while pi < text.len and text.byte_at(pi) == ' ':
            pi += 1
        if pi < text.len and text.byte_at(pi) == ',':
            pi += 1
    return result


function skip_arrow(text: str, start: ptr_uint) -> ptr_uint:
    var i = start
    while i < text.len and (text.byte_at(i) == ' ' or text.byte_at(i) == '-' or text.byte_at(i) == '>'):
        i += 1
    return i


function starts_at(text: str, start: ptr_uint, pattern: str) -> bool:
    if start + pattern.len > text.len:
        return false
    var i: ptr_uint = 0
    while i < pattern.len:
        if text.byte_at(start + i) != pattern.byte_at(i):
            return false
        i += 1
    return true


# =============================================================================
#  Type helpers
# =============================================================================

## Strip import-alias qualifiers from a type (`rl.Vector2` -> `Vector2`,
## `ptr[rl.Vector2]` -> `ptr[Vector2]`).  External method sources are generated
## modules whose types may carry their own import aliases.
function strip_alias_qualifiers(text: str) -> string.String:
    var result = string.String.with_capacity(text.len)
    var i: ptr_uint = 0
    while i < text.len:
        let ch = text.byte_at(i)
        if is_ident_start(ch):
            var j = i + 1
            while j < text.len and is_ident_char(text.byte_at(j)):
                j += 1
            if j < text.len and text.byte_at(j) == '.':
                i = j + 1
                continue
            result.append(text.slice(i, j - i))
            i = j
        else:
            result.push_byte(ch)
            i += 1
    return result


function is_ident_start(ch: ubyte) -> bool:
    return (ch >= 65 and ch <= 90) or (ch >= 97 and ch <= 122) or ch == 95


function is_ident_char(ch: ubyte) -> bool:
    return is_ident_start(ch) or (ch >= 48 and ch <= 57)


function receiver_matches(type_str: str, spec: policy.MethodSpec) -> bool:
    if spec.receiver_types.len() > 0:
        var i: ptr_uint = 0
        while i < spec.receiver_types.len():
            let item = spec.receiver_types.get(i)
            if item != null and unsafe: read(item).as_str().equal(type_str):
                return true
            i += 1
        return false
    return spec.receiver_type.as_str().equal(type_str)


function method_selected(key: str, spec: policy.MethodSpec) -> bool:
    var ei: ptr_uint = 0
    while ei < spec.exclude.len():
        let en = spec.exclude.get(ei)
        if en != null and unsafe: read(en).as_str().equal(key):
            return false
        ei += 1

    if spec.include_kind == policy.IncludeKind.include_all:
        return true

    var ii: ptr_uint = 0
    while ii < spec.include_list.len():
        let iname = spec.include_list.get(ii)
        if iname != null and unsafe: read(iname).as_str().equal(key):
            return true
        ii += 1

    var pi: ptr_uint = 0
    while pi < spec.include_prefixes.len():
        let prefix = spec.include_prefixes.get(pi)
        if prefix != null and key.starts_with(unsafe: read(prefix).as_str()):
            return true
        pi += 1
    return false


function method_public_name(key: str, spec: policy.MethodSpec) -> string.String:
    var name = string.String.from_str(key)
    var ri: ptr_uint = 0
    while ri < spec.rename_rules.len():
        let rp = spec.rename_rules.get(ri)
        if rp != null:
            unsafe:
                var next = naming.apply_rename_rule(
                    name.as_str(),
                    read(rp).kind.as_str(),
                    read(rp).pattern.as_str(),
                    read(rp).replace_with.as_str(),
                )
                name.release()
                name = next
        ri += 1

    if spec.strip_prefix.len() > 0:
        let stripped = naming.strip_prefix_str(name.as_str(), spec.strip_prefix.as_str())
        var renamed = string.String.from_str(stripped)
        name.release()
        name = renamed

    var sanitized = naming.sanitize_value_binding_name(name.as_str())
    name.release()
    var snaked = naming.snake_case(sanitized.as_str())
    sanitized.release()
    return snaked


# =============================================================================
#  Method generation entry point
# =============================================================================

public function generate(
    method_specs: vec.Vec[policy.MethodSpec],
    function_entries: vec.Vec[MethodFunc],
    external_funcs: vec.Vec[MethodFunc],
    ext_module_alias: str,
    raw_module_alias: str,
) -> vec.Vec[string.String]:
    var lines = vec.Vec[string.String].create()
    var mi: ptr_uint = 0
    while mi < method_specs.len():
        let spec_ptr = method_specs.get(mi) else:
            mi += 1
            continue
        var block = vec.Vec[string.String].create()
        unsafe:
            let spec = read(spec_ptr)
            if spec.module_name.len() > 0:
                block = emit_block(spec, external_funcs, true, ext_module_alias)
            else:
                block = emit_block(spec, function_entries, false, raw_module_alias)
        if block.len() > 0:
            merge_lines(ref_of(lines), ref_of(block))
        block.release()
        mi += 1
    return lines


function merge_lines(dest: ref[vec.Vec[string.String]], src: ref[vec.Vec[string.String]]) -> void:
    var i: ptr_uint = 0
    while i < src.len():
        let p = src.get(i)
        if p != null:
            unsafe: dest.push(string.String.from_str(read(p).as_str()))
        i += 1


function emit_block(
    spec: policy.MethodSpec,
    entries: vec.Vec[MethodFunc],
    use_public_key: bool,
    call_alias: str,
) -> vec.Vec[string.String]:
    var result = vec.Vec[string.String].create()

    var matching = vec.Vec[ptr[MethodFunc]].create()
    var seen = vec.Vec[string.String].create()
    var ei: ptr_uint = 0
    while ei < entries.len():
        let entry_ptr = entries.get(ei) else:
            ei += 1
            continue
        unsafe:
            let entry = read(entry_ptr)
            let key = if use_public_key: entry.public_name.as_str() else: entry.raw_name.as_str()
            if method_selected(key, spec) and not string_in_list(ref_of(seen), key):
                seen.push(string.String.from_str(key))
                matching.push(entry_ptr)
        ei += 1

    if matching.len() == 0:
        matching.release()
        release_strings(ref_of(seen))
        return result

    result.push(string.String.from_str(""))
    var header = string.String.with_capacity(30)
    header.append("extending ")
    header.append(spec.receiver_type.as_str())
    header.append(":")
    result.push(header)

    var mi: ptr_uint = 0
    while mi < matching.len():
        let entry_ptr = matching.get(mi) else:
            mi += 1
            continue
        var method_ptr: ptr[MethodFunc]
        unsafe:
            method_ptr = read(entry_ptr)
        var wrapper = emit_wrapper(method_ptr, spec, use_public_key, call_alias)
        merge_lines(ref_of(result), ref_of(wrapper))
        wrapper.release()
        mi += 1

    matching.release()
    release_strings(ref_of(seen))
    return result


function string_in_list(list: ref[vec.Vec[string.String]], value: str) -> bool:
    var i: ptr_uint = 0
    while i < list.len():
        let p = list.get(i)
        if p != null and unsafe: read(p).as_str().equal(value):
            return true
        i += 1
    return false


function emit_wrapper(
    entry_ptr: ptr[MethodFunc],
    spec: policy.MethodSpec,
    use_public_key: bool,
    call_alias: str,
) -> vec.Vec[string.String]:
    var lines = vec.Vec[string.String].create()
    var entry: MethodFunc
    unsafe:
        entry = read(entry_ptr)

    let key = if use_public_key: entry.public_name.as_str() else: entry.raw_name.as_str()
    if key.len == 0:
        return lines

    var method_name = method_public_name(key, spec)

    var kind: str = "static "
    var drop_first = false
    if entry.params.len() > 0:
        let first = entry.params.get(0)
        if first != null:
            var first_type: string.String
            var mode: str = ""
            unsafe:
                first_type = strip_alias_qualifiers(read(first).param_type.as_str())
                mode = read(first).mode.as_str()
            let base_type = first_type.as_str()
            if receiver_matches(base_type, spec):
                if mode.equal("inout"):
                    kind = "editable "
                    drop_first = true
                else if mode.len == 0:
                    kind = ""
                    drop_first = true
            first_type.release()

    var signature = string.String.with_capacity(200)
    signature.append("    public ")
    signature.append(kind)
    signature.append("function ")
    signature.append(method_name.as_str())
    signature.append("(")

    let start: ptr_uint = if drop_first: 1 else: 0
    var pi = start
    var emitted = false
    while pi < entry.params.len():
        let param_ptr = entry.params.get(pi) else:
            pi += 1
            continue
        unsafe:
            let param = read(param_ptr)
            if emitted:
                signature.append(", ")
            signature.append(param.name.as_str())
            signature.append(": ")
            var param_type = strip_alias_qualifiers(param.param_type.as_str())
            signature.append(param_type.as_str())
            param_type.release()
            emitted = true
        pi += 1
    signature.append(") -> ")

    var return_type = strip_alias_qualifiers(entry.return_type.as_str())
    signature.append(return_type.as_str())
    signature.append(":")
    lines.push(signature)

    var call = string.String.with_capacity(200)
    call.append("        ")
    if not return_type.as_str().equal("void"):
        call.append("return ")
    if use_public_key and call_alias.len > 0:
        call.append(call_alias)
        call.append(".")
    call.append(entry.public_name.as_str())
    call.append("(")

    var need_comma = false
    if drop_first:
        call.append("this")
        need_comma = true
    pi = start
    while pi < entry.params.len():
        let param_ptr = entry.params.get(pi) else:
            pi += 1
            continue
        unsafe:
            let param = read(param_ptr)
            if need_comma:
                call.append(", ")
            call.append(param.name.as_str())
            need_comma = true
        pi += 1
    call.append(")")
    lines.push(call)

    return_type.release()
    method_name.release()
    return lines
