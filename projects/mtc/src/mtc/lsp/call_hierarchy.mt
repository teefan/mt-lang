## Call hierarchy handler.  Supports prepareCallHierarchy, incomingCalls,
## and outgoingCalls.  Uses cursor token resolution, the workspace index,
## and AST body traversal to build call-graph relationships.

import std.fmt
import std.fs as fs_mod
import std.json as json
import std.str
import std.string as string
import std.vec as vec

import mtc.parser.ast as ast
import mtc.parser.parser as parser
import mtc.parser.state as pstate
import mtc.semantic.analyzer as analyzer
import mtc.lsp.cursor as cursor
import mtc.lsp.protocol as proto
import mtc.lsp.uri as uri_ops
import mtc.lsp.workspace as workspace
import mtc.lsp.workspace_index as idx


const KIND_FUNCTION: int = 12
const KIND_METHOD:   int = 6


## Handle textDocument/prepareCallHierarchy.  Finds a callable symbol at
## the cursor and returns a CallHierarchyItem.
public function handle_prepare_call_hierarchy(
    ws: ref[workspace.Workspace],
    uri: str,
    line: ptr_uint,
    character: ptr_uint,
    id: json.Value,
) -> void:
    var file_path = uri_ops.file_uri_to_path(uri) else:
        proto.write_response(id, json.null_value())
        return
    defer file_path.release()

    var content = ws.document_source(file_path.as_str()) else:
        proto.write_response(id, json.null_value())
        return
    defer content.release()

    let source = content.as_str()
    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer parse_diags.release()
    var ast_file = parser.parse_source(source, ref_of(parse_diags))
    var analysis = analyzer.check_source_file(ast_file)

    let token_opt = cursor.identifier_at(source, line, character)
    match token_opt:
        Option.none:
            proto.write_response(id, json.null_value())
            return
        Option.some as token_payload:
            let name = token_payload.value.text
            var found = false
            var kind: int = KIND_FUNCTION

            unsafe:
                found = analysis.functions.contains(name)

            if not found:
                proto.write_response(id, json.null_value())
                return

            var result = string.String.create()
            defer result.release()
            result.append("[")
            append_call_item(ref_of(result), name, kind, uri, token_payload.value.line, token_payload.value.column, token_payload.value.length)
            result.append("]")
            proto.write_response_raw(id, result.as_str())


## Handle callHierarchy/incomingCalls.  Finds all references to the target
## function and determines the enclosing function for each reference.
public function handle_incoming_calls(
    ws: ref[workspace.Workspace],
    params: json.Value,
    id: json.Value,
) -> void:
    let item_uri = extract_item_field(params, "uri")
    let name = extract_item_field(params, "name")
    if name.len == 0:
        proto.write_response(id, json.null_value())
        return

    ws.build_index_if_needed()

    var result = string.String.create()
    defer result.release()
    result.append("[")
    var first = true
    var max_entries: ptr_uint = 200

    var ri: ptr_uint = 0
    while ri < ws.index.entries.len() and ri < max_entries:
        let ep = ws.index.entries.get(ri) else:
            break
        let entry = unsafe: read(ep)
        let path = entry.path.as_str()

        match fs_mod.read_text(path):
            Result.success as payload:
                var content = payload.value
                var parse_diags2 = vec.Vec[pstate.ParseDiagnostic].create()
                defer parse_diags2.release()
                var ast_file2 = parser.parse_source(content.as_str(), ref_of(parse_diags2))
                var analysis2 = analyzer.check_source_file(ast_file2)

                let source = content.as_str()
                var occurrences = cursor.identifier_occurrences(source, name)
                defer occurrences.release()

                # Skip matches that are the declaration itself.
                var oi: ptr_uint = 0
                while oi < occurrences.len():
                    let oc = occurrences.get(oi) else:
                        break
                    let occ = unsafe: read(oc)

                    let caller_name = find_enclosing_decl(ast_file2, occ.line)
                    if caller_name.len > 0 and not caller_name.equal(name):
                        if not first:
                            result.append(",")
                        first = false
                        var target_uri = build_file_uri(path)
                        append_incoming_call(ref_of(result), name, caller_name, target_uri.as_str(), entry.line, occ.line, occ.column)
                        target_uri.release()
                        # Only report once per caller per file.
                        break
                    oi += 1

                content.release()
            Result.failure:
                pass
        ri += 1

    result.append("]")
    proto.write_response_raw(id, result.as_str())


