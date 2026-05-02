# frozen_string_literal: true

require "pp"

module MilkTea
  class CLI
    def self.start(argv = ARGV, out: $stdout, err: $stderr)
      new(argv, out:, err:).start
    end

    def initialize(argv, out:, err:)
      @argv = argv.dup
      @out = out
      @err = err
      @module_roots = [MilkTea.root]
    end

    def start
      extract_include_paths!
      command = @argv.shift

      case command
      when "lex"
        lex_command
      when "parse"
        parse_command
      when "fmt"
        fmt_command
      when "lint"
        lint_command
      when "check"
        check_command
      when "lower"
        lower_command
      when "emit-c"
        emit_c_command
      when "build"
        build_command
      when "run"
        run_command
      when "dap"
        dap_command
      when "deps"
        deps_command
      when "bindgen"
        bindgen_command
      else
        print_usage(@err)
        1
      end
    rescue StandardError => e
      raise unless handled_cli_error?(e)

      @err.puts(e.message)
      1
    end

    private

    def lex_command
      path = @argv.shift
      unless path
        @err.puts("missing source file path")
        print_usage(@err)
        return 1
      end

      tokens = Lexer.lex(read_source_file(path), path: path)
      @out.write(PP.pp(tokens, +""))
      0
    end

    def parse_command
      path = @argv.shift
      unless path
        @err.puts("missing source file path")
        print_usage(@err)
        return 1
      end

      ast = make_module_loader.load_file(path)
      @out.write(PrettyPrinter.format_ast(ast))
      0
    end

    def fmt_command
      path = @argv.shift
      unless path
        @err.puts("missing source file path")
        print_usage(@err)
        return 1
      end

      options = parse_fmt_options
      return 1 unless options

      if File.directory?(path)
        return fmt_directory(path, options)
      end

      source = read_source_file(path)
      result = Formatter.check_source(source, path: path, mode: options[:mode])

      if options[:check]
        if result.changed
          @out.puts("needs formatting #{path}")
          return 1
        end

        @out.puts("already formatted #{path}")
        return 0
      end

      if options[:write]
        if result.changed
          File.write(path, result.formatted_source)
          @out.puts("formatted #{path}")
        else
          @out.puts("already formatted #{path}")
        end
        return 0
      end

      @out.write(result.formatted_source)
      0
    end

    def fmt_directory(dir, options)
      paths = Dir.glob(File.join(dir, "**/*.mt")).sort
      if paths.empty?
        @out.puts("no .mt files found in #{dir}")
        return 0
      end

      unless options[:check] || options[:write]
        @err.puts("fmt on a directory requires --check or --write")
        print_usage(@err)
        return 1
      end

      if options[:check]
        needs_fmt = []
        paths.each do |p|
          result = Formatter.check_source(read_source_file(p), path: p, mode: options[:mode])
          needs_fmt << p if result.changed
        end
        if needs_fmt.empty?
          @out.puts("all #{paths.size} file(s) already formatted")
          return 0
        end
        needs_fmt.each { |p| @out.puts("needs formatting #{p}") }
        @out.puts("#{needs_fmt.size} file(s) need formatting")
        return 1
      end

      # --write
      changed = 0
      paths.each do |p|
        result = Formatter.check_source(read_source_file(p), path: p, mode: options[:mode])
        if result.changed
          File.write(p, result.formatted_source)
          @out.puts("formatted #{p}")
          changed += 1
        end
      end
      @out.puts("formatted #{changed} of #{paths.size} file(s)")
      0
    end

    def lint_command
      path = @argv.shift
      unless path
        @err.puts("missing source file path")
        print_usage(@err)
        return 1
      end

      select = nil
      ignore = nil
      fix = false
      output_format = :text
      while @argv.first&.start_with?("--")
        flag = @argv.shift
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
        when "--output-format"
          fmt_arg = @argv.shift
          unless fmt_arg
            @err.puts("--output-format requires an argument (text, json)")
            return 1
          end
          case fmt_arg
          when "text" then output_format = :text
          when "json" then output_format = :json
          else
            @err.puts("unknown output format: #{fmt_arg} (use text or json)")
            return 1
          end
        else
          @err.puts("unknown lint flag: #{flag}")
          return 1
        end
      end

      paths = if File.directory?(path)
                Dir.glob(File.join(path, "**/*.mt")).sort
              else
                [path]
              end

      if paths.empty?
        @out.puts("no .mt files found in #{path}")
        return 0
      end

      if fix
        paths.each do |p|
          source = read_source_file(p)
          fixed = Linter.fix_source(source, path: p)
          if fixed != source
            File.write(p, fixed)
            @out.puts("fixed #{p}")
          end
        end
        return 0
      end

      all_warnings = paths.flat_map do |p|
        Linter.lint_source(read_source_file(p), path: p, select:, ignore:)
      end

      if output_format == :json
        require "json"
        @out.puts(JSON.dump(all_warnings.map do |w|
          { path: w.path, line: w.line, code: w.code, message: w.message, severity: w.severity }
        end))
        return all_warnings.empty? ? 0 : 1
      end

      if all_warnings.empty?
        @out.puts("clean #{path}")
        return 0
      end

      all_warnings.each do |warning|
        @out.puts("#{warning.path}:#{warning.line}: #{warning.code}: #{warning.message}")
      end

      file_count = all_warnings.map(&:path).uniq.size
      noun = all_warnings.size == 1 ? "warning" : "warnings"
      files_str = file_count == 1 ? "1 file" : "#{file_count} files"
      @out.puts("Found #{all_warnings.size} #{noun} in #{files_str}.")
      1
    end

    def check_command
      path = @argv.shift
      unless path
        @err.puts("missing source file path")
        print_usage(@err)
        return 1
      end

      result = make_module_loader.check_file(path)
      module_name = result.module_name || "(anonymous)"
      @out.puts("checked #{path} as #{module_name}")
      0
    end

    def lower_command
      path = @argv.shift
      unless path
        @err.puts("missing source file path")
        print_usage(@err)
        return 1
      end

      program = make_module_loader.check_program(path)
      @out.write(PrettyPrinter.format_ir(Lowering.lower(program)))
      0
    end

    def emit_c_command
      path = @argv.shift
      unless path
        @err.puts("missing source file path")
        print_usage(@err)
        return 1
      end

      program = make_module_loader.check_program(path)
      @out.write(Codegen.generate_c(program))
      0
    end

    def build_command
      path = @argv.shift
      unless path
        @err.puts("missing source file path")
        print_usage(@err)
        return 1
      end

      options = parse_build_options
      return 1 unless options

      result = Build.build(path, module_roots: @module_roots, **options)
      @out.puts("built #{path} -> #{result.output_path}")
      @out.puts("saved C to #{result.c_path}") if result.c_path
      0
    end

    def run_command
      path = @argv.shift
      unless path
        @err.puts("missing source file path")
        print_usage(@err)
        return 1
      end

      options = parse_build_options
      return 1 unless options

      result = Run.run(path, module_roots: @module_roots, **options)
      @out.write(result.stdout)
      @err.write(result.stderr)
      result.exit_status
    end

    def deps_command
      subcommand = @argv.shift

      unless subcommand
        @err.puts("missing deps subcommand")
        print_usage(@err)
        return 1
      end

      case subcommand
      when "bootstrap"
        if @argv.any?
          @err.puts("unknown deps option #{@argv.first}")
          print_usage(@err)
          return 1
        end

        require_relative "../bindings"

        results = UpstreamSources.bootstrap_all!
        results.each do |result|
          verb = result.status == :present ? "kept" : "bootstrapped"
          @out.puts("#{verb} #{result.source.name} -> #{result.path}")
        end
        0
      else
        @err.puts("unknown deps subcommand #{subcommand}")
        print_usage(@err)
        1
      end
    end

    def dap_command
      DAP::Server.new.run
      0
    end

    def bindgen_command
      module_name = @argv.shift
      header_path = @argv.shift
      unless module_name && header_path
        @err.puts("missing module name or header path")
        print_usage(@err)
        return 1
      end

      require_relative "../bindings"

      options = parse_bindgen_options
      return 1 unless options

      output_path = options.delete(:output_path)
      source = Bindgen.generate(module_name:, header_path:, **options)
      if output_path
        FileUtils.mkdir_p(File.dirname(File.expand_path(output_path)))
        File.write(output_path, source)
        @out.puts("generated #{header_path} -> #{output_path}")
      else
        @out.write(source)
      end
      0
    end

    def parse_build_options
      options = {
        output_path: nil,
        cc: ENV.fetch("CC", "cc"),
        keep_c_path: nil,
      }

      until @argv.empty?
        option = @argv.shift
        case option
        when "-o", "--output"
          value = @argv.shift
          return missing_option_value(option) unless value

          options[:output_path] = value
        when "--cc"
          value = @argv.shift
          return missing_option_value(option) unless value

          options[:cc] = value
        when "--keep-c"
          value = @argv.shift
          return missing_option_value(option) unless value

          options[:keep_c_path] = value
        else
          @err.puts("unknown build option #{option}")
          print_usage(@err)
          return nil
        end
      end

      options
    end

    def parse_fmt_options
      options = {
        check: false,
        write: false,
        mode: :safe,
      }

      until @argv.empty?
        option = @argv.shift
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
        else
          @err.puts("unknown fmt option #{option}")
          print_usage(@err)
          return nil
        end
      end

      if options[:check] && options[:write]
        @err.puts("fmt options --check and --write cannot be combined")
        print_usage(@err)
        return nil
      end

      options
    end

    def parse_bindgen_options
      options = {
        output_path: nil,
        link_libraries: [],
        include_directives: [],
        clang: ENV.fetch("CLANG", "clang"),
        clang_args: [],
      }

      until @argv.empty?
        option = @argv.shift
        case option
        when "-o", "--output"
          value = @argv.shift
          return missing_option_value(option) unless value

          options[:output_path] = value
        when "--link"
          value = @argv.shift
          return missing_option_value(option) unless value

          options[:link_libraries] << value
        when "--include"
          value = @argv.shift
          return missing_option_value(option) unless value

          options[:include_directives] << value
        when "--clang"
          value = @argv.shift
          return missing_option_value(option) unless value

          options[:clang] = value
        when "--clang-arg"
          value = @argv.shift
          return missing_option_value(option) unless value

          options[:clang_args] << value
        else
          @err.puts("unknown bindgen option #{option}")
          print_usage(@err)
          return nil
        end
      end

      options[:include_directives] = nil if options[:include_directives].empty?
      options
    end

    def missing_option_value(option)
      @err.puts("missing value for #{option}")
      print_usage(@err)
      nil
    end

    def handled_cli_error?(error)
      handled_error_classes.any? { |klass| error.is_a?(klass) }
    end

    def handled_error_classes
      classes = [LexError, ParseError, ModuleLoadError, SemaError, LoweringError, BuildError, RunError, FormatterError]
      classes << BindgenError if MilkTea.const_defined?(:BindgenError, false)
      classes << UpstreamSources::Error if MilkTea.const_defined?(:UpstreamSources, false)
      classes
    end

    def read_source_file(path)
      File.read(path)
    rescue Errno::ENOENT
      raise ModuleLoadError.new("source file not found", path: path)
    rescue Errno::EISDIR
      raise ModuleLoadError.new("expected a source file, got a directory", path: path)
    end

    def make_module_loader
      ModuleLoader.new(module_roots: @module_roots)
    end

    def extract_include_paths!
      remaining = []
      i = 0
      while i < @argv.length
        if @argv[i] == "-I" || @argv[i] == "--include-path"
          value = @argv[i + 1]
          if value && !value.start_with?("-")
            @module_roots << File.expand_path(value)
            i += 2
          else
            @err.puts("missing value for #{@argv[i]}")
            i += 1
          end
        else
          remaining << @argv[i]
          i += 1
        end
      end
      @argv = remaining
    end

    def print_usage(io)
      io.puts("Usage: mtc lex PATH")
      io.puts("       mtc parse PATH")
      io.puts("       mtc fmt PATH|DIR [--check|--write] [--safe|--canonical|--preserve]")
      io.puts("       mtc lint PATH|DIR [--select RULES] [--ignore RULES] [--fix] [--output-format text|json]")
      io.puts("       mtc check PATH")
      io.puts("       mtc lower PATH")
      io.puts("       mtc emit-c PATH")
      io.puts("       mtc build PATH [-o OUTPUT] [--cc COMPILER] [--keep-c C_PATH] [-I PATH]")
      io.puts("       mtc run PATH [-o OUTPUT] [--cc COMPILER] [--keep-c C_PATH] [-I PATH]")
      io.puts("       mtc dap")
      io.puts("       mtc deps bootstrap")
      io.puts("       mtc bindgen MODULE HEADER [-o OUTPUT] [--link LIB] [--include HEADER] [--clang PATH] [--clang-arg ARG]")
    end
  end
end
