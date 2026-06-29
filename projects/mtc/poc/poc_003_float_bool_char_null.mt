# POC 003 — Float and double literals, bool, char
# Tests: float/double literals (plain, exponent, f/d suffix), bool (true/false),
# char literals (plain, escape, hex-escape), null.
const PI: float     = 3.14
const SMALL: double = 1.1920929E-7
const EXP: float    = 1.2e-3
const FVAL: float   = 1.0f
const DVAL: double  = 1.0d

const YES: bool = true
const NO: bool  = false

const NL: ubyte   = '\n'
const TAB: ubyte  = '\t'
const NUL: ubyte  = '\0'
const HEXCH: ubyte = '\x41'

const NPTR: ptr[int]?    = null
const TNUL: ptr[char]?    = null[ptr[char]]

function main() -> int:
    var f: float = 0.0
    f = f + PI + float<-(SMALL) + EXP
    if YES or not NO:
        f = f + 1.0

    var ch: ubyte = 'A'
    var bs: ubyte = '\\'
    let _ch = ch
    let _bs = bs

    return 0
