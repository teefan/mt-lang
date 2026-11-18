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
import std.str
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
import mtc.parser.ast as ast
import mtc.parser.parser as parser
import mtc.parser.state as pstate
import mtc.semantic.analyzer as analyzer
import mtc.semantic.types as types


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

    # The semantic snapshot (the host's `get_tooling_snapshot`): the
    # loader-backed analysis the other requests share.  Its module name feeds
    # the AST section's `SourceFile` header, which the host's cached AST carries.
    let entry_opt = workspace.analysis_entry_for(ws, file_path.as_str())
    match entry_opt:
        Option.some as ep:
            var entry = unsafe: read(ep.value)
            debug_ast.append_ast_section(ref_of(text), file, entry.analysis.module_name, true)
            append_parse_errors(ref_of(text), ref_of(parse_diags))
            append_facts_section(ref_of(text), ref_of(entry.analysis))
            append_bindings_section(ref_of(text), ref_of(entry.analysis))
            append_diagnostics_text(ref_of(text), ref_of(entry.analysis))
        Option.none:
            debug_ast.append_ast_section(ref_of(text), file, "", true)
            append_parse_errors(ref_of(text), ref_of(parse_diags))
            text.append("\n\n── Diagnostics  (not available) ──")
    return text


## The CLI `debug` dump (`lib/milk_tea/tooling/cli/commands/debug.rb`): the same
## sections as the LSP request, with the CLI path's inputs and fallbacks.  The
## token table carries no semantic-class column (the host passes no semantic
## entries), and the snapshot — facts, bindings and diagnostics — is only built
## when the root parses cleanly; otherwise those sections print
## "(not available)", as the host's nil facts/snapshot do.  `display_path` is
## the host's `File.expand_path` rendering of the operand.
public function build_cli_debug_text(ws: ref[workspace.Workspace], path: str, display_path: str) -> string.String:
    var text = string.String.create()
    var content = ws.document_source(path) else:
        text.append("error: cannot read ")
        text.append(display_path)
        return text
    defer: content.release()
    let source = content.as_str()

    var lex_diags = vec.Vec[token_mod.LexDiagnostic].create()
    defer: lex_diags.release()
    var tokens = lexer_mod.lex_reporting(source, ref_of(lex_diags))
    defer: tokens.release()

    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer: parse_diags.release()
    var file = parser.parse_source(source, ref_of(parse_diags))

    append_header(ref_of(text), display_path, source, last_token_line(ref_of(tokens)))

    var classes = vec.Vec[semtok.SemanticClass].create()
    defer: classes.release()
    append_token_section(ref_of(text), source, ref_of(tokens), ref_of(classes))

    if parse_diags.len() == 0:
        let entry_opt = workspace.analysis_entry_for(ws, path)
        match entry_opt:
            Option.some as ep:
                var entry = unsafe: read(ep.value)
                debug_ast.append_ast_section(ref_of(text), file, entry.analysis.module_name, false)
                append_parse_errors(ref_of(text), ref_of(parse_diags))
                append_facts_section(ref_of(text), ref_of(entry.analysis))
                append_bindings_section(ref_of(text), ref_of(entry.analysis))
                append_diagnostics_text(ref_of(text), ref_of(entry.analysis))
                return text
            Option.none:
                pass

    debug_ast.append_ast_section(ref_of(text), file, "", false)
    append_parse_errors(ref_of(text), ref_of(parse_diags))
    text.append("\n\n── Facts  (not available) ──")
    text.append("\n\n── Bindings  (not available) ──")
    text.append("\n\n── Diagnostics  (not available) ──")
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


## ── Facts ────────────────────────────────────────────────────────────────────

## The host's `INSTALLABLE_BUILTIN_TYPE_NAMES` order — the `facts.types` block's
## first rows.
const FACTS_BUILTIN_TYPE_ORDER: array[str, 34] = array[str, 34](
    "bool", "byte", "ubyte", "char", "short", "ushort",
    "int", "uint", "long", "ulong", "ptr_int", "ptr_uint",
    "float", "double", "void", "str", "cstr",
    "vec2", "vec3", "vec4", "ivec2", "ivec3", "ivec4",
    "mat3", "mat4", "quat",
    "Subscription", "EventError",
    "struct_handle", "field_handle", "callable_handle", "attribute_handle",
    "member_handle", "type",
)


