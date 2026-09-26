## Semantic tokens — lexer token stream → LSP semantic token highlighting.
##
## Lexes the source file and maps Token kinds to LSP SemanticTokens with
## relative delta encoding (delta line, delta start char, length, type, mod).
## Identifier tokens are classified through the semantic Analysis maps:
## functions, types, namespaces (import aliases), and parameters.

import std.fmt
import std.fs as fs_mod
import std.json as json
import std.map as map_mod
import std.str
import std.string as string
import std.vec as vec

import mtc.lexer.lexer as lexer_mod
import mtc.lexer.token as token_mod
import mtc.lexer.token_kinds as tk_mod
import mtc.loader.path_resolver as resolver_mod
import mtc.parser.parser as parser
import mtc.parser.ast as ast
import mtc.parser.state as pstate
import mtc.semantic.analyzer as analyzer
import mtc.semantic.types as types_mod
import mtc.lsp.cursor as cursor
import mtc.lsp.protocol as proto
import mtc.lsp.uri as uri_ops
import mtc.lsp.workspace as workspace


const FNV_OFFSET: uint = 0x811C9DC5
const FNV_PRIME:  uint = 0x01000193


## Legend indices, mirroring the host's advertised legend exactly (see
## lifecycle.mt TOKEN_TYPES_JSON): namespace=0, type=1, class=2, enum=3,
## interface=4, struct=5, typeParameter=6, parameter=7, variable=8, property=9,
## enumMember=10, event=11, function=12, method=13, macro=14, keyword=15,
## modifier=16, comment=17, string=18, number=19, regexp=20, operator=21,
## decorator=22.
##
## Modifier bits match the host too: declaration=1, readonly=4.
const TOKEN_NAMESPACE:    uint = 0
const TOKEN_TYPE:         uint = 1
const TOKEN_CLASS:        uint = 2
const TOKEN_ENUM:         uint = 3
const TOKEN_INTERFACE:    uint = 4
const TOKEN_STRUCT:       uint = 5
const TOKEN_TYPE_PARAM:   uint = 6
const TOKEN_PARAMETER:    uint = 7
const TOKEN_VARIABLE:     uint = 8
const TOKEN_PROPERTY:     uint = 9
const TOKEN_ENUM_MEMBER:  uint = 10
const TOKEN_EVENT:        uint = 11
const TOKEN_FUNCTION:     uint = 12
const TOKEN_METHOD:       uint = 13
const TOKEN_MACRO:        uint = 14
const TOKEN_KEYWORD:      uint = 15
const TOKEN_MODIFIER:     uint = 16
const TOKEN_COMMENT:      uint = 17
const TOKEN_STRING:       uint = 18
const TOKEN_NUMBER:       uint = 19
const TOKEN_REGEXP:       uint = 20
const TOKEN_OPERATOR:     uint = 21
const TOKEN_DECORATOR:    uint = 22


## Handle textDocument/semanticTokens/full.
public function handle_semantic_tokens(ws: ref[workspace.Workspace], uri: str, id: json.Value) -> void:
    emit_semantic_tokens(ws, uri, id, false, 0, 0)


## Handle textDocument/semanticTokens/range: the full token pass clipped to
## whole lines of the requested range.  The host re-filters its entries with a
## 1-based start line while the entries carry 0-based lines, so the requested
## range's first line is never emitted
## (lib/milk_tea/lsp/server/semantic_tokens.rb:105-118).
public function handle_semantic_tokens_range(
    ws: ref[workspace.Workspace],
    uri: str,
    start_line: ptr_uint,
    end_line: ptr_uint,
    id: json.Value,
) -> void:
    emit_semantic_tokens(ws, uri, id, true, start_line + 1, end_line)


## Handle textDocument/semanticTokens/full/delta.  Computes the delta
## between the cached token set and the current token set and returns
## SemanticTokensDelta edits.
public function handle_semantic_tokens_delta(
    ws: ref[workspace.Workspace],
    uri: str,
    id: json.Value,
) -> void:
    var file_path = uri_ops.file_uri_to_path(uri) else:
        proto.write_response(id, json.null_value())
        return
    defer: file_path.release()

    var content = ws.document_source(file_path.as_str()) else:
        proto.write_response(id, json.null_value())
        return
    defer: content.release()

    let source = content.as_str()
    let current_hash = fnv1a_hash(source)

    # Check cache.
    let cached_ptr = ws.semantic_token_cache_get(file_path.as_str())
    if cached_ptr != null:
        let cached = unsafe: read(cached_ptr)
        if cached.source_hash == current_hash:
            var empty_json = string.String.create()
            defer: empty_json.release()
            empty_json.append("{\"edits\":[]}")
            proto.write_response_raw(id, empty_json.as_str())
            return

    # Compute full tokens (reuse existing full handler logic).
    var full_data = compute_token_data(ws, file_path.as_str(), source, false, 0, 0)
    defer: full_data.release()

    var result_id = string.String.create()
    result_id.append_format(f"#{current_hash:x}")

    # Cache the new result.
    ws.semantic_token_cache_set(file_path.as_str(), current_hash, string.String.from_str(result_id.as_str()), full_data.len() / 5)

    # If we have a cache entry (different hash), compute delta.
    if cached_ptr != null:
        # Recompute cached tokens to get delta.  Fall back to full.
        var old_data = compute_token_data(ws, file_path.as_str(), source, false, 0, 0)
        defer: old_data.release()

        var edits = compute_delta_edits(ref_of(old_data), ref_of(full_data))
        defer: edits.release()

        var result_json = string.String.create()
        defer: result_json.release()
        result_json.append("{\"resultId\":\"")
        proto.append_escaped(ref_of(result_json), result_id.as_str())
        result_json.append("\",\"edits\":[")
        var first = true
        var ei: ptr_uint = 0
        while ei < edits.len():
            let ep = edits.get(ei) else:
                break
            let edit = unsafe: read(ep)
            if not first:
                result_json.append(",")
            first = false
            result_json.append("{\"start\":")
            result_json.append_format(f"#{edit.start}")
            result_json.append(",\"deleteCount\":")
            result_json.append_format(f"#{edit.delete_count}")
            result_json.append(",\"data\":[")
            var di: ptr_uint = 0
            while di < edit.data.len():
                let dp = edit.data.get(di) else:
                    break
                if di > 0:
                    result_json.append(",")
                unsafe:
                    result_json.append_format(f"#{read(dp)}")
                di += 1
            result_json.append("]}")
            ei += 1
        result_json.append("]}")
        result_id.release()
        proto.write_response_raw(id, result_json.as_str())
        return

    # No cache entry: fall back to full.
    var tokens_json = build_tokens_json(ref_of(full_data))
    defer: tokens_json.release()
    var result_json = string.String.create()
    defer: result_json.release()
    result_json.append("{\"resultId\":\"")
    proto.append_escaped(ref_of(result_json), result_id.as_str())
    result_json.append("\",\"data\":[")
    if full_data.len() > 0:
        var di: ptr_uint = 0
        while di < full_data.len():
            let dp = full_data.get(di) else:
                break
            if di > 0:
                result_json.append(",")
            unsafe:
                result_json.append_format(f"#{read(dp)}")
            di += 1
    result_json.append("]}")
    result_id.release()
    proto.write_response_raw(id, result_json.as_str())


struct TokenEdit:
    start: ptr_uint
    delete_count: ptr_uint
    data: vec.Vec[uint]


## Compute delta edits between old and new token arrays.  Each token
## consumes 5 `uint` values in the packed LSP data array.
function compute_delta_edits(old_data: ref[vec.Vec[uint]], new_data: ref[vec.Vec[uint]]) -> vec.Vec[TokenEdit]:
    var result = vec.Vec[TokenEdit].create()

    let old_tokens = old_data.len() / 5
    let new_tokens = new_data.len() / 5

    # Find common prefix (in tokens, not in uint values).
    var common_prefix: ptr_uint = 0
    while common_prefix < old_tokens and common_prefix < new_tokens:
        if not token_equals(old_data, common_prefix, new_data, common_prefix):
            break
        common_prefix += 1

    # Find common suffix.
    var common_suffix: ptr_uint = 0
    while common_suffix + common_prefix < old_tokens and common_suffix + common_prefix < new_tokens:
        let oi = old_tokens - common_suffix - 1
        let ni = new_tokens - common_suffix - 1
        if not token_equals(old_data, oi, new_data, ni):
            break
        common_suffix += 1

    let delete_start = common_prefix
    let delete_count = old_tokens - common_prefix - common_suffix
    let insert_start = 5 * common_prefix
    let insert_end = 5 * (new_tokens - common_suffix)

    if delete_count > 0 or insert_end > insert_start:
        var edit = TokenEdit(start = delete_start, delete_count = delete_count, data = vec.Vec[uint].create())
        if insert_end > insert_start:
            var di = insert_start
            while di < insert_end:
                let dp = new_data.get(di) else:
                    break
                unsafe:
                    edit.data.push(read(dp))
                di += 1
        result.push(edit)

    return result


