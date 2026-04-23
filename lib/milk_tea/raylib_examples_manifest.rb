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
    end

    def generate
      validate_examples_root!

      examples = parse_examples_list.map { |entry| build_example_manifest(entry) }

      {
        "examples_root" => @examples_root,
        "examples_list_path" => @examples_list_path,
        "total_examples" => examples.length,
        "category_counts" => category_counts(examples),
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
        "port_status" => "not_started",
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
  end
end
