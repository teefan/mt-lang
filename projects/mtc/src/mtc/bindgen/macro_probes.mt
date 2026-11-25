## Macro constant probes — `#define` discovery, macro-body normalisation,
## constant lowering, and the synthetic probe declarations (the host's
## `macro_probe_declarations`).  Extracted from bindgen.mt.

import std.str
import std.string as string
import std.vec as vec
import std.json as json
import std.process as process

import mtc.bindgen as bindgen

public const MACRO_PROBE_PREFIX: str = "__mt_bindgen_macro_"


public function first_inner_child(node: ptr[json.Object]) -> ptr[json.Object]?:
    unsafe:
        let children = bindgen.jget_inner(node)
        if children == null:
            return null
        var i: ptr_uint = 0
        while true:
            let cvp = read(children).get(i) else:
                break
            let co = read(cvp).as_object()
            if co != null:
                return co
            i += 1
    return null

## Candidate macro names in definition order (the host's
## `macro_constant_candidates`): uppercase, allowed by the declaration
## prefixes, value-shaped bodies.

public function macro_candidates(
    tu_path: str,
    clang_bin: str,
    clang_args: span[str],
    opts: ref[bindgen.BindgenOptions]
) -> vec.Vec[string.String]:
    var names = vec.Vec[string.String].create()
    var values = vec.Vec[string.String].create()
    defer: bindgen.release_macro_names(ref_of(values))
    var args = vec.Vec[str].create()
    defer: args.release()
    args.push(clang_bin)
    args.push("-x")
    args.push("c")
    args.push("-fno-builtin")
    var ai: ptr_uint = 0
    while ai < clang_args.len:
        args.push(unsafe: read(clang_args.data + ai))
        ai += 1
    args.push("-E")
    args.push("-dD")
    args.push(tu_path)

    match process.capture(args.as_span()):
        Result.success as captured:
            var result = captured.value
            defer: result.stdout.release()
            defer: result.stderr.release()
            if result.status.exit_code != 0:
                return names
            let text = result.stdout.as_str()
            var current_file = string.String.create()
            defer: current_file.release()
            var pos: ptr_uint = 0
            while pos < text.len:
                var line_end = pos
                while line_end < text.len and text.byte_at(line_end) != '\n':
                    line_end += 1
                let line = text.slice(pos, line_end - pos)
                pos = line_end + 1
                if line.len >= 2 and line.byte_at(0) == '#' and line.byte_at(1) == ' ':
                    match macro_line_marker_path(line):
                        Option.some as path:
                            current_file.release()
                            current_file = bindgen.absolute_path(path.value)
                        Option.none:
                            pass
                    continue
                if line.len < 8 or line.byte_at(0) != '#' or not line.slice(1, 6).equal("define"):
                    continue
                if current_file.as_str().len == 0 or not bindgen.tracked_macro_file(
                    current_file.as_str(),
                    read(opts).header_path.as_str(),
                    opts
                ):
                    continue
                var si: ptr_uint = 8
                while si < line.len and line.byte_at(si) == ' ':
                    si += 1
                let name_start = si
                while si < line.len and bindgen.is_ident_byte(line.byte_at(si)):
                    si += 1
                let name = line.slice(name_start, si - name_start)
                if name == "":
                    continue
                if si < line.len and line.byte_at(si) == '(':
                    continue
                while si < line.len and line.byte_at(si) == ' ':
                    si += 1
                var body = normalize_macro_body(line.slice(si, line.len - si))
                defer: body.release()
                if not macro_constant_candidate(name, body.as_str(), opts):
                    continue
                let existing = bindgen.find_macro_index(ref_of(names), name)
                if existing < names.len():
                    let vp = values.get(existing) else:
                        continue
                    unsafe:
                        read(vp).release()
                        read(vp) = string.String.from_str(body.as_str())
                else:
                    names.push(string.String.from_str(name))
                    values.push(string.String.from_str(body.as_str()))
        Result.failure:
            pass
    return names

## The host's `macro_constant_candidate?`.

function macro_line_marker_path(line: str) -> Option[str]:
    var i: ptr_uint = 2
    while i < line.len and line.byte_at(i) == ' ':
        i += 1
    while i < line.len and line.byte_at(i) >= '0' and line.byte_at(i) <= '9':
        i += 1
    if i >= line.len or line.byte_at(i) != ' ':
        return Option[str].none
    while i < line.len and line.byte_at(i) == ' ':
        i += 1
    if i >= line.len or line.byte_at(i) != '"':
        return Option[str].none
    i += 1
    let start = i
    while i < line.len and line.byte_at(i) != '"':
        i += 1
    if i >= line.len:
        return Option[str].none
    let path = line.slice(start, i - start)
    if path.len > 0 and path.byte_at(0) == '<':
        return Option[str].none
    return Option[str].some(value = path)


