# frozen_string_literal: true

module MilkTea
  module VendoredCJSON
    Error = VendoredCLibrary::Error

    SOURCES = %w[
      cJSON.c
    ].freeze

    SYSTEM_LINK_FLAGS = %w[
      -lm
    ].freeze

    module_function

    def library(root: MilkTea.root)
      resolved_root = Pathname.new(File.expand_path(root.to_s))
      @libraries ||= {}
      @libraries[resolved_root.to_s] ||= VendoredCLibrary::Archive.new(
        name: "cjson",
        source_root: source_root(root: resolved_root),
        build_root: build_root(root: resolved_root),
        archive_name: "libcjson.a",
        sources: SOURCES,
        include_roots: [source_root(root: resolved_root)],
        system_link_flags: SYSTEM_LINK_FLAGS,
        cc_env_var: "CJSON_CC",
      )
    end

    def source_root(root: MilkTea.root)
      MilkTea.writable_root_for(root).join("third_party/cjson-upstream")
    end

    def build_root(root: MilkTea.root)
      MilkTea.writable_root_for(root).join("tmp/vendored-cjson")
    end

    def archive_path(root: MilkTea.root)
      build_root(root:).join("libcjson.a")
    end

    def link_flags(root: MilkTea.root)
      library(root:).link_flags
    end

    def prepare!(root: MilkTea.root, **kwargs)
      library(root:).prepare!(**kwargs)
    end
  end
end
