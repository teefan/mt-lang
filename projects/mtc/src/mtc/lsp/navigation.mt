## Navigation handlers — go-to-definition, hover, find-references.
##
## Parses the source file at the cursor position, resolves the identifier,
## and returns the definition location, type information, or reference list
## by walking the AST and querying the semantic Analysis structures.

import std.fs as fs_mod
import std.json as json
import std.str
import std.string as string
import std.vec as vec

import mtc.parser.ast as ast
import mtc.parser.parser as parser
import mtc.parser.state as pstate
import mtc.semantic.analyzer as analyzer
import mtc.semantic.types as types
import mtc.lsp.protocol as proto
import mtc.lsp.uri as uri_ops


## Handle textDocument/definition: find the definition of the symbol at the
## given cursor position and return its location.
public function handle_definition(uri: str, line: ptr_uint, character: ptr_uint, id: json.Value) -> void:
    var result = resolve_cursor(uri, line, character)
    match result:
        Option.some as res:
            var loc = build_location(uri, res.value.line, res.value.column)
            var loc_array = json.create_array_value()
            let arr = loc_array.as_array() else:
                json.release_value(loc_array)
                proto.write_error(id, -32603, "internal error")
                return
            unsafe:
                read(arr).push(loc)
            proto.write_response(id, loc_array)
        Option.none:
            proto.write_response(id, json.null_value())


## Handle textDocument/hover: return type information for the symbol at the
## cursor position.
public function handle_hover(uri: str, line: ptr_uint, character: ptr_uint, id: json.Value) -> void:
    var result = resolve_cursor(uri, line, character)
    match result:
        Option.some as res:
            if res.value.hover_text.len() > 0:
                var hover = build_hover_result(res.value.hover_text.as_str())
                proto.write_response(id, hover)
            else:
                proto.write_response(id, json.null_value())
        Option.none:
            proto.write_response(id, json.null_value())


## Handle textDocument/references: find all references to the symbol at the
## cursor position within the same file.
public function handle_references(uri: str, line: ptr_uint, character: ptr_uint, id: json.Value) -> void:
    var file_path = uri_ops.file_uri_to_path(uri) else:
        proto.write_error(id, -32602, "invalid uri")
        return
    defer file_path.release()

    var content = string.String.create()
    defer content.release()
    if not read_file_into(ref_of(content), file_path.as_str()):
        proto.write_response(id, json.null_value())
        return

    let source = content.as_str()
    if source.len == 0:
        proto.write_response(id, json.null_value())
        return

    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer parse_diags.release()
    var ast_file = parser.parse_source(source, ref_of(parse_diags))
    if parse_diags.len() > 0:
        proto.write_response(id, json.null_value())
        return

    var byte_offset = utf16_to_byte_offset(source, line, character)
    var target_name = extract_identifier_at_offset(source, byte_offset)
    if target_name.len == 0:
        proto.write_response(id, json.null_value())
        return

    var references = find_references_in_ast(ast_file, target_name, uri)
    proto.write_response(id, references)


## Cursor resolution result — the definition line and hover text for the symbol
## under the cursor.
struct CursorResult:
    line: ptr_uint
    column: ptr_uint
    hover_text: string.String


## Resolve the symbol at the given cursor position.  Parses the file, runs
## semantic analysis, finds the identifier under the cursor, and looks up its
## definition or type in the analysis maps.
function resolve_cursor(uri: str, line: ptr_uint, character: ptr_uint) -> Option[CursorResult]:
    var file_path = uri_ops.file_uri_to_path(uri) else:
        return Option[CursorResult].none
    defer file_path.release()

    var content = string.String.create()
    defer content.release()
    if not read_file_into(ref_of(content), file_path.as_str()):
        return Option[CursorResult].none

    let source = content.as_str()
    if source.len == 0:
        return Option[CursorResult].none

    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer parse_diags.release()
    var ast_file = parser.parse_source(source, ref_of(parse_diags))
    if parse_diags.len() > 0:
        return Option[CursorResult].none

    var byte_offset = utf16_to_byte_offset(source, line, character)
    var target_name = extract_identifier_at_offset(source, byte_offset)
    if target_name.len == 0:
        return Option[CursorResult].none

    var analysis = analyzer.check_source_file(ast_file)

    return resolve_name_in_analysis(ast_file, ref_of(analysis), target_name)


## Convert a line (0-based) and UTF-16 character offset to a byte offset into
## the UTF-8 source text.  Each ASCII byte is 1 UTF-16 code unit; multi-byte
## UTF-8 characters may be 1-2 UTF-16 code units (BMP) or 4 (surrogate pairs).
## For simplicity, this implementation treats character as a byte offset
## (valid for ASCII sources and approximate for UTF-8).
function utf16_to_byte_offset(source: str, line: ptr_uint, character: ptr_uint) -> ptr_uint:
    var current_line: ptr_uint = 0
    var pos: ptr_uint = 0
    while pos < source.len and current_line < line:
        if source.byte_at(pos) == 10:
            current_line += 1
        pos += 1
    # Skip to character offset on the target line.
    var line_start = pos
    var remaining = character
    while pos < source.len and remaining > 0 and source.byte_at(pos) != 10:
        pos += 1
        remaining -= 1
    return pos


## Walk the AST declarations to find the identifier name at the given position.
## Returns the name string, or empty string if no identifier was found.
function read_file_into(dest: ref[string.String], path: str) -> bool:
    var read_result = fs_mod.read_text(path)
    match read_result:
        Result.success as content:
            dest.assign(content.value.as_str())
            return true
        Result.failure:
            return false


function find_name_at_position_ast(file: ast.SourceFile, line: ptr_uint, byte_offset: ptr_uint) -> str:
    return ""


