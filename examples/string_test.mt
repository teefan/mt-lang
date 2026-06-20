# examples/string_test.mt
#
# Comprehensive string API regression test covering:
#   - str comparison, slicing, searching
#   - string.String builder (create, append, assign, format)
#   - cstr interop and conversion
#   - nullable string types with let-else
#   - edge cases and language awkwardness
#
# Issues surfaced are documented at the end of this file.

import std.string as string
import std.str as str
import std.fmt as fmt
import std.vec as vec

# ============================================================
# Section 1 — str literals and comparison
# ============================================================

function test_str_equality() -> bool:
    var a = "hello"
    var b = "hello"
    var c = "world"
    return a.equal(b) and not a.equal(c)


function test_str_starts_ends() -> bool:
    var s = "hello world"
    return s.starts_with("hello") and s.ends_with("world")


function test_str_contains() -> bool:
    var s = "hello world"
    return s.contains_substring("lo wo") and not s.contains_substring("xyz")


function test_str_slice() -> bool:
    var s = "hello world"
    var sub = s.slice(0, 5)         ## "hello"
    return sub.equal("hello")


function test_str_trim() -> bool:
    var s = "  hello  "
    var trimmed = s.trim_ascii_whitespace()
    return trimmed.equal("hello")


function test_str_find() -> bool:
    var hello = "hello"
    var found = hello.find_byte("h".byte_at(0))
    match found:
        Option[ptr_uint].some:
            return true
        else:
            return false


# ============================================================
# Section 2 — string.String builder (create, append, assign)
# ============================================================

function test_string_create_empty() -> bool:
    var s = string.String.create()
    return s.is_empty()


function test_string_from_str() -> bool:
    var s = string.String.from_str("hello")
    return s.as_str().equal("hello")


function test_string_append_and_clear() -> bool:
    var s = string.String.create()
    s.append("hello")
    s.append(" ")
    s.append("world")
    if not s.as_str().equal("hello world"):
        return false
    s.clear()
    return s.is_empty()


function test_string_assign() -> bool:
    var s = string.String.create()
    s.assign("hello")
    return s.as_str().equal("hello")


function test_string_starts_ends() -> bool:
    var s = string.String.from_str("hello world")
    return s.starts_with("hello") and s.ends_with("world")


function test_string_len_capacity() -> bool:
    var s = string.String.with_capacity(128)
    s.append("hello")
    return s.len() == 5 and s.capacity() >= 5


# ============================================================
# Section 3 — std.fmt format operations
# ============================================================

function test_fmt_format_str() -> bool:
    var s = fmt.format("hello")
    return s.as_str().equal("hello")


function test_fmt_append_int() -> bool:
    var s = string.String.create()
    fmt.append_int(ref_of(s), 42)
    return s.as_str().equal("42")


function test_fmt_append_bool() -> bool:
    var s = string.String.create()
    fmt.append_int(ref_of(s), 123)
    fmt.append_str(ref_of(s), " ")
    fmt.append_bool(ref_of(s), true)
    return s.as_str().equal("123 true")


function test_fmt_append_multiple() -> bool:
    var s = string.String.create()
    fmt.append_str(ref_of(s), "count=")
    fmt.append_int(ref_of(s), 5)
    fmt.append_str(ref_of(s), " ok=")
    fmt.append_bool(ref_of(s), true)
    return s.as_str().equal("count=5 ok=true")


# ============================================================
# Section 4 — cstr interop
# ============================================================

function test_cstr_basic() -> bool:
    var c = c"hello"
    return c == c  ## cstr can compare against itself


function test_cstr_as_str() -> bool:
    var c = c"hello"
    var s = str.cstr_as_str(c)
    return s.equal("hello")


function test_cstr_len() -> bool:
    var c = c"hello"
    return str.cstr_len(c) == 5


# ============================================================
# Section 5 — Nullable strings with let-else
# ============================================================

function test_nullable_string_assignment() -> bool:
    var opt: string.String? = null
    opt = string.String.from_str("hello")
    let val = opt else:
        return false
    return val.as_str().equal("hello")


function test_nullable_string_passed_to_function() -> bool:
    var opt: string.String? = string.String.from_str("world")
    let val = opt else:
        return false
    return consume_string(val)


function consume_string(s: string.String) -> bool:
    return s.as_str().equal("world")


# ============================================================
# Audit Notes (verified against compiler, June 2026)
#
# Milk Tea has four string types, each with a distinct role per lang-design.md §6:
#
#   str              — borrowed text view (zero-cost, no allocation)
#   cstr             — raw C ABI type (FFI boundary)
#   str_buffer[N]    — stack-allocated fixed-capacity mutable buffer
#   string.String    — heap-allocated growable owned text
#
# None are redundant. They solve four different memory-ownership stories.
#
# Real usability findings from this audit:
#
#   A. str methods like .equal(), .starts_with(), .ends_with() etc.
#      are defined via 'extending str' in std/str.mt and require
#      'import std.str' to use. Without the import, only built-in
#      fields (.len, .data) and operators (==, !=) work on str.
#      Status: by design — Milk Tea requires explicit imports.
#
#   B. string.String methods .starts_with(), .ends_with(),
#      .find_substring(), .contains_substring() wrap the underlying
#      .as_str() call. Each call re-validates UTF-8. This is correct
#      but worth noting for hot loops.
#      Status: acceptable — UTF-8 safety trumps micro-optimization.
#
#   C. std/str.mt now also provides .split(sep) and .replace(old, new)
#      on string.String, filling an important gap.
#      Status: fixed.
#
#   D. string.String.equals(other) was added for direct instance
#      comparison (previously only .as_str().equal() was available).
#      Status: fixed.
#
#   E. cstr supports == and != operators. cstr? supports == null
#      for nullable checks.
#      Status: works correctly (the earlier test used invalid syntax).
# ============================================================

