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
    SourceFile = Data.define(:module_name, :module_kind, :imports, :directives, :declarations)
    Import = Data.define(:path, :alias_name)
    LinkDirective = Data.define(:value)
    IncludeDirective = Data.define(:value)
    ConstDecl = Data.define(:name, :type, :value, :visibility)
    VarDecl = Data.define(:name, :type, :value, :visibility)
    TypeAliasDecl = Data.define(:name, :target, :visibility)
    StructDecl = Data.define(:name, :type_params, :fields, :packed, :alignment, :visibility)
    UnionDecl = Data.define(:name, :fields, :visibility)
    Field = Data.define(:name, :type)
    EnumDecl = Data.define(:name, :backing_type, :members, :visibility)
    FlagsDecl = Data.define(:name, :backing_type, :members, :visibility)
    EnumMember = Data.define(:name, :value)
    OpaqueDecl = Data.define(:name, :c_name, :visibility)
    MethodsBlock = Data.define(:type_name, :methods)
    FunctionDef = Data.define(:name, :type_params, :params, :return_type, :body, :visibility, :async)
    MethodDef = Data.define(:name, :type_params, :params, :return_type, :body, :kind, :visibility, :async)
    ExternFunctionDecl = Data.define(:name, :type_params, :params, :return_type, :variadic)
    ForeignFunctionDecl = Data.define(:name, :type_params, :params, :return_type, :mapping, :visibility)
    Param = Data.define(:name, :type)
    ForeignParam = Data.define(:name, :type, :mode, :boundary_type)
    LocalDecl = Data.define(:kind, :name, :type, :value, :line) do
      def initialize(kind:, name:, type:, value:, line: nil) = super
    end
    Assignment = Data.define(:target, :operator, :value)
    IfBranch = Data.define(:condition, :body)
    IfStmt = Data.define(:branches, :else_body)
    VariantDecl = Data.define(:name, :type_params, :arms, :visibility)
    VariantArm = Data.define(:name, :fields)
    MatchArm = Data.define(:pattern, :binding_name, :body)
    MatchStmt = Data.define(:expression, :arms)
    UnsafeStmt = Data.define(:body)
    StaticAssert = Data.define(:condition, :message)
    ForStmt = Data.define(:name, :iterable, :body)
    WhileStmt = Data.define(:condition, :body)
    BreakStmt = Data.define()
    ContinueStmt = Data.define()
    ReturnStmt = Data.define(:value, :line) do
      def initialize(value:, line: nil) = super
    end
    DeferStmt = Data.define(:expression, :body)
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
