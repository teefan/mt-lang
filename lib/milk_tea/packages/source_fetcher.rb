# frozen_string_literal: true

require "fileutils"
require "open3"

module MilkTea
  class PackageSourceFetcherError < StandardError; end

  class PackageSourceFetcher
    Result = Data.define(:package_name, :identity, :status, :path)

    def initialize(source_cache: PackageSourceCache.new, source_resolver: PackageSourceResolver.new(source_cache: source_cache), registry_store: PackageRegistryStore.new)
      @source_cache = source_cache
      @source_resolver = source_resolver
      @registry_store = registry_store
    end

    def fetch_locked_sources(path)
      locked_packages = PackageLock.locked_packages(path, source_resolver: @source_resolver)
      locked_packages.select { |package| package.identity.cacheable? }.map do |package|
        fetch_locked_package(package)
      end
    rescue PackageLockError => e
      raise PackageSourceFetcherError, e.message
    end

    def materialize_identity(package_name:, identity:)
      expected_manifest_path = @source_cache.manifest_path_for(identity)

      case identity
      when PackageSourceResolver::RegistryIdentity
        fetch_registry_package(package_name, identity, expected_manifest_path)
      when PackageSourceResolver::GitIdentity
        fetch_git_package(package_name, identity, expected_manifest_path)
      else
        raise PackageSourceFetcherError,
              "package source kind #{identity.kind.inspect} is not fetchable"
      end
    rescue PackageSourceCacheError => e
      raise PackageSourceFetcherError, e.message
    rescue PackageRegistryStoreError => e
      raise PackageSourceFetcherError, e.message
    end

    private

    def fetch_locked_package(package)
      identity = package.identity
      expected_manifest_path = @source_cache.manifest_path_for(identity)
      if package.manifest_path != expected_manifest_path
        raise PackageSourceFetcherError,
              "package.lock manifest_path for #{package.package_name} does not match the expected cache path #{expected_manifest_path}"
      end

      materialize_identity(package_name: package.package_name, identity:)
    end

    def fetch_git_package(package_name, identity, expected_manifest_path)
      checkout_root = @source_cache.path_for(identity)
      materialized_root = @source_cache.materialized_root_for(identity)

      if git_checkout_current?(checkout_root, identity.revision) && File.file?(expected_manifest_path)
        return Result.new(package_name:, identity:, status: :present, path: materialized_root)
      end

      FileUtils.rm_rf(checkout_root) if File.exist?(checkout_root)
      FileUtils.mkdir_p(File.dirname(checkout_root))

      run_git!("clone", identity.url, checkout_root)
      run_git!("-C", checkout_root, "checkout", "--detach", identity.revision)

      unless File.file?(expected_manifest_path)
        raise PackageSourceFetcherError,
              "git source for #{package_name} is missing package.toml at #{expected_manifest_path}"
      end

      Result.new(package_name:, identity:, status: :materialized, path: materialized_root)
    end

    def fetch_registry_package(package_name, identity, expected_manifest_path)
      cache_root = @source_cache.path_for(identity)
      materialized_root = @source_cache.materialized_root_for(identity)

      if File.file?(expected_manifest_path)
        return Result.new(package_name:, identity:, status: :present, path: materialized_root)
      end

      published_root = @registry_store.published_root_for(identity, sync: true)

      FileUtils.rm_rf(cache_root) if File.exist?(cache_root)
      FileUtils.mkdir_p(File.dirname(cache_root))
      FileUtils.copy_entry(published_root, cache_root)

      unless File.file?(expected_manifest_path)
        raise PackageSourceFetcherError,
              "registry source for #{package_name} is missing package.toml at #{expected_manifest_path}"
      end

      Result.new(package_name:, identity:, status: :materialized, path: materialized_root)
    end

    def git_checkout_current?(checkout_root, revision)
      return false unless File.directory?(checkout_root)

      stdout, _stderr, status = Open3.capture3("git", "-C", checkout_root, "rev-parse", "HEAD")
      return false unless status.success?

      stdout.strip == revision
    rescue Errno::ENOENT => e
      raise PackageSourceFetcherError, "git not found while materializing package sources: #{e.message}"
    end

    def run_git!(*args)
      stdout, stderr, status = Open3.capture3("git", *args)
      return if status.success?

      details = [stdout, stderr].reject(&:empty?).join
      raise PackageSourceFetcherError,
            details.empty? ? "failed to materialize git package source" : "failed to materialize git package source:\n#{details}"
    rescue Errno::ENOENT => e
      raise PackageSourceFetcherError, "git not found while materializing package sources: #{e.message}"
    end
  end
end
