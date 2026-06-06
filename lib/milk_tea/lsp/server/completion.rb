# frozen_string_literal: true

module MilkTea
  module LSP
    class Server
      module ServerCompletion
        private

      def handle_completion(params)
        stages = new_perf_stages
        total_start = stages ? monotonic_time : nil
        uri      = params['textDocument']['uri']
        lsp_line = params['position']['line']
        lsp_char = params['position']['character']
        branch = 'none'
        item_count = 0

        facts = measure_perf_stage(stages, 'facts') { @workspace.get_facts(uri) }
        unless facts
          branch = 'no-facts'
          return { isIncomplete: false, items: [] }
        end

        prefix = measure_perf_stage(stages, 'prefix') { current_word_prefix(uri, lsp_line, lsp_char) }

        # When user is typing after '.', return module members or method completions.
        dot_recv = nil
        dot_recv_path = nil
        measure_perf_stage(stages, 'receiver_context') do
          dot_recv = @workspace.find_dot_receiver(uri, lsp_line, lsp_char)
          dot_recv_path = @workspace.find_dot_receiver_path(uri, lsp_line, lsp_char)
        end
        if dot_recv
          # Module member access: rl.init_window, rl.RAYWHITE, etc.
          if (module_binding = facts.imports[dot_recv])
            branch = 'module'
            items = measure_perf_stage(stages, 'build') do
              result = []
              module_binding.functions.each do |fname, binding|
                next unless prefix.empty? || fname.start_with?(prefix)
                params_str = format_params(binding.type.params)
                result << {
                  label:      fname,
                  kind:       3,  # Function
                  detail:     "function #{fname}(#{params_str}) -> #{binding.type.return_type}",
                  insertText: fname,
                  sortText:   "0_#{fname}"
                }
              end
              module_binding.values.each do |vname, binding|
                next unless prefix.empty? || vname.start_with?(prefix)
                result << {
                  label:      vname,
                  kind:       6,  # Variable
                  detail:     "#{vname}: #{binding.type}",
                  insertText: vname,
                  sortText:   "1_#{vname}"
                }
              end
              module_binding.types.each do |tname, _type|
                next unless prefix.empty? || tname.start_with?(prefix)
                result << {
                  label:      tname,
                  kind:       7,  # Class
                  detail:     "type #{tname}",
                  insertText: tname,
                  sortText:   "2_#{tname}"
                }
              end
              result
            end
            item_count = items.length
            return { isIncomplete: false, items: items }
          end
          if (type_receiver = measure_perf_stage(stages, 'type_receiver') { resolve_type_receiver_info(facts, dot_recv, dot_recv_path) })
            receiver_label = type_receiver[:label]
            type = type_receiver[:type]

            # Enum/Flags member access: Color.RED, KeyboardKey.A, etc.
            if type.is_a?(Types::EnumBase)
              branch = 'enum-members'
              items = measure_perf_stage(stages, 'build') do
                type.members.filter_map do |mname|
                  next if !prefix.empty? && !mname.start_with?(prefix)
                  {
                    label:      mname,
                    kind:       20, # EnumMember
                    detail:     "#{receiver_label}.#{mname}",
                    insertText: mname,
                    sortText:   "0_#{mname}"
                  }
                end
              end
              item_count = items.length
              return { isIncomplete: false, items: items }
            end

            # Variant arm access: Option.none, Result.success, etc.
            if type.is_a?(Types::Variant)
              branch = 'variant-arms'
              items = measure_perf_stage(stages, 'build') do
                type.arm_names.filter_map do |aname|
                  next if !prefix.empty? && !aname.start_with?(prefix)
                  {
                    label:      aname,
                    kind:       20, # EnumMember
                    detail:     "#{receiver_label}.#{aname}",
                    insertText: aname,
                    sortText:   "0_#{aname}"
                  }
                end
              end
              item_count = items.length
              return { isIncomplete: false, items: items }
            end

            items = measure_perf_stage(stages, 'build') { completion_items_for_type_receiver(facts, type, prefix) }
            unless items.empty?
              branch = 'type-receiver'
              item_count = items.length
              return { isIncomplete: false, items: items }
            end
          end

          if (receiver_type = measure_perf_stage(stages, 'value_receiver') { resolve_dot_receiver_value_type(facts, dot_recv, lsp_line + 1, lsp_char + 1) })
            items = measure_perf_stage(stages, 'build') { completion_items_for_value_receiver(facts, receiver_type, prefix) }
            unless items.empty?
              branch = 'value-receiver'
              item_count = items.length
              return { isIncomplete: false, items: items }
            end
          end

          # Method completions on a non-module receiver.
          branch = 'method-fallback'
          method_items = measure_perf_stage(stages, 'build') do
            result = []
            facts.methods.each do |_recv_type, methods|
              methods.each do |mname, binding|
                next unless prefix.empty? || mname.start_with?(prefix)

                params_str = format_params(binding.type.params)
                result << {
                  label:      mname,
                  kind:       2,  # Method
                  detail:     "#{mname}(#{params_str}) -> #{binding.type.return_type}",
                  insertText: mname,
                  sortText:   "0_#{mname}"
                }
              end
            end
            result
          end
          item_count = method_items.length
          return { isIncomplete: false, items: method_items }
        end

        branch = 'global'
        items = measure_perf_stage(stages, 'build') do
          result = []
          function_docs_cache = {}

          # Functions
          facts.functions.each do |name, binding|
            next unless prefix.empty? || name.start_with?(prefix)

            params_str = format_params(binding.type.params)
            entry = {
              label:        name,
              kind:         3,  # Function
              detail:       "function #{name}(#{params_str}) -> #{binding.type.return_type}",
              insertText:   name,
              insertTextFormat: 1,
              sortText:     "0_#{name}"
            }

            docs = completion_function_documentation(uri, name, cache: function_docs_cache)
            unless docs.empty?
              entry[:documentation] = {
                kind: 'markdown',
                value: docs,
              }
            end

            result << entry
          end

          # Types
          builtin_names = Sema::INSTALLABLE_BUILTIN_TYPE_NAMES
          facts.types.each do |name, type|
            next if builtin_names.include?(name)
            next unless prefix.empty? || name.start_with?(prefix)

            kind = case type
                   when Types::StructInstance then 22 # Struct
                   when Types::EnumBase, Types::Variant then 13 # Enum
                   else 7 # Class/type
                   end

            result << {
              label:        name,
              kind:         kind,
              detail:       "type #{name}",
              insertText:   name,
              insertTextFormat: 1,
              sortText:     "1_#{name}"
            }
          end

          # Imported modules
          facts.imports.each do |name, module_binding|
            next unless prefix.empty? || name.start_with?(prefix)

            result << {
              label:        name,
              kind:         9,  # Module
              detail:       "module #{module_binding.name}",
              insertText:   name,
              insertTextFormat: 1,
              sortText:     "2_#{name}"
            }
          end

          # Values
          facts.values.each do |name, binding|
            next unless prefix.empty? || name.start_with?(prefix)

            result << {
              label:        name,
              kind:         6,  # Variable
              detail:       "#{name}: #{binding.type}",
              insertText:   name,
              insertTextFormat: 1,
              sortText:     "3_#{name}"
            }
          end

          result
        end

        item_count = items.length
        { isIncomplete: false, items: items }
      rescue StandardError => e
        branch = 'error'
        warn "Error in completion handler: #{e.message}"
        { isIncomplete: false, items: [] }
      ensure
        log_request_stage_breakdown('textDocument/completion', total_start, uri: uri, stages: stages, summary: "branch=#{branch} items=#{item_count}")
      end

      def completion_items_for_type_receiver(facts, receiver_type, prefix)
        methods_for_receiver_type(facts, receiver_type).filter_map do |mname, binding|
          next unless binding.ast.is_a?(AST::MethodDef) && binding.ast.kind == :static

          display_name = mname.delete_prefix("static:")
          next unless prefix.empty? || display_name.start_with?(prefix)

          params_str = format_params(binding.type.params)
          {
            label:      display_name,
            kind:       2,  # Method
            detail:     "#{display_name}(#{params_str}) -> #{binding.type.return_type}",
            insertText: display_name,
            sortText:   "0_#{display_name}"
          }
        end
      end

      def resolve_type_receiver_info(facts, receiver_name, receiver_path)
        if facts.types.key?(receiver_name)
          type = facts.types.fetch(receiver_name)
          module_name = type.respond_to?(:module_name) ? type.module_name : facts.module_name
          return { label: receiver_name, type:, module_name: }
        end

        return nil unless receiver_path&.include?('.')

        module_alias, type_name = receiver_path.split('.', 2)
        return nil unless module_alias && type_name

        module_binding = facts.imports[module_alias]
        return nil unless module_binding

        type = module_binding.types[type_name]
        return nil unless type

        { label: receiver_path, type:, module_name: module_binding.name }
      end

      def resolve_static_type_receiver_method(facts, receiver_name, receiver_path, method_name)
        receiver_info = resolve_type_receiver_info(facts, receiver_name, receiver_path)
        return nil unless receiver_info

        binding = static_method_binding_for_receiver(facts, receiver_info[:type], method_name)
        return nil unless binding

        receiver_info.merge(binding:)
      end

      def static_method_binding_for_receiver(facts, receiver_type, method_name)
        methods = methods_for_receiver_type(facts, receiver_type)
        binding = methods[method_name] || methods["static:#{method_name}"]
        return nil unless binding&.ast.is_a?(AST::MethodDef) && binding.ast.kind == :static

        binding
      end

      def resolve_static_type_reference_target(uri, token, facts)
        token_end_char = token.column - 1 + token.lexeme.length
        receiver_name = @workspace.find_dot_receiver(uri, token.line - 1, token_end_char)
        receiver_path = @workspace.find_dot_receiver_path(uri, token.line - 1, token_end_char)

        if (target = resolve_static_type_receiver_method(facts, receiver_name, receiver_path, token.lexeme))
          location = module_member_binding_location(uri, target[:module_name], token.lexeme, target[:binding])
          location ||= module_member_definition_location(uri, target[:module_name], token.lexeme)
          return target.merge(location:)
        end

        binding = static_method_binding_at_token(facts, token)
        return nil unless binding

        location = module_member_binding_location(uri, facts.module_name, token.lexeme, binding)
        location ||= module_member_definition_location(uri, facts.module_name, token.lexeme)
        {
          label: token.lexeme,
          type: binding.declared_receiver_type,
          module_name: facts.module_name,
          binding:,
          location:,
        }
      end

      def static_method_binding_at_token(facts, token)
        binding = method_binding_at_token(facts, token)
        return nil unless binding&.ast.is_a?(AST::MethodDef) && binding.ast.kind == :static

        binding
      end

      def static_type_method_references(target, include_declaration:)
        refs = @workspace.find_all_references(target[:binding].name)
        refs.filter do |ref|
          if location_matches_reference?(target[:location], ref)
            include_declaration
          else
            static_type_method_reference?(ref, target)
          end
        end
      end

      def static_type_method_reference?(ref, target)
        token = @workspace.find_token_at(ref[:uri], ref.dig(:range, :start, :line), ref.dig(:range, :start, :character))
        return false unless token&.type == :identifier

        facts = @workspace.get_facts(ref[:uri])
        return false unless facts

        token_end_char = ref.dig(:range, :end, :character)
        receiver_name = @workspace.find_dot_receiver(ref[:uri], ref.dig(:range, :start, :line), token_end_char)
        receiver_path = @workspace.find_dot_receiver_path(ref[:uri], ref.dig(:range, :start, :line), token_end_char)
        candidate = resolve_static_type_receiver_method(facts, receiver_name, receiver_path, token.lexeme)
        return false unless candidate

        candidate_location = module_member_binding_location(ref[:uri], candidate[:module_name], token.lexeme, candidate[:binding])
        candidate_location ||= module_member_definition_location(ref[:uri], candidate[:module_name], token.lexeme)
        same_location?(candidate_location, target[:location])
      end

      def location_matches_reference?(location, ref)
        return false unless location

        same_location?(location, {
          uri: ref[:uri],
          range: ref[:range]
        })
      end

      def same_location?(left, right)
        return false unless left && right

        left[:uri] == right[:uri] && left[:range] == right[:range]
      end

      def module_member_access_info(tokens, index)
        dot_index = previous_non_trivia_token_index(tokens, index)
        return nil unless dot_index && tokens[dot_index].type == :dot

        receiver_index = previous_non_trivia_token_index(tokens, dot_index)
        return nil unless receiver_index

        receiver = tokens[receiver_index]
        return nil unless receiver.type == :identifier

        { receiver: receiver.lexeme }
      end

      def completion_items_for_value_receiver(facts, receiver_type, prefix)
        items = []

        field_receiver_type = project_field_receiver_type_for_completion(receiver_type)
        if field_receiver_type.respond_to?(:fields)
          field_receiver_type.fields.each do |fname, ftype|
            next unless prefix.empty? || fname.start_with?(prefix)

            items << {
              label:      fname,
              kind:       10, # Property
              detail:     "#{fname}: #{ftype}",
              insertText: fname,
              sortText:   "0_#{fname}"
            }
          end
        end

        method_receiver_type = project_method_receiver_type_for_completion(receiver_type)
        methods = methods_for_receiver_type(facts, method_receiver_type)
        methods.each do |mname, binding|
          next unless prefix.empty? || mname.start_with?(prefix)

          params_str = format_params(binding.type.params)
          items << {
            label:      mname,
            kind:       2,  # Method
            detail:     "#{mname}(#{params_str}) -> #{binding.type.return_type}",
            insertText: mname,
            sortText:   "1_#{mname}"
          }
        end

        items
      end

      def methods_for_receiver_type(facts, receiver_type)
        methods = {}
        return methods unless receiver_type

        receiver_candidates = [receiver_type]
        dispatch_receiver_type = method_dispatch_receiver_type_for_completion(receiver_type)
        receiver_candidates << dispatch_receiver_type if dispatch_receiver_type != receiver_type

        receiver_candidates.each do |candidate|
          facts.methods.fetch(candidate, {}).each do |name, binding|
            methods[name] ||= binding
          end
        end

        facts.imports.each_value do |module_binding|
          receiver_candidates.each do |candidate|
            module_binding.methods.fetch(candidate, {}).each do |name, binding|
              methods[name] ||= binding
            end
          end
        end
        methods
      end

      def method_dispatch_receiver_type_for_completion(receiver_type)
        return receiver_type.definition if receiver_type.is_a?(Types::StructInstance)

        if receiver_type.is_a?(Types::Nullable)
          dispatch_base_type = method_dispatch_receiver_type_for_completion(receiver_type.base)
          return receiver_type if dispatch_base_type == receiver_type.base

          return Types::Nullable.new(dispatch_base_type)
        end

        return receiver_type unless receiver_type.is_a?(Types::GenericInstance)

        dispatch_receiver_type = Types::GenericInstance.new(
          receiver_type.name,
          receiver_type.arguments.each_with_index.map do |argument, index|
            argument.is_a?(Types::LiteralTypeArg) ? argument : Types::TypeVar.new("__receiver_arg#{index}")
          end,
        )

        dispatch_receiver_type == receiver_type ? receiver_type : dispatch_receiver_type
      end

      def project_field_receiver_type_for_completion(type)
        return type.arguments.first if ref_type_name?(type)
        return type.arguments.first if pointer_type_name?(type)

        type
      end

      def project_method_receiver_type_for_completion(type)
        return type.arguments.first if ref_type_name?(type)
        return type.arguments.first if pointer_type_name?(type)

        type
      end

      def field_owner_type(receiver_type)
        aggregate_type = project_field_receiver_type_for_completion(receiver_type)
        return aggregate_type.definition if aggregate_type.is_a?(Types::StructInstance)

        aggregate_type
      end

      def ref_type_name?(type)
        type.is_a?(Types::GenericInstance) && type.name == 'ref' && type.arguments.length == 1
      end

      def pointer_type_name?(type)
        type.is_a?(Types::GenericInstance) && %w[ptr const_ptr].include?(type.name) && type.arguments.length == 1
      end
      end
    end
  end
end
