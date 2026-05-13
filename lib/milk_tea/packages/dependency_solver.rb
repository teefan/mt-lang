# frozen_string_literal: true

module MilkTea
  class PackageDependencySolverError < StandardError; end

  class PackageDependencySolver
    Solution = Data.define(:registry_versions)
    Requirement = Data.define(:version_req, :required_by)

    State = Data.define(:manifests_by_name, :selected_registry_versions, :selected_registry_manifests, :requirements_by_name, :processing_stack) do
      def deep_dup
        duplicated_requirements = Hash.new { |hash, key| hash[key] = [] }
        requirements_by_name.each do |package_name, requirements|
          duplicated_requirements[package_name] = requirements.dup
        end

        self.class.new(
          manifests_by_name: manifests_by_name.dup,
          selected_registry_versions: selected_registry_versions.dup,
          selected_registry_manifests: selected_registry_manifests.dup,
          requirements_by_name: duplicated_requirements,
          processing_stack: processing_stack.dup,
        )
      end
    end

    def initialize(source_resolver:, registry_metadata_provider: PackageRegistryMetadataProvider.new)
      @source_resolver = source_resolver
      @registry_metadata_provider = registry_metadata_provider
    end

    def solve(path_or_manifest)
      root_manifest = path_or_manifest.is_a?(PackageManifest::DataView) ? path_or_manifest : PackageManifest.load(path_or_manifest)
      state = State.new(
        manifests_by_name: {},
        selected_registry_versions: {},
        selected_registry_manifests: {},
        requirements_by_name: Hash.new { |hash, key| hash[key] = [] },
        processing_stack: [],
      )

      resolved_state = visit_manifest(root_manifest, state)
      Solution.new(registry_versions: resolved_state.selected_registry_versions.transform_values(&:to_s).freeze)
    rescue PackageManifestError, PackageRegistryMetadataProviderError, PackageSourceResolverError, PackageVersionError => e
      raise PackageDependencySolverError, e.message
    end

    private

    def visit_manifest(manifest, state)
      existing_manifest = state.manifests_by_name[manifest.package_name]
      if existing_manifest
        if existing_manifest.manifest_path != manifest.manifest_path
          raise PackageDependencySolverError,
                "duplicate package name #{manifest.package_name} at #{manifest.manifest_path} and #{existing_manifest.manifest_path}"
        end

        return state
      end

      if state.processing_stack.include?(manifest.package_name)
        cycle = state.processing_stack + [manifest.package_name]
        raise PackageDependencySolverError, "package dependency cycle detected: #{cycle.join(' -> ')}"
      end

      state.manifests_by_name[manifest.package_name] = manifest
      state.processing_stack << manifest.package_name
      process_dependency_list(manifest.dependencies, parent_manifest: manifest, state:)
    ensure
      state.processing_stack.pop if state&.processing_stack&.last == manifest.package_name
    end

    def process_dependency_list(dependencies, parent_manifest:, state:, index: 0)
      return state if index >= dependencies.length

      candidate_states = visit_dependency(dependencies[index], parent_manifest:, state:)
      last_error = nil
      candidate_states.each do |candidate_state|
        begin
          return process_dependency_list(dependencies, parent_manifest:, state: candidate_state, index: index + 1)
        rescue PackageDependencySolverError => e
          last_error = e
        end
      end

      raise last_error || PackageDependencySolverError.new(
        "failed to resolve dependency #{dependencies[index].name} in #{parent_manifest.manifest_path}",
      )
    end

    def visit_dependency(dependency, parent_manifest:, state:)
      if dependency.path || dependency.git
        branch = state.deep_dup
        resolved_package = @source_resolver.resolve(dependency, parent_manifest:)
        return [visit_manifest(resolved_package.manifest, branch)]
      end

      if dependency.registry?
        requirement_state = state.deep_dup
        requirement_state.requirements_by_name[dependency.name] << Requirement.new(
          dependency.version_req,
          "dependency #{dependency.name} in #{parent_manifest.manifest_path}",
        )

        selected_version = requirement_state.selected_registry_versions[dependency.name]
        if selected_version
          ensure_selected_version_matches!(dependency.name, requirement_state)
          return [visit_manifest(requirement_state.selected_registry_manifests.fetch(dependency.name), requirement_state)]
        end

        return choose_registry_version(dependency.name, requirement_state)
      end

      raise PackageDependencySolverError,
            "dependency #{dependency.name} in #{parent_manifest.manifest_path} has no supported source resolver"
    end

    def choose_registry_version(package_name, state)
      requirements = state.requirements_by_name.fetch(package_name)
      candidate_versions = @registry_metadata_provider.available_versions(package_name).select do |candidate_version|
        requirements.all? { |requirement| requirement.version_req.matches?(candidate_version) }
      end

      if candidate_versions.empty?
        raise PackageDependencySolverError,
              "no registry version for #{package_name} satisfies #{format_requirements(requirements)}"
      end

      last_error = nil
      candidate_states = candidate_versions.filter_map do |candidate_version|
        branch = state.deep_dup
        branch.selected_registry_versions[package_name] = candidate_version
        branch.selected_registry_manifests[package_name] = @registry_metadata_provider.manifest_for(package_name, candidate_version)

        begin
          visit_manifest(branch.selected_registry_manifests.fetch(package_name), branch)
        rescue PackageDependencySolverError => e
          last_error = e
          nil
        end
      end

      return candidate_states unless candidate_states.empty?

      raise last_error || PackageDependencySolverError.new(
        "no registry version for #{package_name} satisfies #{format_requirements(requirements)}",
      )
    end

    def ensure_selected_version_matches!(package_name, state)
      selected_version = state.selected_registry_versions.fetch(package_name)
      requirements = state.requirements_by_name.fetch(package_name)
      return if requirements.all? { |requirement| requirement.version_req.matches?(selected_version) }

      raise PackageDependencySolverError,
            "selected registry version #{selected_version} for #{package_name} does not satisfy #{format_requirements(requirements)}"
    end

    def format_requirements(requirements)
      requirements.map { |requirement| "#{requirement.version_req} from #{requirement.required_by}" }.join(", ")
    end
  end
end
