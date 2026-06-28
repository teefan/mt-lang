import std.str
import std.string as string_mod

public function lower_analysis_to_ir(analysis_json: str) -> string_mod.String:
    var r = string_mod.String.create()
    var root = extract_json_string_value(analysis_json, "\"root\":")
    let root_str = root.as_str()
    let module_name = find_module_name_in(root_str)
    let func_name = find_func_name_in(root_str)

    r.append("{\"$mt_type\":\"IR:Program\",\"module_name\":\"")
    r.append(module_name)
    r.append("\",\"includes\":[{\"$mt_type\":\"IR:Include\",\"header\":\"<stdbool.h>\"},{\"$mt_type\":\"IR:Include\",\"header\":\"<stdint.h>\"},{\"$mt_type\":\"IR:Include\",\"header\":\"<string.h>\"},{\"$mt_type\":\"IR:Include\",\"header\":\"<stdio.h>\"}],\"constants\":[],\"globals\":[],\"opaques\":[],\"structs\":[],\"unions\":[],\"enums\":[],\"variants\":[],\"static_asserts\":[],\"functions\":[")
    lower_function_from_analysis(ref_of(r), root_str, func_name, module_name)
    r.append("],\"source_path\":null}")
    root.release()
    return r

function lower_function_from_analysis(buf: ref[string_mod.String], analysis: str, name: str, mod_name: str) -> void:
    var linkage = string_mod.String.create()
    linkage.append(mod_name)
    linkage.push_byte('_')
    linkage.append(name)

    buf.append("{\"$mt_type\":\"IR:Function\",\"name\":\"")
    buf.append(name)
    buf.append("\",\"linkage_name\":\"")
    buf.append(linkage.as_str())
    linkage.release()

    let func_obj = json_get_obj(analysis, "functions")
    let func_binding = json_get_obj(func_obj, name)
    let ast_json = json_get_obj(func_binding, "ast")

    buf.append("\",\"params\":[")
    let params_json = json_get_obj(ast_json, "params")
    if params_json.len > 0:
        var ppos: ptr_uint = 1
        var pfirst = true
        while ppos < params_json.len:
            if params_json.byte_at(ppos) == '{':
                let pobj = read_balanced(params_json, ppos)
                if pobj.len > 0:
                    ppos = ppos + pobj.len
                    if not pfirst:
                        buf.push_byte(',')
                    pfirst = false
                    let pn = json_get_str(pobj, "name")
                    buf.append("{\"$mt_type\":\"IR:Param\",\"name\":\"")
                    buf.append(pn)
                    buf.append("\",\"linkage_name\":\"")
                    buf.append(pn)
                    buf.append("\",\"type\":{\"$type_ref\":\"Primitive\",\"name\":\"int\"},\"pointer\":false,\"line\":null}")
                else:
                    ppos += 1
            else:
                ppos += 1
    buf.append("]")

    let ret_json = json_get_obj(ast_json, "return_type")
    buf.append(",\"return_type\":")
    if ret_json.len > 0:
        lower_type_json(buf, ret_json)
    else:
        buf.append("{\"$type_ref\":\"Primitive\",\"name\":\"void\"}")

    buf.append(",\"body\":[")
    let body_json = json_get_obj(ast_json, "body")
    lower_body_json(buf, body_json)
    buf.append("],\"entry_point\":false,\"method_receiver_param\":false}")

function lower_body_json(buf: ref[string_mod.String], body: str) -> void:
    var pos: ptr_uint = 1
    var first = true
    while pos < body.len:
        if body.byte_at(pos) == '{':
            let obj = read_balanced(body, pos)
            if obj.len > 0:
                pos = pos + obj.len
                if not first:
                    buf.push_byte(',')
                first = false
                lower_stmt_json(buf, obj)
            else:
                pos += 1
        else:
            pos += 1

