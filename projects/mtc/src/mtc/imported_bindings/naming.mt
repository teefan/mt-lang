## Imported bindings naming transforms — the host's snake_case/camelize,
## OpenGL normalization tables, rename rules, strip_prefix, and reserved-name
## sanitization.  Each transform returns an owned string.String unless it is a
## borrowed view (strip_prefix_str).

import std.string as string
import std.str
import std.vec as vec

import mtc.imported_bindings.raw_scanner as raw

# =============================================================================
#  OpenGL tables (host naming.rb:7-86)
# =============================================================================

struct OglSuffix:
    suffix: str
    first: str
    second: str
    count: int

const OPENGL_TYPED_SUFFIX_TOKENS: array[OglSuffix, 22] = array[OglSuffix, 22](
    OglSuffix(suffix = "ui64v", first = "uint64", second = "values", count = 2),
    OglSuffix(suffix = "i64v", first = "int64", second = "values", count = 2),
    OglSuffix(suffix = "uiv", first = "uint", second = "values", count = 2),
    OglSuffix(suffix = "iv", first = "int", second = "values", count = 2),
    OglSuffix(suffix = "fi", first = "float", second = "int", count = 2),
    OglSuffix(suffix = "fv", first = "float", second = "values", count = 2),
    OglSuffix(suffix = "dv", first = "double", second = "values", count = 2),
    OglSuffix(suffix = "ubv", first = "ubyte", second = "values", count = 2),
    OglSuffix(suffix = "usv", first = "ushort", second = "values", count = 2),
    OglSuffix(suffix = "bv", first = "byte", second = "values", count = 2),
    OglSuffix(suffix = "sv", first = "short", second = "values", count = 2),
    OglSuffix(suffix = "ui64", first = "uint64", second = "", count = 1),
    OglSuffix(suffix = "i64", first = "int64", second = "", count = 1),
    OglSuffix(suffix = "ui", first = "uint", second = "", count = 1),
    OglSuffix(suffix = "i", first = "int", second = "", count = 1),
    OglSuffix(suffix = "f", first = "float", second = "", count = 1),
    OglSuffix(suffix = "d", first = "double", second = "", count = 1),
    OglSuffix(suffix = "ub", first = "ubyte", second = "", count = 1),
    OglSuffix(suffix = "us", first = "ushort", second = "", count = 1),
    OglSuffix(suffix = "b", first = "byte", second = "", count = 1),
    OglSuffix(suffix = "s", first = "short", second = "", count = 1),
    OglSuffix(suffix = "v", first = "values", second = "", count = 1),
)

const OPENGL_INDEXED_PARAM_NAMES: array[str, 3] = array[str, 3]("buf", "index", "mask_number")

const OPENGL_TYPED_ALPHA_STEMS: array[str, 28] = array[str, 28](
    "array", "attrib", "block", "boolean", "buffer", "double", "feedback",
    "float", "framebuffer", "indexed", "integer", "internalformat", "interface",
    "multisample", "object", "parameter", "pipeline", "pointer", "program",
    "query", "resource", "shader", "stage", "subroutine", "subroutines", "sync",
    "uniform", "uniforms",
)

const OPENGL_TYPED_QUERY_BASES: array[str, 4] = array[str, 4]("boolean", "double", "float", "integer")

const OPENGL_NUMERIC_SUFFIX_CONTEXTS: array[str, 17] = array[str, 17](
    "attrib", "boolean", "double", "feedback", "float", "indexed", "int",
    "integer", "integer64", "long", "matrix", "normalized", "object", "packed",
    "parameter", "uint", "uniform",
)

# =============================================================================
#  Byte helpers
# =============================================================================

function is_upper(ch: ubyte) -> bool:
    return ch >= 65 and ch <= 90


function is_lower(ch: ubyte) -> bool:
    return ch >= 97 and ch <= 122


function is_digit(ch: ubyte) -> bool:
    return ch >= 48 and ch <= 57


