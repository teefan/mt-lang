# frozen_string_literal: true

module MilkTea
  module VendoredSDL3
    Error = VendoredCLibrary::Error

    CONFIGURE_ARGS = %w[
      -DCMAKE_BUILD_TYPE=Release
      -DCMAKE_POSITION_INDEPENDENT_CODE=ON
      -DSDL_SHARED=OFF
      -DSDL_STATIC=ON
      -DSDL_TEST_LIBRARY=OFF
      -DSDL_TESTS=OFF
      -DSDL_EXAMPLES=OFF
    ].freeze

    module_function

    def library
      @library ||= VendoredCLibrary::CMake.new(
        name: "sdl3",
        source_root: source_root,
        build_root: build_root,
        install_root: install_root,
        archive_path: archive_path,
        include_roots: [include_root],
        configure_args: CONFIGURE_ARGS,
        pkg_config_name: "sdl3",
        cc_env_var: "SDL3_CC",
      )
    end

    def source_root
      MilkTea.root.join("third_party/sdl3-upstream")
    end

    def include_root
      source_root.join("include")
    end

    def header_root
      include_root.join("SDL3")
    end

    def build_root
      MilkTea.root.join("tmp/vendored-sdl3")
    end

    def install_root
      MilkTea.root.join("tmp/vendored-sdl3-prefix")
    end

    def archive_path
      install_root.join("lib/libSDL3.a")
    end

    def include_flags
      library.include_flags
    end

    def link_flags
      library.link_flags
    end

    def prepare!(**kwargs)
      library.prepare!(**kwargs)
    end
  end
end
