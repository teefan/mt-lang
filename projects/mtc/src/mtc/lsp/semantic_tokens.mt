## Semantic tokens — lexer token stream → LSP semantic token highlighting.
##
## Lexes the source file and maps Token kinds to LSP SemanticTokens with
## relative delta encoding (delta line, delta start char, length, type, mod).
## Identifier tokens are classified through the semantic Analysis maps:
## functions, types, namespaces (import aliases), and parameters.

import std.fmt
import std.json as json
import std.map as map_mod
import std.str
import std.string as string
import std.vec as vec

import mtc.lexer.lexer as lexer_mod
import mtc.lexer.token as token_mod
import mtc.lexer.token_kinds as tk
import mtc.loader.module_loader as loader
import mtc.loader.path_resolver as resolver
import mtc.parser.parser as parser
import mtc.parser.ast as ast
import mtc.semantic.analyzer as analyzer
import mtc.semantic.types as types
import mtc.lsp.cursor as cursor
import mtc.lsp.protocol as proto
import mtc.lsp.scope as scope_mod
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
## The "no entry" sentinel for a token the host's classifier skips (a character
## literal, a malformed format-string part).
const TOKEN_NONE:         uint = 1000


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

    # Diff against the tokens the client holds *before* replacing the cache: the
    # cached data belongs to the previous result id, and the delta must describe
    # the transition from it to the current tokens.
    var have_previous = false
    var old_data = vec.Vec[uint].create()
    defer: old_data.release()
    if cached_ptr != null:
        unsafe:
            let cached = read(cached_ptr)
            var di: ptr_uint = 0
            while di < cached.data.len():
                let dp = cached.data.get(di) else:
                    break
                old_data.push(read(dp))
                di += 1
        have_previous = true

    # Cache the new result (takes ownership of a copy of the token data).
    var cached_copy = vec.Vec[uint].create()
    var ci: ptr_uint = 0
    while ci < full_data.len():
        let cp = full_data.get(ci) else:
            break
        cached_copy.push(unsafe: read(cp))
        ci += 1
    ws.semantic_token_cache_set(file_path.as_str(), current_hash, string.String.from_str(result_id.as_str()), full_data.len() / 5, cached_copy)

    if have_previous:
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
    ## The alias members whose value binding is immutable (`const`), so a
    ## reference renders `variable` + `readonly` like the host's
    ## `semantic_value_binding_entry`.
    alias_readonly_values: map_mod.Map[str, bool]
    ## The analyzer's recorded callable-value sites (bare function names used
    ## where a callable type is expected), borrowed from the Analysis: only
    ## those render `function` (the host's `callable_value_identifier_sites`).
    callable_value_sites: span[analyzer.CallableValueSite]
    ## `<Type>.<Nested>` keys for every nested type a struct declares: a member
    ## of a type-name receiver that names one renders `type` (the host's
    ## `dot_nested_type_member?`).
    nested_type_keys: map_mod.Map[str, bool]
    ## `<Struct>.<field>` keys of the struct fields whose declared type is a
    ## function or proc: a call through such a field renders `property` (the
    ## host's `callable_field_member_access?`).
    callable_fields: map_mod.Map[str, bool]
    ## `<name>.<Struct>` keys for every `let x = Struct(...)` initializer: a
    ## callable-field receiver resolves against any struct the name is bound to
    ## in the file, which the host's `resolve_receiver_value_type` resolves
    ## scope-aware.  Every binding is kept — a file that reuses `c` for another
    ## type later must not hide the earlier receiver.
    receiver_structs: map_mod.Map[str, bool]
    ## The file's implicit value bindings (`scope_mod.collect_bindings`): a
    ## reference resolves the innermost binding in scope — the host's
    ## `local_semantic_value_binding` — instead of a flat name set.
    bindings: vec.Vec[scope_mod.Binding]
    ## The file's module-level `const` names: their value bindings are immutable.
    readonly_values: map_mod.Map[str, bool]
    ## `<Type>.<member>` keys of every *static* method the file declares or its
    ## resolved imports expose (`alias.<Type>.<member>` too): the host's
    ## `static_method_binding_for_receiver`, which is what tells a static call
    ## (`NPC.max_hp()`) apart from a variant arm (`Option.some(...)`).
    static_members: map_mod.Map[str, bool]
    ## The file's declarations' type-parameter scopes (`[T, U]` clauses), so a
    ## reference to `T` in a type position renders `typeParameter`.
    type_param_scopes: vec.Vec[scope_mod.TypeParamScope]
    ## Declared attribute names' positions (`attribute[field] rename(...)`), so
    ## the name renders `decorator` + declaration (the host's attribute override
    ## table, built from the AST).
    attribute_decls: map_mod.Map[ptr_uint, bool]
    ## Owns the composite-key buffers (`alias.member`, `Type.field`, ...) the
    ## maps above hold `str` views into.  `release_scan_facts` frees them with
    ## the maps, so a token request's tables do not accumulate.
    key_storage: vec.Vec[string.String]


## Release one scan's classification tables (the request's token data is built
## before this runs, so nothing reads them afterwards).
function release_scan_facts(facts: ref[ScanFacts]) -> void:
    facts.functions.release()
    facts.types.release()
    facts.structs.release()
    facts.interfaces.release()
    facts.values.release()
    facts.imports.release()
    facts.alias_functions.release()
    facts.alias_types.release()
    facts.alias_interfaces.release()
    facts.alias_values.release()
    facts.alias_readonly_values.release()
    facts.readonly_values.release()
    facts.static_members.release()
    facts.nested_type_keys.release()
    facts.callable_fields.release()
    facts.receiver_structs.release()
    facts.attribute_decls.release()
    facts.bindings.release()
    release_type_param_scopes(ref_of(facts.type_param_scopes))

    # The maps are gone; the key buffers can follow (the composite keys are the
    # only allocated strings — the rest of the keys view the AST or the source).
    var ki: ptr_uint = 0
    while ki < facts.key_storage.len():
        let key_ptr = facts.key_storage.get(ki) else:
            break
        unsafe:
            read(key_ptr).release()
        ki += 1
    facts.key_storage.release()


function release_type_param_scopes(scopes: ref[vec.Vec[scope_mod.TypeParamScope]]) -> void:
    var si: ptr_uint = 0
    while si < scopes.len():
        let scope_ptr = scopes.get(si) else:
            break
        unsafe:
            var names = read(scope_ptr).names
            names.release()
        si += 1
    scopes.release()


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


function scan_is_trivia(kind: tk.TokenKind) -> bool:
    return kind == tk.TokenKind.newline or kind == tk.TokenKind.indent or
        kind == tk.TokenKind.dedent or kind == tk.TokenKind.eof


function scan_kind_at(tokens: span[token_mod.Token], index: ptr_uint) -> tk.TokenKind:
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
        if kind == tk.TokenKind.rparen:
            depth += 1
        else if kind == tk.TokenKind.lparen:
            if depth == 0:
                return Option[ptr_uint].some(value = i)
            depth -= 1
    return Option[ptr_uint].none


## `name: T` immediately after `(`/`,` or a foreign mode keyword
## (the host's `parameter_declaration_token?`).
function scan_is_parameter_decl(tokens: span[token_mod.Token], index: ptr_uint) -> bool:
    let next_idx = scan_next_index(tokens, index) else:
        return false
    if scan_kind_at(tokens, next_idx) != tk.TokenKind.colon:
        return false
    let prev_idx = scan_prev_index(tokens, index) else:
        return false
    let prev_kind = scan_kind_at(tokens, prev_idx)
    return prev_kind == tk.TokenKind.lparen or prev_kind == tk.TokenKind.comma or
        prev_kind == tk.TokenKind.tk_out or prev_kind == tk.TokenKind.tk_in or
        prev_kind == tk.TokenKind.tk_inout or prev_kind == tk.TokenKind.tk_consuming


## True when the parameter list containing `index` belongs to a callable
## declaration (`function f(...)`, `fn(...)`, `proc(...)`)
## (the host's `callable_parameter_declaration_token?`).
function scan_is_callable_parameter_decl(tokens: span[token_mod.Token], index: ptr_uint) -> bool:
    if not scan_is_parameter_decl(tokens, index):
        return false
    let opener = scan_parameter_list_opener(tokens, index) else:
        return false
    var head_idx = scan_prev_index(tokens, opener) else:
        return false
    var head_kind = scan_kind_at(tokens, head_idx)
    if head_kind == tk.TokenKind.tk_fn or head_kind == tk.TokenKind.tk_proc:
        return true
    if head_kind == tk.TokenKind.rbracket:
        let lbracket = scan_matching_opener(tokens, head_idx) else:
            return false
        let head_opt = scan_prev_index(tokens, lbracket) else:
            return false
        head_idx = head_opt
        head_kind = scan_kind_at(tokens, head_idx)
    if head_kind != tk.TokenKind.identifier:
        return false
    let before = scan_prev_index(tokens, head_idx) else:
        return false
    return scan_kind_at(tokens, before) == tk.TokenKind.tk_function


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
        else if (closer == tk.TokenKind.rparen and kind == tk.TokenKind.lparen) or
                (closer == tk.TokenKind.rbracket and kind == tk.TokenKind.lbracket):
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
        return scan_line_has_enum_header(tokens, other.line)
    return false


## True when any token on `line` is `variant`/`enum`/`flags` — the host searches
## the whole header line (`non_trivia_tokens_on_line`), including the tokens
## after the one the backward scan stopped at.
function scan_line_has_enum_header(tokens: span[token_mod.Token], line: ptr_uint) -> bool:
    var i: ptr_uint = 0
    while i < tokens.len:
        let t = unsafe: read(tokens.data + i)
        if t.line > line:
            return false
        if t.line == line and (t.kind == tk.TokenKind.tk_variant or t.kind == tk.TokenKind.tk_enum or
                               t.kind == tk.TokenKind.tk_flags):
            return true
        i += 1
    return false


## True when the token is a struct/union field declaration: first on its line,
## followed by `:` and not part of a parameter list or match arm
## (the host's `field_declaration_token?`).
function scan_is_field_decl(tokens: span[token_mod.Token], index: ptr_uint) -> bool:
    if not scan_first_on_line(tokens, index):
        return false
    if scan_is_parameter_decl(tokens, index):
        return false
    if scan_is_match_arm_binding(tokens, index):
        return false
    let next_idx = scan_next_index(tokens, index) else:
        return false
    return scan_kind_at(tokens, next_idx) == tk.TokenKind.colon


## `as name:` — a match arm binding (the host's `match_arm_binding_token?`).
function scan_is_match_arm_binding(tokens: span[token_mod.Token], index: ptr_uint) -> bool:
    let prev_idx = scan_prev_index(tokens, index) else:
        return false
    if scan_kind_at(tokens, prev_idx) != tk.TokenKind.tk_as:
        return false
    let next_idx = scan_next_index(tokens, index) else:
        return false
    return scan_kind_at(tokens, next_idx) == tk.TokenKind.colon


## True when the token is a field of a variant arm's payload: a parameter-list
## member whose list head is a variant arm name
## (the host's `variant_payload_field_declaration_token?`).
function scan_is_variant_payload_field(tokens: span[token_mod.Token], index: ptr_uint) -> bool:
    if not scan_is_parameter_decl(tokens, index):
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
    var first_kind: tk.TokenKind = tk.TokenKind.eof
    var first_found = false
    var second_kind: tk.TokenKind = tk.TokenKind.eof
    var second_found = false
    var third_kind: tk.TokenKind = tk.TokenKind.eof
    var third_found = false
    var lparen_seen = false
    var equal_seen = false
    # Only this line's tokens matter, so start at the line's first token: the
    # scan used to walk the whole token array for every identifier, which is
    # O(n^2) on a large file (99 ms of a 1700-line file's token request).
    var i = index
    while i > 0:
        if unsafe: read(tokens.data + i - 1).line != tok.line:
            break
        i -= 1
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
            if t.kind == tk.TokenKind.lparen and not equal_seen:
                lparen_seen = true
            if t.kind == tk.TokenKind.equal:
                equal_seen = true
        i += 1
    if not first_found or first_kind != tk.TokenKind.tk_let:
        return false
    if not lparen_seen:
        return false
    if second_found and second_kind == tk.TokenKind.lparen:
        return true
    return second_found and second_kind == tk.TokenKind.identifier and third_found and third_kind == tk.TokenKind.lparen


