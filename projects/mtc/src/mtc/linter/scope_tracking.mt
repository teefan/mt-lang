## Scope state for the self-hosted mtc compiler's lint walk.
##
## The linter's own traversal (`linter.mt`'s `visit_decl`/`visit_stmt`/
## `visit_expr`) drives this state machine so the scope-based warnings
## (`unused-local`, `unused-param`, `shadow`, `prefer-let`, `prefer-own-ptr`)
## interleave with the rule warnings in the host's emission order; the scope
## declarations also drive the rules that read bindings (`unused-import`
## credits, `prefer-let`'s mutation tracking).
##
## IMPORTANT: all scope entries are stored in a raw byte buffer owned by the
## linter's `lint_source_with`, accessed exclusively through unsafe pointer
## arithmetic.  This avoids the self-host C-backend bug where
## `array[T,N]` inside a struct passed through a `ref[ScopeContext]` is
## lowered as a zero-length array.

import std.vec as vec
import std.string as string
import std.str
import std.map as map_mod

import mtc.parser.ast as ast
import mtc.semantic.analyzer as analyzer
import mtc.semantic.types as types


public struct ScopeWarning:
    path: str
    line: ptr_uint
    column: ptr_uint
    ## The binding name's length: the host's scope warnings span the name.
    length: ptr_uint
    code: str
    message: str
    severity: str


public const BINDING_LOCAL: ptr_uint = 0
public const BINDING_PARAM: ptr_uint = 1
const MAX_SCOPES: ptr_uint = 32
const MAX_ENTRIES: ptr_uint = 128
## One MAX_ENTRIES window per scope, for the 32 scopes the ctx supports.
public const SCOPE_WINDOW_TOTAL: ptr_uint = 32 * MAX_ENTRIES

public struct Binding:
    name: str
    line: ptr_uint
    column: ptr_uint
    used: bool
    binding_kind: ptr_uint
    allow_prefer_let: bool
    mutated: bool
    ## 1 + the index of this binding's `reserved-primitive-name` fix, or 0 when
    ## it has none (the host's `binding.fix_index`): an identifier that
    ## resolves to this binding records a rename site.
    reserved_fix: ptr_uint

public struct ScopeEntry:
    name: str
    binding: Binding

## Minimal struct.  All scope data lives in the external byte buffer;
## the ctx only stores counters and a pointer to that buffer.
public struct ScopeContext:
    buf: ptr[ScopeEntry]
    scope_starts: array[ptr_uint, MAX_SCOPES]
    scope_counts: array[ptr_uint, MAX_SCOPES]
    scope_count: ptr_uint
    generic_function_depth: ptr_uint
    match_arm_depth: ptr_uint
    ## Receivers of `editable` method calls, recorded by the analyzer: a call on
    ## one of them mutates the binding, so prefer-let must not fire.
    editable_sites: span[analyzer.EditableSite]
    ## Identifier arguments passed to `out`/`inout` foreign parameters
    ## (recorded by the analyzer): the call mutates them, so prefer-let must
    ## not fire.
    mutating_sites: span[analyzer.EditableSite]
    ## Identifier arguments recorded by the array/`str_buffer`→`span` coercion
    ## (the host's `mutable_lvalue_argument_identifier_ids`): the callee may
    ## write through the alias, so prefer-let must not fire on them either.
    mutable_lvalue_sites: span[analyzer.EditableSite]


# =============================================================================
#  Warning helpers
# =============================================================================

function push_w(warnings: ref[vec.Vec[ScopeWarning]], path: str, line: ptr_uint, column: ptr_uint, length: ptr_uint, code: str, msg: str, sev: str) -> void:
    warnings.push(ScopeWarning(path = path, line = line, column = column, length = length, code = code, message = msg, severity = sev))


function warn_unused_import(warnings: ref[vec.Vec[ScopeWarning]], path: str, name: str, line: ptr_uint, column: ptr_uint) -> void:
    var buf = string.String.create()
    buf.append("unused import '")
    buf.append(name)
    buf.append("'")
    push_w(warnings, path, line, column, name.len, "unused-import", buf.as_str(), "warning")


# =============================================================================
#  Scope helpers — all access through ctx.buf + pointer arithmetic
# =============================================================================

public function ctx_init(ctx: ref[ScopeContext], buf: ptr[ScopeEntry]) -> void:
    read(ctx).buf = buf
    read(ctx).scope_count = 0
    read(ctx).generic_function_depth = 0
    read(ctx).editable_sites = span[analyzer.EditableSite]()
    read(ctx).mutating_sites = span[analyzer.EditableSite]()
    read(ctx).mutable_lvalue_sites = span[analyzer.EditableSite]()


public function ctx_set_generic_depth(ctx: ref[ScopeContext], depth: ptr_uint) -> void:
    read(ctx).generic_function_depth = depth


public function ctx_set_match_arm_depth(ctx: ref[ScopeContext], depth: ptr_uint) -> void:
    read(ctx).match_arm_depth = depth


public function ctx_push_scope(ctx: ref[ScopeContext]) -> void:
    let c = unsafe: read(ctx)
    if c.scope_count >= MAX_SCOPES:
        fatal(c"scope tracking overflow in lint pass")
    # Every scope owns a MAX_ENTRIES-wide window: a scope holding more than a
    # dozen locals must not spill into the next scope's window (that made a
    # sibling block's bindings look like outer ones and reported `shadow`).
    let si = c.scope_count
    read(ctx).scope_starts[si] = si * MAX_ENTRIES
    read(ctx).scope_counts[si] = 0
    read(ctx).scope_count = si + 1


