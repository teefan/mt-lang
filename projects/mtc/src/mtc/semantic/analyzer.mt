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


struct ParamEntry:
    name: str
    ty: types.Type


struct FnSig:
    name: str
    params: span[ParamEntry]
    return_type: types.Type
    has_return_type: bool


struct FieldEntry:
    name: str
    ty: types.Type


struct Context:
    value_names: map_mod.Map[str, bool]
    type_names: map_mod.Map[str, bool]
    type_aliases: map_mod.Map[str, ptr[ast.TypeRef]]
    alias_types: map_mod.Map[str, types.Type]
    structs: map_mod.Map[str, span[FieldEntry]]
    method_keys: map_mod.Map[str, bool]
    static_member_types: map_mod.Map[str, bool]
    match_case_types: map_mod.Map[str, bool]
    match_case_names: map_mod.Map[str, span[str]]
    functions: map_mod.Map[str, FnSig]
    value_types: map_mod.Map[str, types.Type]
    diagnostics: vec.Vec[SemanticDiagnostic]


public function check_source_file(file: ast.SourceFile) -> vec.Vec[SemanticDiagnostic]:
    var ctx = Context(
        value_names = map_mod.Map[str, bool].create(),
        type_names = map_mod.Map[str, bool].create(),
        type_aliases = map_mod.Map[str, ptr[ast.TypeRef]].create(),
        alias_types = map_mod.Map[str, types.Type].create(),
        structs = map_mod.Map[str, span[FieldEntry]].create(),
        method_keys = map_mod.Map[str, bool].create(),
        static_member_types = map_mod.Map[str, bool].create(),
        match_case_types = map_mod.Map[str, bool].create(),
        match_case_names = map_mod.Map[str, span[str]].create(),
        functions = map_mod.Map[str, FnSig].create(),
        value_types = map_mod.Map[str, types.Type].create(),
        diagnostics = vec.Vec[SemanticDiagnostic].create(),
    )
    declare_named_types(ref_of(ctx), file)
    collect_struct_fields(ref_of(ctx), file)
    collect_extending_methods(ref_of(ctx), file)
    collect_enum_variant_members(ref_of(ctx), file)
    declare_values_and_functions(ref_of(ctx), file)
    check_functions(ref_of(ctx), file)
    check_extending_methods(ref_of(ctx), file)
    return ctx.diagnostics


function report(ctx: ref[Context], line: ptr_uint, column: ptr_uint, message: str) -> void:
    ctx.diagnostics.push(SemanticDiagnostic(line = line, column = column, message = message))


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
                    ctx.method_keys.set(method_key(base, m.name), true)
                    j += 1
            _:
                pass
        i += 1


function method_key(type_name: str, member: str) -> str:
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
                    ctx.functions.set(fun.name, build_fn_sig(ctx, fun.name, fun.method_params, fun.return_type))
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


function build_fn_sig(ctx: ref[Context], name: str, params: span[ast.Param], return_type: ptr[ast.TypeRef]?) -> FnSig:
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
            return_type = resolve_type(ctx, rt), has_return_type = true)
    return FnSig(name = name, params = param_entries.as_span(),
        return_type = types.primitive("void"), has_return_type = false)


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

    let name = qname_to_str(t.name)
    let base = resolve_named(ctx, name, t.arguments, depth)
    return wrap_nullable(base, t.nullable)


function wrap_nullable(base: types.Type, nullable: bool) -> types.Type:
    if nullable:
        return types.Type.ty_nullable(base = types.alloc_type(base))
    return base


function resolve_named(ctx: ref[Context], name: str, arguments: span[ast.TypeRef], depth: int) -> types.Type:
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


function qname_to_str(q: ast.QualifiedName) -> str:
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
                check_function_body(ctx, fun.name, fun.line, fun.method_params, fun.return_type, fun.body)
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


function check_method_body(ctx: ref[Context], this_type: types.Type, m: ast.Method) -> void:
    var scope = map_mod.Map[str, types.Type].create()
    if m.method_kind != ast.MethodKind.mk_static:
        scope.set("this", this_type)
    var pi: ptr_uint = 0
    while pi < m.method_params.len:
        var p: ast.Param
        unsafe:
            p = read(m.method_params.data + pi)
        scope.set(p.name, resolve_type_value(ctx, p.param_type))
        pi += 1
    var ret = types.primitive("void")
    let rt = m.return_type
    if rt != null:
        ret = resolve_type(ctx, rt)
    check_stmt(ctx, ref_of(scope), ret, false, m.body)
    if rt != null and not types.is_void(ret):
        if not terminates_ptr(ctx, m.body):
            report(ctx, m.line, m.column, missing_return_message(m.name))


