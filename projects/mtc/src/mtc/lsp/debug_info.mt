## Debug info handler — the `milkTea/debugInfo` request.  Renders the host's
## sections (`lib/milk_tea/tooling/debug_info_formatter.rb`), in its order:
##
##   Header        file path and content size
##   Tokens        every token: lexeme, kind, location, semantic class
##   Parse Errors  parser diagnostics
##   Diagnostics   the semantic snapshot's diagnostics
##
## The AST / Facts / Bindings sections render Ruby object ids, binding ids and
## Ruby AST class names; docs/self-host-plan.md §0k records what matching them
## requires.  The histogram's tie order is MRI's `rb_uniform_intro_sort_2`
## (see `histogram_intro_sort`).

import std.fmt
import std.json as json
import std.string as string
import std.vec as vec

import mtc.lexer.lexer as lexer_mod
import mtc.lexer.token as token_mod
import mtc.lexer.token_kinds as tk
import mtc.lsp.debug_ast as debug_ast
import mtc.lsp.debug_text as debug_text
import mtc.lsp.protocol as proto
import mtc.lsp.semantic_tokens as semtok
import mtc.lsp.uri as uri_ops
import mtc.lsp.workspace as workspace
import mtc.parser.parser as parser
import mtc.parser.state as pstate
import mtc.semantic.analyzer as analyzer


## The debug dump for the document named by the request's `textDocument.uri`.
public function build_debug_text(ws: ref[workspace.Workspace], uri: str) -> string.String:
    var text = string.String.create()
    if uri.len == 0:
        text.append("error: no textDocument.uri")
        return text

    var file_path = uri_ops.file_uri_to_path(uri) else:
        text.append("error: invalid uri ")
        text.append(uri)
        return text
    defer: file_path.release()

    var content = ws.document_source(file_path.as_str()) else:
        text.append("error: cannot read ")
        text.append(file_path.as_str())
        return text
    defer: content.release()
    let source = content.as_str()

    var lex_diags = vec.Vec[token_mod.LexDiagnostic].create()
    defer: lex_diags.release()
    var tokens = lexer_mod.lex_reporting(source, ref_of(lex_diags))
    defer: tokens.release()

    # Parse before emitting: the AST section renders this parse's tree and the
    # parse errors are its diagnostics.
    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer: parse_diags.release()
    var file = parser.parse_source(source, ref_of(parse_diags))

    # The line count the host prints is `content.count("\n") + 1`; the lexer's
    # last line is the same number.
    append_header(ref_of(text), file_path.as_str(), source, last_token_line(ref_of(tokens)))

    var classes = semtok.semantic_class_entries(ws, file_path.as_str(), source)
    defer: classes.release()
    append_token_section(ref_of(text), source, ref_of(tokens), ref_of(classes))
    debug_ast.append_ast_section(ref_of(text), file)
    append_parse_errors(ref_of(text), ref_of(parse_diags))

    # The semantic snapshot (the host's `get_tooling_snapshot`): the
    # loader-backed analysis the other requests share.
    let entry_ptr = workspace.analysis_entry_for(ws, file_path.as_str()) else:
        text.append("\n\n── Diagnostics  (not available) ──")
        return text
    var entry = unsafe: read(entry_ptr)
    append_diagnostics_text(ref_of(text), ref_of(entry.analysis))
    return text


## `File: <path>` / `Content: <lines> lines, <bytes> bytes`.
function append_header(target: ref[string.String], path: str, source: str, line_count: ptr_uint) -> void:
    target.append("File: ")
    target.append(path)
    target.append("\nContent: ")
    target.append_format(f"#{line_count} lines, #{source.len} bytes")


## The line of the token stream's last token (the eof), i.e. the number of lines
## the host reports for the content.
function last_token_line(tokens: ref[vec.Vec[token_mod.Token]]) -> ptr_uint:
    let last_index = if tokens.len() > 0: tokens.len() - 1 else: 0
    let tp = tokens.get(last_index) else:
        return 1
    return unsafe: read(tp).line