## Drop the innermost scope and return its index (the caller emits its
## warnings), or `SCOPE_NONE` when no scope is open.
public const SCOPE_NONE: ptr_uint = 4294967295

public function ctx_pop_scope(ctx: ref[ScopeContext]) -> ptr_uint:
    let c = unsafe: read(ctx)
    if c.scope_count == 0:
        return SCOPE_NONE
    let idx = c.scope_count - 1
    read(ctx).scope_count = idx
    return idx


## The host's `declare_local` shadow check: any *outer* scope (not the
## innermost) already holds the name.  A match arm's scope is an outer scope
## like any other, so an arm binding or a local in an arm body reports shadow
## the same way.
## True means the caller emits `shadow` for the declaration.
public function ctx_shadows_outer(ctx: ref[ScopeContext], name: str) -> bool:
    let c = unsafe: read(ctx)
    if c.scope_count <= 1:
        return false
    var si: ptr_uint = 0
    while si < c.scope_count - 1:
        unsafe:
            if scope_has_name_buf(c.buf, c.scope_starts[si], c.scope_counts[si], name):
                return true
        si += 1
    return false


## The scope's entries, for the caller's warning emission (the host's
## `emit_scope_warnings` loop over `scope.each_value`).
public function ctx_scope_start(ctx: ref[ScopeContext], idx: ptr_uint) -> ptr_uint:
    return unsafe: read(ctx).scope_starts[idx]


public function ctx_scope_count(ctx: ref[ScopeContext], idx: ptr_uint) -> ptr_uint:
    return unsafe: read(ctx).scope_counts[idx]


public function ctx_entry(ctx: ref[ScopeContext], start: ptr_uint, offset: ptr_uint) -> Binding:
    return unsafe: read(read(ctx).buf + start + offset).binding


## The host's `prefer_var_else_binding_mutated?`: the innermost open scope's
## binding for `name` was marked mutated.  A binding declared in an already
## popped nested scope is not found, so its `var ... else` is not reported — the
## host looks only at `@scopes.last` too.
public function ctx_binding_mutated(ctx: ref[ScopeContext], name: str) -> bool:
    let c = unsafe: read(ctx)
    if c.scope_count == 0:
        return false
    let si = c.scope_count - 1
    let start = c.scope_starts[si]
    let count = c.scope_counts[si]
    var i: ptr_uint = 0
    while i < count:
        unsafe:
            let entry = read(c.buf + start + i)
            if entry.name.equal(name):
                return entry.binding.mutated
        i += 1
    return false


## The host's `declare_local`: ignored names (`_`-prefixed) never enter a
## scope, so they draw no shadow/unused-local/prefer-let.
public function ctx_declare_local(ctx: ref[ScopeContext], name: str, line: ptr_uint, col: ptr_uint, is_var: bool, reserved_fix: ptr_uint) -> void:
    let c = unsafe: read(ctx)
    if c.scope_count == 0 or name.len == 0:
        return
    if name.starts_with("_"):
        return
    let allow = is_var and c.generic_function_depth == 0
    let bd = Binding(name = name, line = line, column = col, used = false, binding_kind = BINDING_LOCAL, allow_prefer_let = allow, mutated = false, reserved_fix = reserved_fix)
    unsafe:
        scope_add_entry_buf(c.buf, c.scope_starts[c.scope_count - 1], c.scope_counts[c.scope_count - 1], name, bd)
    read(ctx).scope_counts[c.scope_count - 1] = c.scope_counts[c.scope_count - 1] + 1


public function ctx_declare_param(ctx: ref[ScopeContext], name: str, line: ptr_uint, col: ptr_uint, reserved_fix: ptr_uint) -> void:
    if name.len == 0 or name.starts_with("_"):
        return
    let c = unsafe: read(ctx)
    let bd = Binding(name = name, line = line, column = col, used = false, binding_kind = BINDING_PARAM, allow_prefer_let = false, mutated = false, reserved_fix = reserved_fix)
    unsafe:
        scope_add_entry_buf(c.buf, c.scope_starts[c.scope_count - 1], c.scope_counts[c.scope_count - 1], name, bd)
    read(ctx).scope_counts[c.scope_count - 1] = c.scope_counts[c.scope_count - 1] + 1


## Mark the innermost binding named `name` used and return 0 when no local
## matches, 1 when it matches without a reserved-name fix, or 2 + the fix's
## index when it has one.
public function ctx_mark_used(ctx: ref[ScopeContext], name: str) -> ptr_uint:
    let c = unsafe: read(ctx)
    var si = c.scope_count
    while si > 0:
        si -= 1
        unsafe:
            match scope_find_entry_buf(c.buf, c.scope_starts[si], c.scope_counts[si], name):
                Option.some as idx:
                    read(c.buf + c.scope_starts[si] + idx.value).binding.used = true
                    let reserved_fix = read(c.buf + c.scope_starts[si] + idx.value).binding.reserved_fix
                    if reserved_fix == 0:
                        return 1
                    return reserved_fix + 1
                Option.none:
                    pass
    return 0


