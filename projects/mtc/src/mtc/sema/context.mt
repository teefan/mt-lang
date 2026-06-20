# Module context for semantic analysis.
# Stores all declarations within a module: types, functions, values, imports, methods.
# Mirrors Ruby lib/milk_tea/core/sema/module_context.rb.

import std.vec
import std.map
import mtc.types
import mtc.ast

# ── Function binding ──

public struct FunctionBinding:
    name: str
    func_type_id: types.TypeId
    params_start: ast.NodeId
    params_len: ast.NodeId
    return_type: types.TypeId
    receiver_type: types.TypeId
    receiver_editable: bool
    is_external: bool
    is_async: bool
    is_const: bool
    body: ast.NodeId
    visibility: str
    type_params_start: ast.NodeId
    type_params_len: ast.NodeId

# ── Interface method ──

public struct InterfaceMethod:
    name: str
    method_kind: str
    params_start: ast.NodeId
    params_len: ast.NodeId
    return_type: types.TypeId

# ── Interface binding ──

public struct InterfaceBinding:
    name: str
    module_name: str
    methods: vec.Vec[InterfaceMethod]
    type_params_start: ast.NodeId
    type_params_len: ast.NodeId

# ── Attribute binding ──

public struct AttributeBinding:
    name: str
    targets: vec.Vec[str]

# ── Import binding ──

public struct ImportBinding:
    path: vec.Vec[str]
    alias_name: str

# ── Module context ──

public struct ModuleContext:
    module_name: str
    module_kind: str
    arena: types.TypeArena

    # Pre-allocated sentinel type ids
    error_type_id: types.TypeId

    # Type storage
    types: map.Map[str, types.TypeId]
    generic_struct_defs: map.Map[str, types.TypeId]
    generic_variant_defs: map.Map[str, types.TypeId]
    generic_interface_defs: map.Map[str, types.TypeId]

    # Function storage
    functions: map.Map[str, FunctionBinding]
    methods: map.Map[str, vec.Vec[FunctionBinding]]

    # Interface storage
    interfaces: map.Map[str, InterfaceBinding]

    # Attribute storage
    attributes: map.Map[str, AttributeBinding]

    # Value storage (const, var, event)
    values: vec.Vec[ValueEntry]

    # Import storage
    imports: vec.Vec[ImportBinding]

    # Diagnostics
    errors: vec.Vec[str]
    has_errors: bool

# Value entry for const/var/event
public struct ValueEntry:
    name: str
    value_type: types.TypeId
    kind: str
    visibility: str

# ── ModuleContext helpers ──

extending ModuleContext:
    public static function create(name: str, kind: str) -> ModuleContext:
        var arena = types.TypeArena.create()
        let error_id = arena.alloc(types.Type.error_type)
        return ModuleContext(
            module_name = name,
            module_kind = kind,
            arena = arena,
            error_type_id = error_id,
            types = map.Map[str, types.TypeId].create(),
            generic_struct_defs = map.Map[str, types.TypeId].create(),
            generic_variant_defs = map.Map[str, types.TypeId].create(),
            generic_interface_defs = map.Map[str, types.TypeId].create(),
            functions = map.Map[str, FunctionBinding].create(),
            methods = map.Map[str, vec.Vec[FunctionBinding]].create(),
            interfaces = map.Map[str, InterfaceBinding].create(),
            attributes = map.Map[str, AttributeBinding].create(),
            values = vec.Vec[ValueEntry].create(),
            imports = vec.Vec[ImportBinding].create(),
            errors = vec.Vec[str].create(),
            has_errors = false,
        )

    public editable function add_error(msg: str) -> void:
        this.errors.push(msg)
        this.has_errors = true

    public editable function register_type(name: str, type_id: types.TypeId) -> void:
        let _prev = this.types.set(name, type_id)
        pass

    public function resolve_type(name: str) -> types.TypeId:
        let ptr = this.types.get(name) else:
            return this.error_type_id
        return unsafe: read(ptr)

    public editable function register_function(name: str, binding: FunctionBinding) -> void:
        let _prev = this.functions.set(name, binding)
        pass

    public function resolve_function(name: str) -> Option[FunctionBinding]:
        let ptr = this.functions.get(name) else:
            return Option[FunctionBinding].none
        return Option[FunctionBinding].some(value = unsafe: read(ptr))
