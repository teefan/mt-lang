## Compile-time constant evaluation — AST evaluation, const IR construction,
## and enum/flags member resolution.  Extracted from lowering/lowering.mt.

import std.vec as vec
import std.map as map_mod
import std.str

import mtc.ir as ir
import mtc.parser.ast as ast
import mtc.semantic.analyzer as analyzer
import mtc.semantic.types as types

import mtc.lowering.comptime as comptime
import mtc.lowering.comptime_types as comptime_types
import mtc.lowering.layout as layout_mod
import mtc.lowering.type_helpers as type_helpers
import mtc.lowering.lowering as lowering


## The value of `type_name.member_name` in the module that declares the enum —
## the host's constant evaluation of an enum member (`int<-Kind.A` → 0).
function enum_member_value_in_module(
    ctx: ref[lowering.LoweringContext],
    module_name: str,
    type_name: str,
    member_name: str
) -> Option[long]:
    let a = lowering.find_imported_analysis(ctx, module_name) else:
        return Option[long].none
    return enum_member_value_in_file(ctx, a.source_file, type_name, member_name)


## The value of an enum/flags member *expression* (`Kind.A`, or an imported
## `Keyb.KEY_ESCAPE`): the member's own type names the declaring module, with the
## name-based lookup as a fallback.
function enum_member_value_of_expr(ctx: ref[lowering.LoweringContext], ep: ptr[ast.Expr]) -> Option[long]:
    unsafe:
        match read(ep):
            ast.Expr.expr_member_access as ma:
                let operand_ty = type_helpers.expr_type(ctx, ep)
                var enum_name = ""
                var enum_module = ""
                match operand_ty:
                    types.Type.ty_imported as im:
                        let im_bp = unsafe: read(im.payload)
                        enum_name = im_bp.name
                        enum_module = if im_bp.module_name.len > 0: im_bp.module_name else: ctx.module_name
                    types.Type.ty_named as nm:
                        let nm_np = unsafe: read(nm.payload)
                        enum_name = nm_np.name
                        enum_module = if nm_np.module_name.len > 0: nm_np.module_name else: ctx.module_name
                    _:
                        pass
                if enum_name.len > 0:
                    var found = Option[long].none
                    if enum_module.equal(ctx.module_name):
                        found = enum_member_value_in_file(ctx, ctx.analysis.source_file, enum_name, ma.member_name)
                    else:
                        found = enum_member_value_in_module(ctx, enum_module, enum_name, ma.member_name)
                    match found:
                        Option.some as mv:
                            return Option[long].some(value = mv.value)
                        Option.none:
                            pass
                let by_name = try_lookup_enum_value(ctx, ma.receiver, ma.member_name)
                if by_name >= 0:
                    return Option[long].some(value = by_name)
                return Option[long].none
            _:
                return Option[long].none


public function enum_member_value_in_file(
    ctx: ref[lowering.LoweringContext],
    file: ast.SourceFile,
    type_name: str,
    member_name: str
) -> Option[long]:
    var di: ptr_uint = 0
    while di < file.declarations.len:
        var d: ast.Decl
        unsafe:
            d = read(file.declarations.data + di)
        match d:
            ast.Decl.decl_enum as e:
                if e.name == type_name:
                    var mi: ptr_uint = 0
                    var auto_val: long = 0
                    while mi < e.enum_members.len:
                        var m: ast.EnumMember
                        unsafe:
                            m = read(e.enum_members.data + mi)
                        let vp = m.value
                        if vp != null:
                            unsafe:
                                match try_evaluate_const_expr(ctx, vp):
                                    Option.some as cv_val:
                                        match cv_val.value:
                                            comptime_types.ConstValue.cv_int as iv:
                                                auto_val = iv.value
                                            _:
                                                pass
                                    Option.none:
                                        pass
                        if m.name == member_name:
                            return Option[long].some(value = auto_val)
                        auto_val += 1
                        mi += 1
                    return Option[long].none
            _:
                pass
        di += 1
    return Option[long].none


## Compile-time value evaluation of a constant initializer to an IR constant
## expression.  Supports literals, module constants, `const function` calls, and
## struct/variant/array literals.  Returns none when the expression is not
## compile-time known, in which case the initializer is lowered normally.
public function try_const_value_ir(
    ctx: ref[lowering.LoweringContext],
    ep: ptr[ast.Expr],
    env: ref[map_mod.Map[str, ptr[ir.Expr]]]
) -> Option[ptr[ir.Expr]]:
    unsafe:
        match read(ep):
            ast.Expr.expr_integer_literal as lit:
                return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(lowering.integer_literal_expr(
                    lit.lexeme,
                    lit.value,
                    types.primitive("int")
                )))
            ast.Expr.expr_float_literal as lit:
                return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_float_literal(
                    value = lit.value,
                    ty = types.primitive("float")
                )))
            ast.Expr.expr_bool_literal as b:
                return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_boolean_literal(
                    value = b.value,
                    ty = ctx.bool_ty
                )))
            ast.Expr.expr_string_literal as s:
                return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_string_literal(
                    value = s.value,
                    ty = types.Type.ty_str,
                    cstring = s.is_cstring
                )))
            ast.Expr.expr_char_literal as c:
                return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_integer_literal(
                    value = long<-c.value,
                    ty = types.primitive("ubyte")
                )))
            ast.Expr.expr_null_literal as nl:
                let tr = nl.target_type
                if tr != null:
                    let target = lowering.resolve_type_ref(ctx, tr)
                    return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_null_literal(ty = types.Type.ty_null(target = types.alloc_type(target)))))
                return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_null_literal(ty = ctx.void_ty)))
            ast.Expr.expr_identifier as id:
                let entry = env.get(id.name)
                if entry != null:
                    return Option[ptr[ir.Expr]].some(value = unsafe: read(entry))
                let decl_val = find_const_value_ast(ctx, id.name)
                if decl_val != null:
                    match comptime.const_decl_type(ctx, id.name):
                        Option.some as dt:
                            return try_const_typed_value_ir(ctx, unsafe: ptr[ast.Expr]<-decl_val, env, dt.value)
                        Option.none:
                            pass
                    return try_const_value_ir(ctx, unsafe: ptr[ast.Expr]<-decl_val, env)
                if id.name == "true":
                    return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_boolean_literal(
                        value = true,
                        ty = ctx.bool_ty
                    )))
                if id.name == "false":
                    return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_boolean_literal(
                        value = false,
                        ty = ctx.bool_ty
                    )))
                return Option[ptr[ir.Expr]].none
            ast.Expr.expr_binary_op as bin:
                match try_const_value_ir(ctx, bin.left, env):
                    Option.some as lv:
                        match try_const_value_ir(ctx, bin.right, env):
                            Option.some as rv:
                                return comptime.const_fold_binary_ir(ctx, bin.operator, lv.value, rv.value)
                            Option.none:
                                pass
                    Option.none:
                        pass
                return Option[ptr[ir.Expr]].none
            ast.Expr.expr_unary_op as un:
                match try_const_value_ir(ctx, un.operand, env):
                    Option.some as ov:
                        return comptime.const_fold_unary_ir(ctx, un.operator, ov.value)
                    Option.none:
                        pass
                return Option[ptr[ir.Expr]].none
            ast.Expr.expr_prefix_cast as pc:
                # An enum member is a compile-time integer, so its cast folds:
                # `int<-Kind.A` → 0 (`raylib/*`'s key tables are arrays of such
                # casts).  A bare enum member *reference* keeps its name — only
                # the cast fold consults the member's value.
                var operand_ir = try_const_value_ir(ctx, pc.expression, env)
                match operand_ir:
                    Option.some:
                        pass
                    Option.none:
                        match enum_member_value_of_expr(ctx, pc.expression):
                            Option.some as mv:
                                operand_ir = Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_integer_literal(
                                    value = mv.value,
                                    ty = types.primitive("int")
                                )))
                            Option.none:
                                pass
                match operand_ir:
                    Option.some as ov:
                        let target = lowering.resolve_type_ref(ctx, pc.target_type)
                        var target_name = ""
                        var target_is_prim = false
                        match target:
                            types.Type.ty_primitive as tp:
                                target_is_prim = true
                                target_name = tp.name
                            _:
                                pass
                        if target_is_prim:
                            # Host `evaluate_prefix_cast`: numeric operands fold
                            # to the target type; anything else is not foldable.
                            var numeric = false
                            var value: long = 0
                            var fvalue: double = 0.0
                            var is_float_operand = false
                            match read(ov.value):
                                ir.Expr.expr_integer_literal as lit:
                                    numeric = true
                                    value = lit.value
                                ir.Expr.expr_float_literal as fl:
                                    numeric = true
                                    is_float_operand = true
                                    fvalue = fl.value
                                ir.Expr.expr_boolean_literal as b:
                                    numeric = true
                                    value = if b.value: 1 else: 0
                                _:
                                    pass
                            if numeric:
                                if target_name == "bool":
                                    let truth = if is_float_operand: fvalue != 0.0 else: value != 0
                                    return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_boolean_literal(
                                        value = truth,
                                        ty = target
                                    )))
                                let width = comptime.const_integer_width(target_name)
                                if width > 0:
                                    var iv = if is_float_operand: long<-fvalue else: value
                                    iv = lowering.wrap_int_value(iv, width, types.is_signed_integer_name(target_name))
                                    return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_integer_literal(
                                        value = iv,
                                        ty = target
                                    )))
                                if target_name == "float" or target_name == "double":
                                    var dv = if is_float_operand: fvalue else: double<-value
                                    if target_name == "float":
                                        dv = lowering.float32_round(dv)
                                    return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_float_literal(
                                        value = dv,
                                        ty = target
                                    )))
                                return Option[ptr[ir.Expr]].none
                            return Option[ptr[ir.Expr]].none
                        return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_cast(
                            target_type = target,
                            expression = ov.value,
                            ty = target
                        )))
                    Option.none:
                        pass
                return Option[ptr[ir.Expr]].none
            ast.Expr.expr_call as call:
                return try_const_call_ir(ctx, call.callee, call.args, env)
            ast.Expr.expr_index_access as ia:
                return try_const_index_ir(ctx, ia.receiver, ia.index, env)
            ast.Expr.expr_member_access as ma:
                return try_const_member_ir(ctx, ma.receiver, ma.member_name, env)
            ast.Expr.expr_expression_list as els:
                return try_const_tuple_ir(ctx, els.elements, env)
            ast.Expr.expr_if as iff:
                match comptime.const_env_eval_bool(ctx, env, iff.condition):
                    Option.some as cv:
                        if cv.value:
                            return try_const_value_ir(ctx, iff.then_expr, env)
                        return try_const_value_ir(ctx, iff.else_expr, env)
                    Option.none:
                        return Option[ptr[ir.Expr]].none
            ast.Expr.expr_match as m:
                match try_const_value_ir(ctx, m.scrutinee, env):
                    Option.some as sv:
                        var ai: ptr_uint = 0
                        while ai < m.arms.len:
                            var arm: ast.MatchExprArm
                            unsafe:
                                arm = read(m.arms.data + ai)
                            match comptime.const_match_pattern(ctx, env, arm.pattern, sv.value):
                                Option.some as matched:
                                    if matched.value:
                                        return try_const_value_ir(ctx, arm.value, env)
                                Option.none:
                                    return Option[ptr[ir.Expr]].none
                            ai += 1
                        return Option[ptr[ir.Expr]].none
                    Option.none:
                        return Option[ptr[ir.Expr]].none
            ast.Expr.expr_sizeof as sz:
                let target = lowering.resolve_type_ref(ctx, sz.target_type)
                match layout_mod.layout_size(ctx, target):
                    Option.some as v:
                        return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_integer_literal(
                            value = v.value,
                            ty = types.primitive("ptr_uint")
                        )))
                    Option.none:
                        return Option[ptr[ir.Expr]].none
            ast.Expr.expr_alignof as al:
                let target = lowering.resolve_type_ref(ctx, al.target_type)
                match layout_mod.layout_alignment(ctx, target):
                    Option.some as v:
                        return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_integer_literal(
                            value = v.value,
                            ty = types.primitive("ptr_uint")
                        )))
                    Option.none:
                        return Option[ptr[ir.Expr]].none
            ast.Expr.expr_offsetof as off:
                let target = lowering.resolve_type_ref(ctx, off.target_type)
                match layout_mod.layout_offset_of(ctx, target, off.field):
                    Option.some as v:
                        return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_integer_literal(
                            value = v.value,
                            ty = types.primitive("ptr_uint")
                        )))
                    Option.none:
                        return Option[ptr[ir.Expr]].none
            _:
                return Option[ptr[ir.Expr]].none
    return Option[ptr[ir.Expr]].none


