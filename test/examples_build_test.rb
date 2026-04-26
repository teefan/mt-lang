# frozen_string_literal: true

require "tmpdir"
require_relative "test_helper"

class MilkTeaExamplesBuildTest < Minitest::Test
  def test_all_examples_build_with_host_compiler
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-examples-build") do |dir|
      example_manifest.each do |entry|
        path = entry.fetch(:path)
        relative_path = entry.fetch(:relative_path)
        output_basename = relative_path.delete_suffix(".mt").tr("/", "__")
        output_path = File.join(dir, output_basename)
        c_path = File.join(dir, "#{output_basename}.c")

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

  private

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
