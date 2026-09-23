# In-language parser tests for the self-hosted mtc compiler.
# Run with: mtc test projects/mtc

import std.vec as vec
import mtc.parser.parser as parser
import mtc.parser.state as pstate


function check_parse(source: str) -> void:
    var diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer: diags.release()
    let (ok, decl_count) = parser.parse_reporting(source, ref_of(diags))
    if not ok:
        expect(false, "parse errors")
    return


@[test]
function test_parses_function() -> void:
    var source = <<-SRC
        function main() -> int:
            return 0
    SRC
    check_parse(source)


@[test]
function test_parses_block_const() -> void:
    var source = <<-SRC
        const VAL -> int:
            return 42
    SRC
    check_parse(source)


@[test]
function test_parses_const_equal() -> void:
    var source = <<-SRC
        const WIDTH: int = 42
    SRC
    check_parse(source)


@[test]
function test_parses_var() -> void:
    var source = <<-SRC
        var counter: int = 0
    SRC
    check_parse(source)


@[test]
function test_parses_if_else() -> void:
    var source = <<-SRC
        function main() -> int:
            if true:
                return 1
            else:
                return 0
    SRC
    check_parse(source)


@[test]
function test_parses_while() -> void:
    var source = <<-SRC
        function main() -> int:
            var i: int = 0
            while i < 10:
                i += 1
            return i
    SRC
    check_parse(source)


@[test]
function test_parses_match_int() -> void:
    var source = <<-SRC
        function main() -> int:
            match 0:
                0:
                    return 42
                _:
                    return 0
    SRC
    check_parse(source)


@[test]
function test_parses_struct() -> void:
    var source = <<-SRC
        struct Vec2:
            x: float
            y: float
    SRC
    check_parse(source)


@[test]
function test_parses_for_range() -> void:
    var source = <<-SRC
        function main() -> int:
            var total: int = 0
            for i in 0..4:
                total += i
            return total
    SRC
    check_parse(source)


@[test]
function test_parses_let_else() -> void:
    var source = <<-SRC
        function main() -> int:
            let x: ptr[int]? = null
            let val = x else:
                return 1
            return 0
    SRC
    check_parse(source)


@[test]
function test_parses_defer() -> void:
    var source = <<-SRC
        function main() -> int:
            defer:
                var x: int = 1
            return 0
    SRC
    check_parse(source)


@[test]
function test_parses_unsafe_block() -> void:
    var source = <<-SRC
        function main() -> int:
            unsafe:
                return 0
    SRC
    check_parse(source)


@[test]
function test_parses_import_as() -> void:
    var source = <<-SRC
        import std.vec as vec
    SRC
    check_parse(source)


@[test]
function test_parses_generic_function() -> void:
    var source = <<-SRC
        function first[T](pair: Pair[T, int]) -> T:
            return pair.first
    SRC
    check_parse(source)


@[test]
function test_parses_value_type_param() -> void:
    var source = <<-SRC
        function int_with_bits[N: int]() -> type:
            if N == 32:
                return int
            return byte
    SRC
    check_parse(source)


@[test]
function test_parses_lifetime_param() -> void:
    var source = <<-SRC
        struct Buffer[@a]:
            data: ref[@a, span[ubyte]]
    SRC
    check_parse(source)


@[test]
function test_parses_implements_on_struct() -> void:
    var source = <<-SRC
        struct NPC implements Damageable, Named:
            hp: int
    SRC
    check_parse(source)


@[test]
function test_parses_implements_on_function() -> void:
    var source = <<-SRC
        function describe[T implements Damageable and Named](target: ref[T]) -> str:
            return target.name()
    SRC
    check_parse(source)


@[test]
function test_parses_variant_with_type_params() -> void:
    var source = <<-SRC
        variant Option[T]:
            some(value: T)
            none
    SRC
    check_parse(source)


@[test]
function test_parses_enum_with_backing_type() -> void:
    var source = <<-SRC
        enum Color: ubyte
            red   = 1
            green = 2
            blue  = 3
    SRC
    check_parse(source)


@[test]
function test_parses_enum_default_backing() -> void:
    var source = <<-SRC
        enum Color:
            red
            green
            blue
    SRC
    check_parse(source)


@[test]
function test_parses_flags() -> void:
    var source = <<-SRC
        flags Mask: uint
            a = 1 << 0
            b = 1 << 1
    SRC
    check_parse(source)


