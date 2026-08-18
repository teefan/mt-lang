# frozen_string_literal: true

module MilkTea
  class CLI
    module CommandTest
      TEST_RUN_TIMEOUT_SECONDS = 30
      TEST_RUN_MEMORY_LIMIT_BYTES = 1024 * 1024 * 1024

      TestResult = Data.define(:name, :status, :detail)

      def test_command
        limits = extract_test_limit_flags!
        return 1 unless limits

        @test_timeout_seconds, @test_memory_bytes, @test_jobs, @test_sanitize, @test_filter, @test_format = limits

        path, options = extract_path_and_options
        return 1 unless path

        frozen = options.delete(:frozen)
        ensure_current_lockfile!(path) if frozen
        locked = options.delete(:locked)

        return dispatch_test_run(path, options:, locked:) if @test_format == :human

        buffer = StringIO.new
        real_out = @out
        real_err = @err
        @out = buffer
        @err = buffer
        begin
          exit_code = dispatch_test_run(path, options:, locked:)
        ensure
          @out = real_out
          @err = real_err
        end

        emit_machine_results(parse_test_output(buffer.string), @test_format, real_out)
        exit_code
      end

      def dispatch_test_run(path, options:, locked:)
        if File.directory?(path)
          run_test_directory(path, options:, locked:)
        elsif File.file?(path)
          if compile_fail_fixture?(File.read(path))
            run_compile_fail_test(path) ? 0 : 1
          else
            run_test_file(path, options:, locked:)
          end
        else
          @err.puts("mtc test: not a file or directory: #{path}")
          1
        end
      end

      def extract_test_limit_flags!
        timeout_seconds = TEST_RUN_TIMEOUT_SECONDS
        memory_bytes = TEST_RUN_MEMORY_LIMIT_BYTES
        jobs = 1
        sanitize = false
        filter = nil
        format = :human
        remaining = []
        until @argv.empty?
          arg = @argv.shift
          case arg
          when "--timeout"
            value = @argv.shift
            seconds = value && Integer(value, exception: false)
            unless seconds&.positive?
              @err.puts("--timeout requires a positive integer (seconds)")
              return nil
            end
            timeout_seconds = seconds
          when "--mem"
            value = @argv.shift
            megabytes = value && Integer(value, exception: false)
            unless megabytes&.positive?
              @err.puts("--mem requires a positive integer (megabytes)")
              return nil
            end
            memory_bytes = megabytes * 1024 * 1024
          when "--jobs"
            value = @argv.shift
            count = value && Integer(value, exception: false)
            unless count&.positive?
              @err.puts("--jobs requires a positive integer")
              return nil
            end
            jobs = count
          when "--sanitize"
            sanitize = true
          when "-n", "--name"
            value = @argv.shift
            unless value
              @err.puts("-n requires a name substring")
              return nil
            end
            filter = value
          when "--format"
            value = @argv.shift
            unless %w[human tap junit].include?(value)
              @err.puts("--format must be human, tap, or junit")
              return nil
            end
            format = value.to_sym
          when "--"
            remaining << arg
            remaining.concat(@argv)
            @argv.clear
          else
            remaining << arg
          end
        end
        @argv.replace(remaining)
        [timeout_seconds, memory_bytes, jobs, sanitize, filter, format]
      end

      def parse_test_output(text)
        results = []
        current_file = nil
        text.each_line do |raw|
          line = raw.chomp
          case line
          when /\A# (.+)\z/
            current_file = ::Regexp.last_match(1)
          when /\Aok   - (.+)\z/
            results << TestResult.new(name: ::Regexp.last_match(1), status: :pass, detail: nil)
          when /\Askip - (.+?)(?:: (.*))?\z/
            results << TestResult.new(name: ::Regexp.last_match(1), status: :skip, detail: ::Regexp.last_match(2))
          when /\AFAIL - (.+?)(?:: (.*))?\z/
            results << TestResult.new(name: ::Regexp.last_match(1), status: :fail, detail: ::Regexp.last_match(2))
          when /\AFAILED - (.+?) \(build error\)\z/
            results << TestResult.new(name: "#{::Regexp.last_match(1)} (build error)", status: :fail, detail: "build error")
          when /\Atest run (?:timed out|crashed)/, /\ASUMMARY: \w+Sanitizer/
            results << TestResult.new(name: "#{current_file || 'test'} (#{line})", status: :fail, detail: line)
          end
        end
        results
      end

      def emit_machine_results(results, format, out)
        case format
        when :tap then emit_tap(results, out)
        when :junit then emit_junit(results, out)
        end
      end

      def emit_tap(results, out)
        out.puts("TAP version 13")
        out.puts("1..#{results.length}")
        results.each_with_index do |result, index|
          number = index + 1
          case result.status
          when :pass
            out.puts("ok #{number} - #{result.name}")
          when :skip
            out.puts("ok #{number} - #{result.name} # SKIP#{result.detail ? " #{result.detail}" : ''}")
          when :fail
            out.puts("not ok #{number} - #{result.name}")
            next unless result.detail

            out.puts("  ---")
            out.puts("  message: #{result.detail}")
            out.puts("  ...")
          end
        end
      end

      def emit_junit(results, out)
        failures = results.count { |result| result.status == :fail }
        skipped = results.count { |result| result.status == :skip }
        out.puts(%(<?xml version="1.0" encoding="UTF-8"?>))
        out.puts(%(<testsuites tests="#{results.length}" failures="#{failures}" skipped="#{skipped}">))
        out.puts(%(  <testsuite name="mtc test" tests="#{results.length}" failures="#{failures}" skipped="#{skipped}">))
        results.each do |result|
          name = xml_escape(result.name)
          case result.status
          when :pass
            out.puts(%(    <testcase name="#{name}"/>))
          when :skip
            out.puts(%(    <testcase name="#{name}"><skipped/></testcase>))
          when :fail
            out.puts(%(    <testcase name="#{name}"><failure message="#{xml_escape(result.detail || 'failed')}"/></testcase>))
          end
        end
        out.puts("  </testsuite>")
        out.puts("</testsuites>")
      end

      def xml_escape(value)
        value.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub('"', "&quot;")
      end

      def run_test_directory(directory, options:, locked:)
        test_files = discover_test_files(directory)
        if test_files.empty?
          if @test_filter
            @out.puts("no tests matched -n '#{@test_filter}' under #{directory}")
          else
            @out.puts("no @[test] functions or # expect-error: fixtures found under #{directory}")
          end
          return 0
        end

        jobs = @test_jobs || 1
        return run_test_files_parallel(test_files, jobs:, options:, locked:) if jobs > 1 && Process.respond_to?(:fork)

        failed = 0
        test_files.each do |file, kind|
          @out.puts("# #{file}")
          @out.flush if @out.respond_to?(:flush)
          failed += 1 unless run_classified_file(file, kind, options:, locked:).zero?
        end

        @out.puts("")
        @out.puts("#{test_files.length} test file(s), #{failed} failed")
        failed.zero? ? 0 : 1
      end

      def run_classified_file(file, kind, options:, locked:)
        if kind == :compile_fail
          run_compile_fail_test(file) ? 0 : 1
        else
          run_test_file_guarded(file, options:, locked:)
        end
      end

      def run_compile_fail_test(path)
        source = File.read(path)
        expectations = extract_expect_error_directives(source)
        messages = compile_fail_diagnostics(path)

        if messages.empty?
          @out.puts("FAIL - #{path} (compile-fail): expected a compile error, but it compiled cleanly")
          @out.flush if @out.respond_to?(:flush)
          return false
        end

        unmatched = expectations.find { |expected| messages.none? { |message| message.include?(expected) } }
        if unmatched
          @out.puts("FAIL - #{path} (compile-fail): no diagnostic matched #{unmatched.inspect}")
          @out.flush if @out.respond_to?(:flush)
          return false
        end

        @out.puts("ok   - #{path} (compile-fail)")
        @out.flush if @out.respond_to?(:flush)
        true
      end

      def extract_expect_error_directives(source)
        source.each_line.filter_map do |line|
          match = line.match(/^\s*#\s*expect-error:\s*(.+?)\s*$/)
          match && match[1]
        end
      end

      def compile_fail_diagnostics(path)
        errors, = check_single_reporting_all(path, locked: false)
        errors
          .select { |diagnostic| !diagnostic.respond_to?(:severity) || diagnostic.severity == :error }
          .map { |diagnostic| ErrorFormatter.format(diagnostic, color: false) }
      rescue StandardError => e
        raise unless known_cli_error?(e)

        [ErrorFormatter.format(e, color: false)]
      end

      def run_test_file_guarded(file, options:, locked:)
        run_test_file(file, options:, locked:)
      rescue StandardError => e
        raise unless known_cli_error?(e)

        @err.puts("FAILED - #{file} (build error)")
        @err.puts(ErrorFormatter.format(e, color: use_color?(@err)))
        1
      end

      def run_test_files_parallel(test_files, jobs:, options:, locked:)
        results = Array.new(test_files.length)
        result_paths = {}
        active = {}
        cursor = 0

        while cursor < test_files.length || !active.empty?
          while active.size < jobs && cursor < test_files.length
            index = cursor
            cursor += 1
            result_path = File.join(Dir.tmpdir, "mttest_result_#{Process.pid}_#{index}")
            result_paths[index] = result_path
            pid = fork do
              captured = StringIO.new
              @out = captured
              @err = captured
              file, kind = test_files[index]
              code = run_classified_file(file, kind, options:, locked:)
              File.binwrite(result_path, [code].pack("N") + captured.string)
              exit!(0)
            end
            active[pid] = index
          end

          finished_pid, = Process.wait2
          index = active.delete(finished_pid)
          next unless index

          path = result_paths[index]
          data = begin
            File.binread(path)
          rescue StandardError
            (+"").b
          end
          File.delete(path) if File.exist?(path)
          results[index] =
            if data.bytesize >= 4
              [data[0, 4].unpack1("N"), data.byteslice(4..).force_encoding(Encoding::UTF_8)]
            else
              [1, +""]
            end
        end

        failed = 0
        test_files.each_with_index do |(file, _kind), index|
          code, output = results[index]
          @out.puts("# #{file}")
          @out.write(output.to_s)
          failed += 1 unless code&.zero?
        end
        @out.flush if @out.respond_to?(:flush)
        @out.puts("")
        @out.puts("#{test_files.length} test file(s), #{failed} failed")
        failed.zero? ? 0 : 1
      end

      def discover_test_files(directory)
        Dir.glob(File.join(directory, "**", "*.mt")).sort.filter_map do |file|
          next if File.basename(file).start_with?("__mt_test_runner_")

          kind = classify_test_file(file)
          kind && [file, kind]
        end
      end

      def classify_test_file(file)
        source = File.read(file)
        if compile_fail_fixture?(source)
          return nil if @test_filter && !File.basename(file, ".mt").include?(@test_filter)

          return :compile_fail
        end

        ast = begin
          MilkTea::Parser.parse(source, path: file)
        rescue ParseError
          return nil
        end
        has_match = ast.declarations.any? do |decl|
          decl.is_a?(AST::FunctionDef) && test_attribute?(decl) && matches_filter?(decl.name)
        end
        has_match ? :test : nil
      end

      def compile_fail_fixture?(source)
        source.match?(/^\s*#\s*expect-error:/)
      end

      def test_attribute?(decl)
        decl.attributes.any? { |attribute| attribute.name.parts == ["test"] }
      end

      def matches_filter?(name)
        @test_filter.nil? || name.include?(@test_filter)
      end

      def run_test_file(path, options:, locked:)
        source = File.read(path)
        ast = MilkTea::Parser.parse(source, path:)

        if ast.declarations.any? { |decl| decl.is_a?(AST::FunctionDef) && decl.name == "main" }
          @err.puts("a test file must not define 'main': #{path}")
          return 1
        end

        tests = ast.declarations.select { |decl| decl.is_a?(AST::FunctionDef) && test_attribute?(decl) }

        if tests.empty?
          @out.puts("no @[test] functions found in #{path}")
          return 0
        end

        tests = tests.select { |test| matches_filter?(test.name) }
        return 0 if tests.empty?

        invalid = tests.find { |test| !test.params.empty? }
        if invalid
          @err.puts("@[test] function '#{invalid.name}' must take no parameters")
          return 1
        end

        death_tests, normal_tests = tests.partition { |test| expect_fatal_attribute?(test) }

        exit_code = 0

        unless normal_tests.empty?
          runner_source = source.dup
          runner_source << "\n\n" << test_runner_main(normal_tests.map(&:name))
          exit_code = run_normal_tests(path, runner_source, normal_tests.map(&:name), options:, locked:)
        end

        death_tests.each do |death_test|
          exit_code = 1 unless run_death_test(path, source, death_test.name, options:, locked:)
        end

        exit_code
      end

      def expect_fatal_attribute?(decl)
        decl.attributes.any? { |attribute| attribute.name.parts == ["expect_fatal"] }
      end

      def run_death_test(source_path, source, test_name, options:, locked:)
        runner_source = source.dup
        runner_source << "\n\n" << death_test_runner_main(test_name)
        classification = with_synthesized_binary(source_path, runner_source, options:, locked:) do |binary_path|
          classify_death_test(binary_path)
        end

        passed = classification == :aborted
        line =
          if passed
            "ok   - #{test_name} (expect_fatal)"
          elsif classification == :timed_out
            "FAIL - #{test_name} (expect_fatal): timed out"
          else
            "FAIL - #{test_name} (expect_fatal): expected a fatal abort, but the test returned"
          end
        @out.puts(line)
        @out.flush if @out.respond_to?(:flush)
        passed
      end

      def classify_death_test(binary_path)
        _output, status, timed_out = spawn_sandboxed(binary_path)
        return :timed_out if timed_out
        return :returned if status&.exited? && status.exitstatus&.zero?

        :aborted
      end

      def death_test_runner_main(test_name)
        [
          "function main() -> int:",
          "    #{test_name}()",
          "    return 0",
        ].join("\n") + "\n"
      end

      # The runner binary runs exactly one test per invocation, selected by
      # `argv[1]`. This gives per-test isolation: an aborting assertion in one
      # test cannot suppress the results of its siblings.
      def test_runner_main(test_names)
        lines = ["function main(args: span[str]) -> int:"]
        lines << "    let which = if args.len > 1: args[1] else: \"\""
        lines << "    match which:"
        test_names.each do |name|
          lines << "        \"#{name}\":"
          lines << "            #{name}()"
        end
        lines << "        _:"
        lines << "            return 2"
        lines << "    return 0"
        lines.join("\n") + "\n"
      end

      def run_normal_tests(source_path, runner_source, test_names, options:, locked:)
        with_synthesized_binary(source_path, runner_source, options:, locked:) do |binary_path|
          exit_code = 0
          test_names.each do |name|
            output, status, timed_out = spawn_sandboxed(binary_path, [name])
            if timed_out
              @out.puts("FAIL - #{name}: timed out")
              exit_code = 1
            elsif status&.exitstatus == 0
              @out.puts("ok   - #{name}")
            else
              @out.puts("FAIL - #{name}: #{first_fail_message(output)}")
              exit_code = 1
            end
            @out.flush if @out.respond_to?(:flush)
          end
          exit_code
        end
      end

      def first_fail_message(output)
        line = output.to_s.lines.map(&:chomp).find { |entry| !entry.strip.empty? }
        line.nil? || line.strip.empty? ? "test aborted" : line.strip
      end

      def with_synthesized_binary(source_path, runner_source, options:, locked:)
        directory = File.dirname(File.expand_path(source_path))
        runner_path = File.join(directory, "__mt_test_runner_#{Process.pid}.mt")
        binary_path = File.join(Dir.tmpdir, "__mt_test_runner_#{Process.pid}")

        File.write(runner_path, runner_source)
        begin
          build_opts = options.except(:timings, :output_path, :bundle, :archive)
          build_opts[:debug_guards] = false
          Build.build(
            runner_path,
            output_path: binary_path,
            module_roots: module_roots_for(source_path, locked:),
            package_graph: package_graph_for(source_path, locked:),
            frontend: @build_frontend,
            sanitize: @test_sanitize,
            **build_opts,
          )
          yield binary_path
        ensure
          File.delete(runner_path) if File.exist?(runner_path)
          File.delete(binary_path) if File.exist?(binary_path)
        end
      end

      def spawn_sandboxed(binary_path, args = [])
        timeout_seconds = @test_timeout_seconds || TEST_RUN_TIMEOUT_SECONDS
        memory_bytes = @test_memory_bytes || TEST_RUN_MEMORY_LIMIT_BYTES
        reader, writer = IO.pipe
        spawn_options = { out: writer, err: writer, pgroup: true }
        spawn_options[:rlimit_as] = memory_bytes unless @test_sanitize
        pid = Process.spawn(binary_path, *args, **spawn_options)
        writer.close

        status = nil
        timed_out = false
        begin
          Timeout.timeout(timeout_seconds) { _, status = Process.wait2(pid) }
        rescue Timeout::Error
          timed_out = true
          begin
            Process.kill("-KILL", Process.getpgid(pid))
            Process.wait(pid)
          rescue StandardError
            nil
          end
        end

        output = reader.read
        reader.close
        [output, status, timed_out]
      end
    end
  end
end
