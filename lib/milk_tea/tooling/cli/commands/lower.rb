# frozen_string_literal: true

module MilkTea
  class CLI
    module CommandLower
      def lower_command
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
        return 1 unless ensure_known_source_operands!("lower", input_paths)

        paths = expand_source_paths(input_paths)
        return 0 if print_no_source_files_if_empty(paths, input_paths)

        ensure_current_lockfiles!(paths) if resolution[:frozen]

        multiple = paths.length > 1
        paths.each_with_index do |path, index|
          program = make_module_loader(path, locked: resolution[:locked], platform: ModuleLoader.default_host_platform).check_program(path)
          if multiple
            @out.puts("# --- #{path} ---") unless sexpr
          end
          if sexpr
            @out.puts(SexprDumper.dump_ir(Lowering.lower(program)))
          else
            @out.write(PrettyPrinter.format_ir(Lowering.lower(program)))
          end
        end
        0
      end
    end
  end
end
