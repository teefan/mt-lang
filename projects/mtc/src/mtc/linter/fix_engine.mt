## Auto-fix engine — applies safe rewrites for a fixable subset of lint
## rules, following the Ruby linter's FixEngine multi-pass design: each pass
## isolates one rule at a time (fixes re-lint from fresh source, so edits
## from one rule can never corrupt another rule's positions), and passes
## repeat until a fixpoint or the pass limit.
##
## Fixable rules:
##   prefer-let          `var` never reassigned            → `let`
##   redundant-return    final bare `return` in void body  → delete line
##   redundant-else      else after all-return branches    → dedent body
##   trailing-list-comma comma before a call's `)`         → delete comma
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
        apply_rule_fix(ref_of(lines), code, w)
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


## Dispatch one warning to its rule's fix.
function apply_rule_fix(lines: ref[vec.Vec[string.String]], code: str, w: linter.Warning) -> void:
    if w.line == 0:
        return
    let line_index = w.line - 1
    if line_index >= lines.len():
        return

    if code.equal("prefer-let"):
        fix_prefer_let(lines, line_index)
    else if code.equal("redundant-return"):
        fix_redundant_return(lines, line_index)
    else if code.equal("redundant-else"):
        fix_redundant_else(lines, line_index)
    else if code.equal("trailing-list-comma"):
        fix_trailing_comma(lines, line_index, w.column)


## `var` → `let` at the first word-boundary `var` on the line.
function fix_prefer_let(lines: ref[vec.Vec[string.String]], line_index: ptr_uint) -> void:
    let text = line_text(lines, line_index)
    match find_word(text, "var"):
        Option.some as pos:
            var rebuilt = string.String.from_str(text.slice(0, pos.value))
            rebuilt.append("let")
            let after = pos.value + 3
            rebuilt.append(text.slice(after, text.len - after))
            set_line(lines, line_index, rebuilt)
        Option.none:
            pass


## Delete a final bare `return` line.
function fix_redundant_return(lines: ref[vec.Vec[string.String]], line_index: ptr_uint) -> void:
    if line_text(lines, line_index).trim_ascii_whitespace().equal("return"):
        remove_line(lines, line_index)


## Remove the `else:` line and dedent its body by one level.  The warning
## line is either the `else:` line itself or the first body line.
function fix_redundant_else(lines: ref[vec.Vec[string.String]], line_index: ptr_uint) -> void:
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
        return

    let first_body = else_index + 1
    if first_body >= lines.len():
        return

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

    # Dedent body lines by 4 in place, then drop the `else:` line.
    var bi = first_body
    while bi <= body_end:
        let text = line_text(lines, bi)
        if text.len >= 4 and indent_of(text) >= 4:
            var dedented = string.String.from_str(text.slice(4, text.len - 4))
            set_line(lines, bi, dedented)
        bi += 1
    remove_line(lines, else_index)


## Delete the trailing comma at the warning's 1-based column.
function fix_trailing_comma(lines: ref[vec.Vec[string.String]], line_index: ptr_uint, column: ptr_uint) -> void:
    if column == 0:
        return
    let text = line_text(lines, line_index)
    let char_index = column - 1
    if char_index >= text.len or text.byte_at(char_index) != 44:
        return
    var rebuilt = string.String.from_str(text.slice(0, char_index))
    let after = char_index + 1
    rebuilt.append(text.slice(after, text.len - after))
    set_line(lines, line_index, rebuilt)


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
