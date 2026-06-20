# C code emission for the self-hosting compiler.
# Mirrors lib/milk_tea/core/c_backend.rb, c_backend/expressions.rb,
# c_backend/statements.rb.

import std.vec
import mtc.types
import mtc.ir

public struct Emitter:
    ir: ir.IrUnit
    arena: types.TypeArena
    buf: str_buffer[4096]

extending Emitter:
    public static function create(unit: ir.IrUnit, arena: types.TypeArena) -> Emitter:
        var buf: str_buffer[4096]
        return Emitter(ir = unit, arena = arena, buf = buf)

    public editable function emit_c() -> str:
        this.emit_preamble()
        this.emit_forward_decls()
        this.emit_declarations()
        this.emit_function_definitions()
        return this.buf.as_str()

    # ── Output helpers ──

    editable function put_line(line: str) -> void:
        this.buf.append(line)
        this.buf.append("\n")

    editable function put(text: str) -> void:
        this.buf.append(text)

    # ── Preamble ──

    editable function emit_preamble() -> void:
        this.put_line("#include <stdint.h>")
        this.put_line("#include <stdbool.h>")
        this.put_line("#include <stdlib.h>")
        this.put_line("#include <stdio.h>")
        this.put_line("#include <string.h>")
        this.put_line("")
        this.put_line("typedef struct mt_str { const char* data; uintptr_t len; } mt_str;")
        this.put_line("")
        this.emit_helpers()

    editable function emit_helpers() -> void:
        this.put("static void mt_fatal(const char* message) {\n")
        this.put("    fputs(message, stderr);\n")
        this.put("    fputc('\\n', stderr);\n")
        this.put("    abort();\n")
        this.put("}\n")
        this.put_line("")
        this.put_line("static mt_str mt_make_str(const char* s) {")
        this.put("    mt_str result;\n")
        this.put("    result.data = s;\n")
        this.put("    result.len = (uintptr_t)strlen(s);\n")
        this.put("    return result;\n")
        this.put("}\n")
        this.put_line("")

    # ── Forward declarations ──

    editable function emit_forward_decls() -> void:
        var i: ptr_uint = 1
        while i < this.ir.declarations.len:
            let decl = this.ir.declarations.at(i) else:
                break
            match decl:
                ir.IrDecl.struct_decl as sd:
                    if not this.is_builtin(sd.name):
                        this.buf.append_format(
                            f"typedef struct #{sd.linkage_name} #{sd.linkage_name};\n"
                        )
                ir.IrDecl.variant_decl as vd:
                    this.buf.append_format(
                        f"typedef struct #{vd.linkage_name} #{vd.linkage_name};\n"
                    )
                ir.IrDecl.union_decl as ud:
                    this.buf.append_format(
                        f"typedef union #{ud.linkage_name} #{ud.linkage_name};\n"
                    )
                _:
                    pass
            i += 1
        this.put_line("")

    # ── Declarations ──

    editable function emit_declarations() -> void:
        var i: ptr_uint = 1
        while i < this.ir.declarations.len:
            let decl = this.ir.declarations.at(i) else:
                break
            match decl:
                ir.IrDecl.struct_decl as sd:
                    if not this.is_builtin(sd.name):
                        this.emit_struct_decl(sd.name, sd.linkage_name, sd.fields_start, sd.fields_len, sd.packed, sd.alignment)
                ir.IrDecl.variant_decl as vd:
                    this.emit_variant_decl(vd.name, vd.linkage_name, vd.arms_start, vd.arms_len)
                ir.IrDecl.enum_decl as ed:
                    this.emit_enum_decl(ed.name, ed.linkage_name, ed.backing_type, ed.members_start, ed.members_len)
                ir.IrDecl.constant as cd:
                    this.emit_const_decl(cd.name, cd.linkage_name, cd.type_id, cd.value)
                ir.IrDecl.opaque_decl as od:
                    this.emit_opaque_decl(od.name, od.linkage_name)
                ir.IrDecl.union_decl as ud:
                    this.emit_union_decl(ud.name, ud.linkage_name, ud.fields_start, ud.fields_len)
                _:
                    pass
            i += 1

    # ═══════════════════════════════════════════════════════════════════════
    # Struct emission
    # ═══════════════════════════════════════════════════════════════════════

    editable function emit_struct_decl(
        name: str, linkage_name: str, fields_start: ir.NodeId, fields_len: ir.NodeId,
        packed: bool, _alignment: int,
    ) -> void:
        this.buf.append_format(f"struct #{linkage_name}")
        if packed:
            this.buf.append(" __attribute__((packed))")
        this.put_line(" {")
        var j: ptr_uint = 0
        while j < fields_len:
            let f = this.ir.fields.at(fields_start + j) else:
                break
            let ct = this.c_type(f.field_type)
            this.buf.append_format(f"    #{ct} #{f.name};")
            this.put_line("")
            j += 1
        this.buf.append("};")
        this.put_line("")
        this.put_line("")

    # ═══════════════════════════════════════════════════════════════════════
    # Variant emission
    # ═══════════════════════════════════════════════════════════════════════

    editable function emit_variant_decl(
        name: str, ln: str, arms_start: ir.NodeId, arms_len: ir.NodeId,
    ) -> void:
        this.buf.append_format(f"typedef int32_t #{ln}_kind;")
        this.put_line("")
        var j: ptr_uint = 0
        while j < arms_len:
            let arm = this.ir.variant_arms.at(arms_start + j) else:
                break
            this.buf.append_format(f"enum { #{ln}_kind_#{arm.name} = #{j} };")
            this.put_line("")
            j += 1
        this.put_line("")

        var has_data: bool = this.any_arm_has_data(arms_start, arms_len)

        if has_data:
            var m: ptr_uint = 0
            while m < arms_len:
                let arm = this.ir.variant_arms.at(arms_start + m) else:
                    break
                if arm.fields_len > 0z:
                    var payload_name = f"#{ln}_#{arm.name}"
                    this.buf.append_format(
                        f"typedef struct #{payload_name} #{payload_name};\n"
                    )
                m += 1
            m = 0z
            while m < arms_len:
                let arm = this.ir.variant_arms.at(arms_start + m) else:
                    break
                if arm.fields_len > 0z:
                    var payload_name = f"#{ln}_#{arm.name}"
                    this.buf.append_format(f"struct #{payload_name} {{")
                    this.put_line("")
                    var n: ptr_uint = 0
                    while n < arm.fields_len:
                        let af = this.ir.fields.at(arm.fields_start + n) else:
                            break
                        let ct = this.c_type(af.field_type)
                        this.buf.append_format(
                            f"    #{ct} #{af.name};\n"
                        )
                        n += 1
                    this.buf.append("};\n")
                m += 1

            this.buf.append_format(f"union #{ln}__data {{")
            this.put_line("")
            m = 0z
            while m < arms_len:
                let arm = this.ir.variant_arms.at(arms_start + m) else:
                    break
                if arm.fields_len > 0z:
                    this.buf.append_format(
                        f"    struct #{ln}_#{arm.name} #{arm.name};\n"
                    )
                m += 1
            this.buf.append("};\n\n")

        this.buf.append_format(f"struct #{ln} {{")
        this.put_line("")
        this.buf.append_format(f"    #{ln}_kind kind;")
        this.put_line("")
        if has_data:
            this.buf.append_format(f"    union #{ln}__data data;")
            this.put_line("")
        this.buf.append("};")
        this.put_line("")
        this.put_line("")

    function any_arm_has_data(arms_start: ir.NodeId, arms_len: ir.NodeId) -> bool:
        var k: ptr_uint = 0
        while k < arms_len:
            let arm = this.ir.variant_arms.at(arms_start + k) else:
                break
            if arm.fields_len > 0z:
                return true
            k += 1
        return false

    # ═══════════════════════════════════════════════════════════════════════
    # Enum emission
    # ═══════════════════════════════════════════════════════════════════════

    editable function emit_enum_decl(
        name: str, ln: str, _bt: types.TypeId,
        members_start: ir.NodeId, members_len: ir.NodeId,
    ) -> void:
        this.buf.append_format(f"typedef int32_t #{ln};")
        this.put_line("")
        var j: ptr_uint = 0
        while j < members_len:
            let em = this.ir.enum_members.at(members_start + j) else:
                break
            this.buf.append_format(f"enum { #{ln}_#{em.name} = #{em.value} };")
            this.put_line("")
            j += 1
        this.put_line("")

    # ═══════════════════════════════════════════════════════════════════════
    # Other declarations
    # ═══════════════════════════════════════════════════════════════════════

    editable function emit_const_decl(
        name: str, ln: str, type_id: types.TypeId, _value: ir.NodeId,
    ) -> void:
        let ct = this.c_type(type_id)
        this.buf.append_format(f"static const #{ct} #{ln} = 0;")
        this.put_line("")
        this.put_line("")

    editable function emit_opaque_decl(name: str, ln: str) -> void:
        this.buf.append_format(f"typedef struct #{ln} #{ln};")
        this.put_line("")
        this.put_line("")

    editable function emit_union_decl(
        name: str, ln: str, fields_start: ir.NodeId, fields_len: ir.NodeId,
    ) -> void:
        this.buf.append_format(f"union #{ln} {{")
        this.put_line("")
        var j: ptr_uint = 0
        while j < fields_len:
            let f = this.ir.fields.at(fields_start + j) else:
                break
            let ct = this.c_type(f.field_type)
            this.buf.append_format(f"    #{ct} #{f.name};\n")
            j += 1
        this.buf.append("};\n\n")

    # ═══════════════════════════════════════════════════════════════════════
    # Function definitions (with bodies)
    # ═══════════════════════════════════════════════════════════════════════

    editable function emit_function_definitions() -> void:
        var i: ptr_uint = 1
        while i < this.ir.declarations.len:
            let decl = this.ir.declarations.at(i) else:
                break
            match decl:
                ir.IrDecl.function_decl(name, linkage_name, params_start, params_len, return_type, body_start, body_len):
                    if body_len > 0z:
                        this.emit_function_impl(name, linkage_name, params_start, params_len, return_type, body_start, body_len)
                    else:
                        this.emit_function_decl(name, linkage_name, params_start, params_len, return_type)
                _:
                    pass
            i += 1

    editable function emit_function_impl(
        name: str, ln: str, params_start: ir.NodeId, params_len: ir.NodeId,
        return_type: types.TypeId, body_start: ir.NodeId, body_len: ir.NodeId,
    ) -> void:
        let rt = this.c_type(return_type)
        this.buf.append_format(f"#{rt} #{ln}(")
        this.emit_params(params_start, params_len)
        this.buf.append(")")
        this.put_line(" {")
        var k: ir.NodeId = 0z
        while k < body_len:
            let idx = body_start + k
            let stmt = this.ir.statements.at(idx) else:
                break
            this.emit_ir_stmt(stmt)
            k += 1
        this.put_line("}")
        this.put_line("")

    editable function emit_function_decl(
        name: str, ln: str, params_start: ir.NodeId, params_len: ir.NodeId,
        return_type: types.TypeId,
    ) -> void:
        let rt = this.c_type(return_type)
        this.buf.append_format(f"#{rt} #{ln}(")
        this.emit_params(params_start, params_len)
        this.buf.append(");\n\n")

    editable function emit_params(params_start: ir.NodeId, params_len: ir.NodeId) -> void:
        if params_len == 0z:
            this.buf.append("void")
            return
        var j: ptr_uint = 0
        while j < params_len:
            let param = this.ir.params.at(params_start + j) else:
                break
            if j > 0z:
                this.buf.append(", ")
            let pt = this.c_type(param.param_type)
            this.buf.append_format(f"#{pt} #{param.name}")
            j += 1

    # ═══════════════════════════════════════════════════════════════════════
    # Statement emission
    # ═══════════════════════════════════════════════════════════════════════

    editable function emit_ir_stmt(stmt: ir.IrStmt) -> void:
        match stmt:
            ir.IrStmt.local_decl(name, linkage_name, type_id, value):
                let ct = this.c_type(type_id)
                this.buf.append_format(f"    #{ct} #{linkage_name}")
                if value != 0z:
                    this.buf.append(" = ")
                    this.emit_ir_expr(value)
                this.buf.append(";\n")
            ir.IrStmt.assignment(target, operator, value):
                this.buf.append("    ")
                this.emit_ir_expr(target)
                this.buf.append_format(f" #{operator} ")
                this.emit_ir_expr(value)
                this.buf.append(";\n")
            ir.IrStmt.expression_stmt(expr):
                this.buf.append("    ")
                this.emit_ir_expr(expr)
                this.buf.append(";\n")
            ir.IrStmt.return_stmt(value):
                if value != 0z:
                    this.buf.append("    return ")
                    this.emit_ir_expr(value)
                    this.buf.append(";\n")
                else:
                    this.buf.append("    return;\n")
            ir.IrStmt.if_stmt(condition, then_body_start, then_body_len, else_body_start, else_body_len):
                this.buf.append("    if (")
                this.emit_ir_expr(condition)
                this.buf.append(") {\n")
                this.emit_stmt_block(then_body_start, then_body_len)
                if else_body_len > 0z:
                    this.buf.append("    } else {\n")
                    this.emit_stmt_block(else_body_start, else_body_len)
                this.put_line("    }")
            ir.IrStmt.while_stmt(condition, body_start, body_len):
                this.buf.append("    while (")
                this.emit_ir_expr(condition)
                this.buf.append(") {\n")
                this.emit_stmt_block(body_start, body_len)
                this.put_line("    }")
            ir.IrStmt.for_stmt(init, condition, post, body_start, body_len):
                this.buf.append("    for (")
                if init != 0z:
                    this.emit_ir_expr(init)
                this.buf.append("; ")
                if condition != 0z:
                    this.emit_ir_expr(condition)
                this.buf.append("; ")
                if post != 0z:
                    this.emit_ir_expr(post)
                this.buf.append(") {\n")
                this.emit_stmt_block(body_start, body_len)
                this.put_line("    }")
            ir.IrStmt.break_stmt:
                this.put_line("        break;")
            ir.IrStmt.continue_stmt:
                this.put_line("        continue;")
            ir.IrStmt.block(body_start, body_len):
                this.put_line("    {")
                this.emit_stmt_block(body_start, body_len)
                this.put_line("    }")
            ir.IrStmt.goto_stmt(label):
                this.buf.append_format(f"    goto #{label};\n")
            ir.IrStmt.label_stmt(name):
                this.buf.append_format(f"#{name}: ;\n")
            _:
                this.put_line("    ;")

    editable function emit_stmt_block(body_start: ir.NodeId, body_len: ir.NodeId) -> void:
        var j: ir.NodeId = 0z
        while j < body_len:
            let idx = body_start + j
            let s = this.ir.statements.at(idx) else:
                break
            this.emit_ir_stmt(s)
            j += 1

    # ═══════════════════════════════════════════════════════════════════════
    # Expression emission
    # ═══════════════════════════════════════════════════════════════════════

    editable function emit_ir_expr(expr_id: ir.NodeId) -> void:
        if expr_id == 0z:
            this.buf.append("0")
            return
        let expr = this.ir.expressions.at(expr_id) else:
            this.buf.append("0")
            return
        match expr:
            ir.IrExpr.integer_literal(value, _):
                this.buf.append_format(f"#{value}")
            ir.IrExpr.float_literal as fl:
                this.buf.append_format(f"#{fl.value}")
            ir.IrExpr.string_literal as sl:
                if sl.cstring:
                    this.buf.append_format(f"\"#{sl.value}\"")
                else:
                    this.buf.append_format(f"mt_make_str(\"#{sl.value}\")")
            ir.IrExpr.boolean_literal as bl:
                if bl.value:
                    this.buf.append("true")
                else:
                    this.buf.append("false")
            ir.IrExpr.null_literal:
                this.buf.append("NULL")
            ir.IrExpr.zero_init:
                this.buf.append("{0}")
            ir.IrExpr.name as n:
                this.buf.append(n.name)
            ir.IrExpr.member as m:
                this.emit_ir_expr(m.receiver)
                this.buf.append_format(f".#{m.member_name}")
            ir.IrExpr.index as ix:
                this.emit_ir_expr(ix.receiver)
                this.buf.append("[")
                this.emit_ir_expr(ix.index_expr)
                this.buf.append("]")
            ir.IrExpr.checked_index as ci:
                this.emit_ir_expr(ci.receiver)
                this.buf.append("[")
                this.emit_ir_expr(ci.index_expr)
                this.buf.append("]")
            ir.IrExpr.call as cl:
                this.emit_ir_expr(cl.callee)
                this.buf.append("(")
                var j: ir.NodeId = 0z
                while j < cl.args_len:
                    if j > 0z:
                        this.buf.append(", ")
                    let arg_id = cl.args_start + j
                    this.emit_ir_expr(arg_id)
                    j += 1
                this.buf.append(")")
            ir.IrExpr.fn_call as fc:
                this.buf.append(fc.fn_linkage_name)
                this.buf.append("(")
                var k: ir.NodeId = 0z
                while k < fc.args_len:
                    if k > 0z:
                        this.buf.append(", ")
                    let arg_id = fc.args_start + k
                    this.emit_ir_expr(arg_id)
                    k += 1
                this.buf.append(")")
            ir.IrExpr.binary as bin:
                this.buf.append("(")
                this.emit_ir_expr(bin.left)
                this.buf.append_format(f" #{this.c_op(bin.operator)} ")
                this.emit_ir_expr(bin.right)
                this.buf.append(")")
            ir.IrExpr.unary as un:
                this.buf.append_format(f"#{this.c_op(un.operator)}(")
                this.emit_ir_expr(un.operand)
                this.buf.append(")")
            ir.IrExpr.conditional as cond:
                this.buf.append("(")
                this.emit_ir_expr(cond.condition)
                this.buf.append(" ? ")
                this.emit_ir_expr(cond.then_expr)
                this.buf.append(" : ")
                this.emit_ir_expr(cond.else_expr)
                this.buf.append(")")
            ir.IrExpr.cast as ct:
                let target = this.c_type(ct.target_type)
                this.buf.append_format(f"((#{target})(")
                this.emit_ir_expr(ct.expression)
                this.buf.append("))")
            ir.IrExpr.address_of as ao:
                this.buf.append("&(")
                this.emit_ir_expr(ao.expression)
                this.buf.append(")")
            _:
                this.buf.append("0")

    # ═══════════════════════════════════════════════════════════════════════
    # Helpers
    # ═══════════════════════════════════════════════════════════════════════

    function c_op(op: str) -> str:
        if op == "and":
            return "&&"
        else if op == "or":
            return "||"
        else if op == "not":
            return "!"
        return op

    # ── Type → C type mapping ──

    function c_type(type_id: types.TypeId) -> str:
        let t = this.arena.get(type_id)
        match t:
            types.Type.primitive(name):
                return this.c_primitive(name)
            types.Type.struct_type as st:
                return st.name
            types.Type.variant_type as vt:
                return vt.name
            types.Type.enum_type as et:
                return et.name
            types.Type.pointer_type:
                return "void*"
            types.Type.nullable:
                return "void*"
            types.Type.array_type:
                return "void*"
            _:
                return "int32_t"

    function c_primitive(name: str) -> str:
        if name == "bool":
            return "bool"
        else if name == "byte":
            return "int8_t"
        else if name == "ubyte":
            return "uint8_t"
        else if name == "char":
            return "char"
        else if name == "short":
            return "int16_t"
        else if name == "ushort":
            return "uint16_t"
        else if name == "int":
            return "int32_t"
        else if name == "uint":
            return "uint32_t"
        else if name == "long":
            return "int64_t"
        else if name == "ulong":
            return "uint64_t"
        else if name == "ptr_int":
            return "intptr_t"
        else if name == "ptr_uint":
            return "uintptr_t"
        else if name == "float":
            return "float"
        else if name == "double":
            return "double"
        else if name == "void":
            return "void"
        else if name == "cstr":
            return "const char*"
        else if name == "str":
            return "mt_str"
        return name

    function is_builtin(name: str) -> bool:
        return types.is_reserved_type_name(name)
