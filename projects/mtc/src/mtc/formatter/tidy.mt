## Tidy formatter — the Ruby `MilkTea::Formatter` modes that are not the AST
## pretty printer: `:tidy` (CST normalize → wrap → blank lines), `:preserve`
## (CST reconstruct), plus the mode dispatch the CLI and the LSP handlers share.
##
## Host references (lib/milk_tea/tooling/formatter.rb): tidy_format 54-59,
## resolve_max_line_length 61-69, wrap_long_argument_lists 71-104,
## build_long_line_wrap_fix 106-168, build_wrapped_* 170-216,
## normalize_blank_lines 225-316 with its helpers 318-621, and the wrap
## candidate machinery 623-778.

import std.str
import std.string as string
import std.vec as vec

import mtc.formatter.cst as cst
import mtc.lexer.lexer as lexer
import mtc.lexer.token as tok
import mtc.lexer.token_kinds as tk
import mtc.linter.config as lint_config
import mtc.parser.parser as parser
import mtc.parser.state as pstate
import mtc.pretty_printer.ast_formatter as ast_formatter
import mtc.profile as profile_mod


const DEFAULT_MAX_LINE_LENGTH: ptr_uint = 120
const MAX_WRAP_ITERATIONS: ptr_uint = 100


public enum FormatMode: ubyte
    safe      = 0
    canonical = 1
    preserve  = 2
    tidy      = 3


## Top-level declaration groups for the blank-line rules (host
## `top_level_declaration_group`).
public enum DeclGroup: ubyte
    directive         = 0
    opaque_decl       = 1
    type_decl         = 2
    struct_decl       = 3
    union_decl        = 4
    variant_decl      = 5
    enum_decl         = 6
    flags_decl        = 7
    const_decl        = 8
    var_decl          = 9
    external_function = 10
    external_decl     = 11


# =============================================================================
#  Mode dispatch
# =============================================================================

## Parse a client-provided mode name the way the LSP configuration does
## (strip, case-insensitive; only the host's `Formatter::MODES` count).
public function parse_format_mode(name: str) -> Option[FormatMode]:
    let trimmed = name.trim_ascii_whitespace()
    if equals_ignore_case(trimmed, "safe"):
        return Option[FormatMode].some(value = FormatMode.safe)
    if equals_ignore_case(trimmed, "canonical"):
        return Option[FormatMode].some(value = FormatMode.canonical)
    if equals_ignore_case(trimmed, "preserve"):
        return Option[FormatMode].some(value = FormatMode.preserve)
    if equals_ignore_case(trimmed, "tidy"):
        return Option[FormatMode].some(value = FormatMode.tidy)
    return Option[FormatMode].none


## `Formatter.format_source`.  `explicit_max_line_length` of 0 means "resolve
## from the linter config, else the default" (the host's `explicit: nil`).
public function format_source(source: str, path: str, mode: FormatMode, explicit_max_line_length: ptr_uint) -> Option[string.String]:
    return format_source_profiled(source, path, mode, explicit_max_line_length, null)


## `format_source` with the host's `--timings` phase profile: the outer
## `format` phase plus each mode's steps (`format.lex`/`format.parse`/
## `format.ast` for the AST modes; `format.cst`, `format.normalize`,
## `format.wrap`, `format.blank_lines`, `format.cst_fmt` for the CST modes).
public function format_source_profiled(source: str, path: str, mode: FormatMode, explicit_max_line_length: ptr_uint, profile: ptr[profile_mod.Profile]?) -> Option[string.String]:
    let started = profile_mod.now_ms()
    var result = Option[string.String].none
    match mode:
        FormatMode.preserve:
            result = format_preserve(source, profile)
        FormatMode.tidy:
            result = format_tidy(source, path, resolve_max_line_length(path, explicit_max_line_length), profile)
        _:
            result = format_canonical(source, profile)
    profile_mod.record(profile, "format", profile_mod.now_ms() - started)
    return result


## `Formatter.resolve_max_line_length`.
public function resolve_max_line_length(path: str, explicit: ptr_uint) -> ptr_uint:
    var value = explicit
    if value == 0:
        value = lint_config.load_for_path(path).max_line_length
    if value > 0:
        return value
    return DEFAULT_MAX_LINE_LENGTH


## `:preserve` — CST reconstruct, verbatim.
public function format_preserve(source: str, profile: ptr[profile_mod.Profile]?) -> Option[string.String]:
    var diags = vec.Vec[tok.LexDiagnostic].create()
    defer: diags.release()
    let cst_started = profile_mod.now_ms()
    var cst_file = cst.build_cst(source, ref_of(diags))
    profile_mod.record(profile, "format.cst", profile_mod.now_ms() - cst_started)
    defer: cst.release_cst(ref_of(cst_file))
    if diags.len() > 0:
        return Option[string.String].none
    let fmt_started = profile_mod.now_ms()
    var result = cst.reconstruct(cst_file)
    profile_mod.record(profile, "format.cst_fmt", profile_mod.now_ms() - fmt_started)
    return Option[string.String].some(value = result)


## `:safe` / `:canonical` — AST pretty printer with comment reattachment
## (trivia from a `lex_with_trivia` pass, as the host's `canonical_format` does).
public function format_canonical(source: str, profile: ptr[profile_mod.Profile]?) -> Option[string.String]:
    var diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer: diags.release()
    let parse_started = profile_mod.now_ms()
    var file = parser.parse_source(source, ref_of(diags))
    profile_mod.record(profile, "format.parse", profile_mod.now_ms() - parse_started)
    if diags.len() > 0:
        return Option[string.String].none
    var lex_diags = vec.Vec[tok.LexDiagnostic].create()
    defer: lex_diags.release()
    let lex_started = profile_mod.now_ms()
    var lexed = lexer.lex_with_trivia(source, ref_of(lex_diags))
    profile_mod.record(profile, "format.lex", profile_mod.now_ms() - lex_started)
    let ast_started = profile_mod.now_ms()
    var result = ast_formatter.format_source_file_with_trivia(file, source, lexed.trivia.as_span())
    profile_mod.record(profile, "format.ast", profile_mod.now_ms() - ast_started)
    lexed.tokens.release()
    lexed.trivia.release()
    return Option[string.String].some(value = result)


