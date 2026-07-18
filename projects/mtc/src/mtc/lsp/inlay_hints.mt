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
import mtc.lsp.protocol as proto
import mtc.lsp.uri as uri_ops
import mtc.lsp.workspace as workspace


## Handle textDocument/inlayHint for the given 0-based inclusive line range.
public function handle_inlay_hint(
    ws: ref[workspace.Workspace],
    uri: str,
    start_line: ptr_uint,
    end_line: ptr_uint,
    id: json.Value,
) -> void:
    var file_path = uri_ops.file_uri_to_path(uri) else:
        proto.write_response_raw(id, "[]")
        return
    defer file_path.release()

    var content = ws.document_source(file_path.as_str()) else:
        proto.write_response_raw(id, "[]")
        return
    defer content.release()

    let source = content.as_str()
    var tokens = lexer_mod.lex(source)
    defer tokens.release()

    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer parse_diags.release()
    var ast_file = parser.parse_source(source, ref_of(parse_diags))
    var analysis = analyzer.check_source_file(ast_file)

    var json_text = string.String.create()
    defer json_text.release()
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
                # Only handle `alias.fn(...)` where the receiver is an import alias.
                let alias_ok = ti > 1
                if not alias_ok:
                    ti += 1
                    continue
                let alias_ptr = tokens.get(ti - 2) else:
                    break
                let alias_tok = unsafe: read(alias_ptr)
                if alias_tok.kind != tk.TokenKind.identifier:
                    ti += 1
                    continue
                let alias_name = cursor.token_text(source, alias_tok)
                let module_name_ptr = analysis.imports.get(alias_name)
                if module_name_ptr == null:
                    ti += 1
                    continue

                let module_name = unsafe: read(module_name_ptr)
                let fn_name = cursor.token_text(source, callee)

                var roots = ws.effective_module_roots_for("")
                defer roots.release()
                match resolver.resolve_module_path(module_name, roots.as_span(), resolver.Platform.linux):
                    Result.failure:
                        ti += 1
                        continue
                    Result.success as path_payload:
                        var module_path = path_payload.value
                        defer module_path.release()

                        var module_source = ws.document_source(module_path.as_str()) else:
                            ti += 1
                            continue
                        defer module_source.release()

                        var parse_diags_mod = vec.Vec[pstate.ParseDiagnostic].create()
                        defer parse_diags_mod.release()
                        var module_file = parser.parse_source(module_source.as_str(), ref_of(parse_diags_mod))

                        let psig = find_function_params(module_file.declarations, fn_name)
                        match psig:
                            Option.some as sig:
                                emit_call_hints(ref_of(json_text), ref_of(emitted), source, ref_of(tokens), ti + 1, sig.value, start_line, end_line)
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
                    start_line,
                    end_line
                )
        ti += 1

    json_text.append("]")
    proto.write_response_raw(id, json_text.as_str())


## Emit one hint per positional argument of the call whose lparen is at
## `lparen_index`.
function emit_call_hints(
    json_text: ref[string.String],
    emitted: ref[ptr_uint],
    source: str,
    tokens: ref[vec.Vec[token_mod.Token]],
    lparen_index: ptr_uint,
    sig: analyzer.FnSig,
    start_line: ptr_uint,
    end_line: ptr_uint,
) -> void:
    var arg_starts = collect_argument_starts(tokens, lparen_index)
    defer arg_starts.release()

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
        if arg_line < start_line or arg_line > end_line:
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

        let arg_col = if arg_tok.column > 0: arg_tok.column - 1 else: 0z
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
        json_text.append(": \",\"kind\":2}")
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
                    ))
            _:
                pass
        di += 1
    return Option[analyzer.FnSig].none
