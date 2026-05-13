# frozen_string_literal: true

require "digest"

module MilkTea
  class PackageSourceResolverError < StandardError; end

  class PackageSourceResolver
    attr_reader :resolved_registry_versions

    RegistryDependencyKey = Data.define(:parent_source_key, :dependency_name)

    class SourceIdentity
      def kind
        raise NotImplementedError, "#{self.class} must implement #kind"
      end

      def lock_attributes
        raise NotImplementedError, "#{self.class} must implement #lock_attributes"
      end

      def cache_key
        nil
      end

      def cacheable?
        !cache_key.nil?
      end
    end

    class PathIdentity < SourceIdentity
      attr_reader :path

      def initialize(path)
        @path = File.expand_path(path)
      end

      def kind
        :path
      end

      def lock_attributes
        {
          "source_path" => @path,
        }
      end
    end

    class RegistryIdentity < SourceIdentity
      attr_reader :package_name, :version

      def initialize(package_name:, version:)
        @package_name = normalize_required(package_name, "registry package name")
        @version = normalize_required(version, "registry package version")
      end

      def kind
        :registry
      end

      def lock_attributes
        {
          "registry_package" => @package_name,
          "registry_version" => @version,
        }
      end

      def cache_key
        "registry/#{@package_name}@#{@version}"
      end

      private

      def normalize_required(value, label)
        text = value.to_s.strip
        raise PackageSourceResolverError, "#{label} cannot be empty" if text.empty?
        if text.include?(File::SEPARATOR) || (File::ALT_SEPARATOR && text.include?(File::ALT_SEPARATOR))
          raise PackageSourceResolverError, "#{label} cannot contain path separators"
        end

        text
      end
    end

    class GitIdentity < SourceIdentity
      attr_reader :url, :revision, :subdir

      def initialize(url:, revision:, subdir: nil)
        @url = normalize_required(url, "git source url")
        @revision = normalize_required(revision, "git source revision")
        @subdir = normalize_optional(subdir)
      end

      def kind
        :git
      end

      def lock_attributes
        attributes = {
          "git_url" => @url,
          "git_rev" => @revision,
        }
        attributes["git_subdir"] = @subdir if @subdir
        attributes
      end

      def cache_key
        digest = Digest::SHA256.hexdigest([@url, @revision, @subdir].join("\0"))
        "git/#{digest}"
      end

      private

      def normalize_required(value, label)
        text = value.to_s.strip
        raise PackageSourceResolverError, "#{label} cannot be empty" if text.empty?

        text
      end

      def normalize_optional(value)
        text = value.to_s.strip
        return nil if text.empty?
        raise PackageSourceResolverError, "git source subdir cannot be absolute" if text.start_with?("/", "\\")
        raise PackageSourceResolverError, "git source subdir cannot be absolute" if text.match?(/\A[A-Za-z]:[\\\/]/)

        segments = text.split(/[\\\/]+/).reject(&:empty?)
        normalized_segments = []
        segments.each do |segment|
          next if segment == "."
          raise PackageSourceResolverError, "git source subdir cannot escape the repository root" if segment == ".."

          normalized_segments << segment
        end

        normalized = normalized_segments.join("/")
        normalized.empty? ? nil : normalized
      end
    end

    Source = Data.define(:identity, :local_root) do
      def kind
        identity.kind
      end

      def lock_attributes
        identity.lock_attributes
      end

      def cache_key
        identity.cache_key
      end

      def cacheable?
        identity.cacheable?
      end
    end

    ResolvedPackage = Data.define(:manifest, :source)

    def self.source_key_for_identity(identity)
      return "path:#{File.expand_path(identity.path)}" if identity.is_a?(PathIdentity)
      return "#{identity.kind}:#{identity.cache_key}" if identity.cache_key

      raise PackageSourceResolverError, "unsupported source identity #{identity.class} for registry dependency key"
    end

    def self.registry_dependency_key(parent_source_key:, dependency_name:)
      RegistryDependencyKey.new(
        parent_source_key: parent_source_key.to_s,
        dependency_name: dependency_name.to_s,
      )
    end

    def initialize(source_cache: PackageSourceCache.new, remote_resolution: :reject, source_fetcher: nil, resolved_registry_versions: nil)
      @source_cache = source_cache
      @remote_resolution = remote_resolution
      @source_fetcher = source_fetcher
      @resolved_registry_versions = normalize_resolved_registry_versions(resolved_registry_versions)
    end

    def supports_dependency_solving?
      @remote_resolution != :reject
    end

    def with_resolved_registry_versions(resolved_registry_versions)
      self.class.new(
        source_cache: @source_cache,
        remote_resolution: @remote_resolution,
        source_fetcher: @source_fetcher,
        resolved_registry_versions:,
      )
    end

    def source_for_manifest(manifest)
      Source.new(
        identity: PathIdentity.new(manifest.root_dir),
        local_root: manifest.root_dir,
      )
    end

    def identity_from_lock(entry, lock_path)
      source_kind = entry["source_kind"].to_s

      case source_kind
      when "path"
        source_path = entry["source_path"].to_s
        raise PackageSourceResolverError, "package.lock missing source_path in #{lock_path}" if source_path.empty?

        PathIdentity.new(source_path)
      when "registry"
        RegistryIdentity.new(
          package_name: entry["registry_package"],
          version: entry["registry_version"],
        )
      when "git"
        GitIdentity.new(
          url: entry["git_url"],
          revision: entry["git_rev"],
          subdir: entry["git_subdir"],
        )
      else
        raise PackageSourceResolverError,
              "unsupported package source_kind #{source_kind.inspect} in #{lock_path}; supported kinds are path, registry, and git"
      end
    end

    def resolve(dependency, parent_manifest:, parent_source: nil)
      if dependency.path
        manifest = PackageManifest.load(dependency.path)
        validate_fixed_dependency_version_requirement!(dependency, manifest, parent_manifest:)
        return ResolvedPackage.new(manifest:, source: source_for_manifest(manifest))
      end

      return resolve_registry_dependency(dependency, parent_manifest:, parent_source:) if dependency.registry?
      return resolve_git_dependency(dependency, parent_manifest:) if dependency.git

      raise PackageSourceResolverError,
            "dependency #{dependency.name} in #{parent_manifest.manifest_path} has no supported source resolver"
    end

    def source_from_lock(entry, lock_path)
      identity = identity_from_lock(entry, lock_path)
      source_for_identity(identity, lock_path)
    rescue PackageSourceCacheError => e
      raise PackageSourceResolverError, e.message
    end

    private

    def resolve_registry_dependency(dependency, parent_manifest:, parent_source: nil)
      if dependency.exact_registry_version?
        identity = RegistryIdentity.new(package_name: dependency.name, version: dependency.version)
        return resolve_cache_backed_dependency(identity, dependency:, parent_manifest:)
      end

      parent_source_key = registry_dependency_parent_source_key(parent_manifest:, parent_source:)
      dependency_key = self.class.registry_dependency_key(parent_source_key:, dependency_name: dependency.name)
      resolved_version = @resolved_registry_versions[dependency_key] || @resolved_registry_versions[dependency.name]
      if resolved_version
        unless dependency.version_req.matches?(resolved_version)
          raise PackageSourceResolverError,
                "dependency #{dependency.name} in #{parent_manifest.manifest_path} resolved version #{resolved_version.inspect}, which does not satisfy #{dependency.version_req}"
        end

        identity = RegistryIdentity.new(package_name: dependency.name, version: resolved_version)
        return resolve_cache_backed_dependency(identity, dependency:, parent_manifest:)
      end

      raise PackageSourceResolverError,
        "dependency #{dependency.name} in #{parent_manifest.manifest_path} uses version requirement #{dependency.version_req}, but registry dependency solving is not implemented yet; use an exact version for now"
    end

    def resolve_git_dependency(dependency, parent_manifest:)
      identity = GitIdentity.new(
        url: dependency.git,
        revision: dependency.git_rev,
        subdir: dependency.git_subdir,
      )

      resolve_cache_backed_dependency(identity, dependency:, parent_manifest:)
    end

    def resolve_cache_backed_dependency(identity, dependency:, parent_manifest:)
      context_label = "dependency #{dependency.name} in #{parent_manifest.manifest_path}"
      source = case @remote_resolution
               when :reject
                 raise PackageSourceResolverError,
                       "#{context_label} uses #{identity.kind} resolution, but live dependency resolution only supports local path dependencies; run mtc deps lock and then use --locked or --frozen"
               when :cache
                 source_for_identity(identity, context_label)
               when :materialize
                 unless @source_fetcher
                   raise PackageSourceResolverError,
                         "#{context_label} requested #{identity.kind} materialization without a package source fetcher"
                 end

                 @source_fetcher.materialize_identity(package_name: dependency.name, identity:)
                 source_for_identity(identity, context_label)
               else
                 raise PackageSourceResolverError, "unknown remote resolution mode #{@remote_resolution.inspect}"
               end

      manifest = PackageManifest.load(source.local_root)
      if manifest.package_name != dependency.name
        raise PackageSourceResolverError,
              "#{context_label} resolved package #{manifest.package_name} at #{manifest.manifest_path}"
      end

      if identity.is_a?(RegistryIdentity) && manifest.package_version != identity.version
        raise PackageSourceResolverError,
              "#{context_label} resolved version #{manifest.package_version.inspect} at #{manifest.manifest_path}; expected #{identity.version.inspect}"
      end

      ResolvedPackage.new(manifest:, source:)
    rescue PackageManifestError => e
      raise PackageSourceResolverError, e.message
    end

    def validate_fixed_dependency_version_requirement!(dependency, manifest, parent_manifest:)
      return unless dependency.version_req

      package_version = manifest.package_version
      if package_version.nil?
        raise PackageSourceResolverError,
              "dependency #{dependency.name} in #{parent_manifest.manifest_path} requires version #{dependency.version_req}, but #{manifest.manifest_path} does not declare package.version"
      end

      return if dependency.version_req.matches?(package_version)

      raise PackageSourceResolverError,
            "dependency #{dependency.name} in #{parent_manifest.manifest_path} resolved version #{package_version.inspect} at #{manifest.manifest_path}, which does not satisfy #{dependency.version_req}"
    end

    def source_for_identity(identity, context_label)
      local_root = if identity.is_a?(PathIdentity)
                     identity.path
                   else
                     manifest_path = @source_cache.manifest_path_for(identity)
                     unless File.file?(manifest_path)
                       raise PackageSourceResolverError,
                             "package source_kind #{identity.kind.inspect} in #{context_label} is not materialized in the source cache: expected #{manifest_path}"
                     end

                     @source_cache.materialized_root_for(identity)
                   end

      Source.new(
        identity:,
        local_root:,
      )
    end

    def registry_dependency_parent_source_key(parent_manifest:, parent_source:)
      identity = if parent_source
                   parent_source.identity
                 else
                   source_for_manifest(parent_manifest).identity
                 end

      self.class.source_key_for_identity(identity)
    end

    def normalize_resolved_registry_versions(versions)
      return {} unless versions

      versions.each_with_object({}) do |(key, version), resolved|
        normalized_key = case key
                         when RegistryDependencyKey
                           self.class.registry_dependency_key(
                             parent_source_key: key.parent_source_key,
                             dependency_name: key.dependency_name,
                           )
                         when Array
                           if key.length != 2
                             raise PackageSourceResolverError,
                                   "registry dependency key must contain parent manifest path and dependency name"
                           end

                           self.class.registry_dependency_key(parent_source_key: key[0], dependency_name: key[1])
                         else
                           key.to_s
                         end

        resolved[normalized_key] = version.to_s
      end
    end
  end
end
