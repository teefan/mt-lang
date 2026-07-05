## Lowering stage — transforms the semantically-checked `Program` into an
## `ir.Program`.  This is the decoupled middle-end: it reads only the loader's
## retained per-module `Analysis` values and emits `ir`, never reaching into the
## C backend.
##
## Mirrors the Ruby Lowering entry (lib/milk_tea/core/lowering.rb `Lowering.lower`),
## its C-name mangling (lowering/utils.rb), and root-main entry-point synthesis
## (lowering/async.rb `build_root_main_entrypoint`).
##
## PHASE 1 scope: a single (root) module of plain, non-generic, non-async
## functions over scalar types — enough to lower `function main() -> int:
## return <expr>` with integer/bool literals, identifiers, unary/binary
## operators, local `let`/`var` bindings, and direct function calls.  Structs,
## generics, control flow, and multi-module assembly arrive in later phases.
##
## Because the self-host analyzer does not yet produce Ruby's rich
## FunctionBinding objects (plan prerequisite #3), lowering here walks the AST
## directly and resolves types from the retained `Analysis` (`functions` sigs and
## `resolved_expr_types`).

import std.vec as vec
import std.str
import std.string as string
import std.fmt as fmt
import std.mem.heap as heap_mod

import mtc.ir as ir
import mtc.loader.module_loader as loader
import mtc.semantic.analyzer as analyzer
import mtc.semantic.types as types
import mtc.parser.ast as ast


## A lowering-stage error.  Placeholder for Phase 1+, where lowering will fail
## loudly on unresolved (`ty_error`) nodes rather than emit a guessed type.
public struct LoweringError:
    message: str
    line: ptr_uint
    column: ptr_uint
    path: str


## A local/parameter binding in scope during function-body lowering: the source
## name, its C linkage name, resolved type, and whether it is held by pointer.
struct LocalBinding:
    name: str
    c_name: str
    ty: types.Type
    pointer: bool


struct LowerCtx:
    module_name: str
    analysis: analyzer.Analysis
    locals: vec.Vec[LocalBinding]
    temp_counter: ptr_uint


# =============================================================================
#  Public API
# =============================================================================

## Lower a checked program to IR.  In dependency-first order the root module is
## the last retained analysis; Phase 1 lowers that single module.
public function lower(program: loader.Program) -> ir.Program:
    let count = program.analyses.len()
    if count == 0:
        return ir.empty_program("(anonymous)", "")
    let root_ptr = program.analyses.get(count - 1) else:
        return ir.empty_program("(anonymous)", "")
    var root = unsafe: read(root_ptr)
    return lower_module(root)


function lower_module(analysis: analyzer.Analysis) -> ir.Program:
    var ctx = LowerCtx(
        module_name = analysis.module_name,
        analysis = analysis,
        locals = vec.Vec[LocalBinding].create(),
        temp_counter = 0,
    )
    var functions = vec.Vec[ir.Function].create()
    var enums = vec.Vec[ir.EnumDecl].create()

    var i: ptr_uint = 0
    while i < analysis.source_file.declarations.len:
        var d: ast.Decl
        unsafe:
            d = read(analysis.source_file.declarations.data + i)
        match d:
            ast.Decl.decl_function as fun:
                if lowerable_function(fun.is_async, fun.is_const, fun.type_params, fun.body):
                    functions.push(lower_function(ref_of(ctx), fun.name, fun.method_params, fun.return_type, fun.body))
                    if fun.name.equal("main"):
                        match build_root_main_entrypoint(ref_of(ctx), fun.name, fun.method_params):
                            Option.some as entry:
                                functions.push(entry.value)
                            Option.none:
                                pass
            ast.Decl.decl_enum as en:
                enums.push(lower_enum_decl(ref_of(ctx), en.name, en.backing_type, en.enum_members, false))
            ast.Decl.decl_flags as fl:
                enums.push(lower_enum_decl(ref_of(ctx), fl.name, fl.backing_type, fl.flags_members, true))
            _:
                pass
        i += 1

    return ir.Program(
        module_name = analysis.module_name,
        includes = base_includes(),
        constants = span[ir.Constant](),
        globals = span[ir.Global](),
        opaques = span[ir.OpaqueDecl](),
        structs = span[ir.StructDecl](),
        unions = span[ir.UnionDecl](),
        enums = enums.as_span(),
        variants = span[ir.VariantDecl](),
        static_asserts = span[ir.StaticAssert](),
        functions = functions.as_span(),
        source_path = "",
    )


