## Format string lowering — `f"..."` plans and result buffers, cstr-backed
## metadata, and the explicit `append_format`/`assign_format` sinks.  Extracted
## from lowering/lowering.mt.

import std.vec as vec
import std.str
import std.string as string
import std.fmt as fmt

import mtc.ir as ir
import mtc.parser.ast as ast
import mtc.semantic.types as types

import mtc.lowering.comptime_types as comptime_types
import mtc.lowering.const_eval as const_eval
import mtc.lowering.lowering as lowering
import mtc.strings


# =============================================================================
#  Format string lowering (f"...")
# =============================================================================

## True when a format string has no interpolations (only literal text parts),
## so it can collapse to a plain string literal with no runtime building.
public function format_string_all_static(parts: span[ast.FormatStringPart]) -> bool:
    var i: ptr_uint = 0
    while i < parts.len:
        match unsafe: read(parts.data + i):
            ast.FormatStringPart.fmt_expr:
                return false
            _:
                pass
        i += 1
    return true


## The combined literal text of an all-static format string.
public function format_string_static_literal(parts: span[ast.FormatStringPart]) -> ptr[ir.Expr]:
    var buf = string.String.create()
    var i: ptr_uint = 0
    while i < parts.len:
        match unsafe: read(parts.data + i):
            ast.FormatStringPart.fmt_text as t:
                buf.append(t.value)
            _:
                pass
        i += 1
    return lowering.alloc_expr(ir.Expr.expr_string_literal(value = buf.as_str(), ty = types.Type.ty_str, cstring = false))


## The append/length plan for a single interpolation, selected from the value's
## type and an optional format spec.  `len_kind`: 0 = call `len_helper(x)`,
## 1 = `x.len` (str), 2 = precision (`mt_format_double_precision_len(x, N)`).
struct FormatPlan:
    append_helper: str
    len_helper: str
    arg_ty: types.Type
    len_kind: int
    precision: int


function fmt_is_signed_int_name(name: str) -> bool:
    return name == "byte" or name == "short" or name == "int" or name == "long" or name == "ptr_int"


function fmt_plan(ctx: ref[lowering.LoweringContext], val_ty: types.Type, spec_ptr: ptr[ast.FormatSpec]?) -> FormatPlan:
    let long_ty = types.primitive("long")
    let ulong_ty = types.primitive("ulong")
    let double_ty = types.primitive("double")
    # Resolve the primitive name of the value (str is its own kind).
    var is_str = false
    var prim_name: str = ""
    match val_ty:
        types.Type.ty_str:
            is_str = true
        types.Type.ty_primitive as p:
            prim_name = p.name
        _:
            prim_name = ""
    if spec_ptr != null:
        let spec = unsafe: read(spec_ptr)
        let signed = fmt_is_signed_int_name(prim_name)
        match spec.spec_kind:
            ast.FormatSpecKind.precision:
                return FormatPlan(append_helper = "mt_format_append_double_precision", len_helper = "", arg_ty = double_ty, len_kind = 2, precision = spec.value)
            ast.FormatSpecKind.hex:
                if signed:
                    return FormatPlan(append_helper = if spec.uppercase: "mt_format_append_long_hex_upper" else: "mt_format_append_long_hex", len_helper = "mt_format_long_hex_len", arg_ty = long_ty, len_kind = 0, precision = 0)
                return FormatPlan(append_helper = if spec.uppercase: "mt_format_append_ulong_hex_upper" else: "mt_format_append_ulong_hex", len_helper = "mt_format_ulong_hex_len", arg_ty = ulong_ty, len_kind = 0, precision = 0)
            ast.FormatSpecKind.octal:
                if signed:
                    return FormatPlan(append_helper = "mt_format_append_long_oct", len_helper = "mt_format_long_oct_len", arg_ty = long_ty, len_kind = 0, precision = 0)
                return FormatPlan(append_helper = "mt_format_append_ulong_oct", len_helper = "mt_format_ulong_oct_len", arg_ty = ulong_ty, len_kind = 0, precision = 0)
            ast.FormatSpecKind.binary:
                if signed:
                    return FormatPlan(append_helper = "mt_format_append_long_bin", len_helper = "mt_format_long_bin_len", arg_ty = long_ty, len_kind = 0, precision = 0)
                return FormatPlan(append_helper = "mt_format_append_ulong_bin", len_helper = "mt_format_ulong_bin_len", arg_ty = ulong_ty, len_kind = 0, precision = 0)
    if is_str:
        return FormatPlan(append_helper = "mt_format_append_str", len_helper = "", arg_ty = types.Type.ty_str, len_kind = 1, precision = 0)
    if prim_name == "cstr":
        return FormatPlan(append_helper = "mt_format_append_cstr", len_helper = "mt_format_cstr_len", arg_ty = types.primitive("cstr"), len_kind = 0, precision = 0)
    if prim_name == "bool":
        return FormatPlan(append_helper = "mt_format_append_bool", len_helper = "mt_format_bool_len", arg_ty = ctx.bool_ty, len_kind = 0, precision = 0)
    if prim_name == "float":
        return FormatPlan(append_helper = "mt_format_append_float", len_helper = "mt_format_float_len", arg_ty = types.primitive("float"), len_kind = 0, precision = 0)
    if prim_name == "double":
        return FormatPlan(append_helper = "mt_format_append_double", len_helper = "mt_format_double_len", arg_ty = double_ty, len_kind = 0, precision = 0)
    if prim_name == "ubyte" or prim_name == "ushort" or prim_name == "uint":
        return FormatPlan(append_helper = "mt_format_append_uint", len_helper = "mt_format_uint_len", arg_ty = types.primitive("uint"), len_kind = 0, precision = 0)
    if prim_name == "ptr_uint":
        return FormatPlan(append_helper = "mt_format_append_ptr_uint", len_helper = "mt_format_ptr_uint_len", arg_ty = types.primitive("ptr_uint"), len_kind = 0, precision = 0)
    if prim_name == "long" or prim_name == "ptr_int":
        return FormatPlan(append_helper = "mt_format_append_long", len_helper = "mt_format_long_len", arg_ty = long_ty, len_kind = 0, precision = 0)
    if prim_name == "ulong":
        return FormatPlan(append_helper = "mt_format_append_ulong", len_helper = "mt_format_ulong_len", arg_ty = ulong_ty, len_kind = 0, precision = 0)
    # Custom format hooks: a struct implementing `format_len() -> ptr_uint` and
    # `append_format(output: ref[std.string.String]) -> void` renders through
    # those methods (`len_kind = 3`; the helper fields hold the method C names).
    if spec_ptr == null:
        match lowering.resolve_method_info(ctx, val_ty, "format_len"):
            Option.some as lmi:
                match lowering.resolve_method_info(ctx, val_ty, "append_format"):
                    Option.some as ami:
                        if lmi.value.method_kind != ast.MethodKind.mk_editable and ami.value.method_kind != ast.MethodKind.mk_editable:
                            return FormatPlan(append_helper = ami.value.c_name, len_helper = lmi.value.c_name, arg_ty = val_ty, len_kind = 3, precision = 0)
                    Option.none:
                        pass
            Option.none:
                pass
    # byte/short/int and any integer-like fallback (e.g. an int-backed enum cast
    # to int in C) format as a signed 32-bit integer.
    return FormatPlan(append_helper = "mt_format_append_int", len_helper = "mt_format_int_len", arg_ty = types.primitive("int"), len_kind = 0, precision = 0)


