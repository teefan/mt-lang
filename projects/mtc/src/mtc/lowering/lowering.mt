## Lowering stage — transforms the semantically-checked `Program` into an
## `ir.Program`.  This is the decoupled middle-end: it reads only the loader's
## retained per-module `Analysis` values and emits `ir`, never reaching into the
## C backend.
##
## Mirrors the Ruby Lowering entry (lib/milk_tea/core/lowering.rb `Lowering.lower`),
## its C-name mangling (lowering/utils.rb), and root-main entry-point synthesis
## (lowering/async.rb `build_root_main_entrypoint`).
##
## PHASE 1 scope: a single (root) module of plain, non-generic, non-async
## functions over scalar types — enough to lower `function main() -> int:
## return <expr>` with integer/bool literals, identifiers, unary/binary
## operators, local `let`/`var` bindings, and direct function calls.  Structs,
## generics, control flow, and multi-module assembly arrive in later phases.
##
## Because the self-host analyzer does not yet produce Ruby's rich
## FunctionBinding objects (plan prerequisite #3), lowering here walks the AST
## directly and resolves types from the retained `Analysis` (`functions` sigs and
## `resolved_expr_types`).

import std.vec as vec
import std.map as map_mod
import std.str
import std.string as string
import std.fmt as fmt
import std.mem.heap as heap_mod

import mtc.ir as ir
import mtc.loader.module_loader as loader
import mtc.semantic.analyzer as analyzer
import mtc.semantic.types as types
import mtc.parser.ast as ast
import mtc.c_naming as naming


## A lowering-stage error.  Placeholder for Phase 1+, where lowering will fail
## loudly on unresolved (`ty_error`) nodes rather than emit a guessed type.
public struct LoweringError:
    message: str
    line: ptr_uint
    column: ptr_uint
    path: str


## A local/parameter binding in scope during function-body lowering: the source
## name, its C linkage name, resolved type, and whether it is held by pointer.
struct LocalBinding:
    name: str
    c_name: str
    ty: types.Type
    pointer: bool


## A foreign function's lowering info: the C function it maps to, its return
## type, and its declared parameters (carrying `as cstr` boundary projections).
struct ForeignInfo:
    c_name: str
    return_ty: types.Type
    params: span[ast.ForeignParam]


## One arm of a variant, as needed by lowering: its name, payload field names and
## resolved types (empty for a no-payload arm).  The discriminant index is the
## arm's position in the owning `VariantInfo.arms`.
struct VariantArmInfo:
    name: str
    field_names: span[str]
    field_types: span[types.Type]


## Lowering-time info for a declared variant: its arms in declaration order (so a
## match/`is` can map an arm name to its discriminant index) plus the owning
## module (for cross-module resolution).
struct VariantInfo:
    module_name: str
    arms: span[VariantArmInfo]


## lower the expressions eagerly, deferring monomorphization to the worklist pass.
struct PendingSpecialization:
    module_name: str
    callee_name: str
    type_params: span[ast.TypeParam]
    type_args: span[ast.TypeArgument]
    args: span[ast.Argument]
    call_ep: ptr[ast.Expr]
    ast_function_decl: ptr[ast.Decl]


struct LowerCtx:
    module_name: str
    analysis: analyzer.Analysis
    locals: vec.Vec[LocalBinding]
    temp_counter: ptr_uint
    foreign_map: map_mod.Map[str, ForeignInfo]
    extern_map: map_mod.Map[str, str]
    function_returns: map_mod.Map[str, types.Type]
    # Same-module variant declarations, keyed by variant name, so arm
    # constructors and match arms can resolve discriminants and payload fields.
    variants: map_mod.Map[str, VariantInfo]
    # Shared across all modules: function return types keyed by C linkage name,
    # so cross-module calls (`mod.func(...)`) can resolve their result type.
    # Borrowed pointer into the map owned by `lower`.
    # Per-module counter for `__mt_match_N` labels in struct-pattern (if/goto)
    # variant matches; mirrors Ruby's @match_label_counter.
    match_label_counter: ptr_uint
    program_returns: ptr[map_mod.Map[str, types.Type]]
    # Specialization worklist: entries for generic function calls encountered
    # during lowering, processed after all root modules are lowered.
    pending_specializations: vec.Vec[PendingSpecialization]
    # Cache of already-monomorphized generic function bodies, keyed by the
    # specialization's qualified C name (e.g. "lib_first_int").
    specialization_cache: map_mod.Map[str, ir.Function]
    # Concrete generic struct declarations emitted during lowering, keyed by C
    # type name.  When a `Pair[int, int](...)` constructor is lowered, the
    # concrete struct decl (with resolved field types) is recorded here so it can
    # be appended to the module's structs span.
    generic_struct_decls: map_mod.Map[str, ir.StructDecl]
    # Map from a concrete struct's qualified C name (`std_vec_Vec_int`) to the
    # generic struct instance info (owner module, name, type args), enabling
    # method resolution on variables whose type has been collapsed to
    # `ty_named` by the C backend qualification pass.
    generic_struct_instances: map_mod.Map[str, GenericReceiver]
    # All module analyses in dependency order, for cross-module lookups.
    program_analyses: span[analyzer.Analysis]
    # Raw loaded modules with parsed source files, for cross-module generic
    # function lookups. The analysis copies are occasionally incomplete
    # (mirroring Ruby's @ctx.imports ModuleBinding access).
    loaded_modules: span[loader.LoadedModule]
    # Set of specialization keys currently being lowered, used to detect cyclic
    # generic instantiations (A[T] calls B[T] calls A[T] in monomorphized
    # bodies).
    spec_in_progress: map_mod.Map[str, bool]
    # Active type-parameter substitution during monomorphized body lowering.
    # Always points to a valid map (empty during normal lowering, populated
    # during monomorphized function lowering).
    type_substitution: map_mod.Map[str, types.Type]
    # Proc counter for synthetic invoke/release/retain function names.
    proc_counter: ptr_uint
    # Pending synthetic functions (invoke/release/retain) emitted during
    # proc lowering, to be appended after the main module iteration.
    pending_synthetic_functions: vec.Vec[ir.Function]
    # Pending capture-env structs for capturing procs.
    pending_env_structs: vec.Vec[ir.StructDecl]
    # Pending dyn struct types (mt_dyn_{iface}) and vtable artifacts.
    pending_dyn_structs: vec.Vec[ir.StructDecl]
    pending_dyn_vtable_structs: vec.Vec[ir.StructDecl]
    pending_dyn_wrappers: vec.Vec[ir.Function]
    pending_dyn_constants: vec.Vec[ir.Constant]
    dyn_generated_vtables: map_mod.Map[str, bool]
    # str_buffer[N] struct type cache: N → struct_linkage_name
    str_buffer_structs: map_mod.Map[str, str]
    # Event runtime: per-event-type synthetic info (capacity, payload, linkage names).
    event_runtimes: map_mod.Map[str, EventRuntimeInfo]
    # Pending synthetic declarations emitted during event lowering, appended after
    # the main module iteration.
    pending_event_structs: vec.Vec[ir.StructDecl]
    pending_event_functions: vec.Vec[ir.Function]
    # Pending generic variant declarations emitted during type qualification.
    pending_generic_variants: vec.Vec[ir.VariantDecl]
    # Emitted-once guards for shared runtime types.
    subscription_emitted: bool
    event_error_emitted: bool


## Per-event runtime linkage information.  Each declared `event Name[N]`
## produces one of these; it drives the synthetic slot struct, event struct,
## and runtime functions (subscribe / subscribe_once / unsubscribe / emit).
struct EventRuntimeInfo:
    name: str
    linkage_name: str
    capacity: ptr_uint
    has_payload: bool
    payload_type: types.Type
    slot_c_name: str
    event_c_name: str
    subscribe_c_name: str
    subscribe_once_c_name: str
    unsubscribe_c_name: str
    emit_c_name: str


# =============================================================================
#  str_buffer[N] builtin struct
# =============================================================================

## Ensure a str_buffer[N] struct declaration is registered.  The struct has fields
## { data: array[char, N+1]; len: ptr_uint; dirty: bool }.  N is a literal integer
## encoded as ty_literal_int.  Only emits once per N.
function ensure_str_buffer_struct(ctx: ref[LowerCtx], sb_ty: types.Type) -> void:
    # Extract the string representation of the capacity arg from ty_generic("str_buffer", [N]).
    var n_str = "?"
    match sb_ty:
        types.Type.ty_generic as g:
            if g.args.len >= 1:
                unsafe:
                    n_str = types.type_to_string(read(g.args.data + 0))
        _:
            pass
    let c_name = j3("mt_str_buffer_", n_str, "")
    if ctx.str_buffer_structs.contains(c_name):
        return
    ctx.str_buffer_structs.set(c_name, c_name)
    var capacity: ptr_uint = 64z
    var fields = vec.Vec[ir.Field].create()
    let char_ty = types.primitive("char")
    let ptr_uint_ty = types.primitive("ptr_uint")
    let bool_ty = types.primitive("bool")
    var data_ty = types.Type.ty_generic(name = "array", args = sp_type2(char_ty, types.literal_int(65)))
    fields.push(ir.Field(name = "data", ty = data_ty))
    fields.push(ir.Field(name = "len", ty = ptr_uint_ty))
    fields.push(ir.Field(name = "dirty", ty = bool_ty))
    ctx.pending_env_structs.push(ir.StructDecl(
        name = c_name, linkage_name = c_name,
        fields = fields.as_span(), packed = false, alignment = 0,
        source_module = Option[str].none,
    ))

## Lower a checked program to IR.  Every non-external module is lowered in
## dependency-first order (the root module is the last retained analysis) and the
## fragments are concatenated into one program — mirroring Ruby's
## `lower_modules` / `assemble_modules`.
public function lower(program: loader.Program) -> ir.Program:
    let count = program.analyses.len()
    if count == 0:
        return ir.empty_program("(anonymous)", "")
    let root_ptr = program.analyses.get(count - 1) else:
        return ir.empty_program("(anonymous)", "")
    var root = unsafe: read(root_ptr)
    let root_name = root.module_name

    # Shared cross-module function return types, keyed by C linkage name, so a
    # `mod.func(...)` call in one module can resolve the result type of a
    # function defined in another.
    var program_returns = map_mod.Map[str, types.Type].create()
    collect_program_returns(program, ref_of(program_returns))

    var constants = vec.Vec[ir.Constant].create()
    var globals = vec.Vec[ir.Global].create()
    var opaques = vec.Vec[ir.OpaqueDecl].create()
    var structs = vec.Vec[ir.StructDecl].create()
    var unions = vec.Vec[ir.UnionDecl].create()
    var enums = vec.Vec[ir.EnumDecl].create()
    var variants = vec.Vec[ir.VariantDecl].create()
    var static_asserts = vec.Vec[ir.StaticAssert].create()
    var functions = vec.Vec[ir.Function].create()

    var i: ptr_uint = 0
    var seen_structs = map_mod.Map[str, bool].create()
    var seen_variants = map_mod.Map[str, bool].create()
    var seen_functions = map_mod.Map[str, bool].create()
    while i < count:
        let a_ptr = program.analyses.get(i) else:
            i += 1
            continue
        var analysis = unsafe: read(a_ptr)
        if is_raw_module(analysis.module_kind):
            i += 1
            continue
        let is_root = i == count - 1
        var fragment = lower_module(analysis, ref_of(program_returns), is_root, program.analyses.as_span(), program.modules.as_span())
        globals.append_span(fragment.globals)
        opaques.append_span(fragment.opaques)
        dedup_append_structs(ref_of(structs), fragment.structs, ref_of(seen_structs))
        unions.append_span(fragment.unions)
        enums.append_span(fragment.enums)
        dedup_append_variants(ref_of(variants), fragment.variants, ref_of(seen_variants))
        static_asserts.append_span(fragment.static_asserts)
        constants.append_span(fragment.constants)
        dedup_append_functions(ref_of(functions), fragment.functions, ref_of(seen_functions))
        i += 1

    return ir.Program(
        module_name = root_name,
        includes = base_includes(),
        constants = constants.as_span(),
        globals = globals.as_span(),
        opaques = opaques.as_span(),
        structs = structs.as_span(),
        unions = unions.as_span(),
        enums = enums.as_span(),
        variants = variants.as_span(),
        static_asserts = static_asserts.as_span(),
        functions = functions.as_span(),
        source_path = "",
    )


## True when a module is an external (`raw`) file, which has no lowerable body.
function is_raw_module(kind: ast.ModuleKind) -> bool:
    match kind:
        ast.ModuleKind.module_raw:
            return true
        _:
            return false


## Append structs, deduplicating by linkage_name.
function dedup_append_structs(sink: ref[vec.Vec[ir.StructDecl]], src: span[ir.StructDecl], seen: ref[map_mod.Map[str, bool]]) -> void:
    var i: ptr_uint = 0
    while i < src.len:
        let sd = unsafe: read(src.data + i)
        if not seen.contains(sd.linkage_name):
            seen.set(sd.linkage_name, true)
            sink.push(sd)
        i += 1


## Append variants, deduplicating by linkage_name.
function dedup_append_variants(sink: ref[vec.Vec[ir.VariantDecl]], src: span[ir.VariantDecl], seen: ref[map_mod.Map[str, bool]]) -> void:
    var i: ptr_uint = 0
    while i < src.len:
        let vd = unsafe: read(src.data + i)
        if not seen.contains(vd.linkage_name):
            seen.set(vd.linkage_name, true)
            sink.push(vd)
        i += 1


## Append functions, deduplicating by linkage_name.  Monomorphized generic
## methods carry owner-module-qualified names (e.g. `std_vec_Vec_int_push`), so
## the same specialization reached from multiple caller modules is emitted once.
function dedup_append_functions(sink: ref[vec.Vec[ir.Function]], src: span[ir.Function], seen: ref[map_mod.Map[str, bool]]) -> void:
    var i: ptr_uint = 0
    while i < src.len:
        let func_decl = unsafe: read(src.data + i)
        if not seen.contains(func_decl.linkage_name):
            seen.set(func_decl.linkage_name, true)
            sink.push(func_decl)
        i += 1


## Search a module's analysis for a function declaration by name.  Returns
## `Option.none` when the function is not found in that module.
function find_function_decl(name: str, module_analysis: analyzer.Analysis) -> Option[ast.Decl]:
    var di: ptr_uint = 0
    while di < module_analysis.source_file.declarations.len:
        var d: ast.Decl
        unsafe:
            d = read(module_analysis.source_file.declarations.data + di)
        match d:
            ast.Decl.decl_function as f:
                if f.name.equal(name):
                    return Option[ast.Decl].some(value = d)
            _:
                pass
        di += 1
    return Option[ast.Decl].none


## Search a module analysis for a function by name (used by the cross-module
## specialization fallback).  Mirrors `find_function_decl`.
function search_func_in_analysis(name: str, a: analyzer.Analysis) -> Option[ast.Decl]:
    var di: ptr_uint = 0
    while di < a.source_file.declarations.len:
        var d: ast.Decl
        unsafe:
            d = read(a.source_file.declarations.data + di)
        match d:
            ast.Decl.decl_function as f:
                if f.name.equal(name):
                    return Option[ast.Decl].some(value = d)
            _:
                pass
        di += 1
    return Option[ast.Decl].none


## Search a source file's declarations for a function by name.  Unlike
## the analysis-based helpers, this reads the raw parsed source file directly.
function find_func_in_source(sf: ast.SourceFile, name: str) -> Option[ast.Decl]:
    var di: ptr_uint = 0
    while di < sf.declarations.len:
        var d: ast.Decl
        unsafe:
            d = read(sf.declarations.data + di)
        match d:
            ast.Decl.decl_function as f:
                if f.name.equal(name):
                    return Option[ast.Decl].some(value = d)
            _:
                pass
        di += 1
    return Option[ast.Decl].none


## Find an imported module's analysis by its module name.  The `program_analyses`
## span is in dependency-first order; returns the first analysis whose
## `module_name` matches.
function find_imported_analysis(ctx: ref[LowerCtx], module_name: str) -> Option[analyzer.Analysis]:
    var i: ptr_uint = 0
    while i < ctx.program_analyses.len:
        var a: analyzer.Analysis
        unsafe:
            a = read(ctx.program_analyses.data + i)
        if a.module_name.equal(module_name):
            return Option[analyzer.Analysis].some(value = a)
        i += 1
    return Option[analyzer.Analysis].none


## True when `name` is a struct declared in any loaded module — searches the
## current module first, then imported modules, so generics that reference
## structs from other modules resolve during monomorphisation.
function struct_exists_in_imports(ctx: ref[LowerCtx], name: str) -> bool:
    if ctx.analysis.structs.contains(name):
        return true
    # Check imported modules.
    var import_values = ctx.analysis.imports.values()
    while true:
        let target_ptr = import_values.next() else:
            break
        let target_module = unsafe: read(target_ptr)
        match find_imported_analysis(ctx, target_module):
            Option.some as imported:
                if imported.value.structs.contains(name):
                    return true
            Option.none:
                pass
    return false


# =============================================================================
#  Monomorphized function lowering
# =============================================================================

## Lower a function body with type-parameter substitution applied: every reference
## to a type param (e.g. `T`) in locals, expressions, and the return type is
## replaced by the corresponding concrete type from `sub`.
function lower_specialized_function(ctx: ref[LowerCtx], name: str, params: span[ast.Param], return_type: ptr[ast.TypeRef]?, body: ptr[ast.Stmt]?, sub: ref[map_mod.Map[str, types.Type]]) -> ir.Function:
    # Reset function-level state
    ctx.locals.clear()
    ctx.temp_counter = 0
    ctx.function_returns.clear()
    var ir_params = vec.Vec[ir.Param].create()
    var pi: ptr_uint = 0
    while pi < params.len:
        var p: ast.Param
        unsafe:
            p = read(params.data + pi)
        let p_ty = substitute_type_params(ctx, resolve_field_type_ref(ctx, p.param_type), sub)
        let p_c = c_local_name(p.name)
        let p_ptr = is_pointer_or_ref_type(p_ty)
        ir_params.push(ir.Param(name = p.name, linkage_name = p_c, ty = p_ty, pointer = p_ptr))
        ctx.locals.push(LocalBinding(name = p.name, c_name = p_c, ty = p_ty, pointer = p_ptr))
        pi += 1
    # For return type, use `resolve_field_type_ref` (which returns ty_named for
    # type params) rather than `resolve_type_ref` (which returns ty_error for
    # names not in type_names).  Type params are added to the type scope per
    # function body, not to the global type_names map.
    let ret_ty = if return_type != null: substitute_type_params(ctx, resolve_field_type_ref(ctx, unsafe: read(return_type)), sub) else: types.primitive("void")
    var saved_sub = ctx.type_substitution
    ctx.type_substitution = read(sub)
    let body_ir = lower_block(ctx, body)
    ctx.type_substitution = saved_sub
    return ir.Function(
        name = name,
        linkage_name = name,
        params = ir_params.as_span(),
        return_type = ret_ty,
        body = body_ir,
        entry_point = false,
        method_receiver_param = false,
    )


## Replace type-parameter references (`ty_var`) in a type with their concrete
## values from the substitution map.  Other type variants pass through unchanged.
function substitute_type_params(ctx: ref[LowerCtx], ty: types.Type, sub: ref[map_mod.Map[str, types.Type]]) -> types.Type:
    match ty:
        types.Type.ty_var as v:
            let concrete = sub.get(v.name)
            if concrete != null:
                return unsafe: read(concrete)
            return ty
        types.Type.ty_imported as im:
            let concrete = sub.get(im.name)
            if concrete != null:
                return unsafe: read(concrete)
            if im.args.len > 0:
                var args = vec.Vec[types.Type].create()
                var i: ptr_uint = 0
                while i < im.args.len:
                    unsafe:
                        args.push(substitute_type_params(ctx, read(im.args.data + i), sub))
                    i += 1
                return types.Type.ty_imported(module_name = im.module_name, name = im.name, args = args.as_span())
            return ty
        types.Type.ty_named as n:
            let concrete = sub.get(n.name)
            if concrete != null:
                return unsafe: read(concrete)
            return ty
        types.Type.ty_generic as g:
            var args = vec.Vec[types.Type].create()
            var i: ptr_uint = 0
            while i < g.args.len:
                unsafe:
                    args.push(substitute_type_params(ctx, read(g.args.data + i), sub))
                i += 1
            return types.Type.ty_generic(name = g.name, args = args.as_span())
        types.Type.ty_nullable as nl:
            return types.Type.ty_nullable(base = types.alloc_type(substitute_type_params(ctx, unsafe: read(nl.base), sub)))
        _:
            return ty


## Pre-scan every module's function declarations and record each one's resolved
## return type keyed by its C linkage name, so cross-module calls can look them
## up regardless of lowering order.
function collect_program_returns(program: loader.Program, sink: ref[map_mod.Map[str, types.Type]]) -> void:
    var mi: ptr_uint = 0
    while mi < program.analyses.len():
        let a_ptr = program.analyses.get(mi) else:
            mi += 1
            continue
        var analysis = unsafe: read(a_ptr)
        if is_raw_module(analysis.module_kind):
            mi += 1
            continue
        var ctx = LowerCtx(
            module_name = analysis.module_name,
            analysis = analysis,
            locals = vec.Vec[LocalBinding].create(),
            temp_counter = 0,
            foreign_map = map_mod.Map[str, ForeignInfo].create(),
            extern_map = map_mod.Map[str, str].create(),
            function_returns = map_mod.Map[str, types.Type].create(),
            variants = map_mod.Map[str, VariantInfo].create(),
            match_label_counter = 0,
            program_returns = ptr_of(read(sink)),
            pending_specializations = vec.Vec[PendingSpecialization].create(),
            specialization_cache = map_mod.Map[str, ir.Function].create(),
            generic_struct_decls = map_mod.Map[str, ir.StructDecl].create(),
            generic_struct_instances = map_mod.Map[str, GenericReceiver].create(),
            program_analyses = program.analyses.as_span(),
            loaded_modules = program.modules.as_span(),
            spec_in_progress = map_mod.Map[str, bool].create(),
            type_substitution = map_mod.Map[str, types.Type].create(),
            proc_counter = 0,
            pending_synthetic_functions = vec.Vec[ir.Function].create(),
            pending_env_structs = vec.Vec[ir.StructDecl].create(),
            pending_dyn_structs = vec.Vec[ir.StructDecl].create(),
            pending_dyn_vtable_structs = vec.Vec[ir.StructDecl].create(),
            pending_dyn_wrappers = vec.Vec[ir.Function].create(),
            pending_dyn_constants = vec.Vec[ir.Constant].create(),
            dyn_generated_vtables = map_mod.Map[str, bool].create(),
            str_buffer_structs = map_mod.Map[str, str].create(),
            event_runtimes = map_mod.Map[str, EventRuntimeInfo].create(),
            pending_event_structs = vec.Vec[ir.StructDecl].create(),
            pending_event_functions = vec.Vec[ir.Function].create(),
            pending_generic_variants = vec.Vec[ir.VariantDecl].create(),
            subscription_emitted = false,
            event_error_emitted = false,
        )
        var di: ptr_uint = 0
        while di < analysis.source_file.declarations.len:
            var d: ast.Decl
            unsafe:
                d = read(analysis.source_file.declarations.data + di)
            match d:
                ast.Decl.decl_function as fun:
                    let ret = resolve_return_type(ref_of(ctx), lookup_fn_sig(ref_of(ctx), fun.name), fun.return_type)
                    sink.set(naming.qualified_c_name(analysis.module_name, fun.name), ret)
                _:
                    pass
            di += 1
        mi += 1


function lower_module(analysis: analyzer.Analysis, program_returns: ref[map_mod.Map[str, types.Type]], is_root: bool, program_analyses: span[analyzer.Analysis], loaded_modules: span[loader.LoadedModule]) -> ir.Program:
    var ctx = LowerCtx(
        module_name = analysis.module_name,
        analysis = analysis,
        locals = vec.Vec[LocalBinding].create(),
        temp_counter = 0,
        foreign_map = map_mod.Map[str, ForeignInfo].create(),
        extern_map = map_mod.Map[str, str].create(),
        function_returns = map_mod.Map[str, types.Type].create(),
        variants = map_mod.Map[str, VariantInfo].create(),
        match_label_counter = 0,
        program_returns = ptr_of(read(program_returns)),
        pending_specializations = vec.Vec[PendingSpecialization].create(),
        specialization_cache = map_mod.Map[str, ir.Function].create(),
        generic_struct_decls = map_mod.Map[str, ir.StructDecl].create(),
        generic_struct_instances = map_mod.Map[str, GenericReceiver].create(),
        program_analyses = program_analyses,
        loaded_modules = loaded_modules,
        spec_in_progress = map_mod.Map[str, bool].create(),
        type_substitution = map_mod.Map[str, types.Type].create(),
        proc_counter = 0,
        pending_synthetic_functions = vec.Vec[ir.Function].create(),
        pending_env_structs = vec.Vec[ir.StructDecl].create(),
        pending_dyn_structs = vec.Vec[ir.StructDecl].create(),
        pending_dyn_vtable_structs = vec.Vec[ir.StructDecl].create(),
        pending_dyn_wrappers = vec.Vec[ir.Function].create(),
        pending_dyn_constants = vec.Vec[ir.Constant].create(),
        dyn_generated_vtables = map_mod.Map[str, bool].create(),
        str_buffer_structs = map_mod.Map[str, str].create(),
        event_runtimes = map_mod.Map[str, EventRuntimeInfo].create(),
        pending_event_structs = vec.Vec[ir.StructDecl].create(),
        pending_event_functions = vec.Vec[ir.Function].create(),
        pending_generic_variants = vec.Vec[ir.VariantDecl].create(),
        subscription_emitted = false,
        event_error_emitted = false,
    )
    collect_foreign_functions(ref_of(ctx), analysis.source_file.declarations)
    collect_function_returns(ref_of(ctx), analysis.source_file.declarations)
    collect_variants(ref_of(ctx), analysis.source_file.declarations)
    install_prelude_variants(ref_of(ctx))
    var functions = vec.Vec[ir.Function].create()
    var enums = vec.Vec[ir.EnumDecl].create()
    var structs = vec.Vec[ir.StructDecl].create()
    var unions = vec.Vec[ir.UnionDecl].create()
    var variants = vec.Vec[ir.VariantDecl].create()
    var globals = vec.Vec[ir.Global].create()
    var constants = vec.Vec[ir.Constant].create()

    var i: ptr_uint = 0
    while i < analysis.source_file.declarations.len:
        var d: ast.Decl
        unsafe:
            d = read(analysis.source_file.declarations.data + i)
        match d:
            ast.Decl.decl_function as fun:
                if lowerable_function(fun.is_async, fun.is_const, fun.type_params, fun.body):
                    functions.push(lower_function(ref_of(ctx), fun.name, fun.method_params, fun.return_type, fun.body))
                    if is_root and fun.name.equal("main"):
                        match build_root_main_entrypoint(ref_of(ctx), fun.name, fun.method_params):
                            Option.some as entry:
                                functions.push(entry.value)
                            Option.none:
                                pass
            ast.Decl.decl_enum as en:
                enums.push(lower_enum_decl(ref_of(ctx), en.name, en.backing_type, en.enum_members, false))
            ast.Decl.decl_flags as fl:
                enums.push(lower_enum_decl(ref_of(ctx), fl.name, fl.backing_type, fl.flags_members, true))
            ast.Decl.decl_struct as s:
                # Skip generic structs — only their concrete specializations
                # (emitted by `ensure_generic_struct_decl`) carry resolved
                # field types.
                if s.type_params.len == 0:
                    match lower_struct_decl(ref_of(ctx), s.name):
                        Option.some as sd:
                            structs.push(sd.value)
                        Option.none:
                            pass
            ast.Decl.decl_union as u:
                unions.push(lower_union_decl(ref_of(ctx), u.name, u.union_fields))
            ast.Decl.decl_variant as vr:
                if vr.type_params.len == 0:
                    variants.push(lower_variant_decl(ref_of(ctx), vr.name, vr.variant_arms))
            ast.Decl.decl_extending_block as ex:
                lower_extending_block(ctx, ref_of(functions), ex.type_name, ex.methods)
            ast.Decl.decl_var as v:
                var g_ty = types.primitive("void")
                if v.var_type != null:
                    var vt: ptr[ast.TypeRef] = unsafe: ptr[ast.TypeRef]<-v.var_type
                    g_ty = resolve_type_ref(ctx, vt)
                let zero_val = alloc_expr(ir.Expr.expr_zero_init(ty = g_ty))
                globals.push(ir.Global(name = v.name, linkage_name = naming.qualified_c_name(ctx.module_name, v.name), ty = g_ty, value = zero_val))
            ast.Decl.decl_const as c:
                var c_ty = resolve_type_ref(ctx, c.const_type)
                let c_val = lower_expr(ctx, unsafe: ptr[ast.Expr]<-c.value)
                constants.push(ir.Constant(name = c.name, linkage_name = naming.qualified_c_name(ctx.module_name, c.name), ty = c_ty, value = c_val))
            ast.Decl.decl_event as ev:
                ensure_event_runtime(ctx, ev.name)
                let ev_ty = types.Type.ty_named(name = naming.qualified_c_name(ctx.module_name, ev.name))
                let ev_zero = alloc_expr(ir.Expr.expr_zero_init(ty = ev_ty))
                globals.push(ir.Global(name = ev.name, linkage_name = ev.name, ty = ev_ty, value = ev_zero))
            _:
                pass
        i += 1

    # Prepend generic struct declarations so they appear before the module's
    # own structs that may reference them as by-value fields.
    var pending_generic_structs = vec.Vec[ir.StructDecl].create()
    var gs_iter = ctx.generic_struct_decls.values()
    while true:
        let gs_ptr = gs_iter.next() else:
            break
        pending_generic_structs.push(unsafe: read(gs_ptr))
    var pre_gi = pending_generic_structs.len()
    while pre_gi > 0:
        pre_gi -= 1
        let s_ptr = pending_generic_structs.get(pre_gi) else:
            continue
        let insert_at: ptr_uint = 0
        let _inserted = structs.insert(insert_at, unsafe: read(s_ptr))

    # Append any monomorphized generic functions from the specialization cache.
    var spec_iter = ctx.specialization_cache.values()
    while true:
        let spec_ptr = spec_iter.next() else:
            break
        functions.push(unsafe: read(spec_ptr))

    # Append any pending synthetic proc functions and capture-env structs.
    var sf_iter = ctx.pending_synthetic_functions.iter()
    while true:
        let sf_ptr = sf_iter.next() else:
            break
        functions.push(unsafe: read(sf_ptr))
    var es_iter = ctx.pending_env_structs.iter()
    while true:
        let es_ptr = es_iter.next() else:
            break
        structs.push(unsafe: read(es_ptr))

    var ds_iter = ctx.pending_dyn_structs.iter()
    while true:
        let ds_ptr = ds_iter.next() else:
            break
        structs.push(unsafe: read(ds_ptr))
    var dvs_iter = ctx.pending_dyn_vtable_structs.iter()
    while true:
        let dvs_ptr = dvs_iter.next() else:
            break
        structs.push(unsafe: read(dvs_ptr))
    var dw_index: ptr_uint = 0
    while dw_index < ctx.pending_dyn_wrappers.len():
        let dw_ptr = ctx.pending_dyn_wrappers.get(dw_index) else:
            break
        functions.push(unsafe: read(dw_ptr))
        dw_index += 1

    var dyn_constants = vec.Vec[ir.Constant].create()
    var dci: ptr_uint = 0
    while dci < ctx.pending_dyn_constants.len():
        let dc_ptr = ctx.pending_dyn_constants.get(dci) else:
            break
        dyn_constants.push(unsafe: read(dc_ptr))
        dci += 1

    var ev_struct_index: ptr_uint = 0
    while ev_struct_index < ctx.pending_event_structs.len():
        let es_ptr = ctx.pending_event_structs.get(ev_struct_index) else:
            break
        structs.push(unsafe: read(es_ptr))
        ev_struct_index += 1
    var ev_func_index: ptr_uint = 0
    while ev_func_index < ctx.pending_event_functions.len():
        let ef_ptr = ctx.pending_event_functions.get(ev_func_index) else:
            break
        functions.push(unsafe: read(ef_ptr))
        ev_func_index += 1

    # Prepend pending generic variant declarations so they appear before
    # structs that embed them as by-value fields.
    var gv_index = ctx.pending_generic_variants.len()
    while gv_index > 0:
        gv_index -= 1
        let gv_ptr = ctx.pending_generic_variants.get(gv_index) else:
            continue
        let insert_at: ptr_uint = 0
        let _gv_inserted = variants.insert(insert_at, unsafe: read(gv_ptr))

    return ir.Program(
        module_name = analysis.module_name,
        includes = span[ir.Include](),
        constants = constants.as_span(),
        globals = globals.as_span(),
        opaques = span[ir.OpaqueDecl](),
        structs = structs.as_span(),
        unions = unions.as_span(),
        enums = enums.as_span(),
        variants = variants.as_span(),
        static_asserts = span[ir.StaticAssert](),
        functions = functions.as_span(),
        source_path = "",
    )


## Phase 1 lowers only plain, non-generic, non-async functions that have a body.
function lowerable_function(is_async: bool, is_const: bool, type_params: span[ast.TypeParam], body: ptr[ast.Stmt]?) -> bool:
    if type_params.len > 0:
        return false
    if body == null:
        return false
    return true


## The base C runtime includes for an ordinary module.  `<stdio.h>` is always
## present because the Ruby compiler's prelude (Option/Result) references
## `fatal`, making it universal there; the self-host matches that for byte
## parity.  Conditional `<stddef.h>` (offsetof) / `<stdlib.h>` (fatal) arrive in
## later phases.
function base_includes() -> span[ir.Include]:
    var includes = vec.Vec[ir.Include].create()
    includes.push(ir.Include(header = "<stdbool.h>"))
    includes.push(ir.Include(header = "<stdint.h>"))
    includes.push(ir.Include(header = "<string.h>"))
    includes.push(ir.Include(header = "<stdio.h>"))
    return includes.as_span()


# =============================================================================
#  Function lowering
# =============================================================================

## Lower all methods in an extending block to IR functions.  Each method becomes
## a C function with the receiver as the first parameter (pointer for editable,
## by value for plain, omitted for static).
function lower_extending_block(ctx: ref[LowerCtx], functions: ref[vec.Vec[ir.Function]], type_ref_ptr: ptr[ast.TypeRef], methods: span[ast.Method]) -> void:
    var type_name: str
    unsafe:
        let type_ref = read(type_ref_ptr)
        type_name = read(type_ref.name.parts.data + 0)
    # Skip generic extending blocks (e.g. `extending Vec[T]:`) — their methods
    # are monomorphized by `lower_monomorphized_call` when concrete calls occur.
    if unsafe: read(type_ref_ptr).arguments.len > 0:
        return
    var mi: ptr_uint = 0
    while mi < methods.len:
        var m: ast.Method
        unsafe:
            m = read(methods.data + mi)
        if m.is_async or m.type_params.len > 0:
            mi += 1
            continue
        let c_name = naming.qualified_member_c_name(ctx.module_name, type_name, m.name)
        let receiver_ty = types.Type.ty_imported(module_name = ctx.module_name, name = type_name, args = span[types.Type]())
        functions.push(lower_method(ctx, c_name, receiver_ty, m))
        mi += 1


## Lower a single method to an IR function.  The receiver (`this`) is bound as a
## local parameter (pointer for editable methods, value for plain).
function lower_method(ctx: ref[LowerCtx], c_name: str, receiver_ty: types.Type, m: ast.Method) -> ir.Function:
    ctx.locals.clear()
    ctx.temp_counter = 0
    let sig = lookup_fn_sig(ctx, m.name)

    var ir_params = vec.Vec[ir.Param].create()
    if m.method_kind != ast.MethodKind.mk_static:
        let recv_ty = if m.method_kind == ast.MethodKind.mk_editable: types.Type.ty_generic(name = "ptr", args = sp_type(receiver_ty)) else: receiver_ty
        ir_params.push(ir.Param(name = "this", linkage_name = c_local_name("this"), ty = recv_ty, pointer = false))
        ctx.locals.push(LocalBinding(name = "this", c_name = c_local_name("this"), ty = recv_ty, pointer = false))
    var pi: ptr_uint = 0
    while pi < m.method_params.len:
        var p: ast.Param
        unsafe:
            p = read(m.method_params.data + pi)
        let param_ty = resolve_param_type(ctx, sig, pi, p.param_type)
        let c_pname = c_local_name(p.name)
        let is_ptr = is_pointer_or_ref_type(param_ty)
        ir_params.push(ir.Param(name = p.name, linkage_name = c_pname, ty = param_ty, pointer = is_ptr))
        ctx.locals.push(LocalBinding(name = p.name, c_name = c_pname, ty = param_ty, pointer = is_ptr))
        pi += 1

    let ret_ty = resolve_return_type(ctx, sig, m.return_type)
    let body_stmts = lower_block(ctx, m.body)

    return ir.Function(
        name = c_name,
        linkage_name = c_name,
        params = ir_params.as_span(),
        return_type = ret_ty,
        body = body_stmts,
        entry_point = false,
        method_receiver_param = m.method_kind != ast.MethodKind.mk_static,
    )


## A single-element `span[types.Type]` convenience helper.
function sp_type(t: types.Type) -> span[types.Type]:
    var buf = vec.Vec[types.Type].create()
    buf.push(t)
    return buf.as_span()


## Sibling helpers for one-element spans of other common types.
function sp_fields(field1: ir.AggregateField) -> span[ir.AggregateField]:
    var buf = vec.Vec[ir.AggregateField].create()
    buf.push(field1)
    return buf.as_span()


function sp_fields2(f1: ir.AggregateField, f2: ir.AggregateField) -> span[ir.AggregateField]:
    var buf = vec.Vec[ir.AggregateField].create()
    buf.push(f1)
    buf.push(f2)
    return buf.as_span()


function sp_type2(t1: types.Type, t2: types.Type) -> span[types.Type]:
    var buf = vec.Vec[types.Type].create()
    buf.push(t1)
    buf.push(t2)
    return buf.as_span()


