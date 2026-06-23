## Checker — semantic analysis: name binding + type checking + diagnostics.
##
## Names are resolved via parent-chained scopes.  Top-level
## functions and types are stored in global_scope; function bodies
## create child scopes that chain to global.  Return types are
## recorded in function_types for call resolution.

import compiler.parser.ast as ast
import compiler.parser.operators as ops_mod
import compiler.sema.primitive_kind as pk
import compiler.sema.scope as scope_mod
import compiler.sema.type_registry as reg
import compiler.sema.types as types_mod
import std.intern
import std.map
import std.vec

public type TypeId = reg.TypeId
public type IdentId = ast.IdentId

type P = pk.PrimitiveKind
type B = ops_mod.BinaryOp


public struct Checker:
    registry: reg.Registry
    types: types_mod.Types
    global_scope: scope_mod.Scope
    type_names: map.Map[IdentId, TypeId]
    ## return type for each named function / method (used by check_call)
    function_types: map.Map[IdentId, TypeId]
    ## struct field types: (struct_type_id, field_name) → field_type_id
    struct_fields: map.Map[IdentId, TypeId]
    int_id: TypeId
    float_id: TypeId
    bool_id: TypeId
    void_id: TypeId
    str_id: TypeId
    errors: vec.Vec[str]


public function create(
    registry: reg.Registry,
    interner_ref: ref[intern.Interner],
) -> Checker:
    var reg_copy = registry
    var c = Checker(
        registry = reg_copy,
        types = types_mod.create(ref_of(reg_copy)),
        global_scope = scope_mod.create(null),
        type_names = map.Map[IdentId, TypeId].with_capacity(32),
        function_types = map.Map[IdentId, TypeId].with_capacity(64),
        struct_fields = map.Map[IdentId, TypeId].with_capacity(64),
        int_id = TypeId<-0,
        float_id = TypeId<-0,
        bool_id = TypeId<-0,
        void_id = TypeId<-0,
        str_id = TypeId<-0,
        errors = vec.Vec[str].create(),
    )
    c.init_builtins(interner_ref)
    return c