## The result temp the next dynamic format string in this function gets, and
## its `_cap`/`_off` companions: the host's
## `build_dynamic_format_string_temp_setup` — `__fmt_<dest>` (with a `_2`/`_3`
## suffix for a destination's repeats, via the per-function counter) when the
## most recent local declaration in scope names one, else
## `fresh_c_temp_name(ctx, "fmt_str")` (`__mt_fmt_str_N`).
function format_string_result_base(ctx: ref[lowering.LoweringContext]) -> str:
    if ctx.fmt_dest_name.len > 0:
        # The env creates its counter slot at the first use (the host's
        # `env[:fmt_counter] ||= {}`).
        if not ctx.fmt_counter_visible:
            ctx.fmt_counter.clear()
            ctx.fmt_counter_visible = true
        var n: ptr_uint = 1
        let n_ptr = ctx.fmt_counter.get(ctx.fmt_dest_name)
        if n_ptr != null:
            n = unsafe: read(n_ptr) + 1
        ctx.fmt_counter.set(ctx.fmt_dest_name, n)
        var buf = string.String.create()
        buf.append("__fmt_")
        buf.append(ctx.fmt_dest_name)
        if n > 1:
            buf.append("_")
            fmt.append_ptr_uint(ref_of(buf), n)
        return buf.as_str()
    return lowering.fresh_c_temp_name(ctx, "fmt_str")


## The post-statement release of a dynamic format string's result (the host's
## `mt_format_str_release` cleanup; emitted with nil line/path like the other
## hoisted statements).
public function format_str_release_stmt(temp: ptr[ir.Expr]) -> ir.Stmt:
    return ir.Stmt.stmt_expression(
        expression = lowering.alloc_expr(ir.Expr.expr_call(callee = "mt_format_str_release", arguments = lowering.single_expr_span(temp), ty = types.primitive("void"))),
        line = 0, source_path = "",
    )


## True when `stmt` is an `mt_format_str_release(...)` statement.
public function is_format_release_stmt(stmt: ir.Stmt) -> bool:
    match stmt:
        ir.Stmt.stmt_expression as es:
            match unsafe: read(es.expression):
                ir.Expr.expr_call as c:
                    return c.callee == "mt_format_str_release"
                _:
                    pass
        _:
            pass
    return false


## Drop a window's format-string releases — the host's
## `reject_format_releases_for_assignment`: a dynamic format string stored into
## a `str`/`cstr` binding (or a struct containing one) transfers ownership of
## its buffer, so its temp must not be released after the statement.
public function drop_format_release_cleanups(collected: lowering.HoistSaved) -> lowering.HoistSaved:
    var kept = vec.Vec[ir.Stmt].create()
    var i: ptr_uint = 0
    while i < collected.cleanups.len:
        let st = collected.cleanups.get(i) else:
            break
        if not is_format_release_stmt(unsafe: read(st)):
            kept.push(unsafe: read(st))
        i += 1
    var result = collected
    result.cleanups = kept
    return result


## True for a type that owns a dynamic format string's buffer when assigned to —
## the host's `cstr_trackable_type?`/`struct_contains_string_field?`: `str`,
## `cstr`, or a struct whose fields (recursively) contain one.
public function format_owning_target_type(ctx: ref[lowering.LoweringContext], ty: types.Type, depth: ptr_uint) -> bool:
    if depth > 8:
        return false
    match ty:
        types.Type.ty_str:
            return true
        types.Type.ty_primitive as p:
            return p.name == "cstr"
        types.Type.ty_named:
            pass
        types.Type.ty_imported:
            pass
        _:
            return false
    let fields = lowering.struct_fields_of(ctx, ty) else:
        return false
    var fi: ptr_uint = 0
    while fi < fields.len:
        if format_owning_target_type(ctx, unsafe: read(fields.data + fi).ty, depth + 1):
            return true
        fi += 1
    return false


## True when a local's value is backed by a C-string buffer that outlives the
## enclosing statement — the host's `cstr_backed_storage_value?`: a `cstr`
## local, or a `str` local whose value is a cstr-typed expression, a string
## literal, a dynamic format string, or another cstr-backed local.
public function cstr_backed_binding(ctx: ref[lowering.LoweringContext], ty: types.Type, init: ptr[ast.Expr]?, value_expr: ptr[ir.Expr]) -> bool:
    match ty:
        types.Type.ty_primitive as p:
            if p.name == "cstr":
                return true
        types.Type.ty_str:
            # The lowered value is a `cstr`-typed expression, another
            # cstr-backed local's read, or a dynamic format string's result temp
            # (registered when the format was built) — the host's
            # prepared-identifier check.
            match lowering.ir_expr_type(value_expr):
                types.Type.ty_primitive as vp:
                    if vp.name == "cstr":
                        return true
                _:
                    pass
            if is_cstr_backed_lowered(ctx, value_expr):
                return true
            let ip = init else:
                return false
            return ast_expr_cstr_backed(ctx, ip)
        _:
            return false
    return false


## The host's `cstr_backed_expression?`: a *syntactic* predicate — a string
## literal, a `cstr`-typed or cstr-backed local's read, or an `if`/`unsafe`
## whose parts are all cstr-backed (`let t = if flag: "a" else: "b"` is
## cstr-backed, so `draw_text(t, …)` passes `t.data` directly).
public function ast_expr_cstr_backed(ctx: ref[lowering.LoweringContext], ep: ptr[ast.Expr]) -> bool:
    unsafe:
        match read(ep):
            ast.Expr.expr_string_literal:
                return true
            ast.Expr.expr_identifier as id:
                match lowering.find_local_binding(ctx, id.name):
                    Option.some as lb:
                        match lb.value.ty:
                            types.Type.ty_primitive as p:
                                if p.name == "cstr":
                                    return true
                            _:
                                pass
                        return ctx.cstr_backed_names.contains(lb.value.c_name)
                    Option.none:
                        # A module constant whose compile-time value is a string
                        # literal is cstr-backed (the host's
                        # `binding.const_value.is_a?(String)`).
                        match const_eval.try_evaluate_const_expr(ctx, ep):
                            Option.some as cv:
                                match cv.value:
                                    comptime_types.ConstValue.cv_str:
                                        return true
                                    _:
                                        return false
                            Option.none:
                                return false
            ast.Expr.expr_if as iff:
                return ast_expr_cstr_backed(ctx, iff.then_expr) and ast_expr_cstr_backed(ctx, iff.else_expr)
            ast.Expr.expr_unsafe as u:
                return ast_expr_cstr_backed(ctx, u.expression)
            _:
                return false


## True when a lowered value is a cstr-backed local's read (or a format-string
## temp), so a `str as cstr` foreign boundary can pass its `data` pointer
## directly — the host's `cstr_backed_expression?` on the prepared identifier.
public function is_cstr_backed_lowered(ctx: ref[lowering.LoweringContext], ep: ptr[ir.Expr]) -> bool:
    unsafe:
        match read(ep):
            ir.Expr.expr_name as n:
                return ctx.cstr_backed_names.contains(n.name)
            _:
                return false


