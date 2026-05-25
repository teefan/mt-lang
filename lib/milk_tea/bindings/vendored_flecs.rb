# frozen_string_literal: true

module MilkTea
  module VendoredFlecs
    Error = VendoredCLibrary::Error
    SOURCE_NAME = "flecs"

    SOURCES = %w[
      distr/flecs.c
    ].freeze

    SYSTEM_LINK_FLAGS = %w[
      -lrt
      -lpthread
      -lm
    ].freeze

    C_FLAGS = %w[
      -std=gnu99
    ].freeze

    module_function

    def source(root: MilkTea.root)
      UpstreamSources.default_sources(root:).find { |entry| entry.name == SOURCE_NAME } ||
        raise(Error, "missing upstream source definition for #{SOURCE_NAME}")
    end

    def library(root: MilkTea.root)
      resolved_root = Pathname.new(File.expand_path(root.to_s))
      @libraries ||= {}
      @libraries[resolved_root.to_s] ||= VendoredCLibrary::Archive.new(
        name: "flecs",
        source_root: source_root(root: resolved_root),
        build_root: build_root(root: resolved_root),
        archive_name: "libflecs.a",
        sources: SOURCES,
        include_roots: [include_root(root: resolved_root)],
        system_link_flags: SYSTEM_LINK_FLAGS,
        cc_env_var: "FLECS_CC",
        c_flags: C_FLAGS,
      )
    end

    def source_root(root: MilkTea.root)
      source(root:).checkout_root
    end

    def include_root(root: MilkTea.root)
      source_root(root:).join("distr")
    end

    def header_path(root: MilkTea.root)
      include_root(root:).join("flecs.h")
    end

    def build_root(root: MilkTea.root)
      Pathname.new(File.expand_path(root.to_s)).join("tmp/vendored-flecs")
    end

    def archive_path(root: MilkTea.root)
      build_root(root:).join("libflecs.a")
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
