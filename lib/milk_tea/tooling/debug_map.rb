# frozen_string_literal: true

require "fileutils"
require "json"
require "pathname"

module MilkTea
  class DebugMap
    VERSION = 1

    Entry = Data.define(:name, :linkage_name, :line) do
      def to_h
        payload = {
          "name" => name,
          "cName" => linkage_name,
        }
        payload["line"] = line if line
        payload
      end
    end

    Function = Data.define(:name, :linkage_name, :source_path, :line, :params, :locals) do
      def to_h(base_dir: nil)
        payload = {
          "name" => name,
          "cName" => linkage_name,
          "params" => params.map(&:to_h),
          "locals" => locals.map(&:to_h),
        }
        serialized_source_path = DebugMap.path_for_payload(source_path, base_dir)
        payload["sourcePath"] = serialized_source_path if serialized_source_path
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
        memo[function.linkage_name] ||= function
      end
    end

    def self.sidecar_path_for(binary_path)
      "#{File.expand_path(binary_path)}.mtdbg.json"
    end

    def self.load(path)
      resolved_path = File.expand_path(path)
      base_dir = File.dirname(resolved_path)
      payload = JSON.parse(File.read(resolved_path))
      functions = Array(payload["functions"]).map do |function|
        Function.new(
          name: function.fetch("name"),
          linkage_name: function.fetch("cName"),
          source_path: path_from_payload(function["sourcePath"], base_dir),
          line: function["line"],
          params: load_entries(function["params"]),
          locals: load_entries(function["locals"])
        )
      end

      new(
        binary_path: path_from_payload(payload["binaryPath"], base_dir),
        program_source_path: path_from_payload(payload["programSourcePath"], base_dir),
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
          linkage_name: function.linkage_name.to_s,
          source_path: source_path ? File.expand_path(source_path) : nil,
          line: first_statement_line(function.body),
          params: function.params.map { |param| Entry.new(name: param.name.to_s, linkage_name: param.linkage_name.to_s, line: nil) },
          locals: collect_locals(function.body)
        )
      end

      new(binary_path:, program_source_path: ir_program.source_path, functions:)
    end

    def write(path)
      resolved_path = File.expand_path(path)
      base_dir = File.dirname(resolved_path)
      FileUtils.mkdir_p(base_dir)
      File.write(resolved_path, JSON.pretty_generate(to_h(base_dir:)) + "\n")
    end

    def function_for_c_name(c_name)
      @functions_by_c_name[c_name.to_s]
    end

    def variable_for(function_c_name, c_name)
      function = function_for_c_name(function_c_name)
      return nil unless function

      function.params.find { |entry| entry.linkage_name == c_name.to_s } ||
        function.locals.find { |entry| entry.linkage_name == c_name.to_s }
    end

    def source_variable_for(function_c_name, source_name)
      function = function_for_c_name(function_c_name)
      return nil unless function

      matches = (function.params + function.locals).select { |entry| entry.name == source_name.to_s }
      return nil if matches.empty?

      return matches.first if matches.map(&:linkage_name).uniq.one?

      nil
    end

    def to_h(base_dir: nil)
      payload = {
        "version" => VERSION,
        "functions" => functions.map { |function| function.to_h(base_dir:) },
      }
      serialized_binary_path = self.class.path_for_payload(binary_path, base_dir)
      payload["binaryPath"] = serialized_binary_path if serialized_binary_path
      serialized_program_source_path = self.class.path_for_payload(program_source_path, base_dir)
      payload["programSourcePath"] = serialized_program_source_path if serialized_program_source_path
      payload
    end

    def self.path_for_payload(path, base_dir)
      return nil unless path
      return path.tr("\\", "/") unless base_dir

      expanded_path = File.expand_path(path)
      begin
        Pathname.new(expanded_path).relative_path_from(Pathname.new(base_dir)).to_s.tr("\\", "/")
      rescue ArgumentError
        expanded_path.tr("\\", "/")
      end
    end

    def self.path_from_payload(path, base_dir)
      return nil unless path
      return path if path.empty?
      return path if absolute_path_string?(path)
      return path unless base_dir

      File.expand_path(path, base_dir)
    end

    def self.absolute_path_string?(path)
      path.start_with?("/") || path.start_with?("\\\\") || path.match?(/\A[A-Za-z]:[\\\/]/)
    end

    class << self
      private

      def load_entries(entries)
        Array(entries).map do |entry|
          Entry.new(name: entry.fetch("name"), linkage_name: entry.fetch("cName"), line: entry["line"])
        end
      end

      def collect_locals(statements, locals = [])
        Array(statements).each do |statement|
          case statement
          when IR::LocalDecl
            locals << Entry.new(name: statement.name.to_s, linkage_name: statement.linkage_name.to_s, line: statement.line)
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
