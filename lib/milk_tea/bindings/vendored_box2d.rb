# frozen_string_literal: true

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

    def library
      @library ||= VendoredCLibrary::CMake.new(
        name: "box2d",
        source_root: source_root,
        build_root: build_root,
        install_root: install_root,
        archive_path: archive_path,
        include_roots: [include_root],
        configure_args: CONFIGURE_ARGS,
        system_link_flags: SYSTEM_LINK_FLAGS,
        cc_env_var: "BOX2D_CC",
      )
    end

    def source_root
      MilkTea.root.join("third_party/box2d-upstream")
    end

    def include_root
      source_root.join("include")
    end

    def header_root
      include_root.join("box2d")
    end

    def build_root
      MilkTea.root.join("tmp/vendored-box2d")
    end

    def install_root
      MilkTea.root.join("tmp/vendored-box2d-prefix")
    end

    def archive_path
      install_root.join("lib/libbox2d.a")
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
