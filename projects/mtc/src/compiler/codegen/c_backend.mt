## C Backend — IR → C source emission.

import compiler.lowering.ir as ir
import std.string

struct CWriter:
    buf: string.String
    indent_level: ptr_uint


public function write_program(program: ir.IrProgram) -> str:
    var w = CWriter(
        buf = string.String.with_capacity(8192),
        indent_level = 0,
    )
    w.write_program_impl(program)
    return w.buf.as_str()


extending CWriter:
    editable function write_program_impl(program: ir.IrProgram) -> void:
        this.writeln("#include <stdint.h>")
        this.writeln("#include <stdbool.h>")
        this.writeln("")

        var ei: ptr_uint = 0
        while ei < program.enums.len:
            let e = unsafe: read(program.enums.data + ei)
            this.write_enum(e)
            this.writeln("")
            ei += 1

        var si: ptr_uint = 0
        while si < program.structs.len:
            let s = unsafe: read(program.structs.data + si)
            this.write_struct(s)
            this.writeln("")
            si += 1

        var fi: ptr_uint = 0
        while fi < program.functions.len:
            let func = unsafe: read(program.functions.data + fi)
            this.write_function(func)
            this.writeln("")
            fi += 1

    editable function write_enum(e: ir.IrEnum) -> void:
        this.writeln("typedef enum {")
        var j: ptr_uint = 0
        while j < e.members.len:
            let m = unsafe: read(e.members.data + j)
            this.write("    ")
            this.write(m.name)
            this.write(" = ")
            this.write_int(m.value)
            this.writeln(",")
            j += 1
        this.write("} ")
        this.write(e.name)
        this.writeln(";")

    editable function write_struct(s: ir.IrStruct) -> void:
        this.writeln("typedef struct {")
        var j: ptr_uint = 0
        while j < s.fields.len:
            let field = unsafe: read(s.fields.data + j)
            this.write("    ")
            this.write(field.type_c)
            this.write(" ")
            this.write(field.name)
            this.writeln(";")
            j += 1
        this.write("} ")
        this.write(s.name)
        this.writeln(";")


    editable function write_function(func: ir.IrFunction) -> void:
        this.write(func.return_c)
        this.write(" ")
        this.write(func.name)
        this.write("(")
        var i: ptr_uint = 0
        while i < func.params.len:
            if i > 0:
                this.write(", ")
            let param = unsafe: read(func.params.data + i)
            this.write(param.type_c)
            if func.is_editable and i == 0:
                this.write("*")
            this.write(" ")
            this.write(param.name)
            i += 1
        this.writeln(") {")
        this.indent_level += 1
        var j: ptr_uint = 0
        while j < func.body.len:
            let stmt = unsafe: read(func.body.data + j)
            this.write_stmt(stmt)
            j += 1
        this.indent_level -= 1
        this.writeln("}")


    ## ── statements ─────────────────────────────────────────────────

    editable function write_stmt(stmt: ir.IrStmt) -> void:
        match stmt:
            ir.IrStmt.return_stmt(value):
                this.write_indent()
                this.write("return ")
                this.write_expr(value)
                this.writeln(";")
            ir.IrStmt.return_void:
                this.write_indent()
                this.writeln("return;")
            ir.IrStmt.expr_stmt(expr):
                this.write_indent()
                this.write_expr(expr)
                this.writeln(";")
            ir.IrStmt.decl(name, type_c, init):
                this.write_indent()
                this.write(type_c)
                this.write(" ")
                this.write(name)
                this.write(" = ")
                this.write_expr(init)
                this.writeln(";")
            ir.IrStmt.assign(target, op_kind, value):
                this.write_indent()
                this.write(target)
                this.write(" ")
                this.write(op_kind)
                this.write(" ")
                this.write_expr(value)
                this.writeln(";")
            ir.IrStmt.assign_expr(target, op_kind, value):
                this.write_indent()
                this.write_expr(target)
                this.write(" ")
                this.write(op_kind)
                this.write(" ")
                this.write_expr(value)
                this.writeln(";")
            ir.IrStmt.if_stmt(condition, then_body, else_body):
                this.write_indent()
                this.write("if (")
                this.write_expr(condition)
                this.writeln(") {")
                this.indent_level += 1
                var ti: ptr_uint = 0
                while ti < then_body.len:
                    let ts = unsafe: read(then_body.data + ti)
                    this.write_stmt(ts)
                    ti += 1
                this.indent_level -= 1
                if else_body.len > 0:
                    this.write_indent()
                    this.writeln("} else {")
                    this.indent_level += 1
                    var ei: ptr_uint = 0
                    while ei < else_body.len:
                        let es = unsafe: read(else_body.data + ei)
                        this.write_stmt(es)
                        ei += 1
                    this.indent_level -= 1
                this.write_indent()
                this.writeln("}")
            ir.IrStmt.while_stmt(condition, body):
                this.write_indent()
                this.write("while (")
                this.write_expr(condition)
                this.writeln(") {")
                this.indent_level += 1
                var wi: ptr_uint = 0
                while wi < body.len:
                    let ws = unsafe: read(body.data + wi)
                    this.write_stmt(ws)
                    wi += 1
                this.indent_level -= 1
                this.write_indent()
                this.writeln("}")
            ir.IrStmt.block(stmts):
                var bi: ptr_uint = 0
                while bi < stmts.len:
                    let bs = unsafe: read(stmts.data + bi)
                    this.write_stmt(bs)
                    bi += 1
            ir.IrStmt.match_stmt(scrutinee, arms):
                this.write_match(scrutinee, arms)
            ir.IrStmt.for_stmt(binding, iterable, body):
                this.write_indent()
                this.write("for (ptr_uint _i = 0; _i < ")
                this.write_expr(iterable)
                this.write("; _i++) {")
                this.writeln("")
                this.indent_level += 1
                var fi: ptr_uint = 0
                while fi < body.len:
                    let fs = unsafe: read(body.data + fi)
                    this.write_stmt(fs)
                    fi += 1
                this.indent_level -= 1
                this.write_indent()
                this.writeln("}")
            ir.IrStmt.for_range(binding, start, end, body):
                this.write_indent()
                this.write("for (int ")
                this.write(binding)
                this.write(" = ")
                this.write_expr(start)
                this.write("; ")
                this.write(binding)
                this.write(" < ")
                this.write_expr(end)
                this.write("; ")
                this.write(binding)
                this.writeln("++) {")
                this.indent_level += 1
                var ri: ptr_uint = 0
                while ri < body.len:
                    let rs = unsafe: read(body.data + ri)
                    this.write_stmt(rs)
                    ri += 1
                this.indent_level -= 1
                this.write_indent()
                this.writeln("}")
            ir.IrStmt.break_stmt:
                this.write_indent()
                this.writeln("break;")
            ir.IrStmt.continue_stmt:
                this.write_indent()
                this.writeln("continue;")


    ## ── match ────────────────────────────────────────────────────────

    editable function write_match(scrutinee: ir.IrExpr, arms: span[ir.IrMatchArm]) -> void:
        var i: ptr_uint = 0
        while i < arms.len:
            let arm = unsafe: read(arms.data + i)
            let is_wildcard = arm.values.len == 0
            let is_last = i + 1 == arms.len

            if is_wildcard:
                this.write_indent()
                this.writeln("} else {")
            else:
                if i == 0:
                    this.write_indent()
                    this.write("if (")
                else:
                    this.write_indent()
                    this.write("} else if (")
                var vi: ptr_uint = 0
                while vi < arm.values.len:
                    if vi > 0:
                        this.write(" || ")
                    this.write_expr(scrutinee)
                    this.write(" == ")
                    let v = unsafe: read(arm.values.data + vi)
                    this.write_expr(v)
                    vi += 1
                this.writeln(") {")

            this.indent_level += 1
            var bi: ptr_uint = 0
            while bi < arm.body.len:
                let bs = unsafe: read(arm.body.data + bi)
                this.write_stmt(bs)
                bi += 1
            this.indent_level -= 1

            if is_last:
                this.write_indent()
                this.writeln("}")
            i += 1


    ## ── expressions ────────────────────────────────────────────────

    editable function write_expr(expr: ir.IrExpr) -> void:
        match expr:
            ir.IrExpr.integer(value):
                this.write_int(value)
            ir.IrExpr.null_value:
                this.write("0")
            ir.IrExpr.unary(op, operand):
                this.write(op)
                unsafe: this.write_expr(read(operand))
            ir.IrExpr.name(name):
                this.write(name)
            ir.IrExpr.binary(op, left, right):
                this.write("(")
                unsafe: this.write_expr(read(left))
                this.write(" ")
                this.write(op)
                this.write(" ")
                unsafe: this.write_expr(read(right))
                this.write(")")
            ir.IrExpr.call(name, args):
                this.write(name)
                this.write("(")
                var i: ptr_uint = 0
                while i < args.len:
                    if i > 0:
                        this.write(", ")
                    unsafe: this.write_expr(read(args.data + i))
                    i += 1
                this.write(")")
            ir.IrExpr.access(receiver, member):
                unsafe: this.write_expr(read(receiver))
                this.write(".")
                this.write(member)
            ir.IrExpr.ptr_access(receiver, member):
                unsafe: this.write_expr(read(receiver))
                this.write("->")
                this.write(member)
            ir.IrExpr.deref(operand):
                this.write("(*")
                unsafe: this.write_expr(read(operand))
                this.write(")")
            ir.IrExpr.address(operand):
                this.write("(&")
                unsafe: this.write_expr(read(operand))
                this.write(")")
            ir.IrExpr.aggregate(name, fields):
                this.write("((")
                this.write(name)
                this.write("){")
                var ai: ptr_uint = 0
                while ai < fields.len:
                    if ai > 0:
                        this.write(", ")
                    let f = unsafe: read(fields.data + ai)
                    this.write(".")
                    this.write(f.name)
                    this.write(" = ")
                    this.write_expr(f.value)
                    ai += 1
                this.write("})")


    ## ── helpers ────────────────────────────────────────────────────

    editable function write_int(value: int) -> void:
        var buf: str_buffer[32]
        buf.assign_format(f"#{value}")
        this.buf.append(buf.as_str())


    editable function write(text: str) -> void:
        this.buf.append(text)


    editable function writeln(text: str) -> void:
        this.buf.append(text)
        this.buf.append("\n")


    editable function write_indent() -> void:
        var i: ptr_uint = 0
        while i < this.indent_level:
            this.buf.append("    ")
            i += 1
