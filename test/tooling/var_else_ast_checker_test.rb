# frozen_string_literal: true

require "set"
require_relative "../test_helper"
require_relative "../../lib/milk_tea/bindings"

class MilkTeaVarElseAstCheckerTest < Minitest::Test
  OFFENSE_LABEL = "let-else mutable-copy workaround".freeze
  LOOKAHEAD_LIMIT = 4

  def test_projects_and_handwritten_std_avoid_let_else_var_copy_workaround
    offenses = []

    each_checked_source_file do |path|
      parse_result = MilkTea::Parser.parse_collecting_errors(File.read(path), path: path)
      ast = parse_result.ast
      next unless ast

      scan_declarations(ast.declarations, path, offenses)
    end

    assert offenses.empty?, <<~MESSAGE
      Found #{OFFENSE_LABEL} patterns. Rewrite these as `var name = expr else:` declarations.
      #{offenses.join("\n")}
    MESSAGE
  end

  private

  def each_checked_source_file
    binding_paths = binding_source_paths
    patterns = [
      File.join(MilkTea.root, "projects/**/*.mt"),
      File.join(MilkTea.root, "std/**/*.mt"),
    ]

    patterns
      .flat_map { |pattern| Dir.glob(pattern) }
      .map { |path| File.expand_path(path) }
      .uniq
      .sort
      .each do |path|
        next if binding_paths.include?(path)

        yield(path)
      end
  end

  def binding_source_paths
    @binding_source_paths ||= begin
      raw_paths = MilkTea::RawBindings.default_registry(root: MilkTea.root).map(&:binding_path)
      imported_paths = MilkTea::ImportedBindings.default_registry(root: MilkTea.root).map(&:binding_path)
      (raw_paths + imported_paths).map { |path| File.expand_path(path) }.to_set
    end
  end

  def scan_declarations(declarations, path, offenses)
    declarations.each do |declaration|
      case declaration
      when MilkTea::AST::FunctionDef, MilkTea::AST::MethodDef
        scan_statement_list(declaration.body, path, offenses)
      when MilkTea::AST::ExtendingBlock
        declaration.methods.each do |method|
          scan_statement_list(method.body, path, offenses)
        end
      end
    end
  end

  def scan_statement_list(statements, path, offenses)
    return unless statements.is_a?(Array)

    statements.each_with_index do |left, index|
      next unless let_else_decl?(left)

      find_workaround_copy(statements, start_index: index + 1, source_name: left.name)&.then do |copy_statement|
        relative_path = path.delete_prefix(MilkTea.root.to_s + File::SEPARATOR)
        offenses << "#{relative_path}:#{copy_statement.line}: replace `var #{copy_statement.name} = #{left.name}` with `var #{copy_statement.name} = ... else:`"
      end
    end

    statements.each do |statement|
      nested_statement_lists(statement).each do |nested|
        scan_statement_list(nested, path, offenses)
      end
    end
  end

  def let_else_decl?(statement)
    statement.is_a?(MilkTea::AST::LocalDecl) &&
      statement.kind == :let &&
      statement.name != "_" &&
      !statement.else_body.nil?
  end

  def var_copy_decl?(statement, source_name:)
    return false unless statement.is_a?(MilkTea::AST::LocalDecl)
    return false unless statement.kind == :var

    value = statement.value
    value.is_a?(MilkTea::AST::Identifier) && value.name == source_name
  end

  def find_workaround_copy(statements, start_index:, source_name:)
    lookahead_end = [start_index + LOOKAHEAD_LIMIT - 1, statements.length - 1].min
    index = start_index
    while index <= lookahead_end
      statement = statements[index]
      return statement if var_copy_decl?(statement, source_name:)
      return nil unless harmless_intervening_statement?(statement, source_name:)

      index += 1
    end

    nil
  end

  def harmless_intervening_statement?(statement, source_name:)
    return true if statement.is_a?(MilkTea::AST::PassStmt)

    return false unless statement.is_a?(MilkTea::AST::LocalDecl)
    return false unless statement.kind == :let
    return false unless statement.else_body.nil?

    !expression_references_identifier?(statement.value, source_name)
  end

  def expression_references_identifier?(expression, identifier_name)
    return false if expression.nil?
    return false unless expression.respond_to?(:members)

    case expression
    when MilkTea::AST::Identifier
      expression.name == identifier_name
    else
      expression
        .members
        .map { |member| expression.public_send(member) }
        .any? { |value| value_references_identifier?(value, identifier_name) }
    end
  end

  def value_references_identifier?(value, identifier_name)
    case value
    when Array
      value.any? { |item| value_references_identifier?(item, identifier_name) }
    else
      expression_references_identifier?(value, identifier_name)
    end
  end

  def nested_statement_lists(statement)
    case statement
    when MilkTea::AST::IfStmt
      statement.branches.map(&:body) + [statement.else_body]
    when MilkTea::AST::MatchStmt
      statement.arms.map(&:body)
    when MilkTea::AST::UnsafeStmt
      [statement.body]
    when MilkTea::AST::ForStmt
      [statement.body]
    when MilkTea::AST::WhileStmt
      [statement.body]
    when MilkTea::AST::DeferStmt
      statement.body.is_a?(Array) ? [statement.body] : []
    when MilkTea::AST::ErrorBlockStmt
      [statement.body]
    else
      []
    end
  end
end