## `:tidy` — CST normalize → wrap → blank lines.
public function format_tidy(source: str, path: str, max_line_length: ptr_uint, profile: ptr[profile_mod.Profile]?) -> Option[string.String]:
    var diags = vec.Vec[tok.LexDiagnostic].create()
    defer: diags.release()
    let cst_started = profile_mod.now_ms()
    var cst_file = cst.build_cst(source, ref_of(diags))
    profile_mod.record(profile, "format.cst", profile_mod.now_ms() - cst_started)
    defer: cst.release_cst(ref_of(cst_file))
    if diags.len() > 0:
        return Option[string.String].none

    let norm_started = profile_mod.now_ms()
    var normalized = cst.reconstruct_normalized(cst_file)
    profile_mod.record(profile, "format.normalize", profile_mod.now_ms() - norm_started)
    defer: normalized.release()

    let wrap_started = profile_mod.now_ms()
    var wrapped = wrap_long_argument_lists(normalized.as_str(), max_line_length, path)
    profile_mod.record(profile, "format.wrap", profile_mod.now_ms() - wrap_started)
    defer: wrapped.release()

    let blank_started = profile_mod.now_ms()
    var result = normalize_blank_lines(wrapped.as_str())
    profile_mod.record(profile, "format.blank_lines", profile_mod.now_ms() - blank_started)
    return Option[string.String].some(value = result)


# =============================================================================
#  Text helpers
# =============================================================================

function append_to(output: ref[string.String], text: str) -> void:
    unsafe:
        read(output).append(text)


function slice_span(text: str, start: ptr_uint, end_offset: ptr_uint) -> str:
    if end_offset <= start or end_offset > text.len:
        return ""
    return unsafe: str(data = text.data + start, len = end_offset - start)


function is_space_or_tab(b: ubyte) -> bool:
    return b == ' ' or b == '\t'


function identifier_head_byte(b: ubyte) -> bool:
    return (b >= 'A' and b <= 'Z') or (b >= 'a' and b <= 'z') or b == '_'


function identifier_tail_byte(b: ubyte) -> bool:
    return identifier_head_byte(b) or (b >= '0' and b <= '9')


function ascii_lower_byte(b: ubyte) -> ubyte:
    if b >= 'A' and b <= 'Z':
        return b + 32
    return b


function equals_ignore_case(left: str, right: str) -> bool:
    if left.len != right.len:
        return false
    var i: ptr_uint = 0
    while i < left.len:
        if ascii_lower_byte(left.byte_at(i)) != ascii_lower_byte(right.byte_at(i)):
            return false
        i += 1
    return true


## Ruby `String#length` for UTF-8 text (code points, not bytes).
function utf8_char_count(text: str) -> ptr_uint:
    var count: ptr_uint = 0
    var i: ptr_uint = 0
    while i < text.len:
        let b = text.byte_at(i)
        if b < 0x80 or b > 0xBF:
            count += 1
        i += 1
    return count


## Ruby `String#lines` — every line keeps its "\n".
function split_lines_keep(source: str) -> vec.Vec[str]:
    var lines = vec.Vec[str].create()
    var start: ptr_uint = 0
    var i: ptr_uint = 0
    while i < source.len:
        if source.byte_at(i) == '\n':
            lines.push(slice_span(source, start, i + 1))
            start = i + 1
        i += 1
    if start < source.len:
        lines.push(slice_span(source, start, source.len))
    return lines


## Ruby `String#lines(chomp: true)`.
function split_lines_chomp(source: str) -> vec.Vec[str]:
    var lines = vec.Vec[str].create()
    var start: ptr_uint = 0
    var i: ptr_uint = 0
    while i < source.len:
        if source.byte_at(i) == '\n':
            lines.push(chomp_carriage_return(slice_span(source, start, i)))
            start = i + 1
        i += 1
    if start < source.len:
        lines.push(chomp_carriage_return(slice_span(source, start, source.len)))
    return lines


function chomp_carriage_return(line: str) -> str:
    if line.len > 0 and line.byte_at(line.len - 1) == '\r':
        return slice_span(line, 0, line.len - 1)
    return line


function strip_trailing_newline(line: str) -> str:
    if line.len > 0 and line.byte_at(line.len - 1) == '\n':
        return slice_span(line, 0, line.len - 1)
    return line


function line_at(lines: vec.Vec[str], index: ptr_uint) -> Option[str]:
    let entry = lines.get(index) else:
        return Option[str].none
    return Option[str].some(value = unsafe: read(entry))


## Byte offset of character index `char_index` in `text` (clamped to the end).
## Ruby strings index by character; the lexer's token columns are byte offsets
## (`Token#column`), so every `line[...]` slice the host's wrap machinery makes
## mixes byte indices with character slicing.  Reproducing that mixed model is
## what keeps the wrapped text byte-identical on lines with multi-byte text.
function byte_offset_of_char(text: str, char_index: ptr_uint) -> ptr_uint:
    var chars: ptr_uint = 0
    var i: ptr_uint = 0
    while i < text.len:
        if chars == char_index:
            return i
        let b = text.byte_at(i)
        if b < 0x80 or b > 0xBF:
            chars += 1
        i += 1
    return text.len


function char_at(text: str, char_index: ptr_uint) -> ubyte:
    let byte_index = byte_offset_of_char(text, char_index)
    if byte_index >= text.len:
        return 0
    return text.byte_at(byte_index)


## Ruby `text[start...stop]` by character index (nil slices become "").
function char_slice(text: str, start_char: ptr_uint, stop_char: ptr_uint) -> str:
    let start_byte = byte_offset_of_char(text, start_char)
    if start_byte >= text.len:
        return ""
    let stop_byte = byte_offset_of_char(text, stop_char)
    if stop_byte <= start_byte:
        return ""
    return slice_span(text, start_byte, stop_byte)


## Ruby `text[start..]` by character index (nil slices become "").
function char_slice_from(text: str, start_char: ptr_uint) -> str:
    let start_byte = byte_offset_of_char(text, start_char)
    if start_byte >= text.len:
        return ""
    return slice_span(text, start_byte, text.len)


## The whole text with `lines[index]` replaced by `new_text` (which may hold
## several newlines).
function replace_line(lines: vec.Vec[str], index: ptr_uint, new_text: str) -> string.String:
    var output = string.String.create()
    var i: ptr_uint = 0
    while i < lines.len():
        if i == index:
            append_to(ref_of(output), new_text)
        else:
            let entry = lines.get(i) else:
                break
            append_to(ref_of(output), unsafe: read(entry))
        i += 1
    return output