function macro_constant_candidate(name: str, body: str, opts: ref[bindgen.BindgenOptions]) -> bool:
    if not bindgen.uppercase_macro_name(name):
        return false
    if not bindgen.allowed_declaration_name(name, opts):
        return false
    if body.len == 0:
        return false
    let first_byte = body.byte_at(0)
    var all_ident = (first_byte >= 'A' and first_byte <= 'Z') or (first_byte >= 'a' and first_byte <= 'z') or first_byte == '_'
    var bi: ptr_uint = 0
    while bi < body.len:
        if not bindgen.is_ident_byte(body.byte_at(bi)):
            all_ident = false
            break
        bi += 1
    if all_ident:
        return false
    if body.contains_substring("\"") or body.contains_substring("'"):
        return false
    if contains_disallowed_macro_call(body):
        return false
    if first_macro_token_disallowed(body):
        return false
    bi = 0
    while bi < body.len:
        if not is_macro_body_char(body.byte_at(bi)):
            return false
        bi += 1
    return true


function first_macro_token_disallowed(body: str) -> bool:
    var i: ptr_uint = 0
    while i < body.len and body.byte_at(i) == ' ':
        i += 1
    let start = i
    while i < body.len and bindgen.is_ident_byte(body.byte_at(i)):
        i += 1
    let token = body.slice(start, i - start)
    if token == "":
        return false
    return token.equal("extern") or token.equal("static") or token.equal("inline") or token.equal("typedef") or token.equal("struct") or token.equal("union") or token.equal("enum") or token.equal("do") or token.equal("if") or token.equal("else") or token.equal("for") or token.equal("while") or token.equal("return") or token.equal("sizeof") or token.equal("__attribute__") or token.equal("__attribute") or token.equal("__declspec")

## The host's `contains_disallowed_macro_call?`: a call to a non-uppercase
## name (e.g. a C function) makes the body unusable as a constant.

function contains_disallowed_macro_call(source: str) -> bool:
    var index: ptr_uint = 0
    while index < source.len:
        var i = index
        while i < source.len and not bindgen.is_ident_byte(source.byte_at(i)):
            i += 1
        if i >= source.len:
            return false
        let callee_start = i
        while i < source.len and bindgen.is_ident_byte(source.byte_at(i)):
            i += 1
        let callee = source.slice(callee_start, i - callee_start)
        var j = i
        while j < source.len and source.byte_at(j) == ' ':
            j += 1
        if j >= source.len or source.byte_at(j) != '(':
            index = i
            continue
        if not bindgen.uppercase_macro_name(callee):
            return true
        let close = matching_paren_index(source, j)
        if close < 0:
            return true
        index = ptr_uint<-close + 1
    return false


function matching_paren_index(source: str, open_index: ptr_uint) -> int:
    var depth: int = 0
    var i = open_index
    while i < source.len:
        let b = source.byte_at(i)
        if b == '(':
            depth += 1
        else if b == ')':
            depth -= 1
            if depth == 0:
                return int<-i
        i += 1
    return -1


function normalize_macro_body(body: str) -> string.String:
    var cleaned = string.String.create()
    var i: ptr_uint = 0
    while i < body.len:
        if i + 1 < body.len and body.byte_at(i) == '/' and body.byte_at(i + 1) == '*':
            i += 2
            while i + 1 < body.len and not (body.byte_at(i) == '*' and body.byte_at(i + 1) == '/'):
                i += 1
            i += 2
            cleaned.push_byte(' ')
            continue
        if i + 1 < body.len and body.byte_at(i) == '/' and body.byte_at(i + 1) == '/':
            break
        cleaned.push_byte(body.byte_at(i))
        i += 1
    var trimmed = bindgen.str_strip(cleaned.as_str())
    var copied = string.String.from_str(trimmed)
    cleaned.release()
    return copied


function is_macro_body_char(b: ubyte) -> bool:
    if (b >= 'A' and b <= 'Z') or (b >= 'a' and b <= 'z') or (b >= '0' and b <= '9'):
        return true
    if b == '_' or b == '(' or b == ')' or b == '+' or b == '-' or b == '*' or b == '/' or b == '%':
        return true
    if b == '<' or b == '>' or b == '&' or b == '|' or b == '~' or b == '^' or b == '.' or b == ',':
        return true
    if b == '{' or b == '}' or b == '[' or b == ']' or b == ':' or b == '?' or b == ' ':
        return true
    return b == 9 or b == 10 or b == 13

## The host's `lower_constant_expression`; none when the shape is unsupported.

