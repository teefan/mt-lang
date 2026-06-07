# frozen_string_literal: true

require "fileutils"
require "rubygems/package"
require "tempfile"
require "zlib"

require_relative "asset_pack"
require_relative "build_cache"
require_relative "debug_map"

module MilkTea
  class BuildError < StandardError; end

  class Build
    FrontendModule = Data.define(:name, :kind, :link_libraries, :compiler_flags)

    class RubyFrontend
      def compile(path:, module_roots:, package_graph:, platform:, emit_line_directives:, binary_path:)
        program = ModuleLoader.new(module_roots:, package_graph:, platform:).check_program(path)
        Build.frontend_build_artifacts(program, emit_line_directives:, binary_path:)
      end
    end

    DEFAULT_WASM_SHELL_TEMPLATE_PATH = File.expand_path("templates/wasm_shell.html", __dir__).freeze
    WASM_SHELL_SCRIPT_PLACEHOLDER = "{{{ SCRIPT }}}".freeze
    WASM_SHELL_CANVAS_PLACEHOLDER = "{{{ MILK_TEA_CANVAS }}}".freeze
    WASM_SHELL_OUTPUT_PLACEHOLDER = "{{{ MILK_TEA_OUTPUT }}}".freeze
    WASM_SHELL_BOOTSTRAP_PLACEHOLDER = "{{{ MILK_TEA_BOOTSTRAP }}}".freeze
    WASM_SHELL_TEMPLATE = File.read(DEFAULT_WASM_SHELL_TEMPLATE_PATH).freeze
    WASM_SHELL_CANVAS_TEMPLATE = <<~HTML.freeze
      <canvas id="canvas" oncontextmenu="event.preventDefault()" tabindex="-1"></canvas>
    HTML
    WASM_SHELL_OUTPUT_TEMPLATE = <<~HTML.freeze
      <pre id="output"></pre>
    HTML
    WASM_SHELL_BOOTSTRAP_TEMPLATE = <<~HTML.freeze
      <script>
        var Module = {
          print: (function() {
            var element = document.getElementById('output');
            if (element) element.textContent = '';
            return function(text) {
              if (arguments.length > 1) text = Array.prototype.slice.call(arguments).join(' ');
              console.log(text);
              if (element) {
                element.textContent += text + "\\n";
                element.scrollTop = element.scrollHeight;
              }
            };
          })(),
          printErr: (function() {
            var element = document.getElementById('output');
            return function(text) {
              if (arguments.length > 1) text = Array.prototype.slice.call(arguments).join(' ');
              console.error(text);
              if (element) {
                element.textContent += "[err] " + text + "\\n";
                element.scrollTop = element.scrollHeight;
              }
            };
          })(),
          canvas: (function() {
            return document.getElementById('canvas');
          })()
        };
      </script>
    HTML

    Result = Data.define(:output_path, :c_path, :compiler, :link_flags, :profile, :platform, :bundle_root, :archive_path, :cached)

    def self.build(path, output_path: nil, cc: ENV.fetch("CC", "cc"), keep_c_path: nil, raw_bindings: nil, module_roots: nil, package_graph: nil, frontend: nil, debug: false, profile: nil, platform: nil, bundle: false, archive: false)
      raw_bindings ||= default_raw_bindings
      new(path, output_path:, cc:, keep_c_path:, raw_bindings:, module_roots:, package_graph:, frontend:, debug:, profile:, platform:, bundle:, archive:).build
    end

    def self.clean(path, output_path: nil, profile: nil, platform: nil, bundle: false, archive: false)
      new(
        path,
        output_path:,
        cc: ENV.fetch("CC", "cc"),
        keep_c_path: nil,
        raw_bindings: nil,
        module_roots: nil,
        debug: false,
        profile:,
        platform:,
        bundle:,
        archive:
      ).clean
    end

    def self.frontend_build_artifacts(program, emit_line_directives: false, binary_path: nil)
      ir_program = program.is_a?(IR::Program) ? program : Lowering.lower(program)
      ensure_program_has_entrypoint!(program, ir_program)
      compiled_c = CBackend.emit(ir_program, emit_line_directives: emit_line_directives)
      saved_c = emit_line_directives ? nil : compiled_c

      {
        ir_program: ir_program,
        compiled_c: compiled_c,
        saved_c: saved_c,
        debug_map: binary_path ? DebugMap.from_ir(ir_program, binary_path:) : nil,
        modules: frontend_modules(program),
      }
    end

    def self.frontend_modules(program)
      return [].freeze if program.is_a?(IR::Program)

      program.analyses_by_module_name.keys.sort.map do |module_name|
        analysis = program.analyses_by_module_name.fetch(module_name)
        FrontendModule.new(
          name: module_name,
          kind: analysis.module_kind,
          link_libraries: analysis.directives.grep(AST::LinkDirective).map(&:value).freeze,
          compiler_flags: analysis.directives.grep(AST::CompilerFlagDirective).map(&:value).freeze,
        )
      end.freeze
    end
    private_class_method :frontend_modules

    def self.default_raw_bindings(root: MilkTea.root)
      require_relative "../bindings"

      RawBindings.default_registry(root:)
    end
    private_class_method :default_raw_bindings

    def initialize(path, output_path:, cc:, keep_c_path:, raw_bindings:, module_roots: nil, package_graph: nil, frontend: nil, debug: false, profile: nil, platform: nil, bundle: false, archive: false)
      manifest = PackageManifest.load(path)
      @package_build = true
      @source_path = manifest.source_path
      @project_root = manifest.root_dir
      @package_name = manifest.package_name
      @archive = archive
      @bundle = bundle || archive
      if manifest.package_kind == :library
        raise BuildError, "cannot build library package #{manifest.package_name} as an executable"
      end
      unless @source_path
        raise BuildError, "application package #{manifest.package_name} has no build entry; set build.entry or create src/main.mt"
      end
      @profile = normalize_profile(profile || manifest.profile || (debug ? :debug : :debug))
      @platform = normalize_platform(platform || manifest.platform || host_platform)
      @resolved_source_path = ModuleLoader.resolve_source_path(@source_path, platform: @platform, error_class: BuildError)
      validate_bundle_mode!
      @manifest_output_path = manifest.output_path
      @explicit_output_path = !output_path.nil?
      if @bundle
        @bundle_root = File.expand_path(output_path || manifest.output_path || default_package_bundle_root)
        @output_path = File.join(@bundle_root, "#{@package_name}#{artifact_extension}")
      else
        @bundle_root = nil
        resolved_output = output_path || manifest.output_path || default_package_output_path
        @output_path = normalize_output_path(File.expand_path(resolved_output))
      end
      @assets_paths = manifest.assets_paths
      @html_template_path = manifest.html_template_path
      @cc = resolve_compiler(cc)
      @keep_c_path = keep_c_path ? File.expand_path(keep_c_path) : nil
      @raw_bindings = raw_bindings
      @package_graph = package_graph
      @module_roots = (module_roots || @package_graph&.source_roots || MilkTea::ModuleRoots.roots_for_path(@source_path)).dup
      @frontend = frontend || RubyFrontend.new
      @debug = debug
    rescue PackageManifestError => e
      raise BuildError, e.message if package_manifest_required_for?(path)

      @package_build = false
      @source_path = File.expand_path(path)
      @project_root = File.dirname(@source_path)
      @package_name = File.basename(@project_root).tr("-", "_")
      @archive = archive
      @bundle = bundle || archive
      @profile = normalize_profile(profile || (debug ? :debug : :debug))
      @platform = normalize_platform(platform || host_platform)
      @resolved_source_path = ModuleLoader.resolve_source_path(@source_path, platform: @platform, error_class: BuildError)
      validate_bundle_mode!
      @manifest_output_path = nil
      @explicit_output_path = !output_path.nil?
      @bundle_root = nil
      @output_path = normalize_output_path(File.expand_path(output_path || default_source_output_path(@source_path)))
      @assets_paths = []
      @html_template_path = nil
      @cc = resolve_compiler(cc)
      @keep_c_path = keep_c_path ? File.expand_path(keep_c_path) : nil
      @raw_bindings = raw_bindings
      @package_graph = package_graph
      @module_roots = module_roots || MilkTea::ModuleRoots.roots_for_path(@source_path)
      @frontend = frontend || RubyFrontend.new
      @debug = debug
    end

    def clean
      target_path = clean_target_path
      if File.directory?(target_path)
        FileUtils.rm_rf(target_path)
      else
        clean_output_artifacts(target_path)
        clean_staged_runtime_assets(target_path)
        FileUtils.rm_f(DebugMap.sidecar_path_for(@output_path))
      end
      clean_bundle_archive
      target_path
    end

    def build
      ensure_compiler_available!
      ensure_supported_backend!

      if @frontend.is_a?(RubyFrontend)
        build_cached
      else
        build_uncached
      end
    end

    private

    def build_cached
      cache = BuildCache.new(root: MilkTea.root)
      emit_line_directives = line_directives_required?
      @cached = true

      program = load_program_with_cache(cache)

      compiled_c, frontend_modules, debug_map_source = compile_frontend(program, cache, emit_line_directives)

      prepare_bindings(frontend_modules)
      compiler_flags = collect_compiler_flags(frontend_modules)
      link_flags = collect_link_flags(frontend_modules)
      debug_map_path = DebugMap.sidecar_path_for(@output_path)

      FileUtils.mkdir_p(File.dirname(@output_path))

      saved_c = compile_frontend_saved_c(compiled_c, emit_line_directives)

      if @keep_c_path
        saved_c ||= compiled_c unless emit_line_directives
        if emit_line_directives && saved_c.nil?
          saved_c = CBackend.emit(Lowering.lower(program), emit_line_directives: false)
        end
        raise BuildError, "frontend did not provide saved C output for --keep-c debug build" if saved_c.nil?

        write_c_file(@keep_c_path, saved_c)
        compile_and_link_cached(compiled_c, compiler_flags, link_flags, cache)
        if debug_map_source
          DebugMap.from_ir(debug_map_source, binary_path: @output_path).write(debug_map_path)
        end
        stage_runtime_assets
        archive_path = write_bundle_archive
        return Result.new(output_path: @output_path, c_path: @keep_c_path, compiler: @cc, link_flags:, profile: @profile, platform: @platform, bundle_root: @bundle_root, archive_path:, cached: @cached)
      end

      compile_and_link_cached(compiled_c, compiler_flags, link_flags, cache)

      if debug_map_source
        debug_map = debug_map_source.is_a?(IR::Program) ? DebugMap.from_ir(debug_map_source, binary_path: @output_path) : debug_map_source
        debug_map.write(debug_map_path)
      end
      stage_runtime_assets
      archive_path = write_bundle_archive

      Result.new(output_path: @output_path, c_path: nil, compiler: @cc, link_flags:, profile: @profile, platform: @platform, bundle_root: @bundle_root, archive_path:, cached: @cached)
    end

    def build_uncached
      emit_line_directives = line_directives_required?
      artifacts = @frontend.compile(
        path: @resolved_source_path,
        module_roots: @module_roots,
        package_graph: @package_graph,
        platform: @platform,
        emit_line_directives: emit_line_directives,
        binary_path: @output_path,
      )
      ir_program = artifacts[:ir_program]
      compiled_c = artifacts.fetch(:compiled_c)
      saved_c = artifacts[:saved_c]
      debug_map = artifacts.fetch(:debug_map)
      frontend_modules = artifacts.fetch(:modules)
      prepare_bindings(frontend_modules)
      compiler_flags = collect_compiler_flags(frontend_modules)
      link_flags = collect_link_flags(frontend_modules)
      debug_map_path = DebugMap.sidecar_path_for(@output_path)

      FileUtils.mkdir_p(File.dirname(@output_path))

      if @keep_c_path
        saved_c ||= compiled_c unless emit_line_directives
        saved_c ||= CBackend.emit(ir_program, emit_line_directives: false) if emit_line_directives && ir_program
        raise BuildError, "frontend did not provide saved C output for --keep-c debug build" if saved_c.nil?

        write_c_file(@keep_c_path, saved_c)
        if emit_line_directives
          compile_generated_c(compiled_c, compiler_flags, link_flags)
        else
          compile(@keep_c_path, compiler_flags, link_flags)
        end
        debug_map.write(debug_map_path)
        stage_runtime_assets
        archive_path = write_bundle_archive
        return Result.new(output_path: @output_path, c_path: @keep_c_path, compiler: @cc, link_flags:, profile: @profile, platform: @platform, bundle_root: @bundle_root, archive_path:, cached: false)
      end

      compile_generated_c(compiled_c, compiler_flags, link_flags)

      debug_map.write(debug_map_path)
      stage_runtime_assets
      archive_path = write_bundle_archive

      Result.new(output_path: @output_path, c_path: nil, compiler: @cc, link_flags:, profile: @profile, platform: @platform, bundle_root: @bundle_root, archive_path:, cached: false)
    end

    def clean_target_path
      if @package_build && !@explicit_output_path && @manifest_output_path.nil?
        return File.join(@project_root, "build", "dist") if @bundle

        File.join(@project_root, "build")
      elsif @bundle
        @bundle_root
      else
        @output_path
      end
    end

    def validate_bundle_mode!
      return unless @bundle

      raise BuildError, "bundle mode requires a package build" unless @package_build
      raise BuildError, "bundle mode is supported only for native package builds" if target_wasm?
    end

    def load_program_with_cache(cache)
      loader = ModuleLoader.new(
        module_roots: @module_roots,
        package_graph: @package_graph,
        shared_cache: cache.shared_analysis_cache,
        platform: @platform,
      )
      loader.check_program(@resolved_source_path)
    end

    def compile_frontend(program, cache, emit_line_directives)
      source_files = program.analyses_by_path.keys.each_with_object({}) do |path, hash|
        hash[path] = File.read(path, mode: "rb")
      end
      key = cache.program_key(source_files: source_files.to_a)

      cached = cache.fetch_program(key)
      if cached
        return [cached.c_source, cached.frontend_modules, nil]
      end

      @cached = false
      ir_program = Lowering.lower(program)
      Build.ensure_program_has_entrypoint!(program, ir_program)
      compiled_c = CBackend.emit(ir_program, emit_line_directives:)

      frontend_modules = Build.send(:frontend_modules, program)

      cache.store_program(key, c_source: compiled_c, frontend_modules:)

      [compiled_c, frontend_modules, ir_program]
    end

    def compile_frontend_saved_c(compiled_c, emit_line_directives)
      return nil if emit_line_directives

      compiled_c
    end

    def compile_and_link_cached(compiled_c, compiler_flags, link_flags, cache)
      binary_key = cache.binary_key(c_source: compiled_c, cc: @cc, compiler_flags:, link_flags:)
      cached_binary = cache.fetch_binary(binary_key)

      if cached_binary
        FileUtils.cp(cached_binary, @output_path)
        return
      end

      @cached = false
      compile_generated_c(compiled_c, compiler_flags, link_flags)
      cache.store_binary(binary_key, @output_path)
    end

    def self.ensure_program_has_entrypoint!(program, ir_program)
      return if ir_program.functions.any?(&:entry_point)
      return if program.is_a?(IR::Program)

      if program.root_analysis.functions.key?("main")
        raise BuildError, "root main is not a valid executable entrypoint; expected `function main() -> int|void`, `function main(argc: int, argv: ptr[cstr]) -> int|void`, `function main(argc: int, argv: ptr[ptr[char]]) -> int|void`, or `function main(args: span[str]) -> int|void`"
      end

      raise BuildError, "no executable entrypoint found; define `main` with one of the supported executable signatures"
    end

    def package_manifest_required_for?(path)
      expanded_path = File.expand_path(path)
      return true if File.directory?(expanded_path)
      return true if File.basename(expanded_path) == "package.toml"

      current = File.dirname(expanded_path)
      loop do
        return true if File.file?(File.join(current, "package.toml"))

        parent = File.dirname(current)
        break if parent == current

        current = parent
      end

      false
    end

    def default_source_output_path(source_path)
      base = source_path.sub(/\.mt\z/, "")
      target_wasm? ? "#{base}.html" : base
    end

    def default_package_output_path
      build_root = File.join(@project_root, "build")
      File.join(build_root, "bin", @platform.to_s, @profile.to_s, "#{@package_name}#{artifact_extension}")
    end

    def default_package_bundle_root
      File.join(@project_root, "build", "dist", @platform.to_s, @profile.to_s, @package_name)
    end

    def normalize_profile(value)
      case value.to_s
      when "", "debug", "dev"
        :debug
      when "release", "rel"
        :release
      else
        raise BuildError, "unknown profile #{value}; expected debug|release"
      end
    end

    def normalize_platform(value)
      case value.to_s
      when "", "linux"
        :linux
      when "windows", "win", "win32"
        :windows
      when "wasm", "web", "html5", "browser"
        :wasm
      when "darwin", "macos", "osx"
        :darwin
      else
        raise BuildError, "unknown platform #{value}; expected linux|windows|wasm|darwin"
      end
    end

    def normalize_output_path(path)
      return path unless target_wasm?

      extension = File.extname(path)
      return "#{path}.html" if extension.empty?
      return path if extension == ".html"

      raise BuildError, "wasm output path must end with .html or omit the extension: #{path}"
    end

    def resolve_compiler(requested_cc)
      return ENV.fetch("EMCC", "emcc") if target_wasm? && requested_cc == ENV.fetch("CC", "cc")

      requested_cc
    end

    def prepare_bindings(frontend_modules)
      frontend_modules.each do |mod|
        next unless mod.kind == :raw_module

        binding = @raw_bindings.find_by_module_name(mod.name)
        next unless binding

        binding.prepare!(cc: @cc, platform: @platform)
      end
    rescue RawBindings::Error => e
      raise BuildError, e.message
    end

    def write_c_file(path, source)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, source)
    end

    def compile_generated_c(source, compiler_flags, link_flags)
      Tempfile.create(["milk-tea-build", ".c"]) do |file|
        file.write(source)
        file.flush
        file.close

        compile(file.path, compiler_flags, link_flags)
      end
    end

    def ensure_compiler_available!
      return if compiler_available?(@cc)

      raise BuildError, "C compiler not found: #{@cc}"
    end

    def ensure_supported_backend!
      if target_wasm?
        return if emscripten_backend?(@cc)

        raise BuildError, "unsupported C compiler backend for wasm target: #{@cc}; use Emscripten emcc"
      end

      return unless msvc_style_backend?(@cc)

      raise BuildError, "unsupported C compiler backend for native target: #{@cc}; use a clang/gcc-style compiler driver instead of cl.exe or clang-cl"
    end

    def collect_link_flags(frontend_modules)
      frontend_modules.each_with_object([]) do |mod, flags|
        next unless mod.kind == :raw_module

        binding = @raw_bindings.find_by_module_name(mod.name)
        if binding
          binding.link_flags(platform: @platform).grep(/\A-L/).each do |flag|
            flags << flag unless flags.include?(flag)
          end
        end

        mod.link_libraries.each do |link_library|
          flag = "-l#{link_library}"
          flags << flag unless flags.include?(flag)
        end

        if binding
          binding.link_flags(platform: @platform).reject { |flag| flag.start_with?("-L") }.each do |flag|
            flags << flag unless flags.include?(flag)
          end
        end
      end
    end

    def collect_compiler_flags(frontend_modules)
      std_c_include_flag = "-I#{MilkTea.root.join('std/c')}"

      frontend_modules.each_with_object([]) do |mod, flags|
        next unless mod.kind == :raw_module

        if mod.name.start_with?("std.c.")
          flags << std_c_include_flag unless flags.include?(std_c_include_flag)
        end

        mod.compiler_flags.each do |compiler_flag|
          flags << compiler_flag unless flags.include?(compiler_flag)
        end

        binding = @raw_bindings.find_by_module_name(mod.name)
        next unless binding

        binding.build_flags(platform: @platform).each do |flag|
          flags << flag unless flags.include?(flag)
        end
      end
    rescue RawBindings::Error => e
      raise BuildError, e.message
    end

    def compile(c_path, compiler_flags, link_flags)
      return compile_wasm(c_path, compiler_flags, link_flags) if target_wasm?

      profile_flags = profile_compiler_flags
      command = [@cc, "-std=c11", *profile_flags, *compiler_flags, c_path, "-o", @output_path, *link_flags]
      stdout, stderr, status = Open3.capture3(*command)
      return if status.success?

      details = [stdout, stderr].reject(&:empty?).join
      raise BuildError, details.empty? ? "C compiler failed" : "C compiler failed:\n#{details}"
    rescue Errno::ENOENT
      raise BuildError, "C compiler not found: #{@cc}"
    end

    def host_platform
      MilkTea.host_platform
    end

    def clean_output_artifacts(target_path)
      FileUtils.rm_f(target_path)
      return unless target_wasm? && File.extname(target_path) == ".html"

      base_path = target_path.sub(/\.html\z/, "")
      %w[.js .wasm .data .worker.js .symbols .wasm.map].each do |extension|
        FileUtils.rm_f("#{base_path}#{extension}")
      end
    end

    def clean_bundle_archive
      return unless @archive

      FileUtils.rm_f(bundle_archive_path)
    end

    def clean_staged_runtime_assets(target_path)
      runtime_asset_mappings_for(target_path).each do |_source_path, staged_path|
        FileUtils.rm_rf(staged_path)
      end

      FileUtils.rm_f(runtime_asset_pack_path_for(target_path)) if runtime_assets_packed?
    end

    def compile_wasm(c_path, compiler_flags, link_flags)
      profile_flags = profile_compiler_flags
      preload_flags = wasm_asset_flags
      module_api_flags = ["-sINCOMING_MODULE_JS_API=canvas,print,printErr"]

      with_wasm_shell_file do |shell_path|
        command = [@cc, "-std=c11", *profile_flags, *compiler_flags, c_path, "-o", @output_path, "--shell-file", shell_path, *module_api_flags, *preload_flags, *link_flags]
        stdout, stderr, status = Open3.capture3(*command)
        return if status.success?

        details = [stdout, stderr].reject(&:empty?).join
        raise BuildError, details.empty? ? "C compiler failed" : "C compiler failed:\n#{details}"
      end
    rescue Errno::ENOENT
      raise BuildError, "C compiler not found: #{@cc}"
    end

    def with_wasm_shell_file
      Tempfile.create(["milk-tea-shell", ".html"]) do |file|
        file.write(render_wasm_shell_template)
        file.flush
        file.close
        yield file.path
      end
    end

    def render_wasm_shell_template
      template_source = load_wasm_shell_template_source
      validate_wasm_shell_placeholder!(template_source, WASM_SHELL_SCRIPT_PLACEHOLDER, "Emscripten {{{ SCRIPT }}}")
      validate_wasm_shell_placeholder!(template_source, WASM_SHELL_CANVAS_PLACEHOLDER, "Milk Tea {{{ MILK_TEA_CANVAS }}}")
      validate_wasm_shell_placeholder!(template_source, WASM_SHELL_OUTPUT_PLACEHOLDER, "Milk Tea {{{ MILK_TEA_OUTPUT }}}")
      validate_wasm_shell_placeholder!(template_source, WASM_SHELL_BOOTSTRAP_PLACEHOLDER, "Milk Tea {{{ MILK_TEA_BOOTSTRAP }}}")

      template_source
        .sub(WASM_SHELL_CANVAS_PLACEHOLDER, WASM_SHELL_CANVAS_TEMPLATE)
        .sub(WASM_SHELL_OUTPUT_PLACEHOLDER, WASM_SHELL_OUTPUT_TEMPLATE)
        .sub(WASM_SHELL_BOOTSTRAP_PLACEHOLDER, WASM_SHELL_BOOTSTRAP_TEMPLATE)
    end

    def load_wasm_shell_template_source
      return WASM_SHELL_TEMPLATE.dup unless @html_template_path

      File.read(@html_template_path)
    end

    def validate_wasm_shell_placeholder!(template_source, placeholder, label)
      count = template_source.scan(Regexp.new(Regexp.escape(placeholder))).length
      return if count == 1

      template_path = @html_template_path || DEFAULT_WASM_SHELL_TEMPLATE_PATH
      raise BuildError, "wasm HTML template must contain #{label} exactly once: #{template_path}"
    end

    def wasm_asset_flags
      return [] unless target_wasm? && !@assets_paths.empty?

      @assets_paths.flat_map do |assets_path|
        mount_path = "/#{File.basename(assets_path)}"
        ["--preload-file", "#{assets_path}@#{mount_path}"]
      end
    end

    def stage_runtime_assets
      if runtime_assets_packed?
        runtime_asset_mappings_for(@output_path).each do |_source_path, staged_path|
          FileUtils.rm_rf(staged_path)
        end

        begin
          AssetPack.write(runtime_asset_pack_path_for(@output_path), @assets_paths)
        rescue AssetPackError => e
          raise BuildError, e.message
        end

        return
      end

      runtime_asset_mappings_for(@output_path).each do |source_path, staged_path|
        ensure_runtime_assets_do_not_overlap_source!(source_path, staged_path)
        FileUtils.rm_rf(staged_path)
        FileUtils.mkdir_p(File.dirname(staged_path))

        if File.directory?(source_path)
          FileUtils.cp_r(source_path, File.dirname(staged_path))
        else
          FileUtils.cp(source_path, File.dirname(staged_path))
        end
      end
    end

    def write_bundle_archive
      return nil unless @archive

      archive_path = bundle_archive_path
      FileUtils.rm_f(archive_path)
      FileUtils.mkdir_p(File.dirname(archive_path))

      Tempfile.create(["milk-tea-bundle", ".tar"]) do |tar_file|
        Gem::Package::TarWriter.new(tar_file) do |tar|
          add_archive_tree(tar, @bundle_root, File.basename(@bundle_root))
        end

        tar_file.flush
        tar_file.rewind

        Zlib::GzipWriter.open(archive_path) do |gzip|
          IO.copy_stream(tar_file, gzip)
        end
      end

      archive_path
    end

    def bundle_archive_path
      "#{@bundle_root}.tar.gz"
    end

    def add_archive_tree(tar, source_path, archive_path)
      stat = File.lstat(source_path)

      if stat.directory?
        tar.mkdir(archive_path, stat.mode & 0o777)
        Dir.children(source_path).sort.each do |child|
          add_archive_tree(tar, File.join(source_path, child), File.join(archive_path, child))
        end
      elsif stat.file?
        tar.add_file(archive_path, stat.mode & 0o777) do |io|
          File.open(source_path, "rb") do |file|
            IO.copy_stream(file, io)
          end
        end
      end
    end

    def runtime_asset_mappings_for(target_path)
      return [] if @assets_paths.empty?
      return [] if target_wasm?

      @assets_paths.filter_map do |assets_path|
        staged_path = File.join(File.dirname(target_path), File.basename(assets_path))
        next if staged_path == assets_path

        [assets_path, staged_path]
      end
    end

    def runtime_assets_packed?
      @bundle && !target_wasm? && !@assets_paths.empty?
    end

    def runtime_asset_pack_path_for(target_path)
      File.join(File.dirname(target_path), "assets.mtpack")
    end

    def ensure_runtime_assets_do_not_overlap_source!(source_path, staged_path)
      return unless File.directory?(source_path)
      return unless path_within?(staged_path, source_path)

      raise BuildError, "native runtime asset output would be written inside build.assets source tree: #{staged_path}"
    end

    def path_within?(path, root)
      normalized_path = File.expand_path(path)
      normalized_root = File.expand_path(root)
      normalized_path == normalized_root || normalized_path.start_with?(normalized_root + File::SEPARATOR)
    end

    def target_windows?
      @platform == :windows
    end

    def target_wasm?
      @platform == :wasm
    end

    def artifact_extension
      return ".html" if target_wasm?
      return ".exe" if target_windows?

      ""
    end

    def profile_compiler_flags
      return ["-g", "-O0"] if @debug || @profile == :debug

      ["-O3", "-DNDEBUG"]
    end

    def line_directives_required?
      @debug || @profile == :debug
    end

    def compiler_available?(compiler)
      return File.file?(compiler) && File.executable?(compiler) if compiler.include?(File::SEPARATOR)

      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |entry|
        candidate = File.join(entry, compiler)
        File.file?(candidate) && File.executable?(candidate)
      end
    end

    def compiler_command_name(compiler)
      File.basename(compiler).downcase.sub(/\.(?:exe|bat|cmd|com|sh|py)\z/, "")
    end

    def emscripten_backend?(compiler)
      compiler_command_name(compiler).split(/[-_.]/).include?("emcc")
    end

    def msvc_style_backend?(compiler)
      tokens = compiler_command_name(compiler).split(/[-_.]/)
      tokens.last == "cl" || tokens.last(2) == %w[clang cl]
    end
  end
end