function sp_expr(expr: ptr[ir.Expr]) -> span[ir.Expr]:
    var buf = vec.Vec[ir.Expr].create()
    unsafe:
        buf.push(read(expr))
    return buf.as_span()


## A canonical string name for a concrete type, used as a vtable identifier suffix.
function canonical_type_name(module_name: str, t: types.Type) -> str:
    match t:
        types.Type.ty_primitive as p:
            return p.name
        types.Type.ty_named as n:
            var buf = string.String.create()
            buf.append(naming.module_c_prefix(module_name))
            buf.append("_")
            buf.append(n.name)
            return buf.as_str()
        types.Type.ty_imported as im:
            var buf = string.String.create()
            buf.append(naming.module_c_prefix(im.module_name))
            buf.append("_")
            buf.append(im.name)
            return buf.as_str()
        types.Type.ty_generic as g:
            var buf = string.String.create()
            buf.append(g.name)
            var i: ptr_uint = 0
            while i < g.args.len:
                buf.append("_")
                buf.append(canonical_type_name(module_name, unsafe: read(g.args.data + i)))
                i += 1
            return naming.sanitize_identifier(buf.as_str())
        types.Type.ty_str:
            return "str"
        _:
            return "unknown"


## Multi-string join helpers (mirror c_backend j2, j6).
function lower_function(ctx: ref[LowerCtx], name: str, params: span[ast.Param], return_type: ptr[ast.TypeRef]?, body: ptr[ast.Stmt]?) -> ir.Function:
    ctx.locals.clear()
    ctx.temp_counter = 0
    let sig = lookup_fn_sig(ctx, name)

    var ir_params = vec.Vec[ir.Param].create()
    var pi: ptr_uint = 0
    while pi < params.len:
        var p: ast.Param
        unsafe:
            p = read(params.data + pi)
        let param_ty = resolve_param_type(ctx, sig, pi, p.param_type)
        let c_name = c_local_name(p.name)
        let f_ptr = is_pointer_or_ref_type(param_ty)
        ir_params.push(ir.Param(name = p.name, linkage_name = c_name, ty = param_ty, pointer = f_ptr))
        ctx.locals.push(LocalBinding(name = p.name, c_name = c_name, ty = param_ty, pointer = f_ptr))
        pi += 1

    let ret_ty = resolve_return_type(ctx, sig, return_type)
    let body_stmts = lower_block(ctx, body)

    return ir.Function(
        name = name,
        linkage_name = naming.qualified_c_name(ctx.module_name, name),
        params = ir_params.as_span(),
        return_type = ret_ty,
        body = body_stmts,
        entry_point = false,
        method_receiver_param = false,
    )


## Synthesize the C entry point `int main(void)` that calls the user's root
## `main`.  Phase 1 supports only a no-parameter `main` returning `int` or
## `void` (the `:none` bridge in Ruby's build_root_main_entrypoint).
function build_root_main_entrypoint(ctx: ref[LowerCtx], name: str, params: span[ast.Param]) -> Option[ir.Function]:
    if params.len != 0:
        return Option[ir.Function].none

    let sig = lookup_fn_sig(ctx, name)
    let user_return = fn_sig_return_type(sig)
    if not (types.is_void(user_return) or is_int_type(user_return)):
        return Option[ir.Function].none

    let int_ty = types.primitive("int")
    let user_linkage = naming.qualified_c_name(ctx.module_name, name)
    let call = alloc_expr(ir.Expr.expr_call(callee = user_linkage, arguments = span[ir.Expr](), ty = user_return))

    var body = vec.Vec[ir.Stmt].create()
    if types.is_void(user_return):
        body.push(ir.Stmt.stmt_expression(expression = call, line = 0, source_path = ""))
        let zero = alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = int_ty))
        body.push(ir.Stmt.stmt_return(value = zero, line = 0, source_path = ""))
    else:
        body.push(ir.Stmt.stmt_return(value = call, line = 0, source_path = ""))

    return Option[ir.Function].some(value = ir.Function(
        name = name,
        linkage_name = "main",
        params = span[ir.Param](),
        return_type = int_ty,
        body = body.as_span(),
        entry_point = true,
        method_receiver_param = false,
    ))


# =============================================================================
#  Statement lowering
# =============================================================================

function lower_block(ctx: ref[LowerCtx], body_ptr: ptr[ast.Stmt]?) -> span[ir.Stmt]:
    var stmts = vec.Vec[ir.Stmt].create()
    let bp = body_ptr else:
        return stmts.as_span()
    unsafe:
        match read(bp):
            ast.Stmt.stmt_block as blk:
                var i: ptr_uint = 0
                while i < blk.statements.len:
                    lower_stmt(ctx, ref_of(stmts), blk.statements.data + i)
                    i += 1
            _:
                lower_stmt(ctx, ref_of(stmts), bp)
    return stmts.as_span()


function lower_stmt(ctx: ref[LowerCtx], output: ref[vec.Vec[ir.Stmt]], sp: ptr[ast.Stmt]) -> void:
    unsafe:
        match read(sp):
            ast.Stmt.stmt_ret as r:
                let value = r.value else:
                    output.push(ir.Stmt.stmt_return(value = null, line = r.line, source_path = ""))
                    return
                let lowered = lower_expr(ctx, value)
                output.push(ir.Stmt.stmt_return(value = lowered, line = r.line, source_path = ""))
            ast.Stmt.stmt_local as loc:
                match loc.destructure_bindings:
                    Option.some as binds:
                        lower_destructure(ctx, output, binds.value, loc.destructure_type_name, loc.value)
                        return
                    Option.none:
                        pass
                let init_val = loc.value
                if init_val != null:
                    unsafe:
                        match read(init_val):
                            ast.Expr.expr_match as me:
                                lower_match_expression_local(ctx, output, loc.name, loc.stmt_type, me.scrutinee, me.arms)
                                return
                            ast.Expr.expr_format_string as fs:
                                lower_format_string_local(ctx, output, loc.name, fs.parts)
                                return
                            _:
                                pass
                let c_name = c_local_name(loc.name)
                var ty: types.Type
                var value_expr: ptr[ir.Expr]
                let init = loc.value
                if init == null:
                    let declared = loc.stmt_type else:
                        fatal(c"lowering: local without initializer requires a type")
                    ty = resolve_type_ref(ctx, declared)
                    value_expr = alloc_expr(ir.Expr.expr_zero_init(ty = ty))
                else:
                    value_expr = lower_expr(ctx, init)
                    if loc.stmt_type != null:
                        ty = local_decl_type(ctx, loc.stmt_type, init)
                        if types.is_error(ty):
                            ty = ir_expr_type(value_expr)
                    else:
                        # No annotation: the lowered initializer's IR type is the
                        # authority (it already carries correct cross-module
                        # qualification), avoiding re-qualifying an imported type
                        # against the current module.
                        ty = ir_expr_type(value_expr)
                        if types.is_error(ty):
                            ty = local_decl_type(ctx, loc.stmt_type, init)
                output.push(ir.Stmt.stmt_local(
                    name = loc.name,
                    linkage_name = c_name,
                    ty = ty,
                    value = value_expr,
                    line = loc.line,
                    source_path = "",
                ))
                ctx.locals.push(LocalBinding(name = loc.name, c_name = c_name, ty = ty, pointer = false))
            ast.Stmt.stmt_assignment as asg:
                # Desugar `read(x) = value` to `*x = value`.
                var target_expr = asg.target
                match is_read_call(target_expr):
                    Option.some as inner:
                        let deref_target = lower_expr(ctx, inner.value)
                        let target = alloc_expr(ir.Expr.expr_unary(operator = "*", operand = deref_target, ty = expr_type(ctx, target_expr)))
                        let value = lower_expr(ctx, asg.value)
                        output.push(ir.Stmt.stmt_assignment(target = target, operator = asg.operator, value = value))
                        return
                    Option.none:
                        pass
                let target = lower_expr(ctx, asg.target)
                let value = lower_expr(ctx, asg.value)
                output.push(ir.Stmt.stmt_assignment(target = target, operator = asg.operator, value = value))
            ast.Stmt.stmt_while as w:
                let cond = lower_expr(ctx, w.condition)
                let body = lower_block(ctx, w.body)
                output.push(ir.Stmt.stmt_while(condition = cond, body = body))
            ast.Stmt.stmt_for as f:
                if f.threaded:
                    lower_parallel_for(ctx, output, f.bindings, f.iterables, f.body)
                    return
                lower_for_range(ctx, output, f.bindings, f.iterables, f.body)
            ast.Stmt.stmt_expression as ex:
                let lowered = lower_expr(ctx, ex.expression)
                output.push(ir.Stmt.stmt_expression(expression = lowered, line = ex.line, source_path = ""))
            ast.Stmt.stmt_when as wn:
                lower_when_stmt(ctx, output, wn.discriminant, wn.branches, wn.else_body)
            ast.Stmt.stmt_parallel_block as pb:
                lower_parallel_block(ctx, output, pb.bodies)
            ast.Stmt.stmt_gather as gth:
                lower_gather_stmt(ctx, output, gth.handles)
            ast.Stmt.stmt_pass:
                pass
            ast.Stmt.stmt_if as iff:
                if iff.is_inline:
                    lower_inline_if_statement(ctx, output, iff.branches, iff.else_body)
                    return
                if iff.branches.len > 0:
                    output.push(lower_if_chain(ctx, iff.branches, 0, iff.else_body))
            ast.Stmt.stmt_match as m:
                if m.is_inline:
                    lower_inline_match_statement(ctx, output, m.scrutinee, m.arms)
                    return
                lower_match(ctx, output, m.scrutinee, m.arms)
            ast.Stmt.stmt_break:
                output.push(ir.Stmt.stmt_break())
            ast.Stmt.stmt_continue:
                output.push(ir.Stmt.stmt_continue())
            ast.Stmt.stmt_unsafe as u:
                if u.body != null:
                    lower_stmt(ctx, output, ptr[ast.Stmt]<-u.body)
                return
            ast.Stmt.stmt_block as blk:
                var i: ptr_uint = 0
                while i < blk.statements.len:
                    unsafe:
                        lower_stmt(ctx, output, ptr[ast.Stmt]<-(blk.statements.data + i))
                    i += 1
            ast.Stmt.stmt_defer as d:
                if d.expression != null:
                    output.push(ir.Stmt.stmt_expression(
                        expression = lower_expr(ctx, ptr[ast.Expr]<-d.expression),
                        line = 0, source_path = "",
                    ))
                if d.body != null:
                    lower_stmt(ctx, output, ptr[ast.Stmt]<-d.body)
            _:
                fatal(c"lowering: unsupported statement")


## The declared type of a local (resolved from its annotation when present and
## scalar), else the inferred type of its initializer.
function local_decl_type(ctx: ref[LowerCtx], declared: ptr[ast.TypeRef]?, value: ptr[ast.Expr]) -> types.Type:
    let annotation = declared else:
        return qualify_type(ctx, expr_type(ctx, value))
    let resolved = resolve_type_ref(ctx, annotation)
    if types.is_error(resolved):
        return qualify_type(ctx, expr_type(ctx, value))
    return resolved


## Lower `let (a, b) = expr` (tuple) / `let Name(x, y) = expr` (struct) by
## evaluating the source into a temp and binding each component from it.
function lower_destructure(ctx: ref[LowerCtx], output: ref[vec.Vec[ir.Stmt]], bindings: span[str], type_name: Option[str], value: ptr[ast.Expr]?) -> void:
    let val = value else:
        fatal(c"lowering: destructuring requires an initializer")
    let lowered_val = lower_expr(ctx, val)
    let val_ty = ir_expr_type(lowered_val)
    let temp = fresh_c_temp_name(ctx, "destructure_val")
    output.push(ir.Stmt.stmt_local(name = temp, linkage_name = temp, ty = val_ty, value = lowered_val, line = 0, source_path = ""))

    var i: ptr_uint = 0
    while i < bindings.len:
        var binding: str
        unsafe:
            binding = read(bindings.data + i)
        var member_name: str
        var member_ty: types.Type
        match type_name:
            Option.some as tn:
                member_name = struct_field_name_at(ctx, tn.value, i)
                member_ty = struct_field_type_at(ctx, tn.value, i)
            Option.none:
                member_name = tuple_field_name(i)
                member_ty = tuple_element_type(val_ty, i)
        let receiver = alloc_expr(ir.Expr.expr_name(name = temp, ty = val_ty, pointer = false))
        let member = alloc_expr(ir.Expr.expr_member(receiver = receiver, member = member_name, ty = member_ty))
        let binding_c = c_local_name(binding)
        output.push(ir.Stmt.stmt_local(name = binding, linkage_name = binding_c, ty = member_ty, value = member, line = 0, source_path = ""))
        ctx.locals.push(LocalBinding(name = binding, c_name = binding_c, ty = member_ty, pointer = false))
        i += 1


function struct_field_name_at(ctx: ref[LowerCtx], struct_name: str, index: ptr_uint) -> str:
    let fields_ptr = ctx.analysis.structs.get(struct_name) else:
        return ""
    let entries = unsafe: read(fields_ptr)
    if index < entries.len:
        unsafe:
            return read(entries.data + index).name
    return ""


function struct_field_type_at(ctx: ref[LowerCtx], struct_name: str, index: ptr_uint) -> types.Type:
    let fields_ptr = ctx.analysis.structs.get(struct_name) else:
        return types.Type.ty_error
    let entries = unsafe: read(fields_ptr)
    if index < entries.len:
        unsafe:
            return qualify_type(ctx, read(entries.data + index).ty)
    return types.Type.ty_error


## Qualify a bare local named type (`ty_named`) with the current module so the
## backend can produce its module-prefixed C name (`State` -> `en_State`).
## Primitives, `str`, and already-qualified imported types pass through.
## For imported generic types with concrete args, monomorphize the struct
## declaration via `ensure_generic_struct_decl` and return a named type with
## the module-qualified concrete C name.  Recurses into generic, nullable,
## and pointer types so nested imported generics are also resolved.
## Raw type parameters (`T`, `K`, `V`, etc.) inside generic bodies are
## replaced with `void` to avoid undeclared C type names.
function qualify_type(ctx: ref[LowerCtx], t: types.Type) -> types.Type:
    match t:
        types.Type.ty_named as n:
            if is_raw_type_param_name(n.name):
                return types.primitive("void")
            # Already-monomorphized concrete names (e.g. std_map_Node_str_bool)
            # are fully qualified: pass them through so re-qualifying in a
            # different module context does not double-prefix them.
            if ctx.generic_struct_instances.contains(n.name) or ctx.generic_struct_decls.contains(n.name):
                return t
            return types.Type.ty_imported(module_name = ctx.module_name, name = n.name, args = span[types.Type]())
        types.Type.ty_imported as im:
            if is_raw_type_param_name(im.name):
                return types.primitive("void")
            var resolved_args = span[types.Type]()
            if im.args.len > 0:
                var args_vec = vec.Vec[types.Type].create()
                var ai: ptr_uint = 0
                while ai < im.args.len:
                    unsafe:
                        args_vec.push(qualify_type(ctx, read(im.args.data + ai)))
                    ai += 1
                resolved_args = args_vec.as_span()
            if resolved_args.len > 0:
                let concrete_name = naming.qualified_c_name(im.module_name, generic_struct_c_name(im.name, resolved_args))
                ensure_generic_struct_decl_named(ctx, im.name, span[ast.TypeArgument](), resolved_args, concrete_name)
                ctx.generic_struct_instances.set(concrete_name, GenericReceiver(owner_name = im.name, concrete_args = resolved_args))
                return types.Type.ty_named(name = concrete_name)
            return t
        types.Type.ty_generic as g:
            var args = vec.Vec[types.Type].create()
            var gi: ptr_uint = 0
            while gi < g.args.len:
                unsafe:
                    args.push(qualify_type(ctx, read(g.args.data + gi)))
                gi += 1
            # Monomorphize user-defined generic structs used as field types
            # (e.g. Node[str, bool] from std/map), skipping builtins handled
            # directly by the C backend.
            let resolved = try_monomorphize_generic(ctx, g.name, args.as_span())
            if not types.is_error(resolved):
                return resolved
            return types.Type.ty_generic(name = g.name, args = args.as_span())
        types.Type.ty_nullable as nl:
            return types.Type.ty_nullable(base = types.alloc_type(qualify_type(ctx, unsafe: read(nl.base))))
        _:
            return t


## When `name` is a generic struct (local or imported) with concrete args,
## monomorphize it and return the concrete `ty_named`.  Returns `ty_error` for
## builtins (ptr/span/ref/...) and unknown names — the caller should fall back
## to `ty_generic`.
function try_monomorphize_generic(ctx: ref[LowerCtx], name: str, args: span[types.Type]) -> types.Type:
    if is_builtin_pointer_generic(name):
        return types.Type.ty_error
    if name.equal("Option") or name.equal("Result"):
        return ensure_generic_variant(ctx, name, args)
    # Try current module first.
    if ctx.analysis.structs.contains(name):
        let concrete_name = naming.qualified_c_name(ctx.module_name, generic_struct_c_name(name, args))
        ensure_generic_struct_decl_named(ctx, name, span[ast.TypeArgument](), args, concrete_name)
        ctx.generic_struct_instances.set(concrete_name, GenericReceiver(owner_name = name, concrete_args = args))
        return types.Type.ty_named(name = concrete_name)
    # Try imported modules — search both public and private structs,
    # and fall back to extracting from the AST directly.
    var import_values = ctx.analysis.imports.values()
    while true:
        let target_ptr = import_values.next() else:
            break
        let target_module = unsafe: read(target_ptr)
        match find_imported_analysis(ctx, target_module):
            Option.some as imported:
                var has_struct = imported.value.structs.contains(name)
                if not has_struct:
                    has_struct = struct_in_source(imported.value, name)
                if has_struct:
                    let concrete_name = naming.qualified_c_name(target_module, generic_struct_c_name(name, args))
                    ensure_generic_struct_decl_named(ctx, name, span[ast.TypeArgument](), args, concrete_name)
                    ctx.generic_struct_instances.set(concrete_name, GenericReceiver(owner_name = name, concrete_args = args))
                    return types.Type.ty_named(name = concrete_name)
            Option.none:
                pass
    return types.Type.ty_error


## Check if a struct named `name` exists in a module's source file AST.
function struct_in_source(module_analysis: analyzer.Analysis, name: str) -> bool:
    var di: ptr_uint = 0
    while di < module_analysis.source_file.declarations.len:
        var d: ast.Decl
        unsafe:
            d = read(module_analysis.source_file.declarations.data + di)
        match d:
            ast.Decl.decl_struct as s:
                if s.name.equal(name):
                    return true
            _:
                pass
        di += 1
    return false

## Ensure a concrete variant declaration exists for `Option[T]` or `Result[T,E]`.
function ensure_generic_variant(ctx: ref[LowerCtx], name: str, args: span[types.Type]) -> types.Type:
    let c_name = generic_c_type_raw(name, args)
    var si: ptr_uint = 0
    while si < ctx.pending_generic_variants.len():
        let vp = ctx.pending_generic_variants.get(si) else:
            break
        unsafe:
            if read(vp).linkage_name.equal(c_name):
                return types.Type.ty_named(name = c_name)
        si += 1
    var arms = vec.Vec[ir.VariantArm].create()
    if name.equal("Option") and args.len >= 1:
        let elem = unsafe: read(args.data + 0)
        var sf = vec.Vec[ir.Field].create()
        sf.push(ir.Field(name = "value", ty = elem))
        arms.push(ir.VariantArm(name = "some", linkage_name = j3(c_name, "_", "some"), fields = sf.as_span()))
        arms.push(ir.VariantArm(name = "none", linkage_name = j3(c_name, "_", "none"), fields = span[ir.Field]()))
    else if name.equal("Result") and args.len >= 2:
        let ok = unsafe: read(args.data + 0)
        let err = unsafe: read(args.data + 1)
        var sf = vec.Vec[ir.Field].create()
        sf.push(ir.Field(name = "value", ty = ok))
        var ef = vec.Vec[ir.Field].create()
        ef.push(ir.Field(name = "error", ty = err))
        arms.push(ir.VariantArm(name = "success", linkage_name = j3(c_name, "_", "success"), fields = sf.as_span()))
        arms.push(ir.VariantArm(name = "failure", linkage_name = j3(c_name, "_", "failure"), fields = ef.as_span()))
    ctx.pending_generic_variants.push(ir.VariantDecl(
        name = c_name, linkage_name = c_name,
        arms = arms.as_span(), source_module = Option[str].none,
    ))
    return types.Type.ty_named(name = c_name)

## True when `name` is a pointer-like generic type handled directly by C.
function is_builtin_pointer_generic(name: str) -> bool:
    return (
        name.equal("ptr") or name.equal("const_ptr") or name.equal("ref")
        or name.equal("span") or name.equal("array") or name.equal("str_buffer")
        or name.equal("atomic") or name.equal("Task") or name.equal("SoA")
    )

function generic_c_type_raw(name: str, args: span[types.Type]) -> str:
    var buf = string.String.create()
    buf.append(name)
    var i: ptr_uint = 0
    while i < args.len:
        buf.append("_")
        unsafe:
            buf.append(naming.sanitize_identifier(types.type_to_string(read(args.data + i))))
        i += 1
    return buf.as_str()

## Resolve a syntactic `ast.TypeRef` to a `types.Type`, producing module-
## qualified named types and modelling `array[T, N]` (N as `ty_literal_int`) and
## `span[T]` / `ptr[T]` / `const_ptr[T]` / `ref[T]` as generic instances.  Returns
## `ty_error` for forms not yet handled (callable/dyn/tuple/nullable), letting
## callers fall back to the analyzer's inferred type.
function resolve_type_ref(ctx: ref[LowerCtx], tp: ptr[ast.TypeRef]) -> types.Type:
    unsafe:
        let t = read(tp)
        if t.is_fn or t.is_proc:
            let fun = resolve_function_type_ref(ctx, tp)
            if t.is_proc:
                let proc_name = proc_type_name_from_signature(fun)
                return proc_ensure_struct_decl(ctx, proc_name, fun)
            if t.nullable:
                return types.Type.ty_nullable(base = types.alloc_type(fun))
            return fun
        if t.is_dyn:
            return types.Type.ty_dyn(iface = unsafe: analyzer.qname_to_str(t.dyn_interface))
        if t.is_tuple:
            var elems = vec.Vec[types.Type].create()
            var i: ptr_uint = 0
            while i < t.arguments.len:
                elems.push(resolve_type_ref(ctx, t.arguments.data + i))
                i += 1
            let result = types.Type.ty_tuple(elements = elems.as_span())
            if t.nullable:
                return types.Type.ty_nullable(base = types.alloc_type(result))
            return result
        var resolved = types.Type.ty_error
        if t.arguments.len > 0:
            resolved = resolve_generic_type_ref(ctx, t)
        else if t.name.parts.len == 2:
            var alias: str
            var type_name: str
            unsafe:
                alias = read(t.name.parts.data + 0)
                type_name = read(t.name.parts.data + 1)
            let mod_ptr = ctx.analysis.imports.get(alias)
            if mod_ptr != null:
                let target_module = unsafe: read(mod_ptr)
                resolved = types.Type.ty_imported(module_name = target_module, name = type_name, args = span[types.Type]())
        else if t.name.parts.len == 1:
            let name = read(t.name.parts.data + 0)
            if name.equal("str"):
                resolved = types.Type.ty_str
            else if is_primitive_name(name):
                resolved = types.primitive(name)
            else if ctx.analysis.type_names.contains(name):
                resolved = types.Type.ty_imported(module_name = ctx.module_name, name = name, args = span[types.Type]())
            else:
                let concrete_ptr = ctx.type_substitution.get(name)
                if concrete_ptr != null:
                    resolved = unsafe: read(concrete_ptr)
                else:
                    resolved = types.Type.ty_named(name = name)
        if t.nullable and not types.is_error(resolved):
            return types.Type.ty_nullable(base = types.alloc_type(resolved))
        return resolved


function resolve_generic_type_ref(ctx: ref[LowerCtx], t: ast.TypeRef) -> types.Type:
    if t.name.parts.len == 2:
        var alias: str
        var type_name: str
        unsafe:
            alias = read(t.name.parts.data + 0)
            type_name = read(t.name.parts.data + 1)
        let mod_ptr = ctx.analysis.imports.get(alias)
        if mod_ptr != null:
            let target_module = unsafe: read(mod_ptr)
            var resolved_args = vec.Vec[types.Type].create()
            var ai: ptr_uint = 0
            while ai < t.arguments.len:
                unsafe:
                    resolved_args.push(resolve_type_ref(ctx, t.arguments.data + ai))
                ai += 1
            return types.Type.ty_imported(module_name = target_module, name = type_name, args = resolved_args.as_span())
        return types.Type.ty_error
    if t.name.parts.len != 1:
        return types.Type.ty_error
    let name = unsafe: read(t.name.parts.data + 0)
    if name.equal("array") and t.arguments.len == 2:
        var args = vec.Vec[types.Type].create()
        unsafe:
            args.push(resolve_type_ref(ctx, t.arguments.data + 0))
        args.push(types.literal_int(resolve_array_length(unsafe: t.arguments.data + 1)))
        return types.Type.ty_generic(name = "array", args = args.as_span())
    # str_buffer[N]: ensure the struct type exists and return the resolved type.
    if name.equal("str_buffer") and t.arguments.len == 1:
        var sb_args = vec.Vec[types.Type].create()
        unsafe:
            sb_args.push(resolve_type_ref(ctx, t.arguments.data + 0))
        let sb_ty = types.Type.ty_generic(name = "str_buffer", args = sb_args.as_span())
        ensure_str_buffer_struct(ctx, sb_ty)
        return sb_ty
    # span / ptr / const_ptr / ref and other generics: resolve each type argument.
    var args = vec.Vec[types.Type].create()
    var i: ptr_uint = 0
    while i < t.arguments.len:
        unsafe:
            args.push(resolve_type_ref(ctx, t.arguments.data + i))
        i += 1
    return types.Type.ty_generic(name = name, args = args.as_span())


## Resolve an `fn(...) -> T` or `proc(...) -> T` type ref to a `ty_function`
## type.  Both `fn` and `proc` share the same runtime C representation (function
## pointer), so they are lowered to the same `ty_function` variant.
function resolve_function_type_ref(ctx: ref[LowerCtx], tp: ptr[ast.TypeRef]) -> types.Type:
    let t = unsafe: read(tp)
    var param_types = vec.Vec[types.Type].create()
    var i: ptr_uint = 0
    while i < t.fn_params.len:
        var p: ast.Param
        unsafe:
            p = read(t.fn_params.data + i)
        let pty = resolve_type_ref(ctx, ptr_of(p.param_type))
        param_types.push(pty)
        i += 1
    var ret = types.primitive("void")
    let fr = t.fn_return
    if fr != null:
        unsafe:
            ret = resolve_type_ref(ctx, fr)
    return types.Type.ty_function(
        params = param_types.as_span(),
        return_type = types.alloc_type(ret),
        variadic = false,
    )


## The compile-time length of an array type argument (`array[int, 3]` -> 3),
## parsed from the argument's decimal name.  Non-literal lengths (named
## constants) resolve later.
function resolve_array_length(tp: ptr[ast.TypeRef]) -> long:
    let t = unsafe: read(tp)
    if t.name.parts.len != 1:
        return 0
    let text = unsafe: read(t.name.parts.data + 0)
    return parse_decimal(text)


function parse_decimal(text: str) -> long:
    var value: long = 0
    var i: ptr_uint = 0
    while i < text.len:
        let b = text.byte_at(i)
        if b == '_':
            i += 1
            continue
        if b < '0' or b > '9':
            break
        value = value * 10 + long<-(b - '0')
        i += 1
    return value


## Lower an `if`/`else if`/`else` chain (mtc's multi-branch AST) into nested
## single-branch IR `stmt_if` nodes; the C backend re-flattens single-`if` else
## bodies back into `else if`.
function lower_if_chain(ctx: ref[LowerCtx], branches: span[ast.IfBranch], index: ptr_uint, else_body: ptr[ast.Stmt]?) -> ir.Stmt:
    var branch: ast.IfBranch
    unsafe:
        branch = read(branches.data + index)
    let cond = lower_expr(ctx, branch.condition)
    let then_body = lower_block(ctx, branch.body)

    var else_span: span[ir.Stmt]
    if index + 1 < branches.len:
        var nested = vec.Vec[ir.Stmt].create()
        nested.push(lower_if_chain(ctx, branches, index + 1, else_body))
        else_span = nested.as_span()
    else:
        else_span = lower_block(ctx, else_body)

    return ir.Stmt.stmt_if(condition = cond, then_body = then_body, else_body = else_span)


## Lower `for i in start..stop:` into a scope block holding an optional hoisted
## stop temporary and a C `for` loop.  Mirrors lowering/loops.rb
## lower_range_for_stmt, including the always-allocated (here unused) continue /
## break label temporaries so the fresh-temp counter advances identically.
function lower_for_range(ctx: ref[LowerCtx], output: ref[vec.Vec[ir.Stmt]], bindings: span[ast.ForBinding], iterables: span[ast.Expr], body_ptr: ptr[ast.Stmt]?) -> void:
    if bindings.len != 1 or iterables.len != 1:
        fatal(c"lowering: only single-binding range for-loops are supported")

    var index_name: str
    unsafe:
        index_name = read(bindings.data + 0).name

    var start: ptr[ast.Expr]
    var stop: ptr[ast.Expr]
    unsafe:
        match read(iterables.data + 0):
            ast.Expr.expr_range as rng:
                start = rng.start_expr
                stop = rng.end_expr
            _:
                lower_collection_for(ctx, output, index_name, iterables.data + 0, body_ptr)
                return

    var loop_type = expr_type(ctx, start)
    if types.is_error(loop_type):
        loop_type = expr_type(ctx, stop)
    if types.is_error(loop_type):
        loop_type = types.primitive("int")

    let index_c = c_local_name(index_name)
    let stop_c = fresh_c_temp_name(ctx, "for_stop")
    let _continue_label = fresh_c_temp_name(ctx, "loop_continue")
    let _break_label = fresh_c_temp_name(ctx, "loop_break")

    let inline_stop = is_integer_literal(stop)

    ctx.locals.push(LocalBinding(name = index_name, c_name = index_c, ty = loop_type, pointer = false))
    let body = lower_block(ctx, body_ptr)

    let init = alloc_stmt(ir.Stmt.stmt_local(
        name = index_name,
        linkage_name = index_c,
        ty = loop_type,
        value = lower_expr(ctx, start),
        line = 0,
        source_path = "",
    ))
    let index_ref = alloc_expr(ir.Expr.expr_name(name = index_c, ty = loop_type, pointer = false))
    let stop_value = if inline_stop: lower_expr(ctx, stop) else: alloc_expr(ir.Expr.expr_name(name = stop_c, ty = loop_type, pointer = false))
    let condition = alloc_expr(ir.Expr.expr_binary(operator = "<", left = index_ref, right = stop_value, ty = types.primitive("bool")))
    let post_target = alloc_expr(ir.Expr.expr_name(name = index_c, ty = loop_type, pointer = false))
    let one = alloc_expr(ir.Expr.expr_integer_literal(value = 1, ty = loop_type))
    let post = alloc_stmt(ir.Stmt.stmt_assignment(target = post_target, operator = "+=", value = one))
    let for_stmt = ir.Stmt.stmt_for(init = init, condition = condition, post = post, body = body)

    var block_stmts = vec.Vec[ir.Stmt].create()
    if not inline_stop:
        block_stmts.push(ir.Stmt.stmt_local(
            name = stop_c,
            linkage_name = stop_c,
            ty = loop_type,
            value = lower_expr(ctx, stop),
            line = 0,
            source_path = "",
        ))
    block_stmts.push(for_stmt)
    output.push(ir.Stmt.stmt_block(body = block_stmts.as_span()))


function is_integer_literal(ep: ptr[ast.Expr]) -> bool:
    unsafe:
        match read(ep):
            ast.Expr.expr_integer_literal:
                return true
            _:
                return false


## Lower `for v in xs:` (array) / `for v in s:` (span) into a scope block that
## copies the iterable into a temp and drives a C index loop.  Mirrors
## lowering/loops.rb lower_collection_for_stmt (including the always-allocated
## continue/break label temporaries so the fresh-temp counter matches).
function lower_collection_for(ctx: ref[LowerCtx], output: ref[vec.Vec[ir.Stmt]], binding_name: str, iterable: ptr[ast.Expr], body_ptr: ptr[ast.Stmt]?) -> void:
    let iterable_type = index_receiver_type(ctx, iterable)
    let element_type = generic_first_arg(iterable_type)
    let is_arr = is_array_type(iterable_type)
    let ptr_uint_ty = types.primitive("ptr_uint")

    let items_c = fresh_c_temp_name(ctx, "for_items")
    let index_c = fresh_c_temp_name(ctx, "for_index")
    let _continue_label = fresh_c_temp_name(ctx, "loop_continue")
    let _break_label = fresh_c_temp_name(ctx, "loop_break")

    let binding_c = c_local_name(binding_name)
    ctx.locals.push(LocalBinding(name = binding_name, c_name = binding_c, ty = element_type, pointer = false))
    let body = lower_block(ctx, body_ptr)

    # item value: array -> items[index]; span -> items.data[index]
    var item_value: ptr[ir.Expr]
    let index_ref_item = alloc_expr(ir.Expr.expr_name(name = index_c, ty = ptr_uint_ty, pointer = false))
    if is_arr:
        let items_ref = alloc_expr(ir.Expr.expr_name(name = items_c, ty = iterable_type, pointer = false))
        item_value = alloc_expr(ir.Expr.expr_index(receiver = items_ref, index = index_ref_item, ty = element_type))
    else:
        let items_ref = alloc_expr(ir.Expr.expr_name(name = items_c, ty = iterable_type, pointer = false))
        var ptr_args = vec.Vec[types.Type].create()
        ptr_args.push(element_type)
        let data_ty = types.Type.ty_generic(name = "ptr", args = ptr_args.as_span())
        let data_ref = alloc_expr(ir.Expr.expr_member(receiver = items_ref, member = "data", ty = data_ty))
        item_value = alloc_expr(ir.Expr.expr_index(receiver = data_ref, index = index_ref_item, ty = element_type))

    # stop value: array -> N; span -> items.len
    var stop_value: ptr[ir.Expr]
    if is_arr:
        stop_value = alloc_expr(ir.Expr.expr_integer_literal(value = array_length_of(iterable_type), ty = ptr_uint_ty))
    else:
        let items_ref_stop = alloc_expr(ir.Expr.expr_name(name = items_c, ty = iterable_type, pointer = false))
        stop_value = alloc_expr(ir.Expr.expr_member(receiver = items_ref_stop, member = "len", ty = ptr_uint_ty))

    var loop_body = vec.Vec[ir.Stmt].create()
    loop_body.push(ir.Stmt.stmt_local(name = binding_name, linkage_name = binding_c, ty = element_type, value = item_value, line = 0, source_path = ""))
    var bi: ptr_uint = 0
    while bi < body.len:
        unsafe:
            loop_body.push(read(body.data + bi))
        bi += 1

    let init = alloc_stmt(ir.Stmt.stmt_local(name = index_c, linkage_name = index_c, ty = ptr_uint_ty, value = alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = ptr_uint_ty)), line = 0, source_path = ""))
    let index_ref_cond = alloc_expr(ir.Expr.expr_name(name = index_c, ty = ptr_uint_ty, pointer = false))
    let condition = alloc_expr(ir.Expr.expr_binary(operator = "<", left = index_ref_cond, right = stop_value, ty = types.primitive("bool")))
    let post_target = alloc_expr(ir.Expr.expr_name(name = index_c, ty = ptr_uint_ty, pointer = false))
    let post = alloc_stmt(ir.Stmt.stmt_assignment(target = post_target, operator = "+=", value = alloc_expr(ir.Expr.expr_integer_literal(value = 1, ty = ptr_uint_ty))))
    let for_stmt = ir.Stmt.stmt_for(init = init, condition = condition, post = post, body = loop_body.as_span())

    var block_stmts = vec.Vec[ir.Stmt].create()
    block_stmts.push(ir.Stmt.stmt_local(name = items_c, linkage_name = items_c, ty = iterable_type, value = lower_expr(ctx, iterable), line = 0, source_path = ""))
    block_stmts.push(for_stmt)
    output.push(ir.Stmt.stmt_block(body = block_stmts.as_span()))


function array_length_of(t: types.Type) -> long:
    match t:
        types.Type.ty_generic as g:
            if g.args.len == 2:
                unsafe:
                    match read(g.args.data + 1):
                        types.Type.ty_literal_int as lit:
                            return lit.value
                        _:
                            pass
        _:
            pass
    return 0


# =============================================================================
#  Parallel / detach / gather lowering
# =============================================================================

var parallel_cnt: ptr_uint = 0


function parallel_uid(ctx: ref[LowerCtx]) -> str:
    var buf = string.String.create()
    buf.append(naming.module_c_prefix(ctx.module_name))
    buf.append("_par_")
    fmt.append_ptr_uint(ref_of(buf), parallel_cnt)
    return buf.as_str()


function parallel_worker_fn(ctx: ref[LowerCtx], body_ir: span[ir.Stmt]) -> ir.Function:
    let void_ty = types.primitive("void")
    let void_ptr_ty = types.Type.ty_generic(name = "ptr", args = sp_type(void_ty))
    parallel_cnt += 1
    let uid = parallel_uid(ctx)
    let name = j2("mt_p_work_", uid)
    var params = vec.Vec[ir.Param].create()
    params.push(ir.Param(name = "data", linkage_name = "data", ty = void_ptr_ty, pointer = false))
    return ir.Function(name = name, linkage_name = name, params = params.as_span(),
        return_type = void_ty, body = body_ir, entry_point = false, method_receiver_param = false)


