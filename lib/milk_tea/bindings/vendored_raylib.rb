# frozen_string_literal: true

module MilkTea
  module VendoredRaylib
    Error = VendoredCLibrary::Error

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

    def library(root: MilkTea.root)
      resolved_root = Pathname.new(File.expand_path(root.to_s))
      @libraries ||= {}
      @libraries[resolved_root.to_s] ||= VendoredCLibrary::Archive.new(
        name: "raylib",
        source_root: source_root(root: resolved_root),
        build_root: build_root(root: resolved_root),
        archive_name: "libraylib.a",
        sources: SOURCES,
        include_roots: [source_root(root: resolved_root)],
        defines: DEFINES,
        system_link_flags: SYSTEM_LINK_FLAGS,
        cc_env_var: "RAYLIB_CC",
      )
    end

    def source_root(root: MilkTea.root)
      Pathname.new(File.expand_path(root.to_s)).join("third_party/raylib-upstream/src")
    end

    def build_root(root: MilkTea.root)
      Pathname.new(File.expand_path(root.to_s)).join("tmp/vendored-raylib-opengl43")
    end

    def archive_path(root: MilkTea.root)
      build_root(root:).join("libraylib.a")
    end

    def link_flags(root: MilkTea.root)
      library(root:).link_flags
    end

    def prepare!(root: MilkTea.root, **kwargs)
      library(root:).prepare!(**kwargs)
    end
  end
end
