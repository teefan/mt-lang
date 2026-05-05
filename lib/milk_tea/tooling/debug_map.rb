# frozen_string_literal: true

require "fileutils"
require "json"

module MilkTea
  class DebugMap
    VERSION = 1

    Entry = Data.define(:name, :c_name, :line) do
      def to_h
        payload = {
          "name" => name,
          "cName" => c_name,
        }
        payload["line"] = line if line
        payload
      end
    end

    Function = Data.define(:name, :c_name, :source_path, :line, :params, :locals) do
      def to_h
        payload = {
          "name" => name,
          "cName" => c_name,
          "params" => params.map(&:to_h),
          "locals" => locals.map(&:to_h),
        }
        payload["sourcePath"] = source_path if source_path
        payload["line"] = line if line
        payload
      end
    end

    attr_reader :binary_path, :program_source_path, :functions

    def initialize(binary_path:, program_source_path:, functions:)
      @binary_path = binary_path ? File.expand_path(binary_path) : nil
      @program_source_path = program_source_path ? File.expand_path(program_source_path) : nil
      @functions = functions
      @functions_by_c_name = functions.each_with_object({}) do |function, memo|
        memo[function.c_name] ||= function
      end
    end

    def self.sidecar_path_for(binary_path)
      "#{File.expand_path(binary_path)}.mtdbg.json"
    end

    def self.load(path)
      payload = JSON.parse(File.read(path))
      functions = Array(payload["functions"]).map do |function|
        Function.new(
          name: function.fetch("name"),
          c_name: function.fetch("cName"),
          source_path: function["sourcePath"],
          line: function["line"],
          params: load_entries(function["params"]),
          locals: load_entries(function["locals"])
        )
      end

      new(
        binary_path: payload["binaryPath"],
        program_source_path: payload["programSourcePath"],
        functions:
      )
    end

    def self.load_for_binary(binary_path)
      path = sidecar_path_for(binary_path)
      return nil unless File.file?(path)

      load(path)
    rescue JSON::ParserError
      nil
    end

    def self.from_ir(ir_program, binary_path:)
      functions = ir_program.functions.map do |function|
        source_path = first_statement_source_path(function.body) || ir_program.source_path
        Function.new(
          name: function.name.to_s,
          c_name: function.c_name.to_s,
          source_path: source_path ? File.expand_path(source_path) : nil,
          line: first_statement_line(function.body),
          params: function.params.map { |param| Entry.new(name: param.name.to_s, c_name: param.c_name.to_s, line: nil) },
          locals: collect_locals(function.body)
        )
      end

      new(binary_path:, program_source_path: ir_program.source_path, functions:)
    end

    def write(path)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate(to_h) + "\n")
    end

    def function_for_c_name(c_name)
      @functions_by_c_name[c_name.to_s]
    end

    def variable_for(function_c_name, c_name)
      function = function_for_c_name(function_c_name)
      return nil unless function

      function.params.find { |entry| entry.c_name == c_name.to_s } ||
        function.locals.find { |entry| entry.c_name == c_name.to_s }
    end

    def source_variable_for(function_c_name, source_name)
      function = function_for_c_name(function_c_name)
      return nil unless function

      matches = (function.params + function.locals).select { |entry| entry.name == source_name.to_s }
      return nil if matches.empty?

      return matches.first if matches.map(&:c_name).uniq.one?

      nil
    end

    def to_h
      payload = {
        "version" => VERSION,
        "functions" => functions.map(&:to_h),
      }
      payload["binaryPath"] = binary_path if binary_path
      payload["programSourcePath"] = program_source_path if program_source_path
      payload
    end

    class << self
      private

      def load_entries(entries)
        Array(entries).map do |entry|
          Entry.new(name: entry.fetch("name"), c_name: entry.fetch("cName"), line: entry["line"])
        end
      end

      def collect_locals(statements, locals = [])
        Array(statements).each do |statement|
          case statement
          when IR::LocalDecl
            locals << Entry.new(name: statement.name.to_s, c_name: statement.c_name.to_s, line: statement.line)
          when IR::BlockStmt, IR::WhileStmt
            collect_locals(statement.body, locals)
          when IR::ForStmt
            collect_locals([statement.init], locals)
            collect_locals(statement.body, locals)
            collect_locals([statement.post], locals)
          when IR::IfStmt
            collect_locals(statement.then_body, locals)
            collect_locals(statement.else_body, locals)
          when IR::SwitchStmt
            statement.cases.each do |switch_case|
              collect_locals(switch_case.body, locals)
            end
          end
        end

        locals
      end

      def first_statement_source_path(statements)
        Array(statements).each do |statement|
          if statement.respond_to?(:source_path) && statement.source_path
            return statement.source_path
          end

          nested = nested_statements(statement)
          nested.each do |branch|
            source_path = first_statement_source_path(branch)
            return source_path if source_path
          end
        end

        nil
      end

      def first_statement_line(statements)
        Array(statements).each do |statement|
          if statement.respond_to?(:line) && statement.line
            return statement.line
          end

          nested = nested_statements(statement)
          nested.each do |branch|
            line = first_statement_line(branch)
            return line if line
          end
        end

        nil
      end

      def nested_statements(statement)
        case statement
        when IR::BlockStmt, IR::WhileStmt
          [statement.body]
        when IR::ForStmt
          [[statement.init], statement.body, [statement.post]]
        when IR::IfStmt
          [statement.then_body, statement.else_body]
        when IR::SwitchStmt
          statement.cases.map(&:body)
        else
          []
        end
      end
    end
  end
end
