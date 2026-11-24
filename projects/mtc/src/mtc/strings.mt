## Shared text helpers — fixed-arity string joins used across the compiler, plus
## the content fingerprint.
##
## The joins were previously re-implemented or wrapped in eight modules as
## `j2`..`j6`; one leaf module keeps a single implementation and lets the C
## backend depend on `ir` instead of `lowering`.
##
## `fnv1a_hash` was defined four times (loader, lsp/workspace,
## lsp/semantic_tokens, lsp/pull_diagnostics) with two spellings of the same
## constants; this is rank 0, so every consumer reaches it downward.

import std.fmt as fmt
import std.string as string
import std.vec as vec

const FNV_OFFSET_BASIS: uint = 0x811C9DC5
const FNV_PRIME: uint = 0x01000193


## FNV-1a over the text's bytes.  Used as a content fingerprint for the module,
## analysis, diagnostic and semantic-token caches: it only has to change when
## the text changes, not to resist an adversary.
public function fnv1a_hash(text: str) -> uint:
    var hash: uint = FNV_OFFSET_BASIS
    var i: ptr_uint = 0
    while i < text.len:
        hash = (hash ^ uint<-text.byte_at(i)) * FNV_PRIME
        i += 1
    return hash


## Join two text parts into one `str`.
public function join_two(a: str, b: str) -> str:
    var buf = string.String.create()
    buf.append(a)
    buf.append(b)
    return buf.as_str()


## Join three text parts into one `str`.
public function join_three(a: str, b: str, c: str) -> str:
    var buf = string.String.create()
    buf.append(a)
    buf.append(b)
    buf.append(c)
    return buf.as_str()


## Join four text parts into one `str`.
public function join_four(a: str, b: str, c: str, d: str) -> str:
    var buf = string.String.create()
    buf.append(a)
    buf.append(b)
    buf.append(c)
    buf.append(d)
    return buf.as_str()


## Join five text parts into one `str`.
public function join_five(a: str, b: str, c: str, d: str, e: str) -> str:
    var buf = string.String.create()
    buf.append(a)
    buf.append(b)
    buf.append(c)
    buf.append(d)
    buf.append(e)
    return buf.as_str()


## Join six text parts into one `str`.
public function join_six(a: str, b: str, c: str, d: str, e: str, f: str) -> str:
    var buf = string.String.create()
    buf.append(a)
    buf.append(b)
    buf.append(c)
    buf.append(d)
    buf.append(e)
    buf.append(f)
    return buf.as_str()


## Split `source` on `\n`, keeping a trailing empty element when the text ends
## with a newline (so line count == newline count + 1, and an empty source is
## one empty line).  `linter/redundant_cast.mt` and `linter/platform_drift.mt`
## carried byte-identical private copies; both index lines by 1-based line
## number, which this shape preserves.
public function split_lines(source: str) -> vec.Vec[str]:
    var lines = vec.Vec[str].create()
    var start: ptr_uint = 0
    var i: ptr_uint = 0
    while i <= source.len:
        if i == source.len or source.byte_at(i) == 10:
            lines.push(source.slice(start, i - start))
            start = i + 1
        i += 1
    return lines


## Decimal text for a `ptr_uint`.  Four modules carried their own copy (the
## analyzer's was already a one-line delegate to `diagnostics`); `fmt` owns the
## conversion, so this is the single spelling.
public function uint_to_str(value: ptr_uint) -> str:
    var buf = string.String.create()
    fmt.append_ptr_uint(ref_of(buf), value)
    return buf.as_str()
