## Auto-fix engine — applies safe rewrites for a fixable subset of lint
## rules, following the Ruby linter's FixEngine multi-pass design: each pass
## isolates one rule at a time (fixes re-lint from fresh source, so edits
## from one rule can never corrupt another rule's positions), passes
## repeat until a fixpoint or the pass limit, and a pass is kept only when it
## introduces no new analysis errors (the host's `validated_fixed_source`).
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
##   redundant-ignored-match-binding  `as _` in match arm        → delete ` as _`
##   prefer-let-else           `let x = v; if x == null: ...`    → `let x = v else: ...`
##   prefer-inline-methods     `extending X:` after `struct X:`   → move methods inline
##   reserved-primitive-name   `function int(...)`               → rename declaration
##
## `unused-import` is intentionally NOT auto-fixable, matching Ruby: removing
## an import has non-local effects per-file linting cannot see (it may drop
## extension methods or the canonical `hash[T]`/`equal[T]`/`order[T]` hooks).

import std.str
import std.string as string
import std.vec as vec

import mtc.parser.ast as ast
import mtc.parser.parser as parser
import mtc.parser.state as pstate
import mtc.linter.config as lint_config
import mtc.linter.linter as linter_mod
import mtc.semantic.analyzer as analyzer

const MAX_PASSES: ptr_uint = 5


## The fixable rule codes, in the host's `AUTO_FIXABLE_RULE_CODES` order.
function fixable_codes() -> vec.Vec[str]:
    var codes = vec.Vec[str].create()
    codes.push("prefer-let")
    codes.push("redundant-ignored-match-binding")
    codes.push("prefer-let-else")
    codes.push("prefer-var-else")
    codes.push("prefer-inline-methods")
    codes.push("redundant-bool-compare")
    codes.push("redundant-cast")
    codes.push("redundant-else")
    codes.push("redundant-return")
    codes.push("redundant-type-annotation")
    codes.push("redundant-unsafe")
    codes.push("reserved-primitive-name")
    codes.push("trailing-list-comma")
    return codes


## True when `code` has a fix generator.
public function is_fixable(code: str) -> bool:
    var codes = fixable_codes()
    defer: codes.release()
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
## `options.select`/`options.ignore` filter rule codes exactly like the lint
## command's flags; when they are empty the `.mt-lint.yml` lists apply (the
## host's `AUTO_FIXABLE_RULE_CODES.select { rule enabled }`).  Returns the
## fixed source, which equals the input when nothing was fixable.
public function fix_source(
    source: str,
    path: str,
    options: linter_mod.LintOptions,
) -> string.String:
    # The host's `fix_source_single_pass`: refuse every fix when an import did
    # not resolve, so a rewrite never runs against incomplete facts.
    if options.unresolved_import_paths.len > 0:
        return string.String.from_str(source)

    var current = string.String.from_str(source)

    var codes = fixable_codes()
    defer: codes.release()

    var config = lint_config.load_for_path(path)
    defer: config.release()

    # One batch per rule per pass, then repeat (the host's five outer passes).
    var pass_index: ptr_uint = 0
    while pass_index < MAX_PASSES:
        var changed_in_pass = false
        var ci: ptr_uint = 0
        while ci < codes.len():
            let code_ptr = codes.get(ci) else:
                break
            let code = unsafe: read(code_ptr)
            if rule_enabled(code, options, ref_of(config)):
                var updated = fix_rule_single_pass(current.as_str(), code, path, options)
                if updated.as_str() == current.as_str():
                    updated.release()
                else:
                    current.release()
                    current = updated
                    changed_in_pass = true
            ci += 1
        if not changed_in_pass:
            break
        pass_index += 1

    return current


