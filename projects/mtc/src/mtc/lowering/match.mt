## Match lowering and variant arm introspection — scalar/string/tuple/enum/
## variant match lowering, plus the variant arm/payload helpers it shares with
## the declaration path.  Extracted from lowering/lowering.mt.  The generic
## `stmts_terminate`, `contains_label_target`, `append_span_stmts`,
## `current_return_type`, `fatal_arg_is_cstr`, `is_integer_scrutinee` and
## `named_type_name` helpers stay in lowering.

import std.vec as vec
import std.map as map_mod
import std.str
import std.string as string
import std.fmt as fmt

import mtc.ir as ir
import mtc.parser.ast as ast
import mtc.semantic.analyzer as analyzer
import mtc.semantic.types as types
import mtc.c_naming as naming

import mtc.lowering.async_cps as async_cps
import mtc.lowering.lowering as lowering
import mtc.lowering.type_helpers as type_helpers
import mtc.lowering.utils as utils
import mtc.strings


## Lower a `match` over an enum/flags scrutinee into an IR `stmt_switch`.  Each
## `EnumType.member` arm becomes a `case`; a `_` arm becomes the `default`.  The
## switch is marked exhaustive (the host does so for every match switch; the
## backend adds `__builtin_unreachable` only when there is no default).
## Integer, string, variant, and tuple scrutinees are handled by the
## type-dispatch branches within `lower_match`.
function enum_source_module(ctx: ref[lowering.LoweringContext], ty: types.Type, default_module: str) -> str:
    match ty:
        types.Type.ty_imported as im:
            return im.module_name
        _:
            return default_module

## The C name a match-arm reference to `Enum.member` uses.  A raw (external)
## module's enum is the C header's enum, whose members are the bare enumerators
## (the module emits no scoped constants), so the member name is used as-is;
## mt-declared enums use the module-scoped constant
## (`<module>_<Enum>_<member>`), mirroring Ruby's `imported_value_c_name`
## raw-module rule.
function enum_member_reference_c_name(ctx: ref[lowering.LoweringContext], enum_module: str, enum_name: str, member: str) -> str:
    if enum_module.len > 0 and module_is_raw(ctx, enum_module):
        return member
    return naming.qualified_member_c_name(enum_module, enum_name, member)


## True when `module_name`'s analysis is a raw (external) module.
function module_is_raw(ctx: ref[lowering.LoweringContext], module_name: str) -> bool:
    if module_name == ctx.module_name:
        return lowering.is_raw_module(ctx.analysis.module_kind)
    match lowering.find_imported_analysis(ctx, module_name):
        Option.some as imported:
            return lowering.is_raw_module(imported.value.module_kind)
        Option.none:
            return false


## Lower a match arm's body when the match is a C `switch`.  The host's
## `switch_loop_flow`/`switch_loop_target` convert both a `break` and a
## `continue` to the loop-label form inside a switch (a C `break` would exit the
## switch, and the host never relies on `continue` passing through one), so both
## native flags are cleared here.
function lower_switch_arm_body(ctx: ref[lowering.LoweringContext], body: ptr[ast.Stmt]?) -> span[ir.Stmt]:
    let saved_break_native = ctx.loop_break_native
    let saved_continue_native = ctx.loop_continue_native
    ctx.loop_break_native = false
    ctx.loop_continue_native = false
    let result = lowering.lower_block(ctx, body)
    ctx.loop_continue_native = saved_continue_native
    ctx.loop_break_native = saved_break_native
    return result


public function lower_match(ctx: ref[lowering.LoweringContext], output: ref[vec.Vec[ir.Stmt]], scrutinee: ptr[ast.Expr], arms: span[ast.MatchArm]) -> void:
    # Save/restore locals so match-arm bindings (as name) and arm-body
    # locals don't leak into subsequent code or proc captures.
    let saved_locals = ctx.locals
    ctx.locals = vec.Vec[lowering.LocalBinding].create()
    var li: ptr_uint = 0
    while li < saved_locals.len():
        let lb_ptr = saved_locals.get(li) else:
            break
        unsafe:
            ctx.locals.push(read(lb_ptr))
        li += 1
    # The host's `lower_match_stmt` prepares the scrutinee with the statement's
    # window, lowers it once, and appends its cleanups after the match
    # (`block.rb:838-845,924`).  A proc argument therefore materializes before
    # the `match_value` temp; reusing the same IR node keeps the single
    # evaluation's proc ids/temps/instantiations.
    let had_window = ctx.hoist_mode != lowering.HoistMode.hm_off
    let window_saved = lowering.begin_stmt_setup(ctx, lowering.HoistMode.hm_value)
    let scrutinee_expr = lowering.lower_expr(ctx, scrutinee)
    let window_collected = lowering.collect_stmt_setup(ctx, window_saved)
    if had_window:
        lowering.append_span_stmts(ref_of(ctx.hoist_stmts), window_collected.stmts.as_span())
        lowering.append_span_stmts(ref_of(ctx.hoist_cleanups), window_collected.cleanups.as_span())
    else:
        lowering.append_span_stmts(output, window_collected.stmts.as_span())
        defer: lowering.append_span_stmts(output, window_collected.cleanups.as_span())
    var scrutinee_ty = type_helpers.expr_type(ctx, scrutinee)
    let lowered_ty = lowering.ir_expr_type(scrutinee_expr)
    if not types.is_error(lowered_ty) and not types.type_to_string(lowered_ty) == "void":
        scrutinee_ty = lowered_ty
    let type_name = lowering.named_type_name(scrutinee_ty)

    if type_name.is_some() and ctx.variants.contains(variant_registry_key(ctx, type_name.unwrap(), scrutinee_ty)):
        lower_variant_match(ctx, output, scrutinee_expr, type_name.unwrap(), scrutinee_ty, arms)
        ctx.locals = saved_locals
        return

    let gen_var = generic_variant_name(scrutinee_ty)
    if gen_var.is_some() and variant_match_allowed(ctx, gen_var.unwrap()):
        lower_variant_match(ctx, output, scrutinee_expr, gen_var.unwrap(), scrutinee_ty, arms)
        ctx.locals = saved_locals
        return

    # Integer scrutinee: switch over integer / char literal case values.
    if lowering.is_integer_scrutinee(scrutinee_ty):
        lower_scalar_match(ctx, output, scrutinee_expr, arms)
        ctx.locals = saved_locals
        return

    # String scrutinee: an if / else-if chain comparing with `equal`.
    if is_str_scrutinee(scrutinee_ty):
        lower_string_match(ctx, output, scrutinee_expr, arms)
        ctx.locals = saved_locals
        return

    # Tuple-literal scrutinee: an if / else-if chain over per-element equality
    # tests (mirrors the expression-match tuple path).
    match scrutinee_ty:
        types.Type.ty_tuple:
            lower_tuple_match_stmt(ctx, output, scrutinee_expr, scrutinee_ty, arms)
            ctx.locals = saved_locals
            return
        _:
            pass

    let enum_name = type_name else:
        let ts = types.type_to_string(scrutinee_ty)
        if ts == "void" or ts == "<error>" or ts.starts_with("("):
            ctx.locals = saved_locals
            return
        fatal(strings.join_two("lowering: match requires known type, got ", ts))
    var enum_module = enum_source_module(ctx, scrutinee_ty, ctx.module_name)
    var cases = vec.Vec[ir.SwitchCase].create()
    var i: ptr_uint = 0
    while i < arms.len:
        var arm: ast.MatchArm
        unsafe:
            arm = read(arms.data + i)
        let lowered_body = lower_switch_arm_body(ctx, arm.body)
        # The CPS match lowering appends a native break to every case body
        # (the host's `lower_async_cf_match_stmt`), even after a return.
        var body = lowered_body
        if ctx.async_cps_active:
            var case_body = vec.Vec[ir.Stmt].create()
            lowering.append_span_stmts(ref_of(case_body), lowered_body)
            case_body.push(ir.Stmt.stmt_break)
            body = case_body.as_span()
        let pattern = arm.pattern
        if pattern == null:
            cases.push(ir.SwitchCase(is_default = true, value = null, body = body))
        else:
            let member = match_member_name(pattern) else:
                fatal(c"lowering: unsupported match pattern")
            let value = lowering.alloc_expr(ir.Expr.expr_name(
                name = enum_member_reference_c_name(ctx, enum_module, enum_name, member),
                ty = scrutinee_ty,
                pointer = Option[bool].some(value = false),
            ))
            cases.push(ir.SwitchCase(is_default = false, value = value, body = body))
        i += 1

    output.push(ir.Stmt.stmt_switch(expression = scrutinee_expr, cases = cases.as_span(), exhaustive = true))
    ctx.locals = saved_locals


function is_str_scrutinee(ty: types.Type) -> bool:
    match ty:
        types.Type.ty_str:
            return true
        _:
            return false