## The token table: a header with the count and a per-kind histogram, then one
## aligned line per token.
function append_token_section(
    target: ref[string.String],
    source: str,
    tokens: ref[vec.Vec[token_mod.Token]],
    classes: ref[vec.Vec[semtok.SemanticClass]],
) -> void:
    target.append("\n\n── Tokens  ")
    target.append_format(f"#{tokens.len()}")
    target.append("  (")
    append_token_histogram(target, tokens)
    target.append(") ")
    debug_text.append_rule(target, 50)

    let max_len = token_table_lexeme_width(tokens)
    var ti: ptr_uint = 0
    while ti < tokens.len():
        let tp = tokens.get(ti) else:
            break
        let tok = unsafe: read(tp)
        let lexeme = unsafe: token_mod.token_lexeme(tok, source)
        let end_col = if tok.kind == tk.TokenKind.eof: tok.column else: tok.column + lexeme.len - 1

        target.append("\n  ")
        append_left_aligned(target, tok.line, 3)
        target.append(":")
        var column_text = uint_to_str(tok.column)
        append_right_padded(target, column_text.as_str(), 3)
        column_text.release()
        target.append("  ")
        var inspected = debug_text.ruby_inspect(lexeme)
        append_right_padded(target, inspected.as_str(), max_len + 2)
        inspected.release()
        target.append("  ")
        append_right_padded(target, token_mod.kind_name(tok.kind), 16)
        target.append("  Ln ")
        append_left_aligned(target, tok.line, 2)
        target.append("  Col ")
        append_left_aligned(target, tok.column, 3)
        target.append("-")
        target.append_format(f"#{end_col}")
        target.append("  ")
        append_right_padded(target, semtok.semantic_class_at(classes, tok.line, tok.column), 22)
        target.append("  ")
        if tok.kind == tk.TokenKind.eof:
            target.append("◄")
        ti += 1


## The widest lexeme in the table, capped at 28; indentation tokens carry no text
## and never set the width.
function token_table_lexeme_width(tokens: ref[vec.Vec[token_mod.Token]]) -> ptr_uint:
    var width: ptr_uint = 0
    var i: ptr_uint = 0
    while i < tokens.len():
        let tp = tokens.get(i) else:
            break
        let tok = unsafe: read(tp)
        if tok.kind != tk.TokenKind.newline and tok.kind != tk.TokenKind.indent and tok.kind != tk.TokenKind.dedent:
            let len = if tok.end_offset > tok.start_offset: tok.end_offset - tok.start_offset else: 0
            if len > width:
                width = len
        i += 1
    if width > 28:
        return 28
    return width


## One histogram row: a token kind and its token count.
public struct HistogramEntry:
    kind: tk.TokenKind
    count: ptr_uint


## `75 identifier, 36 newline, ...`: the host sorts the per-kind counts with
## Ruby's `sort_by { |_k, v| -v }`.  Every key there is a Fixnum, so the sort
## goes through MRI's *uniform* introsort (`rb_uniform_intro_sort_2`, `enum.c`),
## not `ruby_qsort` — and it is not stable, so equal counts come out in its
## order, not insertion order.  This port reproduces that order exactly
## (validated against MRI over random count tables and the corpus fixture).
function append_token_histogram(target: ref[string.String], tokens: ref[vec.Vec[token_mod.Token]]) -> void:
    var entries = vec.Vec[HistogramEntry].create()
    defer: entries.release()

    var i: ptr_uint = 0
    while i < tokens.len():
        let tp = tokens.get(i) else:
            break
        let kind = unsafe: read(tp).kind
        var ei: ptr_uint = 0
        var found = false
        while ei < entries.len():
            let ep = entries.get(ei) else:
                break
            if unsafe: read(ep).kind == kind:
                unsafe: read(ep).count += 1
                found = true
                break
            ei += 1
        if not found:
            entries.push(HistogramEntry(kind = kind, count = 1))
        i += 1

    histogram_intro_sort(ref_of(entries))

    var h: ptr_uint = 0
    while h < entries.len():
        if h > 0:
            target.append(", ")
        let entry = histogram_entry(ref_of(entries), h)
        target.append_format(f"#{entry.count}")
        target.append(" ")
        target.append(token_mod.kind_name(entry.kind))
        h += 1


## `rb_uniform_intro_sort_2`: sort unless already descending by count, then the
## depth-limited introsort (quicksort → heapsort after 2*floor(log2 n) levels,
## insertion sort for regions of 16 or fewer).  The comparison is on the
## host's key `-count`, i.e. a descending comparison on counts.
public function histogram_intro_sort(entries: ref[vec.Vec[HistogramEntry]]) -> void:
    let n = entries.len()
    if n < 2:
        return

    # Already descending by count (the host's `rb_uniform_is_larger` probe).
    var sorted = true
    var i: ptr_uint = 1
    while i < n:
        if histogram_entry(entries, i - 1).count < histogram_entry(entries, i).count:
            sorted = false
            break
        i += 1
    if sorted:
        return

    # d = floor(log2(n)); the introsort budget is `d << 1`.
    var depth: ptr_uint = 0
    var value = n
    while value > 1:
        value /= 2
        depth += 1
    histogram_quicksort_intro(entries, 0, n, depth * 2)


