## In-language tests for IR structural verification (Wave 4.1).
## Run with: mtc test projects/mtc
##
## Each test builds a small `ir.Program` directly (no source parse/lowering) and
## plants one violation; the verifier must report it.  The valid case keeps the
## same construction path so a false positive fails too.

import std.mem.heap as heap
import std.string as string
import std.vec as vec

import mtc.ir as ir
import mtc.ir_verify as ir_verify
import mtc.semantic.types as types


function alloc_stmt(value: ir.Stmt) -> ptr[ir.Stmt]:
    var node = heap.must_alloc[ir.Stmt](1)
    unsafe:
        read(node) = value
    return node


function alloc_expr(value: ir.Expr) -> ptr[ir.Expr]:
    var node = heap.must_alloc[ir.Expr](1)
    unsafe:
        read(node) = value
    return node


function int_expr() -> ptr[ir.Expr]:
    return alloc_expr(ir.Expr.expr_integer_literal(value = 0l, ty = types.primitive("int")))


function make_function(linkage_name: str) -> ir.Function:
    return ir.Function(
        name = "f",
        linkage_name = linkage_name,
        params = span[ir.Param](),
        return_type = types.primitive("int"),
        body = span[ir.Stmt](),
        entry_point = false,
        public_export = false,
        method_receiver_param = false,
        source_module = Option[str].none,
    )


function program_with_functions(functions: ref[vec.Vec[ir.Function]]) -> ir.Program:
    var program = ir.empty_program("m", "m.mt")
    program.functions = functions.as_span()
    return program


function expect_valid(program: ir.Program) -> void:
    match ir_verify.verify(program):
        Option.some as error:
            expect(false, error.value.as_str())
            error.value.release()
        Option.none:
            expect(true)


function expect_invalid(program: ir.Program, needle: str) -> void:
    match ir_verify.verify(program):
        Option.some as error:
            expect(error.value.as_str().contains_substring(needle), needle)
            error.value.release()
        Option.none:
            expect(false, needle)


@[test]
function test_empty_program_is_valid() -> void:
    expect_valid(ir.empty_program("m", "m.mt"))


@[test]
function test_valid_function_is_accepted() -> void:
    var functions = vec.Vec[ir.Function].create()
    defer: functions.release()
    functions.push(make_function("m_f"))
    expect_valid(program_with_functions(ref_of(functions)))


@[test]
function test_duplicate_function_linkage_is_rejected() -> void:
    var functions = vec.Vec[ir.Function].create()
    defer: functions.release()
    functions.push(make_function("m_f"))
    functions.push(make_function("m_f"))
    expect_invalid(program_with_functions(ref_of(functions)), "duplicate linkage name")


@[test]
function test_unresolved_parameter_type_is_rejected() -> void:
    var params = vec.Vec[ir.Param].create()
    defer: params.release()
    params.push(ir.Param(
        name = "x",
        linkage_name = "x",
        ty = types.Type.ty_error,
        pointer = Option[bool].none,
    ))
    var decl = make_function("m_f")
    decl.params = params.as_span()
    var functions = vec.Vec[ir.Function].create()
    defer: functions.release()
    functions.push(decl)
    expect_invalid(program_with_functions(ref_of(functions)), "ty_error")


@[test]
function test_type_variable_return_is_rejected() -> void:
    var decl = make_function("m_f")
    decl.return_type = types.Type.ty_var(name = "T")
    var functions = vec.Vec[ir.Function].create()
    defer: functions.release()
    functions.push(decl)
    expect_invalid(program_with_functions(ref_of(functions)), "ty_var")


@[test]
function test_duplicate_struct_field_is_rejected() -> void:
    var fields = vec.Vec[ir.Field].create()
    defer: fields.release()
    fields.push(ir.Field(name = "x", ty = types.primitive("int")))
    fields.push(ir.Field(name = "x", ty = types.primitive("int")))
    var structs = vec.Vec[ir.StructDecl].create()
    defer: structs.release()
    structs.push(ir.StructDecl(
        name = "S",
        linkage_name = "m_S",
        fields = fields.as_span(),
        packed = false,
        alignment = 0,
        source_module = Option[str].none,
    ))
    var program = ir.empty_program("m", "m.mt")
    program.structs = structs.as_span()
    expect_invalid(program, "duplicate field name")


@[test]
function test_duplicate_label_is_rejected() -> void:
    var body = vec.Vec[ir.Stmt].create()
    defer: body.release()
    body.push(unsafe: read(alloc_stmt(ir.Stmt.stmt_label(name = "L"))))
    body.push(unsafe: read(alloc_stmt(ir.Stmt.stmt_label(name = "L"))))
    var decl = make_function("m_f")
    decl.body = body.as_span()
    var functions = vec.Vec[ir.Function].create()
    defer: functions.release()
    functions.push(decl)
    expect_invalid(program_with_functions(ref_of(functions)), "duplicate label")


@[test]
function test_goto_to_missing_label_is_rejected() -> void:
    var body = vec.Vec[ir.Stmt].create()
    defer: body.release()
    body.push(unsafe: read(alloc_stmt(ir.Stmt.stmt_goto(label = "missing"))))
    var decl = make_function("m_f")
    decl.body = body.as_span()
    var functions = vec.Vec[ir.Function].create()
    defer: functions.release()
    functions.push(decl)
    expect_invalid(program_with_functions(ref_of(functions)), "goto target is not defined")


@[test]
function test_goto_to_defined_label_is_accepted() -> void:
    var body = vec.Vec[ir.Stmt].create()
    defer: body.release()
    body.push(unsafe: read(alloc_stmt(ir.Stmt.stmt_label(name = "L"))))
    body.push(unsafe: read(alloc_stmt(ir.Stmt.stmt_goto(label = "L"))))
    var decl = make_function("m_f")
    decl.body = body.as_span()
    var functions = vec.Vec[ir.Function].create()
    defer: functions.release()
    functions.push(decl)
    expect_valid(program_with_functions(ref_of(functions)))


@[test]
function test_multiple_switch_defaults_are_rejected() -> void:
    var cases = vec.Vec[ir.SwitchCase].create()
    defer: cases.release()
    cases.push(ir.SwitchCase(
        is_default = true,
        value = null,
        body = span[ir.Stmt](),
    ))
    cases.push(ir.SwitchCase(
        is_default = true,
        value = null,
        body = span[ir.Stmt](),
    ))
    var body = vec.Vec[ir.Stmt].create()
    defer: body.release()
    body.push(unsafe: read(alloc_stmt(ir.Stmt.stmt_switch(
        expression = int_expr(),
        cases = cases.as_span(),
        exhaustive = false,
    ))))
    var decl = make_function("m_f")
    decl.body = body.as_span()
    var functions = vec.Vec[ir.Function].create()
    defer: functions.release()
    functions.push(decl)
    expect_invalid(program_with_functions(ref_of(functions)), "multiple default cases")


@[test]
function test_invalid_entrypoint_linkage_is_rejected() -> void:
    var decl = make_function("m_main")
    decl.entry_point = true
    var functions = vec.Vec[ir.Function].create()
    defer: functions.release()
    functions.push(decl)
    expect_invalid(program_with_functions(ref_of(functions)), "entry point is not linked as main")


@[test]
function test_empty_source_module_is_rejected() -> void:
    var decl = make_function("m_f")
    decl.source_module = Option[str].some(value = "")
    var functions = vec.Vec[ir.Function].create()
    defer: functions.release()
    functions.push(decl)
    expect_invalid(program_with_functions(ref_of(functions)), "empty source module")
