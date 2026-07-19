## Imported bindings emitter — generates MT source lines for type aliases,
## const aliases, and foreign functions from the policy and raw module data.

import std.string as string
import std.vec as vec
import std.str

import mtc.imported_bindings.policy as policy
import mtc.imported_bindings.naming as naming
import mtc.imported_bindings.raw_scanner as raw

# =============================================================================
#  Name resolution utilities
# =============================================================================

## Get the public name for a raw name by applying the policy's rename rules
## and strip_prefix, then snake_case and sanitize.
function public_name(
    raw_name: str,
    spec_strip_prefix: str,
    spec_rule_kinds: vec.Vec[string.String],
    spec_rule_patterns: vec.Vec[string.String],
    spec_rule_replacements: vec.Vec[string.String],
) -> string.String:
    var name = string.String.from_str(raw_name)

    # Apply rename rules
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

    # Strip prefix
    if spec_strip_prefix.len > 0:
        let stripped = naming.strip_prefix_str(name.as_str(), spec_strip_prefix)
        var new_name = string.String.from_str(stripped)
        name.release()
        name = new_name

    # Snake case
    var snaked = naming.snake_case(name.as_str())
    name.release()
    name = snaked

    # Sanitize
    let sanitized = naming.sanitize_binding_name(name.as_str())
    name.release()
    return sanitized


