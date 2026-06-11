# frozen_string_literal: true

module MilkTea
  module LSP
    class Workspace
      module WorkspaceStore
        def set_document_source(uri, source)
          normalized = source.to_s
          raise ArgumentError, "invalid document source #{source.inspect}" unless DOCUMENT_SOURCES.include?(normalized)

          @document_state_mutex.synchronize do
            previous = @document_sources[uri]
            @document_sources[uri] = normalized
            previous
          end
        end

        def document_source(uri)
          @document_state_mutex.synchronize do
            @document_sources[uri]
          end
        end

        def background_document?(uri)
          @document_state_mutex.synchronize do
            @document_sources[uri] == 'background-document'
          end
        end

        # ── Document lifecycle ──────────────────────────────────────────────────

        def open_document(uri, content)
          @document_state_mutex.synchronize do
            @open_documents[uri] = content
          end
          invalidate_cache(uri)
          enqueue_definition_warmup(uri) unless background_document?(uri)
          warm_document_facts(uri, content)
        end

        def close_document(uri)
          # Keep indexed snapshot available for workspace-level features.
          @document_state_mutex.synchronize do
            @open_documents.delete(uri)
            @document_sources.delete(uri)
          end
          invalidate_cache(uri, clear_last_good: true)
        end

        def update_document(uri, content)
          @document_state_mutex.synchronize do
            @open_documents[uri] = content
          end
          invalidate_cache(uri)
          enqueue_definition_warmup(uri) unless background_document?(uri)
          warm_document_facts(uri, content)
        end

        # Apply one incremental change (LSP textDocumentSync == 2).
        # change is a Hash with optional 'range' and mandatory 'text'.
        def apply_incremental_change(uri, change)
          content = get_content(uri)
          new_content = apply_incremental_change_to_content(content, change)

          @document_state_mutex.synchronize do
            @open_documents[uri] = new_content
          end
          invalidate_cache(uri)
          enqueue_definition_warmup(uri) unless background_document?(uri)
        end

        # Apply a didChange batch. For multi-range batches, apply against the
        # original snapshot in reverse source order so disjoint edits on the same
        # line remain stable even when offsets shift.
        def apply_incremental_changes(uri, changes)
          content = get_content(uri)
          edits = Array(changes)

          new_content = if edits.length > 1 && edits.all? { |change| change['range'] }
                          apply_incremental_changes_against_snapshot(content, edits)
                        else
                          edits.reduce(content) { |acc, change| apply_incremental_change_to_content(acc, change) }
                        end

          @document_state_mutex.synchronize do
            @open_documents[uri] = new_content
          end
          invalidate_cache(uri)
          enqueue_definition_warmup(uri) unless background_document?(uri)
        end

        def apply_incremental_change_to_content(content, change)
          if change['range']
            start_pos = change['range']['start']
            end_pos   = change['range']['end']
            start_off = line_char_to_offset(content, start_pos['line'], start_pos['character'])
            end_off   = line_char_to_offset(content, end_pos['line'],   end_pos['character'])
            prefix = content.byteslice(0, start_off).to_s
            suffix = content.byteslice(end_off..).to_s
            prefix + change['text'].to_s + suffix
          else
            # Full-document fallback within an incremental-sync session
            change['text'].to_s
          end
        end

        def apply_incremental_changes_against_snapshot(content, changes)
          ordered = changes.sort_by do |change|
            start_pos = change['range']['start']
            [start_pos['line'], start_pos['character']]
          end.reverse

          ordered.reduce(content) { |acc, change| apply_incremental_change_to_content(acc, change) }
        end

        # Index all .mt files under root_uri so they are available for workspace-wide queries.
        def index_workspace(root_uri, &progress)
          root_path = uri_to_path(root_uri)
          return unless root_path && File.directory?(root_path)

          paths = Dir.glob(File.join(root_path, '**', '*.mt')).sort
          total = paths.length
          paths.each_with_index do |path, idx|
            file_uri = path_to_uri(path)
            @document_state_mutex.synchronize do
              @indexed_documents[file_uri] ||= begin
                File.read(path)
              rescue StandardError
                nil
              end
            end
            if progress && total > 0
              pct = ((idx + 1) * 100 / total).clamp(0, 100)
              progress.call(pct, "#{idx + 1}/#{total} files")
            end
          end
        rescue StandardError => e
          log_error("LSP workspace index error #{root_uri}: #{e.message}")
        end

        def shutdown
          stop_definition_warmup
        end
      end
    end
  end
end
