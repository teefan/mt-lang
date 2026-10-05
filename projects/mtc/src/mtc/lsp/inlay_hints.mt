## Inlay hints — parameter-name hints at call sites (`add(left: 1, right: 2)`
## rendered as ghost text).  Token-stream call detection with parameter lists
## from the semantic Analysis, following the Ruby LSP's
## collect_parameter_name_hints.  Hints are skipped for named arguments and
## for arguments that already spell the parameter name.

import std.fmt
import std.json as json
import std.str
import std.string as string
import std.vec as vec

import mtc.lexer.lexer as lexer_mod
import mtc.lexer.token as token_mod
import mtc.lexer.token_kinds as tk
import mtc.loader.path_resolver as resolver
import mtc.parser.ast as ast
import mtc.parser.parser as parser
import mtc.parser.state as pstate
import mtc.semantic.analyzer as analyzer
import mtc.semantic.types as types
import mtc.lsp.cursor as cursor
import mtc.lsp.navigation as navigation
import mtc.lsp.protocol as proto
import mtc.lsp.type_render as type_render
import mtc.lsp.uri as uri_ops
import mtc.lsp.workspace as workspace


## The request's range as 0-based positions — the host's `position_in_range?`
## inputs (lines *and* characters: a decl at the end line past the end column
## is outside, as the host's check has it).
public struct HintRange:
    start_line: ptr_uint
    start_char: ptr_uint
    end_line: ptr_uint
    end_char: ptr_uint


## The host's `position_in_range?`: a 0-based (line, column) is inside when it
## is at or after the start and at or before the end.
function in_hint_range(range: HintRange, line: ptr_uint, column: ptr_uint) -> bool:
    let after_start = line > range.start_line or (line == range.start_line and column >= range.start_char)
    let before_end = line < range.end_line or (line == range.end_line and column <= range.end_char)
    return after_start and before_end


