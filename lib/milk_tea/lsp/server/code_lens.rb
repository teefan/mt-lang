# frozen_string_literal: true

module MilkTea
  module LSP
    class Server
      module ServerCodeLens
        private

        def handle_code_lens(params)
          uri = params.dig("textDocument", "uri")
          return [] unless uri

          symbols = @workspace.get_symbols(uri)
          return [] if symbols.empty?

          function_symbols = symbols.select { |s| s[:kind].to_s == "function" && s[:line] }
          function_symbols.map do |sym|
            line = sym[:line] - 1
            {
              range: {
                start: { line: line, character: 0 },
                end: { line: line, character: 0 },
              },
              data: {
                uri: uri,
                name: sym[:name],
              },
            }
          end
        rescue StandardError => e
          warn "Error in codeLens handler: #{e.message}"
          []
        end

        def handle_code_lens_resolve(params)
          data = params["data"] || params[:data]
          return params unless data.is_a?(Hash) || data.respond_to?(:[])

          name = data["name"] || data[:name]
          return params if name.to_s.empty?

          uri = data["uri"] || data[:uri]
          count = if uri
                    facts = @workspace.get_facts(uri)
                    if facts && module_level_name?(facts, name)
                      refs = module_level_reference_locations(uri, name, facts, include_declaration: true)
                      refs.length
                    else
                      ast = @workspace.get_ast(uri)
                      if ast && module_level_ast_name?(ast, name)
                        refs = module_level_reference_locations(uri, name, nil, include_declaration: true)
                        refs.length
                      else
                        refs = @workspace.find_all_references(name)
                        refs ? refs.length : 0
                      end
                    end
                  else
                    refs = @workspace.find_all_references(name)
                    refs ? refs.length : 0
                  end

          params["command"] = {
            "title" => "#{count} reference#{count == 1 ? "" : "s"}",
            "command" => "",
          }

          params
        rescue StandardError => e
          warn "Error in codeLens/resolve handler: #{e.message}"
          params
        end
      end
    end
  end
end
