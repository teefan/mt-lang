# In-language semantic analyzer tests for the self-hosted mtc compiler.
# Run with: mtc test projects/mtc

import std.fs as fs
import std.path as path_ops
import std.string as string
import std.vec as vec

import mtc.loader.module_loader as loader
import mtc.loader.path_resolver as resolver
import mtc.parser.ast as ast
import mtc.parser.parser as parser
import mtc.parser.state as pstate
import mtc.semantic.analyzer as analyzer
import mtc.semantic.control_flow.builder as cfgb
import mtc.semantic.control_flow.graph as cfgg
import mtc.semantic.types as types


## Remove a temp directory tree and release its owned path string.
function cleanup_dir(dir: ref[string.String]) -> void:
    match fs.remove_tree(dir.as_str()):
        Result.success:
            pass
        Result.failure as f:
            var e = f.error
            e.release()
    dir.release()


## Write `content` to `dir/relative`, creating parent directories as needed.
function write_file(dir: str, relative: str, content: str) -> bool:
    var full = path_ops.join(dir, relative)
    defer: full.release()

    match fs.create_directories(path_ops.dirname(full.as_str())):
        Result.failure as f:
            var e = f.error
            e.release()
            return false
        Result.success:
            pass

    match fs.write_text(full.as_str(), content):
        Result.failure as f:
            var e = f.error
            e.release()
            return false
        Result.success:
            return true


## Parse then semantically analyze `source`, returning the diagnostic count.
## The source is expected to parse cleanly; only semantic diagnostics count.
function diagnostic_count(source: str) -> ptr_uint:
    var pdiags = vec.Vec[pstate.ParseDiagnostic].create()
    defer: pdiags.release()
    let file = parser.parse_source(source, ref_of(pdiags))
    if pdiags.len() > 0:
        return pdiags.len()
    var analysis = analyzer.check_source_file(file)
    defer: analysis.diagnostics.release()
    return analysis.diagnostics.len()


function expect_clean(source: str) -> void:
    expect_eq(int<-diagnostic_count(source), 0)


function expect_flagged(source: str) -> void:
    expect(diagnostic_count(source) > 0)


@[test]
function test_valid_function_is_clean() -> void:
    var source = <<-SRC
        function add(a: int, b: int) -> int:
            return a + b
    SRC
    expect_clean(source)


@[test]
function test_return_type_mismatch_is_flagged() -> void:
    var source = <<-SRC
        function f() -> int:
            return true
    SRC
    expect_flagged(source)


@[test]
function test_return_bool_from_bool_is_clean() -> void:
    var source = <<-SRC
        function f() -> bool:
            return true
    SRC
    expect_clean(source)


@[test]
function test_duplicate_function_is_flagged() -> void:
    var source = <<-SRC
        function f() -> int:
            return 1
        function f() -> int:
            return 2
    SRC
    expect_flagged(source)


@[test]
function test_duplicate_type_is_flagged() -> void:
    var source = <<-SRC
        struct Point:
            x: int
        struct Point:
            y: int
    SRC
    expect_flagged(source)


@[test]
function test_distinct_type_and_value_names_are_clean() -> void:
    var source = <<-SRC
        struct Point:
            x: int
        function make() -> int:
            return 0
    SRC
    expect_clean(source)


@[test]
function test_let_type_mismatch_is_flagged() -> void:
    var source = <<-SRC
        function f() -> void:
            let x: int = true
    SRC
    expect_flagged(source)


@[test]
function test_let_numeric_literal_is_clean() -> void:
    # Integer literals coerce across numeric types; must not be flagged.
    var source = <<-SRC
        function f() -> void:
            let x: ptr_uint = 0
    SRC
    expect_clean(source)


@[test]
function test_unknown_bare_type_is_flagged() -> void:
    # A bare, unresolved type name is a typo or missing import — always an error.
    # (Cross-module types are qualified `alias.Type`, never bare, so a bare
    # unknown name can never be a legitimate imported type.)
    var source = <<-SRC
        function f(v: SomeUnknownType) -> int:
            return 0
    SRC
    expect_flagged(source)


@[test]
function test_qualified_unresolved_type_is_permissive() -> void:
    # A qualified `alias.Type` whose binding is unavailable degrades to the
    # permissive error type and must never produce a false positive.
    var source = <<-SRC
        import ext.widgets as ext

        function f(v: ext.SomeImported) -> ext.OtherImported:
            let x: ext.Widget = make_widget()
            return x
    SRC
    expect_clean(source)


@[test]
function test_return_local_variable_is_checked() -> void:
    var source = <<-SRC
        function f() -> int:
            let flag = true
            return flag
    SRC
    expect_flagged(source)


@[test]
function test_non_bool_if_condition_is_flagged() -> void:
    var source = <<-SRC
        function f() -> void:
            if 5:
                pass
    SRC
    expect_flagged(source)


@[test]
function test_non_bool_while_condition_is_flagged() -> void:
    var source = <<-SRC
        function f() -> void:
            while 3:
                pass
    SRC
    expect_flagged(source)


@[test]
function test_comparison_condition_is_clean() -> void:
    var source = <<-SRC
        function f(n: int) -> void:
            if n > 0:
                pass
            while n < 10:
                pass
    SRC
    expect_clean(source)


@[test]
function test_call_arity_mismatch_is_flagged() -> void:
    var source = <<-SRC
        function add(a: int, b: int) -> int:
            return a + b
        function g() -> int:
            return add(1)
    SRC
    expect_flagged(source)


@[test]
function test_call_correct_arity_is_clean() -> void:
    var source = <<-SRC
        function add(a: int, b: int) -> int:
            return a + b
        function g() -> int:
            return add(1, 2)
    SRC
    expect_clean(source)


@[test]
function test_call_argument_type_mismatch_is_flagged() -> void:
    var source = <<-SRC
        function add(a: int, b: int) -> int:
            return a + b
        function g() -> int:
            return add(true, 1)
    SRC
    expect_flagged(source)


@[test]
function test_unknown_name_is_flagged() -> void:
    # A bare identifier that resolves to no local, value, function, or type is
    # a typo or missing import.
    var source = <<-SRC
        function main() -> int:
            return undefined_name
    SRC
    expect_flagged(source)


@[test]
function test_match_binding_is_in_scope() -> void:
    # An arm's `as name` binding is visible in the arm body and must not be
    # reported as an unknown name.
    var source = <<-SRC
        function main() -> int:
            let opt = Option[int].some(value = 5)
            match opt:
                Option.some as s:
                    return s.value
                Option.none:
                    return 0
    SRC
    expect_clean(source)


@[test]
function test_unknown_name_in_match_arm_is_flagged() -> void:
    # A binding is in scope, but an unrelated unknown name in the arm body is
    # still reported.
    var source = <<-SRC
        function main() -> int:
            let opt = Option[int].some(value = 5)
            match opt:
                Option.some as s:
                    return bogus_name
                Option.none:
                    return 0
    SRC
    expect_flagged(source)


@[test]
function test_tuple_destructure_bindings_are_in_scope() -> void:
    # Names bound by tuple destructuring are visible afterwards.
    var source = <<-SRC
        function pair() -> (int, int):
            return (1, 2)

        function main() -> int:
            let (a, b) = pair()
            return a + b
    SRC
    expect_clean(source)


@[test]
function test_call_to_unknown_function_is_permissive() -> void:
    # A method call on a value of an unresolved (qualified) type is permissive.
    var source = <<-SRC
        import ext.widgets as ext

        function g(w: ext.Widget) -> int:
            return w.compute(1, 2, 3)
    SRC
    expect_clean(source)


@[test]
function test_named_arguments_call_is_clean() -> void:
    var source = <<-SRC
        function configure(host: str, port: int) -> void:
            pass
        function g() -> void:
            configure(host = "localhost", port = 8080)
    SRC
    expect_clean(source)


@[test]
function test_unknown_field_in_construction_is_flagged() -> void:
    var source = <<-SRC
        struct Point:
            x: int
            y: int
        function make() -> Point:
            return Point(x = 1, z = 2)
    SRC
    expect_flagged(source)


@[test]
function test_valid_construction_is_clean() -> void:
    var source = <<-SRC
        struct Point:
            x: int
            y: int
        function make() -> Point:
            return Point(x = 1, y = 2)
    SRC
    expect_clean(source)


@[test]
function test_field_access_type_is_inferred() -> void:
    var source = <<-SRC
        struct Box:
            flag: bool
        function f(b: Box) -> int:
            return b.flag
    SRC
    expect_flagged(source)


@[test]
function test_field_access_correct_type_is_clean() -> void:
    var source = <<-SRC
        struct Box:
            count: int
        function f(b: Box) -> int:
            return b.count
    SRC
    expect_clean(source)


@[test]
function test_type_alias_resolves_to_target() -> void:
    var source = <<-SRC
        type Meters = int
        function f() -> Meters:
            return true
    SRC
    expect_flagged(source)


@[test]
function test_unknown_method_call_is_flagged() -> void:
    var source = <<-SRC
        struct Box:
            x: int
        extending Box:
            function get() -> int:
                return this.x
        function f(b: Box) -> int:
            return b.missing()
    SRC
    expect_flagged(source)


@[test]
function test_valid_extending_method_call_is_clean() -> void:
    var source = <<-SRC
        struct Box:
            x: int
        extending Box:
            function get() -> int:
                return this.x
        function f(b: Box) -> int:
            return b.get()
    SRC
    expect_clean(source)


@[test]
function test_unknown_field_read_is_flagged() -> void:
    var source = <<-SRC
        struct Box:
            x: int
        function f(b: Box) -> int:
            return b.nope
    SRC
    expect_flagged(source)


@[test]
function test_member_on_non_local_type_is_permissive() -> void:
    # Receivers of imported / ref-wrapped types are not locally-known structs,
    # so their member accesses must never be flagged.
    var source = <<-SRC
        import ext.widgets as ext

        function f(w: ext.Widget, p: ref[ext.Gadget]) -> int:
            let a = w.anything()
            return p.whatever + a
    SRC
    expect_clean(source)


