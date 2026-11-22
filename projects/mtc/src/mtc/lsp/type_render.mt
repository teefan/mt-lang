## Type rendering for editor features — resolves the type of an inferred local
## from the analyzer's `resolved_expr_types` map and renders type text the way
## the reference LSP does.
##
## Two renderings are needed:
##   * hover signatures use the host's `Types::Struct#to_s` spelling, which
##     prefixes the declaring module (`main.Sample`) and is then shortened by
##     `shorten_signature`, which also reports the stripped modules so hover can
##     print the host's `*From <module>*` line;
##   * inline type hints and outline details use the host's `short_type_detail`,
##     the bare name with generic arguments (`Sample`, `Deque[int]`).

import std.str
import std.string as string

import mtc.parser.ast as ast
import mtc.semantic.analyzer as analyzer
import mtc.semantic.types as types


## The type the analyzer recorded for an initializer expression, when it
## inferred one (`let s = Sample(…)` → `Sample`).
public function initializer_type(analysis: ref[analyzer.Analysis], value: ptr[ast.Expr]?) -> Option[types.Type]:
    let vp = value else:
        return Option[types.Type].none
    let key = unsafe: reinterpret[ptr_uint](vp)
    let ty_ptr = unsafe: read(analysis).resolved_expr_types.get(key)
    if ty_ptr == null:
        return Option[types.Type].none
    return Option[types.Type].some(value = unsafe: read(ty_ptr))


## The binding type of a local declaration: the resolved annotation for an
## annotated local, else its initializer's inferred type.  A guarded declaration
## (`var x = … else:`) binds the *success* type — the analyzer narrows the
## initializer's `T?`/`Option[T]`/`Result[T, E]` for the scope, and the host's
## facts carry that narrowed type, so a member chain on the local starts there.
public function local_binding_type(analysis: ref[analyzer.Analysis], stmt: ast.Stmt) -> Option[types.Type]:
    match stmt:
        ast.Stmt.stmt_local as loc:
            if loc.stmt_type != null:
                let declared_ptr = unsafe: read(analysis).local_decl_types.get(loc.line)
                if declared_ptr != null:
                    return Option[types.Type].some(value = unsafe: read(declared_ptr))
                return Option[types.Type].none
            match initializer_type(analysis, loc.value):
                Option.some as inited:
                    if loc.else_body != null:
                        return Option[types.Type].some(value = analyzer.unwrap_nullable_type(inited.value))
                    return Option[types.Type].some(value = inited.value)
                Option.none:
                    return Option[types.Type].none
        _:
            return Option[types.Type].none


## The host's `short_type_detail`: a type's own name with its generic
## arguments, without the module qualifier.
public function short_name(ty: types.Type) -> string.String:
    var buf = string.String.create()
    match ty:
        types.Type.ty_primitive as p:
            buf.append(p.name)
        types.Type.ty_named as n:
            let n_np = unsafe: read(n.payload)
            append_own_name(ref_of(buf), n_np.name)
        types.Type.ty_opaque as o:
            append_own_name(ref_of(buf), o.name)
        types.Type.ty_imported as im:
            append_own_name(ref_of(buf), im.name)
            append_short_args(ref_of(buf), im.args)
        types.Type.ty_generic as g:
            buf.append(g.name)
            append_short_args(ref_of(buf), g.args)
        types.Type.ty_tuple as tp:
            buf.append("(")
            var i: ptr_uint = 0
            while i < tp.elements.len:
                if i > 0:
                    buf.append(", ")
                match tp.field_names:
                    Option.some as names:
                        if i < names.value.len:
                            buf.append(unsafe: read(names.value.data + i))
                            buf.append(": ")
                    Option.none:
                        pass
                var rendered = short_name(unsafe: read(tp.elements.data + i))
                buf.append(rendered.as_str())
                rendered.release()
                i += 1
            buf.append(")")
        types.Type.ty_nullable as nl:
            var base = short_name(unsafe: read(nl.base))
            buf.append(base.as_str())
            base.release()
            buf.append("?")
        _:
            buf.append(types.type_to_string(ty))
    return buf