@[test]
function test_parses_flags_default_backing() -> void:
    var source = <<-SRC
        flags Perm:
            read  = 1 << 0
            write = 1 << 1
    SRC
    check_parse(source)


@[test]
function test_parses_union() -> void:
    var source = <<-SRC
        union Number:
            i: int
            f: float
    SRC
    check_parse(source)


@[test]
function test_parses_opaque() -> void:
    var source = <<-SRC
        opaque RawHandle
    SRC
    check_parse(source)


@[test]
function test_parses_opaque_with_implements() -> void:
    var source = <<-SRC
        opaque CFile implements Closable
    SRC
    check_parse(source)


@[test]
function test_parses_interface() -> void:
    var source = <<-SRC
        interface Damageable:
            editable function take_damage(amount: int) -> void
            function is_alive() -> bool
            static function max_hp() -> int
    SRC
    check_parse(source)


@[test]
function test_parses_generic_interface() -> void:
    var source = <<-SRC
        interface Mapper[T]:
            function map(x: T) -> T
    SRC
    check_parse(source)


@[test]
function test_parses_async_interface_method() -> void:
    var source = <<-SRC
        interface Runner:
            async function run() -> int
    SRC
    check_parse(source)


@[test]
function test_parses_extending_block() -> void:
    var source = <<-SRC
        extending Counter:
            function read() -> int:
                return this.value
            editable function bump() -> void:
                this.value += 1
            static function zero() -> Counter:
                return Counter(value = 0)
    SRC
    check_parse(source)


@[test]
function test_parses_public_method() -> void:
    var source = <<-SRC
        extending Arena:
            public function len() -> ptr_uint:
                return this.len
    SRC
    check_parse(source)


@[test]
function test_parses_when_statement() -> void:
    var source = <<-SRC
        function label() -> str:
            when TARGET:
                TargetBackend.gl:
                    return "gl"
                TargetBackend.vulkan:
                    return "vk"
    SRC
    check_parse(source)


@[test]
function test_parses_when_declaration() -> void:
    var source = <<-SRC
        const CURRENT: int = 1
        when CURRENT:
            1:
                const MODULE_VAL: str = "one"
            2:
                const MODULE_VAL: str = "two"
    SRC
    check_parse(source)


@[test]
function test_parses_when_decl_with_else() -> void:
    var source = <<-SRC
        const X: int = 1
        when X:
            1:
                function f1() -> int:
                    return 1
            else:
                function fallback() -> int:
                    return 0
    SRC
    check_parse(source)


@[test]
function test_parses_inline_for() -> void:
    var source = <<-SRC
        function check_fields() -> bool:
            inline for field in fields_of(Particle):
                if field.type != float:
                    return false
            return true
    SRC
    check_parse(source)


@[test]
function test_parses_inline_while() -> void:
    var source = <<-SRC
        const ROUNDED -> int:
            var n: int = 1
            inline while n < 1024:
                n = n * 2
            return n
    SRC
    check_parse(source)


@[test]
function test_parses_inline_match() -> void:
    var source = <<-SRC
        function label() -> str:
            inline match COLOR:
                Color.red:
                    return "red"
                Color.blue:
                    return "blue"
    SRC
    check_parse(source)


@[test]
function test_parses_inline_if() -> void:
    var source = <<-SRC
        function draw() -> void:
            inline if DEBUG:
                overlay()
            else:
                normalize()
    SRC
    check_parse(source)


@[test]
function test_parses_inline_if_type_compare() -> void:
    var source = <<-SRC
        function label[T]() -> str:
            inline if T == int:
                return "int"
            return "other"
    SRC
    check_parse(source)


@[test]
function test_parses_match_with_pipe() -> void:
    var source = <<-SRC
        function test() -> int:
            match result:
                0 | 1 | 2:
                    return 10
                3 | 4:
                    return 20
                _:
                    return 0
    SRC
    check_parse(source)


@[test]
function test_parses_match_else_wildcard() -> void:
    var source = <<-SRC
        function test() -> int:
            match value:
                else:
                    return -1
    SRC
    check_parse(source)


@[test]
function test_parses_match_expression_form() -> void:
    var source = <<-SRC
        function test() -> str:
            return match code:
                1: "one"
                2: "two"
                _: "other"
    SRC
    check_parse(source)


@[test]
function test_parses_destructure_tuple() -> void:
    var source = <<-SRC
        function test() -> int:
            let (a, b) = pair()
            return a + b
    SRC
    check_parse(source)