function lower_stmt_json(buf: ref[string_mod.String], stmt: str) -> void:
    let mt = json_get_str(stmt, "$mt_type")
    if mt == "AST:ReturnStmt":
        buf.append("{\"$mt_type\":\"IR:ReturnStmt\",\"value\":")
        lower_expr_json(buf, json_get_obj(stmt, "value"))
        buf.append(",\"line\":null,\"source_path\":null}")
    else if mt == "AST:LocalDecl":
        let nm = json_get_str(stmt, "name")
        buf.append("{\"$mt_type\":\"IR:LocalDecl\",\"name\":\"")
        buf.append(nm)
        buf.append("\",\"linkage_name\":\"")
        buf.append(nm)
        buf.append("\",\"type\":{\"$type_ref\":\"Primitive\",\"name\":\"int\"},\"value\":")
        let v = json_get_obj(stmt, "value")
        if v.len > 0:
            lower_expr_json(buf, v)
        else:
            buf.append("null")
        buf.append(",\"line\":null,\"source_path\":null}")
    else if mt == "AST:Assignment":
        buf.append("{\"$mt_type\":\"IR:Assignment\",\"target\":")
        lower_expr_json(buf, json_get_obj(stmt, "target"))
        let op = json_get_str(stmt, "operator")
        buf.append(",\"operator\":\"")
        buf.append(op)
        buf.append("\",\"value\":")
        lower_expr_json(buf, json_get_obj(stmt, "value"))
        buf.append(",\"line\":null,\"source_path\":null}")
    else if mt == "AST:ExpressionStmt":
        let expr = json_get_obj(stmt, "expression")
        if expr.len > 0 and expr.byte_at(0) == '{':
            buf.append("{\"$mt_type\":\"IR:ExpressionStmt\",\"expression\":")
            lower_expr_json(buf, expr)
            buf.append(",\"line\":null,\"source_path\":null}")
        else:
            buf.append("{\"$mt_type\":\"IR:PassStmt\",\"line\":null}")
    else if mt == "AST:IfStmt":
        lower_if_json(buf, stmt)
    else if mt == "AST:WhileStmt":
        lower_while_json(buf, stmt)
    else if mt == "AST:ForStmt":
        lower_for_json(buf, stmt)
    else if mt == "AST:DeferStmt":
        buf.append("{\"$mt_type\":\"IR:DeferStmt\",\"body\":[")
        lower_body_json(buf, json_get_obj(stmt, "body"))
        buf.append("],\"line\":null,\"source_path\":null}")
    else if mt == "AST:UnsafeStmt":
        buf.append("{\"$mt_type\":\"IR:UnsafeStmt\",\"body\":[")
        lower_body_json(buf, json_get_obj(stmt, "body"))
        buf.append("],\"line\":null,\"source_path\":null}")
    else:
        buf.append("{\"$mt_type\":\"IR:PassStmt\",\"line\":null}")

function lower_if_json(buf: ref[string_mod.String], stmt: str) -> void:
    buf.append("{\"$mt_type\":\"IR:IfStmt\",\"condition\":")
    lower_expr_json(buf, json_get_obj(stmt, "condition"))
    buf.append(",\"then_branch\":[")
    let branches = json_get_obj(stmt, "branches")
    var arm = branch_arm(branches, 0)
    lower_body_json(buf, json_get_obj(arm, "body"))
    buf.append("]")
    var else_arm = branch_arm(branches, 1)
    if else_arm.len > 0:
        buf.append(",\"else_branch\":[")
        lower_body_json(buf, json_get_obj(else_arm, "body"))
        buf.append("]")
    buf.append(",\"line\":null,\"source_path\":null}")

function lower_while_json(buf: ref[string_mod.String], stmt: str) -> void:
    buf.append("{\"$mt_type\":\"IR:WhileStmt\",\"condition\":")
    lower_expr_json(buf, json_get_obj(stmt, "condition"))
    buf.append(",\"body\":[")
    lower_body_json(buf, json_get_obj(stmt, "body"))
    buf.append("],\"line\":null,\"source_path\":null}")

function lower_for_json(buf: ref[string_mod.String], stmt: str) -> void:
    buf.append("{\"$mt_type\":\"IR:ForStmt\",\"bindings\":[")
    let bindings = json_get_obj(stmt, "bindings")
    if bindings.len > 0:
        var bpos: ptr_uint = 1
        var bfirst = true
        while bpos < bindings.len:
            if bindings.byte_at(bpos) == '{':
                let bobj = read_balanced(bindings, bpos)
                if bobj.len > 0:
                    bpos = bpos + bobj.len
                    if not bfirst:
                        buf.push_byte(',')
                    bfirst = false
                    buf.append("{\"$mt_type\":\"IR:LocalDecl\",\"name\":\"")
                    let bn = json_get_str(bobj, "name")
                    buf.append(bn)
                    buf.append("\",\"linkage_name\":\"")
                    buf.append(bn)
                    buf.append("\",\"type\":{\"$type_ref\":\"Primitive\",\"name\":\"int\"},\"value\":null,\"line\":null,\"source_path\":null}")
                else:
                    bpos += 1
            else:
                bpos += 1
    buf.append("],\"iterable\":")
    lower_expr_json(buf, json_get_obj(stmt, "iterable"))
    buf.append(",\"body\":[")
    lower_body_json(buf, json_get_obj(stmt, "body"))
    buf.append("],\"line\":null,\"source_path\":null}")

