## redundant-cast — sema-backed cast checks, mirroring the host
## (`lib/milk_tea/tooling/linter/visitors.rb:1079-1364` and the boundary call
## sites):
##
##   * cast to same type / `own` -> ptr coercion      (any `Target<-expr`)
##   * redundant parentheses around a cast expression (source-line based)
##   * implicit widening at a coercion slot           (typed let/var, `return`,
##     plain `=` assignment — the host's `flag_redundant_widening_cast`)
##   * integer-literal coercion at a slot             (`flag_redundant_literal_cast`)
##   * implicit float widening inside a binary op     (`check_redundant_binary_operand_cast`)
##   * integer-literal coercion inside a comparison   (`check_redundant_literal_operand_cast`)
##
## With no analysis (or an unresolved operand) only the literal-name fallback
## and the parentheses check run, exactly like the host.

import std.str
import std.string as string
import std.vec as vec

import mtc.parser.ast as ast
import mtc.semantic.analyzer as analyzer
import mtc.semantic.types as types


public struct Diag:
    line: ptr_uint
    column: ptr_uint
    message: str


# =============================================================================
#  Primitive classification (the host's `Types::Primitive` flag methods)
# =============================================================================

## The names in the host's `INTEGER_TYPE_RANGES`.
function integer_type_name(name: str) -> bool:
    return (
        name == "byte" or name == "short" or name == "int" or name == "long"
        or name == "ubyte" or name == "ushort" or name == "uint" or name == "ulong"
        or name == "char"
    )


function literal_fits(target_name: str, value: long) -> bool:
    if target_name == "byte":
        return value >= -128 and value <= 127
    if target_name == "short":
        return value >= -32768 and value <= 32767
    if target_name == "int":
        return value >= -2147483648 and value <= 2147483647
    if target_name == "long":
        return true
    if target_name == "ubyte" or target_name == "char":
        return value >= 0 and value <= 255
    if target_name == "ushort":
        return value >= 0 and value <= 65535
    if target_name == "uint":
        return value >= 0 and value <= 4294967295
    if target_name == "ulong":
        return value >= 0
    return false


## Fixed-width integers only (the host's `fixed_width_integer?`): the
## pointer-sized `ptr_int`/`ptr_uint` are not implicit-cast candidates.
function fixed_width_integer(name: str) -> bool:
    return (
        name == "byte" or name == "short" or name == "int" or name == "long"
        or name == "ubyte" or name == "ushort" or name == "uint" or name == "ulong"
    )


function float_name(name: str) -> bool:
    return name == "float" or name == "double"


function signed_integer(name: str) -> bool:
    return name == "byte" or name == "short" or name == "int" or name == "long"


function integer_width(name: str) -> ptr_uint:
    if name == "byte" or name == "ubyte":
        return 1
    if name == "short" or name == "ushort":
        return 2
    if name == "int" or name == "uint":
        return 4
    if name == "long" or name == "ulong":
        return 8
    return 0


## Host `implicit_cast_allowed?`: can `inner` coerce to `target` implicitly?
function implicit_cast_allowed(inner_name: str, target_name: str) -> bool:
    if inner_name.equal(target_name):
        return true
    if not fixed_width_integer(inner_name):
        return false
    if float_name(target_name):
        return true
    if not fixed_width_integer(target_name):
        return false
    if signed_integer(inner_name) == signed_integer(target_name):
        return integer_width(target_name) >= integer_width(inner_name)
    if signed_integer(inner_name):
        return false
    return signed_integer(target_name) and integer_width(target_name) > integer_width(inner_name)


function arithmetic_or_comparison_op(op: str) -> bool:
    return (
        op.equal("+") or op.equal("-") or op.equal("*") or op.equal("/") or op.equal("%")
        or op.equal("==") or op.equal("!=") or op.equal("<") or op.equal("<=")
        or op.equal(">") or op.equal(">=")
    )


function comparison_op(op: str) -> bool:
    return (
        op.equal("==") or op.equal("!=") or op.equal("<") or op.equal("<=")
        or op.equal(">") or op.equal(">=")
    )