@[test]
function test_parses_destructure_discard() -> void:
    var source = <<-SRC
        function test() -> int:
            let (_, _, third) = triple()
            return third
    SRC
    check_parse(source)


@[test]
function test_parses_destructure_struct_pattern() -> void:
    var source = <<-SRC
        function test() -> float:
            let Vec2(x, y) = get_pos()
            return x + y
    SRC
    check_parse(source)


@[test]
function test_parses_extern_function() -> void:
    var source = <<-SRC
        external function atoi(input: cstr) -> int
    SRC
    check_parse(source)


@[test]
function test_parses_extern_with_mapping() -> void:
    var source = <<-SRC
        external function fopen(path: cstr, mode: cstr) -> ptr[void]? = c.fopen
    SRC
    check_parse(source)


@[test]
function test_parses_foreign_function() -> void:
    var source = <<-SRC
        foreign function parse_int(input: str as cstr) -> int = atoi
    SRC
    check_parse(source)


@[test]
function test_parses_foreign_out_param() -> void:
    var source = <<-SRC
        foreign function load_file(out data_size: int, path: str as cstr) -> ptr[ubyte]? = c.LoadFileData
    SRC
    check_parse(source)


@[test]
function test_parses_prefix_cast() -> void:
    var source = <<-SRC
        function test() -> int:
            var x: int = 42
            return int<-x
    SRC
    check_parse(source)


@[test]
function test_parses_specialization_basic() -> void:
    var source = <<-SRC
        function test() -> int:
            let pair = Vec2[int](x = 1, y = 2)
            return pair
    SRC
    check_parse(source)


@[test]
function test_parses_specialization_call() -> void:
    var source = <<-SRC
        function test() -> NPC:
            return default[NPC]()
    SRC
    check_parse(source)


@[test]
function test_parses_nullable_type_null() -> void:
    var source = <<-SRC
        function test() -> void:
            let p: ptr[int]? = null
            let q: ptr[int]? = null[ptr[int]]
    SRC
    check_parse(source)


@[test]
function test_parses_fn_type() -> void:
    var source = <<-SRC
        type Callback = fn(value: int) -> void
    SRC
    check_parse(source)


@[test]
function test_parses_proc_type() -> void:
    var source = <<-SRC
        type Gen = proc() -> int
    SRC
    check_parse(source)


@[test]
function test_parses_dyn_type() -> void:
    var source = <<-SRC
        type Shape = dyn[Damageable]
    SRC
    check_parse(source)


@[test]
function test_parses_tuple_type() -> void:
    var source = <<-SRC
        type Pair = (int, str)
    SRC
    check_parse(source)


@[test]
function test_parses_nested_struct() -> void:
    var source = <<-SRC
        struct Rectangle:
            x: float
            y: float
            struct Edge:
                start: float
                end: float
            top_edge: Edge
    SRC
    check_parse(source)


@[test]
function test_parses_struct_with_event() -> void:
    var source = <<-SRC
        struct Container:
            event ready[4]
            data: int
    SRC
    check_parse(source)


@[test]
function test_parses_packed_attribute() -> void:
    var source = <<-SRC
        @[packed]
        struct Header:
            tag: ubyte
    SRC
    check_parse(source)


@[test]
function test_parses_align_attribute() -> void:
    var source = <<-SRC
        @[align(16)]
        struct Mat4:
            data: array[float, 16]
    SRC
    check_parse(source)


@[test]
function test_parses_field_attribute() -> void:
    var source = <<-SRC
        struct Labeled:
            @[rename("val")]
            value: int
    SRC
    check_parse(source)


@[test]
function test_parses_deprecated_attribute() -> void:
    var source = <<-SRC
        @[deprecated("use new fn")]
        function old_fn() -> void:
            return
    SRC
    check_parse(source)


@[test]
function test_parses_attribute_declaration() -> void:
    var source = <<-SRC
        attribute[field] rename(name: str)
    SRC
    check_parse(source)


@[test]
function test_parses_multi_target_attribute() -> void:
    var source = <<-SRC
        attribute[const, event, enum] tagged(tag: str)
    SRC
    check_parse(source)


@[test]
function test_parses_const_function() -> void:
    var source = <<-SRC
        const function square(x: int) -> int:
            return x * x
    SRC
    check_parse(source)


