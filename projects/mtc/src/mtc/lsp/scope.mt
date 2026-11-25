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

## Binding kinds, mirroring the host's `Bindings::ValueBinding#kind` where the
## semantic-token scanner reads it: a parameter renders `parameter`, an
## immutable local (`let`, a `for` binding, a match-arm binding, a destructured
## name) renders `variable` + `readonly`, a mutable local (`var`) renders bare
## `variable`.
public const BINDING_TOPLEVEL: ptr_uint = 0
public const BINDING_PARAM: ptr_uint = 1
public const BINDING_IMMUTABLE: ptr_uint = 2
public const BINDING_MUTABLE: ptr_uint = 3

public struct Binding:
    name: str
    line: ptr_uint
    scope_end: ptr_uint
    ## True for module-level declarations; false for parameters and locals.
    is_toplevel: bool
    ## One of the BINDING_* constants above.
    kind: ptr_uint
    ## True for parameters and for locals declared directly in a function body.
    ## The host's completion snapshots (the token classifier's
    ## `local_semantic_value_binding`) carry only those: a local bound inside a
    ## nested block — an `if`/`while`/`for`/`match` body, `unsafe`, `defer`, a
    ## `when` branch — is absent from the snapshot the classifier reads, so a
    ## reference to it falls through to the plain-value arms.
    function_level: bool


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
## the declaration that *starts* next in source order, or the file's last line.
## Statement nodes record only their *first* line, so a body whose last
## statement spans several lines would otherwise truncate the scope of
## everything declared in it.  The declaration list is not always source-ordered
## — the analyzer appends the `emit`-expanded declarations at its end — so the
## boundary is the nearest later start line, not the next list entry.
function declaration_region_end(ast_file: ast.SourceFile, index: ptr_uint, source_text: str) -> ptr_uint:
    let start = unsafe: decl_start_line(read(ast_file.declarations.data + index))
    var nearest: ptr_uint = 0
    var di: ptr_uint = 0
    while di < ast_file.declarations.len:
        let line = unsafe: decl_start_line(read(ast_file.declarations.data + di))
        if line > start and (nearest == 0 or line < nearest):
            nearest = line
        di += 1
    if nearest > 0:
        return nearest - 1
    return last_line(source_text)


## The first source line of a declaration, 0 for a declaration without one.
public function decl_start_line(candidate: ast.Decl) -> ptr_uint:
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


function collect_decl_bindings(
    bindings: ref[vec.Vec[Binding]],
    dp: ptr[ast.Decl],
    source_text: str,
    region_end: ptr_uint
) -> void:
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
    # Every top-level binding ends at the file's last line, so scan the source
    # once for the whole declaration list.  Rescanning per declaration was
    # quadratic in declarations × file bytes and made one `inlayHint` on a
    # large file (589 top-level decls × ~1 MB) run for minutes.
    let file_last_line = last_line(source_text)
    var di: ptr_uint = 0
    while di < decls.len:
        unsafe:
            let nl = decl_name_and_line(decls.data + di)
            if nl.name.len > 0:
                bindings.push(Binding(
                    name = nl.name,
                    line = nl.line,
                    scope_end = file_last_line,
                    is_toplevel = true,
                    kind = BINDING_TOPLEVEL,
                    function_level = true
                ))
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
        bindings.push(Binding(
            name = p.name,
            line = p.line,
            scope_end = scope_end,
            is_toplevel = false,
            kind = BINDING_PARAM,
            function_level = true
        ))
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


function walk_body(
    bindings: ref[vec.Vec[Binding]],
    body_node: ptr[ast.Stmt]?,
    scope_end: ptr_uint,
    source_text: str
) -> void:
    let b = body_node else:
        return
    unsafe:
        match read(b):
            ast.Stmt.stmt_block as blk:
                walk_stmts(bindings, blk.statements, scope_end, source_text, true)
            _:
                pass


