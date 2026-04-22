# frozen_string_literal: true

require "open3"
require "tmpdir"

module MilkTea
  class RunError < StandardError; end

  class Run
    Result = Data.define(:stdout, :stderr, :exit_status, :output_path, :c_path, :compiler, :link_flags)

    def self.run(path, output_path: nil, cc: ENV.fetch("CC", "cc"), keep_c_path: nil)
      new(path, output_path:, cc:, keep_c_path:).run
    end

    def initialize(path, output_path:, cc:, keep_c_path:)
      @source_path = File.expand_path(path)
      @output_path = output_path ? File.expand_path(output_path) : nil
      @cc = cc
      @keep_c_path = keep_c_path ? File.expand_path(keep_c_path) : nil
    end

    def run
      if @output_path
        return run_binary(@output_path)
      end

      Dir.mktmpdir("milk-tea-run") do |dir|
        binary_path = File.join(dir, File.basename(@source_path, ".mt"))
        run_binary(binary_path)
      end
    end

    private

    def run_binary(binary_path)
      build_result = Build.build(@source_path, output_path: binary_path, cc: @cc, keep_c_path: @keep_c_path)
      stdout, stderr, status = Open3.capture3(build_result.output_path, chdir: File.dirname(@source_path))

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
  end
end
