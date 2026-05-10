# frozen_string_literal: true

module MilkTea
  module VendoredLibUV
    Error = VendoredCLibrary::Error
    SOURCE_NAME = "libuv"

    CONFIGURE_ARGS = %w[
      -DCMAKE_BUILD_TYPE=Release
      -DCMAKE_POSITION_INDEPENDENT_CODE=ON
      -DBUILD_SHARED_LIBS=OFF
      -DBUILD_TESTING=OFF
    ].freeze

    module_function

    def source(root: MilkTea.root)
      UpstreamSources.default_sources(root:).find { |entry| entry.name == SOURCE_NAME } ||
        raise(Error, "missing upstream source definition for #{SOURCE_NAME}")
    end

    def library(root: MilkTea.root)
      resolved_root = Pathname.new(File.expand_path(root.to_s))
      @libraries ||= {}
      @libraries[resolved_root.to_s] ||= VendoredCLibrary::CMake.new(
        name: "libuv",
        source_root: source_root(root: resolved_root),
        build_root: build_root(root: resolved_root),
        install_root: install_root(root: resolved_root),
        archive_path: archive_path(root: resolved_root),
        include_roots: [include_root(root: resolved_root)],
        configure_args: CONFIGURE_ARGS,
        pkg_config_name: "libuv-static",
        cc_env_var: "LIBUV_CC",
      )
    end

    def source_root(root: MilkTea.root)
      source(root:).checkout_root
    end

    def include_root(root: MilkTea.root)
      source_root(root:).join("include")
    end

    def header_path(root: MilkTea.root)
      include_root(root:).join("uv.h")
    end

    def build_root(root: MilkTea.root)
      Pathname.new(File.expand_path(root.to_s)).join("tmp/vendored-libuv")
    end

    def install_root(root: MilkTea.root)
      Pathname.new(File.expand_path(root.to_s)).join("tmp/vendored-libuv-prefix")
    end

    def archive_path(root: MilkTea.root)
      install_root(root:).join("lib/libuv.a")
    end

    def include_flags(root: MilkTea.root)
      library(root:).include_flags
    end

    def link_flags(root: MilkTea.root)
      library(root:).link_flags
    end

    def prepare!(root: MilkTea.root, **kwargs)
      source(root:).bootstrap!
      library(root:).prepare!(**kwargs)
    end
  end
end
