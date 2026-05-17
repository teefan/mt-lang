import std.fmt as fmt
import std.maybe as maybe
import std.status as status
import std.str as text
import std.string as string
import std.vec as vec
import std.mem.heap as heap

const byte_tab: ubyte = ubyte<-9
const byte_newline: ubyte = ubyte<-10
const byte_carriage_return: ubyte = ubyte<-13
const byte_space: ubyte = ubyte<-32
const byte_quote: ubyte = ubyte<-34
const byte_hash: ubyte = ubyte<-35
const byte_plus: ubyte = ubyte<-43
const byte_comma: ubyte = ubyte<-44
const byte_minus: ubyte = ubyte<-45
const byte_equal: ubyte = ubyte<-61
const byte_left_bracket: ubyte = ubyte<-91
const byte_backslash: ubyte = ubyte<-92
const byte_right_bracket: ubyte = ubyte<-93
const byte_left_brace: ubyte = ubyte<-123
const byte_right_brace: ubyte = ubyte<-125
const byte_underscore: ubyte = ubyte<-95

public struct ParseError:
    line: ptr_uint
    column: ptr_uint
    message: string.String

public enum ValueKind: int
    string = 0
    integer = 1
    boolean = 2
    array = 3
    object = 4

public struct Value:
    kind: ValueKind
    string_value: string.String
    integer_value: long
    boolean_value: bool
    array_value: ptr[Array]?
    object_value: ptr[Object]?

public struct Entry:
    key: string.String
    value: Value

public struct Object:
    entries: vec.Vec[Entry]

public struct Array:
    values: vec.Vec[Value]

public struct Table:
    name: string.String
    entries: Object

public struct ArrayTable:
    name: string.String
    tables: vec.Vec[Object]

public struct Document:
    root: Object
    tables: vec.Vec[Table]
    array_tables: vec.Vec[ArrayTable]

struct Parser:
    text_value: str
    index: ptr_uint
    line: ptr_uint
    column: ptr_uint

enum SectionKind: int
    root = 0
    table = 1
    array_table = 2

struct Cursor:
    kind: SectionKind
    table_index: ptr_uint
    array_table_index: ptr_uint
    array_item_index: ptr_uint


function string_value(value: string.String) -> Value:
    return Value(kind = ValueKind.string, string_value = value, integer_value = 0, boolean_value = false, array_value = null, object_value = null)


function integer_value(value: long) -> Value:
    return Value(kind = ValueKind.integer, string_value = string.String.create(), integer_value = value, boolean_value = false, array_value = null, object_value = null)


function boolean_value(value: bool) -> Value:
    return Value(kind = ValueKind.boolean, string_value = string.String.create(), integer_value = 0, boolean_value = value, array_value = null, object_value = null)


function array_value(value: ptr[Array]?) -> Value:
    return Value(kind = ValueKind.array, string_value = string.String.create(), integer_value = 0, boolean_value = false, array_value = value, object_value = null)


function object_value(value: ptr[Object]?) -> Value:
    return Value(kind = ValueKind.object, string_value = string.String.create(), integer_value = 0, boolean_value = false, array_value = null, object_value = value)


public function release_value(value: Value) -> void:
    var owned = value.string_value
    owned.release()

    let nested_array = value.array_value
    if nested_array != null:
        unsafe:
            read(nested_array).release()
            heap.release(nested_array)

    let nested_object = value.object_value
    if nested_object != null:
        unsafe:
            read(nested_object).release()
            heap.release(nested_object)

    return


function value_as_string(value: Value) -> maybe.Maybe[str]:
    if value.kind == ValueKind.string:
        return maybe.Maybe[str].some(value= value.string_value.as_str())

    return maybe.Maybe[str].none


function value_as_integer(value: Value) -> maybe.Maybe[long]:
    if value.kind == ValueKind.integer:
        return maybe.Maybe[long].some(value= value.integer_value)

    return maybe.Maybe[long].none


function value_as_boolean(value: Value) -> maybe.Maybe[bool]:
    if value.kind == ValueKind.boolean:
        return maybe.Maybe[bool].some(value= value.boolean_value)

    return maybe.Maybe[bool].none


function value_as_array(value: Value) -> ptr[Array]?:
    if value.kind == ValueKind.array:
        return value.array_value

    return null


function value_as_object(value: Value) -> ptr[Object]?:
    if value.kind == ValueKind.object:
        return value.object_value

    return null


methods ParseError:
    public editable function release() -> void:
        this.message.release()
        return


methods Entry:
    public editable function release() -> void:
        this.key.release()
        release_value(this.value)
        return


