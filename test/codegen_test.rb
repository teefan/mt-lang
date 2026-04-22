# frozen_string_literal: true

require "tempfile"
require_relative "test_helper"

class MilkTeaCodegenTest < Minitest::Test
  def test_generate_c_for_demo_emits_structs_functions_and_imported_headers
    program = MilkTea::ModuleLoader.check_program(demo_path)
    generated = MilkTea::Codegen.generate_c(program)

    assert_match(/#include <stdbool\.h>/, generated)
    assert_match(/#include <stdint\.h>/, generated)
    assert_match(/#include "raylib\.h"/, generated)
    assert_match(/typedef struct demo_bouncing_ball_Ball/, generated)
    assert_match(/static void demo_bouncing_ball_Ball_update\(demo_bouncing_ball_Ball\* self, float dt\)/, generated)
    assert_match(/demo_bouncing_ball_Ball_update\(&ball, dt\);/, generated)
    assert_match(/int32_t main\(void\)/, generated)
    assert_equal 1, generated.scan("CloseWindow();").length
  end

    def test_generate_c_for_local_enums_flags_and_unions
      source = [
        "module demo.codegen_surface",
        "",
        "enum State: i32",
        "    idle = 0",
        "    running = 1",
        "",
        "flags WindowFlags: u32",
        "    visible = 1 << 0",
        "    resizable = 1 << 1",
        "",
        "union Payload:",
        "    count: i32",
        "    enabled: bool",
        "",
        "const DEFAULT_STATE: State = State.idle",
        "const DEFAULT_FLAGS: WindowFlags = WindowFlags.visible | WindowFlags.resizable",
        "",
        "def pick_state(active: bool) -> State:",
        "    if active:",
        "        return State.running",
        "    return DEFAULT_STATE",
        "",
        "def main() -> i32:",
        "    let current = pick_state(true)",
        "    if current == State.running:",
        "        return 1",
        "    return 0",
        "",
      ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/typedef int32_t demo_codegen_surface_State;/, generated)
    assert_match(/demo_codegen_surface_State_idle = 0/, generated)
    assert_match(/demo_codegen_surface_State_running = 1/, generated)
    assert_match(/typedef uint32_t demo_codegen_surface_WindowFlags;/, generated)
    assert_match(/demo_codegen_surface_WindowFlags_visible = 1 << 0/, generated)
    assert_match(/demo_codegen_surface_WindowFlags_resizable = 1 << 1/, generated)
    assert_match(/typedef union demo_codegen_surface_Payload/, generated)
    assert_match(/static const demo_codegen_surface_State demo_codegen_surface_DEFAULT_STATE = demo_codegen_surface_State_idle;/, generated)
    assert_match(/static const demo_codegen_surface_WindowFlags demo_codegen_surface_DEFAULT_FLAGS = demo_codegen_surface_WindowFlags_visible \| demo_codegen_surface_WindowFlags_resizable;/, generated)
    assert_match(/if \(current == demo_codegen_surface_State_running\)/, generated)
    assert_match(/return 1;/, generated)
    end

  private

  def demo_path
    File.expand_path("../examples/milk-tea-demo.mt", __dir__)
  end

  def generate_c_from_source(source)
    Tempfile.create(["milk-tea-codegen", ".mt"]) do |file|
      file.write(source)
      file.flush

      program = MilkTea::ModuleLoader.check_program(file.path)
      MilkTea::Codegen.generate_c(program)
    end
  end
end
