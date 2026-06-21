import std.str
import std.vec as vec
import std.stdio

import mtc.ast.nodes


public struct Lowerer:
    module_name: str
    source_text: str


extending Lowerer:
    public static function create(module_name: str, source_text: str) -> Lowerer:
        return Lowerer(module_name = module_name, source_text = source_text)


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
        if unsafe: read(tp).kind == nodes.TypeKind.type_nullable:
            this.write_ctype_node(buf, unsafe: read(tp).inner)
            return
        var name = unsafe: read(tp).name
        if name == "const_ptr":
            name = "ptr"
        if name == "usize":
            name = "ptr_uint"
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
            this.write_decl(decl)
            i += 1


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
        if decl.body_src_start > 0:
            var end_pos = decl.body_src_end
            if end_pos == 0 or end_pos <= decl.body_src_start:
                end_pos = this.source_text.len
            var body_raw = this.source_text.slice(decl.body_src_start, end_pos - decl.body_src_start)
            var translated = this.self_translate_body(body_raw)
            this.pline(translated)
        else:
            this.pline("    /* body not lowered */")
        this.pline("}")
        this.pline("")


    function self_translate_body(raw: str) -> str:
        var result: str_buffer[16384]
        var pos: ptr_uint = 0
        while pos < raw.len:
            let ch = raw.byte_at(pos)
            if ch == 'a':
                var rest = raw.len - pos
                if rest >= 4 and raw.byte_at(pos+1) == 'n' and raw.byte_at(pos+2) == 'd':
                    var after = raw.byte_at(pos+3)
                    if after == ' ' or after == '\n' or after == '\r':
                        result.append("&&")
                        pos += 3
                        continue
            if ch == 'o':
                var rest = raw.len - pos
                if rest >= 3 and raw.byte_at(pos+1) == 'r':
                    var after = raw.byte_at(pos+2)
                    if after == ' ' or after == '\n' or after == '\r':
                        result.append("||")
                        pos += 2
                        continue
            if ch == 'n':
                var rest = raw.len - pos
                if rest >= 4 and raw.byte_at(pos+1) == 'o' and raw.byte_at(pos+2) == 't':
                    var after = raw.byte_at(pos+3)
                    if after == ' ' or after == '\n' or after == '\r':
                        result.append("!")
                        pos += 3
                        continue
            if ch == 'u':
                var rest = raw.len - pos
                if rest >= 7 and raw.byte_at(pos+1) == 'n' and raw.byte_at(pos+2) == 's' and raw.byte_at(pos+3) == 'a' and raw.byte_at(pos+4) == 'f' and raw.byte_at(pos+5) == 'e':
                    if raw.byte_at(pos+6) == ':' or raw.byte_at(pos+6) == ' ':
                        pos += 6
                        continue
            if ch == 'l':
                var rest = raw.len - pos
                if rest >= 4 and raw.byte_at(pos+1) == 'e' and raw.byte_at(pos+2) == 't' and raw.byte_at(pos+3) == ' ':
                    result.append("auto ")
                    pos += 4
                    continue
            if ch == '\n':
                var skip_semi = false
                var pp: ptr_uint = pos
                while pp > 0:
                    pp -= 1
                    if raw.byte_at(pp) == '\n' or raw.byte_at(pp) == '\r':
                        break
                    if raw.byte_at(pp) == ':':
                        skip_semi = true
                        break
                    if raw.byte_at(pp) == '{' or raw.byte_at(pp) == '}' or raw.byte_at(pp) == ';' or raw.byte_at(pp) == '#':
                        skip_semi = true
                        break
                    if raw.byte_at(pp) != ' ':
                        break
                var is_blank = true
                pp = pos
                while pp > 0:
                    pp -= 1
                    if raw.byte_at(pp) == '\n' or raw.byte_at(pp) == '\r':
                        break
                    if raw.byte_at(pp) != ' ':
                        is_blank = false
                        break
                if not skip_semi and not is_blank:
                    result.append(";")
            result.append(raw.slice(pos, 1))
            pos += 1
        return result.as_str()


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
            var ji: ptr_uint = 0
            while ji < method.params.len():
                let p = method.params.get(ji) else:
                    break
                let param = unsafe: read(p)
                if ji > 0:
                    buf.append(", ")
                this.write_ctype_node(ptr_of(buf), param.type_node)
                buf.append(" ")
                buf.append(param.name)
                ji += 1
            buf.append(");")
            this.pline(buf.as_str())
            i += 1
        this.pline("")
