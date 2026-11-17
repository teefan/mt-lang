## platform-api-drift — a platform-pinned module (`name.linux.mt`) whose
## exported API differs from a sibling variant (`name.mt`, `name.windows.mt`,
## `name.wasm.mt`).
##
## Mirrors `lib/milk_tea/tooling/linter/imports_platform.rb`: the exported
## surface of each declaration is rendered to a canonical string (the host's
## `render_*_surface`), the current file's surface is compared with each
## sibling's, and one hint is emitted per differing sibling with the missing
## and extra entries.  The anchor prefers the first `extra` entry's declaration,
## then the earliest exported site, then the first declaration.
##
## Sibling files are parsed directly (a parse error skips the sibling, like the
## host's `load_sibling_source_file` rescue); imports are irrelevant to the
## surface, so no loader is needed.

import std.fs as fs
import std.map as map_mod
import std.path as path_ops
import std.str
import std.string as string
import std.vec as vec

import mtc.parser.ast as ast
import mtc.parser.parser as parser
import mtc.parser.state as pstate
import mtc.lexer.token as token_mod
import mtc.loader.path_resolver as resolver


public struct DriftWarning:
    line: ptr_uint
    column: ptr_uint
    length: ptr_uint
    code: str
    message: str
    severity: str
    symbol_name: str


## A declaration's warning anchor (the host's `declaration_anchor` hash).
public struct Anchor:
    line: ptr_uint
    column: ptr_uint
    length: ptr_uint
    symbol_name: str


# =============================================================================
#  Entry point
# =============================================================================

## Compare `file`'s exported surface against every existing platform sibling of
## `path`.  `source` supplies the lines used by the anchors.
public function check_platform_api_drift(file: ast.SourceFile, path: str, source: str) -> vec.Vec[DriftWarning]:
    var result = vec.Vec[DriftWarning].create()
    if not path.ends_with(".mt"):
        return result
    var siblings = platform_variant_sibling_paths(path)
    defer: siblings.release()
    if siblings.len() == 0:
        return result

    var lines = split_lines(source)
    defer: lines.release()
    var current_sites = surface_sites(file, ref_of(lines))
    defer: sites_release(ref_of(current_sites))
    var current = map_keys(ref_of(current_sites))
    defer: current.release()

    var si: ptr_uint = 0
    while si < siblings.len():
        let sp = siblings.get(si) else:
            break
        let sibling_path = unsafe: read(sp).as_str()
        si += 1
        var sibling_sites = load_sibling_sites(sibling_path, ref_of(lines))
        defer: sites_release(ref_of(sibling_sites))
        var sibling = map_keys(ref_of(sibling_sites))
        defer: sibling.release()

        var missing = keys_difference(ref_of(sibling), ref_of(current))
        defer: missing.release()
        var extra = keys_difference(ref_of(current), ref_of(sibling))
        defer: extra.release()
        sort_strings(ref_of(missing))
        sort_strings(ref_of(extra))
        if missing.len() == 0 and extra.len() == 0:
            continue

        let anchor = platform_drift_anchor(file, ref_of(current_sites), ref_of(extra))
        var message = string.String.create()
        message.append("public API differs from ")
        message.append(path_ops.basename(sibling_path))
        message.append(": ")
        var first = true
        if missing.len() > 0:
            message.append("missing ")
            message.append(summarize_surface_entries(ref_of(missing)))
            first = false
        if extra.len() > 0:
            if not first:
                message.append("; ")
            message.append("extra ")
            message.append(summarize_surface_entries(ref_of(extra)))
        result.push(DriftWarning(
            line = anchor.line,
            column = anchor.column,
            length = anchor.length,
            code = "platform-api-drift",
            message = message.as_str(),
            severity = "warning",
            symbol_name = anchor.symbol_name,
        ))
    return result


# =============================================================================
#  Sibling discovery
# =============================================================================