# =============================================================================
#  Analysis lookups
# =============================================================================

function resolve_expr_type(ctx: ref[Ctx], ep: ptr[ast.Expr]) -> ptr[types.Type]?:
    let analysis = ctx.analysis else:
        return null
    let key = unsafe: reinterpret[ptr_uint](ep)
    return unsafe: read(analysis).resolved_expr_types.get(key)


## The resolved primitive name of an expression, or "" when it is not a
## primitive (mirrors the host's `resolve_expr_type` + `Primitive` checks).
function primitive_name_of(ctx: ref[Ctx], ep: ptr[ast.Expr]) -> str:
    let tp = resolve_expr_type(ctx, ep) else:
        return ""
    match unsafe: read(tp):
        types.Type.ty_primitive as p:
            return p.name
        _:
            return ""


function type_name_of(t: types.Type) -> str:
    match t:
        types.Type.ty_primitive as p:
            return p.name
        types.Type.ty_str:
            return "str"
        types.Type.ty_generic as g:
            return g.name
        types.Type.ty_imported as im:
            return im.name
        types.Type.ty_named as n:
            return n.name
        types.Type.ty_opaque as o:
            return o.name
        _:
            return ""


## Host `same_resolved_type?` (`left.equal?(right) || left.to_s == right.to_s`)
## as a structural comparison over the self-host's type model.
function same_type(left: types.Type, right: types.Type) -> bool:
    match left:
        types.Type.ty_primitive as lp:
            match right:
                types.Type.ty_primitive as rp:
                    return lp.name.equal(rp.name)
                _:
                    return false
        types.Type.ty_str:
            match right:
                types.Type.ty_str:
                    return true
                _:
                    return false
        types.Type.ty_nullable as ln:
            match right:
                types.Type.ty_nullable as rn:
                    return same_type(unsafe: read(ln.base), unsafe: read(rn.base))
                _:
                    return false
        types.Type.ty_generic as lg:
            match right:
                types.Type.ty_generic as rg:
                    if not lg.name.equal(rg.name):
                        return false
                    return same_type_span(lg.args, rg.args)
                _:
                    return false
        types.Type.ty_imported as li:
            match right:
                types.Type.ty_imported as ri:
                    if not li.name.equal(ri.name) or not li.module_name.equal(ri.module_name):
                        return false
                    return same_type_span(li.args, ri.args)
                _:
                    return false
        types.Type.ty_named as lna:
            match right:
                types.Type.ty_named as rna:
                    return lna.name.equal(rna.name)
                _:
                    return false
        types.Type.ty_opaque as lo:
            match right:
                types.Type.ty_opaque as ro:
                    return lo.name.equal(ro.name)
                _:
                    return false
        types.Type.ty_dyn as ld:
            match right:
                types.Type.ty_dyn as rd:
                    return ld.iface.equal(rd.iface)
                _:
                    return false
        _:
            return false


function same_type_span(left: span[types.Type], right: span[types.Type]) -> bool:
    if left.len != right.len:
        return false
    var i: ptr_uint = 0
    while i < left.len:
        unsafe:
            if not same_type(read(left.data + i), read(right.data + i)):
                return false
        i += 1
    return true


## Host `own_to_pointer_cast_redundant?`: `ptr[T]<-own[T]` adds nothing.
function own_to_pointer_redundant(inner: types.Type, cast: types.Type) -> bool:
    match inner:
        types.Type.ty_generic as ig:
            if not ig.name.equal("own") or ig.args.len != 1:
                return false
            match cast:
                types.Type.ty_generic as cg:
                    if not cg.name.equal("ptr") and not cg.name.equal("const_ptr"):
                        return false
                    if cg.args.len != 1:
                        return false
                    return same_type(unsafe: read(ig.args.data), unsafe: read(cg.args.data))
                _:
                    return false
        _:
            return false


# =============================================================================
#  Traversal
# =============================================================================

struct Ctx:
    diags: vec.Vec[Diag]
    lines: vec.Vec[str]
    analysis: ptr[analyzer.Analysis]?


