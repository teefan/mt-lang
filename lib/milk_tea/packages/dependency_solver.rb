# frozen_string_literal: true

module MilkTea
  class PackageDependencySolverError < StandardError; end

  class PackageDependencySolver
    Solution = Data.define(:registry_versions)

    State = Data.define(:manifests_by_path, :selected_registry_versions, :processing_stack) do
      def deep_dup
        self.class.new(
          manifests_by_path: manifests_by_path.dup,
          selected_registry_versions: selected_registry_versions.dup,
          processing_stack: processing_stack.dup,
        )
      end
    end

    def initialize(source_resolver:, registry_metadata_provider: PackageRegistryMetadataProvider.new, locked_registry_versions: nil)
      @source_resolver = source_resolver
      @registry_metadata_provider = registry_metadata_provider
      @locked_registry_versions = normalize_locked_registry_versions(locked_registry_versions)
    end

    def solve(path_or_manifest)
      root_manifest = path_or_manifest.is_a?(PackageManifest::DataView) ? path_or_manifest : PackageManifest.load(path_or_manifest)
      state = State.new(
        manifests_by_path: {},
        selected_registry_versions: {},
        processing_stack: [],
      )

      resolved_state = visit_manifest(root_manifest, state, source: @source_resolver.source_for_manifest(root_manifest))
      Solution.new(registry_versions: resolved_state.selected_registry_versions.transform_values(&:to_s).freeze)
    rescue PackageManifestError, PackageRegistryMetadataProviderError, PackageSourceResolverError, PackageVersionError => e
      raise PackageDependencySolverError, e.message
    end

    private

    def visit_manifest(manifest, state, source:)
      existing_manifest = state.manifests_by_path[manifest.manifest_path]
      if existing_manifest
        return state
      end

      if state.processing_stack.include?(manifest.manifest_path)
        cycle_paths = state.processing_stack + [manifest.manifest_path]
        cycle = cycle_paths.map do |manifest_path|
          if manifest_path == manifest.manifest_path
            manifest.package_name
          else
            state.manifests_by_path.fetch(manifest_path).package_name
          end
        end
        raise PackageDependencySolverError, "package dependency cycle detected: #{cycle.join(' -> ')}"
      end

      state.manifests_by_path[manifest.manifest_path] = manifest
      state.processing_stack << manifest.manifest_path
      process_dependency_list(manifest.dependencies, parent_manifest: manifest, parent_source: source, state:)
    ensure
      state.processing_stack.pop if state&.processing_stack&.last == manifest.manifest_path
    end

    def process_dependency_list(dependencies, parent_manifest:, parent_source:, state:, index: 0)
      return state if index >= dependencies.length

      candidate_states = visit_dependency(dependencies[index], parent_manifest:, parent_source:, state:)
      last_error = nil
      candidate_states.each do |candidate_state|
        begin
          return process_dependency_list(
            dependencies,
            parent_manifest:,
            parent_source:,
            state: candidate_state,
            index: index + 1,
          )
        rescue PackageDependencySolverError => e
          last_error = e
        end
      end

      raise last_error || PackageDependencySolverError.new(
        "failed to resolve dependency #{dependencies[index].name} in #{parent_manifest.manifest_path}",
      )
    end

    def visit_dependency(dependency, parent_manifest:, parent_source:, state:)
      if dependency.path || dependency.git
        branch = state.deep_dup
        resolved_package = @source_resolver.resolve(dependency, parent_manifest:, parent_source:)
        return [visit_manifest(resolved_package.manifest, branch, source: resolved_package.source)]
      end

      if dependency.registry?
        if dependency.exact_registry_version?
          branch = state.deep_dup
          resolved_package = @source_resolver.resolve(dependency, parent_manifest:, parent_source:)
          return [visit_manifest(resolved_package.manifest, branch, source: resolved_package.source)]
        end

        return choose_registry_version(dependency, parent_manifest:, parent_source:, state:)
      end

      raise PackageDependencySolverError,
            "dependency #{dependency.name} in #{parent_manifest.manifest_path} has no supported source resolver"
    end

    def choose_registry_version(dependency, parent_manifest:, parent_source:, state:)
      package_name = dependency.name
      dependency_key = registry_dependency_key(parent_source:, dependency_name: package_name)
      candidate_versions = @registry_metadata_provider.available_versions(package_name).select do |candidate_version|
        dependency.version_req.matches?(candidate_version)
      end

      locked_version = locked_registry_version_for(dependency_key, package_name)
      if locked_version
        candidate_versions = candidate_versions.select { |candidate_version| candidate_version.to_s == locked_version }
      end

      if candidate_versions.empty?
        if locked_version
          raise PackageDependencySolverError,
                "locked registry version #{locked_version} for #{package_name} in #{parent_manifest.manifest_path} does not satisfy #{dependency.version_req}"
        end

        raise PackageDependencySolverError,
              "no registry version for #{package_name} in #{parent_manifest.manifest_path} satisfies #{dependency.version_req}"
      end

      last_error = nil
      candidate_states = candidate_versions.filter_map do |candidate_version|
        branch = state.deep_dup
        branch.selected_registry_versions[dependency_key] = candidate_version
        manifest = @registry_metadata_provider.manifest_for(package_name, candidate_version)
        source = PackageSourceResolver::Source.new(
          identity: PackageSourceResolver::RegistryIdentity.new(package_name:, version: candidate_version.to_s),
          local_root: manifest.root_dir,
        )

        begin
          visit_manifest(manifest, branch, source:)
        rescue PackageDependencySolverError => e
          last_error = e
          nil
        end
      end

      return candidate_states unless candidate_states.empty?

      raise last_error || PackageDependencySolverError.new(
        "no registry version for #{package_name} in #{parent_manifest.manifest_path} satisfies #{dependency.version_req}",
      )
    end

    def registry_dependency_key(parent_source:, dependency_name:)
      PackageSourceResolver.registry_dependency_key(
        parent_source_key: PackageSourceResolver.source_key_for_identity(parent_source.identity),
        dependency_name:,
      )
    end

    def locked_registry_version_for(dependency_key, package_name)
      @locked_registry_versions[dependency_key] || @locked_registry_versions[package_name]
    end

    def normalize_locked_registry_versions(versions)
      return {} unless versions

      versions.each_with_object({}) do |(key, version), locked|
        normalized_key = case key
                         when PackageSourceResolver::RegistryDependencyKey
                           PackageSourceResolver.registry_dependency_key(
                             parent_source_key: key.parent_source_key,
                             dependency_name: key.dependency_name,
                           )
                         when Array
                           if key.length != 2
                             raise PackageDependencySolverError,
                                   "registry dependency key must contain parent manifest path and dependency name"
                           end

                           PackageSourceResolver.registry_dependency_key(parent_source_key: key[0], dependency_name: key[1])
                         else
                           key.to_s
                         end

        locked[normalized_key] = version.to_s
      end
    end
  end
end