function walk_stmts(
    bindings: ref[vec.Vec[Binding]],
    stmts: span[ast.Stmt],
    parent_end: ptr_uint,
    source_text: str,
    function_level: bool
) -> void:
    var si: ptr_uint = 0
    while si < stmts.len:
        unsafe:
            match read(stmts.data + si):
                ast.Stmt.stmt_local as loc:
                    let local_kind = if loc.is_let: BINDING_IMMUTABLE else: BINDING_MUTABLE
                    if loc.name != "_" and loc.name.len > 0:
                        bindings.push(Binding(
                            name = loc.name,
                            line = loc.line,
                            scope_end = parent_end,
                            is_toplevel = false,
                            kind = local_kind,
                            function_level = function_level
                        ))
                    if loc.destructure_bindings.is_some():
                        let binds = loc.destructure_bindings.unwrap()
                        var bi: ptr_uint = 0
                        while bi < binds.len:
                            var bn: str = read(binds.data + bi)
                            if bn != "_":
                                bindings.push(Binding(
                                    name = bn,
                                    line = loc.line,
                                    scope_end = parent_end,
                                    is_toplevel = false,
                                    kind = local_kind,
                                    function_level = function_level
                                ))
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
                                bindings.push(Binding(
                                    name = bn.value,
                                    line = arm.binding_line,
                                    scope_end = mend,
                                    is_toplevel = false,
                                    kind = BINDING_IMMUTABLE,
                                    function_level = false
                                ))
                            Option.none:
                                pass
                        walk_stmt(bindings, arm.body, mend, source_text)
                        mi += 1
                ast.Stmt.stmt_block as blk:
                    walk_stmts(bindings, blk.statements, parent_end, source_text, function_level)
                ast.Stmt.stmt_unsafe as uns:
                    walk_stmt(bindings, uns.body, parent_end, source_text)
                ast.Stmt.stmt_defer as dfr:
                    walk_stmt(bindings, dfr.body, parent_end, source_text)
                ast.Stmt.stmt_when as whn:
                    var wi: ptr_uint = 0
                    while wi < whn.branches.len:
                        let branch = unsafe: read(whn.branches.data + wi)
                        walk_stmts(bindings, branch.body, parent_end, source_text, false)
                        wi += 1
                    walk_stmt(bindings, whn.else_body, parent_end, source_text)
                ast.Stmt.stmt_parallel_block as pb:
                    walk_stmts(bindings, pb.bodies, parent_end, source_text, false)
                ast.Stmt.stmt_error_block as eb:
                    walk_stmt(bindings, eb.body, parent_end, source_text)
                _:
                    pass
        si += 1


function walk_stmt(bindings: ref[vec.Vec[Binding]], sp: ptr[ast.Stmt]?, parent_end: ptr_uint, source_text: str) -> void:
    let b = sp else:
        return
    unsafe:
        match read(b):
            ast.Stmt.stmt_block as blk:
                walk_stmts(bindings, blk.statements, parent_end, source_text, false)
            ast.Stmt.stmt_local as loc:
                if loc.name != "_" and loc.name.len > 0:
                    let local_kind = if loc.is_let: BINDING_IMMUTABLE else: BINDING_MUTABLE
                    bindings.push(Binding(
                        name = loc.name,
                        line = loc.line,
                        scope_end = parent_end,
                        is_toplevel = false,
                        kind = local_kind,
                        function_level = false
                    ))
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
            ast.Stmt.stmt_unsafe as uns:
                walk_stmt(bindings, uns.body, parent_end, source_text)
            ast.Stmt.stmt_defer as dfr:
                walk_stmt(bindings, dfr.body, parent_end, source_text)
            ast.Stmt.stmt_while as wh:
                walk_stmt(bindings, wh.body, branch_body_end(wh.body, parent_end), source_text)
            ast.Stmt.stmt_for as fr:
                collect_for_bindings(bindings, fr.bindings, branch_body_end(fr.body, parent_end), fr.line)
                walk_stmt(bindings, fr.body, branch_body_end(fr.body, parent_end), source_text)
            _:
                pass


function collect_for_bindings(
    bindings: ref[vec.Vec[Binding]],
    for_bindings: span[ast.ForBinding],
    scope_end: ptr_uint,
    line: ptr_uint
) -> void:
    var i: ptr_uint = 0
    while i < for_bindings.len:
        var fb: ast.ForBinding
        unsafe:
            fb = read(for_bindings.data + i)
        if fb.name != "_":
            bindings.push(Binding(
                name = fb.name,
                line = line,
                scope_end = scope_end,
                is_toplevel = false,
                kind = BINDING_MUTABLE,
                function_level = false
            ))
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


