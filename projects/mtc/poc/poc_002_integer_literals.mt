# POC 002 — Integer literal kinds, const, let, arithmetic
# Tests: const (top-level typed), let (inference and explicit), all integer
# literal forms (decimal, hex, binary, u/l/z suffixes), basic arithmetic.
const DEC: int         = 42
const HEX: uint        = 0xFF
const BIN: int         = 0b1010
const ZLIT: ptr_uint   = 100z
const ULIT: ulong      = 99ul
const SEP: ulong       = 1_000_000
const UBYTE_VAL: ubyte = 0xFFub
const UBYTE_DEC: ubyte = 42ub
const SHORT_VAL: short = -1s
const NEG_LONG: long   = -1l
const TYPED_INT: int   = 7i
const TYPED_UINT: uint = 7u

function main() -> int:
    let d = 10
    let h = 0xA
    let b = 0b1

    var sum: int = 0
    sum = sum + int<-(DEC + long<-(HEX) + BIN + int<-(ZLIT) + int<-(ULIT) + int<-(SEP))
    sum = sum + d + int<-(h) + b
    sum = sum + int<-(UBYTE_VAL) + int<-(UBYTE_DEC)
    sum = sum + int<-(SHORT_VAL) + int<-(NEG_LONG) + TYPED_INT + int<-(TYPED_UINT)
    return 0