public function check(file: ast.SourceFile, source: str, analysis: ptr[analyzer.Analysis]?) -> vec.Vec[Diag]:
    var ctx = Ctx(diags = vec.Vec[Diag].create(), lines = split_lines(source), analysis = analysis)
    var i: ptr_uint = 0
    while i < file.declarations.len:
        unsafe:
            walk_decl(ref_of(ctx), read(file.declarations.data + i))
        i += 1
    ctx.lines.release()
    return ctx.diags


function split_lines(source: str) -> vec.Vec[str]:
    var lines = vec.Vec[str].create()
    var start: ptr_uint = 0
    var i: ptr_uint = 0
    while i <= source.len:
        if i == source.len or source.byte_at(i) == 10:
            lines.push(source.slice(start, i - start))
            start = i + 1
        i += 1
    return lines


function emit_diag(ctx: ref[Ctx], line: ptr_uint, column: ptr_uint, reason: str, target_name: str) -> void:
    var message = string.String.create()
    message.append(reason)
    message.append(": ")
    message.append(target_name)
    message.append("<-")
    ctx.diags.push(Diag(line = line, column = column, message = message.as_str()))


function walk_decl(ctx: ref[Ctx], d: ast.Decl) -> void:
    match d:
        ast.Decl.decl_const as c:
            walk_expr_opt(ctx, c.value)
            let blk = c.block_body
            if blk != null:
                unsafe:
                    walk_stmt(ctx, read(blk))
        ast.Decl.decl_var as v:
            walk_expr_opt(ctx, v.value)
        ast.Decl.decl_function as f:
            let fb = f.body
            if fb != null:
                unsafe:
                    walk_stmt(ctx, read(fb))
        ast.Decl.decl_extending_block as ex:
            var j: ptr_uint = 0
            while j < ex.methods.len:
                var mb: ptr[ast.Stmt]
                unsafe:
                    mb = read(ex.methods.data + j).body
                    walk_stmt(ctx, read(mb))
                j += 1
        ast.Decl.decl_when as wh:
            walk_expr(ctx, wh.discriminant)
            var j: ptr_uint = 0
            while j < wh.branches.len:
                let branch = unsafe: read(wh.branches.data + j)
                walk_expr(ctx, branch.pattern)
                walk_decl_span(ctx, branch.body)
                j += 1
            walk_decl_span(ctx, wh.else_body)
        ast.Decl.decl_static_assert as sa:
            walk_expr(ctx, sa.condition)
            walk_expr_opt(ctx, sa.message)
        _:
            pass


function walk_decl_span(ctx: ref[Ctx], decls: span[ast.Decl]) -> void:
    var i: ptr_uint = 0
    while i < decls.len:
        unsafe:
            walk_decl(ctx, read(decls.data + i))
        i += 1


