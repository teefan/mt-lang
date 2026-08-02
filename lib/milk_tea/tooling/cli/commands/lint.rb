# frozen_string_literal: true

module MilkTea
  class CLI
    module CommandLint
      def lint_command
        resolution = { locked: false, frozen: false }
        select = nil
        ignore = nil
        fix = false
        init = false
        ignore_generated = false
        profile = false
        input_paths = []
        until @argv.empty?
          arg = @argv.shift
          unless arg.start_with?("--")
            input_paths << arg
            next
          end

          flag = arg
          case flag
          when "--select"
            arg = @argv.shift
            unless arg
              @err.puts("--select requires a comma-separated list of rule codes")
              return 1
            end
            select = arg.split(",").map(&:strip).to_set
          when "--ignore"
            arg = @argv.shift
            unless arg
              @err.puts("--ignore requires a comma-separated list of rule codes")
              return 1
            end
            ignore = arg.split(",").map(&:strip).to_set
          when "--fix"
            fix = true
          when "--init"
            init = true
          when "--locked"
            resolution[:locked] = true
          when "--frozen"
            resolution[:locked] = true
            resolution[:frozen] = true
          when "--ignore-generated"
            ignore_generated = true
          when "--timings"
            profile = true
          when "--"
            input_paths.concat(@argv)
            @argv.clear
          else
            @err.puts("unknown lint flag: #{flag}")
            return 1
          end
        end

        if init
          if input_paths.empty? && !select && !ignore && !fix && !resolution[:locked] && !resolution[:frozen]
            return init_lint_config
          end

          @err.puts("--init does not accept source paths or lint options")
          return 1
        end

        if input_paths.empty?
          @err.puts("missing source file path")
          print_usage(@err)
          return 1
        end

        paths = input_paths.flat_map do |path|
          if File.directory?(path)
            Dir.glob(File.join(path, "**/*.mt")).sort
          else
            [path]
          end
        end.uniq

        if paths.empty?
          label = input_paths.length == 1 ? input_paths.first : input_paths.join(", ")
          @out.puts("no .mt files found in #{label}")
          return 0
        end

        ensure_current_lockfiles!(paths) if resolution[:frozen]

        if fix
          lint_profiles = []
          paths.each do |p|
            announce_file_action(p, "lint-fix")
            source = read_source_file(p)
            if ignore_generated && generated_source?(source)
              @out.puts("ignored generated #{p}")
              next
            end

            facts = lint_sema_facts_for(source, p, locked: resolution[:locked])
            prof = profile ? Linter::Profile.new : nil
            start_time = profile ? Process.clock_gettime(Process::CLOCK_MONOTONIC) : nil

            fixed = Linter.fix_source(
              source,
              path: p,
              sema_facts: facts,
              select:,
              ignore:,
              profile: prof,
            )
            total_ms = start_time ? ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000.0).round(1) : nil
            lint_profiles << { path: p, profile: prof, mode: :pre_fix_scan, total_ms: } if prof
            if fixed != source
              File.write(p, fixed)
              @out.puts("fixed #{p}")
            end
          end
          print_lint_rule_profiles(lint_profiles) if profile
          print_lint_file_profiles(lint_profiles) if profile
          return 0
        end

        lint_profiles = []
        all_warnings = paths.flat_map do |p|
          announce_file_action(p, "lint")
          source = read_source_file(p)
          next [] if ignore_generated && generated_source?(source)

          facts = lint_sema_facts_for(source, p, locked: resolution[:locked])
          prof = profile ? Linter::Profile.new : nil
          start_time = profile ? Process.clock_gettime(Process::CLOCK_MONOTONIC) : nil
          warnings = Linter.lint_source(source, path: p, select:, ignore:, sema_facts: facts, profile: prof)
          total_ms = start_time ? ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000.0).round(1) : nil
          lint_profiles << { path: p, profile: prof, mode: :lint, total_ms: } if prof
          warnings
        end

        if all_warnings.empty?
          if input_paths.length == 1
            info("clean #{input_paths.first}")
          else
            info("clean #{paths.size} file(s)")
          end
          print_lint_file_profiles(lint_profiles) if profile
          return 0
        end

        all_warnings.each do |warning|
          @out.puts("#{warning.path}:#{warning.line}: #{warning.code}: #{warning.message}")
        end

        print_lint_rule_profiles(lint_profiles) if profile
        print_lint_file_profiles(lint_profiles) if profile

        file_count = all_warnings.map(&:path).uniq.size
        noun = all_warnings.size == 1 ? "warning" : "warnings"
        files_str = file_count == 1 ? "1 file" : "#{file_count} files"
        @out.puts("Found #{all_warnings.size} #{noun} in #{files_str}.")
        1
      end

      def init_lint_config
        path = File.join(Dir.pwd, Linter::DEFAULT_CONFIG_FILE_NAME)
        if File.exist?(path)
          @err.puts("lint config already exists at #{path}")
          return 1
        end

        File.write(path, Linter.default_config_source)
        info("created #{path}")
        0
      end

      def print_lint_rule_profiles(lint_profiles, limit: 12)
        lint_profiles.each do |entry|
          profile = entry[:profile]
          next unless profile

          rows = profile.rule_breakdown(limit:, min_ms: 0.0)
          rule_total = profile.total_time_ms(prefix: "rule.")
          overall_total = profile.total_time_ms
          mode_label = entry[:mode] == :pre_fix_scan ? "pre-fix scan" : "lint scan"
          @out.puts("lint profile #{entry[:path]} (#{mode_label}): rules=#{format('%.1f', rule_total)}ms total=#{format('%.1f', overall_total)}ms")

          if rows.empty?
            @out.puts("  no rule timing data captured")
            next
          end

          rows.each do |row|
            share = rule_total.positive? ? ((row[:total_ms] / rule_total) * 100.0) : 0.0
            @out.puts(
              "  #{row[:code]}: #{row[:count]}x total=#{format('%.1f', row[:total_ms])}ms avg=#{format('%.2f', row[:avg_ms])}ms share=#{format('%.1f', share)}%"
            )
          end

          non_rule_rows = profile.timings_ms
            .filter_map do |name, total_ms|
              next if name.start_with?("rule.")
              next if total_ms < 1.0

              [name, total_ms]
            end
            .sort_by { |_name, total_ms| -total_ms }
            .first(5)
            .map do |name, total_ms|
              count = profile.counts[name]
              "#{name}:#{count}x/#{format('%.1f', total_ms)}ms"
            end

          @out.puts("  non-rule hot phases: #{non_rule_rows.join(', ')}") unless non_rule_rows.empty?
        end
      end

      def print_lint_file_profiles(lint_profiles)
        file_entries = lint_profiles.filter_map do |entry|
          total = entry[:total_ms]
          next unless total

          phases = entry[:profile]&.timings_ms&.reject { |name, _| name.start_with?("rule.") }&.sort_by { |_, ms| -ms }
          { path: entry[:path], total_ms: total, phases: }
        end
        return if file_entries.empty?

        sorted = file_entries.sort_by { |e| -e[:total_ms] }
        @out.puts
        @out.puts("Profile (lint): #{sorted.size} file(s)")
        sorted.each do |entry|
          phase_str = entry[:phases]&.filter_map { |name, ms| "#{name}: #{format('%.1f', ms)}ms" if ms >= 1.0 }&.join(", ")
          detail = phase_str && !phase_str.empty? ? " (#{phase_str})" : ""
          @out.puts("  #{entry[:path]}: #{format('%.1f', entry[:total_ms])}ms#{detail}")
        end
        total = sorted.sum { |e| e[:total_ms] }
        @out.puts("Total: #{format('%.1f', total)}ms")
      end

      def lint_sema_facts_for(source, path, locked: false)
        ast = Parser.parse(source, path: path)
        imported_modules = make_module_loader(path, locked:, platform: ModuleLoader.default_host_platform).imported_modules_for_ast(ast, importer_path: path)
        SemanticAnalyzer.tooling_snapshot(ast, imported_modules: imported_modules, path: path).facts
      rescue MilkTea::LexError, MilkTea::ParseError, SemanticError, ModuleLoadError
        nil
      end
    end
  end
end
