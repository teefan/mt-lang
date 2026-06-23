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
        var i: ptr_uint = 0
        while i < program.functions.len:
            let func = unsafe: read(program.functions.data + i)
            this.write_function(func)
            this.writeln("")
            i += 1


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


    ## ── expressions ────────────────────────────────────────────────

    editable function write_expr(expr: ir.IrExpr) -> void:
        match expr:
            ir.IrExpr.integer(value):
                this.write_int(value)
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