## Phase 1 lowers only plain, non-generic, non-async functions that have a body.
function lowerable_function(is_async: bool, is_const: bool, type_params: span[ast.TypeParam], body: ptr[ast.Stmt]?) -> bool:
    if is_async:
        return false
    if type_params.len > 0:
        return false
    if body == null:
        return false
    return true


## The base C runtime includes for an ordinary module.  `<stdio.h>` is always
## present because the Ruby compiler's prelude (Option/Result) references
## `fatal`, making it universal there; the self-host matches that for byte
## parity.  Conditional `<stddef.h>` (offsetof) / `<stdlib.h>` (fatal) arrive in
## later phases.
function base_includes() -> span[ir.Include]:
    var includes = vec.Vec[ir.Include].create()
    includes.push(ir.Include(header = "<stdbool.h>"))
    includes.push(ir.Include(header = "<stdint.h>"))
    includes.push(ir.Include(header = "<string.h>"))
    includes.push(ir.Include(header = "<stdio.h>"))
    return includes.as_span()


# =============================================================================
#  Function lowering
# =============================================================================

function lower_function(ctx: ref[LowerCtx], name: str, params: span[ast.Param], return_type: ptr[ast.TypeRef]?, body: ptr[ast.Stmt]?) -> ir.Function:
    ctx.locals.clear()
    ctx.temp_counter = 0
    let sig = lookup_fn_sig(ctx, name)

    var ir_params = vec.Vec[ir.Param].create()
    var pi: ptr_uint = 0
    while pi < params.len:
        var p: ast.Param
        unsafe:
            p = read(params.data + pi)
        let param_ty = qualify_type(ctx, fn_sig_param_type(sig, pi))
        let c_name = c_local_name(p.name)
        ir_params.push(ir.Param(name = p.name, linkage_name = c_name, ty = param_ty, pointer = false))
        ctx.locals.push(LocalBinding(name = p.name, c_name = c_name, ty = param_ty, pointer = false))
        pi += 1

    let ret_ty = qualify_type(ctx, fn_sig_return_type(sig))
    let body_stmts = lower_block(ctx, body)

    return ir.Function(
        name = name,
        linkage_name = module_function_c_name(ctx.module_name, name),
        params = ir_params.as_span(),
        return_type = ret_ty,
        body = body_stmts,
        entry_point = false,
        method_receiver_param = false,
    )


## Synthesize the C entry point `int main(void)` that calls the user's root
## `main`.  Phase 1 supports only a no-parameter `main` returning `int` or
## `void` (the `:none` bridge in Ruby's build_root_main_entrypoint).
function build_root_main_entrypoint(ctx: ref[LowerCtx], name: str, params: span[ast.Param]) -> Option[ir.Function]:
    if params.len != 0:
        return Option[ir.Function].none

    let sig = lookup_fn_sig(ctx, name)
    let user_return = fn_sig_return_type(sig)
    if not (types.is_void(user_return) or is_int_type(user_return)):
        return Option[ir.Function].none

    let int_ty = types.primitive("int")
    let user_linkage = module_function_c_name(ctx.module_name, name)
    let call = alloc_expr(ir.Expr.expr_call(callee = user_linkage, arguments = span[ir.Expr](), ty = user_return))

    var body = vec.Vec[ir.Stmt].create()
    if types.is_void(user_return):
        body.push(ir.Stmt.stmt_expression(expression = call, line = 0, source_path = ""))
        let zero = alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = int_ty))
        body.push(ir.Stmt.stmt_return(value = zero, line = 0, source_path = ""))
    else:
        body.push(ir.Stmt.stmt_return(value = call, line = 0, source_path = ""))

    return Option[ir.Function].some(value = ir.Function(
        name = name,
        linkage_name = "main",
        params = span[ir.Param](),
        return_type = int_ty,
        body = body.as_span(),
        entry_point = true,
        method_receiver_param = false,
    ))


# =============================================================================
#  Statement lowering
# =============================================================================

