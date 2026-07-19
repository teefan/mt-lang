## Auto-fix engine — applies safe rewrites for a fixable subset of lint
## rules, following the Ruby linter's FixEngine multi-pass design: each pass
## isolates one rule at a time (fixes re-lint from fresh source, so edits
## from one rule can never corrupt another rule's positions), and passes
## repeat until a fixpoint or the pass limit.
##
## Fixable rules:
##   prefer-let                `var` never reassigned            → `let`
##   redundant-return          final bare `return` in void body  → delete line
##   redundant-else            else after all-return branches    → dedent body
##   trailing-list-comma       comma before a call's `)`         → delete comma
##   redundant-cast            `int<-x` where x: int             → drop `int<-`
##   redundant-bool-compare    `x == true` and friends           → `x` / `not x`
##   redundant-type-annotation `let x: int = 1`                  → drop `: int`
##   redundant-ignored-match-binding  `as _` in match arm        → delete ` as _`
##   prefer-let-else           `let x = v; if x == null: ...`    → `let x = v else: ...`
##   prefer-var-else           `var x = v; if x == null: ...`    → `var x = v else: ...`
##
## `unused-import` is intentionally NOT auto-fixable, matching Ruby: removing
## an import has non-local effects per-file linting cannot see (it may drop
## extension methods or the canonical `hash[T]`/`equal[T]`/`order[T]` hooks).

import std.str
import std.string as string
import std.vec as vec

import mtc.parser.parser as parser
import mtc.parser.state as pstate
import mtc.linter.linter as linter


const MAX_PASSES: ptr_uint = 5
const MAX_RULE_ITERATIONS: ptr_uint = 10


## The fixable rule codes, in application order.
function fixable_codes() -> vec.Vec[str]:
    var codes = vec.Vec[str].create()
    codes.push("prefer-let")
    codes.push("redundant-return")
    codes.push("redundant-else")
    codes.push("trailing-list-comma")
    codes.push("redundant-cast")
    codes.push("redundant-bool-compare")
    codes.push("redundant-type-annotation")
    codes.push("prefer-let-else")
    codes.push("prefer-var-else")
    return codes


## True when `code` has a fix generator.
public function is_fixable(code: str) -> bool:
    var codes = fixable_codes()
    defer codes.release()
    var i: ptr_uint = 0
    while i < codes.len():
        let cp = codes.get(i) else:
            break
        unsafe:
            if read(cp).equal(code):
                return true
        i += 1
    return false


## Apply every enabled fixable rule to `source` until nothing changes.
## `select` (empty = all) and `ignore` filter rule codes exactly like the
## lint command's flags.  Returns the fixed source, which equals the input
## when nothing was fixable.
public function fix_source(
    source: str,
    path: str,
    owning_type_names: span[str],
    select: ref[vec.Vec[str]],
    ignore: ref[vec.Vec[str]],
) -> string.String:
    var current = string.String.from_str(source)

    var codes = fixable_codes()
    defer codes.release()

    var pass_index: ptr_uint = 0
    while pass_index < MAX_PASSES:
        var changed_in_pass = false
        var ci: ptr_uint = 0
        while ci < codes.len():
            let code_ptr = codes.get(ci) else:
                break
            let code = unsafe: read(code_ptr)
            if rule_enabled(code, select, ignore):
                if fix_rule_to_fixpoint(ref_of(current), code, path, owning_type_names):
                    changed_in_pass = true
            ci += 1
        if not changed_in_pass:
            break
        pass_index += 1

    return current


function rule_enabled(code: str, select: ref[vec.Vec[str]], ignore: ref[vec.Vec[str]]) -> bool:
    if select.len() > 0 and not code_in(code, select):
        return false
    return not code_in(code, ignore)


function code_in(code: str, codes: ref[vec.Vec[str]]) -> bool:
    var i: ptr_uint = 0
    while i < codes.len():
        let cp = codes.get(i) else:
            break
        unsafe:
            if read(cp).equal(code):
                return true
        i += 1
    return false


