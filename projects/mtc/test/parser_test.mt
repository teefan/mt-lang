import std.str as text
import std.testing as t
import std.vec as vec
import lexer
import ast
import parser


const SRC_IMPORT: str = "import std.str as text\n"
const SRC_FUNCTION: str = "function add(a: int, b: int) -> int:\n    return a + b\n"
const SRC_STRUCT: str = "struct Point:\n    x: float\n    y: float\n"
const SRC_ENUM: str = "enum Color : int\n    red = 0\n    green = 1\n    blue = 2\n"
const SRC_CONST: str = "const ANSWER: int = 42\n"
const SRC_IF: str = "function check(x: int) -> int:\n    if x > 0:\n        return 1\n    else:\n        return 0\n"
const SRC_WHILE: str = "function loop(n: int) -> int:\n    while n > 0:\n        n = n - 1\n    return 0\n"
const SRC_FOR: str = "function each() -> int:\n    for i in (0, 10):\n        pass\n    return 0\n"
const SRC_ASSIGN: str = "function set() -> int:\n    var x = 0\n    x = 5\n    return x\n"
const SRC_DEFER: str = "function locked() -> int:\n    defer:\n        pass\n    return 0\n"
const SRC_VARIANT: str = "variant Shape\n    circle(r: float)\n    square(side: float)\n"
const SRC_OPAQUE: str = "opaque Handle\n"
const SRC_INTERFACE: str = "interface Drawable\n    draw() -> void\n"
const SRC_TYPE_ALIAS: str = "type Meters = float\n"
const SRC_VAR: str = "var global_count: int = 0\n"
const SRC_EXPR: str = "function calc(a: int, b: int) -> int:\n    let x = a + b * 2\n    return x\n"


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


function stmt_count(stmts: ref[vec.Vec[ast.Statement]]) -> ptr_uint:
    return stmts.len()


@[test]
function test_import_parsing() -> t.Check:
    var sf = lex_and_parse(SRC_IMPORT)
    t.expect(sf.imports.len() == 1, "should have 1 import")?
    sf.imports.release()
    sf.declarations.release()
    sf.exprs.exprs.release()
    return t.ok()


@[test]
function test_function_parsing() -> t.Check:
    var sf = lex_and_parse(SRC_FUNCTION)
    var decl = decl_at(ref_of(sf.declarations), 0)
    match decl:
        ast.Statement.function_decl as fd:
            t.expect(fd.name.equal("add"), "function name")?
        else:
            t.expect(false, "expected function")?
    sf.imports.release()
    sf.declarations.release()
    sf.exprs.exprs.release()
    return t.ok()


@[test]
function test_struct_parsing() -> t.Check:
    var sf = lex_and_parse(SRC_STRUCT)
    var decl = decl_at(ref_of(sf.declarations), 0)
    match decl:
        ast.Statement.struct_decl as sd:
            t.expect(sd.name.equal("Point"), "struct name")?
            t.expect(sd.fields.len() == 2, "two fields")?
        else:
            t.expect(false, "expected struct")?
    sf.imports.release()
    sf.declarations.release()
    sf.exprs.exprs.release()
    return t.ok()


@[test]
function test_enum_parsing() -> t.Check:
    var sf = lex_and_parse(SRC_ENUM)
    var decl = decl_at(ref_of(sf.declarations), 0)
    match decl:
        ast.Statement.enum_decl as ed:
            t.expect(ed.name.equal("Color"), "enum name")?
            t.expect(ed.members.len() == 3, "three members")?
        else:
            t.expect(false, "expected enum")?
    sf.imports.release()
    sf.declarations.release()
    sf.exprs.exprs.release()
    return t.ok()


@[test]
function test_const_parsing() -> t.Check:
    var sf = lex_and_parse(SRC_CONST)
    var decl = decl_at(ref_of(sf.declarations), 0)
    match decl:
        ast.Statement.const_decl as cd:
            t.expect(cd.name.equal("ANSWER"), "const name")?
        else:
            t.expect(false, "expected const")?
    sf.imports.release()
    sf.declarations.release()
    sf.exprs.exprs.release()
    return t.ok()


@[test]
function test_if_statement() -> t.Check:
    var sf = lex_and_parse(SRC_IF)
    var decl = decl_at(ref_of(sf.declarations), 0)
    match decl:
        ast.Statement.function_decl as fd:
            t.expect(stmt_count(ref_of(fd.body)) >= 1, "function has body")?
        else:
            t.expect(false, "expected function")?
    sf.imports.release()
    sf.declarations.release()
    sf.exprs.exprs.release()
    return t.ok()


@[test]
function test_while_statement() -> t.Check:
    var sf = lex_and_parse(SRC_WHILE)
    var decl = decl_at(ref_of(sf.declarations), 0)
    match decl:
        ast.Statement.function_decl as fd:
            t.expect(stmt_count(ref_of(fd.body)) >= 2, "has while + return")?
        else:
            t.expect(false, "expected function")?
    sf.imports.release()
    sf.declarations.release()
    sf.exprs.exprs.release()
    return t.ok()


