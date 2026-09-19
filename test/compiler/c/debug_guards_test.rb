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
end