## Re-lint and fix one rule until its warnings stop changing the source.
## Returns true when any edit was applied.
function fix_rule_to_fixpoint(current: ref[string.String], code: str, path: str, owning_type_names: span[str]) -> bool:
    var changed = false
    var iteration: ptr_uint = 0
    while iteration < MAX_RULE_ITERATIONS:
        var updated = fix_rule_single_pass(current.as_str(), code, path, owning_type_names)
        if updated.as_str() == current.as_str():
            updated.release()
            break
        current.release()
        read(current) = updated
        changed = true
        iteration += 1
    return changed


## One lint-and-apply cycle for a single rule.
function fix_rule_single_pass(source: str, code: str, path: str, owning_type_names: span[str]) -> string.String:
    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer parse_diags.release()
    let file = parser.parse_source(source, ref_of(parse_diags))
    if parse_diags.len() > 0:
        # Never rewrite a file that does not parse.
        return string.String.from_str(source)

    var warnings = linter.lint_source(file, source, path, owning_type_names)
    defer warnings.release()

    var rule_warnings = vec.Vec[linter.Warning].create()
    defer rule_warnings.release()
    var wi: ptr_uint = 0
    while wi < warnings.len():
        let wp = warnings.get(wi) else:
            break
        unsafe:
            if read(wp).code.equal(code):
                rule_warnings.push(read(wp))
        wi += 1

    if rule_warnings.len() == 0:
        return string.String.from_str(source)

    sort_warnings_descending(ref_of(rule_warnings))

    var lines = split_lines(source)
    defer release_lines(ref_of(lines))

    var ri: ptr_uint = 0
    while ri < rule_warnings.len():
        let wp = rule_warnings.get(ri) else:
            break
        let w = unsafe: read(wp)
        match edits_for_warning(ref_of(lines), code, w.line, w.column):
            Option.some as edit:
                apply_edit(ref_of(lines), edit.value)
            Option.none:
                pass
        ri += 1

    return join_lines(ref_of(lines))


## Sort warnings by (line, column) descending so edits below never shift the
## positions of edits above.
function sort_warnings_descending(warnings: ref[vec.Vec[linter.Warning]]) -> void:
    let count = warnings.len()
    var i: ptr_uint = 1
    while i < count:
        var j = i
        while j > 0:
            let prev = warnings.get(j - 1) else:
                break
            let curr = warnings.get(j) else:
                break
            unsafe:
                let a = read(prev)
                let b = read(curr)
                if a.line > b.line or (a.line == b.line and a.column >= b.column):
                    break
            warnings.swap(j - 1, j)
            j -= 1
        i += 1


## A single source rewrite.  `end_line == start_line` is an in-line edit of
## the character range [start_char, end_char); `end_line > start_line`
## replaces whole lines [start_line, end_line) with `new_text` (split on
## newlines; empty text deletes the lines).  Lines are 0-based.
public struct FixEdit:
    start_line: ptr_uint
    start_char: ptr_uint
    end_line: ptr_uint
    end_char: ptr_uint
    new_text: string.String


## The fix edit for one warning, or none when the rule has no generator or
## the surrounding source no longer matches.  Also used by the LSP's code
## actions through `lsp_edit_for_warning`.
public function edits_for_warning(
    lines: ref[vec.Vec[string.String]],
    code: str,
    line: ptr_uint,
    column: ptr_uint,
) -> Option[FixEdit]:
    if line == 0:
        return Option[FixEdit].none
    let line_index = line - 1
    if line_index >= lines.len():
        return Option[FixEdit].none

    if code.equal("prefer-let"):
        return prefer_let_edit(lines, line_index)
    if code.equal("redundant-return"):
        return redundant_return_edit(lines, line_index)
    if code.equal("redundant-else"):
        return redundant_else_edit(lines, line_index)
    if code.equal("trailing-list-comma"):
        return trailing_comma_edit(lines, line_index, column)
    if code.equal("redundant-cast"):
        return redundant_cast_edit(lines, line_index, column)
    if code.equal("redundant-bool-compare"):
        return redundant_bool_compare_edit(lines, line_index)
    if code.equal("redundant-type-annotation"):
        return redundant_type_annotation_edit(lines, line_index)
    # redundant-ignored-match-binding: detection has unreliable line positions
    if code.equal("prefer-let-else"):
        return prefer_let_else_edit(lines, line_index, true)
    if code.equal("prefer-var-else"):
        return prefer_let_else_edit(lines, line_index, false)
    return Option[FixEdit].none