## Handle textDocument/inlayHint for the request's 0-based range.
public function handle_inlay_hint(
    ws: ref[workspace.Workspace],
    uri: str,
    start_line: ptr_uint,
    start_char: ptr_uint,
    end_line: ptr_uint,
    end_char: ptr_uint,
    id: json.Value,
) -> void:
    let range = HintRange(start_line = start_line, start_char = start_char, end_line = end_line, end_char = end_char)
    var file_path = uri_ops.file_uri_to_path(uri) else:
        proto.write_response_raw(id, "[]")
        return
    defer: file_path.release()

    var content = ws.document_source(file_path.as_str()) else:
        proto.write_response_raw(id, "[]")
        return
    defer: content.release()

    let source = content.as_str()
    var lex_diags = vec.Vec[token_mod.LexDiagnostic].create()
    defer: lex_diags.release()
    var tokens = lexer_mod.lex_reporting(source, ref_of(lex_diags))
    defer: tokens.release()

    # Shared with the other features through the workspace's parse cache: the
    # parse and single-file check of a large file cost more than a request's
    # own work.
    # The loader-backed analysis types imported symbols (`node.Node.create(...)`),
    # which the single-file check cannot; its AST is what the recorded types are
    # keyed by.
    var ast_file: ast.SourceFile
    var analysis: analyzer.Analysis
    var maybe_entry = workspace.analysis_entry_for(ws, file_path.as_str())
    if maybe_entry.is_some():
        let entry_ptr = maybe_entry.unwrap()
        analysis = unsafe: read(entry_ptr).analysis
        ast_file = analysis.source_file
    else:
        var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
        defer: parse_diags.release()
        ast_file = parser.parse_source(source, ref_of(parse_diags))
        analysis = analyzer.check_source_file(ast_file)

    var json_text = string.String.create()
    defer: json_text.release()
    json_text.append("[")
    var emitted: ptr_uint = 0

    var ti: ptr_uint = 0
    while ti + 1 < tokens.len():
        let callee_ptr = tokens.get(ti) else:
            break
        let callee = unsafe: read(callee_ptr)
        if callee.kind != tk.TokenKind.identifier:
            ti += 1
            continue
        let next_ptr = tokens.get(ti + 1) else:
            break
        if unsafe: read(next_ptr).kind != tk.TokenKind.lparen:
            ti += 1
            continue
        # Skip `function name(...)` declarations; try import-alias calls.
        if ti > 0:
            let prev_ptr = tokens.get(ti - 1) else:
                break
            let prev_kind = unsafe: read(prev_ptr).kind
            if prev_kind == tk.TokenKind.tk_function:
                ti += 1
                continue
            if prev_kind == tk.TokenKind.dot:
                let receiver_ok = ti > 1
                if not receiver_ok:
                    ti += 1
                    continue
                let receiver_ptr = tokens.get(ti - 2) else:
                    break
                let receiver_tok = unsafe: read(receiver_ptr)
                if receiver_tok.kind != tk.TokenKind.identifier:
                    ti += 1
                    continue
                let receiver_name = cursor.token_text(source, receiver_tok)
                let module_name_ptr = analysis.imports.get(receiver_name)
                if module_name_ptr == null:
                    # `value.method(...)` / `Type.method(...)`: the host resolves
                    # the receiver's type and looks the method up in the merged
                    # receiver table.
                    let fn_name = cursor.token_text(source, callee)
                    match receiver_method_sig_for(analysis, ast_file, receiver_name, fn_name, receiver_tok.line, source):
                        Option.some as sig:
                            emit_call_hints(ref_of(json_text), ref_of(emitted), source, ref_of(tokens), ti + 1, sig.value, range)
                        Option.none:
                            pass
                    ti += 1
                    continue

                let module_name = unsafe: read(module_name_ptr)
                let fn_name = cursor.token_text(source, callee)

                var roots = ws.effective_module_roots_for("")
                defer: roots.release()
                match resolver.resolve_module_path(module_name, roots.as_span(), resolver.Platform.linux):
                    Result.failure:
                        ti += 1
                        continue
                    Result.success as path_payload:
                        var module_path = path_payload.value
                        defer: module_path.release()

                        let module_doc = workspace.document_analysis_for(ws, module_path.as_str()) else:
                            ti += 1
                            continue
                        var module_file = module_doc.ast_file

                        let psig = find_function_params(module_file.declarations, fn_name)
                        match psig:
                            Option.some as sig:
                                emit_call_hints(ref_of(json_text), ref_of(emitted), source, ref_of(tokens), ti + 1, sig.value, range)
                            Option.none:
                                pass
                ti += 1
                continue

        unsafe:
            let sig_ptr = analysis.functions.get(cursor.token_text(source, callee))
            if sig_ptr != null:
                emit_call_hints(
                    ref_of(json_text),
                    ref_of(emitted),
                    source,
                    ref_of(tokens),
                    ti + 1,
                    read(sig_ptr),
                    range
                )
        ti += 1

    # Type-annotation hints for inferred locals, after the parameter hints —
    # the host's collect_inferred_type_hints.
    emit_type_hints(ref_of(json_text), ref_of(emitted), ast_file, ref_of(analysis), range)

    # Return-type hints for callables whose return type was not written, last —
    # the host's collect_inferred_return_hints.
    emit_return_hints(ref_of(json_text), ref_of(emitted), ast_file, ref_of(analysis), range)

    json_text.append("]")
    proto.write_response_raw(id, json_text.as_str())


## Type-annotation hints for inferred locals — the host's
## collect_inferred_type_hints, which walks every function/method body in
## source order and renders `: <type>` after an unannotated binding's name.
function emit_type_hints(
    json_text: ref[string.String],
    emitted: ref[ptr_uint],
    file: ast.SourceFile,
    analysis: ref[analyzer.Analysis],
    range: HintRange,
) -> void:
    var di: ptr_uint = 0
    while di < file.declarations.len:
        var decl: ast.Decl
        unsafe:
            decl = read(file.declarations.data + di)
        match decl:
            ast.Decl.decl_function as fun:
                if fun.body != null:
                    emit_type_hints_in_stmt(json_text, emitted, unsafe: read(ptr[ast.Stmt]<-fun.body), analysis, range)
            ast.Decl.decl_extending_block as ext:
                var mi: ptr_uint = 0
                while mi < ext.methods.len:
                    let method = unsafe: read(ext.methods.data + mi)
                    emit_type_hints_in_stmt(json_text, emitted, unsafe: read(ptr[ast.Stmt]<-method.body), analysis, range)
                    mi += 1
            _:
                pass
        di += 1


