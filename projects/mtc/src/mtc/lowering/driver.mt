## Whole-program lowering driver, extracted from lowering/lowering.mt (Wave 4.2).

import std.map as map_mod
import std.vec as vec

import mtc.c_naming as naming
import mtc.ir as ir
import mtc.parser.ast as ast
import mtc.semantic.analyzer as analyzer
import mtc.semantic.types as types
import mtc.loader.module_loader as loader

import mtc.lowering.include_scan as include_scan
import mtc.lowering.lowering as lowering
import mtc.lowering.monomorphized as monomorphized
import mtc.lowering.parallel as parallel_mod
import mtc.lowering.proc_renumber as proc_renumber
import mtc.lowering.type_helpers as type_helpers


public function lower_checked(program: loader.Program) -> lowering.LoweringOutcome:
    let count = program.analyses.len()
    if count == 0:
        return lowering.LoweringOutcome(
            program = ir.empty_program("(anonymous)", ""),
            failed = false,
            error = zero[lowering.LoweringError]
        )
    let root_ptr = program.analyses.get(program.root_index) else:
        return lowering.LoweringOutcome(
            program = ir.empty_program("(anonymous)", ""),
            failed = false,
            error = zero[lowering.LoweringError]
        )
    var root = unsafe: read(root_ptr)
    let root_name = root.module_name
    # Per-compile counters (the host resets these in `Lowering#initialize`).
    lowering.reset_lowering_counters()
    parallel_mod.reset_parallel_counter()

    # Shared cross-module function return types, keyed by C linkage name, so a
    # `mod.func(...)` call in one module can resolve the result type of a
    # function defined in another.
    var program_returns = map_mod.Map[str, types.Type].create()
    # Async cross-module functions, keyed by C linkage name, so the call lowering
    # does not rescan every module's declarations (and allocate a C name per
    # candidate) for every cross-module call.
    var program_async = map_mod.Map[str, bool].create()
    # Shared prelude arm-payload field types (see lowering.LoweringContext.prelude_arm_field_types).
    # Populated by `collect_program_returns` (which resolves every function's
    # return type, emitting the concrete Option/Result decls) so it is available
    # before any module body is lowered.
    var prelude_arm_field_types = map_mod.Map[str, types.Type].create()
    # Program-wide generic-struct instance registry, shared across every module's
    # lowering so a `Vec[T]` instance registered while qualifying one module's
    # types is visible to method resolution in every other module.
    var generic_instances = map_mod.Map[str, lowering.GenericReceiver].create()
    monomorphized.collect_program_returns(
        program,
        ref_of(program_returns),
        ref_of(program_async),
        ref_of(prelude_arm_field_types),
        ref_of(generic_instances)
    )

    var constants = vec.Vec[ir.Constant].create()
    var globals = vec.Vec[ir.Global].create()
    var opaques = vec.Vec[ir.OpaqueDecl].create()
    var structs = vec.Vec[ir.StructDecl].create()
    var unions = vec.Vec[ir.UnionDecl].create()
    var enums = vec.Vec[ir.EnumDecl].create()
    var variants = vec.Vec[ir.VariantDecl].create()
    var static_asserts = vec.Vec[ir.StaticAssert].create()
    var type_aliases = vec.Vec[ir.TypeAlias].create()
    var functions = vec.Vec[ir.Function].create()

    var i: ptr_uint = 0
    var seen_structs = map_mod.Map[str, bool].create()
    var seen_variants = map_mod.Map[str, bool].create()
    var seen_functions = map_mod.Map[str, bool].create()
    var monomorphized_structs = vec.Vec[ir.StructDecl].create()
    var monomorphized_variants = vec.Vec[ir.VariantDecl].create()
    var pending_synthetic_structs = vec.Vec[ir.StructDecl].create()
    var external_structs = vec.Vec[ir.ExternalStructLayout].create()
    var seen_external_structs = map_mod.Map[str, bool].create()
    var spec_infos = map_mod.Map[str, lowering.SpecInfo].create()
    # Each module's declaration list with module-level `when` blocks expanded in
    # place.  Lowering and the placement pass must share it: the host's
    # `expanded_declarations` expands in place for both.
    var expanded_decls = map_mod.Map[str, span[ast.Decl]].create()
    var module_fragments = vec.Vec[ir.Program].create()
    var module_analyses = vec.Vec[analyzer.Analysis].create()
    var function_owner = map_mod.Map[str, str].create()
    var lowering_error = zero[lowering.LoweringError]
    var lowering_failed = false
    var synthetic_functions = vec.Vec[ir.Function].create()
    var synthetic_enums = vec.Vec[ir.EnumDecl].create()
    # `emit`-produced declarations (the host's `@artifacts.emitted_declarations`),
    # appended after the synthetic declarations in lowering order.
    var emitted_functions = vec.Vec[ir.Function].create()
    var emitted_structs = vec.Vec[ir.StructDecl].create()
    var emitted_constants = vec.Vec[ir.Constant].create()
    while i < count:
        let a_ptr = program.analyses.get(i) else:
            i += 1
            continue
        var analysis = unsafe: read(a_ptr)
        if lowering.is_raw_module(analysis.module_kind):
            i += 1
            continue
        let is_root = i == program.root_index
        var fragment = monomorphized.lower_module(
            analysis,
            ref_of(program_returns),
            ref_of(program_async),
            ref_of(prelude_arm_field_types),
            is_root,
            program.analyses.as_span(),
            program.modules.as_span(),
            ref_of(generic_instances),
            ref_of(monomorphized_structs),
            ref_of(monomorphized_variants),
            ref_of(pending_synthetic_structs),
            ref_of(synthetic_functions),
            ref_of(synthetic_enums),
            ptr_of(emitted_functions),
            ptr_of(emitted_structs),
            ptr_of(emitted_constants),
            ref_of(spec_infos),
            ref_of(expanded_decls),
            ref_of(lowering_error),
            ref_of(lowering_failed)
        )
        if lowering_failed:
            return lowering.LoweringOutcome(
                program = ir.empty_program("(lowering failed)", ""),
                failed = true,
                error = lowering_error
            )
        module_fragments.push(fragment)
        module_analyses.push(analysis)
        var gi_owned: ptr_uint = 0
        while gi_owned < fragment.globals.len:
            var owned_global = unsafe: read(fragment.globals.data + gi_owned)
            owned_global.source_module = Option[str].some(value = analysis.module_name)
            globals.push(owned_global)
            gi_owned += 1
        opaques.append_span(fragment.opaques)
        lowering.dedup_append_structs(ref_of(structs), fragment.structs, ref_of(seen_structs))
        unions.append_span(fragment.unions)
        enums.append_span(fragment.enums)
        lowering.dedup_append_variants(ref_of(variants), fragment.variants, ref_of(seen_variants))
        static_asserts.append_span(fragment.static_asserts)
        var ci_owned: ptr_uint = 0
        while ci_owned < fragment.constants.len:
            var owned_constant = unsafe: read(fragment.constants.data + ci_owned)
            owned_constant.source_module = Option[str].some(value = analysis.module_name)
            constants.push(owned_constant)
            ci_owned += 1
        var fi_owned: ptr_uint = 0
        while fi_owned < fragment.functions.len:
            let owned_function = unsafe: read(fragment.functions.data + fi_owned)
            function_owner.set(owned_function.linkage_name, analysis.module_name)
            fi_owned += 1
        # External-struct layouts for the C backend's equality helpers, deduped
        # across modules (several modules can compare the same raw struct type).
        var efx: ptr_uint = 0
        while efx < fragment.external_structs.len:
            let layout = unsafe: read(fragment.external_structs.data + efx)
            if not seen_external_structs.contains(layout.key):
                seen_external_structs.set(layout.key, true)
                external_structs.push(layout)
            efx += 1
        # Functions are appended after the loop, reordered per module.
        i += 1

    # Synthetic enums and value structs follow the module declarations; the
    # `str_buffer[N]` structs ride the Program's separate field.
    let str_buffer_synthetic = lowering.append_synthetic_decls(
        ref_of(synthetic_enums), pending_synthetic_structs.as_span(), ref_of(emitted_structs),
        ref_of(enums), ref_of(structs), ref_of(seen_structs)
    )

    # Place every module's functions in the host's order (`lower_functions` and
    # its fixpoint): a declaration pass over all modules, then further passes
    # for instances created by later declaration visits.
    var all_by_linkage = map_mod.Map[str, ir.Function].create()
    var fi: ptr_uint = 0
    while fi < module_fragments.len():
        let frag_ptr = module_fragments.get(fi) else:
            break
        let frag = unsafe: read(frag_ptr)
        var ffi: ptr_uint = 0
        while ffi < frag.functions.len:
            var f: ir.Function
            unsafe:
                f = read(frag.functions.data + ffi)
            if not all_by_linkage.contains(f.linkage_name):
                all_by_linkage.set(f.linkage_name, f)
            ffi += 1
        fi += 1
    let ordered = monomorphized.order_module_functions(
        module_analyses.as_span(),
        module_fragments.as_span(),
        ref_of(all_by_linkage),
        ref_of(spec_infos),
        ref_of(expanded_decls)
    )
    var owned_ordered = vec.Vec[ir.Function].create()
    var oi_ordered: ptr_uint = 0
    while oi_ordered < ordered.len:
        var f_ordered = unsafe: read(ordered.data + oi_ordered)
        let owner_ptr = function_owner.get(f_ordered.linkage_name)
        if owner_ptr != null:
            f_ordered.source_module = Option[str].some(value = unsafe: read(owner_ptr))
        owned_ordered.push(f_ordered)
        oi_ordered += 1
    lowering.dedup_append_functions(ref_of(functions), owned_ordered.as_span(), ref_of(seen_functions))
    let module_fn_count = functions.len()
    # The host's program-level synthetic function list (proc invoke/release/
    # retain bodies and pfor/spawn workers) follows every module's functions.
    lowering.dedup_append_functions(ref_of(functions), synthetic_functions.as_span(), ref_of(seen_functions))
    var emf_i: ptr_uint = 0
    while emf_i < emitted_functions.len():
        let emf_ptr = emitted_functions.get(emf_i) else:
            break
        functions.push(unsafe: read(emf_ptr))
        emf_i += 1
    var emc_i: ptr_uint = 0
    while emc_i < emitted_constants.len():
        let emc_ptr = emitted_constants.get(emc_i) else:
            break
        constants.push(unsafe: read(emc_ptr))
        emc_i += 1

    # Collect type aliases from all non-raw modules; raw modules define C-level
    # types that already exist, and `std.c.*` targets get a typedef only when
    # they resolve to a known C name.
    lowering.collect_type_aliases(program, ref_of(monomorphized_structs), ref_of(type_aliases))

    let assembled = ir.Program(
        module_name = root_name,
        includes = include_scan.collect_includes(program),
        constants = constants.as_span(),
        globals = globals.as_span(),
        opaques = monomorphized.collect_opaque_decls(program),
        structs = structs.as_span(),
        unions = unions.as_span(),
        enums = enums.as_span(),
        variants = variants.as_span(),
        static_asserts = static_asserts.as_span(),
        functions = functions.as_span(),
        type_aliases = type_aliases.as_span(),
        source_path = root.source_path,
        monomorphized_structs = monomorphized_structs.as_span(),
        monomorphized_variants = monomorphized_variants.as_span(),
        external_structs = external_structs.as_span(),
        str_buffer_structs = str_buffer_synthetic.as_span(),
        arena = null,
    )
    return lowering.LoweringOutcome(
        program = proc_renumber.renumber_program_procs(assembled, module_fn_count),
        failed = false,
        error = zero[lowering.LoweringError]
    )


