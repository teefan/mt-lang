# frozen_string_literal: true

require "fileutils"
require "rexml/document"
require "set"

module MilkTea
  module OpenGLRegistry
    class Error < StandardError; end

    DEFAULT_API = "gl"
    DEFAULT_VERSION = "4.6"
    DEFAULT_PROFILE = "compatibility"
    SOURCE_NAME = "opengl_registry"
    HELPER_HEADER_BASENAME = "gl_registry_helpers.h"
    IMPLEMENTATION_DEFINE = "MT_LANG_GL_REGISTRY_HELPERS_IMPLEMENTATION"

    TypeEntry = Data.define(:name, :source, :order)
    EnumEntry = Data.define(:name, :value, :alias_of, :order)
    CommandParam = Data.define(:name, :source)
    CommandEntry = Data.define(:name, :return_type, :params, :order)
    BlockEntry = Data.define(:kind, :profile, :api, :types, :enums, :commands)
    FeatureEntry = Data.define(:name, :api, :number, :blocks)
    ExtensionEntry = Data.define(:name, :supported, :blocks)

    module_function

    def helper_header_path(root: MilkTea.root)
      root.join("std/c/#{HELPER_HEADER_BASENAME}")
    end

    def source(root: MilkTea.root)
      UpstreamSources.default_sources(root:).find { |entry| entry.name == SOURCE_NAME } ||
        raise(Error, "missing upstream source definition for #{SOURCE_NAME}")
    end

    def prepare!(root: MilkTea.root, api: DEFAULT_API, version: DEFAULT_VERSION, profile: DEFAULT_PROFILE, extensions: [])
      registry_source = source(root:)
      registry_source.bootstrap!

      generated = Generator.new(
        xml_path: registry_source.checkout_root.join("xml/gl.xml"),
        api:,
        version:,
        profile:,
        extensions:,
      ).generate

      path = helper_header_path(root:)
      FileUtils.mkdir_p(path.dirname)
      return if File.exist?(path) && File.read(path) == generated

      File.write(path, generated)
    end

    class Generator
      KHRONOS_TYPE_REWRITES = {
        "khronos_float_t" => "float",
        "khronos_int8_t" => "int8_t",
        "khronos_uint8_t" => "uint8_t",
        "khronos_int16_t" => "int16_t",
        "khronos_uint16_t" => "uint16_t",
        "khronos_int32_t" => "int32_t",
        "khronos_uint32_t" => "uint32_t",
        "khronos_int64_t" => "int64_t",
        "khronos_uint64_t" => "uint64_t",
        "khronos_intptr_t" => "intptr_t",
        "khronos_ssize_t" => "ptrdiff_t",
      }.freeze

      def initialize(xml_path: nil, xml_source: nil, api: DEFAULT_API, version: DEFAULT_VERSION, profile: DEFAULT_PROFILE, extensions: [])
        raise ArgumentError, "xml_path or xml_source is required" if xml_path.nil? && xml_source.nil?

        @xml_source = xml_source || File.read(xml_path)
        @source_label = xml_path ? File.expand_path(xml_path.to_s) : "<memory>"
        @api = api
        @version = version
        @profile = profile
        @extensions = extensions.to_set
      end

      def generate
        registry = parse_registry
        active_enums, active_commands = active_surface(registry)

        emit_header(
          types: registry.fetch(:types),
          enums: active_enums,
          commands: active_commands,
        )
      end

      private

      def parse_registry
        document = REXML::Document.new(@xml_source)
        root = document.root

        {
          types: parse_types(root),
          enums: parse_enums(root),
          commands: parse_commands(root),
          features: parse_features(root),
          extensions: parse_extensions(root),
        }
      end

      def parse_types(root)
        order = 0

        root.elements.each("types/type") do |type_element|
          name = type_element.attributes["name"] || type_element.elements["name"]&.text&.strip
          next if name.nil? || name.empty?

          source = flatten_node(type_element).strip
          yield_entry = TypeEntry.new(name:, source:, order:)
          order += 1
          (@types ||= []) << yield_entry
        end

        @types || []
      end

      def parse_enums(root)
        order = 0
        enums = {}

        root.elements.each("enums/enum") do |enum_element|
          name = enum_element.attributes["name"]
          next if name.nil? || name.empty?

          enums[name] ||= EnumEntry.new(
            name:,
            value: enum_element.attributes["value"],
            alias_of: enum_element.attributes["alias"],
            order:,
          )
          order += 1
        end

        enums
      end

      def parse_commands(root)
        order = 0
        commands = {}

        root.elements.each("commands/command") do |command_element|
          proto = command_element.elements["proto"]
          next if proto.nil?

          name = proto.elements["name"]&.text&.strip
          next if name.nil? || name.empty?

          commands[name] ||= CommandEntry.new(
            name:,
            return_type: normalize_c_fragment(flatten_node(proto, omit_name: true)),
            params: command_element.get_elements("param").map do |param_element|
              CommandParam.new(
                name: param_element.elements["name"]&.text&.strip,
                source: normalize_c_fragment(flatten_node(param_element)),
              )
            end,
            order:,
          )
          order += 1
        end

        commands
      end

      def parse_features(root)
        root.get_elements("feature").map do |feature_element|
          FeatureEntry.new(
            name: feature_element.attributes["name"],
            api: feature_element.attributes["api"],
            number: feature_element.attributes["number"],
            blocks: parse_blocks(feature_element),
          )
        end
      end

      def parse_extensions(root)
        root.get_elements("extensions/extension").each_with_object({}) do |extension_element, extensions|
          name = extension_element.attributes["name"]
          next if name.nil? || name.empty?

          extensions[name] = ExtensionEntry.new(
            name:,
            supported: extension_element.attributes["supported"],
            blocks: parse_blocks(extension_element),
          )
        end
      end

      def parse_blocks(parent_element)
        parent_element.elements.each_with_object([]) do |child, blocks|
          next unless %w[require remove].include?(child.name)

          blocks << BlockEntry.new(
            kind: child.name.to_sym,
            profile: child.attributes["profile"],
            api: child.attributes["api"],
            types: child.get_elements("type").filter_map { |element| element.attributes["name"] },
            enums: child.get_elements("enum").filter_map { |element| element.attributes["name"] },
            commands: child.get_elements("command").filter_map { |element| element.attributes["name"] },
          )
        end
      end

      def active_surface(registry)
        enums = Set.new
        commands = Set.new

        registry.fetch(:features)
                .select { |feature| api_matches?(feature.api) && version_at_most?(feature.number, @version) }
                .sort_by { |feature| version_key(feature.number) }
                .each { |feature| apply_blocks(feature.blocks, enums:, commands:) }

        @extensions.each do |extension_name|
          extension = registry.fetch(:extensions)[extension_name]
          next if extension.nil?
          next unless api_list_matches?(extension.supported)

          apply_blocks(extension.blocks, enums:, commands:)
        end

        active_enums = enums.map { |name| registry.fetch(:enums).fetch(name) }.sort_by(&:order)
        active_commands = commands.map { |name| registry.fetch(:commands).fetch(name) }.sort_by(&:order)
        [active_enums, active_commands]
      end

      def apply_blocks(blocks, enums:, commands:)
        blocks.each do |block|
          next unless block_matches?(block)

          case block.kind
          when :require
            block.enums.each { |name| enums << name }
            block.commands.each { |name| commands << name }
          when :remove
            block.enums.each { |name| enums.delete(name) }
            block.commands.each { |name| commands.delete(name) }
          end
        end
      end

      def block_matches?(block)
        profile_matches?(block.profile) && api_list_matches?(block.api)
      end

      def profile_matches?(profile)
        profile.nil? || profile.empty? || profile == @profile
      end

      def api_matches?(api)
        api == @api
      end

      def api_list_matches?(api_list)
        return true if api_list.nil? || api_list.empty?

        api_list.split(/[\s,|]+/).include?(@api)
      end

      def version_at_most?(left, right)
        compare_versions(left, right) <= 0
      end

      def version_key(version)
        version.to_s.split(".").map(&:to_i)
      end

      def compare_versions(left, right)
        lhs = version_key(left)
        rhs = version_key(right)
        width = [lhs.length, rhs.length].max

        lhs.fill(0, lhs.length...width)
        rhs.fill(0, rhs.length...width)
        lhs <=> rhs
      end

      def emit_header(types:, enums:, commands:)
        [
          "/* generated by mtc opengl-registry from #{@source_label} */",
          "#ifndef MT_LANG_GL_REGISTRY_HELPERS_H",
          "#define MT_LANG_GL_REGISTRY_HELPERS_H",
          "",
          "#include <stddef.h>",
          "#include <stdint.h>",
          "",
          "#if defined(_WIN32) && !defined(__CYGWIN__)",
          "#define MTLANG_GL_APIENTRY __stdcall",
          "#else",
          "#define MTLANG_GL_APIENTRY",
          "#endif",
          "",
          emit_types(types),
          emit_enums(enums),
          emit_loader_api,
          emit_public_command_declarations(commands),
          "#ifdef #{IMPLEMENTATION_DEFINE}",
          "#include <GLFW/glfw3.h>",
          "#include <stdio.h>",
          "#include <stdlib.h>",
          "",
          emit_command_proc_typedefs(commands),
          emit_command_storage(commands),
          emit_loader_implementation(commands),
          emit_command_definitions(commands),
          "#endif",
          "",
          "#endif",
          "",
        ].reject(&:empty?).join("\n")
      end

      def emit_types(types)
        rendered = types.filter_map do |type|
          next if type.name == "khrplatform"

          rewrite_type_source(type.source)
        end

        return "" if rendered.empty?

        rendered.join("\n\n")
      end

      def emit_enums(enums)
        return "" if enums.empty?

        enums_by_name = enums.each_with_object({}) { |entry, hash| hash[entry.name] = entry }

        enums.map do |entry|
          "#define #{entry.name} #{resolve_enum_value(entry, enums_by_name)}"
        end.join("\n")
      end

      def emit_loader_api
        <<~C.rstrip
          void mt_gl_reset_loader(void);
          void mt_gl_use_glfw_loader(void);
          void mt_gl_use_sdl_loader(void);
        C
      end

      def emit_public_command_declarations(commands)
        return "" if commands.empty?

        commands.map do |command|
          "#{command.return_type} MTLANG_GL_APIENTRY #{command.name}(#{command_parameter_list(command)});"
        end.join("\n")
      end

      def emit_command_proc_typedefs(commands)
        return "" if commands.empty?

        commands.map do |command|
          "typedef #{command.return_type} (MTLANG_GL_APIENTRY *#{command_proc_type_name(command)})(#{command_parameter_list(command)});"
        end.join("\n")
      end

      def emit_command_storage(commands)
        return "" if commands.empty?

        lines = [
          "typedef void (*mtlang_gl_function)(void);",
          "typedef mtlang_gl_function (*mtlang_gl_loader_proc)(const char *name);",
          "",
          "static mtlang_gl_loader_proc mtlang_gl_loader;",
        ]
        lines.concat(commands.map { |command| "static #{command_proc_type_name(command)} #{command_proc_var_name(command)};" })
        lines.join("\n")
      end

      def emit_loader_implementation(commands)
        reset_lines = commands.map { |command| "    #{command_proc_var_name(command)} = NULL;" }

        <<~C.rstrip
          static void mtlang_gl_reset_cache(void)
          {
#{reset_lines.join("\n")}
          }

            static mtlang_gl_function mtlang_gl_require_proc(const char *name)
          {
              mtlang_gl_function proc;

              if (mtlang_gl_loader == NULL)
              {
                  fprintf(stderr, "OpenGL loader is not configured before calling %s\\n", name);
                  abort();
              }

              proc = mtlang_gl_loader(name);
              if (proc == NULL)
              {
                  fprintf(stderr, "OpenGL symbol %s is unavailable for the current context\\n", name);
                  abort();
              }

              return proc;
          }

          void mt_gl_reset_loader(void)
          {
              mtlang_gl_loader = NULL;
              mtlang_gl_reset_cache();
          }

          void mt_gl_set_loader_proc(mtlang_gl_loader_proc loader)
          {
              mtlang_gl_loader = loader;
              mtlang_gl_reset_cache();
          }
        C
      end

      def emit_command_definitions(commands)
        return "" if commands.empty?

        commands.map { |command| emit_command_definition(command) }.join("\n\n")
      end

      def emit_command_definition(command)
        lines = []
        lines << "#{command.return_type} MTLANG_GL_APIENTRY #{command.name}(#{command_parameter_list(command)})"
        lines << "{"
        lines << "    if (#{command_proc_var_name(command)} == NULL)"
        lines << "    {"
        lines << "        #{command_proc_var_name(command)} = (#{command_proc_type_name(command)}) mtlang_gl_require_proc(\"#{command.name}\");"
        lines << "    }"

        call = "#{command_proc_var_name(command)}(#{command_argument_list(command)})"
        if command.return_type == "void"
          lines << ""
          lines << "    #{call};"
        else
          lines << ""
          lines << "    return #{call};"
        end

        lines << "}"
        lines.join("\n")
      end

      def command_proc_type_name(command)
        "mtlang_gl_proc_#{command.name}"
      end

      def command_proc_var_name(command)
        "mtlang_gl_ptr_#{command.name}"
      end

      def command_parameter_list(command)
        return "void" if command.params.empty?

        command.params.map(&:source).join(", ")
      end

      def command_argument_list(command)
        command.params.map(&:name).join(", ")
      end

      def resolve_enum_value(entry, enums_by_name, seen = Set.new)
        return entry.value unless entry.value.nil? || entry.value.empty?
        return entry.alias_of if entry.alias_of.nil? || entry.alias_of.empty?
        return entry.alias_of if seen.include?(entry.name)

        seen << entry.name
        aliased = enums_by_name[entry.alias_of]
        return entry.alias_of if aliased.nil?

        resolve_enum_value(aliased, enums_by_name, seen)
      end

      def rewrite_type_source(source)
        rewritten = source.dup
        rewritten.gsub!("#include <KHR/khrplatform.h>", "")
        rewritten.gsub!(/\bGL_APIENTRY\b/, "MTLANG_GL_APIENTRY")
        rewritten.gsub!(/\bAPIENTRY\b/, "MTLANG_GL_APIENTRY")
        KHRONOS_TYPE_REWRITES.each do |original, replacement|
          rewritten.gsub!(/\b#{Regexp.escape(original)}\b/, replacement)
        end
        rewritten.strip
      end

      def normalize_c_fragment(fragment)
        fragment.gsub(/[ \t\n\r]+/, " ").strip
      end

      def flatten_node(node, omit_name: false)
        case node
        when REXML::Text
          node.value
        when REXML::Element
          return "" if omit_name && node.name == "name"
          return "MTLANG_GL_APIENTRY" if node.name == "apientry"

          node.children.map { |child| flatten_node(child, omit_name:) }.join
        else
          ""
        end
      end
    end
  end
end