function platform_variant_sibling_paths(path: str) -> vec.Vec[string.String]:
    var result = vec.Vec[string.String].create()
    var shared_owner: string.String
    match resolver.platform_suffix_for_path(path):
        Option.some as p:
            let suffix = resolver.platform_suffix(p.value)
            var stem = string.String.create()
            stem.append(path.slice(0, path.len - (suffix.len + 4)))
            stem.append(".mt")
            shared_owner = stem
        Option.none:
            shared_owner = string.String.from_str(path)
    defer: shared_owner.release()
    let shared = shared_owner.as_str()

    maybe_push_sibling(ref_of(result), shared, path)
    var platforms = vec.Vec[str].create()
    defer: platforms.release()
    platforms.push("linux")
    platforms.push("windows")
    platforms.push("wasm")
    var pi: ptr_uint = 0
    while pi < platforms.len():
        let pp = platforms.get(pi) else:
            break
        let platform_name = unsafe: read(pp)
        var candidate = string.String.create()
        candidate.append(shared.slice(0, shared.len - 3))
        candidate.append(".")
        candidate.append(platform_name)
        candidate.append(".mt")
        maybe_push_sibling(ref_of(result), candidate.as_str(), path)
        candidate.release()
        pi += 1
    return result


function maybe_push_sibling(siblings: ref[vec.Vec[string.String]], candidate: str, path: str) -> void:
    if candidate.equal(path) or not fs.is_file(candidate):
        return
    var i: ptr_uint = 0
    while i < siblings.len():
        let existing = siblings.get(i) else:
            break
        if unsafe: read(existing).as_str().equal(candidate):
            return
        i += 1
    siblings.push(string.String.from_str(candidate))


function load_sibling_sites(path: str, lines: ref[vec.Vec[str]]) -> map_mod.Map[str, Anchor]:
    var sites = map_mod.Map[str, Anchor].create()
    match fs.read_text(path):
        Result.success as content:
            let text = content.value.as_str()
            var errors = vec.Vec[pstate.ParseDiagnostic].create()
            defer: errors.release()
            let sibling = parser.parse_source(text, ref_of(errors))
            if errors.len() == 0:
                var text_lines = split_lines(text)
                defer: text_lines.release()
                sites_release(ref_of(sites))
                sites = surface_sites(sibling, ref_of(text_lines))
            content.value.release()
        Result.failure:
            pass
    return sites


# =============================================================================
#  Exported surface
# =============================================================================

## One map from each exported declaration's rendered surface to its anchor.
function surface_sites(file: ast.SourceFile, lines: ref[vec.Vec[str]]) -> map_mod.Map[str, Anchor]:
    var sites = map_mod.Map[str, Anchor].create()
    var exported_types = exported_type_names(file)
    defer: exported_types.release()
    let raw = file.module_kind == ast.ModuleKind.module_raw
    var i: ptr_uint = 0
    unsafe:
        while i < file.declarations.len:
            let decl = read(file.declarations.data + i)
            i += 1
            match decl:
                ast.Decl.decl_const as d:
                    if raw or d.visibility:
                        sites.set(render_value_surface("const", d.name, d.const_type), anchor_of(d.line, d.column, d.name, lines))
                ast.Decl.decl_var as d:
                    if raw or d.visibility:
                        if d.var_type != null:
                            let tr_ptr = d.var_type else:
                                continue
                            sites.set(render_value_surface("var", d.name, tr_ptr), anchor_of(d.line, d.column, d.name, lines))
                        else:
                            sites.set(render_var_surface(d.name), anchor_of(d.line, d.column, d.name, lines))
                ast.Decl.decl_event as d:
                    if raw or d.visibility:
                        sites.set(render_event_surface(d.name, d.capacity, d.payload_type), anchor_of(d.line, d.column, d.name, lines))
                ast.Decl.decl_type_alias as d:
                    if raw or d.visibility:
                        sites.set(render_type_alias_surface(d.name, d.target), anchor_of(d.line, d.column, d.name, lines))
                ast.Decl.decl_struct as d:
                    if raw or d.visibility:
                        sites.set(render_struct_surface(d.name, d.struct_attrs, d.type_params, d.impl_list, d.struct_fields, d.struct_events), anchor_of(d.line, d.column, d.name, lines))
                ast.Decl.decl_union as d:
                    if raw or d.visibility:
                        sites.set(render_union_surface(d.name, d.union_fields), anchor_of(d.line, d.column, d.name, lines))
                ast.Decl.decl_enum as d:
                    if raw or d.visibility:
                        sites.set(render_enum_body("enum", d.name, d.backing_type, d.enum_members), anchor_of(d.line, d.column, d.name, lines))
                ast.Decl.decl_flags as d:
                    if raw or d.visibility:
                        sites.set(render_enum_body("flags", d.name, d.backing_type, d.flags_members), anchor_of(d.line, d.column, d.name, lines))
                ast.Decl.decl_opaque as d:
                    if raw or d.visibility:
                        sites.set(render_opaque_surface(d.name, d.opaque_implements), anchor_of(d.line, d.column, d.name, lines))
                ast.Decl.decl_interface as d:
                    if raw or d.visibility:
                        sites.set(render_interface_surface(d.name, d.interface_methods), anchor_of(d.line, d.column, d.name, lines))
                ast.Decl.decl_variant as d:
                    if raw or d.visibility:
                        sites.set(render_variant_surface(d.name, d.type_params, d.variant_arms), anchor_of(d.line, d.column, d.name, lines))
                ast.Decl.decl_function as d:
                    if raw or d.visibility:
                        sites.set(render_function_surface(d.name, d.type_params, d.method_params, d.return_type, d.is_async), anchor_of(d.line, d.column, d.name, lines))
                ast.Decl.decl_extern_function as d:
                    if raw:
                        sites.set(render_external_surface(d.name, d.type_params, d.extern_params, d.return_type, d.variadic), anchor_of(d.line, 0, d.name, lines))
                ast.Decl.decl_foreign_function as d:
                    if raw or d.visibility:
                        sites.set(render_foreign_surface(d.name, d.type_params, d.foreign_params, d.return_type, d.variadic), anchor_of(d.line, 0, d.name, lines))
                ast.Decl.decl_extending_block as d:
                    let receiver = render_type_ref(d.type_name)
                    if exported_types.contains(receiver):
                        var mi: ptr_uint = 0
                        while mi < d.methods.len:
                            let method = read(d.methods.data + mi)
                            mi += 1
                            if method.visibility:
                                sites.set(render_method_surface(receiver, method), anchor_of(method.line, method.column, method.name, lines))
                _:
                    pass
    return sites


