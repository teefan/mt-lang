## Semantic analyzer — mirrors the structure of Ruby's SemanticAnalyzer
## (lib/milk_tea/core/semantic_analyzer.rb): a structural collection pass over
## top-level declarations followed by per-function body checking.
##
## The analyzer is intentionally conservative — anything it cannot resolve
## concretely degrades to `ty_error` (permissive — compatible with everything),
## so valid programs are never flagged.  Type resolution for the C backend is
## handled by the lowering, which walks the AST directly.  The analyzer catches
## structural errors: duplicate declarations, return-type mismatches on
## concrete types, immutable-assignment violations, and module-import
## inconsistencies.

import std.map as map_mod
import std.str
import std.string as string
import std.vec as vec

import mtc.parser.ast as ast
import mtc.semantic.types as types
import mtc.semantic.type_compatibility as compat
import mtc.semantic.expressions as exprs
import mtc.semantic.control_flow.definite_assignment as da
import mtc.semantic.diagnostics as diag
import mtc.semantic.emit_expansion as emit_ex
import mtc.semantic.scope as sscope


public struct SemanticDiagnostic:
    line: ptr_uint
    column: ptr_uint
    ## Character length of the offending token (0 when the report site has none);
    ## the LSP falls back to 1, matching the Ruby `Diagnostic#length` default.
    length: ptr_uint
    message: str


public struct ParamEntry:
    name: str
    ty: types.Type


public struct FnSig:
    name: str
    params: span[ParamEntry]
    return_type: types.Type
    has_return_type: bool
    method_kind: ast.MethodKind
    ## True for `async function`/`async` methods.  Lets the lowering wrap the
    ## call's return type in `Task[T]` and route the definition through CPS.
    is_async: bool
    ## True for variadic functions (`external function f(..., ...)`).  The
    ## param count in `params` covers only the fixed parameters; arity checks
    ## are skipped because callers may pass additional variadic arguments.
    is_variadic: bool
    ## True for foreign/external functions.  When set, `check_call` skips
    ## signature checking (the parameter types are boundary projections, not
    ## Milk Tea types the analyzer can validate) and just returns the type.
    is_extern: bool
    ## Number of leading parameters without a default value.  Parameters with
    ## defaults may be omitted at the call site, so the accepted argument count
    ## ranges from `required_count` to `params.len`.
    required_count: ptr_uint


public struct FieldEntry:
    name: str
    ty: types.Type


public struct EventInfo:
    name: str
    capacity: int
    payload_type: ptr[ast.TypeRef]?


## The public export surface of a module, consumed by importers for cross-module
## name resolution.  Built from an Analysis by the loader's binder
## (mtc.loader.binder); the type lives here to keep the analyzer free of a
## dependency on the loader.  Exposes public functions (call checks), structs
## (construction field checks), value types (const/var), and enum/variant static
## members (member-access validation).
public struct ModuleBinding:
    functions: map_mod.Map[str, FnSig]
    structs: map_mod.Map[str, span[FieldEntry]]
    unions: map_mod.Map[str, span[FieldEntry]]
    value_types: map_mod.Map[str, types.Type]
    const_values: map_mod.Map[str, ptr[ast.Expr]]
    type_aliases: map_mod.Map[str, bool]
    type_alias_types: map_mod.Map[str, types.Type]
    static_member_types: map_mod.Map[str, bool]
    member_keys: map_mod.Map[str, bool]
    method_sigs: map_mod.Map[str, FnSig]
    interfaces: map_mod.Map[str, span[ast.InterfaceMethod]]
    implemented: map_mod.Map[str, span[ast.QualifiedName]]
    match_case_names: map_mod.Map[str, span[str]]
    types: map_mod.Map[str, bool]
    private_functions: map_mod.Map[str, FnSig]
    private_structs: map_mod.Map[str, span[FieldEntry]]
    private_unions: map_mod.Map[str, span[FieldEntry]]
    private_value_types: map_mod.Map[str, types.Type]
    private_type_aliases: map_mod.Map[str, bool]
    private_static_member_types: map_mod.Map[str, bool]
    private_member_keys: map_mod.Map[str, bool]
    private_method_sigs: map_mod.Map[str, FnSig]
    ## Declared generic parameters per exported type name (`Vec` -> `[T]`).
    type_param_names: map_mod.Map[str, span[ast.TypeParam]]
    ## Declared generic parameters per exported function (`iter_filter` -> `[T]`),
    ## so an imported call can infer its type arguments from the arguments.
    function_type_params: map_mod.Map[str, span[ast.TypeParam]]
    private_interfaces: map_mod.Map[str, span[ast.InterfaceMethod]]


struct Context:
    value_names: map_mod.Map[str, bool]
    type_names: map_mod.Map[str, bool]
    type_aliases: map_mod.Map[str, ptr[ast.TypeRef]]
    type_alias_types: map_mod.Map[str, types.Type]
    alias_types: map_mod.Map[str, types.Type]
    structs: map_mod.Map[str, span[FieldEntry]]
    unions: map_mod.Map[str, span[FieldEntry]]
    method_keys: map_mod.Map[str, bool]
    method_sigs: map_mod.Map[str, FnSig]
    static_member_types: map_mod.Map[str, bool]
    match_case_types: map_mod.Map[str, bool]
    match_case_names: map_mod.Map[str, span[str]]
    functions: map_mod.Map[str, FnSig]
    value_types: map_mod.Map[str, types.Type]
    interfaces: map_mod.Map[str, span[ast.InterfaceMethod]]
    extending_canonical_names: map_mod.Map[str, str]
    type_params: map_mod.Map[str, span[ast.TypeParamConstraint]]
    ## Declared generic parameters per type name (`Vec` -> `[T]`).
    type_param_names: map_mod.Map[str, span[ast.TypeParam]]
    ## Receiver identifiers of `editable` method calls (`s.push(x)`) with the
    ## call's line: a binding used this way is mutated (the host's
    ## `editable_receiver_expression_ids`), which the linter's prefer-let needs
    ## because it cannot resolve method kinds itself.
    editable_receiver_sites: vec.Vec[EditableSite]
    # Names known to be generic type/value parameters in the current
    # declaration context (struct fields, `extending Type[T]` methods, foreign
    # value params, interface methods).  Used ONLY to suppress "unknown type"
    # reports; unlike `type_params`, these still resolve to the permissive
    # `ty_error` so recorded types — and thus code generation — are unchanged.
    suppressed_type_names: map_mod.Map[str, bool]
    function_type_params: map_mod.Map[str, span[ast.TypeParam]]
    method_type_params: map_mod.Map[str, span[ast.TypeParam]]
    implemented: map_mod.Map[str, span[ast.QualifiedName]]
    import_aliases: map_mod.Map[str, str]
    imported_modules: ptr[map_mod.Map[str, ModuleBinding]]?
    ## True when unresolved imports must leave their alias unbound, so uses of
    ## the alias are reported as unknown names (the LSP's `allow_missing_imports`
    ## equivalent).  The compile path leaves it false and stays permissive.
    require_resolved_imports: bool
    types: map_mod.Map[str, types.Type]
    attribute_apps: map_mod.Map[str, vec.Vec[ast.AttributeApplication]]
    field_attribute_apps: map_mod.Map[str, vec.Vec[ast.AttributeApplication]]
    unsafe_depth: int
    inside_async: bool
    resolved_expr_types: map_mod.Map[ptr_uint, types.Type]
    resolved_call_kinds: map_mod.Map[ptr_uint, str]
    const_values: map_mod.Map[str, ptr[ast.Expr]]
    declared_attributes: map_mod.Map[str, span[str]]
    diagnostics: vec.Vec[SemanticDiagnostic]
    uses_parallel_for: bool
    event_types: map_mod.Map[str, EventInfo]
    module_name: str


public struct Analysis:
    source_file: ast.SourceFile
    diagnostics: vec.Vec[SemanticDiagnostic]
    type_names: map_mod.Map[str, bool]
    structs: map_mod.Map[str, span[FieldEntry]]
    unions: map_mod.Map[str, span[FieldEntry]]
    functions: map_mod.Map[str, FnSig]
    value_types: map_mod.Map[str, types.Type]
    method_keys: map_mod.Map[str, bool]
    method_sigs: map_mod.Map[str, FnSig]
    static_member_types: map_mod.Map[str, bool]
    match_case_names: map_mod.Map[str, span[str]]
    interfaces: map_mod.Map[str, span[ast.InterfaceMethod]]
    resolved_expr_types: map_mod.Map[ptr_uint, types.Type]
    resolved_call_kinds: map_mod.Map[ptr_uint, str]
    const_values: map_mod.Map[str, ptr[ast.Expr]]
    module_name: str
    module_kind: ast.ModuleKind
    unsafe_statement_lines: vec.Vec[ptr_uint]
    uses_parallel_for: bool
    declared_attributes: map_mod.Map[str, span[str]]
    imports: map_mod.Map[str, str]
    implemented_interfaces: map_mod.Map[str, span[ast.QualifiedName]]
    directives: span[ast.Decl]
    types: map_mod.Map[str, types.Type]
    attribute_applications: map_mod.Map[str, span[ast.AttributeApplication]]
    field_attribute_applications: map_mod.Map[str, span[ast.AttributeApplication]]
    events: map_mod.Map[str, EventInfo]
    type_alias_types: map_mod.Map[str, types.Type]
    # Literal extending-target name → resolved type name for alias-qualified
    # blocks (`extending b3.Vec3:` → `b3Vec3`), so importers can resolve the
    # methods by the name a receiver resolves to.
    extending_canonical_names: map_mod.Map[str, str]
    ## Declared generic parameters per type name, so an instantiated receiver
    ## (`Vec[int]`) can substitute them.
    type_param_names: map_mod.Map[str, span[ast.TypeParam]]
    ## Receiver identifiers of `editable` method calls, with their lines.
    editable_receiver_sites: vec.Vec[EditableSite]
    # The module's source file path, propagated so lowering can emit `#line`
    # directives that map generated C back to the .mt source (debug builds).
    source_path: str


public function check_source_file(file: ast.SourceFile) -> Analysis:
    return check_module(file, null, "", "")


## Semantically check a module, resolving cross-module references against the
## given import bindings (keyed by module name; may be null for single-file
## checks).  `imported_modules` is borrowed, not owned.
public function check_module(file: ast.SourceFile, imported_modules: ptr[map_mod.Map[str, ModuleBinding]]?, module_name: str, source_path: str) -> Analysis:
    return check_module_opts(file, imported_modules, module_name, source_path, false)


## `check_module` with the LSP's unresolved-import handling: aliases whose
## module did not resolve are left unbound (the host's `allow_missing_imports`
## behaviour), so uses of them are reported as unknown names.
public function check_module_requiring_resolved_imports(file: ast.SourceFile, imported_modules: ptr[map_mod.Map[str, ModuleBinding]]?, module_name: str, source_path: str) -> Analysis:
    return check_module_opts(file, imported_modules, module_name, source_path, true)


public function check_module_opts(file: ast.SourceFile, imported_modules: ptr[map_mod.Map[str, ModuleBinding]]?, module_name: str, source_path: str, require_resolved_imports: bool) -> Analysis:
    var ctx = Context(
        value_names = map_mod.Map[str, bool].create(),
        type_names = map_mod.Map[str, bool].create(),
        type_aliases = map_mod.Map[str, ptr[ast.TypeRef]].create(),
        type_alias_types = map_mod.Map[str, types.Type].create(),
        alias_types = map_mod.Map[str, types.Type].create(),
        structs = map_mod.Map[str, span[FieldEntry]].create(),
        unions = map_mod.Map[str, span[FieldEntry]].create(),
        method_keys = map_mod.Map[str, bool].create(),
        method_sigs = map_mod.Map[str, FnSig].create(),
        static_member_types = map_mod.Map[str, bool].create(),
        match_case_types = map_mod.Map[str, bool].create(),
        match_case_names = map_mod.Map[str, span[str]].create(),
        functions = map_mod.Map[str, FnSig].create(),
        value_types = map_mod.Map[str, types.Type].create(),
        interfaces = map_mod.Map[str, span[ast.InterfaceMethod]].create(),
        extending_canonical_names = map_mod.Map[str, str].create(),
        type_params = map_mod.Map[str, span[ast.TypeParamConstraint]].create(),
        type_param_names = map_mod.Map[str, span[ast.TypeParam]].create(),
        editable_receiver_sites = vec.Vec[EditableSite].create(),
        suppressed_type_names = map_mod.Map[str, bool].create(),
        function_type_params = map_mod.Map[str, span[ast.TypeParam]].create(),
        method_type_params = map_mod.Map[str, span[ast.TypeParam]].create(),
        implemented = map_mod.Map[str, span[ast.QualifiedName]].create(),
        import_aliases = map_mod.Map[str, str].create(),
        imported_modules = imported_modules,
        require_resolved_imports = require_resolved_imports,
        types = map_mod.Map[str, types.Type].create(),
        attribute_apps = map_mod.Map[str, vec.Vec[ast.AttributeApplication]].create(),
        field_attribute_apps = map_mod.Map[str, vec.Vec[ast.AttributeApplication]].create(),
        unsafe_depth = 0,
        inside_async = false,
        resolved_expr_types = map_mod.Map[ptr_uint, types.Type].create(),
        resolved_call_kinds = map_mod.Map[ptr_uint, str].create(),
        const_values = map_mod.Map[str, ptr[ast.Expr]].create(),
        declared_attributes = map_mod.Map[str, span[str]].create(),
        diagnostics = vec.Vec[SemanticDiagnostic].create(),
        uses_parallel_for = false,
        event_types = map_mod.Map[str, EventInfo].create(),
        module_name = module_name,
    )
    let source = expand_emit_declarations(file)
    collect_import_aliases(ref_of(ctx), source)
    declare_named_types(ref_of(ctx), source)
    install_prelude_types(ref_of(ctx))
    declare_attributes(ref_of(ctx), source)
    var when_extra = expand_module_when(ref_of(ctx), source)
    # Values and functions are declared before struct fields resolve: an array
    # size in a struct field may name a module constant
    # (`ground_ids: array[BodyId, MAX_GROUND_BODIES]`), and the type resolver
    # folds it from `const_values`.
    declare_values_and_functions(ref_of(ctx), source)
    declare_values_and_functions_extra(ref_of(ctx), when_extra)
    collect_struct_fields(ref_of(ctx), source)
    collect_struct_fields_extra(ref_of(ctx), when_extra)
    check_attribute_applications(ref_of(ctx), source)
    collect_extending_methods(ref_of(ctx), source)
    collect_enum_variant_members(ref_of(ctx), source)
    collect_interfaces(ref_of(ctx), source)
    register_event_methods(ref_of(ctx))
    register_task_methods(ref_of(ctx))
    check_functions(ref_of(ctx), source)
    check_extending_methods(ref_of(ctx), source)
    check_interface_conformances(ref_of(ctx), source)
    check_extern_and_foreign(ref_of(ctx), source)
    check_top_level_static_asserts(ref_of(ctx), source)
    return Analysis(
        source_file = source,
        diagnostics = ctx.diagnostics,
        type_names = ctx.type_names,
        structs = ctx.structs,
        unions = ctx.unions,
        functions = ctx.functions,
        value_types = ctx.value_types,
        method_keys = ctx.method_keys,
        method_sigs = ctx.method_sigs,
        static_member_types = ctx.static_member_types,
        match_case_names = ctx.match_case_names,
        interfaces = ctx.interfaces,
        resolved_expr_types = ctx.resolved_expr_types,
        resolved_call_kinds = ctx.resolved_call_kinds,
        const_values = ctx.const_values,
        module_name = module_name,
        module_kind = file.module_kind,
        unsafe_statement_lines = vec.Vec[ptr_uint].create(),
        uses_parallel_for = ctx.uses_parallel_for,
        declared_attributes = ctx.declared_attributes,
        imports = ctx.import_aliases,
        implemented_interfaces = ctx.implemented,
        directives = file.directives,
        types = ctx.types,
        attribute_applications = build_attr_app_spans(ref_of(ctx)),
        field_attribute_applications = build_field_attr_app_spans(ref_of(ctx)),
        events = ctx.event_types,
        type_alias_types = ctx.type_alias_types,
        extending_canonical_names = ctx.extending_canonical_names,
        type_param_names = ctx.type_param_names,
        editable_receiver_sites = ctx.editable_receiver_sites,
        source_path = source_path,
    )


function report(ctx: ref[Context], line: ptr_uint, column: ptr_uint, message: str) -> void:
    ctx.diagnostics.push(SemanticDiagnostic(line = line, column = column, length = 0, message = message))


## Like `report`, with the offending token's character length so the LSP range
## spans the token (Ruby's sema diagnostics carry a `length`).
function report_at(ctx: ref[Context], line: ptr_uint, column: ptr_uint, length: ptr_uint, message: str) -> void:
    ctx.diagnostics.push(SemanticDiagnostic(line = line, column = column, length = length, message = message))


## Record each import's alias -> module name so member access on an alias
## (`alias.func(...)`) can be resolved against the imported module's bindings.
## With `require_resolved_imports` (the LSP path, mirroring the host's
## `allow_missing_imports` handling) an alias whose module did not resolve stays
## unbound, so uses of it are reported as unknown names; the compile path keeps
## the permissive aliasing that lowering relies on.
function collect_import_aliases(ctx: ref[Context], file: ast.SourceFile) -> void:
    var i: ptr_uint = 0
    while i < file.imports.len:
        var d: ast.Decl
        unsafe:
            d = read(file.imports.data + i)
        match d:
            ast.Decl.decl_import as imp:
                let module_name = qname_to_str(imp.path)
                if not ctx.require_resolved_imports or lookup_binding(ctx, module_name) != null:
                    ctx.import_aliases.set(import_alias_name(imp.path, imp.alias_name), module_name)
            _:
                pass
        i += 1


## The local name an import is bound to: the explicit alias, or the last path
## segment when none is given (`import a.b.c` binds `c`).
function import_alias_name(path: ast.QualifiedName, alias_name: Option[str]) -> str:
    match alias_name:
        Option.some as given:
            return given.value
        Option.none:
            if path.parts.len == 0:
                return ""
            unsafe:
                return read(path.parts.data + (path.parts.len - 1))


# =============================================================================
#  Structural collection — declare_named_types / declare_values_and_functions
# =============================================================================

function declare_named_types(ctx: ref[Context], file: ast.SourceFile) -> void:
    var i: ptr_uint = 0
    while i < file.declarations.len:
        var d: ast.Decl
        unsafe:
            d = read(file.declarations.data + i)
        match d:
            ast.Decl.decl_struct as s:
                declare_type(ctx, s.name, s.line, s.column)
                ctx.types.set(s.name, types.Type.ty_named(module_name = ctx.module_name, name = s.name))
                ctx.type_param_names.set(s.name, s.type_params)
                ctx.implemented.set(s.name, s.impl_list)
                register_nested_struct_types(ctx, s.nested_types, s.name)
                register_struct_events(ctx, s.struct_events)
            ast.Decl.decl_union as u:
                declare_type(ctx, u.name, u.line, u.column)
                ctx.types.set(u.name, types.Type.ty_named(module_name = ctx.module_name, name = u.name))
            ast.Decl.decl_enum as e:
                declare_type(ctx, e.name, e.line, e.column)
                ctx.types.set(e.name, types.Type.ty_named(module_name = ctx.module_name, name = e.name))
            ast.Decl.decl_flags as fl:
                declare_type(ctx, fl.name, fl.line, fl.column)
                ctx.types.set(fl.name, types.Type.ty_named(module_name = ctx.module_name, name = fl.name))
            ast.Decl.decl_variant as vr:
                declare_type(ctx, vr.name, vr.line, vr.column)
                ctx.types.set(vr.name, types.Type.ty_named(module_name = ctx.module_name, name = vr.name))
                ctx.type_param_names.set(vr.name, vr.type_params)
            ast.Decl.decl_opaque as op:
                declare_type(ctx, op.name, op.line, op.column)
                ctx.types.set(op.name, types.Type.ty_named(module_name = ctx.module_name, name = op.name))
                ctx.implemented.set(op.name, op.opaque_implements)
            ast.Decl.decl_type_alias as ta:
                # Only register the alias here: its target may name a type that
                # is declared *later* in the file (e.g. a callback signature
                # taking a struct declared further down), so resolution happens
                # in the second pass once every name is known.
                declare_type(ctx, ta.name, ta.line, ta.column)
                ctx.type_aliases.set(ta.name, ta.target)
            ast.Decl.decl_event as ev:
                declare_type(ctx, ev.name, ev.line, ev.column)
                ctx.event_types.set(ev.name, EventInfo(name = ev.name, capacity = ev.capacity, payload_type = ev.payload_type))
            _:
                pass
        i += 1

    # Second pass: resolve every alias now that all type names exist.
    i = 0
    while i < file.declarations.len:
        var d: ast.Decl
        unsafe:
            d = read(file.declarations.data + i)
        match d:
            ast.Decl.decl_type_alias as ta:
                let resolved = resolve_type(ctx, ta.target)
                ctx.type_alias_types.set(ta.name, resolved)
                ctx.types.set(ta.name, resolved)
            _:
                pass
        i += 1


function declare_type(ctx: ref[Context], name: str, line: ptr_uint, column: ptr_uint) -> void:
    if ctx.type_names.contains(name):
        report(ctx, line, column, dup_message("type", name))
        return
    ctx.type_names.set(name, true)


function register_nested_struct_types(ctx: ref[Context], nested: span[ast.Decl], parent_name: str) -> void:
    var i: ptr_uint = 0
    while i < nested.len:
        var d: ast.Decl
        unsafe:
            d = read(nested.data + i)
        match d:
            ast.Decl.decl_struct as s:
                var qualified = string.String.create()
                qualified.append(parent_name)
                qualified.append(".")
                qualified.append(s.name)
                let qname = qualified.as_str()
                declare_type(ctx, qname, s.line, s.column)
                if not ctx.type_names.contains(s.name):
                    declare_type(ctx, s.name, s.line, s.column)
                ctx.types.set(qname, types.Type.ty_named(module_name = ctx.module_name, name = qname))
                register_nested_struct_types(ctx, s.nested_types, qname)
                register_struct_events(ctx, s.struct_events)
            _:
                pass
        i += 1


## Register event types and values from a struct's event declarations, so
## struct-member event access (`window.closed.emit()`) resolves correctly.
function register_struct_events(ctx: ref[Context], events: span[ast.Decl]) -> void:
    var i: ptr_uint = 0
    while i < events.len:
        unsafe:
            match read(events.data + i):
                ast.Decl.decl_event as ev:
                    ctx.event_types.set(ev.name, EventInfo(name = ev.name, capacity = ev.capacity, payload_type = ev.payload_type))
                _:
                    pass
        i += 1


## Expand module-level `when` blocks: for each `when CONST:`, resolve the
## discriminant against its const value, pick the matching branch, and return the
## branch's declarations as additional top-level items.  Complex discriminants
## that cannot be resolved return an empty span (permissive — keeps all branches
## in the original AST).
## Splice declarations produced by `emit` statements inside top-level const
## function bodies into the module's top-level declarations, so the emitted
## functions become ordinary declarations that are declared, checked, and
## lowered like any other.  Mirrors Ruby's collect_emit_declarations (which
## appends emitted decls to @ctx.ast.declarations before declare_functions).
## Returns `file` unchanged when no emit statements are present.
function expand_emit_declarations(file: ast.SourceFile) -> ast.SourceFile:
    return emit_ex.expand_emit_declarations(file)


function expand_module_when(ctx: ref[Context], file: ast.SourceFile) -> span[ast.Decl]:
    var extra = vec.Vec[ast.Decl].create()
    var i: ptr_uint = 0
    while i < file.declarations.len:
        var d: ast.Decl
        unsafe:
            d = read(file.declarations.data + i)
        match d:
            ast.Decl.decl_when as w:
                match evaluate_when_discriminant(ctx, w.discriminant, file.declarations):
                    Option.some as chosen:
                        collect_when_branch_decls(w.branches, chosen.value, ref_of(extra))
                    Option.none:
                        pass
            _:
                pass
        i += 1
    return extra.as_span()


## Evaluate a when-discriminant expression into the enum member name it
## represents.  Handles `const_name` (looks up the const's value) and
## `EnumType.member` (direct enum member reference).  Returns none when the
## discriminant cannot be resolved.
function evaluate_when_discriminant(ctx: ref[Context], discriminant: ptr[ast.Expr], decls: span[ast.Decl]) -> Option[str]:
    unsafe:
        match read(discriminant):
            ast.Expr.expr_identifier as id:
                # Try ctx.const_values first (populated by CT eval)
                let chain_ptr = ctx.const_values.get(id.name)
                if chain_ptr != null:
                    return evaluate_when_discriminant(ctx, read(chain_ptr), decls)
                # Fallback: search declarations in the file
                match find_const_value_in_decls(decls, id.name):
                    Option.some as val_expr:
                        return evaluate_when_discriminant(ctx, val_expr.value, decls)
                    Option.none:
                        return Option[str].none
            ast.Expr.expr_member_access as ma:
                return resolve_when_enum_member(ma.receiver, ma.member_name)
            _:
                return Option[str].none


## Extract the const value expression referenced by a when discriminant.
## Returns the initializer of the const declaration with the given name.
function find_const_value_in_decls(decls: span[ast.Decl], const_name: str) -> Option[ptr[ast.Expr]]:
    var i: ptr_uint = 0
    while i < decls.len:
        var d: ast.Decl
        unsafe:
            d = read(decls.data + i)
        match d:
            ast.Decl.decl_const as c:
                if c.name == const_name:
                    let val = c.value else:
                        return Option[ptr[ast.Expr]].none
                    return Option[ptr[ast.Expr]].some(value = val)
            _:
                pass
        i += 1
    return Option[ptr[ast.Expr]].none


## Resolve `EnumType.member` in a when discriminant.  Returns the member name
## when `receiver` is a known enum type.
function resolve_when_enum_member(receiver: ptr[ast.Expr], member: str) -> Option[str]:
    var recv: ast.Expr
    unsafe:
        recv = read(receiver)
    match recv:
        ast.Expr.expr_identifier as id:
            if is_primitive_type_name(id.name):
                return Option[str].none
            return Option[str].some(value = member)
        _:
            return Option[str].none


## Copy the chosen when-branch's declarations into the output vector.
function collect_when_branch_decls(branches: span[ast.WhenDeclBranch], chosen: str, output: ref[vec.Vec[ast.Decl]]) -> void:
    var i: ptr_uint = 0
    while i < branches.len:
        var br: ast.WhenDeclBranch
        unsafe:
            br = read(branches.data + i)
        match extract_when_member_name(br.pattern):
            Option.some as nm:
                if nm.value == chosen:
                    copy_when_body_decls(br.body, output)
            Option.none:
                pass
        i += 1


## Extract `EnumType.member` from a when-branch pattern.  Returns the member
## name when the pattern is a qualifield member access on an enum type.
function extract_when_member_name(pattern: ptr[ast.Expr]) -> Option[str]:
    unsafe:
        match read(pattern):
            ast.Expr.expr_member_access as ma:
                return Option[str].some(value = ma.member_name)
            _:
                return Option[str].none


## Copy declarations (not imports) from a when-branch body into `output`.
function copy_when_body_decls(body: span[ast.Decl], output: ref[vec.Vec[ast.Decl]]) -> void:
    var i: ptr_uint = 0
    while i < body.len:
        unsafe:
            output.push(read(body.data + i))
        i += 1


function collect_struct_fields_extra(ctx: ref[Context], extra: span[ast.Decl]) -> void:
    var i: ptr_uint = 0
    while i < extra.len:
        var d: ast.Decl
        unsafe:
            d = read(extra.data + i)
        match d:
            ast.Decl.decl_struct as s:
                enter_type_params(ctx, s.type_params)
                ctx.structs.set(s.name, resolve_field_entries(ctx, s.struct_fields))
                collect_nested_struct_fields(ctx, s.nested_types, s.name)
                ctx.type_params.clear()
                ctx.suppressed_type_names.clear()
            _:
                pass
        i += 1