## Worker for mt_parallel_for: takes (void* data, intptr_t start, intptr_t end).
function parallel_for_worker_fn(ctx: ref[LowerCtx], body_ir: span[ir.Stmt]) -> ir.Function:
    let void_ty = types.primitive("void")
    let void_ptr_ty = types.Type.ty_generic(name = "ptr", args = sp_type(void_ty))
    let long_ty = types.primitive("long")
    parallel_cnt += 1
    let uid = parallel_uid(ctx)
    let name = j2("mt_p_work_", uid)
    var params = vec.Vec[ir.Param].create()
    params.push(ir.Param(name = "data", linkage_name = "data", ty = void_ptr_ty, pointer = false))
    params.push(ir.Param(name = "mt_pfor_start", linkage_name = "mt_pfor_start", ty = long_ty, pointer = false))
    params.push(ir.Param(name = "mt_pfor_end", linkage_name = "mt_pfor_end", ty = long_ty, pointer = false))
    return ir.Function(name = name, linkage_name = name, params = params.as_span(),
        return_type = void_ty, body = body_ir, entry_point = false, method_receiver_param = false)


function void_ptr_ty() -> types.Type:
    return types.Type.ty_generic(name = "ptr", args = sp_type(types.primitive("void")))


function pw1_str(value: ptr_uint) -> str:
    var buf = string.String.create()
    fmt.append_ptr_uint(ref_of(buf), value)
    return buf.as_str()


## Lower `parallel for i in 0..N: body`.  Generates a worker function that
## contains the loop body, and emits a call to mt_parallel_for.
function lower_parallel_for(ctx: ref[LowerCtx], output: ref[vec.Vec[ir.Stmt]], bindings: span[ast.ForBinding], iterables: span[ast.Expr], body: ptr[ast.Stmt]?) -> void:
    if bindings.len == 0 or iterables.len == 0:
        return
    # Extract range start/end from the iterable (must be a range expression)
    var start_ptr: ptr[ast.Expr]
    var end_ptr: ptr[ast.Expr]
    unsafe:
        match read(iterables.data + 0):
            ast.Expr.expr_range as rng:
                start_ptr = rng.start_expr
                end_ptr = rng.end_expr
            _:
                fatal(c"lowering parallel for: only range iteration is supported")
    let void_ty = types.primitive("void")
    let long_ty = types.primitive("long")
    # Lower the loop body (captured globals work via static linkage)
    let bd = body else:
        return
    let loop_body = lower_block(ctx, bd)
    # Wrap in a worker function
    let worker = parallel_for_worker_fn(ctx, loop_body)
    # Emit: mt_parallel_for(start, end, step, worker, NULL)
    var call_args = vec.Vec[ir.Expr].create()
    let start_expr = lower_expr(ctx, start_ptr)
    let end_expr = lower_expr(ctx, end_ptr)
    unsafe:
        call_args.push(read(start_expr))
        call_args.push(read(end_expr))
        call_args.push(read(alloc_expr(ir.Expr.expr_integer_literal(value = 1, ty = long_ty))))
        call_args.push(read(alloc_expr(ir.Expr.expr_name(name = worker.linkage_name, ty = void_ty, pointer = false))))
        call_args.push(read(alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = void_ptr_ty()))))
    ctx.pending_synthetic_functions.push(worker)
    output.push(ir.Stmt.stmt_expression(
        expression = alloc_expr(ir.Expr.expr_call(callee = "mt_parallel_for", arguments = call_args.as_span(), ty = void_ty)),
        line = 0, source_path = "",
    ))


## Lower `parallel: stmt1; stmt2; ...`.  Each statement becomes a worker
## function, dispatched via mt_spawn_run, then mt_spawn_wait.
function lower_parallel_block(ctx: ref[LowerCtx], output: ref[vec.Vec[ir.Stmt]], bodies: span[ast.Stmt]) -> void:
    if bodies.len < 2:
        return
    let void_ty = types.primitive("void")
    # Generate worker for each body, emit spawn call
    var i: ptr_uint = 0
    while i < bodies.len:
        var wb = lower_block(ctx, unsafe: ptr[ast.Stmt]<-(bodies.data + i))
        let worker = parallel_worker_fn(ctx, wb)
        ctx.pending_synthetic_functions.push(worker)
        var spawn_args = vec.Vec[ir.Expr].create()
        unsafe:
            spawn_args.push(read(alloc_expr(ir.Expr.expr_name(name = worker.linkage_name, ty = void_ty, pointer = false))))
            spawn_args.push(read(alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = void_ptr_ty()))))
        output.push(ir.Stmt.stmt_expression(
            expression = alloc_expr(ir.Expr.expr_call(callee = "mt_spawn_run", arguments = spawn_args.as_span(), ty = void_ty)),
            line = 0, source_path = "",
        ))
        i += 1
    output.push(ir.Stmt.stmt_expression(
        expression = alloc_expr(ir.Expr.expr_call(callee = "mt_spawn_wait", arguments = span[ir.Expr](), ty = void_ty)),
        line = 0, source_path = "",
    ))


## Lower `gather h1, h2, ...`.  Each handle is joined via mt_detach_join.
function lower_gather_stmt(ctx: ref[LowerCtx], output: ref[vec.Vec[ir.Stmt]], handles: span[ast.Expr]) -> void:
    let void_ty = types.primitive("void")
    var i: ptr_uint = 0
    while i < handles.len:
        let h = unsafe: lower_expr(ctx, handles.data + i)
        var join_args = vec.Vec[ir.Expr].create()
        unsafe:
            join_args.push(read(h))
        output.push(ir.Stmt.stmt_expression(
            expression = alloc_expr(ir.Expr.expr_call(callee = "mt_detach_join", arguments = join_args.as_span(), ty = void_ty)),
            line = 0, source_path = "",
        ))
        i += 1


## Lower `detach <call>` expression.  Wraps the call in a worker function
## and dispatches via mt_detach_run, returning a void* handle.
function lower_detach_expr(ctx: ref[LowerCtx], expression: ptr[ast.Expr], ep: ptr[ast.Expr]) -> ptr[ir.Expr]:
    let void_ty = types.primitive("void")
    let lowered_call = lower_expr(ctx, expression)
    var wb = vec.Vec[ir.Stmt].create()
    wb.push(ir.Stmt.stmt_expression(expression = lowered_call, line = 0, source_path = ""))
    let worker = parallel_worker_fn(ctx, wb.as_span())
    ctx.pending_synthetic_functions.push(worker)
    var da = vec.Vec[ir.Expr].create()
    unsafe:
        da.push(read(alloc_expr(ir.Expr.expr_name(name = worker.linkage_name, ty = void_ty, pointer = false))))
        da.push(read(alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = void_ptr_ty()))))
    return alloc_expr(ir.Expr.expr_call(callee = "mt_detach_run", arguments = da.as_span(), ty = void_ptr_ty()))


# =============================================================================
function fresh_c_temp_name(ctx: ref[LowerCtx], prefix: str) -> str:
    ctx.temp_counter += 1
    var buf = string.String.create()
    buf.append("__mt_")
    buf.append(prefix)
    buf.append("_")
    fmt.append_ptr_uint(ref_of(buf), ctx.temp_counter)
    return buf.as_str()


# =============================================================================
#  Expression lowering
# =============================================================================

function lower_expr(ctx: ref[LowerCtx], ep: ptr[ast.Expr]) -> ptr[ir.Expr]:
    unsafe:
        match read(ep):
            ast.Expr.expr_integer_literal as lit:
                return alloc_expr(ir.Expr.expr_integer_literal(value = long<-lit.value, ty = expr_type(ctx, ep)))
            ast.Expr.expr_float_literal as lit:
                return alloc_expr(ir.Expr.expr_float_literal(value = lit.value, ty = expr_type(ctx, ep)))
            ast.Expr.expr_char_literal as lit:
                return alloc_expr(ir.Expr.expr_integer_literal(value = long<-lit.value, ty = types.primitive("ubyte")))
            ast.Expr.expr_bool_literal as b:
                return alloc_expr(ir.Expr.expr_boolean_literal(value = b.value, ty = types.primitive("bool")))
            ast.Expr.expr_if as ie:
                let cond = lower_expr(ctx, ie.condition)
                let then_e = lower_expr(ctx, ie.then_expr)
                let else_e = lower_expr(ctx, ie.else_expr)
                return alloc_expr(ir.Expr.expr_conditional(condition = cond, then_expression = then_e, else_expression = else_e, ty = ir_expr_type(then_e)))
            ast.Expr.expr_unsafe as u:
                return lower_expr(ctx, u.expression)
            ast.Expr.expr_string_literal as lit:
                let ty = if lit.is_cstring: types.primitive("cstr") else: types.Type.ty_str
                return alloc_expr(ir.Expr.expr_string_literal(value = lit.value, ty = ty, cstring = lit.is_cstring))
            ast.Expr.expr_identifier as id:
                match lookup_local(ctx, id.name):
                    Option.some as lb:
                        return alloc_expr(ir.Expr.expr_name(name = lb.value.c_name, ty = lb.value.ty, pointer = lb.value.pointer))
                    Option.none:
                        if ctx.function_returns.contains(id.name) or ctx.analysis.functions.contains(id.name):
                            let fn_c_name = naming.qualified_c_name(ctx.module_name, id.name)
                            let fn_ty = expr_type(ctx, ep)
                            match fn_ty:
                                types.Type.ty_function:
                                    return lower_fn_to_proc(ctx, fn_c_name, fn_ty)
                                _:
                                    pass
                            return alloc_expr(ir.Expr.expr_name(name = fn_c_name, ty = fn_ty, pointer = false))
                        match lookup_qualified_constant(ctx, id.name):
                            Option.some as qc:
                                return alloc_expr(ir.Expr.expr_name(name = qc.value, ty = expr_type(ctx, ep), pointer = false))
                            Option.none:
                                pass
                        return alloc_expr(ir.Expr.expr_name(name = id.name, ty = expr_type(ctx, ep), pointer = false))
            ast.Expr.expr_binary_op as bin:
                let left = lower_expr(ctx, bin.left)
                let right = lower_expr(ctx, bin.right)
                return alloc_expr(ir.Expr.expr_binary(operator = bin.operator, left = left, right = right, ty = expr_type(ctx, ep)))
            ast.Expr.expr_unary_op as un:
                let operand = lower_expr(ctx, un.operand)
                return alloc_expr(ir.Expr.expr_unary(operator = un.operator, operand = operand, ty = expr_type(ctx, ep)))
            ast.Expr.expr_prefix_cast as pc:
                let target_ty = qualify_type(ctx, resolve_type_ref(ctx, pc.target_type))
                let lowered_expr = lower_expr(ctx, pc.expression)
                return alloc_expr(ir.Expr.expr_cast(target_type = target_ty, expression = lowered_expr, ty = target_ty))
            ast.Expr.expr_call as call:
                return lower_call(ctx, call.callee, call.args, ep)
            ast.Expr.expr_member_access as ma:
                return lower_member_access(ctx, ma.receiver, ma.member_name, ep)
            ast.Expr.expr_index_access as ix:
                return lower_index_access(ctx, ix.receiver, ix.index, ep)
            ast.Expr.expr_expression_list as lst:
                return lower_tuple_literal(ctx, lst.elements)
            ast.Expr.expr_proc as pr:
                return lower_proc_expression(ctx, pr.method_params, pr.return_type, pr.body, ep)
            ast.Expr.expr_await as aw:
                return lower_expr(ctx, aw.expression)
            ast.Expr.expr_format_string as fs:
                let str_ty = types.Type.ty_str
                return alloc_expr(ir.Expr.expr_string_literal(value = "fmt", ty = str_ty, cstring = false))
            ast.Expr.expr_detach as dt:
                return lower_detach_expr(ctx, dt.expression, ep)
            ast.Expr.expr_specialization as spec:
                match read(spec.callee):
                    ast.Expr.expr_identifier as id:
                        if id.name.equal("zero") and spec.arguments.len == 1:
                            let z_ty = resolve_type_ref(ctx, read(spec.arguments.data + 0).value)
                            return alloc_expr(ir.Expr.expr_zero_init(ty = z_ty))
                    _:
                        pass
                return alloc_expr(ir.Expr.expr_name(name = "spec", ty = types.Type.ty_error, pointer = false))
            ast.Expr.expr_match as me:
                return lower_expression_match(ctx, me.scrutinee, me.arms, ep)
            ast.Expr.expr_range as rng:
                let start = lower_expr(ctx, rng.start_expr)
                return start
            ast.Expr.expr_null_literal:
                return alloc_expr(ir.Expr.expr_null_literal(ty = types.primitive("void")))
            ast.Expr.expr_named as nm:
                return lower_expr(ctx, nm.value)
            ast.Expr.expr_sizeof as sz:
                return alloc_expr(ir.Expr.expr_sizeof(target_type = qualify_type(ctx, resolve_type_ref(ctx, sz.target_type)), ty = types.primitive("ptr_uint")))
            ast.Expr.expr_alignof as al:
                return alloc_expr(ir.Expr.expr_alignof(target_type = qualify_type(ctx, resolve_type_ref(ctx, al.target_type)), ty = types.primitive("ptr_uint")))
            ast.Expr.expr_offsetof as off:
                return alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = types.primitive("ptr_uint")))
            ast.Expr.expr_error:
                return alloc_expr(ir.Expr.expr_null_literal(ty = types.primitive("void")))
            _:
                fatal(c"lowering: unsupported expression")


## Lower a proc expression `proc(x: int) -> int: x + 1` to a proc struct literal
## with invoke/release/retain function pointers and a capture env pointer.  No-
## capture procs use null env; capturing procs use a heap-allocated env struct
## with ref-counting.
function lower_proc_expression(ctx: ref[LowerCtx], method_params: span[ast.Param], return_type: ptr[ast.TypeRef]?, body_ptr: ptr[ast.Stmt], ep: ptr[ast.Expr]) -> ptr[ir.Expr]:
    ctx.proc_counter += 1
    let proc_id = ctx.proc_counter
    var id_buf = string.String.create()
    id_buf.append(naming.module_c_prefix(ctx.module_name))
    id_buf.append("__proc_")
    fmt.append_ptr_uint(ref_of(id_buf), proc_id)
    let proc_prefix = id_buf.as_str()

    let proc_ty = expr_type(ctx, ep)

    # Collect all in-scope locals as captures (excluding "this" receiver).
    let captures = collect_locals_for_capture(ctx, method_params)
    let has_captures = captures.len > 0

    # Proc struct type: { env, invoke, release, retain }.
    let void_ptr = types.Type.ty_generic(name = "ptr", args = sp_type(types.primitive("void")))
    let struct_name = proc_prefix

    var struct_fields = vec.Vec[ir.Field].create()
    struct_fields.push(ir.Field(name = "env", ty = void_ptr))
    struct_fields.push(ir.Field(name = "invoke", ty = proc_invoke_field_type(proc_ty)))
    let lifecycle_ty = proc_lifecycle_fn_type()
    struct_fields.push(ir.Field(name = "release", ty = lifecycle_ty))
    struct_fields.push(ir.Field(name = "retain", ty = lifecycle_ty))
    ctx.pending_env_structs.push(ir.StructDecl(name = struct_name, linkage_name = struct_name, fields = struct_fields.as_span(), packed = false, alignment = 0, source_module = Option[str].none))

    var invoke_c = string.String.create()
    invoke_c.append(proc_prefix)
    invoke_c.append("__invoke")
    var release_c = string.String.create()
    release_c.append(proc_prefix)
    release_c.append("__release")
    var retain_c = string.String.create()
    retain_c.append(proc_prefix)
    retain_c.append("__retain")

    let invoke_str = invoke_c.as_str()
    let release_str = release_c.as_str()
    let retain_str = retain_c.as_str()

    if has_captures:
        # Build capture-env struct: { __mt_ref_count, cap1, cap2, ... }.
        var env_struct_name = string.String.create()
        env_struct_name.append(proc_prefix)
        env_struct_name.append("__env")
        let env_type_name = env_struct_name.as_str()
        let uint_ty = types.primitive("ptr_uint")
        var env_fields = vec.Vec[ir.Field].create()
        env_fields.push(ir.Field(name = "__mt_ref_count", ty = uint_ty))
        var ci: ptr_uint = 0
        while ci < captures.len:
            let cap = unsafe: read(captures.data + ci)
            env_fields.push(ir.Field(name = cap.name, ty = cap.ty))
            ci += 1
        ctx.pending_env_structs.push(ir.StructDecl(name = env_type_name, linkage_name = env_type_name, fields = env_fields.as_span(), packed = false, alignment = 0, source_module = Option[str].none))

        # Build a synthetic init function that allocates + populates the env.
        var setup_c = string.String.create()
        setup_c.append(proc_prefix)
        setup_c.append("__setup_env")
        ctx.pending_synthetic_functions.push(build_env_setup_fn(ctx, setup_c.as_str(), env_type_name, captures))

        # Build capturing invoke: unpacks env→locals, then body.
        ctx.pending_synthetic_functions.push(build_capturing_invoke(ctx, method_params, return_type, body_ptr, invoke_str, env_type_name, captures))

        # Build release: decrement ref_count, free if zero.
        ctx.pending_synthetic_functions.push(build_capturing_release(release_str, env_type_name, captures))

        # Build retain: increment ref_count.
        ctx.pending_synthetic_functions.push(build_capturing_retain(retain_str, env_type_name))

        # Call the setup function with captured locals as arguments.
        let env_ptr_ty = types.Type.ty_generic(name = "ptr", args = sp_type(types.Type.ty_named(name = env_type_name)))
        var setup_args = vec.Vec[ir.Expr].create()
        var si: ptr_uint = 0
        while si < captures.len:
            let cap = unsafe: read(captures.data + si)
            unsafe:
                setup_args.push(read(alloc_expr(ir.Expr.expr_name(name = cap.c_name, ty = cap.ty, pointer = false))))
            si += 1
        let setup_call = alloc_expr(ir.Expr.expr_call(callee = setup_c.as_str(), arguments = setup_args.as_span(), ty = env_ptr_ty))

        # Build proc struct literal with env pointer.
        var fields = vec.Vec[ir.AggregateField].create()
        fields.push(ir.AggregateField(name = "env", value = alloc_expr(ir.Expr.expr_cast(target_type = void_ptr, expression = setup_call, ty = void_ptr))))
        fields.push(ir.AggregateField(name = "invoke", value = alloc_expr(ir.Expr.expr_name(name = invoke_str, ty = proc_invoke_field_type(proc_ty), pointer = false))))
        fields.push(ir.AggregateField(name = "release", value = alloc_expr(ir.Expr.expr_name(name = release_str, ty = lifecycle_ty, pointer = false))))
        fields.push(ir.AggregateField(name = "retain", value = alloc_expr(ir.Expr.expr_name(name = retain_str, ty = lifecycle_ty, pointer = false))))
        return alloc_expr(ir.Expr.expr_aggregate_literal(ty = types.Type.ty_named(name = struct_name), fields = fields.as_span()))

    # No-capture path.
    ctx.pending_synthetic_functions.push(build_proc_invoke_fn(ctx, method_params, return_type, body_ptr, invoke_str))
    ctx.pending_synthetic_functions.push(build_proc_noop_fn(retain_str))
    ctx.pending_synthetic_functions.push(build_proc_noop_fn(release_str))

    let null_env = alloc_expr(ir.Expr.expr_null_literal(ty = void_ptr))
    var fields = vec.Vec[ir.AggregateField].create()
    fields.push(ir.AggregateField(name = "env", value = null_env))
    fields.push(ir.AggregateField(name = "invoke", value = alloc_expr(ir.Expr.expr_name(name = invoke_str, ty = proc_invoke_field_type(proc_ty), pointer = false))))
    fields.push(ir.AggregateField(name = "release", value = alloc_expr(ir.Expr.expr_name(name = release_str, ty = lifecycle_ty, pointer = false))))
    fields.push(ir.AggregateField(name = "retain", value = alloc_expr(ir.Expr.expr_name(name = retain_str, ty = lifecycle_ty, pointer = false))))

    return alloc_expr(ir.Expr.expr_aggregate_literal(ty = types.Type.ty_named(name = struct_name), fields = fields.as_span()))


## Pack a single expression into a span.
function pack_single(expr: ptr[ir.Expr]) -> span[ir.Expr]:
    var buf = vec.Vec[ir.Expr].create()
    unsafe:
        buf.push(read(expr))
    return buf.as_span()


## Collect all locals in the current scope that can be captured (excluding "this"
## and function parameters declared in the proc).
function collect_locals_for_capture(ctx: ref[LowerCtx], method_params: span[ast.Param]) -> span[ProcCapture]:
    var result = vec.Vec[ProcCapture].create()
    var param_names = map_mod.Map[str, bool].create()
    var pi: ptr_uint = 0
    while pi < method_params.len:
        unsafe:
            param_names.set(read(method_params.data + pi).name, true)
        pi += 1

    var li: ptr_uint = 0
    while li < ctx.locals.len():
        let lb_ptr = ctx.locals.get(li) else:
            break
        unsafe:
            let lb = read(lb_ptr)
            if lb.name == "this" or param_names.contains(lb.name):
                li += 1
                continue
            result.push(ProcCapture(name = lb.name, c_name = lb.c_name, ty = lb.ty))
        li += 1
    return result.as_span()


## Build a setup function that allocates + populates the capture-env struct.
## Takes captured values as parameters and returns a pointer to the initialized env.
function build_env_setup_fn(ctx: ref[LowerCtx], c_name: str, env_type_name: str, captures: span[ProcCapture]) -> ir.Function:
    let void_ptr = types.Type.ty_generic(name = "ptr", args = sp_type(types.primitive("void")))
    let env_ty_named = types.Type.ty_named(name = env_type_name)
    let env_ptr_ty = types.Type.ty_generic(name = "ptr", args = sp_type(env_ty_named))
    let uint_ty = types.primitive("ptr_uint")

    var params = vec.Vec[ir.Param].create()
    # Each capture becomes a parameter of the setup function.
    var ci: ptr_uint = 0
    while ci < captures.len:
        let cap = unsafe: read(captures.data + ci)
        params.push(ir.Param(name = cap.name, linkage_name = cap.c_name, ty = cap.ty, pointer = false))
        ci += 1

    var body = vec.Vec[ir.Stmt].create()

    # env = (env_type*) malloc(sizeof(env_type))
    let sizeof_call = alloc_expr(ir.Expr.expr_call(callee = "malloc", arguments = pack_single(alloc_expr(ir.Expr.expr_sizeof(target_type = env_ty_named, ty = uint_ty))), ty = void_ptr))
    let cast_env = alloc_expr(ir.Expr.expr_cast(target_type = env_ptr_ty, expression = sizeof_call, ty = env_ptr_ty))
    body.push(ir.Stmt.stmt_local(name = "env", linkage_name = "env", ty = env_ptr_ty, value = cast_env, line = 0, source_path = ""))

    # env->__mt_ref_count = 1
    let env_ref = alloc_expr(ir.Expr.expr_name(name = "env", ty = env_ptr_ty, pointer = false))
    let ref_field = alloc_expr(ir.Expr.expr_member(receiver = env_ref, member = "__mt_ref_count", ty = uint_ty))
    let one = alloc_expr(ir.Expr.expr_integer_literal(value = 1, ty = uint_ty))
    body.push(ir.Stmt.stmt_assignment(target = ref_field, operator = "=", value = one))

    # Populate capture fields from parameters.
    var ci2: ptr_uint = 0
    while ci2 < captures.len:
        let cap = unsafe: read(captures.data + ci2)
        let field = alloc_expr(ir.Expr.expr_member(receiver = env_ref, member = cap.name, ty = cap.ty))
        let cap_val = alloc_expr(ir.Expr.expr_name(name = cap.c_name, ty = cap.ty, pointer = false))
        body.push(ir.Stmt.stmt_assignment(target = field, operator = "=", value = cap_val))
        ci2 += 1

    # return env
    body.push(ir.Stmt.stmt_return(value = env_ref, line = 0, source_path = ""))

    return ir.Function(name = c_name, linkage_name = c_name, params = params.as_span(), return_type = env_ptr_ty, body = body.as_span(), entry_point = false, method_receiver_param = false)


## Build an invoke function for a capturing proc: unpacks env struct fields into
## locals, then runs the body.
function build_capturing_invoke(ctx: ref[LowerCtx], method_params: span[ast.Param], return_type: ptr[ast.TypeRef]?, body: ptr[ast.Stmt], invoke_c_name: str, env_type_name: str, captures: span[ProcCapture]) -> ir.Function:
    let saved_locals = ctx.locals
    let saved_counter = ctx.temp_counter
    ctx.locals = vec.Vec[LocalBinding].create()
    ctx.temp_counter = 0

    let void_ptr = types.Type.ty_generic(name = "ptr", args = sp_type(types.primitive("void")))
    let env_ptr_ty = types.Type.ty_generic(name = "ptr", args = sp_type(types.Type.ty_named(name = env_type_name)))

    var params = vec.Vec[ir.Param].create()
    params.push(ir.Param(name = "__mt_proc_env", linkage_name = "__mt_proc_env", ty = void_ptr, pointer = false))

    var pi: ptr_uint = 0
    while pi < method_params.len:
        var p: ast.Param
        unsafe:
            p = read(method_params.data + pi)
        let p_ty = resolve_field_type_ref(ctx, p.param_type)
        let pc = c_local_name(p.name)
        params.push(ir.Param(name = p.name, linkage_name = pc, ty = p_ty, pointer = false))
        ctx.locals.push(LocalBinding(name = p.name, c_name = pc, ty = p_ty, pointer = false))
        pi += 1

    var ret_ty = types.primitive("void")
    if return_type != null:
        ret_ty = resolve_type_ref(ctx, return_type)

    # Build body: first cast env to typed pointer, then unpack captures.
    var body_stmts = vec.Vec[ir.Stmt].create()
    let env_expr = alloc_expr(ir.Expr.expr_name(name = "__mt_proc_env", ty = void_ptr, pointer = false))
    let cast_env = alloc_expr(ir.Expr.expr_cast(target_type = env_ptr_ty, expression = env_expr, ty = env_ptr_ty))
    let env_local_name = fresh_c_temp_name(ctx, "env")
    body_stmts.push(ir.Stmt.stmt_local(name = env_local_name, linkage_name = env_local_name, ty = env_ptr_ty, value = cast_env, line = 0, source_path = ""))

    # Unpack each capture from env.
    var ci: ptr_uint = 0
    while ci < captures.len:
        let cap = unsafe: read(captures.data + ci)
        let env_ref = alloc_expr(ir.Expr.expr_name(name = env_local_name, ty = env_ptr_ty, pointer = false))
        let member = alloc_expr(ir.Expr.expr_member(receiver = env_ref, member = cap.name, ty = cap.ty))
        let bc = c_local_name(cap.name)
        body_stmts.push(ir.Stmt.stmt_local(name = cap.name, linkage_name = bc, ty = cap.ty, value = member, line = 0, source_path = ""))
        ctx.locals.push(LocalBinding(name = cap.name, c_name = bc, ty = cap.ty, pointer = false))
        ci += 1

    # Append the original body.
    let orig_body = lower_block(ctx, body)
    var bi: ptr_uint = 0
    while bi < orig_body.len:
        unsafe:
            body_stmts.push(read(orig_body.data + bi))
        bi += 1

    ctx.locals = saved_locals
    ctx.temp_counter = saved_counter
    return ir.Function(
        name = invoke_c_name,
        linkage_name = invoke_c_name,
        params = params.as_span(),
        return_type = ret_ty,
        body = body_stmts.as_span(),
        entry_point = false,
        method_receiver_param = false,
    )


## Build a release function for capturing procs with ref-counting.
function build_capturing_release(c_name: str, env_type_name: str, captures: span[ProcCapture]) -> ir.Function:
    let void_ptr = types.Type.ty_generic(name = "ptr", args = sp_type(types.primitive("void")))
    let env_ptr_ty = types.Type.ty_generic(name = "ptr", args = sp_type(types.Type.ty_named(name = env_type_name)))
    let uint_ty = types.primitive("ptr_uint")
    var params = vec.Vec[ir.Param].create()
    params.push(ir.Param(name = "__mt_proc_env", linkage_name = "__mt_proc_env", ty = void_ptr, pointer = false))
    var body = vec.Vec[ir.Stmt].create()

    let env_expr = alloc_expr(ir.Expr.expr_name(name = "__mt_proc_env", ty = void_ptr, pointer = false))
    let cast_env = alloc_expr(ir.Expr.expr_cast(target_type = env_ptr_ty, expression = env_expr, ty = env_ptr_ty))
    body.push(ir.Stmt.stmt_local(name = "env", linkage_name = "env", ty = env_ptr_ty, value = cast_env, line = 0, source_path = ""))
    let env_ref = alloc_expr(ir.Expr.expr_name(name = "env", ty = env_ptr_ty, pointer = false))
    let ref_field = alloc_expr(ir.Expr.expr_member(receiver = env_ref, member = "__mt_ref_count", ty = uint_ty))
    let one = alloc_expr(ir.Expr.expr_integer_literal(value = 1, ty = uint_ty))
    body.push(ir.Stmt.stmt_assignment(target = ref_field, operator = "-=", value = one))
    let zero = alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = uint_ty))
    let cond = alloc_expr(ir.Expr.expr_binary(operator = "==", left = ref_field, right = zero, ty = types.primitive("bool")))
    var then_body = vec.Vec[ir.Stmt].create()
    let free_call = alloc_expr(ir.Expr.expr_call(callee = "free", arguments = pack_single(alloc_expr(ir.Expr.expr_cast(target_type = void_ptr, expression = env_ref, ty = void_ptr))), ty = types.primitive("void")))
    then_body.push(ir.Stmt.stmt_expression(expression = free_call, line = 0, source_path = ""))
    body.push(ir.Stmt.stmt_if(condition = cond, then_body = then_body.as_span(), else_body = span[ir.Stmt]()))
    body.push(ir.Stmt.stmt_return(value = null, line = 0, source_path = ""))
    return ir.Function(name = c_name, linkage_name = c_name, params = params.as_span(), return_type = types.primitive("void"), body = body.as_span(), entry_point = false, method_receiver_param = false)


## Build a retain function for capturing procs (increments ref_count).
function build_capturing_retain(c_name: str, env_type_name: str) -> ir.Function:
    let void_ptr = types.Type.ty_generic(name = "ptr", args = sp_type(types.primitive("void")))
    let env_ptr_ty = types.Type.ty_generic(name = "ptr", args = sp_type(types.Type.ty_named(name = env_type_name)))
    let uint_ty = types.primitive("ptr_uint")
    var params = vec.Vec[ir.Param].create()
    params.push(ir.Param(name = "__mt_proc_env", linkage_name = "__mt_proc_env", ty = void_ptr, pointer = false))
    var body = vec.Vec[ir.Stmt].create()
    let env_expr = alloc_expr(ir.Expr.expr_name(name = "__mt_proc_env", ty = void_ptr, pointer = false))
    let cast_env = alloc_expr(ir.Expr.expr_cast(target_type = env_ptr_ty, expression = env_expr, ty = env_ptr_ty))
    body.push(ir.Stmt.stmt_local(name = "env", linkage_name = "env", ty = env_ptr_ty, value = cast_env, line = 0, source_path = ""))
    let env_ref = alloc_expr(ir.Expr.expr_name(name = "env", ty = env_ptr_ty, pointer = false))
    let ref_field = alloc_expr(ir.Expr.expr_member(receiver = env_ref, member = "__mt_ref_count", ty = uint_ty))
    let one = alloc_expr(ir.Expr.expr_integer_literal(value = 1, ty = uint_ty))
    body.push(ir.Stmt.stmt_assignment(target = ref_field, operator = "+=", value = one))
    body.push(ir.Stmt.stmt_return(value = null, line = 0, source_path = ""))
    return ir.Function(name = c_name, linkage_name = c_name, params = params.as_span(), return_type = types.primitive("void"), body = body.as_span(), entry_point = false, method_receiver_param = false)


## Build a non-capturing proc invoke function: unpacks env (unused), lowers the
## body.  Returns the body expression directly (or void return for no-return).
function build_proc_invoke_fn(ctx: ref[LowerCtx], method_params: span[ast.Param], return_type: ptr[ast.TypeRef]?, body: ptr[ast.Stmt], invoke_c_name: str) -> ir.Function:
    let saved_locals = ctx.locals
    let saved_counter = ctx.temp_counter
    ctx.locals = vec.Vec[LocalBinding].create()
    ctx.temp_counter = 0

    let void_ptr = types.Type.ty_generic(name = "ptr", args = sp_type(types.primitive("void")))
    var params = vec.Vec[ir.Param].create()
    params.push(ir.Param(name = "__mt_proc_env", linkage_name = "__mt_proc_env", ty = void_ptr, pointer = false))

    var pi: ptr_uint = 0
    while pi < method_params.len:
        var p: ast.Param
        unsafe:
            p = read(method_params.data + pi)
        let p_ty = resolve_field_type_ref(ctx, p.param_type)
        let pc = c_local_name(p.name)
        params.push(ir.Param(name = p.name, linkage_name = pc, ty = p_ty, pointer = false))
        ctx.locals.push(LocalBinding(name = p.name, c_name = pc, ty = p_ty, pointer = false))
        pi += 1

    var ret_ty = types.primitive("void")
    if return_type != null:
        ret_ty = resolve_type_ref(ctx, return_type)
    let body_stmts = lower_block(ctx, body)

    ctx.locals = saved_locals
    ctx.temp_counter = saved_counter
    return ir.Function(
        name = invoke_c_name,
        linkage_name = invoke_c_name,
        params = params.as_span(),
        return_type = ret_ty,
        body = body_stmts,
        entry_point = false,
        method_receiver_param = false,
    )


## Build a no-op release/retain function for non-capturing procs.
function build_proc_noop_fn(c_name: str) -> ir.Function:
    let void_ptr = types.Type.ty_generic(name = "ptr", args = sp_type(types.primitive("void")))
    var params = vec.Vec[ir.Param].create()
    params.push(ir.Param(name = "__mt_proc_env", linkage_name = "__mt_proc_env", ty = void_ptr, pointer = false))
    var body = vec.Vec[ir.Stmt].create()
    body.push(ir.Stmt.stmt_return(value = null, line = 0, source_path = ""))
    return ir.Function(name = c_name, linkage_name = c_name, params = params.as_span(), return_type = types.primitive("void"), body = body.as_span(), entry_point = false, method_receiver_param = false)


## The proc's invoke field type: `fn(env: ptr[void], params...) -> R`.
function proc_invoke_field_type(proc_ty: types.Type) -> types.Type:
    let void_ptr = types.Type.ty_generic(name = "ptr", args = sp_type(types.primitive("void")))
    match proc_ty:
        types.Type.ty_function as fn_ty:
            var all_params = vec.Vec[types.Type].create()
            all_params.push(void_ptr)
            var i: ptr_uint = 0
            while i < fn_ty.params.len:
                unsafe:
                    all_params.push(read(fn_ty.params.data + i))
                i += 1
            return types.Type.ty_function(params = all_params.as_span(), return_type = fn_ty.return_type, variadic = false)
        _:
            return types.Type.ty_error


## The proc's release/retain field type: `fn(env: ptr[void]) -> void`.
function proc_lifecycle_fn_type() -> types.Type:
    var params = vec.Vec[types.Type].create()
    params.push(types.Type.ty_generic(name = "ptr", args = sp_type(types.primitive("void"))))
    return types.Type.ty_function(params = params.as_span(), return_type = types.alloc_type(types.primitive("void")), variadic = false)
## fields `_0`, `_1`, ... and a `ty_tuple` type.  (Named tuples arrive later.)
function lower_tuple_literal(ctx: ref[LowerCtx], elements: span[ast.Expr]) -> ptr[ir.Expr]:
    var fields = vec.Vec[ir.AggregateField].create()
    var elem_types = vec.Vec[types.Type].create()
    var i: ptr_uint = 0
    while i < elements.len:
        let lowered = unsafe: lower_expr(ctx, elements.data + i)
        fields.push(ir.AggregateField(name = tuple_field_name(i), value = lowered))
        elem_types.push(ir_expr_type(lowered))
        i += 1
    return alloc_expr(ir.Expr.expr_aggregate_literal(
        ty = types.Type.ty_tuple(elements = elem_types.as_span()),
        fields = fields.as_span(),
    ))


function tuple_field_name(index: ptr_uint) -> str:
    var buf = string.String.create()
    buf.append("_")
    fmt.append_ptr_uint(ref_of(buf), index)
    return buf.as_str()


function tuple_element_type(t: types.Type, index: ptr_uint) -> types.Type:
    match t:
        types.Type.ty_tuple as tup:
            if index < tup.elements.len:
                unsafe:
                    return read(tup.elements.data + index)
            return types.Type.ty_error
        _:
            return types.Type.ty_error


## Lower `receiver[index]`: array receivers use a bounds-checked index, span
## receivers a bounds-checked span index, and raw pointers a plain index.
function lower_index_access(ctx: ref[LowerCtx], receiver: ptr[ast.Expr], index: ptr[ast.Expr], ep: ptr[ast.Expr]) -> ptr[ir.Expr]:
    let receiver_type = index_receiver_type(ctx, receiver)
    let recv = lower_expr(ctx, receiver)
    let index_expr = lower_expr(ctx, index)
    var elem_ty = expr_type(ctx, ep)
    if types.is_error(elem_ty):
        elem_ty = generic_first_arg(receiver_type)
    if is_array_type(receiver_type):
        return alloc_expr(ir.Expr.expr_checked_index(receiver = recv, index = index_expr, receiver_type = receiver_type, ty = elem_ty))
    if is_span_type(receiver_type):
        return alloc_expr(ir.Expr.expr_checked_span_index(receiver = recv, index = index_expr, receiver_type = receiver_type, ty = elem_ty))
    return alloc_expr(ir.Expr.expr_index(receiver = recv, index = index_expr, ty = elem_ty))


## The type of an index receiver: for a local/parameter identifier take its
## recorded binding type (which carries the correct array length); otherwise fall
## back to the analyzer's inferred type.
function index_receiver_type(ctx: ref[LowerCtx], receiver: ptr[ast.Expr]) -> types.Type:
    unsafe:
        match read(receiver):
            ast.Expr.expr_identifier as id:
                match lookup_local(ctx, id.name):
                    Option.some as lb:
                        return lb.value.ty
                    Option.none:
                        pass
            _:
                pass
    return expr_type(ctx, receiver)


