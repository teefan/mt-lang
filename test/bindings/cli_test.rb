# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"
require_relative "../test_helper"
require_relative "../../lib/milk_tea/bindings"

class MilkTeaBindingsCliTest < Minitest::Test
  def test_start_requires_module_name_and_header_path
    out = StringIO.new
    err = StringIO.new

    status = MilkTea::BindgenCLI.start([], out:, err:, help_printer: ->(io) { io.puts("bindgen help") })

    assert_equal 1, status
    assert_equal "", out.string
    assert_match(/missing module name or header path/, err.string)
    assert_match(/bindgen help/, err.string)
  end

  def test_start_rejects_unknown_option
    Dir.mktmpdir("milk-tea-bindgen-cli-unknown") do |dir|
      header_path = File.join(dir, "sample.h")
      File.write(header_path, "int add(int a, int b);\n")
      out = StringIO.new
      err = StringIO.new

      status = MilkTea::BindgenCLI.start(["std.c.sample", header_path, "--wat"], out:, err:, help_printer: ->(io) { io.puts("bindgen help") })

      assert_equal 1, status
      assert_equal "", out.string
      assert_match(/unknown bindgen option --wat/, err.string)
      assert_match(/bindgen help/, err.string)
    end
  end

  def test_start_writes_generated_output_file
    Dir.mktmpdir("milk-tea-bindgen-cli-output") do |dir|
      header_path = File.join(dir, "sample.h")
      output_path = File.join(dir, "out", "sample.mt")
      File.write(header_path, "int add(int a, int b);\n")
      out = StringIO.new
      err = StringIO.new
      observed = {}
      generator = lambda do |module_name:, header_path:, **options|
        observed[:module_name] = module_name
        observed[:header_path] = header_path
        observed[:options] = options
        "external\n"
      end

      with_singleton_method_override(MilkTea::Bindgen, :generate, generator) do
        status = MilkTea::BindgenCLI.start(
          ["std.c.sample", header_path, "-o", output_path, "--link", "sample", "--include", "sample.h", "--clang", "fake-clang", "--clang-arg", "-DDEBUG"],
          out:,
          err:,
          help_printer: ->(io) { io.puts("bindgen help") },
        )

        assert_equal 0, status
      end

      assert_equal "std.c.sample", observed[:module_name]
      assert_equal header_path, observed[:header_path]
      assert_equal ["sample"], observed[:options][:link_libraries]
      assert_equal ["sample.h"], observed[:options][:include_directives]
      assert_equal "fake-clang", observed[:options][:clang]
      assert_equal ["-DDEBUG"], observed[:options][:clang_args]
      assert_equal "external\n", File.read(output_path)
      assert_match(/generated .*sample\.h -> .*sample\.mt/, out.string)
      assert_equal "", err.string
    end
  end

  def test_start_writes_generated_source_to_stdout_without_output_path
    Dir.mktmpdir("milk-tea-bindgen-cli-stdout") do |dir|
      header_path = File.join(dir, "sample.h")
      File.write(header_path, "int add(int a, int b);\n")
      out = StringIO.new
      err = StringIO.new

      with_singleton_method_override(MilkTea::Bindgen, :generate, lambda { |module_name:, header_path:, **options| "external\n" }) do
        status = MilkTea::BindgenCLI.start(
          ["std.c.sample", header_path, "--link", "sample"],
          out:,
          err:,
          help_printer: ->(io) { io.puts("bindgen help") },
        )

        assert_equal 0, status
      end

      assert_equal "external\n", out.string
      assert_equal "", err.string
    end
  end

  def test_start_writes_nullable_report_when_requested
    Dir.mktmpdir("milk-tea-bindgen-cli-report") do |dir|
      header_path = File.join(dir, "sample.h")
      report_path = File.join(dir, "reports", "nullable.json")
      File.write(header_path, "int add(int a, int b);\n")
      out = StringIO.new
      err = StringIO.new
      generator = lambda do |module_name:, header_path:, **_options|
        {
          source: "external\n",
          nullable_policy_report: { summary: { total: 1 }, entries: [{ function: "add" }] },
        }
      end

      with_singleton_method_override(MilkTea::Bindgen, :generate_with_report, generator) do
        status = MilkTea::BindgenCLI.start(
          ["std.c.sample", header_path, "--nullable-report", report_path],
          out:,
          err:,
          help_printer: ->(io) { io.puts("bindgen help") },
        )

        assert_equal 0, status
      end

      assert_equal "external\n", out.string
      assert_match(/wrote nullable report .*nullable\.json/, err.string)
      assert_equal({ "summary" => { "total" => 1 }, "entries" => [{ "function" => "add" }] }, JSON.parse(File.read(report_path)))
    end
  end

  def test_start_writes_output_file_and_nullable_report_together
    Dir.mktmpdir("milk-tea-bindgen-cli-output-and-report") do |dir|
      header_path = File.join(dir, "sample.h")
      output_path = File.join(dir, "out", "sample.mt")
      report_path = File.join(dir, "reports", "nullable.json")
      File.write(header_path, "int add(int a, int b);\n")
      out = StringIO.new
      err = StringIO.new

      with_singleton_method_override(MilkTea::Bindgen, :generate_with_report, lambda { |module_name:, header_path:, **options| { source: "external\n", nullable_policy_report: { summary: { total: 1 } } } }) do
        status = MilkTea::BindgenCLI.start(
          ["std.c.sample", header_path, "-o", output_path, "--nullable-report", report_path],
          out:,
          err:,
          help_printer: ->(io) { io.puts("bindgen help") },
        )

        assert_equal 0, status
      end

      assert_equal "", err.string
      assert_equal "external\n", File.read(output_path)
      assert_equal({ "summary" => { "total" => 1 } }, JSON.parse(File.read(report_path)))
      assert_match(/generated .*sample\.h -> .*sample\.mt/, out.string)
      assert_match(/nullable report .*sample\.h -> .*nullable\.json/, out.string)
    end
  end

  def test_parse_options_requires_values_for_all_flagged_options
    {
      "-o" => /missing value for -o/,
      "--link" => /missing value for --link/,
      "--include" => /missing value for --include/,
      "--clang" => /missing value for --clang/,
      "--clang-arg" => /missing value for --clang-arg/,
      "--nullable-report" => /missing value for --nullable-report/,
    }.each do |option, message|
      out = StringIO.new
      err = StringIO.new

      options = MilkTea::BindgenCLI.new([option], out:, err:, help_printer: ->(io) { io.puts("bindgen help") }).send(:parse_options)

      assert_nil options
      assert_equal "", out.string
      assert_match(message, err.string)
      assert_match(/bindgen help/, err.string)
    end
  end

  def test_parse_options_defaults_include_directives_to_nil
    out = StringIO.new
    err = StringIO.new

    options = MilkTea::BindgenCLI.new([], out:, err:, help_printer: ->(io) { io.puts("bindgen help") }).send(:parse_options)

    assert_nil options[:include_directives]
    assert_equal [], options[:link_libraries]
    assert_equal [], options[:clang_args]
    assert_equal "", out.string
    assert_equal "", err.string
  end
end
