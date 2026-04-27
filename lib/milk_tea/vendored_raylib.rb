# frozen_string_literal: true

require "fileutils"
require "open3"

module MilkTea
  module VendoredRaylib
    class Error < RawBindings::Error; end

    SOURCES = %w[
      rcore.c
      rshapes.c
      rtextures.c
      rtext.c
      rmodels.c
      raudio.c
    ].freeze

    DEFINES = %w[
      PLATFORM_DESKTOP_GLFW
      GRAPHICS_API_OPENGL_43
    ].freeze

    SYSTEM_LINK_FLAGS = %w[
      -lglfw
      -lm
      -ldl
      -lpthread
      -lrt
      -lX11
    ].freeze

    module_function

    def source_root
      MilkTea.root.join("third_party/raylib-upstream/src")
    end

    def build_root
      MilkTea.root.join("tmp/vendored-raylib-opengl43")
    end

    def archive_path
      build_root.join("libraylib.a")
    end

    def link_flags
      ["-L#{build_root}", *SYSTEM_LINK_FLAGS]
    end

    def prepare!(cc: ENV.fetch("CC", "cc"), ar: ENV.fetch("AR", "ar"))
      FileUtils.mkdir_p(build_root)
      object_paths = SOURCES.map { |source| build_object(source, cc:) }
      return archive_path.to_s if archive_up_to_date?(object_paths)

      stdout, stderr, status = Open3.capture3(ar, "rcs", archive_path.to_s, *object_paths)
      return archive_path.to_s if status.success?

      details = [stdout, stderr].reject(&:empty?).join
      raise Error, details.empty? ? "failed to archive vendored raylib" : "failed to archive vendored raylib:\n#{details}"
    rescue Errno::ENOENT => e
      raise Error, "tool not found while building vendored raylib: #{e.message}"
    end

    def build_object(source, cc:)
      source_path = source_root.join(source)
      object_path = build_root.join(source.sub(/\.c\z/, ".o"))
      return object_path.to_s if File.exist?(object_path) && File.mtime(object_path) >= File.mtime(source_path)

      command = [
        cc,
        "-c",
        source_path.to_s,
        "-I#{source_root}",
        *DEFINES.map { |define| "-D#{define}" },
        "-o",
        object_path.to_s,
      ]
      stdout, stderr, status = Open3.capture3(*command)
      return object_path.to_s if status.success?

      details = [stdout, stderr].reject(&:empty?).join
      raise Error, details.empty? ? "failed to compile vendored raylib source #{source}" : "failed to compile vendored raylib source #{source}:\n#{details}"
    rescue Errno::ENOENT
      raise Error, "C compiler not found while building vendored raylib: #{cc}"
    end

    def archive_up_to_date?(object_paths)
      return false unless File.exist?(archive_path)

      archive_mtime = File.mtime(archive_path)
      object_paths.all? { |path| File.mtime(path) <= archive_mtime }
    end
  end
end
