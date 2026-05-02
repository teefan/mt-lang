# frozen_string_literal: true

module MilkTea
  module AST
    class QualifiedName < Data.define(:parts)
      def to_s
        parts.join(".")
      end
    end

    TypeParam = Data.define(:name)
    TypeArgument = Data.define(:value)
    TypeRef = Data.define(:name, :arguments, :nullable)
    FunctionType = Data.define(:params, :return_type)
    ProcType = Data.define(:params, :return_type)
    SourceFile = Data.define(:module_name, :module_kind, :imports, :directives, :declarations, :line) do
      def initialize(module_name:, module_kind:, imports:, directives:, declarations:, line: nil) = super
    end
    Import = Data.define(:path, :alias_name, :line) do
      def initialize(path:, alias_name:, line: nil) = super
    end
    LinkDirective = Data.define(:value)
    IncludeDirective = Data.define(:value)
    ConstDecl = Data.define(:name, :type, :value, :visibility, :line) do
      def initialize(name:, type:, value:, visibility:, line: nil) = super
    end
    VarDecl = Data.define(:name, :type, :value, :visibility, :line) do
      def initialize(name:, type:, value:, visibility:, line: nil) = super
    end
    TypeAliasDecl = Data.define(:name, :target, :visibility, :line) do
      def initialize(name:, target:, visibility:, line: nil) = super
    end
    StructDecl = Data.define(:name, :type_params, :fields, :packed, :alignment, :visibility, :line) do
      def initialize(name:, type_params:, fields:, packed:, alignment:, visibility:, line: nil) = super
    end
    UnionDecl = Data.define(:name, :fields, :visibility, :line) do
      def initialize(name:, fields:, visibility:, line: nil) = super
    end
    Field = Data.define(:name, :type)
    EnumDecl = Data.define(:name, :backing_type, :members, :visibility, :line) do
      def initialize(name:, backing_type:, members:, visibility:, line: nil) = super
    end
    FlagsDecl = Data.define(:name, :backing_type, :members, :visibility, :line) do
      def initialize(name:, backing_type:, members:, visibility:, line: nil) = super
    end
    EnumMember = Data.define(:name, :value)
    OpaqueDecl = Data.define(:name, :c_name, :visibility, :line) do
      def initialize(name:, c_name:, visibility:, line: nil) = super
    end
    MethodsBlock = Data.define(:type_name, :methods, :line) do
      def initialize(type_name:, methods:, line: nil) = super
    end
    FunctionDef = Data.define(:name, :type_params, :params, :return_type, :body, :visibility, :async, :line) do
      def initialize(name:, type_params:, params:, return_type:, body:, visibility:, async:, line: nil) = super
    end
    MethodDef = Data.define(:name, :type_params, :params, :return_type, :body, :kind, :visibility, :async, :line) do
      def initialize(name:, type_params:, params:, return_type:, body:, kind:, visibility:, async:, line: nil) = super
    end
    ExternFunctionDecl = Data.define(:name, :type_params, :params, :return_type, :variadic, :line) do
      def initialize(name:, type_params:, params:, return_type:, variadic:, line: nil) = super
    end
    ForeignFunctionDecl = Data.define(:name, :type_params, :params, :return_type, :mapping, :visibility, :line) do
      def initialize(name:, type_params:, params:, return_type:, mapping:, visibility:, line: nil) = super
    end
    Param = Data.define(:name, :type)
    ForeignParam = Data.define(:name, :type, :mode, :boundary_type)
    LocalDecl = Data.define(:kind, :name, :type, :value, :line) do
      def initialize(kind:, name:, type:, value:, line: nil) = super
    end
    Assignment = Data.define(:target, :operator, :value, :line) do
      def initialize(target:, operator:, value:, line: nil) = super
    end
    IfBranch = Data.define(:condition, :body)
    IfStmt = Data.define(:branches, :else_body, :line) do
      def initialize(branches:, else_body:, line: nil) = super
    end
    VariantDecl = Data.define(:name, :type_params, :arms, :visibility, :line) do
      def initialize(name:, type_params:, arms:, visibility:, line: nil) = super
    end
    VariantArm = Data.define(:name, :fields)
    MatchArm = Data.define(:pattern, :binding_name, :body)
    MatchStmt = Data.define(:expression, :arms, :line) do
      def initialize(expression:, arms:, line: nil) = super
    end
    UnsafeStmt = Data.define(:body, :line) do
      def initialize(body:, line: nil) = super
    end
    StaticAssert = Data.define(:condition, :message, :line) do
      def initialize(condition:, message:, line: nil) = super
    end
    ForStmt = Data.define(:name, :iterable, :body, :line) do
      def initialize(name:, iterable:, body:, line: nil) = super
    end
    WhileStmt = Data.define(:condition, :body, :line) do
      def initialize(condition:, body:, line: nil) = super
    end
    BreakStmt = Data.define(:line) do
      def initialize(line: nil) = super
    end
    ContinueStmt = Data.define(:line) do
      def initialize(line: nil) = super
    end
    ReturnStmt = Data.define(:value, :line) do
      def initialize(value:, line: nil) = super
    end
    DeferStmt = Data.define(:expression, :body, :line) do
      def initialize(expression:, body:, line: nil) = super
    end
    ExpressionStmt = Data.define(:expression, :line) do
      def initialize(expression:, line: nil) = super
    end

    Identifier = Data.define(:name)
    MemberAccess = Data.define(:receiver, :member)
    IndexAccess = Data.define(:receiver, :index)
    Specialization = Data.define(:callee, :arguments)
    Call = Data.define(:callee, :arguments)
    Argument = Data.define(:name, :value)
    UnaryOp = Data.define(:operator, :operand)
    BinaryOp = Data.define(:operator, :left, :right)
    IfExpr = Data.define(:condition, :then_expression, :else_expression)
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
