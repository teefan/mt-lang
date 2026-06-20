# frozen_string_literal: true

require_relative "helpers"

class Basic2Test < Minitest::Test
  include CodegenTestHelpers

  def test_generate_c_omits_unused_loop_labels
    source = <<~MT

# module demo.simple_loop_surface

function main() -> int:
    var i = 0
    while i < 3:
        i += 1
    return i

    MT

    generated = generate_c_from_source(source)

    assert_match(/static int32_t demo_simple_loop_surface_main\(void\) \{\s+(?:#[^\n]*\n\s+)?int32_t i = 0;\s+(?:#[^\n]*\n\s+)?while \(i < 3\) \{/m, generated)
    assert_match(/int32_t main\(void\) \{\s+(?:#[^\n]*\n\s+)?return demo_simple_loop_surface_main\(\);/m, generated)
    assert_match(/while \(i < 3\) \{/, generated)
    refute_match(/\n  \{\n    while \(i < 3\) \{/, generated)
    refute_match(/__mt_loop_continue_\d+:;/, generated)
    refute_match(/__mt_loop_break_\d+:;/, generated)
    refute_match(/goto __mt_loop_(continue|break)_\d+;/, generated)
  end

  def test_generate_c_omits_synthetic_fallback_return_after_total_infinite_loop
    source = <<~MT

# module demo.total_infinite_loop_surface

function spin_until(target: int) -> int:
    var current = 0
    while true:
        if current == target:
            return current
        current += 1

function main() -> int:
    return spin_until(3)

    MT

    generated = generate_c_from_source(source)
    function_body = generated[/static int32_t demo_total_infinite_loop_surface_spin_until\(int32_t target\) \{.*?^\}/m]

    refute_nil(function_body)
    assert_match(/while \(true\) \{/, function_body)
    refute_match(/return 0;/, function_body)
  end

  def test_generate_c_omits_synthetic_fallback_return_after_terminal_if_else
    source = <<~MT

# module demo.total_if_else_surface

function choose(flag: bool) -> int:
    if flag:
        return 1
    else:
        return 2

function main() -> int:
    return choose(true)

    MT

    generated = generate_c_from_source(source)
    function_body = generated[/static int32_t demo_total_if_else_surface_choose\(bool flag\) \{.*?^\}/m]

    refute_nil(function_body)
    assert_match(/if \(flag\) \{/, function_body)
    refute_match(/return 0;/, function_body)
  end

  def test_generate_c_rewrites_imported_aggregate_constants_for_static_storage
    source = <<~MT
      # module demo.static_const_colors

      import std.sample as sample

      function main() -> int:
          return int<-sample.WHITE.r
    MT

    imported_sources = {
      "std/sample.mt" => <<~MT,
        # module std.sample

        import std.c.sample as c

        public type Color = c.Color
        public const WHITE: Color = c.WHITE
      MT
      "std/c/sample.mt" => <<~MT,
        # module std.c.sample
        external
        struct Color:
            r: byte
            g: byte
            b: byte
            a: byte

        const WHITE: Color = Color(r = 255, g = 255, b = 255, a = 255)
      MT
    }

    generated = generate_c_from_program_source(source, imported_sources)

    assert_match(/static const Color std_sample_WHITE = \{ \.r = 255, \.g = 255, \.b = 255, \.a = 255 \};/, generated)
    refute_match(/static const Color std_sample_WHITE = c\.WHITE;/, generated)
  end

  def test_generate_c_emits_pedantic_safe_static_array_aggregate_initializers
    source = <<~MT
      # module demo.static_array_init

      struct Cell:
          x: int
          y: int

      const CELLS: array[Cell, 2] = array[Cell, 2](Cell(x = 1, y = 2), Cell(x = 3, y = 4))

      function main() -> int:
          return CELLS[0].x
    MT

    generated = generate_c_from_source(source)

    assert_match(/static const demo_static_array_init_Cell demo_static_array_init_CELLS\[2\] = \{ \{ \.x = 1, \.y = 2 \}, \{ \.x = 3, \.y = 4 \} \};/, generated)
    refute_match(/\(demo_static_array_init_Cell\)\{ \.x = 1, \.y = 2 \}/, generated)
  end

  def test_generate_c_uses_structured_break_for_simple_loop_exit
    source = <<~MT

# module demo.structured_break_surface

function main() -> int:
    var total = 0
    while total < 10:
        total += 1
        if total == 3:
            break
    return total

    MT

    generated = generate_c_from_source(source)

    assert_match(/while \(total < 10\) \{/, generated)
    assert_match(/if \(total == 3\) \{\n      break;/, generated)
    refute_match(/goto __mt_loop_break_\d+;/, generated)
    refute_match(/__mt_loop_break_\d+:;/, generated)
  end

    def test_generate_c_uses_structured_break_for_simple_option_match_inside_loop
    source = <<~MT

  # module demo.option_loop_match_break_surface

  function next_value(current: int) -> Option[int]:
      if current == 0:
          return Option[int].none
      return Option[int].some(value = current)

  function main() -> int:
      var total = 0
      var current = 3
      while current >= 0:
          match next_value(current):
              Option.some as payload:
                  if payload.value == 2:
                      break
                  total += payload.value
              Option.none:
                  break
          current -= 1
      return total

    MT

    generated = generate_c_from_source(source)

    assert_match(/while \(current >= 0\) \{/, generated)
    assert_match(/if \(__mt_match_value_\d+\.kind == std_option_Option_int_kind_some\) \{/, generated)
    assert_match(/if \(payload.value == 2\) \{\n        break;/, generated)
    refute_match(/total \+= payload\.value;\n\s+break;/, generated)
    refute_match(/goto __mt_loop_break_\d+;/, generated)
    refute_match(/__mt_loop_break_\d+:;/, generated)
    end

  def test_generate_c_canonicalizes_top_guarded_infinite_loop
    source = <<~MT

# module demo.top_guarded_loop_surface

function main() -> int:
    var index = 0
    while true:
        if index >= 3:
            break
        index += 1
    return index

    MT

    generated = generate_c_from_source(source)
    function_body = generated[/static int32_t demo_top_guarded_loop_surface_main\(void\) \{.*?^\}/m]

    refute_nil(function_body)
    assert_match(/while \(index < 3\) \{/, function_body)
    refute_match(/while \(true\) \{/, function_body)
    refute_match(/if \(index >= 3\) \{\n      break;/, function_body)
  end

  def test_generate_c_uses_structured_continue_for_simple_while_loop
    source = <<~MT

# module demo.structured_continue_surface

function main() -> int:
    var total = 0
    var i = 0
    while i < 5:
        i += 1
        if i == 2:
            continue
        total += i
    return total

    MT

    generated = generate_c_from_source(source)

    assert_match(/if \(i == 2\) \{\n      continue;/, generated)
    refute_match(/goto __mt_loop_continue_\d+;/, generated)
    refute_match(/__mt_loop_continue_\d+:;/, generated)
  end

  def test_generate_c_uses_structured_continue_for_simple_for_loop
    source = <<~MT

# module demo.structured_for_continue_surface

function main() -> int:
    var total = 0
    for i in 0..5:
        if i == 2:
            continue
        total += i
    return total

    MT

    generated = generate_c_from_source(source)

    assert_match(/for \(int32_t i = 0; i < 5; i \+= 1\) \{/, generated)
    assert_match(/if \(i == 2\) \{\n      continue;/, generated)
    refute_match(/goto __mt_loop_continue_\d+;/, generated)
    refute_match(/__mt_loop_continue_\d+:;/, generated)
  end

  def test_generate_c_for_layout_queries_and_static_assert
    source = <<~MT

# module demo.layout_surface

struct Header:
    magic: array[ubyte, 4]
    version: ushort

static_assert(size_of(Header) == 6, \"Header size should stay stable\")

function main() -> ptr_uint:
    return offset_of(Header, version) + align_of(Header)

    MT

    generated = generate_c_from_source(source)

    assert_match(/#include <stddef\.h>/, generated)
    assert_match(/_Static_assert\(true, "Header size should stay stable"\);/, generated)
    assert_match(/return offsetof\(demo_layout_surface_Header, version\) \+ _Alignof\(demo_layout_surface_Header\);/, generated)
  end

  def test_generate_c_for_local_layout_query_const_reused_in_static_assert
    source = <<~MT

# module demo.layout_local_const_surface

struct Header:
    magic: array[ubyte, 4]
    version: ushort

function main() -> int:
    let header_size = size_of(Header)
    static_assert(header_size == 6, "Header size should stay stable")
    return int<-header_size

    MT

    generated = generate_c_from_source(source)

    assert_match(/uintptr_t header_size = sizeof\(demo_layout_local_const_surface_Header\);/, generated)
    assert_match(/_Static_assert\(true, "Header size should stay stable"\);/, generated)
    refute_match(/_Static_assert\(header_size == 6,/, generated)
  end

  def test_generate_c_for_real_str_literals_and_fatal
    source = <<~MT

# module demo.str_surface

const greeting: str = \"hello\"

function main() -> int:
    fatal(greeting)
    return 0

    MT

    generated = generate_c_from_source(source)

    assert_match(/typedef struct mt_str \{/, generated)
    assert_match(/char\* data;/, generated)
    assert_match(/uintptr_t len;/, generated)
    assert_match(/static const mt_str demo_str_surface_greeting = \{ \.data = "hello", \.len = 5 \};/, generated)
    assert_match(/static void mt_fatal_str\(mt_str message\) \{/, generated)
    assert_match(/fwrite\(message\.data, 1, message\.len, stderr\);/, generated)
    assert_match(/mt_fatal_str\(demo_str_surface_greeting\);/, generated)
  end

  def test_generate_c_for_str_slice_and_arena_cstr_conversion
    source = <<~MT

# module demo.str_methods_surface

import std.str as text_ops
import std.mem.arena as arena

function main() -> int:
    var scratch = arena.create(64)
    defer scratch.release()
    let text = \"hello world\"
    let part = text.slice(6, 5)
    let copied = part.to_cstr(ref_of(scratch))
    fatal(copied)
    if part.len == ptr_uint<-5:
        return int<-part.len
    return 0

    MT

    generated = generate_c_from_source(source)

    assert_match(/static mt_str str_slice\(mt_str this, uintptr_t start, uintptr_t len\)/, generated)
    assert_match(/str slice start must be a UTF-8 boundary/, generated)
    assert_match(/str slice end must be a UTF-8 boundary/, generated)
    assert_match(/return \(mt_str\)\{ \.data = this\.data \+ start, \.len = len \};/, generated)
    assert_match(/static const char\* std_mem_arena_Arena_to_cstr\(std_mem_arena_Arena \*this, mt_str text\)/, generated)
    assert_match(/uint8_t\* memory = std_mem_arena_Arena_alloc_bytes\(this, text\.len \+ 1\);/, generated)
    assert_match(/char \*buffer = \(char\*\) memory;/, generated)
    assert_match(/\*\(buffer \+ text\.len\) = 0;/, generated)
    assert_match(/mt_str text = mt_str_lit_\d+;/, generated)
    assert_match(/const char\* copied = str_to_cstr\(part, &scratch\);/, generated)
  end

  def test_generate_c_for_str_equality_and_compile_time_folding
    source = <<~MT
      # module demo.str_compare_surface

      const same: bool = "milk" == "milk"
      static_assert("milk" != "tea", "string compare failed")

      function main(left: str, right: str) -> int:
          if left == right:
              return 1
          if left != right:
              return 2
          return 0
    MT

    generated = generate_c_from_source(source)

    assert_match(/static bool mt_str_equal\(mt_str left, mt_str right\) \{/, generated)
    assert_match(/static const bool demo_str_compare_surface_same = true;/, generated)
    assert_match(/_Static_assert\(true, "string compare failed"\);/, generated)
    assert_match(/if \(mt_str_equal\(left, right\)\) \{/, generated)
    assert_match(/if \(!mt_str_equal\(left, right\)\) \{/, generated)
    refute_match(/_Static_assert\(\(mt_str\)/, generated)
  end

  def test_generate_c_flattens_boolean_chains_and_preserves_right_grouping
    source = <<~MT
      # module demo.boolean_chain_surface

      function main(active: bool, ctrl: bool, alt: bool, code: int, a: int, b: int, c: int) -> int:
          if active and not ctrl and not alt and code >= 32 and code < 127:
              return a - (b - c)
          return 0
    MT

    generated = generate_c_from_source(source)

    assert_match(/if \(active && !ctrl && !alt && code >= 32 && code < 127\) \{/, generated)
    assert_match(/return a - \(b - c\);/, generated)
  end

  def test_rejects_codegen_for_direct_str_construction_outside_unsafe
    source = <<~MT
      # module demo.bad_str_constructor

      function main(data: ptr[char], len: ptr_uint) -> str:
          return str(data = data, len = len)
    MT

    error = assert_raises(MilkTea::SemaError) do
      generate_c_from_source(source)
    end

    assert_match(/str construction requires unsafe/, error.message)
  end

  def test_rejects_codegen_for_str_addition
    source = <<~MT
      # module demo.bad_str_addition

      function main() -> str:
          let left = "left"
          let right = "right"
          return left + right
    MT

    error = assert_raises(MilkTea::SemaError) do
      generate_c_from_source(source)
    end

    assert_match(/operator \+ does not support str\/cstr concatenation/, error.message)
  end

  def test_generate_c_for_packed_and_aligned_structs
    source = <<~MT

# module demo.layout_modifiers_surface

@[packed]
struct Header:
    tag: ubyte
    value: uint

@[align(16)]
struct Mat4:
    data: array[float, 16]

@[packed]
@[align(16)]
struct Packet:
    tag: ubyte
    value: uint

static_assert(size_of(Header) == 5, \"Header should stay packed\")
static_assert(align_of(Mat4) == 16, \"Mat4 alignment drifted\")
static_assert(size_of(Packet) == 16, \"Packet size drifted\")
static_assert(offset_of(Packet, value) == 1, \"Packet.value offset drifted\")
static_assert(align_of(Packet) == 16, \"Packet alignment drifted\")

function main() -> int:
    return 0

    MT

    generated = generate_c_from_source(source)

    assert_match(/struct demo_layout_modifiers_surface_Header \{/, generated)
    assert_match(/\} __attribute__\(\(packed\)\);/, generated)
    assert_match(/struct demo_layout_modifiers_surface_Mat4 \{/, generated)
    assert_match(/\} __attribute__\(\(aligned\(16\)\)\);/, generated)
    assert_match(/struct demo_layout_modifiers_surface_Packet \{/, generated)
    assert_match(/\} __attribute__\(\(packed, aligned\(16\)\)\);/, generated)
    assert_match(/_Static_assert\(true, "Header should stay packed"\);/, generated)
    assert_match(/_Static_assert\(true, "Mat4 alignment drifted"\);/, generated)
    assert_match(/_Static_assert\(true, "Packet size drifted"\);/, generated)
    assert_match(/_Static_assert\(true, "Packet.value offset drifted"\);/, generated)
    assert_match(/_Static_assert\(true, "Packet alignment drifted"\);/, generated)
  end

  def test_generate_c_for_address_of_and_dereference_assignment
    source = <<~MT

# module demo.pointer_surface

struct Counter:
    value: int

function main() -> int:
    var counter = Counter(value = 3)
    let counter_ptr = ptr_of(counter)
    unsafe:
        read(counter_ptr).value = 7
    return counter.value

    MT

    generated = generate_c_from_source(source)

    assert_match(/demo_pointer_surface_Counter \*counter_ptr = &counter;/, generated)
    assert_match(/counter_ptr->value = 7;/, generated)
    assert_match(/return counter\.value;/, generated)
  end

  def test_generate_c_for_raw_pointer_member_access
    source = <<~MT

# module demo.pointer_surface_auto_member

struct Counter:
    value: int

function main() -> int:
    var counter = Counter(value = 3)
    let counter_ptr = ptr_of(counter)
    unsafe:
        counter_ptr.value = 7
        return counter_ptr.value

    MT

    generated = generate_c_from_source(source)

    assert_match(/demo_pointer_surface_auto_member_Counter \*counter_ptr = &counter;/, generated)
    assert_match(/counter_ptr->value = 7;/, generated)
    assert_match(/return counter_ptr->value;/, generated)
  end

  def test_generate_c_for_raw_pointer_method_calls
    source = <<~MT

# module demo.pointer_method_surface

struct Counter:
    value: int

extending Counter:
    editable function add(delta: int):
        this.value += delta

    function read() -> int:
        return this.value

function main() -> int:
    var counter = Counter(value = 3)
    let counter_ptr = ptr_of(counter)
    unsafe:
        counter_ptr.add(4)
        return counter_ptr.read()

    MT

    generated = generate_c_from_source(source)

    assert_match(/static void demo_pointer_method_surface_Counter_add\(demo_pointer_method_surface_Counter \*this, int32_t delta\)/, generated)
    assert_match(/static int32_t demo_pointer_method_surface_Counter_read\(demo_pointer_method_surface_Counter this\)/, generated)
    assert_match(/demo_pointer_method_surface_Counter \*counter_ptr = &counter;/, generated)
    assert_match(/demo_pointer_method_surface_Counter_add\(counter_ptr, 4\);/, generated)
    assert_match(/return demo_pointer_method_surface_Counter_read\(\*counter_ptr\);/, generated)
  end

  def test_generate_c_for_extended_compound_assignment_operators
    source = <<~MT

# module demo.compound_assignments_surface

flags Bits: uint
    a = 1 << 0
    b = 1 << 1

function main() -> int:
    var value = 12
    value %= 5
    value <<= 1
    value >>= 1
    var bits = Bits.a
    bits |= Bits.b
    bits &= Bits.b
    bits ^= Bits.a
    return value

    MT

    generated = generate_c_from_source(source)

    assert_match(/value %= 5;/, generated)
    assert_match(/value <<= 1;/, generated)
    assert_match(/value >>= 1;/, generated)
    assert_match(/bits \|= demo_compound_assignments_surface_Bits_b;/, generated)
    assert_match(/bits &= demo_compound_assignments_surface_Bits_b;/, generated)
    assert_match(/bits \^= demo_compound_assignments_surface_Bits_a;/, generated)
  end

  def test_generate_c_for_safe_ref_locals_params_and_methods
    source = <<~MT

# module demo.ref_surface

struct Counter:
    value: int

extending Counter:
    editable function add(delta: int):
        this.value += delta

    function read() -> int:
        return this.value

function increment(counter: ref[Counter], amount: int) -> void:
    counter.add(amount)
    counter.value += 1

function main() -> int:
    var counter = Counter(value = 3)
    increment(counter, 4)
    let handle = ref_of(counter)
    let value_ref = ref_of(handle.value)
    read(value_ref) += 2
    unsafe:
        let raw_counter = ptr_of(handle)
        read(raw_counter).value += 1
    return handle.read()

    MT

    generated = generate_c_from_source(source)

    assert_match(/static void demo_ref_surface_Counter_add\(demo_ref_surface_Counter \*this, int32_t delta\)/, generated)
    assert_match(/static int32_t demo_ref_surface_Counter_read\(demo_ref_surface_Counter this\)/, generated)
    assert_match(/static void demo_ref_surface_increment\(demo_ref_surface_Counter \*counter, int32_t amount\)/, generated)
  assert_match(/demo_ref_surface_increment\(&counter, 4\);/, generated)
    assert_match(/demo_ref_surface_Counter \*handle = &counter;/, generated)
    assert_match(/demo_ref_surface_Counter_add\(counter, amount\);/, generated)
    assert_match(/counter->value \+= 1;/, generated)
    assert_match(/int32_t \*value_ref = &handle->value;/, generated)
    assert_match(/\*value_ref \+= 2;/, generated)
    assert_match(/demo_ref_surface_Counter \*raw_counter = handle;/, generated)
    assert_match(/raw_counter->value \+= 1;/, generated)
    assert_match(/return demo_ref_surface_Counter_read\(\*handle\);/, generated)
  end

  def test_generate_c_for_immutable_array_bearing_method_receivers_uses_pointer_params
    source = <<~MT

# module demo.large_receiver_surface

struct Big:
    data: array[int, 8]

function first_value(big: Big) -> int:
    return big.data[0]

extending Big:
    function first() -> int:
        return first_value(this)

function main() -> int:
    let big = Big(data = array[int, 8](1, 2, 3, 4, 5, 6, 7, 8))
    return big.first()

    MT

    generated = generate_c_from_source(source)

    assert_match(/static int32_t demo_large_receiver_surface_Big_first\(demo_large_receiver_surface_Big \*this\)/, generated)
    assert_match(/return demo_large_receiver_surface_first_value\(\*this\);/, generated)
    assert_match(/return demo_large_receiver_surface_Big_first\(&big\);/, generated)
  end

  def test_generate_c_for_unused_method_receivers_omits_param_but_keeps_receiver_evaluation
    source = <<~MT

# module demo.receiver_elision_surface

var calls: int = 0

struct Counter:
    value: int

function make_counter() -> Counter:
    calls += 1
    return Counter(value = calls)

extending Counter:
    function answer() -> int:
        return 7

function main() -> int:
    return make_counter().answer()

    MT

    generated = generate_c_from_source(source)

    assert_match(/static int32_t demo_receiver_elision_surface_Counter_answer\(void\)/, generated)
    refute_match(/demo_receiver_elision_surface_Counter_answer\(demo_receiver_elision_surface_Counter/, generated)
    assert_match(/return \(\(void\)demo_receiver_elision_surface_make_counter\(\), demo_receiver_elision_surface_Counter_answer\(\)\);/, generated)
  end

  def test_generate_c_for_function_values_returning_arrays
    source = <<~MT

# module demo.fn_array_return_surface

function make() -> array[int, 2]:
    return array[int, 2](4, 9)

function read_first(callback: fn() -> array[int, 2]) -> int:
    let values = callback()
    unsafe:
        return values[0]

function main() -> int:
    return read_first(make)

    MT

    generated = generate_c_from_source(source)

    assert_match(/static void demo_fn_array_return_surface_make\(int32_t \(\*__mt_out\)\[2\]\);/, generated)
    assert_match(/static int32_t demo_fn_array_return_surface_read_first\(void \(\*callback\)\(int32_t \(\*__mt_out\)\[2\]\)\);/, generated)
    assert_match(/int32_t values\[2\];\n  callback\(&values\);/, generated)
    assert_match(/return demo_fn_array_return_surface_read_first\(demo_fn_array_return_surface_make\);/, generated)
  end

  def test_generate_c_for_imported_associated_functions_on_type_aliases
    Dir.mktmpdir("milk-tea-codegen-associated") do |dir|
      FileUtils.mkdir_p(File.join(dir, "demo"))

      File.write(File.join(dir, "demo", "math.mt"), <<~MT

# module demo.math

public struct RawVec:
    x: int

public type Vec = RawVec

extending RawVec:
    public static function zero() -> Vec:
        return Vec(x = 0)

      MT

      )
      source_path = File.join(dir, "main.mt")
      File.write(source_path, <<~MT

# module demo.main

import demo.math as math

function main() -> int:
    let value = math.Vec.zero()
    return value.x

      MT

      )
      program = MilkTea::ModuleLoader.new(module_roots: [dir]).check_program(source_path)
      generated = MilkTea::Codegen.generate_c(MilkTea::Lowering.lower(program))

      assert_match(/static demo_math_RawVec demo_math_RawVec_zero_static\(void\)/, generated)
      assert_match(/demo_math_RawVec value = demo_math_RawVec_zero_static\(\);/, generated)
      assert_match(/return value\.x;/, generated)
    end
  end

  def test_generate_c_for_fixed_array_construction_and_layout
    source = <<~MT

# module demo.array_surface

struct Palette:
    colors: array[uint, 4]

const DEFAULT: array[uint, 4] = array[uint, 4](11, 22, 33, 44)

function main() -> int:
    var palette = array[uint, 4](1, 2, 3, 4)
    var holder = Palette(colors = array[uint, 4](5, 6, 7, 8))
    unsafe:
        if read(ptr_of(palette[0])) != 1:
            return 1
        if read(ptr_of(holder.colors[0])) != 5:
            return 2
    return 0

    MT

    generated = generate_c_from_source(source)

    assert_match(/typedef struct demo_array_surface_Palette/, generated)
    assert_match(/uint32_t colors\[4\];/, generated)
    assert_match(/static const uint32_t demo_array_surface_DEFAULT\[4\] = \{ 11, 22, 33, 44 \};/, generated)
    assert_match(/uint32_t palette\[4\] = \{ 1, 2, 3, 4 \};/, generated)
    assert_match(/\.colors = \{ 5, 6, 7, 8 \}/, generated)
  end

  def test_generate_c_for_addr_of_fixed_array_element_through_pointer_deref
    source = <<~MT

# module demo.ptr_array_addr

struct Palette:
    colors: array[uint, 4]

function main() -> uint:
    var holder = Palette(colors = array[uint, 4](5, 6, 7, 8))
    unsafe:
        let base = ptr_of(holder)
        let first = ptr_of(read(base).colors[0])
        read(first) = 9
    return holder.colors[0]

    MT

    generated = generate_c_from_source(source)

    assert_match(/demo_ptr_array_addr_Palette \*base = &holder;/, generated)
    assert_match(/uint32_t \*first = mt_checked_index_array_uint_4\(&base->colors, 0\);/, generated)
    assert_match(/\*first = 9;/, generated)
    assert_match(/return \(\*mt_checked_index_array_uint_4\(&holder\.colors, 0\)\);/, generated)
  end

  def test_generate_c_hoists_repeated_checked_index_helper_within_expression_statement
    source = <<~MT

# module demo.checked_index_alias_surface

struct Point:
    x: int
    y: int

function use(a: int, b: int, c: int, d: int) -> void:
    return

function next(cursor: ptr[int]) -> int:
    unsafe:
        let value = read(cursor)
        read(cursor) += 1
        return value

function main() -> int:
    var points = array[Point, 2](Point(x = 1, y = 2), Point(x = 3, y = 4))
    var index = 1
    use(points[index].x, points[index].y, points[index].x + points[index].y, points[index].x)
    var cursor = 0
    use(points[next(ptr_of(cursor))].x, points[next(ptr_of(cursor))].y, 0, 0)
    return 0

    MT

    generated = generate_c_from_source(source)

    assert_match(/demo_checked_index_alias_surface_Point \*__mt_checked_index_ptr_\d+ = mt_checked_index_array_demo_checked_index_alias_surface_Point_2\(&points, index\);/, generated)
    assert_match(/demo_checked_index_alias_surface_use\(__mt_checked_index_ptr_\d+->x, __mt_checked_index_ptr_\d+->y, __mt_checked_index_ptr_\d+->x \+ __mt_checked_index_ptr_\d+->y, __mt_checked_index_ptr_\d+->x\);/, generated)
    refute_match(/demo_checked_index_alias_surface_Point \*__mt_checked_index_ptr_\d+ = mt_checked_index_array_demo_checked_index_alias_surface_Point_2\(&points, demo_checked_index_alias_surface_next\(&cursor\)\);/, generated)
  end

  def test_generate_c_for_safe_array_indexing_and_assignment
    source = <<~MT

# module demo.array_index_surface

struct Palette:
    colors: array[uint, 4]

function main() -> int:
    var palette = array[uint, 4](1, 2, 3, 4)
    var holder = Palette(colors = array[uint, 4](5, 6, 7, 8))
    palette[1] = 9
    holder.colors[2] = 10
    if palette[0] != 1:
        return 1
    if holder.colors[2] != 10:
        return 2
    return 0

    MT

    generated = generate_c_from_source(source)

    assert_match(/static inline uint32_t \*mt_checked_index_array_uint_4\(uint32_t \(\*array\)\[4\], uintptr_t index\)/, generated)
    assert_match(/if \(index >= 4\) mt_fatal\("array index out of bounds"\);/, generated)
    assert_match(/\(\*mt_checked_index_array_uint_4\(\&palette, 1\)\) = 9;/, generated)
    assert_match(/\(\*mt_checked_index_array_uint_4\(\&holder\.colors, 2\)\) = 10;/, generated)
    assert_match(/if \(\(\*mt_checked_index_array_uint_4\(\&palette, 0\)\) != 1\)/, generated)
  end

  def test_generate_c_for_zero_initialization
    source = <<~MT

# module demo.zero_surface

struct Palette:
    colors: array[uint, 4]

function main() -> int:
    var palette = zero[array[uint, 4]]
    var holder = zero[Palette]
    return 0

    MT

    generated = generate_c_from_source(source)

    assert_match(/uint32_t palette\[4\] = \{ 0 \};/, generated)
    assert_match(/demo_zero_surface_Palette holder = \{ 0 \};/, generated)
  end

  def test_generate_c_for_partial_aggregate_and_array_initialization
    source = <<~MT

# module demo.partial_surface

struct Point:
    x: int
    y: int

function main() -> int:
    var origin = Point()
    var point = Point(x = 5)
    var palette = array[uint, 4](1, 2)
    return origin.x + point.x + int<-palette[1]

    MT

    generated = generate_c_from_source(source)

    assert_match(/demo_partial_surface_Point origin = \{ 0 \};/, generated)
    assert_match(/demo_partial_surface_Point point = \{ \.x = 5 \};/, generated)
    assert_match(/uint32_t palette\[4\] = \{ 1, 2 \};/, generated)
  end

  def test_generate_c_for_array_assignment_and_parameter_copy
    source = <<~MT

# module demo.array_copy_surface

function mutate(values: array[int, 4]) -> int:
    var local = values
    unsafe:
        local[1] = 9
        return local[1]

function main() -> int:
    var lhs = array[int, 4](1, 2, 3, 4)
    let rhs = array[int, 4](5, 6, 7, 8)
    lhs = rhs
    let changed = mutate(lhs)
    unsafe:
        if lhs[1] != 6:
            return 1
    return changed

    MT

    generated = generate_c_from_source(source)

    assert_match(/int32_t values_input\[4\]/, generated)
    assert_match(/static inline int32_t \*mt_checked_index_array_int_4\(int32_t \(\*array\)\[4\], uintptr_t index\)/, generated)
    assert_match(/int32_t values\[4\];\n  memcpy\(values, values_input, sizeof\(values\)\);/, generated)
    assert_match(/int32_t local\[4\];\n  memcpy\(local, values, sizeof\(local\)\);/, generated)
    assert_match(/memcpy\(lhs, rhs, sizeof\(lhs\)\);/, generated)
    assert_match(/return \(\*mt_checked_index_array_int_4\(\&local, 1\)\);/, generated)
    assert_match(/if \(\(\*mt_checked_index_array_int_4\(\&lhs, 1\)\) != 6\)/, generated)
  end

  def test_generate_c_for_local_array_returns
    source = <<~MT

# module demo.array_return_surface

function make() -> array[int, 4]:
    return array[int, 4](1, 2, 3, 4)

function clone(values: array[int, 4]) -> array[int, 4]:
    return values

function read(values: array[int, 4]) -> int:
    unsafe:
        return values[1]

function main() -> int:
    return read(clone(make()))

    MT

    generated = generate_c_from_source(source)

    refute_match(/mt_array_return_array_int_4/, generated)
    assert_match(/static void demo_array_return_surface_make\(int32_t \(\*__mt_out\)\[4\]\);/, generated)
    assert_match(/static void demo_array_return_surface_clone\(int32_t \(\*__mt_out\)\[4\], int32_t values_input\[4\]\);/, generated)
    assert_match(/memcpy\(\*__mt_out, \(int32_t \[4\]\) \{ 1, 2, 3, 4 \}, sizeof\(\*__mt_out\)\);/, generated)
    assert_match(/memcpy\(\*__mt_out, values, sizeof\(\*__mt_out\)\);/, generated)
    assert_match(/demo_array_return_surface_make\(&__mt_array_call_\d+\);/, generated)
    assert_match(/demo_array_return_surface_clone\(&__mt_array_call_\d+, __mt_array_call_\d+\);/, generated)
    assert_match(/return demo_array_return_surface_read\(__mt_array_call_\d+\);/, generated)
  end

  def test_generate_c_for_unsafe_reinterpret_calls
    source = <<~MT

# module demo.reinterpret_surface

function main() -> uint:
    let value: float = 1.0
    unsafe:
        let bits = reinterpret[uint](value)
        return bits

    MT

    generated = generate_c_from_source(source)

    assert_match(/static inline uint32_t mt_reinterpret_uint_from_float\(float value\)/, generated)
    assert_match(/_Static_assert\(sizeof\(uint32_t\) == sizeof\(float\), "reinterpret requires equal sizes"\);/, generated)
    assert_match(/memcpy\(&result, &value, sizeof\(result\)\);/, generated)
    assert_match(/uint32_t bits = mt_reinterpret_uint_from_float\(value\);/, generated)
  end

  def test_generate_c_for_unsafe_pointer_to_cstr_abi_casts
    source = <<~MT

# module demo.cstr_casts_surface

external function set_text(value: cstr) -> void
external function get_text() -> cstr

function main() -> void:
    var buffer = zero[array[char, 32]]
    unsafe:
        let raw_buffer = ptr_of(buffer[0])
        set_text(cstr<-raw_buffer)
        let clipboard = get_text()
        let writable = ptr[char]<-clipboard

    MT

    generated = generate_c_from_source(source)

    assert_match(/set_text\(\(const char\*\) raw_buffer\);/, generated)
    assert_match(/char \*writable = \(char\*\) clipboard;/, generated)
  end

  def test_generate_c_simplifies_address_of_pointer_deref
    source = <<~MT

# module demo.addr_of_deref_surface

function identity(handle: ptr[int]) -> ptr[int]:
    unsafe:
        return ptr_of(read(handle))

    MT

    generated = generate_c_from_source(source)

    assert_match(/static int32_t \*demo_addr_of_deref_surface_identity\(int32_t \*handle\)/, generated)
    assert_match(/return handle;/, generated)
    refute_match(/return &\(\*handle\);/, generated)
  end

  def test_generate_c_for_const_pointer_ro_addr_calls
    source = <<~MT

# module demo.const_pointer_call_surface

function inspect(values: const_ptr[int]) -> void:
    return

function main() -> void:
    let value = 7
    inspect(const_ptr_of(value))

    MT

    generated = generate_c_from_source(source)

    assert_match(/static void demo_const_pointer_call_surface_inspect\(const int32_t\* values\)/, generated)
    assert_match(/demo_const_pointer_call_surface_inspect\(\&value\);/, generated)
  end

  def test_generate_c_for_array_char_values_and_span_char_calls
    source = <<~MT

# module demo.char_array_surface

function view(items: span[char]) -> ptr_uint:
    return items.len

function main() -> int:
    var buffer = zero[array[char, 32]]
    buffer[0] = 65
    return int<-view(buffer)

    MT

    generated = generate_c_from_source(source)

    assert_match(/char buffer\[32\] = \{ 0 \};/, generated)
    assert_match(/\(\*mt_checked_index_array_char_32\(&buffer, 0\)\) = \(char\) 65;/, generated)
    assert_match(/\(mt_span_char\)\{ \.data = &buffer\[0\], \.len = 32 \}/, generated)
  end

  def test_generate_c_for_typed_array_char_local_without_initializer
    source = <<~MT

# module demo.char_array_zero_local

function main() -> int:
    var buffer: array[char, 16]
    return 0

    MT

    generated = generate_c_from_source(source)

    assert_match(/char buffer\[16\] = \{ 0 \};/, generated)
  end

  def test_rejects_generate_c_for_array_char_text_methods
    source = <<~MT

# module demo.char_array_methods

function main() -> int:
    var buffer = zero[array[char, 16]]
    let view = buffer.as_str()
    let label = buffer.as_cstr()
    return int<-view.len

    MT

    error = assert_raises(MilkTea::SemaError) do
      generate_c_from_source(source)
    end

    assert_match(/array\[char, 16\]\.as_str is not available; array\[char, N\] is raw storage/, error.message)
  end

  def test_generate_c_for_str_buffer_methods_and_span_char_calls
    source = <<~MT

# module demo.str_buffer_surface

function view(items: span[char]) -> ptr_uint:
    return items.len

function main() -> int:
    var buffer: str_buffer[32]
    buffer.assign(\"hi\")
    buffer.append(\"!\")
    let text = buffer.as_str()
    let label = buffer.as_cstr()
    let raw = view(buffer)
    buffer.clear()
    return int<-(buffer.capacity() + text.len + raw)

    MT

    generated = generate_c_from_source(source)

    assert_match(/typedef struct mt_str_buffer_32 mt_str_buffer_32;/, generated)
    assert_match(/struct mt_str_buffer_32 \{/, generated)
    assert_match(/char data\[33\];/, generated)
    assert_match(/uintptr_t len;/, generated)
    assert_match(/bool dirty;/, generated)
    assert_match(/static char\* mt_str_buffer_prepare_write\(char\* data, uintptr_t cap, bool\* dirty\)/, generated)
    assert_match(/static uintptr_t mt_str_buffer_len\(char\* data, uintptr_t cap, uintptr_t\* len, bool\* dirty\)/, generated)
    assert_match(/static const char\* mt_str_buffer_as_cstr\(char\* data, uintptr_t cap, uintptr_t\* len, bool\* dirty\)/, generated)
    assert_match(/static void mt_str_buffer_assign\(mt_str value, char\* data, uintptr_t cap, uintptr_t\* len, bool\* dirty\)/, generated)
    assert_match(/static void mt_str_buffer_append\(mt_str value, char\* data, uintptr_t cap, uintptr_t\* len, bool\* dirty\)/, generated)
    assert_match(/static void mt_str_buffer_clear\(char\* data, uintptr_t cap, uintptr_t\* len, bool\* dirty\)/, generated)
    assert_match(/mt_str_buffer_32 buffer = \{ 0 \};/, generated)
    assert_match(/mt_str_buffer_assign\(mt_str_lit_\d+, &buffer\.data\[0\], 32, &buffer\.len, &buffer\.dirty\);/, generated)
    assert_match(/mt_str_buffer_append\(mt_str_lit_\d+, &buffer\.data\[0\], 32, &buffer\.len, &buffer\.dirty\);/, generated)
    assert_match(/mt_str text = \{ \.data = &buffer\.data\[0\], \.len = mt_str_buffer_len\(&buffer\.data\[0\], 32, &buffer\.len, &buffer\.dirty\) \};/, generated)
    assert_match(/const char\* label = mt_str_buffer_as_cstr\(&buffer\.data\[0\], 32, &buffer\.len, &buffer\.dirty\);/, generated)
    assert_match(/\(mt_span_char\)\{ \.data = mt_str_buffer_prepare_write\(&buffer\.data\[0\], 32, &buffer\.dirty\), \.len = 33 \}/, generated)
    assert_match(/mt_str_buffer_clear\(&buffer\.data\[0\], 32, &buffer\.len, &buffer\.dirty\);/, generated)
  end

  def test_generate_c_for_explicit_str_buffer_format_sinks
    source = <<~MT

# module demo.str_buffer_format_sink

function main(value: uint, ratio: double) -> int:
    var buffer: str_buffer[32]
    buffer.assign_format(f"hex=\#{value:x}")
    buffer.append_format(f" ratio=\#{ratio:.2}")
    return int<-buffer.len()

    MT

    generated = generate_c_from_source(source)

    refute_match(/mt_str __mt_fmt_string_\d+ = mt_format_str_make/, generated)
    assert_match(/mt_str_buffer_clear\(&buffer\.data\[0\], 32, &buffer\.len, &buffer\.dirty\);/, generated)
    assert_match(/mt_format_append_str\(/, generated)
    assert_match(/mt_format_append_ulong_hex\(/, generated)
    assert_match(/mt_format_append_double_precision\(/, generated)
    assert_match(/\*\(&buffer\.len\) = __mt_fmt_sink_offset_\d+;/, generated)
  end

  def test_generate_c_for_custom_format_hooks
    source = <<~MT

# module demo.custom_format_codegen

import std.fmt as fmt
import std.string as string

struct Point:
    x: int
    y: int

extending Point:
    function format_len() -> ptr_uint:
        return f"(\#{this.x}, \#{this.y})".len

    function append_format(output: ref[string.String]) -> void:
        fmt.append_format(output, f"(\#{this.x}, \#{this.y})")

function main() -> int:
    let point = Point(x = 2, y = 3)
    let text = f"point=\#{point}"
    var output = string.String.create()
    defer output.release()
    output.append_format(f"[\#{point}]")
    var buffer: str_buffer[64]
    buffer.assign_format(f"<\#{point}>")
    return int<-(text.len + buffer.len())

    MT

    generated = generate_c_from_source(source)

    assert_match(/Point.*format_len\(/, generated)
    assert_match(/Point.*append_format\(/, generated)
    assert_match(/bool owns_storage;/, generated)
    assert_match(/\.owns_storage = false/, generated)
    assert_match(/mt_fatal\("custom format hook length mismatch"\);/, generated)
    refute_match(/std_string_String __mt_fmt_part_output_\d+ = std_string_String_create\(\);/, generated)
    refute_match(/std_string_String_as_str\(__mt_fmt_part_output_\d+\)/, generated)
    refute_match(/std_string_String_release\(&__mt_fmt_part_output_\d+\);/, generated)
  end

  def test_generate_c_for_foreign_defs_with_str_buffer_and_span_char_ptr_char_boundary
    root_source = <<~MT
      # module demo.main

      import std.ui as ui

      function main() -> void:
          var buffer: str_buffer[32]
          ui.text_box(buffer)
    MT

    imported_sources = {
      "std/c/ui.mt" => <<~MT,
        # module std.c.ui
        external
        include "ui.h"

        external function TextBox(text: ptr[char], text_size: int) -> void
      MT
      "std/ui.mt" => <<~MT,
        # module std.ui

        import std.c.ui as c

        public foreign function text_box(text: span[char] as ptr[char]) -> void = c.TextBox(text, int<-text_public.len)
      MT
    }

    generated = generate_c_from_program_source(root_source, imported_sources)

    assert_match(/mt_span_char __mt_foreign_arg_public_1 = \{ \.data = mt_str_buffer_prepare_write\(&buffer\.data\[0\], 32, &buffer\.dirty\), \.len = 33 \};/, generated)
    assert_match(/TextBox\(__mt_foreign_arg_public_1\.data, \(int32_t\) __mt_foreign_arg_public_1\.len\);/, generated)
  end

  def test_rejects_codegen_for_removed_cstr_list_buffer_type
    source = <<~MT
      # module demo.main

      function main() -> void:
          var labels: cstr_list_buffer[3, 64]
    MT

    error = assert_raises(MilkTea::SemaError) do
      generate_c_from_program_source(source)
    end

    assert_match(/unknown generic type cstr_list_buffer/, error.message)
  end

  def test_rejects_generate_c_for_foreign_str_as_cstr_call_with_array_char_as_cstr
    source = <<~MT
      # module demo.main

      import std.ui as ui

      function main() -> void:
          var buffer: array[char, 32]
          ui.label(buffer.as_cstr())
    MT

    imported_sources = {
      "std/c/ui.mt" => <<~MT,
        # module std.c.ui
        external
        include "ui.h"

        external function Label(text: cstr) -> void
      MT
      "std/ui.mt" => <<~MT,
        # module std.ui

        import std.c.ui as c

        public foreign function label(text: str as cstr) -> void = c.Label
      MT
    }

    error = assert_raises(MilkTea::SemaError) do
      generate_c_from_program_source(source, imported_sources)
    end

    assert_match(/array\[char, 32\]\.as_cstr is not available; array\[char, N\] is raw storage/, error.message)
  end

  def test_generate_c_for_foreign_defs_with_array_char_and_span_char_ptr_char_boundary
    source = <<~MT
      # module demo.main

      import std.mem as mem

      function main() -> void:
          var fixed = zero[array[char, 32]]
          var dynamic = zero[array[char, 64]]
          mem.write_fixed(fixed)
          mem.write_dynamic(dynamic)
    MT

    imported_sources = {
      "std/c/mem.mt" => <<~MT,
        # module std.c.mem
        external
        include "mem.h"

        external function WriteFixed(label: ptr[char]) -> void
        external function WriteDynamic(label: ptr[char]) -> void
      MT
      "std/mem.mt" => <<~MT,
        # module std.mem

        import std.c.mem as c

        public foreign function write_fixed(label: array[char, 32] as ptr[char]) -> void = c.WriteFixed(label)
        public foreign function write_dynamic(label: span[char] as ptr[char]) -> void = c.WriteDynamic(label)
      MT
    }

    generated = generate_c_from_program_source(source, imported_sources)

    assert_match(/WriteFixed\(&fixed\[0\]\);/, generated)
    assert_match(/WriteDynamic\(\(\(mt_span_char\)\{ \.data = &dynamic\[0\], \.len = 64 \}\)\.data\);/, generated)
  end

  def test_generate_c_for_foreign_mapping_public_alias_boundary_and_length
    source = <<~MT
      # module demo.main

      import std.ui as ui

      function main() -> void:
          var buffer = zero[array[char, 32]]
          ui.text_box(buffer)
    MT

    imported_sources = {
      "std/c/ui.mt" => <<~MT,
        # module std.c.ui
        external
        include "ui.h"

        external function TextBox(text: ptr[char], text_size: int) -> void
      MT
      "std/ui.mt" => <<~MT,
        # module std.ui

        import std.c.ui as c

        public foreign function text_box(text: span[char] as ptr[char]) -> void = c.TextBox(text, int<-text_public.len)
      MT
    }

    generated = generate_c_from_program_source(source, imported_sources)

    assert_match(/mt_span_char __mt_foreign_arg_public_\d+ = \{ \.data = &buffer\[0\], \.len = 32 \};/, generated)
    assert_match(/TextBox\(__mt_foreign_arg_public_\d+\.data, \(int32_t\) __mt_foreign_arg_public_\d+\.len\);/, generated)
  end

  def test_generate_c_for_unsafe_typed_null_pointer_to_cstr_casts
    source = <<~MT

# module demo.typed_null_cstr_surface

external function set_text(value: cstr) -> void

function main() -> void:
    unsafe:
        set_text(cstr<-null[ptr[char]])

    MT

    generated = generate_c_from_source(source)

    assert_match(/set_text\(\(const char\*\) NULL\);/, generated)
  end

  def test_generate_c_for_unsafe_integer_to_char_buffer_writes
    source = <<~MT

# module demo.char_buffer_surface

function main() -> int:
    var ptr: ptr[char] = zero[ptr[char]]
    unsafe:
        ptr[0] = 65
        ptr[1] = char<-66
    return 0

    MT

    generated = generate_c_from_source(source)

    assert_match(/ptr\[0\] = \(char\) 65;/, generated)
    assert_match(/ptr\[1\] = \(char\) 66;/, generated)
  end

  def test_generate_c_for_unsafe_pointer_offsets_without_ptr_uint_casts
    source = <<~MT

# module demo.pointer_offset_surface

function main() -> int:
    var ptr: ptr[char] = zero[ptr[char]]
    let offset = 1
    unsafe:
        var next = ptr + offset
        next[offset - 1] = 65
    return 0

    MT

    generated = generate_c_from_source(source)

    assert_match(/char \*next = ptr \+ offset;/, generated)
    assert_match(/next\[offset - 1\] = \(char\) 65;/, generated)
  end

  def test_generate_c_for_ref_arguments_passed_to_by_value_parameters
    source = <<~MT

# module demo.ref_value_args

struct Counter:
    value: int

external function consume(counter: Counter) -> void

function project(counter: Counter) -> int:
    return counter.value

function main() -> int:
    var counter = Counter(value = 7)
    let handle = ref_of(counter)
    consume(read(handle))
    return project(read(handle))

    MT

    generated = generate_c_from_source(source)

    assert_match(/consume\(\*handle\);/, generated)
    assert_match(/return demo_ref_value_args_project\(\*handle\);/, generated)
  end

  def test_generate_c_for_left_biased_float_literal_inference
    source = <<~MT

# module demo.float_literal_inference

function main() -> int:
    let value: float = 4.0
    let inverse = 1.0 / value
    let scaled = -2.0 / value
    if inverse > scaled:
        return 0
    return 1

    MT

    generated = generate_c_from_source(source)

    assert_match(/float inverse = 1\.0f \/ value;/, generated)
    assert_match(/float scaled = -2\.0f \/ value;/, generated)
  end

  def test_generate_c_for_callable_value_storage_and_indirect_calls
    source = <<~MT

# module demo.callable_values

struct Entry:
    callback: fn(value: float) -> float

function identity(value: int) -> int:
    return value

function ease(value: float) -> float:
    return value + 2.0

function main() -> int:
    let callbacks = array[fn(value: int) -> int, 1](identity)
    let entry = Entry(callback = ease)
    let callback: fn(value: float) -> float = entry.callback
    let left = callbacks[0](1)
    let right = callback(1.0)
    return left + int<-right

    MT

    generated = generate_c_from_source(source)

    assert_match(/float \(\*callback\)\(float value\);/, generated)
    assert_match(/int32_t \(\*callbacks\[1\]\)\(int32_t value\)/, generated)
    assert_match(/int32_t left = \(\*mt_checked_index_array_.*_1\(&callbacks, 0\)\)\(1\);/, generated)
    assert_match(/float right = callback\(1\.0f\);/, generated)
  end

  def test_generate_c_for_imported_function_callable_values
    source = <<~MT

# module demo.main

import std.ease as ease

struct Entry:
    callback: fn(value: int) -> int

function main() -> int:
    let callbacks = array[fn(value: int) -> int, 1](ease.times_two)
    let entry = Entry(callback = ease.times_two)
    return callbacks[0](3) + entry.callback(4)

    MT

    imported_sources = {
      "std/ease.mt" => <<~MT,

# module std.ease

public function times_two(value: int) -> int:
    return value * 2

      MT
    }

    generated = generate_c_from_program_source(source, imported_sources)

    assert_match(/int32_t \(\*callbacks\[1\]\)\(int32_t value\) = \{ std_ease_times_two \};/, generated)
    assert_match(/\.callback = std_ease_times_two/, generated)
    assert_match(/return \(\*mt_checked_index_array_.*_1\(&callbacks, 0\)\)\(3\) \+ entry\.callback\(4\);/, generated)
  end

  def test_generate_c_for_stored_callable_values_with_ref_parameters
    source = <<~MT

# module demo.ref_callable_values

struct Counter:
    value: int

struct Entry:
    callback: fn(arg0: ref[Counter]) -> bool

function increment(counter: ref[Counter]) -> bool:
    counter.value += 1
    return true

function main() -> int:
    var counter = Counter(value = 0)
    let entry = Entry(callback = increment)
    let callbacks = array[fn(arg0: ref[Counter]) -> bool, 1](entry.callback)
    if not callbacks[0](ref_of(counter)):
        return 1
    return counter.value

    MT

    generated = generate_c_from_source(source)

    assert_match(/bool \(\*callback\)\(demo_ref_callable_values_Counter \*arg0\);/, generated)
    assert_match(/bool \(\*callbacks\[1\]\)\(demo_ref_callable_values_Counter \*arg0\)/, generated)
    assert_match(/\(\*mt_checked_index_array_.*_1\(&callbacks, 0\)\)\(&counter\)/, generated)
  end

  def test_generate_c_for_same_length_function_arrays_with_distinct_signatures
    source = <<~MT

# module demo.same_length_fn_arrays

struct Counter:
    value: int

function plus_three(value: int) -> int:
    return value + 3

function increment(counter: ref[Counter]) -> bool:
    counter.value += 1
    return true

function main() -> int:
    var counter = Counter(value = 0)
    let callbacks = array[fn(value: int) -> int, 2](plus_three, plus_three)
    let ref_callbacks = array[fn(arg0: ref[Counter]) -> bool, 2](increment, increment)
    if callbacks[0](1) != 4:
        return 1
    if not ref_callbacks[0](ref_of(counter)):
        return 2
    return counter.value

    MT

    generated = generate_c_from_source(source)

    assert_match(/static inline int32_t \(\*\*mt_checked_index_array_int32_t_value_int32_t_value_2\(/, generated)
    assert_match(/static inline bool \(\*\*mt_checked_index_array_bool_value_demo_same_length_fn_arrays_Counter_arg0_2\(/, generated)
    assert_match(/\(\*mt_checked_index_array_int32_t_value_int32_t_value_2\(&callbacks, 0\)\)\(1\)/, generated)
    assert_match(/\(\*mt_checked_index_array_bool_value_demo_same_length_fn_arrays_Counter_arg0_2\(&ref_callbacks, 0\)\)\(&counter\)/, generated)
  end

  def test_generate_c_for_proc_closure_capture_and_param_calls
    source = <<~MT

# module demo.proc_codegen

function apply(callback: proc(value: int) -> int, value: int) -> int:
    return callback(value)

function main() -> int:
    let offset = 4
    let callback = proc(value: int) -> int:
        return value * 2 + offset
    return apply(callback, 3)

    MT

    generated = generate_c_from_source(source)

    assert_match(/typedef struct mt_proc_proc_int_int/, generated)
    assert_match(/typedef struct demo_proc_codegen__proc_1__env/, generated)
    assert_match(/mt_async_alloc\(sizeof\(demo_proc_codegen__proc_1__env\)\)/, generated)
    assert_match(/mt_async_free\(__mt_proc_env\);/, generated)
    assert_match(/\.invoke = demo_proc_codegen__proc_1__invoke/, generated)
    assert_match(/\.release = demo_proc_codegen__proc_1__release/, generated)
    assert_match(/\.retain = demo_proc_codegen__proc_1__retain/, generated)
    assert_match(/callback\.invoke\(callback\.env, value\)/, generated)
  end

  def test_generate_c_for_proc_return_and_struct_field
    source = <<~MT

# module demo.proc_surface

struct Holder:
    callback: proc(value: int) -> int

function factory(offset: int) -> proc(value: int) -> int:
    return proc(value: int) -> int:
        return value + offset

function call(holder: Holder, value: int) -> int:
    return holder.callback(value)

function main() -> int:
    let cb = factory(2)
    let holder = Holder(callback = cb)
    return call(holder, 40)

    MT

    generated = generate_c_from_source(source)

    assert_match(/typedef struct demo_proc_surface_Holder/, generated)
    assert_match(/cb\.retain\(cb\.env\);/, generated)
    assert_match(/holder\.callback\.invoke\(holder\.callback\.env, value\)/, generated)
    assert_match(/holder\.callback\.release\(holder\.callback\.env\);/, generated)
  end

  def test_generate_c_for_proc_assignment_lifecycle
    source = <<~MT

# module demo.proc_assign_lifecycle

struct Holder:
    callback: proc(value: int) -> int

function main() -> int:
    let ca = proc(value: int) -> int:
        return value + 1
    let cb = proc(value: int) -> int:
        return value + 2
    let a = Holder(callback = ca)
    var b = Holder(callback = cb)
    b = a
    return b.callback(1)

    MT

    generated = generate_c_from_source(source)

    # Struct assignment retain: ca is an existing proc read(not a direct proc expr in the assignment RHS),
    # so it gets retained for b's ownership.
    assert_match(/__mt_proc_assign_\d+\.callback\.retain\(__mt_proc_assign_\d+\.callback\.env\)/, generated)
    # Old b.callback released (guarded) before overwrite.
    assert_match(/if \(b\.callback\.invoke\)/, generated)
    assert_match(/b\.callback\.release\(b\.callback\.env\)/, generated)
    # Deferred cleanup uses null-guarded release on all proc-containing locals.
    assert_match(/if \(a\.callback\.invoke\)/, generated)
    assert_match(/a\.callback\.release\(a\.callback\.env\)/, generated)
  end

  def test_generate_c_for_proc_field_assignment_lifecycle
    source = <<~MT

# module demo.proc_field_assign

struct Holder:
    callback: proc(value: int) -> int

function main() -> int:
    let ca = proc(value: int) -> int:
        return value + 1
    var h = Holder(callback = ca)
    let cb = proc(value: int) -> int:
        return value + 2
    h.callback = cb
    return h.callback(1)

    MT

    generated = generate_c_from_source(source)

    # h.callback = cb: cb is an existing proc (let cb = ..., not a direct proc expr in the field assignment).
    # Retain is emitted, old field is released.
    assert_match(/__mt_proc_assign_\d+\.retain\(__mt_proc_assign_\d+\.env\)/, generated)
    assert_match(/if \(h\.callback\.invoke\)/, generated)
    assert_match(/h\.callback\.release\(h\.callback\.env\)/, generated)
  end

  def test_generate_c_for_stored_proc_closure_values_with_ref_parameters
    source = <<~MT

# module demo.proc_ref_storage_codegen

struct Counter:
    value: int

struct Entry:
    callback: proc(arg0: ref[Counter]) -> bool

function main() -> int:
    let offset = 2
    let callback = proc(arg0: ref[Counter]) -> bool:
        arg0.value += offset
        return true
    let entry = Entry(callback = callback)
    let callbacks = array[proc(arg0: ref[Counter]) -> bool, 1](entry.callback)
    var counter = Counter(value = 0)
    if not callbacks[0](ref_of(counter)):
        return 1
    return counter.value

    MT

    generated = generate_c_from_source(source)

    assert_match(/typedef struct mt_proc_proc_ref_demo_proc_ref_storage_codegen_Counter_bool/, generated)
    assert_match(/\.invoke = demo_proc_ref_storage_codegen__proc_1__invoke/, generated)
    assert_match(/entry\.callback\.retain\(entry\.callback\.env\);/, generated)
    assert_match(/\(\*mt_checked_index_array_mt_proc_proc_ref_demo_proc_ref_storage_codegen_Counter_bool_value_1\(&callbacks, 0\)\)\.invoke\(\(\*mt_checked_index_array_mt_proc_proc_ref_demo_proc_ref_storage_codegen_Counter_bool_value_1\(&callbacks, 0\)\)\.env, &counter\)/, generated)
  end

  def test_generate_c_for_proc_var_reassign_lifecycle
    source = <<~MT

# module demo.proc_var_reassign

function main() -> int:
    var callback = proc(value: int) -> int:
        return value + 1
    callback = proc(value: int) -> int:
        return value + 2
    return callback(0)

    MT

    generated = generate_c_from_source(source)

    # Reassignment with a fresh proc expr: no retain (transfer ownership), but old callback is released.
    assert_match(/if \(callback\.invoke\)/, generated)
    assert_match(/callback\.release\(callback\.env\)/, generated)
  end

  def test_generate_c_for_module_scope_mutable_vars
    source = <<~MT

# module demo.global_state

const BASE: int = 1

function identity(value: int) -> int:
    return value

var counter: int = BASE
var scratch: array[ubyte, 4]
var callbacks: array[fn(value: int) -> int, 1] = array[fn(value: int) -> int, 1](identity)

function main() -> int:
    counter = callbacks[0](counter)
    return counter + int<-scratch[0]

    MT

    generated = generate_c_from_source(source)

    assert_match(/static int32_t demo_global_state_counter = 1;/, generated)
    assert_match(/static uint8_t demo_global_state_scratch\[4\] = \{ 0 \};/, generated)
    assert_match(/static int32_t \(\*demo_global_state_callbacks\[1\]\)\(int32_t value\) = \{ demo_global_state_identity \};/, generated)
    refute_match(/static int32_t demo_global_state_counter = demo_global_state_BASE;/, generated)
  end

  def test_generate_c_for_integer_match_with_default_case
    source = <<~MT

# module demo.int_match

function dispatch(key: int) -> int:
    match key:
        65:
            return 1
        27:
            return 2
        _:
            return 0

function main() -> int:
    return dispatch(65)

    MT

    generated = generate_c_from_source(source)

    assert_match(/switch \(key\) \{/, generated)
    assert_match(/case 65: \{/, generated)
    assert_match(/case 27: \{/, generated)
    assert_match(/default: \{/, generated)
    assert_match(/return 1;/, generated)
    assert_match(/return 2;/, generated)
    assert_match(/return 0;/, generated)
    refute_match(/case 0:/, generated)
  end

  def test_generate_c_for_enum_match_with_wildcard
    source = <<~MT

# module demo.enum_wild

enum EventKind: ubyte
    quit = 1
    resize = 2
    key = 3

function dispatch(kind: EventKind) -> int:
    match kind:
        EventKind.quit:
            return 0
        _:
            return 1

function main() -> int:
    return dispatch(EventKind.quit)

    MT

    generated = generate_c_from_source(source)

    assert_match(/switch \(kind\) \{/, generated)
    assert_match(/case demo_enum_wild_EventKind_quit: \{/, generated)
    assert_match(/default: \{/, generated)
    assert_match(/return 0;/, generated)
    assert_match(/return 1;/, generated)
  end

  def test_generate_c_omits_non_void_fallback_after_exhaustive_match_switch
    source = <<~MT
      # module demo.non_void_match_fallback



      function select_bool(value: Option[bool]) -> bool:
          match value:
              Option.none:
                  return false
              Option.some as payload:
                  return payload.value

      function select_ptr(value: Option[ptr[int]], fallback: ptr[int]) -> ptr[int]:
          match value:
              Option.none:
                  return fallback
              Option.some as payload:
                  return payload.value

      function main() -> int:
          var number = 7
          if not select_bool(Option[bool].some(value = true)):
              return 1
          let chosen = select_ptr(Option[ptr[int]].none, ptr_of(number))
          unsafe:
              if read(chosen) != 7:
                  return 2
          return 0
    MT

    generated = generate_c_from_program_source(source)

    function_select_bool = generated[/static bool demo_non_void_match_fallback_select_bool\(.*?^\}/m]
    function_select_ptr = generated[/static int32_t \*demo_non_void_match_fallback_select_ptr\(.*?^\}/m]

    refute_nil(function_select_bool)
    refute_nil(function_select_ptr)
    refute_match(/\n  \}\n  return false;\n\}/m, function_select_bool)
    refute_match(/\n  \}\n  return \(int32_t \*\) NULL;\n\}/m, function_select_ptr)
  end

  def test_generate_c_omits_dead_code_after_nested_exhaustive_match
    source = <<~MT
      # module demo.nested_match_dead_code

      function select(value: Result[Option[bool], int]) -> bool:
          match value:
              Result.failure as payload:
                  return payload.error == 0
              Result.success as payload:
                  match payload.value:
                      Option.none:
                          return false
                      Option.some as inner:
                          return inner.value
                  return true
    MT

    generated = generate_c_from_program_source(source)
    function_body = generated[/static bool demo_nested_match_dead_code_select\(.*?^\}/m]

    refute_nil(function_body)
    refute_match(/return true;/, function_body)
  end

  def test_generate_c_for_variant_tagged_union_structs
    source = <<~MT
      # module demo.variant_codegen

      variant Token:
          ident(text: str)
          number(value: int)
          eof

      function kind_of(tok: Token) -> int:
          match tok:
              Token.ident:
                  return 0
              Token.number:
                  return 1
              Token.eof:
                  return 2
    MT

    generated = generate_c_from_source(source)

    # Kind typedef and constants
    assert_match(/typedef int32_t demo_variant_codegen_Token_kind;/, generated)
    assert_match(/demo_variant_codegen_Token_kind_ident = 0/, generated)
    assert_match(/demo_variant_codegen_Token_kind_number = 1/, generated)
    assert_match(/demo_variant_codegen_Token_kind_eof = 2/, generated)
    # Per-arm payload structs emitted
    assert_match(/struct demo_variant_codegen_Token_ident \{/, generated)
    assert_match(/struct demo_variant_codegen_Token_number \{/, generated)
    # Data union (ident and number have payloads)
    assert_match(/union demo_variant_codegen_Token__data \{/, generated)
    # Outer struct with kind and data fields
    assert_match(/struct demo_variant_codegen_Token \{/, generated)
    assert_match(/demo_variant_codegen_Token_kind kind;/, generated)
    # Typedef
    assert_match(/typedef struct demo_variant_codegen_Token demo_variant_codegen_Token;/, generated)
    # Match on .kind
    assert_match(/switch \(.*\.kind\)/, generated)
    assert_match(/case demo_variant_codegen_Token_kind_ident:/, generated)
    assert_match(/case demo_variant_codegen_Token_kind_number:/, generated)
    assert_match(/case demo_variant_codegen_Token_kind_eof:/, generated)
  end

  def test_generate_c_for_variant_construction
    source = <<~MT
      # module demo.variant_ctor_codegen

      variant Event:
          click(x: int, y: int)
          quit

      function make_quit() -> Event:
          return Event.quit

      function make_click(x: int, y: int) -> Event:
          return Event.click(x= x, y= y)
    MT

    generated = generate_c_from_source(source)

    # No-payload arm literal
    assert_match(/demo_variant_ctor_codegen_Event_kind_quit/, generated)
    # Payload arm literal references kind constant and struct
    assert_match(/demo_variant_ctor_codegen_Event_kind_click/, generated)
    assert_match(/\.kind = demo_variant_ctor_codegen_Event_kind_click/, generated)
  end

  def test_generate_c_for_variant_as_binding_field_access
    source = <<~MT
      # module demo.variant_as_binding

      variant Shape:
          circle(radius: double)
          point

      function area(s: Shape) -> double:
          match s:
              Shape.circle as c:
                  return c.radius * c.radius
              Shape.point:
                  return 0.0
    MT

    generated = generate_c_from_source(source)

    # as-binding declared with struct type and initialized from .data
    assert_match(/demo_variant_as_binding_Shape_circle/, generated)
    assert_match(/\.radius/, generated)
    assert_match(/return 0\.0/, generated)
  end

  def test_generate_c_for_union_with_proc_field
    source = <<~MT
      # module demo.union_proc_codegen

      union CallbackOrValue:
          callback: proc() -> int
          value: int

      function main() -> int:
          return 0
    MT

    generated = generate_c_from_source(source)

    assert_match(/typedef struct mt_proc_/, generated)
    assert_match(/typedef union demo_union_proc_codegen_CallbackOrValue/, generated)
    assert_match(/mt_proc_.* callback;/, generated)
  end

  def test_generate_c_format_precision_spec_calls_append_double_precision
    source = <<~MT
      # module demo.fmt_spec

      function main(pi: double, small: float) -> int:
          let formatted_pi = f"pi=\#{pi:.2}"
          let formatted_small = f"small=\#{small:.5}"
          return int<-formatted_pi.len + int<-formatted_small.len
    MT

    generated = generate_c_from_source(source)

    assert_match(/mt_format_append_double_precision\(/, generated)
    assert_match(/,\s*2\s*\)/, generated)
    assert_match(/,\s*5\s*\)/, generated)
  end

  def test_generate_c_format_hex_spec_calls_hex_helpers
    source = <<~MT
      # module demo.fmt_hex_codegen

      function main(value: int) -> int:
          let lower = f"hex=\#{value:x}"
          let upper = f"HEX=\#{value:X}"
          return int<-lower.len + int<-upper.len
    MT

    generated = generate_c_from_source(source)

    assert_match(/mt_format_append_long_hex\(/, generated)
    assert_match(/mt_format_append_long_hex_upper\(/, generated)
    assert_match(/mt_format_ulong_hex_len\(/, generated)
  end

  def test_generate_c_format_octal_and_binary_specs_call_helpers
    source = <<~MT
      # module demo.fmt_oct_bin_codegen

      function main(value: int) -> int:
          let octal = f"oct=\#{value:o}"
          let binary = f"bin=\#{value:b}"
          return int<-octal.len + int<-binary.len
    MT

    generated = generate_c_from_source(source)

    assert_match(/mt_format_append_long_oct\(/, generated)
    assert_match(/mt_format_append_long_bin\(/, generated)
    assert_match(/mt_format_ulong_oct_len\(/, generated)
    assert_match(/mt_format_ulong_bin_len\(/, generated)
  end

  def test_run_program_for_while_loop
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT
      # module demo.while_runtime

      function main() -> int:
          var total = 0
          var i = 1
          while i <= 10:
              total += i
              i += 1
          return total
    MT

    result = run_program_from_source(source, compiler:)

    assert_equal "", result.stderr
    assert_equal 55, result.exit_status
  end

  def test_run_program_for_boolean_operators
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT
      # module demo.bool_runtime

      function main() -> int:
          var result = 0
          if true and true:
              result += 1
          if true and false:
              result += 10
          if false or true:
              result += 1
          if false or false:
              result += 10
          if not false:
              result += 1
          if not true:
              result += 10
          if not (true and false):
              result += 1
          return result
    MT

    result = run_program_from_source(source, compiler:)

    assert_equal "", result.stderr
    assert_equal 4, result.exit_status
  end

  def test_run_program_for_bitwise_operators
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT
      # module demo.bitwise_runtime

      function main() -> int:
          var result = 0
          result += 3 | 5
          result += 3 & 5
          result += 3 ^ 5
          result += 1 << 3
          result += 16 >> 2
          result += ~0
          return result
    MT

    result = run_program_from_source(source, compiler:)

    assert_equal "", result.stderr
    assert_equal 7 + 1 + 6 + 8 + 4 + (-1), result.exit_status
  end

  def test_run_program_for_modulo_operator
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT
      # module demo.modulo_runtime

      function main() -> int:
          return 17 % 5
    MT

    result = run_program_from_source(source, compiler:)

    assert_equal "", result.stderr
    assert_equal 2, result.exit_status
  end

  def test_run_program_for_flags_enum_and_match
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT
      # module demo.flags_runtime

      flags Permission: uint
          read = 1 << 0
          write = 1 << 1
          execute = 1 << 2

      enum Status: int
          ok = 0
          error = 1

      function main() -> int:
          let perm = Permission.read | Permission.write
          if (perm & Permission.read) == Permission.read:
              if (perm & Permission.write) == Permission.write:
                  if (perm & Permission.execute) != Permission.execute:
                      let state = Status.ok
                      match state:
                          Status.ok:
                              return 0
                          Status.error:
                              return 1
          return 2
    MT

    result = run_program_from_source(source, compiler:)

    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
  end

  def test_generate_c_for_nullable_array_indexing
    source = <<~MT
      # module demo.nullable_array

      function main() -> int:
          var arr = array[int, 4](10, 20, 30, 40)
          let p = get(arr, 1) else:
              return 1
          unsafe:
              return read(p)
    MT

    result = generate_c_from_source(source)

    assert_match(/static inline int\d*_t \*mt_nullable_index_array_int_4\(int\d*_t \(\*array\)\[4\], uintptr_t index\)/, result)
    assert_match(/if \(index >= 4\) return NULL/, result)
  end

  def test_generate_c_for_nullable_span_indexing
    source = <<~MT
      # module demo.nullable_span

      function main() -> int:
          var value = 7
          let sp = span[int](data = ptr_of(value), len = 1)
          let p = get(sp, 0) else:
              return 1
          unsafe:
              return read(p)
    MT

    result = generate_c_from_source(source)

    assert_match(/static inline int\d*_t \*mt_nullable_span_index_span_int\(mt_span_int span, uintptr_t index\)/, result)
    assert_match(/if \(index >= span\.len\) return NULL/, result)
  end

  def test_generate_c_for_proc_array_capture
    source = <<~MT

# module demo.proc_array_capture

function main() -> int:
    let arr = array[int, 3](1, 2, 3)
    let cb = proc() -> int:
        return arr[0] + arr[1] + arr[2]
    return cb()

    MT

    generated = generate_c_from_source(source)

    assert_match(/typedef struct demo_proc_array_capture__proc_1__env/, generated)
    assert_match(/int32_t arr\[3\]/, generated)
    assert_match(/memcpy\(.*->arr, arr, sizeof\(.*->arr\)\)/, generated)
    assert_match(/mt_async_alloc\(sizeof\(demo_proc_array_capture__proc_1__env\)\)/, generated)
    assert_match(/mt_async_free\(__mt_proc_env\);/, generated)
    assert_match(/\.invoke = demo_proc_array_capture__proc_1__invoke/, generated)
    assert_match(/\.release = demo_proc_array_capture__proc_1__release/, generated)
    assert_match(/\.retain = demo_proc_array_capture__proc_1__retain/, generated)
  end

  def test_generate_c_for_proc_capturing_proc
    source = <<~MT

# module demo.proc_capture_proc

function main() -> int:
    let offset = 10
    let inner = proc() -> int:
        return 5
    let outer = proc() -> int:
        return inner() + offset
    return outer()

    MT

    generated = generate_c_from_source(source)

    assert_match(/typedef struct demo_proc_capture_proc__proc_2__env/, generated)
    assert_match(/inner\.retain\(/, generated)
    assert_match(/inner\.release\(/, generated)
    assert_match(/mt_async_free\(__mt_proc_env\);/, generated)
    assert_match(/\.invoke = demo_proc_capture_proc__proc_2__invoke/, generated)
    assert_match(/\.release = demo_proc_capture_proc__proc_2__release/, generated)
    assert_match(/\.retain = demo_proc_capture_proc__proc_2__retain/, generated)
  end

  def test_generate_c_for_nested_proc_returns
    source = <<~MT

# module demo.nested_proc_codegen

function factory(x: int) -> proc() -> int:
    return proc() -> int:
        return x

function main() -> int:
    let cb = factory(42)
    return cb()

    MT

    generated = generate_c_from_source(source)

    assert_match(/typedef struct demo_nested_proc_codegen__proc_1__env/, generated)
    assert_match(/mt_async_alloc\(sizeof\(demo_nested_proc_codegen__proc_1__env\)\)/, generated)
    assert_match(/mt_async_free\(__mt_proc_env\);/, generated)
    assert_match(/\.invoke = demo_nested_proc_codegen__proc_1__invoke/, generated)
    assert_match(/\.release = demo_nested_proc_codegen__proc_1__release/, generated)
    assert_match(/\.retain = demo_nested_proc_codegen__proc_1__retain/, generated)
  end

  def test_generate_c_for_proc_returning_proc
    source = <<~MT

# module demo.proc_return_proc_codegen

function make_adder(base: int) -> proc(add: int) -> int:
    return proc(add: int) -> int:
        return base + add

function main() -> int:
    let adder = make_adder(10)
    return adder(5)

    MT

    generated = generate_c_from_source(source)

    assert_match(/typedef struct demo_proc_return_proc_codegen__proc_1__env/, generated)
    assert_match(/mt_async_alloc\(sizeof\(demo_proc_return_proc_codegen__proc_1__env\)\)/, generated)
    assert_match(/mt_async_free\(__mt_proc_env\);/, generated)
    assert_match(/\.invoke = demo_proc_return_proc_codegen__proc_1__invoke/, generated)
    assert_match(/\.release = demo_proc_return_proc_codegen__proc_1__release/, generated)
    assert_match(/\.retain = demo_proc_return_proc_codegen__proc_1__retain/, generated)
  end

  def test_generate_c_for_float_suffix_literals
    source = <<~MT

# module demo.lit_suffix_float

function main() -> float:
    return 1.0f

    MT

    generated = generate_c_from_source(source)
    assert_match(/1\.0f/, generated)
  end

  def test_generate_c_for_double_suffix_literals
    source = <<~MT

# module demo.lit_suffix_double

function main() -> double:
    return 1.0d

    MT

    generated = generate_c_from_source(source)
    assert_match(/1\.0/, generated)
  end

  def test_generate_c_for_integer_underscore_separators
    source = <<~MT

# module demo.underscore_codegen

function main() -> int:
    return 1_000_000 + 0xff_ff + 0b1010_0101

    MT

    generated = generate_c_from_source(source)
    assert_match(/1000000/, generated)
    assert_match(/65535/, generated)
    assert_match(/165/, generated)
  end

  def test_generate_c_for_deprecated_attribute
    source = <<~MT

# module demo.deprecated_codegen

@[deprecated("use newer instead")]
function old_func(x: int) -> int:
    return x

function main() -> int:
    return old_func(1)

    MT

    generated = generate_c_from_source(source)
    assert_match(/old_func/, generated)
  end

  def test_generate_c_for_attributes_of
    source = <<~MT

# module demo.attributes_of_codegen

@[packed]
struct Packed:
    a: ubyte
    b: ubyte

function main() -> int:
    return 0

    MT

    generated = generate_c_from_source(source)
    assert_match(/Packed/, generated)
  end

  def test_generate_c_for_members_of_enum
    source = <<~MT

# module demo.members_of_codegen

enum Fruit: ubyte
    apple = 1
    banana = 2

function main() -> int:
    var count: int = 0
    inline for member in members_of(Fruit):
        count += 1
    return count

    MT

    generated = generate_c_from_source(source)
    assert_match(/count \+= 1;/, generated)
  end

  def test_generate_c_for_block_bodied_const
    source = <<~MT

# module demo.block_const_codegen

const POW2 -> int:
    var n: int = 1
    while n < 64:
        n = n * 2
    return n

function main() -> int:
    return POW2

    MT

    generated = generate_c_from_source(source)
    assert_match(/POW2 = 64/, generated)
  end

  def test_generate_c_for_vec2_type
    source = <<~MT

# module demo.vec2_codegen

function main() -> float:
    let v = vec2(x = 1.0, y = 2.0)
    return v.x + v.y

    MT

    generated = generate_c_from_source(source)
    assert_match(/vec2/, generated)
  end

  def test_generate_c_for_mat3_type
    source = <<~MT

# module demo.mat3_codegen

function main() -> float:
    let m = mat3(
        col0 = vec3(x = 1.0, y = 0.0, z = 0.0),
        col1 = vec3(x = 0.0, y = 1.0, z = 0.0),
        col2 = vec3(x = 0.0, y = 0.0, z = 1.0),
    )
    return m.col0.x

    MT

    generated = generate_c_from_source(source)
    assert_match(/mat3/, generated)
  end

  def test_generate_c_for_ivec3_type
    source = <<~MT

# module demo.ivec3_codegen

function main() -> int:
    let v = ivec3(x = 1, y = 2, z = 3)
    return v.x + v.y + v.z

    MT

    generated = generate_c_from_source(source)
    assert_match(/ivec3/, generated)
  end

  def test_generate_c_for_emit_statement
    source = <<~MT

# module demo.emit_codegen

const function gen() -> void:
    emit function helper() -> int:
        return 42

function main() -> int:
    return helper()

    MT

    generated = generate_c_from_source(source)
    assert_match(/42/, generated)
  end

  def test_generate_c_for_emit_struct_and_const
    source = <<~MT

# module demo.emit_struct

struct Point:
    x: int
    y: int

const function gen() -> void:
    emit function make_point() -> Point:
        return Point(x = 10, y = 20)

    emit const LABEL: str = "emitted"

function main() -> int:
    let p = make_point()
    let _ = LABEL
    return p.x + p.y

    MT

    generated = generate_c_from_source(source)
    assert_match(/10/, generated)
    assert_match(/20/, generated)
    assert_match(/emitted/, generated)
  end

end
