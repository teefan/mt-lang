## In-language linter for the self-hosted mtc compiler.
##
## Walks a parsed AST and reports style/correctness warnings, mirroring the Ruby
## linter's AST-only rules (those that need no semantic-analysis facts):
##
##   - self-assignment                (warning)  `x = x`
##   - self-comparison                (warning)  `x == x` / `x != x`
##   - redundant-bool-compare         (hint)     `x == true` and friends
##   - redundant-return               (hint)     final bare `return` in a `-> void` body
##   - useless-expression             (warning)  pure expression statement
##   - duplicate-if-condition         (warning)  duplicate branch condition
##   - noop-compound-assignment       (hint)     `x += 0`, `x *= 1`
##   - redundant-ignored-match-binding (hint)    `as _`
##   - redundant-else                 (hint)     else after branches that all return
##   - event-capacity                 (warning)  event capacity >= 128
##   - trailing-list-comma            (hint)     redundant comma before a call's `)`
##   - doc-tag                        (hint)     malformed / mismatched `## @param` / `## @return`
##
## The token-based trailing-list-comma pass re-lexes the source and doc-tag
## reads source lines; all others work from the AST alone.
##
## Rule checks are applied after visiting a node's children, matching the Ruby
## visitor's emission order.  The `lint` command renders each warning as
## `path:line: code: message`, so a warning only needs a line, code, message,
## and severity.

import std.vec as vec
import std.string as string
import std.str
import std.map as map_mod
import std.hash

import mtc.parser.ast as ast
import mtc.lexer.lexer as lexer
import mtc.lexer.token as token_mod
import mtc.lexer.token_kinds as tk
import mtc.linter.scope_tracking as scope_tracking


public struct Warning:
    path: str
    line: ptr_uint
    code: str
    message: str
    severity: str


## Lint a parsed source file, returning warnings in source (traversal) order.
## `source` is the original text, re-lexed for the token-based passes.
public function lint_source(file: ast.SourceFile, source: str, path: str) -> vec.Vec[Warning]:
    var warnings = vec.Vec[Warning].create()
    var i: ptr_uint = 0
    while i < file.declarations.len:
        unsafe:
            visit_decl(file.declarations.data + i, path, ref_of(warnings))
        i += 1
    # Scope-tracking pass: unused-local, unused-param, shadow, prefer-let, unused-import
    var scope_warnings = vec.Vec[scope_tracking.ScopeWarning].create()
    scope_tracking.lint_scope_pass(file, path, ref_of(scope_warnings))
    i = 0
    while i < scope_warnings.len():
        let sp = scope_warnings.get(i) else:
            break
        let sw = unsafe: read(sp)
        warnings.push(Warning(path = sw.path, line = sw.line, code = sw.code, message = sw.message, severity = sw.severity))
        i += 1
    scope_warnings.release()
    # Whole-file passes run after the AST visitor, matching Ruby's emission order.
    lint_prefer_let_else(file, path, ref_of(warnings))
    lint_ownership(file, path, ref_of(warnings))
    lint_doc_tags(file.declarations, source, path, ref_of(warnings))
    lint_events(file.declarations, "", path, ref_of(warnings))
    lint_trailing_commas(file.declarations, source, path, ref_of(warnings))
    lint_line_too_long(source, path, ref_of(warnings))
    return warnings


# =============================================================================
#  doc-tag — validate `## @param` / `## @return` doc-comment tags.
# =============================================================================

struct DocLine:
    line: ptr_uint
    text: str

struct DocParamTag:
    name: str
    line: ptr_uint

struct DocTagParse:
    tag: str
    payload: str


function dt_is_space(b: ubyte) -> bool:
    return b == 32 or b == 9


