import std.cjson as cjson
import std.c.cjson as raw
import std.mem.arena as arena
import std.str as text
import std.string as string
import std.vec as vec
import std.mem.heap as heap


public struct Error:
    message: string.String


public enum ValueKind: int
    null_ = 0
    boolean = 1
    number = 2
    string_ = 3
    array_ = 4
    object_ = 5


public struct Value:
    kind: ValueKind
    boolean_value: bool
    number_value: double
    string_value: string.String
    array_value: ptr[Array]?
    object_value: ptr[Object]?


public struct Entry:
    key: string.String
    value: Value


public struct Object:
    entries: vec.Vec[Entry]


public struct Array:
    values: vec.Vec[Value]


function error_message(message: str) -> Error:
    return Error(message = string.String.from_str(message))


public function null_value() -> Value:
    return Value(kind = ValueKind.null_, boolean_value = false, number_value = 0.0, string_value = string.String.create(), array_value = null, object_value = null)


public function boolean_value(value: bool) -> Value:
    return Value(kind = ValueKind.boolean, boolean_value = value, number_value = 0.0, string_value = string.String.create(), array_value = null, object_value = null)


public function number_value(value: double) -> Value:
    return Value(kind = ValueKind.number, boolean_value = false, number_value = value, string_value = string.String.create(), array_value = null, object_value = null)


public function string_value(value: string.String) -> Value:
    return Value(kind = ValueKind.string_, boolean_value = false, number_value = 0.0, string_value = value, array_value = null, object_value = null)


public function string_from_str(value: str) -> Value:
    return string_value(string.String.from_str(value))


public function array_value(value: ptr[Array]?) -> Value:
    return Value(kind = ValueKind.array_, boolean_value = false, number_value = 0.0, string_value = string.String.create(), array_value = value, object_value = null)


public function object_value(value: ptr[Object]?) -> Value:
    return Value(kind = ValueKind.object_, boolean_value = false, number_value = 0.0, string_value = string.String.create(), array_value = null, object_value = value)


public function create_array_value() -> Value:
    let array_ptr = heap.must_alloc[Array](1)
    unsafe:
        read(array_ptr) = Array.create()
    return array_value(array_ptr)


public function create_object_value() -> Value:
    let object_ptr = heap.must_alloc[Object](1)
    unsafe:
        read(object_ptr) = Object.create()
    return object_value(object_ptr)


public function release_value(value: Value) -> void:
    var owned_string = value.string_value
    owned_string.release()

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


function value_as_boolean(value: Value) -> Option[bool]:
    if value.kind == ValueKind.boolean:
        return Option[bool].some(value = value.boolean_value)

    return Option[bool].none


function value_as_number(value: Value) -> Option[double]:
    if value.kind == ValueKind.number:
        return Option[double].some(value = value.number_value)

    return Option[double].none


function value_as_string(value: Value) -> Option[str]:
    if value.kind == ValueKind.string_:
        return Option[str].some(value = value.string_value.as_str())

    return Option[str].none


function value_as_array(value: Value) -> ptr[Array]?:
    if value.kind == ValueKind.array_:
        return value.array_value

    return null


function value_as_object(value: Value) -> ptr[Object]?:
    if value.kind == ValueKind.object_:
        return value.object_value

    return null


function convert_raw_array(item: ptr[cjson.JSON]) -> Result[Value, Error]:
    let array_ptr = heap.must_alloc[Array](1)
    unsafe:
        read(array_ptr) = Array.create()

    let count = cjson.get_array_size(item)
    if count < 0:
        unsafe:
            read(array_ptr).release()
        heap.release(array_ptr)
        return Result[Value, Error].failure(error = error_message("json array size failed"))

    var index: int = 0
    while index < count:
        let child = cjson.get_array_item(item, index) else:
            unsafe:
                read(array_ptr).release()
            heap.release(array_ptr)
            return Result[Value, Error].failure(error = error_message("json array item missing"))

        match convert_raw_value(child):
            Result.failure as payload:
                unsafe:
                    read(array_ptr).release()
                heap.release(array_ptr)
                return Result[Value, Error].failure(error = payload.error)
            Result.success as payload:
                unsafe:
                    read(array_ptr).values.push(payload.value)

        index += 1

    return Result[Value, Error].success(value = array_value(array_ptr))


