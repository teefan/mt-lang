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
##
## Rule checks are applied after visiting a node's children, matching the Ruby
## visitor's emission order.  The `lint` command renders each warning as
## `path:line: code: message`, so a warning only needs a line, code, message,
## and severity.

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
                check_duplicate_if_conditions(iff.branches, path, warnings)
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
