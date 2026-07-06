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
import std.map as map_mod
import std.str
import std.string as string
import std.fmt as fmt
import std.mem.heap as heap_mod

import mtc.ir as ir
import mtc.loader.module_loader as loader
import mtc.semantic.analyzer as analyzer
import mtc.semantic.types as types
import mtc.parser.ast as ast
import mtc.c_naming as naming


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


## A foreign function's lowering info: the C function it maps to, its return
## type, and its declared parameters (carrying `as cstr` boundary projections).
struct ForeignInfo:
    c_name: str
    return_ty: types.Type
    params: span[ast.ForeignParam]


struct LowerCtx:
    module_name: str
    analysis: analyzer.Analysis
    locals: vec.Vec[LocalBinding]
    temp_counter: ptr_uint
    foreign_map: map_mod.Map[str, ForeignInfo]
    extern_map: map_mod.Map[str, str]


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
        foreign_map = map_mod.Map[str, ForeignInfo].create(),
        extern_map = map_mod.Map[str, str].create(),
    )
    collect_foreign_functions(ref_of(ctx), analysis.source_file.declarations)
    var functions = vec.Vec[ir.Function].create()
    var enums = vec.Vec[ir.EnumDecl].create()
    var structs = vec.Vec[ir.StructDecl].create()
    var unions = vec.Vec[ir.UnionDecl].create()

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
            ast.Decl.decl_struct as s:
                match lower_struct_decl(ref_of(ctx), s.name):
                    Option.some as sd:
                        structs.push(sd.value)
                    Option.none:
                        pass
            ast.Decl.decl_union as u:
                unions.push(lower_union_decl(ref_of(ctx), u.name, u.union_fields))
            _:
                pass
        i += 1

    return ir.Program(
        module_name = analysis.module_name,
        includes = base_includes(),
        constants = span[ir.Constant](),
        globals = span[ir.Global](),
        opaques = span[ir.OpaqueDecl](),
        structs = structs.as_span(),
        unions = unions.as_span(),
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
        linkage_name = naming.qualified_c_name(ctx.module_name, name),
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
    let user_linkage = naming.qualified_c_name(ctx.module_name, name)
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
                let c_name = c_local_name(loc.name)
                var ty: types.Type
                var value_expr: ptr[ir.Expr]
                let init = loc.value
                if init == null:
                    let declared = loc.stmt_type else:
                        fatal(c"lowering Phase 3: local without initializer requires a type")
                    ty = resolve_field_type_ref(ctx, read(declared))
                    value_expr = alloc_expr(ir.Expr.expr_zero_init(ty = ty))
                else:
                    value_expr = lower_expr(ctx, init)
                    ty = local_decl_type(ctx, loc.stmt_type, init)
                output.push(ir.Stmt.stmt_local(
                    name = loc.name,
                    linkage_name = c_name,
                    ty = ty,
                    value = value_expr,
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
            ast.Expr.expr_string_literal as lit:
                let ty = if lit.is_cstring: types.primitive("cstr") else: types.Type.ty_str
                return alloc_expr(ir.Expr.expr_string_literal(value = lit.value, ty = ty, cstring = lit.is_cstring))
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
                if id.name.equal("fatal"):
                    return lower_plain_call(ctx, "mt_fatal", args, call_ep)
                if ctx.analysis.structs.contains(id.name):
                    return lower_aggregate_literal(ctx, id.name, args)
                let foreign_ptr = ctx.foreign_map.get(id.name)
                if foreign_ptr != null:
                    return lower_foreign_call(ctx, read(foreign_ptr), args, call_ep)
                let extern_ptr = ctx.extern_map.get(id.name)
                if extern_ptr != null:
                    return lower_plain_call(ctx, read(extern_ptr), args, call_ep)
                return lower_plain_call(ctx, naming.qualified_c_name(ctx.module_name, id.name), args, call_ep)
            _:
                fatal(c"lowering Phase 2: only direct function calls are supported")


## Lower a struct constructor `Name(field = value, ...)` to an IR aggregate
## literal, preserving the constructor's field order.
function lower_aggregate_literal(ctx: ref[LowerCtx], struct_name: str, args: span[ast.Argument]) -> ptr[ir.Expr]:
    var fields = vec.Vec[ir.AggregateField].create()
    var i: ptr_uint = 0
    while i < args.len:
        var arg: ast.Argument
        unsafe:
            arg = read(args.data + i)
        let field_name = arg.arg_name else:
            fatal(c"lowering Phase 3: struct construction requires named fields")
        let value = lower_expr(ctx, arg.arg_value)
        fields.push(ir.AggregateField(name = field_name, value = value))
        i += 1
    return alloc_expr(ir.Expr.expr_aggregate_literal(
        ty = types.Type.ty_imported(module_name = ctx.module_name, name = struct_name),
        fields = fields.as_span(),
    ))


## Lower a call with no boundary projections: every argument lowered as-is.
function lower_plain_call(ctx: ref[LowerCtx], c_name: str, args: span[ast.Argument], call_ep: ptr[ast.Expr]) -> ptr[ir.Expr]:
    var ir_args = vec.Vec[ir.Expr].create()
    var i: ptr_uint = 0
    while i < args.len:
        var arg: ast.Argument
        unsafe:
            arg = read(args.data + i)
        let lowered = lower_expr(ctx, arg.arg_value)
        unsafe:
            ir_args.push(read(lowered))
        i += 1
    return alloc_expr(ir.Expr.expr_call(callee = c_name, arguments = ir_args.as_span(), ty = expr_type(ctx, call_ep)))


## Lower a foreign function call to a direct call on its mapped C function,
## applying `as cstr` boundary projections to arguments.  Phase 2d supports
## string-literal arguments at an `as cstr` boundary (emitted as a C string
## literal); str-variable projection (runtime str->cstr) and in/out/inout/
## consuming modes arrive later.
function lower_foreign_call(ctx: ref[LowerCtx], info: ForeignInfo, args: span[ast.Argument], call_ep: ptr[ast.Expr]) -> ptr[ir.Expr]:
    var ir_args = vec.Vec[ir.Expr].create()
    var i: ptr_uint = 0
    while i < args.len:
        var arg: ast.Argument
        unsafe:
            arg = read(args.data + i)
        var lowered: ptr[ir.Expr]
        if i < info.params.len:
            var param: ast.ForeignParam
            unsafe:
                param = read(info.params.data + i)
            lowered = lower_foreign_arg(ctx, param, arg.arg_value)
        else:
            lowered = lower_expr(ctx, arg.arg_value)
        unsafe:
            ir_args.push(read(lowered))
        i += 1
    return alloc_expr(ir.Expr.expr_call(callee = info.c_name, arguments = ir_args.as_span(), ty = expr_type(ctx, call_ep)))


function lower_foreign_arg(ctx: ref[LowerCtx], param: ast.ForeignParam, arg: ptr[ast.Expr]) -> ptr[ir.Expr]:
    match param.boundary_type:
        Option.some as boundary:
            if boundary_is_cstr(boundary.value):
                unsafe:
                    match read(arg):
                        ast.Expr.expr_string_literal as lit:
                            return alloc_expr(ir.Expr.expr_string_literal(value = lit.value, ty = types.primitive("cstr"), cstring = true))
                        _:
                            fatal(c"lowering Phase 2d: only string-literal arguments are supported at an 'as cstr' boundary")
            return lower_expr(ctx, arg)
        Option.none:
            return lower_expr(ctx, arg)


function boundary_is_cstr(boundary: ast.TypeRef) -> bool:
    if boundary.name.parts.len != 1:
        return false
    unsafe:
        return read(boundary.name.parts.data + 0).equal("cstr")


# =============================================================================
#  Foreign / external function registry
# =============================================================================

## Pre-scan declarations to map each external function to its C name and each
## foreign function to its mapped C function and boundary parameters, so calls
## can be lowered to direct C calls.
function collect_foreign_functions(ctx: ref[LowerCtx], decls: span[ast.Decl]) -> void:
    var i: ptr_uint = 0
    while i < decls.len:
        var d: ast.Decl
        unsafe:
            d = read(decls.data + i)
        match d:
            ast.Decl.decl_extern_function as ef:
                ctx.extern_map.set(ef.name, extern_c_name(ef.name, ef.mapping))
            _:
                pass
        i += 1

    i = 0
    while i < decls.len:
        var d: ast.Decl
        unsafe:
            d = read(decls.data + i)
        match d:
            ast.Decl.decl_foreign_function as ff:
                ctx.foreign_map.set(ff.name, ForeignInfo(
                    c_name = resolve_foreign_c_name(ctx, ff.mapping),
                    return_ty = qualify_type(ctx, resolve_scalar_type_ref(ff.return_type)),
                    params = ff.foreign_params,
                ))
            _:
                pass
        i += 1


## The C name an external function maps to: its explicit `= c.name` mapping value
## when present, else the declaration name itself.
function extern_c_name(name: str, mapping: ptr[ast.Expr]?) -> str:
    let m = mapping else:
        return name
    unsafe:
        match read(m):
            ast.Expr.expr_identifier as id:
                return id.name
            ast.Expr.expr_member_access as ma:
                return ma.member_name
            ast.Expr.expr_string_literal as s:
                return s.value
            _:
                return name


## The C name a foreign function maps to: resolve its `= target` identifier
## through the external registry (so `= atoi` yields the external's C name),
## falling back to the target name.
function resolve_foreign_c_name(ctx: ref[LowerCtx], mapping: ptr[ast.Expr]) -> str:
    unsafe:
        match read(mapping):
            ast.Expr.expr_identifier as id:
                let ext = ctx.extern_map.get(id.name)
                if ext != null:
                    return read(ext)
                return id.name
            ast.Expr.expr_member_access as ma:
                return ma.member_name
            _:
                fatal(c"lowering Phase 2d: unsupported foreign function mapping")


## Member access: enum / flags member constants on a type-name receiver
## (`State.running` -> `en_State_running`), otherwise a struct field access
## (`p.x`).  Method calls and other member forms arrive in later phases.
function lower_member_access(ctx: ref[LowerCtx], receiver: ptr[ast.Expr], member: str, ep: ptr[ast.Expr]) -> ptr[ir.Expr]:
    unsafe:
        match read(receiver):
            ast.Expr.expr_identifier as id:
                if ctx.analysis.static_member_types.contains(id.name):
                    return alloc_expr(ir.Expr.expr_name(
                        name = naming.qualified_member_c_name(ctx.module_name, id.name, member),
                        ty = expr_type(ctx, ep),
                        pointer = false,
                    ))
            _:
                pass
    let recv = lower_expr(ctx, receiver)
    return alloc_expr(ir.Expr.expr_member(
        receiver = recv,
        member = member,
        ty = qualify_type(ctx, expr_type(ctx, ep)),
    ))


## Lower a struct declaration to an IR StructDecl, resolving its fields from the
## analyzer's struct table (which carries resolved field types) and qualifying
## named field types with the current module for backend C-naming.
function lower_struct_decl(ctx: ref[LowerCtx], name: str) -> Option[ir.StructDecl]:
    let fields_ptr = ctx.analysis.structs.get(name) else:
        return Option[ir.StructDecl].none
    let entries = unsafe: read(fields_ptr)
    var ir_fields = vec.Vec[ir.Field].create()
    var i: ptr_uint = 0
    while i < entries.len:
        var entry: analyzer.FieldEntry
        unsafe:
            entry = read(entries.data + i)
        ir_fields.push(ir.Field(name = entry.name, ty = qualify_type(ctx, entry.ty)))
        i += 1
    return Option[ir.StructDecl].some(value = ir.StructDecl(
        name = name,
        linkage_name = naming.qualified_c_name(ctx.module_name, name),
        fields = ir_fields.as_span(),
        packed = false,
        alignment = 0,
        source_module = Option[str].none,
    ))


## Lower a union declaration to an IR UnionDecl, resolving field types from the
## declaration (unions are not tracked in the analyzer's struct table).
function lower_union_decl(ctx: ref[LowerCtx], name: str, fields: span[ast.Field]) -> ir.UnionDecl:
    var ir_fields = vec.Vec[ir.Field].create()
    var i: ptr_uint = 0
    while i < fields.len:
        var f: ast.Field
        unsafe:
            f = read(fields.data + i)
        ir_fields.push(ir.Field(name = f.name, ty = resolve_field_type_ref(ctx, f.field_type)))
        i += 1
    return ir.UnionDecl(
        name = name,
        linkage_name = naming.qualified_c_name(ctx.module_name, name),
        fields = ir_fields.as_span(),
        source_module = Option[str].none,
    )


## Resolve a field/local type annotation to a `types.Type`: scalars via
## `resolve_scalar_type_ref`, and single-name local types (structs/unions/enums)
## to a module-qualified `ty_imported`.  Compound types (arrays/spans/generics)
## resolve later.
function resolve_field_type_ref(ctx: ref[LowerCtx], tref: ast.TypeRef) -> types.Type:
    var local_tref = tref
    let scalar = resolve_scalar_type_ref(ptr_of(local_tref))
    if not types.is_error(scalar):
        return scalar
    if tref.is_fn or tref.is_proc or tref.is_dyn or tref.is_tuple or tref.nullable or tref.arguments.len > 0:
        return types.Type.ty_error
    if tref.name.parts.len != 1:
        return types.Type.ty_error
    let name = unsafe: read(tref.name.parts.data + 0)
    if ctx.analysis.type_names.contains(name):
        return types.Type.ty_imported(module_name = ctx.module_name, name = name)
    return types.Type.ty_error


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

    let enum_linkage = naming.qualified_c_name(ctx.module_name, name)
    var ir_members = vec.Vec[ir.EnumMember].create()
    var next_auto: long = 0

    var i: ptr_uint = 0
    while i < members.len:
        var m: ast.EnumMember
        unsafe:
            m = read(members.data + i)
        let member_linkage = naming.qualified_member_c_name(ctx.module_name, name, m.name)
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
                name = naming.qualified_member_c_name(ctx.module_name, enum_name, member),
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
## A recorded `ty_error` is treated as unresolved so lowering can recover it
## (e.g. foreign-function call return types the analyzer does not track).
function expr_type(ctx: ref[LowerCtx], ep: ptr[ast.Expr]) -> types.Type:
    let key = unsafe: reinterpret[ptr_uint](ep)
    let tp = ctx.analysis.resolved_expr_types.get(key)
    if tp != null:
        let recorded = unsafe: read(tp)
        if not types.is_error(recorded):
            return recorded
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
                        let foreign_ptr = ctx.foreign_map.get(id.name)
                        if foreign_ptr != null:
                            return read(foreign_ptr).return_ty
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

## C-safe local/parameter name: sanitized, with a trailing `_` when it collides
## with a C reserved word.
function c_local_name(name: str) -> str:
    let identifier = naming.sanitize_identifier(name)
    if c_reserved_identifier(identifier):
        var buf = string.String.create()
        buf.append(identifier)
        buf.append("_")
        return buf.as_str()
    return identifier


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
