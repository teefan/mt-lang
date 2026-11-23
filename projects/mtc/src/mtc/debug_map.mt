## Debug map — the host-compatible `<binary>.mtdbg.json` sidecar written next to
## every successful build.  The DAP lldb-dap bridge reads it to rename C frames
## and variables back to Milk Tea names and to rewrite `evaluate` expressions.
## Mirrors `lib/milk_tea/tooling/debug_map.rb`: version 1, per function
## `{name, cName, params, locals, sourcePath?, line?}`, top-level `binaryPath`
## and `programSourcePath`, with paths stored relative to the sidecar's
## directory (the host's `path_for_payload` rule).

import std.fmt as fmt
import std.fs as fs
import std.json as json
import std.path as path_ops
import std.str
import std.string as string
import std.vec as vec

import mtc.ir as ir


const VERSION: int = 1


## One source entry (parameter or local): the Milk Tea name, the generated C
## name, and the declaration line when the IR records one.
public struct DebugEntry:
    name: string.String
    linkage_name: string.String
    line: ptr_uint
    has_line: bool


## One lowered function with its parameters and locals.
public struct DebugFunction:
    name: string.String
    linkage_name: string.String
    path: string.String
    line: ptr_uint
    has_line: bool
    params: vec.Vec[DebugEntry]
    locals: vec.Vec[DebugEntry]


## A generated or loaded debug map.
public struct DebugMap:
    functions: vec.Vec[DebugFunction]
    binary_path: string.String
    program_source_path: string.String


## Release one entry's owned strings.
public function release_entry(entry: ref[DebugEntry]) -> void:
    entry.name.release()
    entry.linkage_name.release()


## Release a vector of entries and every entry it owns.
function release_entries(entries: ref[vec.Vec[DebugEntry]]) -> void:
    var i: ptr_uint = 0
    while i < entries.len():
        unsafe:
            let entry = entries.get(i)
            if entry != null:
                release_entry(read(entry))
        i += 1
    entries.release()


## Release one function and everything it owns.
public function release_function(entry_function: ref[DebugFunction]) -> void:
    entry_function.name.release()
    entry_function.linkage_name.release()
    entry_function.path.release()
    release_entries(ref_of(entry_function.params))
    release_entries(ref_of(entry_function.locals))


## Release a map and everything it owns.
public function release(map: ref[DebugMap]) -> void:
    var i: ptr_uint = 0
    while i < map.functions.len():
        unsafe:
            let entry_fn = map.functions.get(i)
            if entry_fn != null:
                release_function(read(entry_fn))
        i += 1
    map.functions.release()
    map.binary_path.release()
    map.program_source_path.release()


## `<binary>.mtdbg.json` — the sidecar sits next to the binary (host
## `DebugMap.sidecar_path_for`).
public function sidecar_path_for(binary_path: str) -> string.String:
    var result = string.String.from_str(binary_path)
    result.append(".mtdbg.json")
    return result


## Look up a function by its generated C name.
public function function_for_c_name(map: ref[DebugMap], c_name: str) -> ptr[DebugFunction]?:
    var i: ptr_uint = 0
    while i < map.functions.len():
        unsafe:
            let entry_fn = map.functions.get(i)
            if entry_fn != null and read(entry_fn).linkage_name.as_str().equal(c_name):
                return entry_fn
        i += 1
    return null


## Look up a parameter or local by its generated C name.
public function variable_for(map: ref[DebugMap], function_c_name: str, c_name: str) -> ptr[DebugEntry]?:
    let entry_fn = function_for_c_name(map, function_c_name)
    if entry_fn == null:
        return null
    unsafe:
        var i: ptr_uint = 0
        while i < read(entry_fn).params.len():
            let entry = read(entry_fn).params.get(i)
            if entry != null and read(entry).linkage_name.as_str().equal(c_name):
                return entry
            i += 1
        i = 0
        while i < read(entry_fn).locals.len():
            let entry = read(entry_fn).locals.get(i)
            if entry != null and read(entry).linkage_name.as_str().equal(c_name):
                return entry
            i += 1
    return null


