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

    let bs = body_start_of(decl)
    let be = body_end_of(decl)
    if be > bs and bs < source.len and be <= source.len:
        output.append(source.slice(bs, be - bs))


function head_start_of(decl: ast.Decl) -> ptr_uint:
    match decl:
        ast.Decl.import_decl(_, _, head_start, _):
            return head_start
        ast.Decl.attribute_decl(_, head_start, _):
            return head_start
        ast.Decl.const_decl(_, _, _, _, head_start, _, _, _):
            return head_start
        ast.Decl.var_decl(_, _, head_start, _):
            return head_start
        ast.Decl.type_alias(_, _, head_start, _):
            return head_start
        ast.Decl.struct_decl(_, _, head_start, _, _, _):
            return head_start
        ast.Decl.union_decl(_, head_start, _, _, _):
            return head_start
        ast.Decl.enum_decl(_, _, head_start, _, _, _):
            return head_start
        ast.Decl.flags_decl(_, _, head_start, _, _, _):
            return head_start
        ast.Decl.variant_decl(_, _, head_start, _, _, _):
            return head_start
        ast.Decl.opaque_decl(_, head_start, _):
            return head_start
        ast.Decl.interface_decl(_, _, head_start, _, _, _):
            return head_start
        ast.Decl.extending_block(_, head_start, _, _, _):
            return head_start
        ast.Decl.function_decl(_, _, _, _, _, _, _, head_start, _, _, _):
            return head_start
        ast.Decl.extern_function(_, _, _, head_start, _):
            return head_start
        ast.Decl.static_assert_decl(_, _, head_start, _):
            return head_start
        ast.Decl.when_block(_, head_start, _, _, _):
            return head_start
        ast.Decl.event_decl(_, _, head_start, _):
            return head_start
        _:
            return 0


function head_end_of(decl: ast.Decl) -> ptr_uint:
    match decl:
        ast.Decl.import_decl(_, _, _, head_end):
            return head_end
        ast.Decl.attribute_decl(_, _, head_end):
            return head_end
        ast.Decl.const_decl(_, _, _, _, _, head_end, _, _):
            return head_end
        ast.Decl.var_decl(_, _, _, head_end):
            return head_end
        ast.Decl.type_alias(_, _, _, head_end):
            return head_end
        ast.Decl.struct_decl(_, _, _, head_end, _, _):
            return head_end
        ast.Decl.union_decl(_, _, head_end, _, _):
            return head_end
        ast.Decl.enum_decl(_, _, _, head_end, _, _):
            return head_end
        ast.Decl.flags_decl(_, _, _, head_end, _, _):
            return head_end
        ast.Decl.variant_decl(_, _, _, head_end, _, _):
            return head_end
        ast.Decl.opaque_decl(_, _, head_end):
            return head_end
        ast.Decl.interface_decl(_, _, _, head_end, _, _):
            return head_end
        ast.Decl.extending_block(_, _, head_end, _, _):
            return head_end
        ast.Decl.function_decl(_, _, _, _, _, _, _, _, head_end, _, _):
            return head_end
        ast.Decl.extern_function(_, _, _, _, head_end):
            return head_end
        ast.Decl.static_assert_decl(_, _, _, head_end):
            return head_end
        ast.Decl.when_block(_, _, head_end, _, _):
            return head_end
        ast.Decl.event_decl(_, _, _, head_end):
            return head_end
        _:
            return 0


function body_start_of(decl: ast.Decl) -> ptr_uint:
    match decl:
        ast.Decl.const_decl(_, _, _, _, _, _, body_start, _):
            return body_start
        ast.Decl.struct_decl(_, _, _, _, body_start, _):
            return body_start
        ast.Decl.union_decl(_, _, _, body_start, _):
            return body_start
        ast.Decl.enum_decl(_, _, _, _, body_start, _):
            return body_start
        ast.Decl.flags_decl(_, _, _, _, body_start, _):
            return body_start
        ast.Decl.variant_decl(_, _, _, _, body_start, _):
            return body_start
        ast.Decl.interface_decl(_, _, _, _, body_start, _):
            return body_start
        ast.Decl.extending_block(_, _, _, body_start, _):
            return body_start
        ast.Decl.function_decl(_, _, _, _, _, _, _, _, _, body_start, _):
            return body_start
        ast.Decl.when_block(_, _, _, body_start, _):
            return body_start
        _:
            return 0


function body_end_of(decl: ast.Decl) -> ptr_uint:
    match decl:
        ast.Decl.const_decl(_, _, _, _, _, _, _, body_end):
            return body_end
        ast.Decl.struct_decl(_, _, _, _, _, body_end):
            return body_end
        ast.Decl.union_decl(_, _, _, _, body_end):
            return body_end
        ast.Decl.enum_decl(_, _, _, _, _, body_end):
            return body_end
        ast.Decl.flags_decl(_, _, _, _, _, body_end):
            return body_end
        ast.Decl.variant_decl(_, _, _, _, _, body_end):
            return body_end
        ast.Decl.interface_decl(_, _, _, _, _, body_end):
            return body_end
        ast.Decl.extending_block(_, _, _, _, body_end):
            return body_end
        ast.Decl.function_decl(_, _, _, _, _, _, _, _, _, _, body_end):
            return body_end
        ast.Decl.when_block(_, _, _, _, body_end):
            return body_end
        _:
            return 0
