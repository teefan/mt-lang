# frozen_string_literal: true

module MilkTea
  module LSP
    class Workspace
      # Persistent module-name index for import-line completion.
      #
      # `import_completions` previously walked the entire module-root tree on
      # every keystroke (stat'ing every directory entry). This index records, per
      # module root, the importable module names reachable from each directory:
      # `.mt` file basenames directly in a directory, plus subdirectory names that
      # transitively contain a `.mt` file. It is built once per root and kept in
      # sync with workspace/didChangeWatchedFiles events, so per-keystroke import
      # completion becomes an in-memory hash lookup.
      module WorkspaceModuleIndex
        def reset_module_index
          @module_index_mutex.synchronize { @module_index.clear }
        end

        # Rebuild the index for every module root reachable from the workspace
        # root. Called after initialization and after workspace-folder changes.
        def refresh_module_index_for_workspace
          root_path = @workspace_root_path
          return unless root_path

          module_roots_for_path(root_path).each { |root| ensure_module_index(root) }
        end

        # Ensure +root+ has an index entry, building it on first use. A race
        # between two threads simply builds twice and the later write wins.
        def ensure_module_index(root)
          present = @module_index_mutex.synchronize { @module_index.key?(root) }
          return if present

          build_module_index(root)
        end

        # Return importable module names for +fs_dir+ under +root+, excluding the
        # currently-open +current_path+ file. Returns nil when +root+ is unknown.
        def module_importable_names(root, fs_dir, current_path: nil)
          ensure_module_index(root)

          entry = @module_index_mutex.synchronize { @module_index[root] }
          return nil unless entry

          result = {}
          files = entry[:mt_files][fs_dir]
          if files
            files.each do |mod_name, file_path|
              next if current_path && file_path == current_path

              result[mod_name] = true
            end
          end
          entry[:mt_dirs][fs_dir]&.each { |subdir| result[subdir] = true }
          result
        end

        # Apply workspace/didChangeWatchedFiles events to the index. Content
        # changes (type 2) do not affect the name index; creates (1) and deletes
        # (3) of `.mt` files rebuild their root once per event batch so a build
        # producing many events triggers a single rescan. Open documents are
        # source-of-truth and are ignored (skip_open: true), matching
        # apply_watched_file_change; rename handling passes skip_open: false so
        # the index never keeps a stale name for a renamed module.
        def apply_module_index_events(changes, skip_open: true)
          open_uris = @document_state_mutex.synchronize { @open_documents.keys }
          roots_to_rebuild = Set.new
          changes.each do |change|
            uri = change.is_a?(Hash) ? change['uri'] : nil
            change_type = change.is_a?(Hash) ? change['type'] : nil
            next unless uri && [1, 3].include?(change_type&.to_i)
            next if skip_open && open_uris.include?(uri)

            path = uri_to_path(uri)
            next unless path && path.end_with?('.mt')

            root = module_index_root_for_path(path)
            roots_to_rebuild << root if root
          end

          roots_to_rebuild.each { |root| build_module_index(root) }
          roots_to_rebuild.length
        end

        def module_index_roots
          @module_index_mutex.synchronize { @module_index.keys }
        end

        private

        def module_index_root_for_path(path)
          expanded = File.expand_path(path)
          @module_index_mutex.synchronize do
            @module_index.each_key do |root|
              return root if expanded == root || expanded.start_with?(root + File::SEPARATOR)
            end
          end
          nil
        end

        # Scan +root+ once and record, for every directory, the importable module
        # names: `.mt` file basenames in that directory and subdirectory names
        # that transitively contain a `.mt` file.
        def build_module_index(root)
          mt_files = Hash.new { |hash, key| hash[key] = {} }
          mt_dirs = Hash.new { |hash, key| hash[key] = Set.new }

          files = Dir.glob(File.join(root, '**', '*.mt')).sort
          prefix = root + File::SEPARATOR
          files.each do |file_path|
            rel = file_path.delete_prefix(prefix)
            dir = File.dirname(rel)
            dir = '' if dir == '.'
            mod_name = File.basename(rel, '.mt')

            mt_files[dir][mod_name] = File.expand_path(file_path)

            acc = ''
            dir.split(File::SEPARATOR).each do |segment|
              mt_dirs[acc] << segment
              acc = acc.empty? ? segment : "#{acc}#{File::SEPARATOR}#{segment}"
            end
          end

          @module_index_mutex.synchronize do
            @module_index[root] = { mt_files: mt_files, mt_dirs: mt_dirs }
          end
          nil
        end
      end
    end
  end
end
