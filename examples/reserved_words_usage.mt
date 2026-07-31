## Comprehensive reserved-word usage demo
##
## Exercises all contexts where keywords/reserved words are accepted
## as names.  Should parse, type-check, and lower to C without errors.
##
## Contexts:
##   1. Variant arm names
##   2. Struct field names (declaration)
##   3. Union field names
##   4. Enum member names
##   5. Variant payload field names
##   6. Lifetime parameter names
##   7. Type parameter names
##   8. Named arguments in struct/variant literals
##   9. Match arm extraction
##  10. Import paths and aliases
##
## Keywords NOT used inside struct bodies (parse conflicts):
##   struct, union, event, public — these have parser-level special
##   handling inside struct member positions.

# =============================================================================
# 10  Imports — keywords as import path components and aliases
# =============================================================================

import std.option as opt
import std.result as res
import std.str as str

public function use_imports(value: int) -> str:
    if value < 0:
        return "none"
    return "done"

# =============================================================================
# 1  Variant arm names — keywords as arm names
# =============================================================================

public variant AST:
    return(val: int)
    let(name: str, init: int)
    var(name: str, init: int)
    type(inner: str)
    function(name: str, body: int)
    if(cond: int, then: int, else: int)
    else(value: int)
    while(cond: int, body: int)
    for(binding: str, it: int, body: int)
    match(scrutinee: int, arms: int)
    enum(members: int)
    variant(arms: int)
    const(value: int)
    opaque(handle: int)
    interface(methods: int)
    extending(base: int)
    external(symbol: str)
    async(promise: int)
    when(cond: int, branch: int)
    await(target: int)
    pass
    break(value: int)
    continue(value: int)
    defer(work: int)
    unsafe(ptr: int)
    emit(code: str)
    foreign(name: str)
    inline(body: int)
    fn(sig: str)
    proc(body: int)
    is(arm: str)
    and(left: int, right: int)
    or(left: int, right: int)
    not(val: int)
    noop

# =============================================================================
# 2  Struct field names — keywords as field declarations
# =============================================================================

public struct Meta:
    return: int
    let: str
    var: str
    type: str
    function: str
    if: bool
    else: bool
    while: bool
    for: bool
    match: bool
    enum: str
    variant: str
    const: int
    opaque: int
    interface: str
    extending: str
    external: str
    async: bool
    when: str
    await: bool
    pass: bool
    break: bool
    continue: bool
    defer: bool
    unsafe: bool
    emit: str
    foreign: str
    inline: bool
    fn: str
    proc: str
    is: bool
    and: bool
    or: bool
    not: bool
    noop: bool

# =============================================================================
# 3  Union field names
# =============================================================================

public union Value:
    return: int
    let: float
    var: ptr[void]
    type: str

# =============================================================================
# 4  Enum member names
# =============================================================================

public enum Kind: int
    return = 1
    let = 2
    var = 3
    type = 4
    function = 5
    if = 6
    else = 7
    while = 8
    for = 9
    match = 10
    enum_value = 11
    variant_value = 12
    const_value = 13
    opaque_value = 14
    interface_value = 15
    async_value = 16
    when_value = 17
    unsafe_value = 18
    is_value = 19
    and_value = 20
    or_value = 21
    not_value = 22
    pass_value = 23
    fn_value = 24
    proc_value = 25
    noop_value = 26

# =============================================================================
# 5  Variant payload field names
# =============================================================================

public variant Action:
    execute(return: int, let: str, type: str, function: str)

# =============================================================================
# 6  Lifetime parameter names
# =============================================================================

struct Buffer[@return]:
    data: ref[@return, span[ubyte]]

struct DualBuffer[@let, @var]:
    a: ref[@let, span[ubyte]]
    b: ref[@var, span[ubyte]]

# =============================================================================
# 7  Type parameter names
# =============================================================================

public struct Box[return]:
    value: return

public struct Pair[let, var]:
    first: let
    second: var

public function identity[type](x: type) -> type:
    return x

public function pair_of[let, var](a: let, b: var) -> Pair[let, var]:
    return Pair[let, var](first = a, second = b)

# =============================================================================
# 8  Named arguments in struct/variant literals
# =============================================================================

public function make_meta() -> Meta:
    return Meta(
        return = 1,
        let = "hello",
        var = "world",
        type = "str",
        function = "main",
        if = true,
        else = false,
        while = false,
        for = false,
        match = false,
        enum = "Kind",
        variant = "AST",
        const = 42,
        opaque = 0,
        interface = "Shape",
        extending = "Base",
        external = "sym",
        async = false,
        when = "now",
        await = false,
        pass = true,
        break = false,
        continue = false,
        defer = false,
        unsafe = false,
        emit = "code",
        foreign = "c_fn",
        inline = false,
        fn = "fn_type",
        proc = "fn_ptr",
        is = true,
        and = true,
        or = false,
        not = true,
        noop = true
    )

# =============================================================================
# 9  Variant constructors with keyword-named arguments
# =============================================================================

public function make_ast_nodes() -> AST:
    let _retval = AST.return(val = 42)
    let _letval = AST.let(name = "x", init = 1)
    let _typeval = AST.type(inner = "int")
    let _fnval = AST.function(name = "main", body = 0)
    let _ifval = AST.if(cond = 1, then = 2, else = 0)
    let _nop = AST.noop
    return AST.noop

public function make_action() -> Action:
    return Action.execute(return = 42, let = "x", type = "int", function = "main")

# =============================================================================
# 10  Match on variant with keyword arm names
# =============================================================================

public function match_ast(node: AST) -> str:
    match node:
        AST.return as r:
            return "return"
        AST.let as l:
            return "let"
        AST.type as t:
            return t.inner
        AST.function:
            return "function"
        AST.pass:
            return "pass"
        AST.noop:
            return "noop"
        AST.is as is_val:
            return is_val.arm
        AST.and as and_val:
            return "and"
        AST.or as or_val:
            return "or"
        else:
            return "other"

# =============================================================================
# 11  Enum member access with keyword names
# =============================================================================

public function use_enum() -> Kind:
    return Kind.return

# =============================================================================
# 12  Type parameter instantiation with keywords
# =============================================================================

public function use_generics() -> int:
    return identity[int](42)

# =============================================================================
# 13  Entrypoint
# =============================================================================

function main() -> int:
    let _meta = make_meta()
    let _ast = make_ast_nodes()
    let _act = make_action()
    let _kind = use_enum()
    let _gen = use_generics()
    let _ = match_ast(AST.noop)
    return 0