## Apply one edit to the line buffer.
public function apply_edit(lines: ref[vec.Vec[string.String]], edit: FixEdit) -> void:
    var owned = edit
    if owned.start_line == owned.end_line:
        let text = line_text(lines, owned.start_line)
        if owned.start_char > text.len or owned.end_char > text.len or owned.end_char < owned.start_char:
            owned.new_text.release()
            return
        var rebuilt = string.String.from_str(text.slice(0, owned.start_char))
        rebuilt.append(owned.new_text.as_str())
        rebuilt.append(text.slice(owned.end_char, text.len - owned.end_char))
        set_line(lines, owned.start_line, rebuilt)
        owned.new_text.release()
        return

    # Whole-line replacement: delete [start_line, end_line), then insert the
    # replacement lines at start_line.
    var remove_count = owned.end_line - owned.start_line
    while remove_count > 0:
        if owned.start_line >= lines.len():
            break
        remove_line(lines, owned.start_line)
        remove_count -= 1
    if owned.new_text.len() > 0:
        insert_lines_at(lines, owned.start_line, owned.new_text.as_str())
    owned.new_text.release()


## Insert `text` (split on newlines) as new lines starting at `index`.
function insert_lines_at(lines: ref[vec.Vec[string.String]], index: ptr_uint, text: str) -> void:
    var insert_at = index
    var start: ptr_uint = 0
    var i: ptr_uint = 0
    while i <= text.len:
        if i == text.len or text.byte_at(i) == 10:
            if not lines.insert(insert_at, string.String.from_str(text.slice(start, i - start))):
                return
            insert_at += 1
            start = i + 1
        i += 1


## `var` → `let` at the first word-boundary `var` on the line.
function prefer_let_edit(lines: ref[vec.Vec[string.String]], line_index: ptr_uint) -> Option[FixEdit]:
    let text = line_text(lines, line_index)
    match find_word(text, "var"):
        Option.some as pos:
            return Option[FixEdit].some(value = FixEdit(
                start_line = line_index,
                start_char = pos.value,
                end_line = line_index,
                end_char = pos.value + 3,
                new_text = string.String.from_str("let")
            ))
        Option.none:
            return Option[FixEdit].none


## Delete a final bare `return` line.
function redundant_return_edit(lines: ref[vec.Vec[string.String]], line_index: ptr_uint) -> Option[FixEdit]:
    if not line_text(lines, line_index).trim_ascii_whitespace().equal("return"):
        return Option[FixEdit].none
    return Option[FixEdit].some(value = FixEdit(
        start_line = line_index,
        start_char = 0,
        end_line = line_index + 1,
        end_char = 0,
        new_text = string.String.create()
    ))


## Remove the `else:` line and dedent its body by one level.  The warning
## line is either the `else:` line itself or the first body line.
function redundant_else_edit(lines: ref[vec.Vec[string.String]], line_index: ptr_uint) -> Option[FixEdit]:
    var else_index = line_index
    var found_else = false
    if is_bare_else(line_text(lines, line_index)):
        found_else = true
    else:
        var probe = line_index
        while probe > 0:
            probe -= 1
            if is_bare_else(line_text(lines, probe)):
                else_index = probe
                found_else = true
                break
    if not found_else:
        return Option[FixEdit].none

    let first_body = else_index + 1
    if first_body >= lines.len():
        return Option[FixEdit].none

    let else_indent = indent_of(line_text(lines, else_index))
    let body_indent = else_indent + 4

    var body_end = first_body
    var probe = first_body
    while probe < lines.len():
        let text = line_text(lines, probe)
        if text.trim_ascii_whitespace().len == 0 or indent_of(text) >= body_indent:
            body_end = probe
            probe += 1
        else:
            break

    var replacement = string.String.create()
    var bi = first_body
    while bi <= body_end:
        let text = line_text(lines, bi)
        if bi > first_body:
            replacement.append("\n")
        if text.len >= 4 and indent_of(text) >= 4:
            replacement.append(text.slice(4, text.len - 4))
        else:
            replacement.append(text)
        bi += 1

    return Option[FixEdit].some(value = FixEdit(
        start_line = else_index,
        start_char = 0,
        end_line = body_end + 1,
        end_char = 0,
        new_text = replacement
    ))


