## Type and expression helpers — signature lookup, expression types,
## operator/vector typing, flow refinements, and termination analysis.
## Extracted from lowering/lowering.mt.

import std.vec as vec
import std.map as map_mod
import std.str

import mtc.ir as ir
import mtc.parser.ast as ast
import mtc.semantic.analyzer as analyzer
import mtc.semantic.expressions as sem_exprs
import mtc.semantic.types as types
import mtc.c_naming as naming

import mtc.lowering.lowering as lowering
import mtc.lowering.monomorphized as monomorphized
import mtc.lowering.utils as utils


# =============================================================================
#  Type resolution helpers
# =============================================================================

public function find_fn_sig(ctx: ref[lowering.LoweringContext], name: str) -> Option[analyzer.FnSig]:
    let sig_ptr = ctx.analysis.functions.get(name)
    if sig_ptr == null:
        return Option[analyzer.FnSig].none
    unsafe:
        return Option[analyzer.FnSig].some(value = read(sig_ptr))


## Look up a function's FnSig in an imported module's analysis.
public function find_imported_fn_sig(ctx: ref[lowering.LoweringContext], module_name: str, name: str) -> Option[analyzer.FnSig]:
    match lowering.find_imported_analysis(ctx, module_name):
        Option.some as imported:
            let sig_ptr = imported.value.functions.get(name)
            if sig_ptr == null:
                return Option[analyzer.FnSig].none
            return Option[analyzer.FnSig].some(value = unsafe: read(sig_ptr))
        Option.none:
            return Option[analyzer.FnSig].none


function fn_sig_param_type(sig: Option[analyzer.FnSig], index: ptr_uint) -> types.Type:
    match sig:
        Option.some as s:
            if index < s.value.params.len:
                unsafe:
                    return read(s.value.params.data + index).ty
            return types.Type.ty_error
        Option.none:
            return types.Type.ty_error


public function fn_sig_return_type(sig: Option[analyzer.FnSig]) -> types.Type:
    match sig:
        Option.some as s:
            if s.value.has_return_type:
                return s.value.return_type
            return types.primitive("void")
        Option.none:
            return types.primitive("void")


## A parameter's lowered type: resolved from the AST type ref (so tuple/array/
## span params carry full structure), falling back to the analyzer's signature.
public function resolve_param_type(ctx: ref[lowering.LoweringContext], sig: Option[analyzer.FnSig], index: ptr_uint, param_type: ast.TypeRef) -> types.Type:
    var local_tref = param_type
    let resolved = lowering.resolve_type_ref(ctx, ptr_of(local_tref))
    if not types.is_error(resolved):
        return lowering.qualify_type(ctx, resolved)
    return lowering.qualify_type(ctx, fn_sig_param_type(sig, index))


## A function's lowered return type: resolved from the AST return type ref (so
## tuple/array/span returns carry full structure), falling back to the signature.
public function resolve_return_type(ctx: ref[lowering.LoweringContext], sig: Option[analyzer.FnSig], return_type: ptr[ast.TypeRef]?) -> types.Type:
    let annotation = return_type else:
        return lowering.qualify_type(ctx, fn_sig_return_type(sig))
    let resolved = lowering.resolve_type_ref(ctx, annotation)
    if not types.is_error(resolved):
        return lowering.qualify_type(ctx, resolved)
    return lowering.qualify_type(ctx, fn_sig_return_type(sig))


## The resolved type of an AST expression, preferring the analyzer's recorded
## type (keyed by node pointer identity).  A recorded `ty_error` is permissive
## — the lowering recovers via `fallback_type`.  An identifier that names a
## local (or a refined module value) takes the *lowering env's* visible type:
## the host's `infer_expression_type` skips its sema-type cache for identifiers
## (`resolve.rb:706`) and reads `lookup_value`, so the analyzer's CFG refinement
## must not leak in where the host's lowering scope has none.
public function expr_type(ctx: ref[lowering.LoweringContext], ep: ptr[ast.Expr]) -> types.Type:
    unsafe:
        match read(ep):
            ast.Expr.expr_identifier as id:
                match visible_local_type(ctx, id.name):
                    Option.some as visible:
                        return visible.value
                    Option.none:
                        pass
            _:
                pass
    let key = unsafe: reinterpret[ptr_uint](ep)
    let tp = ctx.analysis.resolved_expr_types.get(key)
    if tp != null:
        let recorded = unsafe: read(tp)
        if not types.is_error(recorded):
            # Inside a generic specialization the analyzer's recorded type may
            # still mention type parameters (e.g. `Vec[T].data` is `ptr[T]`);
            # apply the active substitution so locals and member accesses carry
            # the concrete type.
            return monomorphized.substitute_type_params(ctx, recorded, ref_of(ctx.type_substitution))
    return fallback_type(ctx, ep)


