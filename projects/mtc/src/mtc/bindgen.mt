## Self-hosted bindgen — generates a Milk Tea external binding module from a C
## header by running clang to dump the AST as JSON, extracting top-level
## declarations, mapping C types to MT types, and emitting the module source.

import std.str
import std.string as string
import std.vec as vec
import std.map as map_mod
import std.json as json
import std.process as process
import std.path as path_ops
import std.fs as fs
import std.mem.heap as heap

import mtc.formatter.tidy as tidy

# =============================================================================
#  Utilities
# =============================================================================

function str_has_prefix(s: str, prefix: str) -> bool:
    if s.len < prefix.len:
        return false
    var i: ptr_uint = 0
    while i < prefix.len:
        if s.byte_at(i) != prefix.byte_at(i):
            return false
        i += 1
    return true


function str_strip(t: str) -> str:
    var s: ptr_uint = 0
    while s < t.len and t.byte_at(s) == ' ':
        s += 1
    var e = t.len
    while e > s and t.byte_at(e - 1) == ' ':
        e -= 1
    return t.slice(s, e - s)


function strip_cv(t: str) -> str:
    var r = t
    while str_has_prefix(r, "const "):
        r = r.slice(6, r.len - 6)
    while str_has_prefix(r, "volatile "):
        r = r.slice(9, r.len - 9)
    while str_has_prefix(r, "restrict "):
        r = r.slice(9, r.len - 9)
    return str_strip(r)


function is_cv_token(word: str) -> bool:
    return word.equal("const") or word.equal("volatile") or word.equal("restrict")

## The host's `strip_qualifiers`: remove const/volatile/restrict tokens.

function strip_cv_tokens(text: str) -> string.String:
    var result = string.String.create()
    var i: ptr_uint = 0
    var first = true
    var source = str_strip(text)
    while i < source.len:
        while i < source.len and source.byte_at(i) == ' ':
            i += 1
        let start = i
        while i < source.len and source.byte_at(i) != ' ':
            i += 1
        if i > start:
            let word = source.slice(start, i - start)
            if not is_cv_token(word):
                if not first:
                    result.push_byte(' ')
                result.append(word)
                first = false
    return result


function has_cv_token(text: str, qualifier: str) -> bool:
    var i: ptr_uint = 0
    let source = str_strip(text)
    while i < source.len:
        while i < source.len and source.byte_at(i) == ' ':
            i += 1
        let start = i
        while i < source.len and source.byte_at(i) != ' ':
            i += 1
        if i > start and source.slice(start, i - start).equal(qualifier):
            return true
    return false

## A trailing const/volatile/restrict qualifier (possibly attached to a `*`).
struct TrailingQualifier:
    name: str
    rest: str


function strip_trailing_qualifier(text: str) -> Option[TrailingQualifier]:
    var sp = str_strip(text)
    while sp.len > 0 and sp.byte_at(sp.len - 1) == ' ':
        sp = sp.slice(0, sp.len - 1)
    var candidates = vec.Vec[str].create()
    defer: candidates.release()
    candidates.push("const")
    candidates.push("volatile")
    candidates.push("restrict")
    var i: ptr_uint = 0
    while i < candidates.len():
        let cp = candidates.get(i) else:
            break
        let qualifier = unsafe: read(cp)
        i += 1
        if sp.len < qualifier.len:
            continue
        let suffix = sp.slice(sp.len - qualifier.len, qualifier.len)
        if not suffix.equal(qualifier):
            continue
        var at = sp.len - qualifier.len
        while at > 0 and sp.byte_at(at - 1) == ' ':
            at -= 1
        if at > 0 and sp.byte_at(at - 1) == '*':
            return Option[TrailingQualifier].some(value = TrailingQualifier(name = qualifier, rest = sp.slice(0, at)))
        if at == 0:
            return Option[TrailingQualifier].some(value = TrailingQualifier(name = qualifier, rest = ""))
        if sp.byte_at(at - 1) == ' ':
            return Option[TrailingQualifier].some(value = TrailingQualifier(
                name = qualifier,
                rest = sp.slice(0, at - 1)
            ))
    return Option[TrailingQualifier].none

## The host's `strip_pointer_suffix_qualifiers`: drop trailing
## const/volatile/restrict words (they qualify the pointer itself).

function strip_pointer_suffix_qualifiers(text: str) -> string.String:
    var current = str_strip(text)
    while true:
        match strip_trailing_qualifier(current):
            Option.some as stripped:
                current = str_strip(stripped.value.rest)
            Option.none:
                return string.String.from_str(current)
    return string.String.from_str(current)

## The host's `pointer_suffix_qualifiers` contains "const"?

function pointer_suffix_has_const(text: str) -> bool:
    var current = str_strip(text)
    while true:
        match strip_trailing_qualifier(current):
            Option.some as stripped:
                if stripped.value.name.equal("const"):
                    return true
                current = str_strip(stripped.value.rest)
            Option.none:
                return false
    return false

## The host's `top_level_const_qualified?`.

function top_level_const_qualified(text: str) -> bool:
    let normalized = str_strip(text)
    var candidate_owner = strip_pointer_suffix_qualifiers(normalized)
    let candidate = candidate_owner.as_str()
    var is_pointer = candidate.len > 0 and candidate.byte_at(candidate.len - 1) == '*'
    candidate_owner.release()
    if is_pointer:
        return pointer_suffix_has_const(normalized)
    return has_cv_token(normalized, "const")


function uint_to_str(n: ptr_uint) -> str:
    var buf = string.String.create()
    if n == 0:
        buf.push_byte('0')
        return buf.as_str()
    var digits: array[ubyte, 20]
    var di: ptr_uint = 0
    var rem = n
    while rem > 0:
        digits[di] = '0' + ubyte<-(rem % 10)
        rem = rem / 10
        di += 1
    var ri = di
    while ri > 0:
        ri -= 1
        buf.push_byte(digits[ri])
    return buf.as_str()


function parse_long(s: str) -> long:
    var i: ptr_uint = 0
    var neg = false
    if s.len > 0 and s.byte_at(0) == '-':
        neg = true
        i = 1
    var v: long = 0
    while i < s.len:
        let b = s.byte_at(i)
        if b >= '0' and b <= '9':
            v = v * 10 + long<-(b - '0')
        i += 1
    if neg:
        return -v
    return v

# =============================================================================
#  JSON helpers — accept ptr[json.Value]? from Object.get(), handle null
# =============================================================================

## Extract a string from a clang JSON value.  Handles both plain JSON strings
## (the common case) and clang wrapped objects.

function jstr(vp: ptr[json.Value]?) -> str:
    if vp == null:
        return ""
    unsafe:
        # Plain JSON string — the common case for kind/name/tagUsed.
        let str_opt = read(vp).as_string()
        if str_opt.is_some():
            return str_opt.unwrap()
        # Try as a clang wrapped StringLiteral object.
        let obj = read(vp).as_object()
        if obj == null:
            return ""
        let kind_vp = read(obj).get("kind")
        let kind = jstr(kind_vp)
        if kind == "StringLiteral":
            let val_vp = read(obj).get("value")
            return jstr(val_vp)
    return ""

## Walk through an Object node to get a named string field: obj.key → value.
## `node` is the Object containing the field; `key` is the field name.

function jget_str(node: ptr[json.Object]?, key: str) -> str:
    if node == null:
        return ""
    unsafe:
        let vp = read(node).get(key)
        return jstr(vp)

## Get the qualType field from a clang Type node: {"qualType":"int"} → "int".

function jget_inner(node: ptr[json.Object]?) -> ptr[json.Array]?:
    if node == null:
        return null
    unsafe:
        let inner_vp = read(node).get("inner")
        if inner_vp == null:
            return null
        return read(inner_vp).as_array()

# =============================================================================
#  C type → MT type mapping
# =============================================================================

## Mark the current declaration's type mapping as failed (the host raises
## BindgenError; the selection passes skip that declaration).

function map_fail() -> string.String:
    bindgen_map_failed = true
    return string.String.create()

## Collapse whitespace runs and strip (the host's `normalize_c_type`).

function normalize_c_type(qual_type: str) -> string.String:
    var result = string.String.create()
    var i: ptr_uint = 0
    var pending_space = false
    while i < qual_type.len:
        let b = qual_type.byte_at(i)
        if b == ' ' or b == '\t' or b == '\n' or b == '\r':
            pending_space = result.len > 0
        else:
            if pending_space:
                result.push_byte(' ')
                pending_space = false
            result.push_byte(b)
        i += 1
    return result


function is_identifier(text: str) -> bool:
    if text.len == 0:
        return false
    let first = text.byte_at(0)
    if not ((first >= 'A' and first <= 'Z') or (first >= 'a' and first <= 'z') or first == '_'):
        return false
    var i: ptr_uint = 1
    while i < text.len:
        if not is_ident_byte(text.byte_at(i)):
            return false
        i += 1
    return true

## The last whitespace-separated token (`struct foo` -> `foo`).

function last_token(text: str) -> str:
    var end = text.len
    while end > 0 and text.byte_at(end - 1) == ' ':
        end -= 1
    var start = end
    while start > 0 and text.byte_at(start - 1) != ' ':
        start -= 1
    return text.slice(start, end - start)

struct TrimmedToken:
    token: str
    rest: str

## Strip one trailing nullability qualifier (the host's
## `extract_top_level_nullability` suffix match).

function strip_trailing_nullability(text: str) -> Option[TrimmedToken]:
    var t = text
    while t.len > 0 and t.byte_at(t.len - 1) == ' ':
        t = t.slice(0, t.len - 1)
    var candidates = vec.Vec[str].create()
    defer: candidates.release()
    candidates.push("_Nullable")
    candidates.push("_Nonnull")
    candidates.push("_Null_unspecified")
    candidates.push("_Nullable_result")
    var i: ptr_uint = 0
    while i < candidates.len():
        let cp = candidates.get(i) else:
            break
        let candidate = unsafe: read(cp)
        i += 1
        if t.len < candidate.len:
            continue
        if not t.slice(t.len - candidate.len, candidate.len).equal(candidate):
            continue
        var at = t.len - candidate.len
        while at > 0 and t.byte_at(at - 1) == ' ':
            at -= 1
        return Option[TrimmedToken].some(value = TrimmedToken(token = candidate, rest = t.slice(0, at)))
    return Option[TrimmedToken].none

struct NullabilitySplit:
    text: str
    nullable: bool


function extract_top_level_nullability(qual_type: str) -> NullabilitySplit:
    var text = qual_type
    var nullable = false
    while true:
        match strip_trailing_nullability(text):
            Option.some as trimmed:
                if trimmed.value.token.equal("_Nullable") or trimmed.value.token.equal("_Nullable_result"):
                    nullable = true
                text = trimmed.value.rest
            Option.none:
                break
    return NullabilitySplit(text = text, nullable = nullable)


function apply_nullability(mapped: ref[string.String], nullable: bool) -> void:
    if not nullable:
        return
    let text = read(mapped).as_str()
    if text.len > 0 and text.byte_at(text.len - 1) == '?':
        return
    read(mapped).push_byte('?')


function array_type_check(qual_type: str) -> bool:
    if qual_type.len < 3 or qual_type.byte_at(qual_type.len - 1) != ']':
        return false
    var i = qual_type.len - 2
    while i > 0 and qual_type.byte_at(i) >= '0' and qual_type.byte_at(i) <= '9':
        i -= 1
    return qual_type.byte_at(i) == '['


function map_array_type(qual_type: str, opts: ref[BindgenOptions]) -> string.String:
    if not array_type_check(qual_type):
        return map_fail()
    var open = qual_type.len - 1
    while open > 0 and qual_type.byte_at(open) != '[':
        open -= 1
    var length: ptr_uint = 0
    var i = open + 1
    while i < qual_type.len - 1:
        let b = qual_type.byte_at(i)
        if b < '0' or b > '9':
            return map_fail()
        length = length * 10 + ptr_uint<-(b - '0')
        i += 1
    var element = map_type(qual_type.slice(0, open), opts)
    defer: element.release()
    if bindgen_map_failed:
        return string.String.create()
    var rendered = string.String.from_str("array[")
    rendered.append(element.as_str())
    rendered.append(", ")
    rendered.append(uint_to_str(length))
    rendered.append("]")
    return rendered


function va_list_pointer_check(qual_type: str) -> bool:
    var stripped = strip_cv_tokens(qual_type)
    let text = stripped.as_str()
    let result = text.equal("struct __va_list_tag *") or text.equal("__va_list_tag *")
    stripped.release()
    return result


function c_string_pointer_check(qual_type: str) -> bool:
    if qual_type.len == 0 or qual_type.byte_at(qual_type.len - 1) != '*':
        return false
    var end = qual_type.len - 1
    while end > 0 and qual_type.byte_at(end - 1) == ' ':
        end -= 1
    let pointee = qual_type.slice(0, end)
    var unqualified = strip_cv_tokens(pointee)
    let result = unqualified.as_str().equal("char") and has_cv_token(pointee, "const")
    unqualified.release()
    return result


function function_type_typedef_check(qual_type: str) -> bool:
    let state = bindgen_state else:
        return false
    var stripped = strip_cv_tokens(qual_type)
    defer: stripped.release()
    var i: ptr_uint = 0
    while i < unsafe: read(state).function_type_typedef_names.len():
        let entry = unsafe: read(state).function_type_typedef_names.get(i) else:
            break
        if unsafe: read(entry).as_str().equal(stripped.as_str()):
            return true
        i += 1
    return false


function matching_open_paren_index(source: str, close_index: ptr_uint) -> Option[ptr_uint]:
    var depth: long = 0
    var index: long = long<-close_index
    while index >= 0:
        let b = source.byte_at(ptr_uint<-index)
        if b == ')':
            depth += 1
        else if b == '(':
            depth -= 1
            if depth == 0:
                return Option[ptr_uint].some(value = ptr_uint<-index)
        index -= 1
    return Option[ptr_uint].none

struct FunctionPointerSignature:
    return_type_source: str
    declarator_source: str
    params_source: str


function parse_function_pointer_signature(qual_type: str) -> Option[FunctionPointerSignature]:
    let source = str_strip(qual_type)
    if source.len == 0 or source.byte_at(source.len - 1) != ')':
        return Option[FunctionPointerSignature].none
    let params_start = matching_open_paren_index(source, source.len - 1) else:
        return Option[FunctionPointerSignature].none
    if params_start == 0:
        return Option[FunctionPointerSignature].none
    let prefix = str_strip(source.slice(0, params_start))
    if prefix.len == 0 or prefix.byte_at(prefix.len - 1) != ')':
        return Option[FunctionPointerSignature].none
    let declarator_start = matching_open_paren_index(prefix, prefix.len - 1) else:
        return Option[FunctionPointerSignature].none
    if declarator_start == 0:
        return Option[FunctionPointerSignature].none
    let return_type_source = str_strip(prefix.slice(0, declarator_start))
    if return_type_source.len == 0:
        return Option[FunctionPointerSignature].none
    return Option[FunctionPointerSignature].some(value = FunctionPointerSignature(
        return_type_source = return_type_source,
        declarator_source = str_strip(prefix.slice(declarator_start + 1, prefix.len - 1 - declarator_start - 1)),
        params_source = source.slice(params_start + 1, source.len - 1 - params_start - 1),
    ))


function function_pointer_type_check(qual_type: str) -> bool:
    match parse_function_pointer_signature(qual_type):
        Option.none:
            return false
        Option.some as signature:
            var text = signature.value.declarator_source
            var i: ptr_uint = 0
            while i < text.len:
                if text.byte_at(i) == '*':
                    return true
                i += 1
            return false


function split_top_level_csv(source: str) -> vec.Vec[str]:
    var parts = vec.Vec[str].create()
    var start: ptr_uint = 0
    var depth: long = 0
    var i: ptr_uint = 0
    while i < source.len:
        let b = source.byte_at(i)
        if b == '(' or b == '[':
            depth += 1
        else if b == ')' or b == ']':
            if depth > 0:
                depth -= 1
        else if b == ',' and depth == 0:
            parts.push(str_strip(source.slice(start, i - start)))
            start = i + 1
        i += 1
    let tail = str_strip(source.slice(start, source.len - start))
    if tail.len > 0:
        parts.push(tail)
    return parts


function function_params_from_source(params_source: str, opts: ref[BindgenOptions]) -> string.String:
    var rendered = string.String.create()
    var params = split_top_level_csv(params_source)
    defer: params.release()
    if params.len() == 0:
        return rendered
    if params.len() == 1:
        let only = params.get(0) else:
            return rendered
        var stripped = strip_cv_tokens(unsafe: read(only))
        let is_void = stripped.as_str().equal("void")
        stripped.release()
        if is_void:
            return rendered
    var index: ptr_uint = 0
    while index < params.len():
        let entry = params.get(index) else:
            break
        if index > 0:
            rendered.append(", ")
        rendered.append("arg")
        rendered.append(uint_to_str(index))
        rendered.append(": ")
        var mapped = map_type(unsafe: read(entry), opts)
        if bindgen_map_failed:
            mapped.release()
            rendered.release()
            return map_fail()
        rendered.append(mapped.as_str())
        mapped.release()
        index += 1
    return rendered


function build_function_type(
    return_type_source: str,
    params_source: str,
    nullable: bool,
    opts: ref[BindgenOptions]
) -> string.String:
    var return_type = map_type(return_type_source, opts)
    defer: return_type.release()
    var params = function_params_from_source(params_source, opts)
    defer: params.release()
    if bindgen_map_failed:
        return string.String.create()
    var rendered = string.String.from_str("fn(")
    rendered.append(params.as_str())
    rendered.append(") -> ")
    rendered.append(return_type.as_str())
    apply_nullability(ref_of(rendered), nullable)
    return rendered


