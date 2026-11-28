## Program-level C type and body emitters, extracted from c_backend/c_backend.mt.

import std.map as map_mod
import std.string as string
import std.vec as vec

import mtc.ir as ir
import mtc.semantic.types as types
import mtc.strings
import mtc.c_backend.reachability as reachability
import mtc.c_backend.c_backend as c_backend
import mtc.c_backend.slice as slice_emitter
import mtc.c_backend.task as task_emitter


function emit_program_types(
    e: ref[c_backend.Emitter],
    program: ir.Program,
    span_types: vec.Vec[types.Type],
    tuple_types: vec.Vec[types.Type],
    gen_variants: vec.Vec[ir.VariantDecl],
    opt_structs: vec.Vec[c_backend.OptionStructEntry],
    funcs: span[ir.Function]
) -> void:
    var i: ptr_uint = 0
    var gen_variants_mut = gen_variants
    var opt_structs_mut = opt_structs
    if (
        program.structs.len > 0
        or program.unions.len > 0
        or tuple_types.len() > 0
        or program.variants.len > 0
        or gen_variants.len() > 0
        or opt_structs.len() > 0
    ):
        var sorted_structs = c_backend.topo_sort_structs(program.structs)
        let sorted = sorted_structs.as_span()

        # Emit span type forward declarations first (so struct types can reference them).
        var si: ptr_uint = 0
        while si < span_types.len():
            let ty_ptr = span_types.get(si) else:
                break
            unsafe:
                c_backend.emit_line(
                    e,
                    strings.join_three("typedef struct ", c_backend.span_type_name(c_backend.array_element_type(read(ty_ptr))), ";")
                )
            si += 1
        if span_types.len() > 0:
            c_backend.emit_line(e, "")
        i = 0
        while i < sorted.len:
            unsafe:
                let s = read(sorted.data + i)
                c_backend.emit_line(
                    e,
                    strings.join_three(
                        "typedef struct ",
                        s.linkage_name,
                        strings.join_two(" ", strings.join_two(s.linkage_name, ";"))
                    )
                )
            i += 1
        i = 0
        while i < program.unions.len:
            unsafe:
                let u = read(program.unions.data + i)
                c_backend.emit_line(
                    e,
                    strings.join_three(
                        "typedef union ",
                        u.linkage_name,
                        strings.join_two(" ", strings.join_two(u.linkage_name, ";"))
                    )
                )
            i += 1
        i = 0
        while i < tuple_types.len():
            let ty_ptr = tuple_types.get(i) else:
                break
            unsafe:
                c_backend.emit_tuple_type_forward(e, read(ty_ptr))
            i += 1
        i = 0
        while i < program.variants.len:
            unsafe:
                c_backend.emit_variant_forward(e, read(program.variants.data + i))
            i += 1
        i = 0
        while i < gen_variants.len():
            let v_ptr = gen_variants.get(i) else:
                break
            unsafe:
                c_backend.emit_variant_forward(e, read(v_ptr))
            i += 1
        i = 0
        while i < opt_structs.len():
            let os_ptr = opt_structs.get(i) else:
                break
            unsafe:
                let os = read(os_ptr)
                c_backend.emit_line(
                    e,
                    strings.join_three(
                        "typedef struct ",
                        os.decl.linkage_name,
                        strings.join_two(" ", strings.join_two(os.decl.linkage_name, ";"))
                    )
                )
            i += 1
        c_backend.emit_line(e, "")
        c_backend.emit_enums_block(e, program)

        # Collect Task types once; used by both forward declarations (before
        # type aliases) and topological sort (alongside structs/variants).
        var task_seen = map_mod.Map[str, bool].create()
        var task_elements = map_mod.Map[str, types.Type].create()
        task_emitter.collect_task_type_set(program, ref_of(task_seen), ref_of(task_elements))

        # Task forward declarations must come before type aliases because
        # aliases like `typedef mt_task_X ChanMessageTask` reference them.
        task_emitter.emit_task_forward_decls(e, ref_of(task_seen))
        c_backend.emit_type_aliases(e, program)

        # Emit span type full definitions after forward declarations
        # so they can reference struct types.
        si = 0
        while si < span_types.len():
            let ty_ptr = span_types.get(si) else:
                break
            unsafe:
                c_backend.emit_span_type(e, read(ty_ptr))
            c_backend.emit_line(e, "")
            si += 1

        # Emit struct and variant full definitions in a single dependency order,
        # since structs and variants can embed each other by value.  Task structs
        # are included in the sort so that Option[Task[X]] (with value: Task[X])
        # is ordered after the Task struct definition.
        var type_order = c_backend.topo_sort_types(
            program.structs,
            ref_of(gen_variants_mut),
            program.variants,
            ref_of(opt_structs_mut),
            ref_of(task_seen),
            ref_of(task_elements),
            tuple_types
        )
        var toi: ptr_uint = 0
        while toi < type_order.len():
            let node_ptr = type_order.get(toi) else:
                break
            unsafe:
                let node = read(node_ptr)
                if node.kind == 0:
                    c_backend.emit_struct(e, read(program.structs.data + node.index))
                else if node.kind == 1:
                    let gv_ptr = gen_variants.get(node.index) else:
                        toi += 1
                        continue
                    c_backend.emit_variant(e, read(gv_ptr))
                else if node.kind == 2:
                    c_backend.emit_variant(e, read(program.variants.data + node.index))
                else if node.kind == 3:
                    let os_ptr = opt_structs.get(node.index) else:
                        toi += 1
                        continue
                    c_backend.emit_struct(e, read(os_ptr).decl)
                else if node.kind == 4:
                    # kind 4: Task struct
                    var elem = types.primitive("void")
                    let te_ptr = task_elements.get(node.key)
                    if te_ptr != null:
                        elem = unsafe: read(te_ptr)
                    task_emitter.emit_task_struct_type(e, node.key, elem)
                else:
                    # kind 5: tuple struct
                    let tuple_ptr = tuple_types.get(node.index) else:
                        toi += 1
                        continue
                    c_backend.emit_tuple_type_def(e, unsafe: read(tuple_ptr))
            c_backend.emit_line(e, "")
            toi += 1
        i = 0
        while i < program.unions.len:
            unsafe:
                c_backend.emit_union(e, read(program.unions.data + i))
            c_backend.emit_line(e, "")
            i += 1

        # Emit SoA struct definitions after regular structs (they reference
        # element struct fields by C name).
        c_backend.emit_soa_types(e, funcs, program)
    else:
        # No structs/unions/variants — but span types may still be needed.
        var span_si: ptr_uint = 0
        while span_si < span_types.len():
            let ty_ptr = span_types.get(span_si) else:
                break
            unsafe:
                c_backend.emit_line(
                    e,
                    strings.join_three("typedef struct ", c_backend.span_type_name(c_backend.array_element_type(read(ty_ptr))), ";")
                )
            span_si += 1
        span_si = 0
        while span_si < span_types.len():
            let ty_ptr = span_types.get(span_si) else:
                break
            unsafe:
                c_backend.emit_span_type(e, read(ty_ptr))
                c_backend.emit_line(e, "")
            span_si += 1
        c_backend.emit_enums_block(e, program)