function emit_type_hints_in_stmt(
    json_text: ref[string.String],
    emitted: ref[ptr_uint],
    stmt: ast.Stmt,
    analysis: ref[analyzer.Analysis],
    range: HintRange,
) -> void:
    match stmt:
        ast.Stmt.stmt_block as blk:
            var si: ptr_uint = 0
            while si < blk.statements.len:
                var inner = unsafe: read(blk.statements.data + si)
                emit_type_hints_in_stmt(json_text, emitted, inner, analysis, range)
                si += 1
        ast.Stmt.stmt_local as loc:
            emit_local_type_hint(json_text, emitted, loc.name, loc.stmt_type, loc.value, loc.line, loc.column, analysis, range)
        ast.Stmt.stmt_if as iff:
            var bi: ptr_uint = 0
            while bi < iff.branches.len:
                let branch = unsafe: read(iff.branches.data + bi)
                emit_type_hints_in_stmt(json_text, emitted, unsafe: read(branch.body), analysis, range)
                bi += 1
            if iff.else_body != null:
                emit_type_hints_in_stmt(json_text, emitted, unsafe: read(ptr[ast.Stmt]<-iff.else_body), analysis, range)
        ast.Stmt.stmt_while as wh:
            if wh.body != null:
                emit_type_hints_in_stmt(json_text, emitted, unsafe: read(ptr[ast.Stmt]<-wh.body), analysis, range)
        ast.Stmt.stmt_for as fo:
            if fo.body != null:
                emit_type_hints_in_stmt(json_text, emitted, unsafe: read(ptr[ast.Stmt]<-fo.body), analysis, range)
        ast.Stmt.stmt_match as ma:
            var ai: ptr_uint = 0
            while ai < ma.arms.len:
                let arm = unsafe: read(ma.arms.data + ai)
                if arm.body != null:
                    emit_type_hints_in_stmt(json_text, emitted, unsafe: read(ptr[ast.Stmt]<-arm.body), analysis, range)
                ai += 1
        ast.Stmt.stmt_unsafe as un:
            if un.body != null:
                emit_type_hints_in_stmt(json_text, emitted, unsafe: read(ptr[ast.Stmt]<-un.body), analysis, range)
        _:
            pass


## One `: <type>` hint for an unannotated local whose type the analyzer
## inferred.  Nothing is emitted for annotated bindings, `_` bindings, or
## bindings outside the requested line range.
function emit_local_type_hint(
    json_text: ref[string.String],
    emitted: ref[ptr_uint],
    name: str,
    stmt_type: ptr[ast.TypeRef]?,
    value: ptr[ast.Expr]?,
    line: ptr_uint,
    column: ptr_uint,
    analysis: ref[analyzer.Analysis],
    range: HintRange,
) -> void:
    if name.len == 0 or name.equal("_") or stmt_type != null:
        return
    let line_zero = if line > 0: line - 1 else: 0z
    let col_zero = if column > 0: column - 1 else: 0z
    if not in_hint_range(range, line_zero, col_zero):
        return

    match type_render.initializer_type(analysis, value):
        Option.some as ty:
            if is_error_type(ty.value):
                return
            var label = type_render.short_name(ty.value)
            let name_end = if column > 0: (column - 1) + name.len else: name.len
            if unsafe: read(emitted) > 0:
                json_text.append(",")
            unsafe: read(emitted) = read(emitted) + 1
            json_text.append("{\"position\":{\"line\":")
            json_text.append_format(f"#{line_zero}")
            json_text.append(",\"character\":")
            json_text.append_format(f"#{name_end}")
            json_text.append("},\"label\":\": ")
            proto.append_escaped(json_text, label.as_str())
            json_text.append("\",\"kind\":1,\"paddingRight\":false}")
            label.release()
        Option.none:
            pass


function is_error_type(ty: types.Type) -> bool:
    match ty:
        types.Type.ty_error:
            return true
        _:
            return false