function map_function_pointer_type(qual_type: str, opts: ref[BindgenOptions]) -> string.String:
    let signature = parse_function_pointer_signature(qual_type) else:
        return map_fail()
    let declarator = signature.declarator_source

    # `void (*)(...)` and pointer-wrapped variants such as `void (**)(...)`.
    var depth: ptr_uint = 0
    var at: ptr_uint = 0
    var qualifier_token = ""
    var simple = true
    while at < declarator.len:
        let b = declarator.byte_at(at)
        if b == '*':
            depth += 1
            at += 1
        else if b == ' ':
            at += 1
        else:
            var start = at
            while at < declarator.len and declarator.byte_at(at) != ' ':
                at += 1
            qualifier_token = declarator.slice(start, at - start)
            while at < declarator.len and declarator.byte_at(at) == ' ':
                at += 1
            if at < declarator.len:
                simple = false
    if simple and depth > 0:
        let nullable = qualifier_token.equal("_Nullable") or qualifier_token.equal("_Nullable_result")
        var function_type = build_function_type(signature.return_type_source, signature.params_source, nullable, opts)
        if bindgen_map_failed:
            function_type.release()
            return string.String.create()
        var wrapped = function_type
        var level: ptr_uint = 1
        while level < depth:
            var outer = string.String.from_str("ptr[")
            outer.append(wrapped.as_str())
            outer.append("]")
            if level > 1:
                wrapped.release()
            wrapped = outer
            level += 1
        return wrapped

    # `void (*(*)(...))(...)`: a function pointer returning a function pointer.
    if depth == 0 or declarator.len == 0 or declarator.byte_at(0) != '*':
        return map_fail()
    var scan: ptr_uint = 1
    while scan < declarator.len and declarator.byte_at(scan) == ' ':
        scan += 1
    var outer_token = ""
    if scan < declarator.len and declarator.byte_at(scan) != '(':
        var start = scan
        while scan < declarator.len and declarator.byte_at(scan) != ' ' and declarator.byte_at(scan) != '(':
            scan += 1
        outer_token = declarator.slice(start, scan - start)
        while scan < declarator.len and declarator.byte_at(scan) == ' ':
            scan += 1
    if scan >= declarator.len or declarator.byte_at(scan) != '(':
        return map_fail()
    scan += 1
    while scan < declarator.len and declarator.byte_at(scan) == ' ':
        scan += 1
    if scan >= declarator.len or declarator.byte_at(scan) != '*':
        return map_fail()
    scan += 1
    while scan < declarator.len and declarator.byte_at(scan) == ' ':
        scan += 1
    var returned_token = ""
    if scan < declarator.len and declarator.byte_at(scan) != ')':
        var start = scan
        while scan < declarator.len and declarator.byte_at(scan) != ' ' and declarator.byte_at(scan) != ')':
            scan += 1
        returned_token = declarator.slice(start, scan - start)
        while scan < declarator.len and declarator.byte_at(scan) == ' ':
            scan += 1
    if scan >= declarator.len or declarator.byte_at(scan) != ')':
        return map_fail()
    scan += 1
    while scan < declarator.len and declarator.byte_at(scan) == ' ':
        scan += 1
    if scan >= declarator.len or declarator.byte_at(scan) != '(':
        return map_fail()
    let outer_params = declarator.slice(scan + 1, declarator.len - 1 - scan - 1)
    let returned_nullable = returned_token.equal("_Nullable") or returned_token.equal("_Nullable_result")
    var returned_fn = build_function_type(
        signature.return_type_source,
        signature.params_source,
        returned_nullable,
        opts
    )
    defer: returned_fn.release()
    var outer_params_text = function_params_from_source(outer_params, opts)
    defer: outer_params_text.release()
    if bindgen_map_failed:
        return string.String.create()
    var rendered = string.String.from_str("fn(")
    rendered.append(outer_params_text.as_str())
    rendered.append(") -> ")
    rendered.append(returned_fn.as_str())
    apply_nullability(ref_of(rendered), outer_token.equal("_Nullable") or outer_token.equal("_Nullable_result"))
    return rendered


function standard_typedef_primitive(unqualified: str) -> string.String:
    if unqualified.equal("size_t"):
        return string.String.from_str("ptr_uint")
    if unqualified.equal("ssize_t") or unqualified.equal("ptrdiff_t"):
        return string.String.from_str("ptr_int")
    if unqualified.equal("wchar_t"):
        return string.String.from_str("int")
    return integer_typedef_primitive(unqualified)

## The host's `integer_typedef_primitive`: `(u_?)?int(8|16|32|64)_t` with an
## optional `__` prefix.

function integer_typedef_primitive(unqualified: str) -> string.String:
    var at: ptr_uint = 0
    if at + 2 <= unqualified.len and unqualified.slice(at, 2).equal("__"):
        at += 2
    var unsigned = false
    if at < unqualified.len and unqualified.byte_at(at) == 'u':
        unsigned = true
        at += 1
        if at < unqualified.len and unqualified.byte_at(at) == '_':
            at += 1
    if at + 3 > unqualified.len or not unqualified.slice(at, 3).equal("int"):
        return string.String.create()
    at += 3
    var width: ptr_uint = 0
    let width_start = at
    while at < unqualified.len and unqualified.byte_at(at) >= '0' and unqualified.byte_at(at) <= '9':
        width = width * 10 + ptr_uint<-(unqualified.byte_at(at) - '0')
        at += 1
    if at == width_start:
        return string.String.create()
    if at + 2 != unqualified.len or not unqualified.slice(at, 2).equal("_t"):
        return string.String.create()
    var rendered_name = ""
    if unsigned:
        if width == 8:
            rendered_name = "ubyte"
        else if width == 16:
            rendered_name = "ushort"
        else if width == 32:
            rendered_name = "uint"
        else if width == 64:
            rendered_name = "ulong"
    else:
        if width == 8:
            rendered_name = "byte"
        else if width == 16:
            rendered_name = "short"
        else if width == 32:
            rendered_name = "int"
        else if width == 64:
            rendered_name = "long"
    if rendered_name == "":
        return string.String.create()
    return string.String.from_str(rendered_name)

## The host's `PRIMITIVE_TYPE_MAP` lookup ("" when absent).

function primitive_type_map(unqualified: str) -> str:
    if unqualified.equal("_Bool") or unqualified.equal("bool"): return "bool"
    if unqualified.equal("void"): return "void"
    if unqualified.equal("char"): return "char"
    if unqualified.equal("signed char"): return "byte"
    if unqualified.equal("unsigned char"): return "ubyte"
    if (
        unqualified.equal("short")
        or unqualified.equal("short int")
        or unqualified.equal("signed short")
        or unqualified.equal("signed short int")
    ): return "short"
    if unqualified.equal("unsigned short") or unqualified.equal("unsigned short int"): return "ushort"
    if unqualified.equal("int") or unqualified.equal("signed") or unqualified.equal("signed int"): return "int"
    if unqualified.equal("unsigned") or unqualified.equal("unsigned int"): return "uint"
    if (
        unqualified.equal("long")
        or unqualified.equal("long int")
        or unqualified.equal("signed long")
        or unqualified.equal("signed long int")
    ): return "ptr_int"
    if unqualified.equal("unsigned long") or unqualified.equal("unsigned long int"): return "ptr_uint"
    if (
        unqualified.equal("long long")
        or unqualified.equal("long long int")
        or unqualified.equal("signed long long")
        or unqualified.equal("signed long long int")
    ): return "long"
    if unqualified.equal("unsigned long long") or unqualified.equal("unsigned long long int"): return "ulong"
    if unqualified.equal("float"): return "float"
    if unqualified.equal("double"): return "double"
    return ""


function map_long_type(unqualified: str) -> string.String:
    if (
        unqualified.equal("long")
        or unqualified.equal("long int")
        or unqualified.equal("signed long")
        or unqualified.equal("signed long int")
    ):
        return string.String.from_str("ptr_int")
    if unqualified.equal("unsigned long") or unqualified.equal("unsigned long int"):
        return string.String.from_str("ptr_uint")
    return map_fail()

## The host's `map_c_type`: string-based C type mapping.

function map_type(qual_type: str, opts: ref[BindgenOptions]) -> string.String:
    var normalized_owner = normalize_c_type(qual_type)
    defer: normalized_owner.release()
    let normalized = normalized_owner.as_str()
    if normalized.len == 0:
        return map_fail()
    let split = extract_top_level_nullability(normalized)
    let core = split.text
    var mapped: string.String

    if array_type_check(core):
        mapped = map_array_type(core, opts)
    else if function_pointer_type_check(str_strip(core)):
        mapped = map_function_pointer_type(str_strip(core), opts)
    else:
        var pointer_owner = strip_pointer_suffix_qualifiers(core)
        defer: pointer_owner.release()
        let pointer_candidate = str_strip(pointer_owner.as_str())
        if pointer_candidate.len > 0 and pointer_candidate.byte_at(pointer_candidate.len - 1) == '*':
            if va_list_pointer_check(pointer_candidate):
                synthesize_typedef_dependency("va_list")
                mapped = string.String.from_str("va_list")
            else if c_string_pointer_check(pointer_candidate):
                mapped = string.String.from_str("cstr")
            else:
                var end = pointer_candidate.len - 1
                while end > 0 and pointer_candidate.byte_at(end - 1) == ' ':
                    end -= 1
                let pointee = pointer_candidate.slice(0, end)
                if function_type_typedef_check(pointee):
                    # `Name *` where Name is a function-type typedef is a
                    # function pointer, which the `fn` typedef already is.
                    mapped = map_type(pointee, opts)
                else:
                    var inner = map_type(pointee, opts)
                    defer: inner.release()
                    if bindgen_map_failed:
                        return string.String.create()
                    if top_level_const_qualified(pointee):
                        mapped = string.String.from_str("const_ptr[")
                    else:
                        mapped = string.String.from_str("ptr[")
                    mapped.append(inner.as_str())
                    mapped.append("]")
        else:
            var unqualified_owner = strip_cv_tokens(core)
            defer: unqualified_owner.release()
            let unqualified = unqualified_owner.as_str()
            var primitive = standard_typedef_primitive(unqualified)
            if primitive.as_str().len > 0:
                mapped = primitive
            else:
                primitive.release()
                let primitive_name = primitive_type_map(unqualified)
                if primitive_name != "":
                    mapped = string.String.from_str(primitive_name)
                else:
                    let override = map_get_str(ref_of(read(opts).type_overrides), unqualified)
                    if override != "":
                        mapped = string.String.from_str(override)
                    else if str_has_prefix(unqualified, "long") or str_has_prefix(
                        unqualified,
                        "unsigned long"
                    ) or str_has_prefix(unqualified, "signed long"):
                        mapped = map_long_type(unqualified)
                    else if str_has_prefix(
                        unqualified,
                        "struct "
                    ) or str_has_prefix(unqualified, "union ") or str_has_prefix(unqualified, "enum "):
                        let tag = last_token(unqualified)
                        let tag_override = map_get_str(ref_of(read(opts).type_overrides), tag)
                        if tag_override != "":
                            mapped = string.String.from_str(tag_override)
                        else if str_has_prefix(unqualified, "struct ") or str_has_prefix(unqualified, "union "):
                            mapped = record_name_for(unqualified, opts)
                        else:
                            mapped = enum_name_for(unqualified)
                    else if is_identifier(unqualified):
                        if known_generated_type_name(unqualified):
                            mapped = string.String.from_str(visible_type_name(unqualified, opts))
                        else:
                            mapped = map_fail()
                    else:
                        mapped = map_fail()

    if bindgen_map_failed:
        return string.String.create()
    apply_nullability(ref_of(mapped), split.nullable)
    return mapped

## The first TypedefType name in a node's type subtree (the host's
## `typedef_name_from_type_node`).

function typedef_name_from_type_node(node: ptr[json.Object]) -> str:
    unsafe:
        var queue = vec.Vec[ptr[json.Object]].create()
        defer: queue.release()
        queue.push(node)
        var head: ptr_uint = 0
        while head < queue.len():
            let current_ptr = queue.get(head) else:
                break
            head += 1
            let current = read(current_ptr)
            let kind = jget_str(current, "kind")
            if kind.equal("TypedefType"):
                let decl = current.get_object("decl")
                if decl != null:
                    let name = jget_str(decl, "name")
                    if name != "" and not name.equal("__builtin_va_list"):
                        return name
            let children = jget_inner(current)
            if children != null:
                var i: ptr_uint = 0
                while true:
                    let child_ptr = read(children).get(i) else:
                        break
                    let child = read(child_ptr).as_object()
                    if child != null:
                        queue.push(child)
                    i += 1
    return ""


function extract_function_proto(node: ptr[json.Object]) -> ptr[json.Object]?:
    unsafe:
        var queue = vec.Vec[ptr[json.Object]].create()
        defer: queue.release()
        queue.push(node)
        var head: ptr_uint = 0
        while head < queue.len():
            let current_ptr = queue.get(head) else:
                break
            head += 1
            let current = read(current_ptr)
            if jget_str(current, "kind").equal("FunctionProtoType"):
                return read(current_ptr)
            let children = jget_inner(current)
            if children != null:
                var i: ptr_uint = 0
                while true:
                    let child_ptr = read(children).get(i) else:
                        break
                    let child = read(child_ptr).as_object()
                    if child != null:
                        queue.push(child)
                    i += 1
    return null


function function_pointer_surface_nullability(qual_type: str) -> bool:
    var normalized_owner = normalize_c_type(qual_type)
    defer: normalized_owner.release()
    let normalized = normalized_owner.as_str()
    var i: ptr_uint = 0
    while i + 1 < normalized.len:
        if normalized.byte_at(i) == '(' and normalized.byte_at(i + 1) == '*':
            var at = i + 2
            while at < normalized.len and normalized.byte_at(at) == ' ':
                at += 1
            var start = at
            while at < normalized.len and normalized.byte_at(at) != ' ' and normalized.byte_at(at) != ')':
                at += 1
            if at > start:
                let token = normalized.slice(start, at - start)
                if token.equal("_Nullable") or token.equal("_Nullable_result"):
                    return true
        i += 1
    return false


function map_function_proto_node(proto: ptr[json.Object], opts: ref[BindgenOptions]) -> string.String:
    unsafe:
        let children = jget_inner(proto)
        if children == null or read(children).len() == 0:
            return map_fail()
        let return_node_ptr = read(children).get(0) else:
            return map_fail()
        let return_node = read(return_node_ptr).as_object() else:
            return map_fail()
        var return_type = map_type_node(return_node, opts)
        defer: return_type.release()
        var rendered = string.String.from_str("fn(")
        var index: ptr_uint = 1
        var emitted: ptr_uint = 0
        var only_void = false
        if read(children).len() == 2:
            let param_ptr = read(children).get(1)
            if param_ptr != null:
                let param = read(param_ptr).as_object()
                if param != null:
                    var void_owner = normalize_c_type(type_qual_text(param, false))
                    only_void = jget_str(param, "kind").equal("BuiltinType") and void_owner.as_str().equal("void")
                    void_owner.release()
        if not only_void:
            while index < read(children).len():
                let param_ptr = read(children).get(index) else:
                    break
                let param = read(param_ptr).as_object() else:
                    return map_fail()
                index += 1
                if emitted > 0:
                    rendered.append(", ")
                rendered.append("arg")
                rendered.append(uint_to_str(emitted))
                rendered.append(": ")
                var param_type = map_type_node(param, opts)
                defer: param_type.release()
                if bindgen_map_failed:
                    rendered.release()
                    return string.String.create()
                rendered.append(param_type.as_str())
                emitted += 1
        if bindgen_map_failed:
            rendered.release()
            return string.String.create()
        rendered.append(") -> ")
        rendered.append(return_type.as_str())
        return rendered


function direct_typedef_surface(node: ptr[json.Object], alias_name: str) -> bool:
    unsafe:
        let tp = read(node).get("type")
        if tp == null:
            return false
        let to = read(tp).as_object() else:
            return false
        var spelled_owner = normalize_c_type(jget_str(to, "qualType"))
        defer: spelled_owner.release()
        var stripped = strip_cv_tokens(spelled_owner.as_str())
        defer: stripped.release()
        return stripped.as_str().equal(alias_name)


function preserve_typedef_name(name: str) -> bool:
    if name.equal("va_list"):
        return true
    let state = bindgen_state else:
        return false
    var i: ptr_uint = 0
    while i < unsafe: read(state).visible_typedef_names.len():
        let entry = unsafe: read(state).visible_typedef_names.get(i) else:
            break
        if unsafe: read(entry).as_str().equal(name):
            return true
        i += 1
    return false


function map_type_node(node: ptr[json.Object], opts: ref[BindgenOptions]) -> string.String:
    unsafe:
        let alias_name = typedef_name_from_type_node(node)
        if alias_name != "":
            let alias_override = map_get_str(ref_of(read(opts).type_overrides), alias_name)
            if alias_override != "":
                return string.String.from_str(alias_override)
            if preserve_typedef_name(alias_name) and direct_typedef_surface(node, alias_name):
                synthesize_typedef_dependency(alias_name)
                return string.String.from_str(visible_type_name(alias_name, opts))

        let qual_type = type_qual_text(node, true)
        if function_pointer_type_check(qual_type):
            let proto = extract_function_proto(node)
            if proto != null:
                var mapped_proto = map_function_proto_node(proto, opts)
                apply_nullability(ref_of(mapped_proto), function_pointer_surface_nullability(qual_type))
                return mapped_proto

        return map_type(qual_type, opts)

# =============================================================================
#  Keyword escaping
# =============================================================================