## A type's own name for the short detail: the host's `short_type_detail` uses
## the declared type's `name`, and a type nested in another carries only its own
## segment there (`Rectangle.Edge` is the host's `Edge`).
function append_own_name(target: ref[string.String], name: str) -> void:
    var start: ptr_uint = 0
    var i: ptr_uint = 0
    while i < name.len:
        if name.byte_at(i) == '.':
            start = i + 1
        i += 1
    target.append(name.slice(start, name.len - start))


## The hover's type text: a nominal type carries its declaring module
## (`main.Sample`, `std.c.raylib.Vector4`) — the host's `Types::Struct#to_s`.
## A nominal declared in the file being hovered has no module recorded when the
## file is checked on its own, so `current_module` stands in for it.
public function qualified_name(ty: types.Type, current_module: str) -> string.String:
    var buf = string.String.create()
    match ty:
        types.Type.ty_primitive as p:
            buf.append(p.name)
        types.Type.ty_named as n:
            let n_np = unsafe: read(n.payload)
            let owner = module_or_prelude(n_np.module_name, n_np.name)
            if owner.len == 0 and is_moduleless_builtin_type(n_np.name):
                buf.append(n_np.name)
            else:
                append_module_prefix(ref_of(buf), owner, current_module)
                buf.append(n_np.name)
        types.Type.ty_opaque as o:
            append_module_prefix(ref_of(buf), o.module_name, current_module)
            buf.append(o.name)
        types.Type.ty_imported as im:
            if im.module_name.len > 0:
                buf.append(im.module_name)
                buf.append(".")
            buf.append(im.name)
            append_qualified_args(ref_of(buf), im.args, current_module)
        types.Type.ty_generic as g:
            # A generic instance carries no module of its own: only the prelude
            # names acquire one (`std.option.Option[int]`), so that a signature
            # mentioning them shortens to the host's `Option[int]` plus its
            # `*From std.option*` line.
            let prelude_module = prelude_type_module(g.name)
            if prelude_module.len > 0:
                append_module_prefix(ref_of(buf), prelude_module, current_module)
            buf.append(g.name)
            append_qualified_args(ref_of(buf), g.args, current_module)
        types.Type.ty_nullable as nl:
            var base = qualified_name(unsafe: read(nl.base), current_module)
            buf.append(base.as_str())
            base.release()
            buf.append("?")
        types.Type.ty_function as fnt:
            let fnt_ft = unsafe: read(fnt.payload)
            # The host renders the nested types of a proc/function *qualified*
            # (`proc(std.async.libuv_runtime.Runtime) -> T`), so the fallback's
            # `type_to_string` is only right for the `fn <name>` form.
            if not fnt_ft.is_proc:
                buf.append("fn ")
                buf.append(fnt_ft.name)
            else:
                buf.append("proc(")
                var fi: ptr_uint = 0
                while fi < fnt_ft.params.len:
                    if fi > 0:
                        buf.append(", ")
                    var nested = qualified_name(unsafe: read(fnt_ft.params.data + fi), current_module)
                    buf.append(nested.as_str())
                    nested.release()
                    fi += 1
                buf.append(") -> ")
                var returns = qualified_name(unsafe: read(fnt_ft.return_type), current_module)
                buf.append(returns.as_str())
                returns.release()
        _:
            buf.append(types.type_to_string(ty))
    return buf


## The module a type renders against, with the prelude types supplied: the
## host's analyzer installs `Option` and `Result` from the standard library, so
## their declarations carry `std.option` / `std.result` and a signature that
## mentions them reports the host's `*From std.option*` line and the
## `type Result = Result` hover shape.  The self-host's prelude registers them
## with an empty module name (a single-file check has no std module to bind), so
## the renderer supplies it.
function module_or_prelude(module_name: str, type_name: str) -> str:
    if module_name.len > 0:
        return module_name
    return prelude_type_module(type_name)


## The declaration module of a prelude type name, "" for everything else.
public function prelude_type_module(type_name: str) -> str:
    if type_name.equal("Option"):
        return "std.option"
    if type_name.equal("Result"):
        return "std.result"
    return ""


