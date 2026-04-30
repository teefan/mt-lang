# frozen_string_literal: true

require "fileutils"
require "open3"
require "pathname"
require "tmpdir"
require_relative "../test_helper"
require_relative "../../lib/milk_tea/bindings"

class MilkTeaUpstreamSourcesTest < Minitest::Test
  def test_source_bootstrap_clones_missing_checkout_at_pinned_revision
    skip "git not available" unless executable_available?("git")

    Dir.mktmpdir("milk-tea-upstream-source") do |dir|
      origin = File.join(dir, "origin")
      checkout_root = Pathname.new(File.join(dir, "checkout"))

      FileUtils.mkdir_p(origin)
      run_git!(dir: origin, args: ["init", "--initial-branch=main"])
      FileUtils.mkdir_p(File.join(origin, "include", "SDL3"))
      File.write(File.join(origin, "include", "SDL3", "SDL.h"), "#define SDL_MAJOR_VERSION 3\n")
      run_git!(dir: origin, args: ["add", "."])
      run_git!(dir: origin, args: ["commit", "-m", "initial"])

      revision = capture_git(dir: origin, args: ["rev-parse", "HEAD"])
      source = MilkTea::UpstreamSources::Source.new(
        name: "sdl3",
        checkout_root:,
        repository_url: origin,
        revision:,
        sentinel_paths: ["include/SDL3/SDL.h"],
      )

      result = source.bootstrap!

      assert_equal :bootstrapped, result.status
      assert_equal checkout_root.to_s, result.path
      assert File.exist?(checkout_root.join("include/SDL3/SDL.h"))
      assert_equal revision, capture_git(dir: checkout_root.to_s, args: ["rev-parse", "HEAD"])
    end
  end

  def test_source_bootstrap_keeps_existing_complete_plain_snapshot
    Dir.mktmpdir("milk-tea-upstream-snapshot") do |dir|
      checkout_root = Pathname.new(File.join(dir, "raylib-upstream"))
      FileUtils.mkdir_p(checkout_root.join("src"))
      File.write(checkout_root.join("src/raylib.h"), "#define RAYLIB_VERSION \"6.0\"\n")

      source = MilkTea::UpstreamSources::Source.new(
        name: "raylib",
        checkout_root:,
        repository_url: "https://example.invalid/raylib.git",
        revision: "deadbeef",
        sentinel_paths: ["src/raylib.h"],
      )

      result = source.bootstrap!

      assert_equal :present, result.status
      assert_equal checkout_root.to_s, result.path
    end
  end

  private

  def capture_git(dir:, args:)
    stdout, stderr, status = Open3.capture3(git_env, "git", "-C", dir, *args)
    assert status.success?, stderr

    stdout.strip
  end

  def run_git!(dir:, args:)
    stdout, stderr, status = Open3.capture3(git_env, "git", "-C", dir, *args)
    assert status.success?, [stdout, stderr].reject(&:empty?).join
  end

  def git_env
    {
      "GIT_AUTHOR_NAME" => "Milk Tea Tests",
      "GIT_AUTHOR_EMAIL" => "tests@example.com",
      "GIT_COMMITTER_NAME" => "Milk Tea Tests",
      "GIT_COMMITTER_EMAIL" => "tests@example.com",
    }
  end

  def executable_available?(program)
    return File.executable?(program) if program.include?(File::SEPARATOR)

    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |entry|
      candidate = File.join(entry, program)
      File.file?(candidate) && File.executable?(candidate)
    end
  end
end