## Resolve `import_alias.TypeName` to `ty_imported` when the member names a
## struct, enum, variant, or type alias in the imported module.
function import_qualified_type(ctx: ref[lowering.LoweringContext], ep: ptr[ast.Expr]) -> Option[types.Type]:
    unsafe:
        match read(ep):
            ast.Expr.expr_member_access as ma:
                match read(ma.receiver):
                    ast.Expr.expr_identifier as id:
                        let mod_ptr = ctx.analysis.imports.get(id.name)
                        if mod_ptr == null:
                            return Option[types.Type].none
                        let target_module = read(mod_ptr)
                        var ai: ptr_uint = 0
                        while ai < ctx.program_analyses.len:
                            var a: analyzer.Analysis = read(ctx.program_analyses.data + ai)
                            if a.module_name == target_module:
                                if a.structs.contains(ma.member_name) or a.type_names.contains(ma.member_name):
                                    # Follow the type alias chain so re-exported types
                                    # (e.g. `type CameraMode = c.CameraMode`) resolve to
                                    # the originating std.c.* module's type.
                                    let opt_alias = lowering.resolve_single_imported_type(ctx, target_module, ma.member_name)
                                    match opt_alias:
                                        Option.some as resolved:
                                            return Option[types.Type].some(value = resolved.value)
                                        Option.none:
                                            return Option[types.Type].some(value = types.imported_type(module_name = target_module, name = ma.member_name, args = span[types.Type]()))
                            ai += 1
                    _:
                        pass
            _:
                pass
    return Option[types.Type].none


## The return type of a cross-module call `alias.func(...)`, resolved from the
## shared `program_returns` table.  Ordinary functions are keyed by their
## module-qualified C name; `std.c.*` external functions are keyed by their bare
## C name (matching `collect_program_returns`).  Returns `ty_error` when the
## receiver is not an import alias or the function is unknown.
function imported_call_return_type(ctx: ref[lowering.LoweringContext], receiver: ptr[ast.Expr], func_name: str) -> types.Type:
    unsafe:
        match read(receiver):
            ast.Expr.expr_identifier as id:
                let mod_ptr = ctx.analysis.imports.get(id.name) else:
                    return types.Type.ty_error
                let target_module = read(mod_ptr)
                # External (std.c.*) functions are keyed by bare name; ordinary
                # functions by module-qualified name.  Try the bare name first for
                # std.c.* aliases, then the qualified name.
                if target_module.starts_with("std.c."):
                    let bare_ptr = read(ctx.program_returns).get(func_name)
                    if bare_ptr != null:
                        return read(bare_ptr)
                let linkage = naming.qualified_c_name(target_module, func_name)
                let ret_ptr = read(ctx.program_returns).get(linkage) else:
                    return types.Type.ty_error
                return read(ret_ptr)
            _:
                return types.Type.ty_error


## Like `fallback_type_raw`, but applies the active generic substitution so a
## recovered field/local type (`ptr[T]`) becomes concrete inside a
## specialization.
public function fallback_type(ctx: ref[lowering.LoweringContext], ep: ptr[ast.Expr]) -> types.Type:
    return monomorphized.substitute_type_params(ctx, fallback_type_raw(ctx, ep), ref_of(ctx.type_substitution))


