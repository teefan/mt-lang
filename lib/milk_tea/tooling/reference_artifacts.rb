# frozen_string_literal: true

module MilkTea
  class ReferenceArtifacts
    VERSION = 1

    def initialize(root_path:, entry_path:, module_roots:, package_graph:, platform:, base_dir: Dir.pwd)
      @root_path = File.expand_path(root_path)
      @entry_path = File.expand_path(entry_path)
      @module_roots = module_roots
      @package_graph = package_graph
      @platform = ModuleLoader.normalize_platform_name(platform)
      @base_dir = base_dir
      @loader = ModuleLoader.new(module_roots: @module_roots, package_graph: @package_graph, platform: @platform)
    end

    def token_plan
      modules = module_entries.map.with_index(1) do |(path, analysis), source_id|
        source = File.read(path)
        tokens = Lexer.lex(source, path: path)
        line_starts = build_line_starts(source)

        {
          "sourceId" => source_id,
          "packageName" => package_name_for(path),
          "moduleName" => analysis.module_name,
          "path" => contract_path(path),
          "targetPlatform" => @platform.to_s,
          "tokenCount" => tokens.length,
          "tokens" => tokens.each_with_index.map do |token, token_index|
            finish_line, finish_column = position_for_offset(line_starts, token.end_offset)
            {
              "id" => token_index + 1,
              "kind" => token_kind_name(token),
              "lexeme" => token.lexeme,
              "line" => token.line,
              "column" => token.column,
              "finishLine" => finish_line,
              "finishColumn" => finish_column,
            }
          end,
        }
      end

      {
        "schema" => "token-set.v1",
        "version" => VERSION,
        "kind" => "token-set",
        "rootPath" => contract_path(@root_path),
        "targetPlatform" => @platform.to_s,
        "moduleCount" => modules.length,
        "modules" => modules,
      }
    end

    def parsed_plan
      modules = module_entries.map.with_index(1) do |(path, analysis), source_id|
        renderer = Renderer.new(module_kind: analysis.module_kind)
        ast = analysis.ast
        {
          "sourceId" => source_id,
          "packageName" => package_name_for(path),
          "moduleName" => analysis.module_name,
          "path" => contract_path(path),
          "moduleKind" => analysis.module_kind.to_s,
          "targetPlatform" => @platform.to_s,
          "imports" => ast.imports.map { |import| import_payload(import) },
          "types" => ast.declarations.grep(AST::TypeAliasDecl).map { |decl| type_alias_payload(decl, renderer, analysis.module_kind) },
          "consts" => ast.declarations.grep(AST::ConstDecl).map { |decl| const_payload(decl, renderer, analysis.module_kind) },
          "interfaces" => ast.declarations.grep(AST::InterfaceDecl).map { |decl| interface_payload(decl, renderer, analysis.module_kind) },
          "structs" => ast.declarations.grep(AST::StructDecl).map { |decl| struct_payload(decl, renderer, analysis.module_kind) },
          "enums" => enum_declarations(ast).map { |decl| enum_payload(decl, renderer, analysis.module_kind) },
          "variants" => ast.declarations.grep(AST::VariantDecl).map { |decl| variant_payload(decl, renderer, analysis.module_kind) },
          "functions" => top_level_function_declarations(ast).map { |decl| function_payload(decl, renderer, method_kind: "free", module_kind: analysis.module_kind) },
          "extensions" => ast.declarations.grep(AST::ExtendingBlock).map { |decl| extension_payload(decl, renderer, analysis.module_kind) },
          "otherDeclarations" => other_declarations(ast).map { |decl| raw_decl_payload(decl, renderer) },
        }
      end

      {
        "schema" => "parsed-module.v1",
        "version" => VERSION,
        "kind" => "parsed-module",
        "rootPath" => contract_path(@root_path),
        "targetPlatform" => @platform.to_s,
        "moduleCount" => modules.length,
        "modules" => modules,
      }
    end

    private

    def module_entries
      return @module_entries if defined?(@module_entries)

      program = @loader.check_program(@entry_path)
      @module_entries = program.analyses_by_path.sort_by { |path, _analysis| contract_path(path) }
    end

    def build_line_starts(source)
      starts = [0]
      source.to_s.b.each_byte.with_index do |byte, index|
        starts << (index + 1) if byte == 10
      end
      starts
    end

    def position_for_offset(line_starts, offset)
      index = line_starts.bsearch_index { |value| value > offset }
      line_index = index ? index - 1 : (line_starts.length - 1)
      line_start = line_starts.fetch(line_index)
      [line_index + 1, offset - line_start + 1]
    end

    def token_kind_name(token)
      case token.type
      when :identifier
        "identifier"
      when :integer
        "integer"
      when :float
        "float"
      when :string, :cstring
        "string"
      when :fstring
        "format-string"
      when :newline
        "newline"
      when :indent
        "indent"
      when :dedent
        "dedent"
      when :eof
        "eof"
      else
        Token::KEYWORDS.value?(token.type) ? "keyword" : "operator"
      end
    end

    def package_name_for(path)
      expanded_path = File.expand_path(path)
      if @package_graph&.respond_to?(:package_for_path)
        package = @package_graph.package_for_path(expanded_path)
        return package.manifest.package_name if package
      end

      std_root = File.expand_path(MilkTea.root.join("std").to_s)
      return "std" if expanded_path == std_root || expanded_path.start_with?(std_root + File::SEPARATOR)

      manifest = PackageManifest.load(expanded_path)
      manifest.package_name
    rescue PackageManifestError
      PackageManifest.default_package_name_for_root(File.dirname(expanded_path))
    end

    def contract_path(path)
      expanded_path = File.expand_path(path)
      expanded_base_dir = File.expand_path(@base_dir)
      within_base_dir = expanded_path == expanded_base_dir || expanded_path.start_with?(expanded_base_dir + File::SEPARATOR)
      return expanded_path.tr("\\", "/") unless within_base_dir

      Pathname.new(expanded_path).relative_path_from(Pathname.new(expanded_base_dir)).to_s.tr("\\", "/")
    rescue ArgumentError
      expanded_path.tr("\\", "/")
    end

    def import_payload(import)
      {
        "modulePath" => import.path.to_s,
        "aliasName" => (import.alias_name || import.path.to_s.split(".").last),
        "line" => import.line || 0,
        "column" => import.column || 1,
      }
    end

    def type_alias_payload(decl, renderer, module_kind)
      {
        "visibility" => visibility_name(decl.visibility, module_kind),
        "name" => decl.name,
        "target" => renderer.render_type(decl.target),
        "line" => decl.line || 0,
        "column" => 1,
      }
    end

    def const_payload(decl, renderer, module_kind)
      {
        "visibility" => visibility_name(decl.visibility, module_kind),
        "name" => decl.name,
        "type" => renderer.render_type(decl.type),
        "value" => renderer.render_expression(decl.value),
        "line" => decl.line || 0,
        "column" => 1,
      }
    end

    def interface_payload(decl, renderer, module_kind)
      {
        "visibility" => visibility_name(decl.visibility, module_kind),
        "name" => decl.name,
        "methods" => decl.methods.map { |method| interface_method_payload(method, renderer, decl.visibility, module_kind) },
        "line" => decl.line || 0,
        "column" => 1,
      }
    end

    def struct_payload(decl, renderer, module_kind)
      {
        "visibility" => visibility_name(decl.visibility, module_kind),
        "name" => decl.name,
        "typeParams" => renderer.render_type_params(decl.type_params),
        "implements" => decl.implements.map(&:to_s),
        "fields" => decl.fields.map { |field| named_type_payload(field.name, renderer.render_type(field.type)) },
        "line" => decl.line || 0,
        "column" => 1,
      }
    end

    def enum_declarations(ast)
      ast.declarations.select { |decl| decl.is_a?(AST::EnumDecl) || decl.is_a?(AST::FlagsDecl) }
    end

    def enum_payload(decl, renderer, module_kind)
      {
        "visibility" => visibility_name(decl.visibility, module_kind),
        "kind" => decl.is_a?(AST::FlagsDecl) ? "flags" : "enum",
        "name" => decl.name,
        "backingType" => decl.backing_type ? renderer.render_type(decl.backing_type) : "",
        "members" => decl.members.map do |member|
          {
            "name" => member.name,
            "value" => member.value ? renderer.render_expression(member.value) : "",
          }
        end,
        "line" => decl.line || 0,
        "column" => 1,
      }
    end

    def variant_payload(decl, renderer, module_kind)
      {
        "visibility" => visibility_name(decl.visibility, module_kind),
        "name" => decl.name,
        "typeParams" => renderer.render_type_params(decl.type_params),
        "arms" => decl.arms.map do |arm|
          {
            "name" => arm.name,
            "fields" => arm.fields.map { |field| named_type_payload(field.name, renderer.render_type(field.type)) },
          }
        end,
        "line" => decl.line || 0,
        "column" => 1,
      }
    end

    def extension_payload(decl, renderer, module_kind)
      {
        "targetType" => renderer.render_type(decl.type_name),
        "methods" => decl.methods.map { |method| function_payload(method, renderer, method_kind: method_kind_name(method), module_kind:) },
        "line" => decl.line || 0,
        "column" => 1,
      }
    end

    def raw_decl_payload(decl, renderer)
      {
        "kind" => raw_decl_kind(decl),
        "text" => renderer.render_declaration(decl),
        "line" => decl.respond_to?(:line) ? (decl.line || 0) : 0,
        "column" => decl.respond_to?(:column) ? (decl.column || 1) : 1,
      }
    end

    def top_level_function_declarations(ast)
      ast.declarations.select do |decl|
        decl.is_a?(AST::FunctionDef) || decl.is_a?(AST::ForeignFunctionDecl) || decl.is_a?(AST::ExternFunctionDecl)
      end
    end

    def other_declarations(ast)
      ast.declarations.reject do |decl|
        decl.is_a?(AST::TypeAliasDecl) ||
          decl.is_a?(AST::ConstDecl) ||
          decl.is_a?(AST::InterfaceDecl) ||
          decl.is_a?(AST::StructDecl) ||
          decl.is_a?(AST::EnumDecl) ||
          decl.is_a?(AST::FlagsDecl) ||
          decl.is_a?(AST::VariantDecl) ||
          decl.is_a?(AST::ExtendingBlock) ||
          decl.is_a?(AST::FunctionDef) ||
          decl.is_a?(AST::ForeignFunctionDecl) ||
          decl.is_a?(AST::ExternFunctionDecl)
      end
    end

    def function_payload(decl, renderer, method_kind:, module_kind:, visibility: nil)
      body = decl.respond_to?(:body) ? Array(decl.body) : []
      {
        "name" => decl.name,
        "visibility" => visibility || visibility_name(decl.respond_to?(:visibility) ? decl.visibility : nil, module_kind),
        "methodKind" => method_kind,
        "async" => decl.respond_to?(:async) ? !!decl.async : false,
        "variadic" => decl.respond_to?(:variadic) ? !!decl.variadic : false,
        "typeParams" => decl.respond_to?(:type_params) ? renderer.render_type_params(decl.type_params) : "",
        "params" => Array(decl.params).map { |param| named_type_payload(param.name, renderer.render_param_type(param)) },
        "returnType" => decl.respond_to?(:return_type) && decl.return_type ? renderer.render_type(decl.return_type) : "",
        "body" => renderer.render_statement_block(body),
        "bodyStatements" => body.map { |statement| renderer.statement_payload(statement) },
        "line" => decl.respond_to?(:line) ? (decl.line || 0) : 0,
        "column" => decl.respond_to?(:column) ? (decl.column || 1) : 1,
      }
    end

    def interface_method_payload(method, renderer, parent_visibility, module_kind)
      {
        "name" => method.name,
        "visibility" => visibility_name(parent_visibility, module_kind),
        "methodKind" => interface_method_kind_name(method),
        "async" => !!method.async,
        "variadic" => false,
        "typeParams" => "",
        "params" => Array(method.params).map { |param| named_type_payload(param.name, renderer.render_param_type(param)) },
        "returnType" => method.return_type ? renderer.render_type(method.return_type) : "",
        "body" => "",
        "bodyStatements" => [],
        "line" => method.line || 0,
        "column" => method.column || 1,
      }
    end

    def named_type_payload(name, type_text)
      {
        "name" => name,
        "type" => type_text,
      }
    end

    def visibility_name(value, module_kind)
      return "public" if module_kind == :raw_module && value.nil?

      value == :public ? "public" : "private"
    end

    def method_kind_name(method)
      return "mutable" if method.respond_to?(:kind) && method.kind == :mutable
      return "static" if method.respond_to?(:kind) && method.kind == :static

      method.is_a?(AST::MethodDef) ? "instance" : "free"
    end

    def interface_method_kind_name(method)
      method.kind == :mutable ? "mutable" : "instance"
    end

    def raw_decl_kind(decl)
      decl.class.name.split("::").last.gsub(/Decl\z/, "").gsub(/Block\z/, "").gsub(/([a-z])([A-Z])/, '\1-\2').downcase
    end

    class Renderer
      INDENT = "    "

      def initialize(module_kind:)
        @module_kind = module_kind
      end

      def render_type(type)
        with_formatter { |formatter| formatter.send(:render_type, type) }
      rescue StandardError
        type.to_s
      end

      def render_type_params(type_params)
        with_formatter { |formatter| formatter.send(:render_type_params, type_params) }
      rescue StandardError
        ""
      end

      def render_expression(expression)
        with_formatter { |formatter| formatter.send(:render_expression, expression) }
      rescue StandardError
        expression.class.name.split("::").last
      end

      def render_param_type(param)
        if param.is_a?(AST::ForeignParam)
          text = +""
          text << "#{param.mode} " unless param.mode == :plain
          text << render_type(param.type)
          text << " as #{render_type(param.boundary_type)}" if param.boundary_type
          return text
        end

        param.type ? render_type(param.type) : ""
      end

      def render_declaration(declaration)
        with_formatter do |formatter|
          formatter.send(:emit_declaration, declaration)
          formatter.send(:finish).strip
        end
      rescue StandardError
        declaration.class.name.split("::").last
      end

      def render_statement_block(statements)
        return "" if statements.empty?

        statement_lines(statements).join("\n") + "\n"
      end

      def statement_payload(statement)
        case statement
        when AST::LocalDecl
          {
            "kind" => statement.kind.to_s,
            "text" => local_decl_text(statement),
            "aux" => (statement.else_binding&.name || ""),
            "body" => [],
            "elseBody" => Array(statement.else_body).map { |nested| statement_payload(nested) },
            "matchArms" => [],
            "line" => statement.line || 0,
            "column" => statement.column || 1,
          }
        when AST::Assignment
          expression_statement_payload(statement, "#{render_expression(statement.target)} #{statement.operator} #{render_expression(statement.value)}")
        when AST::IfStmt
          if_payload(statement)
        when AST::MatchStmt
          {
            "kind" => "match",
            "text" => render_expression(statement.expression),
            "aux" => "",
            "body" => [],
            "elseBody" => [],
            "matchArms" => Array(statement.arms).map { |arm| match_arm_payload(arm) },
            "line" => statement.line || 0,
            "column" => statement.column || 1,
          }
        when AST::UnsafeStmt
          {
            "kind" => "unsafe",
            "text" => "",
            "aux" => "",
            "body" => Array(statement.body).map { |nested| statement_payload(nested) },
            "elseBody" => [],
            "matchArms" => [],
            "line" => statement.line || 0,
            "column" => statement.column || 1,
          }
        when AST::StaticAssert
          {
            "kind" => "static-assert",
            "text" => "#{render_expression(statement.condition)}, #{render_expression(statement.message)}",
            "aux" => "",
            "body" => [],
            "elseBody" => [],
            "matchArms" => [],
            "line" => statement.line || 0,
            "column" => 1,
          }
        when AST::ForStmt
          {
            "kind" => "for",
            "text" => for_header(statement),
            "aux" => "",
            "body" => Array(statement.body).map { |nested| statement_payload(nested) },
            "elseBody" => [],
            "matchArms" => [],
            "line" => statement.line || 0,
            "column" => statement.column || 1,
          }
        when AST::WhileStmt
          {
            "kind" => "while",
            "text" => render_expression(statement.condition),
            "aux" => "",
            "body" => Array(statement.body).map { |nested| statement_payload(nested) },
            "elseBody" => [],
            "matchArms" => [],
            "line" => statement.line || 0,
            "column" => statement.column || 1,
          }
        when AST::PassStmt
          simple_payload("pass", statement)
        when AST::BreakStmt
          simple_payload("break", statement)
        when AST::ContinueStmt
          simple_payload("continue", statement)
        when AST::ReturnStmt
          {
            "kind" => "return",
            "text" => statement.value ? render_expression(statement.value) : "",
            "aux" => "",
            "body" => [],
            "elseBody" => [],
            "matchArms" => [],
            "line" => statement.line || 0,
            "column" => statement.column || 1,
          }
        when AST::DeferStmt
          {
            "kind" => "defer",
            "text" => statement.expression ? render_expression(statement.expression) : "",
            "aux" => "",
            "body" => Array(statement.body).map { |nested| statement_payload(nested) },
            "elseBody" => [],
            "matchArms" => [],
            "line" => statement.line || 0,
            "column" => statement.column || 1,
          }
        when AST::ExpressionStmt
          expression_statement_payload(statement, render_expression(statement.expression))
        else
          {
            "kind" => "unknown",
            "text" => statement.class.name.split("::").last,
            "aux" => "",
            "body" => [],
            "elseBody" => [],
            "matchArms" => [],
            "line" => statement.respond_to?(:line) ? (statement.line || 0) : 0,
            "column" => statement.respond_to?(:column) ? (statement.column || 1) : 1,
          }
        end
      end

      private

      def with_formatter
        formatter = PrettyPrinter::ASTFormatter.new
        formatter.instance_variable_set(:@current_module_kind, @module_kind)
        formatter.instance_variable_set(:@comment_map, {})
        formatter.instance_variable_set(:@blank_line_set, {})
        formatter.instance_variable_set(:@trailing_comment_map, {})
        yield(formatter)
      end

      def statement_lines(statements, indent = 0)
        Array(statements).flat_map { |statement| statement_lines_for(statement, indent) }
      end

      def statement_lines_for(statement, indent)
        prefix = INDENT * indent

        case statement
        when AST::LocalDecl
          header = prefix + "#{statement.kind} #{local_decl_text(statement)}"
          if statement.else_body
            header += statement.else_binding ? " else as #{statement.else_binding.name}:" : " else:"
            [header] + statement_lines(statement.else_body, indent + 1)
          else
            [header]
          end
        when AST::Assignment
          [prefix + "#{render_expression(statement.target)} #{statement.operator} #{render_expression(statement.value)}"]
        when AST::IfStmt
          if_lines(statement, indent)
        when AST::MatchStmt
          lines = [prefix + "match #{render_expression(statement.expression)}:"]
          Array(statement.arms).each do |arm|
            header = prefix + INDENT + render_expression(arm.pattern)
            header += " as #{arm.binding_name}" if arm.binding_name
            header += ":"
            lines << header
            lines.concat(statement_lines(arm.body, indent + 2))
          end
          lines
        when AST::UnsafeStmt
          [prefix + "unsafe:"] + statement_lines(statement.body, indent + 1)
        when AST::StaticAssert
          [prefix + "static_assert(#{render_expression(statement.condition)}, #{render_expression(statement.message)})"]
        when AST::ForStmt
          [prefix + "for #{for_header(statement)}:"] + statement_lines(statement.body, indent + 1)
        when AST::WhileStmt
          [prefix + "while #{render_expression(statement.condition)}:"] + statement_lines(statement.body, indent + 1)
        when AST::PassStmt
          [prefix + "pass"]
        when AST::BreakStmt
          [prefix + "break"]
        when AST::ContinueStmt
          [prefix + "continue"]
        when AST::ReturnStmt
          [prefix + (statement.value ? "return #{render_expression(statement.value)}" : "return")]
        when AST::DeferStmt
          if statement.body
            [prefix + "defer:"] + statement_lines(statement.body, indent + 1)
          else
            [prefix + "defer #{render_expression(statement.expression)}"]
          end
        when AST::ExpressionStmt
          [prefix + render_expression(statement.expression)]
        else
          [prefix + statement.class.name.split("::").last]
        end
      end

      def local_decl_text(statement)
        text = +local_decl_name_text(statement)
        text << ": #{render_type(statement.type)}" if statement.type
        text << " = #{render_expression(statement.value)}" if statement.value
        text
      end

      def local_decl_name_text(statement)
        raw_name = statement.name.to_s
        match = /\A[_A-Za-z][_A-Za-z0-9]*/.match(raw_name)
        match ? match[0] : raw_name
      end

      def for_header(statement)
        bindings = Array(statement.bindings).map(&:name).join(", ")
        iterables = Array(statement.iterables).map { |iterable| render_expression(iterable) }.join(", ")
        "#{bindings} in #{iterables}"
      end

      def simple_payload(kind, statement)
        {
          "kind" => kind,
          "text" => "",
          "aux" => "",
          "body" => [],
          "elseBody" => [],
          "matchArms" => [],
          "line" => statement.respond_to?(:line) ? (statement.line || 0) : 0,
          "column" => statement.respond_to?(:column) ? (statement.column || 1) : 1,
        }
      end

      def expression_statement_payload(statement, text)
        {
          "kind" => "expression",
          "text" => text,
          "aux" => "",
          "body" => [],
          "elseBody" => [],
          "matchArms" => [],
          "line" => statement.respond_to?(:line) ? (statement.line || 0) : 0,
          "column" => statement.respond_to?(:column) ? (statement.column || 1) : 1,
        }
      end

      def if_payload(statement)
        first_branch, *rest = Array(statement.branches)
        else_body = if rest.empty?
                      Array(statement.else_body).map { |nested| statement_payload(nested) }
                    else
                      [if_payload(AST::IfStmt.new(branches: rest, else_body: statement.else_body, line: rest.first.line, else_line: statement.else_line, else_column: statement.else_column))]
                    end

        {
          "kind" => "if",
          "text" => render_expression(first_branch.condition),
          "aux" => "",
          "body" => Array(first_branch.body).map { |nested| statement_payload(nested) },
          "elseBody" => else_body,
          "matchArms" => [],
          "line" => statement.line || first_branch.line || 0,
          "column" => first_branch.column || 1,
        }
      end

      def match_arm_payload(arm)
        pattern = render_expression(arm.pattern)
        pattern += " as #{arm.binding_name}" if arm.binding_name
        {
          "pattern" => pattern,
          "body" => Array(arm.body).map { |nested| statement_payload(nested) },
          "line" => arm.binding_line || 0,
          "column" => arm.binding_column || 1,
        }
      end

      def if_lines(statement, indent)
        lines = []
        Array(statement.branches).each_with_index do |branch, index|
          keyword = index.zero? ? "if" : "else if"
          lines << ((INDENT * indent) + "#{keyword} #{render_expression(branch.condition)}:")
          lines.concat(statement_lines(branch.body, indent + 1))
        end

        else_body = Array(statement.else_body)
        unless else_body.empty?
          lines << ((INDENT * indent) + "else:")
          lines.concat(statement_lines(else_body, indent + 1))
        end

        lines
      end
    end
  end
end
