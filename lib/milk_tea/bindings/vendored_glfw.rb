# frozen_string_literal: true

module MilkTea
  module VendoredGLFW
    Error = VendoredCLibrary::Error

    CONFIGURE_ARGS = %w[
      -DCMAKE_BUILD_TYPE=Release
      -DCMAKE_POSITION_INDEPENDENT_CODE=ON
      -DBUILD_SHARED_LIBS=OFF
      -DGLFW_BUILD_EXAMPLES=OFF
      -DGLFW_BUILD_TESTS=OFF
      -DGLFW_BUILD_DOCS=OFF
    ].freeze

    module_function

    def library
      @library ||= VendoredCLibrary::CMake.new(
        name: "glfw",
        source_root: source_root,
        build_root: build_root,
        install_root: install_root,
        archive_path: archive_path,
        include_roots: [include_root],
        configure_args: CONFIGURE_ARGS,
        pkg_config_name: "glfw3",
        cc_env_var: "GLFW_CC",
      )
    end

    def source_root
      MilkTea.root.join("third_party/glfw-upstream")
    end

    def include_root
      source_root.join("include")
    end

    def header_root
      include_root.join("GLFW")
    end

    def build_root
      MilkTea.root.join("tmp/vendored-glfw")
    end

    def install_root
      MilkTea.root.join("tmp/vendored-glfw-prefix")
    end

    def archive_path
      install_root.join("lib/libglfw3.a")
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
