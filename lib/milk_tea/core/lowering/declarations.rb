# frozen_string_literal: true

module MilkTea
  module LowererDeclarations
    private

      def expanded_declarations
        @ctx.ast.declarations.flat_map do |decl|
          case decl
          when AST::WhenStmt
            val = compile_time_const_value(decl.discriminant)
            next [decl] if val.nil?

            chosen = decl.branches.find { |b| val == compile_time_const_value(b.pattern) }
            body = chosen ? chosen.body : (decl.else_body || [])
            body
          else
            [decl]
          end
        end
      end

      def lower_constants
        expanded_declarations.grep(AST::ConstDecl).filter_map do |decl|
          type = @ctx.values.fetch(decl.name).type
          const_value = @ctx.values.fetch(decl.name).const_value

          next if type == Types::BUILTIN_TYPE_META_TYPE

          if const_value && (decl.value.is_a?(AST::Call) || decl.value.is_a?(AST::Specialization))
            value = lower_const_value_literal(type, const_value)
          elsif const_value && (decl.block_body || decl.value.is_a?(AST::ExpressionList))
            value = lower_const_value_literal(type, const_value)
          elsif decl.block_body || decl.value.is_a?(AST::ExpressionList)
            raise LoweringError.new("constant #{decl.name} has no compile-time value", line: decl.line, column: decl.column)
          else
            value = lower_static_storage_initializer(decl.value, env: empty_env, expected_type: type)
          end

          IR::Constant.new(name: decl.name, linkage_name: value_c_name(decl.name), type:, value:)
        end
      end

      def lower_const_value_literal(type, const_value)
        case const_value
        when Integer
          value = if type.respond_to?(:integer_width) && (width = type.integer_width) && width < 64
                    mask = (1 << width) - 1
                    masked = const_value & mask
                    if type.respond_to?(:unsigned_integer?) && !type.unsigned_integer? && masked >= (1 << (width - 1))
                      masked - (1 << width)
                    else
                      masked
                    end
                  else
                    const_value
                  end
          IR::IntegerLiteral.new(value:, type:)
        when Float
          IR::FloatLiteral.new(value: const_value, type:)
        when String
          IR::StringLiteral.new(value: const_value, type:, cstring: false)
        when TrueClass, FalseClass
          IR::BooleanLiteral.new(value: const_value, type:)
        when Array
          element_type = type.respond_to?(:arguments) ? type.arguments.first : @ctx.types["int"]
          elements = const_value.map do |element|
            lower_const_value_literal(element_type, element)
          end
          IR::ArrayLiteral.new(type:, elements:)
        else
          IR::IntegerLiteral.new(value: 0, type:)
        end
      end

      def lower_globals
        expanded_declarations.filter_map do |decl|
          next unless decl.is_a?(AST::VarDecl) || decl.is_a?(AST::EventDecl)

          type = @ctx.values.fetch(decl.name).type
          ensure_event_runtime(type) if type.is_a?(Types::Event)
          value = if decl.is_a?(AST::VarDecl) && decl.value
                    lower_static_storage_initializer(decl.value, env: empty_env, expected_type: type)
                  else
                    IR::ZeroInit.new(type: type)
                  end
          IR::Global.new(name: decl.name, linkage_name: value_c_name(decl.name), type:, value:)
        end
      end

      def lower_opaques
        expanded_declarations.grep(AST::OpaqueDecl).map do |decl|
          opaque_type = @ctx.opaque_types.fetch(decl.name)
          IR::OpaqueDecl.new(
            name: decl.name,
            linkage_name: opaque_c_type_name(opaque_type),
            forward_declarable: opaque_forward_declarable?(opaque_type),
            source_module: @ctx.module_name,
          )
        end
      end

      def lower_imported_external_opaques
        each_raw_module_analysis.flat_map do |analysis|
          analysis.ast.declarations.grep(AST::OpaqueDecl).filter_map do |decl|
            opaque_type = analysis.types.fetch(decl.name)
            next unless forward_declarable_external_opaque?(opaque_type)

            IR::OpaqueDecl.new(name: decl.name, linkage_name: opaque_c_type_name(opaque_type), forward_declarable: true, source_module: analysis.module_name)
          end
        end.uniq { |decl| decl.linkage_name }
      end

      def lower_static_asserts
        expanded_declarations.grep(AST::StaticAssert).map do |statement|
          lower_static_assert(statement, env: empty_env)
        end
      end

      def lower_static_assert(statement, env:)
        condition_value = compile_time_const_value(statement.condition, env:)
        raise LoweringError, "static_assert condition must lower to a compile-time bool constant" unless condition_value == true || condition_value == false

        IR::StaticAssert.new(
          condition: IR::BooleanLiteral.new(value: condition_value, type: @ctx.types.fetch("bool")),
          message: lower_expression(statement.message, env:, expected_type: @ctx.types.fetch("str")),
        )
      end

      def lower_structs
        expanded_declarations.grep(AST::StructDecl).filter_map do |decl|
          next unless decl.type_params.empty?

          results = []
          lower_one_struct(decl, decl.name, results)
          results
        end.flatten
      end

      def lower_one_struct(decl, qualified_name, results)
        struct_type = @ctx.struct_types.fetch(qualified_name)
        fields = decl.fields.map do |field|
          IR::Field.new(name: field.name, type: struct_type.field(field.name))
        end
        decl.events.each do |event_decl|
          event_type = struct_type.event(event_decl.name)
          ensure_event_runtime(event_type)
          fields << IR::Field.new(name: event_type.hidden_field_name, type: event_type)
        end

        results << IR::StructDecl.new(name: decl.name, linkage_name: c_type_name(struct_type), fields:, packed: decl.packed, alignment: decl.alignment, source_module: @ctx.module_name)

        decl.nested_types.each do |nested|
          lower_one_struct(nested, "#{qualified_name}.#{nested.name}", results)
        end
      end

      def lower_unions
        expanded_declarations.grep(AST::UnionDecl).map do |decl|
          union_type = @ctx.union_types.fetch(decl.name)
          fields = decl.fields.map do |field|
            IR::Field.new(name: field.name, type: union_type.field(field.name))
          end
          IR::UnionDecl.new(name: decl.name, linkage_name: c_type_name(union_type), fields:, source_module: @ctx.module_name)
        end
      end

      def lower_enums
        expanded_declarations.filter_map do |decl|
          case decl
          when AST::EnumDecl, AST::FlagsDecl
            enum_type = @ctx.types.fetch(decl.name)
            backing_type = enum_type.backing_type
            members = decl.members.map do |member|
              value = lower_expression(member.value, env: empty_env, expected_type: backing_type)
              IR::EnumMember.new(name: member.name, linkage_name: enum_member_c_name(enum_type, member.name), value:)
            end

            IR::EnumDecl.new(
              name: decl.name,
              linkage_name: c_type_name(enum_type),
              backing_type:,
              members:,
              flags: decl.is_a?(AST::FlagsDecl),
            )
          end
        end
      end

      def lower_variants
        expanded_declarations.filter_map do |decl|
          next unless decl.is_a?(AST::VariantDecl)

          variant_type = @ctx.types.fetch(decl.name)
          next if variant_type.is_a?(Types::GenericVariantDefinition)

          outer_c = c_type_name(variant_type)
          arms = decl.arms.map do |arm|
            arm_c = "#{outer_c}_#{arm.name}"
            fields = arm.fields.map do |field|
              field_type = variant_type.arm(arm.name).fetch(field.name)
              IR::Field.new(name: field.name, type: field_type)
            end
            IR::VariantArm.new(name: arm.name, linkage_name: arm_c, fields:)
          end
          IR::VariantDecl.new(name: decl.name, linkage_name: outer_c, arms:, source_module: @ctx.module_name)
        end
      end
  end
end