## A named-argument label (`name =` after `(`/`,`): `property` inside a type
## constructor call, `parameter` otherwise
## (the host's `named_argument_label_token?`).
function scan_is_named_argument_label(tokens: span[token_mod.Token], index: ptr_uint) -> bool:
    let next_idx = scan_next_index(tokens, index) else:
        return false
    if scan_kind_at(tokens, next_idx) != tk.TokenKind.equal:
        return false
    let prev_idx = scan_prev_index(tokens, index) else:
        return false
    let prev_kind = scan_kind_at(tokens, prev_idx)
    return prev_kind == tk.TokenKind.lparen or prev_kind == tk.TokenKind.comma


## True when the named-argument label belongs to a *type constructor*: a call
## whose callee is a declared type or one of its arms — `Sample(x = 1)`,
## `Option[int].some(value = 2)` — where the host renders the label as a
## property.  Only the file's own declared types count: a builtin constructor
## (`span[int](data = ...)`) keeps the parameter shape, and the receiver's
## type-argument list is seen through (the host's
## `named_argument_label_in_type_constructor?`).
function scan_named_argument_in_type_constructor(facts: ref[ScanFacts], tokens: span[token_mod.Token], index: ptr_uint, source: str) -> bool:
    let opener = scan_parameter_list_opener(tokens, index) else:
        return false
    var callee_idx = scan_prev_index(tokens, opener) else:
        return false
    if scan_kind_at(tokens, callee_idx) == tk.TokenKind.rbracket:
        let lbracket = scan_matching_opener(tokens, callee_idx) else:
            return false
        let callee_base = scan_prev_index(tokens, lbracket) else:
            return false
        callee_idx = callee_base
    if scan_kind_at(tokens, callee_idx) != tk.TokenKind.identifier:
        return false
    let callee_name = scan_lexeme_at(tokens, callee_idx, source)
    if scan_is_declared_type(facts, callee_name):
        return true
    let dot_idx = scan_prev_index(tokens, callee_idx) else:
        return false
    if scan_kind_at(tokens, dot_idx) != tk.TokenKind.dot:
        return false
    var receiver_idx = scan_prev_index(tokens, dot_idx) else:
        return false
    if scan_kind_at(tokens, receiver_idx) == tk.TokenKind.rbracket:
        let lbracket = scan_matching_opener(tokens, receiver_idx) else:
            return false
        let receiver_base = scan_prev_index(tokens, lbracket) else:
            return false
        receiver_idx = receiver_base
    if scan_kind_at(tokens, receiver_idx) != tk.TokenKind.identifier:
        return false
    return scan_is_declared_type(facts, scan_lexeme_at(tokens, receiver_idx, source))


## True for a *declared* type or interface name — the file's own types, not the
## builtins (`is_known_type_name?` in the host counts only `facts.types`).
function scan_is_declared_type(facts: ref[ScanFacts], name: str) -> bool:
    unsafe:
        return read(facts).types.contains(name) or read(facts).interfaces.contains(name)


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
    if scan_kind_at(tokens, line_start) != tk.TokenKind.tk_import:
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
            if t.kind == tk.TokenKind.tk_as:
                seen_as = true
            else if i == index and not seen_as and i != line_start:
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
    if scan_kind_at(tokens, line_start) != tk.TokenKind.tk_import:
        return false
    let prev_idx = scan_prev_index(tokens, index) else:
        return false
    return scan_kind_at(tokens, prev_idx) == tk.TokenKind.tk_as



## The declared attribute names' positions (`attribute[field] name(...)`).
function collect_attribute_decl_names(file: ast.SourceFile, names: ref[map_mod.Map[ptr_uint, bool]]) -> void:
    var i: ptr_uint = 0
    while i < file.declarations.len:
        unsafe:
            match read(file.declarations.data + i):
                ast.Decl.decl_attribute as attr:
                    names.set(attribute_position_key(attr.line, attr.column), true)
                _:
                    pass
        i += 1


## A token position as one map key (`line * 10000 + column`), so the override
## table needs no string keys that a temporary would invalidate.
function attribute_position_key(line: ptr_uint, column: ptr_uint) -> ptr_uint:
    return line * 10000 + column


## The token class an attribute-name override gives, or none: the declared
## attribute's own name (`decorator` + declaration) and the name passed to a
## `has_attribute` / `attribute_of` call (the host's
## `build_attribute_name_semantic_overrides`).
function scan_attribute_override(facts: ref[ScanFacts], tokens: span[token_mod.Token], index: ptr_uint, source: str) -> Option[TokenClass]:
    let tok = unsafe: read(tokens.data + index)
    if unsafe: read(facts).attribute_decls.contains(attribute_position_key(tok.line, tok.column)):
        return Option[TokenClass].some(value = TokenClass(token_type = TOKEN_DECORATOR, token_mod = 1))
    if scan_is_attribute_reflection_name(tokens, index, source):
        return Option[TokenClass].some(value = TokenClass(token_type = TOKEN_DECORATOR, token_mod = 0))
    return Option[TokenClass].none


## True for the second argument of a `has_attribute(...)` / `attribute_of(...)`
## call — the position those builtins read an attribute name from.
function scan_is_attribute_reflection_name(tokens: span[token_mod.Token], index: ptr_uint, source: str) -> bool:
    let comma = scan_prev_index(tokens, index) else:
        return false
    if scan_kind_at(tokens, comma) != tk.TokenKind.comma:
        return false
    # The comma must be a top-level one: the nearest unmatched opener before it
    # is the call's `(`.
    var depth: ptr_uint = 0
    var opener: ptr_uint = 0
    var found = false
    var i = comma
    while i > 0:
        i -= 1
        let kind = scan_kind_at(tokens, i)
        if kind == tk.TokenKind.rparen or kind == tk.TokenKind.rbracket:
            depth += 1
        else if kind == tk.TokenKind.lparen:
            if depth == 0:
                opener = i
                found = true
                break
            depth -= 1
        else if kind == tk.TokenKind.lbracket:
            if depth > 0:
                depth -= 1
    if not found:
        return false
    let callee = scan_prev_index(tokens, opener) else:
        return false
    # `has_attribute` / `attribute_of` lex as keywords.
    let name = scan_lexeme_at(tokens, callee, source)
    return name.equal("has_attribute") or name.equal("attribute_of")


## True for a specialized call `name[T](...)` — the host's
## `specialized_call_with_type_args?`: a type-argument list whose closer is
## followed by the call's `(`.
function scan_specialized_call(tokens: span[token_mod.Token], index: ptr_uint) -> bool:
    let lbracket = scan_next_index(tokens, index) else:
        return false
    if scan_kind_at(tokens, lbracket) != tk.TokenKind.lbracket:
        return false
    let rbracket = scan_matching_closer_index(tokens, lbracket, tk.TokenKind.lbracket, tk.TokenKind.rbracket) else:
        return false
    let after = scan_next_index(tokens, rbracket) else:
        return false
    return scan_kind_at(tokens, after) == tk.TokenKind.lparen


## True for a *bare* builtin specialization (`zero[int]`, `default[T]`): a
## type-argument list the call's `(` does not follow — the host's
## `bare_builtin_specialization?`.
function scan_bare_specialization(tokens: span[token_mod.Token], index: ptr_uint) -> bool:
    let lbracket = scan_next_index(tokens, index) else:
        return false
    if scan_kind_at(tokens, lbracket) != tk.TokenKind.lbracket:
        return false
    let rbracket = scan_matching_closer_index(tokens, lbracket, tk.TokenKind.lbracket, tk.TokenKind.rbracket) else:
        return false
    let after = scan_next_index(tokens, rbracket) else:
        return true
    return scan_kind_at(tokens, after) != tk.TokenKind.lparen


## The index of the closer matching the opener at `opener_index`, or none.
function scan_matching_closer_index(
    tokens: span[token_mod.Token],
    opener_index: ptr_uint,
    open_kind: tk.TokenKind,
    close_kind: tk.TokenKind,
) -> Option[ptr_uint]:
    var depth: ptr_uint = 0
    var i = opener_index
    while i < tokens.len:
        let kind = scan_kind_at(tokens, i)
        if kind == open_kind:
            depth += 1
        else if kind == close_kind:
            if depth > 0:
                depth -= 1
            if depth == 0:
                return Option[ptr_uint].some(value = i)
        i += 1
    return Option[ptr_uint].none


## True when the identifier sits inside a type-argument list (`Vec[int]`,
## `SoA[Point, 4]`) — the host's `identifier_in_type_argument_position?`: the
## previous significant token is `[`, or a `,` whose enclosing opener is `[`,
## and a matching `]` follows the identifier.
function scan_identifier_in_type_argument_position(tokens: span[token_mod.Token], index: ptr_uint) -> bool:
    var opener = scan_prev_index(tokens, index) else:
        return false

    if scan_kind_at(tokens, opener) == tk.TokenKind.comma:
        var depth: ptr_uint = 0
        var found = false
        var i = opener
        while i > 0:
            i -= 1
            let kind = scan_kind_at(tokens, i)
            if kind == tk.TokenKind.rbracket:
                depth += 1
            else if kind == tk.TokenKind.lbracket:
                if depth == 0:
                    opener = i
                    found = true
                    break
                depth -= 1
        if not found:
            return false

    if scan_kind_at(tokens, opener) != tk.TokenKind.lbracket:
        return false
    let closer = scan_matching_closer_index(
        tokens, opener, tk.TokenKind.lbracket, tk.TokenKind.rbracket) else:
        return false
    let next_idx = scan_next_index(tokens, index) else:
        return false
    return next_idx <= closer


## True when the token is one of a declaration's type-parameter names: an
## identifier at depth 1 of a `<header> <name>[...]` clause on its line
## (`struct Pair[A, B]`, `function f[T implements Named]`) — the host's
## `type_parameter_declaration_info_on_line`.
function scan_type_parameter_declaration_token(tokens: span[token_mod.Token], index: ptr_uint, source: str) -> bool:
    let line = unsafe: read(tokens.data + index).line
    var first = index
    while first > 0:
        let prev = first - 1
        if scan_is_trivia(scan_kind_at(tokens, prev)):
            first = prev
            continue
        if unsafe: read(tokens.data + prev).line != line:
            break
        first = prev

    var header: ptr_uint = 0
    var found_header = false
    var hi = first
    while hi <= index:
        if scan_is_type_parameter_header(scan_kind_at(tokens, hi)):
            header = hi
            found_header = true
            break
        hi += 1
    if not found_header:
        return false

    var name_idx: ptr_uint = 0
    var found_name = false
    var ni = header + 1
    while ni <= index:
        if scan_kind_at(tokens, ni) == tk.TokenKind.identifier:
            name_idx = ni
            found_name = true
            break
        ni += 1
    if not found_name:
        return false

    let lbracket = name_idx + 1
    if lbracket > index or scan_kind_at(tokens, lbracket) != tk.TokenKind.lbracket:
        return false

    var depth: ptr_uint = 0
    var expect_name = false
    var k = lbracket
    while k <= index:
        let kind = scan_kind_at(tokens, k)
        if kind == tk.TokenKind.lbracket:
            depth += 1
            if depth == 1:
                expect_name = true
        else if kind == tk.TokenKind.rbracket:
            if depth > 0:
                depth -= 1
            if depth == 0:
                return false
        else if kind == tk.TokenKind.comma:
            if depth == 1:
                expect_name = true
        else if kind == tk.TokenKind.at or kind == tk.TokenKind.tk_implements:
            if depth == 1:
                expect_name = false
        else if depth == 1 and expect_name and kind == tk.TokenKind.identifier:
            if k == index:
                return true
            expect_name = false
        k += 1
    return false


