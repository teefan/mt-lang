# frozen_string_literal: true

module MilkTea
  module AST
    class QualifiedName < Data.define(:parts)
      def to_s
        parts.join(".")
      end
    end

    TypeParamConstraint = Data.define(:kind, :interface_ref) do
      def initialize(kind:, interface_ref: nil) = super
    end

    TypeParam = Data.define(:name, :constraints) do
      def initialize(name:, constraints: []) = super
    end
    TypeArgument = Data.define(:value)
    class TypeRef < Data.define(:name, :arguments, :nullable)
      def to_s
        text = name.to_s
        unless arguments.empty?
          rendered_arguments = arguments.map do |argument|
            value = argument.value
            value.respond_to?(:to_s) ? value.to_s : value.inspect
          end
          text += "[#{rendered_arguments.join(', ')}]"
        end
        nullable ? "#{text}?" : text
      end
    end
    FunctionType = Data.define(:params, :return_type)
    ProcType = Data.define(:params, :return_type)
    SourceFile = Data.define(:module_name, :module_kind, :imports, :directives, :declarations, :line) do
      def initialize(module_name:, module_kind:, imports:, directives:, declarations:, line: nil) = super
    end
    Import = Data.define(:path, :alias_name, :line, :column, :length) do
      def initialize(path:, alias_name:, line: nil, column: nil, length: nil) = super
    end
    LinkDirective = Data.define(:value)
    IncludeDirective = Data.define(:value)
    CompilerFlagDirective = Data.define(:value)
    ConstDecl = Data.define(:name, :type, :value, :visibility, :line) do
      def initialize(name:, type:, value:, visibility:, line: nil) = super
    end
    VarDecl = Data.define(:name, :type, :value, :visibility, :line) do
      def initialize(name:, type:, value:, visibility:, line: nil) = super
    end
    TypeAliasDecl = Data.define(:name, :target, :visibility, :line) do
      def initialize(name:, target:, visibility:, line: nil) = super
    end
    StructDecl = Data.define(:name, :type_params, :implements, :c_name, :fields, :packed, :alignment, :visibility, :line) do
      def initialize(name:, type_params:, implements:, c_name:, fields:, packed:, alignment:, visibility:, line: nil) = super
    end
    UnionDecl = Data.define(:name, :c_name, :fields, :visibility, :line) do
      def initialize(name:, c_name:, fields:, visibility:, line: nil) = super
    end
    Field = Data.define(:name, :type) do
      def initialize(name:, type:) = super
    end
    EnumDecl = Data.define(:name, :backing_type, :members, :visibility, :line) do
      def initialize(name:, backing_type:, members:, visibility:, line: nil) = super
    end
    FlagsDecl = Data.define(:name, :backing_type, :members, :visibility, :line) do
      def initialize(name:, backing_type:, members:, visibility:, line: nil) = super
    end
    EnumMember = Data.define(:name, :value)
    OpaqueDecl = Data.define(:name, :implements, :c_name, :visibility, :line) do
      def initialize(name:, implements:, c_name:, visibility:, line: nil) = super
    end
    InterfaceDecl = Data.define(:name, :methods, :visibility, :line) do
      def initialize(name:, methods:, visibility:, line: nil) = super
    end
    MethodsBlock = Data.define(:type_name, :methods, :line) do
      def initialize(type_name:, methods:, line: nil) = super
    end
    InterfaceMethodDecl = Data.define(:name, :params, :return_type, :kind, :async, :line, :column) do
      def initialize(name:, params:, return_type:, kind:, async:, line: nil, column: nil) = super
    end
    FunctionDef = Data.define(:name, :type_params, :params, :return_type, :body, :visibility, :async, :line, :column) do
      def initialize(name:, type_params:, params:, return_type:, body:, visibility:, async:, line: nil, column: nil) = super
    end
    MethodDef = Data.define(:name, :type_params, :params, :return_type, :body, :kind, :visibility, :async, :line, :column) do
      def initialize(name:, type_params:, params:, return_type:, body:, kind:, visibility:, async:, line: nil, column: nil) = super
    end
    ExternFunctionDecl = Data.define(:name, :type_params, :params, :return_type, :variadic, :line) do
      def initialize(name:, type_params:, params:, return_type:, variadic:, line: nil) = super
    end
    ForeignFunctionDecl = Data.define(:name, :type_params, :params, :return_type, :variadic, :mapping, :visibility, :line) do
      def initialize(name:, type_params:, params:, return_type:, variadic:, mapping:, visibility:, line: nil) = super
    end
    Param = Data.define(:name, :type, :line, :column) do
      def initialize(name:, type:, line: nil, column: nil) = super
    end
    ForeignParam = Data.define(:name, :type, :mode, :boundary_type)
    LocalDecl = Data.define(:kind, :name, :type, :value, :else_body, :line, :column) do
      def initialize(kind:, name:, type:, value:, else_body: nil, line: nil, column: nil) = super
    end
    Assignment = Data.define(:target, :operator, :value, :line) do
      def initialize(target:, operator:, value:, line: nil) = super
    end
    IfBranch = Data.define(:condition, :body, :line, :column, :length) do
      def initialize(condition:, body:, line: nil, column: nil, length: nil) = super
    end
    IfStmt = Data.define(:branches, :else_body, :line, :else_line, :else_column) do
      def initialize(branches:, else_body:, line: nil, else_line: nil, else_column: nil) = super
    end
    VariantDecl = Data.define(:name, :type_params, :arms, :visibility, :line) do
      def initialize(name:, type_params:, arms:, visibility:, line: nil) = super
    end
    VariantArm = Data.define(:name, :fields)
    MatchArm = Data.define(:pattern, :binding_name, :binding_line, :binding_column, :body) do
      def initialize(pattern:, binding_name:, body:, binding_line: nil, binding_column: nil) = super
    end
    MatchStmt = Data.define(:expression, :arms, :line, :column, :length) do
      def initialize(expression:, arms:, line: nil, column: nil, length: nil) = super
    end
    UnsafeStmt = Data.define(:body, :line, :column, :length) do
      def initialize(body:, line: nil, column: nil, length: nil) = super
    end
    StaticAssert = Data.define(:condition, :message, :line) do
      def initialize(condition:, message:, line: nil) = super
    end
    ForBinding = Data.define(:name, :line, :column) do
      def initialize(name:, line: nil, column: nil) = super
    end
    ForStmt = Data.define(:bindings, :iterables, :body, :line, :column) do
      def initialize(bindings:, iterables:, body:, line: nil, column: nil) = super
      def name = bindings.first.name
      def names = bindings.map(&:name)
      def binding = bindings.first
      def iterable = iterables.first
      def parallel? = bindings.length > 1 || iterables.length > 1
    end
    WhileStmt = Data.define(:condition, :body, :line, :column, :length) do
      def initialize(condition:, body:, line: nil, column: nil, length: nil) = super
    end
    BreakStmt = Data.define(:line, :column, :length) do
      def initialize(line: nil, column: nil, length: nil) = super
    end
    ContinueStmt = Data.define(:line, :column, :length) do
      def initialize(line: nil, column: nil, length: nil) = super
    end
    ReturnStmt = Data.define(:value, :line, :column, :length) do
      def initialize(value:, line: nil, column: nil, length: nil) = super
    end
    DeferStmt = Data.define(:expression, :body, :line, :column, :length) do
      def initialize(expression:, body:, line: nil, column: nil, length: nil) = super
    end
    ExpressionStmt = Data.define(:expression, :line) do
      def initialize(expression:, line: nil) = super
    end

    Identifier = Data.define(:name, :line, :column) do
      def initialize(name:, line: nil, column: nil) = super
    end
    MemberAccess = Data.define(:receiver, :member)
    IndexAccess = Data.define(:receiver, :index)
    Specialization = Data.define(:callee, :arguments)
    Call = Data.define(:callee, :arguments)
    Argument = Data.define(:name, :value)
    UnaryOp = Data.define(:operator, :operand)
    BinaryOp = Data.define(:operator, :left, :right)
    RangeExpr = Data.define(:start_expr, :end_expr, :line, :column)
    ExpressionList = Data.define(:elements, :line, :column)
    IfExpr = Data.define(:condition, :then_expression, :else_expression)
    UnsafeExpr = Data.define(:expression, :line, :column, :length) do
      def initialize(expression:, line: nil, column: nil, length: nil) = super
    end
    ProcExpr = Data.define(:params, :return_type, :body)
    AwaitExpr = Data.define(:expression)
    SizeofExpr = Data.define(:type)
    AlignofExpr = Data.define(:type)
    OffsetofExpr = Data.define(:type, :field)
    IntegerLiteral = Data.define(:lexeme, :value)
    FloatLiteral = Data.define(:lexeme, :value)
    StringLiteral = Data.define(:lexeme, :value, :cstring)
    FormatString = Data.define(:parts)
    FormatTextPart = Data.define(:value)
    FormatExprPart = Data.define(:expression, :format_spec)
    BooleanLiteral = Data.define(:value)
    NullLiteral = Data.define(:type)
  end
end