## True when an IR expression is a pure integer constant tree (literals under
## integer unary/binary operators), so a contextual retype cannot change names,
## calls or flag/enum members.
function ir_pure_integer_const(v: ir.Expr) -> bool:
    match v:
        ir.Expr.expr_integer_literal:
            return true
        ir.Expr.expr_unsigned_integer_literal:
            return true
        ir.Expr.expr_unary as u:
            if u.operator == "-" or u.operator == "~":
                return ir_pure_integer_const(unsafe: read(u.operand))
            return false
        ir.Expr.expr_binary as b:
            if is_pure_integer_operator(b.operator):
                return ir_pure_integer_const(unsafe: read(b.left)) and ir_pure_integer_const(unsafe: read(b.right))
            return false
        _:
            return false


function is_pure_integer_operator(operator: str) -> bool:
    if operator == "+" or operator == "-" or operator == "*" or operator == "/":
        return true
    if operator == "%" or operator == "&" or operator == "|" or operator == "^":
        return true
    return operator == "<<" or operator == ">>"


## Retype a pure integer constant tree to `target_ty` (the host's contextual
## inference of an enum member value against the backing type).
public function retag_pure_integer_const(v: ir.Expr, target_ty: types.Type) -> ir.Expr:
    if not types.is_integer_type(target_ty) or not ir_pure_integer_const(v):
        return v
    match v:
        ir.Expr.expr_integer_literal as lit:
            return ir.Expr.expr_integer_literal(value = lit.value, ty = target_ty)
        ir.Expr.expr_unsigned_integer_literal as lit:
            return ir.Expr.expr_unsigned_integer_literal(value = lit.value, ty = target_ty)
        ir.Expr.expr_unary as u:
            return ir.Expr.expr_unary(
                operator = u.operator,
                operand = lowering.alloc_expr(retag_pure_integer_const(unsafe: read(u.operand), target_ty)),
                ty = target_ty
            )
        ir.Expr.expr_binary as b:
            return ir.Expr.expr_binary(
                operator = b.operator,
                left = lowering.alloc_expr(retag_pure_integer_const(unsafe: read(b.left), target_ty)),
                right = lowering.alloc_expr(retag_pure_integer_const(unsafe: read(b.right), target_ty)),
                ty = target_ty
            )
        _:
            return v


## Type a folded literal without masking it — the host's
## `lower_compile_time_literal` (a plain expression constant).
public function retype_const_literal(v: ir.Expr, target_ty: types.Type) -> ir.Expr:
    if types.is_integer_type(target_ty):
        match v:
            ir.Expr.expr_integer_literal as lit:
                return ir.Expr.expr_integer_literal(value = lit.value, ty = target_ty)
            ir.Expr.expr_unsigned_integer_literal as lit:
                return ir.Expr.expr_unsigned_integer_literal(value = lit.value, ty = target_ty)
            _:
                pass
    if types.is_float_type(target_ty):
        match v:
            ir.Expr.expr_float_literal as lit:
                return ir.Expr.expr_float_literal(value = lit.value, ty = target_ty)
            _:
                pass
    return v


## The host's `rewrite_static_storage_initializer` fallback: lower the
## referenced imported constant's declaration initializer in its own module
## context (used when the folded value cannot be represented literally).
public function lower_imported_const_initializer(
    ctx: ref[lowering.LoweringContext],
    ep: ptr[ast.Expr],
    expected_ty: types.Type
) -> Option[ptr[ir.Expr]]:
    var target_module = ""
    var const_name = ""
    unsafe:
        match read(ep):
            ast.Expr.expr_member_access as ma:
                match read(ma.receiver):
                    ast.Expr.expr_identifier as id:
                        let mod_ptr = ctx.analysis.imports.get(id.name)
                        if mod_ptr == null:
                            return Option[ptr[ir.Expr]].none
                        target_module = read(mod_ptr)
                        const_name = ma.member_name
                    _:
                        return Option[ptr[ir.Expr]].none
            _:
                return Option[ptr[ir.Expr]].none
    let imported = lowering.find_imported_analysis(ctx, target_module) else:
        return Option[ptr[ir.Expr]].none
    var init_ast: ptr[ast.Expr]? = null
    var di: ptr_uint = 0
    while di < imported.source_file.declarations.len:
        unsafe:
            match read(imported.source_file.declarations.data + di):
                ast.Decl.decl_const as c:
                    if c.name == const_name:
                        init_ast = c.value
                _:
                    pass
        di += 1
    let init = init_ast else:
        return Option[ptr[ir.Expr]].none
    var saved_module = ctx.module_name
    var saved_analysis = ctx.analysis
    var saved_foreign = ctx.foreign_map
    var saved_variants = ctx.variants
    var saved_locals = ctx.locals
    var saved_counter = ctx.temp_counter
    var saved_subst = ctx.type_substitution
    var saved_inside = ctx.inside_async
    var saved_cps = ctx.async_cps_active
    var saved_completion = ctx.async_completion_active

    ctx.module_name = target_module
    ctx.analysis = imported
    ctx.foreign_map = map_mod.Map[str, lowering.ForeignInfo].create()
    ctx.variants = map_mod.Map[str, lowering.VariantInfo].create()
    ctx.locals = vec.Vec[lowering.LocalBinding].create()
    ctx.temp_counter = 0
    ctx.type_substitution = map_mod.Map[str, types.Type].create()
    ctx.inside_async = false
    ctx.async_cps_active = false
    ctx.async_completion_active = false
    lowering.collect_foreign_functions(ctx, imported.source_file.declarations)
    lowering.collect_variants(ctx, imported.source_file.declarations)
    lowering.install_prelude_variants(ctx)
    let lowered = lowering.lower_expr(ctx, init)
    let value = lowering.literal_value_to_context_type(ctx, init, expected_ty, lowered)

    ctx.module_name = saved_module
    ctx.analysis = saved_analysis
    ctx.foreign_map = saved_foreign
    ctx.variants = saved_variants
    ctx.locals = saved_locals
    ctx.temp_counter = saved_counter
    ctx.type_substitution = saved_subst
    ctx.inside_async = saved_inside
    ctx.async_cps_active = saved_cps
    ctx.async_completion_active = saved_completion
    return Option[ptr[ir.Expr]].some(value = value)


## Apply the host's declared-type coercion to a folded constant value
## (`lower_const_value_literal`): mask integers to the type's width,
## sign-extend signed types, and recurse into array elements.
public function coerce_const_value(ctx: ref[lowering.LoweringContext], v: ir.Expr, target_ty: types.Type) -> ir.Expr:
    match target_ty:
        types.Type.ty_primitive as tp:
            let width = types.integer_width(tp.name)
            if width > 0 and width < 64:
                match v:
                    ir.Expr.expr_integer_literal as lit:
                        let masked = lowering.wrap_int_value(lit.value, width, types.is_signed_integer_name(tp.name))
                        return ir.Expr.expr_integer_literal(value = masked, ty = target_ty)
                    _:
                        pass
            match v:
                ir.Expr.expr_integer_literal as lit:
                    return ir.Expr.expr_integer_literal(value = lit.value, ty = target_ty)
                ir.Expr.expr_unsigned_integer_literal as lit:
                    # Keep the lexeme-derived unsigned rendering when the target is
                    # unsigned; a signed target (a program the host rejects) keeps
                    # the bit pattern so the emitted C stays a valid initializer.
                    if types.is_unsigned_integer_type(target_ty):
                        return ir.Expr.expr_unsigned_integer_literal(value = lit.value, ty = target_ty)
                    return ir.Expr.expr_integer_literal(value = long<-lit.value, ty = target_ty)
                ir.Expr.expr_float_literal as fl:
                    return ir.Expr.expr_float_literal(value = fl.value, ty = target_ty)
                _:
                    pass
        types.Type.ty_generic as tg:
            let tg_bp = unsafe: read(tg.payload)
            if tg_bp.name == "array" and tg_bp.args.len == 2:
                let element_ty = unsafe: read(tg_bp.args.data + 0)
                match v:
                    ir.Expr.expr_array_literal as al:
                        var elements = vec.Vec[ir.Expr].create()
                        var i: ptr_uint = 0
                        while i < al.elements.len:
                            elements.push(coerce_const_value(ctx, unsafe: read(al.elements.data + i), element_ty))
                            i += 1
                        return ir.Expr.expr_array_literal(ty = target_ty, elements = elements.as_span())
                    _:
                        pass
        _:
            pass
    return v