## Handle callHierarchy/outgoingCalls.  Walks the function body AST to find
## all call targets and returns CallHierarchyOutgoingCall items.
public function handle_outgoing_calls(
    ws: ref[workspace.Workspace],
    params: json.Value,
    id: json.Value,
) -> void:
    let item_uri = extract_item_field(params, "uri")
    let name = extract_item_field(params, "name")
    if name.len == 0 or item_uri.len == 0:
        proto.write_response(id, json.null_value())
        return

    var file_path = uri_ops.file_uri_to_path(item_uri) else:
        proto.write_response(id, json.null_value())
        return
    defer file_path.release()

    var content = ws.document_source(file_path.as_str()) else:
        proto.write_response(id, json.null_value())
        return
    defer content.release()

    let source = content.as_str()
    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer parse_diags.release()
    var ast_file = parser.parse_source(source, ref_of(parse_diags))

    # Find the function body for `name`.
    var collected = vec.Vec[CalleeRef].create()
    defer collected.release()
    var di: ptr_uint = 0
    while di < ast_file.declarations.len:
        var decl: ast.Decl
        unsafe:
            decl = read(ast_file.declarations.data + di)
        match decl:
            ast.Decl.decl_function as fun:
                if fun.name.equal(name):
                    let body = fun.body else:
                        break
                    collect_callees(body, source, ref_of(collected))
            _:
                pass
        di += 1

    var result = string.String.create()
    defer result.release()
    result.append("[")
    var first = true

    var ci: ptr_uint = 0
    while ci < collected.len():
        let cp = collected.get(ci) else:
            break
        let callee = unsafe: read(cp)
        if not first:
            result.append(",")
        first = false
        append_outgoing_call(ref_of(result), callee.name, callee.line, callee.column, callee.length)
        ci += 1

    result.append("]")
    proto.write_response_raw(id, result.as_str())


struct CalleeRef:
    name: str
    line: ptr_uint
    column: ptr_uint
    length: ptr_uint


## Walk an AST body to collect all call-target names.
function collect_callees(body_node: ptr[ast.Stmt]?, source: str, output: ref[vec.Vec[CalleeRef]]) -> void:
    let b = body_node else:
        return
    unsafe:
        match read(b):
            ast.Stmt.stmt_block as blk:
                walk_stmts_callees(blk.statements, source, output)
            _:
                pass


function walk_stmts_callees(stmts: span[ast.Stmt], source: str, output: ref[vec.Vec[CalleeRef]]) -> void:
    var si: ptr_uint = 0
    while si < stmts.len:
        unsafe:
            var sp = stmts.data + si
            match read(sp):
                ast.Stmt.stmt_match as m:
                    walk_expr_callees(m.scrutinee, source, output)
                    var ai: ptr_uint = 0
                    while ai < m.arms.len:
                        let arm = unsafe: read(m.arms.data + ai)
                        let arm_body = arm.body
                        if arm_body != null:
                            collect_callees(arm_body, source, output)
                        ai += 1
                ast.Stmt.stmt_while as w:
                    walk_expr_callees(w.condition, source, output)
                    collect_callees(w.body, source, output)
                ast.Stmt.stmt_if as iff:
                    # Walk conditions from all branches.
                    var ib: ptr_uint = 0
                    while ib < iff.branches.len:
                        let branch = unsafe: read(iff.branches.data + ib)
                        walk_expr_callees(branch.condition, source, output)
                        collect_callees(branch.body, source, output)
                        ib += 1
                    collect_callees(iff.else_body, source, output)
                ast.Stmt.stmt_for as f:
                    # Walk each iterable expression.
                    var fi: ptr_uint = 0
                    while fi < f.iterables.len:
                        walk_expr_callees(unsafe: f.iterables.data + fi, source, output)
                        fi += 1
                    collect_callees(f.body, source, output)
                ast.Stmt.stmt_expression as se:
                    walk_expr_callees(se.expression, source, output)
                ast.Stmt.stmt_local as loc:
                    walk_expr_callees(loc.value, source, output)
                ast.Stmt.stmt_ret as ret:
                    walk_expr_callees(ret.value, source, output)
                ast.Stmt.stmt_block as blk2:
                    walk_stmts_callees(blk2.statements, source, output)
                _:
                    pass
        si += 1


