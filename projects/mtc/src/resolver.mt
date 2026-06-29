import std.vec as vec
import ast
import resolver.symbol as sym

public struct ResolvedModule:
    mod_ast: ast.Module
    sym_table: sym.SymbolTable

public struct Resolver:
    table: sym.SymbolTable
    module_id: uint
    decl_index: uint

extending Resolver:
    public static function create(module_id: uint) -> Resolver:
        return Resolver(table = sym.SymbolTable.create(), module_id = module_id, decl_index = 0)

    public editable function resolve(module_ast: ast.Module) -> ResolvedModule:
        var m = module_ast
        var i: ptr_uint = 0
        while i < m.imports.len():
            let decl_ptr = m.imports.get(i) else:
                fatal(c"resolver.resolve missing import")
            unsafe:
                this.resolve_import(read(decl_ptr))
            i += 1
        i = 0
        while i < m.declarations.len():
            let decl_ptr = m.declarations.get(i) else:
                fatal(c"resolver.resolve missing declaration")
            unsafe:
                this.register_decl(read(decl_ptr))
            i += 1
        i = 0
        while i < m.declarations.len():
            let decl_ptr = m.declarations.get(i) else:
                fatal(c"resolver.resolve missing declaration")
            unsafe:
                this.resolve_decl(read(decl_ptr))
            i += 1
        return ResolvedModule(mod_ast = m, sym_table = this.table)

    editable function resolve_import(decl: ast.AstDecl) -> void:
        match decl:
            ast.AstDecl.import_decl(module_path, alias):
                let _path = module_path
                let _al = alias
            _:
                pass

    editable function register_decl(decl: ast.AstDecl) -> void:
        match decl:
            ast.AstDecl.function_decl(name, params, return_type, body, type_params, is_async, is_const, is_public, docs):
                let _ = params
                let _ = return_type
                let _ = body
                let _ = type_params
                let _ = is_async
                let _ = is_const
                let _ = is_public
                let _ = docs
                this.table.define(name, sym.SymbolKind.sym_function, this.module_id, uint<-(this.decl_index))
                this.decl_index += 1
            ast.AstDecl.const_decl(name, type_ref, init, is_public, docs):
                let _ = type_ref
                let _ = init
                let _ = is_public
                let _ = docs
                this.table.define(name, sym.SymbolKind.sym_const, this.module_id, uint<-(this.decl_index))
                this.decl_index += 1
            ast.AstDecl.struct_decl(name, fields, type_params, impls, attrs, is_public, docs):
                let _ = fields
                let _ = type_params
                let _ = impls
                let _ = attrs
                let _ = is_public
                let _ = docs
                this.table.define(name, sym.SymbolKind.sym_struct, this.module_id, uint<-(this.decl_index))
                this.decl_index += 1
            ast.AstDecl.type_alias(name, type_ref, is_public):
                let _ = type_ref
                let _ = is_public
                this.table.define(name, sym.SymbolKind.sym_type_alias, this.module_id, uint<-(this.decl_index))
                this.decl_index += 1
            ast.AstDecl.var_decl(name, type_ref, init, is_public):
                let _ = type_ref
                let _ = init
                let _ = is_public
                this.table.define(name, sym.SymbolKind.sym_var, this.module_id, uint<-(this.decl_index))
                this.decl_index += 1
            _:
                this.decl_index += 1

    editable function resolve_decl(decl: ast.AstDecl) -> void:
        match decl:
            ast.AstDecl.function_decl(name, params, return_type, body, type_params, is_async, is_const, is_public, docs):
                let _ = name
                let _ = return_type
                let _ = type_params
                let _ = is_async
                let _ = is_const
                let _ = is_public
                let _ = docs
                this.table.enter_scope(sym.ScopeKind.fn_scope)
                var pi: ptr_uint = 0
                while pi < params.len():
                    let p_ptr = params.get(pi) else:
                        fatal(c"resolver.resolve_decl missing param")
                    unsafe:
                        this.table.define(read(p_ptr).name, sym.SymbolKind.sym_local, this.module_id, 0)
                    pi += 1
                var ri: ptr_uint = 0
                while ri < body.len():
                    let s_ptr = body.get(ri) else:
                        fatal(c"resolver.resolve_decl missing stmt")
                    unsafe:
                        this.resolve_stmt(read(s_ptr))
                    ri += 1
                this.table.leave_scope()
            _:
                pass

    editable function resolve_stmt(stmt: ast.AstStmt) -> void:
        match stmt:
            ast.AstStmt.return_stmt(value):
                this.resolve_expr(value)
            ast.AstStmt.let_stmt(name, type_ref, init, else_block, else_error_binding):
                let _ = type_ref
                let _ = else_error_binding
                this.resolve_expr(init)
                this.table.define(name, sym.SymbolKind.sym_local, this.module_id, 0)
                var i: ptr_uint = 0
                while i < else_block.len():
                    let s_ptr = else_block.get(i) else:
                        fatal(c"resolver.resolve_stmt missing else")
                    unsafe:
                        this.resolve_stmt(read(s_ptr))
                    i += 1
            ast.AstStmt.var_stmt(name, type_ref, init, else_block, else_error_binding):
                let _ = type_ref
                let _ = else_error_binding
                this.resolve_expr(init)
                this.table.define(name, sym.SymbolKind.sym_local, this.module_id, 0)
                var i: ptr_uint = 0
                while i < else_block.len():
                    let s_ptr = else_block.get(i) else:
                        fatal(c"resolver.resolve_stmt missing else")
                    unsafe:
                        this.resolve_stmt(read(s_ptr))
                    i += 1
            ast.AstStmt.expr_stmt(expr):
                this.resolve_expr(expr)
            ast.AstStmt.if_stmt(condition, then_body, elifs, else_body):
                this.resolve_expr(condition)
                this.table.enter_scope(sym.ScopeKind.block_scope)
                var ti: ptr_uint = 0
                while ti < then_body.len():
                    let s_ptr = then_body.get(ti) else:
                        fatal(c"resolver.resolve_stmt missing then")
                    unsafe:
                        this.resolve_stmt(read(s_ptr))
                    ti += 1
                this.table.leave_scope()
                var ei: ptr_uint = 0
                while ei < elifs.len():
                    let e_ptr = elifs.get(ei) else:
                        fatal(c"resolver.resolve_stmt missing elif")
                    unsafe:
                        let eb = read(e_ptr)
                        this.resolve_expr(eb.condition)
                        var ebi: ptr_uint = 0
                        while ebi < eb.body.len():
                            let s_ptr = eb.body.get(ebi) else:
                                fatal(c"resolver.resolve_stmt missing elif stmt")
                            unsafe:
                                this.resolve_stmt(read(s_ptr))
                            ebi += 1
                    ei += 1
                if else_body.len() > 0:
                    this.table.enter_scope(sym.ScopeKind.block_scope)
                    var eli: ptr_uint = 0
                    while eli < else_body.len():
                        let s_ptr = else_body.get(eli) else:
                            fatal(c"resolver.resolve_stmt missing else")
                        unsafe:
                            this.resolve_stmt(read(s_ptr))
                        eli += 1
                    this.table.leave_scope()
            ast.AstStmt.while_stmt(condition, body):
                this.resolve_expr(condition)
                this.table.enter_scope(sym.ScopeKind.block_scope)
                var bi: ptr_uint = 0
                while bi < body.len():
                    let s_ptr = body.get(bi) else:
                        fatal(c"resolver.resolve_stmt missing while")
                    unsafe:
                        this.resolve_stmt(read(s_ptr))
                    bi += 1
                this.table.leave_scope()
            ast.AstStmt.for_range_literal(binding, start, end, body):
                this.resolve_expr(start)
                this.resolve_expr(end)
                this.table.enter_scope(sym.ScopeKind.block_scope)
                this.table.define(binding, sym.SymbolKind.sym_local, this.module_id, 0)
                var bi: ptr_uint = 0
                while bi < body.len():
                    let s_ptr = body.get(bi) else:
                        fatal(c"resolver.resolve_stmt missing for")
                    unsafe:
                        this.resolve_stmt(read(s_ptr))
                    bi += 1
                this.table.leave_scope()
            _:
                pass

    editable function resolve_expr(expr: ast.AstExpr) -> void:
        match expr:
            ast.AstExpr.identifier(name):
                let _ = this.table.lookup(name)
            ast.AstExpr.binary(op, left, right):
                let _ = op
                this.resolve_expr(left)
                this.resolve_expr(right)
            ast.AstExpr.call(callee, args):
                this.resolve_expr(callee)
                var ai: ptr_uint = 0
                while ai < args.len():
                    let a_ptr = args.get(ai) else:
                        fatal(c"resolver.resolve_expr missing arg")
                    unsafe:
                        this.resolve_expr(read(a_ptr).value)
                    ai += 1
            ast.AstExpr.member(object, member_name):
                let _ = member_name
                this.resolve_expr(object)
            ast.AstExpr.index(object, index):
                this.resolve_expr(object)
                this.resolve_expr(index)
            ast.AstExpr.if_expr(condition, then_val, else_val):
                this.resolve_expr(condition)
                this.resolve_expr(then_val)
                this.resolve_expr(else_val)
            ast.AstExpr.struct_literal(name, fields, type_args):
                let _ = name
                let _ = type_args
                var fi: ptr_uint = 0
                while fi < fields.len():
                    let f_ptr = fields.get(fi) else:
                        fatal(c"resolver.resolve_expr missing field")
                    unsafe:
                        this.resolve_expr(read(f_ptr).value)
                    fi += 1
            _:
                pass