## The host's `update_cstr_metadata_for_assignment!`: an assignment to a `str`
## local refreshes whether its storage is still cstr-backed.  `= <cstr-backed
## value>` keeps it; every other assignment and every compound assignment
## clears it (`skybox_file_name = dropped_path` turns a literal-backed local
## into a plain `str`, so a later `str as cstr` boundary must copy it).
public function update_cstr_metadata_for_assignment_mt(ctx: ref[lowering.LoweringContext], target: ptr[ast.Expr], value_ast: ptr[ast.Expr], value_ir: ptr[ir.Expr], operator: str) -> void:
    unsafe:
        match read(target):
            ast.Expr.expr_identifier as id:
                match lowering.find_local_binding(ctx, id.name):
                    Option.some as lb:
                        var backed = false
                        if operator == "=":
                            match lb.value.ty:
                                types.Type.ty_primitive as p:
                                    if p.name == "cstr":
                                        backed = true
                                types.Type.ty_str:
                                    backed = is_cstr_backed_lowered(ctx, value_ir) or ast_expr_cstr_backed(ctx, value_ast)
                                _:
                                    pass
                        if backed:
                            ctx.cstr_backed_names.set(lb.value.c_name, true)
                        else:
                            let _removed = ctx.cstr_backed_names.remove(lb.value.c_name)
                    Option.none:
                        pass
            _:
                pass


## Build a dynamic format string: the host's
## `build_dynamic_format_string_temp_setup` — the interpolation temps first (in
## part order, their nested setups included), then the capacity local (seeded
## with the static text length), the per-interpolation length accumulations
## (`cap = cap + len(...)`), the result local (`mt_format_str_make`) and the
## write offset, then the append statements.  Returns the result temp's
## identifier; the caller hoists `output` and owns the release.
public function build_format_string_dynamic(ctx: ref[lowering.LoweringContext], parts: span[ast.FormatStringPart], output: ref[vec.Vec[ir.Stmt]]) -> ptr[ir.Expr]:
    let str_ty = types.Type.ty_str
    let ptr_uint_ty = types.primitive("ptr_uint")
    let base = format_string_result_base(ctx)
    let cap_name = strings.join_two(base, "_cap")
    let off_name = strings.join_two(base, "_off")
    let result_c = base

    # Pass 1: lower each interpolation into a typed temp.
    var static_len: ptr_uint = 0
    var temps = vec.Vec[str].create()
    var plans = vec.Vec[FormatPlan].create()
    var expected_lengths = vec.Vec[str].create()
    var pi: ptr_uint = 0
    while pi < parts.len:
        match unsafe: read(parts.data + pi):
            ast.FormatStringPart.fmt_text as t:
                static_len += t.value.len
            ast.FormatStringPart.fmt_expr as ex:
                let lowered = lowering.lower_expr(ctx, ex.expression)
                let val_ty = lowering.ir_expr_type(lowered)
                let plan = fmt_plan(ctx, val_ty, ex.format_spec)
                let temp_c = lowering.fresh_c_temp_name(ctx, "fmt_part")
                var temp_ty: types.Type = plan.arg_ty
                var temp_val: ptr[ir.Expr] = lowered
                if plan.len_kind == 1:
                    temp_ty = str_ty
                else if plan.len_kind == 3:
                    pass
                else if not types.type_equals(lowering.ir_expr_type(lowered), plan.arg_ty):
                    # The host's `cast_expression`: a cast is emitted only when
                    # the lowered value's type differs from the append
                    # argument's.
                    temp_val = lowering.alloc_expr(ir.Expr.expr_cast(target_type = plan.arg_ty, expression = lowered, ty = plan.arg_ty))
                output.push(ir.Stmt.stmt_local(name = temp_c, linkage_name = temp_c, ty = temp_ty, value = temp_val, line = 0, source_path = ""))
                temps.push(temp_c)
                plans.push(plan)
                if plan.len_kind == 3:
                    # The host's custom part computes its expected length into
                    # `__mt_fmt_part_len_N` at the temp, before the capacity
                    # accumulation.
                    let len_c = lowering.fresh_c_temp_name(ctx, "fmt_part_len")
                    let temp_ref = lowering.alloc_expr(ir.Expr.expr_name(name = temp_c, ty = temp_ty, pointer = Option[bool].some(value = false)))
                    var hook_args = vec.Vec[ir.Expr].create()
                    unsafe:
                        hook_args.push(read(temp_ref))
                    output.push(ir.Stmt.stmt_local(
                        name = len_c,
                        linkage_name = len_c,
                        ty = ptr_uint_ty,
                        value = lowering.alloc_expr(ir.Expr.expr_call(callee = plan.len_helper, arguments = hook_args.as_span(), ty = ptr_uint_ty)),
                        line = 0,
                        source_path = "",
                    ))
                    expected_lengths.push(len_c)
                else:
                    expected_lengths.push("")
            _:
                pass
        pi += 1

    # The capacity local (the static text's length), then one accumulation per
    # interpolation (the host writes `cap = cap + len(...)`).
    output.push(ir.Stmt.stmt_local(name = cap_name, linkage_name = cap_name, ty = ptr_uint_ty, value = lowering.alloc_expr(ir.Expr.expr_integer_literal(value = long<-static_len, ty = ptr_uint_ty)), line = 0, source_path = ""))
    var ai: ptr_uint = 0
    while ai < temps.len():
        let temp_c = temps.get(ai) else:
            fatal(c"format string: missing interpolation temp")
        let plan = plans.get(ai) else:
            fatal(c"format string: missing interpolation plan")
        var temp_ty: types.Type = unsafe: read(plan).arg_ty
        if unsafe: read(plan).len_kind == 1:
            temp_ty = str_ty
        let temp_ref = lowering.alloc_expr(ir.Expr.expr_name(name = unsafe: read(temp_c), ty = temp_ty, pointer = Option[bool].some(value = false)))
        var len_expr = fmt_len_expr(unsafe: read(plan), temp_ref, ptr_uint_ty)
        if unsafe: read(plan).len_kind == 3:
            let len_name_ptr = expected_lengths.get(ai) else:
                fatal(c"format string: missing custom length")
            len_expr = lowering.alloc_expr(ir.Expr.expr_name(name = unsafe: read(len_name_ptr), ty = ptr_uint_ty, pointer = Option[bool].some(value = false)))
        let cap_ref = lowering.alloc_expr(ir.Expr.expr_name(name = cap_name, ty = ptr_uint_ty, pointer = Option[bool].some(value = false)))
        output.push(ir.Stmt.stmt_assignment(
            target = lowering.alloc_expr(ir.Expr.expr_name(name = cap_name, ty = ptr_uint_ty, pointer = Option[bool].some(value = false))),
            operator = "=",
            value = lowering.alloc_expr(ir.Expr.expr_binary(operator = "+", left = cap_ref, right = len_expr, ty = ptr_uint_ty)),
        ))
        ai += 1

    # Allocate the result buffer and reset the write offset.
    var make_args = vec.Vec[ir.Expr].create()
    unsafe:
        make_args.push(read(lowering.alloc_expr(ir.Expr.expr_name(name = cap_name, ty = ptr_uint_ty, pointer = Option[bool].some(value = false)))))
    output.push(ir.Stmt.stmt_local(name = result_c, linkage_name = result_c, ty = str_ty, value = lowering.alloc_expr(ir.Expr.expr_call(callee = "mt_format_str_make", arguments = make_args.as_span(), ty = str_ty)), line = 0, source_path = ""))
    output.push(ir.Stmt.stmt_local(name = off_name, linkage_name = off_name, ty = ptr_uint_ty, value = lowering.alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = ptr_uint_ty)), line = 0, source_path = ""))

    # Pass 2: append each part in order.
    var expr_index: ptr_uint = 0
    pi = 0
    while pi < parts.len:
        match unsafe: read(parts.data + pi):
            ast.FormatStringPart.fmt_text as t:
                var append_args = vec.Vec[ir.Expr].create()
                unsafe:
                    append_args.push(read(lowering.alloc_expr(ir.Expr.expr_name(name = result_c, ty = str_ty, pointer = Option[bool].some(value = false)))))
                    append_args.push(read(lowering.alloc_expr(ir.Expr.expr_name(name = off_name, ty = ptr_uint_ty, pointer = Option[bool].some(value = false)))))
                    append_args.push(read(lowering.alloc_expr(ir.Expr.expr_string_literal(value = t.value, ty = str_ty, cstring = false))))
                output.push(ir.Stmt.stmt_assignment(target = lowering.alloc_expr(ir.Expr.expr_name(name = off_name, ty = ptr_uint_ty, pointer = Option[bool].some(value = false))), operator = "=", value = lowering.alloc_expr(ir.Expr.expr_call(callee = "mt_format_append_str", arguments = append_args.as_span(), ty = ptr_uint_ty))))
            ast.FormatStringPart.fmt_expr:
                let temp_ptr = temps.get(expr_index) else:
                    fatal(c"format string: missing interpolation temp")
                let plan_ptr = plans.get(expr_index) else:
                    fatal(c"format string: missing interpolation plan")
                let temp_c = unsafe: read(temp_ptr)
                let plan = unsafe: read(plan_ptr)
                expr_index += 1
                var temp_ty: types.Type = plan.arg_ty
                if plan.len_kind == 1:
                    temp_ty = str_ty
                if plan.len_kind == 3:
                    # Custom hook: the host's slice form — a `String` view over
                    # the result at `offset`, the hook call, the expected-length
                    # check, the offset advance and the NUL terminator.
                    let len_name_ptr = expected_lengths.get(expr_index - 1) else:
                        fatal(c"format string: missing custom length")
                    let part = FormatSinkPart(kind = 3, text = "", temp = temp_c, plan = plan, expected_length = unsafe: read(len_name_ptr))
                    let result_ref = lowering.alloc_expr(ir.Expr.expr_name(name = result_c, ty = str_ty, pointer = Option[bool].some(value = false)))
                    format_sink_buffer_part_stmts(ctx, output, part, result_ref, off_name)
                    pi += 1
                    continue
                var append_args = vec.Vec[ir.Expr].create()
                unsafe:
                    append_args.push(read(lowering.alloc_expr(ir.Expr.expr_name(name = result_c, ty = str_ty, pointer = Option[bool].some(value = false)))))
                    append_args.push(read(lowering.alloc_expr(ir.Expr.expr_name(name = off_name, ty = ptr_uint_ty, pointer = Option[bool].some(value = false)))))
                    append_args.push(read(lowering.alloc_expr(ir.Expr.expr_name(name = temp_c, ty = temp_ty, pointer = Option[bool].some(value = false)))))
                    if plan.len_kind == 2:
                        append_args.push(read(lowering.alloc_expr(ir.Expr.expr_integer_literal(value = long<-(plan.precision), ty = types.primitive("int")))))
                output.push(ir.Stmt.stmt_assignment(target = lowering.alloc_expr(ir.Expr.expr_name(name = off_name, ty = ptr_uint_ty, pointer = Option[bool].some(value = false))), operator = "=", value = lowering.alloc_expr(ir.Expr.expr_call(callee = plan.append_helper, arguments = append_args.as_span(), ty = ptr_uint_ty))))
        pi += 1

    return lowering.alloc_expr(ir.Expr.expr_name(name = result_c, ty = str_ty, pointer = Option[bool].some(value = false)))


