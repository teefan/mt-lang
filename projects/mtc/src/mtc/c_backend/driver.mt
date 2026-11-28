## Whole-program C generation driver, extracted from c_backend/c_backend.mt.

import std.map as map_mod
import std.mem.heap as heap
import std.string as string
import std.vec as vec

import mtc.c_naming as naming
import mtc.ir as ir
import mtc.semantic.types as types
import mtc.c_backend.reachability as reachability
import mtc.c_backend.program as program_emitter
import mtc.c_backend.c_backend as c_backend
import mtc.c_backend.slice as slice_emitter


public function generate_c_impl(
    input_program: ir.Program,
    emit_line_directives: bool,
    debug_guards: bool,
    export_public: bool,
    split: ptr[c_backend.SplitOutput]?
) -> string.String:
    var program = input_program
    # Concrete generic struct instances are carried outside the IR's `:structs`
    # section (host parity).  Merge them into the declaration list the backend
    # sorts and emits, so their fields participate in every scan below.
    if program.monomorphized_structs.len > 0 or program.str_buffer_structs.len > 0:
        var merged = vec.Vec[ir.StructDecl].create()
        var mi: ptr_uint = 0
        while mi < program.structs.len:
            merged.push(unsafe: read(program.structs.data + mi))
            mi += 1
        mi = 0
        while mi < program.monomorphized_structs.len:
            merged.push(unsafe: read(program.monomorphized_structs.data + mi))
            mi += 1
        mi = 0
        while mi < program.str_buffer_structs.len:
            merged.push(unsafe: read(program.str_buffer_structs.data + mi))
            mi += 1
        program = ir.Program(
            module_name = program.module_name,
            includes = program.includes,
            constants = program.constants,
            globals = program.globals,
            opaques = program.opaques,
            structs = merged.as_span(),
            unions = program.unions,
            enums = program.enums,
            variants = program.variants,
            static_asserts = program.static_asserts,
            functions = program.functions,
            type_aliases = program.type_aliases,
            source_path = program.source_path,
            monomorphized_structs = program.monomorphized_structs,
            monomorphized_variants = program.monomorphized_variants,
            external_structs = program.external_structs,
            str_buffer_structs = program.str_buffer_structs,
            arena = program.arena,
        )
    var e = c_backend.Emitter(
        buffer = string.String.create(),
        str_lit_map = map_mod.Map[str, str].create(),
        used_labels = map_mod.Map[str, bool].create(),
        variant_eq_set = map_mod.Map[str, bool].create(),
        variant_decl_by_name = map_mod.Map[str, ir.VariantDecl].create(),
        struct_eq_set = map_mod.Map[str, bool].create(),
        external_eq_fields = map_mod.Map[str, span[ir.Field]].create(),
        opt_type_set = map_mod.Map[str, types.Type].create(),
        std_c_backing = map_mod.Map[str, str].create(),
        split_mode = split != null,
        split_target = 0,
        split_header = string.String.create(),
        split_data = string.String.create(),
        split_unit_names = vec.Vec[string.String].create(),
        split_unit_sources = vec.Vec[string.String].create(),
        split_unit_index = 0,
    )
    var backing_map = c_backend.collect_std_c_backing(program)
    let backing_map_ptr = heap.must_alloc[map_mod.Map[str, str]](1)
    unsafe:
        read(backing_map_ptr) = backing_map
    c_backend.set_std_c_backing_names(backing_map_ptr)
    var opaque_backing_map = c_backend.collect_opaque_backings(program)
    let opaque_backing_map_ptr = heap.must_alloc[map_mod.Map[str, str]](1)
    unsafe:
        read(opaque_backing_map_ptr) = opaque_backing_map
    c_backend.set_opaque_backing_names(opaque_backing_map_ptr)
    e.current_fn_return_type = types.primitive("void")
    e.emit_line_directives = emit_line_directives
    e.debug_guards = debug_guards
    e.loop_guard_id = 0
    e.loop_guards = map_mod.Map[ptr_uint, str].create()
    e.current_fn_linkage = ""
    e.array_call_temps = map_mod.Map[ptr_uint, str].create()
    e.array_call_temp_counter = 0
    var opaques = map_mod.Map[str, bool].create()
    var oi: ptr_uint = 0
    while oi < program.opaques.len:
        unsafe:
            let od = read(program.opaques.data + oi)
            opaques.set(od.name, true)
            opaques.set(od.linkage_name, true)
            match od.source_module:
                Option.some as src:
                    opaques.set(naming.qualified_c_name(src.value, od.name), true)
                Option.none:
                    pass
            let bare = c_backend.extract_bare_name(od.name)
            if bare.len > 0:
                opaques.set(bare, true)
        oi += 1

    # Reachability pruning: emit only functions reachable from the entry points,
    # in source order (mirrors c_backend/reachability.rb emitted_functions).
    var emitted = reachability.emitted_functions(program)
    let funcs = emitted.as_span()

    # One variant lookup for the whole generation: `program.variants` plus the
    # concretely-instantiated `Option`/`Result` instances lowering keeps outside
    # the IR's `:variants` section.  `collect_generic_variants` walks every
    # declaration and expression, so it runs exactly once here rather than on
    # each lookup.
    var gv_i: ptr_uint = 0
    while gv_i < program.variants.len:
        unsafe:
            let vd = read(program.variants.data + gv_i)
            e.variant_decl_by_name.set(vd.linkage_name, vd)
        gv_i += 1
    var gen_variants = c_backend.collect_generic_variants(program)
    gv_i = 0
    while gv_i < gen_variants.len():
        let gv_ptr = gen_variants.get(gv_i) else:
            break
        unsafe:
            let vd = read(gv_ptr)
            e.variant_decl_by_name.set(vd.linkage_name, vd)
        gv_i += 1

    # Pre-scan functions for aggregate equality to know which helpers to emit
    # and whether the str-equality helper is required by a helper body.
    c_backend.scan_variant_equality(ref_of(e), funcs, program)

    # Slice helpers (`mt_str_slice`, `mt_span_slice_<T>`) used by the program.
    var slice_has_str = false
    var slice_has_str_index = false
    var slice_has_str_concat = false
    var slice_span_types = vec.Vec[types.Type].create()
    slice_emitter.collect_slice_helpers(
        funcs,
        ref_of(slice_has_str),
        ref_of(slice_has_str_index),
        ref_of(slice_has_str_concat),
        ref_of(slice_span_types)
    )
    var str_lits = c_backend.collect_str_literals(funcs)
    var li: ptr_uint = 0
    while li < str_lits.len():
        let value_ptr = str_lits.get(li) else:
            break
        unsafe:
            e.str_lit_map.set(read(value_ptr), c_backend.str_literal_name(li))
        li += 1
    let has_str_literals = str_lits.len() > 0
    var checked_index_types = c_backend.collect_checked_index_types(funcs)
    var checked_span_index_types = c_backend.collect_checked_span_index_types(funcs)
    var tuple_types = c_backend.filter_declared_tuple_types(c_backend.collect_tuple_types(funcs, program, ref_of(gen_variants)), program)
    var opt_structs = c_backend.collect_opt_struct_decls(program, ref_of(opaques))
    # Bounds-checked accessors call mt_fatal, so their presence pulls in the
    # fatal helper (and, via uses_string_view, the mt_str type + <stdlib.h>).
    let use_fatal = e.debug_guards or c_backend.uses_fatal_helper(
        funcs,
        program
    ) or checked_index_types.len() > 0 or checked_span_index_types.len() > 0 or c_backend.uses_format_helpers(program) or c_backend.uses_foreign_cstr_helper(funcs) or slice_has_str or slice_has_str_index or slice_has_str_concat or slice_span_types.len() > 0
    let use_fatal_str = c_backend.uses_fatal_str_helper(funcs)
    let use_entry_argv = c_backend.uses_entry_argv(program)
    let use_string_view = c_backend.uses_string_view(
        funcs,
        has_str_literals
    ) or use_fatal or use_fatal_str or c_backend.aggregates_use_str(program) or c_backend.gen_variants_have_str(ref_of(gen_variants)) or use_entry_argv or slice_has_str or slice_has_str_index or slice_has_str_concat
    let use_str_equality = c_backend.uses_str_equality(funcs) or c_backend.equality_helpers_need_str(ref_of(e), program)
    var simd_types = c_backend.collect_simd_types(funcs, program)
    if e.split_mode:
        e.split_target = 1

    # Feature-test macros, includes, forward declarations, and the fixed helper
    # types/emitters that precede the program's own declarations.
    c_backend.emit_preamble(
        ref_of(e), program, funcs, use_fatal, use_fatal_str, use_entry_argv, use_string_view,
        use_str_equality, slice_has_str_concat, simd_types
    )

    # Span types are collected over *all* lowered functions, matching the
    # generic-instance and struct collection: an instance (a pruned function's
    # `Option[span[X]]`, say) embeds the span by value, so its typedef must exist
    # even when the function that named it is not emitted.
    var span_types = c_backend.collect_span_types(program.functions)
    c_backend.collect_struct_span_types(program, ref_of(span_types))
    c_backend.collect_variant_span_types(program, ref_of(span_types))

    # Emit runtime helpers before forward declarations (mirrors Ruby order).
    c_backend.emit_runtime_helpers(ref_of(e), program, funcs)
    program_emitter.emit_program_types(ref_of(e), program, span_types, tuple_types, gen_variants, opt_structs, funcs)
    if e.split_mode:
        c_backend.prepare_split_units(ref_of(e), funcs, program.module_name)
    program_emitter.emit_program_bodies(
        ref_of(e),
        program,
        funcs,
        export_public,
        checked_index_types,
        checked_span_index_types,
        has_str_literals,
        str_lits,
        slice_has_str,
        slice_has_str_index,
        slice_has_str_concat,
        slice_span_types,
        use_entry_argv
    )

    var result = string.String.create()
    if split != null:
        let output = split
        e.split_target = 0
        var header_text = c_backend.trim_string(e.split_header)
        var final_header = string.String.create()
        final_header.append("#ifndef MTC_SPLIT_HEADER_H\n#define MTC_SPLIT_HEADER_H\n")
        final_header.append(header_text.as_str())
        final_header.append("#endif\n")
        header_text.release()
        unsafe:
            read(output).header.release()
            read(output).header = final_header

        var data_text = c_backend.trim_string(e.split_data)
        var final_data = string.String.create()
        final_data.append("#include \"mtc.h\"\n")
        final_data.append(data_text.as_str())
        data_text.release()
        unsafe:
            read(output).data.release()
            read(output).data = final_data

        var units = vec.Vec[c_backend.SplitUnit].create()
        var ui: ptr_uint = 0
        while ui < e.split_unit_sources.len():
            let name_ptr = e.split_unit_names.get(ui) else:
                break
            let source_ptr = e.split_unit_sources.get(ui) else:
                break
            var unit = c_backend.SplitUnit(
                module_name = string.String.from_str(unsafe: read(name_ptr).as_str()),
                source = string.String.create()
            )
            unit.source.append("#include \"mtc.h\"\n")
            var unit_text = c_backend.trim_string(unsafe: read(source_ptr))
            unit.source.append(unit_text.as_str())
            unit_text.release()
            units.push(unit)
            ui += 1
        unsafe:
            read(output).units.release()
            read(output).units = units
    else:
        result.release()
        result = c_backend.trim_string(e.buffer)
    # Everything the emitter accumulated is dead once `result` is built: the
    # output buffer, the per-generation lookup tables, the collected type/func
    # sets and the two module-level backing-name maps.  They used to be left to
    # process exit, which cost ~80 MB per call (`--keep-c` emits twice, `mtc test`
    # once per fixture).
    e.buffer.release()
    c_backend.release_emitter_tables(ref_of(e))
    emitted.release()
    gen_variants.release()
    str_lits.release()
    checked_index_types.release()
    checked_span_index_types.release()
    tuple_types.release()
    c_backend.release_opt_struct_entries(ref_of(opt_structs))
    opaques.release()
    simd_types.release()
    span_types.release()
    return result
