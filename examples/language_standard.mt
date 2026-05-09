module examples.language_standard

import std.fmt as fmt
import std.io as io
import std.maybe as maybe
import std.status as status
import std.string as string
import examples.language_standard.algorithms as alg
import examples.language_standard.async_showcase as async_demo
import examples.language_standard.foreign_bridge as foreign_demo
import examples.language_standard.types as types

external function printf(format: cstr, ...) -> int

const example_name: str = "language standard"
const note_text: str = <<-NOTE
    every feature stays explicit
NOTE

type ExitCode = int


struct AppState:
    counter: types.Counter
    header: types.Header
    block: types.SampleBlock
    last_bits: uint


methods AppState:
    static function create() -> AppState:
        var block = zero[types.SampleBlock]
        block.samples = array[float, 4](1.0, 2.0, 3.0, 4.0)
        return AppState(
            counter = types.Counter.zero(),
            header = types.Header(tag = 7, version = 1, flag_bits = 3),
            block = block,
            last_bits = 0,
        )


    edit function touch(step: int) -> void:
        this.counter.bump(step)
        this.last_bits = alg.float_bits(this.block.samples[0])


    function label() -> string.String:
        return fmt.string(f"#{example_name} ##{this.counter.total}")


function pair_label() -> string.String:
    match types.maybe_pair(true):
        maybe.Maybe.some as payload:
            return fmt.string(f"#{payload.value.left}:#{payload.value.right}")
        maybe.Maybe.none:
            return string.String.from_str("none")


function mode_label() -> string.String:
    match types.describe_mode(types.Mode.finished):
        status.Status.ok as payload:
            return string.String.from_str(payload.value)
        status.Status.err as payload:
            return fmt.string(f"err=#{payload.error}")


function release_allocated_values() -> string.String:
    var owned_values = foreign_demo.alloc_zeroed[int](2)
    if owned_values == null:
        return string.String.from_str("alloc=none")

    var first = 0
    var second = 0
    unsafe:
        owned_values[0] = 7
        owned_values[1] = 11
        first = read(owned_values)
        second = read(owned_values + 1)

    foreign_demo.release[int](owned_values)
    return fmt.string(f"alloc=#{first} second=#{second}")


function main() -> ExitCode:
    static_assert(size_of(types.Header) >= 7, "Header layout should stay valid")

    let _note = note_text

    var state = AppState.create()
    let counter_ref = ref_of(state.counter)
    counter_ref.bump(1)
    state.touch(3)

    let swapped = types.Pair[int](left = 4, right = 5).swap()
    let echoed = swapped.echo[str]("echo")

    var scratch: str_builder[32]
    scratch.assign("alpha")
    scratch.append("-beta")

    var numbers = array[int, 4](1)
    alg.fill_tail(ref_of(numbers))

    let numbers_span = span[int](data = ptr_of(numbers[0]), len = ptr_uint<-4)
    var others = array[int, 4](10, 20, 30, 40)
    let others_span = span[int](data = ptr_of(others[0]), len = ptr_uint<-4)
    let total = alg.sum_positive(numbers_span)
    let zipped = alg.zip_total(numbers_span, others_span)
    let first_value = alg.take_or_zero(ptr_of(numbers[0]))
    let missing_value = alg.take_or_zero(null[ptr[int]])
    let const_first = alg.first_const(ref_of(numbers))
    let closure_value = alg.closure_result(7)
    let named_value = alg.named_callback_result(3)
    let countdown_value = alg.countdown(5)

    let token = types.describe_token(types.Token.word(text = "alpha"))
    let mode = mode_label()
    let wildcard = types.wildcard_value(9)
    let choice = alg.choose_box(true)
    var choice_text = "box=none"
    match choice:
        types.Box.some as payload:
            choice_text = f"box=#{payload.value}"
        types.Box.none:
            choice_text = "box=none"

    var whole: double
    let fraction = foreign_demo.split_fraction(12.75, whole)
    let compare = foreign_demo.header_compare(state.header, state.header)
    let name_length = foreign_demo.text_length(example_name)
    let cosine_zero = foreign_demo.cosine(0.0)

    var label_text = state.label()
    defer label_text.release()
    var pair_text = pair_label()
    defer pair_text.release()
    var mode_text = mode_label()
    defer mode_text.release()
    var alloc_text = release_allocated_values()
    defer alloc_text.release()
    let first_const_value = unsafe: read(const_first)

    var owned = fmt.string(f"label=#{label_text.as_str()} pair=#{pair_text.as_str()} echo=#{echoed}")
    defer owned.release()
    owned.append(f" first_const=#{first_const_value}")

    printf(c"extern -> %s %d\n", scratch.as_cstr(), total)
    io.println(owned.as_str())
    io.println(f"token=#{token} mode=#{mode_text.as_str()} wildcard=#{wildcard} #{choice_text}")
    io.println(f"totals sum=#{total} zipped=#{zipped} first=#{first_value} missing=#{missing_value} closure=#{closure_value} named=#{named_value} countdown=#{countdown_value}")
    io.println(f"foreign len=#{name_length} fraction=#{fraction:.2} whole=#{whole:.0} compare=#{compare} cos=#{cosine_zero:.2}")
    io.println(alloc_text.as_str())
    return 0