## Lower an integer match to a `switch`, using each arm's integer / char literal
## pattern as the case value.  A `_` arm becomes `default` (marked exhaustive,
## matching the host; the backend only emits `__builtin_unreachable` when the
## switch has no default).
function lower_scalar_match(ctx: ref[lowering.LoweringContext], output: ref[vec.Vec[ir.Stmt]], scrutinee_expr: ptr[ir.Expr], arms: span[ast.MatchArm]) -> void:
    # A range pattern cannot be a `switch` case, so a match containing one is
    # lowered to an if / else-if chain (mirrors Ruby's lower_range_match_stmt).
    var has_range = false
    var hi: ptr_uint = 0
    while hi < arms.len:
        unsafe:
            let hp = read(arms.data + hi).pattern
            if hp != null:
                match read(hp):
                    ast.Expr.expr_range:
                        has_range = true
                    _:
                        pass
        hi += 1
    if has_range:
        lower_scalar_range_match(ctx, output, scrutinee_expr, arms)
        return

    let scrutinee_ty = lowering.ir_expr_type(scrutinee_expr)
    var cases = vec.Vec[ir.SwitchCase].create()
    var i: ptr_uint = 0
    while i < arms.len:
        var arm: ast.MatchArm
        unsafe:
            arm = read(arms.data + i)
        let lowered_body = lower_switch_arm_body(ctx, arm.body)
        # The CPS match lowering appends a native break to every case body
        # (the host's `lower_async_cf_match_stmt`, async_lowering.rb:585-591),
        # even after a terminating return.
        var body = lowered_body
        if ctx.async_cps_active:
            var case_body = vec.Vec[ir.Stmt].create()
            lowering.append_span_stmts(ref_of(case_body), lowered_body)
            case_body.push(ir.Stmt.stmt_break)
            body = case_body.as_span()
        let pattern = arm.pattern
        if pattern == null:
            cases.push(ir.SwitchCase(is_default = true, value = null, body = body))
        else:
            # A literal case value takes the scrutinee's type (the host's
            # `lower_pattern_expression`): `match b { 80: … }` on a `ubyte`
            # carries a `ubyte` literal, not `int`.
            var case_value = lowering.lower_expr(ctx, ptr[ast.Expr]<-pattern)
            case_value = lowering.literal_value_to_context_type(ctx, ptr[ast.Expr]<-pattern, scrutinee_ty, case_value)
            cases.push(ir.SwitchCase(is_default = false, value = case_value, body = body))
        i += 1
    output.push(ir.Stmt.stmt_switch(expression = scrutinee_expr, cases = cases.as_span(), exhaustive = true))


## Lower an integer match containing range patterns to an if / else-if chain.
## A range arm becomes `scrutinee >= start and scrutinee <= stop`; other arms
## compare with `==`.  A `_` arm becomes the final else block.
function lower_scalar_range_match(ctx: ref[lowering.LoweringContext], output: ref[vec.Vec[ir.Stmt]], scrutinee_expr: ptr[ir.Expr], arms: span[ast.MatchArm]) -> void:
    let scrutinee_ty = lowering.ir_expr_type(scrutinee_expr)
    # The host's match-to-if chains always carry an else body; the innermost
    # `if` falls back to an empty one when there is no wildcard arm.
    var else_body = Option[span[ir.Stmt]].some(value = span[ir.Stmt]())
    var wi: ptr_uint = 0
    while wi < arms.len:
        var warm: ast.MatchArm
        unsafe:
            warm = read(arms.data + wi)
        if warm.pattern == null:
            else_body = Option[span[ir.Stmt]].some(value = lowering.lower_block(ctx, warm.body))
        wi += 1

    var idx = arms.len
    while idx > 0:
        idx -= 1
        var arm: ast.MatchArm
        unsafe:
            arm = read(arms.data + idx)
        let pattern = arm.pattern
        if pattern != null:
            let body = lowering.lower_block(ctx, arm.body)
            var cond: ptr[ir.Expr]
            unsafe:
                match read(pattern):
                    ast.Expr.expr_range as rng:
                        var start = lowering.lower_expr(ctx, rng.start_expr)
                        var stop = lowering.lower_expr(ctx, rng.end_expr)
                        start = lowering.literal_value_to_context_type(ctx, rng.start_expr, scrutinee_ty, start)
                        stop = lowering.literal_value_to_context_type(ctx, rng.end_expr, scrutinee_ty, stop)
                        let ge = lowering.alloc_expr(ir.Expr.expr_binary(operator = ">=", left = scrutinee_expr, right = start, ty = ctx.bool_ty))
                        let le = lowering.alloc_expr(ir.Expr.expr_binary(operator = "<=", left = scrutinee_expr, right = stop, ty = ctx.bool_ty))
                        cond = lowering.alloc_expr(ir.Expr.expr_binary(operator = "and", left = ge, right = le, ty = ctx.bool_ty))
                    _:
                        var lit = lowering.lower_expr(ctx, pattern)
                        lit = lowering.literal_value_to_context_type(ctx, pattern, scrutinee_ty, lit)
                        cond = lowering.alloc_expr(ir.Expr.expr_binary(operator = "==", left = scrutinee_expr, right = lit, ty = ctx.bool_ty))
            var chain = vec.Vec[ir.Stmt].create()
            chain.push(ir.Stmt.stmt_if(condition = cond, then_body = body, else_body = else_body))
            else_body = Option[span[ir.Stmt]].some(value = chain.as_span())
    match else_body:
        Option.some as eb:
            var oi: ptr_uint = 0
            while oi < eb.value.len:
                unsafe:
                    output.push(read(eb.value.data + oi))
                oi += 1
        Option.none:
            pass


## Lower a string match to an if / else-if chain comparing the scrutinee with
## each arm's string-literal pattern via `equal` (rendered as `mt_str_equal`).
## The host compares the prepared scrutinee IR node directly (no `match_str`
## temp).  A `_` arm becomes the final else block.
function lower_string_match(ctx: ref[lowering.LoweringContext], output: ref[vec.Vec[ir.Stmt]], scrutinee_expr: ptr[ir.Expr], arms: span[ast.MatchArm]) -> void:
    # Collect literal arms and the optional default (wildcard) body.
    var default_body = span[ir.Stmt]()
    var lit_bodies = vec.Vec[span[ir.Stmt]].create()
    var lit_values = vec.Vec[ptr[ir.Expr]].create()
    var i: ptr_uint = 0
    while i < arms.len:
        var arm: ast.MatchArm
        unsafe:
            arm = read(arms.data + i)
        let body = lowering.lower_block(ctx, arm.body)
        let pattern = arm.pattern
        if pattern == null:
            default_body = body
        else:
            lit_values.push(lowering.lower_expr(ctx, ptr[ast.Expr]<-pattern))
            lit_bodies.push(body)
        i += 1

    # Build the chain from the last arm backwards so each else wraps the rest.
    # The host always carries an else body: the wildcard arm's block, or an
    # empty one when every arm is a literal.
    var else_body = Option[span[ir.Stmt]].some(value = default_body)
    var idx = lit_values.len()
    while idx > 0:
        idx -= 1
        let value_ptr = lit_values.get(idx) else:
            fatal(c"lowering: string match value")
        let body_ptr = lit_bodies.get(idx) else:
            fatal(c"lowering: string match body")
        let condition = lowering.alloc_expr(ir.Expr.expr_binary(
            operator = "==",
            left = scrutinee_expr,
            right = unsafe: read(value_ptr),
            ty = ctx.bool_ty,
        ))
        let then_body = unsafe: read(body_ptr)
        var if_stmts = vec.Vec[ir.Stmt].create()
        if_stmts.push(ir.Stmt.stmt_if(condition = condition, then_body = then_body, else_body = else_body))
        else_body = Option[span[ir.Stmt]].some(value = if_stmts.as_span())

    match else_body:
        Option.some as eb:
            var j: ptr_uint = 0
            while j < eb.value.len:
                unsafe:
                    output.push(read(eb.value.data + j))
                j += 1
        Option.none:
            pass


## Infer the result type of a match expression from its first non-wildcard arm's
## value, so `let x = match e: { a: "s", _: "t" }` types x as `str` instead of `int`.
function infer_match_arm_type(ctx: ref[lowering.LoweringContext], arms: span[ast.MatchExprArm]) -> types.Type:
    var i: ptr_uint = 0
    while i < arms.len:
        var arm: ast.MatchExprArm
        unsafe:
            arm = read(arms.data + i)
        let vt = lowering.qualify_type(ctx, type_helpers.expr_type(ctx, arm.value))
        if not types.is_error(vt) and not types.type_to_string(vt) == "void":
            return vt
        i += 1
    return types.Type.ty_error


public function lower_match_expression_local(ctx: ref[lowering.LoweringContext], output: ref[vec.Vec[ir.Stmt]], name: str, declared_type: ptr[ast.TypeRef]?, scrutinee: ptr[ast.Expr], arms: span[ast.MatchExprArm], line: ptr_uint) -> void:
    let c_name = utils.c_local_name(name)
    var ty = types.Type.ty_error
    let dt = declared_type
    if dt != null:
        ty = lowering.resolve_type_ref(ctx, dt)
    if types.is_error(ty):
        ty = infer_match_arm_type(ctx, arms)
    if types.is_error(ty):
        ty = types.primitive("int")

    # The host's prepared-expression path: the match writes a fresh
    # `__mt_match_expr_N` temp (zero-initialized), and the declared local copies
    # it afterwards.
    let temp = lowering.fresh_c_temp_name(ctx, "match_expr")
    let zero_init = lowering.alloc_expr(ir.Expr.expr_zero_init(ty = ty))
    output.push(ir.Stmt.stmt_local(name = temp, linkage_name = temp, ty = ty, value = zero_init, line = 0, source_path = ""))

    let result_ref = lowering.alloc_expr(ir.Expr.expr_name(name = temp, ty = ty, pointer = Option[bool].some(value = false)))
    lower_match_expr_to_ref(ctx, output, scrutinee, arms, result_ref)

    let temp_ref = lowering.alloc_expr(ir.Expr.expr_name(name = temp, ty = ty, pointer = Option[bool].some(value = false)))
    output.push(ir.Stmt.stmt_local(name = name, linkage_name = c_name, ty = ty, value = temp_ref, line = line, source_path = ctx.analysis.source_path))

    ctx.locals.push(lowering.LocalBinding(name = name, c_name = c_name, ty = ty, pointer = Option[bool].some(value = false)))


