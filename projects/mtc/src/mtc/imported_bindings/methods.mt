## Method extension emitter — scans generated module functions and emits
## extending Type: function method() -> T: ... blocks for method specs.

import std.str
import std.string as string
import std.vec as vec

import mtc.imported_bindings.policy as policy
import mtc.imported_bindings.naming as naming
import mtc.imported_bindings.raw_scanner as raw

# =============================================================================
#  Types
# =============================================================================

public struct MethodFunc:
    public_name: string.String
    raw_name: string.String
    params: vec.Vec[raw.RawFuncParam]
    return_type: string.String
    module_alias: string.String


extending MethodFunc:
    public editable function release() -> void:
        this.public_name.release()
        this.raw_name.release()
        release_params(ref_of(this.params))
        this.return_type.release()
        this.module_alias.release()


function release_params(v: ref[vec.Vec[raw.RawFuncParam]]) -> void:
    var i: ptr_uint = 0
    while i < v.len():
        let p = v.get(i)
        if p != null:
            unsafe: read(p).release()
        i += 1
    v.release()


function release_method_funcs(v: ref[vec.Vec[MethodFunc]]) -> void:
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
    var params = vec.Vec[raw.RawFuncParam].create()
    if params_start < i - 1:
        params = parse_param_list(after_kw.slice(params_start, i - 1 - params_start))

    i = skip_arrow(after_kw, i)
    var return_type: str = "void"
    if i < after_kw.len:
        let rt_start = i
        while i < after_kw.len and after_kw.byte_at(i) != ' ' and after_kw.byte_at(i) != '=':
            i += 1
        if i > rt_start:
            return_type = after_kw.slice(rt_start, i - rt_start)

    var module_alias: str = ""
    var raw_name: str = ""
    let eq = after_kw.find_substring(" = ")
    let eq_pos = eq else:
        return Option[MethodFunc].some(value = MethodFunc(
            public_name = string.String.from_str(pub_name), raw_name = string.String.create(),
            params = params, return_type = string.String.from_str(return_type),
            module_alias = string.String.create()))
    let after_eq = after_kw.slice(eq_pos + 3, after_kw.len - eq_pos - 3)
    let dot = after_eq.find_substring(".")
    let dot_pos = dot else:
        return Option[MethodFunc].some(value = MethodFunc(
            public_name = string.String.from_str(pub_name), raw_name = string.String.create(),
            params = params, return_type = string.String.from_str(return_type),
            module_alias = string.String.create()))
    module_alias = after_eq.slice(0, dot_pos)
    raw_name = after_eq.slice(dot_pos + 1, after_eq.len - dot_pos - 1)
    return Option[MethodFunc].some(value = MethodFunc(
        public_name = string.String.from_str(pub_name), raw_name = string.String.from_str(raw_name),
        params = params, return_type = string.String.from_str(return_type),
        module_alias = string.String.from_str(module_alias)))


function parse_param_list(text: str) -> vec.Vec[raw.RawFuncParam]:
    var result = vec.Vec[raw.RawFuncParam].create()
    var pi: ptr_uint = 0
    while pi < text.len:
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
        while pi < text.len and text.byte_at(pi) != ',':
            pi += 1
        var ptype_end = pi
        while ptype_end > ptype_start and text.byte_at(ptype_end - 1) == ' ':
            ptype_end -= 1
        let ptype = text.slice(ptype_start, ptype_end - ptype_start)
        if pname.len > 0 and ptype.len > 0:
            result.push(raw.RawFuncParam(name = string.String.from_str(pname), param_type = string.String.from_str(ptype)))
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


# =============================================================================
#  Method matching
# =============================================================================

