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
      @include_module_roots = []
      @include_path_flags = []
      @ambient_module_roots = MilkTea::ModuleRoots.roots_for_path(Dir.pwd)
    end

    def start
      extract_include_paths!
      command = @argv.shift

      if command && @include_module_roots.any? && !command_supports_include_paths?(command)
        @err.puts("unknown option #{@include_path_flags.first} for #{command}")
        print_usage(@err)
        return 1
      end

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
      when "toolchain"
        toolchain_command
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

      resolution = extract_resolution_flags!
      ensure_current_lockfile!(path) if resolution[:frozen]

      require "json"

      payload = MilkTea::LSP::Server.semantic_tokens_for_path(path, module_roots: module_roots_for(path, locked: resolution[:locked]))
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

      resolution = extract_resolution_flags!
      ensure_current_lockfile!(path) if resolution[:frozen]

      ast = make_module_loader(path, locked: resolution[:locked]).load_file(path)
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

      resolution = { locked: false, frozen: false }
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
        when "--locked"
          resolution[:locked] = true
        when "--frozen"
          resolution[:locked] = true
          resolution[:frozen] = true
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

      ensure_current_lockfiles!(paths) if resolution[:frozen]

      if fix
        paths.each do |p|
          source = read_source_file(p)
          fixed = Linter.fix_source(source, path: p, sema_analysis: lint_sema_analysis_for(source, p, locked: resolution[:locked]))
          if fixed != source
            File.write(p, fixed)
            @out.puts("fixed #{p}")
          end
        end
        return 0
      end

      all_warnings = paths.flat_map do |p|
        source = read_source_file(p)
        analysis = lint_sema_analysis_for(source, p, locked: resolution[:locked])

        Linter.lint_source(source, path: p, select:, ignore:, sema_analysis: analysis)
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

      resolution = extract_resolution_flags!
      ensure_current_lockfile!(path) if resolution[:frozen]

      result = make_module_loader(path, locked: resolution[:locked]).check_file(path)
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

      resolution = extract_resolution_flags!
      ensure_current_lockfile!(path) if resolution[:frozen]

      program = make_module_loader(path, locked: resolution[:locked]).check_program(path)
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

      resolution = extract_resolution_flags!
      ensure_current_lockfile!(path) if resolution[:frozen]

      program = make_module_loader(path, locked: resolution[:locked]).check_program(path)
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

      ensure_current_lockfile!(path) if options.delete(:frozen)
      locked = options.delete(:locked)
      package_graph = package_graph_for(path, locked:)
      result = Build.build(path, module_roots: module_roots_for(path, locked:), package_graph:, **options)
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

      ensure_current_lockfile!(path) if options.delete(:frozen)
      locked = options.delete(:locked)
      package_graph = package_graph_for(path, locked:)
      preview_notice_emitted = false
      result = Run.run(
        path,
        module_roots: module_roots_for(path, locked:),
        package_graph:,
        preview_started: lambda do |message|
          preview_notice_emitted = true
          @out.write(message)
          @out.flush if @out.respond_to?(:flush)
        end,
        **options
      )
      @out.write(result.stdout) unless preview_notice_emitted
      @err.write(result.stderr)
      result.exit_status
    end

    def deps_command
      PackageManagerCLI.start(
        @argv,
        out: @out,
        err: @err,
        help_printer: method(:print_deps_help),
        services: package_services,
      )
    end

    def toolchain_command
      ToolchainCLI.start(
        @argv,
        out: @out,
        err: @err,
        help_printer: method(:print_toolchain_help),
      )
    end

    def dap_command
      DAP::Server.new.run
      0
    end

    def bindgen_command
      BindgenCLI.start(@argv, out: @out, err: @err, help_printer: method(:print_bindgen_help))
    end

    def parse_build_options(allow_clean: false)
      options = {
        output_path: nil,
        cc: ENV.fetch("CC", "cc"),
        keep_c_path: nil,
        profile: nil,
        platform: nil,
        locked: false,
        frozen: false,
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
        when "--locked"
          options[:locked] = true
        when "--frozen"
          options[:locked] = true
          options[:frozen] = true
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

    def missing_option_value(option)
      @err.puts("missing value for #{option}")
      print_usage(@err)
      nil
    end

    def handled_cli_error?(error)
      handled_error_classes.any? { |klass| error.is_a?(klass) }
    end

    def handled_error_classes
      classes = [LexError, ParseError, ModuleLoadError, SemaError, LoweringError, BuildError, RunError, FormatterError, PackageManifestError, PackageManifestEditorError, PackageGraphError, PackageLockError, PackageSourceResolverError, PackageSourceFetcherError, PackageRegistryStoreError, PackageRegistryMetadataProviderError, PackageDependencySolverError, PackageVersionError]
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

    def make_module_loader(path = nil, locked: false)
      ModuleLoader.new(module_roots: module_roots_for(path, locked:), package_graph: package_graph_for(path, locked:))
    end

    def module_roots_for(path = nil, locked: false)
      roots = @include_module_roots.dup

      if path
        MilkTea::ModuleRoots.roots_for_path(path, locked:).each do |root|
          roots << root unless roots.include?(root)
        end
      end

      @ambient_module_roots.each do |root|
        roots << root unless roots.include?(root)
      end
      roots
    end

    def package_graph_for(path = nil, locked: false)
      return nil unless locked && path

      PackageGraph.load(path, locked: true)
    end

    def package_services
      @package_services ||= PackageServices.new
    end

    def extract_resolution_flags!
      locked = false
      frozen = false
      remaining = []

      @argv.each do |arg|
        if arg == "--locked"
          locked = true
        elsif arg == "--frozen"
          locked = true
          frozen = true
        else
          remaining << arg
        end
      end

      @argv = remaining
      { locked:, frozen: }
    end

    def ensure_current_lockfile!(path)
      result = PackageLock.check(path, source_resolver: package_services.source_resolver(:cache))
      return if result.current?

      message = if result.missing?
                  "package.lock is missing: #{result.lock_path}"
                else
                  "package.lock is out of date: #{result.lock_path}"
                end
      raise PackageLockError, message
    end

    def ensure_current_lockfiles!(paths)
      checked = {}

      paths.each do |path|
        result = PackageLock.check(path, source_resolver: package_services.source_resolver(:cache))
        next if checked[result.lock_path]

        checked[result.lock_path] = true
        next if result.current?

        message = if result.missing?
                    "package.lock is missing: #{result.lock_path}"
                  else
                    "package.lock is out of date: #{result.lock_path}"
                  end
        raise PackageLockError, message
      end
    end

    def lint_sema_analysis_for(source, path, locked: false)
      ast = Parser.parse(source, path: path)
      imported_modules = make_module_loader(path, locked:).imported_modules_for_ast(ast, importer_path: path)
      Sema.check_collecting_errors(ast, imported_modules: imported_modules)[:analysis]
    rescue MilkTea::LexError, MilkTea::ParseError, SemaError, ModuleLoadError
      nil
    end

    def extract_include_paths!
      remaining = []
      i = 0
      while i < @argv.length
        if @argv[i] == "-I" || @argv[i] == "--include-path"
          value = @argv[i + 1]
          if value && !value.start_with?("-")
            @include_path_flags << @argv[i]
            @include_module_roots << File.expand_path(value)
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

    def command_supports_include_paths?(command)
      %w[semantic-tokens parse lint check lower emit-c build run].include?(command)
    end

    COMMAND_HELP = {
      "lex"             => "Usage: mtc lex PATH\n\n  Tokenize a source file and print the token stream.",
      "semantic-tokens" => "Usage: mtc semantic-tokens PATH [--locked] [--frozen] [-I PATH]\n\n  Emit LSP-style semantic token data for a source file as JSON.",
      "parse"           => "Usage: mtc parse PATH [--locked] [--frozen] [-I PATH]\n\n  Parse a source file and print the AST.",
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
          Some rules and auto-fixes are semantic/import-aware, so lint can use
          the same dependency resolution mode as check/build.

          Options:
            --select RULES          Comma-separated list of rule codes to enable.
            --ignore RULES          Comma-separated list of rule codes to suppress.
            --fix                   Apply auto-fixable changes in place.
            --output-format FORMAT  Output format: text (default) or json.
            --locked                Use package.lock for semantic dependency resolution.
            --frozen                Require a current package.lock before semantic dependency resolution.
            -I, --include-path PATH Add an extra module root for semantic resolution.
        HELP
      "check"           => "Usage: mtc check PATH [--locked] [--frozen] [-I PATH]\n\n  Run semantic analysis on a source file and report errors.",
      "lower"           => "Usage: mtc lower PATH [--locked] [--frozen] [-I PATH]\n\n  Lower a source file to IR and print it.",
      "emit-c"          => "Usage: mtc emit-c PATH [--locked] [--frozen] [-I PATH]\n\n  Compile a source file to C and print the output.",
      "build"           => <<~HELP,
        Usage: mtc build [PATH_OR_PACKAGE] [OPTIONS]

          Compile a source file or package. Defaults to current directory if a
          package.toml is present.

          Options:
            -o, --output OUTPUT          Output path for the compiled artifact.
            --cc COMPILER                C compiler to use (default: $CC or cc).
            --keep-c C_PATH              Write the generated C source to this path.
            --profile PROFILE            debug (default) | release.
            --platform PLATFORM          linux (default) | windows | wasm.
            --locked                     Resolve dependencies from package.lock.
            --frozen                     Require a current package.lock and use locked resolution.
            --clean                      Remove existing build outputs and exit.
            -I, --include-path PATH      Add an extra module root.
        HELP
      "run"             => <<~HELP,
        Usage: mtc run [PATH_OR_PACKAGE] [OPTIONS]

          Build and execute an executable target. For wasm targets this starts a
          local preview server, opens the generated HTML in your browser, and
          keeps serving until you press Ctrl-C.
          Defaults to current directory if a package.toml is present.

          Options:
            -o, --output OUTPUT          Output path for the compiled binary.
            --cc COMPILER                C compiler to use (default: $CC or cc).
            --keep-c C_PATH              Write the generated C source to this path.
            --profile PROFILE            debug (default) | release.
            --platform PLATFORM          linux (default) | windows | wasm.
            --locked                     Resolve dependencies from package.lock.
            --frozen                     Require a current package.lock and use locked resolution.
            -I, --include-path PATH      Add an extra module root.
        HELP
      "dap"             => "Usage: mtc dap\n\n  Start the Debug Adapter Protocol server (stdio).",
      "toolchain"       => <<~HELP,
        Usage: mtc toolchain SUBCOMMAND

          Manage the local native toolchain and upstream native library checkouts.

          Subcommands:
            bootstrap    Download and prepare all upstream native libraries.
            doctor       Check that all required tools and libraries are available.
        HELP
      "deps"            => <<~HELP,
        Usage: mtc deps SUBCOMMAND

          Manage package dependencies and package.lock state.

          Subcommands:
            add          Add or update a package dependency and refresh package.lock.
            remove       Remove a package dependency and refresh package.lock.
            update       Re-resolve dependencies and refresh package.lock.
            tree         Print the package dependency tree for a local package.
            lock         Write or verify a deterministic package.lock for a local package.
            publish      Publish an exact-version package into the local or configured upstream registry store.
            fetch        Materialize cache-backed sources from package.lock explicitly.
        HELP
      "bindgen"         => <<~HELP,
        Usage: mtc bindgen MODULE HEADER [OPTIONS]

          Generate a Milk Tea binding module from a C header.

          Options:
            -o, --output OUTPUT    Write the generated module to this file.
            --nullable-report PATH Write the remaining manual nullable policy report to this file.
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

    def print_toolchain_help(io)
      print_command_help("toolchain", io)
    end

    def print_deps_help(io)
      print_command_help("deps", io)
    end

    def print_bindgen_help(io)
      print_command_help("bindgen", io)
    end

    def print_usage(io)
      io.puts("Usage: mtc lex PATH")
      io.puts("       mtc semantic-tokens PATH [--locked] [--frozen] [-I PATH]")
      io.puts("       mtc parse PATH [--locked] [--frozen] [-I PATH]")
      io.puts("       mtc fmt PATH|DIR [--check|--write] [--safe|--canonical|--preserve]")
      io.puts("       mtc lint PATH|DIR [--select RULES] [--ignore RULES] [--fix] [--output-format text|json] [--locked] [--frozen] [-I PATH]")
      io.puts("       mtc check PATH [--locked] [--frozen] [-I PATH]")
      io.puts("       mtc lower PATH [--locked] [--frozen] [-I PATH]")
      io.puts("       mtc emit-c PATH [--locked] [--frozen] [-I PATH]")
      io.puts("       mtc build [PATH_OR_PACKAGE] [-o OUTPUT] [--cc COMPILER] [--keep-c C_PATH] [--profile debug|release] [--platform linux|windows|wasm] [--locked] [--frozen] [--clean] [-I PATH]")
      io.puts("       mtc run [PATH_OR_PACKAGE] [-o OUTPUT] [--cc COMPILER] [--keep-c C_PATH] [--profile debug|release] [--platform linux|windows|wasm] [--locked] [--frozen] [-I PATH]")
      io.puts("       mtc dap")
      io.puts("       mtc toolchain bootstrap")
      io.puts("       mtc toolchain doctor")
      io.puts("       mtc deps add [PATH_OR_PACKAGE] NAME[@VERSION_REQ] [--path PATH] [--git URL --rev REV [--subdir DIR]] [--version VERSION_REQ]")
      io.puts("       mtc deps remove [PATH_OR_PACKAGE] NAME")
      io.puts("       mtc deps update [PATH_OR_PACKAGE]")
      io.puts("       mtc deps tree [PATH_OR_PACKAGE]")
      io.puts("       mtc deps lock [PATH_OR_PACKAGE] [--check]")
      io.puts("       mtc deps publish [PATH_OR_PACKAGE] [--upstream]")
      io.puts("       mtc deps fetch [PATH_OR_PACKAGE]")
      io.puts("       mtc bindgen MODULE HEADER [-o OUTPUT] [--nullable-report PATH] [--link LIB] [--include HEADER] [--clang PATH] [--clang-arg ARG]")
    end
  end
end
