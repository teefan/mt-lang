## Hover documentation tables — the host's keyword and builtin call docs.
##
## Ported verbatim from the reference LSP server so a hover renders the same
## markdown as the host: `KEYWORD_HOVER_INFO` + `LANGUAGE_KEYWORD_HOVER_INFO`
## (`lib/milk_tea/lsp/server/hover.rb`) and `BUILTIN_CALL_HOVER_INFO`
## (`lib/milk_tea/lsp/server.rb`).  Regenerate with the generator script noted
## in the commit that added this module; the doc strings must stay identical
## to the host's, so do not reword them here.

import std.str


## One hover documentation entry: the signature shown in the ```milk-tea
## fence and the long-form docs rendered under it.
public struct HoverDoc:
    signature: str
    docs: str


## Look up a language keyword (or the `size_of`/`align_of`/`offset_of`
## builtins) in the host's keyword table.
public function language_keyword(name: str) -> Option[HoverDoc]:
    if name.equal("size_of"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "size_of(Type) -> ptr_uint", docs = "`size_of(Type)` evaluates the compile-time size (in bytes) of the type."))
    if name.equal("align_of"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "align_of(Type) -> ptr_uint", docs = "`align_of(Type)` evaluates the compile-time alignment (in bytes) of the type."))
    if name.equal("offset_of"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "offset_of(Type, field) -> ptr_uint", docs = "`offset_of(Type, field)` evaluates the compile-time byte offset of `field` within `Type`."))
    if name.equal("let"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "let", docs = "Immutable local variable declaration: `let name = value` or `let name: Type`. Supports `else` guard with `T?`, `Option[T]`, or `Result[T, E]`."))
    if name.equal("var"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "var", docs = "Mutable local or module-level variable: `var name: Type = initializer`. Supports `else` guard. Module `var` requires explicit type."))
    if name.equal("const"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "const", docs = "Compile-time constant, requires explicit type and initializer. Block-bodied form `const NAME -> TYPE:` evaluates at compile time."))
    if name.equal("function"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "function", docs = "Ordinary function declaration: `function name(params) -> ReturnType:`. Parameters are non-rebindable. Return type defaults to `void`."))
    if name.equal("async"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "async", docs = "Marks a function as async; the declared return type is lifted to `Task[T]`. Use `await` inside async functions."))
    if name.equal("await"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "await", docs = "Awaits a `Task[T]` inside an async function, yielding the unwrapped `T`. Only allowed in async function bodies."))
    if name.equal("struct"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "struct", docs = "Value-type struct with named, typed fields: `struct Name: field: Type`. Supports generics, nested structs, and `implements`."))
    if name.equal("enum"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "enum", docs = "Integer-backed enumeration: `enum Name: BackingType`. Backing type defaults to `int`. Values auto-increment from 0 or the last explicit value."))
    if name.equal("flags"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "flags", docs = "Bitmask type backed by an integer primitive: `flags Name: uint`. Members must be compile-time integer constants."))
    if name.equal("union"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "union", docs = "Overlapped storage union: `union Name: field1: Type1, field2: Type2`. All fields share the same memory."))
    if name.equal("variant"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "variant", docs = "Tagged union: `variant Name: arm1(field: Type), arm2`. Arms may carry named payload fields. No-payload arms are bare identifiers."))
    if name.equal("opaque"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "opaque", docs = "Externally-defined type with unknown layout: `opaque Name`. May declare `implements` for interface conformance."))
    if name.equal("type"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "type", docs = "Type alias: `type Name = ExistingType`. Generic type parameters are supported."))
    if name.equal("interface"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "interface", docs = "Declares a method contract: `interface Name: function method(params) -> T`. Implemented via `implements`; used at runtime via `dyn[Interface]`."))
    if name.equal("extending"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "extending", docs = "Extends an existing type with methods: `extending Type: function method():`. Supports `function`, `editable function`, and `static function`."))
    if name.equal("implements"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "implements", docs = "Nominal interface conformance on `struct` or `opaque`: `struct Foo implements Interface`. Must be declared on the type definition."))
    if name.equal("editable"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "editable", docs = "Method receiver modifier: `editable function`. Grants mutable access to `this`. Used in interfaces and extending blocks."))
    if name.equal("static"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "static", docs = "Static method modifier: `static function`. No `this` receiver. Used in interfaces and extending blocks for constructors and utilities."))
    if name.equal("import"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "import", docs = "Module import: `import module.path` or `import module.path as alias`. Module lookup resolves `a.b.c` to `a/b/c.mt`."))
    if name.equal("public"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "public", docs = "Export visibility modifier: `public function`, `public type`, etc. Rejected on `extending`, `external`, and `static_assert` declarations."))
    if name.equal("if"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "if", docs = "Conditional branch: `if condition:`. Condition must be `bool`. Supports `else if` and `else`. Inline form: `if cond: stmt else: stmt`."))
    if name.equal("else"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "else", docs = "Else branch for `if`. Chains as `else if condition:` for additional branches. Supports inline single-statement form `else: stmt`."))
    if name.equal("match"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "match", docs = "Pattern match on enum, variant, integer, `str`, or tuple. Expression form produces a value. Must be exhaustive without `_` wildcard."))
    if name.equal("for"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "for", docs = "Loop: `for i in 0..count:` (exclusive range) or `for item in iterable:`. Multi-iteration `for left, right in xs, ys:` iterates arrays/spans in lockstep."))
    if name.equal("while"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "while", docs = "Conditional loop: `while condition:`. Condition must be `bool`. Supports `break`, `continue`, and `defer` inside the body."))
    if name.equal("return"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "return", docs = "Returns a value from a function. Not allowed inside `defer` blocks."))
    if name.equal("break"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "break", docs = "Exits the nearest enclosing `for`, `while`, or `parallel for` loop."))
    if name.equal("continue"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "continue", docs = "Skips to the next iteration of the nearest enclosing `for` or `while` loop."))
    if name.equal("defer"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "defer", docs = "Defers an expression or block to function exit: `defer expr` or `defer:`. Multiple defers execute in LIFO order. `return` is not allowed inside."))
    if name.equal("unsafe"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "unsafe", docs = "Required for pointer indexing, raw pointer dereference, pointer arithmetic, pointer casts, and `reinterpret[...]`. Single-expr or block form."))
    if name.equal("external"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "external", docs = "Raw C ABI surface: `external function name(params) -> T`. No body, supports variadic `...`. Also marks external files with `external` header."))
    if name.equal("foreign"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "foreign", docs = "Foreign function bridging: `foreign function name(params) -> T = c.FuncName`. Supports `in`, `out`, `inout`, and `consuming` parameter modes."))
    if name.equal("consuming"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "consuming", docs = "Foreign function parameter mode: takes ownership of the argument. The caller's binding is consumed. Only on `foreign function` params."))
    if name.equal("when"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "when", docs = "Compile-time conditional: `when CONSTANT:`. Only the chosen branch is type-checked and emitted. Requires `else` unless exhaustive."))
    if name.equal("inline"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "inline", docs = "Compile-time unrolling modifier: `inline for` (loop unrolling), `inline while`, `inline match`, `inline if`. Only the active branch emits code."))
    if name.equal("emit"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "emit", docs = "Emits a declaration at compile time: `emit function ...`. Only allowed inside `const function` or `inline` bodies."))
    if name.equal("parallel"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "parallel", docs = "Concurrency construct: `parallel for i in 0..N:` (data-parallel loop) or `parallel:` block (concurrent statement dispatch). Uses OS threads via libuv."))
    if name.equal("detach"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "detach", docs = "Spawns work on a separate thread, returning a `Handle`: `let h = detach func()`. Use `gather` to wait. Supports global function calls only."))
    if name.equal("gather"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "gather", docs = "Blocks until one or more `detach` handles complete: `gather h1, h2`. Takes one or more `Handle` values."))
    if name.equal("event"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "event", docs = "Typed publisher/subscriber: `event name[capacity]` or `event name[capacity](PayloadType)`. Supports `subscribe`, `emit`, `unsubscribe`, `wait`."))
    if name.equal("attribute"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "attribute", docs = "Declares a reusable declaration attribute: `attribute[target, ...] name(params)`. Targets: struct, field, callable, const, event, enum, flags, union, variant."))
    if name.equal("proc"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "proc", docs = "Ref-counted closure: `proc(params...) -> T: body`. Captures values by value. Storable in structs, arrays, and tuples."))
    if name.equal("fn"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "fn", docs = "Function pointer type: `fn(params...) -> T`. Points to module-level functions. No captured state; capture-free."))
    if name.equal("dyn"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "dyn", docs = "Runtime interface value: `dyn[Interface]`. A fat pointer carrying a data pointer and vtable. Constructed via `adapt[Interface](value)`."))
    if name.equal("is"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "is", docs = "Variant arm membership test: `expr is Variant.arm`. Desugars to a `match` expression evaluating to `bool`. Supports `not` negation."))
    if name.equal("pass"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "pass", docs = "Explicit no-op statement for intentionally empty block bodies."))
    if name.equal("null"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "null", docs = "Null value for nullable types (`T?`). Use typed `null[T]` when context cannot determine the target type."))
    if name.equal("true"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "true", docs = "Boolean literal `true`. Type is `bool`."))
    if name.equal("false"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "false", docs = "Boolean literal `false`. Type is `bool`."))
    if name.equal("static_assert"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "static_assert", docs = "Compile-time assertion: `static_assert(condition, message)`. Fails compilation if the compile-time condition is false."))
    return Option[HoverDoc].none