function is_array_type(t: types.Type) -> bool:
    match t:
        types.Type.ty_generic as g:
            return g.name.equal("array") and g.args.len == 2
        _:
            return false


function is_span_type(t: types.Type) -> bool:
    match t:
        types.Type.ty_generic as g:
            return g.name.equal("span") and g.args.len == 1
        _:
            return false


function generic_first_arg(t: types.Type) -> types.Type:
    match t:
        types.Type.ty_generic as g:
            if g.args.len > 0:
                unsafe:
                    return read(g.args.data + 0)
            return types.Type.ty_error
        _:
            return types.Type.ty_error


## The result type carried by a lowered IR expression (used to recover a local's
## type when the analyzer left it unresolved, e.g. `span[T](...)` construction).
function ir_expr_type(ep: ptr[ir.Expr]) -> types.Type:
    unsafe:
        match read(ep):
            ir.Expr.expr_name as x:
                return x.ty
            ir.Expr.expr_member as x:
                return x.ty
            ir.Expr.expr_index as x:
                return x.ty
            ir.Expr.expr_checked_index as x:
                return x.ty
            ir.Expr.expr_checked_span_index as x:
                return x.ty
            ir.Expr.expr_call as x:
                return x.ty
            ir.Expr.expr_call_indirect as x:
                return x.ty
            ir.Expr.expr_unary as x:
                return x.ty
            ir.Expr.expr_binary as x:
                return x.ty
            ir.Expr.expr_conditional as x:
                return x.ty
            ir.Expr.expr_cast as x:
                return x.ty
            ir.Expr.expr_integer_literal as x:
                return x.ty
            ir.Expr.expr_boolean_literal as x:
                return x.ty
            ir.Expr.expr_string_literal as x:
                return x.ty
            ir.Expr.expr_address_of as x:
                return x.ty
            ir.Expr.expr_aggregate_literal as x:
                return x.ty
            ir.Expr.expr_variant_literal as x:
                return x.ty
            ir.Expr.expr_array_literal as x:
                return x.ty
            ir.Expr.expr_zero_init as x:
                return x.ty
            _:
                return types.Type.ty_error


function lower_call(ctx: ref[LowerCtx], callee: ptr[ast.Expr], args: span[ast.Argument], call_ep: ptr[ast.Expr]) -> ptr[ir.Expr]:
    unsafe:
        match read(callee):
            ast.Expr.expr_identifier as id:
                if id.name.equal("fatal"):
                    return lower_plain_call(ctx, "mt_fatal", args, call_ep, null)
                if id.name.equal("ptr_of") or id.name.equal("ref_of") or id.name.equal("const_ptr_of"):
                    if args.len == 1:
                        let inner = lower_expr(ctx, read(args.data + 0).arg_value)
                        return alloc_expr(ir.Expr.expr_address_of(expression = inner, ty = expr_type(ctx, call_ep)))
                # `read(p)` as an rvalue → pointer dereference `*p`.  The result
                # type is the pointer's element type (more reliable than the
                # analyzer's generically-recorded type inside monomorphized
                # bodies); fall back to the recorded call type otherwise.
                if id.name.equal("read"):
                    if args.len == 1:
                        let inner = lower_expr(ctx, read(args.data + 0).arg_value)
                        var base = ir_expr_type(inner)
                        if types.is_nullable_type(base):
                            base = types.unwrap_nullable(base)
                        var elem_ty = expr_type(ctx, call_ep)
                        if types.is_raw_pointer(base) or types.is_ref_type(base):
                            elem_ty = types.pointer_element(base)
                        return alloc_expr(ir.Expr.expr_unary(operator = "*", operand = inner, ty = qualify_type(ctx, elem_ty)))
                if ctx.analysis.structs.contains(id.name):
                    return lower_aggregate_literal(ctx, id.name, args)
                if struct_exists_in_imports(ctx, id.name):
                    return lower_aggregate_literal(ctx, id.name, args)
                let foreign_ptr = ctx.foreign_map.get(id.name)
                if foreign_ptr != null:
                    return lower_foreign_call(ctx, read(foreign_ptr), args, call_ep)
                let extern_ptr = ctx.extern_map.get(id.name)
                if extern_ptr != null:
                    return lower_plain_call(ctx, read(extern_ptr), args, call_ep, null)
                # Proc-typed local: `p(args)` → `p.invoke(p.env, args)`.
                match lookup_local(ctx, id.name):
                    Option.some as lb:
                        if is_proc_type(lb.value.ty):
                            return lower_proc_call(ctx, lb.value, args, call_ep)
                    Option.none:
                        pass
                var ret_ty = function_return_type(ctx, id.name)
                var ret_type_ptr = types.alloc_type(ret_ty)
                return lower_plain_call(ctx, naming.qualified_c_name(ctx.module_name, id.name), args, call_ep, ret_type_ptr)
            ast.Expr.expr_specialization as spec:
                return lower_specialization_call(ctx, spec.callee, spec.arguments, args, call_ep)
            ast.Expr.expr_member_access as ma:
                match read(ma.receiver):
                    ast.Expr.expr_identifier as recv_id:
                        # A non-generic variant arm constructor, e.g. `Token.number(value = 41)`.
                        if ctx.variants.contains(recv_id.name):
                            return lower_variant_literal(ctx, recv_id.name, ma.member_name, args)
                        let mod_ptr = ctx.analysis.imports.get(recv_id.name)
                        if mod_ptr != null:
                            let target_module = read(mod_ptr)
                            # Check if member_name is a struct in the imported module
                            # (struct constructor, e.g. ir.Field(name, ty)).
                            match find_imported_analysis(ctx, target_module):
                                Option.some as imported:
                                    if imported.value.structs.contains(ma.member_name):
                                        return lower_aggregate_literal(ctx, ma.member_name, args)
                                    # Check if ma.member_name is a variant arm in any
                                    # imported variant (e.g. types.Type.ty_named(name)).
                                    match find_imported_variant_arm(imported.value, ma.member_name):
                                        Option.some as var_name:
                                            let var_ty = types.Type.ty_imported(module_name = target_module, name = var_name.value, args = span[types.Type]())
                                            return alloc_expr(ir.Expr.expr_variant_literal(
                                                ty = var_ty,
                                                arm_name = ma.member_name,
                                                fields = collect_variant_literal_fields(ctx, args),
                                            ))
                                        Option.none:
                                            pass
                                Option.none:
                                    pass
                            let c_name = naming.qualified_c_name(target_module, ma.member_name)
                            var ret_ty = cross_module_return_type(ctx, c_name, call_ep)
                            var ret_type_ptr = types.alloc_type(ret_ty)
                            return lower_plain_call(ctx, c_name, args, call_ep, ret_type_ptr)
                    ast.Expr.expr_specialization as spec:
                        # A generic variant arm constructor, e.g. `Option[int].some(value = 42)`.
                        if spec.arguments.len > 0:
                            match read(spec.callee):
                                ast.Expr.expr_identifier as spec_id:
                                    if ctx.variants.contains(spec_id.name):
                                        return lower_generic_variant_literal(ctx, spec_id.name, spec.arguments, ma.member_name, args)
                                _:
                                    pass
                    ast.Expr.expr_member_access as inner_ma:
                        # Imported variant arm constructor: `alias.Variant.arm(args)`,
                        # e.g. `types.Type.ty_named(name)`.
                        match read(inner_ma.receiver):
                            ast.Expr.expr_identifier as inner_id:
                                let mod_ptr = ctx.analysis.imports.get(inner_id.name)
                                if mod_ptr != null:
                                    let target_module = read(mod_ptr)
                                    match find_imported_analysis(ctx, target_module):
                                        Option.some as imported:
                                            match find_imported_variant_arm(imported.value, ma.member_name):
                                                Option.some as var_name:
                                                    let var_ty = types.Type.ty_imported(module_name = target_module, name = var_name.value, args = span[types.Type]())
                                                    return alloc_expr(ir.Expr.expr_variant_literal(
                                                        ty = var_ty,
                                                        arm_name = ma.member_name,
                                                        fields = collect_variant_literal_fields(ctx, args),
                                                    ))
                                                Option.none:
                                                    pass
                                        Option.none:
                                            pass
                            _:
                                pass
                    _:
                        pass
                # Method call: receiver.method(args).  Resolve the method from the
                # receiver's type and lower to a direct C function call.
                let recv_ty = expr_type(ctx, ma.receiver)
                # Event builtin methods: must be checked before resolve_method_info
                # because they ARE registered in method_sigs for sema validation.
                if is_event_type(ctx, recv_ty):
                    let recv_ir = lower_expr(ctx, ma.receiver)
                    return lower_event_method(ctx, recv_ir, recv_ty, ma.member_name, args, call_ep)
                match try_generic_method_call(ctx, recv_ty, ma.member_name, ma.receiver, args, call_ep):
                    Option.some as gen_call:
                        return gen_call.value
                    Option.none:
                        pass
                match resolve_method_info(ctx, recv_ty, ma.member_name):
                    Option.some as mi:
                        return lower_method_resolved(ctx, mi.value, ma.receiver, args, call_ep)
                    Option.none:
                        pass
                # str_buffer[N] builtin methods: lower to C helper calls.
                if is_str_buffer_type(recv_ty):
                    let recv_ir = lower_expr(ctx, ma.receiver)
                    return lower_str_buffer_method(ctx, recv_ir, ma.member_name, args, call_ep)
                # dyn[I] dispatch: extract data + vtable, call through function pointer.
                # The type may be ty_named("dyn") or ty_dyn(iface) — try both.
                let ts = types.type_to_string(recv_ty)
                if ts.equal("dyn") or is_dyn_type(recv_ty):
                    let recv_ir = lower_expr(ctx, ma.receiver)
                    return lower_dyn_method_call(ctx, recv_ir, ma.member_name, args, call_ep)
                # Fallback: treat as a direct C call with the member as callee.
                var recv_type_name = named_type_name(recv_ty)
                if recv_type_name.is_none():
                    recv_type_name = try_spec_type_name(ma.receiver)
                let recv_name = recv_type_name else:
                    let fn_c_name = naming.qualified_member_c_name(ctx.module_name, "mt", ma.member_name)
                    var ir_args = vec.Vec[ir.Expr].create()
                    let recv_ir = lower_expr(ctx, ma.receiver)
                    unsafe:
                        ir_args.push(read(recv_ir))
                    var si: ptr_uint = 0
                    while si < args.len:
                        var arg: ast.Argument
                        unsafe:
                            arg = read(args.data + si)
                        let lowered = lower_expr(ctx, arg.arg_value)
                        unsafe:
                            ir_args.push(read(lowered))
                        si += 1
                    return alloc_expr(ir.Expr.expr_call(callee = fn_c_name, arguments = ir_args.as_span(), ty = expr_type(ctx, call_ep)))
                # Method found — try method resolution with the recovered type name.
                var resolved_ty = types.Type.ty_named(name = recv_name)
                match resolve_method_info(ctx, resolved_ty, ma.member_name):
                    Option.some as mi:
                        return lower_method_resolved(ctx, mi.value, ma.receiver, args, call_ep)
                    Option.none:
                        let fn_c_name = naming.qualified_member_c_name(ctx.module_name, recv_name, ma.member_name)
                        let recv_ir = lower_expr(ctx, ma.receiver)
                        var ir_args = vec.Vec[ir.Expr].create()
                        unsafe:
                            ir_args.push(read(recv_ir))
                        var si: ptr_uint = 0
                        while si < args.len:
                            var arg: ast.Argument
                            unsafe:
                                arg = read(args.data + si)
                            let lowered = lower_expr(ctx, arg.arg_value)
                            unsafe:
                                ir_args.push(read(lowered))
                            si += 1
                        return alloc_expr(ir.Expr.expr_call(callee = fn_c_name, arguments = ir_args.as_span(), ty = expr_type(ctx, call_ep)))
            _:
                fatal(c"lowering: unsupported call target")


## The result type of a cross-module call, resolved from the shared program-wide
## return map (keyed by C linkage name), falling back to the analyzer's recorded
## type for the call expression.
function cross_module_return_type(ctx: ref[LowerCtx], c_name: str, call_ep: ptr[ast.Expr]) -> types.Type:
    var ret_ty = types.Type.ty_error
    unsafe:
        var pr = read(ctx.program_returns)
        let rp = pr.get(c_name)
        if rp != null:
            ret_ty = read(rp)
    if not types.is_error(ret_ty):
        return qualify_type(ctx, ret_ty)
    # Also check per-module function_returns (monomorphized functions added here).
    let fp = ctx.function_returns.get(c_name)
    if fp != null:
        unsafe:
            ret_ty = read(fp)
        if not types.is_error(ret_ty):
            return qualify_type(ctx, ret_ty)
    return expr_type(ctx, call_ep)


## Lower a specialized call `Name[TypeArgs](args)`.  Phase 3 handles the builtin
## `span[T](data = ..., len = ...)` constructor as an aggregate literal; generic
## function-call monomorphization arrives in Phase 4.
function lower_specialization_call(ctx: ref[LowerCtx], spec_callee: ptr[ast.Expr], type_args: span[ast.TypeArgument], call_args: span[ast.Argument], call_ep: ptr[ast.Expr]) -> ptr[ir.Expr]:
    unsafe:
        match read(spec_callee):
            ast.Expr.expr_identifier as id:
                if id.name.equal("span") and type_args.len == 1:
                    var elem_args = vec.Vec[types.Type].create()
                    elem_args.push(resolve_type_ref(ctx, read(type_args.data + 0).value))
                    let span_ty = types.Type.ty_generic(name = "span", args = elem_args.as_span())
                    var fields = vec.Vec[ir.AggregateField].create()
                    var i: ptr_uint = 0
                    while i < call_args.len:
                        let arg = read(call_args.data + i)
                        let field_name = arg.arg_name else:
                            fatal(c"lowering: span construction requires named fields")
                        fields.push(ir.AggregateField(name = field_name, value = lower_expr(ctx, arg.arg_value)))
                        i += 1
                    return alloc_expr(ir.Expr.expr_aggregate_literal(ty = span_ty, fields = fields.as_span()))
                if id.name.equal("adapt") and type_args.len == 1:
                    return lower_adapt_call(ctx, read(type_args.data + 0).value, call_args)
                if id.name.equal("array") and type_args.len == 2:
                    var array_args = vec.Vec[types.Type].create()
                    array_args.push(resolve_type_ref(ctx, read(type_args.data + 0).value))
                    array_args.push(types.literal_int(resolve_array_length(read(type_args.data + 1).value)))
                    let array_ty = types.Type.ty_generic(name = "array", args = array_args.as_span())
                    var elements = vec.Vec[ir.Expr].create()
                    var ai: ptr_uint = 0
                    while ai < call_args.len:
                        let arg = read(call_args.data + ai)
                        elements.push(read(lower_expr(ctx, arg.arg_value)))
                        ai += 1
                    return alloc_expr(ir.Expr.expr_array_literal(ty = array_ty, elements = elements.as_span()))
                if id.name.equal("str_buffer") and type_args.len == 1:
                    let n_ty = resolve_type_ref(ctx, read(type_args.data + 0).value)
                    let sb_ty = types.Type.ty_generic(name = "str_buffer", args = sp_type(n_ty))
                    ensure_str_buffer_struct(ctx, sb_ty)
                    return alloc_expr(ir.Expr.expr_zero_init(ty = sb_ty))
                # Builtin generic callables: order[T], equal[T], hash[T] — lower
                # to direct C calls with a fixed suffix derived from the type.
                if id.name.equal("order") or id.name.equal("equal") or id.name.equal("hash"):
                    var ir_args = vec.Vec[ir.Expr].create()
                    var si: ptr_uint = 0
                    while si < call_args.len:
                        var arg: ast.Argument
                        unsafe:
                            arg = read(call_args.data + si)
                        let lowered = lower_expr(ctx, arg.arg_value)
                        unsafe:
                            ir_args.push(read(lowered))
                        si += 1
                    let fn_name = j2("mt_", j2(id.name, "_func"))
                    let ret_ty = if id.name.equal("equal"): types.primitive("bool") else: types.primitive("int")
                    return alloc_expr(ir.Expr.expr_call(callee = fn_name, arguments = ir_args.as_span(), ty = ret_ty))
                # Builtin `reinterpret[T](value)` → C cast.
                if id.name.equal("reinterpret") and type_args.len == 1:
                    let target_ty = qualify_type(ctx, resolve_type_ref(ctx, read(type_args.data + 0).value))
                    let lowered = lower_expr(ctx, unsafe: read(call_args.data + 0).arg_value)
                    return alloc_expr(ir.Expr.expr_cast(target_type = target_ty, expression = lowered, ty = target_ty))
                # Builtin `zero[T]` → zero-initialized value of type T.
                if id.name.equal("zero") and type_args.len == 1:
                    let z_ty = qualify_type(ctx, resolve_type_ref(ctx, read(type_args.data + 0).value))
                    return alloc_expr(ir.Expr.expr_zero_init(ty = z_ty))
                # Generic struct constructor, e.g. `Pair[int, int](first = 42, ...)`.
                # Check current module's structs first, then imported modules'
                # (structs referenced in monomorphized generic bodies may be
                # defined in a separate module).
                if all_call_args_named(call_args):
                    if ctx.analysis.structs.contains(id.name):
                        return lower_generic_aggregate_literal(ctx, id.name, type_args, call_args)
                    if struct_exists_in_imports(ctx, id.name):
                        return lower_generic_aggregate_literal(ctx, id.name, type_args, call_args)
            ast.Expr.expr_member_access as ma:
                match read(ma.receiver):
                    ast.Expr.expr_identifier as recv_id:
                        if ctx.analysis.imports.contains(recv_id.name) and all_call_args_named(call_args):
                            return lower_generic_aggregate_literal(ctx, ma.member_name, type_args, call_args)
                    _:
                        pass
                # Member-access specialization: e.g., `vec.Vec[string.String].create()`.
                # Route through method resolution with the concrete type from type args.
                let recv_ty = expr_type_for_spec(ctx, spec_callee, type_args)
                match try_generic_method_call(ctx, recv_ty, ma.member_name, ma.receiver, call_args, call_ep):
                    Option.some as gen_call:
                        return gen_call.value
                    Option.none:
                        pass
                match resolve_method_info(ctx, recv_ty, ma.member_name):
                    Option.some as mi:
                        return lower_method_resolved(ctx, mi.value, ma.receiver, call_args, call_ep)
                    Option.none:
                        pass
            _:
                pass
    # Generic function call, e.g. `first[int](p)`.  Lower a monomorphized copy of
    # the generic function body with concrete type arguments and emit a call to it.
    return lower_monomorphized_call(ctx, spec_callee, type_args, call_args, call_ep)


function resolve_method_return_from_import(ctx: ref[LowerCtx], module_name: str, sig: analyzer.FnSig, receiver_ty: types.Type) -> types.Type:
    var ret = sig.return_type
    if not sig.has_return_type:
        ret = types.primitive("void")
    match ret:
        types.Type.ty_named as rn:
            match receiver_ty:
                types.Type.ty_imported as rim:
                    if rim.args.len > 0:
                        ret = types.Type.ty_imported(module_name = module_name, name = rn.name, args = rim.args)
                    else:
                        ret = types.Type.ty_imported(module_name = module_name, name = rn.name, args = span[types.Type]())
                _:
                    ret = types.Type.ty_imported(module_name = module_name, name = rn.name, args = span[types.Type]())
        _:
            pass
    return qualify_type(ctx, ret)


function is_read_call(ep: ptr[ast.Expr]) -> Option[ptr[ast.Expr]]:
    unsafe:
        match read(ep):
            ast.Expr.expr_call as call:
                match read(call.callee):
                    ast.Expr.expr_identifier as id:
                        if id.name.equal("read") and call.args.len == 1:
                            return Option[ptr[ast.Expr]].some(value = read(call.args.data + 0).arg_value)
                    _:
                        pass
            _:
                pass
    return Option[ptr[ast.Expr]].none


function receiver_has_type_args(receiver_ty: types.Type) -> bool:
    match receiver_ty:
        types.Type.ty_imported as im:
            return im.args.len > 0
        _:
            return false


function all_call_args_named(args: span[ast.Argument]) -> bool:
    if args.len == 0:
        return false
    var i: ptr_uint = 0
    while i < args.len:
        let arg = unsafe: read(args.data + i)
        if arg.arg_name.is_none():
            return false
        i += 1
    return true


## Build the concrete type for a specialized member access, e.g.
## `expr_member_access(receiver = "vec", member = "Vec")` with type args
## `[string.String]` produces `ty_generic("Vec", [ty_imported("String")])`.
function expr_type_for_spec(ctx: ref[LowerCtx], spec_callee: ptr[ast.Expr], type_args: span[ast.TypeArgument]) -> types.Type:
    unsafe:
        match read(spec_callee):
            ast.Expr.expr_member_access as ma:
                var concrete = vec.Vec[types.Type].create()
                var i: ptr_uint = 0
                while i < type_args.len:
                    concrete.push(resolve_type_ref(ctx, read(type_args.data + i).value))
                    i += 1
                return types.Type.ty_generic(name = ma.member_name, args = concrete.as_span())
            ast.Expr.expr_identifier as id:
                var concrete = vec.Vec[types.Type].create()
                var i: ptr_uint = 0
                while i < type_args.len:
                    concrete.push(resolve_type_ref(ctx, read(type_args.data + i).value))
                    i += 1
                return types.Type.ty_generic(name = id.name, args = concrete.as_span())
            _:
                return types.Type.ty_error


## Lower a generic struct constructor `Name[TypeArgs](field = value, ...)` to an IR
## aggregate literal with the concrete type arguments resolved.
function lower_generic_aggregate_literal(ctx: ref[LowerCtx], struct_name: str, type_args: span[ast.TypeArgument], call_args: span[ast.Argument]) -> ptr[ir.Expr]:
    var concrete_args = vec.Vec[types.Type].create()
    var i: ptr_uint = 0
    while i < type_args.len:
        unsafe:
            concrete_args.push(resolve_type_ref(ctx, read(type_args.data + i).value))
        i += 1
    let ty = types.Type.ty_generic(name = struct_name, args = concrete_args.as_span())
    var fields = vec.Vec[ir.AggregateField].create()
    i = 0
    while i < call_args.len:
        var arg: ast.Argument
        unsafe:
            arg = read(call_args.data + i)
        let field_name = arg.arg_name else:
            fatal(c"lowering: generic struct construction requires named fields")
        fields.push(ir.AggregateField(name = field_name, value = lower_expr(ctx, arg.arg_value)))
        i += 1
    # Qualify the constructed type so its C name is module-prefixed
    # (`std_vec_Vec_int`), matching the type produced by `qualify_type` for the
    # same instance elsewhere; this also emits the concrete struct declaration.
    let result_ty = qualify_type(ctx, types.Type.ty_generic(name = struct_name, args = concrete_args.as_span()))
    return alloc_expr(ir.Expr.expr_aggregate_literal(ty = result_ty, fields = fields.as_span()))


## Ensure a concrete struct declaration exists for a generic struct specialized
## with concrete type arguments.  If not yet registered, build one by resolving
## the original struct's fields with type substitution.
function ensure_generic_struct_decl(ctx: ref[LowerCtx], struct_name: str, type_args: span[ast.TypeArgument], concrete_args: span[types.Type]) -> void:
    ensure_generic_struct_decl_named(ctx, struct_name, type_args, concrete_args, generic_struct_c_name(struct_name, concrete_args))


## Like `ensure_generic_struct_decl` but uses `decl_name` as the struct
## declaration name (for module-qualified naming of imported generic types).
function ensure_generic_struct_decl_named(ctx: ref[LowerCtx], struct_name: str, type_args: span[ast.TypeArgument], concrete_args: span[types.Type], decl_name: str) -> void:
    if ctx.generic_struct_decls.contains(decl_name):
        return
    # Guard against recursive monomorphization: when Node's `next` field
    # triggers another monomorphization of Node[str, bool], skip.
    if ctx.spec_in_progress.contains(decl_name):
        return
    ctx.spec_in_progress.set(decl_name, true)
    # Search the current module's AST first, then imported modules.
    var fields_opt = extract_generic_struct_fields(ctx, ctx.analysis, struct_name, concrete_args)
    if fields_opt.is_none():
        # Try each imported module.
        var import_values = ctx.analysis.imports.values()
        while true:
            let target_ptr = import_values.next() else:
                break
            let target_module = unsafe: read(target_ptr)
            match find_imported_analysis(ctx, target_module):
                Option.some as imported:
                    fields_opt = extract_generic_struct_fields(ctx, imported.value, struct_name, concrete_args)
                    if fields_opt.is_some():
                        break
                Option.none:
                    pass
    match fields_opt:
        Option.some as f:
            ctx.generic_struct_decls.set(decl_name, ir.StructDecl(
                name = decl_name,
                linkage_name = decl_name,
                fields = f.value,
                packed = false,
                alignment = 0,
                source_module = Option[str].none,
            ))
            ctx.generic_struct_instances.set(decl_name, GenericReceiver(owner_name = struct_name, concrete_args = concrete_args))
        Option.none:
            pass


## Extract and type-substitute the fields of a generic struct from a given
## module's AST.  Returns None if the struct declaration is not found.
function extract_generic_struct_fields(ctx: ref[LowerCtx], module_analysis: analyzer.Analysis, struct_name: str, concrete_args: span[types.Type]) -> Option[span[ir.Field]]:
    var found = false
    var ir_fields = vec.Vec[ir.Field].create()
    var di: ptr_uint = 0
    while di < module_analysis.source_file.declarations.len and not found:
        var d: ast.Decl
        unsafe:
            d = read(module_analysis.source_file.declarations.data + di)
        match d:
            ast.Decl.decl_struct as s:
                if s.name.equal(struct_name):
                    found = true
                    var sub = map_mod.Map[str, types.Type].create()
                    var spi: ptr_uint = 0
                    while spi < s.type_params.len and spi < concrete_args.len:
                        unsafe:
                            sub.set(read(s.type_params.data + spi).name, read(concrete_args.data + spi))
                        spi += 1
                    var fi: ptr_uint = 0
                    while fi < s.struct_fields.len:
                        var f: ast.Field
                        unsafe:
                            f = read(s.struct_fields.data + fi)
                        let raw_ty = resolve_field_type_ref(ctx, f.field_type)
                        let field_ty = substitute_type_params(ctx, raw_ty, ref_of(sub))
                        ir_fields.push(ir.Field(name = f.name, ty = qualify_type(ctx, field_ty)))
                        fi += 1
            _:
                pass
        di += 1
    if not found:
        return Option[span[ir.Field]].none
    return Option[span[ir.Field]].some(value = ir_fields.as_span())


function func_has_type_var(func: ir.Function) -> bool:
    if has_type_var_arg(sp_one(func.return_type)):
        return true
    var i: ptr_uint = 0
    while i < func.params.len:
        unsafe:
            if has_type_var_arg(sp_one(read(func.params.data + i).ty)):
                return true
        i += 1
    return false

function is_pointer_or_ref_type(t: types.Type) -> bool:
    match t:
        types.Type.ty_generic as g:
            return g.name.equal("ptr") or g.name.equal("const_ptr") or g.name.equal("ref")
        _:
            return false

function is_raw_type_param_name(name: str) -> bool:
    return name.equal("T") or name.equal("U") or name.equal("K") or name.equal("V") or name.equal("E")


function sp_one(t: types.Type) -> span[types.Type]:
    var buf = vec.Vec[types.Type].create()
    buf.push(t)
    return buf.as_span()

function has_type_var_arg(args: span[types.Type]) -> bool:
    var i: ptr_uint = 0
    while i < args.len:
        var t: types.Type
        unsafe:
            t = read(args.data + i)
        if type_is_type_var(t):
            return true
        i += 1
    return false

function type_is_type_var(t: types.Type) -> bool:
    match t:
        types.Type.ty_var:
            return true
        types.Type.ty_named as n:
            if n.name.equal("T") or n.name.equal("K") or n.name.equal("V") or n.name.equal("U") or n.name.equal("E"):
                return true
            return false
        types.Type.ty_imported as im:
            if im.name.equal("T") or im.name.equal("K") or im.name.equal("V") or im.name.equal("U") or im.name.equal("E"):
                return true
            if im.args.len > 0:
                if has_type_var_arg(im.args):
                    return true
            return false
        types.Type.ty_generic as g:
            return has_type_var_arg(g.args)
        types.Type.ty_nullable as nl:
            return unsafe: type_is_type_var(read(nl.base))
        _:
            return false


## The C type name for a concrete generic struct: `Pair` + `int` + `int` →
## `Pair_int_int`.  Mirrors `generic_c_type`.
function generic_struct_c_name(name: str, args: span[types.Type]) -> str:
    var buf = string.String.create()
    buf.append(name)
    var i: ptr_uint = 0
    while i < args.len:
        buf.append("_")
        unsafe:
            buf.append(naming.sanitize_identifier(types.type_to_string(read(args.data + i))))
        i += 1
    return buf.as_str()


## Lower a call to a generic function with concrete type arguments.  The generic
## function body is found in the module's declarations, type-substituted, and
## lowered.  The monomorphized copy is cached so subsequent calls to the same
## specialization reuse the already-lowered function.
function lower_monomorphized_call(ctx: ref[LowerCtx], callee: ptr[ast.Expr], type_args: span[ast.TypeArgument], call_args: span[ast.Argument], call_ep: ptr[ast.Expr]) -> ptr[ir.Expr]:
    var callee_name: str
    unsafe:
        match read(callee):
            ast.Expr.expr_identifier as id:
                callee_name = id.name
            ast.Expr.expr_member_access as ma:
                callee_name = ma.member_name
            _:
                fatal(c"lowering: unsupported generic callee")

    let gm = find_generic_function(ctx, callee_name) else:
        if ctx.loaded_modules.len <= 1:
            fatal(j2("lowering: monomorphization failed for ", callee_name))
        fatal(j2("lowering: could not find generic function decl for ", callee_name))

    # Name the specialization by its OWNER module so the same instance reached
    # from multiple caller modules dedups to one definition (see
    # dedup_append_functions).
    let spec_key = specialization_key(ctx, gm.module_name, callee_name, type_args)
    if not ctx.specialization_cache.contains(spec_key) and not ctx.spec_in_progress.contains(spec_key):
        lower_and_cache_specialization(ctx, gm, type_args, spec_key)
    let ret_ty = cross_module_return_type(ctx, spec_key, call_ep)
    var ret_type_ptr = types.alloc_type(ret_ty)
    return lower_plain_call(ctx, spec_key, call_args, call_ep, ret_type_ptr)


## A generic function's AST declaration plus the module that defines it.
struct GenericFunctionMatch:
    module_name: str
    decl: ast.Decl


## Find a generic function declaration by name.  The current module is searched
## first (so same-module generics resolve to their own module), then all other
## analyses, then raw loaded modules as a fallback for functions whose analysis
## copy is incomplete.
function find_generic_function(ctx: ref[LowerCtx], callee_name: str) -> Option[GenericFunctionMatch]:
    match find_func_in_source(ctx.analysis.source_file, callee_name):
        Option.some as d:
            return Option[GenericFunctionMatch].some(value = GenericFunctionMatch(module_name = ctx.module_name, decl = d.value))
        Option.none:
            pass
    var ai: ptr_uint = 0
    while ai < ctx.program_analyses.len:
        var a: analyzer.Analysis
        unsafe:
            a = read(ctx.program_analyses.data + ai)
        if not a.module_name.equal(ctx.module_name):
            match find_func_in_source(a.source_file, callee_name):
                Option.some as d:
                    return Option[GenericFunctionMatch].some(value = GenericFunctionMatch(module_name = a.module_name, decl = d.value))
                Option.none:
                    pass
        ai += 1
    var mi: ptr_uint = 0
    while mi < ctx.loaded_modules.len:
        var lm: loader.LoadedModule
        unsafe:
            lm = read(ctx.loaded_modules.data + mi)
        match find_func_in_source(lm.source_file, callee_name):
            Option.some as d:
                return Option[GenericFunctionMatch].some(value = GenericFunctionMatch(module_name = lm.module_name.as_str(), decl = d.value))
            Option.none:
                pass
        mi += 1
    return Option[GenericFunctionMatch].none


## Lower an uncached generic function specialization: build the type substitution
## map, then lower the body in the OWNER module's context (so its imports,
## foreign functions, variants, and recorded expression types resolve against the
## defining module rather than the caller) and cache it under `spec_key`.
function lower_and_cache_specialization(ctx: ref[LowerCtx], gm: GenericFunctionMatch, type_args: span[ast.TypeArgument], spec_key: str) -> void:
    ctx.spec_in_progress.set(spec_key, true)
    match gm.decl:
        ast.Decl.decl_function as fun:
            # Build type substitution from the function's type params, resolving
            # AND qualifying the type arguments in the CALLER's context: the
            # concrete type must become a fully-qualified name here (where it is
            # known) so the owner module — which may not import the argument's
            # defining module — renders it correctly rather than dropping the
            # module prefix.
            var sub = map_mod.Map[str, types.Type].create()
            var tpi: ptr_uint = 0
            while tpi < fun.type_params.len:
                var tp: ast.TypeParam
                unsafe:
                    tp = read(fun.type_params.data + tpi)
                if tpi < type_args.len:
                    let concrete = qualify_type(ctx, resolve_type_ref(ctx, unsafe: read(type_args.data + tpi).value))
                    sub.set(tp.name, concrete)
                tpi += 1

            # Save the caller context.
            var saved_module = ctx.module_name
            var saved_analysis = ctx.analysis
            var saved_foreign = ctx.foreign_map
            var saved_variants = ctx.variants
            var saved_locals = ctx.locals
            var saved_counter = ctx.temp_counter
            var saved_returns = ctx.function_returns

            # Switch to the owner module's context when its analysis is available.
            match find_imported_analysis(ctx, gm.module_name):
                Option.some as owner_a:
                    ctx.module_name = gm.module_name
                    ctx.analysis = owner_a.value
                    ctx.foreign_map = map_mod.Map[str, ForeignInfo].create()
                    ctx.variants = map_mod.Map[str, VariantInfo].create()
                    collect_foreign_functions(ctx, owner_a.value.source_file.declarations)
                    collect_variants(ctx, owner_a.value.source_file.declarations)
                    install_prelude_variants(ctx)
                Option.none:
                    pass

            ctx.locals = vec.Vec[LocalBinding].create()
            ctx.temp_counter = 0
            ctx.function_returns = map_mod.Map[str, types.Type].create()

            var spec_fun = lower_specialized_function(ctx, fun.name, fun.method_params, fun.return_type, fun.body, ref_of(sub))
            spec_fun.linkage_name = spec_key
            spec_fun.name = spec_key

            ctx.specialization_cache.set(spec_key, spec_fun)
            saved_returns.set(spec_key, spec_fun.return_type)

            # Restore the caller context.
            ctx.module_name = saved_module
            ctx.analysis = saved_analysis
            ctx.foreign_map = saved_foreign
            ctx.variants = saved_variants
            ctx.locals = saved_locals
            ctx.temp_counter = saved_counter
            ctx.function_returns = saved_returns
        _:
            fatal(j2("lowering: monomorphization failed, expected function decl for ", gm.module_name))


## Lower a payload variant arm constructor `Variant.arm(field = value, ...)` to an
## IR variant literal.  No-payload arms are handled in `lower_member_access`.
function lower_variant_literal(ctx: ref[LowerCtx], variant_name: str, arm_name: str, args: span[ast.Argument]) -> ptr[ir.Expr]:
    return alloc_expr(ir.Expr.expr_variant_literal(
        ty = types.Type.ty_imported(module_name = ctx.module_name, name = variant_name, args = span[types.Type]()),
        arm_name = arm_name,
        fields = collect_variant_literal_fields(ctx, args),
    ))


## Lower a generic variant arm constructor `Option[int].some(value = 42)`.  The
## type arguments resolve to concrete types; the call arguments map to field
## values.  The resulting type is `ty_generic("Option", [ty_int])`.
function lower_generic_variant_literal(ctx: ref[LowerCtx], variant_name: str, type_args: span[ast.TypeArgument], arm_name: str, call_args: span[ast.Argument]) -> ptr[ir.Expr]:
    var concrete_args = vec.Vec[types.Type].create()
    var i: ptr_uint = 0
    while i < type_args.len:
        unsafe:
            concrete_args.push(resolve_type_ref(ctx, read(type_args.data + i).value))
        i += 1
    let ty = types.Type.ty_generic(name = variant_name, args = concrete_args.as_span())
    return alloc_expr(ir.Expr.expr_variant_literal(
        ty = ty,
        arm_name = arm_name,
        fields = collect_variant_literal_fields(ctx, call_args),
    ))


function find_imported_variant_arm(module_analysis: analyzer.Analysis, arm_name: str) -> Option[str]:
    var di: ptr_uint = 0
    while di < module_analysis.source_file.declarations.len:
        var d: ast.Decl
        unsafe:
            d = read(module_analysis.source_file.declarations.data + di)
        match d:
            ast.Decl.decl_variant as vr:
                var ai: ptr_uint = 0
                while ai < vr.variant_arms.len:
                    var arm: ast.VariantArm
                    unsafe:
                        arm = read(vr.variant_arms.data + ai)
                    if arm.name.equal(arm_name):
                        return Option[str].some(value = vr.name)
                    ai += 1
            _:
                pass
        di += 1
    return Option[str].none


function collect_variant_literal_fields(ctx: ref[LowerCtx], args: span[ast.Argument]) -> span[ir.AggregateField]:
    var fields = vec.Vec[ir.AggregateField].create()
    var i: ptr_uint = 0
    while i < args.len:
        var arg: ast.Argument
        unsafe:
            arg = read(args.data + i)
        let field_name = arg.arg_name else:
            fatal(c"lowering: variant arm construction requires named fields")
        fields.push(ir.AggregateField(name = field_name, value = lower_expr(ctx, arg.arg_value)))
        i += 1
    return fields.as_span()