## The declaration keywords whose header can carry a type-parameter clause
## (the host's `generic_type_parameter_header_token?`).
function scan_is_type_parameter_header(kind: tk.TokenKind) -> bool:
    return kind == tk.TokenKind.tk_function or kind == tk.TokenKind.tk_struct or
        kind == tk.TokenKind.tk_union or kind == tk.TokenKind.tk_enum or
        kind == tk.TokenKind.tk_flags or kind == tk.TokenKind.tk_variant or
        kind == tk.TokenKind.tk_type or kind == tk.TokenKind.tk_extending


## True when the token references a type parameter of the enclosing declaration
## in a type position — inside a type-argument list, or after `:`/`->` (the
## host's `type_parameter_reference_token?`).
function scan_type_parameter_reference(facts: ref[ScanFacts], tokens: span[token_mod.Token], index: ptr_uint, source: str) -> bool:
    let lexeme = scan_lexeme_at(tokens, index, source)
    let line = unsafe: read(tokens.data + index).line
    if not scan_type_param_in_scope(facts, lexeme, line):
        return false
    if scan_identifier_in_type_argument_position(tokens, index):
        return true
    let prev = scan_prev_index(tokens, index) else:
        return false
    let kind = scan_kind_at(tokens, prev)
    return kind == tk.TokenKind.colon or kind == tk.TokenKind.arrow


## True when `name` is a type parameter in scope at `line`.
function scan_type_param_in_scope(facts: ref[ScanFacts], name: str, line: ptr_uint) -> bool:
    var found = false
    unsafe:
        var scopes = read(facts).type_param_scopes
        var si: ptr_uint = 0
        while si < scopes.len():
            let sp = scopes.get(si) else:
                break
            let sc = read(sp)
            if line >= sc.start_line and line <= sc.end_line:
                var ni: ptr_uint = 0
                while ni < sc.names.len():
                    let np = sc.names.get(ni) else:
                        break
                    if read(np).equal(name):
                        found = true
                        break
                    ni += 1
            si += 1
    return found


## True when a keyword token is a module-path segment (`import std.async as aio`)
## — the host's `namespace_keyword_token?`, whose name classifier answers
## `namespace` for it.
function scan_keyword_namespace_token(tokens: span[token_mod.Token], index: ptr_uint, source: str) -> bool:
    return scan_import_module_path(tokens, index, source)


## True for a character literal: the host's classifier has no arm for one, so it
## emits no entry.
function scan_is_char_literal(kind: tk.TokenKind) -> bool:
    return kind == tk.TokenKind.char_literal


## True when a keyword is a declaration name followed by a colon and is not a
## standalone block keyword — the host's `keyword_field_declaration_token?`
## (which is what colors a `null` ending an `if …:` line as a field
## declaration).
function scan_is_keyword_field_decl(tokens: span[token_mod.Token], index: ptr_uint) -> bool:
    let kind = scan_kind_at(tokens, index)
    if kind == tk.TokenKind.tk_unsafe or kind == tk.TokenKind.tk_else or
       kind == tk.TokenKind.tk_defer or kind == tk.TokenKind.tk_parallel:
        return false
    if scan_is_match_arm_binding(tokens, index):
        return false
    if scan_is_destructure_let(tokens, index):
        return false
    let next_idx = scan_next_index(tokens, index) else:
        return false
    return scan_kind_at(tokens, next_idx) == tk.TokenKind.colon


## True when the previous significant token is a dot.
function scan_prev_is_dot(tokens: span[token_mod.Token], index: ptr_uint) -> bool:
    let prev_idx = scan_prev_index(tokens, index) else:
        return false
    return scan_kind_at(tokens, prev_idx) == tk.TokenKind.dot


## Classify one identifier token (the host's `classify_name_semantic`).
function classify_scan_identifier(
    facts: ref[ScanFacts],
    tokens: span[token_mod.Token],
    index: ptr_uint,
    lexeme: str,
    source: str,
) -> TokenClass:
    # Attribute names: a declared attribute's own name (`attribute[field] rename`)
    # renders `decorator` + declaration, and the name a `has_attribute` /
    # `attribute_of` call reads renders `decorator` (the host's AST-built
    # override table, checked before every other arm).
    match scan_attribute_override(facts, tokens, index, source):
        Option.some as over:
            return over.value
        Option.none:
            pass

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
        if prev_kind == tk.TokenKind.tk_function or prev_kind == tk.TokenKind.tk_fn or
           prev_kind == tk.TokenKind.tk_proc:
            return TokenClass(token_type = TOKEN_FUNCTION, token_mod = 1)
        if prev_kind == tk.TokenKind.tk_struct or prev_kind == tk.TokenKind.tk_union or
           prev_kind == tk.TokenKind.tk_enum or prev_kind == tk.TokenKind.tk_flags or
           prev_kind == tk.TokenKind.tk_variant or prev_kind == tk.TokenKind.tk_type or
           prev_kind == tk.TokenKind.tk_opaque or prev_kind == tk.TokenKind.tk_interface:
            return TokenClass(token_type = TOKEN_TYPE, token_mod = 1)
    if lexeme.equal("_"):
        return TokenClass(token_type = TOKEN_VARIABLE, token_mod = 0)
    if prev_opt.is_some():
        let prev_kind = scan_kind_at(tokens, prev_opt.unwrap())
        if prev_kind == tk.TokenKind.tk_event:
            return TokenClass(token_type = TOKEN_VARIABLE, token_mod = 1)
        if prev_kind == tk.TokenKind.tk_const:
            return TokenClass(token_type = TOKEN_VARIABLE, token_mod = 5)
        if prev_kind == tk.TokenKind.tk_let:
            let next_idx = scan_next_index(tokens, index)
            var next_is_lparen = false
            if next_idx.is_some():
                next_is_lparen = scan_kind_at(tokens, next_idx.unwrap()) == tk.TokenKind.lparen
            if not next_is_lparen:
                return TokenClass(token_type = TOKEN_VARIABLE, token_mod = 5)
        if prev_kind == tk.TokenKind.tk_var:
            let next_idx = scan_next_index(tokens, index)
            var next_is_lparen = false
            if next_idx.is_some():
                next_is_lparen = scan_kind_at(tokens, next_idx.unwrap()) == tk.TokenKind.lparen
            if not next_is_lparen:
                return TokenClass(token_type = TOKEN_VARIABLE, token_mod = 1)
        if prev_kind == tk.TokenKind.tk_for:
            return TokenClass(token_type = TOKEN_VARIABLE, token_mod = 5)
    if scan_is_match_arm_binding(tokens, index):
        return TokenClass(token_type = TOKEN_VARIABLE, token_mod = 5)
    if scan_is_callable_parameter_decl(tokens, index):
        return TokenClass(token_type = TOKEN_PARAMETER, token_mod = 1)
    if scan_is_variant_payload_field(tokens, index):
        return TokenClass(token_type = TOKEN_PROPERTY, token_mod = 1)
    if scan_is_field_decl(tokens, index):
        return TokenClass(token_type = TOKEN_PROPERTY, token_mod = 1)
    if scan_is_destructure_let(tokens, index):
        return TokenClass(token_type = TOKEN_VARIABLE, token_mod = 5)
    # Type parameters: the declaration's own `[T, U]` names and their references
    # in a type position (the host's `type_parameter_declaration_token?` /
    # `type_parameter_reference_token?`).
    if scan_type_parameter_declaration_token(tokens, index, source):
        return TokenClass(token_type = TOKEN_TYPE_PARAM, token_mod = 1)
    if scan_type_parameter_reference(facts, tokens, index, source):
        return TokenClass(token_type = TOKEN_TYPE_PARAM, token_mod = 0)
    if scan_is_named_argument_label(tokens, index):
        if scan_named_argument_in_type_constructor(facts, tokens, index, source):
            return TokenClass(token_type = TOKEN_PROPERTY, token_mod = 0)
        return TokenClass(token_type = TOKEN_PARAMETER, token_mod = 0)

    # Variant arm names are members of the variant's member set.
    if scan_is_variant_enum_member(tokens, index):
        return TokenClass(token_type = TOKEN_ENUM_MEMBER, token_mod = 1)

    # A type argument renders a *declared* type name without the defaultLibrary
    # modifier (`Vec[int]`, `SoA[Point, 4]`) — the host's
    # `identifier_in_type_argument_position?` arm, whose `known_type_name?`
    # counts only the facts' declared types, so a builtin constructor (`ptr` in
    # `null[ptr[int]]`) keeps its `type` + defaultLibrary entry.
    if scan_identifier_in_type_argument_position(tokens, index):
        if unsafe: read(facts).types.contains(lexeme) or read(facts).interfaces.contains(lexeme):
            return TokenClass(token_type = TOKEN_TYPE, token_mod = 0)

    # Dotted member access.
    if prev_opt.is_some() and scan_kind_at(tokens, prev_opt.unwrap()) == tk.TokenKind.dot:
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
                        call_shaped = nk == tk.TokenKind.lparen or nk == tk.TokenKind.lbracket
                    if call_shaped:
                        return TokenClass(token_type = TOKEN_FUNCTION, token_mod = 0)
                    return TokenClass(token_type = TOKEN_PROPERTY, token_mod = 0)
                if unsafe: read(facts).alias_types.contains(key):
                    return TokenClass(token_type = TOKEN_TYPE, token_mod = 0)
                if unsafe: read(facts).alias_interfaces.contains(key):
                    return TokenClass(token_type = TOKEN_TYPE, token_mod = 0)
                if unsafe: read(facts).alias_values.contains(key):
                    if unsafe: read(facts).alias_readonly_values.contains(key):
                        return TokenClass(token_type = TOKEN_VARIABLE, token_mod = 4)
                    return TokenClass(token_type = TOKEN_VARIABLE, token_mod = 0)
            if receiver_is_type_name(facts, tokens, receiver_idx.unwrap(), source):
                # A static method of the receiver's type is a `method`; every
                # other member of a type-name receiver is a variant/enum member
                # (`Option.some(value = 42)`), as the host's
                # `static_type_member_access?` before `type_name_member_access?`.
                if is_static_member_of(facts, tokens, receiver_idx.unwrap(), lexeme, source):
                    return TokenClass(token_type = TOKEN_METHOD, token_mod = 0)
                # A nested type name of the receiver's struct renders `type`
                # (`Rectangle.Edge`), the host's `dot_nested_type_member?`.
                if scan_nested_type_member(facts, tokens, index, source):
                    return TokenClass(token_type = TOKEN_TYPE, token_mod = 0)
                return TokenClass(token_type = TOKEN_ENUM_MEMBER, token_mod = 0)
        let next_idx = scan_next_index(tokens, index)
        if next_idx.is_some() and scan_kind_at(tokens, next_idx.unwrap()) == tk.TokenKind.lparen:
            # A call through a struct field of function/proc type is a
            # `property` (the host's `callable_field_member_access?`), not a
            # method of the receiver's type.
            if scan_callable_field_call(facts, tokens, index, source):
                return TokenClass(token_type = TOKEN_PROPERTY, token_mod = 0)
            return TokenClass(token_type = TOKEN_METHOD, token_mod = 0)
        if scan_specialized_call(tokens, index):
            return TokenClass(token_type = TOKEN_METHOD, token_mod = 0)
        return TokenClass(token_type = TOKEN_PROPERTY, token_mod = 0)


    # Call sites: builtins, functions, then type constructors.  A *specialized*
    # call carries a type-argument list between the callee and the call
    # (`span[int](...)`, `hash[int](...)`), which the host's
    # `specialized_call_with_type_args?` treats as a call shape too.
    let next_call = scan_next_index(tokens, index)
    if next_call.is_some():
        let next_kind = scan_kind_at(tokens, next_call.unwrap())
        if next_kind == tk.TokenKind.lparen or scan_specialized_call(tokens, index):
            # A bound value shadows the function name (the host's
            # `resolved_call_callee_semantic` resolves the local binding and the
            # module values before the builtin/function tables).
            match scan_binding_at(facts, tokens, index, source):
                Option.some as kind:
                    return scan_binding_class(kind.value)
                Option.none:
                    pass
            if unsafe: read(facts).values.contains(lexeme):
                if unsafe: read(facts).readonly_values.contains(lexeme):
                    return TokenClass(token_type = TOKEN_VARIABLE, token_mod = 4)
                return TokenClass(token_type = TOKEN_VARIABLE, token_mod = 0)
            if is_default_library_function_name(lexeme):
                return TokenClass(token_type = TOKEN_FUNCTION, token_mod = 512)
            if unsafe: read(facts).functions.contains(lexeme):
                return TokenClass(token_type = TOKEN_FUNCTION, token_mod = 0)
            if is_constructible_type_name(facts, lexeme):
                return TokenClass(token_type = TOKEN_TYPE, token_mod = 0)
            # The hash/order/equal hooks are defaultLibrary only in their
            # specialized form (the host's `BUILTIN_ASSOCIATED_HOOK_NAMES`).
            if scan_specialized_call(tokens, index) and
               (lexeme.equal("hash") or lexeme.equal("equal") or lexeme.equal("order")):
                return TokenClass(token_type = TOKEN_FUNCTION, token_mod = 512)
            return TokenClass(token_type = TOKEN_FUNCTION, token_mod = 0)
    # A bare builtin specialization (`zero[int]`, `default[T]`, no call) is a
    # builtin function value (the host's `bare_builtin_specialization?`).
    if (lexeme.equal("zero") or lexeme.equal("default")) and scan_bare_specialization(tokens, index):
        return TokenClass(token_type = TOKEN_FUNCTION, token_mod = 512)

    # Value / type / namespace references.  A name bound in scope resolves to
    # that binding (the host's `local_semantic_value_binding`, whose snapshot
    # carries the innermost binding at the token), so a parameter renders
    # `parameter`, a `let`/`for`/match binding `variable` + `readonly` and a
    # `var` bare `variable`.  A *receiver before a dot* resolves through the
    # host's dedicated arm first: a declared type name renders `type` without
    # the defaultLibrary modifier (`Option.some`), an import alias `namespace`.
    let next_dot = scan_next_index(tokens, index)
    if next_dot.is_some() and scan_kind_at(tokens, next_dot.unwrap()) == tk.TokenKind.dot:
        unsafe:
            if read(facts).types.contains(lexeme) or read(facts).interfaces.contains(lexeme):
                return TokenClass(token_type = TOKEN_TYPE, token_mod = 0)
            if read(facts).imports.contains(lexeme):
                return TokenClass(token_type = TOKEN_NAMESPACE, token_mod = 0)
    # A type name in a type-reference position renders `type`, a builtin one
    # with the defaultLibrary modifier; other names fall through to the value
    # arms (the host's `identifier_in_type_reference_position?` arm).
    if scan_identifier_in_type_argument_position(tokens, index) or scan_after_type_position(tokens, index, source):
        unsafe:
            if read(facts).types.contains(lexeme):
                if is_default_library_type_name(lexeme):
                    return TokenClass(token_type = TOKEN_TYPE, token_mod = 512)
                return TokenClass(token_type = TOKEN_TYPE, token_mod = 0)
            if read(facts).interfaces.contains(lexeme):
                return TokenClass(token_type = TOKEN_TYPE, token_mod = 0)
        if is_default_library_type_name(lexeme):
            return TokenClass(token_type = TOKEN_TYPE, token_mod = 512)
    match scan_binding_at(facts, tokens, index, source):
        Option.some as kind:
            # A parameter declaration token carries the declaration modifier
            # (the host passes `parameter_declaration_token?` into
            # `semantic_value_binding_entry`; the `in` of a `for … in name:`
            # line answers that predicate there too).
            if kind.value == scope_mod.BINDING_PARAM and scan_is_parameter_decl(tokens, index):
                return TokenClass(token_type = TOKEN_PARAMETER, token_mod = 1)
            return scan_binding_class(kind.value)
        Option.none:
            pass
    if lexeme.equal("this"):
        return TokenClass(token_type = TOKEN_PARAMETER, token_mod = 0)
    unsafe:
        if read(facts).functions.contains(lexeme) and scan_callable_value_site(facts, tokens, index):
            # A bare function name is a `function` token only where the analyzer
            # recorded a callable-value site (the host's
            # `bare_function_value_identifier_site?`); a name that resolves to a
            # binding, or the `callable_of(x)` form, is a plain variable.
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
            if read(facts).readonly_values.contains(lexeme):
                return TokenClass(token_type = TOKEN_VARIABLE, token_mod = 4)
            return TokenClass(token_type = TOKEN_VARIABLE, token_mod = 0)
    if is_default_library_type_name(lexeme):
        return TokenClass(token_type = TOKEN_TYPE, token_mod = 512)
    return TokenClass(token_type = TOKEN_VARIABLE, token_mod = 0)


