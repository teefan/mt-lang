# frozen_string_literal: true

module MilkTea
  module ImportedBindings
    class Generator
      module GeneratorMethodSource
        private

        def load_method_sources(method_specs)
          method_specs.each_with_object({}) do |spec, sources|
            next unless spec[:module_name]

            key = method_source_key(spec)
            next if sources.key?(key)

            sources[key] = load_method_source(spec)
          end
        end

        def load_method_source(spec)
          module_name = spec.fetch(:module_name)
          module_path = resolve_module_path(module_name)
          source_ast = ModuleLoader.new(module_roots: @module_roots).load_file(module_path)
          unless source_ast.module_name&.to_s == module_name
            raise Error, "expected #{module_path} to define module #{module_name}"
          end

          declarations = index_method_source_declarations(source_ast)
          MethodSource.new(
            module_name:,
            module_path:,
            module_kind: source_ast.module_kind,
            import_alias: spec.fetch(:module_import_alias),
            imports_by_alias: source_ast.imports.to_h { |import| [import.alias_name, import.path.parts.join(".")] },
            public_type_names: declarations[:types].keys,
            functions: declarations[:functions],
            function_order: declarations[:function_order],
            import_specs: [{ module_name:, alias: spec.fetch(:module_import_alias) }],
          )
        end

        def method_source_import_specs(method_sources)
          method_sources.values.flat_map(&:import_specs)
        end

        def method_source_key(spec)
          [spec.fetch(:module_name), spec.fetch(:module_import_alias)]
        end

        def index_method_source_declarations(source_ast)
          types = {}
          type_order = []
          functions = {}
          function_order = []

          source_ast.declarations.each do |declaration|
            case declaration
            when AST::TypeAliasDecl, AST::StructDecl, AST::UnionDecl, AST::EnumDecl, AST::FlagsDecl, AST::OpaqueDecl
              next unless visible_from_method_source?(declaration, module_kind: source_ast.module_kind)

              types[declaration.name] = declaration
              type_order << declaration.name
            when AST::ExternFunctionDecl, AST::ForeignFunctionDecl
              next unless visible_from_method_source?(declaration, module_kind: source_ast.module_kind)

              functions[declaration.name] = declaration
              function_order << declaration.name
            end
          end

          {
            types:,
            type_order:,
            functions:,
            function_order:,
          }
        end

        def visible_from_method_source?(declaration, module_kind:)
          return true if module_kind == :raw_module

          declaration.respond_to?(:visibility) && declaration.visibility == :public
        end

        def plan_method_source_function(declaration, source:)
          if declaration.respond_to?(:variadic) && declaration.variadic
            raise Error, "method generation for #{declaration.name} in #{source.module_path} cannot use variadic functions"
          end

          {
            raw_name: declaration.name,
            public_name: declaration.name,
            call_name: "#{source.import_alias}.#{declaration.name}",
            type_params: raw_type_param_names(declaration),
            params: declaration.params.map { |param| project_method_source_param(param, source:) },
            return_type: project_method_source_type(declaration.return_type, source:),
          }
        end

        def project_method_source_param(param, source:)
          case param
          when AST::ForeignParam
            {
              "name" => param.name,
              "type" => project_method_source_type(param.type, source:),
              "mode" => normalize_method_source_param_mode(param.mode),
            }
          when AST::Param
            {
              "name" => param.name,
              "type" => project_method_source_type(param.type, source:),
            }
          else
            raise Error, "unsupported method source parameter #{param.class.name} in #{source.module_path}"
          end
        end

        def normalize_method_source_param_mode(mode)
          return nil if mode == :plain || mode.nil?

          mode.to_s
        end

        def project_method_source_type(type, source:)
          case type
          when AST::TypeRef
            text = project_method_source_type_name(type.name.to_s, source:)
            unless type.arguments.empty?
              rendered_arguments = type.arguments.map { |argument| project_method_source_type_argument(argument.value, source:) }
              text << "[#{rendered_arguments.join(', ')}]"
            end
            text << "?" if type.nullable
            text
          when AST::FunctionType
            params = type.params.map { |param| project_method_source_function_type_param(param, source:) }.join(', ')
            "fn(#{params}) -> #{project_method_source_type(type.return_type, source:)}"
          else
            raise Error, "unsupported method source type node #{type.class.name} in #{source.module_path}"
          end
        end

        def project_method_source_function_type_param(param, source:)
          case param
          when AST::Param
            "#{param.name}: #{project_method_source_type(param.type, source:)}"
          when AST::ForeignParam
            text = +""
            text << "#{param.mode} " if param.mode
            text << "#{param.name}: #{project_method_source_type(param.type, source:)}"
            if param.boundary_type
              text << " as #{project_method_source_type(param.boundary_type, source:)}"
            end
            text
          else
            project_method_source_type(param, source:)
          end
        end

        def project_method_source_type_argument(argument, source:)
          case argument
          when AST::TypeRef, AST::FunctionType
            project_method_source_type(argument, source:)
          when AST::IntegerLiteral
            argument.lexeme
          when AST::Identifier
            argument.name
          else
            raise Error, "unsupported method source type argument #{argument.class.name} in #{source.module_path}"
          end
        end

        def project_method_source_type_name(raw_name, source:)
          parts = raw_name.split(".")
          if parts.length > 1
            import_alias = parts.first
            imported_name = parts[1..].join(".")
            imported_module_name = source.imports_by_alias[import_alias]
            return rendered_type_name(imported_name) if imported_module_name == @raw_module_name
            return imported_name if imported_module_name == @module_name
            return raw_name if imported_module_name
          end

          return "#{source.import_alias}.#{raw_name}" if source.public_type_names.include?(raw_name)

          rendered_type_name(raw_name)
        end
      end
    end
  end
end
