# frozen_string_literal: true

require_relative "pretty_printer/base_formatter"
require_relative "pretty_printer/ast_formatter"
require_relative "pretty_printer/ir_formatter"

module MilkTea
  module PrettyPrinter
    def self.format_ast(node, trivia: [])
      ASTFormatter.new.format(node, trivia:)
    end

    def self.format_ir(node)
      IRFormatter.new.format(node)
    end
  end
end
