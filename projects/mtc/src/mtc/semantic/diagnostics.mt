## Diagnostic message builders — pure leaf functions extracted from the semantic
## analyzer.  These depend only on `types.type_to_string` and `string.String`,
## never on `Context`/`Scope` or other analyzer-internal state.

import std.string as string
import std.str

import mtc.semantic.types as types


public function return_mismatch_message(expected: types.Type, got: types.Type) -> str:
    var buf = string.String.create()
    buf.append("return type mismatch: expected ")
    buf.append(types.type_to_diagnostic_string(expected))
    buf.append(", got ")
    buf.append(types.type_to_diagnostic_string(got))
    return buf.as_str()


public function local_mismatch_message(expected: types.Type, got: types.Type, name: str) -> str:
    var buf = string.String.create()
    buf.append("cannot assign ")
    buf.append(types.type_to_string(got))
    buf.append(" to ")
    buf.append(name)
    buf.append(": expected ")
    buf.append(types.type_to_string(expected))
    return buf.as_str()


## The `let … else:` guard requires a nullable, `Option[T]` or `Result[T, E]`
## initializer (the host's `check_local_decl_let_else`).
public function let_else_initializer_message(name: str, got: types.Type) -> str:
    var buf = string.String.create()
    buf.append("let-else initializer for ")
    buf.append(name)
    buf.append(" must be nullable, Option[T], or Result[T, E], got ")
    buf.append(types.type_to_string(got))
    return buf.as_str()


## Postfix `?` accepts only `Option[T]` or `Result[T, E]` (the host's
## `infer_propagate_expression`).
public function propagation_message(got: types.Type) -> str:
    var buf = string.String.create()
    buf.append("propagation expects Result[T, E] or Option[T], got ")
    buf.append(types.type_to_string(got))
    return buf.as_str()


## The host's `validate_read_call_arguments!`.
public function read_arity_message(got: ptr_uint) -> str:
    var buf = string.String.create()
    buf.append("read expects 1 argument, got ")
    buf.append(uint_to_str(got))
    return buf.as_str()


## The host's `infer_reference_value_type` fallthrough: only `ref[T]`, `ptr[T]`
## and `own[T]` are read sources (a nullable pointer is not).
public function read_operand_message(got: types.Type) -> str:
    var buf = string.String.create()
    buf.append("read expects ref[...] or ptr[...], got ")
    buf.append(types.type_to_string(got))
    return buf.as_str()


public function assign_message(target: types.Type, value: types.Type) -> str:
    var buf = string.String.create()
    buf.append("cannot assign ")
    buf.append(types.type_to_string(value))
    buf.append(" to ")
    buf.append(types.type_to_string(target))
    return buf.as_str()


## `cannot assign to immutable <name>` — the host's identifier-assignment check
## (`expressions.rb:16`).
public function assign_to_let_message(name: str) -> str:
    var buf = string.String.create()
    buf.append("cannot assign to immutable ")
    buf.append(name)
    return buf.as_str()


## `cannot call editable method push on an immutable receiver` — the host names
## the method only, not the receiver binding.
public function editable_on_immutable_message(name: str, method: str) -> str:
    var buf = string.String.create()
    buf.append("cannot call editable method ")
    buf.append(method)
    buf.append(" on an immutable receiver")
    return buf.as_str()


public function def_assign_message(name: str) -> str:
    var buf = string.String.create()
    buf.append("variable '")
    buf.append(name)
    buf.append("' is read before definite assignment")
    return buf.as_str()


public function missing_cases_message(type_name: str, cases: str) -> str:
    var buf = string.String.create()
    buf.append("match on ")
    buf.append(type_name)
    buf.append(" is missing cases: ")
    buf.append(cases)
    return buf.as_str()


public function integer_wildcard_message(type_name: str) -> str:
    var buf = string.String.create()
    buf.append("match on integer type ")
    buf.append(type_name)
    buf.append(" requires a wildcard arm (_:)")
    return buf.as_str()


public function str_wildcard_message() -> str:
    return "match on str requires a wildcard arm (_:)"


public function dup_case_message(type_name: str, member: str) -> str:
    var buf = string.String.create()
    buf.append("duplicate match arm ")
    buf.append(type_name)
    buf.append(".")
    buf.append(member)
    return buf.as_str()


public function dup_value_message(value: int) -> str:
    var buf = string.String.create()
    buf.append("duplicate match arm value ")
    buf.append(int_to_str(value))
    return buf.as_str()


public function int_to_str(value: int) -> str:
    if value < 0:
        return neg_int_to_str(value)
    return uint_to_str(ptr_uint<-value)


public function neg_int_to_str(value: int) -> str:
    var buf = string.String.create()
    buf.append("-")
    buf.append(uint_to_str(ptr_uint<-(-value)))
    return buf.as_str()


public function condition_message(keyword: str, got: types.Type) -> str:
    var buf = string.String.create()
    buf.append(keyword)
    buf.append(" condition must be bool, got ")
    buf.append(types.type_to_string(got))
    return buf.as_str()