@[test]
function test_for_statement() -> t.Check:
    var sf = lex_and_parse(SRC_FOR)
    var decl = decl_at(ref_of(sf.declarations), 0)
    match decl:
        ast.Statement.function_decl as fd:
            t.expect(stmt_count(ref_of(fd.body)) >= 2, "has for + return")?
        else:
            t.expect(false, "expected function")?
    sf.imports.release()
    sf.declarations.release()
    sf.exprs.exprs.release()
    return t.ok()


@[test]
function test_assign_statement() -> t.Check:
    var sf = lex_and_parse(SRC_ASSIGN)
    var decl = decl_at(ref_of(sf.declarations), 0)
    match decl:
        ast.Statement.function_decl as fd:
            t.expect(stmt_count(ref_of(fd.body)) >= 3, "has var + assign + return")?
        else:
            t.expect(false, "expected function")?
    sf.imports.release()
    sf.declarations.release()
    sf.exprs.exprs.release()
    return t.ok()


@[test]
function test_defer_statement() -> t.Check:
    var sf = lex_and_parse(SRC_DEFER)
    var decl = decl_at(ref_of(sf.declarations), 0)
    match decl:
        ast.Statement.function_decl as fd:
            t.expect(stmt_count(ref_of(fd.body)) >= 2, "has defer + return")?
        else:
            t.expect(false, "expected function")?
    sf.imports.release()
    sf.declarations.release()
    sf.exprs.exprs.release()
    return t.ok()


@[test]
function test_variant_parsing() -> t.Check:
    var sf = lex_and_parse(SRC_VARIANT)
    var decl = decl_at(ref_of(sf.declarations), 0)
    match decl:
        ast.Statement.variant_decl as vd:
            t.expect(vd.name.equal("Shape"), "variant name")?
        else:
            t.expect(false, "expected variant")?
    sf.imports.release()
    sf.declarations.release()
    sf.exprs.exprs.release()
    return t.ok()


@[test]
function test_opaque_parsing() -> t.Check:
    var sf = lex_and_parse(SRC_OPAQUE)
    var decl = decl_at(ref_of(sf.declarations), 0)
    match decl:
        ast.Statement.opaque_decl as od:
            t.expect(od.name.equal("Handle"), "opaque name")?
        else:
            t.expect(false, "expected opaque")?
    sf.imports.release()
    sf.declarations.release()
    sf.exprs.exprs.release()
    return t.ok()


@[test]
function test_interface_parsing() -> t.Check:
    var sf = lex_and_parse(SRC_INTERFACE)
    var decl = decl_at(ref_of(sf.declarations), 0)
    match decl:
        ast.Statement.interface_decl as id:
            t.expect(id.name.equal("Drawable"), "interface name")?
        else:
            t.expect(false, "expected interface")?
    sf.imports.release()
    sf.declarations.release()
    sf.exprs.exprs.release()
    return t.ok()


@[test]
function test_type_alias_parsing() -> t.Check:
    var sf = lex_and_parse(SRC_TYPE_ALIAS)
    var decl = decl_at(ref_of(sf.declarations), 0)
    match decl:
        ast.Statement.type_alias_decl as ta:
            t.expect(ta.name.equal("Meters"), "type alias name")?
        else:
            t.expect(false, "expected type alias")?
    sf.imports.release()
    sf.declarations.release()
    sf.exprs.exprs.release()
    return t.ok()


@[test]
function test_var_parsing() -> t.Check:
    var sf = lex_and_parse(SRC_VAR)
    var decl = decl_at(ref_of(sf.declarations), 0)
    match decl:
        ast.Statement.var_decl as vd:
            t.expect(vd.name.equal("global_count"), "var name")?
        else:
            t.expect(false, "expected var")?
    sf.imports.release()
    sf.declarations.release()
    sf.exprs.exprs.release()
    return t.ok()


@[test]
function test_expression_parsing() -> t.Check:
    var sf = lex_and_parse(SRC_EXPR)
    t.expect(sf.exprs.exprs.len() >= 5, "multiple expressions")?
    sf.imports.release()
    sf.declarations.release()
    sf.exprs.exprs.release()
    return t.ok()


@[test]
function test_seed_known_names() -> t.Check:
    var sf = lex_and_parse(SRC_STRUCT)
    var decl = decl_at(ref_of(sf.declarations), 0)
    match decl:
        ast.Statement.struct_decl as sd:
            t.expect(sd.name.equal("Point"), "struct found")?
        else:
            t.expect(false, "expected struct")?
    sf.imports.release()
    sf.declarations.release()
    sf.exprs.exprs.release()
    return t.ok()