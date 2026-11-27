## Call-argument canonicalization, extracted from semantic/analyzer.mt.

import std.map as map_mod
import std.mem.heap as heap
import std.string as string
import std.vec as vec

import mtc.parser.ast as ast
import mtc.semantic.analyzer as analyzer
import mtc.semantic.scope as sscope
import mtc.semantic.types as types


public function canonicalize_call_arguments_for(
    ctx: ref[analyzer.Context],
    display_name: str,
    sig: analyzer.FnSig,
    args: span[ast.Argument],
    line: ptr_uint,
    column: ptr_uint,
    dest: ref[vec.Vec[ast.Argument]],
) -> void:
    var slots = vec.Vec[ast.Argument].create()
    defer: slots.release()
    var filled = vec.Vec[bool].create()
    defer: filled.release()
    var pi: ptr_uint = 0
    while pi < sig.params.len:
        slots.push(zero[ast.Argument])
        filled.push(false)
        pi += 1

    var named_seen = false
    var i: ptr_uint = 0
    while i < args.len:
        var arg: ast.Argument
        unsafe:
            arg = read(args.data + i)
        match arg.arg_name:
            Option.some as nm:
                named_seen = true
                var found = false
                var duplicate = false
                var pj: ptr_uint = 0
                while pj < sig.params.len:
                    if unsafe: read(sig.params.data + pj).name == nm.value:
                        found = true
                        let slot_ptr = slots.get(pj)
                        if slot_ptr != null:
                            unsafe:
                                match read(ptr[ast.Argument]<-slot_ptr).arg_name:
                                    Option.some as existing:
                                        if existing.value == nm.value:
                                            duplicate = true
                                    Option.none:
                                        pass
                        if duplicate:
                            analyzer.report(ctx, line, column, duplicate_named_argument_message(nm.value, display_name))
                        else:
                            unsafe:
                                read(ptr[ast.Argument]<-slot_ptr) = arg
                            let fptr = filled.get(pj)
                            if fptr != null:
                                unsafe:
                                    read(fptr) = true
                        break
                    pj += 1
                if not found:
                    analyzer.report(ctx, line, column, unknown_parameter_message(nm.value, display_name))
            Option.none:
                if named_seen:
                    analyzer.report(ctx, line, column, positional_after_named_message(display_name))
                var placed = false
                var pj: ptr_uint = 0
                while pj < sig.params.len:
                    if not bool_slot(ref_of(filled), pj):
                        let slot_ptr = slots.get(pj)
                        if slot_ptr != null:
                            unsafe:
                                read(ptr[ast.Argument]<-slot_ptr) = ast.Argument(
                                    arg_name = Option[str].none,
                                    arg_value = arg.arg_value
                                )
                        let fptr = filled.get(pj)
                        if fptr != null:
                            unsafe:
                                read(fptr) = true
                        placed = true
                        break
                    pj += 1
                if not placed:
                    analyzer.report(ctx, line, column, analyzer.arity_message(display_name, sig.params.len, args.len))
        i += 1

    # Omitted defaulted parameters keep their slot; the lowering fills the real
    # default expression, while analysis only needs an error placeholder whose
    # type is permissive.
    var error_expr = heap.must_alloc[ast.Expr](1)
    unsafe:
        read(error_expr) = ast.Expr.expr_error(line = 0, column = 0, message = "")
    var result = vec.Vec[ast.Argument].create()
    pi = 0
    while pi < sig.params.len:
        if bool_slot(ref_of(filled), pi):
            let slot_ptr = slots.get(pi)
            if slot_ptr != null:
                unsafe:
                    let slot_arg = read(ptr[ast.Argument]<-slot_ptr)
                    result.push(ast.Argument(arg_name = Option[str].none, arg_value = slot_arg.arg_value))
        else if pi >= sig.required_count:
            result.push(ast.Argument(arg_name = Option[str].none, arg_value = error_expr))
        pi += 1
    read(dest) = result


function bool_slot(values: ref[vec.Vec[bool]], index: ptr_uint) -> bool:
    let ptr_value = values.get(index)
    if ptr_value == null:
        return false
    return unsafe: read(ptr_value)


function duplicate_named_argument_message(name: str, display_name: str) -> str:
    var buf = string.String.create()
    buf.append("duplicate named argument '")
    buf.append(name)
    buf.append("' in call to ")
    buf.append(display_name)
    return buf.as_str()


function unknown_parameter_message(name: str, display_name: str) -> str:
    var buf = string.String.create()
    buf.append("unknown parameter '")
    buf.append(name)
    buf.append("' for ")
    buf.append(display_name)
    return buf.as_str()


function positional_after_named_message(display_name: str) -> str:
    var buf = string.String.create()
    buf.append("positional argument after named argument in call to ")
    buf.append(display_name)
    return buf.as_str()

