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


## LSP SymbolKinds, as the host's `symbol_kind` maps them.
const KIND_TYPE_ALIAS: int = 5
const KIND_ENUM:       int = 10
const KIND_INTERFACE:  int = 11
const KIND_FUNCTION:   int = 12
const KIND_VARIABLE:   int = 13
const KIND_CONSTANT:   int = 14
const KIND_STRUCT:     int = 23
const KIND_EVENT:      int = 24


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


## One token-pair declaration as the host's `extract_symbols_from_tokens`
## reports it: the identifier's name, the LSP SymbolKind of the keyword that
## introduced it, and its 1-based position.
public struct SymbolEntry:
    name: string.String
    kind: int
    line: ptr_uint
    column: ptr_uint


## Per-document state: the token-pair index (name → tokens, document order), the
## names the document's declaration lines introduce, and the declaration symbols
## in document order (the host's `get_symbols`).
public struct DocumentIndex:
    tokens: map_mod.Map[string.String, vec.Vec[DefinitionToken]]
    names: map_mod.Map[string.String, bool]
    symbols: vec.Vec[SymbolEntry]


public struct DefinitionIndex:
    documents: map_mod.Map[string.String, DocumentIndex]
    ## The host's `@definition_candidate_uris`: the documents known to declare a
    ## name, in warm order (the order they were first warmed).
    candidates: map_mod.Map[string.String, vec.Vec[string.String]]
    ## The host's `@definition_names_by_uri`: the names each warmed document
    ## registered, so a re-warm can drop the stale ones first.
    names_by_uri: map_mod.Map[string.String, vec.Vec[string.String]]
    ## Every warmed document's path in warm order — the host's
    ## `@indexed_documents.keys` order, which `workspace/symbol` reports in.
    warm_order: vec.Vec[string.String]
    warm_seen: map_mod.Map[string.String, bool]


public function create() -> DefinitionIndex:
    return DefinitionIndex(
        documents = map_mod.Map[string.String, DocumentIndex].create(),
        candidates = map_mod.Map[string.String, vec.Vec[string.String]].create(),
        names_by_uri = map_mod.Map[string.String, vec.Vec[string.String]].create(),
        warm_order = vec.Vec[string.String].create(),
        warm_seen = map_mod.Map[string.String, bool].create(),
    )


## The documents the index knows, in warm order (the host's
## `@indexed_documents` keys).  Borrowed from the index.
public function warmed_paths(index: ref[DefinitionIndex]) -> span[string.String]:
    return index.warm_order.as_span()


## The documents known to declare `name`, in warm order — the host's
## `candidate_definition_uris` after its lazy warm pass.  Borrowed from the
## index; empty when no warmed document declares the name.
public function candidate_paths_for(index: ref[DefinitionIndex], name: str) -> span[string.String]:
    var key = string.String.from_str(name)
    defer: key.release()
    let cell = index.candidates.get(key) else:
        return span[string.String]()
    return unsafe: read(cell).as_span()


## True when `uri`'s declaration names are already registered.
public function knows_names(index: ref[DefinitionIndex], uri: str) -> bool:
    var key = string.String.from_str(uri)
    defer: key.release()
    return index.names_by_uri.contains(key)


## Register `uri`'s declaration names (the host's
## `warm_definition_candidates_for_uri`), so a later lookup can pick the
## candidate documents without scanning them.  Already-warmed documents are
## left alone; `forget` drops a document's entries when its content changes.
public function warm_names(index: ref[DefinitionIndex], uri: str, source: str) -> void:
    if uri.len == 0:
        return
    # The map takes ownership of the key when the document is stored, so the
    # early return is the only path that releases it.
    var key = string.String.from_str(uri)
    if index.names_by_uri.contains(key):
        key.release()
        return
    if not index.warm_seen.contains(key):
        index.warm_order.push(string.String.from_str(uri))
        index.warm_seen.set(string.String.from_str(uri), true)

    var names = map_mod.Map[string.String, bool].create()
    defer: names.release()
    collect_declared_names(ref_of(names), source)

    var name_list = vec.Vec[string.String].create()
    var name_iter = names.keys()
    while true:
        let name_ptr = name_iter.next() else:
            break
        let name = unsafe: read(name_ptr)
        name_list.push(string.String.from_str(name.as_str()))

        let cell = index.candidates.get(name)
        if cell != null:
            # The stored Vec is a value: push through a local and write it back,
            # so a reallocation cannot leave the map holding a stale buffer.
            var uri_list = unsafe: read(cell)
            uri_list.push(string.String.from_str(uri))
            unsafe: read(cell) = uri_list
        else:
            var uri_list = vec.Vec[string.String].create()
            uri_list.push(string.String.from_str(uri))
            index.candidates.set(string.String.from_str(name.as_str()), uri_list)

    index.names_by_uri.set(key, name_list)


