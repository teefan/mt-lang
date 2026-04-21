# frozen_string_literal: true

require "stringio"
require_relative "test_helper"

class MilkTeaCliTest < Minitest::Test
  def test_parse_command_reports_success
    out = StringIO.new
    err = StringIO.new

    status = MilkTea::CLI.start(["parse", demo_path], out:, err:)

    assert_equal 0, status
    assert_match(/parsed .*milk-tea-demo\.mt as demo\.bouncing_ball/, out.string)
    assert_equal "", err.string
  end

  def test_parse_command_requires_a_path
    out = StringIO.new
    err = StringIO.new

    status = MilkTea::CLI.start(["parse"], out:, err:)

    assert_equal 1, status
    assert_equal "", out.string
    assert_match(/missing source file path/, err.string)
    assert_match(/Usage: mtc parse PATH/, err.string)
  end

  def test_invalid_commands_print_usage
    out = StringIO.new
    err = StringIO.new

    status = MilkTea::CLI.start(["unknown"], out:, err:)

    assert_equal 1, status
    assert_equal "", out.string
    assert_match(/Usage: mtc parse PATH/, err.string)
  end

  def test_parse_command_reports_loader_errors
    out = StringIO.new
    err = StringIO.new

    status = MilkTea::CLI.start(["parse", __dir__], out:, err:)

    assert_equal 1, status
    assert_equal "", out.string
    assert_match(/expected a source file, got a directory/, err.string)
  end

  private

  def demo_path
    File.expand_path("../examples/milk-tea-demo.mt", __dir__)
  end
end