## Look up an entry by its Milk Tea name.  Returns nil when the name is not
## declared, or when several entries share it with different C names (the
## host's ambiguity rule).
public function source_variable_for(map: ref[DebugMap], function_c_name: str, source_name: str) -> ptr[DebugEntry]?:
    let entry_fn = function_for_c_name(map, function_c_name)
    if entry_fn == null:
        return null

    var first_match: ptr[DebugEntry]? = null
    var ambiguous = false
    unsafe:
        var i: ptr_uint = 0
        while i < read(entry_fn).params.len():
            let entry = read(entry_fn).params.get(i)
            if entry != null and read(entry).name.as_str().equal(source_name):
                if first_match == null:
                    first_match = entry
                else if not read(first_match).linkage_name.as_str().equal(read(entry).linkage_name.as_str()):
                    ambiguous = true
            i += 1
        i = 0
        while i < read(entry_fn).locals.len():
            let entry = read(entry_fn).locals.get(i)
            if entry != null and read(entry).name.as_str().equal(source_name):
                if first_match == null:
                    first_match = entry
                else if not read(first_match).linkage_name.as_str().equal(read(entry).linkage_name.as_str()):
                    ambiguous = true
            i += 1

    if ambiguous:
        return null
    return first_match


## Build a map from the lowered IR.  A function's source path is its first
## located statement's path, falling back to the program path; its line is the
## first located statement's line (host `DebugMap.from_ir`).
public function from_ir(program: ref[ir.Program], binary_path: str) -> DebugMap:
    var cwd = current_directory_string()
    defer: cwd.release()

    var binary_abs = absolute_path(binary_path, cwd.as_str())
    defer: binary_abs.release()
    var program_abs = absolute_path(program.source_path, cwd.as_str())
    defer: program_abs.release()

    var functions = vec.Vec[DebugFunction].create()
    var index: ptr_uint = 0
    while index < program.functions.len:
        unsafe:
            let entry_fn = read(program.functions.data + index)
            functions.push(function_from_ir(entry_fn, program_abs.as_str(), cwd.as_str()))
        index += 1

    return DebugMap(
        functions = functions,
        binary_path = string.String.from_str(binary_abs.as_str()),
        program_source_path = string.String.from_str(program_abs.as_str()),
    )


## One function's map entry.
function function_from_ir(entry_fn: ir.Function, program_path: str, cwd: str) -> DebugFunction:
    var source_path = string.String.create()
    match first_statement_path(entry_fn.body):
        Option.some as found:
            var resolved = absolute_path(found.value, cwd)
            source_path.assign(resolved.as_str())
            resolved.release()
        Option.none:
            source_path.assign(program_path)

    var line: ptr_uint = 0
    var has_line = false
    match first_statement_line(entry_fn.body):
        Option.some as found:
            line = found.value
            has_line = true
        Option.none:
            pass

    var params = vec.Vec[DebugEntry].create()
    var pi: ptr_uint = 0
    while pi < entry_fn.params.len:
        unsafe:
            let param = read(entry_fn.params.data + pi)
            params.push(DebugEntry(
                name = string.String.from_str(param.name),
                linkage_name = string.String.from_str(param.linkage_name),
                line = 0,
                has_line = false,
            ))
        pi += 1

    var locals = vec.Vec[DebugEntry].create()
    collect_locals(entry_fn.body, ref_of(locals))

    return DebugFunction(
        name = string.String.from_str(entry_fn.name),
        linkage_name = string.String.from_str(entry_fn.linkage_name),
        path = source_path,
        line = line,
        has_line = has_line,
        params = params,
        locals = locals,
    )


## Collect every `stmt_local` reachable from `statements`, recursing like the
## host's `collect_locals` (block/while bodies, for init/body/post, if
## then/else, switch case bodies).
function collect_locals(statements: span[ir.Stmt], locals: ref[vec.Vec[DebugEntry]]) -> void:
    var i: ptr_uint = 0
    while i < statements.len:
        unsafe:
            let statement = read(statements.data + i)
            match statement:
                ir.Stmt.stmt_local as local:
                    locals.push(DebugEntry(
                        name = string.String.from_str(local.name),
                        linkage_name = string.String.from_str(local.linkage_name),
                        line = local.line,
                        has_line = true,
                    ))
                ir.Stmt.stmt_block as block:
                    collect_locals(block.body, locals)
                ir.Stmt.stmt_while as while_stmt:
                    collect_locals(while_stmt.body, locals)
                ir.Stmt.stmt_for as for_stmt:
                    collect_local_statement(read(for_stmt.init), locals)
                    collect_locals(for_stmt.body, locals)
                    collect_local_statement(read(for_stmt.post), locals)
                ir.Stmt.stmt_if as if_stmt:
                    collect_locals(if_stmt.then_body, locals)
                    match if_stmt.else_body:
                        Option.some as else_body:
                            collect_locals(else_body.value, locals)
                        Option.none:
                            pass
                ir.Stmt.stmt_switch as switch_stmt:
                    var ci: ptr_uint = 0
                    while ci < switch_stmt.cases.len:
                        let switch_case = read(switch_stmt.cases.data + ci)
                        collect_locals(switch_case.body, locals)
                        ci += 1
                _:
                    pass
        i += 1


