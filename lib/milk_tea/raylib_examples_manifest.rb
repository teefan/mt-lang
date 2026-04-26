# frozen_string_literal: true

require "json"

module MilkTea
  class RaylibExamplesError < StandardError; end

  class RaylibExamplesManifest
    RESOURCE_EXTENSIONS = %w[
      .png .bmp .jpg .jpeg .qoi .gif .raw .hdr
      .ttf .otf .fnt .wav .ogg .mp3 .flac .mod .xm .qoa
      .obj .iqm .glb .gltf .m3d .vox .vs .fs .txt
    ].freeze
    GLSL_VERSIONS = [100, 120, 330].freeze
    CALLBACK_PATTERN = /\b(?:Set\w*Callback|\w*Callback)\b/
    FILE_DROP_OR_DIRECTORY_PATTERN = /\b(?:FilePathList|DroppedFiles|DirectoryFiles|IsFileDropped|LoadDroppedFiles|UnloadDroppedFiles|LoadDirectoryFiles(?:Ex)?|UnloadDirectoryFiles|GetDirectoryPath|GetWorkingDirectory|GetApplicationDirectory|ChangeDirectory)\b/
    HELPER_HEADERS = {
      "raymath.h" => /#include\s+[<"]raymath\.h[>"]|\bRAYMATH_\w+\b/,
      "rlgl.h" => /#include\s+[<"]rlgl\.h[>"]|\brl[A-Z]\w*\s*\(/,
      "raygui.h" => /#include\s+[<"]raygui\.h[>"]|\bRAYGUI_IMPLEMENTATION\b/,
      "rlights.h" => /#include\s+[<"]rlights\.h[>"]|\bRLIGHTS_IMPLEMENTATION\b|\bCreateLight\s*\(/,
    }.freeze
    MODEL_EXTENSIONS = %w[.obj .iqm .glb .gltf .m3d .vox].freeze
    AUDIO_EXTENSIONS = %w[.wav .ogg .mp3 .flac .mod .xm .qoa].freeze
    SHADER_EXTENSIONS = %w[.vs .fs].freeze

    def self.generate(examples_root)
      new(examples_root).generate
    end

    def self.generate_json(examples_root)
      JSON.pretty_generate(generate(examples_root))
    end

    def initialize(examples_root)
      @examples_root = File.expand_path(examples_root)
      @examples_list_path = File.join(@examples_root, "examples_list.txt")
      @repo_root = detect_repo_root
      @raw_examples_root = @repo_root && File.join(@repo_root, "examples", "raylib")
      @idiomatic_examples_root = @repo_root && File.join(@repo_root, "examples", "idiomatic", "raylib")
    end

    def generate
      validate_examples_root!

      examples = parse_examples_list.map { |entry| build_example_manifest(entry) }

      {
        "examples_root" => @examples_root,
        "examples_list_path" => @examples_list_path,
        "repo_root" => @repo_root,
        "total_examples" => examples.length,
        "category_counts" => category_counts(examples),
        "progress" => progress_summary(examples),
        "examples" => examples,
      }
    end

    private

    def validate_examples_root!
      raise RaylibExamplesError, "examples root not found: #{@examples_root}" unless Dir.exist?(@examples_root)
      raise RaylibExamplesError, "examples_list.txt not found under #{@examples_root}" unless File.file?(@examples_list_path)
    end

    def parse_examples_list
      entries = []

      File.foreach(@examples_list_path) do |line|
        stripped = line.strip
        next if stripped.empty? || stripped.start_with?("#")

        fields = stripped.split(/;(?=(?:[^"]*"[^"]*")*[^"]*$)/)
        unless fields && fields.length == 9
          raise RaylibExamplesError, "invalid examples_list entry: #{stripped}"
        end

        entries << {
          category: fields[0],
          name: fields[1],
          stars: fields[2],
          created_version: fields[3],
          updated_version: fields[4],
          year_created: integer_field(fields[5]),
          year_reviewed: integer_field(fields[6]),
          author_name: fields[7],
          author_github_user: fields[8].delete_prefix("@"),
        }
      end

      entries
    end

    def integer_field(value)
      Integer(value)
    rescue ArgumentError
      raise RaylibExamplesError, "invalid integer field in examples_list.txt: #{value.inspect}"
    end

    def build_example_manifest(entry)
      source_rel_path = File.join(entry[:category], "#{entry[:name]}.c")
      source_path = File.join(@examples_root, source_rel_path)
      raise RaylibExamplesError, "example source not found: #{source_path}" unless File.file?(source_path)

      source = File.read(source_path)
      resource_paths = scan_resource_paths(source)
      helper_headers = detect_helper_headers(source)

      uses_raymath = helper_headers.include?("raymath.h")
      uses_rlgl = helper_headers.include?("rlgl.h")
      uses_raygui = helper_headers.include?("raygui.h")
      uses_rlights = helper_headers.include?("rlights.h")
      uses_shader_files = resource_paths.any? { |path| SHADER_EXTENSIONS.include?(File.extname(path).downcase) }
      uses_model_files = resource_paths.any? { |path| MODEL_EXTENSIONS.include?(File.extname(path).downcase) }
      uses_audio_files = resource_paths.any? { |path| AUDIO_EXTENSIONS.include?(File.extname(path).downcase) }
      uses_callbacks = source.match?(CALLBACK_PATTERN)
      uses_file_drop_or_directory_api = source.match?(FILE_DROP_OR_DIRECTORY_PATTERN)
      raw_port_path = find_raw_port_path(entry)
      idiomatic_port_path = find_idiomatic_port_path(entry)

      {
        "example_id" => File.join(entry[:category], entry[:name]),
        "category" => entry[:category],
        "name" => entry[:name],
        "stars" => entry[:stars],
        "raylib_created_version" => entry[:created_version],
        "raylib_last_update_version" => entry[:updated_version],
        "year_created" => entry[:year_created],
        "year_reviewed" => entry[:year_reviewed],
        "author_name" => entry[:author_name],
        "author_github_user" => entry[:author_github_user],
        "upstream_c_path" => source_rel_path.tr("\\", "/"),
        "resource_paths" => resource_paths,
        "helper_headers" => helper_headers,
        "uses_raymath" => uses_raymath,
        "uses_rlgl" => uses_rlgl,
        "uses_raygui" => uses_raygui,
        "uses_rlights" => uses_rlights,
        "uses_shader_files" => uses_shader_files,
        "uses_model_files" => uses_model_files,
        "uses_audio_files" => uses_audio_files,
        "uses_callbacks" => uses_callbacks,
        "uses_file_drop_or_directory_api" => uses_file_drop_or_directory_api,
        "raw_port_present" => !raw_port_path.nil?,
        "raw_port_path" => raw_port_path,
        "idiomatic_port_present" => !idiomatic_port_path.nil?,
        "idiomatic_port_path" => idiomatic_port_path,
        "port_status" => port_status(raw_port_path:, idiomatic_port_path:),
        "known_blockers" => known_blockers(
          uses_raymath:,
          uses_rlgl:,
          uses_raygui:,
          uses_rlights:,
          uses_shader_files:,
          uses_callbacks:,
          uses_file_drop_or_directory_api:,
        ),
      }
    end

    def category_counts(examples)
      examples.each_with_object({}) do |example, counts|
        counts[example.fetch("category")] = counts.fetch(example.fetch("category"), 0) + 1
      end
    end

    def progress_summary(examples)
      total_examples = examples.length
      raw_ported_examples = examples.count { |example| example.fetch("raw_port_present") }
      idiomatic_ported_examples = examples.count { |example| example.fetch("idiomatic_port_present") }

      {
        "raw_ported_examples" => raw_ported_examples,
        "idiomatic_ported_examples" => idiomatic_ported_examples,
        "raw_completion_percent" => completion_percent(raw_ported_examples, total_examples),
        "idiomatic_completion_percent" => completion_percent(idiomatic_ported_examples, total_examples),
        "by_category" => progress_by_category(examples),
        "gates" => {
          "wave1_raw_core_complete" => category_complete?(examples, "core", "raw_port_present"),
          "wave1_raw_shapes_complete" => category_complete?(examples, "shapes", "raw_port_present"),
          "wave1_ready_for_textures" => category_complete?(examples, "core", "raw_port_present") && category_complete?(examples, "shapes", "raw_port_present"),
          "raw_corpus_complete" => total_examples.positive? && raw_ported_examples == total_examples,
        },
      }
    end

    def progress_by_category(examples)
      examples.group_by { |example| example.fetch("category") }.transform_values do |category_examples|
        total_examples = category_examples.length
        raw_ported_examples = category_examples.count { |example| example.fetch("raw_port_present") }
        idiomatic_ported_examples = category_examples.count { |example| example.fetch("idiomatic_port_present") }

        {
          "total_examples" => total_examples,
          "raw_ported_examples" => raw_ported_examples,
          "idiomatic_ported_examples" => idiomatic_ported_examples,
          "raw_completion_percent" => completion_percent(raw_ported_examples, total_examples),
          "idiomatic_completion_percent" => completion_percent(idiomatic_ported_examples, total_examples),
        }
      end
    end

    def completion_percent(completed, total)
      return 0.0 if total.zero?

      ((completed.to_f / total) * 100).round(1)
    end

    def category_complete?(examples, category, field)
      category_examples = examples.select { |example| example.fetch("category") == category }
      return false if category_examples.empty?

      category_examples.all? { |example| example.fetch(field) }
    end

    def detect_helper_headers(source)
      HELPER_HEADERS.each_with_object([]) do |(header, pattern), headers|
        headers << header if source.match?(pattern)
      end
    end

    def scan_resource_paths(source)
      seen = {}
      paths = []

      source.scan(/"([^"\n]+)"/).flatten.each do |candidate|
        next unless resource_candidate?(candidate)

        expand_resource_candidate(candidate).each do |resource_path|
          normalized = resource_path.tr("\\", "/")
          next if seen[normalized]

          seen[normalized] = true
          paths << normalized
        end
      end

      paths
    end

    def resource_candidate?(candidate)
      return true if candidate.include?("resources/")

      RESOURCE_EXTENSIONS.include?(File.extname(candidate).downcase)
    end

    def expand_resource_candidate(candidate)
      return GLSL_VERSIONS.map { |version| candidate.gsub("glsl%i", "glsl#{version}") } if candidate.include?("glsl%i")

      [candidate]
    end

    def known_blockers(uses_raymath:, uses_rlgl:, uses_raygui:, uses_rlights:, uses_shader_files:, uses_callbacks:, uses_file_drop_or_directory_api:)
      blockers = []
      blockers << "raymath_helper_header" if uses_raymath
      blockers << "raygui_helper_header" if uses_raygui
      blockers << "rlights_helper_header" if uses_rlights
      blockers << "shader_assets" if uses_shader_files
      blockers << "callback_ffi" if uses_callbacks
      blockers << "directory_or_drop_apis" if uses_file_drop_or_directory_api
      blockers
    end

    def detect_repo_root
      current = @examples_root

      loop do
        return current if repo_root?(current)

        parent = File.dirname(current)
        return nil if parent == current

        current = parent
      end
    end

    def repo_root?(path)
      Dir.exist?(File.join(path, "examples", "raylib")) && Dir.exist?(File.join(path, "examples", "idiomatic", "raylib"))
    end

    def find_raw_port_path(entry)
      return unless @raw_examples_root

      path = File.join(@raw_examples_root, entry[:category], "#{entry[:name]}.mt")
      repo_relative_path(path) if File.file?(path)
    end

    def find_idiomatic_port_path(entry)
      return unless @idiomatic_examples_root && Dir.exist?(@idiomatic_examples_root)

      idiomatic_path = idiomatic_candidate_paths(entry).find { |path| File.file?(path) }
      repo_relative_path(idiomatic_path) if idiomatic_path
    end

    def idiomatic_candidate_paths(entry)
      stripped_name = entry[:name].delete_prefix("#{entry[:category]}_")
      idiomatic_paths = Dir[File.join(@idiomatic_examples_root, "*.mt")].sort

      exact_names = [entry[:name], stripped_name].uniq
      exact_paths = exact_names.map { |name| File.join(@idiomatic_examples_root, "#{name}.mt") }

      suffix_paths = idiomatic_paths.select do |path|
        idiomatic_name = File.basename(path, ".mt")
        stripped_name.end_with?("_#{idiomatic_name}")
      end

      (exact_paths + suffix_paths).uniq
    end

    def port_status(raw_port_path:, idiomatic_port_path:)
      return "raw_and_idiomatic" if raw_port_path && idiomatic_port_path
      return "idiomatic_only" if idiomatic_port_path
      return "raw_port" if raw_port_path

      "not_started"
    end

    def repo_relative_path(path)
      path.delete_prefix(@repo_root + "/")
    end
  end
end
