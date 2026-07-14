## In-language linter for the self-hosted mtc compiler.
##
## Walks a parsed AST and reports style/correctness warnings, mirroring the Ruby
## linter's AST-only rules.  This first increment covers the rules that need no
## semantic-analysis facts:
##
##   - self-assignment       (warning)  `x = x`
##   - self-comparison       (warning)  `x == x` / `x != x`
##   - redundant-bool-compare (hint)    `x == true` and friends
##   - redundant-return      (hint)     final bare `return` in a `-> void` body
##
## The `lint` command renders each warning as `path:line: code: message`, so a
## warning only needs a line, code, message, and severity.

import std.vec as vec
import std.string as string
import std.str

import mtc.parser.ast as ast


public struct Warning:
    path: str
    line: ptr_uint
    code: str
    message: str
    severity: str


## Lint a parsed source file, returning warnings in source (traversal) order.
public function lint_source(file: ast.SourceFile, path: str) -> vec.Vec[Warning]:
    var warnings = vec.Vec[Warning].create()
    var i: ptr_uint = 0
    while i < file.declarations.len:
        unsafe:
            visit_decl(file.declarations.data + i, path, ref_of(warnings))
        i += 1
    return warnings


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
#  Traversal
# =============================================================================

function visit_decl(decl: ptr[ast.Decl], path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    unsafe:
        match read(decl):
            ast.Decl.decl_function as fun:
                visit_stmt_opt(fun.body, path, warnings)
                check_redundant_return(fun.return_type, fun.body, path, warnings)
            ast.Decl.decl_extending_block as ex:
                var j: ptr_uint = 0
                while j < ex.methods.len:
                    let m = read(ex.methods.data + j)
                    visit_stmt(m.body, path, warnings)
                    check_redundant_return(m.return_type, m.body, path, warnings)
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
                check_self_assignment(asgn.target, asgn.operator, asgn.value, path, warnings)
                visit_expr(asgn.target, path, warnings)
                visit_expr(asgn.value, path, warnings)
            ast.Stmt.stmt_if as iff:
                var bi: ptr_uint = 0
                while bi < iff.branches.len:
                    let br = read(iff.branches.data + bi)
                    visit_expr(br.condition, path, warnings)
                    visit_stmt(br.body, path, warnings)
                    bi += 1
                visit_stmt_opt(iff.else_body, path, warnings)
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
                    visit_stmt_opt(arm.body, path, warnings)
                    ai += 1
            ast.Stmt.stmt_ret as r:
                visit_expr_opt(r.value, path, warnings)
            ast.Stmt.stmt_defer as df:
                visit_expr_opt(df.expression, path, warnings)
                visit_stmt_opt(df.body, path, warnings)
            ast.Stmt.stmt_unsafe as un:
                visit_stmt_opt(un.body, path, warnings)
            ast.Stmt.stmt_expression as ex:
                visit_expr(ex.expression, path, warnings)
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
                check_self_comparison(b.operator, b.left, b.right, path, warnings)
                check_redundant_bool_compare(b.operator, b.left, b.right, path, warnings)
                visit_expr(b.left, path, warnings)
                visit_expr(b.right, path, warnings)
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
