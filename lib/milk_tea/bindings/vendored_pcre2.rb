# frozen_string_literal: true

module MilkTea
  module VendoredPCRE2
    Error = VendoredCLibrary::Error
    SOURCE_NAME = "pcre2"

    CONFIGURE_ARGS = %w[
      -DCMAKE_BUILD_TYPE=Release
      -DCMAKE_POSITION_INDEPENDENT_CODE=ON
      -DBUILD_SHARED_LIBS=OFF
      -DPCRE2_BUILD_PCRE2_8=ON
      -DPCRE2_BUILD_PCRE2_16=OFF
      -DPCRE2_BUILD_PCRE2_32=OFF
      -DPCRE2_BUILD_PCRE2GREP=OFF
      -DPCRE2_BUILD_PCRE2TEST=OFF
      -DPCRE2_BUILD_TESTS=OFF
    ].freeze

    SYSTEM_LINK_FLAGS = %w[
      -lm
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
        name: "pcre2",
        source_root: source_root(root: resolved_root),
        build_root: build_root(root: resolved_root),
        install_root: install_root(root: resolved_root),
        archive_path: archive_path(root: resolved_root),
        include_roots: [include_root(root: resolved_root)],
        configure_args: CONFIGURE_ARGS,
        system_link_flags: SYSTEM_LINK_FLAGS,
        cc_env_var: "PCRE2_CC",
      )
    end

    def source_root(root: MilkTea.root)
      source(root:).checkout_root
    end

    def include_root(root: MilkTea.root)
      install_root(root:).join("include")
    end

    def header_path(root: MilkTea.root)
      include_root(root:).join("pcre2.h")
    end

    def build_root(root: MilkTea.root)
      MilkTea.writable_root_for(root).join("tmp/vendored-pcre2")
    end

    def install_root(root: MilkTea.root)
      MilkTea.writable_root_for(root).join("tmp/vendored-pcre2-prefix")
    end

    def archive_path(root: MilkTea.root)
      install_root(root:).join("lib/libpcre2-8.a")
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