@[test]
function test_builtin_with_on_struct_is_clean() -> void:
    var source = <<-SRC
        struct Point:
            x: int
            y: int
        function shift(p: Point) -> Point:
            return p.with(x = 9)
    SRC
    expect_clean(source)


@[test]
function test_method_body_return_mismatch_is_flagged() -> void:
    var source = <<-SRC
        struct Counter:
            value: int
        extending Counter:
            function bad() -> bool:
                return this.value
    SRC
    expect_flagged(source)


@[test]
function test_method_body_unknown_field_is_flagged() -> void:
    var source = <<-SRC
        struct Counter:
            value: int
        extending Counter:
            function read() -> int:
                return this.nope
    SRC
    expect_flagged(source)


@[test]
function test_valid_method_body_is_clean() -> void:
    var source = <<-SRC
        struct Counter:
            value: int
        extending Counter:
            function read() -> int:
                return this.value
            editable function bump() -> void:
                this.value = this.value + 1
    SRC
    expect_clean(source)


@[test]
function test_static_method_body_is_clean() -> void:
    var source = <<-SRC
        struct Counter:
            value: int
        extending Counter:
            static function zero() -> Counter:
                return Counter(value = 0)
    SRC
    expect_clean(source)


@[test]
function test_method_calls_sibling_method_is_clean() -> void:
    var source = <<-SRC
        struct Counter:
            value: int
        extending Counter:
            function read() -> int:
                return this.value
            function double() -> int:
                return this.read() + this.read()
    SRC
    expect_clean(source)


@[test]
function test_unknown_enum_member_is_flagged() -> void:
    var source = <<-SRC
        enum Color: ubyte
            red = 0
            green = 1
        function f() -> Color:
            return Color.purple
    SRC
    expect_flagged(source)


@[test]
function test_valid_enum_member_is_clean() -> void:
    var source = <<-SRC
        enum Color: ubyte
            red = 0
            green = 1
        function f() -> Color:
            return Color.green
    SRC
    expect_clean(source)


@[test]
function test_unknown_variant_arm_is_flagged() -> void:
    var source = <<-SRC
        variant Token:
            ident(name: str)
            eof
        function f() -> Token:
            return Token.bad
    SRC
    expect_flagged(source)


@[test]
function test_valid_variant_arm_construction_is_clean() -> void:
    var source = <<-SRC
        variant Token:
            ident(name: str)
            eof
        function f() -> Token:
            return Token.ident(name = "x")
    SRC
    expect_clean(source)


@[test]
function test_prelude_option_member_is_permissive() -> void:
    # Option/Result are prelude types, not locally declared, so their member
    # access must never be flagged.
    var source = <<-SRC
        function f() -> Option[int]:
            return Option[int].some(value = 5)
    SRC
    expect_clean(source)


@[test]
function test_if_else_both_return_is_clean() -> void:
    var source = <<-SRC
        function f(n: int) -> int:
            if n > 0:
                return 1
            else:
                return 2
    SRC
    expect_clean(source)


@[test]
function test_void_function_needs_no_return() -> void:
    var source = <<-SRC
        function f() -> void:
            let x = 5
    SRC
    expect_clean(source)


@[test]
function test_assignment_type_mismatch_is_flagged() -> void:
    var source = <<-SRC
        function f() -> void:
            var x: int = 0
            x = true
    SRC
    expect_flagged(source)


@[test]
function test_assignment_compatible_is_clean() -> void:
    var source = <<-SRC
        function f() -> void:
            var x: int = 0
            x = 5
    SRC
    expect_clean(source)


@[test]
function test_break_outside_loop_is_flagged() -> void:
    var source = <<-SRC
        function f() -> void:
            break
    SRC
    expect_flagged(source)


@[test]
function test_continue_outside_loop_is_flagged() -> void:
    var source = <<-SRC
        function f() -> void:
            continue
    SRC
    expect_flagged(source)


@[test]
function test_break_inside_loop_is_clean() -> void:
    var source = <<-SRC
        function f() -> void:
            while true:
                break
    SRC
    expect_clean(source)


@[test]
function test_break_in_nested_if_in_loop_is_clean() -> void:
    var source = <<-SRC
        function f(n: int) -> void:
            for i in 0..n:
                if i > 2:
                    break
    SRC
    expect_clean(source)


@[test]
function test_non_exhaustive_enum_match_is_flagged() -> void:
    var source = <<-SRC
        enum Color: ubyte
            red = 0
            green = 1
            blue = 2
        function f(c: Color) -> int:
            match c:
                Color.red:
                    return 1
                Color.green:
                    return 2
    SRC
    expect_flagged(source)


@[test]
function test_exhaustive_enum_match_is_clean() -> void:
    var source = <<-SRC
        enum Color: ubyte
            red = 0
            green = 1
        function f(c: Color) -> int:
            match c:
                Color.red:
                    return 1
                Color.green:
                    return 2
    SRC
    expect_clean(source)


@[test]
function test_enum_match_with_wildcard_is_clean() -> void:
    var source = <<-SRC
        enum Color: ubyte
            red = 0
            green = 1
            blue = 2
        function f(c: Color) -> int:
            match c:
                Color.red:
                    return 1
                _:
                    return 0
    SRC
    expect_clean(source)


@[test]
function test_integer_match_without_wildcard_is_flagged() -> void:
    var source = <<-SRC
        function f(n: int) -> int:
            match n:
                1:
                    return 1
                2:
                    return 2
    SRC
    expect_flagged(source)


@[test]
function test_integer_match_with_wildcard_is_clean() -> void:
    var source = <<-SRC
        function f(n: int) -> int:
            match n:
                1:
                    return 1
                _:
                    return 0
    SRC
    expect_clean(source)


@[test]
function test_str_match_without_wildcard_is_flagged() -> void:
    var source = <<-SRC
        function f(s: str) -> int:
            match s:
                "a":
                    return 1
    SRC
    expect_flagged(source)


@[test]
function test_duplicate_integer_arm_is_flagged() -> void:
    var source = <<-SRC
        function f(n: int) -> int:
            match n:
                1:
                    return 1
                1:
                    return 2
                _:
                    return 0
    SRC
    expect_flagged(source)


@[test]
function test_duplicate_enum_arm_is_flagged() -> void:
    var source = <<-SRC
        enum Color: ubyte
            red = 0
            green = 1
        function f(c: Color) -> int:
            match c:
                Color.red:
                    return 1
                Color.red:
                    return 2
                _:
                    return 0
    SRC
    expect_flagged(source)


@[test]
function test_variant_match_non_exhaustive_is_flagged() -> void:
    var source = <<-SRC
        variant Tok:
            a
            b
            c
        function f(t: Tok) -> int:
            match t:
                Tok.a:
                    return 1
                Tok.b:
                    return 2
    SRC
    expect_flagged(source)


@[test]
function test_variant_match_exhaustive_is_clean() -> void:
    var source = <<-SRC
        variant Tok:
            a
            b
        function f(t: Tok) -> int:
            match t:
                Tok.a:
                    return 1
                Tok.b:
                    return 2
    SRC
    expect_clean(source)


@[test]
function test_variant_match_with_payload_pattern_is_permissive() -> void:
    # Payload destructuring patterns are not classified, so exhaustiveness is
    # skipped (permissive) rather than risk a false positive.
    var source = <<-SRC
        variant Tok:
            ident(name: str)
            eof
        function f(t: Tok) -> int:
            match t:
                Tok.ident(name):
                    return 1
    SRC
    expect_clean(source)


@[test]
function test_method_call_arity_mismatch_is_flagged() -> void:
    var source = <<-SRC
        struct Counter:
            value: int
        extending Counter:
            function add(a: int, b: int) -> int:
                return this.value + a + b
        function f(c: Counter) -> int:
            return c.add(1)
    SRC
    expect_flagged(source)


@[test]
function test_method_call_correct_arity_is_clean() -> void:
    var source = <<-SRC
        struct Counter:
            value: int
        extending Counter:
            function add(a: int, b: int) -> int:
                return this.value + a + b
        function f(c: Counter) -> int:
            return c.add(1, 2)
    SRC
    expect_clean(source)


@[test]
function test_method_call_argument_type_mismatch_is_flagged() -> void:
    var source = <<-SRC
        struct Counter:
            value: int
        extending Counter:
            function add(a: int, b: int) -> int:
                return this.value + a + b
        function f(c: Counter) -> int:
            return c.add(true, 2)
    SRC
    expect_flagged(source)


@[test]
function test_method_return_type_flows_to_caller() -> void:
    # count() returns int; returning it from a bool function must be flagged.
    var source = <<-SRC
        struct Box:
            n: int
        extending Box:
            function count() -> int:
                return this.n
        function f(b: Box) -> bool:
            return b.count()
    SRC
    expect_flagged(source)


@[test]
function test_static_method_call_correct_is_clean() -> void:
    var source = <<-SRC
        struct Counter:
            value: int
        extending Counter:
            static function make(start: int) -> Counter:
                return Counter(value = start)
        function f() -> int:
            let c = Counter.make(5)
            return 0
    SRC
    expect_clean(source)


@[test]
function test_static_method_call_arity_mismatch_is_flagged() -> void:
    var source = <<-SRC
        struct Counter:
            value: int
        extending Counter:
            static function make(start: int) -> Counter:
                return Counter(value = start)
        function f() -> int:
            let c = Counter.make()
            return 0
    SRC
    expect_flagged(source)


@[test]
function test_unknown_static_method_is_flagged() -> void:
    var source = <<-SRC
        struct Counter:
            value: int
        extending Counter:
            static function make(start: int) -> Counter:
                return Counter(value = start)
        function f() -> int:
            let c = Counter.bogus()
            return 0
    SRC
    expect_flagged(source)


