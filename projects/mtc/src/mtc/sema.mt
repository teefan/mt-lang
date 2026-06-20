# Sema pipeline orchestrator for the self-hosting compiler.
# Mirrors lib/milk_tea/core/sema.rb.

import std.vec
import std.map
import mtc.types
import mtc.ast
import mtc.scope
import mtc.sema.context
import mtc.sema.resolver

public struct Checker:
    ctx: context.ModuleContext
    file: ast.SourceFile

extending Checker:
    public static function create(file: ast.SourceFile) -> Checker:
        return Checker(
            ctx = context.ModuleContext.create("", "module"),
            file = file,
        )

    public editable function check() -> context.ModuleContext:
        this.install_builtin_types()
        this.install_prelude_types()
        this.declare_named_types()
        this.resolve_aggregate_fields()
        this.resolve_enum_members()
        this.resolve_variant_arms()
        this.declare_top_level_values()
        this.declare_functions()
        this.check_function_bodies()
        return this.ctx

    # ═══════════════════════════════════════════════════════════════════════
    # Phase 1: Install built-in primitive types
    # ═══════════════════════════════════════════════════════════════════════

    editable function install_builtin_types() -> void:
        this.add_primitive("bool")
        this.add_primitive("byte")
        this.add_primitive("ubyte")
        this.add_primitive("char")
        this.add_primitive("short")
        this.add_primitive("ushort")
        this.add_primitive("int")
        this.add_primitive("uint")
        this.add_primitive("long")
        this.add_primitive("ulong")
        this.add_primitive("ptr_int")
        this.add_primitive("ptr_uint")
        this.add_primitive("float")
        this.add_primitive("double")
        this.add_primitive("void")
        this.add_primitive("cstr")
        this.add_special("str", types.Type.string_view_type)
        this.add_special("vec2", types.Type.vector_type(name = "vec2"))
        this.add_special("vec3", types.Type.vector_type(name = "vec3"))
        this.add_special("vec4", types.Type.vector_type(name = "vec4"))
        this.add_special("ivec2", types.Type.vector_type(name = "ivec2"))
        this.add_special("ivec3", types.Type.vector_type(name = "ivec3"))
        this.add_special("ivec4", types.Type.vector_type(name = "ivec4"))
        this.add_special("mat3", types.Type.matrix_type(name = "mat3"))
        this.add_special("mat4", types.Type.matrix_type(name = "mat4"))
        this.add_special("quat", types.Type.quaternion_type)
        this.add_special("Subscription", types.Type.subscription_type)
        this.add_special("type", types.Type.type_meta_type)
        this.add_special("field_handle", types.Type.field_handle_type)
        this.add_special("struct_handle", types.Type.struct_handle_type)
        this.add_special("callable_handle", types.Type.callable_handle_type)
        this.add_special("attribute_handle", types.Type.attribute_handle_type)
        this.add_special("member_handle", types.Type.member_handle_type)

    editable function add_primitive(name: str) -> void:
        let id = this.ctx.arena.alloc(types.Type.primitive(name = name))
        let _prev = this.ctx.types.set(name, id)
        pass

    editable function add_special(name: str, ty: types.Type) -> void:
        let id = this.ctx.arena.alloc(ty)
        let _prev = this.ctx.types.set(name, id)
        pass

    # ═══════════════════════════════════════════════════════════════════════
    # Phase 4: Install prelude types (Option, Result)
    # ═══════════════════════════════════════════════════════════════════════

    editable function install_prelude_types() -> void:
        this.ensure_generic_variant("Option")
        this.ensure_generic_variant("Result")

    editable function ensure_generic_variant(name: str) -> void:
        let existing = this.ctx.types.get(name) else:
            let def_id = this.ctx.arena.alloc(types.Type.generic_variant_def(
                name = name, type_params_start = 0z, type_params_len = 0z, module_name = "",
            ))
            let _prev = this.ctx.types.set(name, def_id)
            return
        pass

    # ═══════════════════════════════════════════════════════════════════════
    # Phase 5: Declare named types from AST
    # ═══════════════════════════════════════════════════════════════════════

    editable function declare_named_types() -> void:
        var i: ptr_uint = 0
        while i < this.file.declarations.len:
            let decl = this.file.declarations.at(i) else:
                break
            match decl:
                ast.Decl.struct_decl as sd:
                    this.declare_struct(sd.name)
                ast.Decl.variant_decl as vd:
                    this.declare_variant(vd.name)
                ast.Decl.enum_decl as ed:
                    this.declare_enum(ed.name)
                ast.Decl.flags_decl as fd:
                    this.declare_flags(fd.name)
                ast.Decl.opaque_decl as od:
                    this.declare_opaque(od.name, od.c_name)
                ast.Decl.union_decl as ud:
                    this.declare_union(ud.name)
                ast.Decl.interface_decl as idecl:
                    this.declare_interface(idecl.name)
                _:
                    pass
            i += 1

    editable function declare_struct(name: str) -> void:
        let existing = this.ctx.types.get(name) else:
            let id = this.ctx.arena.alloc(types.Type.struct_type(
                name = name, module_name = "", packed = false, alignment = 0,
                is_external = false, linkage_name = "",
            ))
            let _prev = this.ctx.types.set(name, id)
            return
        pass

    editable function declare_variant(name: str) -> void:
        let existing = this.ctx.types.get(name) else:
            let id = this.ctx.arena.alloc(types.Type.variant_type(
                name = name, module_name = "",
            ))
            let _prev = this.ctx.types.set(name, id)
            return
        pass

    editable function declare_enum(name: str) -> void:
        let existing = this.ctx.types.get(name) else:
            let id = this.ctx.arena.alloc(types.Type.enum_type(
                name = name, module_name = "", backing_type = 0z, is_external = false,
            ))
            let _prev = this.ctx.types.set(name, id)
            return
        pass

    editable function declare_flags(name: str) -> void:
        let existing = this.ctx.types.get(name) else:
            let id = this.ctx.arena.alloc(types.Type.flags_type(
                name = name, module_name = "", backing_type = 0z, is_external = false,
            ))
            let _prev = this.ctx.types.set(name, id)
            return
        pass

    editable function declare_opaque(name: str, c_name: str) -> void:
        let existing = this.ctx.types.get(name) else:
            let id = this.ctx.arena.alloc(types.Type.opaque_type(
                name = name, module_name = "", linkage_name = c_name, is_external = false,
            ))
            let _prev = this.ctx.types.set(name, id)
            return
        pass

    editable function declare_union(name: str) -> void:
        let existing = this.ctx.types.get(name) else:
            let id = this.ctx.arena.alloc(types.Type.union_type(
                name = name, module_name = "",
            ))
            let _prev = this.ctx.types.set(name, id)
            return
        pass

    editable function declare_interface(name: str) -> void:
        let existing = this.ctx.types.get(name) else:
            let id = this.ctx.arena.alloc(types.Type.interface_type(
                name = name, module_name = "",
            ))
            let _prev = this.ctx.types.set(name, id)
            return
        pass

    # ═══════════════════════════════════════════════════════════════════════
    # Phase 9: Resolve struct/union field types
    # ═══════════════════════════════════════════════════════════════════════

    editable function resolve_aggregate_fields() -> void:
        var i: ptr_uint = 0
        while i < this.file.declarations.len:
            let decl = this.file.declarations.at(i) else:
                break
            match decl:
                ast.Decl.struct_decl as sd:
                    this.resolve_struct_fields(sd.fields_start, sd.fields_len)
                _:
                    pass
            i += 1

    editable function resolve_struct_fields(fields_start: ast.NodeId, fields_len: ast.NodeId) -> void:
        var empty_params = vec.Vec[str].create()
        var j: ptr_uint = 0
        while j < fields_len:
            let field = this.file.fields.at(fields_start + j) else:
                break
            let _resolved = resolver.resolve_type_expr(
                ref_of(this.ctx), ref_of(this.file),
                field.type_expr_id, empty_params,
            )
            j += 1

    # ═══════════════════════════════════════════════════════════════════════
    # Phase 10: Resolve enum/flags members
    # ═══════════════════════════════════════════════════════════════════════

    editable function resolve_enum_members() -> void:
        pass

    # ═══════════════════════════════════════════════════════════════════════
    # Phase 11: Resolve variant arm payload types
    # ═══════════════════════════════════════════════════════════════════════

    editable function resolve_variant_arms() -> void:
        pass

    # ═══════════════════════════════════════════════════════════════════════
    # Phase 13: Declare top-level values (const, var, event)
    # ═══════════════════════════════════════════════════════════════════════

    editable function declare_top_level_values() -> void:
        var i: ptr_uint = 0
        while i < this.file.declarations.len:
            let decl = this.file.declarations.at(i) else:
                break
            match decl:
                ast.Decl.const_decl as cd:
                    this.ctx.values.push(context.ValueEntry(
                        name = cd.name, value_type = cd.type_id, kind = "const", visibility = cd.visibility,
                    ))
                ast.Decl.var_decl as vd:
                    this.ctx.values.push(context.ValueEntry(
                        name = vd.name, value_type = vd.type_id, kind = "var", visibility = vd.visibility,
                    ))
                _:
                    pass
            i += 1

    # ═══════════════════════════════════════════════════════════════════════
    # Phase 15: Declare function bindings
    # ═══════════════════════════════════════════════════════════════════════

    editable function declare_functions() -> void:
        var i: ptr_uint = 0
        while i < this.file.declarations.len:
            let decl = this.file.declarations.at(i) else:
                break
            match decl:
                ast.Decl.func_def as fd:
                    this.declare_function_binding(
                        fd.name, fd.params_start, fd.params_len,
                        fd.return_type, fd.body, fd.visibility,
                        fd.is_async, fd.is_const,
                    )
                _:
                    pass
            i += 1

    editable function declare_function_binding(
        name: str, params_start: ast.NodeId, params_len: ast.NodeId,
        return_type_expr: ast.NodeId, body: ast.NodeId, visibility: str,
        is_async: bool, is_const: bool,
    ) -> void:
        var empty_params = vec.Vec[str].create()
        var return_type_id: types.TypeId = this.ctx.arena.primitive_void()
        if return_type_expr != 0z:
            return_type_id = resolver.resolve_type_expr(
                ref_of(this.ctx), ref_of(this.file),
                return_type_expr, empty_params,
            )
        let binding = context.FunctionBinding(
            name = name,
            func_type_id = 0z,
            params_start = params_start,
            params_len = params_len,
            return_type = return_type_id,
            receiver_type = 0z,
            receiver_editable = false,
            is_external = false,
            is_async = is_async,
            is_const = is_const,
            body = body,
            visibility = visibility,
            type_params_start = 0z,
            type_params_len = 0z,
        )
        let _prev = this.ctx.functions.set(name, binding)
        pass

    # ═══════════════════════════════════════════════════════════════════════
    # Phase 20: Check function bodies (expression + statement inference)
    # ═══════════════════════════════════════════════════════════════════════

    public editable function check_function_bodies() -> void:
        var i: ptr_uint = 0
        while i < this.file.declarations.len:
            let decl = this.file.declarations.at(i) else:
                break
            match decl:
                ast.Decl.func_def as fd:
                    if fd.body != 0z:
                        var scopes = scope.ScopeStack.create()
                        this.check_block(fd.body, ref_of(scopes))
                _:
                    pass
            i += 1

    editable function check_block(body_id: ast.NodeId, scopes: ref[scope.ScopeStack]) -> void:
        scopes.push_scope()
        var i = body_id
        while i < this.file.stmts.len:
            let stmt = this.file.stmts.at(i) else:
                break
            match stmt:
                ast.Stmt.expression_stmt(expr_id, _):
                    let _ty = this.infer_expr(expr_id, scopes)
                ast.Stmt.return_stmt(value_id, _, _):
                    if value_id != 0z:
                        let _ty = this.infer_expr(value_id, scopes)
                    break
                ast.Stmt.local_decl as ld:
                    if ld.value_id != 0z:
                        let inf = this.infer_expr(ld.value_id, scopes)
                        let vb = scope.ValueBinding(
                            id = 0z, name = ld.name, storage_type = inf,
                            mutable = (ld.kind == "var"), kind = "local", is_param = false,
                        )
                        scopes.insert(vb)
                _:
                    pass
            i += 1
        scopes.pop_scope()

    # ── Expression type inference ──

    editable function infer_expr(expr_id: ast.NodeId, scopes: ref[scope.ScopeStack]) -> types.TypeId:
        if expr_id == 0z:
            return this.ctx.error_type_id
        let expr = this.file.exprs.at(expr_id) else:
            return this.ctx.error_type_id
        match expr:
            ast.Expr.identifier(name, _, _):
                return this.infer_name(name, scopes)
            ast.Expr.member_access(receiver, member, _, _):
                let _rt = this.infer_expr(receiver, scopes)
                return this.ctx.arena.primitive_int()
            ast.Expr.call(callee, args_start, args_len, _):
                let _ct = this.infer_expr(callee, scopes)
                return this.ctx.arena.primitive_int()
            ast.Expr.integer_literal as il:
                return this.ctx.arena.primitive_int()
            ast.Expr.string_literal as sl:
                return this.ctx.arena.primitive_str()
            ast.Expr.boolean_literal as bl:
                return this.ctx.arena.primitive_bool()
            ast.Expr.float_literal as fl:
                return this.ctx.arena.primitive_double()
            ast.Expr.binary_op(operator, left, right):
                let _lt = this.infer_expr(left, scopes)
                let _rt = this.infer_expr(right, scopes)
                if operator == "==" or operator == "!=" or operator == "<" or operator == "<=" or operator == ">" or operator == ">=":
                    return this.ctx.arena.primitive_bool()
                if operator == "and" or operator == "or":
                    return this.ctx.arena.primitive_bool()
                return this.ctx.arena.primitive_int()
            ast.Expr.prefix_cast(target_type, expression):
                let _tt = this.infer_expr(target_type, scopes)
                return _tt
            ast.Expr.unary_op(operator, operand):
                let _ot = this.infer_expr(operand, scopes)
                return _ot
            ast.Expr.index_access(receiver, index, args_start, args_len):
                let _rt = this.infer_expr(receiver, scopes)
                return this.ctx.arena.primitive_int()
            ast.Expr.null_literal(type_id):
                return this.ctx.arena.primitive_int()
            ast.Expr.if_expr(condition, then_expr, else_expr):
                return this.infer_expr(then_expr, scopes)
            ast.Expr.format_string(_, _):
                return this.ctx.arena.primitive_str()
            ast.Expr.cstring_literal as cl:
                return this.ctx.arena.primitive_cstr()
            ast.Expr.char_literal as ch:
                return this.ctx.arena.primitive_char()
            ast.Expr.range_expr(_, _, _, _):
                return this.ctx.arena.primitive_int()
            ast.Expr.error_expr(_, _, _):
                return this.ctx.error_type_id
            _:
                pass
        return this.ctx.error_type_id

    editable function infer_name(name: str, scopes: ref[scope.ScopeStack]) -> types.TypeId:
        let binding = scopes.lookup(name)
        match binding:
            Option.some as s:
                return s.value.storage_type
            Option.none:
                pass
        let type_ptr = this.ctx.types.get(name) else:
            return this.ctx.error_type_id
        return unsafe: read(type_ptr)