@[test]
function test_parses_emit_statement() -> void:
    var source = <<-SRC
        const function helpers() -> void:
            emit function zero() -> int:
                return 0
    SRC
    check_parse(source)


@[test]
function test_parses_detach_and_gather() -> void:
    var source = <<-SRC
        function main() -> int:
            let a = detach compute()
            let b = detach compute()
            gather a, b
            return 0
    SRC
    check_parse(source)


@[test]
function test_parses_parallel_for() -> void:
    var source = <<-SRC
        function main() -> int:
            var arr: array[int, 4]
            parallel for i in 0..4:
                arr[i] = i
            return 0
    SRC
    check_parse(source)


@[test]
function test_parses_parallel_block() -> void:
    var source = <<-SRC
        function main() -> int:
            var a: int = 0
            var b: int = 0
            parallel:
                a = 1
                b = 2
            return a + b
    SRC
    check_parse(source)


@[test]
function test_parses_async_function() -> void:
    var source = <<-SRC
        async function worker() -> int:
            return 42
    SRC
    check_parse(source)


@[test]
function test_parses_await_expression() -> void:
    var source = <<-SRC
        async function caller() -> int:
            let v = await worker()
            return v
    SRC
    check_parse(source)


@[test]
function test_parses_proc_expression() -> void:
    var source = <<-SRC
        function test() -> int:
            let cb = proc(x: int) -> int: x * 2
            return cb(5)
    SRC
    check_parse(source)


@[test]
function test_parses_proc_with_body() -> void:
    var source = <<-SRC
        function test() -> int:
            let cb = proc(x: int) -> int:
                return x + 1
            return cb(5)
    SRC
    check_parse(source)


@[test]
function test_parses_format_string() -> void:
    var source = <<-SRC
        function test() -> str:
            let count = 42
            return f"count=#{count}"
    SRC
    check_parse(source)


@[test]
function test_parses_str_buffer() -> void:
    var source = <<-SRC
        function test() -> void:
            var buf: str_buffer[64]
            buf.assign("hello")
            buf.append(" world")
    SRC
    check_parse(source)


@[test]
function test_parses_static_assert() -> void:
    var source = <<-SRC
        static_assert(size_of(int) == 4, "int must be 4 bytes")
    SRC
    check_parse(source)


@[test]
function test_parses_event_declaration() -> void:
    var source = <<-SRC
        public event ready[4]
        public event updated[8](float)
    SRC
    check_parse(source)


@[test]
function test_parses_is_expression() -> void:
    var source = <<-SRC
        function test() -> int:
            let t = token
            if t is TokenKind.eof:
                return 1
            return 0
    SRC
    check_parse(source)


@[test]
function test_parses_adjacent_strings() -> void:
    var source = <<-SRC
        function test() -> str:
            return "hello "
                "world"
    SRC
    check_parse(source)


@[test]
function test_parses_question_propagation() -> void:
    var source = <<-SRC
        function test() -> Option[int]:
            let parsed = parseInt("42")?
            return Option[int].some(value = parsed)
    SRC
    check_parse(source)


@[test]
function test_parses_external_file_header() -> void:
    var source = <<-SRC
        external

        include "header.h"
        link "mylib"

        struct Color:
            r: ubyte
            g: ubyte
            b: ubyte

        external function init() -> void
    SRC
    check_parse(source)


function check_parse_fails(source: str) -> void:
    var diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer: diags.release()
    let (ok, decl_count) = parser.parse_reporting(source, ref_of(diags))
    if ok:
        expect(false, "expected parse errors but got none")
    return


# =============================================================================
#  Statement coverage
# =============================================================================

@[test]
function test_parses_break() -> void:
    var source = <<-SRC
        function test() -> int:
            var i: int = 0
            while i < 10:
                if i == 5:
                    break
                i += 1
            return i
    SRC
    check_parse(source)


@[test]
function test_parses_continue() -> void:
    var source = <<-SRC
        function test() -> int:
            var i: int = 0
            var s: int = 0
            while i < 10:
                i += 1
                if i == 5:
                    continue
                s += i
            return s
    SRC
    check_parse(source)


@[test]
function test_parses_pass() -> void:
    var source = <<-SRC
        function noop() -> void:
            pass
    SRC
    check_parse(source)


@[test]
function test_parses_return_void() -> void:
    var source = <<-SRC
        function test():
            return
    SRC
    check_parse(source)


