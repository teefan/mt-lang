## prefer-own-ptr — a `ptr[T]` binding whose every use is inside `unsafe:`.
##
## The host records a *candidate* per local declaration (`record_ptr_candidate`:
## an explicit `ptr[...]` annotation, or a `heap.must_alloc`-family initializer)
## and counts every identifier use by whether it sits inside an `unsafe:` context
## (`track_binding_unsafe_use`); the warning fires at the scope pop when the
## binding is not a parameter, has at least one unsafe use and no safe one.

import std.str
import std.vec as vec

import mtc.parser.ast as ast


public struct Diag:
    name: str
    line: ptr_uint
    column: ptr_uint


struct Candidate:
    name: str
    line: ptr_uint
    column: ptr_uint
    unsafe_uses: ptr_uint
    safe_uses: ptr_uint
    is_param: bool


public function check(file: ast.SourceFile) -> vec.Vec[Diag]:
    var diags = vec.Vec[Diag].create()
    var i: ptr_uint = 0
    while i < file.declarations.len:
        unsafe:
            match read(file.declarations.data + i):
                ast.Decl.decl_function as fun:
                    check_body(fun.method_params, fun.body, ref_of(diags))
                ast.Decl.decl_extending_block as ex:
                    var j: ptr_uint = 0
                    while j < ex.methods.len:
                        let m = read(ex.methods.data + j)
                        check_body(m.method_params, m.body, ref_of(diags))
                        j += 1
                _:
                    pass
        i += 1
    return diags


function check_body(params: span[ast.Param], body: ptr[ast.Stmt]?, diags: ref[vec.Vec[Diag]]) -> void:
    let bp = body else:
        return
    var candidates = vec.Vec[Candidate].create()
    defer: candidates.release()
    var pi: ptr_uint = 0
    while pi < params.len:
        var p: ast.Param
        unsafe:
            p = read(params.data + pi)
        if is_ptr_type(ptr_of(p.param_type)):
            candidates.push(Candidate(name = p.name, line = p.line, column = p.column, unsafe_uses = 0, safe_uses = 0, is_param = true))
        pi += 1
    collect_locals(bp, ref_of(candidates))
    count_uses(bp, ref_of(candidates), 0)
    emit_candidates(ref_of(candidates), diags)


## A candidate declaration: an explicit `ptr[...]`/`const_ptr[...]` annotation, or
## a heap-allocation initializer (the host's `heap_alloc_call?`/`alloc_wrapper`).
function collect_locals(stmt: ptr[ast.Stmt], candidates: ref[vec.Vec[Candidate]]) -> void:
    unsafe:
        match read(stmt):
            ast.Stmt.stmt_block as blk:
                var si: ptr_uint = 0
                while si < blk.statements.len:
                    collect_locals(blk.statements.data + si, candidates)
                    si += 1
            ast.Stmt.stmt_local as loc:
                if loc.name.len > 0 and loc.name != "_" and (is_ptr_type(loc.stmt_type) or is_heap_alloc(loc.value)):
                    candidates.push(Candidate(name = loc.name, line = loc.line, column = loc.column, unsafe_uses = 0, safe_uses = 0, is_param = false))
            ast.Stmt.stmt_if as iff:
                var bi: ptr_uint = 0
                while bi < iff.branches.len:
                    var inner: ptr[ast.Stmt] = read(iff.branches.data + bi).body
                    collect_locals(inner, candidates)
                    bi += 1
                if iff.else_body != null:
                    collect_locals(ptr[ast.Stmt]<-iff.else_body, candidates)
            ast.Stmt.stmt_while as wh:
                if wh.body != null:
                    collect_locals(ptr[ast.Stmt]<-wh.body, candidates)
            ast.Stmt.stmt_for as fr:
                if fr.body != null:
                    collect_locals(ptr[ast.Stmt]<-fr.body, candidates)
            ast.Stmt.stmt_match as mt:
                var ai: ptr_uint = 0
                while ai < mt.arms.len:
                    if read(mt.arms.data + ai).body != null:
                        collect_locals(ptr[ast.Stmt]<-read(mt.arms.data + ai).body, candidates)
                    ai += 1
            ast.Stmt.stmt_defer as df:
                if df.body != null:
                    collect_locals(ptr[ast.Stmt]<-df.body, candidates)
            ast.Stmt.stmt_unsafe as un:
                if un.body != null:
                    collect_locals(ptr[ast.Stmt]<-un.body, candidates)
            ast.Stmt.stmt_when as wn:
                var wi: ptr_uint = 0
                while wi < wn.branches.len:
                    var body = read(wn.branches.data + wi).body
                    var bi: ptr_uint = 0
                    while bi < body.len:
                        collect_locals(body.data + bi, candidates)
                        bi += 1
                    wi += 1
                if wn.else_body != null:
                    collect_locals(ptr[ast.Stmt]<-wn.else_body, candidates)
            ast.Stmt.stmt_error_block as eb:
                collect_locals(eb.body, candidates)
            _:
                pass


