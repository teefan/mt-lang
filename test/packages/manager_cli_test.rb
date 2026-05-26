# frozen_string_literal: true

require "stringio"
require "tmpdir"
require_relative "../test_helper"

class MilkTeaPackageManagerCliTest < Minitest::Test
  LockCheckResult = Struct.new(:lock_path, :state) do
    def current?
      state == :current
    end

    def missing?
      state == :missing
    end
  end

  LockWriteResult = Struct.new(:lock_path)
  FakeFetchResult = Struct.new(:package_name, :status, :path)
  FakePublishResult = Struct.new(:package_name, :version, :path)
  FakeDependency = Struct.new(:name)
  FakeManifest = Struct.new(:manifest_path, :root_dir, :dependencies)

  FakeEditor = Struct.new(:manifest_path) do
    attr_reader :added_dependency, :removed_dependency

    def add_dependency(name, spec)
      @added_dependency = [name, spec]
    end

    def remove_dependency(name)
      @removed_dependency = name
    end
  end

  def test_start_requires_subcommand
    out = StringIO.new
    err = StringIO.new

    status = cli([], out:, err:).start

    assert_equal 1, status
    assert_equal "", out.string
    assert_match(/missing deps subcommand/, err.string)
    assert_match(/deps help/, err.string)
  end

  def test_lock_check_uses_current_directory_package_and_reports_up_to_date
    Dir.mktmpdir("milk-tea-manager-cli-lock") do |dir|
      File.write(File.join(dir, "package.toml"), "[package]\nname = \"demo\"\n")
      out = StringIO.new
      err = StringIO.new
      resolver = Object.new
      observed = {}
      lock_check = lambda do |path, source_resolver:|
        observed[:path] = path
        observed[:source_resolver] = source_resolver
        LockCheckResult.new(File.join(dir, "package.lock"), :current)
      end

      with_singleton_method_override(MilkTea::PackageLock, :check, lock_check) do
        status = Dir.chdir(dir) { cli(["lock", "--check"], out:, err:, services: services(source_resolver: resolver)).start }

        assert_equal 0, status
      end

      assert_equal dir, observed[:path]
      assert_same resolver, observed[:source_resolver]
      assert_equal "", err.string
      assert_match(/up to date .*package\.lock/, out.string)
    end
  end

  def test_publish_defaults_to_local_target
    Dir.mktmpdir("milk-tea-manager-cli-publish") do |dir|
      File.write(File.join(dir, "package.toml"), "[package]\nname = \"demo\"\n")
      out = StringIO.new
      err = StringIO.new
      observed = {}
      registry_store = Object.new
      registry_store.define_singleton_method(:publish) do |path, target:|
        observed[:path] = path
        observed[:target] = target
        FakePublishResult.new("demo", "1.2.3", File.join(dir, "demo-1.2.3.pkg"))
      end

      status = Dir.chdir(dir) { cli(["publish"], out:, err:, services: services(registry_store:)).start }

      assert_equal 0, status
      assert_equal dir, observed[:path]
      assert_equal :local, observed[:target]
      assert_equal "", err.string
      assert_match(/published demo@1\.2\.3 -> .*demo-1\.2\.3\.pkg/, out.string)
    end
  end

  def test_start_rejects_unknown_subcommand
    out = StringIO.new
    err = StringIO.new

    status = cli(["wat"], out:, err:).start

    assert_equal 1, status
    assert_equal "", out.string
    assert_match(/unknown deps subcommand wat/, err.string)
    assert_match(/deps help/, err.string)
  end

  def test_tree_command_renders_dependency_tree_for_explicit_path
    out = StringIO.new
    err = StringIO.new
    resolver = Object.new
    observed = {}
    renderer = lambda do |path, source_resolver:|
      observed[:path] = path
      observed[:source_resolver] = source_resolver
      "demo-tree"
    end

    with_singleton_method_override(MilkTea::PackageGraph, :render_tree, renderer) do
      status = cli(["tree", "/tmp/demo"], out:, err:, services: services(source_resolver: resolver)).start

      assert_equal 0, status
    end

    assert_equal "/tmp/demo", observed[:path]
    assert_same resolver, observed[:source_resolver]
    assert_equal "demo-tree\n", out.string
    assert_equal "", err.string
  end

  def test_tree_command_requires_package_path_when_current_directory_is_not_package
    Dir.mktmpdir("milk-tea-manager-cli-tree-missing") do |dir|
      out = StringIO.new
      err = StringIO.new

      status = Dir.chdir(dir) { cli(["tree"], out:, err:).start }

      assert_equal 1, status
      assert_equal "", out.string
      assert_match(/missing package path/, err.string)
      assert_match(/deps help/, err.string)
    end
  end

  def test_lock_check_reports_missing_lockfile
    Dir.mktmpdir("milk-tea-manager-cli-lock-missing") do |dir|
      File.write(File.join(dir, "package.toml"), "[package]\nname = \"demo\"\n")
      out = StringIO.new
      err = StringIO.new
      resolver = Object.new

      with_singleton_method_override(MilkTea::PackageLock, :check, lambda { |_path, source_resolver:| LockCheckResult.new(File.join(dir, "package.lock"), :missing) }) do
        status = Dir.chdir(dir) { cli(["lock", "--check"], out:, err:, services: services(source_resolver: resolver)).start }

        assert_equal 1, status
      end

      assert_equal "", err.string
      assert_match(/missing .*package\.lock/, out.string)
    end
  end

  def test_lock_check_reports_out_of_date_lockfile
    Dir.mktmpdir("milk-tea-manager-cli-lock-stale") do |dir|
      File.write(File.join(dir, "package.toml"), "[package]\nname = \"demo\"\n")
      out = StringIO.new
      err = StringIO.new
      resolver = Object.new

      with_singleton_method_override(MilkTea::PackageLock, :check, lambda { |_path, source_resolver:| LockCheckResult.new(File.join(dir, "package.lock"), :stale) }) do
        status = Dir.chdir(dir) { cli(["lock", "--check"], out:, err:, services: services(source_resolver: resolver)).start }

        assert_equal 1, status
      end

      assert_equal "", err.string
      assert_match(/out of date .*package\.lock/, out.string)
    end
  end

  def test_lock_write_reports_written_path
    Dir.mktmpdir("milk-tea-manager-cli-lock-write") do |dir|
      File.write(File.join(dir, "package.toml"), "[package]\nname = \"demo\"\n")
      out = StringIO.new
      err = StringIO.new
      resolver = Object.new
      observed = {}
      writer = lambda do |path, source_resolver:|
        observed[:path] = path
        observed[:source_resolver] = source_resolver
        LockWriteResult.new(File.join(dir, "package.lock"))
      end

      with_singleton_method_override(MilkTea::PackageLock, :write, writer) do
        status = Dir.chdir(dir) { cli(["lock"], out:, err:, services: services(source_resolver: resolver)).start }

        assert_equal 0, status
      end

      assert_equal dir, observed[:path]
      assert_same resolver, observed[:source_resolver]
      assert_equal "", err.string
      assert_match(/wrote .*package\.lock/, out.string)
    end
  end

  def test_publish_supports_upstream_target
    Dir.mktmpdir("milk-tea-manager-cli-publish-upstream") do |dir|
      File.write(File.join(dir, "package.toml"), "[package]\nname = \"demo\"\n")
      out = StringIO.new
      err = StringIO.new
      observed = {}
      registry_store = Object.new
      registry_store.define_singleton_method(:publish) do |path, target:|
        observed[:path] = path
        observed[:target] = target
        FakePublishResult.new("demo", "1.2.3", File.join(dir, "demo-1.2.3.pkg"))
      end

      status = Dir.chdir(dir) { cli(["publish", "--upstream"], out:, err:, services: services(registry_store:)).start }

      assert_equal 0, status
      assert_equal dir, observed[:path]
      assert_equal :upstream, observed[:target]
      assert_equal "", err.string
    end
  end

  def test_fetch_reports_kept_and_materialized_sources
    Dir.mktmpdir("milk-tea-manager-cli-fetch") do |dir|
      File.write(File.join(dir, "package.toml"), "[package]\nname = \"demo\"\n")
      out = StringIO.new
      err = StringIO.new
      observed = {}
      fetcher = Object.new
      fetcher.define_singleton_method(:fetch_locked_sources) do |path|
        observed[:path] = path
        [
          FakeFetchResult.new("demo.ui", :present, "/tmp/ui"),
          FakeFetchResult.new("demo.audio", :materialized, "/tmp/audio"),
        ]
      end

      status = Dir.chdir(dir) { cli(["fetch"], out:, err:, services: services(source_fetcher: fetcher)).start }

      assert_equal 0, status
      assert_equal dir, observed[:path]
      assert_equal "", err.string
      assert_match(/kept demo\.ui -> \/tmp\/ui/, out.string)
      assert_match(/materialized demo\.audio -> \/tmp\/audio/, out.string)
    end
  end

  def test_deps_target_path_requires_path_when_not_in_package_directory
    Dir.mktmpdir("milk-tea-manager-cli-target-path") do |dir|
      error = Dir.chdir(dir) do
        assert_raises(MilkTea::PackageManifestEditorError) do
          cli([]).send(:deps_target_path_from_argv!)
        end
      end

      assert_match(/missing package path/, error.message)
    end
  end

  def test_parse_dependency_argument_strips_name_and_requirement
    name, requirement = cli([]).send(:parse_dependency_argument, " demo.pkg @ 1.2.3 ")

    assert_equal "demo.pkg", name
    assert_equal "1.2.3", requirement
  end

  def test_parse_dependency_argument_rejects_empty_name_and_requirement
    name_error = assert_raises(MilkTea::PackageManifestEditorError) do
      cli([]).send(:parse_dependency_argument, "   ")
    end
    requirement_error = assert_raises(MilkTea::PackageManifestEditorError) do
      cli([]).send(:parse_dependency_argument, "demo@   ")
    end

    assert_match(/dependency name cannot be empty/, name_error.message)
    assert_match(/dependency version requirement cannot be empty/, requirement_error.message)
  end

  def test_parse_update_dependency_names_rejects_unknown_option
    out = StringIO.new
    err = StringIO.new

    names = cli(["--wat"], out:, err:).send(:parse_update_dependency_names)

    assert_nil names
    assert_equal "", out.string
    assert_match(/unknown deps option --wat/, err.string)
    assert_match(/deps help/, err.string)
  end

  def test_parse_dependency_spec_for_add_builds_git_spec_with_subdir
    spec = cli(["--git", "https://example.com/demo.git", "--rev", "abc123", "--subdir", "pkg"]).send(:parse_dependency_spec_for_add, "demo", nil)

    assert_equal({ "git" => "https://example.com/demo.git", "rev" => "abc123", "subdir" => "pkg" }, spec)
  end

  def test_parse_dependency_spec_for_add_builds_path_spec_with_normalized_version
    spec = cli(["--path", "vendor/demo", "--version", "1.2.3"]).send(:parse_dependency_spec_for_add, "demo", nil)

    assert_equal({ "path" => "vendor/demo", "version" => "1.2.3" }, spec)
  end

  def test_parse_dependency_spec_for_add_requires_registry_version_when_no_source_override
    error = assert_raises(MilkTea::PackageManifestEditorError) do
      cli([]).send(:parse_dependency_spec_for_add, "demo", nil)
    end

    assert_match(/missing a version requirement/, error.message)
  end

  def test_parse_dependency_spec_for_add_rejects_git_without_rev_and_git_with_version
    missing_rev_error = assert_raises(MilkTea::PackageManifestEditorError) do
      cli(["--git", "https://example.com/demo.git"]).send(:parse_dependency_spec_for_add, "demo", nil)
    end
    git_version_error = assert_raises(MilkTea::PackageManifestEditorError) do
      cli(["--git", "https://example.com/demo.git", "--rev", "abc123"]).send(:parse_dependency_spec_for_add, "demo", "1.2.3")
    end

    assert_match(/missing --rev/, missing_rev_error.message)
    assert_match(/cannot combine git resolution with a version requirement/, git_version_error.message)
  end

  def test_selective_update_source_resolver_returns_resolver_when_dependency_list_is_empty
    resolver = Object.new

    selected = cli([], services: services(source_resolver: resolver)).send(:selective_update_source_resolver, "/tmp/demo", [])

    assert_same resolver, selected
  end

  def test_selective_update_source_resolver_rejects_unknown_dependency_name
    resolver = Object.new
    resolver.define_singleton_method(:with_resolved_registry_versions) { |_versions| self }
    manifest = FakeManifest.new("/tmp/demo/package.toml", "/tmp/demo", [FakeDependency.new("known.pkg")])
    locked_packages = [locked_package(package_name: "root", instance_id: "root", identity: MilkTea::PackageSourceResolver::PathIdentity.new("/tmp/demo"), dependency_ids: [])]

    with_singleton_method_override(MilkTea::PackageManifest, :load, lambda { |_path| manifest }) do
      with_singleton_method_override(MilkTea::PackageLock, :locked_packages, lambda { |_path| locked_packages }) do
        with_singleton_method_override(MilkTea::PackageLock, :check, lambda { |_path, source_resolver:| LockCheckResult.new("/tmp/demo/package.lock", :current) }) do
          error = assert_raises(MilkTea::PackageManifestEditorError) do
            cli([], services: services(source_resolver: resolver)).send(:selective_update_source_resolver, "/tmp/demo", ["missing.pkg"])
          end

          assert_match(/cannot selectively update unknown package missing\.pkg/, error.message)
        end
      end
    end
  end

  def test_with_manifest_edit_restores_original_manifest_on_failure
    Dir.mktmpdir("milk-tea-manager-cli-rollback") do |dir|
      manifest_path = File.join(dir, "package.toml")
      File.write(manifest_path, "original\n")
      editor = FakeEditor.new(manifest_path)

      error = assert_raises(RuntimeError) do
        cli([]).send(:with_manifest_edit, editor) do
          File.write(manifest_path, "changed\n")
          raise "boom"
        end
      end

      assert_equal "boom", error.message
      assert_equal "original\n", File.read(manifest_path)
    end
  end

  def test_with_manifest_edit_restores_original_lockfile_when_post_write_step_fails
    Dir.mktmpdir("milk-tea-manager-cli-lock-rollback") do |dir|
      manifest_path = File.join(dir, "package.toml")
      lock_path = File.join(dir, "package.lock")
      editor = FakeEditor.new(manifest_path)
      out = StringIO.new
      err = StringIO.new
      fetcher = Object.new
      fetcher.define_singleton_method(:fetch_locked_sources) do |_path|
        raise "fetch failed"
      end

      File.write(manifest_path, "original\n")
      File.write(lock_path, "old lock\n")

      with_singleton_method_override(MilkTea::PackageLock, :write, lambda do |_path, source_resolver:|
        File.write(lock_path, "new lock\n")
        LockWriteResult.new(lock_path)
      end) do
        error = assert_raises(RuntimeError) do
          cli([], out:, err:, services: services(source_fetcher: fetcher)).send(:with_manifest_edit, editor) do
            File.write(manifest_path, "changed\n")
          end
        end

        assert_equal "fetch failed", error.message
      end

      assert_equal "", err.string
      assert_equal "", out.string
      assert_equal "original\n", File.read(manifest_path)
      assert_equal "old lock\n", File.read(lock_path)
    end
  end

  def test_with_manifest_edit_removes_new_lockfile_when_post_write_step_fails
    Dir.mktmpdir("milk-tea-manager-cli-new-lock-rollback") do |dir|
      manifest_path = File.join(dir, "package.toml")
      lock_path = File.join(dir, "package.lock")
      editor = FakeEditor.new(manifest_path)
      out = StringIO.new
      err = StringIO.new
      fetcher = Object.new
      fetcher.define_singleton_method(:fetch_locked_sources) do |_path|
        raise "fetch failed"
      end

      File.write(manifest_path, "original\n")

      with_singleton_method_override(MilkTea::PackageLock, :write, lambda do |_path, source_resolver:|
        File.write(lock_path, "new lock\n")
        LockWriteResult.new(lock_path)
      end) do
        error = assert_raises(RuntimeError) do
          cli([], out:, err:, services: services(source_fetcher: fetcher)).send(:with_manifest_edit, editor) do
            File.write(manifest_path, "changed\n")
          end
        end

        assert_equal "fetch failed", error.message
      end

      assert_equal "", err.string
      assert_equal "", out.string
      assert_equal "original\n", File.read(manifest_path)
      refute File.exist?(lock_path)
    end
  end

  def test_emit_dependency_fetch_results_reports_missing_cache_backed_sources
    out = StringIO.new
    err = StringIO.new
    manifest = FakeManifest.new("/tmp/demo/package.toml", "/tmp/demo", [])

    with_singleton_method_override(MilkTea::PackageManifest, :load, lambda { |_path| manifest }) do
      cli([], out:, err:).send(:emit_dependency_fetch_results, [], "/tmp/demo")
    end

    assert_equal "", err.string
    assert_match(/no cache-backed sources in \/tmp\/demo\/package\.lock/, out.string)
  end

  def test_selective_update_package_instance_ids_includes_transitive_dependencies
    locked_packages = [
      locked_package(package_name: "app", instance_id: "app", identity: MilkTea::PackageSourceResolver::PathIdentity.new("/tmp/app"), dependency_ids: ["feature", "keep"]),
      locked_package(package_name: "feature", instance_id: "feature", identity: registry_identity("feature", "1.0.0"), dependency_ids: ["leaf"]),
      locked_package(package_name: "leaf", instance_id: "leaf", identity: registry_identity("leaf", "2.0.0"), dependency_ids: []),
      locked_package(package_name: "keep", instance_id: "keep", identity: registry_identity("keep", "3.0.0"), dependency_ids: []),
    ]

    selected = cli([]).send(:selective_update_package_instance_ids, locked_packages, ["feature"])

    assert_equal Set["feature", "leaf"], selected
  end

  def test_locked_registry_dependency_versions_skips_unlocked_dependencies
    locked_packages = [
      locked_package(package_name: "app", instance_id: "app", identity: MilkTea::PackageSourceResolver::PathIdentity.new("/tmp/app"), dependency_ids: ["feature", "keep"]),
      locked_package(package_name: "feature", instance_id: "feature", identity: registry_identity("feature", "1.0.0"), dependency_ids: []),
      locked_package(package_name: "keep", instance_id: "keep", identity: registry_identity("keep", "2.0.0"), dependency_ids: []),
    ]

    versions = cli([]).send(:locked_registry_dependency_versions, locked_packages, unlocked_instance_ids: Set["feature"])

    assert_equal({
      MilkTea::PackageSourceResolver.registry_dependency_key(parent_source_key: "path:/tmp/app", dependency_name: "keep") => "2.0.0",
    }, versions)
  end

  def test_parse_dependency_spec_for_add_rejects_conflicting_path_and_git_options
    error = assert_raises(MilkTea::PackageManifestEditorError) do
      cli(["--path", "vendor/demo", "--git", "https://example.com/demo.git", "--rev", "abc123"]).send(:parse_dependency_spec_for_add, "demo", nil)
    end

    assert_match(/cannot use both --path and --git/, error.message)
  end

  private

  def cli(argv, out: StringIO.new, err: StringIO.new, services: services)
    MilkTea::PackageManagerCLI.new(argv, out:, err:, help_printer: ->(io) { io.puts("deps help") }, services:)
  end

  def services(source_resolver: Object.new, source_fetcher: Object.new.tap { |fetcher| fetcher.define_singleton_method(:fetch_locked_sources) { |_path| [] } }, registry_store: Object.new)
    Object.new.tap do |object|
      object.define_singleton_method(:source_resolver) { |_mode| source_resolver }
      object.define_singleton_method(:source_fetcher) { source_fetcher }
      object.define_singleton_method(:registry_store) { registry_store }
    end
  end

  def locked_package(package_name:, instance_id:, identity:, dependency_ids:)
    MilkTea::PackageLock::LockedPackage.new(
      package_name,
      instance_id,
      identity,
      "/tmp/#{instance_id}/package.toml",
      [],
      dependency_ids,
    )
  end

  def registry_identity(package_name, version)
    MilkTea::PackageSourceResolver::RegistryIdentity.new(package_name:, version:)
  end
end