function exported_type_names(file: ast.SourceFile) -> map_mod.Map[str, bool]:
    var names = map_mod.Map[str, bool].create()
    let raw = file.module_kind == ast.ModuleKind.module_raw
    var i: ptr_uint = 0
    unsafe:
        while i < file.declarations.len:
            let decl = read(file.declarations.data + i)
            i += 1
            match decl:
                ast.Decl.decl_type_alias as d:
                    if raw or d.visibility:
                        names.set(d.name, true)
                ast.Decl.decl_struct as d:
                    if raw or d.visibility:
                        names.set(d.name, true)
                ast.Decl.decl_union as d:
                    if raw or d.visibility:
                        names.set(d.name, true)
                ast.Decl.decl_enum as d:
                    if raw or d.visibility:
                        names.set(d.name, true)
                ast.Decl.decl_flags as d:
                    if raw or d.visibility:
                        names.set(d.name, true)
                ast.Decl.decl_opaque as d:
                    if raw or d.visibility:
                        names.set(d.name, true)
                ast.Decl.decl_interface as d:
                    if raw or d.visibility:
                        names.set(d.name, true)
                ast.Decl.decl_variant as d:
                    if raw or d.visibility:
                        names.set(d.name, true)
                _:
                    pass
    return names


# =============================================================================
#  Declaration renderers (the host's `render_*_surface`)
# =============================================================================

function render_value_surface(kind: str, name: str, ty: ptr[ast.TypeRef]) -> str:
    var buf = string.String.create()
    buf.append(kind)
    buf.append(" ")
    buf.append(name)
    buf.append(": ")
    buf.append(render_type_ref(ty))
    return buf.as_str()


function render_var_surface(name: str) -> str:
    var buf = string.String.create()
    buf.append("var ")
    buf.append(name)
    return buf.as_str()


function render_event_surface(name: str, capacity: int, payload: ptr[ast.TypeRef]?) -> str:
    var buf = string.String.create()
    buf.append("event ")
    buf.append(name)
    buf.append("[")
    buf.append(int_to_dec(capacity))
    buf.append("]")
    if payload != null:
        buf.append("(")
        buf.append(render_type_ref(payload))
        buf.append(")")
    return buf.as_str()


function render_type_alias_surface(name: str, target: ptr[ast.TypeRef]) -> str:
    var buf = string.String.create()
    buf.append("type ")
    buf.append(name)
    buf.append(" = ")
    buf.append(render_type_ref(target))
    return buf.as_str()