function declare_values_and_functions_extra(ctx: ref[Context], extra: span[ast.Decl]) -> void:
    var i: ptr_uint = 0
    while i < extra.len:
        var d: ast.Decl
        unsafe:
            d = read(extra.data + i)
        match d:
            ast.Decl.decl_const as c:
                if declare_value(ctx, c.name, c.line, c.column):
                    ctx.value_types.set(c.name, resolve_type(ctx, c.const_type))
                    let val = c.value else:
                        i += 1
                        continue
                    ctx.const_values.set(c.name, val)
            ast.Decl.decl_function as fun:
                if declare_value(ctx, fun.name, fun.line, fun.column):
                    ctx.functions.set(fun.name, build_fn_sig(ctx, fun.name, fun.method_params, fun.return_type, ast.MethodKind.mk_plain, fun.is_async))
            _:
                pass
        i += 1


## Register the prelude types (Option[T], Result[T,E]) so their variant arms
## are match-exhaustive, their arm constructors (Option.some(...)) are validated,
## and common methods (is_some, unwrap, etc.) pass the member-existence check.
## Runs after declare_named_types so user-declared types of the same name take
## priority (the prelude never overrides a local declaration).
function install_prelude_types(ctx: ref[Context]) -> void:
    register_builtin_types(ctx)
    # Prelude imports: ensure std.option and std.result are tracked as import
    # aliases so classifier_identifier can map Option/Result to TOKEN_NAMESPACE.
    if not ctx.import_aliases.contains("std.option"):
        ctx.import_aliases.set("std.option", "std.option")
    if not ctx.import_aliases.contains("std.result"):
        ctx.import_aliases.set("std.result", "std.result")
    register_prelude_type(ctx, "Option", "some", "none")
    register_prelude_type(ctx, "Result", "success", "failure")
    merge_prelude_binding_methods(ctx, "std.option")
    merge_prelude_binding_methods(ctx, "std.result")
    register_builtin_event_types(ctx)


function register_builtin_types(ctx: ref[Context]) -> void:
    var i: ptr_uint = 0
    while i < 26:
        let name = BUILTIN_TYPE_NAMES[i]
        if not ctx.type_names.contains(name):
            ctx.types.set(name, types.Type.ty_primitive(name = name))
            ctx.type_names.set(name, true)
        i += 1
    ctx.types.set("struct_handle", types.Type.ty_primitive(name = "struct_handle"))
    ctx.type_names.set("struct_handle", true)
    ctx.types.set("field_handle", types.Type.ty_primitive(name = "field_handle"))
    ctx.type_names.set("field_handle", true)
    ctx.types.set("callable_handle", types.Type.ty_primitive(name = "callable_handle"))
    ctx.type_names.set("callable_handle", true)
    ctx.types.set("attribute_handle", types.Type.ty_primitive(name = "attribute_handle"))
    ctx.type_names.set("attribute_handle", true)
    ctx.types.set("member_handle", types.Type.ty_primitive(name = "member_handle"))
    ctx.type_names.set("member_handle", true)
    ctx.types.set("type", types.Type.ty_primitive(name = "type"))
    ctx.type_names.set("type", true)


const BUILTIN_TYPE_NAMES: array[str, 26] = array[str, 26](
    "bool", "byte", "ubyte", "char", "short", "ushort",
    "int", "uint", "long", "ulong", "ptr_int", "ptr_uint",
    "float", "double", "void", "str", "cstr",
    "vec2", "vec3", "vec4", "ivec2", "ivec3", "ivec4",
    "mat3", "mat4", "quat",
)


## True for the built-in type names the host hides from completion — its
## `INSTALLABLE_BUILTIN_TYPE_NAMES`: the primitives plus the handle types,
## `EventError` and `Subscription`.
public function is_builtin_completion_type(name: str) -> bool:
    var i: ptr_uint = 0
    while i < 26:
        if name.equal(BUILTIN_TYPE_NAMES[i]):
            return true
        i += 1
    return name.equal("struct_handle") or name.equal("field_handle") or
        name.equal("callable_handle") or name.equal("attribute_handle") or
        name.equal("member_handle") or name.equal("type") or
        name.equal("EventError") or name.equal("Subscription")


## Copy the exported member/method keys of a seeded prelude module's binding
## (e.g. `Option.expect` from std.option's `extending Option[T]`) into the
## current module's method-key set.  No-op when the binding is absent
## (single-file checks without a loaded program).
function merge_prelude_binding_methods(ctx: ref[Context], module_name: str) -> void:
    let binding_ptr = lookup_binding(ctx, module_name) else:
        return
    unsafe:
        var keys = read(binding_ptr).member_keys.keys()
        while true:
            let key_ptr = keys.next() else:
                break
            ctx.method_keys.set(read(key_ptr), true)


## Register the built-in event support types: `EventError` (built-in enum with
## the single member `full`) and the opaque `Subscription` handle — mirroring
## Ruby's type_declaration.rb built-in registration.
function register_builtin_event_types(ctx: ref[Context]) -> void:
    if not ctx.type_names.contains("EventError"):
        ctx.types.set("EventError", types.Type.ty_named(module_name = "", name = "EventError"))
        ctx.static_member_types.set("EventError", true)
        ctx.match_case_types.set("EventError", true)
        ctx.method_keys.set(method_key("EventError", "full"), true)
        var members = vec.Vec[str].create()
        members.push("full")
        ctx.match_case_names.set("EventError", members.as_span())
    if not ctx.type_names.contains("Subscription"):
        ctx.types.set("Subscription", types.Type.ty_named(module_name = "", name = "Subscription"))


function register_prelude_type(ctx: ref[Context], name: str, arm_a: str, arm_b: str) -> void:
    if ctx.type_names.contains(name):
        return
    ctx.types.set(name, types.Type.ty_named(module_name = "", name = name))
    ctx.static_member_types.set(name, true)
    ctx.match_case_types.set(name, true)
    ctx.method_keys.set(method_key(name, arm_a), true)
    ctx.method_keys.set(method_key(name, arm_b), true)
    var arms = vec.Vec[str].create()
    arms.push(arm_a)
    arms.push(arm_b)
    ctx.match_case_names.set(name, arms.as_span())
    # Method keys for common prelude methods (existence-only, no type-check).
    # Fallback surface for single-file checks; program builds also merge the
    # real std.option / std.result exports (merge_prelude_binding_methods).
    if arm_a == "some":
        ctx.method_keys.set(method_key(name, "is_some"), true)
        ctx.method_keys.set(method_key(name, "is_none"), true)
        ctx.method_keys.set(method_key(name, "unwrap"), true)
        ctx.method_keys.set(method_key(name, "expect"), true)
        ctx.method_keys.set(method_key(name, "unwrap_or"), true)
        ctx.method_keys.set(method_key(name, "unwrap_or_else"), true)
        ctx.method_keys.set(method_key(name, "ok"), true)
        # Typed: is_some() -> bool, is_none() -> bool.
        let bool_ty = types.primitive("bool")
        ctx.method_sigs.set(method_key(name, "is_some"), fn_sig_no_params(name, "is_some", bool_ty))
        ctx.method_sigs.set(method_key(name, "is_none"), fn_sig_no_params(name, "is_none", bool_ty))
    else if arm_a == "success":
        ctx.method_keys.set(method_key(name, "is_success"), true)
        ctx.method_keys.set(method_key(name, "is_failure"), true)
        ctx.method_keys.set(method_key(name, "unwrap"), true)
        ctx.method_keys.set(method_key(name, "expect"), true)
        ctx.method_keys.set(method_key(name, "unwrap_error"), true)
        ctx.method_keys.set(method_key(name, "expect_error"), true)
        ctx.method_keys.set(method_key(name, "unwrap_or"), true)
        ctx.method_keys.set(method_key(name, "unwrap_or_else"), true)
        ctx.method_keys.set(method_key(name, "ok"), true)
        ctx.method_keys.set(method_key(name, "error"), true)
        ctx.method_keys.set(method_key(name, "map_error"), true)
        let bool_ty = types.primitive("bool")
        ctx.method_sigs.set(method_key(name, "is_success"), fn_sig_no_params(name, "is_success", bool_ty))
        ctx.method_sigs.set(method_key(name, "is_failure"), fn_sig_no_params(name, "is_failure", bool_ty))


## Register built-in event methods (emit, subscribe, subscribe_once,
## unsubscribe) for each event type declared in the module.  Runs after
## declare_named_types so event types are populated.
function register_event_methods(ctx: ref[Context]) -> void:
    let bool_ty = types.primitive("bool")
    var entries = ctx.event_types.entries()
    while true:
        if not entries.next():
            break
        unsafe:
            let key = read(entries.current().key)
            ctx.method_keys.set(method_key(key, "emit"), true)
            ctx.method_keys.set(method_key(key, "subscribe"), true)
            ctx.method_keys.set(method_key(key, "subscribe_once"), true)
            ctx.method_keys.set(method_key(key, "unsubscribe"), true)


function fn_sig_no_params(type_name: str, method_name: str, return_type: types.Type) -> FnSig:
    return FnSig(name = method_name, params = span[ParamEntry](), return_type = return_type, has_return_type = true, method_kind = ast.MethodKind.mk_plain, is_async = false, is_variadic = false, is_extern = false, required_count = 0)


function check_attribute_applications(ctx: ref[Context], file: ast.SourceFile) -> void:
    var i: ptr_uint = 0
    while i < file.declarations.len:
        var d: ast.Decl
        unsafe:
            d = read(file.declarations.data + i)
        match d:
            ast.Decl.decl_struct as s:
                check_attr_span(ctx, s.struct_attrs, "struct", s.line, s.column)
                record_attr_apps(ctx, s.name, s.struct_attrs)
                record_field_attr_apps(ctx, s.name, s.struct_fields)
            ast.Decl.decl_function as f:
                check_attr_span(ctx, f.attributes, "function", f.line, f.column)
                record_attr_apps(ctx, f.name, f.attributes)
            ast.Decl.decl_const as c:
                check_attr_span(ctx, c.attributes, "const", c.line, c.column)
                record_attr_apps(ctx, c.name, c.attributes)
            ast.Decl.decl_enum as e:
                check_attr_span(ctx, e.enum_attrs, "enum", e.line, e.column)
                record_attr_apps(ctx, e.name, e.enum_attrs)
            ast.Decl.decl_flags as fl:
                check_attr_span(ctx, fl.flags_attrs, "flags", fl.line, fl.column)
                record_attr_apps(ctx, fl.name, fl.flags_attrs)
            ast.Decl.decl_union as u:
                check_attr_span(ctx, u.union_attrs, "union", u.line, u.column)
                record_attr_apps(ctx, u.name, u.union_attrs)
            ast.Decl.decl_variant as vr:
                check_attr_span(ctx, vr.variant_attrs, "variant", vr.line, vr.column)
                record_attr_apps(ctx, vr.name, vr.variant_attrs)
            ast.Decl.decl_event as ev:
                check_attr_span(ctx, ev.attrs, "event", ev.line, ev.column)
                record_attr_apps(ctx, ev.name, ev.attrs)
            _:
                pass
        i += 1


function check_attr_span(ctx: ref[Context], attrs: span[ast.AttributeApplication], target: str, line: ptr_uint, column: ptr_uint) -> void:
    var i: ptr_uint = 0
    while i < attrs.len:
        var a: ast.AttributeApplication
        unsafe:
            a = read(attrs.data + i)
        if a.name.parts.len == 1:
            let attr_name = unsafe: read(a.name.parts.data + 0)
            if not is_valid_attr_target(attr_name, target):
                report(ctx, line, column, attr_target_message(attr_name, target))
        i += 1


## Record each field's attribute applications under the `Type.field` key, so
## `attributes_of(field_of(Type, field))` reflects the declaring field's
## attributes (mirrors the host's `resolved_attribute_applications_for_target`).
function record_field_attr_apps(ctx: ref[Context], type_name: str, fields: span[ast.Field]) -> void:
    var i: ptr_uint = 0
    while i < fields.len:
        var f: ast.Field
        unsafe:
            f = read(fields.data + i)
        if f.attributes.len > 0:
            var key_buf = string.String.create()
            key_buf.append(type_name)
            key_buf.append(".")
            key_buf.append(f.name)
            let key = key_buf.as_str()
            let existing_ptr = ctx.field_attribute_apps.get(key)
            var v = vec.Vec[ast.AttributeApplication].create()
            if existing_ptr != null:
                unsafe:
                    v = read(existing_ptr)
            var ai: ptr_uint = 0
            while ai < f.attributes.len:
                unsafe:
                    v.push(read(f.attributes.data + ai))
                ai += 1
            ctx.field_attribute_apps.set(key, v)
        i += 1


function record_attr_apps(ctx: ref[Context], name: str, attrs: span[ast.AttributeApplication]) -> void:
    var existing_ptr = ctx.attribute_apps.get(name)
    if existing_ptr == null:
        var v = vec.Vec[ast.AttributeApplication].create()
        var ai: ptr_uint = 0
        while ai < attrs.len:
            unsafe:
                v.push(read(attrs.data + ai))
            ai += 1
        ctx.attribute_apps.set(name, v)
    else:
        unsafe:
            var v = read(existing_ptr)
            var ai: ptr_uint = 0
            while ai < attrs.len:
                v.push(read(attrs.data + ai))
                ai += 1
            ctx.attribute_apps.set(name, v)


## Attributes the compiler itself defines, valid wherever a declared attribute
## name is (e.g. as a `has_attribute(...)` reflection argument).  Mirrors the
## host's `BUILTIN_ATTRIBUTE_NAMES`.
function is_builtin_attribute_name(name: str) -> bool:
    return name == "packed" or name == "align" or name == "deprecated" or name == "test" or name == "expect_fatal"


function is_valid_attr_target(attr_name: str, target: str) -> bool:
    if attr_name == "packed" or attr_name == "align":
        return target == "struct"
    if attr_name == "deprecated":
        return target == "function" or target == "struct" or target == "const" or target == "enum" or target == "flags" or target == "union" or target == "variant" or target == "event"
    if attr_name == "test" or attr_name == "expect_fatal":
        return target == "function"
    return true


function attr_target_message(attr_name: str, target: str) -> str:
    var buf = string.String.create()
    buf.append("attribute @[")
    buf.append(attr_name)
    buf.append("] is not valid on ")
    buf.append(target)
    buf.append(" declarations")
    return buf.as_str()


function build_attr_app_spans(ctx: ref[Context]) -> map_mod.Map[str, span[ast.AttributeApplication]]:
    var result = map_mod.Map[str, span[ast.AttributeApplication]].create()
    var entries = ctx.attribute_apps.entries()
    while true:
        if not entries.next():
            break
        unsafe:
            let key = read(entries.current().key)
            let vec_ptr = read(entries.current().value)
            result.set(key, vec_ptr.as_span())
    return result


function build_field_attr_app_spans(ctx: ref[Context]) -> map_mod.Map[str, span[ast.AttributeApplication]]:
    var result = map_mod.Map[str, span[ast.AttributeApplication]].create()
    var entries = ctx.field_attribute_apps.entries()
    while true:
        if not entries.next():
            break
        unsafe:
            let key = read(entries.current().key)
            let vec_ptr = read(entries.current().value)
            result.set(key, vec_ptr.as_span())
    return result


function declare_attributes(ctx: ref[Context], file: ast.SourceFile) -> void:
    var i: ptr_uint = 0
    while i < file.declarations.len:
        var d: ast.Decl
        unsafe:
            d = read(file.declarations.data + i)
        match d:
            ast.Decl.decl_attribute as a:
                ctx.declared_attributes.set(a.name, a.targets)
            _:
                pass
        i += 1


## Resolve each struct's declared fields into the type model, after all type
## names and aliases are known so field types resolve correctly.
function collect_struct_fields(ctx: ref[Context], file: ast.SourceFile) -> void:
    var i: ptr_uint = 0
    while i < file.declarations.len:
        var d: ast.Decl
        unsafe:
            d = read(file.declarations.data + i)
        match d:
            ast.Decl.decl_struct as s:
                # A generic struct's fields reference its type parameters
                # (`data: own[T]?`); register them as type variables so nested
                # references like `Vec[Node[Context]]` keep their arguments and
                # can be substituted during monomorphization.
                enter_type_params(ctx, s.type_params)
                ctx.structs.set(s.name, resolve_field_entries_with_events(ctx, s.struct_fields, s.struct_events))
                collect_nested_struct_fields(ctx, s.nested_types, s.name)
                ctx.type_params.clear()
                ctx.suppressed_type_names.clear()
            ast.Decl.decl_union as u:
                # Union members are read like struct fields (`ev.type`), so the
                # analyzer needs their types for member checks.
                ctx.unions.set(u.name, resolve_field_entries(ctx, u.union_fields))
            _:
                pass
        i += 1


function collect_nested_struct_fields(ctx: ref[Context], nested: span[ast.Decl], parent_name: str) -> void:
    var i: ptr_uint = 0
    while i < nested.len:
        var d: ast.Decl
        unsafe:
            d = read(nested.data + i)
        match d:
            ast.Decl.decl_struct as s:
                var qualified = string.String.create()
                qualified.append(parent_name)
                qualified.append(".")
                qualified.append(s.name)
                let qname = qualified.as_str()
                ctx.structs.set(qname, resolve_field_entries_with_events(ctx, s.struct_fields, s.struct_events))
                if not ctx.structs.contains(s.name):
                    ctx.structs.set(s.name, resolve_field_entries_with_events(ctx, s.struct_fields, s.struct_events))
                collect_nested_struct_fields(ctx, s.nested_types, qname)
            _:
                pass
        i += 1


function resolve_field_entries(ctx: ref[Context], fields: span[ast.Field]) -> span[FieldEntry]:
    var entries = vec.Vec[FieldEntry].create()
    var i: ptr_uint = 0
    while i < fields.len:
        var f: ast.Field
        unsafe:
            f = read(fields.data + i)
        entries.push(FieldEntry(name = f.name, ty = resolve_type_value(ctx, f.field_type)))
        i += 1
    return entries.as_span()


## Combine regular field entries with event fields from struct_events into a
## single span, so the analyzer sees event fields as valid struct members.
function resolve_field_entries_with_events(ctx: ref[Context], fields: span[ast.Field], struct_events: span[ast.Decl]) -> span[FieldEntry]:
    var entries = resolve_field_entries(ctx, fields)
    var result = vec.Vec[FieldEntry].create()
    var i: ptr_uint = 0
    while i < entries.len:
        unsafe:
            result.push(read(entries.data + i))
        i += 1
    var evi: ptr_uint = 0
    while evi < struct_events.len:
        unsafe:
            match read(struct_events.data + evi):
                ast.Decl.decl_event as ev:
                    result.push(FieldEntry(name = ev.name, ty = types.Type.ty_named(module_name = "", name = ev.name)))
                _:
                    pass
        evi += 1
    return result.as_span()


## The canonical name an `extending` block attaches to.  A receiver resolves
## through its import alias and the target module's type-alias chain
## (`extending b3.Vec3:` — with `type Vec3 = c.b3Vec3` in std.box3d — is a method
## on the C struct `b3Vec3`), and call sites look methods up by that resolved
## name.  Single-part targets (local types, builtins, local aliases) and
## unresolvable qualifiers keep their literal name.
function canonical_extending_base(ctx: ref[Context], type_name: ptr[ast.TypeRef]) -> str:
    let literal = qname_to_str(unsafe: read(type_name).name)
    let parts = unsafe: read(type_name).name.parts
    if parts.len < 2:
        return literal
    let alias = unsafe: read(parts.data + 0)
    let module_ptr = ctx.import_aliases.get(alias) else:
        return literal
    var target_module = unsafe: read(module_ptr)
    var name = unsafe: read(parts.data + (parts.len - 1))
    var depth: int = 0
    while depth < 10:
        depth += 1
        let binding_ptr = lookup_binding(ctx, target_module) else:
            break
        let resolved_ptr = unsafe: read(binding_ptr).type_alias_types.get(name)
        if resolved_ptr == null:
            break
        var moved = false
        match unsafe: read(resolved_ptr):
            types.Type.ty_imported as im:
                name = im.name
                target_module = im.module_name
                moved = true
            types.Type.ty_named as nn:
                name = nn.name
                target_module = nn.module_name
                moved = true
            _:
                pass
        if not moved:
            break
    return name


## Collect method names from `extending` blocks keyed as "TypeName.method", so
## member/method reads on locally-declared struct instances can distinguish a
## valid method from an unknown member.  A struct and its `extending` blocks
## live in the same module, so within a single file the method set for a local
## struct is complete.
function collect_extending_methods(ctx: ref[Context], file: ast.SourceFile) -> void:
    var i: ptr_uint = 0
    while i < file.declarations.len:
        var d: ast.Decl
        unsafe:
            d = read(file.declarations.data + i)
        match d:
            ast.Decl.decl_extending_block as ex:
                var base: str = ""
                unsafe:
                    base = qname_to_str(read(ex.type_name).name)
                # Alias-qualified targets also register under the resolved type
                # name, which is what a call site's receiver resolves to.
                let canonical = canonical_extending_base(ctx, ex.type_name)
                if canonical != base:
                    ctx.extending_canonical_names.set(base, canonical)
                var j: ptr_uint = 0
                while j < ex.methods.len:
                    var m: ast.Method
                    unsafe:
                        m = read(ex.methods.data + j)
                    let key = method_key(base, m.name)
                    ctx.method_keys.set(key, true)
                    if canonical != base:
                        ctx.method_keys.set(method_key(canonical, m.name), true)
                    enter_suppressed_extending_target(ctx, ex.type_name)
                    enter_type_params(ctx, m.type_params)
                    enter_extending_type_params(ctx, ex.type_name)
                    let sig = build_fn_sig(ctx, m.name, m.method_params, m.return_type, m.method_kind, m.is_async)
                    if m.method_kind != ast.MethodKind.mk_static or not ctx.method_sigs.contains(key):
                        ctx.method_sigs.set(key, sig)
                    if canonical != base:
                        let canonical_key = method_key(canonical, m.name)
                        if not ctx.method_sigs.contains(canonical_key):
                            ctx.method_sigs.set(canonical_key, sig)
                    ctx.type_params.clear()
                    ctx.suppressed_type_names.clear()
                    if m.type_params.len > 0:
                        ctx.method_type_params.set(key, m.type_params)
                    j += 1
            _:
                pass
        i += 1


public function method_key(type_name: str, member: str) -> str:
    var buf = string.String.create()
    buf.append(type_name)
    buf.append(".")
    buf.append(member)
    return buf.as_str()


function has_method(ctx: ref[Context], type_name: str, member: str) -> bool:
    return ctx.method_keys.contains(method_key(type_name, member))


## Register enum/flags members and variant arms as static members (keyed like
## methods) so `Color.red` / `Token.ident(...)` on a type-name receiver can be
## validated.  The type names are tracked as "static-checkable".
function collect_enum_variant_members(ctx: ref[Context], file: ast.SourceFile) -> void:
    var i: ptr_uint = 0
    while i < file.declarations.len:
        var d: ast.Decl
        unsafe:
            d = read(file.declarations.data + i)
        match d:
            ast.Decl.decl_enum as e:
                ctx.static_member_types.set(e.name, true)
                ctx.match_case_types.set(e.name, true)
                ctx.match_case_names.set(e.name, enum_member_names(e.enum_members))
                register_member_names(ctx, e.name, e.enum_members)
            ast.Decl.decl_flags as fl:
                ctx.static_member_types.set(fl.name, true)
                register_member_names(ctx, fl.name, fl.flags_members)
            ast.Decl.decl_variant as vr:
                ctx.static_member_types.set(vr.name, true)
                ctx.match_case_types.set(vr.name, true)
                ctx.match_case_names.set(vr.name, variant_arm_names(vr.variant_arms))
                register_arm_names(ctx, vr.name, vr.variant_arms)
            _:
                pass
        i += 1
    # Import enum/variant member names from bindings so cross-module match
    # scrutinees of imported enums/variants get exhaustiveness checks.
    let imported = ctx.imported_modules else:
        return
    unsafe:
        var bindings = read(imported).values()
        while true:
            let binding_ptr = bindings.next() else:
                return
            var case_entries = read(binding_ptr).match_case_names.entries()
            while true:
                if not case_entries.next():
                    break
                let entry = case_entries.current()
                if not ctx.match_case_names.contains(read(entry.key)):
                    ctx.match_case_names.set(read(entry.key), read(entry.value))
                if not ctx.match_case_types.contains(read(entry.key)):
                    ctx.match_case_types.set(read(entry.key), true)


function register_member_names(ctx: ref[Context], type_name: str, members: span[ast.EnumMember]) -> void:
    var i: ptr_uint = 0
    while i < members.len:
        unsafe:
            ctx.method_keys.set(method_key(type_name, read(members.data + i).name), true)
        i += 1


function enum_member_names(members: span[ast.EnumMember]) -> span[str]:
    var names = vec.Vec[str].create()
    var i: ptr_uint = 0
    while i < members.len:
        unsafe:
            names.push(read(members.data + i).name)
        i += 1
    return names.as_span()


function variant_arm_names(arms: span[ast.VariantArm]) -> span[str]:
    var names = vec.Vec[str].create()
    var i: ptr_uint = 0
    while i < arms.len:
        unsafe:
            names.push(read(arms.data + i).name)
        i += 1
    return names.as_span()


function register_arm_names(ctx: ref[Context], type_name: str, arms: span[ast.VariantArm]) -> void:
    var i: ptr_uint = 0
    while i < arms.len:
        unsafe:
            ctx.method_keys.set(method_key(type_name, read(arms.data + i).name), true)
        i += 1


function declare_values_and_functions(ctx: ref[Context], file: ast.SourceFile) -> void:
    var i: ptr_uint = 0
    while i < file.declarations.len:
        var d: ast.Decl
        unsafe:
            d = read(file.declarations.data + i)
        match d:
            ast.Decl.decl_const as c:
                if declare_value(ctx, c.name, c.line, c.column):
                    ctx.value_types.set(c.name, resolve_type(ctx, c.const_type))
                    match evaluate_const_expr(ctx, c.value):
                        Option.some:
                            let val = c.value else:
                                i += 1
                                continue
                            ctx.const_values.set(c.name, val)
                        Option.none:
                            pass
            ast.Decl.decl_var as v:
                if declare_value(ctx, v.name, v.line, v.column):
                    let vt = v.var_type
                    if vt != null:
                        ctx.value_types.set(v.name, resolve_type(ctx, vt))
            ast.Decl.decl_function as fun:
                if declare_value(ctx, fun.name, fun.line, fun.column):
                    # Build the signature with the function's own type parameters
                    # in scope, so parameter/return patterns carry ty_var(T) for
                    # call-site unification. Record the constraints for validation.
                    enter_type_params(ctx, fun.type_params)
                    ctx.functions.set(fun.name, build_fn_sig(ctx, fun.name, fun.method_params, fun.return_type, ast.MethodKind.mk_plain, fun.is_async))
                    ctx.type_params.clear()
                    ctx.suppressed_type_names.clear()
                    if fun.type_params.len > 0:
                        ctx.function_type_params.set(fun.name, fun.type_params)
            ast.Decl.decl_extern_function as ef:
                enter_suppressed_type_params(ctx, ef.type_params)
                var extern_ret = types.primitive("void")
                let er_ptr = ef.return_type
                if er_ptr != null:
                    extern_ret = resolve_type(ctx, er_ptr)
                let sig = build_foreign_fn_sig(ctx, ef.name, ef.extern_params, extern_ret)
                ctx.suppressed_type_names.clear()
                ctx.functions.set(ef.name, sig)
                declare_value(ctx, ef.name, ef.line, 1)
            ast.Decl.decl_foreign_function as ff:
                enter_suppressed_type_params(ctx, ff.type_params)
                let sig = build_foreign_fn_sig(ctx, ff.name, ff.foreign_params, resolve_type(ctx, ff.return_type))
                ctx.suppressed_type_names.clear()
                ctx.functions.set(ff.name, sig)
                declare_value(ctx, ff.name, ff.line, 1)
            ast.Decl.decl_event as ev:
                if declare_value(ctx, ev.name, ev.line, ev.column):
                    ctx.value_types.set(ev.name, types.Type.ty_named(module_name = "", name = ev.name))
            ast.Decl.decl_struct as s:
                # Register struct events as values so they can be referenced
                # in expressions like `window.closed.emit()`.  Also recurse
                # into nested structs.
                declare_struct_event_values(ctx, s.struct_events, s.nested_types)
            _:
                pass
        i += 1


