## Imported bindings emitter — generates MT source lines for type aliases,
## const aliases, and foreign functions from the policy and raw module data.
## Mirrors the host generator: types are alias-by-default (opaque only via an
## override), names keep the host's sanitize-before-snake order, and foreign
## signatures render through the generated public type-name map.

import std.string as string
import std.vec as vec
import std.str

import mtc.imported_bindings.policy as policy
import mtc.imported_bindings.naming as naming
import mtc.imported_bindings.raw_scanner as raw

# =============================================================================
#  Public type-name map
# =============================================================================

public struct TypeNameEntry:
    raw_name: string.String
    public_name: string.String
    is_opaque: bool
    selected: bool
    alias_target: string.String


extending TypeNameEntry:
    public editable function release() -> void:
        this.raw_name.release()
        this.public_name.release()
        this.alias_target.release()


public function release_type_name_entries(v: ref[vec.Vec[TypeNameEntry]]) -> void:
    var i: ptr_uint = 0
    while i < v.len():
        let p = v.get(i)
        if p != null:
            unsafe: read(p).release()
        i += 1
    v.release()


public function find_type_entry(type_map: span[TypeNameEntry], raw_name: str) -> ptr[TypeNameEntry]?:
    var i: ptr_uint = 0
    while i < type_map.len:
        unsafe:
            let entry = type_map.data + i
            if entry.raw_name.as_str().equal(raw_name):
                return entry
        i += 1
    return null

# =============================================================================
#  Name resolution utilities
# =============================================================================

## Apply the policy's rename rules then strip_prefix.  Returns an owned string.
function apply_spec_rules(
    raw_name: str,
    spec_strip_prefix: str,
    spec_rule_kinds: vec.Vec[string.String],
    spec_rule_patterns: vec.Vec[string.String],
    spec_rule_replacements: vec.Vec[string.String],
) -> string.String:
    var name = string.String.from_str(raw_name)

    var ri: ptr_uint = 0
    while ri < spec_rule_kinds.len():
        let kind_ptr = spec_rule_kinds.get(ri)
        let pattern_ptr = spec_rule_patterns.get(ri)
        let repl_ptr = spec_rule_replacements.get(ri)
        let kind = if kind_ptr != null: unsafe: read(kind_ptr).as_str() else: ""
        let pattern = if pattern_ptr != null: unsafe: read(pattern_ptr).as_str() else: ""
        let repl = if repl_ptr != null: unsafe: read(repl_ptr).as_str() else: ""
        var next = naming.apply_rename_rule(name.as_str(), kind, pattern, repl)
        name.release()
        name = next
        ri += 1

    if spec_strip_prefix.len > 0:
        let stripped = naming.strip_prefix_str(name.as_str(), spec_strip_prefix)
        var new_name = string.String.from_str(stripped)
        name.release()
        name = new_name

    return name


function spec_has_opengl(kinds: vec.Vec[string.String]) -> bool:
    var i: ptr_uint = 0
    while i < kinds.len():
        let p = kinds.get(i)
        if p != null and unsafe: read(p).as_str().equal("opengl"):
            return true
        i += 1
    return false


## Host `alias_public_name(..., binding_kind: :type)`: preserve case, no
## snake_case.  An override name wins verbatim.
function public_type_name(
    raw_name: str,
    spec_strip_prefix: str,
    spec_rule_kinds: vec.Vec[string.String],
    spec_rule_patterns: vec.Vec[string.String],
    spec_rule_replacements: vec.Vec[string.String],
    override_name: str,
) -> string.String:
    if override_name.len > 0:
        return string.String.from_str(override_name)

    var name = apply_spec_rules(
        raw_name,
        spec_strip_prefix,
        spec_rule_kinds,
        spec_rule_patterns,
        spec_rule_replacements
    )
    var sanitized = naming.sanitize_type_binding_name(name.as_str())
    name.release()
    return sanitized


