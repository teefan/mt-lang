# frozen_string_literal: true

module MilkTea
  class SyntaxTokenStream
    def initialize(tokens)
      @tokens = tokens
    end

    def [](index)
      @tokens[index]
    end

    def length
      @tokens.length
    end

    def to_a
      @tokens
    end
  end

  class TriviaTokenStream
    attr_reader :tokens, :trivia

    def initialize(tokens, trivia)
      @tokens = tokens
      @trivia = trivia
    end
  end
end