methods Object:
    public static function create() -> Object:
        return Object(entries = vec.Vec[Entry].create())


    static function find_entry(current: Object, key: str) -> ptr[Entry]?:
        var index: ptr_uint = 0
        while index < current.entries.len():
            let entry = current.entries.get(index) else:
                fatal(c"toml.Object.find_entry missing entry")

            unsafe:
                if read(entry).key.as_str().equal(key):
                    return entry

            index += 1

        return null


    public function contains(key: str) -> bool:
        return Object.find_entry(this, key) != null


    public function get_string(key: str) -> maybe.Maybe[str]:
        let entry = Object.find_entry(this, key) else:
            return maybe.Maybe[str].none

        unsafe:
            return value_as_string(read(entry).value)


    public function get_integer(key: str) -> maybe.Maybe[long]:
        let entry = Object.find_entry(this, key) else:
            return maybe.Maybe[long].none

        unsafe:
            return value_as_integer(read(entry).value)


    public function get_boolean(key: str) -> maybe.Maybe[bool]:
        let entry = Object.find_entry(this, key) else:
            return maybe.Maybe[bool].none

        unsafe:
            return value_as_boolean(read(entry).value)


    public function get_array(key: str) -> ptr[Array]?:
        let entry = Object.find_entry(this, key) else:
            return null

        unsafe:
            return value_as_array(read(entry).value)


    public function get_object(key: str) -> ptr[Object]?:
        let entry = Object.find_entry(this, key) else:
            return null

        unsafe:
            return value_as_object(read(entry).value)


    public editable function release() -> void:
        var index: ptr_uint = 0
        while index < this.entries.len():
            let entry = this.entries.get(index) else:
                fatal(c"toml.Object.release missing entry")

            unsafe:
                read(entry).release()

            index += 1

        this.entries.release()
        return


methods Array:
    public static function create() -> Array:
        return Array(values = vec.Vec[Value].create())


    public function len() -> ptr_uint:
        return this.values.len()


    public function get_string(index: ptr_uint) -> maybe.Maybe[str]:
        let value_ptr = this.values.get(index) else:
            return maybe.Maybe[str].none

        unsafe:
            return value_as_string(read(value_ptr))


    public function get_integer(index: ptr_uint) -> maybe.Maybe[long]:
        let value_ptr = this.values.get(index) else:
            return maybe.Maybe[long].none

        unsafe:
            return value_as_integer(read(value_ptr))


    public function get_boolean(index: ptr_uint) -> maybe.Maybe[bool]:
        let value_ptr = this.values.get(index) else:
            return maybe.Maybe[bool].none

        unsafe:
            return value_as_boolean(read(value_ptr))


    public function get_array(index: ptr_uint) -> ptr[Array]?:
        let value_ptr = this.values.get(index) else:
            return null

        unsafe:
            return value_as_array(read(value_ptr))


    public function get_object(index: ptr_uint) -> ptr[Object]?:
        let value_ptr = this.values.get(index) else:
            return null

        unsafe:
            return value_as_object(read(value_ptr))


    public editable function release() -> void:
        var index: ptr_uint = 0
        while index < this.values.len():
            let value_ptr = this.values.get(index) else:
                fatal(c"toml.Array.release missing value")

            unsafe:
                release_value(read(value_ptr))

            index += 1

        this.values.release()
        return


methods Table:
    public function get_string(key: str) -> maybe.Maybe[str]:
        return this.entries.get_string(key)


    public function get_integer(key: str) -> maybe.Maybe[long]:
        return this.entries.get_integer(key)


    public function get_boolean(key: str) -> maybe.Maybe[bool]:
        return this.entries.get_boolean(key)


    public function get_array(key: str) -> ptr[Array]?:
        return this.entries.get_array(key)


    public function get_object(key: str) -> ptr[Object]?:
        return this.entries.get_object(key)


    public editable function release() -> void:
        this.name.release()
        this.entries.release()
        return


methods ArrayTable:
    public function len() -> ptr_uint:
        return this.tables.len()


    public function get(index: ptr_uint) -> ptr[Object]?:
        return this.tables.get(index)


    public editable function release() -> void:
        this.name.release()

        var index: ptr_uint = 0
        while index < this.tables.len():
            let table_ptr = this.tables.get(index) else:
                fatal(c"toml.ArrayTable.release missing table")

            unsafe:
                read(table_ptr).release()

            index += 1

        this.tables.release()
        return