public function fallback_type_raw(ctx: ref[lowering.LoweringContext], ep: ptr[ast.Expr]) -> types.Type:
    unsafe:
        match read(ep):
            ast.Expr.expr_integer_literal:
                return types.primitive("int")
            ast.Expr.expr_float_literal:
                return types.primitive("float")
            ast.Expr.expr_char_literal:
                return types.primitive("ubyte")
            ast.Expr.expr_bool_literal:
                return ctx.bool_ty
            ast.Expr.expr_identifier as id:
                match visible_local_type(ctx, id.name):
                    Option.some as visible:
                        return visible.value
                    Option.none:
                        pass
                let mvt = lowering.module_var_type(ctx, id.name)
                if not types.is_error(mvt):
                    return mvt
                # Function reference: its function type, named after the
                # function and carrying its variadic flag, the way the
                # host's `infer_expression_type` returns the function
                # binding's own type (`Types::Function#name`; the
                # analyzer's `argument_inference_type` refinement does
                # the same for call arguments).
                match find_fn_sig(ctx, id.name):
                    Option.some as s:
                        var ret = s.value.return_type
                        if not s.value.has_return_type:
                            ret = ctx.void_ty
                        var param_types = vec.Vec[types.Type].create()
                        var param_names = vec.Vec[str].create()
                        var pi: ptr_uint = 0
                        while pi < s.value.params.len:
                            unsafe:
                                param_types.push(read(s.value.params.data + pi).ty)
                                param_names.push(read(s.value.params.data + pi).name)
                            pi += 1
                        return types.function_type(name = id.name, params = param_types.as_span(), return_type = types.alloc_type(ret), variadic = s.value.is_variadic, is_proc = false, param_names = param_names.as_span())
                    Option.none:
                        pass
                return types.Type.ty_error
            ast.Expr.expr_binary_op as bin:
                if is_comparison_operator(bin.operator):
                    return ctx.bool_ty
                return fallback_type_raw(ctx, bin.left)
            ast.Expr.expr_unary_op as un:
                return fallback_type_raw(ctx, un.operand)
            ast.Expr.expr_call as call:
                match read(call.callee):
                    ast.Expr.expr_identifier as id:
                        # Builtin address-of / pointer-of: infer the correct
                        # result type from the argument's type instead of
                        # falling to void (#1194).
                        if call.args.len > 0:
                            let inner_kind = id.name
                            let inner_type_name = lowering.builtin_addr_type_name(inner_kind)
                            if inner_type_name.len > 0:
                                let inner_ty = fallback_type_raw(ctx, unsafe: read(call.args.data + 0).arg_value)
                                if not types.is_error(inner_ty) and not types.is_void(inner_ty):
                                    return types.generic_type(name = inner_type_name, args = lowering.sp_type(inner_ty))
                        let foreign_ptr = ctx.foreign_map.get(id.name)
                        if foreign_ptr != null:
                            return read(foreign_ptr).return_ty
                        return fn_sig_return_type(find_fn_sig(ctx, id.name))
                    ast.Expr.expr_member_access as ma:
                        # Cross-module call `alias.func(...)` (ordinary or external):
                        # the analyzer does not record a resolved type for these, so
                        # recover the callee's return type from the shared
                        # program_returns table (keyed by its C linkage name — the
                        # module-qualified name for ordinary functions, the bare
                        # name for std.c.* external functions).
                        return imported_call_return_type(ctx, ma.receiver, ma.member_name)
                    _:
                        return types.Type.ty_error
            ast.Expr.expr_member_access as ma:
                match import_qualified_type(ctx, ep):
                    Option.some as ty:
                        return ty.value
                    Option.none:
                        pass
                # A field access on a struct value (`rect.height`) resolves to
                # the field's type, not the receiver's type.  Recover the
                # receiver's type and look the field up; fall back to the
                # receiver type only when the field cannot be resolved.
                let recv_fallback = fallback_type_raw(ctx, ma.receiver)
                match lowering.concrete_field_type(ctx, recv_fallback, ma.member_name):
                    Option.some as ft:
                        return ft.value
                    Option.none:
                        pass
                match lowering.imported_field_type(ctx, recv_fallback, ma.member_name):
                    Option.some as ft:
                        return ft.value
                    Option.none:
                        pass
                return recv_fallback
            ast.Expr.expr_specialization as spec:
                match lowering.try_spec_type_name(ep):
                    Option.some as tn:
                        return types.generic_type(name = tn.value, args = lowering.sp_type(types.Type.ty_error))
                    Option.none:
                        return types.Type.ty_error
            # Proc expressions: reconstruct the ty_function(is_proc=true) from the
            # AST so proc_invoke_field_type and callers can compute the correct
            # invoke field type instead of falling to ty_error / void.
            ast.Expr.expr_proc as pr:
                var param_types = vec.Vec[types.Type].create()
                var pi: ptr_uint = 0
                var proc_param_names = vec.Vec[str].create()
                while pi < pr.method_params.len:
                    unsafe:
                        let p = read(pr.method_params.data + pi)
                        param_types.push(lowering.resolve_field_type_ref(ctx, p.param_type))
                        proc_param_names.push(p.name)
                    pi += 1
                var ret = ctx.void_ty
                let rt = pr.return_type
                if rt != null:
                    # Full resolution (not scalar-only) so a struct / imported
                    # return type resolves correctly — needed for generic-method
                    # type-param inference (e.g. `map_error[F]`'s F from the proc's
                    # return type).
                    ret = lowering.resolve_field_type_ref(ctx, unsafe: read(rt))
                return types.function_type(name = "", params = param_types.as_span(), return_type = types.alloc_type(ret), variadic = false, is_proc = true, param_names = proc_param_names.as_span())
            _:
                return types.Type.ty_error


public function is_comparison_operator(op: str) -> bool:
    return (
        op == "==" or op == "!=" or op == "<" or op == "<=" or op == ">" or op == ">="
        or op == "and" or op == "or"
    )


## True when a type is exactly `str` (`ty_str`).
public function is_str_typed(t: types.Type) -> bool:
    match t:
        types.Type.ty_str:
            return true
        _:
            return false


## True for integer/bitwise arithmetic operators whose result type matches the
## (same-typed) operands.
public function is_arithmetic_operator(op: str) -> bool:
    return (
        op == "+" or op == "-" or op == "*" or op == "/" or op == "%"
        or op == "&" or op == "|" or op == "^" or op == "<<" or op == ">>"
    )


