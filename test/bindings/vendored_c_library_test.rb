# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"
require_relative "../../lib/milk_tea/bindings"

class MilkTeaVendoredCLibraryTest < Minitest::Test
  def test_archive_uses_cxx_for_cpp_sources
    Dir.mktmpdir("milk-tea-vendored-c-library") do |dir|
      source_root = File.join(dir, "src")
      build_root = File.join(dir, "build")
      FileUtils.mkdir_p(source_root)
      File.write(File.join(source_root, "helper.c"), "int helper(void) { return 1; }\n")
      File.write(File.join(source_root, "shim.cpp"), "int shim() { return 2; }\n")

      archive = MilkTea::VendoredCLibrary::Archive.new(
        name: "sample",
        source_root:,
        build_root:,
        archive_name: "libsample.a",
        sources: ["helper.c", "shim.cpp"],
        include_roots: [source_root],
        cxx_flags: ["-std=c++17"],
      )

      commands = []
      with_singleton_method_override(Open3, :capture3, lambda { |*args|
        command = args.dup
        commands << command

        output_index = command.index("-o")
        if output_index
          output_path = command[output_index + 1]
          FileUtils.mkdir_p(File.dirname(output_path))
          File.write(output_path, "")
        elsif command[0] == "ar-custom"
          FileUtils.mkdir_p(File.dirname(archive.archive_path.to_s))
          File.write(archive.archive_path.to_s, "")
        end

        ["", "", success_status]
      }) do
        archive.prepare!(env: { "AR" => "ar-custom" }, cc: "cc-custom", cxx: "cxx-custom")
      end

      c_command = commands.find { |command| command.include?(File.join(source_root, "helper.c")) }
      cpp_command = commands.find { |command| command.include?(File.join(source_root, "shim.cpp")) }
      ar_command = commands.find { |command| command[0] == "ar-custom" }

      refute_nil c_command
      refute_nil cpp_command
      refute_nil ar_command
      assert_equal "cc-custom", c_command.first
      assert_equal "cxx-custom", cpp_command.first
      assert_includes cpp_command, "-std=c++17"
      refute_includes c_command, "-std=c++17"
    end
  end

  private

  def success_status
    Object.new.tap do |status|
      status.define_singleton_method(:success?) { true }
    end
  end

  def with_singleton_method_override(object, method_name, implementation)
    singleton_class = class << object; self; end
    original_name = "__vendored_c_library_original_#{method_name}__"
    original_defined = singleton_class.method_defined?(method_name) || singleton_class.private_method_defined?(method_name)
    singleton_class.alias_method(original_name, method_name) if original_defined
    singleton_class.define_method(method_name) do |*args, **kwargs, &block|
      implementation.call(*args, **kwargs, &block)
    end
    yield
  ensure
    singleton_class.remove_method(method_name) if singleton_class.method_defined?(method_name)
    if original_defined
      singleton_class.alias_method(method_name, original_name)
      singleton_class.remove_method(original_name)
    end
  end
end
