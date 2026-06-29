import std.vec as vec
import ast
import resolver
import resolver.symbol as sym
import type_check.compat
import type_check.types

public struct Checker:
    compat: compat.TypeChecker
    sym_table: sym.SymbolTable
    func_return_type: types.TypeHandle

extending Checker:
    public static function create() -> Checker:
        return Checker(
            compat = compat.TypeChecker.create(),
            sym_table = sym.SymbolTable.create(),
            func_return_type = types.TYPE_HANDLE_VOID
        )

    public editable function check_module(resolved: resolver.ResolvedModule) -> bool:
        var rm = resolved
        this.sym_table = rm.sym_table
        var i: ptr_uint = 0
        while i < rm.mod_ast.declarations.len():
            let decl_ptr = rm.mod_ast.declarations.get(i) else:
                fatal(c"checker.check_module missing declaration")
            unsafe:
                this.check_decl(read(decl_ptr))
            i += 1
        return true

    editable function check_decl(decl: ast.AstDecl) -> void:
        match decl:
            ast.AstDecl.function_decl(name, params, return_type, body, type_params, is_async, is_const, is_public, docs):
                let _ = name
                let _ = type_params
                let _ = is_async
                let _ = is_const
                let _ = is_public
                let _ = docs
                let rt = this.resolve_type_ref(return_type)
                let prev = this.func_return_type
                this.func_return_type = rt
                var pi: ptr_uint = 0
                while pi < body.len():
                    let s_ptr = body.get(pi) else:
                        fatal(c"checker.check_decl missing stmt")
                    unsafe:
                        this.check_stmt(read(s_ptr))
                    pi += 1
                this.func_return_type = prev
            ast.AstDecl.const_decl(name, type_ref, init, is_public, docs):
                let _ = name
                let _ = is_public
                let _ = docs
                let _target = this.resolve_type_ref(type_ref)
                this.check_expr(init)
            ast.AstDecl.var_decl(name, type_ref, init, is_public):
                let _ = name
                let _ = is_public
                let _target = this.resolve_type_ref(type_ref)
                this.check_expr(init)
            _:
                pass

    editable function check_stmt(stmt: ast.AstStmt) -> void:
        match stmt:
            ast.AstStmt.return_stmt(value):
                this.check_expr(value)
            ast.AstStmt.let_stmt(name, type_ref, init, else_block, else_error_binding):
                let _ = name
                let _ = else_block
                let _ = else_error_binding
                let _target_type = this.resolve_type_ref(type_ref)
                this.check_expr(init)
            ast.AstStmt.var_stmt(name, type_ref, init, else_block, else_error_binding):
                let _ = name
                let _ = else_block
                let _ = else_error_binding
                let _target_type = this.resolve_type_ref(type_ref)
                this.check_expr(init)
            ast.AstStmt.expr_stmt(expr):
                this.check_expr(expr)
            ast.AstStmt.if_stmt(condition, then_body, elifs, else_body):
                this.check_expr(condition)
                var ti: ptr_uint = 0
                while ti < then_body.len():
                    let s_ptr = then_body.get(ti) else:
                        fatal(c"checker.check_stmt missing then")
                    unsafe:
                        this.check_stmt(read(s_ptr))
                    ti += 1
                var ei: ptr_uint = 0
                while ei < elifs.len():
                    let e_ptr = elifs.get(ei) else:
                        fatal(c"checker.check_stmt missing elif")
                    unsafe:
                        this.check_expr(read(e_ptr).condition)
                        let eb = read(e_ptr).body
                        var ebi: ptr_uint = 0
                        while ebi < eb.len():
                            let s_ptr = eb.get(ebi) else:
                                fatal(c"checker.check_stmt missing elif stmt")
                            unsafe:
                                this.check_stmt(read(s_ptr))
                            ebi += 1
                    ei += 1
                var eli: ptr_uint = 0
                while eli < else_body.len():
                    let s_ptr = else_body.get(eli) else:
                        fatal(c"checker.check_stmt missing else")
                    unsafe:
                        this.check_stmt(read(s_ptr))
                    eli += 1
            ast.AstStmt.while_stmt(condition, body):
                this.check_expr(condition)
                var bi: ptr_uint = 0
                while bi < body.len():
                    let s_ptr = body.get(bi) else:
                        fatal(c"checker.check_stmt missing while")
                    unsafe:
                        this.check_stmt(read(s_ptr))
                    bi += 1
            ast.AstStmt.for_range_literal(binding, start, end, body):
                let _ = binding
                this.check_expr(start)
                this.check_expr(end)
                var bi: ptr_uint = 0
                while bi < body.len():
                    let s_ptr = body.get(bi) else:
                        fatal(c"checker.check_stmt missing for")
                    unsafe:
                        this.check_stmt(read(s_ptr))
                    bi += 1
            _:
                pass

    editable function check_expr(expr: ast.AstExpr) -> types.TypeHandle:
        match expr:
            ast.AstExpr.integer_literal(value_str):
                let _ = value_str
                return types.TYPE_HANDLE_INT
            ast.AstExpr.float_literal(value_str):
                let _ = value_str
                return types.TYPE_HANDLE_FLOAT
            ast.AstExpr.string_literal(value_str):
                let _ = value_str
                return types.TYPE_HANDLE_STR
            ast.AstExpr.char_literal(value_str):
                let _ = value_str
                return types.TYPE_HANDLE_UBYTE
            ast.AstExpr.cstring_literal(value_str):
                let _ = value_str
                return types.TYPE_HANDLE_CSTR
            ast.AstExpr.bool_literal(value):
                let _ = value
                return types.TYPE_HANDLE_BOOL
            ast.AstExpr.null_literal:
                return types.TYPE_HANDLE_VOID
            ast.AstExpr.identifier(name):
                let _result = this.sym_table.lookup(name)
                return types.TYPE_HANDLE_INT
            ast.AstExpr.binary(op, left, right):
                let _ = op
                let lt = this.check_expr(left)
                let rt = this.check_expr(right)
                if lt == types.TYPE_HANDLE_FLOAT and rt == types.TYPE_HANDLE_INT:
                    return types.TYPE_HANDLE_FLOAT
                if lt == types.TYPE_HANDLE_INT and rt == types.TYPE_HANDLE_FLOAT:
                    return types.TYPE_HANDLE_FLOAT
                return lt
            ast.AstExpr.unary(op, operand):
                let _ = op
                return this.check_expr(operand)
            ast.AstExpr.call(callee, args):
                this.check_expr(callee)
                var ai: ptr_uint = 0
                while ai < args.len():
                    let a_ptr = args.get(ai) else:
                        fatal(c"checker.check_expr missing arg")
                    unsafe:
                        this.check_expr(read(a_ptr).value)
                    ai += 1
                return types.TYPE_HANDLE_INT
            ast.AstExpr.member(object, member_name):
                let _ = member_name
                this.check_expr(object)
                return types.TYPE_HANDLE_INT
            ast.AstExpr.index(object, index):
                this.check_expr(object)
                this.check_expr(index)
                return types.TYPE_HANDLE_INT
            ast.AstExpr.if_expr(condition, then_val, else_val):
                this.check_expr(condition)
                this.check_expr(then_val)
                this.check_expr(else_val)
                return types.TYPE_HANDLE_INT
            ast.AstExpr.cast(target_type, value):
                let type_ref = this.resolve_type_ref(target_type)
                this.check_expr(value)
                return type_ref
            ast.AstExpr.reinterpret(target_type, value):
                let type_ref = this.resolve_type_ref(target_type)
                this.check_expr(value)
                return type_ref
            ast.AstExpr.range(start, end):
                this.check_expr(start)
                this.check_expr(end)
                return types.TYPE_HANDLE_INT
            _:
                return types.TYPE_HANDLE_VOID

    editable function resolve_type_ref(type_ref: ast.TypeRef) -> types.TypeHandle:
        match type_ref:
            ast.TypeRef.named(name, type_args):
                let _ = type_args
                let result = this.compat.lookup_type(name) else:
                    return types.TYPE_HANDLE_VOID
                return result
            ast.TypeRef.ptr_type(pointee):
                let inner = this.resolve_type_ref(pointee)
                return this.compat.registry.pointer_type(inner)
            ast.TypeRef.const_ptr_type(pointee):
                let inner = this.resolve_type_ref(pointee)
                return this.compat.registry.const_ptr_type(inner)
            ast.TypeRef.span_type(element):
                let inner = this.resolve_type_ref(element)
                return this.compat.registry.span_type(inner)
            ast.TypeRef.array_type(element, size):
                let inner = this.resolve_type_ref(element)
                let _ = size
                return this.compat.registry.array_type(inner, 0)
            ast.TypeRef.nullable_type(inner):
                let inner_h = this.resolve_type_ref(inner)
                return this.compat.registry.nullable_type(inner_h)
            ast.TypeRef.void_type:
                return types.TYPE_HANDLE_VOID
            _:
                return types.TYPE_HANDLE_VOID