function is_ptr_type(tr: ptr[ast.TypeRef]?) -> bool:
    let t = tr else:
        return false
    unsafe:
        if read(t).name.parts.len == 0:
            return false
        let first = read(read(t).name.parts.data + 0)
        return first.equal("ptr") or first.equal("const_ptr")


## The host's `heap_alloc_call?` / `alloc_wrapper_name`: a `heap.must_alloc…`
## family call, or a call whose callee name wraps one.
function is_heap_alloc(value: ptr[ast.Expr]?) -> bool:
    let vp = value else:
        return false
    unsafe:
        match read(vp):
            ast.Expr.expr_call as call:
                match read(call.callee):
                    ast.Expr.expr_member_access as ma:
                        return ma.member_name.equal("must_alloc") or ma.member_name.equal("alloc") or ma.member_name.equal("must_alloc_zeroed") or ma.member_name.equal("must_resize")
                    _:
                        return false
            _:
                return false


## Count every use of each candidate, by whether it sits inside `unsafe:`.
function count_uses(stmt: ptr[ast.Stmt], candidates: ref[vec.Vec[Candidate]], unsafe_depth: ptr_uint) -> void:
    unsafe:
        match read(stmt):
            ast.Stmt.stmt_block as blk:
                var si: ptr_uint = 0
                while si < blk.statements.len:
                    count_uses(blk.statements.data + si, candidates, unsafe_depth)
                    si += 1
            ast.Stmt.stmt_local as loc:
                count_expr_use(loc.value, candidates, unsafe_depth)
                count_stmts_use(loc.else_body, candidates, unsafe_depth)
            ast.Stmt.stmt_assignment as a:
                count_expr_use(a.value, candidates, unsafe_depth)
                count_expr_use(a.target, candidates, unsafe_depth)
            ast.Stmt.stmt_expression as e:
                count_expr_use(e.expression, candidates, unsafe_depth)
            ast.Stmt.stmt_ret as r:
                count_expr_use(r.value, candidates, unsafe_depth)
            ast.Stmt.stmt_if as iff:
                var bi: ptr_uint = 0
                while bi < iff.branches.len:
                    var br = read(iff.branches.data + bi)
                    count_expr_use(br.condition, candidates, unsafe_depth)
                    count_uses(br.body, candidates, unsafe_depth)
                    bi += 1
                count_stmts_use(iff.else_body, candidates, unsafe_depth)
            ast.Stmt.stmt_while as wh:
                count_expr_use(wh.condition, candidates, unsafe_depth)
                count_stmts_use(wh.body, candidates, unsafe_depth)
            ast.Stmt.stmt_for as fr:
                var ii: ptr_uint = 0
                while ii < fr.iterables.len:
                    count_expr_use(fr.iterables.data + ii, candidates, unsafe_depth)
                    ii += 1
                count_stmts_use(fr.body, candidates, unsafe_depth)
            ast.Stmt.stmt_match as mt:
                count_expr_use(mt.scrutinee, candidates, unsafe_depth)
                var ai: ptr_uint = 0
                while ai < mt.arms.len:
                    count_stmts_use(read(mt.arms.data + ai).body, candidates, unsafe_depth)
                    ai += 1
            ast.Stmt.stmt_defer as df:
                count_expr_use(df.expression, candidates, unsafe_depth)
                count_stmts_use(df.body, candidates, unsafe_depth)
            ast.Stmt.stmt_unsafe as un:
                count_stmts_use(un.body, candidates, unsafe_depth + 1)
            ast.Stmt.stmt_when as wn:
                count_expr_use(wn.discriminant, candidates, unsafe_depth)
                var wi: ptr_uint = 0
                while wi < wn.branches.len:
                    var body = read(wn.branches.data + wi).body
                    var bi: ptr_uint = 0
                    while bi < body.len:
                        count_uses(body.data + bi, candidates, unsafe_depth)
                        bi += 1
                    wi += 1
                count_stmts_use(wn.else_body, candidates, unsafe_depth)
            ast.Stmt.stmt_error_block as eb:
                count_uses(eb.body, candidates, unsafe_depth)
            _:
                pass


