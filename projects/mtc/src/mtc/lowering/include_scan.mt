## Include scanning and emission — `fatal`/`offsetof` usage scans, raw-module
## `#include` collection, and the C runtime header helpers.  Extracted from
## lowering/lowering.mt.

import std.vec as vec
import std.map as map_mod
import std.string as string
import std.str

import mtc.ir as ir
import mtc.parser.ast as ast
import mtc.semantic.analyzer as analyzer
import mtc.loader.module_loader as loader

import mtc.lowering.lowering as lowering
import mtc.strings

## Which built-in the include scan looks for (host scans.rb).
const SCAN_FATAL: int = 0
const SCAN_OFFSETOF: int = 1


## True when an expression is a `fatal(...)` call (mode 0) or an `offsetof`
## expression (mode 1).
function expr_matches_scan(ep: ptr[ast.Expr], mode: int) -> bool:
    unsafe:
        match read(ep):
            ast.Expr.expr_call as c:
                if mode == SCAN_FATAL:
                    match read(c.callee):
                        ast.Expr.expr_identifier as id:
                            if id.name == "fatal":
                                return true
                        _:
                            pass
            ast.Expr.expr_offsetof:
                if mode == SCAN_OFFSETOF:
                    return true
            _:
                pass
    return false


function expr_args_use_scan(args: span[ast.Argument], mode: int) -> bool:
    var i: ptr_uint = 0
    while i < args.len:
        let a = unsafe: read(args.data + i)
        if expr_uses_scan(a.arg_value, mode):
            return true
        i += 1
    return false


function match_arms_use_scan(arms: span[ast.MatchArm], mode: int) -> bool:
    var i: ptr_uint = 0
    while i < arms.len:
        let a = unsafe: read(arms.data + i)
        if expr_uses_scan(a.pattern, mode):
            return true
        if stmt_uses_scan(a.body, mode):
            return true
        i += 1
    return false


function match_expr_arms_use_scan(arms: span[ast.MatchExprArm], mode: int) -> bool:
    var i: ptr_uint = 0
    while i < arms.len:
        let a = unsafe: read(arms.data + i)
        if expr_uses_scan(a.pattern, mode):
            return true
        if expr_uses_scan(a.value, mode):
            return true
        i += 1
    return false


function if_branches_use_scan(branches: span[ast.IfBranch], mode: int) -> bool:
    var i: ptr_uint = 0
    while i < branches.len:
        let b = unsafe: read(branches.data + i)
        if expr_uses_scan(b.condition, mode):
            return true
        if stmt_uses_scan(b.body, mode):
            return true
        i += 1
    return false


function expr_list_uses_scan(items: span[ast.Expr], mode: int) -> bool:
    var i: ptr_uint = 0
    while i < items.len:
        if expr_uses_scan(unsafe: items.data + i, mode):
            return true
        i += 1
    return false


## Walk an expression tree for `fatal`/`offsetof` (host
## `expression_uses_pattern?`).
function expr_uses_scan(ep: ptr[ast.Expr]?, mode: int) -> bool:
    if ep == null:
        return false
    let p = ptr[ast.Expr]<-ep
    if expr_matches_scan(p, mode):
        return true
    unsafe:
        match read(p):
            ast.Expr.expr_await as x:
                return expr_uses_scan(x.expression, mode)
            ast.Expr.expr_call as x:
                return expr_uses_scan(x.callee, mode) or expr_args_use_scan(x.args, mode)
            ast.Expr.expr_binary_op as x:
                return expr_uses_scan(x.left, mode) or expr_uses_scan(x.right, mode)
            ast.Expr.expr_range as x:
                return expr_uses_scan(x.start_expr, mode) or expr_uses_scan(x.end_expr, mode)
            ast.Expr.expr_if as x:
                return expr_uses_scan(
                    x.condition,
                    mode
                ) or expr_uses_scan(x.then_expr, mode) or expr_uses_scan(x.else_expr, mode)
            ast.Expr.expr_match as x:
                return expr_uses_scan(x.scrutinee, mode) or match_expr_arms_use_scan(x.arms, mode)
            ast.Expr.expr_unsafe as x:
                return expr_uses_scan(x.expression, mode)
            ast.Expr.expr_prefix_cast as x:
                return expr_uses_scan(x.expression, mode)
            ast.Expr.expr_unary_op as x:
                return expr_uses_scan(x.operand, mode)
            ast.Expr.expr_member_access as x:
                return expr_uses_scan(x.receiver, mode)
            ast.Expr.expr_index_access as x:
                return expr_uses_scan(x.receiver, mode) or expr_uses_scan(x.index, mode)
            ast.Expr.expr_specialization as x:
                return expr_uses_scan(x.callee, mode)
            _:
                pass
    return false


