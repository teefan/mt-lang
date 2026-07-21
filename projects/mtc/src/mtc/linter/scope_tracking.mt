## Scope-tracking lint pass for the self-hosted mtc compiler.
##
## Separate AST traversal that emits scope-based warnings:
##   unused-local, unused-param, shadow, prefer-let, unused-import
##
## IMPORTANT: all scope entries are stored in a raw byte buffer on the
## stack of lint_scope_pass, accessed exclusively through unsafe pointer
## arithmetic.  This avoids the self-host C-backend bug where
## `array[T,N]` inside a struct passed through a `ref[ScopeCtx]` is
## lowered as a zero-length array.

import std.vec as vec
import std.string as string
import std.str

import mtc.parser.ast as ast


public struct ScopeWarning:
    path: str
    line: ptr_uint
    column: ptr_uint
    code: str
    message: str
    severity: str


const BINDING_LOCAL: ptr_uint = 0
const BINDING_PARAM: ptr_uint = 1
const MAX_SCOPES: ptr_uint = 32
const MAX_ENTRIES: ptr_uint = 128

struct Binding:
    name: str
    line: ptr_uint
    column: ptr_uint
    used: bool
    binding_kind: ptr_uint
    allow_prefer_let: bool
    mutated: bool

struct ScopeEntry:
    name: str
    binding: Binding

## Minimal struct.  All scope data lives in the external byte buffer;
## the ctx only stores counters and a pointer to that buffer.
struct ScopeCtx:
    buf: ptr[ScopeEntry]
    scope_starts: array[ptr_uint, 32]
    scope_counts: array[ptr_uint, 32]
    scope_count: ptr_uint
    generic_function_depth: ptr_uint
    match_arm_depth: ptr_uint


# =============================================================================
#  Warning helpers
# =============================================================================

function push_w(warnings: ref[vec.Vec[ScopeWarning]], path: str, line: ptr_uint, column: ptr_uint, code: str, msg: str, sev: str) -> void:
    warnings.push(ScopeWarning(path = path, line = line, column = column, code = code, message = msg, severity = sev))


function warn_shadow(warnings: ref[vec.Vec[ScopeWarning]], path: str, name: str, line: ptr_uint, column: ptr_uint) -> void:
    var buf = string.String.create()
    buf.append("local '")
    buf.append(name)
    buf.append("' shadows a binding from an outer scope")
    push_w(warnings, path, line, column, "shadow", buf.as_str(), "warning")


function warn_unused(warnings: ref[vec.Vec[ScopeWarning]], path: str, code: str, kind: str, name: str, line: ptr_uint, column: ptr_uint) -> void:
    var buf = string.String.create()
    buf.append("unused ")
    buf.append(kind)
    buf.append(" '")
    buf.append(name)
    buf.append("'")
    push_w(warnings, path, line, column, code, buf.as_str(), "warning")


function warn_prefer_let(warnings: ref[vec.Vec[ScopeWarning]], path: str, name: str, line: ptr_uint, column: ptr_uint) -> void:
    var buf = string.String.create()
    buf.append("variable '")
    buf.append(name)
    buf.append("' is never reassigned, prefer 'let'")
    push_w(warnings, path, line, column, "prefer-let", buf.as_str(), "hint")


function warn_unused_import(warnings: ref[vec.Vec[ScopeWarning]], path: str, name: str, line: ptr_uint, column: ptr_uint) -> void:
    var buf = string.String.create()
    buf.append("unused import '")
    buf.append(name)
    buf.append("'")
    push_w(warnings, path, line, column, "unused-import", buf.as_str(), "hint")


# =============================================================================
#  Scope helpers — all access through ctx.buf + pointer arithmetic
# =============================================================================

function ctx_init(ctx: ref[ScopeCtx], buf: ptr[ScopeEntry]) -> void:
    read(ctx).buf = buf
    read(ctx).scope_count = 0
    read(ctx).generic_function_depth = 0


function ctx_push_scope(ctx: ref[ScopeCtx]) -> void:
    let c = unsafe: read(ctx)
    if c.scope_count >= 32:
        fatal(c"scope tracking overflow in lint pass")
    let si = c.scope_count
    read(ctx).scope_starts[si] = si * 16
    read(ctx).scope_counts[si] = 0
    read(ctx).scope_count = si + 1


