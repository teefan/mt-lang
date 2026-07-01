# frozen_string_literal: true

module MilkTea
  class CBackend
    module TypeCollectors
      private

          def collect_checked_array_index_types(nullable_only: false)
            array_types = []
            emitted_functions.each do |function|
              collect_checked_array_index_types_from_statements(function.body, array_types, nullable_only:)
            end
            array_types.uniq
          end

          def collect_checked_span_index_types(nullable_only: false)
            span_types = []
            emitted_functions.each do |function|
              collect_checked_span_index_types_from_statements(function.body, span_types, nullable_only:)
            end
            span_types.uniq
          end

          def collect_checked_array_index_types_from_statements(statements, array_types, nullable_only: false)
            statements.each do |statement|
              case statement
              when IR::LocalDecl
                collect_checked_array_index_types_from_expression(statement.value, array_types, nullable_only:)
              when IR::Assignment
                collect_checked_array_index_types_from_expression(statement.target, array_types, nullable_only:)
                collect_checked_array_index_types_from_expression(statement.value, array_types, nullable_only:)
              when IR::BlockStmt
                collect_checked_array_index_types_from_statements(statement.body, array_types, nullable_only:)
              when IR::WhileStmt
                collect_checked_array_index_types_from_expression(statement.condition, array_types, nullable_only:)
                collect_checked_array_index_types_from_statements(statement.body, array_types, nullable_only:)
              when IR::ForStmt
                collect_checked_array_index_types_from_statements([statement.init], array_types, nullable_only:)
                collect_checked_array_index_types_from_expression(statement.condition, array_types, nullable_only:)
                collect_checked_array_index_types_from_statements(statement.body, array_types, nullable_only:)
                collect_checked_array_index_types_from_statements([statement.post], array_types, nullable_only:)
              when IR::IfStmt
                collect_checked_array_index_types_from_expression(statement.condition, array_types, nullable_only:)
                collect_checked_array_index_types_from_statements(statement.then_body, array_types, nullable_only:)
                collect_checked_array_index_types_from_statements(statement.else_body, array_types, nullable_only:) if statement.else_body
              when IR::SwitchStmt
                collect_checked_array_index_types_from_expression(statement.expression, array_types, nullable_only:)
                statement.cases.each do |switch_case|
                  collect_checked_array_index_types_from_statements(switch_case.body, array_types, nullable_only:)
                end
              when IR::StaticAssert
                collect_checked_array_index_types_from_expression(statement.condition, array_types, nullable_only:)
                collect_checked_array_index_types_from_expression(statement.message, array_types, nullable_only:)
              when IR::ReturnStmt
                collect_checked_array_index_types_from_expression(statement.value, array_types, nullable_only:) if statement.value
              when IR::ExpressionStmt
                collect_checked_array_index_types_from_expression(statement.expression, array_types, nullable_only:)
              end
            end
          end

          def collect_checked_array_index_types_from_expression(expression, array_types, nullable_only: false)
            case expression
            when IR::Member
              collect_checked_array_index_types_from_expression(expression.receiver, array_types, nullable_only:)
            when IR::Index
              collect_checked_array_index_types_from_expression(expression.receiver, array_types, nullable_only:)
              collect_checked_array_index_types_from_expression(expression.index, array_types, nullable_only:)
            when IR::CheckedIndex
              array_types << expression.receiver_type unless nullable_only
              collect_checked_array_index_types_from_expression(expression.receiver, array_types, nullable_only:)
              collect_checked_array_index_types_from_expression(expression.index, array_types, nullable_only:)
            when IR::NullableIndex
              array_types << expression.receiver_type
              collect_checked_array_index_types_from_expression(expression.receiver, array_types, nullable_only:)
              collect_checked_array_index_types_from_expression(expression.index, array_types, nullable_only:)
            when IR::Call
              collect_checked_array_index_types_from_expression(expression.callee, array_types, nullable_only:) unless expression.callee.is_a?(String)
              expression.arguments.each { |argument| collect_checked_array_index_types_from_expression(argument, array_types, nullable_only:) }
            when IR::Unary
              collect_checked_array_index_types_from_expression(expression.operand, array_types, nullable_only:)
            when IR::Binary
              collect_checked_array_index_types_from_expression(expression.left, array_types, nullable_only:)
              collect_checked_array_index_types_from_expression(expression.right, array_types, nullable_only:)
            when IR::Conditional
              collect_checked_array_index_types_from_expression(expression.condition, array_types, nullable_only:)
              collect_checked_array_index_types_from_expression(expression.then_expression, array_types, nullable_only:)
              collect_checked_array_index_types_from_expression(expression.else_expression, array_types, nullable_only:)
            when IR::ReinterpretExpr
              collect_checked_array_index_types_from_expression(expression.expression, array_types, nullable_only:)
            when IR::AddressOf
              collect_checked_array_index_types_from_expression(expression.expression, array_types, nullable_only:)
            when IR::Cast
              collect_checked_array_index_types_from_expression(expression.expression, array_types, nullable_only:)
            when IR::AggregateLiteral
              expression.fields.each { |field| collect_checked_array_index_types_from_expression(field.value, array_types, nullable_only:) }
            when IR::ArrayLiteral
              expression.elements.each { |element| collect_checked_array_index_types_from_expression(element, array_types, nullable_only:) }
            when IR::VariantLiteral
              expression.fields.each { |field| collect_checked_array_index_types_from_expression(field.value, array_types, nullable_only:) }
            end
          end

          def collect_checked_span_index_types_from_statements(statements, span_types, nullable_only: false)
            statements.each do |statement|
              case statement
              when IR::LocalDecl
                collect_checked_span_index_types_from_expression(statement.value, span_types, nullable_only:)
              when IR::Assignment
                collect_checked_span_index_types_from_expression(statement.target, span_types, nullable_only:)
                collect_checked_span_index_types_from_expression(statement.value, span_types, nullable_only:)
              when IR::BlockStmt
                collect_checked_span_index_types_from_statements(statement.body, span_types, nullable_only:)
              when IR::WhileStmt
                collect_checked_span_index_types_from_expression(statement.condition, span_types, nullable_only:)
                collect_checked_span_index_types_from_statements(statement.body, span_types, nullable_only:)
              when IR::ForStmt
                collect_checked_span_index_types_from_statements([statement.init], span_types, nullable_only:)
                collect_checked_span_index_types_from_expression(statement.condition, span_types, nullable_only:)
                collect_checked_span_index_types_from_statements(statement.body, span_types, nullable_only:)
                collect_checked_span_index_types_from_statements([statement.post], span_types, nullable_only:)
              when IR::IfStmt
                collect_checked_span_index_types_from_expression(statement.condition, span_types, nullable_only:)
                collect_checked_span_index_types_from_statements(statement.then_body, span_types, nullable_only:)
                collect_checked_span_index_types_from_statements(statement.else_body, span_types, nullable_only:) if statement.else_body
              when IR::SwitchStmt
                collect_checked_span_index_types_from_expression(statement.expression, span_types, nullable_only:)
                statement.cases.each do |switch_case|
                  collect_checked_span_index_types_from_statements(switch_case.body, span_types, nullable_only:)
                end
              when IR::StaticAssert
                collect_checked_span_index_types_from_expression(statement.condition, span_types, nullable_only:)
                collect_checked_span_index_types_from_expression(statement.message, span_types, nullable_only:)
              when IR::ReturnStmt
                collect_checked_span_index_types_from_expression(statement.value, span_types, nullable_only:) if statement.value
              when IR::ExpressionStmt
                collect_checked_span_index_types_from_expression(statement.expression, span_types, nullable_only:)
              end
            end
          end

          def collect_checked_span_index_types_from_expression(expression, span_types, nullable_only: false)
            case expression
            when IR::Member
              collect_checked_span_index_types_from_expression(expression.receiver, span_types, nullable_only:)
            when IR::Index, IR::CheckedIndex, IR::NullableIndex
              collect_checked_span_index_types_from_expression(expression.receiver, span_types, nullable_only:)
              collect_checked_span_index_types_from_expression(expression.index, span_types, nullable_only:)
            when IR::CheckedSpanIndex
              span_types << expression.receiver_type unless nullable_only
              collect_checked_span_index_types_from_expression(expression.receiver, span_types, nullable_only:)
              collect_checked_span_index_types_from_expression(expression.index, span_types, nullable_only:)
            when IR::NullableSpanIndex
              span_types << expression.receiver_type
              collect_checked_span_index_types_from_expression(expression.receiver, span_types, nullable_only:)
              collect_checked_span_index_types_from_expression(expression.index, span_types, nullable_only:)
            when IR::Call
              collect_checked_span_index_types_from_expression(expression.callee, span_types, nullable_only:) unless expression.callee.is_a?(String)
              expression.arguments.each { |argument| collect_checked_span_index_types_from_expression(argument, span_types, nullable_only:) }
            when IR::Unary
              collect_checked_span_index_types_from_expression(expression.operand, span_types, nullable_only:)
            when IR::Binary
              collect_checked_span_index_types_from_expression(expression.left, span_types, nullable_only:)
              collect_checked_span_index_types_from_expression(expression.right, span_types, nullable_only:)
            when IR::Conditional
              collect_checked_span_index_types_from_expression(expression.condition, span_types, nullable_only:)
              collect_checked_span_index_types_from_expression(expression.then_expression, span_types, nullable_only:)
              collect_checked_span_index_types_from_expression(expression.else_expression, span_types, nullable_only:)
            when IR::ReinterpretExpr
              collect_checked_span_index_types_from_expression(expression.expression, span_types, nullable_only:)
            when IR::AddressOf
              collect_checked_span_index_types_from_expression(expression.expression, span_types, nullable_only:)
            when IR::Cast
              collect_checked_span_index_types_from_expression(expression.expression, span_types, nullable_only:)
            when IR::AggregateLiteral
              expression.fields.each { |field| collect_checked_span_index_types_from_expression(field.value, span_types, nullable_only:) }
            when IR::ArrayLiteral
              expression.elements.each { |element| collect_checked_span_index_types_from_expression(element, span_types, nullable_only:) }
            when IR::VariantLiteral
              expression.fields.each { |field| collect_checked_span_index_types_from_expression(field.value, span_types, nullable_only:) }
            end
          end

          def collect_span_types
            span_types = []
            visited = {}

            all_emitted_top_level_values.each do |value|
              collect_span_type(value.type, span_types, visited)
            end

            @program.structs.each do |struct_decl|
              struct_decl.fields.each do |field|
                collect_span_type(field.type, span_types, visited)
              end
            end

            @program.unions.each do |union_decl|
              union_decl.fields.each do |field|
                collect_span_type(field.type, span_types, visited)
              end
            end

            each_variant_arm_field_type do |field_type|
              collect_span_type(field_type, span_types, visited)
            end

            emitted_functions.each do |function|
              collect_span_type(function.return_type, span_types, visited)
              function.params.each do |param|
                collect_span_type(param.type, span_types, visited)
              end
              collect_span_types_from_statements(function.body, span_types, visited)
            end

            @program.static_asserts.each do |statement|
              collect_span_types_from_expression(statement.condition, span_types, visited)
              collect_span_types_from_expression(statement.message, span_types, visited)
            end

            span_types.uniq
          end

          def collect_soa_types
            soa_types = []
            visited = {}

            emitted_functions.each do |function|
              collect_soa_type(function.return_type, soa_types, visited)
              function.params.each do |param|
                collect_soa_type(param.type, soa_types, visited)
              end
              collect_soa_from_statements(function.body, soa_types, visited)
            end

            @program.structs.each do |struct_decl|
              struct_decl.fields.each do |field|
                collect_soa_type(field.type, soa_types, visited)
              end
            end

            soa_types.uniq
          end

          def collect_soa_from_statements(statements, soa_types, visited)
            statements.each do |stmt|
              case stmt
              when IR::LocalDecl
                collect_soa_type(stmt.type, soa_types, visited)
              when IR::BlockStmt
                collect_soa_from_statements(stmt.body, soa_types, visited)
              when IR::IfStmt
                collect_soa_from_statements(stmt.then_body || [], soa_types, visited)
                collect_soa_from_statements(stmt.else_body || [], soa_types, visited)
              when IR::WhileStmt
                collect_soa_from_statements(stmt.body || [], soa_types, visited)
              when IR::ForStmt
                collect_soa_from_statements(stmt.body || [], soa_types, visited)
              end
            end
          end

          def collect_soa_type(type, soa_types, visited)
            return unless type
            return if visited[type]

            if type.is_a?(Types::SoA)
              soa_types << type
              visited[type] = true
            end
          end

          def collect_tuple_types
            tuple_types = []
            visited = {}

            emitted_functions.each do |function|
              r_collect_tuple_type(function.return_type, tuple_types, visited)
              function.params.each do |param|
                r_collect_tuple_type(param.type, tuple_types, visited)
              end
              collect_tuple_from_statements(function.body, tuple_types, visited)
            end

            @program.structs.each do |struct_decl|
              struct_decl.fields.each do |field|
                r_collect_tuple_type(field.type, tuple_types, visited)
              end
            end

            tuple_types.uniq
          end

          def collect_tuple_from_statements(statements, tuple_types, visited)
            statements&.each do |stmt|
              case stmt
              when IR::LocalDecl
                r_collect_tuple_type(stmt.type, tuple_types, visited)
              when IR::BlockStmt
                collect_tuple_from_statements(stmt.body, tuple_types, visited)
              when IR::IfStmt
                collect_tuple_from_statements(stmt.then_body, tuple_types, visited)
                collect_tuple_from_statements(stmt.else_body, tuple_types, visited)
              when IR::WhileStmt
                collect_tuple_from_statements(stmt.body, tuple_types, visited)
              when IR::ForStmt
                collect_tuple_from_statements(stmt.body, tuple_types, visited)
              end
            end
          end

          def r_collect_tuple_type(type, tuple_types, visited)
            return unless type
            return if visited[type]
            return unless type.is_a?(Types::Tuple)

            tuple_types << type
            visited[type] = true
            type.element_types.each { |et| r_collect_tuple_type(et, tuple_types, visited) }
          end

          def collect_generic_struct_decls
            collect_generic_struct_types.map do |type|
              fields = type.fields.map { |field_name, field_type| IR::Field.new(name: field_name, type: field_type) }
              if type.respond_to?(:events)
                type.events.each_value do |event_type|
                  fields << IR::Field.new(name: event_type.hidden_field_name, type: event_type)
                end
              end
              IR::StructDecl.new(
                name: type.to_s,
                linkage_name: named_type_c_name(type),
                fields:,
                packed: type.packed,
                alignment: type.alignment,
              )
            end
          end

          def collect_task_decls
            collect_task_types.map do |type|
              IR::StructDecl.new(
                name: type.to_s,
                linkage_name: task_type_name(type),
                fields: type.fields.map { |field_name, field_type| IR::Field.new(name: field_name, type: field_type) },
                packed: false,
                alignment: nil,
              )
            end
          end

          def collect_proc_decls
            collect_proc_types.map do |type|
              IR::StructDecl.new(
                name: type.to_s,
                linkage_name: proc_type_name(type),
                fields: proc_field_types(type).map { |field_name, field_type| IR::Field.new(name: field_name, type: field_type) },
                packed: false,
                alignment: nil,
              )
            end
          end

          def proc_field_types(type)
            void_ptr = Types::Registry.generic_instance("ptr", [Types::Registry.primitive("void")])

            {
              "env" => void_ptr,
              "invoke" => Types::Registry.function(nil, params: [Types::Registry.parameter("env", void_ptr)] + type.params, return_type: type.return_type),
              "release" => Types::Registry.function(nil, params: [Types::Registry.parameter("env", void_ptr)], return_type: Types::Registry.primitive("void")),
              "retain" => Types::Registry.function(nil, params: [Types::Registry.parameter("env", void_ptr)], return_type: Types::Registry.primitive("void")),
            }
          end

          def collect_str_buffer_decls
            collect_str_buffer_types.map do |type|
              IR::StructDecl.new(
                name: type.to_s,
                linkage_name: str_buffer_type_name(type),
                fields: [
                  IR::Field.new(name: "data", type: Types::Registry.generic_instance("array", [Types::Registry.primitive("char"), Types::LiteralTypeArg.new(str_buffer_storage_capacity(type))])),
                  IR::Field.new(name: "len", type: Types::Registry.primitive("ptr_uint")),
                  IR::Field.new(name: "dirty", type: Types::Registry.primitive("bool")),
                ],
                packed: false,
                alignment: nil,
              )
            end
          end

          def collect_generic_variant_decls
            collect_generic_variant_types.map do |type|
              outer_c = named_type_c_name(type)
              arms = type.arm_names.map do |arm_name|
                fields = type.arm(arm_name)
                IR::VariantArm.new(
                  name: arm_name,
                  linkage_name: "#{outer_c}_#{arm_name}",
                  fields: fields.map { |field_name, field_type| IR::Field.new(name: field_name, type: field_type) },
                )
              end
              IR::VariantDecl.new(name: type.to_s, linkage_name: outer_c, arms:)
            end
          end

          def collect_task_types
            task_types = []
            visited = {}

            all_emitted_top_level_values.each do |value|
              collect_task_type(value.type, task_types, visited)
            end

            @program.structs.each do |struct_decl|
              struct_decl.fields.each do |field|
                collect_task_type(field.type, task_types, visited)
              end
            end

            @program.unions.each do |union_decl|
              union_decl.fields.each do |field|
                collect_task_type(field.type, task_types, visited)
              end
            end

            each_variant_arm_field_type do |field_type|
              collect_task_type(field_type, task_types, visited)
            end

            emitted_functions.each do |function|
              collect_task_type(function.return_type, task_types, visited)
              function.params.each do |param|
                collect_task_type(param.type, task_types, visited)
              end
              collect_task_types_from_statements(function.body, task_types, visited)
            end

            @program.static_asserts.each do |statement|
              collect_task_types_from_expression(statement.condition, task_types, visited)
              collect_task_types_from_expression(statement.message, task_types, visited)
            end

            task_types
          end

          def collect_proc_types
            proc_types = []
            visited = {}

            all_emitted_top_level_values.each do |value|
              collect_proc_type(value.type, proc_types, visited)
            end

            @program.structs.each do |struct_decl|
              struct_decl.fields.each do |field|
                collect_proc_type(field.type, proc_types, visited)
              end
            end

            @program.unions.each do |union_decl|
              union_decl.fields.each do |field|
                collect_proc_type(field.type, proc_types, visited)
              end
            end

            each_variant_arm_field_type do |field_type|
              collect_proc_type(field_type, proc_types, visited)
            end

            emitted_functions.each do |function|
              collect_proc_type(function.return_type, proc_types, visited)
              function.params.each do |param|
                collect_proc_type(param.type, proc_types, visited)
              end
              collect_proc_types_from_statements(function.body, proc_types, visited)
            end

            @program.static_asserts.each do |statement|
              collect_proc_types_from_expression(statement.condition, proc_types, visited)
              collect_proc_types_from_expression(statement.message, proc_types, visited)
            end

            proc_types
          end

          def collect_proc_types_from_statements(statements, proc_types, visited)
            statements.each do |statement|
              case statement
              when IR::LocalDecl
                collect_proc_type(statement.type, proc_types, visited)
                collect_proc_types_from_expression(statement.value, proc_types, visited)
              when IR::Assignment
                collect_proc_types_from_expression(statement.target, proc_types, visited)
                collect_proc_types_from_expression(statement.value, proc_types, visited)
              when IR::BlockStmt
                collect_proc_types_from_statements(statement.body, proc_types, visited)
              when IR::WhileStmt
                collect_proc_types_from_expression(statement.condition, proc_types, visited)
                collect_proc_types_from_statements(statement.body, proc_types, visited)
              when IR::ForStmt
                collect_proc_types_from_statements([statement.init], proc_types, visited)
                collect_proc_types_from_expression(statement.condition, proc_types, visited)
                collect_proc_types_from_statements(statement.body, proc_types, visited)
                collect_proc_types_from_statements([statement.post], proc_types, visited)
              when IR::IfStmt
                collect_proc_types_from_expression(statement.condition, proc_types, visited)
                collect_proc_types_from_statements(statement.then_body, proc_types, visited)
                collect_proc_types_from_statements(statement.else_body, proc_types, visited) if statement.else_body
              when IR::SwitchStmt
                collect_proc_types_from_expression(statement.expression, proc_types, visited)
                statement.cases.each do |switch_case|
                  collect_proc_types_from_statements(switch_case.body, proc_types, visited)
                end
              when IR::StaticAssert
                collect_proc_types_from_expression(statement.condition, proc_types, visited)
                collect_proc_types_from_expression(statement.message, proc_types, visited)
              when IR::ReturnStmt
                collect_proc_types_from_expression(statement.value, proc_types, visited) if statement.value
              when IR::ExpressionStmt
                collect_proc_types_from_expression(statement.expression, proc_types, visited)
              end
            end
          end

          def collect_proc_types_from_expression(expression, proc_types, visited)
            case expression
            when IR::Member
              collect_proc_types_from_expression(expression.receiver, proc_types, visited)
            when IR::Index, IR::CheckedIndex, IR::CheckedSpanIndex, IR::NullableIndex, IR::NullableSpanIndex
              collect_proc_types_from_expression(expression.receiver, proc_types, visited)
              collect_proc_types_from_expression(expression.index, proc_types, visited)
            when IR::Call
              collect_proc_type(expression.type, proc_types, visited)
              collect_proc_types_from_expression(expression.callee, proc_types, visited) unless expression.callee.is_a?(String)
              expression.arguments.each { |argument| collect_proc_types_from_expression(argument, proc_types, visited) }
            when IR::Unary
              collect_proc_types_from_expression(expression.operand, proc_types, visited)
            when IR::Binary
              collect_proc_types_from_expression(expression.left, proc_types, visited)
              collect_proc_types_from_expression(expression.right, proc_types, visited)
            when IR::Conditional
              collect_proc_types_from_expression(expression.condition, proc_types, visited)
              collect_proc_types_from_expression(expression.then_expression, proc_types, visited)
              collect_proc_types_from_expression(expression.else_expression, proc_types, visited)
            when IR::ReinterpretExpr
              collect_proc_type(expression.target_type, proc_types, visited)
              collect_proc_type(expression.source_type, proc_types, visited)
              collect_proc_types_from_expression(expression.expression, proc_types, visited)
            when IR::SizeofExpr, IR::AlignofExpr, IR::OffsetofExpr
              collect_proc_type(expression.target_type, proc_types, visited)
            when IR::AddressOf, IR::Cast
              collect_proc_types_from_expression(expression.expression, proc_types, visited)
            when IR::AggregateLiteral
              collect_proc_type(expression.type, proc_types, visited)
              expression.fields.each { |field| collect_proc_types_from_expression(field.value, proc_types, visited) }
            when IR::ArrayLiteral
              expression.elements.each { |element| collect_proc_types_from_expression(element, proc_types, visited) }
            when IR::VariantLiteral
              collect_proc_type(expression.type, proc_types, visited)
              expression.fields.each { |field| collect_proc_types_from_expression(field.value, proc_types, visited) }
            end
          end

          def collect_proc_type(type, proc_types, visited)
            return unless type
            return if visited[type]

            visited[type] = true

            case type
            when Types::Nullable
              collect_proc_type(type.base, proc_types, visited)
            when Types::Task
              collect_proc_type(type.result_type, proc_types, visited)
            when Types::Proc
              proc_types << type
              type.params.each do |param|
                collect_proc_type(param.type, proc_types, visited)
              end
              collect_proc_type(type.return_type, proc_types, visited)
            when Types::Span
              collect_proc_type(type.element_type, proc_types, visited)
            when Types::StructInstance
              type.arguments.each do |argument|
                collect_proc_type(argument, proc_types, visited) unless argument.is_a?(Types::LiteralTypeArg)
              end
              type.fields.each_value do |field_type|
                collect_proc_type(field_type, proc_types, visited)
              end
            when Types::GenericInstance
              type.arguments.each do |argument|
                collect_proc_type(argument, proc_types, visited) unless argument.is_a?(Types::LiteralTypeArg)
              end
            when Types::Function
              type.params.each do |param|
                collect_proc_type(param.type, proc_types, visited)
              end
              collect_proc_type(type.return_type, proc_types, visited)
            when Types::Struct, Types::Union
              type.fields.each_value do |field_type|
                collect_proc_type(field_type, proc_types, visited)
              end
            when Types::Variant
              type.arm_names.each do |arm_name|
                type.arm(arm_name).each_value do |field_type|
                  collect_proc_type(field_type, proc_types, visited)
                end
              end
            end
          end

          def collect_task_types_from_statements(statements, task_types, visited)
            statements.each do |statement|
              case statement
              when IR::LocalDecl
                collect_task_type(statement.type, task_types, visited)
                collect_task_types_from_expression(statement.value, task_types, visited)
              when IR::Assignment
                collect_task_types_from_expression(statement.target, task_types, visited)
                collect_task_types_from_expression(statement.value, task_types, visited)
              when IR::BlockStmt
                collect_task_types_from_statements(statement.body, task_types, visited)
              when IR::WhileStmt
                collect_task_types_from_expression(statement.condition, task_types, visited)
                collect_task_types_from_statements(statement.body, task_types, visited)
              when IR::ForStmt
                collect_task_types_from_statements([statement.init], task_types, visited)
                collect_task_types_from_expression(statement.condition, task_types, visited)
                collect_task_types_from_statements(statement.body, task_types, visited)
                collect_task_types_from_statements([statement.post], task_types, visited)
              when IR::IfStmt
                collect_task_types_from_expression(statement.condition, task_types, visited)
                collect_task_types_from_statements(statement.then_body, task_types, visited)
                collect_task_types_from_statements(statement.else_body, task_types, visited) if statement.else_body
              when IR::SwitchStmt
                collect_task_types_from_expression(statement.expression, task_types, visited)
                statement.cases.each do |switch_case|
                  collect_task_types_from_statements(switch_case.body, task_types, visited)
                end
              when IR::StaticAssert
                collect_task_types_from_expression(statement.condition, task_types, visited)
                collect_task_types_from_expression(statement.message, task_types, visited)
              when IR::ReturnStmt
                collect_task_types_from_expression(statement.value, task_types, visited) if statement.value
              when IR::ExpressionStmt
                collect_task_types_from_expression(statement.expression, task_types, visited)
              end
            end
          end

          def collect_task_types_from_expression(expression, task_types, visited)
            case expression
            when IR::Member
              collect_task_types_from_expression(expression.receiver, task_types, visited)
            when IR::Index, IR::CheckedIndex, IR::CheckedSpanIndex, IR::NullableIndex, IR::NullableSpanIndex
              collect_task_types_from_expression(expression.receiver, task_types, visited)
              collect_task_types_from_expression(expression.index, task_types, visited)
            when IR::Call
              collect_task_type(expression.type, task_types, visited)
              collect_task_types_from_expression(expression.callee, task_types, visited) unless expression.callee.is_a?(String)
              expression.arguments.each { |argument| collect_task_types_from_expression(argument, task_types, visited) }
            when IR::Unary
              collect_task_types_from_expression(expression.operand, task_types, visited)
            when IR::Binary
              collect_task_types_from_expression(expression.left, task_types, visited)
              collect_task_types_from_expression(expression.right, task_types, visited)
            when IR::Conditional
              collect_task_types_from_expression(expression.condition, task_types, visited)
              collect_task_types_from_expression(expression.then_expression, task_types, visited)
              collect_task_types_from_expression(expression.else_expression, task_types, visited)
            when IR::ReinterpretExpr
              collect_task_type(expression.target_type, task_types, visited)
              collect_task_type(expression.source_type, task_types, visited)
              collect_task_types_from_expression(expression.expression, task_types, visited)
            when IR::SizeofExpr, IR::AlignofExpr, IR::OffsetofExpr
              collect_task_type(expression.target_type, task_types, visited)
            when IR::AddressOf, IR::Cast
              collect_task_types_from_expression(expression.expression, task_types, visited)
            when IR::AggregateLiteral
              collect_task_type(expression.type, task_types, visited)
              expression.fields.each { |field| collect_task_types_from_expression(field.value, task_types, visited) }
            when IR::ArrayLiteral
              expression.elements.each { |element| collect_task_types_from_expression(element, task_types, visited) }
            when IR::VariantLiteral
              collect_task_type(expression.type, task_types, visited)
              expression.fields.each { |field| collect_task_types_from_expression(field.value, task_types, visited) }
            end
          end

          def collect_task_type(type, task_types, visited)
            return unless type
            return if visited[type]

            visited[type] = true

            case type
            when Types::Nullable
              collect_task_type(type.base, task_types, visited)
            when Types::Task
              task_types << type
              collect_task_type(type.result_type, task_types, visited)
            when Types::Span
              collect_task_type(type.element_type, task_types, visited)
            when Types::StructInstance
              type.arguments.each do |argument|
                collect_task_type(argument, task_types, visited) unless argument.is_a?(Types::LiteralTypeArg)
              end
              type.fields.each_value do |field_type|
                collect_task_type(field_type, task_types, visited)
              end
            when Types::GenericInstance
              type.arguments.each do |argument|
                collect_task_type(argument, task_types, visited) unless argument.is_a?(Types::LiteralTypeArg)
              end
            when Types::Function
              type.params.each do |param|
                collect_task_type(param.type, task_types, visited)
              end
              collect_task_type(type.return_type, task_types, visited)
            when Types::Struct, Types::Union
              type.fields.each_value do |field_type|
                collect_task_type(field_type, task_types, visited)
              end
            when Types::Variant
              type.arm_names.each do |arm_name|
                type.arm(arm_name).each_value do |field_type|
                  collect_task_type(field_type, task_types, visited)
                end
              end
            end
          end

          def collect_generic_variant_types
            generic_variant_types = []
            visited = {}

            all_emitted_top_level_values.each do |value|
              collect_generic_variant_type(value.type, generic_variant_types, visited)
            end

            @program.structs.each do |struct_decl|
              struct_decl.fields.each do |field|
                collect_generic_variant_type(field.type, generic_variant_types, visited)
              end
            end

            @program.unions.each do |union_decl|
              union_decl.fields.each do |field|
                collect_generic_variant_type(field.type, generic_variant_types, visited)
              end
            end

            each_variant_arm_field_type do |field_type|
              collect_generic_variant_type(field_type, generic_variant_types, visited)
            end

            emitted_functions.each do |function|
              collect_generic_variant_type(function.return_type, generic_variant_types, visited)
              function.params.each do |param|
                collect_generic_variant_type(param.type, generic_variant_types, visited)
              end
              collect_generic_variant_types_from_statements(function.body, generic_variant_types, visited)
            end

            @program.static_asserts.each do |statement|
              collect_generic_variant_types_from_expression(statement.condition, generic_variant_types, visited)
              collect_generic_variant_types_from_expression(statement.message, generic_variant_types, visited)
            end

            generic_variant_types
          end

          def collect_generic_variant_types_from_statements(statements, generic_variant_types, visited)
            statements.each do |statement|
              case statement
              when IR::LocalDecl
                collect_generic_variant_type(statement.type, generic_variant_types, visited)
                collect_generic_variant_types_from_expression(statement.value, generic_variant_types, visited)
              when IR::Assignment
                collect_generic_variant_types_from_expression(statement.target, generic_variant_types, visited)
                collect_generic_variant_types_from_expression(statement.value, generic_variant_types, visited)
              when IR::BlockStmt
                collect_generic_variant_types_from_statements(statement.body, generic_variant_types, visited)
              when IR::WhileStmt
                collect_generic_variant_types_from_expression(statement.condition, generic_variant_types, visited)
                collect_generic_variant_types_from_statements(statement.body, generic_variant_types, visited)
              when IR::ForStmt
                collect_generic_variant_types_from_statements([statement.init], generic_variant_types, visited)
                collect_generic_variant_types_from_expression(statement.condition, generic_variant_types, visited)
                collect_generic_variant_types_from_statements(statement.body, generic_variant_types, visited)
                collect_generic_variant_types_from_statements([statement.post], generic_variant_types, visited)
              when IR::IfStmt
                collect_generic_variant_types_from_expression(statement.condition, generic_variant_types, visited)
                collect_generic_variant_types_from_statements(statement.then_body, generic_variant_types, visited)
                collect_generic_variant_types_from_statements(statement.else_body, generic_variant_types, visited) if statement.else_body
              when IR::SwitchStmt
                collect_generic_variant_types_from_expression(statement.expression, generic_variant_types, visited)
                statement.cases.each do |switch_case|
                  collect_generic_variant_types_from_statements(switch_case.body, generic_variant_types, visited)
                end
              when IR::StaticAssert
                collect_generic_variant_types_from_expression(statement.condition, generic_variant_types, visited)
                collect_generic_variant_types_from_expression(statement.message, generic_variant_types, visited)
              when IR::ReturnStmt
                collect_generic_variant_types_from_expression(statement.value, generic_variant_types, visited) if statement.value
              when IR::ExpressionStmt
                collect_generic_variant_types_from_expression(statement.expression, generic_variant_types, visited)
              end
            end
          end

          def collect_generic_variant_types_from_expression(expression, generic_variant_types, visited)
            case expression
            when IR::Member
              collect_generic_variant_types_from_expression(expression.receiver, generic_variant_types, visited)
            when IR::Index, IR::CheckedIndex, IR::CheckedSpanIndex, IR::NullableIndex, IR::NullableSpanIndex
              collect_generic_variant_types_from_expression(expression.receiver, generic_variant_types, visited)
              collect_generic_variant_types_from_expression(expression.index, generic_variant_types, visited)
            when IR::Call
              collect_generic_variant_type(expression.type, generic_variant_types, visited)
              collect_generic_variant_types_from_expression(expression.callee, generic_variant_types, visited) unless expression.callee.is_a?(String)
              expression.arguments.each { |argument| collect_generic_variant_types_from_expression(argument, generic_variant_types, visited) }
            when IR::Unary
              collect_generic_variant_types_from_expression(expression.operand, generic_variant_types, visited)
            when IR::Binary
              collect_generic_variant_types_from_expression(expression.left, generic_variant_types, visited)
              collect_generic_variant_types_from_expression(expression.right, generic_variant_types, visited)
            when IR::Conditional
              collect_generic_variant_types_from_expression(expression.condition, generic_variant_types, visited)
              collect_generic_variant_types_from_expression(expression.then_expression, generic_variant_types, visited)
              collect_generic_variant_types_from_expression(expression.else_expression, generic_variant_types, visited)
            when IR::ReinterpretExpr
              collect_generic_variant_type(expression.target_type, generic_variant_types, visited)
              collect_generic_variant_type(expression.source_type, generic_variant_types, visited)
              collect_generic_variant_types_from_expression(expression.expression, generic_variant_types, visited)
            when IR::SizeofExpr, IR::AlignofExpr, IR::OffsetofExpr
              collect_generic_variant_type(expression.target_type, generic_variant_types, visited)
            when IR::AddressOf, IR::Cast
              collect_generic_variant_types_from_expression(expression.expression, generic_variant_types, visited)
            when IR::AggregateLiteral
              collect_generic_variant_type(expression.type, generic_variant_types, visited)
              expression.fields.each { |field| collect_generic_variant_types_from_expression(field.value, generic_variant_types, visited) }
            when IR::ArrayLiteral
              expression.elements.each { |element| collect_generic_variant_types_from_expression(element, generic_variant_types, visited) }
            when IR::VariantLiteral
              collect_generic_variant_type(expression.type, generic_variant_types, visited)
              expression.fields.each { |field| collect_generic_variant_types_from_expression(field.value, generic_variant_types, visited) }
            end
          end

          def collect_generic_variant_type(type, generic_variant_types, visited)
            return unless type
            return if visited[type]

            visited[type] = true

            case type
            when Types::Nullable
              collect_generic_variant_type(type.base, generic_variant_types, visited)
            when Types::Task
              collect_generic_variant_type(type.result_type, generic_variant_types, visited)
            when Types::Span
              collect_generic_variant_type(type.element_type, generic_variant_types, visited)
            when Types::VariantInstance
              type.arguments.each do |argument|
                collect_generic_variant_type(argument, generic_variant_types, visited) unless argument.is_a?(Types::LiteralTypeArg)
              end
              type.arm_names.each do |arm_name|
                type.arm(arm_name).each_value do |field_type|
                  collect_generic_variant_type(field_type, generic_variant_types, visited)
                end
              end
              generic_variant_types << type
            when Types::StructInstance
              type.arguments.each do |argument|
                collect_generic_variant_type(argument, generic_variant_types, visited) unless argument.is_a?(Types::LiteralTypeArg)
              end
              type.fields.each_value do |field_type|
                collect_generic_variant_type(field_type, generic_variant_types, visited)
              end
            when Types::GenericInstance
              type.arguments.each do |argument|
                collect_generic_variant_type(argument, generic_variant_types, visited) unless argument.is_a?(Types::LiteralTypeArg)
              end
            when Types::Function, Types::Proc
              type.params.each do |param|
                collect_generic_variant_type(param.type, generic_variant_types, visited)
              end
              collect_generic_variant_type(type.return_type, generic_variant_types, visited)
            when Types::Struct, Types::Union
              type.fields.each_value do |field_type|
                collect_generic_variant_type(field_type, generic_variant_types, visited)
              end
            when Types::Variant
              type.arm_names.each do |arm_name|
                type.arm(arm_name).each_value do |field_type|
                  collect_generic_variant_type(field_type, generic_variant_types, visited)
                end
              end
            end
          end

          def collect_generic_struct_types
            generic_struct_types = []
            visited = {}

            all_emitted_top_level_values.each do |value|
              collect_generic_struct_type(value.type, generic_struct_types, visited)
            end

            @program.structs.each do |struct_decl|
              struct_decl.fields.each do |field|
                collect_generic_struct_type(field.type, generic_struct_types, visited)
              end
            end

            @program.unions.each do |union_decl|
              union_decl.fields.each do |field|
                collect_generic_struct_type(field.type, generic_struct_types, visited)
              end
            end

            each_variant_arm_field_type do |field_type|
              collect_generic_struct_type(field_type, generic_struct_types, visited)
            end

            emitted_functions.each do |function|
              collect_generic_struct_type(function.return_type, generic_struct_types, visited)
              function.params.each do |param|
                collect_generic_struct_type(param.type, generic_struct_types, visited)
              end
              collect_generic_struct_types_from_statements(function.body, generic_struct_types, visited)
            end

            @program.static_asserts.each do |statement|
              collect_generic_struct_types_from_expression(statement.condition, generic_struct_types, visited)
              collect_generic_struct_types_from_expression(statement.message, generic_struct_types, visited)
            end

            generic_struct_types
          end

          def collect_str_buffer_types
            str_buffer_types = []
            visited = {}

            all_emitted_top_level_values.each do |value|
              collect_str_buffer_type(value.type, str_buffer_types, visited)
            end

            @program.structs.each do |struct_decl|
              struct_decl.fields.each do |field|
                collect_str_buffer_type(field.type, str_buffer_types, visited)
              end
            end

            @program.unions.each do |union_decl|
              union_decl.fields.each do |field|
                collect_str_buffer_type(field.type, str_buffer_types, visited)
              end
            end

            each_variant_arm_field_type do |field_type|
              collect_str_buffer_type(field_type, str_buffer_types, visited)
            end

            emitted_functions.each do |function|
              collect_str_buffer_type(function.return_type, str_buffer_types, visited)
              function.params.each do |param|
                collect_str_buffer_type(param.type, str_buffer_types, visited)
              end
              collect_str_buffer_types_from_statements(function.body, str_buffer_types, visited)
            end

            @program.static_asserts.each do |statement|
              collect_str_buffer_types_from_expression(statement.condition, str_buffer_types, visited)
              collect_str_buffer_types_from_expression(statement.message, str_buffer_types, visited)
            end

            str_buffer_types
          end

          def collect_str_buffer_types_from_statements(statements, str_buffer_types, visited)
            statements.each do |statement|
              case statement
              when IR::LocalDecl
                collect_str_buffer_type(statement.type, str_buffer_types, visited)
                collect_str_buffer_types_from_expression(statement.value, str_buffer_types, visited)
              when IR::Assignment
                collect_str_buffer_types_from_expression(statement.target, str_buffer_types, visited)
                collect_str_buffer_types_from_expression(statement.value, str_buffer_types, visited)
              when IR::BlockStmt
                collect_str_buffer_types_from_statements(statement.body, str_buffer_types, visited)
              when IR::WhileStmt
                collect_str_buffer_types_from_expression(statement.condition, str_buffer_types, visited)
                collect_str_buffer_types_from_statements(statement.body, str_buffer_types, visited)
              when IR::ForStmt
                collect_str_buffer_types_from_statements([statement.init], str_buffer_types, visited)
                collect_str_buffer_types_from_expression(statement.condition, str_buffer_types, visited)
                collect_str_buffer_types_from_statements(statement.body, str_buffer_types, visited)
                collect_str_buffer_types_from_statements([statement.post], str_buffer_types, visited)
              when IR::IfStmt
                collect_str_buffer_types_from_expression(statement.condition, str_buffer_types, visited)
                collect_str_buffer_types_from_statements(statement.then_body, str_buffer_types, visited)
                collect_str_buffer_types_from_statements(statement.else_body, str_buffer_types, visited) if statement.else_body
              when IR::SwitchStmt
                collect_str_buffer_types_from_expression(statement.expression, str_buffer_types, visited)
                statement.cases.each do |switch_case|
                  collect_str_buffer_types_from_statements(switch_case.body, str_buffer_types, visited)
                end
              when IR::StaticAssert
                collect_str_buffer_types_from_expression(statement.condition, str_buffer_types, visited)
                collect_str_buffer_types_from_expression(statement.message, str_buffer_types, visited)
              when IR::ReturnStmt
                collect_str_buffer_types_from_expression(statement.value, str_buffer_types, visited) if statement.value
              when IR::ExpressionStmt
                collect_str_buffer_types_from_expression(statement.expression, str_buffer_types, visited)
              end
            end
          end

          def collect_str_buffer_types_from_expression(expression, str_buffer_types, visited)
            case expression
            when IR::Member
              collect_str_buffer_types_from_expression(expression.receiver, str_buffer_types, visited)
            when IR::Index, IR::CheckedIndex, IR::CheckedSpanIndex, IR::NullableIndex, IR::NullableSpanIndex
              collect_str_buffer_types_from_expression(expression.receiver, str_buffer_types, visited)
              collect_str_buffer_types_from_expression(expression.index, str_buffer_types, visited)
            when IR::Call
              collect_str_buffer_type(expression.type, str_buffer_types, visited)
              collect_str_buffer_types_from_expression(expression.callee, str_buffer_types, visited) unless expression.callee.is_a?(String)
              expression.arguments.each { |argument| collect_str_buffer_types_from_expression(argument, str_buffer_types, visited) }
            when IR::Unary
              collect_str_buffer_types_from_expression(expression.operand, str_buffer_types, visited)
            when IR::Binary
              collect_str_buffer_types_from_expression(expression.left, str_buffer_types, visited)
              collect_str_buffer_types_from_expression(expression.right, str_buffer_types, visited)
            when IR::Conditional
              collect_str_buffer_types_from_expression(expression.condition, str_buffer_types, visited)
              collect_str_buffer_types_from_expression(expression.then_expression, str_buffer_types, visited)
              collect_str_buffer_types_from_expression(expression.else_expression, str_buffer_types, visited)
            when IR::ReinterpretExpr
              collect_str_buffer_type(expression.target_type, str_buffer_types, visited)
              collect_str_buffer_type(expression.source_type, str_buffer_types, visited)
              collect_str_buffer_types_from_expression(expression.expression, str_buffer_types, visited)
            when IR::SizeofExpr, IR::AlignofExpr, IR::OffsetofExpr
              collect_str_buffer_type(expression.target_type, str_buffer_types, visited)
            when IR::AddressOf, IR::Cast
              collect_str_buffer_types_from_expression(expression.expression, str_buffer_types, visited)
            when IR::AggregateLiteral
              collect_str_buffer_type(expression.type, str_buffer_types, visited)
              expression.fields.each { |field| collect_str_buffer_types_from_expression(field.value, str_buffer_types, visited) }
            when IR::ArrayLiteral
              expression.elements.each { |element| collect_str_buffer_types_from_expression(element, str_buffer_types, visited) }
            when IR::VariantLiteral
              collect_str_buffer_type(expression.type, str_buffer_types, visited)
              expression.fields.each { |field| collect_str_buffer_types_from_expression(field.value, str_buffer_types, visited) }
            end
          end

          def collect_str_buffer_type(type, str_buffer_types, visited)
            return unless type
            return if visited[type]

            visited[type] = true

            case type
            when Types::Nullable
              collect_str_buffer_type(type.base, str_buffer_types, visited)
            when Types::Span
              collect_str_buffer_type(type.element_type, str_buffer_types, visited)
            when Types::StructInstance
              type.arguments.each do |argument|
                collect_str_buffer_type(argument, str_buffer_types, visited) unless argument.is_a?(Types::LiteralTypeArg)
              end
              type.fields.each_value do |field_type|
                collect_str_buffer_type(field_type, str_buffer_types, visited)
              end
            when Types::GenericInstance
              str_buffer_types << type if str_buffer_type?(type)
              type.arguments.each do |argument|
                collect_str_buffer_type(argument, str_buffer_types, visited) unless argument.is_a?(Types::LiteralTypeArg)
              end
            when Types::Function
              type.params.each do |param|
                collect_str_buffer_type(param.type, str_buffer_types, visited)
              end
              collect_str_buffer_type(type.return_type, str_buffer_types, visited)
            when Types::Struct, Types::Union
              type.fields.each_value do |field_type|
                collect_str_buffer_type(field_type, str_buffer_types, visited)
              end
            when Types::Variant
              type.arm_names.each do |arm_name|
                type.arm(arm_name).each_value do |field_type|
                  collect_str_buffer_type(field_type, str_buffer_types, visited)
                end
              end
            end
          end

          def collect_generic_struct_types_from_statements(statements, generic_struct_types, visited)
            statements.each do |statement|
              case statement
              when IR::LocalDecl
                collect_generic_struct_type(statement.type, generic_struct_types, visited)
                collect_generic_struct_types_from_expression(statement.value, generic_struct_types, visited)
              when IR::Assignment
                collect_generic_struct_types_from_expression(statement.target, generic_struct_types, visited)
                collect_generic_struct_types_from_expression(statement.value, generic_struct_types, visited)
              when IR::BlockStmt
                collect_generic_struct_types_from_statements(statement.body, generic_struct_types, visited)
              when IR::WhileStmt
                collect_generic_struct_types_from_expression(statement.condition, generic_struct_types, visited)
                collect_generic_struct_types_from_statements(statement.body, generic_struct_types, visited)
              when IR::ForStmt
                collect_generic_struct_types_from_statements([statement.init], generic_struct_types, visited)
                collect_generic_struct_types_from_expression(statement.condition, generic_struct_types, visited)
                collect_generic_struct_types_from_statements(statement.body, generic_struct_types, visited)
                collect_generic_struct_types_from_statements([statement.post], generic_struct_types, visited)
              when IR::IfStmt
                collect_generic_struct_types_from_expression(statement.condition, generic_struct_types, visited)
                collect_generic_struct_types_from_statements(statement.then_body, generic_struct_types, visited)
                collect_generic_struct_types_from_statements(statement.else_body, generic_struct_types, visited) if statement.else_body
              when IR::SwitchStmt
                collect_generic_struct_types_from_expression(statement.expression, generic_struct_types, visited)
                statement.cases.each do |switch_case|
                  collect_generic_struct_types_from_statements(switch_case.body, generic_struct_types, visited)
                end
              when IR::StaticAssert
                collect_generic_struct_types_from_expression(statement.condition, generic_struct_types, visited)
                collect_generic_struct_types_from_expression(statement.message, generic_struct_types, visited)
              when IR::ReturnStmt
                collect_generic_struct_types_from_expression(statement.value, generic_struct_types, visited) if statement.value
              when IR::ExpressionStmt
                collect_generic_struct_types_from_expression(statement.expression, generic_struct_types, visited)
              end
            end
          end

          def collect_generic_struct_types_from_expression(expression, generic_struct_types, visited)
            case expression
            when IR::Member
              collect_generic_struct_types_from_expression(expression.receiver, generic_struct_types, visited)
            when IR::Index, IR::CheckedIndex, IR::CheckedSpanIndex, IR::NullableIndex, IR::NullableSpanIndex
              collect_generic_struct_types_from_expression(expression.receiver, generic_struct_types, visited)
              collect_generic_struct_types_from_expression(expression.index, generic_struct_types, visited)
            when IR::Call
              collect_generic_struct_type(expression.type, generic_struct_types, visited)
              collect_generic_struct_types_from_expression(expression.callee, generic_struct_types, visited) unless expression.callee.is_a?(String)
              expression.arguments.each { |argument| collect_generic_struct_types_from_expression(argument, generic_struct_types, visited) }
            when IR::Unary
              collect_generic_struct_types_from_expression(expression.operand, generic_struct_types, visited)
            when IR::Binary
              collect_generic_struct_types_from_expression(expression.left, generic_struct_types, visited)
              collect_generic_struct_types_from_expression(expression.right, generic_struct_types, visited)
            when IR::Conditional
              collect_generic_struct_types_from_expression(expression.condition, generic_struct_types, visited)
              collect_generic_struct_types_from_expression(expression.then_expression, generic_struct_types, visited)
              collect_generic_struct_types_from_expression(expression.else_expression, generic_struct_types, visited)
            when IR::ReinterpretExpr
              collect_generic_struct_type(expression.target_type, generic_struct_types, visited)
              collect_generic_struct_type(expression.source_type, generic_struct_types, visited)
              collect_generic_struct_types_from_expression(expression.expression, generic_struct_types, visited)
            when IR::SizeofExpr, IR::AlignofExpr, IR::OffsetofExpr
              collect_generic_struct_type(expression.target_type, generic_struct_types, visited)
            when IR::AddressOf
              collect_generic_struct_types_from_expression(expression.expression, generic_struct_types, visited)
            when IR::Cast
              collect_generic_struct_types_from_expression(expression.expression, generic_struct_types, visited)
            when IR::AggregateLiteral
              collect_generic_struct_type(expression.type, generic_struct_types, visited)
              expression.fields.each { |field| collect_generic_struct_types_from_expression(field.value, generic_struct_types, visited) }
            when IR::ArrayLiteral
              expression.elements.each { |element| collect_generic_struct_types_from_expression(element, generic_struct_types, visited) }
            when IR::VariantLiteral
              collect_generic_struct_type(expression.type, generic_struct_types, visited)
              expression.fields.each { |field| collect_generic_struct_types_from_expression(field.value, generic_struct_types, visited) }
            end
          end

          def collect_generic_struct_type(type, generic_struct_types, visited)
            return unless type
            return if visited[type]

            visited[type] = true

            case type
            when Types::Nullable
              collect_generic_struct_type(type.base, generic_struct_types, visited)
            when Types::Span
              collect_generic_struct_type(type.element_type, generic_struct_types, visited)
            when Types::StructInstance
              generic_struct_types << type
              type.arguments.each do |argument|
                collect_generic_struct_type(argument, generic_struct_types, visited) unless argument.is_a?(Types::LiteralTypeArg)
              end
              type.fields.each_value do |field_type|
                collect_generic_struct_type(field_type, generic_struct_types, visited)
              end
            when Types::GenericInstance
              type.arguments.each do |argument|
                collect_generic_struct_type(argument, generic_struct_types, visited) unless argument.is_a?(Types::LiteralTypeArg)
              end
            when Types::Function
              type.params.each do |param|
                collect_generic_struct_type(param.type, generic_struct_types, visited)
              end
              collect_generic_struct_type(type.return_type, generic_struct_types, visited)
            when Types::Struct, Types::Union
              type.fields.each_value do |field_type|
                collect_generic_struct_type(field_type, generic_struct_types, visited)
              end
            when Types::Variant
              type.arm_names.each do |arm_name|
                type.arm(arm_name).each_value do |field_type|
                  collect_generic_struct_type(field_type, generic_struct_types, visited)
                end
              end
            end
          end

          def collect_span_types_from_statements(statements, span_types, visited)
            statements.each do |statement|
              case statement
              when IR::LocalDecl
                collect_span_type(statement.type, span_types, visited)
                collect_span_types_from_expression(statement.value, span_types, visited)
              when IR::Assignment
                collect_span_types_from_expression(statement.target, span_types, visited)
                collect_span_types_from_expression(statement.value, span_types, visited)
              when IR::BlockStmt
                collect_span_types_from_statements(statement.body, span_types, visited)
              when IR::WhileStmt
                collect_span_types_from_expression(statement.condition, span_types, visited)
                collect_span_types_from_statements(statement.body, span_types, visited)
              when IR::ForStmt
                collect_span_types_from_statements([statement.init], span_types, visited)
                collect_span_types_from_expression(statement.condition, span_types, visited)
                collect_span_types_from_statements(statement.body, span_types, visited)
                collect_span_types_from_statements([statement.post], span_types, visited)
              when IR::IfStmt
                collect_span_types_from_expression(statement.condition, span_types, visited)
                collect_span_types_from_statements(statement.then_body, span_types, visited)
                collect_span_types_from_statements(statement.else_body, span_types, visited) if statement.else_body
              when IR::SwitchStmt
                collect_span_types_from_expression(statement.expression, span_types, visited)
                statement.cases.each do |switch_case|
                  collect_span_types_from_statements(switch_case.body, span_types, visited)
                end
              when IR::StaticAssert
                collect_span_types_from_expression(statement.condition, span_types, visited)
                collect_span_types_from_expression(statement.message, span_types, visited)
              when IR::ReturnStmt
                collect_span_types_from_expression(statement.value, span_types, visited) if statement.value
              when IR::ExpressionStmt
                collect_span_types_from_expression(statement.expression, span_types, visited)
              end
            end
          end

          def collect_span_types_from_expression(expression, span_types, visited)
            case expression
            when IR::Member
              collect_span_types_from_expression(expression.receiver, span_types, visited)
            when IR::Index, IR::CheckedIndex, IR::CheckedSpanIndex, IR::NullableIndex, IR::NullableSpanIndex
              collect_span_types_from_expression(expression.receiver, span_types, visited)
              collect_span_types_from_expression(expression.index, span_types, visited)
            when IR::Call
              collect_span_type(expression.type, span_types, visited)
              collect_span_types_from_expression(expression.callee, span_types, visited) unless expression.callee.is_a?(String)
              expression.arguments.each { |argument| collect_span_types_from_expression(argument, span_types, visited) }
            when IR::Unary
              collect_span_types_from_expression(expression.operand, span_types, visited)
            when IR::Binary
              collect_span_types_from_expression(expression.left, span_types, visited)
              collect_span_types_from_expression(expression.right, span_types, visited)
            when IR::Conditional
              collect_span_types_from_expression(expression.condition, span_types, visited)
              collect_span_types_from_expression(expression.then_expression, span_types, visited)
              collect_span_types_from_expression(expression.else_expression, span_types, visited)
            when IR::ReinterpretExpr
              collect_span_type(expression.target_type, span_types, visited)
              collect_span_type(expression.source_type, span_types, visited)
              collect_span_types_from_expression(expression.expression, span_types, visited)
            when IR::SizeofExpr, IR::AlignofExpr, IR::OffsetofExpr
              collect_span_type(expression.target_type, span_types, visited)
            when IR::AddressOf
              collect_span_types_from_expression(expression.expression, span_types, visited)
            when IR::Cast
              collect_span_types_from_expression(expression.expression, span_types, visited)
            when IR::AggregateLiteral
              collect_span_type(expression.type, span_types, visited)
              expression.fields.each { |field| collect_span_types_from_expression(field.value, span_types, visited) }
            when IR::ArrayLiteral
              expression.elements.each { |element| collect_span_types_from_expression(element, span_types, visited) }
            when IR::VariantLiteral
              collect_span_type(expression.type, span_types, visited)
              expression.fields.each { |field| collect_span_types_from_expression(field.value, span_types, visited) }
            end
          end

          def collect_span_type(type, span_types, visited)
            return unless type
            return if visited[type]

            visited[type] = true

            case type
            when Types::Nullable
              collect_span_type(type.base, span_types, visited)
            when Types::Span
              span_types << type
              collect_span_type(type.element_type, span_types, visited)
            when Types::GenericInstance
              type.arguments.each do |argument|
                collect_span_type(argument, span_types, visited) unless argument.is_a?(Types::LiteralTypeArg)
              end
            when Types::Function
              type.params.each do |param|
                collect_span_type(param.type, span_types, visited)
              end
              collect_span_type(type.return_type, span_types, visited)
            when Types::Struct, Types::Union
              type.fields.each_value do |field_type|
                collect_span_type(field_type, span_types, visited)
              end
            when Types::Variant
              type.arm_names.each do |arm_name|
                type.arm(arm_name).each_value do |field_type|
                  collect_span_type(field_type, span_types, visited)
                end
              end
            end
          end

          def collect_dyn_decls
            void_ptr = Types::Registry.generic_instance("ptr", [Types::Registry.primitive("void")])
            collect_dyn_types.map do |type|
              IR::StructDecl.new(
                name: type.to_s,
                linkage_name: dyn_type_name(type),
                fields: [
                  IR::Field.new(name: "data", type: void_ptr),
                  IR::Field.new(name: "vtable", type: void_ptr),
                ],
                packed: false,
                alignment: nil,
              )
            end
          end

          def collect_dyn_types
            dyn_types = []
            seen = []

            collect_type = lambda do |type|
              return unless type
              case type
              when Types::Dyn
                name = type.interface_binding.name
                unless seen.include?(name)
                  seen << name
                  dyn_types << type
                end
              when Types::Nullable
                collect_type.call(type.base)
              when Types::GenericInstance
                type.arguments.each { |arg| collect_type.call(arg) unless arg.is_a?(Types::LiteralTypeArg) }
              when Types::Span
                collect_type.call(type.element_type)
              when Types::Task
                collect_type.call(type.result_type)
              when Types::Function
                type.params.each { |p| collect_type.call(p.type) }
                collect_type.call(type.return_type)
              when Types::Proc
                type.params.each { |p| collect_type.call(p.type) }
                collect_type.call(type.return_type)
              when Types::StructInstance
                type.arguments.each { |arg| collect_type.call(arg) }
              when Types::VariantInstance
                type.arguments.each { |arg| collect_type.call(arg) }
              end
            end

            collect_in_stmt = lambda do |stmt|
              case stmt
              when IR::LocalDecl
                collect_type.call(stmt.type)
              when IR::BlockStmt
                stmt.body.each { |s| collect_in_stmt.call(s) }
              when IR::IfStmt
                stmt.then_body.each { |s| collect_in_stmt.call(s) }
                stmt.else_body&.each { |s| collect_in_stmt.call(s) }
              when IR::WhileStmt
                stmt.body.each { |s| collect_in_stmt.call(s) }
              when IR::ForStmt
                stmt.body.each { |s| collect_in_stmt.call(s) }
              when IR::SwitchStmt
                stmt.cases.each { |c| c.body.each { |s| collect_in_stmt.call(s) } }
              end
            end

            if @program
              @program.constants.each { |c| collect_type.call(c.type) }
              @program.globals.each { |g| collect_type.call(g.type) }
              @program.structs.each { |s| s.fields.each { |f| collect_type.call(f.type) } }
              @program.unions.each { |u| u.fields.each { |f| collect_type.call(f.type) } }
              @program.functions.each do |f|
                collect_type.call(f.return_type)
                f.params.each { |p| collect_type.call(p.type) }
                body = f.body
                if body.is_a?(IR::BlockStmt)
                  body.body.each { |s| collect_in_stmt.call(s) }
                elsif body.is_a?(Array)
                  body.each { |s| collect_in_stmt.call(s) }
                end
              end
            end

            dyn_types
          end

          def collect_nullable_opt_decls
            collect_nullable_opt_types.map do |type|
              IR::StructDecl.new(
                name: type.to_s,
                linkage_name: nullable_opt_type_name(type),
                fields: [
                  IR::Field.new(name: "has_value", type: Types::Registry.primitive("bool")),
                  IR::Field.new(name: "value", type: type.base),
                ],
                packed: false,
                alignment: nil,
              )
            end
          end

          def collect_nullable_opt_types
            opt_types = []
            seen = {}

            collect_type = lambda do |type|
              return unless type

              case type
              when Types::Nullable
                unless c_backend_pointer_like_type?(type.base)
                  name = nullable_opt_type_name(type)
                  unless seen[name]
                    seen[name] = true
                    opt_types << type
                  end
                end
                collect_type.call(type.base)
              when Types::GenericInstance
                type.arguments.each { |arg| collect_type.call(arg) unless arg.is_a?(Types::LiteralTypeArg) }
              when Types::Span
                collect_type.call(type.element_type)
              when Types::Task
                collect_type.call(type.result_type)
              when Types::Function, Types::Proc
                type.params.each { |p| collect_type.call(p.type) }
                collect_type.call(type.return_type)
              when Types::StructInstance, Types::VariantInstance
                type.arguments.each { |arg| collect_type.call(arg) }
              end
            end

            collect_in_stmt = lambda do |stmt|
              case stmt
              when IR::LocalDecl
                collect_type.call(stmt.type)
              when IR::BlockStmt
                stmt.body.each { |s| collect_in_stmt.call(s) }
              when IR::IfStmt
                stmt.then_body.each { |s| collect_in_stmt.call(s) }
                stmt.else_body&.each { |s| collect_in_stmt.call(s) }
              when IR::WhileStmt
                stmt.body.each { |s| collect_in_stmt.call(s) }
              when IR::ForStmt
                stmt.body.each { |s| collect_in_stmt.call(s) }
              when IR::SwitchStmt
                stmt.cases.each { |c| c.body.each { |s| collect_in_stmt.call(s) } }
              end
            end

            emitted_aggregate_structs.each { |decl| decl.fields.each { |f| collect_type.call(f.type) } }
            emitted_aggregate_unions.each { |decl| decl.fields.each { |f| collect_type.call(f.type) } }
            emitted_aggregate_variants.each do |decl|
              decl.arms.each { |arm| arm.fields.each { |f| collect_type.call(f.type) } }
            end
            emitted_constants.each { |c| collect_type.call(c.type) }
            emitted_globals.each { |g| collect_type.call(g.type) }
            emitted_functions.each do |f|
              collect_type.call(f.return_type)
              f.params.each { |p| collect_type.call(p.type) }
              f.body.each { |s| collect_in_stmt.call(s) }
            end

            opt_types
          end

          def collect_str_literals
            literals = {}
            emitted_functions.each do |func|
              collect_str_literals_from_statements(func.body, literals)
            end
            emitted_globals.each do |global|
              collect_str_literals_from_expression(global.value, literals)
            end
            emitted_constants.each do |constant|
              collect_str_literals_from_expression(constant.value, literals)
            end
            literals.keys.sort_by { |k| [k.bytesize, k] }
          end

          def collect_str_literals_from_statements(statements, literals)
            statements.each do |stmt|
              case stmt
              when IR::LocalDecl
                collect_str_literals_from_expression(stmt.value, literals) if stmt.value
              when IR::Assignment
                collect_str_literals_from_expression(stmt.target, literals)
                collect_str_literals_from_expression(stmt.value, literals)
              when IR::BlockStmt
                collect_str_literals_from_statements(stmt.body, literals)
              when IR::WhileStmt
                collect_str_literals_from_expression(stmt.condition, literals)
                collect_str_literals_from_statements(stmt.body, literals)
              when IR::ForStmt
                collect_str_literals_from_statements([stmt.init], literals)
                collect_str_literals_from_expression(stmt.condition, literals)
                collect_str_literals_from_statements(stmt.body, literals)
                collect_str_literals_from_statements([stmt.post], literals)
              when IR::IfStmt
                collect_str_literals_from_expression(stmt.condition, literals)
                collect_str_literals_from_statements(stmt.then_body, literals)
                collect_str_literals_from_statements(stmt.else_body, literals) if stmt.else_body
              when IR::SwitchStmt
                collect_str_literals_from_expression(stmt.expression, literals)
                stmt.cases.each { |c| collect_str_literals_from_statements(c.body, literals) }
              when IR::ReturnStmt
                collect_str_literals_from_expression(stmt.value, literals) if stmt.value
              when IR::ExpressionStmt
                collect_str_literals_from_expression(stmt.expression, literals)
              when IR::StaticAssert
                collect_str_literals_from_expression(stmt.condition, literals)
                collect_str_literals_from_expression(stmt.message, literals)
              end
            end
          end

          def collect_str_literals_from_expression(expr, literals)
            return unless expr

            case expr
            when IR::StringLiteral
              literals[expr.value] = true if expr.type.is_a?(Types::StringView)
            when IR::Member
              collect_str_literals_from_expression(expr.receiver, literals)
            when IR::Index, IR::CheckedIndex, IR::CheckedSpanIndex, IR::NullableIndex, IR::NullableSpanIndex
              collect_str_literals_from_expression(expr.receiver, literals)
              collect_str_literals_from_expression(expr.index, literals)
            when IR::Call
              collect_str_literals_from_expression(expr.callee, literals) unless expr.callee.is_a?(String)
              expr.arguments.each { |arg| collect_str_literals_from_expression(arg, literals) }
            when IR::Unary
              collect_str_literals_from_expression(expr.operand, literals)
            when IR::Binary
              collect_str_literals_from_expression(expr.left, literals)
              collect_str_literals_from_expression(expr.right, literals)
            when IR::Conditional
              collect_str_literals_from_expression(expr.condition, literals)
              collect_str_literals_from_expression(expr.then_expression, literals)
              collect_str_literals_from_expression(expr.else_expression, literals)
            when IR::ReinterpretExpr
              collect_str_literals_from_expression(expr.expression, literals)
            when IR::AddressOf
              collect_str_literals_from_expression(expr.expression, literals)
            when IR::Cast
              collect_str_literals_from_expression(expr.expression, literals)
            when IR::AggregateLiteral
              expr.fields.each { |f| collect_str_literals_from_expression(f.value, literals) }
            when IR::ArrayLiteral
              expr.elements.each { |e| collect_str_literals_from_expression(e, literals) }
            when IR::VariantLiteral
              expr.fields.each { |f| collect_str_literals_from_expression(f.value, literals) }
            end
          end
    end
  end
end
