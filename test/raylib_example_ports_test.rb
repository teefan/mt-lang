# frozen_string_literal: true

require "tmpdir"
require_relative "test_helper"

class MilkTeaRaylibExamplePortsTest < Minitest::Test
  def test_core_example_ports_check_and_lower
    core_example_paths.each do |path|
      program = MilkTea::ModuleLoader.check_program(path)

      assert_equal true, program.analyses_by_module_name.key?(module_name_for(path))
    end
  end

  def test_core_example_ports_build_with_fake_compiler
    Dir.mktmpdir("milk-tea-raylib-example-ports") do |dir|
      compiler_log = File.join(dir, "compiler.log")
      compiler_path = write_fake_compiler(dir, compiler_log)

      core_example_paths.each do |path|
        output_basename = File.basename(path, ".mt")
        output_path = File.join(dir, output_basename)
        c_path = File.join(dir, "#{output_basename}.c")

        result = MilkTea::Build.build(path, output_path:, cc: compiler_path, keep_c_path: c_path)

        assert_equal File.expand_path(output_path), result.output_path
        assert_equal File.expand_path(c_path), result.c_path
        assert_equal File.expand_path(compiler_path), result.compiler
        assert_includes result.link_flags, "-lraylib"
        if %w[core_clipboard_text core_smooth_pixelperfect core_input_gestures_testbed].include?(File.basename(path, ".mt"))
          assert_includes result.link_flags, "-lm"
        end
        assert File.exist?(output_path)
        assert File.exist?(c_path)
        assert_match(/#include "raylib\.h"/, File.read(c_path))
      end

      invocation = File.read(compiler_log).lines(chomp: true)
      assert_includes invocation, "-std=c11"
      assert_includes invocation, "-lraylib"
    end
  end

  private

  def core_example_paths
    %w[
      core_2d_camera
      core_2d_camera_platformer
      core_3d_camera_free
      core_3d_camera_first_person
      core_3d_camera_fps
      core_3d_camera_split_screen
      core_3d_picking
      core_custom_frame_control
      core_basic_window
      core_basic_screen_manager
      core_3d_camera_mode
      core_clipboard_text
      core_2d_camera_split_screen
      core_delta_time
      core_highdpi_demo
      core_highdpi_testbed
      core_window_letterbox
      core_input_actions
      core_input_gamepad
      core_input_gestures
      core_input_gestures_testbed
      core_input_keys
      core_keyboard_testbed
      core_input_mouse
      core_input_multitouch
      core_input_mouse_wheel
      core_input_virtual_controls
      core_monitor_detector
      core_random_sequence
      core_random_values
      core_render_texture
      core_smooth_pixelperfect
      core_storage_values
      core_undo_redo
      core_viewport_scaling
      core_window_web
      core_window_flags
      core_world_screen
      core_window_should_close
      core_scissor_test
    ].map do |name|
      File.expand_path("../examples/raylib/core/#{name}.mt", __dir__)
    end
  end

  def module_name_for(path)
    "examples.raylib.core.#{File.basename(path, ".mt")}"
  end

  def write_fake_compiler(dir, log_path)
    path = File.join(dir, "fake-cc")
    File.write(path, <<~SH)
      #!/bin/sh
      printf '%s\n' "$@" > #{log_path.inspect}
      output=''
      previous=''
      for argument in "$@"; do
        if [ "$previous" = '-o' ]; then
          output="$argument"
        fi
        previous="$argument"
      done
      : > "$output"
    SH
    File.chmod(0o755, path)
    path
  end
end