## `── Facts  module "<name>"  <summary>  ──…` plus the host's blocks
## (`DebugInfoFormatter.format_facts`): Types, Interfaces, Functions, Values,
## Methods, Imports and the trailing counters.
public function append_facts_section(target: ref[string.String], analysis: ref[analyzer.Analysis]) -> void:
    let type_count = analysis.types.len()
    let function_count = analysis.functions.len()
    let value_count = analysis.value_types.len()
    let method_set_count = facts_method_set_count(analysis)
    let interface_count = analysis.interface_order.len()
    let import_count = analysis.import_order.len()

    target.append("\n\n── Facts  module \"")
    target.append(analysis.module_name)
    target.append("\"  ")
    var wrote = false
    if type_count > 0:
        target.append_format(f"#{type_count} types")
        wrote = true
    if function_count > 0:
        if wrote:
            target.append(", ")
        target.append_format(f"#{function_count} functions")
        wrote = true
    if value_count > 0:
        if wrote:
            target.append(", ")
        target.append_format(f"#{value_count} values")
        wrote = true
    if method_set_count > 0:
        if wrote:
            target.append(", ")
        target.append_format(f"#{method_set_count} method_sets")
        wrote = true
    if interface_count > 0:
        if wrote:
            target.append(", ")
        target.append_format(f"#{interface_count} interfaces")
        wrote = true
    if import_count > 0:
        if wrote:
            target.append(", ")
        target.append_format(f"#{import_count} imports")
        wrote = true
    if not wrote:
        target.append("empty")
    target.append("  ")
    debug_text.append_rule(target, 50)

    append_facts_types(target, analysis)
    append_facts_interfaces(target, analysis)
    append_facts_functions(target, analysis)
    append_facts_values(target, analysis)
    append_facts_methods(target, analysis)
    append_facts_imports(target, analysis)
    append_facts_trailer(target, analysis)


function append_rule_seen(seen: ref[vec.Vec[str]], name: str) -> void:
    seen.push(name)


function facts_contains(seen: ref[vec.Vec[str]], name: str) -> bool:
    var i: ptr_uint = 0
    while i < seen.len():
        let p = seen.get(i) else:
            break
        unsafe:
            if read(p) == name:
                return true
        i += 1
    return false


function append_facts_types(target: ref[string.String], analysis: ref[analyzer.Analysis]) -> void:
    if analysis.types.len() == 0:
        return
    target.append("\n\n  Types:")
    var seen = vec.Vec[str].create()
    defer: seen.release()

    var i: ptr_uint = 0
    while i < 34:
        let name = FACTS_BUILTIN_TYPE_ORDER[i]
        if analysis.types.contains(name):
            append_facts_type_row(target, analysis, name)
            append_rule_seen(ref_of(seen), name)
        i += 1
    if analysis.types.contains("Option"):
        append_facts_type_row(target, analysis, "Option")
        append_rule_seen(ref_of(seen), "Option")
    if analysis.types.contains("Result"):
        append_facts_type_row(target, analysis, "Result")
        append_rule_seen(ref_of(seen), "Result")

    var mi: ptr_uint = 0
    while mi < analysis.module_type_order.len():
        let np = analysis.module_type_order.get(mi) else:
            break
        let name = unsafe: read(np)
        if analysis.types.contains(name) and not facts_contains(ref_of(seen), name):
            append_facts_type_row(target, analysis, name)
            append_rule_seen(ref_of(seen), name)
        mi += 1

    var entries = analysis.types.entries()
    while entries.next():
        let entry = entries.current()
        let name = unsafe: read(entry.key)
        if not facts_contains(ref_of(seen), name):
            append_facts_type_row(target, analysis, name)
            append_rule_seen(ref_of(seen), name)


function append_facts_type_row(target: ref[string.String], analysis: ref[analyzer.Analysis], name: str) -> void:
    let ty = analysis.types.get(name) else:
        return
    target.append("\n    ")
    append_right_padded(target, name, 20)
    target.append(" → ")
    target.append(facts_type_repr(analysis, name, unsafe: read(ty)))


## The prelude types print their owning module (`std.option.Option`); the
## analyzer's prelude registration is module-less, so the dump supplies it.
function facts_type_repr(analysis: ref[analyzer.Analysis], name: str, t: types.Type) -> str:
    match t:
        types.Type.ty_named as n:
            if n.module_name.len == 0:
                if name == "Option":
                    return "std.option.Option"
                if name == "Result":
                    return "std.result.Result"
        _:
            pass
    return binding_type_repr(analysis, t)


