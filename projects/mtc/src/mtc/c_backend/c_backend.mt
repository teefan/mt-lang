## C backend — transforms an `ir.Program` into C source text.  This is the
## decoupled back-end: it reads only `ir`, never the analyzer or lowering
## internals.
##
## Mirrors the Ruby CBackend (lib/milk_tea/core/c_backend.rb `generate_c` and the
## type_system / type_declaration / statements / expressions modules).
##
## PHASE 1 scope: base includes, function forward declarations, and function
## bodies over scalar primitives — `return`, local declarations, expression
## statements, integer/bool literals, identifiers, unary/binary operators, and
## direct calls.  Runtime helpers, aggregates, control flow, and reachability
## pruning arrive in later phases.

import std.string as string
import std.str
import std.fmt as fmt

import mtc.ir as ir
import mtc.semantic.types as types


## A backend-stage error.  Placeholder for Phase 1+.
public struct CBackendError:
    message: str
    line: ptr_uint
    column: ptr_uint
    path: str


struct Emitter:
    buffer: string.String


public function generate_c(program: ir.Program) -> string.String:
    var e = Emitter(buffer = string.String.create())

    var i: ptr_uint = 0
    while i < program.includes.len:
        unsafe:
            emit_line(ref_of(e), j2("#include ", read(program.includes.data + i).header))
        i += 1
    emit_line(ref_of(e), "")

    if program.functions.len > 0:
        i = 0
        while i < program.functions.len:
            unsafe:
                emit_line(ref_of(e), j2(function_signature(read(program.functions.data + i)), ";"))
            i += 1
        emit_line(ref_of(e), "")

    i = 0
    while i < program.functions.len:
        unsafe:
            emit_function(ref_of(e), read(program.functions.data + i))
        if i < program.functions.len - 1:
            emit_line(ref_of(e), "")
        i += 1

    return e.buffer


# =============================================================================
#  String helpers
# =============================================================================

function j2(a: str, b: str) -> str:
    var buf = string.String.create()
    buf.append(a)
    buf.append(b)
    return buf.as_str()

function j3(a: str, b: str, c: str) -> str:
    var buf = string.String.create()
    buf.append(a)
    buf.append(b)
    buf.append(c)
    return buf.as_str()

function j4(a: str, b: str, c: str, d: str) -> str:
    var buf = string.String.create()
    buf.append(a)
    buf.append(b)
    buf.append(c)
    buf.append(d)
    return buf.as_str()

function j5(a: str, b: str, c: str, d: str, e: str) -> str:
    var buf = string.String.create()
    buf.append(a)
    buf.append(b)
    buf.append(c)
    buf.append(d)
    buf.append(e)
    return buf.as_str()


function emit_line(e: ref[Emitter], text: str) -> void:
    e.buffer.append(text)
    e.buffer.append("\n")


function indent_c(level: ptr_uint) -> str:
    var buf = string.String.create()
    var i: ptr_uint = 0
    while i < level:
        buf.append("  ")
        i += 1
    return buf.as_str()


function long_to_str(value: long) -> str:
    var buf = string.String.create()
    fmt.append_long(ref_of(buf), value)
    return buf.as_str()


# =============================================================================
#  Type mapping (mirrors c_backend/type_system.rb)
# =============================================================================

function c_type(t: types.Type) -> str:
    match t:
        types.Type.ty_primitive as p:
            return primitive_c_type(p.name)
        types.Type.ty_str:
            return "mt_str"
        _:
            fatal(c"c_backend Phase 1: unsupported C type")


function primitive_c_type(name: str) -> str:
    if name.equal("bool"):
        return "bool"
    if name.equal("byte"):
        return "int8_t"
    if name.equal("ubyte"):
        return "uint8_t"
    if name.equal("char"):
        return "char"
    if name.equal("short"):
        return "int16_t"
    if name.equal("ushort"):
        return "uint16_t"
    if name.equal("int"):
        return "int32_t"
    if name.equal("uint"):
        return "uint32_t"
    if name.equal("long"):
        return "int64_t"
    if name.equal("ulong"):
        return "uint64_t"
    if name.equal("ptr_int"):
        return "intptr_t"
    if name.equal("ptr_uint"):
        return "uintptr_t"
    if name.equal("float"):
        return "float"
    if name.equal("double"):
        return "double"
    if name.equal("void"):
        return "void"
    if name.equal("cstr"):
        return "const char*"
    fatal(c"c_backend Phase 1: unsupported primitive type")


## A scalar declaration `TYPE NAME` (Phase 1 has no arrays/pointers/functions).
function c_declaration(t: types.Type, name: str) -> str:
    return j3(c_type(t), " ", name)


# =============================================================================
#  Function emission (mirrors c_backend/type_declaration.rb)
# =============================================================================

function function_signature(func: ir.Function) -> str:
    let prefix = if func.entry_point: "" else: "static "
    var buf = string.String.create()
    buf.append(prefix)
    buf.append(c_type(func.return_type))
    buf.append(" ")
    buf.append(func.linkage_name)
    buf.append("(")
    buf.append(function_params(func))
    buf.append(")")
    return buf.as_str()