function method_matches(raw_name: str, spec: policy.MethodSpec) -> bool:
    # Check include prefixes against the raw name first
    var raw_selected = true
    if spec.include_kind != policy.IncludeKind.include_all:
        raw_selected = false
        var pi: ptr_uint = 0
        while pi < spec.include_prefixes.len():
            let prefix = spec.include_prefixes.get(pi)
            if prefix != null and raw_name.starts_with(unsafe: read(prefix).as_str()):
                raw_selected = true
                break
            pi += 1
        if not raw_selected:
            var ii: ptr_uint = 0
            while ii < spec.include_list.len():
                let iname = spec.include_list.get(ii)
                if iname != null and unsafe: read(iname).as_str().equal(raw_name):
                    raw_selected = true
                    break
                ii += 1
    if not raw_selected:
        return false

    # Apply strip_prefix and renaming
    var name = naming.strip_prefix_str(raw_name, spec.strip_prefix.as_str())
    var buf = string.String.from_str(name)
    var ri: ptr_uint = 0
    while ri < spec.rename_rules.len():
        let rp = spec.rename_rules.get(ri)
        if rp != null:
            unsafe:
                var next = naming.apply_rename_rule(buf.as_str(), read(rp).kind.as_str(), read(rp).pattern.as_str(), read(rp).replace_with.as_str())
                buf.release()
                buf = next
        ri += 1
    var snaked = naming.snake_case(buf.as_str())
    let final_name = snaked.as_str()

    # Check exclude against transformed name
    var ei: ptr_uint = 0
    while ei < spec.exclude.len():
        let en = spec.exclude.get(ei)
        if en != null and unsafe: read(en).as_str().equal(final_name):
            buf.release()
            snaked.release()
            return false
        ei += 1

    buf.release()
    snaked.release()
    return true


function type_in_list(type_str: str, list: vec.Vec[string.String]) -> bool:
    var i: ptr_uint = 0
    while i < list.len():
        let item = list.get(i)
        if item != null and unsafe: read(item).as_str().equal(type_str):
            return true
        i += 1
    return false


function find_func_in_span(funcs: span[raw.RawFuncInfo], name: str) -> ptr[raw.RawFuncInfo]?:
    var i: ptr_uint = 0
    while i < funcs.len:
        let fi = unsafe: funcs.data + i
        if fi.name.as_str().equal(name):
            return fi
        i += 1
    return null


# =============================================================================
#  Method generation entry point
# =============================================================================

public function generate(
    method_specs: vec.Vec[policy.MethodSpec],
    raw_funcs: span[raw.RawFuncInfo],
    raw_func_order: span[string.String],
    external_funcs: vec.Vec[MethodFunc],
    ext_module_alias: str,
    raw_module_alias: str,
) -> vec.Vec[string.String]:
    var lines = vec.Vec[string.String].create()
    if method_specs.len() == 0:
        return lines

    var mi: ptr_uint = 0
    while mi < method_specs.len():
        let spec_ptr = method_specs.get(mi) else:
            mi += 1
            continue
        var block = vec.Vec[string.String].create()
        unsafe:
            let spec = read(spec_ptr)
            if spec.module_name.len() > 0:
                block = emit_external_block(spec, external_funcs, ext_module_alias)
            else:
                block = emit_raw_block(spec, raw_funcs, raw_func_order, raw_module_alias)
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


# =============================================================================
#  Raw module method emission
# =============================================================================

function emit_raw_block(
    spec: policy.MethodSpec,
    raw_funcs: span[raw.RawFuncInfo],
    raw_func_order: span[string.String],
    raw_alias: str,
) -> vec.Vec[string.String]:
    var result = vec.Vec[string.String].create()

    var matching = vec.Vec[ptr[raw.RawFuncInfo]].create()
    var ri: ptr_uint = 0
    while ri < raw_func_order.len:
        let order_name = unsafe: read(raw_func_order.data + ri)
        if method_matches(order_name.as_str(), spec):
            let fi = find_func_in_span(raw_funcs, order_name.as_str())
            if fi != null:
                matching.push(fi)
        ri += 1

    if matching.len() == 0:
        matching.release()
        return result

    result.push(string.String.from_str(""))
    var header = string.String.with_capacity(30)
    header.append("extending ")
    header.append(spec.receiver_type.as_str())
    header.append(":")
    result.push(header)

    var method_lines = vec.Vec[string.String].create()
    var ii: ptr_uint = 0
    while ii < matching.len():
        let fi_ptr = matching.get(ii) else:
            ii += 1
            continue
        unsafe:
            method_lines = emit_single_raw(read(fi_ptr), spec, raw_alias)
        merge_lines(ref_of(result), ref_of(method_lines))
        method_lines.release()
        method_lines = vec.Vec[string.String].create()
        ii += 1
    matching.release()
    return result


