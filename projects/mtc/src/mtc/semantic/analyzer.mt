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


struct FnSig:
    name: str
    params: span[types.Type]
    param_names: span[str]
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
        functions = map_mod.Map[str, FnSig].create(),
        value_types = map_mod.Map[str, types.Type].create(),
        diagnostics = vec.Vec[SemanticDiagnostic].create(),
    )
    declare_named_types(ref_of(ctx), file)
    collect_struct_fields(ref_of(ctx), file)
    declare_values_and_functions(ref_of(ctx), file)
    check_functions(ref_of(ctx), file)
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
    var param_types = vec.Vec[types.Type].create()
    var param_names = vec.Vec[str].create()
    var i: ptr_uint = 0
    while i < params.len:
        var p: ast.Param
        unsafe:
            p = read(params.data + i)
        param_types.push(resolve_type_value(ctx, p.param_type))
        param_names.push(p.name)
        i += 1
    let rt = return_type
    if rt != null:
        return FnSig(name = name, params = param_types.as_span(), param_names = param_names.as_span(),
            return_type = resolve_type(ctx, rt), has_return_type = true)
    return FnSig(name = name, params = param_types.as_span(), param_names = param_names.as_span(),
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
                check_function_body(ctx, fun.method_params, fun.return_type, fun.body)
            _:
                pass
        i += 1


function check_function_body(ctx: ref[Context], params: span[ast.Param], return_type: ptr[ast.TypeRef]?, body: ptr[ast.Stmt]?) -> void:
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
    check_stmt(ctx, ref_of(scope), ret, b)


function check_body(ctx: ref[Context], scope: ref[map_mod.Map[str, types.Type]], ret: types.Type, body: ptr[ast.Stmt]?) -> void:
    let b = body else:
        return
    check_stmt(ctx, scope, ret, b)


function check_stmt(ctx: ref[Context], scope: ref[map_mod.Map[str, types.Type]], ret: types.Type, sp: ptr[ast.Stmt]) -> void:
    unsafe:
        match read(sp):
            ast.Stmt.stmt_block as blk:
                check_stmt_span(ctx, scope, ret, blk.statements)
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
                    check_body(ctx, scope, ret, br.body)
                    bi += 1
                check_body(ctx, scope, ret, i.else_body)
            ast.Stmt.stmt_while as w:
                check_condition(ctx, scope, w.condition, "while", w.line, w.column)
                check_body(ctx, scope, ret, w.body)
            ast.Stmt.stmt_for as fr:
                bind_for_names(scope, fr.bindings)
                check_body(ctx, scope, ret, fr.body)
            ast.Stmt.stmt_match as m:
                var ai: ptr_uint = 0
                while ai < m.arms.len:
                    var arm: ast.MatchArm
                    arm = read(m.arms.data + ai)
                    check_body(ctx, scope, ret, arm.body)
                    ai += 1
            ast.Stmt.stmt_unsafe as u:
                check_body(ctx, scope, ret, u.body)
            ast.Stmt.stmt_defer as d:
                check_body(ctx, scope, ret, d.body)
            ast.Stmt.stmt_expression as e:
                let _ignored = infer_expr(ctx, scope, e.expression)
            ast.Stmt.stmt_assignment as a:
                let _target = infer_expr(ctx, scope, a.target)
                let _value = infer_expr(ctx, scope, a.value)
            _:
                pass


function check_condition(ctx: ref[Context], scope: ref[map_mod.Map[str, types.Type]], cond: ptr[ast.Expr], keyword: str, line: ptr_uint, column: ptr_uint) -> void:
    let ct = infer_expr(ctx, scope, cond)
    if types.is_definitely_non_bool(ct):
        report(ctx, line, column, condition_message(keyword, ct))


function check_stmt_span(ctx: ref[Context], scope: ref[map_mod.Map[str, types.Type]], ret: types.Type, stmts: span[ast.Stmt]) -> void:
    var i: ptr_uint = 0
    while i < stmts.len:
        unsafe:
            check_stmt(ctx, scope, ret, stmts.data + i)
        i += 1


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
                let recv = infer_expr(ctx, scope, ma.receiver)
                return struct_field_type(ctx, recv, ma.member_name)
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
            check_call(ctx, scope, callee, arg_types.as_span(), any_named)
            return callee_return_type(ctx, scope, callee)


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
                if not field_exists(fields, nm.value):
                    report(ctx, line, column, unknown_field_message(struct_name, nm.value))
            Option.none:
                pass
        i += 1


function field_exists(fields: span[FieldEntry], name: str) -> bool:
    var i: ptr_uint = 0
    while i < fields.len:
        unsafe:
            if read(fields.data + i).name.equal(name):
                return true
        i += 1
    return false


## Look up a field's type on a concretely-known local struct receiver.  Unknown
## members degrade to the permissive error type (they may be `extending`
## methods, which are not modeled yet), so member reads are never flagged.
function struct_field_type(ctx: ref[Context], receiver: types.Type, member: str) -> types.Type:
    match receiver:
        types.Type.ty_named as n:
            let fieldsp = ctx.structs.get(n.name)
            if fieldsp == null:
                return types.Type.ty_error
            unsafe:
                let fields = read(fieldsp)
                var i: ptr_uint = 0
                while i < fields.len:
                    let fe = read(fields.data + i)
                    if fe.name.equal(member):
                        return fe.ty
                    i += 1
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
                    let ptype = read(sig.params.data + i)
                    if types.definitely_incompatible(ptype, atype):
                        report(ctx, id.line, id.column, argument_message(read(sig.param_names.data + i), id.name, ptype, atype))
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


function unknown_field_message(struct_name: str, field_name: str) -> str:
    var buf = string.String.create()
    buf.append("unknown field ")
    buf.append(struct_name)
    buf.append(".")
    buf.append(field_name)
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
