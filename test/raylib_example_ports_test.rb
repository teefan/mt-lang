# frozen_string_literal: true

require_relative "test_helper"

class MilkTeaRaylibExamplePortsTest < Minitest::Test
  def test_core_example_ports_check_and_lower
    core_example_paths.each do |path|
      program = MilkTea::ModuleLoader.check_program(path)

      assert_equal true, program.analyses_by_module_name.key?(module_name_for(path))
    end
  end

  def test_shapes_example_ports_check_and_lower
    shapes_example_paths.each do |path|
      program = MilkTea::ModuleLoader.check_program(path)

      assert_equal true, program.analyses_by_module_name.key?(module_name_for(path))
    end
  end

  private

  def core_example_paths
    %w[
      core_2d_camera
      core_2d_camera_mouse_zoom
      core_2d_camera_platformer
      core_automation_events
      core_3d_camera_free
      core_3d_camera_first_person
      core_3d_camera_fps
      core_3d_camera_split_screen
      core_3d_picking
      core_compute_hash
      core_custom_logging
      core_custom_frame_control
      core_directory_files
      core_basic_window
      core_basic_screen_manager
      core_3d_camera_mode
      core_clipboard_text
      core_2d_camera_split_screen
      core_delta_time
      core_drop_files
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
      core_screen_recording
      core_smooth_pixelperfect
      core_storage_values
      core_text_file_loading
      core_undo_redo
      core_viewport_scaling
      core_vr_simulator
      core_window_web
      core_window_flags
      core_world_screen
      core_window_should_close
      core_scissor_test
    ].map do |name|
      File.expand_path("../examples/raylib/core/#{name}.mt", __dir__)
    end
  end

  def shapes_example_paths
    Dir[File.expand_path("../examples/raylib/shapes/*.mt", __dir__)].sort
  end

  def module_name_for(path)
    relative_path = path.delete_prefix(File.expand_path("../examples/", __dir__) + "/")
    "examples.#{relative_path.delete_suffix(".mt").tr("/", ".")}"
  end

end
