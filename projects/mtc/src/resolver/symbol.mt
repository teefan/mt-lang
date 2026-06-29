import std.str
import std.vec as vec
import context.interner

public enum SymbolKind: ubyte
    sym_function     = 1
    sym_struct       = 2
    sym_variant      = 3
    sym_enum         = 4
    sym_flags        = 5
    sym_union        = 6
    sym_opaque       = 7
    sym_interface    = 8
    sym_type_alias   = 9
    sym_const        = 10
    sym_var          = 11
    sym_event        = 12
    sym_attribute    = 13
    sym_module       = 14
    sym_method       = 15
    sym_type_param   = 16
    sym_local        = 17

public struct Symbol:
    name: str
    kind: SymbolKind
    module_id: uint
    decl_index: uint

public struct Scope:
    parent: uint
    kind: ScopeKind

public enum ScopeKind: ubyte
    module_scope  = 0
    fn_scope      = 1
    block_scope   = 2
    struct_scope  = 3

public struct ScopeTree:
    scopes: vec.Vec[Scope]

extending ScopeTree:
    public static function create() -> ScopeTree:
        var tree = ScopeTree(scopes = vec.Vec[Scope].create())
        tree.scopes.push(Scope(parent = 0, kind = ScopeKind.module_scope))
        return tree

    public editable function push_scope(kind: ScopeKind) -> uint:
        let parent = this.scopes.len() - 1
        this.scopes.push(Scope(parent = uint<-(parent), kind = kind))
        return uint<-(this.scopes.len() - 1)

    public editable function pop_scope() -> void:
        if this.scopes.len() > 1:
            let _ = this.scopes.pop()

    public function current_scope() -> uint:
        return uint<-(this.scopes.len() - 1)

    public function parent_scope(scope_id: uint) -> uint:
        let ptr = this.scopes.get(ptr_uint<-(scope_id)) else:
            return 0
        unsafe:
            return read(ptr).parent

public struct SymbolTable:
    scopes: ScopeTree
    symbols: vec.Vec[Symbol]
    interned: interner.Interner

extending SymbolTable:
    public static function create() -> SymbolTable:
        return SymbolTable(
            scopes = ScopeTree.create(),
            symbols = vec.Vec[Symbol].create(),
            interned = interner.Interner.create()
        )

    public editable function enter_scope(kind: ScopeKind) -> void:
        this.scopes.push_scope(kind)

    public editable function leave_scope() -> void:
        this.scopes.pop_scope()

    public editable function define(name: str, kind: SymbolKind, module_id: uint, decl_index: uint) -> uint:
        let sym = Symbol(name = this.interned.intern(name), kind = kind, module_id = module_id, decl_index = decl_index)
        this.symbols.push(sym)
        return uint<-(this.symbols.len() - 1)

    public function lookup(name: str) -> Option[uint]:
        var scope_id = this.scopes.current_scope()

        while true:
            var i: ptr_uint = this.symbols.len()
            while i > 0:
                i -= 1
                let sym_ptr = this.symbols.get(i) else:
                    fatal(c"symbol_table.lookup missing symbol")
                unsafe:
                    let sym = read(sym_ptr)
                    if sym.name.equal(name):
                        return Option[uint].some(value = uint<-(i))

            if scope_id == 0:
                break

            scope_id = this.scopes.parent_scope(scope_id)

        return Option[uint].none

    public function symbol(sym_index: uint) -> Symbol:
        let ptr = this.symbols.get(ptr_uint<-(sym_index)) else:
            fatal(c"symbol_table.symbol invalid index")
        unsafe:
            return read(ptr)
