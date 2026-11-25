## `package.toml` dependency edits — the self-host port of
## `lib/milk_tea/packages/manifest_editor.rb`.  The manifest is validated as
## TOML, dependencies are re-rendered from their parsed values, and only the
## `[dependencies]` section is replaced textually so the rest of the file keeps
## its comments and formatting.

import std.fs as fs
import std.path as path_ops
import std.str
import std.string as string
import std.toml as toml
import std.vec as vec

import mtc.packages.manifest as manifest


public function add_dependency(path: str, name: str, rendered_spec: str) -> Result[string.String, string.String]:
    return edit_dependency(path, name, rendered_spec, false)


public function remove_dependency(path: str, name: str) -> Result[string.String, string.String]:
    return edit_dependency(path, name, "", true)


function edit_dependency(
    path: str,
    name: str,
    rendered_spec: str,
    remove: bool,
) -> Result[string.String, string.String]:
    var loaded: manifest.PackageManifest
    match manifest.load(path):
        Result.failure as manifest_failure:
            return Result[string.String, string.String].failure(error = manifest_failure.error)
        Result.success as manifest_payload:
            loaded = manifest_payload.value
    defer: loaded.release()
    let manifest_path = loaded.manifest_path.as_str()

    var source: string.String
    match fs.read_text(manifest_path):
        Result.failure as read_failure:
            var read_error = read_failure.error
            var message = string.String.from_str("failed to update ")
            message.append(manifest_path)
            message.append(": ")
            message.append(read_error.message.as_str())
            read_error.release()
            return Result[string.String, string.String].failure(error = message)
        Result.success as read_payload:
            source = read_payload.value
    defer: source.release()

    var document: toml.Document
    match toml.parse(source.as_str()):
        Result.failure as parse_failure:
            var parse_error = parse_failure.error
            var message = string.String.from_str("invalid package.toml at ")
            message.append(manifest_path)
            message.append(": ")
            message.append(parse_error.message.as_str())
            parse_error.release()
            return Result[string.String, string.String].failure(error = message)
        Result.success as parse_payload:
            document = parse_payload.value
    defer: document.release()

    var entries = vec.Vec[DependencyLine].create()
    defer: release_dependency_lines(ref_of(entries))
    match collect_dependency_lines(ref_of(document), manifest_path, ref_of(entries)):
        Result.failure as collect_failure:
            return Result[string.String, string.String].failure(error = collect_failure.error)
        Result.success:
            pass

    var found = -1
    var i: ptr_uint = 0
    while i < entries.len():
        let entry = entries.get(i) else:
            break
        if unsafe: read(entry).name.as_str().equal(name):
            found = int<-i
            break
        i += 1

    if remove:
        if found < 0:
            var message = string.String.from_str("dependency ")
            message.append(name)
            message.append(" not found in ")
            message.append(manifest_path)
            return Result[string.String, string.String].failure(error = message)
        let removed = entries.remove(ptr_uint<-found) else:
            return Result[string.String, string.String].failure(
                error = string.String.from_str("dependency removal failed")
            )
        var owned = removed
        owned.release()
    else:
        var new_entry = DependencyLine(
            name = string.String.from_str(name),
            rendered = string.String.from_str(rendered_spec),
        )
        if found >= 0:
            let existing = entries.get(ptr_uint<-found) else:
                new_entry.release()
                return Result[string.String, string.String].failure(
                    error = string.String.from_str("dependency replacement failed")
                )
            unsafe:
                read(existing).rendered.release()
                read(existing).rendered = string.String.from_str(rendered_spec)
            new_entry.release()
        else:
            entries.push(new_entry)

    var replacement = string.String.create()
    defer: replacement.release()
    if entries.len() > 0:
        replacement.append("[dependencies]\n")
        var ei: ptr_uint = 0
        while ei < entries.len():
            let entry = entries.get(ei) else:
                break
            unsafe:
                append_toml_string(ref_of(replacement), read(entry).name.as_str())
                replacement.append(" = ")
                replacement.append(read(entry).rendered.as_str())
                replacement.append("\n")
            ei += 1

    var updated = replace_dependencies_section(ref_of(source), ref_of(replacement), entries.len() > 0)
    match fs.write_text(manifest_path, updated.as_str()):
        Result.failure as write_failure:
            var write_error = write_failure.error
            var message = string.String.from_str("failed to update ")
            message.append(manifest_path)
            message.append(": ")
            message.append(write_error.message.as_str())
            write_error.release()
            updated.release()
            return Result[string.String, string.String].failure(error = message)
        Result.success:
            pass
    return Result[string.String, string.String].success(value = updated)

struct DependencyLine:
    name: string.String
    rendered: string.String


extending DependencyLine:
    public editable function release() -> void:
        this.name.release()
        this.rendered.release()


function release_dependency_lines(entries: ref[vec.Vec[DependencyLine]]) -> void:
    var i: ptr_uint = 0
    while i < entries.len():
        let entry = entries.get(i) else:
            break
        unsafe: read(entry).release()
        i += 1
    entries.release()