## The length expression for one interpolation temp, per its plan's `len_kind`.
function fmt_len_expr(plan: FormatPlan, temp_ref: ptr[ir.Expr], ptr_uint_ty: types.Type) -> ptr[ir.Expr]:
    if plan.len_kind == 1:
        return lowering.alloc_expr(ir.Expr.expr_member(receiver = temp_ref, member = "len", ty = ptr_uint_ty))
    if plan.len_kind == 3:
        # Custom hook: `<Type>.format_len(value)` (by-value receiver).
        var hook_args = vec.Vec[ir.Expr].create()
        unsafe:
            hook_args.push(read(temp_ref))
        return lowering.alloc_expr(ir.Expr.expr_call(callee = plan.len_helper, arguments = hook_args.as_span(), ty = ptr_uint_ty))
    var args = vec.Vec[ir.Expr].create()
    unsafe:
        args.push(read(temp_ref))
    if plan.len_kind == 2:
        unsafe:
            args.push(read(lowering.alloc_expr(ir.Expr.expr_integer_literal(value = long<-(plan.precision), ty = types.primitive("int")))))
        return lowering.alloc_expr(ir.Expr.expr_call(callee = "mt_format_double_precision_len", arguments = args.as_span(), ty = ptr_uint_ty))
    return lowering.alloc_expr(ir.Expr.expr_call(callee = plan.len_helper, arguments = args.as_span(), ty = ptr_uint_ty))


# =============================================================================
#  Explicit format sinks (`String`/`str_buffer` append_format/assign_format)
#
#  The host streams a statement-form format string into its destination instead
#  of building a `str` and copying it (`lower_explicit_format_sink_expression_
#  statement`, lowering/expressions.rb:488).  Three forms are recognised:
#    - `std.fmt.append_format(ref, f"...")` / `assign_format`
#    - `String.append_format(f"...")` / `assign_format`
#    - `str_buffer[N].append_format(f"...")` / `assign_format`
#  The dynamic form emits the parts' temps, copies `str`/`cstr` arguments whose
#  buffer the sink may overwrite, then the destination-specific stream:
#  `std_string_String_append`/`std_fmt_append_*` for a String, or a single
#  `__mt_fmt_sink_offset_N` through a `str` view for a str_buffer.
# =============================================================================


## True when `t` is `std.string.String` (or a ref/pointer to it).
function is_std_string_type(t: types.Type) -> bool:
    var effective = t
    if types.is_ref_type(effective) or types.is_raw_pointer(effective):
        effective = types.pointer_element(effective)
    match effective:
        types.Type.ty_named as n:
            return n.name == "String" and n.module_name == "std.string"
        types.Type.ty_imported as im:
            return im.name == "String" and im.module_name == "std.string"
        _:
            return false


## A `String` sink method: the receiver may be a nominal `String` whose module
## name the analyzer did not qualify, so also accept the resolved method's
## `std_string_String_*` linkage (a user struct named `String` resolves to its
## own module prefix and is not treated as a sink).
function is_std_string_sink_method(ctx: ref[lowering.LoweringContext], receiver_ty: types.Type, method_name: str) -> bool:
    if is_std_string_type(receiver_ty):
        return true
    match lowering.resolve_method_info(ctx, receiver_ty, method_name):
        Option.some as mi:
            return mi.value.c_name.starts_with("std_string_String_")
        Option.none:
            return false


## The `data` member's type: the host's `str_buffer_storage_capacity` is `N + 1`.
public function str_buffer_data_member_type(cap: long) -> types.Type:
    return types.Type.ty_generic(name = "array", args = lowering.sp_type2(types.primitive("char"), types.literal_int(cap + 1)))


struct FormatSinkInfo:
    is_assign: bool
    is_buffer: bool
    sink_ep: ptr[ast.Expr]
    format_parts: span[ast.FormatStringPart]
    ## `String.append_format` passes its receiver through the editable-method
    ## borrow; `std.fmt.append_format` uses the declared `ref[String]` parameter.
    method_form: bool


variant FormatSinkTarget:
    fst_string(value: ptr[ir.Expr])
    fst_buffer(
        receiver: ptr[ir.Expr],
        data_pointer: ptr[ir.Expr],
        len_pointer: ptr[ir.Expr],
        dirty_pointer: ptr[ir.Expr],
        capacity: ptr[ir.Expr],
    )


