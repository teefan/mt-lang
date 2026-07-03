# In-language parser tests for the self-hosted mtc compiler.
# Run with: mtc test projects/mtc

import std.testing as t
import std.vec as vec
import mtc.parser.parser as parser


function check_parse(source: str) -> t.Check:
    var diags = vec.Vec[parser.ParseDiagnostic].create()
    defer diags.release()
    let (ok, decl_count) = parser.parse_reporting(source, ref_of(diags))
    if not ok:
        return t.fail("parse errors")
    return t.ok()


@[test]
function test_parses_function() -> t.Check:
    var source = <<-SRC
        function main() -> int:
            return 0
    SRC
    return check_parse(source)


@[test]
function test_parses_block_const() -> t.Check:
    var source = <<-SRC
        const VAL -> int:
            return 42
    SRC
    return check_parse(source)


@[test]
function test_parses_const_equal() -> t.Check:
    var source = <<-SRC
        const WIDTH: int = 42
    SRC
    return check_parse(source)


@[test]
function test_parses_var() -> t.Check:
    var source = <<-SRC
        var counter: int = 0
    SRC
    return check_parse(source)


@[test]
function test_parses_if_else() -> t.Check:
    var source = <<-SRC
        function main() -> int:
            if true:
                return 1
            else:
                return 0
    SRC
    return check_parse(source)


@[test]
function test_parses_while() -> t.Check:
    var source = <<-SRC
        function main() -> int:
            var i: int = 0
            while i < 10:
                i += 1
            return i
    SRC
    return check_parse(source)


@[test]
function test_parses_match_int() -> t.Check:
    var source = <<-SRC
        function main() -> int:
            match 0:
                0:
                    return 42
                _:
                    return 0
    SRC
    return check_parse(source)


@[test]
function test_parses_struct() -> t.Check:
    var source = <<-SRC
        struct Vec2:
            x: float
            y: float
    SRC
    return check_parse(source)


@[test]
function test_parses_for_range() -> t.Check:
    var source = <<-SRC
        function main() -> int:
            var total: int = 0
            for i in 0..4:
                total += i
            return total
    SRC
    return check_parse(source)


@[test]
function test_parses_let_else() -> t.Check:
    var source = <<-SRC
        function main() -> int:
            let x: ptr[int]? = null
            let val = x else:
                return 1
            return 0
    SRC
    return check_parse(source)


@[test]
function test_parses_defer() -> t.Check:
    var source = <<-SRC
        function main() -> int:
            defer:
                var x: int = 1
            return 0
    SRC
    return check_parse(source)


@[test]
function test_parses_unsafe_block() -> t.Check:
    var source = <<-SRC
        function main() -> int:
            unsafe:
                return 0
    SRC
    return check_parse(source)


@[test]
function test_parses_import_as() -> t.Check:
    var source = <<-SRC
        import std.vec as vec
    SRC
    return check_parse(source)


@[test]
function test_parses_generic_function() -> t.Check:
    var source = <<-SRC
        function first[T](pair: Pair[T, int]) -> T:
            return pair.first
    SRC
    return check_parse(source)


@[test]
function test_parses_value_type_param() -> t.Check:
    var source = <<-SRC
        function int_with_bits[N: int]() -> type:
            if N == 32:
                return int
            return byte
    SRC
    return check_parse(source)


@[test]
function test_parses_lifetime_param() -> t.Check:
    var source = <<-SRC
        struct Buffer[@a]:
            data: ref[@a, span[ubyte]]
    SRC
    return check_parse(source)


@[test]
function test_parses_implements_on_struct() -> t.Check:
    var source = <<-SRC
        struct NPC implements Damageable, Named:
            hp: int
    SRC
    return check_parse(source)


@[test]
function test_parses_implements_on_function() -> t.Check:
    var source = <<-SRC
        function describe[T implements Damageable and Named](target: ref[T]) -> str:
            return target.name()
    SRC
    return check_parse(source)


@[test]
function test_parses_variant_with_type_params() -> t.Check:
    var source = <<-SRC
        variant Option[T]:
            some(value: T)
            none
    SRC
    return check_parse(source)


@[test]
function test_parses_enum_with_backing_type() -> t.Check:
    var source = <<-SRC
        enum Color: ubyte
            red   = 1
            green = 2
            blue  = 3
    SRC
    return check_parse(source)