## Register struct-level events as value names, recursing into nested structs
## (e.g. `Container.Inner.updated`).
function declare_struct_event_values(ctx: ref[Context], struct_events: span[ast.Decl], nested_types: span[ast.Decl]) -> void:
    var evi: ptr_uint = 0
    while evi < struct_events.len:
        unsafe:
            match read(struct_events.data + evi):
                ast.Decl.decl_event as ev:
                    if not ctx.value_names.contains(ev.name):
                        ctx.value_names.set(ev.name, true)
                _:
                    pass
        evi += 1
    var ni: ptr_uint = 0
    while ni < nested_types.len:
        unsafe:
            match read(nested_types.data + ni):
                ast.Decl.decl_struct as ns:
                    declare_struct_event_values(ctx, ns.struct_events, ns.nested_types)
                _:
                    pass
        ni += 1


function declare_value(ctx: ref[Context], name: str, line: ptr_uint, column: ptr_uint) -> bool:
    if ctx.value_names.contains(name):
        report(ctx, line, column, dup_message("value", name))
        return false
    ctx.value_names.set(name, true)
    return true


function dup_message(kind: str, name: str) -> str:
    var buf = string.String.create()
    buf.append("duplicate ")
    buf.append(kind)
    buf.append(" ")
    buf.append(name)
    return buf.as_str()


## Build a FnSig for a foreign or external function declaration.  Resolves
## each ForeignParam.param_type through the same resolution pipeline that
## `build_fn_sig` uses for ordinary Params.  The return type is resolved at the
## call site and passed in already, because the two declarations have different
## return_type pointer types (`ptr[TypeRef]?` vs `ptr[TypeRef]`).
function build_foreign_fn_sig(ctx: ref[Context], name: str, params: span[ast.ForeignParam], ret: types.Type) -> FnSig:
    var param_entries = vec.Vec[ParamEntry].create()
    var i: ptr_uint = 0
    while i < params.len:
        var p: ast.ForeignParam
        unsafe:
            p = read(params.data + i)
        param_entries.push(ParamEntry(name = p.name, ty = resolve_type_value(ctx, p.param_type)))
        i += 1
    return FnSig(name = name, params = param_entries.as_span(),
        return_type = ret, has_return_type = true,
        method_kind = ast.MethodKind.mk_plain, is_async = false,
        is_variadic = true, is_extern = true, required_count = param_entries.len())


function build_fn_sig(ctx: ref[Context], name: str, params: span[ast.Param], return_type: ptr[ast.TypeRef]?, method_kind: ast.MethodKind, is_async: bool) -> FnSig:
    var param_entries = vec.Vec[ParamEntry].create()
    var required_count: ptr_uint = 0
    var seen_default = false
    var i: ptr_uint = 0
    while i < params.len:
        var p: ast.Param
        unsafe:
            p = read(params.data + i)
            if p.default_value != null:
                seen_default = true
            else if not seen_default:
                required_count += 1
        param_entries.push(ParamEntry(name = p.name, ty = resolve_type_value(ctx, p.param_type)))
        i += 1
    let rt = return_type
    var final_ret = types.primitive("void")
    if rt != null:
        final_ret = resolve_type(ctx, rt)
        if is_async:
            final_ret = make_task_type(final_ret)
        return FnSig(name = name, params = param_entries.as_span(),
            return_type = final_ret, has_return_type = true, method_kind = method_kind, is_async = is_async,
            is_variadic = false, is_extern = false, required_count = required_count)
    if is_async:
        final_ret = make_task_type(final_ret)
    return FnSig(name = name, params = param_entries.as_span(),
        return_type = final_ret, has_return_type = false, method_kind = method_kind, is_async = is_async,
        is_variadic = false, is_extern = false, required_count = required_count)


# =============================================================================
#  Type resolution — ast.TypeRef -> types.Type (mirrors resolve_type)
# =============================================================================

function resolve_type(ctx: ref[Context], tref: ptr[ast.TypeRef]) -> types.Type:
    unsafe:
        return resolve_type_at(ctx, read(tref), 0)


function resolve_type_value(ctx: ref[Context], t: ast.TypeRef) -> types.Type:
    return resolve_type_at(ctx, t, 0)


## `depth` guards against cyclic type aliases (`type A = B; type B = A`).
function resolve_type_at(ctx: ref[Context], t: ast.TypeRef, depth: int) -> types.Type:
    if depth > 200:
        return types.Type.ty_error
    if t.is_fn or t.is_proc:
        var param_types = vec.Vec[types.Type].create()
        var param_names = vec.Vec[str].create()
        var i: ptr_uint = 0
        while i < t.fn_params.len:
            var p: ast.Param
            unsafe:
                p = read(t.fn_params.data + i)
            param_types.push(resolve_type_at(ctx, p.param_type, depth + 1))
            param_names.push(p.name)
            i += 1
        var ret = types.primitive("void")
        let fr = t.fn_return
        if fr != null:
            unsafe:
                ret = resolve_type_at(ctx, read(fr), depth + 1)
        let base = types.Type.ty_function(params = param_types.as_span(), return_type = types.alloc_type(ret), variadic = false, is_proc = t.is_proc, param_names = param_names.as_span())
        return wrap_nullable(base, t.nullable)

    if t.is_dyn:
        return wrap_nullable(types.Type.ty_named(module_name = "", name = "dyn"), t.nullable)

    if t.is_tuple:
        var elems = vec.Vec[types.Type].create()
        var ti: ptr_uint = 0
        while ti < t.arguments.len:
            unsafe:
                elems.push(resolve_type(ctx, t.arguments.data + ti))
            ti += 1
        return types.Type.ty_tuple(elements = elems.as_span(), field_names = Option[span[str]].none)

    # An `alias.Type` naming a type exported by an imported module resolves to a
    # concrete imported type (so its members are checkable); otherwise fall back
    # to the permissive named/error resolution.
    match resolve_imported_type(ctx, t.name):
        Option.some as imported:
            return wrap_nullable(imported_type_with_args(ctx, imported.value, t.arguments, depth), t.nullable)
        Option.none:
            pass

    let name = qname_to_str(t.name)
    let base = resolve_named(ctx, name, t.arguments, t.lifetime, depth, t.line, t.column)
    return wrap_nullable(base, t.nullable)


## An `alias.Type` type reference resolving to an imported struct, enum/variant,
## or interface exported by the aliased module.  None for anything else.
function resolve_imported_type(ctx: ref[Context], name: ast.QualifiedName) -> Option[types.Type]:
    if name.parts.len != 2:
        return Option[types.Type].none
    var alias: str = ""
    var type_name: str = ""
    unsafe:
        alias = read(name.parts.data + 0)
        type_name = read(name.parts.data + 1)
    let module_name_ptr = ctx.import_aliases.get(alias) else:
        return Option[types.Type].none
    let binding_ptr = lookup_binding(ctx, unsafe: read(module_name_ptr)) else:
        return Option[types.Type].none
    unsafe:
        let binding = read(binding_ptr)
        if binding.type_alias_types.contains(type_name):
            var val_ptr = binding.type_alias_types.get(type_name)
            if val_ptr != null:
                return Option[types.Type].some(value = unsafe: read(ptr[types.Type]<-val_ptr))
        if binding.structs.contains(type_name) or binding.type_aliases.contains(type_name) or binding.static_member_types.contains(type_name) or binding.interfaces.contains(type_name) or binding.types.contains(type_name):
            return Option[types.Type].some(value = types.Type.ty_imported(module_name = read(module_name_ptr), name = type_name, args = span[types.Type]()))
    return Option[types.Type].none


## Wrap a resolved imported type with concrete type arguments from the TypeRef.
## When the type arguments are empty, the imported type is returned unchanged.
function imported_type_with_args(ctx: ref[Context], imported: types.Type, arguments: span[ast.TypeRef], depth: int) -> types.Type:
    if arguments.len == 0:
        return imported
    match imported:
        types.Type.ty_imported as im:
            var resolved_args = vec.Vec[types.Type].create()
            var i: ptr_uint = 0
            while i < arguments.len:
                var a: ast.TypeRef
                unsafe:
                    a = read(arguments.data + i)
                resolved_args.push(resolve_type_at(ctx, a, depth + 1))
                i += 1
            return types.Type.ty_imported(module_name = im.module_name, name = im.name, args = resolved_args.as_span())
        _:
            return imported


function wrap_nullable(base: types.Type, nullable: bool) -> types.Type:
    if nullable:
        return types.Type.ty_nullable(base = types.alloc_type(base))
    return base


function resolve_named(ctx: ref[Context], name: str, arguments: span[ast.TypeRef], lifetime: Option[str], depth: int, line: ptr_uint, column: ptr_uint) -> types.Type:
    # An in-scope generic type parameter is a type variable, carrying whatever
    # `implements` constraints its declaration gave it.
    if ctx.type_params.contains(name):
        return types.Type.ty_var(name = name)
    # Type aliases resolve to their (transitively resolved) target.
    if ctx.type_aliases.contains(name):
        return resolve_alias(ctx, name, depth)
    if name == "str":
        return types.Type.ty_str
    if is_primitive_type_name(name):
        return types.primitive(name)
    if name == "type":
        return types.Type.ty_type_meta
    if is_generic_constructor_name(name):
        var args = vec.Vec[types.Type].create()
        # The host keeps an explicit lifetime as the first `ref` argument
        # (`ref[@a, T]`); the AST stores the name without its sigil, so add it
        # back here.  Extraction takes the last argument as the referent.
        if name == "ref":
            match lifetime:
                Option.some as lt:
                    var lt_buf = string.String.create()
                    lt_buf.append("@")
                    lt_buf.append(lt.value)
                    args.push(types.Type.ty_lifetime(name = lt_buf.as_str()))
                Option.none:
                    pass
        var i: ptr_uint = 0
        while i < arguments.len:
            var a: ast.TypeRef
            unsafe:
                a = read(arguments.data + i)
            args.push(resolve_type_at(ctx, a, depth + 1))
            i += 1
        return types.Type.ty_generic(name = name, args = args.as_span())
    if ctx.type_names.contains(name):
        # Built-in registered types (e.g. `EventError`, `Subscription`) carry no
        # owning module and must stay unqualified.
        let registered_ptr = ctx.types.get(name)
        if registered_ptr != null:
            let registered = unsafe: read(registered_ptr)
            match registered:
                types.Type.ty_named as rn:
                    if rn.module_name.len == 0 and arguments.len == 0:
                        return registered
                _:
                    pass
        # A local generic struct/variant with explicit arguments keeps them:
        # dropping the arguments would leave an unspecialized name in inferred
        # expression types (`Node[Context]` -> bare `Node`).
        if arguments.len > 0:
            var args = vec.Vec[types.Type].create()
            var ai: ptr_uint = 0
            while ai < arguments.len:
                var a: ast.TypeRef
                unsafe:
                    a = read(arguments.data + ai)
                args.push(resolve_type_at(ctx, a, depth + 1))
                ai += 1
            return types.Type.ty_imported(module_name = ctx.module_name, name = name, args = args.as_span())
        return types.Type.ty_named(module_name = ctx.module_name, name = name)
    # An integer literal in type-argument position (`array[ubyte, 256]`) is
    # resolved directly to a `ty_literal_int` so that the lowering and C
    # backend can recover the correct array size without relying on a
    # follow-up fixup pass (which only existed for expression/statement-level
    # type refs, not struct-field types).
    if is_all_digits(name):
        return types.literal_int(parse_str_int(name))
    # A module-level integer constant in type-argument position (an array or
    # str_buffer length such as `array[bool, WORLD_SIZE]`) folds to its value,
    # so array sizes resolve consistently across the analyzer, lowering, and
    # the C backend's checked-index helpers.
    let cv = ctx.const_values.get(name)
    if cv != null:
        match const_eval_int_expr(ctx, unsafe: read(cv)):
            Option.some as folded:
                return types.literal_int(folded.value)
            Option.none:
                pass
    # A module-qualified constant in type-argument position
    # (`array[b3.BodyId, human.BONE_COUNT]`) folds through the import alias the
    # same way a local constant does.
    match name.find_byte('.'):
        Option.some as dot:
            let alias_name = name.slice(0, dot.value)
            let member_name = name.slice(dot.value + 1, name.len - dot.value - 1)
            let mod_ptr = ctx.import_aliases.get(alias_name)
            if mod_ptr != null:
                let target_module = unsafe: read(mod_ptr)
                let binding_ptr = lookup_binding(ctx, target_module)
                if binding_ptr != null:
                    let value_ptr = unsafe: read(binding_ptr).const_values.get(member_name)
                    if value_ptr != null:
                        match const_eval_int_expr(ctx, unsafe: read(value_ptr)):
                            Option.some as folded:
                                return types.literal_int(folded.value)
                            Option.none:
                                pass
        Option.none:
            pass
    if name.find_byte('.').is_some():
        return types.Type.ty_error
    if ctx.suppressed_type_names.contains(name):
        return types.Type.ty_error
    report(ctx, line, column, unknown_type_message(name))
    return types.Type.ty_error


## Resolve an alias name to a concrete type, memoized.  A temporary error entry
## is installed before recursing so a cyclic alias resolves to the permissive
## error type rather than looping.
function resolve_alias(ctx: ref[Context], name: str, depth: int) -> types.Type:
    let memo = ctx.alias_types.get(name)
    if memo != null:
        unsafe:
            return read(memo)
    let targetp = ctx.type_aliases.get(name) else:
        return types.Type.ty_error
    ctx.alias_types.set(name, types.Type.ty_error)
    var resolved: types.Type = types.Type.ty_error
    unsafe:
        resolved = resolve_type_at(ctx, read(read(targetp)), depth + 1)
    ctx.alias_types.set(name, resolved)
    return resolved


public function qname_to_str(q: ast.QualifiedName) -> str:
    var buf = string.String.create()
    var i: ptr_uint = 0
    while i < q.parts.len:
        if i > 0:
            buf.append(".")
        unsafe:
            buf.append(read(q.parts.data + i))
        i += 1
    return buf.as_str()


function is_primitive_type_name(name: str) -> bool:
    return (
        name == "bool" or name == "byte" or name == "ubyte" or name == "char"
        or name == "short" or name == "ushort" or name == "int" or name == "uint"
        or name == "long" or name == "ulong" or name == "ptr_int" or name == "ptr_uint"
        or name == "float" or name == "double" or name == "void" or name == "cstr"
        or name == "vec2" or name == "vec3" or name == "vec4"
        or name == "ivec2" or name == "ivec3" or name == "ivec4"
        or name == "mat3" or name == "mat4" or name == "quat"
    )


function is_reserved_name(name: str) -> bool:
    return is_primitive_type_name(name) or name == "str"


function is_generic_constructor_name(name: str) -> bool:
    return (
        name == "ptr" or name == "const_ptr" or name == "own" or name == "ref" or name == "span"
        or         name == "array" or name == "str_buffer" or name == "atomic" or name == "Task"
        or name == "Option" or name == "Result" or name == "SoA" or name == "simd"
    )


# =============================================================================
#  Function body checking
# =============================================================================

function check_functions(ctx: ref[Context], file: ast.SourceFile) -> void:
    var i: ptr_uint = 0
    while i < file.declarations.len:
        var d: ast.Decl
        unsafe:
            d = read(file.declarations.data + i)
        match d:
            ast.Decl.decl_function as fun:
                check_function_body(ctx, fun.name, fun.line, fun.type_params, fun.method_params, fun.return_type, fun.body, fun.is_async)
            _:
                pass
        i += 1


## Check the bodies of methods declared in `extending` blocks.  `this` is bound
## to the receiver type (unwrapped, so `this.field` / `this.method()` are
## checked); static methods have no `this`.  Generic/native/imported receivers
## resolve to permissive types, so their member accesses are not flagged.
function check_extending_methods(ctx: ref[Context], file: ast.SourceFile) -> void:
    var i: ptr_uint = 0
    while i < file.declarations.len:
        var d: ast.Decl
        unsafe:
            d = read(file.declarations.data + i)
        match d:
            ast.Decl.decl_extending_block as ex:
                var this_type: types.Type = types.Type.ty_error
                enter_suppressed_extending_target(ctx, ex.type_name)
                unsafe:
                    this_type = resolve_type_value(ctx, read(ex.type_name))
                ctx.suppressed_type_names.clear()
                var j: ptr_uint = 0
                while j < ex.methods.len:
                    var m: ast.Method
                    unsafe:
                        m = read(ex.methods.data + j)
                    enter_extending_type_params(ctx, ex.type_name)
                    check_method_body(ctx, this_type, m, ex.type_name)
                    ctx.type_params.clear()
                    j += 1
            _:
                pass
        i += 1


# =============================================================================
#  Interface conformance — a struct/opaque `implements` list is satisfied when
#  the type provides a method matching each of the interface's required methods.
#  Mirrors Ruby's SemanticAnalyzer interface_conformance pass, scoped to local
#  interfaces (imported interfaces resolve permissively for now).
# =============================================================================

function collect_interfaces(ctx: ref[Context], file: ast.SourceFile) -> void:
    var i: ptr_uint = 0
    while i < file.declarations.len:
        var d: ast.Decl
        unsafe:
            d = read(file.declarations.data + i)
        match d:
            ast.Decl.decl_interface as iface:
                ctx.interfaces.set(iface.name, iface.interface_methods)
            _:
                pass
        i += 1


function check_interface_conformances(ctx: ref[Context], file: ast.SourceFile) -> void:
    var i: ptr_uint = 0
    while i < file.declarations.len:
        var d: ast.Decl
        unsafe:
            d = read(file.declarations.data + i)
        match d:
            ast.Decl.decl_struct as s:
                check_conformance(ctx, s.name, s.impl_list, s.line, s.column)
            ast.Decl.decl_opaque as op:
                check_conformance(ctx, op.name, op.opaque_implements, op.line, op.column)
            _:
                pass
        i += 1


## Verify a type satisfies each interface in its `implements` list.  Interfaces
## that cannot be resolved (unknown, or imported without a binding) are skipped
## permissively.
function check_conformance(ctx: ref[Context], type_name: str, impl_list: span[ast.QualifiedName], line: ptr_uint, column: ptr_uint) -> void:
    var i: ptr_uint = 0
    while i < impl_list.len:
        var iface_qname: ast.QualifiedName
        unsafe:
            iface_qname = read(impl_list.data + i)
        match resolve_interface_methods(ctx, iface_qname):
            Option.some as methods:
                check_conformance_methods(ctx, type_name, qname_to_str(iface_qname), methods.value, line, column)
            Option.none:
                pass
        i += 1


## The required methods of an interface named in an `implements` clause: a local
## interface (`I`) from ctx, or an imported one (`alias.I`) from the alias's
## module binding.  None when it cannot be resolved.
function resolve_interface_methods(ctx: ref[Context], qname: ast.QualifiedName) -> Option[span[ast.InterfaceMethod]]:
    if qname.parts.len == 1:
        let name = unsafe: read(qname.parts.data + 0)
        let methods_ptr = ctx.interfaces.get(name)
        if methods_ptr != null:
            return Option[span[ast.InterfaceMethod]].some(value = unsafe: read(methods_ptr))
        return Option[span[ast.InterfaceMethod]].none
    if qname.parts.len == 2:
        let alias = unsafe: read(qname.parts.data + 0)
        let iface = unsafe: read(qname.parts.data + 1)
        let module_name_ptr = ctx.import_aliases.get(alias) else:
            return Option[span[ast.InterfaceMethod]].none
        let binding_ptr = lookup_binding(ctx, unsafe: read(module_name_ptr)) else:
            return Option[span[ast.InterfaceMethod]].none
        unsafe:
            let methods_ptr = read(binding_ptr).interfaces.get(iface)
            if methods_ptr != null:
                return Option[span[ast.InterfaceMethod]].some(value = read(methods_ptr))
        return Option[span[ast.InterfaceMethod]].none
    return Option[span[ast.InterfaceMethod]].none


function check_conformance_methods(ctx: ref[Context], type_name: str, iface_name: str, methods: span[ast.InterfaceMethod], line: ptr_uint, column: ptr_uint) -> void:
    var i: ptr_uint = 0
    while i < methods.len:
        var m: ast.InterfaceMethod
        unsafe:
            m = read(methods.data + i)
        let actual_ptr = ctx.method_sigs.get(method_key(type_name, m.name))
        if actual_ptr == null:
            report(ctx, line, column, missing_method_message(type_name, iface_name, m.name))
        else:
            enter_suppressed_interface_method(ctx, m)
            let required = build_fn_sig(ctx, m.name, m.method_params, m.return_type, m.method_kind, false)
            ctx.suppressed_type_names.clear()
            unsafe:
                if not sigs_compatible(required, read(actual_ptr)):
                    report(ctx, line, column, method_mismatch_message(type_name, iface_name, m.name))
        i += 1


## Signatures match when arity is equal and no parameter or the return type is a
## definite (scalar-category) mismatch.  Named / generic / error types stay
## permissive, so only concrete mismatches are reported.
function sigs_compatible(required: FnSig, actual: FnSig) -> bool:
    if required.method_kind != actual.method_kind:
        return false
    if required.params.len != actual.params.len:
        return false
    var i: ptr_uint = 0
    while i < required.params.len:
        unsafe:
            let required_param = read(required.params.data + i)
            let actual_param = read(actual.params.data + i)
            if types.definitely_incompatible(required_param.ty, actual_param.ty):
                return false
        i += 1
    return not types.definitely_incompatible(required.return_type, actual.return_type)


function check_extern_and_foreign(ctx: ref[Context], file: ast.SourceFile) -> void:
    var i: ptr_uint = 0
    while i < file.declarations.len:
        var d: ast.Decl
        unsafe:
            d = read(file.declarations.data + i)
        match d:
            ast.Decl.decl_extern_function as ef:
                check_foreign_params(ctx, ef.name, ef.extern_params, ef.type_params)
            ast.Decl.decl_foreign_function as ff:
                check_foreign_params(ctx, ff.name, ff.foreign_params, ff.type_params)
            _:
                pass
        i += 1


function check_foreign_params(ctx: ref[Context], name: str, params: span[ast.ForeignParam], type_params: span[ast.TypeParam]) -> void:
    # A foreign/extern signature may carry value params (`create_temp_file[N]`
    # with `str_buffer[N]`); suppress unknown-type reports for them.
    enter_suppressed_type_params(ctx, type_params)
    var pi: ptr_uint = 0
    while pi < params.len:
        var p: ast.ForeignParam
        unsafe:
            p = read(params.data + pi)
        let pt = resolve_type_value(ctx, p.param_type)
        if types.is_ref_type(pt):
            report(ctx, 0, 0, extern_ref_param_message(name, p.name))
        pi += 1
    ctx.suppressed_type_names.clear()


function extern_ref_param_message(func: str, param: str) -> str:
    var buf = string.String.create()
    buf.append("external function ")
    buf.append(func)
    buf.append(" cannot take ref parameter ")
    buf.append(param)
    return buf.as_str()


function check_top_level_static_asserts(ctx: ref[Context], file: ast.SourceFile) -> void:
    var i: ptr_uint = 0
    while i < file.declarations.len:
        var d: ast.Decl
        unsafe:
            d = read(file.declarations.data + i)
        match d:
            ast.Decl.decl_static_assert as sa:
                let ct = infer_expr_noscope(ctx, sa.condition)
                if types.is_definitely_non_bool(ct):
                    report(ctx, sa.line, 1, "static_assert condition must be bool")
            _:
                pass
        i += 1


function infer_expr_noscope(ctx: ref[Context], ep: ptr[ast.Expr]) -> types.Type:
    var empty_scope = scope_create()
    scope_enter(ref_of(empty_scope))
    let result = infer_expr(ctx, ref_of(empty_scope), ep)
    scope_leave(ref_of(empty_scope))
    return result


## Scope management — now in semantic/scope.mt.

function scope_create() -> sscope.Scope:
    return sscope.scope_create()

function scope_enter(scope: ref[sscope.Scope]) -> void:
    sscope.scope_enter(scope)

function scope_leave(scope: ref[sscope.Scope]) -> void:
    sscope.scope_leave(scope)

function scope_set(scope: ref[sscope.Scope], name: str, ty: types.Type) -> void:
    sscope.scope_set(scope, name, ty)

function scope_get(scope: ref[sscope.Scope], name: str) -> ptr[types.Type]?:
    return sscope.scope_get(scope, name)

function scope_is_let(scope: ref[sscope.Scope], name: str) -> bool:
    return sscope.scope_is_let(scope, name)

function scope_set_let(scope: ref[sscope.Scope], name: str) -> void:
    sscope.scope_set_let(scope, name)


function check_method_body(ctx: ref[Context], this_type: types.Type, m: ast.Method, target_type_name: ptr[ast.TypeRef]) -> void:
    enter_suppressed_extending_target(ctx, target_type_name)
    enter_type_params(ctx, m.type_params)
    var scope = scope_create()
    scope_enter(ref_of(scope))
    if m.method_kind != ast.MethodKind.mk_static:
        scope_set(ref_of(scope), "this", this_type)
    var seen = map_mod.Map[str, bool].create()
    var pi: ptr_uint = 0
    while pi < m.method_params.len:
        var p: ast.Param
        unsafe:
            p = read(m.method_params.data + pi)
        if seen.contains(p.name):
            report(ctx, m.line, m.column, dup_param_message(m.name, p.name))
        seen.set(p.name, true)
        if is_reserved_name(p.name):
            report(ctx, m.line, m.column, reserved_param_message(m.name, p.name))
        scope_set(ref_of(scope), p.name, resolve_type_value(ctx, p.param_type))
        pi += 1
    seen.release()
    var ret = types.primitive("void")
    let rt = m.return_type
    if rt != null:
        ret = resolve_type(ctx, rt)
    ctx.inside_async = m.is_async
    check_stmt(ctx, ref_of(scope), check_flags(ret, false, false, false), m.body)
    ctx.inside_async = false
    check_definite_assignment(ctx, m.method_params, m.body)
    if rt != null and not types.is_void(ret):
        if not terminates_ptr(ctx, m.body):
            report(ctx, m.line, m.column, missing_return_message(m.name))
    ctx.type_params.clear()
    ctx.suppressed_type_names.clear()