## `collect_locals` for a single nested statement (for-init / for-post).
function collect_local_statement(statement: ir.Stmt, locals: ref[vec.Vec[DebugEntry]]) -> void:
    match statement:
        ir.Stmt.stmt_local as local:
            locals.push(DebugEntry(
                name = string.String.from_str(local.name),
                linkage_name = string.String.from_str(local.linkage_name),
                line = local.line,
                has_line = true,
            ))
        _:
            pass


## The first source path among `statements`, depth-first in the host's nested
## order (LocalDecl/ReturnStmt/ExpressionStmt carry the path).
function first_statement_path(statements: span[ir.Stmt]) -> Option[str]:
    var i: ptr_uint = 0
    while i < statements.len:
        unsafe:
            let statement = read(statements.data + i)
            match first_path_in_statement(statement):
                Option.some as found:
                    return Option[str].some(value = found.value)
                Option.none:
                    pass
        i += 1
    return Option[str].none


function first_path_in_statement(statement: ir.Stmt) -> Option[str]:
    match statement:
        ir.Stmt.stmt_local as local:
            if local.source_path.len > 0:
                return Option[str].some(value = local.source_path)
            return Option[str].none
        ir.Stmt.stmt_return as return_stmt:
            if return_stmt.source_path.len > 0:
                return Option[str].some(value = return_stmt.source_path)
            return Option[str].none
        ir.Stmt.stmt_expression as expression_stmt:
            if expression_stmt.source_path.len > 0:
                return Option[str].some(value = expression_stmt.source_path)
            return Option[str].none
        ir.Stmt.stmt_block as block:
            return first_statement_path(block.body)
        ir.Stmt.stmt_while as while_stmt:
            return first_statement_path(while_stmt.body)
        ir.Stmt.stmt_for as for_stmt:
            match first_path_in_statement(unsafe: read(for_stmt.init)):
                Option.some as found:
                    return Option[str].some(value = found.value)
                Option.none:
                    pass
            match first_statement_path(for_stmt.body):
                Option.some as found:
                    return Option[str].some(value = found.value)
                Option.none:
                    pass
            return first_path_in_statement(unsafe: read(for_stmt.post))
        ir.Stmt.stmt_if as if_stmt:
            match first_statement_path(if_stmt.then_body):
                Option.some as found:
                    return Option[str].some(value = found.value)
                Option.none:
                    pass
            match if_stmt.else_body:
                Option.some as else_body:
                    return first_statement_path(else_body.value)
                Option.none:
                    return Option[str].none
        ir.Stmt.stmt_switch as switch_stmt:
            var i: ptr_uint = 0
            while i < switch_stmt.cases.len:
                unsafe:
                    let switch_case = read(switch_stmt.cases.data + i)
                    match first_statement_path(switch_case.body):
                        Option.some as found:
                            return Option[str].some(value = found.value)
                        Option.none:
                            pass
                i += 1
            return Option[str].none
        _:
            return Option[str].none


## The first source line among `statements`, same traversal as
## `first_statement_path`.
function first_statement_line(statements: span[ir.Stmt]) -> Option[ptr_uint]:
    var i: ptr_uint = 0
    while i < statements.len:
        unsafe:
            let statement = read(statements.data + i)
            match first_line_in_statement(statement):
                Option.some as found:
                    return Option[ptr_uint].some(value = found.value)
                Option.none:
                    pass
        i += 1
    return Option[ptr_uint].none


