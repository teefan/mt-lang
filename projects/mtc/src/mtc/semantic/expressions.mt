## Expression type inference helpers — pure functions for computing result types
## of compound expressions (if/match/proc/detach).  The main expression dispatch
## stays in analyzer.mt; this module contains the reusable type-combination logic.
##
## Mirrors Ruby's semantic_analyzer/expressions.rb helpers (conditional_common_type,
## match_expression_common_type) and the numeric predicates they build on
## (`common_numeric_type` / `common_integer_type`, types/predicates.rb).

import mtc.parser.ast as ast
import mtc.semantic.type_compatibility as compat
import mtc.semantic.types as types


## The common type of two branch types.  Follows Ruby's conditional_common_type:
## structural equality wins, then the common numeric type, then nullable-base
## unification, then the compatibility fallbacks (a branch that widens into the
## other's type makes the other the common type — `if flag: 0 else: <ptr_uint>`).
public function conditional_common_type(then_ty: types.Type, else_ty: types.Type, then_expr: ptr[ast.Expr]?, else_expr: ptr[ast.Expr]?) -> types.Type:
    # Identical types — the ideal case.
    if types.type_equals(then_ty, else_ty):
        return then_ty

    # Two numeric types unify at their numeric common type (`1` and `1.5` →
    # double, `int` and `long` → long).
    match common_numeric_type(then_ty, else_ty):
        Option.some as numeric_ty:
            return numeric_ty.value
        Option.none:
            pass

    # T?  and  T  →  T?   (nullable with compatible base).
    if types.is_nullable_type(then_ty):
        let base = types.unwrap_nullable(then_ty)
        if types.type_equals(base, else_ty) or types.is_error(else_ty):
            return then_ty

    if types.is_nullable_type(else_ty):
        let base = types.unwrap_nullable(else_ty)
        if types.type_equals(base, then_ty) or types.is_error(then_ty):
            return else_ty

    # If one side is permissive (ty_error), keep the concrete type.
    if types.is_error(then_ty):
        return else_ty
    if types.is_error(else_ty):
        return then_ty

    # A branch assignable to the other's type widens into it.  The source
    # expression matters: a compile-time numeric literal fits any numeric
    # target, while a concrete value widens only when the target can hold it
    # (`if flag: 0 else: count` with a `ptr_uint` count is a `ptr_uint`).
    if compat.types_compatible(then_ty, else_ty, else_expr):
        return then_ty
    if compat.types_compatible(else_ty, then_ty, then_expr):
        return else_ty

    # Fall back — different concrete types, can't unify.
    return types.Type.ty_error


## The common type across all arms of a match expression.  Folds
## conditional_common_type from left to right, keeping the arm expression that
## produced the running common type (the host's `match_expression_common_type`);
## returns ty_error for zero arms.
public function match_expression_common_type(arm_types: span[types.Type], arm_exprs: span[ptr[ast.Expr]]) -> types.Type:
    if arm_types.len == 0:
        return types.Type.ty_error

    var result = unsafe: read(arm_types.data + 0)
    var result_expr = Option[ptr[ast.Expr]].none
    if arm_exprs.len > 0:
        result_expr = Option[ptr[ast.Expr]].some(value = unsafe: read(arm_exprs.data + 0))
    var i: ptr_uint = 1
    while i < arm_types.len:
        unsafe:
            let arm_ty = read(arm_types.data + i)
            var arm_expr = Option[ptr[ast.Expr]].none
            if i < arm_exprs.len:
                arm_expr = Option[ptr[ast.Expr]].some(value = read(arm_exprs.data + i))
            if not types.type_equals(result, arm_ty):
                match result_expr:
                    Option.some as then_expr:
                        match arm_expr:
                            Option.some as else_expr:
                                result = conditional_common_type(result, arm_ty, then_expr.value, else_expr.value)
                            Option.none:
                                result = conditional_common_type(result, arm_ty, then_expr.value, null)
                    Option.none:
                        match arm_expr:
                            Option.some as else_expr:
                                result = conditional_common_type(result, arm_ty, null, else_expr.value)
                            Option.none:
                                result = conditional_common_type(result, arm_ty, null, null)
                result_expr = arm_expr
        i += 1
    return result


## The common numeric type of two types (mirrors Ruby's `common_numeric_type`):
## identical types pass through; two integers use `common_integer_type`; two
## floats use the wider float; a float paired with a fixed-width integer uses
## the float.
public function common_numeric_type(left: types.Type, right: types.Type) -> Option[types.Type]:
    if types.type_equals(left, right):
        return Option[types.Type].some(value = left)
    if not (types.is_numeric(left) and types.is_numeric(right)):
        return Option[types.Type].none
    if types.is_integer_type(left) and types.is_integer_type(right):
        return common_integer_type(left, right)
    if types.is_float_type(left) and types.is_float_type(right):
        return Option[types.Type].some(value = wider_float_type(left, right))
    let float_ty = if types.is_float_type(left): left else: right
    let int_ty = if types.is_float_type(left): right else: left
    if not (types.is_integer_type(int_ty) and types.is_fixed_width_integer_name(prim_name(int_ty))):
        return Option[types.Type].none
    return Option[types.Type].some(value = float_ty)


## The common integer type (mirrors Ruby's `common_integer_type`): identical
## types pass through; both must be fixed-width integers.  Same signedness takes
## the wider type; mixed signedness promotes to the narrowest signed type that
## holds both ranges, and has no answer once the unsigned side is 64-bit.
public function common_integer_type(left: types.Type, right: types.Type) -> Option[types.Type]:
    if types.type_equals(left, right):
        return Option[types.Type].some(value = left)
    if not (types.is_integer_type(left) and types.is_integer_type(right)):
        return Option[types.Type].none
    let left_name = prim_name(left)
    let right_name = prim_name(right)
    if not (types.is_fixed_width_integer_name(left_name) and types.is_fixed_width_integer_name(right_name)):
        return Option[types.Type].none
    if types.is_signed_integer_name(left_name) == types.is_signed_integer_name(right_name):
        if types.integer_width(left_name) >= types.integer_width(right_name):
            return Option[types.Type].some(value = left)
        return Option[types.Type].some(value = right)
    var signed_ty = left
    var unsigned_ty = right
    if not types.is_signed_integer_name(left_name):
        signed_ty = right
        unsigned_ty = left
    let signed_width = types.integer_width(prim_name(signed_ty))
    let unsigned_width = types.integer_width(prim_name(unsigned_ty))
    if signed_width > unsigned_width:
        return Option[types.Type].some(value = signed_ty)
    return signed_type_above_width(unsigned_width)


## The narrowest signed integer primitive wider than `width`; 64-bit unsigned
## operands have no safe signed common type (Ruby's `signed_type_above_width`).
public function signed_type_above_width(width: int) -> Option[types.Type]:
    if width == 8:
        return Option[types.Type].some(value = types.primitive("short"))
    if width == 16:
        return Option[types.Type].some(value = types.primitive("int"))
    if width == 32:
        return Option[types.Type].some(value = types.primitive("long"))
    return Option[types.Type].none


## The wider of two float primitives (mirrors Ruby's `wider_float_type`).
public function wider_float_type(left: types.Type, right: types.Type) -> types.Type:
    if float_width_of(left) >= float_width_of(right):
        return left
    return right


function float_width_of(t: types.Type) -> int:
    if prim_name(t) == "double":
        return 64
    return 32


## The primitive type name of `t`, or the empty string for non-primitives.
function prim_name(t: types.Type) -> str:
    match t:
        types.Type.ty_primitive as p:
            return p.name
        _:
            return ""