function check_function_body(ctx: ref[Context], name: str, line: ptr_uint, type_params: span[ast.TypeParam], params: span[ast.Param], return_type: ptr[ast.TypeRef]?, body: ptr[ast.Stmt]?, is_async: bool) -> void:
    let b = body else:
        return
    enter_type_params(ctx, type_params)
    var scope = scope_create()
    scope_enter(ref_of(scope))
    var seen = map_mod.Map[str, bool].create()
    var pi: ptr_uint = 0
    while pi < params.len:
        var p: ast.Param
        unsafe:
            p = read(params.data + pi)
        if seen.contains(p.name):
            report(ctx, line, 1, dup_param_message(name, p.name))
        seen.set(p.name, true)
        if is_reserved_name(p.name):
            report(ctx, line, 1, reserved_param_message(name, p.name))
        scope_set(ref_of(scope), p.name, resolve_type_value(ctx, p.param_type))
        pi += 1
    seen.release()
    # Generic value params (`[N: int]`) are compile-time integer constants.
    # Bind them as immutable locals so `N == 8` resolves in the body.
    var tpi: ptr_uint = 0
    while tpi < type_params.len:
        var tp: ast.TypeParam
        unsafe:
            tp = read(type_params.data + tpi)
        if tp.is_value:
            let vtype = tp.value_type
            if vtype != null:
                scope_set(ref_of(scope), tp.name, resolve_type_value(ctx, unsafe: read(vtype)))
        tpi += 1
    var ret = types.primitive("void")
    let rt = return_type
    if rt != null:
        ret = resolve_type(ctx, rt)
    ctx.inside_async = is_async
    check_stmt(ctx, ref_of(scope), check_flags(ret, false, false, false), b)
    ctx.inside_async = false
    check_definite_assignment(ctx, params, b)
    if rt != null and not types.is_void(ret):
        if not terminates_ptr(ctx, b):
            report(ctx, line, 1, missing_return_message(name))
    ctx.type_params.clear()
    ctx.suppressed_type_names.clear()


function check_definite_assignment(ctx: ref[Context], params: span[ast.Param], body: ptr[ast.Stmt]) -> void:
    var da_diags = da.check(params, body)
    var di: ptr_uint = 0
    while di < da_diags.len():
        let d = da_diags.get(di) else:
            break
        unsafe:
            let dd = read(d)
            report(ctx, dd.line, dd.column, def_assign_message(dd.name))
        di += 1
    da_diags.release()


## Register a generic body's type parameters so references to them resolve to
## type variables carrying their `implements` constraints.  Value and lifetime
## parameters are not type variables and are skipped.  Cleared after the body.
## Register an extending block's own type parameters (`extending Vec[T]:`) as
## type variables, so the methods declared in it resolve `T` the way a struct
## body does.  The parser keeps them on the target's qualified name.
function enter_extending_type_params(ctx: ref[Context], target: ptr[ast.TypeRef]) -> void:
    var i: ptr_uint = 0
    unsafe:
        let target_ref = read(target)
        while i < target_ref.arguments.len:
            let argument = read(target_ref.arguments.data + i)
            let qname = argument.name
            if qname.parts.len > 0:
                let leaf = read(qname.parts.data + (qname.parts.len - 1))
                if leaf.len > 0:
                    ctx.type_params.set(leaf, span[ast.TypeParamConstraint]())
            i += 1


function enter_type_params(ctx: ref[Context], type_params: span[ast.TypeParam]) -> void:
    var i: ptr_uint = 0
    while i < type_params.len:
        var tp: ast.TypeParam
        unsafe:
            tp = read(type_params.data + i)
        if not tp.is_value and not tp.is_lifetime:
            ctx.type_params.set(tp.name, tp.constraints)
        # Value params (`[N: int]`) are not type variables, but they appear in
        # type-argument position (`array[T, N]`); suppress unknown-type reports
        # for them without turning them into type variables.
        if tp.is_value:
            ctx.suppressed_type_names.set(tp.name, true)
        i += 1


## True when `name` is a decimal integer literal in type-argument position
## (`array[ubyte, 256]`) rather than a type name.
function is_all_digits(name: str) -> bool:
    if name.len == 0:
        return false
    var i: ptr_uint = 0
    while i < name.len:
        let b = name.byte_at(i)
        if b < 48 or b > 57:
            return false
        i += 1
    return true


## Parse an all-digits string to a long integer.  Callers must verify
## `is_all_digits` first — no validation is performed here.
function parse_str_int(name: str) -> long:
    var value: long = 0
    var i: ptr_uint = 0
    while i < name.len:
        let b = name.byte_at(i)
        value = value * 10 + long<-(b - 48)
        i += 1
    return value


## True when `name` looks like a fresh type-parameter identifier (single-part,
## not a primitive/str/generic-constructor/locally-declared type).
function is_type_param_identifier(ctx: ref[Context], name: str) -> bool:
    if name.find_byte('.').is_some():
        return false
    if is_primitive_type_name(name) or name == "str":
        return false
    if is_generic_constructor_name(name):
        return false
    if ctx.type_names.contains(name):
        return false
    return true


## Suppress unknown-type reports for a declaration's own type + value params
## (e.g. a generic struct's `[T]` while resolving its field types).
function enter_suppressed_type_params(ctx: ref[Context], type_params: span[ast.TypeParam]) -> void:
    var i: ptr_uint = 0
    while i < type_params.len:
        var tp: ast.TypeParam
        unsafe:
            tp = read(type_params.data + i)
        if not tp.is_lifetime:
            ctx.suppressed_type_names.set(tp.name, true)
        i += 1


## Suppress reports for the fresh type parameters named by an
## `extending Type[T, ...]` target (`T`, `K`, `V`).  Concrete instantiation
## arguments are left alone.
function enter_suppressed_extending_target(ctx: ref[Context], type_name: ptr[ast.TypeRef]) -> void:
    unsafe:
        let tref = read(type_name)
        var i: ptr_uint = 0
        while i < tref.arguments.len:
            let arg = read(tref.arguments.data + i)
            let arg_name = qname_to_str(arg.name)
            if is_type_param_identifier(ctx, arg_name):
                ctx.suppressed_type_names.set(arg_name, true)
            i += 1


## Suppress reports for type-parameter identifiers a TypeRef mentions, recursing
## into its arguments (`Vec[T]` → `T`, `Map[K, V]` → `K`, `V`).
function register_suppressed_ref_names(ctx: ref[Context], t: ast.TypeRef) -> void:
    let name = qname_to_str(t.name)
    if is_type_param_identifier(ctx, name):
        ctx.suppressed_type_names.set(name, true)
    var i: ptr_uint = 0
    while i < t.arguments.len:
        unsafe:
            register_suppressed_ref_names(ctx, read(t.arguments.data + i))
        i += 1


## Suppress reports for the interface type parameters referenced by an interface
## method's parameter and return types (`convert(x: T) -> U` → `T`, `U`).
function enter_suppressed_interface_method(ctx: ref[Context], m: ast.InterfaceMethod) -> void:
    var pi: ptr_uint = 0
    while pi < m.method_params.len:
        unsafe:
            let p = read(m.method_params.data + pi)
            register_suppressed_ref_names(ctx, p.param_type)
        pi += 1
    let rt = m.return_type
    if rt != null:
        unsafe:
            register_suppressed_ref_names(ctx, read(rt))


function unknown_type_message(name: str) -> str:
    var buf = string.String.create()
    buf.append("unknown type ")
    buf.append(name)
    return buf.as_str()


# =============================================================================
#  Structural termination — does control always leave via a value-return path?
#  Mirrors Ruby's ControlFlow::Termination as used for the missing-return
#  diagnostic: return / fatal(...) / while true / if-with-else / exhaustive
#  when / all-arm match / unsafe block all terminate.
# =============================================================================

function terminates_ptr(ctx: ref[Context], sp: ptr[ast.Stmt]) -> bool:
    unsafe:
        match read(sp):
            ast.Stmt.stmt_ret:
                return true
            ast.Stmt.stmt_block as b:
                return terminates_span(ctx, b.statements)
            ast.Stmt.stmt_if as i:
                let eb = i.else_body
                if eb == null:
                    return false
                if not terminates_body(ctx, eb):
                    return false
                var k: ptr_uint = 0
                while k < i.branches.len:
                    if not terminates_body(ctx, read(i.branches.data + k).body):
                        return false
                    k += 1
                return true
            ast.Stmt.stmt_while as w:
                return is_true_literal(w.condition)
            ast.Stmt.stmt_match as m:
                if m.arms.len == 0:
                    return false
                var k: ptr_uint = 0
                while k < m.arms.len:
                    if not terminates_body(ctx, read(m.arms.data + k).body):
                        return false
                    k += 1
                return true
            ast.Stmt.stmt_when as wn:
                var k: ptr_uint = 0
                while k < wn.branches.len:
                    if not terminates_span(ctx, read(wn.branches.data + k).body):
                        return false
                    k += 1
                let eb = wn.else_body
                if eb != null:
                    return terminates_ptr(ctx, eb)
                return wn.branches.len > 0
            ast.Stmt.stmt_unsafe as u:
                return terminates_body(ctx, u.body)
            ast.Stmt.stmt_expression as e:
                return is_fatal_call(e.expression)
            ast.Stmt.stmt_static_assert as sa:
                # `static_assert(false, ...)` aborts compilation on this path
                # (used to mark unreachable code); a passing assert does not.
                return is_false_literal(sa.condition)
            _:
                return false


function terminates_body(ctx: ref[Context], body: ptr[ast.Stmt]?) -> bool:
    let b = body else:
        return false
    return terminates_ptr(ctx, b)


function terminates_span(ctx: ref[Context], stmts: span[ast.Stmt]) -> bool:
    if stmts.len == 0:
        return false
    unsafe:
        return terminates_ptr(ctx, stmts.data + (stmts.len - 1))


function is_true_literal(ep: ptr[ast.Expr]) -> bool:
    unsafe:
        match read(ep):
            ast.Expr.expr_bool_literal as b:
                return b.value
            _:
                return false


function is_false_literal(ep: ptr[ast.Expr]) -> bool:
    unsafe:
        match read(ep):
            ast.Expr.expr_bool_literal as b:
                return not b.value
            _:
                return false


function is_fatal_call(ep: ptr[ast.Expr]) -> bool:
    unsafe:
        match read(ep):
            ast.Expr.expr_call as call:
                match read(call.callee):
                    ast.Expr.expr_identifier as id:
                        return id.name == "fatal"
                    _:
                        return false
            _:
                return false


## Assignment-site incompatibility check.  Delegates to the full positive
## type-compatibility rule (type_compatibility.mt), negating the result so this
## function continues to return true when types are incompatible.
function incompatible_value(target: types.Type, source_ty: types.Type, source_expr: ptr[ast.Expr]?) -> bool:
    return not compat.types_compatible(target, source_ty, source_expr)


struct CheckFlags:
    ret: types.Type
    inside_loop: bool
    inside_defer: bool
    inside_parallel: bool


function check_flags(ret: types.Type, inside_loop: bool, inside_defer: bool, inside_parallel: bool) -> CheckFlags:
    return CheckFlags(ret = ret, inside_loop = inside_loop, inside_defer = inside_defer, inside_parallel = inside_parallel)


function check_body(ctx: ref[Context], scope: ref[sscope.Scope], chk: CheckFlags, body: ptr[ast.Stmt]?) -> void:
    let b = body else:
        return
    scope_enter(scope)
    check_stmt(ctx, scope, chk, b)
    scope_leave(scope)


## When `narrowed_name` is set, wrap the body check with a scope frame that
## shadows the variable with its non-nullable type.
function apply_narrow_by_name(ctx: ref[Context], scope: ref[sscope.Scope], narrowed_name: Option[str], narrowed_ty: types.Type, chk: CheckFlags, body: ptr[ast.Stmt]?) -> void:
    match narrowed_name:
        Option.some as nnm:
            scope_enter(scope)
            scope_set(scope, nnm.value, narrowed_ty)
            check_body(ctx, scope, chk, body)
            scope_leave(scope)
        Option.none:
            check_body(ctx, scope, chk, body)


function check_stmt(ctx: ref[Context], scope: ref[sscope.Scope], chk: CheckFlags, sp: ptr[ast.Stmt]) -> void:
    unsafe:
        match read(sp):
            ast.Stmt.stmt_block as blk:
                check_stmt_span(ctx, scope, chk, blk.statements)
            ast.Stmt.stmt_ret as r:
                if chk.inside_defer:
                    report(ctx, r.line, r.column, "return is not allowed inside a defer block")
                else if chk.inside_parallel:
                    report(ctx, r.line, r.column, "return is not allowed inside a parallel block")
                let rv = r.value
                if rv != null:
                    if types.is_void(chk.ret):
                        report(ctx, r.line, r.column, "void function may not return a value")
                    let vt = infer_expr(ctx, scope, rv)
                    if incompatible_value(chk.ret, vt, rv):
                        report(ctx, r.line, r.column, return_mismatch_message(chk.ret, vt))
            ast.Stmt.stmt_local as l:
                check_local(ctx, scope, l.is_let, l.name, l.stmt_type, l.value, l.else_body != null, l.destructure_bindings, l.line, l.column)
            ast.Stmt.stmt_if as i:
                var false_refinements = map_mod.Map[str, types.Type].create()
                var post_refinements = map_mod.Map[str, types.Type].create()
                var first_post = true
                var bi2: ptr_uint = 0
                while bi2 < i.branches.len:
                    var br: ast.IfBranch = read(i.branches.data + bi2)
                    check_condition(ctx, scope, br.condition, "if", br.line, br.column)
                    var true_refs = flow_refinements(ctx, br.condition, true, scope)
                    scope_enter(scope)
                    apply_refinements_to_frame(scope, ref_of(true_refs))
                    check_body(ctx, scope, chk, br.body)
                    scope_leave(scope)
                    var false_refs = flow_refinements(ctx, br.condition, false, scope)
                    merge_refinements_into(ref_of(false_refinements), ref_of(false_refs))
                    var branch_keepers = keep_unassigned(true_refs, br.body)
                    intersect_post_refs(ref_of(post_refinements), ref_of(branch_keepers), ref_of(first_post))
                    branch_keepers.release()
                    first_post = false
                    bi2 += 1
                scope_enter(scope)
                apply_refinements_to_frame(scope, ref_of(false_refinements))
                check_body(ctx, scope, chk, i.else_body)
                scope_leave(scope)
                if i.else_body != null:
                    var else_keepers = keep_unassigned(false_refinements, i.else_body)
                    intersect_post_refs(ref_of(post_refinements), ref_of(else_keepers), ref_of(first_post))
                    else_keepers.release()
                apply_refinements_to_scope_frame(scope, ref_of(post_refinements))
                post_refinements.release()
            ast.Stmt.stmt_while as w:
                if w.is_inline:
                    match evaluate_const_expr(ctx, w.condition):
                        Option.none:
                            report(ctx, w.line, w.column, "inline while condition must be a compile-time constant")
                            return
                        Option.some:
                            pass
                check_condition(ctx, scope, w.condition, "while", w.line, w.column)
                check_body(ctx, scope, check_flags(chk.ret, true, chk.inside_defer, chk.inside_parallel), w.body)
            ast.Stmt.stmt_for as fr:
                scope_enter(scope)
                bind_for_names(scope, fr.bindings)
                if fr.threaded:
                    ctx.uses_parallel_for = true
                    check_body(ctx, scope, check_flags(chk.ret, true, chk.inside_defer, true), fr.body)
                else:
                    check_body(ctx, scope, check_flags(chk.ret, true, chk.inside_defer, chk.inside_parallel), fr.body)
                scope_leave(scope)
            ast.Stmt.stmt_match as m:
                var ai: ptr_uint = 0
                while ai < m.arms.len:
                    var arm: ast.MatchArm
                    arm = read(m.arms.data + ai)
                    scope_enter(scope)
                    bind_match_arm_names(scope, arm.binding_name, arm.pattern)
                    check_body(ctx, scope, chk, arm.body)
                    scope_leave(scope)
                    ai += 1
                check_match(ctx, scope, m.scrutinee, m.arms, m.line, m.column)
            ast.Stmt.stmt_unsafe as u:
                ctx.unsafe_depth += 1
                check_body(ctx, scope, chk, u.body)
                ctx.unsafe_depth -= 1
            ast.Stmt.stmt_defer as d:
                if chk.inside_parallel:
                    report(ctx, d.line, d.column, "defer is not allowed inside a parallel block")
                check_body(ctx, scope, check_flags(chk.ret, chk.inside_loop, true, chk.inside_parallel), d.body)
            ast.Stmt.stmt_parallel_block as pb:
                if pb.bodies.len < 2:
                    report(ctx, pb.line, pb.column, "parallel block requires at least two statements")
                check_stmt_span(ctx, scope, check_flags(chk.ret, chk.inside_loop, chk.inside_defer, true), pb.bodies)
            ast.Stmt.stmt_gather:
                pass
            ast.Stmt.stmt_when as w:
                check_when_statement(ctx, scope, chk, w.discriminant, w.branches, w.else_body)
            ast.Stmt.stmt_pass:
                pass
            ast.Stmt.stmt_break as br:
                if chk.inside_parallel:
                    report(ctx, br.line, br.column, "break is not allowed inside a parallel block")
                else if not chk.inside_loop:
                    report(ctx, br.line, br.column, "break must be inside a loop")
            ast.Stmt.stmt_continue as cont:
                if chk.inside_parallel:
                    report(ctx, cont.line, cont.column, "continue is not allowed inside a parallel block")
                else if not chk.inside_loop:
                    report(ctx, cont.line, cont.column, "continue must be inside a loop")
            ast.Stmt.stmt_expression as e:
                let _ignored = infer_expr(ctx, scope, e.expression)
            ast.Stmt.stmt_assignment as a:
                let tt = infer_expr(ctx, scope, a.target)
                let vt = infer_expr(ctx, scope, a.value)
                if a.operator == "=" and incompatible_value(tt, vt, a.value):
                    report(ctx, a.line, a.column, assign_message(tt, vt))
                check_assign_target_immutable(ctx, scope, a.target, a.line, a.column)
            _:
                pass


function check_condition(ctx: ref[Context], scope: ref[sscope.Scope], cond: ptr[ast.Expr], keyword: str, line: ptr_uint, column: ptr_uint) -> void:
    let ct = infer_expr(ctx, scope, cond)
    if types.is_definitely_non_bool(ct):
        report(ctx, line, column, condition_message(keyword, ct))


## Compute the type refinements that flow from a condition being true or false.
## Returns a map of variable names to their narrowed types.  Handles:
##   * `x != null` / `x == null` — null-pointer narrowing
##   * `not cond` — delegates with flipped truthy
##   * `a and b` — merges when truthy, left-only when falsy (short-circuit)
##   * `a or b` — left-only when truthy, merges when falsy (short-circuit)
function flow_refinements(ctx: ref[Context], cond: ptr[ast.Expr], truthy: bool, scope: ref[sscope.Scope]) -> map_mod.Map[str, types.Type]:
    var result = map_mod.Map[str, types.Type].create()
    unsafe:
        match read(cond):
            ast.Expr.expr_unary_op as u:
                if u.operator == "not":
                    return flow_refinements(ctx, u.operand, not truthy, scope)
            ast.Expr.expr_binary_op as b:
                if b.operator == "and":
                    if truthy:
                        var left = flow_refinements(ctx, b.left, true, scope)
                        merge_refinements_into(ref_of(result), ref_of(left))
                        apply_refinements_to_frame(scope, ref_of(left))
                        var right = flow_refinements(ctx, b.right, true, scope)
                        merge_refinements_into(ref_of(result), ref_of(right))
                    else:
                        var left = flow_refinements(ctx, b.left, false, scope)
                        merge_refinements_into(ref_of(result), ref_of(left))
                    return result
                if b.operator == "or":
                    if truthy:
                        var left = flow_refinements(ctx, b.left, true, scope)
                        merge_refinements_into(ref_of(result), ref_of(left))
                    else:
                        var left = flow_refinements(ctx, b.left, false, scope)
                        merge_refinements_into(ref_of(result), ref_of(left))
                        apply_refinements_to_frame(scope, ref_of(left))
                        var right = flow_refinements(ctx, b.right, false, scope)
                        merge_refinements_into(ref_of(result), ref_of(right))
                    return result
                if b.operator == "!=" or b.operator == "==":
                    return null_test_refinements(ctx, cond, truthy, scope)
            _:
                pass
    return result


## Null-test refinements: returns {name -> unwrapped_type} when the condition
## is `name != null` (truthy) or `name == null` (falsy), and the variable has
## a nullable type.
function null_test_refinements(ctx: ref[Context], condp: ptr[ast.Expr], truthy: bool, scope: ref[sscope.Scope]) -> map_mod.Map[str, types.Type]:
    var result = map_mod.Map[str, types.Type].create()

    unsafe:
        match read(condp):
            ast.Expr.expr_binary_op as b:
                var is_negated = false
                if b.operator == "!=":
                    is_negated = true
                else if b.operator == "==":
                    is_negated = false
                else:
                    return result

                var var_name: Option[str] = Option[str].none
                unsafe:
                    match read(b.left):
                        ast.Expr.expr_identifier as id:
                            if read(b.right) is ast.Expr.expr_null_literal:
                                var_name = Option[str].some(value = id.name)
                        _:
                            pass
                    match read(b.right):
                        ast.Expr.expr_identifier as id:
                            if read(b.left) is ast.Expr.expr_null_literal:
                                var_name = Option[str].some(value = id.name)
                        _:
                            pass

                var name_value: str = ""
                var found = false
                match var_name:
                    Option.some as nv:
                        name_value = nv.value
                        found = true
                    Option.none:
                        pass
                if not found:
                    return result

                let narrow = if is_negated: truthy else: not truthy
                if not narrow:
                    return result

                let type_ptr = scope_get(scope, name_value)
                if type_ptr == null:
                    return result

                unsafe:
                    let raw_ty = read(type_ptr)
                    let unwrapped = unwrap_nullable_type(raw_ty)
                    if not types.type_equals(unwrapped, raw_ty):
                        result.set(name_value, unwrapped)
            _:
                pass

    return result


## Copy all entries from `incoming` into `existing`.  When a key is already
## present in both and has a different type, it is removed (ambiguous state).
function merge_refinements_into(existing: ref[map_mod.Map[str, types.Type]], incoming: ref[map_mod.Map[str, types.Type]]) -> void:
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


## Apply refinement bindings to the top scope frame, shadowing any existing
## bindings with the narrowed types.
function apply_refinements_to_frame(scope: ref[sscope.Scope], refinements: ref[map_mod.Map[str, types.Type]]) -> void:
    var entries = refinements.entries()
    while true:
        if not entries.next():
            break
        unsafe:
            let entry = entries.current()
            scope_set(scope, read(entry.key), read(entry.value))


## Apply refinements directly to the current scope frame without entering a new
## one — for post-if refinements that persist beyond the if/else block.
function apply_refinements_to_scope_frame(scope: ref[sscope.Scope], refinements: ref[map_mod.Map[str, types.Type]]) -> void:
    var entries = refinements.entries()
    while true:
        if not entries.next():
            break
        unsafe:
            let entry = entries.current()
            scope_set(scope, read(entry.key), read(entry.value))


## Return the subset of `refinements` whose variable names are NOT assigned
## (via let/var/assignment) within the given statement body.  Variables that
## are reassigned lose their narrowing.
function keep_unassigned(refinements: map_mod.Map[str, types.Type], body_ptr: ptr[ast.Stmt]?) -> map_mod.Map[str, types.Type]:
    var result = map_mod.Map[str, types.Type].create()
    var assigned = collect_assigned_names(body_ptr)
    var entries = refinements.entries()
    while true:
        if not entries.next():
            break
        unsafe:
            let key = read(entries.current().key)
            if not assigned.contains(key):
                result.set(key, read(entries.current().value))
    assigned.release()
    return result


## Collect all variable names that appear as targets of let/var declarations
## or assignments within a statement body.
function collect_assigned_names(body_ptr: ptr[ast.Stmt]?) -> map_mod.Map[str, bool]:
    var result = map_mod.Map[str, bool].create()
    collect_assigned_into(body_ptr, ref_of(result))
    return result


function collect_assigned_into(stmt_ptr: ptr[ast.Stmt]?, names: ref[map_mod.Map[str, bool]]) -> void:
    if stmt_ptr == null:
        return
    unsafe:
        match read(stmt_ptr):
            ast.Stmt.stmt_local as l:
                if not l.name == "_":
                    names.set(l.name, true)
            ast.Stmt.stmt_assignment as a:
                match read(a.target):
                    ast.Expr.expr_identifier as id:
                        if not id.name == "_":
                            names.set(id.name, true)
                    _:
                        pass
            ast.Stmt.stmt_block as b:
                var i: ptr_uint = 0
                while i < b.statements.len:
                    collect_assigned_into(b.statements.data + i, names)
                    i += 1
            ast.Stmt.stmt_if as i:
                var bi: ptr_uint = 0
                while bi < i.branches.len:
                    let br = read(i.branches.data + bi)
                    collect_assigned_into(br.body, names)
                    bi += 1
                collect_assigned_into(i.else_body, names)
            ast.Stmt.stmt_while as w:
                collect_assigned_into(w.body, names)
            ast.Stmt.stmt_for as fr:
                collect_assigned_into(fr.body, names)
            ast.Stmt.stmt_match as m:
                var ai: ptr_uint = 0
                while ai < m.arms.len:
                    let arm = read(m.arms.data + ai)
                    collect_assigned_into(arm.body, names)
                    ai += 1
            ast.Stmt.stmt_defer as d:
                collect_assigned_into(d.body, names)
            ast.Stmt.stmt_unsafe as u:
                collect_assigned_into(u.body, names)
            _:
                pass


## Intersect `branch` into `result`.  When `first` is true, `branch` is the first
## branch and its entries are copied directly.  Otherwise, only entries present
## in both with the same type survive.
function intersect_post_refs(result: ref[map_mod.Map[str, types.Type]], branch: ref[map_mod.Map[str, types.Type]], first: ref[bool]) -> void:
    if read(first):
        var entries = branch.entries()
        while true:
            if not entries.next():
                break
            unsafe:
                result.set(read(entries.current().key), read(entries.current().value))
        read(first) = false
    else:
        var to_remove = vec.Vec[str].create()
        var entries = result.entries()
        while true:
            if not entries.next():
                break
            unsafe:
                let key = read(entries.current().key)
                if not branch.contains(key):
                    to_remove.push(key)
                else:
                    let bv = branch.get(key)
                    if bv != null and not types.type_equals(read(entries.current().value), read(bv)):
                        to_remove.push(key)
        var ri: ptr_uint = 0
        while ri < to_remove.len():
            let kr = to_remove.get(ri) else:
                break
            unsafe:
                let _removed = result.remove(read(kr))
            ri += 1
        to_remove.release()


function check_when_statement(ctx: ref[Context], scope: ref[sscope.Scope], chk: CheckFlags, discriminant: ptr[ast.Expr], branches: span[ast.WhenBranch], else_body: ptr[ast.Stmt]?) -> void:
    match evaluate_when_discriminant(ctx, discriminant, span[ast.Decl]()):
        Option.some as chosen:
            var i: ptr_uint = 0
            while i < branches.len:
                var br: ast.WhenBranch
                unsafe:
                    br = read(branches.data + i)
                match extract_when_member_name(br.pattern):
                    Option.some as nm:
                        if nm.value == chosen.value:
                            check_stmt_span(ctx, scope, chk, br.body)
                            return
                    Option.none:
                        pass
                i += 1
            check_body(ctx, scope, chk, else_body)
        Option.none:
            pass


function check_stmt_span(ctx: ref[Context], scope: ref[sscope.Scope], chk: CheckFlags, stmts: span[ast.Stmt]) -> void:
    var i: ptr_uint = 0
    while i < stmts.len:
        unsafe:
            check_stmt(ctx, scope, chk, stmts.data + i)
        i += 1