function append_facts_interfaces(target: ref[string.String], analysis: ref[analyzer.Analysis]) -> void:
    if analysis.interface_order.len() == 0:
        return
    target.append("\n\n  Interfaces:")
    var i: ptr_uint = 0
    while i < analysis.interface_order.len():
        let np = analysis.interface_order.get(i) else:
            break
        let name = unsafe: read(np)
        let mp = analysis.interfaces.get(name)
        if mp != null:
            target.append("\n    ")
            target.append(name)
            target.append("  [methods: ")
            let methods = unsafe: read(mp)
            var mi: ptr_uint = 0
            while mi < methods.len:
                if mi > 0:
                    target.append(", ")
                target.append(unsafe: read(methods.data + mi).name)
                mi += 1
            target.append("]")
        i += 1


function append_facts_functions(target: ref[string.String], analysis: ref[analyzer.Analysis]) -> void:
    if analysis.functions.len() == 0:
        return
    target.append("\n\n  Functions:")
    var seen = vec.Vec[str].create()
    defer: seen.release()
    facts_function_decls(target, analysis, ref_of(seen), analysis.source_file.declarations)
    facts_function_decls(target, analysis, ref_of(seen), analysis.when_declarations)


function facts_function_decls(target: ref[string.String], analysis: ref[analyzer.Analysis], seen: ref[vec.Vec[str]], decls: span[ast.Decl]) -> void:
    var i: ptr_uint = 0
    while i < decls.len:
        var d: ast.Decl
        unsafe:
            d = read(decls.data + i)
        let node = unsafe: reinterpret[ptr_uint](decls.data + i)
        match d:
            ast.Decl.decl_function as fun:
                if analysis.functions.contains(fun.name) and not facts_contains(seen, fun.name):
                    let sig = analysis.functions.get(fun.name)
                    if sig != null:
                        append_facts_callable(target, analysis, fun.name, sig, node, "FunctionDef", fun.line, fun.column, "    ", fun.name, true, fun.is_const, false, false, fun.type_params, span[ast.TypeRef](), 0z, types.Type.ty_error, false)
                    append_rule_seen(seen, fun.name)
            ast.Decl.decl_extern_function as ef:
                if analysis.functions.contains(ef.name) and not facts_contains(seen, ef.name):
                    let sig = analysis.functions.get(ef.name)
                    if sig != null:
                        append_facts_callable(target, analysis, ef.name, sig, node, "ExternFunctionDecl", ef.line, 0z, "    ", ef.name, false, false, true, false, ef.type_params, span[ast.TypeRef](), 0z, types.Type.ty_error, false)
                    append_rule_seen(seen, ef.name)
            ast.Decl.decl_foreign_function as ff:
                if analysis.functions.contains(ff.name) and not facts_contains(seen, ff.name):
                    let sig = analysis.functions.get(ff.name)
                    if sig != null:
                        append_facts_callable(target, analysis, ff.name, sig, node, "ForeignFunctionDecl", ff.line, 0z, "    ", ff.name, false, false, false, false, ff.type_params, span[ast.TypeRef](), 0z, types.Type.ty_error, false)
                    append_rule_seen(seen, ff.name)
            _:
                pass
        i += 1