## Drop a document's candidate entries (its declaration names changed), keeping
## the index's other documents' entries in their warm order.
function drop_names(index: ref[DefinitionIndex], uri: str) -> void:
    var key = string.String.from_str(uri)
    defer: key.release()
    match index.names_by_uri.remove_entry(key):
        Option.some as removed:
            var entry = removed.value
            entry.key.release()
            var names = entry.value
            var i: ptr_uint = 0
            while i < names.len():
                let name = names.get(i) else:
                    break
                let cell = index.candidates.get(unsafe: read(name))
                if cell != null:
                    remove_candidate(cell, uri)
                i += 1
            release_string_vec(ref_of(names))
        Option.none:
            pass


## Remove one path from a candidate list, releasing the removed string.  The
## Vec is stored in the map by value, so the shortened Vec is written back.
function remove_candidate(cell: ptr[vec.Vec[string.String]], uri: str) -> void:
    var paths = unsafe: read(cell)
    var i: ptr_uint = 0
    while i < paths.len():
        let entry = paths.get(i) else:
            break
        if unsafe: read(entry).as_str().equal(uri):
            match paths.remove(i):
                Option.some as removed:
                    removed.value.release()
                Option.none:
                    pass
            unsafe: read(cell) = paths
            return
        i += 1


function release_string_vec(values: ref[vec.Vec[string.String]]) -> void:
    var i: ptr_uint = 0
    while i < values.len():
        let entry = values.get(i) else:
            break
        unsafe: read(entry).release()
        i += 1
    values.release()


## Drop a document's index: its content changed, so its declaration tokens and
## names are rebuilt on the next lookup.  The host clears the per-uri token
## index and re-warms the name candidates the same way.
public function forget(index: ref[DefinitionIndex], uri: str) -> void:
    var key = string.String.from_str(uri)
    defer: key.release()
    drop_names(index, uri)
    match index.documents.remove_entry(key):
        Option.some as removed:
            var entry = removed.value
            entry.key.release()
            var doc_index = entry.value
            release_document_index(ref_of(doc_index))
        Option.none:
            pass


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
    release_map_keys(ref_of(index.documents))
    index.documents.release()

    var name_iter = index.names_by_uri.entries()
    while name_iter.next():
        let entry = name_iter.current()
        unsafe:
            read(entry.key).release()
            var names = read(entry.value)
            release_string_vec(ref_of(names))
    index.names_by_uri.release()

    var candidate_iter = index.candidates.entries()
    while candidate_iter.next():
        let entry = candidate_iter.current()
        unsafe:
            read(entry.key).release()
            var paths = read(entry.value)
            release_string_vec(ref_of(paths))
    index.candidates.release()

    release_string_vec(ref_of(index.warm_order))
    release_map_keys_bool(ref_of(index.warm_seen))
    index.warm_seen.release()


## Release a map's stored string keys (the values are released by the caller).
function release_map_keys_bool(values: ref[map_mod.Map[string.String, bool]]) -> void:
    var iter = values.keys()
    while true:
        let key_ptr = iter.next() else:
            break
        unsafe: read(key_ptr).release()


