## TokenKind enum — every token type the lexer can produce.
##
## Prefix convention: `tk_` to avoid collisions with C keywords (int, float,
## return, if, etc.) and Milk Tea keywords (and, or, not, type, etc.).

public enum TokenKind: int
    # ── structural ───────────────────────────────────────────────
    tk_eof = 0
    tk_newline = 1
    tk_indent = 2
    tk_dedent = 3

    # ── single-char delimiters ───────────────────────────────────
    tk_lparen = 4
    tk_rparen = 5
    tk_lbracket = 6
    tk_rbracket = 7
    tk_colon = 8
    tk_comma = 9
    tk_dot = 10
    tk_at = 11
    tk_question = 12

    # ── single-char arithmetic ───────────────────────────────────
    tk_plus = 13
    tk_minus = 14
    tk_star = 15
    tk_slash = 16
    tk_percent = 17

    # ── single-char bitwise ──────────────────────────────────────
    tk_amp = 18
    tk_pipe = 19
    tk_caret = 20
    tk_tilde = 21

    # ── single-char comparison ───────────────────────────────────
    tk_less = 22
    tk_greater = 23

    # ── single-char assignment ───────────────────────────────────
    tk_equal = 24

    # ── multi-char operators ─────────────────────────────────────
    tk_arrow = 25
    tk_dot_dot = 26
    tk_plus_equal = 27
    tk_minus_equal = 28
    tk_star_equal = 29
    tk_slash_equal = 30
    tk_percent_equal = 31
    tk_amp_equal = 32
    tk_pipe_equal = 33
    tk_caret_equal = 34
    tk_equal_equal = 35
    tk_bang_equal = 36
    tk_less_equal = 37
    tk_greater_equal = 38
    tk_shift_left = 39
    tk_shift_right = 40
    tk_shift_left_equal = 41
    tk_shift_right_equal = 42
    tk_ellipsis = 43

    # ── literals ─────────────────────────────────────────────────
    tk_integer = 44
    tk_float = 45
    tk_string = 46
    tk_cstring = 47
    tk_char_literal = 48
    tk_fstring = 49
    tk_identifier = 50

    # ── boolean and null literal keywords ────────────────────────
    tk_kw_true = 51
    tk_kw_false = 52
    tk_kw_null = 53

    # ── word operators ───────────────────────────────────────────
    tk_kw_and = 54
    tk_kw_or = 55
    tk_kw_not = 56
    tk_kw_is = 57
    tk_kw_as = 58

    # ── parameter mode keywords ──────────────────────────────────
    tk_kw_in = 59
    tk_kw_out = 60
    tk_kw_inout = 61

    # ── control flow keywords ────────────────────────────────────
    tk_kw_if = 62
    tk_kw_else = 63
    tk_kw_for = 64
    tk_kw_while = 65
    tk_kw_match = 66
    tk_kw_when = 67
    tk_kw_return = 68
    tk_kw_break = 69
    tk_kw_continue = 70
    tk_kw_defer = 71
    tk_kw_pass = 72
    tk_kw_unsafe = 73
    tk_kw_await = 74
    tk_kw_parallel = 75
    tk_kw_gather = 76
    tk_kw_detach = 77
    tk_kw_inline = 78
    tk_kw_emit = 79

    # ── declaration keywords ─────────────────────────────────────
    tk_kw_let = 80
    tk_kw_var = 81
    tk_kw_const = 82
    tk_kw_function = 83
    tk_kw_struct = 84
    tk_kw_union = 85
    tk_kw_enum = 86
    tk_kw_flags = 87
    tk_kw_variant = 88
    tk_kw_opaque = 89
    tk_kw_type = 90
    tk_kw_interface = 91
    tk_kw_attribute = 92
    tk_kw_event = 93
    tk_kw_extending = 94
    tk_kw_implements = 95
    tk_kw_import = 96
    tk_kw_public = 97
    tk_kw_external = 98
    tk_kw_foreign = 99
    tk_kw_async = 100
    tk_kw_editable = 101
    tk_kw_static = 102
    tk_kw_consuming = 103
    tk_kw_fn = 104
    tk_kw_proc = 105
    tk_kw_module = 106
    tk_kw_dyn = 107

    # ── directive keywords ───────────────────────────────────────
    tk_kw_include = 108
    tk_kw_link = 109
    tk_kw_compiler_flag = 110
    tk_kw_static_assert = 111

    # ── builtin names (also keywords) ────────────────────────────
    tk_kw_size_of = 112
    tk_kw_align_of = 113
    tk_kw_offset_of = 114
    tk_kw_fields_of = 115
    tk_kw_members_of = 116
    tk_kw_attributes_of = 117
    tk_kw_field_of = 118
    tk_kw_callable_of = 119
    tk_kw_attribute_of = 120
    tk_kw_has_attribute = 121
    tk_kw_attribute_arg = 122

    tk_larrow = 123
