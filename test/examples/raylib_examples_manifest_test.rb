# frozen_string_literal: true

require "fileutils"
require_relative "../test_helper"

class MilkTeaRaylibExamplesManifestTest < Minitest::Test
  def test_generate_parses_examples_list_and_scans_source_features
    Dir.mktmpdir("milk-tea-raylib-manifest") do |dir|
      examples_root = write_examples_fixture(dir)

      manifest = MilkTea::RaylibExamplesManifest.generate(examples_root)

      assert_equal File.join(examples_root, "examples_list.txt"), manifest.fetch("examples_list_path")
      assert_nil manifest.fetch("repo_root")
      assert_equal 3, manifest.fetch("total_examples")
      assert_equal({ "core" => 2, "shaders" => 1 }, manifest.fetch("category_counts"))
      assert_equal 0, manifest.fetch("progress").fetch("raw_ported_examples")
      assert_equal 0, manifest.fetch("progress").fetch("idiomatic_ported_examples")

      rlgl_example = manifest.fetch("examples").find { |example| example.fetch("example_id") == "core/core_2d_camera_mouse_zoom" }
      refute_nil rlgl_example
      assert_equal ["rlgl.h"], rlgl_example.fetch("helper_headers")
      assert_equal true, rlgl_example.fetch("uses_rlgl")
      assert_equal false, rlgl_example.fetch("raw_port_present")
      assert_equal false, rlgl_example.fetch("idiomatic_port_present")
      assert_equal "not_started", rlgl_example.fetch("port_status")
      refute_includes rlgl_example.fetch("known_blockers"), "rlgl_helper_header"

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

  def test_generate_reports_repo_progress_and_wave1_gates
    Dir.mktmpdir("milk-tea-raylib-manifest-progress") do |dir|
      repo_root = write_repo_examples_fixture(dir)
      examples_root = File.join(repo_root, "third_party", "raylib-upstream", "examples")

      manifest = MilkTea::RaylibExamplesManifest.generate(examples_root)

      assert_equal repo_root, manifest.fetch("repo_root")
      assert_equal 3, manifest.fetch("progress").fetch("raw_ported_examples")
      assert_equal 2, manifest.fetch("progress").fetch("idiomatic_ported_examples")
      assert_equal 100.0, manifest.fetch("progress").fetch("raw_completion_percent")
      assert_equal 66.7, manifest.fetch("progress").fetch("idiomatic_completion_percent")
      assert_equal true, manifest.fetch("progress").fetch("gates").fetch("wave1_raw_core_complete")
      assert_equal true, manifest.fetch("progress").fetch("gates").fetch("wave1_raw_shapes_complete")
      assert_equal true, manifest.fetch("progress").fetch("gates").fetch("wave1_ready_for_textures")
      assert_equal true, manifest.fetch("progress").fetch("gates").fetch("raw_corpus_complete")

      core_progress = manifest.fetch("progress").fetch("by_category").fetch("core")
      assert_equal 2, core_progress.fetch("total_examples")
      assert_equal 2, core_progress.fetch("raw_ported_examples")
      assert_equal 2, core_progress.fetch("idiomatic_ported_examples")
      assert_equal 100.0, core_progress.fetch("raw_completion_percent")
      assert_equal 100.0, core_progress.fetch("idiomatic_completion_percent")

      camera_example = manifest.fetch("examples").find { |example| example.fetch("example_id") == "core/core_3d_camera_free" }
      refute_nil camera_example
      assert_equal true, camera_example.fetch("raw_port_present")
      assert_equal "examples/raylib/core/core_3d_camera_free.mt", camera_example.fetch("raw_port_path")
      assert_equal true, camera_example.fetch("idiomatic_port_present")
      assert_equal "examples/idiomatic/raylib/camera_free.mt", camera_example.fetch("idiomatic_port_path")
      assert_equal "raw_and_idiomatic", camera_example.fetch("port_status")

      shapes_example = manifest.fetch("examples").find { |example| example.fetch("example_id") == "shapes/shapes_basic_shapes" }
      refute_nil shapes_example
      assert_equal true, shapes_example.fetch("raw_port_present")
      assert_equal false, shapes_example.fetch("idiomatic_port_present")
      assert_equal "raw_port", shapes_example.fetch("port_status")
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
      core;core_2d_camera_mouse_zoom;★★☆☆;1.0;5.5;2016;2025;"Ramon Santamaria";@raysan5
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

    File.write(File.join(examples_root, "core", "core_2d_camera_mouse_zoom.c"), <<~C)
      #include "raylib.h"
      #include "rlgl.h"

      int main(void)
      {
          rlPushMatrix();
          rlPopMatrix();
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

  def write_repo_examples_fixture(dir)
    repo_root = File.join(dir, "repo")
    examples_root = File.join(repo_root, "third_party", "raylib-upstream", "examples")

    FileUtils.mkdir_p(File.join(examples_root, "core"))
    FileUtils.mkdir_p(File.join(examples_root, "shapes"))
    FileUtils.mkdir_p(File.join(repo_root, "examples", "raylib", "core"))
    FileUtils.mkdir_p(File.join(repo_root, "examples", "raylib", "shapes"))
    FileUtils.mkdir_p(File.join(repo_root, "examples", "idiomatic", "raylib"))

    File.write(File.join(examples_root, "examples_list.txt"), <<~TXT)
      core;core_basic_window;★☆☆☆;1.0;1.0;2013;2025;"Ramon Santamaria";@raysan5
      core;core_3d_camera_free;★★☆☆;1.3;5.5;2015;2025;"Ramon Santamaria";@raysan5
      shapes;shapes_basic_shapes;★☆☆☆;1.0;1.0;2014;2025;"Ramon Santamaria";@raysan5
    TXT

    File.write(File.join(examples_root, "core", "core_basic_window.c"), <<~C)
      #include "raylib.h"

      int main(void)
      {
          InitWindow(800, 450, "raylib [core] example - basic window");
          return 0;
      }
    C

    File.write(File.join(examples_root, "core", "core_3d_camera_free.c"), <<~C)
      #include "raylib.h"

      int main(void)
      {
          Camera camera = { 0 };
          UpdateCamera(&camera, CAMERA_FREE);
          return 0;
      }
    C

    File.write(File.join(examples_root, "shapes", "shapes_basic_shapes.c"), <<~C)
      #include "raylib.h"

      int main(void)
      {
          DrawCircle(100, 100, 24.0f, RED);
          return 0;
      }
    C

    File.write(File.join(repo_root, "examples", "raylib", "core", "core_basic_window.mt"), "module examples.raylib.core.core_basic_window\n")
    File.write(File.join(repo_root, "examples", "raylib", "core", "core_3d_camera_free.mt"), "module examples.raylib.core.core_3d_camera_free\n")
    File.write(File.join(repo_root, "examples", "raylib", "shapes", "shapes_basic_shapes.mt"), "module examples.raylib.shapes.shapes_basic_shapes\n")
    File.write(File.join(repo_root, "examples", "idiomatic", "raylib", "basic_window.mt"), "module examples.idiomatic.raylib.basic_window\n")
    File.write(File.join(repo_root, "examples", "idiomatic", "raylib", "camera_free.mt"), "module examples.idiomatic.raylib.camera_free\n")

    repo_root
  end
end