## True for the arithmetic operators whose result type is the promoted operand
## type (excludes comparisons, which yield bool, and shifts/bitwise).
public function is_pure_arithmetic_operator(op: str) -> bool:
    return op == "+" or op == "-" or op == "*" or op == "/" or op == "%"


## The common type both operands of a balanced binary operator are cast to, or
## none when no balancing applies.  Arithmetic and comparison balance to the
## common numeric type; `%` to the common integer type; shifts, bitwise, and
## logical operators do not balance.  Mirrors Ruby's promoted_binary_operand_type.
public function promoted_binary_operand_type(operator: str, left: types.Type, right: types.Type) -> Option[types.Type]:
    if (
        operator == "+" or operator == "-" or operator == "*" or operator == "/"
        or operator == "<" or operator == "<=" or operator == ">" or operator == ">="
        or operator == "==" or operator == "!="
    ):
        # Vector/matrix/quaternion arithmetic: same-type operations pass through;
        # scalar * vector uses the vector type; scalar / vector is unsupported.
        let lp = nominal_type_name(left)
        let rp = nominal_type_name(right)
        if is_vec_math_name(lp) and lp == rp:
            return Option[types.Type].some(value = left)
        if is_vec_math_name(lp) and types.is_numeric(right) and operator == "*":
            return Option[types.Type].some(value = left)
        if is_vec_math_name(rp) and types.is_numeric(left) and operator == "*":
            return Option[types.Type].some(value = right)
        return common_numeric_type(left, right)
    if operator == "%":
        return common_integer_type(left, right)
    return Option[types.Type].none


public function is_vec_math_name(name: str) -> bool:
    return (
        name == "vec2" or name == "vec3" or name == "vec4"
        or name == "ivec2" or name == "ivec3" or name == "ivec4"
        or name == "mat3" or name == "mat4" or name == "quat"
    )


public function lower_vec_unary_neg(ctx: ref[lowering.LoweringContext], operand: ptr[ir.Expr], name: str) -> ptr[ir.Expr]:
    var field_names = vec.Vec[str].create()
    var field_types = vec.Vec[types.Type].create()
    vec_math_fields(name, ref_of(field_names), ref_of(field_types))
    var fields = vec.Vec[ir.AggregateField].create()
    let ty = lowering.ir_expr_type(operand)
    var i: ptr_uint = 0
    while i < field_names.len():
        let fname_ptr = field_names.get(i) else:
            fatal(c"lowering: vec unary neg missing field name")
        let ft_ptr = field_types.get(i) else:
            fatal(c"lowering: vec unary neg missing field type")
        let fname = unsafe: read(fname_ptr)
        let field_ty = unsafe: read(ft_ptr)
        let field_access = lowering.alloc_expr(ir.Expr.expr_member(receiver = operand, member = fname, ty = field_ty))
        var neg_val: ptr[ir.Expr]
        if is_vec_math_name(nominal_type_name(field_ty)):
            neg_val = lower_vec_unary_neg(ctx, field_access, nominal_type_name(field_ty))
        else:
            neg_val = lowering.alloc_expr(ir.Expr.expr_unary(operator = "-", operand = field_access, ty = field_ty))
        fields.push(ir.AggregateField(name = fname, value = neg_val))
        i += 1
    return lowering.alloc_expr(ir.Expr.expr_aggregate_literal(ty = ty, fields = fields.as_span()))


## Populate `field_names` and `field_types` for a vector/math type name.
## Mirrors the field set used by `lower_vec_unary_neg` and `lower_vec_binary_op`.
public function vec_math_fields(name: str, names: ref[vec.Vec[str]], ftypes: ref[vec.Vec[types.Type]]) -> void:
    if name == "vec2" or name == "ivec2":
        names.push("x")
        names.push("y")
    else if name == "vec3" or name == "ivec3":
        names.push("x")
        names.push("y")
        names.push("z")
    else if name == "vec4" or name == "ivec4" or name == "quat":
        names.push("x")
        names.push("y")
        names.push("z")
        names.push("w")
    else if name == "mat3":
        names.push("col0")
        names.push("col1")
        names.push("col2")
    else if name == "mat4":
        names.push("col0")
        names.push("col1")
        names.push("col2")
        names.push("col3")
    var fi: ptr_uint = 0
    while fi < names.len():
        var ft = types.primitive("float")
        if name.starts_with("ivec"):
            ft = types.primitive("int")
        else if name == "mat3":
            ft = types.primitive("vec3")
        else if name == "mat4":
            ft = types.primitive("vec4")
        ftypes.push(ft)
        fi += 1