## Lower a match expression so each arm assigns its value to `result_ref`, using
## the strategy that fits the scrutinee type (str if-chain / variant switch /
## enum switch / tuple if-chain).  The scrutinee is hoisted into a temp when it is
## not already a name so it is evaluated once.  Shared by `let x = match ...`
## (lower_match_expression_local) and the `return match ...` hoist.
public function lower_match_expr_to_ref(ctx: ref[lowering.LoweringContext], output: ref[vec.Vec[ir.Stmt]], scrutinee: ptr[ast.Expr], arms: span[ast.MatchExprArm], result_ref: ptr[ir.Expr]) -> void:
    var scrutinee_ty = type_helpers.expr_type(ctx, scrutinee)
    var scrutinee_expr = lowering.lower_expr(ctx, scrutinee)
    # Prefer the lowered scrutinee's type (more accurate for prelude/field types).
    let lowered_sty = lowering.ir_expr_type(scrutinee_expr)
    if not types.is_error(lowered_sty) and not types.type_to_string(lowered_sty) == "void":
        scrutinee_ty = lowered_sty
    if not ir_expr_is_name(scrutinee_expr):
        # The host hoists the scrutinee into a `match_value` temp only for a
        # *variant* whose arms bind payloads and whose expression is not
        # duplicable — every arm's body reads the scrutinee again; an enum
        # scrutinee (a member access like `this.shape.kind`) switches on the
        # expression itself (`expressions.rb:1148-1154`).
        var binds_payload = false
        var arm_i: ptr_uint = 0
        while arm_i < arms.len:
            var arm_chk: ast.MatchExprArm
            unsafe:
                arm_chk = read(arms.data + arm_i)
            if arm_chk.binding_name.is_some() and arm_chk.wildcard_line == 0:
                binds_payload = true
            arm_i += 1
        let scrut_name = lowering.named_type_name(scrutinee_ty)
        var is_variant = false
        match scrut_name:
            Option.some as sn:
                if ctx.variants.contains(sn.value):
                    is_variant = true
            Option.none:
                pass
        if binds_payload and is_variant and not lowering.duplicable_foreign_value(scrutinee_expr):
            let temp = lowering.fresh_c_temp_name(ctx, "match_value")
            output.push(ir.Stmt.stmt_local(name = temp, linkage_name = temp, ty = scrutinee_ty, value = scrutinee_expr, line = 0, source_path = ""))
            scrutinee_expr = lowering.alloc_expr(ir.Expr.expr_name(name = temp, ty = scrutinee_ty, pointer = Option[bool].some(value = false)))

    let type_name = lowering.named_type_name(scrutinee_ty)
    if is_str_scrutinee(scrutinee_ty):
        lower_str_match_expr(ctx, output, scrutinee_expr, arms, result_ref)
    else if lowering.is_tuple_type(scrutinee_ty):
        lower_tuple_match_expr(ctx, output, scrutinee_expr, scrutinee_ty, arms, result_ref)
    else if type_name.is_some() and ctx.variants.contains(type_name.unwrap()):
        lower_variant_match_expr(ctx, output, scrutinee_expr, type_name.unwrap(), scrutinee_ty, arms, result_ref)
    else:
        lower_enum_match_expr(ctx, output, scrutinee_expr, type_name, arms, result_ref)


## Lower a match expression over a `str` scrutinee: emit an if / else-if chain
## comparing the scrutinee with each arm's string-literal pattern, assigning the
## arm's value to `result_ref` on match.  Mirrors `lower_string_match` for the
## expression form.
function lower_str_match_expr(ctx: ref[lowering.LoweringContext], output: ref[vec.Vec[ir.Stmt]], scrutinee_expr: ptr[ir.Expr], arms: span[ast.MatchExprArm], result_ref: ptr[ir.Expr]) -> void:
    var has_default = false
    var default_val: ptr[ir.Expr]? = null
    var pattern_lits = vec.Vec[ptr[ir.Expr]].create()
    var result_vals = vec.Vec[ptr[ir.Expr]].create()
    var ai: ptr_uint = 0
    while ai < arms.len:
        var arm: ast.MatchExprArm
        unsafe:
            arm = read(arms.data + ai)
        if arm.pattern == null:
            has_default = true
            default_val = lowering.lower_expr(ctx, arm.value)
        else:
            unsafe:
                pattern_lits.push(lowering.lower_expr(ctx, ptr[ast.Expr]<-arm.pattern))
            result_vals.push(lowering.lower_expr(ctx, arm.value))
        ai += 1

    # Emit a proper else-if chain: `if (p0) r=v0; else if (p1) r=v1; ... else
    # r=default;`.  Building it as independent if-thens (with only the final arm
    # carrying the default as its else) is WRONG — the last arm's `else` would
    # clobber an earlier arm's assignment.  Mirrors Ruby's string-match lowering,
    # which nests each subsequent arm inside the prior arm's else branch.
    # Construct from the tail backwards so each arm's else_body is the already-
    # built remainder of the chain.
    var chain = vec.Vec[ir.Stmt].create()
    if has_default:
        let dv = default_val else:
            fatal(c"lowering: str match expr default value")
        chain.push(ir.Stmt.stmt_assignment(target = result_ref, operator = "=", value = dv))

    var back = pattern_lits.len
    while back > 0:
        back -= 1
        let pat_ptr = pattern_lits.get(back) else:
            fatal(c"lowering: str match expr pattern")
        let val_ptr = result_vals.get(back) else:
            fatal(c"lowering: str match expr value")
        let condition = lowering.alloc_expr(ir.Expr.expr_binary(
            operator = "==",
            left = scrutinee_expr,
            right = unsafe: read(pat_ptr),
            ty = ctx.bool_ty,
        ))
        var then_body = vec.Vec[ir.Stmt].create()
        then_body.push(ir.Stmt.stmt_assignment(target = result_ref, operator = "=", value = unsafe: read(val_ptr)))
        let else_body = Option[span[ir.Stmt]].some(value = chain.as_span())
        var next_chain = vec.Vec[ir.Stmt].create()
        next_chain.push(ir.Stmt.stmt_if(condition = condition, then_body = then_body.as_span(), else_body = else_body))
        chain = next_chain

    lowering.append_span_stmts(output, chain.as_span())


## Lower a match expression over a tuple scrutinee: for each arm, compare the
## tuple element-wise (`scrut._0 == e0 && scrut._1 == e1 && ...`) and assign the
## arm value on match.  The host nests the chain into else bodies (the wildcard
## arm is the innermost else), so exactly one arm's assignment executes.
function lower_tuple_match_expr(ctx: ref[lowering.LoweringContext], output: ref[vec.Vec[ir.Stmt]], scrutinee_expr: ptr[ir.Expr], scrutinee_ty: types.Type, arms: span[ast.MatchExprArm], result_ref: ptr[ir.Expr]) -> void:
    # The wildcard arm (built first, as the host does) is the chain's else body.
    var else_body = vec.Vec[ir.Stmt].create()
    var ai: ptr_uint = 0
    while ai < arms.len:
        var arm: ast.MatchExprArm
        unsafe:
            arm = read(arms.data + ai)
        if arm.pattern == null:
            let value = lowering.lower_expr(ctx, arm.value)
            else_body.push(ir.Stmt.stmt_assignment(target = result_ref, operator = "=", value = value))
        ai += 1

    # Construct from the tail backwards so each arm's else body is the
    # already-built remainder of the chain (the host's non_wildcard.reverse_each).
    var idx = arms.len
    while idx > 0:
        idx -= 1
        var arm: ast.MatchExprArm
        unsafe:
            arm = read(arms.data + idx)
        let pattern = arm.pattern
        if pattern != null:
            var then_body = vec.Vec[ir.Stmt].create()
            then_body.push(ir.Stmt.stmt_assignment(target = result_ref, operator = "=", value = lowering.lower_expr(ctx, arm.value)))
            let cond = tuple_pattern_condition(ctx, scrutinee_expr, scrutinee_ty, unsafe: read(pattern))
            var chain = vec.Vec[ir.Stmt].create()
            chain.push(ir.Stmt.stmt_if(condition = cond, then_body = then_body.as_span(), else_body = Option[span[ir.Stmt]].some(value = else_body.as_span())))
            else_body = chain

    lowering.append_span_stmts(output, else_body.as_span())


## Lower a tuple-literal match statement to an if / else-if chain of
## per-element equality conditions, with the `_` arm as the final else.
function lower_tuple_match_stmt(ctx: ref[lowering.LoweringContext], output: ref[vec.Vec[ir.Stmt]], scrutinee_expr: ptr[ir.Expr], scrutinee_ty: types.Type, arms: span[ast.MatchArm]) -> void:
    # The host's match-to-if chains always carry an else body; the innermost
    # `if` falls back to an empty one when there is no wildcard arm.
    var else_body = Option[span[ir.Stmt]].some(value = span[ir.Stmt]())
    var wi: ptr_uint = 0
    while wi < arms.len:
        var warm: ast.MatchArm
        unsafe:
            warm = read(arms.data + wi)
        if warm.pattern == null:
            else_body = Option[span[ir.Stmt]].some(value = lowering.lower_block(ctx, warm.body))
        wi += 1
    var idx = arms.len
    while idx > 0:
        idx -= 1
        var arm: ast.MatchArm
        unsafe:
            arm = read(arms.data + idx)
        let pattern = arm.pattern
        if pattern != null:
            let cond = tuple_pattern_condition(ctx, scrutinee_expr, scrutinee_ty, unsafe: read(pattern))
            var chain = vec.Vec[ir.Stmt].create()
            chain.push(ir.Stmt.stmt_if(condition = cond, then_body = lowering.lower_block(ctx, arm.body), else_body = else_body))
            else_body = Option[span[ir.Stmt]].some(value = chain.as_span())
    match else_body:
        Option.some as eb:
            var oi: ptr_uint = 0
            while oi < eb.value.len:
                unsafe:
                    output.push(read(eb.value.data + oi))
                oi += 1
        Option.none:
            pass