extending Checker:
    public editable function check(file: ptr[ast.SourceFile]) -> bool:
        unsafe:
            let decls_span = file.decls.as_span()
            var i: ptr_uint = 0
            while i < decls_span.len:
                let decl_ptr = read(decls_span.data + i)
                this.check_decl(decl_ptr)
                i += 1
        return this.errors.len == 0


    editable function init_builtins(interner_ref: ref[intern.Interner]) -> void:
        this.int_id = this.registry.primitive(P.pk_int)
        this.float_id = this.registry.primitive(P.pk_float)
        this.bool_id = this.registry.primitive(P.pk_bool)
        this.void_id = this.registry.primitive(P.pk_void)
        this.str_id = this.registry.primitive(P.pk_str)
        this.register_typename(interner_ref.intern("int"), this.int_id)
        this.register_typename(interner_ref.intern("float"), this.float_id)
        this.register_typename(interner_ref.intern("bool"), this.bool_id)
        this.register_typename(interner_ref.intern("void"), this.void_id)
        this.register_typename(interner_ref.intern("str"), this.str_id)


    editable function register_typename(name: IdentId, tid: TypeId) -> void:
        let _ = this.type_names.set(name, tid)


    editable function check_decl(decl: ptr[ast.Decl]) -> void:
        unsafe:
            match read(decl):
                ast.Decl.function_def(_):
                    this.check_function(decl)
                ast.Decl.struct_decl(name, fields, _, _):
                    this.check_struct(name, fields)
                ast.Decl.enum_decl(name, backing, members, _, _):
                    this.check_enum(name, backing, members)
                ast.Decl.extending_decl(type_name, methods, _):
                    this.check_extending(type_name, methods)
                ast.Decl.type_alias(name, target, _, _):
                    this.check_type_alias(name, target)
                ast.Decl.import_decl(_):
                    pass
                _:
                    pass


    editable function check_struct(name: ast.IdentId, fields: span[ast.Field]) -> void:
        let tid = this.registry.named_type(name)
        this.register_typename(name, tid)
        var i: ptr_uint = 0
        while i < fields.len:
            unsafe:
                let field = read(fields.data + i)
                let ft = this.resolve_type(field.type_ref)
                if ft == TypeId<-0:
                    let _ = this.add_error("unknown type in struct field")
                let _ = this.struct_fields.set(this.struct_field_key(tid, field.name), ft)
            i += 1


    function struct_field_key(struct_tid: TypeId, field_name: IdentId) -> IdentId:
        return ptr_uint<-struct_tid ^ field_name


    editable function check_enum(
        name: ast.IdentId,
        backing_type: ptr[ast.Type],
        members: span[ast.EnumMember],
    ) -> void:
        let tid = this.registry.named_type(name)
        this.register_typename(name, tid)


    editable function check_type_alias(name: ast.IdentId, target: ptr[ast.Type]) -> void:
        let tid = this.resolve_type(target)
        this.register_typename(name, tid)
        this.registry.set_alias(name, tid)


    editable function check_extending(type_name: ast.IdentId, methods: span[ast.ExtendingMethod]) -> void:
        let _ = this.lookup_typename(type_name)
        var mi: ptr_uint = 0
        while mi < methods.len:
            unsafe:
                let method = read(methods.data + mi)
                var fn_scope = scope_mod.create(ptr_of(this.global_scope))
                let scope_ptr = ptr_of(fn_scope)
                this.bind_params(method.params, scope_ptr)
                let ret_id = this.resolve_type(method.return_type)
                let _ = this.function_types.set(method.name, ret_id)
                this.check_block(method.body, scope_ptr, ret_id)
            mi += 1


    editable function check_function(decl: ptr[ast.Decl]) -> void:
        unsafe:
            match read(decl):
                ast.Decl.function_def(name, _, params, return_type, body, _, _, _, _):
                    var fn_scope = scope_mod.create(ptr_of(this.global_scope))
                    let scope_ptr = ptr_of(fn_scope)
                    this.bind_params(params, scope_ptr)
                    let ret_id = this.resolve_type(return_type)
                    if ret_id == TypeId<-0:
                        let _ = this.add_error("unknown return type")
                    let _ = this.function_types.set(name, ret_id)
                    let glob_ptr = ptr_of(this.global_scope)
                    scope_mod.define(glob_ptr, name, ret_id)
                    if body != zero[ptr[ast.Stmt]]:
                        this.check_block(body, scope_ptr, ret_id)
                _:
                    pass


    editable function bind_params(
        params: span[ast.Param],
        scope: ptr[scope_mod.Scope],
    ) -> void:
        var i: ptr_uint = 0
        while i < params.len:
            unsafe:
                let param = read(params.data + i)
                let tid = this.resolve_type(param.type_ref)
                scope_mod.define(scope, param.name, tid)
            i += 1


    editable function resolve_type(type_ref: ptr[ast.Type]) -> TypeId:
        if type_ref == zero[ptr[ast.Type]]:
            return this.void_id
        unsafe:
            match read(type_ref):
                ast.Type.named_type(name, _):
                    return this.lookup_typename(name)
                ast.Type.pointer_type(pointee, is_const, _):
                    let inner = this.resolve_type(pointee)
                    return this.registry.pointer(inner, is_const)
                ast.Type.ref_type(pointee, _):
                    let inner = this.resolve_type(pointee)
                    return this.registry.ref(inner)
                ast.Type.span_type(element, _):
                    let inner = this.resolve_type(element)
                    return this.registry.span(inner)
                ast.Type.array_type(element, size, _):
                    let inner = this.resolve_type(element)
                    return this.registry.array(inner, size)
                ast.Type.nullable_type(inner, _):
                    let inner_tid = this.resolve_type(inner)
                    return this.registry.nullable(inner_tid)
                _:
                    return TypeId<-0


    function lookup_typename(name: IdentId) -> TypeId:
        let found = this.type_names.get(name)
        if found == null:
            return TypeId<-0
        unsafe:
            return read(found)


    editable function check_block(
        stmt: ptr[ast.Stmt],
        scope: ptr[scope_mod.Scope],
        expected_ret: TypeId,
    ) -> void:
        unsafe:
            match read(stmt):
                ast.Stmt.block(stmts, _):
                    var i: ptr_uint = 0
                    while i < stmts.len:
                        let s = read(stmts.data + i)
                        this.check_stmt(s, scope, expected_ret)
                        i += 1
                _:
                    pass


    editable function check_stmt(
        stmt: ptr[ast.Stmt],
        scope: ptr[scope_mod.Scope],
        expected_ret: TypeId,
    ) -> void:
        unsafe:
            match read(stmt):
                ast.Stmt.return_stmt(value, _):
                    this.check_return(value, scope, expected_ret)
                ast.Stmt.expression(expr, _):
                    let _ = this.check_expr(expr, scope)
                ast.Stmt.local_decl(_, name, type_ref, value, else_binding, else_body, _):
                    var tid = this.resolve_type(type_ref)
                    if tid == TypeId<-0 and value != zero[ptr[ast.Expr]]:
                        tid = this.check_expr(value, scope)
                    scope_mod.define(scope, name, tid)
                    if else_body != zero[ptr[ast.Stmt]]:
                        this.check_block(else_body, scope, this.void_id)
                ast.Stmt.if_stmt(branches, else_body, _):
                    var bi: ptr_uint = 0
                    while bi < branches.len:
                        let br = unsafe: read(branches.data + bi)
                        let _ = this.check_expr(br.condition, scope)
                        this.check_block(br.body, scope, expected_ret)
                        bi += 1
                    if else_body != zero[ptr[ast.Stmt]]:
                        this.check_block(else_body, scope, expected_ret)
                ast.Stmt.while_stmt(condition, body, _):
                    let _ = this.check_expr(condition, scope)
                    this.check_block(body, scope, expected_ret)
                ast.Stmt.unsafe_block(body, _):
                    this.check_block(body, scope, expected_ret)
                ast.Stmt.assignment(target, _, value, _):
                    let _ = this.check_expr(target, scope)
                    let _ = this.check_expr(value, scope)
                ast.Stmt.match_stmt(scrutinee, arms, _):
                    let _ = this.check_expr(scrutinee, scope)
                    var mi: ptr_uint = 0
                    while mi < arms.len:
                        let arm = unsafe: read(arms.data + mi)
                        this.check_block(arm.body, scope, expected_ret)
                        mi += 1
                ast.Stmt.for_stmt(_, iterables, body, _):
                    var ii: ptr_uint = 0
                    while ii < iterables.len:
                        let _ = this.check_expr(unsafe: read(iterables.data + ii), scope)
                        ii += 1
                    this.check_block(body, scope, expected_ret)
                _:
                    pass


    editable function check_return(
        value: ptr[ast.Expr],
        scope: ptr[scope_mod.Scope],
        expected_ret: TypeId,
    ) -> void:
        if expected_ret == this.void_id:
            return
        let actual = this.check_expr(value, scope)
        let unknown: TypeId = TypeId<-0
        if actual != unknown and actual != this.void_id and actual != expected_ret:
            let _ = this.add_error("return type mismatch")


    function check_expr(
        expr: ptr[ast.Expr],
        scope: ptr[scope_mod.Scope],
    ) -> TypeId:
        unsafe:
            match read(expr):
                ast.Expr.integer_literal(_, _):
                    return this.int_id
                ast.Expr.float_literal(_, _):
                    return this.float_id
                ast.Expr.string_literal(_, _, _):
                    return this.str_id
                ast.Expr.bool_literal(_, _):
                    return this.bool_id
                ast.Expr.char_literal(_, _):
                    return this.int_id
                ast.Expr.identifier(name, _):
                    let tid = scope_mod.lookup(scope, name) else:
                        return TypeId<-0
                    return tid
                ast.Expr.binary_op(operator, left, right, _):
                    return this.check_binary(operator, left, right, scope)
                ast.Expr.call(callee, args, _):
                    return this.check_call(callee, args, scope)
                ast.Expr.unary_op(_, operand, _):
                    return this.check_expr(operand, scope)
                ast.Expr.member_access(receiver, member, _):
                    return this.check_member(receiver, member, scope)
                ast.Expr.null_literal(_):
                    return TypeId<-0
                ast.Expr.aggregate(type_name, _, _):
                    return this.lookup_typename(type_name)
                ast.Expr.cast_expr(target_type, expr, _):
                    let _ = this.check_expr(expr, scope)
                    unsafe:
                        match read(target_type):
                            ast.Type.named_type(name, _):
                                return this.lookup_typename(name)
                            _:
                                return TypeId<-0
                _:
                    return TypeId<-0


    function check_binary(
        op: B,
        left: ptr[ast.Expr],
        right: ptr[ast.Expr],
        scope: ptr[scope_mod.Scope],
    ) -> TypeId:
        let lt = this.check_expr(left, scope)
        let rt = this.check_expr(right, scope)
        if op == B.op_eq or op == B.op_ne or
           op == B.op_lt or op == B.op_le or
           op == B.op_gt or op == B.op_ge:
            return this.bool_id
        if op == B.op_logic_and or op == B.op_logic_or:
            return this.bool_id
        if lt == this.float_id or rt == this.float_id:
            return this.float_id
        return this.int_id


    function check_call(
        callee: ptr[ast.Expr],
        args: span[ptr[ast.Expr]],
        scope: ptr[scope_mod.Scope],
    ) -> TypeId:
        var ret: TypeId = TypeId<-0
        unsafe:
            match read(callee):
                ast.Expr.identifier(name, _):
                    let stored = this.function_types.get(name)
                    if stored != null:
                        ret = read(stored)
                _:
                    pass
        let _ = this.check_expr(callee, scope)
        var i: ptr_uint = 0
        while i < args.len:
            unsafe:
                let arg = read(args.data + i)
                let _ = this.check_expr(arg, scope)
            i += 1
        return ret


    function check_member(
        receiver: ptr[ast.Expr],
        member: ast.IdentId,
        scope: ptr[scope_mod.Scope],
    ) -> TypeId:
        let recv_tid = this.check_expr(receiver, scope)
        if recv_tid == TypeId<-0:
            return TypeId<-0
        let key = this.struct_field_key(recv_tid, member)
        let ft = this.struct_fields.get(key)
        if ft == null:
            return TypeId<-0
        unsafe:
            return read(ft)


    editable function add_error(msg: str) -> ptr_uint:
        this.errors.push(msg)
        return 0
