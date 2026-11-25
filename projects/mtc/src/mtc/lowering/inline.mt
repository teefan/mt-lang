## Compile-time inline control flow — `when`, inline if/match/while/for, and
## inline-for substitution and condition folding.  Extracted from
## lowering/lowering.mt.

import std.vec as vec
import std.map as map_mod

import mtc.ir as ir
import mtc.parser.ast as ast
import mtc.semantic.types as types

import mtc.lowering.comptime as comptime
import mtc.lowering.comptime_types as comptime_types
import mtc.lowering.const_eval as const_eval
import mtc.lowering.control_flow as control_flow
import mtc.lowering.lowering as lowering
import mtc.lowering.utils as utils


## Lower a `when` statement: evaluate the discriminant at compile time,
## find the matching branch, and only emit that branch's body.
public function lower_when_stmt(
    ctx: ref[lowering.LoweringContext],
    output: ref[vec.Vec[ir.Stmt]],
    discriminant: ptr[ast.Expr],
    branches: span[ast.WhenBranch],
    else_body: ptr[ast.Stmt]?
) -> void:
    match const_eval.try_evaluate_const_expr(ctx, discriminant):
        Option.some as val:
            var i: ptr_uint = 0
            while i < branches.len:
                var br: ast.WhenBranch
                unsafe:
                    br = read(branches.data + i)
                match const_eval.try_evaluate_const_expr(ctx, br.pattern):
                    Option.some as pv:
                        if comptime.const_values_equal(val.value, pv.value):
                            lowering.lower_span_stmts(ctx, output, br.body)
                            return
                    Option.none:
                        pass
                i += 1
            let eb = else_body
            if eb != null:
                lowering.lower_block_stmts(ctx, output, eb)
        Option.none:
            pass


## Lower an `inline if` statement.  Evaluate the condition; if true, emit
## the then-branch; otherwise emit the else branch (if present).
public function lower_inline_if_statement(
    ctx: ref[lowering.LoweringContext],
    output: ref[vec.Vec[ir.Stmt]],
    branches: span[ast.IfBranch],
    else_body: ptr[ast.Stmt]?
) -> void:
    if branches.len == 0:
        return
    # Each `else if` is its own branch with its own condition; evaluate them in
    # order and emit the first branch whose compile-time condition is true.
    var i: ptr_uint = 0
    while i < branches.len:
        var br: ast.IfBranch
        unsafe:
            br = read(branches.data + i)
        match const_eval.try_evaluate_const_expr(ctx, br.condition):
            Option.some as val:
                match val.value:
                    comptime_types.ConstValue.cv_bool as bv:
                        if bv.value:
                            lowering.lower_block_stmts(ctx, output, br.body)
                            return
                        # False: fall through to the next `else if` / `else`.
                    _:
                        # Non-bool discriminant: cannot select a branch.
                        return
            Option.none:
                # Can't evaluate at compile time: emit nothing (like Ruby).
                return
        i += 1
    # No branch condition held: emit the trailing `else` body, if any.
    let el = else_body
    if el != null:
        lowering.lower_block_stmts(ctx, output, el)


## Lower an `inline match` statement.  Evaluate the scrutinee and only emit
## the matching arm's body.  If no arm matches, emit the wildcard or nothing.
public function lower_inline_match_statement(
    ctx: ref[lowering.LoweringContext],
    output: ref[vec.Vec[ir.Stmt]],
    scrutinee: ptr[ast.Expr],
    arms: span[ast.MatchArm]
) -> void:
    match const_eval.try_evaluate_const_expr(ctx, scrutinee):
        Option.some as val:
            var i: ptr_uint = 0
            while i < arms.len:
                var arm: ast.MatchArm
                unsafe:
                    arm = read(arms.data + i)
                if arm.pattern == null:
                    if arm.body != null:
                        unsafe:
                            lowering.lower_block_stmts(ctx, output, ptr[ast.Stmt]<-arm.body)
                    return
                let pattern_ptr = arm.pattern else:
                    return
                match const_eval.try_evaluate_const_expr(ctx, pattern_ptr):
                    Option.some as pv:
                        if comptime.const_values_equal(val.value, pv.value):
                            if arm.body != null:
                                unsafe:
                                    lowering.lower_block_stmts(ctx, output, ptr[ast.Stmt]<-arm.body)
                            return
                    Option.none:
                        pass
                i += 1
        Option.none:
            pass