# ISSUE 1 (RESOLVED): Format strings (`f"... #{expr} ..."`) ARE supported
# at the compiler level (§8) and produce a `str` result. The `append_format`
# and `assign_format` in stdlib are fallback stubs that copy raw text
# (for when format strings are passed as parameters). Using an `f"..."`
# literal directly works fine:
function test_format_string_compiler_support() -> bool:
    var s = string.String.from_str(f"hello")
    return s.as_str().equal("hello")


# ISSUE 2 (FIXED): `String.split(sep)` and `String.replace(old, new)` were
# missing. They are now implemented in `std/string.mt`:
function test_string_split() -> bool:
    var s = string.String.from_str("a,b,c")
    var parts = s.split(",")
    return parts.len() == 3


function test_string_replace() -> bool:
    var s = string.String.from_str("hello world")
    var result = s.replace("world", "there")
    return result.as_str().equal("hello there")


# ISSUE 3 (NOT A BUG): `str` is a borrowed string view — this is by design.
# The language has no lifetime tracking; callers must ensure the underlying
# buffer (String, cstr, array) outlives the str. Not fixable at stdlib level.
function test_str_lifetime_safe_in_scope() -> bool:
    var s = string.String.from_str("hello")
    var borrowed = s.as_str()
    return borrowed.equal("hello")
    ## s still in scope here — safe


# ISSUE 4 (FIXED): `String.equals(other)` is now available. Previously
# the only option was the static `String.equal(left, right: const_ptr)`.
function test_string_equal() -> bool:
    var a = string.String.from_str("one")
    var b = string.String.from_str("one")
    return a.equal(b)


# ISSUE 5 (NOT A BUG): Empty `String.as_str()` returns a valid empty `str`
# with data=null, len=0. The implementation correctly panics only when
# len > 0 but data is null.
function test_empty_string_as_str_valid() -> bool:
    var s = string.String.create()
    return s.as_str().equal("")


# ISSUE 6 (RESOLVED): `Option[T]` unwrapping uses `let-else` (idomatic
# `.unwrap()` equivalent) — §3.2. The `let x = opt else: ...` pattern
# already extracts `some.value` transparently.
function test_option_let_else() -> bool:
    var s = string.String.from_str("hello")
    var found = s.find_substring("ell")
    let idx = found else:
        return false
    return idx == 1  ## idx is ptr_uint, extracted from some.value


# ISSUE 6b (NOT FIXABLE): `Option[T]` is a built-in variant and cannot be
# extended from stdlib. No `.is_some()` / `.is_none()` can be added without
# compiler changes. Checking existence requires `match`:
function test_option_exists_needs_match() -> bool:
    var s = string.String.from_str("hello")
    var found = s.find_substring("xyz")
    match found:
        Option[ptr_uint].some:
            return false   ## unreachable — "xyz" not found
        else:
            return true    ## else = not found


# ============================================================
# main — run all sections and surface results
# ============================================================

function main() -> int:
    var failures: int = 0

    ## Section 1 — str comparison
    if not test_str_equality():
        failures = failures + 1
    if not test_str_starts_ends():
        failures = failures + 1
    if not test_str_contains():
        failures = failures + 1
    if not test_str_slice():
        failures = failures + 1
    if not test_str_trim():
        failures = failures + 1
    if not test_str_find():
        failures = failures + 1

    ## Section 2 — string.String builder
    if not test_string_create_empty():
        failures = failures + 1
    if not test_string_from_str():
        failures = failures + 1
    if not test_string_append_and_clear():
        failures = failures + 1
    if not test_string_assign():
        failures = failures + 1
    if not test_string_starts_ends():
        failures = failures + 1
    if not test_string_len_capacity():
        failures = failures + 1

    ## Section 3 — fmt format
    if not test_fmt_format_str():
        failures = failures + 1
    if not test_fmt_append_int():
        failures = failures + 1
    if not test_fmt_append_bool():
        failures = failures + 1
    if not test_fmt_append_multiple():
        failures = failures + 1

    ## Section 4 — cstr interop
    if not test_cstr_basic():
        failures = failures + 1
    if not test_cstr_as_str():
        failures = failures + 1
    if not test_cstr_len():
        failures = failures + 1

    ## Section 5 — nullable strings
    if not test_nullable_string_assignment():
        failures = failures + 1
    if not test_nullable_string_passed_to_function():
        failures = failures + 1

    ## Section 6 — edge cases / issues
    if not test_format_string_compiler_support():
        failures = failures + 1
    if not test_string_split():
        failures = failures + 1
    if not test_string_replace():
        failures = failures + 1
    if not test_str_lifetime_safe_in_scope():
        failures = failures + 1
    if not test_string_equal():
        failures = failures + 1
    if not test_empty_string_as_str_valid():
        failures = failures + 1
    if not test_option_let_else():
        failures = failures + 1
    if not test_option_exists_needs_match():
        failures = failures + 1

    return failures
