# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "shellwords"
require "tmpdir"
require_relative "../test_helper"

class MilkTeaCliContractTest < Minitest::Test
  FIXTURE_ROOT = File.expand_path("fixtures", __dir__)
  DEFAULT_CLI_COMMAND = [RbConfig.ruby, File.expand_path("../../bin/mtc", __dir__)].freeze
  CONTRACT_CLI_COMMAND_ENV = "MILK_TEA_CONTRACT_CLI_CMD"

  Dir.glob(File.join(FIXTURE_ROOT, "*", "case.json")).sort.each do |case_path|
    case_dir = File.dirname(case_path)
    case_name = JSON.parse(File.read(case_path)).fetch("name")

    define_method("test_contract_case_#{case_name}") do
      run_contract_case(case_dir, JSON.parse(File.read(case_path)))
    end
  end

  private

  def run_contract_case(case_dir, contract_case)
    Dir.mktmpdir("milk-tea-cli-contract") do |sandbox|
      FileUtils.cp_r(File.join(case_dir, "."), sandbox)
      Array(contract_case["executablePaths"]).each do |relative_path|
        File.chmod(0o755, File.join(sandbox, relative_path))
      end

      stdout, stderr, status = Open3.capture3(
        *contract_cli_command,
        *contract_case.fetch("argv"),
        chdir: File.join(sandbox, contract_case.fetch("cwd", ".")),
      )

      assert_equal contract_case.fetch("exitStatus"), status.exitstatus
      assert_equal contract_case.fetch("stderr", ""), stderr

      stdout_expectation = contract_case.fetch("stdout")
      expected_path = File.join(case_dir, stdout_expectation.fetch("path"))
      assert_stdout_expectation(stdout, stdout_expectation.fetch("type"), expected_path)

      Array(contract_case["files"]).each do |file_expectation|
        assert_file_expectation(case_dir, sandbox, file_expectation)
      end
    end
  end

  def assert_file_expectation(case_dir, sandbox, file_expectation)
    actual_path = File.join(sandbox, file_expectation.fetch("path"))
    assert File.exist?(actual_path), "expected file #{file_expectation.fetch('path')} to exist"

    expectation = file_expectation["expectation"]
    return unless expectation

    expected_path = File.join(case_dir, expectation.fetch("path"))
    assert_stdout_expectation(File.read(actual_path), expectation.fetch("type"), expected_path)
  end

  def assert_stdout_expectation(stdout, type, expected_path)
    case type
    when "json-exact"
      assert_equal JSON.parse(File.read(expected_path)), JSON.parse(stdout)
    when "json-projection"
      expected = JSON.parse(File.read(expected_path))
      actual = JSON.parse(stdout)
      assert_equal expected, projected_json(actual, expected)
    when "text-exact"
      assert_equal File.read(expected_path), stdout
    when "text-regexp-all"
      JSON.parse(File.read(expected_path)).each do |pattern|
        assert_match Regexp.new(pattern, Regexp::MULTILINE), stdout
      end
    else
      flunk("unknown stdout expectation type #{type.inspect}")
    end
  end

  def contract_cli_command
    configured_command = ENV.fetch(CONTRACT_CLI_COMMAND_ENV, "").strip
    return DEFAULT_CLI_COMMAND if configured_command.empty?

    command = Shellwords.split(configured_command)
    raise ArgumentError, "#{CONTRACT_CLI_COMMAND_ENV} must not be empty" if command.empty?

    command
  end

  def projected_json(actual, expected)
    case expected
    when Hash
      expected.each_with_object({}) do |(key, value), memo|
        memo[key] = projected_json(actual.fetch(key), value)
      end
    when Array
      assert_operator actual.length, :>=, expected.length
      expected.each_with_index.map do |value, index|
        projected_json(actual.fetch(index), value)
      end
    else
      actual
    end
  end
end