public function visit_typeref(tr: ptr[ast.TypeRef], ctx: ref[ScopeContext]) -> void:
    unsafe:
        let r = read(tr)
        var pi: ptr_uint = 0
        while pi < r.name.parts.len:
            ctx_mark_used(ctx, read(r.name.parts.data + pi))
            pi += 1
        var ai: ptr_uint = 0
        while ai < r.arguments.len:
            visit_typeref(r.arguments.data + ai, ctx)
            ai += 1


function visit_typeref_opt(tr: ptr[ast.TypeRef]?, ctx: ref[ScopeContext]) -> void:
    if tr != null:
        visit_typeref(tr, ctx)


public function ctx_mark_mutated(ctx: ref[ScopeContext], target: ptr[ast.Expr]) -> void:
    unsafe:
        match read(target):
            ast.Expr.expr_identifier as id:
                var c = read(ctx)
                var si = c.scope_count
                while si > 0:
                    si -= 1
                    match scope_find_entry_buf(c.buf, c.scope_starts[si], c.scope_counts[si], id.name):
                        Option.some as idx:
                            read(c.buf + c.scope_starts[si] + idx.value).binding.mutated = true
                            return
                        Option.none:
                            pass
            ast.Expr.expr_index_access as ia:
                ctx_mark_mutated(ctx, ia.receiver)
            ast.Expr.expr_member_access as ma:
                ctx_mark_mutated(ctx, ma.receiver)
            _:
                pass


## Mark a binding mutated when the call is an `editable` method call on it:
## `var s = Stack[int].create()` plus `s.push(x)` needs `var`, so prefer-let must
## not fire.  The analyzer records those receivers while resolving method kinds,
## matching them by the receiver identifier's name and line.
public function ctx_mark_editable_receiver(call: ptr[ast.Expr], ctx: ref[ScopeContext]) -> void:
    unsafe:
        match read(call):
            ast.Expr.expr_call as cl:
                match read(cl.callee):
                    ast.Expr.expr_member_access:
                        ctx_mark_editable_member(cl.callee, ctx)
                    ast.Expr.expr_specialization as sp:
                        ctx_mark_editable_member(sp.callee, ctx)
                    _:
                        pass
            _:
                pass


## `x.method(...)` / `x.method[T](...)`: mark the receiver when the analyzer
## recorded an editable site at the same name/line.  The analyzer records the
## receiver's *root* identifier (its lvalue walk reaches the binding through
## members/indexes), so the same walk runs here.
function ctx_mark_editable_member(member_expr: ptr[ast.Expr], ctx: ref[ScopeContext]) -> void:
    unsafe:
        match read(member_expr):
            ast.Expr.expr_member_access as ma:
                let root = receiver_root_identifier(ma.receiver) else:
                    return
                var si: ptr_uint = 0
                let sites = read(ctx).editable_sites
                while si < sites.len:
                    let site = read(sites.data + si)
                    if site.line == root.line and site.column == root.column and site.name.equal(root.name):
                        ctx_mark_mutated(ctx, ma.receiver)
                        return
                    si += 1
            _:
                pass


struct RootIdentifier:
    name: str
    line: ptr_uint
    column: ptr_uint


## The root identifier of a receiver expression, through member and index
## accesses only (the analyzer's walk stops at a call receiver too).
function receiver_root_identifier(receiver: ptr[ast.Expr]) -> Option[RootIdentifier]:
    unsafe:
        match read(receiver):
            ast.Expr.expr_identifier as id:
                return Option[RootIdentifier].some(value = RootIdentifier(name = id.name, line = id.line, column = id.column))
            ast.Expr.expr_member_access as ma:
                return receiver_root_identifier(ma.receiver)
            ast.Expr.expr_index_access as ix:
                return receiver_root_identifier(ix.receiver)
            _:
                pass
    return Option[RootIdentifier].none


## Mark bindings mutated by a call's arguments: an identifier the analyzer
## recorded as passed to an `out`/`inout` foreign parameter, or an explicit
## `out x` / `inout x` argument (the host's `mutating_argument_identifier?` and
## its `out`/`inout` write-target rule).
public function ctx_mark_mutating_args(call: ptr[ast.Expr], ctx: ref[ScopeContext]) -> void:
    unsafe:
        match read(call):
            ast.Expr.expr_call as cl:
                var ai: ptr_uint = 0
                while ai < cl.args.len:
                    let value = read(cl.args.data + ai).arg_value
                    match read(value):
                        ast.Expr.expr_identifier as id:
                            if ctx_mutating_site_contains(read(ctx).mutating_sites, id.name, id.line, id.column) or
                               ctx_mutating_site_contains(read(ctx).mutable_lvalue_sites, id.name, id.line, id.column):
                                ctx_mark_mutated(ctx, value)
                        ast.Expr.expr_unary_op as u:
                            if u.operator.equal("out") or u.operator.equal("inout"):
                                ctx_mark_mutated(ctx, u.operand)
                        _:
                            pass
                    ai += 1
            _:
                pass


function ctx_mutating_site_contains(sites: span[analyzer.EditableSite], name: str, line: ptr_uint, column: ptr_uint) -> bool:
    var i: ptr_uint = 0
    unsafe:
        while i < sites.len:
            let site = read(sites.data + i)
            if site.line == line and site.column == column and site.name.equal(name):
                return true
            i += 1
    return false


