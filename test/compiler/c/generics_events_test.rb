# frozen_string_literal: true

require_relative "helpers"

class GenericsEventsTest < Minitest::Test
  include CodegenTestHelpers

  def test_generate_c_for_event_declarations_and_runtime_helpers
    source = <<~MT
      # module demo.event_codegen

      struct Resize:
          width: int
          height: int

      event reloaded[4]

      struct Window:
          public event closed[4]
          public event resized[8](Resize)
          title: str

      function on_close() -> void:
          return

      function on_resize(value: Resize) -> void:
          return

      function attach(window: ref[Window]) -> Result[Subscription, EventError]:
          let sub = window.closed.subscribe(on_close)?
          let resized_sub = window.resized.subscribe(on_resize)?
          window.resized.unsubscribe(resized_sub)
          return window.closed.subscribe(on_close)

      function trigger(window: ref[Window]) -> Result[Subscription, EventError]:
          reloaded.subscribe(on_close)?
          reloaded.emit()
          window.closed.emit()
          window.resized.emit(Resize(width = 1, height = 2))
          return window.closed.subscribe(on_close)

      async function wait_for_resize(window: ref[Window]) -> Result[Resize, EventError]:
          return await window.resized.wait()
    MT

    generated = generate_c_from_program_source(source)

    assert_match(/mt_subscription/, generated)
    assert_match(/mt_event_demo_event_codegen_reloaded_4__subscribe/, generated)
    assert_match(/mt_event_demo_event_codegen_reloaded_4__emit/, generated)
    assert_match(/__event_closed/, generated)
    assert_match(/mt_event_demo_event_codegen_Window_resized.*__wait/, generated)
    assert_match(/mt_async_alloc/, generated)
  end

  def test_generate_c_for_full_event_wait_without_failure_allocation
    source = <<~MT
      # module demo.event_wait_full_codegen

      event ready[1]

      async function wait_for_ready() -> Result[void, EventError]:
          return await ready.wait()
    MT

    generated = generate_c_from_program_source(source)

    assert_match(/if \(frame == NULL\) \{\s*return true;/m, generated)
    assert_match(/if \(frame == NULL\) \{\s*waiter\(waiter_frame\);\s*return;/m, generated)
    assert_match(/if \(frame == NULL\) \{\s*return \(Result_void_EventError\)\{.*EventError_full.*\};\s*\}/m, generated)
    assert_match(/\.frame = NULL, \.ready = mt_event_demo_event_wait_full_codegen_ready_1__wait__ready/m, generated)
  end

  def test_generate_c_for_generic_methods
    source = <<~MT
      # module demo.generic_methods_codegen

      struct Box:
          value: int

      extending Box:
          function echo[T](input: T) -> T:
              return input

          static function make[T](input: T) -> T:
              return input

      function main() -> int:
          let box = Box(value = 1)
          let a = box.echo(3)
          let b = Box.make(4)
          return a + b
    MT

    generated = generate_c_from_program_source(source)

    assert_match(/demo_generic_methods_codegen_Box_echo_int/, generated)
    assert_match(/demo_generic_methods_codegen_Box_make_static_int/, generated)
    assert_match(/int32_t a = demo_generic_methods_codegen_Box_echo_int\(3\);/, generated)
    assert_match(/demo_generic_methods_codegen_Box_make_static_int\(4\)/, generated)
  end

  def test_generate_c_for_generic_receiver_methods
    source = <<~MT
      # module demo.generic_receiver_methods_codegen

      struct Box[T]:
          value: T

      extending Box[T]:
          function get() -> T:
              return this.value

          static function zero() -> Box[T]:
              return Box[T](value = zero[T])

          function echo[U](input: U) -> U:
              return input

      function main() -> int:
          let box = Box[int].zero()
          let echoed = box.echo(true)
          if echoed:
              return box.get()
          return 0
    MT

    generated = generate_c_from_program_source(source)

    assert_match(/demo_generic_receiver_methods_codegen_Box_zero_static_int/, generated)
    assert_match(/demo_generic_receiver_methods_codegen_Box_get_int/, generated)
    assert_match(/demo_generic_receiver_methods_codegen_Box_echo_int_bool/, generated)
    assert_match(/demo_generic_receiver_methods_codegen_Box_zero_static_int\(\)/, generated)
    assert_match(/demo_generic_receiver_methods_codegen_Box_get_int\(box\)/, generated)
    assert_match(/if \(demo_generic_receiver_methods_codegen_Box_echo_int_bool\(true\)\) \{/, generated)
  end

  def test_generate_c_for_generic_receiver_static_self_call
    source = <<~MT
      # module demo.generic_receiver_static_self_call_codegen

      struct Box[T]:
          value: T

      extending Box[T]:
          static function create() -> Box[T]:
              return Box[T](value = zero[T])

          static function with_default() -> Box[T]:
              return Box[T].create()

      function main() -> int:
          let box = Box[int].with_default()
          return box.value
    MT

    generated = generate_c_from_program_source(source)

    assert_match(/demo_generic_receiver_static_self_call_codegen_Box_create_static_int/, generated)
    assert_match(/demo_generic_receiver_static_self_call_codegen_Box_with_default_static_int/, generated)
    assert_match(/demo_generic_receiver_static_self_call_codegen_Box_create_static_int\(\)/, generated)
    assert_match(/demo_generic_receiver_static_self_call_codegen_Box_with_default_static_int\(\)/, generated)
  end

  def test_generate_c_for_default_specialization_with_explicit_associated_overrides
    source = <<~MT
      # module demo.default_codegen

      struct Player:
          hp: int

      extending Player:
          static function default() -> Player:
              return Player(hp = 100)

      struct Plain:
          hp: int

      extending Plain:
          static function default() -> Plain:
              return Plain(hp = 7)

      function make_default[T]() -> T:
          return default[T]

      function main() -> int:
          let player = make_default[Player]()
          let plain = make_default[Plain]()
          return player.hp + plain.hp
    MT

    generated = generate_c_from_program_source(source)

    assert_match(/static demo_default_codegen_Player demo_default_codegen_make_default_demo_default_codegen_Player\(void\)/, generated)
    assert_match(/return demo_default_codegen_Player_default_static\(\);/, generated)
    assert_match(/static demo_default_codegen_Plain demo_default_codegen_make_default_demo_default_codegen_Plain\(void\)/, generated)
    assert_match(/return demo_default_codegen_Plain_default_static\(\);/, generated)
  end

  def test_generate_c_for_generic_struct_instantiation_and_embedding
    source = <<~MT

# module demo.generic_surface

struct Slice[T]:
    data: ptr[T]
    len: ptr_uint

struct Holder:
    items: Slice[int]

function first(items: Slice[int]) -> int:
    if items.len == 0:
        return 0
    unsafe:
        return read(items.data)

function main() -> int:
    var value = 7
    let holder = Holder(items = Slice[int](data = ptr_of(value), len = 1))
    return first(holder.items)

    MT

    generated = generate_c_from_source(source)

    assert_match(/typedef struct demo_generic_surface_Slice_int demo_generic_surface_Slice_int;/, generated)
    assert_match(/typedef struct demo_generic_surface_Holder demo_generic_surface_Holder;/, generated)
    assert_match(/struct demo_generic_surface_Slice_int \{/, generated)
    assert_match(/int32_t \*data;/, generated)
    assert_match(/uintptr_t len;/, generated)
    assert_match(/struct demo_generic_surface_Holder \{/, generated)
    assert_match(/demo_generic_surface_Slice_int items;/, generated)
    assert_match(/static int32_t demo_generic_surface_first\(demo_generic_surface_Slice_int items\)/, generated)
    assert_match(/demo_generic_surface_Holder holder = \{ \.items = \{ \.data = &value, \.len = 1 \} \};/, generated)
  end

  def test_generate_c_for_generic_struct_used_only_in_expression
    source = <<~MT

# module demo.generic_expression_only

struct Box[T]:
    value: T

function main() -> int:
    let ok: bool = Box[int](value = 7).value == 7
    if ok:
        return 1
    return 0

    MT

    generated = generate_c_from_source(source)

    assert_match(/typedef struct demo_generic_expression_only_Box_int demo_generic_expression_only_Box_int;/, generated)
    assert_match(/struct demo_generic_expression_only_Box_int \{/, generated)
  end

  def test_generate_c_for_generic_functions_with_inferred_type_arguments
    source = <<~MT

# module demo.generic_functions

struct Slice[T]:
    data: ptr[T]
    len: ptr_uint

function head[T](items: Slice[T]) -> ptr[T]:
    return items.data

function min[T](a: T, b: T) -> T:
    if a < b:
        return a
    return b

function main() -> int:
    var value = 7
    let items = Slice[int](data = ptr_of(value), len = 1)
    let smallest = min(9, 4)
    unsafe:
        return read(head(items)) + smallest

    MT

    generated = generate_c_from_source(source)

    assert_match(/static int32_t \*demo_generic_functions_head_int\(demo_generic_functions_Slice_int items\)/, generated)
    assert_match(/static int32_t demo_generic_functions_min_int\(int32_t a, int32_t b\)/, generated)
    assert_match(/int32_t smallest = demo_generic_functions_min_int\(9, 4\);/, generated)
    assert_match(/return \*demo_generic_functions_head_int\(items\) \+ smallest;/, generated)
  end

  def test_generate_c_for_generic_functions_with_interface_constraints
    source = <<~MT

# module demo.interface_codegen

interface Damageable:
    editable function take_damage(amount: int) -> void
    function is_alive() -> bool

struct NPC implements Damageable:
    hp: int

extending NPC:
    editable function take_damage(amount: int):
        this.hp -= amount

    function is_alive() -> bool:
        return this.hp > 0

function damage_one[T implements Damageable](target: ref[T], amount: int) -> void:
    if target.is_alive():
        target.take_damage(amount)

function main() -> int:
    var npc = NPC(hp = 5)
    damage_one(npc, 2)
    return npc.hp

    MT

    generated = generate_c_from_source(source)

    assert_match(/static void demo_interface_codegen_damage_one_demo_interface_codegen_NPC\(/, generated)
    assert_match(/demo_interface_codegen_damage_one_demo_interface_codegen_NPC\(&npc, 2\);/, generated)
    refute_match(/Damageable/, generated)
  end

  def test_generate_c_for_generic_struct_with_interface_constraints
    source = <<~MT

# module demo.generic_struct_constraints

interface Damageable:
    function hp() -> int

struct NPC implements Damageable:
    value: int

extending NPC:
    function hp() -> int:
        return this.value

struct Holder[T implements Damageable]:
    value: T

function main() -> int:
    let holder = Holder[NPC](value = NPC(value = 9))
    return holder.value.hp()

    MT

    generated = generate_c_from_source(source)

    assert_match(/typedef struct demo_generic_struct_constraints_Holder_demo_generic_struct_constraints_NPC demo_generic_struct_constraints_Holder_demo_generic_struct_constraints_NPC;/, generated)
    assert_match(/struct demo_generic_struct_constraints_Holder_demo_generic_struct_constraints_NPC \{/, generated)
    refute_match(/Damageable/, generated)
  end

  def test_generate_c_for_hash_and_equal_builtins_in_imported_generic_functions
    source = <<~MT

# module demo.hash_equal_imported_codegen_main

import demo.hash_tools as tools

struct Key:
    value: int

extending Key:
    static function hash(value: const_ptr[Key]) -> uint:
        return uint<-0

    static function equal(left: const_ptr[Key], right: const_ptr[Key]) -> bool:
        return true

function main() -> bool:
    let left = Key(value = 1)
    let right = Key(value = 1)
    return tools.same_key(left, right)

    MT

    imported_sources = {
      "demo/hash_tools.mt" => <<~MT,
        # module demo.hash_tools

        public function same_key[T](left: T, right: T) -> bool:
            return hash[T](left) == hash[T](right) and equal[T](left, right)
      MT
    }

    generated = generate_c_from_program_source(source, imported_sources)

    assert_match(/static bool demo_hash_tools_same_key_demo_hash_equal_imported_codegen_main_Key\(demo_hash_equal_imported_codegen_main_Key left, demo_hash_equal_imported_codegen_main_Key right\)/, generated)
    assert_match(/demo_hash_equal_imported_codegen_main_Key_hash_static\(&left\)/, generated)
    assert_match(/demo_hash_equal_imported_codegen_main_Key_equal_static\(&left, &right\)/, generated)
  end

  def test_generate_c_for_order_builtin_in_imported_generic_functions
    source = <<~MT

# module demo.order_imported_codegen_main

import demo.order_tools as tools

struct Key:
    value: int

extending Key:
    static function order(left: const_ptr[Key], right: const_ptr[Key]) -> int:
        unsafe:
            let left_value = read(ptr[Key]<-left).value
            let right_value = read(ptr[Key]<-right).value
            if left_value < right_value:
                return -1
            if left_value > right_value:
                return 1
            return 0

function main() -> int:
    let left = Key(value = 2)
    let right = Key(value = 7)
    return tools.compare(left, right)

    MT

    imported_sources = {
      "demo/order_tools.mt" => <<~MT,
        # module demo.order_tools

        public function compare[T](left: T, right: T) -> int:
            return order[T](left, right)
      MT
    }

    generated = generate_c_from_program_source(source, imported_sources)

    assert_match(/static int32_t demo_order_tools_compare_demo_order_imported_codegen_main_Key\(demo_order_imported_codegen_main_Key left, demo_order_imported_codegen_main_Key right\)/, generated)
    assert_match(/demo_order_imported_codegen_main_Key_order_static\(&left, &right\)/, generated)
  end

  def test_generate_c_for_generic_functions_with_explicit_type_arguments_and_layout_queries
    source = <<~MT

# module demo.generic_layout

function bytes_for[T](count: ptr_uint) -> ptr_uint:
    return count * size_of(T)

function main() -> int:
    let total = bytes_for[int](4)
    return int<-total

    MT

    generated = generate_c_from_source(source)

    assert_match(/static uintptr_t demo_generic_layout_bytes_for_int\(uintptr_t count\)/, generated)
    assert_match(/return count \* sizeof\(int32_t\);/, generated)
    assert_match(/uintptr_t total = demo_generic_layout_bytes_for_int\(4\);/, generated)
  end

  def test_generate_c_for_generic_functions_with_literal_type_arguments
    source = <<~MT

# module demo.generic_builder

function capacity_of[N](buffer: str_buffer[N]) -> ptr_uint:
    return buffer.capacity()

function main() -> int:
    var buffer: str_buffer[32]
    return int<-(capacity_of(buffer) + capacity_of(buffer))

    MT

    generated = generate_c_from_source(source)

    assert_match(/static uintptr_t demo_generic_builder_capacity_of_32\(mt_str_buffer_32 buffer\)/, generated)
    assert_match(/return 32;/, generated)
    assert_match(/return \(int32_t\) \(demo_generic_builder_capacity_of_32\(buffer\) \+ demo_generic_builder_capacity_of_32\(buffer\)\);/, generated)
  end

  def test_generate_c_for_generic_functions_with_explicit_literal_type_arguments
    source = <<~MT

# module demo.generic_builder_explicit

function capacity_of[N](buffer: str_buffer[N]) -> ptr_uint:
    return buffer.capacity()

function main() -> int:
    var buffer: str_buffer[32]
    return int<-capacity_of[32](buffer)

    MT

    generated = generate_c_from_source(source)

    assert_match(/static uintptr_t demo_generic_builder_explicit_capacity_of_32\(mt_str_buffer_32 buffer\)/, generated)
    assert_match(/return 32;/, generated)
    assert_match(/return \(int32_t\) demo_generic_builder_explicit_capacity_of_32\(buffer\);/, generated)
  end

  def test_generate_c_for_generic_functions_with_explicit_named_const_type_arguments
    source = <<~MT

# module demo.generic_builder_named_const

const BASE: int = 28
const CAPACITY: int = BASE + 4

function capacity_of[N](buffer: str_buffer[N]) -> ptr_uint:
    return buffer.capacity()

function main() -> int:
    var buffer: str_buffer[CAPACITY]
    return int<-capacity_of[CAPACITY](buffer)

    MT

    generated = generate_c_from_source(source)

    assert_match(/static uintptr_t demo_generic_builder_named_const_capacity_of_32\(mt_str_buffer_32 buffer\)/, generated)
    assert_match(/return 32;/, generated)
    assert_match(/return \(int32_t\) demo_generic_builder_named_const_capacity_of_32\(buffer\);/, generated)
  end

  def test_generate_c_for_generic_functions_with_default_calls_and_interface_constraints
    source = <<~MT

# module demo.default_call_interface_codegen

interface Named:
    function value() -> int

struct Counter implements Named:
    count: int

extending Counter:
    static function default() -> Counter:
        return Counter(count = 7)

    function value() -> int:
        return this.count

function make_and_read[T implements Named]() -> int:
    let item = default[T]
    return item.value()

function main() -> int:
    return make_and_read[Counter]()

    MT

    generated = generate_c_from_source(source)

    assert_match(/static int32_t demo_default_call_interface_codegen_make_and_read_demo_default_call_interface_codegen_Counter\(void\)/, generated)
    assert_match(/demo_default_call_interface_codegen_Counter item = demo_default_call_interface_codegen_Counter_default_static\(\);/, generated)
    assert_match(/return demo_default_call_interface_codegen_Counter_value\(item\);/, generated)
  end

  def test_generate_c_for_generic_foreign_defs_with_str_buffer_public_capacity_mapping
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

        public foreign function text_box[N](text: str_buffer[N] as ptr[char]) -> void = c.TextBox(text, int<-(text_public.capacity() + 1))
      MT
    }

    generated = generate_c_from_program_source(root_source, imported_sources)

    assert_match(/TextBox\(mt_str_buffer_prepare_write\(&buffer\.data\[0\], 32, &buffer\.dirty\), \(int32_t\) (?:33|\(32 \+ 1\))\);/, generated)
  end

  def test_generate_c_for_explicit_literal_specialization_on_imported_generic_foreign_defs
    root_source = <<~MT
      # module demo.main

      import std.ui as ui

      function main() -> void:
          var buffer: str_buffer[32]
          ui.text_box[32](buffer)
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

        public foreign function text_box[N](text: str_buffer[N] as ptr[char]) -> void = c.TextBox(text, int<-(text_public.capacity() + 1))
      MT
    }

    generated = generate_c_from_program_source(root_source, imported_sources)

    assert_match(/TextBox\(mt_str_buffer_prepare_write\(&buffer\.data\[0\], 32, &buffer\.dirty\), \(int32_t\) (?:33|\(32 \+ 1\))\);/, generated)
  end

  def test_generate_c_for_explicit_literal_specialization_on_local_generic_foreign_defs
    root_source = <<~MT
      # module demo.main

      import std.c.ui as c

      public foreign function text_box[N](text: str_buffer[N] as ptr[char]) -> void = c.TextBox(text, int<-(text_public.capacity() + 1))

      function main() -> void:
          var buffer: str_buffer[32]
          text_box[32](buffer)
    MT

    imported_sources = {
      "std/c/ui.mt" => <<~MT,
        # module std.c.ui
        external
        include "ui.h"

        external function TextBox(text: ptr[char], text_size: int) -> void
      MT
    }

    generated = generate_c_from_program_source(root_source, imported_sources)

    assert_match(/TextBox\(mt_str_buffer_prepare_write\(&buffer\.data\[0\], 32, &buffer\.dirty\), \(int32_t\) (?:33|\(32 \+ 1\))\);/, generated)
  end

  def test_generate_c_for_generic_variant_instances
    source = <<~MT
      # module demo.generic_variant_codegen

      variant Box[T]:
          some(value: T)
          none

      function value_or_zero(value: Box[int]) -> int:
          match value:
              Box.some as payload:
                  return payload.value
              Box.none:
                  return 0

      function main() -> int:
          let value: Box[int] = Box[int].some(value= 7)
          return value_or_zero(value)
    MT

    generated = generate_c_from_source(source)

    assert_match(/typedef int32_t demo_generic_variant_codegen_Box_int_kind;/, generated)
    assert_match(/struct demo_generic_variant_codegen_Box_int_some \{/, generated)
    assert_match(/struct demo_generic_variant_codegen_Box_int \{/, generated)
    assert_match(/demo_generic_variant_codegen_Box_int_kind kind;/, generated)
    assert_match(/case demo_generic_variant_codegen_Box_int_kind_some:/, generated)
    assert_match(/case demo_generic_variant_codegen_Box_int_kind_none:/, generated)
    assert_match(/demo_generic_variant_codegen_Box_int_some payload = .*\.data\.some;/, generated)
  end

  def test_run_program_with_struct_field_of_generic_variant
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT
      # module demo.status_field_codegen



      struct Holder:
          result: Result[int, int]

      function main() -> int:
          let holder = Holder(result = Result[int, int].success(value= 7))
          match holder.result:
              Result.success as ignored_payload:
                  return 0
              Result.failure as ignored_error:
                  return 1
          return 2
    MT

    result = run_program_from_source(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
  end

  def test_run_program_for_event_runtime_helpers
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT
      # module demo.event_runtime_codegen

      event reloaded[4](int)

      var seen: int = 0

      function on_reload(value: int) -> void:
          seen += value

      async function main() -> int:
          match reloaded.subscribe(on_reload):
              Result.success as payload:
                  let sub = payload.value
                  let waited = reloaded.wait()
                  reloaded.emit(3)
                  reloaded.unsubscribe(sub)
                  reloaded.emit(4)
                  match await waited:
                      Result.success as waited_payload:
                          return seen + waited_payload.value
                      Result.failure as wait_error:
                          return 100
              Result.failure as subscribe_error:
                  return 101
          return 102
    MT

    result = run_program_from_source(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 6, result.exit_status
  end

  def test_run_program_for_event_wait_full_failure
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT
      # module demo.event_wait_full_runtime

      event reloaded[1](int)

      function on_reload(value: int) -> void:
          return

      async function main() -> int:
          match reloaded.subscribe(on_reload):
              Result.success as _:
                  match await reloaded.wait():
                      Result.success as _:
                          return 100
                      Result.failure as payload:
                          if payload.error != EventError.full:
                              return 101
                          return 0
              Result.failure as _:
                  return 102
          return 103
    MT

    result = run_program_from_source(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
  end

  # ── subscribe_once / stateful subscribe ────────────────────────────────────

  def test_generate_c_for_event_subscribe_once_stateless
    source = <<~MT
      # module demo.subscribe_once_codegen

      event ready[4]

      function on_ready() -> void:
          return

      function main() -> Result[Subscription, EventError]:
          return ready.subscribe_once(on_ready)
    MT

    generated = generate_c_from_program_source(source)

    assert_match(/mt_event_demo_subscribe_once_codegen_ready_4__subscribe_once/, generated)
  end

  def test_generate_c_for_event_subscribe_stateful
    source = <<~MT
      # module demo.subscribe_stateful_codegen

      struct Counter:
          value: int

      event ticked[4]

      function on_tick(state: ptr[Counter]) -> void:
          return

      function main(state: ptr[Counter]) -> Result[Subscription, EventError]:
          return ticked.subscribe(state, on_tick)
    MT

    generated = generate_c_from_program_source(source)

    assert_match(/mt_event_demo_subscribe_stateful_codegen_ticked_4__subscribe_stateful/, generated)
  end

  def test_generate_c_for_event_subscribe_once_stateful
    source = <<~MT
      # module demo.subscribe_once_stateful_codegen

      struct State:
          value: int

      event fired[4](int)

      function on_fire(state: ptr[State], payload: int) -> void:
          return

      function main(state: ptr[State]) -> Result[Subscription, EventError]:
          return fired.subscribe_once(state, on_fire)
    MT

    generated = generate_c_from_program_source(source)

    assert_match(/subscribe_once_stateful/, generated)
  end

  def test_run_program_with_event_subscribe_once
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT
      # module demo.subscribe_once_runtime

      event ready[4]

      function on_ready() -> void:
          return

      function main() -> int:
          let _ = ready.subscribe_once(on_ready) else:
              return 1
          ready.emit()
          return 10
    MT

    result = run_program_from_source(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 10, result.exit_status
  end

  def test_run_program_with_event_stateful_subscribe
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT
      # module demo.stateful_subscribe_runtime

      struct Counter:
          count: int

      event ticked[4]

      function on_tick(state: ptr[Counter]) -> void:
          unsafe:
              state.count += 1

      function main() -> int:
          var c = Counter(count = 0)
          ticked.subscribe(ptr_of(c), on_tick)
          ticked.emit()
          return c.count
    MT

    result = run_program_from_source(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 1, result.exit_status
  end

  # ── inline while / inline match codegen ────────────────────────────────────

  def test_generate_c_for_inline_match_only_emits_chosen_arm
    source = <<~MT
      # module demo.inline_match_codegen

      const CHOICE: int = 2

      function main() -> int:
          inline match CHOICE:
              1:
                  return 10
              2:
                  return 20
              _:
                  return 30
    MT

    generated = generate_c_from_program_source(source)

    assert_match(/return 20/, generated)
    refute_match(/return 10/, generated)
    refute_match(/return 30/, generated)
  end

  def test_run_program_with_inline_match
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT
      # module demo.inline_match_runtime

      const CHOICE: int = 2

      function main() -> int:
          inline match CHOICE:
              1:
                  return 10
              2:
                  return 20
              _:
                  return 30
    MT

    result = run_program_from_source(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 20, result.exit_status
  end

  # ── variant struct patterns runtime ────────────────────────────────────────

  def test_run_program_with_variant_struct_pattern_binding
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT
      # module demo.variant_binding_runtime

      variant Entity:
          player(hp: int, position: int)
          empty

      function main() -> int:
          var entity = Entity.player(hp = 5, position = 3)
          match entity:
              Entity.player(hp, position):
                  return hp + position
              Entity.empty:
                  return 0
    MT

    result = run_program_from_source(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 8, result.exit_status
  end

  def test_run_program_with_variant_struct_pattern_guard_fallthrough
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT
      # module demo.variant_guard_runtime

      variant Entity:
          player(hp: int)
          empty

      function main() -> int:
          var entity = Entity.player(hp = 8)
          match entity:
              Entity.player(hp):
                  return hp
              Entity.empty:
                  return 0
    MT

    result = run_program_from_source(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 8, result.exit_status
  end

  def test_run_program_with_variant_binding_and_wildcard
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT
      # module demo.variant_wildcard_runtime

      variant Entity:
          player(hp: int, position: int)
          enemy(id: int)
          empty

      function main() -> int:
          var entity = Entity.player(hp = 5, position = 3)
          match entity:
              Entity.player(hp, position):
                  return hp + position
              _:
                  return 0
    MT

    result = run_program_from_source(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 8, result.exit_status
  end

  def test_run_program_with_variant_guard_skip_when_condition_false
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT
      # module demo.variant_guard_skip_runtime

      variant Entity:
          player(hp: int)
          empty

      function main() -> int:
          var entity = Entity.player(hp = 3)
          match entity:
              Entity.player(hp > 5):
                  return 10
              Entity.player(hp):
                  return hp
              Entity.empty:
                  return 0
    MT

    result = run_program_from_source(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 3, result.exit_status
  end

  def test_run_program_with_variant_guard_match_when_condition_true
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT
      # module demo.variant_guard_match_runtime

      variant Entity:
          player(hp: int)
          empty

      function main() -> int:
          var entity = Entity.player(hp = 8)
          match entity:
              Entity.player(hp > 5):
                  return 10
              Entity.player(hp):
                  return hp
              Entity.empty:
                  return 0
    MT

    result = run_program_from_source(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 10, result.exit_status
  end

  def test_run_program_with_variant_equality_skip_when_not_equal
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT
      # module demo.variant_equality_skip_runtime

      enum Kind: ubyte
          boss = 1
          minion = 2

      variant Entity:
          monster(kind: Kind, hp: int)
          empty

      function main() -> int:
          var entity = Entity.monster(kind = Kind.minion, hp = 7)
          match entity:
              Entity.monster(kind = Kind.boss, hp):
                  return 10
              Entity.monster(kind = Kind.minion, hp):
                  return hp
              _:
                  return 0
    MT

    result = run_program_from_source(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 7, result.exit_status
  end

  # ── heredoc format string codegen ──────────────────────────────────────────

  def test_generate_c_for_format_heredoc_literal
    source = <<~'MT'
      # module demo.heredoc_fmt_codegen

      function main(count: int) -> ptr_uint:
          let text = f<<-FMT
          count=#{count}
          FMT
          return text.len
    MT

    generated = generate_c_from_program_source(source)

    assert_match(/count=/, generated)
    assert_match(/mt_format_str_make/, generated)
  end

  def test_run_program_with_format_heredoc_literal
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~'MT'
      # module demo.heredoc_fmt_runtime

      function main() -> int:
          let text = f<<-FMT
          hello
          FMT
          return int<-text.len
    MT

    result = run_program_from_source(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 6, result.exit_status
  end

  # ── flags composite alias codegen ──────────────────────────────────────────

  def test_generate_c_for_flags_composite_alias
    source = <<~'MT'
      # module demo.flags_composite_codegen

      flags Mask: uint
          a = 1 << 0
          b = 1 << 1
          both = Mask.a | Mask.b

      function main() -> Mask:
          return Mask.both
    MT

    generated = generate_c_from_program_source(source)

    assert_match(/Mask_both/, generated)
  end

  def test_run_program_with_flags_composite_alias
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~'MT'
      # module demo.flags_composite_runtime

      flags Mask: uint
          a = 1 << 0
          b = 1 << 1
          both = Mask.a | Mask.b

      function main() -> int:
          return int<-(Mask.both)
    MT

    result = run_program_from_source(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 3, result.exit_status
  end

  # ── array.as_span codegen ──────────────────────────────────────────────────

  def test_generate_c_for_array_as_span
    source = <<~'MT'
      # module demo.array_as_span_codegen

      function first(arr: array[int, 4]) -> int:
          let sp = arr.as_span()
          return sp[0]

      function main() -> int:
          var data = array[int, 4](10, 20, 30, 40)
          return first(data)
    MT

    generated = generate_c_from_program_source(source)

    assert_match(/as_span/, generated)
  end

  def test_run_program_with_array_as_span
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~'MT'
      # module demo.array_as_span_runtime

      function first(arr: array[int, 4]) -> int:
          let sp = arr.as_span()
          return sp[0]

      function main() -> int:
          var data = array[int, 4](10, 20, 30, 40)
          return first(data)
    MT

    result = run_program_from_source(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 10, result.exit_status
  end

  # ── event nested struct / generic struct / subscribe_once stateful runtime ──

  def test_generate_c_for_event_in_nested_struct
    source = <<~MT
      # module demo.nested_event_codegen

      struct Container:
          id: int

          struct Inner:
              value: int
              event updated[4](int)

          inner: Inner

      function on_update(value: int) -> void:
          return

      function main(container: ref[Container]) -> void:
          container.inner.updated.subscribe(on_update)
          container.inner.updated.emit(42)
    MT

    generated = generate_c_from_program_source(source)
    assert_match(/__event_updated/, generated)
    assert_match(/updated_int_4__subscribe/, generated)
    assert_match(/updated_int_4__emit/, generated)
  end

  def test_generate_c_for_event_in_generic_struct
    source = <<~MT
      # module demo.generic_event_codegen

      struct Box[T]:
          event changed[4](T)
          value: T

      function on_change_int(value: int) -> void:
          return

      function main(box: ref[Box[int]]) -> void:
          box.changed.subscribe(on_change_int)
          box.changed.emit(1)
    MT

    generated = generate_c_from_program_source(source)
    assert_match(/event.*changed.*4.*int/, generated)
    assert_match(/__event_changed/, generated)
  end

  def test_run_program_with_event_stateful_subscribe_once
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT
      # module demo.stateful_once_runtime

      struct Counter:
          count: int

      event ticked[4]

      function on_tick(state: ptr[Counter]) -> void:
          unsafe:
              state.count += 1

      function main() -> int:
          var c = Counter(count = 0)
          let _ = ticked.subscribe_once(ptr_of(c), on_tick) else:
              return 1
          ticked.emit()
          ticked.emit()
          return c.count
    MT

    result = run_program_from_source(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 1, result.exit_status
  end

  def test_run_program_with_event_multiple_subscribers
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT
      # module demo.multi_sub_runtime

      event signal[4]

      var a: int = 0
      var b: int = 0
      var c: int = 0

      function on_a() -> void:
          a += 1

      function on_b() -> void:
          b += 2

      function on_c() -> void:
          c += 3

      function main() -> int:
          let _ = signal.subscribe(on_a) else:
              return 1
          let _ = signal.subscribe(on_b) else:
              return 1
          let _ = signal.subscribe(on_c) else:
              return 1
          signal.emit()
          return a + b + c
    MT

    result = run_program_from_source(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 6, result.exit_status
  end

  # ── proc in module variable runtime ──

  def test_run_program_with_module_variable_capture_free_proc
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT
      # module demo.modvar_proc_runtime

      var callback: proc() -> int = proc() -> int: 42

      function main() -> int:
          return callback()
    MT

    result = run_program_from_source(source, compiler:)
    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 42, result.exit_status
  end

  def test_run_program_with_module_variable_proc_calling_function
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT
      # module demo.modvar_proc_fn_runtime

      function square(x: int) -> int:
          return x * x

      var callback: proc(x: int) -> int = proc(x: int) -> int: square(x)

      function main() -> int:
          return callback(7)
    MT

    result = run_program_from_source(source, compiler:)
    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 49, result.exit_status
  end

end