function first_line_in_statement(statement: ir.Stmt) -> Option[ptr_uint]:
    match statement:
        ir.Stmt.stmt_local as local:
            if local.line > 0:
                return Option[ptr_uint].some(value = local.line)
            return Option[ptr_uint].none
        ir.Stmt.stmt_return as return_stmt:
            if return_stmt.line > 0:
                return Option[ptr_uint].some(value = return_stmt.line)
            return Option[ptr_uint].none
        ir.Stmt.stmt_expression as expression_stmt:
            if expression_stmt.line > 0:
                return Option[ptr_uint].some(value = expression_stmt.line)
            return Option[ptr_uint].none
        ir.Stmt.stmt_block as block:
            return first_statement_line(block.body)
        ir.Stmt.stmt_while as while_stmt:
            return first_statement_line(while_stmt.body)
        ir.Stmt.stmt_for as for_stmt:
            match first_line_in_statement(unsafe: read(for_stmt.init)):
                Option.some as found:
                    return Option[ptr_uint].some(value = found.value)
                Option.none:
                    pass
            match first_statement_line(for_stmt.body):
                Option.some as found:
                    return Option[ptr_uint].some(value = found.value)
                Option.none:
                    pass
            return first_line_in_statement(unsafe: read(for_stmt.post))
        ir.Stmt.stmt_if as if_stmt:
            match first_statement_line(if_stmt.then_body):
                Option.some as found:
                    return Option[ptr_uint].some(value = found.value)
                Option.none:
                    pass
            match if_stmt.else_body:
                Option.some as else_body:
                    return first_statement_line(else_body.value)
                Option.none:
                    return Option[ptr_uint].none
        ir.Stmt.stmt_switch as switch_stmt:
            var i: ptr_uint = 0
            while i < switch_stmt.cases.len:
                unsafe:
                    let switch_case = read(switch_stmt.cases.data + i)
                    match first_statement_line(switch_case.body):
                        Option.some as found:
                            return Option[ptr_uint].some(value = found.value)
                        Option.none:
                            pass
                i += 1
            return Option[ptr_uint].none
        _:
            return Option[ptr_uint].none


## Write the sidecar (host `DebugMap#write`: create the parent directory, then
## the pretty-ish payload plus a trailing newline).
public function write(map: ref[DebugMap], sidecar_path: str) -> Result[bool, string.String]:
    var cwd = current_directory_string()
    defer: cwd.release()
    var base_dir = absolute_path(path_ops.dirname(sidecar_path), cwd.as_str())
    defer: base_dir.release()

    match fs.create_directories(base_dir.as_str()):
        Result.failure as failure:
            var error = failure.error
            var message = string.String.from_str(error.message.as_str())
            error.release()
            return Result[bool, string.String].failure(error = message)
        Result.success:
            pass

    var payload = to_json(map, base_dir.as_str())
    defer: payload.release()

    match fs.write_text(sidecar_path, payload.as_str()):
        Result.success:
            return Result[bool, string.String].success(value = true)
        Result.failure as failure:
            var error = failure.error
            var message = string.String.from_str(error.message.as_str())
            error.release()
            return Result[bool, string.String].failure(error = message)


## Serialize the map.  `base_dir` is the sidecar's directory; paths that cannot
## be made relative stay absolute (the host's fallback).
public function to_json(map: ref[DebugMap], base_dir: str) -> string.String:
    var output = string.String.with_capacity(1024)
    output.append("{\"version\":")
    fmt.append_int(ref_of(output), VERSION)
    output.append(",\"functions\":[")
    var i: ptr_uint = 0
    while i < map.functions.len():
        if i > 0:
            output.append(",")
        unsafe:
            let entry_fn = map.functions.get(i)
            if entry_fn != null:
                append_function_json(ref_of(output), read(entry_fn), base_dir)
        i += 1
    output.append("]")

    var binary_path = payload_path(map.binary_path.as_str(), base_dir)
    if not binary_path.is_empty():
        output.append(",\"binaryPath\":")
        append_json_string(ref_of(output), binary_path.as_str())
    binary_path.release()

    var program_path = payload_path(map.program_source_path.as_str(), base_dir)
    if not program_path.is_empty():
        output.append(",\"programSourcePath\":")
        append_json_string(ref_of(output), program_path.as_str())
    program_path.release()

    output.append("}\n")
    return output


function append_function_json(output: ref[string.String], entry_fn: DebugFunction, base_dir: str) -> void:
    output.append("{\"name\":")
    append_json_string(output, entry_fn.name.as_str())
    output.append(",\"cName\":")
    append_json_string(output, entry_fn.linkage_name.as_str())
    output.append(",\"params\":")
    append_entries_json(output, entry_fn.params.as_span())
    output.append(",\"locals\":")
    append_entries_json(output, entry_fn.locals.as_span())

    var source_path = payload_path(entry_fn.path.as_str(), base_dir)
    if not source_path.is_empty():
        output.append(",\"sourcePath\":")
        append_json_string(output, source_path.as_str())
    source_path.release()

    if entry_fn.has_line:
        output.append(",\"line\":")
        fmt.append_ptr_uint(output, entry_fn.line)
    output.append("}")