## Lower a binary arithmetic operator on vector/matrix/quaternion types to a
## component-wise aggregate literal.  Mirrors Ruby's lower_vector_binary_op /
## lower_aggregate_binary_op.
public function lower_vec_binary_op(ctx: ref[lowering.LoweringContext], operator: str, left: ptr[ir.Expr], right: ptr[ir.Expr], result_ty: types.Type, name: str) -> ptr[ir.Expr]:
    let left_ty = lowering.ir_expr_type(left)
    let right_ty = lowering.ir_expr_type(right)
    var field_names = vec.Vec[str].create()
    var field_types = vec.Vec[types.Type].create()
    vec_math_fields(name, ref_of(field_names), ref_of(field_types))
    var fields = vec.Vec[ir.AggregateField].create()
    # An operand is scalar if its type is NOT a known vec/mat/quat type.
    # Using nominal_type_name instead of is_numeric handles float literals that
    # the analyzer may not type correctly in this binary context.
    let left_is_scalar = not is_vec_math_name(nominal_type_name(left_ty))
    let right_is_scalar = not is_vec_math_name(nominal_type_name(right_ty))
    var i: ptr_uint = 0
    while i < field_names.len():
        let fn_ptr = field_names.get(i) else:
            fatal(c"lowering: vec binary missing field name")
        let ft_ptr = field_types.get(i) else:
            fatal(c"lowering: vec binary missing field type")
        let fname = unsafe: read(fn_ptr)
        let ftype = unsafe: read(ft_ptr)
        var left_field: ptr[ir.Expr]
        var right_field: ptr[ir.Expr]
        if left_is_scalar:
            left_field = left
        else:
            left_field = lowering.alloc_expr(ir.Expr.expr_member(receiver = left, member = fname, ty = ftype))
        if right_is_scalar:
            right_field = right
        else:
            right_field = lowering.alloc_expr(ir.Expr.expr_member(receiver = right, member = fname, ty = ftype))
        # If the field type is itself a vec/mat type (e.g. mat4 column is vec4),
        # recurse to lower the inner operation component-wise.
        var field_val: ptr[ir.Expr]
        let ftype_name = nominal_type_name(ftype)
        if is_vec_math_name(ftype_name):
            field_val = lower_vec_binary_op(ctx, operator, left_field, right_field, ftype, ftype_name)
        else:
            field_val = lowering.alloc_expr(ir.Expr.expr_binary(operator = operator, left = left_field, right = right_field, ty = ftype))
        fields.push(ir.AggregateField(name = fname, value = field_val))
        i += 1
    return lowering.alloc_expr(ir.Expr.expr_aggregate_literal(ty = result_ty, fields = fields.as_span()))


## True for compound assignment operators (`+=`, `*=`, ...).
public function is_compound_assignment_operator(op: str) -> bool:
    return (
        op == "+=" or op == "-=" or op == "*=" or op == "/=" or op == "%="
        or op == "&=" or op == "|=" or op == "^=" or op == "<<=" or op == ">>="
    )


## The binary operator underlying a compound assignment (`+=` -> `+`).
public function compound_base_operator(op: str) -> str:
    if op == "+=":
        return "+"
    if op == "-=":
        return "-"
    if op == "*=":
        return "*"
    if op == "/=":
        return "/"
    if op == "%=":
        return "%"
    if op == "&=":
        return "&"
    if op == "|=":
        return "|"
    if op == "^=":
        return "^"
    if op == "<<=":
        return "<<"
    if op == ">>=":
        return ">>"
    return op


public function nominal_type_name(t: types.Type) -> str:
    match t:
        types.Type.ty_primitive as p:
            return p.name
        types.Type.ty_named as n:
            let n_np = unsafe: read(n.payload)
            return n_np.name
        types.Type.ty_imported as im:
            let im_bp = unsafe: read(im.payload)
            return im_bp.name
        _:
            return ""


## True for the numeric aggregate types (simd lanes, vec/mat/quat), whose
## arithmetic result the analyzer records as the aggregate itself.
public function is_numeric_aggregate_type(t: types.Type) -> bool:
    if types.is_simd_type(t):
        return true
    return is_vec_math_name(nominal_type_name(t))


## The common numeric type of two operands (mirrors Ruby's common_numeric_type):
## identical types pass through; two integers use common_integer_type; two floats
## use the wider float; a float paired with a fixed-width integer uses the float.
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


## The common integer type of two operands (mirrors Ruby's common_integer_type):
## identical types pass through; both must be fixed-width integers.  Same
## signedness takes the wider type; mixed signedness promotes to the narrowest
## signed type that holds both ranges (`uint` vs `int` → `long`), with no answer
## once the unsigned side is 64-bit.  Shared with the semantic conditional
## common-type rule.
function common_integer_type(left: types.Type, right: types.Type) -> Option[types.Type]:
    return sem_exprs.common_integer_type(left, right)


## The wider of two float primitives (mirrors Ruby's wider_float_type).
function wider_float_type(left: types.Type, right: types.Type) -> types.Type:
    if float_width_of(left) >= float_width_of(right):
        return left
    return right


function float_width_of(t: types.Type) -> int:
    if prim_name(t) == "double":
        return 64
    return 32


