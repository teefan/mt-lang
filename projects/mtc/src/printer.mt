import parser.ast_types as ast
import std.str
import std.string
import std.vec


public function print_ast(decls: ref[vec.Vec[ast.Decl]], source: str, output: ref[string.String]) -> void:
    var index: ptr_uint = 0
    while index < decls.len():
        let decl_ptr = decls.get(index) else:
            fatal(c"printer.print_ast missing declaration")
        unsafe:
            print_decl(read(decl_ptr), source, output)
        output.append("\n")
        index += 1


function print_decl(decl: ast.Decl, source: str, output: ref[string.String]) -> void:
    let start = head_start_of(decl)
    let end = head_end_of(decl)
    if end > start and start < source.len and end <= source.len:
        output.append(source.slice(start, end - start))
        return

    name_fallback(decl, output)


function head_start_of(decl: ast.Decl) -> ptr_uint:
    match decl:
        ast.Decl.import_decl(_, _, head_start, _):
            return head_start
        ast.Decl.attribute_decl(_, head_start, _):
            return head_start
        ast.Decl.const_decl(_, _, _, _, head_start, _):
            return head_start
        ast.Decl.var_decl(_, _, head_start, _):
            return head_start
        ast.Decl.type_alias(_, _, head_start, _):
            return head_start
        ast.Decl.struct_decl(_, _, head_start, _):
            return head_start
        ast.Decl.union_decl(_, head_start, _):
            return head_start
        ast.Decl.enum_decl(_, _, head_start, _):
            return head_start
        ast.Decl.flags_decl(_, _, head_start, _):
            return head_start
        ast.Decl.variant_decl(_, _, head_start, _):
            return head_start
        ast.Decl.opaque_decl(_, head_start, _):
            return head_start
        ast.Decl.interface_decl(_, _, head_start, _):
            return head_start
        ast.Decl.extending_block(_, head_start, _):
            return head_start
        ast.Decl.function_decl(_, _, _, _, _, _, _, head_start, _):
            return head_start
        ast.Decl.extern_function(_, _, _, head_start, _):
            return head_start
        ast.Decl.static_assert_decl(_, _, head_start, _):
            return head_start
        ast.Decl.when_block(_, head_start, _):
            return head_start
        ast.Decl.event_decl(_, _, head_start, _):
            return head_start
        ast.Decl.empty:
            return 0


function head_end_of(decl: ast.Decl) -> ptr_uint:
    match decl:
        ast.Decl.import_decl(_, _, _, head_end):
            return head_end
        ast.Decl.attribute_decl(_, _, head_end):
            return head_end
        ast.Decl.const_decl(_, _, _, _, _, head_end):
            return head_end
        ast.Decl.var_decl(_, _, _, head_end):
            return head_end
        ast.Decl.type_alias(_, _, _, head_end):
            return head_end
        ast.Decl.struct_decl(_, _, _, head_end):
            return head_end
        ast.Decl.union_decl(_, _, head_end):
            return head_end
        ast.Decl.enum_decl(_, _, _, head_end):
            return head_end
        ast.Decl.flags_decl(_, _, _, head_end):
            return head_end
        ast.Decl.variant_decl(_, _, _, head_end):
            return head_end
        ast.Decl.opaque_decl(_, _, head_end):
            return head_end
        ast.Decl.interface_decl(_, _, _, head_end):
            return head_end
        ast.Decl.extending_block(_, _, head_end):
            return head_end
        ast.Decl.function_decl(_, _, _, _, _, _, _, _, head_end):
            return head_end
        ast.Decl.extern_function(_, _, _, _, head_end):
            return head_end
        ast.Decl.static_assert_decl(_, _, _, head_end):
            return head_end
        ast.Decl.when_block(_, _, head_end):
            return head_end
        ast.Decl.event_decl(_, _, _, head_end):
            return head_end
        ast.Decl.empty:
            return 0


function name_fallback(decl: ast.Decl, output: ref[string.String]) -> void:
    match decl:
        ast.Decl.import_decl(path, alias, _, _):
            output.append("import ")
            output.append(path)
            if alias.len != 0:
                output.append(" as ")
                output.append(alias)
        ast.Decl.attribute_decl(name, _, _):
            output.append("attribute ")
            output.append(name)
        ast.Decl.const_decl(name, ctype, has_block_body, is_const_fn, _, _):
            if is_const_fn: output.append("const function ") else: output.append("const ")
            output.append(name)
            output.append(" ...")
        ast.Decl.var_decl(name, vtype, _, _):
            output.append("var ")
            output.append(name)
        ast.Decl.type_alias(name, target, _, _):
            output.append("type ")
            output.append(name)
            output.append(" = ...")
        ast.Decl.struct_decl(name, type_params, _, _):
            output.append("struct ")
            output.append(name)
        ast.Decl.union_decl(name, _, _):
            output.append("union ")
            output.append(name)
        ast.Decl.enum_decl(name, backing, _, _):
            output.append("enum ")
            output.append(name)
        ast.Decl.flags_decl(name, backing, _, _):
            output.append("flags ")
            output.append(name)
        ast.Decl.variant_decl(name, type_params, _, _):
            output.append("variant ")
            output.append(name)
        ast.Decl.opaque_decl(name, _, _):
            output.append("opaque ")
            output.append(name)
        ast.Decl.interface_decl(name, type_params, _, _):
            output.append("interface ")
            output.append(name)
        ast.Decl.extending_block(target, _, _):
            output.append("extending ")
            output.append(target)
        ast.Decl.function_decl(name, type_params, params, return_type, is_async, is_foreign, is_const, _, _):
            if is_foreign: output.append("foreign ")
            if is_async: output.append("async ")
            if is_const: output.append("const ")
            output.append("function ")
            output.append(name)
        ast.Decl.extern_function(name, params, return_type, _, _):
            output.append("external function ")
            output.append(name)
        ast.Decl.static_assert_decl(cond, message, _, _):
            output.append("static_assert(...)")
        ast.Decl.when_block(discriminant_line, _, _):
            output.append("when ...")
        ast.Decl.event_decl(name, payload, _, _):
            output.append("event ")
            output.append(name)
        ast.Decl.empty:
            output.append("(empty)")