## Host `foreign_function_name`: sanitize as a value, then snake_case, then the
## OpenGL normalization when the policy has an `opengl` rename rule.
function public_value_name(
    raw_name: str,
    spec_strip_prefix: str,
    spec_rule_kinds: vec.Vec[string.String],
    spec_rule_patterns: vec.Vec[string.String],
    spec_rule_replacements: vec.Vec[string.String],
    has_opengl: bool,
    raw_funcs: span[raw.RawFuncInfo],
    override_name: str,
) -> string.String:
    if override_name.len > 0:
        return string.String.from_str(override_name)

    var name = apply_spec_rules(
        raw_name,
        spec_strip_prefix,
        spec_rule_kinds,
        spec_rule_patterns,
        spec_rule_replacements
    )
    var sanitized = naming.sanitize_value_binding_name(name.as_str())
    name.release()
    var snaked = naming.snake_case(sanitized.as_str())
    sanitized.release()
    if not has_opengl:
        return snaked

    var normalized = naming.normalize_opengl_snake_case(snaked.as_str())
    snaked.release()
    var final = naming.normalize_opengl_terminal_suffix(normalized.as_str(), raw_name, raw_funcs)
    normalized.release()
    return final


## Like public_value_name but skips snake_case — constants keep their casing.
function public_const_name(
    raw_name: str,
    spec_strip_prefix: str,
    spec_rule_kinds: vec.Vec[string.String],
    spec_rule_patterns: vec.Vec[string.String],
    spec_rule_replacements: vec.Vec[string.String],
) -> string.String:
    var name = apply_spec_rules(
        raw_name,
        spec_strip_prefix,
        spec_rule_kinds,
        spec_rule_patterns,
        spec_rule_replacements
    )
    var sanitized = naming.sanitize_value_binding_name(name.as_str())
    name.release()
    return sanitized

# =============================================================================
#  Raw type rendering
# =============================================================================

function is_ident_start(ch: ubyte) -> bool:
    return (ch >= 65 and ch <= 90) or (ch >= 97 and ch <= 122) or ch == 95


function is_ident_char(ch: ubyte) -> bool:
    return is_ident_start(ch) or (ch >= 48 and ch <= 57)


function text_starts_at(text: str, start: ptr_uint, pattern: str) -> bool:
    if start + pattern.len > text.len:
        return false
    var i: ptr_uint = 0
    while i < pattern.len:
        if text.byte_at(start + i) != pattern.byte_at(i):
            return false
        i += 1
    return true


## Resolve one type token: a selected type's public name wins, otherwise a bare
## alias recurses to its target, otherwise the token is left as written.
function resolve_type_token(type_map: span[TypeNameEntry], token: str, depth: int) -> str:
    if depth > 16:
        return token
    let entry = find_type_entry(type_map, token) else:
        return token
    unsafe:
        let e = read(entry)
        if e.public_name.len() > 0:
            return e.public_name.as_str()
        if e.alias_target.len() > 0:
            return resolve_type_token(type_map, e.alias_target.as_str(), depth + 1)
    return token


## Render a raw type string through the public type-name map.  `project_handles`
## mirrors `render_public_foreign_type`: a top-level `ptr[opaque]` /
## `const_ptr[opaque]` projects to the opaque's public name.
public function render_type_text(
    type_map: span[TypeNameEntry],
    text: str,
    project_handles: bool,
) -> string.String:
    if text.len == 0:
        return string.String.create()

    var core = text
    var nullable = false
    if core.byte_at(core.len - 1) == 63:
        nullable = true
        core = core.slice(0, core.len - 1)

    if project_handles:
        var inner_start: ptr_uint = 0
        var matched = false
        if core.starts_with("ptr[") and core.ends_with("]") and core.len >= 5:
            inner_start = 4
            matched = true
        else if core.starts_with("const_ptr[") and core.ends_with("]") and core.len >= 11:
            inner_start = 10
            matched = true

        if matched:
            let inner = core.slice(inner_start, core.len - inner_start - 1)
            if inner.find_substring("[").is_none() and inner.find_substring("?").is_none():
                let entry = find_type_entry(type_map, inner)
                if entry != null:
                    unsafe:
                        if read(entry).is_opaque:
                            var projected = string.String.from_str(read(entry).public_name.as_str())
                            if nullable:
                                projected.push_byte('?')
                            return projected

    var result = string.String.with_capacity(text.len + 16)
    var i: ptr_uint = 0
    while i < text.len:
        let ch = text.byte_at(i)
        if is_ident_start(ch):
            var j = i + 1
            while j < text.len and is_ident_char(text.byte_at(j)):
                j += 1
            let token = text.slice(i, j - i)
            result.append(resolve_type_token(type_map, token, 0))
            i = j
        else:
            result.push_byte(ch)
            i += 1

    # Function-type parameters are rendered with the host's foreign-type
    # projection, unlike generic type arguments: `fn(arg0: ptr[Window], ...)`
    # becomes `fn(arg0: Window, ...)`.
    if result.as_str().find_substring("fn(").is_some():
        var projected = project_fn_handles(type_map, result.as_str())
        result.release()
        return projected
    return result