methods Document:
    public static function create() -> Document:
        return Document(root = Object.create(), tables = vec.Vec[Table].create(), array_tables = vec.Vec[ArrayTable].create())


    public function get_string(key: str) -> maybe.Maybe[str]:
        return this.root.get_string(key)


    public function get_integer(key: str) -> maybe.Maybe[long]:
        return this.root.get_integer(key)


    public function get_boolean(key: str) -> maybe.Maybe[bool]:
        return this.root.get_boolean(key)


    public function get_array(key: str) -> ptr[Array]?:
        return this.root.get_array(key)


    public function get_object(key: str) -> ptr[Object]?:
        return this.root.get_object(key)


    public function get_table(name: str) -> ptr[Table]?:
        var index: ptr_uint = 0
        while index < this.tables.len():
            let table_ptr = this.tables.get(index) else:
                fatal(c"toml.Document.get_table missing table")

            unsafe:
                if read(table_ptr).name.as_str().equal(name):
                    return table_ptr

            index += 1

        return null


    public function get_array_table(name: str) -> ptr[ArrayTable]?:
        var index: ptr_uint = 0
        while index < this.array_tables.len():
            let table_ptr = this.array_tables.get(index) else:
                fatal(c"toml.Document.get_array_table missing table")

            unsafe:
                if read(table_ptr).name.as_str().equal(name):
                    return table_ptr

            index += 1

        return null


    public editable function release() -> void:
        this.root.release()

        var table_index: ptr_uint = 0
        while table_index < this.tables.len():
            let table_ptr = this.tables.get(table_index) else:
                fatal(c"toml.Document.release missing table")

            unsafe:
                read(table_ptr).release()

            table_index += 1

        var array_table_index: ptr_uint = 0
        while array_table_index < this.array_tables.len():
            let table_ptr = this.array_tables.get(array_table_index) else:
                fatal(c"toml.Document.release missing array table")

            unsafe:
                read(table_ptr).release()

            array_table_index += 1

        this.tables.release()
        this.array_tables.release()
        return


function parse_error(parser: ref[Parser], message: str) -> ParseError:
    return ParseError(line = parser.line, column = parser.column, message = string.String.from_str(message))


function ascii_letter(value: ubyte) -> bool:
    return (value >= ubyte<-65 and value <= ubyte<-90) or (value >= ubyte<-97 and value <= ubyte<-122)


function ascii_digit(value: ubyte) -> bool:
    return value >= ubyte<-48 and value <= ubyte<-57


function inline_space(value: ubyte) -> bool:
    return value == byte_space or value == byte_tab


function bare_key_byte(value: ubyte) -> bool:
    return ascii_letter(value) or ascii_digit(value) or value == byte_minus or value == byte_underscore


function header_name_byte(value: ubyte) -> bool:
    return bare_key_byte(value)


function parser_peek_byte(parser: ref[Parser]) -> maybe.Maybe[ubyte]:
    if parser.index >= parser.text_value.len:
        return maybe.Maybe[ubyte].none

    return maybe.Maybe[ubyte].some(value= parser.text_value.byte_at(parser.index))


function parser_peek_offset_byte(parser: ref[Parser], offset: ptr_uint) -> maybe.Maybe[ubyte]:
    if offset > heap.ptr_uint_max() - parser.index:
        return maybe.Maybe[ubyte].none

    let index = parser.index + offset
    if index >= parser.text_value.len:
        return maybe.Maybe[ubyte].none

    return maybe.Maybe[ubyte].some(value= parser.text_value.byte_at(index))


function parser_advance(parser: ref[Parser]) -> maybe.Maybe[ubyte]:
    if parser.index >= parser.text_value.len:
        return maybe.Maybe[ubyte].none

    let current = parser.text_value.byte_at(parser.index)
    if current == byte_carriage_return:
        parser.index += 1
        if parser.index < parser.text_value.len and parser.text_value.byte_at(parser.index) == byte_newline:
            parser.index += 1
        parser.line += 1
        parser.column = 1
        return maybe.Maybe[ubyte].some(value= byte_newline)

    parser.index += 1
    if current == byte_newline:
        parser.line += 1
        parser.column = 1
    else:
        parser.column += 1

    return maybe.Maybe[ubyte].some(value= current)


function parser_consume_byte(parser: ref[Parser], expected: ubyte) -> bool:
    match parser_peek_byte(parser):
        maybe.Maybe.none:
            return false
        maybe.Maybe.some as payload:
            if payload.value != expected:
                return false

    parser_advance(parser)
    return true


function parser_skip_inline_space(parser: ref[Parser]) -> void:
    while true:
        match parser_peek_byte(parser):
            maybe.Maybe.none:
                return
            maybe.Maybe.some as payload:
                if not inline_space(payload.value):
                    return
        parser_advance(parser)


function parser_skip_comment(parser: ref[Parser]) -> void:
    if not parser_consume_byte(parser, byte_hash):
        return

    while true:
        match parser_peek_byte(parser):
            maybe.Maybe.none:
                return
            maybe.Maybe.some as payload:
                if payload.value == byte_newline or payload.value == byte_carriage_return:
                    return
        parser_advance(parser)


function parser_skip_layout(parser: ref[Parser]) -> void:
    while true:
        parser_skip_inline_space(parser)

        match parser_peek_byte(parser):
            maybe.Maybe.none:
                return
            maybe.Maybe.some as payload:
                if payload.value == byte_hash:
                    parser_skip_comment(parser)
                    continue
                if payload.value == byte_newline or payload.value == byte_carriage_return:
                    parser_advance(parser)
                    continue
                return


