## Raw-binding options JSON — load the host's `--options-json` metadata table
## into the bindgen options, and its typed JSON field helpers.  Extracted from
## bindgen.mt.

import std.string as string
import std.vec as vec
import std.map as map_mod
import std.json as json
import std.fs as fs
import std.mem.heap as heap

import mtc.bindgen as bindgen


## Load the raw-binding option table into `opts`.  The returned root owns every
## string the table populated (they are `str` views into it); the caller must
## keep it alive until generation finishes and then release it with
## `release_options_json`.

public function load_options_json(path: str, opts: ref[bindgen.BindgenOptions]) -> Result[ptr[json.Value], string.String]:
    var content: string.String
    match fs.read_text(path):
        Result.success as read_ok:
            content = read_ok.value
        Result.failure as read_err:
            var message = string.String.from_str("bindgen: cannot read options file ")
            message.append(path)
            read_err.error.release()
            return Result[ptr[json.Value], string.String].failure(error = message)
    defer: content.release()

    match json.parse(content.as_str()):
        Result.success as parsed:
            let root_ptr = heap.must_alloc[json.Value](1)
            unsafe: read(root_ptr) = parsed.value
            let obj = unsafe: read(root_ptr).as_object() else:
                json.release_value(unsafe: read(root_ptr))
                heap.release(root_ptr)
                return Result[
                    ptr[json.Value],
                    string.String
                ].failure(error = string.String.from_str("bindgen: options file is not a JSON object"))
            unsafe:
                let clang_name = json_string(obj, "clang")
                if clang_name != "":
                    read(opts).clang_bin = clang_name
                read(opts).clang_args = json_string_array(obj, "clang_args")
                read(opts).include_headers = json_string_array(obj, "include_directives")
                read(opts).link_libs = json_string_array(obj, "link_libraries")
                read(opts).bindgen_defines = json_string_array(obj, "bindgen_defines")
                read(opts).bindgen_include_directives = json_string_array(obj, "bindgen_include_directives")
                read(opts).module_imports = json_module_imports(obj)
                read(opts).tracked_header_paths = json_string_array(obj, "tracked_header_paths")
                read(opts).tracked_header_prefixes = json_string_array(obj, "tracked_header_prefixes")
                read(opts).declaration_name_prefixes = json_string_array(obj, "declaration_name_prefixes")
                read(opts).excluded_declaration_names = json_string_array(obj, "excluded_declaration_names")
                read(opts).type_name_overrides = json_string_map(obj, "type_name_overrides")
                read(opts).type_overrides = json_string_map(obj, "type_overrides")
                read(opts).function_param_type_overrides = json_nested_string_map(obj, "function_param_type_overrides")
                read(opts).function_return_type_overrides = json_string_map(obj, "function_return_type_overrides")
                read(opts).field_type_overrides = json_nested_string_map(obj, "field_type_overrides")
                read(opts).allow_static_inline_functions = json_bool(obj, "allow_static_inline_functions")
                read(opts).strip_leading_underscores = json_bool(obj, "strip_leading_underscores")
            return Result[ptr[json.Value], string.String].success(value = root_ptr)
        Result.failure as parse_err:
            var message = string.String.from_str("bindgen: invalid options JSON: ")
            message.append(parse_err.error.message.as_str())
            parse_err.error.message.release()
            return Result[ptr[json.Value], string.String].failure(error = message)


public function release_options_json(root: ptr[json.Value]) -> void:
    json.release_value(unsafe: read(root))
    heap.release(root)


function json_string(obj: ptr[json.Object], key: str) -> str:
    match unsafe: read(obj).get_string(key):
        Option.some as value:
            return value.value
        Option.none:
            return ""


function json_string_array(obj: ptr[json.Object], key: str) -> vec.Vec[str]:
    var values = vec.Vec[str].create()
    let arr = unsafe: read(obj).get_array(key) else:
        return values
    unsafe:
        var i: ptr_uint = 0
        while i < read(arr).len():
            match read(arr).get_string(i):
                Option.some as value:
                    values.push(value.value)
                Option.none:
                    pass
            i += 1
    return values


function json_string_map(obj: ptr[json.Object], key: str) -> map_mod.Map[str, str]:
    var result = map_mod.Map[str, str].create()
    let mo = unsafe: read(obj).get_object(key) else:
        return result
    unsafe:
        var entries = read(mo).entries
        var i: ptr_uint = 0
        while i < entries.len():
            let ep = entries.get(i) else:
                break
            let entry = read(ep)
            let value = entry.value.as_string() else:
                i += 1
                continue
            result.set(entry.key.as_str(), value)
            i += 1
    return result


function json_nested_string_map(obj: ptr[json.Object], key: str) -> map_mod.Map[str, map_mod.Map[str, str]]:
    var result = map_mod.Map[str, map_mod.Map[str, str]].create()
    let mo = unsafe: read(obj).get_object(key) else:
        return result
    unsafe:
        var entries = read(mo).entries
        var i: ptr_uint = 0
        while i < entries.len():
            let ep = entries.get(i) else:
                break
            let entry = read(ep)
            let inner = entry.value.as_object() else:
                i += 1
                continue
            var inner_map = map_mod.Map[str, str].create()
            var inner_entries = read(inner).entries
            var j: ptr_uint = 0
            while j < inner_entries.len():
                let iep = inner_entries.get(j) else:
                    break
                let inner_entry = read(iep)
                match inner_entry.value.as_string():
                    Option.some as value:
                        inner_map.set(inner_entry.key.as_str(), value.value)
                    Option.none:
                        pass
                j += 1
            result.set(entry.key.as_str(), inner_map)
            i += 1
    return result


public function jget_bool(obj: ptr[json.Object], key: str) -> bool:
    unsafe:
        match read(obj).get_boolean(key):
            Option.some as value:
                return value.value
            Option.none:
                return false


function json_bool(obj: ptr[json.Object], key: str) -> bool:
    match unsafe: read(obj).get_boolean(key):
        Option.some as value:
            return value.value
        Option.none:
            return false


function json_module_imports(obj: ptr[json.Object]) -> vec.Vec[bindgen.ModuleImport]:
    var result = vec.Vec[bindgen.ModuleImport].create()
    let arr = unsafe: read(obj).get_array("module_imports") else:
        return result
    unsafe:
        var i: ptr_uint = 0
        while i < read(arr).len():
            let io = read(arr).get_object(i) else:
                i += 1
                continue
            var module_name = ""
            var alias = ""
            match read(io).get_string("module_name"):
                Option.some as value:
                    module_name = value.value
                Option.none:
                    pass
            match read(io).get_string("alias"):
                Option.some as value:
                    alias = value.value
                Option.none:
                    pass
            if module_name != "":
                result.push(bindgen.ModuleImport(module_name = module_name, alias = alias))
            i += 1
    return result