function collect_dependency_lines(
    document: ref[toml.Document],
    manifest_path: str,
    entries: ref[vec.Vec[DependencyLine]],
) -> Result[bool, string.String]:
    let table = document.get_table("dependencies")
    if table != null:
        var table_value = unsafe: read(table)
        return collect_object_lines(ref_of(table_value.entries), manifest_path, entries)

    let inline_object = document.root.get_object("dependencies")
    if inline_object != null:
        var inline_value = unsafe: read(inline_object)
        return collect_object_lines(ref_of(inline_value), manifest_path, entries)

    let entry = find_root_entry(ref_of(document.root), "dependencies")
    if entry != null:
        unsafe:
            if read(entry).value.kind != toml.ValueKind.object_:
                var message = string.String.from_str("dependencies must be a table in ")
                message.append(manifest_path)
                return Result[bool, string.String].failure(error = message)
    return Result[bool, string.String].success(value = true)


function collect_object_lines(
    object: ref[toml.Object],
    manifest_path: str,
    entries: ref[vec.Vec[DependencyLine]],
) -> Result[bool, string.String]:
    var i: ptr_uint = 0
    while i < object.entries.len():
        let entry = object.entries.get(i) else:
            break
        var item = unsafe: read(entry)
        var rendered = string.String.create()
        match render_value(ref_of(item.value), manifest_path):
            Result.failure as render_failure:
                rendered.release()
                return Result[bool, string.String].failure(error = render_failure.error)
            Result.success as render_payload:
                rendered = render_payload.value
        entries.push(DependencyLine(
            name = string.String.from_str(item.key.as_str()),
            rendered = rendered,
        ))
        i += 1
    return Result[bool, string.String].success(value = true)


function render_value(value: ref[toml.Value], manifest_path: str) -> Result[string.String, string.String]:
    var rendered = string.String.create()
    match read(value).kind:
        toml.ValueKind.string_:
            append_toml_string(ref_of(rendered), read(value).string_value.as_str())
            return Result[string.String, string.String].success(value = rendered)
        toml.ValueKind.object_:
            let object = read(value).object_value
            if object == null:
                rendered.release()
                return Result[string.String, string.String].failure(
                    error = string.String.from_str("unsupported dependency spec type Hash")
                )
            rendered.append("{ ")
            var i: ptr_uint = 0
            var first = true
            while i < unsafe: read(object).entries.len():
                let entry = unsafe: read(object).entries.get(i) else:
                    break
                var item = unsafe: read(entry)
                if not first:
                    rendered.append(", ")
                first = false
                rendered.append(item.key.as_str())
                rendered.append(" = ")
                match item.value.kind:
                    toml.ValueKind.string_:
                        append_toml_string(ref_of(rendered), item.value.string_value.as_str())
                    toml.ValueKind.integer:
                        var number_text = string.String.create()
                        var number = item.value.integer_value
                        if number < 0:
                            number_text.push_byte('-')
                            number = -number
                        if number == 0:
                            number_text.push_byte('0')
                        else:
                            var digits: array[ubyte, 32]
                            var count: ptr_uint = 0
                            while number > 0:
                                digits[count] = ubyte<-(number % 10) + 48
                                number = number / 10
                                count += 1
                            while count > 0:
                                count -= 1
                                number_text.push_byte(digits[count])
                        append_toml_string(ref_of(rendered), number_text.as_str())
                        number_text.release()
                    toml.ValueKind.boolean:
                        if item.value.boolean_value:
                            append_toml_string(ref_of(rendered), "true")
                        else:
                            append_toml_string(ref_of(rendered), "false")
                    toml.ValueKind.array_:
                        rendered.release()
                        return Result[string.String, string.String].failure(
                            error = string.String.from_str("unsupported dependency spec type Array")
                        )
                    toml.ValueKind.object_:
                        rendered.release()
                        return Result[string.String, string.String].failure(
                            error = string.String.from_str("unsupported dependency spec type Hash")
                        )
                i += 1
            rendered.append(" }")
            return Result[string.String, string.String].success(value = rendered)
        toml.ValueKind.integer:
            rendered.release()
            return Result[string.String, string.String].failure(
                error = string.String.from_str("unsupported dependency spec type Integer")
            )
        toml.ValueKind.boolean:
            rendered.release()
            return Result[string.String, string.String].failure(
                error = string.String.from_str("unsupported dependency spec type TrueClass")
            )
        toml.ValueKind.array_:
            rendered.release()
            return Result[string.String, string.String].failure(
                error = string.String.from_str("unsupported dependency spec type Array")
            )
    rendered.release()
    var message = string.String.from_str("unsupported dependency spec type Object in ")
    message.append(manifest_path)
    return Result[string.String, string.String].failure(error = message)


function find_root_entry(object: ref[toml.Object], key: str) -> ptr[toml.Entry]?:
    var i: ptr_uint = 0
    while i < object.entries.len():
        let entry = object.entries.get(i) else:
            return null
        unsafe:
            if read(entry).key.as_str().equal(key):
                return entry
        i += 1
    return null