function is_alpha(ch: ubyte) -> bool:
    return is_upper(ch) or is_lower(ch)


function is_alnum(ch: ubyte) -> bool:
    return is_alpha(ch) or is_digit(ch)


function is_word(ch: ubyte) -> bool:
    return is_alnum(ch) or ch == 95


function contains_str(items: span[str], name: str) -> bool:
    var i: ptr_uint = 0
    while i < items.len:
        let item = unsafe: read(items.data + i)
        if item.equal(name):
            return true
        i += 1
    return false


function all_digits(text: str) -> bool:
    if text.len == 0:
        return false
    var i: ptr_uint = 0
    while i < text.len:
        if not is_digit(text.byte_at(i)):
            return false
        i += 1
    return true


function all_lower_alpha(text: str) -> bool:
    if text.len == 0:
        return false
    var i: ptr_uint = 0
    while i < text.len:
        if not is_lower(text.byte_at(i)):
            return false
        i += 1
    return true


function digit_x_digit(text: str) -> bool:
    if text.len == 0:
        return false
    var i: ptr_uint = 0
    while i < text.len and is_digit(text.byte_at(i)):
        i += 1
    if i == 0 or i >= text.len or text.byte_at(i) != 120:
        return false
    i += 1
    if i >= text.len:
        return false
    while i < text.len:
        if not is_digit(text.byte_at(i)):
            return false
        i += 1
    return true


function starts_with_digit(text: str) -> bool:
    if text.len == 0:
        return false
    return is_digit(text.byte_at(0))


function starts_at(text: str, start: ptr_uint, pattern: str) -> bool:
    if start + pattern.len > text.len:
        return false
    var i: ptr_uint = 0
    while i < pattern.len:
        if text.byte_at(start + i) != pattern.byte_at(i):
            return false
        i += 1
    return true


function suffix_boundary(text: str, position: ptr_uint) -> bool:
    return position >= text.len or text.byte_at(position) == 95

# =============================================================================
#  Token lists
# =============================================================================

function split_underscore(name: str, dest: ref[vec.Vec[str]]) -> void:
    var start: ptr_uint = 0
    var i: ptr_uint = 0
    while i <= name.len:
        if i == name.len or name.byte_at(i) == 95:
            if i > start:
                dest.push(name.slice(start, i - start))
            start = i + 1
        i += 1


function token_at(tokens: ref[vec.Vec[str]], index: ptr_uint) -> str:
    let p = tokens.get(index) else:
        return ""
    return unsafe: read(p)


function last_token(tokens: ref[vec.Vec[str]]) -> str:
    if tokens.len() == 0:
        return ""
    let p = tokens.last() else:
        return ""
    return unsafe: read(p)


function replace_last(tokens: ref[vec.Vec[str]], value: str) -> void:
    let p = tokens.last() else:
        return
    unsafe:
        read(p) = value


function push_suffix(dest: ref[vec.Vec[str]], spec: OglSuffix) -> void:
    if spec.count >= 1:
        dest.push(spec.first)
    if spec.count >= 2:
        dest.push(spec.second)


function join_tokens(tokens: ref[vec.Vec[str]]) -> string.String:
    var result = string.String.with_capacity(64)
    var i: ptr_uint = 0
    while i < tokens.len():
        if i > 0:
            result.push_byte('_')
        let p = tokens.get(i) else:
            break
        result.append(unsafe: read(p))
        i += 1
    return result

# =============================================================================
#  Core transforms
# =============================================================================

