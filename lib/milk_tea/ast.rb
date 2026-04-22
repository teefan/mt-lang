# frozen_string_literal: true

module MilkTea
  module AST
    class QualifiedName < Data.define(:parts)
      def to_s
        parts.join(".")
      end
    end

    TypeArgument = Data.define(:value)
    TypeRef = Data.define(:name, :arguments, :nullable)
    FunctionType = Data.define(:params, :return_type)
    SourceFile = Data.define(:module_name, :module_kind, :imports, :directives, :declarations)
    Import = Data.define(:path, :alias_name)
    LinkDirective = Data.define(:value)
    IncludeDirective = Data.define(:value)
    ConstDecl = Data.define(:name, :type, :value)
    TypeAliasDecl = Data.define(:name, :target)
    StructDecl = Data.define(:name, :fields)
    UnionDecl = Data.define(:name, :fields)
    Field = Data.define(:name, :type)
    EnumDecl = Data.define(:name, :backing_type, :members)
    FlagsDecl = Data.define(:name, :backing_type, :members)
    EnumMember = Data.define(:name, :value)
    OpaqueDecl = Data.define(:name)
    ImplBlock = Data.define(:type_name, :methods)
    FunctionDef = Data.define(:name, :params, :return_type, :body)
    ExternFunctionDecl = Data.define(:name, :params, :return_type)
    Param = Data.define(:name, :type, :mutable)
    LocalDecl = Data.define(:kind, :name, :type, :value)
    Assignment = Data.define(:target, :operator, :value)
    IfBranch = Data.define(:condition, :body)
    IfStmt = Data.define(:branches, :else_body)
    WhileStmt = Data.define(:condition, :body)
    ReturnStmt = Data.define(:value)
    DeferStmt = Data.define(:expression)
    ExpressionStmt = Data.define(:expression)

    Identifier = Data.define(:name)
    MemberAccess = Data.define(:receiver, :member)
    Specialization = Data.define(:callee, :arguments)
    Call = Data.define(:callee, :arguments)
    Argument = Data.define(:name, :value)
    UnaryOp = Data.define(:operator, :operand)
    BinaryOp = Data.define(:operator, :left, :right)
    IntegerLiteral = Data.define(:lexeme, :value)
    FloatLiteral = Data.define(:lexeme, :value)
    StringLiteral = Data.define(:lexeme, :value, :cstring)
    BooleanLiteral = Data.define(:value)
    NullLiteral = Data.define()
  end
end
