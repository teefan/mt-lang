# frozen_string_literal: true

module MilkTea
  class PackageServices
    attr_reader :source_cache, :registry_store

    def initialize(source_cache: PackageSourceCache.new, registry_store: PackageRegistryStore.new)
      @source_cache = source_cache
      @registry_store = registry_store
      @source_resolvers = {}
    end

    def source_fetcher
      @source_fetcher ||= PackageSourceFetcher.new(
        source_cache: source_cache,
        source_resolver: source_resolver(:reject),
        registry_store: registry_store,
      )
    end

    def source_resolver(mode)
      @source_resolvers[mode] ||= case mode
                                  when :reject
                                    PackageSourceResolver.new(source_cache: source_cache)
                                  when :cache
                                    PackageSourceResolver.new(
                                      source_cache: source_cache,
                                      remote_resolution: :cache,
                                    )
                                  when :materialize
                                    PackageSourceResolver.new(
                                      source_cache: source_cache,
                                      remote_resolution: :materialize,
                                      source_fetcher: source_fetcher,
                                    )
                                  else
                                    raise ArgumentError, "unknown dependency source resolution mode #{mode.inspect}"
                                  end
    end
  end
end