## Build the boolean condition for a tuple-literal pattern: the conjunction of
## per-element equality tests `scrut._i == elem_i`.  `_` elements are skipped
## (they match anything).  Returns a literal `true` when the pattern has no
## constraining elements.
function tuple_pattern_condition(ctx: ref[lowering.LoweringContext], scrutinee_expr: ptr[ir.Expr], scrutinee_ty: types.Type, pattern: ast.Expr) -> ptr[ir.Expr]:
    var cond: ptr[ir.Expr]? = null
    match pattern:
        ast.Expr.expr_expression_list as lst:
            var i: ptr_uint = 0
            while i < lst.elements.len:
                var elem: ast.Expr
                unsafe:
                    elem = read(lst.elements.data + i)
                    if not expr_is_wildcard(elem):
                        let elem_ty = lowering.tuple_element_type(scrutinee_ty, i)
                        var member_name = lowering.tuple_field_name(i)
                        match scrutinee_ty:
                            types.Type.ty_tuple as tup:
                                match tup.field_names:
                                    Option.some as fnames:
                                        if i < fnames.value.len:
                                            member_name = unsafe: read(fnames.value.data + i)
                                    Option.none:
                                        pass
                            _:
                                pass
                        let field = lowering.alloc_expr(ir.Expr.expr_member(receiver = scrutinee_expr, member = member_name, ty = elem_ty))
                        let elem_expr = lowering.lower_expr(ctx, unsafe: ptr[ast.Expr]<-(lst.elements.data + i))
                        let cmp = lowering.alloc_expr(ir.Expr.expr_binary(operator = "==", left = field, right = elem_expr, ty = ctx.bool_ty))
                        let existing = cond
                        if existing == null:
                            cond = cmp
                        else:
                            cond = lowering.alloc_expr(ir.Expr.expr_binary(operator = "and", left = existing, right = cmp, ty = ctx.bool_ty))
                i += 1
        _:
            pass
    let final_cond = cond else:
        return lowering.alloc_expr(ir.Expr.expr_boolean_literal(value = true, ty = ctx.bool_ty))
    return final_cond


## True when an expression is the `_` wildcard identifier.
function expr_is_wildcard(e: ast.Expr) -> bool:
    match e:
        ast.Expr.expr_identifier as id:
            return id.name == "_"
        _:
            return false


## Lower a match expression over an enum scrutinee: emit a switch whose cases
## assign the result and break, plus a default case for the wildcard arm.
function lower_enum_match_expr(ctx: ref[lowering.LoweringContext], output: ref[vec.Vec[ir.Stmt]], scrutinee_expr: ptr[ir.Expr], type_name: Option[str], arms: span[ast.MatchExprArm], result_ref: ptr[ir.Expr]) -> void:
    var cases = vec.Vec[ir.SwitchCase].create()
    var enum_module = enum_source_module(ctx, lowering.ir_expr_type(scrutinee_expr), ctx.module_name)
    var i: ptr_uint = 0
    while i < arms.len:
        var arm: ast.MatchExprArm
        unsafe:
            arm = read(arms.data + i)
        let lowered_val = lowering.lower_expr(ctx, arm.value)
        var body = vec.Vec[ir.Stmt].create()
        body.push(ir.Stmt.stmt_assignment(target = result_ref, operator = "=", value = lowered_val))
        let pattern = arm.pattern
        if pattern == null:
            cases.push(ir.SwitchCase(is_default = true, value = null, body = body.as_span()))
        else:
            let member = match_member_name(pattern) else:
                # Non-enum pattern (integer literal, char literal, etc.): the
                # literal takes the scrutinee's type, as `lower_pattern_expression`
                # does on the host.
                var lowered_pat = lowering.lower_expr(ctx, pattern)
                lowered_pat = lowering.literal_value_to_context_type(ctx, pattern, lowering.ir_expr_type(scrutinee_expr), lowered_pat)
                cases.push(ir.SwitchCase(is_default = false, value = lowered_pat, body = body.as_span()))
                i += 1
                continue
            match type_name:
                Option.some as tn:
                    let value = lowering.alloc_expr(ir.Expr.expr_name(
                        name = enum_member_reference_c_name(ctx, enum_module, tn.value, member),
                        ty = lowering.ir_expr_type(scrutinee_expr),
                        pointer = Option[bool].some(value = false),
                    ))
                    cases.push(ir.SwitchCase(is_default = false, value = value, body = body.as_span()))
                Option.none:
                    fatal(c"lowering: match expression on non-enum scrutinee")
        i += 1

    output.push(ir.Stmt.stmt_switch(expression = scrutinee_expr, cases = cases.as_span(), exhaustive = true))


## Lower a match expression over a variant scrutinee: emit a switch on the variant
## kind, with each arm assigning its value to the result reference.
function lower_variant_match_expr(ctx: ref[lowering.LoweringContext], output: ref[vec.Vec[ir.Stmt]], scrutinee_expr: ptr[ir.Expr], variant_name: str, scrutinee_ty: types.Type, arms: span[ast.MatchExprArm], result_ref: ptr[ir.Expr]) -> void:
    let info_ptr = ctx.variants.get(variant_registry_key(ctx, variant_name, scrutinee_ty)) else:
        fatal(c"lowering: variant match expr on unknown variant")
    let info = unsafe: read(info_ptr)
    let outer_c = lowering.variant_base_c_name(scrutinee_ty, ctx.module_name)
    let int_ty = types.primitive("int")
    let kind_expr = lowering.alloc_expr(ir.Expr.expr_member(receiver = scrutinee_expr, member = "kind", ty = int_ty))

    var cases = vec.Vec[ir.SwitchCase].create()
    var i: ptr_uint = 0
    while i < arms.len:
        var arm: ast.MatchExprArm
        unsafe:
            arm = read(arms.data + i)
        var body = vec.Vec[ir.Stmt].create()
        let pattern = arm.pattern
        if pattern != null:
            match arm.binding_name:
                Option.some as bn:
                    let arm_name = variant_match_arm_name_from_pattern(pattern) else:
                        fatal(c"lowering: unsupported variant match expression pattern")
                    let binding_ty = variant_arm_payload_binding(variant_name, info.module_name, outer_c, arm_name)
                    register_arm_payload_fields(ctx, variant_arm_type_name(outer_c, arm_name), info, arm_name, scrutinee_ty)
                    let data_member = lowering.alloc_expr(ir.Expr.expr_member(receiver = scrutinee_expr, member = "data", ty = types.Type.ty_nil))
                    let arm_data = lowering.alloc_expr(ir.Expr.expr_member(receiver = data_member, member = arm_name, ty = binding_ty))
                    let bc = utils.c_local_name(bn.value)
                    # The host's plain match-expression lowering (expressions.rb:
                    # 1166-1173) always declares the binding as a C local — its
                    # async path has no frame spill here.
                    body.push(ir.Stmt.stmt_local(name = bn.value, linkage_name = bc, ty = binding_ty, value = arm_data, line = 0, source_path = ""))
                    ctx.locals.push(lowering.LocalBinding(name = bn.value, c_name = bc, ty = binding_ty, pointer = Option[bool].some(value = false)))
                Option.none:
                    pass
        let lowered_val = lowering.lower_expr(ctx, arm.value)
        body.push(ir.Stmt.stmt_assignment(target = result_ref, operator = "=", value = lowered_val))

        if pattern == null:
            cases.push(ir.SwitchCase(is_default = true, value = null, body = body.as_span()))
        else:
            let arm_name = variant_match_arm_name_from_pattern(pattern) else:
                fatal(c"lowering: unsupported variant match expression pattern")
            let kind_const = lowering.alloc_expr(ir.Expr.expr_name(
                name = variant_kind_const_name(outer_c, arm_name),
                ty = int_ty,
                pointer = Option[bool].some(value = false),
            ))
            cases.push(ir.SwitchCase(is_default = false, value = kind_const, body = body.as_span()))
        i += 1

    output.push(ir.Stmt.stmt_switch(expression = kind_expr, cases = cases.as_span(), exhaustive = true))


## Lower a `match` over a variant scrutinee into a `switch (scrut.kind)`.  Each
## payload arm may bind the whole payload struct via `as name`
## (`<arm_c> name = scrut.data.<arm>;`); no-payload arms carry no binding.  A
## non-name scrutinee is hoisted into a temp so it is evaluated once.
## Dispatch a variant match to the switch strategy (member / `as name` /
## no-payload / wildcard arms) or the if/goto strategy (any struct-pattern arm,
## i.e. `Variant.arm(field, ...)`), mirroring Ruby's block.rb decision.
function lower_variant_match(ctx: ref[lowering.LoweringContext], output: ref[vec.Vec[ir.Stmt]], scrutinee_expr: ptr[ir.Expr], variant_name: str, scrutinee_ty: types.Type, arms: span[ast.MatchArm]) -> void:
    if arms_have_call_pattern(arms):
        lower_variant_match_goto(ctx, output, scrutinee_expr, variant_name, scrutinee_ty, arms)
    else:
        lower_variant_match_switch(ctx, output, scrutinee_expr, variant_name, scrutinee_ty, arms)


## True when any arm's pattern is a call (a struct-destructure pattern such as
## `Shape.circle(r)`), which forces the if/goto lowering strategy.
function arms_have_call_pattern(arms: span[ast.MatchArm]) -> bool:
    var i: ptr_uint = 0
    while i < arms.len:
        var arm: ast.MatchArm
        unsafe:
            arm = read(arms.data + i)
        let pattern = arm.pattern
        if pattern != null:
            unsafe:
                match read(pattern):
                    ast.Expr.expr_call:
                        return true
                    _:
                        pass
        i += 1
    return false


