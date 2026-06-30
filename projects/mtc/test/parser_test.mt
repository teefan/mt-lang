import std.str as text
import std.testing as t
import std.vec as vec
import lexer
import ast
import parser


# ── test sources ──────────────────────────────────────────────────────

const SRC_IMPORT: str = <<-SRC
import std.str as text
SRC

const SRC_FUNCTION: str = <<-SRC
function add(a: int, b: int) -> int:
    return a + b
SRC

const SRC_STRUCT: str = <<-SRC
struct Point:
    x: float
    y: float
SRC

const SRC_ENUM: str = <<-SRC
enum Color : int
    red = 0
    green = 1
    blue = 2
SRC

const SRC_CONST: str = <<-SRC
const ANSWER: int = 42
SRC

const SRC_IF: str = <<-SRC
function check(x: int) -> int:
    if x > 0:
        return 1
    else:
        return 0
SRC

const SRC_WHILE: str = <<-SRC
function loop(n: int) -> int:
    var total = 0
    while n > 0:
        n = n - 1
        total = total + 1
    return total
SRC

const SRC_FOR: str = <<-SRC
function sum_items(items: int, n: int) -> int:
    var total = 0
    for i in (0, n):
        total = total + i
    return total
SRC

const SRC_ASSIGN: str = <<-SRC
function assign() -> int:
    var x = 10
    x += 5
    return x
SRC

const SRC_DEFER: str = <<-SRC
function locked() -> int:
    defer:
        pass
    return 0
SRC

const SRC_VARIANT: str = <<-SRC
variant Shape
    circle(r: float)
    square(side: float)
SRC

const SRC_OPAQUE: str = <<-SRC
opaque Handle
SRC

const SRC_INTERFACE: str = <<-SRC
interface Serializable
    serialize() -> str
SRC

const SRC_TYPE_ALIAS: str = <<-SRC
type Meters = float
SRC

const SRC_VAR: str = <<-SRC
var global_count: int = 0
SRC

const SRC_EXPR: str = <<-SRC
function calc(a: int, b: int) -> int:
    let x = a + b * 2
    let y = -x
    return x + y
SRC


# ── helpers ───────────────────────────────────────────────────────────

function lex_and_parse(source: str) -> ast.SourceFile:
    var errors = vec.Vec[lexer.LexError].create()
    var tokens = lexer.lex(source, ref_of(errors))
    var result = parser.parse(tokens)
    errors.release()
    tokens.release()
    return result


function decl_at(decls: ref[vec.Vec[ast.Statement]], index: ptr_uint) -> ast.Statement:
    let dp = decls.get(index) else:
        fatal("parser_test: no decl at index")
    return unsafe: read(ptr[ast.Statement]<-dp)


# ── tests ─────────────────────────────────────────────────────────────

@[test]
function test_import_parsing() -> t.Check:
    var sf = lex_and_parse(SRC_IMPORT)
    t.expect(sf.imports.len() == 1, "should have 1 import")?
    t.expect(sf.exprs.exprs.len() == 0, "no expressions")?
    sf.imports.release()
    sf.declarations.release()
    sf.exprs.exprs.release()
    return t.ok()


@[test]
function test_function_parsing() -> t.Check:
    var sf = lex_and_parse(SRC_FUNCTION)
    t.expect(sf.imports.len() == 0, "no imports")?
    t.expect(sf.declarations.len() == 1, "one declaration")?
    var decl = decl_at(ref_of(sf.declarations), 0)
    t.expect(decl.kind == ast.STMT_FUNCTION, "is a function")?
    t.expect(decl.name.equal("add"), "function name is add")?
    sf.imports.release()
    sf.declarations.release()
    sf.exprs.exprs.release()
    return t.ok()


@[test]
function test_struct_parsing() -> t.Check:
    var sf = lex_and_parse(SRC_STRUCT)
    t.expect(sf.declarations.len() == 1, "one declaration")?
    var decl = decl_at(ref_of(sf.declarations), 0)
    t.expect(decl.kind == ast.STMT_STRUCT, "is a struct")?
    t.expect(decl.name.equal("Point"), "struct name is Point")?
    t.expect(decl.children.len() == 2, "two fields")?
    sf.imports.release()
    sf.declarations.release()
    sf.exprs.exprs.release()
    return t.ok()


@[test]
function test_enum_parsing() -> t.Check:
    var sf = lex_and_parse(SRC_ENUM)
    t.expect(sf.declarations.len() == 1, "one declaration")?
    var decl = decl_at(ref_of(sf.declarations), 0)
    t.expect(decl.kind == ast.STMT_ENUM, "is an enum")?
    t.expect(decl.name.equal("Color"), "enum name is Color")?
    t.expect(decl.children.len() == 3, "three members")?
    sf.imports.release()
    sf.declarations.release()
    sf.exprs.exprs.release()
    return t.ok()


@[test]
function test_const_parsing() -> t.Check:
    var sf = lex_and_parse(SRC_CONST)
    t.expect(sf.declarations.len() == 1, "one declaration")?
    var decl = decl_at(ref_of(sf.declarations), 0)
    t.expect(decl.kind == ast.STMT_CONST, "is a const")?
    t.expect(decl.name.equal("ANSWER"), "const name is ANSWER")?
    sf.imports.release()
    sf.declarations.release()
    sf.exprs.exprs.release()
    return t.ok()