## Constant-fold an expression whose declared type is known: an expression list
## `(a, b, c)` becomes an array literal when the target is `array[T, N]`.
public function try_const_typed_value_ir(
    ctx: ref[lowering.LoweringContext],
    ep: ptr[ast.Expr],
    env: ref[map_mod.Map[str, ptr[ir.Expr]]],
    target_ty: types.Type
) -> Option[ptr[ir.Expr]]:
    unsafe:
        match read(ep):
            ast.Expr.expr_null_literal as nl:
                # `null[T]` carries `Types::Null :target_type T`; a bare `null`
                # takes the constant's declared type (host expression lowering).
                let tr = nl.target_type
                if tr != null:
                    let target = lowering.resolve_type_ref(ctx, tr)
                    return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_null_literal(ty = types.Type.ty_null(target = types.alloc_type(target)))))
                return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_null_literal(ty = target_ty)))
            _:
                pass
    match target_ty:
        types.Type.ty_primitive as tp:
            # A literal initializer takes the constant's declared type.  A
            # string literal declared as `cstr` becomes a C string literal.
            unsafe:
                match read(ep):
                    ast.Expr.expr_integer_literal as lit:
                        return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(lowering.integer_literal_expr(
                            lit.lexeme,
                            lit.value,
                            target_ty
                        )))
                    ast.Expr.expr_float_literal as lit:
                        return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_float_literal(
                            value = lit.value,
                            ty = target_ty
                        )))
                    ast.Expr.expr_char_literal as ch:
                        return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_integer_literal(
                            value = long<-ch.value,
                            ty = target_ty
                        )))
                    ast.Expr.expr_string_literal as sl:
                        let cs = sl.is_cstring or tp.name == "cstr"
                        return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_string_literal(
                            value = sl.value,
                            ty = target_ty,
                            cstring = cs
                        )))
                    _:
                        pass
        types.Type.ty_generic as tg:
            let tg_bp = unsafe: read(tg.payload)
            if tg_bp.name == "array" and tg_bp.args.len == 2:
                let element_ty = unsafe: read(tg_bp.args.data + 0)
                unsafe:
                    match read(ep):
                        ast.Expr.expr_expression_list as els:
                            var elements = vec.Vec[ir.Expr].create()
                            var i: ptr_uint = 0
                            while i < els.elements.len:
                                match try_const_typed_value_ir(ctx, els.elements.data + i, env, element_ty):
                                    Option.some as ev:
                                        elements.push(read(ev.value))
                                    Option.none:
                                        return Option[ptr[ir.Expr]].none
                                i += 1
                            return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_array_literal(
                                ty = target_ty,
                                elements = elements.as_span()
                            )))
                        _:
                            pass
        _:
            pass
    return try_const_value_ir(ctx, ep, env)


function try_const_tuple_ir(
    ctx: ref[lowering.LoweringContext],
    elements: span[ast.Expr],
    env: ref[map_mod.Map[str, ptr[ir.Expr]]]
) -> Option[ptr[ir.Expr]]:
    var values = vec.Vec[ir.Expr].create()
    var tys = vec.Vec[types.Type].create()
    var i: ptr_uint = 0
    while i < elements.len:
        match try_const_value_ir(ctx, unsafe: elements.data + i, env):
            Option.some as ev:
                values.push(unsafe: read(ev.value))
                tys.push(lowering.ir_expr_type(ev.value))
            Option.none:
                return Option[ptr[ir.Expr]].none
        i += 1
    var fields = vec.Vec[ir.AggregateField].create()
    var fi: ptr_uint = 0
    while fi < values.len():
        let vp = values.get(fi) else:
            return Option[ptr[ir.Expr]].none
        fields.push(ir.AggregateField(name = lowering.tuple_field_name(fi), value = vp))
        fi += 1
    let tup_ty = types.tuple_type(elements = tys.as_span(), field_names = Option[span[str]].none)
    return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_aggregate_literal(
        ty = tup_ty,
        fields = fields.as_span()
    )))


## Constant-fold `arr[i]`, `arr[a..b]`, `str[i]`, and `str[a..b]`.
function try_const_index_ir(
    ctx: ref[lowering.LoweringContext],
    receiver: ptr[ast.Expr],
    index: ptr[ast.Expr],
    env: ref[map_mod.Map[str, ptr[ir.Expr]]]
) -> Option[ptr[ir.Expr]]:
    match try_const_value_ir(ctx, receiver, env):
        Option.some as rv:
            unsafe:
                match read(index):
                    ast.Expr.expr_range as r:
                        let s_opt = comptime.const_env_eval_int(ctx, env, r.start_expr) else:
                            return Option[ptr[ir.Expr]].none
                        let e_opt = comptime.const_env_eval_int(ctx, env, r.end_expr) else:
                            return Option[ptr[ir.Expr]].none
                        match read(rv.value):
                            ir.Expr.expr_array_literal as al:
                                if s_opt < 0 or e_opt > long<-al.elements.len or s_opt > e_opt:
                                    return Option[ptr[ir.Expr]].none
                                var elements = vec.Vec[ir.Expr].create()
                                var i = s_opt
                                while i < e_opt:
                                    elements.push(read(al.elements.data + ptr_uint<-i))
                                    i += 1
                                return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_array_literal(
                                    ty = al.ty,
                                    elements = elements.as_span()
                                )))
                            ir.Expr.expr_string_literal as sl:
                                if s_opt < 0 or e_opt > long<-sl.value.len or s_opt > e_opt:
                                    return Option[ptr[ir.Expr]].none
                                let start = ptr_uint<-s_opt
                                let n = ptr_uint<-(e_opt - s_opt)
                                let sliced = str(data = sl.value.data + start, len = n)
                                return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_string_literal(
                                    value = sliced,
                                    ty = types.Type.ty_str,
                                    cstring = false
                                )))
                            _:
                                return Option[ptr[ir.Expr]].none
                    _:
                        pass
            let idx_opt = comptime.const_env_eval_int(ctx, env, index) else:
                return Option[ptr[ir.Expr]].none
            unsafe:
                match read(rv.value):
                    ir.Expr.expr_array_literal as al:
                        if idx_opt < 0 or idx_opt >= long<-al.elements.len:
                            return Option[ptr[ir.Expr]].none
                        return Option[ptr[ir.Expr]].some(value = al.elements.data + ptr_uint<-idx_opt)
                    ir.Expr.expr_string_literal as sl:
                        if idx_opt < 0 or idx_opt >= long<-sl.value.len:
                            return Option[ptr[ir.Expr]].none
                        return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_integer_literal(
                            value = long<-sl.value.byte_at(ptr_uint<-idx_opt),
                            ty = types.primitive("ubyte")
                        )))
                    _:
                        return Option[ptr[ir.Expr]].none
        Option.none:
            return Option[ptr[ir.Expr]].none
    return Option[ptr[ir.Expr]].none


## Resolve `alias.MEMBER` where `alias` is an import and `MEMBER` is a constant
## declared in the imported module (e.g. `c.EOF` in `std/stdio.mt`).  The
## initializer is evaluated in the imported module's own context, mirroring the
## host's cross-module constant resolution.
function imported_const_value_ir(
    ctx: ref[lowering.LoweringContext],
    receiver: ptr[ast.Expr],
    member: str,
    env: ref[map_mod.Map[str, ptr[ir.Expr]]]
) -> Option[ptr[ir.Expr]]:
    var alias: str
    unsafe:
        match read(receiver):
            ast.Expr.expr_identifier as rid:
                alias = rid.name
            _:
                return Option[ptr[ir.Expr]].none
    let target_ptr = ctx.analysis.imports.get(alias)
    if target_ptr == null:
        return Option[ptr[ir.Expr]].none
    let target_module = unsafe: read(target_ptr)
    let owner_a = lowering.find_imported_analysis(ctx, target_module) else:
        return Option[ptr[ir.Expr]].none
    var saved_module = ctx.module_name
    var saved_analysis = ctx.analysis
    ctx.module_name = owner_a.module_name
    ctx.analysis = owner_a
    var result = Option[ptr[ir.Expr]].none
    let decl_val = find_const_value_ast(ctx, member)
    if decl_val != null:
        var empty_env = map_mod.Map[str, ptr[ir.Expr]].create()
        match comptime.const_decl_type(ctx, member):
            Option.some as dt:
                result = try_const_typed_value_ir(ctx, unsafe: ptr[ast.Expr]<-decl_val, ref_of(empty_env), dt.value)
            Option.none:
                result = try_const_value_ir(ctx, unsafe: ptr[ast.Expr]<-decl_val, ref_of(empty_env))
    ctx.module_name = saved_module
    ctx.analysis = saved_analysis
    return result


## Constant-fold member access: struct fields, `len` on strings/arrays, and
## parenthesized-less variant arms (`Option[int].none`).
function try_const_member_ir(
    ctx: ref[lowering.LoweringContext],
    receiver: ptr[ast.Expr],
    member: str,
    env: ref[map_mod.Map[str, ptr[ir.Expr]]]
) -> Option[ptr[ir.Expr]]:
    match imported_const_value_ir(ctx, receiver, member, env):
        Option.some as imported:
            return Option[ptr[ir.Expr]].some(value = imported.value)
        Option.none:
            pass
    unsafe:
        match read(receiver):
            ast.Expr.expr_specialization as spec:
                match read(spec.callee):
                    ast.Expr.expr_identifier as sid:
                        if ctx.variants.contains(sid.name):
                            return try_const_variant_literal_ir(ctx, sid.name, member, span[ast.Argument](), env)
                    _:
                        pass
            _:
                pass
    match try_const_value_ir(ctx, receiver, env):
        Option.some as rv:
            unsafe:
                match read(rv.value):
                    ir.Expr.expr_aggregate_literal as ag:
                        return comptime.const_field_value(ag.fields, member)
                    ir.Expr.expr_string_literal as sl:
                        if member == "len":
                            return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_integer_literal(
                                value = long<-sl.value.len,
                                ty = types.primitive("int")
                            )))
                    ir.Expr.expr_array_literal as al:
                        if member == "len":
                            return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_integer_literal(
                                value = long<-al.elements.len,
                                ty = types.primitive("int")
                            )))
                    _:
                        pass
        Option.none:
            pass
    return Option[ptr[ir.Expr]].none