## Builtin types with no declaring module — the host's `module_name` is nil for
## them, so they render bare with no `*From <module>*` line.  Everything else
## with an empty module is a user type declared in the file being hovered, which
## the renderer qualifies with the file's own module.
function is_moduleless_builtin_type(type_name: str) -> bool:
    return (
        type_name.equal("Handle")
        or type_name.equal("Subscription")
        or type_name.equal("EventError")
    )


## A signature with its module qualifiers stripped plus the modules that were
## stripped, in first-appearance order — the host's `shorten_qualified_types`.
## `let s: main.Sample (immutable)` → text `let s: Sample (immutable)`,
## modules `main`.
public struct ShortenedSignature:
    text: string.String
    modules: string.String


public function shorten_signature(signature: str) -> ShortenedSignature:
    var text = string.String.create()
    var modules = string.String.create()
    var copy_from: ptr_uint = 0
    var i: ptr_uint = 0
    while i < signature.len:
        let b = signature.byte_at(i)
        if not is_identifier_head(b):
            i += 1
            continue

        # Scan the identifier chain starting at `i` (`name`, or `a.b.c` while
        # the segments start lower-case).
        var j = i
        while j < signature.len and is_identifier_char(signature.byte_at(j)):
            j += 1
        var chain_end = j
        while j + 1 < signature.len and signature.byte_at(j) == '.' and is_lower_head(signature.byte_at(j + 1)):
            j += 1
            while j < signature.len and is_identifier_char(signature.byte_at(j)):
                j += 1
            chain_end = j

        # `chain.Type` — drop the qualifier and record the module.
        if j > i and j + 1 < signature.len and signature.byte_at(j) == '.' and is_upper_head(signature.byte_at(j + 1)):
            text.append(signature.slice(copy_from, i - copy_from))
            append_module(ref_of(modules), signature.slice(i, j - i))
            copy_from = j + 1
            i = j + 1
            continue

        if chain_end > i:
            i = chain_end
        else:
            i += 1

    text.append(signature.slice(copy_from, signature.len - copy_from))
    return ShortenedSignature(text = text, modules = modules)


function append_short_args(target: ref[string.String], args: span[types.Type]) -> void:
    if args.len == 0:
        return
    target.append("[")
    var i: ptr_uint = 0
    while i < args.len:
        if i > 0:
            target.append(", ")
        let arg = unsafe: read(args.data + i)
        var rendered = short_name(arg)
        target.append(rendered.as_str())
        rendered.release()
        i += 1
    target.append("]")


function append_qualified_args(target: ref[string.String], args: span[types.Type], current_module: str) -> void:
    if args.len == 0:
        return
    target.append("[")
    var i: ptr_uint = 0
    while i < args.len:
        if i > 0:
            target.append(", ")
        let arg = unsafe: read(args.data + i)
        var rendered = qualified_name(arg, current_module)
        target.append(rendered.as_str())
        rendered.release()
        i += 1
    target.append("]")


function append_module_prefix(target: ref[string.String], module_name: str, current_module: str) -> void:
    if module_name.len > 0:
        target.append(module_name)
        target.append(".")
        return
    if current_module.len > 0:
        target.append(current_module)
        target.append(".")


## Append `name` to the ", "-joined module list when it is not there yet.
function append_module(modules: ref[string.String], name: str) -> void:
    if name.len == 0 or module_list_contains(modules.as_str(), name):
        return
    if modules.len() > 0:
        modules.append(", ")
    modules.append(name)


function module_list_contains(list: str, name: str) -> bool:
    var start: ptr_uint = 0
    while start <= list.len:
        var end = start
        while end < list.len:
            if list.byte_at(end) == ',' and end + 1 < list.len and list.byte_at(end + 1) == ' ':
                break
            end += 1
        let entry = list.slice(start, end - start)
        if entry.equal(name):
            return true
        if end >= list.len:
            return false
        start = end + 2
    return false


function is_identifier_head(b: ubyte) -> bool:
    return is_lower_head(b) or (b >= 'A' and b <= 'Z')


function is_lower_head(b: ubyte) -> bool:
    return (b >= 'a' and b <= 'z') or b == '_'


function is_upper_head(b: ubyte) -> bool:
    return b >= 'A' and b <= 'Z'


function is_identifier_char(b: ubyte) -> bool:
    return is_identifier_head(b) or (b >= '0' and b <= '9')