function lower_variant_match_switch(ctx: ref[lowering.LoweringContext], output: ref[vec.Vec[ir.Stmt]], scrutinee_expr: ptr[ir.Expr], variant_name: str, scrutinee_ty: types.Type, arms: span[ast.MatchArm]) -> void:
    # If variant_name includes type args (e.g. "Option_span_Field"), strip to
    # the base name (e.g. "Option") to find the variant info.
    var info_ptr = ctx.variants.get(variant_registry_key(ctx, variant_name, scrutinee_ty))
    if info_ptr == null:
        let bn = variant_base_name(variant_name)
        if bn.is_some():
            info_ptr = ctx.variants.get(variant_registry_key(ctx, bn.unwrap(), scrutinee_ty))
    let info_ptr2 = info_ptr else:
        fatal(c"lowering: variant match on unknown variant")
    let info = unsafe: read(info_ptr2)
    let outer_c = lowering.variant_base_c_name(scrutinee_ty, ctx.module_name)
    let int_ty = types.primitive("int")

    var scrut_base = scrutinee_expr
    if not ir_expr_is_name(scrut_base):
        # The host's hoist rule (`block.rb:847-853`): a `match_value` temp only
        # when some arm binds a payload and the expression is not duplicable.
        var binds_payload = false
        var arm_i: ptr_uint = 0
        while arm_i < arms.len:
            var arm_chk: ast.MatchArm
            unsafe:
                arm_chk = read(arms.data + arm_i)
            if arm_chk.binding_name.is_some() and not (arm_chk.pattern == null):
                binds_payload = true
            arm_i += 1
        if binds_payload and not lowering.duplicable_foreign_value(scrut_base):
            let temp = lowering.fresh_c_temp_name(ctx, "match_value")
            let scrut_ty = lowering.ir_expr_type(scrut_base)
            output.push(ir.Stmt.stmt_local(name = temp, linkage_name = temp, ty = scrut_ty, value = scrut_base, line = 0, source_path = ""))
            scrut_base = lowering.alloc_expr(ir.Expr.expr_name(name = temp, ty = scrut_ty, pointer = Option[bool].some(value = false)))

    let kind_expr = lowering.alloc_expr(ir.Expr.expr_member(receiver = scrut_base, member = "kind", ty = int_ty))
    var cases = vec.Vec[ir.SwitchCase].create()
    var i: ptr_uint = 0
    while i < arms.len:
        var arm: ast.MatchArm
        var arm_key: ptr_uint = 0
        unsafe:
            arm = read(arms.data + i)
            arm_key = reinterpret[ptr_uint](arms.data + i)
        let pattern = arm.pattern
        if pattern == null:
            if ctx.async_cps_active:
                # The CPS match lowering appends a native break to every case
                # body (the host's `lower_async_cf_match_stmt`,
                # async_lowering.rb:573-590), even after a terminating return.
                var case_body = vec.Vec[ir.Stmt].create()
                lowering.append_span_stmts(ref_of(case_body), lower_switch_arm_body(ctx, arm.body))
                case_body.push(ir.Stmt.stmt_break)
                cases.push(ir.SwitchCase(is_default = true, value = null, body = case_body.as_span()))
            else:
                cases.push(ir.SwitchCase(is_default = true, value = null, body = lower_switch_arm_body(ctx, arm.body)))
        else:
            let arm_name = match_member_name(pattern) else:
                fatal(c"lowering: unsupported variant match pattern")
            var stmts = vec.Vec[ir.Stmt].create()
            var reg_field = ""
            var reg_field_ty = ctx.void_ty
            match arm.binding_name:
                Option.some as bn:
                    let binding_ty = variant_arm_payload_binding(variant_name, info.module_name, outer_c, arm_name)
                    register_arm_payload_fields(ctx, variant_arm_type_name(outer_c, arm_name), info, arm_name, scrutinee_ty)
                    let data_member = lowering.alloc_expr(ir.Expr.expr_member(receiver = scrut_base, member = "data", ty = types.Type.ty_nil))
                    let arm_data = lowering.alloc_expr(ir.Expr.expr_member(receiver = data_member, member = arm_name, ty = binding_ty))
                    let bc = utils.c_local_name(bn.value)
                    if ctx.inside_async:
                        # The host's lowering-pass counter advance
                        # (`async_variant_match_arm_binding` →
                        # `async_match_binding_field_key`, async_lowering.rb:1333).
                        # Its `local_fields` lookup never matches, so the arm
                        # binding is a plain C local and the analysis-registered
                        # field stays unused.
                        if async_cps.arm_has_payload(info, arm_name):
                            lowering.next_async_binding_index()
                        let fname_ptr = ctx.async_match_binding_names.get(arm_key)
                        if fname_ptr != null:
                            reg_field = unsafe: read(ptr[str]<-fname_ptr)
                            reg_field_ty = binding_ty
                    stmts.push(ir.Stmt.stmt_local(name = bn.value, linkage_name = bc, ty = binding_ty, value = arm_data, line = 0, source_path = ""))
                    ctx.locals.push(lowering.LocalBinding(name = bn.value, c_name = bc, ty = binding_ty, pointer = Option[bool].some(value = false)))
                Option.none:
                    pass
            let body = lower_switch_arm_body(ctx, arm.body)
            var bi: ptr_uint = 0
            while bi < body.len:
                unsafe:
                    stmts.push(read(body.data + bi))
                bi += 1
            if reg_field != "":
                async_cps.async_register_unused_field(ctx, reg_field, reg_field_ty)
            if ctx.async_cps_active:
                stmts.push(ir.Stmt.stmt_break)
            let kind_const = lowering.alloc_expr(ir.Expr.expr_name(
                name = variant_kind_const_name(outer_c, arm_name),
                ty = int_ty,
                pointer = Option[bool].some(value = false),
            ))
            cases.push(ir.SwitchCase(is_default = false, value = kind_const, body = stmts.as_span()))
        i += 1

    output.push(ir.Stmt.stmt_switch(expression = kind_expr, cases = cases.as_span(), exhaustive = true))


## Lower a variant match with struct-pattern arms into an if/goto chain: each arm
## tests `scrut.kind`, jumps to the next arm's label on mismatch, otherwise binds
## the payload into a temp, destructures its fields, and falls through to the arm
## body then `goto <end>`.  Mirrors Ruby's block.rb struct-pattern match path.
function lower_variant_match_goto(ctx: ref[lowering.LoweringContext], output: ref[vec.Vec[ir.Stmt]], scrutinee_expr: ptr[ir.Expr], variant_name: str, scrutinee_ty: types.Type, arms: span[ast.MatchArm]) -> void:
    let info_ptr = ctx.variants.get(variant_registry_key(ctx, variant_name, scrutinee_ty)) else:
        fatal(c"lowering: variant match on unknown variant")
    let info = unsafe: read(info_ptr)
    let outer_c = lowering.variant_base_c_name(scrutinee_ty, ctx.module_name)
    let int_ty = types.primitive("int")
    let bool_ty = ctx.bool_ty

    var scrut_base = scrutinee_expr
    if not ir_expr_is_name(scrut_base):
        let temp = lowering.fresh_c_temp_name(ctx, "match_value")
        let scrut_ty = lowering.ir_expr_type(scrut_base)
        output.push(ir.Stmt.stmt_local(name = temp, linkage_name = temp, ty = scrut_ty, value = scrut_base, line = 0, source_path = ""))
        scrut_base = lowering.alloc_expr(ir.Expr.expr_name(name = temp, ty = scrut_ty, pointer = Option[bool].some(value = false)))

    ctx.match_label_counter += 1
    let m = ctx.match_label_counter
    let end_label = match_label_name(m, "end")
    let next_label = match_label_name(m, "arm_next")

    var arm_index: ptr_uint = 0
    while arm_index < arms.len:
        var arm: ast.MatchArm
        var arm_key: ptr_uint = 0
        unsafe:
            arm = read(arms.data + arm_index)
            arm_key = reinterpret[ptr_uint](arms.data + arm_index)
        if arm_index > 0:
            output.push(ir.Stmt.stmt_label(name = match_arm_label(m, arm_index)))

        let pattern = arm.pattern
        if pattern == null:
            var blk = vec.Vec[ir.Stmt].create()
            lowering.append_span_stmts(ref_of(blk), lowering.lower_block(ctx, arm.body))
            blk.push(ir.Stmt.stmt_goto(label = end_label))
            output.push(ir.Stmt.stmt_block(body = blk.as_span()))
        else:
            let arm_name = variant_match_arm_name_from_pattern(pattern) else:
                fatal(c"lowering: unsupported variant match pattern")
            let goto_label = if arm_index < arms.len - 1: match_arm_label(m, arm_index + 1) else: next_label

            let kind_expr = lowering.alloc_expr(ir.Expr.expr_member(receiver = scrut_base, member = "kind", ty = int_ty))
            let tag_value = lowering.alloc_expr(ir.Expr.expr_name(name = variant_kind_const_name(outer_c, arm_name), ty = int_ty, pointer = Option[bool].some(value = false)))
            let tag_check = lowering.alloc_expr(ir.Expr.expr_binary(operator = "!=", left = kind_expr, right = tag_value, ty = bool_ty))
            var then_body = vec.Vec[ir.Stmt].create()
            then_body.push(ir.Stmt.stmt_goto(label = goto_label))
            # The host emits an empty (present) else branch for arm tag checks.
            output.push(ir.Stmt.stmt_if(condition = tag_check, then_body = then_body.as_span(), else_body = Option[span[ir.Stmt]].some(value = span[ir.Stmt]())))

            var blk = vec.Vec[ir.Stmt].create()
            var reg_field = ""
            let payload_ty = variant_arm_payload_binding(variant_name, info.module_name, outer_c, arm_name)
            register_arm_payload_fields(ctx, variant_arm_type_name(outer_c, arm_name), info, arm_name, scrutinee_ty)
            match lowering.variant_arm_info(info, arm_name):
                Option.some as ai:
                    if ai.value.field_names.len > 0:
                        let payload_c = lowering.fresh_c_temp_name(ctx, "match_payload")
                        let data_member = lowering.alloc_expr(ir.Expr.expr_member(receiver = scrut_base, member = "data", ty = types.Type.ty_nil))
                        let arm_data = lowering.alloc_expr(ir.Expr.expr_member(receiver = data_member, member = arm_name, ty = payload_ty))
                        if ctx.async_cps_active:
                            # Spill the match arm's payload struct to a frame
                            # field so pattern-bindings and `as` binding survive
                            # await inside the arm body.
                            let mfield = strings.join_two("local_", payload_c)
                            let mcname = strings.join_two("__mt_frame->", mfield)
                            async_cps.async_register_local_field(ctx, payload_c, mfield, mcname, payload_ty)
                            blk.push(ir.Stmt.stmt_assignment(target = lowering.alloc_expr(ir.Expr.expr_name(name = mcname, ty = payload_ty, pointer = Option[bool].some(value = false))), operator = "=", value = arm_data))
                        else:
                            blk.push(ir.Stmt.stmt_local(name = payload_c, linkage_name = payload_c, ty = payload_ty, value = arm_data, line = 0, source_path = ""))
                            ctx.locals.push(lowering.LocalBinding(name = payload_c, c_name = payload_c, ty = payload_ty, pointer = Option[bool].some(value = false)))
                        lower_variant_field_bindings(ctx, ref_of(blk), pattern, ai.value, payload_c, payload_ty, goto_label)
                        match arm.binding_name:
                            Option.some as bn:
                                let bc = utils.c_local_name(bn.value)
                                let payload_ref = lowering.alloc_expr(ir.Expr.expr_name(name = payload_c, ty = payload_ty, pointer = Option[bool].some(value = false)))
                                if ctx.inside_async:
                                    # The host's lowering-pass counter advance for
                                    # the `as` binding (the payload temp above has
                                    # no host counterpart: the host's async match
                                    # path only handles member-pattern arms).
                                    lowering.next_async_binding_index()
                                    let gname_ptr = ctx.async_match_binding_names.get(arm_key)
                                    if gname_ptr != null:
                                        reg_field = unsafe: read(ptr[str]<-gname_ptr)
                                blk.push(ir.Stmt.stmt_local(name = bn.value, linkage_name = bc, ty = payload_ty, value = payload_ref, line = 0, source_path = ""))
                                ctx.locals.push(lowering.LocalBinding(name = bn.value, c_name = bc, ty = payload_ty, pointer = Option[bool].some(value = false)))
                            Option.none:
                                pass
                Option.none:
                    pass
            lowering.append_span_stmts(ref_of(blk), lowering.lower_block(ctx, arm.body))
            if reg_field != "":
                async_cps.async_register_unused_field(ctx, reg_field, payload_ty)
            blk.push(ir.Stmt.stmt_goto(label = end_label))
            output.push(ir.Stmt.stmt_block(body = blk.as_span()))
        arm_index += 1

    output.push(ir.Stmt.stmt_label(name = next_label))
    output.push(ir.Stmt.stmt_label(name = end_label))