## When a `ref_of(x)` / `ptr_of(x)` call creates a writable alias, mark the
## source as potentially mutated through it (the host's
## `mark_alias_source_mutated`): exactly one argument, and `mark_mutated`
## recurses through index/member receivers to the root binding, so
## `ptr_of(arr[0])` marks `arr`.
public function ctx_mark_alias_source(call: ptr[ast.Expr], ctx: ref[ScopeContext]) -> void:
    unsafe:
        match read(call):
            ast.Expr.expr_call as cl:
                match read(cl.callee):
                    ast.Expr.expr_identifier as callee_id:
                        if cl.args.len == 1:
                            if callee_id.name.equal("ref_of") or callee_id.name.equal("ptr_of"):
                                ctx_mark_mutated(ctx, read(cl.args.data + 0).arg_value)
                    _:
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


# =============================================================================
#  Pass entry point
# =============================================================================

## The host's `check_unused_imports`, run before the declaration walk: one
## `unused-import` per import whose local name nothing references.
public function lint_unused_imports(
    file: ast.SourceFile,
    path: str,
    unresolved_import_paths: span[str],
    providers: span[ImportMethodProvider],
    analysis: ptr[analyzer.Analysis]?,
    warnings: ref[vec.Vec[ScopeWarning]],
) -> void:
    var credited = collect_import_credits(file, providers, analysis)
    defer: credited.release()
    check_unused_imports(file, path, unresolved_import_paths, credited.as_span(), warnings)


# =============================================================================
#  unused-import
# =============================================================================

function check_unused_imports(file: ast.SourceFile, path: str, unresolved_import_paths: span[str], credited: span[bool], warnings: ref[vec.Vec[ScopeWarning]]) -> void:
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
                    if not import_path_is_unresolved(im.path, unresolved_import_paths):
                        var used = false
                        # Credit by index: `credited` has one flag per import, in
                        # this same order (see collect_import_credits).
                        if i < credited.len:
                            used = read(credited.data + i)
                        if not used:
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


## The dotted module path of an import (`std.linear_algebra`).
function import_path_dotted(path: ast.QualifiedName) -> string.String:
    var dotted = string.String.create()
    var i: ptr_uint = 0
    while i < path.parts.len:
        if i > 0:
            dotted.push_byte(46)
        unsafe:
            dotted.append(read(path.parts.data + i))
        i += 1
    return dotted


## True when the dotted import path is one of the module paths whose import
## failed to resolve (Ruby's `unresolved_import_paths`): those are never
## reported as unused, because the failure is already reported elsewhere.
function import_path_is_unresolved(path: ast.QualifiedName, unresolved_import_paths: span[str]) -> bool:
    if unresolved_import_paths.len == 0:
        return false
    var dotted = import_path_dotted(path)
    defer: dotted.release()
    let name = dotted.as_str()
    var j: ptr_uint = 0
    while j < unresolved_import_paths.len:
        if unsafe: read(unresolved_import_paths.data + j).equal(name):
            return true
        j += 1
    return false


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
            ast.Stmt.stmt_local as loc:
                # A local's initializer names the import too
                # (`let v = vec.Vec[int].create()`), so an import used only
                # there is not unused.
                let value = loc.value else:
                    return false
                return expr_contains_name(value, name)
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
#  unused-import credit (Ruby's `collect_method_only_import_uses`)
# =============================================================================

## One imported module's method surface: the dotted module name plus the
## module's own analysis, whose `method_keys` (`"Type.method"`) are consulted
## when a receiver-typed method call or a canonical hook builtin could be
## provided by that import.
public struct ImportMethodProvider:
    module_name: str
    analysis: ptr[analyzer.Analysis]?


## One provider per entry of `file.imports`, in the same order (so a credit
## flag index matches the import index).  The dotted path resolves against the
## loaded program's analyses; an unresolved import gets a null analysis.
public function build_import_method_providers(file: ast.SourceFile, analyses: span[analyzer.Analysis]) -> vec.Vec[ImportMethodProvider]:
    var providers = vec.Vec[ImportMethodProvider].create()
    var i: ptr_uint = 0
    while i < file.imports.len:
        unsafe:
            match read(file.imports.data + i):
                ast.Decl.decl_import as im:
                    var dotted = import_path_dotted(im.path)
                    var found: ptr[analyzer.Analysis]? = null
                    var ai: ptr_uint = 0
                    while ai < analyses.len:
                        let ap = analyses.data + ai
                        if read(ap).module_name.equal(dotted.as_str()):
                            found = ap
                            break
                        ai += 1
                    if found != null:
                        providers.push(ImportMethodProvider(
                            module_name = read(ptr[analyzer.Analysis]<-found).module_name,
                            analysis = found
                        ))
                    else:
                        providers.push(ImportMethodProvider(module_name = "", analysis = null))
                    dotted.release()
                _:
                    providers.push(ImportMethodProvider(module_name = "", analysis = null))
        i += 1
    return providers


## Which imports are used without naming them: a `recv.method(...)` call
## credits every import whose module declares that method on the receiver's
## resolved type name (and the import owning the receiver's type), a canonical
## hook builtin credits every import that defines such a method at all, and an
## identifier or type-reference segment naming an import's local binding credits
## that import (Ruby's `collect_used_names`).  One flag per `providers` entry.
public function collect_import_credits(file: ast.SourceFile, providers: span[ImportMethodProvider], analysis: ptr[analyzer.Analysis]?) -> vec.Vec[bool]:
    var credited = vec.Vec[bool].create()
    var i: ptr_uint = 0
    while i < providers.len:
        credited.push(false)
        i += 1
    var import_names = vec.Vec[str].create()
    defer: import_names.release()
    var ii: ptr_uint = 0
    while ii < file.imports.len:
        unsafe:
            match read(file.imports.data + ii):
                ast.Decl.decl_import as im:
                    import_names.push(import_local_name(im.path, im.alias_name))
                _:
                    import_names.push("")
        ii += 1
    if providers.len == 0:
        return credited
    let credit_flags = credited.as_span().data
    var di: ptr_uint = 0
    while di < file.declarations.len:
        unsafe:
            credit_walk_decl(file.declarations.data + di, providers, credit_flags, analysis, import_names.as_span())
        di += 1
    return credited