function lower_block(ctx: ref[LowerCtx], body_ptr: ptr[ast.Stmt]?) -> span[ir.Stmt]:
    var stmts = vec.Vec[ir.Stmt].create()
    let bp = body_ptr else:
        return stmts.as_span()
    unsafe:
        match read(bp):
            ast.Stmt.stmt_block as blk:
                var i: ptr_uint = 0
                while i < blk.statements.len:
                    lower_stmt(ctx, ref_of(stmts), blk.statements.data + i)
                    i += 1
            _:
                lower_stmt(ctx, ref_of(stmts), bp)
    return stmts.as_span()


function lower_stmt(ctx: ref[LowerCtx], output: ref[vec.Vec[ir.Stmt]], sp: ptr[ast.Stmt]) -> void:
    unsafe:
        match read(sp):
            ast.Stmt.stmt_ret as r:
                let value = r.value else:
                    output.push(ir.Stmt.stmt_return(value = null, line = r.line, source_path = ""))
                    return
                let lowered = lower_expr(ctx, value)
                output.push(ir.Stmt.stmt_return(value = lowered, line = r.line, source_path = ""))
            ast.Stmt.stmt_local as loc:
                let value = loc.value else:
                    fatal(c"lowering Phase 2: local declaration without initializer is unsupported")
                let lowered_value = lower_expr(ctx, value)
                let ty = local_decl_type(ctx, loc.stmt_type, value)
                let c_name = c_local_name(loc.name)
                output.push(ir.Stmt.stmt_local(
                    name = loc.name,
                    linkage_name = c_name,
                    ty = ty,
                    value = lowered_value,
                    line = loc.line,
                    source_path = "",
                ))
                ctx.locals.push(LocalBinding(name = loc.name, c_name = c_name, ty = ty, pointer = false))
            ast.Stmt.stmt_assignment as asg:
                let target = lower_expr(ctx, asg.target)
                let value = lower_expr(ctx, asg.value)
                output.push(ir.Stmt.stmt_assignment(target = target, operator = asg.operator, value = value))
            ast.Stmt.stmt_if as iff:
                if iff.branches.len > 0:
                    output.push(lower_if_chain(ctx, iff.branches, 0, iff.else_body))
            ast.Stmt.stmt_while as w:
                let cond = lower_expr(ctx, w.condition)
                let body = lower_block(ctx, w.body)
                output.push(ir.Stmt.stmt_while(condition = cond, body = body))
            ast.Stmt.stmt_for as f:
                lower_for_range(ctx, output, f.bindings, f.iterables, f.body)
            ast.Stmt.stmt_match as m:
                lower_match(ctx, output, m.scrutinee, m.arms)
            ast.Stmt.stmt_expression as ex:
                let lowered = lower_expr(ctx, ex.expression)
                output.push(ir.Stmt.stmt_expression(expression = lowered, line = ex.line, source_path = ""))
            _:
                fatal(c"lowering Phase 2: unsupported statement")


## The declared type of a local (resolved from its annotation when present and
## scalar), else the inferred type of its initializer.
function local_decl_type(ctx: ref[LowerCtx], declared: ptr[ast.TypeRef]?, value: ptr[ast.Expr]) -> types.Type:
    let annotation = declared else:
        return qualify_type(ctx, expr_type(ctx, value))
    let resolved = resolve_scalar_type_ref(annotation)
    if types.is_error(resolved):
        return qualify_type(ctx, expr_type(ctx, value))
    return resolved


## Qualify a bare local named type (`ty_named`) with the current module so the
## backend can produce its module-prefixed C name (`State` -> `en_State`).
## Primitives, `str`, and already-qualified imported types pass through.
function qualify_type(ctx: ref[LowerCtx], t: types.Type) -> types.Type:
    match t:
        types.Type.ty_named as n:
            return types.Type.ty_imported(module_name = ctx.module_name, name = n.name)
        _:
            return t


