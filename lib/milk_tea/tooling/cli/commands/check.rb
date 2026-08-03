# frozen_string_literal: true

module MilkTea
  class CLI
    module CommandCheck
      def check_command
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
        return 1 unless ensure_known_source_operands!("check", input_paths)

        paths = expand_source_paths(input_paths)
        return 0 if print_no_source_files_if_empty(paths, input_paths)

        ensure_current_lockfiles!(paths) if resolution[:frozen]

        all_diagnostics = []
        paths.each do |path|
          diagnostics, module_name, closure_errors = check_single_reporting_all(path, locked: resolution[:locked])
          closure_errors = [] if paths.length > 1
          diagnostics = sort_by_location(diagnostics)

          if diagnostics.any? || closure_errors.any?
            main_source = read_source_file(path)
            main_abs = File.expand_path(path)
            diagnostics.each do |d|
              same_file = !d.respond_to?(:path) || d.path.nil? || File.expand_path(d.path) == main_abs
              source = same_file ? main_source : nil
              @err.puts(ErrorFormatter.format(d, source:, color: error_color?(@err)))
            end
            closure_errors.each do |d|
              same_file = !d.respond_to?(:path) || d.path.nil? || File.expand_path(d.path) == main_abs
              source = same_file ? main_source : nil
              @err.puts(ErrorFormatter.format(d, source:, color: error_color?(@err)))
            end
            all_diagnostics.concat(diagnostics)
            all_diagnostics.concat(closure_errors)
          elsif module_name
            info("checked #{path} as #{module_name}")
          end
        end

        return 0 if all_diagnostics.empty?

        error_count = all_diagnostics.count { |d| !d.respond_to?(:severity) || d.severity == :error }
        warning_count = all_diagnostics.count { |d| d.respond_to?(:severity) && d.severity == :warning }
        info_count = all_diagnostics.count { |d| d.respond_to?(:severity) && (d.severity == :info || d.severity == :hint) }

        @err.puts
        parts = []
        parts << "#{error_count} #{error_count == 1 ? 'error' : 'errors'}" if error_count > 0
        parts << "#{warning_count} #{warning_count == 1 ? 'warning' : 'warnings'}" if warning_count > 0
        parts << "#{info_count} #{info_count == 1 ? 'note' : 'notes'}" if info_count > 0
        body = parts.join("; ")
        if error_count > 0
          @err.puts("#{body} found")
        elsif warning_count > 0
          @err.puts("#{body}")
        end
        final_error_count = error_count + (resolution[:warnings_as_errors] ? warning_count : 0)
        final_error_count > 0 ? 1 : 0
      end

      def check_single_reporting_all(path, locked: false)
        loader = make_module_loader(path, locked:, platform: ModuleLoader.default_host_platform)
        resolved_path = File.expand_path(path)

        result = loader.check_program_collecting(path)
        errors = result[:errors]
        analysis = result[:root_analysis]
        module_name = result[:module_name]

        if analysis && errors.empty?
          source = read_source_file(path)
          warnings = Linter.lint_source(source, path: resolved_path, sema_facts: analysis, lint_tier: :full)
          errors.concat(warnings)
        end

        [errors, module_name, []]
      rescue ModuleLoadError, PackageLockError => e
        [[e], nil, []]
      end

      def sort_by_location(errors)
        errors.sort_by do |e|
          actual = e.respond_to?(:error) ? e.error : e
          line = actual.respond_to?(:line) ? actual.line.to_i : 0
          column = actual.respond_to?(:column) ? actual.column.to_i : 0
          [line, column]
        end
      end
    end
  end
end