## Build a specialization key from the callee name + concrete type args.  For a
## same-module function `first[int]`, the key is `<module_prefix>_first_int`.  The
## key doubles as the monomorphized C linkage name.
function specialization_key(ctx: ref[LowerCtx], module_name: str, callee_name: str, type_args: span[ast.TypeArgument]) -> str:
    var buf = string.String.create()
    buf.append(naming.module_c_prefix(module_name))
    buf.append("_")
    buf.append(callee_name)
    var i: ptr_uint = 0
    while i < type_args.len:
        buf.append("_")
        let ty = resolve_type_ref(ctx, unsafe: read(type_args.data + i).value)
        buf.append(naming.sanitize_identifier(types.type_to_string(ty)))
        i += 1
    return buf.as_str()


## Lower a struct constructor `Name(field = value, ...)` to an IR aggregate
## literal, preserving the constructor's field order.
function lower_aggregate_literal(ctx: ref[LowerCtx], struct_name: str, args: span[ast.Argument]) -> ptr[ir.Expr]:
    var fields = vec.Vec[ir.AggregateField].create()
    var i: ptr_uint = 0
    while i < args.len:
        var arg: ast.Argument
        unsafe:
            arg = read(args.data + i)
        let field_name = arg.arg_name else:
            fatal(c"lowering: struct construction requires named fields")
        let value = lower_expr(ctx, arg.arg_value)
        fields.push(ir.AggregateField(name = field_name, value = value))
        i += 1
    var source_module = ctx.module_name
    if not ctx.analysis.structs.contains(struct_name):
        var import_values = ctx.analysis.imports.values()
        while true:
            let target_ptr = import_values.next() else:
                break
            let target_module = unsafe: read(target_ptr)
            match find_imported_analysis(ctx, target_module):
                Option.some as imported:
                    if imported.value.structs.contains(struct_name):
                        source_module = target_module
                        break
                Option.none:
                    pass
    return alloc_expr(ir.Expr.expr_aggregate_literal(
        ty = types.Type.ty_imported(module_name = source_module, name = struct_name, args = span[types.Type]()),
        fields = fields.as_span(),
    ))


# =============================================================================
#  dyn[I] interface lowering (mirrors Ruby's lowerer_dyn)
# =============================================================================

## Lower `adapt[I](value)`: construct a dyn[I] fat pointer `{ data: void*, vtable: void* }`.
## The concrete type is extracted from the argument (unwrapping ref[T] to T).  A vtable
## struct type, wrapper functions, and a vtable global constant are generated on first use.
function lower_adapt_call(ctx: ref[LowerCtx], iface_type_ref: ptr[ast.TypeRef], args: span[ast.Argument]) -> ptr[ir.Expr]:
    if args.len != 1:
        fatal(c"dyn lowering: adapt requires exactly one argument")
    var arg = unsafe: read(args.data + 0)
    let arg_value = lower_expr(ctx, arg.arg_value)
    let arg_type = expr_type(ctx, arg.arg_value)
    let concrete_type = if types.is_ref_type(arg_type): types.pointer_element(arg_type) else: arg_type
    let iface_name = unsafe: analyzer.qname_to_str(read(iface_type_ref).name)
    match find_interface_analysis(ctx, iface_name):
        Option.some as ia:
            let methods = ia.value.methods
            let concrete_name = canonical_type_name(ctx.module_name, concrete_type)
            let vtable_name = ensure_dyn_vtable(ctx, concrete_name, concrete_type, iface_name, methods, ia.value.module_name)
            var void_ptr = types.Type.ty_generic(name = "ptr", args = sp_type(types.primitive("void")))
            let vtable_ptr_ty = types.Type.ty_generic(name = "ptr", args = sp_type(types.primitive("void")))
            return alloc_expr(ir.Expr.expr_aggregate_literal(
                ty = types.Type.ty_dyn(iface = iface_name),
                fields = sp_fields2(
                    ir.AggregateField(name = "data", value = alloc_expr(ir.Expr.expr_cast(target_type = void_ptr, expression = arg_value, ty = void_ptr))),
                    ir.AggregateField(name = "vtable", value = alloc_expr(ir.Expr.expr_cast(
                        target_type = void_ptr,
                        expression = alloc_expr(ir.Expr.expr_address_of(
                            expression = alloc_expr(ir.Expr.expr_name(name = vtable_name, ty = void_ptr, pointer = false)),
                            ty = void_ptr,
                        )),
                        ty = void_ptr,
                    ))),
                ),
            ))
        Option.none:
            fatal(c"dyn lowering: interface not found")


## Interface analysis: the owning module name and the methods declared by the interface.
struct InterfaceAnalysis:
    module_name: str
    methods: span[ast.InterfaceMethod]


## Find an interface's definition across all loaded modules.  Searches the current
## module first, then imported modules.
function find_interface_analysis(ctx: ref[LowerCtx], iface_name: str) -> Option[InterfaceAnalysis]:
    # Short qualified name: `mod.Interface`.
    if iface_name.find_byte(46).is_some():  # '.'
        var parts_buf = string.String.create()
        var idx: ptr_uint = 0
        while idx < iface_name.len:
            let b = iface_name.byte_at(idx)
            if b == 46:
                let mod_name = parts_buf.as_str()
                let rest = iface_name.slice(idx + 1, iface_name.len - idx - 1)
                if not rest.is_valid_utf8():
                    break
                match find_imported_analysis(ctx, mod_name):
                    Option.some as imported:
                        let m_ptr = imported.value.interfaces.get(rest)
                        if m_ptr != null:
                            return Option[InterfaceAnalysis].some(value = InterfaceAnalysis(module_name = mod_name, methods = unsafe: read(m_ptr)))
                    Option.none:
                        pass
                return Option[InterfaceAnalysis].none
            parts_buf.push_byte(b)
            idx += 1
        return Option[InterfaceAnalysis].none
    # Bare name: search current module then all imported modules.
    let m_ptr = ctx.analysis.interfaces.get(iface_name)
    if m_ptr != null:
        return Option[InterfaceAnalysis].some(value = InterfaceAnalysis(module_name = ctx.module_name, methods = unsafe: read(m_ptr)))
    var import_values = ctx.analysis.imports.values()
    while true:
        let target_ptr = import_values.next() else:
            break
        let target_module = unsafe: read(target_ptr)
        match find_imported_analysis(ctx, target_module):
            Option.some as imported:
                let i_ptr = imported.value.interfaces.get(iface_name)
                if i_ptr != null:
                    # Is the interface public in that module?
                    if not module_has_private_interface(imported.value.source_file, iface_name):
                        return Option[InterfaceAnalysis].some(value = InterfaceAnalysis(module_name = target_module, methods = unsafe: read(i_ptr)))
            Option.none:
                pass
    return Option[InterfaceAnalysis].none


function module_has_private_interface(file: ast.SourceFile, iface_name: str) -> bool:
    var di: ptr_uint = 0
    while di < file.declarations.len:
        var d: ast.Decl
        unsafe:
            d = read(file.declarations.data + di)
        match d:
            ast.Decl.decl_interface as iface:
                if iface.name.equal(iface_name) and not iface.visibility:
                    return true
            _:
                pass
        di += 1
    return false


## Ensure a vtable for the given concrete type and interface exists.  Generates the
## vtable struct type declaration once per interface, and the wrapper functions +
## global vtable constant once per (type, interface) pair.  Returns the vtable global name.
function ensure_dyn_vtable(ctx: ref[LowerCtx], concrete_name: str, concrete_type: types.Type, iface_name: str, methods: span[ast.InterfaceMethod], iface_module_name: str) -> str:
    let vtable_c_name = j5("mt_vtable_", concrete_name, "_", iface_name, "")
    if ctx.dyn_generated_vtables.contains(vtable_c_name):
        return vtable_c_name

    # Ensure the vtable struct type exists (once per interface).
    let vtable_type_c_name = j3("mt_vtable_", iface_name, "")
    ensure_dyn_vtable_struct(ctx, vtable_type_c_name, methods)

    # Generate wrapper functions and vtable constant.
    var wrappers = gen_dyn_vtable_wrappers(ctx, concrete_name, concrete_type, iface_name, methods, iface_module_name)
    gen_dyn_vtable_constant(ctx, iface_name, vtable_type_c_name, vtable_c_name, ref_of(wrappers), methods)

    # Ensure the dyn struct type exists (once per interface).
    ensure_dyn_struct_type(ctx, iface_name)

    ctx.dyn_generated_vtables.set(vtable_c_name, true)
    return vtable_c_name


## Ensure the dyn struct type `mt_dyn_{iface}` exists.
function ensure_dyn_struct_type(ctx: ref[LowerCtx], iface_name: str) -> void:
    let name = j3("mt_dyn_", iface_name, "")
    var iter = ctx.pending_dyn_structs.iter()
    while true:
        let s_ptr = iter.next() else:
            break
        if unsafe: read(s_ptr).linkage_name.equal(name):
            return
    var void_ptr = types.Type.ty_generic(name = "ptr", args = sp_type(types.primitive("void")))
    var fields = vec.Vec[ir.Field].create()
    fields.push(ir.Field(name = "data", ty = void_ptr))
    fields.push(ir.Field(name = "vtable", ty = void_ptr))
    ctx.pending_dyn_structs.push(ir.StructDecl(name = name, linkage_name = name, fields = fields.as_span(), packed = false, alignment = 0, source_module = Option[str].none))


## Ensure the vtable struct type `mt_vtable_{iface}` exists.  Fields are function
## pointer types so the C backend can render calls through them directly.
function ensure_dyn_vtable_struct(ctx: ref[LowerCtx], vtable_type_c_name: str, methods: span[ast.InterfaceMethod]) -> void:
    var iter = ctx.pending_dyn_vtable_structs.iter()
    while true:
        let s_ptr = iter.next() else:
            break
        if unsafe: read(s_ptr).linkage_name.equal(vtable_type_c_name):
            return
    var void_ptr = types.Type.ty_generic(name = "ptr", args = sp_type(types.primitive("void")))
    var fields = vec.Vec[ir.Field].create()
    var mi: ptr_uint = 0
    while mi < methods.len:
        var m: ast.InterfaceMethod
        unsafe:
            m = read(methods.data + mi)
        var fn_params = vec.Vec[types.Type].create()
        fn_params.push(void_ptr)
        var pi: ptr_uint = 0
        while pi < m.method_params.len:
            var p: ast.Param
            unsafe:
                p = read(m.method_params.data + pi)
            fn_params.push(resolve_field_type_ref(ctx, p.param_type))
            pi += 1
        let ret = if m.return_type != null: resolve_field_type_ref(ctx, unsafe: read(ptr[ast.TypeRef]<-m.return_type)) else: types.primitive("void")
        let fn_ty = types.Type.ty_function(params = fn_params.as_span(), return_type = types.alloc_type(ret), variadic = false)
        fields.push(ir.Field(name = m.name, ty = fn_ty))
        mi += 1
    ctx.pending_dyn_vtable_structs.push(ir.StructDecl(name = vtable_type_c_name, linkage_name = vtable_type_c_name, fields = fields.as_span(), packed = false, alignment = 0, source_module = Option[str].none))


## Generate wrapper functions for each interface method, calling through to the
## concrete type's method implementation.  Returns a map from method name to wrapper C name.
function gen_dyn_vtable_wrappers(ctx: ref[LowerCtx], concrete_name: str, concrete_type: types.Type, iface_name: str, methods: span[ast.InterfaceMethod], iface_module_name: str) -> map_mod.Map[str, str]:
    var wrappers = map_mod.Map[str, str].create()
    var void_ptr = types.Type.ty_generic(name = "ptr", args = sp_type(types.primitive("void")))
    let concrete_type_name = named_type_name(concrete_type) else:
        fatal(c"dyn lowering: concrete type must be nominal")
    # Use a module-qualified type so c_type renders the correct C struct name.
    var c_ty = types.Type.ty_imported(module_name = ctx.module_name, name = concrete_type_name, args = span[types.Type]())
    var mi: ptr_uint = 0
    while mi < methods.len:
        var m: ast.InterfaceMethod
        unsafe:
            m = read(methods.data + mi)
        let wrapper_c_name = j5("__dyn_", concrete_name, "_", iface_name, j2("_", m.name))
        var wrapper_params = vec.Vec[ir.Param].create()
        wrapper_params.push(ir.Param(name = "data", linkage_name = "data", ty = void_ptr, pointer = false))
        var pi: ptr_uint = 0
        while pi < m.method_params.len:
            var p: ast.Param
            unsafe:
                p = read(m.method_params.data + pi)
            let p_ty = resolve_field_type_ref(ctx, p.param_type)
            wrapper_params.push(ir.Param(name = p.name, linkage_name = c_local_name(p.name), ty = p_ty, pointer = false))
            pi += 1
        let ret_ty = if m.return_type != null: resolve_field_type_ref(ctx, unsafe: read(ptr[ast.TypeRef]<-m.return_type)) else: types.primitive("void")
        # Find the method info for the concrete type's method (search all modules).
        var method_info_opt: Option[DynMethodLookup]
        match concrete_type:
            types.Type.ty_named as n:
                method_info_opt = find_dyn_method(ctx, n.name, m.name, concrete_type)
            types.Type.ty_imported as im:
                method_info_opt = find_dyn_method(ctx, im.name, m.name, concrete_type)
            _:
                pass
        match method_info_opt:
            Option.some as dm:
                var real_c_name = string.String.create()
                real_c_name.append(naming.module_c_prefix(dm.value.module_name))
                real_c_name.append("_")
                real_c_name.append(dm.value.type_name)
                real_c_name.append("_")
                real_c_name.append(m.name)
                let call_name = real_c_name.as_str()
                # Build body: cast data, call real method, return.
                var body_stmts = vec.Vec[ir.Stmt].create()
                var call_args = vec.Vec[ir.Expr].create()
                if dm.value.method_kind != ast.MethodKind.mk_static:
                    let is_editable = dm.value.method_kind == ast.MethodKind.mk_editable
                    let inner_ptr_ty = types.Type.ty_generic(name = "ptr", args = sp_type(c_ty))
                    if is_editable:
                        unsafe:
                            call_args.push(read(alloc_expr(ir.Expr.expr_cast(target_type = inner_ptr_ty, expression = alloc_expr(ir.Expr.expr_name(name = "data", ty = void_ptr, pointer = false)), ty = inner_ptr_ty))))
                    else:
                        unsafe:
                            call_args.push(read(alloc_expr(ir.Expr.expr_unary(operator = "*", operand = alloc_expr(ir.Expr.expr_cast(target_type = inner_ptr_ty, expression = alloc_expr(ir.Expr.expr_name(name = "data", ty = void_ptr, pointer = false)), ty = inner_ptr_ty)), ty = c_ty))))
                pi = 0
                while pi < m.method_params.len:
                    var p: ast.Param
                    unsafe:
                        p = read(m.method_params.data + pi)
                    unsafe:
                        call_args.push(read(alloc_expr(ir.Expr.expr_name(name = c_local_name(p.name), ty = resolve_field_type_ref(ctx, p.param_type), pointer = false))))
                    pi += 1
                let call_ret_ty = if types.is_void(ret_ty): types.primitive("void") else: ret_ty
                body_stmts.push(ir.Stmt.stmt_return(
                    value = alloc_expr(ir.Expr.expr_call(callee = call_name, arguments = call_args.as_span(), ty = call_ret_ty)),
                    line = 0,
                    source_path = "",
                ))
                ctx.pending_dyn_wrappers.push(ir.Function(
                    name = wrapper_c_name,
                    linkage_name = wrapper_c_name,
                    params = wrapper_params.as_span(),
                    return_type = ret_ty,
                    body = body_stmts.as_span(),
                    entry_point = false,
                    method_receiver_param = false,
                ))
                wrappers.set(m.name, wrapper_c_name)
            Option.none:
                fatal(c"dyn lowering: could not find method implementation")
        mi += 1
    return wrappers


struct DynMethodLookup:
    module_name: str
    type_name: str
    method_kind: ast.MethodKind


function find_dyn_method(ctx: ref[LowerCtx], type_name: str, method_name: str, concrete_type: types.Type) -> Option[DynMethodLookup]:
    let key = analyzer.method_key(type_name, method_name)
    if ctx.analysis.method_sigs.contains(key):
        let sig_ptr = ctx.analysis.method_sigs.get(key) else:
            return Option[DynMethodLookup].none
        return Option[DynMethodLookup].some(value = DynMethodLookup(module_name = ctx.module_name, type_name = type_name, method_kind = unsafe: read(sig_ptr).method_kind))
    var import_values = ctx.analysis.imports.values()
    while true:
        let target_ptr = import_values.next() else:
            break
        let target_module = unsafe: read(target_ptr)
        match find_imported_analysis(ctx, target_module):
            Option.some as imported:
                if imported.value.method_keys.contains(key):
                    let sig_ptr = imported.value.method_sigs.get(key) else:
                        return Option[DynMethodLookup].none
                    return Option[DynMethodLookup].some(value = DynMethodLookup(module_name = target_module, type_name = type_name, method_kind = unsafe: read(sig_ptr).method_kind))
            Option.none:
                pass
    return Option[DynMethodLookup].none


## Generate a vtable global constant of type `mt_vtable_{iface}`, holding pointers
## to the wrapper functions.
function gen_dyn_vtable_constant(ctx: ref[LowerCtx], iface_name: str, vtable_type_name: str, vtable_c_name: str, wrappers: ref[map_mod.Map[str, str]], methods: span[ast.InterfaceMethod]) -> void:
    let const_ty = types.Type.ty_named(name = vtable_type_name)
    var fields = vec.Vec[ir.AggregateField].create()
    var mi: ptr_uint = 0
    while mi < methods.len:
        var m: ast.InterfaceMethod
        unsafe:
            m = read(methods.data + mi)
        let wrapper_ptr = unsafe: read(wrappers).get(m.name) else:
            fatal(c"dyn lowering: missing wrapper for method")
        let wrapper_c_name = unsafe: read(wrapper_ptr)
        # Use the function type for the field so the constant matches the struct decl.
        var fn_params = vec.Vec[types.Type].create()
        fn_params.push(types.Type.ty_generic(name = "ptr", args = sp_type(types.primitive("void"))))
        var pi: ptr_uint = 0
        while pi < m.method_params.len:
            var p: ast.Param
            unsafe:
                p = read(m.method_params.data + pi)
            fn_params.push(resolve_field_type_ref(ctx, p.param_type))
            pi += 1
        let ret = if m.return_type != null: resolve_field_type_ref(ctx, unsafe: read(ptr[ast.TypeRef]<-m.return_type)) else: types.primitive("void")
        let fn_ty = types.Type.ty_function(params = fn_params.as_span(), return_type = types.alloc_type(ret), variadic = false)
        fields.push(ir.AggregateField(name = m.name, value = alloc_expr(ir.Expr.expr_name(name = wrapper_c_name, ty = fn_ty, pointer = false))))
        mi += 1
    ctx.pending_dyn_constants.push(ir.Constant(
        name = vtable_c_name,
        linkage_name = vtable_c_name,
        ty = const_ty,
        value = alloc_expr(ir.Expr.expr_aggregate_literal(ty = const_ty, fields = fields.as_span())),
    ))


## Lower a dyn method call `receiver.method(args)` where receiver has ty_dyn.
## Extracts data and vtable members, casts vtable to its struct type, and calls
## through the method function pointer.
function lower_dyn_method_call(ctx: ref[LowerCtx], recv: ptr[ir.Expr], method_name: str, args: span[ast.Argument], call_ep: ptr[ast.Expr]) -> ptr[ir.Expr]:
    var void_ptr = types.Type.ty_generic(name = "ptr", args = sp_type(types.primitive("void")))
    let data = alloc_expr(ir.Expr.expr_member(receiver = recv, member = "data", ty = void_ptr))
    let vtable_raw = alloc_expr(ir.Expr.expr_member(receiver = recv, member = "vtable", ty = void_ptr))
    # Cast vtable void* to the vtable struct pointer type (mt_vtable_{iface}*).
    # The iface name is embedded in the ty_dyn type: use ty_named to match c_type.
    let recv_ty = ir_expr_type(recv)
    let vtable_c_type = dyn_vtable_c_type(recv_ty)
    var vtable_ptr_ty = types.Type.ty_generic(name = "ptr", args = sp_type(types.Type.ty_named(name = vtable_c_type)))
    let vtable_cast = alloc_expr(ir.Expr.expr_cast(target_type = vtable_ptr_ty, expression = vtable_raw, ty = vtable_ptr_ty))
    let method_fn = alloc_expr(ir.Expr.expr_member(receiver = vtable_cast, member = method_name, ty = void_ptr))
    var call_args = vec.Vec[ir.Expr].create()
    unsafe:
        call_args.push(read(data))
    var i: ptr_uint = 0
    while i < args.len:
        var arg: ast.Argument
        unsafe:
            arg = read(args.data + i)
        let lowered = lower_expr(ctx, arg.arg_value)
        unsafe:
            call_args.push(read(lowered))
        i += 1
    return alloc_expr(ir.Expr.expr_call_indirect(callee = method_fn, arguments = call_args.as_span(), ty = expr_type(ctx, call_ep)))


## The C type name for a dyn[I] vtable struct: "mt_vtable_" + iface_name.
function dyn_vtable_c_type(t: types.Type) -> str:
    let ts = types.type_to_string(t)
    # The type string could be "dyn" for ty_named or the iface name for ty_dyn.
    # For ty_dyn(iface = "Shape"), the string is "Shape".
    # If ts is "dyn", we can't determine the iface — use a fallback.
    if ts.equal("dyn"):
        return "mt_vtable_unknown"
    return j3("mt_vtable_", ts, "")


## Resolved method call info: the C function name and the method kind (needed to
## decide whether to pass the receiver by pointer or by value).
struct MethodInfo:
    c_name: str
    method_kind: ast.MethodKind
    return_type: types.Type


## HACK: qualified_member_c_name but with an explicit module prefix.
function qualified_member_c_name_ext(module_prefix: str, owner: str, member: str) -> str:
    var buf = string.String.create()
    buf.append(module_prefix)
    buf.append("_")
    buf.append(owner)
    buf.append("_")
    buf.append(member)
    return buf.as_str()


## Extract a type name from a specialization receiver when the analyzer's
## expr_type returned void.  For `expr_specialization(callee = member_access("string", "String"), ...)`,
## returns `Option.some("String")`.
function try_spec_type_name(receiver: ptr[ast.Expr]) -> Option[str]:
    unsafe:
        match read(receiver):
            ast.Expr.expr_specialization as spec:
                match read(spec.callee):
                    ast.Expr.expr_member_access as ma:
                        return Option[str].some(value = ma.member_name)
                    ast.Expr.expr_identifier as id:
                        return Option[str].some(value = id.name)
                    _:
                        return Option[str].none
            _:
                return Option[str].none


## Resolve a method call `receiver.method(args)` to its C function name and kind,
## looking up the receiver's type in the analyzer's `method_sigs` map.  Returns
## `Option.none` when the receiver type has no such method.
function resolve_method_info(ctx: ref[LowerCtx], receiver_ty: types.Type, method_name: str) -> Option[MethodInfo]:
    let type_name = named_type_name(receiver_ty) else:
        let gen_var = generic_variant_name(receiver_ty)
        match gen_var:
            Option.some as gv:
                let key = analyzer.method_key(gv.value, method_name)
                if ctx.analysis.method_sigs.contains(key):
                    let sig_ptr = ctx.analysis.method_sigs.get(key) else:
                        return Option[MethodInfo].none
                    let sig = unsafe: read(sig_ptr)
                    var ret = sig.return_type
                    if not sig.has_return_type:
                        ret = types.primitive("void")
                    return Option[MethodInfo].some(value = MethodInfo(c_name = naming.qualified_member_c_name(ctx.module_name, gv.value, method_name), method_kind = sig.method_kind, return_type = ret))
            Option.none:
                pass
        return Option[MethodInfo].none
    let key = analyzer.method_key(type_name, method_name)
    if ctx.analysis.method_sigs.contains(key):
        let sig_ptr = ctx.analysis.method_sigs.get(key) else:
            return Option[MethodInfo].none
        let sig = unsafe: read(sig_ptr)
        var ret = sig.return_type
        if not sig.has_return_type:
            ret = types.primitive("void")
        return Option[MethodInfo].some(value = MethodInfo(c_name = naming.qualified_member_c_name(ctx.module_name, type_name, method_name), method_kind = sig.method_kind, return_type = ret))
    # Search imported modules' method_sigs when the method is not found locally.
    var ai: ptr_uint = 0
    while ai < ctx.program_analyses.len:
        var a: analyzer.Analysis
        unsafe:
            a = read(ctx.program_analyses.data + ai)
        if a.module_name.equal(ctx.module_name):
            ai += 1
            continue
        if a.method_sigs.contains(key):
            let sig_ptr = a.method_sigs.get(key) else:
                ai += 1
                continue
            let sig = unsafe: read(sig_ptr)
            let mod_prefix = naming.module_c_prefix(a.module_name)
            var ret = sig.return_type
            if not sig.has_return_type:
                ret = types.primitive("void")
            # If the method returns a locally-named struct (ty_named), which is
            # defined in the imported module, convert it to ty_imported so the C
            # backend produces the module-qualified C name.
            match ret:
                types.Type.ty_named as rn:
                    if a.structs.contains(rn.name):
                        ret = types.Type.ty_imported(module_name = a.module_name, name = rn.name, args = span[types.Type]())
                _:
                    pass
            return Option[MethodInfo].some(value = MethodInfo(
                c_name = qualified_member_c_name_ext(mod_prefix, type_name, method_name),
                method_kind = sig.method_kind,
                return_type = resolve_method_return_from_import(ctx, a.module_name, sig, receiver_ty),
            ))
        ai += 1
    return Option[MethodInfo].none


function lower_method_resolved(ctx: ref[LowerCtx], mi: MethodInfo, receiver: ptr[ast.Expr], args: span[ast.Argument], call_ep: ptr[ast.Expr]) -> ptr[ir.Expr]:
    let recv = lower_expr(ctx, receiver)
    var ir_args = vec.Vec[ir.Expr].create()
    match build_receiver_arg(recv, mi.method_kind):
        Option.some as recv_arg:
            unsafe:
                ir_args.push(read(recv_arg.value))
        Option.none:
            pass
    var i: ptr_uint = 0
    while i < args.len:
        var arg: ast.Argument
        unsafe:
            arg = read(args.data + i)
        let lowered = lower_expr(ctx, arg.arg_value)
        unsafe:
            ir_args.push(read(lowered))
        i += 1
    return alloc_expr(ir.Expr.expr_call(callee = mi.c_name, arguments = ir_args.as_span(), ty = mi.return_type))


## Build the receiver argument for a method call, applying auto-ref / auto-deref
## so the passed value matches the C receiver parameter:
##   - static:   no receiver argument (returns none)
##   - editable: parameter is `ptr[T]`; pass a pointer receiver through, else take
##               its address (`&value`)
##   - plain:    parameter is `T` by value; dereference a pointer receiver (`*p`),
##               else pass the value through
## This mirrors the Ruby lowerer's implicit receiver borrow/deref and, in
## particular, makes `this.method()` calls inside editable methods (where `this`
## is already a pointer) pass `this` directly instead of `&this`.
function build_receiver_arg(recv: ptr[ir.Expr], method_kind: ast.MethodKind) -> Option[ptr[ir.Expr]]:
    if method_kind == ast.MethodKind.mk_static:
        return Option[ptr[ir.Expr]].none
    let recv_ty = ir_expr_type(recv)
    let recv_is_pointer = is_pointer_or_ref_type(recv_ty)
    if method_kind == ast.MethodKind.mk_editable:
        if recv_is_pointer:
            return Option[ptr[ir.Expr]].some(value = recv)
        return Option[ptr[ir.Expr]].some(value = alloc_expr(ir.Expr.expr_address_of(
            expression = recv,
            ty = types.Type.ty_generic(name = "ptr", args = sp_type(recv_ty)),
        )))
    # Plain value receiver.
    if recv_is_pointer:
        return Option[ptr[ir.Expr]].some(value = alloc_expr(ir.Expr.expr_unary(
            operator = "*",
            operand = recv,
            ty = types.pointer_element(recv_ty),
        )))
    return Option[ptr[ir.Expr]].some(value = recv)


# =============================================================================
#  Generic method monomorphization
#
#  Generic *functions* are monomorphized by `lower_monomorphized_call`.  Methods
#  on generic types (e.g. `Vec[int].create()`, `v.push(7)` where `v: Vec[int]`)
#  are monomorphized here: a method call on a concrete instance of a user-defined
#  generic struct clones the method body with the struct's type parameters bound
#  to the receiver's concrete type arguments and emits a specialized C function.
#
#  Mirrors the Ruby lowerer, where `specialize_function_binding` derives the
#  substitution from the receiver type (`infer_receiver_type_substitutions`) and
#  `instantiate_function_binding` produces a specialized instance.  The self-host
#  uses inline caller-side monomorphization (like its generic-function path) and
#  lowers the body in the *owner* module's context so the method's recorded
#  expression types and imports resolve correctly.
# =============================================================================

## A concrete generic receiver: the struct name and its resolved type arguments
## (e.g. `Vec` + `[int]`).  Type-parameter arguments are resolved through the
## active substitution so nested method calls inside monomorphized bodies work.
struct GenericReceiver:
    owner_name: str
    concrete_args: span[types.Type]


## A located generic method: the module that defines the extending block, the
## struct's type-parameter names, and the method's AST declaration.
struct GenericMethodMatch:
    owner_module: str
    struct_param_names: span[str]
    method: ast.Method


## The first component of a qualified name (`vec.Vec` -> "vec"; `Vec` -> "Vec").
function qname_first(qn: ast.QualifiedName) -> str:
    if qn.parts.len == 0:
        return ""
    return unsafe: read(qn.parts.data + 0)


## The type-parameter names declared by an extending block's receiver type
## arguments (`extending Vec[T]:` -> ["T"]).
function type_param_names_of(args: span[ast.TypeRef]) -> span[str]:
    var names = vec.Vec[str].create()
    var i: ptr_uint = 0
    while i < args.len:
        unsafe:
            names.push(qname_first(read(args.data + i).name))
        i += 1
    return names.as_span()


## A named method within an extending block's method list.
function find_method_in_block(methods: span[ast.Method], name: str) -> Option[ast.Method]:
    var i: ptr_uint = 0
    while i < methods.len:
        var m: ast.Method
        unsafe:
            m = read(methods.data + i)
        if m.name.equal(name):
            return Option[ast.Method].some(value = m)
        i += 1
    return Option[ast.Method].none


## True when a type is an unresolved type parameter (`ty_var`, or a bare named
## type using a raw parameter letter) — i.e. not a concrete type argument.
function type_is_unresolved_param(t: types.Type) -> bool:
    if type_is_type_var(t):
        return true
    match t:
        types.Type.ty_named as n:
            return is_raw_type_param_name(n.name)
        types.Type.ty_imported as im:
            return is_raw_type_param_name(im.name)
        _:
            return false


## Extract a concrete generic-struct receiver from a receiver type.  Returns
## none for non-generic, builtin (`span`/`array`/`ptr`/...), and prelude-variant
## (`Option`/`Result`) receivers, which are handled by other lowering paths.
## Type-parameter arguments are resolved through the active substitution; if any
## remain abstract the receiver is not a concrete instance and none is returned.
function generic_receiver_info(ctx: ref[LowerCtx], recv_ty: types.Type) -> Option[GenericReceiver]:
    # Auto-deref: when the receiver is a pointer or ref, unwrap to the pointee
    # type because method calls auto-dereference the receiver.
    var effective = recv_ty
    if types.is_raw_pointer(effective) or types.is_ref_type(effective):
        effective = types.pointer_element(effective)
    var owner_name: str
    var raw_args: span[types.Type]
    match effective:
        types.Type.ty_imported as im:
            owner_name = im.name
            raw_args = im.args
        types.Type.ty_generic as g:
            if is_builtin_pointer_generic(g.name):
                return Option[GenericReceiver].none
            owner_name = g.name
            raw_args = g.args
        types.Type.ty_named as n:
            let instance_ptr = ctx.generic_struct_instances.get(n.name)
            if instance_ptr == null:
                return Option[GenericReceiver].none
            let inst = unsafe: read(instance_ptr)
            owner_name = inst.owner_name
            raw_args = inst.concrete_args
        _:
            return Option[GenericReceiver].none
    if raw_args.len == 0:
        return Option[GenericReceiver].none
    if is_prelude_variant_name(owner_name):
        return Option[GenericReceiver].none
    var resolved = vec.Vec[types.Type].create()
    var i: ptr_uint = 0
    while i < raw_args.len:
        let arg = unsafe: read(raw_args.data + i)
        let concrete = substitute_type_params(ctx, arg, ref_of(ctx.type_substitution))
        if type_is_unresolved_param(concrete):
            return Option[GenericReceiver].none
        resolved.push(concrete)
        i += 1
    return Option[GenericReceiver].some(value = GenericReceiver(owner_name = owner_name, concrete_args = resolved.as_span()))


## Locate a generic method by owner-struct name and method name: search every
## module for a generic extending block (`extending Owner[...]:`) on a struct
## named `owner_name` that declares `method_name`.  Restricting to modules that
## declare the struct excludes prelude variants and non-struct receivers.
function find_generic_method(ctx: ref[LowerCtx], owner_name: str, method_name: str) -> Option[GenericMethodMatch]:
    var ai: ptr_uint = 0
    while ai < ctx.program_analyses.len:
        var a: analyzer.Analysis
        unsafe:
            a = read(ctx.program_analyses.data + ai)
        if a.structs.contains(owner_name) or struct_in_source(a, owner_name):
            var di: ptr_uint = 0
            while di < a.source_file.declarations.len:
                var d: ast.Decl
                unsafe:
                    d = read(a.source_file.declarations.data + di)
                match d:
                    ast.Decl.decl_extending_block as ex:
                        let type_ref = unsafe: read(ex.type_name)
                        if qname_first(type_ref.name).equal(owner_name) and type_ref.arguments.len > 0:
                            match find_method_in_block(ex.methods, method_name):
                                Option.some as m:
                                    return Option[GenericMethodMatch].some(value = GenericMethodMatch(
                                        owner_module = a.module_name,
                                        struct_param_names = type_param_names_of(type_ref.arguments),
                                        method = m.value,
                                    ))
                                Option.none:
                                    pass
                    _:
                        pass
                di += 1
        ai += 1
    return Option[GenericMethodMatch].none


## Extract a concrete generic-struct receiver from a specialization receiver
## expression (`Vec[int]` in `Vec[int].create()`), reading the real type
## arguments from the AST.  This is needed because `expr_type` records a
## placeholder (`ty_error`) argument for specialization expressions.
function spec_receiver_info(ctx: ref[LowerCtx], receiver: ptr[ast.Expr]) -> Option[GenericReceiver]:
    unsafe:
        match read(receiver):
            ast.Expr.expr_specialization as spec:
                let owner_name = spec_callee_name(spec.callee) else:
                    return Option[GenericReceiver].none
                if is_builtin_pointer_generic(owner_name) or is_prelude_variant_name(owner_name):
                    return Option[GenericReceiver].none
                if spec.arguments.len == 0:
                    return Option[GenericReceiver].none
                var resolved = vec.Vec[types.Type].create()
                var i: ptr_uint = 0
                while i < spec.arguments.len:
                    let raw = resolve_type_ref(ctx, read(spec.arguments.data + i).value)
                    let concrete = substitute_type_params(ctx, raw, ref_of(ctx.type_substitution))
                    if types.is_error(concrete) or type_is_unresolved_param(concrete):
                        return Option[GenericReceiver].none
                    resolved.push(concrete)
                    i += 1
                return Option[GenericReceiver].some(value = GenericReceiver(owner_name = owner_name, concrete_args = resolved.as_span()))
            _:
                return Option[GenericReceiver].none


## The struct name a specialization callee refers to (`vec.Vec` -> "Vec";
## `Vec` -> "Vec").
function spec_callee_name(callee: ptr[ast.Expr]) -> Option[str]:
    unsafe:
        match read(callee):
            ast.Expr.expr_member_access as ma:
                return Option[str].some(value = ma.member_name)
            ast.Expr.expr_identifier as id:
                return Option[str].some(value = id.name)
            _:
                return Option[str].none


## Attempt to lower a method call as a generic-method monomorphization.  Returns
## none when the receiver is not a concrete instance of a user generic struct, or
## when the method declares its own type parameters (deferred — those need
## call-site type-argument inference and fall through to ordinary resolution).
function try_generic_method_call(ctx: ref[LowerCtx], recv_ty: types.Type, method_name: str, receiver: ptr[ast.Expr], args: span[ast.Argument], call_ep: ptr[ast.Expr]) -> Option[ptr[ir.Expr]]:
    var info_opt = spec_receiver_info(ctx, receiver)
    if info_opt.is_none():
        info_opt = generic_receiver_info(ctx, recv_ty)
    if info_opt.is_none():
        # Fallback for identifier receivers (`this`, locals): the analyzer's
        # recorded type can lack recoverable type arguments, but the binding's
        # lowered IR type carries the concrete (collapsed) struct name, which the
        # generic-struct instance map can map back to its type arguments.
        # Restricted to identifiers because lowering them has no side effects.
        var is_identifier = false
        unsafe:
            match read(receiver):
                ast.Expr.expr_identifier:
                    is_identifier = true
                _:
                    pass
        if is_identifier:
            info_opt = generic_receiver_info(ctx, ir_expr_type(lower_expr(ctx, receiver)))
    let info = info_opt else:
        return Option[ptr[ir.Expr]].none
    let gm = find_generic_method(ctx, info.owner_name, method_name) else:
        return Option[ptr[ir.Expr]].none
    if gm.method.type_params.len > 0:
        return Option[ptr[ir.Expr]].none
    return Option[ptr[ir.Expr]].some(value = lower_monomorphized_method(ctx, info, gm, method_name, receiver, args))