function walk_stmt(ctx: ref[Ctx], st: ast.Stmt) -> void:
    match st:
        ast.Stmt.stmt_block as b:
            walk_stmt_span(ctx, b.statements)
        ast.Stmt.stmt_local as l:
            if l.stmt_type != null:
                flag_widening(ctx, l.value)
                flag_literal(ctx, l.value)
            walk_expr_opt(ctx, l.value)
            let eb = l.else_body
            if eb != null:
                unsafe:
                    walk_stmt(ctx, read(eb))
        ast.Stmt.stmt_assignment as a:
            if a.operator.equal("="):
                flag_widening(ctx, a.value)
                flag_literal(ctx, a.value)
            walk_expr(ctx, a.target)
            walk_expr(ctx, a.value)
        ast.Stmt.stmt_if as i:
            var bi: ptr_uint = 0
            while bi < i.branches.len:
                let branch = unsafe: read(i.branches.data + bi)
                walk_expr(ctx, branch.condition)
                unsafe:
                    walk_stmt(ctx, read(branch.body))
                bi += 1
            let ieb = i.else_body
            if ieb != null:
                unsafe:
                    walk_stmt(ctx, read(ieb))
        ast.Stmt.stmt_while as w:
            walk_expr(ctx, w.condition)
            let wb = w.body
            if wb != null:
                unsafe:
                    walk_stmt(ctx, read(wb))
        ast.Stmt.stmt_for as fr:
            var fi: ptr_uint = 0
            while fi < fr.iterables.len:
                unsafe:
                    walk_expr(ctx, fr.iterables.data + fi)
                fi += 1
            let fbody = fr.body
            if fbody != null:
                unsafe:
                    walk_stmt(ctx, read(fbody))
        ast.Stmt.stmt_match as m:
            walk_expr(ctx, m.scrutinee)
            var mi: ptr_uint = 0
            while mi < m.arms.len:
                let arm = unsafe: read(m.arms.data + mi)
                walk_expr_opt(ctx, arm.pattern)
                let ab = arm.body
                if ab != null:
                    unsafe:
                        walk_stmt(ctx, read(ab))
                mi += 1
        ast.Stmt.stmt_ret as r:
            flag_widening(ctx, r.value)
            flag_literal(ctx, r.value)
            walk_expr_opt(ctx, r.value)
        ast.Stmt.stmt_defer as d:
            walk_expr_opt(ctx, d.expression)
            let db = d.body
            if db != null:
                unsafe:
                    walk_stmt(ctx, read(db))
        ast.Stmt.stmt_unsafe as u:
            let ub = u.body
            if ub != null:
                unsafe:
                    walk_stmt(ctx, read(ub))
        ast.Stmt.stmt_expression as e:
            walk_expr(ctx, e.expression)
        ast.Stmt.stmt_static_assert as sa:
            walk_expr(ctx, sa.condition)
            walk_expr_opt(ctx, sa.message)
        ast.Stmt.stmt_emit as em:
            let decl = em.declaration
            if decl != null:
                unsafe:
                    walk_decl(ctx, read(decl))
        ast.Stmt.stmt_when as wn:
            walk_expr(ctx, wn.discriminant)
            var wi: ptr_uint = 0
            while wi < wn.branches.len:
                let br = unsafe: read(wn.branches.data + wi)
                walk_expr(ctx, br.pattern)
                walk_stmt_span(ctx, br.body)
                wi += 1
            let web = wn.else_body
            if web != null:
                unsafe:
                    walk_stmt(ctx, read(web))
        ast.Stmt.stmt_parallel_block as pb:
            walk_stmt_span(ctx, pb.bodies)
        ast.Stmt.stmt_gather as g:
            var gi: ptr_uint = 0
            while gi < g.handles.len:
                unsafe:
                    walk_expr(ctx, g.handles.data + gi)
                gi += 1
        ast.Stmt.stmt_error_block as eb:
            unsafe:
                walk_stmt(ctx, read(eb.body))
        _:
            pass


function walk_stmt_span(ctx: ref[Ctx], stmts: span[ast.Stmt]) -> void:
    var i: ptr_uint = 0
    while i < stmts.len:
        unsafe:
            walk_stmt(ctx, read(stmts.data + i))
        i += 1