## Walk a statement tree for `fatal`/`offsetof` (host
## `statement_uses_expression_pattern?`; unhandled kinds are false there too).
function stmt_uses_scan(sp: ptr[ast.Stmt]?, mode: int) -> bool:
    if sp == null:
        return false
    let p = ptr[ast.Stmt]<-sp
    unsafe:
        match read(p):
            ast.Stmt.stmt_local as x:
                return expr_uses_scan(x.value, mode)
            ast.Stmt.stmt_assignment as x:
                return expr_uses_scan(x.target, mode) or expr_uses_scan(x.value, mode)
            ast.Stmt.stmt_if as x:
                return if_branches_use_scan(x.branches, mode) or stmt_uses_scan(x.else_body, mode)
            ast.Stmt.stmt_match as x:
                return expr_uses_scan(x.scrutinee, mode) or match_arms_use_scan(x.arms, mode)
            ast.Stmt.stmt_static_assert as x:
                return expr_uses_scan(x.condition, mode) or expr_uses_scan(x.message, mode)
            ast.Stmt.stmt_for as x:
                return expr_list_uses_scan(x.iterables, mode) or stmt_uses_scan(x.body, mode)
            ast.Stmt.stmt_unsafe as x:
                return stmt_uses_scan(x.body, mode)
            ast.Stmt.stmt_while as x:
                return expr_uses_scan(x.condition, mode) or stmt_uses_scan(x.body, mode)
            ast.Stmt.stmt_ret as x:
                return expr_uses_scan(x.value, mode)
            ast.Stmt.stmt_expression as x:
                return expr_uses_scan(x.expression, mode)
            ast.Stmt.stmt_defer as x:
                return stmt_uses_scan(x.body, mode) or expr_uses_scan(x.expression, mode)
            ast.Stmt.stmt_block as x:
                var bi: ptr_uint = 0
                while bi < x.statements.len:
                    if stmt_uses_scan(unsafe: x.statements.data + bi, mode):
                        return true
                    bi += 1
            _:
                pass
    return false


## True when any non-raw module's functions or extending methods use the
## scanned construct (host `program_uses_fatal?` / `program_uses_offsetof?`).
function program_uses_scan(program: loader.Program, mode: int) -> bool:
    var ai: ptr_uint = 0
    while ai < program.analyses.len():
        let a_ptr = program.analyses.get(ai) else:
            break
        var analysis = unsafe: read(a_ptr)
        if not lowering.is_raw_module(analysis.module_kind):
            var di: ptr_uint = 0
            while di < analysis.source_file.declarations.len:
                var decl: ast.Decl
                unsafe:
                    decl = read(analysis.source_file.declarations.data + di)
                match decl:
                    ast.Decl.decl_function as f:
                        if stmt_uses_scan(f.body, mode):
                            return true
                    ast.Decl.decl_extending_block as e:
                        var mi: ptr_uint = 0
                        while mi < e.methods.len:
                            let m = unsafe: read(e.methods.data + mi)
                            if stmt_uses_scan(m.body, mode):
                                return true
                            mi += 1
                    _:
                        pass
                di += 1
        ai += 1
    return false