## Lower a monomorphized method call: ensure the specialized method body exists,
## then emit a direct C call to it with the receiver argument.  The specialized
## C name groups by the concrete struct (`std_vec_Vec_int_push`), matching the
## monomorphized struct type produced by `qualify_type`.
function lower_monomorphized_method(ctx: ref[LowerCtx], info: GenericReceiver, gm: GenericMethodMatch, method_name: str, receiver: ptr[ast.Expr], args: span[ast.Argument]) -> ptr[ir.Expr]:
    let struct_c = naming.qualified_c_name(gm.owner_module, generic_struct_c_name(info.owner_name, info.concrete_args))
    let method_c = j3(struct_c, "_", method_name)

    if not ctx.specialization_cache.contains(method_c) and not ctx.spec_in_progress.contains(method_c):
        ensure_monomorphized_method(ctx, method_c, info, gm)

    var ret_ty = types.primitive("void")
    let cached = ctx.specialization_cache.get(method_c)
    if cached != null:
        ret_ty = unsafe: read(cached).return_type

    let recv = lower_expr(ctx, receiver)
    var ir_args = vec.Vec[ir.Expr].create()
    match build_receiver_arg(recv, gm.method.method_kind):
        Option.some as recv_arg:
            unsafe:
                ir_args.push(read(recv_arg.value))
        Option.none:
            pass
    var i: ptr_uint = 0
    while i < args.len:
        var arg: ast.Argument
        unsafe:
            arg = read(args.data + i)
        let lowered = lower_expr(ctx, arg.arg_value)
        unsafe:
            ir_args.push(read(lowered))
        i += 1
    return alloc_expr(ir.Expr.expr_call(callee = method_c, arguments = ir_args.as_span(), ty = ret_ty))


## Lower and cache a monomorphized method body once, in the owner module's
## context.  The context switch (module name, analysis, foreign map, variants)
## makes the body's recorded expression types and import-qualified references
## resolve against the defining module rather than the caller.
function ensure_monomorphized_method(ctx: ref[LowerCtx], method_c: str, info: GenericReceiver, gm: GenericMethodMatch) -> void:
    ctx.spec_in_progress.set(method_c, true)
    let owner_a = find_imported_analysis(ctx, gm.owner_module) else:
        return

    var sub = map_mod.Map[str, types.Type].create()
    var pi: ptr_uint = 0
    while pi < gm.struct_param_names.len and pi < info.concrete_args.len:
        unsafe:
            sub.set(read(gm.struct_param_names.data + pi), read(info.concrete_args.data + pi))
        pi += 1

    var saved_module = ctx.module_name
    var saved_analysis = ctx.analysis
    var saved_foreign = ctx.foreign_map
    var saved_variants = ctx.variants
    var saved_locals = ctx.locals
    var saved_counter = ctx.temp_counter
    var saved_returns = ctx.function_returns
    var saved_sub = ctx.type_substitution

    ctx.module_name = gm.owner_module
    ctx.analysis = owner_a
    ctx.foreign_map = map_mod.Map[str, ForeignInfo].create()
    ctx.variants = map_mod.Map[str, VariantInfo].create()
    ctx.locals = vec.Vec[LocalBinding].create()
    ctx.temp_counter = 0
    ctx.function_returns = map_mod.Map[str, types.Type].create()
    ctx.type_substitution = sub
    collect_foreign_functions(ctx, owner_a.source_file.declarations)
    collect_variants(ctx, owner_a.source_file.declarations)
    install_prelude_variants(ctx)

    let spec_fun = lower_specialized_method(ctx, method_c, info, gm, ref_of(sub))
    ctx.specialization_cache.set(method_c, spec_fun)
    saved_returns.set(method_c, spec_fun.return_type)

    ctx.module_name = saved_module
    ctx.analysis = saved_analysis
    ctx.foreign_map = saved_foreign
    ctx.variants = saved_variants
    ctx.locals = saved_locals
    ctx.temp_counter = saved_counter
    ctx.function_returns = saved_returns
    ctx.type_substitution = saved_sub


## Lower a single generic method to an IR function with the struct's type
## parameters substituted.  Mirrors `lower_method`, but resolves the receiver and
## parameter/return types through `substitute_type_params` with `sub`.
function lower_specialized_method(ctx: ref[LowerCtx], method_c: str, info: GenericReceiver, gm: GenericMethodMatch, sub: ref[map_mod.Map[str, types.Type]]) -> ir.Function:
    let m = gm.method
    ctx.locals.clear()
    ctx.temp_counter = 0

    let recv_struct_ty = qualify_type(ctx, types.Type.ty_imported(
        module_name = gm.owner_module,
        name = info.owner_name,
        args = info.concrete_args,
    ))

    var ir_params = vec.Vec[ir.Param].create()
    if m.method_kind != ast.MethodKind.mk_static:
        let recv_ty = if m.method_kind == ast.MethodKind.mk_editable: types.Type.ty_generic(name = "ptr", args = sp_type(recv_struct_ty)) else: recv_struct_ty
        ir_params.push(ir.Param(name = "this", linkage_name = c_local_name("this"), ty = recv_ty, pointer = false))
        ctx.locals.push(LocalBinding(name = "this", c_name = c_local_name("this"), ty = recv_ty, pointer = false))

    var pi: ptr_uint = 0
    while pi < m.method_params.len:
        var p: ast.Param
        unsafe:
            p = read(m.method_params.data + pi)
        let p_ty = qualify_type(ctx, substitute_type_params(ctx, resolve_field_type_ref(ctx, p.param_type), sub))
        let c_pname = c_local_name(p.name)
        let is_ptr = is_pointer_or_ref_type(p_ty)
        ir_params.push(ir.Param(name = p.name, linkage_name = c_pname, ty = p_ty, pointer = is_ptr))
        ctx.locals.push(LocalBinding(name = p.name, c_name = c_pname, ty = p_ty, pointer = is_ptr))
        pi += 1

    var ret_ty = types.primitive("void")
    let return_ref = m.return_type
    if return_ref != null:
        let resolved_ret = resolve_field_type_ref(ctx, unsafe: read(return_ref))
        ret_ty = qualify_type(ctx, substitute_type_params(ctx, resolved_ret, sub))

    var saved_sub = ctx.type_substitution
    ctx.type_substitution = read(sub)
    let body_ir = lower_block(ctx, m.body)
    ctx.type_substitution = saved_sub

    return ir.Function(
        name = method_c,
        linkage_name = method_c,
        params = ir_params.as_span(),
        return_type = ret_ty,
        body = body_ir,
        entry_point = false,
        method_receiver_param = m.method_kind != ast.MethodKind.mk_static,
    )


## Wrap a function reference in a proc struct with a synthetic invoke function
## that calls the original function, plus no-op release/retain.
function lower_fn_to_proc(ctx: ref[LowerCtx], fn_c_name: str, fn_ty: types.Type) -> ptr[ir.Expr]:
    ctx.proc_counter += 1
    var prefix = string.String.create()
    prefix.append(naming.module_c_prefix(ctx.module_name))
    prefix.append("__fn_wrap_")
    fmt.append_ptr_uint(ref_of(prefix), ctx.proc_counter)

    var invoke_c = string.String.create()
    invoke_c.append(prefix.as_str())
    invoke_c.append("__invoke")
    var release_c = string.String.create()
    release_c.append(prefix.as_str())
    release_c.append("__release")
    var retain_c = string.String.create()
    retain_c.append(prefix.as_str())
    retain_c.append("__retain")

    let invoke_str = invoke_c.as_str()
    let release_str = release_c.as_str()
    let retain_str = retain_c.as_str()

    match fn_ty:
        types.Type.ty_function as fnt:
            let void_ptr = types.Type.ty_generic(name = "ptr", args = sp_type(types.primitive("void")))
            var inv_params = vec.Vec[ir.Param].create()
            inv_params.push(ir.Param(name = "__mt_proc_env", linkage_name = "__mt_proc_env", ty = void_ptr, pointer = false))
            var call_args = vec.Vec[ir.Expr].create()
            var pi: ptr_uint = 0
            while pi < fnt.params.len:
                var p_ty: types.Type
                unsafe:
                    p_ty = read(fnt.params.data + pi)
                let pname = jstr_i("arg_", pi)
                inv_params.push(ir.Param(name = pname, linkage_name = pname, ty = p_ty, pointer = false))
                let arg_expr = alloc_expr(ir.Expr.expr_name(name = pname, ty = p_ty, pointer = false))
                unsafe:
                    call_args.push(read(arg_expr))
                pi += 1
            var ret_ty = types.primitive("void")
            unsafe:
                ret_ty = read(fnt.return_type)
            var inv_body = vec.Vec[ir.Stmt].create()
            if is_void_type(ret_ty):
                let call = alloc_expr(ir.Expr.expr_call(callee = fn_c_name, arguments = call_args.as_span(), ty = ret_ty))
                inv_body.push(ir.Stmt.stmt_expression(expression = call, line = 0, source_path = ""))
                inv_body.push(ir.Stmt.stmt_return(value = null, line = 0, source_path = ""))
            else:
                let call = alloc_expr(ir.Expr.expr_call(callee = fn_c_name, arguments = call_args.as_span(), ty = ret_ty))
                inv_body.push(ir.Stmt.stmt_return(value = call, line = 0, source_path = ""))

            ctx.pending_synthetic_functions.push(ir.Function(name = invoke_str, linkage_name = invoke_str, params = inv_params.as_span(), return_type = ret_ty, body = inv_body.as_span(), entry_point = false, method_receiver_param = false))
            ctx.pending_synthetic_functions.push(build_proc_noop_fn(retain_str))
            ctx.pending_synthetic_functions.push(build_proc_noop_fn(release_str))

            # Ensure the proc struct type exists for this signature.
            let proc_name = proc_type_name_from_signature(fn_ty)
            let proc_ty = proc_ensure_struct_decl(ctx, proc_name, fn_ty)

            let lifecycle_ty = proc_lifecycle_fn_type()
            var fields = vec.Vec[ir.AggregateField].create()
            fields.push(ir.AggregateField(name = "env", value = alloc_expr(ir.Expr.expr_null_literal(ty = void_ptr))))
            fields.push(ir.AggregateField(name = "invoke", value = alloc_expr(ir.Expr.expr_name(name = invoke_str, ty = proc_invoke_field_type(fn_ty), pointer = false))))
            fields.push(ir.AggregateField(name = "release", value = alloc_expr(ir.Expr.expr_name(name = release_str, ty = lifecycle_ty, pointer = false))))
            fields.push(ir.AggregateField(name = "retain", value = alloc_expr(ir.Expr.expr_name(name = retain_str, ty = lifecycle_ty, pointer = false))))
            return alloc_expr(ir.Expr.expr_aggregate_literal(ty = proc_ty, fields = fields.as_span()))
        _:
            fatal(c"lowering: fn_to_proc requires function type")


## String concatenation helpers.
function j2(a: str, b: str) -> str:
    var buf = string.String.create()
    buf.append(a)
    buf.append(b)
    return buf.as_str()


function j3(a: str, b: str, c: str) -> str:
    var buf = string.String.create()
    buf.append(a)
    buf.append(b)
    buf.append(c)
    return buf.as_str()


function j4(a: str, b: str, c: str, d: str) -> str:
    var buf = string.String.create()
    buf.append(a)
    buf.append(b)
    buf.append(c)
    buf.append(d)
    return buf.as_str()


function j5(a: str, b: str, c: str, d: str, e: str) -> str:
    var buf = string.String.create()
    buf.append(a)
    buf.append(b)
    buf.append(c)
    buf.append(d)
    buf.append(e)
    return buf.as_str()


function j6(a: str, b: str, c: str, d: str, e: str, f: str) -> str:
    var buf = string.String.create()
    buf.append(a)
    buf.append(b)
    buf.append(c)
    buf.append(d)
    buf.append(e)
    buf.append(f)
    return buf.as_str()


## Build a "arg_N" string from an integer index.
function jstr_i(prefix: str, n: ptr_uint) -> str:
    var buf = string.String.create()
    buf.append(prefix)
    fmt.append_ptr_uint(ref_of(buf), n)
    return buf.as_str()

## True when a type is void.
function is_void_type(t: types.Type) -> bool:
    match t:
        types.Type.ty_primitive as p:
            return p.name.equal("void")
        _:
            return false


## True when a type is a str_buffer[N] type.
function is_str_buffer_type(t: types.Type) -> bool:
    match t:
        types.Type.ty_generic as g:
            return g.name.equal("str_buffer")
        _:
            return false


# =============================================================================
#  Event runtime — delegates to C runtime helpers for slot management.
# =============================================================================

## True when `t` is the type of a declared event.
function is_event_type(ctx: ref[LowerCtx], t: types.Type) -> bool:
    match t:
        types.Type.ty_named as n:
            return ctx.analysis.events.contains(n.name)
        _:
            return false


## Extract the event name from an event type (ty_named).
function event_name_from_type(t: types.Type) -> str:
    match t:
        types.Type.ty_named as n:
            return n.name
        _:
            fatal(c"event type is not ty_named")


## Ensure event runtime structs are declared (slot type, event type, subscript type).
## Called lazily on first event method call.
function ensure_event_runtime(ctx: ref[LowerCtx], event_name: str) -> EventRuntimeInfo:
    let existing_ptr = ctx.event_runtimes.get(event_name)
    if existing_ptr != null:
        return unsafe: read(existing_ptr)
    let ev_ptr = ctx.analysis.events.get(event_name) else:
        fatal(c"ensure_event_runtime: event not found")
    var ev = unsafe: read(ev_ptr)
    let ptr_uint_ty = types.primitive("ptr_uint")
    let bool_ty = types.primitive("bool")
    let void_ptr_ty = types.Type.ty_generic(name = "ptr", args = sp_type(types.primitive("void")))
    let linkage = naming.qualified_c_name(ctx.module_name, event_name)
    let slot_cn = j2(linkage, "__slot")
    let event_cn = linkage
    # Slot struct: { active, once, generation, listener }
    ctx.pending_event_structs.push(ir.StructDecl(
        name = slot_cn, linkage_name = slot_cn,
        fields = sp_field4(
            ir.Field(name = "active", ty = bool_ty),
            ir.Field(name = "once", ty = bool_ty),
            ir.Field(name = "generation", ty = ptr_uint_ty),
            ir.Field(name = "listener", ty = void_ptr_ty),
        ),
        packed = false, alignment = 0, source_module = Option[str].none,
    ))
    # Event struct: { slots: array[Slot, capacity] }
    let capacity_val: long = long<-(ev.capacity)
    let slot_ty = types.Type.ty_named(name = slot_cn)
    let slot_arr_ty = types.Type.ty_generic(name = "array", args = sp_type2(slot_ty, types.literal_int(capacity_val)))
    ctx.pending_event_structs.push(ir.StructDecl(
        name = event_cn, linkage_name = event_cn,
        fields = sp_field1(ir.Field(name = "slots", ty = slot_arr_ty)),
        packed = false, alignment = 0, source_module = Option[str].none,
    ))
    # Subscript struct: { slot, generation }
    if not ctx.subscription_emitted:
        ctx.pending_event_structs.push(ir.StructDecl(
            name = "mt_subscription", linkage_name = "mt_subscription",
            fields = sp_field2(
                ir.Field(name = "slot", ty = ptr_uint_ty),
                ir.Field(name = "generation", ty = ptr_uint_ty),
            ),
            packed = false, alignment = 0, source_module = Option[str].none,
        ))
        ctx.subscription_emitted = true
    var has_payload = false
    var payload_ty = types.primitive("void")
    if ev.payload_type != null:
        has_payload = true
        let pt = ev.payload_type else:
            fatal(c"ensure_event_runtime: payload type is null")
        payload_ty = resolve_type_ref(ctx, pt)
    var info = EventRuntimeInfo(
        name = event_name, linkage_name = linkage, capacity = ptr_uint<-(ev.capacity),
        has_payload = has_payload, payload_type = payload_ty,
        slot_c_name = slot_cn, event_c_name = event_cn,
        subscribe_c_name = "mt_event_subscribe",
        subscribe_once_c_name = "mt_event_subscribe_once",
        unsubscribe_c_name = "mt_event_unsubscribe",
        emit_c_name = "mt_event_emit",
    )
    ctx.event_runtimes.set(event_name, info)
    return info


## Lower an event method call: emit, subscribe, subscribe_once, or unsubscribe.
## Routes to C runtime helpers (mt_event_*) and wraps subscribe results in
## Option[mt_subscription] for let-else integration.
function lower_event_method(ctx: ref[LowerCtx], recv: ptr[ir.Expr], recv_ty: types.Type, method_name: str, args: span[ast.Argument], call_ep: ptr[ast.Expr]) -> ptr[ir.Expr]:
    let ev_name = event_name_from_type(recv_ty)
    var info = ensure_event_runtime(ctx, ev_name)
    let void_ty = types.primitive("void")
    let bool_ty = types.primitive("bool")
    let ptr_uint_ty = types.primitive("ptr_uint")
    # Address of the event struct
    let event_ptr_ty = types.Type.ty_generic(name = "ptr", args = sp_type(types.Type.ty_named(name = info.event_c_name)))
    let recv_addr = alloc_expr(ir.Expr.expr_address_of(expression = recv, ty = event_ptr_ty))
    if method_name.equal("emit"):
        var call_args = vec.Vec[ir.Expr].create()
        unsafe:
            call_args.push(read(recv_addr))
            call_args.push(read(alloc_expr(ir.Expr.expr_integer_literal(value = long<-(info.capacity), ty = ptr_uint_ty))))
        return alloc_expr(ir.Expr.expr_call(callee = info.emit_c_name, arguments = call_args.as_span(), ty = void_ty))
    if method_name.equal("subscribe") or method_name.equal("subscribe_once"):
        let callee = if method_name.equal("subscribe"): info.subscribe_c_name else: info.subscribe_once_c_name
        var call_args = vec.Vec[ir.Expr].create()
        unsafe:
            call_args.push(read(recv_addr))
            call_args.push(read(alloc_expr(ir.Expr.expr_integer_literal(value = long<-(info.capacity), ty = ptr_uint_ty))))
        let listener_val = lower_listener_arg(ctx, unsafe: read(args.data + 0).arg_value)
        unsafe:
            call_args.push(read(listener_val))
        let sub_ty = types.Type.ty_named(name = "mt_subscription")
        return alloc_expr(ir.Expr.expr_call(callee = callee, arguments = call_args.as_span(), ty = sub_ty))
    if method_name.equal("unsubscribe"):
        var call_args = vec.Vec[ir.Expr].create()
        unsafe:
            call_args.push(read(recv_addr))
            call_args.push(read(alloc_expr(ir.Expr.expr_integer_literal(value = long<-(info.capacity), ty = ptr_uint_ty))))
        let sub_val = lower_expr(ctx, unsafe: read(args.data + 0).arg_value)
        unsafe:
            call_args.push(read(sub_val))
        return alloc_expr(ir.Expr.expr_call(callee = info.unsubscribe_c_name, arguments = call_args.as_span(), ty = bool_ty))
    fatal(c"lowering: unknown event method")


## Build a field list span helper with 1 field.
function sp_field1(f1: ir.Field) -> span[ir.Field]:
    var buf = vec.Vec[ir.Field].create()
    buf.push(f1)
    return buf.as_span()


## Build a field list span helper with 2 fields.
function sp_field2(f1: ir.Field, f2: ir.Field) -> span[ir.Field]:
    var buf = vec.Vec[ir.Field].create()
    buf.push(f1)
    buf.push(f2)
    return buf.as_span()


## Build a field list span helper with 4 fields.
function sp_field4(f1: ir.Field, f2: ir.Field, f3: ir.Field, f4: ir.Field) -> span[ir.Field]:
    var buf = vec.Vec[ir.Field].create()
    buf.push(f1)
    buf.push(f2)
    buf.push(f3)
    buf.push(f4)
    return buf.as_span()


## Lower a listener argument for event subscribe calls.  When the argument is a
## plain function name, use the raw C function name (avoid fn→proc coercion
## which creates a temporary proc struct); otherwise fall back to lower_expr.
function lower_listener_arg(ctx: ref[LowerCtx], arg: ptr[ast.Expr]) -> ptr[ir.Expr]:
    unsafe:
        match read(arg):
            ast.Expr.expr_identifier as id:
                if ctx.function_returns.contains(id.name) or ctx.analysis.functions.contains(id.name):
                    let fn_c_name = naming.qualified_c_name(ctx.module_name, id.name)
                    let void_ty = types.primitive("void")
                    let void_fn_ty = types.Type.ty_function(params = span[types.Type](), return_type = types.alloc_type(void_ty), variadic = false)
                    return alloc_expr(ir.Expr.expr_cast(
                        target_type = types.Type.ty_generic(name = "ptr", args = sp_type(types.primitive("void"))),
                        expression = alloc_expr(ir.Expr.expr_name(name = fn_c_name, ty = void_fn_ty, pointer = false)),
                        ty = types.Type.ty_generic(name = "ptr", args = sp_type(types.primitive("void"))),
                    ))
            _:
                pass
    return lower_expr(ctx, arg)


## Lower a str_buffer[N] method call to a C helper call or inline operation.
function lower_str_buffer_method(ctx: ref[LowerCtx], recv: ptr[ir.Expr], method_name: str, args: span[ast.Argument], call_ep: ptr[ast.Expr]) -> ptr[ir.Expr]:
    let char_ty = types.primitive("char")
    let ptr_uint_ty = types.primitive("ptr_uint")
    let void_ty = types.primitive("void")
    let str_ty = types.Type.ty_str
    let bool_ty = types.primitive("bool")
    let data_member = alloc_expr(ir.Expr.expr_member(receiver = recv, member = "data", ty = char_ty))
    let data_elem = alloc_expr(ir.Expr.expr_index(receiver = data_member, index = alloc_expr(ir.Expr.expr_integer_literal(value = 0z, ty = ptr_uint_ty)), ty = char_ty))
    let data_ptr = types.Type.ty_generic(name = "ptr", args = sp_type(char_ty))
    let data_addr = alloc_expr(ir.Expr.expr_address_of(expression = data_elem, ty = data_ptr))
    let len_ptr_ty = types.Type.ty_generic(name = "ptr", args = sp_type(ptr_uint_ty))
    let len_addr = alloc_expr(ir.Expr.expr_address_of(
        expression = alloc_expr(ir.Expr.expr_member(receiver = recv, member = "len", ty = ptr_uint_ty)),
        ty = len_ptr_ty,
    ))
    let dirty_ptr_ty = types.Type.ty_generic(name = "ptr", args = sp_type(bool_ty))
    let dirty_addr = alloc_expr(ir.Expr.expr_address_of(
        expression = alloc_expr(ir.Expr.expr_member(receiver = recv, member = "dirty", ty = bool_ty)),
        ty = dirty_ptr_ty,
    ))
    if method_name.equal("clear"):
        return alloc_expr(ir.Expr.expr_call(callee = "mt_str_buffer_clear", arguments = sp_expr2(len_addr, dirty_addr), ty = void_ty))
    if method_name.equal("len"):
        return alloc_expr(ir.Expr.expr_call(callee = "mt_str_buffer_len", arguments = sp_expr3(data_addr, len_addr, dirty_addr), ty = ptr_uint_ty))
    if method_name.equal("capacity"):
        return alloc_expr(ir.Expr.expr_integer_literal(value = 0z, ty = ptr_uint_ty))
    if method_name.equal("assign") or method_name.equal("append"):
        let helper = if method_name.equal("assign"): "mt_str_buffer_assign" else: "mt_str_buffer_append"
        var helper_args = vec.Vec[ir.Expr].create()
        let lowered = lower_expr(ctx, unsafe: read(args.data + 0).arg_value)
        let cap_val = alloc_expr(ir.Expr.expr_integer_literal(value = 64z, ty = ptr_uint_ty))
        unsafe:
            helper_args.push(read(lowered))
            helper_args.push(read(data_addr))
            helper_args.push(read(cap_val))
            helper_args.push(read(len_addr))
            helper_args.push(read(dirty_addr))
        return alloc_expr(ir.Expr.expr_call(callee = helper, arguments = helper_args.as_span(), ty = void_ty))
    if method_name.equal("as_str"):
        var as_str_args = vec.Vec[ir.Expr].create()
        unsafe:
            as_str_args.push(read(data_addr))
            as_str_args.push(read(len_addr))
            as_str_args.push(read(dirty_addr))
        return alloc_expr(ir.Expr.expr_call(callee = "mt_str_buffer_as_str", arguments = as_str_args.as_span(), ty = str_ty))
    if method_name.equal("assign_format") or method_name.equal("append_format"):
        let helper = if method_name.equal("assign_format"): "mt_str_buffer_assign" else: "mt_str_buffer_append"
        var helper_args = vec.Vec[ir.Expr].create()
        let lowered = lower_expr(ctx, unsafe: read(args.data + 0).arg_value)
        let cap_val = alloc_expr(ir.Expr.expr_integer_literal(value = 64z, ty = ptr_uint_ty))
        unsafe:
            helper_args.push(read(lowered))
            helper_args.push(read(data_addr))
            helper_args.push(read(cap_val))
            helper_args.push(read(len_addr))
            helper_args.push(read(dirty_addr))
        return alloc_expr(ir.Expr.expr_call(callee = helper, arguments = helper_args.as_span(), ty = void_ty))
    if method_name.equal("as_cstr"):
        return alloc_expr(ir.Expr.expr_null_literal(ty = types.primitive("cstr")))
    fatal(c"str_buffer lowering: unknown method")


function sp_expr2(e1: ptr[ir.Expr], e2: ptr[ir.Expr]) -> span[ir.Expr]:
    var buf = vec.Vec[ir.Expr].create()
    unsafe:
        buf.push(read(e1))
        buf.push(read(e2))
    return buf.as_span()


function lower_expression_match(ctx: ref[LowerCtx], scrutinee: ptr[ast.Expr], arms: span[ast.MatchExprArm], ep: ptr[ast.Expr]) -> ptr[ir.Expr]:
    let scrut_ty = expr_type(ctx, scrutinee)
    return alloc_expr(ir.Expr.expr_name(name = "match_expr", ty = scrut_ty, pointer = false))


function sp_expr3(e1: ptr[ir.Expr], e2: ptr[ir.Expr], e3: ptr[ir.Expr]) -> span[ir.Expr]:
    var buf = vec.Vec[ir.Expr].create()
    unsafe:
        buf.push(read(e1))
        buf.push(read(e2))
        buf.push(read(e3))
    return buf.as_span()


function is_dyn_type(t: types.Type) -> bool:
    match t:
        types.Type.ty_dyn:
            return true
        _:
            return false


function lower_plain_call(ctx: ref[LowerCtx], c_name: str, args: span[ast.Argument], call_ep: ptr[ast.Expr], override_ty: ptr[types.Type]?) -> ptr[ir.Expr]:
    var ir_args = vec.Vec[ir.Expr].create()
    var i: ptr_uint = 0
    while i < args.len:
        var arg: ast.Argument
        unsafe:
            arg = read(args.data + i)
        let lowered = lower_expr(ctx, arg.arg_value)
        unsafe:
            ir_args.push(read(lowered))
        i += 1
    var ret_ty: types.Type
    let ov = override_ty
    if ov != null:
        unsafe:
            ret_ty = read(ov)
    else:
        ret_ty = expr_type(ctx, call_ep)
    return alloc_expr(ir.Expr.expr_call(callee = c_name, arguments = ir_args.as_span(), ty = ret_ty))


## Lower a foreign function call to a direct call on its mapped C function,
## applying `as cstr` boundary projections to arguments.  Phase 2d supports
## string-literal arguments at an `as cstr` boundary (emitted as a C string
## literal); str-variable projection (runtime str->cstr) and in/out/inout/
## consuming modes arrive later.
function lower_foreign_call(ctx: ref[LowerCtx], info: ForeignInfo, args: span[ast.Argument], call_ep: ptr[ast.Expr]) -> ptr[ir.Expr]:
    var ir_args = vec.Vec[ir.Expr].create()
    var i: ptr_uint = 0
    while i < args.len:
        var arg: ast.Argument
        unsafe:
            arg = read(args.data + i)
        var lowered: ptr[ir.Expr]
        if i < info.params.len:
            var param: ast.ForeignParam
            unsafe:
                param = read(info.params.data + i)
            lowered = lower_foreign_arg(ctx, param, arg.arg_value)
        else:
            lowered = lower_expr(ctx, arg.arg_value)
        unsafe:
            ir_args.push(read(lowered))
        i += 1
    return alloc_expr(ir.Expr.expr_call(callee = info.c_name, arguments = ir_args.as_span(), ty = expr_type(ctx, call_ep)))


function lower_foreign_arg(ctx: ref[LowerCtx], param: ast.ForeignParam, arg: ptr[ast.Expr]) -> ptr[ir.Expr]:
    match param.boundary_type:
        Option.some as boundary:
            if boundary_is_cstr(boundary.value):
                unsafe:
                    match read(arg):
                        ast.Expr.expr_string_literal as lit:
                            return alloc_expr(ir.Expr.expr_string_literal(value = lit.value, ty = types.primitive("cstr"), cstring = true))
                        _:
                            fatal(c"lowering: only string-literal arguments are supported at an 'as cstr' boundary")
            return lower_expr(ctx, arg)
        Option.none:
            return lower_expr(ctx, arg)


function boundary_is_cstr(boundary: ast.TypeRef) -> bool:
    if boundary.name.parts.len != 1:
        return false
    unsafe:
        return read(boundary.name.parts.data + 0).equal("cstr")


# =============================================================================
#  Foreign / external function registry
# =============================================================================

## Pre-scan declarations to map each external function to its C name and each
## foreign function to its mapped C function and boundary parameters, so calls
## can be lowered to direct C calls.
function collect_foreign_functions(ctx: ref[LowerCtx], decls: span[ast.Decl]) -> void:
    var i: ptr_uint = 0
    while i < decls.len:
        var d: ast.Decl
        unsafe:
            d = read(decls.data + i)
        match d:
            ast.Decl.decl_extern_function as ef:
                ctx.extern_map.set(ef.name, extern_c_name(ef.name, ef.mapping))
            _:
                pass
        i += 1

    i = 0
    while i < decls.len:
        var d: ast.Decl
        unsafe:
            d = read(decls.data + i)
        match d:
            ast.Decl.decl_foreign_function as ff:
                ctx.foreign_map.set(ff.name, ForeignInfo(
                    c_name = resolve_foreign_c_name(ctx, ff.mapping),
                    return_ty = qualify_type(ctx, resolve_scalar_type_ref(ff.return_type)),
                    params = ff.foreign_params,
                ))
            _:
                pass
        i += 1


## Pre-scan function declarations to record each one's resolved return type in
## ctx.function_returns, so call lowering can use the correct type even when the
## analyzer left it unresolved (tuple returns, array returns, etc.).
function collect_function_returns(ctx: ref[LowerCtx], decls: span[ast.Decl]) -> void:
    var i: ptr_uint = 0
    while i < decls.len:
        var d: ast.Decl
        unsafe:
            d = read(decls.data + i)
        match d:
            ast.Decl.decl_function as fun:
                let ret = resolve_return_type(ctx, lookup_fn_sig(ctx, fun.name), fun.return_type)
                ctx.function_returns.set(fun.name, ret)
            _:
                pass
        i += 1


## A captured free variable from the enclosing scope, collected for proc
## capture-env struct generation.
struct ProcCapture:
    name: str
    c_name: str
    ty: types.Type


## True when a lowered type represents a proc struct (has invoke/release/retain
## fields), as opposed to a bare fn pointer or a regular struct.
function is_proc_type(t: types.Type) -> bool:
    match t:
        types.Type.ty_named as n:
            return n.name.find_substring("__proc_").is_some() or n.name.starts_with("mt_proc_")
        types.Type.ty_function:
            return true
        _:
            return false


## Generate a shared proc struct type name for a given function type:
## `mt_proc_R_P1_P2_...`.  Multiple proc expressions with the same signature
## share this type, so proc-typed params, returns, and expressions unify.
function proc_type_name_from_signature(proc_ty: types.Type) -> str:
    var buf = string.String.create()
    buf.append("mt_proc_")
    match proc_ty:
        types.Type.ty_function as fnt:
            unsafe:
                buf.append(naming.sanitize_identifier(types.type_to_string(read(fnt.return_type))))
            var i: ptr_uint = 0
            while i < fnt.params.len:
                buf.append("_")
                unsafe:
                    buf.append(naming.sanitize_identifier(types.type_to_string(read(fnt.params.data + i))))
                i += 1
        _:
            pass
    return buf.as_str()


## Ensure a proc struct declaration exists for the given signature and return a
## `ty_named` pointing to it.  Multiple callers with the same signature share
## the same struct type.
function proc_ensure_struct_decl(ctx: ref[LowerCtx], struct_name: str, proc_ty: types.Type) -> types.Type:
    # Skip when the proc type contains unresolved type variables (happens
    # inside generic function bodies where T is not yet substituted).
    if proc_type_has_type_var(proc_ty):
        return types.Type.ty_named(name = struct_name)
    let void_ptr = types.Type.ty_generic(name = "ptr", args = sp_type(types.primitive("void")))
    var struct_fields = vec.Vec[ir.Field].create()
    struct_fields.push(ir.Field(name = "env", ty = void_ptr))
    struct_fields.push(ir.Field(name = "invoke", ty = proc_invoke_field_type(proc_ty)))
    let lifecycle_ty = proc_lifecycle_fn_type()
    struct_fields.push(ir.Field(name = "release", ty = lifecycle_ty))
    struct_fields.push(ir.Field(name = "retain", ty = lifecycle_ty))
    ctx.pending_env_structs.push(ir.StructDecl(name = struct_name, linkage_name = struct_name, fields = struct_fields.as_span(), packed = false, alignment = 0, source_module = Option[str].none))
    return types.Type.ty_named(name = struct_name)


## True when a function type's params or return type contain an unresolved
## type variable or raw type parameter.
function proc_type_has_type_var(proc_ty: types.Type) -> bool:
    match proc_ty:
        types.Type.ty_function as fnt:
            var i: ptr_uint = 0
            while i < fnt.params.len:
                unsafe:
                    if type_contains_type_var(read(fnt.params.data + i)):
                        return true
                i += 1
            unsafe:
                if type_contains_type_var(read(fnt.return_type)):
                    return true
            return false
        _:
            return false


## True when a type contains an unresolved type variable or raw type param.
function type_contains_type_var(t: types.Type) -> bool:
    match t:
        types.Type.ty_var:
            return true
        types.Type.ty_named as n:
            if n.name.equal("T") or n.name.equal("U") or n.name.equal("K") or n.name.equal("V") or n.name.equal("E"):
                return true
            return false
        types.Type.ty_generic as g:
            var i: ptr_uint = 0
            while i < g.args.len:
                unsafe:
                    if type_contains_type_var(read(g.args.data + i)):
                        return true
                i += 1
            return false
        types.Type.ty_nullable as nl:
            return unsafe: type_contains_type_var(read(nl.base))
        _:
            return false


## Lower a proc call `p(arg1, arg2)` to `p.invoke(p.env, arg1, arg2)`.  Since the
## IR's `expr_call` uses a string callee for direct calls, we generate a direct
## call to the invoke function (which is `<struct_name>__invoke`) and pass the
## env member as the first argument.
function lower_proc_call(ctx: ref[LowerCtx], lb: LocalBinding, args: span[ast.Argument], call_ep: ptr[ast.Expr]) -> ptr[ir.Expr]:
    let recv = alloc_expr(ir.Expr.expr_name(name = lb.c_name, ty = lb.ty, pointer = false))
    let void_ptr = types.Type.ty_generic(name = "ptr", args = sp_type(types.primitive("void")))
    let env_member = alloc_expr(ir.Expr.expr_member(receiver = recv, member = "env", ty = void_ptr))

    # Build arguments: env, then user args.
    var invoke_args = vec.Vec[ir.Expr].create()
    unsafe:
        invoke_args.push(read(env_member))
    var i: ptr_uint = 0
    while i < args.len:
        var arg: ast.Argument
        unsafe:
            arg = read(args.data + i)
        let lowered = lower_expr(ctx, arg.arg_value)
        unsafe:
            invoke_args.push(read(lowered))
        i += 1

    # Call through p.invoke (function pointer field).  The C backend renders
    # this as p.invoke(arg0, arg1, ...), a direct call through the member.
    let invoke_field = alloc_expr(ir.Expr.expr_member(receiver = recv, member = "invoke", ty = expr_type(ctx, call_ep)))
    return alloc_expr(ir.Expr.expr_call_indirect(callee = invoke_field, arguments = invoke_args.as_span(), ty = expr_type(ctx, call_ep)))


## The resolved return type of a module function: recorded during pre-scan
## (handles tuple/array returns the analyzer can't resolve), else the
## analyzer's best guess.
function function_return_type(ctx: ref[LowerCtx], name: str) -> types.Type:
    let ret_ptr = ctx.function_returns.get(name)
    if ret_ptr != null:
        unsafe:
            return read(ret_ptr)
    return fn_sig_return_type(lookup_fn_sig(ctx, name))


## The C name an external function maps to: its explicit `= c.name` mapping value
## when present, else the declaration name itself.
function extern_c_name(name: str, mapping: ptr[ast.Expr]?) -> str:
    let m = mapping else:
        return name
    unsafe:
        match read(m):
            ast.Expr.expr_identifier as id:
                return id.name
            ast.Expr.expr_member_access as ma:
                return ma.member_name
            ast.Expr.expr_string_literal as s:
                return s.value
            _:
                return name


## The C name a foreign function maps to: resolve its `= target` identifier
## through the external registry (so `= atoi` yields the external's C name),
## falling back to the target name.
function resolve_foreign_c_name(ctx: ref[LowerCtx], mapping: ptr[ast.Expr]) -> str:
    unsafe:
        match read(mapping):
            ast.Expr.expr_identifier as id:
                let ext = ctx.extern_map.get(id.name)
                if ext != null:
                    return read(ext)
                return id.name
            ast.Expr.expr_member_access as ma:
                return ma.member_name
            _:
                fatal(c"lowering: unsupported foreign function mapping")