## True when the 5-tuple at position `a` in `old_data` equals the 5-tuple
## at position `b` in `new_data`.
function token_equals(old_data: ref[vec.Vec[uint]], a: ptr_uint, new_data: ref[vec.Vec[uint]], b: ptr_uint) -> bool:
    let ao = a * 5
    let bo = b * 5
    var i: ptr_uint = 0
    while i < 5:
        unsafe:
            let oa_ptr = old_data.get(ao + i) else:
                return false
            let nb_ptr = new_data.get(bo + i) else:
                return false
            if read(oa_ptr) != read(nb_ptr):
                return false
        i += 1
    return true


# =============================================================================
#  Shared scan classification — one classifier for semanticTokens
#  full / range / delta, mirroring the host's `classify_name_semantic`
#  decision order (lib/milk_tea/lsp/server/semantic_tokens.rb:336-515).
# =============================================================================

## Classification tables for one scan.  `alias_*` hold "<alias>.<member>" keys
## for members reached through a *resolved* import; unresolved imports are
## deliberately absent, so `alias.member` degrades exactly like the host (the
## alias is an unknown value; the member is method/property by call shape).
struct ScanFacts:
    functions: map_mod.Map[str, bool]
    types: map_mod.Map[str, bool]
    ## Struct (and other constructible) names: a call to one of these is a type
    ## constructor (`Sample(x = 1)`), which the host reports as a type.
    structs: map_mod.Map[str, bool]
    interfaces: map_mod.Map[str, bool]
    values: map_mod.Map[str, bool]
    imports: map_mod.Map[str, bool]
    alias_functions: map_mod.Map[str, bool]
    alias_types: map_mod.Map[str, bool]
    alias_interfaces: map_mod.Map[str, bool]
    alias_values: map_mod.Map[str, bool]
    readonly_names: map_mod.Map[str, bool]
    param_names: map_mod.Map[str, bool]


struct TokenClass:
    token_type: uint
    token_mod: uint


## Builtin type names the host marks `defaultLibrary`
## (`DEFAULT_LIBRARY_TYPE_NAMES` = `Types::BUILTIN_TYPE_NAMES`).
function is_default_library_type_name(name: str) -> bool:
    if is_builtin_type_name(name):
        return true
    return name.equal("Option") or name.equal("Result") or name.equal("simd") or
        name.equal("struct_handle") or name.equal("field_handle") or
        name.equal("callable_handle") or name.equal("attribute_handle") or
        name.equal("member_handle") or name.equal("EventError") or
        name.equal("Subscription")


## Builtin functions the host marks `defaultLibrary`
## (`BUILTIN_FUNCTION_NAMES`, lib/milk_tea/lsp/server.rb:59-61).
function is_default_library_function_name(name: str) -> bool:
    return name.equal("ref_of") or name.equal("const_ptr_of") or name.equal("ptr_of") or
        name.equal("read") or name.equal("fatal") or name.equal("reinterpret") or
        name.equal("array") or name.equal("span") or name.equal("zero") or
        name.equal("default") or name.equal("adapt") or name.equal("get") or
        name.equal("field_of") or name.equal("callable_of") or name.equal("has_attribute") or
        name.equal("attribute_of") or name.equal("attribute_arg") or name.equal("fields_of") or
        name.equal("members_of") or name.equal("attributes_of")


function scan_is_trivia(kind: tk_mod.TokenKind) -> bool:
    return kind == tk_mod.TokenKind.newline or kind == tk_mod.TokenKind.indent or
        kind == tk_mod.TokenKind.dedent or kind == tk_mod.TokenKind.eof


function scan_kind_at(tokens: span[token_mod.Token], index: ptr_uint) -> tk_mod.TokenKind:
    return unsafe: read(tokens.data + index).kind


function scan_lexeme_at(tokens: span[token_mod.Token], index: ptr_uint, source: str) -> str:
    return unsafe: token_mod.token_lexeme(read(tokens.data + index), source)


function scan_prev_index(tokens: span[token_mod.Token], index: ptr_uint) -> Option[ptr_uint]:
    if index == 0:
        return Option[ptr_uint].none
    var i = index
    while i > 0:
        i -= 1
        if not scan_is_trivia(scan_kind_at(tokens, i)):
            return Option[ptr_uint].some(value = i)
    return Option[ptr_uint].none


function scan_next_index(tokens: span[token_mod.Token], index: ptr_uint) -> Option[ptr_uint]:
    var i = index + 1
    while i < tokens.len:
        if not scan_is_trivia(scan_kind_at(tokens, i)):
            return Option[ptr_uint].some(value = i)
        i += 1
    return Option[ptr_uint].none


## True when no significant token on the same line precedes `index`
## (the host's `first_non_trivia_token_on_line?`).
function scan_first_on_line(tokens: span[token_mod.Token], index: ptr_uint) -> bool:
    let tok = unsafe: read(tokens.data + index)
    var i = index
    while i > 0:
        i -= 1
        if scan_is_trivia(scan_kind_at(tokens, i)):
            continue
        let other = unsafe: read(tokens.data + i)
        return other.line != tok.line
    return true


## The `(` opening the parameter list that contains `index`, if any
## (the host's `parameter_list_opener_index`).
function scan_parameter_list_opener(tokens: span[token_mod.Token], index: ptr_uint) -> Option[ptr_uint]:
    var depth: ptr_uint = 0
    var i = index
    while i > 0:
        i -= 1
        let kind = scan_kind_at(tokens, i)
        if kind == tk_mod.TokenKind.rparen:
            depth += 1
        else if kind == tk_mod.TokenKind.lparen:
            if depth == 0:
                return Option[ptr_uint].some(value = i)
            depth -= 1
    return Option[ptr_uint].none


## `name: T` immediately after `(`/`,` or a foreign mode keyword
## (the host's `parameter_declaration_token?`).
function scan_is_parameter_declaration(tokens: span[token_mod.Token], index: ptr_uint) -> bool:
    let next_idx = scan_next_index(tokens, index) else:
        return false
    if scan_kind_at(tokens, next_idx) != tk_mod.TokenKind.colon:
        return false
    let prev_idx = scan_prev_index(tokens, index) else:
        return false
    let prev_kind = scan_kind_at(tokens, prev_idx)
    return prev_kind == tk_mod.TokenKind.lparen or prev_kind == tk_mod.TokenKind.comma or
        prev_kind == tk_mod.TokenKind.tk_out or prev_kind == tk_mod.TokenKind.tk_in or
        prev_kind == tk_mod.TokenKind.tk_inout or prev_kind == tk_mod.TokenKind.tk_consuming


## True when the parameter list containing `index` belongs to a callable
## declaration (`function f(...)`, `fn(...)`, `proc(...)`)
## (the host's `callable_parameter_declaration_token?`).
function scan_is_callable_parameter_declaration(tokens: span[token_mod.Token], index: ptr_uint) -> bool:
    if not scan_is_parameter_declaration(tokens, index):
        return false
    let opener = scan_parameter_list_opener(tokens, index) else:
        return false
    var head_idx = scan_prev_index(tokens, opener) else:
        return false
    var head_kind = scan_kind_at(tokens, head_idx)
    if head_kind == tk_mod.TokenKind.tk_fn or head_kind == tk_mod.TokenKind.tk_proc:
        return true
    if head_kind == tk_mod.TokenKind.rbracket:
        let lbracket = scan_matching_opener(tokens, head_idx) else:
            return false
        let head_opt = scan_prev_index(tokens, lbracket) else:
            return false
        head_idx = head_opt
        head_kind = scan_kind_at(tokens, head_idx)
    if head_kind != tk_mod.TokenKind.identifier:
        return false
    let before = scan_prev_index(tokens, head_idx) else:
        return false
    return scan_kind_at(tokens, before) == tk_mod.TokenKind.tk_function


## The `(`/`[` matching the closer at `index`.
function scan_matching_opener(tokens: span[token_mod.Token], index: ptr_uint) -> Option[ptr_uint]:
    let closer = scan_kind_at(tokens, index)
    var depth: ptr_uint = 0
    var i = index
    while i > 0:
        i -= 1
        let kind = scan_kind_at(tokens, i)
        if kind == closer:
            depth += 1
        else if (closer == tk_mod.TokenKind.rparen and kind == tk_mod.TokenKind.lparen) or
                (closer == tk_mod.TokenKind.rbracket and kind == tk_mod.TokenKind.lbracket):
            if depth == 0:
                return Option[ptr_uint].some(value = i)
            depth -= 1
    return Option[ptr_uint].none


