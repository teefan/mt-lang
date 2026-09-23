# frozen_string_literal: true

require_relative "helpers"

class DebugGuardsTest < Minitest::Test
  include CodegenTestHelpers

  def test_debug_guards_emit_null_trap_before_pointer_member_deref
    source = <<~MT
      # module demo.debug_guards_member

      struct Item:
          value: int

      function read_value(p: ptr[Item]) -> int:
          unsafe:
              return p.value
    MT

    debug_c = generate_c_from_source(source, debug_guards: true)
    assert_match(/if \(p == NULL\) mt_fatal\("null pointer dereferenced in /, debug_c)

    release_c = generate_c_from_source(source)
    refute_match(/null pointer dereferenced/, release_c)
  end

  def test_debug_guards_emit_null_trap_before_pointer_index_deref
    source = <<~MT
      # module demo.debug_guards_index

      function read_at(p: ptr[int], i: int) -> int:
          unsafe:
              return p[i]
    MT

    debug_c = generate_c_from_source(source, debug_guards: true)
    assert_match(/if \(p == NULL\) mt_fatal\("null pointer dereferenced in /, debug_c)
  end

  def test_debug_guards_emit_null_trap_before_read_deref
    source = <<~MT
      # module demo.debug_guards_read

      function load(p: ptr[int]) -> int:
          unsafe:
              return read(p)
    MT

    debug_c = generate_c_from_source(source, debug_guards: true)
    assert_match(/if \(p == NULL\) mt_fatal\("null pointer dereferenced in /, debug_c)
  end

  def test_debug_guards_skip_ref_receivers
    source = <<~MT
      # module demo.debug_guards_ref

      struct Item:
          value: int

      function bump(target: ref[Item]) -> void:
          target.value = 1
    MT

    debug_c = generate_c_from_source(source, debug_guards: true)
    refute_match(/null pointer dereferenced/, debug_c)
  end

  def test_debug_guards_skip_conditional_deref_branches
    source = <<~MT
      # module demo.debug_guards_conditional

      function pick(ready: bool, p: ptr[int]) -> int:
          unsafe:
              if ready and read(p) > 0:
                  return 1
          return 0
    MT

    debug_c = generate_c_from_source(source, debug_guards: true)
    refute_match(/null pointer dereferenced/, debug_c)
  end

  def test_debug_guards_guard_chained_pointer_derefs_once_per_receiver
    source = <<~MT
      # module demo.debug_guards_chain

      struct Node:
          next: ptr[Node]
          value: int

      function total(head: ptr[Node]) -> int:
          unsafe:
              return head.next.value
    MT

    debug_c = generate_c_from_source(source, debug_guards: true)
    assert_match(/if \(head == NULL\) mt_fatal\(/, debug_c)
    assert_match(/if \(head->next == NULL\) mt_fatal\(/, debug_c)
  end

  def test_debug_guards_skip_side_effecting_call_receivers
    # A pointer-returning call is duplicated by a trap that guards it, so the
    # call would run twice.  Side-effecting receivers must not be guarded.
    source = <<~MT
      # module demo.debug_guards_call_receiver

      struct Item:
          value: int

      var calls: int = 0
      var global_item: Item

      function get_item() -> ptr[Item]:
          calls += 1
          return ptr_of(global_item)

      function read_value() -> int:
          unsafe:
              return read(get_item()).value
    MT

    debug_c = generate_c_from_source(source, debug_guards: true)
    refute_match(/if \(demo_debug_guards_call_receiver_get_item\(\) == NULL\)/, debug_c)
    assert_equal 1, debug_c.scan(/demo_debug_guards_call_receiver_get_item\(\)/).size,
                 "pointer-returning call must be invoked exactly once"
  end
end
