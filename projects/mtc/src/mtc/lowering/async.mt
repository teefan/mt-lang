## Async CPS — analysis module (await detection + state counting + frame struct).
##
## Imported by lowering/lowering.mt which does the actual IR generation
## (lower_expr / lower_stmt are defined there).

import std.vec as vec
import std.string as string

import mtc.parser.ast as ast
import mtc.semantic.types as types
import mtc.ir as ir
import mtc.c_naming as naming


# =============================================================================
#  Await detection
# =============================================================================

public function body_has_await(sp: ptr[ast.Stmt]?) -> bool:
    let b = sp else:
        return false
    return stmt_has_await(sp)


function stmt_has_await(sp: ptr[ast.Stmt]?) -> bool:
    let p = sp else:
        return false
    unsafe:
        match read(p):
            ast.Stmt.stmt_ret as r:
                let v = r.value
                return v != null and expr_has_await(v)
            ast.Stmt.stmt_assignment as a:
                return expr_has_await(a.value)
            ast.Stmt.stmt_local as d:
                let v = d.value
                return v != null and expr_has_await(v)
            ast.Stmt.stmt_if as iff:
                var bi: ptr_uint = 0
                while bi < iff.branches.len:
                    let br = unsafe: read(iff.branches.data + bi)
                    if expr_has_await(br.condition) or stmt_has_await(br.body):
                        return true
                    bi += 1
                return body_has_await(iff.else_body)
            ast.Stmt.stmt_while as w:
                return expr_has_await(w.condition) or body_has_await(w.body)
            ast.Stmt.stmt_match as m:
                if expr_has_await(m.scrutinee):
                    return true
                var ai: ptr_uint = 0
                while ai < m.arms.len:
                    if stmt_has_await(unsafe: read(m.arms.data + ai).body):
                        return true
                    ai += 1
                return false
            ast.Stmt.stmt_for as f:
                var bi: ptr_uint = 0
                while bi < f.iterables.len:
                    if expr_has_await(unsafe: f.iterables.data + bi):
                        return true
                    bi += 1
                return body_has_await(f.body)
            ast.Stmt.stmt_block as blk:
                var si: ptr_uint = 0
                while si < blk.statements.len:
                    if stmt_has_await(unsafe: blk.statements.data + si):
                        return true
                    si += 1
                return false
            ast.Stmt.stmt_unsafe as u:
                return body_has_await(u.body)
            ast.Stmt.stmt_defer as d:
                return body_has_await(d.body) or (d.expression != null and expr_has_await(d.expression))
            ast.Stmt.stmt_expression as e:
                return expr_has_await(e.expression)
            _:
                return false


function expr_has_await(ep: ptr[ast.Expr]?) -> bool:
    let p = ep else:
        return false
    unsafe:
        match read(p):
            ast.Expr.expr_await:
                return true
            ast.Expr.expr_call as c:
                if expr_has_await(c.callee):
                    return true
                var i: ptr_uint = 0
                while i < c.args.len:
                    if expr_has_await(unsafe: read(c.args.data + i).arg_value):
                        return true
                    i += 1
                return false
            ast.Expr.expr_binary_op as b:
                return expr_has_await(b.left) or expr_has_await(b.right)
            ast.Expr.expr_unary_op as u:
                return expr_has_await(u.operand)
            ast.Expr.expr_member_access as ma:
                return expr_has_await(ma.receiver)
            ast.Expr.expr_index_access as ix:
                return expr_has_await(ix.receiver) or expr_has_await(ix.index)
            ast.Expr.expr_prefix_cast as c:
                return expr_has_await(c.expression)
            ast.Expr.expr_if as c:
                return expr_has_await(c.condition) or expr_has_await(c.then_expr) or expr_has_await(c.else_expr)
            ast.Expr.expr_unsafe as u:
                return expr_has_await(u.expression)
            ast.Expr.expr_specialization as s:
                return expr_has_await(s.callee)
            _:
                return false


# =============================================================================
#  State counting
# =============================================================================

public function count_async_states(sp: ptr[ast.Stmt]?) -> int:
    var c: int = 0
    count_await_in_stmt(sp, ref_of(c))
    return c