function join_lines_with_newlines(lines: vec.Vec[str]) -> string.String:
    var output = string.String.create()
    var i: ptr_uint = 0
    while i < lines.len():
        if i > 0:
            append_to(ref_of(output), "\n")
        let entry = lines.get(i) else:
            break
        append_to(ref_of(output), unsafe: read(entry))
        i += 1
    append_to(ref_of(output), "\n")
    return output


# =============================================================================
#  Line classification (host helpers 318-621)
# =============================================================================

function blank_line(line: str) -> bool:
    var i: ptr_uint = 0
    while i < line.len:
        let b = line.byte_at(i)
        if b != ' ' and b != '\t':
            return false
        i += 1
    return true


function leading_indent_width(line: str) -> ptr_uint:
    var i: ptr_uint = 0
    while i < line.len:
        let b = line.byte_at(i)
        if b != ' ' and b != '\t':
            break
        i += 1
    return i


function leading_indent_text(line: str) -> str:
    return slice_span(line, 0, leading_indent_width(line))


## Host `function_line?`: after any run of words, a `function` keyword followed
## by whitespace.
function function_line(line: str) -> bool:
    var i: ptr_uint = 0
    while i < line.len:
        let b = line.byte_at(i)
        if b != ' ' and b != '\t':
            break
        i += 1
    if i >= line.len:
        return false

    while true:
        let word_start = i
        if not identifier_head_byte(line.byte_at(i)):
            return false
        i += 1
        while i < line.len and identifier_tail_byte(line.byte_at(i)):
            i += 1

        if slice_span(line, word_start, i).equal("function"):
            return i < line.len and is_space_or_tab(line.byte_at(i))

        if i >= line.len or not is_space_or_tab(line.byte_at(i)):
            return false
        while i < line.len and is_space_or_tab(line.byte_at(i)):
            i += 1

    return false


## Host `bodyless_function_line?`: the line does not end with ':'.
function bodyless_function_line(line: str) -> bool:
    var i = line.len
    while i > 0:
        let b = line.byte_at(i - 1)
        if b != ' ' and b != '\t':
            break
        i -= 1
    if i == 0:
        return false
    return line.byte_at(i - 1) != ':'


function bodyless_function_header_at(lines: vec.Vec[str], line_index: ptr_uint) -> bool:
    let line = line_at(lines, line_index) else:
        return false
    if not function_line(line):
        return false
    if not bodyless_function_line(line):
        return false

    let function_indent = leading_indent_width(line)
    var cursor = line_index + 1
    while cursor < lines.len():
        let candidate = line_at(lines, cursor) else:
            break
        if blank_line(candidate):
            cursor += 1
            continue

        let candidate_indent = leading_indent_width(candidate)
        if candidate_indent < function_indent:
            break
        else if candidate_indent == function_indent and not function_header_continuation_line(candidate):
            break

        if not bodyless_function_line(candidate):
            return false
        cursor += 1

    return true


function function_header_continuation_line(line: str) -> bool:
    let stripped = line.trim_ascii_whitespace()
    if stripped.len == 0:
        return false
    return stripped.starts_with(")") or stripped.starts_with("]") or stripped.starts_with(",") or stripped.starts_with("->")


function line_inside_bodyless_function_header(lines: vec.Vec[str], line_index: ptr_uint) -> bool:
    var cursor = line_index + 1
    while cursor > 0:
        cursor -= 1
        let line = line_at(lines, cursor) else:
            break
        if function_line(line):
            return bodyless_function_header_at(lines, cursor) and line_in_function_header_span(lines, cursor, line_index)
    return false


function line_in_function_header_span(lines: vec.Vec[str], start_index: ptr_uint, target_index: ptr_uint) -> bool:
    if target_index < start_index:
        return false

    let start_line = line_at(lines, start_index) else:
        return false
    let function_indent = leading_indent_width(start_line)
    var header_end = start_index
    var cursor = start_index + 1

    while cursor < lines.len():
        let candidate = line_at(lines, cursor) else:
            break
        if blank_line(candidate):
            cursor += 1
            continue

        let candidate_indent = leading_indent_width(candidate)
        if candidate_indent < function_indent:
            break
        else if candidate_indent == function_indent and not function_header_continuation_line(candidate):
            break

        header_end = cursor
        cursor += 1

    return target_index <= header_end


## True when `text[word_start..]` is the word `external` or `foreign` followed
## by `function` (host `/\A(?:external|foreign)\s+function\b/` suffix).
function word_followed_by_function(text: str, word_start: ptr_uint) -> bool:
    var i = word_start
    if i >= text.len or not identifier_head_byte(text.byte_at(i)):
        return false
    i += 1
    while i < text.len and identifier_tail_byte(text.byte_at(i)):
        i += 1

    var k = i
    while k < text.len and is_space_or_tab(text.byte_at(k)):
        k += 1
    if k == i:
        return false
    if k >= text.len or not identifier_head_byte(text.byte_at(k)):
        return false

    var m = k + 1
    while m < text.len and identifier_tail_byte(text.byte_at(m)):
        m += 1
    return slice_span(text, k, m).equal("function")


## Host `external_or_foreign_function_header_line?`.
function external_or_foreign_function_header_line(line: str) -> bool:
    let stripped = line.trim_ascii_whitespace()
    var i: ptr_uint = 0
    while i < stripped.len:
        if not identifier_head_byte(stripped.byte_at(i)):
            return false
        let word_start = i
        i += 1
        while i < stripped.len and identifier_tail_byte(stripped.byte_at(i)):
            i += 1

        let word = slice_span(stripped, word_start, i)
        if word.equal("external") or word.equal("foreign"):
            return word_followed_by_function(stripped, word_start)

        if i >= stripped.len or not is_space_or_tab(stripped.byte_at(i)):
            return false
        while i < stripped.len and is_space_or_tab(stripped.byte_at(i)):
            i += 1
    return false


function line_inside_external_or_foreign_function_header(lines: vec.Vec[str], line_index: ptr_uint) -> bool:
    var cursor = line_index + 1
    while cursor > 0:
        cursor -= 1
        let line = line_at(lines, cursor) else:
            break
        if external_or_foreign_function_header_line(line):
            return line_in_function_header_span(lines, cursor, line_index)
        if function_line(line):
            break
    return false