## True when the token stands right after a type-position marker: `:`/`->`/`as`,
## or `=` on a `type`-headed line (`const A: type = B`) — the host's
## `identifier_in_type_reference_position?` without the type-argument case the
## caller checks separately.
function scan_after_type_position(tokens: span[token_mod.Token], index: ptr_uint, source: str) -> bool:
    let prev = scan_prev_index(tokens, index) else:
        return false
    let kind = scan_kind_at(tokens, prev)
    if kind == tk.TokenKind.colon or kind == tk.TokenKind.arrow or kind == tk.TokenKind.tk_as:
        return true
    if kind != tk.TokenKind.equal:
        return false
    let line = unsafe: read(tokens.data + index).line
    var i: ptr_uint = 0
    while i < index:
        let t = unsafe: read(tokens.data + i)
        if t.line == line and not scan_is_trivia(t.kind):
            return t.kind == tk.TokenKind.tk_type
        i += 1
    return false


## A keyword in a type-parameter position (`[@a]`, `[T]`, a list entry after a
## comma inside a type-parameter clause) renders `typeParameter` — the host's
## `keyword_lifetime_or_type_param?`.
function scan_is_keyword_type_parameter(tokens: span[token_mod.Token], index: ptr_uint) -> bool:
    let prev = scan_prev_index(tokens, index) else:
        return false
    let kind = scan_kind_at(tokens, prev)
    if kind == tk.TokenKind.at or kind == tk.TokenKind.lbracket:
        return true
    if kind != tk.TokenKind.comma:
        return false
    var i = prev
    while i > 0:
        i -= 1
        let k = scan_kind_at(tokens, i)
        if k == tk.TokenKind.lbracket:
            break
        if k == tk.TokenKind.newline or k == tk.TokenKind.rbracket or k == tk.TokenKind.lparen:
            return false
    if i == 0:
        return false
    let before = scan_prev_index(tokens, i) else:
        return false
    let bk = scan_kind_at(tokens, before)
    if bk == tk.TokenKind.tk_struct or bk == tk.TokenKind.tk_variant or bk == tk.TokenKind.tk_enum or
       bk == tk.TokenKind.tk_flags or bk == tk.TokenKind.tk_function or bk == tk.TokenKind.tk_fn or
       bk == tk.TokenKind.tk_proc:
        return true
    return bk == tk.TokenKind.rbracket


## A keyword type name in an annotation position: the previous significant token
## is `:` or `->` on the same line (`x: proc() -> int`) — the host's
## `keyword_type_annotation?`.
function scan_is_keyword_type_annotation(tokens: span[token_mod.Token], index: ptr_uint) -> bool:
    let prev = scan_prev_index(tokens, index) else:
        return false
    let kind = scan_kind_at(tokens, prev)
    if kind != tk.TokenKind.colon and kind != tk.TokenKind.arrow:
        return false
    return unsafe: read(tokens.data + prev).line == read(tokens.data + index).line


## The binding in scope at a token (the host's `local_semantic_value_binding`):
## the kind of the innermost function-level binding of the token's name.
function scan_binding_at(facts: ref[ScanFacts], tokens: span[token_mod.Token], index: ptr_uint, source: str) -> Option[ptr_uint]:
    let tok = unsafe: read(tokens.data + index)
    return scope_mod.binding_kind_at(unsafe: read(facts).bindings, scan_lexeme_at(tokens, index, source), tok.line)


## The token class a value binding renders: `parameter`, `variable` +
## `readonly` for an immutable binding, bare `variable` for a mutable one.
function scan_binding_class(kind: ptr_uint) -> TokenClass:
    if kind == scope_mod.BINDING_PARAM:
        return TokenClass(token_type = TOKEN_PARAMETER, token_mod = 0)
    if kind == scope_mod.BINDING_MUTABLE:
        return TokenClass(token_type = TOKEN_VARIABLE, token_mod = 0)
    return TokenClass(token_type = TOKEN_VARIABLE, token_mod = 4)


## True when the token is a member of a *static* method of the receiver's type
## (the host's `static_type_member_access?`): the receiver may carry type
## arguments (`Option[int].some`) and a module prefix (`rl.Color.hex_digit`),
## and the method may come from the scanned file or a resolved import.
function is_static_member_of(facts: ref[ScanFacts], tokens: span[token_mod.Token], receiver_index: ptr_uint, member: str, source: str) -> bool:
    var key = string.String.create()
    defer: key.release()
    let module_prefix = receiver_module_prefix(tokens, receiver_index, source)
    if module_prefix.len > 0:
        key.append(module_prefix)
        key.push_byte(46)
    key.append(receiver_base_name(tokens, receiver_index, source))
    key.push_byte(46)
    key.append(member)
    unsafe:
        return read(facts).static_members.contains(key.as_str())


## The identifier before a `module.Type` pair — the import alias qualifying the
## receiver — or "" when the receiver stands alone.  Type arguments are seen
## through (`vec.Vec[int].create` -> `vec`).
function receiver_module_prefix(tokens: span[token_mod.Token], receiver_index: ptr_uint, source: str) -> str:
    var base_index = receiver_index
    if scan_kind_at(tokens, base_index) == tk.TokenKind.rbracket:
        let lbracket = scan_matching_opener(tokens, base_index) else:
            return ""
        let base = scan_prev_index(tokens, lbracket) else:
            return ""
        base_index = base
    let dot = scan_prev_index(tokens, base_index) else:
        return ""
    if scan_kind_at(tokens, dot) != tk.TokenKind.dot:
        return ""
    let module_idx = scan_prev_index(tokens, dot) else:
        return ""
    if scan_kind_at(tokens, module_idx) != tk.TokenKind.identifier:
        return ""
    return scan_lexeme_at(tokens, module_idx, source)


## The receiver's base identifier, seeing through a type-argument list
## (`Option[int].some` -> `Option`).
function receiver_base_name(tokens: span[token_mod.Token], receiver_index: ptr_uint, source: str) -> str:
    if scan_kind_at(tokens, receiver_index) != tk.TokenKind.rbracket:
        return scan_lexeme_at(tokens, receiver_index, source)
    let lbracket = scan_matching_opener(tokens, receiver_index) else:
        return ""
    let base = scan_prev_index(tokens, lbracket) else:
        return ""
    return scan_lexeme_at(tokens, base, source)