function is_opaque_public_name(type_map: span[TypeNameEntry], name: str) -> bool:
    var i: ptr_uint = 0
    while i < type_map.len:
        unsafe:
            let entry = type_map.data + i
            if entry.public_name.len() > 0 and entry.public_name.as_str().equal(name) and entry.is_opaque:
                return true
        i += 1
    return false


## Project `ptr[Opaque]` / `const_ptr[Opaque]` inside a `fn(...)` parameter list
## to the opaque public name.  A nested pointer (`ptr[ptr[Opaque]]`) is copied
## unchanged, matching the host's non-recursive projection.
function project_fn_handles(type_map: span[TypeNameEntry], text: str) -> string.String:
    var result = string.String.with_capacity(text.len)
    var i: ptr_uint = 0
    while i < text.len:
        if text_starts_at(text, i, "fn("):
            result.append("fn(")
            i += 3
            var depth: int = 1
            while i < text.len and depth > 0:
                let ch = text.byte_at(i)
                if ch == '(':
                    depth += 1
                    result.push_byte(ch)
                    i += 1
                else if ch == ')':
                    depth -= 1
                    result.push_byte(ch)
                    i += 1
                else if text_starts_at(text, i, "ptr[") or text_starts_at(text, i, "const_ptr["):
                    let prefix_len: ptr_uint = if text_starts_at(text, i, "ptr["): 4 else: 10
                    var j = i + prefix_len
                    var inner_depth: int = 1
                    var has_nested = false
                    while j < text.len and inner_depth > 0:
                        let inner_ch = text.byte_at(j)
                        if inner_ch == '[':
                            inner_depth += 1
                            has_nested = true
                        else if inner_ch == ']':
                            inner_depth -= 1
                        j += 1
                    if not has_nested and inner_depth == 0:
                        let name = text.slice(i + prefix_len, j - 1 - (i + prefix_len))
                        if is_opaque_public_name(type_map, name):
                            result.append(name)
                            i = j
                            continue
                    result.append(text.slice(i, j - i))
                    i = j
                else:
                    result.push_byte(ch)
                    i += 1
        else:
            result.push_byte(text.byte_at(i))
            i += 1
    return result


## Build the raw-name -> public-name/kind map used by the type lines and every
## foreign signature.  Unselected aliases are kept with an empty public name so
## a foreign signature can resolve a bare alias to its target (e.g.
## `Uint16 -> ushort`, `enet_uint32 -> uint`).
public function build_public_type_names(
    raw_types: span[raw.RawTypeInfo],
    raw_type_order: span[string.String],
    type_spec: policy.AliasSpec,
) -> vec.Vec[TypeNameEntry]:
    var result = vec.Vec[TypeNameEntry].create()
    var kinds = collect_rule_kinds(type_spec.rename_rules)
    var patterns = collect_rule_patterns(type_spec.rename_rules)
    var replacements = collect_rule_replacements(type_spec.rename_rules)

    var i: ptr_uint = 0
    while i < raw_type_order.len:
        let order_name = unsafe: read(raw_type_order.data + i)
        let raw_name = order_name.as_str()
        let selected = type_selected(raw_name, type_spec)

        var public_name = string.String.create()
        var is_opaque = false
        if selected:
            let override = find_type_override(raw_name, type_spec)
            var override_name: str = ""
            if override != null:
                unsafe:
                    override_name = read(override).name.as_str()
                    is_opaque = read(override).override_kind.as_str().equal("opaque")
            public_name = public_type_name(
                raw_name,
                type_spec.strip_prefix.as_str(),
                kinds,
                patterns,
                replacements,
                override_name,
            )

        var alias_target = string.String.create()
        let type_info = find_type_info(raw_types, raw_name)
        if type_info != null:
            unsafe:
                if read(type_info).kind == raw.RawDeclKind.raw_type_alias:
                    alias_target.release()
                    alias_target = string.String.from_str(read(type_info).target.as_str())

        result.push(TypeNameEntry(
            raw_name = string.String.from_str(raw_name),
            public_name = public_name,
            is_opaque = is_opaque,
            selected = selected,
            alias_target = alias_target,
        ))
        i += 1

    release_string_vec(ref_of(kinds))
    release_string_vec(ref_of(patterns))
    release_string_vec(ref_of(replacements))
    return result