function convert_raw_object(item: ptr[cjson.JSON]) -> Result[Value, Error]:
    let object_ptr = heap.must_alloc[Object](1)
    unsafe:
        read(object_ptr) = Object.create()

    var child = unsafe: ptr[cjson.JSON]?<-read(ptr[raw.cJSON]<-item).child
    while child != null:
        let current = unsafe: ptr[cjson.JSON]<-child
        let key_ptr = unsafe: ptr[char]?<-read(ptr[raw.cJSON]<-current).string else:
            unsafe:
                read(object_ptr).release()
            heap.release(object_ptr)
            return Result[Value, Error].failure(error = error_message("json object key missing"))

        match convert_raw_value(current):
            Result.failure as payload:
                unsafe:
                    read(object_ptr).release()
                heap.release(object_ptr)
                return Result[Value, Error].failure(error = payload.error)
            Result.success as payload:
                unsafe:
                    read(object_ptr).entries.push(Entry(key = string.String.from_str(text.chars_as_str(key_ptr)), value = payload.value))

        child = unsafe: ptr[cjson.JSON]?<-read(ptr[raw.cJSON]<-current).next

    return Result[Value, Error].success(value = object_value(object_ptr))


function convert_raw_value(item: ptr[cjson.JSON]?) -> Result[Value, Error]:
    let current = item else:
        return Result[Value, Error].failure(error = error_message("json value missing"))

    if cjson.is_null(current) != 0:
        return Result[Value, Error].success(value = null_value())

    if cjson.is_true(current) != 0:
        return Result[Value, Error].success(value = boolean_value(true))

    if cjson.is_false(current) != 0:
        return Result[Value, Error].success(value = boolean_value(false))

    if cjson.is_number(current) != 0:
        return Result[Value, Error].success(value = number_value(cjson.get_number_value(current)))

    if cjson.is_string(current) != 0:
        let raw_text = cjson.get_string_value(current) else:
            return Result[Value, Error].failure(error = error_message("json string value missing"))
        return Result[Value, Error].success(value = string_value(string.String.from_str(text.cstr_as_str(raw_text))))

    if cjson.is_array(current) != 0:
        return convert_raw_array(current)

    if cjson.is_object(current) != 0:
        return convert_raw_object(current)

    return Result[Value, Error].failure(error = error_message("unsupported json value"))


function build_raw_array(array_ptr: ptr[Array]?) -> Result[ptr[cjson.JSON], Error]:
    let current = array_ptr else:
        return Result[ptr[cjson.JSON], Error].failure(error = error_message("json array value missing"))

    let array_item = cjson.create_array() else:
        return Result[ptr[cjson.JSON], Error].failure(error = error_message("json create array failed"))

    unsafe:
        var index: ptr_uint = 0
        while index < read(current).values.len():
            let value_ptr = read(current).values.get(index) else:
                cjson.delete(array_item)
                return Result[ptr[cjson.JSON], Error].failure(error = error_message("json array value missing"))

            match build_raw_value(read(value_ptr)):
                Result.failure as payload:
                    cjson.delete(array_item)
                    return Result[ptr[cjson.JSON], Error].failure(error = payload.error)
                Result.success as payload:
                    if cjson.add_item_to_array(array_item, payload.value) == 0:
                        cjson.delete(payload.value)
                        cjson.delete(array_item)
                        return Result[ptr[cjson.JSON], Error].failure(error = error_message("json add array item failed"))

            index += 1

    return Result[ptr[cjson.JSON], Error].success(value = array_item)