public function arity_message(name: str, expected: ptr_uint, got: ptr_uint) -> str:
    var buf = string.String.create()
    buf.append("function ")
    buf.append(name)
    buf.append(" expects ")
    buf.append(uint_to_str(expected))
    buf.append(" arguments, got ")
    buf.append(uint_to_str(got))
    return buf.as_str()


public function unknown_member_message(kind: str, type_name: str, member: str) -> str:
    var buf = string.String.create()
    buf.append("unknown ")
    buf.append(kind)
    buf.append(" ")
    buf.append(type_name)
    buf.append(".")
    buf.append(member)
    return buf.as_str()


public function missing_method_message(type_name: str, iface_name: str, method: str) -> str:
    var buf = string.String.create()
    buf.append(type_name)
    buf.append(" does not implement ")
    buf.append(iface_name)
    buf.append(": missing method ")
    buf.append(method)
    return buf.as_str()


public function method_mismatch_message(type_name: str, iface_name: str, method: str) -> str:
    var buf = string.String.create()
    buf.append(type_name)
    buf.append(".")
    buf.append(method)
    buf.append(" does not match interface ")
    buf.append(iface_name)
    return buf.as_str()


public function hook_missing_message(hook_name: str, type_name: str) -> str:
    var buf = string.String.create()
    buf.append(hook_name)
    buf.append("[")
    buf.append(type_name)
    buf.append("] requires ")
    buf.append(type_name)
    buf.append(".")
    buf.append(hook_name)
    return buf.as_str()


public function constraint_unsatisfied_message(type_name: str, iface_name: str) -> str:
    var buf = string.String.create()
    buf.append("type argument ")
    buf.append(type_name)
    buf.append(" does not implement ")
    buf.append(iface_name)
    return buf.as_str()


public function argument_message(param_name: str, fn_name: str, expected: types.Type, got: types.Type) -> str:
    var buf = string.String.create()
    buf.append("argument ")
    buf.append(param_name)
    buf.append(" to ")
    buf.append(fn_name)
    buf.append(" expects ")
    buf.append(types.type_to_string(expected))
    buf.append(", got ")
    buf.append(types.type_to_string(got))
    return buf.as_str()


public function uint_to_str(value: ptr_uint) -> str:
    if value == 0:
        return "0"
    var digits = string.String.create()
    var n = value
    while n > 0:
        let d = n % 10
        digits.push_byte(ubyte<-(int<-d + 48))
        n = n / 10
    var rev = string.String.create()
    let raw = digits.as_str()
    var i = raw.len
    while i > 0:
        i -= 1
        rev.push_byte(raw.byte_at(i))
    return rev.as_str()


public function named_args_required_message(struct_name: str) -> str:
    var buf = string.String.create()
    buf.append("construction of ")
    buf.append(struct_name)
    buf.append(" requires named arguments")
    return buf.as_str()


## The host's `check_aggregate_field_arguments` wording for an *aggregate*
## construction (a builtin `span[T](…)`, whose context is "aggregate
## construction").
public function aggregate_named_args_required_message(struct_name: str) -> str:
    var buf = string.String.create()
    buf.append("aggregate construction for ")
    buf.append(struct_name)
    buf.append(" requires named arguments")
    return buf.as_str()


public function array_named_args_message() -> str:
    return "array construction does not support named arguments"


public function array_arity_message(length: long, got: ptr_uint) -> str:
    var buf = string.String.create()
    buf.append("array expects at most ")
    buf.append(uint_to_str(ptr_uint<-length))
    buf.append(" elements, got ")
    buf.append(uint_to_str(got))
    return buf.as_str()


public function array_element_message(expected: types.Type, got: types.Type) -> str:
    var buf = string.String.create()
    buf.append("array element expects ")
    buf.append(types.type_to_string(expected))
    buf.append(", got ")
    buf.append(types.type_to_string(got))
    return buf.as_str()


public function duplicate_field_message(struct_name: str, field: str) -> str:
    var buf = string.String.create()
    buf.append("duplicate field ")
    buf.append(struct_name)
    buf.append(".")
    buf.append(field)
    return buf.as_str()


public function field_type_mismatch_message(struct_name: str, field: str, expected: types.Type, got: types.Type) -> str:
    var buf = string.String.create()
    buf.append("field ")
    buf.append(struct_name)
    buf.append(".")
    buf.append(field)
    buf.append(" expects ")
    buf.append(types.type_to_string(expected))
    buf.append(", got ")
    buf.append(types.type_to_string(got))
    return buf.as_str()


public function dup_param_message(func_name: str, param: str) -> str:
    var buf = string.String.create()
    buf.append("duplicate parameter ")
    buf.append(param)
    buf.append(" in function ")
    buf.append(func_name)
    return buf.as_str()


## The host's `<kind> <name> uses reserved built-in type name <name>`.
public function reserved_value_message(kind_label: str, name: str) -> str:
    var buf = string.String.create()
    buf.append(kind_label)
    buf.append(" ")
    buf.append(name)
    buf.append(" uses reserved built-in type name ")
    buf.append(name)
    return buf.as_str()
