# frozen_string_literal: true

require "cgi/escape"
require "json"
require "pathname"
require "pp"
require_relative "source_index_tool"

module MilkTea
  class CLI
    CONTRACT_VERSION = 1
    CONTRACT_POSITION_ENCODING = "utf-8"

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
      when "format"
        format_command
      when "lint"
        lint_command
      when "diagnostics"
        diagnostics_command
      when "check"
        check_command
      when "lower"
        lower_command
      when "emit-c"
        emit_c_command
      when "frontend-artifacts"
        frontend_artifacts_command
      when "build"
        build_command
      when "run"
        run_command
      when "new"
        new_command
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

      payload = MilkTea::LSP::Server.semantic_tokens_for_path(
        path,
        module_roots: module_roots_for(path, locked: resolution[:locked]),
        package_graph: package_graph_for(path, locked: resolution[:locked]),
      )
      @out.puts(JSON.pretty_generate(semantic_tokens_contract_payload(payload, source_path: path)))
      0
    end

    def diagnostics_command
      path = @argv.shift
      unless path
        @err.puts("missing source file path")
        print_usage(@err)
        return 1
      end

      resolution = extract_resolution_flags!
      ensure_current_lockfile!(path) if resolution[:frozen]

      source = read_source_file(path)
      payload = diagnostics_contract_payload(path, source, locked: resolution[:locked])
      @out.puts(JSON.pretty_generate(payload))
      payload.fetch(:summary).fetch(:errorCount).positive? ? 1 : 0
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

    def format_command
      path = @argv.shift
      unless path
        @err.puts("missing source file path")
        print_usage(@err)
        return 1
      end

      options = parse_format_options
      return 1 unless options

      if File.directory?(path)
        return format_directory(path, options)
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

    def format_directory(dir, options)
      paths = SourceIndexTool.list_milk_tea_files(root_path: dir)
      if paths.empty?
        @out.puts("no .mt files found in #{dir}")
        return 0
      end

      unless options[:check] || options[:write]
        @err.puts("format on a directory requires --check or --write")
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
      resolution = { locked: false, frozen: false }
      select = nil
      ignore = nil
      fix = false
      output_format = :text
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

      if input_paths.empty?
        @err.puts("missing source file path")
        print_usage(@err)
        return 1
      end

      paths = input_paths.flat_map do |path|
        if File.directory?(path)
          SourceIndexTool.list_milk_tea_files(root_path: path)
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
        paths.each do |p|
          source = read_source_file(p)
          fixed = Linter.fix_source(source, path: p, sema_facts: lint_sema_facts_for(source, p, locked: resolution[:locked]))
          if fixed != source
            File.write(p, fixed)
            @out.puts("fixed #{p}")
          end
        end
        return 0
      end

      all_warnings = paths.flat_map do |p|
        source = read_source_file(p)
        facts = lint_sema_facts_for(source, p, locked: resolution[:locked])

        Linter.lint_source(source, path: p, select:, ignore:, sema_facts: facts)
      end

      if output_format == :json
        require "json"
        @out.puts(JSON.dump(all_warnings.map do |w|
          { path: w.path, line: w.line, code: w.code, message: w.message, severity: w.severity }
        end))
        return all_warnings.empty? ? 0 : 1
      end

      if all_warnings.empty?
        if input_paths.length == 1
          @out.puts("clean #{input_paths.first}")
        else
          @out.puts("clean #{paths.size} file(s)")
        end
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

    def frontend_artifacts_command
      path = @argv.shift
      unless path
        @err.puts("missing source file path")
        print_usage(@err)
        return 1
      end

      options = parse_frontend_artifacts_options
      return 1 unless options
      json_output = options.delete(:json)

      with_contract_error_handling("frontendArtifacts", enabled: json_output, input_path: path) do
        ensure_current_lockfile!(path) if options.delete(:frozen)
        locked = options.delete(:locked)

        artifacts = Build::RubyFrontend.new.compile(
          path:,
          module_roots: module_roots_for(path, locked:),
          package_graph: package_graph_for(path, locked:),
          platform: options.fetch(:platform),
          emit_line_directives: options.fetch(:emit_line_directives),
          binary_path: options.fetch(:binary_path),
        )

        FileUtils.mkdir_p(File.dirname(options.fetch(:compiled_c_path)))
        File.write(options.fetch(:compiled_c_path), artifacts.fetch(:compiled_c))
        FileUtils.mkdir_p(File.dirname(options.fetch(:saved_c_path)))
        File.write(options.fetch(:saved_c_path), artifacts.fetch(:saved_c))

        debug_map = artifacts.fetch(:debug_map)
        raise BuildError, "frontend artifacts require --binary-path to generate a debug map" unless debug_map

        FileUtils.mkdir_p(File.dirname(options.fetch(:debug_map_path)))
        debug_map.write(options.fetch(:debug_map_path))

        if json_output
          @out.puts(JSON.pretty_generate(frontend_artifacts_contract_payload(path, artifacts, options)))
        else
          @out.puts("wrote frontend artifacts for #{path}")
        end
        0
      end
    end

    def build_command
      path = nil
      if @argv.first && !@argv.first.start_with?("-")
        path = @argv.shift
      end

      options = parse_build_options(allow_clean: true)
      return 1 unless options
      json_output = options.delete(:json)

      unless path
        if File.file?(File.join(Dir.pwd, "package.toml"))
          path = Dir.pwd
        else
          @err.puts("missing source file path")
          print_usage(@err)
          return 1
        end
      end

      with_contract_error_handling("buildResult", enabled: json_output, input_path: path) do
        if options.delete(:clean)
          cleaned_path = Build.clean(path, output_path: options[:output_path], profile: options[:profile], platform: options[:platform], bundle: options[:bundle], archive: options[:archive])
          if json_output
            @out.puts(JSON.pretty_generate(build_clean_contract_payload(path, cleaned_path)))
          else
            @out.puts("cleaned #{cleaned_path}")
          end
          return 0
        end

        frozen = options.delete(:frozen)
        ensure_current_lockfile!(path) if frozen
        locked = options.delete(:locked)
        frontend = frontend_from_options(options, locked:, frozen:)
        bundle = options[:bundle]
        package_graph = package_graph_for(path, locked:)
        result = Build.build(path, module_roots: module_roots_for(path, locked:), package_graph:, frontend:, **options)
        if json_output
          @out.puts(JSON.pretty_generate(build_result_contract_payload(path, result)))
        elsif bundle
          @out.puts("built #{path} -> #{File.dirname(result.output_path)}")
          @out.puts("entry executable #{result.output_path}")
          @out.puts("archive #{result.archive_path}") if result.archive_path
        else
          @out.puts("built #{path} -> #{result.output_path}")
        end
        @out.puts("saved C to #{result.c_path}") if result.c_path && !json_output
        0
      end
    end

    def run_command
      path = nil
      if @argv.first && !@argv.first.start_with?("-")
        path = @argv.shift
      end

      options = parse_build_options
      return 1 unless options
      json_output = options.delete(:json)

      unless path
        if File.file?(File.join(Dir.pwd, "package.toml"))
          path = Dir.pwd
        else
          @err.puts("missing source file path")
          print_usage(@err)
          return 1
        end
      end

      with_contract_error_handling("runResult", enabled: json_output, input_path: path) do
        frozen = options.delete(:frozen)
        ensure_current_lockfile!(path) if frozen
        locked = options.delete(:locked)
        frontend = frontend_from_options(options, locked:, frozen:)
        package_graph = package_graph_for(path, locked:)
        preview_notice_emitted = false
        preview_started = nil
        unless json_output
          preview_started = lambda do |message|
            preview_notice_emitted = true
            @out.write(message)
            @out.flush if @out.respond_to?(:flush)
          end
        end

        result = Run.run(
          path,
          module_roots: module_roots_for(path, locked:),
          package_graph:,
          frontend:,
          preview_started:,
          **options
        )
        if json_output
          @out.puts(JSON.pretty_generate(run_result_contract_payload(path, result)))
        else
          @out.write(result.stdout) unless preview_notice_emitted
          @err.write(result.stderr)
        end
        result.exit_status
      end
    end

    def new_command
      name = @argv.shift
      unless name
        @err.puts("missing project name")
        print_usage(@err)
        return 1
      end

      if @argv.any?
        @err.puts("unknown new option #{@argv.first}")
        print_usage(@err)
        return 1
      end

      result = ProjectScaffold.create(name)
      @out.puts("created #{result.root_path}")
      0
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
        frontend_command: nil,
        profile: nil,
        platform: nil,
        bundle: false,
        archive: false,
        locked: false,
        frozen: false,
        json: false,
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
        when "--frontend-command"
          value = @argv.shift
          return missing_option_value(option) unless value

          options[:frontend_command] ||= []
          options[:frontend_command] << value
        when "--profile"
          value = @argv.shift
          return missing_option_value(option) unless value

          options[:profile] = value
        when "--platform"
          value = @argv.shift
          return missing_option_value(option) unless value

          options[:platform] = value
        when "--bundle"
          options[:bundle] = true
        when "--archive"
          options[:bundle] = true
          options[:archive] = true
        when "--locked"
          options[:locked] = true
        when "--frozen"
          options[:locked] = true
          options[:frozen] = true
        when "--json"
          options[:json] = true
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

    def frontend_from_options(options, locked:, frozen:)
      command = options.delete(:frontend_command)
      if command&.any?
        return Build::CommandFrontend.new(command:, locked:, frozen:)
      end

      Build.default_frontend_from_env(locked:, frozen:)
    end

    def parse_frontend_artifacts_options
      options = {
        platform: :linux,
        json: false,
        locked: false,
        frozen: false,
        emit_line_directives: false,
      }

      until @argv.empty?
        option = @argv.shift
        case option
        when "--compiled-c"
          value = @argv.shift
          return missing_option_value(option) unless value

          options[:compiled_c_path] = value
        when "--saved-c"
          value = @argv.shift
          return missing_option_value(option) unless value

          options[:saved_c_path] = value
        when "--debug-map"
          value = @argv.shift
          return missing_option_value(option) unless value

          options[:debug_map_path] = value
        when "--binary-path"
          value = @argv.shift
          return missing_option_value(option) unless value

          options[:binary_path] = value
        when "--platform"
          value = @argv.shift
          return missing_option_value(option) unless value

          options[:platform] = case value
                               when "linux" then :linux
                               when "windows", "win", "win32" then :windows
                               when "wasm", "web", "html5", "browser" then :wasm
                               else
                                 @err.puts("unknown platform #{value}; expected linux|windows|wasm")
                                 print_usage(@err)
                                 return nil
                               end
        when "--json"
          options[:json] = true
        when "--locked"
          options[:locked] = true
        when "--frozen"
          options[:locked] = true
          options[:frozen] = true
        when "--line-directives"
          options[:emit_line_directives] = true
        when "--no-line-directives"
          options[:emit_line_directives] = false
        else
          @err.puts("unknown frontend-artifacts option #{option}")
          print_usage(@err)
          return nil
        end
      end

      %i[compiled_c_path saved_c_path debug_map_path binary_path].each do |key|
        next if options[key]

        @err.puts("missing required option #{frontend_artifact_option_name(key)}")
        print_usage(@err)
        return nil
      end

      options
    end

    def frontend_artifact_option_name(key)
      case key
      when :compiled_c_path then "--compiled-c"
      when :saved_c_path then "--saved-c"
      when :debug_map_path then "--debug-map"
      when :binary_path then "--binary-path"
      else key.to_s
      end
    end

    def parse_format_options
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
          @err.puts("unknown format option #{option}")
          print_usage(@err)
          return nil
        end
      end

      if options[:check] && options[:write]
        @err.puts("format options --check and --write cannot be combined")
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
      classes = [LexError, ParseError, ModuleLoadError, SemaError, LoweringError, BuildError, RunError, FormatterError, SourceIndexToolError, PackageManifestError, PackageManifestEditorError, PackageGraphError, PackageLockError, PackageSourceResolverError, PackageSourceFetcherError, PackageRegistryStoreError, PackageRegistryMetadataProviderError, PackageDependencySolverError, PackageVersionError, ProjectScaffoldError]
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
      return nil unless path

      PackageGraph.load(path, locked:)
    rescue PackageManifestError
      nil
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

    def lint_sema_facts_for(source, path, locked: false)
      ast = Parser.parse(source, path: path)
      imported_modules = make_module_loader(path, locked:).imported_modules_for_ast(ast, importer_path: path)
      Sema.tooling_snapshot(ast, imported_modules: imported_modules, path: path).facts
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
      %w[semantic-tokens parse lint diagnostics check lower emit-c frontend-artifacts build run].include?(command)
    end

    def semantic_tokens_contract_payload(payload, source_path:)
      source = read_source_file(source_path)
      line_texts = source.lines

      payload.merge(
        version: CONTRACT_VERSION,
        contract: "semanticTokens",
        positionEncoding: CONTRACT_POSITION_ENCODING,
        path: contract_path(payload.fetch(:path)),
        entries: payload.fetch(:entries).map do |entry|
          contract_semantic_token_entry(entry, line_texts)
        end,
      )
    end

    def diagnostics_contract_payload(path, source, locked: false)
      result = MilkTea::LSP::Diagnostics.collect(
        path_to_uri(path),
        source,
        dependency_resolution_mode: locked ? :locked : :auto,
      )
      diagnostics = result.fetch(:diagnostics)

      {
        version: CONTRACT_VERSION,
        contract: "diagnostics",
        positionEncoding: CONTRACT_POSITION_ENCODING,
        path: contract_path(path),
        moduleName: result[:facts]&.module_name,
        summary: diagnostics_summary_payload(diagnostics),
        diagnostics: diagnostics.map { |diagnostic| diagnostics_entry_payload(diagnostic, source) },
      }.compact
    end

    def diagnostics_summary_payload(diagnostics)
      counts = diagnostics.each_with_object({ errorCount: 0, warningCount: 0, informationCount: 0, hintCount: 0 }) do |diagnostic, memo|
        case severity_name(fetch_hash_value(diagnostic, :severity))
        when "error"
          memo[:errorCount] += 1
        when "warning"
          memo[:warningCount] += 1
        when "information"
          memo[:informationCount] += 1
        when "hint"
          memo[:hintCount] += 1
        end
      end
      counts[:totalCount] = counts.values.sum
      counts
    end

    def diagnostics_entry_payload(diagnostic, source)
      {
        code: fetch_hash_value(diagnostic, :code) || "tooling/error",
        stage: fetch_hash_value(fetch_hash_value(diagnostic, :data) || {}, :stage) || "tooling",
        severity: severity_name(fetch_hash_value(diagnostic, :severity)),
        message: fetch_hash_value(diagnostic, :message).to_s,
        source: fetch_hash_value(diagnostic, :source),
        range: contract_range_payload(fetch_hash_value(diagnostic, :range), source),
      }.compact
    end

    def build_clean_contract_payload(input_path, cleaned_path)
      {
        version: CONTRACT_VERSION,
        contract: "buildResult",
        success: true,
        action: "clean",
        inputPath: contract_path(input_path),
        cleanedPath: contract_path(cleaned_path),
      }
    end

    def build_result_contract_payload(input_path, result)
      {
        version: CONTRACT_VERSION,
        contract: "buildResult",
        success: true,
        inputPath: contract_path(input_path),
        outputPath: contract_path(result.output_path),
        cPath: contract_path(result.c_path),
        compiler: result.compiler,
        linkFlags: result.link_flags,
        profile: result.profile&.to_s,
        platform: result.platform&.to_s,
        bundleRoot: contract_path(result.bundle_root),
        archivePath: contract_path(result.archive_path),
      }.compact
    end

    def frontend_artifacts_contract_payload(input_path, artifacts, options)
      {
        version: CONTRACT_VERSION,
        contract: "frontendArtifacts",
        success: true,
        inputPath: contract_path(input_path),
        compiledCPath: contract_path(options.fetch(:compiled_c_path)),
        savedCPath: contract_path(options.fetch(:saved_c_path)),
        debugMapPath: contract_path(options.fetch(:debug_map_path)),
        binaryPath: contract_path(options.fetch(:binary_path)),
        platform: options.fetch(:platform).to_s,
        emitLineDirectives: options.fetch(:emit_line_directives),
        modules: artifacts.fetch(:modules).map do |mod|
          {
            name: mod.name,
            kind: mod.kind.to_s,
            linkLibraries: mod.link_libraries,
            compilerFlags: mod.compiler_flags,
          }
        end,
      }
    end

    def run_result_contract_payload(input_path, result)
      {
        version: CONTRACT_VERSION,
        contract: "runResult",
        success: true,
        inputPath: contract_path(input_path),
        outputPath: contract_path(result.output_path),
        cPath: contract_path(result.c_path),
        compiler: result.compiler,
        linkFlags: result.link_flags,
        platform: result.platform&.to_s,
        bundleRoot: contract_path(result.bundle_root),
        archivePath: contract_path(result.archive_path),
        stdout: result.stdout,
        stderr: result.stderr,
        exitStatus: result.exit_status,
      }.compact
    end

    def with_contract_error_handling(contract_name, enabled:, input_path: nil)
      yield
    rescue StandardError => e
      raise unless enabled && handled_cli_error?(e)

      @out.puts(JSON.pretty_generate(contract_error_payload(contract_name, e, input_path:)))
      1
    end

    def contract_error_payload(contract_name, error, input_path: nil)
      payload = {
        version: CONTRACT_VERSION,
        contract: contract_name,
        success: false,
        error: {
          code: contract_error_code(error),
          type: error.class.name.split("::").last,
          message: error.message.to_s,
        },
      }
      payload[:inputPath] = contract_path(input_path) if input_path
      payload
    end

    def contract_error_code(error)
      case error
      when BuildError
        "build/error"
      when RunError
        "run/error"
      when PackageLockError
        "package/lock-error"
      when PackageManifestError
        "package/manifest-error"
      when PackageGraphError
        "package/graph-error"
      when PackageSourceResolverError
        "package/source-resolver-error"
      when PackageSourceFetcherError
        "package/source-fetcher-error"
      when PackageRegistryStoreError
        "package/registry-store-error"
      when PackageRegistryMetadataProviderError
        "package/registry-metadata-error"
      when PackageDependencySolverError
        "package/dependency-solver-error"
      when PackageVersionError
        "package/version-error"
      when ModuleLoadError
        "import/load-error"
      when LexError
        "lex/error"
      when ParseError
        "parse/error"
      when SemaError
        "sema/error"
      else
        "tooling/error"
      end
    end

    def contract_range_payload(range, source)
      source_lines = source.lines
      start = fetch_hash_value(range, :start)
      end_pos = fetch_hash_value(range, :end)
      start_line = fetch_hash_value(start, :line)
      end_line = fetch_hash_value(end_pos, :line)
      start_char = fetch_hash_value(start, :character)
      end_char = fetch_hash_value(end_pos, :character)

      {
        start: {
          line: start_line,
          byte: line_char_to_byte(source_lines, start_line, start_char),
        },
        end: {
          line: end_line,
          byte: line_char_to_byte(source_lines, end_line, end_char),
        },
      }
    end

    def line_char_to_byte(line_texts, line_index, char_index)
      line_text = line_texts.fetch(line_index, "")
      line_text[0, char_index].to_s.bytesize
    end

    def severity_name(value)
      case value.to_i
      when 1 then "error"
      when 2 then "warning"
      when 3 then "information"
      when 4 then "hint"
      else "warning"
      end
    end

    def fetch_hash_value(hash, key)
      return nil unless hash
      return hash[key] if hash.key?(key)

      hash[key.to_s]
    end

    def contract_semantic_token_entry(entry, line_texts)
      line_text = line_texts.fetch(entry.fetch(:line), "")
      start_char = entry.fetch(:startChar)
      char_length = entry.fetch(:length)
      start_byte = line_text[0, start_char].to_s.bytesize
      token_text = line_text[start_char, char_length].to_s
      length_bytes = token_text.bytesize

      entry.merge(
        startByte: start_byte,
        endByte: start_byte + length_bytes,
        lengthBytes: length_bytes,
      )
    end

    def contract_path(path, base_dir: Dir.pwd)
      return nil unless path

      expanded_path = File.expand_path(path)
      return expanded_path.tr("\\", "/") unless base_dir

      expanded_base_dir = File.expand_path(base_dir)
      within_base_dir = expanded_path == expanded_base_dir || expanded_path.start_with?("#{expanded_base_dir}#{File::SEPARATOR}")
      return expanded_path.tr("\\", "/") unless within_base_dir

      begin
        Pathname.new(expanded_path).relative_path_from(Pathname.new(expanded_base_dir)).to_s.tr("\\", "/")
      rescue ArgumentError
        expanded_path.tr("\\", "/")
      end
    end

    def path_to_uri(path)
      escaped_path = File.expand_path(path).tr("\\", "/").split("/").map { |segment| CGI.escape(segment).gsub("+", "%20") }.join("/")
      "file://#{escaped_path}"
    end

    COMMAND_HELP = {
      "lex"             => "Usage: mtc lex PATH\n\n  Tokenize a source file and print the token stream.",
      "semantic-tokens" => "Usage: mtc semantic-tokens PATH [--locked] [--frozen] [-I PATH]\n\n  Emit a versioned semantic token contract for a source file as JSON.",
      "parse"           => "Usage: mtc parse PATH [--locked] [--frozen] [-I PATH]\n\n  Parse a source file and print the AST.",
      "format"          => <<~HELP,
        Usage: mtc format PATH|DIR [OPTIONS]

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
          "diagnostics"     => "Usage: mtc diagnostics PATH [--locked] [--frozen] [-I PATH]\n\n  Emit a versioned diagnostics contract for a source file as JSON.",
      "check"           => "Usage: mtc check PATH [--locked] [--frozen] [-I PATH]\n\n  Run semantic analysis on a source file and report errors.",
      "lower"           => "Usage: mtc lower PATH [--locked] [--frozen] [-I PATH]\n\n  Lower a source file to IR and print it.",
      "emit-c"          => "Usage: mtc emit-c PATH [--locked] [--frozen] [-I PATH]\n\n  Compile a source file to C and print the output.",
      "frontend-artifacts" => <<~HELP,
        Usage: mtc frontend-artifacts PATH [OPTIONS]

          Compile frontend artifacts without invoking a C compiler. This is the
          external-frontend handoff contract used by Build command frontends.

          Options:
            --compiled-c PATH          Write the C used for compilation.
            --saved-c PATH             Write the normalized C used for --keep-c.
            --debug-map PATH           Write the debug map JSON.
            --binary-path PATH         Binary path to encode into the debug map.
            --platform PLATFORM        linux (default) | windows | wasm.
            --line-directives          Emit #line directives in compiled C.
            --no-line-directives       Omit #line directives (default).
            --json                     Emit a versioned frontend artifact contract as JSON.
            --locked                   Resolve dependencies from package.lock.
            --frozen                   Require a current package.lock and use locked resolution.
            -I, --include-path PATH    Add an extra module root.
        HELP
      "build"           => <<~HELP,
        Usage: mtc build [PATH_OR_PACKAGE] [OPTIONS]

          Compile a source file or package. Defaults to current directory if a
          package.toml is present.

          Options:
            -o, --output OUTPUT          Output path for the compiled artifact.
            --cc COMPILER                C compiler to use (default: $CC or cc).
            --frontend-command ARG       External frontend command argv element (repeatable).
            --keep-c C_PATH              Write the generated C source to this path.
            --profile PROFILE            debug (default) | release.
            --platform PLATFORM          linux (default) | windows | wasm.
            --bundle                     Package a native package build into a distributable directory.
            --archive                    Also write a .tar.gz archive for the native bundle (implies --bundle).
            --json                       Emit a versioned build result contract as JSON.
            --locked                     Resolve dependencies from package.lock.
            --frozen                     Require a current package.lock and use locked resolution.
            --clean                      Remove existing build outputs and exit.
            -I, --include-path PATH      Add an extra module root.
        HELP
      "new"             => <<~HELP,
        Usage: mtc new NAME

          Create a new application package scaffold with package.toml and src/main.mt.
          NAME selects the target directory, and its basename is normalized to
          snake_case for package.name and the generated module declaration.
          The target may be a new directory or an existing empty directory.
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
            --frontend-command ARG       External frontend command argv element (repeatable).
            --keep-c C_PATH              Write the generated C source to this path.
            --profile PROFILE            debug (default) | release.
            --platform PLATFORM          linux (default) | windows | wasm.
            --json                       Emit a versioned run result contract as JSON.
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
      io.puts("       mtc format PATH|DIR [--check|--write] [--safe|--canonical|--preserve]")
      io.puts("       mtc lint PATH|DIR [--select RULES] [--ignore RULES] [--fix] [--output-format text|json] [--locked] [--frozen] [-I PATH]")
      io.puts("       mtc diagnostics PATH [--locked] [--frozen] [-I PATH]")
      io.puts("       mtc check PATH [--locked] [--frozen] [-I PATH]")
      io.puts("       mtc lower PATH [--locked] [--frozen] [-I PATH]")
      io.puts("       mtc emit-c PATH [--locked] [--frozen] [-I PATH]")
      io.puts("       mtc frontend-artifacts PATH --compiled-c PATH --saved-c PATH --debug-map PATH --binary-path PATH [--platform linux|windows|wasm] [--line-directives|--no-line-directives] [--json] [--locked] [--frozen] [-I PATH]")
      io.puts("       mtc build [PATH_OR_PACKAGE] [-o OUTPUT] [--cc COMPILER] [--frontend-command ARG]... [--keep-c C_PATH] [--profile debug|release] [--platform linux|windows|wasm] [--bundle] [--archive] [--json] [--locked] [--frozen] [--clean] [-I PATH]")
      io.puts("       mtc new NAME")
      io.puts("       mtc run [PATH_OR_PACKAGE] [-o OUTPUT] [--cc COMPILER] [--frontend-command ARG]... [--keep-c C_PATH] [--profile debug|release] [--platform linux|windows|wasm] [--json] [--locked] [--frozen] [-I PATH]")
      io.puts("       mtc dap")
      io.puts("       mtc toolchain bootstrap")
      io.puts("       mtc toolchain doctor")
      io.puts("       mtc deps add [PATH_OR_PACKAGE] NAME[@VERSION_REQ] [--path PATH] [--git URL --rev REV [--subdir DIR]] [--version VERSION_REQ]")
      io.puts("       mtc deps remove [PATH_OR_PACKAGE] NAME")
      io.puts("       mtc deps update [PATH_OR_PACKAGE] [NAME ...]")
      io.puts("       mtc deps tree [PATH_OR_PACKAGE]")
      io.puts("       mtc deps lock [PATH_OR_PACKAGE] [--check]")
      io.puts("       mtc deps publish [PATH_OR_PACKAGE] [--upstream]")
      io.puts("       mtc deps fetch [PATH_OR_PACKAGE]")
      io.puts("       mtc bindgen MODULE HEADER [-o OUTPUT] [--nullable-report PATH] [--link LIB] [--include HEADER] [--clang PATH] [--clang-arg ARG]")
    end
  end
end
