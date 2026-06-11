# frozen_string_literal: true

module MilkTea
  module LSP
    class Workspace
      module WorkspaceDependencyGraph
        # Apply a workspace/didChangeWatchedFiles change to the indexed snapshot.
        # Open documents are source-of-truth and are left untouched.
        def apply_watched_file_change(uri, change_type)
          return [] if @document_state_mutex.synchronize { @open_documents.key?(uri) }

          if change_type.to_i == 3 # Deleted
            @document_state_mutex.synchronize do
              @indexed_documents.delete(uri)
            end
            invalidate_cache(uri)
            return refresh_import_dependent_caches(changed_uri: uri)
          end

          path = uri_to_path(uri)
          return [] unless path && File.file?(path)

          @document_state_mutex.synchronize do
            @indexed_documents[uri] = File.read(path)
          end
          invalidate_cache(uri)
          enqueue_definition_warmup(uri)
          affected_uris = refresh_import_dependent_caches(changed_uri: uri)
          if affected_uris.empty? && change_type.to_i == 1 # Created
            affected_uris = refresh_import_dependent_caches
            affected_uris.delete(uri)
          end
          affected_uris
        rescue StandardError => e
          warn "LSP watched-file update error #{uri}: #{e.message}"
          []
        end

        def refresh_open_document_dependency_caches(changed_uri)
          path = uri_to_path(changed_uri)
          return [] unless path

          refresh_import_dependent_caches(changed_uri: changed_uri)
        end

        def open_document_uris
          @document_state_mutex.synchronize do
            @open_documents.keys.dup
          end
        end

        # Returns open documents connected to +seed_uri+ through the import
        # dependency graph (imports and reverse dependents).
        def related_open_document_uris(seed_uri)
          open_uris = @document_state_mutex.synchronize do
            @open_documents.keys.dup
          end
          return [] if open_uris.empty?

          @facts_cache_mutex.synchronize do
            open_uris.each do |uri|
              facts = @facts_cache[uri]
              update_dependency_index(uri, facts)
            end

            open_set = open_uris.to_set
            return [seed_uri] unless open_set.include?(seed_uri)

            module_to_uris = Hash.new { |hash, key| hash[key] = Set.new }
            open_uris.each do |uri|
              module_name = @dependency_module_name_by_uri[uri]
              module_to_uris[module_name] << uri if module_name
            end

            visited = Set.new
            queue = [seed_uri]

            until queue.empty?
              current = queue.shift
              next if visited.include?(current)

              visited << current

              current_module = @dependency_module_name_by_uri[current]
              if current_module
                @reverse_import_dependents[current_module].each do |dependent_uri|
                  queue << dependent_uri if open_set.include?(dependent_uri) && !visited.include?(dependent_uri)
                end
              end

              imported_modules = @dependency_imports_by_uri[current] || Set.new
              imported_modules.each do |imported_module_name|
                module_to_uris[imported_module_name].each do |imported_uri|
                  queue << imported_uri if open_set.include?(imported_uri) && !visited.include?(imported_uri)
                end
              end
            end

            visited.to_a
          end
        end

        private

        def clear_dependency_index
          @dependency_module_name_by_uri.clear
          @dependency_imports_by_uri.clear
          @reverse_import_dependents.clear
          @full_reverse_index_built = false
        end

        def update_dependency_index(uri, facts)
          imported_module_names = if facts
                                    facts.imports.each_value.filter_map(&:name).to_set
                                  else
                                    dependency_index_imports_for(uri)
                                  end
          return if imported_module_names.nil? && facts.nil?

          delete_dependency_index(uri)

          module_name = facts&.module_name || infer_module_name_for_uri(uri)
          @dependency_module_name_by_uri[uri] = module_name if module_name
          @dependency_imports_by_uri[uri] = imported_module_names
          imported_module_names.each do |module_name|
            @reverse_import_dependents[module_name] << uri
          end
        end

        def dependency_index_imports_for(uri)
          ast = @ast_cache[uri]
          unless ast
            content = get_content(uri)
            return nil if content.empty?

            path = uri_to_path(uri)
            ast = if path && File.file?(path)
                    MilkTea::Parser.parse_collecting_errors(content, path: uri).ast
                  else
                    MilkTea::Parser.parse(content, path: uri)
                  end
          end
          return nil unless ast

          ast.imports.map { |import| import.path.to_s }.to_set
        rescue MilkTea::LexError, MilkTea::ParseError
          nil
        end

        def delete_dependency_index(uri)
          imported_module_names = @dependency_imports_by_uri.delete(uri) || Set.new
          imported_module_names.each do |module_name|
            dependents = @reverse_import_dependents[module_name]
            dependents.delete(uri)
            @reverse_import_dependents.delete(module_name) if dependents.empty?
          end
          @dependency_module_name_by_uri.delete(uri)
        end

        def dependent_open_document_uris_for(changed_uri, open_document_uris)
          return open_document_uris.reject { |open_uri| open_uri == changed_uri } unless changed_uri

          module_name = @dependency_module_name_by_uri[changed_uri] || infer_module_name_for_uri(changed_uri)
          return open_document_uris.reject { |open_uri| open_uri == changed_uri } unless module_name

          dependents = @reverse_import_dependents[module_name]
          open_document_uris.select { |open_uri| open_uri != changed_uri && dependents.include?(open_uri) }
        end

        def infer_module_name_for_uri(uri)
          path = uri_to_path(uri)
          return nil unless path

          resolution = DependencyResolution.resolve(path, mode: @dependency_resolution_mode)
          return nil if resolution.error_message

          loader = ModuleLoader.new(
            module_roots: module_roots_for_path(path, locked: resolution.locked),
            package_graph: package_graph_for_path(path, locked: resolution.locked),
            platform: effective_platform_for_path(path),
          )
          loader.send(:inferred_module_name_for_path, path)
        rescue StandardError
          nil
        end

        def module_roots_for_path(path, locked: false)
          roots = MilkTea::ModuleRoots.roots_for_path(path, locked: locked)
          return roots unless workspace_root_applicable_for?(path)

          [@workspace_root_path, *roots].uniq
        end

        def workspace_root_applicable_for?(path)
          return false if @workspace_root_path.nil? || path.nil?

          expanded_path = File.expand_path(path)
          expanded_path == @workspace_root_path || expanded_path.start_with?(@workspace_root_path + File::SEPARATOR)
        end

        def normalize_workspace_root_path(path)
          return nil if path.nil? || path.to_s.strip.empty?

          expanded_path = File.expand_path(path.to_s)
          return nil unless File.directory?(expanded_path)

          expanded_path
        end

        def refresh_import_dependent_caches(changed_uri: nil)
          all_open_document_uris = @document_state_mutex.synchronize do
            @open_documents.keys
          end
          open_document_uris = @facts_cache_mutex.synchronize do
            dependent_open_document_uris_for(changed_uri, all_open_document_uris)
          end

          @facts_state_mutex.synchronize do
            @facts_cache_mutex.synchronize do
              preserved_open_last_good_facts = all_open_document_uris.each_with_object({}) do |open_uri, preserved|
                facts = @last_good_facts_cache[open_uri]
                preserved[open_uri] = facts if facts
              end
              preserved_open_last_good_snapshots = all_open_document_uris.each_with_object({}) do |open_uri, preserved|
                snapshot = @last_good_tooling_snapshot_cache[open_uri]
                preserved[open_uri] = snapshot if snapshot
              end
              @shared_module_cache.clear
              @facts_cache.clear
              @tooling_snapshot_cache.clear
              @diagnostics_cache.clear
              @last_good_facts_cache.clear
              @last_good_tooling_snapshot_cache.clear
              preserved_open_last_good_snapshots.each do |open_uri, snapshot|
                @last_good_tooling_snapshot_cache[open_uri] = snapshot
              end
              preserved_open_last_good_facts.each do |open_uri, facts|
                @last_good_facts_cache[open_uri] = facts
              end
            end
          end
          open_document_uris
        end

        public

        def reverse_import_dependents_for(module_name)
          ensure_full_reverse_import_index
          @reverse_import_dependents[module_name]
        end

        private

        def ensure_full_reverse_import_index
          return if @full_reverse_index_built

          all_uris = @document_state_mutex.synchronize do
            (@indexed_documents.keys + @open_documents.keys).uniq
          end

          all_uris.each do |uri|
            next if @dependency_imports_by_uri.key?(uri)

            imported = dependency_index_imports_for(uri)
            next unless imported

            @dependency_imports_by_uri[uri] = imported
            imported.each do |mod_name|
              @reverse_import_dependents[mod_name] << uri
            end
          end

          @full_reverse_index_built = true
        end
      end
    end
  end
end
