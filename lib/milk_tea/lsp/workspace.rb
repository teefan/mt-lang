# frozen_string_literal: true

module MilkTea
  module LSP
    # Manages open documents, AST cache, symbol index
    class Workspace
      def initialize
        @documents = {}      # uri -> content
        @ast_cache = {}      # uri -> ast
        @symbols_cache = {}  # uri -> [symbols]
      end

      def open_document(uri, content)
        @documents[uri] = content
        invalidate_cache(uri)
      end

      def close_document(uri)
        @documents.delete(uri)
        invalidate_cache(uri)
      end

      def update_document(uri, content)
        @documents[uri] = content
        invalidate_cache(uri)
      end

      def get_content(uri)
        @documents[uri] || ''
      end

      def get_ast(uri)
        @ast_cache[uri] ||= parse_document(uri)
      end

      def get_symbols(uri)
        @symbols_cache[uri] ||= extract_symbols(get_ast(uri))
      end

      def open_documents
        @documents.keys
      end

      private

      def invalidate_cache(uri)
        @ast_cache.delete(uri)
        @symbols_cache.delete(uri)
      end

      def parse_document(uri)
        content = get_content(uri)
        return nil if content.empty?

        Parser.parse(content, path: uri)
      rescue StandardError => e
        warn "Error parsing #{uri}: #{e.message}"
        nil
      end

      def extract_symbols(ast)
        return [] if ast.nil?

        symbols = []
        walk_ast(ast) do |node|
          symbol_info = extract_symbol(node)
          symbols << symbol_info if symbol_info
        end
        symbols
      end

      def walk_ast(node, &block)
        return if node.nil?

        block.call(node)

        case node
        when AST::SourceFile
          node.declarations.each { |decl| walk_ast(decl, &block) }
        when AST::FunctionDef
          # Don't walk into function body for now
        when AST::MethodDef
          # Don't walk into method body for now
        when AST::StructDecl
          # Don't walk into struct fields
        when AST::UnionDecl
          # Don't walk into union fields
        when AST::MethodsBlock
          node.methods.each { |method| walk_ast(method, &block) }
        end
      end

      def extract_symbol(node)
        case node
        when AST::FunctionDef
          {
            name: node.name,
            kind: 'function',
            line: 1,
            column: 1
          }
        when AST::StructDecl
          {
            name: node.name,
            kind: 'struct',
            line: 1,
            column: 1
          }
        when AST::UnionDecl
          {
            name: node.name,
            kind: 'union',
            line: 1,
            column: 1
          }
        when AST::EnumDecl
          {
            name: node.name,
            kind: 'enum',
            line: 1,
            column: 1
          }
        when AST::ConstDecl
          {
            name: node.name,
            kind: 'constant',
            line: 1,
            column: 1
          }
        else
          nil
        end
      end
    end
  end
end