function count_stmts_use(stmt: ptr[ast.Stmt]?, candidates: ref[vec.Vec[Candidate]], unsafe_depth: ptr_uint) -> void:
    let sp = stmt else:
        return
    count_uses(sp, candidates, unsafe_depth)


function count_expr_use(expr: ptr[ast.Expr]?, candidates: ref[vec.Vec[Candidate]], unsafe_depth: ptr_uint) -> void:
    let ep = expr else:
        return
    unsafe:
        match read(ep):
            ast.Expr.expr_identifier as id:
                record_use(candidates, id.name, unsafe_depth)
            ast.Expr.expr_member_access as ma:
                count_expr_use(ma.receiver, candidates, unsafe_depth)
            ast.Expr.expr_binary_op as b:
                count_expr_use(b.left, candidates, unsafe_depth)
                count_expr_use(b.right, candidates, unsafe_depth)
            ast.Expr.expr_unary_op as u:
                count_expr_use(u.operand, candidates, unsafe_depth)
            ast.Expr.expr_call as call:
                count_expr_use(call.callee, candidates, unsafe_depth)
                var i: ptr_uint = 0
                while i < call.args.len:
                    count_expr_use(read(call.args.data + i).arg_value, candidates, unsafe_depth)
                    i += 1
            ast.Expr.expr_index_access as ix:
                count_expr_use(ix.receiver, candidates, unsafe_depth)
                count_expr_use(ix.index, candidates, unsafe_depth)
            ast.Expr.expr_specialization as sp:
                count_expr_use(sp.callee, candidates, unsafe_depth)
            ast.Expr.expr_prefix_cast as pc:
                count_expr_use(pc.expression, candidates, unsafe_depth)
            ast.Expr.expr_unsafe as us:
                count_expr_use(us.expression, candidates, unsafe_depth + 1)
            ast.Expr.expr_await as aw:
                count_expr_use(aw.expression, candidates, unsafe_depth)
            ast.Expr.expr_detach as dt:
                count_expr_use(dt.expression, candidates, unsafe_depth)
            ast.Expr.expr_if as iff:
                count_expr_use(iff.condition, candidates, unsafe_depth)
                count_expr_use(iff.then_expr, candidates, unsafe_depth)
                count_expr_use(iff.else_expr, candidates, unsafe_depth)
            ast.Expr.expr_expression_list as el:
                var ei: ptr_uint = 0
                while ei < el.elements.len:
                    count_expr_use(el.elements.data + ei, candidates, unsafe_depth)
                    ei += 1
            ast.Expr.expr_named as nm:
                count_expr_use(nm.value, candidates, unsafe_depth)
            ast.Expr.expr_range as rg:
                count_expr_use(rg.start_expr, candidates, unsafe_depth)
                count_expr_use(rg.end_expr, candidates, unsafe_depth)
            _:
                pass


function record_use(candidates: ref[vec.Vec[Candidate]], name: str, unsafe_depth: ptr_uint) -> void:
    var i: ptr_uint = 0
    while i < candidates.len():
        let cp = candidates.get(i) else:
            break
        if unsafe: read(cp).name.equal(name):
            if unsafe_depth > 0:
                unsafe: read(cp).unsafe_uses += 1
            else:
                unsafe: read(cp).safe_uses += 1
        i += 1


## The host's `emit_scope_warnings` gate: `binding_kind != :param &&
## uses[:unsafe] > 0 && uses[:safe] == 0 && @ptr_candidates.include?(name)`.
function emit_candidates(candidates: ref[vec.Vec[Candidate]], diags: ref[vec.Vec[Diag]]) -> void:
    var i: ptr_uint = 0
    while i < candidates.len():
        let cp = candidates.get(i) else:
            break
        let c = unsafe: read(cp)
        if not c.is_param and c.unsafe_uses > 0 and c.safe_uses == 0:
            diags.push(Diag(name = c.name, line = c.line, column = c.column))
        i += 1
