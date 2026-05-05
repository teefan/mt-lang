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
      @module_roots = MilkTea::ModuleRoots.roots_for_path(Dir.pwd)
    end

    def start
      extract_include_paths!
      command = @argv.shift

      if @argv.first == "--help" || @argv.first == "-h"
        @argv.shift
        print_command_help(command, @out)
        return 0
      end

      case command
      when "lex"
        lex_command
      when "semantic-tokens"
        semantic_tokens_command
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

    def semantic_tokens_command
      path = @argv.shift
      unless path
        @err.puts("missing source file path")
        print_usage(@err)
        return 1
      end

      require "json"

      payload = MilkTea::LSP::Server.semantic_tokens_for_path(path, module_roots: module_roots_for(path))
      @out.puts(JSON.pretty_generate(payload))
      0
    end

    def parse_command
      path = @argv.shift
      unless path
        @err.puts("missing source file path")
        print_usage(@err)
        return 1
      end

      ast = make_module_loader(path).load_file(path)
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

      result = make_module_loader(path).check_file(path)
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

      program = make_module_loader(path).check_program(path)
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

      program = make_module_loader(path).check_program(path)
      @out.write(Codegen.generate_c(program, emit_line_directives: false))
      0
    end

    def build_command
      path = nil
      if @argv.first && !@argv.first.start_with?("-")
        path = @argv.shift
      end

      options = parse_build_options(allow_clean: true)
      return 1 unless options

      unless path
        if File.file?(File.join(Dir.pwd, "package.toml"))
          path = Dir.pwd
        else
          @err.puts("missing source file path")
          print_usage(@err)
          return 1
        end
      end

      if options.delete(:clean)
        cleaned_path = Build.clean(path, output_path: options[:output_path], profile: options[:profile], platform: options[:platform])
        @out.puts("cleaned #{cleaned_path}")
        return 0
      end

      result = Build.build(path, module_roots: module_roots_for(path), **options)
      @out.puts("built #{path} -> #{result.output_path}")
      @out.puts("saved C to #{result.c_path}") if result.c_path
      0
    end

    def run_command
      path = nil
      if @argv.first && !@argv.first.start_with?("-")
        path = @argv.shift
      end

      options = parse_build_options
      return 1 unless options

      unless path
        if File.file?(File.join(Dir.pwd, "package.toml"))
          path = Dir.pwd
        else
          @err.puts("missing source file path")
          print_usage(@err)
          return 1
        end
      end

      result = Run.run(path, module_roots: module_roots_for(path), **options)
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
      when "doctor"
        if @argv.any?
          @err.puts("unknown deps option #{@argv.first}")
          print_usage(@err)
          return 1
        end

        require_relative "../bindings"

        cc = ENV.fetch("CC", "cc")
        ar = ENV.fetch("AR", "ar")
        checks = []

        checks << ["ruby", true, RUBY_DESCRIPTION]
        checks << ["cc", executable_available?(cc), cc]
        checks << ["ar", executable_available?(ar), ar]
        checks << ["bundle", executable_available?("bundle"), "bundle"]

        raylib_ok = false
        raylib_detail = "std.c.raylib binding missing"
        if checks.assoc("cc")[1]
          begin
            registry = RawBindings.default_registry(root: MilkTea.root)
            raylib_binding = registry.find_by_module_name("std.c.raylib")
            if raylib_binding
              raylib_binding.prepare!(cc: cc)
              raylib_ok = true
              raylib_detail = "std.c.raylib prepared"
            end
          rescue RawBindings::Error => e
            raylib_ok = false
            raylib_detail = e.message
          end
        else
          raylib_detail = "skipped (missing C compiler)"
        end
        checks << ["raylib", raylib_ok, raylib_detail]

        checks.each do |name, ok, detail|
          @out.puts("#{ok ? 'ok' : 'fail'} #{name}: #{detail}")
        end

        checks.all? { |_, ok, _| ok } ? 0 : 1
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

    def parse_build_options(allow_clean: false)
      options = {
        output_path: nil,
        cc: ENV.fetch("CC", "cc"),
        keep_c_path: nil,
        profile: nil,
        platform: nil,
      }
      options[:clean] = false if allow_clean

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
        when "--profile"
          value = @argv.shift
          return missing_option_value(option) unless value

          options[:profile] = value
        when "--platform"
          value = @argv.shift
          return missing_option_value(option) unless value

          options[:platform] = value
        when "--clean"
          if allow_clean
            options[:clean] = true
          else
            @err.puts("unknown build option #{option}")
            print_usage(@err)
            return nil
          end
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

    def make_module_loader(path = nil)
      ModuleLoader.new(module_roots: module_roots_for(path))
    end

    def module_roots_for(path = nil)
      roots = @module_roots.dup
      return roots unless path

      MilkTea::ModuleRoots.roots_for_path(path).each do |root|
        roots << root unless roots.include?(root)
      end
      roots
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

    def executable_available?(program)
      return File.executable?(program) if program.include?(File::SEPARATOR)

      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |entry|
        candidate = File.join(entry, program)
        File.file?(candidate) && File.executable?(candidate)
      end
    end

    COMMAND_HELP = {
      "lex"             => "Usage: mtc lex PATH\n\n  Tokenize a source file and print the token stream.",
      "semantic-tokens" => "Usage: mtc semantic-tokens PATH\n\n  Emit LSP-style semantic token data for a source file as JSON.",
      "parse"           => "Usage: mtc parse PATH\n\n  Parse a source file and print the AST.",
      "fmt"             => <<~HELP,
        Usage: mtc fmt PATH|DIR [OPTIONS]

          Format Milk Tea source files.

          Options:
            --check          Report files that need formatting without writing them.
            --write, -w      Rewrite files in place.
            --safe           Format only unambiguous style changes (default).
            --canonical      Apply all canonical style normalisations.
            --preserve       Preserve existing formatting where possible.

          When PATH is a directory, --check or --write is required.
        HELP
      "lint"            => <<~HELP,
        Usage: mtc lint PATH|DIR [OPTIONS]

          Lint Milk Tea source files and report warnings.

          Options:
            --select RULES          Comma-separated list of rule codes to enable.
            --ignore RULES          Comma-separated list of rule codes to suppress.
            --fix                   Apply auto-fixable changes in place.
            --output-format FORMAT  Output format: text (default) or json.
        HELP
      "check"           => "Usage: mtc check PATH\n\n  Run semantic analysis on a source file and report errors.",
      "lower"           => "Usage: mtc lower PATH\n\n  Lower a source file to IR and print it.",
      "emit-c"          => "Usage: mtc emit-c PATH\n\n  Compile a source file to C and print the output.",
      "build"           => <<~HELP,
        Usage: mtc build [PATH_OR_PACKAGE] [OPTIONS]

          Compile a source file or package. Defaults to current directory if a
          package.toml is present.

          Options:
            -o, --output OUTPUT          Output path for the compiled artifact.
            --cc COMPILER                C compiler to use (default: $CC or cc).
            --keep-c C_PATH              Write the generated C source to this path.
            --profile PROFILE            debug (default) | release.
            --platform PLATFORM          linux (default) | windows.
            --clean                      Remove existing build outputs and exit.
            -I PATH                      Add an extra module root.
        HELP
      "run"             => <<~HELP,
        Usage: mtc run [PATH_OR_PACKAGE] [OPTIONS]

          Build and execute an executable target. Defaults to current directory
          if a package.toml is present.

          Options:
            -o, --output OUTPUT          Output path for the compiled binary.
            --cc COMPILER                C compiler to use (default: $CC or cc).
            --keep-c C_PATH              Write the generated C source to this path.
            --profile PROFILE            debug (default) | release.
            --platform PLATFORM          linux (default) | windows.
            -I PATH                      Add an extra module root.
        HELP
      "dap"             => "Usage: mtc dap\n\n  Start the Debug Adapter Protocol server (stdio).",
      "deps"            => <<~HELP,
        Usage: mtc deps SUBCOMMAND

          Manage toolchain dependencies.

          Subcommands:
            bootstrap    Download and prepare all upstream native libraries.
            doctor       Check that all required tools and libraries are available.
        HELP
      "bindgen"         => <<~HELP,
        Usage: mtc bindgen MODULE HEADER [OPTIONS]

          Generate a Milk Tea binding module from a C header.

          Options:
            -o, --output OUTPUT    Write the generated module to this file.
            --link LIB             Link against this library (repeatable).
            --include HEADER       Extra #include directive (repeatable).
            --clang PATH           Clang binary to use (default: $CLANG or clang).
            --clang-arg ARG        Extra argument to pass to clang (repeatable).
        HELP
    }.freeze

    def print_command_help(command, io)
      text = COMMAND_HELP[command]
      if text
        io.puts(text.chomp)
      else
        print_usage(io)
      end
    end

    def print_usage(io)
      io.puts("Usage: mtc lex PATH")
      io.puts("       mtc semantic-tokens PATH")
      io.puts("       mtc parse PATH")
      io.puts("       mtc fmt PATH|DIR [--check|--write] [--safe|--canonical|--preserve]")
      io.puts("       mtc lint PATH|DIR [--select RULES] [--ignore RULES] [--fix] [--output-format text|json]")
      io.puts("       mtc check PATH")
      io.puts("       mtc lower PATH")
      io.puts("       mtc emit-c PATH")
      io.puts("       mtc build [PATH_OR_PACKAGE] [-o OUTPUT] [--cc COMPILER] [--keep-c C_PATH] [--profile debug|release] [--platform linux|windows] [--clean] [-I PATH]")
      io.puts("       mtc run [PATH_OR_PACKAGE] [-o OUTPUT] [--cc COMPILER] [--keep-c C_PATH] [--profile debug|release] [--platform linux|windows] [-I PATH]")
      io.puts("       mtc dap")
      io.puts("       mtc deps bootstrap")
      io.puts("       mtc deps doctor")
      io.puts("       mtc bindgen MODULE HEADER [-o OUTPUT] [--link LIB] [--include HEADER] [--clang PATH] [--clang-arg ARG]")
    end
  end
end
