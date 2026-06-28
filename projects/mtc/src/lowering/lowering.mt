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
    buf.append("\",\"params\":[],\"return_type\":{\"$type_ref\":\"Primitive\",\"name\":\"int\"}")

    buf.append(",\"body\":[")
    let func_obj = json_get_obj(analysis, "functions")
    let func_binding = json_get_obj(func_obj, name)
    let ast_json = json_get_obj(func_binding, "ast")
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
        buf.append("{\"$mt_type\":\"IR:PassStmt\",\"line\":null}")
    else:
        buf.append("{\"$mt_type\":\"IR:PassStmt\",\"line\":null}")

function lower_if_json(buf: ref[string_mod.String], stmt: str) -> void:
    buf.append("{\"$mt_type\":\"IR:IfStmt\",\"condition\":")
    lower_expr_json(buf, json_get_obj(stmt, "\"condition\":"))
    buf.append(",\"then_branch\":[")
    let branches = json_get_obj(stmt, "\"branches\":")
    var arm = branch_arm(branches, 0)
    lower_body_json(buf, json_get_obj(arm, "\"body\":"))
    buf.append("]")
    var else_arm = branch_arm(branches, 1)
    if else_arm.len > 0:
        buf.append(",\"else_branch\":[")
        lower_body_json(buf, json_get_obj(else_arm, "\"body\":"))
        buf.append("]")
    buf.append(",\"line\":null,\"source_path\":null}")

function lower_while_json(buf: ref[string_mod.String], stmt: str) -> void:
    buf.append("{\"$mt_type\":\"IR:WhileStmt\",\"condition\":")
    lower_expr_json(buf, json_get_obj(stmt, "\"condition\":"))
    buf.append(",\"body\":[")
    lower_body_json(buf, json_get_obj(stmt, "\"body\":"))
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
    let mt = json_get_str(expr, "\"$mt_type\":")
    if mt == "AST:IntegerLiteral":
        let v = json_get_str(expr, "value")
        buf.append("{\"$mt_type\":\"IR:IntegerLiteral\",\"value\":")
        buf.append(v)
        buf.append(",\"type\":{\"$type_ref\":\"Primitive\",\"name\":\"int\"}}")
    else if mt == "AST:Identifier":
        let nm = json_get_str(expr, "name")
        buf.append("{\"$mt_type\":\"IR:Name\",\"name\":\"")
        buf.append(nm)
        buf.append("\",\"type\":{\"$type_ref\":\"Primitive\",\"name\":\"int\"},\"pointer\":false}")
    else if mt == "AST:BinaryOp":
        let op = json_get_str(expr, "\"operator\":")
        buf.append("{\"$mt_type\":\"IR:Binary\",\"operator\":\"")
        buf.append(op)
        buf.append("\",\"left\":")
        lower_expr_json(buf, json_get_obj(expr, "\"left\":"))
        buf.append(",\"right\":")
        lower_expr_json(buf, json_get_obj(expr, "\"right\":"))
        buf.append(",\"type\":{\"$type_ref\":\"Primitive\",\"name\":\"int\"}}")
    else if mt == "AST:UnaryOp":
        let op = json_get_str(expr, "\"operator\":")
        buf.append("{\"$mt_type\":\"IR:Unary\",\"operator\":\"")
        buf.append(op)
        buf.append("\",\"operand\":")
        lower_expr_json(buf, json_get_obj(expr, "\"operand\":"))
        buf.append(",\"type\":{\"$type_ref\":\"Primitive\",\"name\":\"int\"}}")
    else if mt == "AST:FloatLiteral":
        let v = json_get_str(expr, "value")
        buf.append("{\"$mt_type\":\"IR:FloatLiteral\",\"value\":")
        buf.append(v)
        buf.append(",\"type\":{\"$type_ref\":\"Primitive\",\"name\":\"float\"}}")
    else if mt == "AST:BooleanLiteral":
        let v = json_get_str(expr, "value")
        buf.append("{\"$mt_type\":\"IR:BooleanLiteral\",\"value\":")
        buf.append(v)
        buf.append(",\"type\":{\"$type_ref\":\"Primitive\",\"name\":\"bool\"}}")
    else:
        buf.append("{\"$mt_type\":\"IR:IntegerLiteral\",\"value\":0,\"type\":{\"$type_ref\":\"Primitive\",\"name\":\"int\"}}")

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
            if pos < obj.len and obj.byte_at(pos) == '"':
                pos = pos + read_quoted(obj, pos + 1).len + 2
            else if pos < obj.len and (obj.byte_at(pos) == '{' or obj.byte_at(pos) == '['):
                let nobj = read_balanced(obj, pos)
                pos = pos + nobj.len
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
            if pos < obj.len and obj.byte_at(pos) == '"':
                pos = pos + read_quoted(obj, pos + 1).len + 2
            else if pos < obj.len and (obj.byte_at(pos) == '{' or obj.byte_at(pos) == '['):
                let nobj = read_balanced(obj, pos)
                pos = pos + nobj.len
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
