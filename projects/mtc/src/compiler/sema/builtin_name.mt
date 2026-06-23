## BuiltinName enum — compiler-recognized builtin function names.
##
## These are the functions listed in §7 of the language manual. The semantic
## analyzer resolves them specially (they don't go through normal name lookup).
##
## Prefix convention: `bi_` to avoid collisions with builtin names that would
## parse as regular identifiers.

public enum BuiltinName: int
    bi_fatal = 0
    bi_ref_of = 1
    bi_const_ptr_of = 2
    bi_ptr_of = 3
    bi_read = 4
    bi_hash = 5
    bi_equal = 6
    bi_order = 7
    bi_zero = 8
    bi_default = 9
    bi_reinterpret = 10
    bi_size_of = 11
    bi_align_of = 12
    bi_offset_of = 13
    bi_get = 14
    bi_adapt = 15
    bi_fields_of = 16
    bi_members_of = 17
    bi_attributes_of = 18
    bi_field_of = 19
    bi_callable_of = 20
    bi_attribute_of = 21
    bi_has_attribute = 22
    bi_attribute_arg = 23
    bi_array = 24
    bi_span = 25
