## The `milkTea/debugInfo` AST section: a port of the host's generic renderer
## (`lib/milk_tea/tooling/debug_info_formatter.rb`), which walks Ruby `Data`
## AST nodes via their class member lists.  The self's AST is variant-based, so
## each host class has a hand-written counterpart here, with the host's member
## order, labels and skip rules (`line`, `column`, `length`, `module_kind`,
## `visibility`, `name` never render as members; `name` feeds the header).
##
## Two host quirks are reproduced deliberately:
##   - `EnumDecl`/`FlagsDecl` declare a member named `members`, which shadows
##     the reflection method, so they render NO children at all;
##   - `body` members are arrays on the host but a single `stmt_block` here, so
##     parents unwrap the block and render its statements as the array.

import std.fmt
import std.string as string
import std.vec as vec

import mtc.float_text as float_text
import mtc.parser.ast as ast
import mtc.lsp.debug_text as debug_text


## ── Section entry ────────────────────────────────────────────────────────────

public function append_ast_section(target: ref[string.String], file: ast.SourceFile) -> void:
    target.append("\n\n── AST  1 SourceFile, ")
    target.append_format(f"#{file.imports.len} imports, ")
    target.append_format(f"#{file.directives.len} directives, ")
    target.append_format(f"#{file.declarations.len} declarations ")
    debug_text.append_rule(target, 50)

    # The root: `SourceFile` with the host's members imports, directives,
    # declarations, node_ids, node_path_ids.  `node_ids`/`node_path_ids` always
    # render (non-empty hashes), so they are the last two members; the arrays
    # before them are never the last rendered member.
    ast_header(target, "", true, "SourceFile", false, "", 0z, 0z)

    let cp = "   "
    render_decl_array(target, file.imports, cp, false, "imports")
    render_decl_array(target, file.directives, cp, false, "directives")
    render_decl_array(target, file.declarations, cp, false, "declarations")
    render_count_leaf(target, cp, false, "node_ids", count_ast_nodes(file))
    render_count_leaf(target, cp, true, "node_path_ids", count_ast_nodes(file))


## ── Line helpers ─────────────────────────────────────────────────────────────

function ast_line(target: ref[string.String], prefix: str, is_last: bool, text: str) -> void:
    target.append("\n")
    target.append(prefix)
    target.append(if is_last: "└─ " else: "├─ ")
    target.append(text)


function ast_leaf(target: ref[string.String], prefix: str, is_last: bool, member: str, value: str) -> void:
    target.append("\n")
    target.append(prefix)
    target.append(if is_last: "└─ " else: "├─ ")
    target.append(member)
    target.append(": ")
    target.append(value)


## `Kind [Ln N, Col M]` — the column renders even when 0 (Ruby's 0 is truthy
## and the host stores 0 for some positions).
function ast_header_always_column(target: ref[string.String], prefix: str, is_last: bool, kind: str, line: ptr_uint, column: ptr_uint) -> void:
    var text = string.String.create()
    defer: text.release()
    text.append(kind)
    if line > 0:
        text.append(" [Ln ")
        text.append_format(f"#{line}")
        text.append(", Col ")
        text.append_format(f"#{column}")
        text.append("]")
    ast_line(target, prefix, is_last, text.as_str())


## The line the host stores on an expression node (0 when the self's variant
## carries no position field for it).
function expr_line(e: ast.Expr) -> ptr_uint:
    match e:
        ast.Expr.expr_identifier as d:
            return d.line
        ast.Expr.expr_char_literal as d:
            return d.line
        ast.Expr.expr_null_literal as d:
            return d.line
        ast.Expr.expr_member_access as d:
            return d.line
        ast.Expr.expr_detach as d:
            return d.line
        ast.Expr.expr_expression_list as d:
            return d.line
        ast.Expr.expr_range as d:
            return d.line
        ast.Expr.expr_prefix_cast as d:
            return d.line
        ast.Expr.expr_unsafe as d:
            return d.line
        ast.Expr.expr_match as d:
            return d.line
        ast.Expr.expr_error as d:
            return d.line
        else:
            return 0


## See `expr_line`.
function expr_column(e: ast.Expr) -> ptr_uint:
    match e:
        ast.Expr.expr_identifier as d:
            return d.column
        ast.Expr.expr_char_literal as d:
            return d.column
        ast.Expr.expr_null_literal as d:
            return d.column
        ast.Expr.expr_member_access as d:
            return d.column
        ast.Expr.expr_detach as d:
            return d.column
        ast.Expr.expr_expression_list as d:
            return d.column
        ast.Expr.expr_range as d:
            return d.column
        ast.Expr.expr_prefix_cast as d:
            return d.column
        ast.Expr.expr_unsafe as d:
            return d.column
        ast.Expr.expr_match as d:
            return d.column
        ast.Expr.expr_error as d:
            return d.column
        else:
            return 0


## `Kind ◆ name [Ln N, Col M]`.
function ast_header(target: ref[string.String], prefix: str, is_last: bool, kind: str, has_name: bool, name: str, line: ptr_uint, column: ptr_uint) -> void:
    var text = string.String.create()
    defer: text.release()
    text.append(kind)
    if has_name:
        text.append(" ◆ ")
        text.append(name)
    if line > 0:
        text.append(" [Ln ")
        text.append_format(f"#{line}")
        if column > 0:
            text.append(", Col ")
            text.append_format(f"#{column}")
        text.append("]")
    ast_line(target, prefix, is_last, text.as_str())


## `◆ <member> (N):` — an array member that has children.
function ast_container_line(target: ref[string.String], prefix: str, is_last: bool, member: str, count: ptr_uint, colon: bool) -> void:
    var text = string.String.create()
    defer: text.release()
    text.append("◆ ")
    text.append(member)
    text.append_format(f" (#{count})")
    if colon:
        text.append(":")
    ast_line(target, prefix, is_last, text.as_str())


## `◆ <member> (N)  "a", "b"` — an array of plain strings.
function ast_string_array_line(target: ref[string.String], prefix: str, is_last: bool, member: str, values: span[str]) -> void:
    var text = string.String.create()
    defer: text.release()
    text.append("◆ ")
    text.append(member)
    text.append_format(f" (#{values.len})  ")
    var i: ptr_uint = 0
    while i < values.len:
        if i > 0:
            text.append(", ")
        var repr = debug_text.ruby_string_value(unsafe: read(values.data + i))
        text.append(repr.as_str())
        repr.release()
        i += 1
    ast_line(target, prefix, is_last, text.as_str())


## `node_ids: {N entries}` (the host's `value_repr` for a Hash).
function render_count_leaf(target: ref[string.String], prefix: str, is_last: bool, member: str, count: ptr_uint) -> void:
    var text = string.String.create()
    defer: text.release()
    text.append("{")
    text.append_format(f"#{count}")
    text.append(" entries}")
    ast_leaf(target, prefix, is_last, member, text.as_str())


function render_int_leaf(target: ref[string.String], prefix: str, is_last: bool, member: str, value: ptr_uint) -> void:
    var text = string.String.create()
    defer: text.release()
    text.append_format(f"#{value}")
    ast_leaf(target, prefix, is_last, member, text.as_str())


function render_str_leaf(target: ref[string.String], prefix: str, is_last: bool, member: str, value: str) -> void:
    var repr = debug_text.ruby_string_value(value)
    defer: repr.release()
    ast_leaf(target, prefix, is_last, member, repr.as_str())


function render_bool_leaf(target: ref[string.String], prefix: str, is_last: bool, member: str, value: bool) -> void:
    ast_leaf(target, prefix, is_last, member, if value: "true" else: "false")


function render_option_int_leaf(target: ref[string.String], prefix: str, is_last: bool, member: str, value: ptr_uint) -> void:
    render_int_leaf(target, prefix, is_last, member, value)


## ── Compact nodes ────────────────────────────────────────────────────────────

function compact_qualified_name(q: ast.QualifiedName) -> string.String:
    var text = string.String.create()
    text.append("QualifiedName(")
    var i: ptr_uint = 0
    while i < q.parts.len:
        if i > 0:
            text.append(".")
        text.append(unsafe: read(q.parts.data + i))
        i += 1
    if q.type_arguments.len > 0:
        text.append("<")
        var j: ptr_uint = 0
        while j < q.type_arguments.len:
            if j > 0:
                text.append(", ")
            let arg = unsafe: read(q.type_arguments.data + j)
            var arg_repr = value_repr_type_ref(arg)
            text.append(arg_repr.as_str())
            arg_repr.release()
            j += 1
        text.append(">")
    text.append(")")
    return text


## `value_repr(TypeRef)`: the object falls through to `TypeRef(<name to_s>)`.
function value_repr_type_ref(t: ast.TypeRef) -> string.String:
    var text = string.String.create()
    text.append("TypeRef(")
    var name_text = qualified_name_to_s(t.name)
    text.append(name_text.as_str())
    name_text.release()
    text.append(")")
    return text


## `QualifiedName#to_s`: `parts.join(".")`, truncated like `value_repr` does
## for a string longer than 59 characters.
function qualified_name_to_s(q: ast.QualifiedName) -> string.String:
    var text = string.String.create()
    var i: ptr_uint = 0
    while i < q.parts.len:
        if i > 0:
            text.append(".")
        text.append(unsafe: read(q.parts.data + i))
        i += 1
    if debug_text.utf8_char_count(text.as_str()) < 60:
        return text
    let stop = debug_text.utf8_prefix_bytes(text.as_str(), 57)
    var truncated = string.String.create()
    truncated.append(text.as_str()[0..stop])
    truncated.append("...")
    text.release()
    return truncated


## `compact_ast_repr(TypeRef)`: `name[args]`, `?`-prefixed when nullable.
## The self encodes the host's FunctionType/ProcType/TupleType/DynType nodes
## inside a TypeRef; those render as their own subtrees (see
## `render_type_member`), never through here.
function compact_type_ref(t: ast.TypeRef) -> string.String:
    var core = string.String.create()
    var name = qualified_name_to_s(t.name)
    core.append(name.as_str())
    name.release()
    if t.arguments.len > 0:
        core.append("[")
        var i: ptr_uint = 0
        while i < t.arguments.len:
            if i > 0:
                core.append(", ")
            var arg = compact_type_ref(unsafe: read(t.arguments.data + i))
            core.append(arg.as_str())
            arg.release()
            i += 1
        core.append("]")
    var text = string.String.create()
    if t.nullable:
        text.append("?")
    text.append(core.as_str())
    core.release()
    return text


## A type in a member position: a plain TypeRef renders `member: <repr>`; the
## host's non-compact type nodes (fn/proc/tuple/dyn) render as a subtree with
## no label.
function render_type_member(target: ref[string.String], t: ast.TypeRef, prefix: str, is_last: bool, member: str) -> void:
    if type_is_compact(t):
        var repr = compact_type_ref(t)
        defer: repr.release()
        ast_leaf(target, prefix, is_last, member, repr.as_str())
        return
    render_type_node(target, t, prefix, is_last)


function type_is_compact(t: ast.TypeRef) -> bool:
    if t.is_fn or t.is_proc or t.is_tuple or t.is_dyn:
        return false
    return true


## A type as an array element: compact types render their repr line, others
## their subtree (the host's `format_ast_node`, no label either way).
function render_type_child(target: ref[string.String], t: ast.TypeRef, prefix: str, is_last: bool) -> void:
    if type_is_compact(t):
        var repr = compact_type_ref(t)
        defer: repr.release()
        ast_line(target, prefix, is_last, repr.as_str())
        return
    render_type_node(target, t, prefix, is_last)


function render_type_node(target: ref[string.String], t: ast.TypeRef, prefix: str, is_last: bool) -> void:
    if t.is_fn:
        render_function_type(target, t, prefix, is_last, "FunctionType")
    else if t.is_proc:
        render_function_type(target, t, prefix, is_last, "ProcType")
    else if t.is_tuple:
        ast_header(target, prefix, is_last, "TupleType", false, "", 0z, 0z)
        let cp = if is_last: "   " else: "│  "
        var last: int = 0
        if t.nullable:
            last = 1
        if t.arguments.len > 0:
            ast_container_line(target, prefix + cp, last == 0, "element_types", t.arguments.len, true)
            var i: ptr_uint = 0
            while i < t.arguments.len:
                render_type_child(target, unsafe: read(t.arguments.data + i), prefix + cp + (if last == 0: "   " else: "│  "), i == t.arguments.len - 1)
                i += 1
        if t.nullable:
            render_bool_leaf(target, prefix + cp, true, "nullable", true)
    else:
        ast_header(target, prefix, is_last, "DynType", false, "", t.line, t.column)
        let cp = if is_last: "   " else: "│  "
        var last: int = 0
        if t.nullable:
            last = 1
        var iface = compact_qualified_name(t.dyn_interface)
        defer: iface.release()
        ast_leaf(target, prefix + cp, last == 0, "interface", iface.as_str())
        if t.nullable:
            render_bool_leaf(target, prefix + cp, true, "nullable", true)