function build_raw_object(object_ptr: ptr[Object]?) -> Result[ptr[cjson.JSON], Error]:
    let current = object_ptr else:
        return Result[ptr[cjson.JSON], Error].failure(error = error_message("json object value missing"))

    let object_item = cjson.create_object() else:
        return Result[ptr[cjson.JSON], Error].failure(error = error_message("json create object failed"))

    unsafe:
        var index: ptr_uint = 0
        while index < read(current).entries.len():
            let entry_ptr = read(current).entries.get(index) else:
                cjson.delete(object_item)
                return Result[ptr[cjson.JSON], Error].failure(error = error_message("json object entry missing"))

            let entry = read(entry_ptr)
            match build_raw_value(entry.value):
                Result.failure as payload:
                    cjson.delete(object_item)
                    return Result[ptr[cjson.JSON], Error].failure(error = payload.error)
                Result.success as payload:
                    if cjson.add_item_to_object(object_item, entry.key.as_str(), payload.value) == 0:
                        cjson.delete(payload.value)
                        cjson.delete(object_item)
                        return Result[ptr[cjson.JSON], Error].failure(error = error_message("json add object entry failed"))

            index += 1

    return Result[ptr[cjson.JSON], Error].success(value = object_item)


function build_raw_value(value: Value) -> Result[ptr[cjson.JSON], Error]:
    if value.kind == ValueKind.null_:
        let item = cjson.create_null() else:
            return Result[ptr[cjson.JSON], Error].failure(error = error_message("json create null failed"))
        return Result[ptr[cjson.JSON], Error].success(value = item)

    if value.kind == ValueKind.boolean:
        if value.boolean_value:
            let item = cjson.create_true() else:
                return Result[ptr[cjson.JSON], Error].failure(error = error_message("json create boolean failed"))
            return Result[ptr[cjson.JSON], Error].success(value = item)

        let item = cjson.create_false() else:
            return Result[ptr[cjson.JSON], Error].failure(error = error_message("json create boolean failed"))
        return Result[ptr[cjson.JSON], Error].success(value = item)

    if value.kind == ValueKind.number:
        let item = cjson.create_number(value.number_value) else:
            return Result[ptr[cjson.JSON], Error].failure(error = error_message("json create number failed"))
        return Result[ptr[cjson.JSON], Error].success(value = item)

    if value.kind == ValueKind.string_:
        let item = cjson.create_string(value.string_value.as_str()) else:
            return Result[ptr[cjson.JSON], Error].failure(error = error_message("json create string failed"))
        return Result[ptr[cjson.JSON], Error].success(value = item)

    if value.kind == ValueKind.array_:
        return build_raw_array(value.array_value)

    if value.kind == ValueKind.object_:
        return build_raw_object(value.object_value)

    return Result[ptr[cjson.JSON], Error].failure(error = error_message("unsupported json value"))


function render_with_mode(value: Value, pretty: bool) -> Result[string.String, Error]:
    match build_raw_value(value):
        Result.failure as payload:
            return Result[string.String, Error].failure(error = payload.error)
        Result.success as payload:
            let raw_value = payload.value
            defer cjson.delete(raw_value)

            if pretty:
                let rendered_ptr = cjson.print(raw_value) else:
                    return Result[string.String, Error].failure(error = error_message("json print failed"))
                defer raw.cJSON_free(unsafe: ptr[void]<-rendered_ptr)
                return Result[string.String, Error].success(value = string.String.from_str(text.chars_as_str(rendered_ptr)))

            let rendered_ptr = cjson.print_unformatted(raw_value) else:
                return Result[string.String, Error].failure(error = error_message("json print failed"))
            defer raw.cJSON_free(unsafe: ptr[void]<-rendered_ptr)
            return Result[string.String, Error].success(value = string.String.from_str(text.chars_as_str(rendered_ptr)))


public function parse(text_value: str) -> Result[Value, Error]:
    var storage = arena.create(text_value.len + 1)
    defer storage.release()

    let c_text = storage.to_cstr(text_value)
    let raw_value = raw.cJSON_Parse(c_text) else:
        let error_ptr = raw.cJSON_GetErrorPtr()
        if error_ptr == null:
            return Result[Value, Error].failure(error = error_message("json parse failed"))
        let error_text = text.cstr_as_str(unsafe: cstr<-error_ptr)
        if error_text.len == 0:
            return Result[Value, Error].failure(error = error_message("json parse failed"))
        return Result[Value, Error].failure(error = Error(message = string.String.from_str(error_text)))

    defer raw.cJSON_Delete(raw_value)
    return convert_raw_value(unsafe: ptr[cjson.JSON]?<-raw_value)