## Delete the trailing comma at the warning's 1-based column.
function trailing_comma_edit(
    lines: ref[vec.Vec[string.String]],
    line_index: ptr_uint,
    column: ptr_uint,
) -> Option[FixEdit]:
    if column == 0:
        return Option[FixEdit].none
    let text = line_text(lines, line_index)
    let char_index = column - 1
    if char_index >= text.len or text.byte_at(char_index) != 44:
        return Option[FixEdit].none
    return Option[FixEdit].some(value = FixEdit(
        start_line = line_index,
        start_char = char_index,
        end_line = line_index,
        end_char = char_index + 1,
        new_text = string.String.create()
    ))


## Delete the `Type<-` prefix of a redundant cast; the warning column points
## at the cast target type.  When the cast is the payload of an inline
## `unsafe:` prefix, the wrapper is removed too (mirrors Ruby).
function redundant_cast_edit(
    lines: ref[vec.Vec[string.String]],
    line_index: ptr_uint,
    column: ptr_uint,
) -> Option[FixEdit]:
    if column == 0:
        return Option[FixEdit].none
    let text = line_text(lines, line_index)
    var start = column - 1
    if start >= text.len:
        return Option[FixEdit].none

    let arrow = find_from(text, "<-", start) else:
        return Option[FixEdit].none
    if arrow < start:
        return Option[FixEdit].none

    # Extend backwards over a directly preceding `unsafe:` wrapper.
    var new_start = start
    match find_last_before(text, "unsafe:", start):
        Option.some as kw:
            var only_spaces = true
            var pi = kw.value + 7
            while pi < start:
                if text.byte_at(pi) != 32:
                    only_spaces = false
                    break
                pi += 1
            if only_spaces:
                new_start = kw.value
        Option.none:
            pass

    return Option[FixEdit].some(value = FixEdit(
        start_line = line_index,
        start_char = new_start,
        end_line = line_index,
        end_char = arrow + 2,
        new_text = string.String.create()
    ))


## Rewrite an identifier compared against a boolean literal: `x == true` →
## `x`, `x == false` → `not x`, and the mirrored literal-first forms.  Only
## simple identifier operands are rewritten; anything else is skipped.
function redundant_bool_compare_edit(lines: ref[vec.Vec[string.String]], line_index: ptr_uint) -> Option[FixEdit]:
    let text = line_text(lines, line_index)

    # Expression-first only (`IDENT ==|!= true|false`) — the literal-first
    # form is warned about but not rewritten, matching Ruby's fix engine.
    var scan: ptr_uint = 0
    while scan < text.len:
        let op_pos = find_comparison(text, scan) else:
            break
        let op_negated = text.byte_at(op_pos) == 33
        match literal_after(text, op_pos + 2):
            Option.some as lit:
                match identifier_before(text, op_pos):
                    Option.some as ident:
                        let keep = if op_negated: not lit.value.truth else: lit.value.truth
                        return bool_compare_edit(
                            text,
                            line_index,
                            ident.value.start,
                            lit.value.stop,
                            ident.value.start,
                            ident.value.stop,
                            keep
                        )
                    Option.none:
                        pass
            Option.none:
                pass
        scan = op_pos + 2
    return Option[FixEdit].none


## Remove a redundant `: Type` annotation after the let-bound name.
function redundant_type_annotation_edit(lines: ref[vec.Vec[string.String]], line_index: ptr_uint) -> Option[FixEdit]:
    let text = line_text(lines, line_index)
    let let_pos = find_word(text, "let") else:
        return Option[FixEdit].none

    # The bound name follows `let `.
    var name_start = let_pos + 3
    while name_start < text.len and text.byte_at(name_start) == 32:
        name_start += 1
    var name_end = name_start
    while name_end < text.len and is_word_byte(text.byte_at(name_end)):
        name_end += 1
    if name_end == name_start:
        return Option[FixEdit].none

    # Annotation: optional spaces, `:`, spaces, one type token.
    var cursor = name_end
    while cursor < text.len and text.byte_at(cursor) == 32:
        cursor += 1
    if cursor >= text.len or text.byte_at(cursor) != 58:
        return Option[FixEdit].none
    cursor += 1
    while cursor < text.len and text.byte_at(cursor) == 32:
        cursor += 1
    var type_end = cursor
    while type_end < text.len and text.byte_at(type_end) != 32 and text.byte_at(type_end) != 61:
        type_end += 1
    if type_end == cursor:
        return Option[FixEdit].none

    return Option[FixEdit].some(value = FixEdit(
        start_line = line_index,
        start_char = name_end,
        end_line = line_index,
        end_char = type_end,
        new_text = string.String.create()
    ))


