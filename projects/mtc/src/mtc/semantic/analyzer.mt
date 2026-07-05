## Semantic analyzer (phase 1) — mirrors the structure of Ruby's
## SemanticAnalyzer (lib/milk_tea/core/semantic_analyzer.rb): a structural
## collection pass over top-level declarations followed by per-function body
## checking.
##
## Scope of phase 1 (sound but intentionally incomplete — like Ruby it uses a
## permissive Error type so it never emits a false positive):
##   * duplicate top-level value / type declarations
##   * return-type compatibility (concrete scalar mismatches)
##   * let/var initializer vs declared-type compatibility
## Anything the analyzer cannot resolve concretely degrades to `ty_error`,
## which is compatible with everything, so valid programs are never flagged.
## Module loading, generics, interfaces, flow analysis, and full type
## compatibility are later phases.

import std.map as map_mod
import std.str
import std.string as string
import std.vec as vec

import mtc.parser.ast as ast
import mtc.semantic.types as types


public struct SemanticDiagnostic:
    line: ptr_uint
    column: ptr_uint
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


public struct FieldEntry:
    name: str
    ty: types.Type


## The public export surface of a module, consumed by importers for cross-module
## name resolution.  Built from an Analysis by the loader's binder
## (mtc.loader.binder); the type lives here to keep the analyzer free of a
## dependency on the loader.  Exposes public functions (call checks), structs
## (construction field checks), value types (const/var), and enum/variant static
## members (member-access validation).
public struct ModuleBinding:
    functions: map_mod.Map[str, FnSig]
    structs: map_mod.Map[str, span[FieldEntry]]
    value_types: map_mod.Map[str, types.Type]
    static_member_types: map_mod.Map[str, bool]
    member_keys: map_mod.Map[str, bool]
    method_sigs: map_mod.Map[str, FnSig]
    interfaces: map_mod.Map[str, span[ast.InterfaceMethod]]
    implemented: map_mod.Map[str, span[ast.QualifiedName]]
    match_case_names: map_mod.Map[str, span[str]]


struct Context:
    value_names: map_mod.Map[str, bool]
    type_names: map_mod.Map[str, bool]
    type_aliases: map_mod.Map[str, ptr[ast.TypeRef]]
    alias_types: map_mod.Map[str, types.Type]
    structs: map_mod.Map[str, span[FieldEntry]]
    method_keys: map_mod.Map[str, bool]
    method_sigs: map_mod.Map[str, FnSig]
    static_member_types: map_mod.Map[str, bool]
    match_case_types: map_mod.Map[str, bool]
    match_case_names: map_mod.Map[str, span[str]]
    functions: map_mod.Map[str, FnSig]
    value_types: map_mod.Map[str, types.Type]
    interfaces: map_mod.Map[str, span[ast.InterfaceMethod]]
    type_params: map_mod.Map[str, span[ast.TypeParamConstraint]]
    function_type_params: map_mod.Map[str, span[ast.TypeParam]]
    implemented: map_mod.Map[str, span[ast.QualifiedName]]
    import_aliases: map_mod.Map[str, str]
    imported_modules: ptr[map_mod.Map[str, ModuleBinding]]?
    diagnostics: vec.Vec[SemanticDiagnostic]


public struct Analysis:
    source_file: ast.SourceFile
    diagnostics: vec.Vec[SemanticDiagnostic]
    type_names: map_mod.Map[str, bool]
    structs: map_mod.Map[str, span[FieldEntry]]
    functions: map_mod.Map[str, FnSig]
    value_types: map_mod.Map[str, types.Type]
    method_keys: map_mod.Map[str, bool]
    method_sigs: map_mod.Map[str, FnSig]
    static_member_types: map_mod.Map[str, bool]
    match_case_names: map_mod.Map[str, span[str]]
    interfaces: map_mod.Map[str, span[ast.InterfaceMethod]]


public function check_source_file(file: ast.SourceFile) -> Analysis:
    return check_module(file, null)


## Semantically check a module, resolving cross-module references against the
## given import bindings (keyed by module name; may be null for single-file
## checks).  `imported_modules` is borrowed, not owned.
public function check_module(file: ast.SourceFile, imported_modules: ptr[map_mod.Map[str, ModuleBinding]]?) -> Analysis:
    var ctx = Context(
        value_names = map_mod.Map[str, bool].create(),
        type_names = map_mod.Map[str, bool].create(),
        type_aliases = map_mod.Map[str, ptr[ast.TypeRef]].create(),
        alias_types = map_mod.Map[str, types.Type].create(),
        structs = map_mod.Map[str, span[FieldEntry]].create(),
        method_keys = map_mod.Map[str, bool].create(),
        method_sigs = map_mod.Map[str, FnSig].create(),
        static_member_types = map_mod.Map[str, bool].create(),
        match_case_types = map_mod.Map[str, bool].create(),
        match_case_names = map_mod.Map[str, span[str]].create(),
        functions = map_mod.Map[str, FnSig].create(),
        value_types = map_mod.Map[str, types.Type].create(),
        interfaces = map_mod.Map[str, span[ast.InterfaceMethod]].create(),
        type_params = map_mod.Map[str, span[ast.TypeParamConstraint]].create(),
        function_type_params = map_mod.Map[str, span[ast.TypeParam]].create(),
        implemented = map_mod.Map[str, span[ast.QualifiedName]].create(),
        import_aliases = map_mod.Map[str, str].create(),
        imported_modules = imported_modules,
        diagnostics = vec.Vec[SemanticDiagnostic].create(),
    )
    collect_import_aliases(ref_of(ctx), file)
    declare_named_types(ref_of(ctx), file)
    collect_struct_fields(ref_of(ctx), file)
    collect_extending_methods(ref_of(ctx), file)
    collect_enum_variant_members(ref_of(ctx), file)
    collect_interfaces(ref_of(ctx), file)
    declare_values_and_functions(ref_of(ctx), file)
    check_functions(ref_of(ctx), file)
    check_extending_methods(ref_of(ctx), file)
    check_interface_conformances(ref_of(ctx), file)
    check_top_level_static_asserts(ref_of(ctx), file)
    return Analysis(
        source_file = file,
        diagnostics = ctx.diagnostics,
        type_names = ctx.type_names,
        structs = ctx.structs,
        functions = ctx.functions,
        value_types = ctx.value_types,
        method_keys = ctx.method_keys,
        method_sigs = ctx.method_sigs,
        static_member_types = ctx.static_member_types,
        match_case_names = ctx.match_case_names,
        interfaces = ctx.interfaces,
    )