function check_function_body(ctx: ref[Context], name: str, line: ptr_uint, params: span[ast.Param], return_type: ptr[ast.TypeRef]?, body: ptr[ast.Stmt]?) -> void:
    let b = body else:
        return
    var scope = map_mod.Map[str, types.Type].create()
    var pi: ptr_uint = 0
    while pi < params.len:
        var p: ast.Param
        unsafe:
            p = read(params.data + pi)
        scope.set(p.name, resolve_type_value(ctx, p.param_type))
        pi += 1
    var ret = types.primitive("void")
    let rt = return_type
    if rt != null:
        ret = resolve_type(ctx, rt)
    check_stmt(ctx, ref_of(scope), ret, false, b)
    if rt != null and not types.is_void(ret):
        if not terminates_ptr(ctx, b):
            report(ctx, line, 1, missing_return_message(name))


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


function check_body(ctx: ref[Context], scope: ref[map_mod.Map[str, types.Type]], ret: types.Type, in_loop: bool, body: ptr[ast.Stmt]?) -> void:
    let b = body else:
        return
    check_stmt(ctx, scope, ret, in_loop, b)


function check_stmt(ctx: ref[Context], scope: ref[map_mod.Map[str, types.Type]], ret: types.Type, in_loop: bool, sp: ptr[ast.Stmt]) -> void:
    unsafe:
        match read(sp):
            ast.Stmt.stmt_block as blk:
                check_stmt_span(ctx, scope, ret, in_loop, blk.statements)
            ast.Stmt.stmt_ret as r:
                let rv = r.value
                if rv != null:
                    let vt = infer_expr(ctx, scope, rv)
                    if types.definitely_incompatible(ret, vt):
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
                bind_for_names(scope, fr.bindings)
                check_body(ctx, scope, ret, true, fr.body)
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
                if a.operator.equal("=") and types.definitely_incompatible(tt, vt):
                    report(ctx, a.line, a.column, assign_message(tt, vt))
            _:
                pass


function check_condition(ctx: ref[Context], scope: ref[map_mod.Map[str, types.Type]], cond: ptr[ast.Expr], keyword: str, line: ptr_uint, column: ptr_uint) -> void:
    let ct = infer_expr(ctx, scope, cond)
    if types.is_definitely_non_bool(ct):
        report(ctx, line, column, condition_message(keyword, ct))


function check_stmt_span(ctx: ref[Context], scope: ref[map_mod.Map[str, types.Type]], ret: types.Type, in_loop: bool, stmts: span[ast.Stmt]) -> void:
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
function check_match(ctx: ref[Context], scope: ref[map_mod.Map[str, types.Type]], scrutinee: ptr[ast.Expr], arms: span[ast.MatchArm], line: ptr_uint, column: ptr_uint) -> void:
    let st = infer_expr(ctx, scope, scrutinee)
    match st:
        types.Type.ty_named as n:
            if ctx.match_case_types.contains(n.name):
                check_case_match(ctx, n.name, arms, line, column)
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
    return (
        name.equal("byte") or name.equal("short") or name.equal("int") or name.equal("long")
        or name.equal("ubyte") or name.equal("ushort") or name.equal("uint") or name.equal("ulong")
        or name.equal("ptr_int") or name.equal("ptr_uint")
    )


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


function bind_for_names(scope: ref[map_mod.Map[str, types.Type]], bindings: span[ast.ForBinding]) -> void:
    var i: ptr_uint = 0
    while i < bindings.len:
        unsafe:
            scope.set(read(bindings.data + i).name, types.Type.ty_error)
        i += 1


function check_local(ctx: ref[Context], scope: ref[map_mod.Map[str, types.Type]], is_let: bool, name: str, stmt_type: ptr[ast.TypeRef]?, value: ptr[ast.Expr]?, destructure_bindings: Option[span[str]], line: ptr_uint, column: ptr_uint) -> void:
    let _unused = is_let
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
        if types.definitely_incompatible(declared, value_type):
            report(ctx, line, column, local_mismatch_message(declared, value_type))

    # Bind the name for later inference: prefer the declared type.
    if has_declared:
        scope.set(name, declared)
    else if has_value:
        scope.set(name, value_type)
    else:
        scope.set(name, types.Type.ty_error)


# =============================================================================
#  Expression type inference (conservative)
# =============================================================================

function infer_expr(ctx: ref[Context], scope: ref[map_mod.Map[str, types.Type]], ep: ptr[ast.Expr]) -> types.Type:
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
            _:
                return types.Type.ty_error


function infer_identifier(ctx: ref[Context], scope: ref[map_mod.Map[str, types.Type]], name: str) -> types.Type:
    let local = scope.get(name)
    if local != null:
        unsafe:
            return read(local)
    let global = ctx.value_types.get(name)
    if global != null:
        unsafe:
            return read(global)
    return types.Type.ty_error