function emit_single_raw(
    fi: ptr[raw.RawFuncInfo],
    spec: policy.MethodSpec,
    raw_alias: str,
) -> vec.Vec[string.String]:
    var lines = vec.Vec[string.String].create()
    unsafe:
        let func = read(fi)
        if func.params.len == 0:
            return lines

        let fp = func.params.get(0) else:
            return lines
        let first_type = read(fp).param_type.as_str()
        # Strip import alias prefix if present (e.g. "c.Color" -> "Color")
        var type_to_check = first_type
        if raw_alias.len > 0 and first_type.starts_with(raw_alias):
            let after_alias = first_type.slice(raw_alias.len, first_type.len - raw_alias.len)
            if after_alias.starts_with("."):
                type_to_check = after_alias.slice(1, after_alias.len - 1)
        # Default receiver_types to [receiver_type] when empty
        var receivers = spec.receiver_types
        var has_default_receivers = false
        if receivers.len() == 0:
            receivers = vec.Vec[string.String].create()
            receivers.push(string.String.from_str(spec.receiver_type.as_str()))
            has_default_receivers = true
        var method_kind = if not type_in_list(type_to_check, receivers): "static " else: ""
        if has_default_receivers:
            receivers.release()

        var method_name = naming.strip_prefix_str(func.name.as_str(), spec.strip_prefix.as_str())
        var snaked = naming.snake_case(method_name)
        var sanitized = naming.sanitize_binding_name(snaked.as_str())

        var sig = string.String.with_capacity(200)
        sig.append("    public ")
        sig.append(method_kind)
        sig.append("function ")
        sig.append(sanitized.as_str())
        sig.append("(")
        var spi: ptr_uint = if method_kind.len == 0: 1 else: 0
        while spi < func.params.len:
            let pp = func.params.get(spi) else:
                spi += 1
                continue
            if spi != (if method_kind.len == 0: 1 else: 0):
                sig.append(", ")
            var pname = naming.snake_case(read(pp).name.as_str())
            sig.append(pname.as_str())
            sig.append(": ")
            sig.append(read(pp).param_type.as_str())
            pname.release()
            spi += 1
        sig.append(") -> ")
        sig.append(func.return_type.as_str())
        sig.append(":")
        lines.push(sig)

        var call_name_snaked = naming.snake_case(func.name.as_str())
        var call_name = naming.sanitize_binding_name(call_name_snaked.as_str())

        var call = string.String.with_capacity(200)
        call.append("        ")
        if not func.return_type.as_str().equal("void"):
            call.append("return ")
        call.append(call_name.as_str())
        call.append("(")
        if method_kind.len == 0:
            call.append("this")
        var need_comma = method_kind.len == 0
        var ci: ptr_uint = if method_kind.len == 0: 1 else: 0
        while ci < func.params.len:
            let pp = func.params.get(ci) else:
                ci += 1
                continue
            if need_comma:
                call.append(", ")
            else:
                need_comma = true
            var pname = naming.snake_case(read(pp).name.as_str())
            call.append(pname.as_str())
            pname.release()
            ci += 1
        call.append(")")
        lines.push(call)
        lines.push(string.String.from_str(""))

        snaked.release()

    return lines


# =============================================================================
#  External module method emission
# =============================================================================

