import std.str
import std.vec as vec
import std.stdio

import mtc.ast.nodes


public struct Lowerer:
    module_name: str


extending Lowerer:
    public static function create(module_name: str) -> Lowerer:
        return Lowerer(module_name = module_name)


    function pline(line: str) -> void:
        stdio.print_line(line)


    editable function write_header() -> void:
        var dbg: str_buffer[512]
        dbg.assign("// module: ")
        dbg.append(this.module_name)
        dbg.append(" len=")
        var len_buf: str_buffer[32]
        len_buf.assign(f"#{this.module_name.len}")
        dbg.append(len_buf.as_str())
        this.pline(dbg.as_str())
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


    public     editable function lower_module(source: nodes.SourceFile) -> void:
        this.write_header()

        var i: ptr_uint = 0
        while i < source.decls.len():
            let d = source.decls.get(i) else:
                break
            let decl = unsafe: read(d)
            if decl.name == "":
                continue
            this.write_forward_decl(decl)
            i += 1
        this.pline("")

        i = 0
        while i < source.decls.len():
            let d = source.decls.get(i) else:
                break
            let decl = unsafe: read(d)
            if decl.name == "":
                continue
            this.write_decl(decl)
            i += 1


    editable function write_forward_decl(decl: nodes.Decl) -> void:
        if decl.kind == nodes.DeclKind.function_def or decl.kind == nodes.DeclKind.const_decl or decl.kind == nodes.DeclKind.extern_function:
            return
        if decl.name == "":
            return
        if decl.kind == nodes.DeclKind.const_decl and decl.type_name == "" and decl.value_text == "" and decl.stmt_count == 0:
            return
        if decl.kind == nodes.DeclKind.enum_decl or decl.kind == nodes.DeclKind.flags_decl:
            var buf: str_buffer[512]
            buf.assign("typedef ")
            this.self_ctype_into(ptr_of(buf), decl.type_name)
            buf.append(" ")
            this.self_tname_into(ptr_of(buf), decl.name)
            buf.append(";")
            this.pline(buf.as_str())
        else if decl.kind == nodes.DeclKind.struct_decl or decl.kind == nodes.DeclKind.union_decl or decl.kind == nodes.DeclKind.opaque_decl:
            var buf: str_buffer[512]
            buf.assign("typedef struct ")
            this.self_tname_into(ptr_of(buf), decl.name)
            buf.append(" ")
            this.self_tname_into(ptr_of(buf), decl.name)
            buf.append(";")
            this.pline(buf.as_str())


    editable function write_decl(decl: nodes.Decl) -> void:
        if decl.name == "":
            return
        if decl.kind == nodes.DeclKind.const_decl and decl.type_name == "" and decl.value_text == "" and decl.stmt_count == 0:
            return
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
            this.write_function_sig(decl)
        else if decl.kind == nodes.DeclKind.extern_function:
            this.write_function_sig(decl)
        else if decl.kind == nodes.DeclKind.const_decl and decl.stmt_count > 0:
            this.write_function_sig(decl)
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
        this.self_tname_into(ptr_of(buf), decl.name)
        buf.append(" {")
        this.pline(buf.as_str())
        var i: ptr_uint = 0
        while i < decl.fields.len():
            let f = decl.fields.get(i) else:
                break
            let field = unsafe: read(f)
            buf.assign("  ")
            this.self_ctype_into(ptr_of(buf), field.type_text)
            buf.append(" ")
            buf.append(field.name)
            buf.append(";")
            this.pline(buf.as_str())
            i += 1
        buf.assign("} ")
        this.self_tname_into(ptr_of(buf), decl.name)
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
            this.self_tname_into(ptr_of(buf), decl.name)
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
        this.self_ctype_into(ptr_of(buf), decl.type_name)
        buf.append(" ")
        this.self_tname_into(ptr_of(buf), decl.name)
        buf.append(";")
        this.pline(buf.as_str())
        this.pline("")


    editable function write_function_sig(decl: nodes.Decl) -> void:
        var buf: str_buffer[512]
        if decl.kind == nodes.DeclKind.const_decl:
            buf.append("static ")
        this.self_ctype_into(ptr_of(buf), decl.return_text)
        buf.append(" ")
        this.self_fname_into(ptr_of(buf), decl.name, "")
        buf.append("(")
        var i: ptr_uint = 0
        while i < decl.params.len():
            let p = decl.params.get(i) else:
                break
            let param = unsafe: read(p)
            if i > 0:
                buf.append(", ")
            this.self_ctype_into(ptr_of(buf), param.type_text)
            buf.append(" ")
            buf.append(param.name)
            i += 1
        buf.append(")")
        if decl.kind == nodes.DeclKind.const_decl and decl.stmt_count == 0:
            if decl.value_text != "":
                buf.append(" = ")
                buf.append(decl.value_text)
            buf.append(";")
        else:
            buf.append(";")
        this.pline(buf.as_str())
        this.pline("")


    editable function write_const(decl: nodes.Decl) -> void:
        var buf: str_buffer[512]
        if decl.value_text != "":
            buf.assign("static const ")
        else:
            buf.assign("static ")
        this.self_ctype_into(ptr_of(buf), decl.type_name)
        buf.append(" ")
        this.self_fname_into(ptr_of(buf), decl.name, "")
        if decl.value_text != "":
            buf.append(" = ")
            buf.append(decl.value_text)
        buf.append(";")
        this.pline(buf.as_str())


    editable function write_var(decl: nodes.Decl) -> void:
        var buf: str_buffer[512]
        buf.assign("static ")
        this.self_ctype_into(ptr_of(buf), decl.type_name)
        buf.append(" ")
        this.self_fname_into(ptr_of(buf), decl.name, "")
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
            this.self_ctype_into(ptr_of(buf), method.return_text)
            buf.append(" ")
            this.self_fname_into(ptr_of(buf), method.name, decl.name)
            buf.append("(")
            var ji: ptr_uint = 0
            while ji < method.params.len():
                let p = method.params.get(ji) else:
                    break
                let param = unsafe: read(p)
                if ji > 0:
                    buf.append(", ")
                this.self_ctype_into(ptr_of(buf), param.type_text)
                buf.append(" ")
                buf.append(param.name)
                ji += 1
            buf.append(");")
            this.pline(buf.as_str())
            i += 1
        this.pline("")


    function self_ctype_into(buf_ptr: ptr[str_buffer[512]], mt_type: str) -> void:
        var buf = unsafe: read(buf_ptr)
        if mt_type == "bool":
            buf.append("bool")
        else if mt_type == "int":
            buf.append("int32_t")
        else if mt_type == "uint":
            buf.append("uint32_t")
        else if mt_type == "byte":
            buf.append("int8_t")
        else if mt_type == "ubyte":
            buf.append("uint8_t")
        else if mt_type == "short":
            buf.append("int16_t")
        else if mt_type == "ushort":
            buf.append("uint16_t")
        else if mt_type == "long":
            buf.append("int64_t")
        else if mt_type == "ulong":
            buf.append("uint64_t")
        else if mt_type == "float":
            buf.append("float")
        else if mt_type == "double":
            buf.append("double")
        else if mt_type == "char":
            buf.append("char")
        else if mt_type == "void":
            buf.append("void")
        else if mt_type == "str":
            buf.append("mt_str")
        else if mt_type == "cstr":
            buf.append("const char*")
        else if mt_type == "ptr_int":
            buf.append("intptr_t")
        else if mt_type == "ptr_uint":
            buf.append("uintptr_t")
        else if mt_type == "ptr":
            buf.append("void*")
        else if mt_type == "" or mt_type == "?":
            pass
        else:
            var i: ptr_uint = 0
            while i < mt_type.len:
                let ch = mt_type.byte_at(i)
                if ch == '.':
                    buf.append("_")
                else:
                    buf.append(mt_type.slice(i, 1))
                i += 1


    function self_tname_into(buf_ptr: ptr[str_buffer[512]], type_name: str) -> void:
        var buf = unsafe: read(buf_ptr)
        var mn = this.module_name
        if mn != "":
            buf.append(mn)
            buf.append("_")
        buf.append(type_name)


    function self_fname_into(buf_ptr: ptr[str_buffer[512]], func_name: str, receiver_type: str) -> void:
        var buf = unsafe: read(buf_ptr)
        if this.module_name != "":
            buf.append(this.module_name)
            buf.append("_")
        if receiver_type != "":
            buf.append(receiver_type)
            buf.append("_")
        buf.append(func_name)