function report(ctx: ref[Context], line: ptr_uint, column: ptr_uint, message: str) -> void:
    ctx.diagnostics.push(SemanticDiagnostic(line = line, column = column, message = message))


## Record each import's alias -> module name so member access on an alias
## (`alias.func(...)`) can be resolved against the imported module's bindings.
function collect_import_aliases(ctx: ref[Context], file: ast.SourceFile) -> void:
    var i: ptr_uint = 0
    while i < file.imports.len:
        var d: ast.Decl
        unsafe:
            d = read(file.imports.data + i)
        match d:
            ast.Decl.decl_import as imp:
                ctx.import_aliases.set(import_alias_name(imp.path, imp.alias_name), qname_to_str(imp.path))
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
                ctx.implemented.set(s.name, s.impl_list)
            ast.Decl.decl_union as u:
                declare_type(ctx, u.name, u.line, u.column)
            ast.Decl.decl_enum as e:
                declare_type(ctx, e.name, e.line, e.column)
            ast.Decl.decl_flags as fl:
                declare_type(ctx, fl.name, fl.line, fl.column)
            ast.Decl.decl_variant as vr:
                declare_type(ctx, vr.name, vr.line, vr.column)
            ast.Decl.decl_opaque as op:
                declare_type(ctx, op.name, op.line, op.column)
                ctx.implemented.set(op.name, op.opaque_implements)
            ast.Decl.decl_type_alias as ta:
                declare_type(ctx, ta.name, ta.line, ta.column)
                ctx.type_aliases.set(ta.name, ta.target)
            _:
                pass
        i += 1


function declare_type(ctx: ref[Context], name: str, line: ptr_uint, column: ptr_uint) -> void:
    if ctx.type_names.contains(name):
        report(ctx, line, column, dup_message("type", name))
        return
    ctx.type_names.set(name, true)


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
                ctx.structs.set(s.name, resolve_field_entries(ctx, s.struct_fields))
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
                var j: ptr_uint = 0
                while j < ex.methods.len:
                    var m: ast.Method
                    unsafe:
                        m = read(ex.methods.data + j)
                    let key = method_key(base, m.name)
                    ctx.method_keys.set(key, true)
                    # Instance methods win the signature key over a same-named
                    # static method (e.g. str's instance `equal(right)` vs the
                    # static `equal(left, right)` hook), so instance calls resolve
                    # to the instance signature.
                    if m.method_kind != ast.MethodKind.mk_static or not ctx.method_sigs.contains(key):
                        ctx.method_sigs.set(key, build_fn_sig(ctx, m.name, m.method_params, m.return_type, m.method_kind))
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
                    ctx.functions.set(fun.name, build_fn_sig(ctx, fun.name, fun.method_params, fun.return_type, ast.MethodKind.mk_plain))
                    ctx.type_params.clear()
                    if fun.type_params.len > 0:
                        ctx.function_type_params.set(fun.name, fun.type_params)
            ast.Decl.decl_extern_function as ef:
                declare_value(ctx, ef.name, ef.line, 1)
            ast.Decl.decl_foreign_function as ff:
                declare_value(ctx, ff.name, ff.line, 1)
            _:
                pass
        i += 1


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


function build_fn_sig(ctx: ref[Context], name: str, params: span[ast.Param], return_type: ptr[ast.TypeRef]?, method_kind: ast.MethodKind) -> FnSig:
    var param_entries = vec.Vec[ParamEntry].create()
    var i: ptr_uint = 0
    while i < params.len:
        var p: ast.Param
        unsafe:
            p = read(params.data + i)
        param_entries.push(ParamEntry(name = p.name, ty = resolve_type_value(ctx, p.param_type)))
        i += 1
    let rt = return_type
    if rt != null:
        return FnSig(name = name, params = param_entries.as_span(),
            return_type = resolve_type(ctx, rt), has_return_type = true, method_kind = method_kind)
    return FnSig(name = name, params = param_entries.as_span(),
        return_type = types.primitive("void"), has_return_type = false, method_kind = method_kind)


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
        var i: ptr_uint = 0
        while i < t.fn_params.len:
            var p: ast.Param
            unsafe:
                p = read(t.fn_params.data + i)
            param_types.push(resolve_type_at(ctx, p.param_type, depth + 1))
            i += 1
        var ret = types.primitive("void")
        let fr = t.fn_return
        if fr != null:
            unsafe:
                ret = resolve_type_at(ctx, read(fr), depth + 1)
        let base = types.Type.ty_function(params = param_types.as_span(), return_type = types.alloc_type(ret), variadic = false)
        return wrap_nullable(base, t.nullable)

    if t.is_dyn:
        return wrap_nullable(types.Type.ty_named(name = "dyn"), t.nullable)

    if t.is_tuple:
        return types.Type.ty_error

    # An `alias.Type` naming a type exported by an imported module resolves to a
    # concrete imported type (so its members are checkable); otherwise fall back
    # to the permissive named/error resolution.
    match resolve_imported_type(ctx, t.name):
        Option.some as imported:
            return wrap_nullable(imported.value, t.nullable)
        Option.none:
            pass

    let name = qname_to_str(t.name)
    let base = resolve_named(ctx, name, t.arguments, depth)
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
        if binding.structs.contains(type_name) or binding.static_member_types.contains(type_name) or binding.interfaces.contains(type_name):
            return Option[types.Type].some(value = types.Type.ty_imported(module_name = read(module_name_ptr), name = type_name))
    return Option[types.Type].none


function wrap_nullable(base: types.Type, nullable: bool) -> types.Type:
    if nullable:
        return types.Type.ty_nullable(base = types.alloc_type(base))
    return base