## A fixable rule is applied when the effective select/ignore lists allow it:
## explicit option lists win over the config's (the host's `select ||= cfg`).
function rule_enabled(code: str, options: linter_mod.LintOptions, config: ref[lint_config.LintConfig]) -> bool:
    var lint_cfg = unsafe: read(config)
    if options.select.len > 0:
        if not code_in(code, options.select):
            return false
    else if lint_cfg.has_select and not string_vec_contains(code, ref_of(lint_cfg.select)):
        return false
    if options.ignore.len > 0:
        return not code_in(code, options.ignore)
    if lint_cfg.has_ignore:
        return not string_vec_contains(code, ref_of(lint_cfg.ignore))
    return true


function code_in(code: str, codes: span[str]) -> bool:
    var i: ptr_uint = 0
    while i < codes.len:
        unsafe:
            if read(codes.data + i).equal(code):
                return true
        i += 1
    return false


function string_vec_contains(code: str, codes: ref[vec.Vec[string.String]]) -> bool:
    var i: ptr_uint = 0
    while i < codes.len():
        let cp = codes.get(i) else:
            break
        unsafe:
            if read(cp).as_str().equal(code):
                return true
        i += 1
    return false


## One lint-and-apply cycle for a single rule.
function fix_rule_single_pass(
    source: str,
    code: str,
    path: str,
    options: linter_mod.LintOptions,
) -> string.String:
    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer: parse_diags.release()
    let file = parser.parse_source(source, ref_of(parse_diags))
    if parse_diags.len() > 0:
        # Never rewrite a file that does not parse.
        return string.String.from_str(source)

    # `reserved-primitive-name` renames a binding at every site it is spelled —
    # a pass of its own over the linter's collected fixes (the host's
    # `fix_source_single_pass` reserved-name phase).
    if code.equal("reserved-primitive-name"):
        var reserved_fixes = linter_mod.collect_reserved_primitive_name_fixes(source, path, options)
        defer: linter_mod.release_reserved_name_fixes(ref_of(reserved_fixes))
        if reserved_fixes.len() == 0:
            return string.String.from_str(source)
        return apply_reserved_name_fixes(source, ref_of(reserved_fixes))

    # Lint the way the command did: with the analysis-backed facts, so a rule
    # that would rewrite `var v` while `v.push(1)` needs it never fires.
    # The semantic maps are keyed by expression pointer, so the analysis must
    # belong to THIS parse (the fix passes re-parse after every edit).
    var analysis = analyze_with_imports(file, path, options)
    var local_options = options
    local_options.analysis = ptr_of(analysis)
    var warnings = linter_mod.lint_source_with(file, source, path, local_options)
    defer: warnings.release()

    var rule_warnings = vec.Vec[linter_mod.Warning].create()
    defer: rule_warnings.release()
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
    defer: release_lines(ref_of(lines))

    var ri: ptr_uint = 0
    while ri < rule_warnings.len():
        let wp = rule_warnings.get(ri) else:
            break
        let w = unsafe: read(wp)
        match edits_for_warning(ref_of(lines), code, w.line, w.column, w.message):
            Option.some as edit:
                apply_edit(ref_of(lines), edit.value)
            Option.none:
                pass
        ri += 1

    # Keep the pass only when it introduces no new analysis errors — the
    # host's `validated_fixed_source`.  A batch that corrupts the source (for
    # example two `prefer-inline-methods` edits whose stale line numbers
    # overlap) fails the re-analysis and is discarded.
    var candidate = join_lines(ref_of(lines))
    var candidate_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer: candidate_diags.release()
    let candidate_file = parser.parse_source(candidate.as_str(), ref_of(candidate_diags))
    if candidate_diags.len() > 0:
        candidate.release()
        return string.String.from_str(source)
    var candidate_analysis = analyze_with_imports(candidate_file, path, options)
    if introduces_new_errors(ref_of(analysis), ref_of(candidate_analysis)):
        candidate.release()
        return string.String.from_str(source)
    return candidate