## Release a map's stored string keys (the values are released by the caller).
function release_map_keys(values: ref[map_mod.Map[string.String, DocumentIndex]]) -> void:
    var iter = values.keys()
    while true:
        let key_ptr = iter.next() else:
            break
        unsafe: read(key_ptr).release()


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


## The declaration symbols of `doc` in document order, warming its token index
## first — the host's `get_symbols(uri)` → `extract_symbols_from_tokens`.
public function symbols_for(index: ref[DefinitionIndex], path: str, source: str) -> span[SymbolEntry]:
    let doc = CandidateDocument(uri = path, source = source)
    warm_document(index, doc)
    let stored = stored_document(index, path) else:
        return span[SymbolEntry]()
    return stored.symbols.as_span()


## Warm `doc` when it is not indexed yet: the pair index of its declaration
## identifiers, the set of names its declaration lines introduce, and its
## declaration symbols.
function warm_document(index: ref[DefinitionIndex], doc: CandidateDocument) -> void:
    var key = string.String.from_str(doc.uri)
    defer: key.release()
    if index.documents.contains(key):
        return

    var tokens = map_mod.Map[string.String, vec.Vec[DefinitionToken]].create()
    var symbols = vec.Vec[SymbolEntry].create()
    index_tokens(ref_of(tokens), ref_of(symbols), doc.source)

    var names = map_mod.Map[string.String, bool].create()
    collect_declared_names(ref_of(names), doc.source)

    index.documents.set(string.String.from_str(doc.uri), DocumentIndex(tokens = tokens, names = names, symbols = symbols))


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
    var si: ptr_uint = 0
    while si < doc_index.symbols.len():
        let entry = doc_index.symbols.get(si) else:
            break
        unsafe: read(entry).name.release()
        si += 1
    doc_index.symbols.release()


## Index every identifier that immediately follows a declaration keyword — the
## host's `definition_token_index` token-pair scan (structural tokens included,
## since they are part of the stream) — and collect the same pairs as declaration
## symbols, in document order (`extract_symbols_from_tokens`).
function index_tokens(
    tokens: ref[map_mod.Map[string.String, vec.Vec[DefinitionToken]]],
    symbols: ref[vec.Vec[SymbolEntry]],
    source: str,
) -> void:
    var lex_diags = vec.Vec[token_mod.LexDiagnostic].create()
    defer: lex_diags.release()
    var lexed = lexer_mod.lex_reporting(source, ref_of(lex_diags))
    defer: lexed.release()

    var previous_kind: int = -1
    var ti: ptr_uint = 0
    while ti < lexed.len():
        let token_ptr = lexed.get(ti) else:
            break
        let token = unsafe: read(token_ptr)
        if previous_kind >= 0 and token.kind == tk.TokenKind.identifier:
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
            # `_` is a discard, never a symbol (the host's extraction skips it).
            if not (previous_kind == KIND_VARIABLE and lexeme.equal("_")):
                symbols.push(SymbolEntry(
                    name = string.String.from_str(lexeme),
                    kind = previous_kind,
                    line = token.line,
                    column = token.column,
                ))
        previous_kind = symbol_kind_for_keyword(token.kind)
        ti += 1


## The LSP SymbolKind of a declaration keyword, or -1 for every other token —
## the host's kind table (`function`/`struct`/… → `symbol_kind`).
function symbol_kind_for_keyword(kind: tk.TokenKind) -> int:
    if not is_definition_keyword(kind):
        return -1
    if kind == tk.TokenKind.tk_function:
        return KIND_FUNCTION
    if kind == tk.TokenKind.tk_interface:
        return KIND_INTERFACE
    if kind == tk.TokenKind.tk_type:
        return KIND_TYPE_ALIAS
    if kind == tk.TokenKind.tk_const:
        return KIND_CONSTANT
    if kind == tk.TokenKind.tk_let or kind == tk.TokenKind.tk_var:
        return KIND_VARIABLE
    if kind == tk.TokenKind.tk_enum or kind == tk.TokenKind.tk_flags:
        return KIND_ENUM
    if kind == tk.TokenKind.tk_event:
        return KIND_EVENT
    return KIND_STRUCT


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