function parser_finish_line(parser: ref[Parser]) -> status.Status[bool, ParseError]:
    parser_skip_inline_space(parser)
    parser_skip_comment(parser)

    match parser_peek_byte(parser):
        maybe.Maybe.none:
            return status.Status[bool, ParseError].ok(value= true)
        maybe.Maybe.some as payload:
            if payload.value == byte_newline or payload.value == byte_carriage_return:
                parser_advance(parser)
                return status.Status[bool, ParseError].ok(value= true)

    return status.Status[bool, ParseError].err(error= parse_error(parser, "expected end of line"))


function parser_starts_with(parser: ref[Parser], literal: str) -> bool:
    if parser.text_value.len - parser.index < literal.len:
        return false

    var offset: ptr_uint = 0
    while offset < literal.len:
        if parser.text_value.byte_at(parser.index + offset) != literal.byte_at(offset):
            return false
        offset += 1

    return true


function parser_consume_literal(parser: ref[Parser], literal: str) -> bool:
    if not parser_starts_with(parser, literal):
        return false

    var offset: ptr_uint = 0
    while offset < literal.len:
        parser_advance(parser)
        offset += 1

    return true


function parse_string(parser: ref[Parser]) -> status.Status[string.String, ParseError]:
    if not parser_consume_byte(parser, byte_quote):
        return status.Status[string.String, ParseError].err(error= parse_error(parser, "expected string"))

    var result = string.String.create()
    while true:
        match parser_peek_byte(parser):
            maybe.Maybe.none:
                result.release()
                return status.Status[string.String, ParseError].err(error= parse_error(parser, "unterminated string"))
            maybe.Maybe.some as payload:
                let current = payload.value
                if current == byte_quote:
                    parser_advance(parser)
                    return status.Status[string.String, ParseError].ok(value= result)
                if current == byte_newline or current == byte_carriage_return:
                    result.release()
                    return status.Status[string.String, ParseError].err(error= parse_error(parser, "unterminated string"))
                if current != byte_backslash:
                    result.push_byte(current)
                    parser_advance(parser)
                    continue

        parser_advance(parser)
        match parser_advance(parser):
            maybe.Maybe.none:
                result.release()
                return status.Status[string.String, ParseError].err(error= parse_error(parser, "unterminated escape"))
            maybe.Maybe.some as payload:
                let escaped = payload.value
                if escaped == ubyte<-98:
                    result.push_byte(ubyte<-8)
                else if escaped == ubyte<-102:
                    result.push_byte(ubyte<-12)
                else if escaped == ubyte<-110:
                    result.push_byte(byte_newline)
                else if escaped == ubyte<-114:
                    result.push_byte(byte_carriage_return)
                else if escaped == ubyte<-116:
                    result.push_byte(byte_tab)
                else if escaped == byte_quote:
                    result.push_byte(byte_quote)
                else if escaped == byte_backslash:
                    result.push_byte(byte_backslash)
                else:
                    result.release()
                    return status.Status[string.String, ParseError].err(error= parse_error(parser, "unsupported string escape"))


function parse_key(parser: ref[Parser]) -> status.Status[string.String, ParseError]:
    match parser_peek_byte(parser):
        maybe.Maybe.none:
            return status.Status[string.String, ParseError].err(error= parse_error(parser, "expected key"))
        maybe.Maybe.some as payload:
            if payload.value == byte_quote:
                return parse_string(parser)
            if not bare_key_byte(payload.value):
                return status.Status[string.String, ParseError].err(error= parse_error(parser, "expected key"))

    let start = parser.index
    while true:
        var advance = false
        match parser_peek_byte(parser):
            maybe.Maybe.none:
                pass
            maybe.Maybe.some as payload:
                if not bare_key_byte(payload.value):
                    pass
                else:
                    advance = true

        if not advance:
            break

        parser_advance(parser)

    let key_text = parser.text_value.slice(start, parser.index - start)
    return status.Status[string.String, ParseError].ok(value= string.String.from_str(key_text))


function parse_header_name(parser: ref[Parser]) -> status.Status[string.String, ParseError]:
    match parser_peek_byte(parser):
        maybe.Maybe.none:
            return status.Status[string.String, ParseError].err(error= parse_error(parser, "expected header name"))
        maybe.Maybe.some as payload:
            if payload.value == byte_quote:
                return parse_string(parser)
            if not header_name_byte(payload.value):
                return status.Status[string.String, ParseError].err(error= parse_error(parser, "expected header name"))

    let start = parser.index
    while true:
        var advance = false
        match parser_peek_byte(parser):
            maybe.Maybe.none:
                pass
            maybe.Maybe.some as payload:
                if not header_name_byte(payload.value):
                    pass
                else:
                    advance = true

        if not advance:
            break

        parser_advance(parser)

    let name_text = parser.text_value.slice(start, parser.index - start)
    return status.Status[string.String, ParseError].ok(value= string.String.from_str(name_text))


