## Binder — name resolution pass (stub).

import compiler.parser.ast as ast
import compiler.sema.scope as scope_mod
import compiler.sema.type_registry as reg

public type TypeId = reg.TypeId


struct Binder:
    registry: ptr[reg.Registry]
    global_scope: scope_mod.Scope


public function create(registry: ptr[reg.Registry]) -> Binder:
    var global = scope_mod.create(null)
    return Binder(registry = registry, global_scope = global)


extending Binder:
    public editable function bind(decls: span[ptr[ast.Decl]]) -> void:
        var i: ptr_uint = 0
        while i < decls.len:
            let decl = unsafe: read(decls.data + i)
            this.bind_decl(decl)
            i += 1


    editable function bind_decl(decl: ptr[ast.Decl]) -> void:
        unsafe:
            match read(decl):
                ast.Decl.function_def(_):
                    this.bind_function(decl)
                _:
                    pass


    editable function bind_function(decl: ptr[ast.Decl]) -> void:
        unsafe:
            match read(decl):
            ast.Decl.function_def(
                name, _tp, _params, _ret, _body,
                _vis, _async, _konst, _loc,
            ):
                let glob_ptr = ptr_of(this.global_scope)
                scope_mod.define(glob_ptr, name, TypeId<-0)
            _:
                pass