function walk_expr(ctx: ref[Ctx], ep: ptr[ast.Expr]) -> void:
    unsafe:
        match read(ep):
            ast.Expr.expr_prefix_cast as c:
                walk_expr(ctx, c.expression)
                check_cast(ctx, ep, c.target_type, c.expression, c.line, c.column)
                check_parens(ctx, c.line, c.column, type_last_name(c.target_type))
            ast.Expr.expr_binary_op as b:
                walk_expr(ctx, b.left)
                walk_expr(ctx, b.right)
                check_binary_operand(ctx, b.operator, b.left, b.right)
                check_binary_operand(ctx, b.operator, b.right, b.left)
                check_literal_operand(ctx, b.operator, b.left, b.right)
                check_literal_operand(ctx, b.operator, b.right, b.left)
            ast.Expr.expr_unary_op as u:
                walk_expr(ctx, u.operand)
            ast.Expr.expr_member_access as m:
                walk_expr(ctx, m.receiver)
            ast.Expr.expr_index_access as ix:
                walk_expr(ctx, ix.receiver)
                walk_expr(ctx, ix.index)
            ast.Expr.expr_specialization as s:
                walk_expr(ctx, s.callee)
            ast.Expr.expr_call as call:
                walk_expr(ctx, call.callee)
                var ai: ptr_uint = 0
                while ai < call.args.len:
                    walk_expr(ctx, read(call.args.data + ai).arg_value)
                    ai += 1
            ast.Expr.expr_if as ie:
                walk_expr(ctx, ie.condition)
                walk_expr(ctx, ie.then_expr)
                walk_expr(ctx, ie.else_expr)
            ast.Expr.expr_match as me:
                walk_expr(ctx, me.scrutinee)
                var mi: ptr_uint = 0
                while mi < me.arms.len:
                    let arm = read(me.arms.data + mi)
                    walk_expr_opt(ctx, arm.pattern)
                    walk_expr(ctx, arm.value)
                    mi += 1
            ast.Expr.expr_unsafe as ue:
                walk_expr(ctx, ue.expression)
            ast.Expr.expr_proc as pr:
                walk_stmt(ctx, read(pr.body))
            ast.Expr.expr_await as aw:
                walk_expr(ctx, aw.expression)
            ast.Expr.expr_detach as dt:
                walk_expr(ctx, dt.expression)
            ast.Expr.expr_expression_list as el:
                var ei: ptr_uint = 0
                while ei < el.elements.len:
                    walk_expr(ctx, el.elements.data + ei)
                    ei += 1
            ast.Expr.expr_named as nm:
                walk_expr(ctx, nm.value)
            ast.Expr.expr_range as rg:
                walk_expr(ctx, rg.start_expr)
                walk_expr(ctx, rg.end_expr)
            ast.Expr.expr_format_string as fs:
                var pi: ptr_uint = 0
                while pi < fs.parts.len:
                    match read(fs.parts.data + pi):
                        ast.FormatStringPart.fmt_expr as fe:
                            walk_expr(ctx, fe.expression)
                        _:
                            pass
                    pi += 1
            _:
                pass


function walk_expr_opt(ctx: ref[Ctx], ep: ptr[ast.Expr]?) -> void:
    let p = ep else:
        return
    walk_expr(ctx, p)


# =============================================================================
#  Checks
# =============================================================================

function check_cast(ctx: ref[Ctx], cast_ptr: ptr[ast.Expr], target_type: ptr[ast.TypeRef], inner: ptr[ast.Expr], line: ptr_uint, column: ptr_uint) -> void:
    let target_name = type_last_name(target_type)
    if target_name.len == 0:
        return

    if ctx.analysis != null:
        let cast_ty = resolve_expr_type(ctx, cast_ptr)
        let inner_ty = resolve_expr_type(ctx, inner)
        if cast_ty != null and inner_ty != null:
            if same_type(unsafe: read(cast_ty), unsafe: read(inner_ty)):
                emit_diag(ctx, line, column, "cast to same type is redundant", target_name)
            else if own_to_pointer_redundant(unsafe: read(inner_ty), unsafe: read(cast_ty)):
                emit_diag(ctx, line, column, "implicit own->ptr coercion makes this cast redundant", target_name)
            return

    # Fallback when the inner type cannot be resolved: a value literal whose
    # type is known by name.
    let literal_name = expression_literal_type_name(inner)
    if literal_name.len > 0 and literal_name.equal(target_name):
        emit_diag(ctx, line, column, "cast to same type is redundant", target_name)


function expression_literal_type_name(ep: ptr[ast.Expr]) -> str:
    unsafe:
        match read(ep):
            ast.Expr.expr_integer_literal:
                return "int"
            ast.Expr.expr_string_literal as s:
                if s.is_cstring:
                    return "cstr"
                return "str"
            ast.Expr.expr_float_literal:
                return "float"
            ast.Expr.expr_bool_literal:
                return "bool"
            _:
                return ""