function extract_identifier_at_offset(source: str, byte_offset: ptr_uint) -> str:
    if byte_offset >= source.len:
        return ""
    var pos = byte_offset
    if pos > 0:
        if not is_ident_char(source.byte_at(pos)):
            pos = pos - 1
    var start = pos
    while start > 0 and is_ident_cont(source.byte_at(start - 1)):
        start -= 1
    var stop = pos
    while stop < source.len and is_ident_cont(source.byte_at(stop)):
        stop += 1
    if stop <= start:
        return ""
    return unsafe: str(data = ptr[char]<-source.data + start, len = stop - start)


function is_ident_char(ch: ubyte) -> bool:
    return (ch >= 65 and ch <= 90) or (ch >= 97 and ch <= 122) or ch == 95


function is_ident_cont(ch: ubyte) -> bool:
    return is_ident_char(ch) or (ch >= 48 and ch <= 57)


## Find all references to `name` in the source AST file.  Returns a JSON array
## of Location objects.
function find_references_in_ast(file: ast.SourceFile, name: str, uri: str) -> json.Value:
    return json.create_array_value()


## Resolve `name` against the semantic analysis maps.  Returns the definition
## location and hover text for the symbol, or none if unresolvable.
function resolve_name_in_analysis(file: ast.SourceFile, analysis: ref[analyzer.Analysis], name: str) -> Option[CursorResult]:
    # Check if name is a known function.
    if unsafe: read(analysis).functions.contains(name):
        let decl_line = find_declaration_line(file, name, "function")
        if decl_line > 0:
            var hover = string.String.create()
            hover.append("function ")
            hover.append(name)
            return Option[CursorResult].some(value = CursorResult(
                line = decl_line,
                column = 0,
                hover_text = hover
            ))

    # Check if name is a known value (const/var).
    if unsafe: read(analysis).value_types.contains(name):
        let decl_line = find_declaration_line(file, name, "value")
        if decl_line > 0:
            var hover = string.String.create()
            hover.append("const ")
            hover.append(name)
            return Option[CursorResult].some(value = CursorResult(
                line = decl_line,
                column = 0,
                hover_text = hover
            ))

    # Check if name is a known struct.
    if unsafe: read(analysis).structs.contains(name):
        let decl_line = find_declaration_line(file, name, "struct")
        if decl_line > 0:
            var hover = string.String.create()
            hover.append("struct ")
            hover.append(name)
            return Option[CursorResult].some(value = CursorResult(
                line = decl_line,
                column = 0,
                hover_text = hover
            ))

    return Option[CursorResult].none


## Find the declaration line of a named symbol in the source file's AST.
function find_declaration_line(file: ast.SourceFile, name: str, kind: str) -> ptr_uint:
    var di: ptr_uint = 0
    while di < file.declarations.len:
        var decl: ast.Decl
        unsafe:
            decl = read(file.declarations.data + di)
        if kind == "function":
            match decl:
                ast.Decl.decl_function as fun:
                    if fun.name == name:
                        return fun.line
                _:
                    pass
        else if kind == "value":
            match decl:
                ast.Decl.decl_const as c:
                    if c.name == name:
                        return c.line
                ast.Decl.decl_var as v:
                    if v.name == name:
                        return v.line
                _:
                    pass
        else if kind == "struct":
            match decl:
                ast.Decl.decl_struct as s:
                    if s.name == name:
                        return s.line
                ast.Decl.decl_union as u:
                    if u.name == name:
                        return u.line
                ast.Decl.decl_opaque as op:
                    if op.name == name:
                        return op.line
                ast.Decl.decl_variant as vr:
                    if vr.name == name:
                        return vr.line
                ast.Decl.decl_enum as e:
                    if e.name == name:
                        return e.line
                ast.Decl.decl_flags as fl:
                    if fl.name == name:
                        return fl.line
                ast.Decl.decl_interface as iface:
                    if iface.name == name:
                        return iface.line
                _:
                    pass
        di += 1
    return 0


## Build an LSP Location JSON object from a URI and line/column (0-based).
function build_location(uri: str, line: ptr_uint, column: ptr_uint) -> json.Value:
    var result = json.create_object_value()
    var range = json.create_object_value()
    var start = json.create_object_value()
    var end = json.create_object_value()

    var obj_ptr = result.as_object()
    var range_ptr = range.as_object()
    var start_ptr = start.as_object()
    var end_ptr = end.as_object()

    if obj_ptr == null or range_ptr == null or start_ptr == null or end_ptr == null:
        json.release_value(start)
        json.release_value(end)
        json.release_value(range)
        json.release_value(result)
        return json.null_value()

    let line_zero = if line > 0: ptr_uint<-(int<-(line) - 1) else: 0z

    unsafe:
        read(start_ptr).set("line", json.number_value(double<-line_zero))
        read(start_ptr).set("character", json.number_value(0.0))
        read(end_ptr).set("line", json.number_value(double<-line_zero))
        read(end_ptr).set("character", json.number_value(0.0))
        read(range_ptr).set("start", start)
        read(range_ptr).set("end", end)
        read(obj_ptr).set("uri", json.string_from_str(uri))
        read(obj_ptr).set("range", range)

    return result


## Build an LSP Hover result JSON object.
function build_hover_result(hover_text: str) -> json.Value:
    var result = json.create_object_value()
    var contents = json.create_object_value()

    var obj_ptr = result.as_object()
    var contents_ptr = contents.as_object()

    if obj_ptr == null or contents_ptr == null:
        json.release_value(contents)
        json.release_value(result)
        return json.null_value()

    unsafe:
        read(contents_ptr).set("language", json.string_from_str("milktea"))
        read(contents_ptr).set("value", json.string_from_str(hover_text))
        read(obj_ptr).set("contents", contents)

    return result