function ctx_pop_scope(ctx: ref[ScopeCtx], path: str, warnings: ref[vec.Vec[ScopeWarning]]) -> void:
    let c = unsafe: read(ctx)
    if c.scope_count == 0:
        return
    let idx = c.scope_count - 1
    emit_scope_flat(path, warnings, c.buf, c.scope_starts[idx], c.scope_counts[idx])
    read(ctx).scope_count = idx


function ctx_declare_local(ctx: ref[ScopeCtx], name: str, line: ptr_uint, col: ptr_uint, is_var: bool, path: str, warnings: ref[vec.Vec[ScopeWarning]]) -> void:
    let c = unsafe: read(ctx)
    if c.scope_count == 0:
        return
    if c.scope_count > 1 and c.match_arm_depth == 0:
        var si: ptr_uint = 0
        while si < c.scope_count - 1:
            unsafe:
                if scope_has_name_buf(c.buf, c.scope_starts[si], c.scope_counts[si], name):
                    warn_shadow(warnings, path, name, line, col)
                    break
            si += 1

    let allow = is_var and c.generic_function_depth == 0
    let bd = Binding(name = name, line = line, column = col, used = false, binding_kind = BINDING_LOCAL, allow_prefer_let = allow, mutated = false)
    unsafe:
        scope_add_entry_buf(c.buf, c.scope_starts[c.scope_count - 1], c.scope_counts[c.scope_count - 1], name, bd)
    read(ctx).scope_counts[c.scope_count - 1] = c.scope_counts[c.scope_count - 1] + 1


function ctx_declare_param(ctx: ref[ScopeCtx], name: str, line: ptr_uint, col: ptr_uint) -> void:
    let c = unsafe: read(ctx)
    let bd = Binding(name = name, line = line, column = col, used = false, binding_kind = BINDING_PARAM, allow_prefer_let = false, mutated = false)
    unsafe:
        scope_add_entry_buf(c.buf, c.scope_starts[c.scope_count - 1], c.scope_counts[c.scope_count - 1], name, bd)
    read(ctx).scope_counts[c.scope_count - 1] = c.scope_counts[c.scope_count - 1] + 1


function ctx_mark_used(ctx: ref[ScopeCtx], name: str) -> void:
    let c = unsafe: read(ctx)
    var si = c.scope_count
    while si > 0:
        si -= 1
        unsafe:
            match scope_find_entry_buf(c.buf, c.scope_starts[si], c.scope_counts[si], name):
                Option.some as idx:
                    read(c.buf + c.scope_starts[si] + idx.value).binding.used = true
                    return
                Option.none:
                    pass


function ctx_mark_mutated(ctx: ref[ScopeCtx], target: ptr[ast.Expr]) -> void:
    unsafe:
        match read(target):
            ast.Expr.expr_identifier as id:
                let c = read(ctx)
                var si = c.scope_count
                while si > 0:
                    si -= 1
                    match scope_find_entry_buf(c.buf, c.scope_starts[si], c.scope_counts[si], id.name):
                        Option.some as idx:
                            read(c.buf + c.scope_starts[si] + idx.value).binding.mutated = true
                            return
                        Option.none:
                            pass
            _:
                pass


function scope_add_entry_buf(buf: ptr[ScopeEntry], start: ptr_uint, count: ptr_uint, name: str, bd: Binding) -> void:
    if count >= MAX_ENTRIES:
        return
    unsafe:
        read(buf + start + count) = ScopeEntry(name = name, binding = bd)


function scope_find_entry_buf(buf: ptr[ScopeEntry], start: ptr_uint, count: ptr_uint, name: str) -> Option[ptr_uint]:
    var i: ptr_uint = 0
    while i < count:
        unsafe:
            if read(buf + start + i).name.equal(name):
                return Option[ptr_uint].some(value = i)
        i += 1
    return Option[ptr_uint].none


function scope_has_name_buf(buf: ptr[ScopeEntry], start: ptr_uint, count: ptr_uint, name: str) -> bool:
    var i: ptr_uint = 0
    while i < count:
        unsafe:
            if read(buf + start + i).name.equal(name):
                return true
        i += 1
    return false


function emit_scope_flat(path: str, warnings: ref[vec.Vec[ScopeWarning]], buf: ptr[ScopeEntry], start: ptr_uint, count: ptr_uint) -> void:
    var i: ptr_uint = 0
    while i < count:
        unsafe:
            let bd = read(buf + start + i).binding
            if not bd.used and bd.name.len > 0 and not bd.name.starts_with("_"):
                let code = if bd.binding_kind == BINDING_PARAM: "unused-param" else: "unused-local"
                let kind = if bd.binding_kind == BINDING_PARAM: "parameter" else: "local"
                warn_unused(warnings, path, code, kind, bd.name, bd.line, bd.column)
            else:
                if bd.allow_prefer_let and not bd.mutated:
                    warn_prefer_let(warnings, path, bd.name, bd.line, bd.column)
        i += 1


