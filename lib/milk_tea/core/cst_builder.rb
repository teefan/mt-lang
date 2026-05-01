# frozen_string_literal: true

module MilkTea
  class CSTBuilder
    def self.build(source, path: nil)
      new(source, path:).build
    end

    def initialize(source, path: nil)
      @source = source
      @path = path
    end

    def build
      lexed = Lexer.lex_with_trivia(@source, path: @path)
      nodes = lexed.tokens.map { |token| CST::TokenNode.new(token:) }
      CST::SourceFile.new(source: @source, tokens: lexed.tokens, trivia: lexed.trivia, nodes:)
    end
  end
end