function is_keyword(name: str) -> bool:
    return name == "align_of" or name == "and" or name == "as" or name == "async" or name == "attribute" or name == "attribute_arg" or name == "attribute_of" or name == "attributes_of" or name == "await" or name == "break" or name == "callable_of" or name == "compiler_flag" or name == "const" or name == "consuming" or name == "continue" or name == "defer" or name == "detach" or name == "dyn" or name == "editable" or name == "else" or name == "emit" or name == "enum" or name == "event" or name == "extending" or name == "external" or name == "false" or name == "field_of" or name == "fields_of" or name == "flags" or name == "fn" or name == "for" or name == "foreign" or name == "function" or name == "gather" or name == "has_attribute" or name == "if" or name == "implements" or name == "import" or name == "in" or name == "include" or name == "inline" or name == "inout" or name == "interface" or name == "is" or name == "let" or name == "link" or name == "match" or name == "members_of" or name == "module" or name == "not" or name == "null" or name == "offset_of" or name == "opaque" or name == "or" or name == "out" or name == "parallel" or name == "pass" or name == "proc" or name == "public" or name == "return" or name == "size_of" or name == "static" or name == "static_assert" or name == "struct" or name == "true" or name == "type" or name == "union" or name == "unsafe" or name == "var" or name == "variant" or name == "when" or name == "while" or name == "Option" or name == "Result" or name == "bool" or name == "byte" or name == "char" or name == "cstr" or name == "double" or name == "float" or name == "int" or name == "ivec2" or name == "ivec3" or name == "ivec4" or name == "long" or name == "mat3" or name == "mat4" or name == "ptr_int" or name == "ptr_uint" or name == "quat" or name == "short" or name == "str" or name == "ubyte" or name == "uint" or name == "ulong" or name == "ushort" or name == "vec2" or name == "vec3" or name == "vec4" or name == "void"

# =============================================================================
#  Declaration types
# =============================================================================

## One selected declaration (the host's post-selection declaration hash).

struct CDecl:
    kind: string.String
    ## The original C name (functions, typedefs, consts); records use linkage.
    c_name: string.String
    ## The visible Milk Tea name (before `emitted_name` stripping).
    mt_name: string.String
    ## The record's C linkage name (`struct X`, or its typedef alias).
    linkage: string.String
    ## The mapped type: const type, typedef target, enum backing qual type, or
    ## the raw function signature (used by the nullable report).
    qual_type: string.String
    ## A function's mapped return type.
    return_type: string.String
    is_complete: bool
    members: vec.Vec[CMember]
    param_names: vec.Vec[string.String]
    param_types: vec.Vec[string.String]
    is_variadic: bool
    ## A `const` declaration's lowered initializer.
    value_text: string.String
    ## The clang AST node for aggregates/enums.
    node: ptr[json.Object]?
    ## The node's position in the extracted top-level list.
    index: ptr_uint

struct CMember:
    ename: str
    evalue: string.String

## A discovered declaration emitted before the selected ones (the host's
## `@synthetic_declarations`).

struct SyntheticDecl:
    kind: string.String
    name: string.String
    linkage: string.String
    node: ptr[json.Object]?

## The per-generation state (the host's Generator instance variables).

struct GenState:
    record_aliases: map_mod.Map[str, str]
    record_aliases_by_tag: map_mod.Map[str, str]
    enum_aliases: map_mod.Map[str, str]
    record_visible_names: map_mod.Map[str, str]
    enum_visible_names: map_mod.Map[str, str]
    visible_typedef_names: vec.Vec[string.String]
    function_type_typedef_names: vec.Vec[string.String]
    referenceable: map_mod.Map[str, ptr[json.Object]]
    referenceable_by_id: map_mod.Map[str, ptr[json.Object]]
    aggregate_declarations: map_mod.Map[str, ptr[json.Object]]
    synthetics: vec.Vec[SyntheticDecl]

var bindgen_state: ptr[GenState]? = null
var bindgen_map_failed: bool = false

# =============================================================================
#  AST traversal — extracts declarations from clang JSON
# =============================================================================

## The `desugaredQualType` (or `qualType`) of a node's type, the host's
## `type_qual_type`: nullability-annotated spellings keep `qualType`.

function type_qual_text(node: ptr[json.Object], prefer_desugared: bool) -> str:
    unsafe:
        let tp = read(node).get("type")
        if tp == null:
            return ""
        let to = read(tp).as_object() else:
            return ""
        let qt = jget_str(to, "qualType")
        if not prefer_desugared:
            return qt
        if contains_nullability(qt):
            return qt
        let dq = jget_str(to, "desugaredQualType")
        if dq != "":
            return dq
        return qt


function contains_nullability(text: str) -> bool:
    return text.contains_substring("_Nullable") or text.contains_substring("_Nonnull") or text.contains_substring("_Null_unspecified") or text.contains_substring("_Nullable_result")


function str_replace_all(text: str, needle: str, replacement: str) -> string.String:
    var replaced = string.String.create()
    var i: ptr_uint = 0
    while i < text.len:
        if i + needle.len <= text.len and text.slice(i, needle.len).equal(needle):
            replaced.append(replacement)
            i += needle.len
        else:
            replaced.push_byte(text.byte_at(i))
            i += 1
    return replaced

## The module path the tidy formatter sees (`std.c.cjson` -> `std/c/cjson.mt`).

function generated_module_path(module_name: str) -> string.String:
    var slashed = str_replace_all(module_name, ".", "/")
    slashed.append(".mt")
    return slashed


function is_absolute_path(path: str) -> bool:
    return path.len > 0 and path.byte_at(0) == '/'


function absolute_path(path: str) -> string.String:
    if is_absolute_path(path):
        return string.String.from_str(path)
    var cwd = string.String.create()
    match fs.current_directory():
        Result.success as dir:
            cwd.append(dir.value.as_str())
            dir.value.release()
        Result.failure:
            pass
    if cwd.as_str().len > 0:
        cwd.append("/")
    cwd.append(path)
    return cwd

## A JSON path field, expanded like the host's `File.expand_path`.

function node_file(o: ptr[json.Object]?, key: str) -> string.String:
    let op = o else:
        return string.String.create()
    let value = jget_str(op, key)
    if value == "":
        return string.String.create()
    return absolute_path(value)

## True when the path is the header itself or under a tracked path/prefix.
## The macro scan uses the host's `tracked_header_path?`, which does NOT treat
## the generated translation unit as tracked (its `#define`s are user
## configuration, not header constants).

function tracked_macro_file(path: str, header: str, opts: ref[BindgenOptions]) -> bool:
    if path.equal(header):
        return true
    var i: ptr_uint = 0
    while i < read(opts).tracked_header_paths.len():
        let tp = read(opts).tracked_header_paths.get(i) else:
            break
        if path.equal(unsafe: read(tp)):
            return true
        i += 1
    i = 0
    while i < read(opts).tracked_header_prefixes.len():
        let pp = read(opts).tracked_header_prefixes.get(i) else:
            break
        let prefix = unsafe: read(pp)
        if path.equal(prefix) or str_has_prefix(
            path,
            prefix
        ) and path.len > prefix.len and path.byte_at(prefix.len) == '/':
            return true
        i += 1
    return false


function tracked_file(path: str, header: str, tu_path: str, opts: ref[BindgenOptions]) -> bool:
    if path.equal(header) or path.equal(tu_path):
        return true
    var i: ptr_uint = 0
    while i < read(opts).tracked_header_paths.len():
        let tp = read(opts).tracked_header_paths.get(i) else:
            break
        if path.equal(unsafe: read(tp)):
            return true
        i += 1
    i = 0
    while i < read(opts).tracked_header_prefixes.len():
        let pp = read(opts).tracked_header_prefixes.get(i) else:
            break
        let prefix = unsafe: read(pp)
        if path.equal(prefix) or str_has_prefix(
            path,
            prefix
        ) and path.len > prefix.len and path.byte_at(prefix.len) == '/':
            return true
        i += 1
    return false

## The host's `node_from_header?`: any node source file under the header or a
## tracked path counts; when a node carries no source file at all, its
## `includedFrom` file is checked instead (macro-expanded probes).

function node_from_header(node: ptr[json.Object], header: str, tu_path: str, opts: ref[BindgenOptions]) -> bool:
    unsafe:
        var found_file = false
        var tracked = false
        let loc = read(node).get_object("loc")
        if loc != null:
            var lf = node_file(loc, "file")
            if lf.as_str().len > 0:
                found_file = true
                if tracked_file(lf.as_str(), header, tu_path, opts):
                    tracked = true
            lf.release()
            let sp = read(loc).get_object("spellingLoc")
            if sp != null:
                var sf = node_file(sp, "file")
                if sf.as_str().len > 0:
                    found_file = true
                    if tracked_file(sf.as_str(), header, tu_path, opts):
                        tracked = true
                sf.release()
            let ex = read(loc).get_object("expansionLoc")
            if ex != null:
                var ef = node_file(ex, "file")
                if ef.as_str().len > 0:
                    found_file = true
                    if tracked_file(ef.as_str(), header, tu_path, opts):
                        tracked = true
                ef.release()
        let range = read(node).get_object("range")
        if range != null:
            found_file = scan_range_files(range, header, tu_path, opts, found_file, ref_of(tracked))
        if tracked:
            return true
        if found_file:
            return false
        # No source file: use the include provenance.
        if loc != null:
            let inc = read(loc).get_object("includedFrom")
            if inc != null:
                var inf = node_file(inc, "file")
                let hit = inf.as_str().len > 0 and tracked_file(inf.as_str(), header, tu_path, opts)
                inf.release()
                if hit:
                    return true
        return false

## Scan a range node's begin/end (and their spelling/expansion) files.

function scan_range_files(
    range: ptr[json.Object],
    header: str,
    tu_path: str,
    opts: ref[BindgenOptions],
    found_base: bool,
    tracked: ref[bool]
) -> bool:
    unsafe:
        var found = found_base
        var ends = vec.Vec[str].create()
        defer: ends.release()
        ends.push("begin")
        ends.push("end")
        var ei: ptr_uint = 0
        while ei < ends.len():
            let end_name = ends.get(ei) else:
                break
            ei += 1
            let edge = read(range).get_object(unsafe: read(end_name)) else:
                continue
            var direct = node_file(edge, "file")
            if direct.as_str().len > 0:
                found = true
                if tracked_file(direct.as_str(), header, tu_path, opts):
                    read(tracked) = true
            direct.release()
            let sp = read(edge).get_object("spellingLoc")
            if sp != null:
                var sf = node_file(sp, "file")
                if sf.as_str().len > 0:
                    found = true
                    if tracked_file(sf.as_str(), header, tu_path, opts):
                        read(tracked) = true
                sf.release()
            let ex = read(edge).get_object("expansionLoc")
            if ex != null:
                var ef = node_file(ex, "file")
                if ef.as_str().len > 0:
                    found = true
                    if tracked_file(ef.as_str(), header, tu_path, opts):
                        read(tracked) = true
                ef.release()
        return found

## The host's `allowed_declaration_name?`.

function allowed_declaration_name(name: str, opts: ref[BindgenOptions]) -> bool:
    if name == "":
        return false
    var i: ptr_uint = 0
    while i < read(opts).excluded_declaration_names.len():
        let ep = read(opts).excluded_declaration_names.get(i) else:
            break
        if name.equal(unsafe: read(ep)):
            return false
        i += 1
    if read(opts).declaration_name_prefixes.len() == 0:
        return true
    i = 0
    while i < read(opts).declaration_name_prefixes.len():
        let pp = read(opts).declaration_name_prefixes.get(i) else:
            break
        if str_has_prefix(name, unsafe: read(pp)):
            return true
        i += 1
    return false

## Does the node contain a child of `kind` (the host's `has_body` test)?

function has_child_kind(node: ptr[json.Object], kind: str) -> bool:
    unsafe:
        let children = jget_inner(node)
        if children == null:
            return false
        var i: ptr_uint = 0
        while true:
            let cvp = read(children).get(i) else:
                break
            let co = read(cvp).as_object()
            if co != null and jget_str(co, "kind").equal(kind):
                return true
            i += 1
    return false


function map_get_str(m: ref[map_mod.Map[str, str]], key: str) -> str:
    let value = m.get(key) else:
        return ""
    return unsafe: read(value)

## The host's `visible_type_name`: a `type_name_overrides` entry renames a C
## type (and every reference to it).

function visible_type_name(name: str, opts: ref[BindgenOptions]) -> str:
    let override = map_get_str(ref_of(read(opts).type_name_overrides), name)
    if override != "":
        return override
    return name

## The host's `emitted_name`: optionally strip a leading-underscore prefix.

function emitted_name(name: str, opts: ref[BindgenOptions]) -> str:
    if not read(opts).strip_leading_underscores:
        return name
    var i: ptr_uint = 0
    while i < name.len and name.byte_at(i) == '_':
        i += 1
    return name.slice(i, name.len - i)


function synthetic_exists(name: str) -> bool:
    let state = bindgen_state else:
        return false
    var i: ptr_uint = 0
    while i < unsafe: read(state).synthetics.len():
        let entry = unsafe: read(state).synthetics.get(i) else:
            break
        if unsafe: read(entry).name.as_str().equal(name):
            return true
        i += 1
    return false

## The host's `synthesize_typedef_dependency`: `va_list`/`__va_list_tag`
## become opaque declarations.

function synthesize_typedef_dependency(name: str) -> void:
    let state = bindgen_state else:
        return
    if name.equal("va_list"):
        if synthetic_exists("va_list"):
            return
        unsafe: read(state).synthetics.push(SyntheticDecl(
            kind = string.String.from_str("opaque"),
            name = string.String.from_str("va_list"),
            linkage = string.String.from_str("va_list"),
            node = null,
        ))
    else if name.equal("__va_list_tag"):
        if synthetic_exists("__va_list_tag"):
            return
        unsafe: read(state).synthetics.push(SyntheticDecl(
            kind = string.String.from_str("opaque"),
            name = string.String.from_str("__va_list_tag"),
            linkage = string.String.from_str("__va_list_tag"),
            node = null,
        ))

## The host's `record_c_name`: the typedef alias for a record, else its tag.

function record_c_name(node: ptr[json.Object]) -> str:
    let state = bindgen_state else:
        return ""
    let node_id = jget_str(node, "id")
    if node_id != "":
        let alias = unsafe: map_get_str(ref_of(read(state).record_aliases), node_id)
        if alias != "":
            return alias
    let tag_name = jget_str(node, "name")
    if tag_name != "":
        let by_tag = unsafe: map_get_str(ref_of(read(state).record_aliases_by_tag), tag_name)
        if by_tag != "":
            return by_tag
    let tag = jget_str(node, "tagUsed")
    if tag_name != "":
        var joined = string.String.create()
        joined.append(tag)
        joined.append(" ")
        joined.append(tag_name)
        return joined.as_str()
    return ""

## The host's `synthesize_record_dependency`: a referenced `struct X`/`union X`
## gets an emitted declaration (full when a definition exists, opaque otherwise).

function synthesize_record_dependency(unqualified: str, opts: ref[BindgenOptions]) -> void:
    let state = bindgen_state else:
        return
    var kind = ""
    if str_has_prefix(unqualified, "struct "):
        kind = "struct"
    else if str_has_prefix(unqualified, "union "):
        kind = "union"
    else:
        return
    let tag_name = last_token(unqualified)
    if tag_name == "":
        return
    let existing = unsafe: map_get_str(ref_of(read(state).record_visible_names), tag_name)
    if existing != "":
        return
    let record_entry = unsafe: read(state).referenceable.get(tag_name)
    var record_node: ptr[json.Object]? = null
    if record_entry != null:
        record_node = unsafe: read(record_entry)
    var original_name = tag_name
    if record_node != null:
        let node_id = jget_str(record_node, "id")
        let alias = unsafe: map_get_str(ref_of(read(state).record_aliases), node_id)
        if alias != "":
            original_name = alias
    let visible = visible_type_name(original_name, opts)
    if synthetic_exists(visible):
        return
    unsafe:
        read(state).record_visible_names.set(tag_name, visible)
        read(state).record_visible_names.set(visible, visible)
    if record_node != null and record_complete_definition(record_node):
        unsafe:
            read(state).synthetics.push(SyntheticDecl(
                kind = string.String.from_str(jget_str(record_node, "tagUsed")),
                name = string.String.from_str(visible),
                linkage = string.String.create(),
                node = record_node,
            ))
            read(state).aggregate_declarations.set(visible, record_node)
        return
    var linkage = string.String.create()
    linkage.append(kind)
    linkage.append(" ")
    linkage.append(tag_name)
    unsafe: read(state).synthetics.push(SyntheticDecl(
        kind = string.String.from_str("opaque"),
        name = string.String.from_str(visible),
        linkage = linkage,
        node = null,
    ))


function record_name_for(unqualified: str, opts: ref[BindgenOptions]) -> string.String:
    synthesize_record_dependency(unqualified, opts)
    let state = bindgen_state else:
        return string.String.from_str(last_token(unqualified))
    let tag_name = last_token(unqualified)
    let visible = unsafe: map_get_str(ref_of(read(state).record_visible_names), tag_name)
    if visible != "":
        return string.String.from_str(visible)
    return string.String.from_str(tag_name)


function enum_name_for(unqualified: str) -> string.String:
    let state = bindgen_state else:
        return string.String.from_str(last_token(unqualified))
    let tag_name = last_token(unqualified)
    let visible = unsafe: map_get_str(ref_of(read(state).enum_visible_names), tag_name)
    if visible != "":
        return string.String.from_str(visible)
    return string.String.from_str(tag_name)

## The host's `known_generated_type_name?`.

function known_generated_type_name(name: str) -> bool:
    let primitive = primitive_type_map(name)
    if primitive != "":
        return true
    let state = bindgen_state else:
        return false
    var i: ptr_uint = 0
    while i < unsafe: read(state).visible_typedef_names.len():
        let entry = unsafe: read(state).visible_typedef_names.get(i) else:
            break
        if unsafe: read(entry).as_str().equal(name):
            return true
        i += 1
    var values = unsafe: read(state).record_visible_names.values()
    while true:
        let value = values.next() else:
            break
        if unsafe: read(value).equal(name):
            return true
    var enum_values = unsafe: read(state).enum_visible_names.values()
    while true:
        let value = enum_values.next() else:
            break
        if unsafe: read(value).equal(name):
            return true
    return synthetic_exists(name)


