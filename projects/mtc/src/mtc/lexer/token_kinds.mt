## Token kind enum — every token type the lexer can emit.
## Keyword-typed members are prefixed `tk_` to avoid collision with MT
## reserved words (e.g. `tk_if` not `if`, `tk_return` not `return`).
##
## The parser consumes tokens and dispatches on the TokenKind value.
## Values match the Ruby compiler's `Token::KEYWORDS` symbols 1:1.

public enum TokenKind: ubyte
    # Structural
    eof       = 0
    newline   = 1
    indent    = 2
    dedent    = 3

    # Identifiers and literals
    identifier    = 4
    integer       = 5
    float_literal = 6
    string        = 7
    cstring       = 8
    char_literal  = 9
    fstring       = 10

    # Single-character punctuation
    dot       = 11
    colon     = 12
    comma     = 13
    question  = 14
    at        = 15
    tilde     = 16

    # Delimiters
    lparen    = 17
    rparen    = 18
    lbracket  = 19
    rbracket  = 20

    # Arithmetic operators
    plus      = 21
    minus     = 22
    star      = 23
    slash     = 24
    percent   = 25

    # Bitwise operators
    amp       = 26
    pipe      = 27
    caret     = 28

    # Comparison
    less      = 29
    greater   = 30
    equal     = 31

    # Multi-character operators
    arrow             = 32
    dot_dot           = 33
    equal_equal       = 34
    bang_equal        = 35
    less_equal        = 36
    greater_equal     = 37
    shift_left        = 38
    shift_right       = 39

    # Compound assignment
    plus_equal        = 40
    minus_equal       = 41
    star_equal        = 42
    slash_equal       = 43
    percent_equal     = 44
    amp_equal         = 45
    pipe_equal        = 46
    caret_equal       = 47
    shift_left_equal  = 48
    shift_right_equal = 49

    ellipsis          = 50

    # --- Keywords (tk_ prefix) ---
    tk_align_of       = 51
    tk_and            = 52
    tk_as             = 53
    tk_async          = 54
    tk_attribute      = 55
    tk_attribute_arg  = 56
    tk_attribute_of   = 57
    tk_attributes_of  = 58
    tk_await          = 59
    tk_break          = 60
    tk_callable_of    = 61
    tk_compiler_flag  = 62
    tk_const          = 63
    tk_consuming      = 64
    tk_continue       = 65
    tk_defer          = 66
    tk_detach         = 67
    tk_dyn            = 68
    tk_editable       = 69
    tk_else           = 70
    tk_emit           = 71
    tk_enum           = 72
    tk_event          = 73
    tk_extending      = 74
    tk_external       = 75
    tk_false          = 76
    tk_field_of       = 77
    tk_fields_of      = 78
    tk_flags          = 79
    tk_fn             = 80
    tk_for            = 81
    tk_foreign        = 82
    tk_function       = 83
    tk_gather         = 84
    tk_has_attribute  = 85
    tk_if             = 86
    tk_implements     = 87
    tk_import         = 88
    tk_in             = 89
    tk_include        = 90
    tk_inline         = 91
    tk_inout          = 92
    tk_interface      = 93
    tk_is             = 94
    tk_let            = 95
    tk_link           = 96
    tk_match          = 97
    tk_members_of     = 98
    tk_module         = 99
    tk_not            = 100
    tk_null           = 101
    tk_offset_of      = 102
    tk_opaque         = 103
    tk_or             = 104
    tk_out            = 105
    tk_parallel       = 106
    tk_pass           = 107
    tk_proc           = 108
    tk_public         = 109
    tk_return         = 110
    tk_size_of        = 111
    tk_static         = 112
    tk_static_assert  = 113
    tk_struct         = 114
    tk_true           = 115
    tk_type           = 116
    tk_union          = 117
    tk_unsafe         = 118
    tk_var            = 119
    tk_variant        = 120
    tk_when           = 121
    tk_while          = 122
