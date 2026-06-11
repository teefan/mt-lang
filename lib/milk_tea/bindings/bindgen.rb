# frozen_string_literal: true

require "json"
require "open3"
require "tempfile"
require_relative "../tooling/formatter"
require_relative "../core/token"
require_relative "../core/types"
require_relative "bindgen/ast_parser"
require_relative "bindgen/declaration"
require_relative "bindgen/type_mapper"
require_relative "bindgen/emitter"
require_relative "bindgen/overrides"

module MilkTea
  module Bindgen
    MACRO_CONST_PREFIX = "__mt_bindgen_macro_"
    QUALIFIERS = %w[const volatile restrict].freeze
    NULLABILITY_QUALIFIERS = %w[_Nullable _Nonnull _Null_unspecified _Nullable_result].freeze
    NON_VALUE_MACRO_TOKENS = %w[
      extern static inline typedef struct union enum do if else for while return sizeof
      __attribute__ __attribute __declspec
    ].freeze
    PRIMITIVE_TYPE_MAP = {
      "_Bool" => "bool",
      "bool" => "bool",
      "void" => "void",
      "char" => "char",
      "signed char" => "byte",
      "unsigned char" => "ubyte",
      "short" => "short",
      "short int" => "short",
      "signed short" => "short",
      "signed short int" => "short",
      "unsigned short" => "ushort",
      "unsigned short int" => "ushort",
      "int" => "int",
      "signed" => "int",
      "signed int" => "int",
      "unsigned" => "uint",
      "unsigned int" => "uint",
      "long" => "ptr_int",
      "long int" => "ptr_int",
      "signed long" => "ptr_int",
      "signed long int" => "ptr_int",
      "unsigned long" => "ptr_uint",
      "unsigned long int" => "ptr_uint",
      "long long" => "long",
      "long long int" => "long",
      "signed long long" => "long",
      "signed long long int" => "long",
      "unsigned long long" => "ulong",
      "unsigned long long int" => "ulong",
      "float" => "float",
      "double" => "double",
    }.freeze

    def self.generate(module_name:, header_path:, tracked_header_paths: [], tracked_header_prefixes: [], declaration_name_prefixes: [], excluded_declaration_names: [], link_libraries: [], include_directives: nil, bindgen_defines: [], bindgen_include_directives: [], module_imports: [], clang: ENV.fetch("CLANG", "clang"), clang_args: [], type_name_overrides: {}, type_overrides: {}, function_param_type_overrides: {}, function_return_type_overrides: {}, field_type_overrides: {}, allow_static_inline_functions: false, strip_leading_underscores: false)
      generate_with_report(
        module_name:,
        header_path:,
        tracked_header_paths:,
        tracked_header_prefixes:,
        declaration_name_prefixes:,
        excluded_declaration_names:,
        link_libraries:,
        include_directives:,
        bindgen_defines:,
        bindgen_include_directives:,
        module_imports:,
        clang:,
        clang_args:,
        type_name_overrides:,
        type_overrides:,
        function_param_type_overrides:,
        function_return_type_overrides:,
        field_type_overrides:,
        allow_static_inline_functions:,
        strip_leading_underscores:,
      ).fetch(:source)
    end

    def self.generate_with_report(module_name:, header_path:, tracked_header_paths: [], tracked_header_prefixes: [], declaration_name_prefixes: [], excluded_declaration_names: [], link_libraries: [], include_directives: nil, bindgen_defines: [], bindgen_include_directives: [], module_imports: [], clang: ENV.fetch("CLANG", "clang"), clang_args: [], type_name_overrides: {}, type_overrides: {}, function_param_type_overrides: {}, function_return_type_overrides: {}, field_type_overrides: {}, allow_static_inline_functions: false, strip_leading_underscores: false)
      Generator.new(
        module_name:,
        header_path:,
        tracked_header_paths:,
        tracked_header_prefixes:,
        declaration_name_prefixes:,
        excluded_declaration_names:,
        link_libraries:,
        include_directives:,
        bindgen_defines:,
        bindgen_include_directives:,
        module_imports:,
        clang:,
        clang_args:,
        type_name_overrides:,
        type_overrides:,
        function_param_type_overrides:,
        function_return_type_overrides:,
        field_type_overrides:,
        allow_static_inline_functions:,
        strip_leading_underscores:,
      ).generate_with_report
    end

    class Generator
      def initialize(module_name:, header_path:, tracked_header_paths:, tracked_header_prefixes:, declaration_name_prefixes:, excluded_declaration_names:, link_libraries:, include_directives:, bindgen_defines:, bindgen_include_directives:, module_imports:, clang:, clang_args:, type_name_overrides:, type_overrides:, function_param_type_overrides:, function_return_type_overrides:, field_type_overrides:, allow_static_inline_functions:, strip_leading_underscores: false)
        @module_name = module_name
        @header_path = File.expand_path(header_path)
        @tracked_header_paths = ([header_path] + tracked_header_paths).map { |path| File.expand_path(path) }.uniq.freeze
        @tracked_header_prefixes = tracked_header_prefixes.map { |path| File.expand_path(path) }.uniq.freeze
        @declaration_name_prefixes = declaration_name_prefixes.dup.freeze
        @excluded_declaration_names = excluded_declaration_names.map(&:to_s).freeze
        @link_libraries = link_libraries.dup
        @include_directives = include_directives&.dup
        @bindgen_defines = bindgen_defines.dup.freeze
        @bindgen_include_directives = bindgen_include_directives.dup.freeze
        @module_imports = normalize_module_imports(module_imports)
        @clang = clang
        @clang_args = clang_args.dup
        @type_name_overrides = normalize_type_name_overrides(type_name_overrides)
        @type_overrides = normalize_type_overrides(type_overrides)
        @function_param_type_overrides = normalize_function_param_type_overrides(function_param_type_overrides)
        @function_return_type_overrides = normalize_function_return_type_overrides(function_return_type_overrides)
        @field_type_overrides = normalize_field_type_overrides(field_type_overrides)
        @allow_static_inline_functions = allow_static_inline_functions
        @strip_leading_underscores = strip_leading_underscores
        @record_aliases = {}
        @record_aliases_by_tag_name = {}
        @enum_aliases = {}
        @record_visible_names = {}
        @enum_visible_names = {}
        @referenceable_record_declarations = {}
        @referenceable_record_declarations_by_id = {}
        @aggregate_declarations = {}
        @synthetic_declarations = []
        @manual_nullable_param_overrides = []
        @manual_nullable_return_overrides = []
      end

      def generate
        ast = dump_ast
        index_referenceable_record_declarations(ast)
        top_level_nodes = extract_top_level_header_nodes(ast)
        @visible_typedef_names = top_level_nodes.filter_map do |node|
          node["name"] if node["kind"] == "TypedefDecl" && allowed_declaration_name?(node["name"])
        end
        build_alias_maps(top_level_nodes)

        declarations = []
        declarations.concat(select_record_declarations(top_level_nodes))
        validate_field_type_overrides!(declarations)
        discover_synthetic_aggregate_dependencies(declarations)
        discover_synthetic_field_type_dependencies(declarations)
        declarations.concat(select_enum_declarations(top_level_nodes))
        declarations.concat(select_type_alias_declarations(top_level_nodes))
        declarations.concat(select_constant_declarations(top_level_nodes))
        function_declarations = select_function_declarations(top_level_nodes)
        validate_function_param_type_overrides!(function_declarations)
        validate_function_return_type_overrides!(function_declarations)
        declarations.concat(function_declarations)
        declarations.sort_by! { |declaration| declaration[:index] }

        emit_module(declarations)
      end

      def generate_with_report
        source = generate
        {
          source:,
          nullable_policy_report: nullable_policy_report,
        }
      end

      private

      def nullable_policy_report
        parameter_entries = @manual_nullable_param_overrides.sort_by { |entry| [entry[:function], entry[:parameter]] }
        return_entries = @manual_nullable_return_overrides.sort_by { |entry| entry[:function] }

        {
          module_name: @module_name,
          header_path: @header_path,
          summary: {
            parameters: parameter_entries.length,
            return_types: return_entries.length,
            total: parameter_entries.length + return_entries.length,
          },
          manual_nullable_policy: {
            parameters: parameter_entries,
            return_types: return_entries,
          },
        }
      end

      include GeneratorAstParser
      include GeneratorDeclaration
      include GeneratorTypeMapper
      include GeneratorEmitter
      include GeneratorOverrides
    end
  end

  class BindgenError < StandardError; end
end