@[test]
function test_block_local_does_not_leak_past_loop() -> void:
    # A loop-local shadowing a parameter must not leak: after the loop, `flag`
    # is the bool parameter again, so returning it from a bool function is clean.
    var source = <<-SRC
        function f(flag: bool) -> bool:
            var i: int = 0
            while i < 3:
                let flag = i
                i += 1
            return flag
    SRC
    expect_clean(source)


@[test]
function test_interface_conformance_valid_is_clean() -> void:
    var source = <<-SRC
        interface Damageable:
            function is_alive() -> bool
            editable function take_damage(amount: int) -> void
        struct NPC implements Damageable:
            hp: int
        extending NPC:
            function is_alive() -> bool:
                return this.hp > 0
            editable function take_damage(amount: int) -> void:
                this.hp = this.hp - amount
    SRC
    expect_clean(source)


@[test]
function test_interface_missing_method_is_flagged() -> void:
    var source = <<-SRC
        interface Named:
            function name() -> str
        struct Widget implements Named:
            id: int
        extending Widget:
            function other() -> int:
                return this.id
    SRC
    expect_flagged(source)


@[test]
function test_interface_arity_mismatch_is_flagged() -> void:
    var source = <<-SRC
        interface Bumper:
            function bump(amount: int) -> int
        struct C implements Bumper:
            n: int
        extending C:
            function bump() -> int:
                return this.n
    SRC
    expect_flagged(source)


@[test]
function test_interface_return_type_mismatch_is_flagged() -> void:
    var source = <<-SRC
        interface Producer:
            function produce() -> int
        struct P implements Producer:
            v: int
        extending P:
            function produce() -> bool:
                return true
    SRC
    expect_flagged(source)


@[test]
function test_opaque_interface_conformance_is_clean() -> void:
    var source = <<-SRC
        interface Closable:
            function close() -> void
        opaque Handle implements Closable
        extending Handle:
            function close() -> void:
                pass
    SRC
    expect_clean(source)


@[test]
function test_generic_interface_conformance_is_permissive() -> void:
    # Substituted type parameters resolve permissively, so a correct generic
    # implementation is clean (method exists, arity matches).
    var source = <<-SRC
        interface Converter[T, U]:
            function convert(x: T) -> U
        struct Doubler implements Converter[int, int]:
            value: int
        extending Doubler:
            function convert(x: int) -> int:
                return x * 2
    SRC
    expect_clean(source)


# =============================================================================
#  Generics — handled permissively (type parameters resolve to the error type),
#  so generic bodies never false-positive, while concrete errors inside them are
#  still caught. Deep generic checking (constraints, specialization) is future.
# =============================================================================

@[test]
function test_generic_function_call_is_permissive() -> void:
    var source = <<-SRC
        function id[T](x: T) -> T:
            return x
        function f() -> int:
            return id(5)
    SRC
    expect_clean(source)


@[test]
function test_generic_struct_declaration_is_clean() -> void:
    var source = <<-SRC
        struct Box[T]:
            value: T
        function f() -> int:
            return 0
    SRC
    expect_clean(source)


@[test]
function test_constrained_generic_function_is_clean() -> void:
    var source = <<-SRC
        interface Named:
            function name() -> str
        function label[T implements Named](target: ref[T]) -> str:
            return target.name()
    SRC
    expect_clean(source)


@[test]
function test_concrete_error_in_generic_body_is_flagged() -> void:
    # A generic body is not blanket-permissive: a concrete-typed mismatch (bool
    # returned from an int function) is still flagged.
    var source = <<-SRC
        function wrong[T](x: T) -> int:
            return true
    SRC
    expect_flagged(source)


# =============================================================================
#  Generic constraint checking — a `[T implements I]` type parameter is a type
#  variable whose only members are its constraint interfaces' methods, checked
#  with full signatures (arity, args, return-type flow). Unconstrained type
#  parameters stay permissive.
# =============================================================================

@[test]
function test_generic_constraint_method_call_is_clean() -> void:
    var source = <<-SRC
        interface Damageable:
            function is_alive() -> bool
            editable function take_damage(amount: int) -> void
        function hurt[T implements Damageable](target: ref[T], amount: int) -> void:
            target.take_damage(amount)
    SRC
    expect_clean(source)


@[test]
function test_generic_constraint_unknown_method_is_flagged() -> void:
    var source = <<-SRC
        interface Damageable:
            function is_alive() -> bool
            editable function take_damage(amount: int) -> void
        function hurt[T implements Damageable](target: ref[T]) -> void:
            target.bogus()
    SRC
    expect_flagged(source)


@[test]
function test_generic_constraint_argument_type_is_flagged() -> void:
    var source = <<-SRC
        interface Damageable:
            editable function take_damage(amount: int) -> void
        function hurt[T implements Damageable](target: ref[T]) -> void:
            target.take_damage(true)
    SRC
    expect_flagged(source)


@[test]
function test_generic_constraint_return_type_flows() -> void:
    var source = <<-SRC
        interface Named:
            function name() -> str
        function label[T implements Named](target: ref[T]) -> int:
            return target.name()
    SRC
    expect_flagged(source)


@[test]
function test_generic_multi_constraint_is_clean() -> void:
    var source = <<-SRC
        interface Damageable:
            function is_alive() -> bool
        interface Named:
            function name() -> str
        function describe[T implements Damageable and Named](target: ref[T]) -> str:
            if target.is_alive():
                return target.name()
            return "dead"
    SRC
    expect_clean(source)


@[test]
function test_unconstrained_generic_member_is_permissive() -> void:
    var source = <<-SRC
        function use[T](x: T) -> void:
            x.anything()
    SRC
    expect_clean(source)


# =============================================================================
#  Associated-function hook checking (S3b-2). hash/equal/order/default require
#  the type argument to provide the hook. Flagged only for a fully-known local
#  struct; primitives, imports, and abstract type parameters stay permissive.
# =============================================================================

@[test]
function test_hook_missing_on_local_struct_is_flagged() -> void:
    var source = <<-SRC
        struct Widget:
            id: int
        function f() -> uint:
            var w: Widget
            return hash[Widget](ref_of(w))
    SRC
    expect_flagged(source)


@[test]
function test_bare_default_hook_missing_is_flagged() -> void:
    var source = <<-SRC
        struct Widget:
            id: int
        function f() -> Widget:
            return default[Widget]
    SRC
    expect_flagged(source)


@[test]
function test_hook_present_on_local_struct_is_clean() -> void:
    var source = <<-SRC
        struct Widget:
            id: int
        extending Widget:
            static function hash(value: const_ptr[Widget]) -> uint:
                return 0
        function f() -> uint:
            var w: Widget
            return hash[Widget](ref_of(w))
    SRC
    expect_clean(source)


@[test]
function test_default_hook_present_is_clean() -> void:
    var source = <<-SRC
        struct Widget:
            id: int
        extending Widget:
            static function default() -> Widget:
                return Widget(id = 0)
        function f() -> Widget:
            return default[Widget]
    SRC
    expect_clean(source)


@[test]
function test_hook_on_primitive_is_permissive() -> void:
    var source = <<-SRC
        function f() -> uint:
            var n: int = 5
            return hash[int](ref_of(n))
    SRC
    expect_clean(source)


@[test]
function test_hook_on_type_parameter_is_permissive() -> void:
    var source = <<-SRC
        function keyed[T](value: ref[T]) -> uint:
            return hash[T](value)
    SRC
    expect_clean(source)


# =============================================================================
#  Generic constraint satisfaction (S3b-3). A concrete local-struct type
#  argument to a generic function must satisfy the parameter's local-interface
#  constraint, whether given explicitly (foo[T]) or inferred from the arguments.
# =============================================================================

@[test]
function test_explicit_type_arg_unsatisfied_constraint_is_flagged() -> void:
    var source = <<-SRC
        interface Damageable:
            function is_alive() -> bool
        struct Rock:
            weight: int
        function hurt[T implements Damageable](target: ref[T]) -> void:
            pass
        function f() -> void:
            var r: Rock
            hurt[Rock](ref_of(r))
    SRC
    expect_flagged(source)


@[test]
function test_explicit_type_arg_satisfied_constraint_is_clean() -> void:
    var source = <<-SRC
        interface Damageable:
            function is_alive() -> bool
        struct NPC implements Damageable:
            hp: int
        extending NPC:
            function is_alive() -> bool:
                return this.hp > 0
        function hurt[T implements Damageable](target: ref[T]) -> void:
            pass
        function f() -> void:
            var n: NPC
            hurt[NPC](ref_of(n))
    SRC
    expect_clean(source)


@[test]
function test_inferred_type_arg_unsatisfied_constraint_is_flagged() -> void:
    var source = <<-SRC
        interface Damageable:
            function is_alive() -> bool
        struct Rock:
            weight: int
        function hurt[T implements Damageable](target: ref[T]) -> void:
            pass
        function f() -> void:
            var r: Rock
            hurt(r)
    SRC
    expect_flagged(source)


@[test]
function test_inferred_type_arg_satisfied_constraint_is_clean() -> void:
    var source = <<-SRC
        interface Damageable:
            function is_alive() -> bool
        struct NPC implements Damageable:
            hp: int
        extending NPC:
            function is_alive() -> bool:
                return this.hp > 0
        function hurt[T implements Damageable](target: ref[T]) -> void:
            pass
        function f() -> void:
            var n: NPC
            hurt(n)
    SRC
    expect_clean(source)


@[test]
function test_abstract_type_arg_constraint_is_permissive() -> void:
    # Forwarding an abstract U to a constrained parameter cannot be checked, so
    # it stays permissive rather than being flagged.
    var source = <<-SRC
        interface Damageable:
            function is_alive() -> bool
        function hurt[T implements Damageable](target: ref[T]) -> void:
            pass
        function forward[U](thing: ref[U]) -> void:
            hurt(thing)
    SRC
    expect_clean(source)


# =============================================================================
#  Phase 1 item B: generic-call return-type substitution. Explicit and inferred
#  type arguments are substituted into the generic function's return type, so
#  chained member access on the result is checkable.
# =============================================================================

