## Scope tracking for scope-aware rename/references.  Walks a parsed AST to
## collect the line-range of every name binding and uses them to determine
## which occurrences share the same scope (avoids renaming shadowed locals in
## unrelated scopes).  All variant matches operate on pointers, matching the
## pattern used throughout the lowering module.

import std.str
import std.vec as vec

import mtc.parser.ast as ast
import mtc.parser.parser as parser
import mtc.parser.state as pstate


public struct Binding:
    name: str
    line: ptr_uint
    scope_end: ptr_uint


public function collect_bindings(source_text: str, ast_file: ast.SourceFile) -> vec.Vec[Binding]:
    var bindings = vec.Vec[Binding].create()

    collect_toplevel_names(bindings, ast_file.declarations, source_text)

    var di: ptr_uint = 0
    while di < ast_file.declarations.len:
        unsafe:
            collect_decl_bindings(bindings, ast_file.declarations.data + di, source_text)
        di += 1

    return bindings


function collect_decl_bindings(bindings: ref[vec.Vec[Binding]], dp: ptr[ast.Decl], source_text: str) -> void:
    let body_end = decl_body_end(dp)
    let params = decl_params(dp)
    var par_end = body_end
    if par_end == 0:
        par_end = last_line(source_text)
    collect_params(bindings, params, par_end)
    if body_end > 0:
        let body = decl_body(dp)
        walk_body(bindings, body, body_end, source_text)


function decl_params(dp: ptr[ast.Decl]) -> span[ast.Param]:
    unsafe:
        match read(dp):
            ast.Decl.decl_function as fun:
                return fun.method_params
            _:
                return span[ast.Param]()


function decl_body(dp: ptr[ast.Decl]) -> ptr[ast.Stmt]?:
    unsafe:
        match read(dp):
            ast.Decl.decl_function as fun:
                return fun.body
            ast.Decl.decl_const as c:
                return c.block_body
            _:
                return null


function decl_body_end(dp: ptr[ast.Decl]) -> ptr_uint:
    let body_node = decl_body(dp)
    return body_end_of(body_node)


function collect_toplevel_names(bindings: ref[vec.Vec[Binding]], decls: span[ast.Decl], source_text: str) -> void:
    var di: ptr_uint = 0
    while di < decls.len:
        unsafe:
            let nl = decl_name_and_line(decls.data + di)
            if nl.name.len > 0:
                bindings.push(Binding(name = nl.name, line = nl.line, scope_end = last_line(source_text)))
        di += 1


struct NameLine:
    name: str
    line: ptr_uint


function decl_name_and_line(dp: ptr[ast.Decl]) -> NameLine:
    unsafe:
        match read(dp):
            ast.Decl.decl_function as fun:
                return NameLine(name = fun.name, line = fun.line)
            ast.Decl.decl_const as c:
                return NameLine(name = c.name, line = c.line)
            ast.Decl.decl_var as v:
                return NameLine(name = v.name, line = v.line)
            ast.Decl.decl_struct as s:
                return NameLine(name = s.name, line = s.line)
            ast.Decl.decl_union as u:
                return NameLine(name = u.name, line = u.line)
            ast.Decl.decl_enum as e:
                return NameLine(name = e.name, line = e.line)
            ast.Decl.decl_flags as fl:
                return NameLine(name = fl.name, line = fl.line)
            ast.Decl.decl_variant as vr:
                return NameLine(name = vr.name, line = vr.line)
            ast.Decl.decl_opaque as op:
                return NameLine(name = op.name, line = op.line)
            ast.Decl.decl_interface as ifc:
                return NameLine(name = ifc.name, line = ifc.line)
            ast.Decl.decl_type_alias as ta:
                return NameLine(name = ta.name, line = ta.line)
            _:
                return NameLine(name = "", line = 0)


function collect_params(bindings: ref[vec.Vec[Binding]], params: span[ast.Param], scope_end: ptr_uint) -> void:
    var pi: ptr_uint = 0
    while pi < params.len:
        var p: ast.Param
        unsafe:
            p = read(params.data + pi)
        bindings.push(Binding(name = p.name, line = p.line, scope_end = scope_end))
        pi += 1


function branch_body_end(body_node: ptr[ast.Stmt]?, fallback: ptr_uint) -> ptr_uint:
    let b = body_node else:
        return fallback
    unsafe:
        match read(b):
            ast.Stmt.stmt_block as blk:
                return block_last_line(blk.statements)
            _:
                return fallback


function walk_body(bindings: ref[vec.Vec[Binding]], body_node: ptr[ast.Stmt]?, scope_end: ptr_uint, source_text: str) -> void:
    let b = body_node else:
        return
    unsafe:
        match read(b):
            ast.Stmt.stmt_block as blk:
                walk_stmts(bindings, blk.statements, scope_end, source_text)
            _:
                pass