# =============================================================================
#  Type alias generation
# =============================================================================

## Generate type alias lines for all types selected by the policy.
public function generate_type_lines(
    raw_types: span[raw.RawTypeInfo],
    raw_type_order: span[string.String],
    type_spec: policy.AliasSpec,
    type_map: span[TypeNameEntry],
    import_alias: str,
) -> vec.Vec[string.String]:
    var lines = vec.Vec[string.String].create()

    var i: ptr_uint = 0
    while i < raw_type_order.len:
        let order_name = unsafe: read(raw_type_order.data + i)
        let raw_name = order_name.as_str()

        if not type_selected(raw_name, type_spec):
            i += 1
            continue

        let type_info = find_type_info(raw_types, raw_name) else:
            i += 1
            continue
        let entry = find_type_entry(type_map, raw_name) else:
            i += 1
            continue
        if not unsafe: read(entry).selected:
            i += 1
            continue

        unsafe:
            let public_name = read(entry).public_name.as_str()
            if read(entry).is_opaque:
                let declared_c_name = read(type_info).c_name.as_str()
                let c_name = if declared_c_name.len > 0: declared_c_name else: raw_name
                var l = string.String.with_capacity(c_name.len + public_name.len + 30)
                l.append("public opaque ")
                l.append(public_name)
                l.append(" = c\"")
                l.append(c_name)
                l.append("\"")
                lines.push(l)
            else:
                let override = find_type_override(raw_name, type_spec)
                var l = string.String.with_capacity(raw_name.len + public_name.len + import_alias.len + 30)
                l.append("public type ")
                l.append(public_name)
                l.append(" = ")
                if override != null and read(override).mapping.len() > 0:
                    l.append(read(override).mapping.as_str())
                else:
                    l.append(import_alias)
                    l.append(".")
                    l.append(raw_name)
                lines.push(l)

        i += 1

    return lines


function find_type_override(raw_name: str, spec: policy.AliasSpec) -> ptr[policy.TypeOverride]?:
    var i: ptr_uint = 0
    while i < spec.overrides.len():
        let p = spec.overrides.get(i)
        if p != null and unsafe: read(p).raw.as_str().equal(raw_name):
            return p
        i += 1
    return null


function type_selected(raw_name: str, spec: policy.AliasSpec) -> bool:
    var ei: ptr_uint = 0
    while ei < spec.exclude.len():
        let en = spec.exclude.get(ei)
        if en != null and unsafe: read(en).as_str().equal(raw_name):
            return false
        ei += 1

    if spec.include_kind == policy.IncludeKind.include_all:
        return true

    var ii: ptr_uint = 0
    while ii < spec.include_list.len():
        let iname = spec.include_list.get(ii)
        if iname != null and unsafe: read(iname).as_str().equal(raw_name):
            return true
        ii += 1

    var pi: ptr_uint = 0
    while pi < spec.include_prefixes.len():
        let prefix = spec.include_prefixes.get(pi)
        if prefix != null and raw_name.starts_with(unsafe: read(prefix).as_str()):
            return true
        pi += 1

    return false


function find_type_info(raw_types: span[raw.RawTypeInfo], name: str) -> ptr[raw.RawTypeInfo]?:
    var i: ptr_uint = 0
    while i < raw_types.len:
        unsafe:
            let ti = raw_types.data + i
            if ti.name.as_str().equal(name):
                return ti
        i += 1
    return null