## Return-type hints for callables whose return type was not written — the
## host's collect_inferred_return_hints: for each top-level function and
## extending-block method in source order, `-> <type>` after the declared name
## when the resolved return type is not `void`.  (With the return type omitted
## the body is void, so in practice this is the async wrapper, `Task[void]`.)
function emit_return_hints(
    json_text: ref[string.String],
    emitted: ref[ptr_uint],
    file: ast.SourceFile,
    analysis: ref[analyzer.Analysis],
    range: HintRange,
) -> void:
    var di: ptr_uint = 0
    while di < file.declarations.len:
        var decl: ast.Decl
        unsafe:
            decl = read(file.declarations.data + di)
        match decl:
            ast.Decl.decl_function as fun:
                let sig_ptr = unsafe: read(analysis).functions.get(fun.name)
                if sig_ptr != null:
                    emit_return_hint(json_text, emitted, fun.name, fun.line, fun.column, unsafe: read(sig_ptr), range)
            ast.Decl.decl_extending_block as ext:
                var mi: ptr_uint = 0
                while mi < ext.methods.len:
                    let method = unsafe: read(ext.methods.data + mi)
                    match find_method_sig(analysis, method.name):
                        Option.some as sig:
                            emit_return_hint(json_text, emitted, method.name, method.line, method.column, sig.value, range)
                        Option.none:
                            pass
                    mi += 1
            _:
                pass
        di += 1


## The first-registered method signature named `name` in the analysis' method
## table — the host's `facts.methods.each_value` scan for the method name.
function find_method_sig(analysis: ref[analyzer.Analysis], name: str) -> Option[analyzer.FnSig]:
    var suffix = string.String.create()
    defer: suffix.release()
    suffix.append(".")
    suffix.append(name)
    var i: ptr_uint = 0
    unsafe:
        let order = read(analysis).method_order
        while i < order.len():
            let key_ptr = order.get(i) else:
                break
            let key = read(key_ptr)
            if key.ends_with(suffix.as_str()):
                let sig_ptr = read(analysis).method_sigs.get(key)
                if sig_ptr != null:
                    return Option[analyzer.FnSig].some(value = read(sig_ptr))
            i += 1
    return Option[analyzer.FnSig].none


## One `-> <type>` hint for a callable without a written return type.
function emit_return_hint(
    json_text: ref[string.String],
    emitted: ref[ptr_uint],
    name: str,
    line: ptr_uint,
    column: ptr_uint,
    sig: analyzer.FnSig,
    range: HintRange,
) -> void:
    if sig.has_return_type:
        return
    var label = type_render.short_name(sig.return_type)
    defer: label.release()
    if label.as_str().equal("void"):
        return
    let line_zero = if line > 0: line - 1 else: 0z
    let col_zero = if column > 0: column - 1 else: 0z
    if not in_hint_range(range, line_zero, col_zero):
        return
    let name_end = if column > 0: (column - 1) + name.len else: name.len
    if unsafe: read(emitted) > 0:
        json_text.append(",")
    unsafe: read(emitted) = read(emitted) + 1
    json_text.append("{\"position\":{\"line\":")
    json_text.append_format(f"#{line_zero}")
    json_text.append(",\"character\":")
    json_text.append_format(f"#{name_end}")
    json_text.append("},\"label\":\"-> ")
    proto.append_escaped(json_text, label.as_str())
    json_text.append("\",\"kind\":1,\"paddingRight\":false}")


## Emit one hint per positional argument of the call whose lparen is at
## `lparen_index`.
function emit_call_hints(
    json_text: ref[string.String],
    emitted: ref[ptr_uint],
    source: str,
    tokens: ref[vec.Vec[token_mod.Token]],
    lparen_index: ptr_uint,
    sig: analyzer.FnSig,
    range: HintRange,
) -> void:
    var arg_starts = collect_argument_starts(tokens, lparen_index)
    defer: arg_starts.release()

    var ai: ptr_uint = 0
    while ai < arg_starts.len() and ai < sig.params.len:
        let arg_index_ptr = arg_starts.get(ai) else:
            break
        let arg_index = unsafe: read(arg_index_ptr)
        let arg_ptr = tokens.get(arg_index) else:
            break
        let arg_tok = unsafe: read(arg_ptr)
        let param = unsafe: read(sig.params.data + ai)

        let arg_line = if arg_tok.line > 0: arg_tok.line - 1 else: 0z
        let arg_col = if arg_tok.column > 0: arg_tok.column - 1 else: 0z
        if not in_hint_range(range, arg_line, arg_col):
            ai += 1
            continue

        # Named argument (`name = value`): already self-describing.
        if is_named_argument(source, tokens, arg_index):
            ai += 1
            continue

        # Argument identifier already spells the parameter name.
        if arg_tok.kind == tk.TokenKind.identifier:
            if cursor.token_text(source, arg_tok).equal(param.name):
                ai += 1
                continue

        if unsafe: read(emitted) > 0:
            json_text.append(",")
        unsafe:
            read(emitted) = read(emitted) + 1
        json_text.append("{\"position\":{\"line\":")
        json_text.append_format(f"#{arg_line}")
        json_text.append(",\"character\":")
        json_text.append_format(f"#{arg_col}")
        json_text.append("},\"label\":\"")
        proto.append_escaped(json_text, param.name)
        json_text.append(": \",\"kind\":2,\"paddingRight\":true}")
        ai += 1


