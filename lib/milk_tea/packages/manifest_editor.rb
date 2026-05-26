# frozen_string_literal: true

require "tomlrb"

module MilkTea
  class PackageManifestEditorError < StandardError; end

  class PackageManifestEditor
    attr_reader :manifest_path

    def initialize(path)
      manifest = PackageManifest.load(path)
      @manifest_path = manifest.manifest_path
    rescue PackageManifestError => e
      raise PackageManifestEditorError, e.message
    end

    def add_dependency(name, raw_spec)
      config = parse_manifest
      dependencies = normalize_dependencies(config)
      dependencies[name] = raw_spec
      write_dependencies(dependencies)
    end

    def remove_dependency(name)
      config = parse_manifest
      dependencies = normalize_dependencies(config)
      raise PackageManifestEditorError, "dependency #{name} not found in #{@manifest_path}" unless dependencies.key?(name)

      dependencies.delete(name)
      write_dependencies(dependencies)
    end

    private

    def parse_manifest
      data = Tomlrb.load_file(@manifest_path)
      raise PackageManifestEditorError, "package.toml root must be a table: #{@manifest_path}" unless data.is_a?(Hash)

      data
    rescue StandardError => e
      raise PackageManifestEditorError, "invalid package.toml at #{@manifest_path}: #{e.message}"
    end

    def normalize_dependencies(config)
      dependencies = config["dependencies"]
      return {} if dependencies.nil?
      raise PackageManifestEditorError, "dependencies must be a table in #{@manifest_path}" unless dependencies.is_a?(Hash)

      dependencies.dup
    end

    def write_dependencies(dependencies)
      source = File.read(@manifest_path)
      replacement = dependencies.empty? ? nil : render_dependencies_section(dependencies)
      updated_source = replace_dependencies_section(source, replacement)
      PackageAtomicWrite.write(@manifest_path, updated_source)
    rescue SystemCallError => e
      raise PackageManifestEditorError, "failed to update #{@manifest_path}: #{e.message}"
    end

    def render_dependencies_section(dependencies)
      lines = ["[dependencies]\n"]
      dependencies.each do |name, spec|
        lines << "#{toml_string(name)} = #{render_dependency_spec(spec)}\n"
      end
      lines.join
    end

    def render_dependency_spec(spec)
      case spec
      when String
        toml_string(spec)
      when Hash
        pairs = spec.map do |key, value|
          "#{key} = #{toml_string(value)}"
        end
        "{ #{pairs.join(', ')} }"
      else
        raise PackageManifestEditorError, "unsupported dependency spec type #{spec.class}"
      end
    end

    def replace_dependencies_section(source, replacement)
      lines = source.lines
      start_index = lines.index { |line| line.match?(/^\[dependencies\]\s*$/) }
      if start_index
        end_index = lines[(start_index + 1)..]&.index { |line| line.start_with?("[") }
        end_index = end_index ? start_index + 1 + end_index : lines.length
        before = lines[0...start_index]
        after = lines[end_index..] || []
        return rebuild_source(before, replacement, after)
      end

      return source if replacement.nil?

      rebuilt = source.dup
      rebuilt << "\n" unless rebuilt.empty? || rebuilt.end_with?("\n")
      rebuilt << "\n" unless rebuilt.empty? || rebuilt.end_with?("\n\n")
      rebuilt << replacement
      rebuilt
    end

    def rebuild_source(before, replacement, after)
      rebuilt = before.join
      rebuilt = rebuilt.rstrip
      if replacement
        rebuilt << "\n\n" unless rebuilt.empty?
        rebuilt << replacement
      end

      trailing = after.join.lstrip
      unless trailing.empty?
        rebuilt << "\n" unless rebuilt.empty? || rebuilt.end_with?("\n")
        rebuilt << "\n" unless rebuilt.end_with?("\n\n")
        rebuilt << trailing
      else
        rebuilt << "\n" unless rebuilt.empty? || rebuilt.end_with?("\n")
      end
      rebuilt
    end

    def toml_string(value)
      escaped = value.to_s
        .gsub('\\', '\\\\')
        .gsub('"', '\\"')
        .gsub("\n", '\\n')
        .gsub("\r", '\\r')
        .gsub("\t", '\\t')

      %Q("#{escaped}")
    end
  end
end