## Lower an `if`/`else if`/`else` chain (mtc's multi-branch AST) into nested
## single-branch IR `stmt_if` nodes; the C backend re-flattens single-`if` else
## bodies back into `else if`.
function lower_if_chain(ctx: ref[LowerCtx], branches: span[ast.IfBranch], index: ptr_uint, else_body: ptr[ast.Stmt]?) -> ir.Stmt:
    var branch: ast.IfBranch
    unsafe:
        branch = read(branches.data + index)
    let cond = lower_expr(ctx, branch.condition)
    let then_body = lower_block(ctx, branch.body)

    var else_span: span[ir.Stmt]
    if index + 1 < branches.len:
        var nested = vec.Vec[ir.Stmt].create()
        nested.push(lower_if_chain(ctx, branches, index + 1, else_body))
        else_span = nested.as_span()
    else:
        else_span = lower_block(ctx, else_body)

    return ir.Stmt.stmt_if(condition = cond, then_body = then_body, else_body = else_span)


## Lower `for i in start..stop:` into a scope block holding an optional hoisted
## stop temporary and a C `for` loop.  Mirrors lowering/loops.rb
## lower_range_for_stmt, including the always-allocated (here unused) continue /
## break label temporaries so the fresh-temp counter advances identically.
function lower_for_range(ctx: ref[LowerCtx], output: ref[vec.Vec[ir.Stmt]], bindings: span[ast.ForBinding], iterables: span[ast.Expr], body_ptr: ptr[ast.Stmt]?) -> void:
    if bindings.len != 1 or iterables.len != 1:
        fatal(c"lowering Phase 2: only single-binding range for-loops are supported")

    var index_name: str
    unsafe:
        index_name = read(bindings.data + 0).name

    var start: ptr[ast.Expr]
    var stop: ptr[ast.Expr]
    unsafe:
        match read(iterables.data + 0):
            ast.Expr.expr_range as rng:
                start = rng.start_expr
                stop = rng.end_expr
            _:
                fatal(c"lowering Phase 2: for-loop over non-range iterables is unsupported")

    var loop_type = expr_type(ctx, start)
    if types.is_error(loop_type):
        loop_type = expr_type(ctx, stop)
    if types.is_error(loop_type):
        loop_type = types.primitive("int")

    let index_c = c_local_name(index_name)
    let stop_c = fresh_c_temp_name(ctx, "for_stop")
    let _continue_label = fresh_c_temp_name(ctx, "loop_continue")
    let _break_label = fresh_c_temp_name(ctx, "loop_break")

    let inline_stop = is_integer_literal(stop)

    ctx.locals.push(LocalBinding(name = index_name, c_name = index_c, ty = loop_type, pointer = false))
    let body = lower_block(ctx, body_ptr)

    let init = alloc_stmt(ir.Stmt.stmt_local(
        name = index_name,
        linkage_name = index_c,
        ty = loop_type,
        value = lower_expr(ctx, start),
        line = 0,
        source_path = "",
    ))
    let index_ref = alloc_expr(ir.Expr.expr_name(name = index_c, ty = loop_type, pointer = false))
    let stop_value = if inline_stop: lower_expr(ctx, stop) else: alloc_expr(ir.Expr.expr_name(name = stop_c, ty = loop_type, pointer = false))
    let condition = alloc_expr(ir.Expr.expr_binary(operator = "<", left = index_ref, right = stop_value, ty = types.primitive("bool")))
    let post_target = alloc_expr(ir.Expr.expr_name(name = index_c, ty = loop_type, pointer = false))
    let one = alloc_expr(ir.Expr.expr_integer_literal(value = 1, ty = loop_type))
    let post = alloc_stmt(ir.Stmt.stmt_assignment(target = post_target, operator = "+=", value = one))
    let for_stmt = ir.Stmt.stmt_for(init = init, condition = condition, post = post, body = body)

    var block_stmts = vec.Vec[ir.Stmt].create()
    if not inline_stop:
        block_stmts.push(ir.Stmt.stmt_local(
            name = stop_c,
            linkage_name = stop_c,
            ty = loop_type,
            value = lower_expr(ctx, stop),
            line = 0,
            source_path = "",
        ))
    block_stmts.push(for_stmt)
    output.push(ir.Stmt.stmt_block(body = block_stmts.as_span()))


function is_integer_literal(ep: ptr[ast.Expr]) -> bool:
    unsafe:
        match read(ep):
            ast.Expr.expr_integer_literal:
                return true
            _:
                return false


