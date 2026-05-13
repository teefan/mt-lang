# frozen_string_literal: true

module MilkTea
  class PackageGraphError < StandardError; end

  class PackageGraph
    Edge = Data.define(:dependency, :node)
    Node = Data.define(:manifest, :source, :edges)

    def self.load(path, locked: false, source_resolver: PackageSourceResolver.new, registry_metadata_provider: PackageRegistryMetadataProvider.new)
      return PackageLock.load(path, source_resolver:) if locked

      new(path, source_resolver:, registry_metadata_provider:).load
    end

    def initialize(path, source_resolver: PackageSourceResolver.new, registry_metadata_provider: PackageRegistryMetadataProvider.new)
      @path = File.expand_path(path)
      @source_resolver = source_resolver
      @graph_source_resolver = source_resolver
      @registry_metadata_provider = registry_metadata_provider
      @nodes_by_manifest_path = {}
      @build_stack = []
    end

    def load
      root_manifest = PackageManifest.load(@path)
      @graph_source_resolver = resolve_graph_source_resolver(root_manifest)
      build_node(root_manifest, source: @graph_source_resolver.source_for_manifest(root_manifest))
    end

    def self.render_tree(path, source_resolver: PackageSourceResolver.new, registry_metadata_provider: PackageRegistryMetadataProvider.new)
      load(path, source_resolver:, registry_metadata_provider:).tree_lines.join("\n")
    end

    class Node
      def packages(nodes = [], visited = {})
        return nodes if visited[manifest.manifest_path]

        visited[manifest.manifest_path] = true
        nodes << self
        edges.each do |edge|
          edge.node&.packages(nodes, visited)
        end
        nodes
      end

      def source_roots(roots = [], visited = {})
        return roots if visited[manifest.manifest_path]

        visited[manifest.manifest_path] = true
        roots << manifest.source_root
        edges.each do |edge|
          edge.node&.source_roots(roots, visited)
        end
        roots
      end

      def package_for_path(path, matches = [])
        return nil unless path

        expanded_path = File.expand_path(path)
        matches << self if package_path?(expanded_path)
        edges.each do |edge|
          edge.node&.package_for_path(expanded_path, matches)
        end

        matches.max_by { |node| node.manifest.root_dir.length }
      end

      def tree_lines(indent = 0)
        lines = [("  " * indent) + manifest.package_name]
        edges.each do |edge|
          if edge.node
            lines.concat(edge.node.tree_lines(indent + 1))
          else
            lines << (("  " * (indent + 1)) + edge.dependency.name)
          end
        end
        lines
      end

      private

      def package_path?(path)
        root_dir = manifest.root_dir
        path == root_dir || path.start_with?(root_dir + File::SEPARATOR)
      end
    end

    private

    def build_node(manifest, source:)
      existing = @nodes_by_manifest_path[manifest.manifest_path]
      return existing if existing

      if @build_stack.include?(manifest.manifest_path)
        cycle_paths = @build_stack + [manifest.manifest_path]
        cycle_names = cycle_paths.map { |path| package_name_for_manifest_path(path) }
        raise PackageGraphError, "package dependency cycle detected: #{cycle_names.join(' -> ')}"
      end

      @build_stack << manifest.manifest_path
      edges = manifest.dependencies.map do |dependency|
        resolved_package = @graph_source_resolver.resolve(dependency, parent_manifest: manifest, parent_source: source)
        edge_node = build_node(resolved_package.manifest, source: resolved_package.source)
        Edge.new(dependency:, node: edge_node)
      end

      node = Node.new(manifest:, source:, edges:)
      @nodes_by_manifest_path[manifest.manifest_path] = node
      node
    ensure
      @build_stack.pop if @build_stack.last == manifest.manifest_path
    end

    def package_name_for_manifest_path(manifest_path)
      node = @nodes_by_manifest_path[manifest_path]
      return node.manifest.package_name if node

      PackageManifest.load(manifest_path).package_name
    rescue PackageManifestError
      manifest_path
    end

    def resolve_graph_source_resolver(root_manifest)
      return @source_resolver unless @source_resolver.supports_dependency_solving?

      solution = PackageDependencySolver.new(
        source_resolver: @source_resolver,
        registry_metadata_provider: @registry_metadata_provider,
        locked_registry_versions: @source_resolver.resolved_registry_versions,
      ).solve(root_manifest)

      @source_resolver.with_resolved_registry_versions(solution.registry_versions)
    rescue PackageDependencySolverError => e
      raise PackageGraphError, e.message
    end
  end
end