function parse_integer(parser: ref[Parser]) -> status.Status[long, ParseError]:
    var negative = false
    match parser_peek_byte(parser):
        maybe.Maybe.none:
            return status.Status[long, ParseError].err(error= parse_error(parser, "expected integer"))
        maybe.Maybe.some as payload:
            if payload.value == byte_minus:
                negative = true
                parser_advance(parser)
            else if payload.value == byte_plus:
                parser_advance(parser)

    match parser_peek_byte(parser):
        maybe.Maybe.none:
            return status.Status[long, ParseError].err(error= parse_error(parser, "expected integer"))
        maybe.Maybe.some as payload:
            if not ascii_digit(payload.value):
                return status.Status[long, ParseError].err(error= parse_error(parser, "expected integer"))

    var result: long = 0
    while true:
        var advance = false
        match parser_peek_byte(parser):
            maybe.Maybe.none:
                pass
            maybe.Maybe.some as payload:
                if not ascii_digit(payload.value):
                    pass
                else:
                    result = result * long<-10 + long<-(payload.value - ubyte<-48)
                    advance = true

        if not advance:
            break

        parser_advance(parser)

    if negative:
        result = -result

    return status.Status[long, ParseError].ok(value= result)


function parse_boolean(parser: ref[Parser]) -> status.Status[bool, ParseError]:
    if parser_consume_literal(parser, "true"):
        return status.Status[bool, ParseError].ok(value= true)
    if parser_consume_literal(parser, "false"):
        return status.Status[bool, ParseError].ok(value= false)

    return status.Status[bool, ParseError].err(error= parse_error(parser, "expected boolean"))


function parse_array(parser: ref[Parser]) -> status.Status[ptr[Array]?, ParseError]:
    if not parser_consume_byte(parser, byte_left_bracket):
        return status.Status[ptr[Array]?, ParseError].err(error= parse_error(parser, "expected array"))

    let array_ptr = heap.must_alloc[Array](1)
    unsafe:
        read(array_ptr) = Array.create()

    parser_skip_inline_space(parser)
    if parser_consume_byte(parser, byte_right_bracket):
        return status.Status[ptr[Array]?, ParseError].ok(value= array_ptr)

    while true:
        parser_skip_inline_space(parser)
        let value_result = parse_value(parser)
        match value_result:
            status.Status.err as payload:
                unsafe:
                    read(array_ptr).release()
                heap.release(array_ptr)
                return status.Status[ptr[Array]?, ParseError].err(error= payload.error)
            status.Status.ok as payload:
                unsafe:
                    read(array_ptr).values.push(payload.value)

        parser_skip_inline_space(parser)
        if parser_consume_byte(parser, byte_comma):
            continue
        if parser_consume_byte(parser, byte_right_bracket):
            return status.Status[ptr[Array]?, ParseError].ok(value= array_ptr)

        unsafe:
            read(array_ptr).release()
        heap.release(array_ptr)
        return status.Status[ptr[Array]?, ParseError].err(error= parse_error(parser, "expected ',' or ']'"))


function parse_inline_object(parser: ref[Parser]) -> status.Status[ptr[Object]?, ParseError]:
    if not parser_consume_byte(parser, byte_left_brace):
        return status.Status[ptr[Object]?, ParseError].err(error= parse_error(parser, "expected inline table"))

    let object_ptr = heap.must_alloc[Object](1)
    unsafe:
        read(object_ptr) = Object.create()

    parser_skip_inline_space(parser)
    if parser_consume_byte(parser, byte_right_brace):
        return status.Status[ptr[Object]?, ParseError].ok(value= object_ptr)

    while true:
        parser_skip_inline_space(parser)
        let key_result = parse_key(parser)
        match key_result:
            status.Status.err as payload:
                unsafe:
                    read(object_ptr).release()
                heap.release(object_ptr)
                return status.Status[ptr[Object]?, ParseError].err(error= payload.error)
            status.Status.ok as key_payload:
                var key = key_payload.value
                parser_skip_inline_space(parser)
                if not parser_consume_byte(parser, byte_equal):
                    key.release()
                    unsafe:
                        read(object_ptr).release()
                    heap.release(object_ptr)
                    return status.Status[ptr[Object]?, ParseError].err(error= parse_error(parser, "expected '='"))

                parser_skip_inline_space(parser)
                let value_result = parse_value(parser)
                match value_result:
                    status.Status.err as payload:
                        key.release()
                        unsafe:
                            read(object_ptr).release()
                        heap.release(object_ptr)
                        return status.Status[ptr[Object]?, ParseError].err(error= payload.error)
                    status.Status.ok as value_payload:
                        let key_text = key.as_str()
                        if unsafe: read(object_ptr).contains(key_text):
                            key.release()
                            release_value(value_payload.value)
                            unsafe:
                                read(object_ptr).release()
                            heap.release(object_ptr)
                            return status.Status[ptr[Object]?, ParseError].err(error= parse_error(parser, "duplicate key"))

                        unsafe:
                            read(object_ptr).entries.push(Entry(key = key, value = value_payload.value))

                parser_skip_inline_space(parser)
                if parser_consume_byte(parser, byte_comma):
                    continue
                if parser_consume_byte(parser, byte_right_brace):
                    return status.Status[ptr[Object]?, ParseError].ok(value= object_ptr)

                unsafe:
                    read(object_ptr).release()
                heap.release(object_ptr)
                return status.Status[ptr[Object]?, ParseError].err(error= parse_error(parser, "expected ',' or '}'"))


