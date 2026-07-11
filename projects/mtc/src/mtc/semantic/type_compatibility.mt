## Full type assignability — determines whether a value of `actual` type may be
## stored into a binding/parameter/field of `expected` type.
##
## Mirrors Ruby's `types_compatible?` (type_compatibility.rb): a positive chain
## of explicit coercions, with a fallback to `definitely_incompatible`.  Any pair
## that is NOT provably incompatible is treated as compatible (permissive).

import std.str
import std.string as string

import mtc.parser.ast as ast
import mtc.semantic.types as types


## True when the expression is a compile-time numeric literal (integer, float,
## or char), including a unary-minus literal like `-42`.  The self-host has no
## constant evaluator, so a literal source is treated as assignable to any
## numeric target — mirroring Ruby's exact_compile_time_numeric_compatibility?
## without range-checking the value.
public function is_numeric_literal_expr(ep: ptr[ast.Expr]?) -> bool:
    let p = ep else:
        return false
    unsafe:
        match read(p):
            ast.Expr.expr_integer_literal:
                return true
            ast.Expr.expr_float_literal:
                return true
            ast.Expr.expr_char_literal:
                return true
            ast.Expr.expr_unary_op as u:
                if u.operator == "-":
                    return is_numeric_literal_expr(u.operand)
                return false
            _:
                return false


## Returns true when a value of `actual` type is assignable to `expected`.
## `source_expr` gates numeric-literal widening: when non-null and a numeric
## literal, the literal fits any numeric or char target.  Pass null when the
## source expression is not available (recursive type-arg calls).
##
## Rules are checked in order; the first match wins.
public function types_compatible(expected: types.Type, actual: types.Type, source_expr: ptr[ast.Expr]?) -> bool:
    # 1  Numeric-literal sources fit into any numeric / char target.
    if source_expr != null and is_numeric_literal_expr(source_expr):
        let bare = types.unwrap_nullable(expected)
        if types.is_numeric(bare) or types.is_char_type(bare):
            return true

    # 2  Unresolved types never force a mismatch.
    if types.is_error(expected) or types.is_error(actual):
        return true

    # 3  Structural identity — the common fast path.
    if types.type_equals(expected, actual):
        return true

    # 4  ref[T] ↔ ref[T]: compare referenced pointee types.
    let e_is_ref = types.is_ref_type(expected)
    let a_is_ref = types.is_ref_type(actual)
    if e_is_ref and a_is_ref:
        let e_elem = types.pointer_element(expected)
        let a_elem = types.pointer_element(actual)
        return types_compatible(e_elem, a_elem, null)

    # 5  Auto-wrap:  T  →  T?   (non-nullable stored into an optional).
    let e_nullable = types.is_nullable_type(expected)
    let a_nullable = types.is_nullable_type(actual)
    if e_nullable and not a_nullable:
        return types_compatible(types.unwrap_nullable(expected), actual, source_expr)

    # 6  Permissive: accept T? → T (flow refinement handles narrowing in
    #     checked bodies; standalone calls into imported modules use this).
    if a_nullable and not e_nullable:
        return true

    # 7  Both nullable: compare the inner types.
    if e_nullable and a_nullable:
        return types_compatible(types.unwrap_nullable(expected), types.unwrap_nullable(actual), source_expr)

    # 8  ptr[T]  →  const_ptr[T]   (mutable-to-const pointer coercion).
    match actual:
        types.Type.ty_generic as ag:
            if ag.name == "ptr":
                match expected:
                    types.Type.ty_generic as eg:
                        if eg.name == "const_ptr" and eg.args.len >= 1 and ag.args.len >= 1:
                            return types_compatible(
                                unsafe: read(eg.args.data + 0),
                                unsafe: read(ag.args.data + 0),
                                null,
                            )
                    _:
                        pass
        _:
            pass

    # 8a  own[T]  →  ptr[T] / const_ptr[T]   (owning-to-raw pointer coercion).
    match actual:
        types.Type.ty_generic as ag:
            if ag.name == "own":
                match expected:
                    types.Type.ty_generic as eg:
                        if (eg.name == "ptr" or eg.name == "const_ptr") and eg.args.len >= 1 and ag.args.len >= 1:
                            return types_compatible(
                                unsafe: read(eg.args.data + 0),
                                unsafe: read(ag.args.data + 0),
                                null,
                            )
                    _:
                        pass
        _:
            pass

    # 9  array[T, N]  →  span[T]   (fixed array coerces to slice).
    match actual:
        types.Type.ty_generic as ag2:
            if ag2.name == "array":
                match expected:
                    types.Type.ty_generic as eg2:
                        if eg2.name == "span" and eg2.args.len >= 1 and ag2.args.len >= 1:
                            return types_compatible(
                                unsafe: read(eg2.args.data + 0),
                                unsafe: read(ag2.args.data + 0),
                                null,
                            )
                    _:
                        pass
        _:
            pass

    # 10  str  →  cstr   (Milk Tea string view passed where a C string is expected).
    match actual:
        types.Type.ty_str:
            match expected:
                types.Type.ty_primitive as ep:
                    if ep.name == "cstr":
                        return true
                _:
                    pass
        _:
            pass

    # 11  Fall back to the existing negative-only rule.  A type pair that is NOT
    #      provably incompatible is treated as compatible (permissive Phase-1
    #      design — unresolved generics, imported types, and type variables are
    #      never flagged as mismatches).
    return not types.definitely_incompatible(expected, actual)
