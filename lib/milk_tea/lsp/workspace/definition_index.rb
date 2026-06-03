# frozen_string_literal: true

module MilkTea
  module LSP
    class Workspace
      module WorkspaceDefinitionIndex
        # Find a definition token across the whole workspace, preferring +preferred_uri+.
        # Returns { uri:, token: } or nil.
        # Uses demand-driven name lookup to avoid cold full-workspace indexing.
        def find_definition_token_global(name, preferred_uri: nil, before_line: nil, before_char: nil)
          # Check preferred_uri first without going through the index.
          if preferred_uri
            token = find_definition_token(preferred_uri, name, before_line:, before_char:)
            return { uri: preferred_uri, token: token } if token
          end

          entries = nil
          miss = false
          @definition_cache_mutex.synchronize do
            entries = @definition_index[name]&.dup
            miss = @definition_miss_cache.include?(name)
          end
          if entries
            entries.each do |entry|
              next if entry[:uri] == preferred_uri

              return entry
            end
          end

          return nil if miss

          candidate_definition_uris(name, exclude_uri: preferred_uri).each do |doc_uri|
            token = find_definition_token(doc_uri, name)
            next unless token

            entry = { uri: doc_uri, token: token }
            cache_definition_entry(name, entry)
            return entry
          end

          @definition_cache_mutex.synchronize do
            @definition_miss_cache << name
          end
          nil
        end

        private

        def candidate_definition_uris(name, exclude_uri: nil)
          matcher = definition_line_matcher(name)
          open_uris, indexed_uris = @document_state_mutex.synchronize do
            [@open_documents.keys, @indexed_documents.keys]
          end

          ordered_uris = (open_uris + indexed_uris).uniq
          warmed_candidates = nil
          warmed_uris = nil
          @definition_cache_mutex.synchronize do
            warmed_candidates = @definition_candidate_uris[name].dup
            warmed_uris = @definition_names_by_uri.keys.to_set
          end

          matches = warmed_candidates.to_a.filter_map do |doc_uri|
            next if doc_uri == exclude_uri

            doc_uri
          end

          ordered_uris.each do |doc_uri|
            next if doc_uri == exclude_uri
            next if warmed_uris.include?(doc_uri)

            content = get_content(doc_uri)
            next if content.empty?
            next unless content.match?(matcher)

            warm_definition_candidates_for_uri(doc_uri, content)
            matches << doc_uri
          end

          matches.uniq
        end

        def definition_line_matcher(name)
          /#{DEFINITION_LINE_PREFIX}#{Regexp.escape(name)}\b/
        end

        def cache_definition_entry(name, entry)
          @definition_cache_mutex.synchronize do
            entries = (@definition_index[name] ||= [])
            return if entries.any? { |existing| existing[:uri] == entry[:uri] && existing[:token].line == entry[:token].line && existing[:token].column == entry[:token].column }

            entries << entry
          end
        end

        def start_definition_warmup
          return if @definition_warmup_thread&.alive?

          @definition_warmup_thread = Thread.new do
            Thread.current.name = 'mt-lsp-def-warmup' if Thread.current.respond_to?(:name=)

            loop do
              uri = @definition_warmup_queue.pop
              break if uri == :__stop__

              content = get_content(uri)
              warm_definition_candidates_for_uri(uri, content)
            end
          rescue StandardError => e
            warn "LSP definition warmup error: #{e.message}"
          end
        end

        def stop_definition_warmup
          worker = @definition_warmup_thread
          return unless worker

          @definition_warmup_queue << :__stop__
          worker.join(1.0)
          if worker.alive?
            worker.kill
            worker.join
          end
          @definition_warmup_thread = nil
        rescue StandardError => e
          warn "LSP definition warmup shutdown error: #{e.message}"
        end

        def enqueue_definition_warmup(uri)
          return if uri.nil?

          start_definition_warmup unless @definition_warmup_thread&.alive?

          should_enqueue = false
          @definition_cache_mutex.synchronize do
            unless @definition_warmup_enqueued.include?(uri)
              @definition_warmup_enqueued << uri
              should_enqueue = true
            end
          end

          @definition_warmup_queue << uri if should_enqueue
        end

        def warm_definition_candidates_for_uri(uri, content)
          names = extract_definition_names(content)

          @definition_cache_mutex.synchronize do
            remove_definition_name_candidates_for_uri(uri)
            @definition_names_by_uri[uri] = names
            names.each { |name| @definition_candidate_uris[name] << uri }
            @definition_warmup_enqueued.delete(uri)
            @definition_miss_cache.clear unless names.empty?
          end
        end

        def remove_definition_name_candidates_for_uri(uri)
          names = @definition_names_by_uri.delete(uri)
          return unless names

          names.each do |name|
            next unless @definition_candidate_uris.key?(name)

            @definition_candidate_uris[name].delete(uri)
            @definition_candidate_uris.delete(name) if @definition_candidate_uris[name].empty?
          end
        end

        def extract_definition_names(content)
          return Set.new if content.empty?

          names = Set.new
          content.each_line do |line|
            match = line.match(DEFINITION_NAME_REGEX)
            names << match[1] if match
          end
          names
        end
      end
    end
  end
end