## Host `fn_type_signature_start_line?`.
function fn_type_signature_start_line(line: str) -> bool:
    let stripped = line.trim_ascii_whitespace()
    if stripped.len == 0:
        return false

    if stripped.starts_with("type"):
        var i: ptr_uint = 4
        if i < stripped.len and is_space_or_tab(stripped.byte_at(i)):
            while i < stripped.len and is_space_or_tab(stripped.byte_at(i)):
                i += 1
            if i >= stripped.len or not identifier_head_byte(stripped.byte_at(i)):
                return false
            i += 1
            while i < stripped.len and identifier_tail_byte(stripped.byte_at(i)):
                i += 1
            while i < stripped.len and is_space_or_tab(stripped.byte_at(i)):
                i += 1
            if i >= stripped.len or stripped.byte_at(i) != '=':
                return false
            i += 1
            while i < stripped.len and is_space_or_tab(stripped.byte_at(i)):
                i += 1
            return fn_keyword_then_lparen(stripped, i)

    if not identifier_head_byte(stripped.byte_at(0)):
        return false
    var i: ptr_uint = 1
    while i < stripped.len and identifier_tail_byte(stripped.byte_at(i)):
        i += 1
    while i < stripped.len and is_space_or_tab(stripped.byte_at(i)):
        i += 1
    if i >= stripped.len or stripped.byte_at(i) != ':':
        return false
    i += 1
    while i < stripped.len and is_space_or_tab(stripped.byte_at(i)):
        i += 1
    return fn_keyword_then_lparen(stripped, i)


function fn_keyword_then_lparen(text: str, index: ptr_uint) -> bool:
    if index + 2 > text.len:
        return false
    if text.byte_at(index) != 'f' or text.byte_at(index + 1) != 'n':
        return false
    var i = index + 2
    while i < text.len and is_space_or_tab(text.byte_at(i)):
        i += 1
    return i < text.len and text.byte_at(i) == '('


function line_inside_fn_type_signature(lines: vec.Vec[str], line_index: ptr_uint) -> bool:
    var cursor = line_index + 1
    while cursor > 0:
        cursor -= 1
        let line = line_at(lines, cursor) else:
            break
        if fn_type_signature_start_line(line):
            return line_in_function_header_span(lines, cursor, line_index)
        if function_line(line) or external_or_foreign_function_header_line(line):
            break
    return false


function extending_block_header_line(line: str) -> bool:
    let stripped = line.trim_ascii_whitespace()
    if not stripped.ends_with(":"):
        return false
    return stripped.starts_with("extending ")


function interface_block_header_line(line: str) -> bool:
    let stripped = line.trim_ascii_whitespace()
    if not stripped.ends_with(":"):
        return false
    return stripped.starts_with("interface ")


function line_is_import(line: str) -> bool:
    return line.trim_ascii_whitespace().starts_with("import ")


function line_is_comment(line: str) -> bool:
    return line.trim_ascii_whitespace().starts_with("#")


function attribute_application_line(line: str) -> bool:
    return line.trim_ascii_whitespace().starts_with("@[")


function attribute_application_end_line(lines: vec.Vec[str], start_index: ptr_uint) -> Option[ptr_uint]:
    let start_line = line_at(lines, start_index) else:
        return Option[ptr_uint].none
    if not attribute_application_line(start_line):
        return Option[ptr_uint].none

    var depth: int = 0
    var open_seen = false
    var index = start_index

    while index < lines.len():
        let text = line_at(lines, index) else:
            break
        var char_index: ptr_uint = 0
        while char_index < text.len:
            let b = text.byte_at(char_index)
            if b == '[':
                depth += 1
                open_seen = true
            else if b == ']' and depth > 0:
                depth -= 1
                if open_seen and depth == 0:
                    return Option[ptr_uint].some(value = index)
            char_index += 1
        index += 1

    return Option[ptr_uint].none


function line_inside_attribute_application(lines: vec.Vec[str], line_index: ptr_uint) -> bool:
    var cursor = line_index + 1
    while cursor > 0:
        cursor -= 1
        let line = line_at(lines, cursor) else:
            break
        if attribute_application_line(line):
            let end_index = attribute_application_end_line(lines, cursor) else:
                return false
            return line_index <= end_index
        if function_line(line):
            break
    return false


function top_level_function_attached_to_attribute_start(lines: vec.Vec[str], line_index: ptr_uint) -> Option[ptr_uint]:
    let line = line_at(lines, line_index) else:
        return Option[ptr_uint].none
    if leading_indent_width(line) != 0:
        return Option[ptr_uint].none
    if not attribute_application_line(line):
        return Option[ptr_uint].none
    if line_index > 0 and line_inside_attribute_application(lines, line_index - 1):
        return Option[ptr_uint].none

    var cursor = line_index
    while true:
        let end_index = attribute_application_end_line(lines, cursor) else:
            return Option[ptr_uint].none
        cursor = end_index + 1
        while cursor < lines.len():
            let candidate = line_at(lines, cursor) else:
                break
            if not blank_line(candidate):
                break
            cursor += 1
        if cursor >= lines.len():
            return Option[ptr_uint].none

        let next_line = line_at(lines, cursor) else:
            return Option[ptr_uint].none
        if attribute_application_line(next_line) and leading_indent_width(next_line) == 0:
            continue

        if function_line(next_line) and leading_indent_width(next_line) == 0:
            return Option[ptr_uint].some(value = cursor)

        return Option[ptr_uint].none

    return Option[ptr_uint].none


function first_identifier(text: str) -> str:
    if text.len == 0 or not identifier_head_byte(text.byte_at(0)):
        return ""
    var i: ptr_uint = 1
    while i < text.len and identifier_tail_byte(text.byte_at(i)):
        i += 1
    return slice_span(text, 0, i)


