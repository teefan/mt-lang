## The workspace's identifier-token index — the host's `@identifier_index` plus
## `@indexed_uris` and its scan fallback (`lsp/workspace/caches.rb`).
##
## The host builds it lazily: every `get_tokens(uri)` call lexes a document once
## and records each identifier token by lexeme, and both `find_all_references`
## and `find_all_references_in` answer with the *indexed* entries first, in the
## order the documents were first tokenized, then scan the documents they have
## not indexed yet (appending them in the caller's candidate order).  That
## insertion order is observable in the response array, so this index keeps the
## same order instead of re-sorting.
##
## Identifier tokens are stored as views into an owned copy of each document's
## text, so a query is a name comparison per token with no per-lookup
## allocation, exactly like the host's per-name array.

import std.map as map_mod
import std.mem.heap
import std.str
import std.string as string_mod
import std.vec as vec

import mtc.lexer.lexer as lexer_mod
import mtc.lexer.token as token_mod
import mtc.lexer.token_kinds as tk


## One identifier token: its lexeme (a view into the document's stored text),
## 1-based lexer line/column, and byte length.
struct IdentifierToken:
    name: str
    line: ptr_uint
    column: ptr_uint
    length: ptr_uint


## One indexed document: its text (which the token views point into), its path,
## and its identifier tokens in source order.
struct IndexedDocument:
    path: string_mod.String
    source: string_mod.String
    identifiers: vec.Vec[IdentifierToken]


## A reference hit: the document (by path) and the identifier token.
public struct ReferenceEntry:
    path: str
    line: ptr_uint
    column: ptr_uint
    length: ptr_uint


public struct ReferenceIndex:
    ## Documents in tokenization order.  A re-indexed document moves to the end,
    ## as the host's re-appended entries do.
    documents: vec.Vec[ptr[IndexedDocument]]
    ## path → the document's stored content hash, so an unchanged document is a
    ## no-op and an edited one is re-indexed.
    hashes: map_mod.Map[string_mod.String, uint]


public function create() -> ReferenceIndex:
    return ReferenceIndex(
        documents = vec.Vec[ptr[IndexedDocument]].create(),
        hashes = map_mod.Map[string_mod.String, uint].create(),
    )


public function release(index: ref[ReferenceIndex]) -> void:
    var di: ptr_uint = 0
    while di < index.documents.len():
        let dp = index.documents.get(di) else:
            break
        release_document(unsafe: read(dp))
        di += 1
    index.documents.release()
    index.hashes.release()


## Record `path`'s identifier tokens, lexing `source` — the host's
## `index_identifier_tokens` reached through `get_tokens`.  A document whose
## content is unchanged is left alone; a changed one is re-indexed at the end.
public function note(index: ref[ReferenceIndex], path: str, source: str) -> void:
    var hash_key = string_mod.String.from_str(path)
    defer: hash_key.release()
    let hash = source_hash(source)
    let stored_hash = index.hashes.get(hash_key)
    if stored_hash != null:
        if unsafe: read(stored_hash) == hash:
            return
        drop_document(index, path)

    let allocated = heap.must_alloc[IndexedDocument](1)
    let document = unsafe: ptr[IndexedDocument]<-allocated
    # The token views point into the stored copy, so it is built — and walked —
    # before the struct assignment moves it into place.
    var stored_source = string_mod.String.from_str(source)
    var stored_path = string_mod.String.from_str(path)
    var identifiers = collect_identifiers(stored_source.as_str())
    unsafe:
        read(document) = IndexedDocument(
            path = stored_path,
            source = stored_source,
            identifiers = identifiers,
        )
    index.documents.push(document)

    var hash_slot = index.hashes.set(string_mod.String.from_str(path), hash)
    match hash_slot:
        Option.some as previous:
            let _ = previous
        Option.none:
            pass


## Drop `path`'s index entry: the host's `remove_identifier_index_entries` (its
## content changed, or it closed).
public function forget(index: ref[ReferenceIndex], path: str) -> void:
    var key = string_mod.String.from_str(path)
    defer: key.release()
    let removed = index.hashes.remove(key)
    match removed:
        Option.some as value:
            let _ = value
        Option.none:
            return
    drop_document(index, path)