function append_entries_json(output: ref[string.String], entries: span[DebugEntry]) -> void:
    output.append("[")
    var i: ptr_uint = 0
    while i < entries.len:
        if i > 0:
            output.append(",")
        unsafe:
            let entry = read(entries.data + i)
            output.append("{\"name\":")
            append_json_string(output, entry.name.as_str())
            output.append(",\"cName\":")
            append_json_string(output, entry.linkage_name.as_str())
            if entry.has_line:
                output.append(",\"line\":")
                fmt.append_ptr_uint(output, entry.line)
            output.append("}")
        i += 1
    output.append("]")


## JSON-escape and append one string value (the DAP transport's escaping rules).
function append_json_string(output: ref[string.String], text: str) -> void:
    output.push_byte('"')
    var i: ptr_uint = 0
    while i < text.len:
        let b = text.byte_at(i)
        if b == '"':
            output.append("\\\"")
        else if b == '\\':
            output.append("\\\\")
        else if b == '\n':
            output.append("\\n")
        else if b == '\r':
            output.append("\\r")
        else if b == '\t':
            output.append("\\t")
        else:
            output.push_byte(b)
        i += 1
    output.push_byte('"')


## Host `path_for_payload`: relative to the sidecar's directory when possible,
## the normalized absolute path otherwise; empty means "absent".
function payload_path(target: str, base_dir: str) -> string.String:
    if target.len == 0:
        return string.String.create()
    match path_ops.relative_path(target, base_dir):
        Option.some as relative:
            return relative.value
        Option.none:
            return path_ops.normalize_separators(target)


## Load a sidecar.  Returns none when the file is unreadable or malformed (the
## host's `load_for_binary` tolerance, extended to missing fields).
public function load(sidecar_path: str) -> Option[DebugMap]:
    var cwd = current_directory_string()
    defer: cwd.release()
    var base_dir = absolute_path(path_ops.dirname(sidecar_path), cwd.as_str())
    defer: base_dir.release()

    var text = string.String.create()
    defer: text.release()
    match fs.read_text(sidecar_path):
        Result.success as loaded:
            text.assign(loaded.value.as_str())
            loaded.value.release()
        Result.failure as failure:
            var error = failure.error
            error.release()
            return Option[DebugMap].none

    match json.parse(text.as_str()):
        Result.success as parsed:
            defer: json.release_value(parsed.value)
            return map_from_value(parsed.value, base_dir.as_str())
        Result.failure as failure:
            var error = failure.error
            error.release()
            return Option[DebugMap].none


## Load the sidecar for a binary, or none when it does not exist.
public function load_for_binary(binary_path: str) -> Option[DebugMap]:
    var sidecar = sidecar_path_for(binary_path)
    defer: sidecar.release()
    if not fs.is_file(sidecar.as_str()):
        return Option[DebugMap].none
    return load(sidecar.as_str())


function map_from_value(value: json.Value, base_dir: str) -> Option[DebugMap]:
    let object_ptr = value.as_object()
    if object_ptr == null:
        return Option[DebugMap].none

    var functions = vec.Vec[DebugFunction].create()
    var binary_path = string.String.create()
    var program_path = string.String.create()

    unsafe:
        let functions_array = read(object_ptr).get_array("functions")
        if functions_array != null:
            var i: ptr_uint = 0
            while i < read(functions_array).len():
                let item_ptr = read(functions_array).get(i)
                if item_ptr != null:
                    match function_from_value(read(item_ptr), base_dir):
                        Option.some as loaded_function:
                            functions.push(loaded_function.value)
                        Option.none:
                            pass
                i += 1

        let binary_text = read(object_ptr).get_string("binaryPath")
        match binary_text:
            Option.some as found:
                var resolved = resolve_loaded_path(found.value, base_dir)
                binary_path.assign(resolved.as_str())
                resolved.release()
            Option.none:
                pass

        let program_text = read(object_ptr).get_string("programSourcePath")
        match program_text:
            Option.some as found:
                var resolved = resolve_loaded_path(found.value, base_dir)
                program_path.assign(resolved.as_str())
                resolved.release()
            Option.none:
                pass

    return Option[DebugMap].some(value = DebugMap(
        functions = functions,
        binary_path = binary_path,
        program_source_path = program_path,
    ))