## Convert CamelCase to snake_case with the host's four-step gsub:
## acronym boundary, lower/digit-to-upper boundary, downcase, `_d` fixup.
public function snake_case(name: str) -> string.String:
    var result = string.String.with_capacity(name.len + 8)
    var i: ptr_uint = 0
    while i < name.len:
        let ch = name.byte_at(i)
        if is_upper(ch):
            var insert = false
            if i > 0:
                let previous = name.byte_at(i - 1)
                if is_lower(previous) or is_digit(previous):
                    insert = true
                else if is_upper(previous) and i + 1 < name.len and is_lower(name.byte_at(i + 1)):
                    insert = true
            if insert:
                result.push_byte('_')
            result.push_byte(ch + 32)
        else:
            result.push_byte(ch)
        i += 1

    # `([a-z])(\d+)_d\b` -> `\1_\2d`: move the underscore before the digit run.
    var fixed = string.String.with_capacity(result.len())
    let result_text = result.as_str()
    i = 0
    while i < result_text.len:
        if result_text.byte_at(i) == 95 and i + 1 < result_text.len and result_text.byte_at(i + 1) == 100:
            var boundary = true
            if i + 2 < result_text.len and is_word(result_text.byte_at(i + 2)):
                boundary = false
            if boundary and i >= 2:
                var j = i - 1
                var digits: ptr_uint = 0
                while j > 0 and is_digit(result_text.byte_at(j)):
                    digits += 1
                    j -= 1
                if digits > 0 and is_lower(result_text.byte_at(j)):
                    fixed.truncate(fixed.len() - (digits + 1))
                    fixed.push_byte(result_text.byte_at(j))
                    fixed.push_byte('_')
                    var k = j + 1
                    while k < i:
                        fixed.push_byte(result_text.byte_at(k))
                        k += 1
                    fixed.push_byte('d')
                    i += 2
                    continue
        fixed.push_byte(result_text.byte_at(i))
        i += 1

    result.release()
    return fixed


## Convert snake_case to CamelCase: "hello_world" -> "HelloWorld".
public function camelize(name: str) -> string.String:
    var result = string.String.with_capacity(name.len)
    var next_upper: bool = true
    var i: ptr_uint = 0

    while i < name.len:
        let ch = name.byte_at(i)
        if ch == '_':
            next_upper = true
            i += 1
            continue

        if next_upper:
            if is_lower(ch):
                result.push_byte(ch - 32)
            else:
                result.push_byte(ch)
            next_upper = false
        else:
            if is_upper(ch):
                result.push_byte(ch + 32)
            else:
                result.push_byte(ch)

        i += 1

    return result


## Strip a prefix from a name if matched.  Returns a borrowed str view — the
## original text must outlive it.
public function strip_prefix_str(name: str, prefix: str) -> str:
    if prefix.len == 0:
        return name
    if prefix.len > name.len:
        return name
    if not name.starts_with(prefix):
        return name
    return name.slice(prefix.len, name.len - prefix.len)

# =============================================================================
#  Rename rule application
# =============================================================================

public function apply_rename_rule(name: str, kind: str, pattern: str, replace_with: str) -> string.String:
    if kind.equal("prefix"):
        if name.starts_with(pattern):
            let suffix = name.slice(pattern.len, name.len - pattern.len)
            var r = string.String.with_capacity(replace_with.len + suffix.len)
            r.append(replace_with)
            r.append(suffix)
            return r
        return string.String.from_str(name)

    if kind.equal("replace"):
        if pattern.len == 0:
            return string.String.from_str(name)
        var r = string.String.with_capacity(name.len)
        var remaining = name
        while true:
            match remaining.find_substring(pattern):
                Option.none:
                    r.append(remaining)
                    break
                Option.some as pos:
                    r.append(remaining.slice(0, pos.value))
                    r.append(replace_with)
                    remaining = remaining.slice(pos.value + pattern.len, remaining.len - pos.value - pattern.len)
        return r

    if kind.equal("camelize"):
        return camelize(name)

    if kind.equal("opengl"):
        return openglize_binding_name(name)

    return string.String.from_str(name)


