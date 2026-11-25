## Emitter — generates the .mt external module source from the selected
## declarations.  Extracted from bindgen.mt.

import std.str
import std.string as string
import std.vec as vec
import std.json as json
import std.path as path_ops

import mtc.bindgen as bindgen


function aggregate_explicit_c_name(name: str, node: ptr[json.Object]) -> str:
    let linkage = bindgen.record_c_name(node)
    if linkage == "" or linkage.equal(name):
        return ""
    return linkage


function emit_aggregate_fields(
    buf: ref[string.String],
    node: ptr[json.Object],
    owner_name: str,
    opts: ref[bindgen.BindgenOptions]
) -> void:
    let state = bindgen.bindgen_state_ptr() else:
        return
    unsafe:
        let children = bindgen.jget_inner(node)
        if children == null:
            return
        var i: ptr_uint = 0
        while true:
            let entry = read(children).get(i) else:
                break
            let field = read(entry).as_object()
            if field != null and bindgen.jget_str(field, "kind").equal("FieldDecl"):
                let anonymous_record = bindgen.anonymous_record_decl_for_field(field, node)
                if anonymous_record != null and bindgen.field_unnamed(field):
                    emit_flattened_anonymous(buf, bindgen.node_non_null(anonymous_record), owner_name, opts)
                else:
                    bindgen.set_bindgen_map_failed(false)
                    var field_type = bindgen.aggregate_field_type(field, owner_name, node, opts)
                    defer: field_type.release()
                    if not bindgen.bindgen_map_failed_flag():
                        let field_name = bindgen.emitted_name(bindgen.aggregate_field_name(field, node), opts)
                        buf.append("    ")
                        buf.append(field_name)
                        buf.append(": ")
                        buf.append(field_type.as_str())
                        buf.append("\n")
            i += 1


function emit_flattened_anonymous(
    buf: ref[string.String],
    record: ptr[json.Object],
    owner_name: str,
    opts: ref[bindgen.BindgenOptions]
) -> void:
    unsafe:
        let children = bindgen.jget_inner(record)
        if children == null:
            return
        var i: ptr_uint = 0
        while true:
            let entry = read(children).get(i) else:
                break
            let field = read(entry).as_object()
            if field != null and bindgen.jget_str(field, "kind").equal("FieldDecl"):
                let anonymous_record = bindgen.anonymous_record_decl_for_field(field, record)
                if anonymous_record != null and bindgen.field_unnamed(field):
                    emit_flattened_anonymous(buf, bindgen.node_non_null(anonymous_record), owner_name, opts)
                else:
                    bindgen.set_bindgen_map_failed(false)
                    var field_type = bindgen.aggregate_field_type(field, owner_name, record, opts)
                    defer: field_type.release()
                    if not bindgen.bindgen_map_failed_flag():
                        let field_name = bindgen.emitted_name(bindgen.jget_str(field, "name"), opts)
                        buf.append("    ")
                        buf.append(field_name)
                        buf.append(": ")
                        buf.append(field_type.as_str())
                        buf.append("\n")
            i += 1


function emit_aggregate_decl(
    buf: ref[string.String],
    kind_text: str,
    name: str,
    node: ptr[json.Object],
    opts: ref[bindgen.BindgenOptions]
) -> void:
    let state = bindgen.bindgen_state_ptr() else:
        return
    buf.append(kind_text)
    buf.append(" ")
    buf.append(bindgen.emitted_name(name, opts))
    let explicit_c_name = aggregate_explicit_c_name(name, node)
    if explicit_c_name != "":
        buf.append(" = c\"")
        buf.append(explicit_c_name)
        buf.append("\"")
    buf.append(":\n")
    emit_aggregate_fields(buf, node, name, opts)


function emit_synthetic(
    buf: ref[string.String],
    synthetic_decl: bindgen.SyntheticDecl,
    opts: ref[bindgen.BindgenOptions]
) -> void:
    let kind_text = synthetic_decl.kind.as_str()
    if kind_text.equal("opaque"):
        buf.append("opaque ")
        buf.append(bindgen.emitted_name(synthetic_decl.name.as_str(), opts))
        if synthetic_decl.linkage.as_str().len > 0:
            buf.append(" = c\"")
            buf.append(synthetic_decl.linkage.as_str())
            buf.append("\"")
        buf.append("\n")
        return
    emit_aggregate_decl(buf, kind_text, synthetic_decl.name.as_str(), bindgen.node_non_null(synthetic_decl.node), opts)