## Match validation dispatched on the scrutinee type:
##  * enum/variant   -> exhaustiveness ("missing cases") + duplicate-arm
##  * integer/str    -> requires a wildcard `_` arm + duplicate integer value
##  * anything else  -> permissive
## Enum/variant checks bail out if any arm is not a plain `Type.case` pattern
## (e.g. payload destructuring), so guarded/complex matches never false-positive.
function check_match(ctx: ref[Context], scope: ref[sscope.Scope], scrutinee: ptr[ast.Expr], arms: span[ast.MatchArm], line: ptr_uint, column: ptr_uint) -> void:
    # Infer the scrutinee type WITHOUT recording it (`infer_expr_inner`, not
    # `infer_expr`): this is a diagnostic-only pass and must not mutate the
    # `resolved_expr_types` map that lowering later consumes.
    let scrutinee_ty = infer_expr_inner(ctx, scope, scrutinee)
    if types.is_error(scrutinee_ty):
        return

    # Enum or variant scrutinee: exhaustiveness ("missing cases") plus
    # duplicate-arm checks.  `match_case_names` holds member/arm names for both
    # local and imported enums and variants, keyed by type name.
    match scrutinee_type_name(scrutinee_ty):
        Option.some as nm:
            # An imported type's case names come from its declaring module: a
            # bare name shared with a local type (`Error` from std.raylib vs
            # `pack.Error`) must not pick the wrong member list.
            let owning_module = scrutinee_type_module(scrutinee_ty)
            if match_case_names_for(ctx, owning_module, nm.value) != null:
                check_case_match(ctx, owning_module, nm.value, arms, line, column)
                return
        Option.none:
            pass

    # Integer scrutinee: requires a wildcard `_` arm, plus duplicate-value check.
    # String scrutinee: requires a wildcard `_` arm.  Anything else is permissive.
    match scrutinee_ty:
        types.Type.ty_primitive as p:
            if is_integer_name(p.name):
                check_scalar_match(ctx, arms, line, column, integer_wildcard_message(p.name), true)
        types.Type.ty_str:
            check_scalar_match(ctx, arms, line, column, str_wildcard_message(), false)
        _:
            pass


## The name of a nominal (enum/variant/struct) type, for `match_case_names`
## lookup.  Local types are `ty_named`; imported types are `ty_imported`.
function scrutinee_type_name(t: types.Type) -> Option[str]:
    match t:
        types.Type.ty_named as n:
            return Option[str].some(value = n.name)
        types.Type.ty_imported as im:
            return Option[str].some(value = im.name)
        _:
            return Option[str].none


## The module owning an imported scrutinee type ("" for a local one).
function scrutinee_type_module(t: types.Type) -> str:
    match t:
        types.Type.ty_imported as im:
            return im.module_name
        _:
            return ""


## The member/arm-name table for `type_name` declared in `module_name` ("" =
## the current module), or null when the type has no case table.
function match_case_names_for(ctx: ref[Context], module_name: str, type_name: str) -> ptr[span[str]]?:
    if module_name.len == 0 or module_name == ctx.module_name:
        return ctx.match_case_names.get(type_name)
    let binding_ptr = lookup_binding(ctx, module_name) else:
        return null
    return unsafe: read(binding_ptr).match_case_names.get(type_name)


function check_case_match(ctx: ref[Context], module_name: str, type_name: str, arms: span[ast.MatchArm], line: ptr_uint, column: ptr_uint) -> void:
    let namesp = match_case_names_for(ctx, module_name, type_name) else:
        return
    var covered = vec.Vec[str].create()
    var has_wild = false
    var i: ptr_uint = 0
    while i < arms.len:
        var arm: ast.MatchArm
        unsafe:
            arm = read(arms.data + i)
        let p = arm.pattern
        if p == null:
            has_wild = true
        else:
            match case_name_of(p):
                Option.some as nm:
                    if vec_contains_str(covered, nm.value):
                        report(ctx, line, column, dup_case_message(type_name, nm.value))
                    covered.push(nm.value)
                Option.none:
                    return
        i += 1
    if has_wild:
        return
    unsafe:
        let members = read(namesp)
        # Guard against bare-name type collisions: the self-host has both
        # ast.Stmt/ir.Stmt and ast.Expr/ir.Expr, which share the match_case_names
        # key "Stmt"/"Expr".  If any covered arm is not a member of the
        # looked-up type, the name resolved to a different same-named type, so
        # stay permissive rather than reporting spurious missing cases.
        var ci: ptr_uint = 0
        while ci < covered.len():
            let cn = covered.get(ci) else:
                break
            if not span_contains_str(members, read(cn)):
                return
            ci += 1
        var buf = string.String.create()
        var any_missing = false
        var j: ptr_uint = 0
        while j < members.len:
            let mn = read(members.data + j)
            if not vec_contains_str(covered, mn):
                if any_missing:
                    buf.append(", ")
                buf.append(mn)
                any_missing = true
            j += 1
        if any_missing:
            report(ctx, line, column, missing_cases_message(type_name, buf.as_str()))


## True when `name` is one of the strings in `members`.
function span_contains_str(members: span[str], name: str) -> bool:
    var i: ptr_uint = 0
    while i < members.len:
        if unsafe: read(members.data + i) == name:
            return true
        i += 1
    return false


function check_scalar_match(ctx: ref[Context], arms: span[ast.MatchArm], line: ptr_uint, column: ptr_uint, wildcard_message: str, check_duplicate_int: bool) -> void:
    var has_wild = false
    var seen = vec.Vec[int].create()
    var i: ptr_uint = 0
    while i < arms.len:
        var arm: ast.MatchArm
        unsafe:
            arm = read(arms.data + i)
        let p = arm.pattern
        if p == null:
            has_wild = true
        else if check_duplicate_int:
            match int_literal_value(p):
                Option.some as v:
                    if vec_contains_int(seen, v.value):
                        report(ctx, line, column, dup_value_message(v.value))
                    seen.push(v.value)
                Option.none:
                    pass
        i += 1
    if not has_wild:
        report(ctx, line, column, wildcard_message)


## The case name of a plain `Type.case` (or `Type.case as x`) pattern.  Returns
## none for anything else (payload destructuring, guards, literals), signalling
## the caller to skip exhaustiveness/duplicate checks.
function case_name_of(p: ptr[ast.Expr]) -> Option[str]:
    unsafe:
        match read(p):
            ast.Expr.expr_member_access as ma:
                return Option[str].some(value = ma.member_name)
            _:
                return Option[str].none


function int_literal_value(p: ptr[ast.Expr]) -> Option[int]:
    unsafe:
        match read(p):
            ast.Expr.expr_integer_literal as lit:
                return Option[int].some(value = int<-lit.value)
            ast.Expr.expr_char_literal as ch:
                return Option[int].some(value = int<-ch.value)
            _:
                return Option[int].none


function is_integer_name(name: str) -> bool:
    return types.is_integer_name(name)


const int_suffix_ub: str = "ub"
const int_suffix_us: str = "us"
const int_suffix_ul: str = "ul"
const int_suffix_iz: str = "iz"


function integer_suffix_type_name(lexeme: str) -> Option[str]:
    if lexeme.ends_with(int_suffix_ub):
        return Option[str].some(value = "ubyte")
    if lexeme.ends_with(int_suffix_us):
        return Option[str].some(value = "ushort")
    if lexeme.ends_with(int_suffix_ul):
        return Option[str].some(value = "ulong")
    if lexeme.ends_with(int_suffix_iz):
        return Option[str].some(value = "ptr_int")
    let last = lexeme.byte_at(lexeme.len - 1)
    if last == 'u':
        return Option[str].some(value = "uint")
    if last == 'i':
        return Option[str].some(value = "int")
    if last == 'l':
        return Option[str].some(value = "long")
    if last == 'z':
        return Option[str].some(value = "ptr_uint")
    if last == 's':
        return Option[str].some(value = "short")
    if last == 'b':
        return Option[str].some(value = "byte")
    return Option[str].none


function float_literal_is_double(lexeme: str) -> bool:
    return lexeme.ends_with("d")


function vec_contains_str(v: ref[vec.Vec[str]], s: str) -> bool:
    var i: ptr_uint = 0
    while i < v.len():
        let p = v.get(i) else:
            break
        unsafe:
            if read(p) == s:
                return true
        i += 1
    return false


function vec_contains_int(v: ref[vec.Vec[int]], value: int) -> bool:
    var i: ptr_uint = 0
    while i < v.len():
        let p = v.get(i) else:
            break
        unsafe:
            if read(p) == value:
                return true
        i += 1
    return false


function bind_for_names(scope: ref[sscope.Scope], bindings: span[ast.ForBinding]) -> void:
    var i: ptr_uint = 0
    while i < bindings.len:
        unsafe:
            scope_set(scope, read(bindings.data + i).name, types.Type.ty_error)
        i += 1


## If `t` is a nullable, Option, or Result wrapper, return the unwrapped
## success/payload type (the type the guard binding exposes).  Otherwise t itself.
function unwrap_nullable_type(t: types.Type) -> types.Type:
    match t:
        types.Type.ty_nullable as n:
            return unsafe: read(n.base)
        types.Type.ty_generic as g:
            if (g.name == "Option" or g.name == "Result") and g.args.len >= 1:
                return unsafe: read(g.args.data + 0)
            return t
        _:
            return t


## Flag an assignment whose target is a name bound by `let`, which is immutable.
function check_assign_target_immutable(ctx: ref[Context], scope: ref[sscope.Scope], target: ptr[ast.Expr], line: ptr_uint, column: ptr_uint) -> void:
    unsafe:
        match read(target):
            ast.Expr.expr_identifier as id:
                if scope_is_let(scope, id.name):
                    report(ctx, line, column, assign_to_let_message(id.name))
            _:
                pass


function check_local(ctx: ref[Context], scope: ref[sscope.Scope], is_let: bool, name: str, stmt_type: ptr[ast.TypeRef]?, value: ptr[ast.Expr]?, has_guard: bool, destructure_bindings: Option[span[str]], line: ptr_uint, column: ptr_uint) -> void:
    # Destructuring bindings: bind each destructured name to the permissive
    # error type so later references are not reported as unknown.  Binding to
    # `ty_error` (and not inferring the initializer, as before) keeps recorded
    # types — and thus code generation — identical to the previous behavior.
    match destructure_bindings:
        Option.some as names:
            var di: ptr_uint = 0
            while di < names.value.len:
                unsafe:
                    let dn = read(names.value.data + di)
                    if not dn == "_":
                        scope_set(scope, dn, types.Type.ty_error)
                di += 1
            return
        Option.none:
            pass

    var declared: types.Type = types.Type.ty_error
    var has_declared = false
    let lt = stmt_type
    if lt != null:
        declared = resolve_type(ctx, lt)
        has_declared = true

    var value_type: types.Type = types.Type.ty_error
    var has_value = false
    let val = value
    if val != null:
        value_type = infer_expr(ctx, scope, val)
        has_value = true

    # A guarded let/var (let x = nullable else: ...) unwraps the value type:
    # T?, Option[T], and Result[T,E] all narrow their success type.
    let narrowed = unwrap_nullable_type(value_type)

    # Compatibility: a plain local compares its declared type against the value
    # type directly; a guarded local's annotation names the *success* type, so
    # it is compared against the unwrapped (narrowed) value type instead.
    if has_declared and has_value:
        let compared = if has_guard: narrowed else: value_type
        if incompatible_value(declared, compared, value):
            report(ctx, line, column, local_mismatch_message(declared, compared))

    # Bind the name for later inference: prefer the declared type, but narrow a
    # guard-unwrapped nullable/Option/Result to its success type.
    if has_declared:
        scope_set(scope, name, declared)
    else if has_value:
        if has_guard:
            scope_set(scope, name, narrowed)
        else:
            scope_set(scope, name, value_type)
    else:
        scope_set(scope, name, types.Type.ty_error)

    if is_let:
        scope_set_let(scope, name)

    if is_reserved_name(name):
        report(ctx, line, column, reserved_local_message(name))


# =============================================================================
#  Expression type inference (conservative)
# =============================================================================

function infer_expr(ctx: ref[Context], scope: ref[sscope.Scope], ep: ptr[ast.Expr]) -> types.Type:
    let ty = infer_expr_inner(ctx, scope, ep)
    record_expr_type(ctx, ep, ty)
    return ty


function record_expr_type(ctx: ref[Context], ep: ptr[ast.Expr], ty: types.Type) -> void:
    let key = unsafe: reinterpret[ptr_uint](ep)
    ctx.resolved_expr_types.set(key, ty)


function record_call_kind(ctx: ref[Context], callee: ptr[ast.Expr], kind: str) -> void:
    let key = unsafe: reinterpret[ptr_uint](callee)
    ctx.resolved_call_kinds.set(key, kind)


function call_expr_kind(ctx: ref[Context], callee: ptr[ast.Expr]) -> str:
    unsafe:
        match read(callee):
            ast.Expr.expr_identifier as id:
                if is_builtin_call_name(id.name):
                    return "builtin"
                if ctx.functions.contains(id.name):
                    return "function"
                return "unknown"
            ast.Expr.expr_member_access:
                return "method"
            ast.Expr.expr_specialization as spec:
                return specialization_kind(ctx, spec.callee, spec.arguments)
            _:
                return "unknown"


function specialization_kind(ctx: ref[Context], callee: ptr[ast.Expr], type_args: span[ast.TypeArgument]) -> str:
    unsafe:
        match read(callee):
            ast.Expr.expr_identifier as id:
                if is_hook_name(id.name):
                    return "hook"
                if id.name == "reinterpret":
                    return "reinterpret"
                if id.name == "zero":
                    return "zero"
                if id.name == "adapt":
                    return "adapt"
                if ctx.functions.contains(id.name):
                    return "function"
                return "unknown"
            _:
                return "unknown"


function is_builtin_call_name(name: str) -> bool:
    return (
        name == "read" or name == "ptr_of" or name == "const_ptr_of" or name == "ref_of"
        or name == "size_of" or name == "align_of" or name == "fatal"
    )


## Evaluate a compile-time constant expression.  Returns the type of the
## evaluated value when the expression is a literal, a reference to another
## const, an enum-member access, or a size_of/align_of call.  Returns none for
## anything the self-host cannot evaluate at compile time (runtime-only).
## Evaluate a compile-time integer constant expression (literals, named const
## chains, and arithmetic).  Returns none when the expression is not a
## statically-known integer.  Used to fold a named constant in array-length
## type-argument position (`array[T, WORLD_SIZE]`) to a concrete size, matching
## the Ruby analyzer.
## True for the comparison and logical operators, whose const result type is
## `bool` rather than the operand type.
function is_comparison_or_logical_op(op: str) -> bool:
    return op == "==" or op == "!=" or op == "<" or op == "<=" or op == ">" or op == ">=" or op == "and" or op == "or"


function const_eval_int_expr(ctx: ref[Context], ep: ptr[ast.Expr]) -> Option[long]:
    unsafe:
        match read(ep):
            ast.Expr.expr_integer_literal as lit:
                return Option[long].some(value = long<-lit.value)
            ast.Expr.expr_char_literal as ch:
                return Option[long].some(value = long<-ch.value)
            ast.Expr.expr_identifier as id:
                let chain = ctx.const_values.get(id.name)
                if chain != null:
                    return const_eval_int_expr(ctx, read(chain))
                return Option[long].none
            ast.Expr.expr_unary_op as un:
                let v = const_eval_int_expr(ctx, un.operand) else:
                    return Option[long].none
                if un.operator == "-":
                    return Option[long].some(value = -v)
                if un.operator == "~":
                    return Option[long].some(value = ~v)
                return Option[long].some(value = v)
            ast.Expr.expr_binary_op as bin:
                let l = const_eval_int_expr(ctx, bin.left) else:
                    return Option[long].none
                let r = const_eval_int_expr(ctx, bin.right) else:
                    return Option[long].none
                if bin.operator == "+":
                    return Option[long].some(value = l + r)
                if bin.operator == "-":
                    return Option[long].some(value = l - r)
                if bin.operator == "*":
                    return Option[long].some(value = l * r)
                if bin.operator == "/":
                    if r == 0:
                        return Option[long].none
                    return Option[long].some(value = l / r)
                if bin.operator == "%":
                    if r == 0:
                        return Option[long].none
                    return Option[long].some(value = l % r)
                if bin.operator == "<<":
                    return Option[long].some(value = l << r)
                if bin.operator == ">>":
                    return Option[long].some(value = l >> r)
                if bin.operator == "|":
                    return Option[long].some(value = l | r)
                if bin.operator == "&":
                    return Option[long].some(value = l & r)
                if bin.operator == "^":
                    return Option[long].some(value = l ^ r)
                return Option[long].none
            _:
                return Option[long].none


function evaluate_const_expr(ctx: ref[Context], ep: ptr[ast.Expr]?) -> Option[types.Type]:
    let p = ep else:
        return Option[types.Type].none
    unsafe:
        match read(p):
            ast.Expr.expr_integer_literal:
                return Option[types.Type].some(value = types.primitive("int"))
            ast.Expr.expr_float_literal:
                return Option[types.Type].some(value = types.primitive("float"))
            ast.Expr.expr_bool_literal:
                return Option[types.Type].some(value = types.primitive("bool"))
            ast.Expr.expr_string_literal as s:
                if s.is_cstring:
                    return Option[types.Type].some(value = types.primitive("cstr"))
                return Option[types.Type].some(value = types.Type.ty_str)
            ast.Expr.expr_char_literal:
                return Option[types.Type].some(value = types.primitive("ubyte"))
            ast.Expr.expr_identifier as id:
                let chain = ctx.const_values.get(id.name)
                if chain != null:
                    return evaluate_const_expr(ctx, read(chain))
                return Option[types.Type].none
            ast.Expr.expr_unary_op as un:
                let ut = evaluate_const_expr(ctx, un.operand) else:
                    return Option[types.Type].none
                if un.operator == "not":
                    return Option[types.Type].some(value = types.primitive("bool"))
                return Option[types.Type].some(value = ut)
            ast.Expr.expr_binary_op as bin:
                let lt = evaluate_const_expr(ctx, bin.left) else:
                    return Option[types.Type].none
                let _rt = evaluate_const_expr(ctx, bin.right) else:
                    return Option[types.Type].none
                if is_comparison_or_logical_op(bin.operator):
                    return Option[types.Type].some(value = types.primitive("bool"))
                return Option[types.Type].some(value = lt)
            ast.Expr.expr_member_access as ma:
                return Option[types.Type].some(value = types.Type.ty_error)
            ast.Expr.expr_prefix_cast as c:
                return Option[types.Type].some(value = resolve_type(ctx, c.target_type))
            ast.Expr.expr_call as call:
                match evaluate_const_builtin_call(call.callee):
                    Option.some:
                        return Option[types.Type].some(value = types.primitive("ptr_uint"))
                    Option.none:
                        return Option[types.Type].none
            ast.Expr.expr_null_literal:
                return Option[types.Type].some(value = types.Type.ty_error)
            _:
                return Option[types.Type].none


function evaluate_const_builtin_call(callee: ptr[ast.Expr]) -> Option[bool]:
    unsafe:
        match read(callee):
            ast.Expr.expr_identifier as id:
                if id.name == "size_of" or id.name == "align_of":
                    return Option[bool].some(value = true)
            _:
                pass
    return Option[bool].none


function infer_expr_inner(ctx: ref[Context], scope: ref[sscope.Scope], ep: ptr[ast.Expr]) -> types.Type:
    unsafe:
        match read(ep):
            ast.Expr.expr_integer_literal as lit:
                match integer_suffix_type_name(lit.lexeme):
                    Option.some as st:
                        return types.primitive(st.value)
                    Option.none:
                        return types.primitive("int")
            ast.Expr.expr_float_literal as flit:
                if float_literal_is_double(flit.lexeme):
                    return types.primitive("double")
                return types.primitive("float")
            ast.Expr.expr_bool_literal:
                return types.primitive("bool")
            ast.Expr.expr_string_literal as s:
                if s.is_cstring:
                    return types.primitive("cstr")
                return types.Type.ty_str
            ast.Expr.expr_char_literal:
                return types.primitive("ubyte")
            ast.Expr.expr_identifier as id:
                return infer_identifier(ctx, scope, id.name, id.line, id.column)
            ast.Expr.expr_binary_op as b:
                return infer_binary(ctx, scope, b.operator, b.left, b.right)
            ast.Expr.expr_unary_op as u:
                return infer_unary(ctx, scope, u.operator, u.operand)
            ast.Expr.expr_prefix_cast as c:
                let source = infer_expr(ctx, scope, c.expression)
                let target = resolve_type(ctx, c.target_type)
                if types.is_raw_pointer(target) and ctx.unsafe_depth == 0 and not types.is_raw_pointer(source):
                    report(ctx, c.line, c.column, "pointer cast requires unsafe")
                return target
            ast.Expr.expr_member_access as ma:
                return resolve_member_access(ctx, scope, ma.receiver, ma.member_name, false, ma.line, ma.column)
            ast.Expr.expr_index_access as ix:
                let rt = infer_expr(ctx, scope, ix.receiver)
                let _ix = infer_expr(ctx, scope, ix.index)
                if types.is_raw_pointer(rt) and ctx.unsafe_depth == 0:
                    report(ctx, 0, 0, "pointer indexing requires unsafe")
                # Range slicing: `str[start..stop]` yields `str`;
                # `array[T,N][a..b]` / `span[T][a..b]` yield `span[T]`.
                unsafe:
                    match read(ix.index):
                        ast.Expr.expr_range:
                            if types.type_to_string(rt) == "str":
                                return types.Type.ty_str
                            match rt:
                                types.Type.ty_generic as g:
                                    if g.name == "array" or g.name == "span":
                                        var span_args = vec.Vec[types.Type].create()
                                        span_args.push(types.pointer_element(rt))
                                        return types.Type.ty_generic(name = "span", args = span_args.as_span())
                                _:
                                    pass
                        _:
                            pass
                let elem = types.pointer_element(rt)
                if not types.is_error(elem):
                    return elem
                return types.Type.ty_error
            ast.Expr.expr_unsafe as u:
                ctx.unsafe_depth += 1
                let result = infer_expr(ctx, scope, u.expression)
                ctx.unsafe_depth -= 1
                return result
            ast.Expr.expr_call as call:
                let ty = infer_and_check_call(ctx, scope, call.callee, call.args)
                record_call_kind(ctx, ep, call_expr_kind(ctx, call.callee))
                return ty
            ast.Expr.expr_specialization as spec:
                let ty = check_specialization_call(ctx, scope, spec.callee, spec.arguments, span[types.Type](), span[ast.Argument]())
                record_call_kind(ctx, ep, specialization_kind(ctx, spec.callee, spec.arguments))
                return ty
            ast.Expr.expr_await as aw:
                if not ctx.inside_async:
                    report(ctx, 0, 0, "await is only allowed inside async functions")
                # `await` unwraps the lifted Task type: Task[T] -> T (mirrors
                # Ruby's infer_await returning task_type.result_type).
                let awaited = infer_expr(ctx, scope, aw.expression)
                match awaited:
                    types.Type.ty_generic as task_g:
                        if task_g.name == "Task" and task_g.args.len == 1:
                            return unsafe: read(task_g.args.data + 0)
                    _:
                        pass
                return awaited
            ast.Expr.expr_null_literal as nl:
                let target = nl.target_type
                if target != null:
                    let t = resolve_type(ctx, target)
                    return types.Type.ty_nullable(base = types.alloc_type(t))
                return types.Type.ty_error
            ast.Expr.expr_format_string:
                return types.Type.ty_str
            ast.Expr.expr_proc as pr:
                var param_types = vec.Vec[types.Type].create()
                var pi: ptr_uint = 0
                var param_names = vec.Vec[str].create()
                while pi < pr.method_params.len:
                    var p: ast.Param = read(pr.method_params.data + pi)
                    param_types.push(resolve_type_value(ctx, p.param_type))
                    param_names.push(p.name)
                    pi += 1
                var ret = types.primitive("void")
                let rt = pr.return_type
                if rt != null:
                    ret = resolve_type(ctx, rt)
                return types.Type.ty_function(params = param_types.as_span(), return_type = types.alloc_type(ret), variadic = false, is_proc = true, param_names = param_names.as_span())
            ast.Expr.expr_if as ife:
                let then_ty = infer_expr(ctx, scope, ife.then_expr)
                let else_ty = infer_expr(ctx, scope, ife.else_expr)
                return exprs.conditional_common_type(then_ty, else_ty)
            ast.Expr.expr_match as me:
                var arm_types = vec.Vec[types.Type].create()
                var ai: ptr_uint = 0
                while ai < me.arms.len:
                    var arm: ast.MatchExprArm = read(me.arms.data + ai)
                    scope_enter(scope)
                    bind_match_arm_names(scope, arm.binding_name, arm.pattern)
                    arm_types.push(infer_expr(ctx, scope, arm.value))
                    scope_leave(scope)
                    ai += 1
                return exprs.match_expression_common_type(arm_types.as_span())
            ast.Expr.expr_detach as det:
                match read(det.expression):
                    ast.Expr.expr_call as call:
                        match read(call.callee):
                            ast.Expr.expr_identifier:
                                pass
                            _:
                                report(ctx, det.line, det.column, "detach target must be a global function call")
                    _:
                        report(ctx, det.line, det.column, "detach target must be a function call")
                return types.Type.ty_error
            ast.Expr.expr_sizeof:
                return types.primitive("ptr_uint")
            ast.Expr.expr_alignof:
                return types.primitive("ptr_uint")
            ast.Expr.expr_offsetof:
                return types.primitive("ptr_uint")
            ast.Expr.expr_expression_list:
                return types.Type.ty_error
            ast.Expr.expr_range:
                return types.Type.ty_error
            ast.Expr.expr_named as nm:
                return infer_expr(ctx, scope, nm.value)
            ast.Expr.expr_error as err:
                return types.Type.ty_error
            _:
                return types.Type.ty_error


## A bare identifier that names something referenceable even when its type is
## not in `value_types` — a declared value/function/event (`value_names`), a
## function (fn-pointer), a type or type parameter, an import alias, or a
## built-in type constructor.  Used to avoid false "unknown name" reports.
function is_known_value_identifier(ctx: ref[Context], name: str) -> bool:
    if (
        ctx.value_names.contains(name)
        or ctx.value_types.contains(name)
        or ctx.functions.contains(name)
        or ctx.type_names.contains(name)
        or ctx.type_params.contains(name)
        or ctx.import_aliases.contains(name)
        or is_generic_constructor_name(name)
        or is_primitive_type_name(name)
        or name == "str"
    ):
        return true
    # Compile-time reflection builtins (`field_of(Labeled, value)`) pass bare
    # field and attribute names as arguments — these are declared names even
    # though they have no value-type entry.
    if ctx.declared_attributes.contains(name) or is_builtin_attribute_name(name):
        return true
    var keys = ctx.structs.keys()
    while true:
        let key_ptr = keys.next() else:
            break
        let struct_name = unsafe: read(key_ptr)
        let fields_ptr = ctx.structs.get(struct_name) else:
            continue
        unsafe:
            let fields = read(fields_ptr)
            var fi: ptr_uint = 0
            while fi < fields.len:
                if read(fields.data + fi).name == name:
                    return true
                fi += 1
    return false


function infer_identifier(ctx: ref[Context], scope: ref[sscope.Scope], name: str, line: ptr_uint, column: ptr_uint) -> types.Type:
    let local = scope_get(scope, name)
    if local != null:
        unsafe:
            return read(local)
    let global = ctx.value_types.get(name)
    if global != null:
        unsafe:
            return read(global)
    # Declared functions/externs and other referenceable names carry no
    # `value_types` entry, so keep the permissive error type for them (recorded
    # types — and thus code generation — are unchanged); only a name matching
    # nothing at all is a typo or missing import and is reported.
    if not is_known_value_identifier(ctx, name):
        report_at(ctx, line, column, name.len, unknown_name_message(name))
    return types.Type.ty_error


function unknown_name_message(name: str) -> str:
    var buf = string.String.create()
    buf.append("unknown name ")
    buf.append(name)
    return buf.as_str()


