import std.string as string
import cir
import type_check.types as types

public struct Emitter:
    output: string.String
    indent_level: uint

extending Emitter:
    public static function create() -> Emitter:
        return Emitter(output = string.String.create(), indent_level = 0)

    public editable function emit_c(program: ref[cir.CirProgram]) -> str:
        var p = program
        this.output.append("#include <stdlib.h>")
        this.output.append("\n")
        this.output.append("\n")

        var i: ptr_uint = 0
        while i < p.functions.len():
            let fp = p.functions.get(i) else:
                fatal(c"emitter.emit_c missing function")
            unsafe:
                this.emit_function(read(fp))
            if i + 1 < p.functions.len():
                this.output.append("\n")
            i += 1
        return this.output.as_str()

    editable function emit_indent() -> void:
        var i: uint = 0
        while i < this.indent_level:
            this.output.append("    ")
            i += 1

    editable function emit_line(text: str) -> void:
        this.emit_indent()
        this.output.append(text)
        this.output.append("\n")

    editable function emit_function(f: ref[cir.CirFunction]) -> void:
        var fun = f
        this.output.append("int ")
        this.output.append(fun.name)
        this.output.append("(void) {\n")
        this.indent_level += 1

        var si: ptr_uint = 0
        while si < fun.stmts.len():
            let sp = fun.stmts.get(si) else:
                fatal(c"emitter.emit_function missing stmt")
            unsafe:
                this.emit_stmt(read(sp), fun)
            si += 1

        this.indent_level -= 1
        this.emit_line("}")

    editable function emit_stmt(s: ref[cir.CirStmt], fun: ref[cir.CirFunction]) -> void:
        var stmt = s
        if stmt.kind == cir.CirStmtKind.return_stmt:
            if stmt.children.len() > 0:
                let idx_ptr = stmt.children.get(ptr_uint<-(0)) else:
                    fatal(c"emitter.emit_stmt missing return expr")
                unsafe:
                    let idx = read(idx_ptr)
                    let ep = fun.exprs.get(ptr_uint<-(idx)) else:
                        fatal(c"emitter.emit_stmt missing expr at index")
                    this.emit_indent()
                    this.output.append("return ")
                    this.emit_expr(read(ep), fun)
                    this.output.append(";\n")
            else:
                this.emit_line("return 0;")
        else if stmt.kind == cir.CirStmtKind.expr_stmt:
            if stmt.value != "":
                let val_name = stmt.value
                this.emit_indent()
                this.output.append("int ")
                this.output.append(val_name)
                this.output.append(" = ")
                if stmt.children.len() > 0:
                    let idx_ptr = stmt.children.get(ptr_uint<-(0)) else:
                        fatal(c"emitter.emit_stmt missing expr child")
                    unsafe:
                        let idx = read(idx_ptr)
                        let ep = fun.exprs.get(ptr_uint<-(idx)) else:
                            fatal(c"emitter.emit_stmt missing expr at index")
                        this.emit_expr(read(ep), fun)
                this.output.append(";\n")
        else if stmt.kind == cir.CirStmtKind.assign_stmt:
            if stmt.children.len() >= 2:
                let tgt_ptr = stmt.children.get(ptr_uint<-(0)) else:
                    fatal(c"emitter.emit_stmt missing assign_stmt target")
                let val_ptr = stmt.children.get(ptr_uint<-(1)) else:
                    fatal(c"emitter.emit_stmt missing assign_stmt value")
                this.emit_indent()
                unsafe:
                    let tgt_idx = read(tgt_ptr)
                    let tgt_ep = fun.exprs.get(ptr_uint<-(tgt_idx)) else:
                        fatal(c"emitter.emit_stmt missing assign_stmt target expr")
                    this.emit_expr(read(tgt_ep), fun)
                this.output.append(" = ")
                unsafe:
                    let val_idx = read(val_ptr)
                    let val_ep = fun.exprs.get(ptr_uint<-(val_idx)) else:
                        fatal(c"emitter.emit_stmt missing assign_stmt value expr")
                    this.emit_expr(read(val_ep), fun)
                this.output.append(";\n")
        else if stmt.kind == cir.CirStmtKind.if_stmt:
            this.emit_indent()
            this.output.append("if (")
            if stmt.children.len() > 0:
                let idx_ptr = stmt.children.get(ptr_uint<-(0)) else:
                    fatal(c"emitter.emit_stmt missing if cond")
                unsafe:
                    let idx = read(idx_ptr)
                    let ep = fun.exprs.get(ptr_uint<-(idx)) else:
                        fatal(c"emitter.emit_stmt missing expr at index")
                    this.emit_expr(read(ep), fun)
            this.output.append(") {\n")
        else if stmt.kind == cir.CirStmtKind.while_stmt:
            this.emit_indent()
            this.output.append("while (")
            if stmt.children.len() > 0:
                let idx_ptr = stmt.children.get(ptr_uint<-(0)) else:
                    fatal(c"emitter.emit_stmt missing while cond")
                unsafe:
                    let idx = read(idx_ptr)
                    let ep = fun.exprs.get(ptr_uint<-(idx)) else:
                        fatal(c"emitter.emit_stmt missing expr at index")
                    this.emit_expr(read(ep), fun)
            this.output.append(") {\n")
        else if stmt.kind == cir.CirStmtKind.for_stmt:
            if stmt.children.len() >= 2:
                let start_ptr = stmt.children.get(ptr_uint<-(0)) else:
                    fatal(c"emitter.emit_stmt missing for start")
                let end_ptr = stmt.children.get(ptr_uint<-(1)) else:
                    fatal(c"emitter.emit_stmt missing for end")
                let binding = stmt.cond
                this.emit_indent()
                this.output.append("for (int ")
                this.output.append(binding)
                this.output.append(" = ")
                unsafe:
                    let start_idx = read(start_ptr)
                    let ep = fun.exprs.get(ptr_uint<-(start_idx)) else:
                        fatal(c"emitter.emit_stmt missing for start expr")
                    this.emit_expr(read(ep), fun)
                this.output.append("; ")
                this.output.append(binding)
                this.output.append(" < ")
                unsafe:
                    let end_idx = read(end_ptr)
                    let ep = fun.exprs.get(ptr_uint<-(end_idx)) else:
                        fatal(c"emitter.emit_stmt missing for end expr")
                    this.emit_expr(read(ep), fun)
                this.output.append("; ")
                this.output.append(binding)
                this.output.append("++) {\n")
        else if stmt.kind == cir.CirStmtKind.block:
            this.emit_indent()
            this.output.append("}\n")
        else if stmt.kind == cir.CirStmtKind.break_stmt:
            this.emit_line("break;")
        else if stmt.kind == cir.CirStmtKind.continue_stmt:
            this.emit_line("continue;")
        else if stmt.kind == cir.CirStmtKind.fatal_call:
            this.emit_indent()
            this.output.append("mt_fatal(")
            if stmt.message != "":
                this.output.append(stmt.message)
            this.output.append(");\n")

    editable function emit_expr(e: ref[cir.CirExpr], fun: ref[cir.CirFunction]) -> void:
        var expr = e
        if expr.kind == cir.CirExprKind.int_lit:
            this.output.append(expr.str_value)
        else if expr.kind == cir.CirExprKind.identifier:
            this.output.append(expr.name)
        else if expr.kind == cir.CirExprKind.binary:
            unsafe:
                let left_ep = fun.exprs.get(ptr_uint<-(expr.left)) else:
                    fatal(c"emitter.emit_expr missing binary left")
                this.emit_expr(read(left_ep), fun)
            this.output.append(" ")
            this.output.append(expr.op)
            this.output.append(" ")
            unsafe:
                let right_ep = fun.exprs.get(ptr_uint<-(expr.right)) else:
                    fatal(c"emitter.emit_expr missing binary right")
                this.emit_expr(read(right_ep), fun)
        else if expr.kind == cir.CirExprKind.unary:
            this.output.append(expr.op)
            unsafe:
                let operand_ep = fun.exprs.get(ptr_uint<-(expr.left)) else:
                    fatal(c"emitter.emit_expr missing unary operand")
                this.emit_expr(read(operand_ep), fun)
        else if expr.kind == cir.CirExprKind.bool_lit:
            if expr.bool_value:
                this.output.append("1")
            else:
                this.output.append("0")
        else if expr.kind == cir.CirExprKind.float_lit:
            this.output.append(expr.str_value)
        else if expr.kind == cir.CirExprKind.str_lit:
            this.output.append(expr.str_value)
        else if expr.kind == cir.CirExprKind.null_lit:
            this.output.append("NULL")
        else if expr.kind == cir.CirExprKind.call:
            if expr.op != "":
                this.output.append(expr.op)
            this.output.append("(")
            unsafe:
                if expr.left < fun.exprs.len():
                    let callee_ep = fun.exprs.get(ptr_uint<-(expr.left)) else:
                        fatal(c"emitter.emit_expr missing call callee")
                    this.emit_expr(read(callee_ep), fun)
            this.output.append(")")
        else if expr.kind == cir.CirExprKind.member:
            unsafe:
                let obj_ep = fun.exprs.get(ptr_uint<-(expr.left)) else:
                    fatal(c"emitter.emit_expr missing member obj")
                this.emit_expr(read(obj_ep), fun)
            this.output.append(".")
            this.output.append(expr.name)
        else if expr.kind == cir.CirExprKind.index:
            unsafe:
                let obj_ep = fun.exprs.get(ptr_uint<-(expr.left)) else:
                    fatal(c"emitter.emit_expr missing index obj")
                this.emit_expr(read(obj_ep), fun)
            this.output.append("[")
            unsafe:
                let idx_ep = fun.exprs.get(ptr_uint<-(expr.right)) else:
                    fatal(c"emitter.emit_expr missing index idx")
                this.emit_expr(read(idx_ep), fun)
            this.output.append("]")
        else if expr.kind == cir.CirExprKind.cast_expr:
            this.output.append("(")
            this.output.append(this.get_ctype(expr.type_handle))
            this.output.append(")(")
            unsafe:
                let val_ep = fun.exprs.get(ptr_uint<-(expr.left)) else:
                    fatal(c"emitter.emit_expr missing cast value")
                this.emit_expr(read(val_ep), fun)
            this.output.append(")")
        else if expr.kind == cir.CirExprKind.struct_lit:
            this.output.append("{")
            if expr.struct_name != "":
                this.output.append(".")
                this.output.append(expr.struct_name)
                this.output.append(" = ")
            this.output.append("{")
            var fi: ptr_uint = 0
            while fi < expr.field_indices.len():
                if fi > 0:
                    this.output.append(", ")
                unsafe:
                    let f_idx_ptr = expr.field_indices.get(fi) else:
                        fatal(c"emitter.emit_expr missing struct field")
                    let f_idx = read(f_idx_ptr)
                    let f_ep = fun.exprs.get(ptr_uint<-(f_idx)) else:
                        fatal(c"emitter.emit_expr missing struct field expr")
                    this.emit_expr(read(f_ep), fun)
                fi += 1
            this.output.append("}")

    function get_ctype(handle: types.TypeHandle) -> str:
        if handle == types.TYPE_HANDLE_INT:
            return "int"
        else if handle == types.TYPE_HANDLE_VOID:
            return "void"
        else if handle == types.TYPE_HANDLE_FLOAT:
            return "float"
        else if handle == types.TYPE_HANDLE_BOOL:
            return "int"
        else if handle == types.TYPE_HANDLE_UBYTE:
            return "unsigned char"
        else if handle == types.TYPE_HANDLE_STR:
            return "mt_str"
        else if handle == types.TYPE_HANDLE_CSTR:
            return "char*"
        return "int"
