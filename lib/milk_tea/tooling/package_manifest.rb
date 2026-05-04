# frozen_string_literal: true

module MilkTea
  class PackageManifestError < StandardError; end

  class PackageManifest
    DataView = Data.define(:root_dir, :manifest_path, :package_name, :source_path, :profile, :platform, :output_path)

    def self.load(path)
      new(path).load
    end

    def initialize(path)
      @path = File.expand_path(path)
    end

    def load
      manifest_path, root_dir = resolve_manifest_path(@path)
      raise PackageManifestError, "package manifest not found for #{@path}" unless manifest_path

      config = parse_manifest(manifest_path)
      package = config.fetch("package", {})
      build = config.fetch("build", {})
      profile_config = config.fetch("profile", {})
      platform_config = config.fetch("platform", {})

      package_name = package["name"]
      if package_name.nil? || package_name.empty?
        package_name = File.basename(root_dir).tr("-", "_")
      end

      build_type_name = (build["type"] || "executable").to_s
      unless build_type_name == "executable"
        raise PackageManifestError, "unsupported build.type #{build_type_name} in #{manifest_path}; only executable is supported"
      end

      profile_name = normalize_profile_name(build["profile"] || profile_config["default"])
      platform_name = normalize_platform_name(build["platform"] || platform_config["default"])

      default_entry = "src/main.mt"
      entry = (build["entry"] || default_entry).to_s
      source_path = File.expand_path(entry, root_dir)
      unless File.file?(source_path)
        raise PackageManifestError, "build.entry not found: #{entry} (resolved to #{source_path})"
      end

      output_path = build["output"]
      output_path = File.expand_path(output_path.to_s, root_dir) if output_path

      DataView.new(
        root_dir:,
        manifest_path:,
        package_name:,
        source_path:,
        profile: profile_name,
        platform: platform_name,
        output_path:,
      )
    end

    private

    def resolve_manifest_path(path)
      if File.directory?(path)
        manifest_path = File.join(path, "package.toml")
        raise PackageManifestError, "package manifest not found: #{manifest_path}" unless File.file?(manifest_path)

        return [manifest_path, path]
      end

      if File.basename(path) == "package.toml"
        raise PackageManifestError, "package manifest not found: #{path}" unless File.file?(path)

        return [path, File.dirname(path)]
      end

      [nil, nil]
    end

    def parse_manifest(path)
      data = {}
      current_section = nil

      File.readlines(path, chomp: true).each_with_index do |line, index|
        clean = line.sub(/\s+#.*\z/, "").strip
        next if clean.empty?

        if (section_match = clean.match(/\A\[([a-zA-Z0-9_.-]+)\]\z/))
          current_section = section_match[1]
          data[current_section] ||= {}
          next
        end

        key_match = clean.match(/\A([a-zA-Z0-9_.-]+)\s*=\s*(.+)\z/)
        unless key_match
          raise PackageManifestError, "invalid package.toml at #{path}:#{index + 1}"
        end

        key = key_match[1]
        value = parse_value(key_match[2], path:, line_number: index + 1)

        target = current_section ? (data[current_section] ||= {}) : data
        target[key] = value
      end

      data
    end

    def parse_value(raw_value, path:, line_number:)
      value = raw_value.strip

      if value.start_with?("\"") && value.end_with?("\"") && value.length >= 2
        return value[1..-2].gsub('\\"', '"').gsub("\\\\", "\\")
      end

      if value.match?(/\A[a-zA-Z0-9_.\/-]+\z/)
        return value
      end

      raise PackageManifestError, "unsupported package.toml value at #{path}:#{line_number}"
    end

    def normalize_profile_name(value)
      case value.to_s
      when "", "debug", "dev"
        :debug
      when "release", "rel"
        :release
      else
        raise PackageManifestError, "unknown profile #{value}; expected debug|release"
      end
    end

    def normalize_platform_name(value)
      case value.to_s
      when "", "linux"
        :linux
      when "windows", "win", "win32"
        :windows
      else
        raise PackageManifestError, "unknown platform #{value}; expected linux|windows"
      end
    end
  end
end
