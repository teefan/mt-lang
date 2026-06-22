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
    current_receiver_type: str
    current_return_type: str
    type_pool: str_buffer[4096]
    local_names: vec.Vec[str]
    local_types: vec.Vec[str]
    scope_stack: vec.Vec[ptr_uint]
    func_lookup_names: vec.Vec[str]
    func_lookup_rets: vec.Vec[str]
    method_lookup_receivers: vec.Vec[str]
    method_lookup_names: vec.Vec[str]
    method_lookup_rets: vec.Vec[str]
    field_struct_names: vec.Vec[str]
    field_names: vec.Vec[str]
    field_types: vec.Vec[str]


extending Lowerer:
    public static function create(module_name: str, source_text: str) -> Lowerer:
        var ob: str_buffer[32768]
        return Lowerer(module_name = module_name, source_text = source_text, indent_level = 0, out_buf = ob, skip_header = false, current_receiver_type = "")


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
            if name == "Vec" or self_str_ends_with(name, ".Vec"):
                unsafe: read(buf).append("mt_vec")
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
        this.pline("#include <stdlib.h>")
        this.pline("")
        this.pline("typedef struct mt_str {")
        this.pline("  char* data;")
        this.pline("  uintptr_t len;")
        this.pline("} mt_str;")
        this.pline("#define MT_STR(s) ((mt_str){(char*)(s), sizeof(s)-1})")
        this.pline("static int mt_str_eq(mt_str a, mt_str b) {")
        this.pline("  return a.len == b.len && (a.data == b.data || memcmp(a.data, b.data, a.len) == 0);")
        this.pline("}")
        this.pline("")
        this.pline("typedef struct mt_vec {")
        this.pline("  void* data;")
        this.pline("  uintptr_t len;")
        this.pline("  uintptr_t capacity;")
        this.pline("} mt_vec;")
        this.pline("")
        this.pline("static void mt_vec_push_impl(mt_vec *v, const void *item, uintptr_t item_size) {")
        this.pline("  if (v->len >= v->capacity) {")
        this.pline("    v->capacity = v->capacity ? v->capacity * 2 : 8;")
        this.pline("    v->data = realloc(v->data, v->capacity * item_size);")
        this.pline("  }")
        this.pline("  memcpy((char*)v->data + v->len * item_size, item, item_size);")
        this.pline("  v->len++;")
        this.pline("}")
        this.pline("")
        this.pline("static void* mt_vec_get_impl(mt_vec *v, uintptr_t index, uintptr_t item_size) {")
        this.pline("  if (index >= v->len) return NULL;")
        this.pline("  return (char*)v->data + index * item_size;")
        this.pline("}")
        this.pline("")


    public editable function lower_module(source: nodes.SourceFile) -> void:
        if not this.skip_header:
            this.write_header()

        this.build_type_maps(source)

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
        else if decl.kind == nodes.DeclKind.function_def:
            this.write_function_sig(decl)
            this.pline(";")
        else if decl.kind == nodes.DeclKind.extending_block:
            var mi: ptr_uint = 0
            while mi < decl.methods.len():
                let m = decl.methods.get(mi) else:
                    break
                let method = unsafe: read(m)
                var mbuf: str_buffer[512]
                mbuf.assign("static ")
                this.write_ctype_node(ptr_of(mbuf), method.return_node)
                mbuf.append(" ")
                this.write_fname(ptr_of(mbuf), method.name, decl.name)
                mbuf.append("(")
                this.write_tname(ptr_of(mbuf), decl.name)
                mbuf.append(" *this")
                var ji: ptr_uint = 0
                while ji < method.params.len():
                    let p = method.params.get(ji) else:
                        break
                    mbuf.append(", ")
                    let param = unsafe: read(p)
                    this.write_ctype_node(ptr_of(mbuf), param.type_node)
                    mbuf.append(" ")
                    mbuf.append(param.name)
                    ji += 1
                mbuf.append(");")
                this.pline(mbuf.as_str())
                mi += 1
        else if decl.kind == nodes.DeclKind.const_decl and decl.stmt_count > 0:
            var buf: str_buffer[512]
            buf.assign("static ")
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
            buf.append(");")
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

        this.scope_enter()
        var ret_buf: str_buffer[512]
        this.write_ctype_node(ptr_of(ret_buf), decl.return_node)
        this.current_return_type = this.pool_type(unsafe: ret_buf.as_str())
        i = 0
        while i < decl.params.len():
            let p = decl.params.get(i) else:
                break
            let param = unsafe: read(p)
            var pt: str_buffer[512]
            this.write_ctype_node(ptr_of(pt), param.type_node)
            this.scope_bind(param.name, this.pool_type(unsafe: pt.as_str()))
            i += 1

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

        this.scope_leave()
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
        var resolved_type: str_buffer[512]
        if tp != null:
            this.write_ctype_node(ptr_of(resolved_type), tp)
            unsafe: this.out_buf.append(unsafe: resolved_type.as_str())
            unsafe: this.out_buf.append(" ")
        else if s.expr != null:
            var itype = this.self_infer_expr_type(s.expr)
            if itype != "":
                unsafe: this.out_buf.append(itype)
                unsafe: this.out_buf.append(" ")
                resolved_type.assign(itype)
            else:
                unsafe: this.out_buf.append("auto ")
        else:
            unsafe: this.out_buf.append("auto ")
        unsafe: this.out_buf.append(s.name)
        if s.expr != null:
            unsafe: this.out_buf.append(" = ")
            this.self_write_expr_buf(s.expr)
        unsafe: this.out_buf.append(";\n")
        # Record type for scope
        var rt = unsafe: resolved_type.as_str()
        if rt != "" and rt != "auto":
            this.scope_bind(s.name, this.pool_type(rt))


    function self_infer_receiver_type(expr_ptr: ptr[nodes.Expr]?) -> str:
        if expr_ptr == null:
            return ""
        let e = unsafe: read(expr_ptr)
        if e.kind == nodes.ExprKind.identifier:
            return this.scope_lookup(e.name)
        if e.kind == nodes.ExprKind.member_access:
            # For chained member access like a.b.c, resolve c's field type from b's struct
            var inner_type = this.self_infer_receiver_type(e.left)
            if inner_type != "":
                var struct_name = inner_type
                if self_str_ends_with(struct_name, "*"):
                    struct_name = struct_name.slice(0, struct_name.len - 1)
                return this.struct_field_lookup(struct_name, e.name)
            return ""
        return ""


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
        if e.kind == nodes.ExprKind.string_literal:
            if e.lexeme != "" and e.lexeme.byte_at(0) != 'c':
                return "mt_str"
            return ""
        if e.kind == nodes.ExprKind.null_literal:
            return "void*"
        if e.kind == nodes.ExprKind.await_expr:
            return this.self_infer_expr_type(e.left)
        if e.kind == nodes.ExprKind.identifier:
            var st = this.scope_lookup(e.name)
            if st != "":
                return st
            return ""
        if e.kind == nodes.ExprKind.member_access:
            var recv_type = this.self_infer_receiver_type(e.left)
            if recv_type != "":
                var struct_name = recv_type
                if self_str_ends_with(struct_name, "*"):
                    struct_name = struct_name.slice(0, struct_name.len - 1)
                var ft = this.struct_field_lookup(struct_name, e.name)
                if ft != "":
                    return ft
            # Fallback heuristic: common string field names
            if self_is_string_field_name(e.name):
                return "mt_str"
            return ""
        if e.kind == nodes.ExprKind.call:
            var callee_ptr = e.left
            if callee_ptr != null:
                let callee = unsafe: read(callee_ptr)
                if callee.kind == nodes.ExprKind.identifier:
                    if callee.name == "read":
                        # read(x) returns pointee type of x
                        var arg_types = this.self_infer_read_pointee_type(e)
                        if arg_types != "":
                            return arg_types
                    var rt = this.func_lookup_ret(callee.name)
                    if rt != "" and rt != "void":
                        return rt
                else if callee.kind == nodes.ExprKind.member_access and this.current_receiver_type != "":
                    var recv_ptr = callee.left
                    if recv_ptr != null:
                        let receiver_expr = unsafe: read(recv_ptr)
                        if receiver_expr.kind == nodes.ExprKind.identifier and receiver_expr.name == "this":
                            var mi: ptr_uint = 0
                            while mi < this.method_lookup_receivers.len():
                                let rcp = this.method_lookup_receivers.get(mi) else:
                                    break
                                let rc = unsafe: read(rcp)
                                if rc == this.current_receiver_type:
                                    let mnp = this.method_lookup_names.get(mi) else:
                                        break
                                    let mn = unsafe: read(mnp)
                                    if mn == callee.name:
                                        let rtp = this.method_lookup_rets.get(mi) else:
                                            break
                                        let rt = unsafe: read(rtp)
                                        if rt != "" and rt != "void":
                                            return rt
                                        break
                                mi += 1
                    # Check Vec.get() regardless of this-method match
                    if callee.name == "get" and self_is_str_vec_field(callee.left):
                        return "mt_str*"
                else if callee.kind == nodes.ExprKind.member_access and callee.name == "get" and self_is_str_vec_field(callee.left):
                    return "mt_str*"
            return ""
        return ""


    editable function self_write_var(stmt_ptr: ptr[nodes.Stmt]) -> void:
        let s = unsafe: read(stmt_ptr)
        this.self_write_indent()
        var tp = s.type_node
        var resolved_type: str_buffer[512]
        if tp != null:
            this.write_ctype_node(ptr_of(resolved_type), tp)
            unsafe: this.out_buf.append(unsafe: resolved_type.as_str())
            unsafe: this.out_buf.append(" ")
        else:
            unsafe: this.out_buf.append("auto ")
        unsafe: this.out_buf.append(s.name)
        if s.expr != null:
            unsafe: this.out_buf.append(" = ")
            this.self_write_expr_buf(s.expr)
        unsafe: this.out_buf.append(";\n")
        var rt = unsafe: resolved_type.as_str()
        if rt != "" and rt != "auto":
            this.scope_bind(s.name, this.pool_type(rt))


    editable function self_write_return(stmt_ptr: ptr[nodes.Stmt]) -> void:
        let s = unsafe: read(stmt_ptr)
        this.self_write_indent()
        unsafe: this.out_buf.append("return")
        if s.expr != null:
            unsafe: this.out_buf.append(" ")
            this.self_write_expr_buf(s.expr)
        unsafe: this.out_buf.append(";\n")


    function self_expr_is_mt_str(expr_ptr: ptr[nodes.Expr]) -> str:
        let ep = unsafe: read(expr_ptr)
        if ep.kind == nodes.ExprKind.identifier:
            var st = this.scope_lookup(ep.name)
            if st == "mt_str":
                return "mt_str"
        else if ep.kind == nodes.ExprKind.string_literal:
            if ep.lexeme != "" and ep.lexeme.byte_at(0) != 'c':
                return "mt_str"
        else if ep.kind == nodes.ExprKind.call:
            var callee_ptr = ep.left
            if callee_ptr != null:
                let callee = unsafe: read(callee_ptr)
                if callee.kind == nodes.ExprKind.identifier:
                    var rt = this.func_lookup_ret(callee.name)
                    if rt == "mt_str":
                        return "mt_str"
                else if callee.kind == nodes.ExprKind.member_access and this.current_receiver_type != "":
                    var rp = callee.left
                    if rp != null:
                        let rx = unsafe: read(rp)
                        if rx.kind == nodes.ExprKind.identifier and rx.name == "this":
                            var mi: ptr_uint = 0
                            while mi < this.method_lookup_receivers.len():
                                let rcp = this.method_lookup_receivers.get(mi) else:
                                    break
                                let rc = unsafe: read(rcp)
                                if rc == this.current_receiver_type:
                                    let mnp = this.method_lookup_names.get(mi) else:
                                        break
                                    if unsafe: read(mnp) == callee.name:
                                        let rtp = this.method_lookup_rets.get(mi) else:
                                            break
                                        let rt = unsafe: read(rtp)
                                        if rt == "mt_str":
                                            return "mt_str"
                                        break
                                mi += 1
        else if ep.kind == nodes.ExprKind.member_access:
            var rtype = this.self_infer_receiver_type(ep.left)
            if rtype != "":
                var sname = rtype
                if self_str_ends_with(sname, "*"):
                    sname = sname.slice(0, sname.len - 1)
                var ft = this.struct_field_lookup(sname, ep.name)
                if ft == "mt_str":
                    return "mt_str"
            if self_is_string_field_name(ep.name):
                return "mt_str"
        return ""


    function self_infer_read_pointee_type(call_expr: nodes.Expr) -> str:
        if unsafe: call_expr.args.len() < 1:
            return ""
        let a0 = unsafe: call_expr.args.get(0) else:
            return ""
        let ap0: ptr[nodes.Expr]? = unsafe: read(a0)
        if ap0 == null:
            return ""
        let arg = unsafe: read(ap0)
        if arg.kind == nodes.ExprKind.identifier:
            var st = this.scope_lookup(arg.name)
            if st != "" and st != "void*" and self_str_ends_with(st, "*"):
                return st.slice(0, st.len - 1)
        return ""


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
            if e.lexeme != "":
                let first = e.lexeme.byte_at(0)
                if first == 'c':
                    # c"..." → strip c prefix for C
                    unsafe: this.out_buf.append(e.lexeme.slice(1, e.lexeme.len - 1))
                else if first == 'f':
                    # f"..." → emit as-is for now
                    unsafe: this.out_buf.append(e.lexeme)
                else:
                    # Regular "..." → MT_STR wrapper
                    unsafe: this.out_buf.append("MT_STR(")
                    unsafe: this.out_buf.append(e.lexeme)
                    unsafe: this.out_buf.append(")")
        else if kind == nodes.ExprKind.char_literal:
            unsafe: this.out_buf.append(e.lexeme)
        else if kind == nodes.ExprKind.boolean_literal:
            unsafe: this.out_buf.append(e.name)
        else if kind == nodes.ExprKind.null_literal:
            unsafe: this.out_buf.append("NULL")
        else if kind == nodes.ExprKind.binary_op:
            var op = e.name
            if op == "or":
                op = "||"
            else if op == "and":
                op = "&&"
            # Detect mt_str == / mt_str != comparisons
            var left_t = this.self_infer_expr_type(e.left)
            if left_t == "":
                var lp = e.left
                if lp != null:
                    left_t = this.self_expr_is_mt_str(lp)
            var right_t = this.self_infer_expr_type(e.right)
            if right_t == "":
                var rp = e.right
                if rp != null:
                    right_t = this.self_expr_is_mt_str(rp)
            if (op == "==" or op == "!=") and left_t == "mt_str" and right_t == "mt_str":
                if op == "!=":
                    unsafe: this.out_buf.append("!")
                unsafe: this.out_buf.append("mt_str_eq(")
                this.self_write_expr_buf(e.left)
                unsafe: this.out_buf.append(", ")
                this.self_write_expr_buf(e.right)
                unsafe: this.out_buf.append(")")
            else:
                unsafe: this.out_buf.append("(")
                this.self_write_expr_buf(e.left)
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
            if this.self_try_write_builtin(expr_ptr):
                pass
            else if this.self_is_struct_ctor(expr_ptr):
                this.self_write_struct_call(expr_ptr)
            else if this.self_is_vec_method(expr_ptr):
                this.self_write_vec_method(expr_ptr)
            else if this.self_is_method_call(expr_ptr):
                this.self_write_method_call(expr_ptr)
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


    editable function self_try_write_builtin(expr_ptr: ptr[nodes.Expr]) -> bool:
        let e = unsafe: read(expr_ptr)
        let callee = e.left
        if callee == null:
            return false
        let ce = unsafe: read(callee)
        if ce.kind != nodes.ExprKind.identifier:
            return false
        if ce.name == "fatal":
            this.self_write_builtin_fatal(expr_ptr)
            return true
        if ce.name == "read":
            this.self_write_builtin_read(expr_ptr)
            return true
        if ce.name == "ref_of":
            this.self_write_builtin_ref_of(expr_ptr)
            return true
        if ce.name == "ptr_of":
            this.self_write_builtin_ptr_of(expr_ptr)
            return true
        if ce.name == "const_ptr_of":
            this.self_write_builtin_const_ptr_of(expr_ptr)
            return true
        return false


    editable function self_write_builtin_fatal(expr_ptr: ptr[nodes.Expr]) -> void:
        let e = unsafe: read(expr_ptr)
        unsafe: this.out_buf.append("do { mt_str _f = ")
        var si: ptr_uint = 0
        while si < unsafe: e.args.len():
            if si > 0:
                unsafe: this.out_buf.append(", ")
            let a = unsafe: e.args.get(si) else:
                break
            let ap: ptr[nodes.Expr]? = unsafe: read(a)
            if ap != null:
                this.self_write_expr_buf(ap)
            si += 1
        unsafe: this.out_buf.append("; fwrite(_f.data, 1, _f.len, stderr); fputc((int)'\\n', stderr); abort(); } while(0)")


    editable function self_write_builtin_read(expr_ptr: ptr[nodes.Expr]) -> void:
        let e = unsafe: read(expr_ptr)
        if unsafe: e.args.len() < 1:
            return
        let a0 = unsafe: e.args.get(0) else:
            return
        let ap0: ptr[nodes.Expr]? = unsafe: read(a0)
        if ap0 == null:
            return
        let arg = unsafe: read(ap0)
        var cast_type = ""
        if arg.kind == nodes.ExprKind.identifier:
            cast_type = this.scope_lookup(arg.name)
        # Only use return type when scope type is explicitly void*
        if cast_type == "void*" and this.current_return_type != "" and this.current_return_type != "void":
            unsafe: this.out_buf.append("(*(")
            unsafe: this.out_buf.append(this.current_return_type)
            unsafe: this.out_buf.append("*")
            unsafe: this.out_buf.append(")")
            this.self_write_expr_buf(ap0)
            unsafe: this.out_buf.append(")")
            return
        if cast_type != "" and self_str_ends_with(cast_type, "*"):
            unsafe: this.out_buf.append("(*(")
            unsafe: this.out_buf.append(cast_type)
            unsafe: this.out_buf.append(")")
            this.self_write_expr_buf(ap0)
            unsafe: this.out_buf.append(")")
            return
        unsafe: this.out_buf.append("(*(")
        this.self_write_expr_buf(ap0)
        unsafe: this.out_buf.append("))")


    editable function self_write_builtin_ref_of(expr_ptr: ptr[nodes.Expr]) -> void:
        let e = unsafe: read(expr_ptr)
        unsafe: this.out_buf.append("&(")
        var ai: ptr_uint = 0
        while ai < unsafe: e.args.len():
            if ai > 0:
                unsafe: this.out_buf.append(", ")
            let a = unsafe: e.args.get(ai) else:
                break
            let ap: ptr[nodes.Expr]? = unsafe: read(a)
            if ap != null:
                this.self_write_expr_buf(ap)
            ai += 1
        unsafe: this.out_buf.append(")")


    editable function self_write_builtin_ptr_of(expr_ptr: ptr[nodes.Expr]) -> void:
        let e = unsafe: read(expr_ptr)
        unsafe: this.out_buf.append("(void*)&(")
        var ai: ptr_uint = 0
        while ai < unsafe: e.args.len():
            if ai > 0:
                unsafe: this.out_buf.append(", ")
            let a = unsafe: e.args.get(ai) else:
                break
            let ap: ptr[nodes.Expr]? = unsafe: read(a)
            if ap != null:
                this.self_write_expr_buf(ap)
            ai += 1
        unsafe: this.out_buf.append(")")


    editable function self_write_builtin_const_ptr_of(expr_ptr: ptr[nodes.Expr]) -> void:
        let e = unsafe: read(expr_ptr)
        unsafe: this.out_buf.append("(const void*)&(")
        var ai: ptr_uint = 0
        while ai < unsafe: e.args.len():
            if ai > 0:
                unsafe: this.out_buf.append(", ")
            let a = unsafe: e.args.get(ai) else:
                break
            let ap: ptr[nodes.Expr]? = unsafe: read(a)
            if ap != null:
                this.self_write_expr_buf(ap)
            ai += 1
        unsafe: this.out_buf.append(")")


    editable function self_is_vec_method(expr_ptr: ptr[nodes.Expr]) -> bool:
        if not this.self_is_method_call(expr_ptr):
            return false
        let e = unsafe: read(expr_ptr)
        let callee = e.left
        if callee == null:
            return false
        let ce = unsafe: read(callee)
        if ce.kind != nodes.ExprKind.member_access:
            return false
        var method_name = ce.name
        if method_name == "create" or method_name == "push" or method_name == "get" or method_name == "len":
            # Only reject direct this.method() calls, not this.field.method() chains
            var left_ptr = ce.left
            if left_ptr != null:
                let left_inner = unsafe: read(left_ptr)
                if left_inner.kind == nodes.ExprKind.identifier and left_inner.name == "this":
                    return false
            return true
        return false


    editable function self_write_vec_method(expr_ptr: ptr[nodes.Expr]) -> void:
        let e = unsafe: read(expr_ptr)
        let callee = e.left
        if callee == null:
            return
        let ce = unsafe: read(callee)
        var method_name = ce.name
        if method_name == "create":
            unsafe: this.out_buf.append("((mt_vec){0})")
        else if method_name == "len":
            var left_expr = ce.left
            if left_expr != null:
                this.self_write_expr_buf(left_expr)
            else:
                unsafe: this.out_buf.append("/* vec len */")
            unsafe: this.out_buf.append(".len")
        else if method_name == "push":
            if unsafe: e.args.len() < 1:
                unsafe: this.out_buf.append("/* vec push */")
                return
            unsafe: this.out_buf.append("do { __typeof__(")
            let a0 = unsafe: e.args.get(0) else:
                return
            let ap0: ptr[nodes.Expr]? = unsafe: read(a0)
            if ap0 != null:
                this.self_write_expr_buf(ap0)
            unsafe: this.out_buf.append(") _mtval = ")
            if ap0 != null:
                this.self_write_expr_buf(ap0)
            unsafe: this.out_buf.append("; mt_vec_push_impl(&(")
            var left_expr = ce.left
            if left_expr != null:
                this.self_write_expr_buf(left_expr)
            unsafe: this.out_buf.append("), &_mtval, sizeof(_mtval)); } while(0)")
        else if method_name == "get":
            if unsafe: e.args.len() < 1:
                unsafe: this.out_buf.append("NULL")
                return
            var is_str_vec = self_is_str_vec_field(ce.left)
            if is_str_vec:
                unsafe: this.out_buf.append("(mt_str*)")
            unsafe: this.out_buf.append("mt_vec_get_impl(&(")
            var left_expr = ce.left
            if left_expr != null:
                this.self_write_expr_buf(left_expr)
            unsafe: this.out_buf.append("), ")
            let a0 = unsafe: e.args.get(0) else:
                return
            let ap0: ptr[nodes.Expr]? = unsafe: read(a0)
            if ap0 != null:
                this.self_write_expr_buf(ap0)
            if is_str_vec:
                unsafe: this.out_buf.append(", sizeof(mt_str))")
            else:
                unsafe: this.out_buf.append(", sizeof(void*))")
        else:
            unsafe: this.out_buf.append("/* vec method */")


    editable function self_is_struct_ctor(expr_ptr: ptr[nodes.Expr]) -> bool:
        let e = unsafe: read(expr_ptr)
        var len = unsafe: e.args.len()
        # Struct ctors have named args: (name, value, name, value, ...) → even count
        if len < 2:
            return false
        if (len & 1) != 0:
            return false
        # Check that callee looks like a type name (starts with uppercase or is a member chain ending in uppercase)
        if not self_callee_looks_like_type(e.left):
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
        this.self_write_tname_expr_depth(expr_ptr, true)


    editable function self_write_tname_expr_depth(expr_ptr: ptr[nodes.Expr]?, is_top: bool) -> void:
        if expr_ptr == null:
            return
        let e = unsafe: read(expr_ptr)
        if e.kind == nodes.ExprKind.identifier:
            if is_top and not self_is_c_primitive(e.name) and this.module_name != "":
                unsafe: this.out_buf.append(this.module_name)
                unsafe: this.out_buf.append("_")
            unsafe: this.out_buf.append(e.name)
        else if e.kind == nodes.ExprKind.member_access:
            this.self_write_tname_expr_depth(e.left, false)
            unsafe: this.out_buf.append("_")
            unsafe: this.out_buf.append(e.name)
        else:
            this.self_write_expr_buf(expr_ptr)


    editable function self_write_callee_expr(expr_ptr: ptr[nodes.Expr]?) -> void:
        this.self_write_callee_expr_depth(expr_ptr, true)


    editable function self_write_callee_expr_depth(expr_ptr: ptr[nodes.Expr]?, is_top: bool) -> void:
        if expr_ptr == null:
            return
        let e = unsafe: read(expr_ptr)
        if e.kind == nodes.ExprKind.identifier:
            unsafe: this.out_buf.append(e.name)
        else if e.kind == nodes.ExprKind.member_access:
            if is_top and this.current_receiver_type != "":
                let left_expr = e.left
                if left_expr != null:
                    let left = unsafe: read(left_expr)
                    if left.kind == nodes.ExprKind.identifier and left.name == "this":
                        if this.module_name != "":
                            unsafe: this.out_buf.append(this.module_name)
                            unsafe: this.out_buf.append("_")
                        unsafe: this.out_buf.append(this.current_receiver_type)
                        unsafe: this.out_buf.append("_")
                        unsafe: this.out_buf.append(e.name)
                        return
            this.self_write_callee_expr_depth(e.left, false)
            unsafe: this.out_buf.append("_")
            unsafe: this.out_buf.append(e.name)
        else if e.kind == nodes.ExprKind.index_access:
            this.self_write_callee_expr_depth(e.left, false)
            unsafe: this.out_buf.append("_")
            this.self_write_expr_buf(e.right)
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
        let callee = e.left
        if callee != null:
            let ce = unsafe: read(callee)
            if ce.kind == nodes.ExprKind.identifier and this.module_name != "" and not self_is_builtin_call(ce.name) and not self_is_c_primitive(ce.name):
                unsafe: this.out_buf.append(this.module_name)
                unsafe: this.out_buf.append("_")
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

            this.scope_enter()
            var mret_buf: str_buffer[512]
            this.write_ctype_node(ptr_of(mret_buf), method.return_node)
            this.current_return_type = this.pool_type(unsafe: mret_buf.as_str())
            var tname_buf: str_buffer[512]
            this.write_tname(ptr_of(tname_buf), decl.name)
            tname_buf.append("*")
            this.scope_bind("this", this.pool_type(unsafe: tname_buf.as_str()))
            ji = 0
            while ji < method.params.len():
                let p = method.params.get(ji) else:
                    break
                let param = unsafe: read(p)
                var pt: str_buffer[512]
                this.write_ctype_node(ptr_of(pt), param.type_node)
                this.scope_bind(param.name, this.pool_type(unsafe: pt.as_str()))
                ji += 1

            if method.body_block != null:
                this.current_receiver_type = decl.name
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

            this.scope_leave()
            this.pline("}")
            this.pline("")
            i += 1


    editable function pool_type(ctype: str) -> str:
        var start = this.type_pool.len()
        unsafe: this.type_pool.append(ctype)
        return unsafe: this.type_pool.as_str().slice(start, ctype.len)


    editable function build_type_maps(source: nodes.SourceFile) -> void:
        var i: ptr_uint = 0
        while i < source.decls.len():
            let d = source.decls.get(i) else:
                break
            let decl = unsafe: read(d)
            if decl.kind == nodes.DeclKind.function_def:
                var buf: str_buffer[512]
                this.write_ctype_node(ptr_of(buf), decl.return_node)
                var pooled = this.pool_type(unsafe: buf.as_str())
                this.func_lookup_names.push(decl.name)
                this.func_lookup_rets.push(pooled)
            else if decl.kind == nodes.DeclKind.extending_block:
                var mi: ptr_uint = 0
                while mi < decl.methods.len():
                    let m = decl.methods.get(mi) else:
                        break
                    let method = unsafe: read(m)
                    var buf: str_buffer[512]
                    this.write_ctype_node(ptr_of(buf), method.return_node)
                    var pooled = this.pool_type(unsafe: buf.as_str())
                    this.method_lookup_receivers.push(decl.name)
                    this.method_lookup_names.push(method.name)
                    this.method_lookup_rets.push(pooled)
                    mi += 1
            else if decl.kind == nodes.DeclKind.struct_decl or decl.kind == nodes.DeclKind.union_decl:
                var sname_buf: str_buffer[512]
                this.write_tname(ptr_of(sname_buf), decl.name)
                var struct_cname = this.pool_type(unsafe: sname_buf.as_str())
                var fi: ptr_uint = 0
                while fi < decl.fields.len():
                    let f = decl.fields.get(fi) else:
                        break
                    let field = unsafe: read(f)
                    var fbuf: str_buffer[512]
                    this.write_ctype_node(ptr_of(fbuf), field.type_node)
                    var ftype = this.pool_type(unsafe: fbuf.as_str())
                    this.field_struct_names.push(struct_cname)
                    this.field_names.push(field.name)
                    this.field_types.push(ftype)
                    fi += 1
            i += 1


    editable function scope_enter() -> void:
        this.scope_stack.push(this.local_names.len())


    editable function scope_leave() -> void:
        let depth_ptr = this.scope_stack.last() else:
            return
        var depth = unsafe: read(depth_ptr)
        while this.local_names.len() > depth:
            this.local_names.pop()
            this.local_types.pop()
        this.scope_stack.pop()


    editable function scope_bind(name: str, ctype: str) -> void:
        this.local_names.push(name)
        this.local_types.push(ctype)


    function scope_lookup(name: str) -> str:
        var i: ptr_uint = this.local_names.len()
        while i > 0:
            i -= 1
            let np = this.local_names.get(i) else:
                break
            let n = unsafe: read(np)
            if n == name:
                let tp = this.local_types.get(i) else:
                    break
                let t = unsafe: read(tp)
                return t
        return ""


    function func_lookup_ret(name: str) -> str:
        var i: ptr_uint = 0
        while i < this.func_lookup_names.len():
            let np = this.func_lookup_names.get(i) else:
                break
            let n = unsafe: read(np)
            if n == name:
                let rp = this.func_lookup_rets.get(i) else:
                    break
                let r = unsafe: read(rp)
                return r
            i += 1
        return ""


    function method_lookup_ret(receiver_type: str, method_name: str) -> str:
        var i: ptr_uint = 0
        while i < this.method_lookup_receivers.len():
            let rp = this.method_lookup_receivers.get(i) else:
                break
            let r = unsafe: read(rp)
            if r == receiver_type:
                let mp = this.method_lookup_names.get(i) else:
                    break
                let m = unsafe: read(mp)
                if m == method_name:
                    let tp = this.method_lookup_rets.get(i) else:
                        break
                    let t = unsafe: read(tp)
                    return t
            i += 1
        return ""


    function struct_field_lookup(struct_cname: str, field_name: str) -> str:
        var i: ptr_uint = 0
        while i < this.field_struct_names.len():
            let sp = this.field_struct_names.get(i) else:
                break
            let s = unsafe: read(sp)
            if s == struct_cname:
                let fp = this.field_names.get(i) else:
                    break
                let f = unsafe: read(fp)
                if f == field_name:
                    let tp = this.field_types.get(i) else:
                        break
                    let t = unsafe: read(tp)
                    return t
            i += 1
        return ""