# =============================================================================
#  Pass entry point
# =============================================================================

public function lint_scope_pass(file: ast.SourceFile, path: str, warnings: ref[vec.Vec[ScopeWarning]]) -> void:
    var entries_buf: array[ScopeEntry, 4096]
    var sc: ScopeCtx
    ctx_init(ref_of(sc), ptr_of(entries_buf[0]))
    check_unused_imports(file, path, warnings)
    var i: ptr_uint = 0
    while i < file.declarations.len:
        unsafe:
            visit_decl(file.declarations.data + i, path, warnings, ref_of(sc))
        i += 1
    read(ref_of(sc)).scope_count = 0


# =============================================================================
#  unused-import
# =============================================================================

function check_unused_imports(file: ast.SourceFile, path: str, warnings: ref[vec.Vec[ScopeWarning]]) -> void:
    var i: ptr_uint = 0
    while i < file.imports.len:
        unsafe:
            match read(file.imports.data + i):
                ast.Decl.decl_import as im:
                    let parts = im.path.parts
                    var ln: str = ""
                    match im.alias_name:
                        Option.some as an:
                            ln = an.value
                        Option.none:
                            ln = read(parts.data + parts.len - 1)
                    var used = false
                    var j: ptr_uint = 0
                    while j < file.declarations.len:
                        if decl_uses_name(file.declarations.data + j, ln):
                            used = true
                            break
                        j += 1
                    if not used:
                        warn_unused_import(warnings, path, ln, im.line, im.column)
                _:
                    pass
        i += 1


function decl_uses_name(decl: ptr[ast.Decl], name: str) -> bool:
    unsafe:
        match read(decl):
            ast.Decl.decl_function as fun:
                return body_uses_name(fun.body, name)
            ast.Decl.decl_extending_block as ex:
                var j: ptr_uint = 0
                while j < ex.methods.len:
                    if body_uses_name(read(ex.methods.data + j).body, name):
                        return true
                    j += 1
                return false
            _:
                return false


function body_uses_name(body: ptr[ast.Stmt]?, name: str) -> bool:
    let bp = body else:
        return false
    unsafe:
        match read(bp):
            ast.Stmt.stmt_block as blk:
                return stmts_use_name(blk.statements, name)
            _:
                return stmt_contains_name(bp, name)


function stmts_use_name(stmts: span[ast.Stmt], name: str) -> bool:
    var i: ptr_uint = 0
    while i < stmts.len:
        unsafe:
            if stmt_contains_name(stmts.data + i, name):
                return true
        i += 1
    return false


function stmt_contains_name(stmt: ptr[ast.Stmt], name: str) -> bool:
    unsafe:
        match read(stmt):
            ast.Stmt.stmt_block as blk:
                return stmts_use_name(blk.statements, name)
            ast.Stmt.stmt_assignment as asgn:
                if expr_contains_name(asgn.target, name):
                    return true
                return expr_contains_name(asgn.value, name)
            ast.Stmt.stmt_if as iff:
                var bi: ptr_uint = 0
                while bi < iff.branches.len:
                    let br = read(iff.branches.data + bi)
                    if expr_contains_name(br.condition, name):
                        return true
                    if body_uses_name(br.body, name):
                        return true
                    bi += 1
                return body_uses_name(iff.else_body, name)
            ast.Stmt.stmt_while as wh:
                if expr_contains_name(wh.condition, name):
                    return true
                return body_uses_name(wh.body, name)
            ast.Stmt.stmt_for as fr:
                var ii: ptr_uint = 0
                while ii < fr.iterables.len:
                    if expr_contains_name(fr.iterables.data + ii, name):
                        return true
                    ii += 1
                return body_uses_name(fr.body, name)
            ast.Stmt.stmt_match as mt:
                if expr_contains_name(mt.scrutinee, name):
                    return true
                var ai: ptr_uint = 0
                while ai < mt.arms.len:
                    if body_uses_name(read(mt.arms.data + ai).body, name):
                        return true
                    ai += 1
                return false
            ast.Stmt.stmt_ret as r:
                return expr_opt_contains_name(r.value, name)
            ast.Stmt.stmt_expression as ex:
                return expr_contains_name(ex.expression, name)
            ast.Stmt.stmt_unsafe as un:
                return body_uses_name(un.body, name)
            _:
                return false


