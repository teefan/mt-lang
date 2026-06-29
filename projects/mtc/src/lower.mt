import std.vec as vec
import parser.ast as ast
import typeck.types as types
import lower.cir

public struct Lowerer:
    current: cir.CirFunction
    tmp_counter: uint

extending Lowerer:
    public static function create() -> Lowerer:
        return Lowerer(
            current = cir.CirFunction(
                name = "",
                params = vec.Vec[cir.CirField].create(),
                return_type = types.TYPE_HANDLE_VOID,
                stmts = vec.Vec[cir.CirStmt].create(),
                exprs = vec.Vec[cir.CirExpr].create(),
                root_stmt = 0
            ),
            tmp_counter = 0
        )

    public editable function lower_module(module_ast: ast.Module, program: ref[cir.CirProgram]) -> void:
        var m = module_ast
        var i: ptr_uint = 0
        while i < m.declarations.len():
            let decl_ptr = m.declarations.get(i) else:
                fatal(c"lowerer.lower_module missing declaration")
            unsafe:
                this.lower_decl(read(decl_ptr), program)
            i += 1

    editable function lower_decl(decl: ast.AstDecl, program: ref[cir.CirProgram]) -> void:
        match decl:
            ast.AstDecl.function_decl(name, params, return_type, body, type_params, is_async, is_const, is_public, docs):
                let _ = return_type
                let _ = type_params
                let _ = is_async
                let _ = is_const
                let _ = is_public
                let _ = docs
                var f = cir.CirFunction(
                    name = name,
                    params = vec.Vec[cir.CirField].create(),
                    return_type = types.TYPE_HANDLE_INT,
                    stmts = vec.Vec[cir.CirStmt].create(),
                    exprs = vec.Vec[cir.CirExpr].create(),
                    root_stmt = 0
                )
                var pi: ptr_uint = 0
                while pi < params.len():
                    let p_ptr = params.get(pi) else:
                        fatal(c"lowerer.lower_decl missing param")
                    unsafe:
                        let p = read(p_ptr)
                        f.params.push(cir.CirField(name = p.name, type_handle = types.TYPE_HANDLE_INT))
                    pi += 1
                this.current = f
                this.tmp_counter = 0
                var bi: ptr_uint = 0
                while bi < body.len():
                    let s_ptr = body.get(bi) else:
                        fatal(c"lowerer.lower_decl missing stmt")
                    unsafe:
                        this.lower_stmt(read(s_ptr))
                    bi += 1
                program.add_function(this.current)
            ast.AstDecl.extending_block(target_type, methods):
                let _ = target_type
                var mi: ptr_uint = 0
                while mi < methods.len():
                    let m_ptr = methods.get(mi) else:
                        fatal(c"lowerer.lower_decl missing method")
                    unsafe:
                        this.lower_decl(read(m_ptr), program)
                    mi += 1
            ast.AstDecl.struct_decl(name, fields, type_params, impls, attrs, is_public, docs):
                let _ = name
                let _ = fields
                let _ = type_params
                let _ = impls
                let _ = attrs
                let _ = is_public
                let _ = docs
            _:
                pass

    editable function lower_stmt(stmt: ast.AstStmt) -> void:
        match stmt:
            ast.AstStmt.return_stmt(value):
                let expr_idx = this.lower_expr(value)
                var children = vec.Vec[ptr_uint].create()
                children.push(expr_idx)
                this.current.stmts.push(cir.CirStmt(
                    kind = cir.CirStmtKind.return_stmt,
                    cond = "",
                    init = "",
                    increment = "",
                    label = "",
                    value = "",
                    target = "",
                    callee = "",
                    message = "",
                    children = children
                ))
            ast.AstStmt.expr_stmt(expr):
                this.lower_expr(expr)
            ast.AstStmt.let_stmt(name, type_ref, init, else_block, else_error_binding):
                let _ = type_ref
                let _ = else_block
                let _ = else_error_binding
                let init_idx = this.lower_expr(init)
                var children = vec.Vec[ptr_uint].create()
                children.push(init_idx)
                this.current.stmts.push(cir.CirStmt(
                    kind = cir.CirStmtKind.expr_stmt,
                    cond = "",
                    init = "",
                    increment = "",
                    label = "",
                    value = name,
                    target = "",
                    callee = "",
                    message = "",
                    children = children
                ))
            ast.AstStmt.var_stmt(name, type_ref, init, else_block, else_error_binding):
                let _ = type_ref
                let _ = else_block
                let _ = else_error_binding
                let init_idx = this.lower_expr(init)
                var children = vec.Vec[ptr_uint].create()
                children.push(init_idx)
                this.current.stmts.push(cir.CirStmt(
                    kind = cir.CirStmtKind.expr_stmt,
                    cond = "",
                    init = "",
                    increment = "",
                    label = "",
                    value = name,
                    target = "",
                    callee = "",
                    message = "",
                    children = children
                ))
            ast.AstStmt.assign(target, value):
                let target_idx = this.lower_expr(target)
                let value_idx = this.lower_expr(value)
                var children = vec.Vec[ptr_uint].create()
                children.push(target_idx)
                children.push(value_idx)
                this.current.stmts.push(cir.CirStmt(
                    kind = cir.CirStmtKind.assign,
                    cond = "",
                    init = "",
                    increment = "",
                    label = "",
                    value = "",
                    target = "",
                    callee = "",
                    message = "",
                    children = children
                ))
            ast.AstStmt.if_stmt(condition, then_body, elifs, else_body):
                let cond_idx = this.lower_expr(condition)
                var children = vec.Vec[ptr_uint].create()
                children.push(cond_idx)
                this.current.stmts.push(cir.CirStmt(
                    kind = cir.CirStmtKind.if_stmt,
                    cond = "",
                    init = "",
                    increment = "",
                    label = "",
                    value = "",
                    target = "",
                    callee = "",
                    message = "",
                    children = children
                ))
                var ti: ptr_uint = 0
                while ti < then_body.len():
                    let s_ptr = then_body.get(ti) else:
                        fatal(c"lowerer.lower_stmt missing then")
                    unsafe:
                        this.lower_stmt(read(s_ptr))
                    ti += 1
                var ei: ptr_uint = 0
                while ei < elifs.len():
                    let e_ptr = elifs.get(ei) else:
                        fatal(c"lowerer.lower_stmt missing elif")
                    unsafe:
                        let econd = this.lower_expr(read(e_ptr).condition)
                        let _econd = econd
                        var ebi: ptr_uint = 0
                        while ebi < read(e_ptr).body.len():
                            let s_ptr = read(e_ptr).body.get(ebi) else:
                                fatal(c"lowerer.lower_stmt missing elif stmt")
                            unsafe:
                                this.lower_stmt(read(s_ptr))
                            ebi += 1
                    ei += 1
                if else_body.len() > 0:
                    var eli: ptr_uint = 0
                    while eli < else_body.len():
                        let s_ptr = else_body.get(eli) else:
                            fatal(c"lowerer.lower_stmt missing else")
                        unsafe:
                            this.lower_stmt(read(s_ptr))
                        eli += 1
            ast.AstStmt.while_stmt(condition, body):
                let cond_idx = this.lower_expr(condition)
                var children = vec.Vec[ptr_uint].create()
                children.push(cond_idx)
                this.current.stmts.push(cir.CirStmt(
                    kind = cir.CirStmtKind.while_stmt,
                    cond = "",
                    init = "",
                    increment = "",
                    label = "",
                    value = "",
                    target = "",
                    callee = "",
                    message = "",
                    children = children
                ))
                var bi: ptr_uint = 0
                while bi < body.len():
                    let s_ptr = body.get(bi) else:
                        fatal(c"lowerer.lower_stmt missing while")
                    unsafe:
                        this.lower_stmt(read(s_ptr))
                    bi += 1
            ast.AstStmt.for_range_literal(binding, start, end, body):
                let _bind = this.lower_expr(ast.AstExpr.identifier(name = binding))
                let start_idx = this.lower_expr(start)
                let end_idx = this.lower_expr(end)
                var children = vec.Vec[ptr_uint].create()
                children.push(start_idx)
                children.push(end_idx)
                this.current.stmts.push(cir.CirStmt(
                    kind = cir.CirStmtKind.for_range,
                    cond = binding,
                    init = "",
                    increment = "",
                    label = "",
                    value = "",
                    target = "",
                    callee = "",
                    message = "",
                    children = children
                ))
                var bi: ptr_uint = 0
                while bi < body.len():
                    let s_ptr = body.get(bi) else:
                        fatal(c"lowerer.lower_stmt missing for")
                    unsafe:
                        this.lower_stmt(read(s_ptr))
                    bi += 1
            ast.AstStmt.if_inline(condition, then_stmt, else_stmt):
                let cond_idx = this.lower_expr(condition)
                var children = vec.Vec[ptr_uint].create()
                children.push(cond_idx)
                this.current.stmts.push(cir.CirStmt(
                    kind = cir.CirStmtKind.if_stmt,
                    cond = "",
                    init = "",
                    increment = "",
                    label = "",
                    value = "",
                    target = "",
                    callee = "",
                    message = "",
                    children = children
                ))
                this.lower_stmt(then_stmt)
                this.lower_stmt(else_stmt)
            _:
                pass

    editable function lower_expr(expr: ast.AstExpr) -> ptr_uint:
        match expr:
            ast.AstExpr.integer_literal(value_str):
                this.current.exprs.push(cir.CirExpr(
                    kind = cir.CirExprKind.int_lit,
                    name = "",
                    op = "",
                    str_value = value_str,
                    int_value = 0,
                    bool_value = false,
                    type_handle = types.TYPE_HANDLE_INT,
                    left = 0,
                    right = 0,
                    struct_name = "",
                    field_indices = vec.Vec[ptr_uint].create()
                ))
                return this.current.exprs.len() - 1
            ast.AstExpr.identifier(name):
                this.current.exprs.push(cir.CirExpr(
                    kind = cir.CirExprKind.identifier,
                    name = name,
                    op = "",
                    str_value = "",
                    int_value = 0,
                    bool_value = false,
                    type_handle = types.TYPE_HANDLE_INT,
                    left = 0,
                    right = 0,
                    struct_name = "",
                    field_indices = vec.Vec[ptr_uint].create()
                ))
                return this.current.exprs.len() - 1
            ast.AstExpr.binary(op, left, right):
                let l_idx = this.lower_expr(left)
                let r_idx = this.lower_expr(right)
                this.current.exprs.push(cir.CirExpr(
                    kind = cir.CirExprKind.binary,
                    name = "",
                    op = op,
                    str_value = "",
                    int_value = 0,
                    bool_value = false,
                    type_handle = types.TYPE_HANDLE_INT,
                    left = l_idx,
                    right = r_idx,
                    struct_name = "",
                    field_indices = vec.Vec[ptr_uint].create()
                ))
                return this.current.exprs.len() - 1
            ast.AstExpr.unary(op, operand):
                let operand_idx = this.lower_expr(operand)
                this.current.exprs.push(cir.CirExpr(
                    kind = cir.CirExprKind.unary,
                    name = "",
                    op = op,
                    str_value = "",
                    int_value = 0,
                    bool_value = false,
                    type_handle = types.TYPE_HANDLE_INT,
                    left = operand_idx,
                    right = 0,
                    struct_name = "",
                    field_indices = vec.Vec[ptr_uint].create()
                ))
                return this.current.exprs.len() - 1
            ast.AstExpr.call(callee, args):
                let callee_idx = this.lower_expr(callee)
                this.current.exprs.push(cir.CirExpr(
                    kind = cir.CirExprKind.call,
                    name = "",
                    op = "",
                    str_value = "",
                    int_value = 0,
                    bool_value = false,
                    type_handle = types.TYPE_HANDLE_INT,
                    left = callee_idx,
                    right = 0,
                    struct_name = "",
                    field_indices = vec.Vec[ptr_uint].create()
                ))
                return this.current.exprs.len() - 1
            ast.AstExpr.member(object, member_name):
                let obj_idx = this.lower_expr(object)
                this.current.exprs.push(cir.CirExpr(
                    kind = cir.CirExprKind.member,
                    name = member_name,
                    op = "",
                    str_value = "",
                    int_value = 0,
                    bool_value = false,
                    type_handle = types.TYPE_HANDLE_INT,
                    left = obj_idx,
                    right = 0,
                    struct_name = "",
                    field_indices = vec.Vec[ptr_uint].create()
                ))
                return this.current.exprs.len() - 1
            ast.AstExpr.index(object, index):
                let obj_idx = this.lower_expr(object)
                let idx_idx = this.lower_expr(index)
                this.current.exprs.push(cir.CirExpr(
                    kind = cir.CirExprKind.index,
                    name = "",
                    op = "",
                    str_value = "",
                    int_value = 0,
                    bool_value = false,
                    type_handle = types.TYPE_HANDLE_INT,
                    left = obj_idx,
                    right = idx_idx,
                    struct_name = "",
                    field_indices = vec.Vec[ptr_uint].create()
                ))
                return this.current.exprs.len() - 1
            ast.AstExpr.bool_literal(value):
                this.current.exprs.push(cir.CirExpr(
                    kind = cir.CirExprKind.bool_lit,
                    name = "",
                    op = "",
                    str_value = "",
                    int_value = 0,
                    bool_value = value,
                    type_handle = types.TYPE_HANDLE_BOOL,
                    left = 0,
                    right = 0,
                    struct_name = "",
                    field_indices = vec.Vec[ptr_uint].create()
                ))
                return this.current.exprs.len() - 1
            ast.AstExpr.float_literal(value_str):
                this.current.exprs.push(cir.CirExpr(
                    kind = cir.CirExprKind.float_lit,
                    name = "",
                    op = "",
                    str_value = value_str,
                    int_value = 0,
                    bool_value = false,
                    type_handle = types.TYPE_HANDLE_FLOAT,
                    left = 0,
                    right = 0,
                    struct_name = "",
                    field_indices = vec.Vec[ptr_uint].create()
                ))
                return this.current.exprs.len() - 1
            ast.AstExpr.string_literal(value_str):
                this.current.exprs.push(cir.CirExpr(
                    kind = cir.CirExprKind.str_lit,
                    name = "",
                    op = "",
                    str_value = value_str,
                    int_value = 0,
                    bool_value = false,
                    type_handle = types.TYPE_HANDLE_STR,
                    left = 0,
                    right = 0,
                    struct_name = "",
                    field_indices = vec.Vec[ptr_uint].create()
                ))
                return this.current.exprs.len() - 1
            ast.AstExpr.range(start, end):
                let s_idx = this.lower_expr(start)
                let e_idx = this.lower_expr(end)
                this.current.exprs.push(cir.CirExpr(
                    kind = cir.CirExprKind.binary,
                    name = "",
                    op = "..",
                    str_value = "",
                    int_value = 0,
                    bool_value = false,
                    type_handle = types.TYPE_HANDLE_INT,
                    left = s_idx,
                    right = e_idx,
                    struct_name = "",
                    field_indices = vec.Vec[ptr_uint].create()
                ))
                return this.current.exprs.len() - 1
            _:
                return 0