## An LSP-space edit for one diagnostic, computed against `source`.  The
## whole-line edit mode is converted to an LSP range ending at column 0 of
## the line after the replaced block, with a trailing newline on non-empty
## replacement text.
public struct LspFixEdit:
    start_line: ptr_uint
    start_char: ptr_uint
    end_line: ptr_uint
    end_char: ptr_uint
    new_text: string.String


public function lsp_edit_for_warning(source: str, code: str, line: ptr_uint, column: ptr_uint) -> Option[LspFixEdit]:
    var lines = split_lines(source)
    defer release_lines(ref_of(lines))
    match edits_for_warning(ref_of(lines), code, line, column):
        Option.some as edit:
            var e = edit.value
            if e.start_line == e.end_line:
                return Option[LspFixEdit].some(value = LspFixEdit(
                    start_line = e.start_line,
                    start_char = e.start_char,
                    end_line = e.end_line,
                    end_char = e.end_char,
                    new_text = e.new_text
                ))
            var text = e.new_text
            if text.len() > 0:
                text.append("\n")
            return Option[LspFixEdit].some(value = LspFixEdit(
                start_line = e.start_line,
                start_char = 0,
                end_line = e.end_line,
                end_char = 0,
                new_text = text
            ))
        Option.none:
            return Option[LspFixEdit].none


# ── bool-compare text scanning ──────────────────────────────────────────────

struct TextSpan:
    start: ptr_uint
    stop: ptr_uint


struct LiteralSpan:
    start: ptr_uint
    stop: ptr_uint
    truth: bool


function bool_compare_edit(
    text: str,
    line_index: ptr_uint,
    span_start: ptr_uint,
    span_stop: ptr_uint,
    ident_start: ptr_uint,
    ident_stop: ptr_uint,
    keep: bool,
) -> Option[FixEdit]:
    var replacement = string.String.create()
    if not keep:
        replacement.append("not ")
    replacement.append(text.slice(ident_start, ident_stop - ident_start))
    return Option[FixEdit].some(value = FixEdit(
        start_line = line_index,
        start_char = span_start,
        end_line = line_index,
        end_char = span_stop,
        new_text = replacement
    ))


## The first `==` or `!=` at or after `from`.
function find_comparison(text: str, from_index: ptr_uint) -> Option[ptr_uint]:
    var i = from_index
    while i + 1 < text.len:
        let b = text.byte_at(i)
        if (b == 61 or b == 33) and text.byte_at(i + 1) == 61:
            return Option[ptr_uint].some(value = i)
        i += 1
    return Option[ptr_uint].none


## A `true`/`false` word after `pos` (spaces allowed between).
function literal_after(text: str, pos: ptr_uint) -> Option[LiteralSpan]:
    var i = pos
    while i < text.len and text.byte_at(i) == 32:
        i += 1
    var stop = i
    while stop < text.len and is_word_byte(text.byte_at(stop)):
        stop += 1
    return literal_span(text, i, stop)


## A `true`/`false` word ending just before `pos` (spaces allowed between).
function literal_before(text: str, pos: ptr_uint) -> Option[LiteralSpan]:
    var stop = pos
    while stop > 0 and text.byte_at(stop - 1) == 32:
        stop -= 1
    var start = stop
    while start > 0 and is_word_byte(text.byte_at(start - 1)):
        start -= 1
    return literal_span(text, start, stop)


function literal_span(text: str, start: ptr_uint, stop: ptr_uint) -> Option[LiteralSpan]:
    if stop <= start:
        return Option[LiteralSpan].none
    let word = text.slice(start, stop - start)
    if word.equal("true"):
        return Option[LiteralSpan].some(value = LiteralSpan(start = start, stop = stop, truth = true))
    if word.equal("false"):
        return Option[LiteralSpan].some(value = LiteralSpan(start = start, stop = stop, truth = false))
    return Option[LiteralSpan].none