function self_is_str_vec_field(expr_ptr: ptr[nodes.Expr]?) -> bool:
    if expr_ptr == null:
        return false
    let e = unsafe: read(expr_ptr)
    if e.kind != nodes.ExprKind.member_access:
        return false
    var rp = e.left
    if rp == null:
        return false
    let recv = unsafe: read(rp)
    if recv.kind != nodes.ExprKind.identifier or recv.name != "this":
        return false
    var fname = e.name
    if fname == "local_names" or fname == "local_types":
        return true
    if fname == "func_lookup_names" or fname == "func_lookup_rets":
        return true
    if fname == "method_lookup_receivers" or fname == "method_lookup_names" or fname == "method_lookup_rets":
        return true
    if fname == "field_struct_names" or fname == "field_names" or fname == "field_types":
        return true
    return false


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

function self_is_builtin_call(name: str) -> bool:
    if name == "fatal" or name == "read" or name == "ref_of" or name == "ptr_of" or name == "const_ptr_of":
        return true
    if name == "zero" or name == "default" or name == "heap" or name == "alloc" or name == "must_alloc":
        return true
    if name == "vec" or name == "create" or name == "push" or name == "get" or name == "len":
        return true
    if name == "append" or name == "assign" or name == "clear" or name == "as_str" or name == "as_cstr":
        return true
    if name == "unsafe" or name == "read":
        return true
    return false

function self_char_is_uppercase(ch: ubyte) -> bool:
    return ch >= 'A' and ch <= 'Z'

function self_str_ends_with(s: str, suffix: str) -> bool:
    if suffix.len > s.len:
        return false
    return s.slice(s.len - suffix.len, suffix.len) == suffix

function self_callee_looks_like_type(callee: ptr[nodes.Expr]?) -> bool:
    if callee == null:
        return false
    let ce = unsafe: read(callee)
    if ce.kind == nodes.ExprKind.identifier:
        return ce.name != "" and self_char_is_uppercase(ce.name.byte_at(0))
    if ce.kind == nodes.ExprKind.member_access:
        return self_callee_looks_like_type(ce.left) or self_char_is_uppercase(ce.name.byte_at(0))
    return false

function self_is_string_field_name(name: str) -> bool:
    if name == "name" or name == "lexeme" or name == "text" or name == "path":
        return true
    if name == "message" or name == "value_text" or name == "alias":
        return true
    if name == "type_text" or name == "module_name" or name == "source_text":
        return true
    return false