function emit_external_block(
    spec: policy.MethodSpec,
    ext_funcs: vec.Vec[MethodFunc],
    ext_alias: str,
) -> vec.Vec[string.String]:
    var result = vec.Vec[string.String].create()

    var matching = vec.Vec[ptr[MethodFunc]].create()
    var ei: ptr_uint = 0
    while ei < ext_funcs.len():
        let mf = ext_funcs.get(ei) else:
            ei += 1
            continue
        if method_matches(unsafe: read(mf).public_name.as_str(), spec):
            matching.push(mf)
        ei += 1

    if matching.len() == 0:
        matching.release()
        return result

    result.push(string.String.from_str(""))
    var header = string.String.with_capacity(30)
    header.append("extending ")
    header.append(spec.receiver_type.as_str())
    header.append(":")
    result.push(header)

    var method_lines = vec.Vec[string.String].create()
    var mi: ptr_uint = 0
    while mi < matching.len():
        let mf_ptr = matching.get(mi) else:
            mi += 1
            continue
        unsafe:
            method_lines = emit_single_external(read(mf_ptr), spec, ext_alias)
        merge_lines(ref_of(result), ref_of(method_lines))
        method_lines.release()
        method_lines = vec.Vec[string.String].create()
        mi += 1
    matching.release()
    return result


function emit_single_external(
    mf: ptr[MethodFunc],
    spec: policy.MethodSpec,
    ext_alias: str,
) -> vec.Vec[string.String]:
    var lines = vec.Vec[string.String].create()
    unsafe:
        let func = read(mf)
        let pub_name = func.public_name.as_str()
        var method_name = naming.strip_prefix_str(pub_name, spec.strip_prefix.as_str())
        var snaked = naming.snake_case(method_name)
        var sanitized = naming.sanitize_binding_name(snaked.as_str())

        var method_kind = "static "
        if func.params.len > 0:
            let fp = func.params.get(0) else:
                pass
            if fp != null:
                let first_type = read(fp).param_type.as_str()
                var type_to_check = first_type
                # Strip any module prefix (e.g. "rl.Vector2" -> "Vector2")
                var dot_pos_opt = first_type.find_substring(".")
                if dot_pos_opt.is_some():
                    let dp = dot_pos_opt.unwrap()
                    type_to_check = first_type.slice(dp + 1, first_type.len - dp - 1)
                # Default receiver_types to [receiver_type]
                var receivers = spec.receiver_types
                var has_df = false
                if receivers.len() == 0:
                    receivers = vec.Vec[string.String].create()
                    receivers.push(string.String.from_str(spec.receiver_type.as_str()))
                    has_df = true
                if type_in_list(type_to_check, receivers):
                    method_kind = ""
                if has_df:
                    receivers.release()

        var sig = string.String.with_capacity(200)
        sig.append("    public ")
        sig.append(method_kind)
        sig.append("function ")
        sig.append(sanitized.as_str())
        sig.append("(")
        var spi: ptr_uint = if method_kind.len == 0: 1 else: 0
        while spi < func.params.len:
            let pp = func.params.get(spi) else:
                spi += 1
                continue
            if spi != (if method_kind.len == 0: 1 else: 0):
                sig.append(", ")
            var pname = naming.snake_case(read(pp).name.as_str())
            sig.append(pname.as_str())
            sig.append(": ")
            sig.append(read(pp).param_type.as_str())
            pname.release()
            spi += 1
        sig.append(") -> ")
        var rt = func.return_type.as_str()
        # Strip module prefix (e.g. "rl.Vector2" -> "Vector2")
        var rt_dot = rt.find_substring(".")
        if rt_dot.is_some():
            let dp = rt_dot.unwrap()
            rt = rt.slice(dp + 1, rt.len - dp - 1)
        sig.append(rt)
        sig.append(":")
        lines.push(sig)

        var call = string.String.with_capacity(200)
        call.append("        ")
        if not func.return_type.as_str().equal("void"):
            call.append("return ")
        call.append(ext_alias)
        call.append(".")
        call.append(pub_name)
        call.append("(")
        if method_kind.len == 0:
            call.append("this")
        var need_comma = method_kind.len == 0
        var ci: ptr_uint = if method_kind.len == 0: 1 else: 0
        while ci < func.params.len:
            let pp = func.params.get(ci) else:
                ci += 1
                continue
            if need_comma:
                call.append(", ")
            else:
                need_comma = true
            var pname = naming.snake_case(read(pp).name.as_str())
            call.append(pname.as_str())
            pname.release()
            ci += 1
        call.append(")")
        lines.push(call)
        lines.push(string.String.from_str(""))

        snaked.release()

    return lines