function unresolved_alias_target(alias_name: str, mapped_text: str, opts: ref[BindgenOptions]) -> bool:
    if mapped_text.len < 2 or not str_has_prefix(mapped_text, "__"):
        return false
    var i: ptr_uint = 0
    while i < mapped_text.len:
        let b = mapped_text.byte_at(i)
        if not is_ident_byte(b):
            return false
        i += 1
    return not known_generated_type_name(mapped_text)

struct TagTarget:
    id: str
    kind: str
    name: str


function typedef_tag_target(node: ptr[json.Object]) -> Option[TagTarget]:
    unsafe:
        let inner = jget_inner(node)
        if inner == null:
            return Option[TagTarget].none
        var i: ptr_uint = 0
        while true:
            let icvp = read(inner).get(i) else:
                break
            let ico = read(icvp).as_object()
            if ico != null:
                let ik = jget_str(ico, "kind")
                if ik.equal("RecordType") or ik.equal("EnumType"):
                    let decl_vp = read(ico).get("decl")
                    if decl_vp != null:
                        let decl_o = read(decl_vp).as_object()
                        if decl_o != null:
                            return Option[TagTarget].some(value = TagTarget(
                                id = jget_str(decl_o, "id"),
                                kind = jget_str(decl_o, "kind"),
                                name = jget_str(decl_o, "name"),
                            ))
            i += 1
    return Option[TagTarget].none


function safe_param_name(n: string.String) -> string.String:
    if is_keyword(n.as_str()):
        var r = string.String.from_str(n.as_str())
        r.append("_")
        return r
    return string.String.from_str(n.as_str())


function param_type_override(opts: ref[BindgenOptions], function_name: str, parameter_name: str) -> Option[str]:
    if parameter_name == "":
        return Option[str].none
    var params = read(opts).function_param_type_overrides.get(function_name) else:
        return Option[str].none
    let value = unsafe: read(params).get(parameter_name) else:
        return Option[str].none
    return Option[str].some(value = unsafe: read(value))


function function_return_type_override_text(opts: ref[BindgenOptions], function_name: str) -> Option[str]:
    let value = read(opts).function_return_type_overrides.get(function_name) else:
        return Option[str].none
    return Option[str].some(value = unsafe: read(value))

## The host's `field_type_overrides[type][field]`.

function field_type_override(opts: ref[BindgenOptions], type_name: str, field_name: str) -> Option[str]:
    if field_name == "":
        return Option[str].none
    var fields = read(opts).field_type_overrides.get(type_name) else:
        return Option[str].none
    let value = unsafe: read(fields).get(field_name) else:
        return Option[str].none
    return Option[str].some(value = unsafe: read(value))

# =============================================================================
#  Two-phase declaration selection — the host's Generator#generate
# =============================================================================

## The host's `extract_top_level_header_nodes`: the translation unit's direct
## declarations (plus tags owned by a typedef) whose provenance is the header.

function extract_top_level_nodes(
    root: ptr[json.Object],
    opts: ref[BindgenOptions],
    tu_path: str,
    nodes: ref[vec.Vec[ptr[json.Object]]],
    seen_ids: ref[vec.Vec[string.String]]
) -> void:
    unsafe:
        let children = jget_inner(root)
        if children == null:
            return
        var i: ptr_uint = 0
        while true:
            let cvp = read(children).get(i) else:
                break
            let co = read(cvp).as_object()
            if co != null:
                let kind = jget_str(co, "kind")
                if interesting_top_level_kind(kind) and node_from_header(
                    co,
                    read(opts).header_path.as_str(),
                    tu_path,
                    opts
                ):
                    append_unique_node(nodes, seen_ids, co)
                if kind.equal("TypedefDecl"):
                    collect_owned_tag_nodes(co, opts, tu_path, nodes, seen_ids)
            i += 1


function interesting_top_level_kind(kind: str) -> bool:
    return kind.equal("TypedefDecl") or kind.equal("RecordDecl") or kind.equal("EnumDecl") or kind.equal("VarDecl") or kind.equal("FunctionDecl")


function append_unique_node(
    nodes: ref[vec.Vec[ptr[json.Object]]],
    seen_ids: ref[vec.Vec[string.String]],
    node: ptr[json.Object]
) -> void:
    unsafe:
        let node_id = jget_str(node, "id")
        if node_id != "":
            var i: ptr_uint = 0
            while i < seen_ids.len():
                let entry = seen_ids.get(i) else:
                    break
                if read(entry).as_str().equal(node_id):
                    return
                i += 1
            seen_ids.push(string.String.from_str(node_id))
        nodes.push(node)

## The host's `typedef_owned_tag_nodes`: RecordDecl/EnumDecl nodes nested in a
## typedef's type subtree.

function collect_owned_tag_nodes(
    node: ptr[json.Object],
    opts: ref[BindgenOptions],
    tu_path: str,
    nodes: ref[vec.Vec[ptr[json.Object]]],
    seen_ids: ref[vec.Vec[string.String]]
) -> void:
    unsafe:
        let children = jget_inner(node)
        if children == null:
            return
        var i: ptr_uint = 0
        while true:
            let cvp = read(children).get(i) else:
                break
            let co = read(cvp).as_object()
            if co != null:
                let kind = jget_str(co, "kind")
                if kind.equal("RecordDecl") or kind.equal("EnumDecl"):
                    if node_from_header(co, read(opts).header_path.as_str(), tu_path, opts):
                        append_unique_node(nodes, seen_ids, co)
                collect_owned_tag_nodes(co, opts, tu_path, nodes, seen_ids)
            i += 1

## The host's `build_alias_maps`.

function build_alias_maps(nodes: vec.Vec[ptr[json.Object]], state: ref[GenState]) -> void:
    var i: ptr_uint = 0
    while i < nodes.len():
        let node_entry = nodes.get(i) else:
            break
        let node = unsafe: read(node_entry)
        i += 1
        unsafe:
            if not jget_str(node, "kind").equal("TypedefDecl"):
                continue
            match typedef_tag_target(node):
                Option.none:
                    pass
                Option.some as target:
                    let alias_name = jget_str(node, "name")
                    if target.value.kind.equal("RecordDecl"):
                        read(state).record_aliases.set(target.value.id, alias_name)
                        if target.value.name != "":
                            let existing = map_get_str(ref_of(read(state).record_aliases_by_tag), target.value.name)
                            if existing == "":
                                read(state).record_aliases_by_tag.set(target.value.name, alias_name)
                    else if target.value.kind.equal("EnumDecl"):
                        read(state).enum_aliases.set(target.value.id, alias_name)

## The host's `index_referenceable_record_declarations`: every struct/union
## RecordDecl in the AST, by tag name (complete definitions preferred) and id.

function index_referenceable_records(root: ptr[json.Object], state: ref[GenState]) -> void:
    unsafe:
        var queue = vec.Vec[ptr[json.Object]].create()
        defer: queue.release()
        let children = jget_inner(root)
        if children == null:
            return
        var head: ptr_uint = 0
        while head < read(children).len():
            let entry = read(children).get(head) else:
                break
            head += 1
            let node = read(entry).as_object()
            if node != null:
                queue.push(node)
        head = 0
        while head < queue.len():
            let node_ptr = queue.get(head) else:
                break
            head += 1
            let node = read(node_ptr)
            let kind = jget_str(node, "kind")
            if kind.equal("RecordDecl"):
                let tag = jget_str(node, "tagUsed")
                if tag.equal("struct") or tag.equal("union"):
                    let name = jget_str(node, "name")
                    if name != "":
                        let existing_entry = read(state).referenceable.get(name)
                        var replace = existing_entry == null
                        if existing_entry != null:
                            let existing_node = read(existing_entry)
                            replace = not record_complete_definition(existing_node) and record_complete_definition(node)
                        if replace:
                            read(state).referenceable.set(name, node)
                    let node_id = jget_str(node, "id")
                    if node_id != "":
                        read(state).referenceable_by_id.set(node_id, node)
            let inner = jget_inner(node)
            if inner != null:
                var i: ptr_uint = 0
                while true:
                    let entry = read(inner).get(i) else:
                        break
                    let child = read(entry).as_object()
                    if child != null:
                        queue.push(child)
                    i += 1

## The host's `record_complete_definition?`.

function record_complete_definition(node: ptr[json.Object]) -> bool:
    unsafe:
        if read(node).get("completeDefinition") != null:
            return true
        let children = jget_inner(node)
        if children == null:
            return false
        var i: ptr_uint = 0
        while true:
            let entry = read(children).get(i) else:
                break
            let child = read(entry).as_object()
            if child != null and jget_str(child, "kind").equal("FieldDecl"):
                return true
            i += 1
    return false

## The host's `enum_member_values`: explicit values and implicit successors.

function enum_member_list(node: ptr[json.Object]) -> vec.Vec[CMember]:
    var members = vec.Vec[CMember].create()
    unsafe:
        let children = jget_inner(node)
        if children == null:
            return members
        var i: ptr_uint = 0
        var counter: long = 0
        while true:
            let entry = read(children).get(i) else:
                break
            let child = read(entry).as_object()
            if child != null and jget_str(child, "kind").equal("EnumConstantDecl"):
                let name = jget_str(child, "name")
                let explicit_value = find_enum_value(child, name)
                if explicit_value != "":
                    counter = parse_long(explicit_value)
                var rendered = string.String.from_str(long_to_str(counter))
                members.push(CMember(ename = name, evalue = rendered))
                counter += 1
            i += 1
    return members

## The host's `enum_kind`: flags when every non-zero member is a power of two.

function enum_kind(members: vec.Vec[CMember]) -> str:
    var index: ptr_uint = 0
    var any_nonzero = false
    while index < members.len():
        let entry = members.get(index) else:
            break
        let value = unsafe: parse_long(read(entry).evalue.as_str())
        if value != 0:
            any_nonzero = true
            if (value & (value - 1)) != 0:
                return "enum"
        index += 1
    if any_nonzero:
        return "flags"
    return "enum"


function enum_backing_qual_type(node: ptr[json.Object]) -> str:
    unsafe:
        let children = jget_inner(node)
        if children == null:
            return "int"
        var i: ptr_uint = 0
        while true:
            let entry = read(children).get(i) else:
                break
            let child = read(entry).as_object()
            if child != null and jget_str(child, "kind").equal("EnumConstantDecl"):
                let text = type_qual_text(child, false)
                if text != "":
                    return text
            i += 1
    return "int"


function new_decl(kind: str, c_name: str, mt_name: str, index: ptr_uint) -> CDecl:
    return CDecl(
        kind = string.String.from_str(kind),
        c_name = string.String.from_str(c_name),
        mt_name = string.String.from_str(mt_name),
        linkage = string.String.create(),
        qual_type = string.String.create(),
        return_type = string.String.create(),
        is_complete = true,
        members = vec.Vec[CMember].create(),
        param_names = vec.Vec[string.String].create(),
        param_types = vec.Vec[string.String].create(),
        is_variadic = false,
        value_text = string.String.create(),
        node = null,
        index = index,
    )

## The host's `select_record_declarations` plus its typedef projections.

function select_record_declarations(
    nodes: vec.Vec[ptr[json.Object]],
    opts: ref[BindgenOptions],
    state: ref[GenState],
    decls: ref[vec.Vec[CDecl]]
) -> void:
    var selected = map_mod.Map[str, CDecl].create()
    defer: selected.release()
    var selected_order = vec.Vec[string.String].create()
    defer: release_macro_names(ref_of(selected_order))
    var type_aliases = vec.Vec[CDecl].create()
    defer: type_aliases.release()

    var i: ptr_uint = 0
    while i < nodes.len():
        let node_entry = nodes.get(i) else:
            break
        let node = unsafe: read(node_entry)
        let index = i
        i += 1
        unsafe:
            let kind = jget_str(node, "kind")
            var record_node: ptr[json.Object]? = null
            var original_name = ""
            if kind.equal("RecordDecl"):
                record_node = node
                let node_id = jget_str(node, "id")
                original_name = map_get_str(ref_of(read(state).record_aliases), node_id)
                if original_name == "":
                    original_name = jget_str(node, "name")
            else if kind.equal("TypedefDecl"):
                let target = typedef_tag_target(node) else:
                    continue
                if not target.kind.equal("RecordDecl"):
                    continue
                var resolved_entry = read(state).referenceable_by_id.get(target.id)
                if resolved_entry == null and target.name != "":
                    resolved_entry = read(state).referenceable.get(target.name)
                if resolved_entry != null:
                    record_node = read(resolved_entry)
                let node_name = jget_str(node, "name")
                if record_node == null or node_name == "":
                    continue
                let primary_alias = map_get_str(ref_of(read(state).record_aliases), target.id)
                if primary_alias != "" and not primary_alias.equal(node_name) and allowed_declaration_name(
                    node_name,
                    opts
                ):
                    var projection = new_decl("type_alias", node_name, visible_type_name(node_name, opts), index)
                    projection.qual_type = string.String.from_str(visible_type_name(primary_alias, opts))
                    type_aliases.push(projection)
                    continue
                original_name = node_name
            else:
                continue

            let record = record_node else:
                continue
            let tag = jget_str(record, "tagUsed")
            if not (tag.equal("struct") or tag.equal("union")):
                continue
            if original_name == "" or not allowed_declaration_name(original_name, opts):
                continue
            let visible = visible_type_name(original_name, opts)
            let complete = record_complete_definition(record)
            var candidate = new_decl(if complete: tag else: "opaque", original_name, visible, index)
            candidate.is_complete = complete
            candidate.node = record
            candidate.linkage = string.String.from_str(record_c_name(record))
            let existing = selected.get(visible)
            if existing == null:
                selected_order.push(string.String.from_str(visible))
                selected.set(visible, candidate)
            else if read(existing).kind.as_str().equal("opaque") and not candidate.kind.as_str().equal("opaque"):
                selected.set(visible, candidate)

    # Record the visible names and aggregate nodes of the final selection.
    var order_index: ptr_uint = 0
    while order_index < selected_order.len():
        let name_entry = selected_order.get(order_index) else:
            break
        order_index += 1
        let declaration_ptr = selected.get(unsafe: read(name_entry).as_str()) else:
            continue
        let declaration = unsafe: read(declaration_ptr)
        if declaration.node != null:
            let tag_name = jget_str(declaration.node, "name")
            if tag_name != "":
                read(state).record_visible_names.set(tag_name, declaration.mt_name.as_str())
            read(state).record_visible_names.set(declaration.mt_name.as_str(), declaration.mt_name.as_str())
            if declaration.kind.as_str().equal("struct") or declaration.kind.as_str().equal("union"):
                read(state).aggregate_declarations.set(
                    declaration.mt_name.as_str(),
                    unsafe: ptr[json.Object]<-declaration.node
                )
        decls.push(declaration)

    var alias_index: ptr_uint = 0
    while alias_index < type_aliases.len():
        let alias = type_aliases.get(alias_index) else:
            break
        decls.push(unsafe: read(alias))
        alias_index += 1

## The host's `select_enum_declarations`.

function select_enum_declarations(
    nodes: vec.Vec[ptr[json.Object]],
    opts: ref[BindgenOptions],
    state: ref[GenState],
    decls: ref[vec.Vec[CDecl]]
) -> void:
    var selected = map_mod.Map[str, CDecl].create()
    defer: selected.release()
    var selected_order = vec.Vec[string.String].create()
    defer: release_macro_names(ref_of(selected_order))

    var i: ptr_uint = 0
    while i < nodes.len():
        let node_entry = nodes.get(i) else:
            break
        let node = unsafe: read(node_entry)
        let index = i
        i += 1
        unsafe:
            if not jget_str(node, "kind").equal("EnumDecl"):
                continue
            let node_id = jget_str(node, "id")
            var original_name = map_get_str(ref_of(read(state).enum_aliases), node_id)
            if original_name == "":
                original_name = jget_str(node, "name")
            if original_name == "" or not allowed_declaration_name(original_name, opts):
                continue
            let visible = visible_type_name(original_name, opts)
            var candidate = new_decl("enum", original_name, visible, index)
            candidate.node = node
            var members = enum_member_list(node)
            candidate.qual_type = string.String.from_str(enum_backing_qual_type(node))
            let kind_text = enum_kind(members)
            candidate.kind.release()
            candidate.kind = string.String.from_str(kind_text)
            let count = members.len()
            var mi: ptr_uint = 0
            while mi < count:
                let member = members.get(mi) else:
                    break
                candidate.members.push(read(member))
                mi += 1
            if selected.get(visible) == null:
                selected_order.push(string.String.from_str(visible))
            selected.set(visible, candidate)

    var order_index: ptr_uint = 0
    while order_index < selected_order.len():
        let name_entry = selected_order.get(order_index) else:
            break
        order_index += 1
        let declaration_ptr = selected.get(unsafe: read(name_entry).as_str()) else:
            continue
        let declaration = unsafe: read(declaration_ptr)
        if declaration.node != null:
            let tag_name = jget_str(declaration.node, "name")
            if tag_name != "":
                read(state).enum_visible_names.set(tag_name, declaration.mt_name.as_str())
            read(state).enum_visible_names.set(declaration.mt_name.as_str(), declaration.mt_name.as_str())
        decls.push(declaration)

## The host's `select_type_alias_declarations`.

