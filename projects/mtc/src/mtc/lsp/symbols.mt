## Document symbols — extract top-level symbol definitions from a parsed
## source file and return them as LSP DocumentSymbol JSON.

import std.fmt
import std.json as json
import std.str
import std.string as string
import std.vec as vec

import mtc.parser.ast as ast
import mtc.parser.parser as parser
import mtc.parser.state as pstate
import mtc.lsp.uri as uri_ops
import mtc.lsp.protocol as proto
import mtc.lsp.workspace as workspace


const SYMBOLKIND_FUNCTION:  double = 12.0
const SYMBOLKIND_STRUCT:    double = 23.0
const SYMBOLKIND_ENUM:      double = 10.0
const SYMBOLKIND_VARIABLE:  double = 13.0
const SYMBOLKIND_CONST:     double = 14.0
const SYMBOLKIND_INTERFACE: double = 11.0
const SYMBOLKIND_EVENT:     double = 24.0
const SYMBOLKIND_TYPEPARAM: double = 25.0


public function handle_document_symbols(ws: ref[workspace.Workspace], uri: str, id: json.Value) -> void:
    var owned_path = uri_ops.file_uri_to_path(uri) else:
        proto.write_error(id, -32602, "invalid uri")
        return
    defer owned_path.release()

    var content = ws.document_source(owned_path.as_str()) else:
        proto.write_error(id, -32800, "symbol request failed: could not read file")
        return
    defer content.release()

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

    var json_text = string.String.create()
    defer json_text.release()
    json_text.append("[")
    var first = true
    var si: ptr_uint = 0
    while si < symbols.len():
        let sym_ptr = symbols.get(si) else:
            break
        if not first:
            json_text.append(",")
        first = false
        json_text.append(unsafe: read(sym_ptr).as_str())
        si += 1
    json_text.append("]")
    symbols.release()
    proto.write_response_raw(id, json_text.as_str())


function collect_declaration_symbols_from_file(file: ast.SourceFile) -> vec.Vec[string.String]:
    var symbols = vec.Vec[string.String].create()

    var di: ptr_uint = 0
    while di < file.declarations.len:
        var decl: ast.Decl
        unsafe:
            decl = read(file.declarations.data + di)
        match decl:
            ast.Decl.decl_function as fun:
                var sym = build_symbol_string(fun.name, SYMBOLKIND_FUNCTION, fun.line)
                symbols.push(sym)
            ast.Decl.decl_struct as s:
                var children = vec.Vec[string.String].create()
                collect_field_children(ref_of(children), s.struct_fields)
                var sym = build_symbol_string_with_children(s.name, SYMBOLKIND_STRUCT, s.line, ref_of(children))
                symbols.push(sym)
            ast.Decl.decl_enum as e:
                var children = vec.Vec[string.String].create()
                collect_enum_children(ref_of(children), e.enum_members)
                var sym = build_symbol_string_with_children(e.name, SYMBOLKIND_ENUM, e.line, ref_of(children))
                symbols.push(sym)
            ast.Decl.decl_flags as fl:
                var children = vec.Vec[string.String].create()
                collect_enum_children(ref_of(children), fl.flags_members)
                var sym = build_symbol_string_with_children(fl.name, SYMBOLKIND_ENUM, fl.line, ref_of(children))
                symbols.push(sym)
            ast.Decl.decl_const as c:
                var sym = build_symbol_string(c.name, SYMBOLKIND_CONST, c.line)
                symbols.push(sym)
            ast.Decl.decl_var as v:
                var sym = build_symbol_string(v.name, SYMBOLKIND_VARIABLE, v.line)
                symbols.push(sym)
            ast.Decl.decl_interface as iface:
                var children = vec.Vec[string.String].create()
                collect_interface_children(ref_of(children), iface.interface_methods)
                var sym = build_symbol_string_with_children(iface.name, SYMBOLKIND_INTERFACE, iface.line, ref_of(children))
                symbols.push(sym)
            ast.Decl.decl_event as ev:
                var sym = build_symbol_string(ev.name, SYMBOLKIND_EVENT, ev.line)
                symbols.push(sym)
            ast.Decl.decl_variant as vr:
                var children = vec.Vec[string.String].create()
                collect_variant_children(ref_of(children), vr.variant_arms)
                var sym = build_symbol_string_with_children(vr.name, SYMBOLKIND_STRUCT, vr.line, ref_of(children))
                symbols.push(sym)
            ast.Decl.decl_type_alias as ta:
                var sym = build_symbol_string(ta.name, SYMBOLKIND_TYPEPARAM, ta.line)
                symbols.push(sym)
            ast.Decl.decl_union as u:
                var children = vec.Vec[string.String].create()
                collect_field_children(ref_of(children), u.union_fields)
                var sym = build_symbol_string_with_children(u.name, SYMBOLKIND_STRUCT, u.line, ref_of(children))
                symbols.push(sym)
            ast.Decl.decl_opaque as op:
                var sym = build_symbol_string(op.name, SYMBOLKIND_STRUCT, op.line)
                symbols.push(sym)
            _:
                pass
        di += 1

    return symbols