@[test]
function test_parses_enum_default_backing() -> t.Check:
    var source = <<-SRC
        enum Color:
            red
            green
            blue
    SRC
    return check_parse(source)


@[test]
function test_parses_flags() -> t.Check:
    var source = <<-SRC
        flags Mask: uint
            a = 1 << 0
            b = 1 << 1
    SRC
    return check_parse(source)


@[test]
function test_parses_flags_default_backing() -> t.Check:
    var source = <<-SRC
        flags Perm:
            read  = 1 << 0
            write = 1 << 1
    SRC
    return check_parse(source)


@[test]
function test_parses_union() -> t.Check:
    var source = <<-SRC
        union Number:
            i: int
            f: float
    SRC
    return check_parse(source)


@[test]
function test_parses_opaque() -> t.Check:
    var source = <<-SRC
        opaque RawHandle
    SRC
    return check_parse(source)


@[test]
function test_parses_opaque_with_implements() -> t.Check:
    var source = <<-SRC
        opaque CFile implements Closable
    SRC
    return check_parse(source)


@[test]
function test_parses_interface() -> t.Check:
    var source = <<-SRC
        interface Damageable:
            editable function take_damage(amount: int) -> void
            function is_alive() -> bool
            static function max_hp() -> int
    SRC
    return check_parse(source)


@[test]
function test_parses_generic_interface() -> t.Check:
    var source = <<-SRC
        interface Mapper[T]:
            function map(x: T) -> T
    SRC
    return check_parse(source)


@[test]
function test_parses_async_interface_method() -> t.Check:
    var source = <<-SRC
        interface Runner:
            async function run() -> int
    SRC
    return check_parse(source)


@[test]
function test_parses_extending_block() -> t.Check:
    var source = <<-SRC
        extending Counter:
            function read() -> int:
                return this.value
            editable function bump() -> void:
                this.value += 1
            static function zero() -> Counter:
                return Counter(value = 0)
    SRC
    return check_parse(source)


@[test]
function test_parses_public_method() -> t.Check:
    var source = <<-SRC
        extending Arena:
            public function len() -> ptr_uint:
                return this.len
    SRC
    return check_parse(source)


@[test]
function test_parses_when_statement() -> t.Check:
    var source = <<-SRC
        function label() -> str:
            when TARGET:
                TargetBackend.gl:
                    return "gl"
                TargetBackend.vulkan:
                    return "vk"
    SRC
    return check_parse(source)


@[test]
function test_parses_when_declaration() -> t.Check:
    var source = <<-SRC
        const CURRENT: int = 1
        when CURRENT:
            1:
                const MODULE_VAL: str = "one"
            2:
                const MODULE_VAL: str = "two"
    SRC
    return check_parse(source)


@[test]
function test_parses_when_decl_with_else() -> t.Check:
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
    return check_parse(source)


@[test]
function test_parses_inline_for() -> t.Check:
    var source = <<-SRC
        function check_fields() -> bool:
            inline for field in fields_of(Particle):
                if field.type != float:
                    return false
            return true
    SRC
    return check_parse(source)


@[test]
function test_parses_inline_while() -> t.Check:
    var source = <<-SRC
        const ROUNDED -> int:
            var n: int = 1
            inline while n < 1024:
                n = n * 2
            return n
    SRC
    return check_parse(source)


@[test]
function test_parses_inline_match() -> t.Check:
    var source = <<-SRC
        function label() -> str:
            inline match COLOR:
                Color.red:
                    return "red"
                Color.blue:
                    return "blue"
    SRC
    return check_parse(source)


@[test]
function test_parses_inline_if() -> t.Check:
    var source = <<-SRC
        function draw() -> void:
            inline if DEBUG:
                overlay()
            else:
                normalize()
    SRC
    return check_parse(source)


@[test]
function test_parses_inline_if_type_compare() -> t.Check:
    var source = <<-SRC
        function label[T]() -> str:
            inline if T == int:
                return "int"
            return "other"
    SRC
    return check_parse(source)


@[test]
function test_parses_match_with_pipe() -> t.Check:
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
    return check_parse(source)


@[test]
function test_parses_match_else_wildcard() -> t.Check:
    var source = <<-SRC
        function test() -> int:
            match value:
                else:
                    return -1
    SRC
    return check_parse(source)