## `T<-(x)` when `T<-x` needs no precedence protection: the parens are
## redundant unless the inner text has a top-level operator (host
## `check_redundant_cast_parens`).
function check_parens(ctx: ref[Ctx], line: ptr_uint, column: ptr_uint, target_name: str) -> void:
    if line == 0:
        return
    let line_index = line - 1
    if line_index >= ctx.lines.len():
        return
    let text_ptr = ctx.lines.get(line_index) else:
        return
    let text = unsafe: read(text_ptr)
    var col: ptr_uint = 0
    if column > 0:
        col = column - 1
    let arrow = find_from(text, "<-", col) else:
        return
    let arrow_end = arrow + 2
    if arrow_end >= text.len or text.byte_at(arrow_end) != '(':
        return
    let close = match_paren(text, arrow_end) else:
        return
    let inner = text.slice(arrow_end + 1, close - (arrow_end + 1)).trim_ascii_whitespace()
    if inner.len == 0:
        return
    if inner_has_top_level_operators(inner):
        return
    emit_diag(ctx, line, column, "parentheses around cast expression are redundant", target_name)


## A widening cast directly at a coercion slot (typed local, `return`, plain
## `=`), where the slot type pins the result.
function flag_widening(ctx: ref[Ctx], ep: ptr[ast.Expr]?) -> void:
    if ctx.analysis == null:
        return
    let p = ep else:
        return
    unsafe:
        match read(p):
            ast.Expr.expr_prefix_cast as c:
                let target_name = type_last_name(c.target_type)
                if target_name.len == 0:
                    return
                let inner_name = primitive_name_of(ctx, c.expression)
                if inner_name.len == 0 or inner_name.equal(target_name):
                    return
                if implicit_cast_allowed(inner_name, target_name):
                    emit_diag(ctx, c.line, c.column, "implicit widening makes this cast redundant", target_name)
            _:
                pass


## An integer-literal cast at a coercion slot whose literal fits the target.
function flag_literal(ctx: ref[Ctx], ep: ptr[ast.Expr]?) -> void:
    if ctx.analysis == null:
        return
    let p = ep else:
        return
    unsafe:
        match read(p):
            ast.Expr.expr_prefix_cast as c:
                let target_name = type_last_name(c.target_type)
                if not integer_type_name(target_name):
                    return
                match read(c.expression):
                    ast.Expr.expr_integer_literal as lit:
                        if not literal_fits(target_name, lit.value):
                            return
                        let inner_name = primitive_name_of(ctx, c.expression)
                        if inner_name.len == 0 or inner_name.equal(target_name):
                            return
                        if implicit_cast_allowed(inner_name, target_name):
                            return
                        emit_diag(ctx, c.line, c.column, "integer literal coercion makes this cast redundant", target_name)
                    _:
                        pass
            _:
                pass


## `float_y + double<-i` style redundancy: an int->float cast as an operand of
## an arithmetic/comparison op whose sibling is already float.
function check_binary_operand(ctx: ref[Ctx], op: str, operand: ptr[ast.Expr], sibling: ptr[ast.Expr]) -> void:
    if ctx.analysis == null:
        return
    if not arithmetic_or_comparison_op(op):
        return
    if not is_prefix_cast(operand) or is_prefix_cast(sibling):
        return
    let target_name = primitive_name_of(ctx, operand)
    if target_name.len == 0 or not float_name(target_name):
        return
    let inner = cast_inner(operand) else:
        return
    let inner_name = primitive_name_of(ctx, inner)
    if not fixed_width_integer(inner_name):
        return
    let sibling_name = primitive_name_of(ctx, sibling)
    if not float_name(sibling_name):
        return
    if target_name.equal("double") and sibling_name.equal("float"):
        return
    let type_ref_name = cast_type_last_name(operand)
    if type_ref_name.len == 0:
        return
    emit_diag(ctx, cast_line(operand), cast_column(operand), "implicit float widening makes this cast redundant", type_ref_name)