## Evaluate a call in constant position: struct literals, variant-arm literals,
## `const function` calls, and `const` methods (static and instance).
function try_const_call_ir(
    ctx: ref[lowering.LoweringContext],
    callee: ptr[ast.Expr],
    args: span[ast.Argument],
    env: ref[map_mod.Map[str, ptr[ir.Expr]]]
) -> Option[ptr[ir.Expr]]:
    unsafe:
        match read(callee):
            ast.Expr.expr_identifier as id:
                if id.name == "has_attribute" and args.len == 2:
                    match comptime.comptime_has_attribute(ctx, args):
                        Option.some as present:
                            return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(
                                ir.Expr.expr_boolean_literal(value = present.value, ty = ctx.bool_ty)
                            ))
                        Option.none:
                            pass
                # A struct of this module, or a local type alias re-exporting one
                # (`type Color = c.Color`), constructs an aggregate literal.
                match comptime.const_aggregate_target_type(ctx, ctx.module_name, id.name):
                    Option.some as target:
                        return try_const_struct_literal_ir(ctx, target.value, args, env)
                    Option.none:
                        pass
                return try_const_function_value(ctx, id.name, args, env)
            ast.Expr.expr_specialization as bare_spec:
                match read(bare_spec.callee):
                    ast.Expr.expr_identifier as bsid:
                        if bsid.name == "array":
                            return try_const_array_literal_ir(ctx, bare_spec.arguments, args, env)
                        if bsid.name == "attribute_arg":
                            return try_const_attribute_arg_ir(ctx, bare_spec.arguments, args, env)
                    _:
                        pass
                return Option[ptr[ir.Expr]].none
            ast.Expr.expr_member_access as ma:
                match read(ma.receiver):
                    ast.Expr.expr_identifier as rid:
                        if ctx.variants.contains(rid.name):
                            return try_const_variant_literal_ir(ctx, rid.name, ma.member_name, args, env)
                        if ctx.analysis.structs.contains(rid.name):
                            return try_const_method_value(
                                ctx,
                                env,
                                rid.name,
                                ma.member_name,
                                Option[ptr[ir.Expr]].none,
                                args
                            )
                        # Qualified struct literal through an import alias
                        # (`rl.Color(r = …)`), which the bare-name branch above
                        # already handles for an unqualified `Color(r = …)`.
                        # The member may be a type alias re-exporting a struct
                        # (`type Color = c.Color`), so the target resolves through
                        # the alias chain like the runtime construction path.
                        let alias_module_ptr = ctx.analysis.imports.get(rid.name)
                        if alias_module_ptr != null:
                            match comptime.const_aggregate_target_type(ctx, read(alias_module_ptr), ma.member_name):
                                Option.some as target:
                                    return try_const_struct_literal_ir(ctx, target.value, args, env)
                                Option.none:
                                    pass
                    ast.Expr.expr_specialization as spec:
                        match read(spec.callee):
                            ast.Expr.expr_identifier as sid:
                                if ctx.variants.contains(sid.name):
                                    return try_const_variant_literal_ir(ctx, sid.name, ma.member_name, args, env)
                                if sid.name == "array":
                                    return try_const_array_literal_ir(ctx, spec.arguments, args, env)
                            _:
                                pass
                    ast.Expr.expr_member_access as inner_ma:
                        # Qualified receiver: `alias.Type.method(...)` — the
                        # extending block declaring the const method names the
                        # type through the same import alias, so the bare type
                        # name is what `try_const_method_value` matches on.
                        match read(inner_ma.receiver):
                            ast.Expr.expr_identifier as alias_id:
                                if ctx.analysis.imports.contains(alias_id.name):
                                    if ctx.variants.contains(inner_ma.member_name):
                                        return try_const_variant_literal_ir(
                                            ctx,
                                            inner_ma.member_name,
                                            ma.member_name,
                                            args,
                                            env
                                        )
                                    return try_const_method_value(
                                        ctx,
                                        env,
                                        inner_ma.member_name,
                                        ma.member_name,
                                        Option[ptr[ir.Expr]].none,
                                        args
                                    )
                            _:
                                pass
                    _:
                        pass
                # Instance method on a compile-time value (`RECT.area()`,
                # `this.area()` inside a const method body).
                match try_const_value_ir(ctx, ma.receiver, env):
                    Option.some as rv:
                        match comptime.const_receiver_struct_name(rv.value):
                            Option.some as sn:
                                return try_const_method_value(
                                    ctx,
                                    env,
                                    sn.value,
                                    ma.member_name,
                                    Option[ptr[ir.Expr]].some(value = rv.value),
                                    args
                                )
                            Option.none:
                                pass
                    Option.none:
                        pass
                return Option[ptr[ir.Expr]].none
            _:
                return Option[ptr[ir.Expr]].none
    return Option[ptr[ir.Expr]].none


## Evaluate a `const` method call by binding `this` (for instance methods) and
## the parameters, then interpreting the method body.
function try_const_method_value(
    ctx: ref[lowering.LoweringContext],
    caller_env: ref[map_mod.Map[str, ptr[ir.Expr]]],
    struct_name: str,
    method_name: str,
    receiver: Option[ptr[ir.Expr]],
    args: span[ast.Argument]
) -> Option[ptr[ir.Expr]]:
    let decls = ctx.analysis.source_file.declarations
    var i: ptr_uint = 0
    while i < decls.len:
        unsafe:
            match read(decls.data + i):
                ast.Decl.decl_extending_block as ex:
                    let type_ref = read(ex.type_name)
                    if lowering.qname_last(type_ref.name) == struct_name:
                        var mi: ptr_uint = 0
                        while mi < ex.methods.len:
                            var m: ast.Method
                            m = read(ex.methods.data + mi)
                            if m.name == method_name and m.is_const and m.method_params.len == args.len:
                                var env = map_mod.Map[str, ptr[ir.Expr]].create()
                                match receiver:
                                    Option.some as rv:
                                        env.set("this", rv.value)
                                    Option.none:
                                        pass
                                var j: ptr_uint = 0
                                while j < args.len:
                                    match try_const_value_ir(ctx, read(args.data + j).arg_value, caller_env):
                                        Option.some as av:
                                            env.set(read(m.method_params.data + j).name, av.value)
                                        Option.none:
                                            return Option[ptr[ir.Expr]].none
                                    j += 1
                                return try_const_value_body(ctx, m.body, ref_of(env))
                            mi += 1
                _:
                    pass
        i += 1
    return Option[ptr[ir.Expr]].none


## Evaluate an `array[T, N](a, b, ...)` constructor to an array literal.
function try_const_array_literal_ir(
    ctx: ref[lowering.LoweringContext],
    type_args: span[ast.TypeArgument],
    args: span[ast.Argument],
    env: ref[map_mod.Map[str, ptr[ir.Expr]]]
) -> Option[ptr[ir.Expr]]:
    if type_args.len != 2:
        return Option[ptr[ir.Expr]].none
    let element_ty = lowering.resolve_type_ref(ctx, unsafe: read(type_args.data + 0).value)
    var array_args = vec.Vec[types.Type].create()
    unsafe:
        array_args.push(element_ty)
        array_args.push(lowering.resolve_array_length_type(ctx, read(type_args.data + 1).value))
    let array_ty = types.generic_type(name = "array", args = array_args.as_span())
    var elements = vec.Vec[ir.Expr].create()
    var i: ptr_uint = 0
    while i < args.len:
        # An *enum member* element of an mt-declared enum folds to its value
        # typed as the enum: `const KINDS: array[TokenKind, 19] =
        # array[…]((TokenKind.dot_dot, …))` carries
        # `(IR::IntegerLiteral :value 33 :type (Types::Enum TokenKind))`.  A
        # *runtime* array literal keeps its member names, and a *raw* module's
        # enum keeps them too (the host cannot know the C values; session 44,
        # item 9a).
        let arg_ast = unsafe: read(args.data + i).arg_value
        match enum_member_value_of_expr(ctx, arg_ast):
            Option.some as mv:
                elements.push(unsafe: read(lowering.alloc_expr(ir.Expr.expr_integer_literal(
                    value = mv.value,
                    ty = element_ty
                ))))
            Option.none:
                match try_const_value_ir(ctx, arg_ast, env):
                    Option.some as ev:
                        # Elements take the element type contextually too: a folded
                        # `array[ubyte, 4](0, 0, 0, 0)` keeps ubyte elements.
                        let retyped = comptime.const_value_to_field_type(ev.value, element_ty)
                        elements.push(unsafe: read(retyped))
                    Option.none:
                        return Option[ptr[ir.Expr]].none
        i += 1
    return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_array_literal(
        ty = array_ty,
        elements = elements.as_span()
    )))


## Fold `attribute_arg[T](attribute_of(field_of(Type, field), attr), name)`.  The
## attribute application is read from the field's AST and its argument named
## `name` is returned.  (The self-host reflection is limited to this pattern,
## matching the corpus usage.)
public function try_const_attribute_arg_ir(
    ctx: ref[lowering.LoweringContext],
    type_args: span[ast.TypeArgument],
    args: span[ast.Argument],
    env: ref[map_mod.Map[str, ptr[ir.Expr]]]
) -> Option[ptr[ir.Expr]]:
    if type_args.len != 1 or args.len != 2:
        return Option[ptr[ir.Expr]].none
    let type_ty = lowering.resolve_type_ref(ctx, unsafe: read(type_args.data + 0).value)
    let arg_name = comptime.comptime_arg_name(unsafe: args.data + 1)
    if arg_name.len == 0:
        return Option[ptr[ir.Expr]].none
    # Unwrap `attribute_of(field_of(Type, field), attr)` to (type, field, attr).
    let attr_call = unsafe: read(args.data + 0).arg_value
    let attr_ident = comptime.comptime_inner_arg_name(attr_call, "attribute_of", 1)
    if attr_ident.len == 0:
        return Option[ptr[ir.Expr]].none
    let field_call = comptime.comptime_inner_arg_expr(attr_call, "attribute_of", 0)
    if field_call == null:
        return Option[ptr[ir.Expr]].none
    let field_call_ptr = ptr[ast.Expr]<-field_call
    let type_name = comptime.comptime_inner_arg_name(field_call_ptr, "field_of", 0)
    let field_name = comptime.comptime_inner_arg_name(field_call_ptr, "field_of", 1)
    if type_name.len == 0 or field_name.len == 0:
        return Option[ptr[ir.Expr]].none
    return find_attribute_arg_literal(ctx, type_name, field_name, attr_ident, arg_name, type_ty)


