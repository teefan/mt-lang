## Expression type inference helpers — pure functions for computing result types
## of compound expressions (if/match/proc/detach).  The main expression dispatch
## stays in analyzer.mt; this module contains the reusable type-combination logic.
##
## Mirrors Ruby's semantic_analyzer/expressions.rb helpers (conditional_common_type,
## match_expression_common_type).

import mtc.semantic.types as types


## The common type of two branch types.  Used by `if` / `match` expressions.
## Follows Ruby's conditional_common_type: structural equality wins, then
## nullable-wrapping a compatible pointee, then fall-back to permissive error.
public function conditional_common_type(then_ty: types.Type, else_ty: types.Type) -> types.Type:
    # Identical types — the ideal case.
    if types.type_equals(then_ty, else_ty):
        return then_ty

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

    # Fall back — different concrete types, can't unify.
    return types.Type.ty_error


## The common type across all arms of a match expression.  Folds
## conditional_common_type from left to right; returns ty_error for zero arms.
public function match_expression_common_type(arm_types: span[types.Type]) -> types.Type:
    if arm_types.len == 0:
        return types.Type.ty_error

    var result = unsafe: read(arm_types.data + 0)
    var i: ptr_uint = 1
    while i < arm_types.len:
        unsafe:
            result = conditional_common_type(result, read(arm_types.data + i))
        i += 1
    return result