function render_struct_surface(
    name: str,
    attributes: span[ast.AttributeApplication],
    type_params: span[ast.TypeParam],
    impl_list: span[ast.QualifiedName],
    fields: span[ast.Field],
    events: span[ast.Decl],
) -> str:
    var buf = string.String.create()
    let prefix = render_attributes(attributes)
    if prefix.len > 0:
        buf.append(prefix)
        buf.append(" ")
    buf.append("struct ")
    buf.append(name)
    append_type_params(buf, type_params)
    append_implements(buf, impl_list)
    buf.append(" { ")
    var first = true
    var fi: ptr_uint = 0
    unsafe:
        while fi < fields.len:
            var f = read(fields.data + fi)
            fi += 1
            if not first:
                buf.append(", ")
            first = false
            buf.append(f.name)
            buf.append(": ")
            buf.append(render_type_ref(ptr_of(f.field_type)))
        var ei: ptr_uint = 0
        while ei < events.len:
            let e = read(events.data + ei)
            ei += 1
            match e:
                ast.Decl.decl_event as ev:
                    if not first:
                        buf.append(", ")
                    first = false
                    buf.append(render_event_surface(ev.name, ev.capacity, ev.payload_type))
                _:
                    pass
    buf.append(" }")
    return buf.as_str()

function render_union_surface(name: str, fields: span[ast.Field]) -> str:
    var buf = string.String.create()
    buf.append("union ")
    buf.append(name)
    buf.append(" { ")
    append_fields(buf, fields)
    buf.append(" }")
    return buf.as_str()



function render_enum_body(kind: str, name: str, backing: ptr[ast.TypeRef]?, members: span[ast.EnumMember]) -> str:
    var buf = string.String.create()
    buf.append(kind)
    buf.append(" ")
    buf.append(name)
    buf.append(": ")
    if backing != null:
        buf.append(render_type_ref(backing))
    buf.append(" { ")
    var i: ptr_uint = 0
    unsafe:
        while i < members.len:
            if i > 0:
                buf.append(", ")
            buf.append(read(members.data + i).name)
            i += 1
    buf.append(" }")
    return buf.as_str()


function render_opaque_surface(name: str, impl_list: span[ast.QualifiedName]) -> str:
    var buf = string.String.create()
    buf.append("opaque ")
    buf.append(name)
    append_implements(buf, impl_list)
    return buf.as_str()

function render_interface_surface(name: str, methods: span[ast.InterfaceMethod]) -> str:
    var rendered = vec.Vec[str].create()
    defer: rendered.release()
    var mi: ptr_uint = 0
    unsafe:
        while mi < methods.len:
            let m = read(methods.data + mi)
            mi += 1
            rendered.push(render_interface_method_surface(name, m))
    sort_strings(ref_of(rendered))
    var buf = string.String.create()
    buf.append("interface ")
    buf.append(name)
    buf.append(" { ")
    var first = true
    var vi: ptr_uint = 0
    while vi < rendered.len():
        let mp = rendered.get(vi) else:
            break
        vi += 1
        if not first:
            buf.append(", ")
        first = false
        buf.append(unsafe: read(mp))
    buf.append(" }")
    return buf.as_str()

function render_variant_surface(name: str, type_params: span[ast.TypeParam], arms: span[ast.VariantArm]) -> str:
    var buf = string.String.create()
    buf.append("variant ")
    buf.append(name)
    append_type_params(buf, type_params)
    buf.append(" { ")
    var i: ptr_uint = 0
    unsafe:
        while i < arms.len:
            if i > 0:
                buf.append(", ")
            let arm = read(arms.data + i)
            i += 1
            buf.append(arm.name)
            if arm.arm_fields.len > 0:
                buf.append("(")
                var fi: ptr_uint = 0
                while fi < arm.arm_fields.len:
                    if fi > 0:
                        buf.append(", ")
                    var af = read(arm.arm_fields.data + fi)
                    buf.append(render_type_ref(ptr_of(af.field_type)))
                    fi += 1
                buf.append(")")
    buf.append(" }")
    return buf.as_str()

function render_function_surface(name: str, type_params: span[ast.TypeParam], params: span[ast.Param], return_type: ptr[ast.TypeRef]?, is_async: bool) -> str:
    var prefix = string.String.create()
    prefix.append("function ")
    prefix.append(name)
    return render_callable_surface(prefix.as_str(), type_params, render_params(params), return_type, is_async)

