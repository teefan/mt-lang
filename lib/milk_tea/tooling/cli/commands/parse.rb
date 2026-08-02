# frozen_string_literal: true

module MilkTea
  class CLI
    module CommandParse
      def parse_command
        sexpr = false
        args = @argv.dup
        @argv = []
        until args.empty?
          arg = args.shift
          if arg == "--sexpr"
            sexpr = true
            next
          end
          @argv << arg
        end

        unless @argv.any?
          @err.puts("missing source file path")
          print_usage(@err)
          return 1
        end

        resolution = extract_resolution_flags!
        input_paths = @argv.dup
        return 1 unless ensure_known_source_operands!("parse", input_paths)

        paths = expand_source_paths(input_paths)
        return 0 if print_no_source_files_if_empty(paths, input_paths)

        ensure_current_lockfiles!(paths) if resolution[:frozen]

        multiple = paths.length > 1
        paths.each_with_index do |path, index|
          ast = make_module_loader(path, locked: resolution[:locked], platform: ModuleLoader.default_host_platform).load_file(path)
          if multiple
            @out.puts("# --- #{path} ---") unless sexpr
          end
          if sexpr
            @out.puts(SexprDumper.dump_ast(ast))
          else
            @out.write(PrettyPrinter.format_ast(ast))
          end
          @out.puts if multiple && index < paths.length - 1
        end
        0
      end
    end
  end
end