struct FormatSinkPart:
    kind: int  # 0 text, 1 expression, 2 precision, 3 custom hook
    text: str
    temp: str
    plan: FormatPlan
    expected_length: str


## Recognise a statement-form explicit format sink (host
## `explicit_format_sink_call_info`).
function explicit_format_sink_info(ctx: ref[lowering.LoweringContext], ep: ptr[ast.Expr]) -> Option[FormatSinkInfo]:
    unsafe:
        match read(ep):
            ast.Expr.expr_call as call:
                match read(call.callee):
                    ast.Expr.expr_member_access as ma:
                        # `std.fmt.append_format(ref, f"...")` / `assign_format`.
                        if call.args.len == 2:
                            match read(ma.receiver):
                                ast.Expr.expr_identifier as id:
                                    let imp = ctx.analysis.imports.get(id.name)
                                    if imp != null and read(imp) == "std.fmt":
                                        if ma.member_name == "append_format" or ma.member_name == "assign_format":
                                            let fmt_arg = read(call.args.data + 1).arg_value
                                            match read(fmt_arg):
                                                ast.Expr.expr_format_string as fs:
                                                    return Option[FormatSinkInfo].some(value = FormatSinkInfo(
                                                        is_assign = ma.member_name == "assign_format",
                                                        is_buffer = false,
                                                        sink_ep = read(call.args.data + 0).arg_value,
                                                        format_parts = fs.parts,
                                                        method_form = false,
                                                    ))
                                                _:
                                                    pass
                                _:
                                    pass
                        # `String.append_format(f"...")` / `str_buffer[N].…`.
                        # Only the `*_format` methods are sinks; `.assign` and
                        # `.append` take a `str` and keep the ordinary path.
                        if call.args.len == 1 and (ma.member_name == "append_format" or ma.member_name == "assign_format"):
                            let fmt_arg = read(call.args.data + 0).arg_value
                            match read(fmt_arg):
                                ast.Expr.expr_format_string as fs:
                                    let recv_ty = lowering.method_receiver_type(ctx, ma.receiver)
                                    if lowering.is_str_buffer_type(recv_ty):
                                        return Option[FormatSinkInfo].some(value = FormatSinkInfo(
                                            is_assign = ma.member_name == "assign_format",
                                            is_buffer = true,
                                            sink_ep = ma.receiver,
                                            format_parts = fs.parts,
                                            method_form = false,
                                        ))
                                    if is_std_string_sink_method(ctx, recv_ty, ma.member_name):
                                        return Option[FormatSinkInfo].some(value = FormatSinkInfo(
                                            is_assign = ma.member_name == "assign_format",
                                            is_buffer = false,
                                            sink_ep = ma.receiver,
                                            format_parts = fs.parts,
                                            method_form = true,
                                        ))
                                _:
                                    pass
                    _:
                        pass
            _:
                pass
    return Option[FormatSinkInfo].none


## Lower the sink destination (host `explicit_format_sink_target`).
function lower_format_sink_target(ctx: ref[lowering.LoweringContext], info: FormatSinkInfo) -> FormatSinkTarget:
    let char_ty = types.primitive("char")
    let ptr_uint_ty = types.primitive("ptr_uint")
    let bool_ty = ctx.bool_ty
    let char_ptr_ty = types.Type.ty_generic(name = "ptr", args = lowering.sp_type(char_ty))
    let len_ptr_ty = types.Type.ty_generic(name = "ptr", args = lowering.sp_type(ptr_uint_ty))
    let dirty_ptr_ty = types.Type.ty_generic(name = "ptr", args = lowering.sp_type(bool_ty))
    if info.is_buffer:
        let recv = lowering.lower_expr(ctx, info.sink_ep)
        let recv_ty = lowering.ir_expr_type(recv)
        let cap = lowering.str_buffer_capacity_of(recv_ty)
        let data_member = lowering.alloc_expr(ir.Expr.expr_member(receiver = recv, member = "data", ty = str_buffer_data_member_type(cap)))
        let data_elem = lowering.alloc_expr(ir.Expr.expr_index(
            receiver = data_member,
            index = lowering.alloc_expr(ir.Expr.expr_integer_literal(value = 0z, ty = ptr_uint_ty)),
            ty = char_ty,
        ))
        let data_addr = lowering.alloc_expr(ir.Expr.expr_address_of(expression = data_elem, ty = char_ptr_ty))
        let len_addr = lowering.alloc_expr(ir.Expr.expr_address_of(
            expression = lowering.alloc_expr(ir.Expr.expr_member(receiver = recv, member = "len", ty = ptr_uint_ty)),
            ty = len_ptr_ty,
        ))
        let dirty_addr = lowering.alloc_expr(ir.Expr.expr_address_of(
            expression = lowering.alloc_expr(ir.Expr.expr_member(receiver = recv, member = "dirty", ty = bool_ty)),
            ty = dirty_ptr_ty,
        ))
        return FormatSinkTarget.fst_buffer(
            receiver = recv,
            data_pointer = data_addr,
            len_pointer = len_addr,
            dirty_pointer = dirty_addr,
            capacity = lowering.alloc_expr(ir.Expr.expr_integer_literal(value = cap, ty = ptr_uint_ty)),
        )
    let recv = lowering.lower_expr(ctx, info.sink_ep)
    var sink_value = recv
    if info.method_form:
        match lowering.build_receiver_arg(ctx, recv, ast.MethodKind.mk_editable, false):
            Option.some as arg:
                sink_value = arg.value
            Option.none:
                pass
    else:
        let fn_name = if info.is_assign: "assign_format" else: "append_format"
        sink_value = lowering.coerce_arg_to_ref_param(lowering.find_imported_fn_sig(ctx, "std.fmt", fn_name), 0, recv)
    return FormatSinkTarget.fst_string(value = sink_value)


## Lower every format part into a typed temp (the host's pass 1 in
## `build_dynamic_format_string_parts`).  Text parts carry their literal; an
## interpolation gets a `__mt_fmt_part_N` temp and a `FormatPlan`.  A custom
## hook also gets the host's `__mt_fmt_part_len_N` expected-length local.
function build_format_sink_parts(
    ctx: ref[lowering.LoweringContext],
    parts: span[ast.FormatStringPart],
    setup: ref[vec.Vec[ir.Stmt]],
) -> vec.Vec[FormatSinkPart]:
    var result_parts = vec.Vec[FormatSinkPart].create()
    let str_ty = types.Type.ty_str
    let ptr_uint_ty = types.primitive("ptr_uint")
    var pi: ptr_uint = 0
    while pi < parts.len:
        match unsafe: read(parts.data + pi):
            ast.FormatStringPart.fmt_text as t:
                if t.value.len > 0:
                    result_parts.push(FormatSinkPart(
                        kind = 0,
                        text = t.value,
                        temp = "",
                        plan = FormatPlan(append_helper = "", len_helper = "", arg_ty = types.Type.ty_error, len_kind = 0, precision = 0),
                        expected_length = "",
                    ))
            ast.FormatStringPart.fmt_expr as ex:
                let lowered = lowering.lower_expr(ctx, ex.expression)
                let val_ty = lowering.ir_expr_type(lowered)
                let plan = fmt_plan(ctx, val_ty, ex.format_spec)
                let temp_c = lowering.fresh_c_temp_name(ctx, "fmt_part")
                var temp_ty = plan.arg_ty
                var temp_val = lowered
                if plan.len_kind == 1:
                    temp_ty = str_ty
                else if plan.len_kind == 3:
                    pass
                else if not types.type_equals(lowering.ir_expr_type(lowered), plan.arg_ty):
                    temp_val = lowering.alloc_expr(ir.Expr.expr_cast(target_type = plan.arg_ty, expression = lowered, ty = plan.arg_ty))
                setup.push(ir.Stmt.stmt_local(name = temp_c, linkage_name = temp_c, ty = temp_ty, value = temp_val, line = 0, source_path = ""))
                var kind = 1
                if plan.len_kind == 2:
                    kind = 2
                else if plan.len_kind == 3:
                    kind = 3
                var expected_length = ""
                if plan.len_kind == 3:
                    let len_c = lowering.fresh_c_temp_name(ctx, "fmt_part_len")
                    let temp_ref = lowering.alloc_expr(ir.Expr.expr_name(name = temp_c, ty = temp_ty, pointer = Option[bool].some(value = false)))
                    var hook_args = vec.Vec[ir.Expr].create()
                    unsafe:
                        hook_args.push(read(temp_ref))
                    setup.push(ir.Stmt.stmt_local(
                        name = len_c,
                        linkage_name = len_c,
                        ty = ptr_uint_ty,
                        value = lowering.alloc_expr(ir.Expr.expr_call(callee = plan.len_helper, arguments = hook_args.as_span(), ty = ptr_uint_ty)),
                        line = 0,
                        source_path = "",
                    ))
                    expected_length = len_c
                result_parts.push(FormatSinkPart(kind = kind, text = "", temp = temp_c, plan = plan, expected_length = expected_length))
        pi += 1
    return result_parts


