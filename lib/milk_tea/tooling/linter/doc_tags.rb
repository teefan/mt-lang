# frozen_string_literal: true

module MilkTea
  class Linter
    module LinterDocTags
      private

      def emit_doc_tag_warnings(source_file)
        return if @source_lines.empty?
  
        each_doc_comment_definition(source_file) do |declaration, doc_lines|
          parsed = parse_doc_tag_block(doc_lines)
  
          parsed[:errors].each do |error|
            @warnings << Warning.new(
              path: @path,
              line: error[:line],
              column: error[:column],
              length: error[:length],
              code: "doc-tag",
              message: error[:message],
              severity: :hint,
            )
          end
  
          validate_doc_tags_for_declaration(declaration, parsed[:tags])
        end
      end
      def each_doc_comment_definition(source_file)
        declarations = source_file.declarations.flat_map do |declaration|
          case declaration
          when AST::ExtendingBlock
            declaration.methods
          else
            declaration
          end
        end
  
        declarations.each do |declaration|
          docs = collect_doc_comment_block_for_line(declaration.line)
          next if docs.nil? || docs.empty?
  
          yield declaration, docs
        end
      end
  
      def collect_doc_comment_block_for_line(line)
        index = line.to_i - 2
        return nil if index.negative?
  
        docs = []
        while index >= 0
          stripped = @source_lines[index].to_s.strip
          break if stripped.empty?
          break unless stripped.start_with?('##')
  
          docs << {
            line: index + 1,
            text: stripped.sub(/\A##\s?/, ''),
          }
          index -= 1
        end
  
        return nil if docs.empty?
  
        docs.reverse
      end
      def parse_doc_tag_block(lines)
        tags = {
          params: [],
          returns: nil,
          throws: [],
          see: [],
        }
        errors = []
  
        lines.each do |entry|
          text = entry[:text].to_s
          match = text.match(/\A\s*@([A-Za-z_][A-Za-z0-9_-]*)(?:\s+(.*))?\z/)
          next unless match
  
          tag = match[1].to_s.downcase
          payload = match[2].to_s.strip
          column = doc_tag_column(entry[:line])
  
          case tag
          when 'param'
            if payload.empty?
              errors << {
                line: entry[:line],
                column: column,
                length: 6,
                message: 'doc tag @param requires a parameter name',
              }
              next
            end
  
            name_match = payload.match(/\A([A-Za-z_][A-Za-z0-9_]*)(?:\s+(.*))?\z/)
            unless name_match
              errors << {
                line: entry[:line],
                column: column,
                length: 6,
                message: 'doc tag @param has an invalid parameter name',
              }
              next
            end
  
            tags[:params] << {
              name: name_match[1],
              text: name_match[2].to_s.strip,
              line: entry[:line],
              column: column,
            }
          when 'return', 'returns'
            tags[:returns] = {
              text: payload,
              line: entry[:line],
              column: column,
            }
          when 'throws', 'throw'
            tags[:throws] << {
              text: payload,
              line: entry[:line],
              column: column,
            }
          when 'see'
            tags[:see] << {
              text: payload,
              line: entry[:line],
              column: column,
            }
          else
            errors << {
              line: entry[:line],
              column: column,
              length: tag.length + 1,
              message: "unknown doc tag @#{tag}",
            }
          end
        end
  
        {
          tags: tags,
          errors: errors,
        }
      end
      def validate_doc_tags_for_declaration(declaration, tags)
        callable = declaration.respond_to?(:params) && declaration.respond_to?(:return_type)
        param_tags = Array(tags[:params])
        return_tag = tags[:returns]
  
        unless callable
          ([*param_tags, return_tag].compact).each do |tag_entry|
            @warnings << Warning.new(
              path: @path,
              line: tag_entry[:line],
              column: tag_entry[:column],
              length: 1,
              code: 'doc-tag',
              message: 'callable doc tags are only valid on function and method declarations',
              severity: :hint,
            )
          end
          return
        end
  
        params = Array(declaration.params)
        param_names = params.map(&:name)
        param_name_set = param_names.to_set
  
        param_tags.each do |tag_entry|
          next if param_name_set.include?(tag_entry[:name])
  
          @warnings << Warning.new(
            path: @path,
            line: tag_entry[:line],
            column: tag_entry[:column],
            length: tag_entry[:name].length,
            code: 'doc-tag',
            message: "doc tag @param '#{tag_entry[:name]}' does not match any parameter in '#{declaration.name}'",
            severity: :hint,
            symbol_name: tag_entry[:name],
          )
        end
  
        return unless return_tag
  
        return_type_text = declaration.return_type.to_s
        return unless return_type_text == 'void'
  
        @warnings << Warning.new(
          path: @path,
          line: return_tag[:line],
          column: return_tag[:column],
          length: 7,
          code: 'doc-tag',
          message: "doc tag @return is stale for '#{declaration.name}' because it returns void",
          severity: :hint,
        )
      end
  
      def doc_tag_column(line)
        text = @source_lines[line.to_i - 1].to_s
        at_index = text.index('@')
        return 1 if at_index.nil?
  
        at_index + 1
      end
    end
  end
end
