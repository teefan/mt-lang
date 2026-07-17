## prefer-own-ptr — ptr[T] binding only used inside unsafe blocks
##
## Detects `let x: ptr[T] = ...` bindings where all uses of `x` are inside
## `unsafe:` blocks and suggests converting to `own[T]` for auto-deref.

import std.map as map_mod
import std.str
import std.hash
import std.vec as vec

import mtc.parser.ast as ast


public struct Diag:
    name: str
    line: ptr_uint


public function check(file: ast.SourceFile) -> vec.Vec[Diag]:
    var diags = vec.Vec[Diag].create()
    var i: ptr_uint = 0
    while i < file.declarations.len:
        unsafe:
            match read(file.declarations.data + i):
                ast.Decl.decl_function as fun:
                    check_body(fun.body, ref_of(diags))
                ast.Decl.decl_extending_block as ex:
                    var j: ptr_uint = 0
                    while j < ex.methods.len:
                        check_body(read(ex.methods.data + j).body, ref_of(diags))
                        j += 1
                _:
                    pass
        i += 1
    return diags


function check_body(body: ptr[ast.Stmt]?, diags: ref[vec.Vec[Diag]]) -> void:
    let bp = body else:
        return
    unsafe:
        match read(bp):
            ast.Stmt.stmt_block as blk:
                var candidates = map_mod.Map[str, bool].create()
                defer candidates.release()
                collect_locals(blk.statements, candidates)
                track_uses(blk.statements, candidates)
                emit_leaks(candidates, diags)
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


function collect_locals(stmts: span[ast.Stmt], c: ref[map_mod.Map[str, bool]]) -> void:
    var si: ptr_uint = 0
    while si < stmts.len:
        unsafe:
            match read(stmts.data + si):
                ast.Stmt.stmt_local as loc:
                    if loc.name != "_" and is_ptr_type(loc.stmt_type):
                        c.set(loc.name, false)
                _:
                    pass
        si += 1


function track_uses(stmts: span[ast.Stmt], c: ref[map_mod.Map[str, bool]]) -> void:
    var si: ptr_uint = 0
    while si < stmts.len:
        unsafe:
            match read(stmts.data + si):
                ast.Stmt.stmt_local as loc:
                    mark_use(loc.value, c)
                ast.Stmt.stmt_assignment as a:
                    mark_use(a.value, c)
                    mark_use(a.target, c)
                ast.Stmt.stmt_expression as e:
                    mark_use(e.expression, c)
                ast.Stmt.stmt_ret as r:
                    mark_use(r.value, c)
                _:
                    pass
        si += 1


function mark_use(ep: ptr[ast.Expr]?, c: ref[map_mod.Map[str, bool]]) -> void:
    let p = ep else:
        return
    unsafe:
        match read(p):
            ast.Expr.expr_identifier as id:
                if c.contains(id.name):
                    c.set(id.name, true)
            _:
                pass


function emit_leaks(candidates: map_mod.Map[str, bool], diags: ref[vec.Vec[Diag]]) -> void:
    var keys = candidates.keys()
    while true:
        let kp = keys.next() else:
            break
        let nm = unsafe: read(kp)
        let usedp = candidates.get(nm) else:
            continue
        if not unsafe: read(usedp):
            diags.push(Diag(name = nm, line = 0))
