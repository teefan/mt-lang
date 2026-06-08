# frozen_string_literal: true

module MilkTea
  class VendoredTool
    class Error < StandardError; end

    attr_reader :name, :source_dir, :build_dir, :output_binary_name, :cmake_args

    def initialize(name:, source_dir:, build_dir:, output_binary_name:, cmake_args: [])
      @name = name
      @source_dir = File.expand_path(source_dir)
      @build_dir = File.expand_path(build_dir)
      @output_binary_name = output_binary_name
      @cmake_args = cmake_args.dup.freeze
    end

    def binary_path
      File.join(@build_dir, @output_binary_name)
    end

    def install_path(root: MilkTea.root)
      File.join(root, "bin", @output_binary_name)
    end

    def built?
      File.file?(binary_path) && File.executable?(binary_path)
    end

    def build!
      return binary_path if built?

      FileUtils.mkdir_p(@build_dir)

      run_cmake!
      run_make!

      raise Error, "tool #{@name} built but binary not found at #{binary_path}" unless built?

      binary_path
    end

    private

    def run_cmake!
      args = [
        "cmake",
        "-S", @source_dir,
        "-B", @build_dir,
        "-DCMAKE_BUILD_TYPE=Release",
        *cmake_args,
      ]
      stdout, stderr, status = Open3.capture3(*args)
      return if status.success?

      details = [stdout, stderr].reject(&:empty?).join
      raise Error, "cmake configure failed for #{name}:\n#{details}"
    rescue Errno::ENOENT => e
      raise Error, "cmake not found while building #{name}: #{e.message}"
    end

    def run_make!
      nproc = Etc.nprocessors
      args = ["cmake", "--build", @build_dir, "-j#{nproc}"]
      stdout, stderr, status = Open3.capture3(*args)
      return if status.success?

      details = [stdout, stderr].reject(&:empty?).join
      raise Error, "build failed for #{name}:\n#{details}"
    end
  end
end