@[test]
function test_parses_match_expression_form() -> t.Check:
    var source = <<-SRC
        function test() -> str:
            return match code:
                1: "one"
                2: "two"
                _: "other"
    SRC
    return check_parse(source)


@[test]
function test_parses_destructure_tuple() -> t.Check:
    var source = <<-SRC
        function test() -> int:
            let (a, b) = pair()
            return a + b
    SRC
    return check_parse(source)


@[test]
function test_parses_destructure_discard() -> t.Check:
    var source = <<-SRC
        function test() -> int:
            let (_, _, third) = triple()
            return third
    SRC
    return check_parse(source)


@[test]
function test_parses_destructure_struct_pattern() -> t.Check:
    var source = <<-SRC
        function test() -> float:
            let Vec2(x, y) = get_pos()
            return x + y
    SRC
    return check_parse(source)


@[test]
function test_parses_extern_function() -> t.Check:
    var source = <<-SRC
        external function atoi(input: cstr) -> int
    SRC
    return check_parse(source)


@[test]
function test_parses_extern_with_mapping() -> t.Check:
    var source = <<-SRC
        external function fopen(path: cstr, mode: cstr) -> ptr[void]? = c.fopen
    SRC
    return check_parse(source)


@[test]
function test_parses_foreign_function() -> t.Check:
    var source = <<-SRC
        foreign function parse_int(input: str as cstr) -> int = atoi
    SRC
    return check_parse(source)


@[test]
function test_parses_foreign_out_param() -> t.Check:
    var source = <<-SRC
        foreign function load_file(out data_size: int, path: str as cstr) -> ptr[ubyte]? = c.LoadFileData
    SRC
    return check_parse(source)


@[test]
function test_parses_prefix_cast() -> t.Check:
    var source = <<-SRC
        function test() -> int:
            var x: int = 42
            return int<-x
    SRC
    return check_parse(source)


@[test]
function test_parses_specialization_basic() -> t.Check:
    var source = <<-SRC
        function test() -> int:
            let pair = Vec2[int](x = 1, y = 2)
            return pair
    SRC
    return check_parse(source)


@[test]
function test_parses_specialization_call() -> t.Check:
    var source = <<-SRC
        function test() -> NPC:
            return default[NPC]()
    SRC
    return check_parse(source)


@[test]
function test_parses_nullable_type_null() -> t.Check:
    var source = <<-SRC
        function test() -> void:
            let p: ptr[int]? = null
            let q: ptr[int]? = null[ptr[int]]
    SRC
    return check_parse(source)


@[test]
function test_parses_fn_type() -> t.Check:
    var source = <<-SRC
        type Callback = fn(value: int) -> void
    SRC
    return check_parse(source)


@[test]
function test_parses_proc_type() -> t.Check:
    var source = <<-SRC
        type Gen = proc() -> int
    SRC
    return check_parse(source)


@[test]
function test_parses_dyn_type() -> t.Check:
    var source = <<-SRC
        type Shape = dyn[Damageable]
    SRC
    return check_parse(source)


@[test]
function test_parses_tuple_type() -> t.Check:
    var source = <<-SRC
        type Pair = (int, str)
    SRC
    return check_parse(source)


@[test]
function test_parses_nested_struct() -> t.Check:
    var source = <<-SRC
        struct Rectangle:
            x: float
            y: float
            struct Edge:
                start: float
                end: float
            top_edge: Edge
    SRC
    return check_parse(source)


@[test]
function test_parses_struct_with_event() -> t.Check:
    var source = <<-SRC
        struct Container:
            event ready[4]
            data: int
    SRC
    return check_parse(source)


@[test]
function test_parses_packed_attribute() -> t.Check:
    var source = <<-SRC
        @[packed]
        struct Header:
            tag: ubyte
    SRC
    return check_parse(source)


@[test]
function test_parses_align_attribute() -> t.Check:
    var source = <<-SRC
        @[align(16)]
        struct Mat4:
            data: array[float, 16]
    SRC
    return check_parse(source)


@[test]
function test_parses_field_attribute() -> t.Check:
    var source = <<-SRC
        struct Labeled:
            @[rename("val")]
            value: int
    SRC
    return check_parse(source)


@[test]
function test_parses_deprecated_attribute() -> t.Check:
    var source = <<-SRC
        @[deprecated("use new fn")]
        function old_fn() -> void:
            return
    SRC
    return check_parse(source)