## Re-analyze an edited source against the same loader-backed imports as the
## lint command's analysis.  Without them, an imported editable method's kind is
## unknown and `prefer-let` would rewrite a `var` the host keeps.
function analyze_with_imports(file: ast.SourceFile, path: str, options: linter_mod.LintOptions) -> analyzer.Analysis:
    let analysis_ptr = options.analysis else:
        return analyzer.check_source_file(file)
    unsafe:
        return analyzer.check_module(
            file,
            read(analysis_ptr).imported_modules,
            read(analysis_ptr).module_name,
            path,
        )


## True when the fixed analysis adds an error signature — a (line, column,
## message) triple whose count exceeds the original's (the host's
## `introduces_new_errors?`).
function introduces_new_errors(
    original_analysis: ref[analyzer.Analysis],
    fixed_analysis: ref[analyzer.Analysis]
) -> bool:
    var i: ptr_uint = 0
    while i < unsafe: read(fixed_analysis).diagnostics.len():
        let dp = unsafe: read(fixed_analysis).diagnostics.get(i) else:
            break
        let d = unsafe: read(dp)
        let before = count_error_signature(original_analysis, d.line, d.column, d.message)
        let after = count_error_signature(fixed_analysis, d.line, d.column, d.message)
        if after > before:
            return true
        i += 1
    return false


## How many diagnostics in `analysis` carry the (line, column, message)
## signature.
function count_error_signature(
    analysis: ref[analyzer.Analysis],
    line: ptr_uint,
    column: ptr_uint,
    message: str
) -> ptr_uint:
    var count: ptr_uint = 0
    var i: ptr_uint = 0
    while i < unsafe: read(analysis).diagnostics.len():
        let dp = unsafe: read(analysis).diagnostics.get(i) else:
            break
        let d = unsafe: read(dp)
        if d.line == line and d.column == column and d.message.equal(message):
            count += 1
        i += 1
    return count


## Sort warnings by (line, column) descending so edits below never shift the
## positions of edits above.
function sort_warnings_descending(warnings: ref[vec.Vec[linter_mod.Warning]]) -> void:
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
    message: str,
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
        return redundant_cast_edit(lines, line_index, column, message)
    if code.equal("redundant-bool-compare"):
        return redundant_bool_compare_edit(lines, line_index)
    if code.equal("redundant-type-annotation"):
        return redundant_type_annotation_edit(lines, line_index)
    if code.equal("redundant-ignored-match-binding"):
        return redundant_ignored_match_binding_edit(lines, line_index)
    if code.equal("prefer-let-else"):
        return prefer_let_else_edit(lines, line_index, true)
    if code.equal("prefer-var-else"):
        return prefer_let_else_edit(lines, line_index, false)
    if code.equal("prefer-inline-methods"):
        return prefer_inline_methods_edit(lines, line_index)
    if code.equal("redundant-unsafe"):
        return redundant_unsafe_edit(lines, line_index)
    if code.equal("unused-import"):
        return unused_import_edit(lines, line_index)
    return Option[FixEdit].none