@[test]
function test_if_statement() -> t.Check:
    var sf = lex_and_parse(SRC_IF)
    var decl = decl_at(ref_of(sf.declarations), 0)
    t.expect(decl.kind == ast.STMT_FUNCTION, "top is function")?
    t.expect(decl.children.len() >= 1, "function has body")?
    sf.imports.release()
    sf.declarations.release()
    sf.exprs.exprs.release()
    return t.ok()


@[test]
function test_while_statement() -> t.Check:
    var sf = lex_and_parse(SRC_WHILE)
    var decl = decl_at(ref_of(sf.declarations), 0)
    t.expect(decl.children.len() >= 3, "has let + while + return")?
    sf.imports.release()
    sf.declarations.release()
    sf.exprs.exprs.release()
    return t.ok()


@[test]
function test_for_statement() -> t.Check:
    var sf = lex_and_parse(SRC_FOR)
    var decl = decl_at(ref_of(sf.declarations), 0)
    t.expect(decl.children.len() >= 3, "has var + for + return")?
    sf.imports.release()
    sf.declarations.release()
    sf.exprs.exprs.release()
    return t.ok()


@[test]
function test_assign_statement() -> t.Check:
    var sf = lex_and_parse(SRC_ASSIGN)
    var decl = decl_at(ref_of(sf.declarations), 0)
    t.expect(decl.children.len() >= 3, "has var + assign + return")?
    sf.imports.release()
    sf.declarations.release()
    sf.exprs.exprs.release()
    return t.ok()


@[test]
function test_defer_statement() -> t.Check:
    var sf = lex_and_parse(SRC_DEFER)
    var decl = decl_at(ref_of(sf.declarations), 0)
    t.expect(decl.children.len() >= 2, "has defer + return")?
    sf.imports.release()
    sf.declarations.release()
    sf.exprs.exprs.release()
    return t.ok()


@[test]
function test_variant_parsing() -> t.Check:
    var sf = lex_and_parse(SRC_VARIANT)
    var decl = decl_at(ref_of(sf.declarations), 0)
    t.expect(decl.kind == ast.STMT_VARIANT, "is a variant")?
    t.expect(decl.name.equal("Shape"), "variant name is Shape")?
    sf.imports.release()
    sf.declarations.release()
    sf.exprs.exprs.release()
    return t.ok()


@[test]
function test_opaque_parsing() -> t.Check:
    var sf = lex_and_parse(SRC_OPAQUE)
    var decl = decl_at(ref_of(sf.declarations), 0)
    t.expect(decl.kind == ast.STMT_OPAQUE, "is an opaque")?
    t.expect(decl.name.equal("Handle"), "opaque name is Handle")?
    sf.imports.release()
    sf.declarations.release()
    sf.exprs.exprs.release()
    return t.ok()


@[test]
function test_interface_parsing() -> t.Check:
    var sf = lex_and_parse(SRC_INTERFACE)
    var decl = decl_at(ref_of(sf.declarations), 0)
    t.expect(decl.kind == ast.STMT_INTERFACE, "is an interface")?
    t.expect(decl.name.equal("Serializable"), "interface name")?
    sf.imports.release()
    sf.declarations.release()
    sf.exprs.exprs.release()
    return t.ok()


@[test]
function test_type_alias_parsing() -> t.Check:
    var sf = lex_and_parse(SRC_TYPE_ALIAS)
    var decl = decl_at(ref_of(sf.declarations), 0)
    t.expect(decl.kind == ast.STMT_TYPE_ALIAS, "is a type alias")?
    t.expect(decl.name.equal("Meters"), "type alias name")?
    sf.imports.release()
    sf.declarations.release()
    sf.exprs.exprs.release()
    return t.ok()


@[test]
function test_var_parsing() -> t.Check:
    var sf = lex_and_parse(SRC_VAR)
    var decl = decl_at(ref_of(sf.declarations), 0)
    t.expect(decl.kind == ast.STMT_VAR, "is a var")?
    t.expect(decl.name.equal("global_count"), "var name")?
    sf.imports.release()
    sf.declarations.release()
    sf.exprs.exprs.release()
    return t.ok()


@[test]
function test_expression_parsing() -> t.Check:
    var sf = lex_and_parse(SRC_EXPR)
    var decl = decl_at(ref_of(sf.declarations), 0)
    t.expect(decl.children.len() >= 3, "has let + let + return")?
    t.expect(sf.exprs.exprs.len() >= 5, "multiple expressions in pool")?
    sf.imports.release()
    sf.declarations.release()
    sf.exprs.exprs.release()
    return t.ok()


@[test]
function test_seed_known_names() -> t.Check:
    var sf = lex_and_parse(SRC_STRUCT)
    var decl = decl_at(ref_of(sf.declarations), 0)
    t.expect(decl.name.equal("Point"), "struct name found")?
    sf.imports.release()
    sf.declarations.release()
    sf.exprs.exprs.release()
    return t.ok()