function expr_opt_contains_name(expr: ptr[ast.Expr]?, name: str) -> bool:
    let ep = expr else:
        return false
    return expr_contains_name(ep, name)


function expr_contains_name(expr: ptr[ast.Expr], name: str) -> bool:
    unsafe:
        match read(expr):
            ast.Expr.expr_identifier as id:
                return id.name.equal(name)
            ast.Expr.expr_binary_op as b:
                if expr_contains_name(b.left, name):
                    return true
                return expr_contains_name(b.right, name)
            ast.Expr.expr_unary_op as u:
                return expr_contains_name(u.operand, name)
            ast.Expr.expr_member_access as m:
                return expr_contains_name(m.receiver, name)
            ast.Expr.expr_call as call:
                if expr_contains_name(call.callee, name):
                    return true
                var i: ptr_uint = 0
                while i < call.args.len:
                    if expr_contains_name(read(call.args.data + i).arg_value, name):
                        return true
                    i += 1
                return false
            ast.Expr.expr_index_access as ix:
                if expr_contains_name(ix.receiver, name):
                    return true
                return expr_contains_name(ix.index, name)
            ast.Expr.expr_specialization as sp:
                return expr_contains_name(sp.callee, name)
            ast.Expr.expr_if as iff:
                if expr_contains_name(iff.condition, name):
                    return true
                if expr_contains_name(iff.then_expr, name):
                    return true
                return expr_contains_name(iff.else_expr, name)
            ast.Expr.expr_await as aw:
                return expr_contains_name(aw.expression, name)
            ast.Expr.expr_detach as dt:
                return expr_contains_name(dt.expression, name)
            ast.Expr.expr_named as nm:
                return expr_contains_name(nm.value, name)
            ast.Expr.expr_prefix_cast as pc:
                return expr_contains_name(pc.expression, name)
            ast.Expr.expr_unsafe as us:
                return expr_contains_name(us.expression, name)
            _:
                return false


# =============================================================================
#  AST visitors
# =============================================================================

function visit_decl(decl: ptr[ast.Decl], path: str, warnings: ref[vec.Vec[ScopeWarning]], ctx: ref[ScopeCtx]) -> void:
    unsafe:
        match read(decl):
            ast.Decl.decl_function as fun:
                ctx_push_scope(ctx)
                var pi: ptr_uint = 0
                while pi < fun.method_params.len:
                    let p = read(fun.method_params.data + pi)
                    ctx_declare_param(ctx, p.name, p.line, p.column)
                    pi += 1
                visit_stmt_opt(fun.body, path, warnings, ctx)
                ctx_pop_scope(ctx, path, warnings)
            ast.Decl.decl_extending_block as ex:
                var j: ptr_uint = 0
                while j < ex.methods.len:
                    ctx_push_scope(ctx)
                    let m = read(ex.methods.data + j)
                    var pi: ptr_uint = 0
                    while pi < m.method_params.len:
                        let p = read(m.method_params.data + pi)
                        ctx_declare_param(ctx, p.name, p.line, p.column)
                        pi += 1
                    visit_stmt(m.body, path, warnings, ctx)
                    ctx_pop_scope(ctx, path, warnings)
                    j += 1
            ast.Decl.decl_when as w:
                var bi: ptr_uint = 0
                while bi < w.branches.len:
                    let br = read(w.branches.data + bi)
                    var si: ptr_uint = 0
                    while si < br.body.len:
                        visit_decl(br.body.data + si, path, warnings, ctx)
                        si += 1
                    bi += 1
            _:
                pass


function visit_stmt_opt(stmt: ptr[ast.Stmt]?, path: str, warnings: ref[vec.Vec[ScopeWarning]], ctx: ref[ScopeCtx]) -> void:
    let sp = stmt else:
        return
    visit_stmt(sp, path, warnings, ctx)


