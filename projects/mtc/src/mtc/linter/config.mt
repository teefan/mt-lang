## `.mt-lint.yml` configuration — a minimal YAML-subset reader for the lint
## config file the Ruby linter uses.  Supported keys:
##
##   select:               # block list …
##     - prefer-let
##   ignore: [a, b]        # … or inline list
##   max_line_length: 100
##
## The config file is discovered by walking ancestor directories from the
## linted file, exactly like Ruby's `Linter.load_config`.

import std.fs as fs
import std.path as path_ops
import std.str
import std.string as string
import std.vec as vec


public const CONFIG_FILE_NAME: str = ".mt-lint.yml"


public struct LintConfig:
    has_select: bool
    select: vec.Vec[string.String]
    has_ignore: bool
    ignore: vec.Vec[string.String]
    max_line_length: ptr_uint


extending LintConfig:
    public static function empty() -> LintConfig:
        return LintConfig(
            has_select = false,
            select = vec.Vec[string.String].create(),
            has_ignore = false,
            ignore = vec.Vec[string.String].create(),
            max_line_length = 0
        )


    public editable function release() -> void:
        release_values(ref_of(this.select))
        release_values(ref_of(this.ignore))


## Load the nearest `.mt-lint.yml` above `path` (file or directory).
## Returns an empty config when no file is found or it cannot be read.
public function load_for_path(path: str) -> LintConfig:
    var dir = string.String.from_str(if fs.is_directory(path): path else: path_ops.dirname(path))
    defer dir.release()

    var depth: ptr_uint = 0
    while depth < 100:
        var candidate = path_ops.join(dir.as_str(), CONFIG_FILE_NAME)
        defer candidate.release()
        if fs.is_file(candidate.as_str()):
            match fs.read_text(candidate.as_str()):
                Result.success as content:
                    var owned = content.value
                    defer owned.release()
                    return parse_config(owned.as_str())
                Result.failure as failure_payload:
                    var err = failure_payload.error
                    err.release()
                    return LintConfig.empty()

        let parent = path_ops.dirname(dir.as_str())
        if parent == dir.as_str():
            break
        var next_dir = string.String.from_str(parent)
        dir.release()
        dir = next_dir
        depth += 1

    return LintConfig.empty()


## Parse the YAML subset.  Unknown keys are ignored; malformed lines are
## skipped rather than reported (matching Ruby's permissive rescue).
public function parse_config(source: str) -> LintConfig:
    var result = LintConfig.empty()
    var current_key: str = ""

    var start: ptr_uint = 0
    var i: ptr_uint = 0
    while i <= source.len:
        if i == source.len or source.byte_at(i) == 10:
            let raw_line = source.slice(start, i - start)
            parse_line(raw_line, ref_of(result), ref_of(current_key))
            start = i + 1
        i += 1

    return result


function parse_line(raw_line: str, result: ref[LintConfig], current_key: ref[str]) -> void:
    let line = strip_comment(raw_line).trim_ascii_whitespace()
    if line.len == 0:
        return

    # Block-list item under a `select:`/`ignore:` key.
    if line.starts_with("- "):
        let item = line.slice(2, line.len - 2).trim_ascii_whitespace()
        if item.len == 0:
            return
        unsafe:
            if read(current_key) == "select":
                result.select.push(string.String.from_str(item))
            else if read(current_key) == "ignore":
                result.ignore.push(string.String.from_str(item))
        return

    match line.find_byte(':'):
        Option.none:
            return
        Option.some as colon:
            let key = line.slice(0, colon.value).trim_ascii_whitespace()
            let after = colon.value + 1
            let value = line.slice(after, line.len - after).trim_ascii_whitespace()

            if key.equal("select"):
                unsafe: read(current_key) = "select"
                result.has_select = true
                parse_inline_list(value, ref_of(result.select))
            else if key.equal("ignore"):
                unsafe: read(current_key) = "ignore"
                result.has_ignore = true
                parse_inline_list(value, ref_of(result.ignore))
            else if key.equal("max_line_length"):
                unsafe: read(current_key) = ""
                let parsed = parse_uint(value)
                if parsed > 0:
                    result.max_line_length = parsed
            else:
                unsafe: read(current_key) = ""


## Parse `[a, b, c]` (or a single bare value) into `output`.
function parse_inline_list(value: str, output: ref[vec.Vec[string.String]]) -> void:
    if value.len == 0:
        return
    var body = value
    if body.starts_with("[") and body.ends_with("]"):
        body = body.slice(1, body.len - 2).trim_ascii_whitespace()
    if body.len == 0:
        return

    var start: ptr_uint = 0
    var i: ptr_uint = 0
    while i <= body.len:
        if i == body.len or body.byte_at(i) == 44:
            let item = body.slice(start, i - start).trim_ascii_whitespace()
            if item.len > 0:
                output.push(string.String.from_str(item))
            start = i + 1
        i += 1


function strip_comment(line: str) -> str:
    match line.find_byte('#'):
        Option.some as pos:
            return line.slice(0, pos.value)
        Option.none:
            return line


function parse_uint(value: str) -> ptr_uint:
    if value.len == 0:
        return 0
    var result: ptr_uint = 0
    var i: ptr_uint = 0
    while i < value.len:
        let b = value.byte_at(i)
        if b < 48 or b > 57:
            return 0
        result = result * 10 + ptr_uint<-(int<-(b - 48))
        i += 1
    return result


function release_values(values: ref[vec.Vec[string.String]]) -> void:
    var i: ptr_uint = 0
    while i < values.len():
        let vp = values.get(i) else:
            break
        unsafe:
            read(vp).release()
        i += 1
    values.release()
