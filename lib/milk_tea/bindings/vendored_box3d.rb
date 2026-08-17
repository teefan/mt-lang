# frozen_string_literal: true

require_relative "vendored_c_library"

module MilkTea
  module VendoredBox3D
    Error = VendoredCLibrary::Error

    CONFIGURE_ARGS = %w[
      -DCMAKE_BUILD_TYPE=Release
      -DCMAKE_POSITION_INDEPENDENT_CODE=ON
      -DBUILD_SHARED_LIBS=OFF
      -DBOX3D_SAMPLES=OFF
      -DBOX3D_BENCHMARKS=OFF
      -DBOX3D_DOCS=OFF
      -DBOX3D_PROFILE=OFF
      -DBOX3D_VALIDATE=OFF
      -DBOX3D_UNIT_TESTS=OFF
    ].freeze

    SYSTEM_LINK_FLAGS = %w[
      -lm
    ].freeze

    def self.library(root: MilkTea.root)
      resolved_root = Pathname.new(File.expand_path(root.to_s))
      @libraries ||= {}
      @libraries[resolved_root.to_s] ||= VendoredCLibrary::CMake.new(
        name: "box3d",
        source_root: source_root(root: resolved_root),
        build_root: build_root(root: resolved_root),
        install_root: install_root(root: resolved_root),
        archive_path: archive_path(root: resolved_root),
        include_roots: [include_root(root: resolved_root)],
        configure_args: CONFIGURE_ARGS,
        system_link_flags: SYSTEM_LINK_FLAGS,
        cc_env_var: "BOX3D_CC",
      )
    end

    def self.source_root(root: MilkTea.root)
      MilkTea.writable_root_for(root).join("third_party/box3d-upstream")
    end

    def self.include_root(root: MilkTea.root)
      source_root(root:).join("include")
    end

    def self.header_root(root: MilkTea.root)
      include_root(root:).join("box3d")
    end

    def self.build_root(root: MilkTea.root)
      MilkTea.writable_root_for(root).join("tmp/vendored-box3d")
    end

    def self.install_root(root: MilkTea.root)
      MilkTea.writable_root_for(root).join("tmp/vendored-box3d-prefix")
    end

    def self.archive_path(root: MilkTea.root)
      install_root(root:).join("lib/libbox3d.a")
    end

    def self.include_flags(root: MilkTea.root)
      library(root:).include_flags
    end

    def self.link_flags(root: MilkTea.root)
      library(root:).link_flags
    end

    def self.prepare!(root: MilkTea.root, **kwargs)
      library(root:).prepare!(**kwargs)
    end
  end
end