## The IR literal for attribute argument `arg_name` of `@[attr(...)]` applied to
## `Type.field`, if present.
function find_attribute_arg_literal(
    ctx: ref[lowering.LoweringContext],
    type_name: str,
    field_name: str,
    attr_name: str,
    arg_name: str,
    ty: types.Type
) -> Option[ptr[ir.Expr]]:
    var di: ptr_uint = 0
    while di < ctx.analysis.source_file.declarations.len:
        var d: ast.Decl
        unsafe:
            d = read(ctx.analysis.source_file.declarations.data + di)
        match d:
            ast.Decl.decl_struct as s:
                if s.name == type_name:
                    var fi: ptr_uint = 0
                    while fi < s.struct_fields.len:
                        var f: ast.Field
                        unsafe:
                            f = read(s.struct_fields.data + fi)
                        if f.name == field_name:
                            let found = attribute_apps_arg_literal(ctx, f.attributes, attr_name, arg_name, ty)
                            if found.is_some():
                                return found
                        fi += 1
            _:
                pass
        di += 1
    return Option[ptr[ir.Expr]].none


## Search a field's attribute applications for `@[attr_name(...)]` and return the
## IR literal for its argument `arg_name`.
function attribute_apps_arg_literal(
    ctx: ref[lowering.LoweringContext],
    apps: span[ast.AttributeApplication],
    attr_name: str,
    arg_name: str,
    ty: types.Type
) -> Option[ptr[ir.Expr]]:
    var ai: ptr_uint = 0
    while ai < apps.len:
        var app: ast.AttributeApplication
        unsafe:
            app = read(apps.data + ai)
        if app.name.parts.len == 1:
            let app_name = unsafe: read(app.name.parts.data + 0)
            if app_name == attr_name:
                # Explicitly named arguments take precedence.
                var argi: ptr_uint = 0
                while argi < app.arguments.len:
                    var app_arg: ast.Argument
                    unsafe:
                        app_arg = read(app.arguments.data + argi)
                    match app_arg.arg_name:
                        Option.some as an:
                            if an.value == arg_name:
                                return attribute_arg_value_to_ir(ctx, app_arg.arg_value, ty)
                        Option.none:
                            pass
                    argi += 1
                # Positional argument: match against the attribute declaration's
                # parameter list to find the parameter named `arg_name`.
                match attribute_param_index(ctx, attr_name, arg_name):
                    Option.some as idx:
                        if idx.value < app.arguments.len:
                            let app_arg = unsafe: read(app.arguments.data + idx.value)
                            return attribute_arg_value_to_ir(ctx, app_arg.arg_value, ty)
                    Option.none:
                        pass
        ai += 1
    return Option[ptr[ir.Expr]].none


## The positional index of parameter `param_name` in the attribute declaration
## `attribute[...] <attr_name>(<params>)`, or none.
function attribute_param_index(ctx: ref[lowering.LoweringContext], attr_name: str, param_name: str) -> Option[ptr_uint]:
    var di: ptr_uint = 0
    while di < ctx.analysis.source_file.declarations.len:
        var d: ast.Decl
        unsafe:
            d = read(ctx.analysis.source_file.declarations.data + di)
        match d:
            ast.Decl.decl_attribute as a:
                if a.name == attr_name:
                    var pi: ptr_uint = 0
                    while pi < a.attr_params.len:
                        var p: ast.Param
                        unsafe:
                            p = read(a.attr_params.data + pi)
                        if p.name == param_name:
                            return Option[ptr_uint].some(value = pi)
                        pi += 1
            _:
                pass
        di += 1
    return Option[ptr_uint].none


function attribute_arg_value_to_ir(
    ctx: ref[lowering.LoweringContext],
    ep: ptr[ast.Expr],
    ty: types.Type
) -> Option[ptr[ir.Expr]]:
    let result_ty = if types.is_error(ty): types.Type.ty_str else: ty
    unsafe:
        match read(ep):
            ast.Expr.expr_string_literal as s:
                return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_string_literal(
                    value = s.value,
                    ty = result_ty,
                    cstring = s.is_cstring
                )))
            ast.Expr.expr_integer_literal as lit:
                return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(lowering.integer_literal_expr(
                    lit.lexeme,
                    lit.value,
                    result_ty
                )))
            ast.Expr.expr_bool_literal as b:
                return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_boolean_literal(
                    value = b.value,
                    ty = result_ty
                )))
            _:
                pass
    return Option[ptr[ir.Expr]].none


## Fold a struct construction into an aggregate literal of `target`'s type.  The
## target is the struct the constructor names, resolved through its alias chain
## by `const_aggregate_target_type`, so the fields come from the declaring module.
function try_const_struct_literal_ir(
    ctx: ref[lowering.LoweringContext],
    target: types.Type,
    args: span[ast.Argument],
    env: ref[map_mod.Map[str, ptr[ir.Expr]]]
) -> Option[ptr[ir.Expr]]:
    var struct_name = ""
    var field_module = ctx.module_name
    match target:
        types.Type.ty_named as nm:
            let nm_np = unsafe: read(nm.payload)
            struct_name = nm_np.name
            field_module = nm_np.module_name
        types.Type.ty_imported as im:
            let im_bp = unsafe: read(im.payload)
            struct_name = im_bp.name
            field_module = im_bp.module_name
        _:
            return Option[ptr[ir.Expr]].none
    var fields = vec.Vec[ir.AggregateField].create()
    var i: ptr_uint = 0
    while i < args.len:
        var arg: ast.Argument
        unsafe:
            arg = read(args.data + i)
        let field_name = arg.arg_name else:
            return Option[ptr[ir.Expr]].none
        match try_const_value_ir(ctx, arg.arg_value, env):
            Option.some as fv:
                # Folded constants must still carry the *field's* type: the
                # folder types an integer literal `int`, while the host renders
                # e.g. `LIGHTGRAY`'s fields as `ubyte`.
                var field_value = fv.value
                match lowering.find_struct_field_type(ctx, struct_name, field_module, field_name):
                    Option.some as field_ty:
                        field_value = lowering.int_literal_to_context_type(arg.arg_value, field_ty.value, field_value)
                        field_value = lowering.null_literal_to_context_type(arg.arg_value, field_ty.value, field_value)
                        field_value = comptime.const_value_to_field_type(field_value, field_ty.value)
                    Option.none:
                        pass
                fields.push(ir.AggregateField(name = field_name, value = field_value))
            Option.none:
                return Option[ptr[ir.Expr]].none
        i += 1
    return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_aggregate_literal(
        ty = target,
        fields = fields.as_span()
    )))


function try_const_variant_literal_ir(
    ctx: ref[lowering.LoweringContext],
    variant_name: str,
    arm_name: str,
    args: span[ast.Argument],
    env: ref[map_mod.Map[str, ptr[ir.Expr]]]
) -> Option[ptr[ir.Expr]]:
    var fields = vec.Vec[ir.AggregateField].create()
    var i: ptr_uint = 0
    while i < args.len:
        var arg: ast.Argument
        unsafe:
            arg = read(args.data + i)
        let field_name = arg.arg_name else:
            return Option[ptr[ir.Expr]].none
        match try_const_value_ir(ctx, arg.arg_value, env):
            Option.some as fv:
                fields.push(ir.AggregateField(name = field_name, value = fv.value))
            Option.none:
                return Option[ptr[ir.Expr]].none
        i += 1
    let var_ty = types.named_type(name = variant_name, module_name = ctx.module_name, linkage_name = Option[str].none)
    return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_variant_literal(
        ty = var_ty,
        arm_name = arm_name,
        fields = fields.as_span()
    )))


## Evaluate a `const function` call by binding arguments into a fresh
## environment and interpreting the body's `let` / `return` statements.
function try_const_function_value(
    ctx: ref[lowering.LoweringContext],
    func_name: str,
    args: span[ast.Argument],
    caller_env: ref[map_mod.Map[str, ptr[ir.Expr]]]
) -> Option[ptr[ir.Expr]]:
    let decls = ctx.analysis.source_file.declarations
    var i: ptr_uint = 0
    var func_body: ptr[ast.Stmt]? = null
    var func_params: span[ast.Param] = span[ast.Param]()
    while i < decls.len:
        unsafe:
            match read(decls.data + i):
                ast.Decl.decl_function as f:
                    if f.name == func_name and f.is_const and f.method_params.len == args.len:
                        func_body = f.body
                        func_params = f.method_params
                        break
                _:
                    pass
        i += 1
    let body_ptr = func_body else:
        return Option[ptr[ir.Expr]].none
    var env = map_mod.Map[str, ptr[ir.Expr]].create()
    var j: ptr_uint = 0
    while j < args.len:
        let arg_ep = unsafe: read(args.data + j).arg_value
        match try_const_value_ir(ctx, arg_ep, caller_env):
            Option.some as av:
                unsafe:
                    env.set(read(func_params.data + j).name, av.value)
            Option.none:
                return Option[ptr[ir.Expr]].none
        j += 1
    return try_const_value_body(ctx, body_ptr, ref_of(env))


## Evaluate a const block body to its `return` value.  Returns none when the
## body cannot be folded or completes without returning.
public function try_const_value_body(
    ctx: ref[lowering.LoweringContext],
    body: ptr[ast.Stmt]?,
    env: ref[map_mod.Map[str, ptr[ir.Expr]]]
) -> Option[ptr[ir.Expr]]:
    match comptime.const_flow_body(ctx, env, body):
        comptime_types.ConstFlow.cf_value as v:
            return Option[ptr[ir.Expr]].some(value = v.value)
        comptime_types.ConstFlow.cf_break:
            return Option[ptr[ir.Expr]].none
        comptime_types.ConstFlow.cf_continue:
            return Option[ptr[ir.Expr]].none
        comptime_types.ConstFlow.cf_fallthrough:
            return Option[ptr[ir.Expr]].none
        comptime_types.ConstFlow.cf_stuck:
            return Option[ptr[ir.Expr]].none
    return Option[ptr[ir.Expr]].none


## Compile-time evaluation of `==` / `!=` over constant operands, used to fold
## struct/variant constant comparisons (`const EQ: bool = A == B`).  Resolves
## identifiers through module constants and compares literals, struct/variant
## literals, and array literals structurally.  Returns none when either side is
## not compile-time known, in which case the comparison is lowered normally.
public function try_const_equality(ctx: ref[lowering.LoweringContext], ep: ptr[ast.Expr]) -> Option[bool]:
    unsafe:
        match read(ep):
            ast.Expr.expr_binary_op as bin:
                if bin.operator == "==" or bin.operator == "!=":
                    match comptime.const_operand_eq(ctx, bin.left, bin.right):
                        Option.some as eq:
                            if bin.operator == "==":
                                return Option[bool].some(value = eq.value)
                            return Option[bool].some(value = not eq.value)
                        Option.none:
                            pass
            _:
                pass
    return Option[bool].none


