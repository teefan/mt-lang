## Keyword lookup — maps identifier lexemes to keyword TokenKind values.
## Uses a str match expression for direct comparison. Non-keyword
## strings return TokenKind.identifier.

import mtc.lexer.token_kinds as tk

public function keyword_kind(lexeme: str) -> tk.TokenKind:
    return match lexeme:
        "align_of":       tk.TokenKind.tk_align_of
        "and":            tk.TokenKind.tk_and
        "as":             tk.TokenKind.tk_as
        "async":          tk.TokenKind.tk_async
        "attribute":      tk.TokenKind.tk_attribute
        "attribute_arg":  tk.TokenKind.tk_attribute_arg
        "attribute_of":   tk.TokenKind.tk_attribute_of
        "attributes_of":  tk.TokenKind.tk_attributes_of
        "await":          tk.TokenKind.tk_await
        "break":          tk.TokenKind.tk_break
        "callable_of":    tk.TokenKind.tk_callable_of
        "compiler_flag":  tk.TokenKind.tk_compiler_flag
        "const":          tk.TokenKind.tk_const
        "consuming":      tk.TokenKind.tk_consuming
        "continue":       tk.TokenKind.tk_continue
        "defer":          tk.TokenKind.tk_defer
        "detach":         tk.TokenKind.tk_detach
        "dyn":            tk.TokenKind.tk_dyn
        "editable":       tk.TokenKind.tk_editable
        "else":           tk.TokenKind.tk_else
        "emit":           tk.TokenKind.tk_emit
        "enum":           tk.TokenKind.tk_enum
        "event":          tk.TokenKind.tk_event
        "extending":      tk.TokenKind.tk_extending
        "external":       tk.TokenKind.tk_external
        "false":          tk.TokenKind.tk_false
        "field_of":       tk.TokenKind.tk_field_of
        "fields_of":      tk.TokenKind.tk_fields_of
        "flags":          tk.TokenKind.tk_flags
        "fn":             tk.TokenKind.tk_fn
        "for":            tk.TokenKind.tk_for
        "foreign":        tk.TokenKind.tk_foreign
        "function":       tk.TokenKind.tk_function
        "gather":         tk.TokenKind.tk_gather
        "has_attribute":  tk.TokenKind.tk_has_attribute
        "if":             tk.TokenKind.tk_if
        "implements":     tk.TokenKind.tk_implements
        "import":         tk.TokenKind.tk_import
        "in":             tk.TokenKind.tk_in
        "include":        tk.TokenKind.tk_include
        "inline":         tk.TokenKind.tk_inline
        "inout":          tk.TokenKind.tk_inout
        "interface":      tk.TokenKind.tk_interface
        "is":             tk.TokenKind.tk_is
        "let":            tk.TokenKind.tk_let
        "link":           tk.TokenKind.tk_link
        "match":          tk.TokenKind.tk_match
        "members_of":     tk.TokenKind.tk_members_of
        "module":         tk.TokenKind.tk_module
        "not":            tk.TokenKind.tk_not
        "null":           tk.TokenKind.tk_null
        "offset_of":      tk.TokenKind.tk_offset_of
        "opaque":         tk.TokenKind.tk_opaque
        "or":             tk.TokenKind.tk_or
        "out":            tk.TokenKind.tk_out
        "parallel":       tk.TokenKind.tk_parallel
        "pass":           tk.TokenKind.tk_pass
        "proc":           tk.TokenKind.tk_proc
        "public":         tk.TokenKind.tk_public
        "return":         tk.TokenKind.tk_return
        "size_of":        tk.TokenKind.tk_size_of
        "static":         tk.TokenKind.tk_static
        "static_assert":  tk.TokenKind.tk_static_assert
        "struct":         tk.TokenKind.tk_struct
        "true":           tk.TokenKind.tk_true
        "type":           tk.TokenKind.tk_type
        "union":          tk.TokenKind.tk_union
        "unsafe":         tk.TokenKind.tk_unsafe
        "var":            tk.TokenKind.tk_var
        "variant":        tk.TokenKind.tk_variant
        "when":           tk.TokenKind.tk_when
        "while":          tk.TokenKind.tk_while
        _:                tk.TokenKind.identifier