@[test]
function test_parses_attribute_declaration() -> t.Check:
    var source = <<-SRC
        attribute[field] rename(name: str)
    SRC
    return check_parse(source)


@[test]
function test_parses_multi_target_attribute() -> t.Check:
    var source = <<-SRC
        attribute[const, event, enum] tagged(tag: str)
    SRC
    return check_parse(source)


@[test]
function test_parses_const_function() -> t.Check:
    var source = <<-SRC
        const function square(x: int) -> int:
            return x * x
    SRC
    return check_parse(source)


@[test]
function test_parses_emit_statement() -> t.Check:
    var source = <<-SRC
        const function helpers() -> void:
            emit function zero() -> int:
                return 0
    SRC
    return check_parse(source)


@[test]
function test_parses_detach_and_gather() -> t.Check:
    var source = <<-SRC
        function main() -> int:
            let a = detach compute()
            let b = detach compute()
            gather a, b
            return 0
    SRC
    return check_parse(source)


@[test]
function test_parses_parallel_for() -> t.Check:
    var source = <<-SRC
        function main() -> int:
            var arr: array[int, 4]
            parallel for i in 0..4:
                arr[i] = i
            return 0
    SRC
    return check_parse(source)


@[test]
function test_parses_parallel_block() -> t.Check:
    var source = <<-SRC
        function main() -> int:
            var a: int = 0
            var b: int = 0
            parallel:
                a = 1
                b = 2
            return a + b
    SRC
    return check_parse(source)


@[test]
function test_parses_async_function() -> t.Check:
    var source = <<-SRC
        async function worker() -> int:
            return 42
    SRC
    return check_parse(source)


@[test]
function test_parses_await_expression() -> t.Check:
    var source = <<-SRC
        async function caller() -> int:
            let v = await worker()
            return v
    SRC
    return check_parse(source)


@[test]
function test_parses_proc_expression() -> t.Check:
    var source = <<-SRC
        function test() -> int:
            let cb = proc(x: int) -> int: x * 2
            return cb(5)
    SRC
    return check_parse(source)


@[test]
function test_parses_proc_with_body() -> t.Check:
    var source = <<-SRC
        function test() -> int:
            let cb = proc(x: int) -> int:
                return x + 1
            return cb(5)
    SRC
    return check_parse(source)


@[test]
function test_parses_format_string() -> t.Check:
    var source = <<-SRC
        function test() -> str:
            let count = 42
            return f"count=#{count}"
    SRC
    return check_parse(source)


@[test]
function test_parses_str_buffer() -> t.Check:
    var source = <<-SRC
        function test() -> void:
            var buf: str_buffer[64]
            buf.assign("hello")
            buf.append(" world")
    SRC
    return check_parse(source)


@[test]
function test_parses_static_assert() -> t.Check:
    var source = <<-SRC
        static_assert(size_of(int) == 4, "int must be 4 bytes")
    SRC
    return check_parse(source)


@[test]
function test_parses_event_declaration() -> t.Check:
    var source = <<-SRC
        public event ready[4]
        public event updated[8](float)
    SRC
    return check_parse(source)


@[test]
function test_parses_is_expression() -> t.Check:
    var source = <<-SRC
        function test() -> int:
            let t = token
            if t is TokenKind.eof:
                return 1
            return 0
    SRC
    return check_parse(source)


@[test]
function test_parses_adjacent_strings() -> t.Check:
    var source = <<-SRC
        function test() -> str:
            return "hello "
                "world"
    SRC
    return check_parse(source)


@[test]
function test_parses_question_propagation() -> t.Check:
    var source = <<-SRC
        function test() -> Option[int]:
            let parsed = parseInt("42")?
            return Option[int].some(value = parsed)
    SRC
    return check_parse(source)


@[test]
function test_parses_external_file_header() -> t.Check:
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
    return check_parse(source)


function check_parse_fails(source: str) -> t.Check:
    var diags = vec.Vec[parser.ParseDiagnostic].create()
    defer diags.release()
    let (ok, decl_count) = parser.parse_reporting(source, ref_of(diags))
    if ok:
        return t.fail("expected parse errors but got none")
    return t.ok()


# =============================================================================
#  Statement coverage
# =============================================================================