function render_function_type(target: ref[string.String], t: ast.TypeRef, prefix: str, is_last: bool, kind: str) -> void:
    ast_header(target, prefix, is_last, kind, false, "", 0z, 0z)
    let cp = if is_last: "   " else: "│  "
    let ret_ptr = t.fn_return
    var last: int = 0
    if t.fn_params.len > 0:
        last = 1
    if ret_ptr != null:
        last = 2
    if t.fn_params.len > 0:
        render_param_array(target, t.fn_params, prefix + cp, last == 1, "params")
    if ret_ptr != null:
        render_type_member(target, unsafe: read(ret_ptr), prefix + cp, last == 2, "return_type")


function append_param_names(target: ref[string.String], params: span[ast.Param]) -> void:
    var i: ptr_uint = 0
    while i < params.len:
        if i > 0:
            target.append(", ")
        let param = unsafe: read(params.data + i)
        target.append(param.name)
        target.append(": ")
        var ty = compact_type_ref(param.param_type)
        target.append(ty.as_str())
        ty.release()
        i += 1


## `TypeArg(<repr of the value>)`.
function compact_type_argument(a: ast.TypeArgument) -> string.String:
    var text = string.String.create()
    text.append("TypeArg(")
    let value = unsafe: read(a.value)
    if type_is_compact(value):
        var inner = compact_type_ref(value)
        text.append(inner.as_str())
        inner.release()
    else if value.is_fn:
        text.append("FunctionType")
    else if value.is_proc:
        text.append("ProcType")
    else if value.is_tuple:
        text.append("TupleType")
    else:
        text.append("DynType")
    text.append(")")
    return text


## `compact_ast_repr(Identifier)`: `id:<name>`.
function compact_identifier(name: str) -> string.String:
    var text = string.String.create()
    text.append("id:")
    text.append(name)
    return text


function expr_is_compact(e: ast.Expr) -> bool:
    match e:
        ast.Expr.expr_identifier as _d:
            return true
        ast.Expr.expr_integer_literal as _d:
            return true
        ast.Expr.expr_float_literal as _d:
            return true
        ast.Expr.expr_string_literal as _d:
            return true
        ast.Expr.expr_bool_literal as _d:
            return true
        ast.Expr.expr_null_literal as _d:
            return true
        ast.Expr.expr_format_string as _d:
            return true
        else:
            return false


function compact_expr(e: ast.Expr) -> string.String:
    match e:
        ast.Expr.expr_identifier as d:
            return compact_identifier(d.name)
        ast.Expr.expr_integer_literal as d:
            var text = string.String.create()
            append_long(ref_of(text), d.value)
            return text
        ast.Expr.expr_float_literal as d:
            return string.String.from_str(float_text.double_to_str(d.value))
        ast.Expr.expr_string_literal as d:
            return debug_text.ruby_inspect(d.value)
        ast.Expr.expr_bool_literal as d:
            return string.String.from_str(if d.value: "true" else: "false")
        ast.Expr.expr_null_literal as _d:
            return string.String.from_str("null")
        ast.Expr.expr_format_string as d:
            var text = string.String.create()
            text.append("f")
            var i: ptr_uint = 0
            while i < d.parts.len:
                append_format_part_repr(ref_of(text), unsafe: read(d.parts.data + i))
                i += 1
            return text
        else:
            return string.String.from_str("?")


function append_format_part_repr(target: ref[string.String], part: ast.FormatStringPart) -> void:
    var full = string.String.create()
    match part:
        ast.FormatStringPart.fmt_text as d:
            full.append("#<data MilkTea::AST::FormatTextPart value=")
            var inner = debug_text.ruby_inspect(d.value)
            full.append(inner.as_str())
            inner.release()
            full.append(", line=nil, column=nil>")
        ast.FormatStringPart.fmt_expr as d:
            full.append("#<data MilkTea::AST::FormatExprPart expression=")
            var expr_repr = data_to_s_expr(unsafe: read(d.expression))
            full.append(expr_repr.as_str())
            expr_repr.release()
            full.append(", format_spec=nil, line=nil, column=nil>")
    append_ruby_truncated(target, full.as_str())
    full.release()


## `value_repr` truncation: `s.length < 60 ? s : "#{s[0..56]}..."`.
function append_ruby_truncated(target: ref[string.String], text: str) -> void:
    if debug_text.utf8_char_count(text) < 60:
        target.append(text)
        return
    let stop = debug_text.utf8_prefix_bytes(text, 57)
    target.append(text[0..stop])
    target.append("...")


## `Data#to_s` of an AST expression (used inside a format part's repr).
function data_to_s_expr(e: ast.Expr) -> string.String:
    match e:
        ast.Expr.expr_identifier as d:
            var text = string.String.create()
            text.append("#<data MilkTea::AST::Identifier name=")
            var name_repr = debug_text.ruby_inspect(d.name)
            text.append(name_repr.as_str())
            name_repr.release()
            text.append(", line=nil, column=nil>")
            return text
        ast.Expr.expr_member_access as d:
            var text = string.String.create()
            text.append("#<data MilkTea::AST::MemberAccess receiver=")
            var recv = data_to_s_expr(unsafe: read(d.receiver))
            text.append(recv.as_str())
            recv.release()
            text.append(", member=")
            var member_repr = debug_text.ruby_inspect(d.member_name)
            text.append(member_repr.as_str())
            member_repr.release()
            text.append(", line=nil, column=nil>")
            return text
        else:
            return string.String.from_str("#<data MilkTea::AST::Node>")


## `◆ <member> (N)  :a, :b` — an array of symbols.
function render_symbol_array_line(target: ref[string.String], prefix: str, is_last: bool, member: str, values: span[str]) -> void:
    var text = string.String.create()
    defer: text.release()
    text.append("◆ ")
    text.append(member)
    text.append_format(f" (#{values.len})  ")
    var i: ptr_uint = 0
    while i < values.len:
        if i > 0:
            text.append(", ")
        text.append(":")
        text.append(unsafe: read(values.data + i))
        i += 1
    ast_line(target, prefix, is_last, text.as_str())


function append_long(target: ref[string.String], value: long) -> void:
    target.append_format(f"#{value}")


## ── Expressions ──────────────────────────────────────────────────────────────

function render_expr(target: ref[string.String], e: ast.Expr, prefix: str, is_last: bool) -> void:
    if expr_is_compact(e):
        var repr = compact_expr(e)
        defer: repr.release()
        ast_line(target, prefix, is_last, repr.as_str())
        return
    match e:
        ast.Expr.expr_identifier as _d:
            return
        ast.Expr.expr_integer_literal as _d:
            return
        ast.Expr.expr_float_literal as _d:
            return
        ast.Expr.expr_string_literal as _d:
            return
        ast.Expr.expr_bool_literal as _d:
            return
        ast.Expr.expr_null_literal as _d:
            return
        ast.Expr.expr_format_string as _d:
            return
        ast.Expr.expr_binary_op as d:
            ast_header(target, prefix, is_last, "BinaryOp", false, "", 0z, 0z)
            let cp = if is_last: "   " else: "│  "
            render_str_leaf(target, prefix + cp, false, "operator", d.operator)
            render_expr_member(target, unsafe: read(d.left), prefix + cp, false, "left")
            render_expr_member(target, unsafe: read(d.right), prefix + cp, true, "right")
        ast.Expr.expr_member_access as d:
            ast_header(target, prefix, is_last, "MemberAccess", false, "", d.line, d.column)
            let cp = if is_last: "   " else: "│  "
            render_expr_member(target, unsafe: read(d.receiver), prefix + cp, false, "receiver")
            render_str_leaf(target, prefix + cp, true, "member", d.member_name)
        ast.Expr.expr_call as d:
            ast_header(target, prefix, is_last, "Call", false, "", 0z, 0z)
            let cp = if is_last: "   " else: "│  "
            var last: int = 0
            if d.args.len > 0:
                last = 1
            render_expr_member(target, unsafe: read(d.callee), prefix + cp, last == 0, "callee")
            if d.args.len > 0:
                render_argument_array(target, d.args, prefix + cp, true, "arguments")
        else:
            render_expr_rest(target, e, prefix, is_last)


## A member holding an expression: compact ones render `member: repr`, others
## recurse with no label (the host's `format_ast_node` call).
function render_expr_member(target: ref[string.String], e: ast.Expr, prefix: str, is_last: bool, member: str) -> void:
    if expr_is_compact(e):
        var repr = compact_expr(e)
        defer: repr.release()
        ast_leaf(target, prefix, is_last, member, repr.as_str())
        return
    render_expr(target, e, prefix, is_last)


function render_argument_array(target: ref[string.String], args: span[ast.Argument], prefix: str, is_last: bool, member: str) -> void:
    ast_container_line(target, prefix, is_last, member, args.len, true)
    let cp = if is_last: "   " else: "│  "
    var i: ptr_uint = 0
    while i < args.len:
        let arg = unsafe: read(args.data + i)
        if arg.arg_name.is_some():
            let name = arg.arg_name.unwrap()
            ast_header(target, prefix + cp, i == args.len - 1, "Argument", true, name, 0z, 0z)
        else:
            ast_header(target, prefix + cp, i == args.len - 1, "Argument", false, "", 0z, 0z)
        let arg_cp = if i == args.len - 1: "   " else: "│  "
        render_expr_member(target, unsafe: read(arg.arg_value), prefix + cp + arg_cp, true, "value")
        i += 1


## ── Statements ───────────────────────────────────────────────────────────────

function render_stmt(target: ref[string.String], s: ast.Stmt, prefix: str, is_last: bool) -> void:
    match s:
        ast.Stmt.stmt_local as _d:
            render_local_decl(target, s, prefix, is_last)
        ast.Stmt.stmt_assignment as d:
            ast_header(target, prefix, is_last, "Assignment", false, "", d.line, d.column)
            let cp = if is_last: "   " else: "│  "
            render_expr_member(target, unsafe: read(d.target), prefix + cp, false, "target")
            render_str_leaf(target, prefix + cp, false, "operator", d.operator)
            render_expr_member(target, unsafe: read(d.value), prefix + cp, true, "value")
        ast.Stmt.stmt_ret as d:
            ast_header(target, prefix, is_last, "ReturnStmt", false, "", d.line, d.column)
            let ret_ptr = d.value
            if ret_ptr != null:
                let cp = if is_last: "   " else: "│  "
                render_expr_member(target, unsafe: read(ret_ptr), prefix + cp, true, "value")
        else:
            render_stmt_rest(target, s, prefix, is_last)


## `LocalDecl(kind, name, type, value, else_binding, else_body, line, column,
## recovered_else, destructure_bindings, destructure_type_name)`.
function render_local_decl(target: ref[string.String], d: ast.Stmt, prefix: str, is_last: bool) -> void:
    match d:
        ast.Stmt.stmt_local as s:
            ast_header(target, prefix, is_last, "LocalDecl", s.name.len > 0, s.name, s.line, s.column)
            let cp = if is_last: "   " else: "│  "
            let type_ptr = s.stmt_type
            let value_ptr = s.value
            let else_body_ptr = s.else_body
            var last: int = 0
            if type_ptr != null:
                last = 1
            if value_ptr != null:
                last = 2
            if s.else_binding.is_some():
                last = 3
            if else_body_ptr != null:
                last = 4
            if s.destructure_bindings.is_some():
                last = 5
            if s.destructure_type_name.is_some():
                last = 6
            ast_leaf(target, prefix + cp, last == 0, "kind", if s.is_let: ":let" else: ":var")
            if type_ptr != null:
                render_type_member(target, unsafe: read(type_ptr), prefix + cp, last == 1, "type")
            if value_ptr != null:
                render_expr_member(target, unsafe: read(value_ptr), prefix + cp, last == 2, "value")
            if s.else_binding.is_some():
                # The host stores the binding as an Identifier expression.
                var binding_text = string.String.create()
                defer: binding_text.release()
                binding_text.append("id:")
                binding_text.append(s.else_binding.unwrap())
                ast_leaf(target, prefix + cp, last == 3, "else_binding", binding_text.as_str())
            if else_body_ptr != null:
                render_block_array(target, unsafe: read(else_body_ptr), prefix + cp, last == 4, "else_body")
            if s.destructure_bindings.is_some():
                let bindings = s.destructure_bindings.unwrap()
                ast_string_array_line(target, prefix + cp, last == 5, "destructure_bindings", bindings)
            if s.destructure_type_name.is_some():
                render_str_leaf(target, prefix + cp, last == 6, "destructure_type_name", s.destructure_type_name.unwrap())
        else:
            return


## `body`-family members: the host's array vs the self's single block.
function render_block_array(target: ref[string.String], block: ast.Stmt, prefix: str, is_last: bool, member: str) -> void:
    match block:
        ast.Stmt.stmt_block as b:
            ast_container_line(target, prefix, is_last, member, b.statements.len, true)
            let cp = if is_last: "   " else: "│  "
            var i: ptr_uint = 0
            while i < b.statements.len:
                render_stmt(target, unsafe: read(b.statements.data + i), prefix + cp, i == b.statements.len - 1)
                i += 1
        else:
            ast_container_line(target, prefix, is_last, member, 1, true)
            let cp = if is_last: "   " else: "│  "
            render_stmt(target, block, prefix + cp, true)


## ── Declarations ─────────────────────────────────────────────────────────────