## `State.idle == ubyte<-0`: a fitting integer literal cast as a comparison
## operand against an enum / float / wider integer sibling.
function check_literal_operand(ctx: ref[Ctx], op: str, operand: ptr[ast.Expr], sibling: ptr[ast.Expr]) -> void:
    if ctx.analysis == null:
        return
    if not comparison_op(op):
        return
    if not is_prefix_cast(operand):
        return
    let inner = cast_inner(operand) else:
        return
    let target_name = cast_type_last_name(operand)
    if not integer_type_name(target_name):
        return
    unsafe:
        match read(inner):
            ast.Expr.expr_integer_literal as lit:
                if not literal_fits(target_name, lit.value):
                    return
                let inner_name = primitive_name_of(ctx, inner)
                if inner_name.len > 0 and inner_name.equal(target_name):
                    return
                let sibling_ty = resolve_expr_type(ctx, sibling) else:
                    return
                match read(sibling_ty):
                    types.Type.ty_primitive as sp:
                        if float_name(sp.name):
                            pass
                        else if integer_type_name(sp.name):
                            if not literal_fits(sp.name, lit.value):
                                return
                        else:
                            return
                    types.Type.ty_named as n:
                        let analysis = ctx.analysis else:
                            return
                        var is_enum = unsafe: read(analysis).static_member_types.contains(n.name)
                        if not is_enum:
                            return
                    types.Type.ty_imported:
                        pass
                    _:
                        return
                emit_diag(ctx, cast_line(operand), cast_column(operand), "integer literal coercion makes this cast redundant", target_name)
            _:
                pass


# =============================================================================
#  Node helpers
# =============================================================================

function is_prefix_cast(ep: ptr[ast.Expr]) -> bool:
    unsafe:
        match read(ep):
            ast.Expr.expr_prefix_cast:
                return true
            _:
                return false


function cast_inner(ep: ptr[ast.Expr]) -> ptr[ast.Expr]?:
    unsafe:
        match read(ep):
            ast.Expr.expr_prefix_cast as c:
                return c.expression
            _:
                return null


function cast_type_last_name(ep: ptr[ast.Expr]) -> str:
    unsafe:
        match read(ep):
            ast.Expr.expr_prefix_cast as c:
                return type_last_name(c.target_type)
            _:
                return ""


function cast_line(ep: ptr[ast.Expr]) -> ptr_uint:
    unsafe:
        match read(ep):
            ast.Expr.expr_prefix_cast as c:
                return c.line
            _:
                return 0


function cast_column(ep: ptr[ast.Expr]) -> ptr_uint:
    unsafe:
        match read(ep):
            ast.Expr.expr_prefix_cast as c:
                return c.column
            _:
                return 0


function type_last_name(type_ref: ptr[ast.TypeRef]) -> str:
    unsafe:
        let tr = read(type_ref)
        if tr.name.parts.len == 0:
            return ""
        return read(tr.name.parts.data + tr.name.parts.len - 1)


function find_from(text: str, needle: str, from: ptr_uint) -> Option[ptr_uint]:
    if needle.len == 0 or text.len < needle.len:
        return Option[ptr_uint].none
    var i = from
    let last = text.len - needle.len
    while i <= last:
        var matched = true
        var j: ptr_uint = 0
        while j < needle.len:
            if text.byte_at(i + j) != needle.byte_at(j):
                matched = false
                break
            j += 1
        if matched:
            return Option[ptr_uint].some(value = i)
        i += 1
    return Option[ptr_uint].none


function match_paren(line: str, open_pos: ptr_uint) -> Option[ptr_uint]:
    var depth: int = 0
    var i = open_pos
    while i < line.len:
        let b = line.byte_at(i)
        if b == '(':
            depth += 1
        else if b == ')':
            depth -= 1
            if depth == 0:
                return Option[ptr_uint].some(value = i)
        i += 1
    return Option[ptr_uint].none


function is_binary_op_char(b: ubyte) -> bool:
    return (
        b == '+' or b == '-' or b == '*' or b == '/' or b == '%'
        or b == '&' or b == '|' or b == '^' or b == '<' or b == '>'
        or b == '=' or b == '!' or b == '?' or b == ':'
    )


function inner_has_top_level_operators(inner: str) -> bool:
    var depth: int = 0
    var i: ptr_uint = 0
    while i < inner.len:
        let b = inner.byte_at(i)
        if b == '(' or b == '[' or b == '{':
            depth += 1
        else if b == ')' or b == ']' or b == '}':
            if depth > 0:
                depth -= 1
        else if is_binary_op_char(b):
            if depth == 0:
                return true
        i += 1
    return false