function function_params(func: ir.Function) -> str:
    if func.params.len == 0:
        return "void"
    var buf = string.String.create()
    var i: ptr_uint = 0
    while i < func.params.len:
        if i > 0:
            buf.append(", ")
        unsafe:
            let p = read(func.params.data + i)
            buf.append(c_declaration(p.ty, p.linkage_name))
        i += 1
    return buf.as_str()


function emit_function(e: ref[Emitter], func: ir.Function) -> void:
    emit_line(e, j2(function_signature(func), " {"))
    var i: ptr_uint = 0
    while i < func.body.len:
        unsafe:
            emit_statement(e, func.body.data + i, 1)
        i += 1
    emit_line(e, "}")


# =============================================================================
#  Statement emission (mirrors c_backend/statements.rb)
# =============================================================================

function emit_statement(e: ref[Emitter], sp: ptr[ir.Stmt], level: ptr_uint) -> void:
    let indent = indent_c(level)
    unsafe:
        match read(sp):
            ir.Stmt.stmt_return as r:
                let value = r.value else:
                    emit_line(e, j2(indent, "return;"))
                    return
                emit_line(e, j4(indent, "return ", emit_expression(value), ";"))
            ir.Stmt.stmt_local as loc:
                emit_line(e, j5(indent, c_declaration(loc.ty, loc.linkage_name), " = ", emit_expression(loc.value), ";"))
            ir.Stmt.stmt_expression as ex:
                emit_line(e, j3(indent, emit_expression(ex.expression), ";"))
            _:
                fatal(c"c_backend Phase 1: unsupported statement")


# =============================================================================
#  Expression emission (mirrors c_backend/expressions.rb)
# =============================================================================

function emit_expression(ep: ptr[ir.Expr]) -> str:
    unsafe:
        match read(ep):
            ir.Expr.expr_name as n:
                return n.name
            ir.Expr.expr_integer_literal as lit:
                return long_to_str(lit.value)
            ir.Expr.expr_boolean_literal as b:
                return if b.value: "true" else: "false"
            ir.Expr.expr_unary as un:
                if un.operator == "not":
                    return j2("!", wrap_expression(un.operand))
                return j2(un.operator, wrap_expression(un.operand))
            ir.Expr.expr_binary as bin:
                return emit_binary(bin.operator, bin.left, bin.right)
            ir.Expr.expr_call as call:
                return emit_call(call.callee, call.arguments)
            _:
                fatal(c"c_backend Phase 1: unsupported expression")


function emit_call(callee: str, arguments: span[ir.Expr]) -> str:
    var buf = string.String.create()
    buf.append(callee)
    buf.append("(")
    var i: ptr_uint = 0
    while i < arguments.len:
        if i > 0:
            buf.append(", ")
        unsafe:
            buf.append(emit_expression(arguments.data + i))
        i += 1
    buf.append(")")
    return buf.as_str()


function emit_binary(operator: str, left: ptr[ir.Expr], right: ptr[ir.Expr]) -> str:
    let parent = binary_precedence(operator)
    let left_text = emit_binary_operand(left, parent, false)
    let right_text = emit_binary_operand(right, parent, true)
    return j5(left_text, " ", c_operator(operator), " ", right_text)


function emit_binary_operand(ep: ptr[ir.Expr], parent_precedence: int, is_right: bool) -> str:
    let text = emit_expression(ep)
    unsafe:
        match read(ep):
            ir.Expr.expr_conditional:
                return j3("(", text, ")")
            ir.Expr.expr_binary as child:
                let child_precedence = binary_precedence(child.operator)
                if child_precedence < parent_precedence or (is_right and child_precedence == parent_precedence):
                    return j3("(", text, ")")
                return text
            _:
                return text


function wrap_expression(ep: ptr[ir.Expr]) -> str:
    let text = emit_expression(ep)
    unsafe:
        match read(ep):
            ir.Expr.expr_name:
                return text
            ir.Expr.expr_integer_literal:
                return text
            ir.Expr.expr_boolean_literal:
                return text
            ir.Expr.expr_call:
                return text
            _:
                return j3("(", text, ")")


function c_operator(operator: str) -> str:
    if operator == "and":
        return "&&"
    if operator == "or":
        return "||"
    return operator


function binary_precedence(operator: str) -> int:
    if operator == "or":
        return 1
    if operator == "and":
        return 2
    if operator == "|":
        return 3
    if operator == "^":
        return 4
    if operator == "&":
        return 5
    if operator == "==" or operator == "!=":
        return 6
    if operator == "<" or operator == "<=" or operator == ">" or operator == ">=":
        return 7
    if operator == "<<" or operator == ">>":
        return 8
    if operator == "+" or operator == "-":
        return 9
    if operator == "*" or operator == "/" or operator == "%":
        return 10
    fatal(c"c_backend Phase 1: unsupported binary operator")