function emit_program_bodies(
    e: ref[c_backend.Emitter],
    program: ir.Program,
    funcs: span[ir.Function],
    export_public: bool,
    checked_index_types: vec.Vec[types.Type],
    checked_span_index_types: vec.Vec[types.Type],
    has_str_literals: bool,
    str_lits: vec.Vec[str],
    slice_has_str: bool,
    slice_has_str_index: bool,
    slice_has_str_concat: bool,
    slice_span_types: vec.Vec[types.Type],
    use_entry_argv: bool
) -> void:
    if e.split_mode:
        e.split_target = 1
    var i: ptr_uint = 0
    if funcs.len > 0:
        i = 0
        while i < funcs.len:
            unsafe:
                c_backend.emit_line(
                    e,
                    strings.join_two(
                        c_backend.function_signature(read(funcs.data + i), export_public, e.split_mode),
                        ";"
                    )
                )
            i += 1
        c_backend.emit_line(e, "")
    i = 0
    var emitted_helpers = map_mod.Map[str, bool].create()
    while i < checked_index_types.len():
        let ty_ptr = checked_index_types.get(i) else:
            break
        unsafe:
            let name = c_backend.checked_array_index_helper_name(read(ty_ptr))
            if not emitted_helpers.contains(name):
                emitted_helpers.set(name, true)
                c_backend.emit_checked_index_helper(e, read(ty_ptr), false)
                c_backend.emit_line(e, "")
            let nullable_name = c_backend.nullable_array_index_helper_name(read(ty_ptr))
            if not emitted_helpers.contains(nullable_name):
                emitted_helpers.set(nullable_name, true)
                c_backend.emit_checked_index_helper(e, read(ty_ptr), true)
                c_backend.emit_line(e, "")
        i += 1
    i = 0
    var emitted_span_helpers = map_mod.Map[str, bool].create()
    while i < checked_span_index_types.len():
        let ty_ptr = checked_span_index_types.get(i) else:
            break
        unsafe:
            let name = c_backend.checked_span_index_helper_name(read(ty_ptr))
            if not emitted_span_helpers.contains(name):
                emitted_span_helpers.set(name, true)
                c_backend.emit_checked_span_index_helper(e, read(ty_ptr), false)
                c_backend.emit_line(e, "")
            let nullable_name = c_backend.nullable_span_index_helper_name(read(ty_ptr))
            if not emitted_span_helpers.contains(nullable_name):
                emitted_span_helpers.set(nullable_name, true)
                c_backend.emit_checked_span_index_helper(e, read(ty_ptr), true)
                c_backend.emit_line(e, "")
        i += 1
    if has_str_literals:
        i = 0
        while i < str_lits.len():
            let value_ptr = str_lits.get(i) else:
                break
            unsafe:
                c_backend.emit_line(e, c_backend.render_str_literal_constant(read(value_ptr), i))
            i += 1
        c_backend.emit_line(e, "")
    if e.variant_eq_set.len() > 0 or e.struct_eq_set.len() > 0:
        c_backend.emit_equality_forward_decls(e, program)
        c_backend.emit_variant_equality_helpers(e)
        c_backend.emit_struct_equality_helpers(e, program)
    if slice_has_str or slice_has_str_index or slice_has_str_concat or slice_span_types.len() > 0:
        slice_emitter.emit_slice_helpers(e, slice_has_str, slice_has_str_index, slice_has_str_concat, slice_span_types)
    if program.constants.len > 0:
        var emitted_consts = reachability.emitted_constants(program, funcs)
        var ci: ptr_uint = 0
        while ci < emitted_consts.len():
            let c_ptr = emitted_consts.get(ci) else:
                break
            unsafe:
                c_backend.emit_line(e, c_backend.render_constant(e, read(c_ptr)))
            ci += 1
        # A module import can contribute constants that are all pruned; the
        # host emits no separator when nothing was written.
        if emitted_consts.len() > 0:
            c_backend.emit_line(e, "")
    if program.globals.len > 0:
        if e.split_mode:
            e.split_target = 1
            var gh: ptr_uint = 0
            while gh < program.globals.len:
                unsafe:
                    c_backend.emit_line(e, c_backend.render_global_extern(read(program.globals.data + gh)))
                gh += 1
            e.split_target = 2
            var gd: ptr_uint = 0
            while gd < program.globals.len:
                unsafe:
                    c_backend.emit_line(e, c_backend.render_global_definition(ref_of(e), read(program.globals.data + gd)))
                gd += 1
            e.split_target = 1
        else:
            var gi: ptr_uint = 0
            while gi < program.globals.len:
                unsafe:
                    let g = read(program.globals.data + gi)
                    c_backend.emit_line(e, c_backend.render_global(e, g))
                gi += 1
        c_backend.emit_line(e, "")

    # Top-level static asserts, evaluated by the C compiler.  Emitted after all
    # type definitions so `sizeof` over user structs sees complete types.
    if program.static_asserts.len > 0:
        if e.split_mode:
            e.split_target = 2
        var sai: ptr_uint = 0
        while sai < program.static_asserts.len:
            unsafe:
                let assertion = read(program.static_asserts.data + sai)
                c_backend.emit_line(e, c_backend.render_static_assert(e, assertion.condition, assertion.message))
            sai += 1
        c_backend.emit_line(e, "")
        if e.split_mode:
            e.split_target = 1

    # Emit str_buffer runtime helpers if any str_buffer struct is present.
    if c_backend.has_str_buffer_structs(program):
        c_backend.emit_str_buffer_helpers(e)

    # Emit the argv → span[str] entry bridge helpers when the entry point uses them.
    if use_entry_argv:
        c_backend.emit_entry_argv_helpers(e)
    i = 0
    if e.split_mode:
        e.split_target = 3
    while i < funcs.len:
        unsafe:
            let f = read(funcs.data + i)
            if e.split_mode:
                var module_name = program.module_name
                match f.source_module:
                    Option.some as owner:
                        module_name = owner.value
                    Option.none:
                        pass
                if module_name.len == 0:
                    module_name = "program"
                e.split_unit_index = c_backend.split_unit_index_for(e, module_name)
            c_backend.emit_function(e, f, export_public, e.split_mode)
        if i < funcs.len - 1:
            c_backend.emit_line(e, "")
        i += 1

# =============================================================================
#  String helpers
# =============================================================================