## Look up a builtin call name in the host's builtin-call table.
public function builtin_call(name: str) -> Option[HoverDoc]:
    if name.equal("fatal"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "builtin fatal(message) -> never", docs = "`fatal(message)` aborts execution with the provided message."))
    if name.equal("ref_of"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "builtin ref_of(value) -> ref[T]", docs = "`ref_of(x)` borrows a safe lvalue as `ref[T]`."))
    if name.equal("const_ptr_of"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "builtin const_ptr_of(value) -> const_ptr[T]", docs = "`const_ptr_of(x)` takes the address of a safe lvalue as `const_ptr[T]`."))
    if name.equal("ptr_of"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "builtin ptr_of(value) -> ptr[T]", docs = "`ptr_of(x)` takes the address of a safe lvalue as `ptr[T]`."))
    if name.equal("read"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "builtin read(value) -> T", docs = "`read(value)` projects a `ref[T]` or pointer-like value to its referent."))
    if name.equal("adapt"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "builtin adapt[Interface](value) -> dyn[Interface]", docs = "`adapt[Interface](value)` constructs a `dyn[Interface]` runtime interface value. Compile-time verified: the value's type must implement the interface."))
    if name.equal("reinterpret"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "builtin reinterpret[T](value) -> T", docs = "`reinterpret[T](value)` reinterprets the bits of `value` as type `T` without conversion. Requires `unsafe`."))
    if name.equal("array"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "builtin array[T, N](elements...) -> array[T, N]", docs = "`array[T, N]` constructs a fixed-size array from elements. Omitted trailing elements default to zero."))
    if name.equal("span"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "builtin span[T](data, len) -> span[T]", docs = "`span[T](data = ..., len = ...)` constructs a borrowed pointer-plus-length view over contiguous memory."))
    if name.equal("zero"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "builtin zero[T] -> T", docs = "`zero[T]` returns a zero-initialized value of type `T`. All bits are set to zero."))
    if name.equal("default"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "builtin default[T] -> T", docs = "`default[T]` calls `T.default()` to produce a semantic default value. Requires an accessible `default()` associated function on `T`."))
    if name.equal("get"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "builtin get(collection, index) -> ptr[T]?", docs = "`get(collection, index)` performs recoverable bounds-checked indexing, returning `ptr[T]?` (null on out-of-bounds) instead of aborting."))
    if name.equal("attribute_arg"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "builtin attribute_arg[T](handle) -> T", docs = "`attribute_arg[T](handle)` returns the `T`-typed argument of a resolved `attribute_handle`. The attribute must declare an argument of type `T`."))
    if name.equal("field_of"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "builtin field_of(Type, field_name) -> field_handle", docs = "`field_of(Type, field_name)` returns a compile-time handle for the named field on a struct type."))
    if name.equal("callable_of"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "builtin callable_of(name) -> callable_handle", docs = "`callable_of(name)` returns a compile-time handle for a callable declaration name."))
    if name.equal("has_attribute"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "builtin has_attribute(target, attribute_name) -> bool", docs = "`has_attribute(target, attribute_name)` checks at compile time whether the resolved attribute is applied to the target."))
    if name.equal("attribute_of"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "builtin attribute_of(target, attribute_name) -> attribute_handle", docs = "`attribute_of(target, attribute_name)` returns the applied attribute handle for the resolved target-and-attribute pair; use `has_attribute(...)` when absence is expected."))
    if name.equal("fields_of"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "builtin fields_of(Type) -> array[field_handle, N]", docs = "`fields_of(Type)` returns all struct fields as a compile-time `array[field_handle, N]`, in declaration order. Use with `inline for` for reflective field iteration."))
    if name.equal("members_of"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "builtin members_of(Type) -> array[member_handle, N]", docs = "`members_of(Type)` returns all members of an enum or flags type as a compile-time `array[member_handle, N]`. Each handle exposes `.name` and `.value`."))
    if name.equal("attributes_of"):
        return Option[HoverDoc].some(value = HoverDoc(signature = "builtin attributes_of(target [, name]) -> array[attribute_handle, N]", docs = "`attributes_of(target)` returns all attributes applied to a type, field, or callable as a compile-time array. `attributes_of(target, name)` filters by attribute kind."))
    return Option[HoverDoc].none