## The local binding name of an import (its alias, else the path's last part).
function import_local_name(path: ast.QualifiedName, alias_name: Option[str]) -> str:
    match alias_name:
        Option.some as an:
            return an.value
        Option.none:
            return unsafe: read(path.parts.data + path.parts.len - 1)


## Credit every import whose local name occurs in `name` (a bare identifier or
## a type-path segment).
function credit_name(name: str, import_names: span[str], credit_flags: ptr[bool]) -> void:
    var i: ptr_uint = 0
    while i < import_names.len:
        if unsafe: read(import_names.data + i).equal(name):
            unsafe: read(credit_flags + i) = true
        i += 1


## Prelude/builtin method keys (`Option.*`, `Result.*`, `EventError.*`,
## `Subscription.*`) are merged into *every* module's method set, so only the
## module that owns the type may be credited for them — otherwise calling any
## prelude method would credit every import (`fmt`, `log`, …).
function provider_owns_prelude_key(leaf: str, module_name: str) -> bool:
    if leaf.equal("Option"):
        return module_name.equal("std.option")
    if leaf.equal("Result"):
        return module_name.equal("std.result")
    if leaf.equal("EventError") or leaf.equal("Subscription"):
        return false
    return true


## Credit the imports named anywhere in a type reference: the root name of the
## qualified path (`ref[arena.Arena]`, `vec.Vec[int]`), generic arguments,
## function-type parameters/returns and dyn interface names (Ruby's
## `collect_names_from_type`).
function credit_typeref(tr: ast.TypeRef, import_names: span[str], credit_flags: ptr[bool]) -> void:
    if tr.name.parts.len > 0:
        credit_name(unsafe: read(tr.name.parts.data + 0), import_names, credit_flags)
    var qi: ptr_uint = 0
    while qi < tr.name.type_arguments.len:
        credit_typeref(unsafe: read(tr.name.type_arguments.data + qi), import_names, credit_flags)
        qi += 1
    var ai: ptr_uint = 0
    while ai < tr.arguments.len:
        credit_typeref(unsafe: read(tr.arguments.data + ai), import_names, credit_flags)
        ai += 1
    var fi: ptr_uint = 0
    while fi < tr.fn_params.len:
        credit_typeref(unsafe: read(tr.fn_params.data + fi).param_type, import_names, credit_flags)
        fi += 1
    if tr.fn_return != null:
        credit_typeref(unsafe: read(ptr[ast.TypeRef]<-tr.fn_return), import_names, credit_flags)
    var di: ptr_uint = 0
    while di < tr.dyn_interface.parts.len:
        credit_name(unsafe: read(tr.dyn_interface.parts.data + di), import_names, credit_flags)
        di += 1


function credit_typeref_opt(tr: ptr[ast.TypeRef]?, import_names: span[str], credit_flags: ptr[bool]) -> void:
    let tp = tr else:
        return
    credit_typeref(unsafe: read(tp), import_names, credit_flags)