function render_external_surface(name: str, type_params: span[ast.TypeParam], params: span[ast.ForeignParam], return_type: ptr[ast.TypeRef]?, variadic: bool) -> str:
    var prefix = string.String.create()
    prefix.append("external function ")
    prefix.append(name)
    return render_callable_surface(prefix.as_str(), type_params, render_foreign_params(params, variadic), return_type, false)

function render_foreign_surface(name: str, type_params: span[ast.TypeParam], params: span[ast.ForeignParam], return_type: ptr[ast.TypeRef]?, variadic: bool) -> str:
    var prefix = string.String.create()
    prefix.append("foreign function ")
    prefix.append(name)
    return render_callable_surface(prefix.as_str(), type_params, render_foreign_params(params, variadic), return_type, false)

function render_method_surface(receiver_name: str, method: ast.Method) -> str:
    var prefix = string.String.create()
    if method.method_kind == ast.MethodKind.mk_static:
        prefix.append("static method ")
    else:
        prefix.append("method ")
    prefix.append(receiver_name)
    prefix.append(".")
    prefix.append(method.name)
    return render_callable_surface(prefix.as_str(), method.type_params, render_params(method.method_params), method.return_type, method.is_async)


function render_interface_method_surface(interface_name: str, method: ast.InterfaceMethod) -> str:
    var prefix = string.String.create()
    prefix.append("interface method ")
    prefix.append(interface_name)
    prefix.append(".")
    prefix.append(method.name)
    return render_callable_surface(prefix.as_str(), span[ast.TypeParam](), render_params(method.method_params), method.return_type, method.is_async)


function render_callable_surface(prefix: str, type_params: span[ast.TypeParam], params: str, return_type: ptr[ast.TypeRef]?, is_async: bool) -> str:
    var buf = string.String.create()
    if is_async:
        buf.append("async ")
    buf.append(prefix)
    append_type_params(buf, type_params)
    buf.append("(")
    buf.append(params)
    buf.append(")")
    if return_type != null:
        buf.append(" -> ")
        buf.append(render_type_ref(return_type))
    return buf.as_str()


function render_params(params: span[ast.Param]) -> str:
    var buf = string.String.create()
    var i: ptr_uint = 0
    unsafe:
        while i < params.len:
            if i > 0:
                buf.append(", ")
            var p = read(params.data + i)
            i += 1
            buf.append(p.name)
            buf.append(": ")
            buf.append(render_type_ref(ptr_of(p.param_type)))
    return buf.as_str()


function render_foreign_params(params: span[ast.ForeignParam], variadic: bool) -> str:
    var buf = string.String.create()
    var i: ptr_uint = 0
    unsafe:
        while i < params.len:
            if i > 0:
                buf.append(", ")
            var p = read(params.data + i)
            i += 1
            buf.append(p.name)
            buf.append(": ")
            buf.append(render_type_ref(ptr_of(p.param_type)))
            match p.boundary_type:
                Option.some as boundary:
                    buf.append(" as ")
                    buf.append(render_type_ref(ptr_of(boundary.value)))
                Option.none:
                    pass
    if variadic:
        if params.len > 0:
            buf.append(", ")
        buf.append("...")
    return buf.as_str()


function append_fields(buf: ref[string.String], fields: span[ast.Field]) -> void:
    var i: ptr_uint = 0
    unsafe:
        while i < fields.len:
            if i > 0:
                buf.append(", ")
            var f = read(fields.data + i)
            i += 1
            buf.append(f.name)
            buf.append(": ")
            buf.append(render_type_ref(ptr_of(f.field_type)))


function append_type_params(buf: ref[string.String], type_params: span[ast.TypeParam]) -> void:
    if type_params.len == 0:
        return
    buf.append("[")
    var i: ptr_uint = 0
    unsafe:
        while i < type_params.len:
            if i > 0:
                buf.append(", ")
            let tp = read(type_params.data + i)
            i += 1
            buf.append(tp.name)
            if tp.constraints.len > 0:
                buf.append(" implements ")
                var ci: ptr_uint = 0
                while ci < tp.constraints.len:
                    if ci > 0:
                        buf.append(" and ")
                    buf.append(qualified_name_text(read(tp.constraints.data + ci).interface_ref))
                    ci += 1
    buf.append("]")


