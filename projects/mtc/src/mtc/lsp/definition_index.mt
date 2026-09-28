## The workspace's cross-file definition index — the host's
## `WorkspaceDefinitionIndex` (`lsp/workspace/definition_index.rb`) plus the
## per-document token-pair index it queries (`definition_token_index`,
## `lsp/workspace/utilities.rb`), ported for the same last-resort answers:
## `textDocument/definition` / `declaration` / `typeDefinition`, and a hover
## with no other source location.
##
## A *definition identifier* is an identifier immediately preceded by a
## declaration keyword (`function`, `struct`, `type`, `const`, `let`, …).  The
## index keeps that pair list per document, the names its declaration lines
## introduce (the host's `extract_definition_names`), and answers "which
## candidate document declares `name`, and where" over a candidate list the
## caller supplies in the host's order: the requesting document first, then the
## other documents the workspace knows.
##
## Deliberately not ported: the host's `@definition_index` / miss caches and its
## `@definition_candidate_uris` map.  They cache the same answers for speed; the
## self-host's per-document token and name indexes already avoid rescanning, and
## without them an edit is reflected immediately.

import std.map as map_mod
import std.str
import std.string as string
import std.vec as vec

import mtc.lexer.lexer as lexer_mod
import mtc.lexer.token as token_mod
import mtc.lexer.token_kinds as tk


## One declaration identifier: its 1-based line and column, and its length.
public struct DefinitionToken:
    line: ptr_uint
    column: ptr_uint
    length: ptr_uint


## A resolved cross-file hit: the token and the document (by path) that
## declares it.
public struct DefinitionEntry:
    path: string.String
    line: ptr_uint
    column: ptr_uint
    length: ptr_uint


## A document the global lookup may search: its uri (borrowed) and its text
## (borrowed — the caller owns it and keeps it alive for the call).
public struct CandidateDocument:
    uri: str
    source: str


## Per-document state: the token-pair index (name → tokens, document order) and
## the names the document's declaration lines introduce.
public struct DocumentIndex:
    tokens: map_mod.Map[string.String, vec.Vec[DefinitionToken]]
    names: map_mod.Map[string.String, bool]


public struct DefinitionIndex:
    documents: map_mod.Map[string.String, DocumentIndex]


public function create() -> DefinitionIndex:
    return DefinitionIndex(documents = map_mod.Map[string.String, DocumentIndex].create())


## Drop a document's index: its content changed, so its declaration tokens and
## names are rebuilt on the next lookup.  The host clears the per-uri token
## index and re-warms the name candidates the same way.
public function forget(index: ref[DefinitionIndex], uri: str) -> void:
    var key = string.String.from_str(uri)
    defer: key.release()
    let stored = index.documents.get(key)
    if stored == null:
        return
    var doc_index = unsafe: read(stored)
    release_document_index(ref_of(doc_index))
    index.documents.remove(key)


## Drop every document's index and the map itself (a re-rooted workspace).
public function release(index: ref[DefinitionIndex]) -> void:
    var keys = index.documents.keys()
    while true:
        let key_ptr = keys.next() else:
            break
        let stored = index.documents.get(unsafe: read(key_ptr)) else:
            continue
        var doc_index = unsafe: read(stored)
        release_document_index(ref_of(doc_index))
    index.documents.release()


## The host's `find_definition_token_global`: the candidates are searched in
## order.  In the requesting document the last declaration at or before the
## cursor wins (falling back to its first); in every other document the first
## declaration wins.  The first candidate that declares `name` answers.
public function lookup(
    index: ref[DefinitionIndex],
    name: str,
    preferred_uri: str,
    before_line: ptr_uint,
    before_char: ptr_uint,
    candidates: span[CandidateDocument],
) -> Option[DefinitionEntry]:
    var i: ptr_uint = 0
    while i < candidates.len:
        let doc = unsafe: read(candidates.data + i)
        let is_preferred = preferred_uri.len > 0 and doc.uri.equal(preferred_uri)
        match document_tokens(index, doc, name):
            Option.some as tokens:
                match declaration_token(tokens.value, before_line, before_char, is_preferred):
                    Option.some as token:
                        return Option[DefinitionEntry].some(value = DefinitionEntry(
                            path = string.String.from_str(doc.uri),
                            line = token.value.line,
                            column = token.value.column,
                            length = token.value.length,
                        ))
                    Option.none:
                        pass
            Option.none:
                pass
        i += 1
    return Option[DefinitionEntry].none


