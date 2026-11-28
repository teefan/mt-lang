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
import std.mem.heap as heap
import std.str
import std.string as string
import std.vec as vec

import mtc.parser.ast as ast
import mtc.semantic.types as types
import mtc.semantic.preassign as preassign
import mtc.semantic.call_arguments as call_arguments
import mtc.semantic.member_calls as member_calls
import mtc.semantic.type_compatibility as compat
import mtc.semantic.expressions as sem_exprs
import mtc.semantic.control_flow.builder as flow_builder
import mtc.semantic.control_flow.definite_assignment as da
import mtc.semantic.control_flow.graph as flow_graph
import mtc.semantic.diagnostics as diag
import mtc.semantic.emit_expansion as emit_ex
import mtc.semantic.scope as sscope
import mtc.c_naming as naming

## When false, the analyzer skips the fact maps that only the LSP consumes
## (`flow_types`, `local_decl_types`, `destructure_types`, …).  The compiler
## pipeline clears it before analysis; the LSP and the in-language semantic
## tests keep the default so their fact assertions remain valid.
var tooling_facts_enabled: bool = true


public function set_tooling_facts(enabled: bool) -> void:
    tooling_facts_enabled = enabled


## True when `--strict-types` asks the analyzer to report assignments that are
## accepted only by the permissive assignability fallback.  Off by default so
## normal builds, diagnostics, and goldens are unchanged.
var strict_assignability_enabled: bool = false


public function set_strict_assignability(enabled: bool) -> void:
    strict_assignability_enabled = enabled


public struct SemanticDiagnostic:
    line: ptr_uint
    column: ptr_uint
    ## Character length of the offending token (0 when the report site has none);
    ## the LSP falls back to 1, matching the Ruby `Diagnostic#length` default.
    length: ptr_uint
    message: str
    severity: str
    code: str

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

## One imported type's members, keyed `<module>.<Type>`: its fields (a struct's or
## union's) and its methods.  The analysis carries only the current module's
## tables, so this is the record the LSP's dot-receiver completion reads to list
## `imported.Node.`'s members.
public struct ImportedTypeMembers:
    fields: span[FieldEntry]
    methods: map_mod.Map[str, FnSig]
    ## The `methods` keys in registration order, because a map iterates in
    ## bucket order and the LSP's completion merge needs the host's per-type
    ## registration order.
    method_order: vec.Vec[str]
    ## True when the module *declares* the type (the host's
    ## `module_binding.types`); a method-only entry from a module that merely
    ## extends the type is not a type receiver the host resolves.
    declared: bool

## One name of a destructuring `let (a, b) = …` binding and the type the
## binding carries (the host's per-name scope binding): the tuple element at the
## name's position, or the struct field at that position.  The declaration line
## identifies the statement, so the LSP can answer a hover on a destructured
## name the way it answers one on a plain local.
public struct DestructureTypeEntry:
    line: ptr_uint
    name: str
    ty: types.Type

## A bare function name used as a *value* where a function/proc type is
## expected (an argument to a callback parameter): the host's
## `callable_value_identifier_sites`, keyed by the identifier's position.  The
## token scanner renders `function` for those sites alone — a name that resolves
## to a binding, or that is merely a function in the module, is not one.
public struct CallableValueSite:
    line: ptr_uint
    column: ptr_uint

## One identifier use resolved to a scope binding: the identifier's node key
## and the binding's id, in resolution order (the host's
## `binding_resolution.identifier_binding_ids`).
public struct BindingSite:
    node: ptr_uint
    id: ptr_uint

## One binding id's type, in allocation order (the host's
## `binding_resolution.binding_types`).
public struct BindingTypeEntry:
    id: ptr_uint
    ty: types.Type

## An `as name` variant match-arm binding: the arm's declaration position and
## the payload type the binding carries, so the LSP can hover it the way the
## host's scope snapshot answers.
public struct ArmBindingEntry:
    line: ptr_uint
    name: str
    ty: types.Type

## The resolved receiver type of one non-static `extending` method — the
## implicit `this` binding — keyed by the method's line, so the LSP resolves
## `this.`'s members the way the host's scope binding does.
public struct ThisTypeEntry:
    line: ptr_uint
    ty: types.Type

public struct EventInfo:
    name: str
    capacity: int
    payload_type: ptr[ast.TypeRef]?
    ## The declaring struct's sanitized owner path (`Window`,
    ## `Container_Inner`), empty for a module-level event.  Mirrors the host's
    ## `Types::Event#owner_type_name`, which the linkage uses to keep two
    ## same-named events in different structs distinct.
    owner_type_name: str

## The public export surface of a module, consumed by importers for cross-module
## name resolution.  Built from an Analysis by the loader's binder
## (mtc.loader.binder); the type lives here to keep the analyzer free of a
## dependency on the loader.  Exposes public functions (call checks), structs
## (construction field checks), value types (const/var), and enum/variant static
## A directional (`in`/`out`/`inout`) FFI parameter: its passing mode and
## declared name (for the `directional-ffi-arg` hint message).
public struct DirectionalParamInfo:
    mode_label: str
    name: str

## A recorded `directional-ffi-arg` site: the call's *callee* expression
## pointer (so the linter emits at the call's visit, in the host's order), the
## argument expression pointer (for the warning span), and the message parts.
public struct DirectionalFfiSite:
    callee_key: ptr_uint
    argument_key: ptr_uint
    function_name: str
    parameter_name: str
    mode_label: str

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
    ## The `method_sigs` keys in registration order (`<Type>.<method>`), because
    ## a map iterates in bucket order and the LSP's completion merge needs the
    ## host's per-type registration order.
    method_order: vec.Vec[str]
    interfaces: map_mod.Map[str, span[ast.InterfaceMethod]]
    implemented: map_mod.Map[str, span[ast.QualifiedName]]
    match_case_names: map_mod.Map[str, span[str]]
    ## A static member type's member names — enum members, flags members and
    ## variant arms — the host's `type.members`, which completion lists for a
    ## type receiver.  Flags members appear only here: flags are not matchable,
    ## so `match_case_names` omits them.
    member_names: map_mod.Map[str, span[str]]
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
    ## The resolved payload fields of each exported variant arm, keyed by the
    ## payload name (`Decl_decl_var`): an importer's `match … as name` binding
    ## carries the host's `Types::VariantArmPayload` fields.
    variant_arm_fields: map_mod.Map[str, span[types.PayloadField]]
    ## Declared type parameters per exported method (`Arena.alloc` -> `[T]`), so
    ## an importer resolves `x.method[T](…)` on an imported receiver.
    method_type_params: map_mod.Map[str, span[ast.TypeParam]]
    ## Declared generic parameters per exported function (`iter_filter` -> `[T]`),
    ## so an imported call can infer its type arguments from the arguments.
    function_type_params: map_mod.Map[str, span[ast.TypeParam]]
    ## Per foreign function name, the `out`/`inout` parameter indices, so an
    ## imported `alias.fn(...)` call can record its mutating identifier
    ## arguments (the host's `mutating_argument_identifier_ids`).
    mutating_param_indices: map_mod.Map[str, map_mod.Map[ptr_uint, bool]]
    ## Per foreign function name, the `in`/`out`/`inout` parameters (index ->
    ## mode/name), so an importer's `alias.fn(...)` call can record
    ## `directional-ffi-arg` sites (the host's binding `passing_mode`).
    directional_param_modes: map_mod.Map[str, map_mod.Map[ptr_uint, DirectionalParamInfo]]
    private_interfaces: map_mod.Map[str, span[ast.InterfaceMethod]]

## One entry of the analyzer's refinement record — the self's analogue of the
## host's completion-snapshot bindings: the type a local has at a statement
## boundary.  `at` packs the recording statement's position as
## `line * 1000000 + column` (1-based line, 0-based column).  An entry with an
## empty `name` is a barrier: entries recorded before it belong to an earlier
## function body and do not apply past it; `cleared` marks a binding that left
## scope, so the consumer falls back to its declaration.
public struct FlowTypeEntry:
    at: ptr_uint
    name: str
    ty: types.Type
    cleared: bool


## A name/type pair of the snapshot scratch buffer.
struct FlowName:
    name: str
    ty: types.Type

public struct Context:
    value_names: map_mod.Map[str, bool]
    type_names: map_mod.Map[str, bool]
    type_aliases: map_mod.Map[str, ptr[ast.TypeRef]]
    type_alias_types: map_mod.Map[str, types.Type]
    alias_types: map_mod.Map[str, types.Type]
    structs: map_mod.Map[str, span[FieldEntry]]
    unions: map_mod.Map[str, span[FieldEntry]]
    method_keys: map_mod.Map[str, bool]
    method_sigs: map_mod.Map[str, FnSig]
    ## The `method_sigs` keys in registration order (see `ModuleBinding`).
    method_order: vec.Vec[str]
    ## The seeded prelude modules' method signatures (`Option.unwrap`,
    ## `Result.unwrap`), consulted after the module's own table.  They are not
    ## exported on the `Analysis`: the LSP resolves a member's declaration from
    ## the receiver's own module, which a prelude method does not have.
    prelude_method_sigs: map_mod.Map[str, FnSig]
    static_member_types: map_mod.Map[str, bool]
    match_case_types: map_mod.Map[str, bool]
    match_case_names: map_mod.Map[str, span[str]]
    ## See `ModuleBinding.member_names`.
    member_names: map_mod.Map[str, span[str]]
    ## The static-member types that are *variants* rather than enums or flags
    ## (`Option`, `Result`, a declared `variant`): an arm resolves the
    ## constructor form `Type.arm(field: T)`, never an enum member's value.
    variant_types: map_mod.Map[str, bool]
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
    ## See `ThisTypeEntry`: the implicit `this` type of each non-static
    ## extending method.
    this_types: vec.Vec[ThisTypeEntry]
    ## The module names whose method tables the LSP merges for a receiver type,
    ## in the host's `facts.imports` key order: the file's imports in source
    ## order, then the seeded prelude modules.
    import_order: vec.Vec[str]
    ## Identifier arguments passed to an `out`/`inout` foreign parameter, with
    ## the argument's line: the call mutates that binding (the host's
    ## `mutating_argument_identifier_ids`), which the linter's prefer-let needs.
    mutating_argument_sites: vec.Vec[EditableSite]
    ## Identifier arguments the host's `array_to_span_call_argument_compatible?`
    ## records: an array (or `str_buffer`) passed where a `span` is expected is
    ## a mutable lvalue (the host's `mutable_lvalue_argument_identifier_ids`),
    ## so prefer-let must treat the binding as reassigned.
    mutable_lvalue_sites: vec.Vec[EditableSite]
    ## Per foreign function name, the parameter indices carrying an `out`/`inout`
    ## passing mode, so a call site can record its mutating identifier arguments.
    mutating_param_indices: map_mod.Map[str, map_mod.Map[ptr_uint, bool]]
    ## Per foreign function name, every `in`/`out`/`inout` parameter's mode and
    ## name: a call whose argument re-states the direction (`out x`,
    ## `ptr_of(x)`, `ptr[X]<-x`) records a `directional-ffi-arg` hint site.
    directional_param_modes: map_mod.Map[str, map_mod.Map[ptr_uint, DirectionalParamInfo]]
    ## Recorded `directional-ffi-arg` sites for this module, emitted by the
    ## linter at the call's visit.
    directional_ffi_sites: vec.Vec[DirectionalFfiSite]
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
    ## See `strict_assignability_enabled`.
    strict_assignability: bool
    ## See `tooling_facts_enabled`.
    tooling_facts: bool
    types: map_mod.Map[str, types.Type]
    attribute_apps: map_mod.Map[str, vec.Vec[ast.AttributeApplication]]
    field_attribute_apps: map_mod.Map[str, vec.Vec[ast.AttributeApplication]]
    unsafe_depth: int
    ## The enclosing `unsafe:` statements/expressions' lines (the host's
    ## `@unsafe_statement_lines`): an operation that requires unsafe inside one
    ## of them records that node's line in `required_unsafe_lines`, which is what
    ## the linter's `redundant-unsafe` rule reads.
    unsafe_statement_lines: vec.Vec[ptr_uint]
    required_unsafe_lines: map_mod.Map[ptr_uint, bool]
    inside_async: bool
    resolved_expr_types: map_mod.Map[ptr_uint, types.Type]
    resolved_call_kinds: map_mod.Map[ptr_uint, str]
    ## The receiver type of a member access whose receiver is not a plain
    ## name/field chain (`read(p).method`, `make().field`, `a[0].b`), keyed by
    ## the member name's position (`binding_key`).  The LSP's text-based
    ## receiver walk cannot resolve those, so it reads the inferred type here.
    member_receiver_types: map_mod.Map[ptr_uint, types.Type]
    ## The host's `expected_type` argument while inferring a value expression in
    ## a declared position (a local's annotation, an assignment target, a
    ## return type): an if/match expression whose branches all fit it takes
    ## that type (`let n: uint = if p: uint<-x else: 0` is `uint`, not the
    ## branches' numeric common type).  `ty_error` when there is no context.
    expected_type_hint: types.Type
    ## The enclosing statement's anchor: a `LocalDecl`'s binding name, a
    ## `return` keyword, an expression statement's first line.  The host's
    ## positionless expression checks (an if-expression condition) report at
    ## the current statement, not at the nested expression.
    statement_line: ptr_uint
    statement_column: ptr_uint
    ## The *declared* type of an annotated local, keyed by its declaration line:
    ## a local with an annotation has no inferred initializer type, so this is
    ## the only record of its type (the host reads the same type off its scope
    ## binding).  Consumers outside the analysis pass — the LSP's `this`/local
    ## member resolution — resolve a local's type through it.
    local_decl_types: map_mod.Map[ptr_uint, types.Type]
    ## See `Analysis.destructure_types`.
    destructure_types: vec.Vec[DestructureTypeEntry]
    ## The declared payload fields of a variant arm, keyed by the payload name
    ## (`Option_some`, `Decl_decl_var`): the host's `VariantArmPayload` is the
    ## arm's struct, so an `as name` binding carries these fields with the
    ## scrutinee's type arguments substituted.  Covers the prelude variants and
    ## every variant declared in the module; imported variants come from the
    ## module binding (`ModuleBinding.variant_arm_fields`).
    arm_payload_field_types: map_mod.Map[str, span[types.PayloadField]]
    ## The declared type-parameter names per variant (`Option` -> `[T]`,
    ## `Result` -> `[T, E]`), the substitution domain for an arm payload.
    variant_param_names: map_mod.Map[str, span[str]]
    ## See `Analysis.arm_binding_types`.
    arm_binding_types: vec.Vec[ArmBindingEntry]
    ## See `Analysis.callable_value_sites`.
    callable_value_sites: vec.Vec[CallableValueSite]
    ## Depth of the builtin calls whose arguments are *not* values
    ## (`callable_of`, `field_of`, `has_attribute`, …): a bare function name
    ## inside one is the host's special evaluation, which records no
    ## callable-value site.
    callable_site_suppression: int
    ## The current function body's CFG, its solved non-null flow (the host's
    ## `@nullability_flow_result`), and the refinement record the LSP reads.
    flow_cfg: flow_builder.Cfg
    flow_graph: flow_graph.CfgGraph
    flow: flow_graph.NullabilityFlow
    flow_active: bool
    flow_types: vec.Vec[FlowTypeEntry]
    flow_recorded: map_mod.Map[str, types.Type]
    flow_scratch: vec.Vec[FlowName]
    ## Constants *declared* by this module (own names only).  `const_values`
    ## also carries the qualified imported aliases used for compile-time
    ## folding; exporting those would make every importer re-prefix them, so the
    ## names compound along the import graph.
    declared_const_values: map_mod.Map[str, ptr[ast.Expr]]
    const_values: map_mod.Map[str, ptr[ast.Expr]]
    declared_attributes: map_mod.Map[str, span[str]]
    diagnostics: vec.Vec[SemanticDiagnostic]
    uses_parallel_for: bool
    event_types: map_mod.Map[str, EventInfo]
    ## The next host-shaped binding id (1-based; `milkTea/debugInfo`'s Bindings
    ## section renders the allocation order).  See `allocate_binding_id`.
    next_binding_id: ptr_uint
    ## Identifier uses resolved to a scope binding, in resolution order.
    identifier_sites: vec.Vec[BindingSite]
    ## Declaration nodes (params, locals, match arms, for/else bindings) with
    ## their binding ids, in declaration order.
    declaration_sites: vec.Vec[BindingSite]
    ## Every binding's type, keyed by id (the host's `@binding_type_by_id`);
    ## the debug dump materializes the entries in id order.
    binding_type_by_id: map_mod.Map[ptr_uint, types.Type]
    ## The host's `@preassigned_local_binding_ids`: the current body's binding
    ## ids, keyed by `binding_key` (`line * 1000000 + column`).  Reset per body.
    preassigned_ids: map_mod.Map[ptr_uint, ptr_uint]
    ## Declaration-pass records, keyed by the function/method node key: the
    ## first parameter's id, and an instance method's `this` id.
    param_id_base: map_mod.Map[ptr_uint, ptr_uint]
    this_binding_ids: map_mod.Map[ptr_uint, ptr_uint]
    ## Module-level values (const/var/event) with their binding ids; an
    ## identifier use of one records like a scope binding does.
    value_binding_ids: map_mod.Map[str, ptr_uint]
    ## Module-declared type names in registration order (the host's `facts.types`
    ## order after the builtin and prelude blocks).
    module_type_order: vec.Vec[str]
    ## Interface names in declaration order (the host's `facts.interfaces`
    ## order).
    interface_order: vec.Vec[str]
    ## Each extending method's resolved receiver type, keyed like `method_sigs`
    ## (`milkTea/debugInfo`'s Methods section renders `on <receiver>:` and
    ## `fn <receiver>.<name>`).
    method_receiver_types: map_mod.Map[str, types.Type]
    ## Each resolved import's exported-symbol count (types + functions + values),
    ## for the debug dump's Imports block.
    import_symbol_counts: map_mod.Map[str, ptr_uint]
    ## True while checking a body the host only name-checks (a generic body):
    ## no ids are allocated and no sites recorded there.
    suppress_binding_records: bool
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
    ## See `ModuleBinding.method_order`: the LSP's completion merge reads this.
    method_order: vec.Vec[str]
    static_member_types: map_mod.Map[str, bool]
    match_case_names: map_mod.Map[str, span[str]]
    ## See `ModuleBinding.member_names`: the LSP's type-receiver completion
    ## lists these (flags members included).
    member_names: map_mod.Map[str, span[str]]
    ## See `Context.variant_types`.
    variant_types: map_mod.Map[str, bool]
    interfaces: map_mod.Map[str, span[ast.InterfaceMethod]]
    resolved_expr_types: map_mod.Map[ptr_uint, types.Type]
    resolved_call_kinds: map_mod.Map[ptr_uint, str]
    ## See `Context.member_receiver_types`.
    member_receiver_types: map_mod.Map[ptr_uint, types.Type]
    ## See `Context.local_decl_types`.
    local_decl_types: map_mod.Map[ptr_uint, types.Type]
    ## See `Context.destructure_types`.
    destructure_types: vec.Vec[DestructureTypeEntry]
    ## The `as name` variant match-arm bindings with their payload types, so the
    ## LSP resolves an arm binding's hover (declaration and use).
    arm_binding_types: vec.Vec[ArmBindingEntry]
    ## See `Context.arm_payload_field_types`: the module's declared variant arm
    ## payload fields, exported through `ModuleBinding.variant_arm_fields`.
    arm_payload_field_types: map_mod.Map[str, span[types.PayloadField]]
    ## See `Context.method_type_params`: the module's declared methods' type
    ## parameters, exported through `ModuleBinding.method_type_params`.
    method_type_params: map_mod.Map[str, span[ast.TypeParam]]
    ## See `Context.callable_value_sites`: the bare function names used as
    ## values, which the token scanner renders `function`.
    callable_value_sites: vec.Vec[CallableValueSite]
    ## See `Context.flow_types`: the local refinement record the LSP resolves a
    ## hover's type through.
    flow_types: vec.Vec[FlowTypeEntry]
    declared_const_values: map_mod.Map[str, ptr[ast.Expr]]
    const_values: map_mod.Map[str, ptr[ast.Expr]]
    module_name: str
    module_kind: ast.ModuleKind
    ## The loader-backed import table this analysis resolved against (borrowed).
    ## A consumer that re-analyzes an edited source (the fix engine) can reuse it
    ## instead of dropping cross-module method kinds.
    imported_modules: ptr[map_mod.Map[str, ModuleBinding]]?
    unsafe_statement_lines: vec.Vec[ptr_uint]
    ## See `ImportedTypeMembers`: the imported types' fields and methods.
    imported_type_members: map_mod.Map[str, ImportedTypeMembers]
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
    ## See `ThisTypeEntry`: the implicit `this` type of each non-static
    ## extending method, which the LSP resolves a `this.` receiver through.
    this_types: vec.Vec[ThisTypeEntry]
    ## See `Context.import_order`: the host's `facts.imports` key order.
    import_order: vec.Vec[str]
    ## The declarations of the `when` branches selected for the target platform,
    ## which the host's expanded AST carries in place; the LSP merges them into
    ## its declaration walks by line.
    when_declarations: span[ast.Decl]
    ## Identifier arguments passed to `out`/`inout` foreign parameters, with
    ## their lines (the host's `mutating_argument_identifier_ids`).
    mutating_argument_sites: vec.Vec[EditableSite]
    ## Identifier arguments recorded by the array/`str_buffer`→`span` coercion
    ## (the host's `mutable_lvalue_argument_identifier_ids`): the callee may
    ## write through the alias, so prefer-let treats the binding as reassigned.
    mutable_lvalue_sites: vec.Vec[EditableSite]
    ## Per foreign function name, the parameter indices carrying an `out`/`inout`
    ## passing mode (exported so importing modules can record mutating arguments
    ## of `alias.fn(...)` calls too).
    mutating_param_indices: map_mod.Map[str, map_mod.Map[ptr_uint, bool]]
    ## Per foreign function name, the `in`/`out`/`inout` parameters (exported so
    ## importing modules can record `directional-ffi-arg` sites).
    directional_param_modes: map_mod.Map[str, map_mod.Map[ptr_uint, DirectionalParamInfo]]
    ## The module's recorded `directional-ffi-arg` sites.
    directional_ffi_sites: vec.Vec[DirectionalFfiSite]
    # The module's source file path, propagated so lowering can emit `#line`
    # directives that map generated C back to the .mt source (debug builds).
    source_path: str
    ## See `BindingSite`: identifier uses → binding id, in resolution order.
    identifier_sites: vec.Vec[BindingSite]
    ## See `BindingSite`: declaration nodes → binding id, in declaration order.
    declaration_sites: vec.Vec[BindingSite]
    ## See `BindingTypeEntry`: every binding's type, in allocation order.
    binding_types: vec.Vec[BindingTypeEntry]
    ## See `Context.value_binding_ids`: module values → binding ids.
    value_binding_ids: map_mod.Map[str, ptr_uint]
    ## See `Context.param_id_base` / `Context.this_binding_ids`: declaration
    ## node keys → the first parameter's id / an instance method's `this` id.
    param_id_base: map_mod.Map[ptr_uint, ptr_uint]
    this_binding_ids: map_mod.Map[ptr_uint, ptr_uint]
    ## See `Context.module_type_order`: module-declared types in registration
    ## order.
    module_type_order: vec.Vec[str]
    ## See `Context.interface_order`.
    interface_order: vec.Vec[str]
    ## See `Context.method_receiver_types`.
    method_receiver_types: map_mod.Map[str, types.Type]
    ## See `Context.import_symbol_counts`.
    import_symbol_counts: map_mod.Map[str, ptr_uint]


public function check_source_file(file: ast.SourceFile) -> Analysis:
    return check_module(file, null, "", "")


## Semantically check a module, resolving cross-module references against the
## given import bindings (keyed by module name; may be null for single-file
## checks).  `imported_modules` is borrowed, not owned.
public function check_module(
    file: ast.SourceFile,
    imported_modules: ptr[map_mod.Map[str, ModuleBinding]]?,
    module_name: str,
    source_path: str
) -> Analysis:
    return check_module_opts(file, imported_modules, module_name, source_path, false)


## `check_module` with the LSP's unresolved-import handling: aliases whose
## module did not resolve are left unbound (the host's `allow_missing_imports`
## behaviour), so uses of them are reported as unknown names.
public function check_module_requiring_resolved_imports(
    file: ast.SourceFile,
    imported_modules: ptr[map_mod.Map[str, ModuleBinding]]?,
    module_name: str,
    source_path: str
) -> Analysis:
    return check_module_opts(file, imported_modules, module_name, source_path, true)


public function check_module_opts(
    file: ast.SourceFile,
    imported_modules: ptr[map_mod.Map[str, ModuleBinding]]?,
    module_name: str,
    source_path: str,
    require_resolved_imports: bool
) -> Analysis:
    # The caller owns the import table and must keep it address-stable for as
    # long as the analysis lives (the loader heap-allocates it and the fix
    # engine reuses it).  Copying the map here would snapshot its bucket array,
    # which `set` frees when the table grows.
    var ctx = create_context(module_name, imported_modules, require_resolved_imports)
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
    collect_variant_arm_fields(ref_of(ctx), source.declarations)
    collect_variant_arm_fields(ref_of(ctx), when_extra)
    check_attribute_applications(ref_of(ctx), source)
    collect_extending_methods(ref_of(ctx), source)
    # The host allocates its binding ids across two declaration phases — values
    # (`declare_top_level_values`) then function/method parameters
    # (`declare_functions`) — before any body is checked.
    allocate_declaration_binding_ids(ref_of(ctx), source.declarations, when_extra)
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
        method_order = ctx.method_order,
        static_member_types = ctx.static_member_types,
        match_case_names = ctx.match_case_names,
        member_names = ctx.member_names,
        variant_types = ctx.variant_types,
        interfaces = ctx.interfaces,
        resolved_expr_types = ctx.resolved_expr_types,
        resolved_call_kinds = ctx.resolved_call_kinds,
        member_receiver_types = ctx.member_receiver_types,
        local_decl_types = ctx.local_decl_types,
        destructure_types = ctx.destructure_types,
        arm_binding_types = ctx.arm_binding_types,
        arm_payload_field_types = ctx.arm_payload_field_types,
        method_type_params = ctx.method_type_params,
        callable_value_sites = ctx.callable_value_sites,
        flow_types = ctx.flow_types,
        declared_const_values = ctx.declared_const_values,
        const_values = ctx.const_values,
        module_name = module_name,
        module_kind = file.module_kind,
        imported_modules = ctx.imported_modules,
        unsafe_statement_lines = required_unsafe_line_list(ref_of(ctx)),
        # Imported type members are read only by the linter and the LSP
        # (completion, inlay hints, navigation) - never by lowering or the C
        # backend - so a plain compile leaves the map empty instead of
        # collecting ~29 MB of records per module graph.
        imported_type_members = if ctx.tooling_facts: collect_imported_type_members(ref_of(ctx)) else: map_mod.Map[
            str,
            ImportedTypeMembers
        ].create(),
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
        this_types = ctx.this_types,
        import_order = ctx.import_order,
        when_declarations = when_extra,
        mutating_argument_sites = ctx.mutating_argument_sites,
        mutable_lvalue_sites = ctx.mutable_lvalue_sites,
        mutating_param_indices = ctx.mutating_param_indices,
        directional_param_modes = ctx.directional_param_modes,
        directional_ffi_sites = ctx.directional_ffi_sites,
        source_path = source_path,
        identifier_sites = ctx.identifier_sites,
        declaration_sites = ctx.declaration_sites,
        binding_types = materialize_binding_types(ref_of(ctx)),
        value_binding_ids = ctx.value_binding_ids,
        param_id_base = ctx.param_id_base,
        this_binding_ids = ctx.this_binding_ids,
        module_type_order = ctx.module_type_order,
        interface_order = ctx.interface_order,
        method_receiver_types = ctx.method_receiver_types,
        import_symbol_counts = ctx.import_symbol_counts,
    )


function create_context(
    module_name: str,
    imported_modules: ptr[map_mod.Map[str, ModuleBinding]]?,
    require_resolved_imports: bool
) -> Context:
    return Context(
        value_names = map_mod.Map[str, bool].create(),
        type_names = map_mod.Map[str, bool].create(),
        type_aliases = map_mod.Map[str, ptr[ast.TypeRef]].create(),
        type_alias_types = map_mod.Map[str, types.Type].create(),
        alias_types = map_mod.Map[str, types.Type].create(),
        structs = map_mod.Map[str, span[FieldEntry]].create(),
        unions = map_mod.Map[str, span[FieldEntry]].create(),
        method_keys = map_mod.Map[str, bool].create(),
        method_sigs = map_mod.Map[str, FnSig].create(),
        method_order = vec.Vec[str].create(),
        prelude_method_sigs = map_mod.Map[str, FnSig].create(),
        static_member_types = map_mod.Map[str, bool].create(),
        match_case_types = map_mod.Map[str, bool].create(),
        match_case_names = map_mod.Map[str, span[str]].create(),
        member_names = map_mod.Map[str, span[str]].create(),
        variant_types = map_mod.Map[str, bool].create(),
        functions = map_mod.Map[str, FnSig].create(),
        value_types = map_mod.Map[str, types.Type].create(),
        interfaces = map_mod.Map[str, span[ast.InterfaceMethod]].create(),
        extending_canonical_names = map_mod.Map[str, str].create(),
        type_params = map_mod.Map[str, span[ast.TypeParamConstraint]].create(),
        type_param_names = map_mod.Map[str, span[ast.TypeParam]].create(),
        editable_receiver_sites = vec.Vec[EditableSite].create(),
        this_types = vec.Vec[ThisTypeEntry].create(),
        import_order = vec.Vec[str].create(),
        mutating_argument_sites = vec.Vec[EditableSite].create(),
        mutable_lvalue_sites = vec.Vec[EditableSite].create(),
        mutating_param_indices = map_mod.Map[str, map_mod.Map[ptr_uint, bool]].create(),
        directional_param_modes = map_mod.Map[str, map_mod.Map[ptr_uint, DirectionalParamInfo]].create(),
        directional_ffi_sites = vec.Vec[DirectionalFfiSite].create(),
        suppressed_type_names = map_mod.Map[str, bool].create(),
        function_type_params = map_mod.Map[str, span[ast.TypeParam]].create(),
        method_type_params = map_mod.Map[str, span[ast.TypeParam]].create(),
        implemented = map_mod.Map[str, span[ast.QualifiedName]].create(),
        import_aliases = map_mod.Map[str, str].create(),
        imported_modules = imported_modules,
        require_resolved_imports = require_resolved_imports,
        strict_assignability = strict_assignability_enabled,
        tooling_facts = tooling_facts_enabled,
        types = map_mod.Map[str, types.Type].create(),
        attribute_apps = map_mod.Map[str, vec.Vec[ast.AttributeApplication]].create(),
        field_attribute_apps = map_mod.Map[str, vec.Vec[ast.AttributeApplication]].create(),
        unsafe_depth = 0,
        unsafe_statement_lines = vec.Vec[ptr_uint].create(),
        required_unsafe_lines = map_mod.Map[ptr_uint, bool].create(),
        inside_async = false,
        resolved_expr_types = map_mod.Map[ptr_uint, types.Type].create(),
        resolved_call_kinds = map_mod.Map[ptr_uint, str].create(),
        member_receiver_types = map_mod.Map[ptr_uint, types.Type].create(),
        expected_type_hint = types.Type.ty_error,
        statement_line = 0,
        statement_column = 0,
        local_decl_types = map_mod.Map[ptr_uint, types.Type].create(),
        destructure_types = vec.Vec[DestructureTypeEntry].create(),
        arm_payload_field_types = map_mod.Map[str, span[types.PayloadField]].create(),
        arm_binding_types = vec.Vec[ArmBindingEntry].create(),
        callable_value_sites = vec.Vec[CallableValueSite].create(),
        callable_site_suppression = 0,
        variant_param_names = map_mod.Map[str, span[str]].create(),
        flow_cfg = flow_builder.empty_cfg(),
        flow_graph = flow_graph.empty_graph(),
        flow = flow_graph.NullabilityFlow(state = null, row_size = 0, node_count = 0),
        flow_active = false,
        flow_types = vec.Vec[FlowTypeEntry].create(),
        flow_recorded = map_mod.Map[str, types.Type].create(),
        flow_scratch = vec.Vec[FlowName].create(),
        declared_const_values = map_mod.Map[str, ptr[ast.Expr]].create(),
        const_values = map_mod.Map[str, ptr[ast.Expr]].create(),
        declared_attributes = map_mod.Map[str, span[str]].create(),
        diagnostics = vec.Vec[SemanticDiagnostic].create(),
        uses_parallel_for = false,
        event_types = map_mod.Map[str, EventInfo].create(),
        next_binding_id = 1,
        identifier_sites = vec.Vec[BindingSite].create(),
        declaration_sites = vec.Vec[BindingSite].create(),
        binding_type_by_id = map_mod.Map[ptr_uint, types.Type].create(),
        preassigned_ids = map_mod.Map[ptr_uint, ptr_uint].create(),
        param_id_base = map_mod.Map[ptr_uint, ptr_uint].create(),
        this_binding_ids = map_mod.Map[ptr_uint, ptr_uint].create(),
        value_binding_ids = map_mod.Map[str, ptr_uint].create(),
        module_type_order = vec.Vec[str].create(),
        interface_order = vec.Vec[str].create(),
        method_receiver_types = map_mod.Map[str, types.Type].create(),
        import_symbol_counts = map_mod.Map[str, ptr_uint].create(),
        suppress_binding_records = false,
        module_name = module_name,
    )

# =============================================================================
#  Binding ids — the host's `@next_binding_id` allocation order and the
#  identifier/declaration/type records its `binding_resolution` snapshot carries
#  (`milkTea/debugInfo`'s Bindings section renders them).
# =============================================================================

## A node key for bindings that have no stable AST pointer (a `let … else`
## binding, a for binding): the source position packs into one integer.  Both
## the preassign walk and the check-time binding site compute the same key.
public function binding_key(line: ptr_uint, column: ptr_uint) -> ptr_uint:
    return line * 1000000 + column


## The host's `allocate_binding_id`: ids start at 1 and increase in allocation
## order.
public function allocate_binding_id(ctx: ref[Context]) -> ptr_uint:
    let id = ctx.next_binding_id
    ctx.next_binding_id += 1
    return id


## Record a binding's type (the host's `@binding_type_by_id[id] = …` at
## `value_binding`).  A re-recording for the same id overwrites; the id order
## comes from allocation, so the rendered order stays stable.
public function record_binding_type(ctx: ref[Context], id: ptr_uint, ty: types.Type) -> void:
    if id == 0:
        return
    ctx.binding_type_by_id.set(id, ty)


## The host's `@binding_type_by_id` in id order: every id that received a
## binding, ascending.  Ids allocated but never bound (a discarded `_` local)
## are invisible, exactly as the host's hash is.
public function materialize_binding_types(ctx: ref[Context]) -> vec.Vec[BindingTypeEntry]:
    var entries = vec.Vec[BindingTypeEntry].create()
    var id: ptr_uint = 1
    while id < ctx.next_binding_id:
        let tp = ctx.binding_type_by_id.get(id)
        if tp != null:
            entries.push(BindingTypeEntry(id = id, ty = unsafe: read(tp)))
        id += 1
    return entries


## Record an identifier use resolved to a binding (the host's
## `record_identifier_binding`).
public function record_identifier_site(ctx: ref[Context], node: ptr_uint, id: ptr_uint) -> void:
    if id == 0:
        return
    ctx.identifier_sites.push(BindingSite(node = node, id = id))


## Record a declaration node with its binding id (the host's
## `record_declaration_binding`).
public function record_declaration_site(ctx: ref[Context], node: ptr_uint, id: ptr_uint) -> void:
    if id == 0:
        return
    ctx.declaration_sites.push(BindingSite(node = node, id = id))


## The host's `@preassigned_local_binding_ids[node.object_id] ||= allocate_binding_id`:
## a preassigned id, or a fresh one for a node the preassign walk did not cover.
## A generic body (which the host only name-checks) allocates nothing.
public function preassigned_binding_id_for(ctx: ref[Context], key: ptr_uint) -> ptr_uint:
    if ctx.suppress_binding_records:
        return 0
    let existing = ctx.preassigned_ids.get(key)
    if existing != null:
        return unsafe: read(existing)
    let id = allocate_binding_id(ctx)
    ctx.preassigned_ids.set(key, id)
    return id

# =============================================================================
#  Binding-id declaration pass and per-body preassignment
# =============================================================================

## Allocate the declaration-time binding ids in the host's phase order:
## module-level values (const/var/event) in source order, then every function's
## and method's parameters in source order (`this` first for an instance
## method).  The host's `declare_top_level_values` → `declare_functions`
## `value_binding` calls allocate exactly these ids.  Parameter declaration
## sites are recorded here, as the host records them at declare time.
function allocate_declaration_binding_ids(
    ctx: ref[Context],
    declarations: span[ast.Decl],
    when_extra: span[ast.Decl]
) -> void:
    allocate_value_binding_ids(ctx, declarations)
    allocate_value_binding_ids(ctx, when_extra)
    allocate_callable_binding_ids(ctx, declarations)
    allocate_callable_binding_ids(ctx, when_extra)


function allocate_value_binding_ids(ctx: ref[Context], declarations: span[ast.Decl]) -> void:
    var i: ptr_uint = 0
    while i < declarations.len:
        var d: ast.Decl
        unsafe:
            d = read(declarations.data + i)
        match d:
            ast.Decl.decl_const as c:
                allocate_value_binding_id(ctx, c.name)
            ast.Decl.decl_var as v:
                allocate_value_binding_id(ctx, v.name)
            ast.Decl.decl_event as e:
                allocate_value_binding_id(ctx, e.name)
            _:
                pass
        i += 1


function allocate_value_binding_id(ctx: ref[Context], name: str) -> void:
    if name.len == 0 or ctx.value_binding_ids.contains(name):
        return
    let id = allocate_binding_id(ctx)
    ctx.value_binding_ids.set(name, id)
    let ty = ctx.value_types.get(name)
    if ty != null:
        record_binding_type(ctx, id, unsafe: read(ty))


function allocate_callable_binding_ids(ctx: ref[Context], declarations: span[ast.Decl]) -> void:
    var i: ptr_uint = 0
    while i < declarations.len:
        var d: ast.Decl
        unsafe:
            d = read(declarations.data + i)
        let node = unsafe: reinterpret[ptr_uint](declarations.data + i)
        match d:
            ast.Decl.decl_function as fun:
                allocate_param_binding_ids(
                    ctx,
                    node,
                    fun.method_params.data,
                    fun.method_params.len,
                    ctx.functions.get(fun.name)
                )
            ast.Decl.decl_extern_function as fun:
                allocate_foreign_param_binding_ids(
                    ctx,
                    node,
                    fun.extern_params.data,
                    fun.extern_params.len,
                    ctx.functions.get(fun.name)
                )
            ast.Decl.decl_foreign_function as fun:
                allocate_foreign_param_binding_ids(
                    ctx,
                    node,
                    fun.foreign_params.data,
                    fun.foreign_params.len,
                    ctx.functions.get(fun.name)
                )
            ast.Decl.decl_extending_block as ex:
                var base: str = ""
                unsafe:
                    base = qname_to_str(read(ex.type_name).name)
                var j: ptr_uint = 0
                while j < ex.methods.len:
                    var m: ast.Method
                    unsafe:
                        m = read(ex.methods.data + j)
                    let method_node = unsafe: reinterpret[ptr_uint](ex.methods.data + j)
                    allocate_method_binding_ids(ctx, method_node, m, ctx.method_sigs.get(method_key(base, m.name)))
                    j += 1
            _:
                pass
        i += 1