function resolve_named(ctx: ref[Context], name: str, arguments: span[ast.TypeRef], depth: int) -> types.Type:
    # An in-scope generic type parameter is a type variable, carrying whatever
    # `implements` constraints its declaration gave it.
    if ctx.type_params.contains(name):
        return types.Type.ty_var(name = name)
    # Type aliases resolve to their (transitively resolved) target.
    if ctx.type_aliases.contains(name):
        return resolve_alias(ctx, name, depth)
    if name.equal("str"):
        return types.Type.ty_str
    if is_primitive_type_name(name):
        return types.primitive(name)
    if is_generic_constructor_name(name):
        var args = vec.Vec[types.Type].create()
        var i: ptr_uint = 0
        while i < arguments.len:
            var a: ast.TypeRef
            unsafe:
                a = read(arguments.data + i)
            args.push(resolve_type_at(ctx, a, depth + 1))
            i += 1
        return types.Type.ty_generic(name = name, args = args.as_span())
    if ctx.type_names.contains(name):
        return types.Type.ty_named(name = name)
    # Unknown / imported / type-parameter names are permissive.
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
        name.equal("bool") or name.equal("byte") or name.equal("ubyte") or name.equal("char")
        or name.equal("short") or name.equal("ushort") or name.equal("int") or name.equal("uint")
        or name.equal("long") or name.equal("ulong") or name.equal("ptr_int") or name.equal("ptr_uint")
        or name.equal("float") or name.equal("double") or name.equal("void") or name.equal("cstr")
        or name.equal("vec2") or name.equal("vec3") or name.equal("vec4")
        or name.equal("ivec2") or name.equal("ivec3") or name.equal("ivec4")
        or name.equal("mat3") or name.equal("mat4") or name.equal("quat")
    )