function append_implements(buf: ref[string.String], impl_list: span[ast.QualifiedName]) -> void:
    if impl_list.len == 0:
        return
    var names = vec.Vec[str].create()
    defer: names.release()
    var i: ptr_uint = 0
    unsafe:
        while i < impl_list.len:
            names.push(qualified_name_text(read(impl_list.data + i)))
            i += 1
    sort_strings(ref_of(names))
    buf.append(" implements ")
    i = 0
    while i < names.len():
        if i > 0:
            buf.append(", ")
        let np = names.get(i) else:
            break
        buf.append(unsafe: read(np))
        i += 1


function render_attributes(attributes: span[ast.AttributeApplication]) -> str:
    var buf = string.String.create()
    var i: ptr_uint = 0
    unsafe:
        while i < attributes.len:
            if i > 0:
                buf.append(" ")
            buf.append(render_attribute(read(attributes.data + i)))
            i += 1
    return buf.as_str()


function render_attribute(application: ast.AttributeApplication) -> str:
    var buf = string.String.create()
    buf.append("@[")
    buf.append(qualified_name_text(application.name))
    if application.arguments.len > 0:
        buf.append("(")
        var i: ptr_uint = 0
        unsafe:
            while i < application.arguments.len:
                if i > 0:
                    buf.append(", ")
                let arg = read(application.arguments.data + i)
                i += 1
                match arg.arg_name:
                    Option.some as arg_name:
                        buf.append(arg_name.value)
                        buf.append(" = ")
                    Option.none:
                        pass
                buf.append(render_attribute_argument(arg.arg_value))
        buf.append(")")
    buf.append("]")
    return buf.as_str()


function render_attribute_argument(expr: ptr[ast.Expr]) -> str:
    unsafe:
        match read(expr):
            ast.Expr.expr_integer_literal as lit:
                return lit.lexeme
            ast.Expr.expr_float_literal as lit:
                return lit.lexeme
            ast.Expr.expr_string_literal as lit:
                return lit.lexeme
            ast.Expr.expr_identifier as id:
                return id.name
            ast.Expr.expr_member_access as ma:
                match read(ma.receiver):
                    ast.Expr.expr_identifier as id:
                        var buf = string.String.create()
                        buf.append(id.name)
                        buf.append(".")
                        buf.append(ma.member_name)
                        return buf.as_str()
                    _:
                        return "..."
            _:
                return "..."


# =============================================================================
#  Type rendering (the host's `render_type_surface`)
# =============================================================================

function render_type_ref(tr: ptr[ast.TypeRef]) -> str:
    unsafe:
        let t = read(tr)
        if t.is_fn:
            var fn_buf = string.String.create()
            fn_buf.append("fn(")
            fn_buf.append(render_params(t.fn_params))
            fn_buf.append(")")
            let fn_ret = t.fn_return else:
                return fn_buf.as_str()
            fn_buf.append(" -> ")
            fn_buf.append(render_type_ref(fn_ret))
            return fn_buf.as_str()
        if t.is_proc:
            var proc_buf = string.String.create()
            proc_buf.append("proc(")
            proc_buf.append(render_params(t.fn_params))
            proc_buf.append(")")
            let proc_ret = t.fn_return else:
                return proc_buf.as_str()
            proc_buf.append(" -> ")
            proc_buf.append(render_type_ref(proc_ret))
            return proc_buf.as_str()
        var buf = string.String.create()
        buf.append(qualified_name_text(t.name))
        if t.arguments.len > 0:
            buf.append("[")
            var i: ptr_uint = 0
            while i < t.arguments.len:
                if i > 0:
                    buf.append(", ")
                buf.append(render_type_ref(t.arguments.data + i))
                i += 1
            buf.append("]")
        if t.is_dyn:
            buf.append("[")
            buf.append(qualified_name_text(t.dyn_interface))
            buf.append("]")
        if t.nullable:
            buf.append("?")
        return buf.as_str()


function qualified_name_text(name: ast.QualifiedName) -> str:
    var buf = string.String.create()
    var i: ptr_uint = 0
    unsafe:
        while i < name.parts.len:
            if i > 0:
                buf.append(".")
            buf.append(read(name.parts.data + i))
            i += 1
    return buf.as_str()


# =============================================================================
#  Anchors and message helpers
# =============================================================================