function dt_is_name_start(b: ubyte) -> bool:
    return (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or b == '_'


function dt_is_name_char(b: ubyte) -> bool:
    return dt_is_name_start(b) or (b >= '0' and b <= '9')


function dt_is_tag_char(b: ubyte) -> bool:
    return dt_is_name_char(b) or b == '-'


## Split `source` into line slices (without the terminating newline).
function split_lines(source: str) -> vec.Vec[str]:
    var lines = vec.Vec[str].create()
    var start: ptr_uint = 0
    var i: ptr_uint = 0
    while i < source.len:
        if source.byte_at(i) == 10:
            lines.push(source.slice(start, i - start))
            start = i + 1
        i += 1
    if start < source.len:
        lines.push(source.slice(start, source.len - start))
    return lines


## The contiguous block of `##` doc-comment lines immediately above `decl_line`,
## top-to-bottom, or empty when there is none.
function collect_doc_block(lines: ref[vec.Vec[str]], decl_line: ptr_uint) -> vec.Vec[DocLine]:
    var docs = vec.Vec[DocLine].create()
    if decl_line < 2:
        return docs
    var collected = vec.Vec[DocLine].create()
    defer collected.release()
    var idx = decl_line - 2
    while true:
        let lp = lines.get(idx) else:
            break
        let line = unsafe: read(lp)
        let stripped = line.trim_ascii_whitespace()
        if stripped.len == 0 or not stripped.starts_with("##"):
            break
        collected.push(DocLine(line = idx + 1, text = strip_doc_prefix(stripped)))
        if idx == 0:
            break
        idx -= 1
    var k = collected.len()
    while k > 0:
        let cp = collected.get(k - 1) else:
            break
        docs.push(unsafe: read(cp))
        k -= 1
    return docs


## Drop the leading `##` and one optional whitespace from a stripped doc line.
function strip_doc_prefix(s: str) -> str:
    var i: ptr_uint = 2
    if i < s.len and dt_is_space(s.byte_at(i)):
        i += 1
    return s.slice(i, s.len - i)


## Parse `@tag payload` from a doc line; returns the lowercased tag + trimmed
## payload, or none when the line is not a well-formed tag.
function parse_doc_tag_line(text: str) -> Option[DocTagParse]:
    let t = text.trim_ascii_whitespace()
    if t.len == 0 or t.byte_at(0) != '@':
        return Option[DocTagParse].none
    if t.len < 2 or not dt_is_name_start(t.byte_at(1)):
        return Option[DocTagParse].none
    var j: ptr_uint = 2
    while j < t.len and dt_is_tag_char(t.byte_at(j)):
        j += 1
    let raw_tag = t.slice(1, j - 1)
    # After the tag: end of line, or whitespace followed by the payload.
    var payload = ""
    if j < t.len:
        if not dt_is_space(t.byte_at(j)):
            return Option[DocTagParse].none
        var k = j
        while k < t.len and dt_is_space(t.byte_at(k)):
            k += 1
        payload = t.slice(k, t.len - k).trim_ascii_whitespace()
    return Option[DocTagParse].some(value = DocTagParse(tag = dt_lowercase(raw_tag), payload = payload))


function dt_lowercase(s: str) -> str:
    var buf = string.String.create()
    var i: ptr_uint = 0
    while i < s.len:
        var b = s.byte_at(i)
        if b >= 'A' and b <= 'Z':
            b = b + 32
        buf.push_byte(b)
        i += 1
    return buf.as_str()


## Extract a valid leading parameter name from a payload, or none.
function parse_param_name(payload: str) -> Option[str]:
    if payload.len == 0 or not dt_is_name_start(payload.byte_at(0)):
        return Option[str].none
    var j: ptr_uint = 1
    while j < payload.len and dt_is_name_char(payload.byte_at(j)):
        j += 1
    if j < payload.len and not dt_is_space(payload.byte_at(j)):
        return Option[str].none
    return Option[str].some(value = payload.slice(0, j))


function param_names_of(params: span[ast.Param]) -> vec.Vec[str]:
    var names = vec.Vec[str].create()
    var i: ptr_uint = 0
    while i < params.len:
        unsafe:
            names.push(read(params.data + i).name)
        i += 1
    return names


function param_names_of_foreign(params: span[ast.ForeignParam]) -> vec.Vec[str]:
    var names = vec.Vec[str].create()
    var i: ptr_uint = 0
    while i < params.len:
        unsafe:
            names.push(read(params.data + i).name)
        i += 1
    return names


function names_contains(names: ref[vec.Vec[str]], name: str) -> bool:
    var i: ptr_uint = 0
    while i < names.len():
        let np = names.get(i) else:
            break
        if unsafe: read(np).equal(name):
            return true
        i += 1
    return false


## Parse and validate the doc block above a declaration.  `is_callable` /
## `param_names` / `return_type` describe function-like declarations.
function process_doc_definition(lines: ref[vec.Vec[str]], decl_line: ptr_uint, decl_name: str, is_callable: bool, param_names: ref[vec.Vec[str]], return_type: ptr[ast.TypeRef]?, path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    var docs = collect_doc_block(lines, decl_line)
    defer docs.release()
    if docs.len() == 0:
        return

    var param_tags = vec.Vec[DocParamTag].create()
    defer param_tags.release()
    var has_return = false
    var return_line: ptr_uint = 0

    var i: ptr_uint = 0
    while i < docs.len():
        let dlp = docs.get(i) else:
            break
        let dl = unsafe: read(dlp)
        match parse_doc_tag_line(dl.text):
            Option.some as parsed:
                let tag = parsed.value.tag
                let payload = parsed.value.payload
                if tag.equal("param"):
                    if payload.len == 0:
                        push_warning(warnings, path, dl.line, "doc-tag", "doc tag @param requires a parameter name", "hint")
                    else:
                        match parse_param_name(payload):
                            Option.some as pn:
                                param_tags.push(DocParamTag(name = pn.value, line = dl.line))
                            Option.none:
                                push_warning(warnings, path, dl.line, "doc-tag", "doc tag @param has an invalid parameter name", "hint")
                else if tag.equal("return") or tag.equal("returns"):
                    has_return = true
                    return_line = dl.line
                else if tag.equal("throws") or tag.equal("throw") or tag.equal("see"):
                    pass
                else:
                    var msg = string.String.create()
                    msg.append("unknown doc tag @")
                    msg.append(tag)
                    push_warning(warnings, path, dl.line, "doc-tag", msg.as_str(), "hint")
            Option.none:
                pass
        i += 1

    if not is_callable:
        var pi: ptr_uint = 0
        while pi < param_tags.len():
            let ptp = param_tags.get(pi) else:
                break
            let pt = unsafe: read(ptp)
            push_warning(warnings, path, pt.line, "doc-tag", "callable doc tags are only valid on function and method declarations", "hint")
            pi += 1
        if has_return:
            push_warning(warnings, path, return_line, "doc-tag", "callable doc tags are only valid on function and method declarations", "hint")
        return

    var pi: ptr_uint = 0
    while pi < param_tags.len():
        let ptp = param_tags.get(pi) else:
            break
        let pt = unsafe: read(ptp)
        if not names_contains(param_names, pt.name):
            var msg = string.String.create()
            msg.append("doc tag @param '")
            msg.append(pt.name)
            msg.append("' does not match any parameter in '")
            msg.append(decl_name)
            msg.append("'")
            push_warning(warnings, path, pt.line, "doc-tag", msg.as_str(), "hint")
        pi += 1

    if has_return and is_void_type(return_type):
        var msg = string.String.create()
        msg.append("doc tag @return is stale for '")
        msg.append(decl_name)
        msg.append("' because it returns void")
        push_warning(warnings, path, return_line, "doc-tag", msg.as_str(), "hint")


function lint_doc_tags(decls: span[ast.Decl], source: str, path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    var lines = split_lines(source)
    defer lines.release()
    var empty_names = vec.Vec[str].create()
    defer empty_names.release()

    var i: ptr_uint = 0
    while i < decls.len:
        unsafe:
            match read(decls.data + i):
                ast.Decl.decl_function as fun:
                    var pn = param_names_of(fun.method_params)
                    defer pn.release()
                    process_doc_definition(ref_of(lines), fun.line, fun.name, true, ref_of(pn), fun.return_type, path, warnings)
                ast.Decl.decl_extending_block as ex:
                    var j: ptr_uint = 0
                    while j < ex.methods.len:
                        let m = read(ex.methods.data + j)
                        var pn = param_names_of(m.method_params)
                        process_doc_definition(ref_of(lines), m.line, m.name, true, ref_of(pn), m.return_type, path, warnings)
                        pn.release()
                        j += 1
                ast.Decl.decl_extern_function as ef:
                    var pn = param_names_of_foreign(ef.extern_params)
                    defer pn.release()
                    process_doc_definition(ref_of(lines), ef.line, ef.name, true, ref_of(pn), ef.return_type, path, warnings)
                ast.Decl.decl_foreign_function as ff:
                    var pn = param_names_of_foreign(ff.foreign_params)
                    defer pn.release()
                    process_doc_definition(ref_of(lines), ff.line, ff.name, true, ref_of(pn), ff.return_type, path, warnings)
                ast.Decl.decl_const as c:
                    process_doc_definition(ref_of(lines), c.line, c.name, false, ref_of(empty_names), null, path, warnings)
                ast.Decl.decl_var as v:
                    process_doc_definition(ref_of(lines), v.line, v.name, false, ref_of(empty_names), null, path, warnings)
                ast.Decl.decl_struct as s:
                    process_doc_definition(ref_of(lines), s.line, s.name, false, ref_of(empty_names), null, path, warnings)
                ast.Decl.decl_union as u:
                    process_doc_definition(ref_of(lines), u.line, u.name, false, ref_of(empty_names), null, path, warnings)
                ast.Decl.decl_enum as e:
                    process_doc_definition(ref_of(lines), e.line, e.name, false, ref_of(empty_names), null, path, warnings)
                ast.Decl.decl_flags as f:
                    process_doc_definition(ref_of(lines), f.line, f.name, false, ref_of(empty_names), null, path, warnings)
                ast.Decl.decl_variant as va:
                    process_doc_definition(ref_of(lines), va.line, va.name, false, ref_of(empty_names), null, path, warnings)
                ast.Decl.decl_opaque as o:
                    process_doc_definition(ref_of(lines), o.line, o.name, false, ref_of(empty_names), null, path, warnings)
                ast.Decl.decl_type_alias as ta:
                    process_doc_definition(ref_of(lines), ta.line, ta.name, false, ref_of(empty_names), null, path, warnings)
                ast.Decl.decl_interface as iface:
                    process_doc_definition(ref_of(lines), iface.line, iface.name, false, ref_of(empty_names), null, path, warnings)
                ast.Decl.decl_event as ev:
                    process_doc_definition(ref_of(lines), ev.line, ev.name, false, ref_of(empty_names), null, path, warnings)
                ast.Decl.decl_attribute as at:
                    process_doc_definition(ref_of(lines), at.line, at.name, false, ref_of(empty_names), null, path, warnings)
                _:
                    pass
        i += 1


const EVENT_CAPACITY_THRESHOLD: int = 128


## Warn on event declarations whose capacity forces emit() to copy a large
## listener array onto the stack.  Recurses into struct and nested-struct
## events, in declaration order (after the AST-visitor warnings).
function lint_events(decls: span[ast.Decl], owner: str, path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    var i: ptr_uint = 0
    while i < decls.len:
        unsafe:
            match read(decls.data + i):
                ast.Decl.decl_event as ev:
                    if ev.capacity >= EVENT_CAPACITY_THRESHOLD:
                        warn_event_capacity(ev.name, owner, ev.capacity, ev.line, path, warnings)
                ast.Decl.decl_struct as s:
                    lint_events(s.struct_events, s.name, path, warnings)
                    lint_events(s.nested_types, s.name, path, warnings)
                _:
                    pass
        i += 1


function warn_event_capacity(name: str, owner: str, capacity: int, line: ptr_uint, path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    var label = string.String.create()
    defer label.release()
    if owner.len > 0:
        label.append(owner)
        label.append(".")
    label.append(name)
    var cap = int_to_decimal(capacity)
    defer cap.release()
    let cap_s = cap.as_str()
    var msg = string.String.create()
    msg.append("event '")
    msg.append(label.as_str())
    msg.append("' capacity ")
    msg.append(cap_s)
    msg.append(" makes emit() copy up to ")
    msg.append(cap_s)
    msg.append(" listeners onto the stack; prefer a smaller fixed capacity or a managed queue abstraction")
    push_warning(warnings, path, line, "event-capacity", msg.as_str(), "warning")


function int_to_decimal(n: int) -> string.String:
    if n <= 0:
        return string.String.from_str("0")
    var digits = string.String.create()
    defer digits.release()
    var v = n
    while v > 0:
        digits.push_byte(ubyte<-(48 + (v % 10)))
        v = v / 10
    var result = string.String.create()
    let ds = digits.as_str()
    var i = ds.len
    while i > 0:
        result.push_byte(ds.byte_at(i - 1))
        i -= 1
    return result


function push_warning(warnings: ref[vec.Vec[Warning]], path: str, line: ptr_uint, code: str, message: str, severity: str) -> void:
    warnings.push(Warning(path = path, line = line, code = code, message = message, severity = severity))


# =============================================================================
#  Line resolution — descend to the first sub-expression that carries a line.
# =============================================================================

function expression_line(expr: ptr[ast.Expr]?) -> ptr_uint:
    let ep = expr else:
        return 0
    unsafe:
        match read(ep):
            ast.Expr.expr_identifier as id:
                return id.line
            ast.Expr.expr_char_literal as ch:
                return ch.line
            ast.Expr.expr_member_access as m:
                return m.line
            ast.Expr.expr_match as mm:
                return mm.line
            ast.Expr.expr_null_literal as nl:
                return nl.line
            ast.Expr.expr_detach as dt:
                return dt.line
            ast.Expr.expr_expression_list as el:
                return el.line
            ast.Expr.expr_range as rg:
                return rg.line
            ast.Expr.expr_prefix_cast as pc:
                return pc.line
            ast.Expr.expr_unsafe as us:
                return us.line
            ast.Expr.expr_error as er:
                return er.line
            ast.Expr.expr_binary_op as b:
                let l = expression_line(b.left)
                if l != 0:
                    return l
                return expression_line(b.right)
            ast.Expr.expr_unary_op as u:
                return expression_line(u.operand)
            ast.Expr.expr_call as call:
                return expression_line(call.callee)
            ast.Expr.expr_index_access as ix:
                let l = expression_line(ix.receiver)
                if l != 0:
                    return l
                return expression_line(ix.index)
            ast.Expr.expr_specialization as sp:
                return expression_line(sp.callee)
            ast.Expr.expr_if as iff:
                let l = expression_line(iff.condition)
                if l != 0:
                    return l
                return expression_line(iff.then_expr)
            ast.Expr.expr_await as aw:
                return expression_line(aw.expression)
            _:
                return 0


function expression_column(expr: ptr[ast.Expr]?) -> ptr_uint:
    let ep = expr else:
        return 0
    unsafe:
        match read(ep):
            ast.Expr.expr_identifier as id:
                return id.column
            ast.Expr.expr_char_literal as ch:
                return ch.column
            ast.Expr.expr_member_access as m:
                return expression_column(m.receiver)
            ast.Expr.expr_match as mm:
                return mm.column
            ast.Expr.expr_null_literal as nl:
                return nl.column
            ast.Expr.expr_detach as dt:
                return dt.column
            ast.Expr.expr_expression_list as el:
                return el.column
            ast.Expr.expr_range as rg:
                return rg.column
            ast.Expr.expr_prefix_cast as pc:
                return pc.column
            ast.Expr.expr_unsafe as us:
                return us.column
            ast.Expr.expr_error as er:
                return er.column
            ast.Expr.expr_binary_op as b:
                let l = expression_column(b.left)
                if l != 0:
                    return l
                return expression_column(b.right)
            ast.Expr.expr_unary_op as u:
                return expression_column(u.operand)
            ast.Expr.expr_call as call:
                return expression_column(call.callee)
            ast.Expr.expr_index_access as ix:
                return expression_column(ix.receiver)
            ast.Expr.expr_specialization as sp:
                return expression_column(sp.callee)
            ast.Expr.expr_if as iff:
                let c = expression_column(iff.condition)
                if c != 0:
                    return c
                return expression_column(iff.then_expr)
            ast.Expr.expr_await as aw:
                return expression_column(aw.expression)
            _:
                return 0


# =============================================================================
#  trailing-list-comma (token-based) — a redundant comma before a call's `)`.
# =============================================================================

## Combine a line and column into a single map key.  Columns are well below
## 1_000_000 in any realistic source line.
function location_key(line: ptr_uint, column: ptr_uint) -> ptr_uint:
    return line * 1000000 + column


function lint_trailing_commas(decls: span[ast.Decl], source: str, path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    var tokens = lexer.lex(source)
    defer tokens.release()
    let ts = tokens.as_span()

    # Map each token's (line, column) to its index, first-occurrence wins.
    var loc_index = map_mod.Map[ptr_uint, ptr_uint].create()
    defer loc_index.release()
    var i: ptr_uint = 0
    while i < ts.len:
        unsafe:
            let t = read(ts.data + i)
            let key = location_key(t.line, t.column)
            if not loc_index.contains(key):
                loc_index.set(key, i)
        i += 1

    # Dedup by comma site so a call reached via multiple walks warns once.
    var warned = map_mod.Map[ptr_uint, bool].create()
    defer warned.release()

    var di: ptr_uint = 0
    while di < decls.len:
        unsafe:
            match read(decls.data + di):
                ast.Decl.decl_const as c:
                    tc_expr_opt(c.value, ts, ref_of(loc_index), ref_of(warned), path, warnings)
                ast.Decl.decl_var as v:
                    tc_expr_opt(v.value, ts, ref_of(loc_index), ref_of(warned), path, warnings)
                ast.Decl.decl_function as fun:
                    tc_body(fun.body, ts, ref_of(loc_index), ref_of(warned), path, warnings)
                ast.Decl.decl_extending_block as ex:
                    var j: ptr_uint = 0
                    while j < ex.methods.len:
                        tc_body(read(ex.methods.data + j).body, ts, ref_of(loc_index), ref_of(warned), path, warnings)
                        j += 1
                _:
                    pass
        di += 1


## Report the trailing comma before the matching `)` of `call`, if any.
function check_trailing_comma(callee: ptr[ast.Expr], args: span[ast.Argument], ts: span[token_mod.Token], loc_index: ref[map_mod.Map[ptr_uint, ptr_uint]], warned: ref[map_mod.Map[ptr_uint, bool]], path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    if args.len == 0:
        return
    let callee_line = expression_line(callee)
    let callee_col = expression_column(callee)
    if callee_line == 0 or callee_col == 0:
        return
    let idx_ptr = loc_index.get(location_key(callee_line, callee_col)) else:
        return
    let callee_idx = unsafe: read(idx_ptr)

    # Find the opening paren after the callee.
    var lparen_idx: ptr_uint = 0
    var have_lparen = false
    var cursor = callee_idx
    while cursor < ts.len:
        unsafe:
            let t = read(ts.data + cursor)
            if t.kind == tk.TokenKind.lparen:
                lparen_idx = cursor
                have_lparen = true
                break
            if t.kind == tk.TokenKind.newline and t.line > callee_line:
                break
        cursor += 1
    if not have_lparen:
        return

    # Track a comma seen at depth 0; a non-trivia token clears it, so it only
    # survives if it sits immediately before the closing paren.
    var paren_depth: int = 0
    var bracket_depth: int = 0
    var have_comma = false
    var comma_line: ptr_uint = 0
    var comma_col: ptr_uint = 0
    cursor = lparen_idx + 1
    while cursor < ts.len:
        unsafe:
            let t = read(ts.data + cursor)
            let k = t.kind
            if k == tk.TokenKind.lparen:
                paren_depth += 1
            else if k == tk.TokenKind.rparen:
                if paren_depth == 0 and bracket_depth == 0:
                    if have_comma:
                        let key = location_key(comma_line, comma_col)
                        if not warned.contains(key):
                            warned.set(key, true)
                            push_warning(warnings, path, comma_line, "trailing-list-comma", "trailing comma in call argument list is redundant", "hint")
                    return
                if paren_depth > 0:
                    paren_depth -= 1
            else if k == tk.TokenKind.lbracket:
                bracket_depth += 1
            else if k == tk.TokenKind.rbracket:
                if bracket_depth > 0:
                    bracket_depth -= 1
            else if k == tk.TokenKind.comma:
                if paren_depth == 0 and bracket_depth == 0:
                    have_comma = true
                    comma_line = t.line
                    comma_col = t.column
            else:
                if paren_depth == 0 and bracket_depth == 0 and not is_trivia_token(k):
                    have_comma = false
        cursor += 1


function is_trivia_token(k: tk.TokenKind) -> bool:
    return k == tk.TokenKind.newline or k == tk.TokenKind.indent or k == tk.TokenKind.dedent or k == tk.TokenKind.eof


function tc_expr_opt(expr: ptr[ast.Expr]?, ts: span[token_mod.Token], loc_index: ref[map_mod.Map[ptr_uint, ptr_uint]], warned: ref[map_mod.Map[ptr_uint, bool]], path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    let ep = expr else:
        return
    tc_expr(ep, ts, loc_index, warned, path, warnings)


function tc_expr(expr: ptr[ast.Expr], ts: span[token_mod.Token], loc_index: ref[map_mod.Map[ptr_uint, ptr_uint]], warned: ref[map_mod.Map[ptr_uint, bool]], path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    unsafe:
        match read(expr):
            ast.Expr.expr_call as call:
                check_trailing_comma(call.callee, call.args, ts, loc_index, warned, path, warnings)
                tc_expr(call.callee, ts, loc_index, warned, path, warnings)
                var i: ptr_uint = 0
                while i < call.args.len:
                    tc_expr(read(call.args.data + i).arg_value, ts, loc_index, warned, path, warnings)
                    i += 1
            ast.Expr.expr_binary_op as b:
                tc_expr(b.left, ts, loc_index, warned, path, warnings)
                tc_expr(b.right, ts, loc_index, warned, path, warnings)
            ast.Expr.expr_unary_op as u:
                tc_expr(u.operand, ts, loc_index, warned, path, warnings)
            ast.Expr.expr_member_access as m:
                tc_expr(m.receiver, ts, loc_index, warned, path, warnings)
            ast.Expr.expr_index_access as ix:
                tc_expr(ix.receiver, ts, loc_index, warned, path, warnings)
                tc_expr(ix.index, ts, loc_index, warned, path, warnings)
            ast.Expr.expr_specialization as sp:
                tc_expr(sp.callee, ts, loc_index, warned, path, warnings)
            ast.Expr.expr_if as iff:
                tc_expr(iff.condition, ts, loc_index, warned, path, warnings)
                tc_expr(iff.then_expr, ts, loc_index, warned, path, warnings)
                tc_expr(iff.else_expr, ts, loc_index, warned, path, warnings)
            ast.Expr.expr_match as mm:
                tc_expr(mm.scrutinee, ts, loc_index, warned, path, warnings)
                var ai: ptr_uint = 0
                while ai < mm.arms.len:
                    tc_expr(read(mm.arms.data + ai).value, ts, loc_index, warned, path, warnings)
                    ai += 1
            ast.Expr.expr_proc as pr:
                tc_body(pr.body, ts, loc_index, warned, path, warnings)
            ast.Expr.expr_await as aw:
                tc_expr(aw.expression, ts, loc_index, warned, path, warnings)
            ast.Expr.expr_detach as dt:
                tc_expr(dt.expression, ts, loc_index, warned, path, warnings)
            ast.Expr.expr_named as nm:
                tc_expr(nm.value, ts, loc_index, warned, path, warnings)
            ast.Expr.expr_range as rg:
                tc_expr(rg.start_expr, ts, loc_index, warned, path, warnings)
                tc_expr(rg.end_expr, ts, loc_index, warned, path, warnings)
            ast.Expr.expr_prefix_cast as pc:
                tc_expr(pc.expression, ts, loc_index, warned, path, warnings)
            ast.Expr.expr_unsafe as us:
                tc_expr(us.expression, ts, loc_index, warned, path, warnings)
            ast.Expr.expr_expression_list as el:
                var ei: ptr_uint = 0
                while ei < el.elements.len:
                    tc_expr(el.elements.data + ei, ts, loc_index, warned, path, warnings)
                    ei += 1
            _:
                pass


## Faithful port of Ruby's walk_statement_lists: process a list's direct-
## statement expressions, then recurse into nested statement lists.  Combined
## with the `warned` dedup this reproduces Ruby's exact warning order.
function tc_body(body: ptr[ast.Stmt]?, ts: span[token_mod.Token], loc_index: ref[map_mod.Map[ptr_uint, ptr_uint]], warned: ref[map_mod.Map[ptr_uint, bool]], path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    let bp = body else:
        return
    unsafe:
        match read(bp):
            ast.Stmt.stmt_block as blk:
                tc_statement_list(blk.statements, ts, loc_index, warned, path, warnings)
            _:
                tc_each_statement_expression(bp, ts, loc_index, warned, path, warnings)
                tc_recurse_statement(bp, ts, loc_index, warned, path, warnings)


function tc_statement_list(stmts: span[ast.Stmt], ts: span[token_mod.Token], loc_index: ref[map_mod.Map[ptr_uint, ptr_uint]], warned: ref[map_mod.Map[ptr_uint, bool]], path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    var i: ptr_uint = 0
    while i < stmts.len:
        unsafe:
            tc_each_statement_expression(stmts.data + i, ts, loc_index, warned, path, warnings)
        i += 1
    i = 0
    while i < stmts.len:
        unsafe:
            tc_recurse_statement(stmts.data + i, ts, loc_index, warned, path, warnings)
        i += 1


function tc_recurse_statement(stmt: ptr[ast.Stmt], ts: span[token_mod.Token], loc_index: ref[map_mod.Map[ptr_uint, ptr_uint]], warned: ref[map_mod.Map[ptr_uint, bool]], path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    unsafe:
        match read(stmt):
            ast.Stmt.stmt_if as iff:
                var bi: ptr_uint = 0
                while bi < iff.branches.len:
                    tc_body(read(iff.branches.data + bi).body, ts, loc_index, warned, path, warnings)
                    bi += 1
                tc_body(iff.else_body, ts, loc_index, warned, path, warnings)
            ast.Stmt.stmt_match as mt:
                var ai: ptr_uint = 0
                while ai < mt.arms.len:
                    tc_body(read(mt.arms.data + ai).body, ts, loc_index, warned, path, warnings)
                    ai += 1
            ast.Stmt.stmt_unsafe as un:
                tc_body(un.body, ts, loc_index, warned, path, warnings)
            ast.Stmt.stmt_for as fr:
                tc_body(fr.body, ts, loc_index, warned, path, warnings)
            ast.Stmt.stmt_while as wh:
                tc_body(wh.body, ts, loc_index, warned, path, warnings)
            ast.Stmt.stmt_defer as df:
                tc_body(df.body, ts, loc_index, warned, path, warnings)
            _:
                pass


## The direct expressions of a statement (Ruby's each_statement_expression) —
## does not descend into nested statement bodies, except for the transparent
## `when` / `unsafe` / error blocks.
function tc_each_statement_expression(stmt: ptr[ast.Stmt], ts: span[token_mod.Token], loc_index: ref[map_mod.Map[ptr_uint, ptr_uint]], warned: ref[map_mod.Map[ptr_uint, bool]], path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    unsafe:
        match read(stmt):
            ast.Stmt.stmt_local as loc:
                tc_expr_opt(loc.value, ts, loc_index, warned, path, warnings)
            ast.Stmt.stmt_assignment as asgn:
                tc_expr(asgn.target, ts, loc_index, warned, path, warnings)
                tc_expr(asgn.value, ts, loc_index, warned, path, warnings)
            ast.Stmt.stmt_if as iff:
                var bi: ptr_uint = 0
                while bi < iff.branches.len:
                    tc_expr(read(iff.branches.data + bi).condition, ts, loc_index, warned, path, warnings)
                    bi += 1
            ast.Stmt.stmt_while as wh:
                tc_expr(wh.condition, ts, loc_index, warned, path, warnings)
            ast.Stmt.stmt_for as fr:
                var ii: ptr_uint = 0
                while ii < fr.iterables.len:
                    tc_expr(fr.iterables.data + ii, ts, loc_index, warned, path, warnings)
                    ii += 1
            ast.Stmt.stmt_match as mt:
                tc_expr(mt.scrutinee, ts, loc_index, warned, path, warnings)
            ast.Stmt.stmt_ret as r:
                tc_expr_opt(r.value, ts, loc_index, warned, path, warnings)
            ast.Stmt.stmt_defer as df:
                tc_expr_opt(df.expression, ts, loc_index, warned, path, warnings)
            ast.Stmt.stmt_expression as ex:
                tc_expr(ex.expression, ts, loc_index, warned, path, warnings)
            ast.Stmt.stmt_static_assert as sa:
                tc_expr(sa.condition, ts, loc_index, warned, path, warnings)
            ast.Stmt.stmt_when as wn:
                tc_expr(wn.discriminant, ts, loc_index, warned, path, warnings)
                var wbi: ptr_uint = 0
                while wbi < wn.branches.len:
                    let br = read(wn.branches.data + wbi)
                    var wsi: ptr_uint = 0
                    while wsi < br.body.len:
                        tc_each_statement_expression(br.body.data + wsi, ts, loc_index, warned, path, warnings)
                        wsi += 1
                    wbi += 1
                tc_each_stmt_expr_in_body(wn.else_body, ts, loc_index, warned, path, warnings)
            ast.Stmt.stmt_unsafe as un:
                tc_each_stmt_expr_in_body(un.body, ts, loc_index, warned, path, warnings)
            ast.Stmt.stmt_error_block as eb:
                tc_each_statement_expression(eb.body, ts, loc_index, warned, path, warnings)
            _:
                pass


function tc_each_stmt_expr_in_body(body: ptr[ast.Stmt]?, ts: span[token_mod.Token], loc_index: ref[map_mod.Map[ptr_uint, ptr_uint]], warned: ref[map_mod.Map[ptr_uint, bool]], path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    let bp = body else:
        return
    unsafe:
        match read(bp):
            ast.Stmt.stmt_block as blk:
                var i: ptr_uint = 0
                while i < blk.statements.len:
                    tc_each_statement_expression(blk.statements.data + i, ts, loc_index, warned, path, warnings)
                    i += 1
            _:
                tc_each_statement_expression(bp, ts, loc_index, warned, path, warnings)



# =============================================================================
#  Rules
# =============================================================================

function is_identifier(expr: ptr[ast.Expr]) -> Option[str]:
    unsafe:
        match read(expr):
            ast.Expr.expr_identifier as id:
                return Option[str].some(value = id.name)
            _:
                return Option[str].none


function bool_literal_of(expr: ptr[ast.Expr]) -> Option[bool]:
    unsafe:
        match read(expr):
            ast.Expr.expr_bool_literal as b:
                return Option[bool].some(value = b.value)
            _:
                return Option[bool].none


## `x = x` — a variable assigned to itself.
function check_self_assignment(target: ptr[ast.Expr], operator: str, value: ptr[ast.Expr], path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    if operator != "=":
        return
    let target_name = is_identifier(target) else:
        return
    let value_name = is_identifier(value) else:
        return
    if not target_name.equal(value_name):
        return
    var buf = string.String.create()
    buf.append("'")
    buf.append(target_name)
    buf.append("' is assigned to itself")
    push_warning(warnings, path, expression_line(target), "self-assignment", buf.as_str(), "warning")


## `x == x` / `x != x` — a variable compared to itself.
function check_self_comparison(operator: str, left: ptr[ast.Expr], right: ptr[ast.Expr], path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    if operator != "==" and operator != "!=":
        return
    let left_name = is_identifier(left) else:
        return
    let right_name = is_identifier(right) else:
        return
    if not left_name.equal(right_name):
        return
    let always = if operator == "==": "always true" else: "always false"
    var buf = string.String.create()
    buf.append("'")
    buf.append(left_name)
    buf.append("' is compared to itself — ")
    buf.append(always)
    push_warning(warnings, path, expression_line(left), "self-comparison", buf.as_str(), "warning")


## `x == true` / `x != false` and friends — comparison against a boolean literal.
function check_redundant_bool_compare(operator: str, left: ptr[ast.Expr], right: ptr[ast.Expr], path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    if operator != "==" and operator != "!=":
        return
    let left_bool = bool_literal_of(left)
    let right_bool = bool_literal_of(right)
    # Exactly one side must be a boolean literal.
    if left_bool.is_some() == right_bool.is_some():
        return

    let literal_value = if left_bool.is_some(): left_bool.unwrap() else: right_bool.unwrap()
    var use_directly = false
    if operator == "==":
        use_directly = literal_value
    else:
        use_directly = not literal_value
    let suggestion = if use_directly: "use the expression directly" else: "invert the expression with 'not'"

    var buf = string.String.create()
    buf.append("boolean comparison against literal is redundant; ")
    buf.append(suggestion)
    let line = if left_bool.is_some(): expression_line(right) else: expression_line(left)
    push_warning(warnings, path, line, "redundant-bool-compare", buf.as_str(), "hint")


## A pure expression statement with no side effects has a useless result.
function is_pure_expression(expr: ptr[ast.Expr]) -> bool:
    unsafe:
        match read(expr):
            ast.Expr.expr_integer_literal:
                return true
            ast.Expr.expr_float_literal:
                return true
            ast.Expr.expr_string_literal:
                return true
            ast.Expr.expr_format_string:
                return true
            ast.Expr.expr_bool_literal:
                return true
            ast.Expr.expr_null_literal:
                return true
            ast.Expr.expr_binary_op:
                return true
            ast.Expr.expr_unary_op:
                return true
            ast.Expr.expr_identifier:
                return true
            ast.Expr.expr_unsafe:
                return true
            _:
                return false


## True when `expr` contains a call, await, or `?` propagation — mirrors the
## Ruby `contains_side_effecting_expression?` (note: it does NOT descend into a
## plain unary operand).
function contains_side_effect(expr: ptr[ast.Expr]) -> bool:
    unsafe:
        match read(expr):
            ast.Expr.expr_call:
                return true
            ast.Expr.expr_await:
                return true
            ast.Expr.expr_unary_op as u:
                return u.operator == "?"
            ast.Expr.expr_binary_op as b:
                if contains_side_effect(b.left):
                    return true
                return contains_side_effect(b.right)
            ast.Expr.expr_unsafe as us:
                return contains_side_effect(us.expression)
            ast.Expr.expr_format_string as fs:
                var i: ptr_uint = 0
                while i < fs.parts.len:
                    match read(fs.parts.data + i):
                        ast.FormatStringPart.fmt_expr as fe:
                            if contains_side_effect(fe.expression):
                                return true
                        _:
                            pass
                    i += 1
                return false
            _:
                return false


function check_useless_expression(expr: ptr[ast.Expr], stmt_line: ptr_uint, path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    if not is_pure_expression(expr):
        return
    unsafe:
        match read(expr):
            ast.Expr.expr_unary_op as u:
                if u.operator == "?":
                    return
            _:
                pass
    if contains_side_effect(expr):
        return
    var line = expression_line(expr)
    if line == 0:
        line = stmt_line
    push_warning(warnings, path, line, "useless-expression", "expression result is unused and has no side effects", "warning")


## Compound assignment against an identity value (`x += 0`, `x *= 1`).
function check_noop_compound_assignment(target: ptr[ast.Expr], operator: str, value: ptr[ast.Expr], path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    var is_identity = false
    if operator == "+=" or operator == "-=" or operator == "|=" or operator == "^=" or operator == "<<=" or operator == ">>=":
        is_identity = integer_literal_matches(value, "0")
    else if operator == "*=" or operator == "/=":
        is_identity = numeric_literal_one(value)
    if is_identity:
        push_warning(warnings, path, expression_line(target), "noop-compound-assignment", "compound assignment with identity value has no effect", "hint")


function lexeme_without_underscores(lexeme: str) -> string.String:
    var b = string.String.create()
    var i: ptr_uint = 0
    while i < lexeme.len:
        let c = lexeme.byte_at(i)
        if c != 95:
            b.push_byte(c)
        i += 1
    return b


function integer_literal_matches(value: ptr[ast.Expr], target: str) -> bool:
    unsafe:
        match read(value):
            ast.Expr.expr_integer_literal as il:
                var stripped = lexeme_without_underscores(il.lexeme)
                defer stripped.release()
                return stripped.as_str().equal(target)
            _:
                return false


function numeric_literal_one(value: ptr[ast.Expr]) -> bool:
    if integer_literal_matches(value, "1"):
        return true
    unsafe:
        match read(value):
            ast.Expr.expr_float_literal as fl:
                var stripped = lexeme_without_underscores(fl.lexeme)
                defer stripped.release()
                let s = stripped.as_str()
                return s.equal("1.0") or s.equal("1.")
            _:
                return false


## Duplicate condition across the branches of one if/else-if chain.
function check_duplicate_if_conditions(branches: span[ast.IfBranch], path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    var seen = vec.Vec[str].create()
    defer seen.release()
    var bi: ptr_uint = 0
    while bi < branches.len:
        unsafe:
            let br = read(branches.data + bi)
            match expression_signature(br.condition):
                Option.some as sig:
                    var dup = false
                    var k: ptr_uint = 0
                    while k < seen.len():
                        let sp = seen.get(k) else:
                            break
                        if read(sp).equal(sig.value):
                            dup = true
                            break
                        k += 1
                    if dup:
                        var line = expression_line(br.condition)
                        if line == 0:
                            line = br.line
                        push_warning(warnings, path, line, "duplicate-if-condition", "duplicate condition matches an earlier if/else-if branch and is unreachable", "warning")
                    else:
                        seen.push(sig.value)
                Option.none:
                    pass
        bi += 1


## A structural signature string for a condition, used to detect duplicate
## branches.  None for expressions the signature does not model.
function expression_signature(expr: ptr[ast.Expr]) -> Option[str]:
    unsafe:
        match read(expr):
            ast.Expr.expr_identifier as id:
                var b = string.String.create()
                b.append("id:")
                b.append(id.name)
                return Option[str].some(value = b.as_str())
            ast.Expr.expr_bool_literal as bl:
                var b = string.String.create()
                b.append("bool:")
                b.append(if bl.value: "true" else: "false")
                return Option[str].some(value = b.as_str())
            ast.Expr.expr_integer_literal as il:
                var b = string.String.create()
                b.append("lit:")
                b.append(il.lexeme)
                return Option[str].some(value = b.as_str())
            ast.Expr.expr_float_literal as fl:
                var b = string.String.create()
                b.append("lit:")
                b.append(fl.lexeme)
                return Option[str].some(value = b.as_str())
            ast.Expr.expr_string_literal as sl:
                var b = string.String.create()
                b.append("lit:")
                b.append(sl.lexeme)
                return Option[str].some(value = b.as_str())
            ast.Expr.expr_null_literal:
                return Option[str].some(value = "null")
            ast.Expr.expr_member_access as m:
                let recv = expression_signature(m.receiver) else:
                    return Option[str].none
                var b = string.String.create()
                b.append("member:(")
                b.append(recv)
                b.append(").")
                b.append(m.member_name)
                return Option[str].some(value = b.as_str())
            ast.Expr.expr_unary_op as u:
                let operand = expression_signature(u.operand) else:
                    return Option[str].none
                var b = string.String.create()
                b.append("unary:")
                b.append(u.operator)
                b.append("(")
                b.append(operand)
                b.append(")")
                return Option[str].some(value = b.as_str())
            ast.Expr.expr_binary_op as bo:
                let l = expression_signature(bo.left) else:
                    return Option[str].none
                let r = expression_signature(bo.right) else:
                    return Option[str].none
                var b = string.String.create()
                b.append("binary:(")
                b.append(l)
                b.append(")")
                b.append(bo.operator)
                b.append("(")
                b.append(r)
                b.append(")")
                return Option[str].some(value = b.as_str())
            _:
                return Option[str].none


## `Variant.arm as _` — an ignored match binding is redundant.
function warn_redundant_ignored_match_binding(binding_name: Option[str], binding_line: ptr_uint, fallback_line: ptr_uint, path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    match binding_name:
        Option.some as bn:
            if bn.value.equal("_"):
                let line = if binding_line != 0: binding_line else: fallback_line
                push_warning(warnings, path, line, "redundant-ignored-match-binding", "ignored match binding is redundant; remove 'as _'", "hint")
        Option.none:
            pass


## Final bare `return` in an explicit `-> void` body is redundant.
function check_redundant_return(return_type: ptr[ast.TypeRef]?, body: ptr[ast.Stmt]?, path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    if not is_void_type(return_type):
        return
    let last = last_block_statement(body) else:
        return
    unsafe:
        match read(last):
            ast.Stmt.stmt_ret as r:
                if r.value == null:
                    push_warning(warnings, path, r.line, "redundant-return", "final bare return in void function is redundant", "hint")
            _:
                pass


function is_void_type(return_type: ptr[ast.TypeRef]?) -> bool:
    let rp = return_type else:
        return false
    unsafe:
        let t = read(rp)
        if t.nullable:
            return false
        if t.name.parts.len != 1:
            return false
        return read(t.name.parts.data + 0) == "void"


function last_block_statement(body: ptr[ast.Stmt]?) -> ptr[ast.Stmt]?:
    let bp = body else:
        return null
    unsafe:
        match read(bp):
            ast.Stmt.stmt_block as blk:
                if blk.statements.len == 0:
                    return null
                return blk.statements.data + blk.statements.len - 1
            _:
                return null


# =============================================================================
#  redundant-else — flag an else block when every if/else-if branch returns.
# =============================================================================

## A call/specialization to `fatal` or `static_assert(false)` never returns.
function terminating_expression(expr: ptr[ast.Expr]) -> bool:
    unsafe:
        match read(expr):
            ast.Expr.expr_call as call:
                if terminating_callee(call.callee):
                    return true
                return static_assert_false(call.callee, call.args)
            ast.Expr.expr_specialization as sp:
                return terminating_callee(sp.callee)
            _:
                return false


function terminating_callee(callee: ptr[ast.Expr]) -> bool:
    unsafe:
        match read(callee):
            ast.Expr.expr_identifier as id:
                return id.name == "fatal"
            ast.Expr.expr_specialization as sp:
                return terminating_callee(sp.callee)
            _:
                return false


function static_assert_false(callee: ptr[ast.Expr], args: span[ast.Argument]) -> bool:
    unsafe:
        match read(callee):
            ast.Expr.expr_identifier as id:
                if id.name != "static_assert" or args.len == 0:
                    return false
                match read(read(args.data + 0).arg_value):
                    ast.Expr.expr_bool_literal as b:
                        return not b.value
                    _:
                        return false
            _:
                return false


## A `break` that would exit *this* loop — descends into conditionals but not
## into nested loops (whose breaks belong to them).
function stmt_can_break(stmt: ptr[ast.Stmt]) -> bool:
    unsafe:
        match read(stmt):
            ast.Stmt.stmt_break:
                return true
            ast.Stmt.stmt_block as blk:
                return stmts_can_break(blk.statements)
            ast.Stmt.stmt_local as loc:
                return body_can_break(loc.else_body)
            ast.Stmt.stmt_if as iff:
                var bi: ptr_uint = 0
                while bi < iff.branches.len:
                    if body_can_break(read(iff.branches.data + bi).body):
                        return true
                    bi += 1
                return body_can_break(iff.else_body)
            ast.Stmt.stmt_match as mt:
                var ai: ptr_uint = 0
                while ai < mt.arms.len:
                    if body_can_break(read(mt.arms.data + ai).body):
                        return true
                    ai += 1
                return false
            ast.Stmt.stmt_when as wn:
                var wi: ptr_uint = 0
                while wi < wn.branches.len:
                    if stmts_can_break(read(wn.branches.data + wi).body):
                        return true
                    wi += 1
                return body_can_break(wn.else_body)
            ast.Stmt.stmt_unsafe as un:
                return body_can_break(un.body)
            ast.Stmt.stmt_defer as df:
                return body_can_break(df.body)
            _:
                return false


function stmts_can_break(stmts: span[ast.Stmt]) -> bool:
    var i: ptr_uint = 0
    while i < stmts.len:
        unsafe:
            if stmt_can_break(stmts.data + i):
                return true
        i += 1
    return false


function body_can_break(body: ptr[ast.Stmt]?) -> bool:
    let bp = body else:
        return false
    return stmt_can_break(bp)


function is_true_literal(expr: ptr[ast.Expr]) -> bool:
    unsafe:
        match read(expr):
            ast.Expr.expr_bool_literal as b:
                return b.value
            _:
                return false


## Mirrors the Ruby linter's `always_returns?` over a statement list: true when
## some statement unconditionally returns/terminates.
function always_returns_stmts(stmts: span[ast.Stmt]) -> bool:
    var i: ptr_uint = 0
    while i < stmts.len:
        unsafe:
            if stmt_always_returns(stmts.data + i):
                return true
        i += 1
    return false


function always_returns_body(body: ptr[ast.Stmt]?) -> bool:
    let bp = body else:
        return false
    unsafe:
        match read(bp):
            ast.Stmt.stmt_block as blk:
                return always_returns_stmts(blk.statements)
            _:
                return stmt_always_returns(bp)


function block_is_nonempty(body: ptr[ast.Stmt]?) -> bool:
    let bp = body else:
        return false
    unsafe:
        match read(bp):
            ast.Stmt.stmt_block as blk:
                return blk.statements.len > 0
            _:
                return true


function stmt_always_returns(stmt: ptr[ast.Stmt]) -> bool:
    unsafe:
        match read(stmt):
            ast.Stmt.stmt_ret:
                return true
            ast.Stmt.stmt_expression as ex:
                return terminating_expression(ex.expression)
            ast.Stmt.stmt_if as iff:
                if not block_is_nonempty(iff.else_body):
                    return false
                var bi: ptr_uint = 0
                while bi < iff.branches.len:
                    if not always_returns_body(read(iff.branches.data + bi).body):
                        return false
                    bi += 1
                return always_returns_body(iff.else_body)
            ast.Stmt.stmt_while as wh:
                return is_true_literal(wh.condition) and not body_can_break(wh.body)
            ast.Stmt.stmt_match as mt:
                if mt.arms.len == 0:
                    return false
                var ai: ptr_uint = 0
                while ai < mt.arms.len:
                    if not always_returns_body(read(mt.arms.data + ai).body):
                        return false
                    ai += 1
                return true
            ast.Stmt.stmt_when as wn:
                var any_branch = false
                var wi: ptr_uint = 0
                while wi < wn.branches.len:
                    any_branch = true
                    if not always_returns_stmts(read(wn.branches.data + wi).body):
                        return false
                    wi += 1
                if block_is_nonempty(wn.else_body):
                    any_branch = true
                    if not always_returns_body(wn.else_body):
                        return false
                return any_branch
            ast.Stmt.stmt_static_assert as sa:
                return is_false_literal(sa.condition)
            ast.Stmt.stmt_unsafe as un:
                return always_returns_body(un.body)
            _:
                return false


function is_false_literal(expr: ptr[ast.Expr]) -> bool:
    unsafe:
        match read(expr):
            ast.Expr.expr_bool_literal as b:
                return not b.value
            _:
                return false


function first_block_statement_line(body: ptr[ast.Stmt]?) -> ptr_uint:
    let bp = body else:
        return 0
    unsafe:
        match read(bp):
            ast.Stmt.stmt_block as blk:
                if blk.statements.len == 0:
                    return 0
                return statement_line(blk.statements.data + 0)
            _:
                return statement_line(bp)


function statement_line(stmt: ptr[ast.Stmt]) -> ptr_uint:
    unsafe:
        match read(stmt):
            ast.Stmt.stmt_ret as r:
                return r.line
            ast.Stmt.stmt_if as iff:
                return iff.line
            ast.Stmt.stmt_while as wh:
                return wh.line
            ast.Stmt.stmt_for as fr:
                return fr.line
            ast.Stmt.stmt_match as mt:
                return mt.line
            ast.Stmt.stmt_expression as ex:
                return expression_line(ex.expression)
            ast.Stmt.stmt_local as loc:
                return loc.line
            ast.Stmt.stmt_break as bk:
                return bk.line
            ast.Stmt.stmt_continue as ct:
                return ct.line
            ast.Stmt.stmt_pass as ps:
                return ps.line
            ast.Stmt.stmt_defer as df:
                return df.line
            ast.Stmt.stmt_unsafe as un:
                return un.line
            _:
                return 0


## Every if/else-if branch returns, so the else block is unnecessary nesting.
function check_redundant_else(branches: span[ast.IfBranch], else_body: ptr[ast.Stmt]?, else_line: ptr_uint, path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    if not block_is_nonempty(else_body):
        return
    var bi: ptr_uint = 0
    while bi < branches.len:
        unsafe:
            if not always_returns_body(read(branches.data + bi).body):
                return
        bi += 1
    var line = else_line
    if line == 0:
        line = first_block_statement_line(else_body)
    push_warning(warnings, path, line, "redundant-else", "else block is redundant because all preceding branches return", "hint")


# =============================================================================
#  Traversal
# =============================================================================

function visit_decl(decl: ptr[ast.Decl], path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    unsafe:
        match read(decl):
            ast.Decl.decl_function as fun:
                visit_stmt_opt(fun.body, path, warnings)
                check_redundant_return(fun.return_type, fun.body, path, warnings)
                check_missing_return(fun.name, fun.return_type, fun.body, path, warnings)
            ast.Decl.decl_extending_block as ex:
                var j: ptr_uint = 0
                while j < ex.methods.len:
                    let m = read(ex.methods.data + j)
                    visit_stmt(m.body, path, warnings)
                    check_redundant_return(m.return_type, m.body, path, warnings)
                    check_missing_return(m.name, m.return_type, m.body, path, warnings)
                    j += 1
            ast.Decl.decl_const as c:
                visit_expr_opt(c.value, path, warnings)
            ast.Decl.decl_var as v:
                visit_expr_opt(v.value, path, warnings)
            ast.Decl.decl_static_assert as sa:
                visit_expr(sa.condition, path, warnings)
                visit_expr_opt(sa.message, path, warnings)
            ast.Decl.decl_when as w:
                visit_expr(w.discriminant, path, warnings)
                var bi: ptr_uint = 0
                while bi < w.branches.len:
                    let br = read(w.branches.data + bi)
                    var si: ptr_uint = 0
                    while si < br.body.len:
                        visit_decl(br.body.data + si, path, warnings)
                        si += 1
                    bi += 1
            _:
                pass


function visit_stmt_opt(stmt: ptr[ast.Stmt]?, path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    let sp = stmt else:
        return
    visit_stmt(sp, path, warnings)


function visit_stmt(stmt: ptr[ast.Stmt], path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    unsafe:
        match read(stmt):
            ast.Stmt.stmt_block as blk:
                var i: ptr_uint = 0
                while i < blk.statements.len:
                    visit_stmt(blk.statements.data + i, path, warnings)
                    i += 1
            ast.Stmt.stmt_local as loc:
                visit_expr_opt(loc.value, path, warnings)
                visit_stmt_opt(loc.else_body, path, warnings)
            ast.Stmt.stmt_assignment as asgn:
                visit_expr(asgn.value, path, warnings)
                visit_expr(asgn.target, path, warnings)
                check_self_assignment(asgn.target, asgn.operator, asgn.value, path, warnings)
                check_noop_compound_assignment(asgn.target, asgn.operator, asgn.value, path, warnings)
            ast.Stmt.stmt_if as iff:
                var bi: ptr_uint = 0
                while bi < iff.branches.len:
                    let br = read(iff.branches.data + bi)
                    visit_expr(br.condition, path, warnings)
                    visit_stmt(br.body, path, warnings)
                    bi += 1
                visit_stmt_opt(iff.else_body, path, warnings)
                check_redundant_else(iff.branches, iff.else_body, iff.else_line, path, warnings)
                check_duplicate_if_conditions(iff.branches, path, warnings)
                check_prefer_inline_if(iff.branches, iff.else_body, iff.is_inline, iff.line, path, warnings)
                check_prefer_conditional_expression_if(iff.branches, iff.else_body, path, warnings)
            ast.Stmt.stmt_while as wh:
                visit_expr(wh.condition, path, warnings)
                visit_stmt_opt(wh.body, path, warnings)
            ast.Stmt.stmt_for as fr:
                var ii: ptr_uint = 0
                while ii < fr.iterables.len:
                    visit_expr(fr.iterables.data + ii, path, warnings)
                    ii += 1
                visit_stmt_opt(fr.body, path, warnings)
            ast.Stmt.stmt_match as mt:
                visit_expr(mt.scrutinee, path, warnings)
                var ai: ptr_uint = 0
                while ai < mt.arms.len:
                    let arm = read(mt.arms.data + ai)
                    warn_redundant_ignored_match_binding(arm.binding_name, arm.binding_line, mt.line, path, warnings)
                    visit_stmt_opt(arm.body, path, warnings)
                    ai += 1
                check_prefer_or_pattern_stmt(mt.arms, path, warnings)
                check_prefer_conditional_expression_match(mt.arms, path, warnings)
                check_prefer_try_stmt(mt.arms, path, warnings)
            ast.Stmt.stmt_ret as r:
                visit_expr_opt(r.value, path, warnings)
            ast.Stmt.stmt_defer as df:
                visit_expr_opt(df.expression, path, warnings)
                visit_stmt_opt(df.body, path, warnings)
            ast.Stmt.stmt_unsafe as un:
                visit_stmt_opt(un.body, path, warnings)
            ast.Stmt.stmt_expression as ex:
                visit_expr(ex.expression, path, warnings)
                check_useless_expression(ex.expression, ex.line, path, warnings)
            ast.Stmt.stmt_static_assert as sa:
                visit_expr(sa.condition, path, warnings)
                visit_expr_opt(sa.message, path, warnings)
            ast.Stmt.stmt_when as wn:
                visit_expr(wn.discriminant, path, warnings)
                var wbi: ptr_uint = 0
                while wbi < wn.branches.len:
                    let br = read(wn.branches.data + wbi)
                    var wsi: ptr_uint = 0
                    while wsi < br.body.len:
                        visit_stmt(br.body.data + wsi, path, warnings)
                        wsi += 1
                    wbi += 1
                visit_stmt_opt(wn.else_body, path, warnings)
            ast.Stmt.stmt_parallel_block as pb:
                var pi: ptr_uint = 0
                while pi < pb.bodies.len:
                    visit_stmt(pb.bodies.data + pi, path, warnings)
                    pi += 1
            ast.Stmt.stmt_gather as g:
                var gi: ptr_uint = 0
                while gi < g.handles.len:
                    visit_expr(g.handles.data + gi, path, warnings)
                    gi += 1
            _:
                pass


function visit_expr_opt(expr: ptr[ast.Expr]?, path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    let ep = expr else:
        return
    visit_expr(ep, path, warnings)


function visit_expr(expr: ptr[ast.Expr], path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    unsafe:
        match read(expr):
            ast.Expr.expr_binary_op as b:
                visit_expr(b.left, path, warnings)
                visit_expr(b.right, path, warnings)
                check_self_comparison(b.operator, b.left, b.right, path, warnings)
                check_redundant_bool_compare(b.operator, b.left, b.right, path, warnings)
            ast.Expr.expr_unary_op as u:
                visit_expr(u.operand, path, warnings)
            ast.Expr.expr_member_access as m:
                visit_expr(m.receiver, path, warnings)
            ast.Expr.expr_call as call:
                visit_expr(call.callee, path, warnings)
                var i: ptr_uint = 0
                while i < call.args.len:
                    let arg = read(call.args.data + i)
                    visit_expr(arg.arg_value, path, warnings)
                    i += 1
            ast.Expr.expr_index_access as ix:
                visit_expr(ix.receiver, path, warnings)
                visit_expr(ix.index, path, warnings)
            ast.Expr.expr_specialization as sp:
                visit_expr(sp.callee, path, warnings)
            ast.Expr.expr_if as iff:
                visit_expr(iff.condition, path, warnings)
                visit_expr(iff.then_expr, path, warnings)
                visit_expr(iff.else_expr, path, warnings)
            ast.Expr.expr_match as mm:
                visit_expr(mm.scrutinee, path, warnings)
                var ai: ptr_uint = 0
                while ai < mm.arms.len:
                    let arm = read(mm.arms.data + ai)
                    warn_redundant_ignored_match_binding(arm.binding_name, arm.binding_line, mm.line, path, warnings)
                    visit_expr(arm.value, path, warnings)
                    ai += 1
            ast.Expr.expr_proc as pr:
                visit_stmt(pr.body, path, warnings)
            ast.Expr.expr_await as aw:
                visit_expr(aw.expression, path, warnings)
            ast.Expr.expr_detach as dt:
                visit_expr(dt.expression, path, warnings)
            ast.Expr.expr_named as nm:
                visit_expr(nm.value, path, warnings)
            ast.Expr.expr_range as rg:
                visit_expr(rg.start_expr, path, warnings)
                visit_expr(rg.end_expr, path, warnings)
            ast.Expr.expr_prefix_cast as pc:
                visit_expr(pc.expression, path, warnings)
            ast.Expr.expr_unsafe as us:
                visit_expr(us.expression, path, warnings)
            ast.Expr.expr_expression_list as el:
                var ei: ptr_uint = 0
                while ei < el.elements.len:
                    visit_expr(el.elements.data + ei, path, warnings)
                    ei += 1
            _:
                pass

    unsafe:
        match read(expr):
            ast.Expr.expr_call as call:
                check_prefer_struct_with(expr, call.args, path, warnings)
            ast.Expr.expr_match as mm:
                check_prefer_or_pattern_expr(mm.arms, path, warnings)
                check_prefer_is_variant_expr(mm.arms, mm.line, path, warnings)
            _:
                pass


# =============================================================================
#  Helpers — statement / expression structural comparison
# =============================================================================

## Return the single statement from a block body, or none when the body is not
## a single-statement block (or is null).
function single_statement_body(body: ptr[ast.Stmt]?) -> ptr[ast.Stmt]?:
    let bp = body else:
        return null
    unsafe:
        match read(bp):
            ast.Stmt.stmt_block as blk:
                if blk.statements.len == 1:
                    return blk.statements.data + 0
                return null
            _:
                return bp


## Is `stmt` an inline-worthy simple statement (return, assign, expression,
## break, continue, local decl)?
function inline_simple_statement(stmt: ptr[ast.Stmt]) -> bool:
    unsafe:
        match read(stmt):
            ast.Stmt.stmt_ret:
                return true
            ast.Stmt.stmt_assignment:
                return true
            ast.Stmt.stmt_expression:
                return true
            ast.Stmt.stmt_break:
                return true
            ast.Stmt.stmt_continue:
                return true
            ast.Stmt.stmt_local:
                return true
            _:
                return false


## Structural equality of two statement pointers — compare outline.
function stmts_structural_equal(a: ptr[ast.Stmt]?, b: ptr[ast.Stmt]?) -> bool:
    if a == null and b == null:
        return true
    if a == null or b == null:
        return false
    unsafe:
        match read(a):
            ast.Stmt.stmt_ret as ra:
                match read(b):
                    ast.Stmt.stmt_ret as rb:
                        return ra.value == null and rb.value == null
                    _:
                        return false
            ast.Stmt.stmt_expression as ea:
                match read(b):
                    ast.Stmt.stmt_expression as eb:
                        return exprs_structural_equal(ea.expression, eb.expression)
                    _:
                        return false
            ast.Stmt.stmt_assignment as aa:
                match read(b):
                    ast.Stmt.stmt_assignment as ab:
                        return aa.operator.equal(ab.operator) and exprs_structural_equal(aa.target, ab.target)
                    _:
                        return false
            ast.Stmt.stmt_break:
                match read(b):
                    ast.Stmt.stmt_break:
                        return true
                    _:
                        return false
            ast.Stmt.stmt_continue:
                match read(b):
                    ast.Stmt.stmt_continue:
                        return true
                    _:
                        return false
            ast.Stmt.stmt_pass:
                match read(b):
                    ast.Stmt.stmt_pass:
                        return true
                    _:
                        return false
            ast.Stmt.stmt_block as blka:
                match read(b):
                    ast.Stmt.stmt_block as blkb:
                        if blka.statements.len != blkb.statements.len:
                            return false
                        var i: ptr_uint = 0
                        while i < blka.statements.len:
                            if not stmts_structural_equal(blka.statements.data + i, blkb.statements.data + i):
                                return false
                            i += 1
                        return true
                    _:
                        return false
            _:
                return false


function exprs_structural_equal(a: ptr[ast.Expr], b: ptr[ast.Expr]) -> bool:
    unsafe:
        match read(a):
            ast.Expr.expr_identifier as ida:
                match read(b):
                    ast.Expr.expr_identifier as idb:
                        return ida.name.equal(idb.name)
                    _:
                        return false
            ast.Expr.expr_member_access as ma:
                match read(b):
                    ast.Expr.expr_member_access as mb:
                        return ma.member_name.equal(mb.member_name) and exprs_structural_equal(ma.receiver, mb.receiver)
                    _:
                        return false
            ast.Expr.expr_integer_literal as ia:
                match read(b):
                    ast.Expr.expr_integer_literal as ib:
                        return ia.value == ib.value
                    _:
                        return false
            ast.Expr.expr_bool_literal as ba:
                match read(b):
                    ast.Expr.expr_bool_literal as bb:
                        return ba.value == bb.value
                    _:
                        return false
            ast.Expr.expr_string_literal as sa:
                match read(b):
                    ast.Expr.expr_string_literal as sb:
                        return sa.value.equal(sb.value)
                    _:
                        return false
            ast.Expr.expr_null_literal:
                match read(b):
                    ast.Expr.expr_null_literal:
                        return true
                    _:
                        return false
            ast.Expr.expr_call as ca:
                match read(b):
                    ast.Expr.expr_call as cb:
                        if not exprs_structural_equal(ca.callee, cb.callee):
                            return false
                        if ca.args.len != cb.args.len:
                            return false
                        var i: ptr_uint = 0
                        while i < ca.args.len:
                            if not exprs_structural_equal(read(ca.args.data + i).arg_value, read(cb.args.data + i).arg_value):
                                return false
                            i += 1
                        return true
                    _:
                        return false
            ast.Expr.expr_unary_op as ua:
                match read(b):
                    ast.Expr.expr_unary_op as ub:
                        return ua.operator.equal(ub.operator) and exprs_structural_equal(ua.operand, ub.operand)
                    _:
                        return false
            ast.Expr.expr_binary_op as ba2:
                match read(b):
                    ast.Expr.expr_binary_op as bb2:
                        return ba2.operator.equal(bb2.operator) and exprs_structural_equal(ba2.left, bb2.left) and exprs_structural_equal(ba2.right, bb2.right)
                    _:
                        return false
            _:
                return false


## Is `expr` a wildcard pattern (_)?
function wildcard_pattern(expr: ptr[ast.Expr]?) -> bool:
    let ep = expr else:
        return false
    unsafe:
        match read(ep):
            ast.Expr.expr_identifier as id:
                return id.name == "_"
            _:
                return false


## Extract boolean literal value from an expression, or none.
function boolean_literal_value(expr: ptr[ast.Expr]) -> Option[bool]:
    unsafe:
        match read(expr):
            ast.Expr.expr_bool_literal as b:
                return Option[bool].some(value = b.value)
            _:
                return Option[bool].none


## Extract identifier name from an expr, or none.
function identifier_name_of(expr: ptr[ast.Expr]) -> Option[str]:
    unsafe:
        match read(expr):
            ast.Expr.expr_identifier as id:
                return Option[str].some(value = id.name)
            _:
                return Option[str].none


# =============================================================================
#  missing-return — non-void function whose body does not always return.
# =============================================================================

function check_missing_return(name: str, return_type: ptr[ast.TypeRef]?, body: ptr[ast.Stmt]?, path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    if return_type == null:
        return
    if is_void_type(return_type):
        return
    let bp = body else:
        push_warning(warnings, path, 0, "missing-return", mk_missing_return_msg(name), "error")
        return
    if not always_returns_body(body):
        push_warning(warnings, path, 0, "missing-return", mk_missing_return_msg(name), "error")


function mk_missing_return_msg(name: str) -> str:
    var buf = string.String.create()
    buf.append("function '")
    buf.append(name)
    buf.append("' does not always return a value")
    return buf.as_str()


# =============================================================================
#  prefer-inline-if — multi-line if/else where each branch is a single simple
#  statement that fits on one line.
# =============================================================================

function check_prefer_inline_if(branches: span[ast.IfBranch], else_body: ptr[ast.Stmt]?, is_inline: bool, line: ptr_uint, path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    if is_inline:
        return
    if not block_is_nonempty(else_body):
        return
    var bi: ptr_uint = 0
    while bi < branches.len:
        unsafe:
            let s = single_statement_body(read(branches.data + bi).body) else:
                return
            if not inline_simple_statement(s):
                return
        bi += 1
    let s = single_statement_body(else_body) else:
        return
    if not inline_simple_statement(s):
        return
    push_warning(warnings, path, line, "prefer-inline-if", "if/else with single-statement branches can be written inline", "hint")


# =============================================================================
#  prefer-or-pattern — adjacent match arms with identical bodies should merge
#  with |.
# =============================================================================

function check_prefer_or_pattern_stmt(arms: span[ast.MatchArm], path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    if arms.len < 2:
        return
    var i: ptr_uint = 1
    while i < arms.len:
        unsafe:
            let prev = read(arms.data + i - 1)
            let curr = read(arms.data + i)
            if prev.binding_name.is_some() or curr.binding_name.is_some():
                i += 1
                continue
            if prev.pattern == null or curr.pattern == null:
                i += 1
                continue
            if wildcard_pattern(prev.pattern) or wildcard_pattern(curr.pattern):
                i += 1
                continue
            if stmts_structural_equal(prev.body, curr.body):
                let pat_line = expression_line(curr.pattern)
                if pat_line == 0:
                    i += 1
                    continue
                push_warning(warnings, path, pat_line, "prefer-or-pattern", "adjacent match arms have identical bodies; merge them with `|`", "hint")
        i += 1


function check_prefer_or_pattern_expr(arms: span[ast.MatchExprArm], path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    if arms.len < 2:
        return
    var i: ptr_uint = 1
    while i < arms.len:
        unsafe:
            let prev = read(arms.data + i - 1)
            let curr = read(arms.data + i)
            if prev.binding_name.is_some() or curr.binding_name.is_some():
                i += 1
                continue
            if prev.pattern == null or curr.pattern == null:
                i += 1
                continue
            if wildcard_pattern(prev.pattern) or wildcard_pattern(curr.pattern):
                i += 1
                continue
            if exprs_structural_equal(prev.value, curr.value):
                let pat_line = expression_line(curr.pattern)
                if pat_line != 0:
                    push_warning(warnings, path, pat_line, "prefer-or-pattern", "adjacent match arms have identical bodies; merge them with `|`", "hint")
        i += 1


# =============================================================================
#  prefer-conditional-expression — if/match where every branch returns a value
#  or assigns to the same target.
# =============================================================================

function check_prefer_conditional_expression_if(branches: span[ast.IfBranch], else_body: ptr[ast.Stmt]?, path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    if not block_is_nonempty(else_body):
        return
    # Collect single statements from each branch.
    var stmts = vec.Vec[ptr[ast.Stmt]].create()
    defer stmts.release()
    var bi: ptr_uint = 0
    while bi < branches.len:
        unsafe:
            let s = single_statement_body(read(branches.data + bi).body) else:
                return
            stmts.push(s)
        bi += 1
    let else_s = single_statement_body(else_body) else:
        return
    stmts.push(else_s)

    var all_ret = true
    var all_assign = true
    var assign_target_sig: Option[str] = Option[str].none
    var si: ptr_uint = 0
    while si < stmts.len():
        unsafe:
            let sp = stmts.get(si) else:
                break
            let s = read(sp)
            match read(s):
                ast.Stmt.stmt_ret as r:
                    if r.value == null:
                        return
                    all_assign = false
                ast.Stmt.stmt_assignment as a:
                    if a.operator != "=":
                        return
                    all_ret = false
                    let tsig = expr_source_sig(a.target)
                    match assign_target_sig:
                        Option.some as prev_sig:
                            if not tsig.equal(prev_sig.value):
                                return
                        Option.none:
                            assign_target_sig = Option[str].some(value = tsig)
                _:
                    return
        si += 1

    let kind = "if"
    if all_ret:
        var buf = string.String.create()
        buf.append("every ")
        buf.append(kind)
        buf.append(" branch returns a value; use a `return ")
        buf.append(kind)
        buf.append(" ...` expression")
        let line = unsafe: expression_line(read(branches.data + 0).condition)
        push_warning(warnings, path, line, "prefer-conditional-expression", buf.as_str(), "hint")
    else if all_assign:
        var buf = string.String.create()
        buf.append("every ")
        buf.append(kind)
        buf.append(" branch assigns the same target; use a `")
        buf.append(kind)
        buf.append(" ...` expression")
        let line = unsafe: expression_line(read(branches.data + 0).condition)
        push_warning(warnings, path, line, "prefer-conditional-expression", buf.as_str(), "hint")


function check_prefer_conditional_expression_match(arms: span[ast.MatchArm], path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    # Only fires when there is a wildcard arm.
    var has_wild = false
    var ai: ptr_uint = 0
    while ai < arms.len:
        unsafe:
            let arm = read(arms.data + ai)
            if arm.pattern != null and wildcard_pattern(arm.pattern):
                has_wild = true
                break
        ai += 1
    if not has_wild:
        return

    var stmts = vec.Vec[ptr[ast.Stmt]].create()
    defer stmts.release()
    ai = 0
    while ai < arms.len:
        unsafe:
            let arm = read(arms.data + ai)
            if arm.binding_name.is_some():
                return
            let s = single_statement_body(arm.body) else:
                return
            stmts.push(s)
        ai += 1

    var all_ret = true
    var all_assign = true
    var assign_target_sig: Option[str] = Option[str].none
    var si: ptr_uint = 0
    while si < stmts.len():
        unsafe:
            let sp = stmts.get(si) else:
                break
            let s = read(sp)
            match read(s):
                ast.Stmt.stmt_ret as r:
                    if r.value == null:
                        return
                    all_assign = false
                ast.Stmt.stmt_assignment as a:
                    if a.operator != "=":
                        return
                    all_ret = false
                    let tsig = expr_source_sig(a.target)
                    match assign_target_sig:
                        Option.some as prev_sig:
                            if not tsig.equal(prev_sig.value):
                                return
                        Option.none:
                            assign_target_sig = Option[str].some(value = tsig)
                _:
                    return
        si += 1

    let kind = "match"
    if all_ret:
        var buf = string.String.create()
        buf.append("every ")
        buf.append(kind)
        buf.append(" branch returns a value; use a `return ")
        buf.append(kind)
        buf.append(" ...` expression")
        let line = unsafe: expression_line(read(arms.data + 0).pattern)
        push_warning(warnings, path, line, "prefer-conditional-expression", buf.as_str(), "hint")
    else if all_assign:
        var buf = string.String.create()
        buf.append("every ")
        buf.append(kind)
        buf.append(" branch assigns the same target; use a `")
        buf.append(kind)
        buf.append(" ...` expression")
        let line = unsafe: expression_line(read(arms.data + 0).pattern)
        push_warning(warnings, path, line, "prefer-conditional-expression", buf.as_str(), "hint")


## A source-signature string for an expression, used for assignment-target
## identity comparison (node_fingerprint mirror).
function expr_source_sig(expr: ptr[ast.Expr]) -> str:
    unsafe:
        match read(expr):
            ast.Expr.expr_identifier as id:
                var buf = string.String.create()
                buf.append("id:")
                buf.append(id.name)
                return buf.as_str()
            ast.Expr.expr_member_access as m:
                var buf = string.String.create()
                buf.append(expr_source_sig(m.receiver))
                buf.append(".")
                buf.append(m.member_name)
                return buf.as_str()
            ast.Expr.expr_index_access as ix:
                var buf = string.String.create()
                buf.append(expr_source_sig(ix.receiver))
                buf.append("[]")
                return buf.as_str()
            _:
                return "unknown"


# =============================================================================
#  prefer-let-else — `let x = expr; if x == null: ...` should use let...else.
# =============================================================================

function lint_prefer_let_else(file: ast.SourceFile, path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    var i: ptr_uint = 0
    while i < file.declarations.len:
        unsafe:
            match read(file.declarations.data + i):
                ast.Decl.decl_function as fun:
                    prefer_else_walk_body(fun.body, path, warnings)
                ast.Decl.decl_extending_block as ex:
                    var j: ptr_uint = 0
                    while j < ex.methods.len:
                        prefer_else_walk_body(read(ex.methods.data + j).body, path, warnings)
                        j += 1
                _:
                    pass
        i += 1


function prefer_else_walk_body(body: ptr[ast.Stmt]?, path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    let bp = body else:
        return
    unsafe:
        match read(bp):
            ast.Stmt.stmt_block as blk:
                prefer_else_walk_stmts(blk.statements, path, warnings)
            _:
                pass


function prefer_else_walk_stmts(stmts: span[ast.Stmt], path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    var i: ptr_uint = 0
    while i < stmts.len:
        unsafe:
            prefer_else_recurse_into(stmts.data + i, path, warnings)
        i += 1
    if stmts.len < 2:
        return
    i = 0
    while i + 1 < stmts.len:
        unsafe:
            match read(stmts.data + i):
                ast.Stmt.stmt_local as loc:
                    if not loc.is_let:
                        i += 1
                        continue
                    if loc.value == null:
                        i += 1
                        continue
                    if loc.stmt_type != null:
                        i += 1
                        continue
                    if loc.else_binding.is_some() or loc.else_body != null:
                        i += 1
                        continue
                    match read(stmts.data + i + 1):
                        ast.Stmt.stmt_if as iff:
                            if iff.branches.len != 1:
                                i += 1
                                continue
                            if block_is_nonempty(iff.else_body):
                                i += 1
                                continue
                            let cond = read(iff.branches.data + 0).condition
                            let guard_name = prefer_else_guard_name(cond, loc.name) else:
                                i += 1
                                continue
                            let guard_body = read(iff.branches.data + 0).body
                            if not always_returns_body(guard_body):
                                i += 1
                                continue
                            var buf = string.String.create()
                            buf.append("nullable guard for '")
                            buf.append(loc.name)
                            buf.append("' can use let ... else")
                            push_warning(warnings, path, loc.line, "prefer-let-else", buf.as_str(), "hint")
                        _:
                            pass
                _:
                    pass
        i += 1


## Check if `condition` is `name == null` or `null == name`, returning true
## if the guard matches the given name.
function prefer_else_guard_name(condition: ptr[ast.Expr], name: str) -> Option[bool]:
    unsafe:
        match read(condition):
            ast.Expr.expr_binary_op as b:
                if b.operator != "==":
                    return Option[bool].none
                let left_name = identifier_name_of(b.left)
                let right_name = identifier_name_of(b.right)
                var left_null = false
                var right_null = false
                match read(b.left):
                    ast.Expr.expr_null_literal:
                        left_null = true
                    _:
                        pass
                match read(b.right):
                    ast.Expr.expr_null_literal:
                        right_null = true
                    _:
                        pass
                if left_null and right_name.is_some() and right_name.unwrap().equal(name):
                    return Option[bool].some(value = true)
                if right_null and left_name.is_some() and left_name.unwrap().equal(name):
                    return Option[bool].some(value = true)
                return Option[bool].none
            _:
                return Option[bool].none


function prefer_else_recurse_into(stmt: ptr[ast.Stmt], path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    unsafe:
        match read(stmt):
            ast.Stmt.stmt_if as iff:
                var bi: ptr_uint = 0
                while bi < iff.branches.len:
                    prefer_else_walk_body(read(iff.branches.data + bi).body, path, warnings)
                    bi += 1
                prefer_else_walk_body(iff.else_body, path, warnings)
            ast.Stmt.stmt_match as mt:
                var ai: ptr_uint = 0
                while ai < mt.arms.len:
                    prefer_else_walk_body(read(mt.arms.data + ai).body, path, warnings)
                    ai += 1
            ast.Stmt.stmt_while as wh:
                prefer_else_walk_body(wh.body, path, warnings)
            ast.Stmt.stmt_for as fr:
                prefer_else_walk_body(fr.body, path, warnings)
            ast.Stmt.stmt_unsafe as un:
                prefer_else_walk_body(un.body, path, warnings)
            ast.Stmt.stmt_defer as df:
                prefer_else_walk_body(df.body, path, warnings)
            ast.Stmt.stmt_when as wn:
                var wi: ptr_uint = 0
                while wi < wn.branches.len:
                    var wsi: ptr_uint = 0
                    let wbr = read(wn.branches.data + wi)
                    while wsi < wbr.body.len:
                        prefer_else_recurse_into(wbr.body.data + wsi, path, warnings)
                        wsi += 1
                    wi += 1
                prefer_else_walk_body(wn.else_body, path, warnings)
            ast.Stmt.stmt_block as blk:
                prefer_else_walk_stmts(blk.statements, path, warnings)
            _:
                pass


# =============================================================================
#  prefer-try — match over Option/Result that only propagates failure.
# =============================================================================

struct TryArmPair:
    early_is_first: bool
    base: str

function check_prefer_try_stmt(arms: span[ast.MatchArm], path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    if arms.len != 2:
        return
    unsafe:
        let arm0 = read(arms.data + 0)
        let arm1 = read(arms.data + 1)
        let pair = classify_try_arms(arm0, arm1) else:
            return
        let early = if pair.early_is_first: arm0 else: arm1
        let s = single_statement_body(early.body) else:
            return
        match read(s):
            ast.Stmt.stmt_ret as r:
                let rv = r.value else:
                    return
                if is_propagation_return(rv, pair.base, early.binding_name):
                    var buf = string.String.create()
                    buf.append("this ")
                    buf.append(pair.base)
                    buf.append(" match only propagates the failure branch; consider `expr?`")
                    let line = unsafe: expression_line(read(arms.data + 0).pattern)
                    push_warning(warnings, path, line, "prefer-try", buf.as_str(), "hint")
            _:
                pass


function classify_try_arms(arm0: ast.MatchArm, arm1: ast.MatchArm) -> Option[TryArmPair]:
    let p0 = arm0.pattern
    let p1 = arm1.pattern
    if p0 == null or p1 == null:
        return Option[TryArmPair].none
    let base_opt = try_short_circuit_base(p0, p1)
    match base_opt:
        Option.some as base:
            return Option[TryArmPair].some(value = TryArmPair(early_is_first = true, base = base.value))
        Option.none:
            pass
    let base_opt2 = try_short_circuit_base(p1, p0)
    match base_opt2:
        Option.some as base:
            return Option[TryArmPair].some(value = TryArmPair(early_is_first = false, base = base.value))
        Option.none:
            pass
    return Option[TryArmPair].none


## If `short_arm` is a short-circuit pattern (Result.failure or Option.none),
## and `other_arm` is the success arm, return the variant base name.
function try_short_circuit_base(short_pat: ptr[ast.Expr], other_pat: ptr[ast.Expr]) -> Option[str]:
    unsafe:
        match read(short_pat):
            ast.Expr.expr_member_access as m:
                let recv_name = identifier_name_of(m.receiver) else:
                    return Option[str].none
                if m.member_name == "failure":
                    # Check that the other arm is success or some
                    match read(other_pat):
                        ast.Expr.expr_member_access as om:
                            let other_recv = identifier_name_of(om.receiver) else:
                                return Option[str].none
                            if om.member_name == "success" and other_recv.equal(recv_name):
                                return Option[str].some(value = "Result")
                            return Option[str].none
                        _:
                            return Option[str].none
                if m.member_name == "none":
                    match read(other_pat):
                        ast.Expr.expr_member_access as om:
                            let other_recv = identifier_name_of(om.receiver) else:
                                return Option[str].none
                            if om.member_name == "some" and other_recv.equal(recv_name):
                                return Option[str].some(value = "Option")
                            return Option[str].none
                        _:
                            return Option[str].none
                return Option[str].none
            _:
                return Option[str].none


## Check if `value` propagates the failure arm's error unchanged.
## For Option: `Option[..].none` or `.none()`. For Result:
## `.failure(error = <binding_name>.error)`.
function is_propagation_return(value: ptr[ast.Expr], base: str, binding_name: Option[str]) -> bool:
    if base.equal("Option"):
        return is_option_none_expr(value)
    if base.equal("Result"):
        return is_result_failure_propagation(value, binding_name)
    return false


function is_option_none_expr(value: ptr[ast.Expr]) -> bool:
    unsafe:
        match read(value):
            ast.Expr.expr_member_access as m:
                if m.member_name == "none":
                    return true
            _:
                return false
    return false


function is_result_failure_propagation(value: ptr[ast.Expr], binding_name: Option[str]) -> bool:
    let bn = binding_name else:
        return false
    unsafe:
        match read(value):
            ast.Expr.expr_call as call:
                match read(call.callee):
                    ast.Expr.expr_member_access as m:
                        if m.member_name != "failure":
                            return false
                        let recv_name = identifier_name_of(m.receiver) else:
                            return false
                        if not recv_name.equal("Result"):
                            return false
                        # Check args: error=<binding>.error
                        if call.args.len == 1:
                            let arg_v = read(read(call.args.data + 0).arg_value)
                            match arg_v:
                                ast.Expr.expr_member_access as err_m:
                                    if err_m.member_name == "error":
                                        match read(err_m.receiver):
                                            ast.Expr.expr_identifier as id:
                                                return id.name.equal(bn)
                                            _:
                                                pass
                                _:
                                    pass
                        return false
                    _:
                        return false
            _:
                return false
    return false


# =============================================================================
#  prefer-is-variant — `match expr: Arm: true; _: false` → `expr is Arm`.
# =============================================================================

struct IsVariantPair:
    pat_is_first: bool
    want_true: bool

function check_prefer_is_variant_expr(arms: span[ast.MatchExprArm], match_line: ptr_uint, path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    if arms.len != 2:
        return
    unsafe:
        let arm0 = read(arms.data + 0)
        let arm1 = read(arms.data + 1)
        let pair = classify_is_variant_arms(arm0, arm1) else:
            return
        let pat_arm = if pair.pat_is_first: arm0 else: arm1
        let pat_text = expr_source_name(pat_arm.pattern)
        var suggestion = string.String.create()
        if pair.want_true:
            suggestion.append("expr is ")
            suggestion.append(pat_text)
        else:
            suggestion.append("not (expr is ")
            suggestion.append(pat_text)
            suggestion.append(")")
        var buf = string.String.create()
        buf.append("prefer `")
        buf.append(suggestion.as_str())
        buf.append("` over a match that maps one variant arm to a boolean")
        push_warning(warnings, path, match_line, "prefer-is-variant", buf.as_str(), "hint")


function classify_is_variant_arms(arm0: ast.MatchExprArm, arm1: ast.MatchExprArm) -> Option[IsVariantPair]:
    let p0_wild = arm0.pattern != null and wildcard_pattern(arm0.pattern)
    let p1_wild = arm1.pattern != null and wildcard_pattern(arm1.pattern)
    if p0_wild == p1_wild:
        return Option[IsVariantPair].none
    let wild_is_first = p0_wild
    let pat_arm = if wild_is_first: arm1 else: arm0
    let pat_is_true = boolean_literal_value(pat_arm.value)
    let wild_is_true = boolean_literal_value(if wild_is_first: arm0.value else: arm1.value)
    if wild_is_true.is_none() or pat_is_true.is_none():
        return Option[IsVariantPair].none
    if wild_is_true.unwrap() == pat_is_true.unwrap():
        return Option[IsVariantPair].none
    if pat_arm.binding_name.is_some():
        return Option[IsVariantPair].none
    let pat = pat_arm.pattern else:
        return Option[IsVariantPair].none
    var ok = false
    unsafe:
        match read(pat):
            ast.Expr.expr_member_access:
                ok = true
            _:
                pass
    if not ok:
        return Option[IsVariantPair].none
    if pat_arm.binding_name.is_some():
        return Option[IsVariantPair].none
    let want_true = pat_is_true.unwrap()
    return Option[IsVariantPair].some(value = IsVariantPair(pat_is_first = not wild_is_first, want_true = want_true))


## Reconstruct source text for an expression (best effort).
function expr_source_name(expr: ptr[ast.Expr]?) -> str:
    let ep = expr else:
        return ""
    unsafe:
        match read(ep):
            ast.Expr.expr_identifier as id:
                return id.name
            ast.Expr.expr_member_access as m:
                var buf = string.String.create()
                buf.append(expr_source_name(m.receiver))
                buf.append(".")
                buf.append(m.member_name)
                return buf.as_str()
            _:
                return ""


# =============================================================================
#  prefer-struct-with — struct construction with many copy-field args.
# =============================================================================

function check_prefer_struct_with(call_expr: ptr[ast.Expr], args: span[ast.Argument], path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    if args.len < 3:
        return
    var changed_count: ptr_uint = 0
    var copied_count: ptr_uint = 0
    var source_sig: Option[str] = Option[str].none
    var changed_fields = vec.Vec[str].create()
    defer changed_fields.release()
    var copied_fields = vec.Vec[str].create()
    defer copied_fields.release()

    var ai: ptr_uint = 0
    while ai < args.len:
        unsafe:
            let arg = read(args.data + ai)
            let field_name = arg.arg_name else:
                return
            match read(arg.arg_value):
                ast.Expr.expr_member_access as m:
                    let field_sig = expr_source_sig(m.receiver)
                    if m.member_name.equal(field_name):
                        # This arg is a copy from a source struct.
                        copied_count += 1
                        copied_fields.push(field_name)
                        match source_sig:
                            Option.some as prev:
                                if not field_sig.equal(prev.value):
                                    return
                            Option.none:
                                source_sig = Option[str].some(value = field_sig)
                    else:
                        changed_count += 1
                        changed_fields.push(field_name)
                _:
                    changed_count += 1
                    changed_fields.push(field_name)
        ai += 1

    if changed_count == 0 or copied_count < 2:
        return

    let source_text = source_sig.unwrap_or("source")
    # Extract just the variable name from the sig (e.g. "id:x" -> "x")
    var display_source = source_text
    if display_source.starts_with("id:"):
        display_source = display_source.slice(3, display_source.len - 3)
    var buf = string.String.create()
    buf.append("copies ")
    buf.append(uint_to_str(copied_count))
    buf.append(" field(s) from `")
    buf.append(display_source)
    buf.append("`; use `")
    buf.append(source_text)
    buf.append(".with(")
    var first = true
    var ci: ptr_uint = 0
    while ci < changed_fields.len():
        let fp = changed_fields.get(ci) else:
            break
        if not first:
            buf.append(", ")
        buf.append(unsafe: read(fp))
        buf.append(" = ...")
        first = false
        ci += 1
    buf.append(")`")
    push_warning(warnings, path, expression_line(call_expr), "prefer-struct-with", buf.as_str(), "hint")


function uint_to_str(n: ptr_uint) -> str:
    if n == 0:
        return "0"
    var result = string.String.create()
    defer result.release()
    var v = n
    while v > 0:
        result.push_byte(ubyte<-(48 + (v % 10)))
        v = v / 10
    var output_str = string.String.create()
    let rs = result.as_str()
    var i = rs.len
    while i > 0:
        output_str.push_byte(rs.byte_at(i - 1))
        i -= 1
    return output_str.as_str()


# =============================================================================
#  line-too-long — source-level check for lines exceeding the max length.
# =============================================================================

const DEFAULT_MAX_LINE_LENGTH: ptr_uint = 120

function lint_line_too_long(source: str, path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    var start: ptr_uint = 0
    var line_num: ptr_uint = 1
    var i: ptr_uint = 0
    while i < source.len:
        if source.byte_at(i) == 10:
            let line_text = source.slice(start, i - start)
            if should_check_line_length(line_text):
                # Count UTF-8 characters rather than bytes for accurate column width.
                let char_count = utf8_char_width(line_text)
                if char_count > DEFAULT_MAX_LINE_LENGTH:
                    push_line_too_long(path, line_num, char_count, warnings)
            start = i + 1
            line_num += 1
        i += 1
    if start < source.len:
        let line_text = source.slice(start, source.len - start)
        if should_check_line_length(line_text):
            let char_count = utf8_char_width(line_text)
            if char_count > DEFAULT_MAX_LINE_LENGTH:
                push_line_too_long(path, line_num, char_count, warnings)


function should_check_line_length(line: str) -> bool:
    let t = line.trim_ascii_whitespace()
    if t.len == 0:
        return false
    # Skip external/foreign function header lines, and shebang lines.
    if t.starts_with("external") or t.starts_with("foreign function") or t.starts_with("#!"):
        return false
    return true


function utf8_char_width(s: str) -> ptr_uint:
    var count: ptr_uint = 0
    var i: ptr_uint = 0
    while i < s.len:
        let b = s.byte_at(i)
        if b < 0x80:
            i += 1
        else if b >= 0xC0 and b < 0xE0:
            i += 2
        else if b >= 0xE0 and b < 0xF0:
            i += 3
        else:
            i += 4
        count += 1
    return count


function push_line_too_long(path: str, line: ptr_uint, length: ptr_uint, warnings: ref[vec.Vec[Warning]]) -> void:
    var msg = string.String.create()
    msg.append("line exceeds max length of ")
    msg.append(uint_to_str(DEFAULT_MAX_LINE_LENGTH))
    msg.append(" columns (")
    msg.append(uint_to_str(length))
    msg.append(")")
    push_warning(warnings, path, line, "line-too-long", msg.as_str(), "warning")


# =============================================================================
#  owning-release-leak / owning-release-double — AST-based ownership checks.
# =============================================================================

## Walk all function-like bodies to collect owning locals and release calls,
## then report leaks and double-releases.
function lint_ownership(file: ast.SourceFile, path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    var i: ptr_uint = 0
    while i < file.declarations.len:
        unsafe:
            match read(file.declarations.data + i):
                ast.Decl.decl_function as fun:
                    ownership_walk_body(fun.body, path, warnings)
                ast.Decl.decl_extending_block as ex:
                    var j: ptr_uint = 0
                    while j < ex.methods.len:
                        ownership_walk_body(read(ex.methods.data + j).body, path, warnings)
                        j += 1
                _:
                    pass
        i += 1


function ownership_walk_body(body: ptr[ast.Stmt]?, path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    let bp = body else:
        return
    unsafe:
        match read(bp):
            ast.Stmt.stmt_block as blk:
                ownership_walk_stmts(blk.statements, path, warnings)
            _:
                pass


function ownership_walk_stmts(stmts: span[ast.Stmt], path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    var created = vec.Vec[str].create()
    defer created.release()
    var released = vec.Vec[str].create()
    defer released.release()
    var transferred = vec.Vec[str].create()
    defer transferred.release()
    var released_lines = map_mod.Map[str, ptr_uint].create()
    defer released_lines.release()

    # Collect from statements.
    var si: ptr_uint = 0
    while si < stmts.len:
        unsafe:
            ownership_collect_stmt(stmts.data + si, ref_of(created), ref_of(released), ref_of(released_lines), ref_of(transferred), path, warnings)
        si += 1

    # Recurse into nested scopes.
    si = 0
    while si < stmts.len:
        unsafe:
            ownership_recurse_stmt(stmts.data + si, path, warnings)
        si += 1

    # Report leaks: created but never released and never transferred.
    # Currently disabled (AST-only heuristic is too noisy without type info).
    # si = 0
    # while si < created.len():
    #     let namep = created.get(si) else:
    #         break
    #     let name = unsafe: read(namep)
    #     if not ownership_contains(ref_of(released), name) and not ownership_contains(ref_of(transferred), name):
    #         var buf = string.String.create()
    #         buf.append("owning binding '")
    #         buf.append(name)
    #         buf.append("' is never released")
    #         push_warning(warnings, path, 0, "owning-release-leak", buf.as_str(), "warning")
    #     si += 1


function ownership_contains(vec_ref: ref[vec.Vec[str]], name: str) -> bool:
    var i: ptr_uint = 0
    while i < vec_ref.len():
        let ep = vec_ref.get(i) else:
            break
        if unsafe: read(ep).equal(name):
            return true
        i += 1
    return false


function ownership_collect_stmt(stmt: ptr[ast.Stmt], created: ref[vec.Vec[str]], released: ref[vec.Vec[str]], released_lines: ref[map_mod.Map[str, ptr_uint]], transferred: ref[vec.Vec[str]], path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    unsafe:
        match read(stmt):
            ast.Stmt.stmt_local as loc:
                if loc.value != null:
                    if own_creating_call(loc.value):
                        created.push(loc.name)
                    else if ownership_transfer_ctor(loc.value, loc.name):
                        transferred.push(loc.name)
                ownership_collect_expr_opt(loc.value, released, released_lines, transferred, path, warnings)
                ownership_collect_body_opt(loc.else_body, path, warnings)
            ast.Stmt.stmt_expression as ex:
                ownership_collect_expr(ex.expression, released, released_lines, transferred, path, warnings)
            ast.Stmt.stmt_assignment as asgn:
                # If assigned from a create call, mark the target as created.
                if own_creating_call(asgn.value):
                    match read(asgn.target):
                        ast.Expr.expr_identifier as id:
                            created.push(id.name)
                        _:
                            pass
                # If the value is a release call, mark the target (the released var) and check double-release.
                if is_release_call_expr(asgn.target):
                    match read(asgn.target):
                        ast.Expr.expr_member_access as ma:
                            match read(ma.receiver):
                                ast.Expr.expr_identifier as id:
                                    if released_lines.contains(id.name):
                                        let prev_ptr = released_lines.get(id.name)
                                        if prev_ptr != null:
                                            let prev_line = unsafe: read(prev_ptr)
                                            var buf = string.String.create()
                                            buf.append("owning binding '")
                                            buf.append(id.name)
                                            buf.append("' may be released more than once")
                                            push_warning(warnings, path, prev_line, "owning-release-double", buf.as_str(), "warning")
                                    else:
                                        released_lines.set(id.name, unsafe: expression_line(asgn.target))
                                _:
                                    pass
                        _:
                            pass
                ownership_collect_expr(asgn.value, released, released_lines, transferred, path, warnings)
                ownership_collect_expr(asgn.target, released, released_lines, transferred, path, warnings)
                # Check for transferred ownership (e.g., passing to struct constructor).
                ownership_collect_transfer_in_args(asgn.value, asgn.target, transferred)
            ast.Stmt.stmt_ret as r:
                ownership_collect_expr_opt(r.value, released, released_lines, transferred, path, warnings)
                ownership_collect_ret_transfer(r.value, transferred)
            _:
                pass


function ownership_collect_body(body: ptr[ast.Stmt]?, path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    let bp = body else:
        return
    unsafe:
        match read(bp):
            ast.Stmt.stmt_block as blk:
                ownership_walk_stmts(blk.statements, path, warnings)
            _:
                var created = vec.Vec[str].create()
                defer created.release()
                var released = vec.Vec[str].create()
                defer released.release()
                var released_lines = map_mod.Map[str, ptr_uint].create()
                defer released_lines.release()
                var transferred = vec.Vec[str].create()
                defer transferred.release()
                ownership_collect_stmt(bp, ref_of(created), ref_of(released), ref_of(released_lines), ref_of(transferred), path, warnings)


function ownership_collect_body_opt(body: ptr[ast.Stmt]?, path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    let bp = body else:
        return
    ownership_collect_body(bp, path, warnings)


function ownership_collect_expr(expr: ptr[ast.Expr], released: ref[vec.Vec[str]], released_lines: ref[map_mod.Map[str, ptr_uint]], transferred: ref[vec.Vec[str]], path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    unsafe:
        match read(expr):
            ast.Expr.expr_call as call:
                if is_release_call_expr(call.callee):
                    match read(call.callee):
                        ast.Expr.expr_member_access as ma:
                            match read(ma.receiver):
                                ast.Expr.expr_identifier as id:
                                    if ownership_contains(released, id.name):
                                        var buf = string.String.create()
                                        buf.append("owning binding '")
                                        buf.append(id.name)
                                        buf.append("' may be released more than once")
                                        push_warning(warnings, path, expression_line(expr), "owning-release-double", buf.as_str(), "warning")
                                    else:
                                        released.push(id.name)
                                _:
                                    pass
                        _:
                            pass
                ownership_collect_expr(call.callee, released, released_lines, transferred, path, warnings)
                var ai: ptr_uint = 0
                while ai < call.args.len:
                    ownership_collect_expr(read(call.args.data + ai).arg_value, released, released_lines, transferred, path, warnings)
                    ai += 1
            ast.Expr.expr_member_access as m:
                ownership_collect_expr(m.receiver, released, released_lines, transferred, path, warnings)
            ast.Expr.expr_binary_op as b:
                ownership_collect_expr(b.left, released, released_lines, transferred, path, warnings)
                ownership_collect_expr(b.right, released, released_lines, transferred, path, warnings)
            ast.Expr.expr_unary_op as u:
                ownership_collect_expr(u.operand, released, released_lines, transferred, path, warnings)
            ast.Expr.expr_index_access as ix:
                ownership_collect_expr(ix.receiver, released, released_lines, transferred, path, warnings)
                ownership_collect_expr(ix.index, released, released_lines, transferred, path, warnings)
            ast.Expr.expr_if as iff:
                ownership_collect_expr(iff.condition, released, released_lines, transferred, path, warnings)
                ownership_collect_expr(iff.then_expr, released, released_lines, transferred, path, warnings)
                ownership_collect_expr(iff.else_expr, released, released_lines, transferred, path, warnings)
            ast.Expr.expr_match as mm:
                ownership_collect_expr(mm.scrutinee, released, released_lines, transferred, path, warnings)
                var mi: ptr_uint = 0
                while mi < mm.arms.len:
                    ownership_collect_expr(read(mm.arms.data + mi).value, released, released_lines, transferred, path, warnings)
                    mi += 1
            ast.Expr.expr_prefix_cast as pc:
                ownership_collect_expr(pc.expression, released, released_lines, transferred, path, warnings)
            ast.Expr.expr_unsafe as us:
                ownership_collect_expr(us.expression, released, released_lines, transferred, path, warnings)
            ast.Expr.expr_await as aw:
                ownership_collect_expr(aw.expression, released, released_lines, transferred, path, warnings)
            ast.Expr.expr_detach as dt:
                ownership_collect_expr(dt.expression, released, released_lines, transferred, path, warnings)
            ast.Expr.expr_expression_list as el:
                var ei: ptr_uint = 0
                while ei < el.elements.len:
                    ownership_collect_expr(el.elements.data + ei, released, released_lines, transferred, path, warnings)
                    ei += 1
            _:
                pass


function ownership_collect_expr_opt(expr: ptr[ast.Expr]?, released: ref[vec.Vec[str]], released_lines: ref[map_mod.Map[str, ptr_uint]], transferred: ref[vec.Vec[str]], path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    let ep = expr else:
        return
    ownership_collect_expr(ep, released, released_lines, transferred, path, warnings)


function ownership_recurse_stmt(stmt: ptr[ast.Stmt], path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    unsafe:
        match read(stmt):
            ast.Stmt.stmt_if as iff:
                var bi: ptr_uint = 0
                while bi < iff.branches.len:
                    ownership_collect_body(read(iff.branches.data + bi).body, path, warnings)
                    bi += 1
                ownership_collect_body_opt(iff.else_body, path, warnings)
            ast.Stmt.stmt_match as mt:
                var ai: ptr_uint = 0
                while ai < mt.arms.len:
                    ownership_collect_body(read(mt.arms.data + ai).body, path, warnings)
                    ai += 1
            ast.Stmt.stmt_while as wh:
                ownership_collect_body_opt(wh.body, path, warnings)
            ast.Stmt.stmt_for as fr:
                ownership_collect_body_opt(fr.body, path, warnings)
            ast.Stmt.stmt_unsafe as un:
                ownership_collect_body_opt(un.body, path, warnings)
            ast.Stmt.stmt_defer as df:
                ownership_collect_body_opt(df.body, path, warnings)
            ast.Stmt.stmt_block as blk:
                ownership_walk_stmts(blk.statements, path, warnings)
            ast.Stmt.stmt_when as wn:
                var wi: ptr_uint = 0
                while wi < wn.branches.len:
                    let wbr = read(wn.branches.data + wi)
                    var wsi: ptr_uint = 0
                    while wsi < wbr.body.len:
                        ownership_recurse_stmt(wbr.body.data + wsi, path, warnings)
                        wsi += 1
                    wi += 1
                ownership_collect_body_opt(wn.else_body, path, warnings)
            _:
                pass


## True when `expr` is an ownership-creating call (heap.must_alloc, Vec.create, etc.).
function own_creating_call(expr: ptr[ast.Expr]?) -> bool:
    let ep = expr else:
        return false
    unsafe:
        match read(ep):
            ast.Expr.expr_call as call:
                match read(call.callee):
                    ast.Expr.expr_member_access as ma:
                        if is_create_method_name(ma.member_name):
                            return true
                        return false
                    ast.Expr.expr_specialization as sp:
                        match read(sp.callee):
                            ast.Expr.expr_member_access as ma2:
                                if is_alloc_method_name(ma2.member_name):
                                    return true
                            _:
                                pass
                        return false
                    _:
                        return false
            _:
                return false


function is_create_method_name(name: str) -> bool:
    false


function is_alloc_method_name(name: str) -> bool:
    return name.equal("must_alloc") or name.equal("alloc") or name.equal("must_alloc_zeroed") or name.equal("must_resize") or name.equal("resize")


## True when `expr` is a `.release()` or `.release_and_null()` call.
function is_release_call_expr(expr: ptr[ast.Expr]) -> bool:
    unsafe:
        match read(expr):
            ast.Expr.expr_member_access as ma:
                return ma.member_name.equal("release") or ma.member_name.equal("release_and_null")
            _:
                return false


## Record transfers: when `target` is an identifier (struct field assignment or
## similar), and `value` contains an owning name, that name is transferred.
function ownership_collect_transfer_in_args(value: ptr[ast.Expr], target: ptr[ast.Expr], transferred: ref[vec.Vec[str]]) -> void:
    unsafe:
        match read(value):
            ast.Expr.expr_identifier as id:
                # Check if target is accessing a struct field (transfer ownership).
                match read(target):
                    ast.Expr.expr_member_access:
                        if not ownership_contains(transferred, id.name):
                            transferred.push(id.name)
                    _:
                        pass
            _:
                pass


## Record return transfers: a returned identifier transfers ownership.
function ownership_collect_ret_transfer(value: ptr[ast.Expr]?, transferred: ref[vec.Vec[str]]) -> void:
    let vp = value else:
        return
    unsafe:
        match read(vp):
            ast.Expr.expr_identifier as id:
                if not ownership_contains(transferred, id.name):
                    transferred.push(id.name)
            _:
                pass


## True when `expr` is a struct constructor call that takes an owning value
## (transfers ownership). For AST-only, we just record names passed to any call.
function ownership_transfer_ctor(expr: ptr[ast.Expr]?, target_name: str) -> bool:
    false