## One function/method binding block: the host's `format_function_binding`.
## `display_name` is the hash key (methods render `static:<name>` for statics),
## `type_name` the `fn <…>` name, `indent` the member indent.
function append_facts_callable(
    target: ref[string.String],
    analysis: ref[analyzer.Analysis],
    display_name: str,
    sig: ptr[analyzer.FnSig],
    node: ptr_uint,
    kind: str,
    line: ptr_uint,
    column: ptr_uint,
    indent: str,
    type_name: str,
    show_const: bool,
    is_const: bool,
    is_external: bool,
    has_this: bool,
    own_type_params: span[ast.TypeParam],
    receiver_type_params: span[ast.TypeRef],
    this_id: ptr_uint,
    this_ty: types.Type,
    this_mutable: bool,
) -> void:
    let s = unsafe: read(sig)
    target.append("\n")
    target.append(indent)
    target.append(display_name)
    target.append("\n")
    target.append(indent)
    target.append("  type: fn ")
    target.append(type_name)
    let param_count = s.params.len + (if has_this: 1 else: 0)
    if param_count > 0:
        target.append("\n")
        target.append(indent)
        target.append("  params (")
        target.append_format(f"#{param_count}")
        target.append("):")
        if has_this:
            target.append("\n")
            target.append(indent)
            target.append("    ")
            append_facts_value_binding(target, analysis, this_id, this_mutable, "param", "this", this_ty)
        let base = facts_param_base(analysis, node)
        var pi: ptr_uint = 0
        while pi < s.params.len:
            let p = unsafe: read(s.params.data + pi)
            target.append("\n")
            target.append(indent)
            target.append("    ")
            append_facts_value_binding(target, analysis, base + pi, false, "param", p.name, p.ty)
            pi += 1
    target.append("\n")
    target.append(indent)
    target.append("  return_type: ")
    target.append(binding_type_repr(analysis, facts_body_return(s)))
    target.append("\n")
    target.append(indent)
    target.append("  external: ")
    append_bool_text(target, is_external)
    target.append("\n")
    target.append(indent)
    target.append("  async: ")
    append_bool_text(target, s.is_async)
    if show_const:
        target.append("\n")
        target.append(indent)
        target.append("  const: ")
        append_bool_text(target, is_const)
    target.append("\n")
    target.append(indent)
    target.append("  ast: ")
    var header = debug_ast.ast_header_text(kind, true, type_name_name_part(display_name), line, column)
    defer: header.release()
    target.append(header.as_str())
    let type_param_count = receiver_type_params.len + own_type_params.len
    if type_param_count > 0:
        target.append("\n")
        target.append(indent)
        target.append("  type_params (")
        target.append_format(f"#{type_param_count}")
        target.append("):")
        var ri: ptr_uint = 0
        while ri < receiver_type_params.len:
            target.append("\n")
            target.append(indent)
            target.append("    ")
            append_quoted_name(target, type_ref_leaf_name(unsafe: read(receiver_type_params.data + ri)))
            ri += 1
        var ti: ptr_uint = 0
        while ti < own_type_params.len:
            target.append("\n")
            target.append(indent)
            target.append("    ")
            append_quoted_name(target, unsafe: read(own_type_params.data + ti).name)
            ti += 1


## The AST header's name for a method key (`static:sum` -> `sum`).
function type_name_name_part(display_name: str) -> str:
    if display_name.len >= 7 and display_name.slice(0, 7) == "static:":
        return display_name.slice(7, display_name.len - 7)
    return display_name


function type_ref_leaf_name(r: ast.TypeRef) -> str:
    if r.name.parts.len == 0:
        return ""
    return unsafe: read(r.name.parts.data + (r.name.parts.len - 1))


function append_quoted_name(target: ref[string.String], name: str) -> void:
    var repr = debug_text.ruby_inspect(name)
    defer: repr.release()
    target.append(repr.as_str())


function append_bool_text(target: ref[string.String], value: bool) -> void:
    if value:
        target.append("true")
    else:
        target.append("false")


function facts_param_base(analysis: ref[analyzer.Analysis], node: ptr_uint) -> ptr_uint:
    let base = analysis.param_id_base.get(node)
    if base != null:
        return unsafe: read(base)
    return 0


## The `return_type:` a binding prints: the declared return, with an async
## signature's `Task[T]` wrapper unwrapped (the host's `body_return_type`).
function facts_body_return(s: analyzer.FnSig) -> types.Type:
    match s.return_type:
        types.Type.ty_generic as g:
            if s.is_async and g.name.equal("Task") and g.args.len == 1:
                return unsafe: read(g.args.data + 0)
        _:
            pass
    return s.return_type


function append_facts_value_binding(target: ref[string.String], analysis: ref[analyzer.Analysis], id: ptr_uint, mutable: bool, kind: str, name: str, ty: types.Type) -> void:
    target.append("ValueBinding[id: ")
    target.append_format(f"#{id}")
    target.append("] ")
    if mutable:
        target.append("mut")
    else:
        target.append("  ")
    target.append(" ")
    target.append(kind)
    var pad: ptr_uint = 0
    if kind.len < 6:
        pad = 6 - kind.len
    while pad > 0:
        target.append(" ")
        pad -= 1
    target.append(" ")
    target.append(name)
    target.append(": ")
    target.append(binding_type_repr(analysis, ty))


