# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require_relative "../test_helper"

class MilkTeaLanguageBaselineTest < Minitest::Test
  BASELINE_PATH = File.expand_path("../../examples/language_baseline.mt", __dir__)

  # ---------------------------------------------------------------------------
  #  Parse
  # ---------------------------------------------------------------------------

  def test_baseline_parses_without_error
    source = File.read(BASELINE_PATH)
    tokens = MilkTea::Lexer.lex(source)
    parser = MilkTea::Parser.new(tokens)
    ast = parser.parse

    refute_nil ast
    assert_kind_of MilkTea::AST::SourceFile, ast
    refute_empty ast.declarations

    names = declaration_names(ast)

    # --- data declarations
    assert_includes names, "Seconds"
    assert_includes names, "IntCallback"
    assert_includes names, "Vec2"
    assert_includes names, "Header"
    assert_includes names, "Mat4"
    assert_includes names, "Number"
    assert_includes names, "State"
    assert_includes names, "Mask"
    assert_includes names, "RawHandle"
    assert_includes names, "Pair"
    assert_includes names, "TokenKind"
    assert_includes names, "NPC"
    assert_includes names, "Damageable"
    assert_includes names, "Named"
    assert_includes names, "Labeled"
    assert_includes names, "GuardError"

    # --- functions
    assert_includes names, "main"
    assert_includes names, "statements_demo"
    assert_includes names, "expressions_demo"
    assert_includes names, "format_demo"
    assert_includes names, "generics_demo"
    assert_includes names, "builtins_demo"
    assert_includes names, "unsafe_demo"
    assert_includes names, "proc_demo"
    assert_includes names, "void_returning"
    assert_includes names, "simple_noop"
    assert_includes names, "add"
    assert_includes names, "guard_demo"
    assert_includes names, "nullability_demo"
    assert_includes names, "interface_demo"
    assert_includes names, "str_buffer_demo"
    assert_includes names, "heredoc_fmt_demo"
    assert_includes names, "identity"
    assert_includes names, "describe"
    assert_includes names, "make_default"
    assert_includes names, "damage_one"
    assert_includes names, "read_into"
    assert_includes names, "first_pair"
    assert_includes names, "async_child"
    assert_includes names, "async_demo"
    assert_includes names, "emit_ready"
    assert_includes names, "on_ready_callback"
    assert_includes names, "on_ready_once"
    assert_includes names, "schedule_ready_callback"

    # --- external function
    externals = ast.declarations.select { |d| d.is_a?(MilkTea::AST::ExternFunctionDecl) }
    assert_equal 1, externals.length
    assert_equal "atoi", externals.first.name

    # --- imports
    assert_equal 2, ast.imports.length
    assert_equal "std.async", ast.imports.first.path.to_s
    assert_equal "aio", ast.imports.first.alias_name
  end

  # ---------------------------------------------------------------------------
  #  Sema
  # ---------------------------------------------------------------------------

  def test_baseline_sema_passes
    analysis = check_baseline_file

    refute_nil analysis
    assert_equal "examples.language_baseline", analysis.module_name

    function_names = %w[
      main statements_demo expressions_demo builtins_demo
      unsafe_demo proc_demo format_demo generics_demo
      guard_demo nullability_demo interface_demo
      void_returning simple_noop add first_pair read_into
      make_default damage_one describe identity
      async_child async_demo
      emit_ready on_ready_callback on_ready_once schedule_ready_callback
      str_buffer_demo heredoc_fmt_demo
    ]

    function_names.each do |name|
      assert_includes analysis.functions.keys, name, "missing function #{name}"
    end

    # --- verify types are declared
    type_names = %w[Vec2 Header Mat4 Number State Mask RawHandle Pair TokenKind NPC]
    type_names.each do |name|
      assert_includes analysis.types.keys, name, "missing type #{name}"
    end

    # --- verify interface conformance (checked by sema pipeline above)
  end

  # ---------------------------------------------------------------------------
  #  Lowering
  # ---------------------------------------------------------------------------

  def test_baseline_lowers_without_error
    program = check_baseline_program
    ir_program = MilkTea::Lowering.lower(program)

    refute_nil ir_program
    assert_equal "examples.language_baseline", ir_program.module_name
    refute_empty ir_program.structs
    refute_empty ir_program.unions
    refute_empty ir_program.enums
    refute_empty ir_program.functions
    refute_empty ir_program.variants

    function_names = ir_program.functions.map(&:name)
    assert_includes function_names, "main"
    assert_includes function_names, "statements_demo"
    assert_includes function_names, "expressions_demo"
    assert_includes function_names, "builtins_demo"
    assert_includes function_names, "unsafe_demo"
    assert_includes function_names, "proc_demo"
    assert_includes function_names, "format_demo"
    assert_includes function_names, "generics_demo"
    assert_includes function_names, "guard_demo"
    assert_includes function_names, "nullability_demo"
    assert_includes function_names, "interface_demo"
    assert_includes function_names, "str_buffer_demo"
    assert_includes function_names, "heredoc_fmt_demo"
    assert_includes function_names, "damage_one"
    assert_includes function_names, "describe"
  end

  # ---------------------------------------------------------------------------
  #  C Codegen
  # ---------------------------------------------------------------------------

  def test_baseline_generates_c_with_expected_patterns
    program = check_baseline_program
    generated = MilkTea::Codegen.generate_c(program)

    # --- data declarations
    assert_match(/typedef struct.*Vec2/, generated)
    assert_match(/float x;/, generated)
    assert_match(/float y;/, generated)
    assert_match(/packed/, generated)
    assert_match(/aligned\(16\)/, generated)
    assert_match(/typedef union.*Number/, generated)
    assert_match(/typedef uint8_t.*State;/, generated)
    assert_match(/typedef uint32_t.*Mask;/, generated)
    assert_match(/typedef struct.*NPC/, generated)
    assert_match(/typedef struct.*Pair_int_bool/, generated)
    assert_match(/typedef struct.*Pair_int_float/, generated)
    assert_match(/TokenKind_kind/, generated)
    assert_match(/TokenKind_ident/, generated)
    assert_match(/TokenKind_number/, generated)
    assert_match(/TokenKind_kind_eof/, generated)

    # --- enum/flag values
    assert_match(/State_idle = 0/, generated)
    assert_match(/State_running = 1/, generated)
    assert_match(/Mask_a = 1 << 0/, generated)
    assert_match(/Mask_b = 1 << 1/, generated)
    assert_match(/Mask_both/, generated)

    # --- literals
    assert_match(/DECIMAL = 42/, generated)
    assert_match(/PI = 3\.14/, generated)
    assert_match(/YES = true/, generated)
    assert_match(/GREETING/, generated)
    assert_match(/C_GREETING = "hello from C"/, generated)
    assert_match(/VOID_PTR = NULL/, generated)

    # --- static_asserts
    assert_match(/\b_Static_assert/, generated)
    assert_match(/int must be 4 bytes/, generated)
    assert_match(/rename attribute missing on field/, generated)
    assert_match(/traced attribute missing on identity/, generated)

    # --- built-in callables
    assert_match(/\bmt_fatal\b/, generated)
    assert_match(/\breinterpret\b/, generated)

    # --- enums
    assert_match(/GuardError_missing = 1/, generated)
    assert_match(/GuardError_timeout = 2/, generated)

    # --- events
    assert_match(/ready.*emit/, generated)
    assert_match(/ready.*subscribe/, generated)
    assert_match(/ready.*subscribe_once/, generated)

    # --- functions (reachable from main)
    assert_match(/examples_language_baseline_main/, generated)
    assert_match(/examples_language_baseline_statements_demo/, generated)
    assert_match(/examples_language_baseline_expressions_demo/, generated)
    assert_match(/examples_language_baseline_builtins_demo/, generated)
    assert_match(/examples_language_baseline_unsafe_demo/, generated)
    assert_match(/examples_language_baseline_proc_demo/, generated)
    assert_match(/examples_language_baseline_format_demo/, generated)
    assert_match(/examples_language_baseline_generics_demo/, generated)
    assert_match(/examples_language_baseline_nullability_demo/, generated)
    assert_match(/examples_language_baseline_interface_demo/, generated)
    assert_match(/examples_language_baseline_str_buffer_demo/, generated)
    assert_match(/examples_language_baseline_heredoc_fmt_demo/, generated)
    assert_match(/examples_language_baseline_async_child/, generated)
    assert_match(/examples_language_baseline_async_demo/, generated)

    # --- event helpers
    assert_match(/\bmt_event_/, generated)

    # --- str_buffer operations
    assert_match(/mt_str_buffer_/, generated)

    # --- compound assignments
    assert_match(/\+=/, generated)

    # --- flags
    assert_match(/Mask_both/, generated)

    # --- char literal (in statements_demo body, emitted C may use cast)
    assert_match(/char.*65/, generated)

    # --- external function (declared; reachability analysis may exclude)
    # var without initializer (zero-init)
    assert_match(/scratch_buffer/, generated)

    # --- async bridging (main uses aio.wait)
    assert_match(/std_async_wait_int/, generated)
  end

  private

  def check_baseline_file
    Dir.mktmpdir("milk-tea-baseline-sema") do |dir|
      target_path = File.join(dir, "examples", "language_baseline.mt")
      FileUtils.mkdir_p(File.dirname(target_path))
      FileUtils.cp(BASELINE_PATH, target_path)

      MilkTea::ModuleLoader.new(module_roots: [dir, MilkTea.root])
                           .check_file(target_path)
    end
  end

  def check_baseline_program
    Dir.mktmpdir("milk-tea-baseline") do |dir|
      target_path = File.join(dir, "examples", "language_baseline.mt")
      FileUtils.mkdir_p(File.dirname(target_path))
      FileUtils.cp(BASELINE_PATH, target_path)

      MilkTea::ModuleLoader.new(module_roots: [dir, MilkTea.root])
                           .check_program(target_path)
    end
  end

  def declaration_names(ast)
    ast.declarations.filter_map do |decl|
      case decl
      when MilkTea::AST::StructDecl, MilkTea::AST::EnumDecl, MilkTea::AST::FlagsDecl,
           MilkTea::AST::ConstDecl, MilkTea::AST::VarDecl, MilkTea::AST::TypeAliasDecl,
           MilkTea::AST::OpaqueDecl, MilkTea::AST::EventDecl, MilkTea::AST::AttributeDecl,
           MilkTea::AST::InterfaceDecl, MilkTea::AST::UnionDecl, MilkTea::AST::VariantDecl
        decl.name
      when MilkTea::AST::FunctionDef, MilkTea::AST::MethodDef, MilkTea::AST::ExternFunctionDecl,
           MilkTea::AST::ForeignFunctionDecl
        decl.name
      end
    end.compact
  end
end
