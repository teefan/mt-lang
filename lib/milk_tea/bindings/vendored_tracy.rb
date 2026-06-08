# frozen_string_literal: true

require_relative "vendored_tool"

module MilkTea
  module VendoredTracy
    def self.library(root: MilkTea.root)
      source = MilkTea.writable_root_for(root).join("third_party/tracy-upstream/public/TracyClient.cpp")
      build = MilkTea.writable_root_for(root).join("tmp/tracy-lib")
      MilkTea::VendoredCLibrary::Archive.new(
        name: "tracy",
        source_root: source.dirname,
        build_root: build,
        archive_name: "libtracyclient.a",
        sources: ["TracyClient.cpp"],
        include_roots: [source.dirname],
        defines: ["TRACY_ENABLE"],
        default_ar: "ar",
      )
    end

    def self.profiler_tool(root: MilkTea.root)
      upstream_root = root.join("third_party/tracy-upstream")
      MilkTea::VendoredTool.new(
        name: "tracy-profiler",
        source_dir: upstream_root.join("profiler").to_s,
        build_dir: MilkTea.writable_root_for(root).join("tmp/tracy-profiler-build").to_s,
        output_binary_name: "tracy-profiler",
        cmake_args: ["-DLEGACY=ON"],
      )
    end

    def self.all_tools(root: MilkTea.root)
      [profiler_tool(root:)]
    end
  end
end