## True when the token is a variant arm name: a first-on-line identifier whose
## enclosing declaration line carries `variant`/`enum`/`flags`
## (the host's `variant_enum_member_declaration?`).
function scan_is_variant_enum_member(tokens: span[token_mod.Token], index: ptr_uint) -> bool:
    let tok = unsafe: read(tokens.data + index)
    if not scan_first_on_line(tokens, index) or tok.column <= 1:
        return false
    var i = index
    while i > 0:
        i -= 1
        let other = unsafe: read(tokens.data + i)
        if scan_is_trivia(other.kind) or other.line == tok.line or other.column >= tok.column:
            continue
        return scan_line_has_enum_header(tokens, i, other.line)
    return false


## True when some token on `line` (up to `index`) is `variant`/`enum`/`flags`.
function scan_line_has_enum_header(tokens: span[token_mod.Token], index: ptr_uint, line: ptr_uint) -> bool:
    var i: ptr_uint = 0
    while i <= index and i < tokens.len:
        let t = unsafe: read(tokens.data + i)
        if t.line == line:
            if t.kind == tk_mod.TokenKind.tk_variant or t.kind == tk_mod.TokenKind.tk_enum or
               t.kind == tk_mod.TokenKind.tk_flags:
                return true
        i += 1
    return false


## True when the token is a struct/union field declaration: first on its line,
## followed by `:` and not part of a parameter list or match arm
## (the host's `field_declaration_token?`).
function scan_is_field_declaration(tokens: span[token_mod.Token], index: ptr_uint) -> bool:
    if not scan_first_on_line(tokens, index):
        return false
    if scan_is_parameter_declaration(tokens, index):
        return false
    if scan_is_match_arm_binding(tokens, index):
        return false
    let next_idx = scan_next_index(tokens, index) else:
        return false
    return scan_kind_at(tokens, next_idx) == tk_mod.TokenKind.colon


## `as name:` — a match arm binding (the host's `match_arm_binding_token?`).
function scan_is_match_arm_binding(tokens: span[token_mod.Token], index: ptr_uint) -> bool:
    let prev_idx = scan_prev_index(tokens, index) else:
        return false
    if scan_kind_at(tokens, prev_idx) != tk_mod.TokenKind.tk_as:
        return false
    let next_idx = scan_next_index(tokens, index) else:
        return false
    return scan_kind_at(tokens, next_idx) == tk_mod.TokenKind.colon


## True when the token is a field of a variant arm's payload: a parameter-list
## member whose list head is a variant arm name
## (the host's `variant_payload_field_declaration_token?`).
function scan_is_variant_payload_field(tokens: span[token_mod.Token], index: ptr_uint) -> bool:
    if not scan_is_parameter_declaration(tokens, index):
        return false
    let opener = scan_parameter_list_opener(tokens, index) else:
        return false
    let head_idx = scan_prev_index(tokens, opener) else:
        return false
    return scan_is_variant_enum_member(tokens, head_idx)


## `let (a, b) =` / `let Vec2(x, y) =` destructuring binding
## (the host's `destructure_let_binding?`).
function scan_is_destructure_let(tokens: span[token_mod.Token], index: ptr_uint) -> bool:
    let tok = unsafe: read(tokens.data + index)
    var first_kind: tk_mod.TokenKind = tk_mod.TokenKind.eof
    var first_found = false
    var second_kind: tk_mod.TokenKind = tk_mod.TokenKind.eof
    var second_found = false
    var third_kind: tk_mod.TokenKind = tk_mod.TokenKind.eof
    var third_found = false
    var lparen_seen = false
    var equal_seen = false
    var i: ptr_uint = 0
    while i < tokens.len:
        let t = unsafe: read(tokens.data + i)
        if t.line != tok.line:
            if t.line > tok.line:
                break
            i += 1
            continue
        if not scan_is_trivia(t.kind):
            if not first_found:
                first_kind = t.kind
                first_found = true
            else if not second_found:
                second_kind = t.kind
                second_found = true
            else if not third_found:
                third_kind = t.kind
                third_found = true
            if t.kind == tk_mod.TokenKind.lparen and not equal_seen:
                lparen_seen = true
            if t.kind == tk_mod.TokenKind.equal:
                equal_seen = true
        i += 1
    if not first_found or first_kind != tk_mod.TokenKind.tk_let:
        return false
    if not lparen_seen:
        return false
    if second_found and second_kind == tk_mod.TokenKind.lparen:
        return true
    return second_found and second_kind == tk_mod.TokenKind.identifier and third_found and third_kind == tk_mod.TokenKind.lparen


## A named-argument label (`name =` after `(`/`,`): `property` inside a type
## constructor call, `parameter` otherwise
## (the host's `named_argument_label_token?`).
function scan_is_named_argument_label(tokens: span[token_mod.Token], index: ptr_uint) -> bool:
    let next_idx = scan_next_index(tokens, index) else:
        return false
    if scan_kind_at(tokens, next_idx) != tk_mod.TokenKind.equal:
        return false
    let prev_idx = scan_prev_index(tokens, index) else:
        return false
    let prev_kind = scan_kind_at(tokens, prev_idx)
    return prev_kind == tk_mod.TokenKind.lparen or prev_kind == tk_mod.TokenKind.comma


## True when the label's call is a type constructor (`Sample(x = 1)`), whose
## labels the host reports as properties
## (the host's `named_argument_label_in_type_constructor?`).
function scan_named_argument_in_type_constructor(facts: ref[ScanFacts], tokens: span[token_mod.Token], index: ptr_uint, source: str) -> bool:
    let opener = scan_parameter_list_opener(tokens, index) else:
        return false
    var callee_idx = scan_prev_index(tokens, opener) else:
        return false
    if scan_kind_at(tokens, callee_idx) == tk_mod.TokenKind.rbracket:
        let lbracket = scan_matching_opener(tokens, callee_idx) else:
            return false
        let callee_opt = scan_prev_index(tokens, lbracket) else:
            return false
        callee_idx = callee_opt
    if scan_kind_at(tokens, callee_idx) != tk_mod.TokenKind.identifier:
        return false
    let callee_name = scan_lexeme_at(tokens, callee_idx, source)
    if is_known_type_name(facts, callee_name):
        return true
    let dot_idx = scan_prev_index(tokens, callee_idx) else:
        return false
    if scan_kind_at(tokens, dot_idx) != tk_mod.TokenKind.dot:
        return false
    let receiver_idx = scan_prev_index(tokens, dot_idx) else:
        return false
    if scan_kind_at(tokens, receiver_idx) != tk_mod.TokenKind.identifier:
        return false
    return is_known_type_name(facts, scan_lexeme_at(tokens, receiver_idx, source))


## True when the name is a constructible type: a struct, or one of the builtin
## constructible types (the host's `constructible_semantic_type?`).
function is_constructible_type_name(facts: ref[ScanFacts], name: str) -> bool:
    unsafe:
        if read(facts).structs.contains(name):
            return true
    return name.equal("vec2") or name.equal("vec3") or name.equal("vec4") or
        name.equal("ivec2") or name.equal("ivec3") or name.equal("ivec4") or
        name.equal("mat3") or name.equal("mat4") or name.equal("quat") or
        name.equal("Task")


## Known type name: any declared type, struct, enum/variant (static member
## types), alias or builtin (the host's `known_type_name?`).
function is_known_type_name(facts: ref[ScanFacts], name: str) -> bool:
    unsafe:
        if read(facts).types.contains(name):
            return true
    return is_default_library_type_name(name)


## True when the token carries an `import` line role; `module path` segments are
## plain namespaces, the alias after `as` is a namespace declaration
## (the host's `import_path_info_at`).
function scan_import_module_path(tokens: span[token_mod.Token], index: ptr_uint, source: str) -> bool:
    var line_start = index
    while line_start > 0:
        let prev_kind = scan_kind_at(tokens, line_start - 1)
        let prev_line = unsafe: read(tokens.data + line_start - 1).line
        let tok_line = unsafe: read(tokens.data + index).line
        if scan_is_trivia(prev_kind) and prev_line != tok_line:
            break
        if prev_line != tok_line:
            break
        line_start -= 1
    if scan_kind_at(tokens, line_start) != tk_mod.TokenKind.tk_import:
        return false
    let tok_line = unsafe: read(tokens.data + index).line
    var seen_as = false
    var is_module_path = false
    var i = line_start
    while i < tokens.len:
        let t = unsafe: read(tokens.data + i)
        if t.line != tok_line:
            break
        if not scan_is_trivia(t.kind):
            if t.kind == tk_mod.TokenKind.tk_as:
                seen_as = true
            else if i == index and not seen_as:
                is_module_path = true
        i += 1
    return is_module_path


