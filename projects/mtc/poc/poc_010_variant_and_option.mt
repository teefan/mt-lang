# POC 010 — Variant and Option: variant declaration, constructors, == !=,
# Option[T] construction, match, unwrap, is_some, is_none.

variant Token:
    ident(name: str)
    number(value: int)
    eof

variant Point:
    xy(x: int, y: int)
    origin

function main() -> int:
    # single-field arm constructor
    let t1 = Token.ident(name = "hello")
    # multi-field arm constructor
    let t2 = Token.number(value = 42)
    let _t2 = t2
    # no-payload arm
    let t3 = Token.eof

    # variant == and !=
    let eq = t1 == Token.ident(name = "hello")
    let ne = t3 != Token.eof
    let _eq = eq
    let _ne = ne

    # Option[T] .some and .none
    let some_val = Option[int].some(value = 10)
    let none_val = Option[int].none

    # match on Option
    match some_val:
        Option[int].some(value):
            let _v = value
        Option[int].none:
            pass

    # is_some / is_none
    let has_val = some_val.is_some()
    let is_n = none_val.is_none()
    let is_n2 = some_val.is_some()
    let _hv = has_val
    let _in = is_n
    let _in2 = is_n2

    # unwrap / expect
    let val = some_val.unwrap()
    let expect_val = some_val.expect("must be present")
    let or_val = none_val.unwrap_or(99)
    let _val = val
    let _ev = expect_val
    let _ov = or_val

    return 0
