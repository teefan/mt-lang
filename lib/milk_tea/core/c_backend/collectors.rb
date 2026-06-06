# frozen_string_literal: true

module MilkTea
  class CBackend
    module CBackendCollectors
      private


          def c_declaration(type, name)
            base, declarator = c_declaration_parts(type, name)
            declarator.empty? ? base : "#{base} #{declarator}"
          end

          def c_field_declaration(type, name)
            return "uint8_t #{name}" if void_storage_field?(type)

            c_declaration(type, name)
          end

          def c_function_declaration(return_type, name, params)
            c_declaration(array_type?(return_type) ? void_type : return_type, "#{name}(#{params})")
          end

          def c_function_return_type(type)
            c_type(array_type?(type) ? void_type : type)
          end

          def function_returns_value_in_c?(function)
            c_function_return_type(function.return_type) != c_type(void_type)
          end

          def array_out_param_declaration(type, name)
            c_declaration(type, "(*#{name})")
          end

          def c_declaration_parts(type, name)
            name = name.to_s

            if array_type?(type)
              declarator = declarator_needs_grouping?(name) ? "(#{name})" : name
              return c_declaration_parts(array_element_type(type), "#{declarator}[#{array_length(type)}]")
            end

            if type.is_a?(Types::Nullable) && type.base.is_a?(Types::Function)
              return c_declaration_parts(type.base, name)
            end

            if type.is_a?(Types::Function)
              params = []
              params << array_out_param_declaration(type.return_type, ARRAY_OUT_PARAM_NAME) if array_type?(type.return_type)
              params.concat(type.params.each_with_index.map do |param, index|
                c_declaration(param.type, param.name || "arg#{index}")
              end)
              params << "..." if type.variadic
              params = ["void"] if params.empty?
              return [c_function_return_type(type.return_type), "(*#{name})(#{params.join(', ')})"]
            end

            if type.is_a?(Types::Proc)
              return [proc_type_name(type), name]
            end

            if mutable_pointer_type?(type)
              return c_declaration_parts(type.arguments.first, "*#{name}")
            end

            if const_pointer_type?(type)
              return [generic_c_type(type), name]
            end

            if ref_type?(type)
              return c_declaration_parts(type.arguments.first, "*#{name}")
            end

            [c_type(type), name]
          end

          def declarator_needs_grouping?(name)
            !name.empty? && (name.start_with?("*") || name.include?("["))
          end

          def c_type(type, pointer: false)
            case type
            when Types::Nullable
              return c_type(type.base, pointer:) if type.base.is_a?(Types::Function)

              base = c_type(type.base)
              base.end_with?("*") ? base : "#{base}*"
            when Types::StringView
              base = "mt_str"
              pointer ? "#{base}*" : base
            when Types::Primitive
              base = primitive_c_type(type.name)
              pointer ? "#{base}*" : base
            when Types::Span
              base = span_type_name(type)
              pointer ? "#{base}*" : base
            when Types::Task
              base = task_type_name(type)
              pointer ? "#{base}*" : base
            when Types::Proc
              base = proc_type_name(type)
              pointer ? "#{base}*" : base
            when Types::Function
              base = c_declaration(type, "")
              pointer ? "#{base}*" : base
            when Types::GenericInstance
              base = generic_c_type(type)
              pointer ? "#{base}*" : base
            when Types::Struct, Types::StructInstance, Types::Union, Types::Enum, Types::Flags, Types::Variant, Types::VariantInstance, Types::VariantArmPayload, Types::Event, Types::Subscription
              base = named_type_c_name(type)
              pointer ? "#{base}*" : base
            when Types::Opaque
              if type.external
                base = external_opaque_c_type(type)
                pointer ? "#{base}*" : base
              else
                base = type.c_name || named_type_c_name(type)
                pointer ? "#{base}**" : "#{base}*"
              end
            when Types::Vector
              base = "mt_#{type.name}"
              pointer ? "#{base}*" : base
            when Types::Matrix
              base = "mt_#{type.name}"
              pointer ? "#{base}*" : base
            when Types::Quaternion
              base = "mt_#{type.name}"
              pointer ? "#{base}*" : base
            else
              raise LoweringError, "unsupported C type #{type.class.name}"
            end
          end

          def constant_storage(type)
            return "static const" if array_type?(type)

            c_type(type).start_with?("const ") ? "static" : "static const"
          end

          def global_storage(_type)
            "static"
          end

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

          def collect_generic_struct_decls
            collect_generic_struct_types.map do |type|
              IR::StructDecl.new(
                name: type.to_s,
                c_name: named_type_c_name(type),
                fields: type.fields.map { |field_name, field_type| IR::Field.new(name: field_name, type: field_type) },
                packed: type.packed,
                alignment: type.alignment,
              )
            end
          end

          def collect_task_decls
            collect_task_types.map do |type|
              IR::StructDecl.new(
                name: type.to_s,
                c_name: task_type_name(type),
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
                c_name: proc_type_name(type),
                fields: proc_field_types(type).map { |field_name, field_type| IR::Field.new(name: field_name, type: field_type) },
                packed: false,
                alignment: nil,
              )
            end
          end

          def proc_field_types(type)
            void_ptr = Types::GenericInstance.new("ptr", [Types::Primitive.new("void")])

            {
              "env" => void_ptr,
              "invoke" => Types::Function.new(nil, params: [Types::Parameter.new("env", void_ptr)] + type.params, return_type: type.return_type),
              "release" => Types::Function.new(nil, params: [Types::Parameter.new("env", void_ptr)], return_type: Types::Primitive.new("void")),
              "retain" => Types::Function.new(nil, params: [Types::Parameter.new("env", void_ptr)], return_type: Types::Primitive.new("void")),
            }
          end

          def collect_str_buffer_decls
            collect_str_buffer_types.map do |type|
              IR::StructDecl.new(
                name: type.to_s,
                c_name: str_buffer_type_name(type),
                fields: [
                  IR::Field.new(name: "data", type: Types::GenericInstance.new("array", [Types::Primitive.new("char"), Types::LiteralTypeArg.new(str_buffer_storage_capacity(type))])),
                  IR::Field.new(name: "len", type: Types::Primitive.new("ptr_uint")),
                  IR::Field.new(name: "dirty", type: Types::Primitive.new("bool")),
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
                  c_name: "#{outer_c}_#{arm_name}",
                  fields: fields.map { |field_name, field_type| IR::Field.new(name: field_name, type: field_type) },
                )
              end
              IR::VariantDecl.new(name: type.to_s, c_name: outer_c, arms:)
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

          def each_variant_arm_field_type
            @program.variants.each do |variant_decl|
              variant_decl.arms.each do |arm|
                arm.fields.each do |field|
                  yield field.type
                end
              end
            end
          end

          def sort_aggregate_decls(struct_decls, union_decls, variant_decls)
            aggregate_decls = struct_decls + union_decls + variant_decls
            by_c_name = aggregate_decls.each_with_object({}) do |aggregate_decl, declarations|
              declarations[aggregate_decl.c_name] = aggregate_decl
            end
            visiting = {}
            visited = {}
            sorted = []

            visit = lambda do |aggregate_decl|
              return if visited[aggregate_decl.c_name]
              raise LoweringError, "cyclic aggregate dependency involving #{aggregate_decl.c_name}" if visiting[aggregate_decl.c_name]

              visiting[aggregate_decl.c_name] = true
              aggregate_decl_dependencies(aggregate_decl).each do |dependency|
                next unless by_c_name.key?(dependency)

                visit.call(by_c_name.fetch(dependency))
              end
              visiting.delete(aggregate_decl.c_name)
              visited[aggregate_decl.c_name] = true
              sorted << aggregate_decl
            end

            aggregate_decls.each do |aggregate_decl|
              visit.call(aggregate_decl)
            end

            sorted
          end

          def aggregate_decl_dependencies(aggregate_decl)
            case aggregate_decl
            when IR::StructDecl, IR::UnionDecl
              aggregate_decl.fields.flat_map { |field| aggregate_type_dependencies(field.type) }.uniq
            when IR::VariantDecl
              aggregate_decl.arms.flat_map { |arm| arm.fields.flat_map { |field| aggregate_type_dependencies(field.type) } }.uniq
            else
              []
            end
          end

          def aggregate_type_dependencies(type)
            case type
            when Types::Nullable
              aggregate_type_dependencies(type.base)
            when Types::Task
              [task_type_name(type)]
            when Types::Proc
              [proc_type_name(type)]
            when Types::GenericInstance
              if pointer_type?(type)
                []
              elsif array_type?(type)
                aggregate_type_dependencies(array_element_type(type))
              elsif str_buffer_type?(type)
                [str_buffer_type_name(type)]
              else
                []
              end
            when Types::Function
              []
            when Types::Struct, Types::StructInstance, Types::Union, Types::Variant, Types::VariantInstance, Types::Event, Types::Subscription
              [named_type_c_name(type)]
            when Types::VariantArmPayload
              [named_type_c_name(type.variant_type)]
            else
              []
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
            return if visited[type.object_id]

            visited[type.object_id] = true

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

          def span_type_name(type)
            "mt_span_#{sanitize_identifier(type.element_type.to_s)}"
          end

          def task_type_name(type)
            "mt_task_#{sanitize_identifier(type.result_type.to_s)}"
          end

          def proc_type_name(type)
            "mt_proc_#{sanitize_identifier(type.to_s)}"
          end

          def named_type_c_name(type)
            return task_type_name(type) if type.is_a?(Types::Task)
            if type.is_a?(Types::VariantArmPayload)
              return "#{named_type_c_name(type.variant_type)}_#{type.arm_name}"
            end

            if type.respond_to?(:c_name) && type.c_name
              return type.c_name
            end

            base_name = type.module_name&.start_with?("std.c.") ? type.name : type.module_name ? "#{module_c_prefix(type.module_name)}_#{type.name}" : type.name
            return base_name unless type.is_a?(Types::StructInstance) || type.is_a?(Types::VariantInstance)

            "#{base_name}_#{sanitize_identifier(type.arguments.join('_'))}"
          end

          def external_opaque_c_type(type)
            type.c_name || type.name
          end

          def sanitize_identifier(text)
            identifier = text.gsub(/[^A-Za-z0-9_]+/, "_").gsub(/_+/, "_").sub(/^_+/, "").sub(/_+$/, "")
            identifier.empty? ? "value" : identifier
          end

          def module_c_prefix(module_name)
            sanitize_identifier(module_name.to_s.tr('.', '_'))
          end

          def primitive_c_type(name)
            {
              "bool" => "bool",
              "byte" => "int8_t",
              "ubyte" => "uint8_t",
              "char" => "char",
              "short" => "int16_t",
              "ushort" => "uint16_t",
              "int" => "int32_t",
              "uint" => "uint32_t",
              "long" => "int64_t",
              "ulong" => "uint64_t",
              "ptr_int" => "intptr_t",
              "ptr_uint" => "uintptr_t",
              "float" => "float",
              "double" => "double",
              "void" => "void",
              "cstr" => "const char*",
            }.fetch(name)
          end

          def generic_c_type(type)
            case type.name
            when "ptr"
              raise LoweringError, "ptr requires exactly one type argument" unless type.arguments.length == 1

              "#{c_type(type.arguments.first)}*"
            when "const_ptr"
              raise LoweringError, "const_ptr requires exactly one type argument" unless type.arguments.length == 1

              "const #{c_type(type.arguments.first)}*"
            when "ref"
              raise LoweringError, "ref requires exactly one type argument" unless type.arguments.length == 1

              "#{c_type(type.arguments.first)}*"
            when "str_buffer"
              raise LoweringError, "str_buffer requires exactly one type argument" unless str_buffer_type?(type)

              str_buffer_type_name(type)
            else
              raise LoweringError, "unsupported generic C type #{type.name}"
            end
          end

          def mutable_pointer_type?(type)
            type.is_a?(Types::GenericInstance) && type.name == "ptr" && type.arguments.length == 1
          end

          def const_pointer_type?(type)
            type.is_a?(Types::GenericInstance) && type.name == "const_ptr" && type.arguments.length == 1
          end

          def pointer_type?(type)
            mutable_pointer_type?(type)
          end

          def raw_pointer_type?(type)
            mutable_pointer_type?(type) || const_pointer_type?(type)
          end

          def ref_type?(type)
            type.is_a?(Types::GenericInstance) && type.name == "ref" && type.arguments.length == 1
          end

          def array_type?(type)
            type.is_a?(Types::GenericInstance) && type.name == "array" && type.arguments.length == 2 &&
              type.arguments[1].is_a?(Types::LiteralTypeArg)
          end

          def array_element_type(type)
            type.arguments.first
          end

          def array_length(type)
            type.arguments[1].value
          end

          def str_buffer_type?(type)
            type.is_a?(Types::GenericInstance) && type.name == "str_buffer" && type.arguments.length == 1 &&
              type.arguments.first.is_a?(Types::LiteralTypeArg) && type.arguments.first.value.is_a?(Integer)
          end

          def str_buffer_capacity(type)
            type.arguments.first.value
          end

          def str_buffer_storage_capacity(type)
            str_buffer_capacity(type) + 1
          end

          def str_buffer_type_name(type)
            "mt_str_buffer_#{str_buffer_capacity(type)}"
          end

          def pointer_to(type)
            Types::GenericInstance.new("ptr", [type])
          end
    end
  end
end