function facts_value_id(analysis: ref[analyzer.Analysis], name: str) -> ptr_uint:
    let id = analysis.value_binding_ids.get(name)
    if id != null:
        return unsafe: read(id)
    return 0


function append_facts_values(target: ref[string.String], analysis: ref[analyzer.Analysis]) -> void:
    if analysis.value_types.len() == 0:
        return
    target.append("\n\n  Values:")
    var seen = vec.Vec[str].create()
    defer: seen.release()
    facts_value_decls(target, analysis, ref_of(seen), analysis.source_file.declarations)
    facts_value_decls(target, analysis, ref_of(seen), analysis.when_declarations)


function facts_value_decls(target: ref[string.String], analysis: ref[analyzer.Analysis], seen: ref[vec.Vec[str]], decls: span[ast.Decl]) -> void:
    var i: ptr_uint = 0
    while i < decls.len:
        var d: ast.Decl
        unsafe:
            d = read(decls.data + i)
        match d:
            ast.Decl.decl_const as c:
                if analysis.value_types.contains(c.name) and not facts_contains(seen, c.name):
                    append_facts_value_row(target, analysis, c.name, false, "const")
                    append_rule_seen(seen, c.name)
            ast.Decl.decl_var as v:
                if analysis.value_types.contains(v.name) and not facts_contains(seen, v.name):
                    append_facts_value_row(target, analysis, v.name, true, "var")
                    append_rule_seen(seen, v.name)
            ast.Decl.decl_event as ev:
                if analysis.value_types.contains(ev.name) and not facts_contains(seen, ev.name):
                    append_facts_value_row(target, analysis, ev.name, false, "event")
                    append_rule_seen(seen, ev.name)
            _:
                pass
        i += 1


function append_facts_value_row(target: ref[string.String], analysis: ref[analyzer.Analysis], name: str, mutable: bool, kind: str) -> void:
    let ty = analysis.value_types.get(name) else:
        return
    target.append("\n    ")
    append_right_padded(target, name, 20)
    target.append(" → ")
    append_facts_value_binding(target, analysis, facts_value_id(analysis, name), mutable, kind, name, unsafe: read(ty))


## The host's `facts.methods` shape: one `on <receiver>:` group per first-seen
## receiver type, the methods in registration order.  The receiver list comes
## from this file's extending blocks, so a prelude-only `method_sigs` entry
## (std.option/std.result methods) does not open an empty block the way the
## host's facts never would.
function append_facts_methods(target: ref[string.String], analysis: ref[analyzer.Analysis]) -> void:
    var receivers = vec.Vec[str].create()
    defer: receivers.release()
    facts_collect_receivers(analysis, ref_of(receivers), analysis.source_file.declarations)
    facts_collect_receivers(analysis, ref_of(receivers), analysis.when_declarations)
    if receivers.len() == 0:
        return
    target.append("\n\n  Methods:")
    var ri: ptr_uint = 0
    while ri < receivers.len():
        let rp = receivers.get(ri) else:
            break
        let receiver = unsafe: read(rp)
        target.append("\n    on ")
        target.append(receiver)
        target.append(":")
        facts_emit_receiver_methods(target, analysis, receiver, analysis.source_file.declarations)
        facts_emit_receiver_methods(target, analysis, receiver, analysis.when_declarations)
        ri += 1


function facts_method_receiver_string(analysis: ref[analyzer.Analysis], base: str, method_name: str) -> str:
    let ty = analysis.method_receiver_types.get(analyzer.method_key(base, method_name))
    if ty != null:
        return debug_type_repr(unsafe: read(ty))
    return base


function facts_collect_receivers(analysis: ref[analyzer.Analysis], receivers: ref[vec.Vec[str]], decls: span[ast.Decl]) -> void:
    var i: ptr_uint = 0
    while i < decls.len:
        var d: ast.Decl
        unsafe:
            d = read(decls.data + i)
        match d:
            ast.Decl.decl_extending_block as ex:
                var base: str = ""
                unsafe:
                    base = analyzer.qname_to_str(read(ex.type_name).name)
                var j: ptr_uint = 0
                while j < ex.methods.len:
                    var m: ast.Method = unsafe: read(ex.methods.data + j)
                    let receiver = facts_method_receiver_string(analysis, base, m.name)
                    if not facts_contains(receivers, receiver):
                        receivers.push(receiver)
                    j += 1
            _:
                pass
        i += 1


