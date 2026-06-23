## Binary and unary operator enums used by the parser.
##
## Prefix convention: `op_` for binary ops, `uop_` for unary ops.

enum BinaryOp: int
    # arithmetic
    op_add = 0
    op_sub = 1
    op_mul = 2
    op_div = 3
    op_mod = 4

    # bitwise
    op_bit_and = 5
    op_bit_or = 6
    op_bit_xor = 7
    op_shift_left = 8
    op_shift_right = 9

    # comparison
    op_eq = 10
    op_ne = 11
    op_lt = 12
    op_le = 13
    op_gt = 14
    op_ge = 15

    # logical
    op_logic_and = 16
    op_logic_or = 17


enum UnaryOp: int
    uop_negate = 0
    uop_bit_not = 1
    uop_logic_not = 2
