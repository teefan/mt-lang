# frozen_string_literal: true

require "fileutils"

module MilkTea
  module VendoredSteamworks
    Error = VendoredCLibrary::Error

    module_function

    def library(root: MilkTea.root)
      @libraries ||= {}
      @libraries[root.to_s] ||= Library.new(root:)
    end

    class Library < VendoredCLibrary::Base
      attr_reader :build_root, :root

      def initialize(root: MilkTea.root)
        @root = Pathname.new(File.expand_path(root.to_s))
        @build_root = @root.join("tmp/vendored-steamworks")
        super(name: "steamworks", source_root: @root.join("third_party/steamworks-sdk-upstream"))
      end

      def link_flags(platform: nil)
        resolved_platform = platform || host_platform

        case resolved_platform
        when :windows
          copied_import_library = build_root.join(MilkTea::Steamworks::IMPORT_LIBRARY_BASENAME_BY_PLATFORM.fetch(resolved_platform))
          return [copied_import_library.to_s] if File.file?(copied_import_library)

          ["-L#{build_root}"]
        else
          ["-L#{build_root}"]
        end
      end

      def prepare!(env: ENV, cc: ENV.fetch("CC", "cc"), platform: nil)
        _resolved_cc = resolved_cc(env, cc)
        FileUtils.mkdir_p(build_root)

        resolved_platform = platform || host_platform
        import_library = MilkTea::Steamworks.import_library_path(root:, env:, platform: resolved_platform, bootstrap: true)
        runtime_library = MilkTea::Steamworks.runtime_library_path(root:, env:, platform: resolved_platform, bootstrap: true)

        copy_if_present(import_library)
        copy_if_present(runtime_library)
      rescue Errno::ENOENT => e
        raise tool_not_found(e)
      end

      private

      def copy_if_present(path)
        return unless path && File.file?(path)

        destination = build_root.join(path.basename)
        return destination.to_s if File.file?(destination) && File.mtime(destination) >= File.mtime(path)

        FileUtils.cp(path, destination)
        destination.to_s
      end

      def host_platform
        MilkTea::Steamworks.host_platform
      end
    end
  end
end
