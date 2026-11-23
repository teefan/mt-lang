# In-language tests for the LSP reference index: content-hash idempotence,
# re-index ordering, the retained-text bound and the disk-stamp cache.
# Run with: mtc test projects/mtc/test/lsp_index_test.mt

import std.str
import std.string as string
import std.vec as vec

import mtc.lsp.reference_index as refidx


@[test]
function test_reference_index_note_is_idempotent() -> void:
    var index = refidx.create()
    defer: refidx.release(ref_of(index))

    refidx.note(ref_of(index), "/a.mt", "let alpha = 1\n")
    let first_len = index.retained_bytes
    expect(first_len > 0)

    # The same content indexes nothing new (and does not double-count bytes).
    refidx.note(ref_of(index), "/a.mt", "let alpha = 1\n")
    expect_eq(int<-index.documents.len(), 1)
    expect_eq(int<-index.retained_bytes, int<-first_len)


@[test]
function test_reference_index_reindex_moves_document_to_the_end() -> void:
    var index = refidx.create()
    defer: refidx.release(ref_of(index))

    refidx.note(ref_of(index), "/a.mt", "alpha\n")
    refidx.note(ref_of(index), "/b.mt", "beta alpha\n")
    # A changed document is re-indexed at the end (the host's re-append order).
    refidx.note(ref_of(index), "/a.mt", "alpha two\n")

    var results = vec.Vec[refidx.ReferenceEntry].create()
    defer: results.release()
    refidx.entries_named(ref_of(index), "alpha", ref_of(results))
    expect_eq(int<-results.len(), 2)

    let first = results.get(0) else:
        expect(false, "missing first entry")
    let second = results.get(1) else:
        expect(false, "missing second entry")
    expect(unsafe: read(first).path.equal("/b.mt"))
    expect(unsafe: read(second).path.equal("/a.mt"))


@[test]
function test_reference_index_records_document_imports() -> void:
    # The index records each noted document's import module names, so the
    # references path can ask for a module's importers (the host's
    # `reverse_import_dependents_for` over its indexed documents).
    var index = refidx.create()
    defer: refidx.release(ref_of(index))

    refidx.note(ref_of(index), "/a.mt", "import std.vec as vec\n\nlet a = 1\n")
    refidx.note(ref_of(index), "/b.mt", "import std.map\nimport std.vec\n\nlet b = 2\n")
    refidx.note(ref_of(index), "/c.mt", "import std.str\n\nlet c = 3\n")

    var importers = vec.Vec[string.String].create()
    defer: release_importers(ref_of(importers))
    refidx.documents_importing(ref_of(index), "std.vec", ref_of(importers))
    expect_eq(int<-importers.len(), 2)
    let first = importers.get(0) else:
        expect(false, "missing first importer")
    expect(unsafe: read(first).as_str().equal("/a.mt"))
    let second = importers.get(1) else:
        expect(false, "missing second importer")
    expect(unsafe: read(second).as_str().equal("/b.mt"))

    # A re-note without the import drops the document from the importers.
    refidx.note(ref_of(index), "/a.mt", "let a = 1\n")
    var after = vec.Vec[string.String].create()
    defer: release_importers(ref_of(after))
    refidx.documents_importing(ref_of(index), "std.vec", ref_of(after))
    expect_eq(int<-after.len(), 1)
    let only = after.get(0) else:
        expect(false, "missing importer after re-note")
    expect(unsafe: read(only).as_str().equal("/b.mt"))


function release_importers(paths: ref[vec.Vec[string.String]]) -> void:
    var i: ptr_uint = 0
    while i < paths.len():
        let p = paths.get(i) else:
            break
        unsafe: read(p).release()
        i += 1
    paths.release()


@[test]
function test_reference_index_retained_text_bound_evicts_oldest() -> void:
    var index = refidx.create()
    defer: refidx.release(ref_of(index))
    # Small synthetic budget: two six-byte documents exceed it.
    index.max_retained_bytes = 10

    refidx.note(ref_of(index), "/a.mt", "alpha\n")
    refidx.note(ref_of(index), "/b.mt", "alpha\n")

    # The oldest document is dropped with its hash, so a lookup treats it as
    # unseen (and would re-read it) while the newest is still indexed.
    expect(not refidx.is_indexed(ref_of(index), "/a.mt"))
    expect(refidx.is_indexed(ref_of(index), "/b.mt"))
    expect_eq(int<-index.documents.len(), 1)

    var results = vec.Vec[refidx.ReferenceEntry].create()
    defer: results.release()
    refidx.entries_named(ref_of(index), "alpha", ref_of(results))
    expect_eq(int<-results.len(), 1)
    let only = results.get(0) else:
        expect(false, "missing entry")
    expect(unsafe: read(only).path.equal("/b.mt"))


@[test]
function test_reference_index_stamps() -> void:
    var index = refidx.create()
    defer: refidx.release(ref_of(index))

    expect(not refidx.matches_stamp(ref_of(index), "/a.mt", 10, 100, 5))
    refidx.record_stamp(ref_of(index), "/a.mt", 10, 100, 5)
    expect(refidx.matches_stamp(ref_of(index), "/a.mt", 10, 100, 5))
    expect(not refidx.matches_stamp(ref_of(index), "/a.mt", 11, 100, 5))
    expect(not refidx.matches_stamp(ref_of(index), "/a.mt", 10, 101, 5))

    # Updating a stamp replaces it in place.
    refidx.record_stamp(ref_of(index), "/a.mt", 11, 100, 5)
    expect(refidx.matches_stamp(ref_of(index), "/a.mt", 11, 100, 5))
    expect(not refidx.matches_stamp(ref_of(index), "/a.mt", 10, 100, 5))

    # Forgetting a document clears its stamp too.
    refidx.note(ref_of(index), "/a.mt", "alpha\n")
    refidx.forget(ref_of(index), "/a.mt")
    expect(not refidx.matches_stamp(ref_of(index), "/a.mt", 11, 100, 5))
    expect(not refidx.is_indexed(ref_of(index), "/a.mt"))
    expect_eq(int<-index.retained_bytes, 0)