function render_decl_array(target: ref[string.String], items: span[ast.Decl], prefix: str, is_last: bool, member: str) -> void:
    if items.len == 0:
        return
    ast_container_line(target, prefix, is_last, member, items.len, true)
    let cp = if is_last: "   " else: "│  "
    var i: ptr_uint = 0
    while i < items.len:
        render_decl(target, unsafe: read(items.data + i), prefix + cp, i == items.len - 1)
        i += 1


function render_decl(target: ref[string.String], d: ast.Decl, prefix: str, is_last: bool) -> void:
    match d:
        ast.Decl.decl_import as imp:
            ast_header(target, prefix, is_last, "Import", false, "", imp.line, imp.column)
            let cp = if is_last: "   " else: "│  "
            var last: int = 0
            if imp.alias_name.is_some():
                last = 1
            var path = compact_qualified_name(imp.path)
            defer: path.release()
            ast_leaf(target, prefix + cp, last == 0, "path", path.as_str())
            if imp.alias_name.is_some():
                render_str_leaf(target, prefix + cp, true, "alias_name", imp.alias_name.unwrap())
        ast.Decl.decl_struct as _s:
            render_struct_decl(target, d, prefix, is_last)
        ast.Decl.decl_extending_block as _s:
            render_extending_block(target, d, prefix, is_last)
        ast.Decl.decl_interface as _s:
            render_interface_decl(target, d, prefix, is_last)
        ast.Decl.decl_enum as s:
            # `members` shadows the reflection method on the host, so no
            # members render at all.
            ast_header(target, prefix, is_last, "EnumDecl", true, s.name, s.line, s.column)
        ast.Decl.decl_variant as s:
            ast_header(target, prefix, is_last, "VariantDecl", true, s.name, s.line, s.column)
            let cp = if is_last: "   " else: "│  "
            var last: int = 0
            if s.type_params.len > 0:
                last = 1
            if s.variant_arms.len > 0:
                last = 2
            if s.variant_attrs.len > 0:
                last = 3
            if s.type_params.len > 0:
                render_type_param_array(target, s.type_params, prefix + cp, last == 1, "type_params")
            if s.variant_arms.len > 0:
                render_variant_arm_array(target, s.variant_arms, prefix + cp, last == 2, "arms")
            if s.variant_attrs.len > 0:
                render_attr_array(target, s.variant_attrs, prefix + cp, last == 3, "attributes")
        ast.Decl.decl_function as _s:
            render_function_decl(target, d, prefix, is_last)
        else:
            render_decl_rest(target, d, prefix, is_last)


function render_struct_decl(target: ref[string.String], s: ast.Decl, prefix: str, is_last: bool) -> void:
    match s:
        ast.Decl.decl_struct as d:
            ast_header(target, prefix, is_last, "StructDecl", true, d.name, d.line, d.column)
            let cp = if is_last: "   " else: "│  "
            var last: int = 0
            if d.type_params.len > 0:
                last = 1
            if d.impl_list.len > 0:
                last = 2
            if d.c_name.is_some():
                last = 3
            if d.struct_fields.len > 0:
                last = 4
            if d.struct_events.len > 0:
                last = 5
            if d.nested_types.len > 0:
                last = 6
            if d.struct_attrs.len > 0:
                last = 7
            if d.packed:
                last = 8
            if d.alignment != 0:
                last = 9
            if d.lifetime_params.len > 0:
                last = 10
            if d.type_params.len > 0:
                render_type_param_array(target, d.type_params, prefix + cp, last == 1, "type_params")
            if d.impl_list.len > 0:
                render_qname_array(target, d.impl_list, prefix + cp, last == 2, "implements")
            if d.c_name.is_some():
                render_str_leaf(target, prefix + cp, last == 3, "c_name", d.c_name.unwrap())
            if d.struct_fields.len > 0:
                render_field_array(target, d.struct_fields, prefix + cp, last == 4, "fields", true)
            if d.struct_events.len > 0:
                render_decl_array(target, d.struct_events, prefix + cp, last == 5, "events")
            if d.nested_types.len > 0:
                render_decl_array(target, d.nested_types, prefix + cp, last == 6, "nested_types")
            if d.struct_attrs.len > 0:
                render_attr_array(target, d.struct_attrs, prefix + cp, last == 7, "attributes")
            if d.packed:
                render_bool_leaf(target, prefix + cp, last == 8, "packed", true)
            if d.alignment != 0:
                render_int_leaf(target, prefix + cp, last == 9, "alignment", ptr_uint<-d.alignment)
            if d.lifetime_params.len > 0:
                ast_string_array_line(target, prefix + cp, last == 10, "lifetime_params", d.lifetime_params)
        else:
            return


function render_extending_block(target: ref[string.String], s: ast.Decl, prefix: str, is_last: bool) -> void:
    match s:
        ast.Decl.decl_extending_block as d:
            ast_header(target, prefix, is_last, "ExtendingBlock", false, "", d.line, d.column)
            let cp = if is_last: "   " else: "│  "
            var last: int = 1
            if d.methods.len > 0:
                last = 2
            if d.is_inline:
                last = 3
            render_type_member(target, unsafe: read(d.type_name), prefix + cp, last == 1, "type_name")
            if d.methods.len > 0:
                render_method_array(target, d.methods, prefix + cp, last == 2, "methods")
            if d.is_inline:
                render_bool_leaf(target, prefix + cp, last == 3, "inline", true)
        else:
            return


function render_interface_decl(target: ref[string.String], s: ast.Decl, prefix: str, is_last: bool) -> void:
    match s:
        ast.Decl.decl_interface as d:
            ast_header(target, prefix, is_last, "InterfaceDecl", true, d.name, d.line, d.column)
            let cp = if is_last: "   " else: "│  "
            var last: int = 0
            if d.type_params.len > 0:
                last = 1
            if d.interface_methods.len > 0:
                last = 2
            if d.type_params.len > 0:
                render_type_param_array(target, d.type_params, prefix + cp, last == 1, "type_params")
            if d.interface_methods.len > 0:
                render_interface_method_array(target, d.interface_methods, prefix + cp, last == 2, "methods")
        else:
            return


function render_function_decl(target: ref[string.String], s: ast.Decl, prefix: str, is_last: bool) -> void:
    match s:
        ast.Decl.decl_function as d:
            ast_header(target, prefix, is_last, "FunctionDef", true, d.name, d.line, d.column)
            let cp = if is_last: "   " else: "│  "
            let ret_ptr = d.return_type
            let body_ptr = d.body
            var has_body = false
            if body_ptr != null:
                has_body = not block_is_empty(unsafe: read(body_ptr))
            var last: int = 0
            if d.type_params.len > 0:
                last = 1
            if d.method_params.len > 0:
                last = 2
            if ret_ptr != null:
                last = 3
            if has_body:
                last = 4
            if d.is_async:
                last = 5
            if d.is_const:
                last = 6
            if d.attributes.len > 0:
                last = 7
            if d.type_params.len > 0:
                render_type_param_array(target, d.type_params, prefix + cp, last == 1, "type_params")
            if d.method_params.len > 0:
                render_param_array(target, d.method_params, prefix + cp, last == 2, "params")
            if ret_ptr != null:
                render_type_member(target, unsafe: read(ret_ptr), prefix + cp, last == 3, "return_type")
            if has_body:
                let bp = body_ptr
                if bp != null:
                    render_block_array(target, unsafe: read(bp), prefix + cp, last == 4, "body")
            if d.is_async:
                render_bool_leaf(target, prefix + cp, last == 5, "async", true)
            if d.is_const:
                render_bool_leaf(target, prefix + cp, last == 6, "const", true)
            if d.attributes.len > 0:
                render_attr_array(target, d.attributes, prefix + cp, last == 7, "attributes")
        else:
            return


## ── Members ──────────────────────────────────────────────────────────────────

function render_field_array(target: ref[string.String], fields: span[ast.Field], prefix: str, is_last: bool, member: str, with_location: bool) -> void:
    ast_container_line(target, prefix, is_last, member, fields.len, true)
    let cp = if is_last: "   " else: "│  "
    var i: ptr_uint = 0
    while i < fields.len:
        let f = unsafe: read(fields.data + i)
        let line = if with_location: f.line else: 0z
        let column = if with_location: f.column else: 0z
        ast_header(target, prefix + cp, i == fields.len - 1, "Field", true, f.name, line, column)
        let fcp = if i == fields.len - 1: "   " else: "│  "
        var last: int = 0
        if f.attributes.len > 0:
            last = 1
        render_type_member(target, f.field_type, prefix + cp + fcp, last == 0, "type")
        if f.attributes.len > 0:
            render_attr_array(target, f.attributes, prefix + cp + fcp, true, "attributes")
        i += 1


function render_param_array(target: ref[string.String], params: span[ast.Param], prefix: str, is_last: bool, member: str) -> void:
    ast_container_line(target, prefix, is_last, member, params.len, true)
    let cp = if is_last: "   " else: "│  "
    var i: ptr_uint = 0
    while i < params.len:
        let p = unsafe: read(params.data + i)
        ast_header(target, prefix + cp, i == params.len - 1, "Param", true, p.name, p.line, p.column)
        let pcp = if i == params.len - 1: "   " else: "│  "
        let default_ptr = p.default_value
        var last: int = 0
        if default_ptr != null:
            last = 1
        render_type_member(target, p.param_type, prefix + cp + pcp, last == 0, "type")
        if default_ptr != null:
            render_expr_member(target, unsafe: read(default_ptr), prefix + cp + pcp, true, "default_value")
        i += 1


function render_type_param_array(target: ref[string.String], params: span[ast.TypeParam], prefix: str, is_last: bool, member: str) -> void:
    ast_container_line(target, prefix, is_last, member, params.len, true)
    let cp = if is_last: "   " else: "│  "
    var i: ptr_uint = 0
    while i < params.len:
        let p = unsafe: read(params.data + i)
        if p.is_value:
            # The host has a separate ValueTypeParam node (`N: int`).
            ast_header(target, prefix + cp, i == params.len - 1, "ValueTypeParam", true, p.name, p.line, p.column)
            let vcp = if i == params.len - 1: "   " else: "│  "
            let value_type_ptr = p.value_type
            if value_type_ptr != null:
                render_type_member(target, unsafe: read(value_type_ptr), prefix + cp + vcp, true, "type")
            i += 1
            continue
        ast_header(target, prefix + cp, i == params.len - 1, "TypeParam", true, p.name, p.line, p.column)
        let pcp = if i == params.len - 1: "   " else: "│  "
        if p.constraints.len > 0:
            ast_container_line(target, prefix + cp + pcp, true, "constraints", p.constraints.len, true)
            let constraint_prefix = prefix + cp + pcp + "   "
            var j: ptr_uint = 0
            while j < p.constraints.len:
                let c = unsafe: read(p.constraints.data + j)
                ast_header(target, constraint_prefix, j == p.constraints.len - 1, "TypeParamConstraint", false, "", 0z, 0z)
                let member_cp = constraint_prefix + (if j == p.constraints.len - 1: "   " else: "│  ")
                ast_leaf(target, member_cp, false, "kind", ":interface")
                var iface = compact_qualified_name(c.interface_ref)
                defer: iface.release()
                ast_leaf(target, member_cp, true, "interface_ref", iface.as_str())
                j += 1
        i += 1


function render_variant_arm_array(target: ref[string.String], arms: span[ast.VariantArm], prefix: str, is_last: bool, member: str) -> void:
    ast_container_line(target, prefix, is_last, member, arms.len, true)
    let cp = if is_last: "   " else: "│  "
    var i: ptr_uint = 0
    while i < arms.len:
        let arm = unsafe: read(arms.data + i)
        ast_header(target, prefix + cp, i == arms.len - 1, "VariantArm", true, arm.name, 0z, 0z)
        let acp = if i == arms.len - 1: "   " else: "│  "
        if arm.arm_fields.len > 0:
            render_field_array(target, arm.arm_fields, prefix + cp + acp, true, "fields", false)
        i += 1


function render_method_array(target: ref[string.String], methods: span[ast.Method], prefix: str, is_last: bool, member: str) -> void:
    ast_container_line(target, prefix, is_last, member, methods.len, true)
    let cp = if is_last: "   " else: "│  "
    var i: ptr_uint = 0
    while i < methods.len:
        render_method(target, unsafe: read(methods.data + i), prefix + cp, i == methods.len - 1)
        i += 1