## True when the token follows `as` on an import line (the alias).
function scan_is_import_alias(tokens: span[token_mod.Token], index: ptr_uint) -> bool:
    let tok_line = unsafe: read(tokens.data + index).line
    var line_start = index
    while line_start > 0:
        let prev_line = unsafe: read(tokens.data + line_start - 1).line
        if prev_line != tok_line:
            break
        line_start -= 1
    if scan_kind_at(tokens, line_start) != tk_mod.TokenKind.tk_import:
        return false
    let prev_idx = scan_prev_index(tokens, index) else:
        return false
    return scan_kind_at(tokens, prev_idx) == tk_mod.TokenKind.tk_as


## Classify one identifier token (the host's `classify_name_semantic`).
function classify_scan_identifier(
    facts: ref[ScanFacts],
    tokens: span[token_mod.Token],
    index: ptr_uint,
    lexeme: str,
    source: str,
) -> TokenClass:
    # Import lines: path segments are namespaces, the alias declares one.
    if scan_is_import_alias(tokens, index):
        return TokenClass(token_type = TOKEN_NAMESPACE, token_mod = 1)
    if scan_import_module_path(tokens, index, source):
        return TokenClass(token_type = TOKEN_NAMESPACE, token_mod = 0)

    # Declaration names, judged by the preceding keyword.
    let prev_opt = scan_prev_index(tokens, index)
    if prev_opt.is_some():
        let prev_idx = prev_opt.unwrap()
        let prev_kind = scan_kind_at(tokens, prev_idx)
        if prev_kind == tk_mod.TokenKind.tk_function or prev_kind == tk_mod.TokenKind.tk_fn or
           prev_kind == tk_mod.TokenKind.tk_proc:
            return TokenClass(token_type = TOKEN_FUNCTION, token_mod = 1)
        if prev_kind == tk_mod.TokenKind.tk_struct or prev_kind == tk_mod.TokenKind.tk_union or
           prev_kind == tk_mod.TokenKind.tk_enum or prev_kind == tk_mod.TokenKind.tk_flags or
           prev_kind == tk_mod.TokenKind.tk_variant or prev_kind == tk_mod.TokenKind.tk_type or
           prev_kind == tk_mod.TokenKind.tk_opaque or prev_kind == tk_mod.TokenKind.tk_interface:
            return TokenClass(token_type = TOKEN_TYPE, token_mod = 1)
    if lexeme.equal("_"):
        return TokenClass(token_type = TOKEN_VARIABLE, token_mod = 0)
    if prev_opt.is_some():
        let prev_kind = scan_kind_at(tokens, prev_opt.unwrap())
        if prev_kind == tk_mod.TokenKind.tk_event:
            return TokenClass(token_type = TOKEN_VARIABLE, token_mod = 1)
        if prev_kind == tk_mod.TokenKind.tk_const:
            return TokenClass(token_type = TOKEN_VARIABLE, token_mod = 5)
        if prev_kind == tk_mod.TokenKind.tk_let:
            let next_idx = scan_next_index(tokens, index)
            var next_is_lparen = false
            if next_idx.is_some():
                next_is_lparen = scan_kind_at(tokens, next_idx.unwrap()) == tk_mod.TokenKind.lparen
            if not next_is_lparen:
                return TokenClass(token_type = TOKEN_VARIABLE, token_mod = 5)
        if prev_kind == tk_mod.TokenKind.tk_var:
            let next_idx = scan_next_index(tokens, index)
            var next_is_lparen = false
            if next_idx.is_some():
                next_is_lparen = scan_kind_at(tokens, next_idx.unwrap()) == tk_mod.TokenKind.lparen
            if not next_is_lparen:
                return TokenClass(token_type = TOKEN_VARIABLE, token_mod = 1)
        if prev_kind == tk_mod.TokenKind.tk_for:
            return TokenClass(token_type = TOKEN_VARIABLE, token_mod = 5)
    if scan_is_match_arm_binding(tokens, index):
        return TokenClass(token_type = TOKEN_VARIABLE, token_mod = 5)
    if scan_is_callable_parameter_declaration(tokens, index):
        return TokenClass(token_type = TOKEN_PARAMETER, token_mod = 1)
    if scan_is_variant_payload_field(tokens, index):
        return TokenClass(token_type = TOKEN_PROPERTY, token_mod = 1)
    if scan_is_field_declaration(tokens, index):
        return TokenClass(token_type = TOKEN_PROPERTY, token_mod = 1)
    if scan_is_destructure_let(tokens, index):
        return TokenClass(token_type = TOKEN_VARIABLE, token_mod = 5)
    if scan_is_named_argument_label(tokens, index):
        if scan_named_argument_in_type_constructor(facts, tokens, index, source):
            return TokenClass(token_type = TOKEN_PROPERTY, token_mod = 0)
        return TokenClass(token_type = TOKEN_PARAMETER, token_mod = 0)

    # Variant arm names are members of the variant's member set.
    if scan_is_variant_enum_member(tokens, index):
        return TokenClass(token_type = TOKEN_ENUM_MEMBER, token_mod = 1)

    # Dotted member access.
    if prev_opt.is_some() and scan_kind_at(tokens, prev_opt.unwrap()) == tk_mod.TokenKind.dot:
        let receiver_idx = scan_prev_index(tokens, prev_opt.unwrap())
        if receiver_idx.is_some():
            let receiver = scan_lexeme_at(tokens, receiver_idx.unwrap(), source)
            if unsafe: read(facts).imports.contains(receiver):
                var qualified = qualified_member_key(receiver, lexeme)
                defer: qualified.release()
                let key = qualified.as_str()
                if unsafe: read(facts).alias_functions.contains(key):
                    let next_idx = scan_next_index(tokens, index)
                    var call_shaped = false
                    if next_idx.is_some():
                        let nk = scan_kind_at(tokens, next_idx.unwrap())
                        call_shaped = nk == tk_mod.TokenKind.lparen or nk == tk_mod.TokenKind.lbracket
                    if call_shaped:
                        return TokenClass(token_type = TOKEN_FUNCTION, token_mod = 0)
                    return TokenClass(token_type = TOKEN_PROPERTY, token_mod = 0)
                if unsafe: read(facts).alias_types.contains(key):
                    return TokenClass(token_type = TOKEN_TYPE, token_mod = 0)
                if unsafe: read(facts).alias_interfaces.contains(key):
                    return TokenClass(token_type = TOKEN_TYPE, token_mod = 0)
                if unsafe: read(facts).alias_values.contains(key):
                    return TokenClass(token_type = TOKEN_VARIABLE, token_mod = 0)
            if is_known_type_name(facts, receiver) or starts_uppercase(receiver):
                return TokenClass(token_type = TOKEN_ENUM_MEMBER, token_mod = 0)
        let next_idx = scan_next_index(tokens, index)
        if next_idx.is_some() and scan_kind_at(tokens, next_idx.unwrap()) == tk_mod.TokenKind.lparen:
            return TokenClass(token_type = TOKEN_METHOD, token_mod = 0)
        return TokenClass(token_type = TOKEN_PROPERTY, token_mod = 0)

    # Call sites: builtins, functions, then type constructors.
    let next_call = scan_next_index(tokens, index)
    if next_call.is_some() and scan_kind_at(tokens, next_call.unwrap()) == tk_mod.TokenKind.lparen:
        if is_default_library_function_name(lexeme):
            return TokenClass(token_type = TOKEN_FUNCTION, token_mod = 512)
        if unsafe: read(facts).functions.contains(lexeme):
            return TokenClass(token_type = TOKEN_FUNCTION, token_mod = 0)
        if is_constructible_type_name(facts, lexeme):
            return TokenClass(token_type = TOKEN_TYPE, token_mod = 0)
        return TokenClass(token_type = TOKEN_FUNCTION, token_mod = 0)

    # Value / type / namespace references.
    unsafe:
        if read(facts).param_names.contains(lexeme):
            return TokenClass(token_type = TOKEN_PARAMETER, token_mod = 0)
        if read(facts).readonly_names.contains(lexeme):
            return TokenClass(token_type = TOKEN_VARIABLE, token_mod = 4)
        if read(facts).functions.contains(lexeme):
            return TokenClass(token_type = TOKEN_FUNCTION, token_mod = 0)
        if read(facts).types.contains(lexeme):
            if is_default_library_type_name(lexeme):
                return TokenClass(token_type = TOKEN_TYPE, token_mod = 512)
            return TokenClass(token_type = TOKEN_TYPE, token_mod = 0)
        if read(facts).interfaces.contains(lexeme):
            return TokenClass(token_type = TOKEN_TYPE, token_mod = 0)
        if read(facts).imports.contains(lexeme):
            return TokenClass(token_type = TOKEN_NAMESPACE, token_mod = 0)
        if read(facts).values.contains(lexeme):
            return TokenClass(token_type = TOKEN_VARIABLE, token_mod = 0)
    if is_default_library_type_name(lexeme):
        return TokenClass(token_type = TOKEN_TYPE, token_mod = 512)
    return TokenClass(token_type = TOKEN_VARIABLE, token_mod = 0)