## Lower an `inline while` statement.  Evaluate the condition at compile time;
## if constantly true, unroll the loop body (capped at MAX_INLINE_WHILE_ITERS).
## Mirrors Ruby's lower_inline_while_stmt.
const MAX_INLINE_WHILE_ITERS: ptr_uint = 10000


public function lower_inline_while(
    ctx: ref[lowering.LoweringContext],
    output: ref[vec.Vec[ir.Stmt]],
    condition: ptr[ast.Expr],
    body_ptr: ptr[ast.Stmt]?
) -> void:
    let body = body_ptr else:
        return
    var iter: ptr_uint = 0
    while iter < MAX_INLINE_WHILE_ITERS:
        match const_eval.try_evaluate_const_expr(ctx, condition):
            Option.some as val:
                match val.value:
                    comptime_types.ConstValue.cv_bool as bv:
                        if not bv.value:
                            return
                    _:
                        return
            Option.none:
                return
        lowering.lower_block_stmts(ctx, output, body)
        iter += 1


## Lower an `inline for` statement: evaluate the iterable at compile time and
## unroll the loop body once per element, binding the loop variable to each
## element in turn.  Mirrors Ruby's lower_inline_for_stmt.
public function lower_inline_for_stmt(
    ctx: ref[lowering.LoweringContext],
    output: ref[vec.Vec[ir.Stmt]],
    bindings: span[ast.ForBinding],
    iterables: span[ast.Expr],
    body_ptr: ptr[ast.Stmt]?
) -> void:
    if bindings.len != 1 or iterables.len != 1:
        return
    var binding_name: str
    unsafe:
        binding_name = read(bindings.data + 0).name

    var first_iterable: ast.Expr
    unsafe:
        first_iterable = read(iterables.data + 0)
    match comptime.comptime_iterable_elements(ctx, ptr_of(first_iterable)):
        Option.some as elements:
            var i: ptr_uint = 0
            while i < elements.value.len:
                let bp = body_ptr
                if bp != null:
                    var elem: comptime_types.ComptimeElement
                    unsafe:
                        elem = read(elements.value.data + i)
                    # For struct fields: check if the body is a type-guard pattern
                    # `if field.type != X: return false` and evaluate at comptime.
                    lower_inline_for_iteration(ctx, output, binding_name, elem, bp)
                i += 1
        Option.none:
            pass


## Lower one iteration of an inline for loop.  For struct fields, detect and
## handle `size_of(field.type)` and `field.type != X` patterns at comptime.
## For enum members and attributes, emit the body with a dummy binding.
function lower_inline_for_iteration(
    ctx: ref[lowering.LoweringContext],
    output: ref[vec.Vec[ir.Stmt]],
    binding_name: str,
    elem: comptime_types.ComptimeElement,
    body_ptr: ptr[ast.Stmt]
) -> void:
    match elem:
        comptime_types.ComptimeElement.ce_struct_field as f:
            lower_inline_for_field_iter(ctx, output, binding_name, f.name, f.field_type, body_ptr)
        _:
            var iter_stmts = vec.Vec[ir.Stmt].create()
            let binding_c = utils.c_local_name(binding_name)
            # The host binds the loop variable as a compile-time constant
            # (`const_value` + `substitute_const_value`): no local is declared;
            # member reads (`.name`, `.value`) are substituted.
            ctx.locals.push(lowering.LocalBinding(
                name = binding_name,
                c_name = binding_c,
                ty = types.primitive("int"),
                pointer = Option[bool].some(value = false)
            ))
            ctx.inline_for_element = Option[comptime_types.ComptimeElement].some(value = elem)
            lowering.lower_block_stmts(ctx, ref_of(iter_stmts), body_ptr)
            ctx.inline_for_element = Option[comptime_types.ComptimeElement].none
            ctx.locals.pop()
            if iter_stmts.len() > 0:
                output.push(ir.Stmt.stmt_block(body = iter_stmts.as_span()))


