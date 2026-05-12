# frozen_string_literal: true

module MilkTea
  class PackageSourceCacheError < StandardError; end

  class PackageSourceCache
    def self.default_root(env: ENV, home: nil)
      xdg_cache_home = env.fetch("XDG_CACHE_HOME", "").to_s.strip
      base_root = if xdg_cache_home.empty?
                    File.join(home || Dir.home, ".cache")
                  else
                    File.expand_path(xdg_cache_home)
                  end

      File.join(base_root, "milk_tea", "package_sources")
    end

    attr_reader :root

    def initialize(root: self.class.default_root)
      @root = File.expand_path(root)
    end

    def path_for(source_or_identity)
      identity = extract_identity(source_or_identity)
      cache_key = identity.cache_key
      unless cache_key
        raise PackageSourceCacheError, "package source kind #{identity.kind.inspect} does not use the shared source cache"
      end

      File.join(@root, *cache_key.split("/"))
    end

    def materialized_root_for(source_or_identity)
      identity = extract_identity(source_or_identity)
      base_path = path_for(identity)

      if identity.respond_to?(:subdir) && identity.subdir
        segments = identity.subdir.split(/[\\\/]+/).reject(&:empty?)
        return File.join(base_path, *segments)
      end

      base_path
    end

    def manifest_path_for(source_or_identity)
      File.join(materialized_root_for(source_or_identity), "package.toml")
    end

    def materialized?(source_or_identity)
      File.file?(manifest_path_for(source_or_identity))
    end

    private

    def extract_identity(source_or_identity)
      if source_or_identity.respond_to?(:identity)
        source_or_identity.identity
      else
        source_or_identity
      end
    end
  end
end
