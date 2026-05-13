module std.ctype

import std.c.ctype as c


public function is_alnum(value: int) -> bool:
    return c.mt_ctype_isalnum(value) != 0


public function is_alpha(value: int) -> bool:
    return c.mt_ctype_isalpha(value) != 0


public function is_blank(value: int) -> bool:
    return c.mt_ctype_isblank(value) != 0


public function is_cntrl(value: int) -> bool:
    return c.mt_ctype_iscntrl(value) != 0


public function is_digit(value: int) -> bool:
    return c.mt_ctype_isdigit(value) != 0


public function is_graph(value: int) -> bool:
    return c.mt_ctype_isgraph(value) != 0


public function is_lower(value: int) -> bool:
    return c.mt_ctype_islower(value) != 0


public function is_print(value: int) -> bool:
    return c.mt_ctype_isprint(value) != 0


public function is_punct(value: int) -> bool:
    return c.mt_ctype_ispunct(value) != 0


public function is_space(value: int) -> bool:
    return c.mt_ctype_isspace(value) != 0


public function is_upper(value: int) -> bool:
    return c.mt_ctype_isupper(value) != 0


public function is_xdigit(value: int) -> bool:
    return c.mt_ctype_isxdigit(value) != 0


public foreign function to_lower(value: int) -> int = c.mt_ctype_tolower
public foreign function to_upper(value: int) -> int = c.mt_ctype_toupper
