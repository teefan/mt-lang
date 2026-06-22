# frozen_string_literal: true

module MilkTea
  module Parse
    module Attributes
      private

      def parse_attribute_applications
        attributes = []

        while match(:at)
          consume(:lbracket, "expected '[' after '@'")
          raise error(peek, "expected attribute in attribute list") if check(:rbracket)

          attributes.concat(parse_comma_separated_until(:rbracket) { parse_attribute_application })
          consume(:rbracket, "expected ']' after attributes")
          skip_newlines
        end

        attributes
      end

      def parse_attribute_application
        start_token = peek
        name = parse_attribute_name
        arguments = match(:lparen) ? parse_call_arguments : []
        AST::AttributeApplication.new(name:, arguments:, line: start_token.line, column: start_token.column)
      end

      def parse_attribute_name
        parts = [consume_attribute_name_component("expected attribute name").lexeme]
        while match(:dot)
          parts << consume_attribute_name_component("expected attribute name after '.'").lexeme
        end
        AST::QualifiedName.new(parts:)
      end

      def consume_attribute_name_component(message)
        consume_name_allowing_keywords(message)
      end

      def parse_struct_layout_attributes(attributes)
        packed = false
        alignment = nil

        attributes.each do |attribute|
          next unless attribute.name.parts.length == 1

          case attribute.name.parts.first
          when "packed"
            packed = true
          when "align"
            first_argument = attribute.arguments.first
            next unless first_argument && first_argument.name.nil? && first_argument.value.is_a?(AST::IntegerLiteral)

            alignment = first_argument.value.value
          end
        end

        [packed, alignment]
      end

      def reject_attributes!(attributes, kind_label = nil)
        return if attributes.empty?

        message = kind_label ? "attributes are not allowed on #{kind_label} declarations" : "attributes are not allowed on this declaration"
        raise error(peek, message)
      end
    end
  end
end