## Remove a redundant `unsafe:` wrapper: an inline expression drops the keyword
## and the whitespace after it; a block statement dedents its body over the
## removed `unsafe:` line (the host's `redundant_unsafe_edits`).
function redundant_unsafe_edit(lines: ref[vec.Vec[string.String]], line_index: ptr_uint) -> Option[FixEdit]:
    let text = line_text(lines, line_index)
    let unsafe_pos = text.find_substring("unsafe:") else:
        return Option[FixEdit].none
    let keyword_end = unsafe_pos + 7
    if keyword_end > text.len:
        return Option[FixEdit].none

    # Inline expression form: `... unsafe: expr ...`.
    var remainder_start = keyword_end
    while remainder_start < text.len and text.byte_at(remainder_start) == 32:
        remainder_start += 1
    if remainder_start < text.len:
        let remainder = text.slice(remainder_start, text.len - remainder_start)
        if not balanced_line(remainder):
            return Option[FixEdit].none
        return Option[FixEdit].some(value = FixEdit(
            start_line = line_index,
            start_char = unsafe_pos,
            end_line = line_index,
            end_char = remainder_start,
            new_text = string.String.create()
        ))

    # Block form: `unsafe:` alone, body indented deeper.
    let indent = text.slice(0, unsafe_pos)
    var indent_ok = true
    var ii: ptr_uint = 0
    while ii < indent.len:
        if indent.byte_at(ii) != 32:
            indent_ok = false
            break
        ii += 1
    if not indent_ok:
        return Option[FixEdit].none

    let body_start = line_index + 1
    var body_indent: ptr_uint = 0
    var last_body = body_start
    var found_body = false
    var i = body_start
    while i < lines.len():
        let candidate = line_text(lines, i)
        if candidate.trim_ascii_whitespace().len == 0:
            last_body = i
            found_body = true
            i += 1
            continue
        if candidate.len <= indent.len or not candidate.starts_with(indent):
            break
        if candidate.byte_at(indent.len) != 32:
            break
        if body_indent == 0:
            var lead: ptr_uint = 0
            while lead < candidate.len and candidate.byte_at(lead) == 32:
                lead += 1
            body_indent = lead - indent.len
        last_body = i
        found_body = true
        i += 1

    if not found_body or body_indent == 0 or last_body < body_start:
        return Option[FixEdit].none

    var checked = body_start
    while checked <= last_body:
        let candidate = line_text(lines, checked)
        if candidate.trim_ascii_whitespace().len > 0:
            if candidate.len < indent.len + body_indent or
                    not candidate.starts_with(indent):
                return Option[FixEdit].none
        checked += 1

    var replacement = string.String.create()
    var ri = body_start
    while ri <= last_body:
        let candidate = line_text(lines, ri)
        if candidate.trim_ascii_whitespace().len > 0:
            replacement.append(candidate.slice(body_indent, candidate.len - body_indent))
        if ri < last_body:
            replacement.push_byte('\n')
        ri += 1
    replacement.push_byte('\n')

    return Option[FixEdit].some(value = FixEdit(
        start_line = line_index,
        start_char = 0,
        end_line = last_body + 1,
        end_char = 0,
        new_text = replacement
    ))


function balanced_line(text: str) -> bool:
    var depth: int = 0
    var i: ptr_uint = 0
    while i < text.len:
        let ch = text.byte_at(i)
        if ch == '(' or ch == '[':
            depth += 1
        else if ch == ')' or ch == ']':
            depth -= 1
            if depth < 0:
                return false
        i += 1
    return depth == 0


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


## Insert `text` (split on newlines, Ruby's `split("\n")` semantics: a
## trailing newline terminates the last line rather than adding an empty one)
## as new lines starting at `index`.
function insert_lines_at(lines: ref[vec.Vec[string.String]], index: ptr_uint, text: str) -> void:
    var insert_at = index
    var start: ptr_uint = 0
    var i: ptr_uint = 0
    while i <= text.len:
        if i == text.len and i > 0 and text.byte_at(i - 1) == 10:
            break
        if i == text.len or text.byte_at(i) == 10:
            if not lines.insert(insert_at, string.String.from_str(text.slice(start, i - start))):
                return
            insert_at += 1
            start = i + 1
        i += 1


## `var` → `let` at the first word-boundary `var` on the line, as a whole-line
## rewrite carrying the new line (the host's `prefer_let_edits`).
function prefer_let_edit(lines: ref[vec.Vec[string.String]], line_index: ptr_uint) -> Option[FixEdit]:
    let text = line_text(lines, line_index)
    match find_word(text, "var"):
        Option.some as pos:
            var new_line = string.String.create()
            new_line.append(text.slice(0, pos.value))
            new_line.append("let")
            new_line.append(text.slice(pos.value + 3, text.len - pos.value - 3))
            new_line.append("\n")
            return Option[FixEdit].some(value = FixEdit(
                start_line = line_index,
                start_char = 0,
                end_line = line_index + 1,
                end_char = 0,
                new_text = new_line
            ))
        Option.none:
            return Option[FixEdit].none