## Per-argument expected types for a call, resolved before any argument is
## inferred.  The host infers each positional argument with
## `expected_type: parameter.type`; an argument whose parameter is not
## statically known is inferred with no hint, never with the enclosing
## expression's hint (a `return f(...)` must not force `f`'s arguments to the
## function's return type).  An empty result means "no parameter is known".
public function call_argument_expected_types(
    ctx: ref[analyzer.Context],
    scope: ref[sscope.Scope],
    callee: ptr[ast.Expr],
    args: span[ast.Argument]
) -> vec.Vec[types.Type]:
    # Named arguments are canonicalized to parameter order in the host; the self
    # infers them in source order, so a positional hint could name the wrong
    # parameter.  Constructors are the named-argument path that matters, and
    # `check_construction` sets each field's hint by name itself.
    var named_scan: ptr_uint = 0
    while named_scan < args.len:
        unsafe:
            match read(args.data + named_scan).arg_name:
                Option.some:
                    return vec.Vec[types.Type].create()
                Option.none:
                    pass
        named_scan += 1
    unsafe:
        match read(callee):
            ast.Expr.expr_identifier as id:
                if analyzer.is_builtin_call_name(id.name) or analyzer.is_callable_builtin_name(id.name) or analyzer.scope_get(
                    scope,
                    id.name
                ) != null:
                    return vec.Vec[types.Type].create()
                let sigp = ctx.functions.get(id.name)
                if sigp != null:
                    return expected_from_params(read(sigp).params, args.len)
                let fieldsp = ctx.structs.get(id.name)
                if fieldsp != null:
                    return expected_from_fields(read(fieldsp), args)
                return vec.Vec[types.Type].create()
            ast.Expr.expr_member_access as ma:
                match read(ma.receiver):
                    ast.Expr.expr_identifier as rid:
                        if analyzer.scope_get(scope, rid.name) == null and ctx.import_aliases.contains(rid.name):
                            let module_name_ptr = ctx.import_aliases.get(rid.name) else:
                                return vec.Vec[types.Type].create()
                            let binding_ptr = analyzer.find_binding(ctx, read(module_name_ptr)) else:
                                return vec.Vec[types.Type].create()
                            let sig_ptr = read(binding_ptr).functions.get(ma.member_name)
                            if sig_ptr != null:
                                return expected_from_params(read(sig_ptr).params, args.len)
                            let fields_ptr = read(binding_ptr).structs.get(ma.member_name)
                            if fields_ptr != null:
                                return expected_from_fields(read(fields_ptr), args)
                            return vec.Vec[types.Type].create()
                    _:
                        pass
                # A static struct method (`Counter.make(...)`,
                # `lib.Adder.make(...)`).
                match analyzer.static_struct_receiver_type(ctx, scope, ma.receiver):
                    Option.some as rt:
                        return expected_from_method(ctx, rt.value, ma.member_name, args)
                    Option.none:
                        pass
                # A value-receiver method on a bare local or `this`: the
                # receiver's declared type is in scope, so resolving the
                # signature needs no inference.
                match read(ma.receiver):
                    ast.Expr.expr_identifier as rid:
                        let rtp = analyzer.scope_get(scope, rid.name) else:
                            return vec.Vec[types.Type].create()
                        return expected_from_method(ctx, analyzer.unwrap_ref(unsafe: read(rtp)), ma.member_name, args)
                    _:
                        return vec.Vec[types.Type].create()
            ast.Expr.expr_specialization as spec:
                match read(spec.callee):
                    ast.Expr.expr_identifier as id:
                        if analyzer.scope_get(scope, id.name) != null:
                            return vec.Vec[types.Type].create()
                        # Builtin vector/array constructions type every
                        # positional argument at the element type.
                        if id.name.equal("simd") or id.name.equal("array"):
                            if spec.arguments.len >= 1:
                                match analyzer.quiet_explicit_type(ctx, read(spec.arguments.data + 0).value):
                                    Option.some as elem:
                                        return expected_repeated(elem.value, args.len)
                                    Option.none:
                                        return vec.Vec[types.Type].create()
                            return vec.Vec[types.Type].create()
                        let tps_ptr = ctx.function_type_params.get(id.name) else:
                            return vec.Vec[types.Type].create()
                        let sigp = ctx.functions.get(id.name) else:
                            return vec.Vec[types.Type].create()
                        var subs = map_mod.Map[str, types.Type].create()
                        defer: subs.release()
                        if not analyzer.try_quiet_type_substitutions(ctx, read(tps_ptr), spec.arguments, ref_of(subs)):
                            return vec.Vec[types.Type].create()
                        return expected_from_substituted_params(read(sigp).params, args.len, ref_of(subs))
                    ast.Expr.expr_member_access as ma:
                        match read(ma.receiver):
                            ast.Expr.expr_identifier as rid:
                                if analyzer.scope_get(scope, rid.name) == null and ctx.import_aliases.contains(rid.name):
                                    let module_name_ptr = ctx.import_aliases.get(rid.name) else:
                                        return vec.Vec[types.Type].create()
                                    let binding_ptr = analyzer.find_binding(ctx, read(module_name_ptr)) else:
                                        return vec.Vec[types.Type].create()
                                    let tps_ptr = read(binding_ptr).function_type_params.get(ma.member_name) else:
                                        return vec.Vec[types.Type].create()
                                    let sig_ptr = read(binding_ptr).functions.get(ma.member_name) else:
                                        return vec.Vec[types.Type].create()
                                    var subs = map_mod.Map[str, types.Type].create()
                                    defer: subs.release()
                                    if not analyzer.try_quiet_type_substitutions(
                                        ctx,
                                        read(tps_ptr),
                                        spec.arguments,
                                        ref_of(subs)
                                    ):
                                        return vec.Vec[types.Type].create()
                                    return expected_from_substituted_params(
                                        read(sig_ptr).params,
                                        args.len,
                                        ref_of(subs)
                                    )
                                let rtp = analyzer.scope_get(scope, rid.name) else:
                                    return vec.Vec[types.Type].create()
                                let recv_ty = analyzer.unwrap_ref(unsafe: read(rtp))
                                let mtps = analyzer.method_type_params_of(ctx, recv_ty, ma.member_name) else:
                                    return vec.Vec[types.Type].create()
                                let sig = analyzer.resolve_method_sig(ctx, recv_ty, ma.member_name) else:
                                    return vec.Vec[types.Type].create()
                                var subs = map_mod.Map[str, types.Type].create()
                                defer: subs.release()
                                if not analyzer.try_quiet_type_substitutions(ctx, mtps, spec.arguments, ref_of(subs)):
                                    return vec.Vec[types.Type].create()
                                return expected_from_substituted_params(sig.params, args.len, ref_of(subs))
                            _:
                                return vec.Vec[types.Type].create()
                    _:
                        return vec.Vec[types.Type].create()
            _:
                return vec.Vec[types.Type].create()


