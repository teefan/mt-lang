# frozen_string_literal: true

require_relative "../test_helper"

class MilkTeaSourceIndexToolTest < Minitest::Test
  def test_list_milk_tea_files_returns_sorted_visible_sources_only
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-source-index-tool") do |dir|
      root = File.join(dir, "workspace")
      FileUtils.mkdir_p(File.join(root, "src", "nested"))
      FileUtils.mkdir_p(File.join(root, ".hidden", "nested"))
      File.write(File.join(root, "zeta.mt"), "function main() -> int:\n    return 0\n")
      File.write(File.join(root, "README.txt"), "not source\n")
      File.write(File.join(root, ".secret.mt"), "function hidden() -> int:\n    return 0\n")
      File.write(File.join(root, "src", "alpha.mt"), "function alpha() -> int:\n    return 0\n")
      File.write(File.join(root, "src", "nested", "beta.mt"), "function beta() -> int:\n    return 0\n")
      File.write(File.join(root, ".hidden", "nested", "shadow.mt"), "function shadow() -> int:\n    return 0\n")

      paths = MilkTea::SourceIndexTool.list_milk_tea_files(root_path: root, cc: compiler)

      assert_equal [
        File.join(root, "src", "alpha.mt"),
        File.join(root, "src", "nested", "beta.mt"),
        File.join(root, "zeta.mt")
      ], paths
    end
  end

  private

  def compiler_available?(compiler)
    return File.executable?(compiler) if compiler.include?(File::SEPARATOR)

    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |entry|
      candidate = File.join(entry, compiler)
      File.file?(candidate) && File.executable?(candidate)
    end
  end
end
