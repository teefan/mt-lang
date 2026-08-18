# frozen_string_literal: true

module MilkTea
  class CLI
    module CommandRun
      def run_command
        path, options = extract_path_and_options
        return 1 unless path

        run_and_print_result(path, options)
      end

      def app_command
        options = parse_build_options
        return 1 unless options

        module_name = @argv.shift
        unless module_name
          @err.puts("missing module name")
          print_usage(@err)
          return 1
        end

        path = resolve_app_module(module_name)
        unless path
          @err.puts("run-module module not found: #{module_name}")
          return 1
        end

        frozen = options.delete(:frozen)
        ensure_current_lockfile!(path) if frozen

        run_and_print_result(path, options)
      end

      def extract_path_and_options(allow_clean: false)
        options = parse_build_options(allow_clean:)
        return nil unless options

        path = @argv.shift
        unless path
          if File.file?(File.join(Dir.pwd, "package.toml"))
            path = Dir.pwd
          else
            @err.puts("missing source file path")
            print_usage(@err)
            return nil
          end
        end

        [path, options]
      end

      def run_and_print_result(path, options)
        frozen = options.delete(:frozen)
        ensure_current_lockfile!(path) if frozen
        locked = options.delete(:locked)
        package_graph = package_graph_for(path, locked:)
        preview_notice_emitted = false
        preview_started = lambda do |message|
          preview_notice_emitted = true
          @out.write(message)
          @out.flush if @out.respond_to?(:flush)
        end

        result = Run.run(
          path,
          module_roots: module_roots_for(path, locked:),
          package_graph:,
          frontend: @build_frontend,
          preview_started:,
          argv: @argv.dup,
          **options.except(:timings)
        )
        live = $stdout.tty?
        unless (@out.equal?($stdout) && live) || preview_notice_emitted
          @out.write(result.stdout)
        end
        @out.flush if @out.respond_to?(:flush)
        @err.write(result.stderr) unless @err.equal?($stderr) && live
        info("[cached]") if result.cached
        result.exit_status
      end

      def resolve_app_module(name)
        relative = name.tr(".", "/").sub(%r{^/}, "") + ".mt"

        module_roots_for(Dir.pwd).each do |root|
          candidate = File.join(root, "std", relative)
          return File.expand_path(candidate) if File.file?(candidate)

          candidate = File.join(root, relative)
          return File.expand_path(candidate) if File.file?(candidate)
        end

        nil
      end
    end
  end
end