# =============================================================================
#  Const alias generation
# =============================================================================

## Generate const alias lines for all constants selected by the policy.
public function generate_const_lines(
    raw_consts: span[raw.RawConstInfo],
    raw_const_order: span[string.String],
    const_spec: policy.AliasSpec,
    type_map: span[TypeNameEntry],
    import_alias: str,
) -> vec.Vec[string.String]:
    var lines = vec.Vec[string.String].create()
    var kinds = collect_rule_kinds(const_spec.rename_rules)
    var patterns = collect_rule_patterns(const_spec.rename_rules)
    var replacements = collect_rule_replacements(const_spec.rename_rules)

    var i: ptr_uint = 0
    while i < raw_const_order.len:
        let order_name = unsafe: read(raw_const_order.data + i)
        let raw_name = order_name.as_str()

        if not const_selected(raw_name, const_spec):
            i += 1
            continue

        let override = find_type_override(raw_name, const_spec)
        var override_name: str = ""
        if override != null:
            unsafe:
                override_name = read(override).name.as_str()

        var pub_name: string.String
        if override_name.len > 0:
            pub_name = string.String.from_str(override_name)
        else:
            pub_name = public_const_name(
                raw_name,
                const_spec.strip_prefix.as_str(),
                kinds,
                patterns,
                replacements,
            )

        unsafe:
            let ci = find_const_info(raw_consts, raw_name) else:
                pub_name.release()
                i += 1
                continue

            var type_str: string.String
            if override != null and read(override).const_type.len() > 0:
                type_str = string.String.from_str(read(override).const_type.as_str())
            else:
                let ctype = read(ci).const_type.as_str()
                if ctype.len > 0:
                    type_str = render_type_text(type_map, ctype, false)
                else:
                    type_str = string.String.from_str("int")

            var l = string.String.with_capacity(raw_name.len + pub_name.len() + import_alias.len + type_str.len() + 30)
            l.append("public const ")
            l.append(pub_name.as_str())
            l.append(": ")
            l.append(type_str.as_str())
            l.append(" = ")
            if override != null and read(override).mapping.len() > 0:
                l.append(read(override).mapping.as_str())
            else:
                l.append(import_alias)
                l.append(".")
                l.append(raw_name)
            lines.push(l)
            type_str.release()

        pub_name.release()
        i += 1

    release_string_vec(ref_of(kinds))
    release_string_vec(ref_of(patterns))
    release_string_vec(ref_of(replacements))
    return lines


function const_selected(raw_name: str, spec: policy.AliasSpec) -> bool:
    var ei: ptr_uint = 0
    while ei < spec.exclude.len():
        let en = spec.exclude.get(ei)
        if en != null and unsafe: read(en).as_str().equal(raw_name):
            return false
        ei += 1
    if spec.include_kind == policy.IncludeKind.include_all:
        return true
    var ii: ptr_uint = 0
    while ii < spec.include_list.len():
        let iname = spec.include_list.get(ii)
        if iname != null and unsafe: read(iname).as_str().equal(raw_name):
            return true
        ii += 1
    var pi: ptr_uint = 0
    while pi < spec.include_prefixes.len():
        let prefix = spec.include_prefixes.get(pi)
        if prefix != null and raw_name.starts_with(unsafe: read(prefix).as_str()):
            return true
        pi += 1
    return false


function find_const_info(raw_consts: span[raw.RawConstInfo], name: str) -> ptr[raw.RawConstInfo]?:
    var i: ptr_uint = 0
    while i < raw_consts.len:
        unsafe:
            let ci = raw_consts.data + i
            if ci.name.as_str().equal(name):
                return ci
        i += 1
    return null

# =============================================================================
#  Foreign function generation
# =============================================================================