## The primitive type name of `t`, or the empty string for non-primitives.
public function prim_name(t: types.Type) -> str:
    match t:
        types.Type.ty_primitive as p:
            return p.name
        _:
            return ""


## Wrap `ep` in a cast to `target` unless it already has that type (mirrors
## Ruby's cast_expression).  A redundant cast is elided by the C backend.
public function cast_to_type(ep: ptr[ir.Expr], target: types.Type) -> ptr[ir.Expr]:
    if types.type_equals(lowering.ir_expr_type(ep), target):
        return ep
    return lowering.alloc_expr(ir.Expr.expr_cast(target_type = target, expression = ep, ty = target))


## The backing primitive of an enum or flags type, or `t` unchanged for any
## other type.  Mirrors Ruby unwrapping Types::EnumBase to its backing_type so
## enum/flags operands balance (and cast) to their integer backing.
public function enum_backing_or_self(ctx: ref[lowering.LoweringContext], t: types.Type) -> types.Type:
    match t:
        types.Type.ty_named as n:
            let n_np = unsafe: read(n.payload)
            # The builtin event enum has no AST declaration to scan; its backing
            # is the host's `Types::Enum` int (`type_declaration.rb`'s builtin
            # registration).
            if n_np.name == "EventError" and n_np.module_name.len == 0:
                return types.primitive("int")
            let owner = if n_np.module_name.len > 0: n_np.module_name else: ctx.module_name
            match find_enum_backing(ctx, owner, n_np.name):
                Option.some as b:
                    return b.value
                Option.none:
                    return t
        types.Type.ty_imported as im:
            let im_bp = unsafe: read(im.payload)
            if im_bp.args.len != 0:
                return t
            match find_enum_backing(ctx, im_bp.module_name, im_bp.name):
                Option.some as b:
                    return b.value
                Option.none:
                    return t
        _:
            return t


## The backing primitive type of the enum or flags named `enum_name` in
## `module_name`, or none when no such declaration exists.  Scans the owning
## module's AST declarations (the analyzer keeps no separate backing table).
function find_enum_backing(ctx: ref[lowering.LoweringContext], module_name: str, enum_name: str) -> Option[types.Type]:
    if module_name == ctx.module_name:
        return scan_enum_backing(ctx.analysis.source_file.declarations, enum_name)
    match lowering.find_imported_analysis(ctx, module_name):
        Option.some as a:
            return scan_enum_backing(a.value.source_file.declarations, enum_name)
        Option.none:
            return Option[types.Type].none


## Find an enum/flags declaration named `enum_name` in `decls` and return its
## resolved backing primitive type.
function scan_enum_backing(decls: span[ast.Decl], enum_name: str) -> Option[types.Type]:
    var i: ptr_uint = 0
    while i < decls.len:
        var d: ast.Decl
        unsafe:
            d = read(decls.data + i)
        match d:
            ast.Decl.decl_enum as en:
                if en.name == enum_name:
                    return Option[types.Type].some(value = enum_backing_type(en.backing_type))
            ast.Decl.decl_flags as fl:
                if fl.name == enum_name:
                    return Option[types.Type].some(value = enum_backing_type(fl.backing_type))
            _:
                pass
        i += 1
    return Option[types.Type].none


## Resolve an enum/flags backing-type annotation to a primitive type; the
## default backing is int when the annotation is absent (mirrors lower_enum_decl).
function enum_backing_type(annotation: ptr[ast.TypeRef]?) -> types.Type:
    let a = annotation else:
        return types.primitive("int")
    let resolved = lowering.resolve_scalar_type_ref(a)
    if types.is_error(resolved):
        return types.primitive("int")
    return resolved


public function is_int_type(t: types.Type) -> bool:
    match t:
        types.Type.ty_primitive as p:
            return p.name == "int"
        _:
            return false


public function find_local_binding(ctx: ref[lowering.LoweringContext], name: str) -> Option[lowering.LocalBinding]:
    if ctx.locals.len() == 0:
        return Option[lowering.LocalBinding].none
    var i = ctx.locals.len()
    while i > 0:
        i -= 1
        let lb_ptr = ctx.locals.get(i) else:
            break
        unsafe:
            if read(lb_ptr).name == name:
                return Option[lowering.LocalBinding].some(value = read(lb_ptr))
    return Option[lowering.LocalBinding].none


## The visible (flow-refined) type of `name` in the innermost refinement scope
## that mentions it.  The host's `lookup_value(...)[:type]`; nil when no scope
## narrows the name.
public function flow_scope_binding(ctx: ref[lowering.LoweringContext], name: str) -> Option[types.Type]:
    var i = ctx.flow_scopes.len()
    while i > 0:
        i -= 1
        let scope_ptr = ctx.flow_scopes.get(i) else:
            break
        unsafe:
            let found = read(scope_ptr).get(name)
            if found != null:
                return Option[types.Type].some(value = read(found))
    return Option[types.Type].none