## Lower one inline for iteration over a struct field, handling size_of(field.type).
function lower_inline_for_field_iter(
    ctx: ref[lowering.LoweringContext],
    output: ref[vec.Vec[ir.Stmt]],
    binding_name: str,
    field_name: str,
    field_ty: types.Type,
    body_ptr: ptr[ast.Stmt]
) -> void:
    ctx.inline_for_element = Option[comptime_types.ComptimeElement].some(value = comptime_types.ComptimeElement.ce_struct_field(
        name = field_name,
        field_type = field_ty
    ))
    var iter_stmts = vec.Vec[ir.Stmt].create()
    let binding_c = utils.c_local_name(binding_name)
    # The host binds the field handle as a compile-time constant and declares no
    # local; `field.type` / `field.name` reads are substituted, and a body that
    # folds away entirely contributes no block.
    ctx.locals.push(lowering.LocalBinding(
        name = binding_name,
        c_name = binding_c,
        ty = field_ty,
        pointer = Option[bool].some(value = false)
    ))
    lower_inline_for_field_body(ctx, ref_of(iter_stmts), body_ptr, field_ty)
    ctx.locals.pop()
    ctx.inline_for_element = Option[comptime_types.ComptimeElement].none
    if iter_stmts.len() > 0:
        output.push(ir.Stmt.stmt_block(body = iter_stmts.as_span()))


function lower_inline_for_field_body(
    ctx: ref[lowering.LoweringContext],
    output: ref[vec.Vec[ir.Stmt]],
    body: ptr[ast.Stmt],
    field_ty: types.Type
) -> void:
    var processed = false
    unsafe:
        match read(body):
            ast.Stmt.stmt_block as blk:
                lower_inline_for_field_stmts(ctx, output, blk.statements, field_ty)
                processed = true
            _:
                pass
    if not processed:
        if not lower_inline_field_type_guard(ctx, output, body, field_ty):
            lowering.lower_stmt(ctx, output, body)


function lower_inline_for_field_stmts(
    ctx: ref[lowering.LoweringContext],
    output: ref[vec.Vec[ir.Stmt]],
    stmts: span[ast.Stmt],
    field_ty: types.Type
) -> void:
    var i: ptr_uint = 0
    while i < stmts.len:
        unsafe:
            lower_inline_for_field_body(ctx, output, stmts.data + i, field_ty)
        i += 1


## Try to lower `if field.type != X: return false` at comptime.
function lower_inline_field_type_guard(
    ctx: ref[lowering.LoweringContext],
    output: ref[vec.Vec[ir.Stmt]],
    sp: ptr[ast.Stmt],
    field_ty: types.Type
) -> bool:
    var br: ast.IfBranch
    var body: ptr[ast.Stmt]?
    unsafe:
        match read(sp):
            ast.Stmt.stmt_if as iff:
                if iff.branches.len != 1:
                    return false
                br = read(iff.branches.data + 0)
            _:
                return false
    match extract_field_type_compare(ctx, br.condition, field_ty):
        Option.some as matches:
            if matches.value:
                lowering.lower_block_stmts(ctx, output, br.body)
            return true
        Option.none:
            return false


function extract_field_type_compare(
    ctx: ref[lowering.LoweringContext],
    cond: ptr[ast.Expr],
    field_ty: types.Type
) -> Option[bool]:
    unsafe:
        match read(cond):
            ast.Expr.expr_binary_op as bin:
                if bin.operator == "==" or bin.operator == "!=":
                    let rhs_ty = comptime.comptime_expr_to_type(ctx, bin.right)
                    if not types.is_error(rhs_ty):
                        let equal = types.type_to_string(field_ty) == types.type_to_string(rhs_ty)
                        if bin.operator == "==":
                            return Option[bool].some(value = equal)
                        return Option[bool].some(value = not equal)
            _:
                pass
    return Option[bool].none


