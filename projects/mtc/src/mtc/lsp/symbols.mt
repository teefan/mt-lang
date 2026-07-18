## Document symbols — extract top-level symbol definitions from a parsed
## source file and return them as LSP DocumentSymbol JSON.

import std.fs as fs_mod
import std.json as json
import std.string as string
import std.vec as vec

import mtc.parser.ast as ast
import mtc.parser.parser as parser
import mtc.parser.state as pstate
import mtc.lsp.uri as uri_ops
import mtc.lsp.protocol as proto


const SYMBOLKIND_FUNCTION:  double = 12.0
const SYMBOLKIND_STRUCT:    double = 23.0
const SYMBOLKIND_ENUM:      double = 10.0
const SYMBOLKIND_VARIABLE:  double = 13.0
const SYMBOLKIND_CONST:     double = 14.0
const SYMBOLKIND_INTERFACE: double = 11.0
const SYMBOLKIND_EVENT:     double = 24.0
const SYMBOLKIND_TYPEPARAM: double = 25.0


public function handle_document_symbols(uri: str, id: json.Value) -> void:
    var owned_path = uri_ops.file_uri_to_path(uri) else:
        proto.write_error(id, -32602, "invalid uri")
        return
    defer owned_path.release()

    var content = string.String.create()
    defer content.release()
    var read_result = fs_mod.read_text(owned_path.as_str())
    match read_result:
        Result.success as c:
            content.assign(c.value.as_str())
        Result.failure:
            proto.write_error(id, -32800, "symbol request failed: could not read file")
            return

    let source = content.as_str()
    if source.len == 0:
        proto.write_error(id, -32800, "symbol request failed: empty file")
        return

    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer parse_diags.release()
    var ast_file = parser.parse_source(source, ref_of(parse_diags))
    if parse_diags.len() > 0:
        proto.write_error(id, -32800, "symbol request failed: parse error")
        return

    var symbols = collect_declaration_symbols_from_file(ast_file)
    var result = json.create_array_value()
    var result_ptr = result.as_array()
    if result_ptr == null:
        release_symbol_vec(ref_of(symbols))
        proto.write_error(id, -32603, "internal error")
        return

    var si: ptr_uint = 0
    while si < symbols.len():
        let sym_ptr = symbols.get(si) else:
            break
        unsafe:
            read(result_ptr).push(read(sym_ptr))
        si += 1

    symbols.release()
    proto.write_response(id, result)


function collect_declaration_symbols_from_file(file: ast.SourceFile) -> vec.Vec[json.Value]:
    var symbols = vec.Vec[json.Value].create()

    var di: ptr_uint = 0
    while di < file.declarations.len:
        var decl: ast.Decl
        unsafe:
            decl = read(file.declarations.data + di)
        match decl:
            ast.Decl.decl_function as fun:
                var sym = build_symbol(fun.name, SYMBOLKIND_FUNCTION, fun.line)
                symbols.push(sym)
            ast.Decl.decl_struct as s:
                var children = vec.Vec[json.Value].create()
                collect_fields(ref_of(children), s.struct_fields)
                var sym = build_symbol_with_children(s.name, SYMBOLKIND_STRUCT, s.line, ref_of(children))
                symbols.push(sym)
            ast.Decl.decl_enum as e:
                var children = vec.Vec[json.Value].create()
                collect_enums(ref_of(children), e.enum_members)
                var sym = build_symbol_with_children(e.name, SYMBOLKIND_ENUM, e.line, ref_of(children))
                symbols.push(sym)
            ast.Decl.decl_flags as fl:
                var children = vec.Vec[json.Value].create()
                collect_enums(ref_of(children), fl.flags_members)
                var sym = build_symbol_with_children(fl.name, SYMBOLKIND_ENUM, fl.line, ref_of(children))
                symbols.push(sym)
            ast.Decl.decl_const as c:
                var sym = build_symbol(c.name, SYMBOLKIND_CONST, c.line)
                symbols.push(sym)
            ast.Decl.decl_var as v:
                var sym = build_symbol(v.name, SYMBOLKIND_VARIABLE, v.line)
                symbols.push(sym)
            ast.Decl.decl_interface as iface:
                var children = vec.Vec[json.Value].create()
                collect_iface_methods(ref_of(children), iface.interface_methods)
                var sym = build_symbol_with_children(iface.name, SYMBOLKIND_INTERFACE, iface.line, ref_of(children))
                symbols.push(sym)
            ast.Decl.decl_event as ev:
                var sym = build_symbol(ev.name, SYMBOLKIND_EVENT, ev.line)
                symbols.push(sym)
            ast.Decl.decl_variant as vr:
                var children = vec.Vec[json.Value].create()
                collect_variant_arms(ref_of(children), vr.variant_arms)
                var sym = build_symbol_with_children(vr.name, SYMBOLKIND_STRUCT, vr.line, ref_of(children))
                symbols.push(sym)
            ast.Decl.decl_type_alias as ta:
                var sym = build_symbol(ta.name, SYMBOLKIND_TYPEPARAM, ta.line)
                symbols.push(sym)
            ast.Decl.decl_union as u:
                var children = vec.Vec[json.Value].create()
                collect_fields(ref_of(children), u.union_fields)
                var sym = build_symbol_with_children(u.name, SYMBOLKIND_STRUCT, u.line, ref_of(children))
                symbols.push(sym)
            ast.Decl.decl_opaque as op:
                var sym = build_symbol(op.name, SYMBOLKIND_STRUCT, op.line)
                symbols.push(sym)
            _:
                pass
        di += 1

    return symbols


