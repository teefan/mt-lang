# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaGlfwExamplesBuildTest < Minitest::Test
  def test_glfw_examples_build_with_host_compiler
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    manifest = example_manifest
    refute_empty manifest

    Dir.mktmpdir("milk-tea-glfw-examples-build") do |dir|
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
        assert_includes result.link_flags, "-lglfw3", relative_path
        assert File.exist?(output_path), "#{relative_path} did not produce an output binary"
        assert File.exist?(c_path), "#{relative_path} did not produce a C file"

        generated_c = File.read(c_path)
        assert_match(/#include "GLFW\/glfw3\.h"/, generated_c, relative_path)
        assert_match(/#include "gl_registry_helpers\.h"/, generated_c, relative_path)
        assert_match(/mt_gl_use_glfw_loader\(/, generated_c, relative_path)
      end
    end
  end

  private

  def announce_build_progress(current, total, relative_path)
    $stdout.puts("[glfw_examples_build_test #{current}/#{total}] #{relative_path}")
    $stdout.flush
  end

  def example_manifest
    examples_root = File.expand_path("../../examples", __dir__)
    glfw_examples_root = File.join(examples_root, "glfw")

    Dir[File.join(glfw_examples_root, "*.mt")].sort.map do |path|
      {
        path: path,
        relative_path: path.delete_prefix(examples_root + "/"),
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