function walk_stmts(bindings: ref[vec.Vec[Binding]], stmts: span[ast.Stmt], parent_end: ptr_uint, source_text: str) -> void:
    var si: ptr_uint = 0
    while si < stmts.len:
        unsafe:
            match read(stmts.data + si):
                ast.Stmt.stmt_local as loc:
                    if loc.name != "_" and loc.name.len > 0:
                        bindings.push(Binding(name = loc.name, line = loc.line, scope_end = parent_end))
                    if loc.destructure_bindings.is_some():
                        let binds = loc.destructure_bindings.unwrap()
                        var bi: ptr_uint = 0
                        while bi < binds.len:
                            var bn: str = read(binds.data + bi)
                            if bn != "_":
                                bindings.push(Binding(name = bn, line = loc.line, scope_end = parent_end))
                            bi += 1
                ast.Stmt.stmt_if as iff:
                    var ib: ptr_uint = 0
                    while ib < iff.branches.len:
                        let branch = unsafe: read(iff.branches.data + ib)
                        let branch_end = branch_body_end(branch.body, parent_end)
                        walk_stmt(bindings, branch.body, branch_end, source_text)
                        ib += 1
                    if iff.else_body != null:
                        let else_end = branch_body_end(iff.else_body, parent_end)
                        walk_stmt(bindings, iff.else_body, else_end, source_text)
                ast.Stmt.stmt_while as w:
                    let wend = branch_body_end(w.body, parent_end)
                    walk_stmt(bindings, w.body, wend, source_text)
                ast.Stmt.stmt_for as f:
                    let fend = branch_body_end(f.body, parent_end)
                    collect_for_bindings(bindings, f.bindings, fend, f.line)
                    walk_stmt(bindings, f.body, fend, source_text)
                ast.Stmt.stmt_match as m:
                    var mi: ptr_uint = 0
                    while mi < m.arms.len:
                        let arm = unsafe: read(m.arms.data + mi)
                        let mend = branch_body_end(arm.body, parent_end)
                        match arm.binding_name:
                            Option.some as bn:
                                bindings.push(Binding(name = bn.value, line = arm.binding_line, scope_end = mend))
                            Option.none:
                                pass
                        walk_stmt(bindings, arm.body, mend, source_text)
                        mi += 1
                ast.Stmt.stmt_block as blk:
                    walk_stmts(bindings, blk.statements, parent_end, source_text)
                _:
                    pass
        si += 1


function walk_stmt(bindings: ref[vec.Vec[Binding]], sp: ptr[ast.Stmt]?, parent_end: ptr_uint, source_text: str) -> void:
    let b = sp else:
        return
    unsafe:
        match read(b):
            ast.Stmt.stmt_block as blk:
                walk_stmts(bindings, blk.statements, parent_end, source_text)
            ast.Stmt.stmt_local as loc:
                if loc.name != "_" and loc.name.len > 0:
                    bindings.push(Binding(name = loc.name, line = loc.line, scope_end = parent_end))
            ast.Stmt.stmt_if as iff:
                var ib: ptr_uint = 0
                while ib < iff.branches.len:
                    let branch = unsafe: read(iff.branches.data + ib)
                    let branch_end = branch_body_end(branch.body, parent_end)
                    walk_stmt(bindings, branch.body, branch_end, source_text)
                    ib += 1
                if iff.else_body != null:
                    let else_end = branch_body_end(iff.else_body, parent_end)
                    walk_stmt(bindings, iff.else_body, else_end, source_text)
            _:
                pass


function collect_for_bindings(bindings: ref[vec.Vec[Binding]], for_bindings: span[ast.ForBinding], scope_end: ptr_uint, line: ptr_uint) -> void:
    var i: ptr_uint = 0
    while i < for_bindings.len:
        var fb: ast.ForBinding
        unsafe:
            fb = read(for_bindings.data + i)
        if fb.name != "_":
            bindings.push(Binding(name = fb.name, line = line, scope_end = scope_end))
        i += 1


function body_end_of(body_node: ptr[ast.Stmt]?) -> ptr_uint:
    let b = body_node else:
        return 0
    unsafe:
        match read(b):
            ast.Stmt.stmt_block as blk:
                return block_last_line(blk.statements)
            _:
                return 0


function block_last_line(stmts: span[ast.Stmt]) -> ptr_uint:
    var last: ptr_uint = 0
    var si: ptr_uint = 0
    while si < stmts.len:
        let sl = unsafe: stmt_line(stmts.data + si)
        if sl > last:
            last = sl
        si += 1
    return last + 0


function stmt_line(sp: ptr[ast.Stmt]) -> ptr_uint:
    unsafe:
        match read(sp):
            ast.Stmt.stmt_local as loc:
                return loc.line
            ast.Stmt.stmt_ret as r:
                return r.line
            ast.Stmt.stmt_block as blk:
                return block_last_line(blk.statements)
            _:
                return 0


function last_line(source: str) -> ptr_uint:
    var line: ptr_uint = 1
    var i: ptr_uint = 0
    while i < source.len:
        if source.byte_at(i) == 10:
            line += 1
        i += 1
    return line


## True when an occurrence at `occ_line` should be renamed alongside a target
## declaration at `target_line`.
##
## Returns true when the occurrence is within the same scope region as the
## target and no shadowing binding of `name` exists between target and
## occurrence.  If the target is a module-level declaration (no enclosing
## function scope), all occurrences are in scope (global rename).
public function is_in_same_scope(bindings: ref[vec.Vec[Binding]], name: str, target_line: ptr_uint, occ_line: ptr_uint) -> bool:
    var scope_end: ptr_uint = 0
    var found: bool = false

    var bi: ptr_uint = 0
    while bi < bindings.len():
        let bp = bindings.get(bi) else:
            break
        let b = unsafe: read(bp)
        if b.name.equal(name):
            if b.line == target_line:
                scope_end = b.scope_end
                found = true
            else if b.line != target_line:
                if occ_line >= b.line and occ_line <= b.scope_end:
                    let target_in_shadow = target_line >= b.line and target_line <= b.scope_end
                    return target_in_shadow
        bi += 1

    if not found:
        return true

    return occ_line <= scope_end
