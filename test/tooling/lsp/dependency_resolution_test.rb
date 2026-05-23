# frozen_string_literal: true

require_relative "../../test_helper"

class LSPDependencyResolutionTest < Minitest::Test
  FakeLockResult = Struct.new(:current_value, :missing_value, :lock_path_value, keyword_init: true) do
    def current?
      current_value
    end

    def missing?
      missing_value
    end

    def lock_path
      lock_path_value
    end
  end

  def test_normalize_mode_maps_unknown_values_to_auto
    assert_equal :auto, MilkTea::LSP::DependencyResolution.normalize_mode("unknown")
    assert_equal :locked, MilkTea::LSP::DependencyResolution.normalize_mode("  LOCKED ")
  end

  def test_resolve_returns_unlocked_when_manifest_path_missing
    resolved = MilkTea::LSP::DependencyResolution.resolve("/tmp/does-not-exist-package.toml", mode: :auto)

    assert_equal :auto, resolved.mode
    assert_equal false, resolved.locked
    assert_nil resolved.error_message
    assert resolved.ok?
  end

  def test_resolve_live_and_locked_modes_without_lock_lookup
    Dir.mktmpdir("lsp-dep-resolve-direct") do |dir|
      manifest = File.join(dir, "package.toml")
      File.write(manifest, "[package]\nname=\"demo\"\nversion=\"0.1.0\"\n")

      live = MilkTea::LSP::DependencyResolution.resolve(manifest, mode: :live)
      locked = MilkTea::LSP::DependencyResolution.resolve(manifest, mode: :locked)

      assert_equal :live, live.mode
      assert_equal false, live.locked
      assert_nil live.error_message

      assert_equal :locked, locked.mode
      assert_equal true, locked.locked
      assert_nil locked.error_message
    end
  end

  def test_resolve_auto_uses_package_lock_current_flag
    Dir.mktmpdir("lsp-dep-resolve-auto") do |dir|
      manifest = File.join(dir, "package.toml")
      File.write(manifest, "[package]\nname=\"demo\"\nversion=\"0.1.0\"\n")
      fake = FakeLockResult.new(current_value: true, missing_value: false, lock_path_value: File.join(dir, "package.lock"))

      with_singleton_method_override(MilkTea::PackageLock, :check, ->(_path) { fake }) do
        resolved = MilkTea::LSP::DependencyResolution.resolve(manifest, mode: :auto)
        assert_equal :auto, resolved.mode
        assert_equal true, resolved.locked
        assert_nil resolved.error_message
      end
    end
  end

  def test_resolve_frozen_reports_missing_lock
    Dir.mktmpdir("lsp-dep-resolve-frozen-missing") do |dir|
      manifest = File.join(dir, "package.toml")
      File.write(manifest, "[package]\nname=\"demo\"\nversion=\"0.1.0\"\n")
      lock_path = File.join(dir, "package.lock")
      fake = FakeLockResult.new(current_value: false, missing_value: true, lock_path_value: lock_path)

      with_singleton_method_override(MilkTea::PackageLock, :check, ->(_path) { fake }) do
        resolved = MilkTea::LSP::DependencyResolution.resolve(manifest, mode: :frozen)
        assert_equal :frozen, resolved.mode
        assert_equal true, resolved.locked
        assert_match(/package\.lock is missing:/, resolved.error_message)
      end
    end
  end

  def test_resolve_frozen_reports_out_of_date_lock
    Dir.mktmpdir("lsp-dep-resolve-frozen-stale") do |dir|
      manifest = File.join(dir, "package.toml")
      File.write(manifest, "[package]\nname=\"demo\"\nversion=\"0.1.0\"\n")
      lock_path = File.join(dir, "package.lock")
      fake = FakeLockResult.new(current_value: false, missing_value: false, lock_path_value: lock_path)

      with_singleton_method_override(MilkTea::PackageLock, :check, ->(_path) { fake }) do
        resolved = MilkTea::LSP::DependencyResolution.resolve(manifest, mode: :frozen)
        assert_equal :frozen, resolved.mode
        assert_equal true, resolved.locked
        assert_match(/package\.lock is out of date:/, resolved.error_message)
      end
    end
  end

  def test_resolve_handles_package_manifest_error_as_non_fatal
    Dir.mktmpdir("lsp-dep-resolve-manifest-error") do |dir|
      manifest = File.join(dir, "package.toml")
      File.write(manifest, "[package]\nname=\"demo\"\nversion=\"0.1.0\"\n")

      with_singleton_method_override(MilkTea::PackageLock, :check, ->(_path) { raise MilkTea::PackageManifestError, "invalid" }) do
        resolved = MilkTea::LSP::DependencyResolution.resolve(manifest, mode: :frozen)
        assert_equal :frozen, resolved.mode
        assert_equal false, resolved.locked
        assert_nil resolved.error_message
      end
    end
  end

  def test_resolve_handles_package_lock_error_by_mode
    Dir.mktmpdir("lsp-dep-resolve-lock-error") do |dir|
      manifest = File.join(dir, "package.toml")
      File.write(manifest, "[package]\nname=\"demo\"\nversion=\"0.1.0\"\n")

      with_singleton_method_override(MilkTea::PackageLock, :check, lambda { |_path|
        raise MilkTea::PackageLockError, "lock parse failed"
      }) do
        auto = MilkTea::LSP::DependencyResolution.resolve(manifest, mode: :auto)
        frozen = MilkTea::LSP::DependencyResolution.resolve(manifest, mode: :frozen)

        assert_equal false, auto.locked
        assert_nil auto.error_message

        assert_equal true, frozen.locked
        assert_equal "lock parse failed", frozen.error_message
      end
    end
  end
end
