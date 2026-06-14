# frozen_string_literal: true

module MilkTea
  module LSP
    class Server
      FakeWarning = Struct.new(:line, :column, :length, :symbol_name, keyword_init: true)

      module ServerCodeActions
        private

      def handle_code_action(params)
        uri    = params.dig('textDocument', 'uri')
        return [] unless uri

        total_start = monotonic_time
        content = @workspace.get_content(uri)
        return [] unless content

        only_kinds = params.dig('context', 'only')
        want_quickfix  = only_kinds.nil? || only_kinds.any? { |k| k == 'quickFix' || k.start_with?('quickFix.') }
        want_fixall    = !only_kinds.nil? && only_kinds.any? { |k| k == 'source.fixAll' || k == 'source' || k.start_with?('source.') }

        actions = []
        lines = content.lines
        requested_diagnostics = params.dig('context', 'diagnostics') || []
        reserved_primitive_name_fixes = nil

        quickfix_start = monotonic_time

        # ── Per-diagnostic quickfix actions ──────────────────────────────────
        if want_quickfix
        requested_diagnostics.each do |diag|
          code = diag['code']
          message = diag['message'].to_s
          diag_line = diag.dig('range', 'start', 'line').to_i + 1  # 1-based
          diag_start_char = diag.dig('range', 'start', 'character').to_i
          diag_end_char = diag.dig('range', 'end', 'character').to_i
          source_line = lines[diag_line - 1].to_s

          if message.start_with?('cannot assign ') && !source_line.empty?
            expected_type = message[/\bexpected\s+(.+)\z/, 1]&.strip
            equal_index = source_line.index('=')
            if expected_type && !expected_type.empty? && equal_index
              rhs = source_line[(equal_index + 1)..]&.strip
              if rhs && !rhs.empty? && !rhs.start_with?("#{expected_type}<-")
                indent = source_line[/\A\s*/] || ''
                lhs = source_line[0..equal_index].rstrip
                simple_value = rhs.match?(/\A(?:[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*|[0-9][0-9_]*(?:\.[0-9][0-9_]*)?|0x[0-9A-Fa-f_]+|0b[01_]+|0o[0-7_]+)\z/)
                casted_rhs = simple_value ? "#{expected_type}<-#{rhs}" : "#{expected_type}<-(#{rhs})"
                new_line = "#{indent}#{lhs} #{casted_rhs}\n"
                actions << {
                  title: "Cast expression to #{expected_type}",
                  kind: 'quickFix',
                  diagnostics: [diag],
                  edit: {
                    changes: {
                      uri => [{
                        range: {
                          start: { line: diag_line - 1, character: 0 },
                          end:   { line: diag_line,     character: 0 }
                        },
                        newText: new_line
                      }]
                    }
                  }
                }
              end
            end
          end

          case code
          when 'reserved-primitive-name'
            reserved_primitive_name_fixes ||= Linter.collect_reserved_primitive_name_fixes(content, path: uri)
            fix = reserved_primitive_name_fixes.find do |candidate|
              declaration_site = candidate.sites.first
              declaration_site.line == diag_line && declaration_site.column == (diag_start_char + 1)
            end
            next unless fix

            edits = fix.sites.uniq { |site| [site.line, site.column] }.sort_by { |site| [site.line, site.column] }.map do |site|
              {
                range: {
                  start: { line: site.line - 1, character: site.column - 1 },
                  end:   { line: site.line - 1, character: site.column - 1 + site.length }
                },
                newText: fix.replacement_name
              }
            end

            actions << {
              title: "Rename '#{fix.original_name}' to '#{fix.replacement_name}'",
              kind: 'quickFix',
              diagnostics: [diag],
              edit: {
                changes: {
                  uri => edits
                }
              }
            }

          when 'prefer-let', 'redundant-ignored-match-binding', 'prefer-let-else',
               'prefer-var-else', 'redundant-bool-compare', 'redundant-else',
               'redundant-return', 'unused-import', 'trailing-list-comma'
            fake_warning = FakeWarning.new(
              line: diag_line,
              column: diag_start_char + 1,
              length: (diag_end_char - diag_start_char).positive? ? diag_end_char - diag_start_char : nil,
              symbol_name: message[/'([^']+)'/, 1],
            )
            edits = Linter::FixEngine.edits_for_rule(code, lines, fake_warning)
            next if edits.empty?

            actions << {
              title: Linter.quick_fix_title(code),
              kind: 'quickFix',
              diagnostics: [diag],
              edit: { changes: { uri => Linter::FixEngine.edits_to_lsp_text_edits(edits, uri) } }
            }

          when 'line-too-long'
            fix = Formatter.build_long_line_wrap_fix(
              content,
              diag_line - 1,
              max_line_length: Formatter.resolve_max_line_length(uri),
              path: uri,
            )
            next unless fix

            actions << {
              title: Linter.quick_fix_title('line-too-long'),
              kind: 'quickFix',
              diagnostics: [diag],
              edit: {
                changes: {
                  uri => [{
                    range: {
                      start: { line: fix[:start_line_idx], character: 0 },
                      end:   { line: fix[:end_line_idx] + 1, character: 0 }
                    },
                    newText: fix[:new_text]
                  }]
                }
              }
            }

          when 'shadow'
            # Offer to rename to _ prefix; editor will invoke textDocument/rename.
            # This action just annotates — the actual rename is a client-side refactor.
            actions << {
              title: "Add '_' prefix to suppress shadow warning",
              kind: 'quickFix',
              diagnostics: [diag]
            }

          when 'unused-param'
            next if source_line.empty?

            token = source_line[diag_start_char...diag_end_char].to_s
            token = token.strip
            next if token.empty?
            next if token.start_with?('_')

            replacement = "_#{token.gsub(/\A_+/, '')}"
            actions << {
              title: "Rename parameter '#{token}' to '#{replacement}'",
              kind: 'quickFix',
              diagnostics: [diag],
              edit: {
                changes: {
                  uri => [{
                    range: {
                      start: { line: diag_line - 1, character: diag_start_char },
                      end:   { line: diag_line - 1, character: diag_end_char }
                    },
                    newText: replacement
                  }]
                }
              }
            }

          when 'dead-assignment'
            next if source_line.empty?

            # Linter guarantees this write is overwritten before any read,
            # so dropping the statement is semantics-preserving.
            actions << {
              title: 'Remove dead assignment',
              kind: 'quickFix',
              diagnostics: [diag],
              edit: {
                changes: {
                  uri => [{
                    range: {
                      start: { line: diag_line - 1, character: 0 },
                      end:   { line: diag_line,     character: 0 }
                    },
                    newText: ''
                  }]
                }
              }
            }

          else
            next if source_line.empty?

            # Wrap unsafe-required pointer casts into a local unsafe block.
            if message == 'pointer cast requires unsafe' || message == 'ref to pointer cast requires unsafe'
              next if source_line.match?(/\A\s*unsafe:\s*\z/)

              indent = source_line[/\A\s*/] || ''
              body = source_line.sub(/\A\s*/, '').rstrip
              next if body.empty?

              wrapped = "#{indent}unsafe:\n#{indent}    #{body}\n"
              actions << {
                title: 'Wrap statement in unsafe block',
                kind: 'quickFix',
                diagnostics: [diag],
                edit: {
                  changes: {
                    uri => [{
                      range: {
                        start: { line: diag_line - 1, character: 0 },
                        end:   { line: diag_line,     character: 0 }
                      },
                      newText: wrapped
                    }]
                  }
                }
              }
            end

            # "match on Foo is missing cases: A, B, C"
            if message =~ /\Amatch on (\S+) is missing cases: (.+)\z/
              _scrutinee_type = $1
              missing = $2.split(', ').map(&:strip).reject(&:empty?)
              next if missing.empty?

              indent = source_line[/\A\s*/] || ''
              arm_indent = indent + '    '
              body_indent = arm_indent + '    '
              new_arms = missing.map do |arm_name|
                "#{arm_indent}#{arm_name}:\n#{body_indent}return\n"
              end.join

              match_end_line = find_match_end_line(lines, diag_line - 1)
              insert_line = match_end_line || diag_line - 1

              actions << {
                title: "Add missing match #{missing.length == 1 ? 'arm' : 'arms'}: #{missing.join(', ')}",
                kind: 'quickFix',
                diagnostics: [diag],
                edit: {
                  changes: {
                    uri => [{
                      range: {
                        start: { line: insert_line, character: 0 },
                        end:   { line: insert_line, character: 0 }
                      },
                      newText: new_arms
                    }]
                  }
                }
              }
            end

            # "unknown type X" or "unknown name Y" with import suggestion
            if message =~ /\Aunknown (?:type|callable) (\S+)\z/
              _type_name = $1
              suggestion = diag.dig('data', 'suggestion')
              next unless suggestion.is_a?(String)

              if suggestion =~ /did you mean ['"]([^'"]+)['"]/
                full_path = $1
                parts = full_path.split('.')
                next unless parts.length >= 2

                import_module = parts[0..-2].join('.')
                _import_type = parts.last

                actions << {
                  title: "Import #{full_path}",
                  kind: 'quickFix',
                  diagnostics: [diag],
                  edit: {
                    changes: {
                      uri => [{
                        range: {
                          start: { line: 0, character: 0 },
                          end:   { line: 0, character: 0 }
                        },
                        newText: "import #{import_module}\n"
                      }]
                    }
                  }
                }
              end
            end
          end
        end
        end # want_quickfix
        quickfix_ms = elapsed_ms(quickfix_start)

        # ── source.fixAll: apply all lint auto-fixes at once ───────────────
        # Skip for files outside the workspace root (library files) and very
        # large files to keep codeAction latency bounded.
        fixall_ms = 0.0
        fixall_skipped_reason = want_fixall ? skip_expensive_work_reason(uri, content) : 'not-requested'
        unless fixall_skipped_reason
          fixall_start = monotonic_time
          begin
            content_hash = content.hash
            cached_fixall = @fixall_cache[uri]
            if cached_fixall &&
               cached_fixall[:content_hash] == content_hash
              fixed = cached_fixall[:fixed]
            else
              fixed = begin
                Linter.fix_source(content, path: uri)
              rescue StandardError
                content
              end
              @fixall_cache[uri] = {
                content_hash: content_hash,
                fixed: fixed,
              }
            end
            if fixed != content
              line_count = content.count("\n")
              actions << {
                title: Linter::FIX_ALL_TITLE,
                kind: 'source.fixAll',
                edit: {
                  changes: {
                    uri => [{
                      range: {
                        start: { line: 0, character: 0 },
                        end:   { line: line_count + 1, character: 0 }
                      },
                      newText: fixed
                    }]
                  }
                }
              }
            end
          rescue StandardError => e
            warn "Error building source.fixAll action: #{e.message}"
          end
          fixall_ms = elapsed_ms(fixall_start)
        end

        elapsed = elapsed_ms(total_start)
        short_uri = shorten_uri(uri) || uri
        fixall_detail = fixall_skipped_reason ? "skipped(#{fixall_skipped_reason})" : "generated(ms=#{fixall_ms})"
        log_perf_breakdown('textDocument/codeAction', elapsed,
                           "uri=#{short_uri} bytes=#{content.bytesize} lines=#{content.count("\n") + 1} diagnostics=#{requested_diagnostics.length} actions=#{actions.length} fixAll=#{fixall_detail} stages_ms=quickfix:#{quickfix_ms},fixAll:#{fixall_ms}")

        actions
      rescue StandardError => e
        warn "Error in codeAction handler: #{e.message}"
        []
      end

      def handle_document_diagnostic(params)
        uri = params.dig('textDocument', 'uri')
        return { kind: 'full', items: [] } unless uri

        content = @workspace.get_content(uri)
        diagnostics = @workspace.collect_diagnostics(uri)
        fingerprint = diagnostics_fingerprint(content, diagnostics)
        previous_result_id = params['previousResultId']
        cached = @diagnostic_report_cache[uri]

        if cached && cached[:result_id] == previous_result_id && cached[:fingerprint] == fingerprint
          return {
            kind: 'unchanged',
            resultId: cached[:result_id]
          }
        end

        result_id = next_diagnostic_result_id(uri, fingerprint)
        @diagnostic_report_cache[uri] = {
          result_id: result_id,
          fingerprint: fingerprint
        }

        {
          kind: 'full',
          resultId: result_id,
          items: diagnostics
        }
      rescue StandardError => e
        warn "Error in documentDiagnostic handler: #{e.message}"
        { kind: 'full', items: [] }
      end

      def handle_workspace_diagnostic(params)
        previous_ids = params['previousResultIds'] || []
        prev_map = previous_ids.each_with_object({}) do |entry, h|
          h[entry['uri']] = entry['value'] if entry.is_a?(Hash) && entry['uri']
        end

        all_uris = @workspace.open_document_uris
        items = all_uris.filter_map do |uri|
          content = @workspace.get_content(uri)
          next if content.empty?

          diagnostics = @workspace.collect_diagnostics(uri)
          fingerprint = diagnostics_fingerprint(content, diagnostics)
          result_id = next_diagnostic_result_id(uri, fingerprint)

          cached = @workspace_diagnostic_cache[uri]
          if cached && cached[:result_id] == prev_map[uri] && cached[:fingerprint] == fingerprint
            { uri: uri, kind: 'unchanged', resultId: result_id, items: [] }
          else
            @workspace_diagnostic_cache[uri] = { result_id: result_id, fingerprint: fingerprint }
            { uri: uri, kind: 'full', resultId: result_id, items: diagnostics }
          end
        end

        { items: items }
      rescue StandardError => e
        warn "Error in workspace/diagnostic handler: #{e.message}"
        { items: [] }
      end

      def refresh_workspace_diagnostics
        @protocol.write_notification('workspace/diagnostic/refresh', nil)
      end

      def find_match_end_line(lines, match_start_idx)
        return nil if match_start_idx >= lines.length

        match_indent = lines[match_start_idx][/\A\s*/].length
        (match_start_idx + 1...lines.length).each do |i|
          line = lines[i]
          next if line.strip.empty?
          line_indent = line[/\A\s*/].length
          return i if line_indent <= match_indent
        end
        nil
      end
      end
    end
  end
end