public function lower_constant(
    node: ptr[json.Object]?,
    expected_type: str,
    opts: ref[bindgen.BindgenOptions]
) -> Option[string.String]:
    let n = node else:
        return Option[string.String].none
    unsafe:
        let kind = bindgen.jget_str(n, "kind")
        if kind.equal("IntegerLiteral"):
            let value = bindgen.jget_str(n, "value")
            match pointer_zero_literal(expected_type, value):
                Option.some as typed_null:
                    return Option[string.String].some(value = typed_null.value)
                Option.none:
                    return Option[string.String].some(value = string.String.from_str(value))
        if kind.equal("FloatingLiteral"):
            let value = bindgen.jget_str(n, "value")
            var rendered = string.String.from_str(value)
            if (
                not value.contains_substring(".")
                and not value.contains_substring("e")
                and not value.contains_substring("E")
            ):
                rendered.append(".0")
            return Option[string.String].some(value = rendered)
        if kind.equal("StringLiteral"):
            var rendered = string.String.from_str("c")
            rendered.append(bindgen.jget_str(n, "value"))
            return Option[string.String].some(value = rendered)
        if kind.equal("ImplicitValueInitExpr"):
            return lower_zero_value(expected_type, opts)
        if (
            kind.equal("ImplicitCastExpr")
            or kind.equal("ConstantExpr")
            or kind.equal("CompoundLiteralExpr")
            or kind.equal("ParenExpr")
        ):
            return lower_constant(first_inner_child(n), expected_type, opts)
        if kind.equal("UnaryOperator"):
            let operator = bindgen.jget_str(n, "opcode")
            var operand = lower_constant(first_inner_child(n), expected_type, opts) else:
                return Option[string.String].none
            var rendered = string.String.from_str(operator)
            rendered.append(operand.as_str())
            operand.release()
            return Option[string.String].some(value = rendered)
        if kind.equal("InitListExpr"):
            return lower_init_list(n, expected_type, opts)
    return Option[string.String].none


function pointer_zero_literal(expected_type: str, value: str) -> Option[string.String]:
    if not value.equal("0"):
        return Option[string.String].none
    if expected_type.equal("cstr"):
        return Option[string.String].some(value = string.String.from_str("null[ptr[char]]"))
    if expected_type.equal("cstr?"):
        return Option[string.String].some(value = string.String.from_str("null"))
    if bindgen.str_has_prefix(expected_type, "ptr[") or bindgen.str_has_prefix(expected_type, "const_ptr["):
        var rendered = string.String.from_str("null[")
        rendered.append(expected_type)
        rendered.append("]")
        return Option[string.String].some(value = rendered)
    return Option[string.String].none


function lower_zero_value(expected_type: str, opts: ref[bindgen.BindgenOptions]) -> Option[string.String]:
    if expected_type.equal("bool"):
        return Option[string.String].some(value = string.String.from_str("false"))
    if (
        expected_type.equal("char")
        or expected_type.equal("byte")
        or expected_type.equal("ubyte")
        or expected_type.equal("short")
        or expected_type.equal("ushort")
        or expected_type.equal("int")
        or expected_type.equal("uint")
        or expected_type.equal("long")
        or expected_type.equal("ulong")
        or expected_type.equal("ptr_int")
        or expected_type.equal("ptr_uint")
    ):
        return Option[string.String].some(value = string.String.from_str("0"))
    if expected_type.equal("float") or expected_type.equal("double"):
        return Option[string.String].some(value = string.String.from_str("0.0"))
    if expected_type.equal("cstr"):
        return Option[string.String].some(value = string.String.from_str("null[ptr[char]]"))
    if expected_type.equal("cstr?"):
        return Option[string.String].some(value = string.String.from_str("null"))
    if bindgen.str_has_prefix(expected_type, "ptr[") or bindgen.str_has_prefix(expected_type, "const_ptr["):
        var rendered = string.String.from_str("null[")
        rendered.append(expected_type)
        rendered.append("]")
        return Option[string.String].some(value = rendered)
    if bindgen.find_aggregate_node(expected_type) != null:
        return lower_init_list_fields(null, expected_type, opts)
    match parse_array_type(expected_type):
        Option.some as array_info:
            var rendered = string.String.from_str(expected_type)
            rendered.append("(")
            var index: ptr_uint = 0
            while index < array_info.value.length:
                if index > 0:
                    rendered.append(", ")
                match lower_zero_value(array_info.value.element_type, opts):
                    Option.some as element:
                        rendered.append(element.value.as_str())
                        element.value.release()
                    Option.none:
                        return Option[string.String].none
                index += 1
            rendered.append(")")
            return Option[string.String].some(value = rendered)
        Option.none:
            pass
    var cast = string.String.from_str(expected_type)
    cast.append("<-0")
    return Option[string.String].some(value = cast)

struct ArrayTypeInfo:
    element_type: str
    length: ptr_uint