## While lowering an inline for body, detect member access on the loop variable
## (`.value` for enum members, `.type` for struct fields) and substitute the
## comptime-known value.
public function inline_for_member_subst(
    ctx: ref[lowering.LoweringContext],
    receiver: ptr[ast.Expr],
    member: str
) -> Option[ptr[ir.Expr]]:
    match ctx.inline_for_element:
        Option.some as elem_val:
            match elem_val.value:
                comptime_types.ComptimeElement.ce_enum_member as m:
                    unsafe:
                        match read(receiver):
                            ast.Expr.expr_identifier as id:
                                if member == "value":
                                    return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_integer_literal(
                                        value = m.member_value,
                                        ty = types.primitive("int")
                                    )))
                                if member == "name":
                                    return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_string_literal(
                                        value = m.name,
                                        ty = types.Type.ty_str,
                                        cstring = false
                                    )))
                            _:
                                pass
                comptime_types.ComptimeElement.ce_struct_field as f:
                    unsafe:
                        match read(receiver):
                            ast.Expr.expr_identifier as id:
                                if member == "type":
                                    return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_name(
                                        name = "sizeof_hint",
                                        ty = f.field_type,
                                        pointer = Option[bool].some(value = false)
                                    )))
                                if member == "name":
                                    return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_string_literal(
                                        value = f.name,
                                        ty = types.Type.ty_str,
                                        cstring = false
                                    )))
                            _:
                                pass
                _:
                    pass
        Option.none:
            pass
    return Option[ptr[ir.Expr]].none


## Resolve `field.type` in type position inside an inline for body: when the
## current comptime element is a struct field and the binding name matches,
## return the field's concrete type.
public function inline_for_type_subst(ctx: ref[lowering.LoweringContext], binding_name: str) -> types.Type:
    match ctx.inline_for_element:
        Option.some as elem_val:
            match elem_val.value:
                comptime_types.ComptimeElement.ce_struct_field as f:
                    # Check if there's a local binding with this name.  We can't
                    # directly check by name since the binding could be from
                    # another scope.  Assume the binding_name matches the current
                    # inline for element.
                    return f.field_type
                _:
                    pass
        Option.none:
            pass
    return types.Type.ty_error


## Compile-time value of an expression inside an inline-for body: literals, a
## type identifier, and the active comptime element's members (`field.name`,
## `field.type`, `member.name`, `member.value`).  The host evaluates the same
## way through the loop variable's `const_value` substitution.
function inline_for_eval_const(
    ctx: ref[lowering.LoweringContext],
    ep: ptr[ast.Expr]
) -> Option[comptime_types.ConstValue]:
    unsafe:
        match read(ep):
            ast.Expr.expr_integer_literal as lit:
                return Option[comptime_types.ConstValue].some(value = comptime_types.ConstValue.cv_int(value = long<-lit.value))
            ast.Expr.expr_char_literal as c:
                return Option[comptime_types.ConstValue].some(value = comptime_types.ConstValue.cv_int(value = long<-c.value))
            ast.Expr.expr_bool_literal as b:
                return Option[comptime_types.ConstValue].some(value = comptime_types.ConstValue.cv_bool(value = b.value))
            ast.Expr.expr_string_literal as s:
                return Option[comptime_types.ConstValue].some(value = comptime_types.ConstValue.cv_str(value = s.value))
            ast.Expr.expr_identifier as id:
                if id.name == "true":
                    return Option[comptime_types.ConstValue].some(value = comptime_types.ConstValue.cv_bool(value = true))
                if id.name == "false":
                    return Option[comptime_types.ConstValue].some(value = comptime_types.ConstValue.cv_bool(value = false))
                match comptime.comptime_identifier_type(ctx, id.name):
                    Option.some as ty:
                        return Option[comptime_types.ConstValue].some(value = comptime_types.ConstValue.cv_type(ty = ty.value))
                    Option.none:
                        pass
            ast.Expr.expr_member_access as ma:
                match read(ma.receiver):
                    ast.Expr.expr_identifier:
                        match ctx.inline_for_element:
                            Option.some as elem_val:
                                match elem_val.value:
                                    comptime_types.ComptimeElement.ce_enum_member as m:
                                        if ma.member_name == "name":
                                            return Option[comptime_types.ConstValue].some(value = comptime_types.ConstValue.cv_str(value = m.name))
                                        if ma.member_name == "value":
                                            return Option[comptime_types.ConstValue].some(value = comptime_types.ConstValue.cv_int(value = m.member_value))
                                    comptime_types.ComptimeElement.ce_struct_field as f:
                                        if ma.member_name == "name":
                                            return Option[comptime_types.ConstValue].some(value = comptime_types.ConstValue.cv_str(value = f.name))
                                        if ma.member_name == "type":
                                            return Option[comptime_types.ConstValue].some(value = comptime_types.ConstValue.cv_type(ty = f.field_type))
                                    _:
                                        pass
                            Option.none:
                                pass
                    _:
                        pass
            ast.Expr.expr_prefix_cast as pc:
                return inline_for_eval_const(ctx, pc.expression)
            _:
                pass
    return Option[comptime_types.ConstValue].none


