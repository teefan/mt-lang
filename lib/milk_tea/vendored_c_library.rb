# frozen_string_literal: true

require "fileutils"
require "open3"
require "pathname"
require "shellwords"

module MilkTea
  module VendoredCLibrary
    class Error < RawBindings::Error; end

    class Base
      attr_reader :name, :source_root, :include_roots

      def initialize(name:, source_root:, include_roots: [], cc_env_var: nil)
        @name = name.to_s
        @source_root = Pathname.new(File.expand_path(source_root.to_s))
        @include_roots = include_roots.map { |path| Pathname.new(File.expand_path(path.to_s)) }.freeze
        @cc_env_var = cc_env_var
      end

      def include_flags
        include_roots.map { |path| "-I#{path}" }
      end

      def prepare!(env: ENV, cc: ENV.fetch("CC", "cc"))
        raise NotImplementedError, "#{self.class} must implement #prepare!"
      end

      def link_flags
        raise NotImplementedError, "#{self.class} must implement #link_flags"
      end

      private

      def resolved_cc(env, default_cc)
        return default_cc unless @cc_env_var

        env.fetch(@cc_env_var, default_cc)
      end

      def signature_path(root)
        root.join(".milk-tea-signature")
      end

      def read_signature(root)
        path = signature_path(root)
        return unless File.exist?(path)

        File.read(path)
      end

      def write_signature(root, value)
        File.write(signature_path(root), value)
      end

      def newest_tree_file_mtime(root)
        Dir.glob(File.join(root.to_s, "**", "*"))
          .select { |path| File.file?(path) }
          .map { |path| File.mtime(path) }
          .max
      end

      def command_error(label, stdout, stderr)
        details = [stdout, stderr].reject(&:empty?).join
        details.empty? ? label : "#{label}:\n#{details}"
      end

      def tool_not_found(error)
        Error.new("tool not found while building vendored #{name}: #{error.message}")
      end
    end

    class Archive < Base
      attr_reader :build_root, :archive_path, :sources, :defines

      def initialize(name:, source_root:, build_root:, archive_name:, sources:, include_roots: [], defines: [], system_link_flags: [], cc_env_var: nil, ar_env_var: nil)
        resolved_include_roots = include_roots.empty? ? [source_root] : include_roots
        super(name:, source_root:, include_roots: resolved_include_roots, cc_env_var:)
        @build_root = Pathname.new(File.expand_path(build_root.to_s))
        @archive_path = @build_root.join(archive_name)
        @sources = sources.dup.freeze
        @defines = defines.dup.freeze
        @system_link_flags = system_link_flags.dup.freeze
        @ar_env_var = ar_env_var
      end

      def link_flags
        ["-L#{build_root}", *@system_link_flags]
      end

      def prepare!(env: ENV, cc: ENV.fetch("CC", "cc"))
        resolved_cc = resolved_cc(env, cc)
        resolved_ar = env.fetch(@ar_env_var || "AR", "ar")
        signature = configuration_signature(cc: resolved_cc, ar: resolved_ar)
        signature_changed = signature != read_signature(build_root)

        FileUtils.mkdir_p(build_root)
        object_paths = sources.map do |source|
          build_object(source, cc: resolved_cc, force_rebuild: signature_changed)
        end
        return archive_path.to_s if !signature_changed && archive_up_to_date?(object_paths)

        stdout, stderr, status = Open3.capture3(resolved_ar, "rcs", archive_path.to_s, *object_paths)
        unless status.success?
          raise Error, command_error("failed to archive vendored #{name}", stdout, stderr)
        end

        write_signature(build_root, signature)
        archive_path.to_s
      rescue Errno::ENOENT => e
        raise tool_not_found(e)
      end

      private

      def configuration_signature(cc:, ar:)
        [cc, ar, *include_flags, *defines].join("\0")
      end

      def build_object(source, cc:, force_rebuild:)
        source_path = source_root.join(source)
        object_path = build_root.join(source.sub(/\.c\z/, ".o"))
        if !force_rebuild && File.exist?(object_path) && File.mtime(object_path) >= File.mtime(source_path)
          return object_path.to_s
        end

        command = [
          cc,
          "-c",
          source_path.to_s,
          *include_flags,
          *defines.map { |define| "-D#{define}" },
          "-o",
          object_path.to_s,
        ]
        stdout, stderr, status = Open3.capture3(*command)
        unless status.success?
          raise Error, command_error("failed to compile vendored #{name} source #{source}", stdout, stderr)
        end

        object_path.to_s
      end

      def archive_up_to_date?(object_paths)
        return false unless File.exist?(archive_path)

        archive_mtime = File.mtime(archive_path)
        object_paths.all? { |path| File.mtime(path) <= archive_mtime }
      end
    end

    class CMake < Base
      attr_reader :build_root, :install_root, :archive_path

      def initialize(name:, source_root:, build_root:, install_root:, archive_path:, include_roots: [], configure_args: [], build_target: "install", system_link_flags: [], pkg_config_name: nil, cc_env_var: nil, cmake_env_var: nil)
        super(name:, source_root:, include_roots:, cc_env_var:)
        @build_root = Pathname.new(File.expand_path(build_root.to_s))
        @install_root = Pathname.new(File.expand_path(install_root.to_s))
        @archive_path = Pathname.new(File.expand_path(archive_path.to_s))
        @configure_args = configure_args.dup.freeze
        @build_target = build_target
        @system_link_flags = system_link_flags.dup.freeze
        @pkg_config_name = pkg_config_name
        @cmake_env_var = cmake_env_var
      end

      def link_flags
        ["-L#{archive_path.dirname}", *pkg_config_link_flags, *@system_link_flags].uniq
      end

      def prepare!(env: ENV, cc: ENV.fetch("CC", "cc"))
        resolved_cc = resolved_cc(env, cc)
        resolved_cmake = env.fetch(@cmake_env_var || "CMAKE", "cmake")
        signature = configuration_signature(cc: resolved_cc, cmake: resolved_cmake)
        needs_configure = signature != read_signature(build_root) || !File.exist?(build_root.join("CMakeCache.txt"))
        needs_build = !archive_up_to_date?
        return archive_path.to_s unless needs_configure || needs_build

        FileUtils.mkdir_p(build_root)
        FileUtils.mkdir_p(install_root)
        configure(cmake: resolved_cmake, cc: resolved_cc)
        build(cmake: resolved_cmake)
        unless File.exist?(archive_path)
          raise Error, "failed to build vendored #{name}: missing #{archive_path}"
        end

        write_signature(build_root, signature)
        archive_path.to_s
      rescue Errno::ENOENT => e
        raise tool_not_found(e)
      end

      private

      def configuration_signature(cc:, cmake:)
        [cmake, cc, install_root.to_s, *include_flags, *@configure_args, @build_target].join("\0")
      end

      def archive_up_to_date?
        return false unless File.exist?(archive_path)

        newest_source_mtime = newest_tree_file_mtime(source_root)
        return true unless newest_source_mtime

        newest_source_mtime <= File.mtime(archive_path)
      end

      def configure(cmake:, cc:)
        command = [
          cmake,
          "-S",
          source_root.to_s,
          "-B",
          build_root.to_s,
          "-G",
          "Ninja",
          "-DCMAKE_INSTALL_PREFIX=#{install_root}",
          *@configure_args,
        ]
        stdout, stderr, status = Open3.capture3({ "CC" => cc }, *command)
        unless status.success?
          raise Error, command_error("failed to configure vendored #{name}", stdout, stderr)
        end
      end

      def build(cmake:)
        command = [cmake, "--build", build_root.to_s, "--target", @build_target]
        stdout, stderr, status = Open3.capture3(*command)
        unless status.success?
          raise Error, command_error("failed to build vendored #{name}", stdout, stderr)
        end
      end

      def pkg_config_link_flags
        return [] unless @pkg_config_name

        path = install_root.join("lib/pkgconfig/#{@pkg_config_name}.pc")
        return [] unless File.exist?(path)

        lines = File.readlines(path, chomp: true)
        variables = pkg_config_variables(lines)
        lines.filter_map do |line|
          line.split(":", 2).last&.strip if line.start_with?("Libs:", "Libs.private:")
        end.flat_map do |value|
          Shellwords.split(expand_pkg_config_value(value, variables))
        end
      end

      def pkg_config_variables(lines)
        variables = {
          "prefix" => install_root.to_s,
          "exec_prefix" => install_root.to_s,
          "libdir" => archive_path.dirname.to_s,
          "includedir" => install_root.join("include").to_s,
        }

        lines.each do |line|
          next if line.empty? || line.start_with?("#") || line.include?(":") || !line.include?("=")

          key, value = line.split("=", 2)
          variables[key] = expand_pkg_config_value(value, variables)
        end

        variables
      end

      def expand_pkg_config_value(value, variables)
        value.gsub(/\$\{([^}]+)\}/) { variables.fetch(Regexp.last_match(1), "") }
      end
    end
  end
end