function visit_stmt(stmt: ptr[ast.Stmt], path: str, warnings: ref[vec.Vec[ScopeWarning]], ctx: ref[ScopeCtx]) -> void:
    unsafe:
        match read(stmt):
            ast.Stmt.stmt_block as blk:
                var i: ptr_uint = 0
                while i < blk.statements.len:
                    visit_stmt(blk.statements.data + i, path, warnings, ctx)
                    i += 1
            ast.Stmt.stmt_local as loc:
                visit_expr_opt(loc.value, path, warnings, ctx)
                if loc.name.len > 0:
                    ctx_declare_local(ctx, loc.name, loc.line, loc.column, not loc.is_let, path, warnings)
                match loc.destructure_bindings:
                    Option.some as bindings:
                        var di: ptr_uint = 0
                        while di < bindings.value.len:
                            let dname = unsafe: read(bindings.value.data + di)
                            if dname.len > 0:
                                ctx_declare_local(ctx, dname, loc.line, loc.column, not loc.is_let, path, warnings)
                            di += 1
                    Option.none:
                        pass
                visit_stmt_opt(loc.else_body, path, warnings, ctx)
            ast.Stmt.stmt_assignment as asgn:
                visit_expr(asgn.value, path, warnings, ctx)
                visit_expr(asgn.target, path, warnings, ctx)
                ctx_mark_mutated(ctx, asgn.target)
            ast.Stmt.stmt_if as iff:
                var bi: ptr_uint = 0
                while bi < iff.branches.len:
                    let br = read(iff.branches.data + bi)
                    visit_expr(br.condition, path, warnings, ctx)
                    ctx_push_scope(ctx)
                    visit_stmt(br.body, path, warnings, ctx)
                    ctx_pop_scope(ctx, path, warnings)
                    bi += 1
                if iff.else_body != null:
                    ctx_push_scope(ctx)
                    visit_stmt_opt(iff.else_body, path, warnings, ctx)
                    ctx_pop_scope(ctx, path, warnings)
            ast.Stmt.stmt_while as wh:
                visit_expr(wh.condition, path, warnings, ctx)
                ctx_push_scope(ctx)
                visit_stmt_opt(wh.body, path, warnings, ctx)
                ctx_pop_scope(ctx, path, warnings)
            ast.Stmt.stmt_for as fr:
                var ii: ptr_uint = 0
                while ii < fr.iterables.len:
                    visit_expr(fr.iterables.data + ii, path, warnings, ctx)
                    ii += 1
                ctx_push_scope(ctx)
                var bi: ptr_uint = 0
                while bi < fr.bindings.len:
                    let b = read(fr.bindings.data + bi)
                    ctx_declare_local(ctx, b.name, b.line, b.column, false, path, warnings)
                    bi += 1
                visit_stmt_opt(fr.body, path, warnings, ctx)
                ctx_pop_scope(ctx, path, warnings)
            ast.Stmt.stmt_match as mt:
                visit_expr(mt.scrutinee, path, warnings, ctx)
                var ai: ptr_uint = 0
                var saved_depth = unsafe: read(ctx).match_arm_depth
                unsafe: read(ctx).match_arm_depth = 1
                while ai < mt.arms.len:
                    let arm = read(mt.arms.data + ai)
                    ctx_push_scope(ctx)
                    match arm.binding_name:
                        Option.some as bn:
                            ctx_declare_local(ctx, bn.value, arm.binding_line, arm.binding_column, false, path, warnings)
                        Option.none:
                            pass
                    visit_stmt_opt(arm.body, path, warnings, ctx)
                    ctx_pop_scope(ctx, path, warnings)
                    ai += 1
                unsafe: read(ctx).match_arm_depth = saved_depth
            ast.Stmt.stmt_ret as r:
                visit_expr_opt(r.value, path, warnings, ctx)
            ast.Stmt.stmt_defer as df:
                visit_expr_opt(df.expression, path, warnings, ctx)
                ctx_push_scope(ctx)
                visit_stmt_opt(df.body, path, warnings, ctx)
                ctx_pop_scope(ctx, path, warnings)
            ast.Stmt.stmt_unsafe as un:
                ctx_push_scope(ctx)
                visit_stmt_opt(un.body, path, warnings, ctx)
                ctx_pop_scope(ctx, path, warnings)
            ast.Stmt.stmt_expression as ex:
                visit_expr(ex.expression, path, warnings, ctx)
            ast.Stmt.stmt_static_assert as sa:
                visit_expr(sa.condition, path, warnings, ctx)
                visit_expr_opt(sa.message, path, warnings, ctx)
            ast.Stmt.stmt_when as wn:
                visit_expr(wn.discriminant, path, warnings, ctx)
                var wbi: ptr_uint = 0
                while wbi < wn.branches.len:
                    let br = read(wn.branches.data + wbi)
                    ctx_push_scope(ctx)
                    var wsi: ptr_uint = 0
                    while wsi < br.body.len:
                        visit_stmt(br.body.data + wsi, path, warnings, ctx)
                        wsi += 1
                    ctx_pop_scope(ctx, path, warnings)
                    wbi += 1
                if wn.else_body != null:
                    ctx_push_scope(ctx)
                    visit_stmt_opt(wn.else_body, path, warnings, ctx)
                    ctx_pop_scope(ctx, path, warnings)
            ast.Stmt.stmt_gather as g:
                var gi: ptr_uint = 0
                while gi < g.handles.len:
                    visit_expr(g.handles.data + gi, path, warnings, ctx)
                    gi += 1
            _:
                pass


