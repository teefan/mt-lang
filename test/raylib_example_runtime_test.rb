# frozen_string_literal: true

require "open3"
require "tmpdir"
require_relative "test_helper"

class MilkTeaRaylibExampleRuntimeTest < Minitest::Test
  def test_smoke_examples_render_non_blank_screenshots
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    headless_runner = find_headless_runner
    skip "xvfb-run is required for raylib runtime smoke tests" unless headless_runner

    smoke_examples.each do |name|
      Dir.mktmpdir("milk-tea-raylib-runtime") do |dir|
        source_path = File.expand_path("../examples/raylib/core/#{name}.mt", __dir__)
        source_dir = File.dirname(source_path)
        binary_path = File.join(dir, name)
        screenshot_name = "#{name}.bmp"
        screenshot_path = File.join(source_dir, screenshot_name)

        MilkTea::Build.build(source_path, output_path: binary_path, cc: compiler)

        File.delete(screenshot_path) if File.exist?(screenshot_path)

        stdout, stderr, status = Open3.capture3(
          {
            "MILK_TEA_RAYLIB_SMOKE_FRAMES" => "3",
            "MILK_TEA_RAYLIB_SMOKE_SCREENSHOT" => screenshot_name,
          },
          *headless_runner,
          binary_path,
          chdir: source_dir,
        )

        assert_equal 0, status.exitstatus, "#{name} exited with #{status.exitstatus}: #{stderr}\n#{stdout}"
        assert File.exist?(screenshot_path), "#{name} did not produce a screenshot"

        stats = bmp_stats(screenshot_path)
        assert_operator stats[:white_ratio], :<, 0.99, "#{name} screenshot is effectively all white"
        assert_operator stats[:black_ratio], :<, 0.99, "#{name} screenshot is effectively all black"
        assert_operator stats[:unique_colors], :>, 4, "#{name} screenshot did not render enough visible variation"

        File.delete(screenshot_path)
      end
    end
  end

  private

  def smoke_examples
    %w[
      core_custom_frame_control
      core_input_gestures_testbed
      core_storage_values
    ]
  end

  def compiler_available?(compiler)
    system("sh", "-c", "command -v \"$0\" >/dev/null 2>&1", compiler)
  end

  def find_headless_runner
    return ["xvfb-run", "-a"] if system("sh", "-c", "command -v xvfb-run >/dev/null 2>&1")

    nil
  end

  def bmp_stats(path)
    data = File.binread(path)
    raise "not a BMP file: #{path}" unless data.start_with?("BM")

    pixel_offset = data.byteslice(10, 4).unpack1("V")
    width = data.byteslice(18, 4).unpack1("V")
    height = data.byteslice(22, 4).unpack1("l<").abs
    bits_per_pixel = data.byteslice(28, 2).unpack1("v")
    compression = data.byteslice(30, 4).unpack1("V")

    raise "unsupported BMP depth #{bits_per_pixel}: #{path}" unless [24, 32].include?(bits_per_pixel)
    raise "compressed BMP not supported: #{path}" unless compression == 0 || (compression == 3 && bits_per_pixel == 32)

    bytes_per_pixel = bits_per_pixel / 8
    row_size = ((bits_per_pixel * width + 31) / 32) * 4
    total_pixels = width * height
    white_pixels = 0
    black_pixels = 0
    unique_colors = {}

    height.times do |row|
      row_offset = pixel_offset + row_size * row

      width.times do |column|
        pixel_offset_in_row = row_offset + column * bytes_per_pixel
        b, g, r = data.byteslice(pixel_offset_in_row, 3).bytes

        white_pixels += 1 if r >= 248 && g >= 248 && b >= 248
        black_pixels += 1 if r <= 7 && g <= 7 && b <= 7
        unique_colors[[r, g, b]] = true if unique_colors.length < 512
      end
    end

    {
      white_ratio: white_pixels.to_f / total_pixels,
      black_ratio: black_pixels.to_f / total_pixels,
      unique_colors: unique_colors.length,
    }
  end
end
