# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaAssetPackTest < Minitest::Test
  def test_write_packs_directory_and_file_entries_with_deterministic_binary_index
    Dir.mktmpdir("milk-tea-asset-pack") do |dir|
      assets_dir = File.join(dir, "assets")
      audio_dir = File.join(assets_dir, "audio")
      credits_path = File.join(dir, "credits.txt")
      output_path = File.join(dir, "build", "assets.mtpack")
      FileUtils.mkdir_p(audio_dir)

      File.write(File.join(assets_dir, "tiles.txt"), "tiles\n")
      File.write(File.join(audio_dir, "hit.wav"), "wavdata")
      File.write(credits_path, "credits\n")

      result = MilkTea::AssetPack.write(output_path, [credits_path, assets_dir])
      pack = parse_pack(output_path)

      assert_equal output_path, result
      assert_equal MilkTea::AssetPack::MAGIC, pack.fetch(:magic)
      assert_equal MilkTea::AssetPack::VERSION, pack.fetch(:version)
      assert_equal 0, pack.fetch(:header_flags)
      assert_equal 3, pack.fetch(:entry_count)
      assert_equal MilkTea::AssetPack::HEADER_SIZE + pack.fetch(:index_size), pack.fetch(:data_offset)

      assert_equal [
        "assets/audio/hit.wav",
        "assets/tiles.txt",
        "credits.txt",
      ], pack.fetch(:entries).map { |entry| entry.fetch(:path) }

      assert_equal "wavdata", pack.fetch(:entries)[0].fetch(:data)
      assert_equal "tiles\n", pack.fetch(:entries)[1].fetch(:data)
      assert_equal "credits\n", pack.fetch(:entries)[2].fetch(:data)
      assert_equal [7, 6, 8], pack.fetch(:entries).map { |entry| entry.fetch(:stored_size) }
      assert_equal pack.fetch(:entries).map { |entry| entry.fetch(:stored_size) }, pack.fetch(:entries).map { |entry| entry.fetch(:unpacked_size) }
    end
  end

  def test_write_is_deterministic_for_same_source_tree
    Dir.mktmpdir("milk-tea-asset-pack-deterministic") do |dir|
      assets_dir = File.join(dir, "assets")
      credits_path = File.join(dir, "credits.txt")
      output_a = File.join(dir, "build", "a.mtpack")
      output_b = File.join(dir, "build", "b.mtpack")
      FileUtils.mkdir_p(assets_dir)

      File.write(File.join(assets_dir, "tiles.txt"), "tiles\n")
      File.write(credits_path, "credits\n")

      MilkTea::AssetPack.write(output_a, [credits_path, assets_dir])
      MilkTea::AssetPack.write(output_b, [assets_dir, credits_path])

      assert_equal File.binread(output_a), File.binread(output_b)
    end
  end

  def test_write_rejects_output_inside_source_tree
    Dir.mktmpdir("milk-tea-asset-pack-overlap") do |dir|
      assets_dir = File.join(dir, "assets")
      output_path = File.join(assets_dir, "packed.mtpack")
      FileUtils.mkdir_p(assets_dir)
      File.write(File.join(assets_dir, "tiles.txt"), "tiles\n")

      error = assert_raises(MilkTea::AssetPackError) do
        MilkTea::AssetPack.write(output_path, [assets_dir])
      end

      assert_match(/asset pack output would be written inside source tree/, error.message)
    end
  end

  private

  def parse_pack(path)
    bytes = File.binread(path)
    magic, version, header_flags, entry_count, index_size, data_offset = bytes.byteslice(0, MilkTea::AssetPack::HEADER_SIZE).unpack(MilkTea::AssetPack::HEADER_FORMAT)

    offset = MilkTea::AssetPack::HEADER_SIZE
    entries = []
    entry_count.times do
      path_length, flags, entry_data_offset, stored_size, unpacked_size = bytes.byteslice(offset, MilkTea::AssetPack::ENTRY_PREFIX_SIZE).unpack(MilkTea::AssetPack::ENTRY_PREFIX_FORMAT)
      offset += MilkTea::AssetPack::ENTRY_PREFIX_SIZE

      path_bytes = bytes.byteslice(offset, path_length)
      offset += path_length

      entries << {
        path: path_bytes.force_encoding(Encoding::UTF_8),
        flags:,
        data_offset: entry_data_offset,
        stored_size:,
        unpacked_size:,
        data: bytes.byteslice(entry_data_offset, stored_size),
      }
    end

    {
      magic:,
      version:,
      header_flags:,
      entry_count:,
      index_size:,
      data_offset:,
      entries:,
    }
  end
end
