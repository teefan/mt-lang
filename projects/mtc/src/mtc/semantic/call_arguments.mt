## Call-argument canonicalization, extracted from semantic/analyzer.mt.

import std.mem.heap as heap
import std.string as string
import std.vec as vec

import mtc.parser.ast as ast
import mtc.semantic.analyzer as analyzer


public function canonicalize_call_arguments_for(
    ctx: ref[analyzer.Context],
    display_name: str,
    sig: analyzer.FnSig,
    args: span[ast.Argument],
    line: ptr_uint,
    column: ptr_uint,
    dest: ref[vec.Vec[ast.Argument]],
) -> void:
    var slots = vec.Vec[ast.Argument].create()
    defer: slots.release()
    var filled = vec.Vec[bool].create()
    defer: filled.release()
    var pi: ptr_uint = 0
    while pi < sig.params.len:
        slots.push(zero[ast.Argument])
        filled.push(false)
        pi += 1

    var named_seen = false
    var i: ptr_uint = 0
    while i < args.len:
        var arg: ast.Argument
        unsafe:
            arg = read(args.data + i)
        match arg.arg_name:
            Option.some as nm:
                named_seen = true
                var found = false
                var duplicate = false
                var pj: ptr_uint = 0
                while pj < sig.params.len:
                    if unsafe: read(sig.params.data + pj).name == nm.value:
                        found = true
                        let slot_ptr = slots.get(pj)
                        if slot_ptr != null:
                            unsafe:
                                match read(ptr[ast.Argument]<-slot_ptr).arg_name:
                                    Option.some as existing:
                                        if existing.value == nm.value:
                                            duplicate = true
                                    Option.none:
                                        pass
                        if duplicate:
                            analyzer.report(ctx, line, column, duplicate_named_argument_message(nm.value, display_name))
                        else:
                            unsafe:
                                read(ptr[ast.Argument]<-slot_ptr) = arg
                            let fptr = filled.get(pj)
                            if fptr != null:
                                unsafe:
                                    read(fptr) = true
                        break
                    pj += 1
                if not found:
                    analyzer.report(ctx, line, column, unknown_parameter_message(nm.value, display_name))
            Option.none:
                if named_seen:
                    analyzer.report(ctx, line, column, positional_after_named_message(display_name))
                var placed = false
                var pj: ptr_uint = 0
                while pj < sig.params.len:
                    if not bool_slot(ref_of(filled), pj):
                        let slot_ptr = slots.get(pj)
                        if slot_ptr != null:
                            unsafe:
                                read(ptr[ast.Argument]<-slot_ptr) = ast.Argument(
                                    arg_name = Option[str].none,
                                    arg_value = arg.arg_value
                                )
                        let fptr = filled.get(pj)
                        if fptr != null:
                            unsafe:
                                read(fptr) = true
                        placed = true
                        break
                    pj += 1
                if not placed:
                    analyzer.report(ctx, line, column, analyzer.arity_message(display_name, sig.params.len, args.len))
        i += 1

    # Omitted defaulted parameters keep their slot; the lowering fills the real
    # default expression, while analysis only needs an error placeholder whose
    # type is permissive.
    var error_expr = heap.must_alloc[ast.Expr](1)
    unsafe:
        read(error_expr) = ast.Expr.expr_error(line = 0, column = 0, message = "")
    var result = vec.Vec[ast.Argument].create()
    pi = 0
    while pi < sig.params.len:
        if bool_slot(ref_of(filled), pi):
            let slot_ptr = slots.get(pi)
            if slot_ptr != null:
                unsafe:
                    let slot_arg = read(ptr[ast.Argument]<-slot_ptr)
                    result.push(ast.Argument(arg_name = Option[str].none, arg_value = slot_arg.arg_value))
        else if pi >= sig.required_count:
            result.push(ast.Argument(arg_name = Option[str].none, arg_value = error_expr))
        pi += 1
    read(dest) = result


function bool_slot(values: ref[vec.Vec[bool]], index: ptr_uint) -> bool:
    let ptr_value = values.get(index)
    if ptr_value == null:
        return false
    return unsafe: read(ptr_value)


function duplicate_named_argument_message(name: str, display_name: str) -> str:
    var buf = string.String.create()
    buf.append("duplicate named argument '")
    buf.append(name)
    buf.append("' in call to ")
    buf.append(display_name)
    return buf.as_str()


function unknown_parameter_message(name: str, display_name: str) -> str:
    var buf = string.String.create()
    buf.append("unknown parameter '")
    buf.append(name)
    buf.append("' for ")
    buf.append(display_name)
    return buf.as_str()


function positional_after_named_message(display_name: str) -> str:
    var buf = string.String.create()
    buf.append("positional argument after named argument in call to ")
    buf.append(display_name)
    return buf.as_str()