## The declaration token of `name` in one document — the host's
## `find_definition_token_in_file`, which matches any declaration keyword (so a
## function, a const or a type all resolve), warming the document's index first.
public function document_declaration_token(
    index: ref[DefinitionIndex],
    path: str,
    source: str,
    name: str,
) -> Option[DefinitionToken]:
    let doc = CandidateDocument(uri = path, source = source)
    match document_tokens(index, doc, name):
        Option.some as tokens:
            return declaration_token(tokens.value, 0, 0, false)
        Option.none:
            return Option[DefinitionToken].none


## The declaration token for `name` in `document`, the last one at or before
## (`before_line`, `before_char`) when `use_before` — the host's
## `find_definition_token`, which falls back to the first token when the filter
## matches nothing.
public function declaration_token(
    token_list: span[DefinitionToken],
    before_line: ptr_uint,
    before_char: ptr_uint,
    use_before: bool,
) -> Option[DefinitionToken]:
    var best: DefinitionToken = DefinitionToken(line = 0, column = 0, length = 0)
    var first: DefinitionToken = DefinitionToken(line = 0, column = 0, length = 0)
    var found = false
    var has_first = false
    var i: ptr_uint = 0
    while i < token_list.len:
        let token = unsafe: read(token_list.data + i)
        if not has_first:
            first = token
            has_first = true
        else if not use_before:
            # Without the position filter the host takes the first token.
            return Option[DefinitionToken].some(value = first)
        let before = token.line < before_line or
            (token.line == before_line and token.column < before_char)
        if before and (not found or token.line > best.line or (token.line == best.line and token.column > best.column)):
            best = token
            found = true
        i += 1
    if not has_first:
        return Option[DefinitionToken].none
    if not use_before or not found:
        # The host falls back to the first declaration when the position filter
        # matches nothing (a cursor on the declaration itself is excluded).
        return Option[DefinitionToken].some(value = first)
    return Option[DefinitionToken].some(value = best)


## The declaration tokens of `name` in `doc` — warming the document's index
## first — or none when the document does not declare `name`.
function document_tokens(index: ref[DefinitionIndex], doc: CandidateDocument, name: str) -> Option[span[DefinitionToken]]:
    warm_document(index, doc)
    let doc_index = stored_document(index, doc.uri) else:
        return Option[span[DefinitionToken]].none
    var name_key = string.String.from_str(name)
    defer: name_key.release()
    if not doc_index.names.contains(name_key):
        return Option[span[DefinitionToken]].none
    let tokens_ptr = doc_index.tokens.get(name_key) else:
        return Option[span[DefinitionToken]].none
    return Option[span[DefinitionToken]].some(value = unsafe: read(tokens_ptr).as_span())


## Warm `doc` when it is not indexed yet: the pair index of its declaration
## identifiers and the set of names its declaration lines introduce.
function warm_document(index: ref[DefinitionIndex], doc: CandidateDocument) -> void:
    var key = string.String.from_str(doc.uri)
    defer: key.release()
    if index.documents.contains(key):
        return

    var tokens = map_mod.Map[string.String, vec.Vec[DefinitionToken]].create()
    index_tokens(ref_of(tokens), doc.source)

    var names = map_mod.Map[string.String, bool].create()
    collect_declared_names(ref_of(names), doc.source)

    index.documents.set(string.String.from_str(doc.uri), DocumentIndex(tokens = tokens, names = names))


function stored_document(index: ref[DefinitionIndex], uri: str) -> Option[DocumentIndex]:
    var key = string.String.from_str(uri)
    defer: key.release()
    let ptr = index.documents.get(key) else:
        return Option[DocumentIndex].none
    return Option[DocumentIndex].some(value = unsafe: read(ptr))


function release_document_index(doc_index: ref[DocumentIndex]) -> void:
    var keys = doc_index.tokens.keys()
    while true:
        let key_ptr = keys.next() else:
            break
        let cell = doc_index.tokens.get(unsafe: read(key_ptr)) else:
            continue
        unsafe: read(cell).release()
    doc_index.tokens.release()
    doc_index.names.release()