## Copy the parts whose buffer the sink may overwrite: a `str` argument for any
## sink, a `cstr` argument for a `str_buffer` sink (the host's
## `copy_explicit_format_sink_str_parts`).  Returns the rewritten parts.
function copy_format_sink_parts(
    ctx: ref[lowering.LoweringContext],
    parts: vec.Vec[FormatSinkPart],
    is_buffer: bool,
    setup: ref[vec.Vec[ir.Stmt]],
    cleanups: ref[vec.Vec[ir.Stmt]],
) -> vec.Vec[FormatSinkPart]:
    var copied = vec.Vec[FormatSinkPart].create()
    let str_ty = types.Type.ty_str
    let ptr_uint_ty = types.primitive("ptr_uint")
    let void_ty = types.primitive("void")
    var i: ptr_uint = 0
    while i < parts.len:
        let part_ptr = parts.get(i) else:
            break
        var part = unsafe: read(part_ptr)
        let is_str_part = part.kind == 1 and part.plan.append_helper == "mt_format_append_str"
        let is_cstr_part = part.kind == 1 and is_buffer and part.plan.append_helper == "mt_format_append_cstr"
        if is_str_part or is_cstr_part:
            let param_ty = if is_cstr_part: types.primitive("cstr") else: str_ty
            let param = lowering.alloc_expr(ir.Expr.expr_name(name = part.temp, ty = param_ty, pointer = Option[bool].some(value = false)))
            let copy_c = lowering.fresh_c_temp_name(ctx, "fmt_sink_str")
            let copy_ref = lowering.alloc_expr(ir.Expr.expr_name(name = copy_c, ty = str_ty, pointer = Option[bool].some(value = false)))
            ctx.cstr_backed_names.set(copy_c, true)
            var len_expr = lowering.alloc_expr(ir.Expr.expr_member(receiver = param, member = "len", ty = ptr_uint_ty))
            if is_cstr_part:
                var len_args = vec.Vec[ir.Expr].create()
                unsafe:
                    len_args.push(read(param))
                len_expr = lowering.alloc_expr(ir.Expr.expr_call(callee = "mt_format_cstr_len", arguments = len_args.as_span(), ty = ptr_uint_ty))
            var make_args = vec.Vec[ir.Expr].create()
            unsafe:
                make_args.push(read(len_expr))
            setup.push(ir.Stmt.stmt_local(
                name = copy_c,
                linkage_name = copy_c,
                ty = str_ty,
                value = lowering.alloc_expr(ir.Expr.expr_call(callee = "mt_format_str_make", arguments = make_args.as_span(), ty = str_ty)),
                line = 0,
                source_path = "",
            ))
            let append_callee = if is_cstr_part: "mt_format_append_cstr" else: "mt_format_append_str"
            setup.push(ir.Stmt.stmt_expression(
                expression = lowering.alloc_expr(ir.Expr.expr_call(
                    callee = append_callee,
                    arguments = lowering.sp_expr3(copy_ref, lowering.alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = ptr_uint_ty)), param),
                    ty = ptr_uint_ty,
                )),
                line = 0,
                source_path = "",
            ))
            var release_args = vec.Vec[ir.Expr].create()
            unsafe:
                release_args.push(read(copy_ref))
            cleanups.push(ir.Stmt.stmt_expression(
                expression = lowering.alloc_expr(ir.Expr.expr_call(callee = "mt_format_str_release", arguments = release_args.as_span(), ty = void_ty)),
                line = 0,
                source_path = "",
            ))
            part.temp = copy_c
            part.plan = FormatPlan(append_helper = "mt_format_append_str", len_helper = part.plan.len_helper, arg_ty = str_ty, len_kind = 1, precision = 0)
        copied.push(part)
        i += 1
    return copied


## The `std.fmt` append callee for a plan: `append` uses the String method,
## `append_cstr` the cstr helper, everything else `std_fmt_<helper>`.
function format_sink_string_callee(helper: str) -> str:
    if helper == "mt_format_append_str":
        return "std_string_String_append"
    if helper == "mt_format_append_cstr":
        return "std_fmt_append_cstr"
    let prefix = "mt_format_"
    return strings.join_two("std_fmt_", helper.slice(prefix.len, helper.len - prefix.len))


## One String-sink append call (host `explicit_format_sink_append_call`).
function format_sink_string_append_call(part: FormatSinkPart, sink_value: ptr[ir.Expr]) -> ptr[ir.Expr]:
    let void_ty = types.primitive("void")
    let int_ty = types.primitive("int")
    if part.kind == 0:
        return lowering.alloc_expr(ir.Expr.expr_call(
            callee = "std_string_String_append",
            arguments = lowering.sp_expr2(sink_value, lowering.alloc_expr(ir.Expr.expr_string_literal(value = part.text, ty = types.Type.ty_str, cstring = false))),
            ty = void_ty,
        ))
    let temp_ref = lowering.alloc_expr(ir.Expr.expr_name(name = part.temp, ty = part.plan.arg_ty, pointer = Option[bool].some(value = false)))
    if part.kind == 2:
        return lowering.alloc_expr(ir.Expr.expr_call(
            callee = "std_fmt_append_double_precision",
            arguments = lowering.sp_expr3(sink_value, temp_ref, lowering.alloc_expr(ir.Expr.expr_integer_literal(value = long<-(part.plan.precision), ty = int_ty))),
            ty = void_ty,
        ))
    if part.kind == 3:
        return lowering.alloc_expr(ir.Expr.expr_call(callee = part.plan.append_helper, arguments = lowering.sp_expr2(temp_ref, sink_value), ty = void_ty))
    return lowering.alloc_expr(ir.Expr.expr_call(callee = format_sink_string_callee(part.plan.append_helper), arguments = lowering.sp_expr2(sink_value, temp_ref), ty = void_ty))


