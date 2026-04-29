# frozen_string_literal: true

require "tmpdir"
require_relative "test_helper"

class MilkTeaExamplesBuildTest < Minitest::Test
  def test_all_examples_build_with_host_compiler
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    manifest = example_manifest

    Dir.mktmpdir("milk-tea-examples-build") do |dir|
      manifest.each_with_index do |entry, index|
        path = entry.fetch(:path)
        relative_path = entry.fetch(:relative_path)
        output_basename = relative_path.delete_suffix(".mt").tr("/", "__")
        output_path = File.join(dir, output_basename)
        c_path = File.join(dir, "#{output_basename}.c")

        announce_build_progress(index + 1, manifest.length, relative_path)
        result = MilkTea::Build.build(path, output_path:, cc: compiler, keep_c_path: c_path)

        assert_equal File.expand_path(output_path), result.output_path, relative_path
        assert_equal File.expand_path(c_path), result.c_path, relative_path
        assert_equal File.expand_path(compiler), result.compiler, relative_path if compiler.include?(File::SEPARATOR)
        assert_includes result.link_flags, "-lraylib", relative_path
        assert File.exist?(output_path), "#{relative_path} did not produce an output binary"
        assert File.exist?(c_path), "#{relative_path} did not produce a C file"

        generated_c = File.read(c_path)
        assert_match(/#include "raylib\.h"/, generated_c, relative_path)

        next unless entry.fetch(:uses_raygui)

        assert_includes result.link_flags, "-lm", relative_path
        assert_match(/#include "raygui\.h"/, generated_c, relative_path)
      end
    end
  end

  def test_raylib_example_resources_are_vendored
    manifest = raylib_resource_manifest
    refute_empty manifest

    missing = manifest.reject { |entry| File.exist?(entry.fetch(:resource_path)) }

    assert_empty missing, missing.map { |entry| "#{entry.fetch(:example_relative_path)}: missing #{entry.fetch(:resource_relative_path)}" }.join("\n")
  end

  private

  def raylib_resource_manifest
    examples_root = File.expand_path("../examples", __dir__)
    raylib_examples_root = File.join(examples_root, "raylib")
    idiomatic_examples_root = File.join(examples_root, "idiomatic", "raylib")
    resources_root = File.join(raylib_examples_root, "resources")

    raw_manifest = Dir[File.join(raylib_examples_root, "**", "*.mt")].sort.flat_map do |path|
      source = File.read(path)
      example_relative_path = path.delete_prefix(examples_root + "/")

      source.scan(%r{\.\./resources/([^"\s]+)}).flatten.uniq.flat_map do |resource_relative_path|
        expand_raylib_resource_path(resource_relative_path).map do |expanded_path|
          {
            example_relative_path:,
            resource_relative_path: expanded_path,
            resource_path: File.join(resources_root, expanded_path),
          }
        end
      end
    end

    idiomatic_manifest = Dir[File.join(idiomatic_examples_root, "*.mt")].sort.flat_map do |path|
      source = File.read(path)
      example_relative_path = path.delete_prefix(examples_root + "/")

      source.scan(%r{\.\./\.\./raylib/resources/([^"\s]+)}).flatten.uniq.flat_map do |resource_relative_path|
        expand_raylib_resource_path(resource_relative_path).map do |expanded_path|
          {
            example_relative_path:,
            resource_relative_path: expanded_path,
            resource_path: File.join(resources_root, expanded_path),
          }
        end
      end
    end

    raw_manifest + idiomatic_manifest
  end

  def expand_raylib_resource_path(resource_relative_path)
    return MilkTea::RaylibExamplesManifest::GLSL_VERSIONS.map do |version|
      resource_relative_path.gsub("glsl%i", "glsl#{version}")
    end if resource_relative_path.include?("glsl%i")

    [resource_relative_path]
  end

  def announce_build_progress(current, total, relative_path)
    $stdout.puts("[examples_build_test #{current}/#{total}] #{relative_path}")
    $stdout.flush
  end

  def example_manifest
    examples_root = File.expand_path("../examples", __dir__)

    Dir[File.join(examples_root, "**", "*.mt")].sort.map do |path|
      source = File.read(path)

      {
        path: path,
        relative_path: path.delete_prefix(examples_root + "/"),
        uses_raygui: source.match?(/^import std\.(?:c\.)?raygui as /),
      }
    end
  end

  def compiler_available?(compiler)
    return File.executable?(compiler) if compiler.include?(File::SEPARATOR)

    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |entry|
      candidate = File.join(entry, compiler)
      File.file?(candidate) && File.executable?(candidate)
    end
  end
end