## Emit `<field_type> <field> = <payload>.<field>;` bindings for each bare
## identifier in a struct pattern's argument list, skipping `_` discards.
## Guards (`field > expr`) and equality patterns (`field = expr`) are emitted
## as conditional `goto next_arm_label` checks on failure.
function lower_variant_field_bindings(ctx: ref[lowering.LoweringContext], blk: ref[vec.Vec[ir.Stmt]], pattern: ptr[ast.Expr], arm_info: lowering.VariantArmInfo, payload_c: str, payload_ty: types.Type, next_arm_label: str) -> void:
    let bool_ty = ctx.bool_ty
    unsafe:
        match read(pattern):
            ast.Expr.expr_call as cl:
                var i: ptr_uint = 0
                while i < cl.args.len:
                    var arg: ast.Argument
                    arg = read(cl.args.data + i)
                    match arg.arg_name:
                        Option.some as eq_name:
                            # Equality pattern: `field = expr` —
                            # skip arm if payload.field != expr.
                            let field_ty = variant_arm_field_type(arm_info, eq_name.value)
                            let payload_ref = lowering.alloc_expr(ir.Expr.expr_name(name = payload_c, ty = payload_ty, pointer = Option[bool].some(value = false)))
                            let left = lowering.alloc_expr(ir.Expr.expr_member(receiver = payload_ref, member = eq_name.value, ty = field_ty))
                            let right = lowering.lower_expr(ctx, arg.arg_value)
                            let cond = lowering.alloc_expr(ir.Expr.expr_binary(operator = "!=", left = left, right = right, ty = bool_ty))
                            var guard_body = vec.Vec[ir.Stmt].create()
                            guard_body.push(ir.Stmt.stmt_goto(label = next_arm_label))
                            blk.push(ir.Stmt.stmt_if(condition = cond, then_body = guard_body.as_span(), else_body = Option[span[ir.Stmt]].some(value = span[ir.Stmt]())))
                        Option.none:
                            pass
                    match read(arg.arg_value):
                        ast.Expr.expr_identifier as id:
                            if not id.name == "_":
                                let field_ty = variant_arm_field_type(arm_info, id.name)
                                let bc = utils.c_local_name(id.name)
                                let payload_ref = lowering.alloc_expr(ir.Expr.expr_name(name = payload_c, ty = payload_ty, pointer = Option[bool].some(value = false)))
                                var field_expr = lowering.alloc_expr(ir.Expr.expr_member(receiver = payload_ref, member = id.name, ty = field_ty))
                                # Auto-dereference recursive variant fields.
                                match payload_ty:
                                    types.Type.ty_named as pn:
                                        let pn_np = unsafe: read(pn.payload)
                                        if ctx.arm_payload_fields.contains(pn_np.name) and is_recursive_variant_field(payload_ty, field_ty):
                                            field_expr = lowering.alloc_expr(ir.Expr.expr_unary(operator = "*", operand = field_expr, ty = field_ty))
                                    types.Type.ty_imported as pi:
                                        if ctx.arm_payload_fields.contains(naming.qualified_c_name(pi.module_name, pi.name)) and is_recursive_variant_field(payload_ty, field_ty):
                                            field_expr = lowering.alloc_expr(ir.Expr.expr_unary(operator = "*", operand = field_expr, ty = field_ty))
                                    _:
                                        pass
                                if ctx.async_cps_active:
                                    let vfield = strings.join_four("local_", payload_c, "_", id.name)
                                    let vcname = strings.join_two("__mt_frame->", vfield)
                                    async_cps.async_register_local_field(ctx, id.name, vfield, vcname, field_ty)
                                    blk.push(ir.Stmt.stmt_assignment(target = lowering.alloc_expr(ir.Expr.expr_name(name = vcname, ty = field_ty, pointer = Option[bool].some(value = false))), operator = "=", value = field_expr))
                                else:
                                    blk.push(ir.Stmt.stmt_local(name = id.name, linkage_name = bc, ty = field_ty, value = field_expr, line = 0, source_path = ""))
                                    ctx.locals.push(lowering.LocalBinding(name = id.name, c_name = bc, ty = field_ty, pointer = Option[bool].some(value = false)))
                        ast.Expr.expr_binary_op as b:
                            # Guard pattern: `field comparison_op expr` —
                            # skip arm if guard condition is false.
                            # The left side must be a bare identifier (field name);
                            # we resolve it against the payload struct.
                            var left_name: str = ""
                            unsafe:
                                match read(b.left):
                                    ast.Expr.expr_identifier as lid:
                                        left_name = lid.name
                                    _:
                                        pass
                            if left_name != "":
                                let field_ty = variant_arm_field_type(arm_info, left_name)
                                let payload_ref = lowering.alloc_expr(ir.Expr.expr_name(name = payload_c, ty = payload_ty, pointer = Option[bool].some(value = false)))
                                let left_expr = lowering.alloc_expr(ir.Expr.expr_member(receiver = payload_ref, member = left_name, ty = field_ty))
                                let right_expr = lowering.lower_expr(ctx, b.right)
                                let cond = lowering.alloc_expr(ir.Expr.expr_binary(operator = b.operator, left = left_expr, right = right_expr, ty = bool_ty))
                                var guard_fail = vec.Vec[ir.Stmt].create()
                                guard_fail.push(ir.Stmt.stmt_goto(label = next_arm_label))
                                blk.push(ir.Stmt.stmt_if(condition = cond, then_body = span[ir.Stmt](), else_body = Option[span[ir.Stmt]].some(value = guard_fail.as_span())))
                        _:
                            pass
                    i += 1
            _:
                pass


## The arm name of a variant match pattern: `Variant.arm` (member access) or
## `Variant.arm(...)` (call whose callee is that member access).
public function variant_match_arm_name_from_pattern(pattern: ptr[ast.Expr]) -> Option[str]:
    unsafe:
        match read(pattern):
            ast.Expr.expr_member_access as ma:
                return Option[str].some(value = ma.member_name)
            ast.Expr.expr_call as cl:
                return match_member_name(cl.callee)
            _:
                return Option[str].none


## The type of a named field within a variant arm, or `ty_error` when absent.
function variant_arm_field_type(arm_info: lowering.VariantArmInfo, field_name: str) -> types.Type:
    var i: ptr_uint = 0
    while i < arm_info.field_names.len:
        unsafe:
            if read(arm_info.field_names.data + i) == field_name:
                return read(arm_info.field_types.data + i)
        i += 1
    return types.Type.ty_error


## `__mt_match_<m>_<suffix>` label name.
function match_label_name(m: ptr_uint, suffix: str) -> str:
    var buf = string.String.create()
    buf.append("__mt_match_")
    fmt.append_ptr_uint(ref_of(buf), m)
    buf.append("_")
    buf.append(suffix)
    return buf.as_str()


## `__mt_match_<m>_arm_<index>` label name.
function match_arm_label(m: ptr_uint, index: ptr_uint) -> str:
    var buf = string.String.create()
    buf.append("__mt_match_")
    fmt.append_ptr_uint(ref_of(buf), m)
    buf.append("_arm_")
    fmt.append_ptr_uint(ref_of(buf), index)
    return buf.as_str()


## The `types.Type` name for a variant arm's payload struct so it renders as the
## arm C name (`Token` + `ident` -> `Token_ident`, then `<module>_Token_ident`).
public function variant_arm_type_name(outer_c: str, arm_name: str) -> str:
    var buf = string.String.create()
    buf.append(outer_c)
    buf.append("_")
    buf.append(arm_name)
    return buf.as_str()