## True when the receiver before the cursor's dot names a type: a declared type
## or interface of this file or of a resolved import (`rl.Color`), a builtin, or
## any uppercase identifier (the host's `type_name_receiver_token?`).
function receiver_is_type_name(facts: ref[ScanFacts], tokens: span[token_mod.Token], receiver_index: ptr_uint, source: str) -> bool:
    let name = receiver_base_name(tokens, receiver_index, source)
    if name.len == 0:
        return false
    if starts_uppercase(name) or is_known_type_name(facts, name):
        return true
    if unsafe: read(facts).types.contains(name) or read(facts).interfaces.contains(name):
        return true
    let module_prefix = receiver_module_prefix(tokens, receiver_index, source)
    if module_prefix.len == 0:
        return false
    var qualified = qualified_member_key(module_prefix, name)
    defer: qualified.release()
    unsafe:
        return read(facts).alias_types.contains(qualified.as_str())


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
function merge_type_keys(source: ref[map_mod.Map[str, types.Type]], target: ref[map_mod.Map[str, bool]]) -> void:
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


## Record a module's *static* method keys (`<Type>.<member>`) under `prefix`
## (`""` for the scanned file's own declarations, `"alias."` for an import) —
## the host's `static_method_binding_for_receiver`, which is what tells a
## static call (`NPC.max_hp()`) apart from a variant arm (`Option.some(...)`).
function collect_static_members(methods: ref[map_mod.Map[str, analyzer.FnSig]], prefix: str, target: ref[map_mod.Map[str, bool]], storage: ref[vec.Vec[string.String]]) -> void:
    var entries = methods.entries()
    while true:
        if not entries.next():
            break
        unsafe:
            let key = read(entries.current().key)
            let sig = read(entries.current().value)
            if sig.method_kind != ast.MethodKind.mk_static:
                continue
            if prefix.len == 0:
                target.set(key, true)
            else:
                var buf = string.String.create()
                buf.append(prefix)
                buf.append(key)
                target.set(buf.as_str(), true)
                storage.push(buf)


## Record a module's exported surface under `alias.` keys.
function collect_alias_exports(facts: ref[ScanFacts], alias: str, analysis: ref[analyzer.Analysis], file: ast.SourceFile) -> void:
    var functions = vec.Vec[str].create()
    defer: functions.release()
    var type_names = vec.Vec[str].create()
    defer: type_names.release()
    var interfaces = vec.Vec[str].create()
    defer: interfaces.release()
    var values = vec.Vec[str].create()
    defer: values.release()
    var readonly_values = vec.Vec[str].create()
    defer: readonly_values.release()
    var const_names = map_mod.Map[str, bool].create()
    defer: const_names.release()
    collect_const_names(file, ref_of(const_names))
    var alias_prefix = string.String.create()
    defer: alias_prefix.release()
    alias_prefix.append(alias)
    alias_prefix.push_byte(46)
    collect_static_members(ref_of(read(analysis).method_sigs), alias_prefix.as_str(), ref_of(facts.static_members), ref_of(facts.key_storage))
    # The host's `methods_for_receiver_type` merges every imported module's
    # methods by the bare type name, so `vec.Vec.create` and a bare
    # `Vec.create` resolve alike.
    collect_static_members(ref_of(read(analysis).method_sigs), "", ref_of(facts.static_members), ref_of(facts.key_storage))
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
            type_names.push(read(kp))
        var skeys = read(analysis).structs.keys()
        while true:
            let kp = skeys.next() else:
                break
            type_names.push(read(kp))
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
    var const_iter = const_names.keys()
    while true:
        let kp = const_iter.next() else:
            break
        unsafe:
            readonly_values.push(read(kp))
    var i: ptr_uint = 0
    while i < functions.len():
        let fp = functions.get(i) else:
            break
        var key = qualified_member_key(alias, unsafe: read(fp))
        facts.alias_functions.set(key.as_str(), true)
        facts.key_storage.push(key)
        i += 1
    i = 0
    while i < type_names.len():
        let tp = type_names.get(i) else:
            break
        var key = qualified_member_key(alias, unsafe: read(tp))
        facts.alias_types.set(key.as_str(), true)
        facts.key_storage.push(key)
        i += 1
    i = 0
    while i < interfaces.len():
        let ip = interfaces.get(i) else:
            break
        var key = qualified_member_key(alias, unsafe: read(ip))
        facts.alias_interfaces.set(key.as_str(), true)
        facts.key_storage.push(key)
        i += 1
    i = 0
    while i < values.len():
        let vp = values.get(i) else:
            break
        var key = qualified_member_key(alias, unsafe: read(vp))
        facts.alias_values.set(key.as_str(), true)
        facts.key_storage.push(key)
        i += 1
    i = 0
    while i < readonly_values.len():
        let vp = readonly_values.get(i) else:
            break
        var key = qualified_member_key(alias, unsafe: read(vp))
        facts.alias_readonly_values.set(key.as_str(), true)
        facts.key_storage.push(key)
        i += 1


## Register one import's exported surface when the module resolves.  Unresolved
## imports contribute nothing: the alias stays unknown, matching the host.
## The module cache serves the import's analysis — the same loader-backed
## analysis every other request sees, which honors open buffers — so an
## unchanged import is neither re-read nor re-parsed here; a cold one is loaded
## (and cached) through the workspace once.
function register_resolved_import(
    ws: ref[workspace.Workspace],
    facts: ref[ScanFacts],
    path: ast.QualifiedName,
    alias_name: Option[str],
    roots: span[str],
) -> void:
    var module_name = dotted_qname(path)
    defer: module_name.release()
    let alias = scan_import_alias_name(path, alias_name)
    match resolver.resolve_module_path(module_name.as_str(), roots, resolver.Platform.linux):
        Result.success as resolved_ok:
            var resolved = resolved_ok.value
            defer: resolved.release()
            match loader.cached_module_surface(ptr_of(ws.module_cache), resolved.as_str()):
                Option.some as surface:
                    facts.imports.set(alias, true)
                    collect_alias_exports(facts, alias, ref_of(surface.value.analysis), surface.value.source_file)
                Option.none:
                    match workspace.analysis_entry_for(ws, resolved.as_str()):
                        Option.some as entry_payload:
                            var entry = unsafe: read(entry_payload.value)
                            facts.imports.set(alias, true)
                            collect_alias_exports(facts, alias, ref_of(entry.analysis), entry.analysis.source_file)
                        Option.none:
                            register_import_from_disk(ws, facts, alias, resolved.as_str())
        Result.failure as resolve_failure:
            var rerr = resolve_failure.error
            rerr.release()


## Cold fallback: check the import through the shared document cache when
## neither the module cache nor the workspace's loader-backed analysis could
## serve it.
function register_import_from_disk(ws: ref[workspace.Workspace], facts: ref[ScanFacts], alias: str, resolved: str) -> void:
    var dep_doc = workspace.document_analysis_for(ws, resolved) else:
        return
    facts.imports.set(alias, true)
    collect_alias_exports(facts, alias, ref_of(dep_doc.analysis), dep_doc.ast_file)
    # The scan keeps only the exported surface; the cached dependency
    # analysis' own diagnostics stay with its cache entry.


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
function build_scan_facts(ws: ref[workspace.Workspace], file: ast.SourceFile, analysis: ref[analyzer.Analysis], roots: span[str], source: str) -> ScanFacts:
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
        alias_readonly_values = map_mod.Map[str, bool].create(),
        bindings = scope_mod.collect_bindings(source, file),
        readonly_values = map_mod.Map[str, bool].create(),
        static_members = map_mod.Map[str, bool].create(),
        callable_value_sites = span[analyzer.CallableValueSite](),
        nested_type_keys = map_mod.Map[str, bool].create(),
        callable_fields = map_mod.Map[str, bool].create(),
        receiver_structs = map_mod.Map[str, bool].create(),
        type_param_scopes = scope_mod.collect_type_param_scopes(source, file),
        attribute_decls = map_mod.Map[ptr_uint, bool].create(),
        key_storage = vec.Vec[string.String].create(),
    )
    var analysis_value = unsafe: read(analysis)
    facts.callable_value_sites = analysis_value.callable_value_sites.as_span()
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
        collect_static_members(ref_of(analysis_value.method_sigs), "", ref_of(facts.static_members), ref_of(facts.key_storage))
    collect_const_names(file, ref_of(facts.readonly_values))
    collect_attribute_decl_names(file, ref_of(facts.attribute_decls))
    collect_nested_type_keys(file.declarations, "", ref_of(facts.nested_type_keys), ref_of(facts.receiver_structs), ref_of(facts.callable_fields), ref_of(analysis_value), ref_of(facts.key_storage))


    var i: ptr_uint = 0
    while i < file.imports.len:
        unsafe:
            match read(file.imports.data + i):
                ast.Decl.decl_import as imp:
                    register_resolved_import(ws, ref_of(facts), imp.path, imp.alias_name, roots)
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
    # The cache holds the tokens of the document's last computed version; when
    # the text is unchanged they are exactly what this call would produce, so
    # repeated full/range requests for one edit cost a copy instead of a scan.
    if not clip:
        let cached_ptr = ws.semantic_token_cache_get(path)
        if cached_ptr != null:
            unsafe:
                let cached = read(cached_ptr)
                if cached.source_hash == fnv1a_hash(source) and cached.data.len() > 0:
                    var reused = vec.Vec[uint].create()
                    var ri: ptr_uint = 0
                    while ri < cached.data.len():
                        let rp = cached.data.get(ri) else:
                            break
                        reused.push(read(rp))
                        ri += 1
                    return reused

    var lex_diags = vec.Vec[token_mod.LexDiagnostic].create()
    defer: lex_diags.release()
    var all_tokens = lexer_mod.lex_reporting(source, ref_of(lex_diags))
    defer: all_tokens.release()

    # The parse and check are shared with the other features through the
    # workspace's caches — the loader-backed entry when the document loads
    # (already built by the diagnostics publish after an edit), else the
    # single-file parse cache.  On a large file they cost more than the scan.
    let parsed = workspace.document_analysis_for(ws, path) else:
        return vec.Vec[uint].create()
    var ast_file = parsed.ast_file
    var analysis = parsed.analysis

    var roots = ws.effective_module_roots_for(path)
    defer: roots.release()
    var facts = build_scan_facts(ws, ast_file, ref_of(analysis), roots.as_span(), source)
    defer: release_scan_facts(ref_of(facts))

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
        if kind == tk.TokenKind.identifier:
            let lexeme = unsafe: token_mod.token_lexeme(tok, source)
            if in_decorator and decorator_depth == 1:
                token_type = TOKEN_DECORATOR
            else:
                let cls = classify_scan_identifier(ref_of(facts), tokens, ti, lexeme, source)
                token_type = cls.token_type
                token_mod = cls.token_mod
        else:
            # A keyword inside an `import` path is a namespace segment, as the
            # host's `namespace_keyword_token?` routes it through the name
            # classifier before the keyword arm.
            if token_type == TOKEN_KEYWORD and scan_keyword_namespace_token(tokens, ti, source):
                token_type = TOKEN_NAMESPACE
            if scan_is_char_literal(kind):
                # The host's classifier has no arm for a character literal, so
                # it emits no entry for one.
                ti += 1
                continue
            if token_type == TOKEN_KEYWORD:
                # The host's keyword arm: `name` before a colon declares a field
                # (`null` ending an `if …:` line included), a keyword after a dot
                # is a property, and a keyword type name after `:`/`->` on the
                # same line (`x: proc() -> int`, `fn(x: int) -> bool`) is a type.
                if scan_is_keyword_type_parameter(tokens, ti):
                    token_type = TOKEN_TYPE_PARAM
                else if scan_is_keyword_type_annotation(tokens, ti):
                    token_type = TOKEN_TYPE
                else if scan_is_keyword_field_decl(tokens, ti):
                    token_type = TOKEN_PROPERTY
                    token_mod = 1
                else if scan_prev_is_dot(tokens, ti):
                    token_type = TOKEN_PROPERTY
            if kind == tk.TokenKind.at:
                # Only `@[` opens an attribute application; a lifetime `@a` is
                # not one, so its following tokens keep their own classes.
                let after_at = scan_next_index(tokens, ti)
                var opens_attribute = false
                if after_at.is_some():
                    opens_attribute = scan_kind_at(tokens, after_at.unwrap()) == tk.TokenKind.lbracket
                in_decorator = opens_attribute
                decorator_depth = 0
            else if kind == tk.TokenKind.lbracket and in_decorator:
                decorator_depth += 1
            else if kind == tk.TokenKind.rbracket and in_decorator:
                if decorator_depth > 0:
                    decorator_depth -= 1
                if decorator_depth == 0:
                    in_decorator = false
        # A heredoc body is emitted one entry per line — the host splits a
        # multi-line string token (`token_semantic_entries`) — except for the
        # embedded-language tags it leaves to the editor's grammar
        # (`embedded_heredoc_token?`), and a format string's interpolations are
        # split into literal runs and re-lexed expressions
        # (`fstring_interpolation_entries`).
        if token_type == TOKEN_STRING:
            let lexeme = unsafe: token_mod.token_lexeme(tok, source)
            if kind == tk.TokenKind.fstring and not scan_is_heredoc(lexeme):
                emit_fstring_entries(ref_of(data), lexeme, line_num, ptr_uint<-col_num, ref_of(prev_line), ref_of(prev_char), ref_of(facts), source)
                ti += 1
                continue
            if scan_is_heredoc(lexeme):
                if not scan_heredoc_embedded_tag(lexeme):
                    emit_heredoc_lines(ref_of(data), lexeme, line_num, col_num, ref_of(prev_line), ref_of(prev_char))
                ti += 1
                continue
            if scan_lexeme_has_newline(lexeme):
                emit_heredoc_lines(ref_of(data), lexeme, line_num, col_num, ref_of(prev_line), ref_of(prev_char))
                ti += 1
                continue
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


