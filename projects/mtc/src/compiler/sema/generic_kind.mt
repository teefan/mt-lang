## GenericTypeKind enum — generic type constructor names.
##
## These are the type constructors listed in §6.2 of the language manual.
## The semantic analyzer identifies them when parsing type references with
## arguments (e.g., ptr[int], span[ubyte], array[float, 16]).
##
## Prefix convention: `gk_` to avoid collisions with C keywords and other enums.

public enum GenericTypeKind: int
    gk_ptr = 0
    gk_const_ptr = 1
    gk_ref = 2
    gk_span = 3
    gk_array = 4
    gk_str_buffer = 5
    gk_atomic = 6
    gk_task = 7
    gk_option = 8
    gk_result = 9
    gk_fn = 10
    gk_proc = 11
    gk_soa = 12
    gk_dyn = 13
    gk_tuple = 14