function credit_walk_decl(decl: ptr[ast.Decl], providers: span[ImportMethodProvider], credit_flags: ptr[bool], analysis: ptr[analyzer.Analysis]?, import_names: span[str]) -> void:
    unsafe:
        match read(decl):
            ast.Decl.decl_function as fun:
                var pi: ptr_uint = 0
                while pi < fun.method_params.len:
                    credit_typeref(read(fun.method_params.data + pi).param_type, import_names, credit_flags)
                    pi += 1
                credit_typeref_opt(fun.return_type, import_names, credit_flags)
                credit_walk_stmt_opt(fun.body, providers, credit_flags, analysis, import_names)
            ast.Decl.decl_extending_block as ex:
                var j: ptr_uint = 0
                while j < ex.methods.len:
                    let m = read(ex.methods.data + j)
                    var pi: ptr_uint = 0
                    while pi < m.method_params.len:
                        credit_typeref(read(m.method_params.data + pi).param_type, import_names, credit_flags)
                        pi += 1
                    credit_typeref_opt(m.return_type, import_names, credit_flags)
                    credit_walk_stmt(m.body, providers, credit_flags, analysis, import_names)
                    j += 1
            ast.Decl.decl_const as c:
                credit_typeref(read(c.const_type), import_names, credit_flags)
                credit_walk_expr_opt(c.value, providers, credit_flags, analysis, import_names)
                credit_walk_stmt_opt(c.block_body, providers, credit_flags, analysis, import_names)
            ast.Decl.decl_var as v:
                credit_typeref_opt(v.var_type, import_names, credit_flags)
                credit_walk_expr_opt(v.value, providers, credit_flags, analysis, import_names)
            ast.Decl.decl_struct as st:
                var fi: ptr_uint = 0
                while fi < st.struct_fields.len:
                    credit_typeref(read(st.struct_fields.data + fi).field_type, import_names, credit_flags)
                    fi += 1
                var ni: ptr_uint = 0
                while ni < st.nested_types.len:
                    credit_walk_decl(st.nested_types.data + ni, providers, credit_flags, analysis, import_names)
                    ni += 1
            ast.Decl.decl_union as un:
                var fi: ptr_uint = 0
                while fi < un.union_fields.len:
                    credit_typeref(read(un.union_fields.data + fi).field_type, import_names, credit_flags)
                    fi += 1
            ast.Decl.decl_enum as en:
                credit_typeref_opt(en.backing_type, import_names, credit_flags)
            ast.Decl.decl_flags as fl:
                credit_typeref_opt(fl.backing_type, import_names, credit_flags)
            ast.Decl.decl_variant as va:
                var ai: ptr_uint = 0
                while ai < va.variant_arms.len:
                    let arm = read(va.variant_arms.data + ai)
                    var fi: ptr_uint = 0
                    while fi < arm.arm_fields.len:
                        credit_typeref(read(arm.arm_fields.data + fi).field_type, import_names, credit_flags)
                        fi += 1
                    ai += 1
            ast.Decl.decl_type_alias as ta:
                credit_typeref(read(ta.target), import_names, credit_flags)
            ast.Decl.decl_interface as itf:
                var mi: ptr_uint = 0
                while mi < itf.interface_methods.len:
                    let m = read(itf.interface_methods.data + mi)
                    var pi: ptr_uint = 0
                    while pi < m.method_params.len:
                        credit_typeref(read(m.method_params.data + pi).param_type, import_names, credit_flags)
                        pi += 1
                    credit_typeref_opt(m.return_type, import_names, credit_flags)
                    mi += 1
            ast.Decl.decl_extern_function as ef:
                var pi: ptr_uint = 0
                while pi < ef.extern_params.len:
                    credit_typeref(read(ef.extern_params.data + pi).param_type, import_names, credit_flags)
                    pi += 1
                credit_typeref_opt(ef.return_type, import_names, credit_flags)
                credit_walk_expr_opt(ef.mapping, providers, credit_flags, analysis, import_names)
            ast.Decl.decl_foreign_function as ff:
                var pi: ptr_uint = 0
                while pi < ff.foreign_params.len:
                    credit_typeref(read(ff.foreign_params.data + pi).param_type, import_names, credit_flags)
                    pi += 1
                credit_typeref(read(ff.return_type), import_names, credit_flags)
                credit_walk_expr(ff.mapping, providers, credit_flags, analysis, import_names)
            ast.Decl.decl_when as w:
                var bi: ptr_uint = 0
                while bi < w.branches.len:
                    let body = read(w.branches.data + bi).body
                    var di: ptr_uint = 0
                    while di < body.len:
                        credit_walk_decl(body.data + di, providers, credit_flags, analysis, import_names)
                        di += 1
                    bi += 1
            _:
                pass


function credit_walk_stmt_opt(stmt: ptr[ast.Stmt]?, providers: span[ImportMethodProvider], credit_flags: ptr[bool], analysis: ptr[analyzer.Analysis]?, import_names: span[str]) -> void:
    let sp = stmt else:
        return
    credit_walk_stmt(sp, providers, credit_flags, analysis, import_names)


function credit_walk_stmt(stmt: ptr[ast.Stmt], providers: span[ImportMethodProvider], credit_flags: ptr[bool], analysis: ptr[analyzer.Analysis]?, import_names: span[str]) -> void:
    unsafe:
        match read(stmt):
            ast.Stmt.stmt_block as blk:
                var i: ptr_uint = 0
                while i < blk.statements.len:
                    credit_walk_stmt(blk.statements.data + i, providers, credit_flags, analysis, import_names)
                    i += 1
            ast.Stmt.stmt_local as loc:
                credit_typeref_opt(loc.stmt_type, import_names, credit_flags)
                credit_walk_expr_opt(loc.value, providers, credit_flags, analysis, import_names)
                credit_walk_stmt_opt(loc.else_body, providers, credit_flags, analysis, import_names)
            ast.Stmt.stmt_assignment as asgn:
                credit_walk_expr(asgn.target, providers, credit_flags, analysis, import_names)
                credit_walk_expr(asgn.value, providers, credit_flags, analysis, import_names)
            ast.Stmt.stmt_if as iff:
                var bi: ptr_uint = 0
                while bi < iff.branches.len:
                    let br = read(iff.branches.data + bi)
                    credit_walk_expr(br.condition, providers, credit_flags, analysis, import_names)
                    credit_walk_stmt(br.body, providers, credit_flags, analysis, import_names)
                    bi += 1
                credit_walk_stmt_opt(iff.else_body, providers, credit_flags, analysis, import_names)
            ast.Stmt.stmt_while as wh:
                credit_walk_expr(wh.condition, providers, credit_flags, analysis, import_names)
                credit_walk_stmt_opt(wh.body, providers, credit_flags, analysis, import_names)
            ast.Stmt.stmt_for as fr:
                var ii: ptr_uint = 0
                while ii < fr.iterables.len:
                    credit_walk_expr(fr.iterables.data + ii, providers, credit_flags, analysis, import_names)
                    ii += 1
                credit_walk_stmt_opt(fr.body, providers, credit_flags, analysis, import_names)
            ast.Stmt.stmt_match as mt:
                credit_walk_expr(mt.scrutinee, providers, credit_flags, analysis, import_names)
                var ai: ptr_uint = 0
                while ai < mt.arms.len:
                    let arm = read(mt.arms.data + ai)
                    credit_walk_expr_opt(arm.pattern, providers, credit_flags, analysis, import_names)
                    credit_walk_stmt_opt(arm.body, providers, credit_flags, analysis, import_names)
                    ai += 1
            ast.Stmt.stmt_ret as r:
                credit_walk_expr_opt(r.value, providers, credit_flags, analysis, import_names)
            ast.Stmt.stmt_defer as df:
                credit_walk_expr_opt(df.expression, providers, credit_flags, analysis, import_names)
                credit_walk_stmt_opt(df.body, providers, credit_flags, analysis, import_names)
            ast.Stmt.stmt_unsafe as un:
                credit_walk_stmt_opt(un.body, providers, credit_flags, analysis, import_names)
            ast.Stmt.stmt_expression as ex:
                credit_walk_expr(ex.expression, providers, credit_flags, analysis, import_names)
            ast.Stmt.stmt_static_assert as sa:
                credit_walk_expr(sa.condition, providers, credit_flags, analysis, import_names)
                credit_walk_expr_opt(sa.message, providers, credit_flags, analysis, import_names)
            ast.Stmt.stmt_when as w:
                credit_walk_expr(w.discriminant, providers, credit_flags, analysis, import_names)
                var bi: ptr_uint = 0
                while bi < w.branches.len:
                    let body = read(w.branches.data + bi).body
                    var si: ptr_uint = 0
                    while si < body.len:
                        credit_walk_stmt(body.data + si, providers, credit_flags, analysis, import_names)
                        si += 1
                    bi += 1
                credit_walk_stmt_opt(w.else_body, providers, credit_flags, analysis, import_names)
            ast.Stmt.stmt_error_block as eb:
                credit_walk_stmt(eb.body, providers, credit_flags, analysis, import_names)
            _:
                pass