## The offset of a heredoc's tag inside its lexeme (`<<-TAG` or `f<<-TAG`), or 0
## when the lexeme is no heredoc.
function heredoc_tag_start(lexeme: str) -> ptr_uint:
    if lexeme.starts_with("<<-"):
        return 3
    if lexeme.len > 4 and (lexeme.byte_at(0) == 'f' or lexeme.byte_at(0) == 'c') and
       lexeme.byte_at(1) == '<' and lexeme.byte_at(2) == '<' and lexeme.byte_at(3) == '-':
        return 4
    return 0


## True when the lexeme is a heredoc string.
function scan_is_heredoc(lexeme: str) -> bool:
    return heredoc_tag_start(lexeme) > 0


## True for the embedded-language heredoc tags the host leaves to the editor's
## grammar (`embedded_heredoc_token?`).
function scan_heredoc_embedded_tag(lexeme: str) -> bool:
    let start = heredoc_tag_start(lexeme)
    if start == 0:
        return false
    var end = start
    while end < lexeme.len and not scan_is_heredoc_tag_end(lexeme.byte_at(end)):
        end += 1
    let tag = lexeme.slice(start, end - start)
    return tag.equal("GLSL") or tag.equal("VERT") or tag.equal("FRAG") or tag.equal("COMP") or
        tag.equal("JSON") or tag.equal("JSONC") or tag.equal("SQL") or tag.equal("HTML") or tag.equal("MT")


function scan_is_heredoc_tag_end(b: ubyte) -> bool:
    return b == '\n' or b == ' ' or b == '\t' or b == '\r'


## Emit one entry per non-empty line of a multi-line heredoc token — the host's
## `token_semantic_entries`: the first segment starts at the token's column,
## every later segment at column 0.
function emit_heredoc_lines(
    data: ref[vec.Vec[uint]],
    lexeme: str,
    first_line: uint,
    first_col: uint,
    prev_line: ref[uint],
    prev_char: ref[uint],
) -> void:
    var segment_start: ptr_uint = 0
    var line_index: uint = 0
    var i: ptr_uint = 0
    while i <= lexeme.len:
        if i == lexeme.len or lexeme.byte_at(i) == '\n':
            let length: uint = uint<-(i - segment_start)
            if length > 0:
                let line = first_line + line_index
                let col: uint = if line_index == 0: first_col else: 0
                let delta_line = line - unsafe: read(prev_line)
                var delta_char = col
                if delta_line == 0:
                    delta_char = col - unsafe: read(prev_char)
                data.push(delta_line)
                data.push(delta_char)
                data.push(length)
                data.push(TOKEN_STRING)
                data.push(0)
                unsafe: read(prev_line) = line
                unsafe: read(prev_char) = col
            segment_start = i + 1
            line_index += 1
        i += 1


## True when a lexeme contains a newline: the host emits one entry per line for
## such a string token (`token_semantic_entries`), which is how the implicitly
## concatenated multi-line literals are split.
function scan_lexeme_has_newline(lexeme: str) -> bool:
    var i: ptr_uint = 0
    while i < lexeme.len:
        if lexeme.byte_at(i) == '\n':
            return true
        i += 1
    return false


## One format string's interpolation: the expression source (the format spec
## split off) and the 0-based column of the expression's first character.
struct FstringPart:
    expr_col: ptr_uint
    source: str
    spec: str
    has_spec: bool


## Emit a format string's semantic entries (the host's
## `fstring_interpolation_entries`): the literal runs render `string`, and each
## interpolation's expression is re-lexed and classified so its identifiers,
## numbers and operators are coloured as if they stood alone.
function emit_fstring_entries(
    data: ref[vec.Vec[uint]],
    lexeme: str,
    first_line: uint,
    first_col: ptr_uint,
    prev_line: ref[uint],
    prev_char: ref[uint],
    facts: ref[ScanFacts],
    source: str,
) -> void:
    var cursor = first_col
    var i: ptr_uint = 2
    while i < lexeme.len:
        let b = lexeme.byte_at(i)
        if b == '"':
            break
        if b == '#' and i + 1 < lexeme.len and lexeme.byte_at(i + 1) == '{':
            let expr_start = i + 2
            let expr_end = fstring_interpolation_end(lexeme, expr_start)
            if expr_end < expr_start:
                break
            let part = fstring_split_part(lexeme, expr_start, expr_end, first_col)
            let hash_col = part.expr_col - 2
            if hash_col > cursor:
                emit_span(data, first_line, cursor, hash_col - cursor, TOKEN_STRING, 0, prev_line, prev_char)
            emit_fstring_expr(data, part, first_line, facts, prev_line, prev_char)
            let raw_len = part.source.len + (if part.has_spec: 1 + part.spec.len else: 0)
            cursor = part.expr_col + raw_len + 1
            i = expr_end + 1
            continue
        if b == '\\' and i + 1 < lexeme.len:
            i += 2
            continue
        i += 1
    let end_col: ptr_uint = first_col + lexeme.len - 1
    if end_col + 1 > cursor:
        emit_span(data, first_line, cursor, end_col + 1 - cursor, TOKEN_STRING, 0, prev_line, prev_char)


## The index of the `}` closing the interpolation that starts at `index`, with
## nested braces balanced and nested string literals skipped; the lexeme's end
## when it is unterminated.
function fstring_interpolation_end(lexeme: str, index: ptr_uint) -> ptr_uint:
    var depth: ptr_uint = 1
    var i = index
    while i < lexeme.len:
        let b = lexeme.byte_at(i)
        if b == '"':
            i = fstring_skip_string(lexeme, i)
            continue
        if b == '{':
            depth += 1
            i += 1
            continue
        if b == '}':
            depth -= 1
            if depth == 0:
                return i
            i += 1
            continue
        i += 1
    return lexeme.len


## The index just past a nested string literal starting at `index` (its opening
## quote), escapes included.
function fstring_skip_string(lexeme: str, index: ptr_uint) -> ptr_uint:
    var i = index + 1
    while i < lexeme.len:
        let b = lexeme.byte_at(i)
        if b == '"':
            return i + 1
        if b == '\\':
            i += 2
            continue
        i += 1
    return lexeme.len


## Split one interpolation into its expression and format spec (the host's
## `split_format_interpolation_source`: a top-level `:` whose suffix is a format
## spec wins, the last one if several match).
function fstring_split_part(lexeme: str, expr_start: ptr_uint, expr_end: ptr_uint, first_col: ptr_uint) -> FstringPart:
    let raw = lexeme.slice(expr_start, expr_end - expr_start)
    var depth: ptr_uint = 0
    var spec_index: ptr_uint = 0
    var found_spec = false
    var i: ptr_uint = 0
    while i < raw.len:
        let b = raw.byte_at(i)
        if b == '"':
            i = fstring_skip_string(raw, i)
            continue
        if b == '(' or b == '[' or b == '{':
            depth += 1
        else if b == ')' or b == ']' or b == '}':
            if depth > 0:
                depth -= 1
        else if b == ':':
            if depth == 0 and fstring_format_spec_suffix(raw.slice(i + 1, raw.len - i - 1)):
                spec_index = i
                found_spec = true
        i += 1
    if found_spec:
        return FstringPart(
            expr_col = first_col + expr_start,
            source = raw.slice(0, spec_index),
            spec = raw.slice(spec_index + 1, raw.len - spec_index - 1),
            has_spec = true,
        )
    return FstringPart(expr_col = first_col + expr_start, source = raw, spec = "", has_spec = false)


## The host's `format_spec_suffix?`: a trimmed `.digits` or one of the radix
## letters.
function fstring_format_spec_suffix(suffix: str) -> bool:
    let trimmed = suffix.trim_ascii_whitespace()
    if trimmed.len == 0:
        return false
    if trimmed.len == 1:
        let b = trimmed.byte_at(0)
        return b == 'x' or b == 'X' or b == 'o' or b == 'O' or b == 'b' or b == 'B'
    if trimmed.byte_at(0) != '.':
        return false
    var i: ptr_uint = 1
    while i < trimmed.len:
        let b = trimmed.byte_at(i)
        if b < '0' or b > '9':
            return false
        i += 1
    return true


## Emit the entries of one interpolation: its expression re-lexed and
## classified, then its format spec's tokens.  The re-lexed tokens are shifted
## to the document's coordinates first (the host's
## `interpolation_expression_tokens`), so the classifier's scope lookups see the
## f-string's own line.
function emit_fstring_expr(
    data: ref[vec.Vec[uint]],
    part: FstringPart,
    line: uint,
    facts: ref[ScanFacts],
    prev_line: ref[uint],
    prev_char: ref[uint],
) -> void:
    if part.source.len == 0:
        return
    emit_shifted_sub_tokens(data, part.source, line, part.expr_col, facts, prev_line, prev_char)
    if part.has_spec and part.spec.len > 0:
        emit_shifted_sub_tokens(data, part.spec, line, part.expr_col + part.source.len + 1, facts, prev_line, prev_char)