@[test]
function test_generic_explicit_return_type_is_substituted() -> void:
    var source = <<-SRC
        struct Widget:
            w: int
        function make[T](x: T) -> T:
            return x
        function f() -> int:
            let w = Widget(w = 7)
            let copy = make[Widget](w)
            return copy.w
    SRC
    expect_clean(source)


@[test]
function test_generic_inferred_return_type_is_substituted() -> void:
    var source = <<-SRC
        struct Widget:
            w: int
        function id[T](x: T) -> T:
            return x
        function f() -> int:
            var w = Widget(w = 7)
            let copy = id(w)
            return copy.w
    SRC
    expect_clean(source)


@[test]
function test_generic_return_type_mismatch_still_flagged() -> void:
    var source = <<-SRC
        function id[T](x: T) -> T:
            return x
        function f() -> bool:
            var n: int = 3
            return id(n)
    SRC
    expect_flagged(source)


@[test]
function test_method_kind_mismatch_is_flagged() -> void:
    var source = <<-SRC
        interface I:
            editable function bump() -> void
        struct S implements I:
            x: int
        extending S:
            function bump() -> void:
                this.x += 1
    SRC
    expect_flagged(source)


@[test]
function test_method_kind_match_is_clean() -> void:
    var source = <<-SRC
        interface I:
            editable function bump() -> void
        struct S implements I:
            x: int
        extending S:
            editable function bump() -> void:
                this.x += 1
    SRC
    expect_clean(source)


@[test]
function test_assign_to_let_is_flagged() -> void:
    var source = <<-SRC
        function f() -> int:
            let x = 5
            x = 10
            return x
    SRC
    expect_flagged(source)


@[test]
function test_compound_assign_to_let_is_flagged() -> void:
    var source = <<-SRC
        function f() -> int:
            let x = 5
            x += 1
            return x
    SRC
    expect_flagged(source)


@[test]
function test_assign_to_var_is_clean() -> void:
    var source = <<-SRC
        function f() -> int:
            var x = 5
            x = 10
            return x
    SRC
    expect_clean(source)


@[test]
function test_let_binding_stays_immutable_after_guard() -> void:
    var source = <<-SRC
        function f() -> int:
            let v = Option[int].some(value = 5) else:
                return 0
            v = 10
            return v
    SRC
    expect_flagged(source)


@[test]
function test_guard_unnarrows_nullable_value_type() -> void:
    var source = <<-SRC
        function f(m: int?) -> int:
            let val = m else:
                return 0
            return val * 2
    SRC
    expect_clean(source)


@[test]
function test_guard_unnarrows_pointer_nullable() -> void:
    var source = <<-SRC
        function f(p: ptr[int]?) -> int:
            let safe = p else:
                return 0
            unsafe:
                var x: ptr[int] = safe
                return read(x)
    SRC
    expect_clean(source)


@[test]
function test_editable_on_let_is_flagged() -> void:
    var source = <<-SRC
        struct C:
            x: int
        extending C:
            editable function bump() -> void:
                this.x += 1
        function f() -> void:
            let c = C(x = 0)
            c.bump()
    SRC
    expect_flagged(source)


@[test]
function test_editable_on_var_is_clean() -> void:
    var source = <<-SRC
        struct C:
            x: int
        extending C:
            editable function bump() -> void:
                this.x += 1
        function f() -> void:
            var c = C(x = 0)
            c.bump()
    SRC
    expect_clean(source)


@[test]
function test_adapt_returns_dyn_type() -> void:
    var source = <<-SRC
        interface Shape:
            function area() -> float
        struct C implements Shape:
            r: float
        extending C:
            function area() -> float:
                return this.r * 3.14
        function f() -> dyn[Shape]:
            var c = C(r = 1.0)
            return adapt[Shape](ref_of(c))
    SRC
    expect_clean(source)


# =============================================================================
#  Integer type compatibility (lossless widening / narrowing detection)
# =============================================================================

@[test]
function test_int_narrowing_to_byte_is_flagged() -> void:
    var source = <<-SRC
        function f() -> byte:
            var x: int = 999
            return x
    SRC
    expect_flagged(source)


@[test]
function test_int_widening_to_long_is_clean() -> void:
    var source = <<-SRC
        function f() -> long:
            var x: int = 999
            return int<-x
    SRC
    expect_clean(source)


@[test]
function test_int_to_int_is_clean() -> void:
    var source = <<-SRC
        function f() -> int:
            var x: int = 999
            return x
    SRC
    expect_clean(source)


@[test]
function test_uint_narrowing_to_ushort_is_flagged() -> void:
    var source = <<-SRC
        function f() -> ushort:
            var x: uint = 999
            return x
    SRC
    expect_flagged(source)


@[test]
function test_numeric_literal_assign_to_byte_is_clean() -> void:
    var source = <<-SRC
        function f() -> byte:
            return 42
    SRC
    expect_clean(source)


@[test]
function test_numeric_literal_assign_to_ushort_is_clean() -> void:
    var source = <<-SRC
        function f() -> ushort:
            return 100
    SRC
    expect_clean(source)


@[test]
function test_float_literal_assign_to_double_is_clean() -> void:
    var source = <<-SRC
        function f() -> double:
            return 3.14
    SRC
    expect_clean(source)


@[test]
function test_int_literal_arg_to_byte_param_is_clean() -> void:
    var source = <<-SRC
        function use(b: byte) -> void:
            pass
        function f() -> void:
            use(65)
    SRC
    expect_clean(source)


@[test]
function test_int_variable_arg_to_byte_param_is_flagged() -> void:
    var source = <<-SRC
        function use(b: byte) -> void:
            pass
        function f() -> void:
            var x: int = 65
            use(x)
    SRC
    expect_flagged(source)


# =============================================================================
#  Integer ↔ char compatibility (chars are integer-compatible)
# =============================================================================

@[test]
function test_char_cast_is_clean() -> void:
    var source = <<-SRC
        function f() -> char:
            return char<-65
    SRC
    expect_clean(source)


@[test]
function test_char_to_int_cast_is_clean() -> void:
    var source = <<-SRC
        function f() -> int:
            var c: char = 'A'
            return int<-(c)
    SRC
    expect_clean(source)


# =============================================================================
#  Same-width sign changes require a cast (Ruby-faithful)
# =============================================================================

@[test]
function test_int_literal_return_to_uint_is_clean() -> void:
    var source = <<-SRC
        function f() -> uint:
            return 0
    SRC
    expect_clean(source)


@[test]
function test_int_variable_return_to_uint_is_flagged() -> void:
    var source = <<-SRC
        function f() -> uint:
            var n: int = 0
            return n
    SRC
    expect_flagged(source)


@[test]
function test_int_cast_return_to_uint_is_clean() -> void:
    var source = <<-SRC
        function f() -> uint:
            var n: int = 0
            return uint<-(n)
    SRC
    expect_clean(source)


@[test]
function test_uint_cast_return_to_int_is_clean() -> void:
    var source = <<-SRC
        function f() -> int:
            var n: uint = 0
            return int<-(n)
    SRC
    expect_clean(source)


@[test]
function test_float_to_int_is_flagged() -> void:
    var source = <<-SRC
        function f() -> int:
            var x: float = 1.0
            return x
    SRC
    expect_flagged(source)


@[test]
function test_int_to_float_is_clean() -> void:
    var source = <<-SRC
        function f() -> float:
            var x: int = 1
            return x
    SRC
    expect_clean(source)


# =============================================================================
#  Nominal type mismatch (distinct structs / enums)
# =============================================================================

@[test]
function test_distinct_struct_assignment_is_flagged() -> void:
    var source = <<-SRC
        struct A:
            x: int
        struct B:
            y: int
        function f() -> A:
            var b = B(y = 1)
            return b
    SRC
    expect_flagged(source)


@[test]
function test_same_struct_assignment_is_clean() -> void:
    var source = <<-SRC
        struct A:
            x: int
        function f() -> A:
            var a = A(x = 1)
            return a
    SRC
    expect_clean(source)


@[test]
function test_struct_returned_as_int_is_flagged() -> void:
    var source = <<-SRC
        struct A:
            x: int
        function f() -> int:
            var a = A(x = 1)
            return a
    SRC
    expect_flagged(source)


@[test]
function test_struct_arg_to_int_param_is_flagged() -> void:
    var source = <<-SRC
        struct A:
            x: int
        function use(n: int) -> void:
            pass
        function f() -> void:
            var a = A(x = 1)
            use(a)
    SRC
    expect_flagged(source)


@[test]
function test_ref_param_accepts_struct_arg_is_clean() -> void:
    var source = <<-SRC
        struct A:
            x: int
        function use(a: ref[A]) -> void:
            pass
        function f() -> void:
            var a = A(x = 1)
            use(a)
    SRC
    expect_clean(source)


# =============================================================================
#  Nullable base compatibility
# =============================================================================

@[test]
function test_nullable_target_accepts_base_is_clean() -> void:
    var source = <<-SRC
        function f() -> void:
            var x: int? = 5
    SRC
    expect_clean(source)


@[test]
function test_nullable_byte_accepts_literal_is_clean() -> void:
    var source = <<-SRC
        function f() -> void:
            var x: byte? = 42
    SRC
    expect_clean(source)


@[test]
function test_nullable_int_rejects_str_is_flagged() -> void:
    var source = <<-SRC
        function f() -> void:
            var s: str = "hi"
            var x: int? = s
    SRC
    expect_flagged(source)


@[test]
function test_nullable_narrowing_int_variable_is_flagged() -> void:
    var source = <<-SRC
        function f() -> void:
            var n: int = 5
            var x: byte? = n
    SRC
    expect_flagged(source)


# =============================================================================
#  Aggregate construction completeness
# =============================================================================

@[test]
function test_construction_duplicate_field_is_flagged() -> void:
    var source = <<-SRC
        struct A:
            x: int
        function f() -> A:
            return A(x = 1, x = 2)
    SRC
    expect_flagged(source)


@[test]
function test_construction_field_type_mismatch_is_flagged() -> void:
    var source = <<-SRC
        struct A:
            x: int
        function f() -> A:
            return A(x = true)
    SRC
    expect_flagged(source)