function append_toml_string(output: ref[string.String], value: str) -> void:
    output.push_byte('"')
    var i: ptr_uint = 0
    while i < value.len:
        let byte_value = value.byte_at(i)
        if byte_value == 92:
            output.append("\\\\")
        else if byte_value == 34:
            output.append("\\\"")
        else if byte_value == 10:
            output.append("\\n")
        else if byte_value == 13:
            output.append("\\r")
        else if byte_value == 9:
            output.append("\\t")
        else:
            output.push_byte(byte_value)
        i += 1
    output.push_byte('"')

# =============================================================================
#  Section replacement — the host's textual algorithm
# =============================================================================

function replace_dependencies_section(
    source: ref[string.String],
    replacement: ref[string.String],
    has_replacement: bool,
) -> string.String:
    var lines = vec.Vec[LineView].create()
    defer: lines.release()
    split_lines(source.as_str(), ref_of(lines))

    var start_index = -1
    var i: ptr_uint = 0
    while i < lines.len():
        let line = lines.get(i) else:
            break
        if is_dependencies_header(source.as_str(), unsafe: read(line)):
            start_index = int<-i
            break
        i += 1

    if start_index >= 0:
        var end_index = lines.len()
        var j = ptr_uint<-start_index + 1
        while j < lines.len():
            let line = lines.get(j) else:
                break
            if starts_with_bracket(source.as_str(), unsafe: read(line)):
                end_index = j
                break
            j += 1
        return rebuild_source(
            source.as_str(),
            ref_of(lines),
            ptr_uint<-start_index,
            end_index,
            replacement,
            has_replacement
        )

    var unchanged = string.String.from_str(source.as_str())
    if not has_replacement:
        return unchanged
    if unchanged.len() > 0:
        if unchanged.as_str().byte_at(unchanged.len() - 1) != 10:
            unchanged.push_byte('\n')
        if unchanged.len() < 2 or unchanged.as_str().byte_at(unchanged.len() - 2) != 10:
            unchanged.push_byte('\n')
    unchanged.append(replacement.as_str())
    return unchanged

struct LineView:
    start: ptr_uint
    len: ptr_uint


function split_lines(source: str, lines: ref[vec.Vec[LineView]]) -> void:
    var start: ptr_uint = 0
    var i: ptr_uint = 0
    while i < source.len:
        if source.byte_at(i) == 10:
            lines.push(LineView(start = start, len = i - start + 1))
            start = i + 1
        i += 1
    if start < source.len:
        lines.push(LineView(start = start, len = source.len - start))


function line_text(source: str, line: LineView) -> str:
    var length = line.len
    while (
        length > 0
        and (source.byte_at(line.start + length - 1) == 10 or source.byte_at(line.start + length - 1) == 13)
    ):
        length -= 1
    return source.slice(line.start, length)


function is_dependencies_header(source: str, line: LineView) -> bool:
    let text = line_text(source, line)
    if not text.starts_with("[dependencies]"):
        return false
    var i: ptr_uint = 14
    while i < text.len:
        let byte_value = text.byte_at(i)
        if byte_value != 32 and byte_value != 9 and byte_value != 10 and byte_value != 13:
            return false
        i += 1
    return true


function starts_with_bracket(source: str, line: LineView) -> bool:
    let text = line_text(source, line)
    return text.len > 0 and text.byte_at(0) == 91


function rebuild_source(
    source: str,
    lines: ref[vec.Vec[LineView]],
    start_index: ptr_uint,
    end_index: ptr_uint,
    replacement: ref[string.String],
    has_replacement: bool,
) -> string.String:
    var before = string.String.create()
    defer: before.release()
    var i: ptr_uint = 0
    while i < start_index:
        let line = lines.get(i) else:
            break
        before.append(source.slice(unsafe: read(line).start, unsafe: read(line).len))
        i += 1
    rstrip(ref_of(before))

    var after = string.String.create()
    defer: after.release()
    var j = end_index
    while j < lines.len():
        let line = lines.get(j) else:
            break
        after.append(source.slice(unsafe: read(line).start, unsafe: read(line).len))
        j += 1
    let trailing = after.as_str().trim_ascii_whitespace()

    var rebuilt = string.String.create()
    rebuilt.append(before.as_str())
    if has_replacement:
        if rebuilt.len() > 0:
            rebuilt.append("\n\n")
        rebuilt.append(replacement.as_str())
    if trailing.len > 0:
        if rebuilt.len() > 0 and rebuilt.as_str().byte_at(rebuilt.len() - 1) != 10:
            rebuilt.push_byte('\n')
        if rebuilt.len() > 1 and rebuilt.as_str().byte_at(rebuilt.len() - 2) != 10:
            rebuilt.push_byte('\n')
        rebuilt.append(trailing)
    else:
        if rebuilt.len() > 0 and rebuilt.as_str().byte_at(rebuilt.len() - 1) != 10:
            rebuilt.push_byte('\n')
    return rebuilt


function rstrip(value: ref[string.String]) -> void:
    var length = value.len()
    while length > 0:
        let byte_value = value.as_str().byte_at(length - 1)
        if byte_value == 32 or byte_value == 9 or byte_value == 10 or byte_value == 13:
            length -= 1
        else:
            break
    value.truncate(length)