function fresh_c_temp_name(ctx: ref[LowerCtx], prefix: str) -> str:
    ctx.temp_counter += 1
    var buf = string.String.create()
    buf.append("__mt_")
    buf.append(prefix)
    buf.append("_")
    fmt.append_ptr_uint(ref_of(buf), ctx.temp_counter)
    return buf.as_str()


# =============================================================================
#  Expression lowering
# =============================================================================

function lower_expr(ctx: ref[LowerCtx], ep: ptr[ast.Expr]) -> ptr[ir.Expr]:
    unsafe:
        match read(ep):
            ast.Expr.expr_integer_literal as lit:
                return alloc_expr(ir.Expr.expr_integer_literal(value = long<-lit.value, ty = expr_type(ctx, ep)))
            ast.Expr.expr_bool_literal as b:
                return alloc_expr(ir.Expr.expr_boolean_literal(value = b.value, ty = types.primitive("bool")))
            ast.Expr.expr_identifier as id:
                match lookup_local(ctx, id.name):
                    Option.some as lb:
                        return alloc_expr(ir.Expr.expr_name(name = lb.value.c_name, ty = lb.value.ty, pointer = lb.value.pointer))
                    Option.none:
                        return alloc_expr(ir.Expr.expr_name(name = id.name, ty = expr_type(ctx, ep), pointer = false))
            ast.Expr.expr_binary_op as bin:
                let left = lower_expr(ctx, bin.left)
                let right = lower_expr(ctx, bin.right)
                return alloc_expr(ir.Expr.expr_binary(operator = bin.operator, left = left, right = right, ty = expr_type(ctx, ep)))
            ast.Expr.expr_unary_op as un:
                let operand = lower_expr(ctx, un.operand)
                return alloc_expr(ir.Expr.expr_unary(operator = un.operator, operand = operand, ty = expr_type(ctx, ep)))
            ast.Expr.expr_call as call:
                return lower_call(ctx, call.callee, call.args, ep)
            ast.Expr.expr_member_access as ma:
                return lower_member_access(ctx, ma.receiver, ma.member_name, ep)
            _:
                fatal(c"lowering Phase 2: unsupported expression")


function lower_call(ctx: ref[LowerCtx], callee: ptr[ast.Expr], args: span[ast.Argument], call_ep: ptr[ast.Expr]) -> ptr[ir.Expr]:
    unsafe:
        match read(callee):
            ast.Expr.expr_identifier as id:
                var ir_args = vec.Vec[ir.Expr].create()
                var i: ptr_uint = 0
                while i < args.len:
                    let arg = read(args.data + i)
                    let lowered = lower_expr(ctx, arg.arg_value)
                    ir_args.push(read(lowered))
                    i += 1
                return alloc_expr(ir.Expr.expr_call(
                    callee = module_function_c_name(ctx.module_name, id.name),
                    arguments = ir_args.as_span(),
                    ty = expr_type(ctx, call_ep),
                ))
            _:
                fatal(c"lowering Phase 2: only direct function calls are supported")


## Phase 2 member access: enum / flags member constants on a type-name receiver
## (`State.running` -> `en_State_running`).  Struct field access and other member
## forms arrive in Phase 3.
function lower_member_access(ctx: ref[LowerCtx], receiver: ptr[ast.Expr], member: str, ep: ptr[ast.Expr]) -> ptr[ir.Expr]:
    unsafe:
        match read(receiver):
            ast.Expr.expr_identifier as id:
                if ctx.analysis.static_member_types.contains(id.name):
                    return alloc_expr(ir.Expr.expr_name(
                        name = enum_member_c_name(ctx.module_name, id.name, member),
                        ty = expr_type(ctx, ep),
                        pointer = false,
                    ))
            _:
                pass
    fatal(c"lowering Phase 2: unsupported member access")


# =============================================================================
#  Enum / flags declarations
# =============================================================================