function infer_binary(ctx: ref[Context], scope: ref[map_mod.Map[str, types.Type]], op: str, left: ptr[ast.Expr], right: ptr[ast.Expr]) -> types.Type:
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


function infer_unary(ctx: ref[Context], scope: ref[map_mod.Map[str, types.Type]], op: str, operand: ptr[ast.Expr]) -> types.Type:
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
function infer_and_check_call(ctx: ref[Context], scope: ref[map_mod.Map[str, types.Type]], callee: ptr[ast.Expr], args: span[ast.Argument]) -> types.Type:
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

    match try_construction(ctx, scope, callee, args):
        Option.some as ct:
            return ct.value
        Option.none:
            check_method_callee(ctx, scope, callee)
            check_call(ctx, scope, callee, arg_types.as_span(), any_named)
            return callee_return_type(ctx, scope, callee)


## When a call's callee is member access on a local struct instance
## (`value.method(...)`), validate the method exists; unknown members are
## reported as "unknown method".  Non-member callees are recursed for nested
## call checks.
function check_method_callee(ctx: ref[Context], scope: ref[map_mod.Map[str, types.Type]], callee: ptr[ast.Expr]) -> void:
    unsafe:
        match read(callee):
            ast.Expr.expr_member_access as ma:
                let _t = resolve_member_access(ctx, scope, ma.receiver, ma.member_name, true, ma.line, ma.column)
            ast.Expr.expr_identifier:
                pass
            _:
                let _c = infer_expr(ctx, scope, callee)


## Dispatch a member access: a bare type-name receiver of an enum/flags/variant
## is a static member access (validate against members/arms/methods); anything
## else is an instance access (struct field/method or permissive).
function resolve_member_access(ctx: ref[Context], scope: ref[map_mod.Map[str, types.Type]], receiver: ptr[ast.Expr], member: str, is_method_call: bool, line: ptr_uint, column: ptr_uint) -> types.Type:
    match static_type_receiver(ctx, scope, receiver):
        Option.some as tn:
            check_static_member(ctx, tn.value, member, line, column)
            return types.Type.ty_named(name = tn.value)
        Option.none:
            let recv = infer_expr(ctx, scope, receiver)
            return check_member(ctx, recv, member, is_method_call, line, column)


## Some(type name) when `receiver` is a bare identifier naming a locally-declared
## enum/flags/variant that is not shadowed by a local value.
function static_type_receiver(ctx: ref[Context], scope: ref[map_mod.Map[str, types.Type]], receiver: ptr[ast.Expr]) -> Option[str]:
    unsafe:
        match read(receiver):
            ast.Expr.expr_identifier as id:
                if scope.get(id.name) != null:
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
function try_construction(ctx: ref[Context], scope: ref[map_mod.Map[str, types.Type]], callee: ptr[ast.Expr], args: span[ast.Argument]) -> Option[types.Type]:
    unsafe:
        match read(callee):
            ast.Expr.expr_identifier as id:
                if scope.get(id.name) != null:
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
        _:
            return types.Type.ty_error


function check_call(ctx: ref[Context], scope: ref[map_mod.Map[str, types.Type]], callee: ptr[ast.Expr], arg_types: span[types.Type], any_named: bool) -> void:
    unsafe:
        match read(callee):
            ast.Expr.expr_identifier as id:
                # A local value (e.g. a proc) of the same name shadows the
                # function; its arity/parameter types are not statically known.
                if scope.get(id.name) != null:
                    return
                let sigp = ctx.functions.get(id.name)
                if sigp == null:
                    return
                let sig = read(sigp)
                if arg_types.len != sig.params.len:
                    report(ctx, id.line, id.column, arity_message(id.name, sig.params.len, arg_types.len))
                    return
                # Named arguments may be reordered; positional type checking is
                # only sound for all-positional calls.
                if any_named:
                    return
                var i: ptr_uint = 0
                while i < arg_types.len:
                    let atype = read(arg_types.data + i)
                    let pe = read(sig.params.data + i)
                    if types.definitely_incompatible(pe.ty, atype):
                        report(ctx, id.line, id.column, argument_message(pe.name, id.name, pe.ty, atype))
                    i += 1
            _:
                pass


function callee_return_type(ctx: ref[Context], scope: ref[map_mod.Map[str, types.Type]], callee: ptr[ast.Expr]) -> types.Type:
    unsafe:
        match read(callee):
            ast.Expr.expr_identifier as id:
                if scope.get(id.name) != null:
                    return types.Type.ty_error
                let sigp = ctx.functions.get(id.name)
                if sigp != null:
                    return read(sigp).return_type
                return types.Type.ty_error
            _:
                return types.Type.ty_error


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