function count_await_in_stmt(sp: ptr[ast.Stmt]?, count: ref[int]) -> void:
    let p = sp else:
        return
    unsafe:
        match read(p):
            ast.Stmt.stmt_ret as r:
                let v = r.value
                if v != null:
                    count_await_in_expr(v, count)
            ast.Stmt.stmt_assignment as a:
                count_await_in_expr(a.value, count)
            ast.Stmt.stmt_local as d:
                let v = d.value
                if v != null:
                    count_await_in_expr(v, count)
            ast.Stmt.stmt_if as iff:
                var bi: ptr_uint = 0
                while bi < iff.branches.len:
                    let br = unsafe: read(iff.branches.data + bi)
                    count_await_in_expr(br.condition, count)
                    count_await_in_stmt(br.body, count)
                    bi += 1
                let eb = iff.else_body
                if eb != null:
                    count_await_in_stmt(eb, count)
            ast.Stmt.stmt_while as w:
                count_await_in_expr(w.condition, count)
                let wb = w.body
                if wb != null:
                    count_await_in_stmt(wb, count)
            ast.Stmt.stmt_match as m:
                count_await_in_expr(m.scrutinee, count)
                var ai: ptr_uint = 0
                while ai < m.arms.len:
                    count_await_in_stmt(unsafe: read(m.arms.data + ai).body, count)
                    ai += 1
            ast.Stmt.stmt_for as f:
                var bi: ptr_uint = 0
                while bi < f.iterables.len:
                    count_await_in_expr(unsafe: f.iterables.data + bi, count)
                    bi += 1
                let fb = f.body
                if fb != null:
                    count_await_in_stmt(fb, count)
            ast.Stmt.stmt_block as blk:
                var si: ptr_uint = 0
                while si < blk.statements.len:
                    count_await_in_stmt(unsafe: blk.statements.data + si, count)
                    si += 1
            ast.Stmt.stmt_unsafe as u:
                let ub = u.body
                if ub != null:
                    count_await_in_stmt(ub, count)
            ast.Stmt.stmt_defer as d:
                let db = d.body
                if db != null:
                    count_await_in_stmt(db, count)
                if d.expression != null:
                    count_await_in_expr(d.expression, count)
            ast.Stmt.stmt_expression as e:
                count_await_in_expr(e.expression, count)
            _:
                pass


function count_await_in_expr(ep: ptr[ast.Expr]?, count: ref[int]) -> void:
    let p = ep else:
        return
    unsafe:
        match read(p):
            ast.Expr.expr_await:
                read(count) = read(count) + 1
            ast.Expr.expr_call as c:
                count_await_in_expr(c.callee, count)
                var i: ptr_uint = 0
                while i < c.args.len:
                    count_await_in_expr(unsafe: read(c.args.data + i).arg_value, count)
                    i += 1
            ast.Expr.expr_binary_op as b:
                count_await_in_expr(b.left, count)
                count_await_in_expr(b.right, count)
            ast.Expr.expr_unary_op as u:
                count_await_in_expr(u.operand, count)
            ast.Expr.expr_member_access as ma:
                count_await_in_expr(ma.receiver, count)
            ast.Expr.expr_index_access as ix:
                count_await_in_expr(ix.receiver, count)
                count_await_in_expr(ix.index, count)
            ast.Expr.expr_prefix_cast as c:
                count_await_in_expr(c.expression, count)
            ast.Expr.expr_if as c:
                count_await_in_expr(c.condition, count)
                count_await_in_expr(c.then_expr, count)
                count_await_in_expr(c.else_expr, count)
            ast.Expr.expr_unsafe as u:
                count_await_in_expr(u.expression, count)
            ast.Expr.expr_specialization as s:
                count_await_in_expr(s.callee, count)
            _:
                pass


# =============================================================================
#  Frame struct builder
# =============================================================================

public function build_async_frame(module_name: str, name: str, has_await: bool, result_type: types.Type) -> ir.StructDecl:
    let bool_ty = types.primitive("bool")
    let int_ty = types.primitive("int")
    let ptr_void = types.Type.ty_generic(name = "ptr", args = single_ty_span(types.primitive("void")))
    let frame_c = naming.qualified_c_name(module_name, j2(name, "_frame"))

    var fields = vec.Vec[ir.Field].create()
    fields.push(ir.Field(name = "ready",          ty = bool_ty))
    fields.push(ir.Field(name = "cancelled",      ty = bool_ty))
    fields.push(ir.Field(name = "waiter_frame",   ty = ptr_void))
    fields.push(ir.Field(name = "waiter",         ty = ptr_void))
    if has_await:
        fields.push(ir.Field(name = "state",      ty = int_ty))
    if not is_void_type(result_type):
        fields.push(ir.Field(name = "result",     ty = result_type))

    return ir.StructDecl(
        name = frame_c,
        linkage_name = frame_c,
        fields = fields.as_span(),
        packed = false,
        alignment = 0,
        source_module = Option[str].none,
    )


# =============================================================================
#  Type helpers
# =============================================================================

public function is_void_type(t: types.Type) -> bool:
    match t:
        types.Type.ty_primitive as p:
            return p.name == "void"
        _:
            return false


public function ptr_void_type() -> types.Type:
    return types.Type.ty_generic(name = "ptr", args = single_ty_span(types.primitive("void")))


public function task_type(inner: types.Type) -> types.Type:
    var args = vec.Vec[types.Type].create()
    args.push(inner)
    return types.Type.ty_generic(name = "Task", args = args.as_span())


public function bool_type() -> types.Type:
    return types.primitive("bool")


public function int_type() -> types.Type:
    return types.primitive("int")


public function void_type() -> types.Type:
    return types.primitive("void")


function single_ty_span(t: types.Type) -> span[types.Type]:
    var v = vec.Vec[types.Type].create()
    v.push(t)
    return v.as_span()


function j2(a: str, b: str) -> str:
    var buf = string.String.create()
    buf.append(a)
    buf.append(b)
    return buf.as_str()
