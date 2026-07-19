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

        var pub_name = public_name(
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

## Generate foreign function lines for pass-through external functions.
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

        let fi = find_func_info(raw_funcs, raw_name) else:
            pub_name.release()
            i += 1
            continue

        unsafe:
            let sig = read(fi).signature.as_str()
            # Generate pass-through: public foreign function name(...) -> T = c.RawName
            var l = string.String.with_capacity(pub_name.len() + import_alias.len + raw_name.len + 40)
            l.append("public foreign function ")
            l.append(pub_name.as_str())
            # Extract params + return from the raw external func signature
            l.append(extract_params_return(sig))
            l.append(" = ")
            l.append(import_alias)
            l.append(".")
            l.append(raw_name)
            lines.push(l)

        pub_name.release()
        i += 1

    return lines


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


## Extract the parameters and return type from a raw external function signature.
## e.g. "external function InitWindow(width: int, height: int, title: cstr) -> void"
## returns "(width: int, height: int, title: cstr) -> void"
function extract_params_return(signature: str) -> str:
    # Find the first '('
    let paren = signature.find_substring("(")
    let paren_pos = paren else:
        return "() -> void"

    # Find the matching closing paren (account for nested parens)
    var depth: int = 0
    var i = paren_pos
    while i < signature.len:
        let ch = signature.byte_at(i)
        if ch == '(':
            depth += 1
        else if ch == ')':
            depth -= 1
            if depth == 0:
                break
        i += 1

    if depth != 0:
        return signature.slice(paren_pos, signature.len - paren_pos)

    # Include the return type if present
    let after_paren = signature.slice(paren_pos, i - paren_pos + 1)
    let rest = signature.slice(i + 1, signature.len - i - 1)
    let arrow = rest.find_substring("->")
    let arrow_pos = arrow else:
        return after_paren
    return signature.slice(paren_pos, (i + 1 + arrow_pos + 2) - paren_pos + rest.len - arrow_pos - 2)


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