## Like public_name but skips snake_case — for constants which keep their casing.
function public_const_name(
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

    let sanitized = naming.sanitize_binding_name(name.as_str())
    name.release()
    return sanitized


# =============================================================================
#  Type alias generation
# =============================================================================

## Generate type alias lines for all types in the raw module that pass the
## policy's include/exclude filters.
public function generate_type_lines(
    raw_types: span[raw.RawTypeInfo],
    raw_type_order: span[string.String],
    type_spec: policy.AliasSpec,
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

        # Find the type info
        let type_info = find_type_info(raw_types, raw_name) else:
            i += 1
            continue

        var pub_name = public_name(
            raw_name,
            type_spec.strip_prefix.as_str(),
            collect_rule_kinds(type_spec.rename_rules),
            collect_rule_patterns(type_spec.rename_rules),
            collect_rule_replacements(type_spec.rename_rules),
        )

        unsafe:
            if read(type_info).kind == raw.RawDeclKind.raw_opaque:
                let cname = read(type_info).c_name.as_str()
                if cname.len > 0:
                    var l = string.String.with_capacity(cname.len + pub_name.len() + 30)
                    l.append("public opaque ")
                    l.append(pub_name.as_str())
                    l.append(" = c\"")
                    l.append(cname)
                    l.append("\"")
                    lines.push(l)
                else:
                    var l = string.String.with_capacity(pub_name.len() + 30)
                    l.append("public opaque ")
                    l.append(pub_name.as_str())
                    lines.push(l)
            else:
                var l = string.String.with_capacity(raw_name.len + pub_name.len() + import_alias.len + 30)
                l.append("public type ")
                l.append(pub_name.as_str())
                l.append(" = ")
                l.append(import_alias)
                l.append(".")
                l.append(raw_name)
                lines.push(l)

        pub_name.release()
        i += 1

    return lines


function type_selected(raw_name: str, spec: policy.AliasSpec) -> bool:
    # Check exclude list
    var ei: ptr_uint = 0
    while ei < spec.exclude.len():
        let en = spec.exclude.get(ei)
        if en != null and unsafe: read(en).as_str().equal(raw_name):
            return false
        ei += 1

    # If include_all, everything passes except excludes
    if spec.include_kind == policy.IncludeKind.include_all:
        return true

    # Check include list
    var ii: ptr_uint = 0
    while ii < spec.include_list.len():
        let iname = spec.include_list.get(ii)
        if iname != null and unsafe: read(iname).as_str().equal(raw_name):
            return true
        ii += 1

    # Check include prefixes
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
        let ti = unsafe: raw_types.data + i
        if ti.name.as_str().equal(name):
            return ti
        i += 1
    return null


# =============================================================================
#  Const alias generation
# =============================================================================

## Generate const alias lines for all constants in the raw module.
public function generate_const_lines(
    raw_consts: span[raw.RawConstInfo],
    raw_const_order: span[string.String],
    const_spec: policy.AliasSpec,
    import_alias: str,
) -> vec.Vec[string.String]:
    var lines = vec.Vec[string.String].create()

    var i: ptr_uint = 0
    while i < raw_const_order.len:
        let order_name = unsafe: read(raw_const_order.data + i)
        let raw_name = order_name.as_str()

        if not const_selected(raw_name, const_spec):
            i += 1
            continue

        var pub_name = public_const_name(
            raw_name,
            const_spec.strip_prefix.as_str(),
            collect_rule_kinds(const_spec.rename_rules),
            collect_rule_patterns(const_spec.rename_rules),
            collect_rule_replacements(const_spec.rename_rules),
        )

        unsafe:
            let ci = find_const_info(raw_consts, raw_name) else:
                pub_name.release()
                i += 1
                continue
            # Use the raw const's declared type if available
            let ctype = read(ci).const_type.as_str()
            let type_str = if ctype.len > 0: ctype else: "int"
            var l = string.String.with_capacity(raw_name.len + pub_name.len() + import_alias.len + type_str.len + 30)
            l.append("public const ")
            l.append(pub_name.as_str())
            l.append(": ")
            l.append(type_str)
            l.append(" = ")
            l.append(import_alias)
            l.append(".")
            l.append(raw_name)
            lines.push(l)

        pub_name.release()
        i += 1

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
        let ci = unsafe: raw_consts.data + i
        if ci.name.as_str().equal(name):
            return ci
        i += 1
    return null


# =============================================================================
#  Foreign function generation
# =============================================================================

## Generate foreign function lines from parsed param data.
public function generate_function_lines(
    raw_funcs: span[raw.RawFuncInfo],
    raw_func_order: span[string.String],
    func_spec: policy.FunctionSpec,
    import_alias: str,
) -> vec.Vec[string.String]:
    var lines = vec.Vec[string.String].create()

    var i: ptr_uint = 0
    while i < raw_func_order.len:
        let order_name = unsafe: read(raw_func_order.data + i)
        let raw_name = order_name.as_str()

        if not func_selected(raw_name, func_spec):
            i += 1
            continue

        var pub_name = public_name(
            raw_name,
            func_spec.strip_prefix.as_str(),
            collect_rule_kinds(func_spec.rename_rules),
            collect_rule_patterns(func_spec.rename_rules),
            collect_rule_replacements(func_spec.rename_rules),
        )

        # Check for function override
        var override = find_function_override(raw_name, func_spec)

        var l = string.String.with_capacity(pub_name.len() + import_alias.len + raw_name.len + 80)
        l.append("public foreign function ")
        l.append(pub_name.as_str())
        l.append("(")

        if override == null:
            build_raw_params(l, raw_funcs, raw_name)
        else:
            unsafe:
                let ov_info = read(override)
                if ov_info.params.len() > 0:
                    build_override_params_body(l, ov_info)
                else:
                    build_raw_params(l, raw_funcs, raw_name)

        l.append(") -> ")

        if override != null:
            unsafe:
                let ov_info2 = read(override)
                if ov_info2.return_type.len() > 0:
                    l.append(ov_info2.return_type.as_str())
        if override == null or unsafe: read(override).return_type.len() == 0:
            append_raw_return_type(l, raw_funcs, raw_name)

        l.append(" = ")
        if override != null:
            unsafe:
                let ov_info3 = read(override)
                if ov_info3.mapping.len() > 0:
                    l.append(ov_info3.mapping.as_str())
                    lines.push(l)
                    pub_name.release()
                    i += 1
                    continue

        l.append(import_alias)
        l.append(".")
        l.append(raw_name)
        lines.push(l)
        pub_name.release()
        i += 1

    return lines


function find_function_override(raw_name: str, func_spec: policy.FunctionSpec) -> ptr[policy.FunctionOverride]?:
    var oi: ptr_uint = 0
    while oi < func_spec.overrides.len():
        let ov_ptr = func_spec.overrides.get(oi)
        if ov_ptr != null and unsafe: read(ov_ptr).raw.as_str().equal(raw_name):
            return ov_ptr
        oi += 1
    return null


function build_raw_params(l: ref[string.String], raw_funcs: span[raw.RawFuncInfo], raw_name: str) -> void:
    let fi = find_func_info(raw_funcs, raw_name) else:
        return
    unsafe:
        var pi: ptr_uint = 0
        while pi < read(fi).params.len:
            let param_ptr = read(fi).params.get(pi)
            if param_ptr != null:
                if pi > 0:
                    l.append(", ")
                var pname = naming.snake_case(read(param_ptr).name.as_str())
                l.append(pname.as_str())
                l.append(": ")
                l.append(read(param_ptr).param_type.as_str())
                pname.release()
            pi += 1


function append_raw_return_type(l: ref[string.String], raw_funcs: span[raw.RawFuncInfo], raw_name: str) -> void:
    let fi = find_func_info(raw_funcs, raw_name) else:
        l.append("void")
        return
    unsafe:
        l.append(read(fi).return_type.as_str())


function build_override_params_body(l: ref[string.String], ov: policy.FunctionOverride) -> void:
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
                l.append(pname.as_str())
                l.append(": ")
                l.append(param.param_type.as_str())
                if param.boundary_type.len() > 0:
                    l.append(" as ")
                    l.append(param.boundary_type.as_str())
                pname.release()
        pi += 1


function func_selected(raw_name: str, spec: policy.FunctionSpec) -> bool:
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


function find_func_info(raw_funcs: span[raw.RawFuncInfo], name: str) -> ptr[raw.RawFuncInfo]?:
    var i: ptr_uint = 0
    while i < raw_funcs.len:
        let fi = unsafe: raw_funcs.data + i
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
            # Check params
            var pi: ptr_uint = 0
            while pi < read(fi).params.len:
                let param_ptr = read(fi).params.get(pi)
                if param_ptr != null:
                    add_module_import_for_type(read(param_ptr).param_type.as_str(), raw_imports, ref_of(imports), ref_of(seen))
                pi += 1

            # Check return type
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
    # Check if type contains a module prefix like "rl.Vector2"
    let dot = type_str.find_substring(".")
    let dot_pos = dot else:
        return
    let alias = type_str.slice(0, dot_pos)
    if alias.len == 0:
        return

    # Check if already seen
    var si: ptr_uint = 0
    while si < seen_set.len():
        let s = seen_set.get(si)
        if s != null and unsafe: read(s).as_str().equal(alias):
            return
        si += 1

    seen_set.push(string.String.from_str(alias))

    # Find the raw module import matching this alias
    var ri: ptr_uint = 0
    while ri < raw_imports.len:
        let imp = unsafe: raw_imports.data + ri
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