function credit_walk_expr_opt(expr: ptr[ast.Expr]?, providers: span[ImportMethodProvider], credit_flags: ptr[bool], analysis: ptr[analyzer.Analysis]?, import_names: span[str]) -> void:
    let ep = expr else:
        return
    credit_walk_expr(ep, providers, credit_flags, analysis, import_names)


function credit_walk_expr(expr: ptr[ast.Expr], providers: span[ImportMethodProvider], credit_flags: ptr[bool], analysis: ptr[analyzer.Analysis]?, import_names: span[str]) -> void:
    unsafe:
        match read(expr):
            ast.Expr.expr_identifier as id:
                credit_name(id.name, import_names, credit_flags)
            ast.Expr.expr_binary_op as b:
                credit_walk_expr(b.left, providers, credit_flags, analysis, import_names)
                credit_walk_expr(b.right, providers, credit_flags, analysis, import_names)
            ast.Expr.expr_unary_op as u:
                credit_walk_expr(u.operand, providers, credit_flags, analysis, import_names)
            ast.Expr.expr_member_access as m:
                credit_walk_expr(m.receiver, providers, credit_flags, analysis, import_names)
            ast.Expr.expr_call as call:
                match read(call.callee):
                    ast.Expr.expr_member_access as m:
                        credit_member_call(m.receiver, m.member_name, providers, credit_flags, analysis, import_names)
                    _:
                        pass
                credit_walk_expr(call.callee, providers, credit_flags, analysis, import_names)
                var i: ptr_uint = 0
                while i < call.args.len:
                    credit_walk_expr(read(call.args.data + i).arg_value, providers, credit_flags, analysis, import_names)
                    i += 1
            ast.Expr.expr_index_access as ix:
                credit_walk_expr(ix.receiver, providers, credit_flags, analysis, import_names)
                credit_walk_expr(ix.index, providers, credit_flags, analysis, import_names)
            ast.Expr.expr_specialization as sp:
                credit_hook_call(sp.callee, providers, credit_flags)
                credit_walk_expr(sp.callee, providers, credit_flags, analysis, import_names)
            ast.Expr.expr_if as iff:
                credit_walk_expr(iff.condition, providers, credit_flags, analysis, import_names)
                credit_walk_expr(iff.then_expr, providers, credit_flags, analysis, import_names)
                credit_walk_expr(iff.else_expr, providers, credit_flags, analysis, import_names)
            ast.Expr.expr_match as mm:
                credit_walk_expr(mm.scrutinee, providers, credit_flags, analysis, import_names)
                var ai: ptr_uint = 0
                while ai < mm.arms.len:
                    let arm = read(mm.arms.data + ai)
                    credit_walk_expr_opt(arm.pattern, providers, credit_flags, analysis, import_names)
                    credit_walk_expr(arm.value, providers, credit_flags, analysis, import_names)
                    ai += 1
            ast.Expr.expr_proc as pr:
                var pi: ptr_uint = 0
                while pi < pr.method_params.len:
                    credit_typeref(read(pr.method_params.data + pi).param_type, import_names, credit_flags)
                    pi += 1
                credit_typeref_opt(pr.return_type, import_names, credit_flags)
                credit_walk_stmt(pr.body, providers, credit_flags, analysis, import_names)
            ast.Expr.expr_await as aw:
                credit_walk_expr(aw.expression, providers, credit_flags, analysis, import_names)
            ast.Expr.expr_detach as dt:
                credit_walk_expr(dt.expression, providers, credit_flags, analysis, import_names)
            ast.Expr.expr_expression_list as el:
                var ei: ptr_uint = 0
                while ei < el.elements.len:
                    credit_walk_expr(el.elements.data + ei, providers, credit_flags, analysis, import_names)
                    ei += 1
            ast.Expr.expr_named as nm:
                credit_walk_expr(nm.value, providers, credit_flags, analysis, import_names)
            ast.Expr.expr_range as rg:
                credit_walk_expr(rg.start_expr, providers, credit_flags, analysis, import_names)
                credit_walk_expr(rg.end_expr, providers, credit_flags, analysis, import_names)
            ast.Expr.expr_prefix_cast as pc:
                credit_typeref(read(pc.target_type), import_names, credit_flags)
                credit_walk_expr(pc.expression, providers, credit_flags, analysis, import_names)
            ast.Expr.expr_unsafe as us:
                credit_walk_expr(us.expression, providers, credit_flags, analysis, import_names)
            ast.Expr.expr_format_string as fs:
                var pi: ptr_uint = 0
                while pi < fs.parts.len:
                    match read(fs.parts.data + pi):
                        ast.FormatStringPart.fmt_expr as fe:
                            credit_walk_expr(fe.expression, providers, credit_flags, analysis, import_names)
                        _:
                            pass
                    pi += 1
            ast.Expr.expr_sizeof as sz:
                credit_typeref(read(sz.target_type), import_names, credit_flags)
            ast.Expr.expr_alignof as al:
                credit_typeref(read(al.target_type), import_names, credit_flags)
            ast.Expr.expr_offsetof as off:
                credit_typeref(read(off.target_type), import_names, credit_flags)
            _:
                pass