## The last source line a statement occupies, 0 when it carries none.  A
## declaration's scope runs to the last line of its body, so every statement
## kind's *last* line matters: a body whose final statement is an assignment, a
## call or a loop would otherwise end the scope early and hide the enclosing
## binding from `is_in_same_scope`.
function stmt_line(sp: ptr[ast.Stmt]) -> ptr_uint:
    unsafe:
        match read(sp):
            ast.Stmt.stmt_local as loc:
                return max_line(loc.line, stmt_line_opt(loc.else_body))
            ast.Stmt.stmt_ret as r:
                return r.line
            ast.Stmt.stmt_block as blk:
                return block_last_line(blk.statements)
            ast.Stmt.stmt_assignment as asn:
                return asn.line
            ast.Stmt.stmt_if as iff:
                var last = iff.line
                var bi: ptr_uint = 0
                while bi < iff.branches.len:
                    let branch = read(iff.branches.data + bi)
                    last = max_line(last, max_line(branch.line, stmt_line_opt(branch.body)))
                    bi += 1
                return max_line(last, stmt_line_opt(iff.else_body))
            ast.Stmt.stmt_while as wh:
                return max_line(wh.line, stmt_line_opt(wh.body))
            ast.Stmt.stmt_for as fr:
                return max_line(fr.line, stmt_line_opt(fr.body))
            ast.Stmt.stmt_match as mt:
                var last = mt.line
                var mi: ptr_uint = 0
                while mi < mt.arms.len:
                    let arm = read(mt.arms.data + mi)
                    last = max_line(last, stmt_line_opt(arm.body))
                    mi += 1
                return last
            ast.Stmt.stmt_defer as dfr:
                return max_line(dfr.line, stmt_line_opt(dfr.body))
            ast.Stmt.stmt_unsafe as uns:
                return max_line(uns.line, stmt_line_opt(uns.body))
            ast.Stmt.stmt_expression as ex:
                return ex.line
            ast.Stmt.stmt_static_assert as sa:
                return sa.line
            ast.Stmt.stmt_error_block as eb:
                return max_line(eb.line, stmt_line_opt(eb.body))
            ast.Stmt.stmt_when as wh:
                var last = wh.line
                var wi: ptr_uint = 0
                while wi < wh.branches.len:
                    let branch = read(wh.branches.data + wi)
                    var bi2: ptr_uint = 0
                    while bi2 < branch.body.len:
                        last = max_line(last, stmt_line(branch.body.data + bi2))
                        bi2 += 1
                    wi += 1
                return max_line(last, stmt_line_opt(wh.else_body))
            ast.Stmt.stmt_parallel_block as pb:
                var last = pb.line
                var pi: ptr_uint = 0
                while pi < pb.bodies.len:
                    last = max_line(last, stmt_line(pb.bodies.data + pi))
                    pi += 1
                return last
            _:
                return 0


function stmt_line_opt(sp: ptr[ast.Stmt]?) -> ptr_uint:
    let node = sp else:
        return 0
    return stmt_line(node)


function max_line(left: ptr_uint, right: ptr_uint) -> ptr_uint:
    if right > left:
        return right
    return left


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
public function is_in_same_scope(
    bindings: ref[vec.Vec[Binding]],
    name: str,
    target_line: ptr_uint,
    occ_line: ptr_uint
) -> bool:
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
public function local_binding_line(
    bindings: ref[vec.Vec[Binding]],
    name: str,
    cursor_line: ptr_uint
) -> Option[ptr_uint]:
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


## The kind of the binding named `name` that the host's
## `local_semantic_value_binding` resolves at `line` — a parameter or a local
## declared directly in a function body — or none when no such binding is in
## scope.  The host's completion snapshots carry only function-level bindings:
## a local bound inside a nested block (an `if`/`while`/`for`/`match` body,
## `unsafe`, `defer`, a `when` branch) and a `for`/match-arm binding are absent
## from the snapshot the token classifier reads, so such a reference resolves
## through the plain-value arms instead.  Among the candidates the innermost
## (greatest declaration line at or before `line`) wins, so a later declaration
## shadows an earlier one.
public function binding_kind_at(bindings: vec.Vec[Binding], name: str, line: ptr_uint) -> Option[ptr_uint]:
    var best_line: ptr_uint = 0
    var best_kind: ptr_uint = BINDING_TOPLEVEL
    var found = false
    var bi: ptr_uint = 0
    while bi < bindings.len():
        let bp = bindings.get(bi) else:
            break
        let b = unsafe: read(bp)
        if not b.is_toplevel and b.function_level and b.name.equal(name):
            # The host's snapshot carries a binding only once its declaration
            # statement has completed, so a name used inside its own declaration
            # (an annotation, an initializer on the same line) is not resolved.
            let after_declaration = line > b.line
            if after_declaration and line <= b.scope_end:
                if not found or b.line > best_line:
                    best_line = b.line
                    best_kind = b.kind
                    found = true
        bi += 1
    if not found:
        return Option[ptr_uint].none
    return Option[ptr_uint].some(value = best_kind)