## `uless` on the three counts: the median count of `a`, `b`, `c`.
function histogram_med3(a: ptr_uint, b: ptr_uint, c: ptr_uint) -> ptr_uint:
    if a > b:
        if b > c:
            return b
        if c > a:
            return a
        return c
    if c > b:
        return b
    if a > c:
        return a
    return c


function histogram_entry(entries: ref[vec.Vec[HistogramEntry]], index: ptr_uint) -> HistogramEntry:
    let p = entries.get(index) else:
        return HistogramEntry(kind = tk.TokenKind.eof, count = 0)
    return unsafe: read(p)


function histogram_count_at(entries: ref[vec.Vec[HistogramEntry]], index: ptr_uint) -> ptr_uint:
    return histogram_entry(entries, index).count


function histogram_swap(entries: ref[vec.Vec[HistogramEntry]], left: ptr_uint, right: ptr_uint) -> void:
    if left == right:
        return
    let a = histogram_entry(entries, left)
    let b = histogram_entry(entries, right)
    let lp = entries.get(left) else:
        return
    let rp = entries.get(right) else:
        return
    unsafe:
        read(lp) = b
        read(rp) = a


## `rb_uniform_insertionsort_2`, indices [lo, hi).
function histogram_insertion_sort(entries: ref[vec.Vec[HistogramEntry]], lo: ptr_uint, hi: ptr_uint) -> void:
    if hi - lo < 2:
        return
    var index = lo + 1
    while index < hi:
        let tmp = histogram_entry(entries, index)
        var j = index
        var k = index
        if tmp.count > histogram_count_at(entries, lo):
            while lo < j:
                k -= 1
                let src = histogram_entry(entries, k)
                let dst = entries.get(j) else:
                    return
                unsafe: read(dst) = src
                j = k
        else:
            while true:
                k -= 1
                if tmp.count <= histogram_count_at(entries, k):
                    break
                let src = histogram_entry(entries, k)
                let dst = entries.get(j) else:
                    return
                unsafe: read(dst) = src
                j = k
        let dst = entries.get(j) else:
            return
        unsafe: read(dst) = tmp
        index += 1


## `rb_uniform_heap_down_2`.
function histogram_heap_down(entries: ref[vec.Vec[HistogramEntry]], lo: ptr_uint, offset: ptr_uint, len: ptr_uint) -> void:
    let tmp = histogram_entry(entries, lo + offset)
    var pos = offset
    while true:
        let child = (pos << 1) + 1
        if child > len:
            break
        var bigger = child
        if child < len and histogram_count_at(entries, lo + child) > histogram_count_at(entries, lo + child + 1):
            bigger += 1
        if tmp.count <= histogram_count_at(entries, lo + bigger):
            break
        let dst = entries.get(lo + pos) else:
            return
        let src = histogram_entry(entries, lo + bigger)
        unsafe: read(dst) = src
        pos = bigger
    let dst = entries.get(lo + pos) else:
        return
    unsafe: read(dst) = tmp


## `rb_uniform_heapsort_2`.
function histogram_heapsort(entries: ref[vec.Vec[HistogramEntry]], lo: ptr_uint, hi: ptr_uint) -> void:
    let n = hi - lo
    if n < 2:
        return
    var offset = n / 2
    while offset > 0:
        offset -= 1
        histogram_heap_down(entries, lo, offset, n - 1)
    offset = n - 1
    while offset > 0:
        histogram_swap(entries, lo, lo + offset)
        offset -= 1
        histogram_heap_down(entries, lo, 0, offset)