function select_type_alias_declarations(
    nodes: vec.Vec[ptr[json.Object]],
    opts: ref[BindgenOptions],
    decls: ref[vec.Vec[CDecl]]
) -> void:
    var i: ptr_uint = 0
    while i < nodes.len():
        let node_entry = nodes.get(i) else:
            break
        let node = unsafe: read(node_entry)
        let index = i
        i += 1
        unsafe:
            if not jget_str(node, "kind").equal("TypedefDecl"):
                continue
            if typedef_tag_target(node).is_some():
                continue
            let name = jget_str(node, "name")
            if name == "" or not allowed_declaration_name(name, opts):
                continue
            bindgen_map_failed = false
            var mapped: string.String
            if extract_function_proto(node) != null:
                mapped = map_function_pointer_typedef(node, opts)
            else:
                mapped = map_type(type_qual_text(node, true), opts)
            if bindgen_map_failed:
                mapped.release()
                continue
            if name.equal(mapped.as_str()):
                mapped.release()
                continue
            if unresolved_alias_target(name, mapped.as_str(), opts):
                mapped.release()
                continue
            var declaration = new_decl("type_alias", name, visible_type_name(name, opts), index)
            declaration.qual_type = mapped
            decls.push(declaration)


function map_function_pointer_typedef(node: ptr[json.Object], opts: ref[BindgenOptions]) -> string.String:
    let proto = extract_function_proto(node) else:
        return map_fail()
    var mapped = map_function_proto_node(proto, opts)
    if bindgen_map_failed:
        mapped.release()
        return string.String.create()
    apply_nullability(ref_of(mapped), function_pointer_surface_nullability(type_qual_text(node, true)))
    return mapped

## The host's `macro_probe_declaration?` / `constant_name_for`.

function macro_probe_declaration(node: ptr[json.Object]) -> bool:
    return str_has_prefix(jget_str(node, "name"), MACRO_PROBE_PREFIX)


function constant_name_for(node: ptr[json.Object]) -> str:
    let name = jget_str(node, "name")
    if str_has_prefix(name, MACRO_PROBE_PREFIX):
        return name.slice(MACRO_PROBE_PREFIX.len, name.len - MACRO_PROBE_PREFIX.len)
    return name

## The host's `constant_var_decl?`: an initializer plus a top-level qualifier.

function constant_var_decl(node: ptr[json.Object]) -> bool:
    unsafe:
        if read(node).get("init") == null:
            return false
        let qual_type = type_qual_text(node, false)
        var normalized_owner = normalize_c_type(qual_type)
        defer: normalized_owner.release()
        var stripped = strip_cv_tokens(normalized_owner.as_str())
        defer: stripped.release()
        return not stripped.as_str().equal(normalized_owner.as_str())

## The host's `constant_qual_type`.

function constant_qual_type(node: ptr[json.Object]) -> str:
    unsafe:
        let tp = read(node).get("type")
        if tp == null:
            return ""
        let to = read(tp).as_object() else:
            return ""
        let qual_type = jget_str(to, "qualType")
        if macro_probe_declaration(node) and qual_type.contains_substring("typeof"):
            let desugared = jget_str(to, "desugaredQualType")
            if desugared != "":
                return desugared
            return qual_type
        if constant_typedef_alias_aggregate(node):
            let desugared = jget_str(to, "desugaredQualType")
            if desugared != "":
                return desugared
            return qual_type
        return qual_type

## The host's `constant_typedef_alias_aggregate?`.

function constant_typedef_alias_aggregate(node: ptr[json.Object]) -> bool:
    unsafe:
        let tp = read(node).get("type")
        if tp == null:
            return false
        let to = read(tp).as_object() else:
            return false
        let qual_type = jget_str(to, "qualType")
        var spelled_owner = normalize_c_type(qual_type)
        defer: spelled_owner.release()
        var spelled_stripped = strip_cv_tokens(spelled_owner.as_str())
        defer: spelled_stripped.release()
        let spelled = spelled_stripped.as_str()
        if not is_identifier(spelled):
            return false
        let state = bindgen_state else:
            return false
        if read(state).aggregate_declarations.get(spelled) != null:
            return false
        var desugared_owner = normalize_c_type(jget_str(to, "desugaredQualType"))
        defer: desugared_owner.release()
        var desugared_stripped = strip_cv_tokens(desugared_owner.as_str())
        defer: desugared_stripped.release()
        let desugared = desugared_stripped.as_str()
        if desugared == "" or desugared.equal(spelled):
            return false
        return str_has_prefix(desugared, "struct ") or str_has_prefix(desugared, "union ")

## The host's `constant_expression_kind`.

function constant_expression_kind(node: ptr[json.Object]?) -> str:
    var current = node
    while current != null:
        unsafe:
            let kind = jget_str(current, "kind")
            if (
                kind.equal("ImplicitCastExpr")
                or kind.equal("ConstantExpr")
                or kind.equal("CompoundLiteralExpr")
                or kind.equal("ParenExpr")
            ):
                current = first_inner_child(current)
            else:
                return kind
    return ""


function string_literal_macro_compatible_c_type(qual_type: str) -> bool:
    var pointer_owner = strip_pointer_suffix_qualifiers(qual_type)
    defer: pointer_owner.release()
    if c_string_pointer_check(str_strip(pointer_owner.as_str())):
        return true
    let text = str_strip(pointer_owner.as_str())
    if not array_type_check(text):
        return false
    var open = text.len - 1
    while open > 0 and text.byte_at(open) != '[':
        open -= 1
    var element_stripped = strip_cv_tokens(text.slice(0, open))
    defer: element_stripped.release()
    return element_stripped.as_str().equal("char")

## The host's `macro_string_constant_type`: a probe whose initializer is a
## string literal maps through its surface type.

function macro_string_constant_type(node: ptr[json.Object], initializer: ptr[json.Object]?) -> Option[string.String]:
    if not macro_probe_declaration(node):
        return Option[string.String].none
    if not constant_expression_kind(initializer).equal("StringLiteral"):
        return Option[string.String].none
    var normalized_owner = normalize_c_type(constant_qual_type(node))
    defer: normalized_owner.release()
    let split = extract_top_level_nullability(str_strip(normalized_owner.as_str()))
    if string_literal_macro_compatible_c_type(split.text):
        return Option[string.String].some(value = string.String.from_str("cstr"))
    bindgen_map_failed = true
    return Option[string.String].none

## The host's `select_constant_declarations`.

function select_constant_declarations(
    nodes: vec.Vec[ptr[json.Object]],
    opts: ref[BindgenOptions],
    decls: ref[vec.Vec[CDecl]]
) -> void:
    var i: ptr_uint = 0
    while i < nodes.len():
        let node_entry = nodes.get(i) else:
            break
        let node = unsafe: read(node_entry)
        let index = i
        i += 1
        unsafe:
            if not jget_str(node, "kind").equal("VarDecl"):
                continue
            if jget_bool(node, "isInvalid"):
                continue
            if not constant_var_decl(node):
                continue
            let name = constant_name_for(node)
            if name == "" or not allowed_declaration_name(name, opts):
                continue
            bindgen_map_failed = false
            let initializer = first_inner_child(node)
            var type_text: string.String
            match macro_string_constant_type(node, initializer):
                Option.some as declared_type:
                    type_text = declared_type.value
                Option.none:
                    if bindgen_map_failed:
                        continue
                    type_text = map_type(constant_qual_type(node), opts)
            if bindgen_map_failed:
                type_text.release()
                continue
            match lower_constant(initializer, type_text.as_str(), opts):
                Option.none:
                    type_text.release()
                    continue
                Option.some as lowered:
                    var declaration = new_decl("const", name, name, index)
                    declaration.qual_type = type_text
                    declaration.value_text = lowered.value
                    decls.push(declaration)
                    continue


function is_variadic_function(node: ptr[json.Object]) -> bool:
    unsafe:
        return read(node).get("variadic") != null and jget_bool(node, "variadic")

## The host's `select_function_declarations`.

function select_function_declarations(
    nodes: vec.Vec[ptr[json.Object]],
    opts: ref[BindgenOptions],
    decls: ref[vec.Vec[CDecl]]
) -> void:
    var selected = map_mod.Map[str, CDecl].create()
    defer: selected.release()

    var i: ptr_uint = 0
    while i < nodes.len():
        let node_entry = nodes.get(i) else:
            break
        let node = unsafe: read(node_entry)
        let index = i
        i += 1
        unsafe:
            if not jget_str(node, "kind").equal("FunctionDecl"):
                continue
            let storage = jget_str(node, "storageClass")
            let has_body = has_child_kind(node, "CompoundStmt")
            if storage.equal("static") and not read(opts).allow_static_inline_functions:
                continue
            if has_body and not (storage.equal("static") and read(opts).allow_static_inline_functions):
                continue
            let name = jget_str(node, "name")
            if name == "" or not allowed_declaration_name(name, opts):
                continue
            bindgen_map_failed = false
            var declaration = new_decl("function", name, name, index)
            declaration.is_variadic = is_variadic_function(node)
            declaration.qual_type = string.String.from_str(type_qual_text(node, false))

            let children = jget_inner(node)
            var param_index: ptr_uint = 0
            if children != null:
                var child_index: ptr_uint = 0
                while true:
                    let entry = read(children).get(child_index) else:
                        break
                    let child = read(entry).as_object()
                    if child != null and jget_str(child, "kind").equal("ParmVarDecl"):
                        var raw_name = jget_str(child, "name")
                        if raw_name == "":
                            var synthetic = string.String.from_str("arg")
                            synthetic.append(uint_to_str(param_index))
                            declaration.param_names.push(synthetic)
                        else:
                            declaration.param_names.push(safe_param_name(string.String.from_str(raw_name)))
                        match find_param_override(opts.param_overrides.as_span(), name, raw_name):
                            Option.some as policy_type:
                                declaration.param_types.push(string.String.from_str(policy_type.value))
                            Option.none:
                                match param_type_override(opts, name, raw_name):
                                    Option.some as override_type:
                                        declaration.param_types.push(string.String.from_str(override_type.value))
                                    Option.none:
                                        var param_type = map_type_node(child, opts)
                                        if bindgen_map_failed:
                                            param_type.release()
                                            break
                                        declaration.param_types.push(param_type)
                        param_index += 1
                    child_index += 1
            if bindgen_map_failed:
                continue

            match find_type_override(opts.return_overrides.as_span(), name):
                Option.some as policy_type:
                    declaration.return_type = string.String.from_str(policy_type.value)
                Option.none:
                    match function_return_type_override_text(opts, name):
                        Option.some as override_type:
                            declaration.return_type = string.String.from_str(override_type.value)
                        Option.none:
                            var return_text = function_return_type_text(node)
                            var return_type = map_type(return_text, opts)
                            if bindgen_map_failed:
                                return_type.release()
                                continue
                            declaration.return_type = return_type
            if selected.get(name) == null:
                selected.set(name, declaration)

    var values = selected.values()
    while true:
        let value = values.next() else:
            break
        decls.push(unsafe: read(value))

## The host's `function_return_type`: the qual type's return portion.

function function_return_type_text(node: ptr[json.Object]) -> str:
    let qual_type = type_qual_text(node, true)
    match function_sig_text(qual_type):
        Option.some as signature:
            return signature.value.return_text
        Option.none:
            return ""

# =============================================================================
#  Synthetic aggregate dependencies (anonymous nested structs/unions)
# =============================================================================

function field_unnamed(field: ptr[json.Object]) -> bool:
    return jget_str(field, "name") == ""

## Asserts a nullable AST node after an explicit null check.

function node_non_null(value: ptr[json.Object]?) -> ptr[json.Object]:
    unsafe:
        return ptr[json.Object]<-value


function location_key_matches(left: ptr[json.Object], right: ptr[json.Object]) -> bool:
    unsafe:
        let left_offset = read(left).get_number("offset")
        let right_offset = read(right).get_number("offset")
        if left_offset.is_some() and right_offset.is_some():
            if left_offset.unwrap() != right_offset.unwrap():
                return false
        else if left_offset.is_some() or right_offset.is_some():
            return false
        let left_include = read(left).get_object("includedFrom")
        let right_include = read(right).get_object("includedFrom")
        var left_include_file = ""
        var right_include_file = ""
        if left_include != null:
            left_include_file = jget_str(left_include, "file")
        if right_include != null:
            right_include_file = jget_str(right_include, "file")
        if not left_include_file.equal(right_include_file):
            return false
        return jget_str(left, "file").equal(jget_str(right, "file"))


function anonymous_record_decl_for_field(
    field: ptr[json.Object],
    aggregate_node: ptr[json.Object]
) -> ptr[json.Object]?:
    unsafe:
        let qual_type = type_qual_text(field, true)
        var tag = ""
        if str_has_prefix(qual_type, "struct "):
            tag = "struct"
        else if str_has_prefix(qual_type, "union "):
            tag = "union"
        else:
            return null
        if not (qual_type.contains_substring("(unnamed at ") or qual_type.contains_substring("(anonymous at ")):
            return null
        let range = read(field).get_object("range")
        if range == null:
            return null
        let begin = read(range).get_object("begin")
        if begin == null:
            return null
        let children = jget_inner(aggregate_node)
        if children == null:
            return null
        var i: ptr_uint = 0
        while true:
            let entry = read(children).get(i) else:
                break
            let child = read(entry).as_object()
            if child != null and jget_str(child, "kind").equal("RecordDecl") and jget_str(child, "tagUsed").equal(tag):
                let child_loc = read(child).get_object("loc")
                if child_loc != null and location_key_matches(child_loc, begin):
                    return child
            i += 1
    return null


function aggregate_field_name(field: ptr[json.Object], aggregate_node: ptr[json.Object]) -> str:
    let name = jget_str(field, "name")
    if name != "":
        return name
    let anonymous_record = anonymous_record_decl_for_field(field, aggregate_node) else:
        return name
    unsafe:
        let field_id = jget_str(field, "id")
        let children = jget_inner(aggregate_node)
        var index: ptr_uint = 0
        var found: ptr_uint = 0
        if children != null:
            var i: ptr_uint = 0
            while true:
                let entry = read(children).get(i) else:
                    break
                let child = read(entry).as_object()
                if child != null and jget_str(child, "kind").equal("FieldDecl"):
                    if jget_str(child, "id").equal(field_id):
                        found = index
                    index += 1
                i += 1
        var rendered = string.String.from_str("anonymous_")
        rendered.append(jget_str(anonymous_record, "tagUsed"))
        rendered.append("_")
        rendered.append(uint_to_str(found))
        return rendered.as_str()


function synthetic_aggregate_name(
    owner_name: str,
    field: ptr[json.Object],
    aggregate_node: ptr[json.Object]
) -> string.String:
    var rendered = string.String.from_str(owner_name)
    rendered.append("_")
    rendered.append(aggregate_field_name(field, aggregate_node))
    return rendered


function aggregate_field_type(
    field: ptr[json.Object],
    owner_name: str,
    aggregate_node: ptr[json.Object],
    opts: ref[BindgenOptions]
) -> string.String:
    match field_type_override(opts, owner_name, jget_str(field, "name")):
        Option.some as override_type:
            return string.String.from_str(override_type.value)
        Option.none:
            pass
    let anonymous_record = anonymous_record_decl_for_field(field, aggregate_node)
    if anonymous_record != null and not field_unnamed(field):
        return synthetic_aggregate_name(owner_name, field, aggregate_node)
    if jget_str(field, "name") == "":
        return map_fail()
    return map_type_node(field, opts)

struct PendingAggregate:
    owner: str
    node: ptr[json.Object]


function aggregate_seen(seen: ref[vec.Vec[PendingAggregate]], owner: str, node: ptr[json.Object]) -> bool:
    var i: ptr_uint = 0
    while i < seen.len():
        let entry = seen.get(i) else:
            break
        let value = unsafe: read(entry)
        if value.node == node and value.owner.equal(owner):
            return true
        i += 1
    return false

## The host's `discover_synthetic_aggregate_dependencies`.

function discover_synthetic_aggregate_dependencies(
    declarations: vec.Vec[CDecl],
    opts: ref[BindgenOptions],
    state: ref[GenState]
) -> void:
    var pending = vec.Vec[PendingAggregate].create()
    defer: pending.release()
    var i: ptr_uint = 0
    while i < declarations.len():
        let entry = declarations.get(i) else:
            break
        let declaration = unsafe: read(entry)
        if (
            declaration.node != null
            and (declaration.kind.as_str().equal("struct") or declaration.kind.as_str().equal("union"))
        ):
            pending.push(PendingAggregate(
                owner = declaration.mt_name.as_str(),
                node = unsafe: ptr[json.Object]<-declaration.node
            ))
        i += 1
    var seen = vec.Vec[PendingAggregate].create()
    defer: seen.release()
    var head: ptr_uint = 0
    while head < pending.len():
        let current_ptr = pending.get(head) else:
            break
        head += 1
        let current = unsafe: read(current_ptr)
        if aggregate_seen(ref_of(seen), current.owner, current.node):
            continue
        seen.push(current)
        unsafe:
            let children = jget_inner(current.node)
            if children == null:
                continue
            var field_index: ptr_uint = 0
            while true:
                let entry = read(children).get(field_index) else:
                    break
                field_index += 1
                let field_object = read(entry).as_object()
                if field_object == null:
                    continue
                let field = unsafe: ptr[json.Object]<-field_object
                if not jget_str(field, "kind").equal("FieldDecl"):
                    continue
                let anonymous_record = anonymous_record_decl_for_field(field, current.node)
                if anonymous_record == null:
                    continue
                if field_unnamed(field):
                    pending.push(PendingAggregate(owner = current.owner, node = node_non_null(anonymous_record)))
                    continue
                var synthetic_name = synthetic_aggregate_name(current.owner, field, current.node)
                if not synthetic_exists(synthetic_name.as_str()):
                    read(state).synthetics.push(SyntheticDecl(
                        kind = string.String.from_str(jget_str(anonymous_record, "tagUsed")),
                        name = synthetic_name,
                        linkage = string.String.create(),
                        node = node_non_null(anonymous_record),
                    ))
                    read(state).aggregate_declarations.set(synthetic_name.as_str(), node_non_null(anonymous_record))
                pending.push(PendingAggregate(owner = synthetic_name.as_str(), node = node_non_null(anonymous_record)))