function emit_shifted_sub_tokens(
    data: ref[vec.Vec[uint]],
    source: str,
    line: uint,
    base_col: ptr_uint,
    facts: ref[ScanFacts],
    prev_line: ref[uint],
    prev_char: ref[uint],
) -> void:
    var diags = vec.Vec[token_mod.LexDiagnostic].create()
    defer: diags.release()
    var sub_tokens = lexer_mod.lex_reporting(source, ref_of(diags))
    defer: sub_tokens.release()
    let raw = sub_tokens.as_span()
    var shifted = vec.Vec[token_mod.Token].create()
    defer: shifted.release()
    var ti: ptr_uint = 0
    while ti < raw.len:
        let tok = unsafe: read(raw.data + ti)
        if not scan_is_trivia(tok.kind):
            shifted.push(token_mod.Token(
                kind = tok.kind,
                start_offset = tok.start_offset,
                end_offset = tok.end_offset,
                line = ptr_uint<-line + 1,
                column = base_col + tok.column,
            ))
        ti += 1
    var st = shifted.as_span()
    ti = 0
    while ti < st.len:
        let tok = unsafe: read(st.data + ti)
        if scan_is_char_literal(tok.kind):
            ti += 1
            continue
        let cls = scan_sub_token_class(facts, st, ti, source)
        if cls.token_type != TOKEN_NONE:
            let col: ptr_uint = tok.column - 1
            let length: ptr_uint = tok.end_offset - tok.start_offset
            emit_span(data, uint<-tok.line - 1, col, length, cls.token_type, cls.token_mod, prev_line, prev_char)
        ti += 1


## The class of one token inside a format-string interpolation — the classifier's
## arms for the token kinds an expression can contain (the host classifies the
## re-lexed sub-tokens with the same `classify_semantic_token`).
function scan_sub_token_class(facts: ref[ScanFacts], tokens: span[token_mod.Token], index: ptr_uint, source: str) -> TokenClass:
    let kind = scan_kind_at(tokens, index)
    if kind == tk.TokenKind.identifier:
        return classify_scan_identifier(facts, tokens, index, scan_lexeme_at(tokens, index, source), source)
    if kind == tk.TokenKind.string or kind == tk.TokenKind.cstring or kind == tk.TokenKind.fstring:
        return TokenClass(token_type = TOKEN_STRING, token_mod = 0)
    if kind == tk.TokenKind.integer or kind == tk.TokenKind.float_literal:
        return TokenClass(token_type = TOKEN_NUMBER, token_mod = 0)
    if token_kind_to_type(kind) == TOKEN_KEYWORD:
        if scan_is_keyword_type_annotation(tokens, index):
            return TokenClass(token_type = TOKEN_TYPE, token_mod = 0)
        if scan_is_keyword_field_decl(tokens, index):
            return TokenClass(token_type = TOKEN_PROPERTY, token_mod = 1)
        if scan_prev_is_dot(tokens, index):
            return TokenClass(token_type = TOKEN_PROPERTY, token_mod = 0)
        return TokenClass(token_type = TOKEN_KEYWORD, token_mod = 0)
    return TokenClass(token_type = token_kind_to_type(kind), token_mod = 0)


## Push one entry with the relative delta encoding the protocol uses.
function emit_span(
    data: ref[vec.Vec[uint]],
    line: uint,
    col: ptr_uint,
    length: ptr_uint,
    token_type: uint,
    token_mod: uint,
    prev_line: ref[uint],
    prev_char: ref[uint],
) -> void:
    if length == 0:
        return
    let delta_line = line - unsafe: read(prev_line)
    var delta_char = col
    if delta_line == 0:
        delta_char = col - unsafe: read(prev_char)
    data.push(uint<-delta_line)
    data.push(uint<-delta_char)
    data.push(uint<-length)
    data.push(token_type)
    data.push(token_mod)
    unsafe:
        read(prev_line) = line
        read(prev_char) = uint<-col


## The host's legend names, indexed by our legend constants.
public function token_type_name(index: uint) -> str:
    return match index:
        0u:  "namespace"
        1u:  "type"
        2u:  "class"
        3u:  "enum"
        4u:  "interface"
        5u:  "struct"
        6u:  "typeParameter"
        7u:  "parameter"
        8u:  "variable"
        9u:  "property"
        10u: "enumMember"
        11u: "event"
        12u: "function"
        13u: "method"
        14u: "macro"
        15u: "keyword"
        16u: "modifier"
        17u: "comment"
        18u: "string"
        19u: "number"
        20u: "regexp"
        21u: "operator"
        22u: "decorator"
        _:   ""


## `declaration,readonly,...` for a modifier bitmask.
public function token_modifier_names(bits: uint) -> string.String:
    var names = string.String.create()
    var bit: uint = 1
    var index: ptr_uint = 0
    while index < 10:
        if (bits & bit) != 0:
            if names.len() > 0:
                names.append(",")
            names.append(modifier_name(index))
        bit = bit << 1
        index += 1
    return names


function modifier_name(index: ptr_uint) -> str:
    return match index:
        0:  "declaration"
        1:  "definition"
        2:  "readonly"
        3:  "static"
        4:  "deprecated"
        5:  "abstract"
        6:  "async"
        7:  "modification"
        8:  "documentation"
        9:  "defaultLibrary"
        _:  ""


## One token's semantic class, as the debug dump prints it (`type (declaration)`).
public struct SemanticClass:
    line: ptr_uint
    column: ptr_uint
    text: string.String


## The semantic class of every token the semanticTokens endpoints would colour,
## built by the same scanner, so the debug dump and the colours can never
## disagree.
public function semantic_class_entries(
    ws: ref[workspace.Workspace],
    path: str,
    source: str,
) -> vec.Vec[SemanticClass]:
    var entries = vec.Vec[SemanticClass].create()

    var lex_diags = vec.Vec[token_mod.LexDiagnostic].create()
    defer: lex_diags.release()
    var all_tokens = lexer_mod.lex_reporting(source, ref_of(lex_diags))
    defer: all_tokens.release()

    let parsed = workspace.document_analysis_for(ws, path) else:
        return entries
    var ast_file = parsed.ast_file
    var analysis = parsed.analysis

    var roots = ws.effective_module_roots_for(path)
    defer: roots.release()
    var facts = build_scan_facts(ws, ast_file, ref_of(analysis), roots.as_span(), source)
    defer: release_scan_facts(ref_of(facts))

    let tokens = all_tokens.as_span()
    var in_decorator = false
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

        var token_type = token_kind_to_type(kind)
        var token_mod: uint = 0
        if kind == tk.TokenKind.identifier:
            let lexeme = unsafe: token_mod.token_lexeme(tok, source)
            if in_decorator and decorator_depth == 1:
                token_type = TOKEN_DECORATOR
            else:
                let cls = classify_scan_identifier(ref_of(facts), tokens, ti, lexeme, source)
                token_type = cls.token_type
                token_mod = cls.token_mod
        else:
            if kind == tk.TokenKind.at:
                # Only `@[` opens an attribute application; a lifetime `@a` is
                # not one, so its following tokens keep their own classes.
                let after_at = scan_next_index(tokens, ti)
                var opens_attribute = false
                if after_at.is_some():
                    opens_attribute = scan_kind_at(tokens, after_at.unwrap()) == tk.TokenKind.lbracket
                in_decorator = opens_attribute
                decorator_depth = 0
            else if kind == tk.TokenKind.lbracket and in_decorator:
                decorator_depth += 1
            else if kind == tk.TokenKind.rbracket and in_decorator:
                if decorator_depth > 0:
                    decorator_depth -= 1

        var class_text = string.String.create()
        class_text.append(token_type_name(token_type))
        if token_mod != 0:
            class_text.append(" (")
            var names = token_modifier_names(token_mod)
            class_text.append(names.as_str())
            names.release()
            class_text.append(")")
        entries.push(SemanticClass(line = tok.line, column = tok.column, text = class_text))
        ti += 1
    return entries


## The class text for a position, or empty when the token carries none.
public function semantic_class_at(entries: ref[vec.Vec[SemanticClass]], line: ptr_uint, column: ptr_uint) -> str:
    var i: ptr_uint = 0
    while i < entries.len():
        let ep = entries.get(i) else:
            break
        let entry = unsafe: read(ep)
        if entry.line == line and entry.column == column:
            return entry.text.as_str()
        i += 1
    return ""


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

    # Remember the tokens of this version (the response shape stays the host's:
    # no resultId), so a repeat of the same request is a cache hit.
    if not clip:
        var cached_copy = vec.Vec[uint].create()
        var ci: ptr_uint = 0
        while ci < data.len():
            let cp = data.get(ci) else:
                break
            cached_copy.push(unsafe: read(cp))
            ci += 1
        var result_id = string.String.create()
        result_id.append_format(f"#{fnv1a_hash(content.as_str()):x}")
        ws.semantic_token_cache_set(file_path.as_str(), fnv1a_hash(content.as_str()), result_id, data.len() / 5, cached_copy)

    var json_text = build_tokens_json(ref_of(data))
    proto.write_response_raw(id, json_text.as_str())
    json_text.release()


## True when the token at `index` is one of the analyzer's recorded
## callable-value sites (a bare function name used where a callable type is
## expected) — the host's `callable_value_identifier_sites` lookup.
function scan_callable_value_site(facts: ref[ScanFacts], tokens: span[token_mod.Token], index: ptr_uint) -> bool:
    let tok = unsafe: read(tokens.data + index)
    let sites = unsafe: read(facts).callable_value_sites
    var i: ptr_uint = 0
    while i < sites.len:
        let site = unsafe: read(sites.data + i)
        if site.line == tok.line and site.column == tok.column:
            return true
        i += 1
    return false


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
public function token_kind_to_type(kind: tk.TokenKind) -> uint:
    if kind == tk.TokenKind.identifier:
        return TOKEN_VARIABLE
    if kind == tk.TokenKind.integer or kind == tk.TokenKind.float_literal:
        return TOKEN_NUMBER
    if kind == tk.TokenKind.string or kind == tk.TokenKind.cstring or
       kind == tk.TokenKind.fstring or kind == tk.TokenKind.char_literal:
        return TOKEN_STRING
    # Operators and punctuation
    if kind == tk.TokenKind.dot or kind == tk.TokenKind.plus or
       kind == tk.TokenKind.minus or kind == tk.TokenKind.star or
       kind == tk.TokenKind.slash or kind == tk.TokenKind.percent or
       kind == tk.TokenKind.amp or kind == tk.TokenKind.pipe or
       kind == tk.TokenKind.caret or kind == tk.TokenKind.less or
       kind == tk.TokenKind.greater or kind == tk.TokenKind.equal or
       kind == tk.TokenKind.arrow or kind == tk.TokenKind.dot_dot or
       kind == tk.TokenKind.equal_equal or kind == tk.TokenKind.bang_equal or
       kind == tk.TokenKind.less_equal or kind == tk.TokenKind.greater_equal or
       kind == tk.TokenKind.shift_left or kind == tk.TokenKind.shift_right or
       kind == tk.TokenKind.plus_equal or kind == tk.TokenKind.minus_equal or
       kind == tk.TokenKind.star_equal or kind == tk.TokenKind.slash_equal or
       kind == tk.TokenKind.percent_equal or kind == tk.TokenKind.amp_equal or
       kind == tk.TokenKind.pipe_equal or kind == tk.TokenKind.caret_equal or
       kind == tk.TokenKind.shift_left_equal or kind == tk.TokenKind.shift_right_equal or
        kind == tk.TokenKind.ellipsis or kind == tk.TokenKind.tilde or
        kind == tk.TokenKind.lparen or kind == tk.TokenKind.rparen or
        kind == tk.TokenKind.lbracket or kind == tk.TokenKind.rbracket or
        kind == tk.TokenKind.colon or kind == tk.TokenKind.comma or
        kind == tk.TokenKind.question or kind == tk.TokenKind.at:
        return TOKEN_OPERATOR
    return TOKEN_KEYWORD


## Build a SemanticTokens data array JSON.  The integer emission goes through
## `fmt.append_uint` — `append_format(f"#{v}")` allocates a temporary per value,
## which the per-token data array turns into tens of thousands of leaks per
## request on a large file.
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
            fmt.append_uint(ref_of(result), read(v_ptr))
        di += 1
    result.append("]}")
    return result


