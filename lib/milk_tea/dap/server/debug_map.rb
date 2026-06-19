# frozen_string_literal: true

module MilkTea
  module DAP
    class Server
      module ServerDebugMap
        private

        def load_debug_map(runnable_path)
          @debug_map = runnable_path ? DebugMap.load_for_binary(runnable_path) : nil
          @frame_debug_functions = {}
          @variables_reference_debug_functions = {}
        end

        def maybe_load_debug_map_from_backend_modules
          return if @debug_map
          return unless capability_enabled?("supportsModulesRequest")

          response = backend_request("modules", {})
          return unless response["success"]

          modules = response.dig("body", "modules")
          return unless modules.is_a?(Array)

          modules.each do |mod|
            candidate_path = dap_value(mod, "path") || dap_value(mod, "symbolFilePath")
            next if candidate_path.to_s.empty?

            candidate_path = File.expand_path(candidate_path)
            debug_map = DebugMap.load_for_binary(candidate_path)
            next unless debug_map

            @debug_map = debug_map
            @frame_debug_functions = {}
            @variables_reference_debug_functions = {}
            return
          end
        end

        def clear_debug_context
          @debug_map = nil
          @frame_debug_functions = {}
          @variables_reference_debug_functions = {}
          @backend_stopped_thread_id = nil
        end

        def rewrite_stack_trace_response(backend_response)
          return unless @debug_map
          return unless backend_response["success"]

          body = backend_response["body"]
          stack_frames = dap_value(body, "stackFrames")
          return unless stack_frames.is_a?(Array)

          @frame_debug_functions.clear
          stack_frames.each do |frame|
            function = @debug_map.function_for_c_name(dap_value(frame, "name"))
            next unless function

            dap_set(frame, "name", function.name)
            frame_id = normalize_reference_key(dap_value(frame, "id"))
            @frame_debug_functions[frame_id] = function if frame_id
          end
        end

        def rewrite_scopes_response(backend_response, frame_id)
          return unless backend_response["success"]

          normalized_frame_id = normalize_reference_key(frame_id)
          function = @frame_debug_functions[normalized_frame_id]

          body = backend_response["body"]
          scopes = dap_value(body, "scopes")
          return unless scopes.is_a?(Array)

          scopes.each do |scope|
            reference = normalize_reference_key(dap_value(scope, "variablesReference"))
            next unless reference

            scope_name = dap_value(scope, "name").to_s
            @variables_reference_debug_functions[reference] = {
              frame_id: normalized_frame_id,
              function: scope_name == "Locals" ? function : nil,
            }
          end
        end

        def rewrite_variables_response(backend_response, variables_reference)
          return unless @debug_map
          return unless backend_response["success"]

          function = debug_function_for_variables_reference(variables_reference)
          return unless function

          body = backend_response["body"]
          variables = dap_value(body, "variables")
          return unless variables.is_a?(Array)

          rewritten = variables.each_with_object([]) do |variable, kept|
            raw_name = dap_value(variable, "name").to_s
            entry = @debug_map.variable_for(function.linkage_name, raw_name)

            if entry
              dap_set(variable, "name", entry.name)
              kept << variable
              next
            end

            next if raw_name.start_with?("__mt_")

            kept << variable
          end

          dap_set(body, "variables", rewritten)
        end

        def rewrite_evaluate_arguments(arguments)
          rewritten = arguments.dup
          rewritten["expression"] = rewrite_expression_for_frame(arguments["expression"], arguments["frameId"])
          rewritten
        end

        def rewrite_set_expression_arguments(arguments)
          rewritten = arguments.dup
          rewritten["expression"] = rewrite_expression_for_frame(arguments["expression"], arguments["frameId"])
          rewritten["value"] = rewrite_expression_for_frame(arguments["value"], arguments["frameId"])
          rewritten
        end

        def rewrite_set_variable_arguments(arguments)
          rewritten = arguments.dup
          function = debug_function_for_variables_reference(arguments["variablesReference"])
          return rewritten unless function

          if (entry = @debug_map.source_variable_for(function.linkage_name, arguments["name"]))
            rewritten["name"] = entry.linkage_name
          end
          rewritten["value"] = rewrite_expression_for_function(arguments["value"], function)
          rewritten
        end

        def rewrite_data_breakpoint_info_arguments(arguments)
          rewritten = arguments.dup

          if arguments.key?("variablesReference")
            function = debug_function_for_variables_reference(arguments["variablesReference"])
            return rewritten unless function

            if (entry = @debug_map.source_variable_for(function.linkage_name, arguments["name"]))
              rewritten["name"] = entry.linkage_name
            end
            return rewritten
          end

          rewritten["name"] = rewrite_expression_for_frame(arguments["name"], arguments["frameId"])
          rewritten
        end

        def request_set_variable(arguments)
          return backend_request("setVariable", arguments) if backend_supports_set_variable?

          unless backend_supports_set_expression?
            return {
              "success" => false,
              "message" => "setVariable is not supported by the lldb-dap backend"
            }
          end

          context = variables_reference_context(arguments["variablesReference"])
          frame_id = context && context[:frame_id]
          unless frame_id
            return {
              "success" => false,
              "message" => "setVariable requires a scope frame context"
            }
          end

          set_expression_arguments = {
            "expression" => arguments["name"],
            "value" => arguments["value"],
            "frameId" => frame_id,
          }
          set_expression_arguments["format"] = arguments["format"] if arguments.key?("format")

          backend_request("setExpression", set_expression_arguments)
        end

        def rewrite_expression_for_frame(expression, frame_id)
          rewrite_expression_for_function(expression, debug_function_for_frame(frame_id))
        end

        def rewrite_expression_for_function(expression, function)
          return expression unless @debug_map
          return expression unless function
          return expression unless expression.is_a?(String)
          return expression if expression.empty?

          rewritten = +""
          index = 0
          while index < expression.length
            char = expression[index]
            if char == '"' || char == "'"
              index = copy_quoted_segment(expression, index, rewritten)
              next
            end

            if identifier_start_char?(char)
              start = index
              index += 1
              index += 1 while index < expression.length && identifier_continue_char?(expression[index])
              identifier = expression[start...index]
              if accessor_identifier?(expression, start)
                rewritten << identifier
                next
              end

              entry = @debug_map.source_variable_for(function.linkage_name, identifier)
              rewritten << (entry ? entry.linkage_name : identifier)
              next
            end

            rewritten << char
            index += 1
          end

          rewritten
        end

        def debug_function_for_frame(frame_id)
          @frame_debug_functions[normalize_reference_key(frame_id)]
        end

        def debug_function_for_variables_reference(variables_reference)
          context = variables_reference_context(variables_reference)
          context && context[:function]
        end

        def variables_reference_context(variables_reference)
          @variables_reference_debug_functions[normalize_reference_key(variables_reference)]
        end

        def copy_quoted_segment(expression, index, output)
          quote = expression[index]
          output << quote
          index += 1

          while index < expression.length
            char = expression[index]
            output << char
            index += 1

            if char == "\\" && index < expression.length
              output << expression[index]
              index += 1
              next
            end

            break if char == quote
          end

          index
        end

        def accessor_identifier?(expression, index)
          previous_index = index - 1
          previous_index -= 1 while previous_index >= 0 && whitespace_char?(expression[previous_index])
          return false if previous_index < 0
          return true if expression[previous_index] == "."

          return false unless expression[previous_index] == ">"

          previous_index -= 1
          previous_index -= 1 while previous_index >= 0 && whitespace_char?(expression[previous_index])
          previous_index >= 0 && expression[previous_index] == "-"
        end

        def identifier_start_char?(char)
          char.match?(/[A-Za-z_]/)
        end

        def identifier_continue_char?(char)
          char.match?(/[A-Za-z0-9_]/)
        end

        def whitespace_char?(char)
          char.match?(/\s/)
        end
      end
    end
  end
end