## The host's `discover_synthetic_field_type_dependencies`.

function discover_synthetic_field_type_dependencies(
    declarations: vec.Vec[CDecl],
    opts: ref[BindgenOptions],
    state: ref[GenState]
) -> void:
    var pending = vec.Vec[PendingAggregate].create()
    defer: pending.release()
    var i: ptr_uint = 0
    while i < declarations.len():
        let entry = declarations.get(i) else:
            break
        let declaration = unsafe: read(entry)
        if (
            declaration.node != null
            and (declaration.kind.as_str().equal("struct") or declaration.kind.as_str().equal("union"))
        ):
            pending.push(PendingAggregate(
                owner = declaration.mt_name.as_str(),
                node = unsafe: ptr[json.Object]<-declaration.node
            ))
        i += 1
    i = 0
    while i < unsafe: read(state).synthetics.len():
        let entry = unsafe: read(state).synthetics.get(i) else:
            break
        let synthetic_decl = unsafe: read(entry)
        if (
            synthetic_decl.node != null
            and (synthetic_decl.kind.as_str().equal("struct") or synthetic_decl.kind.as_str().equal("union"))
        ):
            pending.push(PendingAggregate(
                owner = synthetic_decl.name.as_str(),
                node = unsafe: ptr[json.Object]<-synthetic_decl.node
            ))
        i += 1
    var seen = vec.Vec[PendingAggregate].create()
    defer: seen.release()
    var head: ptr_uint = 0
    while head < pending.len():
        let current_ptr = pending.get(head) else:
            break
        head += 1
        let current = unsafe: read(current_ptr)
        if aggregate_seen(ref_of(seen), current.owner, current.node):
            continue
        seen.push(current)
        unsafe:
            let children = jget_inner(current.node)
            if children == null:
                continue
            var field_index: ptr_uint = 0
            while true:
                let entry = read(children).get(field_index) else:
                    break
                field_index += 1
                let field_object = read(entry).as_object()
                if field_object == null:
                    continue
                let field = unsafe: ptr[json.Object]<-field_object
                if not jget_str(field, "kind").equal("FieldDecl"):
                    continue
                let anonymous_record = anonymous_record_decl_for_field(field, current.node)
                if anonymous_record != null:
                    if field_unnamed(field):
                        pending.push(PendingAggregate(owner = current.owner, node = node_non_null(anonymous_record)))
                        continue
                    var synthetic_name = synthetic_aggregate_name(current.owner, field, current.node)
                    pending.push(PendingAggregate(
                        owner = synthetic_name.as_str(),
                        node = node_non_null(anonymous_record)
                    ))
                    continue
                bindgen_map_failed = false
                var mapped = aggregate_field_type(field, current.owner, current.node, opts)
                mapped.release()


function find_aggregate_node(name: str) -> ptr[json.Object]?:
    let state = bindgen_state else:
        return null
    let entry = unsafe: read(state).aggregate_declarations.get(name)
    if entry == null:
        return null
    return unsafe: read(entry)


function long_to_str(n: long) -> str:
    if n < 0:
        var u = uint_to_str(ptr_uint<-(-n))
        var r = string.String.from_str("-")
        r.append(u)
        return r.as_str()
    return uint_to_str(ptr_uint<-n)

## Find the value of an enum constant by looking inside its inner
## ConstantExpr child node.

function find_enum_value(ec_node: ptr[json.Object], name: str) -> str:
    unsafe:
        # First try the node's own "value" field (some clang versions).
        let direct_vp = read(ec_node).get("value")
        let direct = jstr(direct_vp)
        if direct != "":
            return direct
        # Search inner children for a ConstantExpr with a "value" field.
        let inner = jget_inner(ec_node)
        if inner == null:
            return ""
        var i: ptr_uint = 0
        while true:
            let cvp = read(inner).get(i) else:
                break
            let co = read(cvp).as_object()
            if co != null:
                let k = jget_str(co, "kind")
                if k == "ConstantExpr":
                    let vp = read(co).get("value")
                    let v = jstr(vp)
                    if v != "":
                        return v
            i += 1
    return ""

# =============================================================================
#  Emitter — generates the .mt external module source
# =============================================================================

function aggregate_explicit_c_name(name: str, node: ptr[json.Object]) -> str:
    let linkage = record_c_name(node)
    if linkage == "" or linkage.equal(name):
        return ""
    return linkage


function emit_aggregate_fields(
    buf: ref[string.String],
    node: ptr[json.Object],
    owner_name: str,
    opts: ref[BindgenOptions]
) -> void:
    let state = bindgen_state else:
        return
    unsafe:
        let children = jget_inner(node)
        if children == null:
            return
        var i: ptr_uint = 0
        while true:
            let entry = read(children).get(i) else:
                break
            let field = read(entry).as_object()
            if field != null and jget_str(field, "kind").equal("FieldDecl"):
                let anonymous_record = anonymous_record_decl_for_field(field, node)
                if anonymous_record != null and field_unnamed(field):
                    emit_flattened_anonymous(buf, node_non_null(anonymous_record), owner_name, opts)
                else:
                    bindgen_map_failed = false
                    var field_type = aggregate_field_type(field, owner_name, node, opts)
                    defer: field_type.release()
                    if not bindgen_map_failed:
                        let field_name = emitted_name(aggregate_field_name(field, node), opts)
                        buf.append("    ")
                        buf.append(field_name)
                        buf.append(": ")
                        buf.append(field_type.as_str())
                        buf.append("\n")
            i += 1


function emit_flattened_anonymous(
    buf: ref[string.String],
    record: ptr[json.Object],
    owner_name: str,
    opts: ref[BindgenOptions]
) -> void:
    unsafe:
        let children = jget_inner(record)
        if children == null:
            return
        var i: ptr_uint = 0
        while true:
            let entry = read(children).get(i) else:
                break
            let field = read(entry).as_object()
            if field != null and jget_str(field, "kind").equal("FieldDecl"):
                let anonymous_record = anonymous_record_decl_for_field(field, record)
                if anonymous_record != null and field_unnamed(field):
                    emit_flattened_anonymous(buf, node_non_null(anonymous_record), owner_name, opts)
                else:
                    bindgen_map_failed = false
                    var field_type = aggregate_field_type(field, owner_name, record, opts)
                    defer: field_type.release()
                    if not bindgen_map_failed:
                        let field_name = emitted_name(jget_str(field, "name"), opts)
                        buf.append("    ")
                        buf.append(field_name)
                        buf.append(": ")
                        buf.append(field_type.as_str())
                        buf.append("\n")
            i += 1


function emit_aggregate_declaration(
    buf: ref[string.String],
    kind_text: str,
    name: str,
    node: ptr[json.Object],
    opts: ref[BindgenOptions]
) -> void:
    let state = bindgen_state else:
        return
    buf.append(kind_text)
    buf.append(" ")
    buf.append(emitted_name(name, opts))
    let explicit_c_name = aggregate_explicit_c_name(name, node)
    if explicit_c_name != "":
        buf.append(" = c\"")
        buf.append(explicit_c_name)
        buf.append("\"")
    buf.append(":\n")
    emit_aggregate_fields(buf, node, name, opts)


function emit_synthetic(buf: ref[string.String], synthetic_decl: SyntheticDecl, opts: ref[BindgenOptions]) -> void:
    let kind_text = synthetic_decl.kind.as_str()
    if kind_text.equal("opaque"):
        buf.append("opaque ")
        buf.append(emitted_name(synthetic_decl.name.as_str(), opts))
        if synthetic_decl.linkage.as_str().len > 0:
            buf.append(" = c\"")
            buf.append(synthetic_decl.linkage.as_str())
            buf.append("\"")
        buf.append("\n")
        return
    emit_aggregate_declaration(buf, kind_text, synthetic_decl.name.as_str(), node_non_null(synthetic_decl.node), opts)


function emit_decl(buf: ref[string.String], d: CDecl, opts: ref[BindgenOptions]) -> void:
    let k = d.kind.as_str()
    let name = d.mt_name.as_str()

    if k == "opaque":
        buf.append("opaque ")
        buf.append(emitted_name(name, opts))
        if d.linkage.as_str().len > 0:
            buf.append(" = c\"")
            buf.append(d.linkage.as_str())
            buf.append("\"")
        buf.append("\n")
        return

    if k == "struct" or k == "union":
        if d.node == null:
            return
        emit_aggregate_declaration(buf, k, name, node_non_null(d.node), opts)
        return

    if k == "enum" or k == "flags":
        buf.append(k)
        buf.append(" ")
        buf.append(emitted_name(name, opts))
        buf.append(": ")
        var backing: string.String
        if d.qual_type.as_str().len == 0:
            backing = string.String.from_str("int")
        else:
            bindgen_map_failed = false
            backing = map_type(d.qual_type.as_str(), opts)
            if bindgen_map_failed:
                backing.release()
                backing = string.String.from_str("int")
        defer: backing.release()
        buf.append(backing.as_str())
        buf.append("\n")
        var mi: ptr_uint = 0
        while mi < d.members.len():
            let mp = d.members.get(mi) else:
                break
            unsafe:
                buf.append("    ")
                buf.append(read(mp).ename)
                buf.append(" = ")
                buf.append(read(mp).evalue.as_str())
                buf.append("\n")
            mi += 1
        return

    if k == "type_alias":
        buf.append("type ")
        buf.append(emitted_name(name, opts))
        buf.append(" = ")
        buf.append(d.qual_type.as_str())
        buf.append("\n")
        return

    if k == "const":
        buf.append("const ")
        buf.append(emitted_name(name, opts))
        buf.append(": ")
        buf.append(d.qual_type.as_str())
        if d.value_text.as_str().len > 0:
            buf.append(" = ")
            buf.append(d.value_text.as_str())
        buf.append("\n")
        return

    if k == "function":
        let original_name = d.c_name.as_str()
        let stripped_name = emitted_name(original_name, opts)
        buf.append("external function ")
        buf.append(stripped_name)
        buf.append("(")
        var an: ptr_uint = 0
        while an < d.param_names.len():
            if an > 0:
                buf.append(", ")
            let pn = d.param_names.get(an) else:
                break
            let pt = d.param_types.get(an) else:
                break
            unsafe:
                buf.append(read(pn).as_str())
                buf.append(": ")
                buf.append(read(pt).as_str())
            an += 1
        if d.is_variadic:
            if d.param_names.len() > 0:
                buf.append(", ")
            buf.append("...")
        buf.append(") -> ")
        buf.append(d.return_type.as_str())
        if not stripped_name.equal(original_name):
            buf.append(" = c\"")
            buf.append(original_name)
            buf.append("\"")
        buf.append("\n")
        return

## A stable index sort for declarations (the host's `sort_by { index }`).

function sort_declaration_order(decls: vec.Vec[CDecl]) -> vec.Vec[ptr_uint]:
    var order = vec.Vec[ptr_uint].create()
    var i: ptr_uint = 0
    while i < decls.len():
        order.push(i)
        i += 1
    var current: ptr_uint = 1
    while current < order.len():
        let value_ptr = order.get(current) else:
            break
        let value = unsafe: read(value_ptr)
        let value_decl_ptr = decls.get(value) else:
            break
        let index = unsafe: read(value_decl_ptr).index
        var position = current
        while position > 0:
            let previous_ptr = order.get(position - 1) else:
                break
            let previous = unsafe: read(previous_ptr)
            let previous_decl_ptr = decls.get(previous) else:
                break
            if unsafe: read(previous_decl_ptr).index <= index:
                break
            let slot = order.get(position) else:
                break
            unsafe: read(slot) = previous
            position -= 1
        let final_slot = order.get(position) else:
            break
        unsafe: read(final_slot) = value
        current += 1
    return order


function emit_module(
    decls: vec.Vec[CDecl],
    header_path: str,
    link_libs: vec.Vec[str],
    incs: vec.Vec[str],
    opts: ref[BindgenOptions]
) -> string.String:
    var buf = string.String.create()
    buf.append("# generated by mtc bindgen from ")
    buf.append(header_path)
    buf.append("\nexternal\n\n")

    var mi: ptr_uint = 0
    while mi < opts.module_imports.len():
        let imp = opts.module_imports.get(mi) else:
            break
        unsafe:
            let m = read(imp)
            buf.append("import ")
            buf.append(m.module_name)
            buf.append(" as ")
            buf.append(m.alias)
            buf.append("\n")
        mi += 1

    var i: ptr_uint = 0
    while i < link_libs.len():
        let l = link_libs.get(i) else:
            break
        buf.append("link \"")
        unsafe: buf.append(read(l))
        buf.append("\"\n")
        i += 1
    if incs.len() == 0:
        buf.append("include \"")
        buf.append(path_ops.basename(header_path))
        buf.append("\"\n")
    i = 0
    while i < incs.len():
        let inc = incs.get(i) else:
            break
        buf.append("include \"")
        unsafe: buf.append(read(inc))
        buf.append("\"\n")
        i += 1

    let state = bindgen_state else:
        return buf
    var si: ptr_uint = 0
    while si < unsafe: read(state).synthetics.len():
        let entry = unsafe: read(state).synthetics.get(si) else:
            break
        si += 1
        let synthetic_decl = unsafe: read(entry)
        var already = false
        var di: ptr_uint = 0
        while di < decls.len():
            let dp = decls.get(di) else:
                break
            if unsafe: read(dp).mt_name.as_str().equal(synthetic_decl.name.as_str()):
                already = true
                break
            di += 1
        if already:
            continue
        emit_synthetic(ref_of(buf), synthetic_decl, opts)

    var order = sort_declaration_order(decls)
    defer: order.release()
    var oi: ptr_uint = 0
    while oi < order.len():
        let position = order.get(oi) else:
            break
        let dp = decls.get(unsafe: read(position)) else:
            break
        emit_decl(ref_of(buf), unsafe: read(dp), opts)
        oi += 1
    return buf

## Extract `#define` macro constants from the header in source order (the
## host's `each_macro_definition` + `macro_constant_candidate?`: uppercase
## names, allowed by the declaration prefixes, non-function, integer bodies).

function uppercase_macro_name(name: str) -> bool:
    if name.len == 0:
        return false
    let first = name.byte_at(0)
    if first < 'A' or first > 'Z':
        return false
    var i: ptr_uint = 1
    while i < name.len:
        let b = name.byte_at(i)
        if not ((b >= 'A' and b <= 'Z') or (b >= '0' and b <= '9') or b == '_'):
            return false
        i += 1
    return true


function find_macro_index(names: ref[vec.Vec[string.String]], name: str) -> ptr_uint:
    var i: ptr_uint = 0
    while i < names.len():
        let np = names.get(i) else:
            break
        if unsafe: read(np).as_str().equal(name):
            return i
        i += 1
    return names.len()


function release_macro_names(items: ref[vec.Vec[string.String]]) -> void:
    var i: ptr_uint = 0
    while i < items.len():
        let ip = items.get(i) else:
            break
        unsafe: read(ip).release()
        i += 1
    items.release()


function is_ident_byte(b: ubyte) -> bool:
    return (b >= 'A' and b <= 'Z') or (b >= 'a' and b <= 'z') or (b >= '0' and b <= '9') or b == '_'

# =============================================================================
#  Macro constant probes (the host's macro_probe_declarations)
# =============================================================================

public const MACRO_PROBE_PREFIX: str = "__mt_bindgen_macro_"


function first_inner_child(node: ptr[json.Object]) -> ptr[json.Object]?:
    unsafe:
        let children = jget_inner(node)
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

function macro_candidates(
    tu_path: str,
    clang_bin: str,
    clang_args: span[str],
    opts: ref[BindgenOptions]
) -> vec.Vec[string.String]:
    var names = vec.Vec[string.String].create()
    var values = vec.Vec[string.String].create()
    defer: release_macro_names(ref_of(values))
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
                            current_file = absolute_path(path.value)
                        Option.none:
                            pass
                    continue
                if line.len < 8 or line.byte_at(0) != '#' or not line.slice(1, 6).equal("define"):
                    continue
                if current_file.as_str().len == 0 or not tracked_macro_file(
                    current_file.as_str(),
                    read(opts).header_path.as_str(),
                    opts
                ):
                    continue
                var si: ptr_uint = 8
                while si < line.len and line.byte_at(si) == ' ':
                    si += 1
                let name_start = si
                while si < line.len and is_ident_byte(line.byte_at(si)):
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
                let existing = find_macro_index(ref_of(names), name)
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


function macro_constant_candidate(name: str, body: str, opts: ref[BindgenOptions]) -> bool:
    if not uppercase_macro_name(name):
        return false
    if not allowed_declaration_name(name, opts):
        return false
    if body.len == 0:
        return false
    let first_byte = body.byte_at(0)
    var all_ident = (first_byte >= 'A' and first_byte <= 'Z') or (first_byte >= 'a' and first_byte <= 'z') or first_byte == '_'
    var bi: ptr_uint = 0
    while bi < body.len:
        if not is_ident_byte(body.byte_at(bi)):
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
    while i < body.len and is_ident_byte(body.byte_at(i)):
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
        while i < source.len and not is_ident_byte(source.byte_at(i)):
            i += 1
        if i >= source.len:
            return false
        let callee_start = i
        while i < source.len and is_ident_byte(source.byte_at(i)):
            i += 1
        let callee = source.slice(callee_start, i - callee_start)
        var j = i
        while j < source.len and source.byte_at(j) == ' ':
            j += 1
        if j >= source.len or source.byte_at(j) != '(':
            index = i
            continue
        if not uppercase_macro_name(callee):
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
    var trimmed = str_strip(cleaned.as_str())
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

