## doc-tag rule — validate `## @param` / `## @return` doc-comment tags.
## Extracted from linter/linter.mt.

import std.vec as vec
import std.str
import std.string as string

import mtc.parser.ast as ast
import mtc.linter.linter as linter_mod


struct DocLine:
    line: ptr_uint
    column: ptr_uint
    text: str

struct DocParamTag:
    name: str
    line: ptr_uint
    column: ptr_uint

struct DocTagParse:
    tag: str
    payload: str


function dt_is_space(b: ubyte) -> bool:
    return b == 32 or b == 9


function dt_is_name_start(b: ubyte) -> bool:
    return (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or b == '_'


function dt_is_name_char(b: ubyte) -> bool:
    return dt_is_name_start(b) or (b >= '0' and b <= '9')


function dt_is_tag_char(b: ubyte) -> bool:
    return dt_is_name_char(b) or b == '-'


## Split `source` into line slices (without the terminating newline).
function split_lines(source: str) -> vec.Vec[str]:
    var lines = vec.Vec[str].create()
    var start: ptr_uint = 0
    var i: ptr_uint = 0
    while i < source.len:
        if source.byte_at(i) == 10:
            lines.push(source.slice(start, i - start))
            start = i + 1
        i += 1
    if start < source.len:
        lines.push(source.slice(start, source.len - start))
    return lines


## The contiguous block of `##` doc-comment lines immediately above `decl_line`,
## top-to-bottom, or empty when there is none.
function collect_doc_block(lines: ref[vec.Vec[str]], decl_line: ptr_uint) -> vec.Vec[DocLine]:
    var docs = vec.Vec[DocLine].create()
    if decl_line < 2:
        return docs
    var collected = vec.Vec[DocLine].create()
    defer: collected.release()
    var idx = decl_line - 2
    while true:
        let lp = lines.get(idx) else:
            break
        let line = unsafe: read(lp)
        let stripped = line.trim_ascii_whitespace()
        if stripped.len == 0 or not stripped.starts_with("##"):
            break
        collected.push(DocLine(line = idx + 1, column = doc_tag_column(line), text = strip_doc_prefix(stripped)))
        if idx == 0:
            break
        idx -= 1
    var k = collected.len()
    while k > 0:
        let cp = collected.get(k - 1) else:
            break
        docs.push(unsafe: read(cp))
        k -= 1
    return docs


## Drop the leading `##` and one optional whitespace from a stripped doc line.
function strip_doc_prefix(s: str) -> str:
    var i: ptr_uint = 2
    if i < s.len and dt_is_space(s.byte_at(i)):
        i += 1
    return s.slice(i, s.len - i)


## The 1-based column of the `@` on a raw doc line, or 1 when absent
## (mirrors Ruby's `doc_tag_column`).
function doc_tag_column(line: str) -> ptr_uint:
    match line.find_substring("@"):
        Option.some as idx:
            return idx.value + 1
        Option.none:
            return 1


## Parse `@tag payload` from a doc line; returns the lowercased tag + trimmed
## payload, or none when the line is not a well-formed tag.
function parse_doc_tag_line(text: str) -> Option[DocTagParse]:
    let t = text.trim_ascii_whitespace()
    if t.len == 0 or t.byte_at(0) != '@':
        return Option[DocTagParse].none
    if t.len < 2 or not dt_is_name_start(t.byte_at(1)):
        return Option[DocTagParse].none
    var j: ptr_uint = 2
    while j < t.len and dt_is_tag_char(t.byte_at(j)):
        j += 1
    let raw_tag = t.slice(1, j - 1)
    # After the tag: end of line, or whitespace followed by the payload.
    var payload = ""
    if j < t.len:
        if not dt_is_space(t.byte_at(j)):
            return Option[DocTagParse].none
        var k = j
        while k < t.len and dt_is_space(t.byte_at(k)):
            k += 1
        payload = t.slice(k, t.len - k).trim_ascii_whitespace()
    return Option[DocTagParse].some(value = DocTagParse(tag = dt_lowercase(raw_tag), payload = payload))


function dt_lowercase(s: str) -> str:
    var buf = string.String.create()
    var i: ptr_uint = 0
    while i < s.len:
        var b = s.byte_at(i)
        if b >= 'A' and b <= 'Z':
            b = b + 32
        buf.push_byte(b)
        i += 1
    return buf.as_str()


## Extract a valid leading parameter name from a payload, or none.
function parse_param_name(payload: str) -> Option[str]:
    if payload.len == 0 or not dt_is_name_start(payload.byte_at(0)):
        return Option[str].none
    var j: ptr_uint = 1
    while j < payload.len and dt_is_name_char(payload.byte_at(j)):
        j += 1
    if j < payload.len and not dt_is_space(payload.byte_at(j)):
        return Option[str].none
    return Option[str].some(value = payload.slice(0, j))


function param_names_of(params: span[ast.Param]) -> vec.Vec[str]:
    var names = vec.Vec[str].create()
    var i: ptr_uint = 0
    while i < params.len:
        unsafe:
            names.push(read(params.data + i).name)
        i += 1
    return names


function param_names_of_foreign(params: span[ast.ForeignParam]) -> vec.Vec[str]:
    var names = vec.Vec[str].create()
    var i: ptr_uint = 0
    while i < params.len:
        unsafe:
            names.push(read(params.data + i).name)
        i += 1
    return names


public function names_contains(names: ref[vec.Vec[str]], name: str) -> bool:
    var i: ptr_uint = 0
    while i < names.len():
        let np = names.get(i) else:
            break
        if unsafe: read(np).equal(name):
            return true
        i += 1
    return false


## Parse and validate the doc block above a declaration.  `is_callable` /
## `param_names` / `return_type` describe function-like declarations.
function process_doc_definition(lines: ref[vec.Vec[str]], decl_line: ptr_uint, decl_name: str, is_callable: bool, param_names: ref[vec.Vec[str]], return_type: ptr[ast.TypeRef]?, path: str, warnings: ref[vec.Vec[linter_mod.Warning]]) -> void:
    var docs = collect_doc_block(lines, decl_line)
    defer: docs.release()
    if docs.len() == 0:
        return

    var param_tags = vec.Vec[DocParamTag].create()
    defer: param_tags.release()
    var has_return = false
    var return_line: ptr_uint = 0
    var return_column: ptr_uint = 0

    var i: ptr_uint = 0
    while i < docs.len():
        let dlp = docs.get(i) else:
            break
        let dl = unsafe: read(dlp)
        match parse_doc_tag_line(dl.text):
            Option.some as parsed:
                let tag = parsed.value.tag
                let payload = parsed.value.payload
                if tag.equal("param"):
                    if payload.len == 0:
                        linter_mod.push_warning_at(warnings, path, dl.line, dl.column, 6, "doc-tag", "doc tag @param requires a parameter name", "hint")
                    else:
                        match parse_param_name(payload):
                            Option.some as pn:
                                param_tags.push(DocParamTag(name = pn.value, line = dl.line, column = dl.column))
                            Option.none:
                                linter_mod.push_warning_at(warnings, path, dl.line, dl.column, 6, "doc-tag", "doc tag @param has an invalid parameter name", "hint")
                else if tag.equal("return") or tag.equal("returns"):
                    has_return = true
                    return_line = dl.line
                    return_column = dl.column
                else if tag.equal("throws") or tag.equal("throw") or tag.equal("see"):
                    pass
                else:
                    var msg = string.String.create()
                    msg.append("unknown doc tag @")
                    msg.append(tag)
                    linter_mod.push_warning_at(warnings, path, dl.line, dl.column, tag.len + 1, "doc-tag", msg.as_str(), "hint")
            Option.none:
                pass
        i += 1

    if not is_callable:
        var pi: ptr_uint = 0
        while pi < param_tags.len():
            let ptp = param_tags.get(pi) else:
                break
            let pt = unsafe: read(ptp)
            linter_mod.push_warning_at(warnings, path, pt.line, pt.column, 1, "doc-tag", "callable doc tags are only valid on function and method declarations", "hint")
            pi += 1
        if has_return:
            linter_mod.push_warning_at(warnings, path, return_line, return_column, 1, "doc-tag", "callable doc tags are only valid on function and method declarations", "hint")
        return

    var pi: ptr_uint = 0
    while pi < param_tags.len():
        let ptp = param_tags.get(pi) else:
            break
        let pt = unsafe: read(ptp)
        if not names_contains(param_names, pt.name):
            var msg = string.String.create()
            msg.append("doc tag @param '")
            msg.append(pt.name)
            msg.append("' does not match any parameter in '")
            msg.append(decl_name)
            msg.append("'")
            linter_mod.push_warning_at(warnings, path, pt.line, pt.column, pt.name.len, "doc-tag", msg.as_str(), "hint")
        pi += 1

    if has_return and linter_mod.is_void_type(return_type):
        var msg = string.String.create()
        msg.append("doc tag @return is stale for '")
        msg.append(decl_name)
        msg.append("' because it returns void")
        linter_mod.push_warning_at(warnings, path, return_line, return_column, 7, "doc-tag", msg.as_str(), "hint")


public function lint_doc_tags(decls: span[ast.Decl], source: str, path: str, warnings: ref[vec.Vec[linter_mod.Warning]]) -> void:
    var lines = split_lines(source)
    defer: lines.release()
    var empty_names = vec.Vec[str].create()
    defer: empty_names.release()

    var i: ptr_uint = 0
    while i < decls.len:
        unsafe:
            match read(decls.data + i):
                ast.Decl.decl_function as fun:
                    var pn = param_names_of(fun.method_params)
                    defer: pn.release()
                    process_doc_definition(ref_of(lines), fun.line, fun.name, true, ref_of(pn), fun.return_type, path, warnings)
                ast.Decl.decl_extending_block as ex:
                    var j: ptr_uint = 0
                    while j < ex.methods.len:
                        let m = read(ex.methods.data + j)
                        var pn = param_names_of(m.method_params)
                        process_doc_definition(ref_of(lines), m.line, m.name, true, ref_of(pn), m.return_type, path, warnings)
                        pn.release()
                        j += 1
                ast.Decl.decl_extern_function as ef:
                    var pn = param_names_of_foreign(ef.extern_params)
                    defer: pn.release()
                    process_doc_definition(ref_of(lines), ef.line, ef.name, true, ref_of(pn), ef.return_type, path, warnings)
                ast.Decl.decl_foreign_function as ff:
                    var pn = param_names_of_foreign(ff.foreign_params)
                    defer: pn.release()
                    process_doc_definition(ref_of(lines), ff.line, ff.name, true, ref_of(pn), ff.return_type, path, warnings)
                ast.Decl.decl_const as c:
                    process_doc_definition(ref_of(lines), c.line, c.name, false, ref_of(empty_names), null, path, warnings)
                ast.Decl.decl_var as v:
                    process_doc_definition(ref_of(lines), v.line, v.name, false, ref_of(empty_names), null, path, warnings)
                ast.Decl.decl_struct as s:
                    process_doc_definition(ref_of(lines), s.line, s.name, false, ref_of(empty_names), null, path, warnings)
                ast.Decl.decl_union as u:
                    process_doc_definition(ref_of(lines), u.line, u.name, false, ref_of(empty_names), null, path, warnings)
                ast.Decl.decl_enum as e:
                    process_doc_definition(ref_of(lines), e.line, e.name, false, ref_of(empty_names), null, path, warnings)
                ast.Decl.decl_flags as f:
                    process_doc_definition(ref_of(lines), f.line, f.name, false, ref_of(empty_names), null, path, warnings)
                ast.Decl.decl_variant as va:
                    process_doc_definition(ref_of(lines), va.line, va.name, false, ref_of(empty_names), null, path, warnings)
                ast.Decl.decl_opaque as o:
                    process_doc_definition(ref_of(lines), o.line, o.name, false, ref_of(empty_names), null, path, warnings)
                ast.Decl.decl_type_alias as ta:
                    process_doc_definition(ref_of(lines), ta.line, ta.name, false, ref_of(empty_names), null, path, warnings)
                ast.Decl.decl_interface as iface:
                    process_doc_definition(ref_of(lines), iface.line, iface.name, false, ref_of(empty_names), null, path, warnings)
                ast.Decl.decl_event as ev:
                    process_doc_definition(ref_of(lines), ev.line, ev.name, false, ref_of(empty_names), null, path, warnings)
                ast.Decl.decl_attribute as at:
                    process_doc_definition(ref_of(lines), at.line, at.name, false, ref_of(empty_names), null, path, warnings)
                _:
                    pass
        i += 1