## Generate foreign function lines from parsed param data.  A raw function may
## carry several overrides; the host emits one signature per override, in
## policy order, at the raw declaration's position.
public function generate_function_lines(
    raw_funcs: span[raw.RawFuncInfo],
    raw_func_order: span[string.String],
    func_spec: policy.FunctionSpec,
    type_map: span[TypeNameEntry],
    import_alias: str,
) -> vec.Vec[string.String]:
    var lines = vec.Vec[string.String].create()
    var kinds = collect_rule_kinds(func_spec.rename_rules)
    var patterns = collect_rule_patterns(func_spec.rename_rules)
    var replacements = collect_rule_replacements(func_spec.rename_rules)
    let has_opengl = spec_has_opengl(kinds)

    var i: ptr_uint = 0
    while i < raw_func_order.len:
        let order_name = unsafe: read(raw_func_order.data + i)
        let raw_name = order_name.as_str()

        if not func_selected(raw_name, func_spec):
            i += 1
            continue

        if not has_function_override(raw_name, func_spec):
            lines.push(emit_function_line(
                raw_name, null, func_spec, type_map, import_alias,
                kinds, patterns, replacements, has_opengl, raw_funcs,
            ))
        else:
            var oi: ptr_uint = 0
            while oi < func_spec.overrides.len():
                let op = func_spec.overrides.get(oi)
                if op != null and unsafe: read(op).raw.as_str().equal(raw_name):
                    lines.push(emit_function_line(
                        raw_name, op, func_spec, type_map, import_alias,
                        kinds, patterns, replacements, has_opengl, raw_funcs,
                    ))
                oi += 1
        i += 1

    release_string_vec(ref_of(kinds))
    release_string_vec(ref_of(patterns))
    release_string_vec(ref_of(replacements))
    return lines


function emit_function_line(
    raw_name: str,
    override: ptr[policy.FunctionOverride]?,
    func_spec: policy.FunctionSpec,
    type_map: span[TypeNameEntry],
    import_alias: str,
    kinds: vec.Vec[string.String],
    patterns: vec.Vec[string.String],
    replacements: vec.Vec[string.String],
    has_opengl: bool,
    raw_funcs: span[raw.RawFuncInfo],
) -> string.String:
    var override_name: str = ""
    if override != null:
        unsafe:
            override_name = read(override).name.as_str()

    var pub_name = public_value_name(
        raw_name,
        func_spec.strip_prefix.as_str(),
        kinds,
        patterns,
        replacements,
        has_opengl,
        raw_funcs,
        override_name,
    )

    var l = string.String.with_capacity(pub_name.len() + import_alias.len + raw_name.len + 80)
    l.append("public foreign function ")
    l.append(pub_name.as_str())

    if override != null:
        unsafe:
            let type_params = read(override).type_params
            if type_params.len() > 0:
                l.append("[")
                var ti: ptr_uint = 0
                while ti < type_params.len():
                    let tp = type_params.get(ti)
                    if tp != null:
                        if ti > 0:
                            l.append(", ")
                        l.append(read(tp).as_str())
                    ti += 1
                l.append("]")

    l.append("(")

    if override == null:
        let emitted_params = build_raw_params(l, raw_funcs, raw_name, type_map, true)
        let fi = find_func_info(raw_funcs, raw_name)
        if fi != null and unsafe: read(fi).variadic:
            if emitted_params:
                l.append(", ")
            l.append("...")
    else:
        unsafe:
            let ov_info = read(override)
            if ov_info.params.len() > 0:
                build_override_params_body(l, ov_info)
            else:
                build_raw_params(l, raw_funcs, raw_name, type_map, false)

    l.append(") -> ")

    if override != null:
        unsafe:
            let ov_info = read(override)
            if ov_info.return_type.len() > 0:
                l.append(ov_info.return_type.as_str())
            else:
                append_raw_return_type(l, raw_funcs, raw_name, type_map)
    else:
        append_raw_return_type(l, raw_funcs, raw_name, type_map)

    l.append(" = ")
    var has_mapping = false
    if override != null:
        unsafe:
            let ov_info = read(override)
            if ov_info.mapping.len() > 0:
                l.append(ov_info.mapping.as_str())
                has_mapping = true
    if not has_mapping:
        l.append(import_alias)
        l.append(".")
        l.append(raw_name)

    pub_name.release()
    return l