function build_symbol_string(name: str, kind: double, line: ptr_uint) -> string.String:
    var result = string.String.create()
    let lz = if line > 0: ptr_uint<-(int<-(line) - 1) else: 0z
    result.append("{\"name\":\"")
    append_json_escape(ref_of(result), name)
    result.append("\",\"kind\":")
    result.append_format(f"#{kind}")
    result.append(",\"range\":")
    append_range_json(ref_of(result), lz)
    result.append(",\"selectionRange\":")
    append_range_json(ref_of(result), lz)
    result.append("}")
    return result


function build_symbol_string_with_children(name: str, kind: double, line: ptr_uint, children: ref[vec.Vec[string.String]]) -> string.String:
    var result = string.String.create()
    let lz = if line > 0: ptr_uint<-(int<-(line) - 1) else: 0z
    result.append("{\"name\":\"")
    append_json_escape(ref_of(result), name)
    result.append("\",\"kind\":")
    result.append_format(f"#{kind}")
    result.append(",\"range\":")
    append_range_json(ref_of(result), lz)
    result.append(",\"selectionRange\":")
    append_range_json(ref_of(result), lz)
    result.append(",\"children\":[")
    var first = true
    var ci: ptr_uint = 0
    while ci < children.len():
        let cp = children.get(ci) else:
            break
        if not first:
            result.append(",")
        first = false
        result.append(unsafe: read(cp).as_str())
        ci += 1
    result.append("]}")
    release_symbol_strings(children)
    return result


function append_range_json(output: ref[string.String], line_zero: ptr_uint) -> void:
    output.append("{\"start\":{\"line\":")
    output.append_format(f"#{line_zero}")
    output.append(",\"character\":0},\"end\":{\"line\":")
    output.append_format(f"#{line_zero}")
    output.append(",\"character\":0}}")


function append_json_escape(output: ref[string.String], text: str) -> void:
    var i: ptr_uint = 0
    while i < text.len:
        let b = text.byte_at(i)
        if b == 34: output.append("\\\"") else if b == 92: output.append("\\\\") else: output.push_byte(b)
        i += 1


function release_symbol_strings(symbols: ref[vec.Vec[string.String]]) -> void:
    var i: ptr_uint = 0
    while i < symbols.len():
        let sp = symbols.get(i) else:
            break
        unsafe:
            read(sp).release()
        i += 1
    symbols.release()


function collect_field_children(children: ref[vec.Vec[string.String]], fields: span[ast.Field]) -> void:
    var fi: ptr_uint = 0
    while fi < fields.len:
        var field: ast.Field
        unsafe:
            field = read(fields.data + fi)
        var sym = build_symbol_string(field.name, SYMBOLKIND_VARIABLE, 0)
        unsafe:
            children.push(sym)
        fi += 1


function collect_enum_children(children: ref[vec.Vec[string.String]], members: span[ast.EnumMember]) -> void:
    var mi: ptr_uint = 0
    while mi < members.len:
        var mem: ast.EnumMember
        unsafe:
            mem = read(members.data + mi)
        var sym = build_symbol_string(mem.name, SYMBOLKIND_ENUM, 0)
        unsafe:
            children.push(sym)
        mi += 1


function collect_interface_children(children: ref[vec.Vec[string.String]], methods: span[ast.InterfaceMethod]) -> void:
    var mi: ptr_uint = 0
    while mi < methods.len:
        var m: ast.InterfaceMethod
        unsafe:
            m = read(methods.data + mi)
        var sym = build_symbol_string(m.name, SYMBOLKIND_FUNCTION, 0)
        unsafe:
            children.push(sym)
        mi += 1


function collect_variant_children(children: ref[vec.Vec[string.String]], arms: span[ast.VariantArm]) -> void:
    var ai: ptr_uint = 0
    while ai < arms.len:
        var arm: ast.VariantArm
        unsafe:
            arm = read(arms.data + ai)
        var sym = build_symbol_string(arm.name, SYMBOLKIND_ENUM, 0)
        unsafe:
            children.push(sym)
        ai += 1
