# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaPackageManifestEditorTest < Minitest::Test
  def test_add_dependency_preserves_original_manifest_when_atomic_replace_fails
    Dir.mktmpdir("milk-tea-manifest-editor-atomic") do |dir|
      FileUtils.mkdir_p(File.join(dir, "src"))
      manifest_path = File.join(dir, "package.toml")
      original_source = <<~TOML
        [package]
        name = "demo"
        version = "0.1.0"
        source_root = "src"
      TOML
      File.write(manifest_path, original_source)

      editor = MilkTea::PackageManifestEditor.new(dir)

      error = with_singleton_method_override(File, :rename, lambda do |*_args|
        raise Errno::EIO, "rename failed"
      end) do
        assert_raises(MilkTea::PackageManifestEditorError) do
          editor.add_dependency("demo.ui", "^1.2.3")
        end
      end

      assert_match(/failed to update/, error.message)
      assert_equal original_source, File.read(manifest_path)
    end
  end
end