function build_symbol(name: str, kind: double, line: ptr_uint) -> json.Value:
    var result = json.create_object_value()
    var obj_ptr = result.as_object()
    if obj_ptr == null:
        return json.null_value()
    var range = make_range(line)
    var sel = make_range(line)
    unsafe:
        read(obj_ptr).set("name", json.string_from_str(name))
        read(obj_ptr).set("kind", json.number_value(kind))
        read(obj_ptr).set("range", range)
        read(obj_ptr).set("selectionRange", sel)
    return result


function build_symbol_with_children(name: str, kind: double, line: ptr_uint, children: ref[vec.Vec[json.Value]]) -> json.Value:
    var result = build_symbol(name, kind, line)
    var obj_ptr = result.as_object()
    if obj_ptr == null:
        release_symbol_vec(children)
        return json.null_value()
    var child_array = json.create_array_value()
    var arr_ptr = child_array.as_array()
    if arr_ptr != null:
        var i: ptr_uint = 0
        while i < children.len():
            let cp = children.get(i) else:
                break
            unsafe:
                read(arr_ptr).push(read(cp))
            i += 1
    children.release()
    unsafe:
        read(obj_ptr).set("children", child_array)
    return result


function release_symbol_vec(symbols: ref[vec.Vec[json.Value]]) -> void:
    var i: ptr_uint = 0
    while i < symbols.len():
        let sp = symbols.get(i) else:
            break
        json.release_value(unsafe: read(sp))
        i += 1
    symbols.release()


function make_range(line: ptr_uint) -> json.Value:
    var range = json.create_object_value()
    var start = json.create_object_value()
    var end = json.create_object_value()
    let line_zero = if line > 0: ptr_uint<-(int<-(line) - 1) else: 0z
    var so_ptr = start.as_object()
    var eo_ptr = end.as_object()
    var r_ptr = range.as_object()
    if so_ptr == null or eo_ptr == null or r_ptr == null:
        return range
    unsafe:
        read(so_ptr).set("line", json.number_value(double<-line_zero))
        read(so_ptr).set("character", json.number_value(0.0))
        read(eo_ptr).set("line", json.number_value(double<-line_zero))
        read(eo_ptr).set("character", json.number_value(0.0))
        read(r_ptr).set("start", start)
        read(r_ptr).set("end", end)
    return range


function collect_fields(children: ref[vec.Vec[json.Value]], fields: span[ast.Field]) -> void:
    var fi: ptr_uint = 0
    while fi < fields.len:
        var field: ast.Field
        unsafe:
            field = read(fields.data + fi)
        var sym = build_symbol(field.name, SYMBOLKIND_VARIABLE, 0)
        unsafe:
            children.push(sym)
        fi += 1


function collect_enums(children: ref[vec.Vec[json.Value]], members: span[ast.EnumMember]) -> void:
    var mi: ptr_uint = 0
    while mi < members.len:
        var mem: ast.EnumMember
        unsafe:
            mem = read(members.data + mi)
        var sym = build_symbol(mem.name, SYMBOLKIND_ENUM, 0)
        unsafe:
            children.push(sym)
        mi += 1


function collect_iface_methods(children: ref[vec.Vec[json.Value]], methods: span[ast.InterfaceMethod]) -> void:
    var mi: ptr_uint = 0
    while mi < methods.len:
        var m: ast.InterfaceMethod
        unsafe:
            m = read(methods.data + mi)
        var sym = build_symbol(m.name, SYMBOLKIND_FUNCTION, 0)
        unsafe:
            children.push(sym)
        mi += 1


function collect_variant_arms(children: ref[vec.Vec[json.Value]], arms: span[ast.VariantArm]) -> void:
    var ai: ptr_uint = 0
    while ai < arms.len:
        var arm: ast.VariantArm
        unsafe:
            arm = read(arms.data + ai)
        var sym = build_symbol(arm.name, SYMBOLKIND_ENUM, 0)
        unsafe:
            children.push(sym)
        ai += 1