## The module that owns a prelude variant's arm-payload binding type.  A local
## variant's `VariantInfo.module_name` is authoritative; a prelude variant is
## registered module-less, so fall back to its standard module.
function variant_arm_owner_module(variant_name: str, owner_module: str) -> str:
    if owner_module.len > 0:
        return owner_module
    if variant_name == "Option":
        return "std.option"
    if variant_name == "Result":
        return "std.result"
    return ""


## The `as name` binding type of a variant match arm, tagged `VariantArmPayload`
## (base variant name + module for rendering, payload C name for codegen).
public function variant_arm_payload_binding(variant_name: str, owner_module: str, outer_c: str, arm_name: str) -> types.Type:
    return types.variant_arm_payload(
        variant_name = variant_name,
        module_name = variant_arm_owner_module(variant_name, owner_module),
        c_name = variant_arm_type_name(outer_c, arm_name),
        arm_name = arm_name,
    )


## The declared name and owning module of a variant-typed storage
## (`Option[int]` -> ("Option", "std.option")), used to tag guard projections.
public function variant_declared_identity(ty: types.Type, fallback_module: str) -> (str, str):
    match ty:
        types.Type.ty_generic as g:
            return (g.name, variant_arm_owner_module(g.name, ""))
        types.Type.ty_imported as im:
            if is_prelude_variant_name(im.name):
                return (im.name, variant_arm_owner_module(im.name, ""))
            return (im.name, im.module_name)
        types.Type.ty_named as n:
            let n_np = unsafe: read(n.payload)
            if is_prelude_variant_name(n_np.name):
                return (n_np.name, variant_arm_owner_module(n_np.name, ""))
            return (n_np.name, if n_np.module_name.len > 0: n_np.module_name else: fallback_module)
        _:
            return ("", fallback_module)


## The `ctx.variants` key for a variant reference.  Two modules may declare the
## same variant name (`mtc.ir.Expr` and `mtc.parser.ast.Expr`); the scrutinee
## type's own module selects the right entry, and the bare name stays the
## fallback (prelude variants and single-module programs).
function variant_registry_key(ctx: ref[lowering.LoweringContext], variant_name: str, ty: types.Type) -> str:
    var base = variant_name
    let bn = variant_base_name(variant_name)
    if bn.is_some():
        base = bn.unwrap()
    let (_, decl_module) = variant_declared_identity(ty, ctx.module_name)
    if decl_module.len > 0:
        let qualified = strings.join_two(strings.join_two(decl_module, "."), base)
        if ctx.variants.contains(qualified):
            return qualified
    return variant_name


## Record a match-arm payload binding's field info under its payload struct C
## name, so member access on the binding (e.g. `un.operator`) resolves field
## types via `arm_payload_field_type`.  Prelude Option/Result arms carry a
## `_phantom` placeholder payload type (their VariantInfo is generic); it is
## specialized here against the scrutinee's concrete type args so `s.value` /
## `f.error` resolve to the real type instead of an undeclared `_phantom` C type.
public function register_arm_payload_fields(ctx: ref[lowering.LoweringContext], payload_c_name: str, info: lowering.VariantInfo, arm_name: str, scrutinee_ty: types.Type) -> void:
    # An entry may already be registered by `install_imported_variants`, keyed by
    # the module-qualified payload C name with field types resolved in the OWNER
    # module's context.  That entry is authoritative and must not be overwritten
    # here: `info` comes from `ctx.variants[base_name]`, which for a bare name that
    # collides across modules (e.g. both `ir.Stmt` and `ast.Stmt` are "Stmt") may
    # be the WRONG module's variant.  Only (re)register when absent, or when this
    # is a prelude variant (whose `_phantom` placeholder must be specialized
    # against the concrete scrutinee type args at each match site).
    if ctx.arm_payload_fields.contains(payload_c_name) and not is_prelude_variant_name(payload_c_name):
        return
    var i: ptr_uint = 0
    while i < info.arms.len:
        var arm_info: lowering.VariantArmInfo
        unsafe:
            arm_info = read(info.arms.data + i)
        if arm_info.name == arm_name:
            ctx.arm_payload_fields.set(payload_c_name, specialize_prelude_arm_info(ctx, arm_info, arm_name, payload_c_name, scrutinee_ty))
            return
        i += 1


## Replace any `_phantom` placeholder field type in a prelude arm's info with the
## concrete payload field type.  Prelude Option/Result VariantInfo carries a
## `_phantom` placeholder because it is registered generically; the concrete arm
## field types are already computed when the concrete generic variant is emitted
## (`ensure_generic_variant`), keyed by the outer C name embedded in
## `payload_c_name` (`<outer_c>_<arm>`).  We look the field type up there first
## (works even when the scrutinee type has already collapsed to a concrete
## `ty_named` with no args), then fall back to the scrutinee's own type args, then
## to the placeholder (no worse than before).
function specialize_prelude_arm_info(ctx: ref[lowering.LoweringContext], arm_info: lowering.VariantArmInfo, arm_name: str, payload_c_name: str, scrutinee_ty: types.Type) -> lowering.VariantArmInfo:
    var changed = false
    var new_types = vec.Vec[types.Type].create()
    var i: ptr_uint = 0
    while i < arm_info.field_types.len:
        var ft: types.Type
        unsafe:
            ft = read(arm_info.field_types.data + i)
        if is_phantom_type(ft):
            match concrete_prelude_field_type(ctx, payload_c_name, arm_name, scrutinee_ty):
                Option.some as resolved:
                    new_types.push(resolved.value)
                    changed = true
                Option.none:
                    new_types.push(ft)
        else:
            new_types.push(ft)
        i += 1

    if not changed:
        return arm_info

    return lowering.VariantArmInfo(name = arm_info.name, field_names = arm_info.field_names, field_types = new_types.as_span())


## Resolve a prelude arm's concrete payload field type.  `payload_c_name` is the
## concrete payload struct C name (`Option_std_string_String_some`); its concrete
## variant decl in `pending_generic_variants` carries the real field type.  Falls
## back to the scrutinee's own type args when the decl is not (yet) recorded.
public function concrete_prelude_field_type(ctx: ref[lowering.LoweringContext], payload_c_name: str, arm_name: str, scrutinee_ty: types.Type) -> Option[types.Type]:
    # Program-wide registry first: the concrete Option/Result decl may have been
    # emitted in a different module's context (e.g. `Result[String, Error]` from
    # `fs.read_text`), so its arm field type is not in this ctx's
    # `pending_generic_variants`.  The stored type is already qualified — return
    # it as-is (re-qualifying would mis-attribute its concrete C name).
    let shared_ty_ptr = unsafe: read(ctx.prelude_arm_field_types).get(payload_c_name)
    if shared_ty_ptr != null:
        return Option[types.Type].some(value = unsafe: read(shared_ty_ptr))

    match prelude_field_type_from_variants(ctx, payload_c_name, arm_name):
        Option.some as decl_ty:
            return Option[types.Type].some(value = decl_ty.value)
        Option.none:
            pass

    let args = variant_type_args(scrutinee_ty)
    let arg_index = if arm_name == "failure": 1z else: 0z
    if arg_index < args.len:
        unsafe:
            return Option[types.Type].some(value = lowering.qualify_type(ctx, read(args.data + arg_index)))
    return Option[types.Type].none


## Look up an arm's single payload field type from the concrete generic variant
## decl recorded in `pending_generic_variants`.  `payload_c_name` is the arm's
## concrete payload struct C name (`<outer_c>_<arm>`), which matches an arm's
## `linkage_name` in the outer decl.
function prelude_field_type_from_variants(ctx: ref[lowering.LoweringContext], payload_c_name: str, arm_name: str) -> Option[types.Type]:
    var vi: ptr_uint = 0
    while vi < ctx.pending_generic_variants.len():
        let vp = ctx.pending_generic_variants.get(vi) else:
            break
        unsafe:
            let vdecl = read(vp)
            var ai: ptr_uint = 0
            while ai < vdecl.arms.len:
                let arm = read(vdecl.arms.data + ai)
                if arm.name == arm_name and arm.linkage_name == payload_c_name and arm.fields.len > 0:
                    return Option[types.Type].some(value = read(arm.fields.data + 0).ty)
                ai += 1
        vi += 1
    return Option[types.Type].none


## The concrete type arguments of a variant scrutinee type (`Option[str]` →
## `[str]`), for both generic and imported forms; empty for others.
public function variant_type_args(ty: types.Type) -> span[types.Type]:
    match ty:
        types.Type.ty_generic as g:
            return g.args
        types.Type.ty_imported as im:
            return im.args
        _:
            return span[types.Type]()


## True when a type is the prelude arm-payload `_phantom` placeholder `ty_named`.
function is_phantom_type(t: types.Type) -> bool:
    match t:
        types.Type.ty_named as n:
            let n_np = unsafe: read(n.payload)
            return n_np.name == "_phantom"
        _:
            return false


## True when field_ty references the same variant that recv_ty is an arm payload of.
public function is_recursive_variant_field(recv_ty: types.Type, field_ty: types.Type) -> bool:
    var recv_c: str
    match recv_ty:
        types.Type.ty_named as rn:
            let rn_np = unsafe: read(rn.payload)
            recv_c = rn_np.name
        types.Type.ty_imported as ri:
            recv_c = naming.qualified_c_name(ri.module_name, ri.name)
        # A match binding is typed as the arm payload struct directly
        # (`Result.success as p` → `ty_variant_arm_payload`), which already
        # carries the payload's C name.
        types.Type.ty_variant_arm_payload as rap:
            recv_c = unsafe: read(rap.payload).c_name
        _:
            return false
    var field_c: str
    match field_ty:
        types.Type.ty_named as nt:
            let nt_np = unsafe: read(nt.payload)
            field_c = naming.qualified_c_name("", nt_np.name)
        types.Type.ty_imported as fi:
            field_c = naming.qualified_c_name(fi.module_name, fi.name)
        _:
            return false
    # The arm payload C name is "<variant_c>_<arm>" (e.g.
    # "examples_Expr_binary_op").  If the field type's C name is a prefix
    # (e.g. "examples_Expr"), the field references the enclosing variant.
    if recv_c.len > field_c.len and recv_c.starts_with(field_c):
        return true
    # Also check bare names.
    match field_ty:
        types.Type.ty_named as nt2:
            let nt2_np = unsafe: read(nt2.payload)
            if recv_c.starts_with(nt2_np.name):
                return true
        types.Type.ty_imported as fi2:
            if recv_c.starts_with(fi2.name):
                return true
        _:
            pass
    return false