function function_from_value(value: json.Value, base_dir: str) -> Option[DebugFunction]:
    let object_ptr = value.as_object()
    if object_ptr == null:
        return Option[DebugFunction].none

    var name_opt = Option[str].none
    var linkage_opt = Option[str].none
    unsafe:
        name_opt = read(object_ptr).get_string("name")
        linkage_opt = read(object_ptr).get_string("cName")
    if name_opt.is_none() or linkage_opt.is_none():
        return Option[DebugFunction].none

    var name = string.String.create()
    match name_opt:
        Option.some as found:
            name.assign(found.value)
        Option.none:
            pass

    var linkage_name = string.String.create()
    match linkage_opt:
        Option.some as found:
            linkage_name.assign(found.value)
        Option.none:
            pass

    var path_text = string.String.create()
    unsafe:
        let source_text = read(object_ptr).get_string("sourcePath")
        match source_text:
            Option.some as found:
                if found.value.len > 0:
                    var resolved = resolve_loaded_path(found.value, base_dir)
                    path_text.assign(resolved.as_str())
                    resolved.release()
            Option.none:
                pass

    var line: ptr_uint = 0
    var has_line = false
    unsafe:
        let line_number = read(object_ptr).get_number("line")
        match line_number:
            Option.some as found:
                line = ptr_uint<-int<-found.value
                has_line = true
            Option.none:
                pass

    var params = vec.Vec[DebugEntry].create()
    var locals = vec.Vec[DebugEntry].create()
    unsafe:
        load_entries_into(read(object_ptr).get_array("params"), ref_of(params))
        load_entries_into(read(object_ptr).get_array("locals"), ref_of(locals))

    return Option[DebugFunction].some(value = DebugFunction(
        name = name,
        linkage_name = linkage_name,
        path = path_text,
        line = line,
        has_line = has_line,
        params = params,
        locals = locals,
    ))


function load_entries_into(array_ptr: ptr[json.Array]?, target_entries: ref[vec.Vec[DebugEntry]]) -> void:
    if array_ptr == null:
        return
    unsafe:
        var i: ptr_uint = 0
        while i < read(array_ptr).len():
            let item_ptr = read(array_ptr).get(i)
            if item_ptr != null:
                match entry_from_value(read(item_ptr)):
                    Option.some as entry:
                        target_entries.push(entry.value)
                    Option.none:
                        pass
            i += 1


function entry_from_value(value: json.Value) -> Option[DebugEntry]:
    let object_ptr = value.as_object()
    if object_ptr == null:
        return Option[DebugEntry].none

    var name_opt = Option[str].none
    var linkage_opt = Option[str].none
    unsafe:
        name_opt = read(object_ptr).get_string("name")
        linkage_opt = read(object_ptr).get_string("cName")
    if name_opt.is_none() or linkage_opt.is_none():
        return Option[DebugEntry].none

    var name = string.String.create()
    match name_opt:
        Option.some as found:
            name.assign(found.value)
        Option.none:
            pass

    var linkage_name = string.String.create()
    match linkage_opt:
        Option.some as found:
            linkage_name.assign(found.value)
        Option.none:
            pass

    var line: ptr_uint = 0
    var has_line = false
    unsafe:
        let line_number = read(object_ptr).get_number("line")
        match line_number:
            Option.some as found:
                line = ptr_uint<-int<-found.value
                has_line = true
            Option.none:
                pass

    return Option[DebugEntry].some(value = DebugEntry(
        name = name,
        linkage_name = linkage_name,
        line = line,
        has_line = has_line,
    ))


## Host `path_from_payload`: absolute stays, empty stays, otherwise relative to
## the sidecar's directory.
function resolve_loaded_path(path_text: str, base_dir: str) -> string.String:
    if path_text.len == 0:
        return string.String.create()
    if path_ops.is_absolute(path_text):
        return path_ops.normalize_separators(path_text)
    return path_ops.join(base_dir, path_text)


## The process working directory as an owned string; "." when unavailable.
function current_directory_string() -> string.String:
    var result = string.String.create()
    match fs.current_directory():
        Result.success as current:
            result.assign(current.value.as_str())
            current.value.release()
        Result.failure as failure:
            var error = failure.error
            error.release()
            result.assign(".")
    return result


## Syntactic absolute path (the host's `File.expand_path`): absolute paths are
## normalized, relative ones joined onto the working directory.
function absolute_path(path_text: str, cwd: str) -> string.String:
    if path_text.len == 0:
        return string.String.create()
    if path_ops.is_absolute(path_text):
        return path_ops.normalize_separators(path_text)
    return path_ops.join(cwd, path_text)
