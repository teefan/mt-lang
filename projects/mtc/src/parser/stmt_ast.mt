import std.vec

public variant Expr:
    literal_int(text: str)
    literal_float(text: str)
    literal_string(text: str)
    literal_cstring(text: str)
    literal_char(text: str)
    literal_bool(value: bool)
    literal_null
    identifier(name: str)
    other(text: str)


public variant Stmt:
    expression(expr_text: str)
    return_stmt(value_text: str)
    let_decl(name: str, type_text: str, value_text: str)
    var_decl(name: str, type_text: str, value_text: str)
    if_stmt(condition_text: str)
    while_stmt(condition_text: str)
    for_stmt(iterable_text: str)
    match_stmt(scrutinee_text: str)
    assign_stmt(target: str, value_text: str)
    compound_assign(target: str, op: str, value_text: str)
    other(text: str)
