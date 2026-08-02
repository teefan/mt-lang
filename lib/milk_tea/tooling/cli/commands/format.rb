# frozen_string_literal: true

module MilkTea
  class CLI
    module CommandFormat
      def format_command
        parsed = parse_format_options
        return 1 unless parsed

        options = parsed[:options]
        input_paths = parsed[:input_paths]

        if input_paths.empty?
          @err.puts("missing source file path")
          print_usage(@err)
          return 1
        end

        paths = expand_source_paths(input_paths)
        return 0 if print_no_source_files_if_empty(paths, input_paths)

        multiple_sources = input_paths.length > 1 || input_paths.any? { |path| File.directory?(path) }
        if multiple_sources
          unless options[:check] || options[:write]
            @err.puts("format on multiple sources requires --check or --write")
            print_usage(@err)
            return 1
          end

          return format_paths(paths, options)
        end

        path = paths.first

        source = read_source_file(path)
        format_profile = options[:profile] ? Linter::Profile.new : nil
        start_time = options[:profile] ? Process.clock_gettime(Process::CLOCK_MONOTONIC) : nil
        result = Formatter.check_source(source, path: path, mode: options[:mode], max_line_length: options[:max_line_length], profile: format_profile)
        elapsed_ms = start_time ? ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000.0).round(1) : nil

        rc = if options[:check]
          announce_file_action(path, "format-check")
          if result.changed
            info("needs formatting #{path}")
            1
          else
            info("already formatted #{path}")
            0
          end
        elsif options[:write]
          announce_file_action(path, "format-write")
          if result.changed
            File.write(path, result.formatted_source)
            info("formatted #{path}")
          else
            info("already formatted #{path}")
          end
          0
        else
          @out.write(result.formatted_source)
          0
        end

        print_file_profiles([{ path:, total_ms: elapsed_ms, profile: format_profile }], "format") if options[:profile]
        rc
      end

      def format_paths(paths, options)
        format_profiles = []
        if options[:check]
          needs_fmt = []
          paths.each do |p|
            announce_file_action(p, "format-check")
            format_profile = options[:profile] ? Linter::Profile.new : nil
            start_time = options[:profile] ? Process.clock_gettime(Process::CLOCK_MONOTONIC) : nil
            result = Formatter.check_source(read_source_file(p), path: p, mode: options[:mode], max_line_length: options[:max_line_length], profile: format_profile)
            elapsed_ms = start_time ? ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000.0).round(1) : nil
            format_profiles << { path: p, total_ms: elapsed_ms, profile: format_profile } if options[:profile]
            needs_fmt << p if result.changed
          end
          print_file_profiles(format_profiles, "format") if options[:profile]
          if needs_fmt.empty?
            info("all #{paths.size} file(s) already formatted")
            return 0
          end
          needs_fmt.each { |p| info("needs formatting #{p}") }
          info("#{needs_fmt.size} file(s) need formatting")
          return 1
        end

        # --write
        changed = 0
        paths.each do |p|
          announce_file_action(p, "format-write")
          format_profile = options[:profile] ? Linter::Profile.new : nil
          start_time = options[:profile] ? Process.clock_gettime(Process::CLOCK_MONOTONIC) : nil
          result = Formatter.check_source(read_source_file(p), path: p, mode: options[:mode], max_line_length: options[:max_line_length], profile: format_profile)
          elapsed_ms = start_time ? ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000.0).round(1) : nil
          format_profiles << { path: p, total_ms: elapsed_ms, profile: format_profile } if options[:profile]
          if result.changed
            File.write(p, result.formatted_source)
            info("formatted #{p}")
            changed += 1
          end
        end
        print_file_profiles(format_profiles, "format") if options[:profile]
        info("formatted #{changed} of #{paths.size} file(s)")
        0
      end

      def parse_format_options
        options = {
          check: false,
          write: false,
          mode: :safe,
          max_line_length: nil,
          profile: false,
        }
        input_paths = []

        until @argv.empty?
          option = @argv.shift
          if option.start_with?("-")
            case option
            when "--check"
              options[:check] = true
            when "--write", "-w"
              options[:write] = true
            when "--preserve"
              options[:mode] = :preserve
            when "--canonical"
              options[:mode] = :canonical
            when "--safe"
              options[:mode] = :safe
            when "--tidy"
              options[:mode] = :tidy
            when "--max-line-length"
              value = @argv.shift
              return missing_option_value(option) unless value

              line_length = Integer(value, exception: false)
              unless line_length && line_length.positive?
                @err.puts("--max-line-length must be a positive integer")
                print_usage(@err)
                return nil
              end

              options[:max_line_length] = line_length
            when "--timings"
              options[:profile] = true
            when "--"
              input_paths.concat(@argv)
              @argv.clear
            else
              @err.puts("unknown format option #{option}")
              print_usage(@err)
              return nil
            end
          else
            input_paths << option
          end
        end

        if options[:check] && options[:write]
          @err.puts("format options --check and --write cannot be combined")
          print_usage(@err)
          return nil
        end

        { options:, input_paths: }
      end

      def print_file_profiles(file_profiles, label)
        sorted = file_profiles.sort_by { |fp| -fp[:total_ms] }
        return if sorted.empty?

        @out.puts
        if sorted.size == 1
          entry = sorted.first
          phases = entry[:profile]&.timings_ms&.sort_by { |_, ms| -ms }
          phase_str = phases&.filter_map { |name, ms| "#{name}: #{format('%.1f', ms)}ms" if ms >= 0.1 }&.join(", ")
          detail = phase_str && !phase_str.empty? ? " (#{phase_str})" : ""
          @out.puts("#{label} profile #{entry[:path]}: #{format('%.1f', entry[:total_ms])}ms#{detail}")
          return
        end

        @out.puts("Profile (#{label}): #{sorted.size} file(s)")
        sorted.each do |entry|
          phases = entry[:profile]&.timings_ms&.sort_by { |_, ms| -ms }
          phase_str = phases&.filter_map { |name, ms| "#{name}: #{format('%.1f', ms)}ms" if ms >= 1.0 }&.join(", ")
          detail = phase_str && !phase_str.empty? ? " (#{phase_str})" : ""
          @out.puts("  #{entry[:path]}: #{format('%.1f', entry[:total_ms])}ms#{detail}")
        end
        total = sorted.sum { |fp| fp[:total_ms] }
        @out.puts("Total: #{format('%.1f', total)}ms")
      end
    end
  end
end
