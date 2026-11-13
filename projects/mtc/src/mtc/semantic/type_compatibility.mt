## Full type assignability — determines whether a value of `actual` type may be
## stored into a binding/parameter/field of `expected` type.
##
## Mirrors Ruby's `types_compatible?` (type_compatibility.rb): a positive chain
## of explicit coercions, with a fallback to `definitely_incompatible`.  Any pair
## that is NOT provably incompatible is treated as compatible (permissive).

import std.map as map_mod
import std.str
import std.string as string

import mtc.parser.ast as ast
import mtc.semantic.types as types


## Integer evaluation of a constant expression, folded against a `const` table:
## integer/char literals, named constants, unary `-`/`~`, and the integer
## arithmetic/bitwise operators.  Mirrors the host's
## `evaluate_compile_time_const_value` reach for the value-range coercion: any
## expression with a statically-known integer value (a literal, a named const,
## or arithmetic over them) is subject to the same range test.
public function fold_int_constant(const_values: ref[map_mod.Map[str, ptr[ast.Expr]]], ep: ptr[ast.Expr]?) -> Option[long]:
    let p = ep else:
        return Option[long].none
    unsafe:
        match read(p):
            ast.Expr.expr_integer_literal as lit:
                return Option[long].some(value = long<-lit.value)
            ast.Expr.expr_char_literal as ch:
                return Option[long].some(value = long<-ch.value)
            ast.Expr.expr_identifier as id:
                let chain = const_values.get(id.name)
                if chain != null:
                    return fold_int_constant(const_values, read(chain))
                return Option[long].none
            ast.Expr.expr_unary_op as un:
                let v = fold_int_constant(const_values, un.operand) else:
                    return Option[long].none
                if un.operator == "-":
                    return Option[long].some(value = -v)
                if un.operator == "~":
                    return Option[long].some(value = ~v)
                if un.operator == "+":
                    return Option[long].some(value = v)
                return Option[long].none
            ast.Expr.expr_binary_op as bin:
                let l = fold_int_constant(const_values, bin.left) else:
                    return Option[long].none
                let r = fold_int_constant(const_values, bin.right) else:
                    return Option[long].none
                if bin.operator == "+":
                    return Option[long].some(value = l + r)
                if bin.operator == "-":
                    return Option[long].some(value = l - r)
                if bin.operator == "*":
                    return Option[long].some(value = l * r)
                if bin.operator == "/":
                    if r == 0:
                        return Option[long].none
                    return Option[long].some(value = l / r)
                if bin.operator == "%":
                    if r == 0:
                        return Option[long].none
                    return Option[long].some(value = l % r)
                if bin.operator == "<<":
                    if r < 0 or r >= 64:
                        return Option[long].none
                    return Option[long].some(value = l << r)
                if bin.operator == ">>":
                    if r < 0 or r >= 64:
                        return Option[long].none
                    return Option[long].some(value = l >> r)
                if bin.operator == "|":
                    return Option[long].some(value = l | r)
                if bin.operator == "&":
                    return Option[long].some(value = l & r)
                if bin.operator == "^":
                    return Option[long].some(value = l ^ r)
                return Option[long].none
            _:
                return Option[long].none


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


## True when `ep` is a numeric literal, or an `if`/`match` expression whose
## branches are all numeric literals.  The host types such branches with the
## expected type (`let shade: ubyte = if c: 0xFF else: 0x00`), so a
## literal-valued branch chain is compatible with any numeric target.
public function is_numeric_literal_valued_expr(ep: ptr[ast.Expr]?) -> bool:
    let p = ep else:
        return false
    unsafe:
        match read(p):
            ast.Expr.expr_if as iff:
                return is_numeric_literal_valued_expr(iff.then_expr) and is_numeric_literal_valued_expr(iff.else_expr)
            _:
                return is_numeric_literal_expr(p)


## True when `ep` is a binary operator expression.
public function is_binary_op_expr(ep: ptr[ast.Expr]?) -> bool:
    let p = ep else:
        return false
    unsafe:
        match read(p):
            ast.Expr.expr_binary_op:
                return true
            _:
                return false


## The primitive name of `t` when it is a primitive integer, else the empty
## string (which `is_fixed_width_integer_name` rejects).
function integer_primitive_name(t: types.Type) -> str:
    match t:
        types.Type.ty_primitive as p:
            return p.name
        _:
            return ""


## The host's `exact_compile_time_numeric_compatibility?` as a tri-state:
## `some(true)` when `source_expr` folds to an integer constant that fits the
## numeric `target`'s range, `some(false)` when it folds to a value that does
## NOT fit (the host rejects it), and `none` when the value is not
## statically-known (fall through to the structural rules).
public function constant_fits_target(
    target: types.Type,
    source_expr: ptr[ast.Expr]?,
    const_values: ptr[map_mod.Map[str, ptr[ast.Expr]]]?,
) -> Option[bool]:
    let target_name = integer_primitive_name(target)
    if not types.is_fixed_width_integer_name(target_name):
        return Option[bool].none
    let table_ptr = const_values else:
        return Option[bool].none
    var table: map_mod.Map[str, ptr[ast.Expr]] = unsafe: read(table_ptr)
    match fold_int_constant(ref_of(table), source_expr):
        Option.some as folded:
            return Option[bool].some(value = types.integer_constant_fits(target_name, folded.value))
        Option.none:
            return Option[bool].none