function parse_array_type(expected_type: str) -> Option[ArrayTypeInfo]:
    if not bindgen.str_has_prefix(expected_type, "array[") or not expected_type.ends_with("]"):
        return Option[ArrayTypeInfo].none
    let inner = expected_type.slice(6, expected_type.len - 7)
    var comma: ptr_uint = 0
    var depth: ptr_uint = 0
    var found = expected_type.len
    var i: ptr_uint = 0
    while i < inner.len:
        let b = inner.byte_at(i)
        if b == '[' or b == '(':
            depth += 1
        else if b == ']' or b == ')':
            depth -= 1
        else if b == ',' and depth == 0:
            comma = i
            found = i
            break
        i += 1
    if found >= expected_type.len:
        return Option[ArrayTypeInfo].none
    let element = bindgen.str_strip(inner.slice(0, comma))
    let length_text = bindgen.str_strip(inner.slice(comma + 1, inner.len - comma - 1))
    var length: ptr_uint = 0
    i = 0
    while i < length_text.len:
        let b = length_text.byte_at(i)
        if b < '0' or b > '9':
            return Option[ArrayTypeInfo].none
        length = length * 10 + ptr_uint<-(b - '0')
        i += 1
    return Option[ArrayTypeInfo].some(value = ArrayTypeInfo(element_type = element, length = length))


function lower_init_list(
    node: ptr[json.Object]?,
    expected_type: str,
    opts: ref[bindgen.BindgenOptions]
) -> Option[string.String]:
    if bindgen.find_aggregate_node(expected_type) != null:
        return lower_init_list_fields(node, expected_type, opts)
    match parse_array_type(expected_type):
        Option.some as array_info:
            return lower_array_init_list(node, array_info.value, opts)
        Option.none:
            return Option[string.String].none


function lower_array_init_list(
    node: ptr[json.Object]?,
    array_info: ArrayTypeInfo,
    opts: ref[bindgen.BindgenOptions]
) -> Option[string.String]:
    var rendered = string.String.from_str("array[")
    rendered.append(array_info.element_type)
    rendered.append(", ")
    rendered.append(bindgen.uint_to_str(array_info.length))
    rendered.append("](")
    var index: ptr_uint = 0
    while index < array_info.length:
        if index > 0:
            rendered.append(", ")
        let value_node = array_element_node(node, index)
        if value_node == null:
            match lower_zero_value(array_info.element_type, opts):
                Option.some as zero:
                    rendered.append(zero.value.as_str())
                    zero.value.release()
                Option.none:
                    return Option[string.String].none
        else:
            match lower_constant(value_node, array_info.element_type, opts):
                Option.some as element:
                    rendered.append(element.value.as_str())
                    element.value.release()
                Option.none:
                    return Option[string.String].none
        index += 1
    rendered.append(")")
    return Option[string.String].some(value = rendered)


function array_element_node(node: ptr[json.Object]?, index: ptr_uint) -> ptr[json.Object]?:
    let n = node else:
        return null
    unsafe:
        let children = bindgen.jget_inner(n)
        if children == null:
            return null
        let cvp = read(children).get(index) else:
            return null
        return read(cvp).as_object()


function lower_init_list_fields(
    node: ptr[json.Object]?,
    expected_type: str,
    opts: ref[bindgen.BindgenOptions]
) -> Option[string.String]:
    let record = bindgen.find_aggregate_node(expected_type) else:
        return Option[string.String].none
    var rendered = string.String.from_str(expected_type)
    rendered.append("(")
    unsafe:
        let children = bindgen.jget_inner(record)
        if children == null:
            return Option[string.String].none
        var index: ptr_uint = 0
        var emitted: ptr_uint = 0
        while true:
            let entry = read(children).get(index) else:
                break
            index += 1
            let field_object = read(entry).as_object()
            if field_object == null:
                continue
            let field = unsafe: ptr[json.Object]<-field_object
            if not bindgen.jget_str(field, "kind").equal("FieldDecl"):
                continue
            if emitted > 0:
                rendered.append(", ")
            bindgen.set_bindgen_map_failed(false)
            var field_type = bindgen.aggregate_field_type(field, expected_type, record, opts)
            if bindgen.bindgen_map_failed_flag():
                field_type.release()
                return Option[string.String].none
            rendered.append(bindgen.jget_str(field, "name"))
            rendered.append(" = ")
            let value_node = array_element_node(node, emitted)
            var lowered: Option[string.String]
            if value_node == null:
                lowered = lower_zero_value(field_type.as_str(), opts)
            else:
                lowered = lower_constant(value_node, field_type.as_str(), opts)
            field_type.release()
            match lowered:
                Option.some as value:
                    rendered.append(value.value.as_str())
                    value.value.release()
                Option.none:
                    return Option[string.String].none
            emitted += 1
    rendered.append(")")
    return Option[string.String].some(value = rendered)