function lower_enum_decl(ctx: ref[LowerCtx], name: str, backing_type: ptr[ast.TypeRef]?, members: span[ast.EnumMember], is_flags: bool) -> ir.EnumDecl:
    var backing = types.primitive("int")
    let annotation = backing_type
    if annotation != null:
        let resolved = resolve_scalar_type_ref(annotation)
        if not types.is_error(resolved):
            backing = resolved

    let enum_linkage = module_function_c_name(ctx.module_name, name)
    var ir_members = vec.Vec[ir.EnumMember].create()
    var next_auto: long = 0

    var i: ptr_uint = 0
    while i < members.len:
        var m: ast.EnumMember
        unsafe:
            m = read(members.data + i)
        let member_linkage = enum_member_c_name(ctx.module_name, name, m.name)
        var value_expr: ptr[ir.Expr]
        let explicit = m.value
        if explicit != null:
            value_expr = lower_expr(ctx, explicit)
            next_auto = const_eval_int(explicit) + 1
        else:
            value_expr = alloc_expr(ir.Expr.expr_integer_literal(value = next_auto, ty = backing))
            next_auto += 1
        ir_members.push(ir.EnumMember(name = m.name, linkage_name = member_linkage, value = value_expr))
        i += 1

    return ir.EnumDecl(
        name = name,
        linkage_name = enum_linkage,
        backing_type = backing,
        members = ir_members.as_span(),
        is_flags = is_flags,
    )


function enum_member_c_name(module_name: str, type_name: str, member: str) -> str:
    var buf = string.String.create()
    buf.append(module_c_prefix(module_name))
    buf.append("_")
    buf.append(type_name)
    buf.append("_")
    buf.append(member)
    return buf.as_str()


## Compile-time integer evaluation for enum/flags member values (literals plus
## the arithmetic/bitwise/shift operators used in flag definitions).  Used only
## to advance the auto-increment counter after an explicit member value.
function const_eval_int(ep: ptr[ast.Expr]) -> long:
    unsafe:
        match read(ep):
            ast.Expr.expr_integer_literal as lit:
                return long<-lit.value
            ast.Expr.expr_char_literal as ch:
                return long<-ch.value
            ast.Expr.expr_unary_op as un:
                let v = const_eval_int(un.operand)
                if un.operator == "-":
                    return -v
                if un.operator == "~":
                    return ~v
                return v
            ast.Expr.expr_binary_op as bin:
                let l = const_eval_int(bin.left)
                let r = const_eval_int(bin.right)
                if bin.operator == "+":
                    return l + r
                if bin.operator == "-":
                    return l - r
                if bin.operator == "*":
                    return l * r
                if bin.operator == "/":
                    return l / r
                if bin.operator == "%":
                    return l % r
                if bin.operator == "<<":
                    return l << r
                if bin.operator == ">>":
                    return l >> r
                if bin.operator == "|":
                    return l | r
                if bin.operator == "&":
                    return l & r
                if bin.operator == "^":
                    return l ^ r
                return 0
            _:
                return 0


# =============================================================================
#  Match (enum scrutinee) -> switch
# =============================================================================

## Lower a `match` over an enum/flags scrutinee into an IR `stmt_switch`.  Each
## `EnumType.member` arm becomes a `case`; a `_` arm becomes the `default`.  With
## no `_` arm the switch is exhaustive (the backend adds `__builtin_unreachable`).
## Integer/str/variant/tuple scrutinees arrive in later phases.
function lower_match(ctx: ref[LowerCtx], output: ref[vec.Vec[ir.Stmt]], scrutinee: ptr[ast.Expr], arms: span[ast.MatchArm]) -> void:
    let scrutinee_expr = lower_expr(ctx, scrutinee)
    let enum_name = named_type_name(expr_type(ctx, scrutinee)) else:
        fatal(c"lowering Phase 2: match is only supported over enum/flags scrutinees")

    var cases = vec.Vec[ir.SwitchCase].create()
    var has_wildcard = false
    var i: ptr_uint = 0
    while i < arms.len:
        var arm: ast.MatchArm
        unsafe:
            arm = read(arms.data + i)
        let body = lower_block(ctx, arm.body)
        let pattern = arm.pattern
        if pattern == null:
            has_wildcard = true
            cases.push(ir.SwitchCase(is_default = true, value = null, body = body))
        else:
            let member = match_member_name(pattern) else:
                fatal(c"lowering Phase 2: unsupported match pattern")
            let value = alloc_expr(ir.Expr.expr_name(
                name = enum_member_c_name(ctx.module_name, enum_name, member),
                ty = expr_type(ctx, scrutinee),
                pointer = false,
            ))
            cases.push(ir.SwitchCase(is_default = false, value = value, body = body))
        i += 1

    output.push(ir.Stmt.stmt_switch(expression = scrutinee_expr, cases = cases.as_span(), exhaustive = not has_wildcard))