function branch_arm(json: str, index: ptr_uint) -> str:
    var pos: ptr_uint = 1
    var count: ptr_uint = 0
    while pos < json.len:
        if json.byte_at(pos) == '{':
            let obj = read_balanced(json, pos)
            if count == index:
                return obj
            count += 1
            pos = pos + obj.len
        else:
            pos += 1
    return ""

function lower_expr_json(buf: ref[string_mod.String], expr: str) -> void:
    let mt = json_get_str(expr, "$mt_type")
    if mt == "AST:IntegerLiteral":
        let v = json_read_value(expr, "value")
        buf.append("{\"$mt_type\":\"IR:IntegerLiteral\",\"value\":")
        buf.append(v)
        buf.append(",\"type\":{\"$type_ref\":\"Primitive\",\"name\":\"int\"}}")
    else if mt == "AST:Identifier":
        let nm = json_get_str(expr, "name")
        buf.append("{\"$mt_type\":\"IR:Name\",\"name\":\"")
        buf.append(nm)
        buf.append("\",\"type\":{\"$type_ref\":\"Primitive\",\"name\":\"int\"},\"pointer\":false}")
    else if mt == "AST:BinaryOp":
        let op = json_get_str(expr, "operator")
        buf.append("{\"$mt_type\":\"IR:Binary\",\"operator\":\"")
        buf.append(op)
        buf.append("\",\"left\":")
        lower_expr_json(buf, json_get_obj(expr, "left"))
        buf.append(",\"right\":")
        lower_expr_json(buf, json_get_obj(expr, "right"))
        buf.append(",\"type\":{\"$type_ref\":\"Primitive\",\"name\":\"int\"}}")
    else if mt == "AST:UnaryOp":
        let op = json_get_str(expr, "operator")
        buf.append("{\"$mt_type\":\"IR:Unary\",\"operator\":\"")
        buf.append(op)
        buf.append("\",\"operand\":")
        lower_expr_json(buf, json_get_obj(expr, "operand"))
        buf.append(",\"type\":{\"$type_ref\":\"Primitive\",\"name\":\"int\"}}")
    else if mt == "AST:FloatLiteral":
        let v = json_read_value(expr, "value")
        buf.append("{\"$mt_type\":\"IR:FloatLiteral\",\"value\":")
        buf.append(v)
        buf.append(",\"type\":{\"$type_ref\":\"Primitive\",\"name\":\"float\"}}")
    else if mt == "AST:BooleanLiteral":
        let v = json_read_value(expr, "value")
        buf.append("{\"$mt_type\":\"IR:BooleanLiteral\",\"value\":")
        buf.append(v)
        buf.append(",\"type\":{\"$type_ref\":\"Primitive\",\"name\":\"bool\"}}")
    else if mt == "AST:Call":
        buf.append("{\"$mt_type\":\"IR:Call\",\"callee\":")
        lower_expr_json(buf, json_get_obj(expr, "callee"))
        buf.append(",\"arguments\":[")
        let args_json = json_get_obj(expr, "arguments")
        if args_json.len > 0:
            var apos: ptr_uint = 1
            var afirst = true
            while apos < args_json.len:
                if args_json.byte_at(apos) == '{':
                    let aobj = read_balanced(args_json, apos)
                    if aobj.len > 0:
                        apos = apos + aobj.len
                        if not afirst:
                            buf.push_byte(',')
                        afirst = false
                        let arg_val = json_get_obj(aobj, "value")
                        if arg_val.len > 0:
                            lower_expr_json(buf, arg_val)
                        else:
                            buf.append("{\"$mt_type\":\"IR:IntegerLiteral\",\"value\":0,\"type\":{\"$type_ref\":\"Primitive\",\"name\":\"int\"}}")
                    else:
                        apos += 1
                else:
                    apos += 1
        buf.append("],\"type\":{\"$type_ref\":\"Primitive\",\"name\":\"int\"}}")
    else if mt == "AST:MemberAccess":
        buf.append("{\"$mt_type\":\"IR:Member\",\"receiver\":")
        lower_expr_json(buf, json_get_obj(expr, "receiver"))
        let mn = json_get_str(expr, "member")
        buf.append(",\"member\":\"")
        buf.append(mn)
        buf.append("\",\"type\":{\"$type_ref\":\"Primitive\",\"name\":\"int\"}}")
    else if mt == "AST:StringLiteral":
        let v = json_read_value(expr, "value")
        buf.append("{\"$mt_type\":\"IR:StringLiteral\",\"value\":\"")
        buf.append(v)
        buf.append("\",\"type\":{\"$type_ref\":\"Pointer\",\"name\":\"char\"}}")
    else if mt == "AST:NullLiteral":
        buf.append("{\"$mt_type\":\"IR:NullptrLiteral\",\"type\":{\"$type_ref\":\"Pointer\",\"name\":\"void\"}}")
    else if mt == "AST:CharLiteral":
        let v = json_get_str(expr, "value")
        buf.append("{\"$mt_type\":\"IR:CharLiteral\",\"value\":")
        buf.append(v)
        buf.append(",\"type\":{\"$type_ref\":\"Primitive\",\"name\":\"char\"}}")
    else if mt == "AST:IndexAccess":
        buf.append("{\"$mt_type\":\"IR:Index\",\"receiver\":")
        lower_expr_json(buf, json_get_obj(expr, "receiver"))
        buf.append(",\"index\":")
        lower_expr_json(buf, json_get_obj(expr, "index"))
        buf.append(",\"type\":{\"$type_ref\":\"Primitive\",\"name\":\"int\"}}")
    else:
        buf.append("{\"$mt_type\":\"IR:IntegerLiteral\",\"value\":0,\"type\":{\"$type_ref\":\"Primitive\",\"name\":\"int\"}}")

