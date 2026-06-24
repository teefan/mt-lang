## Lowerer — AST → IR transformation.
##
## Types are resolved via the shared type registry.  IdentId
## values (interned string handles) are compared by integer
## equality — zero str comparisons in the hot path.

import compiler.lexer.token_kind as tk
import compiler.parser.ast as ast
import compiler.parser.operators as ops_mod
import compiler.lowering.ir as ir
import compiler.sema.primitive_kind as pk
import compiler.sema.type_registry as reg
import std.intern
import std.map
import std.mem.arena
import std.str
import std.vec

type B = ops_mod.BinaryOp
type P = pk.PrimitiveKind


struct Lowerer:
    arena: arena.Arena
    interner: ptr[intern.Interner]
    registry: reg.Registry
    void_tid: reg.TypeId
    in_editable: bool

    ## Pre-interned identifiers — integer comparison only, zero str ops.
    id_void: ast.IdentId
    id_bool: ast.IdentId
    id_byte: ast.IdentId
    id_ubyte: ast.IdentId
    id_char: ast.IdentId
    id_short: ast.IdentId
    id_ushort: ast.IdentId
    id_int: ast.IdentId
    id_uint: ast.IdentId
    id_long: ast.IdentId
    id_ulong: ast.IdentId
    id_ptr_int: ast.IdentId
    id_ptr_uint: ast.IdentId
    id_float: ast.IdentId
    id_double: ast.IdentId
    id_str: ast.IdentId
    id_cstr: ast.IdentId
    id_vec2: ast.IdentId
    id_vec3: ast.IdentId
    id_vec4: ast.IdentId
    id_ivec2: ast.IdentId
    id_ivec3: ast.IdentId
    id_ivec4: ast.IdentId
    id_mat3: ast.IdentId
    id_mat4: ast.IdentId
    id_quat: ast.IdentId

    id_fatal: ast.IdentId
    id_read: ast.IdentId
    id_ptr_of: ast.IdentId
    id_zero: ast.IdentId

    extending_type: ast.IdentId
    extending_cname: str
    name_buf: str_buffer[128]
    var_types: map.Map[ast.IdentId, ast.IdentId]

    enum_names: vec.Vec[ast.IdentId]


public function lower(
    file: ptr[ast.SourceFile],
    interner: ptr[intern.Interner],
    registry: reg.Registry,
) -> ir.IrProgram:
    var l = Lowerer(
        arena = arena.create(64 * 1024),
        interner = interner,
        registry = registry,
        void_tid = registry.primitive(P.pk_void),
        in_editable = false,
        extending_type = 0,
        extending_cname = "",
        name_buf = zero[str_buffer[128]],
        var_types = map.Map[ast.IdentId, ast.IdentId].with_capacity(32),
        enum_names = vec.Vec[ast.IdentId].with_capacity(8),
        id_void = 0, id_bool = 0, id_byte = 0, id_ubyte = 0,
        id_char = 0, id_short = 0, id_ushort = 0,
        id_int = 0, id_uint = 0, id_long = 0, id_ulong = 0,
        id_ptr_int = 0, id_ptr_uint = 0,
        id_float = 0, id_double = 0,
        id_str = 0, id_cstr = 0,
        id_vec2 = 0, id_vec3 = 0, id_vec4 = 0,
        id_ivec2 = 0, id_ivec3 = 0, id_ivec4 = 0,
        id_mat3 = 0, id_mat4 = 0, id_quat = 0,
        id_fatal = 0, id_read = 0, id_ptr_of = 0, id_zero = 0,
    )
    l.init_interned_ids()
    return l.lower_impl(file)


extending Lowerer:
    editable function init_interned_ids() -> void:
        unsafe:
            this.id_void     = this.interner.intern("void")
            this.id_bool     = this.interner.intern("bool")
            this.id_byte     = this.interner.intern("byte")
            this.id_ubyte    = this.interner.intern("ubyte")
            this.id_char     = this.interner.intern("char")
            this.id_short    = this.interner.intern("short")
            this.id_ushort   = this.interner.intern("ushort")
            this.id_int      = this.interner.intern("int")
            this.id_uint     = this.interner.intern("uint")
            this.id_long     = this.interner.intern("long")
            this.id_ulong    = this.interner.intern("ulong")
            this.id_ptr_int  = this.interner.intern("ptr_int")
            this.id_ptr_uint = this.interner.intern("ptr_uint")
            this.id_float    = this.interner.intern("float")
            this.id_double   = this.interner.intern("double")
            this.id_str      = this.interner.intern("str")
            this.id_cstr     = this.interner.intern("cstr")
            this.id_vec2     = this.interner.intern("vec2")
            this.id_vec3     = this.interner.intern("vec3")
            this.id_vec4     = this.interner.intern("vec4")
            this.id_ivec2    = this.interner.intern("ivec2")
            this.id_ivec3    = this.interner.intern("ivec3")
            this.id_ivec4    = this.interner.intern("ivec4")
            this.id_mat3     = this.interner.intern("mat3")
            this.id_mat4     = this.interner.intern("mat4")
            this.id_quat     = this.interner.intern("quat")
            this.id_fatal    = this.interner.intern("fatal")
            this.id_read     = this.interner.intern("read")
            this.id_ptr_of   = this.interner.intern("ptr_of")
            this.id_zero     = this.interner.intern("zero")