## `rb_uniform_quicksort_intro_2`: Hoare partition around the median of first,
## middle and last counts, falling back to heapsort when the depth budget runs
## out.  `i`/`j` are signed: the algorithm can step one element outside the
## region before the final `j + 1` (which the C pointer arithmetic absorbs).
function histogram_quicksort_intro(entries: ref[vec.Vec[HistogramEntry]], lo: ptr_uint, hi: ptr_uint, depth: ptr_uint) -> void:
    if hi - lo <= 16:
        histogram_insertion_sort(entries, lo, hi)
        return
    if depth == 0:
        histogram_heapsort(entries, lo, hi)
        return

    let lo_i = ptr_int<-lo
    let hi_i = ptr_int<-hi
    let mid = lo_i + ((hi_i - lo_i) / 2)
    let x = histogram_med3(
        histogram_count_at(entries, lo),
        histogram_count_at(entries, ptr_uint<-mid),
        histogram_count_at(entries, hi - 1),
    )
    var i = lo_i
    var j = hi_i - 1
    while true:
        while histogram_count_at(entries, ptr_uint<-i) > x:
            i += 1
        while x > histogram_count_at(entries, ptr_uint<-j):
            j -= 1
        if i <= j:
            histogram_swap(entries, ptr_uint<-i, ptr_uint<-j)
            i += 1
            j -= 1
        if i > j:
            break
    j += 1
    if hi_i - j > 1:
        histogram_quicksort_intro(entries, ptr_uint<-j, hi, depth - 1)
    if i - lo_i > 1:
        histogram_quicksort_intro(entries, lo, ptr_uint<-i, depth - 1)


function append_parse_errors(target: ref[string.String], errors: ref[vec.Vec[pstate.ParseDiagnostic]]) -> void:
    target.append("\n\n── Parse Errors  ")
    target.append_format(f"#{errors.len()}")
    if errors.len() == 0:
        target.append(" ──")
        return
    target.append("  ")
    debug_text.append_rule(target, 55)
    var i: ptr_uint = 0
    while i < errors.len():
        let ep = errors.get(i) else:
            break
        let e = unsafe: read(ep)
        target.append("\n  ERROR [Ln ")
        target.append_format(f"#{e.line}")
        target.append(", Col ")
        target.append_format(f"#{e.column}")
        target.append("]: ")
        fmt.append_cstr(target, e.message)
        i += 1


## `── Diagnostics  N  (E errors, W warnings, ...)` plus one row per diagnostic
## (`  E ERROR   sema/error [Ln 42, Col 14]: unknown name alpha`).  The host
## renders its tooling snapshot's diagnostics — the semantic analysis' errors,
## not the loader's import/parse diagnostics or the linter's warnings.
function append_diagnostics_text(target: ref[string.String], analysis: ref[analyzer.Analysis]) -> void:
    let count = analysis.diagnostics.len()
    if count == 0:
        target.append("\n\n── Diagnostics  0 ──")
        return

    target.append("\n\n── Diagnostics  ")
    target.append_format(f"#{count}")
    target.append("  (")
    target.append_format(f"#{count} errors")
    target.append(")  ")
    debug_text.append_rule(target, 50)

    var i: ptr_uint = 0
    while i < count:
        let dp = analysis.diagnostics.get(i) else:
            break
        let d = unsafe: read(dp)
        target.append("\n  E ERROR   sema/error [Ln ")
        target.append_format(f"#{d.line}")
        target.append(", Col ")
        target.append_format(f"#{d.column}")
        target.append("]: ")
        target.append(d.message)
        i += 1


## `%3d`: right-aligned in `width`.
function append_left_aligned(target: ref[string.String], value: ptr_uint, width: ptr_uint) -> void:
    var digits: ptr_uint = 1
    var v = value
    while v >= 10:
        v /= 10
        digits += 1
    var pad = width
    while pad > digits:
        target.append(" ")
        pad -= 1
    target.append_format(f"#{value}")


## `%-Ns`: left-aligned in `width` (never truncating).
function append_right_padded(target: ref[string.String], value: str, width: ptr_uint) -> void:
    target.append(value)
    var pad = width
    while pad > value.len:
        target.append(" ")
        pad -= 1


function uint_to_str(value: ptr_uint) -> string.String:
    var text = string.String.create()
    text.append_format(f"#{value}")
    return text


public function handle_debug_info(ws: ref[workspace.Workspace], params: json.Value, id: json.Value) -> void:
    var text = build_debug_text(ws, debug_uri(params))
    defer: text.release()

    var result = json.create_object_value()
    let result_obj = result.as_object() else:
        proto.write_error(id, -32603, "debug info failed")
        return
    unsafe:
        read(result_obj).set("text", json.string_from_str(text.as_str()))
    proto.write_response(id, result)


## `params.textDocument.uri`, or "" when absent.
function debug_uri(params: json.Value) -> str:
    return proto.extract_text_doc_uri(params)