function starts_uppercase(name: str) -> bool:
    if name.len == 0:
        return false
    let b = name.byte_at(0)
    return b >= 'A' and b <= 'Z'


function qualified_member_key(receiver: str, member: str) -> string.String:
    var key = string.String.create()
    key.append(receiver)
    key.push_byte(46)
    key.append(member)
    return key


## Merge the keys of a typed map into a bool set.
function merge_type_keys(source: ref[map_mod.Map[str, types_mod.Type]], target: ref[map_mod.Map[str, bool]]) -> void:
    var iter = source.keys()
    while true:
        let kp = iter.next() else:
            break
        unsafe:
            target.set(read(kp), true)


function merge_struct_keys(source: ref[map_mod.Map[str, span[analyzer.FieldEntry]]], target: ref[map_mod.Map[str, bool]]) -> void:
    var iter = source.keys()
    while true:
        let kp = iter.next() else:
            break
        unsafe:
            target.set(read(kp), true)


function merge_interface_keys(source: ref[map_mod.Map[str, span[ast.InterfaceMethod]]], target: ref[map_mod.Map[str, bool]]) -> void:
    var iter = source.keys()
    while true:
        let kp = iter.next() else:
            break
        unsafe:
            target.set(read(kp), true)


function merge_fn_keys(source: ref[map_mod.Map[str, analyzer.FnSig]], target: ref[map_mod.Map[str, bool]]) -> void:
    var iter = source.keys()
    while true:
        let kp = iter.next() else:
            break
        unsafe:
            target.set(read(kp), true)


function merge_bool_keys(source: ref[map_mod.Map[str, bool]], target: ref[map_mod.Map[str, bool]]) -> void:
    var iter = source.keys()
    while true:
        let kp = iter.next() else:
            break
        unsafe:
            target.set(read(kp), true)


## Record a module's exported surface under `alias.` keys.
function collect_alias_exports(facts: ref[ScanFacts], alias: str, analysis: ref[analyzer.Analysis]) -> void:
    var functions = vec.Vec[str].create()
    defer: functions.release()
    var types = vec.Vec[str].create()
    defer: types.release()
    var interfaces = vec.Vec[str].create()
    defer: interfaces.release()
    var values = vec.Vec[str].create()
    defer: values.release()
    unsafe:
        var fkeys = read(analysis).functions.keys()
        while true:
            let kp = fkeys.next() else:
                break
            functions.push(read(kp))
        var tkeys = read(analysis).types.keys()
        while true:
            let kp = tkeys.next() else:
                break
            types.push(read(kp))
        var skeys = read(analysis).structs.keys()
        while true:
            let kp = skeys.next() else:
                break
            types.push(read(kp))
        var ikeys = read(analysis).interfaces.keys()
        while true:
            let kp = ikeys.next() else:
                break
            interfaces.push(read(kp))
        var vkeys = read(analysis).value_types.keys()
        while true:
            let kp = vkeys.next() else:
                break
            values.push(read(kp))
    var i: ptr_uint = 0
    while i < functions.len():
        let fp = functions.get(i) else:
            break
        var key = qualified_member_key(alias, unsafe: read(fp))
        facts.alias_functions.set(key.as_str(), true)
        i += 1
    i = 0
    while i < types.len():
        let tp = types.get(i) else:
            break
        var key = qualified_member_key(alias, unsafe: read(tp))
        facts.alias_types.set(key.as_str(), true)
        i += 1
    i = 0
    while i < interfaces.len():
        let ip = interfaces.get(i) else:
            break
        var key = qualified_member_key(alias, unsafe: read(ip))
        facts.alias_interfaces.set(key.as_str(), true)
        i += 1
    i = 0
    while i < values.len():
        let vp = values.get(i) else:
            break
        var key = qualified_member_key(alias, unsafe: read(vp))
        facts.alias_values.set(key.as_str(), true)
        i += 1


## Register one import's exported surface when the module resolves.  Unresolved
## imports contribute nothing: the alias stays unknown, matching the host.
function register_resolved_import(
    facts: ref[ScanFacts],
    path: ast.QualifiedName,
    alias_name: Option[str],
    roots: span[str],
) -> void:
    var module_name = dotted_qname(path)
    defer: module_name.release()
    let alias = scan_import_alias_name(path, alias_name)
    match resolver_mod.resolve_module_path(module_name.as_str(), roots, resolver_mod.Platform.linux):
        Result.success as resolved_ok:
            var resolved = resolved_ok.value
            defer: resolved.release()
            var dep_source_opt = fs_mod.read_text(resolved.as_str())
            match dep_source_opt:
                Result.success as payload:
                    var dep_source = payload.value
                    defer: dep_source.release()
                    var dep_diags = vec.Vec[pstate.ParseDiagnostic].create()
                    defer: dep_diags.release()
                    let dep_file = parser.parse_source(dep_source.as_str(), ref_of(dep_diags))
                    var dep_analysis = analyzer.check_source_file(dep_file)
                    facts.imports.set(alias, true)
                    collect_alias_exports(facts, alias, ref_of(dep_analysis))
                Result.failure as fail:
                    var err = fail.error
                    err.release()
        Result.failure as resolve_failure:
            var rerr = resolve_failure.error
            rerr.release()


function dotted_qname(path: ast.QualifiedName) -> string.String:
    var buf = string.String.create()
    var i: ptr_uint = 0
    while i < path.parts.len:
        if i > 0:
            buf.push_byte(46)
        unsafe:
            buf.append(read(path.parts.data + i))
        i += 1
    return buf


function scan_import_alias_name(path: ast.QualifiedName, alias_name: Option[str]) -> str:
    match alias_name:
        Option.some as given:
            return given.value
        Option.none:
            if path.parts.len == 0:
                return ""
            unsafe:
                return read(path.parts.data + (path.parts.len - 1))


## Build the classification tables for one scan.
function build_scan_facts(file: ast.SourceFile, analysis: ref[analyzer.Analysis], roots: span[str]) -> ScanFacts:
    var facts = ScanFacts(
        functions = map_mod.Map[str, bool].create(),
        types = map_mod.Map[str, bool].create(),
        structs = map_mod.Map[str, bool].create(),
        interfaces = map_mod.Map[str, bool].create(),
        values = map_mod.Map[str, bool].create(),
        imports = map_mod.Map[str, bool].create(),
        alias_functions = map_mod.Map[str, bool].create(),
        alias_types = map_mod.Map[str, bool].create(),
        alias_interfaces = map_mod.Map[str, bool].create(),
        alias_values = map_mod.Map[str, bool].create(),
        readonly_names = map_mod.Map[str, bool].create(),
        param_names = map_mod.Map[str, bool].create(),
    )
    collect_readonly_names(file, ref_of(facts.readonly_names))
    var params = collect_param_names(analysis)
    defer: params.release()
    merge_bool_keys(ref_of(params), ref_of(facts.param_names))
    facts.param_names.set("this", true)
    var analysis_value = unsafe: read(analysis)
    unsafe:
        merge_fn_keys(ref_of(analysis_value.functions), ref_of(facts.functions))
        merge_type_keys(ref_of(analysis_value.types), ref_of(facts.types))
        merge_struct_keys(ref_of(analysis_value.structs), ref_of(facts.types))
        merge_struct_keys(ref_of(analysis_value.structs), ref_of(facts.structs))
        merge_struct_keys(ref_of(analysis_value.unions), ref_of(facts.structs))
        merge_bool_keys(ref_of(analysis_value.static_member_types), ref_of(facts.types))
        merge_type_keys(ref_of(analysis_value.type_alias_types), ref_of(facts.types))
        merge_interface_keys(ref_of(analysis_value.interfaces), ref_of(facts.interfaces))
        merge_type_keys(ref_of(analysis_value.value_types), ref_of(facts.values))

    var i: ptr_uint = 0
    while i < file.imports.len:
        unsafe:
            match read(file.imports.data + i):
                ast.Decl.decl_import as imp:
                    register_resolved_import(ref_of(facts), imp.path, imp.alias_name, roots)
                _:
                    pass
        i += 1
    return facts


