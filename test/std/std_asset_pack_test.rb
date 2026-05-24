# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdAssetPackTest < Minitest::Test
  def test_host_runtime_reads_packed_assets_by_logical_path
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-std-asset-pack") do |dir|
      assets_dir = File.join(dir, "assets")
      audio_dir = File.join(assets_dir, "audio")
      credits_path = File.join(dir, "credits.txt")
      pack_path = File.join(dir, "assets.mtpack")
      FileUtils.mkdir_p(audio_dir)
      File.write(File.join(audio_dir, "hit.txt"), "wavdata")
      File.write(credits_path, "credits\n")
      MilkTea::AssetPack.write(pack_path, [credits_path, assets_dir])

      source = <<~MT

import std.asset_pack as asset_pack
import std.bytes as bytes



function read_text_length(result: Result[bytes.Bytes, asset_pack.Error]) -> int:
    match result:
        Result.failure as ignored_error:
            return 100
        Result.success as payload:
            var owned = payload.value
            defer owned.release()
            let text_result = owned.as_str()
            match text_result:
                Option.none:
                    return 101
                Option.some as text_payload:
                    return int<-text_payload.value.len
            return 101
    return 100

function main() -> int:
    let open_result = asset_pack.open(#{pack_path.dump})
    match open_result:
        Result.failure as ignored_error:
            return 1
        Result.success as payload:
            var reader = payload.value
            defer reader.close()
            let first = read_text_length(reader.read_bytes(\"assets/audio/hit.txt\"))
            let second = read_text_length(reader.read_bytes(\"credits.txt\"))
            return first + second
    return 1

      MT

      result = run_program(dir, source, compiler:)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 15, result.exit_status
      assert_equal [], result.link_flags
    end
  end

  def test_host_runtime_reports_missing_packed_asset
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-std-asset-pack-missing") do |dir|
      assets_dir = File.join(dir, "assets")
      pack_path = File.join(dir, "assets.mtpack")
      FileUtils.mkdir_p(assets_dir)
      File.write(File.join(assets_dir, "tiles.txt"), "tiles\n")
      MilkTea::AssetPack.write(pack_path, [assets_dir])

      source = <<~MT

import std.asset_pack as asset_pack


function main() -> int:
    let open_result = asset_pack.open(#{pack_path.dump})
    match open_result:
        Result.failure as ignored_error:
            return 1
        Result.success as payload:
            var reader = payload.value
            defer reader.close()
            let read_result = reader.read_bytes(\"missing.txt\")
            match read_result:
                Result.success as ignored_payload:
                    return 2
                Result.failure as error_payload:
                    if error_payload.error == asset_pack.Error.entry_not_found:
                        return 0
                    if error_payload.error == asset_pack.Error.closed:
                        return 3
                    if error_payload.error == asset_pack.Error.invalid_magic:
                        return 4
                    if error_payload.error == asset_pack.Error.unsupported_version:
                        return 5
                    if error_payload.error == asset_pack.Error.unsupported_flags:
                        return 6
                    if error_payload.error == asset_pack.Error.range:
                        return 7
                    if error_payload.error == asset_pack.Error.malformed_header:
                        return 8
                    if error_payload.error == asset_pack.Error.malformed_index:
                        return 9
                    if error_payload.error == asset_pack.Error.io:
                        return 10
                    if error_payload.error == asset_pack.Error.open_failed:
                        return 11
            return 12
    return 1

      MT

      result = run_program(dir, source, compiler:)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 0, result.exit_status
      assert_equal [], result.link_flags
    end
  end

  def test_host_runtime_rejects_invalid_pack_magic
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-std-asset-pack-invalid") do |dir|
      pack_path = File.join(dir, "broken.mtpack")
      File.binwrite(pack_path, ["NOPE", 1, 0, 0, 0, 28].pack(MilkTea::AssetPack::HEADER_FORMAT))

      source = <<~MT

import std.asset_pack as asset_pack


function main() -> int:
    let open_result = asset_pack.open(#{pack_path.dump})
    match open_result:
        Result.success as ignored_payload:
            return 1
        Result.failure as payload:
            if payload.error == asset_pack.Error.invalid_magic:
                return 0
            if payload.error == asset_pack.Error.malformed_header:
                return 2
            if payload.error == asset_pack.Error.open_failed:
                return 3
            if payload.error == asset_pack.Error.closed:
                return 4
            if payload.error == asset_pack.Error.unsupported_version:
                return 5
            if payload.error == asset_pack.Error.unsupported_flags:
                return 6
            if payload.error == asset_pack.Error.range:
                return 7
            if payload.error == asset_pack.Error.malformed_index:
                return 8
            if payload.error == asset_pack.Error.entry_not_found:
                return 9
            if payload.error == asset_pack.Error.io:
                return 10
    return 1

      MT

      result = run_program(dir, source, compiler:)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 0, result.exit_status
      assert_equal [], result.link_flags
    end
  end

  private

  def run_program(dir, source, compiler:)
    source_path = File.join(dir, "program.mt")
    File.write(source_path, source)
    MilkTea::Run.run(source_path, cc: compiler)
  end

  def compiler_available?(compiler)
    return File.executable?(compiler) if compiler.include?(File::SEPARATOR)

    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |entry|
      candidate = File.join(entry, compiler)
      File.file?(candidate) && File.executable?(candidate)
    end
  end
end