public function apply_rename_rules(
    name: str,
    rule_kinds: span[str],
    rule_patterns: span[str],
    rule_replacements: span[str],
) -> string.String:
    var current = string.String.from_str(name)
    var i: ptr_uint = 0
    while i < rule_kinds.len:
        let kind = unsafe: read(rule_kinds.data + i)
        let pattern = if i < rule_patterns.len: unsafe: read(rule_patterns.data + i) else: ""
        let replacement = if i < rule_replacements.len: unsafe: read(rule_replacements.data + i) else: ""
        var next = apply_rename_rule(current.as_str(), kind, pattern, replacement)
        current.release()
        current = next
        i += 1
    return current

# =============================================================================
#  OpenGL normalization (host naming.rb:88-252)
# =============================================================================

## The host's three `openglize_binding_name` gsubs.
public function openglize_binding_name(name: str) -> string.String:
    # 1) ([A-Za-z])((?:i64|i|ui)_v)(?=\z|_) -> \1_\2
    var first = string.String.with_capacity(name.len + 8)
    var i: ptr_uint = 0
    while i < name.len:
        let ch = name.byte_at(i)
        if is_alpha(ch):
            if starts_at(name, i + 1, "i64_v") and suffix_boundary(name, i + 6):
                first.push_byte(ch)
                first.push_byte('_')
                first.append("i64_v")
                i += 6
                continue
            if starts_at(name, i + 1, "i_v") and suffix_boundary(name, i + 4):
                first.push_byte(ch)
                first.push_byte('_')
                first.append("i_v")
                i += 4
                continue
            if starts_at(name, i + 1, "ui_v") and suffix_boundary(name, i + 5):
                first.push_byte(ch)
                first.push_byte('_')
                first.append("ui_v")
                i += 5
                continue
        first.push_byte(ch)
        i += 1

    # 2) (?<!_)([A-Za-z])(\d[A-Za-z0-9]*)(?=[A-Z_]|\z) -> \1_\2
    var second = string.String.with_capacity(first.len() + 8)
    let first_text = first.as_str()
    i = 0
    while i < first_text.len:
        let ch = first_text.byte_at(i)
        if is_alpha(ch) and (i == 0 or first_text.byte_at(i - 1) != 95) and
                i + 1 < first_text.len and is_digit(first_text.byte_at(i + 1)):
            var j = i + 2
            while j < first_text.len and is_alnum(first_text.byte_at(j)):
                j += 1
            let boundary = j >= first_text.len or first_text.byte_at(j) == 95 or is_upper(first_text.byte_at(j))
            if boundary:
                second.push_byte(ch)
                second.push_byte('_')
                second.append(first_text.slice(i + 1, j - i - 1))
                i = j
                continue
        second.push_byte(ch)
        i += 1

    # 3) _(\d)D(?=[A-Z_]|\z) -> _\1d
    var third = string.String.with_capacity(second.len())
    let second_text = second.as_str()
    i = 0
    while i < second_text.len:
        if second_text.byte_at(i) == 95 and i + 2 < second_text.len and
                is_digit(second_text.byte_at(i + 1)) and second_text.byte_at(i + 2) == 68:
            let after = i + 3
            if after >= second_text.len or second_text.byte_at(after) == 95 or is_upper(second_text.byte_at(after)):
                third.push_byte('_')
                third.push_byte(second_text.byte_at(i + 1))
                third.push_byte('d')
                i += 3
                continue
        third.push_byte(second_text.byte_at(i))
        i += 1

    first.release()
    second.release()
    return third


public function opengl_domain_marker(token: str, next_token: str) -> Option[str]:
    if next_token.len == 0:
        return Option[str].none
    let eligible = next_token.equal("format") or next_token.equal("pointer") or starts_with_digit(next_token)
    if not eligible:
        return Option[str].none
    if token.equal("i"):
        return Option[str].some(value = "integer")
    if token.equal("l"):
        return Option[str].some(value = "long")
    if token.equal("p"):
        return Option[str].some(value = "packed")
    return Option[str].none