## Host `top_level_declaration_group`.
function top_level_declaration_group(line: str) -> Option[DeclGroup]:
    let stripped = line.trim_ascii_whitespace()
    if stripped.len == 0:
        return Option[DeclGroup].none
    if leading_indent_width(line) != 0:
        return Option[DeclGroup].none

    let first = first_identifier(stripped)
    if first.len == 0:
        return Option[DeclGroup].none

    if first.equal("link") or first.equal("include") or first.equal("compiler_flag"):
        return Option[DeclGroup].some(value = DeclGroup.directive)
    if first.equal("opaque"):
        return Option[DeclGroup].some(value = DeclGroup.opaque_decl)
    if first.equal("type"):
        return Option[DeclGroup].some(value = DeclGroup.type_decl)
    if first.equal("struct"):
        return Option[DeclGroup].some(value = DeclGroup.struct_decl)
    if first.equal("union"):
        return Option[DeclGroup].some(value = DeclGroup.union_decl)
    if first.equal("variant"):
        return Option[DeclGroup].some(value = DeclGroup.variant_decl)
    if first.equal("enum"):
        return Option[DeclGroup].some(value = DeclGroup.enum_decl)
    if first.equal("flags"):
        return Option[DeclGroup].some(value = DeclGroup.flags_decl)
    if first.equal("const"):
        return Option[DeclGroup].some(value = DeclGroup.const_decl)
    if first.equal("var"):
        return Option[DeclGroup].some(value = DeclGroup.var_decl)
    if first.equal("external"):
        if word_followed_by_function(stripped, 0):
            return Option[DeclGroup].some(value = DeclGroup.external_function)
        return Option[DeclGroup].some(value = DeclGroup.external_decl)
    return Option[DeclGroup].none


# =============================================================================
#  Blank-line normalization (host 225-316)
# =============================================================================

public function normalize_blank_lines(source: str) -> string.String:
    var lines = split_lines_chomp(source)
    defer: lines.release()

    var result = vec.Vec[str].create()
    defer: result.release()

    var blank_run: ptr_uint = 0
    var emitted_content = false
    var previous_content_line: str = ""
    var previous_content_index: Option[ptr_uint] = Option[ptr_uint].none
    var previous_group: Option[DeclGroup] = Option[DeclGroup].none
    var previous_was_bodyful_function = false
    var previous_was_comment = false

    var line_index: ptr_uint = 0
    while line_index < lines.len():
        let line = line_at(lines, line_index) else:
            break

        if blank_line(line):
            blank_run += 1
        else:
            let current_group = top_level_declaration_group(line)
            let decorated = top_level_function_attached_to_attribute_start(lines, line_index)

            if emitted_content:
                var needed: ptr_uint = 0
                if decorated.is_some():
                    if bodyless_function_header_at(lines, decorated.unwrap()):
                        needed = 1
                    else:
                        needed = 2
                else if previous_content_index.is_some() and line_inside_attribute_application(lines, previous_content_index.unwrap()):
                    needed = 0
                else if extending_block_header_line(line):
                    if previous_was_comment:
                        needed = 1
                    else:
                        needed = 2
                else if function_line(line):
                    if bodyless_function_header_at(lines, line_index):
                        if previous_content_index.is_some() and line_inside_bodyless_function_header(lines, previous_content_index.unwrap()):
                            needed = 0
                        else if interface_block_header_line(previous_content_line):
                            needed = 0
                        else:
                            needed = 1
                    else if extending_block_header_line(previous_content_line):
                        needed = 0
                    else if previous_was_comment:
                        needed = 1
                    else if previous_was_bodyful_function:
                        needed = 2
                    else:
                        needed = 2
                else if current_group.is_some():
                    let group = current_group.unwrap()
                    if group == DeclGroup.struct_decl and previous_group.is_some() and previous_group.unwrap() == DeclGroup.struct_decl:
                        needed = 1
                    else if group == DeclGroup.enum_decl and previous_group.is_some() and previous_group.unwrap() == DeclGroup.enum_decl:
                        needed = 1
                    else if group == DeclGroup.union_decl and previous_group.is_some() and previous_group.unwrap() == DeclGroup.union_decl:
                        needed = 1
                    else if previous_group.is_some() and group != previous_group.unwrap():
                        needed = 1
                    else if blank_run < 1:
                        needed = blank_run
                    else:
                        needed = 1
                else:
                    if blank_run < 1:
                        needed = blank_run
                    else:
                        needed = 1

                var emitted_blank: ptr_uint = 0
                while emitted_blank < needed:
                    result.push("")
                    emitted_blank += 1

            result.push(line)
            blank_run = 0
            emitted_content = true
            previous_content_line = line
            previous_content_index = Option[ptr_uint].some(value = line_index)
            let line_group = top_level_declaration_group(line)
            if line_group.is_some():
                previous_group = line_group

            if decorated.is_some():
                if not bodyless_function_header_at(lines, decorated.unwrap()):
                    previous_was_bodyful_function = true
            else if function_line(line) and not bodyless_function_header_at(lines, line_index):
                previous_was_bodyful_function = true
            else if line_group.is_some() or extending_block_header_line(line) or interface_block_header_line(line) or line_is_import(line) or line_is_comment(line):
                previous_was_bodyful_function = false

            previous_was_comment = line_is_comment(line)

        line_index += 1

    if result.len() == 0:
        return string.String.create()

    return join_lines_with_newlines(result)


# =============================================================================
#  Long-line wrapping (host 71-216 + 623-778)
# =============================================================================

struct WrapCandidate:
    depth: ptr_uint
    start_char: ptr_uint
    end_char: ptr_uint
    opening_delimiter: str
    closing_delimiter: str
    arguments: vec.Vec[str]


struct ChainCandidate:
    start_char: ptr_uint
    end_char: ptr_uint
    operators: vec.Vec[str]
    segments: vec.Vec[str]


struct DelimiterEntry:
    kind: tk.TokenKind
    index: ptr_uint
    depth: ptr_uint


public struct WrapFix:
    line_index: ptr_uint
    new_text: string.String


function is_trivia_token_kind(kind: tk.TokenKind) -> bool:
    return kind == tk.TokenKind.newline or kind == tk.TokenKind.indent or kind == tk.TokenKind.dedent or kind == tk.TokenKind.eof


function non_trivia_tokens_on_line(tokens: vec.Vec[tok.Token], line_number: ptr_uint) -> vec.Vec[tok.Token]:
    var collected = vec.Vec[tok.Token].create()
    var i: ptr_uint = 0
    while i < tokens.len():
        let entry = tokens.get(i) else:
            break
        let token = unsafe: read(entry)
        if token.line == line_number and not is_trivia_token_kind(token.kind):
            collected.push(token)
        i += 1
    return collected


