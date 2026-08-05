# frozen_string_literal: true

module MilkTea
  class CLI
    module CommandEmitC
      def emit_c_command
        args = @argv.dup
        @argv = []
        until args.empty?
          arg = args.shift
          @argv << arg
        end

        unless @argv.any?
          @err.puts("missing source file path")
          print_usage(@err)
          return 1
        end

        resolution = extract_resolution_flags!
        input_paths = @argv.dup
        return 1 unless validate_source_operands("emit-c", input_paths)

        program_paths = input_paths.map { |p| resolve_program_path(p) }
        return 1 if program_paths.include?(nil)

        ensure_current_lockfiles!(input_paths) if resolution[:frozen]

        multiple = program_paths.length > 1
        program_paths.each_with_index do |path, index|
          program = create_module_loader(path, locked: resolution[:locked], platform: ModuleLoader.default_host_platform).check_program(path)
          if multiple
            @out.puts("/* --- #{path} --- */")
          end
          @out.write(CBackend.generate_c(Lowering.lower(program), emit_line_directives: false))
          @out.puts if multiple && index < program_paths.length - 1
        end
        0
      end

      def resolve_program_path(path)
        return path unless File.directory?(path)

        manifest_path = File.join(path, "package.toml")
        unless File.file?(manifest_path)
          @err.puts("no package.toml found in #{path}")
          return nil
        end

        manifest = PackageManifest.load(path)
        entry_path = manifest.source_path
        unless entry_path && File.file?(entry_path)
          @err.puts("no build entry found for #{path}")
          return nil
        end

        entry_path
      rescue PackageManifestError => e
        @err.puts("failed to load package manifest for #{path}: #{e.message}")
        nil
      end
    end
  end
end