## A function's or method's parameters, in order.  `node` is the declaration's
## key; the first parameter's id is remembered so the body check can give each
## parameter the same id.  Each parameter's declaration site is recorded here,
## as the host records it at declare time.
function allocate_param_binding_ids(
    ctx: ref[Context],
    node: ptr_uint,
    params: ptr[ast.Param],
    count: ptr_uint,
    sig: ptr[FnSig]?
) -> void:
    if count == 0:
        return
    ctx.param_id_base.set(node, ctx.next_binding_id)
    var i: ptr_uint = 0
    while i < count:
        let id = allocate_binding_id(ctx)
        record_declaration_site(ctx, unsafe: reinterpret[ptr_uint](params + i), id)
        var param_ty: types.Type = types.Type.ty_error
        if sig != null:
            let s = unsafe: read(sig)
            if i < s.params.len:
                param_ty = unsafe: read(s.params.data + i).ty
        record_binding_type(ctx, id, param_ty)
        i += 1


function allocate_foreign_param_binding_ids(
    ctx: ref[Context],
    node: ptr_uint,
    params: ptr[ast.ForeignParam],
    count: ptr_uint,
    sig: ptr[FnSig]?
) -> void:
    if count == 0:
        return
    ctx.param_id_base.set(node, ctx.next_binding_id)
    var i: ptr_uint = 0
    while i < count:
        let id = allocate_binding_id(ctx)
        record_declaration_site(ctx, unsafe: reinterpret[ptr_uint](params + i), id)
        var param_ty: types.Type = types.Type.ty_error
        if sig != null:
            let s = unsafe: read(sig)
            if i < s.params.len:
                param_ty = unsafe: read(s.params.data + i).ty
        record_binding_type(ctx, id, param_ty)
        i += 1


## A method's `this` (instance methods only) precedes its parameters — the
## host's `declare_function_binding` builds `body_params` in that order.  The
## `this` type is recorded when the block resolves the receiver.
function allocate_method_binding_ids(ctx: ref[Context], node: ptr_uint, m: ast.Method, sig: ptr[FnSig]?) -> void:
    if m.method_kind != ast.MethodKind.mk_static:
        let this_id = allocate_binding_id(ctx)
        ctx.this_binding_ids.set(node, this_id)
    allocate_param_binding_ids(ctx, node, m.method_params.data, m.method_params.len, sig)


public function report(ctx: ref[Context], line: ptr_uint, column: ptr_uint, message: str) -> void:
    ctx.diagnostics.push(SemanticDiagnostic(
        line = line,
        column = column,
        length = 0,
        message = message,
        severity = "error",
        code = "sema/error",
    ))


## Like `report`, with the offending token's character length so the LSP range
## spans the token (Ruby's sema diagnostics carry a `length`).
function report_at(ctx: ref[Context], line: ptr_uint, column: ptr_uint, length: ptr_uint, message: str) -> void:
    ctx.diagnostics.push(SemanticDiagnostic(
        line = line,
        column = column,
        length = length,
        message = message,
        severity = "error",
        code = "sema/error",
    ))


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
                if not ctx.require_resolved_imports or find_binding(ctx, module_name) != null:
                    let alias = import_alias_name(imp.path, imp.alias_name)
                    ctx.import_aliases.set(alias, module_name)
                    if not vec_contains_str(ref_of(ctx.import_order), module_name):
                        ctx.import_order.push(module_name)
                    record_import_symbol_count(ctx, module_name)
                    record_imported_constants(ctx, alias, module_name)
            _:
                pass
        i += 1


## Expose an imported module's constants under their qualified source name
## (`sdl.ALPHA_OPAQUE`), so compile-time numeric folding can evaluate an
## imported constant used as a call argument.  The bare names stay in the
## imported binding; only the qualified key is added here to avoid collisions.
function record_imported_constants(ctx: ref[Context], alias: str, module_name: str) -> void:
    let binding_ptr = find_binding(ctx, module_name) else:
        return
    var entries = unsafe: read(binding_ptr).const_values.entries()
    while entries.next():
        let entry = entries.current()
        var key = string.String.create()
        key.append(alias)
        key.append(".")
        key.append(unsafe: read(entry.key))
        ctx.const_values.set(key.as_str(), unsafe: read(entry.value))


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
                ctx.types.set(
                    s.name,
                    types.named_type(name = s.name, module_name = ctx.module_name, linkage_name = Option[str].none)
                )
                register_module_type_name(ctx, s.name)
                ctx.type_param_names.set(s.name, s.type_params)
                ctx.implemented.set(s.name, s.impl_list)
                register_nested_struct_types(ctx, s.nested_types, s.name)
                register_struct_events(ctx, s.struct_events, s.name)
            ast.Decl.decl_union as u:
                declare_type(ctx, u.name, u.line, u.column)
                ctx.types.set(
                    u.name,
                    types.named_type(name = u.name, module_name = ctx.module_name, linkage_name = Option[str].none)
                )
                register_module_type_name(ctx, u.name)
            ast.Decl.decl_enum as e:
                declare_type(ctx, e.name, e.line, e.column)
                ctx.types.set(
                    e.name,
                    types.named_type(name = e.name, module_name = ctx.module_name, linkage_name = Option[str].none)
                )
                register_module_type_name(ctx, e.name)
            ast.Decl.decl_flags as fl:
                declare_type(ctx, fl.name, fl.line, fl.column)
                ctx.types.set(
                    fl.name,
                    types.named_type(name = fl.name, module_name = ctx.module_name, linkage_name = Option[str].none)
                )
                register_module_type_name(ctx, fl.name)
            ast.Decl.decl_variant as vr:
                declare_type(ctx, vr.name, vr.line, vr.column)
                ctx.types.set(
                    vr.name,
                    types.named_type(name = vr.name, module_name = ctx.module_name, linkage_name = Option[str].none)
                )
                register_module_type_name(ctx, vr.name)
                ctx.type_param_names.set(vr.name, vr.type_params)
            ast.Decl.decl_opaque as op:
                declare_type(ctx, op.name, op.line, op.column)
                ctx.types.set(
                    op.name,
                    types.named_type(name = op.name, module_name = ctx.module_name, linkage_name = Option[str].none)
                )
                register_module_type_name(ctx, op.name)
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
                ctx.event_types.set(
                    ev.name,
                    EventInfo(
                        name = ev.name,
                        capacity = ev.capacity,
                        payload_type = ev.payload_type,
                        owner_type_name = ""
                    )
                )
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
                register_module_type_name(ctx, ta.name)
            _:
                pass
        i += 1


function declare_type(ctx: ref[Context], name: str, line: ptr_uint, column: ptr_uint) -> void:
    if ctx.type_names.contains(name):
        report(ctx, line, column, dup_message("type", name))
        return
    ctx.type_names.set(name, true)


## Track a module-declared type's registration position (the host's
## `facts.types` order); first registration wins.
function register_module_type_name(ctx: ref[Context], name: str) -> void:
    if not vec_contains_str(ref_of(ctx.module_type_order), name):
        ctx.module_type_order.push(name)


## The exported-symbol count the debug dump's Imports block prints
## (`types + functions + values`), 0 for a module the loader did not resolve.
## The self's `ModuleBinding` splits the public type surface across its
## per-kind maps (`types` holds opaques and unions; enums/flags/variants live in
## `static_member_types`; aliases in `type_alias_types`), so the count sums them.
function record_import_symbol_count(ctx: ref[Context], module_name: str) -> void:
    let binding_ptr = find_binding(ctx, module_name) else:
        ctx.import_symbol_counts.set(module_name, 0)
        return
    let binding = unsafe: read(binding_ptr)
    ctx.import_symbol_counts.set(
        module_name,
        binding.structs.len() + binding.types.len() + binding.static_member_types.len() + binding.type_alias_types.len() + binding.functions.len() + binding.value_types.len()
    )


## A nested struct's C linkage name: its qualified path flattened under the
## module prefix (`Rectangle.Edge` -> `<module>_Rectangle_Edge`), the name the
## host's `register_nested_struct_types` stores as `Types::Struct#linkage_name`
## and the lowering's `lower_nested_struct_decls` declares.
function nested_struct_linkage(module_name: str, qname: str) -> str:
    var flat = string.String.create()
    var i: ptr_uint = 0
    while i < qname.len:
        let b = qname.byte_at(i)
        if b == '.':
            flat.push_byte('_')
        else:
            flat.push_byte(b)
        i += 1
    return naming.qualified_c_name(module_name, flat.as_str())


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
                # The nested struct's type keeps its short name (the host's
                # `Types::Struct.new(nested.name, …)`) but links through its
                # parents (`<module>_Rectangle_Edge`), so a field, parameter or
                # local of this type emits the declared C name.
                let nested_ty = types.named_type(
                    name = s.name,
                    module_name = ctx.module_name,
                    linkage_name = Option[str].some(value = nested_struct_linkage(ctx.module_name, qname))
                )
                ctx.types.set(qname, nested_ty)
                if not ctx.type_names.contains(s.name):
                    declare_type(ctx, s.name, s.line, s.column)
                    ctx.types.set(s.name, nested_ty)
                register_module_type_name(ctx, qname)
                register_nested_struct_types(ctx, s.nested_types, qname)
                register_struct_events(ctx, s.struct_events, qname)
            _:
                pass
        i += 1


## The registry key of an event declared by `owner_type_name` (a sanitized
## owner path such as `Container_Inner`; empty for a module-level event).  The
## host keys its event types by the full `Types::Event` identity, so an owner
## keeps two same-named events in different structs distinct.
public function event_registry_key(owner_type_name: str, name: str) -> str:
    if owner_type_name.len == 0:
        return name
    var buf = string.String.create()
    buf.append(owner_type_name)
    buf.append(".")
    buf.append(name)
    return buf.as_str()


## Register event types and values from a struct's event declarations, so
## struct-member event access (`window.closed.emit()`) resolves correctly.
function register_struct_events(ctx: ref[Context], events: span[ast.Decl], owner: str) -> void:
    let owner_key = naming.sanitize_event_part(owner)
    var i: ptr_uint = 0
    while i < events.len:
        unsafe:
            match read(events.data + i):
                ast.Decl.decl_event as ev:
                    ctx.event_types.set(
                        event_registry_key(owner_key, ev.name),
                        EventInfo(
                            name = ev.name,
                            capacity = ev.capacity,
                            payload_type = ev.payload_type,
                            owner_type_name = owner_key
                        )
                    )
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
function evaluate_when_discriminant(
    ctx: ref[Context],
    discriminant: ptr[ast.Expr],
    decls: span[ast.Decl]
) -> Option[str]:
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
function collect_when_branch_decls(
    branches: span[ast.WhenDeclBranch],
    chosen: str,
    output: ref[vec.Vec[ast.Decl]]
) -> void:
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


## Resolve every declared variant arm's payload fields into the type model
## (`Decl_decl_var` -> `[value: ptr[ast.Expr]?, line: ptr_uint]`), with the
## variant's type parameters as `ty_var`, so an `as name` arm binding carries the
## host's `Types::VariantArmPayload` — for a module's own variants and, through
## `ModuleBinding.variant_arm_fields`, for imported ones.
function collect_variant_arm_fields(ctx: ref[Context], decls: span[ast.Decl]) -> void:
    var i: ptr_uint = 0
    while i < decls.len:
        var d: ast.Decl
        unsafe:
            d = read(decls.data + i)
        match d:
            ast.Decl.decl_variant as vr:
                enter_type_params(ctx, vr.type_params)
                register_variant_param_names(ctx, vr.name, vr.type_params)
                var ai: ptr_uint = 0
                while ai < vr.variant_arms.len:
                    let arm = unsafe: read(vr.variant_arms.data + ai)
                    ctx.arm_payload_field_types.set(
                        payload_struct_key(vr.name, arm.name),
                        resolve_arm_payload_fields(ctx, arm.arm_fields)
                    )
                    ai += 1
                ctx.type_params.clear()
                ctx.suppressed_type_names.clear()
            _:
                pass
        i += 1


## The declared type-parameter *names* of a variant, in declaration order — the
## substitution domain `match_arm_payload_type` maps to the scrutinee's
## arguments.  Value and lifetime parameters are not type variables.
function register_variant_param_names(ctx: ref[Context], name: str, type_params: span[ast.TypeParam]) -> void:
    ctx.variant_param_names.set(name, variant_type_param_names(type_params))


function variant_type_param_names(type_params: span[ast.TypeParam]) -> span[str]:
    var names = vec.Vec[str].create()
    var i: ptr_uint = 0
    while i < type_params.len:
        var tp: ast.TypeParam
        unsafe:
            tp = read(type_params.data + i)
        if not tp.is_value and not tp.is_lifetime:
            names.push(tp.name)
        i += 1
    return names.as_span()


function resolve_arm_payload_fields(ctx: ref[Context], fields: span[ast.Field]) -> span[types.PayloadField]:
    var entries = vec.Vec[types.PayloadField].create()
    var i: ptr_uint = 0
    while i < fields.len:
        var f: ast.Field
        unsafe:
            f = read(fields.data + i)
        entries.push(types.PayloadField(name = f.name, ty = resolve_type_value(ctx, f.field_type)))
        i += 1
    return entries.as_span()


function declare_values_and_functions_extra(ctx: ref[Context], extra: span[ast.Decl]) -> void:
    var i: ptr_uint = 0
    while i < extra.len:
        var d: ast.Decl
        unsafe:
            d = read(extra.data + i)
        match d:
            ast.Decl.decl_const as c:
                check_reserved_value_name(ctx, "constant", c.name, c.line, c.column)
                if declare_value(ctx, c.name, c.line, c.column):
                    ctx.value_types.set(c.name, resolve_type(ctx, c.const_type))
                    let val = c.value else:
                        i += 1
                        continue
                    ctx.declared_const_values.set(c.name, val)
                    ctx.const_values.set(c.name, val)
                    record_decl_callable_sites(ctx, val)
            ast.Decl.decl_function as fun:
                check_reserved_value_name(ctx, "function", fun.name, fun.line, fun.column)
                if declare_value(ctx, fun.name, fun.line, fun.column):
                    ctx.functions.set(
                        fun.name,
                        build_fn_sig(
                            ctx,
                            fun.name,
                            fun.method_params,
                            fun.return_type,
                            ast.MethodKind.mk_plain,
                            fun.is_async
                        )
                    )
            _:
                pass
        i += 1


## Record callable-value sites for the bare function names in a declaration's
## initializer (`const WIDE: type = int_with_bits[64]`, `foreign function f(…) =
## atoi`).  The host infers those with an expected type, so its scanner renders
## the name `function`; the self folds consts and never infers a foreign
## mapping, so the sites are recorded here instead.
function record_decl_callable_sites(ctx: ref[Context], ep: ptr[ast.Expr]?) -> void:
    let p = ep else:
        return
    unsafe:
        match read(p):
            ast.Expr.expr_identifier as id:
                if ctx.functions.contains(id.name):
                    if ctx.tooling_facts:
                        ctx.callable_value_sites.push(CallableValueSite(line = id.line, column = id.column))
            ast.Expr.expr_specialization as sp:
                # `int_with_bits[64]`: the specialization's callee is the value
                # (its type arguments are types, not expressions).
                record_decl_callable_sites(ctx, sp.callee)
            ast.Expr.expr_call as cl:
                record_decl_callable_sites(ctx, cl.callee)
                var ci: ptr_uint = 0
                while ci < cl.args.len:
                    record_decl_callable_sites(ctx, read(cl.args.data + ci).arg_value)
                    ci += 1
            ast.Expr.expr_member_access as ma:
                record_decl_callable_sites(ctx, ma.receiver)
            ast.Expr.expr_unary_op as u:
                record_decl_callable_sites(ctx, u.operand)
            ast.Expr.expr_prefix_cast as pc:
                record_decl_callable_sites(ctx, pc.expression)
            ast.Expr.expr_unsafe as us:
                record_decl_callable_sites(ctx, us.expression)
            ast.Expr.expr_expression_list as el:
                var ei: ptr_uint = 0
                while ei < el.elements.len:
                    record_decl_callable_sites(ctx, el.elements.data + ei)
                    ei += 1
            _:
                pass


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
    # The host's `facts.imports` carries the walked imports first and the
    # prelude modules appended; the LSP's method merge follows that order.
    if not ctx.module_name.equal("std.option") and not vec_contains_str(ref_of(ctx.import_order), "std.option"):
        ctx.import_order.push("std.option")
        record_import_symbol_count(ctx, "std.option")
    if not ctx.module_name.equal("std.result") and not vec_contains_str(ref_of(ctx.import_order), "std.result"):
        ctx.import_order.push("std.result")
        record_import_symbol_count(ctx, "std.result")
    register_prelude_type(ctx, "Option", "some", "none")
    register_prelude_type(ctx, "Result", "success", "failure")
    # The prelude variants' arm payloads (`Option_some{value: T}` and friends,
    # the host's `Types::VariantArmPayload` shapes) and their type parameters,
    # so an `as name` arm binding carries the arm's fields.
    var option_params = vec.Vec[str].create()
    option_params.push("T")
    ctx.variant_param_names.set("Option", option_params.as_span())
    var result_params = vec.Vec[str].create()
    result_params.push("T")
    result_params.push("E")
    ctx.variant_param_names.set("Result", result_params.as_span())
    register_prelude_arm_field(ctx, "Option", "some", "value", "T")
    register_prelude_arm_field(ctx, "Option", "none", "", "T")
    register_prelude_arm_field(ctx, "Result", "success", "value", "T")
    register_prelude_arm_field(ctx, "Result", "failure", "error", "E")
    merge_prelude_binding_methods(ctx, "std.option")
    merge_prelude_binding_methods(ctx, "std.result")
    register_builtin_event_types(ctx)


## Register one prelude arm's declared payload field under its payload key
## (`Option_some` -> `[value: T]`, `Option_none` -> `[]`).  The field's type is
## the variant's type parameter as a `ty_var`, substituted at a match site.
function register_prelude_arm_field(
    ctx: ref[Context],
    variant_name: str,
    arm: str,
    field_name: str,
    field_param: str
) -> void:
    let key = payload_struct_key(variant_name, arm)
    if field_name.len == 0:
        ctx.arm_payload_field_types.set(key, span[types.PayloadField]())
        return
    var decls = vec.Vec[types.PayloadField].create()
    decls.push(types.PayloadField(name = field_name, ty = types.Type.ty_var(name = field_param)))
    ctx.arm_payload_field_types.set(key, decls.as_span())


## The payload struct's name for a variant arm (`Option` + `some` -> `Option_some`),
## the key of `arm_payload_field_types` and the `name` of the payload type.
function payload_struct_key(variant_name: str, arm: str) -> str:
    var buf = string.String.create()
    buf.append(variant_name)
    buf.append("_")
    buf.append(arm)
    return buf.as_str()


## Register the built-in scalar and handle type names into `ctx.types`, so a
## declaration, annotation or field can name them.
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


## Copy a seeded prelude module's binding (`std.option`'s `extending Option[T]`)
## into the local tables: `method_keys` for existence checks and
## `prelude_method_sigs` so a prelude receiver's calls type
## (`Option[int].unwrap()` -> `int`, the receiver's arguments substituted).
## The signatures stay out of `method_sigs` — that table is exported on the
## `Analysis` and the LSP resolves a member's declaration from the receiver's
## own module, which a prelude method does not have.  No-op when the binding is
## absent (single-file checks without a loaded program).
function merge_prelude_binding_methods(ctx: ref[Context], module_name: str) -> void:
    let binding_ptr = find_binding(ctx, module_name) else:
        return
    unsafe:
        let binding = read(binding_ptr)
        var keys = binding.member_keys.keys()
        while true:
            let key_ptr = keys.next() else:
                break
            ctx.method_keys.set(read(key_ptr), true)
        var sig_entries = binding.method_sigs.entries()
        while sig_entries.next():
            let entry = sig_entries.current()
            let key = read(entry.key)
            if not ctx.method_sigs.contains(key):
                ctx.prelude_method_sigs.set(key, read(entry.value))


## Register the built-in event support types: `EventError` (built-in enum with
## the single member `full`) and the opaque `Subscription` handle — mirroring
## Ruby's type_declaration.rb built-in registration.
function register_builtin_event_types(ctx: ref[Context]) -> void:
    if not ctx.type_names.contains("EventError"):
        ctx.types.set(
            "EventError",
            types.named_type(name = "EventError", module_name = "", linkage_name = Option[str].none)
        )
        ctx.static_member_types.set("EventError", true)
        ctx.match_case_types.set("EventError", true)
        ctx.method_keys.set(method_key("EventError", "full"), true)
        var members = vec.Vec[str].create()
        members.push("full")
        ctx.match_case_names.set("EventError", members.as_span())
        ctx.member_names.set("EventError", members.as_span())
    if not ctx.type_names.contains("Subscription"):
        ctx.types.set(
            "Subscription",
            types.named_type(name = "Subscription", module_name = "", linkage_name = Option[str].none)
        )


function register_prelude_type(ctx: ref[Context], name: str, arm_a: str, arm_b: str) -> void:
    if ctx.type_names.contains(name):
        return
    ctx.types.set(name, types.named_type(name = name, module_name = "", linkage_name = Option[str].none))
    ctx.static_member_types.set(name, true)
    ctx.match_case_types.set(name, true)
    ctx.variant_types.set(name, true)
    ctx.method_keys.set(method_key(name, arm_a), true)
    ctx.method_keys.set(method_key(name, arm_b), true)
    var arms = vec.Vec[str].create()
    arms.push(arm_a)
    arms.push(arm_b)
    ctx.match_case_names.set(name, arms.as_span())
    ctx.member_names.set(name, arms.as_span())
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
        register_method_sig(ctx, method_key(name, "is_some"), fn_sig_no_params(name, "is_some", bool_ty))
        register_method_sig(ctx, method_key(name, "is_none"), fn_sig_no_params(name, "is_none", bool_ty))
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
        register_method_sig(ctx, method_key(name, "is_success"), fn_sig_no_params(name, "is_success", bool_ty))
        register_method_sig(ctx, method_key(name, "is_failure"), fn_sig_no_params(name, "is_failure", bool_ty))


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
            # The method table is keyed by the receiver *type name* (the bare
            # event name), not the registry key: a struct event's declared type
            # renders as its short name.
            let info = read(entries.current().value)
            ctx.method_keys.set(method_key(info.name, "emit"), true)
            ctx.method_keys.set(method_key(info.name, "subscribe"), true)
            ctx.method_keys.set(method_key(info.name, "subscribe_once"), true)
            ctx.method_keys.set(method_key(info.name, "unsubscribe"), true)


function fn_sig_no_params(type_name: str, method_name: str, return_type: types.Type) -> FnSig:
    return FnSig(
        name = method_name,
        params = span[ParamEntry](),
        return_type = return_type,
        has_return_type = true,
        method_kind = ast.MethodKind.mk_plain,
        is_async = false,
        is_variadic = false,
        is_extern = false,
        required_count = 0
    )


## Register a method signature and record its key in `method_order` (a first
## registration keeps its position, like the host's `methods[name] ||=`): a map
## iterates in bucket order, and the LSP's completion merge needs the host's
## per-type registration order.
function register_method_sig(ctx: ref[Context], key: str, sig: FnSig) -> void:
    if not ctx.method_sigs.contains(key):
        ctx.method_order.push(key)
    ctx.method_sigs.set(key, sig)


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


function check_attr_span(
    ctx: ref[Context],
    attrs: span[ast.AttributeApplication],
    target: str,
    line: ptr_uint,
    column: ptr_uint
) -> void:
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
function resolve_field_entries_with_events(
    ctx: ref[Context],
    fields: span[ast.Field],
    struct_events: span[ast.Decl]
) -> span[FieldEntry]:
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
                    result.push(FieldEntry(
                        name = ev.name,
                        ty = types.named_type(name = ev.name, module_name = "", linkage_name = Option[str].none)
                    ))
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
        let binding_ptr = find_binding(ctx, target_module) else:
            break
        let resolved_ptr = unsafe: read(binding_ptr).type_alias_types.get(name)
        if resolved_ptr == null:
            break
        var moved = false
        match unsafe: read(resolved_ptr):
            types.Type.ty_imported as im:
                let im_bp = unsafe: read(im.payload)
                name = im_bp.name
                target_module = im_bp.module_name
                moved = true
            types.Type.ty_named as nn:
                let nn_np = unsafe: read(nn.payload)
                name = nn_np.name
                target_module = nn_np.module_name
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
                # A receiver of a nested struct (`Rectangle.Edge`) resolves to a
                # type whose `name` is the short segment, so the block's methods
                # are registered under that name as well as the qualified one.
                var short_base = base
                if canonical == base:
                    short_base = last_dotted_segment(base)
                var j: ptr_uint = 0
                while j < ex.methods.len:
                    var m: ast.Method
                    unsafe:
                        m = read(ex.methods.data + j)
                    let key = method_key(base, m.name)
                    ctx.method_keys.set(key, true)
                    if short_base != base:
                        ctx.method_keys.set(method_key(short_base, m.name), true)
                    if canonical != base:
                        ctx.method_keys.set(method_key(canonical, m.name), true)
                    enter_suppressed_extending_target(ctx, ex.type_name)
                    enter_type_params(ctx, m.type_params)
                    enter_extending_type_params(ctx, ex.type_name)
                    let sig = build_fn_sig(ctx, m.name, m.method_params, m.return_type, m.method_kind, m.is_async)
                    if m.method_kind != ast.MethodKind.mk_static or not ctx.method_sigs.contains(key):
                        register_method_sig(ctx, key, sig)
                    if short_base != base:
                        let short_key = method_key(short_base, m.name)
                        if m.method_kind != ast.MethodKind.mk_static or not ctx.method_sigs.contains(short_key):
                            register_method_sig(ctx, short_key, sig)
                    if canonical != base:
                        let canonical_key = method_key(canonical, m.name)
                        if not ctx.method_sigs.contains(canonical_key):
                            register_method_sig(ctx, canonical_key, sig)
                    ctx.type_params.clear()
                    ctx.suppressed_type_names.clear()
                    if m.type_params.len > 0:
                        ctx.method_type_params.set(key, m.type_params)
                    j += 1
            _:
                pass
        i += 1


## The final segment of a dotted type name (`Rectangle.Edge` -> `Edge`); a
## nested struct's type and its receivers carry the short name.
function last_dotted_segment(name: str) -> str:
    var last_dot: ptr_uint = 0
    var has_dot = false
    var i: ptr_uint = 0
    while i < name.len:
        if name.byte_at(i) == '.':
            last_dot = i
            has_dot = true
        i += 1
    if has_dot:
        return name.slice(last_dot + 1, name.len - last_dot - 1)
    return name


public function method_key(type_name: str, member: str) -> str:
    var buf = string.String.with_capacity(type_name.len + 1 + member.len)
    buf.append(type_name)
    buf.append(".")
    buf.append(member)
    return buf.as_str()


public function has_method(ctx: ref[Context], type_name: str, member: str) -> bool:
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
                let names = enum_member_names(e.enum_members)
                ctx.match_case_names.set(e.name, names)
                ctx.member_names.set(e.name, names)
                register_member_names(ctx, e.name, e.enum_members)
            ast.Decl.decl_flags as fl:
                ctx.static_member_types.set(fl.name, true)
                ctx.member_names.set(fl.name, enum_member_names(fl.flags_members))
                register_member_names(ctx, fl.name, fl.flags_members)
            ast.Decl.decl_variant as vr:
                ctx.static_member_types.set(vr.name, true)
                ctx.match_case_types.set(vr.name, true)
                ctx.variant_types.set(vr.name, true)
                let names = variant_arm_names(vr.variant_arms)
                ctx.match_case_names.set(vr.name, names)
                ctx.member_names.set(vr.name, names)
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
            var member_entries = read(binding_ptr).member_names.entries()
            while true:
                if not member_entries.next():
                    break
                let entry = member_entries.current()
                if not ctx.member_names.contains(read(entry.key)):
                    ctx.member_names.set(read(entry.key), read(entry.value))


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
                check_reserved_value_name(ctx, "constant", c.name, c.line, c.column)
                if declare_value(ctx, c.name, c.line, c.column):
                    ctx.value_types.set(c.name, resolve_type(ctx, c.const_type))
                    record_decl_callable_sites(ctx, c.value)
                    match evaluate_const_expr(ctx, c.value):
                        Option.some:
                            let val = c.value else:
                                i += 1
                                continue
                            ctx.declared_const_values.set(c.name, val)
                            ctx.const_values.set(c.name, val)
                        Option.none:
                            pass
            ast.Decl.decl_var as v:
                check_reserved_value_name(ctx, "module variable", v.name, v.line, v.column)
                if declare_value(ctx, v.name, v.line, v.column):
                    let vt = v.var_type
                    if vt != null:
                        ctx.value_types.set(v.name, resolve_type(ctx, vt))
            ast.Decl.decl_function as fun:
                check_reserved_value_name(ctx, "function", fun.name, fun.line, fun.column)
                if declare_value(ctx, fun.name, fun.line, fun.column):
                    # Build the signature with the function's own type parameters
                    # in scope, so parameter/return patterns carry ty_var(T) for
                    # call-site unification. Record the constraints for validation.
                    enter_type_params(ctx, fun.type_params)
                    ctx.functions.set(
                        fun.name,
                        build_fn_sig(
                            ctx,
                            fun.name,
                            fun.method_params,
                            fun.return_type,
                            ast.MethodKind.mk_plain,
                            fun.is_async
                        )
                    )
                    ctx.type_params.clear()
                    ctx.suppressed_type_names.clear()
                    if fun.type_params.len > 0:
                        ctx.function_type_params.set(fun.name, fun.type_params)
            ast.Decl.decl_extern_function as ef:
                check_reserved_value_name(ctx, "function", ef.name, ef.line, 1)
                enter_suppressed_type_params(ctx, ef.type_params)
                # The declared type parameters are type *variables* in the
                # signature (the host's binding types carry `T`); the suppression
                # above keeps every other unknown name permissive.
                enter_type_params(ctx, ef.type_params)
                var extern_ret = types.primitive("void")
                let er_ptr = ef.return_type
                if er_ptr != null:
                    extern_ret = resolve_type(ctx, er_ptr)
                let sig = build_foreign_fn_sig(ctx, ef.name, ef.extern_params, extern_ret, ef.variadic)
                ctx.suppressed_type_names.clear()
                ctx.type_params.clear()
                ctx.functions.set(ef.name, sig)
                record_mutating_param_indices(ctx, ef.name, ef.extern_params)
                record_directional_param_modes(ctx, ef.name, ef.extern_params)
                declare_value(ctx, ef.name, ef.line, 1)
            ast.Decl.decl_foreign_function as ff:
                check_reserved_value_name(ctx, "function", ff.name, ff.line, 1)
                enter_suppressed_type_params(ctx, ff.type_params)
                enter_type_params(ctx, ff.type_params)
                let sig = build_foreign_fn_sig(
                    ctx,
                    ff.name,
                    ff.foreign_params,
                    resolve_type(ctx, ff.return_type),
                    ff.variadic
                )
                ctx.suppressed_type_names.clear()
                ctx.type_params.clear()
                ctx.functions.set(ff.name, sig)
                record_mutating_param_indices(ctx, ff.name, ff.foreign_params)
                record_directional_param_modes(ctx, ff.name, ff.foreign_params)
                declare_value(ctx, ff.name, ff.line, 1)
                record_decl_callable_sites(ctx, ff.mapping)
            ast.Decl.decl_event as ev:
                check_reserved_value_name(ctx, "event", ev.name, ev.line, ev.column)
                if declare_value(ctx, ev.name, ev.line, ev.column):
                    ctx.value_types.set(
                        ev.name,
                        types.named_type(name = ev.name, module_name = "", linkage_name = Option[str].none)
                    )
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
function declare_struct_event_values(
    ctx: ref[Context],
    struct_events: span[ast.Decl],
    nested_types: span[ast.Decl]
) -> void:
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


function check_reserved_value_name(
    ctx: ref[Context],
    kind_label: str,
    name: str,
    line: ptr_uint,
    column: ptr_uint
) -> void:
    if is_reserved_value_name(name):
        report(ctx, line, column, diag.reserved_value_message(kind_label, name))


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
function build_foreign_fn_sig(
    ctx: ref[Context],
    name: str,
    params: span[ast.ForeignParam],
    ret: types.Type,
    variadic: bool
) -> FnSig:
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
        is_variadic = variadic, is_extern = true, required_count = param_entries.len())


function build_fn_sig(
    ctx: ref[Context],
    name: str,
    params: span[ast.Param],
    return_type: ptr[ast.TypeRef]?,
    method_kind: ast.MethodKind,
    is_async: bool
) -> FnSig:
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
        let base = types.function_type(
            name = "",
            params = param_types.as_span(),
            return_type = types.alloc_type(ret),
            variadic = false,
            is_proc = t.is_proc,
            param_names = param_names.as_span()
        )
        return wrap_nullable(base, t.nullable)

    if t.is_dyn:
        return wrap_nullable(
            types.named_type(name = "dyn", module_name = "", linkage_name = Option[str].none),
            t.nullable
        )

    if t.is_tuple:
        var elems = vec.Vec[types.Type].create()
        var ti: ptr_uint = 0
        while ti < t.arguments.len:
            unsafe:
                elems.push(resolve_type(ctx, t.arguments.data + ti))
            ti += 1
        return types.tuple_type(elements = elems.as_span(), field_names = Option[span[str]].none)

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
    let binding_ptr = find_binding(ctx, unsafe: read(module_name_ptr)) else:
        return Option[types.Type].none
    unsafe:
        let binding = read(binding_ptr)
        if binding.type_alias_types.contains(type_name):
            var val_ptr = binding.type_alias_types.get(type_name)
            if val_ptr != null:
                return Option[types.Type].some(value = unsafe: read(ptr[types.Type]<-val_ptr))
        if (
            binding.structs.contains(type_name)
            or binding.type_aliases.contains(type_name)
            or binding.static_member_types.contains(type_name)
            or binding.interfaces.contains(type_name)
            or binding.types.contains(type_name)
        ):
            return Option[types.Type].some(value = types.imported_type(
                module_name = read(module_name_ptr),
                name = type_name,
                args = span[types.Type]()
            ))
    return Option[types.Type].none


## Wrap a resolved imported type with concrete type arguments from the TypeRef.
## When the type arguments are empty, the imported type is returned unchanged.
function imported_type_with_args(
    ctx: ref[Context],
    imported: types.Type,
    arguments: span[ast.TypeRef],
    depth: int
) -> types.Type:
    if arguments.len == 0:
        return imported
    match imported:
        types.Type.ty_imported as im:
            let im_bp = unsafe: read(im.payload)
            var resolved_args = vec.Vec[types.Type].create()
            var i: ptr_uint = 0
            while i < arguments.len:
                var a: ast.TypeRef
                unsafe:
                    a = read(arguments.data + i)
                resolved_args.push(resolve_type_at(ctx, a, depth + 1))
                i += 1
            return types.imported_type(
                module_name = im_bp.module_name,
                name = im_bp.name,
                args = resolved_args.as_span()
            )
        _:
            return imported


function wrap_nullable(base: types.Type, nullable: bool) -> types.Type:
    if nullable:
        return types.Type.ty_nullable(base = types.alloc_type(base))
    return base


function resolve_named(
    ctx: ref[Context],
    name: str,
    arguments: span[ast.TypeRef],
    lifetime: Option[str],
    depth: int,
    line: ptr_uint,
    column: ptr_uint
) -> types.Type:
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
        return resolve_generic_type(ctx, name, arguments, lifetime, depth)
    if ctx.type_names.contains(name):
        return resolve_registered_type(ctx, name, arguments, depth)
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
    let qual_const = fold_qualified_const_type(ctx, name)
    if not types.is_error(qual_const):
        return qual_const
    if name.find_byte('.').is_some():
        return types.Type.ty_error
    if ctx.suppressed_type_names.contains(name):
        return types.Type.ty_error
    report(ctx, line, column, unknown_type_message(name))
    return types.Type.ty_error


function resolve_generic_type(
    ctx: ref[Context],
    name: str,
    arguments: span[ast.TypeRef],
    lifetime: Option[str],
    depth: int
) -> types.Type:
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
    return types.generic_type(name = name, args = args.as_span())


function resolve_registered_type(ctx: ref[Context], name: str, arguments: span[ast.TypeRef], depth: int) -> types.Type:
    # Built-in registered types (e.g. `EventError`, `Subscription`) carry no
    # owning module and must stay unqualified.
    # The registry entry is authoritative: a builtin stays unqualified, a
    # module-level type names its own module, and a nested struct's entry
    # carries its parent-qualified `linkage_name` (its `name` is the short
    # one, so rebuilding the type from `name` would lose the link).
    let registered_ptr = ctx.types.get(name)
    if registered_ptr != null:
        let registered = unsafe: read(registered_ptr)
        match registered:
            types.Type.ty_named as rn:
                let rn_np = unsafe: read(rn.payload)
                if arguments.len == 0:
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
        return types.imported_type(module_name = ctx.module_name, name = name, args = args.as_span())
    return types.named_type(name = name, module_name = ctx.module_name, linkage_name = Option[str].none)


function fold_qualified_const_type(ctx: ref[Context], name: str) -> types.Type:
    match name.find_byte('.'):
        Option.some as dot:
            let alias_name = name.slice(0, dot.value)
            let member_name = name.slice(dot.value + 1, name.len - dot.value - 1)
            let mod_ptr = ctx.import_aliases.get(alias_name)
            if mod_ptr != null:
                let target_module = unsafe: read(mod_ptr)
                let binding_ptr = find_binding(ctx, target_module)
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


public function is_primitive_type_name(name: str) -> bool:
    return (
        name == "bool" or name == "byte" or name == "ubyte" or name == "char"
        or name == "short" or name == "ushort" or name == "int" or name == "uint"
        or name == "long" or name == "ulong" or name == "ptr_int" or name == "ptr_uint"
        or name == "float" or name == "double" or name == "void" or name == "cstr"
        or name == "vec2" or name == "vec3" or name == "vec4"
        or name == "ivec2" or name == "ivec3" or name == "ivec4"
        or name == "mat3" or name == "mat4" or name == "quat"
    )


function is_reserved_value_name(name: str) -> bool:
    return is_primitive_type_name(name) or name == "str" or name == "Option" or name == "Result"


function is_reserved_name(name: str) -> bool:
    return is_reserved_value_name(name)


