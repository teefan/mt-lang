# frozen_string_literal: true

module MilkTea
  module Serialization
    module TokenIR
      module_function

      def serialize(tokens)
        tokens.map { |t| serialize_token(t) }
      end

      def deserialize(array)
        array.map { |h| deserialize_token(h) }
      end

      def serialize_token(token)
        {
          _t: "Token",
          type: token.type.to_s,
          lexeme: token.lexeme,
          literal: serialize_literal(token.literal),
          line: token.line,
          column: token.column,
          start_offset: token.start_offset,
          end_offset: token.end_offset,
          leading_trivia: (token.leading_trivia || []).map { |tr| serialize_trivia(tr) },
          trailing_trivia: (token.trailing_trivia || []).map { |tr| serialize_trivia(tr) },
        }
      end

      def deserialize_token(h)
        Token.new(
          type: h["type"].to_sym,
          lexeme: h["lexeme"],
          literal: deserialize_literal(h["literal"]),
          line: h["line"],
          column: h["column"],
          start_offset: h["start_offset"],
          end_offset: h["end_offset"],
          leading_trivia: (h["leading_trivia"] || []).map { |tr| deserialize_trivia(tr) },
          trailing_trivia: (h["trailing_trivia"] || []).map { |tr| deserialize_trivia(tr) },
        )
      end

      def serialize_trivia(trivia)
        {
          _t: "TriviaToken",
          kind: trivia.kind.to_s,
          text: trivia.text,
          line: trivia.line,
          column: trivia.column,
          start_offset: trivia.start_offset,
          end_offset: trivia.end_offset,
        }
      end

      def deserialize_trivia(h)
        TriviaToken.new(
          kind: h["kind"].to_sym,
          text: h["text"],
          line: h["line"],
          column: h["column"],
          start_offset: h["start_offset"],
          end_offset: h["end_offset"],
        )
      end

      def serialize_literal(literal)
        return nil if literal.nil?

        case literal
        when Integer
          { _t: "int", v: literal }
        when Float
          { _t: "float", v: literal.nan? ? "nan" : literal.infinite? ? (literal.positive? ? "inf" : "-inf") : literal }
        when String
          { _t: "str", v: literal }
        when TrueClass, FalseClass
          { _t: "bool", v: literal }
        else
          { _t: "unknown", v: literal.inspect }
        end
      end

      def deserialize_literal(h)
        return nil if h.nil?

        case h["_t"]
        when "int" then h["v"]
        when "float"
          case h["v"]
          when "nan" then Float::NAN
          when "inf" then Float::INFINITY
          when "-inf" then -Float::INFINITY
          else h["v"]
          end
        when "str" then h["v"]
        when "bool" then h["v"]
        else nil
        end
      end
    end
  end
end