function facts_emit_receiver_methods(target: ref[string.String], analysis: ref[analyzer.Analysis], receiver: str, decls: span[ast.Decl]) -> void:
    var i: ptr_uint = 0
    while i < decls.len:
        var d: ast.Decl
        unsafe:
            d = read(decls.data + i)
        match d:
            ast.Decl.decl_extending_block as ex:
                var base: str = ""
                unsafe:
                    base = analyzer.qname_to_str(read(ex.type_name).name)
                var j: ptr_uint = 0
                while j < ex.methods.len:
                    var m: ast.Method = unsafe: read(ex.methods.data + j)
                    if facts_method_receiver_string(analysis, base, m.name) == receiver:
                        emit_one_method(target, analysis, ex.type_name, base, m, unsafe: reinterpret[ptr_uint](ex.methods.data + j))
                    j += 1
            _:
                pass
        i += 1


function emit_one_method(target: ref[string.String], analysis: ref[analyzer.Analysis], target_type: ptr[ast.TypeRef], base: str, m: ast.Method, node: ptr_uint) -> void:
    let key = analyzer.method_key(base, m.name)
    let sig = analysis.method_sigs.get(key) else:
        return
    let receiver_ty = analysis.method_receiver_types.get(key)
    var this_ty: types.Type = types.Type.ty_error
    if receiver_ty != null:
        this_ty = unsafe: read(receiver_ty)
    var display_name = m.name
    if m.method_kind == ast.MethodKind.mk_static:
        display_name = static_method_display_name(m.name)
    var type_name = string.String.create()
    defer: type_name.release()
    type_name.append(debug_type_repr(this_ty))
    type_name.append(".")
    type_name.append(m.name)
    let this_id = facts_this_id(analysis, node)
    let has_this = m.method_kind != ast.MethodKind.mk_static
    append_facts_callable(target, analysis, display_name, sig, node, "MethodDef", m.line, m.column, "      ", type_name.as_str(), true, m.is_const, false, has_this, m.type_params, unsafe: read(target_type).arguments, this_id, this_ty, m.method_kind == ast.MethodKind.mk_editable)


function static_method_display_name(name: str) -> str:
    var buf = string.String.create()
    buf.append("static:")
    buf.append(name)
    return buf.as_str()


function facts_this_id(analysis: ref[analyzer.Analysis], node: ptr_uint) -> ptr_uint:
    let id = analysis.this_binding_ids.get(node)
    if id != null:
        return unsafe: read(id)
    return 0


function append_facts_imports(target: ref[string.String], analysis: ref[analyzer.Analysis]) -> void:
    if analysis.import_order.len() == 0:
        return
    target.append("\n\n  Imports:")
    var i: ptr_uint = 0
    while i < analysis.import_order.len():
        let np = analysis.import_order.get(i) else:
            break
        let name = unsafe: read(np)
        var count: ptr_uint = 0
        let cp = analysis.import_symbol_counts.get(name)
        if cp != null:
            count = unsafe: read(cp)
        target.append("\n    ")
        append_right_padded(target, name, 24)
        target.append(" → ModuleBinding (exported symbols: ")
        target.append_format(f"#{count}")
        target.append(")")
        i += 1


## The host's trailing counters: one frame per checked function/method body
## (foreign functions included, externals excluded), the callable-value site
## counts and the required-unsafe lines as a Ruby array.
function append_facts_trailer(target: ref[string.String], analysis: ref[analyzer.Analysis]) -> void:
    target.append("\n\n  local_completion_frames: ")
    target.append_format(f"#{facts_local_completion_frames(analysis)}")
    target.append("\n  callable_value_identifier_sites: ")
    target.append_format(f"#{analysis.callable_value_sites.len()}")
    target.append("\n  callable_value_member_access_sites: 0")
    target.append("\n  required_unsafe_lines: [")
    var i: ptr_uint = 0
    while i < analysis.unsafe_statement_lines.len():
        if i > 0:
            target.append(", ")
        let lp = analysis.unsafe_statement_lines.get(i) else:
            break
        target.append_format(f"#{unsafe: read(lp)}")
        i += 1
    target.append("]")


function facts_local_completion_frames(analysis: ref[analyzer.Analysis]) -> ptr_uint:
    var count: ptr_uint = 0
    count += facts_frame_count(analysis.source_file.declarations)
    count += facts_frame_count(analysis.when_declarations)
    return count