function anchor_of(line: ptr_uint, column: ptr_uint, name: str, lines: ref[vec.Vec[str]]) -> Anchor:
    let resolved_line = if line > 0: line else: 1
    let length = if name.len > 0: name.len else: 1
    if column > 0:
        return Anchor(line = resolved_line, column = column, length = length, symbol_name = name)
    if name.len > 0:
        let text = line_at(lines, resolved_line) else:
            return Anchor(line = resolved_line, column = 1, length = length, symbol_name = name)
        match find_from(text, name, 0):
            Option.some as index:
                return Anchor(line = resolved_line, column = index.value + 1, length = length, symbol_name = name)
            Option.none:
                pass
    return Anchor(line = resolved_line, column = 1, length = length, symbol_name = name)


function line_at(lines: ref[vec.Vec[str]], line: ptr_uint) -> Option[str]:
    if line == 0 or line > lines.len():
        return Option[str].none
    let lp = lines.get(line - 1) else:
        return Option[str].none
    return Option[str].some(value = unsafe: read(lp))


function find_from(text: str, needle: str, from: ptr_uint) -> Option[ptr_uint]:
    if needle.len == 0 or from >= text.len:
        return Option[ptr_uint].none
    var i = from
    while i + needle.len <= text.len:
        if text.starts_with_at(i, needle):
            return Option[ptr_uint].some(value = i)
        i += 1
    return Option[ptr_uint].none


function platform_drift_anchor(file: ast.SourceFile, sites: ref[map_mod.Map[str, Anchor]], extra: ref[vec.Vec[str]]) -> Anchor:
    var i: ptr_uint = 0
    while i < extra.len():
        let ep = extra.get(i) else:
            break
        let entry = unsafe: read(ep)
        i += 1
        let found = sites.get(entry) else:
            continue
        return unsafe: read(found)
    # The earliest exported site (line, then column).
    var best = Anchor(line = 0, column = 0, length = 1, symbol_name = "")
    var best_set = false
    var keys = map_keys(sites)
    defer: keys.release()
    i = 0
    unsafe:
        while i < keys.len():
            let kp = keys.get(i) else:
                break
            let key = read(kp)
            i += 1
            let sp = sites.get(key) else:
                continue
            let site = read(sp)
            if not best_set or site.line < best.line or (site.line == best.line and site.column < best.column):
                best = site
                best_set = true
    if best_set:
        return best
    # The first declaration that carries a line.
    let decl_anchor = first_declaration_anchor(file)
    match decl_anchor:
        Option.some as a:
            return a.value
        Option.none:
            pass
    return Anchor(line = 1, column = 1, length = 1, symbol_name = "")


function first_declaration_anchor(file: ast.SourceFile) -> Option[Anchor]:
    var i: ptr_uint = 0
    unsafe:
        while i < file.declarations.len:
            let decl = read(file.declarations.data + i)
            i += 1
            match decl:
                ast.Decl.decl_const as d:
                    if d.line > 0:
                        return Option[Anchor].some(value = Anchor(line = d.line, column = if d.column > 0: d.column else: 1, length = d.name.len, symbol_name = d.name))
                ast.Decl.decl_var as d:
                    if d.line > 0:
                        return Option[Anchor].some(value = Anchor(line = d.line, column = if d.column > 0: d.column else: 1, length = d.name.len, symbol_name = d.name))
                ast.Decl.decl_function as d:
                    if d.line > 0:
                        return Option[Anchor].some(value = Anchor(line = d.line, column = if d.column > 0: d.column else: 1, length = d.name.len, symbol_name = d.name))
                ast.Decl.decl_struct as d:
                    if d.line > 0:
                        return Option[Anchor].some(value = Anchor(line = d.line, column = if d.column > 0: d.column else: 1, length = d.name.len, symbol_name = d.name))
                ast.Decl.decl_union as d:
                    if d.line > 0:
                        return Option[Anchor].some(value = Anchor(line = d.line, column = if d.column > 0: d.column else: 1, length = d.name.len, symbol_name = d.name))
                ast.Decl.decl_enum as d:
                    if d.line > 0:
                        return Option[Anchor].some(value = Anchor(line = d.line, column = if d.column > 0: d.column else: 1, length = d.name.len, symbol_name = d.name))
                ast.Decl.decl_flags as d:
                    if d.line > 0:
                        return Option[Anchor].some(value = Anchor(line = d.line, column = if d.column > 0: d.column else: 1, length = d.name.len, symbol_name = d.name))
                ast.Decl.decl_opaque as d:
                    if d.line > 0:
                        return Option[Anchor].some(value = Anchor(line = d.line, column = if d.column > 0: d.column else: 1, length = d.name.len, symbol_name = d.name))
                ast.Decl.decl_interface as d:
                    if d.line > 0:
                        return Option[Anchor].some(value = Anchor(line = d.line, column = if d.column > 0: d.column else: 1, length = d.name.len, symbol_name = d.name))
                ast.Decl.decl_variant as d:
                    if d.line > 0:
                        return Option[Anchor].some(value = Anchor(line = d.line, column = if d.column > 0: d.column else: 1, length = d.name.len, symbol_name = d.name))
                ast.Decl.decl_type_alias as d:
                    if d.line > 0:
                        return Option[Anchor].some(value = Anchor(line = d.line, column = if d.column > 0: d.column else: 1, length = d.name.len, symbol_name = d.name))
                ast.Decl.decl_event as d:
                    if d.line > 0:
                        return Option[Anchor].some(value = Anchor(line = d.line, column = if d.column > 0: d.column else: 1, length = d.name.len, symbol_name = d.name))
                _:
                    pass
    return Option[Anchor].none


