## Parser regression tests.
##
## Run via: mtc test

import std.testing as t
import std.str

import lexer.lexer as lexer_mod
import parser.parser as parser_mod

# ── helpers ───────────────────────────────────────────────────────────────

function parse_and_get_decls(source: str) -> int:
    var json = parser_mod.parse_to_ast_json(source, "test")
    let output = json.as_str()
    var consts = count_substring(output, "\"$mt_type\":\"AST:ConstDecl\"")
    var funcs = count_substring(output, "\"$mt_type\":\"AST:FunctionDef\"")
    json.release()
    return int<-(consts + funcs)

function count_substring(haystack: str, needle: str) -> ptr_uint:
    var count: ptr_uint = 0
    var remaining = haystack
    while true:
        var found = remaining.find_substring(needle)
        let idx = found else:
            break
        count += 1
        remaining = remaining.slice(idx + 1, remaining.len - idx - 1)
    return count

function parse_ok(source: str) -> bool:
    var json = parser_mod.parse_to_ast_json(source, "test")
    let output = json.as_str()
    let result = output.contains_substring("\"$mt_type\":\"AST:SourceFile\"")
    json.release()
    return result

# ── basic declarations ────────────────────────────────────────────────────

@[test]
public function test_parses_function() -> t.Check:
    let source = <<-SRC
function main() -> int:
    return 0
SRC
    t.expect(parse_ok(source), "function parsing")?

    return t.ok()

@[test]
public function test_parses_const() -> t.Check:
    let source = <<-SRC
const WIDTH: int = 640
SRC
    t.expect(parse_ok(source), "const parsing")?

    return t.ok()

@[test]
public function test_parses_var() -> t.Check:
    let source = <<-SRC
var counter: int = 0
SRC
    t.expect(parse_ok(source), "var parsing")?

    return t.ok()

@[test]
public function test_parses_type_alias() -> t.Check:
    let source = <<-SRC
type Seconds = float
SRC
    t.expect(parse_ok(source), "type alias parsing")?

    return t.ok()

@[test]
public function test_parses_struct() -> t.Check:
    let source = <<-SRC
struct Vec2:
    x: float
    y: float
SRC
    t.expect(parse_ok(source), "struct parsing")?

    return t.ok()

@[test]
public function test_parses_enum() -> t.Check:
    let source = <<-SRC
enum Color: ubyte
    red = 1
    green = 2
    blue = 3
SRC
    t.expect(parse_ok(source), "enum parsing")?

    return t.ok()

@[test]
public function test_parses_flags() -> t.Check:
    let source = <<-SRC
flags Mask: uint
    a = 1 << 0
    b = 1 << 1
SRC
    t.expect(parse_ok(source), "flags parsing")?

    return t.ok()

@[test]
public function test_parses_union() -> t.Check:
    let source = <<-SRC
union Number:
    i: int
    f: float
SRC
    t.expect(parse_ok(source), "union parsing")?

    return t.ok()

@[test]
public function test_parses_variant() -> t.Check:
    let source = <<-SRC
variant Token:
    ident(text: str)
    number(value: int)
    eof
SRC
    t.expect(parse_ok(source), "variant parsing")?

    return t.ok()

@[test]
public function test_parses_opaque() -> t.Check:
    let source = <<-SRC
opaque RawHandle
SRC
    t.expect(parse_ok(source), "opaque parsing")?

    return t.ok()

@[test]
public function test_parses_interface() -> t.Check:
    let source = <<-SRC
interface Damageable:
    function take_damage(amount: int) -> void
    function is_alive() -> bool
SRC
    t.expect(parse_ok(source), "interface parsing")?

    return t.ok()

@[test]
public function test_parses_extending() -> t.Check:
    let source = <<-SRC
struct NPC:
    hp: int

extending NPC:
    function is_alive() -> bool:
        return true
SRC
    t.expect(parse_ok(source), "extending parsing")?

    return t.ok()

@[test]
public function test_parses_public_declaration() -> t.Check:
    let source = <<-SRC
public struct Player:
    x: float
SRC
    t.expect(parse_ok(source), "public struct parsing")?

    return t.ok()

