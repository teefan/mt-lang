import std.vec as vec

public enum SymbolKind: ubyte
    type_symbol = 1
    function_symbol = 2
    const_symbol = 3
    var_symbol = 4
    module_symbol = 5
    method_symbol = 6
    field_symbol = 7

public struct Symbol:
    kind: SymbolKind
    name: str
    type_text: str
    is_public: bool
    line: ptr_uint
    column: ptr_uint


public struct SemError:
    message: str
    line: ptr_uint
    column: ptr_uint


public struct SemaContext:
    symbols: vec.Vec[Symbol]
    errors: vec.Vec[SemError]
    builtin_types: vec.Vec[str]
    module_name: str


extending SemaContext:
    public static function create(module_name: str) -> SemaContext:
        var ctx = SemaContext(
            symbols = vec.Vec[Symbol].create(),
            errors = vec.Vec[SemError].create(),
            builtin_types = vec.Vec[str].create(),
            module_name = module_name,
        )
        ctx.register_builtin_types()
        return ctx


    editable function register_builtin_types() -> void:
        var names = vec.Vec[str].create()
        names.push("bool")
        names.push("byte")
        names.push("short")
        names.push("int")
        names.push("long")
        names.push("ubyte")
        names.push("ushort")
        names.push("uint")
        names.push("ulong")
        names.push("ptr_int")
        names.push("ptr_uint")
        names.push("float")
        names.push("double")
        names.push("char")
        names.push("void")
        names.push("str")
        names.push("cstr")
        names.push("vec2")
        names.push("vec3")
        names.push("vec4")
        names.push("ivec2")
        names.push("ivec3")
        names.push("ivec4")
        names.push("mat3")
        names.push("mat4")
        names.push("quat")
        names.push("ptr")
        names.push("const_ptr")
        names.push("ref")
        names.push("span")
        names.push("fn")
        names.push("proc")
        names.push("array")
        names.push("SoA")
        names.push("Task")
        names.push("Option")
        names.push("Result")
        names.push("type")
        names.push("atomic")

        var i: ptr_uint = 0
        while i < names.len():
            let name = names.get(i) else:
                break
            let n = unsafe: read(name)
            this.builtin_types.push(n)
            var sym = Symbol(kind = SymbolKind.type_symbol, name = n, type_text = "", is_public = true, line = 0, column = 0)
            this.symbols.push(sym)
            i += 1
        names.release()


    public editable function add_error(msg: str, line: ptr_uint, column: ptr_uint) -> void:
        this.errors.push(SemError(message = msg, line = line, column = column))


    function has_error() -> bool:
        return this.errors.len() > 0


    public editable function register_type(name: str, line: ptr_uint, column: ptr_uint) -> void:
        if this.builtin_type_exists(name):
            return
        if this.lookup(name) != null:
            this.add_error("duplicate declaration", line, column)
            return
        this.symbols.push(Symbol(kind = SymbolKind.type_symbol, name = name, type_text = "", is_public = false, line = line, column = column))


    public editable function register_type_param(name: str, line: ptr_uint, column: ptr_uint) -> void:
        if this.builtin_type_exists(name):
            return
        if this.lookup(name) != null:
            return
        this.symbols.push(Symbol(kind = SymbolKind.type_symbol, name = name, type_text = "", is_public = false, line = line, column = column))


    public editable function register_function(name: str, return_text: str, is_public: bool, line: ptr_uint, column: ptr_uint) -> void:
        if this.lookup(name) != null:
            this.add_error("duplicate declaration", line, column)
            return
        this.symbols.push(Symbol(kind = SymbolKind.function_symbol, name = name, type_text = return_text, is_public = is_public, line = line, column = column))


    public editable function register_const_or_var(name: str, kind: SymbolKind, type_text: str, line: ptr_uint, column: ptr_uint) -> void:
        if this.lookup(name) != null:
            this.add_error("duplicate declaration", line, column)
            return
        this.symbols.push(Symbol(kind = kind, name = name, type_text = type_text, is_public = false, line = line, column = column))


    function builtin_type_exists(name: str) -> bool:
        var i: ptr_uint = 0
        while i < this.builtin_types.len():
            let n = this.builtin_types.get(i) else:
                break
            if unsafe: read(n) == name:
                return true
            i += 1
        return false


    function lookup(name: str) -> ptr[Symbol]?:
        var i: ptr_uint = 0
        while i < this.symbols.len():
            let s = this.symbols.get(i) else:
                break
            let sym = unsafe: read(s)
            if sym.name == name:
                return s
            i += 1
        return null


    public function is_valid_type(name: str) -> bool:
        if this.builtin_type_exists(name):
            return true
        if this.lookup_type(name) != null:
            return true
        return false


    function lookup_type(name: str) -> ptr[Symbol]?:
        var i: ptr_uint = 0
        while i < this.symbols.len():
            let s = this.symbols.get(i) else:
                break
            let sym = unsafe: read(s)
            if sym.name == name and sym.kind == SymbolKind.type_symbol:
                return s
            i += 1
        return null


    public editable function validate_type_ref(type_name: str, line: ptr_uint, column: ptr_uint) -> void:
        if type_name == "" or type_name == "?" or type_name == "void":
            return
        if not this.is_valid_type(type_name):
            this.add_error("unknown type", line, column)
