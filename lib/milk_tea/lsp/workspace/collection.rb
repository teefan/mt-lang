# frozen_string_literal: true

module MilkTea
  module LSP
    class Workspace
      module WorkspaceCollection
        # Return cached diagnostics for +uri+, re-collecting when content or lint tier changes.
        def collect_diagnostics(uri, lint_tier: :full)
          total_start = perf_logging? ? monotonic_time : nil
          content = get_content(uri)
          hash = content.hash
          normalized_lint_tier = Linter.normalize_lint_tier(lint_tier)
          cache_state = 'miss'
          lock_wait_ms = 0.0
          collect_ms = 0.0
          diagnostics = nil
          generation = nil
          cached_snapshot = nil
          @facts_cache_mutex.synchronize do
            generation = @facts_generation[uri]
            cached_snapshot = @tooling_snapshot_cache[uri]
            entry = @diagnostics_cache[uri]
            if entry && entry[:content_hash] == hash && entry[:lint_tier] == normalized_lint_tier
              cache_state = 'hit'
              diagnostics = entry[:diagnostics]
            end
          end
          return diagnostics if diagnostics

          lock_wait_start = total_start ? monotonic_time : nil
          @facts_state_mutex.synchronize do
            lock_wait_ms = elapsed_ms(lock_wait_start) if lock_wait_start
            @facts_cache_mutex.synchronize do
              generation = @facts_generation[uri]
              cached_snapshot = @tooling_snapshot_cache[uri]
              entry = @diagnostics_cache[uri]
              if entry && entry[:content_hash] == hash && entry[:lint_tier] == normalized_lint_tier
                cache_state = 'hit'
                diagnostics = entry[:diagnostics]
              end
            end

            unless diagnostics
              collect_start = total_start ? monotonic_time : nil
              result = Diagnostics.collect(
                uri,
                content,
                shared_module_cache: @shared_module_cache,
                source_overrides: file_backed_source_overrides,
                workspace_root_path: @workspace_root_path,
                dependency_resolution_mode: @dependency_resolution_mode,
                platform_override: @platform_override,
                sema_snapshot: cached_snapshot,
                strict_current_root_diagnostics: @strict_current_root_diagnostics_enabled,
                lint_tier: normalized_lint_tier,
              )
              collect_ms = elapsed_ms(collect_start) if collect_start
              diagnostics = result[:diagnostics]
              facts = result[:facts]
              snapshot = result[:sema_snapshot]
              @facts_cache_mutex.synchronize do
                if @facts_generation[uri] == generation
                  @tooling_snapshot_cache[uri] = snapshot if snapshot
                  @last_good_tooling_snapshot_cache[uri] = snapshot if snapshot&.facts
                  @facts_cache[uri] = facts if facts
                  @last_good_facts_cache[uri] = facts if facts
                  @document_module_names[uri] = facts.module_name if facts&.module_name
                  update_dependency_index(uri, facts)
                  @diagnostics_cache[uri] = {
                    content_hash: hash,
                    lint_tier: normalized_lint_tier,
                    diagnostics: diagnostics,
                  }
                else
                  cache_state = 'stale'
                end
              end
            end
          end
          diagnostics
        rescue StandardError => e
          cache_state = 'error'
          warn "  #{e.backtrace.first(6).join("\n  ")}" if e.backtrace
          []
        ensure
          if total_start
            result_count = diagnostics ? diagnostics.length : 0
            log_perf_breakdown(
              'workspace/collect_diagnostics',
              elapsed_ms(total_start),
              "uri=#{uri} mode=#{normalized_lint_tier} cache=#{cache_state} diagnostics=#{result_count} stages_ms=lock_wait:#{lock_wait_ms},collect:#{collect_ms}",
            )
          end
        end
      end
    end
  end
end
