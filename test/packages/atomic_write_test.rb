# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaPackageAtomicWriteTest < Minitest::Test
  def test_write_creates_parent_directories_and_writes_content
    Dir.mktmpdir("milk-tea-atomic-write-basic") do |dir|
      path = File.join(dir, "deep", "nested", "file.txt")
      content = "hello world\n"

      written_path = MilkTea::PackageAtomicWrite.write(path, content)

      assert_equal File.expand_path(path), written_path
      assert File.file?(written_path)
      assert_equal content, File.read(written_path)
    end
  end

  def test_write_overwrites_existing_file
    Dir.mktmpdir("milk-tea-atomic-write-overwrite") do |dir|
      path = File.join(dir, "file.txt")
      original = "original\n"
      updated = "updated\n"
      File.write(path, original)

      MilkTea::PackageAtomicWrite.write(path, updated)

      assert_equal updated, File.read(path)
    end
  end

  def test_replace_via_backup_preserves_data_when_final_rename_fails
    Dir.mktmpdir("milk-tea-atomic-write-backup") do |dir|
      destination = File.join(dir, "target.txt")
      source = File.join(dir, "source.txt")
      File.write(destination, "destination content\n")
      File.write(source, "source content\n")

      with_singleton_method_override(File, :rename, lambda do |*args|
        old, new = args
        if new == destination
          raise Errno::EIO, "final rename failed"
        else
          File.rename(old, new)
        end
      end) do
        assert_raises(SystemCallError) do
          MilkTea::PackageAtomicWrite.replace(source, destination)
        end
      end

      assert_equal "destination content\n", File.read(destination)
      assert File.file?(source)
    end
  end

  def test_replace_handles_nonexistent_destination
    Dir.mktmpdir("milk-tea-atomic-write-no-dest") do |dir|
      destination = File.join(dir, "target.txt")
      source = File.join(dir, "source.txt")
      File.write(source, "new content\n")

      MilkTea::PackageAtomicWrite.replace(source, destination)

      refute File.exist?(source)
      assert_equal "new content\n", File.read(destination)
    end
  end

  def test_write_uses_binmode_when_requested
    Dir.mktmpdir("milk-tea-atomic-write-binmode") do |dir|
      path = File.join(dir, "binary.bin")
      content = "\x00\x01\x02\x03".b

      MilkTea::PackageAtomicWrite.write(path, content, binmode: true)

      assert_equal content, File.binread(path)
    end
  end

  def test_open_yields_file_and_returns_path
    Dir.mktmpdir("milk-tea-atomic-write-open") do |dir|
      path = File.join(dir, "test.txt")

      returned = MilkTea::PackageAtomicWrite.open(path) do |file|
        file.write("from block\n")
      end

      assert_equal File.expand_path(path), returned
      assert_equal "from block\n", File.read(returned)
    end
  end

  def test_replace_via_backup_cleans_up_backup_on_success
    Dir.mktmpdir("milk-tea-atomic-write-backup-clean") do |dir|
      destination = File.join(dir, "target.txt")
      source = File.join(dir, "source.txt")
      File.write(destination, "old\n")
      File.write(source, "new\n")

      MilkTea::PackageAtomicWrite.replace_via_backup(source, destination)

      refute File.exist?(source)
      assert_equal "new\n", File.read(destination)
      refute File.exist?("#{destination}.bak")
    end
  end
end
