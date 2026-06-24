# frozen_string_literal: true

module MilkTea
  module AST
    class QualifiedName < Data.define(:parts, :type_arguments, :line, :column, :id)
      def initialize(parts:, type_arguments: [], line: nil, column: nil, id: nil) = super
      def to_s
        parts.join(".")
      end
    end

    TypeParamConstraint = Data.define(:kind, :interface_ref, :id) do
      def initialize(kind:, interface_ref: nil, id: nil) = super
    end

    TypeParam = Data.define(:name, :constraints, :line, :column, :length, :id) do
      def initialize(name:, constraints: [], line: nil, column: nil, length: nil, id: nil) = super
    end
    ValueTypeParam = Data.define(:name, :type, :line, :column, :length, :id) do
      def initialize(name:, type:, line: nil, column: nil, length: nil, id: nil) = super
    end
    TypeArgument = Data.define(:value, :id) do
      def initialize(value:, id: nil) = super
    end
    class TypeRef < Data.define(:name, :arguments, :nullable, :lifetime, :line, :column, :length, :id)
      def initialize(name:, arguments:, nullable:, lifetime: nil, line: nil, column: nil, length: nil, id: nil) = super

      def to_s
        text = name.to_s
        args = []
        args << lifetime if lifetime
        args.concat(arguments.map do |argument|
          value = argument.value
          case value
          when IntegerLiteral, FloatLiteral then value.lexeme
          else value.to_s
          end
        end)
        unless args.empty?
          text += "[#{args.join(', ')}]"
        end
        nullable ? "#{text}?" : text
      end
    end
    FunctionType = Data.define(:params, :return_type, :id) do
      def initialize(params:, return_type:, id: nil) = super
    end
    ProcType = Data.define(:params, :return_type, :id) do
      def initialize(params:, return_type:, id: nil) = super
    end
    TupleType = Data.define(:element_types, :nullable, :id) do
      def initialize(element_types:, nullable: false, id: nil) = super
    end
    DynType = Data.define(:interface, :nullable, :line, :column, :length, :id) do
      def initialize(interface:, nullable: false, line: nil, column: nil, length: nil, id: nil) = super
    end
    SourceFile = Data.define(:module_name, :module_kind, :imports, :directives, :declarations, :line, :id) do
      def initialize(module_name:, module_kind:, imports:, directives:, declarations:, line: nil, id: nil) = super
    end
    Import = Data.define(:path, :alias_name, :line, :column, :length, :id) do
      def initialize(path:, alias_name:, line: nil, column: nil, length: nil, id: nil) = super
    end
    LinkDirective = Data.define(:value, :id) do
      def initialize(value:, id: nil) = super
    end
    IncludeDirective = Data.define(:value, :id) do
      def initialize(value:, id: nil) = super
    end
    CompilerFlagDirective = Data.define(:value, :id) do
      def initialize(value:, id: nil) = super
    end
    ConstDecl = Data.define(:name, :type, :value, :block_body, :visibility, :attributes, :line, :column, :id) do
      def initialize(name:, type:, value:, block_body: nil, visibility:, attributes: [], line: nil, column: nil, id: nil) = super
    end
    VarDecl = Data.define(:name, :type, :value, :visibility, :line, :column, :id) do
      def initialize(name:, type:, value:, visibility:, line: nil, column: nil, id: nil) = super
    end
    EventDecl = Data.define(:name, :capacity, :payload_type, :visibility, :attributes, :line, :column, :id) do
      def initialize(name:, capacity:, payload_type: nil, visibility:, attributes: [], line: nil, column: nil, id: nil) = super
    end
    TypeAliasDecl = Data.define(:name, :target, :visibility, :line, :column, :id) do
      def initialize(name:, target:, visibility:, line: nil, column: nil, id: nil) = super
    end
    AttributeDecl = Data.define(:name, :targets, :params, :visibility, :line, :column, :id) do
      def initialize(name:, targets:, params:, visibility:, line: nil, column: nil, id: nil) = super
    end
    AttributeApplication = Data.define(:name, :arguments, :line, :column, :id) do
      def initialize(name:, arguments:, line: nil, column: nil, id: nil) = super
    end
    StructDecl = Data.define(:name, :type_params, :implements, :c_name, :fields, :events, :nested_types, :attributes, :packed, :alignment, :visibility, :lifetime_params, :line, :column, :id) do
      def initialize(name:, type_params:, implements:, c_name:, fields:, events: [], nested_types: [], attributes: [], packed:, alignment:, visibility:, lifetime_params: [], line: nil, column: nil, id: nil) = super
    end
    UnionDecl = Data.define(:name, :c_name, :fields, :visibility, :attributes, :line, :column, :id) do
      def initialize(name:, c_name:, fields:, visibility:, attributes: [], line: nil, column: nil, id: nil) = super
    end
    Field = Data.define(:name, :type, :attributes, :line, :column, :id) do
      def initialize(name:, type:, attributes: [], line: nil, column: nil, id: nil) = super
    end
    EnumDecl = Data.define(:name, :backing_type, :members, :visibility, :attributes, :line, :column, :id) do
      def initialize(name:, backing_type:, members:, visibility:, attributes: [], line: nil, column: nil, id: nil) = super
    end
    FlagsDecl = Data.define(:name, :backing_type, :members, :visibility, :attributes, :line, :column, :id) do
      def initialize(name:, backing_type:, members:, visibility:, attributes: [], line: nil, column: nil, id: nil) = super
    end
    EnumMember = Data.define(:name, :value, :line, :column, :id) do
      def initialize(name:, value:, line: nil, column: nil, id: nil) = super
    end
    OpaqueDecl = Data.define(:name, :implements, :c_name, :visibility, :line, :column, :id) do
      def initialize(name:, implements:, c_name:, visibility:, line: nil, column: nil, id: nil) = super
    end
    InterfaceDecl = Data.define(:name, :type_params, :methods, :visibility, :line, :column, :id) do
      def initialize(name:, type_params: [], methods:, visibility:, line: nil, column: nil, id: nil) = super
    end
    ExtendingBlock = Data.define(:type_name, :methods, :line, :column, :id) do
      def initialize(type_name:, methods:, line: nil, column: nil, id: nil) = super
    end
    InterfaceMethodDecl = Data.define(:name, :params, :return_type, :kind, :async, :attributes, :line, :column, :id) do
      def initialize(name:, params:, return_type:, kind:, async:, attributes: [], line: nil, column: nil, id: nil) = super
    end
    FunctionDef = Data.define(:name, :type_params, :params, :return_type, :body, :visibility, :async, :const, :attributes, :line, :column, :id) do
      def initialize(name:, type_params:, params:, return_type:, body:, visibility:, async:, const: false, attributes: [], line: nil, column: nil, id: nil) = super
    end
    MethodDef = Data.define(:name, :type_params, :params, :return_type, :body, :kind, :visibility, :async, :attributes, :line, :column, :id) do
      def initialize(name:, type_params:, params:, return_type:, body:, kind:, visibility:, async:, attributes: [], line: nil, column: nil, id: nil) = super
    end
    ExternFunctionDecl = Data.define(:name, :type_params, :params, :return_type, :variadic, :attributes, :line, :mapping, :id) do
      def initialize(name:, type_params:, params:, return_type:, variadic:, attributes: [], line: nil, mapping: nil, id: nil) = super
    end
    ForeignFunctionDecl = Data.define(:name, :type_params, :params, :return_type, :variadic, :mapping, :visibility, :attributes, :line, :id) do
      def initialize(name:, type_params:, params:, return_type:, variadic:, mapping:, visibility:, attributes: [], line: nil, id: nil) = super
    end
    Param = Data.define(:name, :type, :line, :column, :id) do
      def initialize(name:, type:, line: nil, column: nil, id: nil) = super
    end
    ForeignParam = Data.define(:name, :type, :mode, :boundary_type, :id) do
      def initialize(name:, type:, mode:, boundary_type:, id: nil) = super
    end
    LocalDecl = Data.define(:kind, :name, :type, :value, :else_binding, :else_body, :line, :column, :recovered_else, :destructure_bindings, :destructure_type_name, :id) do
      def initialize(kind:, name:, type:, value:, else_binding: nil, else_body: nil, line: nil, column: nil, recovered_else: false, destructure_bindings: nil, destructure_type_name: nil, id: nil) = super
    end
    Assignment = Data.define(:target, :operator, :value, :line, :column, :id) do
      def initialize(target:, operator:, value:, line: nil, column: nil, id: nil) = super
    end
    IfBranch = Data.define(:condition, :body, :line, :column, :length, :id) do
      def initialize(condition:, body:, line: nil, column: nil, length: nil, id: nil) = super
    end
    IfStmt = Data.define(:branches, :else_body, :inline, :line, :else_line, :else_column, :id) do
      def initialize(branches:, else_body:, inline: false, line: nil, else_line: nil, else_column: nil, id: nil) = super
    end
    VariantDecl = Data.define(:name, :type_params, :arms, :visibility, :attributes, :line, :column, :id) do
      def initialize(name:, type_params:, arms:, visibility:, attributes: [], line: nil, column: nil, id: nil) = super
    end
    VariantArm = Data.define(:name, :fields, :id) do
      def initialize(name:, fields:, id: nil) = super
    end
    MatchArm = Data.define(:pattern, :binding_name, :binding_line, :binding_column, :body, :id) do
      def initialize(pattern:, binding_name:, body:, binding_line: nil, binding_column: nil, id: nil) = super
    end
    MatchStmt = Data.define(:expression, :arms, :inline, :line, :column, :length, :id) do
      def initialize(expression:, arms:, inline: false, line: nil, column: nil, length: nil, id: nil) = super
    end
    MatchExprArm = Data.define(:pattern, :binding_name, :binding_line, :binding_column, :value, :id) do
      def initialize(pattern:, binding_name:, value:, binding_line: nil, binding_column: nil, id: nil) = super
    end
    WhenBranch = Data.define(:pattern, :binding_name, :binding_line, :binding_column, :body, :id) do
      def initialize(pattern:, binding_name:, body:, binding_line: nil, binding_column: nil, id: nil) = super
    end
    WhenStmt = Data.define(:discriminant, :branches, :else_body, :line, :column, :length, :id) do
      def initialize(discriminant:, branches:, else_body:, line: nil, column: nil, length: nil, id: nil) = super
    end
    UnsafeStmt = Data.define(:body, :line, :column, :length, :id) do
      def initialize(body:, line: nil, column: nil, length: nil, id: nil) = super
    end
    StaticAssert = Data.define(:condition, :message, :line, :id) do
      def initialize(condition:, message:, line: nil, id: nil) = super
    end
    EmitStmt = Data.define(:declaration, :line, :column, :id) do
      def initialize(declaration:, line: nil, column: nil, id: nil) = super
    end
    ForBinding = Data.define(:name, :line, :column, :id) do
      def initialize(name:, line: nil, column: nil, id: nil) = super
    end
    ForStmt = Data.define(:bindings, :iterables, :body, :inline, :threaded, :line, :column, :id) do
      def initialize(bindings:, iterables:, body:, inline: false, threaded: false, line: nil, column: nil, id: nil) = super
      def name = bindings.first.name
      def names = bindings.map(&:name)
      def binding = bindings.first
      def iterable = iterables.first
      def parallel? = bindings.length > 1 || iterables.length > 1
    end
    ParallelBlockStmt = Data.define(:bodies, :line, :column, :id) do
      def initialize(bodies:, line: nil, column: nil, id: nil) = super
    end
    DetachExpr = Data.define(:body, :line, :column, :id) do
      def initialize(body:, line: nil, column: nil, id: nil) = super
    end
    GatherStmt = Data.define(:handles, :line, :column, :id) do
      def initialize(handles:, line: nil, column: nil, id: nil) = super
    end
    WhileStmt = Data.define(:condition, :body, :inline, :line, :column, :length, :id) do
      def initialize(condition:, body:, inline: false, line: nil, column: nil, length: nil, id: nil) = super
    end
    BreakStmt = Data.define(:line, :column, :length, :id) do
      def initialize(line: nil, column: nil, length: nil, id: nil) = super
    end
    ContinueStmt = Data.define(:line, :column, :length, :id) do
      def initialize(line: nil, column: nil, length: nil, id: nil) = super
    end
    PassStmt = Data.define(:line, :column, :length, :id) do
      def initialize(line: nil, column: nil, length: nil, id: nil) = super
    end
    ReturnStmt = Data.define(:value, :line, :column, :length, :id) do
      def initialize(value:, line: nil, column: nil, length: nil, id: nil) = super
    end
    DeferStmt = Data.define(:expression, :body, :line, :column, :length, :id) do
      def initialize(expression:, body:, line: nil, column: nil, length: nil, id: nil) = super
    end
    ErrorBlockStmt = Data.define(:body, :line, :column, :length, :message, :header_type, :header_expression, :header_bindings, :header_iterables, :id) do
      def initialize(body:, line: nil, column: nil, length: nil, message: nil, header_type: nil, header_expression: nil, header_bindings: nil, header_iterables: nil, id: nil) = super
    end
    ErrorStmt = Data.define(:line, :column, :length, :message, :id) do
      def initialize(line: nil, column: nil, length: nil, message: nil, id: nil) = super
    end
    ErrorExpr = Data.define(:line, :column, :length, :message, :id) do
      def initialize(line: nil, column: nil, length: nil, message: nil, id: nil) = super
    end
    ExpressionStmt = Data.define(:expression, :line, :id) do
      def initialize(expression:, line: nil, id: nil) = super
    end

    Identifier = Data.define(:name, :line, :column, :id) do
      def initialize(name:, line: nil, column: nil, id: nil) = super
    end
    MemberAccess = Data.define(:receiver, :member, :line, :column, :id) do
      def initialize(receiver:, member:, line: nil, column: nil, id: nil) = super
    end
    IndexAccess = Data.define(:receiver, :index, :id) do
      def initialize(receiver:, index:, id: nil) = super
    end
    Specialization = Data.define(:callee, :arguments, :id) do
      def initialize(callee:, arguments:, id: nil) = super
    end
    Call = Data.define(:callee, :arguments, :id) do
      def initialize(callee:, arguments:, id: nil) = super
    end
    Argument = Data.define(:name, :value, :id) do
      def initialize(name:, value:, id: nil) = super
    end
    UnaryOp = Data.define(:operator, :operand, :id) do
      def initialize(operator:, operand:, id: nil) = super
    end
    BinaryOp = Data.define(:operator, :left, :right, :id) do
      def initialize(operator:, left:, right:, id: nil) = super
    end
    RangeExpr = Data.define(:start_expr, :end_expr, :line, :column, :id) do
      def initialize(start_expr:, end_expr:, line: nil, column: nil, id: nil) = super
    end
    ExpressionList = Data.define(:elements, :line, :column, :id) do
      def initialize(elements:, line: nil, column: nil, id: nil) = super
    end
    IfExpr = Data.define(:condition, :then_expression, :else_expression, :id) do
      def initialize(condition:, then_expression:, else_expression:, id: nil) = super
    end
    MatchExpr = Data.define(:expression, :arms, :line, :column, :length, :id) do
      def initialize(expression:, arms:, line: nil, column: nil, length: nil, id: nil) = super
    end
    UnsafeExpr = Data.define(:expression, :line, :column, :length, :id) do
      def initialize(expression:, line: nil, column: nil, length: nil, id: nil) = super
    end
    ProcExpr = Data.define(:params, :return_type, :body, :id) do
      def initialize(params:, return_type:, body:, id: nil) = super
    end
    AwaitExpr = Data.define(:expression, :id) do
      def initialize(expression:, id: nil) = super
    end
    SizeofExpr = Data.define(:type, :id) do
      def initialize(type:, id: nil) = super
    end
    AlignofExpr = Data.define(:type, :id) do
      def initialize(type:, id: nil) = super
    end
    OffsetofExpr = Data.define(:type, :field, :id) do
      def initialize(type:, field:, id: nil) = super
    end
    IntegerLiteral = Data.define(:lexeme, :value, :id) do
      def initialize(lexeme:, value:, id: nil) = super
    end
    FloatLiteral = Data.define(:lexeme, :value, :id) do
      def initialize(lexeme:, value:, id: nil) = super
    end
    StringLiteral = Data.define(:lexeme, :value, :cstring, :id) do
      def initialize(lexeme:, value:, cstring:, id: nil) = super
    end
    FormatString = Data.define(:parts, :id) do
      def initialize(parts:, id: nil) = super
    end
    FormatTextPart = Data.define(:value, :id) do
      def initialize(value:, id: nil) = super
    end
    FormatExprPart = Data.define(:expression, :format_spec, :id) do
      def initialize(expression:, format_spec:, id: nil) = super
    end
    CharLiteral = Data.define(:lexeme, :value, :line, :column, :id) do
      def initialize(lexeme:, value:, line: nil, column: nil, id: nil) = super
    end
    BooleanLiteral = Data.define(:value, :id) do
      def initialize(value:, id: nil) = super
    end
    NullLiteral = Data.define(:type, :line, :column, :id) do
      def initialize(type:, line: nil, column: nil, id: nil) = super
    end
    PrefixCast = Data.define(:target_type, :expression, :id) do
      def initialize(target_type:, expression:, id: nil) = super
    end

    def self.assign_node_ids(source_file)
      next_id = 0

      visit = ->(node) do
        return node unless node.is_a?(::Data)

        current_id = (next_id += 1)
        updated = node

        node.class.members.each do |field_name|
          next if %i[module_name module_kind id].include?(field_name)

          value = node.public_send(field_name)
          next unless value

          case value
          when ::Data
            updated = updated.with(field_name => visit.call(value))
          when Array
            updated = updated.with(field_name => value.map { |v| v.is_a?(::Data) ? visit.call(v) : v })
          end
        end

        updated.with(id: current_id)
      end

      visit.call(source_file)
    end

    def self.build_chain_from_parts(parts)
      return nil unless parts.length >= 1

      expr = Identifier.new(name: parts.first)
      parts[1..].each do |part|
        expr = MemberAccess.new(receiver: expr, member: part)
      end
      expr
    end
  end
end
