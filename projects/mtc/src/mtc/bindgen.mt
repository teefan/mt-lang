## Self-hosted bindgen — generates a Milk Tea external binding module from a C
## header by running clang to dump the AST as JSON, extracting top-level
## declarations, mapping C types to MT types, and emitting the module source.

import std.str
import std.string as string
import std.vec as vec
import std.map as map_mod
import std.json as json
import std.process as process
import std.fs as fs

import mtc.formatter.tidy as tidy
import mtc.bindgen.nullable_policy as nullable_policy
import mtc.bindgen.emitter as emitter
import mtc.bindgen.macro_probes as macro_probes
import mtc.bindgen.options_json as options_json
import mtc.bindgen.nullable_report as nullable_report

# =============================================================================
#  Utilities
# =============================================================================

public function str_has_prefix(s: str, prefix: str) -> bool:
    if s.len < prefix.len:
        return false
    var i: ptr_uint = 0
    while i < prefix.len:
        if s.byte_at(i) != prefix.byte_at(i):
            return false
        i += 1
    return true


public function str_strip(t: str) -> str:
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


public function uint_to_str(n: ptr_uint) -> str:
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

public function jget_str(node: ptr[json.Object]?, key: str) -> str:
    if node == null:
        return ""
    unsafe:
        let vp = read(node).get(key)
        return jstr(vp)

## Get the qualType field from a clang Type node: {"qualType":"int"} → "int".

public function jget_inner(node: ptr[json.Object]?) -> ptr[json.Array]?:
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

public function map_type(qual_type: str, opts: ref[BindgenOptions]) -> string.String:
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

public struct CDecl:
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

public struct SyntheticDecl:
    kind: string.String
    name: string.String
    linkage: string.String
    node: ptr[json.Object]?

## The per-generation state (the host's Generator instance variables).

public struct GenState:
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

public function bindgen_state_ptr() -> ptr[GenState]?:
    return bindgen_state

public function bindgen_map_failed_flag() -> bool:
    return bindgen_map_failed

public function set_bindgen_map_failed(value: bool) -> void:
    bindgen_map_failed = value

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


public function absolute_path(path: str) -> string.String:
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

public function tracked_macro_file(path: str, header: str, opts: ref[BindgenOptions]) -> bool:
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

public function allowed_declaration_name(name: str, opts: ref[BindgenOptions]) -> bool:
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

public function emitted_name(name: str, opts: ref[BindgenOptions]) -> str:
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

public function record_c_name(node: ptr[json.Object]) -> str:
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


function create_decl(kind: str, c_name: str, mt_name: str, index: ptr_uint) -> CDecl:
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
                    var projection = create_decl("type_alias", node_name, visible_type_name(node_name, opts), index)
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
            var candidate = create_decl(if complete: tag else: "opaque", original_name, visible, index)
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
            var candidate = create_decl("enum", original_name, visible, index)
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
            var declaration = create_decl("type_alias", name, visible_type_name(name, opts), index)
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

## The host's `macro_probe_decl?` / `constant_name_for`.

function macro_probe_decl(node: ptr[json.Object]) -> bool:
    return str_has_prefix(jget_str(node, "name"), macro_probes.MACRO_PROBE_PREFIX)


function constant_name_for(node: ptr[json.Object]) -> str:
    let name = jget_str(node, "name")
    if str_has_prefix(name, macro_probes.MACRO_PROBE_PREFIX):
        return name.slice(macro_probes.MACRO_PROBE_PREFIX.len, name.len - macro_probes.MACRO_PROBE_PREFIX.len)
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
        if macro_probe_decl(node) and qual_type.contains_substring("typeof"):
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
                current = macro_probes.first_inner_child(current)
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
    if not macro_probe_decl(node):
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
            if options_json.jget_bool(node, "isInvalid"):
                continue
            if not constant_var_decl(node):
                continue
            let name = constant_name_for(node)
            if name == "" or not allowed_declaration_name(name, opts):
                continue
            bindgen_map_failed = false
            let initializer = macro_probes.first_inner_child(node)
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
            match macro_probes.lower_constant(initializer, type_text.as_str(), opts):
                Option.none:
                    type_text.release()
                    continue
                Option.some as lowered:
                    var declaration = create_decl("const", name, name, index)
                    declaration.qual_type = type_text
                    declaration.value_text = lowered.value
                    decls.push(declaration)
                    continue


function is_variadic_function(node: ptr[json.Object]) -> bool:
    unsafe:
        return read(node).get("variadic") != null and options_json.jget_bool(node, "variadic")

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
            var declaration = create_decl("function", name, name, index)
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
                        match nullable_policy.find_param_override(opts.param_overrides.as_span(), name, raw_name):
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

            match nullable_policy.find_type_override(opts.return_overrides.as_span(), name):
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
    match nullable_policy.function_sig_text(qual_type):
        Option.some as signature:
            return signature.value.return_text
        Option.none:
            return ""

# =============================================================================
#  Synthetic aggregate dependencies (anonymous nested structs/unions)
# =============================================================================

public function field_unnamed(field: ptr[json.Object]) -> bool:
    return jget_str(field, "name") == ""

## Asserts a nullable AST node after an explicit null check.

public function node_non_null(value: ptr[json.Object]?) -> ptr[json.Object]:
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


public function anonymous_record_decl_for_field(
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


public function aggregate_field_name(field: ptr[json.Object], aggregate_node: ptr[json.Object]) -> str:
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


public function aggregate_field_type(
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


public function find_aggregate_node(name: str) -> ptr[json.Object]?:
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


## Extract `#define` macro constants from the header in source order (the
## host's `each_macro_definition` + `macro_constant_candidate?`: uppercase
## names, allowed by the declaration prefixes, non-function, integer bodies).

public function uppercase_macro_name(name: str) -> bool:
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


public function find_macro_index(names: ref[vec.Vec[string.String]], name: str) -> ptr_uint:
    var i: ptr_uint = 0
    while i < names.len():
        let np = names.get(i) else:
            break
        if unsafe: read(np).as_str().equal(name):
            return i
        i += 1
    return names.len()


public function release_macro_names(items: ref[vec.Vec[string.String]]) -> void:
    var i: ptr_uint = 0
    while i < items.len():
        let ip = items.get(i) else:
            break
        unsafe: read(ip).release()
        i += 1
    items.release()


public function is_ident_byte(b: ubyte) -> bool:
    return (b >= 'A' and b <= 'Z') or (b >= 'a' and b <= 'z') or (b >= '0' and b <= '9') or b == '_'



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
    var candidates = macro_probes.macro_candidates(tu_path.as_str(), clang, opts.clang_args.as_span(), opts)
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
            tu_content.append(macro_probes.MACRO_PROBE_PREFIX)
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

                    match nullable_policy.validate_override_targets(ref_of(decls), opts):
                        Option.some as error_message:
                            return Result[BindgenOutput, string.String].failure(error = error_message.value)
                        Option.none:
                            pass

                    var src = emitter.emit_module(decls, header, opts.link_libs, opts.include_headers, opts)
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
                        nullable_report.build_nullable_report(ref_of(report), opts, ref_of(decls))
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
            var m = string.String.create()
            if err.code == -2:
                # The host's `Errno::ENOENT` branch: `clang not found: <bin>`.
                m.append("clang not found: ")
                m.append(clang)
            else:
                m.append("clang: ")
                m.append(err.message.as_str())
            err.message.release()
            return Result[BindgenOutput, string.String].failure(error = m)


function remove_temporary_file(path: str) -> void:
    match fs.remove(path):
        Result.success:
            pass
        Result.failure as err:
            err.error.release()
