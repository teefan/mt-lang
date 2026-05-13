# frozen_string_literal: true

module MilkTea
  class PackageManagerCLI
    def self.start(argv = ARGV, out:, err:, help_printer:, services: PackageServices.new)
      new(argv, out:, err:, help_printer:, services:).start
    end

    def initialize(argv, out:, err:, help_printer:, services:)
      @argv = argv.dup
      @out = out
      @err = err
      @help_printer = help_printer
      @services = services
    end

    def start
      subcommand = @argv.shift
      unless subcommand
        @err.puts("missing deps subcommand")
        print_help
        return 1
      end

      case subcommand
      when "add"
        deps_add_command
      when "remove"
        deps_remove_command
      when "update"
        deps_update_command
      when "tree"
        path = nil
        if @argv.first && !@argv.first.start_with?("-")
          path = @argv.shift
        end

        unless path
          if File.file?(File.join(Dir.pwd, "package.toml"))
            path = Dir.pwd
          else
            @err.puts("missing package path")
            print_help
            return 1
          end
        end

        if @argv.any?
          @err.puts("unknown deps option #{@argv.first}")
          print_help
          return 1
        end

        @out.puts(PackageGraph.render_tree(path, source_resolver: @services.source_resolver(:materialize)))
        0
      when "lock"
        path = nil
        check = false
        until @argv.empty?
          arg = @argv.shift
          case arg
          when "--check"
            check = true
          when /^-/
            @err.puts("unknown deps option #{arg}")
            print_help
            return 1
          else
            if path
              @err.puts("unknown deps option #{arg}")
              print_help
              return 1
            end

            path = arg
          end
        end

        unless path
          if File.file?(File.join(Dir.pwd, "package.toml"))
            path = Dir.pwd
          else
            @err.puts("missing package path")
            print_help
            return 1
          end
        end

        if check
          result = PackageLock.check(path, source_resolver: @services.source_resolver(:materialize))
          if result.current?
            @out.puts("up to date #{result.lock_path}")
            0
          elsif result.missing?
            @out.puts("missing #{result.lock_path}")
            1
          else
            @out.puts("out of date #{result.lock_path}")
            1
          end
        else
          result = PackageLock.write(path, source_resolver: @services.source_resolver(:materialize))
          @out.puts("wrote #{result.lock_path}")
          0
        end
      when "publish"
        path = nil
        upstream = false
        until @argv.empty?
          arg = @argv.shift
          case arg
          when "--upstream"
            upstream = true
          when /^-/
            @err.puts("unknown deps option #{arg}")
            print_help
            return 1
          else
            if path
              @err.puts("unknown deps option #{arg}")
              print_help
              return 1
            end

            path = arg
          end
        end

        unless path
          if File.file?(File.join(Dir.pwd, "package.toml"))
            path = Dir.pwd
          else
            @err.puts("missing package path")
            print_help
            return 1
          end
        end

        result = @services.registry_store.publish(path, target: upstream ? :upstream : :local)
        @out.puts("published #{result.package_name}@#{result.version} -> #{result.path}")
        0
      when "fetch"
        path = nil
        until @argv.empty?
          arg = @argv.shift
          case arg
          when /^-/
            @err.puts("unknown deps option #{arg}")
            print_help
            return 1
          else
            if path
              @err.puts("unknown deps option #{arg}")
              print_help
              return 1
            end

            path = arg
          end
        end

        unless path
          if File.file?(File.join(Dir.pwd, "package.toml"))
            path = Dir.pwd
          else
            @err.puts("missing package path")
            print_help
            return 1
          end
        end

        emit_dependency_fetch_results(@services.source_fetcher.fetch_locked_sources(path), path)
        0
      else
        @err.puts("unknown deps subcommand #{subcommand}")
        print_help
        1
      end
    end

    private

    def print_help
      @help_printer.call(@err)
    end

    def deps_add_command
      path = deps_target_path_from_argv!
      dependency_arg = @argv.shift
      unless dependency_arg
        @err.puts("missing dependency name")
        print_help
        return 1
      end

      dependency_name, inline_requirement = parse_dependency_argument(dependency_arg)
      spec = parse_dependency_spec_for_add(dependency_name, inline_requirement)
      editor = PackageManifestEditor.new(path)
      existing = PackageManifest.load(path).dependencies.any? { |dependency| dependency.name == dependency_name }

      with_manifest_edit(editor) do
        editor.add_dependency(dependency_name, spec)
      end

      action = existing ? "updated" : "added"
      @out.puts("#{action} #{dependency_name} in #{editor.manifest_path}")
      0
    end

    def deps_remove_command
      path = deps_target_path_from_argv!
      dependency_name = @argv.shift
      unless dependency_name
        @err.puts("missing dependency name")
        print_help
        return 1
      end

      if @argv.any?
        @err.puts("unknown deps option #{@argv.first}")
        print_help
        return 1
      end

      editor = PackageManifestEditor.new(path)
      with_manifest_edit(editor) do
        editor.remove_dependency(dependency_name)
      end

      @out.puts("removed #{dependency_name} from #{editor.manifest_path}")
      0
    end

    def deps_update_command
      path = deps_target_path_from_argv!
      unless @argv.empty?
        @err.puts("selective deps update is not implemented yet")
        print_help
        return 1
      end

      lock_result = PackageLock.write(path, source_resolver: @services.source_resolver(:materialize))
      @out.puts("updated #{lock_result.lock_path}")
      emit_dependency_fetch_results(@services.source_fetcher.fetch_locked_sources(path), path)
      0
    end

    def deps_target_path_from_argv!
      path = nil
      if @argv.first && !@argv.first.start_with?("-") && package_path_argument?(@argv.first)
        path = @argv.shift
      end

      return path if path
      return Dir.pwd if File.file?(File.join(Dir.pwd, "package.toml"))

      raise PackageManifestEditorError, "missing package path"
    end

    def package_path_argument?(value)
      File.exist?(value) || value.end_with?("package.toml") || value.include?(File::SEPARATOR)
    end

    def parse_dependency_argument(argument)
      name, requirement = argument.split("@", 2)
      if name.nil? || name.strip.empty?
        raise PackageManifestEditorError, "dependency name cannot be empty"
      end

      if requirement && requirement.strip.empty?
        raise PackageManifestEditorError, "dependency version requirement cannot be empty"
      end

      [name.strip, requirement&.strip]
    end

    def parse_dependency_spec_for_add(dependency_name, inline_requirement)
      requirement = inline_requirement
      path = nil
      git = nil
      git_rev = nil
      git_subdir = nil

      until @argv.empty?
        arg = @argv.shift
        case arg
        when "--path"
          path = deps_required_option_value!(arg)
        when "--git"
          git = deps_required_option_value!(arg)
        when "--rev"
          git_rev = deps_required_option_value!(arg)
        when "--subdir"
          git_subdir = deps_required_option_value!(arg)
        when "--version"
          requirement = deps_required_option_value!(arg)
        else
          @err.puts("unknown deps option #{arg}")
          print_help
          raise PackageManifestEditorError, "unknown deps option #{arg}"
        end
      end

      if path && git
        raise PackageManifestEditorError, "dependency #{dependency_name} cannot use both --path and --git"
      end

      if git
        raise PackageManifestEditorError, "dependency #{dependency_name} is missing --rev" unless git_rev
        raise PackageManifestEditorError, "dependency #{dependency_name} cannot combine git resolution with a version requirement" if requirement

        spec = { "git" => git, "rev" => git_rev }
        spec["subdir"] = git_subdir if git_subdir
        return spec
      end

      if path
        spec = { "path" => path }
        spec["version"] = normalize_dependency_requirement_string(requirement, dependency_name) if requirement
        return spec
      end

      raise PackageManifestEditorError, "dependency #{dependency_name} is missing a version requirement" unless requirement

      normalize_dependency_requirement_string(requirement, dependency_name)
    end

    def deps_required_option_value!(option)
      value = @argv.shift
      raise PackageManifestEditorError, "missing value for #{option}" unless value

      value
    end

    def normalize_dependency_requirement_string(requirement, dependency_name)
      normalized_text = requirement.to_s.strip
      version_req = PackageVersionReq.parse(
        normalized_text,
        label: "dependency #{dependency_name} version requirement",
      )
      version_req.exact? ? version_req.exact_version.to_s : normalized_text
    end

    def with_manifest_edit(editor)
      original_source = File.read(editor.manifest_path)
      yield
      lock_result = PackageLock.write(editor.manifest_path, source_resolver: @services.source_resolver(:materialize))
      @out.puts("wrote #{lock_result.lock_path}")
      emit_dependency_fetch_results(@services.source_fetcher.fetch_locked_sources(editor.manifest_path), editor.manifest_path)
    rescue StandardError
      File.write(editor.manifest_path, original_source) if original_source
      raise
    end

    def emit_dependency_fetch_results(results, path)
      if results.empty?
        lock_path = File.join(PackageManifest.load(path).root_dir, "package.lock")
        @out.puts("no cache-backed sources in #{lock_path}")
        return
      end

      results.each do |result|
        verb = result.status == :present ? "kept" : "materialized"
        @out.puts("#{verb} #{result.package_name} -> #{result.path}")
      end
    end
  end
end