## Resolve an operand expression to its constant form: identifiers naming module
## constants resolve to the constant's value expression (recursively); every
## other expression is returned as-is.
public function resolve_const_operand(
    ctx: ref[lowering.LoweringContext],
    ep: ptr[ast.Expr],
    depth: int
) -> Option[ptr[ast.Expr]]:
    if depth > 32:
        return Option[ptr[ast.Expr]].none
    unsafe:
        match read(ep):
            ast.Expr.expr_identifier as id:
                let cv = ctx.analysis.const_values.get(id.name)
                if cv != null:
                    return resolve_const_operand(ctx, unsafe: read(cv), depth + 1)
                # Constants whose value is not a foldable scalar (struct,
                # variant, array literals) are not in `const_values`; read the
                # declaration's value expression directly.
                let decl_val = find_const_value_ast(ctx, id.name)
                if decl_val != null:
                    return resolve_const_operand(ctx, unsafe: ptr[ast.Expr]<-decl_val, depth + 1)
                return Option[ptr[ast.Expr]].none
            _:
                return Option[ptr[ast.Expr]].some(value = ep)


## The value expression of a module-level constant declaration, or null when
## the name is not a constant of the module currently being lowered.
function find_const_value_ast(ctx: ref[lowering.LoweringContext], name: str) -> ptr[ast.Expr]?:
    let decls = ctx.analysis.source_file.declarations
    var i: ptr_uint = 0
    while i < decls.len:
        unsafe:
            match read(decls.data + i):
                ast.Decl.decl_const as c:
                    if c.name == name:
                        return c.value
                _:
                    pass
        i += 1
    return null


## Look up an enum member's integer value.  Returns >= 0 on success, -1 if not found.
function try_lookup_enum_value(ctx: ref[lowering.LoweringContext], receiver: ptr[ast.Expr], member_name: str) -> long:
    unsafe:
        match read(receiver):
            ast.Expr.expr_identifier as id:
                # Check the current module's source file for enum declarations
                # that match the receiver name and contain the member.
                var i: ptr_uint = 0
                let decls = ctx.analysis.source_file.declarations
                while i < decls.len:
                    var d: ast.Decl
                    unsafe:
                        d = read(decls.data + i)
                    match d:
                        ast.Decl.decl_enum as en:
                            if en.name == id.name:
                                return find_enum_member_value(en.enum_members, member_name)
                        ast.Decl.decl_flags as fl:
                            if fl.name == id.name:
                                return find_enum_member_value(fl.flags_members, member_name)
                        _:
                            pass
                    i += 1
                # Also check in imported module sources
                var mi: ptr_uint = 0
                while mi < ctx.program_analyses.len:
                    var a: analyzer.Analysis
                    unsafe:
                        a = read(ctx.program_analyses.data + mi)
                    if a.module_name == id.name:
                        var di: ptr_uint = 0
                        let adecls = a.source_file.declarations
                        while di < adecls.len:
                            var dd: ast.Decl
                            unsafe:
                                dd = read(adecls.data + di)
                            match dd:
                                ast.Decl.decl_enum as een:
                                    return find_enum_member_value(een.enum_members, member_name)
                                _:
                                    pass
                            di += 1
                    mi += 1
                return -1
            ast.Expr.expr_member_access as type_access:
                # A qualified enum type: `module.Enum.member` (the receiver is
                # `module.Enum`).  Resolve the imported module's enum/flags
                # declaration and its member value.
                match read(type_access.receiver):
                    ast.Expr.expr_identifier as module_id:
                        let target_ptr = ctx.analysis.imports.get(module_id.name)
                        if target_ptr != null:
                            match lowering.find_imported_analysis(ctx, unsafe: read(target_ptr)):
                                Option.some as owner:
                                    var di: ptr_uint = 0
                                    let adecls = owner.value.source_file.declarations
                                    while di < adecls.len:
                                        var dd: ast.Decl
                                        unsafe:
                                            dd = read(adecls.data + di)
                                        match dd:
                                            ast.Decl.decl_enum as een:
                                                if een.name == type_access.member_name:
                                                    return find_enum_member_value(een.enum_members, member_name)
                                            ast.Decl.decl_flags as ffl:
                                                if ffl.name == type_access.member_name:
                                                    return find_enum_member_value(ffl.flags_members, member_name)
                                            _:
                                                pass
                                        di += 1
                                Option.none:
                                    pass
                    _:
                        pass
                return -1
            _:
                return -1
    return -1


## Find an enum/flags member by name and return its value.  Returns -1 if not found.
function find_enum_member_value(members: span[ast.EnumMember], name: str) -> long:
    var i: ptr_uint = 0
    while i < members.len:
        var m: ast.EnumMember
        unsafe:
            m = read(members.data + i)
        if m.name == name:
            let val_expr = m.value else:
                return long<-(i)
            unsafe:
                match read(val_expr):
                    ast.Expr.expr_integer_literal as lit:
                        return long<-lit.value
                    _:
                        return long<-(i)
        i += 1
    return -1


## Try to evaluate an AST expression at compile time, returning the constant
## value when the expression can be resolved.
public function try_evaluate_const_expr(
    ctx: ref[lowering.LoweringContext],
    ep: ptr[ast.Expr]
) -> Option[comptime_types.ConstValue]:
    unsafe:
        match read(ep):
            ast.Expr.expr_integer_literal as lit:
                return Option[comptime_types.ConstValue].some(value = comptime_types.ConstValue.cv_int(value = long<-lit.value))
            ast.Expr.expr_float_literal as lit:
                return Option[comptime_types.ConstValue].some(value = comptime_types.ConstValue.cv_int(value = long<-(lit.value)))
            ast.Expr.expr_bool_literal as b:
                return Option[comptime_types.ConstValue].some(value = comptime_types.ConstValue.cv_bool(value = b.value))
            ast.Expr.expr_string_literal as s:
                return Option[comptime_types.ConstValue].some(value = comptime_types.ConstValue.cv_str(value = s.value))
            ast.Expr.expr_char_literal as ch:
                return Option[comptime_types.ConstValue].some(value = comptime_types.ConstValue.cv_int(value = long<-ch.value))
            ast.Expr.expr_identifier as id:
                let cv_entry = ctx.analysis.const_values.get(id.name)
                if cv_entry != null:
                    unsafe:
                        let cv_val = read(cv_entry)
                        return try_evaluate_const_expr(ctx, cv_val)
                if id.name == "true":
                    return Option[comptime_types.ConstValue].some(value = comptime_types.ConstValue.cv_bool(value = true))
                if id.name == "false":
                    return Option[comptime_types.ConstValue].some(value = comptime_types.ConstValue.cv_bool(value = false))
                # A bare type name or an in-scope generic type parameter evaluates
                # to a compile-time type value, enabling `inline if T == int` and
                # `field.type == float` dispatch.
                match comptime.comptime_identifier_type(ctx, id.name):
                    Option.some as tv:
                        return Option[comptime_types.ConstValue].some(value = comptime_types.ConstValue.cv_type(ty = tv.value))
                    Option.none:
                        pass
                return Option[comptime_types.ConstValue].none
            ast.Expr.expr_member_access as ma:
                # `field.type` inside an `inline for` over `fields_of(T)` resolves
                # to the current field's type as a compile-time type value.
                if ma.member_name == "type":
                    match ctx.inline_for_element:
                        Option.some as elem_val:
                            match elem_val.value:
                                comptime_types.ComptimeElement.ce_struct_field as sf:
                                    return Option[comptime_types.ConstValue].some(value = comptime_types.ConstValue.cv_type(ty = sf.field_type))
                                _:
                                    pass
                        Option.none:
                            pass
                match try_evaluate_const_expr(ctx, ma.receiver):
                    Option.some as rv:
                        return Option[comptime_types.ConstValue].some(value = rv.value)
                    Option.none:
                        pass
                # An imported module constant (`alias.CONST`): evaluate its
                # initializer in the declaring module's context — the host's
                # `resolve_imported_module_const_value` (`sdl.ALPHA_OPAQUE` at a
                # `ubyte` foreign boundary).
                match read(ma.receiver):
                    ast.Expr.expr_identifier as rid:
                        let target_ptr = ctx.analysis.imports.get(rid.name)
                        if target_ptr != null:
                            match lowering.find_imported_analysis(ctx, unsafe: read(target_ptr)):
                                Option.some as owner:
                                    var saved_module = ctx.module_name
                                    var saved_analysis = ctx.analysis
                                    ctx.module_name = owner.value.module_name
                                    ctx.analysis = owner.value
                                    var imported_cv = Option[comptime_types.ConstValue].none
                                    let chain = ctx.analysis.const_values.get(ma.member_name)
                                    if chain != null:
                                        imported_cv = try_evaluate_const_expr(ctx, unsafe: read(chain))
                                    ctx.module_name = saved_module
                                    ctx.analysis = saved_analysis
                                    match imported_cv:
                                        Option.some as cv:
                                            return Option[comptime_types.ConstValue].some(value = cv.value)
                                        Option.none:
                                            pass
                                Option.none:
                                    pass
                    _:
                        pass
                # If the receiver is an enum type, look up the member value
                # from the enum's backing integer.
                let enum_val = try_lookup_enum_value(ctx, ma.receiver, ma.member_name)
                if enum_val >= 0:
                    return Option[comptime_types.ConstValue].some(value = comptime_types.ConstValue.cv_int(value = enum_val))
                return Option[comptime_types.ConstValue].none
            ast.Expr.expr_binary_op as bin:
                return evaluate_const_binary(ctx, bin.operator, bin.left, bin.right)
            ast.Expr.expr_unary_op as un:
                return evaluate_const_unary(ctx, un.operator, un.operand)
            ast.Expr.expr_prefix_cast as pc:
                return evaluate_const_prefix_cast(ctx, pc.target_type, pc.expression)
            ast.Expr.expr_call as call:
                match read(call.callee):
                    ast.Expr.expr_identifier as id:
                        if id.name == "has_attribute" and call.args.len == 2:
                            match comptime.comptime_has_attribute(ctx, call.args):
                                Option.some as present:
                                    return Option[comptime_types.ConstValue].some(
                                        value = comptime_types.ConstValue.cv_bool(value = present.value)
                                    )
                                Option.none:
                                    pass
                    _:
                        pass
                return Option[comptime_types.ConstValue].none
            _:
                return Option[comptime_types.ConstValue].none


