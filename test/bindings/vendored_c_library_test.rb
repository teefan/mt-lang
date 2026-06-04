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

  def test_archive_reindexes_up_to_date_static_library
    Dir.mktmpdir("milk-tea-vendored-c-library") do |dir|
      source_root = File.join(dir, "src")
      build_root = File.join(dir, "build")
      FileUtils.mkdir_p(source_root)
      FileUtils.mkdir_p(build_root)

      source_path = File.join(source_root, "helper.c")
      object_path = File.join(build_root, "helper.o")
      archive_path = File.join(build_root, "libsample.a")
      File.write(source_path, "int helper(void) { return 1; }\n")
      File.write(object_path, "\x7fELF")
      File.write(archive_path, "\x00")

      source_time = Time.now - 3
      object_time = Time.now - 2
      archive_time = Time.now - 1
      File.utime(source_time, source_time, source_path)
      File.utime(object_time, object_time, object_path)
      File.utime(archive_time, archive_time, archive_path)

      archive = MilkTea::VendoredCLibrary::Archive.new(
        name: "sample",
        source_root:,
        build_root:,
        archive_name: "libsample.a",
        sources: ["helper.c"],
        include_roots: [source_root],
      )
      signature = archive.send(:configuration_signature, cc: "cc-custom", cxx: "cxx-custom", ar: "ar-custom")
      File.write(File.join(build_root, ".milk-tea-signature"), signature)

      commands = []
      with_singleton_method_override(Open3, :capture3, lambda { |*args|
        commands << args.dup
        ["", "", success_status]
      }) do
        archive.prepare!(env: { "AR" => "ar-custom" }, cc: "cc-custom", cxx: "cxx-custom")
      end

      assert_equal [["ar-custom", "s", archive_path]], commands
    end
  end

  def test_archive_rejects_zero_byte_object_files
    Dir.mktmpdir("milk-tea-vendored-c-library") do |dir|
      source_root = File.join(dir, "src")
      build_root = File.join(dir, "build")
      FileUtils.mkdir_p(source_root)
      FileUtils.mkdir_p(build_root)

      source_path = File.join(source_root, "helper.c")
      object_path = File.join(build_root, "helper.o")
      archive_path = File.join(build_root, "libsample.a")
      File.write(source_path, "int helper(void) { return 1; }\n")
      File.write(object_path, "")
      File.write(archive_path, "\x00")

      source_time = Time.now - 3
      object_time = Time.now - 2
      archive_time = Time.now - 1
      File.utime(source_time, source_time, source_path)
      File.utime(object_time, object_time, object_path)
      File.utime(archive_time, archive_time, archive_path)

      archive = MilkTea::VendoredCLibrary::Archive.new(
        name: "sample",
        source_root:,
        build_root:,
        archive_name: "libsample.a",
        sources: ["helper.c"],
        include_roots: [source_root],
      )
      signature = archive.send(:configuration_signature, cc: "cc-custom", cxx: "cxx-custom", ar: "ar-custom")
      File.write(File.join(build_root, ".milk-tea-signature"), signature)

      commands = []
      with_singleton_method_override(Open3, :capture3, lambda { |*args|
        cmd = args.dup
        commands << cmd
        output_index = cmd.index("-o")
        if output_index
          output_path = cmd[output_index + 1]
          FileUtils.mkdir_p(File.dirname(output_path))
          File.write(output_path, "compiled")
        end
        ["", "", success_status]
      }) do
        archive.prepare!(env: { "AR" => "ar-custom" }, cc: "cc-custom", cxx: "cxx-custom")
      end

      refute commands.none? { |cmd| cmd.include?("-c") }, "expected a compilation command for the zero-byte object"
    end
  end

  def test_archive_creates_nested_object_directories_for_nested_sources
    Dir.mktmpdir("milk-tea-vendored-c-library") do |dir|
      source_root = File.join(dir, "src")
      build_root = File.join(dir, "build")
      FileUtils.mkdir_p(File.join(source_root, "distr"))
      File.write(File.join(source_root, "distr", "helper.c"), "int helper(void) { return 1; }\n")

      archive = MilkTea::VendoredCLibrary::Archive.new(
        name: "sample",
        source_root:,
        build_root:,
        archive_name: "libsample.a",
        sources: ["distr/helper.c"],
        include_roots: [source_root],
      )

      with_singleton_method_override(Open3, :capture3, lambda { |*args|
        output_index = args.index("-o")
        if output_index
          output_path = args[output_index + 1]
          File.write(output_path, "")
        elsif args[0] == "ar"
          FileUtils.mkdir_p(File.dirname(archive.archive_path.to_s))
          File.write(archive.archive_path.to_s, "")
        end

        ["", "", success_status]
      }) do
        archive.prepare!(cc: "cc")
      end

      assert File.exist?(File.join(build_root, "distr", "helper.o"))
    end
  end

  def test_cmake_link_flags_parse_pkg_config_with_compiled_read_lines_helper
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-vendored-c-library") do |dir|
      source_root = File.join(dir, "src")
      build_root = File.join(dir, "build")
      install_root = File.join(dir, "install")
      archive_path = File.join(install_root, "lib", "libsample.a")
      pc_dir = File.join(install_root, "lib", "pkgconfig")

      FileUtils.mkdir_p(source_root)
      FileUtils.mkdir_p(pc_dir)
      File.write(File.join(pc_dir, "sample.pc"), <<~PC)
        prefix=#{install_root}
        libdir=${prefix}/lib
        includedir=${prefix}/include
        Name: sample
        Libs: -L${libdir} -lsample
        Libs.private: -lm
      PC

      library = MilkTea::VendoredCLibrary::CMake.new(
        name: "sample",
        source_root:,
        build_root:,
        install_root:,
        archive_path:,
        pkg_config_name: "sample",
      )

      assert_equal ["-L#{File.dirname(archive_path)}", "-lsample", "-lm"], library.link_flags
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

  def compiler_available?(compiler)
    return File.executable?(compiler) if compiler.include?(File::SEPARATOR)

    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |entry|
      candidate = File.join(entry, compiler)
      File.file?(candidate) && File.executable?(candidate)
    end
  end
end