function has_function_override(raw_name: str, func_spec: policy.FunctionSpec) -> bool:
    return find_function_override(raw_name, func_spec) != null


function find_function_override(raw_name: str, func_spec: policy.FunctionSpec) -> ptr[policy.FunctionOverride]?:
    var oi: ptr_uint = 0
    while oi < func_spec.overrides.len():
        let ov_ptr = func_spec.overrides.get(oi)
        if ov_ptr != null and unsafe: read(ov_ptr).raw.as_str().equal(raw_name):
            return ov_ptr
        oi += 1
    return null


function build_raw_params(
    l: ref[string.String],
    raw_funcs: span[raw.RawFuncInfo],
    raw_name: str,
    type_map: span[TypeNameEntry],
    cstr_as_str: bool,
) -> bool:
    let fi = find_func_info(raw_funcs, raw_name) else:
        return false
    var emitted = false
    unsafe:
        var pi: ptr_uint = 0
        while pi < read(fi).params.len:
            let param_ptr = read(fi).params.get(pi)
            if param_ptr != null:
                if emitted:
                    l.append(", ")
                var pname = naming.snake_case(read(param_ptr).name.as_str())
                var sanitized = naming.sanitize_value_binding_name(pname.as_str())
                pname.release()
                l.append(sanitized.as_str())
                sanitized.release()

                let ptype = read(param_ptr).param_type.as_str()
                if cstr_as_str and ptype.equal("cstr"):
                    l.append(": str as cstr")
                else:
                    var rendered = render_type_text(type_map, ptype, true)
                    l.append(": ")
                    l.append(rendered.as_str())
                    rendered.release()
                emitted = true
            pi += 1
    return emitted


function append_raw_return_type(
    l: ref[string.String],
    raw_funcs: span[raw.RawFuncInfo],
    raw_name: str,
    type_map: span[TypeNameEntry],
) -> void:
    let fi = find_func_info(raw_funcs, raw_name) else:
        l.append("void")
        return
    unsafe:
        let raw_type = read(fi).return_type.as_str()
        if raw_type.len == 0:
            l.append("void")
        else:
            var rendered = render_type_text(type_map, raw_type, true)
            l.append(rendered.as_str())
            rendered.release()


function build_override_params_body(l: ref[string.String], ov: policy.FunctionOverride) -> bool:
    var pi: ptr_uint = 0
    while pi < ov.params.len():
        let p_ptr = ov.params.get(pi)
        if p_ptr != null:
            if pi > 0:
                l.append(", ")
            unsafe:
                let param = read(p_ptr)
                if param.mode.len() > 0:
                    l.append(param.mode.as_str())
                    l.append(" ")
                var pname = naming.snake_case(param.name.as_str())
                var sanitized = naming.sanitize_value_binding_name(pname.as_str())
                pname.release()
                l.append(sanitized.as_str())
                sanitized.release()
                l.append(": ")
                l.append(param.param_type.as_str())
                if param.boundary_type.len() > 0:
                    l.append(" as ")
                    l.append(param.boundary_type.as_str())
        pi += 1
    return ov.params.len() > 0


public function func_selected(raw_name: str, spec: policy.FunctionSpec) -> bool:
    var ei: ptr_uint = 0
    while ei < spec.exclude.len():
        let en = spec.exclude.get(ei)
        if en != null and unsafe: read(en).as_str().equal(raw_name):
            return false
        ei += 1
    if has_function_override(raw_name, spec):
        return true
    if spec.include_kind == policy.IncludeKind.include_all:
        return true
    var ii: ptr_uint = 0
    while ii < spec.include_list.len():
        let iname = spec.include_list.get(ii)
        if iname != null and unsafe: read(iname).as_str().equal(raw_name):
            return true
        ii += 1
    var pi: ptr_uint = 0
    while pi < spec.include_prefixes.len():
        let prefix = spec.include_prefixes.get(pi)
        if prefix != null and raw_name.starts_with(unsafe: read(prefix).as_str()):
            return true
        pi += 1
    return false


function find_func_info(raw_funcs: span[raw.RawFuncInfo], name: str) -> ptr[raw.RawFuncInfo]?:
    var i: ptr_uint = 0
    while i < raw_funcs.len:
        unsafe:
            let fi = raw_funcs.data + i
            if fi.name.as_str().equal(name):
                return fi
        i += 1
    return null

