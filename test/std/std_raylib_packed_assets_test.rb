# frozen_string_literal: true

require "open3"
require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdRaylibPackedAssetsTest < Minitest::Test
  def test_host_runtime_loads_image_and_wave_from_packed_assets
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-std-raylib-packed-assets") do |dir|
      art_dir = File.join(dir, "art")
      sfx_dir = File.join(dir, "sfx")
      pack_path = File.join(dir, "assets.mtpack")
      FileUtils.mkdir_p(art_dir)
      FileUtils.mkdir_p(sfx_dir)
      File.binwrite(File.join(art_dir, "tile.png"), File.binread(tetris_tile_path))
      File.binwrite(File.join(sfx_dir, "line_clear.wav"), File.binread(tetris_sound_path))
      MilkTea::AssetPack.write(pack_path, [art_dir, sfx_dir])

      source = [
        "import std.asset_pack as pack",
        "import std.raylib as rl",
        "import std.raylib.packed_assets as rl_assets",
        "import std.status as status",
        "",
        "function main() -> int:",
        "    let open_result = pack.open(#{pack_path.dump})",
        "    match open_result:",
        "        status.Status.err:",
        "            return 1",
        "        status.Status.ok as payload:",
        "            var reader = payload.value",
        "            defer reader.close()",
        "",
        "            let image_result = rl_assets.load_image(reader, \"art/tile.png\")",
        "            match image_result:",
        "                status.Status.err as image_error:",
        "                    return 10 + int<-image_error.error",
        "                status.Status.ok as image_payload:",
        "                    let image = image_payload.value",
        "                    defer rl.unload_image(image)",
        "                    if image.width <= 0 or image.height <= 0:",
        "                        return 2",
        "",
        "            let wave_result = rl_assets.load_wave(reader, \"sfx/line_clear.wav\")",
        "            match wave_result:",
        "                status.Status.err as wave_error:",
        "                    return 20 + int<-wave_error.error",
        "                status.Status.ok as wave_payload:",
        "                    let wave = wave_payload.value",
        "                    defer rl.unload_wave(wave)",
        "                    if wave.sampleRate <= 0:",
        "                        return 3",
        "                    if wave.sampleSize <= 0:",
        "                        return 4",
        "                    if wave.channels <= 0:",
        "                        return 5",
        "                    if int<-wave.frameCount <= 0:",
        "                        return 6",
        "",
        "    return 0",
        "",
      ].join("\n")

      result = run_program(dir, source, compiler:)

      assert_equal "", result.stderr
      assert_equal 0, result.exit_status
    end
  end

  def test_host_runtime_loads_music_from_packed_assets_with_retained_bytes
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)
    skip "raylib audio device not available" unless audio_device_available?(compiler)

    Dir.mktmpdir("milk-tea-std-raylib-packed-assets-music") do |dir|
      music_dir = File.join(dir, "music")
      pack_path = File.join(dir, "assets.mtpack")
      FileUtils.mkdir_p(music_dir)
      File.binwrite(File.join(music_dir, "theme.wav"), File.binread(tetris_sound_path))
      MilkTea::AssetPack.write(pack_path, [music_dir])

      source = [
        "import std.asset_pack as pack",
        "import std.raylib as rl",
        "import std.raylib.packed_assets as rl_assets",
        "import std.status as status",
        "",
        "function main() -> int:",
        "    rl.init_audio_device()",
        "    defer rl.close_audio_device()",
        "    if not rl.is_audio_device_ready():",
        "        return 1",
        "",
        "    let open_result = pack.open(#{pack_path.dump})",
        "    match open_result:",
        "        status.Status.err:",
        "            return 2",
        "        status.Status.ok as payload:",
        "            var reader = payload.value",
        "            defer reader.close()",
        "",
        "            let music_result = rl_assets.load_music(reader, \"music/theme.wav\")",
        "            match music_result:",
        "                status.Status.err as music_error:",
        "                    return 10 + int<-music_error.error",
        "                status.Status.ok as music_payload:",
        "                    var music = music_payload.value",
        "                    defer music.release()",
        "                    if not music.is_valid():",
        "                        return 3",
        "                    if music.time_length() <= 0.0:",
        "                        return 4",
        "                    music.set_volume(0.0)",
        "                    music.play()",
        "                    var updates = 0",
        "                    while updates < 4:",
        "                        music.update()",
        "                        updates += 1",
        "                    music.pause()",
        "                    music.resume()",
        "                    music.seek(0.0)",
        "                    if music.time_played() < 0.0:",
        "                        return 5",
        "                    music.stop()",
        "",
        "    return 0",
        "",
      ].join("\n")

      result = run_program(dir, source, compiler:)

      assert_equal "", result.stderr
      assert_equal 0, result.exit_status
    end
  end

  def test_host_runtime_reports_missing_file_type_for_packed_asset_entry
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-std-raylib-packed-assets-type") do |dir|
      art_dir = File.join(dir, "art")
      pack_path = File.join(dir, "assets.mtpack")
      FileUtils.mkdir_p(art_dir)
      File.binwrite(File.join(art_dir, "tile"), File.binread(tetris_tile_path))
      MilkTea::AssetPack.write(pack_path, [art_dir])

      source = [
        "import std.asset_pack as pack",
        "import std.raylib.packed_assets as rl_assets",
        "import std.status as status",
        "",
        "function main() -> int:",
        "    let open_result = pack.open(#{pack_path.dump})",
        "    match open_result:",
        "        status.Status.err:",
        "            return 1",
        "        status.Status.ok as payload:",
        "            var reader = payload.value",
        "            defer reader.close()",
        "            let image_result = rl_assets.load_image(reader, \"art/tile\")",
        "            match image_result:",
        "                status.Status.ok:",
        "                    return 2",
        "                status.Status.err as error_payload:",
        "                    if error_payload.error == rl_assets.Error.missing_file_type:",
        "                        return 0",
        "                    return int<-error_payload.error",
        "    return 3",
        "",
      ].join("\n")

      result = run_program(dir, source, compiler:)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 0, result.exit_status
    end
  end

  def test_host_runtime_opens_assets_pack_relative_to_application_directory
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-std-raylib-packed-assets-open") do |dir|
      app_dir = File.join(dir, "bundle")
      other_dir = File.join(dir, "elsewhere")
      assets_dir = File.join(dir, "assets")
      output_path = File.join(app_dir, "demo")
      pack_path = File.join(app_dir, "assets.mtpack")
      FileUtils.mkdir_p(app_dir)
      FileUtils.mkdir_p(other_dir)
      FileUtils.mkdir_p(assets_dir)
      File.write(File.join(assets_dir, "note.txt"), "hello\n")
      MilkTea::AssetPack.write(pack_path, [assets_dir])

      source_path = File.join(dir, "program.mt")
      File.write(source_path, [
        "import std.asset_pack as pack",
        "import std.bytes as bytes",
        "import std.maybe as maybe",
        "import std.raylib.packed_assets as rl_assets",
        "import std.status as status",
        "",
        "function main() -> int:",
        "    let open_result = rl_assets.open_assets_pack_if_present()",
        "    match open_result:",
        "        status.Status.err as payload:",
        "            return int<-payload.error",
        "        status.Status.ok as payload:",
        "            match payload.value:",
        "                maybe.Maybe.none:",
        "                    return 2",
        "                maybe.Maybe.some as reader_payload:",
        "                    var reader = reader_payload.value",
        "                    defer reader.close()",
        "                    let data_result = reader.read_bytes(\"assets/note.txt\")",
        "                    match data_result:",
        "                        status.Status.err as data_payload:",
        "                            return int<-data_payload.error",
        "                        status.Status.ok as bytes_payload:",
        "                            var data = bytes_payload.value",
        "                            defer data.release()",
        "    return 0",
        "",
      ].join("\n"))

      build_result = MilkTea::Build.build(source_path, output_path:, cc: compiler)
      stdout, stderr, status = Open3.capture3(build_result.output_path, chdir: other_dir)

      assert_equal "", stdout
      assert_equal "", stderr
      assert_equal 0, status.exitstatus
    end
  end

  def test_host_runtime_reports_missing_assets_pack_as_none
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-std-raylib-packed-assets-missing-pack") do |dir|
      source = [
        "import std.maybe as maybe",
        "import std.raylib.packed_assets as rl_assets",
        "import std.status as status",
        "",
        "function main() -> int:",
        "    let open_result = rl_assets.open_assets_pack_if_present()",
        "    match open_result:",
        "        status.Status.err as payload:",
        "            return int<-payload.error",
        "        status.Status.ok as payload:",
        "            match payload.value:",
        "                maybe.Maybe.none:",
        "                    return 0",
        "                maybe.Maybe.some:",
        "                    return 1",
        "",
      ].join("\n")

      result = run_program(dir, source, compiler:)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 0, result.exit_status
    end
  end

  private

  def tetris_tile_path
    File.join(__dir__, "../../projects/tetris/assets/tetris_tiles.png")
  end

  def tetris_sound_path
    File.join(__dir__, "../../projects/tetris/assets/line_clear.wav")
  end

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

  def audio_device_available?(compiler)
    Dir.mktmpdir("milk-tea-std-raylib-audio-device") do |dir|
      source = [
        "import std.raylib as rl",
        "",
        "function main() -> int:",
        "    rl.init_audio_device()",
        "    let ready = rl.is_audio_device_ready()",
        "    rl.close_audio_device()",
        "    if ready:",
        "        return 0",
        "    return 1",
        "",
      ].join("\n")

      result = run_program(dir, source, compiler:)
      result.exit_status == 0
    end
  end
end
