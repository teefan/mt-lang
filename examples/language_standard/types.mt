module examples.language_standard.types

import std.maybe as maybe
import std.status as status

public const TITLE: str = "language standard"
public const BANNER: str = <<-BANNER
    language
    standard
BANNER
public const ABI_LABEL: cstr = c<<-ABI
    language-standard-abi
ABI

public type Count = int


## Packed header used for layout checks and foreign-boundary demos.
public packed struct Header:
    tag: ubyte
    version: ushort
    flag_bits: uint


public align(16) struct SampleBlock:
    samples: array[float, 4]


public struct Pair[T]:
    left: T
    right: T


public union RawNumber:
    whole: int
    fraction: double


public enum Mode: ubyte
    idle = 0
    running = 1
    finished = 2


public flags Feature: uint
    loops = 1 << 0
    formats = 1 << 1
    foreign_calls = 1 << 2


public opaque Handle


public variant Token:
    word(text: str)
    number(value: int)
    done


public variant Box[T]:
    some(value: T)
    none


public struct Counter:
    total: int
    features: Feature


static_assert(size_of(Header) >= 7, "Header must stay large enough")
static_assert(offset_of(Header, version) >= 1, "Header.version offset drifted")
static_assert(align_of(SampleBlock) == 16, "SampleBlock alignment drifted")


methods Pair[T]:
    public static function mirror(value: T) -> Pair[T]:
        return Pair[T](left = value, right = value)


    public function swap() -> Pair[T]:
        return Pair[T](left = this.right, right = this.left)


    public function echo[U](value: U) -> U:
        return value


methods Counter:
    public static function zero() -> Counter:
        return Counter(total = 0, features = Feature.loops | Feature.formats)


    public edit function bump(step: int) -> void:
        this.total += step


    public function state_text() -> str:
        return if this.total > 0: "active" else: "empty"


public function describe_token(token: Token) -> str:
    match token:
        Token.word as payload:
            return payload.text
        Token.number as payload:
            return if payload.value > 0: "positive" else: "zero"
        Token.done:
            return "done"


public function describe_mode(mode: Mode) -> status.Status[str, Mode]:
    match mode:
        Mode.idle:
            return status.Status[str, Mode].ok(value = "idle")
        Mode.running:
            return status.Status[str, Mode].ok(value = "running")
        Mode.finished:
            return status.Status[str, Mode].err(error = mode)


public function maybe_pair(flag: bool) -> maybe.Maybe[Pair[int]]:
    if flag:
        return maybe.Maybe[Pair[int]].some(value = Pair[int](left = 1, right = 2))
    return maybe.Maybe[Pair[int]].none


public function wildcard_value(code: int) -> int:
    match code:
        0:
            return 100
        1:
            return 200
        _:
            return -1
