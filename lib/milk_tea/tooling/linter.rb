# frozen_string_literal: true

require "set"

module MilkTea
  class Linter
    # severity: :error | :warning | :hint
    Warning = Data.define(:path, :line, :column, :length, :code, :message, :severity, :symbol_name) do
      def initialize(path:, line:, column: nil, length: nil, code:, message:, severity: :warning, symbol_name: nil) = super
    end
    # binding_kind: :local | :param
    # allow_prefer_let: true only for `var` locals — flag prefer-let if never mutated
    # mutated: true if ever the target of a plain `=` or compound assignment
    # last_write_line: line of most recent plain-write (decl with value, or plain `=`)
    # last_write_depth: branch nesting depth at the time of last_write_line
    # reads_after_write: how many times binding was read since last write
    # pending_dead_assignments: Array<Warning> — intermediate dead writes, emitted at scope exit only if used==true
    Binding = Struct.new(
      :name, :line, :column, :used, :binding_kind, :allow_prefer_let, :mutated,
      :last_write_line, :last_write_column, :last_write_depth, :reads_after_write, :pending_dead_assignments,
      keyword_init: true
    )

    def self.lint_source(source, path: nil, select: nil, ignore: nil)
      ast = Parser.parse(source, path:)
      trivia = Lexer.lex_with_trivia(source, path:).trivia
      suppressions = parse_suppressions(trivia)
      warnings = new(path:).lint(ast)
      warnings = apply_suppressions(warnings, suppressions)

      # Layer in config-file defaults before per-call overrides
      if (cfg = load_config(path))
        select ||= cfg[:select]
        ignore ||= cfg[:ignore]
      end

      warnings = filter_by_rules(warnings, select:, ignore:)
      warnings
    end

    # Load the nearest .mt-lint.yml walking up from the source file's directory.
    # Returns Hash { select: Set|nil, ignore: Set|nil } or nil if no config found.
    def self.load_config(path)
      return nil unless path

      dir = File.directory?(path) ? path : File.dirname(path)
      # Walk up until we either find a config or leave the project
      100.times do
        candidate = File.join(dir, ".mt-lint.yml")
        if File.exist?(candidate)
          return parse_config_file(candidate)
        end
        parent = File.dirname(dir)
        break if parent == dir  # filesystem root

        dir = parent
      end
      nil
    rescue StandardError
      nil
    end

    def self.parse_config_file(path)
      require "yaml"
      raw = YAML.safe_load_file(path, symbolize_names: true) || {}
      result = {}
      if (s = raw[:select])
        result[:select] = Array(s).map(&:to_s).to_set
      end
      if (i = raw[:ignore])
        result[:ignore] = Array(i).map(&:to_s).to_set
      end
      result
    rescue StandardError
      {}
    end

    # Apply auto-fixable rules to source text.
    # Handles: prefer-let, redundant-else.
    # Returns the fixed source (may be identical if nothing was fixable).
    def self.fix_source(source, path: nil)
      warnings = lint_source(source, path:)
      lines = source.lines

      # prefer-let: simple var→let substitution on the declaration line
      prefer_let_fixes = warnings.select { |w| w.code == "prefer-let" && w.line }
      prefer_let_fixes.sort_by(&:line).each do |w|
        idx = w.line - 1
        next unless lines[idx]

        lines[idx] = lines[idx].sub(/\bvar\b/, "let")
      end

      # redundant-else: for each warning, find the `else:` line above, delete it,
      # and dedent the else body by one indent level.
      # Process in reverse line order to keep indices stable.
      redundant_else_fixes = warnings.select { |w| w.code == "redundant-else" && w.line }
      redundant_else_fixes.sort_by(&:line).reverse_each do |w|
        else_idx = w.line - 1   # 0-based index of the `else:` line
        next unless lines[else_idx]&.match?(/\A\s*else:\s*\z/)

        else_indent  = lines[else_idx].match(/\A(\s*)/)[1]
        body_indent  = else_indent + "    "   # one additional 4-space indent level
        first_body_idx = else_idx + 1

        # Find extent of the else body: all consecutive lines that are blank or indented >= body_indent
        body_end_idx = first_body_idx - 1
        (first_body_idx...lines.length).each do |i|
          l = lines[i]
          if l.chomp.empty? || l.start_with?(body_indent)
            body_end_idx = i
          else
            break
          end
        end

        # Dedent the body lines by 4 spaces
        (first_body_idx..body_end_idx).each do |i|
          lines[i] = lines[i].sub(/\A    /, "") if lines[i]
        end

        # Delete the `else:` line
        lines.delete_at(else_idx)
      end

      # unused-import: delete the import line entirely.
      # Process in reverse order to keep indices stable after deletions.
      import_fixes = warnings.select { |w| w.code == "unused-import" && w.line }
      import_fixes.sort_by(&:line).reverse_each do |w|
        idx = w.line - 1
        lines.delete_at(idx) if lines[idx]&.match?(/\A\s*import\b/)
      end

      # dead-assignment: delete the dead reassignment statement.
      # Only applies to plain assignments (not declarations), since
      # mark_write is only called for Assignment nodes.
      dead_fixes = warnings.select { |w| w.code == "dead-assignment" && w.line }
      dead_fixes.sort_by(&:line).reverse_each do |w|
        idx = w.line - 1
        next unless lines[idx]
        # Only delete if it looks like a plain assignment (not let/var declaration)
        next if lines[idx].match?(/\A\s*(let|var)\b/)

        lines.delete_at(idx)
      end

      lines.join
    end

    # Parse `# lint: ignore` / `# lint: ignore(rule1, rule2)` comments.
    # Returns Hash { line_number => Set<code> | :all }
    def self.parse_suppressions(trivia)
      result = {}
      trivia.select { |t| t.kind == :comment }.each do |t|
        text = t.text.strip
        if (m = text.match(/\A#\s*lint:\s*ignore\(([^)]+)\)\z/))
          codes = m[1].split(",").map(&:strip).to_set
          result[t.line] = codes
        elsif text.match(/\A#\s*lint:\s*ignore\z/)
          result[t.line] = :all
        end
      end
      result
    end

    def self.apply_suppressions(warnings, suppressions)
      return warnings if suppressions.empty?

      warnings.reject do |w|
        next false unless w.line
        # Suppression on same line (trailing) or preceding line (leading comment)
        [w.line, w.line - 1].any? do |check_line|
          entry = suppressions[check_line]
          entry == :all || (entry.is_a?(Set) && entry.include?(w.code))
        end
      end
    end

    def self.filter_by_rules(warnings, select:, ignore:)
      warnings = warnings.select { |w| select.include?(w.code) } if select
      warnings = warnings.reject { |w| ignore.include?(w.code) } if ignore
      warnings
    end

    def initialize(path: nil)
      @path = path
      @warnings = []
      @scopes = []
      @loop_condition_reads_stack = []
      @branch_depth = 0
    end

    def lint(ast)
      visit_source_file(ast)
      @warnings
    end

    private

    def visit_source_file(source_file)
      check_unused_imports(source_file)
      source_file.declarations.each do |declaration|
        case declaration
        when AST::FunctionDef, AST::MethodDef
          visit_function(declaration)
        when AST::MethodsBlock
          declaration.methods.each { |m| visit_function(m) }
        end
      end
    end

    # ── unused-import ────────────────────────────────────────────────────

    def check_unused_imports(source_file)
      return if source_file.imports.empty?

      used = collect_used_names(source_file)
      source_file.imports.each do |import|
        local_name = import.alias_name || import.path.parts.last
        next if ignored_binding_name?(local_name)
        next if used.include?(local_name)

        @warnings << Warning.new(
          path: @path,
          line: import.line,
          column: import.column,
          length: import.length,
          code: "unused-import",
          message: "unused import '#{local_name}'",
          symbol_name: local_name
        )
      end
    end

    # Returns a Set of every "root name" referenced in expressions and type
    # positions across all declarations.  Import usage is determined by checking
    # whether the import's local binding name appears as such a root name.
    def collect_used_names(source_file)
      used = Set.new
      source_file.declarations.each do |decl|
        collect_names_from_declaration(decl, used)
      end
      used
    end

    def collect_names_from_declaration(decl, used)
      case decl
      when AST::FunctionDef, AST::MethodDef
        decl.params.each { |p| collect_names_from_type(p.type, used) if p.respond_to?(:type) && p.type }
        collect_names_from_type(decl.return_type, used) if decl.return_type
        decl.body.each { |stmt| collect_names_from_statement(stmt, used) }
      when AST::MethodsBlock
        decl.methods.each { |m| collect_names_from_declaration(m, used) }
      when AST::StructDecl
        decl.fields.each { |f| collect_names_from_type(f.type, used) }
      when AST::UnionDecl
        decl.fields.each { |f| collect_names_from_type(f.type, used) }
      when AST::TypeAliasDecl
        collect_names_from_type(decl.target, used)
      when AST::ConstDecl, AST::VarDecl
        collect_names_from_type(decl.type, used) if decl.type
        collect_names_from_expr(decl.value, used) if decl.value
      when AST::ForeignFunctionDecl
        decl.params.each { |p| collect_names_from_type(p.type, used) if p.respond_to?(:type) && p.type }
        collect_names_from_type(decl.return_type, used) if decl.return_type
      end
    end

    def collect_names_from_statement(stmt, used)
      case stmt
      when AST::LocalDecl
        collect_names_from_type(stmt.type, used) if stmt.type
        collect_names_from_expr(stmt.value, used) if stmt.value
      when AST::Assignment
        collect_names_from_expr(stmt.target, used)
        collect_names_from_expr(stmt.value, used)
      when AST::IfStmt
        stmt.branches.each do |b|
          collect_names_from_expr(b.condition, used)
          b.body.each { |s| collect_names_from_statement(s, used) }
        end
        stmt.else_body&.each { |s| collect_names_from_statement(s, used) }
      when AST::MatchStmt
        collect_names_from_expr(stmt.expression, used)
        stmt.arms.each { |arm| arm.body.each { |s| collect_names_from_statement(s, used) } }
      when AST::ForStmt
        collect_names_from_expr(stmt.iterable, used)
        stmt.body.each { |s| collect_names_from_statement(s, used) }
      when AST::WhileStmt
        collect_names_from_expr(stmt.condition, used)
        stmt.body.each { |s| collect_names_from_statement(s, used) }
      when AST::UnsafeStmt
        stmt.body.each { |s| collect_names_from_statement(s, used) }
      when AST::DeferStmt
        collect_names_from_expr(stmt.expression, used) if stmt.expression
        stmt.body&.each { |s| collect_names_from_statement(s, used) }
      when AST::ReturnStmt
        collect_names_from_expr(stmt.value, used) if stmt.value
      when AST::ExpressionStmt
        collect_names_from_expr(stmt.expression, used)
      when AST::StaticAssert
        collect_names_from_expr(stmt.condition, used)
      end
    end

    def collect_names_from_expr(expr, used)
      case expr
      when nil then nil
      when AST::Identifier then used << expr.name
      when AST::MemberAccess then collect_names_from_expr(expr.receiver, used)
      when AST::IndexAccess
        collect_names_from_expr(expr.receiver, used)
        collect_names_from_expr(expr.index, used)
      when AST::Specialization
        collect_names_from_expr(expr.callee, used)
      when AST::Call
        collect_names_from_expr(expr.callee, used)
        expr.arguments.each { |arg| collect_names_from_expr(arg.value, used) }
      when AST::UnaryOp then collect_names_from_expr(expr.operand, used)
      when AST::BinaryOp
        collect_names_from_expr(expr.left, used)
        collect_names_from_expr(expr.right, used)
      when AST::IfExpr
        collect_names_from_expr(expr.condition, used)
        collect_names_from_expr(expr.then_expression, used)
        collect_names_from_expr(expr.else_expression, used)
      when AST::ProcExpr
        expr.params.each { |p| collect_names_from_type(p.type, used) if p.respond_to?(:type) && p.type }
        expr.body.each { |s| collect_names_from_statement(s, used) }
      when AST::AwaitExpr then collect_names_from_expr(expr.expression, used)
      when AST::FormatString
        expr.parts.each { |p| collect_names_from_expr(p.expression, used) if p.is_a?(AST::FormatExprPart) }
      end
    end

    def collect_names_from_type(type, used)
      case type
      when nil then nil
      when AST::TypeRef
        # Record the root module/alias name (first part of qualified name)
        used << type.name.parts.first if type.name.respond_to?(:parts) && type.name.parts.any?
        type.arguments.each { |arg| collect_names_from_type(arg.value, used) }
      when AST::FunctionType, AST::ProcType
        type.params.each { |p| collect_names_from_type(p.respond_to?(:type) ? p.type : p, used) }
        collect_names_from_type(type.return_type, used) if type.return_type
      end
    end

    def visit_function(function)
      with_scope do
        function.params.each do |param|
          declare_param(
            param.name,
            line: param_line(param, fallback: function.line),
            column: param_column(param)
          )
        end
        visit_statement_list(function.body)
      end
      check_missing_return(function)
    end

    # ── missing-return ───────────────────────────────────────────────────

    def check_missing_return(function)
      return unless function.return_type           # implicit void — no check
      return if void_return_type?(function.return_type)
      return if always_returns?(function.body)

      @warnings << Warning.new(
        path: @path,
        line: function.line,
        column: function.respond_to?(:column) ? function.column : nil,
        length: function.name.length,
        code: "missing-return",
        message: "function '#{function.name}' does not always return a value",
        severity: :error,
        symbol_name: function.name
      )
    end

    def void_return_type?(return_type)
      case return_type
      when AST::TypeRef
        name = return_type.name
        name.is_a?(AST::QualifiedName) && name.parts == ["void"]
      when Types::Primitive
        return_type.name == "void"
      else
        false
      end
    end

    # Returns true if every execution path through `stmts` ends with a
    # guaranteed return.  Conservative: only IfStmt with else + MatchStmt
    # with arms are considered exhaustive.
    def always_returns?(stmts)
      stmts.any? do |stmt|
        case stmt
        when AST::ReturnStmt
          true
        when AST::IfStmt
          # Only exhaustive if there is an else branch AND every branch returns
          stmt.else_body && !stmt.else_body.empty? &&
            stmt.branches.all? { |b| always_returns?(b.body) } &&
            always_returns?(stmt.else_body)
        when AST::MatchStmt
          stmt.arms.any? && stmt.arms.all? { |arm| always_returns?(arm.body) }
        when AST::UnsafeStmt
          always_returns?(stmt.body)
        else
          false
        end
      end
    end

    # ── redundant-else ───────────────────────────────────────────────────
    # Fire when every explicit if/elif branch always returns, making the else
    # block an unnecessary level of indentation.
    def check_redundant_else(stmt)
      return unless stmt.else_body && !stmt.else_body.empty?
      return unless stmt.branches.all? { |b| always_returns?(b.body) }

      # Use the line of the first else-body statement as the diagnostic anchor.
      else_line = stmt.else_body.first.respond_to?(:line) ? stmt.else_body.first.line : stmt.line
      @warnings << Warning.new(
        path: @path,
        line: stmt.else_line || else_line,
        column: stmt.else_column,
        length: 4,
        code: "redundant-else",
        message: "else block is redundant because all preceding branches return"
      )
    end

    # ── useless-expression ───────────────────────────────────────────────────

    PURE_EXPRESSION_TYPES = [
      AST::IntegerLiteral, AST::FloatLiteral, AST::StringLiteral, AST::FormatString,
      AST::BooleanLiteral, AST::NullLiteral,
      AST::BinaryOp, AST::UnaryOp,
      AST::Identifier,
    ].freeze

    def check_useless_expression(stmt)
      expr = stmt.expression
      return unless PURE_EXPRESSION_TYPES.any? { |t| expr.is_a?(t) }

      line = stmt.respond_to?(:line) ? stmt.line : nil
      @warnings << Warning.new(
        path: @path,
        line:,
        code: "useless-expression",
        message: "expression result is unused and has no side effects",
        severity: :warning
      )
    end

    # Visits a list of statements in sequence, emitting unreachable-code for any
    # statement that follows a guaranteed terminator (return/break/continue).
    def visit_statement_list(stmts)
      terminated = false
      stmts.each do |stmt|
        if terminated
          line = stmt.respond_to?(:line) ? stmt.line : nil
          @warnings << Warning.new(path: @path, line:, code: "unreachable-code", message: "unreachable code")
          next
        end
        visit_statement(stmt)
        terminated = true if terminator?(stmt)
      end
    end

    def terminator?(stmt)
      stmt.is_a?(AST::ReturnStmt) || stmt.is_a?(AST::BreakStmt) || stmt.is_a?(AST::ContinueStmt)
    end

    def visit_statement(statement)
      case statement
      when AST::LocalDecl
        visit_expression(statement.value) if statement.value
        declare_local(
          statement.name,
          statement.line,
          column: statement.column,
          var: statement.kind == :var,
          has_value: !statement.value.nil?
        )
      when AST::Assignment
        visit_expression(statement.value)          # visit RHS first — reads in RHS count against dead-assignment
        mark_assignment_target_reads(statement.target, statement.operator) # compound: marks target as read
        visit_assignment_target(statement.target)  # non-identifier sub-expressions in target
        if statement.target.is_a?(AST::Identifier)
          mark_write(statement.target.name, statement.line, column: statement.target.column)
        end
        mark_mutated(statement.target)
      when AST::IfStmt
        statement.branches.each do |branch|
          visit_expression(branch.condition)
          with_scope { in_branch { visit_statement_list(branch.body) } }
        end
        with_scope { in_branch { visit_statement_list(statement.else_body) } } if statement.else_body
        check_redundant_else(statement)
      when AST::MatchStmt
        visit_expression(statement.expression)
        statement.arms.each do |arm|
          with_scope do
            binding_line = arm.binding_line || statement.line
            binding_column = arm.binding_column
            declare_local(arm.binding_name, binding_line, column: binding_column, var: false) if arm.binding_name
            in_branch { visit_statement_list(arm.body) }
          end
        end
      when AST::UnsafeStmt
        with_scope { visit_statement_list(statement.body) }
      when AST::ForStmt
        visit_expression(statement.iterable)
        with_scope do
          declare_local(statement.name, statement.line, column: statement.column, var: false) if statement.name
          visit_statement_list(statement.body)
        end
      when AST::WhileStmt
        condition_reads = collect_read_identifiers(statement.condition)
        body_reads = collect_reads_from_stmts(statement.body)
        loop_reads = condition_reads | body_reads
        visit_expression(statement.condition)
        with_scope do
          @loop_condition_reads_stack << loop_reads
          visit_statement_list(statement.body)
        ensure
          @loop_condition_reads_stack.pop
        end
      when AST::ReturnStmt
        visit_expression(statement.value) if statement.value
      when AST::DeferStmt
        visit_expression(statement.expression) if statement.expression
        with_scope { visit_statement_list(statement.body) } if statement.body
      when AST::ExpressionStmt
        visit_expression(statement.expression)
        check_useless_expression(statement)
      when AST::StaticAssert
        visit_expression(statement.condition)
      when AST::BreakStmt, AST::ContinueStmt
        nil
      else
        nil
      end
    end

    def visit_expression(expression)
      case expression
      when nil
        nil
      when AST::Identifier
        mark_used(expression.name)
      when AST::MemberAccess
        visit_expression(expression.receiver)
      when AST::IndexAccess
        visit_expression(expression.receiver)
        visit_expression(expression.index)
      when AST::Specialization
        visit_expression(expression.callee)
        expression.arguments.each { |argument| visit_type_argument(argument) }
      when AST::Call
        visit_expression(expression.callee)
        expression.arguments.each { |argument| visit_expression(argument.value) }
      when AST::UnaryOp
        visit_expression(expression.operand)
      when AST::BinaryOp
        visit_expression(expression.left)
        visit_expression(expression.right)
      when AST::IfExpr
        visit_expression(expression.condition)
        visit_expression(expression.then_expression)
        visit_expression(expression.else_expression)
      when AST::ProcExpr
        with_scope do
          fallback_line = expression.respond_to?(:line) ? expression.line : nil
          expression.params.each do |param|
            declare_param(
              param.name,
              line: param_line(param, fallback: fallback_line),
              column: param_column(param)
            )
          end
          visit_statement_list(expression.body)
        end
      when AST::AwaitExpr
        visit_expression(expression.expression)
      when AST::FormatString
        expression.parts.each do |part|
          next unless part.is_a?(AST::FormatExprPart)

          visit_expression(part.expression)
        end
      when AST::IntegerLiteral, AST::FloatLiteral, AST::StringLiteral, AST::BooleanLiteral, AST::NullLiteral,
           AST::SizeofExpr, AST::AlignofExpr, AST::OffsetofExpr
        nil
      else
        nil
      end
    end

    def visit_type_argument(argument)
      visit_expression(argument.value) if argument.respond_to?(:value)
    end

    def visit_assignment_target(target)
      case target
      when AST::Identifier
        nil
      when AST::MemberAccess
        visit_expression(target.receiver)
      when AST::IndexAccess
        visit_expression(target.receiver)
        visit_expression(target.index)
      else
        visit_expression(target)
      end
    end

    def mark_assignment_target_reads(target, operator)
      return if operator == "="

      mark_used(target.name) if target.is_a?(AST::Identifier)
    end

    def mark_mutated(target)
      return unless target.is_a?(AST::Identifier)

      @scopes.reverse_each do |scope|
        binding = scope[target.name]
        next unless binding

        binding.mutated = true
        return
      end
    end

    def with_scope
      @scopes << {}
      yield
    ensure
      emit_scope_warnings(@scopes.pop)
    end

    def in_branch
      @branch_depth += 1
      yield
    ensure
      @branch_depth -= 1
    end

    def declare_local(name, line, column: nil, var: false, has_value: false)
      return if ignored_binding_name?(name)

      # shadow: check whether any outer scope already has a binding for this name
      if @scopes.length > 1
        @scopes[0..-2].each do |outer_scope|
          if outer_scope.key?(name)
            @warnings << Warning.new(
              path: @path, line:, column:, length: name.length, code: "shadow",
              message: "local '#{name}' shadows a binding from an outer scope",
              symbol_name: name
            )
            break
          end
        end
      end

      @scopes.last[name] = Binding.new(
        name:, line:, column:, used: false,
        binding_kind: :local,
        allow_prefer_let: var,
        mutated: false,
        last_write_line: has_value ? line : nil,
        last_write_column: has_value ? column : nil,
        last_write_depth: has_value ? @branch_depth : nil,
        reads_after_write: 0,
        pending_dead_assignments: nil
      )
    end

    def declare_param(name, line: nil, column: nil)
      return if ignored_binding_name?(name)

      @scopes.last[name] = Binding.new(
        name:, line:, column:, used: false,
        binding_kind: :param,
        allow_prefer_let: false,
        mutated: false,
        last_write_line: nil,
        last_write_column: nil,
        last_write_depth: nil,
        reads_after_write: 0,
        pending_dead_assignments: nil
      )
    end

    def param_line(param, fallback: nil)
      line = param.respond_to?(:line) ? param.line : nil
      line || fallback
    end

    def param_column(param)
      param.respond_to?(:column) ? param.column : nil
    end

    def mark_used(name)
      @scopes.reverse_each do |scope|
        binding = scope[name]
        next unless binding

        binding.used = true
        binding.reads_after_write += 1
        return
      end
    end

    # Record a plain write to `name` at `line`.  If the previous write was never
    # read (reads_after_write == 0), save a pending dead-assignment warning that
    # will be emitted at scope exit — but only when binding.used is true (to
    # avoid duplicate noise alongside unused-local).
    def mark_write(name, line, column: nil)
      @scopes.reverse_each do |scope|
        binding = scope[name]
        next unless binding

        if binding.last_write_line && binding.reads_after_write == 0
          # Only flag this overwrite as a dead assignment if the current write is
          # at least as unconditional as the original write. When the overwrite
          # happens inside a conditional branch (deeper branch_depth), the
          # original write may still be consumed on the non-branch path — e.g.
          # `var x = default; if cond: x = other; use(x)` is idiomatic.
          if @branch_depth <= (binding.last_write_depth || 0)
            w = Warning.new(
              path: @path,
              line: binding.last_write_line,
              column: binding.last_write_column,
              length: name.length,
              code: "dead-assignment",
              message: "value assigned to '#{name}' is never read before being overwritten",
              symbol_name: name
            )
            (binding.pending_dead_assignments ||= []) << w
          end
        end
        binding.last_write_line = line
        binding.last_write_column = column
        binding.last_write_depth = @branch_depth
        binding.reads_after_write = 0
        # Loops are analyzed as a single pass, so writes in the body that are
        # read by the next iteration's condition would otherwise be misreported
        # as dead assignments. Treat those as potentially read.
        binding.reads_after_write = 1 if loop_condition_reads_include?(name)
        return
      end
    end

    def loop_condition_reads_include?(name)
      @loop_condition_reads_stack.any? { |set| set.include?(name) }
    end

    def collect_read_identifiers(expression, names = Set.new)
      case expression
      when nil
        nil
      when AST::Identifier
        names << expression.name
      when AST::MemberAccess
        collect_read_identifiers(expression.receiver, names)
      when AST::IndexAccess
        collect_read_identifiers(expression.receiver, names)
        collect_read_identifiers(expression.index, names)
      when AST::Specialization
        collect_read_identifiers(expression.callee, names)
      when AST::Call
        collect_read_identifiers(expression.callee, names)
        expression.arguments.each { |argument| collect_read_identifiers(argument.value, names) }
      when AST::UnaryOp
        collect_read_identifiers(expression.operand, names)
      when AST::BinaryOp
        collect_read_identifiers(expression.left, names)
        collect_read_identifiers(expression.right, names)
      when AST::IfExpr
        collect_read_identifiers(expression.condition, names)
        collect_read_identifiers(expression.then_expression, names)
        collect_read_identifiers(expression.else_expression, names)
      when AST::ProcExpr
        # Proc bodies are analyzed separately by normal lint traversal.
        nil
      when AST::AwaitExpr
        collect_read_identifiers(expression.expression, names)
      when AST::IntegerLiteral, AST::FloatLiteral, AST::StringLiteral,
           AST::FormatString, AST::BooleanLiteral, AST::NullLiteral,
           AST::SizeofExpr, AST::AlignofExpr, AST::OffsetofExpr
        nil
      else
        nil
      end
      names
    end

    def collect_reads_from_stmts(stmts, names = Set.new)
      return names unless stmts
      stmts.each { |s| collect_reads_from_stmt(s, names) }
      names
    end

    def collect_reads_from_stmt(stmt, names)
      case stmt
      when AST::LocalDecl
        collect_read_identifiers(stmt.value, names) if stmt.value
      when AST::Assignment
        collect_read_identifiers(stmt.value, names)
        # For compound assignment or index/member targets, the target itself is also read
        collect_read_identifiers(stmt.target, names) unless stmt.target.is_a?(AST::Identifier)
      when AST::ReturnStmt
        collect_read_identifiers(stmt.value, names) if stmt.value
      when AST::ExpressionStmt
        collect_read_identifiers(stmt.expression, names)
      when AST::IfStmt
        stmt.branches&.each do |b|
          collect_read_identifiers(b.condition, names) if b.respond_to?(:condition)
          collect_reads_from_stmts(b.body, names)
        end
        collect_reads_from_stmts(stmt.else_body, names) if stmt.else_body
      when AST::WhileStmt
        collect_read_identifiers(stmt.condition, names)
        collect_reads_from_stmts(stmt.body, names)
      when AST::ForStmt
        collect_read_identifiers(stmt.iterable, names)
        collect_reads_from_stmts(stmt.body, names)
      when AST::UnsafeStmt, AST::DeferStmt
        collect_reads_from_stmts(stmt.body, names) if stmt.respond_to?(:body)
      end
    end

    def emit_scope_warnings(scope)
      scope.each_value do |binding|
        if !binding.used
          code = binding.binding_kind == :param ? "unused-param" : "unused-local"
          kind_label = binding.binding_kind == :param ? "parameter" : "local"
          @warnings << Warning.new(
            path: @path,
            line: binding.line,
            column: binding.column,
            length: binding.name.length,
            code: code,
            message: "unused #{kind_label} '#{binding.name}'",
            symbol_name: binding.name,
          )
        else
          # dead-assignment: emit confirmed intermediate overwrites
          @warnings.concat(binding.pending_dead_assignments) if binding.pending_dead_assignments
          # dead-assignment: final write whose value was never read
          if binding.last_write_line && binding.reads_after_write == 0
            @warnings << Warning.new(
              path: @path,
              line: binding.last_write_line,
              column: binding.last_write_column,
              length: binding.name.length,
              code: "dead-assignment",
              message: "value assigned to '#{binding.name}' is never read",
              symbol_name: binding.name
            )
          end
          if binding.allow_prefer_let && !binding.mutated
            @warnings << Warning.new(
              path: @path,
              line: binding.line,
              column: binding.column,
              length: binding.name.length,
              code: "prefer-let",
              message: "variable '#{binding.name}' is never reassigned, prefer 'let'",
              severity: :hint,
              symbol_name: binding.name
            )
          end
        end
      end
    end

    def ignored_binding_name?(name)
      name == "_" || name.start_with?("_")
    end
  end
end