function visit_expr_opt(expr: ptr[ast.Expr]?, path: str, warnings: ref[vec.Vec[ScopeWarning]], ctx: ref[ScopeCtx]) -> void:
    let ep = expr else:
        return
    visit_expr(ep, path, warnings, ctx)


function visit_expr(expr: ptr[ast.Expr], path: str, warnings: ref[vec.Vec[ScopeWarning]], ctx: ref[ScopeCtx]) -> void:
    unsafe:
        match read(expr):
            ast.Expr.expr_identifier as id:
                ctx_mark_used(ctx, id.name)
            ast.Expr.expr_binary_op as b:
                visit_expr(b.left, path, warnings, ctx)
                visit_expr(b.right, path, warnings, ctx)
            ast.Expr.expr_unary_op as u:
                visit_expr(u.operand, path, warnings, ctx)
            ast.Expr.expr_member_access as m:
                visit_expr(m.receiver, path, warnings, ctx)
            ast.Expr.expr_call as call:
                visit_expr(call.callee, path, warnings, ctx)
                var i: ptr_uint = 0
                while i < call.args.len:
                    visit_expr(read(call.args.data + i).arg_value, path, warnings, ctx)
                    i += 1
            ast.Expr.expr_index_access as ix:
                visit_expr(ix.receiver, path, warnings, ctx)
                visit_expr(ix.index, path, warnings, ctx)
            ast.Expr.expr_specialization as sp:
                visit_expr(sp.callee, path, warnings, ctx)
            ast.Expr.expr_if as iff:
                visit_expr(iff.condition, path, warnings, ctx)
                visit_expr(iff.then_expr, path, warnings, ctx)
                visit_expr(iff.else_expr, path, warnings, ctx)
            ast.Expr.expr_match as mm:
                visit_expr(mm.scrutinee, path, warnings, ctx)
                var ai: ptr_uint = 0
                while ai < mm.arms.len:
                    let arm = read(mm.arms.data + ai)
                    ctx_push_scope(ctx)
                    match arm.binding_name:
                        Option.some as bn:
                            ctx_declare_local(ctx, bn.value, arm.binding_line, arm.binding_column, false, path, warnings)
                        Option.none:
                            pass
                    visit_expr(arm.value, path, warnings, ctx)
                    ctx_pop_scope(ctx, path, warnings)
                    ai += 1
            ast.Expr.expr_proc as pr:
                ctx_push_scope(ctx)
                var pi: ptr_uint = 0
                while pi < pr.method_params.len:
                    let p = read(pr.method_params.data + pi)
                    ctx_declare_param(ctx, p.name, p.line, p.column)
                    pi += 1
                visit_stmt(pr.body, path, warnings, ctx)
                ctx_pop_scope(ctx, path, warnings)
            ast.Expr.expr_await as aw:
                visit_expr(aw.expression, path, warnings, ctx)
            ast.Expr.expr_detach as dt:
                visit_expr(dt.expression, path, warnings, ctx)
            ast.Expr.expr_named as nm:
                visit_expr(nm.value, path, warnings, ctx)
            ast.Expr.expr_range as rg:
                visit_expr(rg.start_expr, path, warnings, ctx)
                visit_expr(rg.end_expr, path, warnings, ctx)
            ast.Expr.expr_prefix_cast as pc:
                visit_expr(pc.expression, path, warnings, ctx)
            ast.Expr.expr_unsafe as us:
                visit_expr(us.expression, path, warnings, ctx)
            ast.Expr.expr_expression_list as el:
                var ei: ptr_uint = 0
                while ei < el.elements.len:
                    visit_expr(el.elements.data + ei, path, warnings, ctx)
                    ei += 1
            ast.Expr.expr_format_string as fs:
                var pi: ptr_uint = 0
                while pi < fs.parts.len:
                    match read(fs.parts.data + pi):
                        ast.FormatStringPart.fmt_expr as fe:
                            visit_expr(fe.expression, path, warnings, ctx)
                        _:
                            pass
                    pi += 1
            _:
                pass