function render_method(target: ref[string.String], m: ast.Method, prefix: str, is_last: bool) -> void:
    ast_header(target, prefix, is_last, "MethodDef", true, m.name, m.line, m.column)
    let cp = if is_last: "   " else: "│  "
    let ret_ptr = m.return_type
    let body_ptr = m.body
    let has_body = not block_is_empty(unsafe: read(body_ptr))
    var last: int = 0
    if m.type_params.len > 0:
        last = 1
    if m.method_params.len > 0:
        last = 2
    if ret_ptr != null:
        last = 3
    if has_body:
        last = 4
    # `kind` always renders.
    last = 5
    if m.is_async:
        last = 6
    if m.is_const:
        last = 7
    if m.attributes.len > 0:
        last = 8
    if m.type_params.len > 0:
        render_type_param_array(target, m.type_params, prefix + cp, last == 1, "type_params")
    if m.method_params.len > 0:
        render_param_array(target, m.method_params, prefix + cp, last == 2, "params")
    if ret_ptr != null:
        render_type_member(target, unsafe: read(ret_ptr), prefix + cp, last == 3, "return_type")
    if has_body:
        render_block_array(target, unsafe: read(body_ptr), prefix + cp, last == 4, "body")
    render_method_kind_leaf(target, prefix + cp, last == 5, "kind", m.method_kind)
    if m.is_async:
        render_bool_leaf(target, prefix + cp, last == 6, "async", true)
    if m.is_const:
        render_bool_leaf(target, prefix + cp, last == 7, "const", true)
    if m.attributes.len > 0:
        render_attr_array(target, m.attributes, prefix + cp, last == 8, "attributes")


## The host's `body` members are arrays; an empty array is skipped entirely.
function block_is_empty(block: ast.Stmt) -> bool:
    match block:
        ast.Stmt.stmt_block as b:
            return b.statements.len == 0
        else:
            return false


function render_method_kind_leaf(target: ref[string.String], prefix: str, is_last: bool, member: str, kind: ast.MethodKind) -> void:
    var text = ":plain"
    if kind == ast.MethodKind.mk_editable:
        text = ":editable"
    else if kind == ast.MethodKind.mk_static:
        text = ":static"
    ast_leaf(target, prefix, is_last, member, text)


function render_interface_method_array(target: ref[string.String], methods: span[ast.InterfaceMethod], prefix: str, is_last: bool, member: str) -> void:
    ast_container_line(target, prefix, is_last, member, methods.len, true)
    let cp = if is_last: "   " else: "│  "
    var i: ptr_uint = 0
    while i < methods.len:
        let m = unsafe: read(methods.data + i)
        ast_header(target, prefix + cp, i == methods.len - 1, "InterfaceMethodDecl", true, m.name, m.line, m.column)
        let mcp = if i == methods.len - 1: "   " else: "│  "
        let ret_ptr = m.return_type
        var last: int = 0
        if m.method_params.len > 0:
            last = 1
        if ret_ptr != null:
            last = 2
        # `kind` always renders.
        last = 3
        if m.is_async:
            last = 4
        if m.attributes.len > 0:
            last = 5
        if m.method_params.len > 0:
            render_param_array(target, m.method_params, prefix + cp + mcp, last == 1, "params")
        if ret_ptr != null:
            render_type_member(target, unsafe: read(ret_ptr), prefix + cp + mcp, last == 2, "return_type")
        render_method_kind_leaf(target, prefix + cp + mcp, last == 3, "kind", m.method_kind)
        if m.is_async:
            render_bool_leaf(target, prefix + cp + mcp, last == 4, "async", true)
        if m.attributes.len > 0:
            render_attr_array(target, m.attributes, prefix + cp + mcp, last == 5, "attributes")
        i += 1


function render_qname_array(target: ref[string.String], names: span[ast.QualifiedName], prefix: str, is_last: bool, member: str) -> void:
    ast_container_line(target, prefix, is_last, member, names.len, true)
    let cp = if is_last: "   " else: "│  "
    var i: ptr_uint = 0
    while i < names.len:
        var repr = compact_qualified_name(unsafe: read(names.data + i))
        defer: repr.release()
        ast_line(target, prefix + cp, i == names.len - 1, repr.as_str())
        i += 1


function render_attr_array(target: ref[string.String], attrs: span[ast.AttributeApplication], prefix: str, is_last: bool, member: str) -> void:
    ast_container_line(target, prefix, is_last, member, attrs.len, true)
    let cp = if is_last: "   " else: "│  "
    var i: ptr_uint = 0
    while i < attrs.len:
        let a = unsafe: read(attrs.data + i)
        var name_text = qualified_name_to_s(a.name)
        defer: name_text.release()
        ast_header(target, prefix + cp, i == attrs.len - 1, "AttributeApplication", true, name_text.as_str(), a.line, a.column)
        let acp = if i == attrs.len - 1: "   " else: "│  "
        if a.arguments.len > 0:
            render_argument_array(target, a.arguments, prefix + cp + acp, true, "arguments")
        i += 1


## ── Remaining declaration kinds ─────────────────────────────────────────────

function render_decl_rest(target: ref[string.String], d: ast.Decl, prefix: str, is_last: bool) -> void:
    match d:
        ast.Decl.decl_const as x:
            ast_header(target, prefix, is_last, "ConstDecl", true, x.name, x.line, x.column)
            let cp = if is_last: "   " else: "│  "
            let value_ptr = x.value
            let block_ptr = x.block_body
            var has_block = false
            if block_ptr != null:
                has_block = not block_is_empty(unsafe: read(block_ptr))
            var last: int = 0
            if value_ptr != null:
                last = 1
            if has_block:
                last = 2
            if x.attributes.len > 0:
                last = 3
            render_type_member(target, unsafe: read(x.const_type), prefix + cp, last == 0, "type")
            if value_ptr != null:
                render_expr_member(target, unsafe: read(value_ptr), prefix + cp, last == 1, "value")
            if has_block:
                let bp = block_ptr
                if bp != null:
                    render_block_array(target, unsafe: read(bp), prefix + cp, last == 2, "block_body")
            if x.attributes.len > 0:
                render_attr_array(target, x.attributes, prefix + cp, last == 3, "attributes")
        ast.Decl.decl_var as x:
            ast_header(target, prefix, is_last, "VarDecl", true, x.name, x.line, x.column)
            let cp = if is_last: "   " else: "│  "
            let type_ptr = x.var_type
            let value_ptr = x.value
            var last: int = 0
            if type_ptr != null:
                last = 1
            if value_ptr != null:
                last = 2
            if type_ptr != null:
                render_type_member(target, unsafe: read(type_ptr), prefix + cp, last == 1, "type")
            if value_ptr != null:
                render_expr_member(target, unsafe: read(value_ptr), prefix + cp, last == 2, "value")
        ast.Decl.decl_union as x:
            ast_header(target, prefix, is_last, "UnionDecl", true, x.name, x.line, x.column)
            let cp = if is_last: "   " else: "│  "
            var last: int = 0
            if x.c_name.is_some():
                last = 1
            if x.union_fields.len > 0:
                last = 2
            if x.union_attrs.len > 0:
                last = 3
            if x.c_name.is_some():
                render_str_leaf(target, prefix + cp, last == 1, "c_name", x.c_name.unwrap())
            if x.union_fields.len > 0:
                render_field_array(target, x.union_fields, prefix + cp, last == 2, "fields", false)
            if x.union_attrs.len > 0:
                render_attr_array(target, x.union_attrs, prefix + cp, last == 3, "attributes")
        ast.Decl.decl_flags as x:
            # `members` shadows the reflection method on the host.
            ast_header(target, prefix, is_last, "FlagsDecl", true, x.name, x.line, x.column)
        ast.Decl.decl_opaque as x:
            ast_header(target, prefix, is_last, "OpaqueDecl", true, x.name, x.line, x.column)
            let cp = if is_last: "   " else: "│  "
            var last: int = 0
            if x.opaque_implements.len > 0:
                last = 1
            if x.c_name.is_some():
                last = 2
            if x.opaque_implements.len > 0:
                render_qname_array(target, x.opaque_implements, prefix + cp, last == 1, "implements")
            if x.c_name.is_some():
                render_str_leaf(target, prefix + cp, last == 2, "c_name", x.c_name.unwrap())
        ast.Decl.decl_type_alias as x:
            ast_header(target, prefix, is_last, "TypeAliasDecl", true, x.name, x.line, x.column)
            let cp = if is_last: "   " else: "│  "
            render_type_member(target, unsafe: read(x.target), prefix + cp, true, "target")
        ast.Decl.decl_attribute as x:
            ast_header(target, prefix, is_last, "AttributeDecl", true, x.name, x.line, x.column)
            let cp = if is_last: "   " else: "│  "
            var last: int = 0
            if x.targets.len > 0:
                last = 1
            if x.attr_params.len > 0:
                last = 2
            if x.targets.len > 0:
                render_symbol_array_line(target, prefix + cp, last == 1, "targets", x.targets)
            if x.attr_params.len > 0:
                render_param_array(target, x.attr_params, prefix + cp, last == 2, "params")
        ast.Decl.decl_static_assert as x:
            ast_header(target, prefix, is_last, "StaticAssert", false, "", x.line, 0z)
            let cp = if is_last: "   " else: "│  "
            let message_ptr = x.message
            var last: int = 0
            if message_ptr != null:
                last = 1
            render_expr_member(target, unsafe: read(x.condition), prefix + cp, last == 0, "condition")
            if message_ptr != null:
                render_expr_member(target, unsafe: read(message_ptr), prefix + cp, true, "message")
        ast.Decl.decl_when as x:
            render_when_decl_stmt(target, x.discriminant, x.branches, x.else_body, prefix, is_last, x.line, x.column)
        ast.Decl.decl_link as x:
            render_directive(target, "LinkDirective", x.value, x.line, x.column, prefix, is_last)
        ast.Decl.decl_include as x:
            render_directive(target, "IncludeDirective", x.value, x.line, x.column, prefix, is_last)
        ast.Decl.decl_compiler_flag as x:
            render_directive(target, "CompilerFlagDirective", x.value, x.line, x.column, prefix, is_last)
        ast.Decl.decl_extern_function as x:
            ast_header(target, prefix, is_last, "ExternFunctionDecl", true, x.name, x.line, 0z)
            let cp = if is_last: "   " else: "│  "
            let ret_ptr = x.return_type
            let mapping_ptr = x.mapping
            var last: int = 0
            if x.type_params.len > 0:
                last = 1
            if x.extern_params.len > 0:
                last = 2
            if ret_ptr != null:
                last = 3
            if x.variadic:
                last = 4
            if x.attrs.len > 0:
                last = 5
            if mapping_ptr != null:
                last = 6
            if x.type_params.len > 0:
                render_type_param_array(target, x.type_params, prefix + cp, last == 1, "type_params")
            if x.extern_params.len > 0:
                render_foreign_param_array(target, x.extern_params, prefix + cp, last == 2, "params")
            if ret_ptr != null:
                render_type_member(target, unsafe: read(ret_ptr), prefix + cp, last == 3, "return_type")
            if x.variadic:
                render_bool_leaf(target, prefix + cp, last == 4, "variadic", true)
            if x.attrs.len > 0:
                render_attr_array(target, x.attrs, prefix + cp, last == 5, "attributes")
            if mapping_ptr != null:
                render_expr_member(target, unsafe: read(mapping_ptr), prefix + cp, last == 6, "mapping")
        ast.Decl.decl_foreign_function as x:
            ast_header(target, prefix, is_last, "ForeignFunctionDecl", true, x.name, x.line, 0z)
            let cp = if is_last: "   " else: "│  "
            var last: int = 0
            if x.type_params.len > 0:
                last = 1
            if x.foreign_params.len > 0:
                last = 2
            last = 3
            if x.variadic:
                last = 4
            # `mapping` always renders.
            last = 5
            if x.attrs.len > 0:
                last = 6
            if x.type_params.len > 0:
                render_type_param_array(target, x.type_params, prefix + cp, last == 1, "type_params")
            if x.foreign_params.len > 0:
                render_foreign_param_array(target, x.foreign_params, prefix + cp, last == 2, "params")
            render_type_member(target, unsafe: read(x.return_type), prefix + cp, last == 3, "return_type")
            if x.variadic:
                render_bool_leaf(target, prefix + cp, last == 4, "variadic", true)
            render_expr_member(target, unsafe: read(x.mapping), prefix + cp, last == 5, "mapping")
            if x.attrs.len > 0:
                render_attr_array(target, x.attrs, prefix + cp, last == 6, "attributes")
        ast.Decl.decl_event as x:
            ast_header(target, prefix, is_last, "EventDecl", true, x.name, x.line, x.column)
            let cp = if is_last: "   " else: "│  "
            let payload_ptr = x.payload_type
            var last: int = 0
            last = 1
            if payload_ptr != null:
                last = 2
            if x.attrs.len > 0:
                last = 3
            render_int_leaf(target, prefix + cp, last == 1, "capacity", ptr_uint<-x.capacity)
            if payload_ptr != null:
                render_type_member(target, unsafe: read(payload_ptr), prefix + cp, last == 2, "payload_type")
            if x.attrs.len > 0:
                render_attr_array(target, x.attrs, prefix + cp, last == 3, "attributes")
        else:
            return


function render_directive(target: ref[string.String], kind: str, value: str, line: ptr_uint, column: ptr_uint, prefix: str, is_last: bool) -> void:
    ast_header(target, prefix, is_last, kind, false, "", line, column)
    let cp = if is_last: "   " else: "│  "
    render_str_leaf(target, prefix + cp, true, "value", value)