## The host's `CompileTime.evaluate_prefix_cast`: fold a constant through the
## cast's target primitive, wrapping integers to the target width/signedness
## (`uint<-MoverBit` → 2, `ubyte<-300` → 44).  A non-primitive target or a
## non-numeric operand stays unfolded.
function evaluate_const_prefix_cast(
    ctx: ref[lowering.LoweringContext],
    target_type: ptr[ast.TypeRef],
    expression: ptr[ast.Expr]
) -> Option[comptime_types.ConstValue]:
    match try_evaluate_const_expr(ctx, expression):
        Option.some as inner:
            match inner.value:
                comptime_types.ConstValue.cv_int as iv:
                    let target_ty = lowering.resolve_type_ref(ctx, target_type)
                    match target_ty:
                        types.Type.ty_primitive as p:
                            if p.name == "bool":
                                return Option[comptime_types.ConstValue].some(value = comptime_types.ConstValue.cv_bool(value = iv.value != 0))
                            if types.is_integer_type(target_ty):
                                let width = types.integer_width(p.name)
                                if width <= 0:
                                    return Option[comptime_types.ConstValue].none
                                return Option[comptime_types.ConstValue].some(value = comptime_types.ConstValue.cv_int(value = wrap_const_integer(
                                    iv.value,
                                    width,
                                    types.is_signed_integer_name(p.name)
                                )))
                            if types.is_float_type(target_ty):
                                return Option[comptime_types.ConstValue].some(value = comptime_types.ConstValue.cv_int(value = iv.value))
                        _:
                            pass
                comptime_types.ConstValue.cv_bool as bv:
                    let target_ty = lowering.resolve_type_ref(ctx, target_type)
                    match target_ty:
                        types.Type.ty_primitive as p:
                            if p.name == "bool":
                                return Option[comptime_types.ConstValue].some(value = inner.value)
                            if types.is_integer_type(target_ty):
                                return Option[comptime_types.ConstValue].some(value = comptime_types.ConstValue.cv_int(value = if bv.value: 1 else: 0))
                        _:
                            pass
                _:
                    pass
        Option.none:
            pass
    return Option[comptime_types.ConstValue].none


function wrap_const_integer(value: long, width: int, signed: bool) -> long:
    if width >= 64:
        return value
    let wide_width = long<-width
    let mask = (1l << wide_width) - 1
    var wrapped = value & mask
    if signed:
        let half = 1l << (wide_width - 1)
        if wrapped >= half:
            wrapped -= 1l << wide_width
    return wrapped


function evaluate_const_unary(
    ctx: ref[lowering.LoweringContext],
    op: str,
    operand: ptr[ast.Expr]
) -> Option[comptime_types.ConstValue]:
    match try_evaluate_const_expr(ctx, operand):
        Option.some as val:
            match val.value:
                comptime_types.ConstValue.cv_int as iv:
                    if op == "-":
                        return Option[comptime_types.ConstValue].some(value = comptime_types.ConstValue.cv_int(value = -iv.value))
                    if op == "~":
                        return Option[comptime_types.ConstValue].some(value = comptime_types.ConstValue.cv_int(value = ~iv.value))
                    return Option[comptime_types.ConstValue].none
                comptime_types.ConstValue.cv_bool as bv:
                    if op == "not":
                        return Option[comptime_types.ConstValue].some(value = comptime_types.ConstValue.cv_bool(value = not bv.value))
                    return Option[comptime_types.ConstValue].none
                _:
                    return Option[comptime_types.ConstValue].none
        Option.none:
            return Option[comptime_types.ConstValue].none


function evaluate_const_binary(
    ctx: ref[lowering.LoweringContext],
    op: str,
    left: ptr[ast.Expr],
    right: ptr[ast.Expr]
) -> Option[comptime_types.ConstValue]:
    match try_evaluate_const_expr(ctx, left):
        Option.some as lv:
            match try_evaluate_const_expr(ctx, right):
                Option.some as rv:
                    return comptime.const_binary_op(op, lv.value, rv.value)
                Option.none:
                    return Option[comptime_types.ConstValue].none
        Option.none:
            return Option[comptime_types.ConstValue].none


public function is_const_comparison_op(op: str) -> bool:
    return op == "==" or op == "!=" or op == "<" or op == "<=" or op == ">" or op == ">="


## Attempt to evaluate a const function call at compile time, returning an IR
## literal when successful.  Walks the function's AST body with a lightweight
## interpreter that supports integer arithmetic, boolean ops, parameters, return
## statements, if/else control flow, while loops, and for loops over arrays.
## Falls back to returning `None` for unrecognised constructs so the regular
## call lowering path can take over.
function try_evaluate_const_function_call(
    ctx: ref[lowering.LoweringContext],
    func_name: str,
    args: span[ast.Argument],
    caller_vars: ref[map_mod.Map[str, long]]
) -> Option[ptr[ir.Expr]]:
    let decls = ctx.analysis.source_file.declarations
    var i: ptr_uint = 0
    var func_body: ptr[ast.Stmt]? = null
    var func_params: span[ast.Param] = span[ast.Param]()
    while i < decls.len:
        unsafe:
            match read(decls.data + i):
                ast.Decl.decl_function as f:
                    if f.name == func_name and f.is_const and f.method_params.len == args.len:
                        func_body = f.body
                        func_params = f.method_params
                        break
                _:
                    pass
        i += 1
    let body_ptr = func_body else:
        return Option[ptr[ir.Expr]].none

    var param_values = map_mod.Map[str, long].create()
    var j: ptr_uint = 0
    while j < args.len:
        let arg_ep = unsafe: read(args.data + j).arg_value
        # Evaluate each argument in the caller's variable scope, so a nested
        # const-function call like `cube` -> `square(x)` resolves `x` from the
        # caller's bindings instead of defaulting to 0.
        # A non-constant argument means the call cannot be folded: fall back to
        # the ordinary call lowering (defaulting it to 0 would fold a runtime
        # call into a wrong literal).
        match evaluate_const_expr_to_long(ctx, caller_vars, arg_ep):
            Option.some as lv:
                unsafe:
                    param_values.set(read(func_params.data + j).name, lv.value)
            Option.none:
                return Option[ptr[ir.Expr]].none
        j += 1

    return try_evaluate_const_body(ctx, ref_of(param_values), body_ptr)


## Evaluate a block body returning an IR expression when the body terminates
## with a return statement that evaluates to a constant.
function try_evaluate_const_body(
    ctx: ref[lowering.LoweringContext],
    variables: ref[map_mod.Map[str, long]],
    body: ptr[ast.Stmt]?
) -> Option[ptr[ir.Expr]]:
    let b = body else:
        return Option[ptr[ir.Expr]].none
    unsafe:
        match read(b):
            ast.Stmt.stmt_block as blk:
                var mi: ptr_uint = 0
                while mi < blk.statements.len:
                    match evaluate_const_stmt(ctx, variables, blk.statements.data + mi):
                        Option.some as result:
                            return Option[ptr[ir.Expr]].some(value = result.value)
                        Option.none:
                            pass
                    mi += 1
                return Option[ptr[ir.Expr]].none
            _:
                return evaluate_const_stmt(ctx, variables, b)


function evaluate_const_stmt(
    ctx: ref[lowering.LoweringContext],
    variables: ref[map_mod.Map[str, long]],
    sp: ptr[ast.Stmt]
) -> Option[ptr[ir.Expr]]:
    unsafe:
        match read(sp):
            ast.Stmt.stmt_ret as r:
                let val_ptr = r.value else:
                    return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(
                        ir.Expr.expr_zero_init(ty = ctx.void_ty)))
                return evaluate_const_expr_to_ir(ctx, variables, val_ptr)
            ast.Stmt.stmt_expression as ex:
                let _discard = evaluate_const_expr_to_ir(ctx, variables, ex.expression)
                return Option[ptr[ir.Expr]].none
            ast.Stmt.stmt_if as ifs:
                var bi: ptr_uint = 0
                while bi < ifs.branches.len:
                    let br = unsafe: read(ifs.branches.data + bi)
                    match evaluate_const_expr_to_long(ctx, variables, br.condition):
                        Option.some as cv:
                            if cv.value != 0:
                                return try_evaluate_const_body(ctx, variables, br.body)
                        Option.none:
                            pass
                    bi += 1
                return try_evaluate_const_body(ctx, variables, ifs.else_body)
            ast.Stmt.stmt_while as ws:
                var iteration: int = 0
                while iteration < 10000:
                    match evaluate_const_expr_to_long(ctx, variables, ws.condition):
                        Option.some as cv:
                            if cv.value == 0:
                                break
                        Option.none:
                            break
                    match try_evaluate_const_body(ctx, variables, ws.body):
                        Option.some as wrv:
                            return Option[ptr[ir.Expr]].some(value = wrv.value)
                        Option.none:
                            pass
                    iteration += 1
                if iteration >= 10000:
                    return Option[ptr[ir.Expr]].none
                return Option[ptr[ir.Expr]].none
            ast.Stmt.stmt_for as fs:
                # Only support single-binding, single-iterable compile-time for loops.
                if fs.bindings.len != 1 or fs.iterables.len != 1:
                    return Option[ptr[ir.Expr]].none
                let binding = unsafe: read(fs.bindings.data + 0)
                let iterable = unsafe: read(fs.iterables.data + 0)
                match evaluate_const_iterable(ctx, iterable):
                    Option.some as iter_vals_payload:
                        var vi: ptr_uint = 0
                        while vi < iter_vals_payload.value.len:
                            unsafe:
                                variables.set(binding.name, read(iter_vals_payload.value.data + vi))
                            match try_evaluate_const_body(ctx, variables, fs.body):
                                Option.some as frv:
                                    return Option[ptr[ir.Expr]].some(value = frv.value)
                                Option.none:
                                    pass
                            vi += 1
                        return Option[ptr[ir.Expr]].none
                    Option.none:
                        return Option[ptr[ir.Expr]].none
            ast.Stmt.stmt_local as loc:
                let init_ptr = loc.value
                if init_ptr != null:
                    match evaluate_const_expr_to_long(ctx, variables, init_ptr):
                        Option.some as lv:
                            variables.set(loc.name, lv.value)
                        Option.none:
                            pass
                return Option[ptr[ir.Expr]].none
            ast.Stmt.stmt_assignment as asg:
                match read(asg.target):
                    ast.Expr.expr_identifier as tid:
                        match evaluate_const_expr_to_long(ctx, variables, asg.value):
                            Option.some as lv:
                                variables.set(tid.name, lv.value)
                            Option.none:
                                pass
                    _:
                        pass
                return Option[ptr[ir.Expr]].none
            _:
                return Option[ptr[ir.Expr]].none


