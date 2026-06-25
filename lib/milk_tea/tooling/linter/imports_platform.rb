# frozen_string_literal: true

module MilkTea
  class Linter
    module LinterImportsPlatform
      private

      # ── unused-import ────────────────────────────────────────────────────

      def check_unused_imports(source_file)
        return if source_file.imports.empty?

        used = collect_used_names(source_file)
        used.merge(collect_method_only_import_uses(source_file))
        source_file.imports.each do |import|
          next if @unresolved_import_paths.include?(import.path.to_s)

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

      def check_platform_api_drift(source_file)
        resolved_path = self.class.resolve_lint_path(@path)
        return unless resolved_path&.end_with?(".mt")

        sibling_paths = platform_variant_sibling_paths(resolved_path)
        return if sibling_paths.empty?

        current_surface_sites = exported_api_surface_sites(source_file)
        current_surface = current_surface_sites.keys.to_set
        sibling_paths.each do |sibling_path|
          sibling_source_file = load_sibling_source_file(sibling_path)
          next unless sibling_source_file
          next unless sibling_source_file.module_name.to_s == source_file.module_name.to_s

          sibling_surface = exported_api_surface(sibling_source_file)
          next if sibling_surface == current_surface

          missing = (sibling_surface - current_surface).to_a.sort
          extra = (current_surface - sibling_surface).to_a.sort
          anchor = platform_api_drift_anchor(source_file, current_surface_sites, extra:)
          @warnings << Warning.new(
            path: @path,
            line: anchor[:line],
            column: anchor[:column],
            length: anchor[:length],
            code: "platform-api-drift",
            message: platform_api_drift_message(sibling_path, missing:, extra:),
            symbol_name: anchor[:symbol_name],
          )
        end
      end
      def platform_api_drift_anchor(source_file, current_surface_sites, extra:)
        extra.each do |surface_entry|
          site = current_surface_sites[surface_entry]
          return site if site
        end

        first_export_site = current_surface_sites.values.min_by do |site|
          [site[:line] || Float::INFINITY, site[:column] || Float::INFINITY]
        end
        return first_export_site if first_export_site

        first_declaration = source_file.declarations.find { |declaration| declaration.respond_to?(:line) && declaration.line }
        return declaration_anchor(first_declaration) if first_declaration

        { line: source_file.line || 1, column: 1, length: 1, symbol_name: nil }
      end

      def exported_api_surface_sites(source_file)
        exported_type_names = exported_type_names(source_file)
        source_file.declarations.each_with_object({}) do |declaration, sites|
          case declaration
          when AST::ConstDecl
            sites[render_value_surface("const", declaration)] = declaration_anchor(declaration) if exported_declaration?(source_file, declaration)
          when AST::VarDecl
            sites[render_value_surface("var", declaration)] = declaration_anchor(declaration) if exported_declaration?(source_file, declaration)
          when AST::EventDecl
            sites[render_event_surface(declaration)] = declaration_anchor(declaration) if exported_declaration?(source_file, declaration)
          when AST::TypeAliasDecl
            sites["type #{declaration.name} = #{render_type_surface(declaration.target)}"] = declaration_anchor(declaration) if exported_declaration?(source_file, declaration)
          when AST::StructDecl
            sites[render_struct_surface(declaration)] = declaration_anchor(declaration) if exported_declaration?(source_file, declaration)
          when AST::UnionDecl
            sites[render_union_surface(declaration)] = declaration_anchor(declaration) if exported_declaration?(source_file, declaration)
          when AST::EnumDecl
            sites[render_enum_surface("enum", declaration)] = declaration_anchor(declaration) if exported_declaration?(source_file, declaration)
          when AST::FlagsDecl
            sites[render_enum_surface("flags", declaration)] = declaration_anchor(declaration) if exported_declaration?(source_file, declaration)
          when AST::OpaqueDecl
            sites[render_opaque_surface(declaration)] = declaration_anchor(declaration) if exported_declaration?(source_file, declaration)
          when AST::InterfaceDecl
            sites[render_interface_surface(declaration)] = declaration_anchor(declaration) if exported_declaration?(source_file, declaration)
          when AST::VariantDecl
            sites[render_variant_surface(declaration)] = declaration_anchor(declaration) if exported_declaration?(source_file, declaration)
          when AST::FunctionDef
            sites[render_callable_surface("function", declaration)] = declaration_anchor(declaration) if exported_declaration?(source_file, declaration)
          when AST::ExternFunctionDecl
            sites[render_callable_surface("external function", declaration, variadic: declaration.variadic)] = declaration_anchor(declaration) if exported_declaration?(source_file, declaration)
          when AST::ForeignFunctionDecl
            sites[render_callable_surface("foreign function", declaration, variadic: declaration.variadic)] = declaration_anchor(declaration) if exported_declaration?(source_file, declaration)
          when AST::ExtendingBlock
            next unless exported_type_names.include?(declaration.type_name.to_s)

            declaration.methods.each do |method|
              next unless method.visibility == :public

              sites[render_method_surface(declaration.type_name.to_s, method)] = declaration_anchor(method)
            end
          end
        end
      end

      def declaration_anchor(declaration)
        return { line: 1, column: 1, length: 1, symbol_name: nil } unless declaration

        symbol_name = declaration.respond_to?(:name) ? declaration.name : nil
        length = symbol_name.to_s.empty? ? 1 : symbol_name.to_s.length
        line = declaration.respond_to?(:line) && declaration.line ? declaration.line : 1

        if declaration.respond_to?(:column) && declaration.column
          return { line:, column: declaration.column, length:, symbol_name: }
        end

        if symbol_name && line
          line_text = @source_lines[line - 1].to_s
          index = line_text.index(symbol_name.to_s)
          return { line:, column: index ? index + 1 : 1, length:, symbol_name: }
        end

        { line:, column: 1, length: 1, symbol_name: }
      end

      def platform_variant_sibling_paths(path)
        current_platform = ModuleLoader.platform_suffix_for_path(path)
        shared_path = if current_platform
          path.sub(/\.#{Regexp.escape(current_platform.to_s)}\.mt\z/, ".mt")
        else
          path
        end

        [
          shared_path,
          *ModuleLoader::PLATFORM_SUFFIXES.keys.map { |platform_name| shared_path.delete_suffix(".mt") + ".#{platform_name}.mt" }
        ].uniq.select { |candidate| candidate != path && File.file?(candidate) }
      end

      def load_sibling_source_file(path)
        ModuleLoader.load_file(path)
      rescue StandardError
        nil
      end

      def exported_api_surface(source_file)
        exported_type_names = exported_type_names(source_file)
        source_file.declarations.each_with_object(Set.new) do |declaration, surface|
          case declaration
          when AST::ConstDecl
            surface << render_value_surface("const", declaration) if exported_declaration?(source_file, declaration)
          when AST::VarDecl
            surface << render_value_surface("var", declaration) if exported_declaration?(source_file, declaration)
          when AST::EventDecl
            surface << render_event_surface(declaration) if exported_declaration?(source_file, declaration)
          when AST::TypeAliasDecl
            surface << "type #{declaration.name} = #{render_type_surface(declaration.target)}" if exported_declaration?(source_file, declaration)
          when AST::StructDecl
            surface << render_struct_surface(declaration) if exported_declaration?(source_file, declaration)
          when AST::UnionDecl
            surface << render_union_surface(declaration) if exported_declaration?(source_file, declaration)
          when AST::EnumDecl
            surface << render_enum_surface("enum", declaration) if exported_declaration?(source_file, declaration)
          when AST::FlagsDecl
            surface << render_enum_surface("flags", declaration) if exported_declaration?(source_file, declaration)
          when AST::OpaqueDecl
            surface << render_opaque_surface(declaration) if exported_declaration?(source_file, declaration)
          when AST::InterfaceDecl
            surface << render_interface_surface(declaration) if exported_declaration?(source_file, declaration)
          when AST::VariantDecl
            surface << render_variant_surface(declaration) if exported_declaration?(source_file, declaration)
          when AST::FunctionDef
            surface << render_callable_surface("function", declaration) if exported_declaration?(source_file, declaration)
          when AST::ExternFunctionDecl
            surface << render_callable_surface("external function", declaration, variadic: declaration.variadic) if exported_declaration?(source_file, declaration)
          when AST::ForeignFunctionDecl
            surface << render_callable_surface("foreign function", declaration, variadic: declaration.variadic) if exported_declaration?(source_file, declaration)
          when AST::ExtendingBlock
            next unless exported_type_names.include?(declaration.type_name.to_s)

            declaration.methods.each do |method|
              next unless method.visibility == :public

              surface << render_method_surface(declaration.type_name.to_s, method)
            end
          end
        end
      end

      def exported_type_names(source_file)
        source_file.declarations.each_with_object(Set.new) do |declaration, names|
          next unless declaration.respond_to?(:name)
          next unless declaration.is_a?(AST::TypeAliasDecl) || declaration.is_a?(AST::StructDecl) ||
                      declaration.is_a?(AST::UnionDecl) || declaration.is_a?(AST::EnumDecl) ||
                      declaration.is_a?(AST::FlagsDecl) || declaration.is_a?(AST::OpaqueDecl) ||
                      declaration.is_a?(AST::InterfaceDecl) || declaration.is_a?(AST::VariantDecl)
          next unless exported_declaration?(source_file, declaration)

          names << declaration.name
        end
      end

      def exported_declaration?(source_file, declaration)
        return true if source_file.module_kind == :raw_module

        declaration.respond_to?(:visibility) && declaration.visibility == :public
      end

      def render_value_surface(kind, declaration)
        return "#{kind} #{declaration.name}" unless declaration.type

        "#{kind} #{declaration.name}: #{render_type_surface(declaration.type)}"
      end

      def render_event_surface(declaration)
        text = +"event #{declaration.name}[#{declaration.capacity}]"
        text << "(#{render_type_surface(declaration.payload_type)})" if declaration.payload_type
        text
      end

      def render_struct_surface(declaration)
        prefix = render_attribute_applications_surface(declaration.attributes)
        text = +""
        text << "#{prefix} " unless prefix.empty?
        text << "struct #{declaration.name}#{render_type_params_surface(declaration.type_params)}#{render_implements_surface(declaration.implements)}"
        members = []
        members.concat(declaration.fields.map { |field| "#{field.name}: #{render_type_surface(field.type)}" })
        members.concat(declaration.events.map { |event| render_event_surface(event) })
        text << " { #{members.join(', ')} }"
        text
      end

      def render_union_surface(declaration)
        "union #{declaration.name} { #{render_fields_surface(declaration.fields)} }"
      end

      def render_enum_surface(kind, declaration)
        members = declaration.members.map(&:name).join(", ")
        "#{kind} #{declaration.name}: #{render_type_surface(declaration.backing_type)} { #{members} }"
      end

      def render_opaque_surface(declaration)
        "opaque #{declaration.name}#{render_implements_surface(declaration.implements)}"
      end

      def render_interface_surface(declaration)
        methods = declaration.methods.map { |method| render_interface_method_surface(declaration.name, method) }.sort.join(", ")
        "interface #{declaration.name} { #{methods} }"
      end

      def render_variant_surface(declaration)
        arms = declaration.arms.map { |arm| render_variant_arm_surface(arm) }.join(", ")
        "variant #{declaration.name}#{render_type_params_surface(declaration.type_params)} { #{arms} }"
      end

      def render_variant_arm_surface(arm)
        return arm.name if arm.fields.empty?

        "#{arm.name}(#{arm.fields.map { |field| render_type_surface(field.respond_to?(:type) ? field.type : field) }.join(', ')})"
      end

      def render_method_surface(receiver_name, declaration)
        prefix = declaration.kind == :static ? "static method" : "method"
        render_callable_surface("#{prefix} #{receiver_name}.", declaration, name_prefix: "")
      end

      def render_interface_method_surface(interface_name, declaration)
        render_callable_surface("interface method #{interface_name}.", declaration, name_prefix: "")
      end

      def render_callable_surface(kind, declaration, variadic: false, name_prefix: nil)
        params = declaration.params.map { |param| render_param_surface(param) }
        params << "..." if variadic
        text = +""
        text << "async " if declaration.respond_to?(:async) && declaration.async
        text << kind
        text << (name_prefix.nil? ? " #{declaration.name}" : "#{name_prefix}#{declaration.name}")
        text << render_type_params_surface(declaration.respond_to?(:type_params) ? declaration.type_params : [])
        text << "(#{params.join(', ')})"
        text << " -> #{render_type_surface(declaration.return_type)}" if declaration.return_type
        text
      end

      def render_fields_surface(fields)
        fields.map { |field| "#{field.name}: #{render_type_surface(field.type)}" }.join(", ")
      end

      def render_attribute_applications_surface(attributes)
        attributes.map { |attribute| render_attribute_application_surface(attribute) }.join(' ')
      end

      def render_attribute_application_surface(attribute)
        text = +"@[#{attribute.name}"
        unless attribute.arguments.empty?
          rendered_arguments = attribute.arguments.map do |argument|
            value = case argument.value
                    when AST::IntegerLiteral, AST::FloatLiteral
                      argument.value.lexeme
                    when AST::StringLiteral
                      argument.value.lexeme
                    when AST::Identifier
                      argument.value.name
                    when AST::MemberAccess
                      "#{argument.value.receiver.name}.#{argument.value.member}"
                    else
                      "..."
                    end
            argument.name ? "#{argument.name} = #{value}" : value
          end
          text << "(#{rendered_arguments.join(', ')})"
        end
        text << "]"
        text
      end

      def render_param_surface(param)
        if param.respond_to?(:boundary_type) && param.boundary_type
          return "#{param.name}: #{render_type_surface(param.type)} as #{render_type_surface(param.boundary_type)}"
        end

        return param.name unless param.respond_to?(:type) && param.type

        "#{param.name}: #{render_type_surface(param.type)}"
      end

      def render_type_surface(type)
        case type
        when AST::TypeRef
          text = type.name.to_s
          unless type.arguments.empty?
            text += "[#{type.arguments.map { |argument| render_type_argument_surface(argument.value) }.join(', ')}]"
          end
          type.nullable ? "#{text}?" : text
        when AST::FunctionType
          "fn(#{type.params.map { |param| render_param_surface(param) }.join(', ')}) -> #{render_type_surface(type.return_type)}"
        when AST::ProcType
          "proc(#{type.params.map { |param| render_param_surface(param) }.join(', ')}) -> #{render_type_surface(type.return_type)}"
        else
          type.to_s
        end
      end

      def render_type_argument_surface(argument)
        case argument
        when AST::IntegerLiteral, AST::FloatLiteral
          argument.lexeme
        else
          render_type_surface(argument)
        end
      end

      def render_type_params_surface(type_params)
        return "" if type_params.nil? || type_params.empty?

        rendered = type_params.map do |type_param|
          next type_param.name if type_param.constraints.empty?

          "#{type_param.name} #{render_type_param_constraints_surface(type_param.constraints)}"
        end
        "[#{rendered.join(', ')}]"
      end

      def render_type_param_constraints_surface(constraints)
        parts = []
        index = 0
        while index < constraints.length
          constraint = constraints[index]
          if constraint.kind == :interface
            interfaces = [constraint.interface_ref.to_s]
            index += 1
            while index < constraints.length && constraints[index].kind == :interface
              interfaces << constraints[index].interface_ref.to_s
              index += 1
            end
            parts << "implements #{interfaces.join(' and ')}"
          else
            raise "unsupported type parameter constraint #{constraint.kind}"
          end
        end

        parts.join(" and ")
      end

      def render_implements_surface(implements)
        return "" if implements.nil? || implements.empty?

        " implements #{implements.map(&:to_s).sort.join(', ')}"
      end

      def platform_api_drift_message(sibling_path, missing:, extra:)
        parts = []
        parts << "missing #{summarize_platform_surface_entries(missing)}" unless missing.empty?
        parts << "extra #{summarize_platform_surface_entries(extra)}" unless extra.empty?
        "public API differs from #{File.basename(sibling_path)}: #{parts.join('; ')}"
      end

      def summarize_platform_surface_entries(entries, limit: 2)
        shown = entries.first(limit).map { |entry| "'#{entry}'" }
        remaining = entries.length - shown.length
        return shown.join(", ") if remaining <= 0

        "#{shown.join(', ')} (+#{remaining} more)"
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

      def collect_method_only_import_uses(source_file)
        return Set.new unless @sema_facts
        return Set.new unless @sema_facts.respond_to?(:binding_resolution) && @sema_facts.binding_resolution

        binding_resolution = @sema_facts.binding_resolution
        import_module_names = @sema_facts.imports.each_with_object({}) do |(local_name, imported_module), map|
          map[imported_module.name] = local_name
        end

        used = Set.new
        source_file.declarations.each do |decl|
          collect_indirect_import_uses_from_declaration(decl, used, binding_resolution, import_module_names)
        end
        used
      end

      def collect_indirect_import_uses_from_declaration(decl, used, binding_resolution, import_module_names)
        case decl
        when AST::FunctionDef, AST::MethodDef
          decl.body&.each { |stmt| collect_indirect_import_uses_from_stmt(stmt, used, binding_resolution, import_module_names) }
        when AST::ExtendingBlock
          decl.methods.each { |m| collect_indirect_import_uses_from_declaration(m, used, binding_resolution, import_module_names) }
        when AST::ConstDecl, AST::VarDecl
          collect_indirect_import_uses_from_expr(decl.value, used, binding_resolution, import_module_names) if decl.value
        when AST::ForeignFunctionDecl
          collect_indirect_import_uses_from_expr(decl.mapping, used, binding_resolution, import_module_names) if decl.mapping
        end
      end

      def collect_indirect_import_uses_from_stmt(stmt, used, binding_resolution, import_module_names)
        case stmt
        when AST::LocalDecl
          collect_indirect_import_uses_from_expr(stmt.value, used, binding_resolution, import_module_names) if stmt.value
        when AST::Assignment
          collect_indirect_import_uses_from_expr(stmt.target, used, binding_resolution, import_module_names)
          collect_indirect_import_uses_from_expr(stmt.value, used, binding_resolution, import_module_names)
        when AST::IfStmt
          stmt.branches.each do |branch|
            collect_indirect_import_uses_from_expr(branch.condition, used, binding_resolution, import_module_names)
            branch.body&.each { |child| collect_indirect_import_uses_from_stmt(child, used, binding_resolution, import_module_names) }
          end
          stmt.else_body&.each { |child| collect_indirect_import_uses_from_stmt(child, used, binding_resolution, import_module_names) }
        when AST::MatchStmt
          collect_indirect_import_uses_from_expr(stmt.expression, used, binding_resolution, import_module_names)
          stmt.arms.each { |arm| arm.body.each { |child| collect_indirect_import_uses_from_stmt(child, used, binding_resolution, import_module_names) } }
        when AST::ForStmt
          stmt.iterables.each { |iterable| collect_indirect_import_uses_from_expr(iterable, used, binding_resolution, import_module_names) }
          stmt.body.each { |child| collect_indirect_import_uses_from_stmt(child, used, binding_resolution, import_module_names) }
        when AST::WhileStmt
          collect_indirect_import_uses_from_expr(stmt.condition, used, binding_resolution, import_module_names)
          stmt.body.each { |child| collect_indirect_import_uses_from_stmt(child, used, binding_resolution, import_module_names) }
        when AST::UnsafeStmt
          stmt.body.each { |child| collect_indirect_import_uses_from_stmt(child, used, binding_resolution, import_module_names) }
        when AST::DeferStmt
          collect_indirect_import_uses_from_expr(stmt.expression, used, binding_resolution, import_module_names) if stmt.expression
          stmt.body&.each { |child| collect_indirect_import_uses_from_stmt(child, used, binding_resolution, import_module_names) }
        when AST::ReturnStmt
          collect_indirect_import_uses_from_expr(stmt.value, used, binding_resolution, import_module_names) if stmt.value
        when AST::ExpressionStmt
          collect_indirect_import_uses_from_expr(stmt.expression, used, binding_resolution, import_module_names)
        when AST::StaticAssert
          collect_indirect_import_uses_from_expr(stmt.condition, used, binding_resolution, import_module_names)
        when AST::WhenStmt
          collect_indirect_import_uses_from_expr(stmt.discriminant, used, binding_resolution, import_module_names)
          stmt.branches.each { |b| b.body.each { |child| collect_indirect_import_uses_from_stmt(child, used, binding_resolution, import_module_names) } }
          stmt.else_body&.each { |child| collect_indirect_import_uses_from_stmt(child, used, binding_resolution, import_module_names) }
        when AST::ErrorBlockStmt
          stmt.body.each { |child| collect_indirect_import_uses_from_stmt(child, used, binding_resolution, import_module_names) } if stmt.body
        end
      end

      def collect_indirect_import_uses_from_expr(expr, used, binding_resolution, import_module_names)
        case expr
        when nil then nil
        when AST::MemberAccess
          collect_indirect_import_uses_from_expr(expr.receiver, used, binding_resolution, import_module_names)
        when AST::IndexAccess
          collect_indirect_import_uses_from_expr(expr.receiver, used, binding_resolution, import_module_names)
          collect_indirect_import_uses_from_expr(expr.index, used, binding_resolution, import_module_names)
        when AST::Specialization
          collect_indirect_import_uses_from_expr(expr.callee, used, binding_resolution, import_module_names)
        when AST::Call
          if expr.callee.is_a?(AST::MemberAccess)
            import_alias = receiver_import_alias(expr.callee.receiver, binding_resolution, import_module_names)
            used << import_alias if import_alias
            collect_method_provider_import_uses(expr.callee.receiver, expr.callee.member, used, binding_resolution)
          end
          collect_indirect_import_uses_from_expr(expr.callee, used, binding_resolution, import_module_names)
          expr.arguments.each { |argument| collect_indirect_import_uses_from_expr(argument.value, used, binding_resolution, import_module_names) }
        when AST::UnaryOp
          collect_indirect_import_uses_from_expr(expr.operand, used, binding_resolution, import_module_names)
        when AST::BinaryOp
          collect_indirect_import_uses_from_expr(expr.left, used, binding_resolution, import_module_names)
          collect_indirect_import_uses_from_expr(expr.right, used, binding_resolution, import_module_names)
        when AST::RangeExpr
          collect_indirect_import_uses_from_expr(expr.start_expr, used, binding_resolution, import_module_names)
          collect_indirect_import_uses_from_expr(expr.end_expr, used, binding_resolution, import_module_names)
        when AST::ExpressionList
          expr.elements.each { |element| collect_indirect_import_uses_from_expr(element, used, binding_resolution, import_module_names) }
        when AST::IfExpr
          collect_indirect_import_uses_from_expr(expr.condition, used, binding_resolution, import_module_names)
          collect_indirect_import_uses_from_expr(expr.then_expression, used, binding_resolution, import_module_names)
          collect_indirect_import_uses_from_expr(expr.else_expression, used, binding_resolution, import_module_names)
        when AST::MatchExpr
          collect_indirect_import_uses_from_expr(expr.expression, used, binding_resolution, import_module_names)
          expr.arms.each { |arm| collect_indirect_import_uses_from_expr(arm.value, used, binding_resolution, import_module_names) }
        when AST::ProcExpr
          expr.body.each { |stmt| collect_indirect_import_uses_from_stmt(stmt, used, binding_resolution, import_module_names) }
        when AST::AwaitExpr
          collect_indirect_import_uses_from_expr(expr.expression, used, binding_resolution, import_module_names)
        when AST::UnsafeExpr
          collect_indirect_import_uses_from_expr(expr.expression, used, binding_resolution, import_module_names)
        when AST::FormatString
          expr.parts.each { |part| collect_indirect_import_uses_from_expr(part.expression, used, binding_resolution, import_module_names) if part.is_a?(AST::FormatExprPart) }
        when AST::SizeofExpr, AST::AlignofExpr, AST::OffsetofExpr
          nil
        end
      end

      def receiver_import_alias(receiver, binding_resolution, import_module_names)
        case receiver
        when AST::Identifier
          binding_id = binding_resolution.identifier_binding_ids[receiver.object_id]
          return nil unless binding_id

          type = binding_resolution.binding_types[binding_id]
          return nil unless type

          module_name = type_module_name(type)
          return nil unless module_name

          import_module_names[module_name]
        end
      end

      # Credits any imported module that provides the invoked method on the
      # receiver's type. The receiver-type-module heuristic above only credits
      # the module that *defines* the receiver type, so it misses extension
      # methods (`extending str:`, `extending int:`, ...) declared in a
      # different module on a builtin or foreign type.
      def collect_method_provider_import_uses(receiver, member_name, used, binding_resolution)
        return unless receiver.is_a?(AST::Identifier)
        return unless @sema_facts.respond_to?(:imports)

        receiver_type = identifier_binding_type(receiver, binding_resolution)
        return unless receiver_type

        @sema_facts.imports.each do |local_name, module_binding|
          next unless module_binding.respond_to?(:methods)
          next unless import_module_defines_method?(module_binding, receiver_type, member_name)

          used << local_name
        end
      end

      def identifier_binding_type(identifier, binding_resolution)
        binding_id = binding_resolution.identifier_binding_ids[identifier.object_id]
        return nil unless binding_id

        binding_resolution.binding_types[binding_id]
      end

      def import_module_defines_method?(module_binding, receiver_type, member_name)
        method_map = module_binding.methods
        return false unless method_map

        entries = method_map.fetch(receiver_type, nil)
        return false unless entries

        entries.key?(member_name) || entries.key?("static:#{member_name}")
      end

      def collect_qualified_name_root(name, used)
        return unless name.respond_to?(:parts) && name.parts.any?

        used << name.parts.first
      end

      def type_module_name(type)
        if type.respond_to?(:definition)
          definition = type.definition
          if definition.respond_to?(:module_name) && definition.module_name
            return definition.module_name
          end
        end

        type.respond_to?(:module_name) ? type.module_name : nil
      end

      def collect_names_from_declaration(decl, used)
        case decl
        when AST::FunctionDef, AST::MethodDef
          decl.params.each { |p| collect_names_from_type(p.type, used) if p.respond_to?(:type) && p.type }
          collect_names_from_type(decl.return_type, used) if decl.return_type
          decl.body&.each { |stmt| collect_names_from_statement(stmt, used) }
        when AST::ExtendingBlock
          collect_names_from_type(decl.type_name, used)
          decl.methods.each { |m| collect_names_from_declaration(m, used) }
        when AST::StructDecl
          decl.fields.each { |f| collect_names_from_type(f.type, used) }
          decl.events.each { |event| collect_names_from_type(event.payload_type, used) if event.payload_type }
          decl.implements&.each { |iface| collect_qualified_name_root(iface, used) }
        when AST::UnionDecl
          decl.fields.each { |f| collect_names_from_type(f.type, used) }
        when AST::TypeAliasDecl
          collect_names_from_type(decl.target, used)
        when AST::EventDecl
          collect_names_from_type(decl.payload_type, used) if decl.payload_type
        when AST::ConstDecl, AST::VarDecl
          collect_names_from_type(decl.type, used) if decl.type
          collect_names_from_expr(decl.value, used) if decl.value
        when AST::ExternFunctionDecl
          decl.params.each { |p| collect_names_from_type(p.type, used) if p.respond_to?(:type) && p.type }
          collect_names_from_type(decl.return_type, used) if decl.return_type
        when AST::ForeignFunctionDecl
          decl.params.each { |p| collect_names_from_type(p.type, used) if p.respond_to?(:type) && p.type }
          collect_names_from_type(decl.return_type, used) if decl.return_type
          collect_names_from_expr(decl.mapping, used) if decl.mapping
        when AST::EnumDecl, AST::FlagsDecl
          collect_names_from_type(decl.backing_type, used) if decl.backing_type
        when AST::InterfaceDecl
          decl.methods.each do |method|
            method.params.each { |p| collect_names_from_type(p.type, used) if p.respond_to?(:type) && p.type }
            collect_names_from_type(method.return_type, used) if method.return_type
          end
        when AST::VariantDecl
          decl.arms.each do |arm|
            arm.fields.each { |f| collect_names_from_type(f.type, used) }
          end
        when AST::OpaqueDecl
          decl.implements&.each { |iface| collect_qualified_name_root(iface, used) }
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
          stmt.arms.each do |arm|
            collect_names_from_expr(arm.pattern, used)
            arm.body.each { |s| collect_names_from_statement(s, used) }
          end
        when AST::ForStmt
          stmt.iterables.each { |iterable| collect_names_from_expr(iterable, used) }
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
        when AST::WhenStmt
          collect_names_from_expr(stmt.discriminant, used)
          stmt.branches.each { |b| b.body.each { |s| collect_names_from_statement(s, used) } }
          stmt.else_body&.each { |s| collect_names_from_statement(s, used) }
        when AST::ErrorBlockStmt
          stmt.body.each { |s| collect_names_from_statement(s, used) } if stmt.body
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
        when AST::RangeExpr
          collect_names_from_expr(expr.start_expr, used)
          collect_names_from_expr(expr.end_expr, used)
        when AST::ExpressionList
          expr.elements.each { |e| collect_names_from_expr(e, used) }
        when AST::IfExpr
          collect_names_from_expr(expr.condition, used)
          collect_names_from_expr(expr.then_expression, used)
          collect_names_from_expr(expr.else_expression, used)
        when AST::MatchExpr
          collect_names_from_expr(expr.expression, used)
          expr.arms.each do |arm|
            collect_names_from_expr(arm.pattern, used)
            collect_names_from_expr(arm.value, used)
          end
        when AST::ProcExpr
          expr.params.each { |p| collect_names_from_type(p.type, used) if p.respond_to?(:type) && p.type }
          expr.body.each { |s| collect_names_from_statement(s, used) }
        when AST::AwaitExpr then collect_names_from_expr(expr.expression, used)
        when AST::UnsafeExpr then collect_names_from_expr(expr.expression, used)
        when AST::FormatString
          expr.parts.each { |p| collect_names_from_expr(p.expression, used) if p.is_a?(AST::FormatExprPart) }
        when AST::SizeofExpr, AST::AlignofExpr
          collect_names_from_type(expr.type, used)
        when AST::OffsetofExpr
          collect_names_from_type(expr.type, used)
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

    end
  end
end