function lower_constant(
    node: ptr[json.Object]?,
    expected_type: str,
    opts: ref[BindgenOptions]
) -> Option[string.String]:
    let n = node else:
        return Option[string.String].none
    unsafe:
        let kind = jget_str(n, "kind")
        if kind.equal("IntegerLiteral"):
            let value = jget_str(n, "value")
            match pointer_zero_literal(expected_type, value):
                Option.some as typed_null:
                    return Option[string.String].some(value = typed_null.value)
                Option.none:
                    return Option[string.String].some(value = string.String.from_str(value))
        if kind.equal("FloatingLiteral"):
            let value = jget_str(n, "value")
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
            rendered.append(jget_str(n, "value"))
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
            let operator = jget_str(n, "opcode")
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
    if str_has_prefix(expected_type, "ptr[") or str_has_prefix(expected_type, "const_ptr["):
        var rendered = string.String.from_str("null[")
        rendered.append(expected_type)
        rendered.append("]")
        return Option[string.String].some(value = rendered)
    return Option[string.String].none


function lower_zero_value(expected_type: str, opts: ref[BindgenOptions]) -> Option[string.String]:
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
    if str_has_prefix(expected_type, "ptr[") or str_has_prefix(expected_type, "const_ptr["):
        var rendered = string.String.from_str("null[")
        rendered.append(expected_type)
        rendered.append("]")
        return Option[string.String].some(value = rendered)
    if find_aggregate_node(expected_type) != null:
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
    if not str_has_prefix(expected_type, "array[") or not expected_type.ends_with("]"):
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
    let element = str_strip(inner.slice(0, comma))
    let length_text = str_strip(inner.slice(comma + 1, inner.len - comma - 1))
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
    opts: ref[BindgenOptions]
) -> Option[string.String]:
    if find_aggregate_node(expected_type) != null:
        return lower_init_list_fields(node, expected_type, opts)
    match parse_array_type(expected_type):
        Option.some as array_info:
            return lower_array_init_list(node, array_info.value, opts)
        Option.none:
            return Option[string.String].none


function lower_array_init_list(
    node: ptr[json.Object]?,
    array_info: ArrayTypeInfo,
    opts: ref[BindgenOptions]
) -> Option[string.String]:
    var rendered = string.String.from_str("array[")
    rendered.append(array_info.element_type)
    rendered.append(", ")
    rendered.append(uint_to_str(array_info.length))
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
        let children = jget_inner(n)
        if children == null:
            return null
        let cvp = read(children).get(index) else:
            return null
        return read(cvp).as_object()


function lower_init_list_fields(
    node: ptr[json.Object]?,
    expected_type: str,
    opts: ref[BindgenOptions]
) -> Option[string.String]:
    let record = find_aggregate_node(expected_type) else:
        return Option[string.String].none
    var rendered = string.String.from_str(expected_type)
    rendered.append("(")
    unsafe:
        let children = jget_inner(record)
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
            if not jget_str(field, "kind").equal("FieldDecl"):
                continue
            if emitted > 0:
                rendered.append(", ")
            bindgen_map_failed = false
            var field_type = aggregate_field_type(field, expected_type, record, opts)
            if bindgen_map_failed:
                field_type.release()
                return Option[string.String].none
            rendered.append(jget_str(field, "name"))
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

# =============================================================================
#  Main entry point
# =============================================================================

## A `--nullable-policy` return-type override: the C symbol and its Milk Tea
## type (the host's `function_return_type_overrides` entry).
public struct TypeOverride:
    function: string.String
    ty: string.String

## A `--nullable-policy` parameter-type override (`<function>.<parameter>`).
public struct ParamOverride:
    function: string.String
    parameter: string.String
    ty: string.String

## A generated module plus its optional nullable-policy report (the wire
## shape `Bindgen.generate_with_report` returns).
public struct BindgenOutput:
    source: string.String
    report: string.String

## A `str` view of a String without UTF-8 validation (clang expands a header
## into a multi-hundred-MB AST JSON; the host parses it unvalidated).

function raw_string_view(text: ref[string.String]) -> str:
    let length = read(text).len
    if length == 0:
        return ""
    unsafe:
        return str(data = ptr[char]<-read(text).data, len = length)

## Release the per-generation selection state.

function release_gen_state() -> void:
    let state = bindgen_state else:
        return
    bindgen_state = null
    unsafe:
        read(state).record_aliases.release()
        read(state).record_aliases_by_tag.release()
        read(state).enum_aliases.release()
        read(state).record_visible_names.release()
        read(state).enum_visible_names.release()
        read(state).referenceable.release()
        read(state).referenceable_by_id.release()
        read(state).aggregate_declarations.release()
        release_macro_names(ref_of(read(state).visible_typedef_names))
        release_macro_names(ref_of(read(state).function_type_typedef_names))
        var si: ptr_uint = 0
        while si < read(state).synthetics.len():
            let entry = read(state).synthetics.get(si) else:
                break
            var synthetic_decl = read(entry)
            synthetic_decl.kind.release()
            synthetic_decl.name.release()
            synthetic_decl.linkage.release()
            si += 1
        read(state).synthetics.release()

## The host's `@visible_typedef_names` / `@function_type_typedef_names`.

function collect_visible_typedef_names(
    nodes: vec.Vec[ptr[json.Object]],
    opts: ref[BindgenOptions],
    state: ref[GenState]
) -> void:
    var i: ptr_uint = 0
    while i < nodes.len():
        let node_entry = nodes.get(i) else:
            break
        let node = unsafe: read(node_entry)
        i += 1
        unsafe:
            if not jget_str(node, "kind").equal("TypedefDecl"):
                continue
            let name = jget_str(node, "name")
            if name == "" or not allowed_declaration_name(name, opts):
                continue
            read(state).visible_typedef_names.push(string.String.from_str(name))
            if extract_function_proto(node) != null and not function_pointer_type_check(type_qual_text(node, true)):
                read(state).function_type_typedef_names.push(string.String.from_str(name))

## One `import <module> as <alias>` directive (the host's `module_imports`).
public struct ModuleImport:
    module_name: str
    alias: str

public struct BindgenOptions:
    module_name: string.String
    header_path: string.String
    output_path: Option[str]
    link_libs: vec.Vec[str]
    include_headers: vec.Vec[str]
    clang_bin: str
    ## Extra clang flags (`--clang-arg`), in command-line order.
    clang_args: vec.Vec[str]
    return_overrides: vec.Vec[TypeOverride]
    param_overrides: vec.Vec[ParamOverride]
    ## The absolute header path the nullable report records (the host's
    ## `File.expand_path`); empty falls back to `header_path`.
    report_header_path: str
    ## `--options-json` tables (the host's raw-binding metadata).  String
    ## values borrow the loaded JSON root, which the caller keeps alive until
    ## generation finishes.
    bindgen_defines: vec.Vec[str]
    bindgen_include_directives: vec.Vec[str]
    module_imports: vec.Vec[ModuleImport]
    tracked_header_paths: vec.Vec[str]
    tracked_header_prefixes: vec.Vec[str]
    declaration_name_prefixes: vec.Vec[str]
    excluded_declaration_names: vec.Vec[str]
    type_name_overrides: map_mod.Map[str, str]
    type_overrides: map_mod.Map[str, str]
    function_param_type_overrides: map_mod.Map[str, map_mod.Map[str, str]]
    function_return_type_overrides: map_mod.Map[str, str]
    field_type_overrides: map_mod.Map[str, map_mod.Map[str, str]]
    allow_static_inline_functions: bool
    strip_leading_underscores: bool


public function generate(opts: ref[BindgenOptions]) -> Result[string.String, string.String]:
    match generate_internal(opts, false):
        Result.success as payload:
            var output = payload.value
            output.report.release()
            return Result[string.String, string.String].success(value = output.source)
        Result.failure as failure:
            return Result[string.String, string.String].failure(error = failure.error)


public function generate_with_report(opts: ref[BindgenOptions]) -> Result[BindgenOutput, string.String]:
    return generate_internal(opts, true)

# =============================================================================
#  --options-json — the host raw-binding metadata table
# =============================================================================

## Load the raw-binding option table into `opts`.  The returned root owns every
## string the table populated (they are `str` views into it); the caller must
## keep it alive until generation finishes and then release it with
## `release_options_json`.

public function load_options_json(path: str, opts: ref[BindgenOptions]) -> Result[ptr[json.Value], string.String]:
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


function jget_bool(obj: ptr[json.Object], key: str) -> bool:
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


function json_module_imports(obj: ptr[json.Object]) -> vec.Vec[ModuleImport]:
    var result = vec.Vec[ModuleImport].create()
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
                result.push(ModuleImport(module_name = module_name, alias = alias))
            i += 1
    return result


function generate_internal(opts: ref[BindgenOptions], want_report: bool) -> Result[BindgenOutput, string.String]:
    let header = opts.header_path.as_str()
    if not fs.is_file(header):
        return Result[BindgenOutput, string.String].failure(error = string.String.from_str("header not found"))

    var clang = "clang"
    let cb = opts.clang_bin
    if cb != "":
        clang = cb

    # A translation unit that includes the header, like the host's Tempfile:
    # clang prints `includedFrom` for declarations whose own loc omits a file,
    # which is how the provenance filter keeps header declarations.
    var tu_content = string.String.create()
    defer: tu_content.release()
    var di: ptr_uint = 0
    while di < opts.bindgen_defines.len():
        let define_ptr = opts.bindgen_defines.get(di) else:
            break
        let define_text = unsafe: read(define_ptr)
        var eq: ptr_uint = 0
        var has_eq = false
        while eq < define_text.len:
            if define_text.byte_at(eq) == '=':
                has_eq = true
                break
            eq += 1
        tu_content.append("#define ")
        if has_eq:
            tu_content.append(define_text.slice(0, eq))
            tu_content.append(" ")
            tu_content.append(define_text.slice(eq + 1, define_text.len - eq - 1))
        else:
            tu_content.append(define_text)
        tu_content.append("\n")
        di += 1
    tu_content.append("#include \"")
    tu_content.append(header)
    tu_content.append("\"\n")
    var ii: ptr_uint = 0
    while ii < opts.bindgen_include_directives.len():
        let include_ptr = opts.bindgen_include_directives.get(ii) else:
            break
        tu_content.append("#include \"")
        tu_content.append(unsafe: read(include_ptr))
        tu_content.append("\"\n")
        ii += 1

    var tu_path: string.String
    match fs.create_temporary_file_in_system_temp("milk-tea-bindgen", ".c"):
        Result.success as created:
            tu_path = created.value
        Result.failure:
            return Result[
                BindgenOutput,
                string.String
            ].failure(error = string.String.from_str("bindgen: cannot create a translation unit"))
    defer: tu_path.release()
    match fs.write_text(tu_path.as_str(), tu_content.as_str()):
        Result.success:
            pass
        Result.failure as write_err:
            var message = string.String.from_str("bindgen: cannot write the translation unit: ")
            message.append(write_err.error.message.as_str())
            write_err.error.release()
            return Result[BindgenOutput, string.String].failure(error = message)
    defer: remove_temporary_file(tu_path.as_str())

    # Probe the header's value-shaped macros so clang types them (`__typeof__`)
    # and folds their initializers; the probes land at the end of the TU, so
    # the AST also gives the host's constant order.
    var candidates = macro_candidates(tu_path.as_str(), clang, opts.clang_args.as_span(), opts)
    defer: release_macro_names(ref_of(candidates))
    if candidates.len() > 0:
        var pi: ptr_uint = 0
        while pi < candidates.len():
            let np = candidates.get(pi) else:
                break
            let candidate = unsafe: read(np).as_str()
            tu_content.append("static const __typeof__(")
            tu_content.append(candidate)
            tu_content.append(") ")
            tu_content.append(MACRO_PROBE_PREFIX)
            tu_content.append(candidate)
            tu_content.append(" = ")
            tu_content.append(candidate)
            tu_content.append(";\n")
            pi += 1
        match fs.write_text(tu_path.as_str(), tu_content.as_str()):
            Result.success:
                pass
            Result.failure as probe_err:
                var message = string.String.from_str("bindgen: cannot write the translation unit: ")
                message.append(probe_err.error.message.as_str())
                probe_err.error.release()
                return Result[BindgenOutput, string.String].failure(error = message)

    var args = vec.Vec[str].create()
    defer: args.release()
    args.push(clang)
    args.push("-x")
    args.push("c")
    args.push("-fno-builtin")
    var cai: ptr_uint = 0
    while cai < opts.clang_args.len():
        let arg_ptr = opts.clang_args.get(cai) else:
            break
        args.push(unsafe: read(arg_ptr))
        cai += 1
    args.push("-Xclang")
    args.push("-ast-dump=json")
    args.push("-fsyntax-only")
    args.push(tu_path.as_str())

    match process.capture(args.as_span()):
        Result.success as captured:
            var result = captured.value
            defer: result.stdout.release()
            defer: result.stderr.release()

            # The host parses stdout first: clang can report a diagnostic and
            # still emit a usable AST (the macro probes trigger warnings).
            # `as_str` would validate every UTF-8 byte of a multi-hundred-MB
            # AST (the host does not validate either, and the C backend's debug
            # loop guard counts the scan); view the captured text directly.
            if result.stdout.len == 0:
                return Result[
                    BindgenOutput,
                    string.String
                ].failure(error = string.String.from_str("clang produced no output"))
            let js = raw_string_view(ref_of(result.stdout))

            match json.parse(js):
                Result.success as parsed_val:
                    var parsed = parsed_val.value
                    defer: json.release_value(parsed)

                    var decls = vec.Vec[CDecl].create()
                    defer: decls.release()
                    var state = GenState(
                        record_aliases = map_mod.Map[str, str].create(),
                        record_aliases_by_tag = map_mod.Map[str, str].create(),
                        enum_aliases = map_mod.Map[str, str].create(),
                        record_visible_names = map_mod.Map[str, str].create(),
                        enum_visible_names = map_mod.Map[str, str].create(),
                        visible_typedef_names = vec.Vec[string.String].create(),
                        function_type_typedef_names = vec.Vec[string.String].create(),
                        referenceable = map_mod.Map[str, ptr[json.Object]].create(),
                        referenceable_by_id = map_mod.Map[str, ptr[json.Object]].create(),
                        aggregate_declarations = map_mod.Map[str, ptr[json.Object]].create(),
                        synthetics = vec.Vec[SyntheticDecl].create(),
                    )
                    bindgen_state = ptr_of(state)
                    defer: release_gen_state()
                    let root_obj = parsed.as_object() else:
                        return Result[
                            BindgenOutput,
                            string.String
                        ].failure(error = string.String.from_str("clang AST is not an object"))
                    var nodes = vec.Vec[ptr[json.Object]].create()
                    defer: nodes.release()
                    var seen_ids = vec.Vec[string.String].create()
                    defer: release_macro_names(ref_of(seen_ids))
                    extract_top_level_nodes(root_obj, opts, tu_path.as_str(), ref_of(nodes), ref_of(seen_ids))
                    collect_visible_typedef_names(nodes, opts, ref_of(state))
                    build_alias_maps(nodes, ref_of(state))
                    index_referenceable_records(root_obj, ref_of(state))
                    select_record_declarations(nodes, opts, ref_of(state), ref_of(decls))
                    discover_synthetic_aggregate_dependencies(decls, opts, ref_of(state))
                    discover_synthetic_field_type_dependencies(decls, opts, ref_of(state))
                    select_enum_declarations(nodes, opts, ref_of(state), ref_of(decls))
                    select_type_alias_declarations(nodes, opts, ref_of(decls))
                    select_constant_declarations(nodes, opts, ref_of(decls))
                    select_function_declarations(nodes, opts, ref_of(decls))

                    match validate_override_targets(ref_of(decls), opts):
                        Option.some as error_message:
                            return Result[BindgenOutput, string.String].failure(error = error_message.value)
                        Option.none:
                            pass

                    var src = emit_module(decls, header, opts.link_libs, opts.include_headers, opts)
                    var module_path = generated_module_path(opts.module_name.as_str())
                    defer: module_path.release()
                    let max_line_length = tidy.resolve_max_line_length(module_path.as_str(), 0)
                    match tidy.format_tidy(src.as_str(), module_path.as_str(), max_line_length, null):
                        Option.some as formatted:
                            src.release()
                            src = formatted.value
                        Option.none:
                            pass
                    var report = string.String.create()
                    if want_report:
                        build_nullable_report(ref_of(report), opts, ref_of(decls))
                    return Result[BindgenOutput, string.String].success(value = BindgenOutput(
                        source = src,
                        report = report
                    ))
                Result.failure as parse_err:
                    if result.status.exit_code != 0:
                        var failed = string.String.from_str("clang failed: ")
                        failed.append(result.stderr.as_str())
                        parse_err.error.message.release()
                        return Result[BindgenOutput, string.String].failure(error = failed)
                    var m = string.String.from_str("json parse error: ")
                    m.append(parse_err.error.message.as_str())
                    parse_err.error.release()
                    return Result[BindgenOutput, string.String].failure(error = m)

        Result.failure as fail:
            var err = fail.error
            var m = string.String.from_str("clang: ")
            m.append(err.message.as_str())
            err.message.release()
            return Result[BindgenOutput, string.String].failure(error = m)


function remove_temporary_file(path: str) -> void:
    match fs.remove(path):
        Result.success:
            pass
        Result.failure as err:
            err.error.release()

# =============================================================================
#  Nullable policy overrides and report
# =============================================================================

## A clang `qualType` function signature split into its return-type text and the
## parameter-list text (without the surrounding parentheses).

struct FunctionSigText:
    return_text: str
    params_text: str