public function build_root_main_entrypoint(
    ctx: ref[lowering.LoweringContext],
    name: str,
    params: span[ast.Param]
) -> Option[ir.Function]:
    let sig = type_helpers.find_fn_sig(ctx, name)
    let user_return = type_helpers.fn_sig_return_type(sig)
    if not (types.is_void(user_return) or type_helpers.is_int_type(user_return)):
        return Option[ir.Function].none

    let int_ty = types.primitive("int")
    let user_linkage = naming.qualified_c_name(ctx.module_name, name)

    if params.len == 0:
        let call = lowering.alloc_expr(ir.Expr.expr_call(callee = user_linkage, arguments = span[ir.Expr](), ty = user_return))
        var body = vec.Vec[ir.Stmt].create()
        lowering.append_entry_call_and_return(ref_of(body), call, user_return, int_ty)
        return Option[ir.Function].some(value = ir.Function(
            source_module = Option[str].none,
            name = name, linkage_name = "main", params = span[ir.Param](),
            return_type = int_ty, body = body.as_span(), entry_point = true, public_export = false, method_receiver_param = false,
        ))

    # Single `span[str]` parameter: emit `int main(int argc, char** argv)`, build a
    # `span[str]` from argv via the runtime bridge, call the user main, then free.
    if params.len == 1 and lowering.main_param_is_span_str(ctx, params):
        let span_str_ty = types.generic_type(name = "span", args = lowering.sp_type(types.Type.ty_str))
        let items_ty = types.generic_type(name = "ptr", args = lowering.sp_type(types.Type.ty_str))
        let char_ptr_ptr = types.generic_type(
            name = "ptr",
            args = lowering.sp_type(types.generic_type(name = "ptr", args = lowering.sp_type(types.primitive("char"))))
        )

        var body = vec.Vec[ir.Stmt].create()
        # mt_str* __mt_args_items = NULL; (the host's null literal, not a `NULL`
        # name — the C backend renders the null literal as `NULL`).
        let items_null = lowering.alloc_expr(ir.Expr.expr_null_literal(ty = items_ty))
        body.push(ir.Stmt.stmt_local(
            name = "__mt_args_items",
            linkage_name = "__mt_args_items",
            ty = items_ty,
            value = items_null,
            line = 0,
            source_path = ""
        ))
        let items_ref = lowering.alloc_expr(ir.Expr.expr_name(
            name = "__mt_args_items",
            ty = items_ty,
            pointer = Option[bool].some(value = false)
        ))
        # mt_span_str __mt_args = mt_entry_argv_to_span_str(argc, argv, &__mt_args_items);
        let argc_expr = lowering.alloc_expr(ir.Expr.expr_name(
            name = "argc",
            ty = int_ty,
            pointer = Option[bool].some(value = false)
        ))
        let argv_expr = lowering.alloc_expr(ir.Expr.expr_name(
            name = "argv",
            ty = char_ptr_ptr,
            pointer = Option[bool].some(value = false)
        ))
        let items_addr = lowering.alloc_expr(ir.Expr.expr_address_of(
            expression = items_ref,
            ty = types.generic_type(name = "ptr", args = lowering.sp_type(items_ty))
        ))
        var bridge_args = vec.Vec[ir.Expr].create()
        unsafe:
            bridge_args.push(read(argc_expr))
            bridge_args.push(read(argv_expr))
            bridge_args.push(read(items_addr))
        let bridge_call = lowering.alloc_expr(ir.Expr.expr_call(
            callee = "mt_entry_argv_to_span_str",
            arguments = bridge_args.as_span(),
            ty = span_str_ty
        ))
        body.push(ir.Stmt.stmt_local(
            name = "__mt_args",
            linkage_name = "__mt_args",
            ty = span_str_ty,
            value = bridge_call,
            line = 0,
            source_path = ""
        ))
        let args_ref = lowering.alloc_expr(ir.Expr.expr_name(
            name = "__mt_args",
            ty = span_str_ty,
            pointer = Option[bool].some(value = false)
        ))

        var call_args = vec.Vec[ir.Expr].create()
        unsafe:
            call_args.push(read(args_ref))
        let call = lowering.alloc_expr(ir.Expr.expr_call(
            callee = user_linkage,
            arguments = call_args.as_span(),
            ty = user_return
        ))

        # Capture the user result, free the argv strings, then return.
        if types.is_void(user_return):
            body.push(ir.Stmt.stmt_expression(expression = call, line = 0, source_path = ""))
            lowering.append_free_argv_items(ref_of(body), items_ref)
            let zero = lowering.alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = int_ty))
            body.push(ir.Stmt.stmt_return(value = zero, line = 0, source_path = ""))
        else:
            body.push(ir.Stmt.stmt_local(
                name = "__mt_result",
                linkage_name = "__mt_result",
                ty = int_ty,
                value = call,
                line = 0,
                source_path = ""
            ))
            lowering.append_free_argv_items(ref_of(body), items_ref)
            let exit_ref = lowering.alloc_expr(ir.Expr.expr_name(
                name = "__mt_result",
                ty = int_ty,
                pointer = Option[bool].some(value = false)
            ))
            body.push(ir.Stmt.stmt_return(value = exit_ref, line = 0, source_path = ""))

        var entry_params = vec.Vec[ir.Param].create()
        entry_params.push(ir.Param(
            name = "argc",
            linkage_name = "argc",
            ty = int_ty,
            pointer = Option[bool].some(value = false)
        ))
        entry_params.push(ir.Param(
            name = "argv",
            linkage_name = "argv",
            ty = char_ptr_ptr,
            pointer = Option[bool].some(value = false)
        ))
        return Option[ir.Function].some(value = ir.Function(
            source_module = Option[str].none,
            name = name, linkage_name = "main", params = entry_params.as_span(),
            return_type = int_ty, body = body.as_span(), entry_point = true, public_export = false, method_receiver_param = false,
        ))

    return Option[ir.Function].none