@[test]
function test_construction_unnamed_arg_is_flagged() -> void:
    var source = <<-SRC
        struct A:
            x: int
        function f() -> A:
            return A(1)
    SRC
    expect_flagged(source)


@[test]
function test_construction_narrowing_int_field_is_flagged() -> void:
    var source = <<-SRC
        struct A:
            x: byte
        function f() -> A:
            var n: int = 99
            return A(x = n)
    SRC
    expect_flagged(source)


@[test]
function test_construction_literal_to_byte_field_is_clean() -> void:
    var source = <<-SRC
        struct A:
            x: byte
        function f() -> A:
            return A(x = 42)
    SRC
    expect_clean(source)


# =============================================================================
#  Statement body-restriction checks
# =============================================================================

@[test]
function test_return_in_defer_is_flagged() -> void:
    var source = <<-SRC
        function f() -> int:
            defer:
                return 1
            return 2
    SRC
    expect_flagged(source)


@[test]
function test_void_return_value_is_flagged() -> void:
    var source = <<-SRC
        function f():
            return 1
    SRC
    expect_flagged(source)


@[test]
function test_parallel_forbids_return_is_flagged() -> void:
    var source = <<-SRC
        function f() -> void:
            parallel for i in 0..4:
                if i > 2:
                    return
    SRC
    expect_flagged(source)


@[test]
function test_parallel_forbids_break_is_flagged() -> void:
    var source = <<-SRC
        function f() -> void:
            parallel for i in 0..4:
                if i > 2:
                    break
    SRC
    expect_flagged(source)


@[test]
function test_parallel_forbids_continue_is_flagged() -> void:
    var source = <<-SRC
        function f() -> void:
            parallel for i in 0..4:
                if i == 2:
                    continue
    SRC
    expect_flagged(source)


@[test]
function test_parallel_block_accepts_two_stmts_is_clean() -> void:
    var source = <<-SRC
        function f() -> void:
            var a: int = 0
            var b: int = 0
            parallel:
                a = 1
                b = 2
    SRC
    expect_clean(source)


# =============================================================================
#  Unsafe context enforcement
# =============================================================================

@[test]
function test_read_ptr_without_unsafe_is_flagged() -> void:
    var source = <<-SRC
        function f(p: ptr[int]) -> int:
            return read(p)
    SRC
    expect_flagged(source)


@[test]
function test_read_ptr_inside_unsafe_is_clean() -> void:
    var source = <<-SRC
        function f(p: ptr[int]) -> int:
            unsafe:
                return read(p)
    SRC
    expect_clean(source)


@[test]
function test_pointer_arithmetic_without_unsafe_is_flagged() -> void:
    var source = <<-SRC
        function f(p: ptr[int]) -> ptr[int]:
            return p + 1
    SRC
    expect_flagged(source)


@[test]
function test_pointer_cast_without_unsafe_is_flagged() -> void:
    var source = <<-SRC
        function f(p: ptr[ubyte]) -> ptr[int]:
            return ptr[int]<-p
    SRC
    expect_flagged(source)


@[test]
function test_pointer_cast_inside_unsafe_is_clean() -> void:
    var source = <<-SRC
        function f(p: ptr[ubyte]) -> ptr[int]:
            unsafe:
                return ptr[int]<-p
    SRC
    expect_clean(source)


@[test]
function test_reinterpret_without_unsafe_is_flagged() -> void:
    var source = <<-SRC
        function f(x: float) -> uint:
            return reinterpret[uint](x)
    SRC
    expect_flagged(source)


@[test]
function test_reinterpret_inside_unsafe_is_clean() -> void:
    var source = <<-SRC
        function f(x: float) -> uint:
            unsafe:
                return reinterpret[uint](x)
    SRC
    expect_clean(source)


@[test]
function test_ptr_of_without_unsafe_is_clean() -> void:
    var source = <<-SRC
        function f() -> ptr[int]:
            var x: int = 5
            return ptr_of(x)
    SRC
    expect_clean(source)


# =============================================================================
#  Builtin call result types
# =============================================================================

@[test]
function test_zero_returns_specified_type_is_clean() -> void:
    var source = <<-SRC
        function f() -> int:
            return zero[int]
    SRC
    expect_clean(source)


@[test]
function test_size_of_returns_ptr_uint_is_clean() -> void:
    var source = <<-SRC
        function f() -> ptr_uint:
            return size_of(int)
    SRC
    expect_clean(source)


@[test]
function test_read_ptr_returns_element_type_is_clean() -> void:
    var source = <<-SRC
        function f(p: ptr[int]) -> int:
            unsafe:
                return read(p)
    SRC
    expect_clean(source)


# =============================================================================
#  Duplicate parameter names
# =============================================================================

@[test]
function test_duplicate_param_is_flagged() -> void:
    var source = <<-SRC
        function f(a: int, a: int) -> int:
            return a
    SRC
    expect_flagged(source)


@[test]
function test_unique_params_is_clean() -> void:
    var source = <<-SRC
        function f(a: int, b: int) -> int:
            return a + b
    SRC
    expect_clean(source)


# =============================================================================
#  Await outside async
# =============================================================================

@[test]
function test_await_outside_async_is_flagged() -> void:
    var source = <<-SRC
        function f() -> int:
            return await f()
    SRC
    expect_flagged(source)


# =============================================================================
#  Primitive / reserved name reuse
# =============================================================================

@[test]
function test_param_named_int_is_flagged() -> void:
    var source = <<-SRC
        function f(int: int) -> int:
            return int
    SRC
    expect_flagged(source)


@[test]
function test_local_named_str_is_flagged() -> void:
    var source = <<-SRC
        function f() -> int:
            let str = 5
            return str
    SRC
    expect_flagged(source)


# =============================================================================
#  Review-pass fixes: defer-in-parallel, negative-literal gate
# =============================================================================

@[test]
function test_defer_in_parallel_block_is_flagged() -> void:
    var source = <<-SRC
        function f() -> void:
            var a: int = 0
            var b: int = 0
            parallel:
                defer: a += 1
                b = 2
    SRC
    expect_flagged(source)


@[test]
function test_negative_literal_return_to_byte_is_clean() -> void:
    var source = <<-SRC
        function f() -> byte:
            return -42
    SRC
    expect_clean(source)


# =============================================================================
#  == null narrowing (else-body)
# =============================================================================

@[test]
function test_not_equal_null_narrows_if_body_is_clean() -> void:
    var source = <<-SRC
        function f(p: ptr[int]?) -> int:
            if p != null:
                return unsafe: read(p)
            return 0
    SRC
    expect_clean(source)


@[test]
function test_equal_null_narrows_else_body_is_clean() -> void:
    var source = <<-SRC
        function f(p: ptr[int]?) -> int:
            if p == null:
                return 0
            return unsafe: read(p)
    SRC
    expect_clean(source)


# =============================================================================
#  Attribute target validation
# =============================================================================

@[test]
function test_packed_on_struct_is_clean() -> void:
    var source = <<-SRC
        @[packed]
        struct A:
            x: int
    SRC
    expect_clean(source)


@[test]
function test_packed_on_function_is_flagged() -> void:
    var source = <<-SRC
        @[packed]
        function f() -> int:
            return 0
    SRC
    expect_flagged(source)


# =============================================================================
#  Phase 1: resolved_expr_types and resolved_call_kinds tables
# =============================================================================

@[test]
function test_resolved_types_recording_does_not_crash() -> void:
    var source = <<-SRC
        function f() -> int:
            let x = 42
            let y = x + 1
            return y
    SRC
    expect_clean(source)


# =============================================================================
#  Imported type aliases: an alias whose target is itself an imported alias
#  (`type Color = c.Color` re-exported as `w.Color`) must resolve through the
#  chain to the declaring module's type, not degrade to a bare name.  The LSP
#  hover path reads these recorded targets, so a regression here shows up as
#  `<error>` (or an unqualified name) in hover and in signature types.
# =============================================================================

const ALIAS_BASE: str = <<-SRC
public struct Color:
    r: int
SRC

const ALIAS_WRAPPER: str = <<-SRC
import base as c

public type Color = c.Color
SRC

const ALIAS_MAIN: str = <<-SRC
import wrap as w

public const MIDNIGHT: w.Color = w.Color(r = 1)

function tint(c: w.Color) -> w.Color:
    return c
SRC


@[test]
function test_alias_of_alias_records_the_declaring_module() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_alias_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    if not write_file(root.as_str(), "base.mt", ALIAS_BASE):
        expect(false, "could not write base")
    if not write_file(root.as_str(), "wrap.mt", ALIAS_WRAPPER):
        expect(false, "could not write wrap")
    if not write_file(root.as_str(), "main.mt", ALIAS_MAIN):
        expect(false, "could not write main")

    var main_path = path_ops.join(root.as_str(), "main.mt")
    defer: main_path.release()
    var roots = array[str, 1](root.as_str())
    var program = loader.check_program(main_path.as_str(), roots.as_span(), resolver.Platform.linux)
    defer: program.release()

    expect_eq(int<-program.diagnostic_count(), 0)

    var saw_wrap = false
    var saw_main = false
    var wi: ptr_uint = 0
    while wi < program.analyses.len():
        let a_ptr = program.analyses.get(wi) else:
            break
        let a = unsafe: read(a_ptr)
        if a.module_name == "wrap":
            saw_wrap = true
            let alias_ptr = a.type_alias_types.get("Color") else:
                expect(false, "wrap.Color alias missing")
            let alias_key = types.nominal_key(unsafe: read(alias_ptr))
            expect_eq(alias_key, "base.Color")
        else if a.module_name == "main":
            saw_main = true
            let value_ptr = a.value_types.get("MIDNIGHT") else:
                expect(false, "MIDNIGHT value type missing")
            expect_eq(types.nominal_key(unsafe: read(value_ptr)), "base.Color")
            let sig_ptr = a.functions.get("tint") else:
                expect(false, "tint signature missing")
            let sig = unsafe: read(sig_ptr)
            let param = unsafe: read(sig.params.data + 0)
            expect_eq(types.nominal_key(param.ty), "base.Color")
            expect_eq(types.nominal_key(sig.return_type), "base.Color")
        wi += 1

    expect(saw_wrap, "wrap module was not analyzed")
    expect(saw_main, "main module was not analyzed")