# ── generic declarations ──────────────────────────────────────────────────

@[test]
public function test_parses_generic_struct() -> t.Check:
    let source = <<-SRC
struct Pair[A, B]:
    first: A
    second: B
SRC
    t.expect(parse_ok(source), "generic struct")?

    return t.ok()

@[test]
public function test_parses_generic_function() -> t.Check:
    let source = <<-SRC
function first[T](items: span[T]) -> ptr[T]?:
    return null
SRC
    t.expect(parse_ok(source), "generic function")?

    return t.ok()

@[test]
public function test_parses_async_function() -> t.Check:
    let source = <<-SRC
async function child() -> int:
    return 41
SRC
    t.expect(parse_ok(source), "async function")?

    return t.ok()

@[test]
public function test_parses_const_function() -> t.Check:
    let source = <<-SRC
const function square(x: int) -> int:
    return x * x
SRC
    t.expect(parse_ok(source), "const function")?

    return t.ok()

# ── extern / foreign ──────────────────────────────────────────────────────

@[test]
public function test_parses_extern_function() -> t.Check:
    let source = <<-SRC
external function atoi(input: cstr) -> int
SRC
    t.expect(parse_ok(source), "extern function")?

    return t.ok()

@[test]
public function test_parses_foreign_function() -> t.Check:
    let source = <<-SRC
foreign function init_window(width: int, height: int) -> void = c.InitWindow
SRC
    t.expect(parse_ok(source), "foreign function")?

    return t.ok()

# ── complex types ─────────────────────────────────────────────────────────

@[test]
public function test_parses_ref_param() -> t.Check:
    let source = <<-SRC
function f1(target: ref[int]) -> int:
    return 1
SRC
    t.expect(parse_ok(source), "ref[T] param")?

    return t.ok()

@[test]
public function test_parses_return_type_with_brackets() -> t.Check:
    let source = <<-SRC
function guard_demo() -> Result[int, str]:
    return Result[int, str].success(value = "ok")
SRC
    t.expect(parse_ok(source), "Result[int, str] return type")?

    return t.ok()

# ── inline body forms ─────────────────────────────────────────────────────

@[test]
public function test_parses_inline_if() -> t.Check:
    let source = <<-SRC
function f(x: int) -> int:
    if x > 0: return 1 else: return 0
SRC
    t.expect(parse_ok(source), "inline if")?

    return t.ok()

# ── attributes ────────────────────────────────────────────────────────────

@[test]
public function test_parses_attribute_declaration() -> t.Check:
    let source = <<-SRC
attribute[field] rename(name: str)
SRC
    t.expect(parse_ok(source), "attribute declaration")?

    return t.ok()

# ── when ──────────────────────────────────────────────────────────────────

@[test]
public function test_parses_module_when() -> t.Check:
    let source = <<-SRC
when true:
    const X: int = 1
SRC
    t.expect(parse_ok(source), "module when")?

    return t.ok()

# ── event ─────────────────────────────────────────────────────────────────

@[test]
public function test_parses_event() -> t.Check:
    let source = <<-SRC
event ready[4]
SRC
    t.expect(parse_ok(source), "event")?

    return t.ok()

# ── multiple declarations ─────────────────────────────────────────────────

@[test]
public function test_parses_multiple_declarations() -> t.Check:
    let source = <<-SRC
const WIDTH: int = 640
const HEIGHT: int = 480
function main() -> int:
    return 0
SRC
    let count = parse_and_get_decls(source)
    t.expect(count == 3, "three declarations")?

    return t.ok()

# ── edge cases ────────────────────────────────────────────────────────────

@[test]
public function test_parses_empty_file() -> t.Check:
    let source = ""
    t.expect(parse_ok(source), "empty file")?

    return t.ok()

@[test]
public function test_parses_comment_only() -> t.Check:
    let source = "# just a comment\n# another comment"
    t.expect(parse_ok(source), "comment only")?

    return t.ok()

@[test]
public function test_parses_function_with_many_params() -> t.Check:
    let source = <<-SRC
function configure(host: str, port: int, debug: bool) -> void:
    pass
SRC
    t.expect(parse_ok(source), "multi-param function")?

    return t.ok()