## Bind an arm's `as name` and struct-pattern field names to the permissive
## error type in the current scope, so references in the arm body/value are not
## reported as unknown.  Binding to `ty_error` keeps recorded types identical to
## the previous (unbound) behavior, so code generation is unaffected.
function bind_match_arm_names(scope: ref[sscope.Scope], binding_name: Option[str], pattern: ptr[ast.Expr]?) -> void:
    match binding_name:
        Option.some as bn:
            scope_set(scope, bn.value, types.Type.ty_error)
        Option.none:
            pass
    let p = pattern else:
        return
    unsafe:
        match read(p):
            ast.Expr.expr_call as cl:
                var i: ptr_uint = 0
                while i < cl.args.len:
                    var arg: ast.Argument
                    arg = read(cl.args.data + i)
                    match read(arg.arg_value):
                        ast.Expr.expr_identifier as id:
                            if not id.name == "_":
                                scope_set(scope, id.name, types.Type.ty_error)
                        _:
                            pass
                    i += 1
            _:
                pass


function infer_binary(ctx: ref[Context], scope: ref[sscope.Scope], op: str, left: ptr[ast.Expr], right: ptr[ast.Expr]) -> types.Type:
    # Always infer both operands so nested calls in either side are checked.
    let lt = infer_expr(ctx, scope, left)
    let rt = infer_expr(ctx, scope, right)
    if is_comparison_op(op) or op == "and" or op == "or":
        return types.primitive("bool")
    # SIMD arithmetic: vector ⊕ vector (same element and lane count) yields the
    # vector; vector * scalar and scalar * vector broadcast the scalar.
    if types.is_simd_type(lt) or types.is_simd_type(rt):
        if types.is_simd_type(lt) and types.is_simd_type(rt):
            if types.type_equals(lt, rt) and (op == "+" or op == "-" or op == "*" or op == "/"):
                return lt
        if types.is_simd_type(lt) and types.is_numeric(rt) and types.type_equals(types.simd_element_type(lt), rt):
            if op == "*" or op == "/":
                return lt
        if types.is_simd_type(rt) and types.is_numeric(lt) and types.type_equals(types.simd_element_type(rt), lt):
            if op == "*":
                return rt
    if (types.is_raw_pointer(lt) or types.is_raw_pointer(rt)) and ctx.unsafe_depth == 0:
        report(ctx, 0, 0, "pointer arithmetic requires unsafe")
    if types.is_numeric(lt) and types.is_numeric(rt):
        # A literal operand adapts to the other operand's numeric type, so
        # `48 + value` types as `value`'s type and `1 << uint<-x` as uint —
        # mirrors Ruby's harmonize_binary_integer_literal_types /
        # harmonize_binary_float_literal_types.
        if is_bare_integer_literal(left) and types.is_integer_type(rt):
            return rt
        if is_bare_integer_literal(right) and types.is_integer_type(lt):
            return lt
        if is_float_literal_expr(left) and types.is_float_type(rt):
            return rt
        if is_float_literal_expr(right) and types.is_float_type(lt):
            return lt
        return lt
    if types.is_raw_pointer(lt) and not types.is_raw_pointer(rt):
        return lt
    if types.is_raw_pointer(rt) and not types.is_raw_pointer(lt):
        return rt
    # Vector/matrix/quaternion arithmetic: same-type yields that type;
    # scalar * vec yields vec; vec * scalar yields vec.
    let lt_name = primitive_type_name_static(lt)
    let rt_name = primitive_type_name_static(rt)
    if is_vec_math_name(lt_name) and lt_name == rt_name:
        return lt
    if is_vec_math_name(lt_name) and types.is_numeric(rt):
        return lt
    if is_vec_math_name(rt_name) and types.is_numeric(lt):
        return rt
    # Enum/flags binary ops on same-typed operands yield that nominal type
    # (flags `| & ^ ~`; enum/flags value arithmetic through the backing int).
    # Comparisons were already handled above (they return bool).
    if lt_name != "" and lt_name == rt_name and ctx.static_member_types.contains(lt_name):
        return lt
    return types.Type.ty_error


function is_vec_math_name(name: str) -> bool:
    return (
        name == "vec2" or name == "vec3" or name == "vec4"
        or name == "ivec2" or name == "ivec3" or name == "ivec4"
        or name == "mat3" or name == "mat4" or name == "quat"
    )


## A bare integer literal operand (Ruby's integer_literal_expression?).
function is_bare_integer_literal(ep: ptr[ast.Expr]) -> bool:
    unsafe:
        match read(ep):
            ast.Expr.expr_integer_literal:
                return true
            _:
                return false


## A float literal, optionally under unary +/- (Ruby's float_literal_expression?).
function is_float_literal_expr(ep: ptr[ast.Expr]) -> bool:
    unsafe:
        match read(ep):
            ast.Expr.expr_float_literal:
                return true
            ast.Expr.expr_unary_op as u:
                if u.operator == "-" or u.operator == "+":
                    return is_float_literal_expr(u.operand)
                return false
            _:
                return false


function primitive_type_name_static(t: types.Type) -> str:
    match t:
        types.Type.ty_primitive as p:
            return p.name
        types.Type.ty_named as n:
            return n.name
        types.Type.ty_imported as im:
            return im.name
        _:
            return ""


function is_comparison_op(op: str) -> bool:
    return (
        op == "==" or op == "!=" or op == "<" or op == "<="
        or op == ">" or op == ">="
    )


function infer_unary(ctx: ref[Context], scope: ref[sscope.Scope], op: str, operand: ptr[ast.Expr]) -> types.Type:
    let ot = infer_expr(ctx, scope, operand)
    if op == "not":
        return types.primitive("bool")
    if op == "-":
        return ot
    return types.Type.ty_error


## Infer a call's result type and, when the callee is a local top-level
## function, check argument count and (positional) argument types.  When the
## callee names a local struct, treat it as a struct construction and validate
## named-field references instead.
function infer_and_check_call(ctx: ref[Context], scope: ref[sscope.Scope], callee: ptr[ast.Expr], args: span[ast.Argument]) -> types.Type:
    var arg_types = vec.Vec[types.Type].create()
    var any_named = false
    var i: ptr_uint = 0
    while i < args.len:
        var arg: ast.Argument
        unsafe:
            arg = read(args.data + i)
        arg_types.push(infer_expr(ctx, scope, arg.arg_value))
        match arg.arg_name:
            Option.some:
                any_named = true
            Option.none:
                pass
        i += 1

    let arg_span = arg_types.as_span()

    match try_imported_call(ctx, scope, callee, args, arg_span, any_named):
        Option.some as imported:
            return imported.value
        Option.none:
            pass

    match try_construction(ctx, scope, callee, args):
        Option.some as ct:
            return ct.value
        Option.none:
            unsafe:
                match read(callee):
                    ast.Expr.expr_member_access as ma:
                        return check_member_call(ctx, scope, ma.receiver, ma.member_name, args, arg_span, any_named, ma.line, ma.column)
                    ast.Expr.expr_specialization as spec:
                        return check_specialization_call(ctx, scope, spec.callee, spec.arguments, arg_span, args)
                    ast.Expr.expr_identifier:
                        return check_call(ctx, scope, callee, args, arg_span, any_named)
                    _:
                        let _ignored = infer_expr(ctx, scope, callee)
                        return types.Type.ty_error


## A call whose callee is a specialization `name[Type](...)`.  Associated-function
## hook builtins (hash/equal/order/default) are checked: when the type argument
## is a fully-known local struct, the required hook must exist.  Everything else
## (primitives, imported types, type variables, user generic functions) stays
## permissive.
function check_specialization_call(ctx: ref[Context], scope: ref[sscope.Scope], spec_callee: ptr[ast.Expr], type_args: span[ast.TypeArgument], arg_types: span[types.Type], arg_exprs: span[ast.Argument]) -> types.Type:
    unsafe:
        match read(spec_callee):
            ast.Expr.expr_identifier as id:
                if id.name == "zero" and not ctx.functions.contains(id.name) and scope_get(scope, id.name) == null:
                    return check_zero_call(ctx, type_args, id.line, id.column)
                if id.name == "reinterpret" and not ctx.functions.contains(id.name) and scope_get(scope, id.name) == null:
                    return check_reinterpret_call(ctx, type_args, arg_types, id.line, id.column)
                if is_hook_name(id.name) and not ctx.functions.contains(id.name) and scope_get(scope, id.name) == null:
                    return check_hook_call(ctx, id.name, type_args, id.line, id.column)
                if id.name == "adapt" and not ctx.functions.contains(id.name) and scope_get(scope, id.name) == null:
                    return check_adapt_call(ctx, type_args)
                if id.name == "simd" and not ctx.functions.contains(id.name) and scope_get(scope, id.name) == null:
                    return check_simd_call(ctx, type_args, arg_types, arg_exprs, id.line, id.column)
                let tps_ptr = ctx.function_type_params.get(id.name)
                if tps_ptr != null and scope_get(scope, id.name) == null:
                    var subs = map_mod.Map[str, types.Type].create()
                    validate_explicit_type_args(ctx, read(tps_ptr), type_args, ref_of(subs), id.line, id.column)
                    let sigp = ctx.functions.get(id.name)
                    if sigp != null:
                        return substitute_type(read(sigp).return_type, ref_of(subs))
                return types.Type.ty_error
            _:
                return types.Type.ty_error


## `reinterpret[T](v)` returns T; requires unsafe context.
function check_reinterpret_call(ctx: ref[Context], type_args: span[ast.TypeArgument], arg_types: span[types.Type], line: ptr_uint, column: ptr_uint) -> types.Type:
    if type_args.len != 1:
        return types.Type.ty_error
    if ctx.unsafe_depth == 0:
        report(ctx, line, column, "reinterpret requires unsafe")
    var arg_ref: ptr[ast.TypeRef]
    unsafe:
        arg_ref = read(type_args.data + 0).value
    let target = resolve_type(ctx, arg_ref)
    # `reinterpret` is a bit-pattern reinterpretation, so both sides must have
    # the same size.  Enforced when both sizes are statically known (primitives
    # and raw pointers); other types stay permissive, matching the conservative
    # analyzer posture.  Mirrors Ruby's equal-size diagnostic.
    if arg_types.len == 1:
        var source: types.Type
        unsafe:
            source = read(arg_types.data + 0)
        let source_size = known_byte_size(source) else:
            return target
        let target_size = known_byte_size(target) else:
            return target
        if source_size != target_size:
            var message = string.String.from_str("reinterpret requires equal-size types, got ")
            message.append(types.type_to_string(source))
            message.append(" (")
            message.append(byte_size_label(source_size))
            message.append(" bytes) -> ")
            message.append(types.type_to_string(target))
            message.append(" (")
            message.append(byte_size_label(target_size))
            message.append(" bytes)")
            report(ctx, line, column, message.as_str())
    return target


## The byte size of a type when statically known: primitives and raw pointers.
## Returns none for structs, generics, and anything layout-dependent.
function known_byte_size(ty: types.Type) -> Option[long]:
    match ty:
        types.Type.ty_primitive as p:
            if p.name == "bool" or p.name == "byte" or p.name == "ubyte" or p.name == "char":
                return Option[long].some(value = 1)
            if p.name == "short" or p.name == "ushort":
                return Option[long].some(value = 2)
            if p.name == "int" or p.name == "uint" or p.name == "float":
                return Option[long].some(value = 4)
            if (
                p.name == "long" or p.name == "ulong" or p.name == "double"
                or p.name == "ptr_int" or p.name == "ptr_uint" or p.name == "cstr"
            ):
                return Option[long].some(value = 8)
            return Option[long].none
        types.Type.ty_generic as g:
            if g.name == "ptr" or g.name == "const_ptr" or g.name == "own":
                return Option[long].some(value = 8)
            return Option[long].none
        _:
            return Option[long].none


## Digits for the small power-of-two byte sizes known_byte_size can produce.
function byte_size_label(size: long) -> str:
    if size == 1:
        return "1"
    if size == 2:
        return "2"
    if size == 4:
        return "4"
    return "8"


## `zero[T]` returns T (zero-initialized value type).
function check_zero_call(ctx: ref[Context], type_args: span[ast.TypeArgument], line: ptr_uint, column: ptr_uint) -> types.Type:
    if type_args.len != 1:
        return types.Type.ty_error
    var arg_ref: ptr[ast.TypeRef]
    unsafe:
        arg_ref = read(type_args.data + 0).value
    return resolve_type(ctx, arg_ref)


## `adapt[I](ref_of(value))` constructs a dyn[I] value.  Verify I resolves to a
## known interface; type-argument checking of `value`'s type against I is
## permissive for now (the caller handles this at the `ref_of` argument level).
function check_adapt_call(ctx: ref[Context], type_args: span[ast.TypeArgument]) -> types.Type:
    if type_args.len != 1:
        return types.Type.ty_error
    var arg_ref: ptr[ast.TypeRef]
    unsafe:
        arg_ref = read(type_args.data + 0).value
    let iface_name = unsafe: qname_to_str(read(arg_ref).name)
    return types.Type.ty_dyn(iface = iface_name)


## `simd[E, N](v0, ..., vN-1)` constructs a SIMD vector.  Requires exactly two
## type arguments (element type and lane count) and exactly N positional lane
## values assignable to E.
function check_simd_call(ctx: ref[Context], type_args: span[ast.TypeArgument], arg_types: span[types.Type], arg_exprs: span[ast.Argument], line: ptr_uint, column: ptr_uint) -> types.Type:
    if type_args.len != 2:
        report(ctx, line, column, "simd requires exactly two type arguments")
        return types.Type.ty_error
    var elem_ref: ptr[ast.TypeRef]
    var lane_ref: ptr[ast.TypeRef]
    unsafe:
        elem_ref = read(type_args.data + 0).value
        lane_ref = read(type_args.data + 1).value
    let elem_ty = resolve_type(ctx, elem_ref)
    let lane_ty = resolve_type(ctx, lane_ref)
    var lanes: long = 0
    match lane_ty:
        types.Type.ty_literal_int as lit:
            lanes = lit.value
        _:
            report(ctx, line, column, "simd lane count must be an integer literal")
            return types.Type.ty_error
    if lanes <= 0:
        report(ctx, line, column, "simd lane count must be positive")
        return types.Type.ty_error
    if long<-arg_types.len != lanes:
        report(ctx, line, column, "simd construction requires exactly N positional lane values")
        return types.Type.ty_error
    var i: ptr_uint = 0
    while i < arg_types.len:
        var at: types.Type
        var arg_expr: ptr[ast.Expr]? = null
        unsafe:
            at = read(arg_types.data + i)
            if i < arg_exprs.len:
                arg_expr = read(arg_exprs.data + i).arg_value
        if incompatible_value(elem_ty, at, arg_expr):
            report(ctx, line, column, "simd lane value type does not match the element type")
            return types.Type.ty_error
        i += 1
    var simd_args = vec.Vec[types.Type].create()
    simd_args.push(elem_ty)
    simd_args.push(types.literal_int(lanes))
    return types.Type.ty_generic(name = "simd", args = simd_args.as_span())


## `v.with(lane, value)` returns a copy of `v` with one lane replaced.  The
## lane index must be an integer and the value assignable to the element type.
function check_simd_with_call(ctx: ref[Context], simd_ty: types.Type, args: span[ast.Argument], arg_types: span[types.Type], any_named: bool, line: ptr_uint, column: ptr_uint) -> void:
    if any_named:
        report(ctx, line, column, "simd.with does not accept named arguments")
        return
    if arg_types.len != 2:
        report(ctx, line, column, "simd.with expects exactly two arguments")
        return
    var index_ty: types.Type
    var value_ty: types.Type
    unsafe:
        index_ty = read(arg_types.data + 0)
        value_ty = read(arg_types.data + 1)
    if not types.is_integer_type(index_ty):
        report(ctx, line, column, "simd.with lane index must be an integer")
    let elem_ty = types.simd_element_type(simd_ty)
    var value_expr: ptr[ast.Expr]? = null
    unsafe:
        if args.len >= 2:
            value_expr = read(args.data + 1).arg_value
    if incompatible_value(elem_ty, value_ty, value_expr):
        report(ctx, line, column, "simd.with lane value type does not match the element type")


## Validate the constraints of an explicit `foo[A, B](...)` call: resolve each
## type argument and check it satisfies its parameter's constraints.  Skipped
## unless the parameters are all plain type variables and the counts line up
## (avoids misaligning value/lifetime parameters).
function validate_explicit_type_args(ctx: ref[Context], type_params: span[ast.TypeParam], type_args: span[ast.TypeArgument], subs: ref[map_mod.Map[str, types.Type]], line: ptr_uint, column: ptr_uint) -> void:
    if type_args.len != type_params.len or not all_plain_type_params(type_params):
        return
    var i: ptr_uint = 0
    while i < type_params.len:
        var tp: ast.TypeParam
        var arg_ref: ptr[ast.TypeRef]
        unsafe:
            tp = read(type_params.data + i)
            arg_ref = read(type_args.data + i).value
        let actual = resolve_type(ctx, arg_ref)
        subs.set(tp.name, actual)
        check_type_arg_constraints(ctx, actual, tp.constraints, line, column)
        i += 1


## Apply a substitution map to a type, replacing bound type variables with their
## concrete types (used to substitute a generic call's return type).  Unbound
## type variables are left as-is (permissive).
function substitute_type(t: types.Type, subs: ref[map_mod.Map[str, types.Type]]) -> types.Type:
    match t:
        types.Type.ty_var as v:
            let actual_ptr = subs.get(v.name)
            if actual_ptr != null:
                return unsafe: read(actual_ptr)
            return t
        types.Type.ty_nullable as n:
            return types.Type.ty_nullable(base = types.alloc_type(substitute_type(unsafe: read(n.base), subs)))
        types.Type.ty_generic as g:
            var new_args = vec.Vec[types.Type].create()
            var i: ptr_uint = 0
            while i < g.args.len:
                unsafe:
                    new_args.push(substitute_type(read(g.args.data + i), subs))
                i += 1
            return types.Type.ty_generic(name = g.name, args = new_args.as_span())
        types.Type.ty_function as f:
            var new_params = vec.Vec[types.Type].create()
            var pi2: ptr_uint = 0
            while pi2 < f.params.len:
                unsafe:
                    new_params.push(substitute_type(read(f.params.data + pi2), subs))
                pi2 += 1
            let new_ret = substitute_type(unsafe: read(f.return_type), subs)
            return types.Type.ty_function(params = new_params.as_span(), return_type = types.alloc_type(new_ret), variadic = f.variadic, is_proc = f.is_proc, param_names = f.param_names)
        types.Type.ty_imported as imported:
            return types.Type.ty_imported(module_name = imported.module_name, name = imported.name, args = substitute_type_span(imported.args, subs))
        _:
            return t


## Substitution over a type-argument list.
function substitute_type_span(args: span[types.Type], subs: ref[map_mod.Map[str, types.Type]]) -> span[types.Type]:
    var replaced = vec.Vec[types.Type].create()
    var i: ptr_uint = 0
    while i < args.len:
        unsafe:
            replaced.push(substitute_type(read(args.data + i), subs))
        i += 1
    return replaced.as_span()


## Validate constraints against an inferred substitution map (from a bare
## `foo(...)` call).  A type parameter with no inferred binding is skipped.
function validate_inferred_type_args(ctx: ref[Context], type_params: span[ast.TypeParam], subs: ref[map_mod.Map[str, types.Type]], line: ptr_uint, column: ptr_uint) -> void:
    var i: ptr_uint = 0
    while i < type_params.len:
        var tp: ast.TypeParam
        unsafe:
            tp = read(type_params.data + i)
        if not tp.is_value and not tp.is_lifetime:
            let actual_ptr = subs.get(tp.name)
            if actual_ptr != null:
                check_type_arg_constraints(ctx, unsafe: read(actual_ptr), tp.constraints, line, column)
        i += 1


function check_type_arg_constraints(ctx: ref[Context], actual: types.Type, constraints: span[ast.TypeParamConstraint], line: ptr_uint, column: ptr_uint) -> void:
    var i: ptr_uint = 0
    while i < constraints.len:
        var constraint: ast.TypeParamConstraint
        unsafe:
            constraint = read(constraints.data + i)
        check_constraint_satisfied(ctx, actual, constraint, line, column)
        i += 1


## Flag only when a fully-known local-struct/opaque type argument definitely does
## not implement an interface constraint.  The constraint interface must resolve
## (locally or via a binding); a local struct and its constraint are written in
## the same module with the same aliases, so their qnames compare by identity.
## Imported struct arguments, primitives, type variables, and unresolvable
## interfaces stay permissive.
function check_constraint_satisfied(ctx: ref[Context], actual: types.Type, constraint: ast.TypeParamConstraint, line: ptr_uint, column: ptr_uint) -> void:
    match resolve_interface_methods(ctx, constraint.interface_ref):
        Option.none:
            return
        Option.some:
            pass
    let constraint_id = qname_to_str(constraint.interface_ref)
    match actual:
        types.Type.ty_named as n:
            let impl_ptr = ctx.implemented.get(n.name)
            if impl_ptr == null:
                return
            unsafe:
                if not impl_list_contains(read(impl_ptr), constraint_id):
                    report(ctx, line, column, constraint_unsatisfied_message(n.name, constraint_id))
        types.Type.ty_imported as im:
            check_imported_constraint(ctx, im.module_name, im.name, constraint, constraint_id, line, column)
        _:
            pass


## Constraint satisfaction for an imported struct type argument.  Safe only when
## the constraint is `alias.Iface` and `alias` names the struct's own module: the
## interface is then local to that module, so the struct implements it via a bare
## `impl_list` entry.  Any other shape (local constraint, interface from a third
## module, unexported impl_list) stays permissive.
function check_imported_constraint(ctx: ref[Context], struct_module: str, struct_name: str, constraint: ast.TypeParamConstraint, constraint_id: str, line: ptr_uint, column: ptr_uint) -> void:
    if constraint.interface_ref.parts.len != 2:
        return
    var iface_name: str = ""
    var alias: str = ""
    unsafe:
        alias = read(constraint.interface_ref.parts.data + 0)
        iface_name = read(constraint.interface_ref.parts.data + 1)
    let alias_module_ptr = ctx.import_aliases.get(alias) else:
        return
    if not unsafe: read(alias_module_ptr) == struct_module:
        return
    let binding_ptr = lookup_binding(ctx, struct_module) else:
        return
    unsafe:
        let impl_ptr = read(binding_ptr).implemented.get(struct_name)
        if impl_ptr == null:
            return
        if not impl_list_contains_bare(read(impl_ptr), iface_name):
            report(ctx, line, column, constraint_unsatisfied_message(struct_name, constraint_id))


function impl_list_contains(impl_list: span[ast.QualifiedName], iface_name: str) -> bool:
    var i: ptr_uint = 0
    while i < impl_list.len:
        var q: ast.QualifiedName
        unsafe:
            q = read(impl_list.data + i)
        if qname_to_str(q) == iface_name:
            return true
        i += 1
    return false


## True when the impl list has a single-part (module-local) entry named
## `iface_name`.  Used to match an imported struct against a constraint interface
## that is local to the struct's own module.
function impl_list_contains_bare(impl_list: span[ast.QualifiedName], iface_name: str) -> bool:
    var i: ptr_uint = 0
    while i < impl_list.len:
        var q: ast.QualifiedName
        unsafe:
            q = read(impl_list.data + i)
        if q.parts.len == 1 and qname_to_str(q) == iface_name:
            return true
        i += 1
    return false


function all_plain_type_params(type_params: span[ast.TypeParam]) -> bool:
    var i: ptr_uint = 0
    while i < type_params.len:
        var tp: ast.TypeParam
        unsafe:
            tp = read(type_params.data + i)
        if tp.is_value or tp.is_lifetime:
            return false
        i += 1
    return true


## Best-effort unification of a call's parameter patterns against its argument
## types, recording type-variable bindings.  Never fails: unresolvable positions
## simply leave a type parameter unbound (and thus unchecked).
function unify_call_args(params: span[ParamEntry], arg_types: span[types.Type], subs: ref[map_mod.Map[str, types.Type]]) -> void:
    var i: ptr_uint = 0
    while i < params.len and i < arg_types.len:
        unsafe:
            unify(read(params.data + i).ty, read(arg_types.data + i), subs)
        i += 1


## `unify_call_args` with the argument expressions in hand: a bare function
## reference infers as `ty_error` (recorded types, and therefore code
## generation, treat it that way), but inference needs its signature —
## `iter_map(it, triple)` binds `U` from `triple: fn(value: int) -> int`.
function unify_call_arguments(
    ctx: ref[Context],
    scope: ref[sscope.Scope],
    params: span[ParamEntry],
    args: span[ast.Argument],
    arg_types: span[types.Type],
    subs: ref[map_mod.Map[str, types.Type]],
) -> void:
    var i: ptr_uint = 0
    while i < params.len and i < arg_types.len:
        var actual: types.Type
        unsafe:
            actual = read(arg_types.data + i)
            if i < args.len:
                actual = argument_inference_type(ctx, scope, read(args.data + i).arg_value, actual)
            unify(read(params.data + i).ty, actual, subs)
        i += 1


## The type an argument contributes to generic inference.  Only a `ty_error`
## argument that names a known function is refined (to that function's
## signature); everything else is used as inferred.
function argument_inference_type(ctx: ref[Context], scope: ref[sscope.Scope], arg: ptr[ast.Expr], inferred: types.Type) -> types.Type:
    match inferred:
        types.Type.ty_error:
            unsafe:
                match read(arg):
                    ast.Expr.expr_identifier as id:
                        if scope_get(scope, id.name) != null:
                            return inferred
                        let sig_ptr = ctx.functions.get(id.name)
                        if sig_ptr == null:
                            return inferred
                        let sig = read(sig_ptr)
                        var params = vec.Vec[types.Type].create()
                        var pi: ptr_uint = 0
                        while pi < sig.params.len:
                            params.push(read(sig.params.data + pi).ty)
                            pi += 1
                        return types.Type.ty_function(
                            params = params.as_span(),
                            return_type = types.alloc_type(sig.return_type),
                            variadic = sig.is_variadic,
                            is_proc = false,
                            param_names = span[str](),
                        )
                    _:
                        return inferred
        _:
            return inferred


function unify(pattern: types.Type, actual: types.Type, subs: ref[map_mod.Map[str, types.Type]]) -> void:
    match pattern:
        types.Type.ty_var as v:
            if subs.get(v.name) == null:
                subs.set(v.name, actual)
        types.Type.ty_nullable as pn:
            var inner_actual = actual
            match actual:
                types.Type.ty_nullable as an:
                    inner_actual = unsafe: read(an.base)
                _:
                    pass
            unify(unsafe: read(pn.base), inner_actual, subs)
        types.Type.ty_generic as pg:
            if pg.name == "ref" and pg.args.len == 1:
                unify(unsafe: read(pg.args.data + 0), unwrap_ref(actual), subs)
            else:
                match actual:
                    types.Type.ty_generic as ag:
                        if (pg.name == "ptr" or pg.name == "const_ptr") and ag.name == "own" and pg.args.len >= 1 and ag.args.len >= 1:
                            unsafe:
                                unify(read(pg.args.data + 0), read(ag.args.data + 0), subs)
                        else if pg.name == ag.name and pg.args.len == ag.args.len:
                            var i: ptr_uint = 0
                            while i < pg.args.len:
                                unsafe:
                                    unify(read(pg.args.data + i), read(ag.args.data + i), subs)
                                i += 1
                    _:
                        pass
        types.Type.ty_imported as pi:
            # An imported generic type in a signature (`iter_filter[T]` takes
            # `Iter[T]`): unify the type arguments so the call's type parameters
            # bind from the argument types.
            match actual:
                types.Type.ty_imported as ai:
                    if pi.name == ai.name and pi.args.len == ai.args.len:
                        var i: ptr_uint = 0
                        while i < pi.args.len:
                            unsafe:
                                unify(read(pi.args.data + i), read(ai.args.data + i), subs)
                            i += 1
                types.Type.ty_generic as ag:
                    if pi.name == ag.name and pi.args.len == ag.args.len:
                        var j: ptr_uint = 0
                        while j < pi.args.len:
                            unsafe:
                                unify(read(pi.args.data + j), read(ag.args.data + j), subs)
                            j += 1
                _:
                    pass
        types.Type.ty_function as pf:
            match actual:
                types.Type.ty_function as af:
                    if pf.params.len == af.params.len:
                        var pi2: ptr_uint = 0
                        while pi2 < pf.params.len:
                            unsafe:
                                unify(read(pf.params.data + pi2), read(af.params.data + pi2), subs)
                            pi2 += 1
                        unsafe:
                            unify(read(pf.return_type), read(af.return_type), subs)
                _:
                    pass
        _:
            pass