public function render(value: Value) -> Result[string.String, Error]:
    return render_with_mode(value, false)


public function render_pretty(value: Value) -> Result[string.String, Error]:
    return render_with_mode(value, true)


extending Error:
    public mutable function release() -> void:
        this.message.release()


extending Value:
    public function is_null() -> bool:
        return this.kind == ValueKind.null_


    public function as_boolean() -> Option[bool]:
        return value_as_boolean(this)


    public function as_number() -> Option[double]:
        return value_as_number(this)


    public function as_string() -> Option[str]:
        return value_as_string(this)


    public function as_array() -> ptr[Array]?:
        return value_as_array(this)


    public function as_object() -> ptr[Object]?:
        return value_as_object(this)


extending Entry:
    public mutable function release() -> void:
        this.key.release()
        release_value(this.value)


extending Object:
    public static function create() -> Object:
        return Object(entries = vec.Vec[Entry].create())


    static function find_entry(current: Object, key: str) -> ptr[Entry]?:
        return current.entries.find(proc(entry: ptr[Entry]) -> bool: unsafe: read(entry).key.as_str().equal(key))


    public function len() -> ptr_uint:
        return this.entries.len()


    public function contains(key: str) -> bool:
        return Object.find_entry(this, key) != null


    public function get(key: str) -> ptr[Value]?:
        let entry = Object.find_entry(this, key) else:
            return null

        unsafe:
            return ptr_of(read(entry).value)


    public function get_boolean(key: str) -> Option[bool]:
        let entry = Object.find_entry(this, key) else:
            return Option[bool].none

        unsafe:
            return value_as_boolean(read(entry).value)


    public function get_number(key: str) -> Option[double]:
        let entry = Object.find_entry(this, key) else:
            return Option[double].none

        unsafe:
            return value_as_number(read(entry).value)


    public function get_string(key: str) -> Option[str]:
        let entry = Object.find_entry(this, key) else:
            return Option[str].none

        unsafe:
            return value_as_string(read(entry).value)


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


    public mutable function set(key: str, value: Value) -> void:
        let entry = Object.find_entry(this, key)
        if entry != null:
            unsafe:
                release_value(read(entry).value)
                read(entry).value = value
            return

        this.entries.push(Entry(key = string.String.from_str(key), value = value))


    public mutable function release() -> void:
        var index: ptr_uint = 0
        while index < this.entries.len():
            let entry = this.entries.get(index) else:
                fatal(c"json.Object.release missing entry")

            unsafe:
                read(entry).release()

            index += 1

        this.entries.release()


extending Array:
    public static function create() -> Array:
        return Array(values = vec.Vec[Value].create())


    public function len() -> ptr_uint:
        return this.values.len()


    public function get(index: ptr_uint) -> ptr[Value]?:
        return this.values.get(index)


    public function get_boolean(index: ptr_uint) -> Option[bool]:
        let value_ptr = this.get(index) else:
            return Option[bool].none

        unsafe:
            return value_as_boolean(read(value_ptr))


    public function get_number(index: ptr_uint) -> Option[double]:
        let value_ptr = this.get(index) else:
            return Option[double].none

        unsafe:
            return value_as_number(read(value_ptr))


    public function get_string(index: ptr_uint) -> Option[str]:
        let value_ptr = this.get(index) else:
            return Option[str].none

        unsafe:
            return value_as_string(read(value_ptr))


    public function get_array(index: ptr_uint) -> ptr[Array]?:
        let value_ptr = this.get(index) else:
            return null

        unsafe:
            return value_as_array(read(value_ptr))


    public function get_object(index: ptr_uint) -> ptr[Object]?:
        let value_ptr = this.get(index) else:
            return null

        unsafe:
            return value_as_object(read(value_ptr))


    public mutable function push(value: Value) -> void:
        this.values.push(value)


    public mutable function release() -> void:
        var index: ptr_uint = 0
        while index < this.values.len():
            let value_ptr = this.values.get(index) else:
                fatal(c"json.Array.release missing value")

            unsafe:
                release_value(read(value_ptr))

            index += 1

        this.values.release()
