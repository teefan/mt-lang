## redundant-cast — cast target matches source declared type
##
## Detects `int<-x` where `x` is already declared as `int` (by comparing
## the cast target TypeRef text with the variable's declared TypeRef text).

import std.map as map_mod
import std.str
import std.hash
import std.vec as vec

import mtc.parser.ast as ast


public struct Diag:
    name: str
    line: ptr_uint
    ## 1-based column of the cast target type (`int<-x` points at `int`).
    column: ptr_uint


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
                var declared = map_mod.Map[str, str].create()
                defer declared.release()
                collect_types(blk.statements, ref_of(declared))
                check_casts(blk.statements, ref_of(declared), diags)
            _:
                pass


function collect_types(stmts: span[ast.Stmt], declared: ref[map_mod.Map[str, str]]) -> void:
    var si: ptr_uint = 0
    while si < stmts.len:
        unsafe:
            match read(stmts.data + si):
                ast.Stmt.stmt_local as loc:
                    let tr = loc.stmt_type
                    if tr != null and loc.name != "_":
                        declared.set(loc.name, type_last_name(tr))
                _:
                    pass
        si += 1


function check_casts(stmts: span[ast.Stmt], declared: ref[map_mod.Map[str, str]], diags: ref[vec.Vec[Diag]]) -> void:
    var si: ptr_uint = 0
    while si < stmts.len:
        unsafe:
            match read(stmts.data + si):
                ast.Stmt.stmt_local as loc:
                    check_expr(loc.value, declared, diags)
                ast.Stmt.stmt_assignment as a:
                    check_expr(a.value, declared, diags)
                ast.Stmt.stmt_expression as e:
                    check_expr(e.expression, declared, diags)
                ast.Stmt.stmt_ret as r:
                    check_expr(r.value, declared, diags)
                _:
                    pass
        si += 1


function check_expr(ep: ptr[ast.Expr]?, declared: ref[map_mod.Map[str, str]], diags: ref[vec.Vec[Diag]]) -> void:
    let p = ep else:
        return
    unsafe:
        match read(p):
            ast.Expr.expr_unsafe as u:
                check_expr(u.expression, declared, diags)
            ast.Expr.expr_prefix_cast as c:
                match read(c.expression):
                    ast.Expr.expr_identifier as id:
                        if id.name == "_":
                            return
                        let dt = declared.get(id.name) else:
                            return
                        let ct = type_last_name(c.target_type)
                        if unsafe: read(dt).equal(ct):
                            diags.push(Diag(name = id.name, line = c.line, column = c.column))
                    _:
                        pass
            _:
                pass


function type_last_name(type_ref: ptr[ast.TypeRef]) -> str:
    unsafe:
        let tr = read(type_ref)
        if tr.name.parts.len == 0:
            return ""
        return read(tr.name.parts.data + tr.name.parts.len - 1)