## The type inference sees for a name — the host's `infer_expression_type`
## identifier arm: the refinement scope's narrowed type, else the local
## binding's storage type, else a module-level value's declared type.
public function visible_local_type(ctx: ref[lowering.LoweringContext], name: str) -> Option[types.Type]:
    match flow_scope_binding(ctx, name):
        Option.some as narrowed:
            return Option[types.Type].some(value = narrowed.value)
        Option.none:
            pass
    match find_local_binding(ctx, name):
        Option.some as lb:
            return Option[types.Type].some(value = lb.value.ty)
        Option.none:
            pass
    let declared = ctx.analysis.value_types.get(name)
    if declared != null:
        return Option[types.Type].some(value = unsafe: read(declared))
    return Option[types.Type].none


## Merge `incoming` into `existing`: a conflicting type deletes the entry (the
## host's `merge_refinements`, `utils.rb:593`).
public function merge_flow_refinements(existing: ref[map_mod.Map[str, types.Type]], incoming: ref[map_mod.Map[str, types.Type]]) -> void:
    var entries = incoming.entries()
    while true:
        if not entries.next():
            break
        let entry = entries.current()
        unsafe:
            let key = read(entry.key)
            let new_val = read(entry.value)
            let cur_ptr = existing.get(key)
            if cur_ptr != null:
                if not types.type_equals(read(cur_ptr), new_val):
                    let _removed = existing.remove(key)
            else:
                existing.set(key, new_val)


## Push a refinement map as a new visible scope (skipped when empty); returns
## the stack length `restore_flow_refinements` restores.  The host's
## `env_with_refinements` makes a fresh `FlowScope` layer, so the pushed map is
## a copy rather than the caller's.
public function push_flow_refinements(ctx: ref[lowering.LoweringContext], refinements: ref[map_mod.Map[str, types.Type]]) -> ptr_uint:
    let saved = ctx.flow_scopes.len()
    if refinements.len() == 0:
        return saved
    var scope = map_mod.Map[str, types.Type].create()
    merge_flow_refinements(ref_of(scope), refinements)
    ctx.flow_scopes.push(scope)
    return saved


public function restore_flow_refinements(ctx: ref[lowering.LoweringContext], saved: ptr_uint) -> void:
    while ctx.flow_scopes.len() > saved:
        let _dropped = ctx.flow_scopes.pop()


## The lowering's `flow_refinements` (`utils.rb:606`): the binding types a
## condition narrows when it is true (`truthy`) or false.  Only null tests
## narrow; `not` flips, and `and`/`or` recurse with the host's short-circuit
## scopes (the right operand sees the left's refinement).
public function lowering_flow_refinements(ctx: ref[lowering.LoweringContext], cond: ptr[ast.Expr], truthy: bool) -> map_mod.Map[str, types.Type]:
    var result = map_mod.Map[str, types.Type].create()
    unsafe:
        match read(cond):
            ast.Expr.expr_unary_op as u:
                if u.operator == "not":
                    return lowering_flow_refinements(ctx, u.operand, not truthy)
            ast.Expr.expr_binary_op as b:
                if b.operator == "and":
                    # Only the truthy side refines: `a and b` being false says
                    # nothing about `a`, so the host's `flow_refinements` falls
                    # through to `{}` for the falsy case (`utils.rb:612-618`).
                    if truthy:
                        var left = lowering_flow_refinements(ctx, b.left, true)
                        merge_flow_refinements(ref_of(result), ref_of(left))
                        let saved = push_flow_refinements(ctx, ref_of(left))
                        var right = lowering_flow_refinements(ctx, b.right, true)
                        restore_flow_refinements(ctx, saved)
                        merge_flow_refinements(ref_of(result), ref_of(right))
                    return result
                if b.operator == "or":
                    # Symmetric with `and`: only the falsy side refines.
                    if not truthy:
                        var left_f = lowering_flow_refinements(ctx, b.left, false)
                        merge_flow_refinements(ref_of(result), ref_of(left_f))
                        let saved = push_flow_refinements(ctx, ref_of(left_f))
                        var right = lowering_flow_refinements(ctx, b.right, false)
                        restore_flow_refinements(ctx, saved)
                        merge_flow_refinements(ref_of(result), ref_of(right))
                    return result
                if b.operator == "==" or b.operator == "!=":
                    return lowering_null_test_refinements(ctx, cond, truthy)
            _:
                pass
    return result