function is_hook_name(name: str) -> bool:
    return name == "hash" or name == "equal" or name == "order" or name == "default"


## Check an associated-function hook call `hook[T](...)`.  Flags a missing hook
## only when T is a fully-known local struct; yields the hook's result type.
function check_hook_call(ctx: ref[Context], hook_name: str, type_args: span[ast.TypeArgument], line: ptr_uint, column: ptr_uint) -> types.Type:
    if type_args.len != 1:
        return types.Type.ty_error
    var arg_ref: ptr[ast.TypeRef]
    unsafe:
        arg_ref = read(type_args.data + 0).value
    let arg_type = resolve_type(ctx, arg_ref)

    match arg_type:
        types.Type.ty_named as n:
            if ctx.structs.contains(n.name):
                match lookup_method_anywhere(ctx, n.name, hook_name):
                    Option.some:
                        pass
                    Option.none:
                        report(ctx, line, column, hook_missing_message(hook_name, n.name))
        _:
            pass

    if hook_name == "hash":
        return types.primitive("uint")
    if hook_name == "equal":
        return types.primitive("bool")
    if hook_name == "order":
        return types.primitive("int")
    return arg_type


## A call whose callee is `alias.member(...)` where `alias` names an imported
## module: check against the imported function signature (yielding its return
## type), or against an imported struct's fields (a cross-module construction).
## Anything else (local calls, unresolved aliases, non-exported members) is left
## to the local paths.
function try_imported_call(ctx: ref[Context], scope: ref[sscope.Scope], callee: ptr[ast.Expr], args: span[ast.Argument], arg_types: span[types.Type], any_named: bool) -> Option[types.Type]:
    unsafe:
        match read(callee):
            ast.Expr.expr_member_access as ma:
                match read(ma.receiver):
                    ast.Expr.expr_identifier as id:
                        # A local value shadowing the name is not a module alias.
                        if scope_get(scope, id.name) != null:
                            return Option[types.Type].none
                        let module_name_ptr = ctx.import_aliases.get(id.name) else:
                            return Option[types.Type].none
                        let binding_ptr = lookup_binding(ctx, read(module_name_ptr)) else:
                            return Option[types.Type].none

                        let sig_ptr = read(binding_ptr).functions.get(ma.member_name)
                        if sig_ptr != null:
                            let sig = read(sig_ptr)
                            check_signature_call(ctx, ma.member_name, sig, args, arg_types, any_named, ma.line, ma.column)
                            # A generic exported function infers its type arguments
                            # from the call's arguments (`iter.iter_filter(it, pred)`
                            # -> `Iter[int]`), exactly as a local call does.
                            let tps_ptr = read(binding_ptr).function_type_params.get(ma.member_name)
                            if tps_ptr != null:
                                var subs = map_mod.Map[str, types.Type].create()
                                defer: subs.release()
                                unify_call_arguments(ctx, scope, sig.params, args, arg_types, ref_of(subs))
                                validate_inferred_type_args(ctx, read(tps_ptr), ref_of(subs), ma.line, ma.column)
                                return Option[types.Type].some(value = substitute_type(sig.return_type, ref_of(subs)))
                            return Option[types.Type].some(value = sig.return_type)

                        let fields_ptr = read(binding_ptr).structs.get(ma.member_name)
                        if fields_ptr != null:
                            check_construction(ctx, scope, ma.member_name, read(fields_ptr), args, ma.line, ma.column)
                            return Option[types.Type].some(value = types.Type.ty_imported(
                                module_name = read(module_name_ptr),
                                name = ma.member_name,
                                args = span[types.Type](),
                            ))

                        return Option[types.Type].none
                    _:
                        return Option[types.Type].none
            _:
                return Option[types.Type].none


## Resolve `alias.member` where `alias` is an imported module and `member` is one
## of its exported values, yielding the value's type.  None for anything else.
function try_imported_member(ctx: ref[Context], scope: ref[sscope.Scope], receiver: ptr[ast.Expr], member: str) -> Option[types.Type]:
    unsafe:
        match read(receiver):
            ast.Expr.expr_identifier as id:
                if scope_get(scope, id.name) != null:
                    return Option[types.Type].none
                let module_name_ptr = ctx.import_aliases.get(id.name) else:
                    return Option[types.Type].none
                let binding_ptr = lookup_binding(ctx, read(module_name_ptr)) else:
                    return Option[types.Type].none
                let value_ptr = read(binding_ptr).value_types.get(member)
                if value_ptr != null:
                    return Option[types.Type].some(value = read(value_ptr))
                return Option[types.Type].none
            _:
                return Option[types.Type].none


## Resolve a module name to its import binding, if bindings were provided.
function lookup_binding(ctx: ref[Context], module_name: str) -> ptr[ModuleBinding]?:
    let imported = ctx.imported_modules else:
        return null
    unsafe:
        return read(imported).get(module_name)


## Check a call whose callee is `receiver.method(...)`.  Enum/variant static
## members (`Color.red(...)`, `lib.Token.ident(...)`) are validated for existence
## only.  Struct static methods (`Counter.make(...)`, `lib.Adder.make(...)`) and
## value-receiver instance methods (`p.method(...)`) are resolved to a signature
## and argument-checked, with the method's return type flowing to the caller.
function check_member_call(ctx: ref[Context], scope: ref[sscope.Scope], receiver: ptr[ast.Expr], method_name: str, args: span[ast.Argument], arg_types: span[types.Type], any_named: bool, line: ptr_uint, column: ptr_uint) -> types.Type:
    match imported_static_member(ctx, scope, receiver, method_name, line, column):
        Option.some as imported_static:
            return imported_static.value
        Option.none:
            pass

    match static_type_receiver(ctx, scope, receiver):
        Option.some as tn:
            check_static_member(ctx, tn.value, method_name, line, column)
            return types.Type.ty_named(module_name = ctx.module_name, name = tn.value)
        Option.none:
            pass

    match static_struct_receiver_type(ctx, scope, receiver):
        Option.some as static_type:
            return check_typed_method_call(ctx, static_type.value, method_name, args, arg_types, any_named, line, column)
        Option.none:
            pass

    # An instantiated imported receiver resolves the call against the binding
    # with the type arguments substituted (`vec.Vec[int].create()` -> `Vec[int]`);
    # the signature is still argument-checked, as the local-type path does.
    match specialization_imported_receiver(ctx, scope, receiver):
        Option.some as instantiated:
            check_editable_receiver_immutable(ctx, scope, receiver, instantiated.value, method_name, line, column)
            match imported_method_call_type(ctx, instantiated.value, method_name, args, arg_types, any_named, line, column):
                Option.some as method_type:
                    return method_type.value
                Option.none:
                    pass
        Option.none:
            pass

    let recv = unwrap_ref(infer_expr(ctx, scope, receiver))
    check_editable_receiver_immutable(ctx, scope, receiver, recv, method_name, line, column)
    match imported_method_call_type(ctx, recv, method_name, args, arg_types, any_named, line, column):
        Option.some as substituted_method:
            return substituted_method.value
        Option.none:
            pass
    return check_typed_method_call(ctx, recv, method_name, args, arg_types, any_named, line, column)


## See through a `ref[T]` receiver to `T` for member access and method calls,
## matching the language's auto-dereference of `ref` receivers.  An explicit
## lifetime (`ref[@a, T]`) occupies the first argument, so the referent is the
## last one.
function unwrap_ref(t: types.Type) -> types.Type:
    match t:
        types.Type.ty_generic as g:
            if g.name == "ref" and g.args.len >= 1:
                return unsafe: read(g.args.data + (g.args.len - 1))
            return t
        _:
            return t


## Resolve and check a method call against a known receiver type (local or
## imported): argument-check the signature and flow its return type, or fall back
## to a member-existence check when no signature is known.
function check_typed_method_call(ctx: ref[Context], receiver_type: types.Type, method_name: str, args: span[ast.Argument], arg_types: span[types.Type], any_named: bool, line: ptr_uint, column: ptr_uint) -> types.Type:
    if types.is_simd_type(receiver_type):
        if method_name == "with":
            check_simd_with_call(ctx, receiver_type, args, arg_types, any_named, line, column)
            return receiver_type
        report(ctx, line, column, unknown_member_message("method", types.type_to_string(receiver_type), method_name))
        return types.Type.ty_error
    match resolve_method_sig(ctx, receiver_type, method_name):
        Option.some as sig:
            check_signature_call(ctx, method_name, sig.value, args, arg_types, any_named, line, column)
            var type_name: Option[str] = Option[str].none
            match receiver_type:
                types.Type.ty_named as n:
                    type_name = Option[str].some(value = n.name)
                _:
                    pass
            match type_name:
                Option.some as tn:
                    let key = method_key(tn.value, method_name)
                    let tps_ptr = ctx.method_type_params.get(key)
                    if tps_ptr != null:
                        var subs = map_mod.Map[str, types.Type].create()
                        unify_call_args(sig.value.params, arg_types, ref_of(subs))
                        unsafe: validate_inferred_type_args(ctx, read(tps_ptr), ref_of(subs), line, column)
                        return substitute_type(sig.value.return_type, ref_of(subs))
                Option.none:
                    pass
            return sig.value.return_type
        Option.none:
            return check_member(ctx, receiver_type, method_name, true, line, column)


## When the receiver is a `let`-bound value and the method is `editable`, flag the
## call.  `ref` (borrow) and `var` (mutable) receivers are fine.
## A receiver of an `editable` method call: the binding's name and the call's
## line, so a linter can treat the binding as mutated.
public struct EditableSite:
    name: str
    line: ptr_uint


function check_editable_receiver_immutable(ctx: ref[Context], scope: ref[sscope.Scope], receiver_expr: ptr[ast.Expr], receiver_type: types.Type, method_name: str, line: ptr_uint, column: ptr_uint) -> void:
    match resolve_method_sig(ctx, receiver_type, method_name):
        Option.some as sig:
            match sig.value.method_kind:
                ast.MethodKind.mk_editable:
                    unsafe:
                        match read(receiver_expr):
                            ast.Expr.expr_identifier as id:
                                # `this` in a method body is implicitly ref,
                                # never a local let binding.
                                if id.name == "this":
                                    return
                                ctx.editable_receiver_sites.push(EditableSite(name = id.name, line = id.line))
                                if scope_is_let(scope, id.name):
                                    report(ctx, line, column, editable_on_immutable_message(id.name, method_name))
                            _:
                                pass
                _:
                    pass
        Option.none:
            pass


## The struct type named by a static-method receiver: a bare local struct name
## (`Counter`) or an imported `alias.Struct`.  None for values, enum/variant type
## names (handled as static members), or unknown names.
function static_struct_receiver_type(ctx: ref[Context], scope: ref[sscope.Scope], receiver: ptr[ast.Expr]) -> Option[types.Type]:
    unsafe:
        match read(receiver):
            ast.Expr.expr_identifier as id:
                if scope_get(scope, id.name) != null:
                    return Option[types.Type].none
                if ctx.structs.contains(id.name):
                    return Option[types.Type].some(value = types.Type.ty_named(module_name = "", name = id.name))
                return Option[types.Type].none
            ast.Expr.expr_member_access as inner:
                match read(inner.receiver):
                    ast.Expr.expr_identifier as alias_id:
                        if scope_get(scope, alias_id.name) != null:
                            return Option[types.Type].none
                        let module_name_ptr = ctx.import_aliases.get(alias_id.name) else:
                            return Option[types.Type].none
                        let binding_ptr = lookup_binding(ctx, read(module_name_ptr)) else:
                            return Option[types.Type].none
                        if read(binding_ptr).structs.contains(inner.member_name):
                            return Option[types.Type].some(value = types.Type.ty_imported(
                                    module_name = read(module_name_ptr),
                                    name = inner.member_name,
                                    args = span[types.Type](),
                                ))
                        return Option[types.Type].none
                    _:
                        return Option[types.Type].none
            _:
                return Option[types.Type].none


## The signature of `method_name` on a receiver of struct type, whether the type
## is local (ctx.method_sigs) or imported (the module's binding).  None for any
## other receiver type or an unknown method.
function resolve_method_sig(ctx: ref[Context], receiver: types.Type, method_name: str) -> Option[FnSig]:
    match receiver:
        types.Type.ty_named as n:
            let sig_ptr = ctx.method_sigs.get(method_key(n.name, method_name))
            if sig_ptr != null:
                return Option[FnSig].some(value = unsafe: read(sig_ptr))
            if n.module_name.len > 0:
                let bp = lookup_binding(ctx, n.module_name)
                if bp != null:
                    let bound = unsafe: read(bp).method_sigs.get(method_key(n.name, method_name))
                    if bound != null:
                        return Option[FnSig].some(value = unsafe: read(bound))
            # A raw or re-exported struct resolves its methods wherever they are
            # declared (`extending Bitset:` lives in std.bitset, while the value's
            # type may arrive as a bare name from an imported signature): the
            # editable check needs the kind, so the search must not stop at the
            # current module.
            return lookup_method_anywhere(ctx, n.name, method_name)
        types.Type.ty_imported as im:
            let bp = lookup_binding(ctx, im.module_name)
            if bp != null:
                let sp = unsafe: read(bp).method_sigs.get(method_key(im.name, method_name))
                if sp != null:
                    return Option[FnSig].some(value = unsafe: read(sp))
            let sp = ctx.method_sigs.get(method_key(im.name, method_name))
            if sp != null:
                return Option[FnSig].some(value = unsafe: read(sp))
            return Option[FnSig].none
        types.Type.ty_var as v:
            match resolve_constraint_method(ctx, v.name, method_name):
                Option.some as sig:
                    return Option[FnSig].some(value = sig.value)
                Option.none:
                    pass
            # A constrained type parameter may also carry interfaces its own
            # constraint does not name (`Identifiable.id_value` on a
            # `Damageable` parameter): the host resolves the method wherever it
            # is declared, so fall back to any interface that declares the name.
            return resolve_any_interface_method(ctx, method_name)
        types.Type.ty_str:
            return lookup_method_anywhere(ctx, "str", method_name)
        types.Type.ty_primitive as p:
            return lookup_method_anywhere(ctx, p.name, method_name)
        # str_buffer[N] and atomic[T] builtin methods.
        types.Type.ty_generic as g:
            if g.name == "str_buffer":
                return str_buffer_method_sig(g.args, method_name)
            if g.name == "atomic":
                return atomic_method_sig(g.args, method_name)
            let sig_ptr = ctx.method_sigs.get(method_key(g.name, method_name))
            if sig_ptr != null:
                return Option[FnSig].some(value = unsafe: read(sig_ptr))
            return Option[FnSig].none
        _:
            return Option[FnSig].none


## Synthetic FnSig for a builtin str_buffer method.  Only the known methods are
## recognized; anything else returns none.
function str_buffer_method_sig(args: span[types.Type], method_name: str) -> Option[FnSig]:
    let void_ty = types.primitive("void")
    let str_ty = types.Type.ty_str
    let ptr_uint_ty = types.primitive("ptr_uint")
    let cstr_ty = types.primitive("cstr")
    var params = vec.Vec[ParamEntry].create()
    var return_type = void_ty
    if method_name == "clear":
        pass
    else if method_name == "assign" or method_name == "append" or method_name == "assign_format" or method_name == "append_format":
        params.push(ParamEntry(name = "text", ty = str_ty))
    else if method_name == "len":
        return_type = ptr_uint_ty
    else if method_name == "capacity":
        return_type = ptr_uint_ty
    else if method_name == "as_str":
        return_type = str_ty
    else if method_name == "as_cstr":
        return_type = cstr_ty
    else:
        return Option[FnSig].none
    return Option[FnSig].some(value = FnSig(
        name = method_name,
        params = params.as_span(),
        return_type = return_type,
        has_return_type = true,
        method_kind = ast.MethodKind.mk_plain,
        is_async = false,
        is_variadic = false,
        is_extern = false,
        required_count = params.len()
    ))


function atomic_method_sig(args: span[types.Type], method_name: str) -> Option[FnSig]:
    if args.len != 1:
        return Option[FnSig].none
    let elem_ty = unsafe: read(args.data + 0)
    let void_ty = types.primitive("void")
    var params = vec.Vec[ParamEntry].create()
    var return_type = void_ty
    var method_kind = ast.MethodKind.mk_plain
    if method_name == "load":
        return_type = elem_ty
    else if method_name == "store":
        params.push(ParamEntry(name = "value", ty = elem_ty))
        method_kind = ast.MethodKind.mk_editable
    else if method_name == "add" or method_name == "sub" or method_name == "exchange":
        params.push(ParamEntry(name = "value", ty = elem_ty))
        return_type = elem_ty
        method_kind = ast.MethodKind.mk_editable
    else:
        return Option[FnSig].none
    return Option[FnSig].some(value = FnSig(
        name = method_name,
        params = params.as_span(),
        return_type = return_type,
        has_return_type = true,
        method_kind = method_kind,
        is_async = false,
        is_variadic = false,
        is_extern = false,
        required_count = params.len()
    ))


## Resolve `Type.method` by searching the local method table, then every
## reachable imported binding.  Underpins method calls on str and primitive
## receivers, whose methods live in whichever module extended the type (e.g.
## `str` methods in std.str).  Missing -> none (permissive; not flagged).
function lookup_method_anywhere(ctx: ref[Context], type_name: str, method_name: str) -> Option[FnSig]:
    let key = method_key(type_name, method_name)
    let local_ptr = ctx.method_sigs.get(key)
    if local_ptr != null:
        return Option[FnSig].some(value = unsafe: read(local_ptr))

    let imported = ctx.imported_modules else:
        return Option[FnSig].none

    # Several bindings can declare the same method (a raw struct is extended in
    # more than one module).  Pick the lexicographically smallest module name
    # rather than whichever binding the map yields first: the choice must not
    # depend on iteration order, or the two bootstrap stages would compile this
    # compiler differently (`mt_str_lit_*` renumbering in the fixed-point check).
    var chosen_name: str = ""
    var chosen_sig: FnSig
    var chosen = false
    unsafe:
        var entries = read(imported).entries()
        while entries.next():
            let entry = entries.current()
            let candidate = read(entry.value).method_sigs.get(key)
            if candidate != null:
                let candidate_name = read(entry.key)
                if not chosen or candidate_name.compare(chosen_name) < 0:
                    chosen_name = candidate_name
                    chosen_sig = read(candidate)
                    chosen = true
    if chosen:
        return Option[FnSig].some(value = chosen_sig)
    return Option[FnSig].none


## The signature a type variable's constraints make available for `method_name`:
## the matching method of the first constraint interface that declares it.
function resolve_constraint_method(ctx: ref[Context], var_name: str, method_name: str) -> Option[FnSig]:
    let constraints_ptr = ctx.type_params.get(var_name)
    if constraints_ptr == null:
        return Option[FnSig].none
    unsafe:
        let constraints = read(constraints_ptr)
        var i: ptr_uint = 0
        while i < constraints.len:
            let constraint = read(constraints.data + i)
            match resolve_interface_methods(ctx, constraint.interface_ref):
                Option.some as methods:
                    match interface_method_named(methods.value, method_name):
                        Option.some as m:
                            enter_suppressed_interface_method(ctx, m.value)
                            let result = build_fn_sig(ctx, m.value.name, m.value.method_params, m.value.return_type, m.value.method_kind, false)
                            ctx.suppressed_type_names.clear()
                            return Option[FnSig].some(value = result)
                        Option.none:
                            pass
                Option.none:
                    pass
            i += 1
    return Option[FnSig].none


## Any interface method with this name in a module's interface table, as a
## call signature.
function interface_method_in_map(ctx: ref[Context], ifaces: map_mod.Map[str, span[ast.InterfaceMethod]], method_name: str) -> Option[FnSig]:
    var keys = ifaces.keys()
    while true:
        let key_ptr = keys.next() else:
            break
        let methods_ptr = ifaces.get(unsafe: read(key_ptr)) else:
            continue
        match interface_method_named(unsafe: read(methods_ptr), method_name):
            Option.some as m:
                enter_suppressed_interface_method(ctx, m.value)
                let result = build_fn_sig(ctx, m.value.name, m.value.method_params, m.value.return_type, m.value.method_kind, false)
                ctx.suppressed_type_names.clear()
                return Option[FnSig].some(value = result)
            Option.none:
                pass
    return Option[FnSig].none


## Any visible interface method with this name, in this module or in an imported
## one — the permissive fallback the host applies to a type-parameter receiver
## whose own constraint does not declare the method.
function resolve_any_interface_method(ctx: ref[Context], method_name: str) -> Option[FnSig]:
    match interface_method_in_map(ctx, ctx.interfaces, method_name):
        Option.some as sig:
            return Option[FnSig].some(value = sig.value)
        Option.none:
            pass
    var aliases = ctx.import_aliases.keys()
    while true:
        let alias_ptr = aliases.next() else:
            break
        let module_name_ptr = ctx.import_aliases.get(unsafe: read(alias_ptr)) else:
            continue
        let binding_ptr = lookup_binding(ctx, unsafe: read(module_name_ptr)) else:
            continue
        match interface_method_in_map(ctx, unsafe: read(binding_ptr).interfaces, method_name):
            Option.some as sig:
                return Option[FnSig].some(value = sig.value)
            Option.none:
                pass
    return Option[FnSig].none


function interface_method_named(methods: span[ast.InterfaceMethod], name: str) -> Option[ast.InterfaceMethod]:
    var i: ptr_uint = 0
    while i < methods.len:
        var m: ast.InterfaceMethod
        unsafe:
            m = read(methods.data + i)
        if m.name == name:
            return Option[ast.InterfaceMethod].some(value = m)
        i += 1
    return Option[ast.InterfaceMethod].none


## Resolve `alias.Type` where `alias` is an imported module and `Type` is one of
## its exported types (struct, enum, flags, variant, type alias, interface, or
## opaque).  Returns an imported-type reference or `none` for anything else.
function try_imported_type(ctx: ref[Context], scope: ref[sscope.Scope], receiver: ptr[ast.Expr], member: str) -> Option[types.Type]:
    unsafe:
        match read(receiver):
            ast.Expr.expr_identifier as id:
                if scope_get(scope, id.name) != null:
                    return Option[types.Type].none
                let module_name_ptr = ctx.import_aliases.get(id.name) else:
                    return Option[types.Type].none
                let binding_ptr = lookup_binding(ctx, read(module_name_ptr)) else:
                    return Option[types.Type].none
                let binding = read(binding_ptr)
                if binding.structs.contains(member) or binding.type_aliases.contains(member) or binding.static_member_types.contains(member) or binding.interfaces.contains(member) or binding.types.contains(member):
                    return Option[types.Type].some(value = types.Type.ty_imported(module_name = read(module_name_ptr), name = member, args = span[types.Type]()))
                return Option[types.Type].none
            _:
                return Option[types.Type].none


## Resolve `alias.Type[args]` in expression position to the instantiated
## imported type (none when it is not an imported type).
function specialization_imported_receiver(ctx: ref[Context], scope: ref[sscope.Scope], receiver: ptr[ast.Expr]) -> Option[types.Type]:
    unsafe:
        match read(receiver):
            ast.Expr.expr_specialization as spec:
                match read(spec.callee):
                    ast.Expr.expr_member_access as ma:
                        match read(ma.receiver):
                            ast.Expr.expr_identifier as alias_id:
                                if scope_get(scope, alias_id.name) != null:
                                    return Option[types.Type].none
                                let module_name_ptr = ctx.import_aliases.get(alias_id.name) else:
                                    return Option[types.Type].none
                                let binding_ptr = lookup_binding(ctx, read(module_name_ptr)) else:
                                    return Option[types.Type].none
                                if not read(binding_ptr).structs.contains(ma.member_name) and not read(binding_ptr).types.contains(ma.member_name):
                                    return Option[types.Type].none
                                return Option[types.Type].some(value = types.Type.ty_imported(
                                    module_name = read(module_name_ptr),
                                    name = ma.member_name,
                                    args = resolve_type_arguments(ctx, spec.arguments),
                                ))
                            _:
                                return Option[types.Type].none
                    _:
                        return Option[types.Type].none
            _:
                return Option[types.Type].none


## The declared type arguments of a specialization as resolved types.
function resolve_type_arguments(ctx: ref[Context], type_args: span[ast.TypeArgument]) -> span[types.Type]:
    var resolved = vec.Vec[types.Type].create()
    var i: ptr_uint = 0
    while i < type_args.len:
        var ref_ptr: ptr[ast.TypeRef]
        unsafe:
            ref_ptr = read(type_args.data + i).value
        resolved.push(resolve_type(ctx, ref_ptr))
        i += 1
    return resolved.as_span()


## Substitute an instantiated type's arguments into the declaring binding's
## recorded parameter names.
function imported_type_substitution(ctx: ref[Context], binding_ptr: ptr[ModuleBinding]?, type_name: str, args: span[types.Type]) -> map_mod.Map[str, types.Type]:
    var subs = map_mod.Map[str, types.Type].create()
    if binding_ptr == null:
        return subs
    let params_ptr = unsafe: read(binding_ptr).type_param_names.get(type_name) else:
        return subs
    let params = unsafe: read(params_ptr)
    var i: ptr_uint = 0
    while i < params.len and i < args.len:
        unsafe:
            subs.set(read(params.data + i).name, read(args.data + i))
        i += 1
    return subs


## The binding that declares `type_name`, when any visible binding does.  The
## receiver's own module declares it normally; a raw re-export may not carry
## the type's parameters, so this also scans the visible bindings.
function binding_declaring_type(ctx: ref[Context], own: ptr[ModuleBinding]?, type_name: str) -> ptr[ModuleBinding]?:
    if own != null and unsafe: read(own).type_param_names.contains(type_name):
        return own
    let bindings = ctx.imported_modules else:
        return null
    # Deterministic pick (smallest module name), like `lookup_method_anywhere`:
    # the choice must not depend on map iteration order.
    var chosen_name: str = ""
    var chosen: ptr[ModuleBinding]? = null
    unsafe:
        var entries = read(bindings).entries()
        while entries.next():
            let entry = entries.current()
            if read(entry.value).type_param_names.contains(type_name):
                let name = read(entry.key)
                if chosen == null or name.compare(chosen_name) < 0:
                    chosen_name = name
                    chosen = entry.value
    return chosen


## The signature of `Type.member` among the visible bindings: the receiver's own
## module first, then anywhere else (`std.iter` declares `extending Vec[T]:`).
function imported_method_signature(ctx: ref[Context], own: ptr[ModuleBinding]?, type_name: str, member: str) -> ptr[FnSig]?:
    let key = method_key(type_name, member)
    if own != null:
        let own_sig = unsafe: read(own).method_sigs.get(key)
        if own_sig != null:
            return own_sig
    let bindings = ctx.imported_modules else:
        return null
    # Deterministic pick (smallest module name) for the same reason as
    # `lookup_method_anywhere`.
    var chosen_name: str = ""
    var chosen: ptr[FnSig]? = null
    unsafe:
        var entries = read(bindings).entries()
        while entries.next():
            let entry = entries.current()
            let candidate = read(entry.value).method_sigs.get(key)
            if candidate != null:
                let name = read(entry.key)
                if chosen == null or name.compare(chosen_name) < 0:
                    chosen_name = name
                    chosen = candidate
    return chosen