public function opengl_numeric_suffix_context(tokens: ref[vec.Vec[str]]) -> bool:
    let last = last_token(tokens)
    if last.len == 0:
        return false
    return contains_str(OPENGL_NUMERIC_SUFFIX_CONTEXTS.as_span(), last)


public function expand_opengl_typed_token(
    token: str,
    numeric_context: bool,
    dest: ref[vec.Vec[str]],
) -> bool:
    var i: ptr_uint = 0
    while i < 22:
        let spec = OPENGL_TYPED_SUFFIX_TOKENS[i]
        if token.ends_with(spec.suffix):
            let prefix_len = token.len - spec.suffix.len
            let prefix = token.slice(0, prefix_len)
            if prefix_len == 0:
                if spec.suffix.equal("v"):
                    return false
                if numeric_context:
                    push_suffix(dest, spec)
                    return true
            else if all_digits(prefix) or digit_x_digit(prefix):
                if not numeric_context:
                    return false
                dest.push(prefix)
                push_suffix(dest, spec)
                return true
            else if all_lower_alpha(prefix) and contains_str(OPENGL_TYPED_ALPHA_STEMS.as_span(), prefix):
                dest.push(prefix)
                push_suffix(dest, spec)
                return true
        i += 1
    return false


public function expand_opengl_special_token(
    token: str,
    numeric_context: bool,
    dest: ref[vec.Vec[str]],
) -> bool:
    if token.equal("iiv"):
        dest.push("integer")
        dest.push("int")
        dest.push("values")
        return true
    if token.equal("iuiv"):
        dest.push("integer")
        dest.push("uint")
        dest.push("values")
        return true

    if token.starts_with("n") and token.len > 1:
        var expanded = vec.Vec[str].create()
        var ok = expand_opengl_typed_token(token.slice(1, token.len - 1), true, ref_of(expanded))
        if ok:
            dest.push("normalized")
            var ei: ptr_uint = 0
            while ei < expanded.len():
                let p = expanded.get(ei) else:
                    break
                dest.push(unsafe: read(p))
                ei += 1
            expanded.release()
            return true
        expanded.release()

    return expand_opengl_typed_token(token, numeric_context, dest)


public function normalize_opengl_snake_case(name: str) -> string.String:
    var tokens = vec.Vec[str].create()
    defer: tokens.release()
    split_underscore(name, ref_of(tokens))

    var normalized = vec.Vec[str].create()
    defer: normalized.release()

    var index: ptr_uint = 0
    while index < tokens.len():
        let token = token_at(ref_of(tokens), index)
        let next_token = token_at(ref_of(tokens), index + 1)

        if token.equal("getn"):
            normalized.push("get")
            normalized.push("n")
            index += 1
            continue

        if token.equal("64i") and next_token.equal("v"):
            if last_token(ref_of(normalized)).equal("integer"):
                replace_last(ref_of(normalized), "integer64")
                normalized.push("indexed")
                normalized.push("values")
            else:
                normalized.push("int64")
                normalized.push("indexed")
                normalized.push("values")
            index += 2
            continue

        if token.equal("i") and next_token.equal("v"):
            if contains_str(OPENGL_TYPED_QUERY_BASES.as_span(), last_token(ref_of(normalized))):
                normalized.push("indexed")
                normalized.push("values")
            else:
                normalized.push("int")
                normalized.push("indexed")
                normalized.push("values")
            index += 2
            continue

        if token.equal("i64") and next_token.equal("v"):
            normalized.push("int64")
            normalized.push("indexed")
            normalized.push("values")
            index += 2
            continue

        if token.equal("ui64") and next_token.equal("v"):
            normalized.push("uint64")
            normalized.push("indexed")
            normalized.push("values")
            index += 2
            continue

        if token.equal("64v"):
            let last = last_token(ref_of(normalized))
            if last.equal("integer"):
                replace_last(ref_of(normalized), "integer64")
                normalized.push("values")
                index += 1
                continue
            if last.equal("int"):
                replace_last(ref_of(normalized), "int64")
                normalized.push("values")
                index += 1
                continue
            if last.equal("uint"):
                replace_last(ref_of(normalized), "uint64")
                normalized.push("values")
                index += 1
                continue

        match opengl_domain_marker(token, next_token):
            Option.some as marker:
                normalized.push(marker.value)
                index += 1
                continue
            Option.none:
                pass

        var expanded = vec.Vec[str].create()
        let numeric_context = opengl_numeric_suffix_context(ref_of(normalized))
        if expand_opengl_special_token(token, numeric_context, ref_of(expanded)):
            var ei: ptr_uint = 0
            while ei < expanded.len():
                let p = expanded.get(ei) else:
                    break
                normalized.push(unsafe: read(p))
                ei += 1
            expanded.release()
            index += 1
            continue
        expanded.release()

        normalized.push(token)
        index += 1

    return join_tokens(ref_of(normalized))