## Host `wrappable_long_line_candidate_text?`: the line has a delimiter or a
## logical chain to wrap.  Also the linter's `line-too-long` gate.
public function wrappable_long_line_candidate_text(line: str) -> bool:
    if line.contains_substring("(") or line.contains_substring("["):
        return true
    return line.contains_substring(" and ") or line.contains_substring(" or ")


# =============================================================================
#  Single-line wrap fixes (linter `line-too-long` and the LSP quickfix)
# =============================================================================

## The wrap fix for one line of `source` (0-based `line_index`), or none.
## `validate` mirrors the host's flag: the linter only asks whether a fix
## exists (`validate = false`), the editor quickfix needs a fix that parses.
public function build_long_line_wrap_fix(
    source: str,
    line_index: ptr_uint,
    max_line_length: ptr_uint,
    path: str,
    validate: bool,
) -> Option[WrapFix]:
    var tokens = lexer.lex(source)
    defer: tokens.release()
    return build_line_wrap_fix_with_tokens(source, tokens, line_index, max_line_length, path, validate)


## `build_long_line_wrap_fix` with the caller's already-lexed tokens.
public function build_line_wrap_fix_with_tokens(
    source: str,
    tokens: vec.Vec[tok.Token],
    line_index: ptr_uint,
    max_line_length: ptr_uint,
    path: str,
    validate: bool,
) -> Option[WrapFix]:
    if max_line_length == 0:
        return Option[WrapFix].none
    var lines = split_lines_keep(source)
    defer: lines.release()
    let original_line = line_at(lines, line_index) else:
        return Option[WrapFix].none
    let line = strip_trailing_newline(original_line)
    return build_wrap_fix_from_parts(lines, line_index, line, original_line, max_line_length, tokens, validate)


## Collapse long delimited argument lists / logical chains onto continuation
## lines; ports `wrap_long_argument_lists`.
public function wrap_long_argument_lists(source: str, max_line_length: ptr_uint, path: str) -> string.String:
    var current = string.String.create()
    current.append(source)
    if max_line_length == 0:
        return current

    var iterations: ptr_uint = 0
    while iterations < MAX_WRAP_ITERATIONS:
        iterations += 1

        let text = current.as_str()
        var lines = split_lines_keep(text)
        let maybe_fix = find_wrap_fix(text, lines, max_line_length, path)
        if maybe_fix.is_none():
            lines.release()
            break

        var fix = maybe_fix.unwrap()
        var updated = replace_line(lines, fix.line_index, fix.new_text.as_str())
        fix.new_text.release()
        lines.release()

        let unchanged = updated.as_str().equal(text)
        current.release()
        current = updated
        if unchanged:
            break

    if current.as_str().equal(source):
        return current

    # The host re-validates the wrapped text and falls back to the input.
    var diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer: diags.release()
    var _file = parser.parse_source(current.as_str(), ref_of(diags))
    if diags.len() > 0:
        current.release()
        var fallback = string.String.create()
        fallback.append(source)
        return fallback

    return current


function find_wrap_fix(text: str, lines: vec.Vec[str], max_line_length: ptr_uint, path: str) -> Option[WrapFix]:
    var tokens = lexer.lex(text)
    defer: tokens.release()

    var line_index: ptr_uint = 0
    while line_index < lines.len():
        let original_line = line_at(lines, line_index) else:
            break
        let line = strip_trailing_newline(original_line)
        if utf8_char_count(line) > max_line_length:
            let fix = build_wrap_fix_from_parts(lines, line_index, line, original_line, max_line_length, tokens, true)
            if fix.is_some():
                return fix
        line_index += 1

    return Option[WrapFix].none


function build_wrap_fix_from_parts(
    lines: vec.Vec[str],
    line_index: ptr_uint,
    line: str,
    original_line: str,
    max_line_length: ptr_uint,
    tokens: vec.Vec[tok.Token],
    validate: bool,
) -> Option[WrapFix]:
    if max_line_length == 0:
        return Option[WrapFix].none
    if line_inside_external_or_foreign_function_header(lines, line_index):
        return Option[WrapFix].none
    if line_inside_fn_type_signature(lines, line_index):
        return Option[WrapFix].none
    if utf8_char_count(line) <= max_line_length:
        return Option[WrapFix].none
    if not wrappable_long_line_candidate_text(line):
        return Option[WrapFix].none

    var line_tokens = non_trivia_tokens_on_line(tokens, line_index + 1)
    defer: line_tokens.release()

    let indent = leading_indent_text(line)
    var item_indent = string.String.create()
    defer: item_indent.release()
    item_indent.append(indent)
    item_indent.append("    ")
    let line_terminator = if original_line.ends_with("\n"): "\n" else: ""

    var candidates = long_line_wrap_candidates(line, line_tokens)
    defer: release_wrap_candidates(ref_of(candidates))

    if candidates.len() > 0:
        sort_wrap_candidates(ref_of(candidates))
        var candidate_index: ptr_uint = 0
        while candidate_index < candidates.len():
            let candidate_entry = candidates.get(candidate_index) else:
                break
            let candidate = unsafe: read(candidate_entry)
            var new_text = build_wrapped_delimited_group_text(line, candidate, indent, item_indent.as_str(), line_terminator)
            if new_text.as_str().equal(original_line):
                new_text.release()
                candidate_index += 1
                continue

            if (not validate) or validate_wrap(lines, line_index, new_text.as_str()):
                return Option[WrapFix].some(value = WrapFix(line_index = line_index, new_text = new_text))

            new_text.release()
            candidate_index += 1

    return build_wrapped_logical_chain_fix(lines, line_index, line, line_tokens, line_terminator, validate)


## Host `Parser.parse(updated_lines.join, path:)` validation inside the wrap
## candidate loop: a candidate that does not parse is skipped.
function validate_wrap(lines: vec.Vec[str], line_index: ptr_uint, new_text: str) -> bool:
    var updated = replace_line(lines, line_index, new_text)
    defer: updated.release()

    var diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer: diags.release()
    var _file = parser.parse_source(updated.as_str(), ref_of(diags))
    return diags.len() == 0


function release_wrap_candidates(candidates: ref[vec.Vec[WrapCandidate]]) -> void:
    var i: ptr_uint = 0
    while i < candidates.len():
        let entry = candidates.get(i) else:
            break
        var candidate = unsafe: read(entry)
        candidate.arguments.release()
        i += 1
    candidates.release()