## Member access: enum / flags member constants on a type-name receiver
## (`State.running` -> `en_State_running`), otherwise a struct field access
## (`p.x`).  Method calls and other member forms arrive in later phases.
function lower_member_access(ctx: ref[LowerCtx], receiver: ptr[ast.Expr], member: str, ep: ptr[ast.Expr]) -> ptr[ir.Expr]:
    unsafe:
        match read(receiver):
            ast.Expr.expr_identifier as id:
                # A no-payload variant arm constructor, e.g. `Token.eof`.
                if ctx.variants.contains(id.name):
                    return alloc_expr(ir.Expr.expr_variant_literal(
                        ty = types.Type.ty_imported(module_name = ctx.module_name, name = id.name, args = span[types.Type]()),
                        arm_name = member,
                        fields = span[ir.AggregateField](),
                    ))
                if ctx.analysis.static_member_types.contains(id.name):
                    return alloc_expr(ir.Expr.expr_name(
                        name = naming.qualified_member_c_name(ctx.module_name, id.name, member),
                        ty = expr_type(ctx, ep),
                        pointer = false,
                    ))
                # Resolve `import_alias.member` through the imported module.
                let mod_ptr = ctx.analysis.imports.get(id.name)
                if mod_ptr != null:
                    let target_module = read(mod_ptr)
                    match find_imported_analysis(ctx, target_module):
                        Option.some as imported:
                            if imported.value.type_names.contains(member):
                                # Raw modules export C macros, not Milk Tea constants.
                                let c_name = if is_raw_module(imported.value.module_kind): member else: naming.qualified_c_name(target_module, member)
                                return alloc_expr(ir.Expr.expr_name(
                                    name = c_name,
                                    ty = expr_type(ctx, ep),
                                    pointer = false,
                                ))
                            if imported.value.value_types.contains(member):
                                let c_name = if is_raw_module(imported.value.module_kind): member else: naming.qualified_c_name(target_module, member)
                                return alloc_expr(ir.Expr.expr_name(
                                    name = c_name,
                                    ty = expr_type(ctx, ep),
                                    pointer = false,
                                ))
                        Option.none:
                            pass
            ast.Expr.expr_specialization as spec:
                # No-payload generic variant arm, e.g. `Option[int].none`.
                if spec.arguments.len > 0:
                    match read(spec.callee):
                        ast.Expr.expr_identifier as spec_id:
                            if ctx.variants.contains(spec_id.name):
                                var concrete_args = vec.Vec[types.Type].create()
                                var ai: ptr_uint = 0
                                while ai < spec.arguments.len:
                                    concrete_args.push(resolve_type_ref(ctx, read(spec.arguments.data + ai).value))
                                    ai += 1
                                let variant_ty = types.Type.ty_generic(name = spec_id.name, args = concrete_args.as_span())
                                return alloc_expr(ir.Expr.expr_variant_literal(
                                    ty = variant_ty,
                                    arm_name = member,
                                    fields = span[ir.AggregateField](),
                                ))
                        _:
                            pass
            ast.Expr.expr_member_access as inner_ma:
                match read(inner_ma.receiver):
                    ast.Expr.expr_identifier as inner_id:
                        let mod_ptr = ctx.analysis.imports.get(inner_id.name)
                        if mod_ptr != null:
                            let target_module = read(mod_ptr)
                            match find_imported_analysis(ctx, target_module):
                                Option.some as imported:
                                    if imported.value.static_member_types.contains(inner_ma.member_name):
                                        match find_imported_variant_arm(imported.value, member):
                                            Option.some as var_name:
                                                let var_ty = types.Type.ty_imported(module_name = target_module, name = var_name.value, args = span[types.Type]())
                                                return alloc_expr(ir.Expr.expr_variant_literal(
                                                    ty = var_ty,
                                                    arm_name = member,
                                                    fields = span[ir.AggregateField](),
                                                ))
                                            Option.none:
                                                return alloc_expr(ir.Expr.expr_name(
                                                    name = naming.qualified_member_c_name(target_module, inner_ma.member_name, member),
                                                    ty = expr_type(ctx, ep),
                                                    pointer = false,
                                                ))
                                Option.none:
                                    pass
                    _:
                        pass
            _:
                pass
    let recv = lower_expr(ctx, receiver)
    var member_ty = expr_type(ctx, ep)
    # Prefer the receiver's concrete (monomorphized) struct field type: the
    # analyzer records member types generically (e.g. Node[K,V] -> Node with the
    # args dropped), so inside a monomorphized method the recorded type loses its
    # arguments.  The concrete struct declaration carries the resolved field type.
    match concrete_field_type(ctx, ir_expr_type(recv), member):
        Option.some as ft:
            member_ty = ft.value
        Option.none:
            if types.is_error(member_ty):
                var recv_ty = ir_expr_type(recv)
                if is_tuple_type(recv_ty):
                    let index = parse_tuple_member_index(member)
                    member_ty = tuple_element_type(recv_ty, index)
    return alloc_expr(ir.Expr.expr_member(
        receiver = recv,
        member = member,
        ty = qualify_type(ctx, member_ty),
    ))


## The resolved type of `member` on a receiver whose type is a concrete
## monomorphized generic struct.  Looks the field up in the receiver struct's
## emitted declaration (keyed by concrete C name), auto-dereferencing a pointer
## or ref receiver.  Returns none for non-generic structs (handled by the
## analyzer's recorded member type) or unknown fields.
function concrete_field_type(ctx: ref[LowerCtx], recv_ty: types.Type, member: str) -> Option[types.Type]:
    var base = recv_ty
    if types.is_raw_pointer(base) or types.is_ref_type(base):
        base = types.pointer_element(base)
    var struct_name: str
    match base:
        types.Type.ty_named as n:
            struct_name = n.name
        _:
            return Option[types.Type].none
    let decl_ptr = ctx.generic_struct_decls.get(struct_name) else:
        return Option[types.Type].none
    unsafe:
        let decl = read(decl_ptr)
        var i: ptr_uint = 0
        while i < decl.fields.len:
            let f = read(decl.fields.data + i)
            if f.name.equal(member):
                return Option[types.Type].some(value = f.ty)
            i += 1
    return Option[types.Type].none


## Extract the integer index from a tuple field name `_0`, `_1`, ...
function parse_tuple_member_index(member: str) -> ptr_uint:
    if member.len < 2:
        return 0
    if member.byte_at(0) != '_':
        return 0
    var result: ptr_uint = 0
    var i: ptr_uint = 1
    while i < member.len:
        let b = member.byte_at(i)
        if b < '0' or b > '9':
            break
        result = result * 10 + ptr_uint<-(b - '0')
        i += 1
    return result


function is_tuple_type(t: types.Type) -> bool:
    match t:
        types.Type.ty_tuple:
            return true
        _:
            return false


## Lower a struct declaration to an IR StructDecl, resolving its fields from the
## analyzer's struct table (which carries resolved field types) and qualifying
## named field types with the current module for backend C-naming.
function lower_struct_decl(ctx: ref[LowerCtx], name: str) -> Option[ir.StructDecl]:
    let fields_ptr = ctx.analysis.structs.get(name) else:
        return Option[ir.StructDecl].none
    let entries = unsafe: read(fields_ptr)
    var ir_fields = vec.Vec[ir.Field].create()
    var i: ptr_uint = 0
    while i < entries.len:
        var entry: analyzer.FieldEntry
        unsafe:
            entry = read(entries.data + i)
        ir_fields.push(ir.Field(name = entry.name, ty = qualify_type(ctx, entry.ty)))
        i += 1
    return Option[ir.StructDecl].some(value = ir.StructDecl(
        name = name,
        linkage_name = naming.qualified_c_name(ctx.module_name, name),
        fields = ir_fields.as_span(),
        packed = false,
        alignment = 0,
        source_module = Option[str].none,
    ))


## Lower a union declaration to an IR UnionDecl, resolving field types from the
## declaration (unions are not tracked in the analyzer's struct table).
function lower_union_decl(ctx: ref[LowerCtx], name: str, fields: span[ast.Field]) -> ir.UnionDecl:
    var ir_fields = vec.Vec[ir.Field].create()
    var i: ptr_uint = 0
    while i < fields.len:
        var f: ast.Field
        unsafe:
            f = read(fields.data + i)
        ir_fields.push(ir.Field(name = f.name, ty = resolve_field_type_ref(ctx, f.field_type)))
        i += 1
    return ir.UnionDecl(
        name = name,
        linkage_name = naming.qualified_c_name(ctx.module_name, name),
        fields = ir_fields.as_span(),
        source_module = Option[str].none,
    )


# =============================================================================
#  Variant declarations (mirrors lowering/declarations.rb lower_variants)
# =============================================================================

## Register the prelude types (Option[T], Result[T,E]) in the variant registry so
## arm constructors `Option.some(value = ...)` and match on Option/Result
## scrutinees can resolve arm names and payload fields.  User-declared variants
## of the same name take priority (matching the analyzer's policy).
function install_prelude_variants(ctx: ref[LowerCtx]) -> void:
    if not ctx.variants.contains("Option"):
        ctx.variants.set("Option", prelude_option_info())
    if not ctx.variants.contains("Result"):
        ctx.variants.set("Result", prelude_result_info())


function prelude_option_info() -> VariantInfo:
    var arms = vec.Vec[VariantArmInfo].create()
    arms.push(VariantArmInfo(
        name = "some",
        field_names = sp_str("value"),
        field_types = sp_str_type("_phantom"),
    ))
    arms.push(VariantArmInfo(name = "none", field_names = span[str](), field_types = span[types.Type]()))
    return VariantInfo(module_name = "", arms = arms.as_span())


function prelude_result_info() -> VariantInfo:
    var arms = vec.Vec[VariantArmInfo].create()
    arms.push(VariantArmInfo(
        name = "success",
        field_names = sp_str("value"),
        field_types = sp_str_type("_phantom"),
    ))
    arms.push(VariantArmInfo(
        name = "failure",
        field_names = sp_str("error"),
        field_types = sp_str_type("_phantom"),
    ))
    return VariantInfo(module_name = "", arms = arms.as_span())


## A single-element `span[str]` — used for prelude arm payload field names.
function sp_str(value: str) -> span[str]:
    var buf = vec.Vec[str].create()
    buf.push(value)
    return buf.as_span()


## A single-element `span[types.Type]` carrying a primitive `ty_named` — used as a
## prelude-arm field-type placeholder until the specialization pass resolves the
## concrete type from the generic call site.
function sp_str_type(name: str) -> span[types.Type]:
    var buf = vec.Vec[types.Type].create()
    buf.push(types.Type.ty_named(name = name))
    return buf.as_span()


## Pre-scan variant declarations into the registry so arm constructors and match
## arms can resolve discriminant indices and payload fields.  Generic variants
## (Option/Result and user generics) are deferred to Phase 4c.
function collect_variants(ctx: ref[LowerCtx], decls: span[ast.Decl]) -> void:
    var i: ptr_uint = 0
    while i < decls.len:
        var d: ast.Decl
        unsafe:
            d = read(decls.data + i)
        match d:
            ast.Decl.decl_variant as vr:
                if vr.type_params.len == 0:
                    ctx.variants.set(vr.name, build_variant_info(ctx, vr.variant_arms))
            _:
                pass
        i += 1
    # Register imported variants so cross-module match can find them.
    install_imported_variants(ctx)


function build_variant_info(ctx: ref[LowerCtx], arms: span[ast.VariantArm]) -> VariantInfo:
    var arm_infos = vec.Vec[VariantArmInfo].create()
    var i: ptr_uint = 0
    while i < arms.len:
        var arm: ast.VariantArm
        unsafe:
            arm = read(arms.data + i)
        var names = vec.Vec[str].create()
        var tys = vec.Vec[types.Type].create()
        var fi: ptr_uint = 0
        while fi < arm.arm_fields.len:
            var f: ast.Field
            unsafe:
                f = read(arm.arm_fields.data + fi)
            names.push(f.name)
            tys.push(resolve_field_type_ref(ctx, f.field_type))
            fi += 1
        arm_infos.push(VariantArmInfo(name = arm.name, field_names = names.as_span(), field_types = tys.as_span()))
        i += 1
    return VariantInfo(module_name = ctx.module_name, arms = arm_infos.as_span())


## Register non-generic variants from imported modules in the current module's
## variant registry so cross-module variant match goes through the switch path
## (which handles `kind` field access and `as name` bindings) instead of
## falling through to the enum fallback (which uses the wrong module prefix).
function install_imported_variants(ctx: ref[LowerCtx]) -> void:
    var import_values = ctx.analysis.imports.values()
    while true:
        let target_ptr = import_values.next() else:
            break
        let target_module = unsafe: read(target_ptr)
        match find_imported_analysis(ctx, target_module):
            Option.some as imported:
                var di: ptr_uint = 0
                while di < imported.value.source_file.declarations.len:
                    var d: ast.Decl
                    unsafe:
                        d = read(imported.value.source_file.declarations.data + di)
                    match d:
                        ast.Decl.decl_variant as vr:
                            if vr.type_params.len == 0 and not ctx.variants.contains(vr.name):
                                ctx.variants.set(vr.name, build_imported_variant_info(vr.variant_arms))
                        _:
                            pass
                    di += 1
            Option.none:
                pass


## Like `build_variant_info` but uses the imported module's name for
## `module_name` so variant arm constructors produce correctly-qualified names.
function build_imported_variant_info(arms: span[ast.VariantArm]) -> VariantInfo:
    var arm_infos = vec.Vec[VariantArmInfo].create()
    var i: ptr_uint = 0
    while i < arms.len:
        var arm: ast.VariantArm
        unsafe:
            arm = read(arms.data + i)
        var names = vec.Vec[str].create()
        var tys = vec.Vec[types.Type].create()
        var fi: ptr_uint = 0
        while fi < arm.arm_fields.len:
            var f: ast.Field
            unsafe:
                f = read(arm.arm_fields.data + fi)
            names.push(f.name)
            # Use ty_named as placeholder; the actual type is looked up in the
            # imported analysis during lowering.
            tys.push(types.Type.ty_named(name = "void"))
            fi += 1
        arm_infos.push(VariantArmInfo(name = arm.name, field_names = names.as_span(), field_types = tys.as_span()))
        i += 1
    return VariantInfo(module_name = "", arms = arm_infos.as_span())


## Lower a variant declaration to an `ir.VariantDecl`, mirroring Ruby's
## `lower_variants`: the outer C name is `<module>_<name>` and each arm's payload
## struct C name is `<outer_c>_<arm>`.
function lower_variant_decl(ctx: ref[LowerCtx], name: str, arms: span[ast.VariantArm]) -> ir.VariantDecl:
    let outer_c = naming.qualified_c_name(ctx.module_name, name)
    var ir_arms = vec.Vec[ir.VariantArm].create()
    var i: ptr_uint = 0
    while i < arms.len:
        var arm: ast.VariantArm
        unsafe:
            arm = read(arms.data + i)
        var fields = vec.Vec[ir.Field].create()
        var fi: ptr_uint = 0
        while fi < arm.arm_fields.len:
            var f: ast.Field
            unsafe:
                f = read(arm.arm_fields.data + fi)
            fields.push(ir.Field(name = f.name, ty = resolve_field_type_ref(ctx, f.field_type)))
            fi += 1
        ir_arms.push(ir.VariantArm(name = arm.name, linkage_name = variant_arm_c_name(outer_c, arm.name), fields = fields.as_span()))
        i += 1
    return ir.VariantDecl(name = name, linkage_name = outer_c, arms = ir_arms.as_span(), source_module = Option[str].none)


## The C name of a variant arm's payload struct: `<outer_c>_<arm>`.
function variant_arm_c_name(outer_c: str, arm_name: str) -> str:
    var buf = string.String.create()
    buf.append(outer_c)
    buf.append("_")
    buf.append(arm_name)
    return buf.as_str()


## The C base name for a variant type: `ty_generic("Option", [ty_int])` →
## `"Option_int"`; `ty_imported` uses `qualified_c_name`; non-generic variants
## fall back to `qualified_c_name(module_name, variant_name)`.
function variant_base_c_name(ty: types.Type, module_name: str) -> str:
    var result: str
    match ty:
        types.Type.ty_generic as g:
            var buf = string.String.create()
            buf.append(g.name)
            var i: ptr_uint = 0
            while i < g.args.len:
                buf.append("_")
                unsafe:
                    buf.append(naming.sanitize_identifier(types.type_to_string(read(g.args.data + i))))
                i += 1
            result = buf.as_str()
        types.Type.ty_imported as im:
            if is_prelude_variant_name(im.name):
                result = im.name
            else:
                result = naming.qualified_c_name(im.module_name, im.name)
        types.Type.ty_named as n:
            if is_prelude_variant_name(n.name):
                result = n.name
            else:
                result = naming.qualified_c_name(module_name, n.name)
        _:
            result = naming.qualified_c_name(module_name, "")
    return result


## Look up a variant arm's field info by arm name.
function variant_arm_info(info: VariantInfo, arm_name: str) -> Option[VariantArmInfo]:
    var i: ptr_uint = 0
    while i < info.arms.len:
        var arm: VariantArmInfo
        unsafe:
            arm = read(info.arms.data + i)
        if arm.name.equal(arm_name):
            return Option[VariantArmInfo].some(value = arm)
        i += 1
    return Option[VariantArmInfo].none


## Resolve a field/local type annotation to a `types.Type`: scalars via
## `resolve_scalar_type_ref`, and single-name local types (structs/unions/enums)
## to a module-qualified `ty_imported`.  Compound types (arrays/spans/generics)
## resolve later.
function resolve_field_type_ref(ctx: ref[LowerCtx], tref: ast.TypeRef) -> types.Type:
    var local_tref = tref
    let scalar = resolve_scalar_type_ref(ptr_of(local_tref))
    if not types.is_error(scalar):
        return scalar
    if tref.is_fn or tref.is_proc:
        let fun = resolve_function_type_ref(ctx, ptr_of(local_tref))
        if tref.is_proc:
            let proc_name = proc_type_name_from_signature(fun)
            return proc_ensure_struct_decl(ctx, proc_name, fun)
        if tref.nullable:
            return types.Type.ty_nullable(base = types.alloc_type(fun))
        return fun
    if tref.is_dyn:
        return types.Type.ty_dyn(iface = unsafe: analyzer.qname_to_str(tref.dyn_interface))
    if tref.is_tuple:
        return types.Type.ty_error
    var resolved = types.Type.ty_error
    if tref.arguments.len > 0:
        resolved = resolve_generic_type_ref(ctx, tref)
    else if tref.name.parts.len == 2:
        var alias: str
        var type_name: str
        unsafe:
            alias = read(tref.name.parts.data + 0)
            type_name = read(tref.name.parts.data + 1)
        let mod_ptr = ctx.analysis.imports.get(alias)
        if mod_ptr != null:
            let target_module = unsafe: read(mod_ptr)
            resolved = types.Type.ty_imported(module_name = target_module, name = type_name, args = span[types.Type]())
    else if tref.name.parts.len == 1:
        let name = unsafe: read(tref.name.parts.data + 0)
        if ctx.analysis.type_names.contains(name):
            resolved = types.Type.ty_imported(module_name = ctx.module_name, name = name, args = span[types.Type]())
        else:
            let concrete_ptr = ctx.type_substitution.get(name)
            if concrete_ptr != null:
                resolved = unsafe: read(concrete_ptr)
            else:
                resolved = types.Type.ty_named(name = name)
    if tref.nullable and not types.is_error(resolved):
        return types.Type.ty_nullable(base = types.alloc_type(resolved))
    return resolved


# =============================================================================
#  Enum / flags declarations
# =============================================================================

function lower_enum_decl(ctx: ref[LowerCtx], name: str, backing_type: ptr[ast.TypeRef]?, members: span[ast.EnumMember], is_flags: bool) -> ir.EnumDecl:
    var backing = types.primitive("int")
    let annotation = backing_type
    if annotation != null:
        let resolved = resolve_scalar_type_ref(annotation)
        if not types.is_error(resolved):
            backing = resolved

    let enum_linkage = naming.qualified_c_name(ctx.module_name, name)
    var ir_members = vec.Vec[ir.EnumMember].create()
    var next_auto: long = 0

    var i: ptr_uint = 0
    while i < members.len:
        var m: ast.EnumMember
        unsafe:
            m = read(members.data + i)
        let member_linkage = naming.qualified_member_c_name(ctx.module_name, name, m.name)
        var value_expr: ptr[ir.Expr]
        let explicit = m.value
        if explicit != null:
            value_expr = lower_expr(ctx, explicit)
            next_auto = const_eval_int(explicit) + 1
        else:
            value_expr = alloc_expr(ir.Expr.expr_integer_literal(value = next_auto, ty = backing))
            next_auto += 1
        ir_members.push(ir.EnumMember(name = m.name, linkage_name = member_linkage, value = value_expr))
        i += 1

    return ir.EnumDecl(
        name = name,
        linkage_name = enum_linkage,
        backing_type = backing,
        members = ir_members.as_span(),
        is_flags = is_flags,
    )


## Compile-time integer evaluation for enum/flags member values (literals plus
## the arithmetic/bitwise/shift operators used in flag definitions).  Used only
## to advance the auto-increment counter after an explicit member value.
function const_eval_int(ep: ptr[ast.Expr]) -> long:
    unsafe:
        match read(ep):
            ast.Expr.expr_integer_literal as lit:
                return long<-lit.value
            ast.Expr.expr_char_literal as ch:
                return long<-ch.value
            ast.Expr.expr_unary_op as un:
                let v = const_eval_int(un.operand)
                if un.operator == "-":
                    return -v
                if un.operator == "~":
                    return ~v
                return v
            ast.Expr.expr_binary_op as bin:
                let l = const_eval_int(bin.left)
                let r = const_eval_int(bin.right)
                if bin.operator == "+":
                    return l + r
                if bin.operator == "-":
                    return l - r
                if bin.operator == "*":
                    return l * r
                if bin.operator == "/":
                    return l / r
                if bin.operator == "%":
                    return l % r
                if bin.operator == "<<":
                    return l << r
                if bin.operator == ">>":
                    return l >> r
                if bin.operator == "|":
                    return l | r
                if bin.operator == "&":
                    return l & r
                if bin.operator == "^":
                    return l ^ r
                return 0
            _:
                return 0


# =============================================================================
#  Match (enum scrutinee) -> switch
# =============================================================================

## Lower a `match` over an enum/flags scrutinee into an IR `stmt_switch`.  Each
## `EnumType.member` arm becomes a `case`; a `_` arm becomes the `default`.  With
## no `_` arm the switch is exhaustive (the backend adds `__builtin_unreachable`).
## Integer/str/variant/tuple scrutinees arrive in later phases.
function enum_source_module(ctx: ref[LowerCtx], ty: types.Type, default_module: str) -> str:
    match ty:
        types.Type.ty_imported as im:
            return im.module_name
        _:
            return default_module

function lower_match(ctx: ref[LowerCtx], output: ref[vec.Vec[ir.Stmt]], scrutinee: ptr[ast.Expr], arms: span[ast.MatchArm]) -> void:
    let scrutinee_ty = expr_type(ctx, scrutinee)
    let type_name = named_type_name(scrutinee_ty)

    if type_name.is_some() and ctx.variants.contains(type_name.unwrap()):
        lower_variant_match(ctx, output, scrutinee, type_name.unwrap(), scrutinee_ty, arms)
        return

    let gen_var = generic_variant_name(scrutinee_ty)
    if gen_var.is_some() and variant_match_allowed(ctx, gen_var.unwrap()):
        lower_variant_match(ctx, output, scrutinee, gen_var.unwrap(), scrutinee_ty, arms)
        return

    let enum_name = type_name else:
        let ts = types.type_to_string(scrutinee_ty)
        if ts.equal("void") or ts.equal("<error>"):
            return
        fatal(j2("lowering: match requires known type, got ", ts))

    let scrutinee_expr = lower_expr(ctx, scrutinee)
    var enum_module = enum_source_module(ctx, scrutinee_ty, ctx.module_name)
    var cases = vec.Vec[ir.SwitchCase].create()
    var has_wildcard = false
    var i: ptr_uint = 0
    while i < arms.len:
        var arm: ast.MatchArm
        unsafe:
            arm = read(arms.data + i)
        let body = lower_block(ctx, arm.body)
        let pattern = arm.pattern
        if pattern == null:
            has_wildcard = true
            cases.push(ir.SwitchCase(is_default = true, value = null, body = body))
        else:
            let member = match_member_name(pattern) else:
                fatal(c"lowering: unsupported match pattern")
            let value = alloc_expr(ir.Expr.expr_name(
                name = naming.qualified_member_c_name(enum_module, enum_name, member),
                ty = scrutinee_ty,
                pointer = false,
            ))
            cases.push(ir.SwitchCase(is_default = false, value = value, body = body))
        i += 1

    output.push(ir.Stmt.stmt_switch(expression = scrutinee_expr, cases = cases.as_span(), exhaustive = not has_wildcard))


## Lower a match expression used as a local variable initializer (`let x = match
## e: p1: v1; p2: v2; _: v3`).  Hoists the match into a switch that assigns to
## the local, keeping the result in a `stmt_local` with zero-init followed by the
## switch.  Supports enum and variant scrutinees (the same subset handled by
## `lower_match`).  Integer and string scrutinees are deferred.
function lower_match_expression_local(ctx: ref[LowerCtx], output: ref[vec.Vec[ir.Stmt]], name: str, declared_type: ptr[ast.TypeRef]?, scrutinee: ptr[ast.Expr], arms: span[ast.MatchExprArm]) -> void:
    let c_name = c_local_name(name)
    var ty: types.Type
    let dt = declared_type
    if dt != null:
        ty = resolve_type_ref(ctx, dt)
    if types.is_error(ty):
        ty = types.primitive("int")

    # Zero-init the local, then build a switch/if chain that overwrites it.
    let zero_init = alloc_expr(ir.Expr.expr_zero_init(ty = ty))
    output.push(ir.Stmt.stmt_local(name = name, linkage_name = c_name, ty = ty, value = zero_init, line = 0, source_path = ""))

    let scrutinee_ty = expr_type(ctx, scrutinee)
    var scrutinee_expr = lower_expr(ctx, scrutinee)
    if not ir_expr_is_name(scrutinee_expr):
        let temp = fresh_c_temp_name(ctx, "match_scrut")
        output.push(ir.Stmt.stmt_local(name = temp, linkage_name = temp, ty = scrutinee_ty, value = scrutinee_expr, line = 0, source_path = ""))
        scrutinee_expr = alloc_expr(ir.Expr.expr_name(name = temp, ty = scrutinee_ty, pointer = false))

    let result_ref = alloc_expr(ir.Expr.expr_name(name = c_name, ty = ty, pointer = false))

    let type_name = named_type_name(scrutinee_ty)
    if type_name.is_some() and ctx.variants.contains(type_name.unwrap()):
        lower_variant_match_expr(ctx, output, scrutinee_expr, type_name.unwrap(), scrutinee_ty, arms, result_ref)
    else:
        lower_enum_match_expr(ctx, output, scrutinee_expr, type_name, arms, result_ref)

    ctx.locals.push(LocalBinding(name = name, c_name = c_name, ty = ty, pointer = false))


## Lower a match expression over an enum scrutinee: emit a switch whose cases
## assign the result and break, plus a default case for the wildcard arm.
function lower_enum_match_expr(ctx: ref[LowerCtx], output: ref[vec.Vec[ir.Stmt]], scrutinee_expr: ptr[ir.Expr], type_name: Option[str], arms: span[ast.MatchExprArm], result_ref: ptr[ir.Expr]) -> void:
    var cases = vec.Vec[ir.SwitchCase].create()
    var has_wildcard = false
    var i: ptr_uint = 0
    while i < arms.len:
        var arm: ast.MatchExprArm
        unsafe:
            arm = read(arms.data + i)
        let lowered_val = lower_expr(ctx, arm.value)
        var body = vec.Vec[ir.Stmt].create()
        body.push(ir.Stmt.stmt_assignment(target = result_ref, operator = "=", value = lowered_val))
        let pattern = arm.pattern
        if pattern == null:
            has_wildcard = true
            cases.push(ir.SwitchCase(is_default = true, value = null, body = body.as_span()))
        else:
            let member = match_member_name(pattern) else:
                # Non-enum pattern (integer literal, char literal, etc.)
                let lowered_pat = lower_expr(ctx, pattern)
                cases.push(ir.SwitchCase(is_default = false, value = lowered_pat, body = body.as_span()))
                continue
            match type_name:
                Option.some as tn:
                    let value = alloc_expr(ir.Expr.expr_name(
                        name = naming.qualified_member_c_name(ctx.module_name, tn.value, member),
                        ty = ir_expr_type(scrutinee_expr),
                        pointer = false,
                    ))
                    cases.push(ir.SwitchCase(is_default = false, value = value, body = body.as_span()))
                Option.none:
                    fatal(c"lowering: match expression on non-enum scrutinee")
        i += 1

    output.push(ir.Stmt.stmt_switch(expression = scrutinee_expr, cases = cases.as_span(), exhaustive = not has_wildcard))


## Lower a match expression over a variant scrutinee: emit a switch on the variant
## kind, with each arm assigning its value to the result reference.
function lower_variant_match_expr(ctx: ref[LowerCtx], output: ref[vec.Vec[ir.Stmt]], scrutinee_expr: ptr[ir.Expr], variant_name: str, scrutinee_ty: types.Type, arms: span[ast.MatchExprArm], result_ref: ptr[ir.Expr]) -> void:
    let info_ptr = ctx.variants.get(variant_name) else:
        fatal(c"lowering: variant match expr on unknown variant")
    let info = unsafe: read(info_ptr)
    let outer_c = variant_base_c_name(scrutinee_ty, ctx.module_name)
    let int_ty = types.primitive("int")
    let kind_expr = alloc_expr(ir.Expr.expr_member(receiver = scrutinee_expr, member = "kind", ty = int_ty))

    var cases = vec.Vec[ir.SwitchCase].create()
    var has_wildcard = false
    var i: ptr_uint = 0
    while i < arms.len:
        var arm: ast.MatchExprArm
        unsafe:
            arm = read(arms.data + i)
        var body = vec.Vec[ir.Stmt].create()
        let pattern = arm.pattern
        if pattern == null:
            has_wildcard = true
        else:
            match arm.binding_name:
                Option.some as bn:
                    let arm_name = variant_match_arm_name_from_pattern(pattern) else:
                        fatal(c"lowering: unsupported variant match expression pattern")
                    let binding_ty = types.Type.ty_named(name = variant_arm_type_name(outer_c, arm_name))
                    let data_member = alloc_expr(ir.Expr.expr_member(receiver = scrutinee_expr, member = "data", ty = binding_ty))
                    let arm_data = alloc_expr(ir.Expr.expr_member(receiver = data_member, member = arm_name, ty = binding_ty))
                    let bc = c_local_name(bn.value)
                    body.push(ir.Stmt.stmt_local(name = bn.value, linkage_name = bc, ty = binding_ty, value = arm_data, line = 0, source_path = ""))
                    ctx.locals.push(LocalBinding(name = bn.value, c_name = bc, ty = binding_ty, pointer = false))
                Option.none:
                    pass
        let lowered_val = lower_expr(ctx, arm.value)
        body.push(ir.Stmt.stmt_assignment(target = result_ref, operator = "=", value = lowered_val))

        if pattern == null:
            cases.push(ir.SwitchCase(is_default = true, value = null, body = body.as_span()))
        else:
            let arm_name = variant_match_arm_name_from_pattern(pattern) else:
                fatal(c"lowering: unsupported variant match expression pattern")
            let kind_const = alloc_expr(ir.Expr.expr_name(
                name = variant_kind_const_name(outer_c, arm_name),
                ty = int_ty,
                pointer = false,
            ))
            cases.push(ir.SwitchCase(is_default = false, value = kind_const, body = body.as_span()))
        i += 1

    output.push(ir.Stmt.stmt_switch(expression = kind_expr, cases = cases.as_span(), exhaustive = not has_wildcard))


## Lower a `match` over a variant scrutinee into a `switch (scrut.kind)`.  Each
## payload arm may bind the whole payload struct via `as name`
## (`<arm_c> name = scrut.data.<arm>;`); no-payload arms carry no binding.  A
## non-name scrutinee is hoisted into a temp so it is evaluated once.
## Dispatch a variant match to the switch strategy (member / `as name` /
## no-payload / wildcard arms) or the if/goto strategy (any struct-pattern arm,
## i.e. `Variant.arm(field, ...)`), mirroring Ruby's block.rb decision.
function lower_variant_match(ctx: ref[LowerCtx], output: ref[vec.Vec[ir.Stmt]], scrutinee: ptr[ast.Expr], variant_name: str, scrutinee_ty: types.Type, arms: span[ast.MatchArm]) -> void:
    if arms_have_call_pattern(arms):
        lower_variant_match_goto(ctx, output, scrutinee, variant_name, scrutinee_ty, arms)
    else:
        lower_variant_match_switch(ctx, output, scrutinee, variant_name, scrutinee_ty, arms)


## True when any arm's pattern is a call (a struct-destructure pattern such as
## `Shape.circle(r)`), which forces the if/goto lowering strategy.
function arms_have_call_pattern(arms: span[ast.MatchArm]) -> bool:
    var i: ptr_uint = 0
    while i < arms.len:
        var arm: ast.MatchArm
        unsafe:
            arm = read(arms.data + i)
        let pattern = arm.pattern
        if pattern != null:
            unsafe:
                match read(pattern):
                    ast.Expr.expr_call:
                        return true
                    _:
                        pass
        i += 1
    return false


function lower_variant_match_switch(ctx: ref[LowerCtx], output: ref[vec.Vec[ir.Stmt]], scrutinee: ptr[ast.Expr], variant_name: str, scrutinee_ty: types.Type, arms: span[ast.MatchArm]) -> void:
    # If variant_name includes type args (e.g. "Option_span_Field"), strip to
    # the base name (e.g. "Option") to find the variant info.
    var base_name = variant_name
    var info_ptr = ctx.variants.get(variant_name)
    if info_ptr == null:
        let bn = variant_base_name(variant_name)
        if bn.is_some():
            base_name = bn.unwrap()
            info_ptr = ctx.variants.get(base_name)
    let info_ptr2 = info_ptr else:
        fatal(c"lowering: variant match on unknown variant")
    let info = unsafe: read(info_ptr2)
    let outer_c = variant_base_c_name(scrutinee_ty, ctx.module_name)
    let int_ty = types.primitive("int")

    var scrut_base = lower_expr(ctx, scrutinee)
    if not ir_expr_is_name(scrut_base):
        let temp = fresh_c_temp_name(ctx, "match_scrutinee")
        let scrut_ty = ir_expr_type(scrut_base)
        output.push(ir.Stmt.stmt_local(name = temp, linkage_name = temp, ty = scrut_ty, value = scrut_base, line = 0, source_path = ""))
        scrut_base = alloc_expr(ir.Expr.expr_name(name = temp, ty = scrut_ty, pointer = false))

    let kind_expr = alloc_expr(ir.Expr.expr_member(receiver = scrut_base, member = "kind", ty = int_ty))
    var cases = vec.Vec[ir.SwitchCase].create()
    var has_wildcard = false
    var i: ptr_uint = 0
    while i < arms.len:
        var arm: ast.MatchArm
        unsafe:
            arm = read(arms.data + i)
        let pattern = arm.pattern
        if pattern == null:
            has_wildcard = true
            cases.push(ir.SwitchCase(is_default = true, value = null, body = lower_block(ctx, arm.body)))
        else:
            let arm_name = match_member_name(pattern) else:
                fatal(c"lowering: unsupported variant match pattern")
            var stmts = vec.Vec[ir.Stmt].create()
            match arm.binding_name:
                Option.some as bn:
                    let binding_ty = types.Type.ty_named(name = variant_arm_type_name(outer_c, arm_name))
                    let data_member = alloc_expr(ir.Expr.expr_member(receiver = scrut_base, member = "data", ty = binding_ty))
                    let arm_data = alloc_expr(ir.Expr.expr_member(receiver = data_member, member = arm_name, ty = binding_ty))
                    let bc = c_local_name(bn.value)
                    stmts.push(ir.Stmt.stmt_local(name = bn.value, linkage_name = bc, ty = binding_ty, value = arm_data, line = 0, source_path = ""))
                    ctx.locals.push(LocalBinding(name = bn.value, c_name = bc, ty = binding_ty, pointer = false))
                Option.none:
                    pass
            let body = lower_block(ctx, arm.body)
            var bi: ptr_uint = 0
            while bi < body.len:
                unsafe:
                    stmts.push(read(body.data + bi))
                bi += 1
            let kind_const = alloc_expr(ir.Expr.expr_name(
                name = variant_kind_const_name(outer_c, arm_name),
                ty = int_ty,
                pointer = false,
            ))
            cases.push(ir.SwitchCase(is_default = false, value = kind_const, body = stmts.as_span()))
        i += 1

    output.push(ir.Stmt.stmt_switch(expression = kind_expr, cases = cases.as_span(), exhaustive = not has_wildcard))