## Collect the full include set: the base C runtime headers plus every `include`
## directive from raw (`external`) module analyses (e.g. `std.c.fs` →
## `fs_support.h`).  Mirrors Ruby's `collect_includes` so external ABI struct
## types declared in those headers are in scope.  Deduplicated, base headers first.
public function collect_includes(program: loader.Program) -> span[ir.Include]:
    var includes = vec.Vec[ir.Include].create()
    var seen = map_mod.Map[str, bool].create()
    includes.push(ir.Include(header = "<stdbool.h>"))
    includes.push(ir.Include(header = "<stdint.h>"))
    includes.push(ir.Include(header = "<string.h>"))
    seen.set("<stdbool.h>", true)
    seen.set("<stdint.h>", true)
    seen.set("<string.h>", true)

    if program_uses_scan(program, SCAN_OFFSETOF):
        includes.push(ir.Include(header = "<stddef.h>"))
        seen.set("<stddef.h>", true)
    if program_uses_scan(program, SCAN_FATAL):
        includes.push(ir.Include(header = "<stdio.h>"))
        seen.set("<stdio.h>", true)

    # External-binding headers follow the host's analysis-cache insertion
    # order: its loader checks each module's imports on demand (in declaration
    # order) and inserts a module's analysis only after its imports are cached
    # — a DFS post-order from the root.  Raw modules are leaves, so their
    # directives are appended when they are popped.  `program.analyses` is the
    # canonical dependency-first order and cannot supply this.
    var by_name = map_mod.Map[str, analyzer.Analysis].create()
    var ai: ptr_uint = 0
    while ai < program.analyses.len():
        let a_ptr = program.analyses.get(ai) else:
            break
        var a = unsafe: read(a_ptr)
        if not by_name.contains(a.module_name):
            by_name.set(a.module_name, a)
        ai += 1

    var include_visited = map_mod.Map[str, bool].create()
    if program.analyses.len() > 0:
        let a_ptr = program.analyses.get(program.root_index) else:
            fatal(c"collect_includes: root analysis missing")
        let root_name = unsafe: read(a_ptr).module_name
        if program.cycle_module_names.len() > 0:
            # The host checks cycle members (and their acyclic dependencies)
            # before the root's remaining closure, so their raw-module
            # directives are inserted first.  Reproduce that insertion order:
            # each cycle member's dependency closure (cycle edges skipped, as
            # the host's forward bindings do), then the root's closure.
            var cycle_set = map_mod.Map[str, bool].create()
            var ci: ptr_uint = 0
            while ci < program.cycle_module_names.len():
                let name_ptr = program.cycle_module_names.get(ci) else:
                    break
                cycle_set.set(unsafe: read(name_ptr), true)
                ci += 1
            ci = 0
            while ci < program.cycle_module_names.len():
                let name_ptr = program.cycle_module_names.get(ci) else:
                    break
                emit_ordered_raw_includes(
                    ref_of(by_name),
                    ref_of(cycle_set),
                    ref_of(include_visited),
                    ref_of(includes),
                    ref_of(seen),
                    unsafe: read(name_ptr)
                )
                ci += 1
            emit_ordered_raw_includes(
                ref_of(by_name),
                ref_of(cycle_set),
                ref_of(include_visited),
                ref_of(includes),
                ref_of(seen),
                root_name
            )
        else:
            emit_raw_module_includes(
                ref_of(by_name),
                ref_of(include_visited),
                ref_of(includes),
                ref_of(seen),
                root_name
            )

    return includes.as_span()


## Append raw-binding include directives in the host's cache order: recurse
## into a module's imports in declaration order first, then emit the module's
## own directives when it is a raw module (DFS post-order).
function emit_raw_module_includes(
    by_name: ref[map_mod.Map[str, analyzer.Analysis]],
    visited: ref[map_mod.Map[str, bool]],
    includes: ref[vec.Vec[ir.Include]],
    seen: ref[map_mod.Map[str, bool]],
    name: str
) -> void:
    if visited.contains(name):
        return
    visited.set(name, true)
    let ap = by_name.get(name) else:
        return
    let analysis = unsafe: read(ap)
    var i: ptr_uint = 0
    while i < analysis.source_file.imports.len:
        var import_decl: ast.Decl
        unsafe:
            import_decl = read(analysis.source_file.imports.data + i)
        match import_decl:
            ast.Decl.decl_import as imported:
                emit_raw_module_includes(by_name, visited, includes, seen, analyzer.qname_to_str(imported.path))
            _:
                pass
        i += 1
    emit_raw_directives(analysis, includes, seen)


