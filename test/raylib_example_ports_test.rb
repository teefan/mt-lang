# frozen_string_literal: true

require_relative "test_helper"

class MilkTeaRaylibExamplePortsTest < Minitest::Test
  def test_core_example_ports_check_and_lower
    core_example_paths.each_with_index do |path, index|
      announce_port_progress("core", index + 1, core_example_paths.length, path)
      program = MilkTea::ModuleLoader.check_program(path)

      assert_equal true, program.analyses_by_module_name.key?(module_name_for(path))
    end
  end

  def test_shapes_example_ports_check_and_lower
    shapes_example_paths.each_with_index do |path, index|
      announce_port_progress("shapes", index + 1, shapes_example_paths.length, path)
      program = MilkTea::ModuleLoader.check_program(path)

      assert_equal true, program.analyses_by_module_name.key?(module_name_for(path))
    end
  end

  def test_textures_example_ports_check_and_lower
    textures_example_paths.each_with_index do |path, index|
      announce_port_progress("textures", index + 1, textures_example_paths.length, path)
      program = MilkTea::ModuleLoader.check_program(path)

      assert_equal true, program.analyses_by_module_name.key?(module_name_for(path))
    end
  end

  def test_text_example_ports_check_and_lower
    text_example_paths.each_with_index do |path, index|
      announce_port_progress("text", index + 1, text_example_paths.length, path)
      program = MilkTea::ModuleLoader.check_program(path)

      assert_equal true, program.analyses_by_module_name.key?(module_name_for(path))
    end
  end

  def test_models_example_ports_check_and_lower
    models_example_paths.each_with_index do |path, index|
      announce_port_progress("models", index + 1, models_example_paths.length, path)
      program = MilkTea::ModuleLoader.check_program(path)

      assert_equal true, program.analyses_by_module_name.key?(module_name_for(path))
    end
  end

  private

  def announce_port_progress(category, current, total, path)
    relative_path = path.delete_prefix(File.expand_path("../examples/", __dir__))
    $stdout.puts("[raylib_example_ports_test #{category} #{current}/#{total}] #{relative_path}")
    $stdout.flush
  end

  def core_example_paths
    Dir[File.expand_path("../examples/raylib/core/*.mt", __dir__)].sort
  end

  def shapes_example_paths
    Dir[File.expand_path("../examples/raylib/shapes/*.mt", __dir__)].sort
  end

  def textures_example_paths
    Dir[File.expand_path("../examples/raylib/textures/*.mt", __dir__)].sort
  end

  def text_example_paths
    Dir[File.expand_path("../examples/raylib/text/*.mt", __dir__)].sort
  end

  def models_example_paths
    Dir[File.expand_path("../examples/raylib/models/*.mt", __dir__)].sort
  end

  def module_name_for(path)
    relative_path = path.delete_prefix(File.expand_path("../examples/", __dir__) + "/")
    "examples.#{relative_path.delete_suffix(".mt").tr("/", ".")}"
  end

end