## The expected type of each named constructor argument (`Counter(value = 3)`),
## keyed by field name; positional arguments have no hint.
function expected_from_fields(fields: span[analyzer.FieldEntry], args: span[ast.Argument]) -> vec.Vec[types.Type]:
    var hints = vec.Vec[types.Type].create()
    var i: ptr_uint = 0
    while i < args.len:
        var hint = types.Type.ty_error
        unsafe:
            match read(args.data + i).arg_name:
                Option.some as nm:
                    let ftp = analyzer.field_type(fields, nm.value)
                    if ftp != null:
                        let ft = read(ftp)
                        if not types.contains_error(ft) and not types.contains_type_var(ft):
                            hint = ft
                Option.none:
                    pass
        hints.push(hint)
        i += 1
    return hints


function expected_from_method(
    ctx: ref[analyzer.Context],
    receiver_type: types.Type,
    method_name: str,
    args: span[ast.Argument]
) -> vec.Vec[types.Type]:
    match analyzer.resolve_method_sig(ctx, receiver_type, method_name):
        Option.some as sig:
            return expected_from_params(sig.value.params, args.len)
        Option.none:
            return vec.Vec[types.Type].create()


## One expected type per positional parameter.  A parameter carrying a type
## variable (a generic function or extending block) has no statically-known
## type, so its argument is inferred with no hint.
function expected_from_params(params: span[analyzer.ParamEntry], arg_count: ptr_uint) -> vec.Vec[types.Type]:
    var hints = vec.Vec[types.Type].create()
    var i: ptr_uint = 0
    while i < arg_count:
        if i < params.len:
            let pty = unsafe: read(params.data + i).ty
            if types.contains_error(pty) or types.contains_type_var(pty):
                hints.push(types.Type.ty_error)
            else:
                hints.push(pty)
        else:
            hints.push(types.Type.ty_error)
        i += 1
    return hints


## As `expected_from_params`, with the explicit specialization's substitutions
## applied first.
function expected_from_substituted_params(
    params: span[analyzer.ParamEntry],
    arg_count: ptr_uint,
    subs: ref[map_mod.Map[str, types.Type]]
) -> vec.Vec[types.Type]:
    var hints = vec.Vec[types.Type].create()
    var i: ptr_uint = 0
    while i < arg_count:
        var hint = types.Type.ty_error
        if i < params.len:
            let pty = analyzer.substitute_type(unsafe: read(params.data + i).ty, subs)
            if not types.contains_error(pty) and not types.contains_type_var(pty):
                hint = pty
        hints.push(hint)
        i += 1
    return hints


## The same hint for every positional argument (`simd[E, N](…)` / `array[E, N](…)`).
function expected_repeated(ty: types.Type, arg_count: ptr_uint) -> vec.Vec[types.Type]:
    var hints = vec.Vec[types.Type].create()
    var i: ptr_uint = 0
    while i < arg_count:
        hints.push(ty)
        i += 1
    return hints
