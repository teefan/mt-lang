## Lowerer — AST → IR transformation.

import compiler.parser.ast as ast
import compiler.parser.operators as ops_mod
import compiler.lowering.ir as ir
import std.intern
import std.mem.arena
import std.str
import std.vec

type B = ops_mod.BinaryOp


struct Lowerer:
    arena: arena.Arena
    interner: ptr[intern.Interner]


public function lower(
    file: ptr[ast.SourceFile],
    interner: ptr[intern.Interner],
) -> ir.IrProgram:
    var l = Lowerer(
        arena = arena.create(64 * 1024),
        interner = interner,
    )
    return l.lower_impl(file)


extending Lowerer:
    editable function lower_impl(file: ptr[ast.SourceFile]) -> ir.IrProgram:
        var functions = vec.Vec[ir.IrFunction].create()
        let decls_span = unsafe: file.decls.as_span()
        var i: ptr_uint = 0
        while i < decls_span.len:
            let decl = unsafe: read(decls_span.data + i)
            unsafe:
                match read(decl):
                    ast.Decl.function_def(name, _, params, return_type, body, _, _, _, _):
                        let f = this.lower_function(name, params, return_type, body)
                        functions.push(f)
                    _:
                        pass
            i += 1
        return ir.IrProgram(functions = this.copy_funcs(ref_of(functions)))


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
                type_c = this.type_c_name(param.type_ref),
            ))
            i += 1

        var ir_body = this.lower_block(body)

        return ir.IrFunction(
            name = name,
            params = this.copy_params(ref_of(ir_params)),
            return_c = this.type_c_name(return_type),
            body = this.copy_stmts(ref_of(ir_body)),
        )


    ## ── type → C name ──────────────────────────────────────────────

    function type_c_name(type_ref: ptr[ast.Type]) -> str:
        unsafe:
            match read(type_ref):
                ast.Type.named_type(name, _):
                    let s = this.name_str(name)
                    return this.map_type_c(s)
                _:
                    return "int"


    function map_type_c(mt_name: str) -> str:
        if mt_name.equal("int"):
            return "int"
        if mt_name.equal("float"):
            return "float"
        if mt_name.equal("double"):
            return "double"
        if mt_name.equal("bool"):
            return "bool"
        if mt_name.equal("void"):
            return "void"
        if mt_name.equal("str"):
            return "char*"
        if mt_name.equal("cstr"):
            return "char*"
        if mt_name.equal("byte"):
            return "int8_t"
        if mt_name.equal("ubyte"):
            return "uint8_t"
        if mt_name.equal("short"):
            return "int16_t"
        if mt_name.equal("ushort"):
            return "uint16_t"
        if mt_name.equal("uint"):
            return "uint32_t"
        if mt_name.equal("long"):
            return "int64_t"
        if mt_name.equal("ulong"):
            return "uint64_t"
        if mt_name.equal("char"):
            return "char"
        return "int"


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
                    let v = this.lower_expr(value)
                    output.push(ir.IrStmt.return_stmt(value = v))
                ast.Stmt.expression(expr, _):
                    let v = this.lower_expr(expr)
                    output.push(ir.IrStmt.expr_stmt(expr = v))
                _:
                    pass


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
                ast.Expr.call(callee, args, _):
                    let cname = this.callee_name(callee)
                    var a = this.lower_args(args)
                    return ir.IrExpr.call(name = cname, args = this.copy_ir_exprs(ref_of(a)))
                _:
                    return ir.IrExpr.integer(value = 0)


    editable function callee_name(expr: ptr[ast.Expr]) -> str:
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


    ## ── operators ──────────────────────────────────────────────────

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