# =============================================================================
#  Control-flow graph — the host's `ControlFlow::Builder` shapes and the
#  nullability dataflow over them.
# =============================================================================

## The address that identifies a statement in the graph (the host's
## `object_id`).
function statement_key(stmt: ptr[ast.Stmt]?) -> ptr_uint:
    let s = stmt else:
        return 0
    return unsafe: reinterpret[ptr_uint](s)


## The `index`-th statement of a block body, or null.
function block_statement(body: ptr[ast.Stmt]?, index: ptr_uint) -> ptr[ast.Stmt]?:
    let b = body else:
        return null
    unsafe:
        match read(b):
            ast.Stmt.stmt_block as blk:
                if index < blk.statements.len:
                    return blk.statements.data + index
                return null
            _:
                return null


## The statement a body starts with: a block's first statement, or the body
## itself when the parser left it unwrapped.
function first_statement(body: ptr[ast.Stmt]?) -> ptr[ast.Stmt]?:
    let b = body else:
        return null
    let first = block_statement(b, 0)
    if first != null:
        return first
    unsafe:
        match read(b):
            ast.Stmt.stmt_block:
                return null
            _:
                return b


## The loop body of a while statement, or null.
function while_body(loop_stmt: ptr[ast.Stmt]?) -> ptr[ast.Stmt]?:
    let s = loop_stmt else:
        return null
    unsafe:
        match read(s):
            ast.Stmt.stmt_while as w:
                return w.body
            _:
                return null


## The body a wrapper statement encloses (`unsafe:`/`defer`/recovered code),
## or the statement itself when it is not a wrapper.
function inner_body(body: ptr[ast.Stmt]?) -> ptr[ast.Stmt]?:
    let b = body else:
        return null
    unsafe:
        match read(b):
            ast.Stmt.stmt_unsafe as u:
                return u.body
            ast.Stmt.stmt_defer as d:
                return d.body
            ast.Stmt.stmt_error_block as eb:
                return eb.body
            _:
                return b


## The `index`-th branch body of an if statement, or null.
function if_branch_body(if_stmt: ptr[ast.Stmt]?, index: ptr_uint) -> ptr[ast.Stmt]?:
    let s = if_stmt else:
        return null
    unsafe:
        match read(s):
            ast.Stmt.stmt_if as sif:
                if index < sif.branches.len:
                    return read(sif.branches.data + index).body
                return null
            _:
                return null


## Parse `source`, build its first function's CFG graph, solve the nullability
## flow, and hand the function body back for navigation.  Returns false when
## the source does not parse or declares no function.
function build_flow(source: str, cfg: ref[cfgb.Cfg], graph: ref[cfgg.CfgGraph], flow: ref[cfgg.NullabilityFlow], body_out: ref[ptr[ast.Stmt]?]) -> bool:
    var pdiags = vec.Vec[pstate.ParseDiagnostic].create()
    defer: pdiags.release()
    let file = parser.parse_source(source, ref_of(pdiags))
    if pdiags.len() > 0:
        return false
    var body: ptr[ast.Stmt]? = null
    var params = span[ast.Param]()
    unsafe:
        var i: ptr_uint = 0
        while i < file.declarations.len:
            match read(file.declarations.data + i):
                ast.Decl.decl_function as fun:
                    body = fun.body
                    params = fun.method_params
                    break
                _:
                    pass
            i += 1
    let bp = body else:
        return false
    cfgb.cfg_clear(cfg)
    cfgb.build_graph_into(cfg, graph, params, bp)
    read(flow) = cfgg.flow_create(read(cfg).next_id, read(graph).next_id)
    cfgg.solve_nullability(graph, flow)
    read(body_out) = bp
    return true


## A binding's id, or 0 when the function declares no such binding.
function binding_key(cfg: ref[cfgb.Cfg], name: str) -> ptr_uint:
    let found = read(cfg).binding_map.get(name) else:
        return 0
    return unsafe: read(found)


## The node built from `stmt` (0 when the statement is transparent).
function node_of(graph: ref[cfgg.CfgGraph], stmt: ptr[ast.Stmt]?) -> ptr_uint:
    return cfgg.graph_node_for_statement(graph, statement_key(stmt))


## True when `key` is known non-null on entry to the node built from `stmt`.
function nonnull_at(graph: ref[cfgg.CfgGraph], flow: ref[cfgg.NullabilityFlow], stmt: ptr[ast.Stmt]?, key: ptr_uint) -> bool:
    return cfgg.nonnull_before(flow, node_of(graph, stmt), key)


## The first node of the given kind, or null.
function node_of_kind(graph: ref[cfgg.CfgGraph], kind: str) -> ptr[cfgg.CfgNode]?:
    var i: ptr_uint = 0
    while i < read(graph).nodes.len():
        let node = read(graph).nodes.get(i) else:
            break
        unsafe:
            if read(node).kind.equal(kind):
                return read(node)
        i += 1
    return null


## True when the write sites of `node` contain a write of `key` with `origin`.
function has_write_origin(node: ptr[cfgg.CfgNode], key: ptr_uint, origin: str) -> bool:
    unsafe:
        var i: ptr_uint = 0
        while i < read(node).write_sites.len():
            let site = read(node).write_sites.get(i) else:
                break
            if read(site).key == key and read(site).origin.equal(origin):
                return true
            i += 1
    return false


## True when the read sites of `node` contain a read of `key`.
function has_read_key(node: ptr[cfgg.CfgNode], key: ptr_uint) -> bool:
    unsafe:
        var i: ptr_uint = 0
        while i < read(node).read_sites.len():
            let site = read(node).read_sites.get(i) else:
                break
            if read(site).key == key:
                return true
            i += 1
    return false


## The first node whose kind matches `kind` and whose successor list contains
## `succ` — the shape tests use it to pin break/continue targets.
function node_of_kind_succ(graph: ref[cfgg.CfgGraph], kind: str, succ: ptr_uint) -> ptr[cfgg.CfgNode]?:
    var i: ptr_uint = 0
    while i < read(graph).nodes.len():
        let node = read(graph).nodes.get(i) else:
            break
        unsafe:
            if read(node).kind.equal(kind):
                var si: ptr_uint = 0
                while si < read(node).succs.len():
                    let target = read(node).succs.get(si) else:
                        break
                    if read(target) == succ:
                        return read(node)
                    si += 1
        i += 1
    return null


@[test]
function test_cfg_terminating_guard_narrows_after_it() -> void:
    var source = <<-SRC
        function f(handle: ptr[int]?) -> int:
            if handle == null:
                return 0
            unsafe:
                return read(handle)
    SRC
    var cfg = cfgb.empty_cfg()
    var graph = cfgg.empty_graph()
    defer: cfgg.graph_release(ref_of(graph))
    var flow = cfgg.flow_create(0, 0)
    defer: cfgg.flow_release(ref_of(flow))
    var body: ptr[ast.Stmt]? = null
    if not build_flow(source, ref_of(cfg), ref_of(graph), ref_of(flow), ref_of(body)):
        expect(false, "the guard source did not build")
        return
    let key = binding_key(ref_of(cfg), "handle")
    expect(key > 0, "handle was not a binding")
    let guard = block_statement(body, 0)
    let guard_return = first_statement(if_branch_body(guard, 0))
    let use_return = first_statement(inner_body(block_statement(body, 1)))
    expect(node_of(ref_of(graph), use_return) > 0, "the use after the guard has no node")
    expect(nonnull_at(ref_of(graph), ref_of(flow), use_return, key), "handle is non-null after the guard")
    let guard_nonnull = nonnull_at(ref_of(graph), ref_of(flow), guard_return, key)
    expect(not guard_nonnull, "handle is not non-null inside the guard's return")


@[test]
function test_cfg_false_edge_refines_when_the_then_branch_returns() -> void:
    var source = <<-SRC
        function f(handle: ptr[int]?) -> int:
            if handle != null:
                return 1
            return 0
    SRC
    var cfg = cfgb.empty_cfg()
    var graph = cfgg.empty_graph()
    defer: cfgg.graph_release(ref_of(graph))
    var flow = cfgg.flow_create(0, 0)
    defer: cfgg.flow_release(ref_of(flow))
    var body: ptr[ast.Stmt]? = null
    if not build_flow(source, ref_of(cfg), ref_of(graph), ref_of(flow), ref_of(body)):
        expect(false, "the guard source did not build")
        return
    let key = binding_key(ref_of(cfg), "handle")
    let then_return = first_statement(if_branch_body(block_statement(body, 0), 0))
    let after_return = block_statement(body, 1)
    expect(nonnull_at(ref_of(graph), ref_of(flow), then_return, key), "handle is non-null in the != null branch")
    expect(not nonnull_at(ref_of(graph), ref_of(flow), after_return, key), "handle is not non-null after the merging if")


@[test]
function test_cfg_write_removes_the_refinement() -> void:
    var source = <<-SRC
        function f(handle: ptr[int]?) -> int:
            if handle != null:
                handle = null[ptr[int]]
            unsafe:
                return read(handle)
    SRC
    var cfg = cfgb.empty_cfg()
    var graph = cfgg.empty_graph()
    defer: cfgg.graph_release(ref_of(graph))
    var flow = cfgg.flow_create(0, 0)
    defer: cfgg.flow_release(ref_of(flow))
    var body: ptr[ast.Stmt]? = null
    if not build_flow(source, ref_of(cfg), ref_of(graph), ref_of(flow), ref_of(body)):
        expect(false, "the write source did not build")
        return
    let key = binding_key(ref_of(cfg), "handle")
    let assignment = first_statement(if_branch_body(block_statement(body, 0), 0))
    let use_return = first_statement(inner_body(block_statement(body, 1)))
    expect(nonnull_at(ref_of(graph), ref_of(flow), assignment, key), "the assignment still sees the narrowed handle")
    expect(not nonnull_at(ref_of(graph), ref_of(flow), use_return, key), "the write clears the narrowing")


