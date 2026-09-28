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
    ## True for module-level declarations; false for parameters and locals.
    is_toplevel: bool


public function collect_bindings(source_text: str, ast_file: ast.SourceFile) -> vec.Vec[Binding]:
    var bindings = vec.Vec[Binding].create()

    collect_toplevel_names(bindings, ast_file.declarations, source_text)

    var di: ptr_uint = 0
    while di < ast_file.declarations.len:
        let region_end = declaration_region_end(ast_file, di, source_text)
        unsafe:
            collect_decl_bindings(bindings, ast_file.declarations.data + di, source_text, region_end)
        di += 1

    return bindings


## The last source line belonging to the declaration at `index`: the line before
## the next top-level declaration, or the file's last line.  Statement nodes
## record only their *first* line, so a body whose last statement spans several
## lines would otherwise truncate the scope of everything declared in it.
function declaration_region_end(ast_file: ast.SourceFile, index: ptr_uint, source_text: str) -> ptr_uint:
    var next = index + 1
    while next < ast_file.declarations.len:
        let line = unsafe: decl_start_line(read(ast_file.declarations.data + next))
        if line > 0:
            return line - 1
        next += 1
    return last_line(source_text)


## The first source line of a declaration, 0 for a declaration without one.
function decl_start_line(candidate: ast.Decl) -> ptr_uint:
    match candidate:
        ast.Decl.decl_function as fun:
            return fun.line
        ast.Decl.decl_foreign_function as ff:
            return ff.line
        ast.Decl.decl_extern_function as ext:
            return ext.line
        ast.Decl.decl_struct as s:
            return s.line
        ast.Decl.decl_union as u:
            return u.line
        ast.Decl.decl_enum as e:
            return e.line
        ast.Decl.decl_flags as fl:
            return fl.line
        ast.Decl.decl_variant as vr:
            return vr.line
        ast.Decl.decl_const as c:
            return c.line
        ast.Decl.decl_var as v:
            return v.line
        ast.Decl.decl_type_alias as ta:
            return ta.line
        ast.Decl.decl_opaque as op:
            return op.line
        ast.Decl.decl_interface as iface:
            return iface.line
        ast.Decl.decl_extending_block as ex:
            return ex.line
        ast.Decl.decl_event as ev:
            return ev.line
        _:
            return 0


function collect_decl_bindings(bindings: ref[vec.Vec[Binding]], dp: ptr[ast.Decl], source_text: str, region_end: ptr_uint) -> void:
    # An `extending` block declares one method per entry: each method's
    # parameters and body get their own scopes, as a plain function's do, and a
    # method's scope ends where the next method begins.
    unsafe:
        match read(dp):
            ast.Decl.decl_extending_block as ex:
                var mi: ptr_uint = 0
                while mi < ex.methods.len:
                    let method = read(ex.methods.data + mi)
                    var method_end = region_end
                    if mi + 1 < ex.methods.len:
                        method_end = read(ex.methods.data + mi + 1).line - 1
                    collect_params(bindings, method.method_params, method_end)
                    walk_body(bindings, method.body, method_end, source_text)
                    mi += 1
                return
            _:
                pass

    collect_params(bindings, decl_params(dp), region_end)
    walk_body(bindings, decl_body(dp), region_end, source_text)


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
                bindings.push(Binding(name = nl.name, line = nl.line, scope_end = last_line(source_text), is_toplevel = true))
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
        bindings.push(Binding(name = p.name, line = p.line, scope_end = scope_end, is_toplevel = false))
        pi += 1


function branch_body_end(body_node: ptr[ast.Stmt]?, fallback: ptr_uint) -> ptr_uint:
    let b = body_node else:
        return fallback
    unsafe:
        match read(b):
            ast.Stmt.stmt_block as blk:
                return block_last_line(blk.statements) - 1
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
                        bindings.push(Binding(name = loc.name, line = loc.line, scope_end = parent_end, is_toplevel = false))
                    if loc.destructure_bindings.is_some():
                        let binds = loc.destructure_bindings.unwrap()
                        var bi: ptr_uint = 0
                        while bi < binds.len:
                            var bn: str = read(binds.data + bi)
                            if bn != "_":
                                bindings.push(Binding(name = bn, line = loc.line, scope_end = parent_end, is_toplevel = false))
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
                                bindings.push(Binding(name = bn.value, line = arm.binding_line, scope_end = mend, is_toplevel = false))
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
                    bindings.push(Binding(name = loc.name, line = loc.line, scope_end = parent_end, is_toplevel = false))
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
            bindings.push(Binding(name = fb.name, line = line, scope_end = scope_end, is_toplevel = false))
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
    return last + 1


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
        if source.byte_at(i) == '\n':
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
    var target_end: ptr_uint = 0
    var found: bool = false

    var bi: ptr_uint = 0
    while bi < bindings.len():
        let bp = bindings.get(bi) else:
            break
        let b = unsafe: read(bp)
        if b.name.equal(name):
            if b.line == target_line:
                target_end = b.scope_end
                found = true
                break
            bi += 1
            continue
        bi += 1

    if not found:
        return true

    bi = 0
    while bi < bindings.len():
        let bp = bindings.get(bi) else:
            break
        let b = unsafe: read(bp)
        if b.name.equal(name) and b.line != target_line:
            if occ_line >= b.line and occ_line <= b.scope_end:
                let target_in_this = target_line >= b.line and target_line <= b.scope_end
                if not target_in_this:
                    return false
        bi += 1

    return occ_line >= target_line and occ_line <= target_end


## The declaration line of the innermost non-top-level binding named `name`
## that contains `cursor_line`, or none when the cursor is not on a local
## binding (module-level and unknown names both yield none).
public function local_binding_line(bindings: ref[vec.Vec[Binding]], name: str, cursor_line: ptr_uint) -> Option[ptr_uint]:
    var best_line: ptr_uint = 0
    var found = false
    var bi: ptr_uint = 0
    while bi < bindings.len():
        let bp = bindings.get(bi) else:
            break
        let b = unsafe: read(bp)
        if not b.is_toplevel and b.name.equal(name):
            if cursor_line >= b.line and cursor_line <= b.scope_end:
                if not found or b.line > best_line:
                    best_line = b.line
                    found = true
        bi += 1
    if not found:
        return Option[ptr_uint].none
    return Option[ptr_uint].some(value = best_line)
