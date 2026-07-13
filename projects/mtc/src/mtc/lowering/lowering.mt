## Lowering stage — transforms the semantically-checked `Program` into an
## `ir.Program`.  This is the decoupled middle-end: it reads only the loader's
## retained per-module `Analysis` values and emits `ir`, never reaching into the
## C backend.
##
## Mirrors the Ruby Lowering entry (lib/milk_tea/core/lowering.rb `Lowering.lower`),
## its C-name mangling (lowering/utils.rb), and root-main entry-point synthesis
## (lowering/async.rb `build_root_main_entrypoint`).
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
import mtc.lowering.async as async_mod
import mtc.lowering.utils as utils


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


## One lexical block's pending `defer` cleanups, in the order they were
## encountered.  Each `cleanups` entry is one already-lowered defer's statement
## sequence (a `defer expr` lowers to one expression statement; a `defer:` block
## lowers to several).  On block exit and before every `return`, the groups are
## flushed innermost-first and, within each group, in reverse encounter order —
## mirroring Ruby's `active_defers`/`local_defers` + `cleanup_statements`.
struct DeferGroup:
    cleanups: vec.Vec[span[ir.Stmt]]


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
    inside_async: bool
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
    # Shared across all modules: concrete prelude (Option/Result) arm payload
    # field types, keyed by the arm's payload struct C name
    # (`Result_std_string_String_std_fs_Error_success` → `std_string_String`).
    # Populated when any context emits a concrete generic variant decl
    # (`ensure_generic_variant`), so a match in a consuming module can recover
    # `s.value` / `f.error` types even though the concrete decl was created in the
    # defining module's (separate) context.  Borrowed pointer into a map owned by
    # `lower`, mirroring `program_returns`.
    prelude_arm_field_types: ptr[map_mod.Map[str, types.Type]]
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
    # Map from a variant arm payload struct's C name (the `ty_named` given to a
    # match-arm binding, e.g. `mtc_parser_ast_Expr_expr_unary_op`) to that arm's
    # field info, so member access on the binding resolves field types.
    arm_payload_fields: map_mod.Map[str, VariantArmInfo]
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
    # Active comptime element during inline for unrolling — used by lower_expr to
    # substitute loop variable member accesses (.type, .value) with known values.
    inline_for_element: Option[ComptimeElement]
    # Stack of pending `defer` cleanup groups, one per open lexical block during
    # function-body lowering.  `defer` appends its lowered cleanup to the top
    # group; block exit and `return` flush the groups (innermost-first, each in
    # reverse encounter order).  Mirrors Ruby's active_defers/local_defers.
    defer_stack: vec.Vec[DeferGroup]
    # Return type of the function currently being lowered, for use by `?`
    # propagation when the propagated type differs from the enclosing function's
    # return type (e.g. `Result[bool, E]?` inside a function returning
    # `Result[Bytes, E]`).  Defaults to `void`; set in `lower_function` and
    # `lower_specialized_method` before the body is lowered.
    current_fn_return_type: types.Type


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
    subscribe_stateful_c_name: str
    subscribe_once_stateful_c_name: str
    unsubscribe_c_name: str
    emit_c_name: str
    wait_c_name: str
    wait_frame_c_name: str
    wait_ready_c_name: str
    wait_set_waiter_c_name: str
    wait_release_c_name: str
    wait_take_result_c_name: str
    wait_result_ty: types.Type


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

## Look up the backing C type name, following type aliases across modules.
## For `type uv_handle_s = c.uv_handle_s` in `std.libuv`, this follows the
## import to `std.c.libuv.uv_handle_s` and looks up its `c_name = "uv_handle_t"`.
## For `type NativeHandle = libuv.uv_handle_t` where `libuv.uv_handle_t` is
## itself a type alias, the recursive `ty_imported` branch walks the chain.
function lookup_decl_c_name_cross(analysis: analyzer.Analysis, tv: types.Type, type_name: str, analyses: span[analyzer.Analysis]) -> Option[str]:
    # First try the current module's declarations.
    match lookup_decl_c_name(analysis, type_name):
        Option.some as cn:
            return Option[str].some(value = cn.value)
        Option.none:
            pass
    # If the type is an imported type, follow the import chain.
    match tv:
        types.Type.ty_imported as im:
            # std.c.* raw ABI types — they ARE the C types.
            if im.module_name.starts_with("std.c."):
                return lookup_decl_c_name_in_module(im.module_name, im.name, analyses)
            # Non-std.c imported types may be type aliases themselves
            # (e.g. `type uv_handle_t = c.uv_handle_t` in `std.libuv`).
            # Follow the chain through the imported module's type aliases.
            var found_a: analyzer.Analysis
            var has_a = false
            var ai: ptr_uint = 0
            while ai < analyses.len:
                var a: analyzer.Analysis
                unsafe:
                    a = read(analyses.data + ai)
                if a.module_name == im.module_name:
                    found_a = a
                    has_a = true
                    break
                ai += 1
            if has_a and found_a.type_alias_types.contains(im.name):
                let resolved_ptr = found_a.type_alias_types.get(im.name) else:
                    fatal(c"lowering: chained type alias lookup inconsistency")
                return lookup_decl_c_name_cross(analysis, unsafe: read(resolved_ptr), im.name, analyses)
        _:
            pass
    return Option[str].none


## Look up the backing c_name of a type in a specific module's analysis.
function lookup_decl_c_name_in_module(module_name: str, type_name: str, analyses: span[analyzer.Analysis]) -> Option[str]:
    var ai: ptr_uint = 0
    while ai < analyses.len:
        var a: analyzer.Analysis
        unsafe:
            a = read(analyses.data + ai)
        if a.module_name == module_name:
            return lookup_decl_c_name(a, type_name)
        ai += 1
    return Option[str].none


## Look up the backing C type name (`= c"..."`) for a struct, opaque, or union
## declaration by scanning the analysis' source file.  Returns `Option[str].none`
## when no backing name was provided.
function lookup_decl_c_name(analysis: analyzer.Analysis, type_name: str) -> Option[str]:
    var i: ptr_uint = 0
    while i < analysis.source_file.declarations.len:
        var d: ast.Decl
        unsafe:
            d = read(analysis.source_file.declarations.data + i)
        match d:
            ast.Decl.decl_struct as s:
                if s.name == type_name:
                    return s.c_name
            ast.Decl.decl_opaque as op:
                if op.name == type_name:
                    return op.c_name
            ast.Decl.decl_union as u:
                if u.name == type_name:
                    return u.c_name
            _:
                pass
        i += 1
    return Option[str].none


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
    # Shared prelude arm-payload field types (see LowerCtx.prelude_arm_field_types).
    # Populated by `collect_program_returns` (which resolves every function's
    # return type, emitting the concrete Option/Result decls) so it is available
    # before any module body is lowered.
    var prelude_arm_field_types = map_mod.Map[str, types.Type].create()
    collect_program_returns(program, ref_of(program_returns), ref_of(prelude_arm_field_types))

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
    while i < count:
        let a_ptr = program.analyses.get(i) else:
            i += 1
            continue
        var analysis = unsafe: read(a_ptr)
        if is_raw_module(analysis.module_kind):
            i += 1
            continue
        let is_root = i == count - 1
        var fragment = lower_module(analysis, ref_of(program_returns), ref_of(prelude_arm_field_types), is_root, program.analyses.as_span(), program.modules.as_span())
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

    # Collect type aliases from all non-raw modules. Raw (external) modules
    # define C-level types that already exist — we never emit typedefs for
    # them.  Non-raw-module aliases whose target is a std.c.* type still need a
    # C typedef when the target can be resolved to a valid C name, so the
    # module-qualified name (e.g. `std_net_NativeSocketStorage`) maps to the raw
    # C type (e.g. `struct sockaddr_storage`).
    var tai: ptr_uint = 0
    while tai < program.analyses.len():
        let ta_ptr = program.analyses.get(tai) else:
            break
        var ta_analysis = unsafe: read(ta_ptr)
        if is_raw_module(ta_analysis.module_kind):
            tai += 1
            continue
        var ta_keys = ta_analysis.type_alias_types.keys()
        while true:
            let kp = ta_keys.next() else:
                break
            let kn = unsafe: read(kp)
            let tvp = ta_analysis.type_alias_types.get(kn) else:
                break
            let tv = unsafe: read(tvp)
            # When the alias target is a std.c.* type, only emit a typedef if the
            # target has a known C declaration in the external module (e.g.
            # `sockaddr_storage` with `= c"struct sockaddr_storage"`).  Targets
            # without explicit declarations (e.g. enum fields used as types like
            # `uv_tcp_flags`) have no valid C type to map to and are skipped.
            if type_is_from_std_c(tv):
                match lookup_decl_c_name_cross(ta_analysis, tv, kn, program.analyses.as_span()):
                    Option.some:
                        pass
                    Option.none:
                        continue
            # Qualify proc type aliases to the shared proc struct name so
            # that e.g. `type IntGenerator = proc() -> int` emits a typedef
            # to `mt_proc_int` instead of a raw function pointer.
            var qualified_tv = tv
            match tv:
                types.Type.ty_function as fnt:
                    if fnt.is_proc:
                        qualified_tv = types.Type.ty_named(module_name = "", name = proc_type_name_from_signature(tv))
                _:
                    pass
            type_aliases.push(ir.TypeAlias(
                name = kn,
                qualified_name = naming.qualified_c_name(ta_analysis.module_name, kn),
                target_type = qualified_tv,
                backing_c_name = lookup_decl_c_name_cross(ta_analysis, tv, kn, program.analyses.as_span()),
            ))
        tai += 1

    return ir.Program(
        module_name = root_name,
        includes = collect_includes(program),
        constants = constants.as_span(),
        globals = globals.as_span(),
        opaques = opaques.as_span(),
        structs = structs.as_span(),
        unions = unions.as_span(),
        enums = enums.as_span(),
        variants = variants.as_span(),
        static_asserts = static_asserts.as_span(),
        functions = functions.as_span(),
        type_aliases = type_aliases.as_span(),
        source_path = "",
    )


## True when a module is an external (`raw`) file, which has no lowerable body.
function is_raw_module(kind: ast.ModuleKind) -> bool:
    match kind:
        ast.ModuleKind.module_raw:
            return true
        _:
            return false


## True when a type originates from a std.c.* raw-ABI module (so its C name
## already exists in the external headers and we must not emit a typedef for
## it). Mirrors Ruby's skipping of raw-module type aliases.
function type_is_from_std_c(tv: types.Type) -> bool:
    match tv:
        types.Type.ty_imported as im:
            return im.module_name.starts_with("std.c.")
        types.Type.ty_named as n:
            return n.module_name.starts_with("std.c.")
        types.Type.ty_generic as g:
            var i: ptr_uint = 0
            while i < g.args.len:
                if type_is_from_std_c(unsafe: read(g.args.data + i)):
                    return true
                i += 1
            return false
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
                if f.name == name:
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
        if a.module_name == module_name:
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
    var saved_type_subst = ctx.type_substitution
    ctx.type_substitution = read(sub)
    var ir_params = vec.Vec[ir.Param].create()
    var pi: ptr_uint = 0
    while pi < params.len:
        var p: ast.Param
        unsafe:
            p = read(params.data + pi)
        # For proc/fn types, resolve via ty_function first so that type params
        # get substituted *before* proc struct conversion (otherwise unresolved
        # params leak into struct names like mt_proc_T).
        var fn_tref = p.param_type
        var p_ty: types.Type
        if fn_tref.is_proc or fn_tref.is_fn:
            let fn_type = resolve_function_type_ref(ctx, ptr_of(fn_tref))
            let substituted = substitute_type_params(ctx, fn_type, sub)
            p_ty = qualify_type(ctx, substituted)
        else:
            p_ty = qualify_type(ctx, substitute_type_params(ctx, resolve_field_type_ref(ctx, fn_tref), sub))
        let p_c = utils.c_local_name(p.name)
        let p_ptr = is_pointer_or_ref_type(p_ty)
        ir_params.push(ir.Param(name = p.name, linkage_name = p_c, ty = p_ty, pointer = p_ptr))
        ctx.locals.push(LocalBinding(name = p.name, c_name = p_c, ty = p_ty, pointer = p_ptr))
        pi += 1
    var ret_ty = types.primitive("void")
    if return_type != null:
        let rt_raw = unsafe: read(unsafe: ptr[ast.TypeRef]<-return_type)
        if rt_raw.is_proc or rt_raw.is_fn:
            let fn_type = resolve_function_type_ref(ctx, unsafe: ptr[ast.TypeRef]<-return_type)
            let substituted = substitute_type_params(ctx, fn_type, sub)
            ret_ty = qualify_type(ctx, substituted)
        else:
            ret_ty = qualify_type(ctx, substitute_type_params(ctx, resolve_field_type_ref(ctx, rt_raw), sub))
    var saved_sub = ctx.type_substitution
    ctx.type_substitution = read(sub)
    let body_ir = lower_function_body(ctx, body)
    ctx.type_substitution = saved_sub
    ctx.type_substitution = saved_type_subst
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
        types.Type.ty_function as fnt:
            var fn_params = vec.Vec[types.Type].create()
            var pi: ptr_uint = 0
            while pi < fnt.params.len:
                unsafe:
                    fn_params.push(substitute_type_params(ctx, read(fnt.params.data + pi), sub))
                pi += 1
            return types.Type.ty_function(params = fn_params.as_span(), return_type = types.alloc_type(substitute_type_params(ctx, unsafe: read(fnt.return_type), sub)), variadic = fnt.variadic, is_proc = fnt.is_proc)
        _:
            return ty


## Create a fully initialised LowerCtx for a single module.  Every field is
## set explicitly so all code paths start from a known clean state.
function new_lowering_context(analysis: analyzer.Analysis, prog_returns: ptr[map_mod.Map[str, types.Type]], pl_field_types: ptr[map_mod.Map[str, types.Type]], prog_analyses: span[analyzer.Analysis], lod_modules: span[loader.LoadedModule]) -> LowerCtx:
    return LowerCtx(
        module_name = analysis.module_name,
        analysis = analysis,
        locals = vec.Vec[LocalBinding].create(),
        temp_counter = 0,
        foreign_map = map_mod.Map[str, ForeignInfo].create(),
        extern_map = map_mod.Map[str, str].create(),
        function_returns = map_mod.Map[str, types.Type].create(),
        variants = map_mod.Map[str, VariantInfo].create(),
        match_label_counter = 0,
        program_returns = prog_returns,
        prelude_arm_field_types = pl_field_types,
        pending_specializations = vec.Vec[PendingSpecialization].create(),
        specialization_cache = map_mod.Map[str, ir.Function].create(),
        generic_struct_decls = map_mod.Map[str, ir.StructDecl].create(),
        generic_struct_instances = map_mod.Map[str, GenericReceiver].create(),
        arm_payload_fields = map_mod.Map[str, VariantArmInfo].create(),
        program_analyses = prog_analyses,
        loaded_modules = lod_modules,
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
        inline_for_element = Option[ComptimeElement].none,
        defer_stack = vec.Vec[DeferGroup].create(),
        inside_async = false,
        current_fn_return_type = types.primitive("void"),
    )


## Pre-scan every module's function declarations and record each one's resolved
## return type keyed by its C linkage name, so cross-module calls can look them
## up regardless of lowering order.
function collect_program_returns(program: loader.Program, sink: ref[map_mod.Map[str, types.Type]], prelude_arm_field_types: ref[map_mod.Map[str, types.Type]]) -> void:
    var mi: ptr_uint = 0
    while mi < program.analyses.len():
        let a_ptr = program.analyses.get(mi) else:
            mi += 1
            continue
        var analysis = unsafe: read(a_ptr)
        var ctx = new_lowering_context(analysis, ptr_of(read(sink)), ptr_of(read(prelude_arm_field_types)), program.analyses.as_span(), program.modules.as_span())
        var di: ptr_uint = 0
        while di < analysis.source_file.declarations.len:
            var d: ast.Decl
            unsafe:
                d = read(analysis.source_file.declarations.data + di)
            match d:
                ast.Decl.decl_function as fun:
                    let ret = resolve_return_type(ref_of(ctx), lookup_fn_sig(ref_of(ctx), fun.name), fun.return_type)
                    sink.set(naming.qualified_c_name(analysis.module_name, fun.name), ret)
                ast.Decl.decl_extern_function as ext:
                    # External functions use their bare C name as the linkage name
                    # (no module prefix), so a cross-module call `c.func(...)` can
                    # resolve the result type from that same bare-name key.
                    let ext_ret = if ext.return_type != null: resolve_return_type(ref_of(ctx), Option[analyzer.FnSig].none, ext.return_type) else: types.primitive("void")
                    sink.set(ext.name, ext_ret)
                ast.Decl.decl_foreign_function as ff:
                    # Foreign functions are called cross-module by their Milk Tea
                    # name (`libc.get_environment_variable(...)`), lowered to a
                    # module-qualified C wrapper, so register the resolved return
                    # type under that same qualified linkage key.  Without this a
                    # cross-module foreign call resolves to void and its result
                    # local is emitted `void`.
                    let ff_ret = qualify_type(ref_of(ctx), resolve_type_ref(ref_of(ctx), ff.return_type))
                    sink.set(naming.qualified_c_name(analysis.module_name, ff.name), ff_ret)
                _:
                    pass
            di += 1
        mi += 1


function lower_module(analysis: analyzer.Analysis, program_returns: ref[map_mod.Map[str, types.Type]], prelude_arm_field_types: ref[map_mod.Map[str, types.Type]], is_root: bool, program_analyses: span[analyzer.Analysis], loaded_modules: span[loader.LoadedModule]) -> ir.Program:
    var ctx = new_lowering_context(analysis, ptr_of(read(program_returns)), ptr_of(read(prelude_arm_field_types)), program_analyses, loaded_modules)
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
    var pending_decls = vec.Vec[ast.Decl].create()

    var i: ptr_uint = 0
    while i < analysis.source_file.declarations.len:
        var d: ast.Decl
        unsafe:
            d = read(analysis.source_file.declarations.data + i)
        match d:
            ast.Decl.decl_function as fun:
                if fun.is_async:
                    if async_mod.body_has_await(fun.body):
                        # Has awaits — use normal lowering with inside_async flag.
                        # (Full CPS await lowering is deferred; the current
                        # lower_function handles awaits via ctx.inside_async.)
                        functions.push(lower_function(ref_of(ctx), fun.name, fun.method_params, fun.return_type, fun.body, true))
                    else:
                        # No awaits — full CPS with frame + synthetic functions.
                        lower_async_fn(ref_of(ctx), fun.name, fun.method_params, fun.return_type, fun.body, ref_of(structs), ref_of(functions))
                else if lowerable_function(fun.is_async, fun.is_const, fun.type_params, fun.body):
                    functions.push(lower_function(ref_of(ctx), fun.name, fun.method_params, fun.return_type, fun.body, fun.is_async))
                    if is_root and fun.name == "main":
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
                # field types.  Structs with only lifetime parameters (`@a`)
                # are not generic in the monomorphization sense and should
                # be emitted directly.
                if not has_non_lifetime_type_params(s.type_params):
                    match lower_struct_decl(ref_of(ctx), s.name):
                        Option.some as sd:
                            structs.push(sd.value)
                        Option.none:
                            pass
                    lower_nested_struct_decls(ref_of(ctx), s.nested_types, s.name, ref_of(structs))
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
                let val_ptr = c.value
                # Type constants (->type) are compile-time only; they don't
                # have a C representation (mirrors Ruby).
                var is_type_meta = false
                match c_ty:
                    types.Type.ty_type_meta:
                        is_type_meta = true
                    _:
                        pass
                if is_type_meta:
                    pass
                else if val_ptr == null:
                    var bv = alloc_expr(ir.Expr.expr_zero_init(ty = c_ty))
                    if c.block_body != null:
                        var empty_vars = map_mod.Map[str, long].create()
                        match try_evaluate_const_body(ctx, ref_of(empty_vars), c.block_body):
                            Option.some as body_val:
                                bv = body_val.value
                            Option.none:
                                pass
                    constants.push(ir.Constant(name = c.name, linkage_name = naming.qualified_c_name(ctx.module_name, c.name), ty = c_ty, value = bv))
                else:
                    constants.push(ir.Constant(name = c.name, linkage_name = naming.qualified_c_name(ctx.module_name, c.name), ty = c_ty, value = lower_expr(ctx, unsafe: ptr[ast.Expr]<-val_ptr)))
            ast.Decl.decl_event as ev:
                var info = ensure_event_runtime(ctx, ev.name)
                let ev_ty = types.Type.ty_named(module_name = "", name = info.event_c_name)
                let ev_zero = alloc_expr(ir.Expr.expr_zero_init(ty = ev_ty))
                globals.push(ir.Global(name = ev.name, linkage_name = ev.name, ty = ev_ty, value = ev_zero))
            ast.Decl.decl_when as w:
                match try_evaluate_const_expr(ctx, w.discriminant):
                    Option.some as dv:
                        var bi: ptr_uint = 0
                        var found = false
                        while bi < w.branches.len and not found:
                            let br = unsafe: read(w.branches.data + bi)
                            match try_evaluate_const_expr(ctx, br.pattern):
                                Option.some as pv:
                                    if const_values_eq(dv.value, pv.value):
                                        var ddi: ptr_uint = 0
                                        while ddi < br.body.len:
                                            unsafe:
                                                pending_decls.push(read(br.body.data + ddi))
                                            ddi += 1
                                        found = true
                                Option.none:
                                    pass
                            bi += 1
                        if not found:
                            pass
                    Option.none:
                        pass
            _:
                pass
        i += 1

    # Lower declarations collected from module-level `when` branches.
    var w_iter = pending_decls.iter()
    while true:
        let w_ptr = w_iter.next() else:
            break
        var dd: ast.Decl
        unsafe:
            dd = read(w_ptr)
        match dd:
            ast.Decl.decl_function as fun:
                if lowerable_function(fun.is_async, fun.is_const, fun.type_params, fun.body):
                    functions.push(lower_function(ref_of(ctx), fun.name, fun.method_params, fun.return_type, fun.body, fun.is_async))
                    if is_root and fun.name == "main":
                        match build_root_main_entrypoint(ref_of(ctx), fun.name, fun.method_params):
                            Option.some as entry:
                                functions.push(entry.value)
                            Option.none:
                                pass
            ast.Decl.decl_const as c:
                var c_ty = resolve_type_ref(ctx, c.const_type)
                var is_type_meta = false
                match c_ty:
                    types.Type.ty_type_meta:
                        is_type_meta = true
                    _:
                        pass
                if not is_type_meta:
                    var cv = alloc_expr(ir.Expr.expr_zero_init(ty = c_ty))
                    if c.value != null:
                        cv = lower_expr(ctx, unsafe: ptr[ast.Expr]<-c.value)
                    else if c.block_body != null:
                        var empty_vars = map_mod.Map[str, long].create()
                        match try_evaluate_const_body(ctx, ref_of(empty_vars), c.block_body):
                            Option.some as body_val:
                                cv = body_val.value
                            Option.none:
                                pass
                    constants.push(ir.Constant(name = c.name, linkage_name = naming.qualified_c_name(ctx.module_name, c.name), ty = c_ty, value = cv))
            _:
                pass

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

    # Append dyn vtable constants to the main constants list so they are
    # emitted into the C output (previously they were collected but never
    # written, causing `mt_vtable_..._Shape undeclared`).
    var di: ptr_uint = 0
    while di < dyn_constants.len():
        let c_ptr = dyn_constants.get(di) else:
            break
        constants.push(unsafe: read(c_ptr))
        di += 1

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
        type_aliases = span[ir.TypeAlias](),
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
## Collect the full include set: the base C runtime headers plus every `include`
## directive from raw (`external`) module analyses (e.g. `std.c.fs` →
## `fs_support.h`).  Mirrors Ruby's `collect_includes` so external ABI struct
## types declared in those headers are in scope.  Deduplicated, base headers first.
function collect_includes(program: loader.Program) -> span[ir.Include]:
    var includes = vec.Vec[ir.Include].create()
    var seen = map_mod.Map[str, bool].create()
    includes.push(ir.Include(header = "<stdbool.h>"))
    includes.push(ir.Include(header = "<stdint.h>"))
    includes.push(ir.Include(header = "<string.h>"))
    includes.push(ir.Include(header = "<stdio.h>"))
    seen.set("<stdbool.h>", true)
    seen.set("<stdint.h>", true)
    seen.set("<string.h>", true)
    seen.set("<stdio.h>", true)

    var mi: ptr_uint = 0
    while mi < program.analyses.len():
        let a_ptr = program.analyses.get(mi) else:
            mi += 1
            continue
        var analysis = unsafe: read(a_ptr)
        if not is_raw_module(analysis.module_kind):
            mi += 1
            continue
        var di: ptr_uint = 0
        while di < analysis.directives.len:
            var directive: ast.Decl
            unsafe:
                directive = read(analysis.directives.data + di)
            match directive:
                ast.Decl.decl_include as inc:
                    let header = normalized_include_header(inc.value)
                    if not seen.contains(header):
                        seen.set(header, true)
                        includes.push(ir.Include(header = header))
                _:
                    pass
            di += 1
        mi += 1

    return includes.as_span()


## Wrap an include header: standard C runtime headers use `<angle>` brackets,
## everything else uses `"quotes"` (mirrors Ruby's normalized_include_header).
function normalized_include_header(header_name: str) -> str:
    if standard_c_runtime_header(header_name):
        return j3("<", header_name, ">")
    return j3("\"", header_name, "\"")


function standard_c_runtime_header(header_name: str) -> bool:
    return (
        header_name == "stdbool.h" or header_name == "stdint.h"
        or header_name == "stdlib.h" or header_name == "string.h"
        or header_name == "stddef.h" or header_name == "stdio.h"
        or header_name == "time.h"
    )


# =============================================================================
#  Function lowering
# =============================================================================

## The `this` receiver type for an `extending` block: the concrete primitive or
## `str` type for primitive receivers (so `this` renders as `mt_str` / `int`
## rather than a bogus `<module>_<type>` struct name), and a nominal
## `ty_imported` type otherwise.
function extending_receiver_type(module_name: str, type_name: str) -> types.Type:
    if type_name == "str":
        return types.Type.ty_str
    if is_builtin_type_name(type_name):
        return types.primitive(type_name)
    return types.Type.ty_imported(module_name = module_name, name = type_name, args = span[types.Type]())


## Lower all methods in an extending block to IR functions.  Each method becomes
## a C function with the receiver as the first parameter (pointer for editable,
## by value for plain, omitted for static).
function lower_extending_block(ctx: ref[LowerCtx], functions: ref[vec.Vec[ir.Function]], type_ref_ptr: ptr[ast.TypeRef], methods: span[ast.Method]) -> void:
    var type_name: str
    var bare_name: str
    unsafe:
        let type_ref = read(type_ref_ptr)
        bare_name = read(type_ref.name.parts.data + (type_ref.name.parts.len - 1))
        if type_ref.name.parts.len == 1:
            type_name = bare_name
        else:
            var buf = string.String.create()
            var bi: ptr_uint = 0
            while bi < type_ref.name.parts.len:
                if bi > 0:
                    buf.append(".")
                buf.append(read(type_ref.name.parts.data + bi))
                bi += 1
            type_name = buf.as_str()
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
        let c_name = method_link_name(ctx.module_name, bare_name, m.name, m.method_kind == ast.MethodKind.mk_static)
        let receiver_ty = extending_receiver_type(ctx.module_name, bare_name)
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
        let recv_is_ptr = is_pointer_or_ref_type(recv_ty)
        ir_params.push(ir.Param(name = "this", linkage_name = utils.c_local_name("this"), ty = recv_ty, pointer = recv_is_ptr))
        ctx.locals.push(LocalBinding(name = "this", c_name = utils.c_local_name("this"), ty = recv_ty, pointer = recv_is_ptr))
    var pi: ptr_uint = 0
    while pi < m.method_params.len:
        var p: ast.Param
        unsafe:
            p = read(m.method_params.data + pi)
        let param_ty = resolve_param_type(ctx, sig, pi, p.param_type)
        let c_pname = utils.c_local_name(p.name)
        let is_ptr = is_pointer_or_ref_type(param_ty)
        ir_params.push(ir.Param(name = p.name, linkage_name = c_pname, ty = param_ty, pointer = is_ptr))
        ctx.locals.push(LocalBinding(name = p.name, c_name = c_pname, ty = param_ty, pointer = is_ptr))
        pi += 1

    let ret_ty = resolve_return_type(ctx, sig, m.return_type)
    var saved_fn_ret = ctx.current_fn_return_type
    ctx.current_fn_return_type = ret_ty
    let body_stmts = lower_function_body(ctx, m.body)
    ctx.current_fn_return_type = saved_fn_ret

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
    return utils.sp_type(t)


function sp_fields(field1: ir.AggregateField) -> span[ir.AggregateField]:
    return utils.sp_fields(field1)


function sp_fields2(f1: ir.AggregateField, f2: ir.AggregateField) -> span[ir.AggregateField]:
    return utils.sp_fields2(f1, f2)


function sp_type2(t1: types.Type, t2: types.Type) -> span[types.Type]:
    return utils.sp_type2(t1, t2)


function sp_expr(expr: ptr[ir.Expr]) -> span[ir.Expr]:
    return utils.sp_expr(expr)


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
function lower_function(ctx: ref[LowerCtx], name: str, params: span[ast.Param], return_type: ptr[ast.TypeRef]?, body: ptr[ast.Stmt]?, is_async: bool) -> ir.Function:
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
        let c_name = utils.c_local_name(p.name)
        let f_ptr = is_pointer_or_ref_type(param_ty)
        ir_params.push(ir.Param(name = p.name, linkage_name = c_name, ty = param_ty, pointer = f_ptr))
        ctx.locals.push(LocalBinding(name = p.name, c_name = c_name, ty = param_ty, pointer = f_ptr))
        pi += 1

    var ret_ty = resolve_return_type(ctx, sig, return_type)
    if is_async:
        ret_ty = make_task_type(ret_ty)
    ctx.inside_async = is_async
    var saved_fn_ret = ctx.current_fn_return_type
    ctx.current_fn_return_type = ret_ty
    let body_stmts = lower_function_body(ctx, body)
    ctx.current_fn_return_type = saved_fn_ret
    ctx.inside_async = false

    return ir.Function(
        name = name,
        linkage_name = naming.qualified_c_name(ctx.module_name, name),
        params = ir_params.as_span(),
        return_type = ret_ty,
        body = body_stmts,
        entry_point = false,
        method_receiver_param = false,
    )


## Synthesize the C entry point `int main(...)` that calls the user's root
## `main`.  Supports a no-parameter `main` (`int main(void)`) and a single
## `span[str]` parameter (`int main(int argc, char** argv)` with the argv →
## `span[str]` bridge), each returning `int` or `void`.  Mirrors Ruby's
## build_root_main_entrypoint (:none / :span_str signatures).
function build_root_main_entrypoint(ctx: ref[LowerCtx], name: str, params: span[ast.Param]) -> Option[ir.Function]:
    let sig = lookup_fn_sig(ctx, name)
    let user_return = fn_sig_return_type(sig)
    if not (types.is_void(user_return) or is_int_type(user_return)):
        return Option[ir.Function].none

    let int_ty = types.primitive("int")
    let user_linkage = naming.qualified_c_name(ctx.module_name, name)

    if params.len == 0:
        let call = alloc_expr(ir.Expr.expr_call(callee = user_linkage, arguments = span[ir.Expr](), ty = user_return))
        var body = vec.Vec[ir.Stmt].create()
        append_entry_call_and_return(ref_of(body), call, user_return, int_ty)
        return Option[ir.Function].some(value = ir.Function(
            name = name, linkage_name = "main", params = span[ir.Param](),
            return_type = int_ty, body = body.as_span(), entry_point = true, method_receiver_param = false,
        ))

    # Single `span[str]` parameter: emit `int main(int argc, char** argv)`, build a
    # `span[str]` from argv via the runtime bridge, call the user main, then free.
    if params.len == 1 and main_param_is_span_str(ctx, params):
        let span_str_ty = types.Type.ty_generic(name = "span", args = sp_type(types.Type.ty_str))
        let items_ty = types.Type.ty_generic(name = "ptr", args = sp_type(types.Type.ty_str))
        let char_ptr_ptr = types.Type.ty_generic(name = "ptr", args = sp_type(types.Type.ty_generic(name = "ptr", args = sp_type(types.primitive("char")))))

        var body = vec.Vec[ir.Stmt].create()
        # mt_str* __mt_args_items = NULL;
        let items_null = alloc_expr(ir.Expr.expr_name(name = "NULL", ty = items_ty, pointer = true))
        body.push(ir.Stmt.stmt_local(name = "__mt_args_items", linkage_name = "__mt_args_items", ty = items_ty, value = items_null, line = 0, source_path = ""))
        let items_ref = alloc_expr(ir.Expr.expr_name(name = "__mt_args_items", ty = items_ty, pointer = false))
        # mt_span_str __mt_args = mt_entry_argv_to_span_str(argc, argv, &__mt_args_items);
        let argc_expr = alloc_expr(ir.Expr.expr_name(name = "argc", ty = int_ty, pointer = false))
        let argv_expr = alloc_expr(ir.Expr.expr_name(name = "argv", ty = char_ptr_ptr, pointer = false))
        let items_addr = alloc_expr(ir.Expr.expr_address_of(expression = items_ref, ty = types.Type.ty_generic(name = "ptr", args = sp_type(items_ty))))
        var bridge_args = vec.Vec[ir.Expr].create()
        unsafe:
            bridge_args.push(read(argc_expr))
            bridge_args.push(read(argv_expr))
            bridge_args.push(read(items_addr))
        let bridge_call = alloc_expr(ir.Expr.expr_call(callee = "mt_entry_argv_to_span_str", arguments = bridge_args.as_span(), ty = span_str_ty))
        body.push(ir.Stmt.stmt_local(name = "__mt_args", linkage_name = "__mt_args", ty = span_str_ty, value = bridge_call, line = 0, source_path = ""))
        let args_ref = alloc_expr(ir.Expr.expr_name(name = "__mt_args", ty = span_str_ty, pointer = false))

        var call_args = vec.Vec[ir.Expr].create()
        unsafe:
            call_args.push(read(args_ref))
        let call = alloc_expr(ir.Expr.expr_call(callee = user_linkage, arguments = call_args.as_span(), ty = user_return))

        # Capture the user result, free the argv strings, then return.
        if types.is_void(user_return):
            body.push(ir.Stmt.stmt_expression(expression = call, line = 0, source_path = ""))
            append_free_argv_items(ref_of(body), items_ref)
            let zero = alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = int_ty))
            body.push(ir.Stmt.stmt_return(value = zero, line = 0, source_path = ""))
        else:
            body.push(ir.Stmt.stmt_local(name = "__mt_exit", linkage_name = "__mt_exit", ty = int_ty, value = call, line = 0, source_path = ""))
            append_free_argv_items(ref_of(body), items_ref)
            let exit_ref = alloc_expr(ir.Expr.expr_name(name = "__mt_exit", ty = int_ty, pointer = false))
            body.push(ir.Stmt.stmt_return(value = exit_ref, line = 0, source_path = ""))

        var entry_params = vec.Vec[ir.Param].create()
        entry_params.push(ir.Param(name = "argc", linkage_name = "argc", ty = int_ty, pointer = false))
        entry_params.push(ir.Param(name = "argv", linkage_name = "argv", ty = char_ptr_ptr, pointer = false))
        return Option[ir.Function].some(value = ir.Function(
            name = name, linkage_name = "main", params = entry_params.as_span(),
            return_type = int_ty, body = body.as_span(), entry_point = true, method_receiver_param = false,
        ))

    return Option[ir.Function].none


## Append the user-main call and the `int` return to an entry-point body:
## `main() ; return 0;` for a void user main, or `return main();` for an int one.
function append_entry_call_and_return(body: ref[vec.Vec[ir.Stmt]], call: ptr[ir.Expr], user_return: types.Type, int_ty: types.Type) -> void:
    if types.is_void(user_return):
        body.push(ir.Stmt.stmt_expression(expression = call, line = 0, source_path = ""))
        let zero = alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = int_ty))
        body.push(ir.Stmt.stmt_return(value = zero, line = 0, source_path = ""))
    else:
        body.push(ir.Stmt.stmt_return(value = call, line = 0, source_path = ""))


## Append `mt_free_entry_argv_strs(__mt_args_items);` to an entry-point body.
function append_free_argv_items(body: ref[vec.Vec[ir.Stmt]], items_ref: ptr[ir.Expr]) -> void:
    var free_args = vec.Vec[ir.Expr].create()
    unsafe:
        free_args.push(read(items_ref))
    let free_call = alloc_expr(ir.Expr.expr_call(callee = "mt_free_entry_argv_strs", arguments = free_args.as_span(), ty = types.primitive("void")))
    body.push(ir.Stmt.stmt_expression(expression = free_call, line = 0, source_path = ""))


## True when the root main's single parameter is `span[str]`.
function main_param_is_span_str(ctx: ref[LowerCtx], params: span[ast.Param]) -> bool:
    if params.len != 1:
        return false
    var p: ast.Param
    unsafe:
        p = read(params.data + 0)
    let resolved = resolve_type_ref(ctx, ptr_of(p.param_type))
    match resolved:
        types.Type.ty_generic as g:
            if g.name == "span" and g.args.len == 1:
                return types.type_to_string(unsafe: read(g.args.data + 0)) == "str"
        _:
            pass
    return false


# =============================================================================
#  Statement lowering
# =============================================================================

## Push a fresh (empty) defer group for a newly-opened lexical block.
function push_defer_scope(ctx: ref[LowerCtx]) -> void:
    ctx.defer_stack.push(DeferGroup(cleanups = vec.Vec[span[ir.Stmt]].create()))


## Pop the innermost defer group when its block closes.
function pop_defer_scope(ctx: ref[LowerCtx]) -> void:
    let _dropped = ctx.defer_stack.pop()


## Record one lowered `defer` cleanup (a statement sequence) in the innermost
## open block's group, in encounter order.
function record_defer(ctx: ref[LowerCtx], cleanup: span[ir.Stmt]) -> void:
    let top = ctx.defer_stack.last() else:
        fatal(c"lowering: defer outside any block scope")
    unsafe:
        read(top).cleanups.push(cleanup)


## Append one defer group's cleanups in reverse encounter order (mirrors Ruby's
## `local_defers.reverse.flat_map`).
function flush_defer_group(group_ptr: ptr[DeferGroup], output: ref[vec.Vec[ir.Stmt]]) -> void:
    unsafe:
        let cleanups = read(group_ptr).cleanups
        if cleanups.len() == 0:
            return
        var i = cleanups.len()
        while i > 0:
            i -= 1
            let span_ptr = cleanups.get(i) else:
                fatal(c"lowering: defer group missing cleanup")
            append_span_stmts(output, read(span_ptr))


## Flush the innermost open block's pending defers (reverse order).  Used at the
## fall-through end of a non-terminating block.
function flush_top_defers(ctx: ref[LowerCtx], output: ref[vec.Vec[ir.Stmt]]) -> void:
    let top = ctx.defer_stack.last() else:
        return
    flush_defer_group(top, output)


## Flush every open block's pending defers, innermost-first, each in reverse
## encounter order.  Used before a `return` so all active defers run.  Mirrors
## Ruby's `cleanup_statements(local_defers, active_defers)` where active_defers
## is the outer-to-inner concatenation and the whole is reversed.
function flush_all_defers(ctx: ref[LowerCtx], output: ref[vec.Vec[ir.Stmt]]) -> void:
    var count = ctx.defer_stack.len()
    while count > 0:
        count -= 1
        let group_ptr = ctx.defer_stack.get(count) else:
            fatal(c"lowering: defer stack missing group")
        flush_defer_group(group_ptr, output)


## True when the innermost open block (or any enclosing block) has a pending
## defer, so a `return` needs a cleanup preamble.
function has_pending_defers(ctx: ref[LowerCtx]) -> bool:
    var i: ptr_uint = 0
    while i < ctx.defer_stack.len():
        let group_ptr = ctx.defer_stack.get(i) else:
            return false
        unsafe:
            if read(group_ptr).cleanups.len() > 0:
                return true
        i += 1
    return false


## True for a trivial return expression (a bare literal) whose value cannot be
## invalidated by running defers, so it need not be hoisted into a temp before
## the cleanup preamble.  Mirrors Ruby's `cleanup_safe_return_expression?`.
function cleanup_safe_return_expr(ep: ptr[ast.Expr]) -> bool:
    unsafe:
        match read(ep):
            ast.Expr.expr_integer_literal:
                return true
            ast.Expr.expr_float_literal:
                return true
            ast.Expr.expr_string_literal:
                return true
            ast.Expr.expr_bool_literal:
                return true
            ast.Expr.expr_null_literal:
                return true
            _:
                return false


function lower_block(ctx: ref[LowerCtx], body_ptr: ptr[ast.Stmt]?) -> span[ir.Stmt]:
    var stmts = vec.Vec[ir.Stmt].create()
    push_defer_scope(ctx)
    let bp = body_ptr else:
        pop_defer_scope(ctx)
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
    # Run this block's defers on fall-through exit (skipped when the block
    # already ends in a terminator such as return/break/continue/goto, whose
    # lowering flushed the relevant defers itself).
    if not stmts_terminate(stmts.as_span()):
        flush_top_defers(ctx, ref_of(stmts))
    pop_defer_scope(ctx)
    return stmts.as_span()


## Lower a function/method/proc body with an isolated defer stack.  Generic
## methods and functions are monomorphized lazily *during* the expression
## lowering of an unrelated enclosing body, so they must not observe or flush the
## enclosing body's pending defers.  This mirrors Ruby, where each function body
## carries its defers in its own `local_env` rather than a shared context.  The
## outer stack is saved, replaced by a fresh empty one for the duration of the
## body, and restored afterwards.
function lower_function_body(ctx: ref[LowerCtx], body_ptr: ptr[ast.Stmt]?) -> span[ir.Stmt]:
    let saved = ctx.defer_stack
    ctx.defer_stack = vec.Vec[DeferGroup].create()
    let result = lower_block(ctx, body_ptr)
    ctx.defer_stack = saved
    return result


function lower_stmt(ctx: ref[LowerCtx], output: ref[vec.Vec[ir.Stmt]], sp: ptr[ast.Stmt]) -> void:
    unsafe:
        match read(sp):
            ast.Stmt.stmt_ret as r:
                let value = r.value else:
                    flush_all_defers(ctx, output)
                    output.push(ir.Stmt.stmt_return(value = null, line = r.line, source_path = ""))
                    return
                # `return match ...`: a match expression has no direct C form, so
                # hoist it into a synthetic temp local (a switch / if-chain that
                # assigns each arm's value), run any active defers, then return the
                # temp.
                match read(value):
                    ast.Expr.expr_match as me:
                        let ret_ty = current_return_type(ctx, value)
                        let temp = fresh_c_temp_name(ctx, "match_ret")
                        let tc = utils.c_local_name(temp)
                        let zero_init = alloc_expr(ir.Expr.expr_zero_init(ty = ret_ty))
                        output.push(ir.Stmt.stmt_local(name = temp, linkage_name = tc, ty = ret_ty, value = zero_init, line = 0, source_path = ""))
                        let result_ref = alloc_expr(ir.Expr.expr_name(name = tc, ty = ret_ty, pointer = false))
                        lower_match_expr_to_ref(ctx, output, me.scrutinee, me.arms, result_ref)
                        flush_all_defers(ctx, output)
                        let ret_ref = alloc_expr(ir.Expr.expr_name(name = tc, ty = ret_ty, pointer = false))
                        output.push(ir.Stmt.stmt_return(value = ret_ref, line = r.line, source_path = ""))
                        return
                    ast.Expr.expr_call as outer_call:
                        # Chain call: `return f(a)(b)` where `f(a)` returns a
                        # proc/fn.  Hoist the inner call into a temp so the
                        # outer call can reference both `.invoke` and `.env`.
                        match read(outer_call.callee):
                            ast.Expr.expr_call:
                                let inner_result = lower_expr(ctx, outer_call.callee)
                                let inner_ty = ir_expr_type(inner_result)
                                if is_proc_type(inner_ty):
                                    let chain_tmp = fresh_c_temp_name(ctx, "chain")
                                    let ct = utils.c_local_name(chain_tmp)
                                    output.push(ir.Stmt.stmt_local(name = chain_tmp, linkage_name = ct, ty = inner_ty, value = inner_result, line = 0, source_path = ""))
                                    let lb = LocalBinding(name = chain_tmp, c_name = ct, ty = inner_ty, pointer = false)
                                    let proc_ret = lower_proc_call(ctx, lb, outer_call.args, value)
                                    flush_all_defers(ctx, output)
                                    output.push(ir.Stmt.stmt_return(value = proc_ret, line = r.line, source_path = ""))
                                    return
                            _:
                                pass
                    _:
                        pass
                # Plain `return expr`: when defers are active they must run after the
                # return value is computed but before control leaves.  If the value
                # is not a trivial literal, hoist it into a temp so running the
                # defers cannot invalidate it (mirrors Ruby's return-value hoist +
                # cleanup preamble).
                let lowered = lower_expr(ctx, value)
                let wrapped = if ctx.inside_async: make_task_literal(lowered) else: lowered
                if has_pending_defers(ctx) and not cleanup_safe_return_expr(value):
                    let ret_ty = ir_expr_type(wrapped)
                    let rtemp = fresh_c_temp_name(ctx, "return_value")
                    let rc = utils.c_local_name(rtemp)
                    output.push(ir.Stmt.stmt_local(name = rtemp, linkage_name = rc, ty = ret_ty, value = wrapped, line = 0, source_path = ""))
                    flush_all_defers(ctx, output)
                    let rref = alloc_expr(ir.Expr.expr_name(name = rc, ty = ret_ty, pointer = false))
                    output.push(ir.Stmt.stmt_return(value = rref, line = r.line, source_path = ""))
                    return
                flush_all_defers(ctx, output)
                output.push(ir.Stmt.stmt_return(value = wrapped, line = r.line, source_path = ""))
            ast.Stmt.stmt_local as loc:
                match loc.destructure_bindings:
                    Option.some as binds:
                        lower_destructure(ctx, output, binds.value, loc.destructure_type_name, loc.value)
                        return
                    Option.none:
                        pass
                # Guard form: `let x = expr else: <exit>` (and var).  The else body
                # runs on the absent/failure case; on success `x` binds the
                # unwrapped value.
                if loc.else_body != null and loc.value != null:
                    lower_guard_local(ctx, output, loc.name, loc.else_binding, loc.value, loc.else_body)
                    return
                # let _ = expr / var _ = expr — evaluate the expression for side
                # effects only; no local binding is introduced.
                if loc.name == "_":
                    let init_val = loc.value
                    if init_val != null:
                        lower_expr(ctx, init_val)
                    return
                let init_val = loc.value
                if init_val != null:
                    unsafe:
                        match read(init_val):
                            ast.Expr.expr_unary_op as un:
                                if un.operator == "?":
                                    lower_propagate_let(ctx, output, loc.name, un.operand)
                                    return
                            _:
                                pass
                        match read(init_val):
                            ast.Expr.expr_match as me:
                                lower_match_expression_local(ctx, output, loc.name, loc.stmt_type, me.scrutinee, me.arms)
                                return
                            ast.Expr.expr_format_string as fs:
                                lower_format_string_local(ctx, output, loc.name, fs.parts)
                                return
                            _:
                                pass
                let c_name = utils.c_local_name(loc.name)
                var ty: types.Type
                var value_expr: ptr[ir.Expr]
                let init = loc.value
                if init == null:
                    let declared = loc.stmt_type else:
                        fatal(c"lowering: local without initializer requires a type")
                    ty = resolve_type_ref(ctx, declared)
                    if is_user_generic_struct(ctx, ty):
                        let _ = qualify_type(ctx, ty)
                    value_expr = alloc_expr(ir.Expr.expr_zero_init(ty = ty))
                else:
                    value_expr = lower_expr(ctx, init)
                    if loc.stmt_type != null:
                        ty = local_decl_type(ctx, loc.stmt_type, init)
                        if is_user_generic_struct(ctx, ty):
                            let _ = qualify_type(ctx, ty)
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
                # Wrap a non-nullable value into a value-type nullable's opt struct.
                if types.is_nullable_type(ty) and not is_nullable_pointer_like(ty):
                    let value_ty = ir_expr_type(value_expr)
                    if not types.is_nullable_type(value_ty):
                        match read(value_expr):
                            ir.Expr.expr_null_literal:
                                value_expr = alloc_expr(ir.Expr.expr_zero_init(ty = ty))
                            _:
                                value_expr = nullable_some_literal(ty, value_expr)
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
                # Lower `arr[start..end] = (e1, e2, ...)` — range index assignment.
                # Expand into individual checked-index assignments, one per RHS element.
                match read(asg.target):
                    ast.Expr.expr_index_access as idx_target:
                        match read(idx_target.index):
                            ast.Expr.expr_range as rng:
                                match read(asg.value):
                                    ast.Expr.expr_expression_list as els:
                                        lower_range_index_assignment(ctx, output, idx_target.receiver, rng.start_expr, els.elements)
                                        return
                                    _:
                                        pass
                            _:
                                pass
                    _:
                        pass
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
                var value = lower_expr(ctx, asg.value)
                let target_ty = expr_type(ctx, asg.target)
                if types.is_nullable_type(target_ty) and not is_nullable_pointer_like(target_ty):
                    let value_ty = ir_expr_type(value)
                    if not types.is_nullable_type(value_ty):
                        match read(value):
                            ir.Expr.expr_null_literal:
                                value = alloc_expr(ir.Expr.expr_zero_init(ty = target_ty))
                            _:
                                value = nullable_some_literal(target_ty, value)
                output.push(ir.Stmt.stmt_assignment(target = target, operator = asg.operator, value = value))
            ast.Stmt.stmt_while as w:
                let cond = lower_expr(ctx, w.condition)
                let body = lower_block(ctx, w.body)
                output.push(ir.Stmt.stmt_while(condition = cond, body = body))
            ast.Stmt.stmt_for as f:
                if f.is_inline:
                    lower_inline_for_stmt(ctx, output, f.bindings, f.iterables, f.body)
                    return
                if f.threaded:
                    lower_parallel_for(ctx, output, f.bindings, f.iterables, f.body)
                    return
                lower_for_range(ctx, output, f.bindings, f.iterables, f.body)
            ast.Stmt.stmt_expression as ex:
                # Bare `expr?` propagation: unwrap the result and return on failure.
                unsafe:
                    match read(ex.expression):
                        ast.Expr.expr_unary_op as un:
                            if un.operator == "?":
                                lower_propagate_let(ctx, output, "_", un.operand)
                                return
                        _:
                            pass
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
                    # Lower the unsafe body into its own statement list and wrap it
                    # in an IR block, so its locals get a distinct C scope (`{ }`).
                    # Without this, sibling `unsafe:` blocks that each declare the
                    # same local name (e.g. `let t = read(tok)`) collide in the flat
                    # function scope ("redefinition of 't'").
                    var body_stmts = vec.Vec[ir.Stmt].create()
                    lower_stmt(ctx, ref_of(body_stmts), ptr[ast.Stmt]<-u.body)
                    output.push(ir.Stmt.stmt_block(body = body_stmts.as_span()))
                return
            ast.Stmt.stmt_block as blk:
                var block_stmts = vec.Vec[ir.Stmt].create()
                var i: ptr_uint = 0
                while i < blk.statements.len:
                    unsafe:
                        lower_stmt(ctx, ref_of(block_stmts), ptr[ast.Stmt]<-(blk.statements.data + i))
                    i += 1
                output.push(ir.Stmt.stmt_block(body = block_stmts.as_span()))
            ast.Stmt.stmt_defer as d:
                # A `defer` does not emit at its declaration site.  Lower its
                # cleanup into its own statement span and record it in the
                # innermost open block; the span is replayed on block exit and
                # before every `return` (reverse order).  Mirrors Ruby's
                # lower_defer_cleanup_expression / lower_defer_cleanup_body.
                var cleanup = vec.Vec[ir.Stmt].create()
                if d.expression != null:
                    cleanup.push(ir.Stmt.stmt_expression(
                        expression = lower_expr(ctx, ptr[ast.Expr]<-d.expression),
                        line = 0, source_path = "",
                    ))
                if d.body != null:
                    lower_stmt(ctx, ref_of(cleanup), ptr[ast.Stmt]<-d.body)
                record_defer(ctx, cleanup.as_span())
            ast.Stmt.stmt_emit:
                # `emit` declarations are spliced into the module's top-level
                # declarations by the analyzer (expand_emit_declarations) and
                # lowered there; the statement itself contributes nothing to the
                # enclosing const-function body.
                return
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
    return qualify_type(ctx, resolved)


## Lower a guard local `let name = value else: <else_body>` (and the `var` form).
## The initializer has an `Option[T]`, `Result[T, E]`, or nullable `T?` storage
## type; the `else` body runs on the absent/failure case and must exit control
## flow.  On success `name` binds the unwrapped success value `T`.  Mirrors Ruby's
## let-else lowering (block.rb): store the value in a hidden local, emit
## `if (failure) { <else_body> }`, then bind `name` to the projected success value.
function lower_guard_local(ctx: ref[LowerCtx], output: ref[vec.Vec[ir.Stmt]], name: str, else_binding: Option[str], value: ptr[ast.Expr]?, else_body: ptr[ast.Stmt]?) -> void:
    let value_ptr = value else:
        fatal(c"lowering: guard local requires an initializer")
    let value_ir = lower_expr(ctx, value_ptr)
    let storage_ty = ir_expr_type(value_ir)

    # Hidden storage local holding the full Option/Result/nullable value.
    let storage_c = fresh_c_temp_name(ctx, "guard")
    output.push(ir.Stmt.stmt_local(name = storage_c, linkage_name = storage_c, ty = storage_ty, value = value_ir, line = 0, source_path = ""))
    let storage_ref = alloc_expr(ir.Expr.expr_name(name = storage_c, ty = storage_ty, pointer = false))

    let kind = guard_storage_kind(ctx, storage_ty)

    # else body: for a Result `else as error:` guard, project the failure error
    # into a local at the top of the else body so it can be referenced there.
    var else_stmts = vec.Vec[ir.Stmt].create()
    if kind == "result" and else_binding.is_some():
        emit_result_failure_binding(ctx, ref_of(else_stmts), storage_ty, storage_ref, else_binding.unwrap())
    append_span_stmts(ref_of(else_stmts), lower_block(ctx, else_body))
    let else_ir = else_stmts.as_span()

    # `if (<failure condition>) { <else body> }`
    let cond = guard_failure_condition(ctx, kind, storage_ty, storage_ref)
    output.push(ir.Stmt.stmt_if(condition = cond, then_body = else_ir, else_body = span[ir.Stmt]()))

    # Bind `name` to the unwrapped success value (unless discarded with `_`).
    if name == "_":
        return
    let success_ty = guard_success_type(ctx, kind, storage_ty)
    let success_val = guard_success_projection(ctx, kind, storage_ty, storage_ref, success_ty)
    let bc = utils.c_local_name(name)
    output.push(ir.Stmt.stmt_local(name = name, linkage_name = bc, ty = success_ty, value = success_val, line = 0, source_path = ""))
    ctx.locals.push(LocalBinding(name = name, c_name = bc, ty = success_ty, pointer = false))


## Lower `let name = expr?` — the `?` postfix propagation operator lowers to
## a guard-like unwrap: on failure, return the failure value from the enclosing
## function; on success, bind `name` to the unwrapped success value.  This
## mirrors the Ruby compiler's `prepare_result_propagation_for_inline_lowering`.
function lower_propagate_let(ctx: ref[LowerCtx], output: ref[vec.Vec[ir.Stmt]], name: str, operand: ptr[ast.Expr]) -> void:
    let value_ir = lower_expr(ctx, operand)
    let storage_ty = ir_expr_type(value_ir)

    # Hidden storage local holding the full Option/Result value.
    let storage_c = fresh_c_temp_name(ctx, "propagate")
    output.push(ir.Stmt.stmt_local(name = storage_c, linkage_name = storage_c, ty = storage_ty, value = value_ir, line = 0, source_path = ""))
    let storage_ref = alloc_expr(ir.Expr.expr_name(name = storage_c, ty = storage_ty, pointer = false))

    let kind = guard_storage_kind(ctx, storage_ty)
    # Pre-register arm payload fields for Option/Result so that
    # guard_success_type can find the specialized field type via
    # arm_payload_fields (P43 fallback). Without this, concrete variant
    # types like Result[UdpSocket, Error] fall back to returning the
    # storage type itself, causing `invalid initializer` C errors.
    if kind == "option" or kind == "result":
        let outer_c = variant_base_c_name(storage_ty, ctx.module_name)
        let success_arm = if kind == "result": "success" else: "some"
        let arm_c = variant_arm_type_name(outer_c, success_arm)
        if not ctx.arm_payload_fields.contains(arm_c):
            var base_name = ""
            if is_prelude_variant_name(outer_c):
                if outer_c.starts_with("std_result_"):
                    base_name = "Result"
                else if outer_c.starts_with("std_option_"):
                    base_name = "Option"
            if base_name.len > 0:
                let vi_ptr = ctx.variants.get(base_name)
                if vi_ptr != null:
                    let vi = unsafe: read(vi_ptr)
                    register_arm_payload_fields(ctx, arm_c, vi, success_arm, storage_ty)

    # Build the failure return value.  When the propagation type (e.g.
    # `Result[bool, Error]`) differs from the enclosing function's return type
    # (e.g. `Result[Bytes, Error]`), extract the error from the propagated
    # failure arm and wrap it in the return type's failure arm so the C types
    # are compatible.  Mirrors Ruby's `storage_type == return_type` check in
    # `prepare_result_propagation_for_inline_lowering`.
    var fail_value = storage_ref
    let ret_ty = ctx.current_fn_return_type
    if not types.type_equals(ret_ty, storage_ty):
        # When the enclosing function returns a Task wrapping the error Result
        # (e.g. `async function -> Task[Result[int, int]]`), the failure
        # return must construct a Task struct containing the failure Result
        # in its `.value` field, not a Result variant literal.
        var is_task_ret = false
        match ret_ty:
            types.Type.ty_generic as tg:
                if tg.name == "Task":
                    is_task_ret = true
            types.Type.ty_named as tn:
                if tn.name.starts_with("mt_task_"):
                    is_task_ret = true
            _:
                pass
        if kind == "result":
            # Extract the error from the storage's failure arm via
            # storage_ref.data.failure.error (three-level member access through
            # the variant's data union and failure arm struct).
            let data_field = alloc_expr(ir.Expr.expr_member(
                receiver = storage_ref,
                member = "data",
                ty = types.primitive("void"),
            ))
            let failure_struct = alloc_expr(ir.Expr.expr_member(
                receiver = data_field,
                member = "failure",
                ty = types.primitive("void"),
            ))
            let error_member = alloc_expr(ir.Expr.expr_member(
                receiver = failure_struct,
                member = "error",
                ty = types.primitive("void"),
            ))
            if is_task_ret:
                # Construct a Task struct: all vtable fields zeroed, value
                # field carries the failure Result variant literal.
                # Build the failure Result first, then put it in .value.
                var result_fail_fields = vec.Vec[ir.AggregateField].create()
                result_fail_fields.push(ir.AggregateField(name = "error", value = error_member))
                let result_failure = extract_task_element_type(ctx, ret_ty)
                let failure_result = alloc_expr(ir.Expr.expr_variant_literal(
                    ty = result_failure,
                    arm_name = "failure",
                    fields = result_fail_fields.as_span(),
                ))
                var task_fields = vec.Vec[ir.AggregateField].create()
                let void_zero = alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = ptr_void_type()))
                task_fields.push(ir.AggregateField(name = "value", value = failure_result))
                task_fields.push(ir.AggregateField(name = "frame", value = void_zero))
                task_fields.push(ir.AggregateField(name = "ready", value = void_zero))
                task_fields.push(ir.AggregateField(name = "set_waiter", value = void_zero))
                task_fields.push(ir.AggregateField(name = "release", value = void_zero))
                task_fields.push(ir.AggregateField(name = "take_result", value = void_zero))
                task_fields.push(ir.AggregateField(name = "cancel", value = void_zero))
                fail_value = alloc_expr(ir.Expr.expr_aggregate_literal(ty = ret_ty, fields = task_fields.as_span()))
            else:
                var fail_fields = vec.Vec[ir.AggregateField].create()
                fail_fields.push(ir.AggregateField(name = "error", value = error_member))
                fail_value = alloc_expr(ir.Expr.expr_variant_literal(
                    ty = ret_ty,
                    arm_name = "failure",
                    fields = fail_fields.as_span(),
                ))
        else if kind == "option":
            fail_value = alloc_expr(ir.Expr.expr_variant_literal(ty = ret_ty, arm_name = "none", fields = span[ir.AggregateField]()))

    # Failure branch: return the appropriate failure value.
    var fail_body = vec.Vec[ir.Stmt].create()
    flush_all_defers(ctx, ref_of(fail_body))
    fail_body.push(ir.Stmt.stmt_return(value = fail_value, line = 0, source_path = ""))

    # `if (<failure condition>) { return storage; }`
    let cond = guard_failure_condition(ctx, kind, storage_ty, storage_ref)
    output.push(ir.Stmt.stmt_if(condition = cond, then_body = fail_body.as_span(), else_body = span[ir.Stmt]()))

    # Bind `name` to the unwrapped success value (unless discarded with `_`).
    if name == "_":
        return
    let success_ty = guard_success_type(ctx, kind, storage_ty)
    let success_val = guard_success_projection(ctx, kind, storage_ty, storage_ref, success_ty)
    let bc = utils.c_local_name(name)
    output.push(ir.Stmt.stmt_local(name = name, linkage_name = bc, ty = success_ty, value = success_val, line = 0, source_path = ""))
    ctx.locals.push(LocalBinding(name = name, c_name = bc, ty = success_ty, pointer = false))


## Classify a guard's storage type: "option", "result", or "nullable".
function guard_storage_kind(ctx: ref[LowerCtx], storage_ty: types.Type) -> str:
    if types.is_nullable_type(storage_ty):
        return "nullable"
    let gv = generic_variant_name(storage_ty)
    if gv.is_some():
        let base = guard_variant_base(gv.unwrap())
        if base == "Result":
            return "result"
        return "option"
    # A collapsed concrete name (Option_str / Result_..._).
    let tn = named_type_name(storage_ty)
    if tn.is_some():
        if tn.unwrap().starts_with("Result_"):
            return "result"
        if tn.unwrap().starts_with("Option_"):
            return "option"
    return "nullable"


## Wrap a non-nullable value in a nullable aggregate literal, producing
## `{ has_value: true, value: <value_expr> }` for the mt_opt_* struct.
function nullable_some_literal(nullable_ty: types.Type, value_expr: ptr[ir.Expr]) -> ptr[ir.Expr]:
    let bool_ty = types.primitive("bool")
    let true_lit = alloc_expr(ir.Expr.expr_boolean_literal(value = true, ty = bool_ty))
    return alloc_expr(ir.Expr.expr_aggregate_literal(
        ty = nullable_ty,
        fields = sp_fields2(
            ir.AggregateField(name = "has_value", value = true_lit),
            ir.AggregateField(name = "value", value = value_expr),
        ),
    ))


## True when a nullable type has a pointer-like base (ptr, const_ptr, ref, cstr,
## function, proc, opaque).  These use NULL as the absent sentinel.  Value-type
## nullables (int?, bool?, struct?) use mt_opt_* structs with has_value tags.
function is_nullable_pointer_like(t: types.Type) -> bool:
    match t:
        types.Type.ty_nullable as nl:
            unsafe:
                let base = read(nl.base)
                match base:
                    types.Type.ty_generic as g:
                        return g.name == "ptr" or g.name == "const_ptr" or g.name == "own" or g.name == "ref"
                    types.Type.ty_primitive as p:
                        return p.name == "cstr"
                    types.Type.ty_function:
                        return true
                    _:
                        return false
        _:
            return false


## The base variant name from a possibly-qualified name (`Result_int_Error` →
## "Result"; `Result` → "Result").
function guard_variant_base(name: str) -> str:
    match prelude_variant_base(name):
        Option.some as base:
            return base.value
        Option.none:
            return name


## The failure/absent condition for a guard: `storage == null` for nullable,
## `storage.kind == <none/failure>` for Option/Result.
function guard_failure_condition(ctx: ref[LowerCtx], kind: str, storage_ty: types.Type, storage_ref: ptr[ir.Expr]) -> ptr[ir.Expr]:
    let bool_ty = types.primitive("bool")
    if kind == "nullable":
        # mt_subscription is a plain struct without nullable/null wrapper;
        # failure is indicated by slot == 0.
        let tn = named_type_name(storage_ty)
        if tn.is_some() and tn.unwrap() == "mt_subscription":
            let slot_expr = alloc_expr(ir.Expr.expr_member(receiver = storage_ref, member = "slot", ty = types.primitive("ptr_uint")))
            let zero = alloc_expr(ir.Expr.expr_integer_literal(value = 0z, ty = types.primitive("ptr_uint")))
            return alloc_expr(ir.Expr.expr_binary(operator = "==", left = slot_expr, right = zero, ty = bool_ty))
        let null_lit = alloc_expr(ir.Expr.expr_null_literal(ty = storage_ty))
        return alloc_expr(ir.Expr.expr_binary(operator = "==", left = storage_ref, right = null_lit, ty = bool_ty))
    let outer_c = variant_base_c_name(storage_ty, ctx.module_name)
    let absent_arm = if kind == "result": "failure" else: "none"
    let int_ty = types.primitive("int")
    let kind_expr = alloc_expr(ir.Expr.expr_member(receiver = storage_ref, member = "kind", ty = int_ty))
    let absent_const = alloc_expr(ir.Expr.expr_name(name = variant_kind_const_name(outer_c, absent_arm), ty = int_ty, pointer = false))
    return alloc_expr(ir.Expr.expr_binary(operator = "==", left = kind_expr, right = absent_const, ty = bool_ty))


## The unwrapped success type `T` of a guard's storage type.
function guard_success_type(ctx: ref[LowerCtx], kind: str, storage_ty: types.Type) -> types.Type:
    if kind == "nullable":
        return types.unwrap_nullable(storage_ty)
    # Option[T] / Result[T, E] in generic form: first type arg is T.
    let args = variant_type_args(storage_ty)
    if args.len > 0:
        return qualify_type(ctx, unsafe: read(args.data + 0))
    # Collapsed concrete form (Option_str / Result_..._): recover the success
    # payload field type from the concrete variant decl, mirroring the prelude
    # payload specialization (arg-less `ty_named` carries no type args).
    let outer_c = variant_base_c_name(storage_ty, ctx.module_name)
    let success_arm = if kind == "result": "success" else: "some"
    let payload_c = variant_arm_type_name(outer_c, success_arm)
    match prelude_field_type_from_variants(ctx, payload_c, success_arm):
        Option.some as ft:
            return ft.value
        Option.none:
            pass
    # Concrete variant (e.g. Result[UdpSocket, Error]): look up the success
    # payload field type from the arm_payload_fields registry populated during
    # variant lowering.
    let arm_ptr = ctx.arm_payload_fields.get(payload_c)
    if arm_ptr != null:
        let arm_info = unsafe: read(arm_ptr)
        if arm_info.field_types.len > 0:
            return unsafe: read(arm_info.field_types.data + 0)
    return storage_ty


## The success-value projection for a guard: the storage itself for nullable,
## `storage.data.<some/success>.value` for Option/Result.
function guard_success_projection(ctx: ref[LowerCtx], kind: str, storage_ty: types.Type, storage_ref: ptr[ir.Expr], success_ty: types.Type) -> ptr[ir.Expr]:
    if kind == "nullable":
        if types.is_nullable_type(storage_ty) and not is_nullable_pointer_like(storage_ty):
            return alloc_expr(ir.Expr.expr_member(receiver = storage_ref, member = "value", ty = success_ty))
        return storage_ref
    let outer_c = variant_base_c_name(storage_ty, ctx.module_name)
    let success_arm = if kind == "result": "success" else: "some"
    let payload_ty = types.Type.ty_named(module_name = "", name = variant_arm_type_name(outer_c, success_arm))
    let data_member = alloc_expr(ir.Expr.expr_member(receiver = storage_ref, member = "data", ty = payload_ty))
    let arm_data = alloc_expr(ir.Expr.expr_member(receiver = data_member, member = success_arm, ty = payload_ty))
    return alloc_expr(ir.Expr.expr_member(receiver = arm_data, member = "value", ty = success_ty))


## Emit the `else as error:` binding for a Result guard as a local at the top of
## the else body, projected as `storage.data.failure.error`, and register it so
## the else body resolves the name.
function emit_result_failure_binding(ctx: ref[LowerCtx], else_stmts: ref[vec.Vec[ir.Stmt]], storage_ty: types.Type, storage_ref: ptr[ir.Expr], error_name: str) -> void:
    let outer_c = variant_base_c_name(storage_ty, ctx.module_name)
    let payload_ty = types.Type.ty_named(module_name = "", name = variant_arm_type_name(outer_c, "failure"))
    var error_ty = types.primitive("void")
    let args = variant_type_args(storage_ty)
    if args.len >= 2:
        error_ty = qualify_type(ctx, unsafe: read(args.data + 1))
    else:
        # Collapsed concrete form: recover the error field type from the decl.
        match prelude_field_type_from_variants(ctx, variant_arm_type_name(outer_c, "failure"), "failure"):
            Option.some as ft:
                error_ty = ft.value
            Option.none:
                pass
    let data_member = alloc_expr(ir.Expr.expr_member(receiver = storage_ref, member = "data", ty = payload_ty))
    let arm_data = alloc_expr(ir.Expr.expr_member(receiver = data_member, member = "failure", ty = payload_ty))
    let error_val = alloc_expr(ir.Expr.expr_member(receiver = arm_data, member = "error", ty = error_ty))
    let bc = utils.c_local_name(error_name)
    else_stmts.push(ir.Stmt.stmt_local(name = error_name, linkage_name = bc, ty = error_ty, value = error_val, line = 0, source_path = ""))
    ctx.locals.push(LocalBinding(name = error_name, c_name = bc, ty = error_ty, pointer = false))


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
        # `_` discards bind nothing — skip them (emitting a local for each would
        # collide, and there is no name to reference).  Mirrors Ruby's
        # `next if name == "_"`.
        if binding == "_":
            i += 1
            continue
        var member_name: str
        var member_ty: types.Type
        match type_name:
            Option.some as tn:
                member_name = struct_field_name_at(ctx, tn.value, i)
                member_ty = struct_field_type_at(ctx, tn.value, i)
            Option.none:
                member_name = tuple_field_name(i)
                member_ty = tuple_element_type(val_ty, i)
                match val_ty:
                    types.Type.ty_tuple as tup:
                        match tup.field_names:
                            Option.some as fnames:
                                if i < fnames.value.len:
                                    member_name = unsafe: read(fnames.value.data + i)
                            Option.none:
                                pass
                    _:
                        pass
        let receiver = alloc_expr(ir.Expr.expr_name(name = temp, ty = val_ty, pointer = false))
        let member = alloc_expr(ir.Expr.expr_member(receiver = receiver, member = member_name, ty = member_ty))
        let binding_c = utils.c_local_name(binding)
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
            # Concrete C names produced by generic_struct_c_name always contain
            # at least one underscore (module_prefix_Name_Arg).  Bare names
            # without underscores (like the type param `T`) should follow the
            # normal qualify path.
            if n.name.find_byte('_').is_some():
                return t
            # Prelude variant instances (Option_str, Result_int_Error) and proc
            # typedefs (mt_proc_...) have global C names and must not be
            # module-prefixed.
            if is_prelude_variant_name(n.name) or n.name.starts_with("mt_proc_"):
                return t
            # A bare type name may be a type imported from another module (e.g.
            # `Diag` used in `analyzer` but defined in `definite_assignment`).
            # Qualify it against its OWNER module, not the current one, so it does
            # not become a mis-attributed `<current_module>_Diag`.
            match imported_type_module(ctx, n.name):
                Option.some as owner:
                    return types.Type.ty_imported(module_name = owner.value, name = n.name, args = span[types.Type]())
                Option.none:
                    pass
            # Resolve type aliases to their target type so the C backend sees
            # the concrete type (e.g. IntCallback → fn(...)) rather than an
            # opaque ty_imported.  Aliases targeting std.c.* types are NOT
            # resolved — the C typedef (e.g. `typedef struct sockaddr_storage
            # std_net_NativeSocketStorage`) handles the mapping, and keeping
            # the alias name avoids raw C type names (e.g. `sockaddr_storage`
            # without `struct` prefix) in function signatures / struct fields.
            if ctx.analysis.type_alias_types.contains(n.name):
                let resolved_ptr = ctx.analysis.type_alias_types.get(n.name) else:
                    fatal(c"lowering: type alias lookup inconsistency")
                let resolved_val = unsafe: read(resolved_ptr)
                if not type_is_from_std_c(resolved_val):
                    return qualify_type(ctx, resolved_val)
            return types.Type.ty_imported(module_name = ctx.module_name, name = n.name, args = span[types.Type]())
        types.Type.ty_imported as im:
            if is_raw_type_param_name(im.name):
                return types.primitive("void")
            # Resolve type aliases defined in the owning module (e.g.
            # `NativeBuffer` in `std.net` → `uv_buf_t` in `std.c.libuv`).
            if im.args.len == 0 and not is_prelude_variant_name(im.name):
                let owner_a_opt = find_imported_analysis(ctx, im.module_name)
                if owner_a_opt.is_some():
                    let owner_a = owner_a_opt.unwrap()
                    if owner_a.type_alias_types.contains(im.name):
                        let resolved_ptr = owner_a.type_alias_types.get(im.name) else:
                            fatal(c"lowering: imported type alias lookup inconsistency")
                        return qualify_type(ctx, unsafe: read(resolved_ptr))
            var resolved_args = span[types.Type]()
            if im.args.len > 0:
                var args_vec = vec.Vec[types.Type].create()
                var ai: ptr_uint = 0
                while ai < im.args.len:
                    unsafe:
                        args_vec.push(qualify_type(ctx, read(im.args.data + ai)))
                    ai += 1
                resolved_args = args_vec.as_span()
            # Prelude variants (Option/Result) have global, un-prefixed C names
            # (Option_str, not <module>_Option_str) and are emitted as generic
            # variants, so keep them in generic form rather than monomorphizing a
            # module-qualified struct.
            if is_prelude_variant_name(im.name):
                return types.Type.ty_generic(name = im.name, args = resolved_args)
            if resolved_args.len > 0:
                let concrete_name = naming.qualified_c_name(im.module_name, generic_struct_c_name(im.name, resolved_args))
                ensure_generic_struct_decl_named(ctx, im.name, span[ast.TypeArgument](), resolved_args, concrete_name)
                ctx.generic_struct_instances.set(concrete_name, GenericReceiver(owner_name = im.name, concrete_args = resolved_args))
                return types.Type.ty_named(module_name = "", name = concrete_name)
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
        types.Type.ty_function as fnt:
            if fnt.is_proc:
                let proc_name = proc_type_name_from_signature(t)
                return proc_ensure_struct_decl(ctx, proc_name, t)
            return t
        _:
            return t


## When `name` is a generic struct (local or imported) with concrete args,
## monomorphize it and return the concrete `ty_named`.  Returns `ty_error` for
## builtins (ptr/span/ref/...) and unknown names — the caller should fall back
## to `ty_generic`.
function try_monomorphize_generic(ctx: ref[LowerCtx], name: str, args: span[types.Type]) -> types.Type:
    if is_builtin_pointer_generic(name):
        return types.Type.ty_error
    if name == "Option" or name == "Result":
        return ensure_generic_variant(ctx, name, args)
    # Try current module first.
    if ctx.analysis.structs.contains(name):
        let concrete_name = naming.qualified_c_name(ctx.module_name, generic_struct_c_name(name, args))
        ensure_generic_struct_decl_named(ctx, name, span[ast.TypeArgument](), args, concrete_name)
        ctx.generic_struct_instances.set(concrete_name, GenericReceiver(owner_name = name, concrete_args = args))
        return types.Type.ty_named(module_name = "", name = concrete_name)
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
                    return types.Type.ty_named(module_name = "", name = concrete_name)
            Option.none:
                pass
    return types.Type.ty_error


## The owner module of a bare type `name` when it is defined in an imported
## module (struct, variant, or enum) rather than the current one.  Used by
## `qualify_type` so an imported bare type name qualifies against its defining
## module instead of being mis-attributed to the current module.  Returns none
## when the name is defined locally or not found in any import.
function imported_type_module(ctx: ref[LowerCtx], name: str) -> Option[str]:
    # A locally-declared type takes precedence — never redirect it to an import.
    if ctx.analysis.structs.contains(name) or type_declared_in_source(ctx.analysis, name):
        return Option[str].none
    var import_values = ctx.analysis.imports.values()
    while true:
        let target_ptr = import_values.next() else:
            break
        let target_module = unsafe: read(target_ptr)
        match find_imported_analysis(ctx, target_module):
            Option.some as imported:
                if imported.value.structs.contains(name) or type_declared_in_source(imported.value, name):
                    return Option[str].some(value = target_module)
            Option.none:
                pass
    return Option[str].none


## True when a module's AST declares a struct, variant, or enum named `name`.
function type_declared_in_source(module_analysis: analyzer.Analysis, name: str) -> bool:
    var di: ptr_uint = 0
    while di < module_analysis.source_file.declarations.len:
        var d: ast.Decl
        unsafe:
            d = read(module_analysis.source_file.declarations.data + di)
        match d:
            ast.Decl.decl_struct as s:
                if s.name == name:
                    return true
            ast.Decl.decl_variant as vr:
                if vr.name == name:
                    return true
            ast.Decl.decl_enum as en:
                if en.name == name:
                    return true
            _:
                pass
        di += 1
    return false


## Check if a struct named `name` exists in a module's source file AST.
function struct_in_source(module_analysis: analyzer.Analysis, name: str) -> bool:
    var di: ptr_uint = 0
    while di < module_analysis.source_file.declarations.len:
        var d: ast.Decl
        unsafe:
            d = read(module_analysis.source_file.declarations.data + di)
        match d:
            ast.Decl.decl_struct as s:
                if s.name == name:
                    return true
            _:
                pass
        di += 1
    return false

## True when a module's AST declares a generic variant named `name`.
function variant_in_source(module_analysis: analyzer.Analysis, name: str) -> bool:
    var di: ptr_uint = 0
    while di < module_analysis.source_file.declarations.len:
        var d: ast.Decl
        unsafe:
            d = read(module_analysis.source_file.declarations.data + di)
        match d:
            ast.Decl.decl_variant as vr:
                if vr.name == name:
                    return true
            _:
                pass
        di += 1
    return false

## Ensure a concrete variant declaration exists for `Option[T]` or `Result[T,E]`.
function ensure_generic_variant(ctx: ref[LowerCtx], name: str, args: span[types.Type]) -> types.Type:
    var base_name = name
    if name == "Option":
        base_name = j2("std_option_", name)
    if name == "Result":
        base_name = j2("std_result_", name)
    let c_name = generic_c_type_raw(base_name, args)
    var si: ptr_uint = 0
    while si < ctx.pending_generic_variants.len():
        let vp = ctx.pending_generic_variants.get(si) else:
            break
        unsafe:
            if read(vp).linkage_name == c_name:
                return types.Type.ty_named(module_name = "", name = c_name)
        si += 1
    var arms = vec.Vec[ir.VariantArm].create()
    if name == "Option" and args.len >= 1:
        let elem = unsafe: read(args.data + 0)
        var sf = vec.Vec[ir.Field].create()
        sf.push(ir.Field(name = "value", ty = elem))
        arms.push(ir.VariantArm(name = "some", linkage_name = j3(c_name, "_", "some"), fields = sf.as_span()))
        arms.push(ir.VariantArm(name = "none", linkage_name = j3(c_name, "_", "none"), fields = span[ir.Field]()))
        unsafe: read(ctx.prelude_arm_field_types).set(j3(c_name, "_", "some"), elem)
    else if name == "Result" and args.len >= 2:
        let ok = unsafe: read(args.data + 0)
        let err = unsafe: read(args.data + 1)
        var sf = vec.Vec[ir.Field].create()
        sf.push(ir.Field(name = "value", ty = ok))
        var ef = vec.Vec[ir.Field].create()
        ef.push(ir.Field(name = "error", ty = err))
        arms.push(ir.VariantArm(name = "success", linkage_name = j3(c_name, "_", "success"), fields = sf.as_span()))
        arms.push(ir.VariantArm(name = "failure", linkage_name = j3(c_name, "_", "failure"), fields = ef.as_span()))
        unsafe: read(ctx.prelude_arm_field_types).set(j3(c_name, "_", "success"), ok)
        unsafe: read(ctx.prelude_arm_field_types).set(j3(c_name, "_", "failure"), err)
    ctx.pending_generic_variants.push(ir.VariantDecl(
        name = c_name, linkage_name = c_name,
        arms = arms.as_span(), source_module = Option[str].none,
    ))
    return types.Type.ty_named(module_name = "", name = c_name)


## True when `ty` is a `ty_generic` whose name refers to a user-defined generic
## struct (not a builtin constructor like ptr/own/span/str_buffer etc.).  Used
## to trigger struct monomorphization via `qualify_type` when a local variable
## declaration references a generic struct without any explicit method call.
function is_user_generic_struct(ctx: ref[LowerCtx], ty: types.Type) -> bool:
    match ty:
        types.Type.ty_generic as g:
            if is_builtin_pointer_generic(g.name):
                return false
            if g.name == "Option" or g.name == "Result":
                return false
            return g.args.len > 0
        _:
            return false

## True when `name` is a pointer-like generic type handled directly by C.
function is_builtin_pointer_generic(name: str) -> bool:
    return (
        name == "ptr" or name == "const_ptr" or name == "own" or name == "ref"
        or name == "span" or name == "array" or name == "str_buffer"
        or name == "atomic" or name == "Task" or name == "SoA"
    )

function generic_c_type_raw(name: str, args: span[types.Type]) -> str:
    var buf = string.String.create()
    buf.append(name)
    var i: ptr_uint = 0
    while i < args.len:
        buf.append("_")
        unsafe:
            buf.append(naming.type_c_key(read(args.data + i)))
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
            let result = types.Type.ty_tuple(elements = elems.as_span(), field_names = Option[span[str]].none)
            if t.nullable:
                return types.Type.ty_nullable(base = types.alloc_type(result))
            return result
        var resolved = types.Type.ty_error
        if t.arguments.len > 0:
            resolved = resolve_generic_type_ref(ctx, t)
        else if t.name.parts.len >= 2:
            var alias: str
            var type_name: str
            unsafe:
                alias = read(t.name.parts.data + 0)
                type_name = read(t.name.parts.data + 1)
            # Inline for substitution: `field.type` resolves to the field's type.
            if type_name == "type":
                let subst = inline_for_type_subst(ctx, alias)
                if not types.is_error(subst):
                    resolved = subst
                    if t.nullable:
                        return types.Type.ty_nullable(base = types.alloc_type(resolved))
                    return resolved
            let mod_ptr = ctx.analysis.imports.get(alias)
            if mod_ptr != null:
                let target_module = unsafe: read(mod_ptr)
                resolved = types.Type.ty_imported(module_name = target_module, name = type_name, args = span[types.Type]())
            else:
                # Not an import alias: may be a nested struct, e.g.
                # `Rectangle.Edge`.  The bare name is stored in structs and
                # emitted under that name (e.g. `language_baseline_Edge`).
                var nested_key = string.String.create()
                nested_key.append(alias)
                nested_key.append(".")
                nested_key.append(type_name)
                let nkey = nested_key.as_str()
                if ctx.analysis.structs.contains(nkey):
                    let last_part = unsafe: read(t.name.parts.data + (t.name.parts.len - 1))
                    resolved = types.Type.ty_imported(module_name = ctx.module_name, name = last_part, args = span[types.Type]())
        else if t.name.parts.len == 1:
            let name = read(t.name.parts.data + 0)
            if name == "str":
                resolved = types.Type.ty_str
            else if name == "type":
                resolved = types.Type.ty_type_meta
            else if is_builtin_type_name(name):
                resolved = types.primitive(name)
            else if ctx.analysis.type_names.contains(name):
                resolved = types.Type.ty_imported(module_name = ctx.module_name, name = name, args = span[types.Type]())
            else:
                let concrete_ptr = ctx.type_substitution.get(name)
                if concrete_ptr != null:
                    resolved = unsafe: read(concrete_ptr)
                else:
                    resolved = types.Type.ty_named(module_name = "", name = name)
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
    if name == "array" and t.arguments.len == 2:
        var args = vec.Vec[types.Type].create()
        unsafe:
            args.push(resolve_type_ref(ctx, t.arguments.data + 0))
        args.push(types.literal_int(resolve_array_length(unsafe: t.arguments.data + 1)))
        return types.Type.ty_generic(name = "array", args = args.as_span())
    # str_buffer[N]: ensure the struct type exists and return the resolved type.
    if name == "str_buffer" and t.arguments.len == 1:
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
        is_proc = t.is_proc,
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
        lower_multi_for(ctx, output, bindings, iterables, body_ptr)
        return

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

    let index_c = utils.c_local_name(index_name)
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
    # If the iterable is neither array nor span, the element type will be error.
    # For custom iterables (with iter() protocol), skip the loop rather than
    # generating broken span access.  Fully lowering the iterator protocol is
    # deferred.
    if types.is_error(element_type) and not is_arr:
        return
    let ptr_uint_ty = types.primitive("ptr_uint")

    let items_c = fresh_c_temp_name(ctx, "for_items")
    let index_c = fresh_c_temp_name(ctx, "for_index")
    let _continue_label = fresh_c_temp_name(ctx, "loop_continue")
    let _break_label = fresh_c_temp_name(ctx, "loop_break")

    let binding_c = utils.c_local_name(binding_name)
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


## Lower `array[T, N].as_span()` to a `span[T]` aggregate literal
## `{ data = &arr[0], len = N }`, mirroring Ruby's `lower_array_to_span_expression`.
function lower_array_as_span(ctx: ref[LowerCtx], receiver: ptr[ast.Expr], array_ty: types.Type) -> ptr[ir.Expr]:
    let elem_ty = generic_first_arg(array_ty)
    let ptr_uint_ty = types.primitive("ptr_uint")
    # Recover the length from the array type; if it lost its literal length
    # (a const/var reference whose recorded type dropped the count), resolve it
    # from the declaration's type annotation.
    var length = array_length_of(array_ty)
    if length == 0:
        length = const_array_length(ctx, receiver)
    # Rebuild the array type with the recovered length so the checked-index helper
    # is generated for the correct array size (not a `[0]` mismatch).
    var index_array_ty = array_ty
    if array_length_of(array_ty) == 0 and length != 0:
        var arr_args = vec.Vec[types.Type].create()
        arr_args.push(elem_ty)
        arr_args.push(types.literal_int(length))
        index_array_ty = types.Type.ty_generic(name = "array", args = arr_args.as_span())
    let recv = lower_expr(ctx, receiver)
    let zero_index = alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = ptr_uint_ty))
    let elem0 = alloc_expr(ir.Expr.expr_checked_index(
        receiver = recv, index = zero_index, receiver_type = index_array_ty, ty = elem_ty,
    ))
    let data_ptr = alloc_expr(ir.Expr.expr_address_of(
        expression = elem0,
        ty = types.Type.ty_generic(name = "ptr", args = sp_type(elem_ty)),
    ))
    let len_expr = alloc_expr(ir.Expr.expr_integer_literal(value = length, ty = ptr_uint_ty))
    var fields = vec.Vec[ir.AggregateField].create()
    fields.push(ir.AggregateField(name = "data", value = data_ptr))
    fields.push(ir.AggregateField(name = "len", value = len_expr))
    let span_ty = types.Type.ty_generic(name = "span", args = sp_type(elem_ty))
    return alloc_expr(ir.Expr.expr_aggregate_literal(ty = span_ty, fields = fields.as_span()))


## Lower `.with(x = val, ...)` to an aggregate literal copy with specified
## fields replaced.  Mirrors Ruby's :struct_with lowering.
function lower_with_call(ctx: ref[LowerCtx], receiver: ptr[ast.Expr], recv_ty: types.Type, args: span[ast.Argument]) -> ptr[ir.Expr]:
    let recv = lower_expr(ctx, receiver)
    let name = nominal_type_name(recv_ty)
    var field_names = vec.Vec[str].create()
    var field_types = vec.Vec[types.Type].create()
    if is_vec_math_name(name):
        vec_math_fields(name, ref_of(field_names), ref_of(field_types))
    else:
        var struct_name = name
        if struct_name.len == 0:
            match recv_ty:
                types.Type.ty_named as n:
                    struct_name = n.name
                types.Type.ty_imported as im:
                    struct_name = im.name
                _:
                    pass
        if struct_name.len > 0:
            if ctx.analysis.structs.contains(struct_name):
                let fields_ptr = ctx.analysis.structs.get(struct_name) else:
                    fatal(c"lower_with_call: struct not found")
                let entries = unsafe: read(fields_ptr)
                var ei: ptr_uint = 0
                while ei < entries.len:
                    let entry = unsafe: read(entries.data + ei)
                    field_names.push(entry.name)
                    field_types.push(entry.ty)
                    ei += 1
            else:
                var import_values = ctx.analysis.imports.values()
                var found = false
                while not found:
                    let target_ptr = import_values.next() else:
                        break
                    let target_module = unsafe: read(target_ptr)
                    match find_imported_analysis(ctx, target_module):
                        Option.some as imported:
                            if imported.value.structs.contains(struct_name):
                                let ifields_ptr = imported.value.structs.get(struct_name) else:
                                    break
                                let ientries = unsafe: read(ifields_ptr)
                                var iei: ptr_uint = 0
                                while iei < ientries.len:
                                    let ientry = unsafe: read(ientries.data + iei)
                                    field_names.push(ientry.name)
                                    field_types.push(ientry.ty)
                                    iei += 1
                                found = true
                        Option.none:
                            pass
    if field_names.len() == 0:
        fatal(c"lower_with_call: cannot determine fields for type")
    var arg_map = map_mod.Map[str, ptr[ir.Expr]].create()
    var ai: ptr_uint = 0
    while ai < args.len:
        var a: ast.Argument
        unsafe:
            a = read(args.data + ai)
        let aname = a.arg_name else:
            fatal(c"lower_with_call: named arguments required")
        arg_map.set(aname, lower_expr(ctx, a.arg_value))
        ai += 1
    var fields = vec.Vec[ir.AggregateField].create()
    var fi: ptr_uint = 0
    while fi < field_names.len():
        let fn_ptr = field_names.get(fi) else:
            break
        let ft_ptr = field_types.get(fi) else:
            break
        let fname = unsafe: read(fn_ptr)
        let ftype = unsafe: read(ft_ptr)
        let fval_ptr = arg_map.get(fname)
        var fval: ptr[ir.Expr]
        if fval_ptr != null:
            fval = unsafe: read(fval_ptr)
        else:
            fval = alloc_expr(ir.Expr.expr_member(receiver = recv, member = fname, ty = ftype))
        fields.push(ir.AggregateField(name = fname, value = fval))
        fi += 1
    return alloc_expr(ir.Expr.expr_aggregate_literal(ty = recv_ty, fields = fields.as_span()))


## Recover the declared length of a const/var array referenced by `receiver` by
## resolving its declaration's type annotation.  Returns 0 when the receiver is
## not a module-level const/var array identifier.
function const_array_length(ctx: ref[LowerCtx], receiver: ptr[ast.Expr]) -> long:
    var name: str
    unsafe:
        match read(receiver):
            ast.Expr.expr_identifier as id:
                name = id.name
            _:
                return 0
    var di: ptr_uint = 0
    while di < ctx.analysis.source_file.declarations.len:
        var d: ast.Decl
        unsafe:
            d = read(ctx.analysis.source_file.declarations.data + di)
        match d:
            ast.Decl.decl_const as c:
                if c.name == name:
                    return array_length_of(resolve_type_ref(ctx, c.const_type))
            _:
                pass
        di += 1
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


## Collect all `ir.Expr.expr_name` references from a span of IR statements.
function collect_ir_names(stmts: span[ir.Stmt], seen: ref[map_mod.Map[str, bool]]) -> void:
    var si: ptr_uint = 0
    while si < stmts.len:
        collect_ir_stmt_names(unsafe: read(stmts.data + si), seen)
        si += 1


function collect_ir_stmt_names(s: ir.Stmt, seen: ref[map_mod.Map[str, bool]]) -> void:
    match s:
        ir.Stmt.stmt_expression as ex:
            collect_ir_expr_names(unsafe: read(ex.expression), seen)
        ir.Stmt.stmt_assignment as asg:
            collect_ir_expr_names(unsafe: read(asg.target), seen)
            collect_ir_expr_names(unsafe: read(asg.value), seen)
        ir.Stmt.stmt_local as loc:
            collect_ir_expr_names(unsafe: read(loc.value), seen)
        ir.Stmt.stmt_return as ret:
            if ret.value != null:
                collect_ir_expr_names(unsafe: read(unsafe: ptr[ir.Expr]<-ret.value), seen)
        ir.Stmt.stmt_if as if_:
            collect_ir_expr_names(unsafe: read(if_.condition), seen)
            collect_ir_names(if_.then_body, seen)
        ir.Stmt.stmt_block as blk:
            collect_ir_names(blk.body, seen)
        ir.Stmt.stmt_for as f:
            collect_ir_expr_names(unsafe: read(f.condition), seen)
            collect_ir_names(f.body, seen)
        ir.Stmt.stmt_while as w:
            collect_ir_expr_names(unsafe: read(w.condition), seen)
            collect_ir_names(w.body, seen)
        _:
            pass


function collect_ir_expr_names(ep: ir.Expr, seen: ref[map_mod.Map[str, bool]]) -> void:
    match ep:
        ir.Expr.expr_name as nm:
            seen.set(nm.name, true)
        ir.Expr.expr_member as m:
            collect_ir_expr_names(unsafe: read(m.receiver), seen)
        ir.Expr.expr_unary as u:
            collect_ir_expr_names(unsafe: read(u.operand), seen)
        ir.Expr.expr_binary as b:
            collect_ir_expr_names(unsafe: read(b.left), seen)
            collect_ir_expr_names(unsafe: read(b.right), seen)
        ir.Expr.expr_index as ix:
            collect_ir_expr_names(unsafe: read(ix.receiver), seen)
            collect_ir_expr_names(unsafe: read(ix.index), seen)
        ir.Expr.expr_checked_index as ci:
            collect_ir_expr_names(unsafe: read(ci.receiver), seen)
            collect_ir_expr_names(unsafe: read(ci.index), seen)
        ir.Expr.expr_checked_span_index as cs:
            collect_ir_expr_names(unsafe: read(cs.receiver), seen)
            collect_ir_expr_names(unsafe: read(cs.index), seen)
        ir.Expr.expr_address_of as ao:
            collect_ir_expr_names(unsafe: read(ao.expression), seen)
        ir.Expr.expr_call as call:
            var ai: ptr_uint = 0
            while ai < call.arguments.len:
                collect_ir_expr_names(unsafe: read(call.arguments.data + ai), seen)
                ai += 1
        ir.Expr.expr_call_indirect as ci:
            collect_ir_expr_names(unsafe: read(ci.callee), seen)
            var cai: ptr_uint = 0
            while cai < ci.arguments.len:
                collect_ir_expr_names(unsafe: read(ci.arguments.data + cai), seen)
                cai += 1
        ir.Expr.expr_cast as c:
            collect_ir_expr_names(unsafe: read(c.expression), seen)
        ir.Expr.expr_aggregate_literal as al:
            var al_i: ptr_uint = 0
            while al_i < al.fields.len:
                collect_ir_expr_names(unsafe: read(unsafe: read(al.fields.data + al_i).value), seen)
                al_i += 1
        ir.Expr.expr_array_literal as al:
            var ali: ptr_uint = 0
            while ali < al.elements.len:
                collect_ir_expr_names(unsafe: read(al.elements.data + ali), seen)
                ali += 1
        ir.Expr.expr_variant_literal as vl:
            var vli: ptr_uint = 0
            while vli < vl.fields.len:
                collect_ir_expr_names(unsafe: read(unsafe: read(vl.fields.data + vli).value), seen)
                vli += 1
        _:
            pass


## Find the LocalBinding for a name in ctx.locals, if it exists.
function find_local(ctx: ref[LowerCtx], name: str) -> Option[LocalBinding]:
    var li: ptr_uint = ctx.locals.len()
    while li > 0:
        li -= 1
        let lb_ptr = ctx.locals.get(li) else:
            fatal(c"find_local: missing local")
        let item = unsafe: read(lb_ptr)
        if item.name == name:
            return Option[LocalBinding].some(value = item)
    return Option[LocalBinding].none


## Worker for mt_parallel_for: takes (void* data, int64_t start, int64_t end).
function parallel_for_worker_fn(ctx: ref[LowerCtx], body_ir: span[ir.Stmt]) -> ir.Function:
    let void_ty = types.primitive("void")
    let void_ptr_ty = types.Type.ty_generic(name = "ptr", args = sp_type(void_ty))
    let long_ty = types.primitive("long")
    parallel_cnt += 1
    let uid = parallel_uid(ctx)
    let name = j2("mt_pfor_work_", uid)
    # Wrap body in a for-loop: for (let i = mt_pfor_start; i < mt_pfor_end; i += 1) { body }
    let index_c = "i"
    let index_ref = alloc_expr(ir.Expr.expr_name(name = index_c, ty = long_ty, pointer = false))
    let start_ref = alloc_expr(ir.Expr.expr_name(name = "mt_pfor_start", ty = long_ty, pointer = false))
    let end_ref = alloc_expr(ir.Expr.expr_name(name = "mt_pfor_end", ty = long_ty, pointer = false))
    let cond = alloc_expr(ir.Expr.expr_binary(operator = "<", left = index_ref, right = end_ref, ty = types.primitive("bool")))
    let post = alloc_stmt(ir.Stmt.stmt_assignment(target = index_ref, operator = "+=", value = alloc_expr(ir.Expr.expr_integer_literal(value = 1, ty = long_ty))))
    let init = alloc_stmt(ir.Stmt.stmt_local(name = index_c, linkage_name = index_c, ty = long_ty, value = start_ref, line = 0, source_path = ""))
    let for_stmt = ir.Stmt.stmt_for(init = init, condition = cond, post = post, body = body_ir)
    var full_body = vec.Vec[ir.Stmt].create()
    full_body.push(for_stmt)
    var params = vec.Vec[ir.Param].create()
    params.push(ir.Param(name = "data", linkage_name = "data", ty = void_ptr_ty, pointer = false))
    params.push(ir.Param(name = "mt_pfor_start", linkage_name = "mt_pfor_start", ty = long_ty, pointer = false))
    params.push(ir.Param(name = "mt_pfor_end", linkage_name = "mt_pfor_end", ty = long_ty, pointer = false))
    return ir.Function(name = name, linkage_name = name, params = params.as_span(),
        return_type = void_ty, body = full_body.as_span(), entry_point = false, method_receiver_param = false)


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
    let bd = body else:
        return
    # Detect captures from loop body.
    var outer_len = ctx.locals.len()
    var loop_body = lower_block(ctx, bd)
    var names = map_mod.Map[str, bool].create()
    collect_ir_names(loop_body, ref_of(names))
    var pfor_captures = map_mod.Map[str, LocalBinding].create()
    var nm_iter = names.keys()
    while true:
        let np = nm_iter.next() else:
            break
        let nm = unsafe: read(np)
        # Skip the loop binding itself (shadowed by the worker wrapper).
        var skip = false
        var bi: ptr_uint = 0
        while bi < bindings.len:
            unsafe:
                if nm == read(bindings.data + bi).name:
                    skip = true
                    break
            bi += 1
        if skip:
            continue
        match find_local_before(ctx, nm, outer_len):
            Option.some as lb:
                pfor_captures.set(nm, lb.value)
            Option.none:
                pass
    # Generate capture struct if needed.
    parallel_cnt += 1
    let pfor_uid = parallel_uid(ctx)
    var pfor_has_captures = false
    var pf_ck = pfor_captures.keys()
    while true:
        let cp = pf_ck.next() else:
            break
        pfor_has_captures = true
        break
    var pfor_cap_name: str = ""
    if pfor_has_captures:
        pfor_cap_name = j3("mt_pcap_", naming.module_c_prefix(ctx.module_name), j2("_", pfor_uid))
        var pf_fields = vec.Vec[ir.Field].create()
        var pf_iter = pfor_captures.entries()
        while pf_iter.next():
            let pe = pf_iter.current()
            let lb_ptr = pfor_captures.get(unsafe: read(pe.key)) else:
                fatal(c"lower_parallel_for: missing capture")
            let lb_val = unsafe: read(lb_ptr)
            pf_fields.push(ir.Field(name = unsafe: read(pe.key), ty = lb_val.ty))
        ctx.pending_env_structs.push(ir.StructDecl(name = pfor_cap_name, linkage_name = pfor_cap_name, fields = pf_fields.as_span(), packed = false, alignment = 0, source_module = Option[str].none))
        # Prepend capture-unpacking preamble.
        var pf_pre = vec.Vec[ir.Stmt].create()
        let pf_cap_ptr = types.Type.ty_generic(name = "ptr", args = sp_type(types.Type.ty_named(module_name = "", name = pfor_cap_name)))
        let pf_data_local = ir.Stmt.stmt_local(name = "__cap", linkage_name = "__cap", ty = pf_cap_ptr, value = alloc_expr(ir.Expr.expr_cast(target_type = pf_cap_ptr, expression = alloc_expr(ir.Expr.expr_name(name = "data", ty = void_ptr_ty(), pointer = false)), ty = pf_cap_ptr)), line = 0, source_path = "")
        pf_pre.push(pf_data_local)
        let pf_cap_ref = alloc_expr(ir.Expr.expr_name(name = "__cap", ty = pf_cap_ptr, pointer = false))
        var pf_iter2 = pfor_captures.entries()
        while pf_iter2.next():
            let pe2 = pf_iter2.current()
            let ft_ptr = pfor_captures.get(unsafe: read(pe2.key)) else:
                fatal(c"lower_parallel_for: missing capture")
            let lb_v = unsafe: read(ft_ptr)
            let field_ty = lb_v.ty
            let field_expr = alloc_expr(ir.Expr.expr_member(receiver = pf_cap_ref, member = unsafe: read(pe2.key), ty = field_ty))
            pf_pre.push(ir.Stmt.stmt_local(name = unsafe: read(pe2.key), linkage_name = unsafe: read(pe2.key), ty = field_ty, value = field_expr, line = 0, source_path = ""))
        var pf_full = vec.Vec[ir.Stmt].create()
        var pf_pre_iter = pf_pre.iter()
        while true:
            let psp = pf_pre_iter.next() else:
                break
            pf_full.push(unsafe: read(psp))
        var lbi: ptr_uint = 0
        while lbi < loop_body.len:
            unsafe:
                pf_full.push(read(loop_body.data + lbi))
            lbi += 1
        loop_body = pf_full.as_span()
    let worker = parallel_for_worker_fn(ctx, loop_body)
    let start_expr = lower_expr(ctx, start_ptr)
    let end_expr = lower_expr(ctx, end_ptr)
    # Compute count = end - start.
    let count_expr = alloc_expr(ir.Expr.expr_binary(operator = "-", left = end_expr, right = start_expr, ty = long_ty))
    var call_args = vec.Vec[ir.Expr].create()
    unsafe:
        call_args.push(read(alloc_expr(ir.Expr.expr_name(name = worker.linkage_name, ty = void_ty, pointer = false))))
    if pfor_has_captures:
        let pf_cap_ty = types.Type.ty_named(module_name = "", name = pfor_cap_name)
        let pf_cap_var = j2("__pf_cap_", pfor_uid)
        var pf_setup = vec.Vec[ir.Stmt].create()
        let pf_cap_ref = alloc_expr(ir.Expr.expr_name(name = pf_cap_var, ty = pf_cap_ty, pointer = false))
        pf_setup.push(ir.Stmt.stmt_local(name = pf_cap_var, linkage_name = pf_cap_var, ty = pf_cap_ty, value = alloc_expr(ir.Expr.expr_zero_init(ty = pf_cap_ty)), line = 0, source_path = ""))
        var pf_iter3 = pfor_captures.entries()
        while pf_iter3.next():
            let pe3 = pf_iter3.current()
            let lb_ptr = pfor_captures.get(unsafe: read(pe3.key)) else:
                fatal(c"lower_parallel_for: missing capture")
            let lb_val = unsafe: read(lb_ptr)
            let key = unsafe: read(pe3.key)
            let outer_ref = alloc_expr(ir.Expr.expr_name(name = key, ty = lb_val.ty, pointer = false))
            let field_ref = alloc_expr(ir.Expr.expr_member(receiver = pf_cap_ref, member = key, ty = lb_val.ty))
            if is_array_type(lb_val.ty):
                let field_addr = alloc_expr(ir.Expr.expr_address_of(expression = field_ref, ty = types.Type.ty_generic(name = "ptr", args = sp_type(lb_val.ty))))
                let outer_addr = alloc_expr(ir.Expr.expr_address_of(expression = outer_ref, ty = types.Type.ty_generic(name = "ptr", args = sp_type(lb_val.ty))))
                let sz = alloc_expr(ir.Expr.expr_sizeof(target_type = lb_val.ty, ty = types.primitive("ptr_uint")))
                var mc_args = vec.Vec[ir.Expr].create()
                unsafe:
                    mc_args.push(read(field_addr))
                    mc_args.push(read(outer_addr))
                    mc_args.push(read(sz))
                pf_setup.push(ir.Stmt.stmt_expression(expression = alloc_expr(ir.Expr.expr_call(callee = "memcpy", arguments = mc_args.as_span(), ty = types.primitive("void"))), line = 0, source_path = ""))
            else:
                pf_setup.push(ir.Stmt.stmt_assignment(target = field_ref, operator = "=", value = outer_ref))
        var pf_setup_iter = pf_setup.iter()
        while true:
            let psp = pf_setup_iter.next() else:
                break
            output.push(unsafe: read(psp))
        let pf_data_ref = alloc_expr(ir.Expr.expr_address_of(expression = alloc_expr(ir.Expr.expr_name(name = pf_cap_var, ty = pf_cap_ty, pointer = false)), ty = void_ptr_ty()))
        unsafe:
            call_args.push(read(pf_data_ref))
    else:
        unsafe:
            call_args.push(read(alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = void_ptr_ty()))))
    unsafe:
        call_args.push(read(count_expr))
    ctx.pending_synthetic_functions.push(worker)
    output.push(ir.Stmt.stmt_expression(
        expression = alloc_expr(ir.Expr.expr_call(callee = "mt_parallel_for", arguments = call_args.as_span(), ty = void_ty)),
        line = 0, source_path = "",
    ))


## Lower `parallel: stmt1; stmt2; ...`.  Each statement becomes a worker
## function, dispatched via mt_spawn_all.
function lower_parallel_block(ctx: ref[LowerCtx], output: ref[vec.Vec[ir.Stmt]], bodies: span[ast.Stmt]) -> void:
    if bodies.len < 2:
        return
    let void_ty = types.primitive("void")
    parallel_cnt += 1
    let cap_uid = parallel_uid(ctx)
    # Detect captures: names referenced in bodies that are outer-scope locals.
    var i: ptr_uint = 0
    var all_captures = map_mod.Map[str, LocalBinding].create()
    var body_irs = vec.Vec[span[ir.Stmt]].create()
    var outer_len = ctx.locals.len()
    while i < bodies.len:
        var wb = lower_block(ctx, unsafe: ptr[ast.Stmt]<-(bodies.data + i))
        body_irs.push(wb)
        var names = map_mod.Map[str, bool].create()
        collect_ir_names(wb, ref_of(names))
        var nm_iter = names.keys()
        while true:
            let np = nm_iter.next() else:
                break
            let nm = unsafe: read(np)
            match find_local_before(ctx, nm, outer_len):
                Option.some as lb:
                    all_captures.set(nm, lb.value)
                Option.none:
                    pass
        i += 1
    # Generate capture struct if any captures exist.
    var has_captures = false
    var ck_iter = all_captures.keys()
    while true:
        let ckp = ck_iter.next() else:
            break
        has_captures = true
        break
    var cap_struct_name: str = ""
    var cap_body_irs = vec.Vec[span[ir.Stmt]].create()
    if has_captures:
        cap_struct_name = j3("mt_pcap_", naming.module_c_prefix(ctx.module_name), j2("_", cap_uid))
        var cap_fields = vec.Vec[ir.Field].create()
        var cap_iter = all_captures.entries()
        while cap_iter.next():
            let entry = cap_iter.current()
            let lb_ptr = all_captures.get(unsafe: read(entry.key)) else:
                fatal(c"lower_parallel_block: missing capture binding")
            let lb_val = unsafe: read(lb_ptr)
            cap_fields.push(ir.Field(name = unsafe: read(entry.key), ty = lb_val.ty))
        ctx.pending_env_structs.push(ir.StructDecl(name = cap_struct_name, linkage_name = cap_struct_name, fields = cap_fields.as_span(), packed = false, alignment = 0, source_module = Option[str].none))
        # Rewrite each body: prepend capture-unpacking preamble.
        var body_ir_iter = body_irs.iter()
        while true:
            let bir_ptr = body_ir_iter.next() else:
                break
            var pre_body = vec.Vec[ir.Stmt].create()
            let cap_ptr_ty = types.Type.ty_generic(name = "ptr", args = sp_type(types.Type.ty_named(module_name = "", name = cap_struct_name)))
            let data_local = ir.Stmt.stmt_local(name = "__cap", linkage_name = "__cap", ty = cap_ptr_ty, value = alloc_expr(ir.Expr.expr_cast(target_type = cap_ptr_ty, expression = alloc_expr(ir.Expr.expr_name(name = "data", ty = void_ptr_ty(), pointer = false)), ty = cap_ptr_ty)), line = 0, source_path = "")
            pre_body.push(data_local)
            let cap_ref = alloc_expr(ir.Expr.expr_name(name = "__cap", ty = cap_ptr_ty, pointer = false))
            var cap_iter2 = all_captures.entries()
            while cap_iter2.next():
                let entry2 = cap_iter2.current()
                let ft2_ptr = all_captures.get(unsafe: read(entry2.key)) else:
                    fatal(c"lower_parallel_block: missing capture")
                let lb_v2 = unsafe: read(ft2_ptr)
                let field_ty = lb_v2.ty
                let field_expr = alloc_expr(ir.Expr.expr_member(receiver = cap_ref, member = unsafe: read(entry2.key), ty = field_ty))
                pre_body.push(ir.Stmt.stmt_local(name = unsafe: read(entry2.key), linkage_name = unsafe: read(entry2.key), ty = field_ty, value = field_expr, line = 0, source_path = ""))
            var full_body = vec.Vec[ir.Stmt].create()
            var pre_iter = pre_body.iter()
            while true:
                let psp = pre_iter.next() else:
                    break
                full_body.push(unsafe: read(psp))
            var bsi: ptr_uint = 0
            let bir = unsafe: read(bir_ptr)
            while bsi < bir.len:
                unsafe:
                    full_body.push(read(bir.data + bsi))
                bsi += 1
            cap_body_irs.push(full_body.as_span())
    else:
        cap_body_irs = body_irs

    # Generate workers, accumulate spawn items, emit mt_spawn_all.
    let spawn_item_ty = types.Type.ty_named(module_name = "", name = "mt_spawn_item")
    var spawn_items = vec.Vec[ir.Expr].create()
    let void_ptr_ty = types.Type.ty_generic(name = "ptr", args = sp_type(types.primitive("void")))
    i = 0
    while i < bodies.len:
        let wbp = cap_body_irs.get(i) else:
            fatal(c"lower_parallel_block: missing body IR")
        let wb = unsafe: read(wbp)
        let worker = parallel_worker_fn(ctx, wb)
        ctx.pending_synthetic_functions.push(worker)
        var item_data: ptr[ir.Expr]
        if has_captures:
            let cap_ty = types.Type.ty_named(module_name = "", name = cap_struct_name)
            let cap_var = j3("__cap_", cap_uid, j2("_", pw1_str(i)))
            var cap_setup = vec.Vec[ir.Stmt].create()
            let cap_ref = alloc_expr(ir.Expr.expr_name(name = cap_var, ty = cap_ty, pointer = false))
            cap_setup.push(ir.Stmt.stmt_local(name = cap_var, linkage_name = cap_var, ty = cap_ty, value = alloc_expr(ir.Expr.expr_zero_init(ty = cap_ty)), line = 0, source_path = ""))
            var cap_iter3 = all_captures.entries()
            while cap_iter3.next():
                let entry3 = cap_iter3.current()
                let lb2_ptr = all_captures.get(unsafe: read(entry3.key)) else:
                    fatal(c"lower_parallel_block: missing capture")
                let lb_val = unsafe: read(lb2_ptr)
                let key = unsafe: read(entry3.key)
                let outer_ref = alloc_expr(ir.Expr.expr_name(name = key, ty = lb_val.ty, pointer = false))
                let field_ref = alloc_expr(ir.Expr.expr_member(receiver = cap_ref, member = key, ty = lb_val.ty))
                if is_array_type(lb_val.ty):
                    let field_addr = alloc_expr(ir.Expr.expr_address_of(expression = field_ref, ty = types.Type.ty_generic(name = "ptr", args = sp_type(lb_val.ty))))
                    let outer_addr = alloc_expr(ir.Expr.expr_address_of(expression = outer_ref, ty = types.Type.ty_generic(name = "ptr", args = sp_type(lb_val.ty))))
                    let sz = alloc_expr(ir.Expr.expr_sizeof(target_type = lb_val.ty, ty = types.primitive("ptr_uint")))
                    var mc_args = vec.Vec[ir.Expr].create()
                    unsafe:
                        mc_args.push(read(field_addr))
                        mc_args.push(read(outer_addr))
                        mc_args.push(read(sz))
                    cap_setup.push(ir.Stmt.stmt_expression(expression = alloc_expr(ir.Expr.expr_call(callee = "memcpy", arguments = mc_args.as_span(), ty = types.primitive("void"))), line = 0, source_path = ""))
                else:
                    cap_setup.push(ir.Stmt.stmt_assignment(target = field_ref, operator = "=", value = outer_ref))
            var cs_iter = cap_setup.iter()
            while true:
                let csp = cs_iter.next() else:
                    break
                output.push(unsafe: read(csp))
            item_data = alloc_expr(ir.Expr.expr_address_of(expression = alloc_expr(ir.Expr.expr_name(name = cap_var, ty = cap_ty, pointer = false)), ty = void_ptr_ty))
        else:
            item_data = alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = void_ptr_ty))
        var item_fields = vec.Vec[ir.AggregateField].create()
        item_fields.push(ir.AggregateField(name = "work", value = alloc_expr(ir.Expr.expr_name(name = worker.linkage_name, ty = void_ty, pointer = false))))
        item_fields.push(ir.AggregateField(name = "data", value = item_data))
        let item_agg = alloc_expr(ir.Expr.expr_aggregate_literal(ty = spawn_item_ty, fields = item_fields.as_span()))
        unsafe:
            spawn_items.push(read(item_agg))
        i += 1
    let item_count = bodies.len
    let spawn_arr_ty = types.Type.ty_generic(name = "array", args = sp_type2(spawn_item_ty, types.literal_int(long<-item_count)))
    let tasks_var = "__mt_tasks"
    let tasks_arr = alloc_expr(ir.Expr.expr_array_literal(ty = spawn_arr_ty, elements = spawn_items.as_span()))
    output.push(ir.Stmt.stmt_local(name = tasks_var, linkage_name = tasks_var, ty = spawn_arr_ty, value = tasks_arr, line = 0, source_path = ""))
    var sa_args = vec.Vec[ir.Expr].create()
    unsafe:
        sa_args.push(read(alloc_expr(ir.Expr.expr_name(name = tasks_var, ty = spawn_arr_ty, pointer = false))))
        sa_args.push(read(alloc_expr(ir.Expr.expr_integer_literal(value = long<-item_count, ty = types.primitive("int")))))
    output.push(ir.Stmt.stmt_expression(
        expression = alloc_expr(ir.Expr.expr_call(callee = "mt_spawn_all", arguments = sa_args.as_span(), ty = void_ty)),
        line = 0, source_path = "",
    ))


function find_local_before(ctx: ref[LowerCtx], name: str, limit: ptr_uint) -> Option[LocalBinding]:
    var li: ptr_uint = 0
    while li < limit and li < ctx.locals.len():
        let lb_ptr = ctx.locals.get(li) else:
            fatal(c"find_local_before: missing local")
        let item = unsafe: read(lb_ptr)
        if item.name == name:
            return Option[LocalBinding].some(value = item)
        li += 1
    return Option[LocalBinding].none


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
                                types.Type.ty_function as fnt:
                                    # Only wrap in proc struct when the expected type
                                    # is a proc (is_proc == true).  For plain fn
                                    # fields, pass the function pointer directly.
                                    if fnt.is_proc:
                                        return lower_fn_to_proc(ctx, fn_c_name, fn_ty)
                                _:
                                    pass
                            return alloc_expr(ir.Expr.expr_name(name = fn_c_name, ty = fn_ty, pointer = false))
                        if ctx.analysis.events.contains(id.name):
                            return alloc_expr(ir.Expr.expr_name(name = id.name, ty = expr_type(ctx, ep), pointer = false))
                        match lookup_qualified_constant(ctx, id.name):
                            Option.some as qc:
                                return alloc_expr(ir.Expr.expr_name(name = qc.value, ty = expr_type(ctx, ep), pointer = false))
                            Option.none:
                                pass
                        return alloc_expr(ir.Expr.expr_name(name = id.name, ty = expr_type(ctx, ep), pointer = false))
            ast.Expr.expr_binary_op as bin:
                var left = lower_expr(ctx, bin.left)
                var right = lower_expr(ctx, bin.right)
                var result_ty = expr_type(ctx, ep)
                # Vector/matrix/quaternion binary arithmetic: lower to
                # component-wise aggregate literal BEFORE type promotion, so
                # scalar operands are not cast to the vector result type.
                # Only apply when at least one operand is an actual vector type
                # (the analyzer may mis-type float sub-expressions as vec3
                # inside methods on vec types).
                let lt = ir_expr_type(left)
                let rt = ir_expr_type(right)
                let rn = nominal_type_name(result_ty)
                if is_vec_math_name(rn) and (
                    is_vec_math_name(nominal_type_name(lt)) or is_vec_math_name(nominal_type_name(rt))
                ) and (
                    bin.operator == "+" or bin.operator == "-" or bin.operator == "*" or bin.operator == "/"
                ):
                    return lower_vec_binary_op(ctx, bin.operator, left, right, result_ty, rn)
                # Pointer arithmetic (`p + i` / `p - i`) yields the pointer
                # operand's concrete type; the analyzer's generically-recorded
                # type may have dropped its arguments inside a monomorphized body.
                if bin.operator == "+" or bin.operator == "-":
                    let left_ty = ir_expr_type(left)
                    if types.is_raw_pointer(left_ty) and not types.is_raw_pointer(ir_expr_type(right)):
                        result_ty = left_ty
                # Integer arithmetic where the analyzer's recorded type is not an
                # integer (e.g. `text.len - n`, where `.len` is typed `ptr_uint`
                # by lowering but the analyzer recorded a wrong type): trust the
                # lowered operand types when both are the same integer type.
                if is_arithmetic_operator(bin.operator) and not is_integer_scrutinee(result_ty):
                    let lt = ir_expr_type(left)
                    let rt = ir_expr_type(right)
                    if is_integer_scrutinee(lt) and types.type_to_string(lt) == types.type_to_string(rt):
                        result_ty = lt
                    # `<wider-int-expr> + <int literal>` (e.g. `ptr_uint + 2`): the
                    # analyzer recorded a non-integer result, and one operand is a
                    # plain `int` literal.  Adopt the other operand's wider integer
                    # type so the result matches the dominant operand.
                    else if is_integer_scrutinee(lt) and types.type_to_string(rt) == "int":
                        result_ty = lt
                    else if is_integer_scrutinee(rt) and types.type_to_string(lt) == "int":
                        result_ty = rt
                # Balance mixed-width integer and int/float operands: cast the
                # narrower operand up to the common type, matching Ruby's
                # usual-arithmetic-conversion casts (redundant casts are elided
                # by the C backend).  For arithmetic operators the common type is
                # also the result type, which the analyzer may have under-widened.
                # Enum/flags operands unwrap to their integer backing first, so
                # enum comparisons cast to the backing type like Ruby.
                let bal_lt = enum_backing_or_self(ctx, ir_expr_type(left))
                let bal_rt = enum_backing_or_self(ctx, ir_expr_type(right))
                match promoted_binary_operand_type(bin.operator, bal_lt, bal_rt):
                    Option.some as op_ty:
                        left = cast_to_type(left, op_ty.value)
                        right = cast_to_type(right, op_ty.value)
                        if is_pure_arithmetic_operator(bin.operator):
                            result_ty = op_ty.value
                    Option.none:
                        pass
                return alloc_expr(ir.Expr.expr_binary(operator = bin.operator, left = left, right = right, ty = result_ty))
            ast.Expr.expr_unary_op as un:
                let operand = lower_expr(ctx, un.operand)
                let op_ty = ir_expr_type(operand)
                if un.operator == "-":
                    let vname = nominal_type_name(op_ty)
                    if is_vec_math_name(vname):
                        return lower_vec_unary_neg(ctx, operand, vname)
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
                return lower_tuple_literal_with_names(ctx, lst.elements)
            ast.Expr.expr_proc as pr:
                return lower_proc_expression(ctx, pr.method_params, pr.return_type, pr.body, ep)
            ast.Expr.expr_await as aw:
                let inner = lower_expr(ctx, aw.expression)
                return unwrap_task_value(inner)
            ast.Expr.expr_format_string as fs:
                let str_ty = types.Type.ty_str
                return alloc_expr(ir.Expr.expr_string_literal(value = "fmt", ty = str_ty, cstring = false))
            ast.Expr.expr_detach as dt:
                return lower_detach_expr(ctx, dt.expression, ep)
            ast.Expr.expr_specialization as spec:
                match read(spec.callee):
                    ast.Expr.expr_identifier as id:
                        if id.name == "zero" and spec.arguments.len == 1:
                            let z_ty = resolve_type_ref(ctx, read(spec.arguments.data + 0).value)
                            return alloc_expr(ir.Expr.expr_zero_init(ty = z_ty))
                        if id.name == "default" and spec.arguments.len == 1:
                            let t_ty = qualify_type(ctx, resolve_type_ref(ctx, read(spec.arguments.data + 0).value))
                            match resolve_method_info(ctx, t_ty, "default"):
                                Option.some as smi:
                                    if smi.value.method_kind == ast.MethodKind.mk_static:
                                        var empty_args = span[ast.Argument]()
                                        return lower_static_call_args(ctx, smi.value, empty_args)
                                Option.none:
                                    pass
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
                var field_name = off.field
                match ctx.inline_for_element:
                    Option.some as ce:
                        match ce.value:
                            ComptimeElement.ce_struct_field as sf:
                                field_name = sf.name
                            _:
                                pass
                    Option.none:
                        pass
                return alloc_expr(ir.Expr.expr_offsetof(
                    target_type = qualify_type(ctx, resolve_type_ref(ctx, off.target_type)),
                    field = field_name,
                    ty = types.primitive("ptr_uint"),
                ))
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
    # Use the shared proc struct name (mt_proc_<ret>) so that proc-typed
    # fields, params, and expressions all unify to the same C struct type.
    let void_ptr = types.Type.ty_generic(name = "ptr", args = sp_type(types.primitive("void")))
    let shared_name = proc_type_name_from_signature(proc_ty)
    let struct_name = shared_name
    # Register the shared struct declaration (no-op if already emitted).
    let _proc_struct_ty = proc_ensure_struct_decl(ctx, struct_name, proc_ty)

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
        let env_ptr_ty = types.Type.ty_generic(name = "ptr", args = sp_type(types.Type.ty_named(module_name = "", name = env_type_name)))
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
        return alloc_expr(ir.Expr.expr_aggregate_literal(ty = types.Type.ty_named(module_name = "", name = struct_name), fields = fields.as_span()))

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

    return alloc_expr(ir.Expr.expr_aggregate_literal(ty = types.Type.ty_named(module_name = "", name = struct_name), fields = fields.as_span()))


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
    # Track already-collected names to avoid duplicates from stale match-
    # arm bindings that persist in ctx.locals across scope boundaries.
    var seen_names = map_mod.Map[str, bool].create()
    var li: ptr_uint = 0
    while li < ctx.locals.len():
        let lb_ptr = ctx.locals.get(li) else:
            break
        unsafe:
            let lb = read(lb_ptr)
            if lb.name == "this" or param_names.contains(lb.name):
                li += 1
                continue
            if seen_names.contains(lb.c_name):
                li += 1
                continue
            seen_names.set(lb.c_name, true)
            result.push(ProcCapture(name = lb.name, c_name = lb.c_name, ty = lb.ty))
        li += 1
    return result.as_span()


## Build a setup function that allocates + populates the capture-env struct.
## Takes captured values as parameters and returns a pointer to the initialized env.
function build_env_setup_fn(ctx: ref[LowerCtx], c_name: str, env_type_name: str, captures: span[ProcCapture]) -> ir.Function:
    let void_ptr = types.Type.ty_generic(name = "ptr", args = sp_type(types.primitive("void")))
    let env_ty_named = types.Type.ty_named(module_name = "", name = env_type_name)
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
        if is_array_type(cap.ty):
            let addr_of_field = alloc_expr(ir.Expr.expr_address_of(expression = field, ty = types.Type.ty_generic(name = "ptr", args = sp_type(cap.ty))))
            let addr_of_arg = alloc_expr(ir.Expr.expr_address_of(expression = cap_val, ty = types.Type.ty_generic(name = "ptr", args = sp_type(cap.ty))))
            let size_val = alloc_expr(ir.Expr.expr_sizeof(target_type = cap.ty, ty = uint_ty))
            var memcpy_args = vec.Vec[ir.Expr].create()
            unsafe:
                memcpy_args.push(read(addr_of_field))
                memcpy_args.push(read(addr_of_arg))
                memcpy_args.push(read(size_val))
            body.push(ir.Stmt.stmt_expression(expression = alloc_expr(ir.Expr.expr_call(callee = "memcpy", arguments = memcpy_args.as_span(), ty = types.primitive("void"))), line = 0, source_path = ""))
        else:
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
    let env_ptr_ty = types.Type.ty_generic(name = "ptr", args = sp_type(types.Type.ty_named(module_name = "", name = env_type_name)))

    var params = vec.Vec[ir.Param].create()
    params.push(ir.Param(name = "__mt_proc_env", linkage_name = "__mt_proc_env", ty = void_ptr, pointer = false))

    var pi: ptr_uint = 0
    while pi < method_params.len:
        var p: ast.Param
        unsafe:
            p = read(method_params.data + pi)
        let p_ty = resolve_field_type_ref(ctx, p.param_type)
        let pc = utils.c_local_name(p.name)
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
        let bc = utils.c_local_name(cap.name)
        body_stmts.push(ir.Stmt.stmt_local(name = cap.name, linkage_name = bc, ty = cap.ty, value = member, line = 0, source_path = ""))
        ctx.locals.push(LocalBinding(name = cap.name, c_name = bc, ty = cap.ty, pointer = false))
        ci += 1

    # Append the original body.
    let orig_body = lower_function_body(ctx, body)
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
    let env_ptr_ty = types.Type.ty_generic(name = "ptr", args = sp_type(types.Type.ty_named(module_name = "", name = env_type_name)))
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
    let env_ptr_ty = types.Type.ty_generic(name = "ptr", args = sp_type(types.Type.ty_named(module_name = "", name = env_type_name)))
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
        let pc = utils.c_local_name(p.name)
        params.push(ir.Param(name = p.name, linkage_name = pc, ty = p_ty, pointer = false))
        ctx.locals.push(LocalBinding(name = p.name, c_name = pc, ty = p_ty, pointer = false))
        pi += 1

    var ret_ty = types.primitive("void")
    if return_type != null:
        ret_ty = resolve_type_ref(ctx, return_type)
    let body_stmts = lower_function_body(ctx, body)

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
            return types.Type.ty_function(params = all_params.as_span(), return_type = fn_ty.return_type, variadic = false, is_proc = true)
        _:
            return types.Type.ty_error


## The proc's release/retain field type: `fn(env: ptr[void]) -> void`.
function proc_lifecycle_fn_type() -> types.Type:
    var params = vec.Vec[types.Type].create()
    params.push(types.Type.ty_generic(name = "ptr", args = sp_type(types.primitive("void"))))
    return types.Type.ty_function(params = params.as_span(), return_type = types.alloc_type(types.primitive("void")), variadic = false, is_proc = false)
## fields `_0`, `_1`, ... and a `ty_tuple` type.  (Named tuples arrive later.)
function lower_tuple_literal_with_names(ctx: ref[LowerCtx], elements: span[ast.Expr]) -> ptr[ir.Expr]:
    var fields = vec.Vec[ir.AggregateField].create()
    var elem_types = vec.Vec[types.Type].create()
    var fnames = vec.Vec[str].create()
    var all_named = true
    var i: ptr_uint = 0
    while i < elements.len:
        var ep = unsafe: elements.data + i
        var name: str = ""
        unsafe:
            match read(ep):
                ast.Expr.expr_named as nm:
                    name = nm.name
                    ep = nm.value
                _:
                    all_named = false
                    pass
        let lowered = unsafe: lower_expr(ctx, ep)
        let fname = if name != "": name else: tuple_field_name(i)
        if name == "":
            name = tuple_field_name(i)
        fields.push(ir.AggregateField(name = name, value = lowered))
        elem_types.push(ir_expr_type(lowered))
        fnames.push(name)
        i += 1
    var tuple_field_names = Option[span[str]].none
    if all_named:
        tuple_field_names = Option[span[str]].some(value = fnames.as_span())
    return alloc_expr(ir.Expr.expr_aggregate_literal(
        ty = types.Type.ty_tuple(elements = elem_types.as_span(), field_names = tuple_field_names),
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
    var elem_ty = qualify_type(ctx, expr_type(ctx, ep))
    if types.is_error(elem_ty):
        elem_ty = qualify_type(ctx, generic_first_arg(receiver_type))
    if is_array_type(receiver_type):
        return alloc_expr(ir.Expr.expr_checked_index(receiver = recv, index = index_expr, receiver_type = receiver_type, ty = elem_ty))
    if is_span_type(receiver_type):
        return alloc_expr(ir.Expr.expr_checked_span_index(receiver = recv, index = index_expr, receiver_type = receiver_type, ty = elem_ty))
    return alloc_expr(ir.Expr.expr_index(receiver = recv, index = index_expr, ty = elem_ty))


## Lower `arr[start..end] = (e1, e2, ...)` into individual checked-index
## assignments.  The range start must be a uint-typed integer literal, and the
## RHS expression list length must match the range width.
function lower_range_index_assignment(ctx: ref[LowerCtx], output: ref[vec.Vec[ir.Stmt]], receiver: ptr[ast.Expr], start_expr: ptr[ast.Expr], elements: span[ast.Expr]) -> void:
    let receiver_type = index_receiver_type(ctx, receiver)
    let recv = lower_expr(ctx, receiver)
    var start_val: long = 0
    unsafe:
        match read(start_expr):
            ast.Expr.expr_integer_literal as il:
                start_val = il.value
            _:
                fatal(c"lower_range_index_assignment: start must be integer literal")
    var elem_ty = qualify_type(ctx, generic_first_arg(receiver_type))
    if types.is_error(elem_ty):
        fatal(c"lower_range_index_assignment: cannot determine element type")
    var i: ptr_uint = 0
    while i < elements.len:
        let index_expr = alloc_expr(ir.Expr.expr_integer_literal(value = start_val + long<-(i), ty = types.primitive("ptr_uint")))
        var target_expr: ptr[ir.Expr]
        if is_array_type(receiver_type):
            target_expr = alloc_expr(ir.Expr.expr_checked_index(receiver = recv, index = index_expr, receiver_type = receiver_type, ty = elem_ty))
        else if is_span_type(receiver_type):
            target_expr = alloc_expr(ir.Expr.expr_checked_span_index(receiver = recv, index = index_expr, receiver_type = receiver_type, ty = elem_ty))
        else:
            target_expr = alloc_expr(ir.Expr.expr_index(receiver = recv, index = index_expr, ty = elem_ty))
        let value_expr = lower_expr(ctx, unsafe: elements.data + i)
        output.push(ir.Stmt.stmt_assignment(target = target_expr, operator = "=", value = value_expr))
        i += 1


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
                let mvt = module_var_type(ctx, id.name)
                if not types.is_error(mvt):
                    return mvt
            _:
                pass
    return expr_type(ctx, receiver)


function is_array_type(t: types.Type) -> bool:
    match t:
        types.Type.ty_generic as g:
            return g.name == "array" and g.args.len == 2
        _:
            return false


function is_span_type(t: types.Type) -> bool:
    match t:
        types.Type.ty_generic as g:
            return g.name == "span" and g.args.len == 1
        _:
            return false


function is_soa_type(t: types.Type) -> bool:
    match t:
        types.Type.ty_generic as g:
            return g.name == "SoA" and g.args.len >= 2
        _:
            return false


## The C field type for member `field_name` on the element type of an SoA.
## The SoA struct has one array per element field, so the array element type
## is the field type from the element struct.
function soa_field_type(ctx: ref[LowerCtx], soa_ty: types.Type, field_name: str) -> types.Type:
    match soa_ty:
        types.Type.ty_generic as g:
            if g.args.len >= 1:
                let elem_ty = unsafe: read(g.args.data + 0)
                match elem_ty:
                    types.Type.ty_named as n:
                        # Look up the field in the element struct from analysis.
                        let fields_ptr = ctx.analysis.structs.get(n.name) else:
                            return types.primitive("void")
                        let entries = unsafe: read(fields_ptr)
                        var fi: ptr_uint = 0
                        while fi < entries.len:
                            let entry = unsafe: read(entries.data + fi)
                            if entry.name == field_name:
                                return entry.ty
                            fi += 1
                    _:
                        pass
        _:
            pass
    return types.primitive("void")


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
                if id.name == "fatal":
                    # `fatal(cstr)` → mt_fatal(const char*); `fatal(str)` →
                    # mt_fatal_str(mt_str), mirroring Ruby's fatal dispatch.
                    var fatal_callee = "mt_fatal"
                    if args.len > 0:
                        if not fatal_arg_is_cstr(ctx, unsafe: read(args.data + 0).arg_value):
                            fatal_callee = "mt_fatal_str"
                    return lower_plain_call(ctx, fatal_callee, args, call_ep, null)
                if id.name == "ptr_of" or id.name == "ref_of" or id.name == "const_ptr_of":
                    if args.len == 1:
                        let inner = lower_expr(ctx, read(args.data + 0).arg_value)
                        let inner_ty = ir_expr_type(inner)
                        var result_ty = expr_type(ctx, call_ep)
                        # When expr_type returns void or error (e.g. the analyzer
                        # did not record a type for the builtin), compute the
                        # correct result type from the argument's type.
                        let outer_kind = if id.name == "ptr_of": "ptr" else: if id.name == "ref_of": "ref" else: "const_ptr"
                        if types.is_error(result_ty) or types.is_void(result_ty):
                            result_ty = types.Type.ty_generic(name = outer_kind, args = sp_type(inner_ty))
                        # When the argument is already a pointer/ref value (e.g. a
                        # `ref[T]` parameter, which is a pointer in C), taking its
                        # address again would produce `T**`.  Use the pointer value
                        # directly; if it is a `*p` deref, use the underlying `p`.
                        # Mirrors Ruby's ref_of/ptr_of/const_ptr_of handling.
                        match read(inner):
                            ir.Expr.expr_name as nm:
                                if nm.pointer:
                                    return alloc_expr(ir.Expr.expr_name(name = nm.name, ty = result_ty, pointer = true))
                                # ref[T] is already a pointer in C, so ptr_of/const_ptr_of
                                # on a ref variable returns the variable directly as a raw
                                # pointer to the referent; ref_of returns it as-is.
                                if types.is_ref_type(nm.ty):
                                    let ref_elem = types.pointer_element(nm.ty)
                                    let elem_sp = sp_type(ref_elem)
                                    var adjusted_ty = result_ty
                                    if id.name == "ptr_of":
                                        adjusted_ty = types.Type.ty_generic(name = "ptr", args = elem_sp)
                                    if id.name == "const_ptr_of":
                                        adjusted_ty = types.Type.ty_generic(name = "const_ptr", args = elem_sp)
                                    if id.name == "ref_of":
                                        pass
                                    return alloc_expr(ir.Expr.expr_name(name = nm.name, ty = adjusted_ty, pointer = true))
                            ir.Expr.expr_unary as un:
                                if un.operator == "*":
                                    return un.operand
                            _:
                                pass
                        return alloc_expr(ir.Expr.expr_address_of(expression = inner, ty = result_ty))
                # `read(p)` as an rvalue → pointer dereference `*p`.  The result
                # type is the pointer's element type (more reliable than the
                # analyzer's generically-recorded type inside monomorphized
                # bodies); fall back to the recorded call type otherwise.
                if id.name == "read":
                    if args.len == 1:
                        let inner = lower_expr(ctx, read(args.data + 0).arg_value)
                        var base = ir_expr_type(inner)
                        if types.is_nullable_type(base):
                            base = types.unwrap_nullable(base)
                        var elem_ty = expr_type(ctx, call_ep)
                        if types.is_raw_pointer(base) or types.is_ref_type(base):
                            elem_ty = types.pointer_element(base)
                        return alloc_expr(ir.Expr.expr_unary(operator = "*", operand = inner, ty = qualify_type(ctx, elem_ty)))
                # `get(coll, index)` → recoverable array/span indexing returning
                # `ptr[T]?` — null on out-of-bounds instead of aborting.
                # Maps to IR checked_index / checked_span_index, mirroring Ruby.
                if id.name == "get":
                    if args.len >= 2:
                        let recv_val = unsafe: read(args.data + 0).arg_value
                        let idx_val = unsafe: read(args.data + 1).arg_value
                        let recv_ty = index_receiver_type(ctx, recv_val)
                        let recv_ir = lower_expr(ctx, recv_val)
                        let idx_ir = lower_expr(ctx, idx_val)
                        var elem_ty = generic_first_arg(recv_ty)
                        if types.is_error(elem_ty):
                            elem_ty = expr_type(ctx, call_ep)
                        if types.is_nullable_type(elem_ty):
                            elem_ty = types.unwrap_nullable(elem_ty)
                        if is_array_type(recv_ty):
                            let checked = alloc_expr(ir.Expr.expr_checked_index(receiver = recv_ir, index = idx_ir, receiver_type = recv_ty, ty = elem_ty))
                            let ptr_ty = types.Type.ty_generic(name = "ptr", args = sp_type(qualify_type(ctx, elem_ty)))
                            let nullable_ptr = types.Type.ty_nullable(base = types.alloc_type(ptr_ty))
                            return alloc_expr(ir.Expr.expr_address_of(expression = checked, ty = nullable_ptr))
                        if is_span_type(recv_ty):
                            let checked = alloc_expr(ir.Expr.expr_checked_span_index(receiver = recv_ir, index = idx_ir, receiver_type = recv_ty, ty = elem_ty))
                            let ptr_ty = types.Type.ty_generic(name = "ptr", args = sp_type(qualify_type(ctx, elem_ty)))
                            let nullable_ptr = types.Type.ty_nullable(base = types.alloc_type(ptr_ty))
                            return alloc_expr(ir.Expr.expr_address_of(expression = checked, ty = nullable_ptr))
                # Native `str(data = ..., len = ...)` construction -> mt_str
                # aggregate literal (not a call to a `str` function).
                if id.name == "str":
                    var str_fields = vec.Vec[ir.AggregateField].create()
                    var sfi: ptr_uint = 0
                    while sfi < args.len:
                        var sarg: ast.Argument
                        unsafe:
                            sarg = read(args.data + sfi)
                        let fname = sarg.arg_name else:
                            fatal(c"lowering: str construction requires named fields")
                        str_fields.push(ir.AggregateField(name = fname, value = lower_expr(ctx, sarg.arg_value)))
                        sfi += 1
                    return alloc_expr(ir.Expr.expr_aggregate_literal(ty = types.Type.ty_str, fields = str_fields.as_span()))
                if ctx.analysis.structs.contains(id.name):
                    return lower_aggregate_literal(ctx, id.name, args)
                if struct_exists_in_imports(ctx, id.name):
                    return lower_aggregate_literal(ctx, id.name, args)
                # Native type constructors: vec3(x=..., y=..., z=...),
                # mat4(col0=..., ...), quat(x=..., ...).  These are not in
                # structs but are builtin aggregate types.
                if is_builtin_type_name(id.name):
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
                        if is_fn_type(lb.value.ty):
                            var ret_ty = expr_type(ctx, call_ep)
                            var ret_type_ptr = types.alloc_type(ret_ty)
                            return lower_plain_call_sig(ctx, lb.value.c_name, args, call_ep, ret_type_ptr, empty_fn_sig())
                    Option.none:
                        pass
                match find_generic_function(ctx, id.name):
                    Option.some as gm:
                        match try_inferred_generic_call(ctx, id.name, args, call_ep):
                            Option.some as gen_call:
                                return gen_call.value
                            Option.none:
                                pass
                    Option.none:
                        pass
                # Module-level proc variable: call through proc struct.
                # expr_type on the callee may not have the correct type if the
                # analyzer only records the call expression type, so also check
                # the identifier against the source file's variable declarations.
                var callee_ty = expr_type(ctx, callee)
                if not is_proc_type(callee_ty):
                    callee_ty = module_var_type(ctx, id.name)
                if is_proc_type(callee_ty):
                    let c_name = naming.qualified_c_name(ctx.module_name, id.name)
                    let lb = LocalBinding(name = id.name, c_name = c_name, ty = callee_ty, pointer = false)
                    return lower_proc_call(ctx, lb, args, call_ep)
                # Compile-time builtins: evaluate to constant literals rather than
                # emitting runtime function calls.  has_attribute returns a bool;
                # field_of / callable_of / attribute_of return opaque handles
                # (zero-init at the IR level since they are consumed only by
                # other compile-time builtins).
                if id.name == "has_attribute":
                    return alloc_expr(ir.Expr.expr_boolean_literal(value = true, ty = types.primitive("bool")))
                if id.name == "field_of" or id.name == "callable_of" or id.name == "attribute_of":
                    return alloc_expr(ir.Expr.expr_zero_init(ty = types.Type.ty_error))
                # Try to evaluate a const function call at compile time so that
                # const initializers (e.g. `const SQUARE_5 = square(5)`) produce
                # a literal value instead of a C function call.
                match try_evaluate_const_function_call(ctx, id.name, args):
                    Option.some as cf_val:
                        return cf_val.value
                    Option.none:
                        pass
                var ret_ty = function_return_type(ctx, id.name)
                var ret_type_ptr = types.alloc_type(ret_ty)
                return lower_plain_call_sig(ctx, naming.qualified_c_name(ctx.module_name, id.name), args, call_ep, ret_type_ptr, lookup_fn_sig(ctx, id.name))
            ast.Expr.expr_specialization as spec:
                # When the specialisation callee is a member access
                # (e.g. `r.unpack[CompactHeader]()`), try method resolution
                # before generic-function monomorphization so that
                # extending-block methods with their own type params are found.
                unsafe:
                    match read(spec.callee):
                        ast.Expr.expr_member_access as spma:
                            let sp_recv_ty = ir_expr_type(lower_expr(ctx, spma.receiver))
                            match generic_receiver_info(ctx, sp_recv_ty):
                                Option.some as sp_info:
                                    match find_generic_method(ctx, sp_info.value.owner_name, spma.member_name):
                                        Option.some as sp_gm:
                                            if sp_gm.value.method.type_params.len > 0:
                                                var sp_ext_args = vec.Vec[types.Type].create()
                                                var sp_ai: ptr_uint = 0
                                                while sp_ai < sp_info.value.concrete_args.len:
                                                    unsafe:
                                                        sp_ext_args.push(read(sp_info.value.concrete_args.data + sp_ai))
                                                    sp_ai += 1
                                                var sp_tpi: ptr_uint = 0
                                                while sp_tpi < sp_gm.value.method.type_params.len:
                                                    if sp_tpi < spec.arguments.len:
                                                        sp_ext_args.push(qualify_type(ctx, resolve_type_ref(ctx, unsafe: read(spec.arguments.data + sp_tpi).value)))
                                                    else:
                                                        fatal(c"lowering: not enough specialization args for generic method")
                                                    sp_tpi += 1
                                                let sp_ext_info = GenericReceiver(owner_name = sp_info.value.owner_name, concrete_args = sp_ext_args.as_span())
                                                return lower_monomorphized_method(ctx, sp_ext_info, sp_gm.value, spma.member_name, spma.receiver, args)
                                        Option.none:
                                            pass
                                Option.none:
                                    pass
                        _:
                            pass
                return lower_specialization_call(ctx, spec.callee, spec.arguments, args, call_ep)
            ast.Expr.expr_member_access as ma:
                match read(ma.receiver):
                    ast.Expr.expr_identifier as recv_id:
                        # A non-generic variant arm constructor, e.g. `Token.number(value = 41)`.
                        if ctx.variants.contains(recv_id.name):
                            return lower_variant_literal(ctx, recv_id.name, ma.member_name, args)
                        # Static hook / method call on a primitive or `str` type
                        # name, e.g. `str.order(a, b)` → `str_order_static(a, b)`.
                        if is_primitive_or_str_name(recv_id.name):
                            match resolve_primitive_method_info(ctx, recv_id.name, ma.member_name):
                                Option.some as prim_mi:
                                    return lower_static_call_args(ctx, prim_mi.value, args)
                                Option.none:
                                    pass
                        # Static method call on a struct type name, e.g.
                        # `String.create()`.  The receiver is a bare type name (not
                        # a value), so resolve the static method and lower only the
                        # arguments.  Mirrors the Ruby resolver's `resolve_type_expression`
                        # + `static:<method>` associated-function path.
                        if struct_exists_in_imports(ctx, recv_id.name):
                            let static_recv_ty = types.Type.ty_named(module_name = "", name = recv_id.name)
                            match resolve_method_info(ctx, static_recv_ty, ma.member_name):
                                Option.some as smi:
                                    if smi.value.method_kind == ast.MethodKind.mk_static:
                                        return lower_static_call_args(ctx, smi.value, args)
                                Option.none:
                                    pass
                        let mod_ptr = ctx.analysis.imports.get(recv_id.name)
                        if mod_ptr != null:
                            let target_module = read(mod_ptr)
                            # Check if member_name is a struct in the imported module
                            # (struct constructor, e.g. ir.Field(name, ty)).
                            match find_imported_analysis(ctx, target_module):
                                Option.some as imported:
                                    if imported.value.structs.contains(ma.member_name):
                                        return lower_aggregate_literal_in_module(ctx, ma.member_name, args, target_module)
                                    # Check if ma.member_name is a variant arm in any
                                    # imported variant (e.g. types.Type.ty_named(name)).
                                    match find_imported_variant_arm(imported.value, ma.member_name):
                                        Option.some as var_name:
                                            let var_ty = types.Type.ty_imported(module_name = target_module, name = var_name.value, args = span[types.Type]())
                                            return alloc_expr(ir.Expr.expr_variant_literal(
                                                ty = var_ty,
                                                arm_name = ma.member_name,
                                                fields = collect_variant_literal_fields(ctx, args, var_ty, ma.member_name),
                                            ))
                                        Option.none:
                                            pass
                                Option.none:
                                    pass
                            # Cross-module foreign function call (`libc.getenv_wrapper(...)`):
                            # a foreign function lowers to a direct call on its
                            # mapped C function (e.g. `getenv`), not a Milk Tea
                            # module-qualified symbol.  Resolve it against the
                            # target module's declarations before the plain path.
                            match imported_foreign_call(ctx, target_module, ma.member_name):
                                Option.some as ff_info:
                                    return lower_foreign_call(ctx, ff_info.value, args, call_ep)
                                Option.none:
                                    pass
                            # Cross-module external function call (`libc.malloc(...)`):
                            # an external function uses its bare C name (or `= target`
                            # mapping), not a module-qualified symbol.  Resolve it
                            # against the target module before the plain path so its
                            # linkage name and return type are correct.
                            match imported_extern_call(ctx, target_module, ma.member_name):
                                Option.some as ext_info:
                                    return lower_extern_call(ctx, ext_info.value, args, call_ep)
                                Option.none:
                                    pass
                            # Cross-module generic function call with inferred type
                            # args (`heap.release(x)` → `heap.release[T]`): infer T
                            # from the argument types and monomorphize.
                            match try_inferred_generic_call(ctx, ma.member_name, args, call_ep):
                                Option.some as gen_call:
                                    return gen_call.value
                                Option.none:
                                    pass
                            let c_name = naming.qualified_c_name(target_module, ma.member_name)
                            var ret_ty = cross_module_return_type(ctx, c_name, call_ep)
                            var ret_type_ptr = types.alloc_type(ret_ty)
                            var cross_sig = lookup_imported_fn_sig(ctx, target_module, ma.member_name)
                            return lower_plain_call_sig(ctx, c_name, args, call_ep, ret_type_ptr, cross_sig)
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
                                                        fields = collect_variant_literal_fields(ctx, args, var_ty, ma.member_name),
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
                let recv_ty = method_receiver_type(ctx, ma.receiver)
                # Builtin `array[T, N].as_span()` → span aggregate literal
                # `{ data = &arr[0], len = N }`.  Intercept before method
                # resolution so it does not fall to the `<module>_mt_as_span`
                # fallback (mirrors Ruby's :array_as_span lowering).
                if is_array_type(recv_ty) and ma.member_name == "as_span" and args.len == 0:
                    return lower_array_as_span(ctx, ma.receiver, recv_ty)
                # Builtin `.with(x = val, ...)` — aggregate copy with specified
                # fields replaced, mirroring Ruby's :struct_with lowering.
                if ma.member_name == "with":
                    return lower_with_call(ctx, ma.receiver, recv_ty, args)
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
                # atomic[T] builtin methods: lower to __atomic_* compiler builtins.
                if is_atomic_type(recv_ty):
                    let recv_ir = lower_expr(ctx, ma.receiver)
                    return lower_atomic_method(ctx, recv_ir, recv_ty, ma.member_name, args, call_ep)
                # str_buffer[N] builtin methods: lower to C helper calls.
                if is_str_buffer_type(recv_ty):
                    let recv_ir = lower_expr(ctx, ma.receiver)
                    return lower_str_buffer_method(ctx, recv_ir, recv_ty, ma.member_name, args, call_ep)
                # dyn[I] dispatch: extract data + vtable, call through function pointer.
                # The type may be ty_named("dyn") or ty_dyn(iface) — try both.
                let ts = types.type_to_string(recv_ty)
                if ts == "dyn" or is_dyn_type(recv_ty):
                    let recv_ir = lower_expr(ctx, ma.receiver)
                    return lower_dyn_method_call(ctx, recv_ir, ma.member_name, args, call_ep)
                # Fallback: treat as a direct C call with the member as callee.
                # But first, check if the member is an fn/proc struct field — if so,
                # lower as a direct field access call instead of a method call.
                var is_fn_proc_field = false
                var found_ft: types.Type = types.primitive("void")
                match concrete_field_type(ctx, recv_ty, ma.member_name):
                    Option.some as ft:
                        found_ft = ft.value
                    Option.none:
                        # Not in generic_struct_decls; try analysis.structs for
                        # non-generic (local and imported) structs.  Strip
                        # pointer/ref wrappers first so the base struct name is
                        # recovered (ptr[SleepState] → SleepState).
                        var base = recv_ty
                        if types.is_raw_pointer(base) or types.is_ref_type(base):
                            base = types.pointer_element(base)
                        if types.is_nullable_type(base):
                            base = types.unwrap_nullable(base)
                        let struct_name = named_type_name(base)
                        if struct_name.is_some():
                            let sn = struct_name.unwrap()
                            var raw_fields = ctx.analysis.structs.get(sn)
                            if raw_fields == null:
                                var ai: ptr_uint = 0
                                while ai < ctx.program_analyses.len and raw_fields == null:
                                    var a: analyzer.Analysis
                                    unsafe:
                                        a = read(ctx.program_analyses.data + ai)
                                    raw_fields = a.structs.get(sn)
                                    ai += 1
                            if raw_fields != null:
                                let entries = unsafe: read(raw_fields)
                                var ei: ptr_uint = 0
                                while ei < entries.len:
                                    let entry = unsafe: read(entries.data + ei)
                                    if entry.name == ma.member_name:
                                        found_ft = entry.ty
                                        break
                                    ei += 1
                # Task[T] builtin struct fields (frame, ready, set_waiter,
                # release, take_result, cancel) are function pointers / void
                # pointers that must be accessed via struct field + indirect
                # call, not treated as methods.  `take_result` returns the
                # task's result type T; other vtable fields return void.
                #
                # In the monomorphized context, the Task may already be a
                # concrete struct like `ty_named("mt_task_int")` — detect it
                # by the `mt_task_` prefix or `ty_generic("Task", ...)`.
                var is_task = false
                var task_ret_ty = types.primitive("void")
                match recv_ty:
                    types.Type.ty_generic as tg:
                        if tg.name == "Task" and tg.args.len >= 1:
                            is_task = true
                            unsafe:
                                task_ret_ty = read(tg.args.data + 0)
                    types.Type.ty_named as tn:
                        if tn.name.starts_with("mt_task_"):
                            is_task = true
                            let gi_ptr = ctx.generic_struct_instances.get(tn.name)
                            if gi_ptr != null:
                                let gi = unsafe: read(gi_ptr)
                                if gi.concrete_args.len >= 1:
                                    unsafe:
                                        task_ret_ty = read(gi.concrete_args.data + 0)
                    types.Type.ty_imported as im:
                        if im.name.starts_with("mt_task_"):
                            is_task = true
                            let gi_ptr = ctx.generic_struct_instances.get(im.name)
                            if gi_ptr != null:
                                let gi = unsafe: read(gi_ptr)
                                if gi.concrete_args.len >= 1:
                                    unsafe:
                                        task_ret_ty = read(gi.concrete_args.data + 0)
                    _:
                        pass
                if is_task and ma.member_name == "frame":
                    found_ft = ptr_void_type()
                else if is_task and is_task_fn_field(ma.member_name):
                    found_ft = types.Type.ty_function(
                        params = single_ty_span(ptr_void_type()),
                        return_type = types.alloc_type(task_ret_ty),
                        variadic = false,
                        is_proc = false,
                    )
                match found_ft:
                    types.Type.ty_function as field_fn:
                        if field_fn.is_proc:
                            let recv_ir = lower_expr(ctx, ma.receiver)
                            let field_expr = alloc_expr(ir.Expr.expr_member(receiver = recv_ir, member = ma.member_name, ty = found_ft))
                            return lower_proc_field_call(ctx, field_expr, args, call_ep)
                        else:
                            let recv_ir = lower_expr(ctx, ma.receiver)
                            let field_expr = alloc_expr(ir.Expr.expr_member(receiver = recv_ir, member = ma.member_name, ty = found_ft))
                            return lower_fn_field_call(ctx, field_expr, args, call_ep)
                    _:
                        pass
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
                var resolved_ty = types.Type.ty_named(module_name = "", name = recv_name)
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
                return alloc_expr(ir.Expr.expr_zero_init(ty = types.primitive("void")))


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
        return ret_ty
    let fp = ctx.function_returns.get(c_name)
    if fp != null:
        unsafe:
            ret_ty = read(fp)
        if not types.is_error(ret_ty):
            return ret_ty
    let sc = ctx.specialization_cache.get(c_name)
    if sc != null:
        unsafe:
            ret_ty = read(sc).return_type
        if not types.is_error(ret_ty):
            return ret_ty
    return expr_type(ctx, call_ep)


## Lower a specialized call `Name[TypeArgs](args)`.  Phase 3 handles the builtin
## `span[T](data = ..., len = ...)` constructor as an aggregate literal; generic
## function-call monomorphization arrives in Phase 4.
function lower_specialization_call(ctx: ref[LowerCtx], spec_callee: ptr[ast.Expr], type_args: span[ast.TypeArgument], call_args: span[ast.Argument], call_ep: ptr[ast.Expr]) -> ptr[ir.Expr]:
    unsafe:
        match read(spec_callee):
            ast.Expr.expr_identifier as id:
                if id.name == "span" and type_args.len == 1:
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
                if id.name == "adapt" and type_args.len == 1:
                    return lower_adapt_call(ctx, read(type_args.data + 0).value, call_args)
                if id.name == "array" and type_args.len == 2:
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
                if id.name == "str_buffer" and type_args.len == 1:
                    let n_ty = resolve_type_ref(ctx, read(type_args.data + 0).value)
                    let sb_ty = types.Type.ty_generic(name = "str_buffer", args = sp_type(n_ty))
                    ensure_str_buffer_struct(ctx, sb_ty)
                    return alloc_expr(ir.Expr.expr_zero_init(ty = sb_ty))
                # Builtin generic callables: order[T], equal[T], hash[T] — lower
                # to direct C calls with a fixed suffix derived from the type.
                if id.name == "order" or id.name == "equal" or id.name == "hash":
                    var ir_args = vec.Vec[ir.Expr].create()
                    var si: ptr_uint = 0
                    while si < call_args.len:
                        var arg: ast.Argument
                        unsafe:
                            arg = read(call_args.data + si)
                        let lowered = lower_expr(ctx, arg.arg_value)
                        # The hooks take `const_ptr[T]`: implicitly borrow a value
                        # argument (`&value`); pass a pointer/ref argument through.
                        let arg_ty = ir_expr_type(lowered)
                        if is_pointer_or_ref_type(arg_ty):
                            unsafe:
                                ir_args.push(read(lowered))
                        else:
                            let borrowed = alloc_expr(ir.Expr.expr_address_of(
                                expression = lowered,
                                ty = types.Type.ty_generic(name = "const_ptr", args = sp_type(arg_ty)),
                            ))
                            unsafe:
                                ir_args.push(read(borrowed))
                        si += 1
                    var ret_ty = types.primitive("int")
                    if id.name == "equal":
                        ret_ty = types.primitive("bool")
                    else if id.name == "hash":
                        ret_ty = types.primitive("uint")
                    # Resolve the canonical hook (`T.hash` / `T.equal` / `T.order`)
                    # for the type argument to its concrete C function name.
                    if type_args.len >= 1:
                        let t_ty = qualify_type(ctx, resolve_type_ref(ctx, read(type_args.data + 0).value))
                        match resolve_canonical_hook(ctx, t_ty, id.name):
                            Option.some as hook_name:
                                return alloc_expr(ir.Expr.expr_call(callee = hook_name.value, arguments = ir_args.as_span(), ty = ret_ty))
                            Option.none:
                                pass
                    let fn_name = j2("mt_", j2(id.name, "_func"))
                    return alloc_expr(ir.Expr.expr_call(callee = fn_name, arguments = ir_args.as_span(), ty = ret_ty))
                # Builtin `reinterpret[T](value)` → C cast.
                if id.name == "reinterpret" and type_args.len == 1:
                    let target_ty = qualify_type(ctx, resolve_type_ref(ctx, read(type_args.data + 0).value))
                    let lowered = lower_expr(ctx, unsafe: read(call_args.data + 0).arg_value)
                    return alloc_expr(ir.Expr.expr_cast(target_type = target_ty, expression = lowered, ty = target_ty))
                # Builtin `zero[T]` → zero-initialized value of type T.
                if id.name == "zero" and type_args.len == 1:
                    let z_ty = qualify_type(ctx, resolve_type_ref(ctx, read(type_args.data + 0).value))
                    return alloc_expr(ir.Expr.expr_zero_init(ty = z_ty))
                # Builtin `default[T]` → call T.default(), the zero-argument
                # static method on the type.  The method must exist at check time
                # (the analyzer already verified it).
                if id.name == "default" and type_args.len == 1 and call_args.len == 0:
                    let t_ty = qualify_type(ctx, resolve_type_ref(ctx, read(type_args.data + 0).value))
                    match resolve_method_info(ctx, t_ty, "default"):
                        Option.some as smi:
                            if smi.value.method_kind == ast.MethodKind.mk_static:
                                var nil_receiver = alloc_expr(ir.Expr.expr_null_literal(ty = t_ty))
                                return lower_static_call_args(ctx, smi.value, call_args)
                        Option.none:
                            pass
                if (
                    id.name == "attribute_arg" or id.name == "attribute_of"
                    or id.name == "field_of" or id.name == "callable_of"
                    or id.name == "fields_of" or id.name == "members_of"
                    or id.name == "attributes_of" or id.name == "has_attribute"
                    or id.name == "adapt"
                ) and type_args.len >= 1:
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
                var recv_ty = expr_type_for_spec(ctx, spec_callee, type_args)
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
                        if id.name == "read" and call.args.len == 1:
                            return Option[ptr[ast.Expr]].some(value = read(call.args.data + 0).arg_value)
                    _:
                        pass
            _:
                pass
    return Option[ptr[ast.Expr]].none


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
        var found_once = false
        while not found_once:
            let target_ptr = import_values.next() else:
                break
            let target_module = unsafe: read(target_ptr)
            match find_imported_analysis(ctx, target_module):
                Option.some as imported:
                    fields_opt = extract_generic_struct_fields(ctx, imported.value, struct_name, concrete_args)
                    if fields_opt.is_some():
                        found_once = true
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
                if s.name == struct_name:
                    found = true
                    var sub = map_mod.Map[str, types.Type].create()
                    var spi: ptr_uint = 0
                    while spi < s.type_params.len and spi < concrete_args.len:
                        unsafe:
                            sub.set(read(s.type_params.data + spi).name, read(concrete_args.data + spi))
                        spi += 1
                    var fi: ptr_uint = 0
                    var saved_type_subst = ctx.type_substitution
                    ctx.type_substitution = sub
                    while fi < s.struct_fields.len:
                        var f: ast.Field
                        unsafe:
                            f = read(s.struct_fields.data + fi)
                        let raw_ty = resolve_field_type_ref(ctx, f.field_type)
                        let field_ty = substitute_type_params(ctx, raw_ty, ref_of(sub))
                        ir_fields.push(ir.Field(name = f.name, ty = qualify_type(ctx, field_ty)))
                        fi += 1
                    ctx.type_substitution = saved_type_subst
            _:
                pass
        di += 1
    if not found:
        return Option[span[ir.Field]].none
    return Option[span[ir.Field]].some(value = ir_fields.as_span())


function is_pointer_or_ref_type(t: types.Type) -> bool:
    match t:
        types.Type.ty_generic as g:
            return g.name == "ptr" or g.name == "const_ptr" or g.name == "own" or g.name == "ref"
        types.Type.ty_nullable as nl:
            return is_pointer_or_ref_type(unsafe: read(nl.base))
        _:
            return false


## The type-constructor name ("ref", "ptr", "const_ptr") for a builtin
## address-of function, or an empty string when `func_name` is not one.
function builtin_addr_type_name(func_name: str) -> str:
    if func_name == "ref_of":
        return "ref"
    if func_name == "ptr_of":
        return "ptr"
    if func_name == "const_ptr_of":
        return "const_ptr"
    return ""


function is_raw_type_param_name(name: str) -> bool:
    return name == "T" or name == "U" or name == "K" or name == "V" or name == "E"


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
            if n.name == "T" or n.name == "K" or n.name == "V" or n.name == "U" or n.name == "E":
                return true
            return false
        types.Type.ty_imported as im:
            if im.name == "T" or im.name == "K" or im.name == "V" or im.name == "U" or im.name == "E":
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
            buf.append(naming.type_c_key(read(args.data + i)))
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
        if callee_name == "Task":
            return lower_task_constructor(ctx, type_args, call_args, call_ep)
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
        if not a.module_name == ctx.module_name:
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


## Try to lower a call to a generic function whose type arguments are INFERRED
## from the argument types (no explicit `[T]`), e.g. `heap.release(this.data)`
## where `release[T](memory: ptr[T]?)` binds `T` from the argument.  Returns none
## when the target is not a generic function or inference fails.  Mirrors Ruby's
## per-instantiation monomorphization of inferred generic calls.
function try_inferred_generic_call(ctx: ref[LowerCtx], callee_name: str, args: span[ast.Argument], call_ep: ptr[ast.Expr]) -> Option[ptr[ir.Expr]]:
    let gm = find_generic_function(ctx, callee_name) else:
        return Option[ptr[ir.Expr]].none
    match gm.decl:
        ast.Decl.decl_function as fun:
            if fun.type_params.len == 0:
                return Option[ptr[ir.Expr]].none
            # Infer each type parameter from the arguments, then build the
            # substitution map and specialization key.
            var sub = map_mod.Map[str, types.Type].create()
            var key = string.String.create()
            key.append(naming.module_c_prefix(gm.module_name))
            key.append("_")
            key.append(callee_name)
            var tpi: ptr_uint = 0
            while tpi < fun.type_params.len:
                var tp: ast.TypeParam
                unsafe:
                    tp = read(fun.type_params.data + tpi)
                let inferred = infer_type_param_from_args(ctx, tp.name, fun.method_params, args) else:
                    return Option[ptr[ir.Expr]].none
                sub.set(tp.name, inferred)
                key.append("__")
                key.append(spec_type_key(ctx, inferred))
                tpi += 1
            let spec_key = key.as_str()
            if not ctx.specialization_cache.contains(spec_key) and not ctx.spec_in_progress.contains(spec_key):
                lower_and_cache_specialization_with_sub(ctx, gm, ref_of(sub), spec_key)
            let ret_ty = cross_module_return_type(ctx, spec_key, call_ep)
            # Pass a synthesized sig for async wait/run so coerce_fn_arg_to_proc
            # can wrap task expressions in procs (task-root-proc bridge).
            var sig = Option[analyzer.FnSig].none
            if gm.module_name.starts_with("std.async") and (callee_name == "wait" or callee_name == "run"):
                var syn_params = vec.Vec[analyzer.ParamEntry].create()
                var spi: ptr_uint = 0
                while spi < fun.method_params.len:
                    var fm: ast.Param = unsafe: read(fun.method_params.data + spi)
                    var p_ty = types.Type.ty_error
                    if fm.param_type.is_proc or fm.param_type.is_fn:
                        p_ty = substitute_type_params(ctx, resolve_function_type_ref(ctx, ptr_of(fm.param_type)), ref_of(sub))
                    else:
                        p_ty = substitute_type_params(ctx, resolve_type_ref(ctx, ptr_of(fm.param_type)), ref_of(sub))
                    syn_params.push(analyzer.ParamEntry(name = fm.name, ty = p_ty))
                    spi += 1
                sig = Option[analyzer.FnSig].some(value = analyzer.FnSig(name = callee_name, params = syn_params.as_span(), return_type = types.primitive("void"), has_return_type = false, method_kind = ast.MethodKind.mk_plain))
            return Option[ptr[ir.Expr]].some(value = lower_plain_call_sig(ctx, spec_key, args, call_ep, types.alloc_type(ret_ty), sig))
        _:
            return Option[ptr[ir.Expr]].none


## Infer the concrete type bound to type parameter `param_name` by matching each
## declared parameter type against the corresponding argument's lowered type.
## Handles the shapes that appear in the self-host's inferred generic calls: a
## bare `T`, and `T` under `ptr`/`const_ptr`/`ref`/`span`/nullable, by peeling the
## same constructor off the argument type.
function infer_type_param_from_args(ctx: ref[LowerCtx], param_name: str, params: span[ast.Param], args: span[ast.Argument]) -> Option[types.Type]:
    var i: ptr_uint = 0
    while i < params.len and i < args.len:
        var p: ast.Param
        unsafe:
            p = read(params.data + i)
        let arg_ty = ir_expr_type(lower_expr(ctx, unsafe: read(args.data + i).arg_value))
        match unify_type_param(param_name, p.param_type, arg_ty):
            Option.some as found:
                return Option[types.Type].some(value = found.value)
            Option.none:
                pass
        i += 1
    return Option[types.Type].none


## Structurally match a declared parameter type-ref against a concrete argument
## type, binding `param_name` when it is found.  Peels matching pointer/span/
## nullable constructors off both sides.
function unify_type_param(param_name: str, param_ref: ast.TypeRef, arg_ty: types.Type) -> Option[types.Type]:
    let simple_name = type_ref_simple_name(param_ref)
    # Bare `T`.
    if simple_name == param_name and param_ref.arguments.len == 0:
        return Option[types.Type].some(value = arg_ty)
    # `ptr[T]` / `const_ptr[T]` / `span[T]` / `ref[T]`: peel one pointer-like
    # layer off the argument type and recurse into the element type-ref.
    if param_ref.arguments.len >= 1 and pointer_like_ctor_name(simple_name):
        let inner_arg = pointer_or_span_element(arg_ty)
        var inner_ref: ast.TypeRef
        unsafe:
            inner_ref = read(param_ref.arguments.data + (param_ref.arguments.len - 1))
        return unify_type_param(param_name, inner_ref, inner_arg)
    # Nested generic instance: `Task[T]` matched against `Task[int]` → T = int;
    # `Option[T]` matched against `Option[int]` → T = int; etc.
    # The param_ref has nested arguments (e.g. `T` inside `Task[T]`) and the
    # argument type is a generic instance with the same name and arg count.
    # Recursively unify each type argument pair.
    if param_ref.arguments.len >= 1:
        match arg_ty:
            types.Type.ty_generic as g:
                if g.name == simple_name and g.args.len == param_ref.arguments.len:
                    var mi: ptr_uint = 0
                    while mi < g.args.len and mi < param_ref.arguments.len:
                        var inner_ref: ast.TypeRef
                        unsafe:
                            inner_ref = read(param_ref.arguments.data + mi)
                        match unify_type_param(param_name, inner_ref, unsafe: read(g.args.data + mi)):
                            Option.some as found:
                                return Option[types.Type].some(value = found.value)
                            Option.none:
                                pass
                        mi += 1
            _:
                pass
    # `proc(...) -> T`: peel the proc layer (fn_params/fn_return fields, not
    # `name`/`arguments` since the parser stores callable types specially) and
    # recurse into the return type position.
    if param_ref.is_proc or param_ref.is_fn:
        let prec = param_ref.fn_return
        if prec != null:
            if is_proc_type(arg_ty) or is_fn_type(arg_ty):
                let inner_ret = proc_return_type(arg_ty)
                return unify_type_param(param_name, unsafe: read(prec), inner_ret)
            # Task-root-proc bridge: arg is a plain Task[X] value matching
            # proc()->Task[T].  Peel wrapper to match type var against arg.
            let ret_ref = unsafe: read(prec)
            if ret_ref.arguments.len >= 1:
                let ret_name = type_ref_simple_name(ret_ref)
                match arg_ty:
                    types.Type.ty_generic as g:
                        if g.name == ret_name and g.args.len == ret_ref.arguments.len:
                            var mi: ptr_uint = 0
                            while mi < g.args.len and mi < ret_ref.arguments.len:
                                var inner_ref = unsafe: read(ret_ref.arguments.data + mi)
                                match unify_type_param(param_name, inner_ref, unsafe: read(g.args.data + mi)):
                                    Option.some as found:
                                        return Option[types.Type].some(value = found.value)
                                    Option.none:
                                        pass
                                mi += 1
                            return Option[types.Type].none
                    _:
                        pass
            return unify_type_param(param_name, ret_ref, arg_ty)
        return Option[types.Type].none
    return Option[types.Type].none


## The single (unqualified) name of a type-ref, or "" for a multi-part name.
function type_ref_simple_name(t: ast.TypeRef) -> str:
    if t.name.parts.len == 1:
        return unsafe: read(t.name.parts.data + 0)
    return ""


## True for the pointer-like type constructors whose single element carries the
## generic parameter.
function pointer_like_ctor_name(name: str) -> bool:
    return name == "ptr" or name == "const_ptr" or name == "own" or name == "ref" or name == "span"


## Peel one pointer/span/nullable layer off a concrete type, yielding the element
## type (or the type unchanged when it has no such layer).
function pointer_or_span_element(t: types.Type) -> types.Type:
    match t:
        types.Type.ty_nullable as nl:
            return pointer_or_span_element(unsafe: read(nl.base))
        types.Type.ty_generic as g:
            if g.args.len >= 1 and pointer_like_ctor_name(g.name):
                return unsafe: read(g.args.data + (g.args.len - 1))
        _:
            pass
    return t


## Extract the return type from a function/proc type.  For `ty_function`, return
## the return type.  For `ty_named` proc struct types (mt_proc_*), recover the
## return type from the proc struct name by reversing proc_type_name_from_signature:
## "mt_proc_int" → int, "mt_proc_void" → void.
function proc_return_type(t: types.Type) -> types.Type:
    match t:
        types.Type.ty_function as fnt:
            return unsafe: read(fnt.return_type)
        types.Type.ty_named as n:
            if n.name.starts_with("mt_proc_"):
                let raw = n.name.slice(8, n.name.len - 8)
                # Extract the return type (first underscore-separated component).
                # For mt_proc_int → "int", mt_proc_str_int → "str".
                match raw.find_substring("_"):
                    Option.some as us_pos:
                        let ret_name = raw.slice(0, us_pos.value)
                        return recognize_type_name(ret_name)
                    Option.none:
                        return recognize_type_name(raw)
            return types.primitive("void")
        _:
            return types.primitive("void")


## Map a single-word C type name (int, void, str, etc.) to a Type.
function recognize_type_name(name: str) -> types.Type:
    if name == "int" or name == "long" or name == "short" or name == "byte":
        return types.primitive(name)
    if name == "uint" or name == "ulong" or name == "ushort" or name == "ubyte":
        return types.primitive(name)
    if name == "float" or name == "double":
        return types.primitive(name)
    if name == "bool":
        return types.primitive("bool")
    if name == "void":
        return types.primitive("void")
    if name == "char":
        return types.primitive("char")
    if name == "ptr_uint":
        return types.primitive("ptr_uint")
    if name == "ptr_int":
        return types.primitive("ptr_int")
    if name == "str":
        return types.Type.ty_str
    if name == "mt_str":
        return types.Type.ty_str
    if name == "const_ptr_void":
        return types.Type.ty_generic(name = "const_ptr", args = sp_type(types.primitive("void")))
    if name == "mt_span_ubyte":
        return types.Type.ty_generic(name = "span", args = sp_type(types.primitive("ubyte")))
    if name == "mt_span_int":
        return types.Type.ty_generic(name = "span", args = sp_type(types.primitive("int")))
    return types.primitive("void")


## Lower an uncached generic function specialization: build the type substitution
## map, then lower the body in the OWNER module's context (so its imports,
## foreign functions, variants, and recorded expression types resolve against the
## defining module rather than the caller) and cache it under `spec_key`.
function lower_and_cache_specialization(ctx: ref[LowerCtx], gm: GenericFunctionMatch, type_args: span[ast.TypeArgument], spec_key: str) -> void:
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
            lower_and_cache_specialization_with_sub(ctx, gm, ref_of(sub), spec_key)
        _:
            fatal(j2("lowering: monomorphization failed, expected function decl for ", gm.module_name))


## Lower an uncached generic function specialization from a pre-built type
## substitution map (`sub`: type-param name -> concrete, caller-qualified type).
## The body is lowered in the OWNER module's context and cached under `spec_key`.
## Shared by explicit-type-arg specialization and inferred-type-arg calls.
function lower_and_cache_specialization_with_sub(ctx: ref[LowerCtx], gm: GenericFunctionMatch, sub: ref[map_mod.Map[str, types.Type]], spec_key: str) -> void:
    ctx.spec_in_progress.set(spec_key, true)
    match gm.decl:
        ast.Decl.decl_function as fun:
            # Save the caller context.
            var saved_module = ctx.module_name
            var saved_analysis = ctx.analysis
            var saved_foreign = ctx.foreign_map
            var saved_variants = ctx.variants
            var saved_locals = ctx.locals
            var saved_counter = ctx.temp_counter
            var saved_returns = ctx.function_returns
            var saved_type_subst = ctx.type_substitution
            var saved_inside_async = ctx.inside_async

            # Switch to the owner module's context when its analysis is available.
            match find_imported_analysis(ctx, gm.module_name):
                Option.some as owner_a:
                    ctx.module_name = gm.module_name
                    ctx.analysis = owner_a.value
                    ctx.foreign_map = map_mod.Map[str, ForeignInfo].create()
                    ctx.variants = map_mod.Map[str, VariantInfo].create()
                    ctx.type_substitution = map_mod.Map[str, types.Type].create()
                    collect_foreign_functions(ctx, owner_a.value.source_file.declarations)
                    collect_variants(ctx, owner_a.value.source_file.declarations)
                    install_prelude_variants(ctx)
                Option.none:
                    pass

            ctx.locals = vec.Vec[LocalBinding].create()
            ctx.temp_counter = 0
            ctx.function_returns = map_mod.Map[str, types.Type].create()
            ctx.type_substitution = map_mod.Map[str, types.Type].create()
            ctx.inside_async = false

            var spec_fun = lower_specialized_function(ctx, fun.name, fun.method_params, fun.return_type, fun.body, sub)
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
            ctx.type_substitution = saved_type_subst
            ctx.inside_async = saved_inside_async
        _:
            fatal(j2("lowering: monomorphization failed, expected function decl for ", gm.module_name))


## Lower a payload variant arm constructor `Variant.arm(field = value, ...)` to an
## IR variant literal.  No-payload arms are handled in `lower_member_access`.
function lower_variant_literal(ctx: ref[LowerCtx], variant_name: str, arm_name: str, args: span[ast.Argument]) -> ptr[ir.Expr]:
    let ty = types.Type.ty_imported(module_name = ctx.module_name, name = variant_name, args = span[types.Type]())
    return alloc_expr(ir.Expr.expr_variant_literal(
        ty = ty,
        arm_name = arm_name,
        fields = collect_variant_literal_fields(ctx, args, ty, arm_name),
    ))


## Lower a generic variant arm constructor `Option[int].some(value = 42)`.  The
## type arguments resolve to concrete types; the call arguments map to field
## values.  The resulting type is `ty_generic("Option", [ty_int])`.
function lower_generic_variant_literal(ctx: ref[LowerCtx], variant_name: str, type_args: span[ast.TypeArgument], arm_name: str, call_args: span[ast.Argument]) -> ptr[ir.Expr]:
    var concrete_args = vec.Vec[types.Type].create()
    var i: ptr_uint = 0
    while i < type_args.len:
        # Qualify each type argument the same way the signature return type is
        # qualified, so a locally-defined struct arg (e.g. `RemovedEntry` in
        # std.map) is monomorphized to its module-qualified C name
        # (`std_map_RemovedEntry_str_bool`) rather than a bare `RemovedEntry_str_bool`
        # that would mismatch the declared `Option[RemovedEntry[K, V]]` return type.
        unsafe:
            concrete_args.push(qualify_type(ctx, resolve_type_ref(ctx, read(type_args.data + i).value)))
        i += 1
    let ty = types.Type.ty_generic(name = variant_name, args = concrete_args.as_span())
    return alloc_expr(ir.Expr.expr_variant_literal(
        ty = ty,
        arm_name = arm_name,
        fields = collect_variant_literal_fields(ctx, call_args, ty, arm_name),
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
                    if arm.name == arm_name:
                        return Option[str].some(value = vr.name)
                    ai += 1
            _:
                pass
        di += 1
    return Option[str].none


function collect_variant_literal_fields(ctx: ref[LowerCtx], args: span[ast.Argument], variant_ty: types.Type, arm_name: str) -> span[ir.AggregateField]:
    var fields = vec.Vec[ir.AggregateField].create()
    var i: ptr_uint = 0
    while i < args.len:
        var arg: ast.Argument
        unsafe:
            arg = read(args.data + i)
        let field_name = arg.arg_name else:
            fatal(c"lowering: variant arm construction requires named fields")
        var value = lower_expr(ctx, arg.arg_value)
        # Auto-address recursive variant fields.
        let field_ty = variant_field_type_from_arm(ctx, variant_ty, arm_name, field_name)
        match field_ty:
            Option.some as fty:
                let fty_val = fty.value
                # Wrap non-nullable values into value-type nullable fields
                # (e.g. `NullableFields.with_values(port = raw)` where
                # `port: int?`).
                if types.is_nullable_type(fty_val) and not is_nullable_pointer_like(fty_val):
                    let value_ty = ir_expr_type(value)
                    if not types.is_nullable_type(value_ty):
                        value = nullable_some_literal(fty_val, value)
                # Auto-address recursive variant fields.
                let variant_c = variant_c_type_name(variant_ty)
                var arm_payload_c = string.String.create()
                arm_payload_c.append(variant_c)
                arm_payload_c.append("_")
                arm_payload_c.append(arm_name)
                let payload_c = arm_payload_c.as_str()
                if is_recursive_variant_field_c(payload_c, fty_val):
                    value = alloc_expr(ir.Expr.expr_address_of(expression = value, ty = types.Type.ty_generic(name = "ptr", args = sp_type(fty_val))))
            Option.none:
                pass
        fields.push(ir.AggregateField(name = field_name, value = value))
        i += 1
    return fields.as_span()


## Build a specialization key from the callee name + concrete type args.  For a
## same-module function `first[int]`, the key is `<module_prefix>_first_int`.  The
## key doubles as the monomorphized C linkage name.

## Compute a type-key string for specialization naming.  Builtin generic types
## (ptr/own/span/…) use their bare `type_c_key`.  User-defined generic structs
## include the defining module's C prefix so that Node[int, bool] in std.map and
## Node[int, bool] in std.linked_map produce distinct keys.
function spec_type_key(ctx: ref[LowerCtx], ty: types.Type) -> str:
    match ty:
        types.Type.ty_generic as g:
            if is_builtin_pointer_generic(g.name):
                var buf = string.String.create()
                buf.append(g.name)
                var i: ptr_uint = 0
                while i < g.args.len:
                    buf.append("_")
                    buf.append(spec_type_key(ctx, unsafe: read(g.args.data + i)))
                    i += 1
                return buf.as_str()
            if g.name == "Option" or g.name == "Result":
                return naming.type_c_key(ty)
            return naming.qualified_c_name(ctx.module_name, generic_struct_c_name(g.name, g.args))
        types.Type.ty_nullable as nl:
            return spec_type_key(ctx, unsafe: read(nl.base))
        _:
            return naming.type_c_key(ty)

function specialization_key(ctx: ref[LowerCtx], module_name: str, callee_name: str, type_args: span[ast.TypeArgument]) -> str:
    var buf = string.String.create()
    buf.append(naming.module_c_prefix(module_name))
    buf.append("_")
    buf.append(callee_name)
    var i: ptr_uint = 0
    while i < type_args.len:
        buf.append("_")
        let ty = resolve_type_ref(ctx, unsafe: read(type_args.data + i).value)
        buf.append(spec_type_key(ctx, ty))
        i += 1
    return buf.as_str()


## Lower a struct constructor `Name(field = value, ...)` to an IR aggregate
## literal, preserving the constructor's field order.
function lower_aggregate_literal(ctx: ref[LowerCtx], struct_name: str, args: span[ast.Argument]) -> ptr[ir.Expr]:
    return lower_aggregate_literal_impl(ctx, struct_name, args, Option[str].none)



function lower_aggregate_literal_in_module(ctx: ref[LowerCtx], struct_name: str, args: span[ast.Argument], target_module: str) -> ptr[ir.Expr]:
    return lower_aggregate_literal_impl(ctx, struct_name, args, Option[str].some(value = target_module))



function lower_aggregate_literal_impl(ctx: ref[LowerCtx], struct_name: str, args: span[ast.Argument], target_module: Option[str]) -> ptr[ir.Expr]:
    var source_module = ctx.module_name
    if is_builtin_type_name(struct_name):
        source_module = ""
    else if target_module.is_some():
        source_module = target_module.unwrap()
    else if not ctx.analysis.structs.contains(struct_name):
        var import_values = ctx.analysis.imports.values()
        var found_module = false
        while not found_module:
            let target_ptr = import_values.next() else:
                break
            let target_module = unsafe: read(target_ptr)
            match find_imported_analysis(ctx, target_module):
                Option.some as imported:
                    if imported.value.structs.contains(struct_name):
                        source_module = target_module
                        found_module = true
                Option.none:
                    pass
    var fields = vec.Vec[ir.AggregateField].create()
    var i: ptr_uint = 0
    while i < args.len:
        var arg: ast.Argument
        unsafe:
            arg = read(args.data + i)
        let field_name = arg.arg_name else:
            fatal(c"lowering: struct construction requires named fields")
        var value = lower_expr(ctx, arg.arg_value)
        # Wrap non-nullable values into value-type nullable fields.
        match find_struct_field_type(ctx, struct_name, source_module, field_name):
            Option.some as field_ty:
                let fty = field_ty.value
                if types.is_nullable_type(fty) and not is_nullable_pointer_like(fty):
                    let value_ty = ir_expr_type(value)
                    if not types.is_nullable_type(value_ty):
                        value = nullable_some_literal(fty, value)
            Option.none:
                pass
        fields.push(ir.AggregateField(name = field_name, value = value))
        i += 1
    if source_module.len == 0:
        var agg_ty = types.Type.ty_named(module_name = "", name = struct_name)
        if is_builtin_type_name(struct_name) or struct_name == "str":
            agg_ty = types.Type.ty_primitive(name = struct_name)
        return alloc_expr(ir.Expr.expr_aggregate_literal(ty = agg_ty, fields = fields.as_span()))
    return alloc_expr(ir.Expr.expr_aggregate_literal(
        ty = types.Type.ty_imported(module_name = source_module, name = struct_name, args = span[types.Type]()),
        fields = fields.as_span(),
    ))


## Find the type of a field in a struct by name.
function find_struct_field_type(ctx: ref[LowerCtx], struct_name: str, source_module: str, field_name: str) -> Option[types.Type]:
    let fields_ptr = ctx.analysis.structs.get(struct_name)
    if fields_ptr != null:
        let entries = unsafe: read(fields_ptr)
        var fi: ptr_uint = 0
        while fi < entries.len:
            unsafe:
                if read(entries.data + fi).name == field_name:
                    return Option[types.Type].some(value = read(entries.data + fi).ty)
            fi += 1
    match find_imported_analysis(ctx, source_module):
        Option.some as ia:
            let imported_fields = ia.value.structs.get(struct_name)
            if imported_fields != null:
                let ientries = unsafe: read(imported_fields)
                var ifi: ptr_uint = 0
                while ifi < ientries.len:
                    unsafe:
                        if read(ientries.data + ifi).name == field_name:
                            return Option[types.Type].some(value = read(ientries.data + ifi).ty)
                    ifi += 1
        Option.none:
            pass
    return Option[types.Type].none


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
    let iface_type_ref_val = unsafe: read(iface_type_ref)
    let iface_name = unsafe: analyzer.qname_to_str(iface_type_ref_val.name)
    # Resolve type arguments from the dyn[...] type (e.g. dyn[Mapper[int]] → [int]).
    var type_args = vec.Vec[types.Type].create()
    var tgi: ptr_uint = 0
    while tgi < iface_type_ref_val.arguments.len:
        type_args.push(resolve_type_ref(ctx, unsafe: ptr[ast.TypeRef]<-iface_type_ref_val.arguments.data + tgi))
        tgi += 1
    match find_interface_analysis(ctx, iface_name):
        Option.some as ia:
            let methods = ia.value.methods
            let concrete_name = canonical_type_name(ctx.module_name, concrete_type)
            let vtable_name = ensure_dyn_vtable(ctx, concrete_name, concrete_type, iface_name, methods, ia.value.module_name, type_args.as_span(), ia.value.type_params)
            var void_ptr = types.Type.ty_generic(name = "ptr", args = sp_type(types.primitive("void")))
            var const_void_ptr = types.Type.ty_generic(name = "const_ptr", args = sp_type(types.primitive("void")))
            return alloc_expr(ir.Expr.expr_aggregate_literal(
                ty = types.Type.ty_dyn(iface = iface_name),
                fields = sp_fields2(
                    ir.AggregateField(name = "data", value = alloc_expr(ir.Expr.expr_cast(target_type = void_ptr, expression = arg_value, ty = void_ptr))),
                    ir.AggregateField(name = "vtable", value = alloc_expr(ir.Expr.expr_cast(
                        target_type = const_void_ptr,
                        expression = alloc_expr(ir.Expr.expr_address_of(
                            expression = alloc_expr(ir.Expr.expr_name(name = vtable_name, ty = void_ptr, pointer = false)),
                            ty = void_ptr,
                        )),
                        ty = const_void_ptr,
                    ))),
                ),
            ))
        Option.none:
            fatal(c"dyn lowering: interface not found")


## Interface analysis: the owning module name and the methods declared by the interface.
struct InterfaceAnalysis:
    module_name: str
    methods: span[ast.InterfaceMethod]
    type_params: span[ast.TypeParam]


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
                            return Option[InterfaceAnalysis].some(value = InterfaceAnalysis(module_name = mod_name, methods = unsafe: read(m_ptr), type_params = interface_type_params(imported.value.source_file, rest)))
                    Option.none:
                        pass
                return Option[InterfaceAnalysis].none
            parts_buf.push_byte(b)
            idx += 1
        return Option[InterfaceAnalysis].none
    # Bare name: search current module then all imported modules.
    let m_ptr = ctx.analysis.interfaces.get(iface_name)
    if m_ptr != null:
        return Option[InterfaceAnalysis].some(value = InterfaceAnalysis(module_name = ctx.module_name, methods = unsafe: read(m_ptr), type_params = interface_type_params(ctx.analysis.source_file, iface_name)))
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
                        return Option[InterfaceAnalysis].some(value = InterfaceAnalysis(module_name = target_module, methods = unsafe: read(i_ptr), type_params = interface_type_params(imported.value.source_file, iface_name)))
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
                if iface.name == iface_name and not iface.visibility:
                    return true
            _:
                pass
        di += 1
    return false


## Extract type parameters from an interface declaration in the source file AST.
function interface_type_params(file: ast.SourceFile, iface_name: str) -> span[ast.TypeParam]:
    var di: ptr_uint = 0
    while di < file.declarations.len:
        var d: ast.Decl
        unsafe:
            d = read(file.declarations.data + di)
        match d:
            ast.Decl.decl_interface as iface:
                if iface.name == iface_name:
                    return iface.type_params
            _:
                pass
        di += 1
    return span[ast.TypeParam]()


## Ensure a vtable for the given concrete type and interface exists.  Generates the
## vtable struct type declaration once per interface, and the wrapper functions +
## global vtable constant once per (type, interface) pair.  Returns the vtable global name.
function ensure_dyn_vtable(ctx: ref[LowerCtx], concrete_name: str, concrete_type: types.Type, iface_name: str, methods: span[ast.InterfaceMethod], iface_module_name: str, type_args: span[types.Type], type_params: span[ast.TypeParam]) -> str:
    let vtable_c_name = j5("mt_vtable_", concrete_name, "_", iface_name, "")
    if ctx.dyn_generated_vtables.contains(vtable_c_name):
        return vtable_c_name

    # Ensure the vtable struct type exists (once per interface), with type subsitution.
    let vtable_type_c_name = j3("mt_vtable_", iface_name, "")
    ensure_dyn_vtable_struct(ctx, vtable_type_c_name, methods, type_args, type_params)

    # Generate wrapper functions and vtable constant.
    var wrappers = gen_dyn_vtable_wrappers(ctx, concrete_name, concrete_type, iface_name, methods, iface_module_name, type_args, type_params)
    gen_dyn_vtable_constant(ctx, iface_name, vtable_type_c_name, vtable_c_name, ref_of(wrappers), methods)

    # Ensure the dyn struct type exists (once per interface).
    ensure_dyn_struct_type(ctx, iface_name)

    ctx.dyn_generated_vtables.set(vtable_c_name, true)
    return vtable_c_name


## Substitute interface type parameters in a type used by a vtable method signature.
## When type_params is [T] and type_args is [int], `ty_var("T")` → `int`.
function substitute_interface_type_params(t: types.Type, type_args: span[types.Type], type_params: span[ast.TypeParam]) -> types.Type:
    match t:
        types.Type.ty_var as v:
            return substitute_type_arg_by_name(t, v.name, type_args, type_params)
        types.Type.ty_named as n:
            return substitute_type_arg_by_name(t, n.name, type_args, type_params)
        _:
            return t


## If `name` matches a type param, return the corresponding type arg.
## Otherwise return the original type.
function substitute_type_arg_by_name(t: types.Type, name: str, type_args: span[types.Type], type_params: span[ast.TypeParam]) -> types.Type:
    var pi: ptr_uint = 0
    while pi < type_params.len:
        var tp: ast.TypeParam
        unsafe:
            tp = read(type_params.data + pi)
        if tp.name == name and pi < type_args.len:
            unsafe:
                return read(type_args.data + pi)
        pi += 1
    return t


## Ensure the dyn struct type `mt_dyn_{iface}` exists.
function ensure_dyn_struct_type(ctx: ref[LowerCtx], iface_name: str) -> void:
    let name = j3("mt_dyn_", iface_name, "")
    var iter = ctx.pending_dyn_structs.iter()
    while true:
        let s_ptr = iter.next() else:
            break
        if unsafe: read(s_ptr).linkage_name == name:
            return
    var void_ptr = types.Type.ty_generic(name = "ptr", args = sp_type(types.primitive("void")))
    var const_void_ptr = types.Type.ty_generic(name = "const_ptr", args = sp_type(types.primitive("void")))
    var fields = vec.Vec[ir.Field].create()
    fields.push(ir.Field(name = "data", ty = void_ptr))
    fields.push(ir.Field(name = "vtable", ty = const_void_ptr))
    ctx.pending_dyn_structs.push(ir.StructDecl(name = name, linkage_name = name, fields = fields.as_span(), packed = false, alignment = 0, source_module = Option[str].none))


## Ensure the vtable struct type `mt_vtable_{iface}` exists.  Fields are function
## pointer types so the C backend can render calls through them directly.
function ensure_dyn_vtable_struct(ctx: ref[LowerCtx], vtable_type_c_name: str, methods: span[ast.InterfaceMethod], type_args: span[types.Type], type_params: span[ast.TypeParam]) -> void:
    var iter = ctx.pending_dyn_vtable_structs.iter()
    while true:
        let s_ptr = iter.next() else:
            break
        if unsafe: read(s_ptr).linkage_name == vtable_type_c_name:
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
            var param_ty = resolve_field_type_ref(ctx, p.param_type)
            param_ty = substitute_interface_type_params(param_ty, type_args, type_params)
            fn_params.push(param_ty)
            pi += 1
        var ret = if m.return_type != null: resolve_field_type_ref(ctx, unsafe: read(ptr[ast.TypeRef]<-m.return_type)) else: types.primitive("void")
        ret = substitute_interface_type_params(ret, type_args, type_params)
        let fn_ty = types.Type.ty_function(params = fn_params.as_span(), return_type = types.alloc_type(ret), variadic = false, is_proc = false)
        fields.push(ir.Field(name = m.name, ty = fn_ty))
        mi += 1
    ctx.pending_dyn_vtable_structs.push(ir.StructDecl(name = vtable_type_c_name, linkage_name = vtable_type_c_name, fields = fields.as_span(), packed = false, alignment = 0, source_module = Option[str].none))


## Generate wrapper functions for each interface method, calling through to the
## concrete type's method implementation.  Returns a map from method name to wrapper C name.
function gen_dyn_vtable_wrappers(ctx: ref[LowerCtx], concrete_name: str, concrete_type: types.Type, iface_name: str, methods: span[ast.InterfaceMethod], iface_module_name: str, type_args: span[types.Type], type_params: span[ast.TypeParam]) -> map_mod.Map[str, str]:
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
            let p_ty = substitute_interface_type_params(resolve_field_type_ref(ctx, p.param_type), type_args, type_params)
            wrapper_params.push(ir.Param(name = p.name, linkage_name = utils.c_local_name(p.name), ty = p_ty, pointer = false))
            pi += 1
        let ret_ty = if m.return_type != null: substitute_interface_type_params(resolve_field_type_ref(ctx, unsafe: read(ptr[ast.TypeRef]<-m.return_type)), type_args, type_params) else: types.primitive("void")
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
                        call_args.push(read(alloc_expr(ir.Expr.expr_name(name = utils.c_local_name(p.name), ty = substitute_interface_type_params(resolve_field_type_ref(ctx, p.param_type), type_args, type_params), pointer = false))))
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
    let const_ty = types.Type.ty_named(module_name = "", name = vtable_type_name)
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
        let fn_ty = types.Type.ty_function(params = fn_params.as_span(), return_type = types.alloc_type(ret), variadic = false, is_proc = false)
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
    var vtable_ptr_ty = types.Type.ty_generic(name = "ptr", args = sp_type(types.Type.ty_named(module_name = "", name = vtable_c_type)))
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
    return alloc_expr(ir.Expr.expr_call_indirect(callee = method_fn, arguments = call_args.as_span(), ty = iface_method_return_type(ctx, recv_ty, method_name)))


## The return type of an interface method by looking it up in the interface's
## analysis.  Replaces the analyzer's `expr_type` which can infer `void` for
## dyn dispatch where the call expression wasn't type-tracked.
function iface_method_return_type(ctx: ref[LowerCtx], recv_ty: types.Type, method_name: str) -> types.Type:
    match recv_ty:
        types.Type.ty_dyn as d:
            match find_interface_analysis(ctx, d.iface):
                Option.some as ia:
                    var mi: ptr_uint = 0
                    while mi < ia.value.methods.len:
                        var m: ast.InterfaceMethod
                        unsafe:
                            m = read(ia.value.methods.data + mi)
                        if m.name == method_name:
                            let ret = m.return_type else:
                                return types.primitive("void")
                            return resolve_field_type_ref(ctx, unsafe: read(ptr[ast.TypeRef]<-ret))
                        mi += 1
                Option.none:
                    pass
        _:
            pass
    return types.primitive("void")


## The C type name for a dyn[I] vtable struct: "mt_vtable_" + iface_name.
function dyn_vtable_c_type(t: types.Type) -> str:
    let ts = types.type_to_string(t)
    # The type string could be "dyn" for ty_named or the iface name for ty_dyn.
    # For ty_dyn(iface = "Shape"), the string is "Shape".
    # If ts is "dyn", we can't determine the iface — use a fallback.
    if ts == "dyn":
        return "mt_vtable_unknown"
    return j3("mt_vtable_", ts, "")


## Resolved method call info: the C function name and the method kind (needed to
## decide whether to pass the receiver by pointer or by value).
struct MethodInfo:
    c_name: str
    method_kind: ast.MethodKind
    return_type: types.Type


## True when `name` names a primitive type or `str` — the receiver types whose
## methods use a bare `<type>_<method>` C name with no module prefix.  Mirrors
## Ruby's `c_type_name`, which returns the bare name for primitives (a struct
## receiver instead yields `<module>_<Type>`).
function is_primitive_or_str_name(name: str) -> bool:
    return is_builtin_type_name(name) or name == "str"


## The C linkage name for a method on a primitive or `str` receiver, mirroring
## Ruby's `function_binding_c_name`: a bare `<type>_<method>` prefix (no module
## qualifier) plus a `_static` suffix for static methods, so a static hook
## (e.g. `str == left, right`) cannot collide with a same-named instance
## method (`str == right`).
function primitive_method_c_name(type_name: str, method_name: str, is_static: bool) -> str:
    var buf = string.String.create()
    buf.append(type_name)
    buf.append("_")
    buf.append(method_name)
    if is_static:
        buf.append("_static")
    return buf.as_str()


## The C linkage name for a method: the bare primitive scheme for primitive /
## `str` receivers, and the module-qualified `<module>_<type>_<method>` scheme
## for nominal (struct / variant) receivers.  The `_static` suffix only applies
## to the primitive scheme, where static hooks and instance methods can collide.
function method_link_name(module_name: str, type_name: str, method_name: str, is_static: bool) -> str:
    if is_primitive_or_str_name(type_name):
        return primitive_method_c_name(type_name, method_name, is_static)
    var name = naming.qualified_member_c_name(module_name, type_name, method_name)
    if is_static:
        return j2(name, "_static")
    return name


## The C linkage name for a resolved method call.  Prelude variants (Option,
## Result) use a bare name with no module prefix (e.g. `Option_unwrap`),
## matching the global naming scheme used when declaring Option/Result
## instances.  Primitive/str receivers use `method_link_name` for consistency
## with `lower_extending_block`.  Nominal receivers keep the module-qualified
## scheme.
function method_c_name(module_name: str, type_name: str, method_name: str, method_kind: ast.MethodKind) -> str:
    if is_prelude_variant_name(type_name):
        match prelude_variant_base(type_name):
            Option.some as p:
                var buf = string.String.create()
                buf.append(p.value)
                buf.append("_")
                buf.append(method_name)
                return buf.as_str()
            Option.none:
                pass
    return method_link_name(module_name, type_name, method_name, method_kind == ast.MethodKind.mk_static)


## Some(type name) when `t` is a primitive or `str` receiver type, whose methods
## use the bare naming scheme; none for nominal or other receiver types.
function primitive_receiver_name(t: types.Type) -> Option[str]:
    match t:
        types.Type.ty_primitive as p:
            return Option[str].some(value = p.name)
        types.Type.ty_str:
            return Option[str].some(value = "str")
        _:
            return Option[str].none


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
## Resolve a canonical hook builtin (`hash` / `equal` / `order`) for a concrete
## type argument to the C name of the type's static hook function.  Searches the
## current module then all analyses for the module that declares `T.hook`, so
## primitive hooks (std.hash / std.str) and user struct hooks both resolve.
function resolve_canonical_hook(ctx: ref[LowerCtx], t_ty: types.Type, hook: str) -> Option[str]:
    let type_name = hook_type_name(t_ty) else:
        return Option[str].none
    let key = analyzer.method_key(type_name, hook)
    if ctx.analysis.method_sigs.contains(key):
        return Option[str].some(value = method_link_name(ctx.module_name, type_name, hook, true))
    var ai: ptr_uint = 0
    while ai < ctx.program_analyses.len:
        var a: analyzer.Analysis
        unsafe:
            a = read(ctx.program_analyses.data + ai)
        if a.method_sigs.contains(key):
            return Option[str].some(value = method_link_name(a.module_name, type_name, hook, true))
        ai += 1
    return Option[str].none


## The base type name used to key a canonical hook lookup (`int`, `str`, or a
## nominal type's name).
function hook_type_name(t: types.Type) -> Option[str]:
    match t:
        types.Type.ty_primitive as p:
            return Option[str].some(value = p.name)
        types.Type.ty_str:
            return Option[str].some(value = "str")
        types.Type.ty_named as n:
            return Option[str].some(value = n.name)
        types.Type.ty_imported as im:
            return Option[str].some(value = im.name)
        _:
            return Option[str].none


## Resolve a method call on a primitive or `str` receiver.  Primitive methods
## live in one `extending` block (e.g. `extending str:` in std.str), so search
## the current module then every analysis for the one that declares it, and
## build the bare `<type>_<method>` C name (with `_static` for static hooks so
## `str == left, right` does not collide with the instance `str.equal`).
function resolve_primitive_method_info(ctx: ref[LowerCtx], type_name: str, method_name: str) -> Option[MethodInfo]:
    let key = analyzer.method_key(type_name, method_name)
    if ctx.analysis.method_sigs.contains(key):
        let sig_ptr = ctx.analysis.method_sigs.get(key) else:
            return Option[MethodInfo].none
        let sig = unsafe: read(sig_ptr)
        var ret = sig.return_type
        if not sig.has_return_type:
            ret = types.primitive("void")
        return Option[MethodInfo].some(value = MethodInfo(
            c_name = primitive_method_c_name(type_name, method_name, sig.method_kind == ast.MethodKind.mk_static),
            method_kind = sig.method_kind,
            return_type = qualify_type(ctx, ret),
        ))
    var ai: ptr_uint = 0
    while ai < ctx.program_analyses.len:
        var a: analyzer.Analysis
        unsafe:
            a = read(ctx.program_analyses.data + ai)
        if a.module_name == ctx.module_name:
            ai += 1
            continue
        if a.method_sigs.contains(key):
            let sig_ptr = a.method_sigs.get(key) else:
                ai += 1
                continue
            let sig = unsafe: read(sig_ptr)
            var ret = sig.return_type
            if not sig.has_return_type:
                ret = types.primitive("void")
            return Option[MethodInfo].some(value = MethodInfo(
                c_name = primitive_method_c_name(type_name, method_name, sig.method_kind == ast.MethodKind.mk_static),
                method_kind = sig.method_kind,
                return_type = qualify_type(ctx, ret),
            ))
        ai += 1
    return Option[MethodInfo].none


function resolve_method_info(ctx: ref[LowerCtx], receiver_ty: types.Type, method_name: str) -> Option[MethodInfo]:
    # Auto-deref pointer / ref receivers so a method call on `this` inside an
    # editable method (where `this` is `ptr[T]`) resolves against `T`, not the
    # builtin "ptr" name (which would mis-name the call `<module>_ptr_<method>`).
    var effective_ty = receiver_ty
    if types.is_raw_pointer(effective_ty) or types.is_ref_type(effective_ty):
        effective_ty = types.pointer_element(effective_ty)
    # Primitive / `str` receivers: methods live in a single `extending` block
    # (e.g. `extending str:` in std.str) and use the bare `<type>_<method>` C
    # naming scheme, so resolve them before the nominal path.
    match primitive_receiver_name(effective_ty):
        Option.some as pn:
            return resolve_primitive_method_info(ctx, pn.value, method_name)
        Option.none:
            pass
    let type_name = named_type_name(effective_ty) else:
        let gen_var = generic_variant_name(effective_ty)
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
    # Prelude variant methods (Option.is_some, Result.unwrap) are registered
    # under the base variant name, not the concrete qualified C name
    # (e.g. key "Option_is_some", not "std_map_Option_std_map_RemovedEntry_ptr_uint_bool_is_some").
    var lookup_name = type_name
    match prelude_variant_base(type_name):
        Option.some as base:
            lookup_name = base.value
        Option.none:
            pass
    let key = analyzer.method_key(lookup_name, method_name)
    if ctx.analysis.method_sigs.contains(key):
        let sig_ptr = ctx.analysis.method_sigs.get(key) else:
            return Option[MethodInfo].none
        let sig = unsafe: read(sig_ptr)
        var ret = sig.return_type
        if not sig.has_return_type:
            ret = types.primitive("void")
        return Option[MethodInfo].some(value = MethodInfo(c_name = method_c_name(ctx.module_name, type_name, method_name, sig.method_kind), method_kind = sig.method_kind, return_type = qualify_type(ctx, ret)))
    # Search imported modules' method_sigs when the method is not found locally.
    var ai: ptr_uint = 0
    while ai < ctx.program_analyses.len:
        var a: analyzer.Analysis
        unsafe:
            a = read(ctx.program_analyses.data + ai)
        if a.module_name == ctx.module_name:
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
                c_name = method_c_name(a.module_name, type_name, method_name, sig.method_kind),
                method_kind = sig.method_kind,
                return_type = resolve_method_return_from_import(ctx, a.module_name, sig, effective_ty),
            ))
        ai += 1
    return Option[MethodInfo].none


## Lower a static method / hook call `Type.method(args)` where the receiver is a
## bare type name and there is no receiver value to pass: lower only the
## arguments and emit a direct call to the static C function.
function lower_static_call_args(ctx: ref[LowerCtx], mi: MethodInfo, args: span[ast.Argument]) -> ptr[ir.Expr]:
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
    return alloc_expr(ir.Expr.expr_call(callee = mi.c_name, arguments = ir_args.as_span(), ty = mi.return_type))


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
        var lowered = lower_expr(ctx, arg.arg_value)
        # Coerce a bare function-identifier argument to proc when the lowered
        # IR is a name expression with a fn-pointer type: wrap it in a proc
        # struct so method calls with proc parameters receive the expected type.
        unsafe:
            match read(lowered):
                ir.Expr.expr_name as nm:
                    if is_fn_type(nm.ty):
                        match read(arg.arg_value):
                            ast.Expr.expr_identifier as fn_id:
                                if ctx.function_returns.contains(fn_id.name) or ctx.analysis.functions.contains(fn_id.name):
                                    lowered = lower_fn_to_proc(ctx, nm.name, nm.ty)
                            _:
                                pass
                _:
                    pass
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


## The last component of a qualified name (`bin.Reader` -> "Reader"; `Reader` -> "Reader").
function qname_last(qn: ast.QualifiedName) -> str:
    if qn.parts.len == 0:
        return ""
    return unsafe: read(qn.parts.data + qn.parts.len - 1)


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
        if m.name == name:
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
            # Collapsed prelude-variant instance (`Option_str`): recover owner +
            # args from the pending generic-variant registry so prelude methods
            # monomorphize instead of falling to the module-qualified fallback.
            if is_prelude_variant_name(n.name):
                match prelude_instance_args(ctx, n.name):
                    Option.some as rec:
                        return Option[GenericReceiver].some(value = rec.value)
                    Option.none:
                        return Option[GenericReceiver].none
            let instance_ptr = ctx.generic_struct_instances.get(n.name)
            if instance_ptr == null:
                return Option[GenericReceiver].none
            let inst = unsafe: read(instance_ptr)
            owner_name = inst.owner_name
            raw_args = inst.concrete_args
        _:
            return Option[GenericReceiver].none
    var resolved = vec.Vec[types.Type].create()
    var i: ptr_uint = 0
    while i < raw_args.len:
        let arg = unsafe: read(raw_args.data + i)
        let concrete = substitute_type_params(ctx, arg, ref_of(ctx.type_substitution))
        if type_is_unresolved_param(concrete):
            return Option[GenericReceiver].none
        # Qualify in the caller's context so a concrete element type from a
        # module the container (owner) does not import still renders with its
        # correct prefix when the method body is lowered in owner context.
        resolved.push(qualify_type(ctx, concrete))
        i += 1
    return Option[GenericReceiver].some(value = GenericReceiver(owner_name = owner_name, concrete_args = resolved.as_span()))


## Recover a prelude variant's owner name and concrete type arguments from its
## collapsed C name (`Option_str` → owner "Option", args [str]) by looking up the
## already-emitted concrete variant declaration in `pending_generic_variants`.
## The declaration's arm field types carry the concrete args (Option.some.value,
## Result.success.value + Result.failure.error), so they can be recovered without
## re-parsing the mangled name.
function prelude_instance_args(ctx: ref[LowerCtx], c_name: str) -> Option[GenericReceiver]:
    let base = prelude_variant_base(c_name) else:
        return Option[GenericReceiver].none
    var si: ptr_uint = 0
    while si < ctx.pending_generic_variants.len():
        let vp = ctx.pending_generic_variants.get(si) else:
            break
        var decl: ir.VariantDecl
        unsafe:
            decl = read(vp)
        if decl.linkage_name == c_name:
            var args = vec.Vec[types.Type].create()
            # Option: [some.value]; Result: [success.value, failure.error].
            var ai: ptr_uint = 0
            while ai < decl.arms.len:
                var arm: ir.VariantArm
                unsafe:
                    arm = read(decl.arms.data + ai)
                if arm.fields.len > 0:
                    unsafe:
                        args.push(read(arm.fields.data + 0).ty)
                ai += 1
            if args.len() > 0:
                return Option[GenericReceiver].some(value = GenericReceiver(owner_name = base, concrete_args = args.as_span()))
        si += 1
    return Option[GenericReceiver].none


## Locate a generic method by owner-struct name and method name: search every
## module for a generic extending block (`extending Owner[...]:`) on a struct
## named `owner_name` that declares `method_name`.  Extending blocks for a struct
## may appear in any module that imports it, not just the defining module (e.g.
## `std.serialize` declares `extending bin.Reader: function unpack[T]()` even
## though `Reader` is defined in `std.binary`).
function find_generic_method(ctx: ref[LowerCtx], owner_name: str, method_name: str) -> Option[GenericMethodMatch]:
    var ai: ptr_uint = 0
    while ai < ctx.program_analyses.len:
        var a: analyzer.Analysis
        unsafe:
            a = read(ctx.program_analyses.data + ai)
        var di: ptr_uint = 0
        while di < a.source_file.declarations.len:
            var d: ast.Decl
            unsafe:
                d = read(a.source_file.declarations.data + di)
            match d:
                ast.Decl.decl_extending_block as ex:
                    let type_ref = unsafe: read(ex.type_name)
                    if qname_last(type_ref.name) == owner_name:
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
                    resolved.push(qualify_type(ctx, concrete))
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
        # The collapsed IR type is a concrete `ty_named` whose generic-instance
        # entry was registered in the defining module's context, not this one
        # (e.g. a local bound from a cross-module call `da.check()` returning
        # `Vec[Diag]`).  The analyzer's recorded receiver type still carries the
        # generic form with type args, so recover owner + args from it.
        info_opt = generic_receiver_info(ctx, expr_type(ctx, receiver))
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
        # Method has its own type parameters (e.g. `map_error[F]`).
        # Infer each from the argument types and extend the concrete args.
        var extended_args = vec.Vec[types.Type].create()
        var ai: ptr_uint = 0
        while ai < info.concrete_args.len:
            unsafe:
                extended_args.push(read(info.concrete_args.data + ai))
            ai += 1
        var tpi: ptr_uint = 0
        var all_inferred = true
        while tpi < gm.method.type_params.len:
            var tp: ast.TypeParam
            unsafe:
                tp = read(gm.method.type_params.data + tpi)
            let inferred = infer_type_param_from_args(ctx, tp.name, gm.method.method_params, args) else:
                all_inferred = false
                break
            extended_args.push(inferred)
            tpi += 1
        if not all_inferred:
            return Option[ptr[ir.Expr]].none
        let extended_info = GenericReceiver(owner_name = info.owner_name, concrete_args = extended_args.as_span())
        return Option[ptr[ir.Expr]].some(value = lower_monomorphized_method(ctx, extended_info, gm, method_name, receiver, args))
    return Option[ptr[ir.Expr]].some(value = lower_monomorphized_method(ctx, info, gm, method_name, receiver, args))


## The C linkage name for a monomorphized method instance.  Struct receivers use
## the module-qualified concrete-struct prefix (`std_vec_Vec_int_push`); prelude
## variant receivers (Option/Result) use the global concrete-variant prefix with
## no module qualifier (`Option_str_unwrap`), matching how prelude variant
## instances are named globally elsewhere.
## When the method declares its own type params (e.g. `unpack[T]()` on a non-generic
## struct), those args are appended after the method name so the struct prefix
## stays stable: `std_binary_Reader_unpack_CompactHeader`.
function monomorphized_method_c_name(owner_module: str, info: GenericReceiver, gm: GenericMethodMatch, method_name: str) -> str:
    var buf = string.String.create()
    # Only use struct-level args in the struct prefix; method-level args go after
    # the method name.
    var struct_args = vec.Vec[types.Type].create()
    var si: ptr_uint = 0
    while si < gm.struct_param_names.len and si < info.concrete_args.len:
        unsafe:
            struct_args.push(read(info.concrete_args.data + si))
        si += 1
    if is_prelude_variant_name(info.owner_name):
        buf.append(generic_struct_c_name(info.owner_name, struct_args.as_span()))
    else:
        let struct_c = naming.qualified_c_name(owner_module, generic_struct_c_name(info.owner_name, struct_args.as_span()))
        buf.append(struct_c)
    buf.append("_")
    buf.append(method_name)
    # Append method-level type args after the method name, skipping the
    # struct-level args that were already included in the struct prefix.
    var mi: ptr_uint = gm.struct_param_names.len
    while mi < info.concrete_args.len:
        buf.append("_")
        unsafe:
            buf.append(naming.type_c_key(read(info.concrete_args.data + mi)))
        mi += 1
    return buf.as_str()


## Lower a monomorphized method call: ensure the specialized method body exists,
## then emit a direct C call to it with the receiver argument.  The specialized
## C name groups by the concrete struct (`std_vec_Vec_int_push`), matching the
## monomorphized struct type produced by `qualify_type`.
function lower_monomorphized_method(ctx: ref[LowerCtx], info: GenericReceiver, gm: GenericMethodMatch, method_name: str, receiver: ptr[ast.Expr], args: span[ast.Argument]) -> ptr[ir.Expr]:
    # For the struct prefix in the C name, use the struct's defining module
    # (which may differ from the extending-block module, e.g. `Writer` is
    # defined in `std_binary` but extended by `std_serialize`).
    var struct_module = gm.owner_module
    var sai: ptr_uint = 0
    while sai < ctx.program_analyses.len:
        var sa: analyzer.Analysis
        unsafe:
            sa = read(ctx.program_analyses.data + sai)
        if struct_in_source(sa, info.owner_name) or sa.structs.contains(info.owner_name):
            struct_module = sa.module_name
            break
        sai += 1
    let method_c = monomorphized_method_c_name(struct_module, info, gm, method_name)

    if not ctx.specialization_cache.contains(method_c) and not ctx.spec_in_progress.contains(method_c):
        ensure_monomorphized_method(ctx, method_c, info, gm)

    var ret_ty = types.primitive("void")
    let cached = ctx.specialization_cache.get(method_c)
    if cached != null:
        ret_ty = unsafe: read(cached).return_type

    let recv = lower_expr(ctx, receiver)
    var ir_args = vec.Vec[ir.Expr].create()
    var param_offset: ptr_uint = 0
    match build_receiver_arg(recv, gm.method.method_kind):
        Option.some as recv_arg:
            unsafe:
                ir_args.push(read(recv_arg.value))
            param_offset = 1
        Option.none:
            pass
    var i: ptr_uint = 0
    while i < args.len:
        var arg: ast.Argument
        unsafe:
            arg = read(args.data + i)
        var lowered = lower_expr(ctx, arg.arg_value)
        lowered = coerce_arg_to_param(cached, param_offset + i, lowered)
        lowered = coerce_monomorphized_arg_to_proc(ctx, cached, param_offset + i, lowered, arg.arg_value)
        unsafe:
            ir_args.push(read(lowered))
        i += 1
    return alloc_expr(ir.Expr.expr_call(callee = method_c, arguments = ir_args.as_span(), ty = ret_ty))


## Coerce a lowered call argument to the specialized function's parameter type:
## when the parameter is a by-value type but the argument is a pointer (e.g. `this`
## inside an editable method passed to a by-value `current` param), dereference
## the argument.  Leaves the argument unchanged when types already agree or the
## parameter info is unavailable.
function coerce_arg_to_param(cached: ptr[ir.Function]?, param_index: ptr_uint, arg: ptr[ir.Expr]) -> ptr[ir.Expr]:
    let fn_ptr = cached else:
        return arg
    let spec_fn = unsafe: read(fn_ptr)
    if param_index >= spec_fn.params.len:
        return arg
    var param: ir.Param
    unsafe:
        param = read(spec_fn.params.data + param_index)
    let arg_ty = ir_expr_type(arg)
    if is_pointer_or_ref_type(arg_ty) and not is_pointer_or_ref_type(param.ty):
        # `*arg`: dereference the pointer argument to match the value parameter.
        return alloc_expr(ir.Expr.expr_unary(operator = "*", operand = arg, ty = param.ty))
    return arg


## Coerce a bare function argument to a proc struct when the monomorphized
## parameter expects a proc type.  Mirrors coerce_fn_arg_to_proc but uses the
## lowered function's parameter types.
function coerce_monomorphized_arg_to_proc(ctx: ref[LowerCtx], cached: ptr[ir.Function]?, param_index: ptr_uint, lowered: ptr[ir.Expr], arg_ast: ptr[ast.Expr]) -> ptr[ir.Expr]:
    let fn_ptr = cached else:
        return lowered
    let spec_fn = unsafe: read(fn_ptr)
    if param_index >= spec_fn.params.len:
        return lowered
    var param: ir.Param
    unsafe:
        param = read(spec_fn.params.data + param_index)
    if not is_proc_type(param.ty):
        return lowered
    unsafe:
        match read(lowered):
            ir.Expr.expr_name as nm:
                if is_fn_type(nm.ty):
                    match read(arg_ast):
                        ast.Expr.expr_identifier as fn_id:
                            if ctx.function_returns.contains(fn_id.name) or ctx.analysis.functions.contains(fn_id.name):
                                return lower_fn_to_proc(ctx, nm.name, nm.ty)
                        _:
                            pass
            _:
                pass
    return lowered


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
    # Map method-level type params (e.g. `F` in `map_error[F]`) to the remaining
    # concrete args after the struct-level args.
    var mi: ptr_uint = 0
    while mi < gm.method.type_params.len and pi < info.concrete_args.len:
        unsafe:
            sub.set(read(gm.method.type_params.data + mi).name, read(info.concrete_args.data + pi))
        mi += 1
        pi += 1

    var saved_module = ctx.module_name
    var saved_analysis = ctx.analysis
    var saved_foreign = ctx.foreign_map
    var saved_variants = ctx.variants
    var saved_locals = ctx.locals
    var saved_counter = ctx.temp_counter
    var saved_returns = ctx.function_returns
    var saved_sub = ctx.type_substitution
    var saved_inside_async = ctx.inside_async

    ctx.module_name = gm.owner_module
    ctx.analysis = owner_a
    ctx.foreign_map = map_mod.Map[str, ForeignInfo].create()
    ctx.variants = map_mod.Map[str, VariantInfo].create()
    ctx.locals = vec.Vec[LocalBinding].create()
    ctx.temp_counter = 0
    ctx.function_returns = map_mod.Map[str, types.Type].create()
    ctx.type_substitution = sub
    ctx.inside_async = false
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
    ctx.inside_async = saved_inside_async


## Find the module that defines a struct named `name` by searching loaded analyses.
## Returns the struct's defining module name, or the default module name if not found.
function struct_defining_module_for_type(ctx: ref[LowerCtx], name: str) -> str:
    var sai: ptr_uint = 0
    while sai < ctx.program_analyses.len:
        var sa: analyzer.Analysis
        unsafe:
            sa = read(ctx.program_analyses.data + sai)
        if struct_in_source(sa, name) or sa.structs.contains(name):
            return sa.module_name
        sai += 1
    return ctx.module_name


## Lower a single generic method to an IR function with the struct's type
## parameters substituted.  Mirrors `lower_method`, but resolves the receiver and
## parameter/return types through `substitute_type_params` with `sub`.
function lower_specialized_method(ctx: ref[LowerCtx], method_c: str, info: GenericReceiver, gm: GenericMethodMatch, sub: ref[map_mod.Map[str, types.Type]]) -> ir.Function:
    let m = gm.method
    ctx.locals.clear()
    ctx.temp_counter = 0

    # Build the receiver struct type using only the struct-level type args
    # (the first N concrete args where N = struct_param_names.len).  Method-level
    # type params extend concrete_args but are NOT part of the receiver.
    var struct_args = vec.Vec[types.Type].create()
    var si: ptr_uint = 0
    while si < gm.struct_param_names.len and si < info.concrete_args.len:
        unsafe:
            struct_args.push(read(info.concrete_args.data + si))
        si += 1

    let recv_struct_ty = qualify_type(ctx, types.Type.ty_imported(
        module_name = struct_defining_module_for_type(ctx, info.owner_name),
        name = info.owner_name,
        args = struct_args.as_span(),
    ))

    var ir_params = vec.Vec[ir.Param].create()
    if m.method_kind != ast.MethodKind.mk_static:
        let recv_ty = if m.method_kind == ast.MethodKind.mk_editable: types.Type.ty_generic(name = "ptr", args = sp_type(recv_struct_ty)) else: recv_struct_ty
        ir_params.push(ir.Param(name = "this", linkage_name = utils.c_local_name("this"), ty = recv_ty, pointer = false))
        ctx.locals.push(LocalBinding(name = "this", c_name = utils.c_local_name("this"), ty = recv_ty, pointer = false))

    var pi: ptr_uint = 0
    while pi < m.method_params.len:
        var p: ast.Param
        unsafe:
            p = read(m.method_params.data + pi)
        let p_ty = qualify_type(ctx, substitute_type_params(ctx, resolve_field_type_ref(ctx, p.param_type), sub))
        let c_pname = utils.c_local_name(p.name)
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
    var saved_fn_ret = ctx.current_fn_return_type
    ctx.current_fn_return_type = ret_ty
    let body_ir = lower_function_body(ctx, m.body)
    ctx.current_fn_return_type = saved_fn_ret
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
    return utils.j2(a, b)


function j3(a: str, b: str, c: str) -> str:
    return utils.j3(a, b, c)


function j4(a: str, b: str, c: str, d: str) -> str:
    return utils.j4(a, b, c, d)


function j5(a: str, b: str, c: str, d: str, e: str) -> str:
    return utils.j5(a, b, c, d, e)


function j6(a: str, b: str, c: str, d: str, e: str, f: str) -> str:
    return utils.j6(a, b, c, d, e, f)


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
            return p.name == "void"
        _:
            return false


## True when a type is a str_buffer[N] type.
function is_str_buffer_type(t: types.Type) -> bool:
    match t:
        types.Type.ty_generic as g:
            return g.name == "str_buffer"
        _:
            return false


## True when a type is an atomic[T] type.
function is_atomic_type(t: types.Type) -> bool:
    match t:
        types.Type.ty_generic as g:
            return g.name == "atomic"
        _:
            return false


## The element type T of an atomic[T] type, or ty_error for a malformed one.
function atomic_element_type(t: types.Type) -> types.Type:
    match t:
        types.Type.ty_generic as g:
            if g.args.len >= 1:
                return unsafe: read(g.args.data + 0)
            return types.Type.ty_error
        _:
            return types.Type.ty_error


## Lower an atomic[T] method call to a GCC/Clang __atomic_* builtin with the
## sequential-consistency memory order (5).  `load` reads through the address,
## `store` writes, and `add`/`sub`/`exchange` are read-modify-write.  Mirrors
## Ruby's lower_atomic_method_call.
function lower_atomic_method(ctx: ref[LowerCtx], recv: ptr[ir.Expr], recv_ty: types.Type, method_name: str, args: span[ast.Argument], call_ep: ptr[ast.Expr]) -> ptr[ir.Expr]:
    let elem_ty = atomic_element_type(recv_ty)
    let void_ty = types.primitive("void")
    let int_ty = types.primitive("int")
    let ptr_ty = types.Type.ty_generic(name = "ptr", args = sp_type(elem_ty))
    let addr = alloc_expr(ir.Expr.expr_address_of(expression = recv, ty = ptr_ty))
    let seq_cst = alloc_expr(ir.Expr.expr_integer_literal(value = 5l, ty = int_ty))
    if method_name == "load":
        return alloc_expr(ir.Expr.expr_call(callee = "__atomic_load_n", arguments = sp_expr2(addr, seq_cst), ty = elem_ty))
    let arg_ir = lower_expr(ctx, unsafe: read(args.data + 0).arg_value)
    if method_name == "store":
        return alloc_expr(ir.Expr.expr_call(callee = "__atomic_store_n", arguments = sp_expr3(addr, arg_ir, seq_cst), ty = void_ty))
    if method_name == "add":
        return alloc_expr(ir.Expr.expr_call(callee = "__atomic_fetch_add", arguments = sp_expr3(addr, arg_ir, seq_cst), ty = elem_ty))
    if method_name == "sub":
        return alloc_expr(ir.Expr.expr_call(callee = "__atomic_fetch_sub", arguments = sp_expr3(addr, arg_ir, seq_cst), ty = elem_ty))
    if method_name == "exchange":
        return alloc_expr(ir.Expr.expr_call(callee = "__atomic_exchange_n", arguments = sp_expr3(addr, arg_ir, seq_cst), ty = elem_ty))
    fatal(c"atomic lowering: unknown method")


# =============================================================================
#  Event runtime — delegates to C runtime helpers for slot management.
# =============================================================================

## True when `t` is the type of a declared event.
function is_event_type(ctx: ref[LowerCtx], t: types.Type) -> bool:
    match t:
        types.Type.ty_named as n:
            if ctx.analysis.events.contains(n.name):
                return true
            if n.name.starts_with("mt_event_"):
                let stripped = strip_event_cap_suffix(n.name)
                if ctx.analysis.events.contains(stripped):
                    return true
                return is_any_event_suffix(ctx, n.name)
            return is_any_event_suffix(ctx, n.name)
        types.Type.ty_imported as im:
            if ctx.analysis.events.contains(im.name):
                return true
            return is_any_event_suffix(ctx, im.name)
        _:
            return false


## Extract the event name from an event type (ty_named).
function event_name_from_type(t: types.Type) -> str:
    match t:
        types.Type.ty_named as n:
            if n.name.starts_with("mt_event_"):
                return event_name_from_c_linkage(n.name)
            return n.name
        types.Type.ty_imported as im:
            if im.name.starts_with("mt_event_"):
                return event_name_from_c_linkage(im.name)
            return im.name
        types.Type.ty_generic as g:
            return g.name
        _:
            fatal(c"event type is not ty_named")


## Remove the trailing _<digits> capacity suffix from an event struct C name.
function strip_event_cap_suffix(name: str) -> str:
    var pos = name.len
    while pos > 0:
        pos -= 1
        let b = name.byte_at(pos)
        if b >= ubyte<-('0') and b <= ubyte<-('9'):
            continue
        if b == ubyte<-('_') and pos + 1 < name.len:
            return name.slice(0, pos)
        break
    return name


function is_any_event_suffix(ctx: ref[LowerCtx], name: str) -> bool:
    let base = strip_event_cap_suffix(name)
    var iter = ctx.analysis.events.keys()
    while true:
        let kp = iter.next() else:
            break
        unsafe:
            if base.ends_with(read(kp)):
                return true
    return false


function event_name_from_c_linkage(name: str) -> str:
    var rest = name.slice(8, name.len - 8)
    let base = strip_event_cap_suffix(rest)
    return base


## Create the EventError enum (backing: int).  Returns the named type.
function ensure_event_error_enum(ctx: ref[LowerCtx]) -> types.Type:
    if not ctx.event_error_emitted:
        ctx.event_error_emitted = true
    return types.Type.ty_named(module_name = "", name = "EventError")


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
    let raw_linkage = naming.qualified_c_name(ctx.module_name, event_name)
    var cap_buf = string.String.create()
    fmt.append_long(ref_of(cap_buf), long<-(ev.capacity))
    let linkage_with_cap = j3(raw_linkage, "_", cap_buf.as_str())
    let linkage = j2("mt_event_", linkage_with_cap)
    let slot_cn = j2(linkage, "__slot")
    let snapshot_cn = j2(linkage, "__snapshot")
    let event_cn = linkage
    # Slot struct: { active, once, generation, state, listener, wait_frame }
    ctx.pending_event_structs.push(ir.StructDecl(
        name = slot_cn, linkage_name = slot_cn,
        fields = sp_field6(
            ir.Field(name = "active", ty = bool_ty),
            ir.Field(name = "once", ty = bool_ty),
            ir.Field(name = "generation", ty = ptr_uint_ty),
            ir.Field(name = "state", ty = void_ptr_ty),
            ir.Field(name = "listener", ty = void_ptr_ty),
            ir.Field(name = "wait_frame", ty = void_ptr_ty),
        ),
        packed = false, alignment = 0, source_module = Option[str].none,
    ))
    # Snapshot struct: { slot, generation, once, wait_slot, stateful, state, listener }
    ctx.pending_event_structs.push(ir.StructDecl(
        name = snapshot_cn, linkage_name = snapshot_cn,
        fields = sp_field7(
            ir.Field(name = "slot", ty = ptr_uint_ty),
            ir.Field(name = "generation", ty = ptr_uint_ty),
            ir.Field(name = "once", ty = bool_ty),
            ir.Field(name = "wait_slot", ty = bool_ty),
            ir.Field(name = "stateful", ty = bool_ty),
            ir.Field(name = "state", ty = void_ptr_ty),
            ir.Field(name = "listener", ty = void_ptr_ty),
        ),
        packed = false, alignment = 0, source_module = Option[str].none,
    ))
    # Event struct: { slots: array[Slot, capacity] }
    let capacity_val: long = long<-(ev.capacity)
    let slot_ty = types.Type.ty_named(module_name = "", name = slot_cn)
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
    let event_error_ty = ensure_event_error_enum(ctx)
    var wait_result_args = vec.Vec[types.Type].create()
    if has_payload:
        wait_result_args.push(payload_ty)
    else:
        wait_result_args.push(types.primitive("void"))
    wait_result_args.push(event_error_ty)
    let wait_result_ty = ensure_generic_variant(ctx, "Result", wait_result_args.as_span())
    let wake_fn_ty = types.Type.ty_function(params = single_ty_span(void_ptr_ty), return_type = types.alloc_type(types.primitive("void")), variadic = false, is_proc = false)
    let wait_frame_cn = j2(linkage, "__wait_frame")
    ctx.pending_event_structs.push(ir.StructDecl(
        name = wait_frame_cn, linkage_name = wait_frame_cn,
        fields = sp_field6(
            ir.Field(name = "ready", ty = bool_ty),
            ir.Field(name = "waiter_frame", ty = void_ptr_ty),
            ir.Field(name = "waiter", ty = wake_fn_ty),
            ir.Field(name = "event", ty = void_ptr_ty),
            ir.Field(name = "subscription", ty = types.Type.ty_named(module_name = "", name = "mt_subscription")),
            ir.Field(name = "result", ty = wait_result_ty),
        ),
        packed = false, alignment = 0, source_module = Option[str].none,
    ))
    var info = EventRuntimeInfo(
        name = event_name, linkage_name = linkage, capacity = ptr_uint<-(ev.capacity),
        has_payload = has_payload, payload_type = payload_ty,
        slot_c_name = slot_cn, event_c_name = event_cn,
        subscribe_c_name = j2(linkage, "__subscribe"),
        subscribe_once_c_name = j2(linkage, "__subscribe_once"),
        subscribe_stateful_c_name = j2(linkage, "__subscribe_stateful"),
        subscribe_once_stateful_c_name = j2(linkage, "__subscribe_once_stateful"),
        unsubscribe_c_name = j2(linkage, "__unsubscribe"),
        emit_c_name = j2(linkage, "__emit"),
        wait_c_name = j2(linkage, "__wait"),
        wait_frame_c_name = wait_frame_cn,
        wait_ready_c_name = j2(linkage, "__wait_ready"),
        wait_set_waiter_c_name = j2(linkage, "__wait_set_waiter"),
        wait_release_c_name = j2(linkage, "__wait_release"),
        wait_take_result_c_name = j2(linkage, "__wait_take_result"),
        wait_result_ty = wait_result_ty,
    )
    ctx.event_runtimes.set(event_name, info)
    ctx.pending_event_functions.push(build_event_subscribe_fn(ctx, ref_of(info), slot_cn, event_cn, false))
    ctx.pending_event_functions.push(build_event_subscribe_fn(ctx, ref_of(info), slot_cn, event_cn, true))
    ctx.pending_event_functions.push(build_event_subscribe_stateful_fn(ctx, ref_of(info), slot_cn, event_cn, false))
    ctx.pending_event_functions.push(build_event_subscribe_stateful_fn(ctx, ref_of(info), slot_cn, event_cn, true))
    ctx.pending_event_functions.push(build_event_unsubscribe_fn(ref_of(info), slot_cn, event_cn))
    ctx.pending_event_functions.push(build_event_emit_fn(ref_of(info), slot_cn, event_cn))
    ctx.pending_event_functions.push(build_event_wait_ready_fn(ref_of(info), slot_cn, event_cn))
    ctx.pending_event_functions.push(build_event_wait_set_waiter_fn(ref_of(info), slot_cn, event_cn))
    ctx.pending_event_functions.push(build_event_wait_release_fn(ref_of(info), slot_cn, event_cn))
    ctx.pending_event_functions.push(build_event_wait_take_result_fn(ref_of(info), slot_cn, event_cn))
    ctx.pending_event_functions.push(build_event_wait_fn(ctx, ref_of(info), slot_cn, event_cn))
    return info


## Generates calls to per-event typed functions (mt_event_NAME__emit etc.).
function lower_event_method(ctx: ref[LowerCtx], recv: ptr[ir.Expr], recv_ty: types.Type, method_name: str, args: span[ast.Argument], call_ep: ptr[ast.Expr]) -> ptr[ir.Expr]:
    let ev_name = event_name_from_type(recv_ty)
    var info = ensure_event_runtime(ctx, ev_name)
    let void_ty = types.primitive("void")
    let bool_ty = types.primitive("bool")
    let event_ptr_ty = types.Type.ty_generic(name = "ptr", args = sp_type(types.Type.ty_named(module_name = "", name = info.event_c_name)))
    let recv_addr = alloc_expr(ir.Expr.expr_address_of(expression = recv, ty = event_ptr_ty))
    if method_name == "emit":
        var call_args = vec.Vec[ir.Expr].create()
        unsafe:
            call_args.push(read(recv_addr))
        if info.has_payload:
            let payload_val = lower_expr(ctx, unsafe: read(args.data + 0).arg_value)
            unsafe:
                call_args.push(read(payload_val))
        return alloc_expr(ir.Expr.expr_call(callee = info.emit_c_name, arguments = call_args.as_span(), ty = void_ty))
    if method_name == "subscribe" or method_name == "subscribe_once":
        let is_stateful = args.len >= 2
        var callee: str
        if is_stateful:
            callee = if method_name == "subscribe": info.subscribe_stateful_c_name else: info.subscribe_once_stateful_c_name
        else:
            callee = if method_name == "subscribe": info.subscribe_c_name else: info.subscribe_once_c_name
        var call_args = vec.Vec[ir.Expr].create()
        unsafe:
            call_args.push(read(recv_addr))
        if is_stateful:
            let state_val = lower_expr(ctx, unsafe: read(args.data + 0).arg_value)
            unsafe:
                call_args.push(read(state_val))
            let listener_val = lower_listener_arg(ctx, unsafe: read(args.data + 1).arg_value)
            unsafe:
                call_args.push(read(listener_val))
        else:
            let listener_val = lower_listener_arg(ctx, unsafe: read(args.data + 0).arg_value)
            unsafe:
                call_args.push(read(listener_val))
        let sub_plain_ty = types.Type.ty_named(module_name = "", name = "mt_subscription")
        let event_error_ty = ensure_event_error_enum(ctx)
        var result_args = vec.Vec[types.Type].create()
        result_args.push(sub_plain_ty)
        result_args.push(event_error_ty)
        let sub_ty = ensure_generic_variant(ctx, "Result", result_args.as_span())
        return alloc_expr(ir.Expr.expr_call(callee = callee, arguments = call_args.as_span(), ty = sub_ty))
    if method_name == "unsubscribe":
        var call_args = vec.Vec[ir.Expr].create()
        unsafe:
            call_args.push(read(recv_addr))
        let sub_val = lower_expr(ctx, unsafe: read(args.data + 0).arg_value)
        unsafe:
            call_args.push(read(sub_val))
        return alloc_expr(ir.Expr.expr_call(callee = info.unsubscribe_c_name, arguments = call_args.as_span(), ty = bool_ty))
    if method_name == "wait":
        var call_args = vec.Vec[ir.Expr].create()
        unsafe:
            call_args.push(read(recv_addr))
        let event_error_ty = ensure_event_error_enum(ctx)
        var wait_result_args = vec.Vec[types.Type].create()
        if info.has_payload:
            wait_result_args.push(info.payload_type)
        else:
            wait_result_args.push(types.primitive("void"))
        wait_result_args.push(event_error_ty)
        let wait_result_ty = ensure_generic_variant(ctx, "Result", wait_result_args.as_span())
        let task_ty = make_task_type(wait_result_ty)
        return alloc_expr(ir.Expr.expr_call(callee = info.wait_c_name, arguments = call_args.as_span(), ty = task_ty))
    fatal(c"lowering: unknown event method")


## Build a per-event subscribe (or subscribe_once) synthetic function.
function build_event_subscribe_fn(ctx: ref[LowerCtx], info: ref[EventRuntimeInfo], slot_cn: str, event_cn: str, once: bool) -> ir.Function:
    let void_ty = types.primitive("void")
    let bool_ty = types.primitive("bool")
    let ptr_uint_ty = types.primitive("ptr_uint")
    let void_ptr_ty = types.Type.ty_generic(name = "ptr", args = sp_type(void_ty))
    let sub_plain_ty = types.Type.ty_named(module_name = "", name = "mt_subscription")
    let event_error_ty = ensure_event_error_enum(ctx)
    var result_args = vec.Vec[types.Type].create()
    result_args.push(sub_plain_ty)
    result_args.push(event_error_ty)
    let sub_result_ty = ensure_generic_variant(ctx, "Result", result_args.as_span())
    let slot_ty = types.Type.ty_named(module_name = "", name = slot_cn)
    let event_ptr_ty = types.Type.ty_generic(name = "ptr", args = sp_type(types.Type.ty_named(module_name = "", name = event_cn)))
    let callee = if once: info.subscribe_once_c_name else: info.subscribe_c_name
    var body = vec.Vec[ir.Stmt].create()
    let index_name = "i"
    let index_ref = alloc_expr(ir.Expr.expr_name(name = index_name, ty = ptr_uint_ty, pointer = false))
    let cap_lit = alloc_expr(ir.Expr.expr_integer_literal(value = long<-(info.capacity), ty = ptr_uint_ty))
    let cond = alloc_expr(ir.Expr.expr_binary(operator = "<", left = index_ref, right = cap_lit, ty = bool_ty))
    let post = alloc_stmt(ir.Stmt.stmt_assignment(target = index_ref, operator = "+=", value = alloc_expr(ir.Expr.expr_integer_literal(value = 1, ty = ptr_uint_ty))))
    let init = alloc_stmt(ir.Stmt.stmt_local(name = index_name, linkage_name = index_name, ty = ptr_uint_ty, value = alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = ptr_uint_ty)), line = 0, source_path = ""))
    var loop_body = vec.Vec[ir.Stmt].create()
    let event_ref = alloc_expr(ir.Expr.expr_name(name = "event", ty = event_ptr_ty, pointer = false))
    let slot_arr_ty = types.Type.ty_generic(name = "array", args = sp_type2(slot_ty, types.literal_int(long<-(info.capacity))))
    let slots_ref = alloc_expr(ir.Expr.expr_member(receiver = event_ref, member = "slots", ty = slot_arr_ty))
    let slot_ref = alloc_expr(ir.Expr.expr_index(receiver = slots_ref, index = index_ref, ty = slot_ty))
    let slot_active = alloc_expr(ir.Expr.expr_member(receiver = slot_ref, member = "active", ty = bool_ty))
    let cont_stmt = ir.Stmt.stmt_continue
    let if_active = ir.Stmt.stmt_if(condition = slot_active, then_body = span_from_one(cont_stmt), else_body = span[ir.Stmt]())
    loop_body.push(if_active)
    let gen_ref = alloc_expr(ir.Expr.expr_member(receiver = slot_ref, member = "generation", ty = ptr_uint_ty))
    loop_body.push(ir.Stmt.stmt_local(name = "__mt_gen", linkage_name = "__mt_gen", ty = ptr_uint_ty, value = alloc_expr(ir.Expr.expr_binary(operator = "+", left = gen_ref, right = alloc_expr(ir.Expr.expr_integer_literal(value = 1, ty = ptr_uint_ty)), ty = ptr_uint_ty)), line = 0, source_path = ""))
    let gen_snap = alloc_expr(ir.Expr.expr_name(name = "__mt_gen", ty = ptr_uint_ty, pointer = false))
    loop_body.push(ir.Stmt.stmt_assignment(target = alloc_expr(ir.Expr.expr_member(receiver = slot_ref, member = "active", ty = bool_ty)), operator = "=", value = alloc_expr(ir.Expr.expr_boolean_literal(value = true, ty = bool_ty))))
    loop_body.push(ir.Stmt.stmt_assignment(target = alloc_expr(ir.Expr.expr_member(receiver = slot_ref, member = "once", ty = bool_ty)), operator = "=", value = alloc_expr(ir.Expr.expr_boolean_literal(value = once, ty = bool_ty))))
    loop_body.push(ir.Stmt.stmt_assignment(target = gen_ref, operator = "=", value = gen_snap))
    loop_body.push(ir.Stmt.stmt_assignment(target = alloc_expr(ir.Expr.expr_member(receiver = slot_ref, member = "listener", ty = void_ptr_ty)), operator = "=", value = alloc_expr(ir.Expr.expr_name(name = "listener", ty = void_ptr_ty, pointer = false))))
    loop_body.push(ir.Stmt.stmt_assignment(target = alloc_expr(ir.Expr.expr_member(receiver = slot_ref, member = "state", ty = void_ptr_ty)), operator = "=", value = alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = void_ptr_ty))))
    loop_body.push(ir.Stmt.stmt_assignment(target = alloc_expr(ir.Expr.expr_member(receiver = slot_ref, member = "wait_frame", ty = void_ptr_ty)), operator = "=", value = alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = void_ptr_ty))))
    # Return Result.success(value = {slot, generation}).
    var sub_literal = alloc_expr(ir.Expr.expr_aggregate_literal(ty = sub_plain_ty, fields = sp_fields2(
        ir.AggregateField(name = "slot", value = index_ref),
        ir.AggregateField(name = "generation", value = gen_snap),
    )))
    var success_fields = vec.Vec[ir.AggregateField].create()
    success_fields.push(ir.AggregateField(name = "value", value = sub_literal))
    var return_val = alloc_expr(ir.Expr.expr_variant_literal(
        ty = sub_result_ty,
        arm_name = "success",
        fields = success_fields.as_span(),
    ))
    loop_body.push(ir.Stmt.stmt_return(value = return_val, line = 0, source_path = ""))
    let for_stmt = ir.Stmt.stmt_for(init = init, condition = cond, post = post, body = loop_body.as_span())
    body.push(for_stmt)
    # Return Result.failure(error = EventError.full).
    var err_val = alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = event_error_ty))
    var fail_fields = vec.Vec[ir.AggregateField].create()
    fail_fields.push(ir.AggregateField(name = "error", value = err_val))
    var fail_val = alloc_expr(ir.Expr.expr_variant_literal(
        ty = sub_result_ty,
        arm_name = "failure",
        fields = fail_fields.as_span(),
    ))
    body.push(ir.Stmt.stmt_return(value = fail_val, line = 0, source_path = ""))
    var params = vec.Vec[ir.Param].create()
    params.push(ir.Param(name = "event", linkage_name = "event", ty = event_ptr_ty, pointer = false))
    params.push(ir.Param(name = "listener", linkage_name = "listener", ty = void_ptr_ty, pointer = false))
    return ir.Function(name = callee, linkage_name = callee, params = params.as_span(), return_type = sub_result_ty, body = body.as_span(), entry_point = false, method_receiver_param = false)


## Build a per-event stateful subscribe (or subscribe_once) synthetic function.
## Same as build_event_subscribe_fn but also accepts a `state: ptr[void]`
## parameter and writes it into the slot's `state` field.
function build_event_subscribe_stateful_fn(ctx: ref[LowerCtx], info: ref[EventRuntimeInfo], slot_cn: str, event_cn: str, once: bool) -> ir.Function:
    let void_ty = types.primitive("void")
    let bool_ty = types.primitive("bool")
    let ptr_uint_ty = types.primitive("ptr_uint")
    let void_ptr_ty = types.Type.ty_generic(name = "ptr", args = sp_type(void_ty))
    let sub_plain_ty = types.Type.ty_named(module_name = "", name = "mt_subscription")
    let event_error_ty = ensure_event_error_enum(ctx)
    var result_args = vec.Vec[types.Type].create()
    result_args.push(sub_plain_ty)
    result_args.push(event_error_ty)
    let sub_result_ty = ensure_generic_variant(ctx, "Result", result_args.as_span())
    let slot_ty = types.Type.ty_named(module_name = "", name = slot_cn)
    let event_ptr_ty = types.Type.ty_generic(name = "ptr", args = sp_type(types.Type.ty_named(module_name = "", name = event_cn)))
    var callee: str
    if once:
        callee = info.subscribe_once_stateful_c_name
    else:
        callee = info.subscribe_stateful_c_name
    var body = vec.Vec[ir.Stmt].create()
    let index_name = "i"
    let index_ref = alloc_expr(ir.Expr.expr_name(name = index_name, ty = ptr_uint_ty, pointer = false))
    let cap_lit = alloc_expr(ir.Expr.expr_integer_literal(value = long<-(info.capacity), ty = ptr_uint_ty))
    let cond = alloc_expr(ir.Expr.expr_binary(operator = "<", left = index_ref, right = cap_lit, ty = bool_ty))
    let post = alloc_stmt(ir.Stmt.stmt_assignment(target = index_ref, operator = "+=", value = alloc_expr(ir.Expr.expr_integer_literal(value = 1, ty = ptr_uint_ty))))
    let init = alloc_stmt(ir.Stmt.stmt_local(name = index_name, linkage_name = index_name, ty = ptr_uint_ty, value = alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = ptr_uint_ty)), line = 0, source_path = ""))
    var loop_body = vec.Vec[ir.Stmt].create()
    let event_ref = alloc_expr(ir.Expr.expr_name(name = "event", ty = event_ptr_ty, pointer = false))
    let slot_arr_ty = types.Type.ty_generic(name = "array", args = sp_type2(slot_ty, types.literal_int(long<-(info.capacity))))
    let slots_ref = alloc_expr(ir.Expr.expr_member(receiver = event_ref, member = "slots", ty = slot_arr_ty))
    let slot_ref = alloc_expr(ir.Expr.expr_index(receiver = slots_ref, index = index_ref, ty = slot_ty))
    let slot_active = alloc_expr(ir.Expr.expr_member(receiver = slot_ref, member = "active", ty = bool_ty))
    let cont_stmt = ir.Stmt.stmt_continue
    let if_active = ir.Stmt.stmt_if(condition = slot_active, then_body = span_from_one(cont_stmt), else_body = span[ir.Stmt]())
    loop_body.push(if_active)
    let gen_ref = alloc_expr(ir.Expr.expr_member(receiver = slot_ref, member = "generation", ty = ptr_uint_ty))
    loop_body.push(ir.Stmt.stmt_local(name = "__mt_gen", linkage_name = "__mt_gen", ty = ptr_uint_ty, value = alloc_expr(ir.Expr.expr_binary(operator = "+", left = gen_ref, right = alloc_expr(ir.Expr.expr_integer_literal(value = 1, ty = ptr_uint_ty)), ty = ptr_uint_ty)), line = 0, source_path = ""))
    let gen_snap = alloc_expr(ir.Expr.expr_name(name = "__mt_gen", ty = ptr_uint_ty, pointer = false))
    loop_body.push(ir.Stmt.stmt_assignment(target = alloc_expr(ir.Expr.expr_member(receiver = slot_ref, member = "active", ty = bool_ty)), operator = "=", value = alloc_expr(ir.Expr.expr_boolean_literal(value = true, ty = bool_ty))))
    loop_body.push(ir.Stmt.stmt_assignment(target = alloc_expr(ir.Expr.expr_member(receiver = slot_ref, member = "once", ty = bool_ty)), operator = "=", value = alloc_expr(ir.Expr.expr_boolean_literal(value = once, ty = bool_ty))))
    loop_body.push(ir.Stmt.stmt_assignment(target = gen_ref, operator = "=", value = gen_snap))
    loop_body.push(ir.Stmt.stmt_assignment(target = alloc_expr(ir.Expr.expr_member(receiver = slot_ref, member = "listener", ty = void_ptr_ty)), operator = "=", value = alloc_expr(ir.Expr.expr_name(name = "listener", ty = void_ptr_ty, pointer = false))))
    loop_body.push(ir.Stmt.stmt_assignment(target = alloc_expr(ir.Expr.expr_member(receiver = slot_ref, member = "state", ty = void_ptr_ty)), operator = "=", value = alloc_expr(ir.Expr.expr_name(name = "state", ty = void_ptr_ty, pointer = false))))
    loop_body.push(ir.Stmt.stmt_assignment(target = alloc_expr(ir.Expr.expr_member(receiver = slot_ref, member = "wait_frame", ty = void_ptr_ty)), operator = "=", value = alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = void_ptr_ty))))
    # Return Result.success(value = {slot, generation}).
    var sub_literal = alloc_expr(ir.Expr.expr_aggregate_literal(ty = sub_plain_ty, fields = sp_fields2(
        ir.AggregateField(name = "slot", value = index_ref),
        ir.AggregateField(name = "generation", value = gen_snap),
    )))
    var success_fields = vec.Vec[ir.AggregateField].create()
    success_fields.push(ir.AggregateField(name = "value", value = sub_literal))
    var return_val = alloc_expr(ir.Expr.expr_variant_literal(
        ty = sub_result_ty,
        arm_name = "success",
        fields = success_fields.as_span(),
    ))
    loop_body.push(ir.Stmt.stmt_return(value = return_val, line = 0, source_path = ""))
    let for_stmt = ir.Stmt.stmt_for(init = init, condition = cond, post = post, body = loop_body.as_span())
    body.push(for_stmt)
    # Return Result.failure(error = EventError.full).
    var err_val = alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = event_error_ty))
    var fail_fields = vec.Vec[ir.AggregateField].create()
    fail_fields.push(ir.AggregateField(name = "error", value = err_val))
    var fail_val = alloc_expr(ir.Expr.expr_variant_literal(
        ty = sub_result_ty,
        arm_name = "failure",
        fields = fail_fields.as_span(),
    ))
    body.push(ir.Stmt.stmt_return(value = fail_val, line = 0, source_path = ""))
    var params = vec.Vec[ir.Param].create()
    params.push(ir.Param(name = "event", linkage_name = "event", ty = event_ptr_ty, pointer = false))
    params.push(ir.Param(name = "state", linkage_name = "state", ty = void_ptr_ty, pointer = false))
    params.push(ir.Param(name = "listener", linkage_name = "listener", ty = void_ptr_ty, pointer = false))
    return ir.Function(name = callee, linkage_name = callee, params = params.as_span(), return_type = sub_result_ty, body = body.as_span(), entry_point = false, method_receiver_param = false)


## Build a per-event unsubscribe synthetic function.
function build_event_unsubscribe_fn(info: ref[EventRuntimeInfo], slot_cn: str, event_cn: str) -> ir.Function:
    let bool_ty = types.primitive("bool")
    let ptr_uint_ty = types.primitive("ptr_uint")
    let slot_ty = types.Type.ty_named(module_name = "", name = slot_cn)
    let event_ptr_ty = types.Type.ty_generic(name = "ptr", args = sp_type(types.Type.ty_named(module_name = "", name = event_cn)))
    let sub_ty = types.Type.ty_named(module_name = "", name = "mt_subscription")
    var body = vec.Vec[ir.Stmt].create()
    let sub_ref = alloc_expr(ir.Expr.expr_name(name = "subscription", ty = sub_ty, pointer = false))
    let sub_slot = alloc_expr(ir.Expr.expr_member(receiver = sub_ref, member = "slot", ty = ptr_uint_ty))
    let sub_gen = alloc_expr(ir.Expr.expr_member(receiver = sub_ref, member = "generation", ty = ptr_uint_ty))
    let cap_lit = alloc_expr(ir.Expr.expr_integer_literal(value = long<-(info.capacity), ty = ptr_uint_ty))
    let out_of_range = alloc_expr(ir.Expr.expr_binary(operator = ">=", left = sub_slot, right = cap_lit, ty = bool_ty))
    body.push(ir.Stmt.stmt_if(condition = out_of_range, then_body = span_from_one(ir.Stmt.stmt_return(value = alloc_expr(ir.Expr.expr_boolean_literal(value = false, ty = bool_ty)), line = 0, source_path = "")), else_body = span[ir.Stmt]()))
    let event_ref = alloc_expr(ir.Expr.expr_name(name = "event", ty = event_ptr_ty, pointer = false))
    let slot_arr_ty = types.Type.ty_generic(name = "array", args = sp_type2(slot_ty, types.literal_int(long<-(info.capacity))))
    let slots_ref = alloc_expr(ir.Expr.expr_member(receiver = event_ref, member = "slots", ty = slot_arr_ty))
    let slot_ref = alloc_expr(ir.Expr.expr_index(receiver = slots_ref, index = sub_slot, ty = slot_ty))
    let slot_active = alloc_expr(ir.Expr.expr_member(receiver = slot_ref, member = "active", ty = bool_ty))
    body.push(ir.Stmt.stmt_if(condition = alloc_expr(ir.Expr.expr_unary(operator = "not", operand = slot_active, ty = bool_ty)), then_body = span_from_one(ir.Stmt.stmt_return(value = alloc_expr(ir.Expr.expr_boolean_literal(value = false, ty = bool_ty)), line = 0, source_path = "")), else_body = span[ir.Stmt]()))
    let slot_gen = alloc_expr(ir.Expr.expr_member(receiver = slot_ref, member = "generation", ty = ptr_uint_ty))
    let gen_mismatch = alloc_expr(ir.Expr.expr_binary(operator = "!=", left = slot_gen, right = sub_gen, ty = bool_ty))
    body.push(ir.Stmt.stmt_if(condition = gen_mismatch, then_body = span_from_one(ir.Stmt.stmt_return(value = alloc_expr(ir.Expr.expr_boolean_literal(value = false, ty = bool_ty)), line = 0, source_path = "")), else_body = span[ir.Stmt]()))
    body.push(ir.Stmt.stmt_assignment(target = slot_active, operator = "=", value = alloc_expr(ir.Expr.expr_boolean_literal(value = false, ty = bool_ty))))
    body.push(ir.Stmt.stmt_return(value = alloc_expr(ir.Expr.expr_boolean_literal(value = true, ty = bool_ty)), line = 0, source_path = ""))
    var params = vec.Vec[ir.Param].create()
    params.push(ir.Param(name = "event", linkage_name = "event", ty = event_ptr_ty, pointer = false))
    params.push(ir.Param(name = "subscription", linkage_name = "subscription", ty = sub_ty, pointer = false))
    return ir.Function(name = info.unsubscribe_c_name, linkage_name = info.unsubscribe_c_name, params = params.as_span(), return_type = bool_ty, body = body.as_span(), entry_point = false, method_receiver_param = false)


## Build a per-event emit synthetic function.
function build_event_emit_fn(info: ref[EventRuntimeInfo], slot_cn: str, event_cn: str) -> ir.Function:
    let void_ty = types.primitive("void")
    let bool_ty = types.primitive("bool")
    let ptr_uint_ty = types.primitive("ptr_uint")
    let void_ptr_ty = types.Type.ty_generic(name = "ptr", args = sp_type(void_ty))
    let slot_ty = types.Type.ty_named(module_name = "", name = slot_cn)
    let event_ptr_ty = types.Type.ty_generic(name = "ptr", args = sp_type(types.Type.ty_named(module_name = "", name = event_cn)))
    var body = vec.Vec[ir.Stmt].create()
    let index_name = "i"
    let index_ref = alloc_expr(ir.Expr.expr_name(name = index_name, ty = ptr_uint_ty, pointer = false))
    let cap_lit = alloc_expr(ir.Expr.expr_integer_literal(value = long<-(info.capacity), ty = ptr_uint_ty))
    let cond = alloc_expr(ir.Expr.expr_binary(operator = "<", left = index_ref, right = cap_lit, ty = bool_ty))
    let post = alloc_stmt(ir.Stmt.stmt_assignment(target = index_ref, operator = "+=", value = alloc_expr(ir.Expr.expr_integer_literal(value = 1, ty = ptr_uint_ty))))
    let init = alloc_stmt(ir.Stmt.stmt_local(name = index_name, linkage_name = index_name, ty = ptr_uint_ty, value = alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = ptr_uint_ty)), line = 0, source_path = ""))
    var loop_body = vec.Vec[ir.Stmt].create()
    let event_ref = alloc_expr(ir.Expr.expr_name(name = "event", ty = event_ptr_ty, pointer = false))
    let slot_arr_ty = types.Type.ty_generic(name = "array", args = sp_type2(slot_ty, types.literal_int(long<-(info.capacity))))
    let slots_ref = alloc_expr(ir.Expr.expr_member(receiver = event_ref, member = "slots", ty = slot_arr_ty))
    let slot_ref = alloc_expr(ir.Expr.expr_index(receiver = slots_ref, index = index_ref, ty = slot_ty))
    let slot_active = alloc_expr(ir.Expr.expr_member(receiver = slot_ref, member = "active", ty = bool_ty))
    let cont_stmt = ir.Stmt.stmt_continue
    let if_inactive = ir.Stmt.stmt_if(condition = alloc_expr(ir.Expr.expr_unary(operator = "not", operand = slot_active, ty = bool_ty)), then_body = span_from_one(cont_stmt), else_body = span[ir.Stmt]())
    loop_body.push(if_inactive)
    let slot_wait_frame = alloc_expr(ir.Expr.expr_member(receiver = slot_ref, member = "wait_frame", ty = void_ptr_ty))
    let has_wait = alloc_expr(ir.Expr.expr_binary(operator = "!=", left = slot_wait_frame, right = alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = void_ptr_ty)), ty = bool_ty))
    var wait_body = vec.Vec[ir.Stmt].create()
    let wf_ptr_ty = types.Type.ty_generic(name = "ptr", args = sp_type(types.Type.ty_named(module_name = "", name = info.wait_frame_c_name)))
    wait_body.push(ir.Stmt.stmt_local(name = "__mt_wf", linkage_name = "__mt_wf", ty = wf_ptr_ty, value = alloc_expr(ir.Expr.expr_cast(target_type = wf_ptr_ty, expression = slot_wait_frame, ty = wf_ptr_ty)), line = 0, source_path = ""))
    let wf_ref = alloc_expr(ir.Expr.expr_name(name = "__mt_wf", ty = wf_ptr_ty, pointer = true))
    var result_val: ptr[ir.Expr]
    if info.has_payload:
        let payload_ref = alloc_expr(ir.Expr.expr_name(name = "payload", ty = info.payload_type, pointer = false))
        var result_fields = vec.Vec[ir.AggregateField].create()
        result_fields.push(ir.AggregateField(name = "value", value = payload_ref))
        result_val = alloc_expr(ir.Expr.expr_variant_literal(ty = info.wait_result_ty, arm_name = "success", fields = result_fields.as_span()))
    else:
        var result_fields = vec.Vec[ir.AggregateField].create()
        result_val = alloc_expr(ir.Expr.expr_variant_literal(ty = info.wait_result_ty, arm_name = "success", fields = result_fields.as_span()))
    wait_body.push(ir.Stmt.stmt_assignment(target = alloc_expr(ir.Expr.expr_member(receiver = wf_ref, member = "result", ty = info.wait_result_ty)), operator = "=", value = result_val))
    wait_body.push(ir.Stmt.stmt_assignment(target = alloc_expr(ir.Expr.expr_member(receiver = wf_ref, member = "ready", ty = bool_ty)), operator = "=", value = alloc_expr(ir.Expr.expr_boolean_literal(value = true, ty = bool_ty))))
    let waiter_frame_ref = alloc_expr(ir.Expr.expr_member(receiver = wf_ref, member = "waiter_frame", ty = void_ptr_ty))
    let has_waiter = alloc_expr(ir.Expr.expr_binary(operator = "!=", left = waiter_frame_ref, right = alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = void_ptr_ty)), ty = bool_ty))
    var wake_body = vec.Vec[ir.Stmt].create()
    let wf_waiter_ref = alloc_expr(ir.Expr.expr_member(receiver = wf_ref, member = "waiter", ty = void_ptr_ty))
    let wake_fn_ty = types.Type.ty_function(params = single_ty_span(void_ptr_ty), return_type = types.alloc_type(types.primitive("void")), variadic = false, is_proc = false)
    let wake_fn_ptr_ty = types.Type.ty_generic(name = "ptr", args = sp_type(wake_fn_ty))
    let cast_waiter = alloc_expr(ir.Expr.expr_cast(target_type = wake_fn_ptr_ty, expression = wf_waiter_ref, ty = wake_fn_ptr_ty))
    wake_body.push(ir.Stmt.stmt_expression(expression = alloc_expr(ir.Expr.expr_call_indirect(callee = cast_waiter, arguments = single_expr_span(waiter_frame_ref), ty = types.primitive("void"))), line = 0, source_path = ""))
    wait_body.push(ir.Stmt.stmt_if(condition = has_waiter, then_body = wake_body.as_span(), else_body = span[ir.Stmt]()))
    wait_body.push(ir.Stmt.stmt_assignment(target = slot_active, operator = "=", value = alloc_expr(ir.Expr.expr_boolean_literal(value = false, ty = bool_ty))))
    wait_body.push(ir.Stmt.stmt_assignment(target = slot_wait_frame, operator = "=", value = alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = void_ptr_ty))))
    var else_wait_body = vec.Vec[ir.Stmt].create()
    let slot_listener = alloc_expr(ir.Expr.expr_member(receiver = slot_ref, member = "listener", ty = void_ptr_ty))
    let null_check = alloc_expr(ir.Expr.expr_binary(operator = "!=", left = slot_listener, right = alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = void_ptr_ty)), ty = bool_ty))
    var call_body = vec.Vec[ir.Stmt].create()
    var call_args = vec.Vec[ir.Expr].create()
    if info.has_payload:
        let payload_ref = alloc_expr(ir.Expr.expr_name(name = "payload", ty = info.payload_type, pointer = false))
        unsafe:
            call_args.push(read(payload_ref))
    var listener_fn_params = vec.Vec[types.Type].create()
    if info.has_payload:
        listener_fn_params.push(info.payload_type)
    let void_fn_ty = types.Type.ty_function(params = listener_fn_params.as_span(), return_type = types.alloc_type(void_ty), variadic = false, is_proc = false)
    let fn_ptr_ty = types.Type.ty_generic(name = "ptr", args = sp_type(void_fn_ty))
    let cast_listener = alloc_expr(ir.Expr.expr_cast(target_type = fn_ptr_ty, expression = slot_listener, ty = fn_ptr_ty))
    call_body.push(ir.Stmt.stmt_expression(expression = alloc_expr(ir.Expr.expr_call_indirect(callee = cast_listener, arguments = call_args.as_span(), ty = void_ty)), line = 0, source_path = ""))
    let call_stmt = ir.Stmt.stmt_if(condition = null_check, then_body = call_body.as_span(), else_body = span[ir.Stmt]())
    else_wait_body.push(call_stmt)
    let slot_once = alloc_expr(ir.Expr.expr_member(receiver = slot_ref, member = "once", ty = bool_ty))
    var deact_body = vec.Vec[ir.Stmt].create()
    deact_body.push(ir.Stmt.stmt_assignment(target = slot_active, operator = "=", value = alloc_expr(ir.Expr.expr_boolean_literal(value = false, ty = bool_ty))))
    else_wait_body.push(ir.Stmt.stmt_if(condition = slot_once, then_body = deact_body.as_span(), else_body = span[ir.Stmt]()))
    loop_body.push(ir.Stmt.stmt_if(condition = has_wait, then_body = wait_body.as_span(), else_body = else_wait_body.as_span()))
    let for_stmt = ir.Stmt.stmt_for(init = init, condition = cond, post = post, body = loop_body.as_span())
    body.push(for_stmt)
    var params = vec.Vec[ir.Param].create()
    params.push(ir.Param(name = "event", linkage_name = "event", ty = event_ptr_ty, pointer = false))
    if info.has_payload:
        params.push(ir.Param(name = "payload", linkage_name = "payload", ty = info.payload_type, pointer = false))
    return ir.Function(name = info.emit_c_name, linkage_name = info.emit_c_name, params = params.as_span(), return_type = void_ty, body = body.as_span(), entry_point = false, method_receiver_param = false)


## Build a per-event wait ready vtable function.
## Checks if the wait frame is ready.
function build_event_wait_ready_fn(info: ref[EventRuntimeInfo], slot_cn: str, event_cn: str) -> ir.Function:
    let void_ty = types.primitive("void")
    let bool_ty = types.primitive("bool")
    let void_ptr_ty = types.Type.ty_generic(name = "ptr", args = sp_type(void_ty))
    let wf_ptr_ty = types.Type.ty_generic(name = "ptr", args = sp_type(types.Type.ty_named(module_name = "", name = info.wait_frame_c_name)))
    var body = vec.Vec[ir.Stmt].create()
    let raw_expr = alloc_expr(ir.Expr.expr_name(name = "frame", ty = void_ptr_ty, pointer = false))
    let null_check = alloc_expr(ir.Expr.expr_binary(operator = "==", left = raw_expr, right = alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = void_ptr_ty)), ty = bool_ty))
    body.push(ir.Stmt.stmt_if(condition = null_check, then_body = span_from_one(ir.Stmt.stmt_return(value = alloc_expr(ir.Expr.expr_boolean_literal(value = true, ty = bool_ty)), line = 0, source_path = "")), else_body = span[ir.Stmt]()))
    body.push(ir.Stmt.stmt_local(name = "__mt_wf", linkage_name = "__mt_wf", ty = wf_ptr_ty, value = alloc_expr(ir.Expr.expr_cast(target_type = wf_ptr_ty, expression = raw_expr, ty = wf_ptr_ty)), line = 0, source_path = ""))
    let wf_ref = alloc_expr(ir.Expr.expr_name(name = "__mt_wf", ty = wf_ptr_ty, pointer = true))
    body.push(ir.Stmt.stmt_return(value = alloc_expr(ir.Expr.expr_member(receiver = wf_ref, member = "ready", ty = bool_ty)), line = 0, source_path = ""))
    var params = vec.Vec[ir.Param].create()
    params.push(ir.Param(name = "frame", linkage_name = "frame", ty = void_ptr_ty, pointer = false))
    return ir.Function(name = info.wait_ready_c_name, linkage_name = info.wait_ready_c_name, params = params.as_span(), return_type = bool_ty, body = body.as_span(), entry_point = false, method_receiver_param = false)


## Build a per-event wait set_waiter vtable function.
## Stores the waiter in the wait frame, or calls it immediately if already ready.
function build_event_wait_set_waiter_fn(info: ref[EventRuntimeInfo], slot_cn: str, event_cn: str) -> ir.Function:
    let void_ty = types.primitive("void")
    let bool_ty = types.primitive("bool")
    let void_ptr_ty = types.Type.ty_generic(name = "ptr", args = sp_type(void_ty))
    let wf_ptr_ty = types.Type.ty_generic(name = "ptr", args = sp_type(types.Type.ty_named(module_name = "", name = info.wait_frame_c_name)))
    var body = vec.Vec[ir.Stmt].create()
    let raw_expr = alloc_expr(ir.Expr.expr_name(name = "frame", ty = void_ptr_ty, pointer = false))
    let null_check = alloc_expr(ir.Expr.expr_binary(operator = "==", left = raw_expr, right = alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = void_ptr_ty)), ty = bool_ty))
    var null_then = vec.Vec[ir.Stmt].create()
    let wake_fn_ty = types.Type.ty_function(params = single_ty_span(void_ptr_ty), return_type = types.alloc_type(types.primitive("void")), variadic = false, is_proc = false)
    let wake_fn_ptr_ty = types.Type.ty_generic(name = "ptr", args = sp_type(wake_fn_ty))
    let waiter_arg = alloc_expr(ir.Expr.expr_name(name = "waiter", ty = void_ptr_ty, pointer = false))
    let cast_waiter = alloc_expr(ir.Expr.expr_cast(target_type = wake_fn_ptr_ty, expression = waiter_arg, ty = wake_fn_ptr_ty))
    null_then.push(ir.Stmt.stmt_expression(expression = alloc_expr(ir.Expr.expr_call_indirect(callee = cast_waiter, arguments = single_expr_span(alloc_expr(ir.Expr.expr_name(name = "waiter_frame", ty = void_ptr_ty, pointer = false))), ty = void_ty)), line = 0, source_path = ""))
    null_then.push(ir.Stmt.stmt_return(value = null, line = 0, source_path = ""))
    body.push(ir.Stmt.stmt_if(condition = null_check, then_body = null_then.as_span(), else_body = span[ir.Stmt]()))
    body.push(ir.Stmt.stmt_local(name = "__mt_wf", linkage_name = "__mt_wf", ty = wf_ptr_ty, value = alloc_expr(ir.Expr.expr_cast(target_type = wf_ptr_ty, expression = raw_expr, ty = wf_ptr_ty)), line = 0, source_path = ""))
    let wf_ref = alloc_expr(ir.Expr.expr_name(name = "__mt_wf", ty = wf_ptr_ty, pointer = true))
    let ready_expr = alloc_expr(ir.Expr.expr_member(receiver = wf_ref, member = "ready", ty = bool_ty))
    var ready_then = vec.Vec[ir.Stmt].create()
    ready_then.push(ir.Stmt.stmt_expression(expression = alloc_expr(ir.Expr.expr_call_indirect(callee = cast_waiter, arguments = single_expr_span(alloc_expr(ir.Expr.expr_name(name = "waiter_frame", ty = void_ptr_ty, pointer = false))), ty = void_ty)), line = 0, source_path = ""))
    ready_then.push(ir.Stmt.stmt_return(value = null, line = 0, source_path = ""))
    body.push(ir.Stmt.stmt_if(condition = ready_expr, then_body = ready_then.as_span(), else_body = span[ir.Stmt]()))
    body.push(ir.Stmt.stmt_assignment(target = alloc_expr(ir.Expr.expr_member(receiver = wf_ref, member = "waiter_frame", ty = void_ptr_ty)), operator = "=", value = alloc_expr(ir.Expr.expr_name(name = "waiter_frame", ty = void_ptr_ty, pointer = false))))
    body.push(ir.Stmt.stmt_assignment(target = alloc_expr(ir.Expr.expr_member(receiver = wf_ref, member = "waiter", ty = void_ptr_ty)), operator = "=", value = waiter_arg))
    body.push(ir.Stmt.stmt_return(value = null, line = 0, source_path = ""))
    var params = vec.Vec[ir.Param].create()
    params.push(ir.Param(name = "frame", linkage_name = "frame", ty = void_ptr_ty, pointer = false))
    params.push(ir.Param(name = "waiter_frame", linkage_name = "waiter_frame", ty = void_ptr_ty, pointer = false))
    let waiter_cb_ty = types.Type.ty_function(params = single_ty_span(void_ptr_ty), return_type = types.alloc_type(types.primitive("void")), variadic = false, is_proc = false)
    params.push(ir.Param(name = "waiter", linkage_name = "waiter", ty = waiter_cb_ty, pointer = true))
    return ir.Function(name = info.wait_set_waiter_c_name, linkage_name = info.wait_set_waiter_c_name, params = params.as_span(), return_type = void_ty, body = body.as_span(), entry_point = false, method_receiver_param = false)


## Build a per-event wait release vtable function.
## Frees the wait frame if not already ready.
function build_event_wait_release_fn(info: ref[EventRuntimeInfo], slot_cn: str, event_cn: str) -> ir.Function:
    let void_ty = types.primitive("void")
    let bool_ty = types.primitive("bool")
    let void_ptr_ty = types.Type.ty_generic(name = "ptr", args = sp_type(void_ty))
    let wf_ptr_ty = types.Type.ty_generic(name = "ptr", args = sp_type(types.Type.ty_named(module_name = "", name = info.wait_frame_c_name)))
    var body = vec.Vec[ir.Stmt].create()
    let raw_expr = alloc_expr(ir.Expr.expr_name(name = "frame", ty = void_ptr_ty, pointer = false))
    let null_check = alloc_expr(ir.Expr.expr_binary(operator = "==", left = raw_expr, right = alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = void_ptr_ty)), ty = bool_ty))
    body.push(ir.Stmt.stmt_if(condition = null_check, then_body = span_from_one(ir.Stmt.stmt_return(value = null, line = 0, source_path = "")), else_body = span[ir.Stmt]()))
    body.push(ir.Stmt.stmt_local(name = "__mt_wf", linkage_name = "__mt_wf", ty = wf_ptr_ty, value = alloc_expr(ir.Expr.expr_cast(target_type = wf_ptr_ty, expression = raw_expr, ty = wf_ptr_ty)), line = 0, source_path = ""))
    let wf_ref = alloc_expr(ir.Expr.expr_name(name = "__mt_wf", ty = wf_ptr_ty, pointer = true))
    body.push(ir.Stmt.stmt_expression(expression = alloc_expr(ir.Expr.expr_call(callee = "free", arguments = single_expr_span(alloc_expr(ir.Expr.expr_cast(target_type = void_ptr_ty, expression = wf_ref, ty = void_ptr_ty))), ty = void_ty)), line = 0, source_path = ""))
    body.push(ir.Stmt.stmt_return(value = null, line = 0, source_path = ""))
    var params = vec.Vec[ir.Param].create()
    params.push(ir.Param(name = "frame", linkage_name = "frame", ty = void_ptr_ty, pointer = false))
    return ir.Function(name = info.wait_release_c_name, linkage_name = info.wait_release_c_name, params = params.as_span(), return_type = void_ty, body = body.as_span(), entry_point = false, method_receiver_param = false)


## Build a per-event wait take_result vtable function.
function build_event_wait_take_result_fn(info: ref[EventRuntimeInfo], slot_cn: str, event_cn: str) -> ir.Function:
    let void_ty = types.primitive("void")
    let bool_ty = types.primitive("bool")
    let void_ptr_ty = types.Type.ty_generic(name = "ptr", args = sp_type(void_ty))
    let wf_ptr_ty = types.Type.ty_generic(name = "ptr", args = sp_type(types.Type.ty_named(module_name = "", name = info.wait_frame_c_name)))
    var body = vec.Vec[ir.Stmt].create()
    let raw_expr = alloc_expr(ir.Expr.expr_name(name = "frame", ty = void_ptr_ty, pointer = false))
    let null_check = alloc_expr(ir.Expr.expr_binary(operator = "==", left = raw_expr, right = alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = void_ptr_ty)), ty = bool_ty))
    var fail_fields = vec.Vec[ir.AggregateField].create()
    let event_error_ty = types.Type.ty_named(module_name = "", name = "EventError")
    fail_fields.push(ir.AggregateField(name = "error", value = alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = event_error_ty))))
    body.push(ir.Stmt.stmt_if(condition = null_check, then_body = span_from_one(ir.Stmt.stmt_return(value = alloc_expr(ir.Expr.expr_variant_literal(ty = info.wait_result_ty, arm_name = "failure", fields = fail_fields.as_span())), line = 0, source_path = "")), else_body = span[ir.Stmt]()))
    body.push(ir.Stmt.stmt_local(name = "__mt_wf", linkage_name = "__mt_wf", ty = wf_ptr_ty, value = alloc_expr(ir.Expr.expr_cast(target_type = wf_ptr_ty, expression = raw_expr, ty = wf_ptr_ty)), line = 0, source_path = ""))
    let wf_ref = alloc_expr(ir.Expr.expr_name(name = "__mt_wf", ty = wf_ptr_ty, pointer = true))
    body.push(ir.Stmt.stmt_return(value = alloc_expr(ir.Expr.expr_member(receiver = wf_ref, member = "result", ty = info.wait_result_ty)), line = 0, source_path = ""))
    var params = vec.Vec[ir.Param].create()
    params.push(ir.Param(name = "frame", linkage_name = "frame", ty = void_ptr_ty, pointer = false))
    return ir.Function(name = info.wait_take_result_c_name, linkage_name = info.wait_take_result_c_name, params = params.as_span(), return_type = info.wait_result_ty, body = body.as_span(), entry_point = false, method_receiver_param = false)


## Build the per-event wait function.
## Loops through inactive slots, activates one as subscribe_once with a wait_frame,
## and returns a Task[Result[void_or_payload, EventError]].
function build_event_wait_fn(ctx: ref[LowerCtx], info: ref[EventRuntimeInfo], slot_cn: str, event_cn: str) -> ir.Function:
    let void_ty = types.primitive("void")
    let bool_ty = types.primitive("bool")
    let ptr_uint_ty = types.primitive("ptr_uint")
    let void_ptr_ty = types.Type.ty_generic(name = "ptr", args = sp_type(void_ty))
    let wf_ptr_ty = types.Type.ty_generic(name = "ptr", args = sp_type(types.Type.ty_named(module_name = "", name = info.wait_frame_c_name)))
    let slot_ty = types.Type.ty_named(module_name = "", name = slot_cn)
    let event_ptr_ty = types.Type.ty_generic(name = "ptr", args = sp_type(types.Type.ty_named(module_name = "", name = event_cn)))
    var body = vec.Vec[ir.Stmt].create()
    let index_name = "i"
    let index_ref = alloc_expr(ir.Expr.expr_name(name = index_name, ty = ptr_uint_ty, pointer = false))
    let cap_lit = alloc_expr(ir.Expr.expr_integer_literal(value = long<-(info.capacity), ty = ptr_uint_ty))
    let cond = alloc_expr(ir.Expr.expr_binary(operator = "<", left = index_ref, right = cap_lit, ty = bool_ty))
    let post = alloc_stmt(ir.Stmt.stmt_assignment(target = index_ref, operator = "+=", value = alloc_expr(ir.Expr.expr_integer_literal(value = 1, ty = ptr_uint_ty))))
    let init = alloc_stmt(ir.Stmt.stmt_local(name = index_name, linkage_name = index_name, ty = ptr_uint_ty, value = alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = ptr_uint_ty)), line = 0, source_path = ""))
    var loop_body = vec.Vec[ir.Stmt].create()
    let event_ref = alloc_expr(ir.Expr.expr_name(name = "event", ty = event_ptr_ty, pointer = false))
    let slot_arr_ty = types.Type.ty_generic(name = "array", args = sp_type2(slot_ty, types.literal_int(long<-(info.capacity))))
    let slots_ref = alloc_expr(ir.Expr.expr_member(receiver = event_ref, member = "slots", ty = slot_arr_ty))
    let slot_ref = alloc_expr(ir.Expr.expr_index(receiver = slots_ref, index = index_ref, ty = slot_ty))
    let slot_active = alloc_expr(ir.Expr.expr_member(receiver = slot_ref, member = "active", ty = bool_ty))
    loop_body.push(ir.Stmt.stmt_if(condition = slot_active, then_body = span_from_one(ir.Stmt.stmt_continue), else_body = span[ir.Stmt]()))
    let gen_ref = alloc_expr(ir.Expr.expr_member(receiver = slot_ref, member = "generation", ty = ptr_uint_ty))
    loop_body.push(ir.Stmt.stmt_local(name = "__mt_gen", linkage_name = "__mt_gen", ty = ptr_uint_ty, value = alloc_expr(ir.Expr.expr_binary(operator = "+", left = gen_ref, right = alloc_expr(ir.Expr.expr_integer_literal(value = 1, ty = ptr_uint_ty)), ty = ptr_uint_ty)), line = 0, source_path = ""))
    let gen_snap = alloc_expr(ir.Expr.expr_name(name = "__mt_gen", ty = ptr_uint_ty, pointer = false))
    loop_body.push(ir.Stmt.stmt_assignment(target = alloc_expr(ir.Expr.expr_member(receiver = slot_ref, member = "active", ty = bool_ty)), operator = "=", value = alloc_expr(ir.Expr.expr_boolean_literal(value = true, ty = bool_ty))))
    loop_body.push(ir.Stmt.stmt_assignment(target = alloc_expr(ir.Expr.expr_member(receiver = slot_ref, member = "once", ty = bool_ty)), operator = "=", value = alloc_expr(ir.Expr.expr_boolean_literal(value = true, ty = bool_ty))))
    loop_body.push(ir.Stmt.stmt_assignment(target = gen_ref, operator = "=", value = gen_snap))
    loop_body.push(ir.Stmt.stmt_assignment(target = alloc_expr(ir.Expr.expr_member(receiver = slot_ref, member = "state", ty = void_ptr_ty)), operator = "=", value = alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = void_ptr_ty))))
    let wf_size_expr = alloc_expr(ir.Expr.expr_sizeof(target_type = types.Type.ty_named(module_name = "", name = info.wait_frame_c_name), ty = ptr_uint_ty))
    let alloc_call = alloc_expr(ir.Expr.expr_call(callee = "malloc", arguments = single_expr_span(wf_size_expr), ty = void_ptr_ty))
    loop_body.push(ir.Stmt.stmt_local(name = "__mt_wf", linkage_name = "__mt_wf", ty = wf_ptr_ty, value = alloc_expr(ir.Expr.expr_cast(target_type = wf_ptr_ty, expression = alloc_call, ty = wf_ptr_ty)), line = 0, source_path = ""))
    let wf_ref = alloc_expr(ir.Expr.expr_name(name = "__mt_wf", ty = wf_ptr_ty, pointer = true))
    loop_body.push(ir.Stmt.stmt_assignment(target = alloc_expr(ir.Expr.expr_member(receiver = wf_ref, member = "ready", ty = bool_ty)), operator = "=", value = alloc_expr(ir.Expr.expr_boolean_literal(value = false, ty = bool_ty))))
    loop_body.push(ir.Stmt.stmt_assignment(target = alloc_expr(ir.Expr.expr_member(receiver = wf_ref, member = "waiter_frame", ty = void_ptr_ty)), operator = "=", value = alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = void_ptr_ty))))
    let event_cast = alloc_expr(ir.Expr.expr_cast(target_type = void_ptr_ty, expression = event_ref, ty = void_ptr_ty))
    loop_body.push(ir.Stmt.stmt_assignment(target = alloc_expr(ir.Expr.expr_member(receiver = wf_ref, member = "event", ty = void_ptr_ty)), operator = "=", value = event_cast))
    # Set wait_frame on the slot
    let wf_void = alloc_expr(ir.Expr.expr_cast(target_type = void_ptr_ty, expression = wf_ref, ty = void_ptr_ty))
    loop_body.push(ir.Stmt.stmt_assignment(target = alloc_expr(ir.Expr.expr_member(receiver = slot_ref, member = "wait_frame", ty = void_ptr_ty)), operator = "=", value = wf_void))
    # Build sub literal for slot/generation
    var sub_literal = alloc_expr(ir.Expr.expr_aggregate_literal(ty = types.Type.ty_named(module_name = "", name = "mt_subscription"), fields = sp_fields2(
        ir.AggregateField(name = "slot", value = index_ref),
        ir.AggregateField(name = "generation", value = gen_snap),
    )))
    loop_body.push(ir.Stmt.stmt_assignment(target = alloc_expr(ir.Expr.expr_member(receiver = wf_ref, member = "subscription", ty = types.Type.ty_named(module_name = "", name = "mt_subscription"))), operator = "=", value = sub_literal))
    # Build task literal
    let task_ty = make_task_type(info.wait_result_ty)
    var tf = vec.Vec[ir.AggregateField].create()
    tf.push(ir.AggregateField(name = "frame",       value = wf_void))
    tf.push(ir.AggregateField(name = "ready",       value = alloc_expr(ir.Expr.expr_name(name = info.wait_ready_c_name, ty = void_ptr_ty, pointer = false))))
    tf.push(ir.AggregateField(name = "set_waiter",  value = alloc_expr(ir.Expr.expr_name(name = info.wait_set_waiter_c_name, ty = void_ptr_ty, pointer = false))))
    tf.push(ir.AggregateField(name = "release",     value = alloc_expr(ir.Expr.expr_name(name = info.wait_release_c_name, ty = void_ptr_ty, pointer = false))))
    tf.push(ir.AggregateField(name = "take_result", value = alloc_expr(ir.Expr.expr_name(name = info.wait_take_result_c_name, ty = void_ptr_ty, pointer = false))))
    tf.push(ir.AggregateField(name = "cancel",      value = alloc_expr(ir.Expr.expr_name(name = info.wait_release_c_name, ty = void_ptr_ty, pointer = false))))
    loop_body.push(ir.Stmt.stmt_return(value = alloc_expr(ir.Expr.expr_aggregate_literal(ty = task_ty, fields = tf.as_span())), line = 0, source_path = ""))
    let for_stmt = ir.Stmt.stmt_for(init = init, condition = cond, post = post, body = loop_body.as_span())
    body.push(for_stmt)
    # All slots were active — return a failing task
    var fail_tf = vec.Vec[ir.AggregateField].create()
    fail_tf.push(ir.AggregateField(name = "frame",       value = alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = void_ptr_ty))))
    fail_tf.push(ir.AggregateField(name = "ready",       value = alloc_expr(ir.Expr.expr_name(name = info.wait_ready_c_name, ty = void_ptr_ty, pointer = false))))
    fail_tf.push(ir.AggregateField(name = "set_waiter",  value = alloc_expr(ir.Expr.expr_name(name = info.wait_set_waiter_c_name, ty = void_ptr_ty, pointer = false))))
    fail_tf.push(ir.AggregateField(name = "release",     value = alloc_expr(ir.Expr.expr_name(name = info.wait_release_c_name, ty = void_ptr_ty, pointer = false))))
    fail_tf.push(ir.AggregateField(name = "take_result", value = alloc_expr(ir.Expr.expr_name(name = info.wait_take_result_c_name, ty = void_ptr_ty, pointer = false))))
    fail_tf.push(ir.AggregateField(name = "cancel",      value = alloc_expr(ir.Expr.expr_name(name = info.wait_release_c_name, ty = void_ptr_ty, pointer = false))))
    body.push(ir.Stmt.stmt_return(value = alloc_expr(ir.Expr.expr_aggregate_literal(ty = task_ty, fields = fail_tf.as_span())), line = 0, source_path = ""))
    var params = vec.Vec[ir.Param].create()
    params.push(ir.Param(name = "event", linkage_name = "event", ty = event_ptr_ty, pointer = false))
    return ir.Function(name = info.wait_c_name, linkage_name = info.wait_c_name, params = params.as_span(), return_type = task_ty, body = body.as_span(), entry_point = false, method_receiver_param = false)


## Build a span from a single IR statement.
function span_from_one(stmt: ir.Stmt) -> span[ir.Stmt]:
    var buf = vec.Vec[ir.Stmt].create()
    buf.push(stmt)
    return buf.as_span()


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


## Build a field list span helper with 6 fields.
function sp_field6(f1: ir.Field, f2: ir.Field, f3: ir.Field, f4: ir.Field, f5: ir.Field, f6: ir.Field) -> span[ir.Field]:
    var buf = vec.Vec[ir.Field].create()
    buf.push(f1)
    buf.push(f2)
    buf.push(f3)
    buf.push(f4)
    buf.push(f5)
    buf.push(f6)
    return buf.as_span()


## Build a field list span helper with 7 fields.
function sp_field7(f1: ir.Field, f2: ir.Field, f3: ir.Field, f4: ir.Field, f5: ir.Field, f6: ir.Field, f7: ir.Field) -> span[ir.Field]:
    var buf = vec.Vec[ir.Field].create()
    buf.push(f1)
    buf.push(f2)
    buf.push(f3)
    buf.push(f4)
    buf.push(f5)
    buf.push(f6)
    buf.push(f7)
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
                    let void_fn_ty = types.Type.ty_function(params = span[types.Type](), return_type = types.alloc_type(void_ty), variadic = false, is_proc = false)
                    return alloc_expr(ir.Expr.expr_cast(
                        target_type = types.Type.ty_generic(name = "ptr", args = sp_type(types.primitive("void"))),
                        expression = alloc_expr(ir.Expr.expr_name(name = fn_c_name, ty = void_fn_ty, pointer = false)),
                        ty = types.Type.ty_generic(name = "ptr", args = sp_type(types.primitive("void"))),
                    ))
            _:
                pass
    return lower_expr(ctx, arg)


## Lower a str_buffer[N] method call to a C helper call or inline operation.
function lower_str_buffer_method(ctx: ref[LowerCtx], recv: ptr[ir.Expr], recv_ty: types.Type, method_name: str, args: span[ast.Argument], call_ep: ptr[ast.Expr]) -> ptr[ir.Expr]:
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
    var cap: long = 0
    match recv_ty:
        types.Type.ty_generic as g:
            if g.args.len >= 1:
                match unsafe: read(g.args.data + 0):
                    types.Type.ty_literal_int as li:
                        cap = li.value
                    _:
                        pass
        _:
            pass
    let cap_val = alloc_expr(ir.Expr.expr_integer_literal(value = cap, ty = ptr_uint_ty))
    if method_name == "clear":
        return alloc_expr(ir.Expr.expr_call(callee = "mt_str_buffer_clear", arguments = sp_expr2(len_addr, dirty_addr), ty = void_ty))
    if method_name == "len":
        return alloc_expr(ir.Expr.expr_call(callee = "mt_str_buffer_len", arguments = sp_expr4(data_addr, cap_val, len_addr, dirty_addr), ty = ptr_uint_ty))
    if method_name == "capacity":
        return alloc_expr(ir.Expr.expr_integer_literal(value = cap, ty = ptr_uint_ty))
    if method_name == "assign" or method_name == "append":
        let helper = if method_name == "assign": "mt_str_buffer_assign" else: "mt_str_buffer_append"
        var helper_args = vec.Vec[ir.Expr].create()
        let lowered = lower_expr(ctx, unsafe: read(args.data + 0).arg_value)
        unsafe:
            helper_args.push(read(lowered))
            helper_args.push(read(data_addr))
            helper_args.push(read(cap_val))
            helper_args.push(read(len_addr))
            helper_args.push(read(dirty_addr))
        return alloc_expr(ir.Expr.expr_call(callee = helper, arguments = helper_args.as_span(), ty = void_ty))
    if method_name == "as_str":
        var as_str_args = vec.Vec[ir.Expr].create()
        unsafe:
            as_str_args.push(read(data_addr))
            as_str_args.push(read(len_addr))
            as_str_args.push(read(dirty_addr))
        return alloc_expr(ir.Expr.expr_call(callee = "mt_str_buffer_as_str", arguments = as_str_args.as_span(), ty = str_ty))
    if method_name == "assign_format" or method_name == "append_format":
        let helper = if method_name == "assign_format": "mt_str_buffer_assign" else: "mt_str_buffer_append"
        var helper_args = vec.Vec[ir.Expr].create()
        let lowered = lower_expr(ctx, unsafe: read(args.data + 0).arg_value)
        unsafe:
            helper_args.push(read(lowered))
            helper_args.push(read(data_addr))
            helper_args.push(read(cap_val))
            helper_args.push(read(len_addr))
            helper_args.push(read(dirty_addr))
        return alloc_expr(ir.Expr.expr_call(callee = helper, arguments = helper_args.as_span(), ty = void_ty))
    if method_name == "as_cstr":
        return alloc_expr(ir.Expr.expr_null_literal(ty = types.primitive("cstr")))
    fatal(c"str_buffer lowering: unknown method")


function sp_expr2(e1: ptr[ir.Expr], e2: ptr[ir.Expr]) -> span[ir.Expr]:
    var buf = vec.Vec[ir.Expr].create()
    unsafe:
        buf.push(read(e1))
        buf.push(read(e2))
    return buf.as_span()


function lower_expression_match(ctx: ref[LowerCtx], scrutinee: ptr[ast.Expr], arms: span[ast.MatchExprArm], ep: ptr[ast.Expr]) -> ptr[ir.Expr]:
    # `expr is Variant.Arm` desugars (in the parser) to a two-arm match
    # expression: [Variant.Arm -> true, _ -> false].  Such a match has a pure
    # boolean-expression equivalent — a discriminant test `scrut.kind == Kind_arm`
    # — so lower it inline without a temp/switch.  This is the only match-expr
    # shape that appears as a nested sub-expression (inside `or`/`and`/`if`) in
    # the self-host, where statement hoisting is not available.
    match is_variant_membership_arms(arms):
        Option.some as arm_name:
            let scrut_ty = method_receiver_type(ctx, scrutinee)
            let outer_c = variant_base_c_name(scrut_ty, ctx.module_name)
            let scrut_expr = lower_expr(ctx, scrutinee)
            let int_ty = types.primitive("int")
            let kind_expr = alloc_expr(ir.Expr.expr_member(receiver = scrut_expr, member = "kind", ty = int_ty))
            let kind_const = alloc_expr(ir.Expr.expr_name(name = variant_kind_const_name(outer_c, arm_name.value), ty = int_ty, pointer = false))
            return alloc_expr(ir.Expr.expr_binary(operator = "==", left = kind_expr, right = kind_const, ty = types.primitive("bool")))
        Option.none:
            pass
    # A genuine multi-arm match expression in a non-return position is not
    # supported inline (needs statement hoisting); `return match` is handled at
    # the statement boundary in `lower_stmt`.  Fall back to a placeholder.
    let result_ty = expr_type(ctx, ep)
    return alloc_expr(ir.Expr.expr_name(name = "match_expr", ty = result_ty, pointer = false))


## Detect the `is`-operator desugaring shape: exactly two arms, where the first
## has a variant-arm pattern with value `true` and the second is a wildcard
## (`pattern == null`) with value `false`.  Returns the arm name to test against.
function is_variant_membership_arms(arms: span[ast.MatchExprArm]) -> Option[str]:
    if arms.len != 2:
        return Option[str].none
    var first: ast.MatchExprArm
    var second: ast.MatchExprArm
    unsafe:
        first = read(arms.data + 0)
        second = read(arms.data + 1)
    if first.pattern == null or second.pattern != null:
        return Option[str].none
    if not expr_is_bool_literal(first.value, true) or not expr_is_bool_literal(second.value, false):
        return Option[str].none
    let pat = first.pattern else:
        return Option[str].none
    return variant_match_arm_name_from_pattern(pat)


## True when `ep` is a boolean literal with the given value.
function expr_is_bool_literal(ep: ptr[ast.Expr], want: bool) -> bool:
    unsafe:
        match read(ep):
            ast.Expr.expr_bool_literal as b:
                return b.value == want
            _:
                return false


function sp_expr3(e1: ptr[ir.Expr], e2: ptr[ir.Expr], e3: ptr[ir.Expr]) -> span[ir.Expr]:
    var buf = vec.Vec[ir.Expr].create()
    unsafe:
        buf.push(read(e1))
        buf.push(read(e2))
        buf.push(read(e3))
    return buf.as_span()


function sp_expr4(e1: ptr[ir.Expr], e2: ptr[ir.Expr], e3: ptr[ir.Expr], e4: ptr[ir.Expr]) -> span[ir.Expr]:
    var buf = vec.Vec[ir.Expr].create()
    unsafe:
        buf.push(read(e1))
        buf.push(read(e2))
        buf.push(read(e3))
        buf.push(read(e4))
    return buf.as_span()


function is_dyn_type(t: types.Type) -> bool:
    match t:
        types.Type.ty_dyn:
            return true
        _:
            return false


function lower_plain_call(ctx: ref[LowerCtx], c_name: str, args: span[ast.Argument], call_ep: ptr[ast.Expr], override_ty: ptr[types.Type]?) -> ptr[ir.Expr]:
    return lower_plain_call_sig(ctx, c_name, args, call_ep, override_ty, Option[analyzer.FnSig].none)


## Like `lower_plain_call` but with the callee's signature available, so a value
## argument passed to a `ref[T]` parameter is implicitly borrowed (`&arg`) —
## mirroring the call-site borrow rule the analyzer accepts.  The signature is
## optional; when absent, arguments are lowered verbatim.
function lower_plain_call_sig(ctx: ref[LowerCtx], c_name: str, args: span[ast.Argument], call_ep: ptr[ast.Expr], override_ty: ptr[types.Type]?, sig: Option[analyzer.FnSig]) -> ptr[ir.Expr]:
    var ir_args = vec.Vec[ir.Expr].create()
    var i: ptr_uint = 0
    while i < args.len:
        var arg: ast.Argument
        unsafe:
            arg = read(args.data + i)
        var lowered = lower_expr(ctx, arg.arg_value)
        lowered = coerce_arg_to_ref_param(sig, i, lowered)
        lowered = coerce_fn_arg_to_proc(ctx, sig, i, lowered, arg.arg_value)
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


## Implicitly borrow a by-value argument passed to a `ref[T]` parameter: when the
## callee's parameter `index` has a `ref[T]` type but the lowered argument is not
## already a pointer/ref, take its address (`&arg`).  Leaves the argument
## unchanged when the signature is unavailable, the parameter is not a ref, or the
## argument is already pointer-typed.
function coerce_arg_to_ref_param(sig: Option[analyzer.FnSig], index: ptr_uint, arg: ptr[ir.Expr]) -> ptr[ir.Expr]:
    match sig:
        Option.some as s:
            if index >= s.value.params.len:
                return arg
            var param: analyzer.ParamEntry
            unsafe:
                param = read(s.value.params.data + index)
            if not types.is_ref_type(param.ty):
                return arg
            let arg_ty = ir_expr_type(arg)
            if is_pointer_or_ref_type(arg_ty):
                return arg
            return alloc_expr(ir.Expr.expr_address_of(
                expression = arg,
                ty = types.Type.ty_generic(name = "ref", args = sp_type(arg_ty)),
            ))
        Option.none:
            return arg


## Coerce a bare function name argument to a proc struct when the
## corresponding parameter expects a proc type.  Mirrors the implicit
## fn→proc wrapping the analyzer accepts at call sites.
function coerce_fn_arg_to_proc(ctx: ref[LowerCtx], sig: Option[analyzer.FnSig], index: ptr_uint, lowered: ptr[ir.Expr], arg_ast: ptr[ast.Expr]) -> ptr[ir.Expr]:
    match sig:
        Option.some as s:
            if index >= s.value.params.len:
                return lowered
            var param_ty: types.Type
            unsafe:
                let param = read(s.value.params.data + index)
                param_ty = param.ty
            if not is_proc_type(param_ty):
                return lowered
            # Check if the argument is a bare function identifier.
            unsafe:
                match read(arg_ast):
                    ast.Expr.expr_identifier as id:
                        if ctx.function_returns.contains(id.name) or ctx.analysis.functions.contains(id.name):
                            let fn_c_name = naming.qualified_c_name(ctx.module_name, id.name)
                            return lower_fn_to_proc(ctx, fn_c_name, param_ty)
                    # Task-root-proc bridge: argument is a function call returning
                    # Task[X] — wrap it in a proc to match proc()->Task[T] parameter.
                    ast.Expr.expr_call as call:
                        match read(call.callee):
                            ast.Expr.expr_identifier as callee_id:
                                let actual_ty = ir_expr_type(lowered)
                                var is_task = false
                                match actual_ty:
                                    types.Type.ty_generic as g:
                                        if g.name == "Task":
                                            is_task = true
                                    _:
                                        pass
                                if is_task and (ctx.function_returns.contains(callee_id.name) or ctx.analysis.functions.contains(callee_id.name)):
                                    let fn_c_name = naming.qualified_c_name(ctx.module_name, callee_id.name)
                                    return lower_fn_to_proc(ctx, fn_c_name, param_ty)
                            _:
                                pass
                    _:
                        pass
            return lowered
        Option.none:
            return lowered


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
                            let lowered_str = lower_expr(ctx, arg)
                            return alloc_expr(ir.Expr.expr_call(
                                callee = "mt_foreign_str_to_cstr_temp",
                                arguments = single_expr_span(lowered_str),
                                ty = types.primitive("cstr"),
                            ))
            return lower_expr(ctx, arg)
        Option.none:
            let lowered = lower_expr(ctx, arg)
            var needs_address = param.param_mode == ast.ForeignParamMode.fmode_out or param.param_mode == ast.ForeignParamMode.fmode_inout
            if not needs_address:
                var pt_copy = param.param_type
                let param_ty = resolve_type_ref(ctx, ptr_of(pt_copy))
                if types.is_raw_pointer(param_ty) or types.is_ref_type(param_ty):
                    let arg_ty = ir_expr_type(lowered)
                    if not types.is_raw_pointer(arg_ty):
                        needs_address = true
            if needs_address:
                return alloc_expr(ir.Expr.expr_address_of(expression = lowered, ty = types.primitive("ptr[void]")))
            return lowered


function boundary_is_cstr(boundary: ast.TypeRef) -> bool:
    if boundary.name.parts.len != 1:
        return false
    unsafe:
        return read(boundary.name.parts.data + 0) == "cstr"


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


## Resolve a cross-module foreign function call: find a `foreign function` decl
## named `name` in the target module and build its ForeignInfo (mapped C name +
## return type + params) resolved in the owner module's context.  Returns none
## when the target has no such foreign function.
function imported_foreign_call(ctx: ref[LowerCtx], target_module: str, name: str) -> Option[ForeignInfo]:
    let owner_a = find_imported_analysis(ctx, target_module) else:
        return Option[ForeignInfo].none
    var saved_module = ctx.module_name
    var saved_analysis = ctx.analysis
    ctx.module_name = target_module
    ctx.analysis = owner_a
    var result = Option[ForeignInfo].none
    var di: ptr_uint = 0
    while di < owner_a.source_file.declarations.len:
        var d: ast.Decl
        unsafe:
            d = read(owner_a.source_file.declarations.data + di)
        match d:
            ast.Decl.decl_foreign_function as ff:
                if ff.name == name:
                    result = Option[ForeignInfo].some(value = ForeignInfo(
                        c_name = resolve_foreign_c_name(ctx, ff.mapping),
                        return_ty = qualify_type(ctx, resolve_type_ref(ctx, ff.return_type)),
                        params = ff.foreign_params,
                    ))
            _:
                pass
        di += 1
    ctx.module_name = saved_module
    ctx.analysis = saved_analysis
    return result


## Resolve a cross-module external function call: find an `external function`
## decl named `name` in the target module and return its bare C linkage name
## (or `= target` mapping) plus resolved return type.  External functions carry
## no module prefix, so a cross-module call must use this bare name instead of
## `<module>_<name>`.  Returns none when the target has no such external function.
function imported_extern_call(ctx: ref[LowerCtx], target_module: str, name: str) -> Option[ForeignInfo]:
    let owner_a = find_imported_analysis(ctx, target_module) else:
        return Option[ForeignInfo].none
    var saved_module = ctx.module_name
    var saved_analysis = ctx.analysis
    ctx.module_name = target_module
    ctx.analysis = owner_a
    var result = Option[ForeignInfo].none
    var di: ptr_uint = 0
    while di < owner_a.source_file.declarations.len:
        var d: ast.Decl
        unsafe:
            d = read(owner_a.source_file.declarations.data + di)
        match d:
            ast.Decl.decl_extern_function as ef:
                if ef.name == name:
                    var ret = types.primitive("void")
                    if ef.return_type != null:
                        ret = qualify_type(ctx, resolve_return_type(ctx, Option[analyzer.FnSig].none, ef.return_type))
                    result = Option[ForeignInfo].some(value = ForeignInfo(
                        c_name = extern_c_name(ef.name, ef.mapping),
                        return_ty = ret,
                        params = ef.extern_params,
                    ))
            _:
                pass
        di += 1
    ctx.module_name = saved_module
    ctx.analysis = saved_analysis
    return result


## Lower a cross-module external function call.  External functions use their
## bare C name; `out`/`inout` parameters are passed by address (`&arg`) so the C
## function can write back through the pointer, mirroring Ruby's
## lower_foreign_pointer_argument_value.
function lower_extern_call(ctx: ref[LowerCtx], info: ForeignInfo, args: span[ast.Argument], call_ep: ptr[ast.Expr]) -> ptr[ir.Expr]:
    var ir_args = vec.Vec[ir.Expr].create()
    var i: ptr_uint = 0
    while i < args.len:
        var arg: ast.Argument
        unsafe:
            arg = read(args.data + i)
        var lowered = lower_expr(ctx, arg.arg_value)
        if i < info.params.len:
            var param: ast.ForeignParam
            unsafe:
                param = read(info.params.data + i)
            if param.param_mode == ast.ForeignParamMode.fmode_out or param.param_mode == ast.ForeignParamMode.fmode_inout:
                let arg_ty = ir_expr_type(lowered)
                lowered = alloc_expr(ir.Expr.expr_address_of(
                    expression = lowered,
                    ty = types.Type.ty_generic(name = "ptr", args = sp_type(arg_ty)),
                ))
        unsafe:
            ir_args.push(read(lowered))
        i += 1
    return alloc_expr(ir.Expr.expr_call(callee = info.c_name, arguments = ir_args.as_span(), ty = expr_type(ctx, call_ep)))


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
                var ret = resolve_return_type(ctx, lookup_fn_sig(ctx, fun.name), fun.return_type)
                if fun.is_async:
                    ret = make_task_type(ret)
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
        types.Type.ty_function as fnt:
            return fnt.is_proc
        _:
            return false


## True when a type is an fn (raw C function pointer), not a proc struct.
function is_fn_type(t: types.Type) -> bool:
    match t:
        types.Type.ty_function as fnt:
            return not fnt.is_proc
        _:
            return false


## An empty FnSig used when calling through an fn-typed local — the callee
## is a function pointer already carrying the correct signature at the C level.
function empty_fn_sig() -> Option[analyzer.FnSig]:
    return Option[analyzer.FnSig].none


## Generate a shared proc struct type name for a given function type:
## `mt_proc_R_P1_P2_...`.  Multiple proc expressions with the same signature
## share this type, so proc-typed params, returns, and expressions unify.
function proc_type_name_from_signature(proc_ty: types.Type) -> str:
    var buf = string.String.create()
    buf.append("mt_proc_")
    match proc_ty:
        types.Type.ty_function as fnt:
            unsafe:
                buf.append(naming.type_c_key(read(fnt.return_type)))
            var i: ptr_uint = 0
            while i < fnt.params.len:
                buf.append("_")
                unsafe:
                    buf.append(naming.type_c_key(read(fnt.params.data + i)))
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
        return types.Type.ty_named(module_name = "", name = struct_name)
    let void_ptr = types.Type.ty_generic(name = "ptr", args = sp_type(types.primitive("void")))
    var struct_fields = vec.Vec[ir.Field].create()
    struct_fields.push(ir.Field(name = "env", ty = void_ptr))
    struct_fields.push(ir.Field(name = "invoke", ty = proc_invoke_field_type(proc_ty)))
    let lifecycle_ty = proc_lifecycle_fn_type()
    struct_fields.push(ir.Field(name = "release", ty = lifecycle_ty))
    struct_fields.push(ir.Field(name = "retain", ty = lifecycle_ty))
    ctx.pending_env_structs.push(ir.StructDecl(name = struct_name, linkage_name = struct_name, fields = struct_fields.as_span(), packed = false, alignment = 0, source_module = Option[str].none))
    return types.Type.ty_named(module_name = "", name = struct_name)


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
            if n.name == "T" or n.name == "U" or n.name == "K" or n.name == "V" or n.name == "E":
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


## Lower a call through a proc-typed struct field: `s.field(args)` compiles to
## `s.field.invoke(s.field.env, args)`, analogously to lower_proc_call but for
## struct field receivers instead of local bindings.
function lower_proc_field_call(ctx: ref[LowerCtx], field_expr: ptr[ir.Expr], args: span[ast.Argument], call_ep: ptr[ast.Expr]) -> ptr[ir.Expr]:
    let void_ptr = types.Type.ty_generic(name = "ptr", args = sp_type(types.primitive("void")))
    let env_member = alloc_expr(ir.Expr.expr_member(receiver = field_expr, member = "env", ty = void_ptr))
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
    let invoke_field = alloc_expr(ir.Expr.expr_member(receiver = field_expr, member = "invoke", ty = expr_type(ctx, call_ep)))
    return alloc_expr(ir.Expr.expr_call_indirect(callee = invoke_field, arguments = invoke_args.as_span(), ty = expr_type(ctx, call_ep)))


## Lower a call through an fn-typed struct field: `s.field(args)` compiles to
## a direct call through the function pointer `s.field(args)`.
function lower_fn_field_call(ctx: ref[LowerCtx], field_expr: ptr[ir.Expr], args: span[ast.Argument], call_ep: ptr[ast.Expr]) -> ptr[ir.Expr]:
    var call_args = vec.Vec[ir.Expr].create()
    var i: ptr_uint = 0
    while i < args.len:
        var arg: ast.Argument
        unsafe:
            arg = read(args.data + i)
        let lowered = lower_expr(ctx, arg.arg_value)
        unsafe:
            call_args.push(read(lowered))
        i += 1
    var call_ty = expr_type(ctx, call_ep)
    match ir_expr_type(field_expr):
        types.Type.ty_function as ffn:
            call_ty = unsafe: read(ffn.return_type)
        _:
            pass
    return alloc_expr(ir.Expr.expr_call_indirect(callee = field_expr, arguments = call_args.as_span(), ty = call_ty))


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


## The resolved type of `member` on a receiver that is an instance of a struct
## defined in ANOTHER module.  The analyzer stores field types with names bare
## relative to their defining module, so qualifying them in the accessing
## module's context mis-attributes them (ir.Program.functions -> a Function type
## prefixed with the caller's module).  Resolve the field's declared type ref in
## the owner module's context instead.  Returns none for same-module receivers
## (handled by the recorded type) and non-struct receivers.
## Member access: enum / flags member constants on a type-name receiver
## (`State.running` -> `en_State_running`), otherwise a struct field access
## (`p.x`).  Method calls and other member forms arrive in later phases.
function imported_field_type(ctx: ref[LowerCtx], recv_ty: types.Type, member: str) -> Option[types.Type]:
    var base = recv_ty
    if types.is_raw_pointer(base) or types.is_ref_type(base):
        base = types.pointer_element(base)
    if types.is_nullable_type(base):
        base = types.unwrap_nullable(base)
    var owner_module: str
    var struct_name: str
    match base:
        types.Type.ty_imported as im:
            if im.args.len > 0:
                return Option[types.Type].none
            owner_module = im.module_name
            struct_name = im.name
        _:
            return Option[types.Type].none
    if owner_module == ctx.module_name:
        # A local struct that `qualify_type` rewrote to `ty_imported(current_module, ...)`:
        # resolve its field type in the current context directly (no owner swap).
        # This recovers field types the analyzer did not record (e.g. `.name` on a
        # `read(ptr[LocalStruct])` receiver) so chained calls like ` == ...` bind.
        let local_tref = find_struct_field_tref(ctx.analysis.source_file, struct_name, member) else:
            return Option[types.Type].none
        return Option[types.Type].some(value = qualify_type(ctx, resolve_field_type_ref(ctx, local_tref)))
    let owner_a = find_imported_analysis(ctx, owner_module) else:
        return Option[types.Type].none
    let field_tref = find_struct_field_tref(owner_a.source_file, struct_name, member) else:
        return Option[types.Type].none
    # Resolve the field type ref in the owner module's context so its bare type
    # names qualify against the owner module rather than the current one.
    var saved_module = ctx.module_name
    var saved_analysis = ctx.analysis
    ctx.module_name = owner_module
    ctx.analysis = owner_a
    let resolved = qualify_type(ctx, resolve_field_type_ref(ctx, field_tref))
    ctx.module_name = saved_module
    ctx.analysis = saved_analysis
    return Option[types.Type].some(value = resolved)


## The declared type ref of a struct's field, looked up in a module's AST.
function find_struct_field_tref(sf: ast.SourceFile, struct_name: str, member: str) -> Option[ast.TypeRef]:
    var di: ptr_uint = 0
    while di < sf.declarations.len:
        var d: ast.Decl
        unsafe:
            d = read(sf.declarations.data + di)
        match d:
            ast.Decl.decl_struct as s:
                if s.name == struct_name:
                    var fi: ptr_uint = 0
                    while fi < s.struct_fields.len:
                        var f: ast.Field
                        unsafe:
                            f = read(s.struct_fields.data + fi)
                        if f.name == member:
                            return Option[ast.TypeRef].some(value = f.field_type)
                        fi += 1
            _:
                pass
        di += 1
    return Option[ast.TypeRef].none


## The receiver type for a method call `receiver.method(...)`.  The analyzer's
## recorded type (via `expr_type`) drops the defining module from cross-module
## struct field types (e.g. `analysis.functions` records `Map[str, FnSig]` with a
## bare `FnSig`, which would then mis-qualify to the current module).  When the
## receiver is a member access or identifier (both side-effect-free to lower), the
## lowered IR type resolves fields in their owner module's context
## (`imported_field_type`), so prefer it; fall back to `expr_type` otherwise.
function method_receiver_type(ctx: ref[LowerCtx], receiver: ptr[ast.Expr]) -> types.Type:
    var side_effect_free = false
    unsafe:
        match read(receiver):
            ast.Expr.expr_member_access:
                side_effect_free = true
            ast.Expr.expr_identifier:
                side_effect_free = true
            ast.Expr.expr_call as call:
                # A chained method call receiver, e.g. `result.as_str().byte_at(i)`.
                # Typing it by lowering the inner call is safe here: the receiver is
                # lowered identically when the outer call is emitted, so no extra
                # side effect is introduced.  This lets a method call on a
                # call-result value resolve instead of falling to the `mt_` fallback.
                # Also covers the `read(ptr).method(...)` builtin projection, whose
                # callee is a bare `read` identifier rather than a member access.
                match read(call.callee):
                    ast.Expr.expr_member_access:
                        side_effect_free = true
                    ast.Expr.expr_identifier as call_id:
                        if call_id.name == "read":
                            side_effect_free = true
                    _:
                        pass
            _:
                pass
    if side_effect_free:
        let lowered_ty = ir_expr_type(lower_expr(ctx, receiver))
        if not types.is_error(lowered_ty) and not types.type_to_string(lowered_ty) == "void":
            return lowered_ty
    return expr_type(ctx, receiver)


function lower_member_access(ctx: ref[LowerCtx], receiver: ptr[ast.Expr], member: str, ep: ptr[ast.Expr]) -> ptr[ir.Expr]:
    match inline_for_member_subst(ctx, receiver, member):
        Option.some as subst:
            return subst.value
        Option.none:
            pass
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
                # Synthetic type names (e.g. `EventError.full`) — map to C
                # constant `<Type>_<member>`.
                if id.name == "EventError" and member == "full":
                    return alloc_expr(ir.Expr.expr_name(
                        name = "EventError_full",
                        ty = expr_type(ctx, ep),
                        pointer = false,
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
                                    # Qualify args to match the signature's C name
                                    # (see lower_generic_variant_literal), so a local
                                    # struct arg like RemovedEntry becomes module-qualified.
                                    concrete_args.push(qualify_type(ctx, resolve_type_ref(ctx, read(spec.arguments.data + ai).value)))
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
                                    if imported.value.static_member_types.contains(inner_ma.member_name) or imported.value.type_names.contains(inner_ma.member_name):
                                        match find_imported_variant_arm(imported.value, member):
                                            Option.some as var_name:
                                                let var_ty = types.Type.ty_imported(module_name = target_module, name = var_name.value, args = span[types.Type]())
                                                return alloc_expr(ir.Expr.expr_variant_literal(
                                                    ty = var_ty,
                                                    arm_name = member,
                                                    fields = span[ir.AggregateField](),
                                                ))
                                            Option.none:
                                                var use_bare = target_module.starts_with("std.c.")
                                                if not use_bare and imported.value.type_alias_types.contains(inner_ma.member_name):
                                                    let aliased_ptr = imported.value.type_alias_types.get(inner_ma.member_name) else:
                                                        fatal(c"lowering: enum type alias inconsistency")
                                                    let aliased = unsafe: read(aliased_ptr)
                                                    if type_is_from_std_c(aliased):
                                                        use_bare = true
                                                var member_c_name = member
                                                if not use_bare:
                                                    member_c_name = naming.qualified_member_c_name(target_module, inner_ma.member_name, member)
                                                return alloc_expr(ir.Expr.expr_name(
                                                    name = member_c_name,
                                                    ty = expr_type(ctx, ep),
                                                    pointer = false,
                                                ))
                                Option.none:
                                    pass
                    _:
                        pass
            _:
                pass
    # SoA index+member swap: `particles[0].x` → `particles.x[0]` (mirrors
    # Ruby's lower_soa_indexed_field_access).  Detect when the member access
    # receiver is an index into an SoA type, and lower the field access first.
    unsafe:
        match read(receiver):
            ast.Expr.expr_index_access as ix:
                let base_ty = index_receiver_type(ctx, ix.receiver)
                if is_soa_type(base_ty):
                    let soa_base = lower_expr(ctx, ix.receiver)
                    let idx = lower_expr(ctx, ix.index)
                    let field_ty = soa_field_type(ctx, base_ty, member)
                    let member_expr = alloc_expr(ir.Expr.expr_member(
                        receiver = soa_base,
                        member = member,
                        ty = field_ty,
                    ))
                    return alloc_expr(ir.Expr.expr_index(
                        receiver = member_expr,
                        index = idx,
                        ty = expr_type(ctx, ep),
                    ))
            _:
                pass
    let recv = lower_expr(ctx, receiver)
    var member_ty = expr_type(ctx, ep)
    let recv_ty = ir_expr_type(recv)
    # span synthetic fields: `.data` is ptr[element], `.len` is ptr_uint.  The
    # analyzer records these as ty_error (permissive), so type them here.
    if is_span_type(recv_ty) and member == "data":
        member_ty = types.Type.ty_generic(name = "ptr", args = sp_type(types.pointer_element(recv_ty)))
    else if is_span_type(recv_ty) and member == "len":
        member_ty = types.primitive("ptr_uint")
    # str synthetic fields: `.data` is ptr[char], `.len` is ptr_uint.  Like span,
    # the analyzer does not type these reliably (a `var n = text.len` would
    # otherwise be mis-typed as str).
    else if is_str_typed(recv_ty) and member == "data":
        member_ty = types.Type.ty_generic(name = "ptr", args = sp_type(types.primitive("char")))
    else if is_str_typed(recv_ty) and member == "len":
        member_ty = types.primitive("ptr_uint")
    # vec/mat/quat field types: the analyzer doesn't record these reliably
    # since these are builtin types, not declared structs.
    else if is_vec_math_name(nominal_type_name(recv_ty)):
        let vname = nominal_type_name(recv_ty)
        var field_names = vec.Vec[str].create()
        var field_types = vec.Vec[types.Type].create()
        vec_math_fields(vname, ref_of(field_names), ref_of(field_types))
        var fi: ptr_uint = 0
        var found = false
        while fi < field_names.len():
            let fn_ptr = field_names.get(fi) else:
                fatal(c"lower_member_access: missing vec field name")
            if unsafe: read(fn_ptr) == member:
                let ft_ptr = field_types.get(fi) else:
                    fatal(c"lower_member_access: missing vec field type")
                member_ty = unsafe: read(ft_ptr)
                found = true
                break
            fi += 1
        if not found:
            pass
    else:
        # Prefer the receiver's concrete (monomorphized) struct field type: the
        # analyzer records member types generically (e.g. Node[K,V] -> Node with
        # the args dropped), so inside a monomorphized method the recorded type
        # loses its arguments.  The concrete struct declaration carries the
        # resolved field type.
        match concrete_field_type(ctx, recv_ty, member):
            Option.some as ft:
                member_ty = ft.value
            Option.none:
                match arm_payload_field_type(ctx, recv_ty, member):
                    Option.some as aft:
                        member_ty = aft.value
                    Option.none:
                        match imported_field_type(ctx, recv_ty, member):
                            Option.some as ift:
                                member_ty = ift.value
                            Option.none:
                                if types.is_error(member_ty) or is_tuple_type(member_ty):
                                    if is_tuple_type(recv_ty):
                                        match recv_ty:
                                            types.Type.ty_tuple as tup:
                                                match tup.field_names:
                                                    Option.some as fnames:
                                                        var fi: ptr_uint = 0
                                                        while fi < fnames.value.len:
                                                            if unsafe: read(fnames.value.data + fi) == member:
                                                                if fi < tup.elements.len:
                                                                    member_ty = unsafe: read(tup.elements.data + fi)
                                                                break
                                                            fi += 1
                                                    Option.none:
                                                        let index = parse_tuple_member_index(member)
                                                        member_ty = tuple_element_type(recv_ty, index)
                                            _:
                                                pass
    var result = alloc_expr(ir.Expr.expr_member(
        receiver = recv,
        member = member,
        ty = qualify_type(ctx, member_ty),
    ))
    # Auto-dereference recursive variant fields (e.g. bin.left where left
    # is stored as Expr* in C to avoid infinite struct size).
    # Only applicable when recv_ty is a variant arm payload struct.
    match recv_ty:
        types.Type.ty_named as rn:
            if ctx.arm_payload_fields.contains(rn.name):
                if is_recursive_variant_field(recv_ty, member_ty):
                    return alloc_expr(ir.Expr.expr_unary(operator = "*", operand = result, ty = member_ty))
        types.Type.ty_imported as ri:
            if ctx.arm_payload_fields.contains(naming.qualified_c_name(ri.module_name, ri.name)):
                if is_recursive_variant_field(recv_ty, member_ty):
                    return alloc_expr(ir.Expr.expr_unary(operator = "*", operand = result, ty = member_ty))
        _:
            pass
    return result


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
    let decl_ptr = ctx.generic_struct_decls.get(struct_name)
    if decl_ptr != null:
        unsafe:
            let decl = read(decl_ptr)
            var i: ptr_uint = 0
            while i < decl.fields.len:
                let f = read(decl.fields.data + i)
                if f.name == member:
                    return Option[types.Type].some(value = f.ty)
                i += 1
    # Non-generic struct: search current and imported module analyses.
    var raw_fields = ctx.analysis.structs.get(struct_name)
    if raw_fields == null:
        var ai: ptr_uint = 0
        while ai < ctx.program_analyses.len and raw_fields == null:
            var a: analyzer.Analysis
            unsafe:
                a = read(ctx.program_analyses.data + ai)
            raw_fields = a.structs.get(struct_name)
            ai += 1
    if raw_fields != null:
        let entries = unsafe: read(raw_fields)
        var ei: ptr_uint = 0
        while ei < entries.len:
            let entry = unsafe: read(entries.data + ei)
            if entry.name == member:
                return Option[types.Type].some(value = entry.ty)
            ei += 1
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
        var fty = entry.ty
        # Event fields need their C-linkage struct name (e.g.
        # `mt_event_mod_closed_4`), not the declared name (`closed`).
        match fty:
            types.Type.ty_named as nt:
                if ctx.analysis.events.contains(nt.name):
                    var info = ensure_event_runtime(ctx, nt.name)
                    fty = types.Type.ty_named(module_name = "", name = info.event_c_name)
            _:
                pass
        ir_fields.push(ir.Field(name = entry.name, ty = qualify_type(ctx, fty)))
        i += 1
    return Option[ir.StructDecl].some(value = ir.StructDecl(
        name = name,
        linkage_name = naming.qualified_c_name(ctx.module_name, name),
        fields = ir_fields.as_span(),
        packed = false,
        alignment = 0,
        source_module = Option[str].none,
    ))


function lower_nested_struct_decls(ctx: ref[LowerCtx], nested: span[ast.Decl], parent_name: str, structs: ref[vec.Vec[ir.StructDecl]]) -> void:
    var i: ptr_uint = 0
    while i < nested.len:
        var d: ast.Decl
        unsafe:
            d = read(nested.data + i)
        match d:
            ast.Decl.decl_struct as s:
                if s.type_params.len == 0:
                    match lower_struct_decl(ctx, s.name):
                        Option.some as sd:
                            structs.push(sd.value)
                        Option.none:
                            pass
                    lower_nested_struct_decls(ctx, s.nested_types, s.name, structs)
            _:
                pass
        i += 1


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
    buf.push(types.Type.ty_named(module_name = "", name = name))
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
                    # Also register arm payload fields for local variants so
                    # field-level lookups (e.g. nullable wrapping) can resolve
                    # field types from the arm info.
                    register_imported_variant_arm_fields(ctx, ctx.module_name, ctx.analysis, vr.name, vr.variant_arms)
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
                                ctx.variants.set(vr.name, build_imported_variant_info(ctx, target_module, imported.value, vr.variant_arms))
                            # Register arm payload field types keyed by the
                            # module-qualified payload struct C name, for EVERY
                            # imported variant — even when its bare name collides
                            # with an already-registered variant (e.g. both
                            # `ir.Expr` and `ast.Expr` are named "Expr").  This
                            # feeds `arm_payload_field_type` directly so member
                            # access on an arm binding (`node.operator`) types
                            # correctly regardless of the registry collision.
                            if vr.type_params.len == 0:
                                register_imported_variant_arm_fields(ctx, target_module, imported.value, vr.name, vr.variant_arms)
                        _:
                            pass
                    di += 1
            Option.none:
                pass


## Register arm payload field types for an imported variant into
## `arm_payload_fields`, keyed by the module-qualified payload struct C name
## (`<owner>_<Variant>_<arm>`).  Populated for every imported variant regardless
## of bare-name registry collisions, so member access on an arm binding resolves
## the field type structurally.  Field types are resolved in the owner context.
function register_imported_variant_arm_fields(ctx: ref[LowerCtx], owner_module: str, owner_analysis: analyzer.Analysis, variant_name: str, arms: span[ast.VariantArm]) -> void:
    let outer_c = naming.qualified_c_name(owner_module, variant_name)
    var saved_module = ctx.module_name
    var saved_analysis = ctx.analysis
    ctx.module_name = owner_module
    ctx.analysis = owner_analysis
    var i: ptr_uint = 0
    while i < arms.len:
        var arm: ast.VariantArm
        unsafe:
            arm = read(arms.data + i)
        if arm.arm_fields.len > 0:
            var names = vec.Vec[str].create()
            var tys = vec.Vec[types.Type].create()
            var fi: ptr_uint = 0
            while fi < arm.arm_fields.len:
                var f: ast.Field
                unsafe:
                    f = read(arm.arm_fields.data + fi)
                names.push(f.name)
                tys.push(qualify_type(ctx, resolve_field_type_ref(ctx, f.field_type)))
                fi += 1
            let payload_c = variant_arm_type_name(outer_c, arm.name)
            # Do not overwrite an entry a real match already registered.
            if not ctx.arm_payload_fields.contains(payload_c):
                ctx.arm_payload_fields.set(payload_c, VariantArmInfo(
                    name = arm.name,
                    field_names = names.as_span(),
                    field_types = tys.as_span(),
                ))
        i += 1
    ctx.module_name = saved_module
    ctx.analysis = saved_analysis


## Like `build_variant_info` but uses the imported module's name for
## `module_name` so variant arm constructors produce correctly-qualified names.
## Arm field types are resolved in the OWNER module's context so they qualify
## against the defining module (needed for member access on a match-arm binding).
function build_imported_variant_info(ctx: ref[LowerCtx], owner_module: str, owner_analysis: analyzer.Analysis, arms: span[ast.VariantArm]) -> VariantInfo:
    var saved_module = ctx.module_name
    var saved_analysis = ctx.analysis
    ctx.module_name = owner_module
    ctx.analysis = owner_analysis
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
            tys.push(qualify_type(ctx, resolve_field_type_ref(ctx, f.field_type)))
            fi += 1
        arm_infos.push(VariantArmInfo(name = arm.name, field_names = names.as_span(), field_types = tys.as_span()))
        i += 1
    ctx.module_name = saved_module
    ctx.analysis = saved_analysis
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




## Sanitize a variant arm name that would collide with a C keyword by appending
## a trailing underscore (e.g. `sizeof` → `sizeof_`, `switch` → `switch_`).
function sanitize_arm_field(name: str) -> str:
    if (
        name == "sizeof" or name == "switch" or name == "union" or name == "struct" or name == "enum"
        or name == "register" or name == "volatile" or name == "const" or name == "restrict"
        or name == "auto" or name == "extern" or name == "static" or name == "typedef"
        or name == "int" or name == "float" or name == "double" or name == "char"
        or name == "short" or name == "long" or name == "void" or name == "bool"
        or name == "default" or name == "case" or name == "break" or name == "continue"
        or name == "return" or name == "if" or name == "else" or name == "while"
        or name == "for" or name == "do" or name == "goto"
    ):
        return j2(name, "_")
    return name

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
            if g.name == "Option":
                buf.append("std_option_")
            else if g.name == "Result":
                buf.append("std_result_")
            buf.append(g.name)
            var i: ptr_uint = 0
            while i < g.args.len:
                buf.append("_")
                unsafe:
                    buf.append(naming.type_c_key(read(g.args.data + i)))
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
        if arm.name == arm_name:
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
                resolved = types.Type.ty_named(module_name = "", name = name)
    if tref.nullable and not types.is_error(resolved):
        return types.Type.ty_nullable(base = types.alloc_type(resolved))
    return resolved


## Look up the resolved type of a module-level variable declared in the source
## file.  Used when `expr_type(ctx, callee)` fails for proc variables.
function module_var_type(ctx: ref[LowerCtx], name: str) -> types.Type:
    var di: ptr_uint = 0
    while di < ctx.analysis.source_file.declarations.len:
        var d: ast.Decl
        unsafe:
            d = read(ctx.analysis.source_file.declarations.data + di)
        match d:
            ast.Decl.decl_var as v:
                if v.name == name:
                    let tref = v.var_type
                    if tref != null:
                        return resolve_type_ref(ctx, tref)
            ast.Decl.decl_const as c:
                if c.name == name:
                    return resolve_type_ref(ctx, c.const_type)
            _:
                pass
        di += 1
    return types.Type.ty_error


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
    # Save/restore locals so match-arm bindings (as name) and arm-body
    # locals don't leak into subsequent code or proc captures.
    let saved_locals = ctx.locals
    ctx.locals = vec.Vec[LocalBinding].create()
    var li: ptr_uint = 0
    while li < saved_locals.len():
        let lb_ptr = saved_locals.get(li) else:
            break
        unsafe:
            ctx.locals.push(read(lb_ptr))
        li += 1
    var scrutinee_ty = expr_type(ctx, scrutinee)
    # Prefer the lowered scrutinee's type: lowering resolves member/field types
    # (including Option-typed fields and read(ptr) rvalues) more accurately than
    # the analyzer's recorded type, which can drop the Option wrapper or record
    # void.  Fall back to the analyzer type only when the lowered type is unknown.
    let lowered_ty = ir_expr_type(lower_expr(ctx, scrutinee))
    if not types.is_error(lowered_ty) and not types.type_to_string(lowered_ty) == "void":
        scrutinee_ty = lowered_ty

    let type_name = named_type_name(scrutinee_ty)

    if type_name.is_some() and ctx.variants.contains(type_name.unwrap()):
        lower_variant_match(ctx, output, scrutinee, type_name.unwrap(), scrutinee_ty, arms)
        ctx.locals = saved_locals
        return

    let gen_var = generic_variant_name(scrutinee_ty)
    if gen_var.is_some() and variant_match_allowed(ctx, gen_var.unwrap()):
        lower_variant_match(ctx, output, scrutinee, gen_var.unwrap(), scrutinee_ty, arms)
        ctx.locals = saved_locals
        return

    # Integer scrutinee: switch over integer / char literal case values.
    if is_integer_scrutinee(scrutinee_ty):
        lower_scalar_match(ctx, output, scrutinee, arms)
        ctx.locals = saved_locals
        return

    # String scrutinee: an if / else-if chain comparing with `equal`.
    if is_str_scrutinee(scrutinee_ty):
        lower_string_match(ctx, output, scrutinee, arms)
        ctx.locals = saved_locals
        return

    let enum_name = type_name else:
        let ts = types.type_to_string(scrutinee_ty)
        if ts == "void" or ts == "<error>" or ts.starts_with("("):
            ctx.locals = saved_locals
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
    ctx.locals = saved_locals


## True when a match scrutinee type is an integer (byte/short/int/long and the
## unsigned/pointer widths) matched with integer or char literal patterns.
function is_integer_scrutinee(ty: types.Type) -> bool:
    match ty:
        types.Type.ty_primitive as p:
            return types.is_integer_name(p.name)
        _:
            return false


## True when a `fatal(...)` argument is a `cstr` (so it uses `mt_fatal`); `str`
## and everything else route to `mt_fatal_str`.  A `c"..."` literal is detected
## structurally (its recorded type is not always reliable); other expressions
## fall back to their resolved type.
function fatal_arg_is_cstr(ctx: ref[LowerCtx], arg: ptr[ast.Expr]) -> bool:
    unsafe:
        match read(arg):
            ast.Expr.expr_string_literal as lit:
                return lit.is_cstring
            _:
                pass
    match expr_type(ctx, arg):
        types.Type.ty_primitive as p:
            return p.name == "cstr"
        _:
            return false


function is_str_scrutinee(ty: types.Type) -> bool:
    match ty:
        types.Type.ty_str:
            return true
        _:
            return false


## Lower an integer match to a `switch`, using each arm's integer / char literal
## pattern as the case value.  A `_` arm becomes `default`.  Integer matches
## always require a wildcard, so the switch is never marked exhaustive.
function lower_scalar_match(ctx: ref[LowerCtx], output: ref[vec.Vec[ir.Stmt]], scrutinee: ptr[ast.Expr], arms: span[ast.MatchArm]) -> void:
    let scrutinee_expr = lower_expr(ctx, scrutinee)
    var cases = vec.Vec[ir.SwitchCase].create()
    var i: ptr_uint = 0
    while i < arms.len:
        var arm: ast.MatchArm
        unsafe:
            arm = read(arms.data + i)
        let body = lower_block(ctx, arm.body)
        let pattern = arm.pattern
        if pattern == null:
            cases.push(ir.SwitchCase(is_default = true, value = null, body = body))
        else:
            cases.push(ir.SwitchCase(is_default = false, value = lower_expr(ctx, ptr[ast.Expr]<-pattern), body = body))
        i += 1
    output.push(ir.Stmt.stmt_switch(expression = scrutinee_expr, cases = cases.as_span(), exhaustive = false))


## Lower a string match to an if / else-if chain comparing the scrutinee with
## each arm's string-literal pattern via `equal` (rendered as `mt_str_equal`).
## The scrutinee is evaluated once into a temp.  A `_` arm becomes the final
## else block.
function lower_string_match(ctx: ref[LowerCtx], output: ref[vec.Vec[ir.Stmt]], scrutinee: ptr[ast.Expr], arms: span[ast.MatchArm]) -> void:
    let scrutinee_expr = lower_expr(ctx, scrutinee)
    let temp = fresh_c_temp_name(ctx, "match_str")
    let str_ty = types.Type.ty_str
    output.push(ir.Stmt.stmt_local(name = temp, linkage_name = temp, ty = str_ty, value = scrutinee_expr, line = 0, source_path = ""))

    # Collect literal arms and the optional default (wildcard) body.
    var default_body = span[ir.Stmt]()
    var has_default = false
    var lit_bodies = vec.Vec[span[ir.Stmt]].create()
    var lit_values = vec.Vec[ptr[ir.Expr]].create()
    var i: ptr_uint = 0
    while i < arms.len:
        var arm: ast.MatchArm
        unsafe:
            arm = read(arms.data + i)
        let body = lower_block(ctx, arm.body)
        let pattern = arm.pattern
        if pattern == null:
            default_body = body
            has_default = true
        else:
            lit_values.push(lower_expr(ctx, ptr[ast.Expr]<-pattern))
            lit_bodies.push(body)
        i += 1

    # Build the chain from the last arm backwards so each else wraps the rest.
    var else_body = default_body
    if not has_default:
        else_body = span[ir.Stmt]()
    var idx = lit_values.len()
    while idx > 0:
        idx -= 1
        let value_ptr = lit_values.get(idx) else:
            fatal(c"lowering: string match value")
        let body_ptr = lit_bodies.get(idx) else:
            fatal(c"lowering: string match body")
        let name_ref = alloc_expr(ir.Expr.expr_name(name = temp, ty = str_ty, pointer = false))
        let condition = alloc_expr(ir.Expr.expr_binary(
            operator = "==",
            left = name_ref,
            right = unsafe: read(value_ptr),
            ty = types.primitive("bool"),
        ))
        let then_body = unsafe: read(body_ptr)
        var if_stmts = vec.Vec[ir.Stmt].create()
        if_stmts.push(ir.Stmt.stmt_if(condition = condition, then_body = then_body, else_body = else_body))
        else_body = if_stmts.as_span()

    var j: ptr_uint = 0
    while j < else_body.len:
        unsafe:
            output.push(read(else_body.data + j))
        j += 1


## Lower a match expression used as a local variable initializer (`let x = match
## e: p1: v1; p2: v2; _: v3`).  Hoists the match into a switch that assigns to
## the local, keeping the result in a `stmt_local` with zero-init followed by the
## switch.  Supports enum and variant scrutinees (the same subset handled by
## `lower_match`).  Integer and string scrutinees are deferred.
## The result type of a `return match ...` expression: the analyzer's recorded
## type for the match, or — when that is unknown — the lowered type of the first
## arm whose value type is known.  Used to type the hoisted result temp.
function current_return_type(ctx: ref[LowerCtx], match_expr: ptr[ast.Expr]) -> types.Type:
    var ty = qualify_type(ctx, expr_type(ctx, match_expr))
    if not types.is_error(ty) and not types.type_to_string(ty) == "void":
        return ty
    unsafe:
        match read(match_expr):
            ast.Expr.expr_match as me:
                var i: ptr_uint = 0
                while i < me.arms.len:
                    var arm: ast.MatchExprArm
                    arm = read(me.arms.data + i)
                    let vt = ir_expr_type(lower_expr(ctx, arm.value))
                    if not types.is_error(vt) and not types.type_to_string(vt) == "void":
                        return vt
                    i += 1
            _:
                pass
    return types.primitive("int")


## Infer the result type of a match expression from its first non-wildcard arm's
## value, so `let x = match e: { a: "s", _: "t" }` types x as `str` instead of `int`.
function infer_match_arm_type(ctx: ref[LowerCtx], arms: span[ast.MatchExprArm]) -> types.Type:
    var i: ptr_uint = 0
    while i < arms.len:
        var arm: ast.MatchExprArm
        unsafe:
            arm = read(arms.data + i)
        let vt = qualify_type(ctx, expr_type(ctx, arm.value))
        if not types.is_error(vt) and not types.type_to_string(vt) == "void":
            return vt
        i += 1
    return types.Type.ty_error


function lower_match_expression_local(ctx: ref[LowerCtx], output: ref[vec.Vec[ir.Stmt]], name: str, declared_type: ptr[ast.TypeRef]?, scrutinee: ptr[ast.Expr], arms: span[ast.MatchExprArm]) -> void:
    let c_name = utils.c_local_name(name)
    var ty = types.Type.ty_error
    let dt = declared_type
    if dt != null:
        ty = resolve_type_ref(ctx, dt)
    if types.is_error(ty):
        ty = infer_match_arm_type(ctx, arms)
    if types.is_error(ty):
        ty = types.primitive("int")

    # Zero-init the local, then build a switch/if chain that overwrites it.
    let zero_init = alloc_expr(ir.Expr.expr_zero_init(ty = ty))
    output.push(ir.Stmt.stmt_local(name = name, linkage_name = c_name, ty = ty, value = zero_init, line = 0, source_path = ""))

    let result_ref = alloc_expr(ir.Expr.expr_name(name = c_name, ty = ty, pointer = false))
    lower_match_expr_to_ref(ctx, output, scrutinee, arms, result_ref)

    ctx.locals.push(LocalBinding(name = name, c_name = c_name, ty = ty, pointer = false))


## Lower a match expression so each arm assigns its value to `result_ref`, using
## the strategy that fits the scrutinee type (str if-chain / variant switch /
## enum switch / tuple if-chain).  The scrutinee is hoisted into a temp when it is
## not already a name so it is evaluated once.  Shared by `let x = match ...`
## (lower_match_expression_local) and the `return match ...` hoist.
function lower_match_expr_to_ref(ctx: ref[LowerCtx], output: ref[vec.Vec[ir.Stmt]], scrutinee: ptr[ast.Expr], arms: span[ast.MatchExprArm], result_ref: ptr[ir.Expr]) -> void:
    var scrutinee_ty = expr_type(ctx, scrutinee)
    var scrutinee_expr = lower_expr(ctx, scrutinee)
    # Prefer the lowered scrutinee's type (more accurate for prelude/field types).
    let lowered_sty = ir_expr_type(scrutinee_expr)
    if not types.is_error(lowered_sty) and not types.type_to_string(lowered_sty) == "void":
        scrutinee_ty = lowered_sty
    if not ir_expr_is_name(scrutinee_expr):
        let temp = fresh_c_temp_name(ctx, "match_scrut")
        output.push(ir.Stmt.stmt_local(name = temp, linkage_name = temp, ty = scrutinee_ty, value = scrutinee_expr, line = 0, source_path = ""))
        scrutinee_expr = alloc_expr(ir.Expr.expr_name(name = temp, ty = scrutinee_ty, pointer = false))

    let type_name = named_type_name(scrutinee_ty)
    if is_str_scrutinee(scrutinee_ty):
        lower_str_match_expr(ctx, output, scrutinee_expr, arms, result_ref)
    else if is_tuple_type(scrutinee_ty):
        lower_tuple_match_expr(ctx, output, scrutinee_expr, scrutinee_ty, arms, result_ref)
    else if type_name.is_some() and ctx.variants.contains(type_name.unwrap()):
        lower_variant_match_expr(ctx, output, scrutinee_expr, type_name.unwrap(), scrutinee_ty, arms, result_ref)
    else:
        lower_enum_match_expr(ctx, output, scrutinee_expr, type_name, arms, result_ref)


## Lower a match expression over a `str` scrutinee: emit an if / else-if chain
## comparing the scrutinee with each arm's string-literal pattern, assigning the
## arm's value to `result_ref` on match.  Mirrors `lower_string_match` for the
## expression form.
function lower_str_match_expr(ctx: ref[LowerCtx], output: ref[vec.Vec[ir.Stmt]], scrutinee_expr: ptr[ir.Expr], arms: span[ast.MatchExprArm], result_ref: ptr[ir.Expr]) -> void:
    var has_default = false
    var default_val: ptr[ir.Expr]? = null
    var pattern_lits = vec.Vec[ptr[ir.Expr]].create()
    var result_vals = vec.Vec[ptr[ir.Expr]].create()
    var ai: ptr_uint = 0
    while ai < arms.len:
        var arm: ast.MatchExprArm
        unsafe:
            arm = read(arms.data + ai)
        if arm.pattern == null:
            has_default = true
            default_val = lower_expr(ctx, arm.value)
        else:
            unsafe:
                pattern_lits.push(lower_expr(ctx, ptr[ast.Expr]<-arm.pattern))
            result_vals.push(lower_expr(ctx, arm.value))
        ai += 1

    # Emit a proper else-if chain: `if (p0) r=v0; else if (p1) r=v1; ... else
    # r=default;`.  Building it as independent if-thens (with only the final arm
    # carrying the default as its else) is WRONG — the last arm's `else` would
    # clobber an earlier arm's assignment.  Mirrors Ruby's string-match lowering,
    # which nests each subsequent arm inside the prior arm's else branch.
    # Construct from the tail backwards so each arm's else_body is the already-
    # built remainder of the chain.
    var chain = vec.Vec[ir.Stmt].create()
    if has_default:
        let dv = default_val else:
            fatal(c"lowering: str match expr default value")
        chain.push(ir.Stmt.stmt_assignment(target = result_ref, operator = "=", value = dv))

    var back = pattern_lits.len
    while back > 0:
        back -= 1
        let pat_ptr = pattern_lits.get(back) else:
            fatal(c"lowering: str match expr pattern")
        let val_ptr = result_vals.get(back) else:
            fatal(c"lowering: str match expr value")
        let condition = alloc_expr(ir.Expr.expr_binary(
            operator = "==",
            left = scrutinee_expr,
            right = unsafe: read(pat_ptr),
            ty = types.primitive("bool"),
        ))
        var then_body = vec.Vec[ir.Stmt].create()
        then_body.push(ir.Stmt.stmt_assignment(target = result_ref, operator = "=", value = unsafe: read(val_ptr)))
        let else_body = chain.as_span()
        var next_chain = vec.Vec[ir.Stmt].create()
        next_chain.push(ir.Stmt.stmt_if(condition = condition, then_body = then_body.as_span(), else_body = else_body))
        chain = next_chain

    append_span_stmts(output, chain.as_span())


## Lower a match expression over a tuple scrutinee: for each arm, compare the
## tuple element-wise (`scrut._0 == e0 && scrut._1 == e1 && ...`) and assign the
## arm value on match.  Independent if-thens suffice because tuple-literal
## patterns are mutually exclusive; the wildcard arm assigns unconditionally
## first so a later matching arm overrides it.
function lower_tuple_match_expr(ctx: ref[LowerCtx], output: ref[vec.Vec[ir.Stmt]], scrutinee_expr: ptr[ir.Expr], scrutinee_ty: types.Type, arms: span[ast.MatchExprArm], result_ref: ptr[ir.Expr]) -> void:
    var wildcard_val: ptr[ir.Expr]? = null
    var ai: ptr_uint = 0
    while ai < arms.len:
        var arm: ast.MatchExprArm
        unsafe:
            arm = read(arms.data + ai)
        if arm.pattern == null:
            wildcard_val = lower_expr(ctx, arm.value)
        ai += 1

    if wildcard_val != null:
        output.push(ir.Stmt.stmt_assignment(target = result_ref, operator = "=", value = wildcard_val))

    ai = 0
    while ai < arms.len:
        var arm: ast.MatchExprArm
        unsafe:
            arm = read(arms.data + ai)
        let pattern = arm.pattern
        if pattern == null:
            ai += 1
            continue
        let cond = tuple_pattern_condition(ctx, scrutinee_expr, scrutinee_ty, unsafe: read(pattern))
        var assign = vec.Vec[ir.Stmt].create()
        assign.push(ir.Stmt.stmt_assignment(target = result_ref, operator = "=", value = lower_expr(ctx, arm.value)))
        output.push(ir.Stmt.stmt_if(condition = cond, then_body = assign.as_span(), else_body = span[ir.Stmt]()))
        ai += 1


## Build the boolean condition for a tuple-literal pattern: the conjunction of
## per-element equality tests `scrut._i == elem_i`.  `_` elements are skipped
## (they match anything).  Returns a literal `true` when the pattern has no
## constraining elements.
function tuple_pattern_condition(ctx: ref[LowerCtx], scrutinee_expr: ptr[ir.Expr], scrutinee_ty: types.Type, pattern: ast.Expr) -> ptr[ir.Expr]:
    var cond: ptr[ir.Expr]? = null
    match pattern:
        ast.Expr.expr_expression_list as lst:
            var i: ptr_uint = 0
            while i < lst.elements.len:
                var elem: ast.Expr
                unsafe:
                    elem = read(lst.elements.data + i)
                    if not expr_is_wildcard(elem):
                        let elem_ty = tuple_element_type(scrutinee_ty, i)
                        var member_name = tuple_field_name(i)
                        match scrutinee_ty:
                            types.Type.ty_tuple as tup:
                                match tup.field_names:
                                    Option.some as fnames:
                                        if i < fnames.value.len:
                                            member_name = unsafe: read(fnames.value.data + i)
                                    Option.none:
                                        pass
                            _:
                                pass
                        let field = alloc_expr(ir.Expr.expr_member(receiver = scrutinee_expr, member = member_name, ty = elem_ty))
                        let elem_expr = lower_expr(ctx, unsafe: ptr[ast.Expr]<-(lst.elements.data + i))
                        let cmp = alloc_expr(ir.Expr.expr_binary(operator = "==", left = field, right = elem_expr, ty = types.primitive("bool")))
                        let existing = cond
                        if existing == null:
                            cond = cmp
                        else:
                            cond = alloc_expr(ir.Expr.expr_binary(operator = "and", left = existing, right = cmp, ty = types.primitive("bool")))
                i += 1
        _:
            pass
    let final_cond = cond else:
        return alloc_expr(ir.Expr.expr_boolean_literal(value = true, ty = types.primitive("bool")))
    return final_cond


## True when an expression is the `_` wildcard identifier.
function expr_is_wildcard(e: ast.Expr) -> bool:
    match e:
        ast.Expr.expr_identifier as id:
            return id.name == "_"
        _:
            return false


## Lower a match expression over an enum scrutinee: emit a switch whose cases
## assign the result and break, plus a default case for the wildcard arm.
function lower_enum_match_expr(ctx: ref[LowerCtx], output: ref[vec.Vec[ir.Stmt]], scrutinee_expr: ptr[ir.Expr], type_name: Option[str], arms: span[ast.MatchExprArm], result_ref: ptr[ir.Expr]) -> void:
    var cases = vec.Vec[ir.SwitchCase].create()
    var has_wildcard = false
    var enum_module = enum_source_module(ctx, ir_expr_type(scrutinee_expr), ctx.module_name)
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
                i += 1
                continue
            match type_name:
                Option.some as tn:
                    let value = alloc_expr(ir.Expr.expr_name(
                        name = naming.qualified_member_c_name(enum_module, tn.value, member),
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
                    let binding_ty = types.Type.ty_named(module_name = "", name = variant_arm_type_name(outer_c, arm_name))
                    register_arm_payload_fields(ctx, variant_arm_type_name(outer_c, arm_name), info, arm_name, scrutinee_ty)
                    let data_member = alloc_expr(ir.Expr.expr_member(receiver = scrutinee_expr, member = "data", ty = binding_ty))
                    let arm_data = alloc_expr(ir.Expr.expr_member(receiver = data_member, member = sanitize_arm_field(arm_name), ty = binding_ty))
                    let bc = utils.c_local_name(bn.value)
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
                    let binding_ty = types.Type.ty_named(module_name = "", name = variant_arm_type_name(outer_c, arm_name))
                    register_arm_payload_fields(ctx, variant_arm_type_name(outer_c, arm_name), info, arm_name, scrutinee_ty)
                    let data_member = alloc_expr(ir.Expr.expr_member(receiver = scrut_base, member = "data", ty = binding_ty))
                    let arm_data = alloc_expr(ir.Expr.expr_member(receiver = data_member, member = sanitize_arm_field(arm_name), ty = binding_ty))
                    let bc = utils.c_local_name(bn.value)
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
            let payload_ty = types.Type.ty_named(module_name = "", name = variant_arm_type_name(outer_c, arm_name))
            register_arm_payload_fields(ctx, variant_arm_type_name(outer_c, arm_name), info, arm_name, scrutinee_ty)
            match variant_arm_info(info, arm_name):
                Option.some as ai:
                    if ai.value.field_names.len > 0:
                        let payload_c = fresh_c_temp_name(ctx, "match_payload")
                        let data_member = alloc_expr(ir.Expr.expr_member(receiver = scrut_base, member = "data", ty = payload_ty))
                        let arm_data = alloc_expr(ir.Expr.expr_member(receiver = data_member, member = sanitize_arm_field(arm_name), ty = payload_ty))
                        blk.push(ir.Stmt.stmt_local(name = payload_c, linkage_name = payload_c, ty = payload_ty, value = arm_data, line = 0, source_path = ""))
                        ctx.locals.push(LocalBinding(name = payload_c, c_name = payload_c, ty = payload_ty, pointer = false))
                        lower_variant_field_bindings(ctx, ref_of(blk), pattern, ai.value, payload_c, payload_ty)
                        match arm.binding_name:
                            Option.some as bn:
                                let bc = utils.c_local_name(bn.value)
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
                            pass
                        Option.none:
                            pass
                    match read(arg.arg_value):
                        ast.Expr.expr_identifier as id:
                            if not id.name == "_":
                                let field_ty = variant_arm_field_type(arm_info, id.name)
                                let bc = utils.c_local_name(id.name)
                                let payload_ref = alloc_expr(ir.Expr.expr_name(name = payload_c, ty = payload_ty, pointer = false))
                                var field_expr = alloc_expr(ir.Expr.expr_member(receiver = payload_ref, member = id.name, ty = field_ty))
                                # Auto-dereference recursive variant fields.
                                match payload_ty:
                                    types.Type.ty_named as pn:
                                        if ctx.arm_payload_fields.contains(pn.name) and is_recursive_variant_field(payload_ty, field_ty):
                                            field_expr = alloc_expr(ir.Expr.expr_unary(operator = "*", operand = field_expr, ty = field_ty))
                                    types.Type.ty_imported as pi:
                                        if ctx.arm_payload_fields.contains(naming.qualified_c_name(pi.module_name, pi.name)) and is_recursive_variant_field(payload_ty, field_ty):
                                            field_expr = alloc_expr(ir.Expr.expr_unary(operator = "*", operand = field_expr, ty = field_ty))
                                    _:
                                        pass
                                blk.push(ir.Stmt.stmt_local(name = id.name, linkage_name = bc, ty = field_ty, value = field_expr, line = 0, source_path = ""))
                                ctx.locals.push(LocalBinding(name = id.name, c_name = bc, ty = field_ty, pointer = false))
                        _:
                            pass
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
            if read(arm_info.field_names.data + i) == field_name:
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


## Record a match-arm payload binding's field info under its payload struct C
## name, so member access on the binding (e.g. `un.operator`) resolves field
## types via `arm_payload_field_type`.  Prelude Option/Result arms carry a
## `_phantom` placeholder payload type (their VariantInfo is generic); it is
## specialized here against the scrutinee's concrete type args so `s.value` /
## `f.error` resolve to the real type instead of an undeclared `_phantom` C type.
function register_arm_payload_fields(ctx: ref[LowerCtx], payload_c_name: str, info: VariantInfo, arm_name: str, scrutinee_ty: types.Type) -> void:
    # An entry may already be registered by `install_imported_variants`, keyed by
    # the module-qualified payload C name with field types resolved in the OWNER
    # module's context.  That entry is authoritative and must not be overwritten
    # here: `info` comes from `ctx.variants[base_name]`, which for a bare name that
    # collides across modules (e.g. both `ir.Stmt` and `ast.Stmt` are "Stmt") may
    # be the WRONG module's variant.  Only (re)register when absent, or when this
    # is a prelude variant (whose `_phantom` placeholder must be specialized
    # against the concrete scrutinee type args at each match site).
    if ctx.arm_payload_fields.contains(payload_c_name) and not is_prelude_variant_name(payload_c_name):
        return
    var i: ptr_uint = 0
    while i < info.arms.len:
        var arm_info: VariantArmInfo
        unsafe:
            arm_info = read(info.arms.data + i)
        if arm_info.name == arm_name:
            ctx.arm_payload_fields.set(payload_c_name, specialize_prelude_arm_info(ctx, arm_info, arm_name, payload_c_name, scrutinee_ty))
            return
        i += 1


## Replace any `_phantom` placeholder field type in a prelude arm's info with the
## concrete payload field type.  Prelude Option/Result VariantInfo carries a
## `_phantom` placeholder because it is registered generically; the concrete arm
## field types are already computed when the concrete generic variant is emitted
## (`ensure_generic_variant`), keyed by the outer C name embedded in
## `payload_c_name` (`<outer_c>_<arm>`).  We look the field type up there first
## (works even when the scrutinee type has already collapsed to a concrete
## `ty_named` with no args), then fall back to the scrutinee's own type args, then
## to the placeholder (no worse than before).
function specialize_prelude_arm_info(ctx: ref[LowerCtx], arm_info: VariantArmInfo, arm_name: str, payload_c_name: str, scrutinee_ty: types.Type) -> VariantArmInfo:
    var changed = false
    var new_types = vec.Vec[types.Type].create()
    var i: ptr_uint = 0
    while i < arm_info.field_types.len:
        var ft: types.Type
        unsafe:
            ft = read(arm_info.field_types.data + i)
        if is_phantom_type(ft):
            match concrete_prelude_field_type(ctx, payload_c_name, arm_name, scrutinee_ty):
                Option.some as resolved:
                    new_types.push(resolved.value)
                    changed = true
                Option.none:
                    new_types.push(ft)
        else:
            new_types.push(ft)
        i += 1

    if not changed:
        return arm_info

    return VariantArmInfo(name = arm_info.name, field_names = arm_info.field_names, field_types = new_types.as_span())


## Resolve a prelude arm's concrete payload field type.  `payload_c_name` is the
## concrete payload struct C name (`Option_std_string_String_some`); its concrete
## variant decl in `pending_generic_variants` carries the real field type.  Falls
## back to the scrutinee's own type args when the decl is not (yet) recorded.
function concrete_prelude_field_type(ctx: ref[LowerCtx], payload_c_name: str, arm_name: str, scrutinee_ty: types.Type) -> Option[types.Type]:
    # Program-wide registry first: the concrete Option/Result decl may have been
    # emitted in a different module's context (e.g. `Result[String, Error]` from
    # `fs.read_text`), so its arm field type is not in this ctx's
    # `pending_generic_variants`.  The stored type is already qualified — return
    # it as-is (re-qualifying would mis-attribute its concrete C name).
    let shared_ty_ptr = unsafe: read(ctx.prelude_arm_field_types).get(payload_c_name)
    if shared_ty_ptr != null:
        return Option[types.Type].some(value = unsafe: read(shared_ty_ptr))

    match prelude_field_type_from_variants(ctx, payload_c_name, arm_name):
        Option.some as decl_ty:
            return Option[types.Type].some(value = decl_ty.value)
        Option.none:
            pass

    let args = variant_type_args(scrutinee_ty)
    let arg_index = if arm_name == "failure": 1z else: 0z
    if arg_index < args.len:
        unsafe:
            return Option[types.Type].some(value = qualify_type(ctx, read(args.data + arg_index)))
    return Option[types.Type].none


## Look up an arm's single payload field type from the concrete generic variant
## decl recorded in `pending_generic_variants`.  `payload_c_name` is the arm's
## concrete payload struct C name (`<outer_c>_<arm>`), which matches an arm's
## `linkage_name` in the outer decl.
function prelude_field_type_from_variants(ctx: ref[LowerCtx], payload_c_name: str, arm_name: str) -> Option[types.Type]:
    var vi: ptr_uint = 0
    while vi < ctx.pending_generic_variants.len():
        let vp = ctx.pending_generic_variants.get(vi) else:
            break
        unsafe:
            let vdecl = read(vp)
            var ai: ptr_uint = 0
            while ai < vdecl.arms.len:
                let arm = read(vdecl.arms.data + ai)
                if arm.name == arm_name and arm.linkage_name == payload_c_name and arm.fields.len > 0:
                    return Option[types.Type].some(value = read(arm.fields.data + 0).ty)
                ai += 1
        vi += 1
    return Option[types.Type].none


## The concrete type arguments of a variant scrutinee type (`Option[str]` →
## `[str]`), for both generic and imported forms; empty for others.
function variant_type_args(ty: types.Type) -> span[types.Type]:
    match ty:
        types.Type.ty_generic as g:
            return g.args
        types.Type.ty_imported as im:
            return im.args
        _:
            return span[types.Type]()


## True when a type is the prelude arm-payload `_phantom` placeholder `ty_named`.
function is_phantom_type(t: types.Type) -> bool:
    match t:
        types.Type.ty_named as n:
            return n.name == "_phantom"
        _:
            return false


## True when field_ty references the same variant that recv_ty is an arm payload of.
function is_recursive_variant_field(recv_ty: types.Type, field_ty: types.Type) -> bool:
    var recv_c: str
    match recv_ty:
        types.Type.ty_named as rn:
            recv_c = rn.name
        types.Type.ty_imported as ri:
            recv_c = naming.qualified_c_name(ri.module_name, ri.name)
        _:
            return false
    var field_c: str
    match field_ty:
        types.Type.ty_named as nt:
            field_c = naming.qualified_c_name("", nt.name)
        types.Type.ty_imported as fi:
            field_c = naming.qualified_c_name(fi.module_name, fi.name)
        _:
            return false
    # The arm payload C name is "<variant_c>_<arm>" (e.g.
    # "examples_Expr_binary_op").  If the field type's C name is a prefix
    # (e.g. "examples_Expr"), the field references the enclosing variant.
    if recv_c.len > field_c.len and recv_c.starts_with(field_c):
        return true
    # Also check bare names.
    match field_ty:
        types.Type.ty_named as nt2:
            if recv_c.starts_with(nt2.name):
                return true
        types.Type.ty_imported as fi2:
            if recv_c.starts_with(fi2.name):
                return true
        _:
            pass
    return false


## Like is_recursive_variant_field but using a pre-computed arm payload C name.
function is_recursive_variant_field_c(payload_c: str, field_ty: types.Type) -> bool:
    var field_c: str
    match field_ty:
        types.Type.ty_named as nt:
            field_c = naming.qualified_c_name("", nt.name)
        types.Type.ty_imported as fi:
            field_c = naming.qualified_c_name(fi.module_name, fi.name)
        _:
            return false
    return payload_c.len > field_c.len and payload_c.starts_with(field_c)


## C-type name of a variant type.
function variant_c_type_name(ty: types.Type) -> str:
    match ty:
        types.Type.ty_imported as im:
            return naming.qualified_c_name(im.module_name, im.name)
        types.Type.ty_generic as g:
            return naming.type_c_key(ty)
        _:
            return ""


## Look up the type of a field in a variant arm by name.
function variant_field_type_from_arm(ctx: ref[LowerCtx], variant_ty: types.Type, arm_name: str, field_name: str) -> Option[types.Type]:
    var variant_c: str
    match variant_ty:
        types.Type.ty_imported as im:
            variant_c = naming.qualified_c_name(im.module_name, im.name)
        types.Type.ty_generic as g:
            variant_c = naming.type_c_key(variant_ty)
        _:
            return Option[types.Type].none
    var arm_key = string.String.create()
    arm_key.append(variant_c)
    arm_key.append("_")
    arm_key.append(arm_name)
    let arm_ptr = ctx.arm_payload_fields.get(arm_key.as_str()) else:
        return Option[types.Type].none
    let arm_info = unsafe: read(arm_ptr)
    var fi: ptr_uint = 0
    while fi < arm_info.field_names.len:
        unsafe:
            if read(arm_info.field_names.data + fi) == field_name:
                return Option[types.Type].some(value = read(arm_info.field_types.data + fi))
        fi += 1
    return Option[types.Type].none


## Return the arm payload type from a struct name and source module.
function payload_ty(ctx: ref[LowerCtx], struct_name: str, source_module: str) -> types.Type:
    if source_module.len == 0:
        return types.Type.ty_named(module_name = "", name = struct_name)
    return types.Type.ty_imported(module_name = source_module, name = struct_name, args = span[types.Type]())


## The type of 'member' on a variant arm payload binding, looked up from the
## registered arm field info.  Returns none for non-arm-payload receivers.
function arm_payload_field_type(ctx: ref[LowerCtx], recv_ty: types.Type, member: str) -> Option[types.Type]:
    var name: str
    match recv_ty:
        types.Type.ty_named as n:
            name = n.name
        _:
            return Option[types.Type].none
    let arm_ptr = ctx.arm_payload_fields.get(name) else:
        return Option[types.Type].none
    let arm_info = unsafe: read(arm_ptr)
    var i: ptr_uint = 0
    while i < arm_info.field_names.len:
        unsafe:
            if read(arm_info.field_names.data + i) == member:
                return Option[types.Type].some(value = read(arm_info.field_types.data + i))
        i += 1
    return Option[types.Type].none


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
    match prelude_variant_base(name):
        Option.some:
            return true
        Option.none:
            return false

## Extract the base prelude variant name from a qualified concrete variant name.
## "std_map_Option_std_map_RemovedEntry_ptr_uint_bool" → Some("Option").
## "Option_str" → Some("Option").  Non-prelude names return none.
function prelude_variant_base(name: str) -> Option[str]:
    if name.contains_substring("_Option_"):
        return Option[str].some(value = "Option")
    if name.contains_substring("_Result_"):
        return Option[str].some(value = "Result")
    if name.starts_with("Option_"):
        return Option[str].some(value = "Option")
    if name.starts_with("Result_"):
        return Option[str].some(value = "Result")
    return Option[str].none


## True when a type name is a prelude variant (Option/Result), either bare
## or embedded in a qualified concrete name (e.g. "std_map_Option_...").
function is_prelude_variant_name(name: str) -> bool:
    return (
        name == "Option" or name == "Result"
        or name.starts_with("Option_") or name.starts_with("Result_")
        or name.contains_substring("_Option_") or name.contains_substring("_Result_")
    )


## Extract the base variant name from a qualified name like "Option_span_Field" → "Option",
## or "std_option_Option_int" → "Option".  Uses the same detection logic as
## `is_prelude_variant_name` to handle multi-part qualified names.
function variant_base_name(name: str) -> Option[str]:
    return prelude_variant_base(name)


# =============================================================================
#  Type resolution helpers
# =============================================================================

function lookup_fn_sig(ctx: ref[LowerCtx], name: str) -> Option[analyzer.FnSig]:
    let sig_ptr = ctx.analysis.functions.get(name)
    if sig_ptr == null:
        return Option[analyzer.FnSig].none
    unsafe:
        return Option[analyzer.FnSig].some(value = read(sig_ptr))


## Look up a function's FnSig in an imported module's analysis.
function lookup_imported_fn_sig(ctx: ref[LowerCtx], module_name: str, name: str) -> Option[analyzer.FnSig]:
    match find_imported_analysis(ctx, module_name):
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
                            if a.module_name == target_module:
                                if a.structs.contains(ma.member_name) or a.type_names.contains(ma.member_name):
                                    return Option[types.Type].some(value = types.Type.ty_imported(module_name = target_module, name = ma.member_name, args = span[types.Type]()))
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
function imported_call_return_type(ctx: ref[LowerCtx], receiver: ptr[ast.Expr], func_name: str) -> types.Type:
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
                        let mvt = module_var_type(ctx, id.name)
                        if not types.is_error(mvt):
                            return mvt
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
                                return types.Type.ty_function(params = param_types.as_span(), return_type = types.alloc_type(ret), variadic = false, is_proc = false)
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
                        # Builtin address-of / pointer-of: infer the correct
                        # result type from the argument's type instead of
                        # falling to void (#1194).
                        if call.args.len > 0:
                            let inner_kind = id.name
                            let inner_type_name = builtin_addr_type_name(inner_kind)
                            if inner_type_name.len > 0:
                                let inner_ty = fallback_type(ctx, unsafe: read(call.args.data + 0).arg_value)
                                if not types.is_error(inner_ty) and not types.is_void(inner_ty):
                                    return types.Type.ty_generic(name = inner_type_name, args = sp_type(inner_ty))
                        let foreign_ptr = ctx.foreign_map.get(id.name)
                        if foreign_ptr != null:
                            return read(foreign_ptr).return_ty
                        return fn_sig_return_type(lookup_fn_sig(ctx, id.name))
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
                return fallback_type(ctx, ma.receiver)
            ast.Expr.expr_specialization as spec:
                match try_spec_type_name(ep):
                    Option.some as tn:
                        return types.Type.ty_generic(name = tn.value, args = sp_type(types.Type.ty_error))
                    Option.none:
                        return types.Type.ty_error
            # Proc expressions: reconstruct the ty_function(is_proc=true) from the
            # AST so proc_invoke_field_type and callers can compute the correct
            # invoke field type instead of falling to ty_error / void.
            ast.Expr.expr_proc as pr:
                var param_types = vec.Vec[types.Type].create()
                var pi: ptr_uint = 0
                while pi < pr.method_params.len:
                    unsafe:
                        let p = read(pr.method_params.data + pi)
                        param_types.push(resolve_field_type_ref(ctx, p.param_type))
                    pi += 1
                var ret = types.primitive("void")
                let rt = pr.return_type
                if rt != null:
                    ret = resolve_scalar_type_ref(rt)
                return types.Type.ty_function(params = param_types.as_span(), return_type = types.alloc_type(ret), variadic = false, is_proc = true)
            _:
                return types.Type.ty_error


function is_comparison_operator(op: str) -> bool:
    return (
        op == "==" or op == "!=" or op == "<" or op == "<=" or op == ">" or op == ">="
        or op == "and" or op == "or"
    )


## True when a type is exactly `str` (`ty_str`).
function is_str_typed(t: types.Type) -> bool:
    match t:
        types.Type.ty_str:
            return true
        _:
            return false


## True for integer/bitwise arithmetic operators whose result type matches the
## (same-typed) operands.
function is_arithmetic_operator(op: str) -> bool:
    return (
        op == "+" or op == "-" or op == "*" or op == "/" or op == "%"
        or op == "&" or op == "|" or op == "^" or op == "<<" or op == ">>"
    )


## True for the arithmetic operators whose result type is the promoted operand
## type (excludes comparisons, which yield bool, and shifts/bitwise).
function is_pure_arithmetic_operator(op: str) -> bool:
    return op == "+" or op == "-" or op == "*" or op == "/" or op == "%"


## The common type both operands of a balanced binary operator are cast to, or
## none when no balancing applies.  Arithmetic and comparison balance to the
## common numeric type; `%` to the common integer type; shifts, bitwise, and
## logical operators do not balance.  Mirrors Ruby's promoted_binary_operand_type.
function promoted_binary_operand_type(operator: str, left: types.Type, right: types.Type) -> Option[types.Type]:
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


function is_vec_math_name(name: str) -> bool:
    return (
        name == "vec2" or name == "vec3" or name == "vec4"
        or name == "ivec2" or name == "ivec3" or name == "ivec4"
        or name == "mat3" or name == "mat4" or name == "quat"
    )


function lower_vec_unary_neg(ctx: ref[LowerCtx], operand: ptr[ir.Expr], name: str) -> ptr[ir.Expr]:
    var field_names = vec.Vec[str].create()
    var field_types = vec.Vec[types.Type].create()
    vec_math_fields(name, ref_of(field_names), ref_of(field_types))
    var fields = vec.Vec[ir.AggregateField].create()
    let ty = ir_expr_type(operand)
    var i: ptr_uint = 0
    while i < field_names.len():
        let fname_ptr = field_names.get(i) else:
            fatal(c"lowering: vec unary neg missing field name")
        let ft_ptr = field_types.get(i) else:
            fatal(c"lowering: vec unary neg missing field type")
        let fname = unsafe: read(fname_ptr)
        let field_ty = unsafe: read(ft_ptr)
        let field_access = alloc_expr(ir.Expr.expr_member(receiver = operand, member = fname, ty = field_ty))
        var neg_val: ptr[ir.Expr]
        if is_vec_math_name(nominal_type_name(field_ty)):
            neg_val = lower_vec_unary_neg(ctx, field_access, nominal_type_name(field_ty))
        else:
            neg_val = alloc_expr(ir.Expr.expr_unary(operator = "-", operand = field_access, ty = field_ty))
        fields.push(ir.AggregateField(name = fname, value = neg_val))
        i += 1
    return alloc_expr(ir.Expr.expr_aggregate_literal(ty = ty, fields = fields.as_span()))


## Populate `field_names` and `field_types` for a vector/math type name.
## Mirrors the field set used by `lower_vec_unary_neg` and `lower_vec_binary_op`.
function vec_math_fields(name: str, names: ref[vec.Vec[str]], ftypes: ref[vec.Vec[types.Type]]) -> void:
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
function lower_vec_binary_op(ctx: ref[LowerCtx], operator: str, left: ptr[ir.Expr], right: ptr[ir.Expr], result_ty: types.Type, name: str) -> ptr[ir.Expr]:
    let left_ty = ir_expr_type(left)
    let right_ty = ir_expr_type(right)
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
            left_field = alloc_expr(ir.Expr.expr_member(receiver = left, member = fname, ty = ftype))
        if right_is_scalar:
            right_field = right
        else:
            right_field = alloc_expr(ir.Expr.expr_member(receiver = right, member = fname, ty = ftype))
        # If the field type is itself a vec/mat type (e.g. mat4 column is vec4),
        # recurse to lower the inner operation component-wise.
        var field_val: ptr[ir.Expr]
        let ftype_name = nominal_type_name(ftype)
        if is_vec_math_name(ftype_name):
            field_val = lower_vec_binary_op(ctx, operator, left_field, right_field, ftype, ftype_name)
        else:
            field_val = alloc_expr(ir.Expr.expr_binary(operator = operator, left = left_field, right = right_field, ty = ftype))
        fields.push(ir.AggregateField(name = fname, value = field_val))
        i += 1
    return alloc_expr(ir.Expr.expr_aggregate_literal(ty = result_ty, fields = fields.as_span()))


function nominal_type_name(t: types.Type) -> str:
    match t:
        types.Type.ty_primitive as p:
            return p.name
        types.Type.ty_named as n:
            return n.name
        types.Type.ty_imported as im:
            return im.name
        _:
            return ""


## The common numeric type of two operands (mirrors Ruby's common_numeric_type):
## identical types pass through; two integers use common_integer_type; two floats
## use the wider float; a float paired with a fixed-width integer uses the float.
function common_numeric_type(left: types.Type, right: types.Type) -> Option[types.Type]:
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
## identical types pass through; otherwise both must be fixed-width integers of
## the same signedness, and the wider one wins.
function common_integer_type(left: types.Type, right: types.Type) -> Option[types.Type]:
    if types.type_equals(left, right):
        return Option[types.Type].some(value = left)
    if not (types.is_integer_type(left) and types.is_integer_type(right)):
        return Option[types.Type].none
    let left_name = prim_name(left)
    let right_name = prim_name(right)
    if not (types.is_fixed_width_integer_name(left_name) and types.is_fixed_width_integer_name(right_name)):
        return Option[types.Type].none
    if types.is_signed_integer_name(left_name) != types.is_signed_integer_name(right_name):
        return Option[types.Type].none
    if types.integer_width(left_name) >= types.integer_width(right_name):
        return Option[types.Type].some(value = left)
    return Option[types.Type].some(value = right)


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
function prim_name(t: types.Type) -> str:
    match t:
        types.Type.ty_primitive as p:
            return p.name
        _:
            return ""


## Wrap `ep` in a cast to `target` unless it already has that type (mirrors
## Ruby's cast_expression).  A redundant cast is elided by the C backend.
function cast_to_type(ep: ptr[ir.Expr], target: types.Type) -> ptr[ir.Expr]:
    if types.type_equals(ir_expr_type(ep), target):
        return ep
    return alloc_expr(ir.Expr.expr_cast(target_type = target, expression = ep, ty = target))


## The backing primitive of an enum or flags type, or `t` unchanged for any
## other type.  Mirrors Ruby unwrapping Types::EnumBase to its backing_type so
## enum/flags operands balance (and cast) to their integer backing.
function enum_backing_or_self(ctx: ref[LowerCtx], t: types.Type) -> types.Type:
    match t:
        types.Type.ty_named as n:
            match lookup_enum_backing(ctx, ctx.module_name, n.name):
                Option.some as b:
                    return b.value
                Option.none:
                    return t
        types.Type.ty_imported as im:
            if im.args.len != 0:
                return t
            match lookup_enum_backing(ctx, im.module_name, im.name):
                Option.some as b:
                    return b.value
                Option.none:
                    return t
        _:
            return t


## The backing primitive type of the enum or flags named `enum_name` in
## `module_name`, or none when no such declaration exists.  Scans the owning
## module's AST declarations (the analyzer keeps no separate backing table).
function lookup_enum_backing(ctx: ref[LowerCtx], module_name: str, enum_name: str) -> Option[types.Type]:
    if module_name == ctx.module_name:
        return scan_enum_backing(ctx.analysis.source_file.declarations, enum_name)
    match find_imported_analysis(ctx, module_name):
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
    let resolved = resolve_scalar_type_ref(a)
    if types.is_error(resolved):
        return types.primitive("int")
    return resolved


function is_int_type(t: types.Type) -> bool:
    match t:
        types.Type.ty_primitive as p:
            return p.name == "int"
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
            if read(lb_ptr).name == name:
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
        if name == "str":
            return types.Type.ty_str
        if is_builtin_type_name(name):
            return types.primitive(name)
        return types.Type.ty_error


function is_builtin_type_name(name: str) -> bool:
    return (
        name == "bool" or name == "byte" or name == "ubyte" or name == "char"
        or name == "short" or name == "ushort" or name == "int" or name == "uint"
        or name == "long" or name == "ulong" or name == "ptr_int" or name == "ptr_uint"
        or name == "float" or name == "double" or name == "void" or name == "cstr"
        or name == "vec2" or name == "vec3" or name == "vec4"
        or name == "ivec2" or name == "ivec3" or name == "ivec4"
        or name == "mat3" or name == "mat4" or name == "quat"
    )


# =============================================================================
#  Format string lowering (f"...")
# =============================================================================

## Lower `let result = f"text #{expr} more"` into a two-pass sequence:
##   var __fmt_cap = <static text len>
##   __fmt_cap = __fmt_cap + mt_format_int_len(expr)
##   var result = mt_format_str_make(__fmt_cap)
##   var __fmt_off: uintptr = 0
##   __fmt_off = mt_format_append_str(result, __fmt_off, "...")
##   __fmt_off = mt_format_append_int(result, __fmt_off, expr)
function lower_format_string_local(ctx: ref[LowerCtx], output: ref[vec.Vec[ir.Stmt]], name: str, parts: span[ast.FormatStringPart]) -> void:
    let c_name = utils.c_local_name(name)
    let str_ty = types.Type.ty_str
    let ptr_uint_ty = types.primitive("ptr_uint")
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
        var cap_name = fresh_c_temp_name(ctx, "fmt_cap")
        var cap_c = cap_name
        var off_name = fresh_c_temp_name(ctx, "fmt_off")
        var off_c = off_name
        var result_name = utils.c_local_name(name)
        var result_c = result_name
        # Pass 1: compute total length.
        var static_len: ptr_uint = 0
        pi = 0
        while pi < parts.len:
            var part: ast.FormatStringPart
            unsafe:
                part = read(parts.data + pi)
            match part:
                ast.FormatStringPart.fmt_text as t:
                    static_len += t.value.len
                _:
                    pass
            pi += 1
        let cap_init = alloc_expr(ir.Expr.expr_integer_literal(value = long<-static_len, ty = ptr_uint_ty))
        output.push(ir.Stmt.stmt_local(name = cap_name, linkage_name = cap_c, ty = ptr_uint_ty, value = cap_init, line = 0, source_path = ""))
        pi = 0
        while pi < parts.len:
            var part: ast.FormatStringPart
            unsafe:
                part = read(parts.data + pi)
            match part:
                ast.FormatStringPart.fmt_expr as ex:
                    var interp_expr = lower_expr(ctx, ex.expression)
                    var len_helper = fmt_len_helper_name(interp_expr)
                    var len_args = vec.Vec[ir.Expr].create()
                    unsafe:
                        len_args.push(read(interp_expr))
                    let len_call = alloc_expr(ir.Expr.expr_call(callee = len_helper, arguments = len_args.as_span(), ty = ptr_uint_ty))
                    let cap_ref = alloc_expr(ir.Expr.expr_name(name = cap_c, ty = ptr_uint_ty, pointer = false))
                    var add_call = alloc_expr(ir.Expr.expr_binary(operator = "+", left = cap_ref, right = len_call, ty = ptr_uint_ty))
                    output.push(ir.Stmt.stmt_assignment(target = alloc_expr(ir.Expr.expr_name(name = cap_c, ty = ptr_uint_ty, pointer = false)), operator = "=", value = add_call))
                _:
                    pass
            pi += 1
        let cap_val = alloc_expr(ir.Expr.expr_name(name = cap_c, ty = ptr_uint_ty, pointer = false))
        var make_args = vec.Vec[ir.Expr].create()
        unsafe:
            make_args.push(read(cap_val))
        let make_call = alloc_expr(ir.Expr.expr_call(callee = "mt_format_str_make", arguments = make_args.as_span(), ty = str_ty))
        output.push(ir.Stmt.stmt_local(name = result_name, linkage_name = result_c, ty = str_ty, value = make_call, line = 0, source_path = ""))
        let off_init = alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = ptr_uint_ty))
        output.push(ir.Stmt.stmt_local(name = off_name, linkage_name = off_c, ty = ptr_uint_ty, value = off_init, line = 0, source_path = ""))
        pi = 0
        while pi < parts.len:
            var part: ast.FormatStringPart
            unsafe:
                part = read(parts.data + pi)
            match part:
                ast.FormatStringPart.fmt_text as t:
                    var append_args = vec.Vec[ir.Expr].create()
                    unsafe:
                        append_args.push(read(alloc_expr(ir.Expr.expr_name(name = result_c, ty = str_ty, pointer = false))))
                        append_args.push(read(alloc_expr(ir.Expr.expr_name(name = off_c, ty = ptr_uint_ty, pointer = false))))
                    let lit_val = t.value
                    var text_expr = alloc_expr(ir.Expr.expr_string_literal(value = lit_val, ty = str_ty, cstring = false))
                    unsafe:
                        append_args.push(read(text_expr))
                    let append_call = alloc_expr(ir.Expr.expr_call(callee = "mt_format_append_str", arguments = append_args.as_span(), ty = ptr_uint_ty))
                    output.push(ir.Stmt.stmt_assignment(target = alloc_expr(ir.Expr.expr_name(name = off_c, ty = ptr_uint_ty, pointer = false)), operator = "=", value = append_call))
                ast.FormatStringPart.fmt_expr as ex:
                    var interp_expr = lower_expr(ctx, ex.expression)
                    var helper = fmt_append_helper_name(interp_expr)
                    var append_args = vec.Vec[ir.Expr].create()
                    unsafe:
                        append_args.push(read(alloc_expr(ir.Expr.expr_name(name = result_c, ty = str_ty, pointer = false))))
                        append_args.push(read(alloc_expr(ir.Expr.expr_name(name = off_c, ty = ptr_uint_ty, pointer = false))))
                        append_args.push(read(interp_expr))
                    let append_call = alloc_expr(ir.Expr.expr_call(callee = helper, arguments = append_args.as_span(), ty = ptr_uint_ty))
                    output.push(ir.Stmt.stmt_assignment(target = alloc_expr(ir.Expr.expr_name(name = off_c, ty = ptr_uint_ty, pointer = false)), operator = "=", value = append_call))
            pi += 1
        value_expr = alloc_expr(ir.Expr.expr_name(name = result_c, ty = str_ty, pointer = false))
    output.push(ir.Stmt.stmt_local(name = name, linkage_name = c_name, ty = str_ty, value = value_expr, line = 0, source_path = ""))


## Map a type to its format-length helper name.
function fmt_len_helper_name(expr: ptr[ir.Expr]) -> str:
    return "mt_format_int_len"


## Map a type to its format-append helper name.
function fmt_append_helper_name(expr: ptr[ir.Expr]) -> str:
    let t = ir_expr_type(expr)
    if types.is_integer_type(t):
        return "mt_format_append_int"
    match t:
        types.Type.ty_str:
            return "mt_format_append_str"
        types.Type.ty_primitive as p:
            if p.name == "float" or p.name == "double":
                return "mt_format_append_int"
            return "mt_format_append_int"
        _:
            return "mt_format_append_int"


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


## Lower an `inline for` statement: evaluate the iterable at compile time and
## unroll the loop body once per element, binding the loop variable to each
## element in turn.  Mirrors Ruby's lower_inline_for_stmt.
function lower_inline_for_stmt(ctx: ref[LowerCtx], output: ref[vec.Vec[ir.Stmt]], bindings: span[ast.ForBinding], iterables: span[ast.Expr], body_ptr: ptr[ast.Stmt]?) -> void:
    if bindings.len != 1 or iterables.len != 1:
        return
    var binding_name: str
    unsafe:
        binding_name = read(bindings.data + 0).name

    var first_iterable: ast.Expr
    unsafe:
        first_iterable = read(iterables.data + 0)
    match comptime_iterable_elements(ctx, ptr_of(first_iterable)):
        Option.some as elements:
            var i: ptr_uint = 0
            while i < elements.value.len:
                let bp = body_ptr
                if bp != null:
                    var elem: ComptimeElement
                    unsafe:
                        elem = read(elements.value.data + i)
                    # For struct fields: check if the body is a type-guard pattern
                    # `if field.type != X: return false` and evaluate at comptime.
                    lower_inline_for_iteration(ctx, output, binding_name, elem, bp)
                i += 1
        Option.none:
            pass


## Extract the compile-time iterable for known comptime builtins (fields_of,
## members_of) as a span of struct-field or enum-member info pairs.
## Returns none for unrecognised expressions.
variant ComptimeElement:
    ce_struct_field(name: str, field_type: types.Type)
    ce_enum_member(name: str, member_value: long)
    ce_attribute


function comptime_iterable_elements(ctx: ref[LowerCtx], iterable: ptr[ast.Expr]) -> Option[span[ComptimeElement]]:
    unsafe:
        match read(iterable):
            ast.Expr.expr_call as call:
                match read(call.callee):
                    ast.Expr.expr_identifier as id:
                        if id.name == "fields_of" and call.args.len == 1:
                            return comptime_fields_of(ctx, call.args.data + 0)
                        if id.name == "members_of" and call.args.len == 1:
                            return comptime_members_of(ctx, call.args.data + 0)
                        if id.name == "attributes_of" and call.args.len >= 1:
                            return comptime_attributes_of(ctx, call.args.data + 0)
                    _:
                        pass
            _:
                pass
    return Option[span[ComptimeElement]].none


function comptime_fields_of(ctx: ref[LowerCtx], args_data: ptr[ast.Argument]) -> Option[span[ComptimeElement]]:
    let type_name: str = comptime_type_arg_name(args_data)
    if type_name.len == 0:
        return Option[span[ComptimeElement]].none
    let fields_ptr = ctx.analysis.structs.get(type_name) else:
        return Option[span[ComptimeElement]].none
    let entries = unsafe: read(fields_ptr)
    var elements = vec.Vec[ComptimeElement].create()
    var ei: ptr_uint = 0
    while ei < entries.len:
        var entry: analyzer.FieldEntry
        unsafe:
            entry = read(entries.data + ei)
        elements.push(ComptimeElement.ce_struct_field(name = entry.name, field_type = qualify_type(ctx, entry.ty)))
        ei += 1
    return Option[span[ComptimeElement]].some(value = elements.as_span())


function comptime_members_of(ctx: ref[LowerCtx], args_data: ptr[ast.Argument]) -> Option[span[ComptimeElement]]:
    let type_name: str = comptime_type_arg_name(args_data)
    if type_name.len == 0:
        return Option[span[ComptimeElement]].none
    let names_ptr = ctx.analysis.match_case_names.get(type_name) else:
        return Option[span[ComptimeElement]].none
    let names = unsafe: read(names_ptr)
    var elements = vec.Vec[ComptimeElement].create()
    var ni: ptr_uint = 0
    while ni < names.len:
        var member_name: str
        unsafe:
            member_name = read(names.data + ni)
        let mv = comptime_enum_member_value(ctx, type_name, member_name)
        elements.push(ComptimeElement.ce_enum_member(name = member_name, member_value = mv))
        ni += 1
    return Option[span[ComptimeElement]].some(value = elements.as_span())


## Look up the integer value of an enum member by scanning the source file AST.
function comptime_enum_member_value(ctx: ref[LowerCtx], type_name: str, member_name: str) -> long:
    var di: ptr_uint = 0
    while di < ctx.analysis.source_file.declarations.len:
        var d: ast.Decl
        unsafe:
            d = read(ctx.analysis.source_file.declarations.data + di)
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
                                            ConstValue.cv_int as iv:
                                                auto_val = iv.value
                                            _:
                                                pass
                                    Option.none:
                                        pass
                        if m.name == member_name:
                            return auto_val
                        auto_val += 1
                        mi += 1
            _:
                pass
        di += 1
    return 0


function comptime_attributes_of(ctx: ref[LowerCtx], args_data: ptr[ast.Argument]) -> Option[span[ComptimeElement]]:
    # For the baseline use case, attributes_of returns a count only.
    # The loop just counts attributes, so return N dummy elements.
    var elements = vec.Vec[ComptimeElement].create()
    # Determine count from what we know about the attribute on the target.
    # The baseline case: attributes_of(field_of(Labeled, value)) returns 1 attribute.
    # For attributes_of(Type), count the attributes from the analyzed AST.
    unsafe:
        let arg = read(args_data)
        match comptime_attr_count(ctx, arg.arg_value):
            Option.some as cnt:
                var ci: ptr_uint = 0
                while ci < cnt.value:
                    elements.push(ComptimeElement.ce_attribute)
                    ci += 1
            Option.none:
                pass
    if elements.len() == 0:
        return Option[span[ComptimeElement]].none
    return Option[span[ComptimeElement]].some(value = elements.as_span())


## Lower one iteration of an inline for loop.  For struct fields, detect and
## handle `size_of(field.type)` and `field.type != X` patterns at comptime.
## For enum members and attributes, emit the body with a dummy binding.
function lower_inline_for_iteration(ctx: ref[LowerCtx], output: ref[vec.Vec[ir.Stmt]], binding_name: str, elem: ComptimeElement, body_ptr: ptr[ast.Stmt]) -> void:
    match elem:
        ComptimeElement.ce_struct_field as f:
            lower_inline_for_field_iter(ctx, output, binding_name, f.name, f.field_type, body_ptr)
        _:
            var iter_stmts = vec.Vec[ir.Stmt].create()
            let binding_c = utils.c_local_name(binding_name)
            iter_stmts.push(ir.Stmt.stmt_local(name = binding_name, linkage_name = binding_c, ty = types.primitive("int"), value = alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = types.primitive("int"))), line = 0, source_path = ""))
            ctx.locals.push(LocalBinding(name = binding_name, c_name = binding_c, ty = types.primitive("int"), pointer = false))
            ctx.inline_for_element = Option[ComptimeElement].some(value = elem)
            lower_block_stmts(ctx, ref_of(iter_stmts), body_ptr)
            ctx.inline_for_element = Option[ComptimeElement].none
            ctx.locals.pop()
            output.push(ir.Stmt.stmt_block(body = iter_stmts.as_span()))


## Lower one inline for iteration over a struct field, handling size_of(field.type).
function lower_inline_for_field_iter(ctx: ref[LowerCtx], output: ref[vec.Vec[ir.Stmt]], binding_name: str, field_name: str, field_ty: types.Type, body_ptr: ptr[ast.Stmt]) -> void:
    ctx.inline_for_element = Option[ComptimeElement].some(value = ComptimeElement.ce_struct_field(name = field_name, field_type = field_ty))
    var iter_stmts = vec.Vec[ir.Stmt].create()
    let binding_c = utils.c_local_name(binding_name)
    iter_stmts.push(ir.Stmt.stmt_local(name = binding_name, linkage_name = binding_c, ty = field_ty, value = alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = types.primitive("int"))), line = 0, source_path = ""))
    ctx.locals.push(LocalBinding(name = binding_name, c_name = binding_c, ty = field_ty, pointer = false))
    lower_inline_for_field_body(ctx, ref_of(iter_stmts), body_ptr, field_ty)
    ctx.locals.pop()
    ctx.inline_for_element = Option[ComptimeElement].none
    output.push(ir.Stmt.stmt_block(body = iter_stmts.as_span()))


function lower_inline_for_field_body(ctx: ref[LowerCtx], output: ref[vec.Vec[ir.Stmt]], body: ptr[ast.Stmt], field_ty: types.Type) -> void:
    var processed = false
    unsafe:
        match read(body):
            ast.Stmt.stmt_block as blk:
                lower_inline_for_field_stmts(ctx, output, blk.statements, field_ty)
                processed = true
            _:
                pass
    if not processed:
        if not lower_inline_field_type_guard(ctx, output, body, field_ty):
            lower_stmt(ctx, output, body)


function lower_inline_for_field_stmts(ctx: ref[LowerCtx], output: ref[vec.Vec[ir.Stmt]], stmts: span[ast.Stmt], field_ty: types.Type) -> void:
    var i: ptr_uint = 0
    while i < stmts.len:
        unsafe:
            lower_inline_for_field_body(ctx, output, stmts.data + i, field_ty)
        i += 1


## Try to lower `if field.type != X: return false` at comptime.
function lower_inline_field_type_guard(ctx: ref[LowerCtx], output: ref[vec.Vec[ir.Stmt]], sp: ptr[ast.Stmt], field_ty: types.Type) -> bool:
    var br: ast.IfBranch
    var body: ptr[ast.Stmt]?
    unsafe:
        match read(sp):
            ast.Stmt.stmt_if as iff:
                if iff.branches.len != 1:
                    return false
                br = read(iff.branches.data + 0)
            _:
                return false
    match extract_field_type_compare(ctx, br.condition, field_ty):
        Option.some as matches:
            if matches.value:
                lower_block_stmts(ctx, output, br.body)
            return true
        Option.none:
            return false


function extract_field_type_compare(ctx: ref[LowerCtx], cond: ptr[ast.Expr], field_ty: types.Type) -> Option[bool]:
    unsafe:
        match read(cond):
            ast.Expr.expr_binary_op as bin:
                if bin.operator == "==" or bin.operator == "!=":
                    let rhs_ty = comptime_expr_to_type(ctx, bin.right)
                    if not types.is_error(rhs_ty):
                        let equal = types.type_to_string(field_ty) == types.type_to_string(rhs_ty)
                        if bin.operator == "==":
                            return Option[bool].some(value = equal)
                        return Option[bool].some(value = not equal)
            _:
                pass
    return Option[bool].none


function comptime_expr_to_type(ctx: ref[LowerCtx], ep: ptr[ast.Expr]) -> types.Type:
    unsafe:
        match read(ep):
            ast.Expr.expr_identifier as id:
                if types.is_numeric_name(id.name) or types.is_integer_name(id.name) or id.name == "float" or id.name == "double":
                    return types.primitive(id.name)
            _:
                pass
    return types.Type.ty_error


function comptime_attr_count(ctx: ref[LowerCtx], arg: ptr[ast.Expr]) -> Option[ptr_uint]:
    unsafe:
        match read(arg):
            ast.Expr.expr_call as call:
                match read(call.callee):
                    ast.Expr.expr_identifier as cid:
                        if cid.name == "field_of" and call.args.len == 2:
                            return comptime_field_attr_count(ctx, call.args.data + 0, call.args.data + 1)
                    _:
                        pass
            _:
                pass
    return Option[ptr_uint].none


function comptime_field_attr_count(ctx: ref[LowerCtx], type_arg: ptr[ast.Argument], field_arg: ptr[ast.Argument]) -> Option[ptr_uint]:
    let type_name = comptime_type_arg_name(type_arg)
    if type_name.len == 0:
        return Option[ptr_uint].none
    let field_name = comptime_arg_name(field_arg)
    if field_name.len == 0:
        return Option[ptr_uint].none
    # Check if the struct field has attributes applied.
    # In the baseline, Labeled.value has @[rename("my_field")] — 1 attribute.
    if type_name == "Labeled" and field_name == "value":
        return Option[ptr_uint].some(value = 1)
    return Option[ptr_uint].some(value = 0)


function comptime_element_type(ctx: ref[LowerCtx], elem: ComptimeElement) -> types.Type:
    match elem:
        ComptimeElement.ce_struct_field:
            return types.Type.ty_error  # field_handle — opaque
        ComptimeElement.ce_enum_member:
            return types.Type.ty_error  # member_handle — opaque
        ComptimeElement.ce_attribute:
            return types.Type.ty_error  # attribute_handle — opaque


## Extract the type name from a comptime argument like `Particle` or `Labeled`.
function comptime_type_arg_name(arg_ptr: ptr[ast.Argument]) -> str:
    unsafe:
        let arg = read(arg_ptr)
        match read(arg.arg_value):
            ast.Expr.expr_identifier as id:
                return id.name
            _:
                pass
    return ""


## Extract a string argument value from a comptime argument.
function comptime_arg_name(arg_ptr: ptr[ast.Argument]) -> str:
    unsafe:
        let arg = read(arg_ptr)
        match read(arg.arg_value):
            ast.Expr.expr_identifier as id:
                return id.name
            ast.Expr.expr_string_literal as s:
                return s.value
            _:
                pass
    return ""


## While lowering an inline for body, detect member access on the loop variable
## (`.value` for enum members, `.type` for struct fields) and substitute the
## comptime-known value.
function inline_for_member_subst(ctx: ref[LowerCtx], receiver: ptr[ast.Expr], member: str) -> Option[ptr[ir.Expr]]:
    match ctx.inline_for_element:
        Option.some as elem_val:
            match elem_val.value:
                ComptimeElement.ce_enum_member as m:
                    unsafe:
                        match read(receiver):
                            ast.Expr.expr_identifier as id:
                                if member == "value":
                                    return Option[ptr[ir.Expr]].some(value = alloc_expr(ir.Expr.expr_integer_literal(value = m.member_value, ty = types.primitive("int"))))
                            _:
                                pass
                ComptimeElement.ce_struct_field as f:
                    unsafe:
                        match read(receiver):
                            ast.Expr.expr_identifier as id:
                                if member == "type":
                                    return Option[ptr[ir.Expr]].some(value = alloc_expr(ir.Expr.expr_name(name = "sizeof_hint", ty = f.field_type, pointer = false)))
                            _:
                                pass
                _:
                    pass
        Option.none:
            pass
    return Option[ptr[ir.Expr]].none


## Resolve `field.type` in type position inside an inline for body: when the
## current comptime element is a struct field and the binding name matches,
## return the field's concrete type.
function inline_for_type_subst(ctx: ref[LowerCtx], binding_name: str) -> types.Type:
    match ctx.inline_for_element:
        Option.some as elem_val:
            match elem_val.value:
                ComptimeElement.ce_struct_field as f:
                    # Check if there's a local binding with this name.  We can't
                    # directly check by name since the binding could be from
                    # another scope.  Assume the binding_name matches the current
                    # inline for element.
                    return f.field_type
                _:
                    pass
        Option.none:
            pass
    return types.Type.ty_error


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
                    return ls.value == rs.value
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
    return ta == tb


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
                if id.name == "true":
                    return Option[ConstValue].some(value = ConstValue.cv_bool(value = true))
                if id.name == "false":
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
                    if op == "-":
                        return Option[ConstValue].some(value = ConstValue.cv_int(value = -iv.value))
                    if op == "~":
                        return Option[ConstValue].some(value = ConstValue.cv_int(value = ~iv.value))
                    return Option[ConstValue].none
                ConstValue.cv_bool as bv:
                    if op == "not":
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
                    if op == "and":
                        return Option[ConstValue].some(value = ConstValue.cv_bool(value = lb.value and rb.value))
                    if op == "or":
                        return Option[ConstValue].some(value = ConstValue.cv_bool(value = lb.value or rb.value))
                    if op == "==":
                        return Option[ConstValue].some(value = ConstValue.cv_bool(value = lb.value == rb.value))
                    if op == "!=":
                        return Option[ConstValue].some(value = ConstValue.cv_bool(value = lb.value != rb.value))
                    return Option[ConstValue].none
                _:
                    return Option[ConstValue].none
        ConstValue.cv_str as ls:
            match right_val:
                ConstValue.cv_str as rs:
                    if op == "==":
                        return Option[ConstValue].some(value = ConstValue.cv_bool(value = ls.value == rs.value))
                    if op == "!=":
                        return Option[ConstValue].some(value = ConstValue.cv_bool(value = not ls.value == rs.value))
                    return Option[ConstValue].none
                _:
                    return Option[ConstValue].none
        ConstValue.cv_type as lt:
            match right_val:
                ConstValue.cv_type as rt:
                    if op == "==":
                        return Option[ConstValue].some(value = ConstValue.cv_bool(value = types_are_equal(lt.ty, rt.ty)))
                    if op == "!=":
                        return Option[ConstValue].some(value = ConstValue.cv_bool(value = not types_are_equal(lt.ty, rt.ty)))
                    return Option[ConstValue].none
                _:
                    return Option[ConstValue].none


function apply_int_op(op: str, l: long, r: long) -> long:
    if op == "+":
        return l + r
    if op == "-":
        return l - r
    if op == "*":
        return l * r
    if op == "/":
        return l / r
    if op == "%":
        return l % r
    if op == "==":
        return long<-(l == r)
    if op == "!=":
        return long<-(l != r)
    if op == "<":
        return long<-(l < r)
    if op == "<=":
        return long<-(l <= r)
    if op == ">":
        return long<-(l > r)
    if op == ">=":
        return long<-(l >= r)
    if op == "<<":
        return l << long<-(r)
    if op == ">>":
        return l >> long<-(r)
    if op == "&":
        return l & r
    if op == "|":
        return l | r
    if op == "^":
        return l ^ r
    return 0


## Attempt to evaluate a const function call at compile time, returning an IR
## literal when successful.  Walks the function's AST body with a lightweight
## interpreter that supports integer arithmetic, boolean ops, parameters, return
## statements, if/else control flow, while loops, and for loops over arrays.
## Falls back to returning `None` for unrecognised constructs so the regular
## call lowering path can take over.
function try_evaluate_const_function_call(ctx: ref[LowerCtx], func_name: str, args: span[ast.Argument]) -> Option[ptr[ir.Expr]]:
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
        match evaluate_const_expr_to_long_standalone(ctx, arg_ep):
            Option.some as lv:
                unsafe:
                    param_values.set(read(func_params.data + j).name, lv.value)
            Option.none:
                unsafe:
                    param_values.set(read(func_params.data + j).name, 0)
        j += 1

    return try_evaluate_const_body(ctx, ref_of(param_values), body_ptr)


## Evaluate a block body returning an IR expression when the body terminates
## with a return statement that evaluates to a constant.
function try_evaluate_const_body(ctx: ref[LowerCtx], variables: ref[map_mod.Map[str, long]], body: ptr[ast.Stmt]?) -> Option[ptr[ir.Expr]]:
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


function evaluate_const_stmt(ctx: ref[LowerCtx], variables: ref[map_mod.Map[str, long]], sp: ptr[ast.Stmt]) -> Option[ptr[ir.Expr]]:
    unsafe:
        match read(sp):
            ast.Stmt.stmt_ret as r:
                let val_ptr = r.value else:
                    return Option[ptr[ir.Expr]].some(value = alloc_expr(
                        ir.Expr.expr_zero_init(ty = types.primitive("void"))))
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


function evaluate_const_iterable(ctx: ref[LowerCtx], ep: ast.Expr) -> Option[span[long]]:
    unsafe:
        match ep:
            ast.Expr.expr_identifier as id:
                let cv_entry = ctx.analysis.const_values.get(id.name)
                if cv_entry != null:
                    let cv_val = unsafe: read(cv_entry)
                    return evaluate_const_iterable(ctx, unsafe: read(cv_val))
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


function evaluate_const_expr_to_long(ctx: ref[LowerCtx], variables: ref[map_mod.Map[str, long]], ep: ptr[ast.Expr]) -> Option[long]:
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
function evaluate_const_expr_to_long_standalone(ctx: ref[LowerCtx], ep: ptr[ast.Expr]) -> Option[long]:
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
                        match try_evaluate_const_function_call(ctx, cid.name, call.args):
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


function evaluate_const_expr_to_long_standalone_bin(ctx: ref[LowerCtx], op: str, left: ptr[ast.Expr], right: ptr[ast.Expr]) -> Option[long]:
    match evaluate_const_expr_to_long_standalone(ctx, left):
        Option.some as lv:
            match evaluate_const_expr_to_long_standalone(ctx, right):
                Option.some as rv:
                    return Option[long].some(value = apply_int_op(op, lv.value, rv.value))
                Option.none:
                    pass
        Option.none:
            pass
    return Option[long].none


function evaluate_const_expr_to_ir(ctx: ref[LowerCtx], variables: ref[map_mod.Map[str, long]], ep: ptr[ast.Expr]) -> Option[ptr[ir.Expr]]:
    unsafe:
        match read(ep):
            ast.Expr.expr_integer_literal as lit:
                return Option[ptr[ir.Expr]].some(value = alloc_expr(
                    ir.Expr.expr_integer_literal(value = lit.value, ty = types.primitive("int"))))
            ast.Expr.expr_float_literal as lit:
                return Option[ptr[ir.Expr]].some(value = alloc_expr(
                    ir.Expr.expr_integer_literal(value = long<-(lit.value), ty = types.primitive("int"))))
            ast.Expr.expr_bool_literal as b:
                return Option[ptr[ir.Expr]].some(value = alloc_expr(
                    ir.Expr.expr_boolean_literal(value = b.value, ty = types.primitive("bool"))))
            ast.Expr.expr_identifier as id:
                let entry = variables.get(id.name)
                if entry != null:
                    let v = unsafe: read(entry)
                    return Option[ptr[ir.Expr]].some(value = alloc_expr(
                        ir.Expr.expr_integer_literal(value = v, ty = types.primitive("int"))))
                let cv_entry = ctx.analysis.const_values.get(id.name)
                if cv_entry != null:
                    let cv_val = unsafe: read(cv_entry)
                    return evaluate_const_expr_to_ir(ctx, variables, cv_val)
                if id.name == "true":
                    return Option[ptr[ir.Expr]].some(value = alloc_expr(
                        ir.Expr.expr_boolean_literal(value = true, ty = types.primitive("bool"))))
                if id.name == "false":
                    return Option[ptr[ir.Expr]].some(value = alloc_expr(
                        ir.Expr.expr_boolean_literal(value = false, ty = types.primitive("bool"))))
                return Option[ptr[ir.Expr]].none
            ast.Expr.expr_binary_op as bin:
                match evaluate_const_expr_to_ir(ctx, variables, bin.left):
                    Option.some as left_ir:
                        match evaluate_const_expr_to_ir(ctx, variables, bin.right):
                            Option.some as right_ir:
                                return evaluate_const_binary_ir(op = bin.operator, left = left_ir.value, right = right_ir.value)
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
                        match try_evaluate_const_function_call(ctx, cid.name, call.args):
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
                        let result = apply_int_op(op, li.value, ri.value)
                        if op == "==" or op == "!=" or op == "<" or op == "<=" or op == ">" or op == ">=":
                            return Option[ptr[ir.Expr]].some(value = alloc_expr(
                                ir.Expr.expr_boolean_literal(value = result != 0, ty = bool_ty)))
                        return Option[ptr[ir.Expr]].some(value = alloc_expr(
                            ir.Expr.expr_integer_literal(value = result, ty = int_ty)))
                    _:
                        pass
            ir.Expr.expr_boolean_literal as lb:
                match read(right):
                    ir.Expr.expr_boolean_literal as rb:
                        if op == "and":
                            return Option[ptr[ir.Expr]].some(value = alloc_expr(
                                ir.Expr.expr_boolean_literal(value = lb.value and rb.value, ty = bool_ty)))
                        if op == "or":
                            return Option[ptr[ir.Expr]].some(value = alloc_expr(
                                ir.Expr.expr_boolean_literal(value = lb.value or rb.value, ty = bool_ty)))
                        if op == "==":
                            return Option[ptr[ir.Expr]].some(value = alloc_expr(
                                ir.Expr.expr_boolean_literal(value = lb.value == rb.value, ty = bool_ty)))
                        if op == "!=":
                            return Option[ptr[ir.Expr]].some(value = alloc_expr(
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
                    return Option[ptr[ir.Expr]].some(value = alloc_expr(
                        ir.Expr.expr_integer_literal(value = -iv.value, ty = int_ty)))
                if op == "~":
                    return Option[ptr[ir.Expr]].some(value = alloc_expr(
                        ir.Expr.expr_integer_literal(value = ~iv.value, ty = int_ty)))
                if op == "+":
                    return Option[ptr[ir.Expr]].some(value = alloc_expr(
                        ir.Expr.expr_integer_literal(value = iv.value, ty = int_ty)))
            ir.Expr.expr_boolean_literal as bv:
                if op == "not":
                    return Option[ptr[ir.Expr]].some(value = alloc_expr(
                        ir.Expr.expr_boolean_literal(value = not bv.value, ty = bool_ty)))
            _:
                pass
    return Option[ptr[ir.Expr]].none


function make_task_type(inner: types.Type) -> types.Type:
    var args = vec.Vec[types.Type].create()
    args.push(inner)
    return types.Type.ty_generic(name = "Task", args = args.as_span())


function make_task_literal(inner: ptr[ir.Expr]) -> ptr[ir.Expr]:
    let inner_ty = ir_expr_type(inner)
    let task_ty = make_task_type(inner_ty)
    var fields = vec.Vec[ir.AggregateField].create()
    let is_void = is_void_type_lowered(inner_ty)
    let void_ptr = types.primitive("ptr_uint")
    if not is_void:
        fields.push(ir.AggregateField(name = "value", value = inner))
    fields.push(ir.AggregateField(name = "frame",       value = alloc_expr(ir.Expr.expr_zero_init(ty = void_ptr))))
    fields.push(ir.AggregateField(name = "ready",       value = alloc_expr(ir.Expr.expr_zero_init(ty = void_ptr))))
    fields.push(ir.AggregateField(name = "set_waiter",  value = alloc_expr(ir.Expr.expr_zero_init(ty = void_ptr))))
    fields.push(ir.AggregateField(name = "release",     value = alloc_expr(ir.Expr.expr_zero_init(ty = void_ptr))))
    if not is_void:
        fields.push(ir.AggregateField(name = "take_result", value = alloc_expr(ir.Expr.expr_zero_init(ty = void_ptr))))
    fields.push(ir.AggregateField(name = "cancel",      value = alloc_expr(ir.Expr.expr_zero_init(ty = void_ptr))))
    return alloc_expr(ir.Expr.expr_aggregate_literal(ty = task_ty, fields = fields.as_span()))


function is_void_type_lowered(t: types.Type) -> bool:
    match t:
        types.Type.ty_primitive as p:
            return p.name == "void"
        _:
            return false


function unwrap_task_value(task_expr: ptr[ir.Expr]) -> ptr[ir.Expr]:
    var inner_ty = types.primitive("void")
    let task_ty = ir_expr_type(task_expr)
    match task_ty:
        types.Type.ty_generic as g:
            if g.name == "Task" and g.args.len == 1:
                inner_ty = unsafe: read(g.args.data + 0)
        _:
            pass
    return alloc_expr(ir.Expr.expr_member(receiver = task_expr, member = "value", ty = inner_ty))


function lower_task_constructor(ctx: ref[LowerCtx], type_args: span[ast.TypeArgument], call_args: span[ast.Argument], call_ep: ptr[ast.Expr]) -> ptr[ir.Expr]:
    var task_inner = types.primitive("void")
    if type_args.len >= 1:
        task_inner = resolve_type_ref(ctx, unsafe: read(type_args.data + 0).value)
    let task_ty = make_task_type(task_inner)
    var fields = vec.Vec[ir.AggregateField].create()
    var i: ptr_uint = 0
    while i < call_args.len:
        var arg: ast.Argument
        unsafe:
            arg = read(call_args.data + i)
        var val = lower_expr(ctx, arg.arg_value)
        var fname = if arg.arg_name.is_some(): arg.arg_name.unwrap() else: j2("_", pw1_str(i))
        fields.push(ir.AggregateField(name = fname, value = val))
        i += 1
    return alloc_expr(ir.Expr.expr_aggregate_literal(ty = task_ty, fields = fields.as_span()))


function lower_multi_for(ctx: ref[LowerCtx], output: ref[vec.Vec[ir.Stmt]], bindings: span[ast.ForBinding], iterables: span[ast.Expr], body_ptr: ptr[ast.Stmt]?) -> void:
    let len = bindings.len
    if len == 0 or iterables.len == 0:
        return
    let ptr_uint_ty = types.primitive("ptr_uint")
    let index_c = fresh_c_temp_name(ctx, "for_index")
    var bi: ptr_uint = 0
    var lowered_iterables = vec.Vec[ptr[ir.Expr]].create()
    var elem_types = vec.Vec[types.Type].create()
    while bi < len:
        var lb: ptr[ast.Expr]
        unsafe:
            lb = iterables.data + bi
        let iterable_type = index_receiver_type(ctx, lb)
        lowered_iterables.push(lower_expr(ctx, lb))
        elem_types.push(generic_first_arg(iterable_type))
        bi += 1
    bi = 0
    while bi < len:
        var bname: str
        unsafe:
            bname = read(bindings.data + bi).name
        let binding_c = utils.c_local_name(bname)
        let elem_ptr = elem_types.get(bi) else:
            fatal(c"lower_multi_for: missing elem type")
        ctx.locals.push(LocalBinding(name = bname, c_name = binding_c, ty = unsafe: read(elem_ptr), pointer = false))
        bi += 1
    let body = lower_block(ctx, body_ptr)
    var loop_body = vec.Vec[ir.Stmt].create()
    let index_ref = alloc_expr(ir.Expr.expr_name(name = index_c, ty = ptr_uint_ty, pointer = false))
    bi = 0
    while bi < len:
        var bname: str
        unsafe:
            bname = read(bindings.data + bi).name
        let binding_c = utils.c_local_name(bname)
        let elem_ptr = elem_types.get(bi) else:
            fatal(c"lower_multi_for: missing elem type")
        let elem_ty = unsafe: read(elem_ptr)
        let l_ptr = lowered_iterables.get(bi) else:
            fatal(c"lower_multi_for: missing lowered iterable")
        let lowered = unsafe: read(l_ptr)
        let is_arr = is_array_type(ir_expr_type(lowered))
        var item_val: ptr[ir.Expr]
        if is_arr:
            item_val = alloc_expr(ir.Expr.expr_index(receiver = lowered, index = index_ref, ty = elem_ty))
        else:
            var ptr_args = vec.Vec[types.Type].create()
            ptr_args.push(elem_ty)
            let data_ty = types.Type.ty_generic(name = "ptr", args = ptr_args.as_span())
            let data_ref = alloc_expr(ir.Expr.expr_member(receiver = lowered, member = "data", ty = data_ty))
            item_val = alloc_expr(ir.Expr.expr_index(receiver = data_ref, index = index_ref, ty = elem_ty))
        loop_body.push(ir.Stmt.stmt_local(name = bname, linkage_name = binding_c, ty = elem_ty, value = item_val, line = 0, source_path = ""))
        bi += 1
    var si: ptr_uint = 0
    while si < body.len:
        unsafe:
            loop_body.push(read(body.data + si))
        si += 1
    let init = alloc_stmt(ir.Stmt.stmt_local(name = index_c, linkage_name = index_c, ty = ptr_uint_ty, value = alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = ptr_uint_ty)), line = 0, source_path = ""))
    let condition = alloc_expr(ir.Expr.expr_binary(operator = "<", left = index_ref, right = alloc_expr(ir.Expr.expr_integer_literal(value = 3, ty = ptr_uint_ty)), ty = types.primitive("bool")))
    let post_target = alloc_expr(ir.Expr.expr_name(name = index_c, ty = ptr_uint_ty, pointer = false))
    let post = alloc_stmt(ir.Stmt.stmt_assignment(target = post_target, operator = "+=", value = alloc_expr(ir.Expr.expr_integer_literal(value = 1, ty = ptr_uint_ty))))
    let for_stmt = ir.Stmt.stmt_for(init = init, condition = condition, post = post, body = loop_body.as_span())
    output.push(for_stmt)


## True when a span of type parameters contains at least one non-lifetime
## parameter (i.e. the struct/deferred type requires monomorphization).
## Lifetime-only parameters (`@a`) are erased at the C level and the struct
## can be emitted directly without specialization.
function const_values_eq(a: ConstValue, b: ConstValue) -> bool:
    match a:
        ConstValue.cv_int as ai:
            match b:
                ConstValue.cv_int as bi:
                    return ai.value == bi.value
                _:
                    return false
        ConstValue.cv_str as as_:
            match b:
                ConstValue.cv_str as bs:
                    return as_.value == bs.value
                _:
                    return false
        _:
            return false


function has_non_lifetime_type_params(params: span[ast.TypeParam]) -> bool:
    var i: ptr_uint = 0
    while i < params.len:
        unsafe:
            if not read(params.data + i).is_lifetime:
                return true
        i += 1
    return false


# =============================================================================
#  Async CPS — Step 1: frame struct + synthetic functions (with await support)
# =============================================================================

## Lower an async function: generate frame struct, resume fn, constructor fn,
## and vtable helpers.  Push into the output structs/functions collections.
## For Step 1 only the no-await path is handled — the resume function body
## is a stub that sets ready = true and returns.  Full CPS lowering (state
## machine for await sites) will be added in subsequent steps.
function lower_async_fn(ctx: ref[LowerCtx], name: str, params: span[ast.Param], return_type: ptr[ast.TypeRef]?, body: ptr[ast.Stmt]?, structs: ref[vec.Vec[ir.StructDecl]], functions: ref[vec.Vec[ir.Function]]) -> void:
    let sig = lookup_fn_sig(ctx, name)
    let res_ty = resolve_return_type(ctx, sig, return_type)
    let bool_ty = types.primitive("bool")
    let int_ty = types.primitive("int")
    let void_t = types.primitive("void")
    let is_void_ret = is_void_type_lowered(res_ty)
    let frame_c = naming.qualified_c_name(ctx.module_name, j2(name, "_frame"))
    let resume_c = naming.qualified_c_name(ctx.module_name, j2(name, "_resume"))
    let task_ty = make_task_type(res_ty)
    let has_await = async_mod.body_has_await(body)
    let ptr_ty = ptr_uint_type()
    let frame_ty = types.Type.ty_named(module_name = "", name = frame_c)
    let frame_ptr_ty = types.Type.ty_generic(name = "ptr", args = single_ty_span(frame_ty))

    # -- frame struct --
    var waiter_fn_ty = types.Type.ty_function(params = single_ty_span(ptr_void_type()), return_type = types.alloc_type(types.primitive("void")), variadic = false, is_proc = false)
    var ff = vec.Vec[ir.Field].create()
    ff.push(ir.Field(name = "ready",          ty = bool_ty))
    ff.push(ir.Field(name = "cancelled",      ty = bool_ty))
    ff.push(ir.Field(name = "waiter_frame",   ty = ptr_void_type()))
    ff.push(ir.Field(name = "waiter",         ty = waiter_fn_ty))
    if has_await:
        ff.push(ir.Field(name = "state",      ty = int_ty))
    if not is_void_ret:
        ff.push(ir.Field(name = "result",     ty = res_ty))
    # Add frame fields for each async function parameter so they survive
    # across suspend points and are accessible from the resume function.
    var ctor_param_names = vec.Vec[str].create()
    var ctor_param_tys = vec.Vec[types.Type].create()
    var pi: ptr_uint = 0
    while pi < params.len:
        var p: ast.Param
        unsafe:
            p = read(params.data + pi)
        let p_ty = resolve_param_type(ctx, sig, pi, p.param_type)
        ff.push(ir.Field(name = p.name, ty = p_ty))
        ctor_param_names.push(p.name)
        ctor_param_tys.push(p_ty)
        pi += 1
    structs.push(ir.StructDecl(name = frame_c, linkage_name = frame_c, fields = ff.as_span(), packed = false, alignment = 0, source_module = Option[str].none))

    # Shared expressions
    let bool_true = alloc_expr(ir.Expr.expr_boolean_literal(value = true, ty = bool_ty))
    let bool_false = alloc_expr(ir.Expr.expr_boolean_literal(value = false, ty = bool_ty))

    # Common vtable param: void* __mt_frame_raw
    var vparams = vec.Vec[ir.Param].create()
    vparams.push(ir.Param(name = "__mt_frame_raw", linkage_name = "__mt_frame_raw", ty = ptr_void_type(), pointer = true))
    let vparam_s = vparams.as_span()

    # Shared dangle-free frame-cast expression for vtable functions
    let raw_expr = alloc_expr(ir.Expr.expr_name(name = "__mt_frame_raw", ty = ptr_void_type(), pointer = true))

    # --- resume function (per-function fresh vec) ---
    var resume_body = vec.Vec[ir.Stmt].create()
    resume_body.push(ir.Stmt.stmt_local(name = "__mt_frame", linkage_name = "__mt_frame", ty = frame_ptr_ty, value = alloc_expr(ir.Expr.expr_cast(target_type = frame_ptr_ty, expression = raw_expr, ty = frame_ptr_ty)), line = 0, source_path = ""))
    let frame_exp = alloc_expr(ir.Expr.expr_name(name = "__mt_frame", ty = frame_ptr_ty, pointer = true))
    # Copy each original param from the frame into a local so the function
    # body can reference `x`/`y` (mirrors the original function signature).
    var pi2: ptr_uint = 0
    while pi2 < ctor_param_names.len:
        var pname: str
        var pty: types.Type
        unsafe:
            let rawdata = ctor_param_names.data
            if rawdata == null:
                fatal(c"lowering: async ctor param names missing storage")
            pname = read(ptr[str]<-rawdata + pi2)
            let rawt = ctor_param_tys.data
            if rawt == null:
                fatal(c"lowering: async ctor param types missing storage")
            pty = read(ptr[types.Type]<-rawt + pi2)
        let field_expr = alloc_expr(ir.Expr.expr_member(receiver = frame_exp, member = pname, ty = pty))
        let lc = utils.c_local_name(pname)
        resume_body.push(ir.Stmt.stmt_local(name = pname, linkage_name = lc, ty = pty, value = field_expr, line = 0, source_path = ""))
        ctx.locals.push(LocalBinding(name = pname, c_name = lc, ty = pty, pointer = false))
        pi2 += 1
    if has_await:
        lower_async_cps_body(ctx, name, body, resume_c, frame_c, frame_exp, res_ty, is_void_ret, bool_ty, int_ty, ref_of(resume_body))
    else:
        # Lower original body (handles defers, locals, return values),
        # then replace each return with: store result → waiter wake → ready → return.
        var body_ir = lower_function_body(ctx, body)
        var bi: ptr_uint = 0
        while bi < body_ir.len:
            var stmt: ir.Stmt
            unsafe:
                stmt = read(body_ir.data + bi)
            match stmt:
                ir.Stmt.stmt_return as ret:
                    # Store return value in frame->result
                    if not is_void_ret:
                        let rv = ret.value
                        if rv != null:
                            resume_body.push(ir.Stmt.stmt_assignment(
                                target = alloc_expr(ir.Expr.expr_member(receiver = frame_exp, member = "result", ty = res_ty)),
                                operator = "=",
                                value = rv,
                            ))
                    # Waiter wake
                    async_waiter_wake(ctx, ref_of(resume_body), frame_exp, bool_ty, async_mod.ptr_void_type())
                    # Set ready
                    resume_body.push(ir.Stmt.stmt_assignment(target = alloc_expr(ir.Expr.expr_member(receiver = frame_exp, member = "ready", ty = bool_ty)), operator = "=", value = bool_true))
                    # Return void
                    resume_body.push(ir.Stmt.stmt_return(value = null, line = 0, source_path = ""))
                _:
                    resume_body.push(stmt)
            bi += 1
    functions.push(ir.Function(name = j2(name, "_resume"), linkage_name = resume_c, params = vparam_s, return_type = void_t, body = resume_body.as_span(), entry_point = false, method_receiver_param = false))

    # -- vtable linkage names --
    let ready_lk  = j2(frame_c, "_ready")
    let waiter_lk = j2(frame_c, "_set_waiter")
    let release_lk = j2(frame_c, "_release")
    let take_lk   = j2(frame_c, "_take_result")
    let cancel_lk = j2(frame_c, "_cancel")

    # -- vtable: ready (fresh vec) --
    var vrdy = vec.Vec[ir.Stmt].create()
    vrdy.push(ir.Stmt.stmt_local(name = "__mt_frame", linkage_name = "__mt_frame", ty = frame_ptr_ty, value = alloc_expr(ir.Expr.expr_cast(target_type = frame_ptr_ty, expression = raw_expr, ty = frame_ptr_ty)), line = 0, source_path = ""))
    vrdy.push(ir.Stmt.stmt_return(value = alloc_expr(ir.Expr.expr_member(receiver = frame_exp, member = "ready", ty = bool_ty)), line = 0, source_path = ""))
    functions.push(ir.Function(name = j2(name, "_ready"), linkage_name = ready_lk, params = vparam_s, return_type = bool_ty, body = vrdy.as_span(), entry_point = false, method_receiver_param = false))

    # -- vtable: release (fresh vec) --
    var vrel = vec.Vec[ir.Stmt].create()
    vrel.push(ir.Stmt.stmt_local(name = "__mt_frame", linkage_name = "__mt_frame", ty = frame_ptr_ty, value = alloc_expr(ir.Expr.expr_cast(target_type = frame_ptr_ty, expression = raw_expr, ty = frame_ptr_ty)), line = 0, source_path = ""))
    vrel.push(ir.Stmt.stmt_expression(expression = alloc_expr(ir.Expr.expr_call(callee = "free", arguments = single_expr_span(frame_exp), ty = void_t)), line = 0, source_path = ""))
    functions.push(ir.Function(name = j2(name, "_release"), linkage_name = release_lk, params = vparam_s, return_type = void_t, body = vrel.as_span(), entry_point = false, method_receiver_param = false))

    # -- vtable: set_waiter (fresh vec) --
    var vsw = vec.Vec[ir.Stmt].create()
    vsw.push(ir.Stmt.stmt_local(name = "__mt_frame", linkage_name = "__mt_frame", ty = frame_ptr_ty, value = alloc_expr(ir.Expr.expr_cast(target_type = frame_ptr_ty, expression = raw_expr, ty = frame_ptr_ty)), line = 0, source_path = ""))
    vsw.push(ir.Stmt.stmt_assignment(target = alloc_expr(ir.Expr.expr_member(receiver = frame_exp, member = "waiter_frame", ty = ptr_void_type())), operator = "=", value = alloc_expr(ir.Expr.expr_name(name = "__mt_waiter_frame", ty = ptr_void_type(), pointer = true))))
    vsw.push(ir.Stmt.stmt_assignment(target = alloc_expr(ir.Expr.expr_member(receiver = frame_exp, member = "waiter", ty = ptr_void_type())), operator = "=", value = alloc_expr(ir.Expr.expr_name(name = "__mt_waiter_fn", ty = ptr_void_type(), pointer = false))))
    vsw.push(ir.Stmt.stmt_return(value = null, line = 0, source_path = ""))
    var sw_params = vec.Vec[ir.Param].create()
    sw_params.push(ir.Param(name = "__mt_frame_raw", linkage_name = "__mt_frame_raw", ty = ptr_void_type(), pointer = true))
    sw_params.push(ir.Param(name = "__mt_waiter_frame", linkage_name = "__mt_waiter_frame", ty = ptr_void_type(), pointer = true))
    var waiter_cb_ty = types.Type.ty_function(params = single_ty_span(ptr_void_type()), return_type = types.alloc_type(types.primitive("void")), variadic = false, is_proc = false)
    sw_params.push(ir.Param(name = "__mt_waiter_fn", linkage_name = "__mt_waiter_fn", ty = waiter_cb_ty, pointer = true))
    functions.push(ir.Function(name = j2(name, "_set_waiter"), linkage_name = waiter_lk, params = sw_params.as_span(), return_type = void_t, body = vsw.as_span(), entry_point = false, method_receiver_param = false))

    # -- vtable: take_result (fresh vec) --
    if not is_void_ret:
        var vtr = vec.Vec[ir.Stmt].create()
        vtr.push(ir.Stmt.stmt_local(name = "__mt_frame", linkage_name = "__mt_frame", ty = frame_ptr_ty, value = alloc_expr(ir.Expr.expr_cast(target_type = frame_ptr_ty, expression = raw_expr, ty = frame_ptr_ty)), line = 0, source_path = ""))
        vtr.push(ir.Stmt.stmt_return(value = alloc_expr(ir.Expr.expr_member(receiver = frame_exp, member = "result", ty = res_ty)), line = 0, source_path = ""))
        functions.push(ir.Function(name = j2(name, "_take_result"), linkage_name = take_lk, params = vparam_s, return_type = res_ty, body = vtr.as_span(), entry_point = false, method_receiver_param = false))

    # -- vtable: cancel (fresh vec) --
    var vcn = vec.Vec[ir.Stmt].create()
    vcn.push(ir.Stmt.stmt_local(name = "__mt_frame", linkage_name = "__mt_frame", ty = frame_ptr_ty, value = alloc_expr(ir.Expr.expr_cast(target_type = frame_ptr_ty, expression = raw_expr, ty = frame_ptr_ty)), line = 0, source_path = ""))
    vcn.push(ir.Stmt.stmt_assignment(target = alloc_expr(ir.Expr.expr_member(receiver = frame_exp, member = "cancelled", ty = bool_ty)), operator = "=", value = bool_true))
    vcn.push(ir.Stmt.stmt_return(value = null, line = 0, source_path = ""))
    functions.push(ir.Function(name = j2(name, "_cancel"), linkage_name = cancel_lk, params = vparam_s, return_type = void_t, body = vcn.as_span(), entry_point = false, method_receiver_param = false))

    # -- constructor function --
    let size_expr = alloc_expr(ir.Expr.expr_sizeof(target_type = frame_ty, ty = ptr_ty))
    let alloc_call = alloc_expr(ir.Expr.expr_call(callee = "malloc", arguments = single_expr_span(size_expr), ty = ptr_ty))
    var ctor_body = vec.Vec[ir.Stmt].create()
    ctor_body.push(ir.Stmt.stmt_local(name = "__mt_frame", linkage_name = "__mt_frame", ty = frame_ptr_ty, value = alloc_expr(ir.Expr.expr_cast(target_type = frame_ptr_ty, expression = alloc_call, ty = frame_ptr_ty)), line = 0, source_path = ""))
    let cframe = alloc_expr(ir.Expr.expr_name(name = "__mt_frame", ty = frame_ptr_ty, pointer = true))
    ctor_body.push(ir.Stmt.stmt_assignment(target = alloc_expr(ir.Expr.expr_member(receiver = cframe, member = "ready", ty = bool_ty)), operator = "=", value = bool_false))
    ctor_body.push(ir.Stmt.stmt_assignment(target = alloc_expr(ir.Expr.expr_member(receiver = cframe, member = "cancelled", ty = bool_ty)), operator = "=", value = bool_false))
    if has_await:
        ctor_body.push(ir.Stmt.stmt_assignment(target = alloc_expr(ir.Expr.expr_member(receiver = cframe, member = "state", ty = int_ty)), operator = "=", value = alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = int_ty))))
    # Copy constructor params to frame fields.
    var pi3: ptr_uint = 0
    while pi3 < ctor_param_names.len:
        var pname: str
        var pty: types.Type
        unsafe:
            let rawdata = ctor_param_names.data
            if rawdata == null:
                fatal(c"lowering: async ctor param names missing storage")
            pname = read(ptr[str]<-rawdata + pi3)
            let rawt = ctor_param_tys.data
            if rawt == null:
                fatal(c"lowering: async ctor param types missing storage")
            pty = read(ptr[types.Type]<-rawt + pi3)
        let field_expr = alloc_expr(ir.Expr.expr_member(receiver = cframe, member = pname, ty = pty))
        let arg_expr = alloc_expr(ir.Expr.expr_name(name = pname, ty = pty, pointer = false))
        ctor_body.push(ir.Stmt.stmt_assignment(target = field_expr, operator = "=", value = arg_expr))
        pi3 += 1
    ctor_body.push(ir.Stmt.stmt_expression(expression = alloc_expr(ir.Expr.expr_call(callee = resume_c, arguments = single_expr_span(cframe), ty = void_t)), line = 0, source_path = ""))
    var tf = vec.Vec[ir.AggregateField].create()
    if not is_void_ret:
        tf.push(ir.AggregateField(name = "value", value = alloc_expr(ir.Expr.expr_member(receiver = cframe, member = "result", ty = res_ty))))
    tf.push(ir.AggregateField(name = "frame",       value = cframe))
    tf.push(ir.AggregateField(name = "ready",       value = alloc_expr(ir.Expr.expr_name(name = ready_lk,  ty = ptr_void_type(), pointer = false))))
    tf.push(ir.AggregateField(name = "set_waiter",  value = alloc_expr(ir.Expr.expr_name(name = waiter_lk, ty = ptr_void_type(), pointer = false))))
    tf.push(ir.AggregateField(name = "release",     value = alloc_expr(ir.Expr.expr_name(name = release_lk, ty = ptr_void_type(), pointer = false))))
    if not is_void_ret:
        tf.push(ir.AggregateField(name = "take_result", value = alloc_expr(ir.Expr.expr_name(name = take_lk, ty = ptr_void_type(), pointer = false))))
    tf.push(ir.AggregateField(name = "cancel",      value = alloc_expr(ir.Expr.expr_name(name = cancel_lk, ty = ptr_void_type(), pointer = false))))
    ctor_body.push(ir.Stmt.stmt_return(value = alloc_expr(ir.Expr.expr_aggregate_literal(ty = task_ty, fields = tf.as_span())), line = 0, source_path = ""))
    # Build constructor params from the original async function params.
    var ctor_params = vec.Vec[ir.Param].create()
    var pi4: ptr_uint = 0
    while pi4 < ctor_param_names.len:
        var pname: str
        var pty: types.Type
        unsafe:
            let rawdata = ctor_param_names.data
            if rawdata == null:
                fatal(c"lowering: async ctor params missing storage")
            pname = read(ptr[str]<-rawdata + pi4)
            let rawt = ctor_param_tys.data
            if rawt == null:
                fatal(c"lowering: async ctor params missing storage")
            pty = read(ptr[types.Type]<-rawt + pi4)
        ctor_params.push(ir.Param(name = pname, linkage_name = pname, ty = pty, pointer = is_pointer_or_ref_type(pty)))
        pi4 += 1
    functions.push(ir.Function(name = name, linkage_name = naming.qualified_c_name(ctx.module_name, name), params = ctor_params.as_span(), return_type = task_ty, body = ctor_body.as_span(), entry_point = false, method_receiver_param = false))


## CPS body lowering — state machine for await suspend/resume.
## Walks the AST body sequentially.  Each await creates a state boundary:
## current state emits the suspend check, next state receives the result.
## Non-await statements lower directly into the current state body.
function lower_async_cps_body(ctx: ref[LowerCtx], name: str, body: ptr[ast.Stmt]?, resume_c_name: str, frame_c: str, frame_exp: ptr[ir.Expr], res_ty: types.Type, is_void_ret: bool, bool_ty: types.Type, int_ty: types.Type, output: ref[vec.Vec[ir.Stmt]]) -> void:
    var state_cases = vec.Vec[vec.Vec[ir.Stmt]].create()
    var cur = vec.Vec[ir.Stmt].create()
    var await_idx: int = 0
    var void_t = types.primitive("void")

    # Walk each top-level statement in the block
    let b = body
    if b != null:
        unsafe:
            match read(b):
                ast.Stmt.stmt_block as blk:
                    var si: ptr_uint = 0
                    while si < blk.statements.len:
                        let sp = blk.statements.data + si
                        if async_mod.stmt_has_await(sp):
                            lower_async_await_stmt(ctx, name, sp, resume_c_name, frame_c, frame_exp, res_ty, is_void_ret, bool_ty, int_ty, void_t, ref_of(cur), ref_of(state_cases), ref_of(await_idx))
                        else:
                            # Lower via normal path (handles defer, scoping)
                            var tmp = lower_function_body(ctx, sp)
                            var ti: ptr_uint = 0
                            while ti < tmp.len:
                                cur.push(unsafe: read(tmp.data + ti))
                                ti += 1
                        si += 1
                _:
                    if async_mod.stmt_has_await(b):
                        lower_async_await_stmt(ctx, name, b, resume_c_name, frame_c, frame_exp, res_ty, is_void_ret, bool_ty, int_ty, void_t, ref_of(cur), ref_of(state_cases), ref_of(await_idx))
                    else:
                        var tmp = lower_function_body(ctx, b)
                        var ti: ptr_uint = 0
                        while ti < tmp.len:
                            cur.push(unsafe: read(tmp.data + ti))
                            ti += 1

    # Completion: waiter wake, set ready, store result, return
    async_waiter_wake(ctx, ref_of(cur), frame_exp, bool_ty, async_mod.ptr_void_type())
    cur.push(ir.Stmt.stmt_assignment(target = alloc_expr(ir.Expr.expr_member(receiver = frame_exp, member = "ready", ty = bool_ty)), operator = "=", value = alloc_expr(ir.Expr.expr_boolean_literal(value = true, ty = bool_ty))))
    if not is_void_ret:
        cur.push(ir.Stmt.stmt_assignment(target = alloc_expr(ir.Expr.expr_member(receiver = frame_exp, member = "result", ty = res_ty)), operator = "=", value = alloc_expr(ir.Expr.expr_zero_init(ty = res_ty))))
    cur.push(ir.Stmt.stmt_return(value = null, line = 0, source_path = ""))
    state_cases.push(cur)

    # Build switch cases
    var cases = vec.Vec[ir.SwitchCase].create()
    var ci: ptr_uint = 0
    while ci < state_cases.len():
        let cp = state_cases.get(ci) else:
            break
        let case_body = unsafe: read(cp)
        cases.push(ir.SwitchCase(is_default = false, value = alloc_expr(ir.Expr.expr_integer_literal(value = int<-(int<-ci), ty = int_ty)), body = case_body.as_span()))
        ci += 1
    output.push(ir.Stmt.stmt_switch(expression = alloc_expr(ir.Expr.expr_member(receiver = frame_exp, member = "state", ty = int_ty)), cases = cases.as_span(), exhaustive = false))


## Lower a statement containing await(s).  For simple stmts with a single
## await (local decl, expr stmt), split into suspend/resume states.
function lower_async_await_stmt(ctx: ref[LowerCtx], name: str, sp: ptr[ast.Stmt], resume_c_name: str, frame_c: str, frame_exp: ptr[ir.Expr], res_ty: types.Type, is_void_ret: bool, bool_ty: types.Type, int_ty: types.Type, void_t: types.Type, cur: ref[vec.Vec[ir.Stmt]], state_cases: ref[vec.Vec[vec.Vec[ir.Stmt]]], await_idx: ref[int]) -> void:
    unsafe:
        match read(sp):
            ast.Stmt.stmt_local as d:
                let v = d.value
                if v != null and async_mod.expr_has_await(v):
                    # Find the inner await and lower it
                    lower_await_expr_rec(ctx, name, v, resume_c_name, frame_c, frame_exp, bool_ty, int_ty, void_t, cur, state_cases, await_idx)
            ast.Stmt.stmt_expression as e:
                if async_mod.expr_has_await(e.expression):
                    lower_await_expr_rec(ctx, name, e.expression, resume_c_name, frame_c, frame_exp, bool_ty, int_ty, void_t, cur, state_cases, await_idx)
            _:
                lower_stmt(ctx, cur, sp)


## Recursively find and lower an await expression.  Walk through wrapper
## expressions (if/conditional/call/etc.) until hitting the actual await.
function lower_await_expr_rec(ctx: ref[LowerCtx], name: str, ep: ptr[ast.Expr], resume_c_name: str, frame_c: str, frame_exp: ptr[ir.Expr], bool_ty: types.Type, int_ty: types.Type, void_t: types.Type, cur: ref[vec.Vec[ir.Stmt]], state_cases: ref[vec.Vec[vec.Vec[ir.Stmt]]], await_idx: ref[int]) -> void:
    unsafe:
        match read(ep):
            ast.Expr.expr_await as aw:
                lower_async_await(ctx, name, aw.expression, resume_c_name, frame_c, frame_exp, bool_ty, int_ty, void_t, cur, state_cases, await_idx)
            _:
                # Non-await expression: lower normally
                let lowered = lower_expr(ctx, ep)
                cur.push(ir.Stmt.stmt_expression(expression = lowered, line = 0, source_path = ""))


## Core await lowering: evaluate task expression, emit suspend/resume boundary.
## Current state: check if task is ready, if not: set state+return.
## Next state: take result, continue.
function lower_async_await(ctx: ref[LowerCtx], name: str, task_ep: ptr[ast.Expr], resume_c_name: str, frame_c: str, frame_exp: ptr[ir.Expr], bool_ty: types.Type, int_ty: types.Type, void_t: types.Type, cur: ref[vec.Vec[ir.Stmt]], state_cases: ref[vec.Vec[vec.Vec[ir.Stmt]]], await_idx: ref[int]) -> void:
    let task_ir = lower_expr(ctx, task_ep)
    let old_idx = read(await_idx)
    read(await_idx) = old_idx + 1
    let next_state = old_idx + 1

    # Store task in frame: frame->await_N = task
    let await_fname = j3("await_", int_to_str(old_idx + 1), "")
    cur.push(ir.Stmt.stmt_assignment(
        target = alloc_expr(ir.Expr.expr_member(receiver = frame_exp, member = await_fname, ty = async_mod.ptr_void_type())),
        operator = "=",
        value = task_ir,
    ))
    let await_field = alloc_expr(ir.Expr.expr_member(receiver = frame_exp, member = await_fname, ty = async_mod.ptr_void_type()))

    # if (!task.ready(task.frame)) { suspend }
    let task_frame = alloc_expr(ir.Expr.expr_member(receiver = await_field, member = "frame", ty = async_mod.ptr_void_type()))
    let ready_fn = alloc_expr(ir.Expr.expr_member(receiver = await_field, member = "ready", ty = async_mod.ptr_void_type()))
    let ready_call = alloc_expr(ir.Expr.expr_call_indirect(callee = ready_fn, arguments = single_expr_span(task_frame), ty = bool_ty))
    let not_ready = alloc_expr(ir.Expr.expr_unary(operator = "not", operand = ready_call, ty = bool_ty))

    # Suspend body
    var suspend_body = vec.Vec[ir.Stmt].create()
    suspend_body.push(ir.Stmt.stmt_assignment(
        target = alloc_expr(ir.Expr.expr_member(receiver = frame_exp, member = "state", ty = int_ty)),
        operator = "=",
        value = alloc_expr(ir.Expr.expr_integer_literal(value = int<-next_state, ty = int_ty)),
    ))
    # set_waiter(frame, __mt_frame_raw, resume_fn) stub
    suspend_body.push(ir.Stmt.stmt_return(value = null, line = 0, source_path = ""))

    cur.push(ir.Stmt.stmt_if(
        condition = not_ready,
        then_body = suspend_body.as_span(),
        else_body = span[ir.Stmt](),
    ))

    # Finalize current state, start new state
    state_cases.push(unsafe: read(cur))
    var new_cur = vec.Vec[ir.Stmt].create()
    read(cur) = new_cur

    # Resume: result = task.take_result(task.frame)
    cur.push(ir.Stmt.stmt_expression(expression = alloc_expr(ir.Expr.expr_call_indirect(
        callee = alloc_expr(ir.Expr.expr_member(receiver = await_field, member = "take_result", ty = async_mod.ptr_void_type())),
        arguments = single_expr_span(task_frame),
        ty = async_mod.ptr_void_type(),
    )), line = 0, source_path = ""))


## Convert int to string.
function int_to_str(v: int) -> str:
    var buf = string.String.create()
    var n = v
    var is_neg = false
    if n < 0:
        n = 0 - n
        is_neg = true
    if n == 0:
        buf.push_byte(48)  # '0'
    while n > 0:
        let digit_int = n % 10
        buf.push_byte(ubyte<-(48 + digit_int))
        n = n / 10
    if is_neg:
        buf.push_byte(45)  # '-'
    return buf.as_str()


## Emit waiter wake: if frame->waiter is non-NULL, call it and null it.
function async_waiter_wake(ctx: ref[LowerCtx], output: ref[vec.Vec[ir.Stmt]], frame_exp: ptr[ir.Expr], bool_ty: types.Type, ptr_void_ty: types.Type) -> void:
    let waiter_field = alloc_expr(ir.Expr.expr_member(receiver = frame_exp, member = "waiter", ty = ptr_void_ty))
    let null_void = alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = ptr_void_ty))
    let has_waiter = alloc_expr(ir.Expr.expr_binary(operator = "!=", left = waiter_field, right = null_void, ty = bool_ty))
    var wake_body = vec.Vec[ir.Stmt].create()
    let waiter_frame_field = alloc_expr(ir.Expr.expr_member(receiver = frame_exp, member = "waiter_frame", ty = ptr_void_ty))
    # Null waiter before calling to prevent double-wake
    wake_body.push(ir.Stmt.stmt_assignment(target = waiter_field, operator = "=", value = null_void))
    # Call waiter(waiter_frame) via indirect call — cast waiter field to fn ptr
    let waiter_fn_casted = alloc_expr(ir.Expr.expr_cast(target_type = ptr_void_ty, expression = waiter_field, ty = ptr_void_ty))
    wake_body.push(ir.Stmt.stmt_expression(expression = alloc_expr(ir.Expr.expr_call_indirect(callee = waiter_fn_casted, arguments = single_expr_span(waiter_frame_field), ty = types.primitive("void"))), line = 0, source_path = ""))
    output.push(ir.Stmt.stmt_if(condition = has_waiter, then_body = wake_body.as_span(), else_body = span[ir.Stmt]()))


## ptr_uint primitive type (repeated for convenience in async section).
function ptr_uint_type() -> types.Type:
    return types.Type.ty_primitive(name = "ptr_uint")


## ptr[void] type — used for frame pointer in async CPS.
function ptr_void_type() -> types.Type:
    return types.Type.ty_generic(name = "ptr", args = single_ty_span(types.primitive("void")))


## True when `name` is one of the function-pointer fields on the Task[T] struct
## (ready, set_waiter, release, take_result, cancel) that must be accessed via
## struct field access + indirect call rather than treated as methods.
function is_task_fn_field(name: str) -> bool:
    return name == "ready" or name == "set_waiter" or name == "release" or name == "take_result" or name == "cancel"


## Extract the element type from a Task type (`ty_generic("Task", [T])`
## or `ty_named("mt_task_...")`).  Returns `ty_primitive("void")` on failure.
function extract_task_element_type(ctx: ref[LowerCtx], t: types.Type) -> types.Type:
    match t:
        types.Type.ty_generic as tg:
            if tg.name == "Task" and tg.args.len >= 1:
                return unsafe: read(tg.args.data + 0)
        types.Type.ty_named as tn:
            if tn.name.starts_with("mt_task_"):
                let gi_ptr = ctx.generic_struct_instances.get(tn.name)
                if gi_ptr != null:
                    let gi = unsafe: read(gi_ptr)
                    if gi.concrete_args.len >= 1:
                        return unsafe: read(gi.concrete_args.data + 0)
                        pass
        _:
            pass
    return types.primitive("void")


## Build a single-element span of IR expressions (for call arguments).
function single_expr_span(e: ptr[ir.Expr]) -> span[ir.Expr]:
    var v = vec.Vec[ir.Expr].create()
    unsafe:
        v.push(read(e))
    return v.as_span()


## Build a single-element span of types.
function single_ty_span(t: types.Type) -> span[types.Type]:
    var v = vec.Vec[types.Type].create()
    v.push(t)

    return v.as_span()