## Token indices of each top-level argument's first token, stopping at the
## call's closing paren.
function collect_argument_starts(tokens: ref[vec.Vec[token_mod.Token]], lparen_index: ptr_uint) -> vec.Vec[ptr_uint]:
    var result = vec.Vec[ptr_uint].create()
    var depth: int = 1
    var expect_arg = true
    var ti = lparen_index + 1
    while ti < tokens.len():
        let tp = tokens.get(ti) else:
            break
        let kind = unsafe: read(tp).kind
        if kind == tk.TokenKind.lparen or kind == tk.TokenKind.lbracket:
            if expect_arg and depth == 1:
                result.push(ti)
                expect_arg = false
            depth += 1
        else if kind == tk.TokenKind.rparen or kind == tk.TokenKind.rbracket:
            depth -= 1
            if depth == 0:
                break
        else if kind == tk.TokenKind.comma and depth == 1:
            expect_arg = true
        else if kind == tk.TokenKind.eof:
            break
        else if expect_arg and depth == 1 and kind != tk.TokenKind.newline and
                kind != tk.TokenKind.indent and kind != tk.TokenKind.dedent:
            result.push(ti)
            expect_arg = false
        ti += 1
    return result


## True when the argument starting at `arg_index` is a named argument
## (`name = value`).
function is_named_argument(source: str, tokens: ref[vec.Vec[token_mod.Token]], arg_index: ptr_uint) -> bool:
    let arg_ptr = tokens.get(arg_index) else:
        return false
    if unsafe: read(arg_ptr).kind != tk.TokenKind.identifier:
        return false
    let next_ptr = tokens.get(arg_index + 1) else:
        return false
    return unsafe: read(next_ptr).kind == tk.TokenKind.equal


## Find a function in `decls` and return its parameter entry list, or none.
function find_function_params(decls: span[ast.Decl], fn_name: str) -> Option[analyzer.FnSig]:
    var di: ptr_uint = 0
    while di < decls.len:
        var d: ast.Decl
        unsafe:
            d = read(decls.data + di)
        match d:
            ast.Decl.decl_function as fun:
                if fun.name.equal(fn_name):
                    var params = vec.Vec[analyzer.ParamEntry].create()
                    var pi: ptr_uint = 0
                    while pi < fun.method_params.len:
                        var p: ast.Param
                        unsafe:
                            p = read(fun.method_params.data + pi)
                        params.push(analyzer.ParamEntry(name = p.name, ty = types.Type.ty_primitive(name = "bool")))
                        pi += 1
                    var sig = analyzer.FnSig(
                        name = fn_name,
                        params = params.as_span(),
                        return_type = types.Type.ty_primitive(name = "void"),
                        has_return_type = false,
                        method_kind = ast.MethodKind.mk_plain,
                        is_async = fun.is_async,
                        is_variadic = false,
                        is_extern = false,
                        required_count = params.len(),
                    )
                    return Option[analyzer.FnSig].some(value = sig)
            ast.Decl.decl_foreign_function as ff:
                if ff.name.equal(fn_name):
                    var params = vec.Vec[analyzer.ParamEntry].create()
                    var pi: ptr_uint = 0
                    while pi < ff.foreign_params.len:
                        var fp: ast.ForeignParam
                        unsafe:
                            fp = read(ff.foreign_params.data + pi)
                        params.push(analyzer.ParamEntry(name = fp.name, ty = types.Type.ty_primitive(name = "bool")))
                        pi += 1
                    return Option[analyzer.FnSig].some(value = analyzer.FnSig(
                        name = fn_name,
                        params = params.as_span(),
                        return_type = types.Type.ty_primitive(name = "void"),
                        has_return_type = false,
                        method_kind = ast.MethodKind.mk_plain,
                        is_async = false,
                        is_variadic = ff.variadic,
                        is_extern = true,
                        required_count = params.len(),
                    ))
            _:
                pass
        di += 1
    return Option[analyzer.FnSig].none


