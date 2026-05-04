# frozen_string_literal: true

require "open3"
require "tmpdir"

module MilkTea
  class RunError < StandardError; end

  class Run
    Result = Data.define(:stdout, :stderr, :exit_status, :output_path, :c_path, :compiler, :link_flags)

    def self.run(path, output_path: nil, cc: ENV.fetch("CC", "cc"), keep_c_path: nil, module_roots: nil, profile: nil, platform: nil)
      new(path, output_path:, cc:, keep_c_path:, module_roots:, profile:, platform:).run
    end

    def initialize(path, output_path:, cc:, keep_c_path:, module_roots: nil, profile: nil, platform: nil)
      @input_path = File.expand_path(path)
      @project_root = File.directory?(@input_path) ? @input_path : File.dirname(@input_path)
      @output_path = output_path ? File.expand_path(output_path) : nil
      @cc = cc
      @keep_c_path = keep_c_path ? File.expand_path(keep_c_path) : nil
      @module_roots = module_roots
      @profile = profile
      @platform = platform
    end

    def run
      if @output_path
        return run_binary(@output_path)
      end

      Dir.mktmpdir("milk-tea-run") do |dir|
        binary_path = File.join(dir, File.basename(@input_path, ".mt"))
        run_binary(binary_path)
      end
    end

    private

    def run_binary(binary_path)
      build_result = Build.build(@input_path, output_path: binary_path, cc: @cc, keep_c_path: @keep_c_path, module_roots: @module_roots, profile: @profile, platform: @platform)
      unless build_result.platform == host_platform
        raise RunError, "run target platform is #{build_result.platform}; host platform is #{host_platform}"
      end

      stdout, stderr, status = Open3.capture3(build_result.output_path, chdir: @project_root)

      Result.new(
        stdout:,
        stderr:,
        exit_status: process_exit_status(status),
        output_path: @output_path,
        c_path: build_result.c_path,
        compiler: build_result.compiler,
        link_flags: build_result.link_flags,
      )
    rescue Errno::ENOENT
      raise RunError, "built program not found: #{binary_path}"
    end

    def process_exit_status(status)
      return status.exitstatus if status.exited?
      return 128 + status.termsig if status.signaled?

      1
    end

    def host_platform
      /mswin|mingw|cygwin/ === RUBY_PLATFORM ? :windows : :linux
    end
  end
end