function parse_value(parser: ref[Parser]) -> status.Status[Value, ParseError]:
    match parser_peek_byte(parser):
        maybe.Maybe.none:
            return status.Status[Value, ParseError].err(error= parse_error(parser, "expected value"))
        maybe.Maybe.some as payload:
            let current = payload.value
            if current == byte_quote:
                let string_result = parse_string(parser)
                match string_result:
                    status.Status.err as error_payload:
                        return status.Status[Value, ParseError].err(error= error_payload.error)
                    status.Status.ok as string_payload:
                        return status.Status[Value, ParseError].ok(value= string_value(string_payload.value))

            if current == byte_left_bracket:
                let array_result = parse_array(parser)
                match array_result:
                    status.Status.err as error_payload:
                        return status.Status[Value, ParseError].err(error= error_payload.error)
                    status.Status.ok as array_payload:
                        return status.Status[Value, ParseError].ok(value= array_value(array_payload.value))

            if current == byte_left_brace:
                let object_result = parse_inline_object(parser)
                match object_result:
                    status.Status.err as error_payload:
                        return status.Status[Value, ParseError].err(error= error_payload.error)
                    status.Status.ok as object_payload:
                        return status.Status[Value, ParseError].ok(value= object_value(object_payload.value))

            if current == ubyte<-116 or current == ubyte<-102:
                let boolean_result = parse_boolean(parser)
                match boolean_result:
                    status.Status.err as error_payload:
                        return status.Status[Value, ParseError].err(error= error_payload.error)
                    status.Status.ok as boolean_payload:
                        return status.Status[Value, ParseError].ok(value= boolean_value(boolean_payload.value))

            if ascii_digit(current) or current == byte_minus or current == byte_plus:
                let integer_result = parse_integer(parser)
                match integer_result:
                    status.Status.err as error_payload:
                        return status.Status[Value, ParseError].err(error= error_payload.error)
                    status.Status.ok as integer_payload:
                        return status.Status[Value, ParseError].ok(value= integer_value(integer_payload.value))

    return status.Status[Value, ParseError].err(error= parse_error(parser, "unsupported value"))


function document_find_table_index(document: ref[Document], name: str) -> maybe.Maybe[ptr_uint]:
    var index: ptr_uint = 0
    while index < document.tables.len():
        let table_ptr = document.tables.get(index) else:
            fatal(c"toml.document_find_table_index missing table")

        unsafe:
            if read(table_ptr).name.as_str().equal(name):
                return maybe.Maybe[ptr_uint].some(value= index)

        index += 1

    return maybe.Maybe[ptr_uint].none


function document_find_array_table_index(document: ref[Document], name: str) -> maybe.Maybe[ptr_uint]:
    var index: ptr_uint = 0
    while index < document.array_tables.len():
        let table_ptr = document.array_tables.get(index) else:
            fatal(c"toml.document_find_array_table_index missing table")

        unsafe:
            if read(table_ptr).name.as_str().equal(name):
                return maybe.Maybe[ptr_uint].some(value= index)

        index += 1

    return maybe.Maybe[ptr_uint].none


function current_object_contains(document: ref[Document], cursor: Cursor, key: str) -> bool:
    match cursor.kind:
        SectionKind.root:
            return document.root.contains(key)
        SectionKind.table:
            let table_ptr = document.tables.get(cursor.table_index) else:
                fatal(c"toml.current_object_contains missing table")

            unsafe:
                return read(table_ptr).entries.contains(key)
        SectionKind.array_table:
            let array_table_ptr = document.array_tables.get(cursor.array_table_index) else:
                fatal(c"toml.current_object_contains missing array table")

            unsafe:
                let object_ptr = read(array_table_ptr).tables.get(cursor.array_item_index) else:
                    fatal(c"toml.current_object_contains missing array table item")

                return read(object_ptr).contains(key)


function current_object_push(document: ref[Document], cursor: Cursor, entry: Entry) -> void:
    match cursor.kind:
        SectionKind.root:
            document.root.entries.push(entry)
            return
        SectionKind.table:
            let table_ptr = document.tables.get(cursor.table_index) else:
                fatal(c"toml.current_object_push missing table")

            unsafe:
                read(table_ptr).entries.entries.push(entry)
            return
        SectionKind.array_table:
            let array_table_ptr = document.array_tables.get(cursor.array_table_index) else:
                fatal(c"toml.current_object_push missing array table")

            unsafe:
                let object_ptr = read(array_table_ptr).tables.get(cursor.array_item_index) else:
                    fatal(c"toml.current_object_push missing array table item")

                read(object_ptr).entries.push(entry)
            return