## Index every identifier that immediately follows a declaration keyword — the
## host's `definition_token_index` token-pair scan (structural tokens included,
## since they are part of the stream).
function index_tokens(tokens: ref[map_mod.Map[string.String, vec.Vec[DefinitionToken]]], source: str) -> void:
    var lex_diags = vec.Vec[token_mod.LexDiagnostic].create()
    defer: lex_diags.release()
    var lexed = lexer_mod.lex_reporting(source, ref_of(lex_diags))
    defer: lexed.release()

    var previous_was_keyword = false
    var ti: ptr_uint = 0
    while ti < lexed.len():
        let token_ptr = lexed.get(ti) else:
            break
        let token = unsafe: read(token_ptr)
        if previous_was_keyword and token.kind == tk.TokenKind.identifier:
            let lexeme = unsafe: token_mod.token_lexeme(token, source)
            var map_key = string.String.from_str(lexeme)
            let entry = tokens.get(map_key)
            if entry == null:
                var list = vec.Vec[DefinitionToken].create()
                list.push(DeclarationTokenOf(token))
                tokens.set(map_key, list)
            else:
                map_key.release()
                unsafe: read(entry).push(DeclarationTokenOf(token))
        previous_was_keyword = is_definition_keyword(token.kind)
        ti += 1


function DeclarationTokenOf(token: token_mod.Token) -> DefinitionToken:
    return DefinitionToken(
        line = token.line,
        column = token.column,
        length = token.end_offset - token.start_offset,
    )


## The names a document's declaration lines introduce (the host's
## `DEFINITION_NAME_REGEX`): the first identifier after an optional
## `public`/`foreign`/`external` prefix and a declaration keyword.
function collect_declared_names(names: ref[map_mod.Map[string.String, bool]], source: str) -> void:
    var start: ptr_uint = 0
    var i: ptr_uint = 0
    while i <= source.len:
        if i == source.len or source.byte_at(i) == '\n':
            match name_in_line(source.slice(start, i - start)):
                Option.some as found:
                    var name_key = string.String.from_str(found.value)
                    if names.contains(name_key):
                        name_key.release()
                    else:
                        names.set(name_key, true)
                Option.none:
                    pass
            start = i + 1
        i += 1


## The declaration name on one line, or none when the line declares nothing.
function name_in_line(line: str) -> Option[str]:
    var i: ptr_uint = 0
    while i < line.len and is_space_byte(line.byte_at(i)):
        i += 1
    while true:
        let word_end = word_end_at(line, i)
        if word_end == i:
            return Option[str].none
        let word = line.slice(i, word_end - i)
        if word.equal("public") or word.equal("foreign") or word.equal("external"):
            i = skip_spaces(line, word_end)
            continue
        if not is_definition_keyword_name(word):
            return Option[str].none
        i = skip_spaces(line, word_end)
        let name_end = word_end_at(line, i)
        if name_end == i:
            return Option[str].none
        return Option[str].some(value = line.slice(i, name_end - i))
    return Option[str].none


function word_end_at(line: str, start: ptr_uint) -> ptr_uint:
    var i = start
    while i < line.len and is_identifier_byte(line.byte_at(i)):
        i += 1
    return i


function skip_spaces(line: str, start: ptr_uint) -> ptr_uint:
    var i = start
    while i < line.len and is_space_byte(line.byte_at(i)):
        i += 1
    return i


function is_space_byte(b: ubyte) -> bool:
    return b == ' ' or b == '\t' or b == '\r'


function is_identifier_byte(b: ubyte) -> bool:
    return (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or (b >= '0' and b <= '9') or b == '_'


## The host's `DEFINITION_KEYWORDS`: a declaration keyword whose following
## identifier names a definition.
function is_definition_keyword(kind: tk.TokenKind) -> bool:
    if kind == tk.TokenKind.tk_function:
        return true
    if kind == tk.TokenKind.tk_struct:
        return true
    if kind == tk.TokenKind.tk_union:
        return true
    if kind == tk.TokenKind.tk_enum:
        return true
    if kind == tk.TokenKind.tk_flags:
        return true
    if kind == tk.TokenKind.tk_variant:
        return true
    if kind == tk.TokenKind.tk_type:
        return true
    if kind == tk.TokenKind.tk_const:
        return true
    if kind == tk.TokenKind.tk_var:
        return true
    if kind == tk.TokenKind.tk_let:
        return true
    if kind == tk.TokenKind.tk_extending:
        return true
    if kind == tk.TokenKind.tk_opaque:
        return true
    if kind == tk.TokenKind.tk_interface:
        return true
    if kind == tk.TokenKind.tk_event:
        return true
    return false


function is_definition_keyword_name(word: str) -> bool:
    if word.equal("function") or word.equal("struct") or word.equal("union"):
        return true
    if word.equal("enum") or word.equal("flags") or word.equal("variant"):
        return true
    if word.equal("type") or word.equal("const") or word.equal("var") or word.equal("let"):
        return true
    if word.equal("extending") or word.equal("opaque") or word.equal("interface") or word.equal("event"):
        return true
    return false