## `imported_method_return_type` with the call's arguments checked against the
## (substituted) signature, so an arity or argument-type mismatch is still
## reported for an instantiated imported receiver.
function imported_method_call_type(
    ctx: ref[Context],
    recv: types.Type,
    member: str,
    args: span[ast.Argument],
    arg_types: span[types.Type],
    any_named: bool,
    line: ptr_uint,
    column: ptr_uint,
) -> Option[types.Type]:
    match recv:
        types.Type.ty_imported as imported:
            let own = lookup_binding(ctx, imported.module_name)
            let sig_ptr = imported_method_signature(ctx, own, imported.name, member) else:
                return Option[types.Type].none
            let sig = unsafe: read(sig_ptr)
            check_signature_call(ctx, member, sig, args, arg_types, any_named, line, column)
            return imported_method_return_type(ctx, recv, member)
        _:
            return Option[types.Type].none


## The return type of an instantiated imported method (`Vec[int].create()` ->
## `Vec[int]`), with the receiver's type arguments substituted.  None when no
## visible binding declares the method, so callers keep their permissive
## fallback.
function imported_method_return_type(ctx: ref[Context], recv: types.Type, member: str) -> Option[types.Type]:
    # A receiver whose type arrives as a bare name (`Bitset`, re-exported by an
    # imported signature) resolves its methods through the visible bindings.
    match recv:
        types.Type.ty_named as named:
            let own = if named.module_name.len > 0: lookup_binding(ctx, named.module_name) else: null
            let sig_ptr = imported_method_signature(ctx, own, named.name, member) else:
                return Option[types.Type].none
            let sig = unsafe: read(sig_ptr)
            if not sig.has_return_type:
                return Option[types.Type].some(value = types.primitive("void"))
            return Option[types.Type].some(value = sig.return_type)
        _:
            pass
    match recv:
        types.Type.ty_imported as imported:
            let own = lookup_binding(ctx, imported.module_name)
            let sig_ptr = imported_method_signature(ctx, own, imported.name, member) else:
                return Option[types.Type].none

            var subs = imported_type_substitution(
                ctx,
                binding_declaring_type(ctx, own, imported.name),
                imported.name,
                imported.args,
            )
            defer: subs.release()

            let sig = unsafe: read(sig_ptr)
            if not sig.has_return_type:
                return Option[types.Type].some(value = types.primitive("void"))
            return Option[types.Type].some(value = substitute_type(sig.return_type, ref_of(subs)))
        _:
            return Option[types.Type].none


## Dispatch a member access: a bare type-name receiver of an enum/flags/variant
## is a static member access (validate against members/arms/methods); anything
## else is an instance access (struct field/method or permissive).
function resolve_member_access(ctx: ref[Context], scope: ref[sscope.Scope], receiver: ptr[ast.Expr], member: str, is_method_call: bool, line: ptr_uint, column: ptr_uint) -> types.Type:
    # An instantiated imported receiver resolves the member against the binding
    # with the type arguments substituted.
    match specialization_imported_receiver(ctx, scope, receiver):
        Option.some as instantiated:
            match imported_method_return_type(ctx, instantiated.value, member):
                Option.some as method_type:
                    return method_type.value
                Option.none:
                    pass
        Option.none:
            pass
    match try_imported_member(ctx, scope, receiver, member):
        Option.some as imported_value:
            return imported_value.value
        Option.none:
            match imported_static_member(ctx, scope, receiver, member, line, column):
                Option.some as imported_static:
                    return imported_static.value
                Option.none:
                    match static_type_receiver(ctx, scope, receiver):
                        Option.some as tn:
                            check_static_member(ctx, tn.value, member, line, column)
                            return types.Type.ty_named(module_name = ctx.module_name, name = tn.value)
                        Option.none:
                            match try_imported_type(ctx, scope, receiver, member):
                                Option.some as imported_type:
                                    return imported_type.value
                                Option.none:
                                    let recv = unwrap_ref(infer_expr(ctx, scope, receiver))
                                    return check_member(ctx, recv, member, is_method_call, line, column)


## Resolve `alias.Type.member` where `alias` is an imported module and `Type` is
## one of its exported enums/flags/variants: validate that `member` is a member
## of that type, flagging it otherwise.  None for anything else.
function imported_static_member(ctx: ref[Context], scope: ref[sscope.Scope], receiver: ptr[ast.Expr], member: str, line: ptr_uint, column: ptr_uint) -> Option[types.Type]:
    unsafe:
        match read(receiver):
            ast.Expr.expr_member_access as inner:
                match read(inner.receiver):
                    ast.Expr.expr_identifier as id:
                        if scope_get(scope, id.name) != null:
                            return Option[types.Type].none
                        let module_name_ptr = ctx.import_aliases.get(id.name) else:
                            return Option[types.Type].none
                        let binding_ptr = lookup_binding(ctx, read(module_name_ptr)) else:
                            return Option[types.Type].none
                        if not read(binding_ptr).static_member_types.contains(inner.member_name):
                            return Option[types.Type].none
                        if not binding_has_member(read(binding_ptr), inner.member_name, member):
                            report(ctx, line, column, unknown_member_message("member", inner.member_name, member))
                        return Option[types.Type].some(value = types.Type.ty_imported(module_name = read(module_name_ptr), name = inner.member_name, args = span[types.Type]()))
                    _:
                        return Option[types.Type].none
            _:
                return Option[types.Type].none


function binding_has_member(binding: ModuleBinding, type_name: str, member: str) -> bool:
    return binding.member_keys.contains(method_key(type_name, member))


## Some(type name) when `receiver` is a bare identifier naming a locally-declared
## enum/flags/variant that is not shadowed by a local value.
function static_type_receiver(ctx: ref[Context], scope: ref[sscope.Scope], receiver: ptr[ast.Expr]) -> Option[str]:
    unsafe:
        match read(receiver):
            ast.Expr.expr_identifier as id:
                if scope_get(scope, id.name) != null:
                    return Option[str].none
                if ctx.static_member_types.contains(id.name):
                    return Option[str].some(value = id.name)
                return Option[str].none
            _:
                return Option[str].none


function check_static_member(ctx: ref[Context], type_name: str, member: str, line: ptr_uint, column: ptr_uint) -> void:
    if has_method(ctx, type_name, member):
        return
    report(ctx, line, column, unknown_member_message("member", type_name, member))


## When `callee` is a bare identifier naming a locally-declared struct or a
## builtin vec/mat/quat type (not shadowed by a local value), validate each
## named-field argument and return the constructed type.  Returns none for
## ordinary function calls.
function try_construction(ctx: ref[Context], scope: ref[sscope.Scope], callee: ptr[ast.Expr], args: span[ast.Argument]) -> Option[types.Type]:
    unsafe:
        match read(callee):
            ast.Expr.expr_identifier as id:
                if scope_get(scope, id.name) != null:
                    return Option[types.Type].none
                let fieldsp = ctx.structs.get(id.name)
                if fieldsp == null:
                    # Builtin vector/matrix/quaternion constructors
                    # (`vec3(x = 1.0, y = 2.0, z = 3.0)`) yield the builtin type
                    # itself, mirroring the host's Vector/Matrix/Quaternion
                    # construction through `lookup_named_type`.
                    if is_vec_math_name(id.name):
                        let builtin = ctx.types.get(id.name)
                        if builtin != null:
                            return Option[types.Type].some(value = read(builtin))
                    return Option[types.Type].none
                check_construction(ctx, scope, id.name, read(fieldsp), args, id.line, id.column)
                return Option[types.Type].some(value = types.Type.ty_named(module_name = "", name = id.name))
            _:
                return Option[types.Type].none


function check_construction(ctx: ref[Context], scope: ref[sscope.Scope], struct_name: str, fields: span[FieldEntry], args: span[ast.Argument], line: ptr_uint, column: ptr_uint) -> void:
    var unnamed = false
    var i: ptr_uint = 0
    while i < args.len:
        var arg: ast.Argument
        unsafe:
            arg = read(args.data + i)
        match arg.arg_name:
            Option.none:
                unnamed = true
            _:
                pass
        i += 1
    if unnamed:
        report(ctx, line, column, named_args_required_message(struct_name))
        return

    var seen = map_mod.Map[str, bool].create()
    i = 0
    while i < args.len:
        var arg: ast.Argument
        unsafe:
            arg = read(args.data + i)
        match arg.arg_name:
            Option.some as nm:
                if seen.contains(nm.value):
                    report(ctx, line, column, duplicate_field_message(struct_name, nm.value))
                seen.set(nm.value, true)
                let ft = field_type(fields, nm.value)
                if ft == null:
                    report(ctx, line, column, unknown_member_message("field", struct_name, nm.value))
                else:
                    let vt = infer_expr(ctx, scope, arg.arg_value)
                    if incompatible_value(unsafe: read(ft), vt, arg.arg_value):
                        report(ctx, line, column, field_type_mismatch_message(struct_name, nm.value, unsafe: read(ft), vt))
            _:
                pass
        i += 1
    seen.release()


function field_type(fields: span[FieldEntry], name: str) -> ptr[types.Type]?:
    var i: ptr_uint = 0
    while i < fields.len:
        unsafe:
            let fe = read(fields.data + i)
            if fe.name == name:
                return ptr_of(read(fields.data + i).ty)
        i += 1
    return null


function has_field(fields: span[FieldEntry], name: str) -> bool:
    var i: ptr_uint = 0
    while i < fields.len:
        unsafe:
            if read(fields.data + i).name == name:
                return true
        i += 1
    return false


## Resolve a member access on a receiver.  For a locally-declared struct
## instance, a member must be a field, an `extending` method, or the builtin
## `with`; anything else is reported ("unknown field" for a read, "unknown
## method" when the member is the callee of a call).  Field reads yield the
## field type; everything else (methods, non-struct receivers) is permissive.
function check_member(ctx: ref[Context], receiver: types.Type, member: str, is_method_call: bool, line: ptr_uint, column: ptr_uint) -> types.Type:
    match receiver:
        types.Type.ty_named as n:
            let fieldsp = ctx.structs.get(n.name)
            if fieldsp == null:
                # A union member is read like a struct field.
                let unionp = ctx.unions.get(n.name)
                if unionp != null:
                    unsafe:
                        let ufields = read(unionp)
                        var ui: ptr_uint = 0
                        while ui < ufields.len:
                            let ufe = read(ufields.data + ui)
                            if ufe.name == member:
                                return ufe.ty
                            ui += 1
                # Not a locally-declared struct (enum/variant/opaque/imported).
                return types.Type.ty_error
            unsafe:
                let fields = read(fieldsp)
                var i: ptr_uint = 0
                while i < fields.len:
                    let fe = read(fields.data + i)
                    if fe.name == member:
                        return fe.ty
                    i += 1
            if member == "with" or has_method(ctx, n.name, member):
                return types.Type.ty_error
            if is_method_call:
                report(ctx, line, column, unknown_member_message("method", n.name, member))
            else:
                report(ctx, line, column, unknown_member_message("field", n.name, member))
            return types.Type.ty_error
        types.Type.ty_imported as im:
            return check_imported_member(ctx, im.module_name, im.name, member, is_method_call, line, column)
        types.Type.ty_var as v:
            return check_type_var_member(ctx, v.name, member, is_method_call, line, column)
        types.Type.ty_generic as g:
            if g.name == "Task" and g.args.len >= 1:
                if member == "frame" or member == "value" or member == "ready":
                    return types.Type.ty_error
            if g.name == "span":
                if member == "data" or member == "len":
                    return types.Type.ty_error
            if g.name == "ptr":
                if has_method(ctx, g.name, member):
                    return types.Type.ty_error
                return types.Type.ty_error
            if g.name == "array":
                if member == "as_span":
                    return types.Type.ty_error
            if g.name == "span" or g.name == "array" or g.name == "ptr":
                return types.Type.ty_error
            if has_method(ctx, g.name, member):
                return types.Type.ty_error
            if is_method_call:
                report(ctx, line, column, unknown_member_message("method", g.name, member))
            else:
                report(ctx, line, column, unknown_member_message("field", g.name, member))
            return types.Type.ty_error
        _:
            return types.Type.ty_error


## Member access on a value of type variable `T`.  A `T` value's only members are
## the methods of its `implements` constraints.  When every constraint interface
## resolves, a member not declared by any of them is reported; if a constraint is
## unresolvable, or `T` is unconstrained, access stays permissive.
function check_type_var_member(ctx: ref[Context], var_name: str, member: str, is_method_call: bool, line: ptr_uint, column: ptr_uint) -> types.Type:
    let constraints_ptr = ctx.type_params.get(var_name)
    if constraints_ptr == null:
        return types.Type.ty_error

    var all_resolvable = true
    unsafe:
        let constraints = read(constraints_ptr)
        if constraints.len == 0:
            return types.Type.ty_error
        var i: ptr_uint = 0
        while i < constraints.len:
            let constraint = read(constraints.data + i)
            match resolve_interface_methods(ctx, constraint.interface_ref):
                Option.some as methods:
                    match interface_method_named(methods.value, member):
                        Option.some:
                            return types.Type.ty_error
                        Option.none:
                            pass
                Option.none:
                    all_resolvable = false
            i += 1

    if all_resolvable:
        if is_method_call:
            report(ctx, line, column, unknown_member_message("method", var_name, member))
        else:
            report(ctx, line, column, unknown_member_message("field", var_name, member))
    return types.Type.ty_error


## Field or method access on a value of an imported struct type.  A field yields
## its (exporter-resolved) type; a public method or the builtin `with` is
## permissive; anything else is reported as unknown.  Permissive if the module is
## no longer bound.
function check_imported_member(ctx: ref[Context], module_name: str, type_name: str, member: str, is_method_call: bool, line: ptr_uint, column: ptr_uint) -> types.Type:
    return check_imported_member_depth(ctx, module_name, type_name, member, is_method_call, line, column, 0)


function check_imported_member_depth(ctx: ref[Context], module_name: str, type_name: str, member: str, is_method_call: bool, line: ptr_uint, column: ptr_uint, depth: int) -> types.Type:
    if depth > 10:
        return types.Type.ty_error
    let binding_ptr = lookup_binding(ctx, module_name) else:
        return types.Type.ty_error

    unsafe:
        let binding = read(binding_ptr)
        let fields_ptr = binding.structs.get(type_name)
        if fields_ptr != null:
            let fields = read(fields_ptr)
            var i: ptr_uint = 0
            while i < fields.len:
                let fe = read(fields.data + i)
                if fe.name == member:
                    return fe.ty
                i += 1

        let union_ptr = binding.unions.get(type_name)
        if union_ptr != null:
            let ufields = read(union_ptr)
            var ui: ptr_uint = 0
            while ui < ufields.len:
                let ufe = read(ufields.data + ui)
                if ufe.name == member:
                    return ufe.ty
                ui += 1

        if member == "with" or binding_has_member(binding, type_name, member):
            return types.Type.ty_error

    # A method this module declares on the receiver's type (`extending
    # b3.Vec3:` for a receiver that resolved to the C struct `b3Vec3`) lives in
    # the current module's method keys, not in any imported binding.
    if has_method(ctx, type_name, member):
        return types.Type.ty_error

    # Follow a type alias to its source module when the member is not found
    # directly (e.g. `public type uv_run_mode = c.uv_run_mode` re-exports an
    # external enum whose members live in the source external module).
    match follow_type_alias(ctx, binding_ptr, type_name):
        Option.some as source_info:
            return check_imported_member_depth(ctx, source_info.value.module_name, source_info.value.type_name, member, is_method_call, line, column, depth + 1)
        Option.none:
            pass

    # Reverse-alias search: `extending` methods on a re-exported type live in
    # the aliasing module's binding under the local alias name (e.g.
    # `type Image = c.Image` + `extending Image:` in std.raylib registers
    # `Image.draw_pixel` there, while the receiver type resolved to the source
    # module std.c.raylib).  Scan visible bindings for an alias that resolves
    # to this exact imported type and check its member keys.
    if alias_binding_has_member(ctx, module_name, type_name, member):
        return types.Type.ty_error

    if is_method_call:
        report(ctx, line, column, unknown_member_message("method", type_name, member))
    else:
        report(ctx, line, column, unknown_member_message("field", type_name, member))
    return types.Type.ty_error


## True when any visible module binding re-exports `module_name.type_name`
## through a type alias and declares `member` on that alias via `extending`.
function alias_binding_has_member(ctx: ref[Context], module_name: str, type_name: str, member: str) -> bool:
    let imported = ctx.imported_modules else:
        return false
    unsafe:
        var binding_entries = read(imported).entries()
        while binding_entries.next():
            let entry = binding_entries.current()
            let candidate = read(entry.value)
            # A module that declares `extending <alias>.<Type>:` on an imported
            # type registers the method under the *resolved* name (`b3Vec3`),
            # which is exactly what this receiver resolved to.
            if binding_has_member(candidate, type_name, member):
                return true
            var alias_entries = candidate.type_alias_types.entries()
            while alias_entries.next():
                let alias_entry = alias_entries.current()
                match read(alias_entry.value):
                    types.Type.ty_imported as im:
                        if im.module_name == module_name and im.name == type_name:
                            if binding_has_member(candidate, read(alias_entry.key), member):
                                return true
                    _:
                        pass
    return false


## When `type_name` is a type alias in the binding, resolve it to its source
## module and type name.  Returns `(source_module, source_type)` or `none` when
## the type is not a resolvable alias or is not imported from another module.
struct AliasSource:
    module_name: str
    type_name: str

function follow_type_alias(ctx: ref[Context], binding_ptr: ptr[ModuleBinding], type_name: str) -> Option[AliasSource]:
    unsafe:
        let resolved_ptr = read(binding_ptr).type_alias_types.get(type_name) else:
            return Option[AliasSource].none
        match read(resolved_ptr):
            types.Type.ty_imported as im:
                if im.module_name == "":
                    return Option[AliasSource].none
                return Option[AliasSource].some(value = AliasSource(module_name = im.module_name, type_name = im.name))
            _:
                return Option[AliasSource].none


## Return the result type of a known builtin call (read, ptr_of, const_ptr_of,
## size_of, align_of).  Returns `none` for anything else, so the call falls
## through to regular function/method dispatch.  `read(ptr)` and `ptr_of(x)` are
## side-effectful: they report an unsafe-context requirement when applicable.
function try_builtin_call(ctx: ref[Context], scope: ref[sscope.Scope], callee_name: str, args: span[ast.Argument], line: ptr_uint, column: ptr_uint) -> Option[types.Type]:
    if callee_name == "read":
        if args.len != 1:
            return Option[types.Type].none
        var arg: ast.Argument = unsafe: read(args.data + 0)
        let at = infer_expr(ctx, scope, arg.arg_value)
        if types.is_raw_pointer(at) and ctx.unsafe_depth == 0:
            report(ctx, line, column, "pointer dereference requires unsafe")
        if types.is_raw_pointer(at) or types.is_ref_type(at):
            return Option[types.Type].some(value = types.pointer_element(at))
        return Option[types.Type].none
    if callee_name == "ptr_of" or callee_name == "const_ptr_of" or callee_name == "ref_of":
        if args.len != 1:
            return Option[types.Type].none
        var arg: ast.Argument = unsafe: read(args.data + 0)
        let at = infer_expr(ctx, scope, arg.arg_value)
        let kind = if callee_name == "ptr_of": "ptr" else: if callee_name == "ref_of": "ref" else: "const_ptr"
        return Option[types.Type].some(value = types.Type.ty_generic(name = string.String.from_str(kind).as_str(), args = alloc_one_type_arg(at)))
    if callee_name == "size_of" or callee_name == "align_of":
        if args.len != 1:
            return Option[types.Type].none
        return Option[types.Type].some(value = types.primitive("ptr_uint"))
    if callee_name == "fatal":
        return Option[types.Type].some(value = types.Type.ty_error)
    if callee_name == "assert" or callee_name == "expect":
        if args.len < 1 or args.len > 2:
            return Option[types.Type].none
        let cond_ty = infer_expr(ctx, scope, unsafe: read(args.data + 0).arg_value)
        if not types.is_error(cond_ty) and types.type_to_string(cond_ty) != "bool":
            var cond_msg = string.String.from_str(callee_name)
            cond_msg.append(" condition must be bool")
            report(ctx, line, column, cond_msg.as_str())
        if args.len == 2:
            let _msg_ty = infer_expr(ctx, scope, unsafe: read(args.data + 1).arg_value)
        return Option[types.Type].some(value = types.primitive("void"))
    if callee_name == "expect_eq" or callee_name == "expect_ne":
        if args.len < 2 or args.len > 3:
            return Option[types.Type].none
        let left_ty = infer_expr(ctx, scope, unsafe: read(args.data + 0).arg_value)
        let right_ty = infer_expr(ctx, scope, unsafe: read(args.data + 1).arg_value)
        if incompatible_value(left_ty, right_ty, unsafe: read(args.data + 1).arg_value) and incompatible_value(right_ty, left_ty, unsafe: read(args.data + 0).arg_value):
            var cmp_msg = string.String.from_str(callee_name)
            cmp_msg.append(" operands are not comparable")
            report(ctx, line, column, cmp_msg.as_str())
        if args.len == 3:
            let _msg_ty = infer_expr(ctx, scope, unsafe: read(args.data + 2).arg_value)
        return Option[types.Type].some(value = types.primitive("void"))
    return Option[types.Type].none


function alloc_one_type_arg(ty: types.Type) -> span[types.Type]:
    var v = vec.Vec[types.Type].create()
    v.push(ty)
    return v.as_span()


## Check a call to a top-level function by identifier and yield its result type.
## For a generic function, type arguments are inferred from the call, validated
## against their constraints, and substituted into the return type.
function check_call(ctx: ref[Context], scope: ref[sscope.Scope], callee: ptr[ast.Expr], args: span[ast.Argument], arg_types: span[types.Type], any_named: bool) -> types.Type:
    unsafe:
        match read(callee):
            ast.Expr.expr_identifier as id:
                # Builtin calls (read, ptr_of, ...) handled before name lookup.
                match try_builtin_call(ctx, scope, id.name, args, id.line, id.column):
                    Option.some as ty:
                        return ty.value
                    Option.none:
                        pass
                # A local value (e.g. a proc) of the same name shadows the
                # function; its arity/parameter types are not statically known.
                if scope_get(scope, id.name) != null:
                    return types.Type.ty_error
                let sigp = ctx.functions.get(id.name)
                if sigp == null:
                    return types.Type.ty_error
                let sig = read(sigp)
                check_signature_call(ctx, id.name, sig, args, arg_types, any_named, id.line, id.column)
                let tps_ptr = ctx.function_type_params.get(id.name)
                if tps_ptr != null:
                    var subs = map_mod.Map[str, types.Type].create()
                    unify_call_arguments(ctx, scope, sig.params, args, arg_types, ref_of(subs))
                    validate_inferred_type_args(ctx, read(tps_ptr), ref_of(subs), id.line, id.column)
                    return substitute_type(sig.return_type, ref_of(subs))
                return sig.return_type
            _:
                return types.Type.ty_error


## Check an argument list against a resolved function signature: arity always,
## and positional argument types when the call is all-positional (named
## arguments may be reordered, so positional type checking is unsound there).
## `args` is the original call argument expression list, used to gate
## narrowing-int checks on numeric literal sources (mirroring Ruby's
## exact_compile_time_numeric_compatibility?).
function check_signature_call(ctx: ref[Context], display_name: str, sig: FnSig, args: span[ast.Argument], arg_types: span[types.Type], any_named: bool, line: ptr_uint, column: ptr_uint) -> void:
    if sig.is_extern:
        return
    if not sig.is_variadic and (arg_types.len > sig.params.len or arg_types.len < sig.required_count):
        report(ctx, line, column, arity_message(display_name, sig.required_count, arg_types.len))
        return
    if any_named:
        return
    var i: ptr_uint = 0
    while i < arg_types.len:
        unsafe:
            let atype = read(arg_types.data + i)
            let pe = read(sig.params.data + i)
            var arg_expr: ptr[ast.Expr]? = null
            if i < args.len:
                arg_expr = read(args.data + i).arg_value
            if incompatible_value(pe.ty, atype, arg_expr):
                report(ctx, line, column, argument_message(pe.name, display_name, pe.ty, atype))
        i += 1



# =============================================================================
#  Diagnostic messages
# =============================================================================

function return_mismatch_message(expected: types.Type, got: types.Type) -> str:
    return diag.return_mismatch_message(expected, got)


function local_mismatch_message(expected: types.Type, got: types.Type) -> str:
    return diag.local_mismatch_message(expected, got)


function assign_message(target: types.Type, value: types.Type) -> str:
    return diag.assign_message(target, value)


function assign_to_let_message(name: str) -> str:
    return diag.assign_to_let_message(name)


function editable_on_immutable_message(name: str, method: str) -> str:
    return diag.editable_on_immutable_message(name, method)


function missing_return_message(name: str) -> str:
    return diag.missing_return_message(name)


function def_assign_message(name: str) -> str:
    return diag.def_assign_message(name)


function missing_cases_message(type_name: str, cases: str) -> str:
    return diag.missing_cases_message(type_name, cases)


function integer_wildcard_message(type_name: str) -> str:
    return diag.integer_wildcard_message(type_name)


function str_wildcard_message() -> str:
    return diag.str_wildcard_message()


function dup_case_message(type_name: str, member: str) -> str:
    return diag.dup_case_message(type_name, member)


function dup_value_message(value: int) -> str:
    return diag.dup_value_message(value)


function int_to_str(value: int) -> str:
    return diag.int_to_str(value)


function neg_int_to_str(value: int) -> str:
    return diag.neg_int_to_str(value)


function condition_message(keyword: str, got: types.Type) -> str:
    return diag.condition_message(keyword, got)


function arity_message(name: str, expected: ptr_uint, got: ptr_uint) -> str:
    return diag.arity_message(name, expected, got)


function unknown_member_message(kind: str, type_name: str, member: str) -> str:
    return diag.unknown_member_message(kind, type_name, member)


function missing_method_message(type_name: str, iface_name: str, method: str) -> str:
    return diag.missing_method_message(type_name, iface_name, method)


function method_mismatch_message(type_name: str, iface_name: str, method: str) -> str:
    return diag.method_mismatch_message(type_name, iface_name, method)


function hook_missing_message(hook_name: str, type_name: str) -> str:
    return diag.hook_missing_message(hook_name, type_name)


function constraint_unsatisfied_message(type_name: str, iface_name: str) -> str:
    return diag.constraint_unsatisfied_message(type_name, iface_name)


function argument_message(param_name: str, fn_name: str, expected: types.Type, got: types.Type) -> str:
    return diag.argument_message(param_name, fn_name, expected, got)


function uint_to_str(value: ptr_uint) -> str:
    return diag.uint_to_str(value)


function named_args_required_message(struct_name: str) -> str:
    return diag.named_args_required_message(struct_name)


function duplicate_field_message(struct_name: str, field: str) -> str:
    return diag.duplicate_field_message(struct_name, field)


function field_type_mismatch_message(struct_name: str, field: str, expected: types.Type, got: types.Type) -> str:
    return diag.field_type_mismatch_message(struct_name, field, expected, got)


function dup_param_message(func_name: str, param: str) -> str:
    return diag.dup_param_message(func_name, param)


function reserved_param_message(func_name: str, param: str) -> str:
    return diag.reserved_param_message(func_name, param)


function reserved_local_message(name: str) -> str:
    return diag.reserved_local_message(name)


function make_task_type(inner: types.Type) -> types.Type:
    var args = vec.Vec[types.Type].create()
    args.push(inner)
    return types.Type.ty_generic(name = "Task", args = args.as_span())


function register_task_methods(ctx: ref[Context]) -> void:
    ctx.method_keys.set(method_key("Task", "take_result"), true)
    ctx.method_keys.set(method_key("Task", "release"), true)
    ctx.method_keys.set(method_key("Task", "set_waiter"), true)
    ctx.method_keys.set(method_key("Task", "cancel"), true)
    ctx.method_keys.set(method_key("Task", "ready"), true)