## Compute the full token data array for a source file.  One scanner serves
## semanticTokens full, range and delta, so the three endpoints can never
## classify the same token differently.
function compute_token_data(
    ws: ref[workspace.Workspace],
    path: str,
    source: str,
    clip: bool,
    clip_start_line: ptr_uint,
    clip_end_line: ptr_uint,
) -> vec.Vec[uint]:
    var lex_diags = vec.Vec[token_mod.LexDiagnostic].create()
    defer: lex_diags.release()
    var all_tokens = lexer_mod.lex_reporting(source, ref_of(lex_diags))
    defer: all_tokens.release()

    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer: parse_diags.release()
    var ast_file = parser.parse_source(source, ref_of(parse_diags))
    var analysis = analyzer.check_source_file(ast_file)

    var roots = ws.effective_module_roots_for(path)
    defer: roots.release()
    var facts = build_scan_facts(ast_file, ref_of(analysis), roots.as_span())

    let tokens = all_tokens.as_span()
    var data = vec.Vec[uint].create()

    var prev_line: uint = 0
    var prev_char: uint = 0
    var in_decorator: bool = false
    var decorator_depth: ptr_uint = 0
    var ti: ptr_uint = 0
    while ti < tokens.len:
        let tok = unsafe: read(tokens.data + ti)
        let kind = tok.kind
        if scan_is_trivia(kind):
            in_decorator = false
            decorator_depth = 0
            ti += 1
            continue
        let line_num: uint = if tok.line > 0: uint<-(tok.line - 1) else: 0
        if clip and (line_num < uint<-clip_start_line or line_num > uint<-clip_end_line):
            ti += 1
            continue
        let char_num: uint = uint<-tok.end_offset - uint<-tok.start_offset
        let col_num: uint = if tok.column > 0: uint<-(tok.column - 1) else: 0
        var token_type = token_kind_to_type(kind)
        var token_mod: uint = 0
        if kind == tk_mod.TokenKind.identifier:
            let lexeme = unsafe: token_mod.token_lexeme(tok, source)
            if in_decorator and decorator_depth == 1:
                token_type = TOKEN_DECORATOR
            else:
                let cls = classify_scan_identifier(ref_of(facts), tokens, ti, lexeme, source)
                token_type = cls.token_type
                token_mod = cls.token_mod
        else:
            if kind == tk_mod.TokenKind.at:
                in_decorator = true
                decorator_depth = 0
            else if kind == tk_mod.TokenKind.lbracket and in_decorator:
                decorator_depth += 1
            else if kind == tk_mod.TokenKind.rbracket and in_decorator:
                if decorator_depth > 0:
                    decorator_depth -= 1
                if decorator_depth == 0:
                    in_decorator = false
        # Heredoc tokens are not highlighted (mirrors the host).
        if token_type == TOKEN_STRING:
            let lexeme = unsafe: token_mod.token_lexeme(tok, source)
            match lexeme.find_substring("<<-"):
                Option.some:
                    ti += 1
                    continue
                Option.none:
                    pass
        let delta_line = line_num - prev_line
        var delta_char = col_num
        if delta_line == 0:
            delta_char = col_num - prev_char
        data.push(delta_line)
        data.push(delta_char)
        data.push(char_num)
        data.push(token_type)
        data.push(token_mod)
        prev_line = line_num
        prev_char = col_num
        ti += 1

    return data


## FNV-1a hash of source text for result ID generation.
function fnv1a_hash(text: str) -> uint:
    var h = FNV_OFFSET
    var i: ptr_uint = 0
    while i < text.len:
        let b = uint<-text.byte_at(i)
        h = (h ^ b) * FNV_PRIME
        i += 1
    return h


function emit_semantic_tokens(
    ws: ref[workspace.Workspace],
    uri: str,
    id: json.Value,
    clip: bool,
    clip_start_line: ptr_uint,
    clip_end_line: ptr_uint,
) -> void:
    var file_path = uri_ops.file_uri_to_path(uri) else:
        proto.write_response(id, json.null_value())
        return
    defer: file_path.release()

    var content = ws.document_source(file_path.as_str()) else:
        proto.write_response(id, json.null_value())
        return
    defer: content.release()

    var data = compute_token_data(ws, file_path.as_str(), content.as_str(), clip, clip_start_line, clip_end_line)
    defer: data.release()

    var json_text = build_tokens_json(ref_of(data))
    proto.write_response_raw(id, json_text.as_str())
    json_text.release()


## Classify an identifier lexeme through the Analysis maps.
public function classify_identifier(
    lexeme: str,
    analysis: ref[analyzer.Analysis],
) -> uint:
    if is_builtin_type_name(lexeme):
        return TOKEN_TYPE
    unsafe:
        if read(analysis).functions.contains(lexeme):
            return TOKEN_FUNCTION
        if read(analysis).method_sigs.contains(lexeme):
            return TOKEN_METHOD
        if read(analysis).structs.contains(lexeme):
            return TOKEN_STRUCT
        if read(analysis).static_member_types.contains(lexeme):
            return TOKEN_TYPE
        if read(analysis).interfaces.contains(lexeme):
            return TOKEN_INTERFACE
        if read(analysis).type_alias_types.contains(lexeme):
            return TOKEN_TYPE
        if read(analysis).imports.contains(lexeme):
            return TOKEN_NAMESPACE
    return TOKEN_VARIABLE


## The set of every parameter name declared by the module's functions and
## methods, for parameter classification.
public function collect_param_names(analysis: ref[analyzer.Analysis]) -> map_mod.Map[str, bool]:
    var names = map_mod.Map[str, bool].create()
    unsafe:
        var fn_values = read(analysis).functions.values()
        while true:
            let sp = fn_values.next() else:
                break
            add_param_names(ref_of(names), read(sp))

        var method_values = read(analysis).method_sigs.values()
        while true:
            let sp = method_values.next() else:
                break
            add_param_names(ref_of(names), read(sp))
    return names


function add_param_names(names: ref[map_mod.Map[str, bool]], sig: analyzer.FnSig) -> void:
    var pi: ptr_uint = 0
    while pi < sig.params.len:
        let param = unsafe: read(sig.params.data + pi)
        if param.name.len > 0:
            names.set(param.name, true)
        pi += 1


## True for primitive type names and built-in type constructors, which lex
## as ordinary identifiers but should highlight as types.
public function is_builtin_type_name(lexeme: str) -> bool:
    if lexeme.equal("bool") or lexeme.equal("byte") or lexeme.equal("short") or
       lexeme.equal("int") or lexeme.equal("long") or lexeme.equal("ubyte") or
       lexeme.equal("ushort") or lexeme.equal("uint") or lexeme.equal("ulong") or
       lexeme.equal("char") or lexeme.equal("ptr_int") or lexeme.equal("ptr_uint") or
       lexeme.equal("float") or lexeme.equal("double") or lexeme.equal("void") or
       lexeme.equal("str") or lexeme.equal("cstr"):
        return true
    if lexeme.equal("vec2") or lexeme.equal("vec3") or lexeme.equal("vec4") or
       lexeme.equal("ivec2") or lexeme.equal("ivec3") or lexeme.equal("ivec4") or
       lexeme.equal("mat3") or lexeme.equal("mat4") or lexeme.equal("quat"):
        return true
    return lexeme.equal("ptr") or lexeme.equal("const_ptr") or lexeme.equal("own") or
       lexeme.equal("ref") or lexeme.equal("span") or lexeme.equal("array") or
       lexeme.equal("str_buffer") or lexeme.equal("Task") or lexeme.equal("atomic") or
       lexeme.equal("dyn") or lexeme.equal("SoA") or lexeme.equal("fn") or
       lexeme.equal("proc") or lexeme.equal("type")