## Host `sort_by { |entry| [-(end_char - start_char), depth] }`, widest first
## then shallowest.  Insertion sort keeps equal keys in discovery order, which
## is what the host's sort does for the small candidate lists a line produces.
function wrap_candidate_order(left: WrapCandidate, right: WrapCandidate) -> int:
    let left_width = left.end_char - left.start_char
    let right_width = right.end_char - right.start_char
    if left_width > right_width:
        return -1
    if left_width < right_width:
        return 1
    if left.depth < right.depth:
        return -1
    if left.depth > right.depth:
        return 1
    return 0


function sort_wrap_candidates(candidates: ref[vec.Vec[WrapCandidate]]) -> void:
    var i: ptr_uint = 1
    while i < candidates.len():
        let key_entry = candidates.get(i) else:
            break
        let key = unsafe: read(key_entry)

        var j = i
        while j > 0:
            let previous_entry = candidates.get(j - 1) else:
                break
            let previous = unsafe: read(previous_entry)
            if wrap_candidate_order(previous, key) <= 0:
                break
            let shift_target = candidates.get(j) else:
                break
            unsafe:
                read(shift_target) = previous
            j -= 1

        let insert_target = candidates.get(j) else:
            break
        unsafe:
            read(insert_target) = key
        i += 1


function matching_delimiter_pair(opening_kind: tk.TokenKind, closing_kind: tk.TokenKind) -> bool:
    if opening_kind == tk.TokenKind.lparen and closing_kind == tk.TokenKind.rparen:
        return true
    return opening_kind == tk.TokenKind.lbracket and closing_kind == tk.TokenKind.rbracket


function long_line_wrap_candidates(line: str, line_tokens: vec.Vec[tok.Token]) -> vec.Vec[WrapCandidate]:
    var stack = vec.Vec[DelimiterEntry].create()
    defer: stack.release()
    var candidates = vec.Vec[WrapCandidate].create()

    var index: ptr_uint = 0
    while index < line_tokens.len():
        let entry = line_tokens.get(index) else:
            break
        let token = unsafe: read(entry)

        if token.kind == tk.TokenKind.lparen or token.kind == tk.TokenKind.lbracket:
            stack.push(DelimiterEntry(kind = token.kind, index = index, depth = stack.len()))
        else if token.kind == tk.TokenKind.rparen or token.kind == tk.TokenKind.rbracket:
            let opening_option = stack.pop()
            if opening_option.is_some():
                let opening = opening_option.unwrap()
                if matching_delimiter_pair(opening.kind, token.kind):
                    let candidate = build_long_line_wrap_candidate(line, line_tokens, opening.index, index, opening.depth)
                    if candidate.is_some():
                        candidates.push(candidate.unwrap())
        index += 1

    return candidates


function build_long_line_wrap_candidate(
    line: str,
    line_tokens: vec.Vec[tok.Token],
    open_index: ptr_uint,
    close_index: ptr_uint,
    depth: ptr_uint,
) -> Option[WrapCandidate]:
    let open_entry = line_tokens.get(open_index) else:
        return Option[WrapCandidate].none
    let close_entry = line_tokens.get(close_index) else:
        return Option[WrapCandidate].none
    let open_token = unsafe: read(open_entry)
    let close_token = unsafe: read(close_entry)

    var nested_group_depth: int = 0
    var comma_indexes = vec.Vec[ptr_uint].create()
    defer: comma_indexes.release()

    var index = open_index + 1
    while index < close_index:
        let token_entry = line_tokens.get(index) else:
            break
        let token = unsafe: read(token_entry)
        if token.kind == tk.TokenKind.lparen or token.kind == tk.TokenKind.lbracket:
            nested_group_depth += 1
        else if token.kind == tk.TokenKind.rparen or token.kind == tk.TokenKind.rbracket:
            if nested_group_depth > 0:
                nested_group_depth -= 1
        else if token.kind == tk.TokenKind.comma:
            if nested_group_depth == 0 and token.line == open_token.line:
                comma_indexes.push(index)
        index += 1

    if comma_indexes.len() == 0:
        return Option[WrapCandidate].none

    let start_char = open_token.column - 1
    let end_char = close_token.column
    var current_start = start_char + 1
    var arguments = vec.Vec[str].create()

    var comma_index: ptr_uint = 0
    while comma_index < comma_indexes.len():
        let comma_entry = comma_indexes.get(comma_index) else:
            break
        let comma_token_index = unsafe: read(comma_entry)
        let comma_token_entry = line_tokens.get(comma_token_index) else:
            break
        let comma_token = unsafe: read(comma_token_entry)
        let argument = char_slice(line, current_start, comma_token.column - 1).trim_ascii_whitespace()
        if argument.len == 0:
            arguments.release()
            return Option[WrapCandidate].none
        arguments.push(argument)
        current_start = comma_token.column
        comma_index += 1

    let final_argument = char_slice(line, current_start, close_token.column - 1).trim_ascii_whitespace()
    if final_argument.len == 0:
        arguments.release()
        return Option[WrapCandidate].none
    arguments.push(final_argument)

    return Option[WrapCandidate].some(
        value = WrapCandidate(
            depth = depth,
            start_char = start_char,
            end_char = end_char,
            opening_delimiter = slice_span(line, open_token.column - 1, open_token.end_offset - open_token.start_offset + open_token.column - 1),
            closing_delimiter = slice_span(line, close_token.column - 1, close_token.end_offset - close_token.start_offset + close_token.column - 1),
            arguments = arguments,
        ),
    )


function build_wrapped_delimited_group_text(
    line: str,
    candidate: WrapCandidate,
    indent: str,
    item_indent: str,
    line_terminator: str,
) -> string.String:
    var output = string.String.create()
    append_to(ref_of(output), char_slice(line, 0, candidate.start_char))
    append_to(ref_of(output), candidate.opening_delimiter)
    append_to(ref_of(output), "\n")

    var index: ptr_uint = 0
    while index < candidate.arguments.len():
        let argument_entry = candidate.arguments.get(index) else:
            break
        append_to(ref_of(output), item_indent)
        append_to(ref_of(output), unsafe: read(argument_entry))
        if index + 1 < candidate.arguments.len():
            append_to(ref_of(output), ",")
        append_to(ref_of(output), "\n")
        index += 1

    append_to(ref_of(output), indent)
    append_to(ref_of(output), candidate.closing_delimiter)
    append_to(ref_of(output), char_slice_from(line, candidate.end_char))
    append_to(ref_of(output), line_terminator)
    return output


