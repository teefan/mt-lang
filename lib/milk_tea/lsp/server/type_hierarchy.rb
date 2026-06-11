# frozen_string_literal: true

module MilkTea
  module LSP
    class Server
      module ServerTypeHierarchy
        private

        TYPE_KIND_MAP = {
          struct: 22,
          enum: 13,
          flags: 13,
          variant: 13,
          union: 22,
          interface: 11,
        }.freeze

        def handle_prepare_type_hierarchy(params)
          text_document = params["textDocument"]
          position = params["position"]
          uri = text_document["uri"]
          lsp_line = position["line"]
          lsp_char = position["character"]

          facts = @workspace.get_facts(uri)
          return nil unless facts

          token = @workspace.find_token_at(uri, lsp_line, lsp_char)
          return nil unless token
          return nil unless token.type == :identifier

          type_name = token.lexeme

          type_entry = type_hierarchy_entry(facts, type_name, uri)
          return nil unless type_entry

          [type_entry]
        end

        def handle_supertypes(params)
          item = params["item"] || params[:item]
          data = item["data"] || item[:data]
          return [] unless data.is_a?(Hash) || data.respond_to?(:[])

          type_name = data["name"] || data[:name]
          uri = data["uri"] || data[:uri]
          return [] if type_name.to_s.empty?

          facts = @workspace.get_facts(uri)
          return [] unless facts

          results = []
          type_obj = facts.types[type_name]

          if type_obj && facts.implemented_interfaces.key?(type_obj)
            iface_names = facts.implemented_interfaces[type_obj]
            iface_names.each do |iface|
              entry = type_hierarchy_entry(facts, iface.name, uri)
              results << entry if entry
            end
          end

          results
        end

        def handle_subtypes(params)
          item = params["item"] || params[:item]
          data = item["data"] || item[:data]
          return [] unless data.is_a?(Hash) || data.respond_to?(:[])

          type_name = data["name"] || data[:name]
          return [] if type_name.to_s.empty?

          results = []
          seen = Set.new

          @workspace.all_documents.each do |doc_uri|
            facts = @workspace.get_facts(doc_uri)
            next unless facts

            results_for = collect_subtypes(facts, type_name, doc_uri)
            results_for.each do |entry|
              key = [entry[:name], entry[:uri]]
              next if seen.include?(key)

              seen << key
              results << entry
            end
          end

          results
        end

        private

        def type_hierarchy_entry(facts, name, uri, kind_override: nil)
          type_info = find_type_info(facts, name)
          return nil unless type_info

          kind = kind_override || TYPE_KIND_MAP[type_info[:kind]] || 22
          range = type_range(type_info)

          {
            name: name,
            kind: kind,
            uri: uri,
            range: range,
            selectionRange: range,
            data: {
              name: name,
              uri: uri,
              kind: type_info[:kind],
            },
          }
        end

        def find_type_info(facts, name)
          if (t = facts.types[name])
            ast = t.respond_to?(:ast_declaration) ? t.ast_declaration : nil
            return { kind: type_kind_from_object(t), line: ast&.line, column: ast.respond_to?(:column) ? ast.column : 0 }
          end

          if (t = facts.interfaces[name])
            ast = t.respond_to?(:ast_declaration) ? t.ast_declaration : nil
            return { kind: :interface, line: ast&.line, column: ast.respond_to?(:column) ? ast.column : 0 }
          end

          nil
        end

        def type_kind_from_object(type)
          case type
          when Types::Struct then type.is_a?(Types::Union) ? :union : :struct
          when Types::Variant then :variant
          when Types::EnumBase then type.respond_to?(:flags?) && type.flags? ? :flags : :enum
          else :struct
          end
        end

        def type_range(type_info)
          line = type_info[:line] ? type_info[:line] - 1 : 0
          col = type_info[:column] ? type_info[:column] - 1 : 0
          {
            start: { line: line, character: col },
            end: { line: line, character: col },
          }
        end

        def collect_subtypes(facts, target_name, uri)
          results = []

          facts.implemented_interfaces.each do |type_obj, ifaces|
            ifaces.each do |iface|
              next unless iface.respond_to?(:name) && iface.name == target_name

              type_name = type_obj.respond_to?(:name) ? type_obj.name : type_obj.to_s
              entry = type_hierarchy_entry(facts, type_name, uri)
              results << entry if entry
            end
          end

          results
        end
      end
    end
  end
end
