# Token definitions for the self-hosting Milk Tea compiler.

public variant TokenKind:
    eof

    # Keywords
    keyword_function
    keyword_let
    keyword_var
    keyword_return
    keyword_if
    keyword_else
    keyword_for
    keyword_while
    keyword_match
    keyword_break
    keyword_continue
    keyword_pass
    keyword_import
    keyword_as
    keyword_public
    keyword_struct
    keyword_union
    keyword_enum
    keyword_flags
    keyword_variant
    keyword_opaque
    keyword_extending
    keyword_interface
    keyword_implements
    keyword_external
    keyword_foreign
    keyword_function_async
    keyword_function_const
    keyword_unsafe
    keyword_defer
    keyword_await
    keyword_type
    keyword_const
    keyword_attribute
    keyword_event
    keyword_static_assert
    keyword_emit
    keyword_when
    keyword_inline
    keyword_parallel
    keyword_and
    keyword_or
    keyword_not
    keyword_true
    keyword_false
    keyword_null

    # Identifiers / Literals
    identifier(name: str)
    string_literal(value: str)
    cstring_literal(value: str)
    int_literal(value: int)

    # Operators
    op_plus
    op_minus
    op_star
    op_slash
    op_percent
    op_equal
    op_not_equal
    op_less
    op_less_equal
    op_greater
    op_greater_equal
    op_assign
    op_plus_assign
    op_minus_assign
    op_star_assign
    op_slash_assign
    op_percent_assign
    op_arrow
    op_dot
    op_comma
    op_colon
    op_semicolon
    op_lparen
    op_rparen
    op_lbracket
    op_rbracket
    op_question
    op_ampersand
    op_pipe
    op_caret
    op_tilde
    op_shift_left
    op_shift_right
    op_hash
    op_double_dot
    op_double_colon
    op_ellipsis

    # Indentation
    indent
    dedent
    newline

public struct Token:
    kind: TokenKind
    line: int
    column: int
    length: int