function lower_type_json(buf: ref[string_mod.String], type_obj: str) -> void:
    let name_obj = json_get_obj(type_obj, "name")
    let parts = json_get_obj(name_obj, "parts")
    var tn = "void"
    if parts.len > 0:
        var ppos: ptr_uint = 1
        var part_str = string_mod.String.create()
        var pfirst = true
        while ppos < parts.len:
            if parts.byte_at(ppos) == '"':
                let p = read_quoted(parts, ppos + 1)
                if not pfirst:
                    part_str.push_byte('.')
                pfirst = false
                part_str.append(p)
                ppos = ppos + p.len + 2
            else:
                ppos += 1
        tn = part_str.as_str()
    buf.append("{\"$type_ref\":\"Primitive\",\"name\":\"")
    buf.append(tn)
    buf.append("\"}")

# ── JSON parsing helpers ──────────────────────────────────────────────────

function extract_json_string_value(json: str, key: str) -> string_mod.String:
    var pos: ptr_uint = 0
    while pos + key.len <= json.len:
        var matched = true
        var j: ptr_uint = 0
        while j < key.len:
            if json.byte_at(pos + j) != key.byte_at(j):
                matched = false
                break
            j += 1
        if matched:
            pos += key.len
            while pos < json.len and json.byte_at(pos) != '"':
                pos += 1
            pos += 1
            var result = string_mod.String.create()
            while pos < json.len:
                let ch = json.byte_at(pos)
                if ch == '\\' and pos + 1 < json.len:
                    pos += 1
                    let ch2 = json.byte_at(pos)
                    if ch2 == '"':
                        result.push_byte('"')
                    else if ch2 == 'n':
                        result.push_byte('\n')
                    else if ch2 == 't':
                        result.push_byte('\t')
                    else if ch2 == '\\':
                        result.push_byte('\\')
                    else:
                        result.push_byte(ch2)
                else if ch == '"':
                    return result
                else:
                    result.push_byte(ch)
                pos += 1
            return result
        pos += 1
    var empty = string_mod.String.create()
    return empty

function find_module_name_in(json: str) -> str:
    let key = "\"module_name\":{\"$mt_type\":\"AST:QualifiedName\",\"parts\":[\""
    var pos: ptr_uint = 0
    while pos + key.len <= json.len:
        var matched = true
        var j: ptr_uint = 0
        while j < key.len:
            if json.byte_at(pos + j) != key.byte_at(j):
                matched = false
                break
            j += 1
        if matched:
            pos += key.len
            return read_quoted(json, pos)
        pos += 1
    return ""

function find_func_name_in(json: str) -> str:
    let key = "\"functions\":{\""
    var pos: ptr_uint = 0
    while pos + key.len <= json.len:
        var matched = true
        var j: ptr_uint = 0
        while j < key.len:
            if json.byte_at(pos + j) != key.byte_at(j):
                matched = false
                break
            j += 1
        if matched:
            pos += key.len
            return read_quoted(json, pos)
        pos += 1
    return ""