@[test]
function test_parses_break() -> t.Check:
    var source = <<-SRC
        function test() -> int:
            var i: int = 0
            while i < 10:
                if i == 5:
                    break
                i += 1
            return i
    SRC
    return check_parse(source)


@[test]
function test_parses_continue() -> t.Check:
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
    return check_parse(source)


@[test]
function test_parses_pass() -> t.Check:
    var source = <<-SRC
        function noop() -> void:
            pass
    SRC
    return check_parse(source)


@[test]
function test_parses_return_void() -> t.Check:
    var source = <<-SRC
        function test():
            return
    SRC
    return check_parse(source)


@[test]
function test_parses_let_discard_else() -> t.Check:
    var source = <<-SRC
        function test() -> int:
            let _ = maybe_val() else:
                return 1
            return 0
    SRC
    return check_parse(source)


@[test]
function test_parses_var_else_guard() -> t.Check:
    var source = <<-SRC
        function test() -> int:
            var x = maybe_int() else:
                return 1
            return x
    SRC
    return check_parse(source)


@[test]
function test_parses_let_else_as_error() -> t.Check:
    var source = <<-SRC
        function test() -> int:
            let val = maybe_result() else as error:
                return error
            return val
    SRC
    return check_parse(source)


@[test]
function test_parses_unsafe_expression_form() -> t.Check:
    var source = <<-SRC
        function test() -> int:
            let val = unsafe: read(ptr)
            return val
    SRC
    return check_parse(source)


@[test]
function test_parses_single_line_if_else() -> t.Check:
    var source = <<-SRC
        function test() -> int:
            if true: return 1 else: return 0
    SRC
    return check_parse(source)


@[test]
function test_parses_range_index_assignment() -> t.Check:
    var source = <<-SRC
        function test() -> void:
            var buf: array[float, 4]
            buf[0..2] = (1.0, 2.0)
    SRC
    return check_parse(source)


@[test]
function test_parses_named_args() -> t.Check:
    var source = <<-SRC
        function configure(host: str, port: int) -> void:
            pass
        function test() -> int:
            configure(host = "localhost", port = 8080)
            return 1
    SRC
    return check_parse(source)


@[test]
function test_parses_enum_comparison() -> t.Check:
    var source = <<-SRC
        enum Color: ubyte
            red = 1
            green = 2
        function test() -> bool:
            return Color.red == Color.red and Color.red != Color.green and Color.red < Color.green
    SRC
    return check_parse(source)


@[test]
function test_parses_flags_bitwise() -> t.Check:
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
    return check_parse(source)


@[test]
function test_parses_heredoc_string() -> t.Check:
    var source = <<-SRC
        const GREET: str = <<-MSG
            hello world
        MSG
    SRC
    return check_parse(source)


@[test]
function test_parses_heredoc_cstring() -> t.Check:
    var source = <<-SRC
        const SHADER: cstr = c<<-GLSL
            void main() {}
        GLSL
    SRC
    return check_parse(source)


@[test]
function test_parses_multiple_imports() -> t.Check:
    var source = <<-SRC
        import std.vec as vec
        import std.map as map
        import std.str
    SRC
    return check_parse(source)


@[test]
function test_parses_complex_precedence() -> t.Check:
    var source = <<-SRC
        function test() -> bool:
            return not (a == b) and (c or d) or not e is Kind.eof
    SRC
    return check_parse(source)


@[test]
function test_parses_nested_if_else() -> t.Check:
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
    return check_parse(source)


@[test]
function test_parses_var_no_initializer() -> t.Check:
    var source = <<-SRC
        function test() -> int:
            var result: int
            result = 42
            return result
    SRC
    return check_parse(source)


@[test]
function test_parses_while_with_and_condition() -> t.Check:
    var source = <<-SRC
        function test() -> int:
            var i: int = 0
            var j: int = 0
            while i < 5 and j < 3:
                i += 1
                j += 1
            return i
    SRC
    return check_parse(source)


# =============================================================================
#  Error recovery / negative tests
# =============================================================================

@[test]
function test_errors_on_missing_end_of_statement() -> t.Check:
    var source = <<-SRC
        const X: int = 42
        const Y: int 42
    SRC
    return check_parse_fails(source)


@[test]
function test_recovery_continues_after_error() -> t.Check:
    var source = <<-SRC
        function good() -> int:
            return 1
        garbage_token
        function also_good() -> int:
            return 2
    SRC
    return check_parse_fails(source)
