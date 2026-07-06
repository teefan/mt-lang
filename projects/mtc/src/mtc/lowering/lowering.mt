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


# =============================================================================
#  Public API
# =============================================================================

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
        constants.append_span(fragment.constants)
        globals.append_span(fragment.globals)
        opaques.append_span(fragment.opaques)
        structs.append_span(fragment.structs)
        unions.append_span(fragment.unions)
        enums.append_span(fragment.enums)
        variants.append_span(fragment.variants)
        static_asserts.append_span(fragment.static_asserts)
        functions.append_span(fragment.functions)
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
        ir_params.push(ir.Param(name = p.name, linkage_name = p_c, ty = p_ty))
        ctx.locals.push(LocalBinding(name = p.name, c_name = p_c, ty = p_ty, pointer = false))
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
            program_analyses = program.analyses.as_span(),
            loaded_modules = program.modules.as_span(),
            spec_in_progress = map_mod.Map[str, bool].create(),
            type_substitution = map_mod.Map[str, types.Type].create(),
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
        program_analyses = program_analyses,
        loaded_modules = loaded_modules,
        spec_in_progress = map_mod.Map[str, bool].create(),
        type_substitution = map_mod.Map[str, types.Type].create(),
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
            _:
                pass
        i += 1

    # Append any generic struct declarations emitted during specialization.
    var gs_iter = ctx.generic_struct_decls.values()
    while true:
        let gs_ptr = gs_iter.next() else:
            break
        structs.push(unsafe: read(gs_ptr))

    # Append any monomorphized generic functions from the specialization cache.
    var spec_iter = ctx.specialization_cache.values()
    while true:
        let spec_ptr = spec_iter.next() else:
            break
        functions.push(unsafe: read(spec_ptr))

    return ir.Program(
        module_name = analysis.module_name,
        includes = span[ir.Include](),
        constants = span[ir.Constant](),
        globals = span[ir.Global](),
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
    if is_async:
        return false
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
        ir_params.push(ir.Param(name = p.name, linkage_name = c_name, ty = param_ty, pointer = false))
        ctx.locals.push(LocalBinding(name = p.name, c_name = c_name, ty = param_ty, pointer = false))
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
                            _:
                                pass
                let c_name = c_local_name(loc.name)
                var ty: types.Type
                var value_expr: ptr[ir.Expr]
                let init = loc.value
                if init == null:
                    let declared = loc.stmt_type else:
                        fatal(c"lowering Phase 3: local without initializer requires a type")
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
                let target = lower_expr(ctx, asg.target)
                let value = lower_expr(ctx, asg.value)
                output.push(ir.Stmt.stmt_assignment(target = target, operator = asg.operator, value = value))
            ast.Stmt.stmt_if as iff:
                if iff.branches.len > 0:
                    output.push(lower_if_chain(ctx, iff.branches, 0, iff.else_body))
            ast.Stmt.stmt_while as w:
                let cond = lower_expr(ctx, w.condition)
                let body = lower_block(ctx, w.body)
                output.push(ir.Stmt.stmt_while(condition = cond, body = body))
            ast.Stmt.stmt_for as f:
                lower_for_range(ctx, output, f.bindings, f.iterables, f.body)
            ast.Stmt.stmt_match as m:
                lower_match(ctx, output, m.scrutinee, m.arms)
            ast.Stmt.stmt_expression as ex:
                let lowered = lower_expr(ctx, ex.expression)
                output.push(ir.Stmt.stmt_expression(expression = lowered, line = ex.line, source_path = ""))
            _:
                fatal(c"lowering Phase 2: unsupported statement")


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
        fatal(c"lowering Phase 3: destructuring requires an initializer")
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
function qualify_type(ctx: ref[LowerCtx], t: types.Type) -> types.Type:
    match t:
        types.Type.ty_named as n:
            return types.Type.ty_imported(module_name = ctx.module_name, name = n.name)
        _:
            return t


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
            if t.nullable:
                return types.Type.ty_nullable(base = types.alloc_type(fun))
            return fun
        if t.is_dyn or t.nullable:
            return types.Type.ty_error
        if t.is_tuple:
            var elems = vec.Vec[types.Type].create()
            var i: ptr_uint = 0
            while i < t.arguments.len:
                elems.push(resolve_type_ref(ctx, t.arguments.data + i))
                i += 1
            return types.Type.ty_tuple(elements = elems.as_span())
        if t.arguments.len > 0:
            return resolve_generic_type_ref(ctx, t)
        if t.name.parts.len != 1:
            return types.Type.ty_error
        let name = read(t.name.parts.data + 0)
        if name.equal("str"):
            return types.Type.ty_str
        if is_primitive_name(name):
            return types.primitive(name)
        if ctx.analysis.type_names.contains(name):
            return types.Type.ty_imported(module_name = ctx.module_name, name = name)
        # Active type-parameter substitution (monomorphized body lowering).
        let concrete_ptr = ctx.type_substitution.get(name)
        if concrete_ptr != null:
            return unsafe: read(concrete_ptr)
        # Fallback for type parameters (e.g. `T`), resolved later via
        # type substitution during monomorphization.
        return types.Type.ty_named(name = name)


function resolve_generic_type_ref(ctx: ref[LowerCtx], t: ast.TypeRef) -> types.Type:
    if t.name.parts.len != 1:
        return types.Type.ty_error
    let name = unsafe: read(t.name.parts.data + 0)
    if name.equal("array") and t.arguments.len == 2:
        var args = vec.Vec[types.Type].create()
        unsafe:
            args.push(resolve_type_ref(ctx, t.arguments.data + 0))
        args.push(types.literal_int(resolve_array_length(unsafe: t.arguments.data + 1)))
        return types.Type.ty_generic(name = "array", args = args.as_span())
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
        fatal(c"lowering Phase 2: only single-binding range for-loops are supported")

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
                            return 0
            return 0
        _:
            return 0


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
            ast.Expr.expr_bool_literal as b:
                return alloc_expr(ir.Expr.expr_boolean_literal(value = b.value, ty = types.primitive("bool")))
            ast.Expr.expr_string_literal as lit:
                let ty = if lit.is_cstring: types.primitive("cstr") else: types.Type.ty_str
                return alloc_expr(ir.Expr.expr_string_literal(value = lit.value, ty = ty, cstring = lit.is_cstring))
            ast.Expr.expr_identifier as id:
                match lookup_local(ctx, id.name):
                    Option.some as lb:
                        return alloc_expr(ir.Expr.expr_name(name = lb.value.c_name, ty = lb.value.ty, pointer = lb.value.pointer))
                    Option.none:
                        return alloc_expr(ir.Expr.expr_name(name = id.name, ty = expr_type(ctx, ep), pointer = false))
            ast.Expr.expr_binary_op as bin:
                let left = lower_expr(ctx, bin.left)
                let right = lower_expr(ctx, bin.right)
                return alloc_expr(ir.Expr.expr_binary(operator = bin.operator, left = left, right = right, ty = expr_type(ctx, ep)))
            ast.Expr.expr_unary_op as un:
                let operand = lower_expr(ctx, un.operand)
                return alloc_expr(ir.Expr.expr_unary(operator = un.operator, operand = operand, ty = expr_type(ctx, ep)))
            ast.Expr.expr_call as call:
                return lower_call(ctx, call.callee, call.args, ep)
            ast.Expr.expr_member_access as ma:
                return lower_member_access(ctx, ma.receiver, ma.member_name, ep)
            ast.Expr.expr_index_access as ix:
                return lower_index_access(ctx, ix.receiver, ix.index, ep)
            ast.Expr.expr_expression_list as lst:
                return lower_tuple_literal(ctx, lst.elements)
            _:
                fatal(c"lowering Phase 3: unsupported expression")


## Lower a positional tuple literal `(a, b, ...)` to an aggregate literal with
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
                if ctx.analysis.structs.contains(id.name):
                    return lower_aggregate_literal(ctx, id.name, args)
                let foreign_ptr = ctx.foreign_map.get(id.name)
                if foreign_ptr != null:
                    return lower_foreign_call(ctx, read(foreign_ptr), args, call_ep)
                let extern_ptr = ctx.extern_map.get(id.name)
                if extern_ptr != null:
                    return lower_plain_call(ctx, read(extern_ptr), args, call_ep, null)
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
                    _:
                        pass
                fatal(c"lowering Phase 4: unsupported member-access call target")
            _:
                fatal(c"lowering Phase 3: unsupported call target")


## The result type of a cross-module call, resolved from the shared program-wide
## return map (keyed by C linkage name), falling back to the analyzer's recorded
## type for the call expression.
function cross_module_return_type(ctx: ref[LowerCtx], c_name: str, call_ep: ptr[ast.Expr]) -> types.Type:
    unsafe:
        var pr = read(ctx.program_returns)
        let rp = pr.get(c_name)
        if rp != null:
            return read(rp)
    # Also check per-module function_returns (monomorphized functions added here).
    let fp = ctx.function_returns.get(c_name)
    if fp != null:
        unsafe:
            return read(fp)
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
                            fatal(c"lowering Phase 3: span construction requires named fields")
                        fields.push(ir.AggregateField(name = field_name, value = lower_expr(ctx, arg.arg_value)))
                        i += 1
                    return alloc_expr(ir.Expr.expr_aggregate_literal(ty = span_ty, fields = fields.as_span()))
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
            _:
                pass
    # Generic function call, e.g. `first[int](p)`.  Lower a monomorphized copy of
    # the generic function body with concrete type arguments and emit a call to it.
    return lower_monomorphized_call(ctx, spec_callee, type_args, call_args, call_ep)


## True when every call argument has a name (field/keyword argument).
function all_call_args_named(args: span[ast.Argument]) -> bool:
    var i: ptr_uint = 0
    while i < args.len:
        let arg = unsafe: read(args.data + i)
        if arg.arg_name.is_none():
            return false
        i += 1
    return true


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
            fatal(c"lowering Phase 4c: generic struct construction requires named fields")
        fields.push(ir.AggregateField(name = field_name, value = lower_expr(ctx, arg.arg_value)))
        i += 1
    let result_ty = types.Type.ty_generic(name = struct_name, args = concrete_args.as_span())
    ensure_generic_struct_decl(ctx, struct_name, type_args, concrete_args.as_span())
    return alloc_expr(ir.Expr.expr_aggregate_literal(ty = result_ty, fields = fields.as_span()))


## Ensure a concrete struct declaration exists for a generic struct specialized
## with concrete type arguments.  If not yet registered, build one by resolving
## the original struct's fields with type substitution.
function ensure_generic_struct_decl(ctx: ref[LowerCtx], struct_name: str, type_args: span[ast.TypeArgument], concrete_args: span[types.Type]) -> void:
    let g_c_name = generic_struct_c_name(struct_name, concrete_args)
    if ctx.generic_struct_decls.contains(g_c_name):
        return
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
            ctx.generic_struct_decls.set(g_c_name, ir.StructDecl(
                name = g_c_name,
                linkage_name = g_c_name,
                fields = f.value,
                packed = false,
                alignment = 0,
                source_module = Option[str].none,
            ))
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
                        ir_fields.push(ir.Field(name = f.name, ty = field_ty))
                        fi += 1
            _:
                pass
        di += 1
    if not found:
        return Option[span[ir.Field]].none
    return Option[span[ir.Field]].some(value = ir_fields.as_span())


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
    let spec_key = specialization_key(ctx, callee, type_args)
    if not ctx.specialization_cache.contains(spec_key):
        lower_and_cache_specialization(ctx, callee, type_args, spec_key)
    let ret_ty = cross_module_return_type(ctx, spec_key, call_ep)
    var ret_type_ptr = types.alloc_type(ret_ty)
    return lower_plain_call(ctx, spec_key, call_args, call_ep, ret_type_ptr)


## Lower an uncached generic function specialization: find the function's AST
## declaration, build the type substitution map, lower the body, and cache.
function lower_and_cache_specialization(ctx: ref[LowerCtx], callee: ptr[ast.Expr], type_args: span[ast.TypeArgument], spec_key: str) -> void:
    # Detect cyclic generic instantiations (A[T] → B[T] → A[T]).
    if ctx.spec_in_progress.contains(spec_key):
        fatal(c"lowering Phase 4c: cyclic generic instantiation")
    ctx.spec_in_progress.set(spec_key, true)

    var callee_name: str
    unsafe:
        match read(callee):
            ast.Expr.expr_identifier as id:
                callee_name = id.name
            ast.Expr.expr_member_access as ma:
                callee_name = ma.member_name
            _:
                fatal(c"lowering Phase 4c: unsupported generic callee")

    # Find the function declaration — search analyses first, then raw loaded
    # modules (analyses may be incomplete for generic functions with complex
    # return types — raw source files always have the full AST).
    # Mirrors Ruby's @ctx.imports ModuleBinding access pattern.
    var fun_decl_opt = Option[ast.Decl].none
    var ai: ptr_uint = 0
    while ai < ctx.program_analyses.len and fun_decl_opt.is_none():
        var a: analyzer.Analysis
        unsafe:
            a = read(ctx.program_analyses.data + ai)
        fun_decl_opt = find_func_in_source(a.source_file, callee_name)
        ai += 1
    if fun_decl_opt.is_none():
        var mi: ptr_uint = 0
        while mi < ctx.loaded_modules.len and fun_decl_opt.is_none():
            var lm: loader.LoadedModule
            unsafe:
                lm = read(ctx.loaded_modules.data + mi)
            fun_decl_opt = find_func_in_source(lm.source_file, callee_name)
            mi += 1
    let fun_decl = fun_decl_opt else:
        if ctx.loaded_modules.len <= 1:
            fatal(c"lowering Phase 4c: only 1 module loaded, no imports available")
        fatal(c"lowering Phase 4c: could not find generic function decl")

    # Build type substitution map from the function's type params.
    match fun_decl:
        ast.Decl.decl_function as fun:
            var sub = map_mod.Map[str, types.Type].create()
            var tpi: ptr_uint = 0
            while tpi < fun.type_params.len:
                var tp: ast.TypeParam
                unsafe:
                    tp = read(fun.type_params.data + tpi)
                if tpi < type_args.len:
                    let concrete = resolve_type_ref(ctx, unsafe: read(type_args.data + tpi).value)
                    sub.set(tp.name, concrete)
                tpi += 1

            # Save the current context (locals, temp counter, function_returns)
            # and lower the specialized copy.
            var saved_locals = ctx.locals
            var saved_counter = ctx.temp_counter
            var saved_returns = ctx.function_returns
            ctx.locals = vec.Vec[LocalBinding].create()
            ctx.temp_counter = 0
            ctx.function_returns = map_mod.Map[str, types.Type].create()

            var spec_fun = lower_specialized_function(ctx, fun.name, fun.method_params, fun.return_type, fun.body, ref_of(sub))
            spec_fun.linkage_name = spec_key
            spec_fun.name = spec_key

            ctx.specialization_cache.set(spec_key, spec_fun)

            # Record the monomorphized function's return type on the ORIGINAL
            # (saved) function_returns so that subsequent lookups in the same
            # module find it after the context is restored.
            saved_returns.set(spec_key, spec_fun.return_type)

            # Restore the original lowering context.
            ctx.locals = saved_locals
            ctx.temp_counter = saved_counter
            ctx.function_returns = saved_returns
        _:
            fatal(c"lowering Phase 4c: expected function decl")


## Lower a payload variant arm constructor `Variant.arm(field = value, ...)` to an
## IR variant literal.  No-payload arms are handled in `lower_member_access`.
function lower_variant_literal(ctx: ref[LowerCtx], variant_name: str, arm_name: str, args: span[ast.Argument]) -> ptr[ir.Expr]:
    return alloc_expr(ir.Expr.expr_variant_literal(
        ty = types.Type.ty_imported(module_name = ctx.module_name, name = variant_name),
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


## Collect named field values from call arguments into variant literal fields.
function collect_variant_literal_fields(ctx: ref[LowerCtx], args: span[ast.Argument]) -> span[ir.AggregateField]:
    var fields = vec.Vec[ir.AggregateField].create()
    var i: ptr_uint = 0
    while i < args.len:
        var arg: ast.Argument
        unsafe:
            arg = read(args.data + i)
        let field_name = arg.arg_name else:
            fatal(c"lowering Phase 4b: variant arm construction requires named fields")
        fields.push(ir.AggregateField(name = field_name, value = lower_expr(ctx, arg.arg_value)))
        i += 1
    return fields.as_span()


## Build a specialization key from the callee name + concrete type args.  For a
## same-module function `first[int]`, the key is `<module_prefix>_first_int`.  The
## key doubles as the monomorphized C linkage name.
function specialization_key(ctx: ref[LowerCtx], callee: ptr[ast.Expr], type_args: span[ast.TypeArgument]) -> str:
    var buf = string.String.create()
    buf.append(naming.module_c_prefix(ctx.module_name))
    buf.append("_")
    unsafe:
        match read(callee):
            ast.Expr.expr_identifier as id:
                buf.append(id.name)
            ast.Expr.expr_member_access as ma:
                buf.append(ma.member_name)
            _:
                fatal(c"lowering Phase 4c: unsupported generic callee")
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
            fatal(c"lowering Phase 3: struct construction requires named fields")
        let value = lower_expr(ctx, arg.arg_value)
        fields.push(ir.AggregateField(name = field_name, value = value))
        i += 1
    return alloc_expr(ir.Expr.expr_aggregate_literal(
        ty = types.Type.ty_imported(module_name = ctx.module_name, name = struct_name),
        fields = fields.as_span(),
    ))


## Lower a call with no boundary projections: every argument lowered as-is.
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
                            fatal(c"lowering Phase 2d: only string-literal arguments are supported at an 'as cstr' boundary")
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
                fatal(c"lowering Phase 2d: unsupported foreign function mapping")


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
                        ty = types.Type.ty_imported(module_name = ctx.module_name, name = id.name),
                        arm_name = member,
                        fields = span[ir.AggregateField](),
                    ))
                if ctx.analysis.static_member_types.contains(id.name):
                    return alloc_expr(ir.Expr.expr_name(
                        name = naming.qualified_member_c_name(ctx.module_name, id.name, member),
                        ty = expr_type(ctx, ep),
                        pointer = false,
                    ))
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
            _:
                pass
    let recv = lower_expr(ctx, receiver)
    var member_ty = expr_type(ctx, ep)
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
            return buf.as_str()
        types.Type.ty_imported as im:
            return naming.qualified_c_name(im.module_name, im.name)
        _:
            return naming.qualified_c_name(module_name, "")


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
        if tref.nullable:
            return types.Type.ty_nullable(base = types.alloc_type(fun))
        return fun
    if tref.is_dyn or tref.is_tuple or tref.nullable:
        return types.Type.ty_error
    if tref.arguments.len > 0:
        return resolve_generic_type_ref(ctx, tref)
    if tref.name.parts.len != 1:
        return types.Type.ty_error
    let name = unsafe: read(tref.name.parts.data + 0)
    if ctx.analysis.type_names.contains(name):
        return types.Type.ty_imported(module_name = ctx.module_name, name = name)
    # Active type-parameter substitution during monomorphized lowering.
    let concrete_ptr = ctx.type_substitution.get(name)
    if concrete_ptr != null:
        return unsafe: read(concrete_ptr)
    # Fallback: the name may be a type parameter (like `T`) which is resolved
    # later via type substitution during monomorphization.
    return types.Type.ty_named(name = name)


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
function lower_match(ctx: ref[LowerCtx], output: ref[vec.Vec[ir.Stmt]], scrutinee: ptr[ast.Expr], arms: span[ast.MatchArm]) -> void:
    let scrutinee_ty = expr_type(ctx, scrutinee)
    let type_name = named_type_name(scrutinee_ty)

    if type_name.is_some() and ctx.variants.contains(type_name.unwrap()):
        lower_variant_match(ctx, output, scrutinee, type_name.unwrap(), scrutinee_ty, arms)
        return

    let gen_var = generic_variant_name(scrutinee_ty)
    if gen_var.is_some() and ctx.variants.contains(gen_var.unwrap()):
        lower_variant_match(ctx, output, scrutinee, gen_var.unwrap(), scrutinee_ty, arms)
        return

    let enum_name = type_name else:
        fatal(c"lowering Phase 2: match is only supported over enum/flags/variant scrutinees")

    let scrutinee_expr = lower_expr(ctx, scrutinee)
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
                fatal(c"lowering Phase 2: unsupported match pattern")
            let value = alloc_expr(ir.Expr.expr_name(
                name = naming.qualified_member_c_name(ctx.module_name, enum_name, member),
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
                    fatal(c"lowering Phase 5: match expression on non-enum scrutinee")
        i += 1

    output.push(ir.Stmt.stmt_switch(expression = scrutinee_expr, cases = cases.as_span(), exhaustive = not has_wildcard))


## Lower a match expression over a variant scrutinee: emit a switch on the variant
## kind, with each arm assigning its value to the result reference.
function lower_variant_match_expr(ctx: ref[LowerCtx], output: ref[vec.Vec[ir.Stmt]], scrutinee_expr: ptr[ir.Expr], variant_name: str, scrutinee_ty: types.Type, arms: span[ast.MatchExprArm], result_ref: ptr[ir.Expr]) -> void:
    let info_ptr = ctx.variants.get(variant_name) else:
        fatal(c"lowering Phase 5: variant match expr on unknown variant")
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
                        fatal(c"lowering Phase 5: unsupported variant match expression pattern")
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
                fatal(c"lowering Phase 5: unsupported variant match expression pattern")
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
    let info_ptr = ctx.variants.get(variant_name) else:
        fatal(c"lowering Phase 4b: variant match on unknown variant")
    let info = unsafe: read(info_ptr)
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
                fatal(c"lowering Phase 4b: unsupported variant match pattern")
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
        fatal(c"lowering Phase 4b: variant match on unknown variant")
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
                fatal(c"lowering Phase 4b: unsupported variant match pattern")
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
                            fatal(c"lowering Phase 4b: variant match equality patterns not yet supported")
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
                            fatal(c"lowering Phase 4b: variant match guard patterns not yet supported")
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
        _:
            return Option[str].none


## Extract the base variant name from a generic variant type (`Option[int]` →
## "Option"), so match on a generic scrutinee can resolve prelude arm names.
function generic_variant_name(t: types.Type) -> Option[str]:
    match t:
        types.Type.ty_generic as g:
            return Option[str].some(value = g.name)
        _:
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
        return resolved
    return qualify_type(ctx, fn_sig_param_type(sig, index))


## A function's lowered return type: resolved from the AST return type ref (so
## tuple/array/span returns carry full structure), falling back to the signature.
function resolve_return_type(ctx: ref[LowerCtx], sig: Option[analyzer.FnSig], return_type: ptr[ast.TypeRef]?) -> types.Type:
    let annotation = return_type else:
        return qualify_type(ctx, fn_sig_return_type(sig))
    let resolved = resolve_type_ref(ctx, annotation)
    if not types.is_error(resolved):
        return resolved
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
        if t.is_fn or t.is_proc or t.is_dyn or t.is_tuple or t.nullable:
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