# =============================================================================
#  Cross-module import detection
# =============================================================================

## Scan all function params and return types for module-prefixed type references
## (e.g., rl.Vector2) and collect the corresponding import lines needed.
public function collect_cross_module_imports(
    raw_funcs: span[raw.RawFuncInfo],
    raw_func_order: span[string.String],
    func_spec: policy.FunctionSpec,
    raw_imports: span[raw.RawImportInfo],
    raw_module_name: str,
) -> vec.Vec[string.String]:
    var imports = vec.Vec[string.String].create()
    var seen = vec.Vec[string.String].create()

    var i: ptr_uint = 0
    while i < raw_func_order.len:
        let order_name = unsafe: read(raw_func_order.data + i)
        let raw_name = order_name.as_str()

        if not func_selected(raw_name, func_spec):
            i += 1
            continue

        let fi = find_func_info(raw_funcs, raw_name) else:
            i += 1
            continue

        unsafe:
            var pi: ptr_uint = 0
            while pi < read(fi).params.len:
                let param_ptr = read(fi).params.get(pi)
                if param_ptr != null:
                    add_module_import_for_type(
                        read(param_ptr).param_type.as_str(),
                        raw_imports,
                        ref_of(imports),
                        ref_of(seen)
                    )
                pi += 1

            let rtype = read(fi).return_type.as_str()
            add_module_import_for_type(rtype, raw_imports, ref_of(imports), ref_of(seen))

        i += 1

    release_string_vec(ref_of(seen))
    return imports


function add_module_import_for_type(
    type_str: str,
    raw_imports: span[raw.RawImportInfo],
    import_lines: ref[vec.Vec[string.String]],
    seen_set: ref[vec.Vec[string.String]],
) -> void:
    let dot = type_str.find_substring(".")
    let dot_pos = dot else:
        return
    let alias = type_str.slice(0, dot_pos)
    if alias.len == 0:
        return

    var si: ptr_uint = 0
    while si < seen_set.len():
        let s = seen_set.get(si)
        if s != null and unsafe: read(s).as_str().equal(alias):
            return
        si += 1

    seen_set.push(string.String.from_str(alias))

    var ri: ptr_uint = 0
    while ri < raw_imports.len:
        unsafe:
            let imp = raw_imports.data + ri
            if imp.alias.as_str().equal(alias):
                var il = string.String.with_capacity(80)
                il.append("import ")
                il.append(imp.module_name.as_str())
                il.append(" as ")
                il.append(alias)
                import_lines.push(il)
                return
        ri += 1


function release_string_vec(v: ref[vec.Vec[string.String]]) -> void:
    var i: ptr_uint = 0
    while i < v.len():
        let p = v.get(i)
        if p != null:
            unsafe: read(p).release()
        i += 1
    v.release()

# =============================================================================
#  Rename rule metadata helpers
# =============================================================================

function collect_rule_kinds(rules: vec.Vec[policy.RenameRule]) -> vec.Vec[string.String]:
    var r = vec.Vec[string.String].create()
    var i: ptr_uint = 0
    while i < rules.len():
        let rp = rules.get(i)
        if rp != null:
            unsafe: r.push(string.String.from_str(read(rp).kind.as_str()))
        i += 1
    return r


function collect_rule_patterns(rules: vec.Vec[policy.RenameRule]) -> vec.Vec[string.String]:
    var r = vec.Vec[string.String].create()
    var i: ptr_uint = 0
    while i < rules.len():
        let rp = rules.get(i)
        if rp != null:
            unsafe: r.push(string.String.from_str(read(rp).pattern.as_str()))
        i += 1
    return r


function collect_rule_replacements(rules: vec.Vec[policy.RenameRule]) -> vec.Vec[string.String]:
    var r = vec.Vec[string.String].create()
    var i: ptr_uint = 0
    while i < rules.len():
        let rp = rules.get(i)
        if rp != null:
            unsafe: r.push(string.String.from_str(read(rp).replace_with.as_str()))
        i += 1
    return r
