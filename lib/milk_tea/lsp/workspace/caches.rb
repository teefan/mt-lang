# frozen_string_literal: true

module MilkTea
  module LSP
    class Workspace
      module WorkspaceCaches
        def get_content(uri)
          @document_state_mutex.synchronize do
            @open_documents[uri] || @indexed_documents[uri] || ''
          end
        end

        def get_tokens(uri)
          @tokens_cache[uri] ||= lex_document(uri)
        end

        def get_ast(uri)
          @ast_cache[uri] ||= parse_document(uri)
        end

        def get_facts(uri, allow_last_good_fallback: true)
          snapshot = get_tooling_snapshot(uri, allow_last_good_fallback:)
          snapshot&.facts
        end

        def get_tooling_snapshot(uri, allow_last_good_fallback: true)
          total_start = perf_logging? ? monotonic_time : nil
          cache_state = 'miss'
          lock_wait_ms = 0.0
          analyze_ms = 0.0
          snapshot = nil
          last_good_snapshot = nil
          generation = nil
          @facts_cache_mutex.synchronize do
            generation = @facts_generation[uri]
            cached = @tooling_snapshot_cache[uri]
            last_good_snapshot = @last_good_tooling_snapshot_cache[uri]
            if cached
              cache_state = 'hit'
              snapshot = cached
            end
          end
          return snapshot if snapshot

          compute_snapshot = lambda do
            @facts_cache_mutex.synchronize do
              generation = @facts_generation[uri]
              cached = @tooling_snapshot_cache[uri]
              if cached
                cache_state = 'hit'
                snapshot = cached
              end
            end

            unless snapshot
              analyze_start = total_start ? monotonic_time : nil
              snapshot = analyze_document(uri)
              analyze_ms = elapsed_ms(analyze_start) if analyze_start
              @facts_cache_mutex.synchronize do
                if @facts_generation[uri] == generation
                  @tooling_snapshot_cache[uri] = snapshot if snapshot
                  if snapshot&.facts
                    @facts_cache[uri] = snapshot.facts
                    @last_good_facts_cache[uri] = snapshot.facts
                    @last_good_tooling_snapshot_cache[uri] = snapshot
                  end
                  update_dependency_index(uri, snapshot&.facts) if snapshot
                else
                  cache_state = 'stale'
                  snapshot = @tooling_snapshot_cache[uri] || @last_good_tooling_snapshot_cache[uri]
                end
              end
            end
          end

          lock_wait_start = total_start ? monotonic_time : nil
          if @facts_state_mutex.try_lock
            begin
              compute_snapshot.call
            ensure
              @facts_state_mutex.unlock
            end
          elsif allow_last_good_fallback && last_good_snapshot
            cache_state = 'last_good'
            snapshot = last_good_snapshot
          else
            @facts_state_mutex.synchronize do
              lock_wait_ms = elapsed_ms(lock_wait_start) if lock_wait_start
              compute_snapshot.call
            end
          end
          snapshot
        ensure
          if total_start
            result_state = snapshot&.facts.nil? ? 'nil' : 'ok'
            log_perf_breakdown(
              'workspace/get_tooling_snapshot',
              elapsed_ms(total_start),
              "uri=#{uri} cache=#{cache_state} result=#{result_state} stages_ms=lock_wait:#{lock_wait_ms},analyze:#{analyze_ms}",
            )
          end
        end

        def get_symbols(uri)
          @symbols_cache[uri] ||= extract_symbols_from_tokens(uri)
        end

        def doc_comment_for_definition(uri, token)
          return nil unless token

          doc_comment_data_for_definition(uri, token)&.fetch(:raw_markdown, nil)
        end

        def doc_comment_data_for_definition(uri, token)
          return nil unless token

          docs_by_location = @doc_comments_cache[uri] ||= extract_doc_comments_for_definitions(uri)
          docs_by_location[doc_comment_key(token.line, token.column)]
        end

        def position_to_offset(uri, line, char)
          content = get_content(uri)
          line_char_to_offset(content, line, char)
        end

        def all_documents
          @document_state_mutex.synchronize do
            (@indexed_documents.keys + @open_documents.keys).uniq
          end
        end

        # Return all identifier token locations matching +name+ across all known documents.
        # Each result is { uri:, range: { start: { line:, character: }, end: ... } }.
        def find_all_references(name)
          results = []
          all_documents.each do |doc_uri|
            toks = get_tokens(doc_uri)
            next unless toks

            toks.each do |tok|
              next unless tok.type == :identifier && tok.lexeme == name

              results << {
                uri:   doc_uri,
                range: {
                  start: { line: tok.line - 1, character: tok.column - 1 },
                  end:   { line: tok.line - 1, character: tok.column - 1 + name.length }
                }
              }
            end
          end
          results
        end

        private

        # ── Cache management ────────────────────────────────────────────────────

        def invalidate_cache(uri, clear_last_good: false)
          @tokens_cache.delete(uri)
          @ast_cache.delete(uri)
          @symbols_cache.delete(uri)
          @doc_comments_cache.delete(uri)
          @facts_cache_mutex.synchronize do
            @facts_generation[uri] += 1
            @facts_cache.delete(uri)
            @tooling_snapshot_cache.delete(uri)
            @diagnostics_cache.delete(uri)
            @last_good_facts_cache.delete(uri) if clear_last_good
            @last_good_tooling_snapshot_cache.delete(uri) if clear_last_good
            @last_good_tokens_cache.delete(uri) if clear_last_good
            delete_dependency_index(uri) if clear_last_good
          end
          @definition_cache_mutex.synchronize do
            @definition_index.each_value { |entries| entries.delete_if { |e| e[:uri] == uri } }
            @definition_index.delete_if { |_k, v| v.empty? }
            remove_definition_name_candidates_for_uri(uri)
            @definition_miss_cache.clear
          end
        end
      end
    end
  end
end