function facts_frame_count(decls: span[ast.Decl]) -> ptr_uint:
    var count: ptr_uint = 0
    var i: ptr_uint = 0
    while i < decls.len:
        var d: ast.Decl
        unsafe:
            d = read(decls.data + i)
        match d:
            ast.Decl.decl_function:
                count += 1
            ast.Decl.decl_foreign_function:
                count += 1
            ast.Decl.decl_extending_block as ex:
                count += ex.methods.len
            _:
                pass
        i += 1
    return count


## The host's method-set count: distinct receiver types among the methods.
function facts_method_set_count(analysis: ref[analyzer.Analysis]) -> ptr_uint:
    var receivers = vec.Vec[str].create()
    defer: receivers.release()
    facts_collect_receivers(analysis, ref_of(receivers), analysis.source_file.declarations)
    facts_collect_receivers(analysis, ref_of(receivers), analysis.when_declarations)
    return receivers.len()


## `── Bindings  <summary>  ──…` plus the three blocks the host's
## `DebugInfoFormatter.format_bindings` renders: identifier uses → binding id
## (first 30), declaration nodes → binding id (first 30), and every binding's
## type in id order.  The `obj <n>` values are the host's Ruby object ids on its
## side and node keys here; the harness normalizes them away, so only the order
## and the binding ids compare.
function append_bindings_section(target: ref[string.String], analysis: ref[analyzer.Analysis]) -> void:
    let ident_count = analysis.identifier_sites.len()
    let decl_count = analysis.declaration_sites.len()
    let type_count = analysis.binding_types.len()

    target.append("\n\n── Bindings  ")
    var wrote = false
    if ident_count > 0:
        target.append_format(f"#{ident_count} ident→id")
        wrote = true
    if decl_count > 0:
        if wrote:
            target.append(", ")
        target.append_format(f"#{decl_count} decl→id")
        wrote = true
    if type_count > 0:
        if wrote:
            target.append(", ")
        target.append_format(f"#{type_count} id→type")
        wrote = true
    if not wrote:
        target.append("empty")
    target.append("  ")
    debug_text.append_rule(target, 60)

    if ident_count > 0:
        target.append("\n  identifier_binding_ids (")
        target.append_format(f"#{ident_count}")
        target.append("):")
        append_binding_site_rows(target, analysis, true)
        if ident_count > 30:
            target.append("\n    ... (")
            target.append_format(f"#{ident_count - 30}")
            target.append(" more)")

    if decl_count > 0:
        target.append("\n  declaration_binding_ids (")
        target.append_format(f"#{decl_count}")
        target.append("):")
        append_binding_site_rows(target, analysis, false)
        if decl_count > 30:
            target.append("\n    ... (")
            target.append_format(f"#{decl_count - 30}")
            target.append(" more)")

    if type_count > 0:
        target.append("\n  binding_types (")
        target.append_format(f"#{type_count}")
        target.append("):")
        var i: ptr_uint = 0
        while i < type_count:
            let ep = analysis.binding_types.get(i) else:
                break
            let e = unsafe: read(ep)
            target.append("\n    binding_id: ")
            target.append_format(f"#{e.id}")
            target.append(" → ")
            target.append(binding_type_repr(analysis, e.ty))
            i += 1


## The `obj <node> → binding_id: <id>` rows of one site list, capped at 30 like
## the host's `.take(30)`.
function append_binding_site_rows(target: ref[string.String], analysis: ref[analyzer.Analysis], identifiers: bool) -> void:
    var i: ptr_uint = 0
    if identifiers:
        while i < 30 and i < analysis.identifier_sites.len():
            let sp = analysis.identifier_sites.get(i) else:
                break
            append_binding_site_row(target, unsafe: read(sp))
            i += 1
    else:
        while i < 30 and i < analysis.declaration_sites.len():
            let sp = analysis.declaration_sites.get(i) else:
                break
            append_binding_site_row(target, unsafe: read(sp))
            i += 1


function append_binding_site_row(target: ref[string.String], site: analyzer.BindingSite) -> void:
    target.append("\n    obj ")
    target.append_format(f"#{site.node}")
    target.append(" → binding_id: ")
    target.append_format(f"#{site.id}")


