import std.str
import std.vec as vec

import mtc.ast.nodes
import mtc.sema.symbol
import mtc.sema.loader


public struct Checker:
    ctx: symbol.SemaContext
    loader: loader.ModuleLoader


extending Checker:
    public static function create(stdlib_root: str, source_root: str) -> Checker:
        var ctx = symbol.SemaContext.create("")
        var ld = loader.ModuleLoader.create(stdlib_root, source_root)
        return Checker(ctx = ctx, loader = ld)


    public editable function check(source: nodes.SourceFile) -> symbol.SemaContext:
        this.ctx.module_name = source.module_name

        this.resolve_imports(source)
        this.register_declarations(source)
        this.validate_type_references(source)

        return this.ctx


    editable function resolve_imports(source: nodes.SourceFile) -> void:
        var i: ptr_uint = 0
        while i < source.imports.len():
            let imp_ptr = source.imports.get(i) else:
                break
            let imp = unsafe: read(imp_ptr)
            this.ctx.symbols.push(symbol.Symbol(
                kind = symbol.SymbolKind.module_symbol,
                name = imp.path,
                type_text = imp.alias,
                is_public = false,
                line = imp.line,
                column = imp.column,
            ))
            if imp.alias != "":
                this.ctx.register_type_param(imp.alias, imp.line, imp.column)
            else:
                var last = self_last_component(imp.path)
                if last != "":
                    this.ctx.register_type_param(last, imp.line, imp.column)
            this.loader.load_and_register(ref_of(this.ctx), imp.path)
            i += 1


    editable function register_declarations(source: nodes.SourceFile) -> void:
        var i: ptr_uint = 0
        while i < source.decls.len():
            let d = source.decls.get(i) else:
                break
            let decl = unsafe: read(d)
            this.register_one_declaration(decl)
            i += 1


    editable function register_one_declaration(decl: nodes.Decl) -> void:
        if decl.name == "":
            return

        var type_params = empty_string_vec()
        self_collect_type_params(decl, ref_of(type_params))

        var tpi: ptr_uint = 0
        while tpi < type_params.len():
            let tp = type_params.get(tpi) else:
                break
            let tn = unsafe: read(tp)
            this.ctx.register_type_param(tn, decl.line, decl.column)
            tpi += 1
        type_params.release()

        if decl.kind == nodes.DeclKind.type_alias:
            this.ctx.register_type(decl.name, decl.line, decl.column)
        else if decl.kind == nodes.DeclKind.struct_decl:
            this.ctx.register_type(decl.name, decl.line, decl.column)
        else if decl.kind == nodes.DeclKind.enum_decl:
            this.ctx.register_type(decl.name, decl.line, decl.column)
        else if decl.kind == nodes.DeclKind.flags_decl:
            this.ctx.register_type(decl.name, decl.line, decl.column)
        else if decl.kind == nodes.DeclKind.variant_decl:
            this.ctx.register_type(decl.name, decl.line, decl.column)
        else if decl.kind == nodes.DeclKind.interface_decl:
            this.ctx.register_type(decl.name, decl.line, decl.column)
        else if decl.kind == nodes.DeclKind.opaque_decl:
            this.ctx.register_type(decl.name, decl.line, decl.column)
        else if decl.kind == nodes.DeclKind.union_decl:
            this.ctx.register_type(decl.name, decl.line, decl.column)
        else if decl.kind == nodes.DeclKind.function_def:
            this.ctx.register_function(decl.name, decl.return_text, decl.is_public, decl.line, decl.column)
        else if decl.kind == nodes.DeclKind.extern_function:
            this.ctx.register_function(decl.name, decl.return_text, false, decl.line, decl.column)
        else if decl.kind == nodes.DeclKind.foreign_function:
            this.ctx.register_function(decl.name, decl.return_text, false, decl.line, decl.column)
        else if decl.kind == nodes.DeclKind.const_decl:
            this.ctx.register_const_or_var(decl.name, symbol.SymbolKind.const_symbol, decl.type_name, decl.line, decl.column)
        else if decl.kind == nodes.DeclKind.var_decl:
            this.ctx.register_const_or_var(decl.name, symbol.SymbolKind.var_symbol, decl.type_name, decl.line, decl.column)
        else if decl.kind == nodes.DeclKind.extending_block:
            this.register_extending_methods(decl)


    editable function register_extending_methods(decl: nodes.Decl) -> void:
        var i: ptr_uint = 0
        while i < decl.methods.len():
            let m = decl.methods.get(i) else:
                break
            let method = unsafe: read(m)
            this.ctx.symbols.push(symbol.Symbol(
                kind = symbol.SymbolKind.method_symbol,
                name = f"#{decl.name}.#{method.name}",
                type_text = method.return_text,
                is_public = false,
                line = method.line,
                column = method.column,
            ))
            i += 1


    editable function validate_type_references(source: nodes.SourceFile) -> void:
        var i: ptr_uint = 0
        while i < source.decls.len():
            let d = source.decls.get(i) else:
                break
            let decl = unsafe: read(d)
            this.validate_decl_type_refs(decl)
            i += 1


    editable function validate_decl_type_refs(decl: nodes.Decl) -> void:
        var j: ptr_uint = 0
        while j < decl.params.len():
            let p = decl.params.get(j) else:
                break
            let param = unsafe: read(p)
            this.ctx.validate_type_ref(param.type_text, param.line, param.column)
            j += 1

        j = 0
        while j < decl.fields.len():
            let f = decl.fields.get(j) else:
                break
            let field = unsafe: read(f)
            this.ctx.validate_type_ref(field.type_text, field.line, field.column)
            j += 1

        j = 0
        while j < decl.members.len():
            let m = decl.members.get(j) else:
                break
            j += 1

        if decl.return_text != "":
            this.ctx.validate_type_ref(decl.return_text, decl.line, decl.column)

        if decl.type_name != "" and decl.type_name != "0" and decl.type_name != "1":
            var is_numeric = true
            var ti: ptr_uint = 0
            while ti < decl.type_name.len:
                let tc = decl.type_name.byte_at(ti)
                if not (tc >= '0' and tc <= '9'):
                    is_numeric = false
                    break
                ti += 1
            if not is_numeric:
                this.ctx.validate_type_ref(decl.type_name, decl.line, decl.column)


function empty_string_vec() -> vec.Vec[str]:
    return vec.Vec[str].create()


function self_collect_type_params(decl: nodes.Decl, output: ref[vec.Vec[str]]) -> void:
    var i: ptr_uint = 0
    while i < decl.fields.len():
        let f = decl.fields.get(i) else:
            break
        let field = unsafe: read(f)
        if self_is_type_param_name(field.type_text):
            output.push(field.type_text)
        i += 1

    i = 0
    while i < decl.arms.len():
        let a = decl.arms.get(i) else:
            break
        let arm = unsafe: read(a)
        var j: ptr_uint = 0
        while j < arm.fields.len():
            let af = arm.fields.get(j) else:
                break
            let afield = unsafe: read(af)
            if self_is_type_param_name(afield.type_text):
                output.push(afield.type_text)
            j += 1
        i += 1


function self_is_type_param_name(name: str) -> bool:
    if name.len != 1:
        return false
    let ch = name.byte_at(0)
    return ch >= 'A' and ch <= 'Z'


function self_last_component(path: str) -> str:
    var dot_pos: ptr_uint = path.len
    var i: ptr_uint = path.len
    while i > 0:
        i -= 1
        if path.byte_at(i) == '.':
            dot_pos = i
            break
    if dot_pos >= path.len:
        return ""
    return path.slice(dot_pos + 1, path.len - dot_pos - 1)