function walk_expr_callees(ep: ptr[ast.Expr]?, source: str, output: ref[vec.Vec[CalleeRef]]) -> void:
    let e = ep else:
        return
    unsafe:
        match read(e):
            ast.Expr.expr_call as call:
                let callee = call.callee
                unsafe: collect_call_target(read(callee), source, output)
                walk_expr_args(call.args, source, output)
            ast.Expr.expr_binary_op as bin:
                walk_expr_callees(bin.left, source, output)
                walk_expr_callees(bin.right, source, output)
            ast.Expr.expr_unary_op as un:
                walk_expr_callees(un.operand, source, output)
            ast.Expr.expr_if as iff:
                walk_expr_callees(iff.condition, source, output)
                walk_expr_callees(iff.then_expr, source, output)
                walk_expr_callees(iff.else_expr, source, output)
            ast.Expr.expr_match as me:
                walk_expr_callees(me.scrutinee, source, output)
                var ai: ptr_uint = 0
                while ai < me.arms.len:
                    let arm = unsafe: read(me.arms.data + ai)
                    walk_expr_callees(arm.value, source, output)
                    ai += 1
            ast.Expr.expr_proc as pr:
                collect_callees(pr.body, source, output)
            ast.Expr.expr_await as aw:
                walk_expr_callees(aw.expression, source, output)
            _:
                pass


function walk_expr_args(args: span[ast.Argument], source: str, output: ref[vec.Vec[CalleeRef]]) -> void:
    var ai: ptr_uint = 0
    while ai < args.len:
        unsafe:
            let arg = read(args.data + ai)
            walk_expr_callees(arg.arg_value, source, output)
        ai += 1


function collect_call_target(callee_expr: ast.Expr, source: str, output: ref[vec.Vec[CalleeRef]]) -> void:
    match callee_expr:
        ast.Expr.expr_identifier as id:
            if id.name.len > 0 and id.line > 0:
                output.push(CalleeRef(name = id.name, line = id.line, column = id.column, length = id.name.len))
        _:
            pass


## Find the name of the top-level declaration that contains the given line.
function find_enclosing_decl(ast_file: ast.SourceFile, line: ptr_uint) -> str:
    var di: ptr_uint = 0
    while di < ast_file.declarations.len:
        var decl: ast.Decl
        unsafe:
            decl = read(ast_file.declarations.data + di)
        match decl:
            ast.Decl.decl_function as fun:
                if fun.line <= line and line <= last_line_of_decl(fun.body, fun.line):
                    return fun.name
            _:
                pass
        di += 1
    return ""


## Approximate the last line of a declaration's body.
function last_line_of_decl(body_node: ptr[ast.Stmt]?, fallback: ptr_uint) -> ptr_uint:
    let b = body_node else:
        return fallback + 5
    unsafe:
        match read(b):
            ast.Stmt.stmt_block as blk:
                return block_last_line(blk.statements) + 1
            _:
                return fallback + 5


function block_last_line(stmts: span[ast.Stmt]) -> ptr_uint:
    var last: ptr_uint = 0
    var si: ptr_uint = 0
    while si < stmts.len:
        unsafe:
            let sl = stmt_line(stmts.data + si)
            if sl > last:
                last = sl
        si += 1
    return last


function stmt_line(sp: ptr[ast.Stmt]) -> ptr_uint:
    unsafe:
        match read(sp):
            ast.Stmt.stmt_local as loc:
                return loc.line
            ast.Stmt.stmt_ret as r:
                return r.line
            ast.Stmt.stmt_block as blk:
                return block_last_line(blk.statements)
            ast.Stmt.stmt_expression as se:
                return se.line
            _:
                return 0


## Extract a named field from a call-hierarchy item JSON.
function extract_item_field(value: json.Value, field: str) -> str:
    let obj_ptr = value.as_object()
    if obj_ptr == null:
        let arr_ptr = value.as_array()
        if arr_ptr == null:
            return ""
        unsafe:
            let first_ptr = read(arr_ptr).get(0)
            if first_ptr == null:
                return ""
            let first_obj = read(first_ptr).as_object()
            if first_obj == null:
                return ""
            let f_ptr = read(first_obj).get(field)
            if f_ptr == null:
                return ""
            let f_str = read(f_ptr).as_string() else:
                return ""
            return f_str
    unsafe:
        let f_ptr = read(obj_ptr).get(field)
        if f_ptr == null:
            return ""
        let f_str = read(f_ptr).as_string() else:
            return ""
        return f_str


## Build a file:// URI from an absolute path.
function build_file_uri(path: str) -> string.String:
    var uri = string.String.create()
    uri.append("file://")
    var i: ptr_uint = 0
    while i < path.len:
        let b = path.byte_at(i)
        if b == ' ':
            uri.append("%20")
        else if b == '%':
            uri.append("%25")
        else:
            uri.push_byte(b)
        i += 1
    return uri


