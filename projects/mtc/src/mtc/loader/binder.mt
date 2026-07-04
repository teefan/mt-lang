## Module binder — projects an analyzed module's declarations into its public
## export surface (a ModuleBinding) for importers to resolve against.
##
## Mirrors Ruby's ModuleBinder (module_binder.rb): ordinary modules export only
## `public` declarations, while raw (external) modules export everything.  The
## ModuleBinding type itself lives in the analyzer to avoid an import cycle; this
## module supplies the construction/visibility-filtering logic.  Scoped to
## functions for now, matching the analyzer's cross-module resolution.

import std.map as map_mod

import mtc.parser.ast as ast
import mtc.semantic.analyzer as analyzer


public function bind_module(analysis: analyzer.Analysis) -> analyzer.ModuleBinding:
    var functions = map_mod.Map[str, analyzer.FnSig].create()
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
            _:
                pass
        i += 1

    return analyzer.ModuleBinding(functions = functions)
