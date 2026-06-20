# Token definitions for the self-hosting Milk Tea compiler.
#
# Mirrors the Ruby lib/milk_tea/core/token.rb KEYWORDS map and operator tables.
# TokenKind arms are sorted alphabetically within each group.

public variant TokenKind:
    eof

    # ── Keywords ──
    keyword_align_of
    keyword_and
    keyword_as
    keyword_async
    keyword_attribute
    keyword_attribute_arg
    keyword_attribute_of
    keyword_attributes_of
    keyword_await
    keyword_break
    keyword_callable_of
    keyword_compiler_flag
    keyword_const
    keyword_consuming
    keyword_continue
    keyword_defer
    keyword_detach
    keyword_dyn
    keyword_editable
    keyword_else
    keyword_emit
    keyword_enum
    keyword_event
    keyword_external
    keyword_extending
    keyword_false
    keyword_field_of
    keyword_fields_of
    keyword_flags
    keyword_fn
    keyword_for
    keyword_foreign
    keyword_function
    keyword_gather
    keyword_has_attribute
    keyword_if
    keyword_implements
    keyword_in
    keyword_include
    keyword_inline
    keyword_inout
    keyword_import
    keyword_interface
    keyword_let
    keyword_link
    keyword_match
    keyword_members_of
    keyword_module
    keyword_not
    keyword_null
    keyword_offset_of
    keyword_opaque
    keyword_or
    keyword_out
    keyword_parallel
    keyword_pass
    keyword_proc
    keyword_public
    keyword_return
    keyword_size_of
    keyword_static
    keyword_static_assert
    keyword_struct
    keyword_true
    keyword_type
    keyword_union
    keyword_unsafe
    keyword_var
    keyword_variant
    keyword_when
    keyword_while

    # ── Identifiers / Literals ──
    identifier(name: str)
    string_literal(value: str)
    cstring_literal(value: str)
    int_literal(value: int)
    float_literal(value: float)
    char_literal(value: ubyte)
    fstring_literal

    # ── Single-char operators ──
    op_ampersand
    op_at
    op_caret
    op_colon
    op_comma
    op_dot
    op_equal
    op_greater
    op_hash
    op_less
    op_lparen
    op_lbracket
    op_minus
    op_percent
    op_pipe
    op_plus
    op_question
    op_rparen
    op_rbracket
    op_slash
    op_star
    op_tilde

    # ── Single-char assignment / value ──
    op_assign

    # ── Two-char operators ──
    op_arrow
    op_dot_dot
    op_not_equal
    op_less_equal
    op_greater_equal
    op_shift_left
    op_shift_right

    # ── Two-char assignment operators ──
    op_plus_assign
    op_minus_assign
    op_star_assign
    op_slash_assign
    op_percent_assign
    op_amp_equal
    op_pipe_equal
    op_caret_equal

    # ── Three-char operators ──
    op_shift_left_equal
    op_shift_right_equal
    op_ellipsis

    # ── Lexical structure ──
    indent
    dedent
    newline

public struct Token:
    kind: TokenKind
    lexeme: str
    line: int
    column: int
    start_offset: ptr_uint
