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


## A document's last-observed disk state, so an unchanged closed document is
## neither re-read nor re-lexed on the next lookup.  (The host re-reads through
## its content cache; the stat is the self-host's bound on that work.)
public struct DocumentStamp:
    size: ptr_uint
    modified_seconds: ptr_int
    modified_nanoseconds: ptr_int


## The retained-text budget for indexed documents.  Past this many bytes the
## oldest documents are dropped and re-indexed on demand — the host keeps every
## noted document's text forever, so this is a deliberate self-host bound for
## long sessions (documents evicted and re-noted answer in a later index
## position than the host would).
public const MAX_RETAINED_TEXT_BYTES: ptr_uint = 33554432


public struct ReferenceIndex:
    ## Documents in tokenization order.  A re-indexed document moves to the end,
    ## as the host's re-appended entries do.
    documents: vec.Vec[ptr[IndexedDocument]]
    ## path → the document's stored content hash, so an unchanged document is a
    ## no-op and an edited one is re-indexed.
    hashes: map_mod.Map[string_mod.String, uint]
    ## path → the disk state the document was last read at (closed documents
    ## only; open buffers are compared by content hash).
    stamps: map_mod.Map[string_mod.String, DocumentStamp]
    ## The indexed documents' total source bytes, against `max_retained_bytes`.
    retained_bytes: ptr_uint
    ## The retained-text budget (`MAX_RETAINED_TEXT_BYTES` by default; tests
    ## shrink it).
    max_retained_bytes: ptr_uint


public function create() -> ReferenceIndex:
    return ReferenceIndex(
        documents = vec.Vec[ptr[IndexedDocument]].create(),
        hashes = map_mod.Map[string_mod.String, uint].create(),
        stamps = map_mod.Map[string_mod.String, DocumentStamp].create(),
        retained_bytes = 0,
        max_retained_bytes = MAX_RETAINED_TEXT_BYTES,
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
    index.stamps.release()


## True when the recorded disk stamp for `path` equals the observed one, so the
## document's text need not be re-read.
public function matches_stamp(index: ref[ReferenceIndex], path: str, size: ptr_uint, modified_seconds: ptr_int, modified_nanoseconds: ptr_int) -> bool:
    var key = string_mod.String.from_str(path)
    defer: key.release()
    let stamp_ptr = index.stamps.get(key)
    if stamp_ptr == null:
        return false
    let stamp = unsafe: read(stamp_ptr)
    return stamp.size == size and stamp.modified_seconds == modified_seconds and stamp.modified_nanoseconds == modified_nanoseconds


## Record the disk state `path` was last read at.
public function record_stamp(index: ref[ReferenceIndex], path: str, size: ptr_uint, modified_seconds: ptr_int, modified_nanoseconds: ptr_int) -> void:
    var key = string_mod.String.from_str(path)
    defer: key.release()
    let stamp_ptr = index.stamps.get(key)
    if stamp_ptr != null:
        unsafe:
            read(stamp_ptr).size = size
            read(stamp_ptr).modified_seconds = modified_seconds
            read(stamp_ptr).modified_nanoseconds = modified_nanoseconds
        return
    index.stamps.set(string_mod.String.from_str(path), DocumentStamp(
        size = size,
        modified_seconds = modified_seconds,
        modified_nanoseconds = modified_nanoseconds,
    ))


## Record `path`'s identifier tokens, lexing `source` — the host's
## `index_identifier_tokens` reached through `get_tokens`.  A document whose
## content is unchanged is left alone; a changed one is re-indexed at the end.
## Past the retained-text budget the oldest documents are dropped.
public function note(index: ref[ReferenceIndex], path: str, source: str) -> void:
    var hash_key = string_mod.String.from_str(path)
    defer: hash_key.release()
    let hash = source_hash(source)
    let stored_hash = index.hashes.get(hash_key)
    if stored_hash != null:
        if unsafe: read(stored_hash) == hash:
            return
        # Update the hash in place (the map keeps its existing key) and drop the
        # document; it is re-pushed at the end below.
        unsafe:
            read(stored_hash) = hash
        drop_document(index, path)
    else:
        index.hashes.set(string_mod.String.from_str(path), hash)

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
    index.retained_bytes = index.retained_bytes + source.len
    enforce_text_bound(index)


## Drop `path`'s index entry: the host's `remove_identifier_index_entries` (its
## content changed, or it closed).
public function forget(index: ref[ReferenceIndex], path: str) -> void:
    var key = string_mod.String.from_str(path)
    defer: key.release()
    match index.hashes.remove_entry(key):
        Option.some as removed:
            var removed_entry = removed.value
            unsafe:
                removed_entry.key.release()
        Option.none:
            return
    drop_document(index, path)
    var stamp_key = string_mod.String.from_str(path)
    defer: stamp_key.release()
    match index.stamps.remove_entry(stamp_key):
        Option.some as removed_stamp:
            var stamp_entry = removed_stamp.value
            unsafe:
                stamp_entry.key.release()
        Option.none:
            pass


## Drop the oldest indexed documents until the retained text is within the
## budget.  The most recently noted document is always kept (a single document
## larger than the budget must not thrash).  The hash and stamp entries go with
## the document, so a later lookup re-reads and re-indexes it.
function enforce_text_bound(index: ref[ReferenceIndex]) -> void:
    while index.retained_bytes > index.max_retained_bytes and index.documents.len() > 1:
        let front_slot = index.documents.get(0) else:
            break
        let front = unsafe: read(front_slot)
        var front_path = string_mod.String.from_str(unsafe: read(front).path.as_str())
        var hash_key = string_mod.String.from_str(front_path.as_str())
        var stamp_key = string_mod.String.from_str(front_path.as_str())
        drop_document(index, front_path.as_str())
        match index.hashes.remove_entry(hash_key):
            Option.some as removed:
                var removed_entry = removed.value
                unsafe:
                    removed_entry.key.release()
            Option.none:
                pass
        match index.stamps.remove_entry(stamp_key):
            Option.some as removed_stamp:
                var stamp_entry = removed_stamp.value
                unsafe:
                    stamp_entry.key.release()
            Option.none:
                pass
        hash_key.release()
        stamp_key.release()
        front_path.release()


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
                    let removed_len = unsafe: read(removed.value).source.len()
                    if removed_len <= index.retained_bytes:
                        index.retained_bytes = index.retained_bytes - removed_len
                    else:
                        index.retained_bytes = 0
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