function render_foreign_param_array(target: ref[string.String], params: span[ast.ForeignParam], prefix: str, is_last: bool, member: str) -> void:
    ast_container_line(target, prefix, is_last, member, params.len, true)
    let cp = if is_last: "   " else: "│  "
    var i: ptr_uint = 0
    while i < params.len:
        let p = unsafe: read(params.data + i)
        let item_last = i == params.len - 1
        ast_header(target, prefix + cp, item_last, "ForeignParam", true, p.name, 0z, 0z)
        let pcp = if item_last: "   " else: "│  "
        var last: int = 1
        if p.boundary_type.is_some():
            last = 2
        render_type_member(target, p.param_type, prefix + cp + pcp, last == 0, "type")
        render_foreign_mode_leaf(target, prefix + cp + pcp, last == 1, "mode", p.param_mode)
        if p.boundary_type.is_some():
            render_type_member(target, p.boundary_type.unwrap(), prefix + cp + pcp, true, "boundary_type")
        i += 1


## The host's `ForeignParam.mode` is a Symbol.
function render_foreign_mode_leaf(target: ref[string.String], prefix: str, is_last: bool, member: str, mode: ast.ForeignParamMode) -> void:
    var text = ":plain"
    if mode == ast.ForeignParamMode.fmode_out:
        text = ":out"
    else if mode == ast.ForeignParamMode.fmode_in:
        text = ":in"
    else if mode == ast.ForeignParamMode.fmode_inout:
        text = ":inout"
    else if mode == ast.ForeignParamMode.fmode_consuming:
        text = ":consuming"
    ast_leaf(target, prefix, is_last, member, text)


## ── Remaining statement kinds ───────────────────────────────────────────────

function render_stmt_rest(target: ref[string.String], s: ast.Stmt, prefix: str, is_last: bool) -> void:
    match s:
        ast.Stmt.stmt_if as x:
            ast_header(target, prefix, is_last, "IfStmt", false, "", x.line, 0z)
            let cp = if is_last: "   " else: "│  "
            let else_ptr = x.else_body
            var has_else = false
            if else_ptr != null:
                has_else = not block_is_empty(unsafe: read(else_ptr))
            var last: int = 0
            if x.branches.len > 0:
                last = 1
            if has_else:
                last = 2
            if x.is_inline:
                last = 3
            if x.else_line > 0:
                last = 4
            if x.else_column > 0:
                last = 5
            if x.branches.len > 0:
                render_if_branch_array(target, x.branches, prefix + cp, last == 1, "branches")
            if has_else:
                let bp = else_ptr
                if bp != null:
                    render_block_array(target, unsafe: read(bp), prefix + cp, last == 2, "else_body")
            if x.is_inline:
                render_bool_leaf(target, prefix + cp, last == 3, "inline", true)
            if x.else_line > 0:
                render_int_leaf(target, prefix + cp, last == 4, "else_line", x.else_line)
            if x.else_column > 0:
                render_int_leaf(target, prefix + cp, last == 5, "else_column", x.else_column)
        ast.Stmt.stmt_while as x:
            ast_header(target, prefix, is_last, "WhileStmt", false, "", x.line, x.column)
            let cp = if is_last: "   " else: "│  "
            let body_ptr = x.body
            var has_body = false
            if body_ptr != null:
                has_body = not block_is_empty(unsafe: read(body_ptr))
            var last: int = 0
            last = 1
            if has_body:
                last = 2
            if x.is_inline:
                last = 3
            render_expr_member(target, unsafe: read(x.condition), prefix + cp, last == 1, "condition")
            if has_body:
                let bp = body_ptr
                if bp != null:
                    render_block_array(target, unsafe: read(bp), prefix + cp, last == 2, "body")
            if x.is_inline:
                render_bool_leaf(target, prefix + cp, last == 3, "inline", true)
        ast.Stmt.stmt_for as x:
            var has_name = false
            var first_name = ""
            if x.bindings.len > 0:
                has_name = true
                first_name = unsafe: read(x.bindings.data).name
            ast_header(target, prefix, is_last, "ForStmt", has_name, first_name, x.line, x.column)
            let cp = if is_last: "   " else: "│  "
            let body_ptr = x.body
            var has_body = false
            if body_ptr != null:
                has_body = not block_is_empty(unsafe: read(body_ptr))
            var last: int = 0
            if x.bindings.len > 0:
                last = 1
            if x.iterables.len > 0:
                last = 2
            if has_body:
                last = 3
            if x.is_inline:
                last = 4
            if x.threaded:
                last = 5
            if x.bindings.len > 0:
                render_for_binding_array(target, x.bindings, prefix + cp, last == 1, "bindings")
            if x.iterables.len > 0:
                render_expr_array(target, x.iterables, prefix + cp, last == 2, "iterables")
            if has_body:
                let bp = body_ptr
                if bp != null:
                    render_block_array(target, unsafe: read(bp), prefix + cp, last == 3, "body")
            if x.is_inline:
                render_bool_leaf(target, prefix + cp, last == 4, "inline", true)
            if x.threaded:
                render_bool_leaf(target, prefix + cp, last == 5, "threaded", true)
        ast.Stmt.stmt_match as x:
            ast_header(target, prefix, is_last, "MatchStmt", false, "", x.line, x.column)
            let cp = if is_last: "   " else: "│  "
            var last: int = 0
            last = 1
            if x.arms.len > 0:
                last = 2
            if x.is_inline:
                last = 3
            render_expr_member(target, unsafe: read(x.scrutinee), prefix + cp, last == 1, "expression")
            if x.arms.len > 0:
                render_match_arm_array(target, x.arms, prefix + cp, last == 2, "arms")
            if x.is_inline:
                render_bool_leaf(target, prefix + cp, last == 3, "inline", true)
        ast.Stmt.stmt_break as x:
            ast_header(target, prefix, is_last, "BreakStmt", false, "", x.line, x.column)
        ast.Stmt.stmt_continue as x:
            ast_header(target, prefix, is_last, "ContinueStmt", false, "", x.line, x.column)
        ast.Stmt.stmt_pass as x:
            ast_header(target, prefix, is_last, "PassStmt", false, "", x.line, x.column)
        ast.Stmt.stmt_defer as x:
            ast_header(target, prefix, is_last, "DeferStmt", false, "", x.line, x.column)
            let cp = if is_last: "   " else: "│  "
            let body_ptr = x.body
            let expr_ptr = x.expression
            var has_body = false
            if body_ptr != null:
                has_body = not block_is_empty(unsafe: read(body_ptr))
            if has_body:
                let bp = body_ptr
                if bp != null:
                    render_block_array(target, unsafe: read(bp), prefix + cp, true, "body")
            else if expr_ptr != null:
                render_expr_member(target, unsafe: read(expr_ptr), prefix + cp, true, "body")
        ast.Stmt.stmt_unsafe as x:
            ast_header(target, prefix, is_last, "UnsafeStmt", false, "", x.line, x.column)
            let cp = if is_last: "   " else: "│  "
            let body_ptr = x.body
            var has_body = false
            if body_ptr != null:
                has_body = not block_is_empty(unsafe: read(body_ptr))
            if has_body:
                let bp = body_ptr
                if bp != null:
                    render_block_array(target, unsafe: read(bp), prefix + cp, true, "body")
        ast.Stmt.stmt_expression as x:
            ast_header(target, prefix, is_last, "ExpressionStmt", false, "", x.line, 0z)
            let cp = if is_last: "   " else: "│  "
            render_expr_member(target, unsafe: read(x.expression), prefix + cp, true, "expression")
        ast.Stmt.stmt_static_assert as x:
            ast_header(target, prefix, is_last, "StaticAssert", false, "", x.line, 0z)
            let cp = if is_last: "   " else: "│  "
            let message_ptr = x.message
            var last: int = 0
            if message_ptr != null:
                last = 1
            render_expr_member(target, unsafe: read(x.condition), prefix + cp, last == 0, "condition")
            if message_ptr != null:
                render_expr_member(target, unsafe: read(message_ptr), prefix + cp, true, "message")
        ast.Stmt.stmt_emit as x:
            ast_header(target, prefix, is_last, "EmitStmt", false, "", x.line, x.column)
            let cp = if is_last: "   " else: "│  "
            let decl_ptr = x.declaration
            if decl_ptr != null:
                render_decl(target, unsafe: read(decl_ptr), prefix + cp, true)
        ast.Stmt.stmt_when as x:
            render_when_stmt(target, x.discriminant, x.branches, x.else_body, prefix, is_last, x.line, x.column)
        ast.Stmt.stmt_parallel_block as x:
            ast_header(target, prefix, is_last, "ParallelBlockStmt", false, "", x.line, x.column)
            let cp = if is_last: "   " else: "│  "
            # The host's `bodies` is an array of arrays: only the count renders.
            ast_container_line(target, prefix + cp, true, "bodies", x.bodies.len, false)
        ast.Stmt.stmt_gather as x:
            ast_header(target, prefix, is_last, "GatherStmt", false, "", x.line, x.column)
            let cp = if is_last: "   " else: "│  "
            if x.handles.len > 0:
                render_expr_array(target, x.handles, prefix + cp, true, "handles")
        ast.Stmt.stmt_error as x:
            ast_header(target, prefix, is_last, "ErrorStmt", false, "", x.line, x.column)
            let cp = if is_last: "   " else: "│  "
            render_str_leaf(target, prefix + cp, true, "message", x.message)
        ast.Stmt.stmt_error_block as x:
            ast_header(target, prefix, is_last, "ErrorBlockStmt", false, "", x.line, 0z)
            let cp = if is_last: "   " else: "│  "
            let body_empty = block_is_empty(unsafe: read(x.body))
            var last: int = 0
            if not body_empty:
                last = 1
            if x.message.len > 0:
                last = 2
            if not body_empty:
                render_block_array(target, unsafe: read(x.body), prefix + cp, last == 1, "body")
            if x.message.len > 0:
                render_str_leaf(target, prefix + cp, last == 2, "message", x.message)
        ast.Stmt.stmt_block as b:
            # A block only ever appears as a parent's body; render defensively.
            render_block_array(target, s, prefix, is_last, "body")
        else:
            return


function render_if_branch_array(target: ref[string.String], branches: span[ast.IfBranch], prefix: str, is_last: bool, member: str) -> void:
    ast_container_line(target, prefix, is_last, member, branches.len, true)
    let cp = if is_last: "   " else: "│  "
    var i: ptr_uint = 0
    while i < branches.len:
        let br = unsafe: read(branches.data + i)
        let item_last = i == branches.len - 1
        ast_header(target, prefix + cp, item_last, "IfBranch", false, "", br.line, br.column)
        let bcp = if item_last: "   " else: "│  "
        let body_empty = block_is_empty(unsafe: read(br.body))
        var last: int = 0
        last = 1
        if not body_empty:
            last = 2
        render_expr_member(target, unsafe: read(br.condition), prefix + cp + bcp, last == 1, "condition")
        if not body_empty:
            render_block_array(target, unsafe: read(br.body), prefix + cp + bcp, last == 2, "body")
        i += 1


function render_for_binding_array(target: ref[string.String], bindings: span[ast.ForBinding], prefix: str, is_last: bool, member: str) -> void:
    ast_container_line(target, prefix, is_last, member, bindings.len, true)
    let cp = if is_last: "   " else: "│  "
    var i: ptr_uint = 0
    while i < bindings.len:
        let b = unsafe: read(bindings.data + i)
        ast_header(target, prefix + cp, i == bindings.len - 1, "ForBinding", true, b.name, b.line, b.column)
        i += 1


function render_match_arm_array(target: ref[string.String], arms: span[ast.MatchArm], prefix: str, is_last: bool, member: str) -> void:
    ast_container_line(target, prefix, is_last, member, arms.len, true)
    let cp = if is_last: "   " else: "│  "
    var i: ptr_uint = 0
    while i < arms.len:
        let arm = unsafe: read(arms.data + i)
        let item_last = i == arms.len - 1
        var arm_line = 0z
        var arm_column = 0z
        let arm_pat = arm.pattern
        if arm_pat != null:
            arm_line = expr_line(unsafe: read(arm_pat))
            arm_column = expr_column(unsafe: read(arm_pat))
        else:
            arm_line = arm.wildcard_line
            arm_column = arm.wildcard_column
        ast_header(target, prefix + cp, item_last, "MatchArm", false, "", arm_line, arm_column)
        let acp = if item_last: "   " else: "│  "
        let pattern_ptr = arm.pattern
        let body_ptr = arm.body
        var has_body = false
        if body_ptr != null:
            has_body = not block_is_empty(unsafe: read(body_ptr))
        var last: int = 0
        let has_pattern = pattern_ptr != null or arm.wildcard_line > 0
        if has_pattern:
            last = 1
        if arm.binding_name.is_some():
            last = 2
        if arm.binding_line > 0:
            last = 3
        if arm.binding_column > 0:
            last = 4
        if has_body:
            last = 5
        if pattern_ptr != null:
            render_expr_member(target, unsafe: read(pattern_ptr), prefix + cp + acp, last == 1, "pattern")
        else if arm.wildcard_line > 0:
            ast_leaf(target, prefix + cp + acp, last == 1, "pattern", "id:_")
        if arm.binding_name.is_some():
            render_str_leaf(target, prefix + cp + acp, last == 2, "binding_name", arm.binding_name.unwrap())
        if arm.binding_line > 0:
            render_int_leaf(target, prefix + cp + acp, last == 3, "binding_line", arm.binding_line)
        if arm.binding_column > 0:
            render_int_leaf(target, prefix + cp + acp, last == 4, "binding_column", arm.binding_column)
        if has_body:
            let bp = body_ptr
            if bp != null:
                render_block_array(target, unsafe: read(bp), prefix + cp + acp, last == 5, "body")
        i += 1


