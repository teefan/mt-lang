# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaPackageServicesTest < Minitest::Test
  def test_source_resolver_caches_by_mode
    services = MilkTea::PackageServices.new

    reject_resolver = services.source_resolver(:reject)
    cache_resolver = services.source_resolver(:cache)
    materialize_resolver = services.source_resolver(:materialize)

    assert_instance_of MilkTea::PackageSourceResolver, reject_resolver
    assert_instance_of MilkTea::PackageSourceResolver, cache_resolver
    assert_instance_of MilkTea::PackageSourceResolver, materialize_resolver
    refute_same reject_resolver, cache_resolver
    refute_same cache_resolver, materialize_resolver

    second_reject = services.source_resolver(:reject)
    assert_same reject_resolver, second_reject
  end

  def test_source_resolver_reject_mode_does_not_support_dependency_solving
    services = MilkTea::PackageServices.new

    refute services.source_resolver(:reject).supports_dependency_solving?
  end

  def test_source_resolver_cache_mode_supports_dependency_solving
    services = MilkTea::PackageServices.new

    assert services.source_resolver(:cache).supports_dependency_solving?
  end

  def test_source_resolver_materialize_mode_supports_dependency_solving
    services = MilkTea::PackageServices.new

    assert services.source_resolver(:materialize).supports_dependency_solving?
  end

  def test_source_fetcher_is_lazily_created_and_cached
    services = MilkTea::PackageServices.new

    fetcher = services.source_fetcher
    assert_instance_of MilkTea::PackageSourceFetcher, fetcher

    second_fetcher = services.source_fetcher
    assert_same fetcher, second_fetcher
  end

  def test_initializer_accepts_custom_cache_and_registry
    cache = MilkTea::PackageSourceCache.new(root: "/tmp/custom-cache")
    registry = MilkTea::PackageRegistryStore.new(root: "/tmp/custom-registry")

    services = MilkTea::PackageServices.new(source_cache: cache, registry_store: registry)

    assert_same cache, services.source_cache
    assert_same registry, services.registry_store
  end

  def test_source_resolver_rejects_unknown_mode
    services = MilkTea::PackageServices.new

    error = assert_raises(ArgumentError) do
      services.source_resolver(:bogus)
    end

    assert_match(/unknown/, error.message)
  end
end