public function opengl_indexed_terminal_variant(raw_name: str, raw_funcs: span[raw.RawFuncInfo]) -> bool:
    var i: ptr_uint = 0
    while i < raw_funcs.len:
        unsafe:
            let func = raw_funcs.data + i
            if func.name.as_str().equal(raw_name):
                var pi: ptr_uint = 0
                while pi < func.params.len:
                    let param = func.params.get(pi) else:
                        break
                    var param_name = snake_case(read(param).name.as_str())
                    let found = contains_str(OPENGL_INDEXED_PARAM_NAMES.as_span(), param_name.as_str())
                    param_name.release()
                    if found:
                        return true
                    pi += 1
                return false
        i += 1
    return false


function replace_trailing(name: str, old_suffix: str, new_suffix: str) -> string.String:
    var result = string.String.with_capacity(name.len + new_suffix.len)
    result.append(name.slice(0, name.len - old_suffix.len))
    result.append(new_suffix)
    return result


public function normalize_opengl_terminal_suffix(
    name: str,
    raw_name: str,
    raw_funcs: span[raw.RawFuncInfo],
) -> string.String:
    var normalized = string.String.from_str(name)
    if normalized.ends_with("indexedfv"):
        var replaced = replace_trailing(normalized.as_str(), "indexedfv", "indexed_float_values")
        normalized.release()
        normalized = replaced
    else if normalized.ends_with("indexedf"):
        var replaced = replace_trailing(normalized.as_str(), "indexedf", "indexed_float")
        normalized.release()
        normalized = replaced

    if raw_name.ends_with("i") and normalized.ends_with("i"):
        let suffix = if opengl_indexed_terminal_variant(raw_name, raw_funcs): "indexed" else: "int"
        var result = string.String.with_capacity(normalized.len() + suffix.len)
        result.append(normalized.as_str().slice(0, normalized.len() - 1))
        result.push_byte('_')
        result.append(suffix)
        normalized.release()
        return result

    if raw_name.ends_with("f") and normalized.ends_with("f"):
        var result = string.String.with_capacity(normalized.len() + 7)
        result.append(normalized.as_str().slice(0, normalized.len() - 1))
        result.append("_float")
        normalized.release()
        return result

    return normalized

# =============================================================================
#  Reserved-name sanitization
# =============================================================================