## Null-test refinements (`utils.rb:634`): `x == null` truthy (and `!=` falsy)
## narrows to the bare null; the other direction narrows to the nullable's base.
## A local's storage type is its binding; a module-level value's is its declared
## type (the host seeds module bindings into its env).
function lowering_null_test_refinements(ctx: ref[lowering.LoweringContext], condp: ptr[ast.Expr], truthy: bool) -> map_mod.Map[str, types.Type]:
    var result = map_mod.Map[str, types.Type].create()
    unsafe:
        match read(condp):
            ast.Expr.expr_binary_op as b:
                if b.operator != "==" and b.operator != "!=":
                    return result
                var name_value: str = ""
                var found = false
                match read(b.left):
                    ast.Expr.expr_identifier as id:
                        if read(b.right) is ast.Expr.expr_null_literal:
                            name_value = id.name
                            found = true
                    _:
                        pass
                if not found:
                    match read(b.right):
                        ast.Expr.expr_identifier as id2:
                            if read(b.left) is ast.Expr.expr_null_literal:
                                name_value = id2.name
                                found = true
                        _:
                            pass
                if not found:
                    return result
                var storage: Option[types.Type] = Option[types.Type].none
                match find_local_binding(ctx, name_value):
                    Option.some as lb:
                        storage = Option[types.Type].some(value = lb.value.ty)
                    Option.none:
                        let declared = ctx.analysis.value_types.get(name_value)
                        if declared != null:
                            storage = Option[types.Type].some(value = read(declared))
                match storage:
                    Option.some as st:
                        match st.value:
                            types.Type.ty_nullable as nl:
                                let null_result = if b.operator == "==": truthy else: not truthy
                                if null_result:
                                    result.set(name_value, types.Type.ty_null(target = null))
                                else:
                                    result.set(name_value, read(nl.base))
                            _:
                                pass
                    Option.none:
                        pass
            _:
                pass
    return result


## The host's `cfg_block_always_terminates?` as the lowering applies it
## (`block.rb:707`): the host's termination builder has no break/continue
## targets, so a `break`/`continue` falls through to the block exit and does
## NOT terminate.
public function ast_block_always_terminates(body: ptr[ast.Stmt]?) -> bool:
    let b = body else:
        return false
    unsafe:
        match read(ptr[ast.Stmt]<-b):
            ast.Stmt.stmt_block as blk:
                if blk.statements.len == 0:
                    return false
                return ast_stmt_terminates(blk.statements.data + (blk.statements.len - 1))
            _:
                return ast_stmt_terminates(ptr[ast.Stmt]<-b)


function ast_stmt_terminates(sp: ptr[ast.Stmt]) -> bool:
    unsafe:
        match read(sp):
            ast.Stmt.stmt_ret:
                return true
            ast.Stmt.stmt_block as blk:
                if blk.statements.len == 0:
                    return false
                return ast_stmt_terminates(blk.statements.data + (blk.statements.len - 1))
            ast.Stmt.stmt_unsafe as u:
                return ast_block_always_terminates(u.body)
            ast.Stmt.stmt_error_block as eb:
                return ast_stmt_terminates(eb.body)
            ast.Stmt.stmt_if as iff:
                if iff.else_body == null:
                    return false
                if not ast_block_always_terminates(iff.else_body):
                    return false
                var bi: ptr_uint = 0
                while bi < iff.branches.len:
                    if not ast_block_always_terminates(read(iff.branches.data + bi).body):
                        return false
                    bi += 1
                return iff.branches.len > 0
            ast.Stmt.stmt_match as m:
                if m.arms.len == 0:
                    return false
                var ai: ptr_uint = 0
                while ai < m.arms.len:
                    if not ast_block_always_terminates(read(m.arms.data + ai).body):
                        return false
                    ai += 1
                return true
            ast.Stmt.stmt_expression as e:
                return ast_expression_always_aborts(e.expression)
            _:
                return false
    return false


## The host's `fatal_expression?` (`builder.rb:256`): a `fatal(...)` call or a
## literal-false `assert`/`expect` always aborts.
function ast_expression_always_aborts(ep: ptr[ast.Expr]) -> bool:
    unsafe:
        match read(ep):
            ast.Expr.expr_call as call:
                match read(call.callee):
                    ast.Expr.expr_identifier as id:
                        if id.name == "fatal":
                            return true
                        if call.args.len == 0:
                            return false
                        match read(read(call.args.data + 0).arg_value):
                            ast.Expr.expr_bool_literal as b:
                                return (id.name == "assert" or id.name == "expect") and not b.value
                            _:
                                return false
                    _:
                        return false
            _:
                return false
    return false


public function find_qualified_constant(ctx: ref[lowering.LoweringContext], name: str) -> Option[str]:
    if ctx.analysis.type_names.contains(name) or ctx.analysis.value_types.contains(name):
        return Option[str].some(value = naming.qualified_c_name(ctx.module_name, name))
    var import_values = ctx.analysis.imports.values()
    while true:
        let target_ptr = import_values.next() else:
            break
        let target_module = unsafe: read(target_ptr)
        match lowering.find_imported_analysis(ctx, target_module):
            Option.some as imported:
                if imported.value.type_names.contains(name) or imported.value.value_types.contains(name):
                    return Option[str].some(value = naming.qualified_c_name(target_module, name))
            Option.none:
                pass
    return Option[str].none