function render_when_stmt(target: ref[string.String], discriminant: ptr[ast.Expr], branches: span[ast.WhenBranch], else_body: ptr[ast.Stmt]?, prefix: str, is_last: bool, line: ptr_uint, column: ptr_uint) -> void:
    ast_header(target, prefix, is_last, "WhenStmt", false, "", line, column)
    let cp = if is_last: "   " else: "│  "
    let else_ptr = else_body
    var has_else = false
    if else_ptr != null:
        has_else = not block_is_empty(unsafe: read(else_ptr))
    var last: int = 0
    last = 1
    if branches.len > 0:
        last = 2
    if has_else:
        last = 3
    render_expr_member(target, unsafe: read(discriminant), prefix + cp, last == 1, "discriminant")
    if branches.len > 0:
        # The statement form's branches are MatchArm nodes on the host.
        render_when_match_arm_array(target, branches, prefix + cp, last == 2, "branches")
    if has_else:
        let bp = else_ptr
        if bp != null:
            render_block_array(target, unsafe: read(bp), prefix + cp, last == 3, "else_body")


## The module-level `when`: the host parses it as the same `WhenStmt`, with
## `WhenBranch` arms whose bodies are declarations.
function render_when_decl_stmt(target: ref[string.String], discriminant: ptr[ast.Expr], branches: span[ast.WhenDeclBranch], else_body: span[ast.Decl], prefix: str, is_last: bool, line: ptr_uint, column: ptr_uint) -> void:
    ast_header(target, prefix, is_last, "WhenStmt", false, "", line, column)
    let cp = if is_last: "   " else: "│  "
    var last: int = 0
    last = 1
    if branches.len > 0:
        last = 2
    if else_body.len > 0:
        last = 3
    render_expr_member(target, unsafe: read(discriminant), prefix + cp, last == 1, "discriminant")
    if branches.len > 0:
        ast_container_line(target, prefix + cp, last == 2, "branches", branches.len, true)
        let bcp = if last == 2: "   " else: "│  "
        var i: ptr_uint = 0
        while i < branches.len:
            let br = unsafe: read(branches.data + i)
            let item_last = i == branches.len - 1
            let br_pat = unsafe: read(br.pattern)
            ast_header(target, prefix + cp + bcp, item_last, "WhenBranch", false, "", expr_line(br_pat), expr_column(br_pat))
            let wcp = if item_last: "   " else: "│  "
            var br_last: int = 1
            if br.binding_name.is_some():
                br_last = 2
            if br.binding_line > 0:
                br_last = 3
            if br.binding_column > 0:
                br_last = 4
            if br.body.len > 0:
                br_last = 5
            render_expr_member(target, br_pat, prefix + cp + bcp + wcp, br_last == 1, "pattern")
            if br.binding_name.is_some():
                render_str_leaf(target, prefix + cp + bcp + wcp, br_last == 2, "binding_name", br.binding_name.unwrap())
            if br.binding_line > 0:
                render_int_leaf(target, prefix + cp + bcp + wcp, br_last == 3, "binding_line", br.binding_line)
            if br.binding_column > 0:
                render_int_leaf(target, prefix + cp + bcp + wcp, br_last == 4, "binding_column", br.binding_column)
            if br.body.len > 0:
                ast_container_line(target, prefix + cp + bcp + wcp, br_last == 5, "body", br.body.len, true)
                let body_cp = if br_last == 5: "   " else: "│  "
                var j: ptr_uint = 0
                while j < br.body.len:
                    render_decl(target, unsafe: read(br.body.data + j), prefix + cp + bcp + wcp + body_cp, j == br.body.len - 1)
                    j += 1
            i += 1
    if else_body.len > 0:
        ast_container_line(target, prefix + cp, last == 3, "else_body", else_body.len, true)
        let ecp = if last == 3: "   " else: "│  "
        var k: ptr_uint = 0
        while k < else_body.len:
            render_decl(target, unsafe: read(else_body.data + k), prefix + cp + ecp, k == else_body.len - 1)
            k += 1


## The statement form's `when` branches are MatchArm nodes on the host.
function render_when_match_arm_array(target: ref[string.String], branches: span[ast.WhenBranch], prefix: str, is_last: bool, member: str) -> void:
    ast_container_line(target, prefix, is_last, member, branches.len, true)
    let cp = if is_last: "   " else: "│  "
    var i: ptr_uint = 0
    while i < branches.len:
        let br = unsafe: read(branches.data + i)
        let item_last = i == branches.len - 1
        let arm_pat = unsafe: read(br.pattern)
        ast_header(target, prefix + cp, item_last, "MatchArm", false, "", expr_line(arm_pat), expr_column(arm_pat))
        let acp = if item_last: "   " else: "│  "
        var last: int = 1
        if br.binding_name.is_some():
            last = 2
        if br.binding_line > 0:
            last = 3
        if br.binding_column > 0:
            last = 4
        if br.body.len > 0:
            last = 5
        render_expr_member(target, arm_pat, prefix + cp + acp, last == 1, "pattern")
        if br.binding_name.is_some():
            render_str_leaf(target, prefix + cp + acp, last == 2, "binding_name", br.binding_name.unwrap())
        if br.binding_line > 0:
            render_int_leaf(target, prefix + cp + acp, last == 3, "binding_line", br.binding_line)
        if br.binding_column > 0:
            render_int_leaf(target, prefix + cp + acp, last == 4, "binding_column", br.binding_column)
        if br.body.len > 0:
            ast_container_line(target, prefix + cp + acp, last == 5, "body", br.body.len, true)
            let body_cp = if last == 5: "   " else: "│  "
            var j: ptr_uint = 0
            while j < br.body.len:
                render_stmt(target, unsafe: read(br.body.data + j), prefix + cp + acp + body_cp, j == br.body.len - 1)
                j += 1
        i += 1


## ── Remaining expression kinds ──────────────────────────────────────────────

function render_expr_array(target: ref[string.String], items: span[ast.Expr], prefix: str, is_last: bool, member: str) -> void:
    ast_container_line(target, prefix, is_last, member, items.len, true)
    let cp = if is_last: "   " else: "│  "
    var i: ptr_uint = 0
    while i < items.len:
        render_expr(target, unsafe: read(items.data + i), prefix + cp, i == items.len - 1)
        i += 1


function render_type_argument_array(target: ref[string.String], args: span[ast.TypeArgument], prefix: str, is_last: bool, member: str) -> void:
    ast_container_line(target, prefix, is_last, member, args.len, true)
    let cp = if is_last: "   " else: "│  "
    var i: ptr_uint = 0
    while i < args.len:
        var repr = compact_type_argument(unsafe: read(args.data + i))
        defer: repr.release()
        ast_line(target, prefix + cp, i == args.len - 1, repr.as_str())
        i += 1


function render_expr_rest(target: ref[string.String], e: ast.Expr, prefix: str, is_last: bool) -> void:
    match e:
        ast.Expr.expr_char_literal as x:
            ast_header(target, prefix, is_last, "CharLiteral", false, "", x.line, x.column)
            let cp = if is_last: "   " else: "│  "
            render_str_leaf(target, prefix + cp, false, "lexeme", x.lexeme)
            render_int_leaf(target, prefix + cp, true, "value", ptr_uint<-x.value)
        ast.Expr.expr_unary_op as x:
            ast_header(target, prefix, is_last, "UnaryOp", false, "", 0z, 0z)
            let cp = if is_last: "   " else: "│  "
            render_str_leaf(target, prefix + cp, false, "operator", x.operator)
            render_expr_member(target, unsafe: read(x.operand), prefix + cp, true, "operand")
        ast.Expr.expr_index_access as x:
            ast_header(target, prefix, is_last, "IndexAccess", false, "", 0z, 0z)
            let cp = if is_last: "   " else: "│  "
            render_expr_member(target, unsafe: read(x.receiver), prefix + cp, false, "receiver")
            render_expr_member(target, unsafe: read(x.index), prefix + cp, true, "index")
        ast.Expr.expr_specialization as x:
            ast_header(target, prefix, is_last, "Specialization", false, "", 0z, 0z)
            let cp = if is_last: "   " else: "│  "
            var last: int = 0
            last = 1
            if x.arguments.len > 0:
                last = 2
            render_expr_member(target, unsafe: read(x.callee), prefix + cp, last == 1, "callee")
            if x.arguments.len > 0:
                render_type_argument_array(target, x.arguments, prefix + cp, last == 2, "arguments")
        ast.Expr.expr_if as x:
            ast_header(target, prefix, is_last, "IfExpr", false, "", 0z, 0z)
            let cp = if is_last: "   " else: "│  "
            render_expr_member(target, unsafe: read(x.condition), prefix + cp, false, "condition")
            render_expr_member(target, unsafe: read(x.then_expr), prefix + cp, false, "then_expression")
            render_expr_member(target, unsafe: read(x.else_expr), prefix + cp, true, "else_expression")
        ast.Expr.expr_match as x:
            ast_header(target, prefix, is_last, "MatchExpr", false, "", x.line, x.column)
            let cp = if is_last: "   " else: "│  "
            var last: int = 0
            last = 1
            if x.arms.len > 0:
                last = 2
            if x.desugared_from_is:
                last = 3
            render_expr_member(target, unsafe: read(x.scrutinee), prefix + cp, last == 1, "expression")
            if x.arms.len > 0:
                render_match_expr_arm_array(target, x.arms, prefix + cp, last == 2, "arms")
            if x.desugared_from_is:
                render_bool_leaf(target, prefix + cp, last == 3, "desugared_from_is", true)
        ast.Expr.expr_proc as x:
            ast_header(target, prefix, is_last, "ProcExpr", false, "", 0z, 0z)
            let cp = if is_last: "   " else: "│  "
            let ret_ptr = x.return_type
            let body_empty = block_is_empty(unsafe: read(x.body))
            var last: int = 0
            if x.method_params.len > 0:
                last = 1
            if ret_ptr != null:
                last = 2
            if not body_empty:
                last = 3
            if x.method_params.len > 0:
                render_param_array(target, x.method_params, prefix + cp, last == 1, "params")
            if ret_ptr != null:
                render_type_member(target, unsafe: read(ret_ptr), prefix + cp, last == 2, "return_type")
            if not body_empty:
                render_block_array(target, unsafe: read(x.body), prefix + cp, last == 3, "body")
        ast.Expr.expr_await as x:
            ast_header(target, prefix, is_last, "AwaitExpr", false, "", 0z, 0z)
            let cp = if is_last: "   " else: "│  "
            render_expr_member(target, unsafe: read(x.expression), prefix + cp, true, "expression")
        ast.Expr.expr_detach as x:
            ast_header(target, prefix, is_last, "DetachExpr", false, "", x.line, x.column)
            let cp = if is_last: "   " else: "│  "
            # The host's body is `[ExpressionStmt(expression)]`.
            ast_container_line(target, prefix + cp, true, "body", 1, true)
            let scp = prefix + cp + "   "
            ast_header(target, scp, true, "ExpressionStmt", false, "", 0z, 0z)
            render_expr_member(target, unsafe: read(x.expression), scp + "   ", true, "expression")
        ast.Expr.expr_expression_list as x:
            ast_header(target, prefix, is_last, "ExpressionList", false, "", x.line, x.column)
            let cp = if is_last: "   " else: "│  "
            if x.elements.len > 0:
                render_expr_array(target, x.elements, prefix + cp, true, "elements")
        ast.Expr.expr_named as x:
            # A named element of a tuple literal: the host's `Argument`.
            ast_header(target, prefix, is_last, "Argument", true, x.name, 0z, 0z)
            let cp = if is_last: "   " else: "│  "
            render_expr_member(target, unsafe: read(x.value), prefix + cp, true, "value")
        ast.Expr.expr_range as x:
            # The host's column is `start_expr.column || 0` and 0 is truthy, so
            # the column always renders.
            let start_col = expr_column(unsafe: read(x.start_expr))
            ast_header_always_column(target, prefix, is_last, "RangeExpr", x.line, start_col)
            let cp = if is_last: "   " else: "│  "
            render_expr_member(target, unsafe: read(x.start_expr), prefix + cp, false, "start_expr")
            render_expr_member(target, unsafe: read(x.end_expr), prefix + cp, true, "end_expr")
        ast.Expr.expr_prefix_cast as x:
            ast_header(target, prefix, is_last, "PrefixCast", false, "", x.line, x.column)
            let cp = if is_last: "   " else: "│  "
            render_type_member(target, unsafe: read(x.target_type), prefix + cp, false, "target_type")
            render_expr_member(target, unsafe: read(x.expression), prefix + cp, true, "expression")
        ast.Expr.expr_unsafe as x:
            ast_header(target, prefix, is_last, "UnsafeExpr", false, "", x.line, x.column)
            let cp = if is_last: "   " else: "│  "
            render_expr_member(target, unsafe: read(x.expression), prefix + cp, true, "expression")
        ast.Expr.expr_sizeof as x:
            ast_header(target, prefix, is_last, "SizeofExpr", false, "", 0z, 0z)
            let cp = if is_last: "   " else: "│  "
            render_type_member(target, unsafe: read(x.target_type), prefix + cp, true, "type")
        ast.Expr.expr_alignof as x:
            ast_header(target, prefix, is_last, "AlignofExpr", false, "", 0z, 0z)
            let cp = if is_last: "   " else: "│  "
            render_type_member(target, unsafe: read(x.target_type), prefix + cp, true, "type")
        ast.Expr.expr_offsetof as x:
            ast_header(target, prefix, is_last, "OffsetofExpr", false, "", 0z, 0z)
            let cp = if is_last: "   " else: "│  "
            render_type_member(target, unsafe: read(x.target_type), prefix + cp, false, "type")
            render_str_leaf(target, prefix + cp, true, "field", x.field)
        ast.Expr.expr_error as x:
            ast_header(target, prefix, is_last, "ErrorExpr", false, "", x.line, x.column)
            let cp = if is_last: "   " else: "│  "
            render_str_leaf(target, prefix + cp, true, "message", x.message)
        else:
            return