@[test]
function test_cfg_while_body_keeps_the_condition_refinement() -> void:
    var source = <<-SRC
        function f(handle: ptr[int]?) -> void:
            while handle != null:
                handle = null[ptr[int]]
    SRC
    var cfg = cfgb.empty_cfg()
    var graph = cfgg.empty_graph()
    defer: cfgg.graph_release(ref_of(graph))
    var flow = cfgg.flow_create(0, 0)
    defer: cfgg.flow_release(ref_of(flow))
    var body: ptr[ast.Stmt]? = null
    if not build_flow(source, ref_of(cfg), ref_of(graph), ref_of(flow), ref_of(body)):
        expect(false, "the loop source did not build")
        return
    let key = binding_key(ref_of(cfg), "handle")
    let loop_stmt = block_statement(body, 0)
    let loop_cond = node_of(ref_of(graph), loop_stmt)
    let body_stmt = first_statement(while_body(loop_stmt))
    expect(loop_cond > 0, "the while has no condition node")
    expect(nonnull_at(ref_of(graph), ref_of(flow), body_stmt, key), "the loop body sees the narrowed handle")
    expect(not nonnull_at(ref_of(graph), ref_of(flow), loop_stmt, key), "the loop head joins with the entry state")
    expect(cfgg.graph_reaches(ref_of(graph), loop_cond, loop_cond), "the loop head reaches itself over the back edge")


@[test]
function test_cfg_for_header_records_bindings_and_reads() -> void:
    var source = <<-SRC
        function f(items: span[int]) -> int:
            var total = 0
            for item in items:
                total = total + item
            return total
    SRC
    var cfg = cfgb.empty_cfg()
    var graph = cfgg.empty_graph()
    defer: cfgg.graph_release(ref_of(graph))
    var flow = cfgg.flow_create(0, 0)
    defer: cfgg.flow_release(ref_of(flow))
    var body: ptr[ast.Stmt]? = null
    if not build_flow(source, ref_of(cfg), ref_of(graph), ref_of(flow), ref_of(body)):
        expect(false, "the for source did not build")
        return
    let header = node_of_kind(ref_of(graph), "for_header") else:
        expect(false, "no for header node")
        return
    let item_key = binding_key(ref_of(cfg), "item")
    let total_key = binding_key(ref_of(cfg), "total")
    let items_key = binding_key(ref_of(cfg), "items")
    expect(has_write_origin(header, item_key, "for_binding"), "the for binding is a write of the header")
    expect(has_read_key(header, items_key), "the iterable is read at the header")
    let assignment = node_of_kind(ref_of(graph), "assignment") else:
        expect(false, "no assignment node")
        return
    expect(has_read_key(assignment, total_key) and has_read_key(assignment, item_key), "the body assignment reads total and item")


@[test]
function test_cfg_match_arm_binding_is_a_write_then_a_read() -> void:
    var source = <<-SRC
        function f(opt: Option[int]) -> int:
            match opt:
                Option.some as value:
                    return value
                Option.none:
                    return 0
    SRC
    var cfg = cfgb.empty_cfg()
    var graph = cfgg.empty_graph()
    defer: cfgg.graph_release(ref_of(graph))
    var flow = cfgg.flow_create(0, 0)
    defer: cfgg.flow_release(ref_of(flow))
    var body: ptr[ast.Stmt]? = null
    if not build_flow(source, ref_of(cfg), ref_of(graph), ref_of(flow), ref_of(body)):
        expect(false, "the match source did not build")
        return
    let value_key = binding_key(ref_of(cfg), "value")
    let bind_node = node_of_kind(ref_of(graph), "match_binding") else:
        expect(false, "no match binding node")
        return
    expect(has_write_origin(bind_node, value_key, "match_binding"), "the arm binding writes value")
    let match_id = node_of(ref_of(graph), block_statement(body, 0))
    expect(cfgg.graph_reaches(ref_of(graph), match_id, unsafe: read(bind_node).id), "the match reaches its arm binding")


@[test]
function test_cfg_unsafe_and_defer_nesting() -> void:
    var source = <<-SRC
        function f(handle: ptr[int]?) -> int:
            unsafe:
                if handle == null:
                    return 0
                return read(handle)
            defer:
                handle = null[ptr[int]]
            return 1
    SRC
    var cfg = cfgb.empty_cfg()
    var graph = cfgg.empty_graph()
    defer: cfgg.graph_release(ref_of(graph))
    var flow = cfgg.flow_create(0, 0)
    defer: cfgg.flow_release(ref_of(flow))
    var body: ptr[ast.Stmt]? = null
    if not build_flow(source, ref_of(cfg), ref_of(graph), ref_of(flow), ref_of(body)):
        expect(false, "the nesting source did not build")
        return
    let key = binding_key(ref_of(cfg), "handle")
    let inner = inner_body(block_statement(body, 0))
    let use_return = block_statement(inner, 1)
    expect(node_of(ref_of(graph), use_return) > 0, "the nested return has a node")
    expect(nonnull_at(ref_of(graph), ref_of(flow), use_return, key), "the nesting keeps the narrowing")
    expect(node_of(ref_of(graph), first_statement(inner_body(block_statement(body, 1)))) > 0, "the defer body has a node")


@[test]
function test_cfg_break_and_continue_targets() -> void:
    var source = <<-SRC
        function f(limit: int) -> int:
            var i = 0
            while i < limit:
                i = i + 1
                if i == 3:
                    continue
                if i == 5:
                    break
            return i
    SRC
    var cfg = cfgb.empty_cfg()
    var graph = cfgg.empty_graph()
    defer: cfgg.graph_release(ref_of(graph))
    var flow = cfgg.flow_create(0, 0)
    defer: cfgg.flow_release(ref_of(flow))
    var body: ptr[ast.Stmt]? = null
    if not build_flow(source, ref_of(cfg), ref_of(graph), ref_of(flow), ref_of(body)):
        expect(false, "the loop control source did not build")
        return
    let loop_stmt = block_statement(body, 1)
    let cond_id = node_of(ref_of(graph), loop_stmt)
    expect(cond_id > 0, "the while has a condition node")
    expect(node_of_kind_succ(ref_of(graph), "continue", cond_id) != null, "continue targets the loop head")
    let after_loop = block_statement(body, 2)
    expect(node_of_kind_succ(ref_of(graph), "break", node_of(ref_of(graph), after_loop)) != null, "break targets the statement after the loop")
    expect(cfgg.graph_reaches(ref_of(graph), cond_id, node_of(ref_of(graph), after_loop)), "the loop's false edge reaches the following statement")


@[test]
function test_tuple_destructure_records_per_name_types() -> void:
    var source = <<-SRC
        function pair() -> (int, int):
            return (1, 2)

        function main() -> int:
            let (a, b) = pair()
            return a + b
    SRC
    var pdiags = vec.Vec[pstate.ParseDiagnostic].create()
    defer: pdiags.release()
    let file = parser.parse_source(source, ref_of(pdiags))
    var analysis = analyzer.check_source_file(file)
    expect_eq(int<-analysis.destructure_types.len(), 2)
    var i: ptr_uint = 0
    while i < analysis.destructure_types.len():
        let ep = analysis.destructure_types.get(i) else:
            break
        let entry = unsafe: read(ep)
        if entry.name == "a":
            expect_eq(types.type_to_string(entry.ty), "int")
        i += 1


@[test]
function test_arm_payload_field_type_is_substituted() -> void:
    # `Option.some as p` binds the arm's payload — the host's
    # `VariantArmPayload` — and `p.value` carries the scrutinee's type argument,
    # so destructuring it records the substituted element types.
    var source = <<-SRC
        function first_of(o: Option[(int, str)]) -> int:
            match o:
                Option.some as p:
                    let (a, b) = p.value
                    if b.len == 0:
                        return a
                    return a + 1
                Option.none:
                    return 0
    SRC
    var pdiags = vec.Vec[pstate.ParseDiagnostic].create()
    defer: pdiags.release()
    let file = parser.parse_source(source, ref_of(pdiags))
    var analysis = analyzer.check_source_file(file)
    expect_eq(int<-analysis.destructure_types.len(), 2)
    var i: ptr_uint = 0
    while i < analysis.destructure_types.len():
        let ep = analysis.destructure_types.get(i) else:
            break
        let entry = unsafe: read(ep)
        if entry.name == "a":
            expect_eq(types.type_to_string(entry.ty), "int")
        if entry.name == "b":
            expect_eq(types.type_to_string(entry.ty), "str")
        i += 1


@[test]
function test_callable_value_sites_record_arg_but_not_handle_builtins() -> void:
    # A bare function name used as a value (an argument to a callback
    # parameter) is the host's callable-value site; a `callable_of(name)`
    # argument is a declaration name, not a value.
    var source = <<-SRC
        function double_it(x: int) -> int:
            return x * 2

        function apply(f: fn(x: int) -> int, v: int) -> int:
            return f(v)

        static_assert(has_attribute(callable_of(double_it), traced), "missing")

        function main() -> int:
            return apply(double_it, 7)
    SRC
    var pdiags = vec.Vec[pstate.ParseDiagnostic].create()
    defer: pdiags.release()
    let file = parser.parse_source(source, ref_of(pdiags))
    var analysis = analyzer.check_source_file(file)
    expect_eq(int<-analysis.callable_value_sites.len(), 1)
    var i: ptr_uint = 0
    while i < analysis.callable_value_sites.len():
        let sp = analysis.callable_value_sites.get(i) else:
            break
        let site = unsafe: read(sp)
        expect_eq(int<-site.line, 10)
        i += 1