function parse_assignment(document: ref[Document], cursor: Cursor, parser: ref[Parser]) -> status.Status[bool, ParseError]:
    let key_result = parse_key(parser)
    match key_result:
        status.Status.err as payload:
            return status.Status[bool, ParseError].err(error= payload.error)
        status.Status.ok as key_payload:
            var key = key_payload.value
            parser_skip_inline_space(parser)
            if not parser_consume_byte(parser, byte_equal):
                key.release()
                return status.Status[bool, ParseError].err(error= parse_error(parser, "expected '='"))

            parser_skip_inline_space(parser)
            let value_result = parse_value(parser)
            match value_result:
                status.Status.err as payload:
                    key.release()
                    return status.Status[bool, ParseError].err(error= payload.error)
                status.Status.ok as value_payload:
                    let key_text = key.as_str()
                    if current_object_contains(document, cursor, key_text):
                        key.release()
                        release_value(value_payload.value)
                        return status.Status[bool, ParseError].err(error= parse_error(parser, "duplicate key"))

                    current_object_push(document, cursor, Entry(key = key, value = value_payload.value))
                    return status.Status[bool, ParseError].ok(value= true)


function parse_header(document: ref[Document], cursor: ref[Cursor], parser: ref[Parser]) -> status.Status[bool, ParseError]:
    if not parser_consume_byte(parser, byte_left_bracket):
        return status.Status[bool, ParseError].err(error= parse_error(parser, "expected table header"))

    let array_table = parser_consume_byte(parser, byte_left_bracket)
    parser_skip_inline_space(parser)

    let name_result = parse_header_name(parser)
    match name_result:
        status.Status.err as payload:
            return status.Status[bool, ParseError].err(error= payload.error)
        status.Status.ok as name_payload:
            var name = name_payload.value
            parser_skip_inline_space(parser)

            if array_table:
                if not parser_consume_byte(parser, byte_right_bracket) or not parser_consume_byte(parser, byte_right_bracket):
                    name.release()
                    return status.Status[bool, ParseError].err(error= parse_error(parser, "expected ']]'"))

                if maybe.is_some(document_find_table_index(document, name.as_str())):
                    name.release()
                    return status.Status[bool, ParseError].err(error= parse_error(parser, "table name already used"))

                match document_find_array_table_index(document, name.as_str()):
                    maybe.Maybe.some as payload:
                        let index = payload.value
                        name.release()
                        let array_table_ptr = document.array_tables.get(index) else:
                            fatal(c"toml.parse_header missing array table")

                        unsafe:
                            read(array_table_ptr).tables.push(Object.create())
                            cursor.kind = SectionKind.array_table
                            cursor.array_table_index = index
                            cursor.array_item_index = read(array_table_ptr).tables.len() - 1
                        return status.Status[bool, ParseError].ok(value= true)
                    maybe.Maybe.none:
                        var next = ArrayTable(name = name, tables = vec.Vec[Object].create())
                        next.tables.push(Object.create())
                        document.array_tables.push(next)
                        cursor.kind = SectionKind.array_table
                        cursor.array_table_index = document.array_tables.len() - 1
                        cursor.array_item_index = 0
                        return status.Status[bool, ParseError].ok(value= true)

            if not parser_consume_byte(parser, byte_right_bracket):
                name.release()
                return status.Status[bool, ParseError].err(error= parse_error(parser, "expected ']'"))

            if maybe.is_some(document_find_table_index(document, name.as_str())) or maybe.is_some(document_find_array_table_index(document, name.as_str())):
                name.release()
                return status.Status[bool, ParseError].err(error= parse_error(parser, "duplicate table"))

            document.tables.push(Table(name = name, entries = Object.create()))
            cursor.kind = SectionKind.table
            cursor.table_index = document.tables.len() - 1
            return status.Status[bool, ParseError].ok(value= true)


public function parse(text_value: str) -> status.Status[Document, ParseError]:
    var parser = Parser(text_value = text_value, index = 0, line = 1, column = 1)
    var document = Document.create()
    var cursor = Cursor(kind = SectionKind.root, table_index = 0, array_table_index = 0, array_item_index = 0)

    while true:
        parser_skip_layout(ref_of(parser))

        if maybe.is_none(parser_peek_byte(ref_of(parser))):
            return status.Status[Document, ParseError].ok(value= document)

        var statement_result = status.Status[bool, ParseError].ok(value= true)
        match parser_peek_byte(ref_of(parser)):
            maybe.Maybe.none:
                pass
            maybe.Maybe.some as payload:
                if payload.value == byte_left_bracket:
                    statement_result = parse_header(ref_of(document), ref_of(cursor), ref_of(parser))
                else:
                    statement_result = parse_assignment(ref_of(document), cursor, ref_of(parser))

        match statement_result:
            status.Status.err as payload:
                document.release()
                return status.Status[Document, ParseError].err(error= payload.error)
            status.Status.ok:
                let line_result = parser_finish_line(ref_of(parser))
                match line_result:
                    status.Status.err as payload:
                        document.release()
                        return status.Status[Document, ParseError].err(error= payload.error)
                    status.Status.ok:
                        pass