function is_generic_constructor_name(name: str) -> bool:
    return (
        name.equal("ptr") or name.equal("const_ptr") or name.equal("ref") or name.equal("span")
        or name.equal("array") or name.equal("str_buffer") or name.equal("atomic") or name.equal("Task")
        or name.equal("Option") or name.equal("Result") or name.equal("SoA")
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
                check_function_body(ctx, fun.name, fun.line, fun.type_params, fun.method_params, fun.return_type, fun.body)
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
                unsafe:
                    this_type = resolve_type_value(ctx, read(ex.type_name))
                var j: ptr_uint = 0
                while j < ex.methods.len:
                    var m: ast.Method
                    unsafe:
                        m = read(ex.methods.data + j)
                    check_method_body(ctx, this_type, m)
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
            let required = build_fn_sig(ctx, m.name, m.method_params, m.return_type, m.method_kind)
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


struct Scope:
    frames: vec.Vec[map_mod.Map[str, types.Type]]
    let_bindings: vec.Vec[map_mod.Map[str, bool]]


function scope_create() -> Scope:
    return Scope(
        frames = vec.Vec[map_mod.Map[str, types.Type]].create(),
        let_bindings = vec.Vec[map_mod.Map[str, bool]].create(),
    )


function scope_enter(scope: ref[Scope]) -> void:
    scope.frames.push(map_mod.Map[str, types.Type].create())
    scope.let_bindings.push(map_mod.Map[str, bool].create())


function scope_leave(scope: ref[Scope]) -> void:
    match scope.frames.pop():
        Option.some as frame:
            var released = frame.value
            released.release()
        Option.none:
            pass
    match scope.let_bindings.pop():
        Option.some as let_frame:
            var released = let_frame.value
            released.release()
        Option.none:
            pass


function scope_set(scope: ref[Scope], name: str, ty: types.Type) -> void:
    let count = scope.frames.len()
    if count == 0:
        return
    let frame_ptr = scope.frames.get(count - 1) else:
        return
    unsafe:
        let _prev = read(frame_ptr).set(name, ty)


## Search the frame stack from innermost to outermost for a binding.
function scope_get(scope: ref[Scope], name: str) -> ptr[types.Type]?:
    var index = scope.frames.len()
    while index > 0:
        index -= 1
        let frame_ptr = scope.frames.get(index) else:
            return null
        unsafe:
            let found = read(frame_ptr).get(name)
            if found != null:
                return found
    return null


## True when the name is bound via `let` (immutable) anywhere in the scope
## stack.  An immutable binding may not appear as the target of an assignment
## (= or compound-assignment).
function scope_is_let(scope: ref[Scope], name: str) -> bool:
    var index = scope.let_bindings.len()
    while index > 0:
        index -= 1
        let frame_ptr = scope.let_bindings.get(index) else:
            return false
        if unsafe: read(frame_ptr).contains(name):
            return true
    return false


function scope_set_let(scope: ref[Scope], name: str) -> void:
    let count = scope.let_bindings.len()
    if count == 0:
        return
    let frame_ptr = scope.let_bindings.get(count - 1) else:
        return
    unsafe:
        let _prev = read(frame_ptr).set(name, true)


function check_method_body(ctx: ref[Context], this_type: types.Type, m: ast.Method) -> void:
    enter_type_params(ctx, m.type_params)
    var scope = scope_create()
    scope_enter(ref_of(scope))
    if m.method_kind != ast.MethodKind.mk_static:
        scope_set(ref_of(scope), "this", this_type)
    var pi: ptr_uint = 0
    while pi < m.method_params.len:
        var p: ast.Param
        unsafe:
            p = read(m.method_params.data + pi)
        scope_set(ref_of(scope), p.name, resolve_type_value(ctx, p.param_type))
        pi += 1
    var ret = types.primitive("void")
    let rt = m.return_type
    if rt != null:
        ret = resolve_type(ctx, rt)
    check_stmt(ctx, ref_of(scope), ret, false, m.body)
    if rt != null and not types.is_void(ret):
        if not terminates_ptr(ctx, m.body):
            report(ctx, m.line, m.column, missing_return_message(m.name))
    ctx.type_params.clear()


function check_function_body(ctx: ref[Context], name: str, line: ptr_uint, type_params: span[ast.TypeParam], params: span[ast.Param], return_type: ptr[ast.TypeRef]?, body: ptr[ast.Stmt]?) -> void:
    let b = body else:
        return
    enter_type_params(ctx, type_params)
    var scope = scope_create()
    scope_enter(ref_of(scope))
    var pi: ptr_uint = 0
    while pi < params.len:
        var p: ast.Param
        unsafe:
            p = read(params.data + pi)
        scope_set(ref_of(scope), p.name, resolve_type_value(ctx, p.param_type))
        pi += 1
    var ret = types.primitive("void")
    let rt = return_type
    if rt != null:
        ret = resolve_type(ctx, rt)
    check_stmt(ctx, ref_of(scope), ret, false, b)
    if rt != null and not types.is_void(ret):
        if not terminates_ptr(ctx, b):
            report(ctx, line, 1, missing_return_message(name))
    ctx.type_params.clear()


## Register a generic body's type parameters so references to them resolve to
## type variables carrying their `implements` constraints.  Value and lifetime
## parameters are not type variables and are skipped.  Cleared after the body.
function enter_type_params(ctx: ref[Context], type_params: span[ast.TypeParam]) -> void:
    var i: ptr_uint = 0
    while i < type_params.len:
        var tp: ast.TypeParam
        unsafe:
            tp = read(type_params.data + i)
        if not tp.is_value and not tp.is_lifetime:
            ctx.type_params.set(tp.name, tp.constraints)
        i += 1


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
                        return id.name.equal("fatal")
                    _:
                        return false
            _:
                return false


## True when the expression is a compile-time numeric literal (integer, float,
## or char).  The self-host has no compile-time evaluation, so a literal source
## is treated as compatible with any numeric target — mirroring Ruby's
## exact_compile_time_numeric_compatibility? without range-checking the value.
function expr_is_numeric_literal(ep: ptr[ast.Expr]?) -> bool:
    let p = ep else:
        return false
    unsafe:
        match read(p):
            ast.Expr.expr_integer_literal:
                return true
            ast.Expr.expr_float_literal:
                return true
            ast.Expr.expr_char_literal:
                return true
            _:
                return false


## Assignment-site incompatibility check that accounts for numeric literals.
## A numeric-literal source assigned to a numeric/char target is always
## permitted (the literal is assumed to fit); otherwise defer to the concrete
## type-compatibility rule.
function incompatible_value(target: types.Type, source_ty: types.Type, source_expr: ptr[ast.Expr]?) -> bool:
    if expr_is_numeric_literal(source_expr):
        if types.is_integer_type(target) or types.is_float_type(target) or types.is_char_type(target):
            return false
    return types.definitely_incompatible(target, source_ty)


function check_body(ctx: ref[Context], scope: ref[Scope], ret: types.Type, in_loop: bool, body: ptr[ast.Stmt]?) -> void:
    let b = body else:
        return
    scope_enter(scope)
    check_stmt(ctx, scope, ret, in_loop, b)
    scope_leave(scope)


function check_stmt(ctx: ref[Context], scope: ref[Scope], ret: types.Type, in_loop: bool, sp: ptr[ast.Stmt]) -> void:
    unsafe:
        match read(sp):
            ast.Stmt.stmt_block as blk:
                check_stmt_span(ctx, scope, ret, in_loop, blk.statements)
            ast.Stmt.stmt_ret as r:
                let rv = r.value
                if rv != null:
                    let vt = infer_expr(ctx, scope, rv)
                    if incompatible_value(ret, vt, rv):
                        report(ctx, r.line, r.column, return_mismatch_message(ret, vt))
            ast.Stmt.stmt_local as l:
                check_local(ctx, scope, l.is_let, l.name, l.stmt_type, l.value, l.destructure_bindings, l.line, l.column)
            ast.Stmt.stmt_if as i:
                var bi: ptr_uint = 0
                while bi < i.branches.len:
                    var br: ast.IfBranch
                    br = read(i.branches.data + bi)
                    check_condition(ctx, scope, br.condition, "if", br.line, br.column)
                    check_body(ctx, scope, ret, in_loop, br.body)
                    bi += 1
                check_body(ctx, scope, ret, in_loop, i.else_body)
            ast.Stmt.stmt_while as w:
                check_condition(ctx, scope, w.condition, "while", w.line, w.column)
                check_body(ctx, scope, ret, true, w.body)
            ast.Stmt.stmt_for as fr:
                scope_enter(scope)
                bind_for_names(scope, fr.bindings)
                check_body(ctx, scope, ret, true, fr.body)
                scope_leave(scope)
            ast.Stmt.stmt_match as m:
                var ai: ptr_uint = 0
                while ai < m.arms.len:
                    var arm: ast.MatchArm
                    arm = read(m.arms.data + ai)
                    check_body(ctx, scope, ret, in_loop, arm.body)
                    ai += 1
                check_match(ctx, scope, m.scrutinee, m.arms, m.line, m.column)
            ast.Stmt.stmt_unsafe as u:
                check_body(ctx, scope, ret, in_loop, u.body)
            ast.Stmt.stmt_defer as d:
                check_body(ctx, scope, ret, in_loop, d.body)
            ast.Stmt.stmt_break as br:
                if not in_loop:
                    report(ctx, br.line, br.column, "break must be inside a loop")
            ast.Stmt.stmt_continue as cont:
                if not in_loop:
                    report(ctx, cont.line, cont.column, "continue must be inside a loop")
            ast.Stmt.stmt_expression as e:
                let _ignored = infer_expr(ctx, scope, e.expression)
            ast.Stmt.stmt_assignment as a:
                let tt = infer_expr(ctx, scope, a.target)
                let vt = infer_expr(ctx, scope, a.value)
                if a.operator.equal("=") and incompatible_value(tt, vt, a.value):
                    report(ctx, a.line, a.column, assign_message(tt, vt))
                check_assign_target_immutable(ctx, scope, a.target, a.line, a.column)
            _:
                pass


function check_condition(ctx: ref[Context], scope: ref[Scope], cond: ptr[ast.Expr], keyword: str, line: ptr_uint, column: ptr_uint) -> void:
    let ct = infer_expr(ctx, scope, cond)
    if types.is_definitely_non_bool(ct):
        report(ctx, line, column, condition_message(keyword, ct))


function check_stmt_span(ctx: ref[Context], scope: ref[Scope], ret: types.Type, in_loop: bool, stmts: span[ast.Stmt]) -> void:
    var i: ptr_uint = 0
    while i < stmts.len:
        unsafe:
            check_stmt(ctx, scope, ret, in_loop, stmts.data + i)
        i += 1


## Match validation dispatched on the scrutinee type:
##  * enum/variant   -> exhaustiveness ("missing cases") + duplicate-arm
##  * integer/str    -> requires a wildcard `_` arm + duplicate integer value
##  * anything else  -> permissive
## Enum/variant checks bail out if any arm is not a plain `Type.case` pattern
## (e.g. payload destructuring), so guarded/complex matches never false-positive.
function check_match(ctx: ref[Context], scope: ref[Scope], scrutinee: ptr[ast.Expr], arms: span[ast.MatchArm], line: ptr_uint, column: ptr_uint) -> void:
    let st = infer_expr(ctx, scope, scrutinee)
    match st:
        types.Type.ty_named as n:
            if ctx.match_case_types.contains(n.name):
                check_case_match(ctx, n.name, arms, line, column)
        types.Type.ty_imported as im:
            if ctx.match_case_types.contains(im.name):
                check_case_match(ctx, im.name, arms, line, column)
        types.Type.ty_str:
            check_scalar_match(ctx, arms, line, column, "match on str requires a wildcard arm (_:)", false)
        types.Type.ty_primitive as p:
            if is_integer_name(p.name):
                check_scalar_match(ctx, arms, line, column, integer_wildcard_message(p.name), true)
        _:
            pass


function check_case_match(ctx: ref[Context], type_name: str, arms: span[ast.MatchArm], line: ptr_uint, column: ptr_uint) -> void:
    let namesp = ctx.match_case_names.get(type_name) else:
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
                return Option[int].some(value = lit.value)
            ast.Expr.expr_char_literal as ch:
                return Option[int].some(value = int<-ch.value)
            _:
                return Option[int].none


function is_integer_name(name: str) -> bool:
    return types.is_integer_name(name)


function vec_contains_str(v: ref[vec.Vec[str]], s: str) -> bool:
    var i: ptr_uint = 0
    while i < v.len():
        let p = v.get(i) else:
            break
        unsafe:
            if read(p).equal(s):
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


function bind_for_names(scope: ref[Scope], bindings: span[ast.ForBinding]) -> void:
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
            if (g.name.equal("Option") or g.name.equal("Result")) and g.args.len >= 1:
                return unsafe: read(g.args.data + 0)
            return t
        _:
            return t


## Flag an assignment whose target is a name bound by `let`, which is immutable.
function check_assign_target_immutable(ctx: ref[Context], scope: ref[Scope], target: ptr[ast.Expr], line: ptr_uint, column: ptr_uint) -> void:
    unsafe:
        match read(target):
            ast.Expr.expr_identifier as id:
                if scope_is_let(scope, id.name):
                    report(ctx, line, column, assign_to_let_message(id.name))
            _:
                pass


function check_local(ctx: ref[Context], scope: ref[Scope], is_let: bool, name: str, stmt_type: ptr[ast.TypeRef]?, value: ptr[ast.Expr]?, destructure_bindings: Option[span[str]], line: ptr_uint, column: ptr_uint) -> void:
    # Destructuring bindings are permissive in phase 1.
    match destructure_bindings:
        Option.some:
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

    if has_declared and has_value:
        if incompatible_value(declared, value_type, value):
            report(ctx, line, column, local_mismatch_message(declared, value_type))

    # A guarded let/var (let x = nullable else: ...) unwraps the value type:
    # T?, Option[T], and Result[T,E] all narrow their success type.
    let narrowed = unwrap_nullable_type(value_type)

    # Bind the name for later inference: prefer the declared type, but narrow a
    # guard-unwrapped nullable/Option/Result to its success type.
    if has_declared:
        scope_set(scope, name, declared)
    else if has_value:
        scope_set(scope, name, narrowed)
    else:
        scope_set(scope, name, types.Type.ty_error)

    if is_let:
        scope_set_let(scope, name)


# =============================================================================
#  Expression type inference (conservative)
# =============================================================================

function infer_expr(ctx: ref[Context], scope: ref[Scope], ep: ptr[ast.Expr]) -> types.Type:
    unsafe:
        match read(ep):
            ast.Expr.expr_integer_literal:
                return types.primitive("int")
            ast.Expr.expr_float_literal:
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
                return infer_identifier(ctx, scope, id.name)
            ast.Expr.expr_binary_op as b:
                return infer_binary(ctx, scope, b.operator, b.left, b.right)
            ast.Expr.expr_unary_op as u:
                return infer_unary(ctx, scope, u.operator, u.operand)
            ast.Expr.expr_prefix_cast as c:
                let _inner = infer_expr(ctx, scope, c.expression)
                return resolve_type(ctx, c.target_type)
            ast.Expr.expr_member_access as ma:
                return resolve_member_access(ctx, scope, ma.receiver, ma.member_name, false, ma.line, ma.column)
            ast.Expr.expr_index_access as ix:
                let _rx = infer_expr(ctx, scope, ix.receiver)
                let _ix = infer_expr(ctx, scope, ix.index)
                return types.Type.ty_error
            ast.Expr.expr_call as call:
                return infer_and_check_call(ctx, scope, call.callee, call.args)
            ast.Expr.expr_specialization as spec:
                return check_specialization_call(ctx, scope, spec.callee, spec.arguments)
            _:
                return types.Type.ty_error


function infer_identifier(ctx: ref[Context], scope: ref[Scope], name: str) -> types.Type:
    let local = scope_get(scope, name)
    if local != null:
        unsafe:
            return read(local)
    let global = ctx.value_types.get(name)
    if global != null:
        unsafe:
            return read(global)
    return types.Type.ty_error


function infer_binary(ctx: ref[Context], scope: ref[Scope], op: str, left: ptr[ast.Expr], right: ptr[ast.Expr]) -> types.Type:
    # Always infer both operands so nested calls in either side are checked.
    let lt = infer_expr(ctx, scope, left)
    let rt = infer_expr(ctx, scope, right)
    if is_comparison_op(op) or op.equal("and") or op.equal("or"):
        return types.primitive("bool")
    if types.is_numeric(lt) and types.is_numeric(rt):
        return lt
    return types.Type.ty_error


function is_comparison_op(op: str) -> bool:
    return (
        op.equal("==") or op.equal("!=") or op.equal("<") or op.equal("<=")
        or op.equal(">") or op.equal(">=")
    )


function infer_unary(ctx: ref[Context], scope: ref[Scope], op: str, operand: ptr[ast.Expr]) -> types.Type:
    let ot = infer_expr(ctx, scope, operand)
    if op.equal("not"):
        return types.primitive("bool")
    if op.equal("-"):
        return ot
    return types.Type.ty_error


## Infer a call's result type and, when the callee is a local top-level
## function, check argument count and (positional) argument types.  When the
## callee names a local struct, treat it as a struct construction and validate
## named-field references instead.
function infer_and_check_call(ctx: ref[Context], scope: ref[Scope], callee: ptr[ast.Expr], args: span[ast.Argument]) -> types.Type:
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
                        return check_specialization_call(ctx, scope, spec.callee, spec.arguments)
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
function check_specialization_call(ctx: ref[Context], scope: ref[Scope], spec_callee: ptr[ast.Expr], type_args: span[ast.TypeArgument]) -> types.Type:
    unsafe:
        match read(spec_callee):
            ast.Expr.expr_identifier as id:
                if is_hook_name(id.name) and not ctx.functions.contains(id.name) and scope_get(scope, id.name) == null:
                    return check_hook_call(ctx, id.name, type_args, id.line, id.column)
                if id.name.equal("adapt") and not ctx.functions.contains(id.name) and scope_get(scope, id.name) == null:
                    return check_adapt_call(ctx, type_args)
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
        _:
            return t


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
    if not unsafe: read(alias_module_ptr).equal(struct_module):
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
        if qname_to_str(q).equal(iface_name):
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
        if q.parts.len == 1 and qname_to_str(q).equal(iface_name):
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
            if pg.name.equal("ref") and pg.args.len == 1:
                unify(unsafe: read(pg.args.data + 0), unwrap_ref(actual), subs)
            else:
                match actual:
                    types.Type.ty_generic as ag:
                        if pg.name.equal(ag.name) and pg.args.len == ag.args.len:
                            var i: ptr_uint = 0
                            while i < pg.args.len:
                                unsafe:
                                    unify(read(pg.args.data + i), read(ag.args.data + i), subs)
                                i += 1
                    _:
                        pass
        _:
            pass


function is_hook_name(name: str) -> bool:
    return name.equal("hash") or name.equal("equal") or name.equal("order") or name.equal("default")


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

    if hook_name.equal("hash"):
        return types.primitive("uint")
    if hook_name.equal("equal"):
        return types.primitive("bool")
    if hook_name.equal("order"):
        return types.primitive("int")
    return arg_type


## A call whose callee is `alias.member(...)` where `alias` names an imported
## module: check against the imported function signature (yielding its return
## type), or against an imported struct's fields (a cross-module construction).
## Anything else (local calls, unresolved aliases, non-exported members) is left
## to the local paths.
function try_imported_call(ctx: ref[Context], scope: ref[Scope], callee: ptr[ast.Expr], args: span[ast.Argument], arg_types: span[types.Type], any_named: bool) -> Option[types.Type]:
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
                            return Option[types.Type].some(value = sig.return_type)

                        let fields_ptr = read(binding_ptr).structs.get(ma.member_name)
                        if fields_ptr != null:
                            check_construction(ctx, ma.member_name, read(fields_ptr), args, ma.line, ma.column)
                            return Option[types.Type].some(value = types.Type.ty_imported(
                                module_name = read(module_name_ptr),
                                name = ma.member_name,
                            ))

                        return Option[types.Type].none
                    _:
                        return Option[types.Type].none
            _:
                return Option[types.Type].none


## Resolve `alias.member` where `alias` is an imported module and `member` is one
## of its exported values, yielding the value's type.  None for anything else.
function try_imported_member(ctx: ref[Context], scope: ref[Scope], receiver: ptr[ast.Expr], member: str) -> Option[types.Type]:
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
function check_member_call(ctx: ref[Context], scope: ref[Scope], receiver: ptr[ast.Expr], method_name: str, args: span[ast.Argument], arg_types: span[types.Type], any_named: bool, line: ptr_uint, column: ptr_uint) -> types.Type:
    match imported_static_member(ctx, scope, receiver, method_name, line, column):
        Option.some as imported_static:
            return imported_static.value
        Option.none:
            pass

    match static_type_receiver(ctx, scope, receiver):
        Option.some as tn:
            check_static_member(ctx, tn.value, method_name, line, column)
            return types.Type.ty_named(name = tn.value)
        Option.none:
            pass

    match static_struct_receiver_type(ctx, scope, receiver):
        Option.some as static_type:
            return check_typed_method_call(ctx, static_type.value, method_name, args, arg_types, any_named, line, column)
        Option.none:
            pass

    let recv = unwrap_ref(infer_expr(ctx, scope, receiver))
    check_editable_receiver_immutable(ctx, scope, receiver, recv, method_name, line, column)
    return check_typed_method_call(ctx, recv, method_name, args, arg_types, any_named, line, column)


## See through a `ref[T]` receiver to `T` for member access and method calls,
## matching the language's auto-dereference of `ref` receivers.
function unwrap_ref(t: types.Type) -> types.Type:
    match t:
        types.Type.ty_generic as g:
            if g.name.equal("ref") and g.args.len == 1:
                return unsafe: read(g.args.data + 0)
            return t
        _:
            return t


## Resolve and check a method call against a known receiver type (local or
## imported): argument-check the signature and flow its return type, or fall back
## to a member-existence check when no signature is known.
function check_typed_method_call(ctx: ref[Context], receiver_type: types.Type, method_name: str, args: span[ast.Argument], arg_types: span[types.Type], any_named: bool, line: ptr_uint, column: ptr_uint) -> types.Type:
    match resolve_method_sig(ctx, receiver_type, method_name):
        Option.some as sig:
            check_signature_call(ctx, method_name, sig.value, args, arg_types, any_named, line, column)
            return sig.value.return_type
        Option.none:
            return check_member(ctx, receiver_type, method_name, true, line, column)


## When the receiver is a `let`-bound value and the method is `editable`, flag the
## call.  `ref` (borrow) and `var` (mutable) receivers are fine.
function check_editable_receiver_immutable(ctx: ref[Context], scope: ref[Scope], receiver_expr: ptr[ast.Expr], receiver_type: types.Type, method_name: str, line: ptr_uint, column: ptr_uint) -> void:
    match resolve_method_sig(ctx, receiver_type, method_name):
        Option.some as sig:
            match sig.value.method_kind:
                ast.MethodKind.mk_editable:
                    unsafe:
                        match read(receiver_expr):
                            ast.Expr.expr_identifier as id:
                                # `this` in a method body is implicitly ref,
                                # never a local let binding.
                                if id.name.equal("this"):
                                    return
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
function static_struct_receiver_type(ctx: ref[Context], scope: ref[Scope], receiver: ptr[ast.Expr]) -> Option[types.Type]:
    unsafe:
        match read(receiver):
            ast.Expr.expr_identifier as id:
                if scope_get(scope, id.name) != null:
                    return Option[types.Type].none
                if ctx.structs.contains(id.name):
                    return Option[types.Type].some(value = types.Type.ty_named(name = id.name))
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
            return Option[FnSig].none
        types.Type.ty_imported as im:
            let binding_ptr = lookup_binding(ctx, im.module_name) else:
                return Option[FnSig].none
            unsafe:
                let sig_ptr = read(binding_ptr).method_sigs.get(method_key(im.name, method_name))
                if sig_ptr != null:
                    return Option[FnSig].some(value = read(sig_ptr))
            return Option[FnSig].none
        types.Type.ty_var as v:
            return resolve_constraint_method(ctx, v.name, method_name)
        types.Type.ty_str:
            return lookup_method_anywhere(ctx, "str", method_name)
        types.Type.ty_primitive as p:
            return lookup_method_anywhere(ctx, p.name, method_name)
        _:
            return Option[FnSig].none


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
    unsafe:
        var bindings = read(imported).values()
        while true:
            let binding_ptr = bindings.next() else:
                return Option[FnSig].none
            let sig_ptr = read(binding_ptr).method_sigs.get(key)
            if sig_ptr != null:
                return Option[FnSig].some(value = read(sig_ptr))


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
                            return Option[FnSig].some(value = build_fn_sig(ctx, m.value.name, m.value.method_params, m.value.return_type, m.value.method_kind))
                        Option.none:
                            pass
                Option.none:
                    pass
            i += 1
    return Option[FnSig].none


function interface_method_named(methods: span[ast.InterfaceMethod], name: str) -> Option[ast.InterfaceMethod]:
    var i: ptr_uint = 0
    while i < methods.len:
        var m: ast.InterfaceMethod
        unsafe:
            m = read(methods.data + i)
        if m.name.equal(name):
            return Option[ast.InterfaceMethod].some(value = m)
        i += 1
    return Option[ast.InterfaceMethod].none


## Dispatch a member access: a bare type-name receiver of an enum/flags/variant
## is a static member access (validate against members/arms/methods); anything
## else is an instance access (struct field/method or permissive).
function resolve_member_access(ctx: ref[Context], scope: ref[Scope], receiver: ptr[ast.Expr], member: str, is_method_call: bool, line: ptr_uint, column: ptr_uint) -> types.Type:
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
                            return types.Type.ty_named(name = tn.value)
                        Option.none:
                            let recv = unwrap_ref(infer_expr(ctx, scope, receiver))
                            return check_member(ctx, recv, member, is_method_call, line, column)


## Resolve `alias.Type.member` where `alias` is an imported module and `Type` is
## one of its exported enums/flags/variants: validate that `member` is a member
## of that type, flagging it otherwise.  None for anything else.
function imported_static_member(ctx: ref[Context], scope: ref[Scope], receiver: ptr[ast.Expr], member: str, line: ptr_uint, column: ptr_uint) -> Option[types.Type]:
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
                        return Option[types.Type].some(value = types.Type.ty_error)
                    _:
                        return Option[types.Type].none
            _:
                return Option[types.Type].none


function binding_has_member(binding: ModuleBinding, type_name: str, member: str) -> bool:
    return binding.member_keys.contains(method_key(type_name, member))


## Some(type name) when `receiver` is a bare identifier naming a locally-declared
## enum/flags/variant that is not shadowed by a local value.
function static_type_receiver(ctx: ref[Context], scope: ref[Scope], receiver: ptr[ast.Expr]) -> Option[str]:
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


## When `callee` is a bare identifier naming a locally-declared struct (not
## shadowed by a local value), validate each named-field argument and return
## the constructed struct type.  Returns none for ordinary function calls.
function try_construction(ctx: ref[Context], scope: ref[Scope], callee: ptr[ast.Expr], args: span[ast.Argument]) -> Option[types.Type]:
    unsafe:
        match read(callee):
            ast.Expr.expr_identifier as id:
                if scope_get(scope, id.name) != null:
                    return Option[types.Type].none
                let fieldsp = ctx.structs.get(id.name)
                if fieldsp == null:
                    return Option[types.Type].none
                check_construction(ctx, id.name, read(fieldsp), args, id.line, id.column)
                return Option[types.Type].some(value = types.Type.ty_named(name = id.name))
            _:
                return Option[types.Type].none


function check_construction(ctx: ref[Context], struct_name: str, fields: span[FieldEntry], args: span[ast.Argument], line: ptr_uint, column: ptr_uint) -> void:
    var i: ptr_uint = 0
    while i < args.len:
        var arg: ast.Argument
        unsafe:
            arg = read(args.data + i)
        match arg.arg_name:
            Option.some as nm:
                if not has_field(fields, nm.value):
                    report(ctx, line, column, unknown_member_message("field", struct_name, nm.value))
            Option.none:
                pass
        i += 1


function has_field(fields: span[FieldEntry], name: str) -> bool:
    var i: ptr_uint = 0
    while i < fields.len:
        unsafe:
            if read(fields.data + i).name.equal(name):
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
                # Not a locally-declared struct (enum/variant/opaque/imported).
                return types.Type.ty_error
            unsafe:
                let fields = read(fieldsp)
                var i: ptr_uint = 0
                while i < fields.len:
                    let fe = read(fields.data + i)
                    if fe.name.equal(member):
                        return fe.ty
                    i += 1
            if member.equal("with") or has_method(ctx, n.name, member):
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
    let binding_ptr = lookup_binding(ctx, module_name) else:
        return types.Type.ty_error

    unsafe:
        let fields_ptr = read(binding_ptr).structs.get(type_name)
        if fields_ptr != null:
            let fields = read(fields_ptr)
            var i: ptr_uint = 0
            while i < fields.len:
                let fe = read(fields.data + i)
                if fe.name.equal(member):
                    return fe.ty
                i += 1

        if member.equal("with") or binding_has_member(read(binding_ptr), type_name, member):
            return types.Type.ty_error

    if is_method_call:
        report(ctx, line, column, unknown_member_message("method", type_name, member))
    else:
        report(ctx, line, column, unknown_member_message("field", type_name, member))
    return types.Type.ty_error


## Check a call to a top-level function by identifier and yield its result type.
## For a generic function, type arguments are inferred from the call, validated
## against their constraints, and substituted into the return type.
function check_call(ctx: ref[Context], scope: ref[Scope], callee: ptr[ast.Expr], args: span[ast.Argument], arg_types: span[types.Type], any_named: bool) -> types.Type:
    unsafe:
        match read(callee):
            ast.Expr.expr_identifier as id:
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
                    unify_call_args(sig.params, arg_types, ref_of(subs))
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
    if arg_types.len != sig.params.len:
        report(ctx, line, column, arity_message(display_name, sig.params.len, arg_types.len))
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
    var buf = string.String.create()
    buf.append("return type mismatch: expected ")
    buf.append(types.type_to_string(expected))
    buf.append(", got ")
    buf.append(types.type_to_string(got))
    return buf.as_str()


function local_mismatch_message(expected: types.Type, got: types.Type) -> str:
    var buf = string.String.create()
    buf.append("type mismatch: cannot assign ")
    buf.append(types.type_to_string(got))
    buf.append(" to ")
    buf.append(types.type_to_string(expected))
    return buf.as_str()


function assign_message(target: types.Type, value: types.Type) -> str:
    var buf = string.String.create()
    buf.append("cannot assign ")
    buf.append(types.type_to_string(value))
    buf.append(" to ")
    buf.append(types.type_to_string(target))
    return buf.as_str()


function assign_to_let_message(name: str) -> str:
    var buf = string.String.create()
    buf.append("cannot assign to immutable binding ")
    buf.append(name)
    return buf.as_str()


function editable_on_immutable_message(name: str, method: str) -> str:
    var buf = string.String.create()
    buf.append("cannot call editable method ")
    buf.append(name)
    buf.append(".")
    buf.append(method)
    buf.append(" on an immutable value")
    return buf.as_str()


function missing_return_message(name: str) -> str:
    var buf = string.String.create()
    buf.append("function '")
    buf.append(name)
    buf.append("' does not always return a value")
    return buf.as_str()


function missing_cases_message(type_name: str, cases: str) -> str:
    var buf = string.String.create()
    buf.append("match on ")
    buf.append(type_name)
    buf.append(" is missing cases: ")
    buf.append(cases)
    return buf.as_str()


function integer_wildcard_message(type_name: str) -> str:
    var buf = string.String.create()
    buf.append("match on integer type ")
    buf.append(type_name)
    buf.append(" requires a wildcard arm (_:)")
    return buf.as_str()


function dup_case_message(type_name: str, member: str) -> str:
    var buf = string.String.create()
    buf.append("duplicate match arm ")
    buf.append(type_name)
    buf.append(".")
    buf.append(member)
    return buf.as_str()


function dup_value_message(value: int) -> str:
    var buf = string.String.create()
    buf.append("duplicate match arm value ")
    buf.append(int_to_str(value))
    return buf.as_str()


function int_to_str(value: int) -> str:
    if value < 0:
        return neg_int_to_str(value)
    return uint_to_str(ptr_uint<-value)


function neg_int_to_str(value: int) -> str:
    var buf = string.String.create()
    buf.append("-")
    buf.append(uint_to_str(ptr_uint<-(-value)))
    return buf.as_str()


function condition_message(keyword: str, got: types.Type) -> str:
    var buf = string.String.create()
    buf.append(keyword)
    buf.append(" condition must be bool, got ")
    buf.append(types.type_to_string(got))
    return buf.as_str()


function arity_message(name: str, expected: ptr_uint, got: ptr_uint) -> str:
    var buf = string.String.create()
    buf.append("function ")
    buf.append(name)
    buf.append(" expects ")
    buf.append(uint_to_str(expected))
    buf.append(" arguments, got ")
    buf.append(uint_to_str(got))
    return buf.as_str()


function unknown_member_message(kind: str, type_name: str, member: str) -> str:
    var buf = string.String.create()
    buf.append("unknown ")
    buf.append(kind)
    buf.append(" ")
    buf.append(type_name)
    buf.append(".")
    buf.append(member)
    return buf.as_str()


function missing_method_message(type_name: str, iface_name: str, method: str) -> str:
    var buf = string.String.create()
    buf.append(type_name)
    buf.append(" does not implement ")
    buf.append(iface_name)
    buf.append(": missing method ")
    buf.append(method)
    return buf.as_str()


function method_mismatch_message(type_name: str, iface_name: str, method: str) -> str:
    var buf = string.String.create()
    buf.append(type_name)
    buf.append(".")
    buf.append(method)
    buf.append(" does not match interface ")
    buf.append(iface_name)
    return buf.as_str()


function hook_missing_message(hook_name: str, type_name: str) -> str:
    var buf = string.String.create()
    buf.append(hook_name)
    buf.append("[")
    buf.append(type_name)
    buf.append("] requires ")
    buf.append(type_name)
    buf.append(".")
    buf.append(hook_name)
    return buf.as_str()


function constraint_unsatisfied_message(type_name: str, iface_name: str) -> str:
    var buf = string.String.create()
    buf.append("type argument ")
    buf.append(type_name)
    buf.append(" does not implement ")
    buf.append(iface_name)
    return buf.as_str()


function argument_message(param_name: str, fn_name: str, expected: types.Type, got: types.Type) -> str:
    var buf = string.String.create()
    buf.append("argument ")
    buf.append(param_name)
    buf.append(" to ")
    buf.append(fn_name)
    buf.append(" expects ")
    buf.append(types.type_to_string(expected))
    buf.append(", got ")
    buf.append(types.type_to_string(got))
    return buf.as_str()


function uint_to_str(value: ptr_uint) -> str:
    if value == 0:
        return "0"
    var digits = string.String.create()
    var n = value
    while n > 0:
        let d = n % 10
        digits.push_byte(ubyte<-(int<-d + 48))
        n = n / 10
    var rev = string.String.create()
    let raw = digits.as_str()
    var i = raw.len
    while i > 0:
        i -= 1
        rev.push_byte(raw.byte_at(i))
    return rev.as_str()