## The cycle-aware variant of `emit_raw_module_includes`: cycle members are
## skipped on the recursive walk (the host's forward bindings), and each cycle
## member's own closure is walked separately before the root's.  `visited` is
## the analysis insertion order, not just a dedup set.
function emit_ordered_raw_includes(
    by_name: ref[map_mod.Map[str, analyzer.Analysis]],
    cycle_set: ref[map_mod.Map[str, bool]],
    visited: ref[map_mod.Map[str, bool]],
    includes: ref[vec.Vec[ir.Include]],
    seen: ref[map_mod.Map[str, bool]],
    name: str
) -> void:
    if visited.contains(name):
        return
    visited.set(name, true)
    let ap = by_name.get(name) else:
        return
    let analysis = unsafe: read(ap)
    var i: ptr_uint = 0
    while i < analysis.source_file.imports.len:
        var import_decl: ast.Decl
        unsafe:
            import_decl = read(analysis.source_file.imports.data + i)
        match import_decl:
            ast.Decl.decl_import as imported:
                let dep = analyzer.qname_to_str(imported.path)
                if not cycle_set.contains(dep):
                    emit_ordered_raw_includes(by_name, cycle_set, visited, includes, seen, dep)
            _:
                pass
        i += 1
    emit_raw_directives(analysis, includes, seen)


function emit_raw_directives(
    analysis: analyzer.Analysis,
    includes: ref[vec.Vec[ir.Include]],
    seen: ref[map_mod.Map[str, bool]]
) -> void:
    if lowering.is_raw_module(analysis.module_kind):
        var di: ptr_uint = 0
        while di < analysis.directives.len:
            var directive: ast.Decl
            unsafe:
                directive = read(analysis.directives.data + di)
            match directive:
                ast.Decl.decl_include as inc:
                    let header = normalized_include_header(inc.value)
                    if not seen.contains(header):
                        seen.set(header, true)
                        includes.push(ir.Include(header = header))
                _:
                    pass
            di += 1


## In-place ascending insertion sort of a `str` vector by byte order.
function sort_str_vec(items: ref[vec.Vec[str]]) -> void:
    var i: ptr_uint = 1
    while i < items.len():
        var j = i
        while j > 0:
            let a_ptr = items.get(j - 1) else:
                break
            let b_ptr = items.get(j) else:
                break
            var a: str
            var b: str
            unsafe:
                a = read(a_ptr)
                b = read(b_ptr)
            if str_less_than(a, b):
                break
            items.swap(j - 1, j)
            j -= 1
        i += 1


## True when `left` sorts strictly before `right` in byte order.
public function str_less_than(left: str, right: str) -> bool:
    var index: ptr_uint = 0
    let shared = if left.len < right.len: left.len else: right.len
    while index < shared:
        let lb = left.byte_at(index)
        let rb = right.byte_at(index)
        if lb < rb:
            return true
        if lb > rb:
            return false
        index += 1
    return left.len < right.len


## Wrap an include header: standard C runtime headers use `<angle>` brackets,
## everything else uses `"quotes"` (mirrors Ruby's normalized_include_header).
function normalized_include_header(header_name: str) -> str:
    if standard_c_runtime_header(header_name):
        return strings.join_three("<", header_name, ">")
    return strings.join_three("\"", header_name, "\"")


function standard_c_runtime_header(header_name: str) -> bool:
    return (
        header_name == "stdbool.h" or header_name == "stdint.h"
        or header_name == "stdlib.h" or header_name == "string.h"
        or header_name == "stddef.h" or header_name == "stdio.h"
        or header_name == "time.h"
    )
