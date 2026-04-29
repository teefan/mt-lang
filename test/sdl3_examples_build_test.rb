# frozen_string_literal: true

require "tmpdir"
require_relative "test_helper"

class MilkTeaSdl3ExamplesBuildTest < Minitest::Test
  def test_sdl3_example_resources_are_vendored
    manifest = resource_manifest
    refute_empty manifest

    missing = manifest.reject { |entry| File.exist?(entry.fetch(:resource_path)) }

    assert_empty missing, <<~MSG
      Missing SDL3 example resources:
      #{missing.map { |entry| "#{entry.fetch(:relative_path)} -> #{entry.fetch(:resource_relative_path)}" }.join("\n")}
    MSG
  end

  def test_sdl3_examples_build_with_host_compiler
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    manifest = example_manifest
    refute_empty manifest

    Dir.mktmpdir("milk-tea-sdl3-examples-build") do |dir|
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
        assert_includes result.link_flags, "-lSDL3", relative_path
        assert File.exist?(output_path), "#{relative_path} did not produce an output binary"
        assert File.exist?(c_path), "#{relative_path} did not produce a C file"

        generated_c = File.read(c_path)
        assert_match(/#include "SDL3\/SDL\.h"/, generated_c, relative_path)
        assert_match(/#include "SDL3\/SDL_main\.h"/, generated_c, relative_path)
        assert_match(/SDL_RunApp\(/, generated_c, relative_path)
      end
    end
  end

  private

  def announce_build_progress(current, total, relative_path)
    $stdout.puts("[sdl3_examples_build_test #{current}/#{total}] #{relative_path}")
    $stdout.flush
  end

  def example_manifest
    examples_root = File.expand_path("../examples", __dir__)
    raw_examples_root = File.join(examples_root, "sdl3")
    idiomatic_examples_root = File.join(examples_root, "idiomatic", "sdl3")

    Dir[
      File.join(raw_examples_root, "**", "*.mt"),
      File.join(idiomatic_examples_root, "*.mt"),
    ].sort.map do |path|
      {
        path: path,
        relative_path: path.delete_prefix(examples_root + "/"),
      }
    end
  end

  def resource_manifest
    resources_root = File.expand_path("../examples/sdl3/resources", __dir__)

    raw_manifest, idiomatic_manifest = example_manifest.partition do |entry|
      entry.fetch(:relative_path).start_with?("sdl3/")
    end

    raw_resources = raw_manifest.flat_map do |entry|
      source = File.read(entry.fetch(:path))

      source.scan(%r{\.\./resources/([^"\s]+)}).flatten.uniq.map do |resource_relative_path|
        {
          relative_path: entry.fetch(:relative_path),
          resource_relative_path: resource_relative_path,
          resource_path: File.join(resources_root, resource_relative_path),
        }
      end
    end

    idiomatic_resources = idiomatic_manifest.flat_map do |entry|
      source = File.read(entry.fetch(:path))

      source.scan(%r{\.\./\.\./sdl3/resources/([^"\s]+)}).flatten.uniq.map do |resource_relative_path|
        {
          relative_path: entry.fetch(:relative_path),
          resource_relative_path: resource_relative_path,
          resource_path: File.join(resources_root, resource_relative_path),
        }
      end
    end

    raw_resources + idiomatic_resources
  end

  def compiler_available?(compiler)
    return File.executable?(compiler) if compiler.include?(File::SEPARATOR)

    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |entry|
      candidate = File.join(entry, compiler)
      File.file?(candidate) && File.executable?(candidate)
    end
  end
end
