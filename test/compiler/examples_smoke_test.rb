# frozen_string_literal: true

require_relative "../test_helper"

class MilkTeaExamplesSmokeTest < Minitest::Test
  def test_all_examples_type_check
    example_files = Dir.glob(File.join(EXAMPLES_ROOT, "*.mt")).sort
    refute_empty example_files, "expected example files in examples/"

    example_files.each do |path|
      basename = File.basename(path)
      err = StringIO.new
      MilkTea::CLI.start(["check", path], out: StringIO.new, err:)
      errors = err.string.scan(/\[E\d+\] error:/)
      assert_equal 0, errors.size,
        "#{basename}: #{errors.size} error(s)\n  #{err.string.lines.grep(/\[E\d+\] error:/).first(5).map(&:strip).join("\n  ")}"
    end
  end

  private

  EXAMPLES_ROOT = File.expand_path("../../examples", __dir__)
end