## Compile-time truth value of an inline-for body condition.  The host lowers a
## bypass-sema body's `if` through `compile_time_const_value`, dropping the
## branches whose condition folds (`block.rb:606-652`).
function inline_for_eval_bool(ctx: ref[lowering.LoweringContext], cond: ptr[ast.Expr]) -> Option[bool]:
    unsafe:
        match read(cond):
            ast.Expr.expr_bool_literal as b:
                return Option[bool].some(value = b.value)
            ast.Expr.expr_unary_op as u:
                if u.operator == "not":
                    match inline_for_eval_bool(ctx, u.operand):
                        Option.some as v:
                            return Option[bool].some(value = not v.value)
                        Option.none:
                            pass
            ast.Expr.expr_binary_op as bin:
                if bin.operator == "==" or bin.operator == "!=":
                    match inline_for_eval_const(ctx, bin.left):
                        Option.some as lv:
                            match inline_for_eval_const(ctx, bin.right):
                                Option.some as rv:
                                    let eq = comptime.const_values_equal(lv.value, rv.value)
                                    if bin.operator == "==":
                                        return Option[bool].some(value = eq)
                                    return Option[bool].some(value = not eq)
                                Option.none:
                                    pass
                        Option.none:
                            pass
                if bin.operator == "and":
                    match inline_for_eval_bool(ctx, bin.left):
                        Option.some as lv:
                            if not lv.value:
                                return Option[bool].some(value = false)
                            return inline_for_eval_bool(ctx, bin.right)
                        Option.none:
                            pass
                if bin.operator == "or":
                    match inline_for_eval_bool(ctx, bin.left):
                        Option.some as lv:
                            if lv.value:
                                return Option[bool].some(value = true)
                            return inline_for_eval_bool(ctx, bin.right)
                        Option.none:
                            pass
            ast.Expr.expr_identifier:
                match inline_for_eval_const(ctx, cond):
                    Option.some as cv:
                        match cv.value:
                            comptime_types.ConstValue.cv_bool as b:
                                return Option[bool].some(value = b.value)
                            _:
                                pass
                    Option.none:
                        pass
            _:
                pass
    return Option[bool].none


## Fold an `if` chain inside an inline-for body: a constant-true branch lowers
## alone, constant-false branches are dropped, and a runtime condition (none of
## the above) falls back to the ordinary chain from that branch.
public function lower_inline_for_if_fold(
    ctx: ref[lowering.LoweringContext],
    output: ref[vec.Vec[ir.Stmt]],
    branches: span[ast.IfBranch],
    else_body: ptr[ast.Stmt]?
) -> void:
    var bi: ptr_uint = 0
    while bi < branches.len:
        var br: ast.IfBranch
        unsafe:
            br = read(branches.data + bi)
        match inline_for_eval_bool(ctx, br.condition):
            Option.some as cv:
                if cv.value:
                    lowering.append_span_stmts(output, lowering.lower_block(ctx, br.body))
                    return
                bi += 1
            Option.none:
                var prior_false = map_mod.Map[str, types.Type].create()
                control_flow.lower_if_chain_at(ctx, output, branches, bi, else_body, ref_of(prior_false), true)
                return
    lowering.append_span_stmts(output, lowering.lower_block(ctx, else_body))