function evaluate_const_iterable(ctx: ref[lowering.LoweringContext], ep: ast.Expr) -> Option[span[long]]:
    unsafe:
        match ep:
            ast.Expr.expr_identifier as id:
                let cv_entry = ctx.analysis.const_values.get(id.name)
                if cv_entry != null:
                    let cv_val = unsafe: read(cv_entry)
                    return evaluate_const_iterable(ctx, unsafe: read(cv_val))
                # Array constants are not in `const_values` (it holds foldable
                # scalars only); read the declaration's value expression.
                let decl_val = find_const_value_ast(ctx, id.name)
                if decl_val != null:
                    return evaluate_const_iterable(ctx, unsafe: read(decl_val))
                return Option[span[long]].none
            ast.Expr.expr_expression_list as els:
                var vals = vec.Vec[long].create()
                var ii: ptr_uint = 0
                while ii < els.elements.len:
                    match evaluate_const_expr_to_long_standalone(ctx, els.elements.data + ii):
                        Option.some as lv:
                            vals.push(lv.value)
                        Option.none:
                            vals.push(0)
                    ii += 1
                return Option[span[long]].some(value = vals.as_span())
            _:
                return Option[span[long]].none


function evaluate_const_expr_to_long(
    ctx: ref[lowering.LoweringContext],
    variables: ref[map_mod.Map[str, long]],
    ep: ptr[ast.Expr]
) -> Option[long]:
    match evaluate_const_expr_to_ir(ctx, variables, ep):
        Option.some as irv:
            unsafe:
                match read(irv.value):
                    ir.Expr.expr_integer_literal as il:
                        return Option[long].some(value = il.value)
                    ir.Expr.expr_boolean_literal as bl:
                        if bl.value:
                            return Option[long].some(value = 1)
                        return Option[long].some(value = 0)
                    ir.Expr.expr_cast as c:
                        match read(c.expression):
                            ir.Expr.expr_integer_literal as cil:
                                return Option[long].some(value = cil.value)
                            ir.Expr.expr_boolean_literal as cbl:
                                if cbl.value:
                                    return Option[long].some(value = 1)
                                return Option[long].some(value = 0)
                            _:
                                pass
                    _:
                        pass
        Option.none:
            pass
    return Option[long].none


## Like evaluate_const_expr_to_long but does not use local variable map;
## evaluates standalone compile-time expressions (e.g. argument values).
function evaluate_const_expr_to_long_standalone(ctx: ref[lowering.LoweringContext], ep: ptr[ast.Expr]) -> Option[long]:
    unsafe:
        match read(ep):
            ast.Expr.expr_integer_literal as lit:
                return Option[long].some(value = lit.value)
            ast.Expr.expr_bool_literal as b:
                if b.value:
                    return Option[long].some(value = 1)
                return Option[long].some(value = 0)
            ast.Expr.expr_identifier as id:
                let entry = ctx.analysis.const_values.get(id.name)
                if entry != null:
                    return evaluate_const_expr_to_long_standalone(ctx, unsafe: read(entry))
                if id.name == "true":
                    return Option[long].some(value = 1)
                if id.name == "false":
                    return Option[long].some(value = 0)
                return Option[long].none
            ast.Expr.expr_binary_op as bin:
                return evaluate_const_expr_to_long_standalone_bin(ctx, bin.operator, bin.left, bin.right)
            ast.Expr.expr_call as call:
                match read(call.callee):
                    ast.Expr.expr_identifier as cid:
                        var standalone_vars = map_mod.Map[str, long].create()
                        match try_evaluate_const_function_call(ctx, cid.name, call.args, ref_of(standalone_vars)):
                            Option.some as rv:
                                unsafe:
                                    match read(rv.value):
                                        ir.Expr.expr_integer_literal as rvl:
                                            return Option[long].some(value = rvl.value)
                                        _:
                                            pass
                            Option.none:
                                pass
                    _:
                        pass
                return Option[long].none
            _:
                return Option[long].none


function evaluate_const_expr_to_long_standalone_bin(
    ctx: ref[lowering.LoweringContext],
    op: str,
    left: ptr[ast.Expr],
    right: ptr[ast.Expr]
) -> Option[long]:
    match evaluate_const_expr_to_long_standalone(ctx, left):
        Option.some as lv:
            match evaluate_const_expr_to_long_standalone(ctx, right):
                Option.some as rv:
                    return Option[long].some(value = lowering.apply_int_op(op, lv.value, rv.value))
                Option.none:
                    pass
        Option.none:
            pass
    return Option[long].none


function evaluate_const_expr_to_ir(
    ctx: ref[lowering.LoweringContext],
    variables: ref[map_mod.Map[str, long]],
    ep: ptr[ast.Expr]
) -> Option[ptr[ir.Expr]]:
    unsafe:
        match read(ep):
            ast.Expr.expr_integer_literal as lit:
                return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(
                    lowering.integer_literal_expr(lit.lexeme, lit.value, types.primitive("int"))))
            ast.Expr.expr_float_literal as lit:
                return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(
                    ir.Expr.expr_integer_literal(value = long<-(lit.value), ty = types.primitive("int"))))
            ast.Expr.expr_bool_literal as b:
                return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(
                    ir.Expr.expr_boolean_literal(value = b.value, ty = ctx.bool_ty)))
            ast.Expr.expr_identifier as id:
                let entry = variables.get(id.name)
                if entry != null:
                    let v = unsafe: read(entry)
                    return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(
                        ir.Expr.expr_integer_literal(value = v, ty = types.primitive("int"))))
                let cv_entry = ctx.analysis.const_values.get(id.name)
                if cv_entry != null:
                    let cv_val = unsafe: read(cv_entry)
                    return evaluate_const_expr_to_ir(ctx, variables, cv_val)
                if id.name == "true":
                    return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(
                        ir.Expr.expr_boolean_literal(value = true, ty = ctx.bool_ty)))
                if id.name == "false":
                    return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(
                        ir.Expr.expr_boolean_literal(value = false, ty = ctx.bool_ty)))
                return Option[ptr[ir.Expr]].none
            ast.Expr.expr_binary_op as bin:
                match evaluate_const_expr_to_ir(ctx, variables, bin.left):
                    Option.some as left_ir:
                        match evaluate_const_expr_to_ir(ctx, variables, bin.right):
                            Option.some as right_ir:
                                return evaluate_const_binary_ir(
                                    op = bin.operator,
                                    left = left_ir.value,
                                    right = right_ir.value
                                )
                            Option.none:
                                pass
                    Option.none:
                        pass
                return Option[ptr[ir.Expr]].none
            ast.Expr.expr_unary_op as un:
                match evaluate_const_expr_to_ir(ctx, variables, un.operand):
                    Option.some as operand_ir:
                        return evaluate_const_unary_ir(op = un.operator, operand = operand_ir.value)
                    Option.none:
                        pass
                return Option[ptr[ir.Expr]].none
            ast.Expr.expr_call as call:
                match read(call.callee):
                    ast.Expr.expr_identifier as cid:
                        match try_evaluate_const_function_call(ctx, cid.name, call.args, variables):
                            Option.some as rv:
                                return Option[ptr[ir.Expr]].some(value = rv.value)
                            Option.none:
                                pass
                    _:
                        pass
                return Option[ptr[ir.Expr]].none
            ast.Expr.expr_member_access as ma:
                return evaluate_const_expr_to_ir(ctx, variables, ma.receiver)
            _:
                return Option[ptr[ir.Expr]].none


function evaluate_const_binary_ir(op: str, left: ptr[ir.Expr], right: ptr[ir.Expr]) -> Option[ptr[ir.Expr]]:
    let int_ty = types.primitive("int")
    let bool_ty = types.primitive("bool")
    let ptr_uint_ty = types.primitive("ptr_uint")
    let uint_ty = types.primitive("uint")
    unsafe:
        match read(left):
            ir.Expr.expr_integer_literal as li:
                match read(right):
                    ir.Expr.expr_integer_literal as ri:
                        let result = lowering.apply_int_op(op, li.value, ri.value)
                        if op == "==" or op == "!=" or op == "<" or op == "<=" or op == ">" or op == ">=":
                            return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(
                                ir.Expr.expr_boolean_literal(value = result != 0, ty = bool_ty)))
                        return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(
                            ir.Expr.expr_integer_literal(value = result, ty = int_ty)))
                    _:
                        pass
            ir.Expr.expr_boolean_literal as lb:
                match read(right):
                    ir.Expr.expr_boolean_literal as rb:
                        if op == "and":
                            return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(
                                ir.Expr.expr_boolean_literal(value = lb.value and rb.value, ty = bool_ty)))
                        if op == "or":
                            return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(
                                ir.Expr.expr_boolean_literal(value = lb.value or rb.value, ty = bool_ty)))
                        if op == "==":
                            return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(
                                ir.Expr.expr_boolean_literal(value = lb.value == rb.value, ty = bool_ty)))
                        if op == "!=":
                            return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(
                                ir.Expr.expr_boolean_literal(value = lb.value != rb.value, ty = bool_ty)))
                    _:
                        pass
            _:
                pass
    return Option[ptr[ir.Expr]].none


function evaluate_const_unary_ir(op: str, operand: ptr[ir.Expr]) -> Option[ptr[ir.Expr]]:
    let int_ty = types.primitive("int")
    let bool_ty = types.primitive("bool")
    unsafe:
        match read(operand):
            ir.Expr.expr_integer_literal as iv:
                if op == "-":
                    return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(
                        ir.Expr.expr_integer_literal(value = -iv.value, ty = int_ty)))
                if op == "~":
                    return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(
                        ir.Expr.expr_integer_literal(value = ~iv.value, ty = int_ty)))
                if op == "+":
                    return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(
                        ir.Expr.expr_integer_literal(value = iv.value, ty = int_ty)))
            ir.Expr.expr_boolean_literal as bv:
                if op == "not":
                    return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(
                        ir.Expr.expr_boolean_literal(value = not bv.value, ty = bool_ty)))
            _:
                pass
    return Option[ptr[ir.Expr]].none