## Append one part into a str_buffer sink through the `str` view `{data, len=cap}`,
## advancing `offset_name` (host `format_string_part_append_statements`).
function format_sink_buffer_part_stmts(
    ctx: ref[lowering.LoweringContext],
    stmts: ref[vec.Vec[ir.Stmt]],
    part: FormatSinkPart,
    view: ptr[ir.Expr],
    offset_name: str,
) -> void:
    let ptr_uint_ty = types.primitive("ptr_uint")
    let char_ty = types.primitive("char")
    let void_ty = types.primitive("void")
    let int_ty = types.primitive("int")
    let offset_ref = lowering.alloc_expr(ir.Expr.expr_name(name = offset_name, ty = ptr_uint_ty, pointer = Option[bool].some(value = false)))
    if part.kind == 0:
        var args = vec.Vec[ir.Expr].create()
        unsafe:
            args.push(read(view))
            args.push(read(offset_ref))
            args.push(read(lowering.alloc_expr(ir.Expr.expr_string_literal(value = part.text, ty = types.Type.ty_str, cstring = false))))
        stmts.push(ir.Stmt.stmt_assignment(
            target = offset_ref,
            operator = "=",
            value = lowering.alloc_expr(ir.Expr.expr_call(callee = "mt_format_append_str", arguments = args.as_span(), ty = ptr_uint_ty)),
        ))
        return
    let temp_ref = lowering.alloc_expr(ir.Expr.expr_name(name = part.temp, ty = part.plan.arg_ty, pointer = Option[bool].some(value = false)))
    if part.kind == 2:
        var prec_args = vec.Vec[ir.Expr].create()
        unsafe:
            prec_args.push(read(view))
            prec_args.push(read(offset_ref))
            prec_args.push(read(temp_ref))
            prec_args.push(read(lowering.alloc_expr(ir.Expr.expr_integer_literal(value = long<-(part.plan.precision), ty = int_ty))))
        stmts.push(ir.Stmt.stmt_assignment(
            target = offset_ref,
            operator = "=",
            value = lowering.alloc_expr(ir.Expr.expr_call(callee = "mt_format_append_double_precision", arguments = prec_args.as_span(), ty = ptr_uint_ty)),
        ))
        return
    if part.kind == 3:
        # The host's custom-hook slice: build a `String` view over the buffer at
        # `view.data + offset`, call `<Type>.append_format(value, &out)`, verify
        # the hook wrote exactly the expected length, advance the offset and
        # NUL-terminate.
        let string_ty = types.Type.ty_imported(module_name = "std.string", name = "String", args = span[types.Type]())
        let ref_string_ty = types.Type.ty_generic(name = "ref", args = lowering.sp_type(string_ty))
        let ubyte_ptr_ty = types.Type.ty_generic(name = "ptr", args = lowering.sp_type(types.primitive("ubyte")))
        let data_field_ty = types.Type.ty_nullable(base = types.alloc_type(ubyte_ptr_ty))
        let char_ptr_ty = types.Type.ty_generic(name = "ptr", args = lowering.sp_type(char_ty))
        let view_data = lowering.alloc_expr(ir.Expr.expr_member(receiver = view, member = "data", ty = char_ptr_ty))
        let slice_sum = lowering.alloc_expr(ir.Expr.expr_binary(operator = "+", left = view_data, right = offset_ref, ty = char_ptr_ty))
        let slice_data = lowering.alloc_expr(ir.Expr.expr_cast(target_type = data_field_ty, expression = slice_sum, ty = data_field_ty))
        let output_name = lowering.fresh_c_temp_name(ctx, "fmt_part_output")
        let output_value = lowering.alloc_expr(ir.Expr.expr_name(name = output_name, ty = string_ty, pointer = Option[bool].some(value = false)))
        let expected_length = lowering.alloc_expr(ir.Expr.expr_name(name = part.expected_length, ty = ptr_uint_ty, pointer = Option[bool].some(value = false)))
        var fields = vec.Vec[ir.AggregateField].create()
        fields.push(ir.AggregateField(name = "data", value = slice_data))
        fields.push(ir.AggregateField(name = "len", value = lowering.alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = ptr_uint_ty))))
        fields.push(ir.AggregateField(name = "capacity", value = expected_length))
        fields.push(ir.AggregateField(name = "owns_storage", value = lowering.alloc_expr(ir.Expr.expr_boolean_literal(value = false, ty = ctx.bool_ty))))
        stmts.push(ir.Stmt.stmt_local(
            name = output_name,
            linkage_name = output_name,
            ty = string_ty,
            value = lowering.alloc_expr(ir.Expr.expr_aggregate_literal(ty = string_ty, fields = fields.as_span())),
            line = 0,
            source_path = "",
        ))
        var hook_args = vec.Vec[ir.Expr].create()
        unsafe:
            hook_args.push(read(temp_ref))
            hook_args.push(read(lowering.alloc_expr(ir.Expr.expr_address_of(expression = output_value, ty = ref_string_ty))))
        stmts.push(ir.Stmt.stmt_expression(
            expression = lowering.alloc_expr(ir.Expr.expr_call(callee = part.plan.append_helper, arguments = hook_args.as_span(), ty = void_ty)),
            line = 0,
            source_path = "",
        ))
        let output_len = lowering.alloc_expr(ir.Expr.expr_member(receiver = output_value, member = "len", ty = ptr_uint_ty))
        var fatal_args = vec.Vec[ir.Expr].create()
        unsafe:
            fatal_args.push(read(lowering.alloc_expr(ir.Expr.expr_string_literal(value = "custom format hook length mismatch", ty = types.primitive("cstr"), cstring = true))))
        var then_body = vec.Vec[ir.Stmt].create()
        then_body.push(ir.Stmt.stmt_expression(
            expression = lowering.alloc_expr(ir.Expr.expr_call(callee = "mt_fatal", arguments = fatal_args.as_span(), ty = void_ty)),
            line = 0,
            source_path = "",
        ))
        stmts.push(ir.Stmt.stmt_if(
            condition = lowering.alloc_expr(ir.Expr.expr_binary(operator = "!=", left = output_len, right = expected_length, ty = ctx.bool_ty)),
            then_body = then_body.as_span(),
            else_body = Option[span[ir.Stmt]].none,
        ))
        let offset_next = lowering.alloc_expr(ir.Expr.expr_binary(operator = "+", left = offset_ref, right = output_len, ty = ptr_uint_ty))
        stmts.push(ir.Stmt.stmt_assignment(target = offset_ref, operator = "=", value = offset_next))
        stmts.push(ir.Stmt.stmt_assignment(
            target = lowering.alloc_expr(ir.Expr.expr_index(receiver = view_data, index = offset_ref, ty = char_ty)),
            operator = "=",
            value = lowering.alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = char_ty)),
        ))
        return
    var args = vec.Vec[ir.Expr].create()
    unsafe:
        args.push(read(view))
        args.push(read(offset_ref))
        args.push(read(temp_ref))
    stmts.push(ir.Stmt.stmt_assignment(
        target = offset_ref,
        operator = "=",
        value = lowering.alloc_expr(ir.Expr.expr_call(callee = part.plan.append_helper, arguments = args.as_span(), ty = ptr_uint_ty)),
    ))


## The static-format sink call (host `explicit_format_sink_runtime_call`).
function explicit_format_sink_runtime_call(
    ctx: ref[lowering.LoweringContext],
    is_assign: bool,
    target: FormatSinkTarget,
    text_value: ptr[ir.Expr],
) -> ptr[ir.Expr]:
    let void_ty = types.primitive("void")
    match target:
        FormatSinkTarget.fst_buffer as buf:
            let callee = if is_assign: "mt_str_buffer_assign" else: "mt_str_buffer_append"
            var args = vec.Vec[ir.Expr].create()
            unsafe:
                args.push(read(text_value))
                args.push(read(buf.data_pointer))
                args.push(read(buf.capacity))
                args.push(read(buf.len_pointer))
                args.push(read(buf.dirty_pointer))
            return lowering.alloc_expr(ir.Expr.expr_call(callee = callee, arguments = args.as_span(), ty = void_ty))
        FormatSinkTarget.fst_string as s:
            let callee = if is_assign: "std_string_String_assign" else: "std_string_String_append"
            return lowering.alloc_expr(ir.Expr.expr_call(callee = callee, arguments = lowering.sp_expr2(s.value, text_value), ty = void_ty))


