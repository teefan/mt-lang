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

    def library
      @library ||= VendoredCLibrary::Archive.new(
        name: "cjson",
        source_root: source_root,
        build_root: build_root,
        archive_name: "libcjson.a",
        sources: SOURCES,
        include_roots: [source_root],
        system_link_flags: SYSTEM_LINK_FLAGS,
        cc_env_var: "CJSON_CC",
      )
    end

    def source_root
      MilkTea.root.join("third_party/cjson-upstream")
    end

    def build_root
      MilkTea.root.join("tmp/vendored-cjson")
    end

    def archive_path
      build_root.join("libcjson.a")
    end

    def link_flags
      library.link_flags
    end

    def prepare!(**kwargs)
      library.prepare!(**kwargs)
    end
  end
end