extending Lowerer:
    editable function lower_impl(file: ptr[ast.SourceFile]) -> ir.IrProgram:
        var functions = vec.Vec[ir.IrFunction].create()
        var structs = vec.Vec[ir.IrStruct].create()
        var enums = vec.Vec[ir.IrEnum].create()
        var variants = vec.Vec[ir.IrVariant].create()
        let decls_span = unsafe: file.decls.as_span()
        var i: ptr_uint = 0
        while i < decls_span.len:
            let decl = unsafe: read(decls_span.data + i)
            unsafe:
                match read(decl):
                    ast.Decl.function_def(name, _, params, return_type, body, _, _, _, _):
                        let f = this.lower_function(name, params, return_type, body)
                        functions.push(f)
                    ast.Decl.struct_decl(name, fields, _, _):
                        let s = this.lower_struct(name, fields)
                        structs.push(s)
                    ast.Decl.enum_decl(name, _, members, _, _):
                        let e = this.lower_enum(name, members)
                        enums.push(e)
                    ast.Decl.extending_decl(type_name, methods, _):
                        this.lower_extending(type_name, methods, ref_of(functions))
                    ast.Decl.type_alias(name, target, _, _):
                        let tid = this.resolve_type_id(target)
                        this.registry.register_named_with_id(name, tid)
                    ast.Decl.import_decl(_):
                        pass
                    ast.Decl.const_decl(_, _, _, _, _):
                        pass
                    ast.Decl.var_decl(_, _, _, _, _):
                        pass
                    ast.Decl.variant_decl(name, arms, _, _):
                        let v = this.lower_variant(name, arms)
                        variants.push(v)
                    ast.Decl.error_decl(_):
                        pass
                    _:
                        pass
            i += 1
        var span_list = vec.Vec[ir.IrSpanType].create()
        var span_rev = this.registry.span_rev.as_span()
        var si: ptr_uint = 0
        while si < span_rev.len:
            let entry = unsafe: read(span_rev.data + si)
            span_list.push(ir.IrSpanType(type_id = entry.id, element_type = entry.element))
            si += 1
        return ir.IrProgram(
            structs = this.copy_structs(ref_of(structs)),
            enums = this.copy_enums(ref_of(enums)),
            variants = this.copy_variants(ref_of(variants)),
            spans = this.copy_span_types(ref_of(span_list)),
            functions = this.copy_funcs(ref_of(functions)),
        )


    editable function lower_struct(name: ast.IdentId, fields: span[ast.Field]) -> ir.IrStruct:
        let cname = this.name_str(name)
        let tid = this.registry.named_type(name)
        var ir_fields = vec.Vec[ir.IrField].create()
        var i: ptr_uint = 0
        while i < fields.len:
            let field = unsafe: read(fields.data + i)
            ir_fields.push(ir.IrField(
                name = this.name_str(field.name),
                type_id = this.resolve_type_id(field.type_ref),
            ))
            i += 1
        return ir.IrStruct(
            name = cname,
            type_id = tid,
            fields = this.copy_fields(ref_of(ir_fields)),
        )


    editable function lower_enum(name: ast.IdentId, members: span[ast.EnumMember]) -> ir.IrEnum:
        let cname = this.name_str(name)
        let tid = this.registry.named_type(name)
        this.enum_names.push(name)
        var ir_members = vec.Vec[ir.IrEnumMember].create()
        var autoval: int = 0
        var i: ptr_uint = 0
        while i < members.len:
            let m = unsafe: read(members.data + i)
            var val: int = autoval
            if m.value != zero[ptr[ast.Expr]]:
                val = this.eval_enum_value(m.value)
                autoval = val
            ir_members.push(ir.IrEnumMember(
                name = this.name_str(m.name),
                value = val,
            ))
            autoval += 1
            i += 1
        return ir.IrEnum(
            name = cname,
            type_id = tid,
            members = this.copy_enum_members(ref_of(ir_members)),
        )


    function eval_enum_value(expr: ptr[ast.Expr]) -> int:
        unsafe:
            match read(expr):
                ast.Expr.integer_literal(value, _):
                    return value
                _:
                    return 0


    editable function lower_variant(name: ast.IdentId, arms: span[ast.VariantArmDecl]) -> ir.IrVariant:
        let cname = this.name_str(name)
        let tid = this.registry.named_type(name)
        var ir_arms = vec.Vec[ir.IrVariantArm].create()
        var ai: ptr_uint = 0
        while ai < arms.len:
            let arm = unsafe: read(arms.data + ai)
            var ir_fields = vec.Vec[ir.IrField].create()
            var fi: ptr_uint = 0
            while fi < arm.fields.len:
                let fld = unsafe: read(arm.fields.data + fi)
                ir_fields.push(ir.IrField(
                    name = this.name_str(fld.name),
                    type_id = this.resolve_type_id(fld.type_ref),
                ))
                fi += 1
            ir_arms.push(ir.IrVariantArm(
                name = this.name_str(arm.name),
                fields = this.copy_fields(ref_of(ir_fields)),
            ))
            ai += 1
        return ir.IrVariant(
            name = cname,
            type_id = tid,
            arms = this.copy_variant_arms(ref_of(ir_arms)),
        )


    editable function lower_extending(
        type_name: ast.IdentId,
        methods: span[ast.ExtendingMethod],
        functions: ref[vec.Vec[ir.IrFunction]],
    ) -> void:
        let saved_type = this.extending_type
        let saved_cname = this.extending_cname
        this.extending_type = type_name
        this.extending_cname = this.name_str(type_name)
        var mi: ptr_uint = 0
        while mi < methods.len:
            let method = unsafe: read(methods.data + mi)
            let f = this.lower_method(type_name, method)
            functions.push(f)
            mi += 1
        this.extending_type = saved_type
        this.extending_cname = saved_cname


    editable function lower_method(type_name: ast.IdentId, method: ast.ExtendingMethod) -> ir.IrFunction:
        let type_cname = this.name_str(type_name)
        let method_cname = this.name_str(method.name)
        this.name_buf.clear()
        this.name_buf.append(type_cname)
        this.name_buf.append("_")
        this.name_buf.append(method_cname)
        let cname = this.arena_str(this.name_buf.as_str())
        var ir_params = vec.Vec[ir.IrParam].create()

        let this_tid = this.registry.named_type(type_name)
        if method.method_kind == ast.MethodKind.mk_editable:
            ir_params.push(ir.IrParam(name = "this", type_id = this_tid))
        else if method.method_kind == ast.MethodKind.mk_plain:
            ir_params.push(ir.IrParam(name = "this", type_id = this_tid))

        var pi: ptr_uint = 0
        while pi < method.params.len:
            let param = unsafe: read(method.params.data + pi)
            ir_params.push(ir.IrParam(
                name = this.name_str(param.name),
                type_id = this.resolve_type_id(param.type_ref),
            ))
            pi += 1

        var save_editable = this.in_editable
        this.in_editable = method.method_kind == ast.MethodKind.mk_editable
        var ir_body = this.lower_block(method.body)
        this.in_editable = save_editable

        return ir.IrFunction(
            name = cname,
            params = this.copy_params(ref_of(ir_params)),
            return_type = this.resolve_type_id(method.return_type),
            body = this.copy_stmts(ref_of(ir_body)),
            is_editable = method.method_kind == ast.MethodKind.mk_editable,
        )


    editable function lower_function(
        name_id: ast.IdentId,
        params: span[ast.Param],
        return_type: ptr[ast.Type],
        body: ptr[ast.Stmt],
    ) -> ir.IrFunction:
        let name = this.name_str(name_id)
        var ir_params = vec.Vec[ir.IrParam].create()
        var i: ptr_uint = 0
        while i < params.len:
            let param = unsafe: read(params.data + i)
            ir_params.push(ir.IrParam(
                name = this.name_str(param.name),
                type_id = this.resolve_type_id(param.type_ref),
            ))
            i += 1

        var ir_body = this.lower_block(body)

        return ir.IrFunction(
            name = name,
            params = this.copy_params(ref_of(ir_params)),
            return_type = this.resolve_type_id(return_type),
            body = this.copy_stmts(ref_of(ir_body)),
        )


    ## ── type resolution ────────────────────────────────────────────

    editable function resolve_type_id(type_ref: ptr[ast.Type]) -> reg.TypeId:
        if type_ref == zero[ptr[ast.Type]]:
            return this.void_tid
        unsafe:
            match read(type_ref):
                ast.Type.named_type(name, _):
                    return this.resolve_named_type_id(name)
                ast.Type.qualified_type(_, type_name, _):
                    return this.resolve_named_type_id(type_name)
                ast.Type.pointer_type(pointee, is_const, _):
                    let inner = this.resolve_type_id(pointee)
                    return this.registry.pointer(inner, is_const)
                ast.Type.ref_type(pointee, _):
                    let inner = this.resolve_type_id(pointee)
                    return this.registry.ref(inner)
                ast.Type.span_type(element, _):
                    let inner = this.resolve_type_id(element)
                    return this.registry.span(inner)
                ast.Type.array_type(element, size, _):
                    let inner = this.resolve_type_id(element)
                    return this.registry.array(inner, size)
                ast.Type.nullable_type(inner, _):
                    let inner_tid = this.resolve_type_id(inner)
                    return this.registry.nullable(inner_tid)
                _:
                    return reg.TypeId<-0


    function resolve_named_type_id(name: ast.IdentId) -> reg.TypeId:
        if name == this.id_void:
            return this.registry.primitive(P.pk_void)
        if name == this.id_bool:
            return this.registry.primitive(P.pk_bool)
        if name == this.id_byte:
            return this.registry.primitive(P.pk_byte)
        if name == this.id_ubyte:
            return this.registry.primitive(P.pk_ubyte)
        if name == this.id_char:
            return this.registry.primitive(P.pk_char)
        if name == this.id_short:
            return this.registry.primitive(P.pk_short)
        if name == this.id_ushort:
            return this.registry.primitive(P.pk_ushort)
        if name == this.id_int:
            return this.registry.primitive(P.pk_int)
        if name == this.id_uint:
            return this.registry.primitive(P.pk_uint)
        if name == this.id_long:
            return this.registry.primitive(P.pk_long)
        if name == this.id_ulong:
            return this.registry.primitive(P.pk_ulong)
        if name == this.id_ptr_int:
            return this.registry.primitive(P.pk_ptr_int)
        if name == this.id_ptr_uint:
            return this.registry.primitive(P.pk_ptr_uint)
        if name == this.id_float:
            return this.registry.primitive(P.pk_float)
        if name == this.id_double:
            return this.registry.primitive(P.pk_double)
        if name == this.id_str:
            return this.registry.primitive(P.pk_str)
        if name == this.id_cstr:
            return this.registry.primitive(P.pk_cstr)
        if name == this.id_vec2:
            return this.registry.primitive(P.pk_vec2)
        if name == this.id_vec3:
            return this.registry.primitive(P.pk_vec3)
        if name == this.id_vec4:
            return this.registry.primitive(P.pk_vec4)
        if name == this.id_ivec2:
            return this.registry.primitive(P.pk_ivec2)
        if name == this.id_ivec3:
            return this.registry.primitive(P.pk_ivec3)
        if name == this.id_ivec4:
            return this.registry.primitive(P.pk_ivec4)
        if name == this.id_mat3:
            return this.registry.primitive(P.pk_mat3)
        if name == this.id_mat4:
            return this.registry.primitive(P.pk_mat4)
        if name == this.id_quat:
            return this.registry.primitive(P.pk_quat)
        return this.registry.lookup_named(name)


    ## ── statements ─────────────────────────────────────────────────

    editable function lower_block(stmt: ptr[ast.Stmt]) -> vec.Vec[ir.IrStmt]:
        var result = vec.Vec[ir.IrStmt].create()
        unsafe:
            match read(stmt):
                ast.Stmt.block(stmts, _):
                    var i: ptr_uint = 0
                    while i < stmts.len:
                        let s = read(stmts.data + i)
                        this.lower_stmt(s, ref_of(result))
                        i += 1
                _:
                    pass
        return result


    editable function lower_stmt(stmt: ptr[ast.Stmt], output: ref[vec.Vec[ir.IrStmt]]) -> void:
        unsafe:
            match read(stmt):
                ast.Stmt.return_stmt(value, _):
                    if value == zero[ptr[ast.Expr]]:
                        output.push(ir.IrStmt.return_void)
                    else:
                        let v = this.lower_expr(value)
                        output.push(ir.IrStmt.return_stmt(value = v))
                ast.Stmt.expression(expr, _):
                    let v = this.lower_expr(expr)
                    output.push(ir.IrStmt.expr_stmt(expr = v))
                ast.Stmt.if_stmt(branches, else_body, _):
                    this.lower_if(branches, else_body, output)
                ast.Stmt.while_stmt(condition, body, _):
                    this.lower_while(condition, body, output)
                ast.Stmt.unsafe_block(body, _):
                    this.lower_block_into(body, output)
                ast.Stmt.block(stmts, _):
                    this.lower_block_stmts(stmts, output)
                ast.Stmt.local_decl(_, name, type_ref, value, else_binding, else_body, _):
                    let saved = name
                    let n = this.name_str(saved)
                    var tid = this.resolve_type_id(type_ref)
                    var init = ir.IrExpr.integer(value = 0)
                    if value != zero[ptr[ast.Expr]]:
                        init = this.lower_expr(value)
                        if type_ref == zero[ptr[ast.Type]]:
                            tid = this.infer_expr_type_id(value)
                    output.push(ir.IrStmt.decl(name = n, type_id = tid, init = init))
                    if type_ref != zero[ptr[ast.Type]]:
                        unsafe:
                            match read(type_ref):
                                ast.Type.named_type(name, _):
                                    let _ = this.var_types.set(saved, name)
                                _:
                                    pass
                    if else_body != zero[ptr[ast.Stmt]]:
                        let name_ref = this.new_ir_expr(ir.IrExpr.name(name = n))
                        let zero_val = this.new_ir_expr(ir.IrExpr.integer(value = 0))
                        let cond = ir.IrExpr.binary(
                            op = "==",
                            left = name_ref,
                            right = zero_val,
                        )
                        var guard_body = vec.Vec[ir.IrStmt].create()
                        this.lower_block_into(else_body, ref_of(guard_body))
                        output.push(ir.IrStmt.if_stmt(
                            condition = cond,
                            then_body = this.copy_stmts(ref_of(guard_body)),
                            else_body = span[ir.IrStmt](data = zero[ptr[ir.IrStmt]], len = 0),
                        ))
                ast.Stmt.assignment(target, op, value, _):
                    let tname = this.target_name(target)
                    let v = this.lower_expr(value)
                    let op_str = this.assign_op_c(op)
                    if this.has_member_target(target):
                        let texpr = this.lower_expr(target)
                        output.push(ir.IrStmt.assign_expr(target = texpr, op_kind = op_str, value = v))
                    else:
                        output.push(ir.IrStmt.assign(target = tname, op_kind = op_str, value = v))
                ast.Stmt.match_stmt(scrutinee, arms, _):
                    this.lower_match(scrutinee, arms, output)
                ast.Stmt.for_stmt(bindings, iterables, body, _):
                    this.lower_for(bindings, iterables, body, output)
                ast.Stmt.break_stmt(_):
                    output.push(ir.IrStmt.break_stmt)
                ast.Stmt.continue_stmt(_):
                    output.push(ir.IrStmt.continue_stmt)
                _:
                    pass


    editable function lower_if(
        branches: span[ast.IfBranch],
        else_body: ptr[ast.Stmt],
        output: ref[vec.Vec[ir.IrStmt]],
    ) -> void:
        if branches.len == 0:
            return
        let first = unsafe: read(branches.data + 0)
        let cond = this.lower_expr(first.condition)
        var then_body = vec.Vec[ir.IrStmt].create()
        this.lower_block_into(first.body, ref_of(then_body))

        var else_ir = vec.Vec[ir.IrStmt].create()
        if branches.len > 1:
            var tail = span[ast.IfBranch](
                data = unsafe: branches.data + 1,
                len = branches.len - 1,
            )
            this.lower_if(tail, else_body, ref_of(else_ir))
        else if else_body != zero[ptr[ast.Stmt]]:
            this.lower_block_into(else_body, ref_of(else_ir))

        output.push(ir.IrStmt.if_stmt(
            condition = cond,
            then_body = this.copy_stmts(ref_of(then_body)),
            else_body = this.copy_stmts(ref_of(else_ir)),
        ))


    editable function lower_while(
        condition: ptr[ast.Expr],
        body: ptr[ast.Stmt],
        output: ref[vec.Vec[ir.IrStmt]],
    ) -> void:
        let cond = this.lower_expr(condition)
        var body_ir = vec.Vec[ir.IrStmt].create()
        this.lower_block_into(body, ref_of(body_ir))
        output.push(ir.IrStmt.while_stmt(
            condition = cond,
            body = this.copy_stmts(ref_of(body_ir)),
        ))


    editable function lower_for(
        bindings: span[ast.ForBinding],
        iterables: span[ptr[ast.Expr]],
        body: ptr[ast.Stmt],
        output: ref[vec.Vec[ir.IrStmt]],
    ) -> void:
        if bindings.len == 0 or iterables.len == 0:
            return
        let iterable = unsafe: read(iterables.data + 0)
        let binding = unsafe: read(bindings.data + 0)
        let bname = this.name_str(binding.name)
        var body_ir = vec.Vec[ir.IrStmt].create()
        this.lower_block_into(body, ref_of(body_ir))
        let body_span = this.copy_stmts(ref_of(body_ir))

        unsafe:
            match read(iterable):
                ast.Expr.range_expr(start, end, _):
                    let s = this.lower_expr(start)
                    let e = this.lower_expr(end)
                    output.push(ir.IrStmt.for_range(
                        binding = bname,
                        start = s,
                        end = e,
                        body = body_span,
                    ))
                    return
                _:
                    pass

        let iter = this.lower_expr(iterable)
        output.push(ir.IrStmt.for_span(
            binding = bname,
            span_expr = iter,
            body = body_span,
        ))


    editable function lower_match(
        scrutinee: ptr[ast.Expr],
        arms: span[ast.MatchArm],
        output: ref[vec.Vec[ir.IrStmt]],
    ) -> void:
        let scrut_ir = this.lower_expr(scrutinee)
        var ir_arms = vec.Vec[ir.IrMatchArm].create()
        if arms.len == 0:
            return
        var i: ptr_uint = 0
        while i < arms.len:
            let arm = unsafe: read(arms.data + i)
            var variant_match = false
            var vtype: str
            var varm: str
            var field_bindings: span[ast.PatternField]
            field_bindings.len = 0
            field_bindings.data = zero[ptr[ast.PatternField]]

            unsafe:
                match read(arm.pattern):
                    ast.Pattern.variant_arm(type_name, arm_name, _, fields, _):
                        if not this.is_enum_name(type_name):
                            variant_match = true
                            vtype = this.name_str(type_name)
                            varm = this.name_str(arm_name)
                            field_bindings = fields
                    _:
                        pass

            var values = vec.Vec[ir.IrExpr].create()
            if variant_match:
                let scr_copy = this.lower_expr(scrutinee)
                let scr_ptr = this.new_ir_expr(scr_copy)
                let tag_access = ir.IrExpr.access(receiver = scr_ptr, member = "tag")
                let tag_ptr = this.new_ir_expr(tag_access)
                this.name_buf.clear()
                this.name_buf.append(vtype)
                this.name_buf.append("_tag_")
                this.name_buf.append(varm)
                let tag_val_name = this.arena_str(this.name_buf.as_str())
                let tag_val = ir.IrExpr.name(name = tag_val_name)
                let cond = ir.IrExpr.binary(
                    op = "==",
                    left = tag_ptr,
                    right = this.new_ir_expr(tag_val),
                )
                values.push(cond)
            else:
                this.lower_match_pattern(arm.pattern, ref_of(values))

            while i + 1 < arms.len and this.same_body(arm.body, unsafe: read(arms.data + i + 1).body):
                i += 1
                let next = unsafe: read(arms.data + i)
                if not variant_match:
                    this.lower_match_pattern(next.pattern, ref_of(values))

            var body_ir = vec.Vec[ir.IrStmt].create()
            if variant_match and field_bindings.len > 0:
                let scr_name = this.scrutinee_name(scrutinee)
                if scr_name != "":
                    var fi: ptr_uint = 0
                    while fi < field_bindings.len:
                        let pf = unsafe: read(field_bindings.data + fi)
                        if pf.name != 0:
                            let fname = this.name_str(pf.name)
                            this.name_buf.clear()
                            this.name_buf.append(scr_name)
                            this.name_buf.append(".data.")
                            this.name_buf.append(varm)
                            this.name_buf.append(".")
                            this.name_buf.append(fname)
                            body_ir.push(ir.IrStmt.decl(
                                name = fname,
                                type_id = this.registry.primitive(P.pk_int),
                                init = ir.IrExpr.name(
                                    name = this.arena_str(this.name_buf.as_str()),
                                ),
                            ))
                        fi += 1
            this.lower_block_into(arm.body, ref_of(body_ir))

            var is_wild = false
            unsafe:
                match read(arm.pattern):
                    ast.Pattern.wildcard(_):
                        is_wild = true
                    _:
                        pass

            ir_arms.push(ir.IrMatchArm(
                values = this.copy_ir_exprs(ref_of(values)),
                body = this.copy_stmts(ref_of(body_ir)),
                variant_name = vtype,
                variant_arm = varm,
                is_wildcard = is_wild,
            ))
            i += 1
        output.push(ir.IrStmt.match_stmt(
            scrutinee = scrut_ir,
            arms = this.copy_match_arms(ref_of(ir_arms)),
        ))


    function same_body(a: ptr[ast.Stmt], b: ptr[ast.Stmt]) -> bool:
        return a == b


    editable function lower_match_pattern(pattern: ptr[ast.Pattern], values: ref[vec.Vec[ir.IrExpr]]) -> void:
        unsafe:
            match read(pattern):
                ast.Pattern.wildcard(_):
                    pass
                ast.Pattern.int_literal(value, _):
                    values.push(ir.IrExpr.integer(value = value))
                ast.Pattern.char_literal(value, _):
                    values.push(ir.IrExpr.integer(value = int<-value))
                ast.Pattern.variant_arm(type_name, arm_name, _, _, _):
                    values.push(ir.IrExpr.name(name = this.name_str(arm_name)))
                _:
                    pass


    editable function lower_block_into(stmt: ptr[ast.Stmt], output: ref[vec.Vec[ir.IrStmt]]) -> void:
        unsafe:
            match read(stmt):
                ast.Stmt.block(stmts, _):
                    this.lower_block_stmts(stmts, output)
                _:
                    this.lower_stmt(stmt, output)


    editable function lower_block_stmts(stmts: span[ptr[ast.Stmt]], output: ref[vec.Vec[ir.IrStmt]]) -> void:
        var i: ptr_uint = 0
        while i < stmts.len:
            let s = unsafe: read(stmts.data + i)
            this.lower_stmt(s, output)
            i += 1


    ## ── expressions ────────────────────────────────────────────────

    editable function lower_expr(expr: ptr[ast.Expr]) -> ir.IrExpr:
        unsafe:
            match read(expr):
                ast.Expr.integer_literal(value, _):
                    return ir.IrExpr.integer(value = value)
                ast.Expr.identifier(name, _):
                    return ir.IrExpr.name(name = this.name_str(name))
                ast.Expr.binary_op(operator, left, right, _):
                    let l = this.lower_expr(left)
                    let r = this.lower_expr(right)
                    let op = this.binary_op_c(operator)
                    let lp = this.new_ir_expr(l)
                    let rp = this.new_ir_expr(r)
                    return ir.IrExpr.binary(op = op, left = lp, right = rp)
                ast.Expr.unary_op(operator, operand, _):
                    let o = this.lower_expr(operand)
                    let op = this.unary_op_c(operator)
                    let op_ptr = this.new_ir_expr(o)
                    return ir.IrExpr.unary(op = op, operand = op_ptr)
                ast.Expr.call(callee, args, _):
                    let ident = this.callee_ident(callee)
                    let is_member = this.callee_is_member(callee)

                    if not is_member and ident == this.id_fatal:
                        let cname = this.callee_name(callee)
                        var a = this.lower_args(args)
                        return ir.IrExpr.call(name = cname, args = this.copy_ir_exprs(ref_of(a)))
                    if not is_member and ident == this.id_read:
                        var a = this.lower_args(args)
                        if args.len > 0:
                            let val_opt = a.at(0)
                            let op = val_opt else:
                                return ir.IrExpr.integer(value = 0)
                            let op_ptr = this.new_ir_expr(op)
                            return ir.IrExpr.deref(operand = op_ptr)
                        return ir.IrExpr.integer(value = 0)
                    if not is_member and ident == this.id_ptr_of:
                        var a2 = this.lower_args(args)
                        if args.len > 0:
                            let val_opt2 = a2.at(0)
                            let op2 = val_opt2 else:
                                return ir.IrExpr.integer(value = 0)
                            let op_ptr2 = this.new_ir_expr(op2)
                            return ir.IrExpr.address(operand = op_ptr2)
                        return ir.IrExpr.integer(value = 0)

                    if is_member:
                        let recv = this.lower_member_receiver(callee)
                        let mname = this.callee_name(callee)
                        let prefix = this.member_call_prefix(callee)
                        var full_name: str
                        if prefix != "":
                            this.name_buf.clear()
                            this.name_buf.append(prefix)
                            this.name_buf.append("_")
                            this.name_buf.append(mname)
                            full_name = this.arena_str(this.name_buf.as_str())
                        else:
                            full_name = mname
                        var combined = vec.Vec[ir.IrExpr].create()
                        combined.push(recv)
                        var ai: ptr_uint = 0
                        while ai < args.len:
                            let arg = unsafe: read(args.data + ai)
                            combined.push(this.lower_expr(arg))
                            ai += 1
                        return ir.IrExpr.call(name = full_name, args = this.copy_ir_exprs(ref_of(combined)))

                    let cname = this.callee_name(callee)
                    var a = this.lower_args(args)
                    return ir.IrExpr.call(name = cname, args = this.copy_ir_exprs(ref_of(a)))
                ast.Expr.member_access(receiver, member, _):
                    if this.is_enum_type_expr(receiver):
                        return ir.IrExpr.name(name = this.name_str(member))
                    let rec = this.lower_expr(receiver)
                    let rp = this.new_ir_expr(rec)
                    if this.in_editable:
                        return ir.IrExpr.ptr_access(receiver = rp, member = this.name_str(member))
                    return ir.IrExpr.access(receiver = rp, member = this.name_str(member))
                ast.Expr.null_literal(_):
                    return ir.IrExpr.null_value
                ast.Expr.aggregate(type_name, fields, _):
                    return this.lower_aggregate(type_name, fields)
                ast.Expr.variant_ctor(type_name, arm_name, fields, _):
                    return this.lower_variant_ctor(type_name, arm_name, fields)
                ast.Expr.cast_expr(target_type, expr, _):
                    return this.lower_cast(target_type, expr)
                ast.Expr.specialization(callee, _, _):
                    let ident = this.callee_ident(callee)
                    if ident == this.id_zero:
                        return ir.IrExpr.null_value
                    return ir.IrExpr.integer(value = 0)
                _:
                    return ir.IrExpr.integer(value = 0)


    editable function callee_name(expr: ptr[ast.Expr]) -> str:
        unsafe:
            match read(expr):
                ast.Expr.identifier(name, _):
                    return this.name_str(name)
                ast.Expr.member_access(_, member, _):
                    return this.name_str(member)
                _:
                    return ""


    function callee_ident(expr: ptr[ast.Expr]) -> ast.IdentId:
        unsafe:
            match read(expr):
                ast.Expr.identifier(name, _):
                    return name
                ast.Expr.member_access(_, member, _):
                    return member
                _:
                    return 0


    function callee_is_member(expr: ptr[ast.Expr]) -> bool:
        unsafe:
            match read(expr):
                ast.Expr.member_access(_, _, _):
                    return true
                _:
                    return false


    function member_call_prefix(callee: ptr[ast.Expr]) -> str:
        unsafe:
            match read(callee):
                ast.Expr.member_access(receiver, _, _):
                    if this.is_this_expr(receiver):
                        return this.extending_cname
                    match read(receiver):
                        ast.Expr.identifier(name, _):
                            let tid_ptr = this.var_types.get(name) else:
                                return ""
                            let tid = unsafe: read(tid_ptr)
                            return this.name_str(tid)
                        _:
                            return ""
                _:
                    return ""


    function is_this_expr(expr: ptr[ast.Expr]) -> bool:
        unsafe:
            match read(expr):
                ast.Expr.identifier(name, _):
                    return this.name_str(name) == "this"
                _:
                    return false


    editable function arena_str(s: str) -> str:
        if s.len == 0:
            return ""
        let storage = this.arena.alloc[ubyte](s.len) else:
            fatal(c"lowerer: arena exhausted")
        var i: ptr_uint = 0
        while i < s.len:
            unsafe: read(storage + i) = ubyte<-read(s.data + i)
            i += 1
        unsafe:
            return str(data = ptr[char]<-storage, len = s.len)

    editable function lower_member_receiver(expr: ptr[ast.Expr]) -> ir.IrExpr:
        unsafe:
            match read(expr):
                ast.Expr.member_access(receiver, _, _):
                    return this.lower_expr(receiver)
                _:
                    return ir.IrExpr.integer(value = 0)


    function is_enum_type_expr(expr: ptr[ast.Expr]) -> bool:
        unsafe:
            match read(expr):
                ast.Expr.identifier(name, _):
                    return this.is_enum_name(name)
                _:
                    return false


    function is_enum_name(name: ast.IdentId) -> bool:
        var ei: ptr_uint = 0
        while ei < this.enum_names.len:
            let ename = this.enum_names.at(ei) else:
                return false
            if ename == name:
                return true
            ei += 1
        return false


    function scrutinee_name(expr: ptr[ast.Expr]) -> str:
        unsafe:
            match read(expr):
                ast.Expr.identifier(name, _):
                    return this.name_str(name)
                _:
                    return ""


    editable function lower_args(args: span[ptr[ast.Expr]]) -> vec.Vec[ir.IrExpr]:
        var result = vec.Vec[ir.IrExpr].create()
        var i: ptr_uint = 0
        while i < args.len:
            let arg = unsafe: read(args.data + i)
            result.push(this.lower_expr(arg))
            i += 1
        return result


    ## ── cast ──────────────────────────────────────────────────────────

    editable function lower_cast(target_type: ptr[ast.Type], expr: ptr[ast.Expr]) -> ir.IrExpr:
        let tid = this.resolve_type_id(target_type)
        ## We need the C type name here — use a simple lookup.
        ## The C backend's type_to_c will handle TypeId → C name,
        ## but we don't have the C backend here.  Store the TypeId
        ## as the type_c string for now (the backend will resolve it).
        var ctype: str
        if tid == reg.TypeId<-0:
            ctype = "void"
        else:
            let s = this.name_str_from_type(target_type)
            ctype = s
        let operand = this.lower_expr(expr)
        let op_ptr = this.new_ir_expr(operand)
        return ir.IrExpr.cast_expr(type_c = ctype, operand = op_ptr)


    function name_str_from_type(type_ref: ptr[ast.Type]) -> str:
        if type_ref == zero[ptr[ast.Type]]:
            return "void"
        unsafe:
            match read(type_ref):
                ast.Type.named_type(name, _):
                    return this.name_str(name)
                _:
                    return "int"

    editable function lower_aggregate(type_name: ast.IdentId, fields: span[ast.TupleField]) -> ir.IrExpr:
        let cname = this.name_str(type_name)
        var ir_fields = vec.Vec[ir.IrAggregateField].create()
        var i: ptr_uint = 0
        while i < fields.len:
            let fld = unsafe: read(fields.data + i)
            let val = this.lower_expr(fld.value)
            ir_fields.push(ir.IrAggregateField(
                name = this.name_str(fld.name),
                value = val,
            ))
            i += 1
        return ir.IrExpr.aggregate(name = cname, fields = this.copy_agg_fields(ref_of(ir_fields)))

    editable function lower_variant_ctor(
        type_name: ast.IdentId,
        arm_name: ast.IdentId,
        fields: span[ast.TupleField],
    ) -> ir.IrExpr:
        let cname = this.name_str(type_name)
        let aname = this.name_str(arm_name)
        var ir_fields = vec.Vec[ir.IrAggregateField].create()
        var i: ptr_uint = 0
        while i < fields.len:
            let fld = unsafe: read(fields.data + i)
            let val = this.lower_expr(fld.value)
            ir_fields.push(ir.IrAggregateField(
                name = this.name_str(fld.name),
                value = val,
            ))
            i += 1
        return ir.IrExpr.variant_ctor(name = cname, arm = aname, fields = this.copy_agg_fields(ref_of(ir_fields)))


    ## ── type inference for untyped local decls ────────────────────────

    editable function infer_expr_type_id(expr: ptr[ast.Expr]) -> reg.TypeId:
        unsafe:
            match read(expr):
                ast.Expr.integer_literal(_, _):
                    return this.registry.primitive(P.pk_int)
                ast.Expr.float_literal(_, _):
                    return this.registry.primitive(P.pk_float)
                ast.Expr.string_literal(_, _):
                    return this.registry.primitive(P.pk_str)
                ast.Expr.char_literal(_, _):
                    return this.registry.primitive(P.pk_ubyte)
                ast.Expr.bool_literal(_, _):
                    return this.registry.primitive(P.pk_bool)
                ast.Expr.null_literal(_):
                    return this.registry.primitive(P.pk_int)
                ast.Expr.identifier(name, _):
                    let tid = this.var_types.get(name)
                    if tid == null:
                        return this.registry.primitive(P.pk_int)
                    return this.registry.named_type(unsafe: read(tid))
                ast.Expr.member_access(receiver, member, _):
                    let ftid = this.infer_field_type(receiver, member)
                    return ftid
                _:
                    return this.registry.primitive(P.pk_int)
        return this.registry.primitive(P.pk_int)


    editable function infer_field_type(receiver: ptr[ast.Expr], member: ast.IdentId) -> reg.TypeId:
        unsafe:
            match read(receiver):
                ast.Expr.identifier(name, _):
                    if name == this.extending_type and this.extending_type != 0:
                        let sid = this.registry.named_type(this.extending_type)
                        return this.registry.primitive(P.pk_int)
                ast.Expr.member_access(receiver, member, _):
                    return this.infer_field_type(receiver, member)
                _:
                    pass
        return this.registry.primitive(P.pk_int)


    ## ── assignment helpers ────────────────────────────────────────────

    function target_name(expr: ptr[ast.Expr]) -> str:
        unsafe:
            match read(expr):
                ast.Expr.identifier(name, _):
                    return this.name_str(name)
                ast.Expr.member_access(receiver, member, _):
                    return this.name_str(member)
                _:
                    return "?"

    function has_member_target(expr: ptr[ast.Expr]) -> bool:
        unsafe:
            match read(expr):
                ast.Expr.member_access(_, _, _):
                    return true
                _:
                    return false

    function assign_op_c(kind: tk.TokenKind) -> str:
        if kind == tk.TokenKind.tk_equal:
            return "="
        if kind == tk.TokenKind.tk_plus_equal:
            return "+="
        if kind == tk.TokenKind.tk_minus_equal:
            return "-="
        if kind == tk.TokenKind.tk_star_equal:
            return "*="
        if kind == tk.TokenKind.tk_slash_equal:
            return "/="
        if kind == tk.TokenKind.tk_percent_equal:
            return "%="
        if kind == tk.TokenKind.tk_amp_equal:
            return "&="
        if kind == tk.TokenKind.tk_pipe_equal:
            return "|="
        if kind == tk.TokenKind.tk_caret_equal:
            return "^="
        if kind == tk.TokenKind.tk_shift_left_equal:
            return "<<="
        if kind == tk.TokenKind.tk_shift_right_equal:
            return ">>="
        return "="


    ## ── operators ──────────────────────────────────────────────────

    function unary_op_c(op: ops_mod.UnaryOp) -> str:
        if op == ops_mod.UnaryOp.uop_negate:
            return "-"
        if op == ops_mod.UnaryOp.uop_bit_not:
            return "~"
        if op == ops_mod.UnaryOp.uop_logic_not:
            return "!"
        return "-"

    function binary_op_c(op: ops_mod.BinaryOp) -> str:
        if op == B.op_add:
            return "+"
        if op == B.op_sub:
            return "-"
        if op == B.op_mul:
            return "*"
        if op == B.op_div:
            return "/"
        if op == B.op_mod:
            return "%"
        if op == B.op_eq:
            return "=="
        if op == B.op_ne:
            return "!="
        if op == B.op_lt:
            return "<"
        if op == B.op_le:
            return "<="
        if op == B.op_gt:
            return ">"
        if op == B.op_ge:
            return ">="
        if op == B.op_logic_and:
            return "&&"
        if op == B.op_logic_or:
            return "||"
        if op == B.op_bit_and:
            return "&"
        if op == B.op_bit_or:
            return "|"
        if op == B.op_bit_xor:
            return "^"
        if op == B.op_shift_left:
            return "<<"
        if op == B.op_shift_right:
            return ">>"
        return "??"


    ## ── interner ───────────────────────────────────────────────────

    function name_str(id: ast.IdentId) -> str:
        unsafe:
            let result = this.interner.lookup(id) else:
                return "?"
            return result


    ## ── arena helpers ──────────────────────────────────────────────

    editable function new_ir_expr(value: ir.IrExpr) -> ptr[ir.IrExpr]:
        let p = this.arena.alloc[ir.IrExpr](1) else:
            fatal(c"lowerer: arena exhausted")
        unsafe: read(p) = value
        return p

    editable function copy_fields(src: ref[vec.Vec[ir.IrField]]) -> span[ir.IrField]:
        if src.len == 0:
            return span[ir.IrField](data = zero[ptr[ir.IrField]], len = 0)
        let storage = this.arena.alloc[ir.IrField](src.len) else:
            fatal(c"lowerer: arena exhausted")
        var i: ptr_uint = 0
        while i < src.len:
            let val = src.at(i) else:
                fatal(c"lowerer: vec access out of bounds")
            unsafe: read(storage + i) = val
            i += 1
        return span[ir.IrField](data = storage, len = src.len)

    editable function copy_variant_arms(src: ref[vec.Vec[ir.IrVariantArm]]) -> span[ir.IrVariantArm]:
        if src.len == 0:
            return span[ir.IrVariantArm](data = zero[ptr[ir.IrVariantArm]], len = 0)
        let storage = this.arena.alloc[ir.IrVariantArm](src.len) else:
            fatal(c"lowerer: arena exhausted")
        var i: ptr_uint = 0
        while i < src.len:
            let val = src.at(i) else:
                fatal(c"lowerer: vec access out of bounds")
            unsafe: read(storage + i) = val
            i += 1
        return span[ir.IrVariantArm](data = storage, len = src.len)

    editable function copy_structs(src: ref[vec.Vec[ir.IrStruct]]) -> span[ir.IrStruct]:
        if src.len == 0:
            return span[ir.IrStruct](data = zero[ptr[ir.IrStruct]], len = 0)
        let storage = this.arena.alloc[ir.IrStruct](src.len) else:
            fatal(c"lowerer: arena exhausted")
        var i: ptr_uint = 0
        while i < src.len:
            let val = src.at(i) else:
                fatal(c"lowerer: vec access out of bounds")
            unsafe: read(storage + i) = val
            i += 1
        return span[ir.IrStruct](data = storage, len = src.len)

    editable function copy_params(src: ref[vec.Vec[ir.IrParam]]) -> span[ir.IrParam]:
        if src.len == 0:
            return span[ir.IrParam](data = zero[ptr[ir.IrParam]], len = 0)
        let storage = this.arena.alloc[ir.IrParam](src.len) else:
            fatal(c"lowerer: arena exhausted")
        var i: ptr_uint = 0
        while i < src.len:
            let val = src.at(i) else:
                fatal(c"lowerer: vec access out of bounds")
            unsafe: read(storage + i) = val
            i += 1
        return span[ir.IrParam](data = storage, len = src.len)

    editable function copy_agg_fields(src: ref[vec.Vec[ir.IrAggregateField]]) -> span[ir.IrAggregateField]:
        if src.len == 0:
            return span[ir.IrAggregateField](data = zero[ptr[ir.IrAggregateField]], len = 0)
        let storage = this.arena.alloc[ir.IrAggregateField](src.len) else:
            fatal(c"lowerer: arena exhausted")
        var i: ptr_uint = 0
        while i < src.len:
            let val = src.at(i) else:
                fatal(c"lowerer: vec access out of bounds")
            unsafe: read(storage + i) = val
            i += 1
        return span[ir.IrAggregateField](data = storage, len = src.len)

    editable function copy_stmts(src: ref[vec.Vec[ir.IrStmt]]) -> span[ir.IrStmt]:
        if src.len == 0:
            return span[ir.IrStmt](data = zero[ptr[ir.IrStmt]], len = 0)
        let storage = this.arena.alloc[ir.IrStmt](src.len) else:
            fatal(c"lowerer: arena exhausted")
        var i: ptr_uint = 0
        while i < src.len:
            let val = src.at(i) else:
                fatal(c"lowerer: vec access out of bounds")
            unsafe: read(storage + i) = val
            i += 1
        return span[ir.IrStmt](data = storage, len = src.len)

    editable function copy_ir_exprs(src: ref[vec.Vec[ir.IrExpr]]) -> span[ir.IrExpr]:
        if src.len == 0:
            return span[ir.IrExpr](data = zero[ptr[ir.IrExpr]], len = 0)
        let storage = this.arena.alloc[ir.IrExpr](src.len) else:
            fatal(c"lowerer: arena exhausted")
        var i: ptr_uint = 0
        while i < src.len:
            let val = src.at(i) else:
                fatal(c"lowerer: vec access out of bounds")
            unsafe: read(storage + i) = val
            i += 1
        return span[ir.IrExpr](data = storage, len = src.len)

    editable function copy_match_arms(src: ref[vec.Vec[ir.IrMatchArm]]) -> span[ir.IrMatchArm]:
        if src.len == 0:
            return span[ir.IrMatchArm](data = zero[ptr[ir.IrMatchArm]], len = 0)
        let storage = this.arena.alloc[ir.IrMatchArm](src.len) else:
            fatal(c"lowerer: arena exhausted")
        var i: ptr_uint = 0
        while i < src.len:
            let val = src.at(i) else:
                fatal(c"lowerer: vec access out of bounds")
            unsafe: read(storage + i) = val
            i += 1
        return span[ir.IrMatchArm](data = storage, len = src.len)

    editable function copy_enums(src: ref[vec.Vec[ir.IrEnum]]) -> span[ir.IrEnum]:
        if src.len == 0:
            return span[ir.IrEnum](data = zero[ptr[ir.IrEnum]], len = 0)
        let storage = this.arena.alloc[ir.IrEnum](src.len) else:
            fatal(c"lowerer: arena exhausted")
        var i: ptr_uint = 0
        while i < src.len:
            let val = src.at(i) else:
                fatal(c"lowerer: vec access out of bounds")
            unsafe: read(storage + i) = val
            i += 1
        return span[ir.IrEnum](data = storage, len = src.len)

    editable function copy_enum_members(src: ref[vec.Vec[ir.IrEnumMember]]) -> span[ir.IrEnumMember]:
        if src.len == 0:
            return span[ir.IrEnumMember](data = zero[ptr[ir.IrEnumMember]], len = 0)
        let storage = this.arena.alloc[ir.IrEnumMember](src.len) else:
            fatal(c"lowerer: arena exhausted")
        var i: ptr_uint = 0
        while i < src.len:
            let val = src.at(i) else:
                fatal(c"lowerer: vec access out of bounds")
            unsafe: read(storage + i) = val
            i += 1
        return span[ir.IrEnumMember](data = storage, len = src.len)

    editable function copy_variants(src: ref[vec.Vec[ir.IrVariant]]) -> span[ir.IrVariant]:
        if src.len == 0:
            return span[ir.IrVariant](data = zero[ptr[ir.IrVariant]], len = 0)
        let storage = this.arena.alloc[ir.IrVariant](src.len) else:
            fatal(c"lowerer: arena exhausted")
        var i: ptr_uint = 0
        while i < src.len:
            let val = src.at(i) else:
                fatal(c"lowerer: vec access out of bounds")
            unsafe: read(storage + i) = val
            i += 1
        return span[ir.IrVariant](data = storage, len = src.len)

    editable function copy_span_types(src: ref[vec.Vec[ir.IrSpanType]]) -> span[ir.IrSpanType]:
        if src.len == 0:
            return span[ir.IrSpanType](data = zero[ptr[ir.IrSpanType]], len = 0)
        let storage = this.arena.alloc[ir.IrSpanType](src.len) else:
            fatal(c"lowerer: arena exhausted")
        var i: ptr_uint = 0
        while i < src.len:
            let val = src.at(i) else:
                fatal(c"lowerer: vec access out of bounds")
            unsafe: read(storage + i) = val
            i += 1
        return span[ir.IrSpanType](data = storage, len = src.len)

    editable function copy_funcs(src: ref[vec.Vec[ir.IrFunction]]) -> span[ir.IrFunction]:
        if src.len == 0:
            return span[ir.IrFunction](data = zero[ptr[ir.IrFunction]], len = 0)
        let storage = this.arena.alloc[ir.IrFunction](src.len) else:
            fatal(c"lowerer: arena exhausted")
        var i: ptr_uint = 0
        while i < src.len:
            let val = src.at(i) else:
                fatal(c"lowerer: vec access out of bounds")
            unsafe: read(storage + i) = val
            i += 1
        return span[ir.IrFunction](data = storage, len = src.len)