## A simple identifier ending just before `pos`.  Member accesses (`a.b`)
## are rejected so `not` insertion cannot split a receiver chain.
function identifier_before(text: str, pos: ptr_uint) -> Option[TextSpan]:
    var stop = pos
    while stop > 0 and text.byte_at(stop - 1) == 32:
        stop -= 1
    var start = stop
    while start > 0 and is_word_byte(text.byte_at(start - 1)):
        start -= 1
    if stop <= start:
        return Option[TextSpan].none
    if start > 0 and text.byte_at(start - 1) == 46:
        return Option[TextSpan].none
    let first = text.byte_at(start)
    if first >= 48 and first <= 57:
        return Option[TextSpan].none
    return Option[TextSpan].some(value = TextSpan(start = start, stop = stop))


## A simple identifier after `pos`; rejects member/call/index continuations.
function identifier_after(text: str, pos: ptr_uint) -> Option[TextSpan]:
    var start = pos
    while start < text.len and text.byte_at(start) == 32:
        start += 1
    var stop = start
    while stop < text.len and is_word_byte(text.byte_at(stop)):
        stop += 1
    if stop <= start:
        return Option[TextSpan].none
    let first = text.byte_at(start)
    if first >= 48 and first <= 57:
        return Option[TextSpan].none
    if stop < text.len:
        let next_byte = text.byte_at(stop)
        if next_byte == 46 or next_byte == 40 or next_byte == 91:
            return Option[TextSpan].none
    return Option[TextSpan].some(value = TextSpan(start = start, stop = stop))


## First occurrence of `needle` at or after `from_index`.
function find_from(text: str, needle: str, from_index: ptr_uint) -> Option[ptr_uint]:
    if from_index >= text.len:
        return Option[ptr_uint].none
    let tail = text.slice(from_index, text.len - from_index)
    match tail.find_substring(needle):
        Option.some as pos:
            return Option[ptr_uint].some(value = from_index + pos.value)
        Option.none:
            return Option[ptr_uint].none


## Last occurrence of `needle` starting before `before`.
function find_last_before(text: str, needle: str, before: ptr_uint) -> Option[ptr_uint]:
    var found = Option[ptr_uint].none
    var scan: ptr_uint = 0
    while scan < before:
        match find_from(text, needle, scan):
            Option.some as pos:
                if pos.value >= before:
                    break
                found = Option[ptr_uint].some(value = pos.value)
                scan = pos.value + 1
            Option.none:
                break
    return found


# ── line-buffer helpers ─────────────────────────────────────────────────────

function is_bare_else(text: str) -> bool:
    return text.trim_ascii_whitespace().equal("else:")


function indent_of(text: str) -> ptr_uint:
    var count: ptr_uint = 0
    while count < text.len and text.byte_at(count) == 32:
        count += 1
    return count


## The first word-boundary occurrence of `word` in `text`.
function find_word(text: str, word: str) -> Option[ptr_uint]:
    if word.len == 0 or word.len > text.len:
        return Option[ptr_uint].none
    let limit = text.len - word.len
    var n: ptr_uint = 0
    while n <= limit:
        var matched = true
        var mi: ptr_uint = 0
        while mi < word.len:
            if text.byte_at(n + mi) != word.byte_at(mi):
                matched = false
                break
            mi += 1
        if matched:
            var boundary = true
            if n > 0 and is_word_byte(text.byte_at(n - 1)):
                boundary = false
            let after = n + word.len
            if after < text.len and is_word_byte(text.byte_at(after)):
                boundary = false
            if boundary:
                return Option[ptr_uint].some(value = n)
        n += 1
    return Option[ptr_uint].none


function is_word_byte(ch: ubyte) -> bool:
    return (ch >= 65 and ch <= 90) or (ch >= 97 and ch <= 122) or ch == 95 or (ch >= 48 and ch <= 57)


function line_text(lines: ref[vec.Vec[string.String]], index: ptr_uint) -> str:
    let lp = lines.get(index) else:
        return ""
    return unsafe: read(lp).as_str()


function set_line(lines: ref[vec.Vec[string.String]], index: ptr_uint, value: string.String) -> void:
    let lp = lines.get(index) else:
        var owned = value
        owned.release()
        return
    unsafe:
        read(lp).release()
        read(lp) = value