function match_member_name(pattern: ptr[ast.Expr]) -> Option[str]:
    unsafe:
        match read(pattern):
            ast.Expr.expr_member_access as ma:
                return Option[str].some(value = ma.member_name)
            _:
                return Option[str].none


function named_type_name(t: types.Type) -> Option[str]:
    match t:
        types.Type.ty_named as n:
            return Option[str].some(value = n.name)
        types.Type.ty_imported as im:
            return Option[str].some(value = im.name)
        _:
            return Option[str].none


# =============================================================================
#  Type resolution helpers
# =============================================================================

function lookup_fn_sig(ctx: ref[LowerCtx], name: str) -> Option[analyzer.FnSig]:
    let sig_ptr = ctx.analysis.functions.get(name)
    if sig_ptr == null:
        return Option[analyzer.FnSig].none
    unsafe:
        return Option[analyzer.FnSig].some(value = read(sig_ptr))


function fn_sig_param_type(sig: Option[analyzer.FnSig], index: ptr_uint) -> types.Type:
    match sig:
        Option.some as s:
            if index < s.value.params.len:
                unsafe:
                    return read(s.value.params.data + index).ty
            return types.Type.ty_error
        Option.none:
            return types.Type.ty_error


function fn_sig_return_type(sig: Option[analyzer.FnSig]) -> types.Type:
    match sig:
        Option.some as s:
            if s.value.has_return_type:
                return s.value.return_type
            return types.primitive("void")
        Option.none:
            return types.primitive("void")


## The resolved type of an AST expression: the analyzer's recorded type (keyed by
## node pointer identity, matching `record_expr_type`), or a structural fallback.
function expr_type(ctx: ref[LowerCtx], ep: ptr[ast.Expr]) -> types.Type:
    let key = unsafe: reinterpret[ptr_uint](ep)
    let tp = ctx.analysis.resolved_expr_types.get(key)
    if tp != null:
        unsafe:
            return read(tp)
    return fallback_type(ctx, ep)


function fallback_type(ctx: ref[LowerCtx], ep: ptr[ast.Expr]) -> types.Type:
    unsafe:
        match read(ep):
            ast.Expr.expr_integer_literal:
                return types.primitive("int")
            ast.Expr.expr_bool_literal:
                return types.primitive("bool")
            ast.Expr.expr_identifier as id:
                match lookup_local(ctx, id.name):
                    Option.some as lb:
                        return lb.value.ty
                    Option.none:
                        return types.Type.ty_error
            ast.Expr.expr_binary_op as bin:
                if is_comparison_operator(bin.operator):
                    return types.primitive("bool")
                return fallback_type(ctx, bin.left)
            ast.Expr.expr_unary_op as un:
                return fallback_type(ctx, un.operand)
            ast.Expr.expr_call as call:
                match read(call.callee):
                    ast.Expr.expr_identifier as id:
                        return fn_sig_return_type(lookup_fn_sig(ctx, id.name))
                    _:
                        return types.Type.ty_error
            _:
                return types.Type.ty_error


function is_comparison_operator(op: str) -> bool:
    return (
        op == "==" or op == "!=" or op == "<" or op == "<=" or op == ">" or op == ">="
        or op == "and" or op == "or"
    )


function is_int_type(t: types.Type) -> bool:
    match t:
        types.Type.ty_primitive as p:
            return p.name.equal("int")
        _:
            return false


function lookup_local(ctx: ref[LowerCtx], name: str) -> Option[LocalBinding]:
    if ctx.locals.len() == 0:
        return Option[LocalBinding].none
    var i = ctx.locals.len()
    while i > 0:
        i -= 1
        let lb_ptr = ctx.locals.get(i) else:
            break
        unsafe:
            if read(lb_ptr).name.equal(name):
                return Option[LocalBinding].some(value = read(lb_ptr))
    return Option[LocalBinding].none


# =============================================================================
#  C-name mangling (mirrors lowering/utils.rb)
# =============================================================================