## True when `path` has been indexed — the host's `@indexed_uris` membership.
public function is_indexed(index: ref[ReferenceIndex], path: str) -> bool:
    var key = string_mod.String.from_str(path)
    defer: key.release()
    return index.hashes.contains(key)


## Every occurrence of `name`, in index order (documents first-tokenized first,
## source order within a document) — the host's `find_all_references` over the
## documents it has already indexed.
public function entries_named(index: ref[ReferenceIndex], name: str, results: ref[vec.Vec[ReferenceEntry]]) -> void:
    var di: ptr_uint = 0
    while di < index.documents.len():
        let dp = index.documents.get(di) else:
            break
        append_entries(unsafe: read(dp), name, Option[span[str]].none, results)
        di += 1


## The occurrences of `name` in `paths`, in index order — the host's
## `find_all_references_in`, whose candidate set is the reverse-import
## dependents of the declaring module plus the declaring file itself.
public function entries_named_in(
    index: ref[ReferenceIndex],
    name: str,
    paths: span[str],
    results: ref[vec.Vec[ReferenceEntry]],
) -> void:
    var di: ptr_uint = 0
    while di < index.documents.len():
        let dp = index.documents.get(di) else:
            break
        append_entries(unsafe: read(dp), name, Option[span[str]].some(value = paths), results)
        di += 1


## Append one document's matching tokens, when it is in `filter` (none = all).
function append_entries(
    document: ptr[IndexedDocument],
    name: str,
    filter: Option[span[str]],
    results: ref[vec.Vec[ReferenceEntry]],
) -> void:
    unsafe:
        if not in_path_filter(read(document).path.as_str(), filter):
            return

        var ii: ptr_uint = 0
        while ii < read(document).identifiers.len():
            let ip = read(document).identifiers.get(ii) else:
                break
            let token = read(ip)
            if token.name.equal(name):
                results.push(ReferenceEntry(
                    path = read(document).path.as_str(),
                    line = token.line,
                    column = token.column,
                    length = token.length,
                ))
            ii += 1


function path_in(path: str, paths: span[str]) -> bool:
    var pi: ptr_uint = 0
    while pi < paths.len:
        if unsafe: read(paths.data + pi).equal(path):
            return true
        pi += 1
    return false


## True when `path` passes the optional candidate filter (none = every document).
function in_path_filter(path: str, filter: Option[span[str]]) -> bool:
    match filter:
        Option.some as paths:
            return path_in(path, paths.value)
        Option.none:
            return true


## Remove `path`'s document from the index and release it.
function drop_document(index: ref[ReferenceIndex], path: str) -> void:
    var di: ptr_uint = 0
    while di < index.documents.len():
        let dp = index.documents.get(di) else:
            break
        let document = unsafe: read(dp)
        var matches = false
        unsafe:
            matches = read(document).path.as_str().equal(path)
        if matches:
            match index.documents.remove(di):
                Option.some as removed:
                    release_document(removed.value)
                Option.none:
                    pass
            return
        di += 1


function release_document(document: ptr[IndexedDocument]) -> void:
    unsafe:
        read(document).path.release()
        read(document).source.release()
        read(document).identifiers.release()


## Every identifier token of `source` in source order, as views into it.
function collect_identifiers(source: str) -> vec.Vec[IdentifierToken]:
    var identifiers = vec.Vec[IdentifierToken].create()

    var lex_diags = vec.Vec[token_mod.LexDiagnostic].create()
    defer: lex_diags.release()
    var tokens = lexer_mod.lex_reporting(source, ref_of(lex_diags))
    defer: tokens.release()

    var ti: ptr_uint = 0
    while ti < tokens.len():
        let tp = tokens.get(ti) else:
            break
        let tok = unsafe: read(tp)
        if tok.kind == tk.TokenKind.identifier:
            if tok.start_offset < source.len and tok.end_offset <= source.len and tok.end_offset > tok.start_offset:
                identifiers.push(IdentifierToken(
                    name = unsafe: str(data = source.data + tok.start_offset, len = tok.end_offset - tok.start_offset),
                    line = tok.line,
                    column = tok.column,
                    length = tok.end_offset - tok.start_offset,
                ))
        ti += 1
    return identifiers


function source_hash(text: str) -> uint:
    var hash: uint = 2166136261
    var i: ptr_uint = 0
    while i < text.len:
        hash = (hash ^ uint<-text.byte_at(i)) * 16777619
        i += 1
    return hash