function emit_decl(buf: ref[string.String], d: bindgen.CDecl, opts: ref[bindgen.BindgenOptions]) -> void:
    let k = d.kind.as_str()
    let name = d.mt_name.as_str()

    if k == "opaque":
        buf.append("opaque ")
        buf.append(bindgen.emitted_name(name, opts))
        if d.linkage.as_str().len > 0:
            buf.append(" = c\"")
            buf.append(d.linkage.as_str())
            buf.append("\"")
        buf.append("\n")
        return

    if k == "struct" or k == "union":
        if d.node == null:
            return
        emit_aggregate_decl(buf, k, name, bindgen.node_non_null(d.node), opts)
        return

    if k == "enum" or k == "flags":
        buf.append(k)
        buf.append(" ")
        buf.append(bindgen.emitted_name(name, opts))
        buf.append(": ")
        var backing: string.String
        if d.qual_type.as_str().len == 0:
            backing = string.String.from_str("int")
        else:
            bindgen.set_bindgen_map_failed(false)
            backing = bindgen.map_type(d.qual_type.as_str(), opts)
            if bindgen.bindgen_map_failed_flag():
                backing.release()
                backing = string.String.from_str("int")
        defer: backing.release()
        buf.append(backing.as_str())
        buf.append("\n")
        var mi: ptr_uint = 0
        while mi < d.members.len():
            let mp = d.members.get(mi) else:
                break
            unsafe:
                buf.append("    ")
                buf.append(read(mp).ename)
                buf.append(" = ")
                buf.append(read(mp).evalue.as_str())
                buf.append("\n")
            mi += 1
        return

    if k == "type_alias":
        buf.append("type ")
        buf.append(bindgen.emitted_name(name, opts))
        buf.append(" = ")
        buf.append(d.qual_type.as_str())
        buf.append("\n")
        return

    if k == "const":
        buf.append("const ")
        buf.append(bindgen.emitted_name(name, opts))
        buf.append(": ")
        buf.append(d.qual_type.as_str())
        if d.value_text.as_str().len > 0:
            buf.append(" = ")
            buf.append(d.value_text.as_str())
        buf.append("\n")
        return

    if k == "function":
        let original_name = d.c_name.as_str()
        let stripped_name = bindgen.emitted_name(original_name, opts)
        buf.append("external function ")
        buf.append(stripped_name)
        buf.append("(")
        var an: ptr_uint = 0
        while an < d.param_names.len():
            if an > 0:
                buf.append(", ")
            let pn = d.param_names.get(an) else:
                break
            let pt = d.param_types.get(an) else:
                break
            unsafe:
                buf.append(read(pn).as_str())
                buf.append(": ")
                buf.append(read(pt).as_str())
            an += 1
        if d.is_variadic:
            if d.param_names.len() > 0:
                buf.append(", ")
            buf.append("...")
        buf.append(") -> ")
        buf.append(d.return_type.as_str())
        if not stripped_name.equal(original_name):
            buf.append(" = c\"")
            buf.append(original_name)
            buf.append("\"")
        buf.append("\n")
        return

## A stable index sort for declarations (the host's `sort_by { index }`).

function sort_declaration_order(decls: vec.Vec[bindgen.CDecl]) -> vec.Vec[ptr_uint]:
    var order = vec.Vec[ptr_uint].create()
    var i: ptr_uint = 0
    while i < decls.len():
        order.push(i)
        i += 1
    var current: ptr_uint = 1
    while current < order.len():
        let value_ptr = order.get(current) else:
            break
        let value = unsafe: read(value_ptr)
        let value_decl_ptr = decls.get(value) else:
            break
        let index = unsafe: read(value_decl_ptr).index
        var position = current
        while position > 0:
            let previous_ptr = order.get(position - 1) else:
                break
            let previous = unsafe: read(previous_ptr)
            let previous_decl_ptr = decls.get(previous) else:
                break
            if unsafe: read(previous_decl_ptr).index <= index:
                break
            let slot = order.get(position) else:
                break
            unsafe: read(slot) = previous
            position -= 1
        let final_slot = order.get(position) else:
            break
        unsafe: read(final_slot) = value
        current += 1
    return order


public function emit_module(
    decls: vec.Vec[bindgen.CDecl],
    header_path: str,
    link_libs: vec.Vec[str],
    incs: vec.Vec[str],
    opts: ref[bindgen.BindgenOptions]
) -> string.String:
    var buf = string.String.create()
    buf.append("# generated by mtc bindgen from ")
    buf.append(header_path)
    buf.append("\nexternal\n\n")

    var mi: ptr_uint = 0
    while mi < opts.module_imports.len():
        let imp = opts.module_imports.get(mi) else:
            break
        unsafe:
            let m = read(imp)
            buf.append("import ")
            buf.append(m.module_name)
            buf.append(" as ")
            buf.append(m.alias)
            buf.append("\n")
        mi += 1

    var i: ptr_uint = 0
    while i < link_libs.len():
        let l = link_libs.get(i) else:
            break
        buf.append("link \"")
        unsafe: buf.append(read(l))
        buf.append("\"\n")
        i += 1
    if incs.len() == 0:
        buf.append("include \"")
        buf.append(path_ops.basename(header_path))
        buf.append("\"\n")
    i = 0
    while i < incs.len():
        let inc = incs.get(i) else:
            break
        buf.append("include \"")
        unsafe: buf.append(read(inc))
        buf.append("\"\n")
        i += 1

    let state = bindgen.bindgen_state_ptr() else:
        return buf
    var si: ptr_uint = 0
    while si < unsafe: read(state).synthetics.len():
        let entry = unsafe: read(state).synthetics.get(si) else:
            break
        si += 1
        let synthetic_decl = unsafe: read(entry)
        var already = false
        var di: ptr_uint = 0
        while di < decls.len():
            let dp = decls.get(di) else:
                break
            if unsafe: read(dp).mt_name.as_str().equal(synthetic_decl.name.as_str()):
                already = true
                break
            di += 1
        if already:
            continue
        emit_synthetic(ref_of(buf), synthetic_decl, opts)

    var order = sort_declaration_order(decls)
    defer: order.release()
    var oi: ptr_uint = 0
    while oi < order.len():
        let position = order.get(oi) else:
            break
        let dp = decls.get(unsafe: read(position)) else:
            break
        emit_decl(ref_of(buf), unsafe: read(dp), opts)
        oi += 1
    return buf