function render_match_expr_arm_array(target: ref[string.String], arms: span[ast.MatchExprArm], prefix: str, is_last: bool, member: str) -> void:
    ast_container_line(target, prefix, is_last, member, arms.len, true)
    let cp = if is_last: "   " else: "│  "
    var i: ptr_uint = 0
    while i < arms.len:
        let arm = unsafe: read(arms.data + i)
        let item_last = i == arms.len - 1
        var arm_line = 0z
        var arm_column = 0z
        let arm_pat = arm.pattern
        if arm_pat != null:
            arm_line = expr_line(unsafe: read(arm_pat))
            arm_column = expr_column(unsafe: read(arm_pat))
        else:
            arm_line = arm.wildcard_line
            arm_column = arm.wildcard_column
        ast_header(target, prefix + cp, item_last, "MatchExprArm", false, "", arm_line, arm_column)
        let acp = if item_last: "   " else: "│  "
        let pattern_ptr = arm.pattern
        let has_pattern = pattern_ptr != null or arm.wildcard_line > 0
        var last: int = 0
        if has_pattern:
            last = 1
        if arm.binding_name.is_some():
            last = 2
        if arm.binding_line > 0:
            last = 3
        if arm.binding_column > 0:
            last = 4
        last = 5
        if pattern_ptr != null:
            render_expr_member(target, unsafe: read(pattern_ptr), prefix + cp + acp, last == 1, "pattern")
        else if arm.wildcard_line > 0:
            ast_leaf(target, prefix + cp + acp, last == 1, "pattern", "id:_")
        if arm.binding_name.is_some():
            render_str_leaf(target, prefix + cp + acp, last == 2, "binding_name", arm.binding_name.unwrap())
        if arm.binding_line > 0:
            render_int_leaf(target, prefix + cp + acp, last == 3, "binding_line", arm.binding_line)
        if arm.binding_column > 0:
            render_int_leaf(target, prefix + cp + acp, last == 4, "binding_column", arm.binding_column)
        render_expr_member(target, unsafe: read(arm.value), prefix + cp + acp, true, "value")
        i += 1


## ── Node counting (`assign_node_ids` semantics) ─────────────────────────────
## The host's `node_ids`/`node_path_ids` map sizes are the number of distinct
## Data objects its traversal reaches (a re-visit overwrites the same key), so
## both counts equal the size of the AST as the host sees it.  Two host shape
## rules matter: the self's `stmt_block` wrappers do not exist on the host (a
## block contributes its statements, never the wrapper), and the nested arrays
## inside `parallel` bodies are never traversed (the host only descends into
## Data values and one level of array elements).

function count_ast_nodes(file: ast.SourceFile) -> ptr_uint:
    var count: ptr_uint = 1
    var i: ptr_uint = 0
    while i < file.imports.len:
        count += count_decl(unsafe: read(file.imports.data + i))
        i += 1
    i = 0
    while i < file.directives.len:
        count += count_decl(unsafe: read(file.directives.data + i))
        i += 1
    i = 0
    while i < file.declarations.len:
        count += count_decl(unsafe: read(file.declarations.data + i))
        i += 1
    return count


function count_qname(q: ast.QualifiedName) -> ptr_uint:
    var count: ptr_uint = 1
    var i: ptr_uint = 0
    while i < q.type_arguments.len:
        count += count_type_ref(unsafe: read(q.type_arguments.data + i))
        i += 1
    return count


## A type position: the host may hold a TypeRef or a synthesized
## FunctionType/ProcType/TupleType/DynType node.
function count_type_ref(t: ast.TypeRef) -> ptr_uint:
    if t.is_fn:
        var count: ptr_uint = 1 + count_params(t.fn_params)
        let ret_ptr = t.fn_return
        if ret_ptr != null:
            count += count_type_ref(unsafe: read(ret_ptr))
        return count
    if t.is_proc:
        var count2: ptr_uint = 1 + count_params(t.fn_params)
        let ret_ptr2 = t.fn_return
        if ret_ptr2 != null:
            count2 += count_type_ref(unsafe: read(ret_ptr2))
        return count2
    if t.is_dyn:
        return 1 + count_qname(t.dyn_interface)
    if t.is_tuple:
        var count3: ptr_uint = 1
        var i: ptr_uint = 0
        while i < t.arguments.len:
            count3 += count_type_ref(unsafe: read(t.arguments.data + i))
            i += 1
        return count3
    var count4: ptr_uint = 1
    # The host's TypeRef name is a bare QualifiedName; the self's parser also
    # mirrors the arguments into `name.type_arguments`, which must not count.
    count4 += 1
    var i2: ptr_uint = 0
    while i2 < t.arguments.len:
        let argument = unsafe: read(t.arguments.data + i2)
        # The host wraps each argument in a TypeArgument node; a numeric value
        # argument is an IntegerLiteral/FloatLiteral node there, which the self
        # encodes as a synthetic, position-less TypeRef.
        count4 += 1
        if is_value_type_argument(argument):
            count4 += 1
        else:
            count4 += count_type_ref(argument)
        i2 += 1
    return count4


## True for the self's synthetic TypeRef standing in for a numeric type
## argument (`array[char, 4]`): no position, no structure.
function is_value_type_argument(t: ast.TypeRef) -> bool:
    if t.line != 0 or t.column != 0:
        return false
    if t.is_fn or t.is_proc or t.is_dyn or t.is_tuple:
        return false
    if t.arguments.len > 0:
        return false
    return true


function count_param(p: ast.Param) -> ptr_uint:
    var count: ptr_uint = 1 + count_type_ref(p.param_type)
    let default_ptr = p.default_value
    if default_ptr != null:
        count += count_expr(unsafe: read(default_ptr))
    return count


function count_params(params: span[ast.Param]) -> ptr_uint:
    var count: ptr_uint = 0
    var i: ptr_uint = 0
    while i < params.len:
        count += count_param(unsafe: read(params.data + i))
        i += 1
    return count


function count_field(f: ast.Field) -> ptr_uint:
    var count: ptr_uint = 1 + count_type_ref(f.field_type)
    var i: ptr_uint = 0
    while i < f.attributes.len:
        count += count_attr(unsafe: read(f.attributes.data + i))
        i += 1
    return count


function count_attr(a: ast.AttributeApplication) -> ptr_uint:
    var count: ptr_uint = 1 + count_qname(a.name)
    var i: ptr_uint = 0
    while i < a.arguments.len:
        count += count_argument(unsafe: read(a.arguments.data + i))
        i += 1
    return count


function count_attrs(attrs: span[ast.AttributeApplication]) -> ptr_uint:
    var count: ptr_uint = 0
    var i: ptr_uint = 0
    while i < attrs.len:
        count += count_attr(unsafe: read(attrs.data + i))
        i += 1
    return count


function count_argument(a: ast.Argument) -> ptr_uint:
    return 1 + count_expr(unsafe: read(a.arg_value))


function count_type_params(params: span[ast.TypeParam]) -> ptr_uint:
    var count: ptr_uint = 0
    var i: ptr_uint = 0
    while i < params.len:
        let p = unsafe: read(params.data + i)
        count += 1
        var j: ptr_uint = 0
        while j < p.constraints.len:
            count += 1
            let c = unsafe: read(p.constraints.data + j)
            count += count_qname(c.interface_ref)
            j += 1
        let value_type_ptr = p.value_type
        if value_type_ptr != null:
            count += count_type_ref(unsafe: read(value_type_ptr))
        i += 1
    return count


function count_enum_member(m: ast.EnumMember) -> ptr_uint:
    var count: ptr_uint = 1
    # Implicit members carry a synthesized value expression the host does not
    # have (`value_explicit` false).
    if m.value_explicit:
        let value_ptr = m.value
        if value_ptr != null:
            count += count_expr(unsafe: read(value_ptr))
    return count


function count_variant_arm(a: ast.VariantArm) -> ptr_uint:
    var count: ptr_uint = 1
    var i: ptr_uint = 0
    while i < a.arm_fields.len:
        count += count_field(unsafe: read(a.arm_fields.data + i))
        i += 1
    return count


function count_foreign_param(p: ast.ForeignParam) -> ptr_uint:
    var count: ptr_uint = 1 + count_type_ref(p.param_type)
    if p.boundary_type.is_some():
        count += count_type_ref(p.boundary_type.unwrap())
    return count


function count_interface_method(m: ast.InterfaceMethod) -> ptr_uint:
    var count: ptr_uint = 1 + count_params(m.method_params)
    let ret_ptr = m.return_type
    if ret_ptr != null:
        count += count_type_ref(unsafe: read(ret_ptr))
    count += count_attrs(m.attributes)
    return count


function count_method(m: ast.Method) -> ptr_uint:
    var count: ptr_uint = 1 + count_type_params(m.type_params) + count_params(m.method_params)
    let ret_ptr = m.return_type
    if ret_ptr != null:
        count += count_type_ref(unsafe: read(ret_ptr))
    count += count_block(unsafe: read(m.body))
    count += count_attrs(m.attributes)
    return count


## The host's `body` members are arrays: count their statements, not a wrapper.
function count_block(block: ast.Stmt) -> ptr_uint:
    match block:
        ast.Stmt.stmt_block as b:
            var count: ptr_uint = 0
            var i: ptr_uint = 0
            while i < b.statements.len:
                count += count_stmt(unsafe: read(b.statements.data + i))
                i += 1
            return count
        else:
            return count_stmt(block)


function count_stmt(s: ast.Stmt) -> ptr_uint:
    var count: ptr_uint = 1
    match s:
        ast.Stmt.stmt_block as b:
            var i: ptr_uint = 0
            while i < b.statements.len:
                count += count_stmt(unsafe: read(b.statements.data + i))
                i += 1
        ast.Stmt.stmt_local as x:
            let type_ptr = x.stmt_type
            if type_ptr != null:
                count += count_type_ref(unsafe: read(type_ptr))
            let value_ptr = x.value
            if value_ptr != null:
                count += count_expr(unsafe: read(value_ptr))
            let else_ptr = x.else_body
            if else_ptr != null:
                count += count_block(unsafe: read(else_ptr))
        ast.Stmt.stmt_assignment as x:
            count += count_expr(unsafe: read(x.target))
            count += count_expr(unsafe: read(x.value))
        ast.Stmt.stmt_if as x:
            var i: ptr_uint = 0
            while i < x.branches.len:
                let br = unsafe: read(x.branches.data + i)
                count += 1
                count += count_expr(unsafe: read(br.condition))
                count += count_block(unsafe: read(br.body))
                i += 1
            let else_ptr = x.else_body
            if else_ptr != null:
                count += count_block(unsafe: read(else_ptr))
        ast.Stmt.stmt_while as x:
            count += count_expr(unsafe: read(x.condition))
            let body_ptr = x.body
            if body_ptr != null:
                count += count_block(unsafe: read(body_ptr))
        ast.Stmt.stmt_for as x:
            var i: ptr_uint = 0
            while i < x.bindings.len:
                count += 1
                i += 1
            i = 0
            while i < x.iterables.len:
                count += count_expr(unsafe: read(x.iterables.data + i))
                i += 1
            let body_ptr = x.body
            if body_ptr != null:
                count += count_block(unsafe: read(body_ptr))
        ast.Stmt.stmt_match as x:
            count += count_expr(unsafe: read(x.scrutinee))
            var i: ptr_uint = 0
            while i < x.arms.len:
                count += count_match_arm(unsafe: read(x.arms.data + i))
                i += 1
        ast.Stmt.stmt_ret as x:
            let value_ptr = x.value
            if value_ptr != null:
                count += count_expr(unsafe: read(value_ptr))
        ast.Stmt.stmt_break as _x:
            return count
        ast.Stmt.stmt_continue as _x:
            return count
        ast.Stmt.stmt_pass as _x:
            return count
        ast.Stmt.stmt_defer as x:
            let expr_ptr = x.expression
            if expr_ptr != null:
                count += count_expr(unsafe: read(expr_ptr))
            let body_ptr = x.body
            if body_ptr != null:
                count += count_block(unsafe: read(body_ptr))
        ast.Stmt.stmt_unsafe as x:
            let body_ptr = x.body
            if body_ptr != null:
                count += count_block(unsafe: read(body_ptr))
        ast.Stmt.stmt_expression as x:
            count += count_expr(unsafe: read(x.expression))
        ast.Stmt.stmt_static_assert as x:
            count += count_expr(unsafe: read(x.condition))
            let message_ptr = x.message
            if message_ptr != null:
                count += count_expr(unsafe: read(message_ptr))
        ast.Stmt.stmt_emit as x:
            let decl_ptr = x.declaration
            if decl_ptr != null:
                count += count_decl(unsafe: read(decl_ptr))
        ast.Stmt.stmt_when as x:
            count += count_expr(unsafe: read(x.discriminant))
            var i: ptr_uint = 0
            while i < x.branches.len:
                let br = unsafe: read(x.branches.data + i)
                count += 1
                count += count_expr(unsafe: read(br.pattern))
                var j: ptr_uint = 0
                while j < br.body.len:
                    count += count_stmt(unsafe: read(br.body.data + j))
                    j += 1
                i += 1
            let else_ptr = x.else_body
            if else_ptr != null:
                count += count_block(unsafe: read(else_ptr))
        ast.Stmt.stmt_parallel_block as _x:
            # The host's `bodies` is an array of arrays; nested arrays are not
            # traversed.
            return count
        ast.Stmt.stmt_gather as x:
            var i: ptr_uint = 0
            while i < x.handles.len:
                count += count_expr(unsafe: read(x.handles.data + i))
                i += 1
        ast.Stmt.stmt_error as _x:
            return count
        ast.Stmt.stmt_error_block as x:
            count += count_block(unsafe: read(x.body))
    return count


