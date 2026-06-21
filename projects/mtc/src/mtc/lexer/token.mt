public enum TokenKind: ushort
    ## --- Literal tokens ---
    tk_identifier = 0
    tk_integer = 1
    tk_float = 2
    tk_string = 3
    tk_cstring = 4
    tk_fstring = 5
    tk_char_literal = 6
    ## --- Keywords ---
    tk_align_of = 7
    tk_and = 8
    tk_as = 9
    tk_async = 10
    tk_attribute = 11
    tk_attribute_arg = 12
    tk_attribute_of = 13
    tk_attributes_of = 14
    tk_await = 15
    tk_break = 16
    tk_callable_of = 17
    tk_compiler_flag = 18
    tk_const = 19
    tk_consuming = 20
    tk_continue = 21
    tk_defer = 22
    tk_detach = 23
    tk_dyn = 24
    tk_editable = 25
    tk_else = 26
    tk_emit = 27
    tk_enum = 28
    tk_event = 29
    tk_extending = 30
    tk_external = 31
    tk_false = 32
    tk_field_of = 33
    tk_fields_of = 34
    tk_flags = 35
    tk_fn = 36
    tk_for = 37
    tk_foreign = 38
    tk_function = 39
    tk_gather = 40
    tk_has_attribute = 41
    tk_if = 42
    tk_implements = 43
    tk_import = 44
    tk_in = 45
    tk_include = 46
    tk_inline = 47
    tk_inout = 48
    tk_interface = 49
    tk_is = 50
    tk_let = 51
    tk_link = 52
    tk_match = 53
    tk_members_of = 54
    tk_module = 55
    tk_not = 56
    tk_null = 57
    tk_offset_of = 58
    tk_opaque = 59
    tk_or = 60
    tk_out = 61
    tk_parallel = 62
    tk_pass = 63
    tk_proc = 64
    tk_public = 65
    tk_return = 66
    tk_size_of = 67
    tk_static = 68
    tk_static_assert = 69
    tk_struct = 70
    tk_true = 71
    tk_type = 72
    tk_union = 73
    tk_unsafe = 74
    tk_var = 75
    tk_variant = 76
    tk_when = 77
    tk_while = 78
    ## --- Operators ---
    tk_plus = 79
    tk_minus = 80
    tk_star = 81
    tk_slash = 82
    tk_percent = 83
    tk_amp = 84
    tk_pipe = 85
    tk_caret = 86
    tk_tilde = 87
    tk_equal = 88
    tk_plus_equal = 89
    tk_minus_equal = 90
    tk_star_equal = 91
    tk_slash_equal = 92
    tk_percent_equal = 93
    tk_amp_equal = 94
    tk_pipe_equal = 95
    tk_caret_equal = 96
    tk_shift_left_equal = 97
    tk_shift_right_equal = 98
    tk_equal_equal = 99
    tk_bang_equal = 100
    tk_less = 101
    tk_less_equal = 102
    tk_greater = 103
    tk_greater_equal = 104
    tk_shift_left = 105
    tk_shift_right = 106
    tk_dot_dot = 107
    tk_ellipsis = 108
    ## --- Punctuation ---
    tk_lparen = 109
    tk_rparen = 110
    tk_lbracket = 111
    tk_rbracket = 112
    tk_colon = 113
    tk_comma = 114
    tk_dot = 115
    tk_arrow = 116
    tk_question = 117
    tk_at = 118
    ## --- Synthetic ---
    tk_indent = 119
    tk_dedent = 120
    tk_newline = 121
    tk_eof = 122


public struct Token:
    kind: TokenKind
    lexeme: str
    line: ptr_uint
    column: ptr_uint
    src_offset: ptr_uint
