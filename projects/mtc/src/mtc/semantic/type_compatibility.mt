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
public function fold_int_constant(
    const_values: ptr[map_mod.Map[str, ptr[ast.Expr]]]?,
    ep: ptr[ast.Expr]?
) -> Option[long]:
    let p = ep else:
        return Option[long].none
    unsafe:
        match read(p):
            ast.Expr.expr_integer_literal as lit:
                return Option[long].some(value = long<-lit.value)
            ast.Expr.expr_char_literal as ch:
                return Option[long].some(value = long<-ch.value)
            ast.Expr.expr_identifier as id:
                let table_ptr = const_values else:
                    return Option[long].none
                let chain = unsafe: read(table_ptr).get(id.name)
                if chain != null:
                    return fold_int_constant(const_values, read(chain))
                return Option[long].none
            ast.Expr.expr_member_access as ma:
                # An imported constant (`sdl.ALPHA_OPAQUE`) is recorded under
                # its qualified source name by `record_imported_constants`.
                let table_ptr = const_values else:
                    return Option[long].none
                unsafe:
                    match read(ma.receiver):
                        ast.Expr.expr_identifier as rid:
                            var key = string.String.create()
                            key.append(rid.name)
                            key.append(".")
                            key.append(ma.member_name)
                            let chain = read(table_ptr).get(key.as_str())
                            if chain != null:
                                return fold_int_constant(const_values, read(chain))
                            return Option[long].none
                        _:
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
## or char), including a unary-minus literal like `-42`.  The host's
## `exact_compile_time_numeric_compatibility?` folds the value and requires it
## to fit the target; an unevaluable *chain* is not accepted for an integer
## target.  This predicate gates the contextual int→float / char forms, where
## the value range is not folded by the self.
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