function append_quoted_string(output: ref[string.String], text_value: str) -> void:
    output.push_byte(byte_quote)

    var index: ptr_uint = 0
    while index < text_value.len:
        let value = text_value.byte_at(index)
        if value == byte_backslash:
            output.append("\\\\")
        else if value == byte_quote:
            output.append("\\\"")
        else if value == byte_newline:
            output.append("\\n")
        else if value == byte_carriage_return:
            output.append("\\r")
        else if value == byte_tab:
            output.append("\\t")
        else if value == ubyte<-8:
            output.append("\\b")
        else if value == ubyte<-12:
            output.append("\\f")
        else:
            output.push_byte(value)
        index += 1

    output.push_byte(byte_quote)
    return


function bare_header_name(text_value: str) -> bool:
    if text_value.len == 0:
        return false

    var index: ptr_uint = 0
    while index < text_value.len:
        if not header_name_byte(text_value.byte_at(index)):
            return false
        index += 1

    return true


function append_header_name(output: ref[string.String], name: str) -> void:
    if bare_header_name(name):
        output.append(name)
    else:
        append_quoted_string(output, name)
    return


function append_entry_key(output: ref[string.String], key: str) -> void:
    append_quoted_string(output, key)
    return


function append_value(output: ref[string.String], value: Value) -> void:
    if value.kind == ValueKind.string:
        append_quoted_string(output, value.string_value.as_str())
        return

    if value.kind == ValueKind.integer:
        fmt.append_long(output, value.integer_value)
        return

    if value.kind == ValueKind.boolean:
        fmt.append_bool(output, value.boolean_value)
        return

    if value.kind == ValueKind.array:
        output.push_byte(byte_left_bracket)
        let nested_array = value.array_value
        if nested_array != null:
            unsafe:
                let values = read(nested_array)
                var index: ptr_uint = 0
                while index < values.len():
                    if index != 0:
                        output.append(", ")

                    let item = values.values.get(index) else:
                        fatal(c"toml.append_value missing array item")

                    append_value(output, unsafe: read(item))
                    index += 1

        output.push_byte(byte_right_bracket)
        return

    output.push_byte(byte_left_brace)
    let nested_object = value.object_value
    if nested_object != null:
        unsafe:
            let object_entries = read(nested_object)
            var index: ptr_uint = 0
            while index < object_entries.entries.len():
                if index != 0:
                    output.append(", ")

                let entry = object_entries.entries.get(index) else:
                    fatal(c"toml.append_value missing object entry")

                let current = unsafe: read(entry)
                append_entry_key(output, current.key.as_str())
                output.append(" = ")
                append_value(output, current.value)
                index += 1

    output.push_byte(byte_right_brace)
    return


function append_table_entries(output: ref[string.String], object_entries: Object) -> void:
    var index: ptr_uint = 0
    while index < object_entries.entries.len():
        let entry = object_entries.entries.get(index) else:
            fatal(c"toml.append_table_entries missing entry")

        let current = unsafe: read(entry)
        append_entry_key(output, current.key.as_str())
        output.append(" = ")
        append_value(output, current.value)
        output.append("\n")
        index += 1

    return


public function render(document: Document) -> string.String:
    var output = string.String.create()

    append_table_entries(ref_of(output), document.root)

    let has_root = document.root.entries.len() > 0
    let has_sections = document.tables.len() > 0 or document.array_tables.len() > 0
    if has_root and has_sections:
        output.append("\n")

    var table_index: ptr_uint = 0
    while table_index < document.tables.len():
        if table_index != 0:
            output.append("\n")

        let table_ptr = document.tables.get(table_index) else:
            fatal(c"toml.render missing table")

        let current = unsafe: read(table_ptr)
        output.push_byte(byte_left_bracket)
        append_header_name(ref_of(output), current.name.as_str())
        output.push_byte(byte_right_bracket)
        output.append("\n")
        append_table_entries(ref_of(output), current.entries)
        table_index += 1

    var array_table_index: ptr_uint = 0
    while array_table_index < document.array_tables.len():
        let array_table_ptr = document.array_tables.get(array_table_index) else:
            fatal(c"toml.render missing array table")

        let current = unsafe: read(array_table_ptr)
        var object_index: ptr_uint = 0
        while object_index < current.tables.len():
            if output.len() > 0 and not output.as_str().ends_with("\n\n"):
                output.append("\n")

            output.push_byte(byte_left_bracket)
            output.push_byte(byte_left_bracket)
            append_header_name(ref_of(output), current.name.as_str())
            output.push_byte(byte_right_bracket)
            output.push_byte(byte_right_bracket)
            output.append("\n")

            let object_ptr = current.tables.get(object_index) else:
                fatal(c"toml.render missing array table item")

            append_table_entries(ref_of(output), unsafe: read(object_ptr))
            object_index += 1
        array_table_index += 1

    return output