## One declaration's in-scope type parameters: their names and the line range
## over which the declaration carries them (the host's
## `type_parameter_scopes_for_declaration`).
public struct TypeParamScope:
    names: vec.Vec[str]
    start_line: ptr_uint
    end_line: ptr_uint


## Collect the type-parameter scopes of a file's declarations, in document
## order: each declaration's own `[T, U]` clause applies from its line to the
## next declaration's line, and an `extending` block's receiver arguments (its
## `extending Vec[T]` names) apply per method.
public function collect_type_param_scopes(source_text: str, ast_file: ast.SourceFile) -> vec.Vec[TypeParamScope]:
    var scopes = vec.Vec[TypeParamScope].create()
    var i: ptr_uint = 0
    while i < ast_file.declarations.len:
        let region_end = declaration_region_end(ast_file, i, source_text)
        unsafe:
            collect_decl_type_params(ref_of(scopes), ast_file.declarations.data + i, region_end)
        i += 1
    return scopes


function collect_decl_type_params(
    scopes: ref[vec.Vec[TypeParamScope]],
    dp: ptr[ast.Decl],
    region_end: ptr_uint
) -> void:
    var decl: ast.Decl
    unsafe:
        decl = read(dp)
    match decl:
        ast.Decl.decl_extending_block as ex:
            unsafe:
                var mi: ptr_uint = 0
                while mi < ex.methods.len:
                    let method = read(ex.methods.data + mi)
                    var method_end = region_end
                    if mi + 1 < ex.methods.len:
                        method_end = read(ex.methods.data + mi + 1).line - 1
                    var names = vec.Vec[str].create()
                    push_extending_type_param_names(ref_of(names), ex.type_name)
                    push_type_param_names(ref_of(names), method.type_params)
                    if names.len() > 0 and method.line > 0:
                        scopes.push(TypeParamScope(names = names, start_line = method.line, end_line = method_end))
                    else:
                        names.release()
                    mi += 1
        _:
            var names = vec.Vec[str].create()
            push_decl_type_param_names(ref_of(names), decl)
            let line = decl_start_line(decl)
            if names.len() > 0 and line > 0:
                scopes.push(TypeParamScope(names = names, start_line = line, end_line = region_end))
            else:
                names.release()


## The type parameters of a declaration that can carry a `[T, U]` clause.
function push_decl_type_param_names(names: ref[vec.Vec[str]], decl: ast.Decl) -> void:
    match decl:
        ast.Decl.decl_function as d:
            push_type_param_names(names, d.type_params)
        ast.Decl.decl_struct as d:
            push_type_param_names(names, d.type_params)
        ast.Decl.decl_variant as d:
            push_type_param_names(names, d.type_params)
        ast.Decl.decl_interface as d:
            push_type_param_names(names, d.type_params)
        ast.Decl.decl_extern_function as d:
            push_type_param_names(names, d.type_params)
        ast.Decl.decl_foreign_function as d:
            push_type_param_names(names, d.type_params)
        _:
            pass


function push_type_param_names(names: ref[vec.Vec[str]], params: span[ast.TypeParam]) -> void:
    var i: ptr_uint = 0
    while i < params.len:
        unsafe:
            names.push(read(params.data + i).name)
        i += 1


## An `extending Vec[T]` receiver's argument names, so the block's methods see
## `T` (the host's `generic_type_parameter_names_for_extending_block`: only a
## bare single-part argument counts).
function push_extending_type_param_names(names: ref[vec.Vec[str]], type_name: ptr[ast.TypeRef]) -> void:
    unsafe:
        let args = read(type_name).arguments
        var i: ptr_uint = 0
        while i < args.len:
            let arg = read(args.data + i)
            if arg.arguments.len == 0 and not arg.nullable and arg.name.parts.len == 1:
                names.push(read(arg.name.parts.data))
            i += 1