## Milk Tea keywords (host core/keywords.rb KEYWORDS).
public function is_reserved_keyword(name: str) -> bool:
    if name.equal("align_of"): return true
    if name.equal("and"): return true
    if name.equal("as"): return true
    if name.equal("async"): return true
    if name.equal("attribute"): return true
    if name.equal("attribute_arg"): return true
    if name.equal("attribute_of"): return true
    if name.equal("attributes_of"): return true
    if name.equal("await"): return true
    if name.equal("break"): return true
    if name.equal("callable_of"): return true
    if name.equal("compiler_flag"): return true
    if name.equal("const"): return true
    if name.equal("consuming"): return true
    if name.equal("continue"): return true
    if name.equal("defer"): return true
    if name.equal("detach"): return true
    if name.equal("dyn"): return true
    if name.equal("editable"): return true
    if name.equal("else"): return true
    if name.equal("emit"): return true
    if name.equal("enum"): return true
    if name.equal("event"): return true
    if name.equal("extending"): return true
    if name.equal("external"): return true
    if name.equal("false"): return true
    if name.equal("field_of"): return true
    if name.equal("fields_of"): return true
    if name.equal("flags"): return true
    if name.equal("fn"): return true
    if name.equal("for"): return true
    if name.equal("foreign"): return true
    if name.equal("function"): return true
    if name.equal("gather"): return true
    if name.equal("has_attribute"): return true
    if name.equal("if"): return true
    if name.equal("implements"): return true
    if name.equal("import"): return true
    if name.equal("in"): return true
    if name.equal("include"): return true
    if name.equal("inline"): return true
    if name.equal("inout"): return true
    if name.equal("interface"): return true
    if name.equal("is"): return true
    if name.equal("let"): return true
    if name.equal("link"): return true
    if name.equal("match"): return true
    if name.equal("members_of"): return true
    if name.equal("module"): return true
    if name.equal("not"): return true
    if name.equal("null"): return true
    if name.equal("offset_of"): return true
    if name.equal("opaque"): return true
    if name.equal("or"): return true
    if name.equal("out"): return true
    if name.equal("parallel"): return true
    if name.equal("pass"): return true
    if name.equal("proc"): return true
    if name.equal("public"): return true
    if name.equal("return"): return true
    if name.equal("size_of"): return true
    if name.equal("static"): return true
    if name.equal("static_assert"): return true
    if name.equal("struct"): return true
    if name.equal("true"): return true
    if name.equal("type"): return true
    if name.equal("union"): return true
    if name.equal("unsafe"): return true
    if name.equal("var"): return true
    if name.equal("variant"): return true
    if name.equal("when"): return true
    if name.equal("while"): return true
    return false

const BUILTIN_PRIMITIVE_NAMES: array[str, 26] = array[str, 26](
    "bool", "byte", "ubyte", "char", "short", "ushort", "int", "uint", "long",
    "ulong", "ptr_int", "ptr_uint", "float", "double", "void", "str", "cstr",
    "vec2", "vec3", "vec4", "ivec2", "ivec3", "ivec4", "mat3", "mat4", "quat",
)

const RESERVED_TYPE_BINDING_NAMES: array[str, 47] = array[str, 47](
    "bool", "byte", "ubyte", "char", "short", "ushort", "int", "uint", "long",
    "ulong", "ptr_int", "ptr_uint", "float", "double", "void", "str", "cstr",
    "vec2", "vec3", "vec4", "ivec2", "ivec3", "ivec4", "mat3", "mat4", "quat",
    "ptr", "const_ptr", "own", "ref", "span", "array", "str_buffer", "atomic",
    "Task", "Option", "Result", "SoA", "simd", "struct_handle", "field_handle",
    "callable_handle", "attribute_handle", "member_handle", "type",
    "EventError", "Subscription",
)


public function is_reserved_type_binding(name: str) -> bool:
    if is_reserved_keyword(name):
        return true
    return contains_str(RESERVED_TYPE_BINDING_NAMES.as_span(), name)


public function is_reserved_value_binding(name: str) -> bool:
    if is_reserved_keyword(name):
        return true
    if contains_str(BUILTIN_PRIMITIVE_NAMES.as_span(), name):
        return true
    return name.equal("Option") or name.equal("Result")


public function sanitize_type_binding_name(name: str) -> string.String:
    if is_reserved_type_binding(name):
        var r = string.String.from_str(name)
        r.push_byte('_')
        return r
    return string.String.from_str(name)


public function sanitize_value_binding_name(name: str) -> string.String:
    if is_reserved_value_binding(name):
        var r = string.String.from_str(name)
        r.push_byte('_')
        return r
    return string.String.from_str(name)