## Map a non-identifier TokenKind to an LSP semantic token type index.
public function token_kind_to_type(kind: tk_mod.TokenKind) -> uint:
    if kind == tk_mod.TokenKind.identifier:
        return TOKEN_VARIABLE
    if kind == tk_mod.TokenKind.integer or kind == tk_mod.TokenKind.float_literal:
        return TOKEN_NUMBER
    if kind == tk_mod.TokenKind.string or kind == tk_mod.TokenKind.cstring or
       kind == tk_mod.TokenKind.fstring or kind == tk_mod.TokenKind.char_literal:
        return TOKEN_STRING
    # Operators and punctuation
    if kind == tk_mod.TokenKind.dot or kind == tk_mod.TokenKind.plus or
       kind == tk_mod.TokenKind.minus or kind == tk_mod.TokenKind.star or
       kind == tk_mod.TokenKind.slash or kind == tk_mod.TokenKind.percent or
       kind == tk_mod.TokenKind.amp or kind == tk_mod.TokenKind.pipe or
       kind == tk_mod.TokenKind.caret or kind == tk_mod.TokenKind.less or
       kind == tk_mod.TokenKind.greater or kind == tk_mod.TokenKind.equal or
       kind == tk_mod.TokenKind.arrow or kind == tk_mod.TokenKind.dot_dot or
       kind == tk_mod.TokenKind.equal_equal or kind == tk_mod.TokenKind.bang_equal or
       kind == tk_mod.TokenKind.less_equal or kind == tk_mod.TokenKind.greater_equal or
       kind == tk_mod.TokenKind.shift_left or kind == tk_mod.TokenKind.shift_right or
       kind == tk_mod.TokenKind.plus_equal or kind == tk_mod.TokenKind.minus_equal or
       kind == tk_mod.TokenKind.star_equal or kind == tk_mod.TokenKind.slash_equal or
       kind == tk_mod.TokenKind.percent_equal or kind == tk_mod.TokenKind.amp_equal or
       kind == tk_mod.TokenKind.pipe_equal or kind == tk_mod.TokenKind.caret_equal or
       kind == tk_mod.TokenKind.shift_left_equal or kind == tk_mod.TokenKind.shift_right_equal or
        kind == tk_mod.TokenKind.ellipsis or kind == tk_mod.TokenKind.tilde or
        kind == tk_mod.TokenKind.lparen or kind == tk_mod.TokenKind.rparen or
        kind == tk_mod.TokenKind.lbracket or kind == tk_mod.TokenKind.rbracket or
        kind == tk_mod.TokenKind.colon or kind == tk_mod.TokenKind.comma or
        kind == tk_mod.TokenKind.question or kind == tk_mod.TokenKind.at:
        return TOKEN_OPERATOR
    return TOKEN_KEYWORD


## Build a SemanticTokens data array JSON.
function build_tokens_json(data: ref[vec.Vec[uint]]) -> string.String:
    var result = string.String.create()
    result.append("{\"data\":[")
    var first = true
    var di: ptr_uint = 0
    while di < data.len():
        let v_ptr = data.get(di) else:
            break
        if not first:
            result.append(",")
        first = false
        unsafe:
            result.append_format(f"#{read(v_ptr)}")
        di += 1
    result.append("]}")
    return result


## Token-type names by legend index, for the HTML snapshot's CSS classes.
## Mirrors the host's legend order (see lifecycle.mt).
const SNAPSHOT_TOKEN_NAMES: array[str, 23] = ("namespace", "type", "class", "enum", "interface", "struct", "typeParameter", "parameter", "variable", "property", "enumMember", "event", "function", "method", "macro", "keyword", "modifier", "comment", "string", "number", "regexp", "operator", "decorator")


function snapshot_utf8_continuation(b: ubyte) -> bool:
    return (b & ubyte<-(0xC0)) == ubyte<-(0x80)


function snapshot_byte_to_char(line: str, byte_offset: ptr_uint) -> ptr_uint:
    var char_count: ptr_uint = 0
    var pos: ptr_uint = 0
    let limit = if byte_offset < line.len: byte_offset else: line.len
    while pos < limit:
        if not snapshot_utf8_continuation(line.byte_at(pos)):
            char_count += 1
        pos += 1
    return char_count


function snapshot_token_type_name(token_type: uint) -> str:
    if token_type >= 23:
        return "variable"
    return SNAPSHOT_TOKEN_NAMES[uint<-token_type]


## Collect names of `let`/`const` bindings so references can be marked readonly.
function collect_readonly_names(file: ast.SourceFile, names: ref[map_mod.Map[str, bool]]) -> void:
    var i: ptr_uint = 0
    while i < file.declarations.len:
        unsafe:
            match read(file.declarations.data + i):
                ast.Decl.decl_const as dc:
                    names.set(dc.name, true)
                ast.Decl.decl_function as fun:
                    collect_readonly_stmts(fun.body, names)
                ast.Decl.decl_extending_block as ex:
                    var j: ptr_uint = 0
                    while j < ex.methods.len:
                        collect_readonly_stmts(read(ex.methods.data + j).body, names)
                        j += 1
                _:
                    pass
        i += 1


function collect_readonly_stmts(body: ptr[ast.Stmt]?, names: ref[map_mod.Map[str, bool]]) -> void:
    if body == null:
        return
    unsafe:
        match read(body):
            ast.Stmt.stmt_block as blk:
                var si: ptr_uint = 0
                while si < blk.statements.len:
                    collect_readonly_stmt(blk.statements.data + si, names)
                    si += 1
            _:
                pass


function collect_readonly_stmt(sp: ptr[ast.Stmt], names: ref[map_mod.Map[str, bool]]) -> void:
    unsafe:
        match read(sp):
            ast.Stmt.stmt_local as loc:
                if (loc.is_let) and loc.name.len > 0 and loc.name != "_":
                    names.set(loc.name, true)
            ast.Stmt.stmt_block as blk:
                var si: ptr_uint = 0
                while si < blk.statements.len:
                    collect_readonly_stmt(blk.statements.data + si, names)
                    si += 1
            ast.Stmt.stmt_if as iff:
                var bi: ptr_uint = 0
                while bi < iff.branches.len:
                    collect_readonly_stmts(read(iff.branches.data + bi).body, names)
                    bi += 1
                collect_readonly_stmts(iff.else_body, names)
            ast.Stmt.stmt_while as wh:
                collect_readonly_stmts(wh.body, names)
            ast.Stmt.stmt_for as fr:
                collect_readonly_stmts(fr.body, names)
            ast.Stmt.stmt_match as mt:
                var ai: ptr_uint = 0
                while ai < mt.arms.len:
                    collect_readonly_stmts(read(mt.arms.data + ai).body, names)
                    ai += 1
            ast.Stmt.stmt_unsafe as un:
                collect_readonly_stmts(un.body, names)
            ast.Stmt.stmt_defer as df:
                collect_readonly_stmts(df.body, names)
            ast.Stmt.stmt_parallel_block as pb:
                var pri: ptr_uint = 0
                while pri < pb.bodies.len:
                    collect_readonly_stmt(pb.bodies.data + pri, names)
                    pri += 1
            _:
                pass