@[test]
function test_parses_let_discard_else() -> void:
    var source = <<-SRC
        function test() -> int:
            let _ = maybe_val() else:
                return 1
            return 0
    SRC
    check_parse(source)


@[test]
function test_parses_var_else_guard() -> void:
    var source = <<-SRC
        function test() -> int:
            var x = maybe_int() else:
                return 1
            return x
    SRC
    check_parse(source)


@[test]
function test_parses_let_else_as_error() -> void:
    var source = <<-SRC
        function test() -> int:
            let val = maybe_result() else as error:
                return error
            return val
    SRC
    check_parse(source)


@[test]
function test_parses_unsafe_expression_form() -> void:
    var source = <<-SRC
        function test() -> int:
            let val = unsafe: read(ptr)
            return val
    SRC
    check_parse(source)


@[test]
function test_parses_single_line_if_else() -> void:
    var source = <<-SRC
        function test() -> int:
            if true: return 1 else: return 0
    SRC
    check_parse(source)


@[test]
function test_parses_range_index_assignment() -> void:
    var source = <<-SRC
        function test() -> void:
            var buf: array[float, 4]
            buf[0..2] = (1.0, 2.0)
    SRC
    check_parse(source)


@[test]
function test_parses_named_args() -> void:
    var source = <<-SRC
        function configure(host: str, port: int) -> void:
            pass
        function test() -> int:
            configure(host = "localhost", port = 8080)
            return 1
    SRC
    check_parse(source)


@[test]
function test_parses_enum_comparison() -> void:
    var source = <<-SRC
        enum Color: ubyte
            red = 1
            green = 2
        function test() -> bool:
            return Color.red == Color.red and Color.red != Color.green and Color.red < Color.green
    SRC
    check_parse(source)


@[test]
function test_parses_flags_bitwise() -> void:
    var source = <<-SRC
        flags Mask: uint
            a = 1 << 0
            b = 1 << 1
        function test() -> uint:
            var m = Mask.a
            m = m | Mask.b
            m = m & Mask.a
            return uint<-(m)
    SRC
    check_parse(source)


@[test]
function test_parses_heredoc_string() -> void:
    var source = <<-SRC
        const GREET: str = <<-MSG
            hello world
        MSG
    SRC
    check_parse(source)


@[test]
function test_parses_heredoc_cstring() -> void:
    var source = <<-SRC
        const SHADER: cstr = c<<-GLSL
            void main() {}
        GLSL
    SRC
    check_parse(source)


@[test]
function test_parses_multiple_imports() -> void:
    var source = <<-SRC
        import std.vec as vec
        import std.map as map
        import std.str
    SRC
    check_parse(source)


@[test]
function test_parses_complex_precedence() -> void:
    var source = <<-SRC
        function test() -> bool:
            return not (a == b) and (c or d) or not e is Kind.eof
    SRC
    check_parse(source)


@[test]
function test_parses_nested_if_else() -> void:
    var source = <<-SRC
        function test() -> int:
            if a:
                return 1
            else if b:
                return 2
            else if c:
                return 3
            else:
                return 0
    SRC
    check_parse(source)


@[test]
function test_parses_var_no_initializer() -> void:
    var source = <<-SRC
        function test() -> int:
            var result: int
            result = 42
            return result
    SRC
    check_parse(source)


@[test]
function test_parses_while_with_and_condition() -> void:
    var source = <<-SRC
        function test() -> int:
            var i: int = 0
            var j: int = 0
            while i < 5 and j < 3:
                i += 1
                j += 1
            return i
    SRC
    check_parse(source)


# =============================================================================
#  Error recovery / negative tests
# =============================================================================

@[test]
function test_errors_on_missing_colon_after_if() -> void:
    var source = <<-SRC
        function test() -> int:
            if true
                return 1
            return 0
    SRC
    check_parse_fails(source)


@[test]
function test_errors_on_unexpected_token_in_body() -> void:
    var source = <<-SRC
        function test() -> int:
            var x: int = @@@
            return 0
    SRC
    check_parse_fails(source)


@[test]
function test_errors_on_missing_end_of_statement() -> void:
    var source = <<-SRC
        const X: int = 42
        const Y: int 42
    SRC
    check_parse_fails(source)


@[test]
function test_recovery_continues_after_error() -> void:
    var source = <<-SRC
        function good() -> int:
            return 1
        garbage_token
        function also_good() -> int:
            return 2
    SRC
    check_parse_fails(source)