## Credit the imports that could provide `recv.member(...)`: every provider
## whose module declares `member` on the receiver's resolved type name, plus
## the import that owns the receiver's type module.
function credit_member_call(receiver: ptr[ast.Expr], member: str, providers: span[ImportMethodProvider], credit_flags: ptr[bool], analysis: ptr[analyzer.Analysis]?, import_names: span[str]) -> void:
    let ap = analysis else:
        return
    let ty_ptr = unsafe: read(ap).resolved_expr_types.get(unsafe: reinterpret[ptr_uint](receiver)) else:
        return
    let recv_type = unsafe: read(ty_ptr)
    let leaf = type_leaf_name(recv_type)
    let recv_module = type_module_name(recv_type)
    var key = string.String.create()
    defer: key.release()
    var has_key = false
    if leaf.len > 0:
        key.append(leaf)
        key.push_byte(46)
        key.append(member)
        has_key = true
    let key_str = key.as_str()
    var i: ptr_uint = 0
    while i < providers.len:
        unsafe:
            let p = read(providers.data + i)
            var hit = false
            if p.analysis != null and has_key and provider_owns_prelude_key(leaf, p.module_name):
                if read(ptr[analyzer.Analysis]<-p.analysis).method_keys.contains(key_str):
                    hit = true
            if not hit and recv_module.len > 0 and p.module_name.len > 0 and p.module_name.equal(recv_module):
                hit = true
            if hit:
                read(credit_flags + i) = true
        i += 1


## Credit every import that defines a canonical hook associated function
## (`Type.hash` / `.equal` / `.order` / `.default`) when a hook builtin is
## used: the type argument may be reflective, so the provider cannot be
## resolved more precisely.
function credit_hook_call(callee: ptr[ast.Expr], providers: span[ImportMethodProvider], credit_flags: ptr[bool]) -> void:
    unsafe:
        match read(callee):
            ast.Expr.expr_identifier as id:
                if is_hook_builtin_name(id.name):
                    var i: ptr_uint = 0
                    while i < providers.len:
                        let p = read(providers.data + i)
                        if p.analysis != null:
                            if method_keys_define_hook(read(ptr[analyzer.Analysis]<-p.analysis).method_keys):
                                read(credit_flags + i) = true
                        i += 1
            _:
                pass


function is_hook_builtin_name(name: str) -> bool:
    return name.equal("hash") or name.equal("equal") or name.equal("order") or name.equal("default")


function method_keys_define_hook(keys: map_mod.Map[str, bool]) -> bool:
    var it = keys.keys()
    while true:
        let kp = it.next() else:
            break
        let key = unsafe: read(kp)
        if key.ends_with(".hash") or key.ends_with(".equal") or key.ends_with(".order") or key.ends_with(".default"):
            return true
    return false


function type_leaf_name(ty: types.Type) -> str:
    match ty:
        types.Type.ty_primitive as p:
            return p.name
        types.Type.ty_str:
            return "str"
        types.Type.ty_named as n:
            let n_np = unsafe: read(n.payload)
            return n_np.name
        types.Type.ty_imported as im:
            return im.name
        types.Type.ty_generic as g:
            return g.name
        types.Type.ty_opaque as op:
            return op.name
        types.Type.ty_var as v:
            return v.name
        types.Type.ty_nullable as nb:
            return type_leaf_name(unsafe: read(nb.base))
        _:
            return ""


function type_module_name(ty: types.Type) -> str:
    match ty:
        types.Type.ty_named as n:
            let n_np = unsafe: read(n.payload)
            return n_np.module_name
        types.Type.ty_imported as im:
            return im.module_name
        types.Type.ty_opaque as op:
            return op.module_name
        _:
            return ""