## The host's `unused-import` edit: delete the import line.  The rule is not in
## `fixable_codes` (never applied by `--fix`, matching the host's auto-fixable
## list), but the LSP's quickfix offers it.
function unused_import_edit(lines: ref[vec.Vec[string.String]], line_index: ptr_uint) -> Option[FixEdit]:
    let text = line_text(lines, line_index)
    if not text.trim_ascii_whitespace().starts_with("import"):
        return Option[FixEdit].none
    return Option[FixEdit].some(value = FixEdit(
        start_line = line_index,
        start_char = 0,
        end_line = line_index + 1,
        end_char = 0,
        new_text = string.String.create()
    ))


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
    let body_limit = content_line_count(lines)
    while probe < body_limit:
        let text = line_text(lines, probe)
        if text.trim_ascii_whitespace().len == 0 or indent_of(text) >= body_indent:
            body_end = probe
            probe += 1
        else:
            break

    # The replacement is the dedented body (the host's `new_body`): the lines
    # joined with their newlines, so the text ends with one.
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
    replacement.append("\n")

    return Option[FixEdit].some(value = FixEdit(
        start_line = else_index,
        start_char = 0,
        end_line = body_end + 1,
        end_char = 0,
        new_text = replacement
    ))


## The number of *content* lines in the buffer: a trailing empty element is
## `split_lines`' representation of the source's final newline (`"a\n"` is
## `["a", ""]` while Ruby's `"a\n".lines` is `["a\n"]`), so scans that walk a
## buffer's real lines must not consume it.
function content_line_count(lines: ref[vec.Vec[string.String]]) -> ptr_uint:
    if lines.len() == 0:
        return 0
    if line_text(lines, lines.len() - 1).len == 0:
        return lines.len() - 1
    return lines.len()


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
## `unsafe:` prefix, the wrapper is removed too, and when the inner expression
## is left parenthesized with no top-level operators the orphaned parens go
## with it.  A "parentheses are redundant" warning removes only the parens
## (mirrors Ruby's `redundant_cast_edits`).
function redundant_cast_edit(
    lines: ref[vec.Vec[string.String]],
    line_index: ptr_uint,
    column: ptr_uint,
    message: str,
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
    let arrow_end = arrow + 2

    # Parens-only fix: `T<-(x)` -> `T<-x`.
    if message_contains(message, "parentheses"):
        if arrow_end >= text.len or text.byte_at(arrow_end) != '(':
            return Option[FixEdit].none
        let close = cast_match_paren(text, arrow_end) else:
            return Option[FixEdit].none
        let inner_text = text.slice(arrow_end + 1, close - (arrow_end + 1))
        return Option[FixEdit].some(value = FixEdit(
            start_line = line_index,
            start_char = arrow_end,
            end_line = line_index,
            end_char = close + 1,
            new_text = string.String.from_str(inner_text)
        ))

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

    # The cast removal can orphan a parenthesized inner expression.
    if arrow_end < text.len and text.byte_at(arrow_end) == '(':
        match cast_match_paren(text, arrow_end):
            Option.some as close:
                let inner_text = text.slice(arrow_end + 1, close.value - (arrow_end + 1))
                if not cast_inner_has_top_level_operators(inner_text):
                    return Option[FixEdit].some(value = FixEdit(
                        start_line = line_index,
                        start_char = new_start,
                        end_line = line_index,
                        end_char = close.value + 1,
                        new_text = string.String.from_str(inner_text)
                    ))
            Option.none:
                pass

    return Option[FixEdit].some(value = FixEdit(
        start_line = line_index,
        start_char = new_start,
        end_line = line_index,
        end_char = arrow + 2,
        new_text = string.String.create()
    ))


function message_contains(message: str, needle: str) -> bool:
    return message.contains_substring(needle)


## The index of the `)` matching the `(` at `open_pos`, or none.
function cast_match_paren(line: str, open_pos: ptr_uint) -> Option[ptr_uint]:
    var depth: int = 0
    var i = open_pos
    while i < line.len:
        let b = line.byte_at(i)
        if b == '(':
            depth += 1
        else if b == ')':
            depth -= 1
            if depth == 0:
                return Option[ptr_uint].some(value = i)
        i += 1
    return Option[ptr_uint].none


function cast_binary_op_char(b: ubyte) -> bool:
    return (
        b == '+' or b == '-' or b == '*' or b == '/' or b == '%'
        or b == '&' or b == '|' or b == '^' or b == '<' or b == '>'
        or b == '=' or b == '!' or b == '?' or b == ':'
    )


function cast_inner_has_top_level_operators(inner: str) -> bool:
    var depth: int = 0
    var i: ptr_uint = 0
    while i < inner.len:
        let b = inner.byte_at(i)
        if b == '(' or b == '[' or b == '{':
            depth += 1
        else if b == ')' or b == ']' or b == '}':
            if depth > 0:
                depth -= 1
        else if cast_binary_op_char(b):
            if depth == 0:
                return true
        i += 1
    return false


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

## An LSP-space edit for one diagnostic, computed against `source`.  The edit
## is passed through unchanged: the generators carry the host's own ranges and
## replacement text (whole-line rewrites include their trailing newline), so a
## code action's TextEdit matches the host's byte for byte.
public struct LspFixEdit:
    start_line: ptr_uint
    start_char: ptr_uint
    end_line: ptr_uint
    end_char: ptr_uint
    new_text: string.String


public function lsp_edit_for_warning(
    source: str,
    code: str,
    line: ptr_uint,
    column: ptr_uint,
    message: str
) -> Option[LspFixEdit]:
    var lines = split_lines(source)
    defer: release_lines(ref_of(lines))
    match edits_for_warning(ref_of(lines), code, line, column, message):
        Option.some as edit:
            return Option[LspFixEdit].some(value = LspFixEdit(
                start_line = edit.value.start_line,
                start_char = edit.value.start_char,
                end_line = edit.value.end_line,
                end_char = edit.value.end_char,
                new_text = edit.value.new_text
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
function redundant_ignored_match_binding_edit(
    lines: ref[vec.Vec[string.String]],
    line_index: ptr_uint
) -> Option[FixEdit]:
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

    # Build the replacement: `let x = v else: <body>` — a whole-line rewrite
    # whose text ends with the line's newline (the host's shape).
    var replacement = string.String.from_str(decl_text)
    replacement.append(" else:")
    if colon_pos < guard_text.len:
        replacement.append(guard_text.slice(colon_pos, guard_text.len - colon_pos))
    replacement.append("\n")

    return Option[FixEdit].some(value = FixEdit(
        start_line = line_index,
        start_char = 0,
        end_line = line_index + 2,
        end_char = 0,
        new_text = replacement
    ))


## Apply every collected reserved-name fix: each site's name becomes its
## binding's replacement, applied right-to-left so earlier columns keep their
## positions (the host's `apply_reserved_primitive_name_fixes`).
function apply_reserved_name_fixes(source: str, fixes: ref[vec.Vec[linter_mod.ReservedNameFix]]) -> string.String:
    var lines = split_lines(source)
    defer: release_lines(ref_of(lines))

    var site_lines = vec.Vec[ptr_uint].create()
    defer: site_lines.release()
    var site_columns = vec.Vec[ptr_uint].create()
    defer: site_columns.release()
    var site_lengths = vec.Vec[ptr_uint].create()
    defer: site_lengths.release()
    var site_texts = vec.Vec[str].create()
    defer: site_texts.release()

    var fi: ptr_uint = 0
    while fi < fixes.len():
        let fp = fixes.get(fi) else:
            break
        let fix = unsafe: read(fp)
        var si: ptr_uint = 0
        while si < fix.sites.len():
            let sp = fix.sites.get(si) else:
                break
            let site = unsafe: read(sp)
            if not reserved_site_seen(ref_of(site_lines), ref_of(site_columns), site.line, site.column):
                site_lines.push(site.line)
                site_columns.push(site.column)
                site_lengths.push(site.length)
                site_texts.push(fix.replacement_name)
            si += 1
        fi += 1

    # Descending by (line, column): an insertion sort over the parallel
    # vectors, the site counts are small.
    let n = site_lines.len()
    var i: ptr_uint = 1
    while i < n:
        var j = i
        while j > 0:
            let prev_line_ptr = site_lines.get(j - 1) else:
                break
            let prev_column_ptr = site_columns.get(j - 1) else:
                break
            let cur_line_ptr = site_lines.get(j) else:
                break
            let cur_column_ptr = site_columns.get(j) else:
                break
            let prev_line = unsafe: read(prev_line_ptr)
            let prev_column = unsafe: read(prev_column_ptr)
            let cur_line = unsafe: read(cur_line_ptr)
            let cur_column = unsafe: read(cur_column_ptr)
            if prev_line > cur_line or (prev_line == cur_line and prev_column >= cur_column):
                break
            site_lines.swap(j - 1, j)
            site_columns.swap(j - 1, j)
            site_lengths.swap(j - 1, j)
            site_texts.swap(j - 1, j)
            j -= 1
        i += 1

    var k: ptr_uint = 0
    while k < n:
        let line_ptr = site_lines.get(k) else:
            break
        let column_ptr = site_columns.get(k) else:
            break
        let length_ptr = site_lengths.get(k) else:
            break
        let text_ptr = site_texts.get(k) else:
            break
        let line = unsafe: read(line_ptr)
        let column = unsafe: read(column_ptr)
        let length = unsafe: read(length_ptr)
        let text = unsafe: read(text_ptr)
        if line > 0 and column > 0:
            apply_edit(lines = ref_of(lines), edit = FixEdit(
                start_line = line - 1,
                start_char = column - 1,
                end_line = line - 1,
                end_char = column - 1 + length,
                new_text = string.String.from_str(text)
            ))
        k += 1

    return join_lines(ref_of(lines))


## True when (line, column) is already among the recorded sites.
function reserved_site_seen(
    site_lines: ref[vec.Vec[ptr_uint]],
    site_columns: ref[vec.Vec[ptr_uint]],
    line: ptr_uint,
    column: ptr_uint
) -> bool:
    var i: ptr_uint = 0
    while i < site_lines.len():
        let l = site_lines.get(i) else:
            break
        let c = site_columns.get(i) else:
            break
        if unsafe: read(l) == line and unsafe: read(c) == column:
            return true
        i += 1
    return false


## Move an `extending X:` block's methods inline into the same file's
## `struct X:` declaration — the host's `prefer_inline_methods_edits`.  Only
## rewrites when the struct's last member precedes the block with nothing but
## blank lines between; any other layout would make the move non-local.
function prefer_inline_methods_edit(lines: ref[vec.Vec[string.String]], line_index: ptr_uint) -> Option[FixEdit]:
    let ext_start = line_index
    let name = extending_target_name(line_text(lines, ext_start)) else:
        return Option[FixEdit].none

    # The first `struct <name>` declaration in the file.
    var struct_index: ptr_uint = 0
    var have_struct = false
    while struct_index < lines.len():
        if is_struct_decl(line_text(lines, struct_index), name):
            have_struct = true
            break
        struct_index += 1
    if not have_struct:
        return Option[FixEdit].none

    # The struct body's last member line (a blank line ends the body only at
    # the next top-level declaration).
    var last_member: ptr_uint = 0
    var have_member = false
    var i = struct_index + 1
    while i < lines.len():
        let text = line_text(lines, i)
        if text.len > 0 and not starts_with_indent(text):
            break
        if text.len > 0:
            last_member = i
            have_member = true
        i += 1
    if not have_member or last_member >= ext_start:
        return Option[FixEdit].none

    # The block's last non-blank line.
    var ext_end = ext_start
    i = ext_start + 1
    while i < lines.len():
        let text = line_text(lines, i)
        if text.len > 0 and not starts_with_indent(text):
            break
        if text.len > 0:
            ext_end = i
        i += 1
    if ext_end <= ext_start:
        return Option[FixEdit].none

    # The method lines, trimmed of leading and trailing blank lines.
    var first = ext_start + 1
    while first <= ext_end and line_text(lines, first).len == 0:
        first += 1
    if first > ext_end:
        return Option[FixEdit].none
    var last = ext_end
    while last > first and line_text(lines, last).len == 0:
        last -= 1

    # Everything between the struct's body and the block must be blank.
    i = last_member + 1
    while i < ext_start:
        if line_text(lines, i).len > 0:
            return Option[FixEdit].none
        i += 1

    # The struct's last member, a blank line, then the block's methods — the
    # host's text, which ends with the method lines' final newline.
    var new_text = string.String.from_str(line_text(lines, last_member))
    new_text.append("\n\n")
    i = first
    while i <= last:
        if i > first:
            new_text.append("\n")
        new_text.append(line_text(lines, i))
        i += 1
    new_text.append("\n")

    return Option[FixEdit].some(value = FixEdit(
        start_line = last_member,
        start_char = 0,
        end_line = ext_end + 1,
        end_char = 0,
        new_text = new_text
    ))


## The target name of an `extending <Name>:` block, or none when the line is
## not that form (only single-name, argument-less blocks are fixable).
function extending_target_name(text: str) -> Option[str]:
    var i: ptr_uint = 0
    while i < text.len and (text.byte_at(i) == ' ' or text.byte_at(i) == '\t'):
        i += 1
    if not matches_word_at(text, i, "extending"):
        return Option[str].none
    i += "extending".len
    while i < text.len and (text.byte_at(i) == ' ' or text.byte_at(i) == '\t'):
        i += 1
    let start = i
    while i < text.len and is_word_byte(text.byte_at(i)):
        i += 1
    if i == start:
        return Option[str].none
    let name_end = i
    while i < text.len and (text.byte_at(i) == ' ' or text.byte_at(i) == '\t'):
        i += 1
    if i >= text.len or text.byte_at(i) != ':':
        return Option[str].none
    return Option[str].some(value = text.slice(start, name_end - start))


## True when the line declares `struct <name>` (the host's
## `/\A\s*struct\s+<name>\b/`).
function is_struct_decl(text: str, name: str) -> bool:
    var i: ptr_uint = 0
    while i < text.len and (text.byte_at(i) == ' ' or text.byte_at(i) == '\t'):
        i += 1
    if not matches_word_at(text, i, "struct"):
        return false
    i += "struct".len
    while i < text.len and (text.byte_at(i) == ' ' or text.byte_at(i) == '\t'):
        i += 1
    if i + name.len > text.len:
        return false
    if not text.starts_with_at(i, name):
        return false
    let after = i + name.len
    return after == text.len or not is_word_byte(text.byte_at(after))


## True when `word` appears at `index` on a word boundary.
function matches_word_at(text: str, index: ptr_uint, word: str) -> bool:
    if index + word.len > text.len:
        return false
    if not text.starts_with_at(index, word):
        return false
    let after = index + word.len
    return after == text.len or not is_word_byte(text.byte_at(after))


## True when the line starts with a space or a tab.
function starts_with_indent(text: str) -> bool:
    if text.len == 0:
        return false
    return text.byte_at(0) == ' ' or text.byte_at(0) == '\t'
