# frozen_string_literal: true

module MilkTea
  module IR
    Program = Data.define(:module_name, :includes, :constants, :structs, :unions, :enums, :functions)
    Include = Data.define(:header)
    Constant = Data.define(:name, :c_name, :type, :value)
    StructDecl = Data.define(:name, :c_name, :fields)
    UnionDecl = Data.define(:name, :c_name, :fields)
    EnumDecl = Data.define(:name, :c_name, :backing_type, :members, :flags)
    EnumMember = Data.define(:name, :c_name, :value)
    Field = Data.define(:name, :type)
    Function = Data.define(:name, :c_name, :params, :return_type, :body, :entry_point)
    Param = Data.define(:name, :c_name, :type, :pointer)

    LocalDecl = Data.define(:name, :c_name, :type, :value)
    Assignment = Data.define(:target, :operator, :value)
    BlockStmt = Data.define(:body)
    IfStmt = Data.define(:condition, :then_body, :else_body)
    SwitchCase = Data.define(:value, :body)
    SwitchStmt = Data.define(:expression, :cases)
    WhileStmt = Data.define(:condition, :body)
    ReturnStmt = Data.define(:value)
    ExpressionStmt = Data.define(:expression)

    Name = Data.define(:name, :type, :pointer)
    Member = Data.define(:receiver, :member, :type)
    Index = Data.define(:receiver, :index, :type)
    Call = Data.define(:callee, :arguments, :type)
    Unary = Data.define(:operator, :operand, :type)
    Binary = Data.define(:operator, :left, :right, :type)
    IntegerLiteral = Data.define(:value, :type)
    FloatLiteral = Data.define(:value, :type)
    StringLiteral = Data.define(:value, :type, :cstring)
    BooleanLiteral = Data.define(:value, :type)
    NullLiteral = Data.define(:type)
    AddressOf = Data.define(:expression, :type)
    Cast = Data.define(:target_type, :expression, :type)
    AggregateLiteral = Data.define(:type, :fields)
    AggregateField = Data.define(:name, :value)
    ArrayLiteral = Data.define(:type, :elements)
  end
end