function summarize_surface_entries(entries: ref[vec.Vec[str]]) -> str:
    var buf = string.String.create()
    var shown: ptr_uint = 0
    var i: ptr_uint = 0
    while i < entries.len() and shown < 2:
        let ep = entries.get(i) else:
            break
        if shown > 0:
            buf.append(", ")
        buf.append("'")
        buf.append(unsafe: read(ep))
        buf.append("'")
        shown += 1
        i += 1
    if entries.len() > shown:
        buf.append(" (+")
        buf.append(uint_to_dec(entries.len() - shown))
        buf.append(" more)")
    return buf.as_str()


# =============================================================================
#  Small helpers
# =============================================================================

function split_lines(source: str) -> vec.Vec[str]:
    var lines = vec.Vec[str].create()
    var start: ptr_uint = 0
    var i: ptr_uint = 0
    while i <= source.len:
        if i == source.len or source.byte_at(i) == 10:
            lines.push(source.slice(start, i - start))
            start = i + 1
        i += 1
    return lines


function map_keys(map: ref[map_mod.Map[str, Anchor]]) -> vec.Vec[str]:
    var keys = vec.Vec[str].create()
    let mut = unsafe: read(map)
    var it = mut.keys()
    while true:
        let kp = it.next() else:
            break
        keys.push(unsafe: read(kp))
    return keys


function keys_difference(a: ref[vec.Vec[str]], b: ref[vec.Vec[str]]) -> vec.Vec[str]:
    var result = vec.Vec[str].create()
    var i: ptr_uint = 0
    while i < a.len():
        let ap = a.get(i) else:
            break
        let key = unsafe: read(ap)
        i += 1
        var found = false
        var j: ptr_uint = 0
        while j < b.len():
            let bp = b.get(j) else:
                break
            if unsafe: read(bp).equal(key):
                found = true
                break
            j += 1
        if not found:
            result.push(key)
    return result


function sort_strings(items: ref[vec.Vec[str]]) -> void:
    var i: ptr_uint = 1
    while i < items.len():
        let ip = items.get(i) else:
            break
        let value = unsafe: read(ip)
        var j = i
        while j > 0:
            let jp = items.get(j - 1) else:
                break
            let prev = unsafe: read(jp)
            if prev.compare(value) <= 0:
                break
            let cur = items.get(j) else:
                break
            unsafe:
                read(cur) = prev
            j -= 1
        let slot = items.get(j) else:
            break
        unsafe:
            read(slot) = value
        i += 1


function sites_release(sites: ref[map_mod.Map[str, Anchor]]) -> void:
    unsafe: read(sites).release()


function int_to_dec(value: int) -> str:
    if value == 0:
        return "0"
    var negative = value < 0
    var magnitude: long = if value < 0: -long<-value else: long<-value
    var buf = string.String.create()
    while magnitude > 0:
        buf.push_byte(ubyte<-(48 + (magnitude % 10)))
        magnitude = magnitude / 10
    if negative:
        buf.push_byte(45)
    var reversed = string.String.create()
    var i = buf.as_str().len
    while i > 0:
        reversed.push_byte(buf.as_str().byte_at(i - 1))
        i -= 1
    return reversed.as_str()


function uint_to_dec(value: ptr_uint) -> str:
    return int_to_dec(int<-value)