## Returns true when a value of `actual` type is assignable to `expected`.
## `source_expr` carries the source expression for the compile-time numeric
## coercion and `const_values` is the `const` table that coercion folds against;
## pass a null expression when the source is not available (recursive type-arg
## calls) — the coercion then cannot fire.
##
## Rules are checked in order; the first match wins.
public function types_compatible(expected: types.Type, actual: types.Type, source_expr: ptr[ast.Expr]?) -> bool:
    return types_compatible_with_consts(expected, actual, source_expr, null)


## As `types_compatible`, with an explicit `const` table for the compile-time
## numeric coercion.  `const_values` null disables the coercion (the literal-only
## form still applies).
public function types_compatible_with_consts(
    expected: types.Type,
    actual: types.Type,
    source_expr: ptr[ast.Expr]?,
    const_values: ptr[map_mod.Map[str, ptr[ast.Expr]]]?,
) -> bool:
    # 1  Compile-time numeric sources: the host's
    #    `exact_compile_time_numeric_compatibility?` — an expression whose value
    #    folds to an integer constant is assignable to a numeric target whose
    #    range holds that value (`let x: ubyte = 200` fits, `256` does not, and
    #    a named constant is folded the same way).  A binary operator is *not*
    #    folded here: the host types its literal operands with the expected type
    #    (`propagating_expected_type` + `harmonize_binary_integer_literal_types`),
    #    so the binary's own type already carries the answer.  A literal-valued
    #    branch chain stays permissive for the same reason.
    #
    #    The range test only applies when the source type is not already the
    #    target: the host's `types_compatible?` returns on
    #    `actual_type == expected_type` before reaching the numeric coercion, so
    #    a `ulong` literal the parser stores as a negative `long`
    #    (`14695981039346656037`) keeps its declared type and passes.
    if source_expr != null and not types.type_equals(expected, actual):
        let bare = types.unwrap_nullable(expected)
        if types.is_char_type(bare):
            # An integer-valued source is assignable to `char` when the value is
            # in `[0, 255]` — the host's `integer_to_char_compatibility?` plus
            # `integer_constant_fits_in_char?`.
            if is_binary_op_expr(source_expr):
                return true
            match constant_fits_target(bare, source_expr, const_values):
                Option.some as fits:
                    return fits.value
                Option.none:
                    if is_numeric_literal_valued_expr(source_expr):
                        return true
        else if types.is_numeric(bare):
            if not is_binary_op_expr(source_expr):
                match constant_fits_target(bare, source_expr, const_values):
                    Option.some as fits:
                        return fits.value
                    Option.none:
                        if is_numeric_literal_valued_expr(source_expr):
                            return true

    # 2  Unresolved types never force a mismatch — including types that merely
    #     contain an unresolved component (e.g. `Keys[<error>, ptr_uint]` from
    #     an unsubstituted type parameter).
    if types.contains_error(expected) or types.contains_error(actual):
        return true

    # 3  Structural identity — the common fast path.
    if types.type_equals(expected, actual):
        return true

    # 3b Null literal: only a nullable target accepts it.  A typed null must
    #    match the nullable base (`null[ptr[int]]` into `ptr[int]?`); the host's
    #    `null_assignable_to?`.  External typed-null pointer compatibility is a
    #    foreign-call concern handled by the call site.
    match actual:
        types.Type.ty_null as nt:
            if not types.is_nullable_type(expected):
                return false
            let target = nt.target
            if target == null:
                return true
            var target_type: types.Type
            unsafe:
                target_type = read(target)
            return types_compatible_with_consts(types.unwrap_nullable(expected), target_type, null, const_values)
        _:
            pass

    # 4  ref[T] ↔ ref[T]: compare referenced pointee types.
    let e_is_ref = types.is_ref_type(expected)
    let a_is_ref = types.is_ref_type(actual)
    if e_is_ref and a_is_ref:
        let e_elem = types.pointer_element(expected)
        let a_elem = types.pointer_element(actual)
        return types_compatible_with_consts(e_elem, a_elem, null, const_values)

    # 5  Auto-wrap:  T  →  T?   (non-nullable stored into an optional).
    let e_nullable = types.is_nullable_type(expected)
    let a_nullable = types.is_nullable_type(actual)
    if e_nullable and not a_nullable:
        return types_compatible_with_consts(types.unwrap_nullable(expected), actual, source_expr, const_values)

    # 6  Both nullable: compare the inner types.
    if e_nullable and a_nullable:
        return types_compatible_with_consts(types.unwrap_nullable(expected), types.unwrap_nullable(actual), source_expr, const_values)

    # 7  ptr[T]  →  const_ptr[T]   (mutable-to-const pointer coercion).
    match actual:
        types.Type.ty_generic as ag:
            if ag.name == "ptr":
                match expected:
                    types.Type.ty_generic as eg:
                        if eg.name == "const_ptr" and eg.args.len >= 1 and ag.args.len >= 1:
                            return types_compatible_with_consts(
                                unsafe: read(eg.args.data + 0),
                                unsafe: read(ag.args.data + 0),
                                null,
                                const_values,
                            )
                    _:
                        pass
        _:
            pass

    # 8  own[T]  →  ptr[T] / const_ptr[T]   (owning-to-raw pointer coercion).
    match actual:
        types.Type.ty_generic as ag:
            if ag.name == "own":
                match expected:
                    types.Type.ty_generic as eg:
                        if (eg.name == "ptr" or eg.name == "const_ptr") and eg.args.len >= 1 and ag.args.len >= 1:
                            return types_compatible_with_consts(
                                unsafe: read(eg.args.data + 0),
                                unsafe: read(ag.args.data + 0),
                                null,
                                const_values,
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
                            return types_compatible_with_consts(
                                unsafe: read(eg2.args.data + 0),
                                unsafe: read(ag2.args.data + 0),
                                null,
                                const_values,
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
