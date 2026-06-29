# POC 009 — Match statements: enum, variant, integer, str, char, is keyword,
# | shared arms, struct patterns in variant arms.

enum Kind:
    a
    b
    c

variant Token:
    ident(name: str)
    number(value: int)
    eof

struct Loc:
    x: int
    y: int

variant Entity:
    positioned(loc: Loc)
    named(label: str)

function main() -> int:
    # enum match with | shared arms
    let k = Kind.a
    match k:
        Kind.a | Kind.b:
            pass
        Kind.c:
            pass

    # variant match with as binding
    let t = Token.ident(name = "hi")
    match t:
        Token.ident(name):
            let _n = name
        Token.number as n:
            let _v = n.value
        Token.eof:
            pass

    # struct patterns in variant arms (transparent destructure)
    let e = Entity.positioned(loc = Loc(x = 1, y = 2))
    match e:
        Entity.positioned(x, y):
            let _x = x
            let _y = y
        Entity.named(label):
            let _l = label

    # integer match
    match 42:
        1:
            pass
        _:
            pass

    # str match
    let s = "hello"
    match s:
        "hello":
            pass
        _:
            pass

    # char match
    let ch = 'a'
    match ch:
        'a' | 'b':
            pass
        _:
            pass

    # is keyword
    let is_a = k is Kind.a
    let _ia = is_a

    return 0
