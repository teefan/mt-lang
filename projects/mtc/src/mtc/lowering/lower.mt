import std.str
import std.vec as vec
import std.stdio

import mtc.ast.nodes


public struct Lowerer:
    module_name: str
    source_text: str
    indent_level: ptr_uint
    out_buf: str_buffer[32768]
    skip_header: bool


extending Lowerer:
    public static function create(module_name: str, source_text: str) -> Lowerer:
        var ob: str_buffer[32768]
        return Lowerer(module_name = module_name, source_text = source_text, indent_level = 0, out_buf = ob, skip_header = false)


    function pline(line: str) -> void:
        stdio.print_line(line)


    function write_ctype(buf: ptr[str_buffer[512]], mt_type: str) -> void:
        if mt_type == "bool":
            unsafe: read(buf).append("bool")
        else if mt_type == "int":
            unsafe: read(buf).append("int32_t")
        else if mt_type == "uint":
            unsafe: read(buf).append("uint32_t")
        else if mt_type == "byte":
            unsafe: read(buf).append("int8_t")
        else if mt_type == "ubyte":
            unsafe: read(buf).append("uint8_t")
        else if mt_type == "short":
            unsafe: read(buf).append("int16_t")
        else if mt_type == "ushort":
            unsafe: read(buf).append("uint16_t")
        else if mt_type == "long":
            unsafe: read(buf).append("int64_t")
        else if mt_type == "ulong":
            unsafe: read(buf).append("uint64_t")
        else if mt_type == "float":
            unsafe: read(buf).append("float")
        else if mt_type == "double":
            unsafe: read(buf).append("double")
        else if mt_type == "char":
            unsafe: read(buf).append("char")
        else if mt_type == "void":
            unsafe: read(buf).append("void")
        else if mt_type == "str":
            unsafe: read(buf).append("mt_str")
        else if mt_type == "cstr":
            unsafe: read(buf).append("const char*")
        else if mt_type == "ptr_int":
            unsafe: read(buf).append("intptr_t")
        else if mt_type == "ptr_uint":
            unsafe: read(buf).append("uintptr_t")
        else if mt_type == "ptr":
            unsafe: read(buf).append("void*")
        else if mt_type == "ref":
            unsafe: read(buf).append("void*")
        else if mt_type == "span":
            unsafe: read(buf).append("void*")
        else if mt_type == "dyn":
            unsafe: read(buf).append("void*")
        else if mt_type == "fn":
            unsafe: read(buf).append("void*")
        else if mt_type == "proc":
            unsafe: read(buf).append("void*")
        else if mt_type == "array":
            unsafe: read(buf).append("void*")
        else if mt_type == "SoA":
            unsafe: read(buf).append("void*")
        else if mt_type == "Task":
            unsafe: read(buf).append("void*")
        else if mt_type == "Option":
            unsafe: read(buf).append("void*")
        else if mt_type == "Result":
            unsafe: read(buf).append("void*")
        else if mt_type == "type":
            unsafe: read(buf).append("void*")
        else if mt_type == "atomic":
            unsafe: read(buf).append("void*")
        else if mt_type == "str_buffer":
            unsafe: read(buf).append("mt_str")
        else if mt_type == "vec2" or mt_type == "vec3" or mt_type == "vec4":
            unsafe: read(buf).append("float")
        else if mt_type == "ivec2" or mt_type == "ivec3" or mt_type == "ivec4":
            unsafe: read(buf).append("int32_t")
        else if mt_type == "mat3" or mt_type == "mat4":
            unsafe: read(buf).append("float")
        else if mt_type == "quat":
            unsafe: read(buf).append("float")
        else if mt_type == "" or mt_type == "?":
            pass
        else:
            var i: ptr_uint = 0
            while i < mt_type.len:
                let ch = mt_type.byte_at(i)
                if ch == '.':
                    unsafe: read(buf).append("_")
                else:
                    unsafe: read(buf).append(mt_type.slice(i, 1))
                i += 1


    function write_ctype_node(buf: ptr[str_buffer[512]], tp: ptr[nodes.Type]?) -> void:
        if tp == null:
            return
        var inner_tp = unsafe: read(tp)
        if inner_tp.kind == nodes.TypeKind.type_nullable:
            this.write_ctype_node(buf, inner_tp.inner)
            return
        var name = inner_tp.name

        if inner_tp.kind == nodes.TypeKind.type_constructed:
            if name == "const_ptr":
                if inner_tp.inner != null:
                    this.write_ctype_node(buf, inner_tp.inner)
                else:
                    unsafe: read(buf).append("void")
                unsafe: read(buf).append("*")
                return
            if name == "ptr" or name == "ref":
                if inner_tp.inner != null:
                    this.write_ctype_node(buf, inner_tp.inner)
                else:
                    unsafe: read(buf).append("void")
                unsafe: read(buf).append("*")
                return
            unsafe: read(buf).append("void*")
            return

        if name == "usize":
            name = "ptr_uint"

        var is_dotted = false
        var di: ptr_uint = 0
        while di < name.len:
            if name.byte_at(di) == '.':
                is_dotted = true
                break
            di += 1

        if not is_dotted and name != "" and not self_is_c_primitive(name):
            if this.module_name != "":
                unsafe: read(buf).append(this.module_name)
                unsafe: read(buf).append("_")
            unsafe: read(buf).append(name)
        else:
            this.write_ctype(buf, name)



    function write_tname(buf: ptr[str_buffer[512]], type_name: str) -> void:
        if type_name == "":
            return
        if this.module_name != "":
            unsafe: read(buf).append(this.module_name)
            unsafe: read(buf).append("_")
        unsafe: read(buf).append(type_name)


    function write_fname(buf: ptr[str_buffer[512]], func_name: str, receiver_type: str) -> void:
        if this.module_name != "":
            unsafe: read(buf).append(this.module_name)
            unsafe: read(buf).append("_")
        if receiver_type != "":
            unsafe: read(buf).append(receiver_type)
            unsafe: read(buf).append("_")
        unsafe: read(buf).append(func_name)


    editable function write_header() -> void:
        this.pline("#include <stdbool.h>")
        this.pline("#include <stdint.h>")
        this.pline("#include <string.h>")
        this.pline("#include <stdio.h>")
        this.pline("")
        this.pline("typedef struct mt_str {")
        this.pline("  char* data;")
        this.pline("  uintptr_t len;")
        this.pline("} mt_str;")
        this.pline("")


    public editable function lower_module(source: nodes.SourceFile) -> void:
        if not this.skip_header:
            this.write_header()

        var i: ptr_uint = 0
        while i < source.decls.len():
            let d = source.decls.get(i) else:
                break
            let decl = unsafe: read(d)
            if not this.self_has_output(decl):
                continue
            this.write_forward_decl(decl)
            i += 1
        this.pline("")

        i = 0
        while i < source.decls.len():
            let d = source.decls.get(i) else:
                break
            let decl = unsafe: read(d)
            if not this.self_has_output(decl):
                continue
            if not this.self_is_function_decl(decl.kind):
                this.write_decl(decl)
            i += 1

        i = 0
        while i < source.decls.len():
            let d = source.decls.get(i) else:
                break
            let decl = unsafe: read(d)
            if not this.self_has_output(decl):
                continue
            if this.self_is_function_decl(decl.kind):
                this.write_decl(decl)
            i += 1


    function self_is_function_decl(kind: nodes.DeclKind) -> bool:
        if kind == nodes.DeclKind.function_def:
            return true
        if kind == nodes.DeclKind.extending_block:
            return true
        if kind == nodes.DeclKind.const_decl or kind == nodes.DeclKind.var_decl:
            return true
        return false


    function self_has_output(decl: nodes.Decl) -> bool:
        if decl.name == "":
            return false
        if decl.kind == nodes.DeclKind.const_decl and decl.stmt_count == 0 and decl.type_node == null and decl.value_text == "":
            return false
        return true


    editable function write_forward_decl(decl: nodes.Decl) -> void:
        if decl.kind == nodes.DeclKind.struct_decl or decl.kind == nodes.DeclKind.union_decl or decl.kind == nodes.DeclKind.opaque_decl:
            var buf: str_buffer[512]
            buf.assign("typedef struct ")
            this.write_tname(ptr_of(buf), decl.name)
            buf.append(" ")
            this.write_tname(ptr_of(buf), decl.name)
            buf.append(";")
            this.pline(buf.as_str())
        else if decl.kind == nodes.DeclKind.enum_decl or decl.kind == nodes.DeclKind.flags_decl:
            var buf: str_buffer[512]
            buf.assign("typedef ")
            this.write_ctype_node(ptr_of(buf), decl.type_node)
            buf.append(" ")
            this.write_tname(ptr_of(buf), decl.name)
            buf.append(";")
            this.pline(buf.as_str())


    editable function write_decl(decl: nodes.Decl) -> void:
        if decl.kind == nodes.DeclKind.struct_decl:
            this.write_struct(decl)
        else if decl.kind == nodes.DeclKind.enum_decl:
            this.write_enum(decl)
        else if decl.kind == nodes.DeclKind.flags_decl:
            this.write_enum(decl)
        else if decl.kind == nodes.DeclKind.union_decl:
            this.write_struct(decl)
        else if decl.kind == nodes.DeclKind.type_alias:
            this.write_type_alias(decl)
        else if decl.kind == nodes.DeclKind.function_def:
            this.write_function(decl)
        else if decl.kind == nodes.DeclKind.extern_function:
            this.write_function_sig(decl)
            this.pline(";")
            this.pline("")
        else if decl.kind == nodes.DeclKind.const_decl and decl.stmt_count > 0:
            this.write_function(decl)
        else if decl.kind == nodes.DeclKind.extending_block:
            this.write_extending(decl)
        else if decl.kind == nodes.DeclKind.var_decl:
            this.write_var(decl)
        else if decl.kind == nodes.DeclKind.const_decl:
            this.write_const(decl)


    editable function write_struct(decl: nodes.Decl) -> void:
        var buf: str_buffer[512]
        if decl.kind == nodes.DeclKind.union_decl:
            buf.assign("typedef union ")
        else:
            buf.assign("typedef struct ")
        this.write_tname(ptr_of(buf), decl.name)
        buf.append(" {")
        this.pline(buf.as_str())
        var i: ptr_uint = 0
        while i < decl.fields.len():
            let f = decl.fields.get(i) else:
                break
            let field = unsafe: read(f)
            buf.assign("  ")
            this.write_ctype_node(ptr_of(buf), field.type_node)
            buf.append(" ")
            buf.append(field.name)
            buf.append(";")
            this.pline(buf.as_str())
            i += 1
        buf.assign("} ")
        this.write_tname(ptr_of(buf), decl.name)
        buf.append(";")
        this.pline(buf.as_str())
        this.pline("")


    editable function write_enum(decl: nodes.Decl) -> void:
        this.pline("enum {")
        var i: ptr_uint = 0
        while i < decl.members.len():
            let m = decl.members.get(i) else:
                break
            let member = unsafe: read(m)
            var buf: str_buffer[512]
            buf.assign("  ")
            this.write_tname(ptr_of(buf), decl.name)
            buf.append("_")
            buf.append(member.name)
            if member.value_text != "":
                buf.append(" = ")
                buf.append(member.value_text)
            buf.append(",")
            this.pline(buf.as_str())
            i += 1
        this.pline("};")
        this.pline("")


    editable function write_type_alias(decl: nodes.Decl) -> void:
        var buf: str_buffer[512]
        buf.assign("typedef ")
        this.write_ctype_node(ptr_of(buf), decl.type_node)
        buf.append(" ")
        this.write_tname(ptr_of(buf), decl.name)
        buf.append(";")
        this.pline(buf.as_str())
        this.pline("")


    editable function write_function(decl: nodes.Decl) -> void:
        var buf: str_buffer[512]
        if decl.kind == nodes.DeclKind.const_decl:
            buf.append("static ")
        this.write_ctype_node(ptr_of(buf), decl.return_node)
        buf.append(" ")
        this.write_fname(ptr_of(buf), decl.name, "")
        buf.append("(")
        var i: ptr_uint = 0
        while i < decl.params.len():
            let p = decl.params.get(i) else:
                break
            let param = unsafe: read(p)
            if i > 0:
                buf.append(", ")
            this.write_ctype_node(ptr_of(buf), param.type_node)
            buf.append(" ")
            buf.append(param.name)
            i += 1
        buf.append(") {")
        this.pline(buf.as_str())

        if decl.body_block != null:
            this.indent_level = 4
            unsafe: this.out_buf.clear()
            this.self_lower_block(decl.body_block)
            this.pline(unsafe: this.out_buf.as_str())
        else if decl.body_src_start > 0:
            var end_pos = decl.body_src_end
            if end_pos == 0 or end_pos <= decl.body_src_start:
                end_pos = this.source_text.len
            var body_raw = this.source_text.slice(decl.body_src_start, end_pos - decl.body_src_start)
            this.self_write_raw_body(body_raw)
        else:
            this.pline("    /* body not lowered */")
        this.pline("}")
        this.pline("")


    editable function self_lower_block(block: ptr[nodes.Block]?) -> void:
        if block == null:
            return
        var i: ptr_uint = 0
        while i < unsafe: read(block).stmts.len():
            let s = unsafe: read(block).stmts.get(i) else:
                break
            this.self_lower_stmt(s)
            i += 1


    editable function self_lower_stmt(stmt_ptr: ptr[nodes.Stmt]) -> void:
        let s = unsafe: read(stmt_ptr)
        var kind = s.kind

        if kind == nodes.StmtKind.if_stmt or kind == nodes.StmtKind.match_stmt:
            this.self_write_ctrl_if(stmt_ptr)
        else if kind == nodes.StmtKind.while_stmt:
            this.self_write_ctrl_while(stmt_ptr)
        else if kind == nodes.StmtKind.for_stmt:
            this.self_write_indent()
            unsafe: this.out_buf.append("/* for */\n")
        else if kind == nodes.StmtKind.return_stmt:
            this.self_write_return(stmt_ptr)
        else if kind == nodes.StmtKind.local_let:
            this.self_write_let(stmt_ptr)
        else if kind == nodes.StmtKind.local_var:
            this.self_write_var(stmt_ptr)
        else if kind == nodes.StmtKind.expression_stmt:
            this.self_write_expr_stmt(stmt_ptr)
        else if kind == nodes.StmtKind.break_stmt:
            this.self_write_indent()
            unsafe: this.out_buf.append("break;\n")
        else if kind == nodes.StmtKind.continue_stmt:
            this.self_write_indent()
            unsafe: this.out_buf.append("continue;\n")
        else if kind == nodes.StmtKind.pass_stmt:
            this.self_write_indent()
            unsafe: this.out_buf.append(";\n")
        else if kind == nodes.StmtKind.defer_stmt or kind == nodes.StmtKind.unsafe_stmt:
            if s.body != null:
                this.self_lower_block(s.body)
            else:
                this.self_write_indent()
                unsafe: this.out_buf.append("/* defer/unsafe */\n")
        else:
            this.self_write_indent()
            unsafe: this.out_buf.append("/* block */\n")


    editable function self_write_ctrl_if(stmt_ptr: ptr[nodes.Stmt]) -> void:
        let s = unsafe: read(stmt_ptr)
        this.self_write_indent()
        if s.kind == nodes.StmtKind.match_stmt:
            unsafe: this.out_buf.append("switch (")
        else:
            unsafe: this.out_buf.append("if (")
        this.self_write_expr_buf(s.expr)
        unsafe: this.out_buf.append(") {\n")
        this.indent_level += 4
        if s.body != null:
            this.self_lower_block(s.body)
        this.indent_level -= 4
        this.self_write_indent()
        if s.else_body != null:
            unsafe: this.out_buf.append("} else {\n")
            this.indent_level += 4
            this.self_lower_block(s.else_body)
            this.indent_level -= 4
            this.self_write_indent()
        unsafe: this.out_buf.append("}\n")


    editable function self_write_ctrl_while(stmt_ptr: ptr[nodes.Stmt]) -> void:
        let s = unsafe: read(stmt_ptr)
        this.self_write_indent()
        unsafe: this.out_buf.append("while (")
        this.self_write_expr_buf(s.expr)
        unsafe: this.out_buf.append(") {\n")
        this.indent_level += 4
        if s.body != null:
            this.self_lower_block(s.body)
        this.indent_level -= 4
        this.self_write_indent()
        unsafe: this.out_buf.append("}\n")


    editable function self_write_let(stmt_ptr: ptr[nodes.Stmt]) -> void:
        let s = unsafe: read(stmt_ptr)
        this.self_write_indent()
        var tp = s.type_node
        if tp != null:
            var tbuf: str_buffer[512]
            this.write_ctype_node(ptr_of(tbuf), tp)
            unsafe: this.out_buf.append(unsafe: tbuf.as_str())
            unsafe: this.out_buf.append(" ")
        else if s.expr != null:
            var itype = this.self_infer_expr_type(s.expr)
            if itype != "":
                unsafe: this.out_buf.append(itype)
                unsafe: this.out_buf.append(" ")
            else:
                unsafe: this.out_buf.append("auto ")
        else:
            unsafe: this.out_buf.append("auto ")
        unsafe: this.out_buf.append(s.name)
        if s.expr != null:
            unsafe: this.out_buf.append(" = ")
            this.self_write_expr_buf(s.expr)
        unsafe: this.out_buf.append(";\n")


    function self_infer_expr_type(expr_ptr: ptr[nodes.Expr]?) -> str:
        if expr_ptr == null:
            return ""
        let e = unsafe: read(expr_ptr)
        if e.kind == nodes.ExprKind.integer_literal:
            return "uintptr_t"
        if e.kind == nodes.ExprKind.float_literal:
            return "double"
        if e.kind == nodes.ExprKind.boolean_literal:
            return "bool"
        if e.kind == nodes.ExprKind.char_literal:
            return "char"
        return ""


    editable function self_write_var(stmt_ptr: ptr[nodes.Stmt]) -> void:
        let s = unsafe: read(stmt_ptr)
        this.self_write_indent()
        var tp = s.type_node
        if tp != null:
            var tbuf: str_buffer[512]
            this.write_ctype_node(ptr_of(tbuf), tp)
            unsafe: this.out_buf.append(unsafe: tbuf.as_str())
            unsafe: this.out_buf.append(" ")
        else:
            unsafe: this.out_buf.append("auto ")
        unsafe: this.out_buf.append(s.name)
        if s.expr != null:
            unsafe: this.out_buf.append(" = ")
            this.self_write_expr_buf(s.expr)
        unsafe: this.out_buf.append(";\n")


    editable function self_write_return(stmt_ptr: ptr[nodes.Stmt]) -> void:
        let s = unsafe: read(stmt_ptr)
        this.self_write_indent()
        unsafe: this.out_buf.append("return")
        if s.expr != null:
            unsafe: this.out_buf.append(" ")
            this.self_write_expr_buf(s.expr)
        unsafe: this.out_buf.append(";\n")


    editable function self_write_expr_stmt(stmt_ptr: ptr[nodes.Stmt]) -> void:
        let s = unsafe: read(stmt_ptr)
        this.self_write_indent()
        if s.expr != null:
            this.self_write_expr_buf(s.expr)
        if s.value != null:
            unsafe: this.out_buf.append(" ")
            unsafe: this.out_buf.append(s.name)
            unsafe: this.out_buf.append(" ")
            this.self_write_expr_buf(s.value)
        unsafe: this.out_buf.append(";\n")


    editable function self_write_expr_buf(expr_ptr: ptr[nodes.Expr]?) -> void:
        if expr_ptr == null:
            return
        let e = unsafe: read(expr_ptr)
        var kind = e.kind

        if kind == nodes.ExprKind.identifier:
            unsafe: this.out_buf.append(e.name)
        else if kind == nodes.ExprKind.integer_literal or kind == nodes.ExprKind.float_literal:
            unsafe: this.out_buf.append(e.lexeme)
        else if kind == nodes.ExprKind.string_literal:
            unsafe: this.out_buf.append(e.lexeme)
        else if kind == nodes.ExprKind.char_literal:
            unsafe: this.out_buf.append(e.lexeme)
        else if kind == nodes.ExprKind.boolean_literal:
            unsafe: this.out_buf.append(e.name)
        else if kind == nodes.ExprKind.null_literal:
            unsafe: this.out_buf.append("NULL")
        else if kind == nodes.ExprKind.binary_op:
            unsafe: this.out_buf.append("(")
            this.self_write_expr_buf(e.left)
            var op = e.name
            if op == "or":
                op = "||"
            else if op == "and":
                op = "&&"
            unsafe: this.out_buf.append(" ")
            unsafe: this.out_buf.append(op)
            unsafe: this.out_buf.append(" ")
            this.self_write_expr_buf(e.right)
            unsafe: this.out_buf.append(")")
        else if kind == nodes.ExprKind.unary_op:
            var op = e.name
            if op == "not":
                op = "!"
            unsafe: this.out_buf.append(op)
            this.self_write_expr_buf(e.left)
        else if kind == nodes.ExprKind.call:
            if this.self_is_method_call(expr_ptr):
                this.self_write_method_call(expr_ptr)
            else if this.self_is_struct_ctor(expr_ptr):
                this.self_write_struct_call(expr_ptr)
            else:
                this.self_write_func_call(expr_ptr)
        else if kind == nodes.ExprKind.member_access:
            this.self_write_expr_buf(e.left)
            if this.self_is_this_expr(e.left):
                unsafe: this.out_buf.append("->")
            else if this.self_has_this_root(e.left):
                unsafe: this.out_buf.append(".")
            else if this.self_is_member_access(e.left):
                unsafe: this.out_buf.append("_")
            else:
                var first = unsafe: e.name.byte_at(0)
                if first >= 'A' and first <= 'Z':
                    unsafe: this.out_buf.append("_")
                else:
                    unsafe: this.out_buf.append(".")
            unsafe: this.out_buf.append(e.name)
        else if kind == nodes.ExprKind.index_access:
            this.self_write_expr_buf(e.left)
            unsafe: this.out_buf.append("[")
            this.self_write_expr_buf(e.right)
            unsafe: this.out_buf.append("]")
        else if kind == nodes.ExprKind.await_expr:
            this.self_write_expr_buf(e.left)
        else if kind == nodes.ExprKind.prefix_cast:
            unsafe: this.out_buf.append("(")
            unsafe: this.out_buf.append(e.name)
            unsafe: this.out_buf.append(")")
        else:
            unsafe: this.out_buf.append(e.name)


    editable function self_is_struct_ctor(expr_ptr: ptr[nodes.Expr]) -> bool:
        let e = unsafe: read(expr_ptr)
        var len = unsafe: e.args.len()
        # Struct ctors have named args: (name, value, name, value, ...) → even count
        if len < 2:
            return false
        if (len & 1) != 0:
            return false
        var ai: ptr_uint = 0
        while ai < len:
            let a = unsafe: e.args.get(ai) else:
                break
            let ap: ptr[nodes.Expr]? = unsafe: read(a)
            if ap == null:
                return false
            let ae = unsafe: read(ap)
            if ae.kind != nodes.ExprKind.identifier:
                return false
            ai += 2
        return true


    editable function self_is_member_access(expr_ptr: ptr[nodes.Expr]?) -> bool:
        if expr_ptr == null:
            return false
        return unsafe: read(expr_ptr).kind == nodes.ExprKind.member_access


    editable function self_is_this_expr(expr_ptr: ptr[nodes.Expr]?) -> bool:
        if expr_ptr == null:
            return false
        return unsafe: read(expr_ptr).name == "this"


    editable function self_has_this_root(expr_ptr: ptr[nodes.Expr]?) -> bool:
        var cur: ptr[nodes.Expr]? = expr_ptr
        var root: ptr[nodes.Expr]? = null
        while cur != null:
            let ce = unsafe: read(cur)
            if ce.kind == nodes.ExprKind.member_access:
                cur = ce.left
            else:
                root = cur
                break
        if root == null:
            return false
        return unsafe: read(root).name == "this"


    editable function self_is_method_call(expr_ptr: ptr[nodes.Expr]) -> bool:
        let e = unsafe: read(expr_ptr)
        return this.self_is_member_access(e.left)


    editable function self_is_this_method(expr_ptr: ptr[nodes.Expr]) -> bool:
        if not this.self_is_method_call(expr_ptr):
            return false
        let e = unsafe: read(expr_ptr)
        var cur: ptr[nodes.Expr]? = e.left
        while cur != null:
            let ce = unsafe: read(cur)
            if ce.kind == nodes.ExprKind.member_access:
                cur = ce.left
            else:
                break
        if cur == null:
            return false
        return unsafe: read(cur).name == "this"


    editable function self_write_struct_call(expr_ptr: ptr[nodes.Expr]) -> void:
        let e = unsafe: read(expr_ptr)
        unsafe: this.out_buf.append("(")
        this.self_write_tname_expr(e.left)
        unsafe: this.out_buf.append("){ ")
        var ai: ptr_uint = 0
        while ai < unsafe: e.args.len():
            let aname = unsafe: e.args.get(ai) else:
                break
            let aval_ptr = unsafe: e.args.get(ai + 1) else:
                break
            let ap: ptr[nodes.Expr]? = unsafe: read(aname)
            if ap == null:
                break
            let an = unsafe: read(ap)
            if ai > 0:
                unsafe: this.out_buf.append(", ")
            unsafe: this.out_buf.append(".")
            unsafe: this.out_buf.append(an.name)
            unsafe: this.out_buf.append(" = ")
            let vp: ptr[nodes.Expr]? = unsafe: read(aval_ptr)
            if vp != null:
                this.self_write_expr_buf(vp)
            ai += 2
        unsafe: this.out_buf.append(" }")


    editable function self_write_tname_expr(expr_ptr: ptr[nodes.Expr]?) -> void:
        if expr_ptr == null:
            return
        let e = unsafe: read(expr_ptr)
        if e.kind == nodes.ExprKind.identifier:
            if not self_is_c_primitive(e.name) and this.module_name != "":
                unsafe: this.out_buf.append(this.module_name)
                unsafe: this.out_buf.append("_")
            unsafe: this.out_buf.append(e.name)
        else if e.kind == nodes.ExprKind.member_access:
            this.self_write_tname_expr(e.left)
            unsafe: this.out_buf.append("_")
            unsafe: this.out_buf.append(e.name)
        else:
            this.self_write_expr_buf(expr_ptr)


    editable function self_write_callee_expr(expr_ptr: ptr[nodes.Expr]?) -> void:
        if expr_ptr == null:
            return
        let e = unsafe: read(expr_ptr)
        if e.kind == nodes.ExprKind.identifier:
            unsafe: this.out_buf.append(e.name)
        else if e.kind == nodes.ExprKind.member_access:
            this.self_write_callee_expr(e.left)
            unsafe: this.out_buf.append("_")
            unsafe: this.out_buf.append(e.name)
        else:
            this.self_write_expr_buf(expr_ptr)


    editable function self_write_receiver(callee: ptr[nodes.Expr]?) -> void:
        if callee == null:
            return
        var cur: ptr[nodes.Expr]? = callee
        while cur != null:
            let ce = unsafe: read(cur)
            if ce.kind == nodes.ExprKind.member_access:
                cur = ce.left
            else:
                break
        if cur != null:
            unsafe: this.out_buf.append("&")
            this.self_write_expr_buf(cur)


    editable function self_write_method_call(expr_ptr: ptr[nodes.Expr]) -> void:
        let e = unsafe: read(expr_ptr)
        this.self_write_callee_expr(e.left)
        unsafe: this.out_buf.append("(")
        if this.self_is_this_method(expr_ptr):
            unsafe: this.out_buf.append("this")
            if unsafe: e.args.len() > 0:
                unsafe: this.out_buf.append(", ")
        var ai: ptr_uint = 0
        while ai < unsafe: e.args.len():
            let a = unsafe: e.args.get(ai) else:
                break
            let ap: ptr[nodes.Expr]? = unsafe: read(a)
            if ai > 0:
                unsafe: this.out_buf.append(", ")
            if ap != null:
                this.self_write_expr_buf(ap)
            ai += 1
        unsafe: this.out_buf.append(")")


    editable function self_write_func_call(expr_ptr: ptr[nodes.Expr]) -> void:
        let e = unsafe: read(expr_ptr)
        this.self_write_expr_buf(e.left)
        unsafe: this.out_buf.append("(")
        var ai: ptr_uint = 0
        while ai < unsafe: e.args.len():
            let a = unsafe: e.args.get(ai) else:
                break
            let ap: ptr[nodes.Expr]? = unsafe: read(a)
            if ai > 0:
                unsafe: this.out_buf.append(", ")
            if ap != null:
                this.self_write_expr_buf(ap)
            ai += 1
        unsafe: this.out_buf.append(")")


    editable function self_write_indent() -> void:
        var i: ptr_uint = 0
        while i < this.indent_level:
            unsafe: this.out_buf.append(" ")
            i += 1


    editable function self_write_raw_body(raw: str) -> void:
        var pos: ptr_uint = 0
        var line_start: ptr_uint = 0
        this.indent_level = 4
        while pos < raw.len:
            let ch = raw.byte_at(pos)
            if ch == '\n':
                var line = raw.slice(line_start, pos - line_start)
                this.self_write_indent()
                unsafe: this.out_buf.append(line)
                unsafe: this.out_buf.append("\n")
                line_start = pos + 1
            pos += 1
        if line_start < raw.len:
            var line = raw.slice(line_start, raw.len - line_start)
            this.self_write_indent()
            unsafe: this.out_buf.append(line)
            unsafe: this.out_buf.append("\n")


    editable function write_function_sig(decl: nodes.Decl) -> void:
        var buf: str_buffer[512]
        this.write_ctype_node(ptr_of(buf), decl.return_node)
        buf.append(" ")
        this.write_fname(ptr_of(buf), decl.name, "")
        buf.append("(")
        var i: ptr_uint = 0
        while i < decl.params.len():
            let p = decl.params.get(i) else:
                break
            let param = unsafe: read(p)
            if i > 0:
                buf.append(", ")
            this.write_ctype_node(ptr_of(buf), param.type_node)
            buf.append(" ")
            buf.append(param.name)
            i += 1
        buf.append(")")
        this.pline(buf.as_str())


    editable function write_const(decl: nodes.Decl) -> void:
        var buf: str_buffer[512]
        if decl.value_text != "":
            buf.assign("static const ")
        else:
            buf.assign("static ")
        this.write_ctype_node(ptr_of(buf), decl.type_node)
        buf.append(" ")
        this.write_fname(ptr_of(buf), decl.name, "")
        if decl.value_text != "":
            buf.append(" = ")
            buf.append(decl.value_text)
        buf.append(";")
        this.pline(buf.as_str())


    editable function write_var(decl: nodes.Decl) -> void:
        var buf: str_buffer[512]
        buf.assign("static ")
        this.write_ctype_node(ptr_of(buf), decl.type_node)
        buf.append(" ")
        this.write_fname(ptr_of(buf), decl.name, "")
        if decl.value_text != "":
            buf.append(" = ")
            buf.append(decl.value_text)
        buf.append(";")
        this.pline(buf.as_str())


    editable function write_extending(decl: nodes.Decl) -> void:
        var i: ptr_uint = 0
        while i < decl.methods.len():
            let m = decl.methods.get(i) else:
                break
            let method = unsafe: read(m)
            var buf: str_buffer[512]
            buf.assign("static ")
            this.write_ctype_node(ptr_of(buf), method.return_node)
            buf.append(" ")
            this.write_fname(ptr_of(buf), method.name, decl.name)
            buf.append("(")
            this.write_tname(ptr_of(buf), decl.name)
            buf.append(" *this")
            var ji: ptr_uint = 0
            while ji < method.params.len():
                let p = method.params.get(ji) else:
                    break
                buf.append(", ")
                let param = unsafe: read(p)
                this.write_ctype_node(ptr_of(buf), param.type_node)
                buf.append(" ")
                buf.append(param.name)
                ji += 1
            buf.append(") {")
            this.pline(buf.as_str())

            if method.body_block != null:
                this.indent_level = 4
                unsafe: this.out_buf.clear()
                this.self_lower_block(method.body_block)
                this.pline(unsafe: this.out_buf.as_str())
            else if method.body_src_start > 0:
                var end_pos = method.body_src_end
                if end_pos == 0 or end_pos <= method.body_src_start:
                    end_pos = this.source_text.len
                var body_raw = this.source_text.slice(method.body_src_start, end_pos - method.body_src_start)
                this.self_write_raw_body(body_raw)

            this.pline("}")
            this.pline("")
            i += 1

function self_is_c_primitive(name: str) -> bool:
    if name == "bool" or name == "int" or name == "uint" or name == "byte" or name == "ubyte":
        return true
    if name == "short" or name == "ushort" or name == "long" or name == "ulong":
        return true
    if name == "float" or name == "double" or name == "char" or name == "void":
        return true
    if name == "str" or name == "cstr" or name == "ptr_int" or name == "ptr_uint":
        return true
    if name == "ptr" or name == "ref" or name == "span" or name == "dyn":
        return true
    if name == "fn" or name == "proc" or name == "array" or name == "SoA":
        return true
    if name == "Task" or name == "Option" or name == "Result" or name == "type":
        return true
    if name == "atomic" or name == "str_buffer":
        return true
    if name == "vec2" or name == "vec3" or name == "vec4":
        return true
    if name == "ivec2" or name == "ivec3" or name == "ivec4":
        return true
    if name == "mat3" or name == "mat4" or name == "quat":
        return true
    if name == "" or name == "?" or name == "const_ptr" or name == "usize":
        return true
    return false