## Lower a variant match with struct-pattern arms into an if/goto chain: each arm
## tests `scrut.kind`, jumps to the next arm's label on mismatch, otherwise binds
## the payload into a temp, destructures its fields, and falls through to the arm
## body then `goto <end>`.  Mirrors Ruby's block.rb struct-pattern match path.
function lower_variant_match_goto(ctx: ref[LowerCtx], output: ref[vec.Vec[ir.Stmt]], scrutinee: ptr[ast.Expr], variant_name: str, scrutinee_ty: types.Type, arms: span[ast.MatchArm]) -> void:
    let info_ptr = ctx.variants.get(variant_name) else:
        fatal(c"lowering: variant match on unknown variant")
    let info = unsafe: read(info_ptr)
    let outer_c = variant_base_c_name(scrutinee_ty, ctx.module_name)
    let int_ty = types.primitive("int")
    let bool_ty = types.primitive("bool")

    var scrut_base = lower_expr(ctx, scrutinee)
    if not ir_expr_is_name(scrut_base):
        let temp = fresh_c_temp_name(ctx, "match_value")
        let scrut_ty = ir_expr_type(scrut_base)
        output.push(ir.Stmt.stmt_local(name = temp, linkage_name = temp, ty = scrut_ty, value = scrut_base, line = 0, source_path = ""))
        scrut_base = alloc_expr(ir.Expr.expr_name(name = temp, ty = scrut_ty, pointer = false))

    ctx.match_label_counter += 1
    let m = ctx.match_label_counter
    let end_label = match_label_name(m, "end")
    let next_label = match_label_name(m, "arm_next")

    var arm_index: ptr_uint = 0
    while arm_index < arms.len:
        var arm: ast.MatchArm
        unsafe:
            arm = read(arms.data + arm_index)
        if arm_index > 0:
            output.push(ir.Stmt.stmt_label(name = match_arm_label(m, arm_index)))

        let pattern = arm.pattern
        if pattern == null:
            var blk = vec.Vec[ir.Stmt].create()
            append_span_stmts(ref_of(blk), lower_block(ctx, arm.body))
            if not stmts_terminate(blk.as_span()):
                blk.push(ir.Stmt.stmt_goto(label = end_label))
            output.push(ir.Stmt.stmt_block(body = blk.as_span()))
        else:
            let arm_name = variant_match_arm_name_from_pattern(pattern) else:
                fatal(c"lowering: unsupported variant match pattern")
            let goto_label = if arm_index < arms.len - 1: match_arm_label(m, arm_index + 1) else: next_label

            let kind_expr = alloc_expr(ir.Expr.expr_member(receiver = scrut_base, member = "kind", ty = int_ty))
            let tag_value = alloc_expr(ir.Expr.expr_name(name = variant_kind_const_name(outer_c, arm_name), ty = int_ty, pointer = false))
            let tag_check = alloc_expr(ir.Expr.expr_binary(operator = "!=", left = kind_expr, right = tag_value, ty = bool_ty))
            var then_body = vec.Vec[ir.Stmt].create()
            then_body.push(ir.Stmt.stmt_goto(label = goto_label))
            output.push(ir.Stmt.stmt_if(condition = tag_check, then_body = then_body.as_span(), else_body = span[ir.Stmt]()))

            var blk = vec.Vec[ir.Stmt].create()
            let payload_ty = types.Type.ty_named(name = variant_arm_type_name(outer_c, arm_name))
            match variant_arm_info(info, arm_name):
                Option.some as ai:
                    if ai.value.field_names.len > 0:
                        let payload_c = fresh_c_temp_name(ctx, "match_payload")
                        let data_member = alloc_expr(ir.Expr.expr_member(receiver = scrut_base, member = "data", ty = payload_ty))
                        let arm_data = alloc_expr(ir.Expr.expr_member(receiver = data_member, member = arm_name, ty = payload_ty))
                        blk.push(ir.Stmt.stmt_local(name = payload_c, linkage_name = payload_c, ty = payload_ty, value = arm_data, line = 0, source_path = ""))
                        ctx.locals.push(LocalBinding(name = payload_c, c_name = payload_c, ty = payload_ty, pointer = false))
                        lower_variant_field_bindings(ctx, ref_of(blk), pattern, ai.value, payload_c, payload_ty)
                        match arm.binding_name:
                            Option.some as bn:
                                let bc = c_local_name(bn.value)
                                let payload_ref = alloc_expr(ir.Expr.expr_name(name = payload_c, ty = payload_ty, pointer = false))
                                blk.push(ir.Stmt.stmt_local(name = bn.value, linkage_name = bc, ty = payload_ty, value = payload_ref, line = 0, source_path = ""))
                                ctx.locals.push(LocalBinding(name = bn.value, c_name = bc, ty = payload_ty, pointer = false))
                            Option.none:
                                pass
                Option.none:
                    pass
            append_span_stmts(ref_of(blk), lower_block(ctx, arm.body))
            if not stmts_terminate(blk.as_span()):
                blk.push(ir.Stmt.stmt_goto(label = end_label))
            output.push(ir.Stmt.stmt_block(body = blk.as_span()))
        arm_index += 1

    output.push(ir.Stmt.stmt_label(name = next_label))
    output.push(ir.Stmt.stmt_label(name = end_label))


## Emit `<field_type> <field> = <payload>.<field>;` bindings for each bare
## identifier in a struct pattern's argument list, skipping `_` discards.  Guards
## and equality patterns are not yet supported.
function lower_variant_field_bindings(ctx: ref[LowerCtx], blk: ref[vec.Vec[ir.Stmt]], pattern: ptr[ast.Expr], arm_info: VariantArmInfo, payload_c: str, payload_ty: types.Type) -> void:
    unsafe:
        match read(pattern):
            ast.Expr.expr_call as cl:
                var i: ptr_uint = 0
                while i < cl.args.len:
                    var arg: ast.Argument
                    arg = read(cl.args.data + i)
                    match arg.arg_name:
                        Option.some:
                            fatal(c"lowering: variant match equality patterns not yet supported")
                        Option.none:
                            pass
                    match read(arg.arg_value):
                        ast.Expr.expr_identifier as id:
                            if not id.name.equal("_"):
                                let field_ty = variant_arm_field_type(arm_info, id.name)
                                let bc = c_local_name(id.name)
                                let payload_ref = alloc_expr(ir.Expr.expr_name(name = payload_c, ty = payload_ty, pointer = false))
                                let field_expr = alloc_expr(ir.Expr.expr_member(receiver = payload_ref, member = id.name, ty = field_ty))
                                blk.push(ir.Stmt.stmt_local(name = id.name, linkage_name = bc, ty = field_ty, value = field_expr, line = 0, source_path = ""))
                                ctx.locals.push(LocalBinding(name = id.name, c_name = bc, ty = field_ty, pointer = false))
                        _:
                            fatal(c"lowering: variant match guard patterns not yet supported")
                    i += 1
            _:
                pass


## The arm name of a variant match pattern: `Variant.arm` (member access) or
## `Variant.arm(...)` (call whose callee is that member access).
function variant_match_arm_name_from_pattern(pattern: ptr[ast.Expr]) -> Option[str]:
    unsafe:
        match read(pattern):
            ast.Expr.expr_member_access as ma:
                return Option[str].some(value = ma.member_name)
            ast.Expr.expr_call as cl:
                return match_member_name(cl.callee)
            _:
                return Option[str].none


## The type of a named field within a variant arm, or `ty_error` when absent.
function variant_arm_field_type(arm_info: VariantArmInfo, field_name: str) -> types.Type:
    var i: ptr_uint = 0
    while i < arm_info.field_names.len:
        unsafe:
            if read(arm_info.field_names.data + i).equal(field_name):
                return read(arm_info.field_types.data + i)
        i += 1
    return types.Type.ty_error


## `__mt_match_<m>_<suffix>` label name.
function match_label_name(m: ptr_uint, suffix: str) -> str:
    var buf = string.String.create()
    buf.append("__mt_match_")
    fmt.append_ptr_uint(ref_of(buf), m)
    buf.append("_")
    buf.append(suffix)
    return buf.as_str()


## `__mt_match_<m>_arm_<index>` label name.
function match_arm_label(m: ptr_uint, index: ptr_uint) -> str:
    var buf = string.String.create()
    buf.append("__mt_match_")
    fmt.append_ptr_uint(ref_of(buf), m)
    buf.append("_arm_")
    fmt.append_ptr_uint(ref_of(buf), index)
    return buf.as_str()


## True when a lowered statement sequence ends in a terminator (return / goto /
## break / continue), so a following `goto` would be unreachable and is omitted —
## keeping the `end` label unused so the backend can drop it, matching Ruby.
function stmts_terminate(stmts: span[ir.Stmt]) -> bool:
    if stmts.len == 0:
        return false
    unsafe:
        match read(stmts.data + stmts.len - 1):
            ir.Stmt.stmt_return:
                return true
            ir.Stmt.stmt_goto:
                return true
            ir.Stmt.stmt_break:
                return true
            ir.Stmt.stmt_continue:
                return true
            _:
                return false


## Append every statement of a lowered block span into an output vector.
function append_span_stmts(dest: ref[vec.Vec[ir.Stmt]], stmts: span[ir.Stmt]) -> void:
    var i: ptr_uint = 0
    while i < stmts.len:
        unsafe:
            dest.push(read(stmts.data + i))
        i += 1


## The `types.Type` name for a variant arm's payload struct so it renders as the
## arm C name (`Token` + `ident` -> `Token_ident`, then `<module>_Token_ident`).
function variant_arm_type_name(outer_c: str, arm_name: str) -> str:
    var buf = string.String.create()
    buf.append(outer_c)
    buf.append("_")
    buf.append(arm_name)
    return buf.as_str()


## The discriminant constant name for an arm: `<outer_c>_kind_<arm>`.
function variant_kind_const_name(outer_c: str, arm_name: str) -> str:
    var buf = string.String.create()
    buf.append(outer_c)
    buf.append("_kind_")
    buf.append(arm_name)
    return buf.as_str()


## True when a lowered expression is a bare name reference (safe to reuse without
## hoisting, since re-rendering it has no side effects).
function ir_expr_is_name(ep: ptr[ir.Expr]) -> bool:
    unsafe:
        match read(ep):
            ir.Expr.expr_name:
                return true
            _:
                return false


function match_member_name(pattern: ptr[ast.Expr]) -> Option[str]:
    unsafe:
        match read(pattern):
            ast.Expr.expr_member_access as ma:
                return Option[str].some(value = ma.member_name)
            _:
                return Option[str].none


function named_type_name(t: types.Type) -> Option[str]:
    match t:
        types.Type.ty_named as n:
            return Option[str].some(value = n.name)
        types.Type.ty_imported as im:
            return Option[str].some(value = im.name)
        types.Type.ty_generic as g:
            return Option[str].some(value = g.name)
        _:
            return Option[str].none


## Extract the base variant name from a generic variant type (`Option[int]` →
## "Option"), so match on a generic scrutinee can resolve prelude arm names.
function generic_variant_name(t: types.Type) -> Option[str]:
    match t:
        types.Type.ty_generic as g:
            return Option[str].some(value = g.name)
        types.Type.ty_imported as im:
            if is_prelude_variant_name(im.name):
                return Option[str].some(value = im.name)
            return Option[str].none
        types.Type.ty_named as n:
            if is_prelude_variant_name(n.name):
                return Option[str].some(value = n.name)
            return Option[str].none
        _:
            return Option[str].none

function variant_match_allowed(ctx: ref[LowerCtx], name: str) -> bool:
    if ctx.variants.contains(name):
        return true
    # Check if the name starts with a known variant name (e.g. "Option_span_Field"
    # starts with "Option", which is a registered variant).
    var i: ptr_uint = 0
    while i < name.len:
        if name.byte_at(i) == '_':
            if ctx.variants.contains(name.slice(0, i)):
                return true
            break
        i += 1
    return false

function is_prelude_variant_name(name: str) -> bool:
    return name.equal("Option") or name.equal("Result") or name.starts_with("Option_") or name.starts_with("Result_")

## Extract the base variant name from a qualified name like "Option_span_Field" → "Option".
function variant_base_name(name: str) -> Option[str]:
    var i: ptr_uint = 0
    while i < name.len:
        if name.byte_at(i) == '_':
            return Option[str].some(value = name.slice(0, i))
        i += 1
    return Option[str].none


# =============================================================================
#  Type resolution helpers
# =============================================================================

function lookup_fn_sig(ctx: ref[LowerCtx], name: str) -> Option[analyzer.FnSig]:
    let sig_ptr = ctx.analysis.functions.get(name)
    if sig_ptr == null:
        return Option[analyzer.FnSig].none
    unsafe:
        return Option[analyzer.FnSig].some(value = read(sig_ptr))


function fn_sig_param_type(sig: Option[analyzer.FnSig], index: ptr_uint) -> types.Type:
    match sig:
        Option.some as s:
            if index < s.value.params.len:
                unsafe:
                    return read(s.value.params.data + index).ty
            return types.Type.ty_error
        Option.none:
            return types.Type.ty_error


function fn_sig_return_type(sig: Option[analyzer.FnSig]) -> types.Type:
    match sig:
        Option.some as s:
            if s.value.has_return_type:
                return s.value.return_type
            return types.primitive("void")
        Option.none:
            return types.primitive("void")


## A parameter's lowered type: resolved from the AST type ref (so tuple/array/
## span params carry full structure), falling back to the analyzer's signature.
function resolve_param_type(ctx: ref[LowerCtx], sig: Option[analyzer.FnSig], index: ptr_uint, param_type: ast.TypeRef) -> types.Type:
    var local_tref = param_type
    let resolved = resolve_type_ref(ctx, ptr_of(local_tref))
    if not types.is_error(resolved):
        return qualify_type(ctx, resolved)
    return qualify_type(ctx, fn_sig_param_type(sig, index))


## A function's lowered return type: resolved from the AST return type ref (so
## tuple/array/span returns carry full structure), falling back to the signature.
function resolve_return_type(ctx: ref[LowerCtx], sig: Option[analyzer.FnSig], return_type: ptr[ast.TypeRef]?) -> types.Type:
    let annotation = return_type else:
        return qualify_type(ctx, fn_sig_return_type(sig))
    let resolved = resolve_type_ref(ctx, annotation)
    if not types.is_error(resolved):
        return qualify_type(ctx, resolved)
    return qualify_type(ctx, fn_sig_return_type(sig))


## The resolved type of an AST expression: the analyzer's recorded type (keyed by
## node pointer identity, matching `record_expr_type`), or a structural fallback.
## A recorded `ty_error` is treated as unresolved so lowering can recover it
## (e.g. foreign-function call return types the analyzer does not track).
function expr_type(ctx: ref[LowerCtx], ep: ptr[ast.Expr]) -> types.Type:
    let key = unsafe: reinterpret[ptr_uint](ep)
    let tp = ctx.analysis.resolved_expr_types.get(key)
    if tp != null:
        let recorded = unsafe: read(tp)
        if not types.is_error(recorded):
            return recorded
    return fallback_type(ctx, ep)


## Resolve `import_alias.TypeName` to `ty_imported` when the member names a
## struct, enum, variant, or type alias in the imported module.
function import_qualified_type(ctx: ref[LowerCtx], ep: ptr[ast.Expr]) -> Option[types.Type]:
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
                            if a.module_name.equal(target_module):
                                if a.structs.contains(ma.member_name) or a.type_names.contains(ma.member_name):
                                    return Option[types.Type].some(value = types.Type.ty_imported(module_name = target_module, name = ma.member_name, args = span[types.Type]()))
                            ai += 1
                    _:
                        pass
            _:
                pass
    return Option[types.Type].none


function fallback_type(ctx: ref[LowerCtx], ep: ptr[ast.Expr]) -> types.Type:
    unsafe:
        match read(ep):
            ast.Expr.expr_integer_literal:
                return types.primitive("int")
            ast.Expr.expr_bool_literal:
                return types.primitive("bool")
            ast.Expr.expr_identifier as id:
                match lookup_local(ctx, id.name):
                    Option.some as lb:
                        return lb.value.ty
                    Option.none:
                        # Function reference: return its function type.
                        match lookup_fn_sig(ctx, id.name):
                            Option.some as s:
                                var ret = s.value.return_type
                                if not s.value.has_return_type:
                                    ret = types.primitive("void")
                                var param_types = vec.Vec[types.Type].create()
                                var pi: ptr_uint = 0
                                while pi < s.value.params.len:
                                    unsafe:
                                        param_types.push(read(s.value.params.data + pi).ty)
                                    pi += 1
                                return types.Type.ty_function(params = param_types.as_span(), return_type = types.alloc_type(ret), variadic = false)
                            Option.none:
                                pass
                        return types.Type.ty_error
            ast.Expr.expr_binary_op as bin:
                if is_comparison_operator(bin.operator):
                    return types.primitive("bool")
                return fallback_type(ctx, bin.left)
            ast.Expr.expr_unary_op as un:
                return fallback_type(ctx, un.operand)
            ast.Expr.expr_call as call:
                match read(call.callee):
                    ast.Expr.expr_identifier as id:
                        let foreign_ptr = ctx.foreign_map.get(id.name)
                        if foreign_ptr != null:
                            return read(foreign_ptr).return_ty
                        return fn_sig_return_type(lookup_fn_sig(ctx, id.name))
                    _:
                        return types.Type.ty_error
            ast.Expr.expr_member_access as ma:
                match import_qualified_type(ctx, ep):
                    Option.some as ty:
                        return ty.value
                    Option.none:
                        pass
                return fallback_type(ctx, ma.receiver)
            ast.Expr.expr_specialization as spec:
                match try_spec_type_name(ep):
                    Option.some as tn:
                        return types.Type.ty_generic(name = tn.value, args = sp_type(types.Type.ty_error))
                    Option.none:
                        return types.Type.ty_error
            _:
                return types.Type.ty_error


function is_comparison_operator(op: str) -> bool:
    return (
        op == "==" or op == "!=" or op == "<" or op == "<=" or op == ">" or op == ">="
        or op == "and" or op == "or"
    )


function is_int_type(t: types.Type) -> bool:
    match t:
        types.Type.ty_primitive as p:
            return p.name.equal("int")
        _:
            return false


function lookup_local(ctx: ref[LowerCtx], name: str) -> Option[LocalBinding]:
    if ctx.locals.len() == 0:
        return Option[LocalBinding].none
    var i = ctx.locals.len()
    while i > 0:
        i -= 1
        let lb_ptr = ctx.locals.get(i) else:
            break
        unsafe:
            if read(lb_ptr).name.equal(name):
                return Option[LocalBinding].some(value = read(lb_ptr))
    return Option[LocalBinding].none


function lookup_qualified_constant(ctx: ref[LowerCtx], name: str) -> Option[str]:
    if ctx.analysis.type_names.contains(name) or ctx.analysis.value_types.contains(name):
        return Option[str].some(value = naming.qualified_c_name(ctx.module_name, name))
    var import_values = ctx.analysis.imports.values()
    while true:
        let target_ptr = import_values.next() else:
            break
        let target_module = unsafe: read(target_ptr)
        match find_imported_analysis(ctx, target_module):
            Option.some as imported:
                if imported.value.type_names.contains(name) or imported.value.value_types.contains(name):
                    return Option[str].some(value = naming.qualified_c_name(target_module, name))
            Option.none:
                pass
    return Option[str].none


# =============================================================================
#  C-name mangling (mirrors lowering/utils.rb)
# =============================================================================

## C-safe local/parameter name: sanitized, with a trailing `_` when it collides
## with a C reserved word.
function c_local_name(name: str) -> str:
    let identifier = naming.sanitize_identifier(name)
    if c_reserved_identifier(identifier):
        var buf = string.String.create()
        buf.append(identifier)
        buf.append("_")
        return buf.as_str()
    return identifier


function c_reserved_identifier(identifier: str) -> bool:
    let words = reserved_words()
    var i: ptr_uint = 0
    while i < words.len:
        unsafe:
            if read(words.data + i).equal(identifier):
                return true
        i += 1
    return false


const RESERVED_WORD_COUNT: ptr_uint = 44
const RESERVED_WORDS: array[str, 44] = array[str, 44](
    "auto", "break", "case", "char", "const", "continue", "default", "do",
    "double", "else", "enum", "extern", "float", "for", "goto", "if", "inline",
    "int", "long", "register", "restrict", "return", "short", "signed",
    "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned",
    "void", "volatile", "while", "_Alignas", "_Alignof", "_Atomic", "_Bool",
    "_Complex", "_Generic", "_Imaginary", "_Noreturn", "_Static_assert",
    "_Thread_local"
)


function reserved_words() -> span[str]:
    return RESERVED_WORDS.as_span()


# =============================================================================
#  IR allocation
# =============================================================================

function alloc_expr(value: ir.Expr) -> ptr[ir.Expr]:
    var node = heap_mod.must_alloc[ir.Expr](1)
    unsafe:
        read(node) = value
    return node


function alloc_stmt(value: ir.Stmt) -> ptr[ir.Stmt]:
    var node = heap_mod.must_alloc[ir.Stmt](1)
    unsafe:
        read(node) = value
    return node


## Resolve a scalar type annotation (primitive or `str`) to a `types.Type`.
## Returns `ty_error` for compound/nullable/callable forms not handled in the
## current phase, signalling the caller to fall back to the initializer type.
function resolve_scalar_type_ref(declared: ptr[ast.TypeRef]) -> types.Type:
    unsafe:
        let t = read(declared)
        if t.is_dyn:
            return types.Type.ty_dyn(iface = unsafe: analyzer.qname_to_str(t.dyn_interface))
        if t.is_fn or t.is_proc or t.is_tuple or t.nullable:
            return types.Type.ty_error
        if t.arguments.len > 0:
            return types.Type.ty_error
        if t.name.parts.len != 1:
            return types.Type.ty_error
        let name = read(t.name.parts.data + 0)
        if name.equal("str"):
            return types.Type.ty_str
        if is_primitive_name(name):
            return types.primitive(name)
        return types.Type.ty_error


function is_primitive_name(name: str) -> bool:
    return (
        name.equal("bool") or name.equal("byte") or name.equal("ubyte") or name.equal("char")
        or name.equal("short") or name.equal("ushort") or name.equal("int") or name.equal("uint")
        or name.equal("long") or name.equal("ulong") or name.equal("ptr_int") or name.equal("ptr_uint")
        or name.equal("float") or name.equal("double") or name.equal("void") or name.equal("cstr")
    )


# =============================================================================
#  Format string lowering (f"...")
# =============================================================================

## Lower `let result = f"text #{expr} more"` into a sequence of builder calls:
##   var __fmt_N = mt_format_str_make()
##   mt_format_str_append_static(__fmt_N, "...")
##   mt_format_str_append_EXPRTY(__fmt_N, expr)
##   let result = mt_format_str_finish(__fmt_N, __fmt_N_capacity)
## The builder is a stack-local struct with a data pointer, len, and capacity.
function lower_format_string_local(ctx: ref[LowerCtx], output: ref[vec.Vec[ir.Stmt]], name: str, parts: span[ast.FormatStringPart]) -> void:
    let c_name = c_local_name(name)
    let str_ty = types.Type.ty_str
    # For format strings with only static text, return the text as a literal.
    # Otherwise, concatenate the parts using simple str operations.
    var all_static = true
    var pi: ptr_uint = 0
    while pi < parts.len and all_static:
        var part: ast.FormatStringPart
        unsafe:
            part = read(parts.data + pi)
        match part:
            ast.FormatStringPart.fmt_text:
                pass
            ast.FormatStringPart.fmt_expr:
                all_static = false
        pi += 1
    var value_expr: ptr[ir.Expr]
    if all_static:
        # Concatenate all static text parts into one str.
        var buf = string.String.create()
        pi = 0
        while pi < parts.len:
            var part: ast.FormatStringPart
            unsafe:
                part = read(parts.data + pi)
            match part:
                ast.FormatStringPart.fmt_text as t:
                    buf.append(t.value)
                _:
                    pass
            pi += 1
        let combined = buf.as_str()
        value_expr = alloc_expr(ir.Expr.expr_string_literal(value = combined, ty = str_ty, cstring = false))
    else:
        # Has interpolation: call the runtime format-string builder.
        # Emit builder allocation, appends, and finish.
        var builder_name = fresh_c_temp_name(ctx, "fmt_builder")
        var builder_c = builder_name
        let make_call = alloc_expr(ir.Expr.expr_call(callee = "mt_format_str_make", arguments = span[ir.Expr](), ty = str_ty))
        output.push(ir.Stmt.stmt_local(name = builder_name, linkage_name = builder_c, ty = str_ty, value = make_call, line = 0, source_path = ""))
        pi = 0
        while pi < parts.len:
            var part: ast.FormatStringPart
            unsafe:
                part = read(parts.data + pi)
            match part:
                ast.FormatStringPart.fmt_text as t:
                    var append_args = vec.Vec[ir.Expr].create()
                    unsafe:
                        append_args.push(read(alloc_expr(ir.Expr.expr_name(name = builder_c, ty = str_ty, pointer = false))))
                    let lit_val = t.value
                    var text_expr = alloc_expr(ir.Expr.expr_string_literal(value = lit_val, ty = str_ty, cstring = false))
                    unsafe:
                        append_args.push(read(text_expr))
                    let append_call = alloc_expr(ir.Expr.expr_call(callee = "mt_format_str_append_str", arguments = append_args.as_span(), ty = str_ty))
                    output.push(ir.Stmt.stmt_expression(expression = append_call, line = 0, source_path = ""))
                ast.FormatStringPart.fmt_expr as ex:
                    var interp_expr = lower_expr(ctx, ex.expression)
                    let interp_ty = ir_expr_type(interp_expr)
                    var helper = fmt_append_helper_name(interp_ty)
                    var append_args = vec.Vec[ir.Expr].create()
                    unsafe:
                        append_args.push(read(alloc_expr(ir.Expr.expr_name(name = builder_c, ty = str_ty, pointer = false))))
                        append_args.push(read(interp_expr))
                    let append_call = alloc_expr(ir.Expr.expr_call(callee = helper, arguments = append_args.as_span(), ty = str_ty))
                    output.push(ir.Stmt.stmt_expression(expression = append_call, line = 0, source_path = ""))
            pi += 1
        var finish_args = vec.Vec[ir.Expr].create()
        unsafe:
            finish_args.push(read(alloc_expr(ir.Expr.expr_name(name = builder_c, ty = str_ty, pointer = false))))
        value_expr = alloc_expr(ir.Expr.expr_call(callee = "mt_format_str_finish", arguments = finish_args.as_span(), ty = str_ty))
    output.push(ir.Stmt.stmt_local(name = name, linkage_name = c_name, ty = str_ty, value = value_expr, line = 0, source_path = ""))


## Map a type to its format-append helper name.
function fmt_append_helper_name(t: types.Type) -> str:
    if types.is_integer_type(t):
        return "mt_format_str_append_int"
    match t:
        types.Type.ty_str:
            return "mt_format_str_append_str"
        types.Type.ty_primitive as p:
            if p.name.equal("float") or p.name.equal("double"):
                return "mt_format_str_append_float"
            return "mt_format_str_append_int"
        _:
            return "mt_format_str_append_int"


# =============================================================================
#  Compile-time evaluation and lowering (when, inline if, inline match)
# =============================================================================

## A compile-time constant value: integer, boolean, string, or type.
variant ConstValue:
    cv_int(value: long)
    cv_bool(value: bool)
    cv_str(value: str)
    cv_type(ty: types.Type)


## Lower a `when` statement: evaluate the discriminant at compile time,
## find the matching branch, and only emit that branch's body.
function lower_when_stmt(ctx: ref[LowerCtx], output: ref[vec.Vec[ir.Stmt]], discriminant: ptr[ast.Expr], branches: span[ast.WhenBranch], else_body: ptr[ast.Stmt]?) -> void:
    match try_evaluate_const_expr(ctx, discriminant):
        Option.some as val:
            var i: ptr_uint = 0
            while i < branches.len:
                var br: ast.WhenBranch
                unsafe:
                    br = read(branches.data + i)
                match try_evaluate_const_expr(ctx, br.pattern):
                    Option.some as pv:
                        if const_values_equal(val.value, pv.value):
                            lower_span_stmts(ctx, output, br.body)
                            return
                    Option.none:
                        pass
                i += 1
            let eb = else_body
            if eb != null:
                lower_block_stmts(ctx, output, eb)
        Option.none:
            pass


## Lower an `inline if` statement.  Evaluate the condition; if true, emit
## the then-branch; otherwise emit the else branch (if present).
function lower_inline_if_statement(ctx: ref[LowerCtx], output: ref[vec.Vec[ir.Stmt]], branches: span[ast.IfBranch], else_body: ptr[ast.Stmt]?) -> void:
    if branches.len == 0:
        return
    var br: ast.IfBranch
    unsafe:
        br = read(branches.data + 0)
    match try_evaluate_const_expr(ctx, br.condition):
        Option.some as val:
            match val.value:
                ConstValue.cv_bool as bv:
                    if bv.value:
                        lower_block_stmts(ctx, output, br.body)
                        return
                    # False: check else
                    if branches.len > 1:
                        var eb: ast.IfBranch
                        unsafe:
                            eb = read(branches.data + 1)
                        lower_block_stmts(ctx, output, eb.body)
                        return
                    let el = else_body
                    if el != null:
                        lower_block_stmts(ctx, output, el)
                    return
                _:
                    return
        Option.none:
            # Can't evaluate at compile time: emit nothing (like Ruby).
            pass


## Lower an `inline match` statement.  Evaluate the scrutinee and only emit
## the matching arm's body.  If no arm matches, emit the wildcard or nothing.
function lower_inline_match_statement(ctx: ref[LowerCtx], output: ref[vec.Vec[ir.Stmt]], scrutinee: ptr[ast.Expr], arms: span[ast.MatchArm]) -> void:
    match try_evaluate_const_expr(ctx, scrutinee):
        Option.some as val:
            var i: ptr_uint = 0
            while i < arms.len:
                var arm: ast.MatchArm
                unsafe:
                    arm = read(arms.data + i)
                if arm.pattern == null:
                    if arm.body != null:
                        unsafe:
                            lower_block_stmts(ctx, output, ptr[ast.Stmt]<-arm.body)
                    return
                let pattern_ptr = arm.pattern else:
                    return
                match try_evaluate_const_expr(ctx, pattern_ptr):
                    Option.some as pv:
                        if const_values_equal(val.value, pv.value):
                            if arm.body != null:
                                unsafe:
                                    lower_block_stmts(ctx, output, ptr[ast.Stmt]<-arm.body)
                            return
                    Option.none:
                        pass
                i += 1
        Option.none:
            pass


## Compare two compile-time values for equality.  Integer values are compared
## with each other; booleans with booleans; strings with strings; types with types.
function const_values_equal(l: ConstValue, r: ConstValue) -> bool:
    match l:
        ConstValue.cv_int as li:
            match r:
                ConstValue.cv_int as ri:
                    return li.value == ri.value
                _:
                    return false
        ConstValue.cv_bool as lb:
            match r:
                ConstValue.cv_bool as rb:
                    return lb.value == rb.value
                _:
                    return false
        ConstValue.cv_str as ls:
            match r:
                ConstValue.cv_str as rs:
                    return ls.value.equal(rs.value)
                _:
                    return false
        ConstValue.cv_type as lt:
            match r:
                ConstValue.cv_type as rt:
                    return types_are_equal(lt.ty, rt.ty)
                _:
                    return false


## Simple type equality check for primitive/named types.
function types_are_equal(a: types.Type, b: types.Type) -> bool:
    let ta = types.type_to_string(a)
    let tb = types.type_to_string(b)
    return ta.equal(tb)


## Lower a span of statements (from a when branch) into the output vec.
function lower_span_stmts(ctx: ref[LowerCtx], output: ref[vec.Vec[ir.Stmt]], stmts: span[ast.Stmt]) -> void:
    var i: ptr_uint = 0
    while i < stmts.len:
        unsafe:
            lower_stmt(ctx, output, ptr[ast.Stmt]<-(stmts.data + i))
        i += 1


## Lower a block body (ptr to statement) into the output vec.
function lower_block_stmts(ctx: ref[LowerCtx], output: ref[vec.Vec[ir.Stmt]], body: ptr[ast.Stmt]) -> void:
    var blk: ast.Stmt
    unsafe:
        blk = read(body)
    match blk:
        ast.Stmt.stmt_block as b:
            var i: ptr_uint = 0
            while i < b.statements.len:
                unsafe:
                    lower_stmt(ctx, output, ptr[ast.Stmt]<-(b.statements.data + i))
                i += 1
        _:
            lower_stmt(ctx, output, body)


## Try to evaluate an AST expression at compile time, returning the constant
## value when the expression can be resolved.
## Look up an enum member's integer value.  Returns >= 0 on success, -1 if not found.
function try_lookup_enum_value(ctx: ref[LowerCtx], receiver: ptr[ast.Expr], member_name: str) -> long:
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
                            if en.name.equal(id.name):
                                return find_enum_member_value(en.enum_members, member_name)
                        ast.Decl.decl_flags as fl:
                            if fl.name.equal(id.name):
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
                    if a.module_name.equal(id.name):
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
        if m.name.equal(name):
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


function try_evaluate_const_expr(ctx: ref[LowerCtx], ep: ptr[ast.Expr]) -> Option[ConstValue]:
    unsafe:
        match read(ep):
            ast.Expr.expr_integer_literal as lit:
                return Option[ConstValue].some(value = ConstValue.cv_int(value = long<-lit.value))
            ast.Expr.expr_float_literal as lit:
                return Option[ConstValue].some(value = ConstValue.cv_int(value = long<-(lit.value)))
            ast.Expr.expr_bool_literal as b:
                return Option[ConstValue].some(value = ConstValue.cv_bool(value = b.value))
            ast.Expr.expr_string_literal as s:
                return Option[ConstValue].some(value = ConstValue.cv_str(value = s.value))
            ast.Expr.expr_identifier as id:
                let cv_entry = ctx.analysis.const_values.get(id.name)
                if cv_entry != null:
                    unsafe:
                        let cv_val = read(cv_entry)
                        return try_evaluate_const_expr(ctx, cv_val)
                if id.name.equal("true"):
                    return Option[ConstValue].some(value = ConstValue.cv_bool(value = true))
                if id.name.equal("false"):
                    return Option[ConstValue].some(value = ConstValue.cv_bool(value = false))
                return Option[ConstValue].none
            ast.Expr.expr_member_access as ma:
                match try_evaluate_const_expr(ctx, ma.receiver):
                    Option.some as rv:
                        return Option[ConstValue].some(value = rv.value)
                    Option.none:
                        pass
                # If the receiver is an enum type, look up the member value
                # from the enum's backing integer.
                let enum_val = try_lookup_enum_value(ctx, ma.receiver, ma.member_name)
                if enum_val >= 0:
                    return Option[ConstValue].some(value = ConstValue.cv_int(value = enum_val))
                return Option[ConstValue].none
            ast.Expr.expr_binary_op as bin:
                return evaluate_const_binary(ctx, bin.operator, bin.left, bin.right)
            ast.Expr.expr_unary_op as un:
                return evaluate_const_unary(ctx, un.operator, un.operand)
            _:
                return Option[ConstValue].none


function evaluate_const_unary(ctx: ref[LowerCtx], op: str, operand: ptr[ast.Expr]) -> Option[ConstValue]:
    match try_evaluate_const_expr(ctx, operand):
        Option.some as val:
            match val.value:
                ConstValue.cv_int as iv:
                    if op.equal("-"):
                        return Option[ConstValue].some(value = ConstValue.cv_int(value = -iv.value))
                    if op.equal("~"):
                        return Option[ConstValue].some(value = ConstValue.cv_int(value = ~iv.value))
                    return Option[ConstValue].none
                ConstValue.cv_bool as bv:
                    if op.equal("not"):
                        return Option[ConstValue].some(value = ConstValue.cv_bool(value = not bv.value))
                    return Option[ConstValue].none
                _:
                    return Option[ConstValue].none
        Option.none:
            return Option[ConstValue].none


function evaluate_const_binary(ctx: ref[LowerCtx], op: str, left: ptr[ast.Expr], right: ptr[ast.Expr]) -> Option[ConstValue]:
    match try_evaluate_const_expr(ctx, left):
        Option.some as lv:
            match try_evaluate_const_expr(ctx, right):
                Option.some as rv:
                    return const_binary_op(op, lv.value, rv.value)
                Option.none:
                    return Option[ConstValue].none
        Option.none:
            return Option[ConstValue].none


function const_binary_op(op: str, left_val: ConstValue, right_val: ConstValue) -> Option[ConstValue]:
    match left_val:
        ConstValue.cv_int as li:
            match right_val:
                ConstValue.cv_int as ri:
                    return Option[ConstValue].some(value = ConstValue.cv_int(value = apply_int_op(op, li.value, ri.value)))
                _:
                    return Option[ConstValue].none
        ConstValue.cv_bool as lb:
            match right_val:
                ConstValue.cv_bool as rb:
                    if op.equal("and"):
                        return Option[ConstValue].some(value = ConstValue.cv_bool(value = lb.value and rb.value))
                    if op.equal("or"):
                        return Option[ConstValue].some(value = ConstValue.cv_bool(value = lb.value or rb.value))
                    if op.equal("=="):
                        return Option[ConstValue].some(value = ConstValue.cv_bool(value = lb.value == rb.value))
                    if op.equal("!="):
                        return Option[ConstValue].some(value = ConstValue.cv_bool(value = lb.value != rb.value))
                    return Option[ConstValue].none
                _:
                    return Option[ConstValue].none
        ConstValue.cv_str as ls:
            match right_val:
                ConstValue.cv_str as rs:
                    if op.equal("=="):
                        return Option[ConstValue].some(value = ConstValue.cv_bool(value = ls.value.equal(rs.value)))
                    if op.equal("!="):
                        return Option[ConstValue].some(value = ConstValue.cv_bool(value = not ls.value.equal(rs.value)))
                    return Option[ConstValue].none
                _:
                    return Option[ConstValue].none
        ConstValue.cv_type as lt:
            match right_val:
                ConstValue.cv_type as rt:
                    if op.equal("=="):
                        return Option[ConstValue].some(value = ConstValue.cv_bool(value = types_are_equal(lt.ty, rt.ty)))
                    if op.equal("!="):
                        return Option[ConstValue].some(value = ConstValue.cv_bool(value = not types_are_equal(lt.ty, rt.ty)))
                    return Option[ConstValue].none
                _:
                    return Option[ConstValue].none


function apply_int_op(op: str, l: long, r: long) -> long:
    if op.equal("+"):
        return l + r
    if op.equal("-"):
        return l - r
    if op.equal("*"):
        return l * r
    if op.equal("/"):
        return l / r
    if op.equal("%"):
        return l % r
    if op.equal("=="):
        return long<-(l == r)
    if op.equal("!="):
        return long<-(l != r)
    if op.equal("<"):
        return long<-(l < r)
    if op.equal("<="):
        return long<-(l <= r)
    if op.equal(">"):
        return long<-(l > r)
    if op.equal(">="):
        return long<-(l >= r)
    if op.equal("<<"):
        return l << long<-(r)
    if op.equal(">>"):
        return l >> long<-(r)
    if op.equal("&"):
        return l & r
    if op.equal("|"):
        return l | r
    if op.equal("^"):
        return l ^ r
    return 0




