# frozen_string_literal: true

require_relative "c_backend/reachability"
require_relative "c_backend/statements"
require_relative "c_backend/control_flow"
require_relative "c_backend/helpers"
require_relative "c_backend/types"
require_relative "c_backend/expressions"
require_relative "c_backend/reinterpret"
require_relative "c_backend/collectors"

module MilkTea
  class CBackend
    INDENT = "  "
    ARRAY_OUT_PARAM_NAME = "__mt_out"

    def self.emit(program, emit_line_directives: true)
      new(program, emit_line_directives:).emit
    end

    def initialize(program, emit_line_directives: true)
      @program = program
      @source_path = program.source_path
      @emit_line_directives = emit_line_directives
      @checked_index_alias_stack = []
      @checked_index_alias_id = 0
    end

    def emit
      lines = []
      constants = emitted_constants
      headers = @program.includes.map(&:header)
      if headers.include?("\"fs_support.h\"") || headers.include?("\"tls_support.h\"")
        lines << "#ifndef _GNU_SOURCE"
        lines << "#define _GNU_SOURCE"
        lines << "#endif"
        lines << "#ifndef _POSIX_C_SOURCE"
        lines << "#define _POSIX_C_SOURCE 200809L"
        lines << "#endif"
        lines << ""
      end
      if uses_fatal_helper? || uses_format_helpers?
        headers << "<stdio.h>"
      end
      if uses_fatal_helper? || uses_format_helpers? || uses_async_memory_helpers? || uses_foreign_temp_cstr_helpers?
        headers << "<stdlib.h>"
      end
      headers.uniq.each do |header|
        lines << "#include #{header}"
      end
      lines << ""

      if uses_string_view?
        lines.concat(emit_string_type)
        lines << ""
      end

      if uses_vector_math_types?
        lines.concat(emit_vector_math_types)
        lines << ""
      end

      if uses_fatal_helper?
        lines.concat(emit_fatal_helper)
        lines << ""
      end

      if uses_format_helpers?
        lines.concat(emit_format_helpers)
        lines << ""
      end

      if uses_str_equality_helper?
        lines.concat(emit_str_equality_helper)
        lines << ""
      end

      if uses_text_buffer_helpers?
        lines.concat(emit_text_buffer_helpers)
        lines << ""
      end

      if uses_async_memory_helpers?
        lines.concat(emit_async_memory_helpers)
        lines << ""
      end

      opaque_decls = @program.opaques
      aggregate_decls = sort_aggregate_decls(
        emitted_aggregate_structs + collect_generic_struct_decls + collect_task_decls + collect_proc_decls + collect_str_buffer_decls,
        emitted_aggregate_unions,
        emitted_aggregate_variants + collect_generic_variant_decls,
      )

      forward_declarations = emit_forward_declarations(opaque_decls, aggregate_decls)
      unless forward_declarations.empty?
        lines.concat(forward_declarations)
        lines << ""
      end

      @program.enums.each do |enum_decl|
        lines.concat(emit_enum(enum_decl))
        lines << ""
      end

      collect_span_types.each do |type|
        lines.concat(emit_span_type(type))
        lines << ""
      end

      if uses_entrypoint_argv_helpers?
        lines.concat(emit_entrypoint_argv_helpers)
        lines << ""
      end

      if uses_foreign_temp_cstr_helpers?
        lines.concat(emit_foreign_temp_cstr_helpers)
        lines << ""
      end

      if uses_str_buffer_helpers?
        lines.concat(emit_str_buffer_helpers)
        lines << ""
      end

      aggregate_decls.each do |aggregate_decl|
        case aggregate_decl
        when IR::StructDecl
          lines.concat(emit_struct(aggregate_decl))
        when IR::UnionDecl
          lines.concat(emit_union(aggregate_decl))
        when IR::VariantDecl
          lines.concat(emit_variant(aggregate_decl))
        end
        lines << ""
      end

      function_declarations = emit_function_declarations(emitted_functions)
      unless function_declarations.empty?
        lines.concat(function_declarations)
        lines << ""
      end

      constants.each do |constant|
        lines << "#{constant_storage(constant.type)} #{c_declaration(constant.type, constant.c_name)} = #{emit_initializer(constant.value)};"
      end
      @program.globals.each do |global|
        next unless emitted_globals.include?(global)
        lines << "#{global_storage(global.type)} #{c_declaration(global.type, global.c_name)} = #{emit_initializer(global.value)};"
      end
      lines << "" unless constants.empty? && @program.globals.empty?

      @program.static_asserts.each do |statement|
        lines << emit_static_assert(statement)
      end
      lines << "" unless @program.static_asserts.empty?

      reinterpret_helpers = collect_reinterpret_helpers
      reinterpret_helpers.each do |helper|
        lines.concat(emit_reinterpret_helper(helper))
        lines << ""
      end

      checked_array_index_types = collect_checked_array_index_types
      checked_array_index_types.each do |type|
        lines.concat(emit_checked_array_index_helper(type))
        lines << ""
      end

      checked_span_index_types = collect_checked_span_index_types
      checked_span_index_types.each do |type|
        lines.concat(emit_checked_span_index_helper(type))
        lines << ""
      end

      nullable_array_index_types = collect_checked_array_index_types(nullable_only: true)
      nullable_array_index_types.each do |type|
        lines.concat(emit_nullable_array_index_helper(type))
        lines << ""
      end

      nullable_span_index_types = collect_checked_span_index_types(nullable_only: true)
      nullable_span_index_types.each do |type|
        lines.concat(emit_nullable_span_index_helper(type))
        lines << ""
      end

      emitted_functions.each do |function|
        lines.concat(emit_function(function))
        lines << ""
      end

      lines.join("\n").rstrip + "\n"
    end

    private

    include CBackendReachability
    include CBackendStatements
    include CBackendControlFlow
    include CBackendHelpers
    include CBackendTypes
    include CBackendExpressions
    include CBackendReinterpret
    include CBackendCollectors
  end
end
