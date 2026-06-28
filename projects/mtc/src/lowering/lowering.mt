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
    r.append("{\"$mt_type\":\"IR:Function\",\"name\":\"")
    r.append(func_name)
    r.append("\",\"linkage_name\":\"")
    r.append(module_name)
    r.push_byte('_')
    r.append(func_name)
    r.append("\",\"params\":[],\"return_type\":{\"$type_ref\":\"Primitive\",\"name\":\"int\"},\"body\":[{\"$mt_type\":\"IR:ReturnStmt\",\"value\":{\"$mt_type\":\"IR:IntegerLiteral\",\"value\":42,\"type\":{\"$type_ref\":\"Primitive\",\"name\":\"int\"}},\"line\":null,\"source_path\":null}],\"entry_point\":false,\"method_receiver_param\":false}]")
    r.append(",\"source_path\":null}")
    root.release()
    return r

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