## True when `ep` is a numeric literal, or an `if` expression whose branches
## are all numeric literals.  The self's expected-type inference types such a
## chain at the target type, so the chain itself clears the host's range test
## only for the contextual int→float and char forms.
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
    # A literal (or an expression over literals) folds without a `const` table;
    # the table is only needed to resolve named constants.
    match fold_int_constant(const_values, source_expr):
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
    #    A literal-valued `if` chain is not a substitute for the range test: the
    #    host accepts `let x: ubyte = if c: 32 else: 200` because both branches
    #    *fit* (the expected-type inference does that), and rejects
    #    `if c: 300 else: 200` because one branch does not.  So an integer
    #    target only accepts a source whose folded value fits — an unevaluable
    #    chain falls through to the structural rules.  Float targets keep the
    #    contextual int→float coercion for a literal chain, which has no range
    #    fold on the self side.
    #
    #    A *nullable* target does not run the compile-time numeric coercion at
    #    all: the host's `exact_compile_time_numeric_compatibility?` requires a
    #    primitive target, and its only nullable rule is exact-base auto-wrap
    #    (`T` -> `T?`).  `let x: ubyte? = 200` is therefore invalid.
    if source_expr != null and not types.is_nullable_type(expected) and not types.type_equals(expected, actual):
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
                        if types.is_float_type(bare) and is_numeric_literal_valued_expr(source_expr):
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

    # 5  Auto-wrap:  T  →  T?   (non-nullable stored into an optional).  The
    #    host's only nullable rule is exact base equality plus its pointer
    #    coercions (`expected_type.is_a?(Nullable) && actual_type ==
    #    expected_type.base`, then mutable-to-const / owning-to-raw); a numeric
    #    literal does not coerce into a nullable numeric target.
    let e_nullable = types.is_nullable_type(expected)
    let a_nullable = types.is_nullable_type(actual)
    if e_nullable and not a_nullable:
        let base = types.unwrap_nullable(expected)
        if types.type_equals(base, actual):
            return true
        return nullable_base_pointer_compatible(base, actual)

    # 6  Both nullable: the bases must be equal, or a pointer coercion.
    if e_nullable and a_nullable:
        let expected_base = types.unwrap_nullable(expected)
        let actual_base = types.unwrap_nullable(actual)
        if types.type_equals(expected_base, actual_base):
            return true
        return nullable_base_pointer_compatible(expected_base, actual_base)

    # 6b A nullable target accepts nothing else.  Continuing into the pointer,
    #    array/span and str/cstr rules would let a non-nullable source through
    #    a nullable target the host rejects (`cstr?` from `str`).
    if e_nullable:
        return false

    # 7  ptr[T]  →  const_ptr[T]   (mutable-to-const pointer coercion).
    match actual:
        types.Type.ty_generic as ag:
            let ag_bp = unsafe: read(ag.payload)
            if ag_bp.name == "ptr":
                match expected:
                    types.Type.ty_generic as eg:
                        let eg_bp = unsafe: read(eg.payload)
                        if eg_bp.name == "const_ptr" and eg_bp.args.len >= 1 and ag_bp.args.len >= 1:
                            return types_compatible_with_consts(
                                unsafe: read(eg_bp.args.data + 0),
                                unsafe: read(ag_bp.args.data + 0),
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
            let ag_bp = unsafe: read(ag.payload)
            if ag_bp.name == "own":
                match expected:
                    types.Type.ty_generic as eg:
                        let eg_bp = unsafe: read(eg.payload)
                        if (eg_bp.name == "ptr" or eg_bp.name == "const_ptr") and eg_bp.args.len >= 1 and ag_bp.args.len >= 1:
                            return types_compatible_with_consts(
                                unsafe: read(eg_bp.args.data + 0),
                                unsafe: read(ag_bp.args.data + 0),
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
            let ag2_bp = unsafe: read(ag2.payload)
            if ag2_bp.name == "array":
                match expected:
                    types.Type.ty_generic as eg2:
                        let eg2_bp = unsafe: read(eg2.payload)
                        if eg2_bp.name == "span" and eg2_bp.args.len >= 1 and ag2_bp.args.len >= 1:
                            return types_compatible_with_consts(
                                unsafe: read(eg2_bp.args.data + 0),
                                unsafe: read(ag2_bp.args.data + 0),
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


## External/foreign call argument compatibility: the structural assignability
## rule plus the FFI boundary coercions the host's
## `argument_types_compatible?(external: true)` adds.  The call site passes the
## declared public parameter type, not the lowering's boundary projection.
public function types_compatible_external_with_consts(
    expected: types.Type,
    actual: types.Type,
    source_expr: ptr[ast.Expr]?,
    const_values: ptr[map_mod.Map[str, ptr[ast.Expr]]]?,
) -> bool:
    if types_compatible_with_consts(expected, actual, source_expr, const_values):
        return true
    if external_cstr_argument_compatible(expected, actual):
        return true
    if external_void_pointer_argument_compatible(expected, actual):
        return true
    return false


## A `str` public parameter with a `cstr` boundary (`str as cstr`) accepts a
## `cstr` argument as well as `str` (the host's
## `foreign_cstr_argument_compatible?`).
function external_cstr_argument_compatible(expected: types.Type, actual: types.Type) -> bool:
    match actual:
        types.Type.ty_primitive as ap:
            if ap.name != "cstr":
                return false
        _:
            return false
    match expected:
        types.Type.ty_str:
            return true
        types.Type.ty_primitive as ep:
            return ep.name == "str"
        _:
            return false


## The host's `external_void_pointer_argument_compatibility?`: a pointer
## argument may cross an FFI boundary when either pointee is `void`, except a
## const pointer narrowed to a mutable one.  Nullable wrappers compare their
## bases; an actual nullable into a non-null target is rejected.
function external_void_pointer_argument_compatible(expected: types.Type, actual: types.Type) -> bool:
    match expected:
        types.Type.ty_nullable as en:
            match actual:
                types.Type.ty_nullable as an:
                    return external_void_pointer_argument_compatible(unsafe: read(en.base), unsafe: read(an.base))
                _:
                    return external_void_pointer_argument_compatible(unsafe: read(en.base), actual)
        _:
            pass
    match actual:
        types.Type.ty_nullable:
            return false
        _:
            pass
    if not types.is_pointer_type(expected) or not types.is_pointer_type(actual):
        return false
    match actual:
        types.Type.ty_generic as ag:
            let ag_bp = unsafe: read(ag.payload)
            if ag_bp.name == "const_ptr":
                match expected:
                    types.Type.ty_generic as eg:
                        let eg_bp = unsafe: read(eg.payload)
                        if eg_bp.name == "ptr":
                            return false
                    _:
                        pass
        _:
            pass
    return types.is_void(types.pointer_element(expected)) or types.is_void(types.pointer_element(actual))


## The pointer coercions a nullable target accepts on non-nullable bases:
## `ptr[T]` -> `const_ptr[T]` and `own[T]` -> `ptr[T]`/`const_ptr[T]` (the
## host's `mutable_to_const_pointer_compatibility?` and
## `own_to_raw_pointer_compatibility?`).
function nullable_base_pointer_compatible(expected_base: types.Type, actual_base: types.Type) -> bool:
    # The self checks a method's declared signature before substituting the
    # receiver's type arguments; a type variable is permissive until the
    # lowering resolves it (the host compares the substituted types).
    if types.contains_type_var(expected_base) or types.contains_type_var(actual_base):
        return true
    unsafe:
        match actual_base:
            types.Type.ty_generic as ag:
                let ag_bp = unsafe: read(ag.payload)
                if ag_bp.args.len < 1:
                    return false
                let actual_element = read(ag_bp.args.data + 0)
                if ag_bp.name == "ptr":
                    match expected_base:
                        types.Type.ty_generic as eg:
                            let eg_bp = unsafe: read(eg.payload)
                            if eg_bp.name == "const_ptr" and eg_bp.args.len >= 1:
                                return types_compatible_with_consts(
                                    read(eg_bp.args.data + 0),
                                    actual_element,
                                    null,
                                    null
                                )
                        _:
                            pass
                if ag_bp.name == "own":
                    match expected_base:
                        types.Type.ty_generic as eg2:
                            let eg2_bp = unsafe: read(eg2.payload)
                            if (eg2_bp.name == "ptr" or eg2_bp.name == "const_ptr") and eg2_bp.args.len >= 1:
                                return types_compatible_with_consts(
                                    read(eg2_bp.args.data + 0),
                                    actual_element,
                                    null,
                                    null
                                )
                        _:
                            pass
            _:
                pass
    return false