## The snapshot command's semantic overlay: the LSP's own token pass (the host
## calls `LSP::Server.semantic_tokens_for_path`), rendered as the entry array
## `snapshot.js -s` consumes.  The protocol stream is delta-encoded
## `[deltaLine, deltaStartChar, length, tokenTypeIndex, modifierBits]`; the
## entry format uses absolute 0-based line/startChar and character lengths.
public function snapshot_entries_for(ws: ref[workspace.Workspace], file_path: str, source: str) -> string.String:
    var data = compute_token_data(ws, file_path, source, false, 0, 0)
    defer: data.release()
    var result = string.String.create()
    result.append("[")
    var first = true
    var line: ptr_uint = 0
    var start: ptr_uint = 0
    var i: ptr_uint = 0
    while i + 4 < data.len():
        let dl_ptr = data.get(i) else:
            break
        let ds_ptr = data.get(i + 1) else:
            break
        let len_ptr = data.get(i + 2) else:
            break
        let ty_ptr = data.get(i + 3) else:
            break
        let md_ptr = data.get(i + 4) else:
            break
        let delta_line = unsafe: read(dl_ptr)
        let delta_start = unsafe: read(ds_ptr)
        let length = unsafe: read(len_ptr)
        let token_type = unsafe: read(ty_ptr)
        let modifiers = unsafe: read(md_ptr)
        if delta_line == 0:
            start = start + delta_start
        else:
            line = line + delta_line
            start = delta_start
        if not first:
            result.append(",")
        first = false
        result.append("{\"line\":")
        fmt.append_uint(ref_of(result), uint<-line)
        result.append(",\"startChar\":")
        fmt.append_uint(ref_of(result), uint<-start)
        result.append(",\"length\":")
        fmt.append_uint(ref_of(result), uint<-length)
        result.append(",\"tokenType\":\"")
        result.append(SNAPSHOT_TOKEN_NAMES[token_type])
        result.append("\",\"modifiers\":[")
        var bit: uint = 1
        var mi: ptr_uint = 0
        var first_mod = true
        while mi < 10:
            if (modifiers & bit) != 0:
                if not first_mod:
                    result.append(",")
                first_mod = false
                result.append("\"")
                result.append(modifier_name(mi))
                result.append("\"")
            bit = bit << 1
            mi += 1
        result.append("]}")
        i += 5
    result.append("]")
    return result


## Token-type names by legend index, for the HTML snapshot's CSS classes.
## Mirrors the host's legend order (see lifecycle.mt).
const SNAPSHOT_TOKEN_NAMES: array[str, 23] = ("namespace", "type", "class", "enum", "interface", "struct", "typeParameter", "parameter", "variable", "property", "enumMember", "event", "function", "method", "macro", "keyword", "modifier", "comment", "string", "number", "regexp", "operator", "decorator")


## Collect the module-level `const` names: their value bindings are immutable,
## so a reference renders `variable` + `readonly`.  Only the consts — a `let`
## name inside some function must not leak into the module-level value set.
function collect_const_names(file: ast.SourceFile, names: ref[map_mod.Map[str, bool]]) -> void:
    var i: ptr_uint = 0
    while i < file.declarations.len:
        unsafe:
            match read(file.declarations.data + i):
                ast.Decl.decl_const as dc:
                    names.set(dc.name, true)
                _:
                    pass
        i += 1


## True when the token is `<Type>.<Nested>` with `<Nested>` declared inside the
## receiver's struct — the host's `dot_nested_type_member?`.
function scan_nested_type_member(facts: ref[ScanFacts], tokens: span[token_mod.Token], index: ptr_uint, source: str) -> bool:
    let dot = scan_prev_index(tokens, index) else:
        return false
    if scan_kind_at(tokens, dot) != tk.TokenKind.dot:
        return false
    let recv = scan_prev_index(tokens, dot) else:
        return false
    if scan_kind_at(tokens, recv) != tk.TokenKind.identifier:
        return false
    var key = string.String.create()
    defer: key.release()
    key.append(scan_lexeme_at(tokens, recv, source))
    key.append(".")
    key.append(scan_lexeme_at(tokens, index, source))
    return unsafe: read(facts).nested_type_keys.contains(key.as_str())


## True when the token is a call through a struct field whose declared type is a
## function or proc (`f.check(5)`) — the host's `callable_field_member_access?`.
function scan_callable_field_call(facts: ref[ScanFacts], tokens: span[token_mod.Token], index: ptr_uint, source: str) -> bool:
    let dot = scan_prev_index(tokens, index) else:
        return false
    if scan_kind_at(tokens, dot) != tk.TokenKind.dot:
        return false
    let recv = scan_prev_index(tokens, dot) else:
        return false
    if scan_kind_at(tokens, recv) != tk.TokenKind.identifier:
        return false
    let receiver_name = scan_lexeme_at(tokens, recv, source)
    let member_name = scan_lexeme_at(tokens, index, source)
    var prefix = string.String.create()
    defer: prefix.release()
    prefix.append(receiver_name)
    prefix.append(".")
    var entries = unsafe: read(facts).receiver_structs.entries()
    while entries.next():
        let entry = entries.current()
        let key = unsafe: read(entry.key)
        if not key.starts_with(prefix.as_str()):
            continue
        var field_key = string.String.create()
        field_key.append(key.slice(prefix.len(), key.len - prefix.len()))
        field_key.append(".")
        field_key.append(member_name)
        var found = false
        unsafe:
            found = read(facts).callable_fields.contains(field_key.as_str())
        field_key.release()
        if found:
            return true
    return false


## Collect `<Owner>.<Nested>` keys for every nested type declared inside a
## struct, recursing into the nested structs themselves, and — as a by-product of
## the same walk — the callable fields and the `let x = Struct(...)` receivers
## the token scanner needs.  `owner` is the enclosing struct's name ("" at the
## top level).
function collect_nested_type_keys(
    decls: span[ast.Decl],
    owner: str,
    keys: ref[map_mod.Map[str, bool]],
    receivers: ref[map_mod.Map[str, bool]],
    callable_fields: ref[map_mod.Map[str, bool]],
    analysis: ref[analyzer.Analysis],
    storage: ref[vec.Vec[string.String]],
) -> void:
    var i: ptr_uint = 0
    while i < decls.len:
        unsafe:
            match read(decls.data + i):
                ast.Decl.decl_struct as s:
                    if owner.len > 0:
                        var key = string.String.create()
                        key.append(owner)
                        key.append(".")
                        key.append(s.name)
                        keys.set(key.as_str(), true)
                        storage.push(key)
                    collect_struct_callable_fields(s.name, analysis, callable_fields, storage)
                    collect_nested_decl_names(s.nested_types, s.name, keys, receivers, callable_fields, analysis, storage)
                    collect_nested_type_keys(s.nested_types, s.name, keys, receivers, callable_fields, analysis, storage)
                ast.Decl.decl_function as fun:
                    collect_receiver_struct_names(fun.body, receivers, analysis, storage)
                ast.Decl.decl_extending_block as ex:
                    var mi: ptr_uint = 0
                    while mi < ex.methods.len:
                        collect_receiver_struct_names(read(ex.methods.data + mi).body, receivers, analysis, storage)
                        mi += 1
                _:
                    pass
        i += 1


## Register `<Owner>.<Nested>` for the nested *struct* declarations in a
## declaration list (the recursion itself happens in `collect_nested_type_keys`).
function collect_nested_decl_names(
    decls: span[ast.Decl],
    owner: str,
    keys: ref[map_mod.Map[str, bool]],
    receivers: ref[map_mod.Map[str, bool]],
    callable_fields: ref[map_mod.Map[str, bool]],
    analysis: ref[analyzer.Analysis],
    storage: ref[vec.Vec[string.String]],
) -> void:
    var i: ptr_uint = 0
    while i < decls.len:
        unsafe:
            match read(decls.data + i):
                ast.Decl.decl_struct as s:
                    var key = string.String.create()
                    key.append(owner)
                    key.append(".")
                    key.append(s.name)
                    keys.set(key.as_str(), true)
                    storage.push(key)
                ast.Decl.decl_enum as e:
                    var ekey = string.String.create()
                    ekey.append(owner)
                    ekey.append(".")
                    ekey.append(e.name)
                    keys.set(ekey.as_str(), true)
                    storage.push(ekey)
                _:
                    pass
        i += 1


## `<Struct>.<field>` for every field whose declared type is a function/proc.
function collect_struct_callable_fields(struct_name: str, analysis: ref[analyzer.Analysis], callable_fields: ref[map_mod.Map[str, bool]], storage: ref[vec.Vec[string.String]]) -> void:
    let fields_ptr = unsafe: read(analysis).structs.get(struct_name) else:
        return
    let fields = unsafe: read(fields_ptr)
    var i: ptr_uint = 0
    while i < fields.len:
        let field = unsafe: read(fields.data + i)
        if analyzer.is_callable_type(field.ty):
            var key = string.String.create()
            key.append(struct_name)
            key.append(".")
            key.append(field.name)
            callable_fields.set(key.as_str(), true)
            storage.push(key)
        i += 1


## Local binding name -> struct type name for `let x = Struct(...)` declarations
## (the receiver shape a callable-field call reads).
function collect_receiver_struct_names(body: ptr[ast.Stmt]?, receivers: ref[map_mod.Map[str, bool]], analysis: ref[analyzer.Analysis], storage: ref[vec.Vec[string.String]]) -> void:
    let b = body else:
        return
    unsafe:
        match read(b):
            ast.Stmt.stmt_block as blk:
                var i: ptr_uint = 0
                while i < blk.statements.len:
                    match read(blk.statements.data + i):
                        ast.Stmt.stmt_local as loc:
                            let v = loc.value
                            if v != null and loc.name != "_":
                                match read(v):
                                    ast.Expr.expr_call as cl:
                                        match read(cl.callee):
                                            ast.Expr.expr_identifier as id:
                                                if read(analysis).structs.contains(id.name):
                                                    var key = string.String.create()
                                                    key.append(loc.name)
                                                    key.append(".")
                                                    key.append(id.name)
                                                    receivers.set(key.as_str(), true)
                                                    storage.push(key)
                                            _:
                                                pass
                                    _:
                                        pass
                        _:
                            pass
                    i += 1
                collect_receiver_struct_names_in_stmts(blk.statements, receivers, analysis, storage)
            _:
                pass


## Recurse `collect_receiver_struct_names` into nested bodies.
function collect_receiver_struct_names_in_stmts(stmts: span[ast.Stmt], receivers: ref[map_mod.Map[str, bool]], analysis: ref[analyzer.Analysis], storage: ref[vec.Vec[string.String]]) -> void:
    var i: ptr_uint = 0
    while i < stmts.len:
        unsafe:
            match read(stmts.data + i):
                ast.Stmt.stmt_if as iff:
                    var bi: ptr_uint = 0
                    while bi < iff.branches.len:
                        collect_receiver_struct_names(read(iff.branches.data + bi).body, receivers, analysis, storage)
                        bi += 1
                    collect_receiver_struct_names(iff.else_body, receivers, analysis, storage)
                ast.Stmt.stmt_while as w:
                    collect_receiver_struct_names(w.body, receivers, analysis, storage)
                ast.Stmt.stmt_for as f:
                    collect_receiver_struct_names(f.body, receivers, analysis, storage)
                ast.Stmt.stmt_match as m:
                    var mi: ptr_uint = 0
                    while mi < m.arms.len:
                        collect_receiver_struct_names(read(m.arms.data + mi).body, receivers, analysis, storage)
                        mi += 1
                ast.Stmt.stmt_unsafe as u:
                    collect_receiver_struct_names(u.body, receivers, analysis, storage)
                ast.Stmt.stmt_defer as d:
                    collect_receiver_struct_names(d.body, receivers, analysis, storage)
                _:
                    pass
        i += 1
