# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"

class MilkTeaEntrypointTest < Minitest::Test
  def test_top_level_entrypoint_loads_core_and_tooling_without_bindings
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", <<~RUBY, chdir: repo_root)
      require "milk_tea"
      puts MilkTea.const_defined?(:Build, false)
      puts MilkTea.const_defined?(:CLI, false)
      puts MilkTea.const_defined?(:Bindgen, false)
      puts MilkTea.const_defined?(:RawBindings, false)
      puts MilkTea.const_defined?(:ImportedBindings, false)
      puts MilkTea.const_defined?(:UpstreamSources, false)
    RUBY

    assert status.success?, stderr
    assert_equal ["true", "true", "false", "false", "false", "false"], stdout.lines(chomp: true)
  end

  def test_bindings_entrypoint_loads_bindings_tooling
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", <<~RUBY, chdir: repo_root)
      require "milk_tea/bindings"
      puts MilkTea.const_defined?(:Bindgen, false)
      puts MilkTea.const_defined?(:RawBindings, false)
      puts MilkTea.const_defined?(:ImportedBindings, false)
      puts MilkTea.const_defined?(:UpstreamSources, false)
    RUBY

    assert status.success?, stderr
    assert_equal ["true", "true", "true", "true"], stdout.lines(chomp: true)
  end

  private

  def repo_root
    File.expand_path("../..", __dir__)
  end
end
