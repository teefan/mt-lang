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

    DESKTOP_DEFINES = %w[
      PLATFORM_DESKTOP_GLFW
      GRAPHICS_API_OPENGL_43
    ].freeze

    DESKTOP_SYSTEM_LINK_FLAGS = %w[
      -lglfw
      -lm
      -ldl
      -lpthread
      -lrt
      -lX11
    ].freeze

    WASM_DEFINES = %w[
      PLATFORM_WEB
      GRAPHICS_API_OPENGL_ES2
      MA_ENABLE_AUDIO_WORKLETS
    ].freeze

    WASM_SYSTEM_LINK_FLAGS = %w[
      -sUSE_GLFW=3
      -sAUDIO_WORKLET=1
      -sWASM_WORKERS=1
      -sASYNCIFY
    ].freeze

    WASM_COMPILE_FLAGS = %w[
      -sAUDIO_WORKLET=1
      -sWASM_WORKERS=1
    ].freeze

    class AdaptiveArchive < VendoredCLibrary::Base
      def initialize(root:)
        sr = VendoredRaylib.source_root(root:)
        super(
          name: "raylib",
          source_root: sr,
          include_roots: [sr],
          cc_env_var: "RAYLIB_CC",
        )
        @desktop_archive = VendoredCLibrary::Archive.new(
          name: "raylib",
          source_root: sr,
          build_root: VendoredRaylib.build_root(root:),
          archive_name: "libraylib.a",
          sources: SOURCES,
          include_roots: [sr],
          defines: DESKTOP_DEFINES,
          system_link_flags: DESKTOP_SYSTEM_LINK_FLAGS,
          cc_env_var: "RAYLIB_CC",
        )
        @wasm_archive = VendoredCLibrary::Archive.new(
          name: "raylib",
          source_root: sr,
          build_root: VendoredRaylib.build_root(root:, platform: :wasm),
          archive_name: "libraylib.a",
          sources: SOURCES,
          include_roots: [sr],
          defines: WASM_DEFINES,
          c_flags: WASM_COMPILE_FLAGS,
          system_link_flags: WASM_SYSTEM_LINK_FLAGS,
          cc_env_var: "RAYLIB_CC",
          default_ar: "emar",
        )
      end

      def link_flags(platform: nil)
        archive_for(platform).link_flags
      end

      def build_flags(platform: nil)
        archive_for(platform).build_flags
      end

      def prepare!(env: ENV, cc: ENV.fetch("CC", "cc"), platform: nil)
        archive_for(platform).prepare!(env:, cc:, platform:)
      end

      private

      def archive_for(platform)
        platform == :wasm ? @wasm_archive : @desktop_archive
      end
    end

    module_function

    def library(root: MilkTea.root)
      resolved_root = Pathname.new(File.expand_path(root.to_s))
      @libraries ||= {}
      @libraries[resolved_root.to_s] ||= AdaptiveArchive.new(root: resolved_root)
    end

    def source_root(root: MilkTea.root)
      MilkTea.writable_root_for(root).join("third_party/raylib-upstream/src")
    end

    def build_root(root: MilkTea.root, platform: nil)
      suffix = platform == :wasm ? "tmp/vendored-raylib-web" : "tmp/vendored-raylib-opengl43"
      MilkTea.writable_root_for(root).join(suffix)
    end

    def archive_path(root: MilkTea.root, platform: nil)
      build_root(root:, platform:).join("libraylib.a")
    end

    def link_flags(root: MilkTea.root, platform: nil)
      library(root:).link_flags(platform:)
    end

    def prepare!(root: MilkTea.root, platform: nil, **kwargs)
      library(root:).prepare!(platform:, **kwargs)
    end
  end
end