function append_call_item(
    output: ref[string.String],
    name: str,
    kind: int,
    uri: str,
    line: ptr_uint,
    column: ptr_uint,
    length: ptr_uint,
) -> void:
    let lz = if line > 0: line - 1 else: 0z
    let colz = if column > 0: column - 1 else: 0z
    output.append("{\"name\":\"")
    proto.append_escaped(output, name)
    output.append("\",\"kind\":")
    output.append_format(f"#{kind}")
    output.append(",\"uri\":\"")
    proto.append_escaped(output, uri)
    output.append("\",\"range\":{\"start\":{\"line\":")
    output.append_format(f"#{lz}")
    output.append(",\"character\":")
    output.append_format(f"#{colz}")
    output.append("},\"end\":{\"line\":")
    output.append_format(f"#{lz}")
    output.append(",\"character\":")
    output.append_format(f"#{colz + length}")
    output.append("}},\"selectionRange\":{\"start\":{\"line\":")
    output.append_format(f"#{lz}")
    output.append(",\"character\":")
    output.append_format(f"#{colz}")
    output.append("},\"end\":{\"line\":")
    output.append_format(f"#{lz}")
    output.append(",\"character\":")
    output.append_format(f"#{colz + length}")
    output.append("}}}")


function append_incoming_call(
    output: ref[string.String],
    target_name: str,
    caller_name: str,
    uri: str,
    line: ptr_uint,
    ref_line: ptr_uint,
    ref_col: ptr_uint,
) -> void:
    let lz = if line > 0: line - 1 else: 0z
    let rlz = if ref_line > 0: ref_line - 1 else: 0z
    let rcz = if ref_col > 0: ref_col - 1 else: 0z
    output.append("{\"from\":{\"name\":\"")
    proto.append_escaped(output, caller_name)
    output.append("\",\"kind\":")
    output.append_format(f"#{KIND_FUNCTION}")
    output.append(",\"uri\":\"")
    proto.append_escaped(output, uri)
    output.append("\",\"range\":{\"start\":{\"line\":")
    output.append_format(f"#{lz}")
    output.append(",\"character\":0},\"end\":{\"line\":")
    output.append_format(f"#{lz}")
    output.append(",\"character\":0}},\"selectionRange\":{\"start\":{\"line\":")
    output.append_format(f"#{lz}")
    output.append(",\"character\":0},\"end\":{\"line\":")
    output.append_format(f"#{lz}")
    output.append(",\"character\":0}}}")
    output.append(",\"fromRanges\":[{\"start\":{\"line\":")
    output.append_format(f"#{rlz}")
    output.append(",\"character\":")
    output.append_format(f"#{rcz}")
    output.append("},\"end\":{\"line\":")
    output.append_format(f"#{rlz}")
    output.append(",\"character\":")
    output.append_format(f"#{rcz + target_name.len}")
    output.append("}}]}")


function append_outgoing_call(
    output: ref[string.String],
    callee_name: str,
    line: ptr_uint,
    column: ptr_uint,
    length: ptr_uint,
) -> void:
    let lz = if line > 0: line - 1 else: 0z
    let cz = if column > 0: column - 1 else: 0z
    output.append("{\"to\":{\"name\":\"")
    proto.append_escaped(output, callee_name)
    output.append("\",\"kind\":")
    output.append_format(f"#{KIND_FUNCTION}")
    output.append(",\"uri\":\"")
    # Same-file reference; the editor knows the context.
    output.append("\",\"range\":{\"start\":{\"line\":")
    output.append_format(f"#{lz}")
    output.append(",\"character\":")
    output.append_format(f"#{cz}")
    output.append("},\"end\":{\"line\":")
    output.append_format(f"#{lz}")
    output.append(",\"character\":")
    output.append_format(f"#{cz + length}")
    output.append("}},\"selectionRange\":{\"start\":{\"line\":")
    output.append_format(f"#{lz}")
    output.append(",\"character\":")
    output.append_format(f"#{cz}")
    output.append("},\"end\":{\"line\":")
    output.append_format(f"#{lz}")
    output.append(",\"character\":")
    output.append_format(f"#{cz + length}")
    output.append("}}}")
    output.append(",\"fromRanges\":[{\"start\":{\"line\":")
    output.append_format(f"#{lz}")
    output.append(",\"character\":")
    output.append_format(f"#{cz}")
    output.append("},\"end\":{\"line\":")
    output.append_format(f"#{lz}")
    output.append(",\"character\":")
    output.append_format(f"#{cz + length}")
    output.append("}}]}")
