# frozen_string_literal: true

module MilkTea
  class CLI
    module CommandBuild
      def build_command
        path, options = extract_path_and_options(allow_clean: true)
        return 1 unless path

        if options.delete(:clean)
          cleaned_path = Build.clean(path, output_path: options[:output_path], profile: options[:profile], platform: options[:platform], bundle: options[:bundle], archive: options[:archive])
          info("cleaned #{cleaned_path}")
          return 0
        end

        frozen = options.delete(:frozen)
        ensure_current_lockfile!(path) if frozen
        locked = options.delete(:locked)
        bundle = options[:bundle]
        package_graph = package_graph_for(path, locked:)
        result = Build.build(path, module_roots: module_roots_for(path, locked:), package_graph:, frontend: @build_frontend, **options.except(:timings))
        if bundle
          info("built #{path} -> #{File.dirname(result.output_path)}")
          info("entry executable #{result.output_path}")
          info("  [cached]") if result.cached
          info("archive #{result.archive_path}") if result.archive_path
        elsif result.cached
          info("built #{path} -> #{result.output_path}  [cached]")
        else
          info("built #{path} -> #{result.output_path}")
        end
        info("saved C to #{result.c_path}") if result.c_path
        0
      end
    end
  end
end