function function_sig_text(qual_type: str) -> Option[FunctionSigText]:
    if qual_type.len == 0 or qual_type.byte_at(qual_type.len - 1) != ')':
        return Option[FunctionSigText].none
    var open: ptr_uint = 0
    var depth = 0
    var found = false
    var close: ptr_uint = 0
    var i: ptr_uint = 0
    while i < qual_type.len:
        let b = qual_type.byte_at(i)
        if b == '(' and depth == 0 and not found:
            open = i
            depth = 1
            found = true
        else if b == '(':
            depth += 1
        else if b == ')':
            depth -= 1
            if found and depth == 0:
                close = i
                break
        i += 1
    if not found:
        return Option[FunctionSigText].none
    return Option[FunctionSigText].some(value = FunctionSigText(
        return_text = str_strip(qual_type.slice(0, open)),
        params_text = qual_type.slice(open + 1, close - open - 1),
    ))

## The type text of the `index`-th top-level parameter in a parameter-list text.

function param_type_text_at(params: str, index: ptr_uint) -> str:
    if params == "void" or params == "":
        return ""
    var comma: ptr_uint = 0
    var pd: ptr_uint = 0
    var an: ptr_uint = 0
    var j: ptr_uint = 0
    while j <= params.len:
        if j == params.len or (params.byte_at(j) == ',' and pd == 0):
            if an == index:
                return str_strip(params.slice(comma, j - comma))
            comma = j + 1
            an += 1
        else if j < params.len:
            if params.byte_at(j) == '(':
                pd += 1
            if params.byte_at(j) == ')':
                pd -= 1
        j += 1
    return ""


function find_type_override(overrides: span[TypeOverride], function_name: str) -> Option[str]:
    var i: ptr_uint = 0
    while i < overrides.len:
        let entry = unsafe: read(overrides.data + i)
        if entry.function.as_str().equal(function_name):
            return Option[str].some(value = entry.ty.as_str())
        i += 1
    return Option[str].none


function find_param_override(overrides: span[ParamOverride], function_name: str, parameter: str) -> Option[str]:
    var i: ptr_uint = 0
    while i < overrides.len:
        let entry = unsafe: read(overrides.data + i)
        if entry.function.as_str().equal(function_name) and entry.parameter.as_str().equal(parameter):
            return Option[str].some(value = entry.ty.as_str())
        i += 1
    return Option[str].none


function find_function_decl(decls: ref[vec.Vec[CDecl]], function_name: str) -> Option[ptr[CDecl]]:
    var i: ptr_uint = 0
    while i < decls.len():
        let decl_ptr = decls.get(i) else:
            break
        let d = unsafe: read(decl_ptr)
        if d.kind.as_str().equal("function") and d.c_name.as_str().equal(function_name):
            return Option[ptr[CDecl]].some(value = decl_ptr)
        i += 1
    return Option[ptr[CDecl]].none


function param_index_of(names: vec.Vec[string.String], parameter: str) -> Option[ptr_uint]:
    var i: ptr_uint = 0
    while i < names.len():
        let name_ptr = names.get(i) else:
            break
        if unsafe: read(name_ptr).as_str().equal(parameter):
            return Option[ptr_uint].some(value = i)
        i += 1
    return Option[ptr_uint].none

## The host's override-target validation (`validate_function_param_type_overrides!`
## and `validate_function_return_type_overrides!`), with its exact messages.

function validate_override_targets(decls: ref[vec.Vec[CDecl]], opts: ref[BindgenOptions]) -> Option[string.String]:
    let header = opts.header_path.as_str()
    var pi: ptr_uint = 0
    while pi < opts.param_overrides.len():
        let entry_ptr = opts.param_overrides.get(pi) else:
            break
        let entry = unsafe: read(entry_ptr)
        match find_function_decl(decls, entry.function.as_str()):
            Option.none:
                var m = string.String.from_str("function_param_type_overrides references unknown function ")
                m.append(entry.function.as_str())
                m.append(" for ")
                m.append(header)
                return Option[string.String].some(value = m)
            Option.some as decl_ptr:
                let d = unsafe: read(decl_ptr.value)
                match param_index_of(d.param_names, entry.parameter.as_str()):
                    Option.none:
                        var m = string.String.from_str("function_param_type_overrides references unknown parameter ")
                        m.append(entry.function.as_str())
                        m.append(".")
                        m.append(entry.parameter.as_str())
                        m.append(" for ")
                        m.append(header)
                        return Option[string.String].some(value = m)
                    Option.some:
                        pass
        pi += 1

    var ri: ptr_uint = 0
    while ri < opts.return_overrides.len():
        let entry_ptr = opts.return_overrides.get(ri) else:
            break
        let entry = unsafe: read(entry_ptr)
        match find_function_decl(decls, entry.function.as_str()):
            Option.none:
                var m = string.String.from_str("function_return_type_overrides references unknown function ")
                m.append(entry.function.as_str())
                m.append(" for ")
                m.append(header)
                return Option[string.String].some(value = m)
            Option.some:
                pass
        ri += 1
    return Option[string.String].none

# =============================================================================
#  Nullable policy file
# =============================================================================

public struct NullablePolicy:
    return_overrides: vec.Vec[TypeOverride]
    param_overrides: vec.Vec[ParamOverride]


extending NullablePolicy:
    public editable function release() -> void:
        release_type_overrides(ref_of(this.return_overrides))
        release_param_overrides(ref_of(this.param_overrides))


public function release_type_overrides(overrides: ref[vec.Vec[TypeOverride]]) -> void:
    var i: ptr_uint = 0
    while i < overrides.len():
        let entry_ptr = overrides.get(i) else:
            break
        unsafe:
            var entry = read(entry_ptr)
            entry.function.release()
            entry.ty.release()
        i += 1
    overrides.release()


public function release_param_overrides(overrides: ref[vec.Vec[ParamOverride]]) -> void:
    var i: ptr_uint = 0
    while i < overrides.len():
        let entry_ptr = overrides.get(i) else:
            break
        unsafe:
            var entry = read(entry_ptr)
            entry.function.release()
            entry.parameter.release()
            entry.ty.release()
        i += 1
    overrides.release()

## Load and validate a `--nullable-policy` JSON file, mirroring the host's
## `BindgenCLI#load_nullable_policy` messages.

public function load_nullable_policy(path: str) -> Result[NullablePolicy, string.String]:
    var text: string.String
    match fs.read_text(path):
        Result.failure:
            var m = string.String.from_str("nullable policy file not found: ")
            m.append(path)
            return Result[NullablePolicy, string.String].failure(error = m)
        Result.success as payload:
            text = payload.value
    defer: text.release()

    var parsed: json.Value
    match json.parse(text.as_str()):
        Result.failure as parse_failure:
            var error = parse_failure.error
            var m = string.String.from_str("nullable policy is not valid JSON: ")
            m.append(error.message.as_str())
            error.release()
            return Result[NullablePolicy, string.String].failure(error = m)
        Result.success as parsed_payload:
            parsed = parsed_payload.value
    defer: json.release_value(parsed)

    let object_ptr = parsed.as_object() else:
        return Result[NullablePolicy, string.String].failure(
            error = string.String.from_str("nullable policy must be a JSON object")
        )

    let root = unsafe: read(object_ptr)
    var unknown = string.String.create()
    defer: unknown.release()
    var unknown_count: ptr_uint = 0
    var ei: ptr_uint = 0
    while ei < root.entries.len():
        let entry_ptr = root.entries.get(ei) else:
            break
        let key = unsafe: read(entry_ptr).key.as_str()
        if not (key == "return_types" or key == "parameters"):
            if unknown_count > 0:
                unknown.append(", ")
            unknown.append(key)
            unknown_count += 1
        ei += 1
    if unknown_count > 0:
        var m = string.String.from_str("nullable policy has unknown keys: ")
        m.append(unknown.as_str())
        m.append(" (expected return_types, parameters)")
        return Result[NullablePolicy, string.String].failure(error = m)

    var return_overrides = vec.Vec[TypeOverride].create()
    var param_overrides = vec.Vec[ParamOverride].create()
    var shape_ok = true

    let return_types_ptr = root.get_object("return_types")
    if return_types_ptr != null:
        let return_types = unsafe: read(return_types_ptr)
        var ri: ptr_uint = 0
        while ri < return_types.entries.len():
            let entry_ptr = return_types.entries.get(ri) else:
                break
            let entry = unsafe: read(entry_ptr)
            if entry.value.kind != json.ValueKind.string_:
                shape_ok = false
                break
            return_overrides.push(TypeOverride(

                function = string.String.from_str(entry.key.as_str()),
                ty = string.String.from_str(entry.value.string_value.as_str()),
            ))
            ri += 1
    else if root.get("return_types") != null:
        shape_ok = false

    let parameters_ptr = root.get_object("parameters")
    if parameters_ptr != null:
        let parameters = unsafe: read(parameters_ptr)
        var pi: ptr_uint = 0
        while pi < parameters.entries.len() and shape_ok:
            let entry_ptr = parameters.entries.get(pi) else:
                break
            let entry = unsafe: read(entry_ptr)
            let inner_ptr = entry.value.object_value
            if inner_ptr == null:
                shape_ok = false
                break
            let inner = unsafe: read(inner_ptr)
            var ii: ptr_uint = 0
            while ii < inner.entries.len():
                let inner_entry_ptr = inner.entries.get(ii) else:
                    break
                let inner_entry = unsafe: read(inner_entry_ptr)
                if inner_entry.value.kind != json.ValueKind.string_:
                    shape_ok = false
                    break
                param_overrides.push(ParamOverride(

                    function = string.String.from_str(entry.key.as_str()),
                    parameter = string.String.from_str(inner_entry.key.as_str()),
                    ty = string.String.from_str(inner_entry.value.string_value.as_str()),
                ))
                ii += 1
            pi += 1
    else if root.get("parameters") != null:
        shape_ok = false

    if not shape_ok:
        release_type_overrides(ref_of(return_overrides))
        release_param_overrides(ref_of(param_overrides))
        return Result[NullablePolicy, string.String].failure(error = string.String.from_str(
            "nullable policy must map {\"return_types\": {symbol: \"type?\"}, \"parameters\": {symbol: {param: \"type?\"}}}"
        ))

    return Result[NullablePolicy, string.String].success(value = NullablePolicy(
        return_overrides = return_overrides,
        param_overrides = param_overrides,
    ))

# =============================================================================
#  Nullable policy report
# =============================================================================

struct ReportParamEntry:
    function: str
    parameter: str
    override_type: str
    auto_type: string.String
    c_type: str

struct ReportReturnEntry:
    function: str
    override_type: str
    auto_type: string.String
    c_type: str


function report_param_compare(left: ptr[ReportParamEntry], right: ptr[ReportParamEntry]) -> int:
    let l = unsafe: read(left)
    let r = unsafe: read(right)
    let by_function = l.function.compare(r.function)
    if by_function != 0:
        return by_function
    return l.parameter.compare(r.parameter)


function report_return_compare(left: ptr[ReportReturnEntry], right: ptr[ReportReturnEntry]) -> int:
    return unsafe: read(left).function.compare(unsafe: read(right).function)


function release_param_entries(entries: ref[vec.Vec[ReportParamEntry]]) -> void:
    var i: ptr_uint = 0
    while i < entries.len():
        let entry_ptr = entries.get(i) else:
            break
        unsafe:
            read(entry_ptr).auto_type.release()
        i += 1
    entries.release()


function release_return_entries(entries: ref[vec.Vec[ReportReturnEntry]]) -> void:
    var i: ptr_uint = 0
    while i < entries.len():
        let entry_ptr = entries.get(i) else:
            break
        unsafe:
            read(entry_ptr).auto_type.release()
        i += 1
    entries.release()

## The host's `nullable_policy_report`: manually overridden entries whose type
## actually differs from the automatic mapping, sorted for stable output.

function build_nullable_report(
    target: ref[string.String],
    opts: ref[BindgenOptions],
    decls: ref[vec.Vec[CDecl]]
) -> void:
    var param_entries = vec.Vec[ReportParamEntry].create()
    defer: release_param_entries(ref_of(param_entries))
    var return_entries = vec.Vec[ReportReturnEntry].create()
    defer: release_return_entries(ref_of(return_entries))

    var pi: ptr_uint = 0
    while pi < opts.param_overrides.len():
        let entry_ptr = opts.param_overrides.get(pi) else:
            break
        let entry = unsafe: read(entry_ptr)
        let override_type = entry.ty.as_str()
        if not override_type.contains_substring("?"):
            pi += 1
            continue
        match find_function_decl(decls, entry.function.as_str()):
            Option.some as decl_ptr:
                let d = unsafe: read(decl_ptr.value)
                match param_index_of(d.param_names, entry.parameter.as_str()):
                    Option.some as index:
                        match function_sig_text(d.qual_type.as_str()):
                            Option.some as sig_payload:
                                let c_type = param_type_text_at(sig_payload.value.params_text, index.value)
                                var auto_type = map_type(c_type, opts)
                                if auto_type.as_str().equal(override_type):
                                    auto_type.release()
                                else:
                                    param_entries.push(ReportParamEntry(

                                        function = entry.function.as_str(),
                                        parameter = entry.parameter.as_str(),
                                        override_type = override_type,
                                        auto_type = auto_type,
                                        c_type = c_type,
                                    ))
                            Option.none:
                                pass
                    Option.none:
                        pass
            Option.none:
                pass
        pi += 1

    var ri: ptr_uint = 0
    while ri < opts.return_overrides.len():
        let entry_ptr = opts.return_overrides.get(ri) else:
            break
        let entry = unsafe: read(entry_ptr)
        let override_type = entry.ty.as_str()
        if not override_type.contains_substring("?"):
            ri += 1
            continue
        match find_function_decl(decls, entry.function.as_str()):
            Option.some as decl_ptr:
                let d = unsafe: read(decl_ptr.value)
                match function_sig_text(d.qual_type.as_str()):
                    Option.some as sig_payload:
                        let c_type = sig_payload.value.return_text
                        var auto_type = map_type(c_type, opts)
                        if auto_type.as_str().equal(override_type):
                            auto_type.release()
                        else:
                            return_entries.push(ReportReturnEntry(

                                function = entry.function.as_str(),
                                override_type = override_type,
                                auto_type = auto_type,
                                c_type = c_type,
                            ))
                    Option.none:
                        pass
            Option.none:
                pass
        ri += 1

    param_entries.sort_by(report_param_compare)
    return_entries.sort_by(report_return_compare)

    let report_header = if opts.report_header_path.len > 0: opts.report_header_path else: opts.header_path.as_str()
    target.append("{\n  \"module_name\": ")
    append_json_string(target, opts.module_name.as_str())
    target.append(",\n  \"header_path\": ")
    append_json_string(target, report_header)
    target.append(",\n  \"summary\": {\n    \"parameters\": ")
    target.append(uint_to_str(param_entries.len()))
    target.append(",\n    \"return_types\": ")
    target.append(uint_to_str(return_entries.len()))
    target.append(",\n    \"total\": ")
    target.append(uint_to_str(param_entries.len() + return_entries.len()))
    target.append("\n  },\n  \"manual_nullable_policy\": {\n    \"parameters\": ")
    append_param_entries_json(target, ref_of(param_entries))
    target.append(",\n    \"return_types\": ")
    append_return_entries_json(target, ref_of(return_entries))
    target.append("\n  }\n}")


function append_param_entries_json(target: ref[string.String], entries: ref[vec.Vec[ReportParamEntry]]) -> void:
    if entries.len() == 0:
        target.append("[]")
        return
    target.append("[\n")
    var i: ptr_uint = 0
    while i < entries.len():
        let entry_ptr = entries.get(i) else:
            break
        let entry = unsafe: read(entry_ptr)
        if i > 0:
            target.append(",\n")
        target.append("      {\n        \"function\": ")
        append_json_string(target, entry.function)
        target.append(",\n        \"parameter\": ")
        append_json_string(target, entry.parameter)
        target.append(",\n        \"override_type\": ")
        append_json_string(target, entry.override_type)
        target.append(",\n        \"auto_type\": ")
        append_json_string(target, entry.auto_type.as_str())
        target.append(",\n        \"c_type\": ")
        append_json_string(target, entry.c_type)
        target.append("\n      }")
        i += 1
    target.append("\n    ]")


function append_return_entries_json(target: ref[string.String], entries: ref[vec.Vec[ReportReturnEntry]]) -> void:
    if entries.len() == 0:
        target.append("[]")
        return
    target.append("[\n")
    var i: ptr_uint = 0
    while i < entries.len():
        let entry_ptr = entries.get(i) else:
            break
        let entry = unsafe: read(entry_ptr)
        if i > 0:
            target.append(",\n")
        target.append("      {\n        \"function\": ")
        append_json_string(target, entry.function)
        target.append(",\n        \"override_type\": ")
        append_json_string(target, entry.override_type)
        target.append(",\n        \"auto_type\": ")
        append_json_string(target, entry.auto_type.as_str())
        target.append(",\n        \"c_type\": ")
        append_json_string(target, entry.c_type)
        target.append("\n      }")
        i += 1
    target.append("\n    ]")


function hex_digit(value: ubyte) -> ubyte:
    if value < 10:
        return value + '0'
    return value - 10 + 'a'


function append_json_string(target: ref[string.String], value: str) -> void:
    target.push_byte(34)
    var i: ptr_uint = 0
    while i < value.len:
        let b = value.byte_at(i)
        if b == 34:
            target.append("\\\"")
        else if b == 92:
            target.append("\\\\")
        else if b == 10:
            target.append("\\n")
        else if b == 13:
            target.append("\\r")
        else if b == 9:
            target.append("\\t")
        else if b < 32:
            target.append("\\u00")
            target.push_byte(hex_digit(b / 16))
            target.push_byte(hex_digit(b % 16))
        else:
            target.push_byte(b)
        i += 1
    target.push_byte(34)
