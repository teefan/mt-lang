# frozen_string_literal: true

require "fileutils"
require "open3"
require "tempfile"

require_relative "debug_map"

module MilkTea
  class BuildError < StandardError; end

  class Build
    Result = Data.define(:output_path, :c_path, :compiler, :link_flags, :profile, :platform)

    def self.build(path, output_path: nil, cc: ENV.fetch("CC", "cc"), keep_c_path: nil, raw_bindings: nil, module_roots: nil, debug: false, profile: nil, platform: nil)
      raw_bindings ||= default_raw_bindings
      new(path, output_path:, cc:, keep_c_path:, raw_bindings:, module_roots:, debug:, profile:, platform:).build
    end

    def self.clean(path, output_path: nil, profile: nil, platform: nil)
      new(
        path,
        output_path:,
        cc: ENV.fetch("CC", "cc"),
        keep_c_path: nil,
        raw_bindings: nil,
        module_roots: nil,
        debug: false,
        profile:,
        platform:
      ).clean
    end

    def self.default_raw_bindings(root: MilkTea.root)
      require_relative "../bindings"

      RawBindings.default_registry(root:)
    end
    private_class_method :default_raw_bindings

    def initialize(path, output_path:, cc:, keep_c_path:, raw_bindings:, module_roots: nil, debug: false, profile: nil, platform: nil)
      manifest = PackageManifest.load(path)
      @package_build = true
      @source_path = manifest.source_path
      @project_root = manifest.root_dir
      @package_name = manifest.package_name
      @profile = normalize_profile(profile || manifest.profile || (debug ? :debug : :debug))
      @platform = normalize_platform(platform || manifest.platform || host_platform)
      @manifest_output_path = manifest.output_path
      @explicit_output_path = !output_path.nil?
      resolved_output = output_path || manifest.output_path || default_package_output_path
      @output_path = File.expand_path(resolved_output)
      @cc = cc
      @keep_c_path = keep_c_path ? File.expand_path(keep_c_path) : nil
      @raw_bindings = raw_bindings
      @module_roots = (module_roots || [MilkTea.root]).dup
      @module_roots << manifest.root_dir unless @module_roots.include?(manifest.root_dir)
      @debug = debug
    rescue PackageManifestError => e
      raise BuildError, e.message if File.directory?(path)

      @package_build = false
      @source_path = File.expand_path(path)
      @project_root = File.dirname(@source_path)
      @package_name = File.basename(@project_root).tr("-", "_")
      @profile = normalize_profile(profile || (debug ? :debug : :debug))
      @platform = normalize_platform(platform || host_platform)
      @manifest_output_path = nil
      @explicit_output_path = !output_path.nil?
      @output_path = File.expand_path(output_path || default_source_output_path(@source_path))
      @cc = cc
      @keep_c_path = keep_c_path ? File.expand_path(keep_c_path) : nil
      @raw_bindings = raw_bindings
      @module_roots = module_roots || [MilkTea.root]
      @debug = debug
    end

    def clean
      target_path = clean_target_path
      if File.directory?(target_path)
        FileUtils.rm_rf(target_path)
      else
        FileUtils.rm_f(target_path)
        FileUtils.rm_f(DebugMap.sidecar_path_for(@output_path))
      end
      target_path
    end

    def build
      ensure_compiler_available!
      program = ModuleLoader.new(module_roots: @module_roots).check_program(@source_path)
      prepare_bindings(program)
      ir_program = program.is_a?(IR::Program) ? program : Lowering.lower(program)
      emit_line_directives = line_directives_required?
      compiled_c = CBackend.emit(ir_program, emit_line_directives: emit_line_directives)
      debug_map = DebugMap.from_ir(ir_program, binary_path: @output_path)
      compiler_flags = collect_compiler_flags(program)
      link_flags = collect_link_flags(program)
      debug_map_path = DebugMap.sidecar_path_for(@output_path)

      FileUtils.mkdir_p(File.dirname(@output_path))

      if @keep_c_path
        saved_c = if emit_line_directives
                    CBackend.emit(ir_program, emit_line_directives: false)
                  else
                    compiled_c
                  end
        write_c_file(@keep_c_path, saved_c)
        if emit_line_directives
          compile_generated_c(compiled_c, compiler_flags, link_flags)
        else
          compile(@keep_c_path, compiler_flags, link_flags)
        end
        debug_map.write(debug_map_path)
        return Result.new(output_path: @output_path, c_path: @keep_c_path, compiler: @cc, link_flags:, profile: @profile, platform: @platform)
      end

      compile_generated_c(compiled_c, compiler_flags, link_flags)

      debug_map.write(debug_map_path)

      Result.new(output_path: @output_path, c_path: nil, compiler: @cc, link_flags:, profile: @profile, platform: @platform)
    end

    private

    def clean_target_path
      if @package_build && !@explicit_output_path && @manifest_output_path.nil?
        File.join(@project_root, "build")
      else
        @output_path
      end
    end

    def default_source_output_path(source_path)
      source_path.sub(/\.mt\z/, "")
    end

    def default_package_output_path
      build_root = File.join(@project_root, "build")
      File.join(build_root, "bin", @platform.to_s, @profile.to_s, "#{@package_name}#{executable_extension}")
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
      else
        raise BuildError, "unknown platform #{value}; expected linux|windows"
      end
    end

    def prepare_bindings(program)
      program.analyses_by_module_name.keys.sort.each do |module_name|
        analysis = program.analyses_by_module_name.fetch(module_name)
        next unless analysis.module_kind == :extern_module

        binding = @raw_bindings.find_by_module_name(module_name)
        next unless binding

        binding.prepare!(cc: @cc)
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

    def collect_link_flags(program)
      program.analyses_by_module_name.keys.sort.each_with_object([]) do |module_name, flags|
        analysis = program.analyses_by_module_name.fetch(module_name)
        next unless analysis.module_kind == :extern_module

        binding = @raw_bindings.find_by_module_name(module_name)
        if binding
          binding.link_flags.grep(/\A-L/).each do |flag|
            flags << flag unless flags.include?(flag)
          end
        end

        analysis.directives.grep(AST::LinkDirective).each do |directive|
          flag = "-l#{directive.value}"
          flags << flag unless flags.include?(flag)
        end

        if binding
          binding.link_flags.reject { |flag| flag.start_with?("-L") }.each do |flag|
            flags << flag unless flags.include?(flag)
          end
        end
      end
    end

    def collect_compiler_flags(program)
      program.analyses_by_module_name.keys.sort.each_with_object([]) do |module_name, flags|
        analysis = program.analyses_by_module_name.fetch(module_name)
        next unless analysis.module_kind == :extern_module

        binding = @raw_bindings.find_by_module_name(module_name)
        next unless binding

        binding.build_flags.each do |flag|
          flags << flag unless flags.include?(flag)
        end
      end
    rescue RawBindings::Error => e
      raise BuildError, e.message
    end

    def compile(c_path, compiler_flags, link_flags)
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
      /mswin|mingw|cygwin/ === RUBY_PLATFORM ? :windows : :linux
    end

    def target_windows?
      @platform == :windows
    end

    def executable_extension
      target_windows? ? ".exe" : ""
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
  end
end
