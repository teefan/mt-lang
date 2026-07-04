## Module binder — projects an analyzed module's declarations into its public
## export surface (a ModuleBinding) for importers to resolve against.
##
## Mirrors Ruby's ModuleBinder (module_binder.rb): ordinary modules export only
## `public` declarations, while raw (external) modules export everything.  The
## ModuleBinding type itself lives in the analyzer to avoid an import cycle; this
## module supplies the construction/visibility-filtering logic.  Exports
## functions (call checks), structs (construction field checks), and value types.

import std.map as map_mod

import mtc.parser.ast as ast
import mtc.semantic.analyzer as analyzer
import mtc.semantic.types as types


public function bind_module(analysis: analyzer.Analysis) -> analyzer.ModuleBinding:
    var functions = map_mod.Map[str, analyzer.FnSig].create()
    var structs = map_mod.Map[str, span[analyzer.FieldEntry]].create()
    var value_types = map_mod.Map[str, types.Type].create()
    let exports_all = analysis.source_file.module_kind == ast.ModuleKind.module_raw

    var i: ptr_uint = 0
    while i < analysis.source_file.declarations.len:
        var declaration: ast.Decl
        unsafe:
            declaration = read(analysis.source_file.declarations.data + i)
        match declaration:
            ast.Decl.decl_function as fun:
                if exports_all or fun.visibility:
                    let sig_ptr = analysis.functions.get(fun.name)
                    if sig_ptr != null:
                        unsafe:
                            functions.set(fun.name, read(sig_ptr))
            ast.Decl.decl_struct as s:
                if exports_all or s.visibility:
                    let fields_ptr = analysis.structs.get(s.name)
                    if fields_ptr != null:
                        unsafe:
                            structs.set(s.name, read(fields_ptr))
            ast.Decl.decl_const as c:
                if exports_all or c.visibility:
                    let type_ptr = analysis.value_types.get(c.name)
                    if type_ptr != null:
                        unsafe:
                            value_types.set(c.name, read(type_ptr))
            ast.Decl.decl_var as v:
                if exports_all or v.visibility:
                    let type_ptr = analysis.value_types.get(v.name)
                    if type_ptr != null:
                        unsafe:
                            value_types.set(v.name, read(type_ptr))
            _:
                pass
        i += 1

    return analyzer.ModuleBinding(functions = functions, structs = structs, value_types = value_types)