function json_get_str(obj: str, key: str) -> str:
    var pos: ptr_uint = 1
    while pos < obj.len:
        if obj.byte_at(pos) == '"':
            let k = read_quoted(obj, pos + 1)
            pos = pos + k.len + 2
            while pos < obj.len and obj.byte_at(pos) != ':':
                pos += 1
            if pos < obj.len:
                pos += 1
            while pos < obj.len and (obj.byte_at(pos) == ' ' or obj.byte_at(pos) == '\n'):
                pos += 1
            if k == key:
                if pos < obj.len and obj.byte_at(pos) == '"':
                    return read_quoted(obj, pos + 1)
                return ""
            pos = skip_json_value(obj, pos)
        else:
            pos += 1
    return ""

function json_get_obj(obj: str, key: str) -> str:
    var pos: ptr_uint = 1
    while pos < obj.len:
        if obj.byte_at(pos) == '"':
            let k = read_quoted(obj, pos + 1)
            pos = pos + k.len + 2
            while pos < obj.len and obj.byte_at(pos) != ':':
                pos += 1
            if pos < obj.len:
                pos += 1
            while pos < obj.len and (obj.byte_at(pos) == ' ' or obj.byte_at(pos) == '\n'):
                pos += 1
            if k == key:
                if pos < obj.len and (obj.byte_at(pos) == '{' or obj.byte_at(pos) == '['):
                    return read_balanced(obj, pos)
                return ""
            pos = skip_json_value(obj, pos)
        else:
            pos += 1
    return ""

function skip_json_value(obj: str, pos: ptr_uint) -> ptr_uint:
    var i = pos
    if i < obj.len and obj.byte_at(i) == '"':
        let val = read_quoted(obj, i + 1)
        return i + val.len + 2
    if i < obj.len and (obj.byte_at(i) == '{' or obj.byte_at(i) == '['):
        return i + read_balanced(obj, i).len
    if i < obj.len and obj.byte_at(i) == 't':
        return i + 4
    if i < obj.len and obj.byte_at(i) == 'f':
        return i + 5
    if i < obj.len and obj.byte_at(i) == 'n':
        return i + 4
    while i < obj.len:
        let ch = obj.byte_at(i)
        if not (is_digit(ch) or ch == '-' or ch == '.' or ch == 'e' or ch == 'E' or ch == '+'):
            return i
        i += 1
    return i

function is_digit(ch: ubyte) -> bool:
    return ch >= '0' and ch <= '9'

function json_read_value(obj: str, key: str) -> str:
    var pos: ptr_uint = 1
    while pos < obj.len:
        if obj.byte_at(pos) == '"':
            let k = read_quoted(obj, pos + 1)
            pos = pos + k.len + 2
            while pos < obj.len and obj.byte_at(pos) != ':':
                pos += 1
            if pos < obj.len:
                pos += 1
            while pos < obj.len and (obj.byte_at(pos) == ' ' or obj.byte_at(pos) == '\n'):
                pos += 1
            if k == key:
                if pos < obj.len and obj.byte_at(pos) == '"':
                    return read_quoted(obj, pos + 1)
                let start = pos
                while pos < obj.len:
                    let ch = obj.byte_at(pos)
                    if ch == ',' or ch == '}' or ch == ']' or ch == ' ' or ch == '\n':
                        break
                    pos += 1
                return obj.slice(start, pos - start)
            pos = skip_json_value(obj, pos)
        else:
            pos += 1
    return ""

function read_quoted(json: str, start: ptr_uint) -> str:
    var i = start
    while i < json.len:
        let ch = json.byte_at(i)
        if ch == '\\':
            i += 1
        else if ch == '"':
            break
        i += 1
    return json.slice(start, i - start)

function read_balanced(json: str, start: ptr_uint) -> str:
    var i = start
    let open = json.byte_at(start)
    var close = '}'
    if open == '[':
        close = ']'
    var depth: ptr_uint = 0
    while i < json.len:
        let ch = json.byte_at(i)
        if ch == '"':
            i += 1
            while i < json.len:
                if json.byte_at(i) == '\\':
                    i += 1
                else if json.byte_at(i) == '"':
                    break
                i += 1
        else if ch == open:
            depth += 1
        else if ch == close:
            depth -= 1
            if depth == 0:
                return json.slice(start, i - start + 1)
        i += 1
    return json.slice(start, json.len - start)