## The host's `Types::*#to_s` for a binding type: a named or imported type
## qualifies with its module (`main.Sample`, `std.option.Option`) where the
## analyzer's `type_to_string` keeps the short name; everything else defers to
## `type_to_string`.
public function debug_type_repr(t: types.Type) -> str:
    match t:
        types.Type.ty_named as n:
            if n.module_name.len > 0:
                var buf = string.String.create()
                buf.append(n.module_name)
                buf.append(".")
                buf.append(n.name)
                return buf.as_str()
            return n.name
        types.Type.ty_imported as im:
            if im.module_name.len > 0:
                var buf = string.String.create()
                buf.append(im.module_name)
                buf.append(".")
                buf.append(im.name)
                if im.args.len > 0:
                    buf.append("[")
                    var i: ptr_uint = 0
                    while i < im.args.len:
                        if i > 0:
                            buf.append(", ")
                        buf.append(debug_type_repr(unsafe: read(im.args.data + i)))
                        i += 1
                    buf.append("]")
                return buf.as_str()
            return types.type_to_string(t)
        _:
            return types.type_to_string(t)


## A binding type as the module's declared types render it: a named type
## without a module (`Sample`, recorded by the construction or annotation path
## without one) takes the declared type's own rendering (`main.Sample`), and the
## resolution recurses through a nullable base and through generic/imported
## arguments, so the dump reads like the host's facts, whose types always carry
## their module (`main.Sample?`, `std.option.Option[main.Sample]`).  The prelude
## variants render under their owning modules, as the host's do.
function binding_type_repr(analysis: ref[analyzer.Analysis], t: types.Type) -> str:
    var text = string.String.create()
    append_binding_type_repr(ref_of(text), analysis, t)
    return text.as_str()


function append_binding_type_repr(target: ref[string.String], analysis: ref[analyzer.Analysis], t: types.Type) -> void:
    match t:
        types.Type.ty_named as n:
            if n.module_name.len > 0:
                target.append(n.module_name)
                target.append(".")
                target.append(n.name)
                return
            if n.name.equal("Option"):
                target.append("std.option.Option")
                return
            if n.name.equal("Result"):
                target.append("std.result.Result")
                return
            let declared = analysis.types.get(n.name)
            if declared != null:
                # An alias resolves through its target; a bare declaration of
                # the same name (`module_name` empty) has no better spelling
                # and must not recurse.
                match unsafe: read(declared):
                    types.Type.ty_named as dn:
                        if dn.module_name.len > 0:
                            target.append(dn.module_name)
                            target.append(".")
                            target.append(dn.name)
                            return
                    _:
                        append_binding_type_repr(target, analysis, unsafe: read(declared))
                        return
            target.append(n.name)
        types.Type.ty_nullable as nl:
            append_binding_type_repr(target, analysis, unsafe: read(nl.base))
            target.append("?")
        types.Type.ty_imported as im:
            append_binding_type_name(target, analysis, im.module_name, im.name)
            append_binding_type_args(target, analysis, im.args)
        types.Type.ty_generic as g:
            append_binding_type_name(target, analysis, "", g.name)
            append_binding_type_args(target, analysis, g.args)
        _:
            target.append(types.type_to_string(t))


## A type name with its owning module: the recorded module when present, else
## the declared type's, with the prelude variants under `std.option` /
## `std.result` (the host's `Types::Variant#to_s`).
function append_binding_type_name(target: ref[string.String], analysis: ref[analyzer.Analysis], module_name: str, name: str) -> void:
    if module_name.len > 0:
        target.append(module_name)
        target.append(".")
        target.append(name)
        return
    if name.equal("Option"):
        target.append("std.option.Option")
        return
    if name.equal("Result"):
        target.append("std.result.Result")
        return
    let declared = analysis.types.get(name)
    if declared != null:
        match unsafe: read(declared):
            types.Type.ty_named as dn:
                if dn.module_name.len > 0:
                    target.append(dn.module_name)
                    target.append(".")
                    target.append(name)
                    return
            _:
                pass
    target.append(name)


function append_binding_type_args(target: ref[string.String], analysis: ref[analyzer.Analysis], args: span[types.Type]) -> void:
    if args.len == 0:
        return
    target.append("[")
    var i: ptr_uint = 0
    while i < args.len:
        if i > 0:
            target.append(", ")
        append_binding_type_repr(target, analysis, unsafe: read(args.data + i))
        i += 1
    target.append("]")


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