public function snapshot_semantic_entries(source: str) -> string.String:
    var result = string.String.create()

    var lex_diags = vec.Vec[token_mod.LexDiagnostic].create()
    defer: lex_diags.release()
    var all_tokens = lexer_mod.lex_reporting(source, ref_of(lex_diags))
    defer: all_tokens.release()

    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer: parse_diags.release()
    var ast_file = parser.parse_source(source, ref_of(parse_diags))
    var analysis = analyzer.check_source_file(ast_file)

    var param_names = collect_param_names(ref_of(analysis))
    defer: param_names.release()
    var readonly_names = map_mod.Map[str, bool].create()
    defer: readonly_names.release()
    collect_readonly_names(ast_file, ref_of(readonly_names))

    var lines = vec.Vec[ptr_uint].create()
    defer: lines.release()
    var pos: ptr_uint = 0
    while pos < source.len:
        lines.push(pos)
        while pos < source.len and source.byte_at(pos) != 10:
            pos += 1
        if pos < source.len:
            pos += 1
    lines.push(source.len)

    var first_entry = true
    result.append("[")

    var prev_ident_lexeme: str = ""
    var prev_is_decl: bool = false
    var prev_readonly: bool = false
    var in_enum_body: bool = false
    var enum_depth: ptr_uint = 0
    var in_struct_body: bool = false
    var struct_depth: ptr_uint = 0
    var in_extending: bool = false
    var extending_depth: ptr_uint = 0
    var in_import_path: bool = false
    var prev_was_dot: bool = false
    var in_decorator: bool = false
    var decorator_depth: ptr_uint = 0
    var seen_fn_keyword: bool = false
    var seen_fn_name: bool = false
    var in_param_list: bool = false
    var param_paren_depth: ptr_uint = 0

    var ti: ptr_uint = 0
    while ti < all_tokens.len():
        let tok_ptr = all_tokens.get(ti) else:
            break
        let tok = unsafe: read(tok_ptr)
        let kind = tok.kind

        if kind == tk_mod.TokenKind.dedent:
            if in_enum_body:
                enum_depth -= 1
                if enum_depth == 0:
                    in_enum_body = false
            if in_struct_body:
                struct_depth -= 1
                if struct_depth == 0:
                    in_struct_body = false
            if in_extending:
                extending_depth -= 1
                if extending_depth == 0:
                    in_extending = false
            if in_decorator:
                decorator_depth -= 1
                if decorator_depth == 0:
                    in_decorator = false
            ti += 1
            continue
        if kind == tk_mod.TokenKind.indent:
            if in_enum_body:
                enum_depth += 1
            if in_struct_body:
                struct_depth += 1
            if in_extending:
                extending_depth += 1
            if in_decorator:
                decorator_depth += 1
            ti += 1
            continue
        if kind == tk_mod.TokenKind.newline or kind == tk_mod.TokenKind.eof:
            in_import_path = false
            in_decorator = false
            decorator_depth = 0
            seen_fn_keyword = false
            seen_fn_name = false
            in_param_list = false
            param_paren_depth = 0
            ti += 1
            continue

        if kind == tk_mod.TokenKind.tk_import:
            in_import_path = true
        else if kind == tk_mod.TokenKind.tk_as:
            in_import_path = false

        var is_decl = false
        var is_readonly = false
        if kind == tk_mod.TokenKind.identifier:
            if prev_is_decl:
                is_decl = true
                is_readonly = prev_readonly
                prev_is_decl = false
                prev_readonly = false
            if in_enum_body and enum_depth >= 1:
                is_decl = true
                is_readonly = true
            if in_struct_body and struct_depth >= 1:
                is_decl = true
                is_readonly = true
        else:
            if kind == tk_mod.TokenKind.at:
                in_decorator = true
                decorator_depth = 0
            else if kind == tk_mod.TokenKind.lbracket and in_decorator:
                decorator_depth += 1
            else if kind == tk_mod.TokenKind.rbracket and in_decorator:
                if decorator_depth > 0:
                    decorator_depth -= 1
                if decorator_depth == 0:
                    in_decorator = false
            if seen_fn_name and kind == tk_mod.TokenKind.lparen:
                in_param_list = true
                param_paren_depth = 1
                seen_fn_name = false
            else if in_param_list and kind == tk_mod.TokenKind.lparen:
                param_paren_depth += 1
            else if in_param_list and kind == tk_mod.TokenKind.rparen:
                if param_paren_depth > 0:
                    param_paren_depth -= 1
                if param_paren_depth == 0:
                    in_param_list = false
            if kind == tk_mod.TokenKind.tk_enum or kind == tk_mod.TokenKind.tk_flags:
                in_enum_body = true
                enum_depth = 0
                prev_is_decl = true
            else if kind == tk_mod.TokenKind.tk_struct or kind == tk_mod.TokenKind.tk_union:
                in_struct_body = true
                struct_depth = 0
                prev_is_decl = true
            else:
                if kind == tk_mod.TokenKind.tk_extending:
                    in_extending = true
                    extending_depth = 0
                    prev_is_decl = true
                else:
                    if snapshot_is_decl_kind(kind):
                        prev_is_decl = true
                        prev_readonly = kind == tk_mod.TokenKind.tk_const or kind == tk_mod.TokenKind.tk_let
                        if kind == tk_mod.TokenKind.tk_function or kind == tk_mod.TokenKind.tk_async:
                            seen_fn_keyword = true
                    else:
                        prev_is_decl = false

        var token_type = token_kind_to_type(kind)
        if in_import_path and token_type == TOKEN_KEYWORD and kind != tk_mod.TokenKind.tk_import and kind != tk_mod.TokenKind.tk_as:
            token_type = TOKEN_NAMESPACE
        if kind == tk_mod.TokenKind.identifier:
            let lexeme = cursor.token_text(source, tok)
            var raw_type = classify_identifier(lexeme, ref_of(analysis))
            if readonly_names.contains(lexeme) and raw_type == TOKEN_VARIABLE:
                is_readonly = true
            if in_param_list and raw_type == TOKEN_VARIABLE:
                token_type = TOKEN_PARAMETER
                is_decl = true
                is_readonly = true
            else if in_decorator and decorator_depth == 1:
                token_type = TOKEN_DECORATOR
                is_decl = false
                is_readonly = false
            else if in_import_path and raw_type == TOKEN_VARIABLE:
                token_type = TOKEN_NAMESPACE
            else if in_enum_body and enum_depth == 1:
                if raw_type == TOKEN_VARIABLE:
                    token_type = TOKEN_ENUM_MEMBER
                else:
                    token_type = raw_type
                is_decl = true
            else if in_struct_body and struct_depth == 1:
                token_type = raw_type
            else:
                token_type = raw_type
                if prev_was_dot:
                    if prev_ident_lexeme.len > 0 and analysis.static_member_types.contains(prev_ident_lexeme):
                        token_type = TOKEN_ENUM_MEMBER
                        is_decl = false
                    else if raw_type != TOKEN_FUNCTION and raw_type != TOKEN_NAMESPACE and raw_type != TOKEN_TYPE:
                        token_type = TOKEN_METHOD
                else:
                    if in_extending and extending_depth >= 1 and is_decl:
                        token_type = TOKEN_METHOD
            prev_was_dot = false
            prev_ident_lexeme = lexeme
            if seen_fn_keyword:
                seen_fn_name = true
                seen_fn_keyword = false
            if in_enum_body and enum_depth == 1:
                is_decl = true
            if in_struct_body and struct_depth == 1:
                is_decl = true
        else:
            if kind == tk_mod.TokenKind.dot:
                prev_was_dot = true
            else:
                prev_was_dot = false

        if token_type == TOKEN_VARIABLE and not is_decl:
            if in_enum_body and enum_depth == 1:
                token_type = TOKEN_ENUM_MEMBER
                is_decl = true
            else if in_struct_body and struct_depth == 1:
                pass
            else if is_readonly:
                pass
            else:
                ti += 1
                continue
        if token_type == TOKEN_PARAMETER:
            if in_enum_body and enum_depth == 1:
                token_type = TOKEN_ENUM_MEMBER
                is_decl = true
            else if in_struct_body and struct_depth == 1:
                token_type = TOKEN_VARIABLE
                is_decl = true
            else if in_param_list:
                pass
            else if is_decl:
                token_type = TOKEN_VARIABLE
            else:
                ti += 1
                continue
        if token_type == TOKEN_STRING:
            # Skip heredoc markers so TextMate grammar handles them uniformly.
            let lexeme = unsafe: token_mod.token_lexeme(tok, source)
            match lexeme.find_substring("<<-"):
                Option.some:
                    ti += 1
                    continue
                Option.none:
                    pass

        var type_name = snapshot_token_type_name(token_type)
        if token_type == TOKEN_TYPE:
            type_name = "namespace"

        let line_num = if tok.line > 0: tok.line - 1 else: 0z
        let byte_start = if tok.column > 0: tok.column - 1 else: 0z
        let byte_len = tok.end_offset - tok.start_offset

        var char_start: ptr_uint = 0
        var char_len: ptr_uint = 0
        if line_num < lines.len() - 1z:
            let line_begin_ptr = lines.get(line_num) else:
                fatal(c"snapshot missing line")
            let line_end_ptr = lines.get(line_num + 1z) else:
                fatal(c"snapshot missing line end")
            let line_begin = unsafe: read(line_begin_ptr)
            let line_end = unsafe: read(line_end_ptr)
            let line_len = if line_end > line_begin and source.byte_at(line_end - 1) == 10: line_end - line_begin - 1 else: line_end - line_begin
            let line_text = unsafe: str(data = source.data + line_begin, len = line_len)
            char_start = snapshot_byte_to_char(line_text, byte_start)
            char_len = snapshot_byte_to_char(line_text, byte_start + byte_len) - char_start

        if not first_entry:
            result.append(",")
        first_entry = false
        result.append("{\"line\":")
        result.append_format(f"#{line_num}")
        result.append(",\"startChar\":")
        result.append_format(f"#{char_start}")
        result.append(",\"length\":")
        result.append_format(f"#{char_len}")
        result.append(",\"tokenType\":\"")
        result.append(type_name)
        result.append("\",\"modifiers\":[")
        if is_decl:
            result.append("\"declaration\"")
        if is_readonly:
            if is_decl:
                result.append(",")
            result.append("\"readonly\"")
        result.append("]}")
        ti += 1

    result.append("]")
    return result


function snapshot_is_decl_kind(kind: tk_mod.TokenKind) -> bool:
    return kind == tk_mod.TokenKind.tk_const or kind == tk_mod.TokenKind.tk_var or
       kind == tk_mod.TokenKind.tk_let or kind == tk_mod.TokenKind.tk_function or
       kind == tk_mod.TokenKind.tk_async or kind == tk_mod.TokenKind.tk_struct or
       kind == tk_mod.TokenKind.tk_enum or kind == tk_mod.TokenKind.tk_union or
       kind == tk_mod.TokenKind.tk_variant or kind == tk_mod.TokenKind.tk_flags or
       kind == tk_mod.TokenKind.tk_opaque or kind == tk_mod.TokenKind.tk_interface or
       kind == tk_mod.TokenKind.tk_type or kind == tk_mod.TokenKind.tk_event or
       kind == tk_mod.TokenKind.tk_extending or kind == tk_mod.TokenKind.tk_attribute or
       kind == tk_mod.TokenKind.tk_public or kind == tk_mod.TokenKind.tk_external or
       kind == tk_mod.TokenKind.tk_foreign or kind == tk_mod.TokenKind.tk_static or
       kind == tk_mod.TokenKind.tk_editable