function build_wrapped_logical_chain_fix(
    lines: vec.Vec[str],
    line_index: ptr_uint,
    line: str,
    line_tokens: vec.Vec[tok.Token],
    line_terminator: str,
    validate: bool,
) -> Option[WrapFix]:
    let maybe_candidate = logical_chain_wrap_candidate(line, line_tokens)
    if maybe_candidate.is_none():
        return Option[WrapFix].none
    var candidate = maybe_candidate.unwrap()
    defer: release_chain_candidate(ref_of(candidate))

    let indent = leading_indent_text(line)
    var item_indent = string.String.create()
    defer: item_indent.release()
    item_indent.append(indent)
    item_indent.append("    ")

    var new_text = build_wrapped_logical_chain_text(line, candidate, indent, item_indent.as_str(), line_terminator)
    let original_entry = lines.get(line_index) else:
        new_text.release()
        return Option[WrapFix].none
    if new_text.as_str().equal(unsafe: read(original_entry)):
        new_text.release()
        return Option[WrapFix].none

    if validate and not validate_wrap(lines, line_index, new_text.as_str()):
        new_text.release()
        return Option[WrapFix].none

    return Option[WrapFix].some(value = WrapFix(line_index = line_index, new_text = new_text))


function release_chain_candidate(candidate: ref[ChainCandidate]) -> void:
    candidate.operators.release()
    candidate.segments.release()


function build_wrapped_logical_chain_text(
    line: str,
    candidate: ChainCandidate,
    indent: str,
    item_indent: str,
    line_terminator: str,
) -> string.String:
    var output = string.String.create()
    append_to(ref_of(output), char_slice(line, 0, candidate.start_char))
    append_to(ref_of(output), "(\n")

    let first_segment_entry = candidate.segments.get(0) else:
        return output
    append_to(ref_of(output), item_indent)
    append_to(ref_of(output), unsafe: read(first_segment_entry))
    append_to(ref_of(output), "\n")

    var index: ptr_uint = 0
    while index < candidate.operators.len():
        let operator_entry = candidate.operators.get(index) else:
            break
        let segment_entry = candidate.segments.get(index + 1) else:
            break
        append_to(ref_of(output), item_indent)
        append_to(ref_of(output), unsafe: read(operator_entry))
        append_to(ref_of(output), " ")
        append_to(ref_of(output), unsafe: read(segment_entry))
        append_to(ref_of(output), "\n")
        index += 1

    append_to(ref_of(output), indent)
    append_to(ref_of(output), ")")
    append_to(ref_of(output), char_slice_from(line, candidate.end_char))
    append_to(ref_of(output), line_terminator)
    return output


function logical_chain_wrap_candidate(line: str, line_tokens: vec.Vec[tok.Token]) -> Option[ChainCandidate]:
    if line_tokens.len() < 4:
        return Option[ChainCandidate].none

    let first_token_entry = line_tokens.get(0) else:
        return Option[ChainCandidate].none
    let first_token = unsafe: read(first_token_entry)
    var header_length: ptr_uint = 0
    if first_token.kind == tk.TokenKind.tk_if or first_token.kind == tk.TokenKind.tk_while:
        header_length = 1
    else if first_token.kind == tk.TokenKind.tk_else:
        let second_token_entry = line_tokens.get(1) else:
            return Option[ChainCandidate].none
        if unsafe: read(second_token_entry).kind == tk.TokenKind.tk_if:
            header_length = 2
        else:
            header_length = 0
    if header_length == 0:
        return Option[ChainCandidate].none

    var colon_index_option: Option[ptr_uint] = Option[ptr_uint].none
    var reverse_index = line_tokens.len()
    while reverse_index > 0:
        reverse_index -= 1
        let token_entry = line_tokens.get(reverse_index) else:
            break
        let token = unsafe: read(token_entry)
        if token.kind == tk.TokenKind.colon:
            colon_index_option = Option[ptr_uint].some(value = reverse_index)
            break
    if colon_index_option.is_none():
        return Option[ChainCandidate].none
    let colon_index = colon_index_option.unwrap()

    let colon_token_entry = line_tokens.get(colon_index) else:
        return Option[ChainCandidate].none
    let colon_token = unsafe: read(colon_token_entry)

    let expression_start_token_entry = line_tokens.get(header_length) else:
        return Option[ChainCandidate].none
    let expression_start_token = unsafe: read(expression_start_token_entry)
    let start_char = expression_start_token.column - 1
    if char_at(line, start_char) == '(':
        return Option[ChainCandidate].none

    var nested_group_depth: int = 0
    var operators = vec.Vec[str].create()
    var segments = vec.Vec[str].create()
    var current_start = start_char

    var index = header_length
    while index < colon_index:
        let token_entry = line_tokens.get(index) else:
            break
        let token = unsafe: read(token_entry)
        if token.kind == tk.TokenKind.lparen or token.kind == tk.TokenKind.lbracket:
            nested_group_depth += 1
        else if token.kind == tk.TokenKind.rparen or token.kind == tk.TokenKind.rbracket:
            if nested_group_depth > 0:
                nested_group_depth -= 1
        else if token.kind == tk.TokenKind.tk_and or token.kind == tk.TokenKind.tk_or:
            if nested_group_depth == 0:
                let segment_text = char_slice(line, current_start, token.column - 1).trim_ascii_whitespace()
                if segment_text.len == 0:
                    operators.release()
                    segments.release()
                    return Option[ChainCandidate].none
                segments.push(segment_text)
                let operator_start = token.column - 1
                let operator_length = token.end_offset - token.start_offset
                operators.push(slice_span(line, operator_start, operator_start + operator_length))
                current_start = operator_start + operator_length
        index += 1

    if operators.len() == 0:
        operators.release()
        segments.release()
        return Option[ChainCandidate].none

    let final_segment = char_slice(line, current_start, colon_token.column - 1).trim_ascii_whitespace()
    if final_segment.len == 0:
        operators.release()
        segments.release()
        return Option[ChainCandidate].none
    segments.push(final_segment)

    return Option[ChainCandidate].some(
        value = ChainCandidate(
            start_char = start_char,
            end_char = colon_token.column - 1,
            operators = operators,
            segments = segments,
        ),
    )
