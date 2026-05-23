# frozen_string_literal: true

require_relative "vendored_c_library"

module MilkTea
  module VendoredBox2D
    Error = VendoredCLibrary::Error

    CONFIGURE_ARGS = %w[
      -DCMAKE_BUILD_TYPE=Release
      -DCMAKE_POSITION_INDEPENDENT_CODE=ON
      -DBUILD_SHARED_LIBS=OFF
      -DBOX2D_SAMPLES=OFF
      -DBOX2D_BENCHMARKS=OFF
      -DBOX2D_DOCS=OFF
      -DBOX2D_PROFILE=OFF
      -DBOX2D_VALIDATE=OFF
      -DBOX2D_UNIT_TESTS=OFF
    ].freeze

    SYSTEM_LINK_FLAGS = %w[
      -lm
    ].freeze

    module_function

    def library(root: MilkTea.root)
      resolved_root = Pathname.new(File.expand_path(root.to_s))
      @libraries ||= {}
      @libraries[resolved_root.to_s] ||= VendoredCLibrary::CMake.new(
        name: "box2d",
        source_root: source_root(root: resolved_root),
        build_root: build_root(root: resolved_root),
        install_root: install_root(root: resolved_root),
        archive_path: archive_path(root: resolved_root),
        include_roots: [include_root(root: resolved_root)],
        configure_args: CONFIGURE_ARGS,
        system_link_flags: SYSTEM_LINK_FLAGS,
        cc_env_var: "BOX2D_CC",
      )
    end

    def source_root(root: MilkTea.root)
      Pathname.new(File.expand_path(root.to_s)).join("third_party/box2d-upstream")
    end

    def include_root(root: MilkTea.root)
      source_root(root:).join("include")
    end

    def header_root(root: MilkTea.root)
      include_root(root:).join("box2d")
    end

    def build_root(root: MilkTea.root)
      Pathname.new(File.expand_path(root.to_s)).join("tmp/vendored-box2d")
    end

    def install_root(root: MilkTea.root)
      Pathname.new(File.expand_path(root.to_s)).join("tmp/vendored-box2d-prefix")
    end

    def archive_path(root: MilkTea.root)
      install_root(root:).join("lib/libbox2d.a")
    end

    def include_flags(root: MilkTea.root)
      library(root:).include_flags
    end

    def link_flags(root: MilkTea.root)
      library(root:).link_flags
    end

    def prepare!(root: MilkTea.root, **kwargs)
      library(root:).prepare!(**kwargs)
    end
  end
end