## Emit the dynamic sink stream (host `lower_explicit_format_sink_expression_
## statement`'s non-static branch).
function emit_format_sink_dynamic(
    ctx: ref[lowering.LoweringContext],
    stmts: ref[vec.Vec[ir.Stmt]],
    info: FormatSinkInfo,
    target: FormatSinkTarget,
    parts: vec.Vec[FormatSinkPart],
    line: ptr_uint,
    path: str,
) -> void:
    let ptr_uint_ty = types.primitive("ptr_uint")
    if not info.is_buffer:
        match target:
            FormatSinkTarget.fst_string as s:
                if info.is_assign:
                    stmts.push(ir.Stmt.stmt_expression(
                        expression = lowering.alloc_expr(ir.Expr.expr_call(callee = "std_string_String_clear", arguments = lowering.single_expr_span(s.value), ty = types.primitive("void"))),
                        line = line,
                        source_path = path,
                    ))
                var i: ptr_uint = 0
                while i < parts.len:
                    let part_ptr = parts.get(i) else:
                        break
                    stmts.push(ir.Stmt.stmt_expression(
                        expression = format_sink_string_append_call(unsafe: read(part_ptr), s.value),
                        line = line,
                        source_path = path,
                    ))
                    i += 1
            _:
                pass
        return
    match target:
        FormatSinkTarget.fst_buffer as buf:
            if info.is_assign:
                var clear_args = vec.Vec[ir.Expr].create()
                unsafe:
                    clear_args.push(read(buf.data_pointer))
                    clear_args.push(read(buf.capacity))
                    clear_args.push(read(buf.len_pointer))
                    clear_args.push(read(buf.dirty_pointer))
                stmts.push(ir.Stmt.stmt_expression(
                    expression = lowering.alloc_expr(ir.Expr.expr_call(callee = "mt_str_buffer_clear", arguments = clear_args.as_span(), ty = types.primitive("void"))),
                    line = line,
                    source_path = path,
                ))
            let offset_name = lowering.fresh_c_temp_name(ctx, "fmt_sink_offset")
            var offset_init: ptr[ir.Expr] = lowering.alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = ptr_uint_ty))
            if not info.is_assign:
                var len_args = vec.Vec[ir.Expr].create()
                unsafe:
                    len_args.push(read(buf.data_pointer))
                    len_args.push(read(buf.capacity))
                    len_args.push(read(buf.len_pointer))
                    len_args.push(read(buf.dirty_pointer))
                offset_init = lowering.alloc_expr(ir.Expr.expr_call(callee = "mt_str_buffer_len", arguments = len_args.as_span(), ty = ptr_uint_ty))
            stmts.push(ir.Stmt.stmt_local(name = offset_name, linkage_name = offset_name, ty = ptr_uint_ty, value = offset_init, line = 0, source_path = ""))
            var view_fields = vec.Vec[ir.AggregateField].create()
            view_fields.push(ir.AggregateField(name = "data", value = buf.data_pointer))
            view_fields.push(ir.AggregateField(name = "len", value = buf.capacity))
            let view = lowering.alloc_expr(ir.Expr.expr_aggregate_literal(ty = types.Type.ty_str, fields = view_fields.as_span()))
            var i: ptr_uint = 0
            while i < parts.len:
                let part_ptr = parts.get(i) else:
                    break
                format_sink_buffer_part_stmts(ctx, stmts, unsafe: read(part_ptr), view, offset_name)
                i += 1
            stmts.push(ir.Stmt.stmt_assignment(
                target = lowering.alloc_expr(ir.Expr.expr_unary(
                    operator = "*",
                    operand = buf.len_pointer,
                    ty = ptr_uint_ty,
                )),
                operator = "=",
                value = lowering.alloc_expr(ir.Expr.expr_name(name = offset_name, ty = ptr_uint_ty, pointer = Option[bool].some(value = false))),
            ))
        _:
            pass


## Lower a statement-form explicit format sink.  Returns false when the
## expression is not a sink, so the ordinary expression-statement path runs.
public function lower_explicit_format_sink_stmt(
    ctx: ref[lowering.LoweringContext],
    output: ref[vec.Vec[ir.Stmt]],
    ep: ptr[ast.Expr],
    line: ptr_uint,
) -> bool:
    let info = explicit_format_sink_info(ctx, ep) else:
        return false
    let base = output.len()
    let saved = lowering.begin_stmt_setup(ctx, lowering.HoistMode.hm_value)
    ctx.hoist_root_ep = ep
    let sink_cleanup_start = ctx.hoist_cleanups.len
    let target = lower_format_sink_target(ctx, info)
    let sink_cleanup_end = ctx.hoist_cleanups.len
    if format_string_all_static(info.format_parts):
        let text = format_string_static_literal(info.format_parts)
        ctx.hoist_stmts.push(ir.Stmt.stmt_expression(
            expression = explicit_format_sink_runtime_call(ctx, info.is_assign, target, text),
            line = line,
            source_path = ctx.analysis.source_path,
        ))
    else:
        var parts = build_format_sink_parts(ctx, info.format_parts, ref_of(ctx.hoist_stmts))
        let part_cleanup_end = ctx.hoist_cleanups.len
        var copy_cleanups = vec.Vec[ir.Stmt].create()
        let copied = copy_format_sink_parts(ctx, parts, info.is_buffer, ref_of(ctx.hoist_stmts), ref_of(copy_cleanups))
        emit_format_sink_dynamic(ctx, ref_of(ctx.hoist_stmts), info, target, copied, line, ctx.analysis.source_path)
        let collected = lowering.collect_stmt_setup(ctx, saved)
        lowering.emit_hoist_setup(output, base, collected)
        var ci: ptr_uint = 0
        while ci < copy_cleanups.len:
            let stmt = copy_cleanups.get(ci) else:
                break
            output.push(unsafe: read(stmt))
            ci += 1
        ci = sink_cleanup_start
        while ci < sink_cleanup_end:
            let stmt = collected.cleanups.get(ci) else:
                break
            output.push(unsafe: read(stmt))
            ci += 1
        ci = part_cleanup_end
        while ci < collected.cleanups.len:
            let stmt = collected.cleanups.get(ci) else:
                break
            output.push(unsafe: read(stmt))
            ci += 1
        return true
    let collected = lowering.collect_stmt_setup(ctx, saved)
    lowering.emit_hoist_setup(output, base, collected)
    var ci: ptr_uint = 0
    while ci < collected.cleanups.len:
        let stmt = collected.cleanups.get(ci) else:
            break
        output.push(unsafe: read(stmt))
        ci += 1
    return true





## Map a type to its format-length helper name.
function fmt_len_helper_name(expr: ptr[ir.Expr]) -> str:
    return "mt_format_int_len"


## Map a type to its format-append helper name.
function fmt_append_helper_name(expr: ptr[ir.Expr]) -> str:
    let t = lowering.ir_expr_type(expr)
    if types.is_integer_type(t):
        return "mt_format_append_int"
    match t:
        types.Type.ty_str:
            return "mt_format_append_str"
        _:
            return "mt_format_append_int"