function module_function_c_name(module_name: str, name: str) -> str:
    var buf = string.String.create()
    buf.append(module_c_prefix(module_name))
    buf.append("_")
    buf.append(name)
    return buf.as_str()


function module_c_prefix(module_name: str) -> str:
    return sanitize_identifier(module_name)


## C-safe local/parameter name: sanitized, with a trailing `_` when it collides
## with a C reserved word.
function c_local_name(name: str) -> str:
    let identifier = sanitize_identifier(name)
    if c_reserved_identifier(identifier):
        var buf = string.String.create()
        buf.append(identifier)
        buf.append("_")
        return buf.as_str()
    return identifier


## Replace every maximal run of non-alphanumeric characters (and underscores)
## with a single `_`, strip a trailing `_`, and map the empty result to
## `value` — matching Ruby's sanitize_identifier.
function sanitize_identifier(text: str) -> str:
    var buf = string.String.create()
    var prev_underscore = false
    var i: ptr_uint = 0
    while i < text.len:
        let b = text.byte_at(i)
        if is_alnum_byte(b):
            buf.push_byte(b)
            prev_underscore = false
        else:
            if not prev_underscore:
                buf.push_byte('_')
                prev_underscore = true
        i += 1

    var result = buf.as_str()
    if result.len > 0 and result.byte_at(result.len - 1) == '_':
        result = result.slice(0, result.len - 1)
    if result.len == 0:
        return "value"
    return result


function is_alnum_byte(b: ubyte) -> bool:
    return (b >= '0' and b <= '9') or (b >= 'A' and b <= 'Z') or (b >= 'a' and b <= 'z')


function c_reserved_identifier(identifier: str) -> bool:
    let words = reserved_words()
    var i: ptr_uint = 0
    while i < words.len:
        unsafe:
            if read(words.data + i).equal(identifier):
                return true
        i += 1
    return false


const RESERVED_WORD_COUNT: ptr_uint = 44
const RESERVED_WORDS: array[str, 44] = array[str, 44](
    "auto", "break", "case", "char", "const", "continue", "default", "do",
    "double", "else", "enum", "extern", "float", "for", "goto", "if", "inline",
    "int", "long", "register", "restrict", "return", "short", "signed",
    "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned",
    "void", "volatile", "while", "_Alignas", "_Alignof", "_Atomic", "_Bool",
    "_Complex", "_Generic", "_Imaginary", "_Noreturn", "_Static_assert",
    "_Thread_local"
)


function reserved_words() -> span[str]:
    return RESERVED_WORDS.as_span()


# =============================================================================
#  IR allocation
# =============================================================================

function alloc_expr(value: ir.Expr) -> ptr[ir.Expr]:
    var node = heap_mod.must_alloc[ir.Expr](1)
    unsafe:
        read(node) = value
    return node


function alloc_stmt(value: ir.Stmt) -> ptr[ir.Stmt]:
    var node = heap_mod.must_alloc[ir.Stmt](1)
    unsafe:
        read(node) = value
    return node


## Resolve a scalar type annotation (primitive or `str`) to a `types.Type`.
## Returns `ty_error` for compound/nullable/callable forms not handled in the
## current phase, signalling the caller to fall back to the initializer type.
function resolve_scalar_type_ref(declared: ptr[ast.TypeRef]) -> types.Type:
    unsafe:
        let t = read(declared)
        if t.is_fn or t.is_proc or t.is_dyn or t.is_tuple or t.nullable:
            return types.Type.ty_error
        if t.arguments.len > 0:
            return types.Type.ty_error
        if t.name.parts.len != 1:
            return types.Type.ty_error
        let name = read(t.name.parts.data + 0)
        if name.equal("str"):
            return types.Type.ty_str
        if is_primitive_name(name):
            return types.primitive(name)
        return types.Type.ty_error


function is_primitive_name(name: str) -> bool:
    return (
        name.equal("bool") or name.equal("byte") or name.equal("ubyte") or name.equal("char")
        or name.equal("short") or name.equal("ushort") or name.equal("int") or name.equal("uint")
        or name.equal("long") or name.equal("ulong") or name.equal("ptr_int") or name.equal("ptr_uint")
        or name.equal("float") or name.equal("double") or name.equal("void") or name.equal("cstr")
    )