@[test]
function test_user_variant_arm_payload_field_is_typed() -> void:
    # A user variant's `as name` arm binding carries its declared payload
    # fields, so `w.value` resolves to `int` — a wrong return type is flagged
    # (before, the field was the permissive error type).
    var source = <<-SRC
        variant Box:
            wrap(value: int)
            empty

        function bad(b: Box) -> str:
            match b:
                Box.wrap as w:
                    return w.value
                Box.empty:
                    return ""
    SRC
    expect_flagged(source)


@[test]
function test_arm_payload_field_types_record_declared_fields() -> void:
    var source = <<-SRC
        variant Box:
            wrap(value: int)
            empty

        function unwrap(b: Box) -> int:
            match b:
                Box.wrap as w:
                    return w.value
                Box.empty:
                    return 0
    SRC
    var pdiags = vec.Vec[pstate.ParseDiagnostic].create()
    defer: pdiags.release()
    let file = parser.parse_source(source, ref_of(pdiags))
    var analysis = analyzer.check_source_file(file)
    let fields_ptr = analysis.arm_payload_field_types.get("Box_wrap") else:
        expect(false, "Box_wrap payload fields missing")
        return
    let fields = unsafe: read(fields_ptr)
    expect_eq(int<-fields.len, 1)
    let field = unsafe: read(fields.data + 0)
    expect(field.name.equal("value"), "field name")
    expect_eq(types.type_to_string(field.ty), "int")


@[test]
function test_generic_variant_arm_payload_field_is_substituted() -> void:
    # `Maybe[int].some as s` binds `s` to the substituted payload, so
    # `s.value` is `int`, not the type parameter.
    var source = <<-SRC
        variant Maybe[T]:
            some(value: T)
            none

        function bad(m: Maybe[int]) -> str:
            match m:
                Maybe.some as s:
                    return s.value
                Maybe.none:
                    return ""
    SRC
    expect_flagged(source)


@[test]
function test_let_else_body_is_checked() -> void:
    # The guard's else block is analyzed like any other body, so a return of
    # the wrong type is flagged (it used to be skipped silently).
    var source = <<-SRC
        function demo(o: Option[int]) -> int:
            let v = o else:
                return "nope"
            return v
    SRC
    expect_flagged(source)


@[test]
function test_proc_body_is_checked() -> void:
    var source = <<-SRC
        function demo() -> int:
            let f = proc(x: int) -> int: return "nope"
            return f(1)
    SRC
    expect_flagged(source)


@[test]
function test_incompatible_cast_is_flagged() -> void:
    var source = <<-SRC
        function demo() -> int:
            return int<-"abc"
    SRC
    expect_flagged(source)


@[test]
function test_pointer_cast_is_flagged_without_unsafe() -> void:
    var source = <<-SRC
        function demo(p: ptr[ubyte]) -> ptr[char]:
            return ptr[char]<-p
    SRC
    expect_flagged(source)


@[test]
function test_for_loop_elements_are_typed() -> void:
    # A range iterable yields its bounds' integer type and an array its element
    # type, so a mismatched use is flagged (each loop variable used to be the
    # permissive error type).
    var source = <<-SRC
        function from_range() -> str:
            for i in 0..3:
                return i
            return ""

        function from_array(values: array[int, 2]) -> str:
            for v in values:
                return v
            return ""
    SRC
    expect_eq(int<-diagnostic_count(source), 2)


@[test]
function test_for_loop_matching_element_types_are_clean() -> void:
    var source = <<-SRC
        function sum(values: array[int, 2]) -> int:
            var total = 0
            for v in values:
                total += v
            return total

        function count() -> int:
            var n = 0
            for i in 0..3:
                n += i
            return n
    SRC
    expect_clean(source)


const PRELUDE_OPTION_STUB: str = <<-SRC
public variant Option[T]:
    some(value: T)
    none

extending Option[T]:
    public function unwrap() -> T:
        match this:
            Option.some as payload:
                return payload.value
            Option.none:
                fatal(c"called Option.unwrap on a none value")
SRC

const PRELUDE_UNWRAP_MAIN: str = <<-SRC
function good(o: Option[int]) -> int:
    return o.unwrap()

function bad(o: Option[int]) -> str:
    return o.unwrap()
SRC


@[test]
function test_prelude_unwrap_types_the_payload() -> void:
    # The seeded std.option binding's method signatures type a prelude
    # receiver's call (`Option[int].unwrap()` -> int), so only the `bad`
    # function's return mismatches.  The workspace carries a minimal
    # `std/option.mt` so the prelude seed resolves it without the repository's
    # std tree.
    var root = fs.create_temporary_directory_in_system_temp("mtc_unwrap_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))
    if not write_file(root.as_str(), "std/option.mt", PRELUDE_OPTION_STUB):
        expect(false, "could not write the prelude stub")
    if not write_file(root.as_str(), "main.mt", PRELUDE_UNWRAP_MAIN):
        expect(false, "could not write main")

    var main_path = path_ops.join(root.as_str(), "main.mt")
    defer: main_path.release()
    var roots = array[str, 1](root.as_str())
    var program = loader.check_program(main_path.as_str(), roots.as_span(), resolver.Platform.linux)
    defer: program.release()
    expect_eq(int<-program.diagnostic_count(), 1)


const GENERIC_FIELD_BASE: str = <<-SRC
public struct Box[T]:
    value: T
SRC

const GENERIC_FIELD_MAIN: str = <<-SRC
import base as b

function good(box: b.Box[int]) -> int:
    return box.value

function bad(box: b.Box[int]) -> str:
    return box.value
SRC


@[test]
function test_imported_generic_field_is_substituted() -> void:
    # An imported generic struct's field carries the declaring type's parameter
    # (`Box[T].value` -> `T`), substituted with the receiver's argument
    # (`Box[int].value` -> `int`), so the mismatched return is flagged.
    var root = fs.create_temporary_directory_in_system_temp("mtc_genfield_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))
    if not write_file(root.as_str(), "base.mt", GENERIC_FIELD_BASE):
        expect(false, "could not write base")
    if not write_file(root.as_str(), "main.mt", GENERIC_FIELD_MAIN):
        expect(false, "could not write main")

    var main_path = path_ops.join(root.as_str(), "main.mt")
    defer: main_path.release()
    var roots = array[str, 1](root.as_str())
    var program = loader.check_program(main_path.as_str(), roots.as_span(), resolver.Platform.linux)
    defer: program.release()
    expect_eq(int<-program.diagnostic_count(), 1)


const METHOD_SPEC_BASE: str = <<-SRC
public struct Store:
    public editable function take[T](count: ptr_uint) -> ptr[T]?:
        return null
SRC

const METHOD_SPEC_MAIN: str = <<-SRC
import base as b

function good(store: ref[b.Store]) -> ptr[int]?:
    return store.take[int](4)

function bad(store: ref[b.Store]) -> int:
    return int<-store.take[int](4)
SRC


@[test]
function test_method_specialization_on_a_value_receiver() -> void:
    # `store.take[int](4)` resolves the generic method's return type with the
    # explicit type argument substituted (`ptr[T]?` -> `ptr[int]?`), so the
    # cast in `bad` reports the incompatible types.
    var root = fs.create_temporary_directory_in_system_temp("mtc_spec_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))
    if not write_file(root.as_str(), "base.mt", METHOD_SPEC_BASE):
        expect(false, "could not write base")
    if not write_file(root.as_str(), "main.mt", METHOD_SPEC_MAIN):
        expect(false, "could not write main")

    var main_path = path_ops.join(root.as_str(), "main.mt")
    defer: main_path.release()
    var roots = array[str, 1](root.as_str())
    var program = loader.check_program(main_path.as_str(), roots.as_span(), resolver.Platform.linux)
    defer: program.release()
    expect_eq(int<-program.diagnostic_count(), 1)


@[test]
function test_nullable_source_into_non_nullable_target_is_flagged() -> void:
    # A nullable value is not assignable to a non-nullable target: the host's
    # `types_compatible?` has no such coercion, and the flow refinement is what
    # narrows a guarded use to its base.
    var source = <<-SRC
        function ret_ptr(p: ptr[int]?) -> ptr[int]:
            return p

        function ret_int(v: int?) -> int:
            return v

        function ret_str(p: ptr[int]?) -> str:
            return p
    SRC
    expect_eq(int<-diagnostic_count(source), 3)


@[test]
function test_nullable_source_narrowed_by_guards_is_clean() -> void:
    # A guard that exits (`if v == null: return`) narrows the continuation, and
    # a truthy `if`/`while`/`and` condition narrows the body, so the guarded
    # uses are the non-null base type.
    var source = <<-SRC
        function guard_return(v: int?) -> int:
            if v == null:
                return 0
            return v

        function guard_branch(p: ptr[int]?) -> ptr[int]?:
            if p != null:
                return p
            return null

        function guard_and(v: int?) -> int:
            if v != null and v > 0:
                return v
            return 0

        function guard_while(v: int?) -> int:
            while v != null:
                return v
            return 0
    SRC
    expect_clean(source)


@[test]
function test_refined_assignment_target_uses_the_storage_type() -> void:
    # An assignment target is checked against the binding's *storage* type (the
    # host's `infer_lvalue` -> `binding.storage_type`), so a binding the flow
    # refinement narrowed still accepts its declared nullable type.
    var source = <<-SRC
        function demo(v: ptr[int]?) -> ptr[int]?:
            var x = v
            if x == null:
                return null
            x = v
            return x

        function loop(v: ptr[int]?) -> ptr[int]?:
            var x = v
            while x != null:
                x = v
            return x
    SRC
    expect_clean(source)


@[test]
function test_module_level_value_narrows_through_a_guard() -> void:
    # A module-level value has no scope binding; the host seeds module bindings
    # into its scopes, so `if g == null: return` narrows it for the rest of the
    # body and the guarded use is clean.
    var source = <<-SRC
        var g: ptr[char]? = null

        function take(p: ptr[char]) -> int:
            return 0

        function f() -> int:
            if g == null:
                return 0
            return take(g)
    SRC
    expect_clean(source)