function is_generic_constructor_name(name: str) -> bool:
    return (
        name == "ptr" or name == "const_ptr" or name == "own" or name == "ref" or name == "span"
        or name == "array" or name == "str_buffer" or name == "atomic" or name == "Task"
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
                check_function_body(
                    ctx,
                    unsafe: reinterpret[ptr_uint](file.declarations.data + i),
                    fun.name,
                    fun.line,
                    fun.type_params,
                    fun.method_params,
                    fun.return_type,
                    fun.body,
                    fun.is_async
                )
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
                var base: str = ""
                unsafe:
                    base = qname_to_str(read(ex.type_name).name)
                enter_suppressed_extending_target(ctx, ex.type_name)
                # The block's own type parameters must be in scope while the
                # receiver type resolves, or `extending StateMachine[State,
                # Event, Context]:` types `this` as `StateMachine[<error>, …]`
                # and every expression recording that type loses the bindings.
                enter_extending_type_params(ctx, ex.type_name)
                unsafe:
                    this_type = resolve_type_value(ctx, read(ex.type_name))
                ctx.suppressed_type_names.clear()
                var j: ptr_uint = 0
                while j < ex.methods.len:
                    var m: ast.Method
                    unsafe:
                        m = read(ex.methods.data + j)
                    enter_extending_type_params(ctx, ex.type_name)
                    ctx.method_receiver_types.set(method_key(base, m.name), this_type)
                    if m.method_kind != ast.MethodKind.mk_static:
                        # `this` is bound in a non-static method only (see
                        # check_method_body); record it for the LSP.
                        ctx.this_types.push(ThisTypeEntry(line = m.line, ty = this_type))
                    check_method_body(
                        ctx,
                        this_type,
                        m,
                        ex.type_name,
                        unsafe: reinterpret[ptr_uint](ex.methods.data + j)
                    )
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
                if not vec_contains_str(ref_of(ctx.interface_order), iface.name):
                    ctx.interface_order.push(iface.name)
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
function check_conformance(
    ctx: ref[Context],
    type_name: str,
    impl_list: span[ast.QualifiedName],
    line: ptr_uint,
    column: ptr_uint
) -> void:
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
        let binding_ptr = find_binding(ctx, unsafe: read(module_name_ptr)) else:
            return Option[span[ast.InterfaceMethod]].none
        unsafe:
            let methods_ptr = read(binding_ptr).interfaces.get(iface)
            if methods_ptr != null:
                return Option[span[ast.InterfaceMethod]].some(value = read(methods_ptr))
        return Option[span[ast.InterfaceMethod]].none
    return Option[span[ast.InterfaceMethod]].none


function check_conformance_methods(
    ctx: ref[Context],
    type_name: str,
    iface_name: str,
    methods: span[ast.InterfaceMethod],
    line: ptr_uint,
    column: ptr_uint
) -> void:
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


function check_foreign_params(
    ctx: ref[Context],
    name: str,
    params: span[ast.ForeignParam],
    type_params: span[ast.TypeParam]
) -> void:
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
                if not types.contains_error(ct):
                    match ct:
                        types.Type.ty_var:
                            pass
                        _:
                            if not types.is_bool_type(ct):
                                report(ctx, sa.line, 1, condition_message("static_assert", ct))
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


public function scope_get(scope: ref[sscope.Scope], name: str) -> ptr[types.Type]?:
    return sscope.scope_get(scope, name)


function scope_is_let(scope: ref[sscope.Scope], name: str) -> bool:
    return sscope.scope_is_let(scope, name)


function scope_set_let(scope: ref[sscope.Scope], name: str) -> void:
    sscope.scope_set_let(scope, name)


function scope_is_param(scope: ref[sscope.Scope], name: str) -> bool:
    return sscope.scope_is_param(scope, name)


function scope_set_param(scope: ref[sscope.Scope], name: str) -> void:
    sscope.scope_set_param(scope, name)


function scope_set_storage(scope: ref[sscope.Scope], name: str, ty: types.Type) -> void:
    sscope.scope_set_storage(scope, name, ty)


function scope_get_storage(scope: ref[sscope.Scope], name: str) -> ptr[types.Type]?:
    return sscope.scope_get_storage(scope, name)


function scope_set_binding_id(scope: ref[sscope.Scope], name: str, id: ptr_uint) -> void:
    sscope.scope_set_binding_id(scope, name, id)


function scope_get_binding_id(scope: ref[sscope.Scope], name: str) -> ptr_uint:
    return sscope.scope_get_binding_id(scope, name)


function check_method_body(
    ctx: ref[Context],
    this_type: types.Type,
    m: ast.Method,
    target_type_name: ptr[ast.TypeRef],
    node: ptr_uint
) -> void:
    var receiver_generic = false
    unsafe:
        receiver_generic = read(target_type_name).arguments.len > 0
    let is_generic = m.type_params.len > 0 or receiver_generic
    ctx.suppress_binding_records = is_generic
    if not is_generic:
        preassign.preassign_body_binding_ids(ctx, m.body)
    enter_suppressed_extending_target(ctx, target_type_name)
    enter_type_params(ctx, m.type_params)
    var scope = scope_create()
    scope_enter(ref_of(scope))
    if m.method_kind != ast.MethodKind.mk_static:
        scope_set(ref_of(scope), "this", this_type)
        scope_set_storage(ref_of(scope), "this", this_type)
        if m.method_kind != ast.MethodKind.mk_editable:
            scope_set_let(ref_of(scope), "this")
        let this_id = ctx.this_binding_ids.get(node)
        if this_id != null:
            let tid = unsafe: read(this_id)
            scope_set_binding_id(ref_of(scope), "this", tid)
            record_binding_type(ctx, tid, this_type)
    var seen = map_mod.Map[str, bool].create()
    var pi: ptr_uint = 0
    while pi < m.method_params.len:
        var p: ast.Param
        unsafe:
            p = read(m.method_params.data + pi)
        if seen.contains(p.name):
            report(ctx, p.line, p.column, dup_param_message(m.name, p.name))
        seen.set(p.name, true)
        if is_reserved_name(p.name):
            report(ctx, p.line, p.column, diag.reserved_value_message("parameter", p.name))
        let param_ty = resolve_type_value(ctx, p.param_type)
        scope_set(ref_of(scope), p.name, param_ty)
        scope_set_storage(ref_of(scope), p.name, param_ty)
        scope_set_let(ref_of(scope), p.name)
        scope_set_param(ref_of(scope), p.name)
        scope_set_binding_id(ref_of(scope), p.name, declared_param_id(ctx, node, pi))
        pi += 1
    seen.release()
    var ret = types.primitive("void")
    let rt = m.return_type
    if rt != null:
        ret = resolve_type(ctx, rt)
    ctx.inside_async = m.is_async
    # The host's `run_nullability_pre_pass` runs for method bodies too: build the
    # body's control-flow graph and solve the non-null dataflow before checking,
    # so a guarded local narrows exactly as it does in a function body (and the
    # refinement record the LSP and the lowering read is populated for methods).
    flow_builder.cfg_clear(ref_of(ctx.flow_cfg))
    flow_builder.build_graph_into(ref_of(ctx.flow_cfg), ref_of(ctx.flow_graph), m.method_params, m.body)
    flow_graph.flow_init_into(ref_of(ctx.flow), ctx.flow_cfg.next_id, ctx.flow_graph.next_id)
    flow_graph.solve_nullability(ref_of(ctx.flow_graph), ref_of(ctx.flow))
    ctx.flow_active = true
    ctx.flow_recorded.clear()
    ctx.flow_scratch.clear()
    record_flow_barrier(ctx, m.line)
    check_stmt(ctx, ref_of(scope), check_flags(ret, false, false, false), m.body, null)
    ctx.flow_active = false
    ctx.inside_async = false
    check_definite_assignment(ctx, m.method_params, m.body)
    ctx.suppress_binding_records = false
    ctx.type_params.clear()
    ctx.suppressed_type_names.clear()


## The declaration-pass id of a function/method parameter (0 when generic or
## unallocated).
function declared_param_id(ctx: ref[Context], node: ptr_uint, index: ptr_uint) -> ptr_uint:
    if ctx.suppress_binding_records:
        return 0
    let base = ctx.param_id_base.get(node)
    if base == null:
        return 0
    return unsafe: read(base) + index


function check_function_body(
    ctx: ref[Context],
    node: ptr_uint,
    name: str,
    line: ptr_uint,
    type_params: span[ast.TypeParam],
    params: span[ast.Param],
    return_type: ptr[ast.TypeRef]?,
    body: ptr[ast.Stmt]?,
    is_async: bool
) -> void:
    let b = body else:
        return
    let is_generic = type_params.len > 0
    ctx.suppress_binding_records = is_generic
    if not is_generic:
        preassign.preassign_body_binding_ids(ctx, body)
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
            report(ctx, p.line, p.column, dup_param_message(name, p.name))
        seen.set(p.name, true)
        if is_reserved_name(p.name):
            report(ctx, p.line, p.column, diag.reserved_value_message("parameter", p.name))
        let param_ty = resolve_type_value(ctx, p.param_type)
        scope_set(ref_of(scope), p.name, param_ty)
        scope_set_storage(ref_of(scope), p.name, param_ty)
        scope_set_let(ref_of(scope), p.name)
        scope_set_param(ref_of(scope), p.name)
        scope_set_binding_id(ref_of(scope), p.name, declared_param_id(ctx, node, pi))
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
                let vparam_ty = resolve_type_value(ctx, unsafe: read(vtype))
                scope_set(ref_of(scope), tp.name, vparam_ty)
                scope_set_storage(ref_of(scope), tp.name, vparam_ty)
                scope_set_let(ref_of(scope), tp.name)
        tpi += 1
    var ret = types.primitive("void")
    let rt = return_type
    if rt != null:
        ret = resolve_type(ctx, rt)
    # The host's `run_nullability_pre_pass`: build the body's control-flow graph
    # and solve the non-null dataflow before checking any statement, so every
    # statement's check sees the narrowing that all incoming paths prove.
    flow_builder.cfg_clear(ref_of(ctx.flow_cfg))
    flow_builder.build_graph_into(ref_of(ctx.flow_cfg), ref_of(ctx.flow_graph), params, b)
    flow_graph.flow_init_into(ref_of(ctx.flow), ctx.flow_cfg.next_id, ctx.flow_graph.next_id)
    flow_graph.solve_nullability(ref_of(ctx.flow_graph), ref_of(ctx.flow))
    ctx.flow_active = true
    ctx.flow_recorded.clear()
    ctx.flow_scratch.clear()
    record_flow_barrier(ctx, line)
    ctx.inside_async = is_async
    check_stmt(ctx, ref_of(scope), check_flags(ret, false, false, false), b, null)
    ctx.inside_async = false
    ctx.flow_active = false
    check_definite_assignment(ctx, params, b)
    ctx.suppress_binding_records = false
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


## A type that is, or contains, an unresolved error or type variable is not a
## strict violation: the operand was already poisoned by an earlier diagnostic,
## or the enclosing generic body is only checked after instantiation.
function strict_assignability_exempt(t: types.Type) -> bool:
    return types.contains_error(t) or types.contains_type_var(t)


function strict_assignability_message(target: types.Type, source_ty: types.Type) -> str:
    var buf = string.String.create()
    buf.append("strict assignability: implicit ")
    buf.append(types.type_to_string(source_ty))
    buf.append(" -> ")
    buf.append(types.type_to_string(target))
    return buf.as_str()


function report_strict_assignability(
    ctx: ref[Context],
    target: types.Type,
    source_ty: types.Type,
    source_expr: ptr[ast.Expr]?,
) -> void:
    if strict_assignability_exempt(target) or strict_assignability_exempt(source_ty):
        return
    var line = ctx.statement_line
    var column = ctx.statement_column
    let expr = source_expr else:
        ctx.diagnostics.push(SemanticDiagnostic(
            line = line,
            column = column,
            length = 0,
            message = strict_assignability_message(target, source_ty),
            severity = "warning",
            code = "strict-types",
        ))
        return
    let expr_line = expr_source_line(expr)
    if expr_line != 0:
        line = expr_line
        column = expr_source_column(expr)
    ctx.diagnostics.push(SemanticDiagnostic(
        line = line,
        column = column,
        length = 0,
        message = strict_assignability_message(target, source_ty),
        severity = "warning",
        code = "strict-types",
    ))


## Assignment-site incompatibility check.  Delegates to the full positive
## type-compatibility rule (type_compatibility.mt), negating the result so this
## function continues to return true when types are incompatible.
##
## `const_values` is the analysis' `const` table, which the host's
## `exact_compile_time_numeric_compatibility?` folds against — a named constant
## whose value fits a numeric target is assignable (`const C: uint = 200;
## let x: ubyte = C`), one that does not is rejected (`256` into `ubyte`).
function incompatible_value_with_consts(
    ctx: ref[Context],
    target: types.Type,
    source_ty: types.Type,
    source_expr: ptr[ast.Expr]?,
    const_values: ref[map_mod.Map[str, ptr[ast.Expr]]],
) -> bool:
    let status = compat.types_compatibility_status(target, source_ty, source_expr, ptr_of(const_values))
    if ctx.strict_assignability and status.compatible and status.used_fallback:
        report_strict_assignability(ctx, target, source_ty, source_expr)
    return not status.compatible


function incompatible_external_value_with_consts(
    ctx: ref[Context],
    target: types.Type,
    source_ty: types.Type,
    source_expr: ptr[ast.Expr]?,
    const_values: ref[map_mod.Map[str, ptr[ast.Expr]]],
) -> bool:
    let status = compat.types_compatibility_external_status(target, source_ty, source_expr, ptr_of(const_values))
    if ctx.strict_assignability and status.compatible and status.used_fallback:
        report_strict_assignability(ctx, target, source_ty, source_expr)
    return not status.compatible


function incompatible_value(
    ctx: ref[Context],
    target: types.Type,
    source_ty: types.Type,
    source_expr: ptr[ast.Expr]?,
) -> bool:
    let status = compat.types_compatibility_status(target, source_ty, source_expr, null)
    if ctx.strict_assignability and status.compatible and status.used_fallback:
        report_strict_assignability(ctx, target, source_ty, source_expr)
    return not status.compatible

struct CheckFlags:
    ret: types.Type
    inside_loop: bool
    inside_defer: bool
    inside_parallel: bool


function check_flags(ret: types.Type, inside_loop: bool, inside_defer: bool, inside_parallel: bool) -> CheckFlags:
    return CheckFlags(
        ret = ret,
        inside_loop = inside_loop,
        inside_defer = inside_defer,
        inside_parallel = inside_parallel
    )


function check_body(ctx: ref[Context], scope: ref[sscope.Scope], chk: CheckFlags, body: ptr[ast.Stmt]?) -> void:
    let b = body else:
        return
    scope_enter(scope)
    check_stmt(ctx, scope, chk, b, null)
    scope_leave(scope)


## When `narrowed_name` is set, wrap the body check with a scope frame that
## shadows the variable with its non-nullable type.
function apply_narrow_by_name(
    ctx: ref[Context],
    scope: ref[sscope.Scope],
    narrowed_name: Option[str],
    narrowed_ty: types.Type,
    chk: CheckFlags,
    body: ptr[ast.Stmt]?
) -> void:
    match narrowed_name:
        Option.some as nnm:
            scope_enter(scope)
            scope_set(scope, nnm.value, narrowed_ty)
            check_body(ctx, scope, chk, body)
            scope_leave(scope)
        Option.none:
            check_body(ctx, scope, chk, body)


## Check one statement, applying the control-flow refinements the host's
## `check_block` applies around it: before the statement the non-null set every
## incoming path proves (its `apply_nullability_continuation_refinements!`), and
## after it the state the statement leaves — recorded so the LSP resolves a
## local's type the way the host's completion snapshots do.
function check_stmt(
    ctx: ref[Context],
    scope: ref[sscope.Scope],
    chk: CheckFlags,
    sp: ptr[ast.Stmt],
    next_stmt: ptr[ast.Stmt]?
) -> void:
    let start_pos = statement_position(sp)
    let saved_statement_line = ctx.statement_line
    let saved_statement_column = ctx.statement_column
    ctx.statement_line = start_pos / 1000000
    ctx.statement_column = start_pos % 1000000
    record_flow_snapshot_at(ctx, scope, start_pos, false, false)
    check_stmt_inner(ctx, scope, chk, sp)
    # The host applies the dataflow's non-null set for the *next* statement
    # right after this one, so the state it records at this statement's
    # position already carries that narrowing (`latest_completion_snapshot`
    # answers a guard line with it).
    if next_stmt != null:
        apply_flow_continuation(ctx, scope, next_stmt)
    # The host's `check_block` tail: the post-statement snapshot sits at the
    # statement's *end*, so a compound statement's post-record cannot shadow
    # its own body's entries; a multi-line statement additionally replays it at
    # its own start so a lookup on the declaration line finds the new binding.
    let end_line = statement_end_line(sp)
    if end_line == 0:
        record_flow_snapshot_at(ctx, scope, start_pos, false, false)
    else:
        if end_line > start_pos / 1000000:
            record_flow_snapshot_at(ctx, scope, start_pos, true, true)
        record_flow_snapshot_at(ctx, scope, end_line * 1000000 + 999999, false, false)
    ctx.statement_line = saved_statement_line
    ctx.statement_column = saved_statement_column


function check_stmt_inner(ctx: ref[Context], scope: ref[sscope.Scope], chk: CheckFlags, sp: ptr[ast.Stmt]) -> void:
    unsafe:
        match read(sp):
            ast.Stmt.stmt_block as blk:
                check_stmt_span(ctx, scope, chk, blk.statements)
            ast.Stmt.stmt_ret as r:
                check_return_stmt(ctx, scope, chk, r.line, r.column, r.value)
            ast.Stmt.stmt_local as l:
                check_local(
                    ctx,
                    scope,
                    chk,
                    l.is_let,
                    l.name,
                    l.stmt_type,
                    l.value,
                    l.else_binding,
                    l.else_body,
                    l.destructure_bindings,
                    l.line,
                    l.column,
                    l.else_binding_line,
                    l.else_binding_column
                )
            ast.Stmt.stmt_if as i:
                check_if_stmt(ctx, scope, chk, i.branches, i.else_body)
            ast.Stmt.stmt_while as w:
                check_while_stmt(ctx, scope, chk, w.is_inline, w.condition, w.body, w.line, w.column)
            ast.Stmt.stmt_for as fr:
                scope_enter(scope)
                bind_for_binding_types(ctx, scope, fr.bindings, fr.iterables, fr.threaded)
                if fr.threaded:
                    ctx.uses_parallel_for = true
                    check_body(ctx, scope, check_flags(chk.ret, true, chk.inside_defer, true), fr.body)
                else:
                    check_body(ctx, scope, check_flags(chk.ret, true, chk.inside_defer, chk.inside_parallel), fr.body)
                scope_leave(scope)
            ast.Stmt.stmt_match as m:
                check_match_stmt(ctx, scope, chk, m.scrutinee, m.arms, m.line, m.column)
            ast.Stmt.stmt_unsafe as u:
                ctx.unsafe_depth += 1
                ctx.unsafe_statement_lines.push(u.line)
                check_body(ctx, scope, chk, u.body)
                ctx.unsafe_depth -= 1
                let _popped_stmt = ctx.unsafe_statement_lines.pop()
            ast.Stmt.stmt_defer as d:
                if chk.inside_parallel:
                    report(ctx, d.line, d.column, "defer is not allowed inside a parallel block")
                check_body(ctx, scope, check_flags(chk.ret, chk.inside_loop, true, chk.inside_parallel), d.body)
            ast.Stmt.stmt_parallel_block as pb:
                if pb.bodies.len < 2:
                    report(ctx, pb.line, pb.column, "parallel block requires at least two statements")
                else if pb.bodies.len > ast.MAX_PARALLEL_ARMS:
                    report(
                        ctx,
                        pb.line,
                        pb.column,
                        "parallel block supports at most 64 statements; use std.jobs for larger fan-out"
                    )
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
                check_assignment_stmt(ctx, scope, a.target, a.value, a.operator, a.line, a.column)
            _:
                pass


function check_return_stmt(
    ctx: ref[Context],
    scope: ref[sscope.Scope],
    chk: CheckFlags,
    line: ptr_uint,
    column: ptr_uint,
    value: ptr[ast.Expr]?
) -> void:
    if chk.inside_defer:
        report(ctx, line, column, "return is not allowed inside a defer block")
    else if chk.inside_parallel:
        report(ctx, line, column, "return is not allowed inside a parallel block")
    let rv = value
    if rv != null:
        if types.is_void(chk.ret):
            report(ctx, line, column, "void function may not return a value")
        # The return type is the value's expected type (the host's
        # `lower_return_stmt` contextual lowering).
        let ret_saved_hint = ctx.expected_type_hint
        ctx.expected_type_hint = chk.ret
        let vt = infer_expr(ctx, scope, rv)
        ctx.expected_type_hint = ret_saved_hint
        if incompatible_value_with_consts(ctx, chk.ret, vt, rv, ref_of(ctx.const_values)):
            let rl = expr_source_line(rv)
            if rl == 0:
                report(ctx, line, column, return_mismatch_message(chk.ret, vt))
            else:
                report(ctx, rl, expr_source_column(rv), return_mismatch_message(chk.ret, vt))


function check_if_stmt(
    ctx: ref[Context],
    scope: ref[sscope.Scope],
    chk: CheckFlags,
    branches: span[ast.IfBranch],
    else_body: ptr[ast.Stmt]?
) -> void:
    unsafe:
        # The host's IfStmt arm: each branch is checked with the previous
        # branches' falsy refinements in scope, and an if whose every
        # branch body terminates continues with the *falsy* refinements —
        # the only way control can get past it.
        var false_refinements = map_mod.Map[str, types.Type].create()
        var all_terminate = true
        var bi2: ptr_uint = 0
        while bi2 < branches.len:
            var br: ast.IfBranch = read(branches.data + bi2)
            scope_enter(scope)
            apply_refinements_to_frame(ctx, scope, ref_of(false_refinements))
            check_condition(ctx, scope, br.condition, "if", br.line, br.column)
            var true_refs = flow_refinements(ctx, br.condition, true, scope)
            merge_refinements_into(ref_of(true_refs), ref_of(false_refinements))
            scope_enter(scope)
            apply_refinements_to_frame(ctx, scope, ref_of(true_refs))
            check_body(ctx, scope, chk, br.body)
            scope_leave(scope)
            true_refs.release()
            if not body_always_terminates(ctx, br.body):
                all_terminate = false
            var false_refs = flow_refinements(ctx, br.condition, false, scope)
            merge_refinements_into(ref_of(false_refinements), ref_of(false_refs))
            false_refs.release()
            scope_leave(scope)
            bi2 += 1
        if else_body != null:
            scope_enter(scope)
            apply_refinements_to_frame(ctx, scope, ref_of(false_refinements))
            check_body(ctx, scope, chk, else_body)
            scope_leave(scope)
        else:
            if all_terminate and branches.len > 0:
                apply_refinements_to_scope_frame(ctx, scope, ref_of(false_refinements))
        false_refinements.release()


function check_while_stmt(
    ctx: ref[Context],
    scope: ref[sscope.Scope],
    chk: CheckFlags,
    is_inline: bool,
    condition: ptr[ast.Expr],
    body: ptr[ast.Stmt]?,
    line: ptr_uint,
    column: ptr_uint
) -> void:
    if is_inline:
        match evaluate_const_expr(ctx, condition):
            Option.none:
                report(ctx, line, column, "inline while condition must be a compile-time constant")
                return
            Option.some:
                pass
    check_condition(ctx, scope, condition, "while", line, column)
    # The body runs only while the condition holds, so its truthy
    # refinements are in scope there (`while p != null: read(p)…`),
    # the host's `body_scopes = scopes_with_refinements(…)`.
    scope_enter(scope)
    var loop_refs = flow_refinements(ctx, condition, true, scope)
    apply_refinements_to_frame(ctx, scope, ref_of(loop_refs))
    check_body(ctx, scope, check_flags(chk.ret, true, chk.inside_defer, chk.inside_parallel), body)
    loop_refs.release()
    scope_leave(scope)


function check_match_stmt(
    ctx: ref[Context],
    scope: ref[sscope.Scope],
    chk: CheckFlags,
    scrutinee: ptr[ast.Expr],
    arms: span[ast.MatchArm],
    line: ptr_uint,
    column: ptr_uint
) -> void:
    unsafe:
        # The scrutinee's type is computed once, before the arms: an
        # `as name` arm binds the arm's payload type from it, and the
        # exhaustiveness pass reuses it (inferring twice would report
        # every unknown name in the scrutinee twice).
        let scrutinee_ty = infer_expr_inner(ctx, scope, scrutinee)
        # The host's dispatch rejects anything but an enum, variant, integer,
        # str or tuple before checking the arms.  Without it a payload struct
        # (`Outer.some as x` then `match x:`) passed analysis and reached the
        # lowering, which aborts with "match requires known type, got
        # Outer_some".  An error type is the parser-recovery path.
        if not match_scrutinee_supported(ctx, scrutinee_ty):
            report_at(ctx, line, column, 5, match_scrutinee_message(scrutinee_ty))
            return
        var ai: ptr_uint = 0
        while ai < arms.len:
            var arm: ast.MatchArm
            arm = read(arms.data + ai)
            scope_enter(scope)
            bind_match_arm_names(
                ctx,
                scope,
                scrutinee_ty,
                arm.binding_name,
                arm.pattern,
                arm.binding_line,
                arm.binding_column
            )
            check_body(ctx, scope, chk, arm.body)
            scope_leave(scope)
            ai += 1
        check_match(ctx, scope, scrutinee_ty, arms, line, column)


function check_assignment_stmt(
    ctx: ref[Context],
    scope: ref[sscope.Scope],
    target: ptr[ast.Expr],
    value: ptr[ast.Expr],
    operator: str,
    line: ptr_uint,
    column: ptr_uint
) -> void:
    let tt = infer_expr(ctx, scope, target)
    let target_ty = assign_target_type(scope, target, tt)
    # The target's type is the value's expected type (the host's
    # `lower_assignment_stmt` passes it to the value's inference).
    let assign_saved_hint = ctx.expected_type_hint
    if operator == "=":
        ctx.expected_type_hint = target_ty
    let vt = infer_expr(ctx, scope, value)
    ctx.expected_type_hint = assign_saved_hint
    if operator == "=":
        if incompatible_value_with_consts(ctx, target_ty, vt, value, ref_of(ctx.const_values)):
            report(ctx, line, column, assign_message(target_ty, vt))
    else if types.is_str(target_ty) and operator == "+=":
        report(ctx, line, column, "str += is not supported; use std.string.String for concatenation")
    else:
        let bin_op = operator.slice(0, operator.len - 1)
        let result_ty = infer_binary_operands(ctx, bin_op, target, value, target_ty, vt)
        if types.is_error(result_ty) and compound_assignment_checkable(target_ty, vt):
            report(ctx, line, column, "compound assignment is not supported for this type")
        else if incompatible_value_with_consts(ctx, target_ty, result_ty, target, ref_of(ctx.const_values)):
            report(ctx, line, column, assign_message(target_ty, result_ty))
    check_assign_target_immutable(ctx, scope, target, line, column)


## Compound-assignment diagnostics are limited to concrete operand shapes.
## Permissive generic/unresolved returns (`ty_error`, `ty_var`, `Task[T]`) must
## stay accepted; only a concrete target and value that the binary rules reject
## are reported.
function compound_assignment_checkable(target_ty: types.Type, value_ty: types.Type) -> bool:
    if types.is_error(target_ty) or types.is_error(value_ty):
        return false
    return concrete_compound_operand(target_ty) and concrete_compound_operand(value_ty)


function concrete_compound_operand(t: types.Type) -> bool:
    match t:
        types.Type.ty_primitive:
            return true
        types.Type.ty_str:
            return true
        types.Type.ty_named:
            return true
        _:
            return false


## The type an assignment target is checked against.  A plain identifier uses
## its *storage* type — the host's `infer_lvalue` → `binding.storage_type` — so
## a binding the flow refinement narrowed is still assigned its declared type;
## member and index targets keep the refined receiver type.
function assign_target_type(scope: ref[sscope.Scope], target: ptr[ast.Expr], inferred: types.Type) -> types.Type:
    unsafe:
        match read(target):
            ast.Expr.expr_identifier as id:
                let storage = scope_get_storage(scope, id.name)
                if storage != null:
                    return read(storage)
            _:
                pass
    return inferred


function check_condition(
    ctx: ref[Context],
    scope: ref[sscope.Scope],
    cond: ptr[ast.Expr],
    keyword: str,
    line: ptr_uint,
    column: ptr_uint
) -> void:
    let ct = infer_expr(ctx, scope, cond)
    if types.contains_error(ct):
        return
    # An unresolved generic parameter stays permissive (the host's
    # `types_compatible?` has no rule that makes a TypeVar incompatible with
    # bool); every concrete non-bool type rejects.
    match ct:
        types.Type.ty_var:
            return
        _:
            pass
    if not types.is_bool_type(ct):
        report(ctx, line, column, condition_message(keyword, ct))


## Compute the type refinements that flow from a condition being true or false.
## Returns a map of variable names to their narrowed types.  Handles:
##   * `x != null` / `x == null` — null-pointer narrowing
##   * `not cond` — delegates with flipped truthy
##   * `a and b` — merges when truthy, left-only when falsy (short-circuit)
##   * `a or b` — left-only when truthy, merges when falsy (short-circuit)
function flow_refinements(
    ctx: ref[Context],
    cond: ptr[ast.Expr],
    truthy: bool,
    scope: ref[sscope.Scope]
) -> map_mod.Map[str, types.Type]:
    var result = map_mod.Map[str, types.Type].create()
    unsafe:
        match read(cond):
            ast.Expr.expr_unary_op as u:
                if u.operator == "not":
                    return flow_refinements(ctx, u.operand, not truthy, scope)
            ast.Expr.expr_binary_op as b:
                if b.operator == "and":
                    # Only the truthy side refines (`a and b` false says nothing
                    # about `a`); the host's `flow_refinements` returns `{}` for
                    # the falsy case (`flow_refinement.rb:79-85`).
                    if truthy:
                        var left = flow_refinements(ctx, b.left, true, scope)
                        merge_refinements_into(ref_of(result), ref_of(left))
                        apply_refinements_to_frame(ctx, scope, ref_of(left))
                        var right = flow_refinements(ctx, b.right, true, scope)
                        merge_refinements_into(ref_of(result), ref_of(right))
                    return result
                if b.operator == "or":
                    # Symmetric with `and`: only the falsy side refines.
                    if not truthy:
                        var left = flow_refinements(ctx, b.left, false, scope)
                        merge_refinements_into(ref_of(result), ref_of(left))
                        apply_refinements_to_frame(ctx, scope, ref_of(left))
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
function null_test_refinements(
    ctx: ref[Context],
    condp: ptr[ast.Expr],
    truthy: bool,
    scope: ref[sscope.Scope]
) -> map_mod.Map[str, types.Type]:
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

                let type_ptr = refinement_type_ptr(ctx, scope, name_value)
                if type_ptr == null:
                    return result

                unsafe:
                    match read(type_ptr):
                        types.Type.ty_nullable as nullable:
                            # The host's `null_test_refinements`: the truth of
                            # `x == null` (and the falsity of `x != null`)
                            # refines to the bare `null`, the other direction to
                            # the base type.
                            let null_result = if is_negated: not truthy else: truthy
                            if null_result:
                                result.set(name_value, types.Type.ty_null(target = null))
                            else:
                                result.set(name_value, read(nullable.base))
                        _:
                            pass
            _:
                pass

    return result


## Apply the CFG's non-null set for `sp` to the scope: every binding the
## dataflow proves non-null on all incoming paths narrows from `T?` to `T`
## before the statement is checked (the host's
## `apply_nullability_continuation_refinements!`).
function apply_flow_continuation(ctx: ref[Context], scope: ref[sscope.Scope], sp: ptr[ast.Stmt]) -> void:
    if not ctx.flow_active:
        return
    let stmt_key = unsafe: reinterpret[ptr_uint](sp)
    let node = flow_graph.graph_node_for_statement(ref_of(ctx.flow_graph), stmt_key)
    if node == 0:
        return
    var key: ptr_uint = 1
    while key < ctx.flow_cfg.next_id:
        if flow_graph.nonnull_before(ref_of(ctx.flow), node, key):
            let name = flow_builder.cfg_binding_name(ref_of(ctx.flow_cfg), key)
            if name.len > 0:
                let type_ptr = refinement_type_ptr(ctx, scope, name)
                if type_ptr != null:
                    unsafe:
                        match read(type_ptr):
                            types.Type.ty_nullable as nullable:
                                note_refinement_storage(ctx, scope, name)
                                scope_set(scope, name, read(nullable.base))
                            _:
                                pass
        key += 1


## Record the refinement state at a statement boundary: only the entries that
## changed since the previous recording.  The LSP and the lowering resolve a
## local's type through the *last record* at or before the cursor (the host's
## `latest_completion_snapshot` walks its snapshots in reverse), so the
## position is a filter and the recording order decides.
function record_flow_snapshot(ctx: ref[Context], scope: ref[sscope.Scope], sp: ptr[ast.Stmt]) -> void:
    record_flow_snapshot_at(ctx, scope, statement_position(sp), false, false)


## The body of `record_flow_snapshot` with an explicit packed position, so the
## post-statement snapshot can be recorded at the statement's *end* (the host's
## `check_block` tail records at `(end_line, 1_000_000)`), and so the
## multi-line replay at the statement's start can skip cleared transitions:
## the replay exists so a lookup on the declaration line finds the new binding,
## and its cleared entries would shadow the very body entries a cursor inside
## the statement still sits under (they are recorded after them, and the
## cursor's lookup takes the last record).
##
## A replay is a *view* of the post-statement state at the statement's start,
## not a state transition: it must not advance `flow_recorded`.  Advancing it
## would suppress the genuine end-of-statement record (the state now "matches"
## what the replay claimed), leaving the lowering's greatest-position lookup
## with only the statement body's inner records — a branch refinement that has
## already gone out of scope (`std/map.mt`'s `previous = node` after the
## `if previous == null` arm).
function record_flow_snapshot_at(
    ctx: ref[Context],
    scope: ref[sscope.Scope],
    position: ptr_uint,
    skip_clears: bool,
    replay: bool
) -> void:
    if not ctx.flow_active:
        return
    if position == 0:
        return
    ctx.flow_scratch.clear()
    var fi: ptr_uint = 0
    while fi < scope.frames.len():
        let frame_ptr = scope.frames.get(fi) else:
            break
        var entries = unsafe: read(frame_ptr).entries()
        while entries.next():
            let entry = entries.current()
            unsafe:
                flow_scratch_set(ref_of(ctx.flow_scratch), read(entry.key), read(entry.value))
        fi += 1
    var si: ptr_uint = 0
    while si < ctx.flow_scratch.len():
        let item = ctx.flow_scratch.get(si) else:
            break
        unsafe:
            let name = read(item).name
            let ty = read(item).ty
            let previous = ctx.flow_recorded.get(name)
            var changed = true
            if previous != null:
                changed = not types.type_equals(read(previous), ty)
            if changed:
                if ctx.tooling_facts:
                    ctx.flow_types.push(FlowTypeEntry(at = position, name = name, ty = ty, cleared = false))
                if not replay:
                    let _prev = ctx.flow_recorded.set(name, ty)
        si += 1
    var to_clear = vec.Vec[str].create()
    defer: to_clear.release()
    var recorded = ctx.flow_recorded.entries()
    while recorded.next():
        let entry = recorded.current()
        unsafe:
            let name = read(entry.key)
            if not flow_scratch_contains(ref_of(ctx.flow_scratch), name):
                if not skip_clears:
                    to_clear.push(name)
                    if ctx.tooling_facts:
                        ctx.flow_types.push(FlowTypeEntry(
                            at = position,
                            name = name,
                            ty = types.Type.ty_error,
                            cleared = true
                        ))
    var ci: ptr_uint = 0
    while ci < to_clear.len():
        let name_ptr = to_clear.get(ci) else:
            break
        unsafe:
            let _removed = ctx.flow_recorded.remove(read(name_ptr))
        ci += 1


## The host's `statement_end_line`: the last source line a statement occupies —
## its own line plus every nested body's and expression's last line.  The
## refinement record's post-statement snapshot is positioned here, so a compound
## statement's post-record (its body's scope left, refinements settled) sorts
## after every record its body made instead of clobbering them.
function statement_end_line(sp: ptr[ast.Stmt]) -> ptr_uint:
    var line = stmt_own_line(sp)
    unsafe:
        match read(sp):
            ast.Stmt.stmt_block as blk:
                line = statements_last_line(blk.statements)
            ast.Stmt.stmt_local as l:
                line = max_u(line, expr_last_line(l.value))
                line = max_u(line, body_last_line(l.else_body))
            ast.Stmt.stmt_if as i:
                var bi: ptr_uint = 0
                while bi < i.branches.len:
                    let br = read(i.branches.data + bi)
                    line = max_u(line, br.line)
                    line = max_u(line, expr_last_line(br.condition))
                    line = max_u(line, body_last_line(br.body))
                    bi += 1
                line = max_u(line, body_last_line(i.else_body))
            ast.Stmt.stmt_while as w:
                line = max_u(line, expr_last_line(w.condition))
                line = max_u(line, body_last_line(w.body))
            ast.Stmt.stmt_for as fr:
                line = max_u(line, body_last_line(fr.body))
            ast.Stmt.stmt_match as m:
                var ai: ptr_uint = 0
                while ai < m.arms.len:
                    let arm = read(m.arms.data + ai)
                    line = max_u(line, expr_last_line(arm.pattern))
                    line = max_u(line, body_last_line(arm.body))
                    ai += 1
            ast.Stmt.stmt_defer as d:
                line = max_u(line, expr_last_line(d.expression))
                line = max_u(line, body_last_line(d.body))
            ast.Stmt.stmt_unsafe as u:
                line = max_u(line, body_last_line(u.body))
            ast.Stmt.stmt_error_block as eb:
                line = max_u(line, body_last_line(eb.body))
            ast.Stmt.stmt_assignment as a:
                line = max_u(line, expr_last_line(a.value))
            ast.Stmt.stmt_ret as r:
                line = max_u(line, expr_last_line(r.value))
            ast.Stmt.stmt_expression as e:
                line = max_u(line, expr_last_line(e.expression))
            ast.Stmt.stmt_static_assert as sa:
                line = max_u(line, expr_last_line(sa.condition))
            _:
                pass
    return line


## The statement's own source line (0 for a block, which carries none).
function stmt_own_line(sp: ptr[ast.Stmt]) -> ptr_uint:
    unsafe:
        match read(sp):
            ast.Stmt.stmt_local as l:
                return l.line
            ast.Stmt.stmt_assignment as a:
                return a.line
            ast.Stmt.stmt_if as i:
                return i.line
            ast.Stmt.stmt_while as w:
                return w.line
            ast.Stmt.stmt_for as fr:
                return fr.line
            ast.Stmt.stmt_match as m:
                return m.line
            ast.Stmt.stmt_ret as r:
                return r.line
            ast.Stmt.stmt_break as b:
                return b.line
            ast.Stmt.stmt_continue as c:
                return c.line
            ast.Stmt.stmt_pass as p:
                return p.line
            ast.Stmt.stmt_defer as d:
                return d.line
            ast.Stmt.stmt_unsafe as u:
                return u.line
            ast.Stmt.stmt_expression as e:
                return e.line
            ast.Stmt.stmt_static_assert as sa:
                return sa.line
            ast.Stmt.stmt_emit as em:
                return em.line
            ast.Stmt.stmt_when as w:
                return w.line
            ast.Stmt.stmt_parallel_block as pb:
                return pb.line
            ast.Stmt.stmt_gather as g:
                return g.line
            ast.Stmt.stmt_error as er:
                return er.line
            ast.Stmt.stmt_error_block as eb:
                return eb.line
            ast.Stmt.stmt_block:
                return 0
    return 0


## The last line of a statement body (a block or one statement), 0 when absent.
function body_last_line(body: ptr[ast.Stmt]?) -> ptr_uint:
    let b = body else:
        return 0
    return statement_end_line(b)


function statements_last_line(stmts: span[ast.Stmt]) -> ptr_uint:
    var last: ptr_uint = 0
    var si: ptr_uint = 0
    while si < stmts.len:
        unsafe:
            last = max_u(last, statement_end_line(stmts.data + si))
        si += 1
    return last


## The host's `expression_last_line`: the last line an expression occupies.
function expr_last_line(e: ptr[ast.Expr]?) -> ptr_uint:
    let ep = e else:
        return 0
    var line: ptr_uint = 0
    unsafe:
        match read(ep):
            ast.Expr.expr_member_access as ma:
                line = expr_last_line(ma.receiver)
            ast.Expr.expr_index_access as ix:
                line = max_u(expr_last_line(ix.receiver), expr_last_line(ix.index))
            ast.Expr.expr_specialization as sp:
                line = expr_last_line(sp.callee)
            ast.Expr.expr_call as cl:
                line = expr_last_line(cl.callee)
                var ai: ptr_uint = 0
                while ai < cl.args.len:
                    line = max_u(line, expr_last_line(read(cl.args.data + ai).arg_value))
                    ai += 1
            ast.Expr.expr_unary_op as u:
                line = expr_last_line(u.operand)
            ast.Expr.expr_binary_op as b:
                line = max_u(expr_last_line(b.left), expr_last_line(b.right))
            ast.Expr.expr_if as ife:
                line = max_u(expr_last_line(ife.condition), expr_last_line(ife.then_expr))
                line = max_u(line, expr_last_line(ife.else_expr))
            ast.Expr.expr_match as me:
                line = expr_last_line(me.scrutinee)
                var mi: ptr_uint = 0
                while mi < me.arms.len:
                    let arm = read(me.arms.data + mi)
                    line = max_u(line, expr_last_line(arm.pattern))
                    line = max_u(line, expr_last_line(arm.value))
                    mi += 1
            ast.Expr.expr_await as aw:
                line = expr_last_line(aw.expression)
            ast.Expr.expr_format_string as fs:
                var pi: ptr_uint = 0
                while pi < fs.parts.len:
                    match read(fs.parts.data + pi):
                        ast.FormatStringPart.fmt_expr as fe:
                            line = max_u(line, expr_last_line(fe.expression))
                        _:
                            pass
                    pi += 1
            ast.Expr.expr_prefix_cast as pc:
                line = expr_last_line(pc.expression)
            _:
                pass
    return line


function max_u(a: ptr_uint, b: ptr_uint) -> ptr_uint:
    return if b > a: b else: a


## Mark the start of a function body's refinement record: entries recorded
## before the barrier belong to an earlier body and cannot apply past it.
function record_flow_barrier(ctx: ref[Context], line: ptr_uint) -> void:
    if line == 0:
        return
    if ctx.tooling_facts:
        ctx.flow_types.push(FlowTypeEntry(
            at = (line - 1) * 1000000 + 999999,
            name = "",
            ty = types.Type.ty_error,
            cleared = true
        ))


## The analyzer's refinement record for a local at a position: the type the
## host resolves there (`infer_expression_type`'s binding) — used by the LSP's
## hover/documentHighlight cursor lookups and by the lowering wherever the host
## reads a refined local (`reinterpret`'s source type after a null guard).
## Bodies are checked in two passes (functions, then `extending` methods), so a
## body's records are not positionally contiguous with the check order: the
## cursor's body is the one whose start barrier (`record_flow_barrier`) has the
## greatest position at or before the cursor (bodies' line ranges are disjoint),
## and only that body's record span — from just after its barrier up to the next
## barrier — is scanned.  Within it, entries are read in recording order and the
## last one at or before the position wins (the host's
## `latest_completion_snapshot` walks its snapshots in reverse with the position
## as a filter), so a post-statement snapshot recorded at an earlier line still
## answers a later position (the same carry-forward a documentHighlight entry
## shows).  None when the name has no entry there, so the declaration's own
## type stands.
public function flow_type_at(
    analysis: ref[Analysis],
    name: str,
    line: ptr_uint,
    character: ptr_uint
) -> Option[types.Type]:
    let at = line * 1000000 + character
    var body_start: ptr_uint = 0
    var start_index: ptr_uint = 0
    var i: ptr_uint = 0
    while i < unsafe: read(analysis).flow_types.len():
        let entry = unsafe: read(analysis).flow_types.get(i) else:
            break
        unsafe:
            let item = read(entry)
            if item.name.len == 0 and item.at <= at and item.at >= body_start:
                body_start = item.at
                start_index = i + 1
        i += 1
    var best = types.Type.ty_error
    var found = false
    var has_type = false
    i = start_index
    while i < unsafe: read(analysis).flow_types.len():
        let entry = unsafe: read(analysis).flow_types.get(i) else:
            break
        unsafe:
            let item = read(entry)
            if item.name.len == 0:
                break
            if item.at <= at and item.name.equal(name):
                # The *last record* at or before the cursor wins (the host's
                # `latest_completion_snapshot` walks its snapshots in reverse),
                # with the position only a filter: a statement's post-record is
                # appended after its body's entries, so the recorded order — not
                # the greatest position — decides which one answers.
                best = item.ty
                has_type = not item.cleared
                found = true
        i += 1
    if not found or not has_type:
        return Option[types.Type].none
    return Option[types.Type].some(value = best)


## The snapshot key of a statement: its position packed into one comparable
## number (`line * 1000000 + column`).  A statement that carries no column uses
## 0, so its entry applies from the start of its line.
function statement_position(sp: ptr[ast.Stmt]) -> ptr_uint:
    unsafe:
        match read(sp):
            ast.Stmt.stmt_local as l:
                return l.line * 1000000 + l.column
            ast.Stmt.stmt_assignment as a:
                return a.line * 1000000 + a.column
            ast.Stmt.stmt_if as i:
                return i.line * 1000000
            ast.Stmt.stmt_while as w:
                return w.line * 1000000 + w.column
            ast.Stmt.stmt_for as f:
                return f.line * 1000000 + f.column
            ast.Stmt.stmt_match as m:
                return m.line * 1000000 + m.column
            ast.Stmt.stmt_ret as r:
                return r.line * 1000000 + r.column
            ast.Stmt.stmt_break as b:
                return b.line * 1000000 + b.column
            ast.Stmt.stmt_continue as c:
                return c.line * 1000000 + c.column
            ast.Stmt.stmt_pass as p:
                return p.line * 1000000 + p.column
            ast.Stmt.stmt_defer as d:
                return d.line * 1000000 + d.column
            ast.Stmt.stmt_unsafe as u:
                return u.line * 1000000 + u.column
            ast.Stmt.stmt_expression as e:
                return e.line * 1000000
            ast.Stmt.stmt_static_assert as s:
                return s.line * 1000000
            ast.Stmt.stmt_emit as em:
                return em.line * 1000000 + em.column
            ast.Stmt.stmt_when as w:
                return w.line * 1000000 + w.column
            ast.Stmt.stmt_parallel_block as pb:
                return pb.line * 1000000 + pb.column
            ast.Stmt.stmt_gather as g:
                return g.line * 1000000 + g.column
            ast.Stmt.stmt_error as er:
                return er.line * 1000000 + er.column
            ast.Stmt.stmt_error_block as eb:
                return eb.line * 1000000 + eb.column
            ast.Stmt.stmt_block as blk:
                if blk.statements.len > 0:
                    return statement_position(blk.statements.data + 0)
                return 0
    return 0


## True when control cannot fall out of `body` (the host's
## `cfg_block_always_terminates?`, answered on the body's CFG).
function body_always_terminates(ctx: ref[Context], body: ptr[ast.Stmt]?) -> bool:
    if not ctx.flow_active:
        return false
    return flow_graph.graph_body_terminates(ref_of(ctx.flow_graph), body)


function flow_scratch_set(scratch: ref[vec.Vec[FlowName]], name: str, ty: types.Type) -> void:
    var i: ptr_uint = 0
    while i < scratch.len():
        let item = scratch.get(i) else:
            break
        unsafe:
            if read(item).name.equal(name):
                read(item).ty = ty
                return
        i += 1
    scratch.push(FlowName(name = name, ty = ty))


function flow_scratch_contains(scratch: ref[vec.Vec[FlowName]], name: str) -> bool:
    var i: ptr_uint = 0
    while i < scratch.len():
        let item = scratch.get(i) else:
            break
        if unsafe: read(item).name.equal(name):
            return true
        i += 1
    return false


## Copy all entries from `incoming` into `existing`.  When a key is already
## present in both and has a different type, it is removed (ambiguous state).
function merge_refinements_into(
    existing: ref[map_mod.Map[str, types.Type]],
    incoming: ref[map_mod.Map[str, types.Type]]
) -> void:
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
function apply_refinements_to_frame(
    ctx: ref[Context],
    scope: ref[sscope.Scope],
    refinements: ref[map_mod.Map[str, types.Type]]
) -> void:
    var entries = refinements.entries()
    while true:
        if not entries.next():
            break
        unsafe:
            let entry = entries.current()
            note_refinement_storage(ctx, scope, read(entry.key))
            scope_set(scope, read(entry.key), read(entry.value))


## Apply refinements directly to the current scope frame without entering a new
## one — for post-if refinements that persist beyond the if/else block.
function apply_refinements_to_scope_frame(
    ctx: ref[Context],
    scope: ref[sscope.Scope],
    refinements: ref[map_mod.Map[str, types.Type]]
) -> void:
    var entries = refinements.entries()
    while true:
        if not entries.next():
            break
        unsafe:
            let entry = entries.current()
            note_refinement_storage(ctx, scope, read(entry.key))
            scope_set(scope, read(entry.key), read(entry.value))


## The type a refinement reads for `name`: the scope binding's current type, or
## a module-level value's declared type.  The host seeds module bindings into its
## scopes, so its flow refinements narrow globals the same way locals are.
function refinement_type_ptr(ctx: ref[Context], scope: ref[sscope.Scope], name: str) -> ptr[types.Type]?:
    let scoped = scope_get(scope, name)
    if scoped != null:
        return scoped
    return ctx.value_types.get(name)


## Record the declared type of a module-level value as the storage type of a
## refinement frame, so an assignment to the refined name is still checked
## against the declared type (`assign_target_type`).  A scope binding's storage
## is already recorded at its declaration.
function note_refinement_storage(ctx: ref[Context], scope: ref[sscope.Scope], name: str) -> void:
    if scope_get_storage(scope, name) != null:
        return
    let declared = ctx.value_types.get(name)
    if declared != null:
        unsafe:
            scope_set_storage(scope, name, read(declared))


function check_when_statement(
    ctx: ref[Context],
    scope: ref[sscope.Scope],
    chk: CheckFlags,
    discriminant: ptr[ast.Expr],
    branches: span[ast.WhenBranch],
    else_body: ptr[ast.Stmt]?
) -> void:
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
            # The dataflow's non-null set narrows the scope before the *next*
            # statement (the host's `apply_nullability_continuation_refinements!`),
            # so each statement's check sees what every incoming path proves.
            var next: ptr[ast.Stmt]? = null
            if i + 1 < stmts.len:
                next = stmts.data + i + 1
            check_stmt(ctx, scope, chk, stmts.data + i, next)
        i += 1


## Match validation dispatched on the scrutinee type:
##  * enum/variant   -> exhaustiveness ("missing cases") + duplicate-arm
##  * integer/str    -> requires a wildcard `_` arm + duplicate integer value
##  * anything else  -> permissive
## Enum/variant checks bail out if any arm is not a plain `Type.case` pattern
## (e.g. payload destructuring), so guarded/complex matches never false-positive.
function check_match(
    ctx: ref[Context],
    scope: ref[sscope.Scope],
    scrutinee_ty: types.Type,
    arms: span[ast.MatchArm],
    line: ptr_uint,
    column: ptr_uint
) -> void:
    var patterns = vec.Vec[ptr[ast.Expr]?].create()
    defer: patterns.release()
    var i: ptr_uint = 0
    while i < arms.len:
        unsafe:
            patterns.push(read(arms.data + i).pattern)
        i += 1
    check_match_patterns(ctx, scrutinee_ty, patterns.as_span(), line, column)


## The exhaustiveness/wildcard/duplicate-arm pass shared by match statements and
## match expressions.  `patterns` carries one optional pattern per arm; a null
## pattern is the wildcard arm.
function check_match_patterns(
    ctx: ref[Context],
    scrutinee_ty: types.Type,
    patterns: span[ptr[ast.Expr]?],
    line: ptr_uint,
    column: ptr_uint
) -> void:
    # The scrutinee's type arrives precomputed (and unrecorded — this is a
    # diagnostic-only pass that must not mutate the `resolved_expr_types` map
    # that lowering later consumes).
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
                check_case_match(ctx, owning_module, nm.value, patterns, line, column)
                return
        Option.none:
            pass

    # Integer scrutinee: requires a wildcard `_` arm, plus duplicate-value check.
    # String scrutinee: requires a wildcard `_` arm.  Anything else is permissive.
    match scrutinee_ty:
        types.Type.ty_primitive as p:
            if is_integer_name(p.name):
                check_scalar_match(ctx, patterns, line, column, integer_wildcard_message(p.name), true)
        types.Type.ty_str:
            check_scalar_match(ctx, patterns, line, column, str_wildcard_message(), false)
        _:
            pass


## Match-expression form: the same pattern checks as a match statement.
function check_match_expression_arms(
    ctx: ref[Context],
    scrutinee_ty: types.Type,
    arms: span[ast.MatchExprArm],
    line: ptr_uint,
    column: ptr_uint
) -> void:
    var patterns = vec.Vec[ptr[ast.Expr]?].create()
    defer: patterns.release()
    var i: ptr_uint = 0
    while i < arms.len:
        unsafe:
            patterns.push(read(arms.data + i).pattern)
        i += 1
    check_match_patterns(ctx, scrutinee_ty, patterns.as_span(), line, column)


## The name of a nominal (enum/variant/struct) type, for `match_case_names`
## lookup.  Local types are `ty_named`; imported types are `ty_imported`.
function scrutinee_type_name(t: types.Type) -> Option[str]:
    match t:
        types.Type.ty_named as n:
            let n_np = unsafe: read(n.payload)
            return Option[str].some(value = n_np.name)
        types.Type.ty_imported as im:
            let im_bp = unsafe: read(im.payload)
            return Option[str].some(value = im_bp.name)
        _:
            return Option[str].none


## The module owning an imported scrutinee type ("" for a local one).
function scrutinee_type_module(t: types.Type) -> str:
    match t:
        types.Type.ty_imported as im:
            let im_bp = unsafe: read(im.payload)
            return im_bp.module_name
        _:
            return ""


## The member/arm-name table for `type_name` declared in `module_name` ("" =
## the current module), or null when the type has no case table.
function match_case_names_for(ctx: ref[Context], module_name: str, type_name: str) -> ptr[span[str]]?:
    if module_name.len == 0 or module_name == ctx.module_name:
        return ctx.match_case_names.get(type_name)
    let binding_ptr = find_binding(ctx, module_name) else:
        return null
    return unsafe: read(binding_ptr).match_case_names.get(type_name)


## The host's match-scrutinee dispatch (`check_match_stmt` /
## `infer_match_expression`): an enum or variant (local or imported), an
## integer, `str`, or a tuple.  Flags are not matchable (the host dispatches
## `Types::Enum`, and `Types::Flags` is a sibling), and neither is a payload
## struct — the case that used to reach the lowering fatal.  A recovered
## (`<error>`) scrutinee keeps the permissive arm checks.
function match_scrutinee_supported(ctx: ref[Context], t: types.Type) -> bool:
    if types.is_error(t):
        return true
    match t:
        types.Type.ty_primitive as p:
            return is_integer_name(p.name)
        types.Type.ty_str:
            return true
        types.Type.ty_tuple:
            return true
        types.Type.ty_named as n:
            let n_np = unsafe: read(n.payload)
            return match_case_names_for(ctx, "", n_np.name) != null
        types.Type.ty_imported as im:
            let im_bp = unsafe: read(im.payload)
            # A prelude variant keeps its arm table in the local context even
            # when its nominal module is `std.option`/`std.result` (a
            # single-file check has no import bindings).
            if im_bp.module_name.len == 0 or prelude_variant_module(im_bp.name).len > 0:
                return match_case_names_for(ctx, "", im_bp.name) != null
            return match_case_names_for(ctx, im_bp.module_name, im_bp.name) != null
        types.Type.ty_generic as g:
            let g_bp = unsafe: read(g.payload)
            return match_case_names_for(ctx, "", g_bp.name) != null
        _:
            return false


## The host's `to_s` for the scrutinee in the match error: a nominal type
## carries its declaring module (`tmp.main.S`, `std.vec.Vec[int]`), the rest
## come from `type_to_string`.
function match_scrutinee_text(t: types.Type) -> str:
    match t:
        types.Type.ty_named as n:
            let n_np = unsafe: read(n.payload)
            if n_np.module_name.len == 0:
                return n_np.name
            var buf = string.String.create()
            buf.append(n_np.module_name)
            buf.append(".")
            buf.append(n_np.name)
            return buf.as_str()
        types.Type.ty_imported as im:
            let im_bp = unsafe: read(im.payload)
            var buf = string.String.create()
            if im_bp.module_name.len > 0:
                buf.append(im_bp.module_name)
                buf.append(".")
            buf.append(im_bp.name)
            if im_bp.args.len > 0:
                buf.append("[")
                var ai: ptr_uint = 0
                while ai < im_bp.args.len:
                    if ai > 0:
                        buf.append(", ")
                    buf.append(match_scrutinee_text(unsafe: read(im_bp.args.data + ai)))
                    ai += 1
                buf.append("]")
            return buf.as_str()
        types.Type.ty_nullable as nl:
            var buf = string.String.create()
            buf.append(match_scrutinee_text(unsafe: read(nl.base)))
            buf.append("?")
            return buf.as_str()
        _:
            return types.type_to_string(t)


function match_scrutinee_message(t: types.Type) -> str:
    var buf = string.String.create()
    buf.append("match requires an enum, variant, or integer scrutinee, got ")
    buf.append(match_scrutinee_text(t))
    return buf.as_str()


function check_case_match(
    ctx: ref[Context],
    module_name: str,
    type_name: str,
    patterns: span[ptr[ast.Expr]?],
    line: ptr_uint,
    column: ptr_uint
) -> void:
    let namesp = match_case_names_for(ctx, module_name, type_name) else:
        return
    var covered = vec.Vec[str].create()
    var has_wild = false
    var i: ptr_uint = 0
    while i < patterns.len:
        let p = unsafe: read(patterns.data + i)
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


function check_scalar_match(
    ctx: ref[Context],
    patterns: span[ptr[ast.Expr]?],
    line: ptr_uint,
    column: ptr_uint,
    wildcard_message: str,
    check_duplicate_int: bool
) -> void:
    var has_wild = false
    var seen = vec.Vec[int].create()
    var i: ptr_uint = 0
    while i < patterns.len:
        let p = unsafe: read(patterns.data + i)
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

const INT_SUFFIX_UB: str = "ub"
const INT_SUFFIX_US: str = "us"
const INT_SUFFIX_UL: str = "ul"
const INT_SUFFIX_IZ: str = "iz"


public function integer_suffix_type_name(lexeme: str) -> Option[str]:
    if lexeme.ends_with(INT_SUFFIX_UB):
        return Option[str].some(value = "ubyte")
    if lexeme.ends_with(INT_SUFFIX_US):
        return Option[str].some(value = "ushort")
    if lexeme.ends_with(INT_SUFFIX_UL):
        return Option[str].some(value = "ulong")
    if lexeme.ends_with(INT_SUFFIX_IZ):
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


## Bind a for loop's variables to their iterables' element types — the host's
## `check_for_stmt` binding half.  A range yields its bounds' (harmonized)
## integer type, an array/span its element (a `ref[element]` for a struct
## element), and anything else runs the iterator protocol: `iter()`'s result's
## `next()`, whose nullable pointer-like item is the element (a `bool` next
## yields `current()`).  The iterables are inferred here too, so nested
## operations are checked and their unsafe requirements recorded; anything the
## self cannot resolve stays at the permissive error type.
function bind_for_binding_types(
    ctx: ref[Context],
    scope: ref[sscope.Scope],
    bindings: span[ast.ForBinding],
    iterables: span[ast.Expr],
    threaded: bool
) -> void:
    var i: ptr_uint = 0
    while i < bindings.len:
        var binding_name: str = ""
        var binding_ty: types.Type = types.Type.ty_error
        var binding_id: ptr_uint = 0
        unsafe:
            let binding = read(bindings.data + i)
            binding_name = binding.name
            binding_id = preassigned_binding_id_for(ctx, binding_key(binding.line, binding.column))
        if i < iterables.len:
            var iterable_ptr: ptr[ast.Expr] = unsafe: iterables.data + i
            binding_ty = for_binding_type(ctx, scope, iterable_ptr, threaded)
        scope_set(scope, binding_name, binding_ty)
        scope_set_storage(scope, binding_name, binding_ty)
        scope_set_binding_id(scope, binding_name, binding_id)
        record_binding_type(ctx, binding_id, binding_ty)
        record_declaration_site(ctx, unsafe: reinterpret[ptr_uint](bindings.data + i), binding_id)
        i += 1


function for_binding_type(
    ctx: ref[Context],
    scope: ref[sscope.Scope],
    iterable: ptr[ast.Expr],
    threaded: bool
) -> types.Type:
    match range_loop_element_type(ctx, scope, iterable):
        Option.some as range_ty:
            return range_ty.value
        Option.none:
            pass
    let iterable_ty = infer_expr(ctx, scope, iterable)
    match collection_loop_element_type(iterable_ty):
        Option.some as element_ty:
            return collection_loop_binding_type(ctx, element_ty.value)
        Option.none:
            pass
    if threaded:
        # The host's parallel for accepts arrays and spans only; the self stays
        # permissive for the rest instead of reporting.
        return types.Type.ty_error
    return iterator_loop_element_type(ctx, iterable_ty)


## A `start..stop` for-loop iterable yields its bounds' (harmonized) integer
## type — the host's `check_range_expr_loop`.  None for anything else.
function range_loop_element_type(
    ctx: ref[Context],
    scope: ref[sscope.Scope],
    iterable: ptr[ast.Expr]
) -> Option[types.Type]:
    unsafe:
        match read(iterable):
            ast.Expr.expr_range as range:
                let start_ty = infer_expr(ctx, scope, range.start_expr)
                let _stop_ty = infer_expr(ctx, scope, range.end_expr)
                if types.is_integer_type(start_ty):
                    return Option[types.Type].some(value = start_ty)
                return Option[types.Type].none
            _:
                return Option[types.Type].none


## The element type of an array/span iterable (the host's `collection_loop_type`).
function collection_loop_element_type(iterable_ty: types.Type) -> Option[types.Type]:
    match iterable_ty:
        types.Type.ty_generic as g:
            let g_bp = unsafe: read(g.payload)
            if (g_bp.name.equal("array") or g_bp.name.equal("span")) and g_bp.args.len >= 1:
                return Option[types.Type].some(value = unsafe: read(g_bp.args.data + 0))
        _:
            pass
    return Option[types.Type].none


## The binding type for an array/span element: a `ref[element]` when the element
## is a struct (the host's `collection_loop_binding_type`, so a loop over
## structs borrows each element), the element itself otherwise.
function collection_loop_binding_type(ctx: ref[Context], element_ty: types.Type) -> types.Type:
    if is_struct_like_type(ctx, element_ty):
        return types.generic_type(name = "ref", args = alloc_one_type_arg(element_ty))
    return element_ty


## True when `t` names a struct or union the analyzer's tables cover — a local
## or imported one, or an instantiated imported generic — the self's
## approximation of the host's `Types::Struct` test for the collection-loop
## `ref` binding.
function is_struct_like_type(ctx: ref[Context], t: types.Type) -> bool:
    match t:
        types.Type.ty_named as n:
            let n_np = unsafe: read(n.payload)
            if ctx.structs.contains(n_np.name) or ctx.unions.contains(n_np.name):
                return true
            if n_np.module_name.len > 0:
                return binding_has_struct_type(ctx, n_np.module_name, n_np.name)
            return false
        types.Type.ty_imported as im:
            let im_bp = unsafe: read(im.payload)
            return binding_has_struct_type(ctx, im_bp.module_name, im_bp.name)
        _:
            return false


## The element type the iterator protocol yields: the receiver's `iter()` return
## type, then `next()` on that — a nullable pointer-like item yields its base
## (`ptr[T]?` -> `ptr[T]`), a `bool` yields `current()`.  The permissive error
## type when the protocol does not resolve (the self does not require it).
function iterator_loop_element_type(ctx: ref[Context], iterable_ty: types.Type) -> types.Type:
    let base = unwrap_ref(iterable_ty)
    let iter_ret = method_return_type(ctx, base, "iter") else:
        return types.Type.ty_error
    let next_ret = method_return_type(ctx, iter_ret, "next") else:
        return types.Type.ty_error
    match next_ret:
        types.Type.ty_nullable as nl:
            let item_ty = unsafe: read(nl.base)
            if types.is_pointer_cast_type(item_ty):
                return item_ty
            return types.Type.ty_error
        types.Type.ty_primitive as p:
            if p.name.equal("bool"):
                let current_ret = method_return_type(ctx, iter_ret, "current") else:
                    return types.Type.ty_error
                return current_ret
        _:
            pass
    return types.Type.ty_error


## A method's declared return type on a receiver type, with an instantiated
## imported generic's arguments substituted (`Vec[int].iter()` -> `Iter[int]`).
## Imported receivers go through the binding (`imported_method_return_type`);
## everything else through `resolve_method_sig`.
function method_return_type(ctx: ref[Context], recv: types.Type, method_name: str) -> Option[types.Type]:
    match recv:
        types.Type.ty_imported:
            return imported_method_return_type(ctx, recv, method_name)
        types.Type.ty_named as n:
            let n_np = unsafe: read(n.payload)
            if n_np.module_name.len > 0 and not n_np.module_name.equal(ctx.module_name):
                return imported_method_return_type(ctx, recv, method_name)
        _:
            pass
    match resolve_method_sig(ctx, recv, method_name):
        Option.some as sig:
            if not sig.value.has_return_type:
                return Option[types.Type].some(value = types.primitive("void"))
            return Option[types.Type].some(value = sig.value.return_type)
        Option.none:
            return Option[types.Type].none


## If `t` is a nullable, Option, or Result wrapper, return the unwrapped
## success/payload type (the type the guard binding exposes).  Otherwise t itself.
## A `let`/`var` guard's success type — what a binding guarded with `else:`
## narrows to.  `T?`, `Option[T]` and `Result[T, E]` all yield their payload.
public function unwrap_nullable_type(t: types.Type) -> types.Type:
    match t:
        types.Type.ty_nullable as n:
            return unsafe: read(n.base)
        types.Type.ty_generic as g:
            let g_bp = unsafe: read(g.payload)
            if (g_bp.name == "Option" or g_bp.name == "Result") and g_bp.args.len >= 1:
                return unsafe: read(g_bp.args.data + 0)
            return t
        types.Type.ty_imported as im:
            let im_bp = unsafe: read(im.payload)
            # The loader binds std.option / std.result, so a guarded binding
            # over them carries the *imported* shape (`std.result.Result[T, E]`)
            # rather than a `ty_generic`.
            if (im_bp.name == "Option" or im_bp.name == "Result") and im_bp.args.len >= 1:
                return unsafe: read(im_bp.args.data + 0)
            return t
        _:
            return t


## True when `t` is a shape a `let … else:` guard accepts: `T?`, `Option[T]`
## or `Result[T, E]`.  The loader binds std.option / std.result, so those
## arrive as `ty_imported`.
function is_let_else_source(t: types.Type) -> bool:
    match t:
        types.Type.ty_nullable:
            return true
        types.Type.ty_generic as g:
            let g_bp = unsafe: read(g.payload)
            return (g_bp.name == "Option" or g_bp.name == "Result") and g_bp.args.len >= 1
        types.Type.ty_imported as im:
            let im_bp = unsafe: read(im.payload)
            return (im_bp.name == "Option" or im_bp.name == "Result") and im_bp.args.len >= 1
        _:
            return false


## True when `t` is `Option[T]` or `Result[T, E]`.  Postfix `?` does not accept
## a bare nullable: unlike a guard, it propagates a variant's failure arm.
function is_option_or_result(t: types.Type) -> bool:
    match t:
        types.Type.ty_generic as g:
            let g_bp = unsafe: read(g.payload)
            return (g_bp.name == "Option" or g_bp.name == "Result") and g_bp.args.len >= 1
        types.Type.ty_imported as im:
            let im_bp = unsafe: read(im.payload)
            return (im_bp.name == "Option" or im_bp.name == "Result") and im_bp.args.len >= 1
        _:
            return false


## True for the compile-time handle builtins whose arguments are declaration
## *names* rather than values (`callable_of(identity)`, `field_of(T, f)`,
## `has_attribute(x, a)`, `size_of(T)`, `align_of(T)`, `members_of`,
## `attributes_of`, `attribute_of`, `attribute_arg`, `fields_of`).
function is_handle_builtin_callee(callee: ptr[ast.Expr]) -> bool:
    unsafe:
        match read(callee):
            ast.Expr.expr_identifier as id:
                return is_handle_builtin_name(id.name)
            _:
                return false


function is_handle_builtin_name(name: str) -> bool:
    return (
        name == "callable_of" or name == "field_of"
        or name == "attribute_of" or name == "attribute_arg"
        or name == "has_attribute" or name == "fields_of"
        or name == "members_of" or name == "attributes_of"
        or name == "size_of" or name == "align_of"
    )


## Identifier-callable builtins the host resolves before its unknown-callable
## fallback.  Their arity/type checking is separate, so an unusable argument
## shape must not turn into `unknown callable`.  `str` is the StringView
## constructor (the host's named-type branch).
public function is_callable_builtin_name(name: str) -> bool:
    return (
        name == "read" or name == "ptr_of" or name == "const_ptr_of"
        or name == "ref_of" or name == "get" or name == "fatal"
        or name == "assert" or name == "expect" or name == "expect_eq"
        or name == "expect_ne" or name == "str"
        or is_handle_builtin_name(name)
    )


## True when a type is a function or proc type (a nullable one included), the
## expected type a callable-value argument stands in for.
public function is_callable_type(t: types.Type) -> bool:
    match t:
        types.Type.ty_function:
            return true
        types.Type.ty_nullable as n:
            return is_callable_type(unsafe: read(n.base))
        _:
            return false


## Flag an assignment whose target is a name bound by `let`, which is immutable.
## The host anchors the error at the assignment's operator (the statement's
## column) and spans the target's name (`source_length` falls back to it).
function is_generic_type_named(t: types.Type, name: str) -> bool:
    match t:
        types.Type.ty_generic as g:
            let g_bp = unsafe: read(g.payload)
            return g_bp.name == name
        types.Type.ty_imported as im:
            let im_bp = unsafe: read(im.payload)
            return im_bp.name == name
        _:
            return false


## The host's `infer_lvalue_receiver` immutability ladder: a mutable binding is
## assignable; a `ref[T]` and a mutable raw pointer receiver are assignable; a
## `span` *parameter* is assignable; a `const_ptr` is read-only; anything else
## bound by `let` (including parameters and non-editable `this`) is immutable.
function check_lvalue_receiver_immutable(
    ctx: ref[Context],
    scope: ref[sscope.Scope],
    receiver: ptr[ast.Expr],
    line: ptr_uint,
    column: ptr_uint
) -> void:
    unsafe:
        match read(receiver):
            ast.Expr.expr_identifier as id:
                let type_ptr = scope_get(scope, id.name)
                if type_ptr == null:
                    return
                let declared = read(type_ptr)
                let ty = if types.is_nullable_type(declared): types.unwrap_nullable(declared) else: declared
                if types.is_ref_type(ty) or is_generic_type_named(ty, "ref"):
                    return
                if is_generic_type_named(ty, "ptr") or is_generic_type_named(ty, "own"):
                    return
                if is_generic_type_named(ty, "const_ptr"):
                    var msg = string.String.create()
                    msg.append("cannot assign through read-only raw pointer ")
                    msg.append(types.type_to_diagnostic_string(ty))
                    report_at(ctx, line, column, id.name.len, msg.as_str())
                    return
                if is_generic_type_named(ty, "span") and scope_is_param(scope, id.name):
                    return
                if scope_is_let(scope, id.name):
                    var msg = string.String.create()
                    msg.append("cannot assign through immutable ")
                    msg.append(id.name)
                    report_at(ctx, line, column, id.name.len, msg.as_str())
            ast.Expr.expr_member_access as m:
                check_lvalue_receiver_immutable(ctx, scope, m.receiver, line, column)
            ast.Expr.expr_index_access as ix:
                check_lvalue_receiver_immutable(ctx, scope, ix.receiver, line, column)
            _:
                pass


function check_assign_target_immutable(
    ctx: ref[Context],
    scope: ref[sscope.Scope],
    target: ptr[ast.Expr],
    line: ptr_uint,
    column: ptr_uint
) -> void:
    unsafe:
        match read(target):
            ast.Expr.expr_identifier as id:
                if scope_is_let(scope, id.name):
                    report_at(ctx, line, column, id.name.len, assign_to_let_message(id.name))
            ast.Expr.expr_member_access as m:
                check_lvalue_receiver_immutable(ctx, scope, m.receiver, line, column)
            ast.Expr.expr_index_access as ix:
                check_lvalue_receiver_immutable(ctx, scope, ix.receiver, line, column)
            _:
                pass


function check_local(
    ctx: ref[Context],
    scope: ref[sscope.Scope],
    chk: CheckFlags,
    is_let: bool,
    name: str,
    stmt_type: ptr[ast.TypeRef]?,
    value: ptr[ast.Expr]?,
    else_binding: Option[str],
    else_body: ptr[ast.Stmt]?,
    destructure_bindings: Option[span[str]],
    line: ptr_uint,
    column: ptr_uint,
    else_line: ptr_uint,
    else_column: ptr_uint
) -> void:
    # The declaration's binding id, consumed even when the binding is discarded
    # (`let _ = …` burns an id): the host's preassigned allocation happens for
    # every LocalDecl.
    let statement_key = binding_key(line, column)
    let statement_binding_id = preassigned_binding_id_for(ctx, statement_key)
    # Destructuring bindings: each name carries the tuple element (or struct
    # field) at its position, the host's `check_local_decl_tuple_destructure`.
    # The per-name types are recorded for the LSP; the initializer itself is
    # inferred without recording so the recorded types — and thus code
    # generation — stay identical to the previous behavior.
    match destructure_bindings:
        Option.some as names:
            var value_ty: types.Type = types.Type.ty_error
            let dv = value
            if dv != null:
                value_ty = infer_expr_inner(ctx, scope, dv)
            var bound_any = false
            var di: ptr_uint = 0
            while di < names.value.len:
                var field_ty: types.Type = types.Type.ty_error
                match value_ty:
                    types.Type.ty_tuple as tup:
                        let tup_bp = unsafe: read(tup.payload)
                        if di < tup_bp.elements.len:
                            field_ty = unsafe: read(tup_bp.elements.data + di)
                    _:
                        pass
                unsafe:
                    let dn = read(names.value.data + di)
                    if not dn == "_":
                        scope_set(scope, dn, field_ty)
                        scope_set_storage(scope, dn, field_ty)
                        scope_set_binding_id(scope, dn, statement_binding_id)
                        record_binding_type(ctx, statement_binding_id, field_ty)
                        if ctx.tooling_facts:
                            ctx.destructure_types.push(DestructureTypeEntry(line = line, name = dn, ty = field_ty))
                        bound_any = true
                di += 1
            if bound_any:
                record_declaration_site(ctx, statement_key, statement_binding_id)
            check_local_else_body(ctx, scope, chk, else_binding, else_body, value_ty, else_line, else_column)
            return
        Option.none:
            pass

    var declared: types.Type = types.Type.ty_error
    var has_declared = false
    let lt = stmt_type
    if lt != null:
        declared = resolve_type(ctx, lt)
        has_declared = true
        if ctx.tooling_facts:
            ctx.local_decl_types.set(line, declared)

    var value_type: types.Type = types.Type.ty_error
    var has_value = false
    let val = value
    if val != null:
        # A declared type is the initializer's expected type: an if/match whose
        # branches all fit it takes the annotation rather than its own common
        # type (the host's `infer_expression(..., expected_type:)`).
        let saved_hint = ctx.expected_type_hint
        if has_declared:
            ctx.expected_type_hint = declared
        value_type = infer_expr(ctx, scope, val)
        ctx.expected_type_hint = saved_hint
        has_value = true

    # A guarded let/var (let x = nullable else: ...) unwraps the value type:
    # T?, Option[T], and Result[T,E] all narrow their success type.
    let has_guard = else_body != null
    let narrowed = unwrap_nullable_type(value_type)

    # A guard requires a nullable, Option or Result initializer; the host
    # reports at the binding name (the statement's anchor).
    if has_guard and has_value and not types.contains_error(value_type) and not is_let_else_source(value_type):
        report(ctx, line, column, diag.let_else_initializer_message(name, value_type))

    # Compatibility: a plain local compares its declared type against the value
    # type directly; a guarded local's annotation names the *success* type, so
    # it is compared against the unwrapped (narrowed) value type instead.
    if has_declared and has_value:
        let compared = if has_guard: narrowed else: value_type
        if incompatible_value_with_consts(ctx, declared, compared, value, ref_of(ctx.const_values)):
            report(ctx, line, column, local_mismatch_message(declared, compared, name))

    # Bind the name for later inference: prefer the declared type, but narrow a
    # guard-unwrapped nullable/Option/Result to its success type.  The storage
    # type follows the host's `LocalDecl`: a plain declaration stores its final
    # type, a guarded one stores the raw initializer for a `let` and the success
    # type for a `var`.
    var final_ty: types.Type = types.Type.ty_error
    if has_declared:
        final_ty = declared
    else if has_value:
        final_ty = if has_guard: narrowed else: value_type
    scope_set(scope, name, final_ty)
    let storage_ty = if has_guard and is_let: value_type else: final_ty
    scope_set_storage(scope, name, storage_ty)
    if not name.equal("_"):
        scope_set_binding_id(scope, name, statement_binding_id)
        record_binding_type(ctx, statement_binding_id, final_ty)
        record_declaration_site(ctx, statement_key, statement_binding_id)

    if is_let:
        scope_set_let(scope, name)

    if is_reserved_name(name):
        report(ctx, line, column, diag.reserved_value_message("local", name))

    check_local_else_body(ctx, scope, chk, else_binding, else_body, value_type, else_line, else_column)


## The host's `check_local_decl_let_else` else-block half: check the guard's
## else body in a scope that also carries its `else as name` binding (the
## initializer's error type, `Result[T, E]`'s `E`).  The `let x = optional else:`
## form has no binding.  A body-less guard has nothing to check.
function check_local_else_body(
    ctx: ref[Context],
    scope: ref[sscope.Scope],
    chk: CheckFlags,
    else_binding: Option[str],
    else_body: ptr[ast.Stmt]?,
    value_type: types.Type,
    else_line: ptr_uint,
    else_column: ptr_uint
) -> void:
    let body = else_body else:
        return
    scope_enter(scope)
    match else_binding:
        Option.some as binding:
            let err_ty = let_else_error_type(value_type)
            let else_key = binding_key(else_line, else_column)
            let else_id = preassigned_binding_id_for(ctx, else_key)
            scope_set(scope, binding.value, err_ty)
            scope_set_storage(scope, binding.value, err_ty)
            scope_set_binding_id(scope, binding.value, else_id)
            record_binding_type(ctx, else_id, err_ty)
            record_declaration_site(ctx, else_key, else_id)
        Option.none:
            pass
    check_body(ctx, scope, chk, body)
    scope_leave(scope)


## The error type an `else as name` binding carries: `Result[T, E]`'s `E`; the
## permissive error type for anything else (a nullable or `Option` guard has no
## error binding, and the host rejects one).
function let_else_error_type(value_type: types.Type) -> types.Type:
    match value_type:
        types.Type.ty_generic as g:
            let g_bp = unsafe: read(g.payload)
            if g_bp.name.equal("Result") and g_bp.args.len == 2:
                return unsafe: read(g_bp.args.data + 1)
        types.Type.ty_imported as im:
            let im_bp = unsafe: read(im.payload)
            if im_bp.name.equal("Result") and im_bp.args.len == 2:
                return unsafe: read(im_bp.args.data + 1)
        types.Type.ty_nullable as nl:
            return let_else_error_type(unsafe: read(nl.base))
        _:
            pass
    return types.Type.ty_error

# =============================================================================
#  Expression type inference (conservative)
# =============================================================================

public function infer_expr(ctx: ref[Context], scope: ref[sscope.Scope], ep: ptr[ast.Expr]) -> types.Type:
    let ty = infer_expr_inner(ctx, scope, ep)
    record_expr_type(ctx, ep, ty)
    return ty


function record_expr_type(ctx: ref[Context], ep: ptr[ast.Expr], ty: types.Type) -> void:
    # A variant arm's payload type is analyzer-side only: the lowering builds
    # its own payload struct (with the C name it registers), so recording this
    # one would hand it a type whose C name it never declared.
    match ty:
        types.Type.ty_variant_arm_payload:
            return
        _:
            pass
    let key = unsafe: reinterpret[ptr_uint](ep)
    ctx.resolved_expr_types.set(key, ty)


function record_call_kind(ctx: ref[Context], callee: ptr[ast.Expr], kind: str) -> void:
    let key = unsafe: reinterpret[ptr_uint](callee)
    if ctx.tooling_facts:
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


public function is_builtin_call_name(name: str) -> bool:
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
    return const_eval_int(ref_of(ctx.const_values), ep)


## Integer evaluation of a constant expression against a `const` table: integer
## and char literals, other constants by name, and the unary/arithmetic/bitwise
## operators.  Public so a consumer outside the analysis pass folds a value the
## way the host does — the LSP's enum/flags member hover renders the host's
## `member_value`, which is this fold of the member's declared expression.
public function const_eval_int(const_values: ref[map_mod.Map[str, ptr[ast.Expr]]], ep: ptr[ast.Expr]) -> Option[long]:
    unsafe:
        match read(ep):
            ast.Expr.expr_integer_literal as lit:
                return Option[long].some(value = long<-lit.value)
            ast.Expr.expr_char_literal as ch:
                return Option[long].some(value = long<-ch.value)
            ast.Expr.expr_identifier as id:
                let chain = const_values.get(id.name)
                if chain != null:
                    return const_eval_int(const_values, read(chain))
                return Option[long].none
            ast.Expr.expr_unary_op as un:
                let v = const_eval_int(const_values, un.operand) else:
                    return Option[long].none
                if un.operator == "-":
                    return Option[long].some(value = -v)
                if un.operator == "~":
                    return Option[long].some(value = ~v)
                return Option[long].some(value = v)
            ast.Expr.expr_binary_op as bin:
                let l = const_eval_int(const_values, bin.left) else:
                    return Option[long].none
                let r = const_eval_int(const_values, bin.right) else:
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
                return infer_integer_literal_type(ctx, lit.lexeme, lit.value)
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
                return infer_identifier(ctx, scope, unsafe: reinterpret[ptr_uint](ep), id.name, id.line, id.column)
            ast.Expr.expr_binary_op as b:
                return infer_binary(ctx, scope, b.operator, b.left, b.right)
            ast.Expr.expr_unary_op as u:
                return infer_unary(ctx, scope, u.operator, u.operand)
            ast.Expr.expr_prefix_cast as c:
                # The host infers a cast's operand with no expected type
                # (`infer_expression(expression.expression)` without
                # `expected_type:`), so an outer assignment/declaration hint must
                # not leak through the cast (`ubyte<-(if c: 0 else: 255)` infers
                # the conditional as `int`).
                let cast_saved_hint = ctx.expected_type_hint
                ctx.expected_type_hint = types.Type.ty_error
                let source = infer_expr(ctx, scope, c.expression)
                ctx.expected_type_hint = cast_saved_hint
                let target = resolve_type(ctx, c.target_type)
                check_cast_call(ctx, c.expression, source, target, c.line, c.column)
                return target
            ast.Expr.expr_member_access as ma:
                return resolve_member_access(ctx, scope, ma.receiver, ma.member_name, false, ma.line, ma.column)
            ast.Expr.expr_index_access as ix:
                return infer_index_access_type(ctx, scope, ix.receiver, ix.index)
            ast.Expr.expr_unsafe as u:
                return infer_unsafe_type(ctx, scope, u.expression, u.line)
            ast.Expr.expr_call as call:
                let ty = infer_and_check_call(ctx, scope, call.callee, call.args)
                record_call_kind(ctx, ep, call_expr_kind(ctx, call.callee))
                return ty
            ast.Expr.expr_specialization as spec:
                let ty = check_specialization_call(
                    ctx,
                    scope,
                    spec.callee,
                    spec.arguments,
                    span[types.Type](),
                    span[ast.Argument](),
                    false
                )
                record_call_kind(ctx, ep, specialization_kind(ctx, spec.callee, spec.arguments))
                return ty
            ast.Expr.expr_await as aw:
                return infer_await_type(ctx, scope, aw.expression)
            ast.Expr.expr_null_literal as nl:
                return infer_null_literal_type(ctx, nl.target_type)
            ast.Expr.expr_format_string as fs:
                check_format_string_parts(ctx, scope, fs.parts)
                return types.Type.ty_str
            ast.Expr.expr_proc as pr:
                return infer_proc_type(ctx, scope, pr.method_params, pr.return_type, pr.body)
            ast.Expr.expr_if as ife:
                return infer_if_expr_type(ctx, scope, ife.condition, ife.then_expr, ife.else_expr)
            ast.Expr.expr_match as me:
                return infer_match_expr_type(ctx, scope, me.scrutinee, me.arms, me.line, me.column)
            ast.Expr.expr_detach as det:
                return infer_detach_type(ctx, det.expression, det.line, det.column)
            ast.Expr.expr_sizeof:
                return types.primitive("ptr_uint")
            ast.Expr.expr_alignof:
                return types.primitive("ptr_uint")
            ast.Expr.expr_offsetof:
                return types.primitive("ptr_uint")
            ast.Expr.expr_expression_list:
                return infer_tuple_literal(ctx, scope, ep)
            ast.Expr.expr_range:
                return types.Type.ty_error
            ast.Expr.expr_named as nm:
                return infer_expr(ctx, scope, nm.value)
            ast.Expr.expr_error as err:
                return types.Type.ty_error
            _:
                return types.Type.ty_error


function infer_integer_literal_type(ctx: ref[Context], lexeme: str, value: long) -> types.Type:
    match integer_suffix_type_name(lexeme):
        Option.some as st:
            return types.primitive(st.value)
        Option.none:
            pass
    # The host's `infer_integer_literal`: a bare literal takes the
    # expected integer type when its value fits (`return 200 + 56`
    # in a `-> ubyte` body types both operands as ubyte).  An
    # out-of-range value falls through to the narrowing ladder and
    # is rejected by the assignment check.
    let hint = ctx.expected_type_hint
    match hint:
        types.Type.ty_primitive as hp:
            # `char` is deliberately excluded: the host types the
            # literal as `int` and lowers it through an explicit
            # `char<-N` cast (`let nl: char = 10`), even though
            # `integer_constant_fits` accepts the value for
            # assignability.
            if hp.name != "char" and types.is_fixed_width_integer_name(hp.name) and types.integer_constant_fits(
                hp.name,
                long<-value
            ):
                return hint
        _:
            pass
    # A bare literal picks the narrowest fixed-width type that
    # holds its value: int -> long -> ulong (the host's
    # `infer_integer_literal`; an overflowing `int` emitted
    # overflowing C, e.g. `int32_t x = 2147483648;`).  A value
    # that does not fit a signed `long` — stored negative by the
    # parser, e.g. 0xFFFFFFFFFFFFFFFF — only fits `ulong`.
    if value < 0:
        return types.primitive("ulong")
    if value <= 2147483647:
        return types.primitive("int")
    return types.primitive("long")


function infer_index_access_type(
    ctx: ref[Context],
    scope: ref[sscope.Scope],
    receiver: ptr[ast.Expr],
    index: ptr[ast.Expr]
) -> types.Type:
    let rt = infer_expr(ctx, scope, receiver)
    # An index is an integer position: the host's `infer_index_access`
    # infers it with no expected type, so the enclosing assignment's
    # element type must not leak into it (`players[i].color[0] =
    # ubyte<-…` keeps the `0` an `int`, not a `ubyte`).
    let index_saved_hint = ctx.expected_type_hint
    ctx.expected_type_hint = types.Type.ty_error
    let _ix = infer_expr(ctx, scope, index)
    ctx.expected_type_hint = index_saved_hint
    if types.is_raw_pointer(rt) and not in_generic_body(ctx):
        if ctx.unsafe_depth == 0:
            report(ctx, 0, 0, "pointer indexing requires unsafe")
        else:
            mark_required_unsafe(ctx)
    # Range slicing: `str[start..stop]` yields `str`;
    # `array[T,N][a..b]` / `span[T][a..b]` yield `span[T]`.
    unsafe:
        match read(index):
            ast.Expr.expr_range:
                if types.type_to_string(rt) == "str":
                    return types.Type.ty_str
                match rt:
                    types.Type.ty_generic as g:
                        let g_bp = unsafe: read(g.payload)
                        if g_bp.name == "array" or g_bp.name == "span":
                            var span_args = vec.Vec[types.Type].create()
                            span_args.push(types.pointer_element(rt))
                            return types.generic_type(name = "span", args = span_args.as_span())
                    _:
                        pass
            _:
                pass
    var elem = types.pointer_element(rt)
    if types.is_error(elem) and types.type_to_string(rt) == "str":
        # `str[i]` reads a byte (host `infer_index_access`).
        elem = types.primitive("ubyte")
    if not types.is_error(elem):
        return elem
    return types.Type.ty_error


function infer_unsafe_type(
    ctx: ref[Context],
    scope: ref[sscope.Scope],
    expression: ptr[ast.Expr],
    line: ptr_uint
) -> types.Type:
    ctx.unsafe_depth += 1
    ctx.unsafe_statement_lines.push(line)
    let result = infer_expr(ctx, scope, expression)
    ctx.unsafe_depth -= 1
    let _popped_expr = ctx.unsafe_statement_lines.pop()
    return result


function infer_await_type(ctx: ref[Context], scope: ref[sscope.Scope], expression: ptr[ast.Expr]) -> types.Type:
    if not ctx.inside_async:
        report(ctx, 0, 0, "await is only allowed inside async functions")
    # `await` unwraps the lifted Task type: Task[T] -> T (mirrors
    # Ruby's infer_await returning task_type.result_type).
    let awaited = infer_expr(ctx, scope, expression)
    match awaited:
        types.Type.ty_generic as task_g:
            let task_g_bp = unsafe: read(task_g.payload)
            if task_g_bp.name == "Task" and task_g_bp.args.len == 1:
                return unsafe: read(task_g_bp.args.data + 0)
        _:
            pass
    return awaited


function infer_null_literal_type(ctx: ref[Context], target_type: ptr[ast.TypeRef]?) -> types.Type:
    let target = target_type
    if target != null:
        let t = resolve_type(ctx, target)
        return types.Type.ty_nullable(base = types.alloc_type(t))
    # The host's `infer_null_literal_type` answers its `Types::Null`
    # when no target type is in scope — not an error — so a
    # conditional branch can unify with the other branch's nullable
    # (`conditional_null_common_type`).
    return types.Type.ty_null(target = null)


function infer_proc_type(
    ctx: ref[Context],
    scope: ref[sscope.Scope],
    method_params: span[ast.Param],
    return_type: ptr[ast.TypeRef]?,
    body: ptr[ast.Stmt]
) -> types.Type:
    unsafe:
        var param_types = vec.Vec[types.Type].create()
        var pi: ptr_uint = 0
        var param_names = vec.Vec[str].create()
        while pi < method_params.len:
            var p: ast.Param = read(method_params.data + pi)
            param_types.push(resolve_type_value(ctx, p.param_type))
            param_names.push(p.name)
            pi += 1
        var ret = types.primitive("void")
        let rt = return_type
        if rt != null:
            ret = resolve_type(ctx, rt)
        check_proc_body(ctx, scope, param_types.as_span(), param_names.as_span(), ret, body)
        return types.function_type(
            name = "",
            params = param_types.as_span(),
            return_type = types.alloc_type(ret),
            variadic = false,
            is_proc = true,
            param_names = param_names.as_span()
        )


function infer_if_expr_type(
    ctx: ref[Context],
    scope: ref[sscope.Scope],
    condition: ptr[ast.Expr],
    then_expr: ptr[ast.Expr],
    else_expr: ptr[ast.Expr]
) -> types.Type:
    # Each branch is checked with the condition's refinements in
    # scope (`let x = if p != null: read(p) else: …`), the host's
    # `infer_if_expression`.  The host requires a bool condition; its
    # diagnostic has no expression position (the AST if-expression carries
    # none), so it reports at the enclosing statement's anchor.
    let cond_ty = infer_expr(ctx, scope, condition)
    if not types.contains_error(cond_ty):
        match cond_ty:
            types.Type.ty_var:
                pass
            _:
                if not types.is_bool_type(cond_ty):
                    report(ctx, ctx.statement_line, ctx.statement_column, condition_message("if expression", cond_ty))
    scope_enter(scope)
    var then_refs = flow_refinements(ctx, condition, true, scope)
    apply_refinements_to_frame(ctx, scope, ref_of(then_refs))
    let then_ty = infer_expr(ctx, scope, then_expr)
    then_refs.release()
    scope_leave(scope)
    scope_enter(scope)
    var else_refs = flow_refinements(ctx, condition, false, scope)
    apply_refinements_to_frame(ctx, scope, ref_of(else_refs))
    let else_ty = infer_expr(ctx, scope, else_expr)
    else_refs.release()
    scope_leave(scope)
    # A declared position's expected type wins when both branches fit
    # it (the host's `infer_if_expression` short-circuit): `let n:
    # uint = if p: uint<-x else: 0` is uint, though the branches'
    # numeric common type would be long.
    let hint_ty = ctx.expected_type_hint
    if not types.is_error(hint_ty):
        if compat.types_compatible_with_consts(
            hint_ty,
            then_ty,
            then_expr,
            ptr_of(ctx.const_values)
        ) and compat.types_compatible_with_consts(hint_ty, else_ty, else_expr, ptr_of(ctx.const_values)):
            return hint_ty
    return sem_exprs.conditional_common_type(then_ty, else_ty, then_expr, else_expr)


function infer_match_expr_type(
    ctx: ref[Context],
    scope: ref[sscope.Scope],
    scrutinee: ptr[ast.Expr],
    arms: span[ast.MatchExprArm],
    line: ptr_uint,
    column: ptr_uint
) -> types.Type:
    unsafe:
        # An `as name` arm binds the arm's payload type from the
        # scrutinee's type, so it is inferred once, before the arms.
        let expr_scrutinee_ty = infer_expr_inner(ctx, scope, scrutinee)
        # The host rejects anything but an enum, variant, integer, str or tuple
        # before inferring the arm values (see `match_scrutinee_supported`).
        if not match_scrutinee_supported(ctx, expr_scrutinee_ty):
            report_at(ctx, line, column, 5, match_scrutinee_message(expr_scrutinee_ty))
            return types.Type.ty_error
        check_match_expression_arms(ctx, expr_scrutinee_ty, arms, line, column)
        var arm_types = vec.Vec[types.Type].create()
        var arm_exprs = vec.Vec[ptr[ast.Expr]].create()
        let match_hint = ctx.expected_type_hint
        var all_fit_hint = not types.is_error(match_hint)
        var ai: ptr_uint = 0
        while ai < arms.len:
            var arm: ast.MatchExprArm = read(arms.data + ai)
            scope_enter(scope)
            bind_match_arm_names(
                ctx,
                scope,
                expr_scrutinee_ty,
                arm.binding_name,
                arm.pattern,
                arm.binding_line,
                arm.binding_column
            )
            let arm_ty = infer_expr(ctx, scope, arm.value)
            if all_fit_hint and not compat.types_compatible_with_consts(
                match_hint,
                arm_ty,
                arm.value,
                ptr_of(ctx.const_values)
            ):
                all_fit_hint = false
            arm_types.push(arm_ty)
            arm_exprs.push(arm.value)
            scope_leave(scope)
            ai += 1
        # A declared position's expected type wins when every arm fits
        # it (the host's `match_expression_common_type` short-circuit).
        if all_fit_hint:
            return match_hint
        return sem_exprs.match_expression_common_type(arm_types.as_span(), arm_exprs.as_span())


function infer_detach_type(
    ctx: ref[Context],
    expression: ptr[ast.Expr],
    line: ptr_uint,
    column: ptr_uint
) -> types.Type:
    unsafe:
        match read(expression):
            ast.Expr.expr_call as call:
                match read(call.callee):
                    ast.Expr.expr_identifier:
                        pass
                    _:
                        report(ctx, line, column, "detach target must be a global function call")
            _:
                report(ctx, line, column, "detach target must be a function call")
        return types.Type.ty_handle


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


function infer_identifier(
    ctx: ref[Context],
    scope: ref[sscope.Scope],
    node_key: ptr_uint,
    name: str,
    line: ptr_uint,
    column: ptr_uint
) -> types.Type:
    let local = scope_get(scope, name)
    if local != null:
        record_identifier_site(ctx, node_key, scope_get_binding_id(scope, name))
        unsafe:
            return read(local)
    let global = ctx.value_types.get(name)
    if global != null:
        let global_id = ctx.value_binding_ids.get(name)
        if global_id != null:
            record_identifier_site(ctx, node_key, unsafe: read(global_id))
        unsafe:
            return read(global)
    # Declared functions/externs and other referenceable names carry no
    # `value_types` entry, so keep the permissive error type for them (recorded
    # types — and thus code generation — are unchanged); only a name matching
    # nothing at all is a typo or missing import and is reported.
    if ctx.functions.contains(name) and ctx.callable_site_suppression == 0:
        # A bare top-level function name in a value position is the host's
        # `record_callable_value_identifier_site`: valid only where an expected
        # type exists (the host errors "must be called" otherwise), which is
        # what the token scanner renders `function` for.
        if ctx.tooling_facts:
            ctx.callable_value_sites.push(CallableValueSite(line = line, column = column))
    if not is_known_value_identifier(ctx, name):
        report_at(ctx, line, column, name.len, unknown_name_message(name))
    return types.Type.ty_error


function unknown_name_message(name: str) -> str:
    var buf = string.String.create()
    buf.append("unknown name ")
    buf.append(name)
    return buf.as_str()


## Bind an arm's `as name` and struct-pattern field names in the current scope,
## so references in the arm body/value are not reported as unknown.  An
## `as name` binding carries the arm's **payload type** — the host's
## `Types::VariantArmPayload`, the arm's declared fields with the scrutinee's
## type arguments substituted (`Option[(str, str)].some payload`) — so
## `p.value` resolves through the normal field path and the LSP can hover it; a
## pattern field name stays at the permissive error type.
function bind_match_arm_names(
    ctx: ref[Context],
    scope: ref[sscope.Scope],
    scrutinee_ty: types.Type,
    binding_name: Option[str],
    pattern: ptr[ast.Expr]?,
    line: ptr_uint,
    column: ptr_uint
) -> void:
    match binding_name:
        Option.some as bn:
            var binding_ty: types.Type = types.Type.ty_error
            let bp = pattern
            if bp != null:
                match match_arm_payload_type(ctx, scrutinee_ty, bp):
                    Option.some as payload_ty:
                        binding_ty = payload_ty.value
                    Option.none:
                        pass
            let arm_key = binding_key(line, column)
            let arm_id = preassigned_binding_id_for(ctx, arm_key)
            scope_set(scope, bn.value, binding_ty)
            scope_set_storage(scope, bn.value, binding_ty)
            scope_set_binding_id(scope, bn.value, arm_id)
            record_binding_type(ctx, arm_id, binding_ty)
            record_declaration_site(ctx, arm_key, arm_id)
            if ctx.tooling_facts:
                ctx.arm_binding_types.push(ArmBindingEntry(line = line, name = bn.value, ty = binding_ty))
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
                    var arg_named = false
                    match arg.arg_name:
                        Option.some:
                            arg_named = true
                        Option.none:
                            pass
                    match read(arg.arg_value):
                        ast.Expr.expr_identifier as id:
                            if not id.name == "_":
                                let arg_id = if arg_named: 0 else: preassigned_binding_id_for(
                                    ctx,
                                    binding_key(id.line, id.column)
                                )
                                scope_set(scope, id.name, types.Type.ty_error)
                                scope_set_storage(scope, id.name, types.Type.ty_error)
                                if not arg_named:
                                    scope_set_binding_id(scope, id.name, arg_id)
                                    record_binding_type(ctx, arg_id, types.Type.ty_error)
                        _:
                            pass
                    i += 1
            _:
                pass


## The immediate arm name a match pattern names (`Option.some` -> `some`,
## `Result.success(field = x)` -> `success`, a bare `some` -> `some`); "" when
## the pattern names no arm.
function pattern_arm_name(pattern: ptr[ast.Expr]?) -> str:
    let p = pattern else:
        return ""
    unsafe:
        match read(p):
            ast.Expr.expr_member_access as ma:
                return ma.member_name
            ast.Expr.expr_call as cl:
                return pattern_arm_name(cl.callee)
            ast.Expr.expr_identifier as id:
                return id.name
            _:
                return ""


## The module a prelude variant belongs to ("" for anything else), mirroring
## the host's `std.option` / `std.result` registration.
function prelude_variant_module(variant_name: str) -> str:
    if variant_name == "Option":
        return "std.option"
    if variant_name == "Result":
        return "std.result"
    return ""


## The payload type an `as name` arm binds: the host's `Types::VariantArmPayload`
## — the arm's declared payload fields with the scrutinee's type arguments
## substituted (`Option[(str, str)].some payload`).  None for a variant or arm
## the analyzer carries no payload fields for (a user variant), which leaves the
## binding at the permissive error type.
function match_arm_payload_type(
    ctx: ref[Context],
    scrutinee_ty: types.Type,
    pattern: ptr[ast.Expr]?
) -> Option[types.Type]:
    let arm_name = pattern_arm_name(pattern)
    if arm_name.len == 0:
        return Option[types.Type].none
    var variant_name: str = ""
    var module_name: str = ""
    var args = span[types.Type]()
    match scrutinee_ty:
        types.Type.ty_generic as g:
            let g_bp = unsafe: read(g.payload)
            variant_name = g_bp.name
            args = g_bp.args
        types.Type.ty_imported as im:
            let im_bp = unsafe: read(im.payload)
            variant_name = im_bp.name
            module_name = im_bp.module_name
            args = im_bp.args
        types.Type.ty_named as n:
            let n_np = unsafe: read(n.payload)
            variant_name = n_np.name
            module_name = n_np.module_name
        types.Type.ty_nullable as nl:
            return match_arm_payload_type(ctx, unsafe: read(nl.base), pattern)
        _:
            return Option[types.Type].none
    if module_name.len == 0:
        module_name = prelude_variant_module(variant_name)
    let key = payload_struct_key(variant_name, arm_name)
    var decls: span[types.PayloadField]
    var params: span[str]
    if module_name.len == 0 or module_name.equal(ctx.module_name) or prelude_variant_module(variant_name).len > 0:
        # A local (or prelude) variant: the analyzer's own tables.
        let decls_ptr = ctx.arm_payload_field_types.get(key) else:
            return Option[types.Type].none
        let params_ptr = ctx.variant_param_names.get(variant_name) else:
            return Option[types.Type].none
        decls = unsafe: read(decls_ptr)
        params = unsafe: read(params_ptr)
    else:
        # An imported variant: the exporter's resolved arm fields and declared
        # type parameters travel on the module binding.
        let binding = find_binding(ctx, module_name) else:
            return Option[types.Type].none
        let decls_ptr = unsafe: read(binding).variant_arm_fields.get(key) else:
            return Option[types.Type].none
        let tps_ptr = unsafe: read(binding).type_param_names.get(variant_name) else:
            return Option[types.Type].none
        decls = unsafe: read(decls_ptr)
        params = variant_type_param_names(unsafe: read(tps_ptr))

    # The scrutinee's type arguments bind the variant's parameters, and each
    # declared field takes its parameter's type.
    var subs = map_mod.Map[str, types.Type].create()
    defer: subs.release()
    var pi: ptr_uint = 0
    while pi < params.len and pi < args.len:
        unsafe:
            subs.set(read(params.data + pi), read(args.data + pi))
        pi += 1
    var fields = vec.Vec[types.PayloadField].create()
    var fi: ptr_uint = 0
    while fi < decls.len:
        let decl = unsafe: read(decls.data + fi)
        fields.push(types.PayloadField(name = decl.name, ty = substitute_type(decl.ty, ref_of(subs))))
        fi += 1

    # The *instantiated* variant text (`std.option.Option[(str, str)]`): the
    # LSP shortens it to the host's `Option[(str, str)]` plus its `*From*` line.
    var variant_text = string.String.create()
    if module_name.len > 0:
        variant_text.append(module_name)
        variant_text.append(".")
    variant_text.append(variant_name)
    if args.len > 0:
        variant_text.append("[")
        var ai: ptr_uint = 0
        while ai < args.len:
            if ai > 0:
                variant_text.append(", ")
            unsafe:
                variant_text.append(types.type_to_string(read(args.data + ai)))
            ai += 1
        variant_text.append("]")

    # `c_name` stays empty: the lowering registers the payload struct's C name
    # itself (`variant_arm_payload_binding`), and a payload-typed expression is
    # never recorded for it (see `record_expr_type`), so no C name is needed.
    return Option[types.Type].some(value = types.variant_arm_payload_with(
        variant_name = variant_name,
        module_name = module_name,
        c_name = "",
        arm_name = arm_name,
        variant_text = variant_text.as_str(),
        fields = fields.as_span(),
    ))


## Infer every interpolation part of a format string (`f"#{read(p)}"`), so the
## nested operations are checked and their unsafe requirements recorded — the
## host's `check_format_string_literal`.
function check_format_string_parts(
    ctx: ref[Context],
    scope: ref[sscope.Scope],
    parts: span[ast.FormatStringPart]
) -> void:
    var i: ptr_uint = 0
    while i < parts.len:
        var part: ast.FormatStringPart
        unsafe:
            part = read(parts.data + i)
        match part:
            ast.FormatStringPart.fmt_expr as fe:
                let _ty = infer_expr(ctx, scope, fe.expression)
            ast.FormatStringPart.fmt_text:
                pass
        i += 1


## Check a proc literal's body (`proc(x: int) -> bool: …`): the parameters are
## declared in a fresh scope and the block is checked with the proc's return
## type, so nested operations are inferred and their unsafe requirements
## recorded — the host's `infer_proc_expression`.
function check_proc_body(
    ctx: ref[Context],
    scope: ref[sscope.Scope],
    param_types: span[types.Type],
    param_names: span[str],
    ret: types.Type,
    body: ptr[ast.Stmt]?
) -> void:
    let b = body else:
        return
    scope_enter(scope)
    var i: ptr_uint = 0
    while i < param_types.len and i < param_names.len:
        unsafe:
            let pname = read(param_names.data + i)
            let pty = read(param_types.data + i)
            scope_set(scope, pname, pty)
            scope_set_storage(scope, pname, pty)
            scope_set_let(scope, pname)
            scope_set_param(scope, pname)
        i += 1
    let proc_flags = check_flags(ret, false, false, false)
    check_body(ctx, scope, proc_flags, b)
    scope_leave(scope)


function infer_binary(
    ctx: ref[Context],
    scope: ref[sscope.Scope],
    op: str,
    left: ptr[ast.Expr],
    right: ptr[ast.Expr]
) -> types.Type:
    # The host's `propagating_expected_type`: an arithmetic binary's numeric
    # expected type reaches both operands, so a literal operand takes it when
    # its value fits (`return 200 + 56` in a `-> ubyte` body).
    let outer_hint = ctx.expected_type_hint
    var operand_hint: types.Type = types.Type.ty_error
    if is_arithmetic_binary_op(op):
        match outer_hint:
            types.Type.ty_primitive as hp:
                if types.is_numeric_name(hp.name):
                    operand_hint = outer_hint
            _:
                pass
    if not types.is_error(operand_hint):
        ctx.expected_type_hint = operand_hint
    # Always infer both operands so nested calls in either side are checked.
    let lt = infer_expr(ctx, scope, left)
    if op.equal("and") or op.equal("or"):
        # Short-circuit: the right operand is evaluated only when the left is
        # truthy (resp. falsy), so the left's refinements are in scope there —
        # the host's `infer_binary`, which refines before the right side is
        # checked (`p != null and read(p)…` narrows `p` for the read).
        scope_enter(scope)
        var refs = flow_refinements(ctx, left, op.equal("and"), scope)
        apply_refinements_to_frame(ctx, scope, ref_of(refs))
        let _short_circuit_ty = infer_expr(ctx, scope, right)
        refs.release()
        scope_leave(scope)
        ctx.expected_type_hint = outer_hint
        return types.primitive("bool")
    let rt = infer_expr(ctx, scope, right)
    ctx.expected_type_hint = outer_hint
    return infer_binary_operands(ctx, op, left, right, lt, rt)


## The result type of a binary operation whose operand types are already known.
## Shared by expression inference and compound assignment (which must not
## re-infer the target/value expressions).
function infer_binary_operands(
    ctx: ref[Context],
    op: str,
    left: ptr[ast.Expr],
    right: ptr[ast.Expr],
    lt: types.Type,
    rt: types.Type
) -> types.Type:
    harmonize_float_binary_operands(ctx, op, left, right, lt, rt)
    if is_comparison_op(op):
        return types.primitive("bool")
    # SIMD arithmetic: vector ⊕ vector (same element and lane count) yields the
    # vector; vector * scalar and scalar * vector broadcast the scalar.
    if types.is_simd_type(lt) or types.is_simd_type(rt):
        let simd_ty = infer_simd_binary_type(op, lt, rt)
        if not types.is_error(simd_ty):
            return simd_ty
    if (types.is_raw_pointer(lt) or types.is_raw_pointer(rt)) and not in_generic_body(ctx):
        if ctx.unsafe_depth == 0:
            report(ctx, 0, 0, "pointer arithmetic requires unsafe")
        else:
            mark_required_unsafe(ctx)
    if types.is_numeric(lt) and types.is_numeric(rt):
        return infer_numeric_binary_type(ctx, op, left, right, lt, rt)
    # `str + str` concatenates (the host's infer_binary `"+"` case).
    if op == "+" and types.is_str(lt) and types.is_str(rt):
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


function infer_numeric_binary_type(
    ctx: ref[Context],
    op: str,
    left: ptr[ast.Expr],
    right: ptr[ast.Expr],
    lt: types.Type,
    rt: types.Type
) -> types.Type:
    # The host's `propagating_expected_type`: an arithmetic binary's numeric
    # expected type reaches both operands, so a bare float literal in a
    # float context takes that type (`val / 4294967296.0` in a `next_double`
    # body is a double binary) and the promoted result is the context's.
    let expected_hint = ctx.expected_type_hint
    if types.is_float_type(expected_hint) and is_arithmetic_binary_op(op):
        var lt_eff = lt
        var rt_eff = rt
        if is_bare_float_literal_expr(left):
            lt_eff = expected_hint
        if is_bare_float_literal_expr(right):
            rt_eff = expected_hint
        if not types.type_equals(lt_eff, lt) or not types.type_equals(rt_eff, rt):
            match sem_exprs.common_numeric_type(lt_eff, rt_eff):
                Option.some as common:
                    return common.value
                Option.none:
                    pass
    # A literal operand adapts to the other operand's numeric type, so
    # `48 + value` types as `value`'s type and `1 << uint<-x` as uint —
    # mirrors Ruby's harmonize_binary_integer_literal_types /
    # harmonize_binary_float_literal_types.  The adaptation is gated on the
    # literal's *value* fitting the peer type (the host re-infers the literal
    # with that expected type): `300 + 0` in a `ubyte` body keeps `300` an
    # `int`, so the binary is `int` and the assignment check rejects it.
    if is_bare_integer_literal(left) and types.is_integer_type(rt) and integer_literal_fits_type(left, rt):
        return rt
    if is_bare_integer_literal(right) and types.is_integer_type(lt) and integer_literal_fits_type(right, lt):
        return lt
    if is_float_literal_expr(left) and types.is_float_type(rt):
        return rt
    if is_float_literal_expr(right) and types.is_float_type(lt):
        return lt
    # A shift's result is its left operand's type (the host's `<<`/`>>`
    # arm); the amount never promotes the result.
    if op.equal("<<") or op.equal(">>"):
        return lt
    # Otherwise the promoted common type (an int operand with a float
    # sibling is float), exactly like Ruby's `common_numeric_type`.
    match sem_exprs.common_numeric_type(lt, rt):
        Option.some as promoted:
            return promoted.value
        Option.none:
            pass
    return lt


## The SIMD operator set: arithmetic for every lane type, plus `%` and bitwise/
## shift operators for integer lanes.
function simd_binary_op_supported(op: str, element: types.Type) -> bool:
    if op == "+" or op == "-" or op == "*" or op == "/":
        return true
    if types.is_integer_type(element):
        return (
            op == "%" or op == "&" or op == "|" or op == "^"
            or op == "<<" or op == ">>"
        )
    return false


function infer_simd_binary_type(op: str, lt: types.Type, rt: types.Type) -> types.Type:
    if types.is_simd_type(lt) and types.is_simd_type(rt):
        if types.type_equals(lt, rt) and simd_binary_op_supported(op, types.simd_element_type(lt)):
            return lt
    if types.is_simd_type(lt) and types.is_numeric(rt) and types.type_equals(types.simd_element_type(lt), rt):
        if simd_binary_op_supported(op, types.simd_element_type(lt)):
            return lt
    if types.is_simd_type(rt) and types.is_numeric(lt) and types.type_equals(types.simd_element_type(rt), lt):
        if simd_binary_op_supported(op, types.simd_element_type(rt)):
            return rt
    return types.Type.ty_error


function harmonize_float_binary_operands(
    ctx: ref[Context],
    op: str,
    left: ptr[ast.Expr],
    right: ptr[ast.Expr],
    lt: types.Type,
    rt: types.Type
) -> void:
    # The host's `harmonize_binary_float_literal_types` (and the expected-type
    # propagation into both operands): an unsuffixed float-literal operand is
    # *re-inferred* with the peer's float type, so `double<-x * 1000.0`
    # records `1000.0` as `double` and the linter/lowering see that type.
    let hint = ctx.expected_type_hint
    if types.is_float_type(hint) and is_arithmetic_binary_op(op):
        if is_bare_float_literal_expr_or_unary(left):
            record_expr_type(ctx, left, hint)
        if is_bare_float_literal_expr_or_unary(right):
            record_expr_type(ctx, right, hint)
    if is_bare_float_literal_expr_or_unary(left) and types.is_float_type(rt):
        record_expr_type(ctx, left, rt)
    if is_bare_float_literal_expr_or_unary(right) and types.is_float_type(lt):
        record_expr_type(ctx, right, lt)


public function is_vec_math_name(name: str) -> bool:
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


## True when the integer literal's value fits `target`'s range — the gate on
## binary operand harmonization (the host re-infers the literal with the peer
## type only when the value fits it).
function integer_literal_fits_type(ep: ptr[ast.Expr], target: types.Type) -> bool:
    let name = primitive_name_or_empty(target)
    if not types.is_fixed_width_integer_name(name):
        return false
    unsafe:
        match read(ep):
            ast.Expr.expr_integer_literal as lit:
                return types.integer_constant_fits(name, long<-lit.value)
            _:
                return false


## The primitive name of `t`, or the empty string.
function primitive_name_or_empty(t: types.Type) -> str:
    match t:
        types.Type.ty_primitive as p:
            return p.name
        _:
            return ""


## A bare float literal — no `f`/`d` suffix — takes an expected float type
## (the host's `AST::FloatLiteral` inference checks the lexeme first).
function is_bare_float_literal_expr(ep: ptr[ast.Expr]) -> bool:
    unsafe:
        match read(ep):
            ast.Expr.expr_float_literal as lit:
                return not (lit.lexeme.ends_with("f") or lit.lexeme.ends_with("d"))
            _:
                return false


## The arithmetic operators whose numeric expected type propagates to the
## operands (the host's `propagating_expected_type`: `+ - * / % << >>`).
function is_arithmetic_binary_op(op: str) -> bool:
    return op == "+" or op == "-" or op == "*" or op == "/" or op == "%" or op == "<<" or op == ">>"


## An unsuffixed float literal, optionally under unary `+`/`-`: the host's
## `float_literal_expression?` restricted to literals whose type may adopt the
## expected/peer float type (`1.0f`/`1.0d` keep their explicit type).
function is_bare_float_literal_expr_or_unary(ep: ptr[ast.Expr]) -> bool:
    unsafe:
        match read(ep):
            ast.Expr.expr_float_literal as lit:
                return not (lit.lexeme.ends_with("f") or lit.lexeme.ends_with("d"))
            ast.Expr.expr_unary_op as u:
                if u.operator == "+" or u.operator == "-":
                    return is_bare_float_literal_expr_or_unary(u.operand)
                return false
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


public function primitive_type_name_static(t: types.Type) -> str:
    match t:
        types.Type.ty_primitive as p:
            return p.name
        types.Type.ty_named as n:
            let n_np = unsafe: read(n.payload)
            return n_np.name
        types.Type.ty_imported as im:
            let im_bp = unsafe: read(im.payload)
            return im_bp.name
        _:
            return ""


function is_comparison_op(op: str) -> bool:
    return (
        op == "==" or op == "!=" or op == "<" or op == "<="
        or op == ">" or op == ">="
    )


## A tuple literal `(1, "x")` / `(a = 1, b = 2)`.  Mirrors the host's
## `Types::Registry.tuple(element_types, field_names:)`: the element types in
## order, with the field names when any element is named.
function infer_tuple_literal(ctx: ref[Context], scope: ref[sscope.Scope], ep: ptr[ast.Expr]) -> types.Type:
    var elements = vec.Vec[types.Type].create()
    var names = vec.Vec[str].create()
    var has_named = false
    # The host's `infer_expression` for an expression list gives the elements
    # an expected type only for an array context (each element takes the
    # element type); otherwise the elements are inferred without one.  Keeping
    # the outer hint would hand a tuple-typed return's elements the tuple type
    # (`return (name, if cond: a else: b)`).
    let outer_hint = ctx.expected_type_hint
    var element_hint = types.Type.ty_error
    match outer_hint:
        types.Type.ty_generic as hg:
            let hg_bp = unsafe: read(hg.payload)
            if hg_bp.name == "array" and hg_bp.args.len >= 1:
                element_hint = unsafe: read(hg_bp.args.data + 0)
        _:
            pass
    ctx.expected_type_hint = element_hint
    unsafe:
        match read(ep):
            ast.Expr.expr_expression_list as el:
                var i: ptr_uint = 0
                while i < el.elements.len:
                    let elem_ptr: ptr[ast.Expr] = el.elements.data + i
                    match read(elem_ptr):
                        ast.Expr.expr_named as nm:
                            elements.push(infer_expr(ctx, scope, nm.value))
                            names.push(nm.name)
                            has_named = true
                        _:
                            elements.push(infer_expr(ctx, scope, elem_ptr))
                            names.push("")
                    i += 1
            _:
                ctx.expected_type_hint = outer_hint
                return types.Type.ty_error
    ctx.expected_type_hint = outer_hint
    var field_names: Option[span[str]] = Option[span[str]].none
    if has_named:
        field_names = Option[span[str]].some(value = names.as_span())
    return types.tuple_type(elements = elements.as_span(), field_names = field_names)


function infer_unary(ctx: ref[Context], scope: ref[sscope.Scope], op: str, operand: ptr[ast.Expr]) -> types.Type:
    let ot = infer_expr(ctx, scope, operand)
    if op == "not":
        return types.primitive("bool")
    if op == "-" or op == "+" or op == "~":
        return ot
    if op == "?":
        # The try operator propagates the failure and yields the success type
        # (`Result[T, E]?` and `Option[T]?` both give `T`), exactly like a
        # guard-unwrapped binding.  A bare nullable is not a propagation
        # source; the host reports at the enclosing statement's anchor.
        if not types.contains_error(ot) and not is_option_or_result(ot):
            report(ctx, ctx.statement_line, ctx.statement_column, diag.propagation_message(ot))
            return types.Type.ty_error
        return unwrap_nullable_type(ot)
    return types.Type.ty_error


## Resolve the parameter list a call's named arguments map onto.  False means
## the callee is not a signature-bearing function/method (a builtin, struct or
## variant constructor, a callable value, or an unresolved name).
function call_parameter_info(
    ctx: ref[Context],
    scope: ref[sscope.Scope],
    callee: ptr[ast.Expr],
    name_out: ref[str],
    sig_out: ref[FnSig]
) -> bool:
    unsafe:
        match read(callee):
            ast.Expr.expr_identifier as id:
                return identifier_parameter_info(ctx, scope, id.name, name_out, sig_out)
            ast.Expr.expr_member_access as ma:
                return member_calls.member_parameter_info(ctx, scope, ma.receiver, ma.member_name, name_out, sig_out)
            ast.Expr.expr_specialization as spec:
                return specialization_parameter_info(ctx, scope, spec.callee, name_out, sig_out)
            _:
                return false


function identifier_parameter_info(
    ctx: ref[Context],
    scope: ref[sscope.Scope],
    name: str,
    name_out: ref[str],
    sig_out: ref[FnSig]
) -> bool:
    if is_builtin_call_name(name) or is_callable_builtin_name(name) or scope_get(scope, name) != null:
        return false
    let sig_ptr = ctx.functions.get(name)
    if sig_ptr == null:
        return false
    read(name_out) = name
    unsafe:
        read(sig_out) = read(sig_ptr)
    return true


## A specialization's signature: a local/imported generic function
## (`ident[int]`, `lib.ident[int]`) or a generic method on a value receiver
## (`storage.alloc[ptr[char]]`).  A specialization of a struct/variant/builtin
## is a construction and keeps its named fields.
function specialization_parameter_info(
    ctx: ref[Context],
    scope: ref[sscope.Scope],
    callee: ptr[ast.Expr],
    name_out: ref[str],
    sig_out: ref[FnSig]
) -> bool:
    unsafe:
        match read(callee):
            ast.Expr.expr_identifier as id:
                return identifier_parameter_info(ctx, scope, id.name, name_out, sig_out)
            ast.Expr.expr_member_access as ma:
                match read(ma.receiver):
                    ast.Expr.expr_identifier as rid:
                        if scope_get(scope, rid.name) == null and ctx.import_aliases.contains(rid.name):
                            let module_name_ptr = ctx.import_aliases.get(rid.name)
                            if module_name_ptr == null:
                                return false
                            let binding_ptr = find_binding(ctx, read(module_name_ptr))
                            if binding_ptr == null:
                                return false
                            let sig_ptr = read(binding_ptr).functions.get(ma.member_name)
                            if sig_ptr == null:
                                return false
                            read(name_out) = ma.member_name
                            read(sig_out) = read(sig_ptr)
                            return true
                        let rtp = scope_get(scope, rid.name)
                        if rtp == null:
                            return false
                        let recv_ty = unwrap_ref(read(rtp))
                        if method_type_params_of(ctx, recv_ty, ma.member_name).is_none():
                            return false
                        match resolve_method_sig(ctx, recv_ty, ma.member_name):
                            Option.some as sig:
                                read(name_out) = ma.member_name
                                read(sig_out) = sig.value
                                return true
                            Option.none:
                                return false
                    _:
                        let recv_ty = unwrap_ref(infer_expr(ctx, scope, ma.receiver))
                        if method_type_params_of(ctx, recv_ty, ma.member_name).is_none():
                            return false
                        match resolve_method_sig(ctx, recv_ty, ma.member_name):
                            Option.some as sig:
                                read(name_out) = ma.member_name
                                read(sig_out) = sig.value
                                return true
                            Option.none:
                                return false
            _:
                return false


## The callee's source position packed as `line * 1_000_000 + column` (the
## analyzer's usual key): an identifier's own position, a member's name
## position, or the underlying callee of a specialization.
function callee_position(callee: ptr[ast.Expr]) -> ptr_uint:
    unsafe:
        match read(callee):
            ast.Expr.expr_identifier as id:
                return id.line * 1000000 + id.column
            ast.Expr.expr_member_access as ma:
                return ma.line * 1000000 + ma.column
            ast.Expr.expr_specialization as spec:
                return callee_position(spec.callee)
            _:
                return 0


## Canonicalize a call's named arguments to parameter order, mirroring Ruby's
## `canonicalize_call_arguments`: unknown names, duplicate names and a
## positional argument after a named one are reported.  A positional argument
## fills the first free slot, so `f(1, y = 2)` leaves x to the positional; a
## named argument may overwrite a positional slot, as the host does.  Omitted
## parameters with a default (every index at/after `required_count`, since the
## language requires all required parameters first) become a permissive
## placeholder so later arguments keep their parameter alignment.  False means
## the call has no named arguments or no signature to canonicalize against;
## the caller then keeps the source argument list.
function canonicalize_call_arguments(
    ctx: ref[Context],
    scope: ref[sscope.Scope],
    callee: ptr[ast.Expr],
    args: span[ast.Argument],
    line: ptr_uint,
    column: ptr_uint,
    dest: ref[vec.Vec[ast.Argument]],
) -> bool:
    var any_named = false
    var ni: ptr_uint = 0
    while ni < args.len:
        unsafe:
            match read(args.data + ni).arg_name:
                Option.some:
                    any_named = true
                Option.none:
                    pass
        ni += 1
    if not any_named:
        return false
    var display_name: str
    var sig: FnSig
    if not call_parameter_info(ctx, scope, callee, ref_of(display_name), ref_of(sig)):
        return false
    call_arguments.canonicalize_call_arguments_for(ctx, display_name, sig, args, line, column, dest)
    return true


## Build the explicit specialization's substitution map without diagnosing.
## `check_specialization_call` resolves the same type arguments once, with
## diagnostics; the hint pre-pass must not report them twice, so it only accepts
## a bare name the analyzer already knows (a primitive/installed type or a type
## parameter) and gives up on anything that needs full resolution.
public function try_quiet_type_substitutions(
    ctx: ref[Context],
    type_params: span[ast.TypeParam],
    type_args: span[ast.TypeArgument],
    subs: ref[map_mod.Map[str, types.Type]]
) -> bool:
    if type_args.len != type_params.len or not all_plain_type_params(type_params):
        return false
    var i: ptr_uint = 0
    while i < type_params.len:
        var tp: ast.TypeParam
        var tref: ptr[ast.TypeRef]
        unsafe:
            tp = read(type_params.data + i)
            tref = read(type_args.data + i).value
        # A `let ... else:` guard binding an `Option[types.Type]` payload makes
        # the host analyzer ~4.5x slower on this module (a recursive-type guard
        # pathology); the equivalent match keeps the host's compile time flat.
        match quiet_explicit_type(ctx, tref):
            Option.some as resolved:
                subs.set(tp.name, resolved.value)
            Option.none:
                return false
        i += 1
    return true


public function quiet_explicit_type(ctx: ref[Context], tref: ptr[ast.TypeRef]) -> Option[types.Type]:
    unsafe:
        let t = read(tref)
        if t.nullable or t.arguments.len > 0 or t.is_fn or t.is_proc or t.is_dyn or t.is_tuple:
            return Option[types.Type].none
        if t.name.parts.len != 1:
            return Option[types.Type].none
        let name = read(t.name.parts.data + 0)
        let known_ptr = ctx.types.get(name)
        if known_ptr != null:
            return Option[types.Type].some(value = read(known_ptr))
        if ctx.type_params.contains(name):
            return Option[types.Type].some(value = types.Type.ty_var(name = name))
        return Option[types.Type].none


## Infer a call's result type and, when the callee is a local top-level
## function, check argument count and (positional) argument types.  When the
## callee names a local struct, treat it as a struct construction and validate
## named-field references instead.
function infer_and_check_call(
    ctx: ref[Context],
    scope: ref[sscope.Scope],
    callee: ptr[ast.Expr],
    args: span[ast.Argument]
) -> types.Type:
    var any_named = false
    let call_pos = callee_position(callee)
    var canonical_args = vec.Vec[ast.Argument].create()
    defer: canonical_args.release()
    let has_canonical = canonicalize_call_arguments(
        ctx,
        scope,
        callee,
        args,
        call_pos / 1000000,
        call_pos % 1000000,
        ref_of(canonical_args)
    )
    var effective_args = args
    if has_canonical:
        effective_args = canonical_args.as_span()
    var expected = call_arguments.call_argument_expected_types(ctx, scope, callee, effective_args)
    defer: expected.release()
    var arg_types = vec.Vec[types.Type].with_capacity_exact(effective_args.len)
    let saved_hint = ctx.expected_type_hint
    # The compile-time handle builtins take *names*, not values: the host
    # evaluates them specially and records no callable-value site for their
    # arguments.
    let suppress_sites = is_handle_builtin_callee(callee)
    if suppress_sites:
        ctx.callable_site_suppression += 1
    defer:
        if suppress_sites:
            ctx.callable_site_suppression -= 1
    var i: ptr_uint = 0
    while i < effective_args.len:
        var arg: ast.Argument
        unsafe:
            arg = read(effective_args.data + i)
        ctx.expected_type_hint = types.Type.ty_error
        if i < expected.len:
            let hint_ptr = expected.get(i)
            if hint_ptr != null:
                unsafe:
                    ctx.expected_type_hint = read(hint_ptr)
        arg_types.push(infer_expr(ctx, scope, arg.arg_value))
        match arg.arg_name:
            Option.some:
                any_named = true
            Option.none:
                pass
        i += 1

    ctx.expected_type_hint = saved_hint
    let arg_span = arg_types.as_span()

    check_str_construction_unsafe(ctx, scope, callee)

    match try_imported_call(ctx, scope, callee, effective_args, arg_span, any_named):
        Option.some as imported:
            return imported.value
        Option.none:
            pass

    match try_construction(ctx, scope, callee, effective_args):
        Option.some as ct:
            return ct.value
        Option.none:
            unsafe:
                match read(callee):
                    ast.Expr.expr_member_access as ma:
                        return member_calls.check_member_call(
                            ctx,
                            scope,
                            ma.receiver,
                            ma.member_name,
                            effective_args,
                            arg_span,
                            any_named,
                            ma.line,
                            ma.column
                        )
                    ast.Expr.expr_specialization as spec:
                        return check_specialization_call(
                            ctx,
                            scope,
                            spec.callee,
                            spec.arguments,
                            arg_span,
                            effective_args,
                            true
                        )
                    ast.Expr.expr_identifier:
                        return check_call(ctx, scope, callee, effective_args, arg_span, any_named)
                    _:
                        let _ignored = infer_expr(ctx, scope, callee)
                        return types.Type.ty_error


## Positional argument checking for an explicitly specialized generic function:
## the parameter types are substituted from the explicit type arguments, then
## the same compatibility rule runs.  Named arguments have already been
## canonicalized to parameter order by the caller.
function check_substituted_arguments(
    ctx: ref[Context],
    display_name: str,
    sig: FnSig,
    args: span[ast.Argument],
    arg_types: span[types.Type],
    subs: ref[map_mod.Map[str, types.Type]],
    line: ptr_uint,
    column: ptr_uint
) -> void:
    var any_named = false
    var i: ptr_uint = 0
    while i < args.len:
        unsafe:
            match read(args.data + i).arg_name:
                Option.some:
                    any_named = true
                Option.none:
                    pass
        i += 1
    if any_named:
        return
    if sig.is_variadic:
        if arg_types.len < sig.required_count:
            report(ctx, line, column, arity_message(display_name, sig.required_count, arg_types.len))
            return
    else if arg_types.len > sig.params.len or arg_types.len < sig.required_count:
        report(ctx, line, column, arity_message(display_name, sig.required_count, arg_types.len))
        return
    i = 0
    while i < arg_types.len and i < sig.params.len:
        unsafe:
            let atype = read(arg_types.data + i)
            let pe = read(sig.params.data + i)
            let pty = substitute_type(pe.ty, subs)
            if not types.contains_type_var(pty) and not types.contains_error(pty):
                var arg_expr: ptr[ast.Expr]? = null
                if i < args.len:
                    arg_expr = read(args.data + i).arg_value
                var incompatible = false
                if sig.is_extern:
                    if not (member_calls.is_imported_constant_member(
                        ctx,
                        arg_expr
                    ) and types.is_numeric(pty) and types.is_numeric(atype)):
                        incompatible = incompatible_external_value_with_consts(ctx,
                            pty,
                            atype,
                            arg_expr,
                            ref_of(ctx.const_values)
                        )
                else:
                    incompatible = incompatible_value_with_consts(ctx, pty, atype, arg_expr, ref_of(ctx.const_values))
                if incompatible:
                    report(ctx, line, column, argument_message(pe.name, display_name, pty, atype))
        i += 1


## A call whose callee is a specialization `name[Type](...)`.  Associated-function
## hook builtins (hash/equal/order/default) are checked: when the type argument
## is a fully-known local struct, the required hook must exist.  Everything else
## (primitives, imported types, type variables, user generic functions) stays
## permissive.
function check_specialization_call(
    ctx: ref[Context],
    scope: ref[sscope.Scope],
    spec_callee: ptr[ast.Expr],
    type_args: span[ast.TypeArgument],
    arg_types: span[types.Type],
    arg_exprs: span[ast.Argument],
    check_call: bool
) -> types.Type:
    unsafe:
        match read(spec_callee):
            ast.Expr.expr_identifier as id:
                if id.name == "zero" and not ctx.functions.contains(id.name) and scope_get(scope, id.name) == null:
                    return check_zero_call(ctx, type_args, id.line, id.column)
                if id.name == "reinterpret" and not ctx.functions.contains(id.name) and scope_get(
                    scope,
                    id.name
                ) == null:
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
                        if check_call:
                            check_substituted_arguments(
                                ctx,
                                id.name,
                                read(sigp),
                                arg_exprs,
                                arg_types,
                                ref_of(subs),
                                id.line,
                                id.column
                            )
                            return substitute_type(read(sigp).return_type, ref_of(subs))
                        return specialized_function_value_type(id.name, read(sigp), ref_of(subs))
                # A generic struct construction with explicit type arguments
                # (`Pair[int, bool](first = 10, second = true)`): the value is an
                # instance of the named type.
                if scope_get(scope, id.name) == null:
                    let fieldsp = ctx.structs.get(id.name)
                    if fieldsp != null:
                        check_construction(ctx, scope, id.name, read(fieldsp), arg_exprs, id.line, id.column)
                        return types.imported_type(
                            module_name = type_owner_module(ctx, id.name),
                            name = id.name,
                            args = resolve_type_arguments(ctx, type_args)
                        )
                # A builtin construction with explicit type arguments
                # (`array[int, 3](1, 2, 3)`, `span[int](data = …, len = 3)`): the
                # host validates the arguments (`check_array_construction`, and
                # `check_aggregate_construction` for `span`), and the value is an
                # instance of the specialized builtin type.
                if id.name.equal("array") or id.name.equal("span"):
                    return check_builtin_construction(ctx, scope, id.name, type_args, arg_exprs, id.line, id.column)
                return types.Type.ty_error
            ast.Expr.expr_member_access as ma:
                # `alias.fn[T](...)`: an imported generic function called with
                # explicit type arguments (`heap.must_alloc[ubyte](64)`); or
                # `x.method[T](...)`: a generic method on a value receiver
                # (`storage.alloc[ptr[char]](n)`).
                match read(ma.receiver):
                    ast.Expr.expr_identifier as rid:
                        if scope_get(scope, rid.name) == null and ctx.import_aliases.contains(rid.name):
                            return check_imported_specialization_call(
                                ctx,
                                scope,
                                spec_callee,
                                type_args,
                                arg_types,
                                arg_exprs
                            )
                    _:
                        pass
                return check_specialized_method_call(
                    ctx,
                    scope,
                    ma.receiver,
                    ma.member_name,
                    type_args,
                    arg_types,
                    arg_exprs,
                    ma.line,
                    ma.column
                )
            _:
                return types.Type.ty_error


## The value form of a specialized generic function (`span_release[T]` passed
## to a function-typed field).  The expression denotes the function itself, not
## its return value; substituting the explicit type arguments into both the
## parameter and return types gives the callable's real `fn(...)` type.
function specialized_function_value_type(
    name: str,
    sig: FnSig,
    subs: ref[map_mod.Map[str, types.Type]],
) -> types.Type:
    var params = vec.Vec[types.Type].create()
    var names = vec.Vec[str].create()
    var i: ptr_uint = 0
    while i < sig.params.len:
        let param = unsafe: read(sig.params.data + i)
        params.push(substitute_type(param.ty, subs))
        names.push(param.name)
        i += 1
    let ret = substitute_type(sig.return_type, subs)
    return types.function_type(
        name = name,
        params = params.as_span(),
        return_type = types.alloc_type(ret),
        variadic = sig.is_variadic,
        is_proc = false,
        param_names = names.as_span()
    )


## `x.method[T](args)` — a generic method called with explicit type arguments on
## a value receiver (`storage.alloc[ptr[char]](n)`).  The method's declared type
## parameters bind the explicit arguments and its return type is substituted
## (`ptr[T]?` -> `ptr[ptr[char]]?`).  The permissive error type when the method
## or its parameters are not resolvable.
function check_specialized_method_call(
    ctx: ref[Context],
    scope: ref[sscope.Scope],
    receiver: ptr[ast.Expr],
    method_name: str,
    type_args: span[ast.TypeArgument],
    arg_types: span[types.Type],
    arg_exprs: span[ast.Argument],
    line: ptr_uint,
    column: ptr_uint
) -> types.Type:
    let recv_ty = unwrap_ref(infer_expr(ctx, scope, receiver))
    let tps = method_type_params_of(ctx, recv_ty, method_name) else:
        return types.Type.ty_error
    let sig = resolve_method_sig(ctx, recv_ty, method_name) else:
        return types.Type.ty_error
    if tps.len == 0:
        return types.Type.ty_error
    var subs = map_mod.Map[str, types.Type].create()
    defer: subs.release()
    validate_explicit_type_args(ctx, tps, type_args, ref_of(subs), line, column)
    # The host's specialized-call arm records/enforces an editable receiver
    # exactly like a normal member call.
    check_editable_receiver_immutable(ctx, scope, receiver, recv_ty, method_name, line, column)
    check_substituted_arguments(ctx, method_name, sig, arg_exprs, arg_types, ref_of(subs), line, column)
    return substitute_type(sig.return_type, ref_of(subs))


## The declared type parameters of a method on a receiver type: the analyzer's
## own table for a local declaration, the binding's export for an imported one
## (`Arena.alloc` -> `[T]`).
public function method_type_params_of(ctx: ref[Context], recv: types.Type, method_name: str) -> Option[span[ast.TypeParam]]:
    let type_name = method_receiver_type_name(recv)
    if type_name.len == 0:
        return Option[span[ast.TypeParam]].none
    let key = method_key(type_name, method_name)
    let local_ptr = ctx.method_type_params.get(key)
    if local_ptr != null:
        return Option[span[ast.TypeParam]].some(value = unsafe: read(local_ptr))
    match recv:
        types.Type.ty_imported as im:
            let im_bp = unsafe: read(im.payload)
            return binding_method_type_params(ctx, im_bp.module_name, key)
        types.Type.ty_named as n:
            let n_np = unsafe: read(n.payload)
            if n_np.module_name.len > 0 and not n_np.module_name.equal(ctx.module_name):
                return binding_method_type_params(ctx, n_np.module_name, key)
        _:
            pass
    return Option[span[ast.TypeParam]].none


function binding_method_type_params(ctx: ref[Context], module_name: str, key: str) -> Option[span[ast.TypeParam]]:
    let binding = find_binding(ctx, module_name) else:
        return Option[span[ast.TypeParam]].none
    let tps_ptr = unsafe: read(binding).method_type_params.get(key) else:
        return Option[span[ast.TypeParam]].none
    return Option[span[ast.TypeParam]].some(value = unsafe: read(tps_ptr))


## The declared type name a method receiver resolves to (`""` for anything the
## method tables are not keyed by).
function method_receiver_type_name(recv: types.Type) -> str:
    match recv:
        types.Type.ty_named as n:
            let n_np = unsafe: read(n.payload)
            return n_np.name
        types.Type.ty_imported as im:
            let im_bp = unsafe: read(im.payload)
            return im_bp.name
        _:
            return ""


## An imported generic function called with explicit type arguments
## (`heap.must_alloc[ubyte](64)`): validate the type arguments against the
## declared parameters and substitute them into the return type, as the
## identifier arm does for a local generic function.
function check_imported_specialization_call(
    ctx: ref[Context],
    scope: ref[sscope.Scope],
    callee: ptr[ast.Expr],
    type_args: span[ast.TypeArgument],
    arg_types: span[types.Type],
    arg_exprs: span[ast.Argument]
) -> types.Type:
    unsafe:
        match read(callee):
            ast.Expr.expr_member_access as ma:
                match read(ma.receiver):
                    ast.Expr.expr_identifier as alias_id:
                        if scope_get(scope, alias_id.name) != null:
                            return types.Type.ty_error
                        let module_name_ptr = ctx.import_aliases.get(alias_id.name) else:
                            return types.Type.ty_error
                        let binding_ptr = find_binding(ctx, read(module_name_ptr)) else:
                            return types.Type.ty_error
                        let tps_ptr = read(binding_ptr).function_type_params.get(ma.member_name) else:
                            return types.Type.ty_error
                        let sigp = read(binding_ptr).functions.get(ma.member_name) else:
                            return types.Type.ty_error
                        var subs = map_mod.Map[str, types.Type].create()
                        defer: subs.release()
                        validate_explicit_type_args(ctx, read(tps_ptr), type_args, ref_of(subs), ma.line, ma.column)
                        check_substituted_arguments(
                            ctx,
                            ma.member_name,
                            read(sigp),
                            arg_exprs,
                            arg_types,
                            ref_of(subs),
                            ma.line,
                            ma.column
                        )
                        return substitute_type(read(sigp).return_type, ref_of(subs))
                    _:
                        return types.Type.ty_error
            _:
                return types.Type.ty_error


## The lines whose unsafe context was actually required, in insertion order —
## the host's `required_unsafe_lines` array on the analysis facts.
function required_unsafe_line_list(ctx: ref[Context]) -> vec.Vec[ptr_uint]:
    var lines = vec.Vec[ptr_uint].create()
    var entries = ctx.required_unsafe_lines.entries()
    while entries.next():
        let entry = entries.current()
        lines.push(unsafe: read(entry.key))
    return lines


## Every imported module's structs and unions with their methods, keyed
## `<module>.<Type>` — the record `Analysis.imported_type_members` carries for the
## LSP (the module bindings themselves are borrowed by the check and not exposed).
function collect_imported_type_members(ctx: ref[Context]) -> map_mod.Map[str, ImportedTypeMembers]:
    var members_by_type = map_mod.Map[str, ImportedTypeMembers].create()
    let modules = ctx.imported_modules else:
        return members_by_type
    var entries = unsafe: read(modules).entries()
    while entries.next():
        let entry = entries.current()
        let module_name = unsafe: read(entry.key)
        collect_binding_members(module_name, entry.value, false, ref_of(members_by_type))
        collect_binding_members(module_name, entry.value, true, ref_of(members_by_type))
        collect_binding_alias_members(ctx, module_name, entry.value, ref_of(members_by_type))
        collect_method_only_members(module_name, entry.value, ref_of(members_by_type))
    return members_by_type


## A binding's method-only types: a module that declares `extending X:` without
## declaring `X` itself (std.iter's `Vec.as_iter`) has no struct/union entry, so
## the LSP's receiver merge would miss its methods — the host's method table is
## keyed by the type object, which that module has regardless.
function collect_method_only_members(
    module_name: str,
    binding_ptr: ptr[ModuleBinding],
    members_by_type: ref[map_mod.Map[str, ImportedTypeMembers]],
) -> void:
    let method_order = unsafe: read(binding_ptr).method_order
    var i: ptr_uint = 0
    while i < method_order.len():
        let key_ptr = method_order.get(i) else:
            break
        let key = unsafe: read(key_ptr)
        # Method keys are `<Type>.<member>`; a qualified type part keeps its dots.
        var last_dot: ptr_uint = key.len
        var k: ptr_uint = 0
        while k < key.len:
            if key.byte_at(k) == '.':
                last_dot = k
            k += 1
        if last_dot < key.len:
            let type_name = key.slice(0, last_dot)
            var full = string.String.create()
            full.append(module_name)
            full.append(".")
            full.append(type_name)
            if not members_by_type.contains(full.as_str()):
                var methods = map_mod.Map[str, FnSig].create()
                var order = vec.Vec[str].create()
                collect_type_methods(type_name, binding_ptr, ref_of(methods), ref_of(order))
                members_by_type.set(full.as_str(), ImportedTypeMembers(
                    fields = span[FieldEntry](), methods = methods, method_order = order, declared = false))
        i += 1


## A module's public type aliases: the host's type identity resolves an alias to
## the underlying Struct, so a receiver spelled with the alias (`rl.Color` for
## `public type Color = c.Color`) carries the target's fields and the module's
## own `<Alias>.<method>` extending methods (`std.raylib`'s `Color.from_hsv`).
function collect_binding_alias_members(
    ctx: ref[Context],
    module_name: str,
    binding_ptr: ptr[ModuleBinding],
    members_by_type: ref[map_mod.Map[str, ImportedTypeMembers]],
) -> void:
    var entries = unsafe: read(binding_ptr).type_alias_types.entries()
    while entries.next():
        let entry = entries.current()
        let alias_name = unsafe: read(entry.key)
        let target = unsafe: read(entry.value)
        var fields = span[FieldEntry]()
        match target:
            types.Type.ty_imported as tim:
                let tim_bp = unsafe: read(tim.payload)
                let target_binding = find_binding(ctx, tim_bp.module_name)
                if target_binding != null:
                    let fp = unsafe: read(target_binding).structs.get(tim_bp.name)
                    if fp != null:
                        fields = unsafe: read(fp)
            types.Type.ty_named as tn:
                let tn_np = unsafe: read(tn.payload)
                if tn_np.module_name.equal(module_name):
                    let fp = unsafe: read(binding_ptr).structs.get(tn_np.name)
                    if fp != null:
                        fields = unsafe: read(fp)
            _:
                pass
        var methods = map_mod.Map[str, FnSig].create()
        var method_order = vec.Vec[str].create()
        collect_type_methods(alias_name, binding_ptr, ref_of(methods), ref_of(method_order))
        var key = string.String.create()
        key.append(module_name)
        key.append(".")
        key.append(alias_name)
        members_by_type.set(
            key.as_str(),
            ImportedTypeMembers(fields = fields, methods = methods, method_order = method_order, declared = true)
        )


## One group of a binding's types (its structs, or its unions) with their methods.
function collect_binding_members(
    module_name: str,
    binding_ptr: ptr[ModuleBinding],
    union_group: bool,
    members_by_type: ref[map_mod.Map[str, ImportedTypeMembers]],
) -> void:
    var entries = if union_group:
        unsafe: read(binding_ptr).unions.entries()
    else:
        unsafe: read(binding_ptr).structs.entries()
    while entries.next():
        let entry = entries.current()
        let type_name = unsafe: read(entry.key)
        var methods = map_mod.Map[str, FnSig].create()
        var method_order = vec.Vec[str].create()
        collect_type_methods(type_name, binding_ptr, ref_of(methods), ref_of(method_order))
        var key = string.String.create()
        key.append(module_name)
        key.append(".")
        key.append(type_name)
        members_by_type.set(
            key.as_str(),
            ImportedTypeMembers(
                fields = unsafe: read(entry.value),
                methods = methods,
                method_order = method_order,
                declared = true
            )
        )


## A type's methods, keyed by their own names: the binding's `method_sigs` are
## keyed `<Type>.<method>` (no `static:` marker — the signature's `method_kind`
## carries that).  Iterating the binding's `method_order` keeps the host's
## per-type registration order in `order`.
function collect_type_methods(
    type_name: str,
    binding_ptr: ptr[ModuleBinding],
    methods: ref[map_mod.Map[str, FnSig]],
    order: ref[vec.Vec[str]]
) -> void:
    var prefix = string.String.create()
    prefix.append(type_name)
    prefix.append(".")
    let method_order = unsafe: read(binding_ptr).method_order
    var i: ptr_uint = 0
    while i < method_order.len():
        let key_ptr = method_order.get(i) else:
            break
        let key = unsafe: read(key_ptr)
        if key.starts_with(prefix.as_str()):
            let sig_ptr = unsafe: read(binding_ptr).method_sigs.get(key)
            if sig_ptr != null:
                let method_name = key.slice(prefix.len(), key.len - prefix.len())
                methods.set(method_name, unsafe: read(sig_ptr))
                order.push(method_name)
        i += 1


## The host does not check a *generic* body — it is checked at instantiation —
## so an unsafe-context requirement inside one is neither reported nor recorded
## (this is why `redundant-unsafe` skips generic bodies).
function in_generic_body(ctx: ref[Context]) -> bool:
    return ctx.type_params.len() > 0


## The host's `mark_current_unsafe_required!`: an operation that needs `unsafe`,
## reached while inside an `unsafe:` context, marks the *enclosing* unsafe node's
## line so the linter's `redundant-unsafe` rule can tell a required `unsafe:`
## from one with nothing to do.
function mark_required_unsafe(ctx: ref[Context]) -> void:
    let top = ctx.unsafe_statement_lines.last() else:
        return
    ctx.required_unsafe_lines.set(unsafe: read(top), true)


## The host's `require_unsafe!` with explicit positions: an operation that needs
## `unsafe`, reached inside an `unsafe:` context, marks the enclosing node;
## outside one it is reported at the given position.
function require_unsafe_at(ctx: ref[Context], line: ptr_uint, column: ptr_uint, message: str) -> void:
    if ctx.unsafe_depth == 0:
        report(ctx, line, column, message)
    else:
        mark_required_unsafe(ctx)


## The host's `check_cast_call` for a `T<-expr` prefix cast.  A cast to the same
## type is a no-op (the redundant-cast lint's business).  A cast between two
## pointer-represented types, and one from a `ref` to such a type, requires
## `unsafe` — reported at the *operand's* position outside an `unsafe:` context,
## marking the enclosing `unsafe:` node inside one.  Everything else must make a
## numeric cast; the host reports `cast requires compatible types` for the
## residue, which the self only emits for sides it can classify concretely.
function check_cast_call(
    ctx: ref[Context],
    operand: ptr[ast.Expr],
    source: types.Type,
    target: types.Type,
    line: ptr_uint,
    column: ptr_uint
) -> void:
    if types.type_equals(source, target):
        return
    if types.is_pointer_cast_type(source) and types.is_pointer_cast_type(target):
        if not in_generic_body(ctx):
            require_unsafe_at(
                ctx,
                expr_source_line(operand),
                expr_source_column(operand),
                "pointer cast requires unsafe"
            )
        return
    if types.is_ref_type(source) and types.is_pointer_cast_type(target):
        if not in_generic_body(ctx):
            require_unsafe_at(
                ctx,
                expr_source_line(operand),
                expr_source_column(operand),
                "ref to pointer cast requires unsafe"
            )
        return
    if not cast_side_incompatible(ctx, source) and not cast_side_incompatible(ctx, target):
        return
    if cast_operand_unknown(source) or cast_operand_unknown(target):
        return
    var message = string.String.from_str("cast requires compatible types, got ")
    message.append(types.type_to_string(source))
    message.append(" -> ")
    message.append(types.type_to_string(target))
    report(ctx, line, column, message.as_str())


## True when a cast operand's type is not concrete enough to justify the
## incompatible-cast error: the permissive error type (an unresolved name, a
## payload field the analyzer does not model, …) or a generic type variable.
function cast_operand_unknown(t: types.Type) -> bool:
    if types.contains_error(t):
        return true
    match t:
        types.Type.ty_var:
            return true
        _:
            return false


## True when a cast operand surely cannot take part in a numeric cast: it is
## resolved, is not a numeric/bool/char primitive, and is not an enum-like value
## whose backing type makes the host's cast numeric (a local or imported
## enum/flags/variant, whose declaration tables the analyzer owns).
function cast_side_incompatible(ctx: ref[Context], t: types.Type) -> bool:
    match types.cast_numeric_type(t):
        Option.some:
            return false
        Option.none:
            pass
    match t:
        types.Type.ty_named as n:
            let n_np = unsafe: read(n.payload)
            return not ctx.static_member_types.contains(n_np.name)
        types.Type.ty_imported as im:
            let im_bp = unsafe: read(im.payload)
            let binding = find_binding(ctx, im_bp.module_name) else:
                return false
            return not unsafe: read(binding).static_member_types.contains(im_bp.name)
        _:
            return true


## The host's `check_aggregate_construction` StringView arm: constructing a
## `str` — directly (`str(data = …, len = …)`) or through a type alias of `str`
## — borrows raw storage and requires `unsafe`.  The construction's own type
## stays whatever it was (the self does not model `str`'s construction as a
## struct call), only the requirement is recorded.
function check_str_construction_unsafe(ctx: ref[Context], scope: ref[sscope.Scope], callee: ptr[ast.Expr]) -> void:
    if in_generic_body(ctx):
        return
    if not callee_constructs_str(ctx, scope, callee):
        return
    require_unsafe_at(ctx, expr_source_line(callee), expr_source_column(callee), "str construction requires unsafe")


## True when a call's callee names the `str` type itself or a type alias whose
## resolved type is `str`, and is not shadowed by a local or a function.
function callee_constructs_str(ctx: ref[Context], scope: ref[sscope.Scope], callee: ptr[ast.Expr]) -> bool:
    unsafe:
        match read(callee):
            ast.Expr.expr_identifier as id:
                if scope_get(scope, id.name) != null:
                    return false
                if ctx.functions.contains(id.name) or ctx.type_params.contains(id.name):
                    return false
                if id.name.equal("str"):
                    return true
                return type_alias_resolves_to_str(ctx, id.name)
            ast.Expr.expr_member_access as ma:
                match read(ma.receiver):
                    ast.Expr.expr_identifier as alias_id:
                        if scope_get(scope, alias_id.name) != null:
                            return false
                        let module_name = ctx.import_aliases.get(alias_id.name) else:
                            return false
                        let binding = find_binding(ctx, read(module_name)) else:
                            return false
                        let alias_type = read(binding).type_alias_types.get(ma.member_name) else:
                            return false
                        return types.is_str(read(alias_type))
                    _:
                        return false
            _:
                return false


## True when a local type alias resolves (directly or transitively) to `str`.
function type_alias_resolves_to_str(ctx: ref[Context], name: str) -> bool:
    let alias_type = ctx.type_alias_types.get(name) else:
        return false
    unsafe:
        match read(alias_type):
            types.Type.ty_str:
                return true
            _:
                return false


## The host's `source_line`: the first position-carrying node of an expression
## (a member access reports its receiver, a call its callee, …).  0 when the
## expression carries none.
function expr_source_line(ep: ptr[ast.Expr]) -> ptr_uint:
    unsafe:
        match read(ep):
            ast.Expr.expr_identifier as x:
                return x.line
            ast.Expr.expr_char_literal as x:
                return x.line
            ast.Expr.expr_null_literal as x:
                return x.line
            ast.Expr.expr_member_access as x:
                return x.line
            ast.Expr.expr_match as x:
                return x.line
            ast.Expr.expr_detach as x:
                return x.line
            ast.Expr.expr_expression_list as x:
                return x.line
            ast.Expr.expr_range as x:
                return x.line
            ast.Expr.expr_prefix_cast as x:
                return x.line
            ast.Expr.expr_unsafe as x:
                return x.line
            ast.Expr.expr_error as x:
                return x.line
            ast.Expr.expr_index_access as x:
                let line = expr_source_line(x.receiver)
                if line != 0:
                    return line
                return expr_source_line(x.index)
            ast.Expr.expr_specialization as x:
                return expr_source_line(x.callee)
            ast.Expr.expr_call as x:
                let line = expr_source_line(x.callee)
                if line != 0:
                    return line
                var i: ptr_uint = 0
                while i < x.args.len:
                    let arg_line = expr_source_line(read(x.args.data + i).arg_value)
                    if arg_line != 0:
                        return arg_line
                    i += 1
                return 0
            ast.Expr.expr_unary_op as x:
                return expr_source_line(x.operand)
            ast.Expr.expr_binary_op as x:
                let line = expr_source_line(x.left)
                if line != 0:
                    return line
                return expr_source_line(x.right)
            ast.Expr.expr_if as x:
                let line = expr_source_line(x.condition)
                if line != 0:
                    return line
                let then_line = expr_source_line(x.then_expr)
                if then_line != 0:
                    return then_line
                return expr_source_line(x.else_expr)
            ast.Expr.expr_await as x:
                return expr_source_line(x.expression)
            _:
                return 0


## The host's `source_column` — see `expr_source_line`.
function expr_source_column(ep: ptr[ast.Expr]) -> ptr_uint:
    unsafe:
        match read(ep):
            ast.Expr.expr_identifier as x:
                return x.column
            ast.Expr.expr_char_literal as x:
                return x.column
            ast.Expr.expr_null_literal as x:
                return x.column
            ast.Expr.expr_member_access as x:
                return x.column
            ast.Expr.expr_match as x:
                return x.column
            ast.Expr.expr_detach as x:
                return x.column
            ast.Expr.expr_expression_list as x:
                return x.column
            ast.Expr.expr_range as x:
                return x.column
            ast.Expr.expr_prefix_cast as x:
                return x.column
            ast.Expr.expr_unsafe as x:
                return x.column
            ast.Expr.expr_error as x:
                return x.column
            ast.Expr.expr_index_access as x:
                let column = expr_source_column(x.receiver)
                if column != 0:
                    return column
                return expr_source_column(x.index)
            ast.Expr.expr_specialization as x:
                return expr_source_column(x.callee)
            ast.Expr.expr_call as x:
                let column = expr_source_column(x.callee)
                if column != 0:
                    return column
                var i: ptr_uint = 0
                while i < x.args.len:
                    let arg_column = expr_source_column(read(x.args.data + i).arg_value)
                    if arg_column != 0:
                        return arg_column
                    i += 1
                return 0
            ast.Expr.expr_unary_op as x:
                return expr_source_column(x.operand)
            ast.Expr.expr_binary_op as x:
                let column = expr_source_column(x.left)
                if column != 0:
                    return column
                return expr_source_column(x.right)
            ast.Expr.expr_if as x:
                let column = expr_source_column(x.condition)
                if column != 0:
                    return column
                let then_column = expr_source_column(x.then_expr)
                if then_column != 0:
                    return then_column
                return expr_source_column(x.else_expr)
            ast.Expr.expr_await as x:
                return expr_source_column(x.expression)
            _:
                return 0


## `reinterpret[T](v)` returns T; requires unsafe context.
function check_reinterpret_call(
    ctx: ref[Context],
    type_args: span[ast.TypeArgument],
    arg_types: span[types.Type],
    line: ptr_uint,
    column: ptr_uint
) -> types.Type:
    if type_args.len != 1:
        return types.Type.ty_error
    if not in_generic_body(ctx):
        if ctx.unsafe_depth == 0:
            report(ctx, line, column, "reinterpret requires unsafe")
        else:
            mark_required_unsafe(ctx)
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
            let g_bp = unsafe: read(g.payload)
            if g_bp.name == "ptr" or g_bp.name == "const_ptr" or g_bp.name == "own":
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
function check_zero_call(
    ctx: ref[Context],
    type_args: span[ast.TypeArgument],
    line: ptr_uint,
    column: ptr_uint
) -> types.Type:
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
    let iface_qname = unsafe: read(arg_ref).name
    let iface_name = unsafe: qname_to_str(iface_qname)
    var dyn_args = vec.Vec[types.Type].create()
    var di: ptr_uint = 0
    while di < iface_qname.type_arguments.len:
        dyn_args.push(resolve_type(ctx, unsafe: iface_qname.type_arguments.data + di))
        di += 1
    return types.dyn_type(iface = iface_name, args = dyn_args.as_span())


## `array[T, N](v0, …, vN)` and `span[T](data = …, len = …)` — the host's
## explicit builtin constructions (`check_array_construction`, and
## `check_aggregate_construction` for `span`, whose field table is
## `data: ptr[T]` / `len: ptr_uint`).  A failing argument reports the host's
## message and yields the error type, so nothing is recorded for the
## expression — the host's facts then carry no construction type either.
function check_builtin_construction(
    ctx: ref[Context],
    scope: ref[sscope.Scope],
    name: str,
    type_args: span[ast.TypeArgument],
    args: span[ast.Argument],
    line: ptr_uint,
    column: ptr_uint,
) -> types.Type:
    let builtin_type = types.generic_type(name = name, args = resolve_type_arguments(ctx, type_args))

    if name.equal("array"):
        if type_args.len != 2:
            report(ctx, line, column, "array requires exactly two type arguments")
            return types.Type.ty_error
        var elem_ref: ptr[ast.TypeRef] = unsafe: read(type_args.data + 0).value
        var length_ref: ptr[ast.TypeRef] = unsafe: read(type_args.data + 1).value
        let elem_ty = resolve_type(ctx, elem_ref)
        let length_ty = resolve_type(ctx, length_ref)
        var length: long = 0
        match length_ty:
            types.Type.ty_literal_int as lit:
                length = lit.value
            _:
                # An unresolved length stays permissive; the host's resolver has
                # already folded a const (`array[bool, WORLD_SIZE]`) where it can.
                if types.contains_error(length_ty) or types.contains_error(elem_ty):
                    return builtin_type
                report(ctx, line, column, "array specialization must be array[T, N]")
                return types.Type.ty_error
        var count: ptr_uint = 0
        var i: ptr_uint = 0
        while i < args.len:
            var arg: ast.Argument
            unsafe:
                arg = read(args.data + i)
            match arg.arg_name:
                Option.some:
                    report(ctx, line, column, diag.array_named_args_message())
                    return types.Type.ty_error
                Option.none:
                    count += 1
            i += 1
        if long<-count > length:
            report(ctx, line, column, diag.array_arity_message(length, count))
            return types.Type.ty_error
        i = 0
        while i < args.len:
            var arg: ast.Argument
            unsafe:
                arg = read(args.data + i)
            let saved_hint = ctx.expected_type_hint
            ctx.expected_type_hint = elem_ty
            let at = infer_expr(ctx, scope, arg.arg_value)
            ctx.expected_type_hint = saved_hint
            if incompatible_value_with_consts(ctx, elem_ty, at, arg.arg_value, ref_of(ctx.const_values)):
                report(ctx, line, column, diag.array_element_message(elem_ty, at))
                return types.Type.ty_error
            i += 1
        return builtin_type

    if type_args.len != 1:
        report(ctx, line, column, "span requires exactly one type argument")
        return types.Type.ty_error
    var span_elem_ref: ptr[ast.TypeRef] = unsafe: read(type_args.data + 0).value
    let elem_ty = resolve_type(ctx, span_elem_ref)
    let data_ty = types.generic_type(name = "ptr", args = alloc_one_type_arg(elem_ty))
    let len_ty = types.primitive("ptr_uint")
    var display = types.type_to_string(builtin_type)
    var i: ptr_uint = 0
    while i < args.len:
        var arg: ast.Argument
        unsafe:
            arg = read(args.data + i)
        match arg.arg_name:
            Option.some as nm:
                if nm.value.equal("data"):
                    let saved_hint = ctx.expected_type_hint
                    ctx.expected_type_hint = data_ty
                    let at = infer_expr(ctx, scope, arg.arg_value)
                    ctx.expected_type_hint = saved_hint
                    if not span_data_fits(elem_ty, at):
                        report(ctx, line, column, diag.field_type_mismatch_message(display, "data", data_ty, at))
                        return types.Type.ty_error
                else if nm.value.equal("len"):
                    let saved_hint = ctx.expected_type_hint
                    ctx.expected_type_hint = len_ty
                    let at = infer_expr(ctx, scope, arg.arg_value)
                    ctx.expected_type_hint = saved_hint
                    if incompatible_value_with_consts(ctx, len_ty, at, arg.arg_value, ref_of(ctx.const_values)):
                        report(ctx, line, column, diag.field_type_mismatch_message(display, "len", len_ty, at))
                        return types.Type.ty_error
                else:
                    report(ctx, line, column, unknown_member_message("field", display, nm.value))
                    return types.Type.ty_error
            Option.none:
                report(ctx, line, column, diag.aggregate_named_args_required_message(display))
                return types.Type.ty_error
        i += 1
    return builtin_type


## True when `actual` is a `ptr[T]`/`const_ptr[T]`/`own[T]` (optionally
## nullable) whose pointee is exactly `elem_ty` — the host's `span` `data` field
## takes `ptr[T]`, and its pointer coercions (`own_to_raw_pointer_compatibility?`,
## `mutable_to_const_pointer_compatibility?`) compare pointees with `==`, so an
## assignable-but-different element (an integer widening) does not fit.
function span_data_fits(elem_ty: types.Type, actual: types.Type) -> bool:
    # An unresolved side never forces a mismatch (the self has no field types
    # for `span[T]`'s members yet, so a `span[T].data` argument infers as the
    # error type and must stay permissive).
    if types.contains_error(elem_ty) or types.contains_error(actual):
        return true
    let a = types.unwrap_nullable(actual)
    match a:
        types.Type.ty_generic as g:
            let g_bp = unsafe: read(g.payload)
            if g_bp.name.equal("ptr") or g_bp.name.equal("const_ptr") or g_bp.name.equal("own"):
                if g_bp.args.len >= 1:
                    return types.type_equals(types.pointer_element(a), elem_ty)
            return false
        _:
            return false


## `simd[E, N](v0, ..., vN-1)` constructs a SIMD vector.  Requires exactly two
## type arguments (element type and lane count) and exactly N positional lane
## values assignable to E.
function check_simd_call(
    ctx: ref[Context],
    type_args: span[ast.TypeArgument],
    arg_types: span[types.Type],
    arg_exprs: span[ast.Argument],
    line: ptr_uint,
    column: ptr_uint
) -> types.Type:
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
        if incompatible_value(ctx, elem_ty, at, arg_expr):
            report(ctx, line, column, "simd lane value type does not match the element type")
            return types.Type.ty_error
        i += 1
    var simd_args = vec.Vec[types.Type].create()
    simd_args.push(elem_ty)
    simd_args.push(types.literal_int(lanes))
    return types.generic_type(name = "simd", args = simd_args.as_span())


## `v.with(lane, value)` returns a copy of `v` with one lane replaced.  The
## lane index must be an integer and the value assignable to the element type.
public function check_simd_with_call(
    ctx: ref[Context],
    simd_ty: types.Type,
    args: span[ast.Argument],
    arg_types: span[types.Type],
    any_named: bool,
    line: ptr_uint,
    column: ptr_uint
) -> void:
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
    if incompatible_value(ctx, elem_ty, value_ty, value_expr):
        report(ctx, line, column, "simd.with lane value type does not match the element type")


## Validate the constraints of an explicit `foo[A, B](...)` call: resolve each
## type argument and check it satisfies its parameter's constraints.  Skipped
## unless the parameters are all plain type variables and the counts line up
## (avoids misaligning value/lifetime parameters).
function validate_explicit_type_args(
    ctx: ref[Context],
    type_params: span[ast.TypeParam],
    type_args: span[ast.TypeArgument],
    subs: ref[map_mod.Map[str, types.Type]],
    line: ptr_uint,
    column: ptr_uint
) -> void:
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
public function substitute_type(t: types.Type, subs: ref[map_mod.Map[str, types.Type]]) -> types.Type:
    match t:
        types.Type.ty_var as v:
            let actual_ptr = subs.get(v.name)
            if actual_ptr != null:
                return unsafe: read(actual_ptr)
            return t
        types.Type.ty_nullable as n:
            return types.Type.ty_nullable(base = types.alloc_type(substitute_type(unsafe: read(n.base), subs)))
        types.Type.ty_generic as g:
            let g_bp = unsafe: read(g.payload)
            var new_args = vec.Vec[types.Type].create()
            var i: ptr_uint = 0
            while i < g_bp.args.len:
                unsafe:
                    new_args.push(substitute_type(read(g_bp.args.data + i), subs))
                i += 1
            return types.generic_type(name = g_bp.name, args = new_args.as_span())
        types.Type.ty_function as f:
            let f_ft = unsafe: read(f.payload)
            var new_params = vec.Vec[types.Type].create()
            var pi2: ptr_uint = 0
            while pi2 < f_ft.params.len:
                unsafe:
                    new_params.push(substitute_type(read(f_ft.params.data + pi2), subs))
                pi2 += 1
            let new_ret = substitute_type(unsafe: read(f_ft.return_type), subs)
            return types.function_type(
                name = f_ft.name,
                params = new_params.as_span(),
                return_type = types.alloc_type(new_ret),
                variadic = f_ft.variadic,
                is_proc = f_ft.is_proc,
                param_names = f_ft.param_names
            )
        types.Type.ty_imported as imported:
            let imported_bp = unsafe: read(imported.payload)
            return types.imported_type(
                module_name = imported_bp.module_name,
                name = imported_bp.name,
                args = substitute_type_span(imported_bp.args, subs)
            )
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
function validate_inferred_type_args(
    ctx: ref[Context],
    type_params: span[ast.TypeParam],
    subs: ref[map_mod.Map[str, types.Type]],
    line: ptr_uint,
    column: ptr_uint
) -> void:
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


function check_type_arg_constraints(
    ctx: ref[Context],
    actual: types.Type,
    constraints: span[ast.TypeParamConstraint],
    line: ptr_uint,
    column: ptr_uint
) -> void:
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
function check_constraint_satisfied(
    ctx: ref[Context],
    actual: types.Type,
    constraint: ast.TypeParamConstraint,
    line: ptr_uint,
    column: ptr_uint
) -> void:
    match resolve_interface_methods(ctx, constraint.interface_ref):
        Option.none:
            return
        Option.some:
            pass
    let constraint_id = qname_to_str(constraint.interface_ref)
    match actual:
        types.Type.ty_named as n:
            let n_np = unsafe: read(n.payload)
            let impl_ptr = ctx.implemented.get(n_np.name)
            if impl_ptr == null:
                return
            unsafe:
                if not impl_list_contains(read(impl_ptr), constraint_id):
                    report(ctx, line, column, constraint_unsatisfied_message(n_np.name, constraint_id))
        types.Type.ty_imported as im:
            let im_bp = unsafe: read(im.payload)
            check_imported_constraint(ctx, im_bp.module_name, im_bp.name, constraint, constraint_id, line, column)
        _:
            pass


## Constraint satisfaction for an imported struct type argument.  Safe only when
## the constraint is `alias.Iface` and `alias` names the struct's own module: the
## interface is then local to that module, so the struct implements it via a bare
## `impl_list` entry.  Any other shape (local constraint, interface from a third
## module, unexported impl_list) stays permissive.
function check_imported_constraint(
    ctx: ref[Context],
    struct_module: str,
    struct_name: str,
    constraint: ast.TypeParamConstraint,
    constraint_id: str,
    line: ptr_uint,
    column: ptr_uint
) -> void:
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
    let binding_ptr = find_binding(ctx, struct_module) else:
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
function unify_call_args(
    params: span[ParamEntry],
    arg_types: span[types.Type],
    subs: ref[map_mod.Map[str, types.Type]]
) -> void:
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
function argument_inference_type(
    ctx: ref[Context],
    scope: ref[sscope.Scope],
    arg: ptr[ast.Expr],
    inferred: types.Type
) -> types.Type:
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
                        return types.function_type(
                            name = id.name,
                            params = params.as_span(),
                            return_type = types.alloc_type(sig.return_type),
                            variadic = sig.is_variadic,
                            is_proc = false,
                            param_names = span[str]()
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
            let pg_bp = unsafe: read(pg.payload)
            if pg_bp.name == "ref" and pg_bp.args.len == 1:
                unify(unsafe: read(pg_bp.args.data + 0), unwrap_ref(actual), subs)
            else:
                match actual:
                    types.Type.ty_generic as ag:
                        let ag_bp = unsafe: read(ag.payload)
                        if (pg_bp.name == "ptr" or pg_bp.name == "const_ptr") and ag_bp.name == "own" and pg_bp.args.len >= 1 and ag_bp.args.len >= 1:
                            unsafe:
                                unify(read(pg_bp.args.data + 0), read(ag_bp.args.data + 0), subs)
                        else if pg_bp.name == ag_bp.name and pg_bp.args.len == ag_bp.args.len:
                            var i: ptr_uint = 0
                            while i < pg_bp.args.len:
                                unsafe:
                                    unify(read(pg_bp.args.data + i), read(ag_bp.args.data + i), subs)
                                i += 1
                    _:
                        pass
        types.Type.ty_imported as pi:
            let pi_bp = unsafe: read(pi.payload)
            # An imported generic type in a signature (`iter_filter[T]` takes
            # `Iter[T]`): unify the type arguments so the call's type parameters
            # bind from the argument types.
            match actual:
                types.Type.ty_imported as ai:
                    let ai_bp = unsafe: read(ai.payload)
                    if pi_bp.name == ai_bp.name and pi_bp.args.len == ai_bp.args.len:
                        var i: ptr_uint = 0
                        while i < pi_bp.args.len:
                            unsafe:
                                unify(read(pi_bp.args.data + i), read(ai_bp.args.data + i), subs)
                            i += 1
                types.Type.ty_generic as ag:
                    let ag_bp = unsafe: read(ag.payload)
                    if pi_bp.name == ag_bp.name and pi_bp.args.len == ag_bp.args.len:
                        var j: ptr_uint = 0
                        while j < pi_bp.args.len:
                            unsafe:
                                unify(read(pi_bp.args.data + j), read(ag_bp.args.data + j), subs)
                            j += 1
                _:
                    pass
        types.Type.ty_function as pf:
            let pf_ft = unsafe: read(pf.payload)
            match actual:
                types.Type.ty_function as af:
                    let af_ft = unsafe: read(af.payload)
                    if pf_ft.params.len == af_ft.params.len:
                        var pi2: ptr_uint = 0
                        while pi2 < pf_ft.params.len:
                            unsafe:
                                unify(read(pf_ft.params.data + pi2), read(af_ft.params.data + pi2), subs)
                            pi2 += 1
                        unsafe:
                            unify(read(pf_ft.return_type), read(af_ft.return_type), subs)
                _:
                    pass
        _:
            pass


function is_hook_name(name: str) -> bool:
    return name == "hash" or name == "equal" or name == "order" or name == "default"


## Check an associated-function hook call `hook[T](...)`.  Flags a missing hook
## only when T is a fully-known local struct; yields the hook's result type.
function check_hook_call(
    ctx: ref[Context],
    hook_name: str,
    type_args: span[ast.TypeArgument],
    line: ptr_uint,
    column: ptr_uint
) -> types.Type:
    if type_args.len != 1:
        return types.Type.ty_error
    var arg_ref: ptr[ast.TypeRef]
    unsafe:
        arg_ref = read(type_args.data + 0).value
    let arg_type = resolve_type(ctx, arg_ref)

    match arg_type:
        types.Type.ty_named as n:
            let n_np = unsafe: read(n.payload)
            if ctx.structs.contains(n_np.name):
                match find_method_anywhere(ctx, n_np.name, hook_name):
                    Option.some:
                        pass
                    Option.none:
                        report(ctx, line, column, hook_missing_message(hook_name, n_np.name))
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
function try_imported_call(
    ctx: ref[Context],
    scope: ref[sscope.Scope],
    callee: ptr[ast.Expr],
    args: span[ast.Argument],
    arg_types: span[types.Type],
    any_named: bool
) -> Option[types.Type]:
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
                        let binding_ptr = find_binding(ctx, read(module_name_ptr)) else:
                            return Option[types.Type].none

                        let sig_ptr = read(binding_ptr).functions.get(ma.member_name)
                        if sig_ptr != null:
                            let sig = read(sig_ptr)
                            check_signature_call(
                                ctx,
                                ma.member_name,
                                sig,
                                args,
                                arg_types,
                                any_named,
                                ma.line,
                                ma.column
                            )
                            let mpi_ptr = read(binding_ptr).mutating_param_indices.get(ma.member_name)
                            if mpi_ptr != null:
                                record_mutating_args_for_indices(ctx, ptr[map_mod.Map[ptr_uint, bool]]<-mpi_ptr, args)
                            let dpm_ptr = read(binding_ptr).directional_param_modes.get(ma.member_name)
                            if dpm_ptr != null:
                                record_directional_ffi_sites(
                                    ctx,
                                    callee,
                                    sig.name,
                                    ptr[map_mod.Map[ptr_uint, DirectionalParamInfo]]<-dpm_ptr,
                                    args
                                )
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
                            return Option[types.Type].some(value = types.imported_type(
                                module_name = read(module_name_ptr),
                                name = ma.member_name,
                                args = span[types.Type]()
                            ))

                        # A re-exported type alias constructs its resolved target
                        # (`rl.Rectangle` is `c.Rectangle`): yield the target type,
                        # as the host's resolved Struct does.  The construction
                        # itself is not field-checked here — the host's check
                        # accepts constants whose folded value fits a narrow field
                        # (`a = sdl.ALPHA_OPAQUE`, declared int), which the self's
                        # coercion rule does not fold yet.
                        let alias_ptr = read(binding_ptr).type_alias_types.get(ma.member_name)
                        if alias_ptr != null:
                            let target = read(ptr[types.Type]<-alias_ptr)
                            match target:
                                types.Type.ty_imported as tim:
                                    let tim_bp = unsafe: read(tim.payload)
                                    let target_binding = find_binding(ctx, tim_bp.module_name) else:
                                        return Option[types.Type].none
                                    if read(target_binding).structs.contains(tim_bp.name):
                                        return Option[types.Type].some(value = target)
                                _:
                                    pass

                        # The module resolved but exports nothing named
                        # `member`: report it instead of falling through to the
                        # permissive path, which silently accepted `a.NOPE()`.
                        report_module_member(ctx, id.name, read(module_name_ptr), ma.member_name, ma.line, ma.column)
                        return Option[types.Type].some(value = types.Type.ty_error)
                    _:
                        return Option[types.Type].none
            _:
                return Option[types.Type].none


## True when the binding exports `member` as a type-like declaration (a struct,
## union, enum/flags/variant name, alias or interface) rather than a value.  The
## value path uses it so a type reference is left to the type paths instead of
## being reported as an unknown value.
function module_exports_type(binding: ModuleBinding, member: str) -> bool:
    return (
        binding.structs.contains(member) or binding.unions.contains(member)
        or binding.types.contains(member) or binding.type_aliases.contains(member)
        or binding.type_alias_types.contains(member) or binding.interfaces.contains(member)
        or binding.static_member_types.contains(member) or binding.variant_arm_fields.contains(member)
        or binding.private_structs.contains(member) or binding.private_unions.contains(member)
        or binding.private_type_aliases.contains(member)
    )


## Report `alias.member` when the alias resolves to a module binding that
## exports nothing named `member`.  Every export surface is consulted, so a
## declaration this binding does not model (a prelude/`std.c` re-export) stays
## silent rather than drawing a false diagnostic.  The alias may also *be* a
## type name (`import std.str as str` plus `str.order(...)`), so a `member_keys`
## entry for `"<alias>.<member>"` counts as a hit: those keys carry the imported
## module's `extending`/static methods.
function report_module_member(
    ctx: ref[Context],
    alias: str,
    module_name: str,
    member: str,
    line: ptr_uint,
    column: ptr_uint
) -> void:
    let binding_ptr = find_binding(ctx, module_name) else:
        return
    let binding = unsafe: read(binding_ptr)
    if (
        binding.functions.contains(member) or binding.structs.contains(member)
        or binding.unions.contains(member) or binding.value_types.contains(member)
        or binding.const_values.contains(member) or binding.type_aliases.contains(member)
        or binding.type_alias_types.contains(member) or binding.static_member_types.contains(member)
        or binding.types.contains(member) or binding.member_names.contains(member)
        or binding.match_case_names.contains(member) or binding.variant_arm_fields.contains(member)
        or binding.interfaces.contains(member) or binding.private_functions.contains(member)
        or binding.private_structs.contains(member) or binding.private_unions.contains(member)
        or binding.private_value_types.contains(member) or binding.private_type_aliases.contains(member)
        or binding.private_static_member_types.contains(member)
        or binding.member_keys.contains(method_key(alias, member))
    ):
        return
    report(ctx, line, column, diag.unknown_module_member_message(alias, member))


## Resolve `alias.member` where `alias` is an imported module and `member` is one
## of its exported values, yielding the value's type.  None for anything else.
function try_imported_member(
    ctx: ref[Context],
    scope: ref[sscope.Scope],
    receiver: ptr[ast.Expr],
    member: str
) -> Option[types.Type]:
    unsafe:
        match read(receiver):
            ast.Expr.expr_identifier as id:
                if scope_get(scope, id.name) != null:
                    return Option[types.Type].none
                let module_name_ptr = ctx.import_aliases.get(id.name) else:
                    return Option[types.Type].none
                let binding_ptr = find_binding(ctx, read(module_name_ptr)) else:
                    return Option[types.Type].none
                let value_ptr = read(binding_ptr).value_types.get(member)
                if value_ptr != null:
                    return Option[types.Type].some(value = read(value_ptr))
                # An imported name that is a type/enum/variant, a static method
                # on a same-named type (`str.order`), or another modelled export
                # belongs to another path; anything else is a genuine miss.
                if not module_exports_type(
                    read(binding_ptr),
                    member
                ) and not read(binding_ptr).member_keys.contains(method_key(id.name, member)):
                    report_module_member(ctx, id.name, read(module_name_ptr), member, id.line, id.column)
                return Option[types.Type].some(value = types.Type.ty_error)
            _:
                return Option[types.Type].none


## Resolve a module name to its import binding, if bindings were provided.
public function find_binding(ctx: ref[Context], module_name: str) -> ptr[ModuleBinding]?:
    let imported = ctx.imported_modules else:
        return null
    unsafe:
        return read(imported).get(module_name)


## See through a `ref[T]` receiver to `T` for member access and method calls,
## matching the language's auto-dereference of `ref` receivers.  An explicit
## lifetime (`ref[@a, T]`) occupies the first argument, so the referent is the
## last one.
public function unwrap_ref(t: types.Type) -> types.Type:
    match t:
        types.Type.ty_generic as g:
            let g_bp = unsafe: read(g.payload)
            if g_bp.name == "ref" and g_bp.args.len >= 1:
                return unsafe: read(g_bp.args.data + (g_bp.args.len - 1))
            return t
        _:
            return t


## True when a generic receiver's own type declares `method_name` among the
## visible bindings — `extending ptr[T]` lives in an imported std module, and
## such a receiver must not be projected to its pointee.
public function generic_receiver_has_method(ctx: ref[Context], t: types.Type, method_name: str) -> bool:
    match t:
        types.Type.ty_generic as g:
            let g_bp = unsafe: read(g.payload)
            match find_method_anywhere(ctx, g_bp.name, method_name):
                Option.some:
                    return true
                Option.none:
                    return false
        _:
            return false


## A member or method receiver projects through a pointer-like type: `ref[T]`
## to its referent, `ptr[T]`/`own[T]`/`const_ptr[T]` to their pointee (the
## host's `project_field_receiver_type` / `project_method_receiver_type`), so
## `state.ready` on an `own[SleepState]` resolves the field.
public function project_pointer_receiver(t: types.Type) -> types.Type:
    match t:
        types.Type.ty_generic as g:
            let g_bp = unsafe: read(g.payload)
            if g_bp.name == "ref" and g_bp.args.len >= 1:
                return unsafe: read(g_bp.args.data + (g_bp.args.len - 1))
            if (g_bp.name == "ptr" or g_bp.name == "own" or g_bp.name == "const_ptr") and g_bp.args.len >= 1:
                var element: types.Type
                unsafe:
                    element = read(g_bp.args.data + 0)
                if not types.is_error(element):
                    return element
            return t
        _:
            return t


## A callable field is called like a method: `task.ready(task.frame)`.  Its
## `fn(...)` type supplies the parameter and return types for the call.
public function function_field_signature(name: str, ft: types.FunctionType) -> FnSig:
    var params = vec.Vec[ParamEntry].create()
    var i: ptr_uint = 0
    while i < ft.params.len:
        let pname = if i < ft.param_names.len: unsafe: read(ft.param_names.data + i) else: ""
        params.push(ParamEntry(name = pname, ty = unsafe: read(ft.params.data + i)))
        i += 1
    return FnSig(
        name = name,
        params = params.as_span(),
        return_type = unsafe: read(ft.return_type),
        has_return_type = true,
        method_kind = ast.MethodKind.mk_plain,
        is_async = false,
        is_variadic = ft.variadic,
        is_extern = false,
        required_count = params.len()
    )


## The declared type-parameter *names* of a receiver's generic type — the
## substitution domain for its methods' signatures.  The prelude variants'
## parameters (`Option` -> `[T]`) and a declared type's (`Vec` -> `[T]`).
public function receiver_type_param_names(ctx: ref[Context], type_name: str) -> Option[span[str]]:
    let variant_params = ctx.variant_param_names.get(type_name)
    if variant_params != null:
        return Option[span[str]].some(value = unsafe: read(variant_params))
    let declared = ctx.type_param_names.get(type_name)
    if declared != null:
        return Option[span[str]].some(value = variant_type_param_names(unsafe: read(declared)))
    return Option[span[str]].none

## When the receiver is a `let`-bound value and the method is `editable`, flag the
## call.  `ref` (borrow) and `var` (mutable) receivers are fine.
## A receiver of an `editable` method call: the binding's name and the call's
## line, so a linter can treat the binding as mutated.
public struct EditableSite:
    name: str
    line: ptr_uint
    column: ptr_uint


## The host's `assignable_receiver?`: `infer_lvalue_receiver` with ref and
## pointer identifiers allowed and a mutable pointer required.  A `ref[T]` or a
## mutable raw pointer is assignable; a `const_ptr` is not; otherwise the
## binding must be mutable (not a `let`/parameter/`this` in a non-editable
## method).
function editable_receiver_assignable(scope: ref[sscope.Scope], name: str) -> bool:
    let type_ptr = scope_get(scope, name)
    if type_ptr == null:
        return true
    var declared: types.Type
    unsafe:
        declared = read(type_ptr)
    let ty = if types.is_nullable_type(declared): types.unwrap_nullable(declared) else: declared
    if types.is_ref_type(ty) or is_generic_type_named(ty, "ref"):
        return true
    if is_generic_type_named(ty, "ptr") or is_generic_type_named(ty, "own"):
        return true
    if is_generic_type_named(ty, "const_ptr"):
        return false
    return not scope_is_let(scope, name)


public function check_editable_receiver_immutable(
    ctx: ref[Context],
    scope: ref[sscope.Scope],
    receiver_expr: ptr[ast.Expr],
    receiver_type: types.Type,
    method_name: str,
    line: ptr_uint,
    column: ptr_uint
) -> void:
    match resolve_method_sig(ctx, receiver_type, method_name):
        Option.some as sig:
            match sig.value.method_kind:
                ast.MethodKind.mk_editable:
                    # The host records the receiver *expression*; its linter then
                    # walks member/index receivers to the root binding
                    # (`mark_mutated`), so `datagram.data.release()` marks
                    # `datagram`.  Record the root identifier's site for that walk.
                    match editable_receiver_root(receiver_expr):
                        Option.some as root:
                            ctx.editable_receiver_sites.push(EditableSite(
                                name = root.value.name,
                                line = root.value.line,
                                column = root.value.column
                            ))
                            if not editable_receiver_assignable(scope, root.value.name):
                                report(ctx, line, column, editable_on_immutable_message(root.value.name, method_name))
                        Option.none:
                            pass
                _:
                    pass
        Option.none:
            pass

struct ReceiverRoot:
    name: str
    line: ptr_uint
    column: ptr_uint


## The root identifier of a receiver expression, through member and index
## accesses only.  A call receiver (`read(x).field.release()`) stops the walk:
## the host's `mark_mutated` never enters a call, and `infer_lvalue_receiver`
## accepts a `read` receiver without a mutability check.
function editable_receiver_root(receiver_expr: ptr[ast.Expr]) -> Option[ReceiverRoot]:
    unsafe:
        match read(receiver_expr):
            ast.Expr.expr_identifier as id:
                return Option[ReceiverRoot].some(value = ReceiverRoot(
                    name = id.name,
                    line = id.line,
                    column = id.column
                ))
            ast.Expr.expr_member_access as ma:
                return editable_receiver_root(ma.receiver)
            ast.Expr.expr_index_access as ix:
                return editable_receiver_root(ix.receiver)
            _:
                pass
    return Option[ReceiverRoot].none


## The signature of `method_name` on a receiver of struct type, whether the type
## is local (ctx.method_sigs) or imported (the module's binding).  None for any
## other receiver type or an unknown method.
public function resolve_method_sig(ctx: ref[Context], receiver: types.Type, method_name: str) -> Option[FnSig]:
    match receiver:
        types.Type.ty_named as n:
            let n_np = unsafe: read(n.payload)
            let sig_ptr = ctx.method_sigs.get(method_key(n_np.name, method_name))
            if sig_ptr != null:
                return Option[FnSig].some(value = unsafe: read(sig_ptr))
            if n_np.module_name.len > 0:
                let bp = find_binding(ctx, n_np.module_name)
                if bp != null:
                    let bound = unsafe: read(bp).method_sigs.get(method_key(n_np.name, method_name))
                    if bound != null:
                        return Option[FnSig].some(value = unsafe: read(bound))
            # A prelude type's methods live in the seeded modules, not in the
            # current one (`Option[int].unwrap()`).
            let prelude_sig = ctx.prelude_method_sigs.get(method_key(n_np.name, method_name))
            if prelude_sig != null:
                return Option[FnSig].some(value = unsafe: read(prelude_sig))
            # A raw or re-exported struct resolves its methods wherever they are
            # declared (`extending Bitset:` lives in std.bitset, while the value's
            # type may arrive as a bare name from an imported signature): the
            # editable check needs the kind, so the search must not stop at the
            # current module.
            return find_method_anywhere(ctx, n_np.name, method_name)
        types.Type.ty_imported as im:
            let im_bp = unsafe: read(im.payload)
            let bp = find_binding(ctx, im_bp.module_name)
            if bp != null:
                let sp = unsafe: read(bp).method_sigs.get(method_key(im_bp.name, method_name))
                if sp != null:
                    return Option[FnSig].some(value = unsafe: read(sp))
            let sp = ctx.method_sigs.get(method_key(im_bp.name, method_name))
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
            return find_method_anywhere(ctx, "str", method_name)
        types.Type.ty_primitive as p:
            return find_method_anywhere(ctx, p.name, method_name)
        # str_buffer[N], atomic[T] and ptr[T] builtin methods.
        types.Type.ty_generic as g:
            let g_bp = unsafe: read(g.payload)
            if g_bp.name == "str_buffer":
                return str_buffer_method_sig(g_bp.args, method_name)
            if g_bp.name == "atomic":
                return atomic_method_sig(g_bp.args, method_name)
            if g_bp.name == "ptr":
                return ptr_method_sig(g_bp.args, method_name)
            let sig_ptr = ctx.method_sigs.get(method_key(g_bp.name, method_name))
            if sig_ptr != null:
                return Option[FnSig].some(value = unsafe: read(sig_ptr))
            let prelude_ptr = ctx.prelude_method_sigs.get(method_key(g_bp.name, method_name))
            if prelude_ptr != null:
                return Option[FnSig].some(value = unsafe: read(prelude_ptr))
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
    # `clear`/`assign`/`append`/`assign_format`/`append_format` mutate the
    # receiver (the host's `check_str_buffer_method_call` records them as
    # editable receivers); the readable methods do not.
    var kind = ast.MethodKind.mk_plain
    if method_name == "clear":
        kind = ast.MethodKind.mk_editable
    else if (
        method_name == "assign"
        or method_name == "append"
        or method_name == "assign_format"
        or method_name == "append_format"
    ):
        params.push(ParamEntry(name = "text", ty = str_ty))
        kind = ast.MethodKind.mk_editable
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
        method_kind = kind,
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
    else if method_name == "compare_exchange":
        params.push(ParamEntry(
            name = "expected",
            ty = types.generic_type(name = "ref", args = alloc_one_type_arg(elem_ty))
        ))
        params.push(ParamEntry(name = "desired", ty = elem_ty))
        return_type = types.primitive("bool")
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


## Synthetic FnSig for a builtin `ptr[T]` method: the API std.mem.ptr declares
## through `extending ptr[T]:`, with the receiver's element type standing in for
## the block's `T`.  Only the known methods are recognized.
function ptr_method_sig(args: span[types.Type], method_name: str) -> Option[FnSig]:
    if args.len != 1:
        return Option[FnSig].none
    let elem_ty = unsafe: read(args.data + 0)
    let offset_ty = types.primitive("ptr_uint")
    var params = vec.Vec[ParamEntry].create()
    var return_type = types.primitive("void")
    if method_name == "load":
        return_type = elem_ty
    else if method_name == "store":
        params.push(ParamEntry(name = "value", ty = elem_ty))
    else if method_name == "load_at":
        params.push(ParamEntry(name = "offset", ty = offset_ty))
        return_type = elem_ty
    else if method_name == "store_at":
        params.push(ParamEntry(name = "offset", ty = offset_ty))
        params.push(ParamEntry(name = "value", ty = elem_ty))
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


## Resolve `Type.method` by searching the local method table, then every
## reachable imported binding.  Underpins method calls on str and primitive
## receivers, whose methods live in whichever module extended the type (e.g.
## `str` methods in std.str).  Missing -> none (permissive; not flagged).
function find_method_anywhere(ctx: ref[Context], type_name: str, method_name: str) -> Option[FnSig]:
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
                            let result = build_fn_sig(
                                ctx,
                                m.value.name,
                                m.value.method_params,
                                m.value.return_type,
                                m.value.method_kind,
                                false
                            )
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
function interface_method_in_map(
    ctx: ref[Context],
    ifaces: map_mod.Map[str, span[ast.InterfaceMethod]],
    method_name: str
) -> Option[FnSig]:
    var keys = ifaces.keys()
    while true:
        let key_ptr = keys.next() else:
            break
        let methods_ptr = ifaces.get(unsafe: read(key_ptr)) else:
            continue
        match interface_method_named(unsafe: read(methods_ptr), method_name):
            Option.some as m:
                enter_suppressed_interface_method(ctx, m.value)
                let result = build_fn_sig(
                    ctx,
                    m.value.name,
                    m.value.method_params,
                    m.value.return_type,
                    m.value.method_kind,
                    false
                )
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
        let binding_ptr = find_binding(ctx, unsafe: read(module_name_ptr)) else:
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
## A re-exported type alias follows its resolved target, exactly as
## `resolve_imported_type` does for a type reference (`rl.Rectangle` names the
## raw binding's struct, not the alias).
function try_imported_type(
    ctx: ref[Context],
    scope: ref[sscope.Scope],
    receiver: ptr[ast.Expr],
    member: str
) -> Option[types.Type]:
    unsafe:
        match read(receiver):
            ast.Expr.expr_identifier as id:
                if scope_get(scope, id.name) != null:
                    return Option[types.Type].none
                let module_name_ptr = ctx.import_aliases.get(id.name) else:
                    return Option[types.Type].none
                let binding_ptr = find_binding(ctx, read(module_name_ptr)) else:
                    return Option[types.Type].none
                let binding = read(binding_ptr)
                let alias_type = binding.type_alias_types.get(member)
                if alias_type != null:
                    return Option[types.Type].some(value = read(ptr[types.Type]<-alias_type))
                if (
                    binding.structs.contains(member)
                    or binding.type_aliases.contains(member)
                    or binding.static_member_types.contains(member)
                    or binding.interfaces.contains(member)
                    or binding.types.contains(member)
                ):
                    return Option[types.Type].some(value = types.imported_type(
                        module_name = read(module_name_ptr),
                        name = member,
                        args = span[types.Type]()
                    ))
                return Option[types.Type].none
            _:
                return Option[types.Type].none


## Resolve `alias.Type[args]` in expression position to the instantiated
## imported type (none when it is not an imported type).
public function specialization_imported_receiver(
    ctx: ref[Context],
    scope: ref[sscope.Scope],
    receiver: ptr[ast.Expr]
) -> Option[types.Type]:
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
                                let binding_ptr = find_binding(ctx, read(module_name_ptr)) else:
                                    return Option[types.Type].none
                                if (
                                    not read(binding_ptr).structs.contains(ma.member_name)
                                    and not read(binding_ptr).types.contains(ma.member_name)
                                ):
                                    return Option[types.Type].none
                                return Option[types.Type].some(value = types.imported_type(
                                    module_name = read(module_name_ptr),
                                    name = ma.member_name,
                                    args = resolve_type_arguments(ctx, spec.arguments)
                                ))
                            _:
                                return Option[types.Type].none
                    _:
                        return Option[types.Type].none
            _:
                return Option[types.Type].none


## The module that declares a type name, for rendering an instance of it
## (`*From <module>*`): the prelude types Option/Result are owned by their real
## std modules, everything else by the module being analyzed.
function type_owner_module(ctx: ref[Context], name: str) -> str:
    if name == "Option":
        return "std.option"
    if name == "Result":
        return "std.result"
    return ctx.module_name


## A receiver that is a specialization of a locally-known type —
## `Result[int, int].success(value = 7)`, `Option[float].none`,
## `Pair[A, B](…)` — denotes an instance of that type.  Returns the instance
## type (module-qualified, type arguments included); none for any other
## receiver.  Imported receivers are handled by `specialization_imported_receiver`.
public function type_instance_receiver(
    ctx: ref[Context],
    scope: ref[sscope.Scope],
    receiver: ptr[ast.Expr]
) -> Option[types.Type]:
    unsafe:
        match read(receiver):
            ast.Expr.expr_specialization as spec:
                match read(spec.callee):
                    ast.Expr.expr_identifier as id:
                        if scope_get(scope, id.name) != null:
                            return Option[types.Type].none
                        if not ctx.structs.contains(id.name) and not ctx.static_member_types.contains(id.name):
                            return Option[types.Type].none
                        return Option[types.Type].some(value = types.imported_type(
                            module_name = type_owner_module(ctx, id.name),
                            name = id.name,
                            args = resolve_type_arguments(ctx, spec.arguments)
                        ))
                    _:
                        return Option[types.Type].none
            _:
                return Option[types.Type].none


## A receiver identifier naming an event declared in this module
## (`ready.subscribe(...)`).
public function event_value_receiver(ctx: ref[Context], scope: ref[sscope.Scope], receiver: ptr[ast.Expr]) -> Option[str]:
    unsafe:
        match read(receiver):
            ast.Expr.expr_identifier as id:
                if scope_get(scope, id.name) != null:
                    return Option[str].none
                if ctx.event_types.contains(id.name):
                    return Option[str].some(value = id.name)
                return Option[str].none
            _:
                return Option[str].none


## The builtin event method result types (the host's
## `check_event_method_call`): `subscribe`/`subscribe_once` yield
## `Result[Subscription, EventError]`, `unsubscribe` a `bool`, `emit` `void`,
## and `wait` a `Task[Result[payload|void, EventError]]` — the payload is the
## event's declared type, so `await event.wait()` is the matchable `Result`.
public function event_method_call_type(ctx: ref[Context], method_name: str, event_name: str) -> types.Type:
    if method_name == "subscribe" or method_name == "subscribe_once":
        var results = vec.Vec[types.Type].create()
        results.push(types.named_type(name = "Subscription", module_name = "", linkage_name = Option[str].none))
        results.push(types.named_type(name = "EventError", module_name = "", linkage_name = Option[str].none))
        return types.generic_type(name = "Result", args = results.as_span())
    if method_name == "unsubscribe":
        return types.primitive("bool")
    if method_name == "wait":
        var payload_ty = types.primitive("void")
        let info_ptr = ctx.event_types.get(event_name)
        if info_ptr != null:
            unsafe:
                let info = read(info_ptr)
                let pt = info.payload_type
                if pt != null:
                    payload_ty = resolve_type(ctx, pt)
        var results = vec.Vec[types.Type].create()
        results.push(payload_ty)
        results.push(types.named_type(name = "EventError", module_name = "", linkage_name = Option[str].none))
        var result_ty = types.generic_type(name = "Result", args = results.as_span())
        var task_args = vec.Vec[types.Type].create()
        task_args.push(result_ty)
        return types.generic_type(name = "Task", args = task_args.as_span())
    return types.primitive("void")


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


## Type-argument substitution for an instantiated *local* generic type from the
## current module's declared type parameters (`Pair[int, float](…)` -> `{A:
## int, B: float}`).  Empty when the name declares no type parameters.
function local_type_substitution(
    ctx: ref[Context],
    type_name: str,
    args: span[types.Type]
) -> map_mod.Map[str, types.Type]:
    var subs = map_mod.Map[str, types.Type].create()
    let params_ptr = ctx.type_param_names.get(type_name) else:
        return subs
    let params = unsafe: read(params_ptr)
    var i: ptr_uint = 0
    while i < params.len and i < args.len:
        unsafe:
            subs.set(read(params.data + i).name, read(args.data + i))
        i += 1
    return subs


## Substitute an instantiated type's arguments into the declaring binding's
## recorded parameter names.
function imported_type_substitution(
    ctx: ref[Context],
    binding_ptr: ptr[ModuleBinding]?,
    type_name: str,
    args: span[types.Type]
) -> map_mod.Map[str, types.Type]:
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
    # Deterministic pick (smallest module name), like `find_method_anywhere`:
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
function imported_method_signature(
    ctx: ref[Context],
    own: ptr[ModuleBinding]?,
    type_name: str,
    member: str
) -> ptr[FnSig]?:
    let key = method_key(type_name, member)
    if own != null:
        let own_sig = unsafe: read(own).method_sigs.get(key)
        if own_sig != null:
            return own_sig
    let bindings = ctx.imported_modules else:
        return null
    # Deterministic pick (smallest module name) for the same reason as
    # `find_method_anywhere`.
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
public function imported_method_call_type(
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
            let imported_bp = unsafe: read(imported.payload)
            let own = find_binding(ctx, imported_bp.module_name)
            let sig_ptr = imported_method_signature(ctx, own, imported_bp.name, member) else:
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
            let named_np = unsafe: read(named.payload)
            let own = if named_np.module_name.len > 0: find_binding(ctx, named_np.module_name) else: null
            let sig_ptr = imported_method_signature(ctx, own, named_np.name, member) else:
                return Option[types.Type].none
            let sig = unsafe: read(sig_ptr)
            if not sig.has_return_type:
                return Option[types.Type].some(value = types.primitive("void"))
            return Option[types.Type].some(value = sig.return_type)
        _:
            pass
    match recv:
        types.Type.ty_imported as imported:
            let imported_bp = unsafe: read(imported.payload)
            let own = find_binding(ctx, imported_bp.module_name)
            let sig_ptr = imported_method_signature(ctx, own, imported_bp.name, member) else:
                return Option[types.Type].none

            var subs = imported_type_substitution(
                ctx,
                binding_declaring_type(ctx, own, imported_bp.name),
                imported_bp.name,
                imported_bp.args,
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
function resolve_member_access(
    ctx: ref[Context],
    scope: ref[sscope.Scope],
    receiver: ptr[ast.Expr],
    member: str,
    is_method_call: bool,
    line: ptr_uint,
    column: ptr_uint
) -> types.Type:
    if member.len == 0:
        # An incomplete dot access (`read(p).`): the parser recovered with an
        # empty member name.  Record the receiver's type at the dot for the
        # LSP completion fallback and suppress the member check.
        let recv_ty = infer_expr(ctx, scope, receiver)
        if ctx.tooling_facts and not receiver_is_text_chain(receiver):
            ctx.member_receiver_types.set(binding_key(line, column), recv_ty)
        return types.Type.ty_error
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
    # A specialization of a locally-known variant/enum/flags type reads one of
    # the type's own members (`Option[float].none`); the value is the instance
    # itself.  A struct's member read falls through to the normal paths.
    match type_instance_receiver(ctx, scope, receiver):
        Option.some as instance:
            match instance.value:
                types.Type.ty_imported as im:
                    let im_bp = unsafe: read(im.payload)
                    if ctx.static_member_types.contains(im_bp.name):
                        check_static_member(ctx, im_bp.name, member, line, column)
                        return instance.value
                _:
                    pass
        Option.none:
            pass
    match try_imported_member(ctx, scope, receiver, member):
        Option.some as imported_value:
            return imported_value.value
        Option.none:
            match member_calls.imported_static_member(ctx, scope, receiver, member, line, column):
                Option.some as imported_static:
                    return imported_static.value
                Option.none:
                    match member_calls.static_type_receiver(ctx, scope, receiver):
                        Option.some as tn:
                            check_static_member(ctx, tn.value, member, line, column)
                            return types.named_type(
                                name = tn.value,
                                module_name = ctx.module_name,
                                linkage_name = Option[str].none
                            )
                        Option.none:
                            match try_imported_type(ctx, scope, receiver, member):
                                Option.some as imported_type:
                                    return imported_type.value
                                Option.none:
                                    let raw_recv = infer_expr(ctx, scope, receiver)
                                    # Keep the LSP's fallback fact: a receiver that
                                    # is not a plain name/field chain (`read(p)`,
                                    # `make()`, `a[0]`) cannot be resolved from the
                                    # source text, so record its inferred type at the
                                    # member's position.
                                    if ctx.tooling_facts and not receiver_is_text_chain(receiver):
                                        ctx.member_receiver_types.set(binding_key(line, column), raw_recv)
                                    # A field read through a raw pointer dereferences
                                    # it — the host requires unsafe
                                    # (`raw pointer dereference requires unsafe`).
                                    # `own`/`ref` receivers auto-deref without.
                                    if (
                                        types.is_raw_pointer(raw_recv)
                                        and not is_method_call
                                        and not in_generic_body(ctx)
                                    ):
                                        if ctx.unsafe_depth == 0:
                                            report(ctx, line, column, "raw pointer dereference requires unsafe")
                                        else:
                                            mark_required_unsafe(ctx)
                                    let recv = project_pointer_receiver(raw_recv)
                                    return member_calls.check_member(ctx, recv, member, is_method_call, line, column)


## True when a member access's receiver expression is a plain identifier or a
## field chain rooted at one — the shape the LSP resolves from source text
## (`ctx.cache.get`).  Every other receiver (a call, an index, a cast, a
## dereference) is recorded in `member_receiver_types` for the LSP fallback.
public function receiver_is_text_chain(ep: ptr[ast.Expr]) -> bool:
    unsafe:
        match read(ep):
            ast.Expr.expr_identifier:
                return true
            ast.Expr.expr_member_access as ma:
                return receiver_is_text_chain(ma.receiver)
            _:
                return false


public function binding_has_member(binding: ModuleBinding, type_name: str, member: str) -> bool:
    return binding.member_keys.contains(method_key(type_name, member))


public function check_static_member(ctx: ref[Context], type_name: str, member: str, line: ptr_uint, column: ptr_uint) -> void:
    if has_method(ctx, type_name, member):
        return
    report(ctx, line, column, unknown_member_message("member", type_name, member))


## When `callee` is a bare identifier naming a locally-declared struct or a
## builtin vec/mat/quat type (not shadowed by a local value), validate each
## named-field argument and return the constructed type.  Returns none for
## ordinary function calls.
function try_construction(
    ctx: ref[Context],
    scope: ref[sscope.Scope],
    callee: ptr[ast.Expr],
    args: span[ast.Argument]
) -> Option[types.Type]:
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
                return Option[types.Type].some(value = types.named_type(
                    name = id.name,
                    module_name = "",
                    linkage_name = Option[str].none
                ))
            _:
                return Option[types.Type].none


function check_construction(
    ctx: ref[Context],
    scope: ref[sscope.Scope],
    struct_name: str,
    fields: span[FieldEntry],
    args: span[ast.Argument],
    line: ptr_uint,
    column: ptr_uint
) -> void:
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
                    let field_ty = unsafe: read(ft)
                    let saved_hint = ctx.expected_type_hint
                    ctx.expected_type_hint = field_ty
                    let vt = infer_expr(ctx, scope, arg.arg_value)
                    ctx.expected_type_hint = saved_hint
                    if incompatible_value_with_consts(ctx, field_ty, vt, arg.arg_value, ref_of(ctx.const_values)):
                        report(ctx, line, column, field_type_mismatch_message(struct_name, nm.value, field_ty, vt))
            _:
                pass
        i += 1
    seen.release()


public function field_type(fields: span[FieldEntry], name: str) -> ptr[types.Type]?:
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


## The value a member access yields when it is called: a function-typed field
## (`node.condition_fn(...)`) returns its declared return type, not the
## function type itself.  The host resolves callable values through
## `check_callable_value_call`; the self's field-call arm needs the same.
public function member_call_result_type(field_ty: types.Type, is_method_call: bool) -> types.Type:
    if not is_method_call:
        return field_ty
    match field_ty:
        types.Type.ty_function as fn_ty:
            let fn_ty_ft = unsafe: read(fn_ty.payload)
            return unsafe: read(fn_ty_ft.return_type)
        _:
            return field_ty


public function check_named_member(
    ctx: ref[Context],
    module_name: str,
    name: str,
    member: str,
    is_method_call: bool,
    line: ptr_uint,
    column: ptr_uint
) -> types.Type:
    # A struct declared in another module reaches the analyzer as a
    # `ty_named` with that module's name (an exported field's type);
    # resolve its members through the module binding, as `ty_imported`
    # does, instead of looking the name up locally.  Anything the
    # binding does not declare as a struct/union (an enum, an opaque
    # type) keeps the permissive error path below.
    if module_name.len > 0 and not module_name.equal(ctx.module_name) and binding_has_struct_type(
        ctx,
        module_name,
        name
    ):
        return check_imported_member(ctx, module_name, name, member, is_method_call, line, column)
    let fieldsp = ctx.structs.get(name)
    if fieldsp == null:
        # A union member is read like a struct field.
        let unionp = ctx.unions.get(name)
        if unionp != null:
            unsafe:
                let ufields = read(unionp)
                var ui: ptr_uint = 0
                while ui < ufields.len:
                    let ufe = read(ufields.data + ui)
                    if ufe.name == member:
                        return member_call_result_type(ufe.ty, is_method_call)
                    ui += 1
        # Not a locally-declared struct (enum/variant/opaque/imported).
        return types.Type.ty_error
    unsafe:
        let fields = read(fieldsp)
        var i: ptr_uint = 0
        while i < fields.len:
            let fe = read(fields.data + i)
            if fe.name == member:
                return member_call_result_type(fe.ty, is_method_call)
            i += 1
    if member == "with" or has_method(ctx, name, member):
        return types.Type.ty_error
    if is_method_call:
        report(ctx, line, column, unknown_member_message("method", name, member))
    else:
        report(ctx, line, column, unknown_member_message("field", name, member))
    return types.Type.ty_error


public function check_imported_receiver_member(
    ctx: ref[Context],
    module_name: str,
    name: str,
    args: span[types.Type],
    member: str,
    is_method_call: bool,
    line: ptr_uint,
    column: ptr_uint
) -> types.Type:
    # An instantiated *local* generic struct (`Pair[int, float](…)`)
    # carries the current module's name; its fields read from the local
    # struct table with the instance's arguments substituted, exactly as
    # a bare `Pair` receiver would (`check_member`'s ty_named arm).
    if module_name.equal(ctx.module_name) or module_name.len == 0:
        let local_fields_ptr = ctx.structs.get(name)
        if local_fields_ptr != null:
            var subs = local_type_substitution(ctx, name, args)
            defer: subs.release()
            let fields = unsafe: read(local_fields_ptr)
            var i: ptr_uint = 0
            while i < fields.len:
                let fe = unsafe: read(fields.data + i)
                if fe.name == member:
                    return member_call_result_type(substitute_type(fe.ty, ref_of(subs)), is_method_call)
                i += 1
            return types.Type.ty_error
    return check_imported_member_args(ctx, module_name, name, member, args, is_method_call, line, column)


public function check_primitive_member(name: str, member: str) -> types.Type:
    # The host's `Types::Vector`/`Matrix`/`Quaternion` field maps:
    # vectors and quaternions expose `x`/`y`/`z`/`w` (the vector's
    # width is its name suffix), and a matrix exposes `col0..colN-1` as
    # the matching `vecN`.  `ivec*` lanes are `int`; everything else is
    # `float`.
    if is_vec_math_name(name):
        let is_int = name.starts_with("ivec")
        let lane_ty = if is_int: types.primitive("int") else: types.primitive("float")
        if name == "mat3":
            if member == "col0" or member == "col1" or member == "col2":
                return types.primitive("vec3")
            return types.Type.ty_error
        if name == "mat4":
            if member == "col0" or member == "col1" or member == "col2" or member == "col3":
                return types.primitive("vec4")
            return types.Type.ty_error
        var width = 4
        if name == "vec2" or name == "ivec2":
            width = 2
        else if name == "vec3" or name == "ivec3":
            width = 3
        if member == "x":
            return lane_ty
        if width >= 2 and member == "y":
            return lane_ty
        if width >= 3 and member == "z":
            return lane_ty
        if width >= 4 and member == "w":
            return lane_ty
        return types.Type.ty_error
    # A non-vector primitive member keeps the permissive path.
    return types.Type.ty_error


public function check_generic_member(
    ctx: ref[Context],
    name: str,
    args: span[types.Type],
    member: str,
    is_method_call: bool,
    line: ptr_uint,
    column: ptr_uint
) -> types.Type:
    if name == "Task" and args.len >= 1:
        # The host's `Types::Task#fields` (`types.rb:590-632`): `frame`
        # is `ptr[void]`, `ready`/`release`/`take_result`/`cancel` are
        # `fn(frame) -> …`, and `set_waiter` takes the waiter callback.
        if member.equal("frame"):
            return task_frame_field_type()
        if member.equal("ready"):
            return task_ready_field_type()
        if member.equal("set_waiter"):
            return task_set_waiter_field_type()
        if member.equal("release") or member.equal("cancel"):
            return task_void_field_type()
        if member.equal("take_result"):
            return task_take_result_field_type(unsafe: read(args.data + 0))
        return types.Type.ty_error
    if name == "span":
        # The host's `Span#fields`: the element pointer and the length.
        if member == "data" and args.len >= 1:
            return types.generic_type(name = "ptr", args = alloc_one_type_arg(unsafe: read(args.data + 0)))
        if member == "len":
            return types.primitive("ptr_uint")
    if name == "ptr":
        if has_method(ctx, name, member):
            return types.Type.ty_error
        return types.Type.ty_error
    if name == "array":
        if member == "as_span":
            return types.Type.ty_error
    if name == "span" or name == "array" or name == "ptr":
        return types.Type.ty_error
    if has_method(ctx, name, member):
        return types.Type.ty_error
    if is_method_call:
        report(ctx, line, column, unknown_member_message("method", name, member))
    else:
        report(ctx, line, column, unknown_member_message("field", name, member))
    return types.Type.ty_error


## `_0`/`_1`/… -> the tuple element index, -1 for any other name.
public function positional_tuple_index(member: str) -> int:
    if member.len < 2 or member.byte_at(0) != '_':
        return -1
    var index: int = 0
    var i: ptr_uint = 1
    while i < member.len:
        let b = member.byte_at(i)
        if b < '0' or b > '9':
            return -1
        index = index * 10 + int<-(b - '0')
        i += 1
    return index


## Member access on a value of type variable `T`.  A `T` value's only members are
## the methods of its `implements` constraints.  When every constraint interface
## resolves, a member not declared by any of them is reported; if a constraint is
## unresolvable, or `T` is unconstrained, access stays permissive.
public function check_type_var_member(
    ctx: ref[Context],
    var_name: str,
    member: str,
    is_method_call: bool,
    line: ptr_uint,
    column: ptr_uint
) -> types.Type:
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
function check_imported_member(
    ctx: ref[Context],
    module_name: str,
    type_name: str,
    member: str,
    is_method_call: bool,
    line: ptr_uint,
    column: ptr_uint
) -> types.Type:
    return check_imported_member_args(
        ctx,
        module_name,
        type_name,
        member,
        span[types.Type](),
        is_method_call,
        line,
        column
    )


function check_imported_member_args(
    ctx: ref[Context],
    module_name: str,
    type_name: str,
    member: str,
    args: span[types.Type],
    is_method_call: bool,
    line: ptr_uint,
    column: ptr_uint
) -> types.Type:
    return member_calls.check_imported_member_depth(ctx, module_name, type_name, member, args, is_method_call, line, column, 0)


## True when the module binding declares `type_name` as a struct or union,
## public or private.  `check_member` uses it to route a foreign `ty_named`
## through the binding only for types whose fields the binding actually owns.
function binding_has_struct_type(ctx: ref[Context], module_name: str, type_name: str) -> bool:
    let binding_ptr = find_binding(ctx, module_name) else:
        return false
    let binding = unsafe: read(binding_ptr)
    return (
        binding.structs.contains(type_name) or binding.unions.contains(type_name)
        or binding.private_structs.contains(type_name) or binding.private_unions.contains(type_name)
    )


## A field's type with an instantiated imported generic's arguments substituted
## (`RemovedEntry[K, V].value` -> the receiver's `V`).  The exported field types
## carry the declaring type's parameters as `ty_var`, so an unsubstituted read
## (`entry.value` -> `V`) would leave the member unresolved.
public function substituted_field_type(
    binding: ModuleBinding,
    type_name: str,
    args: span[types.Type],
    field_ty: types.Type
) -> types.Type:
    if args.len == 0:
        return field_ty
    let params_ptr = binding.type_param_names.get(type_name) else:
        return field_ty
    let params = unsafe: read(params_ptr)
    var subs = map_mod.Map[str, types.Type].create()
    defer: subs.release()
    var i: ptr_uint = 0
    while i < params.len and i < args.len:
        unsafe:
            subs.set(read(params.data + i).name, read(args.data + i))
        i += 1
    return substitute_type(field_ty, ref_of(subs))


## When `type_name` is a type alias in the binding, resolve it to its source
## module and type name.  Returns `(source_module, source_type)` or `none` when
## the type is not a resolvable alias or is not imported from another module.
struct AliasSource:
    module_name: str
    type_name: str


public function follow_type_alias(ctx: ref[Context], binding_ptr: ptr[ModuleBinding], type_name: str) -> Option[AliasSource]:
    unsafe:
        let resolved_ptr = read(binding_ptr).type_alias_types.get(type_name) else:
            return Option[AliasSource].none
        match read(resolved_ptr):
            types.Type.ty_imported as im:
                let im_bp = unsafe: read(im.payload)
                if im_bp.module_name == "":
                    return Option[AliasSource].none
                return Option[AliasSource].some(value = AliasSource(
                    module_name = im_bp.module_name,
                    type_name = im_bp.name
                ))
            _:
                return Option[AliasSource].none


## Return the result type of a known builtin call (read, ptr_of, const_ptr_of,
## size_of, align_of).  Returns `none` for anything else, so the call falls
## through to regular function/method dispatch.  `read(ptr)` and `ptr_of(x)` are
## side-effectful: they report an unsafe-context requirement when applicable.
function try_builtin_call(
    ctx: ref[Context],
    scope: ref[sscope.Scope],
    callee_name: str,
    args: span[ast.Argument],
    line: ptr_uint,
    column: ptr_uint
) -> Option[types.Type]:
    if callee_name == "read":
        if args.len != 1:
            report(ctx, line, column, diag.read_arity_message(args.len))
            return Option[types.Type].some(value = types.Type.ty_error)
        var arg: ast.Argument = unsafe: read(args.data + 0)
        let at = infer_expr(ctx, scope, arg.arg_value)
        # An unresolved operand is the recovery path; do not cascade a second
        # diagnostic on top of the one that produced it.
        if types.contains_error(at):
            return Option[types.Type].some(value = types.Type.ty_error)
        # The host's `infer_reference_value_type`: a `ref` reads its referent; a
        # raw pointer dereferences and requires unsafe, while an `own[T]`
        # auto-dereferences (no requirement).  A nullable pointer is not a read
        # source — the host rejects it instead of silently unwrapping it.
        if types.is_ref_type(at):
            return Option[types.Type].some(value = types.pointer_element(at))
        if types.is_pointer_type(at) and not types.is_nullable_type(at):
            if not types.is_own_type(at) and not in_generic_body(ctx):
                if ctx.unsafe_depth == 0:
                    report(ctx, line, column, "raw pointer dereference requires unsafe")
                else:
                    mark_required_unsafe(ctx)
            return Option[types.Type].some(value = types.pointer_element(at))
        report(ctx, line, column, diag.read_operand_message(at))
        return Option[types.Type].some(value = types.Type.ty_error)
    if callee_name == "ptr_of" or callee_name == "const_ptr_of" or callee_name == "ref_of":
        if args.len != 1:
            return Option[types.Type].none
        var arg: ast.Argument = unsafe: read(args.data + 0)
        var at = infer_expr(ctx, scope, arg.arg_value)
        # `ptr_of` over a borrow yields the pointee's pointer, not a pointer to
        # the borrow (`ptr_of(ref_of(x))` is `ptr[T]`, the host's
        # `check_ptr_of_call`).
        if callee_name == "ptr_of":
            at = unwrap_ref(at)
        let kind = if callee_name == "ptr_of": "ptr" else: if callee_name == "ref_of": "ref" else: "const_ptr"
        return Option[types.Type].some(value = types.generic_type(
            name = string.String.from_str(kind).as_str(),
            args = alloc_one_type_arg(at)
        ))
    if callee_name == "size_of" or callee_name == "align_of":
        if args.len != 1:
            return Option[types.Type].none
        return Option[types.Type].some(value = types.primitive("ptr_uint"))
    if callee_name == "get":
        if args.len != 2:
            return Option[types.Type].none
        var source_arg: ast.Argument = unsafe: read(args.data + 0)
        let source_ty = infer_expr(ctx, scope, source_arg.arg_value)
        let _index_ty = infer_expr(ctx, scope, unsafe: read(args.data + 1).arg_value)
        let element = types.pointer_element(source_ty)
        if types.is_error(element):
            return Option[types.Type].none
        # The host's `check_get_call`: a nullable raw pointer to the element.
        return Option[types.Type].some(value = types.Type.ty_nullable(
            base = types.alloc_type(types.generic_type(name = "ptr", args = alloc_one_type_arg(element)))
        ))
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
        if incompatible_value_with_consts(ctx,
            left_ty,
            right_ty,
            unsafe: read(args.data + 1).arg_value,
            ref_of(ctx.const_values)
        ) and incompatible_value_with_consts(ctx,
            right_ty,
            left_ty,
            unsafe: read(args.data + 0).arg_value,
            ref_of(ctx.const_values)
        ):
            var cmp_msg = string.String.from_str(callee_name)
            cmp_msg.append(" operands are not comparable")
            report(ctx, line, column, cmp_msg.as_str())
        if args.len == 3:
            let _msg_ty = infer_expr(ctx, scope, unsafe: read(args.data + 2).arg_value)
        return Option[types.Type].some(value = types.primitive("void"))
    return Option[types.Type].none


public function alloc_one_type_arg(ty: types.Type) -> span[types.Type]:
    var v = vec.Vec[types.Type].create()
    v.push(ty)
    return v.as_span()


## The host's `Types::Task` field types (`types.rb:590-632`).
function task_frame_field_type() -> types.Type:
    return types.generic_type(name = "ptr", args = alloc_one_type_arg(types.primitive("void")))


function task_ready_field_type() -> types.Type:
    var params = vec.Vec[types.Type].create()
    params.push(task_frame_field_type())
    var names = vec.Vec[str].create()
    names.push("frame")
    return types.function_type(
        name = "",
        params = params.as_span(),
        return_type = types.alloc_type(types.primitive("bool")),
        variadic = false,
        is_proc = false,
        param_names = names.as_span()
    )


function task_void_field_type() -> types.Type:
    var params = vec.Vec[types.Type].create()
    params.push(task_frame_field_type())
    var names = vec.Vec[str].create()
    names.push("frame")
    return types.function_type(
        name = "",
        params = params.as_span(),
        return_type = types.alloc_type(types.primitive("void")),
        variadic = false,
        is_proc = false,
        param_names = names.as_span()
    )


function task_take_result_field_type(result_ty: types.Type) -> types.Type:
    var params = vec.Vec[types.Type].create()
    params.push(task_frame_field_type())
    var names = vec.Vec[str].create()
    names.push("frame")
    return types.function_type(
        name = "",
        params = params.as_span(),
        return_type = types.alloc_type(result_ty),
        variadic = false,
        is_proc = false,
        param_names = names.as_span()
    )


function task_set_waiter_field_type() -> types.Type:
    var params = vec.Vec[types.Type].create()
    params.push(task_frame_field_type())
    params.push(task_frame_field_type())
    params.push(task_void_field_type())
    var names = vec.Vec[str].create()
    names.push("frame")
    names.push("waiter_frame")
    names.push("waiter")
    return types.function_type(
        name = "",
        params = params.as_span(),
        return_type = types.alloc_type(types.primitive("void")),
        variadic = false,
        is_proc = false,
        param_names = names.as_span()
    )


## Check a call to a top-level function by identifier and yield its result type.
## For a generic function, type arguments are inferred from the call, validated
## against their constraints, and substituted into the return type.
function check_call(
    ctx: ref[Context],
    scope: ref[sscope.Scope],
    callee: ptr[ast.Expr],
    args: span[ast.Argument],
    arg_types: span[types.Type],
    any_named: bool
) -> types.Type:
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
                    # The host's `resolve_callable_raw` fallback: a module-level
                    # value (e.g. a proc-typed `var`) and the compile-time handle
                    # builtins resolve permissively; anything else is an unknown
                    # callable.
                    if (
                        ctx.value_names.contains(id.name)
                        or ctx.suppressed_type_names.contains(id.name)
                        or is_callable_builtin_name(id.name)
                    ):
                        return types.Type.ty_error
                    # A source-only check (no loader-backed import bindings) is
                    # the permissive diagnostic helper path; only a real compile
                    # reports an unresolved callee.
                    if ctx.imported_modules == null:
                        return types.Type.ty_error
                    var unknown_msg = string.String.create()
                    unknown_msg.append("unknown callable ")
                    unknown_msg.append(id.name)
                    report(ctx, id.line, id.column, unknown_msg.as_str())
                    return types.Type.ty_error
                let sig = read(sigp)
                record_mutating_argument_sites(ctx, id.name, args)
                check_signature_call(ctx, id.name, sig, args, arg_types, any_named, id.line, id.column)
                let dpm_ptr = ctx.directional_param_modes.get(id.name)
                if dpm_ptr != null:
                    record_directional_ffi_sites(
                        ctx,
                        callee,
                        id.name,
                        ptr[map_mod.Map[ptr_uint, DirectionalParamInfo]]<-dpm_ptr,
                        args
                    )
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
public function check_signature_call(
    ctx: ref[Context],
    display_name: str,
    sig: FnSig,
    args: span[ast.Argument],
    arg_types: span[types.Type],
    any_named: bool,
    line: ptr_uint,
    column: ptr_uint
) -> void:
    if not any_named:
        record_mutable_lvalue_argument_sites(ctx, sig, args, arg_types)
    if sig.is_variadic:
        if arg_types.len < sig.required_count:
            report(ctx, line, column, arity_message(display_name, sig.required_count, arg_types.len))
            return
    else if arg_types.len > sig.params.len or arg_types.len < sig.required_count:
        report(ctx, line, column, arity_message(display_name, sig.required_count, arg_types.len))
        return
    if any_named:
        return
    var i: ptr_uint = 0
    while i < arg_types.len and i < sig.params.len:
        unsafe:
            let atype = read(arg_types.data + i)
            let pe = read(sig.params.data + i)
            var arg_expr: ptr[ast.Expr]? = null
            if i < args.len:
                arg_expr = read(args.data + i).arg_value
            var incompatible = false
            if sig.is_extern:
                if not (member_calls.is_imported_constant_member(
                    ctx,
                    arg_expr
                ) and types.is_numeric(pe.ty) and types.is_numeric(atype)):
                    incompatible = incompatible_external_value_with_consts(ctx,
                        pe.ty,
                        atype,
                        arg_expr,
                        ref_of(ctx.const_values)
                    )
            else:
                incompatible = incompatible_value_with_consts(ctx, pe.ty, atype, arg_expr, ref_of(ctx.const_values))
            if incompatible:
                report(ctx, line, column, argument_message(pe.name, display_name, pe.ty, atype))
        i += 1


## The host's `array_to_span_call_argument_compatible?`: an array or
## `str_buffer` argument passed where a `span` parameter is expected is a
## mutable lvalue (the callee may write through the span), recorded for the
## linter's prefer-let (the host's `mutable_lvalue_argument_identifier_ids`).
function record_mutable_lvalue_argument_sites(
    ctx: ref[Context],
    sig: FnSig,
    args: span[ast.Argument],
    arg_types: span[types.Type]
) -> void:
    var i: ptr_uint = 0
    while i < arg_types.len and i < sig.params.len and i < args.len:
        unsafe:
            let pe = read(sig.params.data + i)
            let atype = read(arg_types.data + i)
            let argument = read(args.data + i)
            match read(argument.arg_value):
                ast.Expr.expr_identifier as aid:
                    if mutable_lvalue_span_argument(pe.ty, atype):
                        ctx.mutable_lvalue_sites.push(EditableSite(
                            name = aid.name,
                            line = aid.line,
                            column = aid.column
                        ))
                _:
                    pass
        i += 1


## Does the coercion `actual` → `expected` go through a span, where the actual
## is an array/`str_buffer` lvalue?  Mirrors the host's rule pair.
function mutable_lvalue_span_argument(expected: types.Type, actual: types.Type) -> bool:
    match expected:
        types.Type.ty_generic as eg:
            let eg_bp = unsafe: read(eg.payload)
            if not eg_bp.name.equal("span") or eg_bp.args.len < 1:
                return false
            let elem = unsafe: read(eg_bp.args.data + 0)
            match actual:
                types.Type.ty_generic as ag:
                    let ag_bp = unsafe: read(ag.payload)
                    if ag_bp.name.equal("array") and ag_bp.args.len >= 1:
                        return types.type_equals(unsafe: read(ag_bp.args.data + 0), elem)
                    if ag_bp.name.equal("str_buffer"):
                        return types.is_char_type(elem)
                _:
                    pass
            return false
        _:
            return false


## Record which parameter indices of a foreign function carry an `out`/`inout`
## passing mode, so call sites can mark their identifier arguments as mutated.
function record_mutating_param_indices(ctx: ref[Context], name: str, params: span[ast.ForeignParam]) -> void:
    var indices = map_mod.Map[ptr_uint, bool].create()
    var i: ptr_uint = 0
    while i < params.len:
        unsafe:
            let mode = read(params.data + i).param_mode
            if mode == ast.ForeignParamMode.fmode_out or mode == ast.ForeignParamMode.fmode_inout:
                indices.set(i, true)
        i += 1
    if indices.len() > 0:
        ctx.mutating_param_indices.set(name, indices)


## Mark the identifier arguments passed to a foreign function's `out`/`inout`
## parameters (the host's `mutating_argument_identifier_ids`): the call mutates
## those bindings, so prefer-let must not fire on them.
function record_mutating_argument_sites(ctx: ref[Context], name: str, args: span[ast.Argument]) -> void:
    let indices_ptr = ctx.mutating_param_indices.get(name) else:
        return
    record_mutating_args_for_indices(ctx, indices_ptr, args)


## Record every `in`/`out`/`inout` parameter of a foreign/extern function
## (index -> mode label + declared name), so call sites can flag a legacy
## directional argument (the host's `directional-ffi-arg` rule).
function record_directional_param_modes(ctx: ref[Context], name: str, params: span[ast.ForeignParam]) -> void:
    var modes = map_mod.Map[ptr_uint, DirectionalParamInfo].create()
    var i: ptr_uint = 0
    unsafe:
        while i < params.len:
            let p = read(params.data + i)
            match p.param_mode:
                ast.ForeignParamMode.fmode_in:
                    modes.set(i, DirectionalParamInfo(mode_label = "in", name = p.name))
                ast.ForeignParamMode.fmode_out:
                    modes.set(i, DirectionalParamInfo(mode_label = "out", name = p.name))
                ast.ForeignParamMode.fmode_inout:
                    modes.set(i, DirectionalParamInfo(mode_label = "inout", name = p.name))
                _:
                    pass
            i += 1
    if modes.len() > 0:
        ctx.directional_param_modes.set(name, modes)


## Record a `directional-ffi-arg` site for every argument whose shape
## re-states the parameter's direction: `in x`/`out x`/`inout x`,
## `ptr_of(x)`/`ref_of(x)`, or a pointer-like cast of an lvalue (the host's
## `legacy_directional_argument_expression?`).
function record_directional_ffi_sites(
    ctx: ref[Context],
    callee: ptr[ast.Expr],
    function_name: str,
    modes: ptr[map_mod.Map[ptr_uint, DirectionalParamInfo]],
    args: span[ast.Argument]
) -> void:
    var i: ptr_uint = 0
    unsafe:
        while i < args.len:
            if read(modes).contains(i):
                let argument = read(args.data + i)
                if legacy_directional_argument(argument.arg_value):
                    let info_ptr = read(modes).get(i) else:
                        i += 1
                        continue
                    let info = read(info_ptr)
                    ctx.directional_ffi_sites.push(DirectionalFfiSite(
                        callee_key = reinterpret[ptr_uint](callee),
                        argument_key = reinterpret[ptr_uint](argument.arg_value),
                        function_name = function_name,
                        parameter_name = info.name,
                        mode_label = info.mode_label,
                    ))
            i += 1


function legacy_directional_argument(expr: ptr[ast.Expr]) -> bool:
    unsafe:
        match read(expr):
            ast.Expr.expr_unary_op as u:
                return u.operator.equal("in") or u.operator.equal("out") or u.operator.equal("inout")
            ast.Expr.expr_call as cl:
                match read(cl.callee):
                    ast.Expr.expr_identifier as id:
                        if id.name.equal("ptr_of") or id.name.equal("ref_of"):
                            return cl.args.len == 1
                    _:
                        pass
                return false
            ast.Expr.expr_prefix_cast as pc:
                if pointer_like_type_ref(pc.target_type):
                    return lvalue_expr(pc.expression) or legacy_directional_argument(pc.expression)
                return false
            _:
                return false


## A non-nullable `ptr`/`const_ptr`/`ref` type-ref (the host's
## `pointer_like_type_ref?`; a qualified `a.ptr` is not pointer-like).
function pointer_like_type_ref(tr: ptr[ast.TypeRef]) -> bool:
    unsafe:
        let t = read(tr)
        if t.nullable or t.name.parts.len != 1:
            return false
        let name = read(t.name.parts.data + 0)
        return name.equal("ptr") or name.equal("const_ptr") or name.equal("ref")


function lvalue_expr(expr: ptr[ast.Expr]) -> bool:
    unsafe:
        match read(expr):
            ast.Expr.expr_identifier:
                return true
            ast.Expr.expr_member_access:
                return true
            ast.Expr.expr_index_access:
                return true
            _:
                return false


function record_mutating_args_for_indices(
    ctx: ref[Context],
    indices: ptr[map_mod.Map[ptr_uint, bool]],
    args: span[ast.Argument]
) -> void:
    var i: ptr_uint = 0
    while i < args.len:
        unsafe:
            if read(indices).contains(i):
                match read(read(args.data + i).arg_value):
                    ast.Expr.expr_identifier as arg_id:
                        ctx.mutating_argument_sites.push(EditableSite(
                            name = arg_id.name,
                            line = arg_id.line,
                            column = arg_id.column
                        ))
                    _:
                        pass
        i += 1

# =============================================================================
#  Diagnostic messages
# =============================================================================

function return_mismatch_message(expected: types.Type, got: types.Type) -> str:
    return diag.return_mismatch_message(expected, got)


function local_mismatch_message(expected: types.Type, got: types.Type, name: str) -> str:
    return diag.local_mismatch_message(expected, got, name)


function assign_message(target: types.Type, value: types.Type) -> str:
    return diag.assign_message(target, value)


function assign_to_let_message(name: str) -> str:
    return diag.assign_to_let_message(name)


function editable_on_immutable_message(name: str, method: str) -> str:
    return diag.editable_on_immutable_message(name, method)


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


public function arity_message(name: str, expected: ptr_uint, got: ptr_uint) -> str:
    return diag.arity_message(name, expected, got)


public function unknown_member_message(kind: str, type_name: str, member: str) -> str:
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


function reserved_value_message(kind_label: str, name: str) -> str:
    return diag.reserved_value_message(kind_label, name)


function make_task_type(inner: types.Type) -> types.Type:
    var args = vec.Vec[types.Type].create()
    args.push(inner)
    return types.generic_type(name = "Task", args = args.as_span())


function register_task_methods(ctx: ref[Context]) -> void:
    ctx.method_keys.set(method_key("Task", "take_result"), true)
    ctx.method_keys.set(method_key("Task", "release"), true)
    ctx.method_keys.set(method_key("Task", "set_waiter"), true)
    ctx.method_keys.set(method_key("Task", "cancel"), true)
    ctx.method_keys.set(method_key("Task", "ready"), true)