## Like is_recursive_variant_field but using a pre-computed arm payload C name.
public function is_recursive_variant_field_c(payload_c: str, field_ty: types.Type) -> bool:
    var field_c: str
    match field_ty:
        types.Type.ty_named as nt:
            let nt_np = unsafe: read(nt.payload)
            field_c = naming.qualified_c_name("", nt_np.name)
        types.Type.ty_imported as fi:
            field_c = naming.qualified_c_name(fi.module_name, fi.name)
        _:
            return false
    return payload_c.len > field_c.len and payload_c.starts_with(field_c)


## C-type name of a variant type.
public function variant_c_type_name(ty: types.Type) -> str:
    match ty:
        types.Type.ty_imported:
            # `type_c_key` keeps a concrete generic instance's argument suffix;
            # a bare `qualified_c_name` would drop it.
            return naming.type_c_key(ty)
        types.Type.ty_generic:
            return naming.type_c_key(ty)
        _:
            return ""


## Look up the type of a field in a variant arm by name.
public function variant_field_type_from_arm(ctx: ref[lowering.LoweringContext], variant_ty: types.Type, arm_name: str, field_name: str) -> Option[types.Type]:
    var variant_c: str
    match variant_ty:
        types.Type.ty_imported:
            # Same key shape as `variant_c_type_name`: a concrete generic
            # instance's arguments are part of its C name.
            variant_c = naming.type_c_key(variant_ty)
        types.Type.ty_generic:
            variant_c = naming.type_c_key(variant_ty)
        _:
            return Option[types.Type].none
    var arm_key = string.String.create()
    arm_key.append(variant_c)
    arm_key.append("_")
    arm_key.append(arm_name)
    var arm_ptr = ctx.arm_payload_fields.get(arm_key.as_str())
    if arm_ptr == null:
        # A *prelude* variant instance constructed before any match registered
        # its arm fields (`Option[ptr_uint].some(value = 0)` in std/str.mt):
        # register them on demand, the same specialization the `?`-propagation
        # path and the match path do (session 43, item 3o).
        match variant_info_for_c_name(ctx, variant_c):
            Option.some as vi:
                register_arm_payload_fields(ctx, arm_key.as_str(), vi.value, arm_name, variant_ty)
                arm_ptr = ctx.arm_payload_fields.get(arm_key.as_str())
            Option.none:
                pass
    let arm_entry = arm_ptr else:
        return Option[types.Type].none
    let arm_info = unsafe: read(arm_entry)
    var fi: ptr_uint = 0
    while fi < arm_info.field_names.len:
        unsafe:
            if read(arm_info.field_names.data + fi) == field_name:
                return Option[types.Type].some(value = read(arm_info.field_types.data + fi))
        fi += 1
    return Option[types.Type].none


## The installed `VariantInfo` a concrete variant C name specializes from: a
## prelude instance (`std_option_Option_ptr_uint`) maps back to its generic
## declaration (`Option`/`Result`); any other name has no registry entry.
function variant_info_for_c_name(ctx: ref[lowering.LoweringContext], variant_c: str) -> Option[lowering.VariantInfo]:
    if not is_prelude_variant_name(variant_c):
        return Option[lowering.VariantInfo].none
    var base_name = ""
    if variant_c.starts_with("std_result_"):
        base_name = "Result"
    else if variant_c.starts_with("std_option_"):
        base_name = "Option"
    if base_name.len == 0:
        return Option[lowering.VariantInfo].none
    let vi_ptr = ctx.variants.get(base_name) else:
        return Option[lowering.VariantInfo].none
    return Option[lowering.VariantInfo].some(value = unsafe: read(vi_ptr))


## Return the arm payload type from a struct name and source module.
public function payload_ty(ctx: ref[lowering.LoweringContext], struct_name: str, source_module: str) -> types.Type:
    if source_module.len == 0:
        return types.named_type(name = struct_name, module_name = "", linkage_name = Option[str].none)
    return types.Type.ty_imported(module_name = source_module, name = struct_name, args = span[types.Type]())


## The type of 'member' on a variant arm payload binding, looked up from the
## registered arm field info.  Returns none for non-arm-payload receivers.
public function arm_payload_field_type(ctx: ref[lowering.LoweringContext], recv_ty: types.Type, member: str) -> Option[types.Type]:
    var name: str
    match recv_ty:
        types.Type.ty_named as n:
            let n_np = unsafe: read(n.payload)
            name = n_np.name
        types.Type.ty_variant_arm_payload as ap:
            # The registry is keyed by the payload struct's C name.
            name = unsafe: read(ap.payload).c_name
        _:
            return Option[types.Type].none
    let arm_ptr = ctx.arm_payload_fields.get(name)
    if arm_ptr != null:
        let arm_info = unsafe: read(arm_ptr)
        var i: ptr_uint = 0
        while i < arm_info.field_names.len:
            unsafe:
                if read(arm_info.field_names.data + i) == member:
                    return Option[types.Type].some(value = read(arm_info.field_types.data + i))
            i += 1
    # Fallback for prelude Option/Result arm payload structs (e.g.
    # `Result_Option_Msg_int_success`): a plain `match` doesn't register the arm
    # in `arm_payload_fields`, but `ensure_generic_variant` records the single
    # payload field type (which may itself be a nested generic like `Option[Msg]`)
    # in the shared `prelude_arm_field_types` registry keyed by the arm C name.
    if member == "value" or member == "error":
        let shared = unsafe: read(ctx.prelude_arm_field_types).get(name)
        if shared != null:
            return Option[types.Type].some(value = unsafe: read(shared))
    return Option[types.Type].none


## The discriminant constant name for an arm: `<outer_c>_kind_<arm>`.
public function variant_kind_const_name(outer_c: str, arm_name: str) -> str:
    var buf = string.String.create()
    buf.append(outer_c)
    buf.append("_kind_")
    buf.append(arm_name)
    return buf.as_str()


## True when a lowered expression is a bare name reference (safe to reuse without
## hoisting, since re-rendering it has no side effects).
function ir_expr_is_name(ep: ptr[ir.Expr]) -> bool:
    unsafe:
        match read(ep):
            ir.Expr.expr_name:
                return true
            _:
                return false


function match_member_name(pattern: ptr[ast.Expr]) -> Option[str]:
    unsafe:
        match read(pattern):
            ast.Expr.expr_member_access as ma:
                return Option[str].some(value = ma.member_name)
            _:
                return Option[str].none


## Extract the base variant name from a generic variant type (`Option[int]` →
## "Option"), so match on a generic scrutinee can resolve prelude arm names.
public function generic_variant_name(t: types.Type) -> Option[str]:
    match t:
        types.Type.ty_generic as g:
            return Option[str].some(value = g.name)
        types.Type.ty_imported as im:
            if is_prelude_variant_name(im.name):
                return Option[str].some(value = im.name)
            return Option[str].none
        types.Type.ty_named as n:
            let n_np = unsafe: read(n.payload)
            if is_prelude_variant_name(n_np.name):
                return Option[str].some(value = n_np.name)
            return Option[str].none
        _:
            return Option[str].none

function variant_match_allowed(ctx: ref[lowering.LoweringContext], name: str) -> bool:
    if ctx.variants.contains(name):
        return true
    match prelude_variant_base(name):
        Option.some:
            return true
        Option.none:
            return false

## Extract the base prelude variant name from a qualified concrete variant name.
## "std_map_Option_std_map_RemovedEntry_ptr_uint_bool" → Some("Option").
## "Option_str" → Some("Option").  Non-prelude names return none.
public function prelude_variant_base(name: str) -> Option[str]:
    if name == "Option" or name == "Result":
        return Option[str].some(value = name)
    # The base variant is the *outermost* Option/Result segment.  In a nested
    # concrete name like `std_result_Result_std_option_Option_int` the type
    # argument key mentions Option, but the variant itself is Result.
    var best: ptr_uint = 0
    var found = false
    var base = ""
    match name.find_substring("_Option_"):
        Option.some as idx:
            best = idx.value
            found = true
            base = "Option"
        Option.none:
            pass
    match name.find_substring("_Result_"):
        Option.some as idx:
            if not found or idx.value < best:
                best = idx.value
                found = true
                base = "Result"
        Option.none:
            pass
    if found:
        return Option[str].some(value = base)
    if name.starts_with("Option_"):
        return Option[str].some(value = "Option")
    if name.starts_with("Result_"):
        return Option[str].some(value = "Result")
    return Option[str].none


## True when a type name is a prelude variant (Option/Result), either bare
## or embedded in a qualified concrete name (e.g. "std_map_Option_...").
public function is_prelude_variant_name(name: str) -> bool:
    return (
        name == "Option" or name == "Result"
        or name.starts_with("Option_") or name.starts_with("Result_")
        or name.contains_substring("_Option_") or name.contains_substring("_Result_")
    )


## Extract the base variant name from a qualified name like "Option_span_Field" → "Option",
## or "std_option_Option_int" → "Option".  Uses the same detection logic as
## `is_prelude_variant_name` to handle multi-part qualified names.
function variant_base_name(name: str) -> Option[str]:
    return prelude_variant_base(name)