## The signature of a `receiver.method(...)` callee: resolve the receiver to a
## type name — a local/parameter/module value's type first, then a type name
## (declared locally or imported) — and find the method in the current module's
## table or an import's (the host's `methods_for_receiver_type` merge, first
## registration wins).
function receiver_method_sig_for(
    analysis: ref[analyzer.Analysis],
    ast_file: ast.SourceFile,
    receiver_name: str,
    member: str,
    receiver_line: ptr_uint,
    source: str,
) -> Option[analyzer.FnSig]:
    var type_name: str = ""
    match navigation.type_of_value(analysis, ast_file, receiver_name, receiver_line, source):
        Option.some as ty:
            type_name = receiver_key_name(ty.value)
        Option.none:
            type_name = type_receiver_key_name(analysis, receiver_name)
    if type_name.len == 0:
        return Option[analyzer.FnSig].none
    return receiver_method_sig(analysis, type_name, member)


## The method-dispatch name of a receiver's value type (`Vec[int]` → "Vec"; a
## nullable unwraps).
function receiver_key_name(ty: types.Type) -> str:
    match ty:
        types.Type.ty_generic as g:
            return g.name
        types.Type.ty_named as n:
            return n.name
        types.Type.ty_imported as im:
            return im.name
        types.Type.ty_opaque as op:
            return op.name
        types.Type.ty_nullable:
            return receiver_key_name(types.unwrap_nullable(ty))
        _:
            return ""


## A *type* receiver's name (`Sample.static(...)`, an imported type spelled
## bare): a locally declared type, or a type one of the imports declares.
function type_receiver_key_name(analysis: ref[analyzer.Analysis], name: str) -> str:
    unsafe:
        if read(analysis).types.get(name) != null:
            return name
        if read(analysis).type_names.contains(name):
            return name
    let import_order = unsafe: read(analysis).import_order
    var i: ptr_uint = 0
    while i < import_order.len():
        let module_ptr = import_order.get(i) else:
            break
        let module_name = unsafe: read(module_ptr)
        var key = string.String.create()
        defer: key.release()
        key.append(module_name)
        key.append(".")
        key.append(name)
        let entry_ptr = unsafe: read(analysis).imported_type_members.get(key.as_str())
        if entry_ptr != null and unsafe: read(entry_ptr).declared:
            return name
        i += 1
    return ""


## One method's signature by receiver type name (the host's
## `methods_for_receiver_type` lookup): the current module's table first, then
## each import's, in the host's import order.
function receiver_method_sig(analysis: ref[analyzer.Analysis], type_name: str, member: str) -> Option[analyzer.FnSig]:
    var key = string.String.create()
    defer: key.release()
    key.append(type_name)
    key.append(".")
    key.append(member)
    let local_ptr = unsafe: read(analysis).method_sigs.get(key.as_str())
    if local_ptr != null:
        return Option[analyzer.FnSig].some(value = unsafe: read(local_ptr))

    let import_order = unsafe: read(analysis).import_order
    var i: ptr_uint = 0
    while i < import_order.len():
        let module_ptr = import_order.get(i) else:
            break
        let module_name = unsafe: read(module_ptr)
        var members_key = string.String.create()
        defer: members_key.release()
        members_key.append(module_name)
        members_key.append(".")
        members_key.append(type_name)
        let entry_ptr = unsafe: read(analysis).imported_type_members.get(members_key.as_str())
        if entry_ptr != null:
            let sig_ptr = unsafe: read(entry_ptr).methods.get(member)
            if sig_ptr != null:
                return Option[analyzer.FnSig].some(value = unsafe: read(sig_ptr))
        i += 1
    return Option[analyzer.FnSig].none
