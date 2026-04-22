# frozen_string_literal: true

require "fileutils"
require_relative "test_helper"

class MilkTeaRaylibExamplesManifestTest < Minitest::Test
  def test_generate_parses_examples_list_and_scans_source_features
    Dir.mktmpdir("milk-tea-raylib-manifest") do |dir|
      examples_root = write_examples_fixture(dir)

      manifest = MilkTea::RaylibExamplesManifest.generate(examples_root)

      assert_equal File.join(examples_root, "examples_list.txt"), manifest.fetch("examples_list_path")
      assert_equal 2, manifest.fetch("total_examples")
      assert_equal({ "core" => 1, "shaders" => 1 }, manifest.fetch("category_counts"))

      shader_example = manifest.fetch("examples").find { |example| example.fetch("example_id") == "shaders/shaders_texture_waves" }
      refute_nil shader_example
      assert_equal ["raymath.h", "rlights.h"], shader_example.fetch("helper_headers")
      assert_equal true, shader_example.fetch("uses_raymath")
      assert_equal false, shader_example.fetch("uses_rlgl")
      assert_equal false, shader_example.fetch("uses_raygui")
      assert_equal true, shader_example.fetch("uses_rlights")
      assert_equal true, shader_example.fetch("uses_shader_files")
      assert_equal false, shader_example.fetch("uses_model_files")
      assert_equal false, shader_example.fetch("uses_audio_files")
      assert_equal true, shader_example.fetch("uses_callbacks")
      assert_includes shader_example.fetch("resource_paths"), "resources/space.png"
      assert_includes shader_example.fetch("resource_paths"), "resources/shaders/glsl100/wave.fs"
      assert_includes shader_example.fetch("resource_paths"), "resources/shaders/glsl120/wave.fs"
      assert_includes shader_example.fetch("resource_paths"), "resources/shaders/glsl330/wave.fs"
      assert_includes shader_example.fetch("known_blockers"), "raymath_helper_header"
      assert_includes shader_example.fetch("known_blockers"), "rlights_helper_header"
      assert_includes shader_example.fetch("known_blockers"), "shader_assets"
      assert_includes shader_example.fetch("known_blockers"), "callback_ffi"
    end
  end

  def test_generate_requires_example_sources_for_list_entries
    Dir.mktmpdir("milk-tea-raylib-manifest-missing") do |dir|
      examples_root = File.join(dir, "examples")
      FileUtils.mkdir_p(examples_root)
      File.write(File.join(examples_root, "examples_list.txt"), <<~TXT)
        core;core_basic_window;★☆☆☆;1.0;1.0;2013;2025;"Ramon Santamaria";@raysan5
      TXT

      error = assert_raises(MilkTea::RaylibExamplesError) do
        MilkTea::RaylibExamplesManifest.generate(examples_root)
      end

      assert_match(/example source not found/, error.message)
    end
  end

  private

  def write_examples_fixture(dir)
    examples_root = File.join(dir, "examples")
    FileUtils.mkdir_p(File.join(examples_root, "core"))
    FileUtils.mkdir_p(File.join(examples_root, "shaders"))

    File.write(File.join(examples_root, "examples_list.txt"), <<~TXT)
      # curated examples fixture
      core;core_basic_window;★☆☆☆;1.0;1.0;2013;2025;"Ramon Santamaria";@raysan5
      shaders;shaders_texture_waves;★★☆☆;2.5;3.7;2019;2025;"Anata";@anatagawa
    TXT

    File.write(File.join(examples_root, "core", "core_basic_window.c"), <<~C)
      #include "raylib.h"

      int main(void)
      {
          InitWindow(800, 450, "raylib [core] example - basic window");
          return 0;
      }
    C

    File.write(File.join(examples_root, "shaders", "shaders_texture_waves.c"), <<~C)
      #include "raylib.h"
      #include "raymath.h"
      #include "rlights.h"

      int main(void)
      {
          Texture2D texture = LoadTexture("resources/space.png");
          Shader shader = LoadShader(0, TextFormat("resources/shaders/glsl%i/wave.fs", GLSL_VERSION));
          SetAudioStreamCallback(stream, callback);
          return 0;
      }
    C

    examples_root
  end
end