function remove_line(lines: ref[vec.Vec[string.String]], index: ptr_uint) -> void:
    match lines.remove(index):
        Option.some as removed:
            var owned = removed.value
            owned.release()
        Option.none:
            pass


function split_lines(source: str) -> vec.Vec[string.String]:
    var result = vec.Vec[string.String].create()
    var start: ptr_uint = 0
    var i: ptr_uint = 0
    while i < source.len:
        if source.byte_at(i) == 10:
            result.push(string.String.from_str(source.slice(start, i - start)))
            start = i + 1
        i += 1
    result.push(string.String.from_str(source.slice(start, source.len - start)))
    return result


function join_lines(lines: ref[vec.Vec[string.String]]) -> string.String:
    var result = string.String.create()
    var i: ptr_uint = 0
    while i < lines.len():
        let lp = lines.get(i) else:
            break
        if i > 0:
            result.append("\n")
        unsafe:
            result.append(read(lp).as_str())
        i += 1
    return result


function release_lines(lines: ref[vec.Vec[string.String]]) -> void:
    var i: ptr_uint = 0
    while i < lines.len():
        let lp = lines.get(i) else:
            break
        unsafe:
            read(lp).release()
        i += 1
    lines.release()


## Delete ` as _` from a match arm line.  Scans the warning line
## and the next line for the literal substring.
function redundant_ignored_match_binding_edit(lines: ref[vec.Vec[string.String]], line_index: ptr_uint) -> Option[FixEdit]:
    var ci: ptr_uint = 0
    while ci <= 1:
        if line_index + ci >= lines.len():
            break
        let text = line_text(lines, line_index + ci)
        match find_substr(text, " as _"):
            Option.some as pos:
                return Option[FixEdit].some(value = FixEdit(
                    start_line = line_index + ci,
                    start_char = pos.value,
                    end_line = line_index + ci,
                    end_char = pos.value + 5,
                    new_text = string.String.create()
                ))
            Option.none:
                pass
        ci += 1
    return Option[FixEdit].none


## Find a literal substring in a str.  Returns the start position or none.
function find_substr(haystack: str, needle: str) -> Option[ptr_uint]:
    if needle.len == 0 or needle.len > haystack.len:
        return Option[ptr_uint].none
    var limit = haystack.len - needle.len
    var i: ptr_uint = 0
    while i <= limit:
        var j: ptr_uint = 0
        var matched = true
        while j < needle.len:
            if haystack.byte_at(i + j) != needle.byte_at(j):
                matched = false
                break
            j += 1
        if matched:
            return Option[ptr_uint].some(value = i)
        i += 1
    return Option[ptr_uint].none


## Merge a `let x = v` declaration and its `if x == null: return ...`
## guard into a single `let x = v else: return ...` line.  The warning
## line points at the `let`/`var` declaration; the if-guard is expected
## on the immediately following line.
function prefer_let_else_edit(
    lines: ref[vec.Vec[string.String]],
    line_index: ptr_uint,
    is_let: bool,
) -> Option[FixEdit]:
    if line_index + 1 >= lines.len():
        return Option[FixEdit].none

    let decl_text = line_text(lines, line_index)
    let guard_text = line_text(lines, line_index + 1)

    # Find the `: ` or `:` just before the if-body on the guard line.
    # The pattern is: `if name == null: <body>` or `if name == null:`
    # We strip everything up to and including the colon, keeping only
    # what follows the colon (the guard body).
    let guard_trimmed = guard_text.trim_ascii_whitespace()
    var colon_pos: ptr_uint = 0
    var i: ptr_uint = 0
    while i < guard_text.len:
        if guard_text.byte_at(i) == ':':
            colon_pos = i + 1
            break
        i += 1

    if colon_pos == 0:
        return Option[FixEdit].none

    # Build the replacement: `let x = v else: <body>`
    var replacement = string.String.from_str(decl_text)
    replacement.append(" else:")
    if colon_pos < guard_text.len:
        replacement.append(guard_text.slice(colon_pos, guard_text.len - colon_pos))

    return Option[FixEdit].some(value = FixEdit(
        start_line = line_index,
        start_char = 0,
        end_line = line_index + 2,
        end_char = 0,
        new_text = replacement
    ))
