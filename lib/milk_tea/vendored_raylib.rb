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

    def library
      @library ||= VendoredCLibrary::Archive.new(
        name: "raylib",
        source_root: source_root,
        build_root: build_root,
        archive_name: "libraylib.a",
        sources: SOURCES,
        include_roots: [source_root],
        defines: DEFINES,
        system_link_flags: SYSTEM_LINK_FLAGS,
        cc_env_var: "RAYLIB_CC",
      )
    end

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
      library.link_flags
    end

    def prepare!(**kwargs)
      library.prepare!(**kwargs)
    end
  end
end