function count_match_arm(arm: ast.MatchArm) -> ptr_uint:
    var count: ptr_uint = 1
    let pattern_ptr = arm.pattern
    if pattern_ptr != null:
        count += count_expr(unsafe: read(pattern_ptr))
    else if arm.wildcard_line > 0:
        # The host represents `_` as an Identifier pattern.
        count += 1
    let body_ptr = arm.body
    if body_ptr != null:
        count += count_block(unsafe: read(body_ptr))
    return count


function count_when_decl_branch(br: ast.WhenDeclBranch) -> ptr_uint:
    var count: ptr_uint = 1
    count += count_expr(unsafe: read(br.pattern))
    var i: ptr_uint = 0
    while i < br.body.len:
        count += count_decl(unsafe: read(br.body.data + i))
        i += 1
    return count


function count_decl(d: ast.Decl) -> ptr_uint:
    var count: ptr_uint = 1
    match d:
        ast.Decl.decl_import as x:
            count += count_qname(x.path)
        ast.Decl.decl_const as x:
            count += count_type_ref(unsafe: read(x.const_type))
            let value_ptr = x.value
            if value_ptr != null:
                count += count_expr(unsafe: read(value_ptr))
            let block_ptr = x.block_body
            if block_ptr != null:
                count += count_block(unsafe: read(block_ptr))
            count += count_attrs(x.attributes)
        ast.Decl.decl_var as x:
            let type_ptr = x.var_type
            if type_ptr != null:
                count += count_type_ref(unsafe: read(type_ptr))
            let value_ptr = x.value
            if value_ptr != null:
                count += count_expr(unsafe: read(value_ptr))
        ast.Decl.decl_function as x:
            count += count_type_params(x.type_params)
            count += count_params(x.method_params)
            let ret_ptr = x.return_type
            if ret_ptr != null:
                count += count_type_ref(unsafe: read(ret_ptr))
            let body_ptr = x.body
            if body_ptr != null:
                count += count_block(unsafe: read(body_ptr))
            count += count_attrs(x.attributes)
        ast.Decl.decl_struct as x:
            count += count_type_params(x.type_params)
            var i: ptr_uint = 0
            while i < x.impl_list.len:
                count += count_qname(unsafe: read(x.impl_list.data + i))
                i += 1
            i = 0
            while i < x.struct_fields.len:
                count += count_field(unsafe: read(x.struct_fields.data + i))
                i += 1
            i = 0
            while i < x.struct_events.len:
                count += count_decl(unsafe: read(x.struct_events.data + i))
                i += 1
            i = 0
            while i < x.nested_types.len:
                count += count_decl(unsafe: read(x.nested_types.data + i))
                i += 1
            count += count_attrs(x.struct_attrs)
        ast.Decl.decl_union as x:
            var i: ptr_uint = 0
            while i < x.union_fields.len:
                count += count_field(unsafe: read(x.union_fields.data + i))
                i += 1
            count += count_attrs(x.union_attrs)
        ast.Decl.decl_enum as x:
            let backing_ptr = x.backing_type
            if backing_ptr != null:
                count += count_type_ref(unsafe: read(backing_ptr))
            var i: ptr_uint = 0
            while i < x.enum_members.len:
                count += count_enum_member(unsafe: read(x.enum_members.data + i))
                i += 1
            count += count_attrs(x.enum_attrs)
        ast.Decl.decl_flags as x:
            let backing_ptr2 = x.backing_type
            if backing_ptr2 != null:
                count += count_type_ref(unsafe: read(backing_ptr2))
            var i: ptr_uint = 0
            while i < x.flags_members.len:
                count += count_enum_member(unsafe: read(x.flags_members.data + i))
                i += 1
            count += count_attrs(x.flags_attrs)
        ast.Decl.decl_variant as x:
            count += count_type_params(x.type_params)
            var i: ptr_uint = 0
            while i < x.variant_arms.len:
                count += count_variant_arm(unsafe: read(x.variant_arms.data + i))
                i += 1
            count += count_attrs(x.variant_attrs)
        ast.Decl.decl_opaque as x:
            var i: ptr_uint = 0
            while i < x.opaque_implements.len:
                count += count_qname(unsafe: read(x.opaque_implements.data + i))
                i += 1
        ast.Decl.decl_type_alias as x:
            count += count_type_ref(unsafe: read(x.target))
        ast.Decl.decl_interface as x:
            count += count_type_params(x.type_params)
            var i: ptr_uint = 0
            while i < x.interface_methods.len:
                count += count_interface_method(unsafe: read(x.interface_methods.data + i))
                i += 1
        ast.Decl.decl_extending_block as x:
            count += count_type_ref(unsafe: read(x.type_name))
            var i: ptr_uint = 0
            while i < x.methods.len:
                count += count_method(unsafe: read(x.methods.data + i))
                i += 1
        ast.Decl.decl_extern_function as x:
            count += count_type_params(x.type_params)
            var i: ptr_uint = 0
            while i < x.extern_params.len:
                count += count_foreign_param(unsafe: read(x.extern_params.data + i))
                i += 1
            let ret_ptr = x.return_type
            if ret_ptr != null:
                count += count_type_ref(unsafe: read(ret_ptr))
            count += count_attrs(x.attrs)
            let mapping_ptr = x.mapping
            if mapping_ptr != null:
                count += count_expr(unsafe: read(mapping_ptr))
        ast.Decl.decl_foreign_function as x:
            count += count_type_params(x.type_params)
            var i: ptr_uint = 0
            while i < x.foreign_params.len:
                count += count_foreign_param(unsafe: read(x.foreign_params.data + i))
                i += 1
            count += count_type_ref(unsafe: read(x.return_type))
            count += count_expr(unsafe: read(x.mapping))
            count += count_attrs(x.attrs)
        ast.Decl.decl_event as x:
            let payload_ptr = x.payload_type
            if payload_ptr != null:
                count += count_type_ref(unsafe: read(payload_ptr))
            count += count_attrs(x.attrs)
        ast.Decl.decl_static_assert as x:
            count += count_expr(unsafe: read(x.condition))
            let message_ptr = x.message
            if message_ptr != null:
                count += count_expr(unsafe: read(message_ptr))
        ast.Decl.decl_when as x:
            count += count_expr(unsafe: read(x.discriminant))
            var i: ptr_uint = 0
            while i < x.branches.len:
                count += count_when_decl_branch(unsafe: read(x.branches.data + i))
                i += 1
            i = 0
            while i < x.else_body.len:
                count += count_decl(unsafe: read(x.else_body.data + i))
                i += 1
        ast.Decl.decl_attribute as x:
            var i: ptr_uint = 0
            while i < x.attr_params.len:
                count += count_param(unsafe: read(x.attr_params.data + i))
                i += 1
        ast.Decl.decl_link as _x:
            return count
        ast.Decl.decl_include as _x:
            return count
        ast.Decl.decl_compiler_flag as _x:
            return count
    return count


function count_match_expr_arm(arm: ast.MatchExprArm) -> ptr_uint:
    var count: ptr_uint = 1
    let pattern_ptr = arm.pattern
    if pattern_ptr != null:
        count += count_expr(unsafe: read(pattern_ptr))
    else if arm.wildcard_line > 0:
        count += 1
    count += count_expr(unsafe: read(arm.value))
    return count


function count_expr(e: ast.Expr) -> ptr_uint:
    var count: ptr_uint = 1
    match e:
        ast.Expr.expr_identifier as _x:
            return count
        ast.Expr.expr_integer_literal as _x:
            return count
        ast.Expr.expr_float_literal as _x:
            return count
        ast.Expr.expr_string_literal as _x:
            return count
        ast.Expr.expr_char_literal as _x:
            return count
        ast.Expr.expr_bool_literal as _x:
            return count
        ast.Expr.expr_null_literal as x:
            let type_ptr = x.target_type
            if type_ptr != null:
                count += count_type_ref(unsafe: read(type_ptr))
        ast.Expr.expr_format_string as x:
            var i: ptr_uint = 0
            while i < x.parts.len:
                count += 1
                let part = unsafe: read(x.parts.data + i)
                match part:
                    ast.FormatStringPart.fmt_text as _t:
                        count += 0
                    ast.FormatStringPart.fmt_expr as t:
                        count += count_expr(unsafe: read(t.expression))
                i += 1
        ast.Expr.expr_binary_op as x:
            count += count_expr(unsafe: read(x.left))
            count += count_expr(unsafe: read(x.right))
        ast.Expr.expr_unary_op as x:
            count += count_expr(unsafe: read(x.operand))
        ast.Expr.expr_member_access as x:
            count += count_expr(unsafe: read(x.receiver))
        ast.Expr.expr_call as x:
            count += count_expr(unsafe: read(x.callee))
            var i: ptr_uint = 0
            while i < x.args.len:
                count += count_argument(unsafe: read(x.args.data + i))
                i += 1
        ast.Expr.expr_index_access as x:
            count += count_expr(unsafe: read(x.receiver))
            count += count_expr(unsafe: read(x.index))
        ast.Expr.expr_specialization as x:
            count += count_expr(unsafe: read(x.callee))
            var i: ptr_uint = 0
            while i < x.arguments.len:
                let argument = unsafe: read(unsafe: read(x.arguments.data + i).value)
                count += 1
                if is_value_type_argument(argument):
                    count += 1
                else:
                    count += count_type_ref(argument)
                i += 1
        ast.Expr.expr_if as x:
            count += count_expr(unsafe: read(x.condition))
            count += count_expr(unsafe: read(x.then_expr))
            count += count_expr(unsafe: read(x.else_expr))
        ast.Expr.expr_match as x:
            count += count_expr(unsafe: read(x.scrutinee))
            var i: ptr_uint = 0
            while i < x.arms.len:
                count += count_match_expr_arm(unsafe: read(x.arms.data + i))
                i += 1
        ast.Expr.expr_proc as x:
            count += count_params(x.method_params)
            let ret_ptr = x.return_type
            if ret_ptr != null:
                count += count_type_ref(unsafe: read(ret_ptr))
            count += count_block(unsafe: read(x.body))
        ast.Expr.expr_await as x:
            count += count_expr(unsafe: read(x.expression))
        ast.Expr.expr_detach as x:
            # The host's body is `[ExpressionStmt(expression)]`.
            count += 1 + count_expr(unsafe: read(x.expression))
        ast.Expr.expr_expression_list as x:
            var i: ptr_uint = 0
            while i < x.elements.len:
                count += count_expr(unsafe: read(x.elements.data + i))
                i += 1
        ast.Expr.expr_named as x:
            count += count_expr(unsafe: read(x.value))
        ast.Expr.expr_range as x:
            count += count_expr(unsafe: read(x.start_expr))
            count += count_expr(unsafe: read(x.end_expr))
        ast.Expr.expr_prefix_cast as x:
            count += count_type_ref(unsafe: read(x.target_type))
            count += count_expr(unsafe: read(x.expression))
        ast.Expr.expr_unsafe as x:
            count += count_expr(unsafe: read(x.expression))
        ast.Expr.expr_sizeof as x:
            count += count_type_ref(unsafe: read(x.target_type))
        ast.Expr.expr_alignof as x:
            count += count_type_ref(unsafe: read(x.target_type))
        ast.Expr.expr_offsetof as x:
            count += count_type_ref(unsafe: read(x.target_type))
        ast.Expr.expr_error as _x:
            return count
    return count
