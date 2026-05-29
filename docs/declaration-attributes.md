# Declaration Attributes

Status: draft RFC

This document proposes a single declaration-attribute system for Milk Tea.
It replaces dedicated declaration modifiers such as `packed struct` and `align(...) struct` with one canonical attribute surface and extends that surface to struct declarations, struct fields, and callable declarations.

## Summary

Milk Tea should support declaration attributes with a single syntax:

```mt
@[packed, align(16)]
public struct Packet:
    @[rename("payload_len")]
    payload_len: uint

@[inline]
public function parse_packet(data: str) -> Packet:
    ...
```

Attributes must also be stackable and multiline. These forms are equivalent:

```mt
@[packed, align(16)]
public struct MyStruct:
    field_name: int
```

```mt
@[packed]
@[align(16)]
public struct MyStruct:
    field_name: int
```

```mt
@[
    packed,
    align(16),
]
public struct MyStruct:
    field_name: int
```

User-defined attributes are declared explicitly:

```mt
public attribute[struct, field, callable] custom_attr
public attribute[field] rename(name: str)
public attribute[callable] inline
```

Attribute access is compile-time-only in v1 through narrow reflection intrinsics such as `has_attribute(...)`, `field_of(...)`, `callable_of(...)`, `attribute_of(...)`, and `attribute_arg[T](...)`.

## Goals

1. Replace bespoke declaration modifiers with one canonical metadata surface.
2. Support built-in and user-defined attributes with the same syntax.
3. Support attributes on exactly these target kinds in v1: `struct`, `field`, and `callable`.
4. Keep attribute metadata available to compile-time checks and future tooling.
5. Avoid introducing a general declaration object model into ordinary expression space.

## Non-goals

1. This RFC does not add attributes to `union`, `variant`, `enum`, `flags`, `opaque`, local bindings, or statements.
2. This RFC does not add arbitrary compile-time metaprogramming or macros.
3. This RFC does not add runtime reflection over declarations.
4. This RFC does not add multiple ordinary spellings for the same declaration metadata.

## Rationale

Milk Tea already has declaration metadata in practice: `packed` and `align(...)` are struct-level layout annotations. Today they are special syntax rather than general metadata.

That shape does not scale. If the language adds field metadata, codegen hints, serialization names, inline hints, calling-convention markers, or tooling-oriented annotations one by one, the language surface becomes a list of unrelated bespoke declaration modifiers.

The better design is one attribute system with one canonical spelling.

Because Milk Tea is intentionally small, the access model should also stay narrow. The language should not start with a general `T.attributes` object system or declaration iteration protocol. Compile-time query intrinsics are sufficient for the use cases this RFC targets.

## Syntax

### Attribute application syntax

An attribute application list is written as `@[ ... ]` and appears immediately before the declaration or field it decorates.

Each attribute application inside the list is:

- a qualified attribute name such as `packed` or `serde.rename`
- optionally followed by `(...)` arguments

Attribute arguments follow ordinary call-argument syntax. They may be positional or named, and multiline argument lists follow the existing `()` rules.

Attribute references use attribute-name parsing, not ordinary value/type name parsing.

Rules:

1. User-declared attribute names must be ordinary identifiers.
2. Compiler-built-in attribute references use the built-in spellings `packed` and `align`.
3. Module-qualified attribute references such as `serde.rename` are allowed for imported user-defined attributes.
4. Built-in attribute spellings are reserved in the attribute namespace and are not valid user-defined attribute declaration names.

Examples:

```mt
@[packed]
@[align(16)]
public struct Header:
    tag: ubyte
    len: uint
```

```mt
struct Packet:
    @[rename("payload_len")]
    payload_len: uint

    @[custom_attr]
    flags: uint
```

```mt
@[inline]
public function parse() -> int:
    return 0
```

### Stacked and multiline forms

Multiple adjacent attribute blocks on the same target are concatenated in source order.

These two forms are exactly equivalent:

```mt
@[a, b(1), c]
public function f() -> void:
    pass
```

```mt
@[a]
@[b(1)]
@[c]
public function f() -> void:
    pass
```

Multiline lists follow the existing `[]` line-joining rules and may use trailing commas.

### Placement rules

Attributes apply to the next supported declaration or field with no intervening blank line.

Valid placements in v1:

- before a `struct` declaration
- before a struct field inside a `struct` body
- before a callable declaration

In raw `external` files, attribute applications are restricted to compiler-built-in ABI-relevant struct attributes.

That means:

- `@[packed]` is allowed on raw `struct` declarations
- `@[align(...)]` is allowed on raw `struct` declarations
- user-defined attributes are not allowed in raw `external` files
- attribute applications on raw `external function` declarations are not part of v1

Callable declarations in v1 are:

- `function`
- `async function`
- `foreign function`
- `external function`
- methods inside `extending`
- interface method declarations

Attributes are part of the declaration head and therefore precede visibility and callable modifiers:

```mt
@[inline]
public async function build() -> Result[Build, Error]:
    ...
```

### Documentation comments and attributes

Attribute blocks do not break documentation-comment attachment.

When a `##` documentation block is followed by one or more attribute blocks and then a declaration, the documentation attaches to the declaration exactly as if the attribute blocks were not present.

Example:

```mt
## Parses one packet from a borrowed input slice.
@[inline]
public function parse_packet(data: str) -> Packet:
    ...
```

The documentation attaches to `parse_packet`, not to `@[inline]`.

This RFC does not add documentation comments to struct fields.

## Attribute declarations

Attributes are declared at top level with an `attribute` declaration.

Syntax:

```mt
attribute[target, ...] name
attribute[target, ...] name(param: Type, ...)
public attribute[target, ...] name
public attribute[target, ...] name(param: Type, ...)
```

Examples:

```mt
public attribute[struct, field, callable] custom_attr
public attribute[field] rename(name: str)
public attribute[callable] inline
public attribute[struct] cache_line(bytes: ptr_uint)
```

Rules:

1. Attribute declarations live in their own namespace.
2. Attribute names may be imported and module-qualified.
3. `public` controls whether another module may use the attribute through import.
4. The target list must be non-empty and may contain only `struct`, `field`, and `callable` in v1.
5. Attribute parameters, when present, use the same parameter syntax as ordinary callable declarations.
6. Attribute declarations are allowed only in ordinary files, not raw `external` files.
7. Attribute declarations are passive metadata declarations. They do not have bodies, do not declare methods, and cannot participate in `extending` blocks.
8. Attribute declarations do not produce runtime values and cannot be used as ordinary value or type expressions.
9. User-declared attribute names must be ordinary identifiers; built-in spellings such as `packed` and `align` are reserved for compiler-built-in attributes in the attribute namespace.

### Do attributes have implementation or methods?

No.

An `attribute` declaration defines only:

- its name
- its valid target set
- its parameter signature
- optional documentation comments

User-defined attributes are passive metadata. Applying one never executes user code.

Built-in attributes such as `packed` and `align` may have compiler-defined effects, but that behavior belongs to the compiler, not to source-level attribute bodies or methods.

If Milk Tea later needs reusable compile-time behavior associated with metadata, that should be designed as a separate explicit feature rather than hidden inside attribute declarations.

## Built-in attributes

The compiler provides these built-in attributes:

- `packed`
- `align(bytes: ptr_uint)`

These are ordinary attributes in application syntax, but they have compiler-defined semantics.

Their spellings are reserved built-in names in the attribute namespace and are referenced through attribute-name parsing; they are not global language keywords or user-declarable source-level attribute names.

### `packed`

`@[packed]` requests packed layout for the target struct.

Effects:

1. It sets the struct's packed-layout flag.
2. `size_of`, `align_of`, and `offset_of` observe the packed layout.
3. C lowering continues to emit GNU-style `__attribute__((packed))` for the current backend.

### `align(bytes)`

`@[align(N)]` requests explicit alignment for the target struct.

Rules:

1. `bytes` must be a compile-time integer constant.
2. `bytes` must be a positive power of two.
3. `size_of`, `align_of`, and `offset_of` observe the explicit alignment.
4. C lowering continues to emit GNU-style `__attribute__((aligned(N)))` for the current backend.

### Removal of legacy syntax

This RFC removes these declaration forms:

```mt
packed struct Header:
    tag: ubyte

align(16) struct Mat4:
    data: array[float, 16]

packed align(16) struct Packet:
    tag: ubyte
```

They become:

```mt
@[packed]
struct Header:
    tag: ubyte

@[align(16)]
struct Mat4:
    data: array[float, 16]

@[packed]
@[align(16)]
struct Packet:
    tag: ubyte
```

Milk Tea should not keep both spellings.

## Attribute arguments

Attribute arguments must be compile-time constant expressions.

Allowed argument values in v1 are the normal compile-time constant forms already supported by Milk Tea, including:

- integer literals and integer constant expressions
- float literals and float constant expressions
- `true` and `false`
- string and cstring literals
- enum and flags constant expressions

Argument types are checked against the attribute declaration's parameter list.

Examples:

```mt
public attribute[field] rename(name: str)
public attribute[callable] trace(label: str)
public attribute[struct] cache_line(bytes: ptr_uint)
```

```mt
@[rename("payload_len")]
payload_len: uint

@[trace("packet_parser")]
function parse_packet() -> Packet:
    ...

@[cache_line(64)]
struct JobState:
    ...
```

## Attribute application rules

Given an attribute application `@[name(args...)]`, semantic checking must enforce:

1. The attribute exists.
2. The attribute is visible from the current module.
3. The decorated declaration kind is listed in the attribute declaration's target set.
4. The number and types of arguments match the attribute declaration.
5. Every argument is a compile-time constant expression.

Duplicate applications of the same attribute on the same target are rejected in v1.

Examples of invalid code:

```mt
@[rename("x")]
public struct Packet:
    payload_len: uint
```

`rename` targets `field`, not `struct`.

```mt
@[align(3)]
public struct Packet:
    payload_len: uint
```

`align(3)` is invalid because alignment must be a positive power of two.

```mt
@[packed]
@[packed]
public struct Packet:
    payload_len: uint
```

Duplicate attributes are rejected.

## Compile-time attribute access

Attribute access in v1 is compile-time-only.

The language should provide narrow compiler-recognized handles and query intrinsics rather than a general declaration object model.

### Declaration and attribute handles

This RFC proposes four compile-time-only handle forms:

- a struct declaration target, written directly as a struct type expression such as `Packet`
- `field_of(Type, field_name)` for a struct field
- `callable_of(name)` for a callable declaration
- `attribute_of(target, attribute_name)` for one applied attribute on a declaration target

`field_name` is an identifier, not a string literal.

Examples:

```mt
Packet
field_of(Packet, payload_len)
callable_of(parse_packet)
callable_of(Packet.hash)
attribute_of(Packet, align)
attribute_of(field_of(Packet, payload_len), rename)
```

These handles are compile-time-only. They are valid only in compiler-recognized reflection queries and may not be used as runtime values.

### Query intrinsics

This RFC proposes these compile-time intrinsics:

```mt
has_attribute(target, attribute_name) -> bool
field_of(Type, field_name) -> field_handle
callable_of(name) -> callable_handle
attribute_of(target, attribute_name) -> attribute_handle
attribute_arg[T](attribute, param_name) -> T
```

Rules:

1. `target` must be a supported declaration target: a struct type expression, `field_handle`, or `callable_handle`.
2. `attribute_name` resolves in attribute namespace, including module-qualified names.
3. `attribute_of(target, attribute_name)` returns the unique applied attribute handle for that target and attribute name.
4. `attribute_of(...)` is only valid when that attribute is present on the target. Use `has_attribute(...)` when absence is expected or must be guarded.
5. `attribute_arg[T](attribute, param_name)` takes an `attribute_handle`, not a declaration target.
6. `param_name` is the declared parameter name from the attribute declaration, not a numeric index.
7. `attribute_arg[T](...)` requires `T` to exactly match the declared parameter type of `param_name`.
8. Zero-argument attributes such as `packed` support `has_attribute(...)` and `attribute_of(...)`, but have no valid `attribute_arg[T](...)` query.
9. These intrinsics evaluate at compile time and are intended for `const` and `static_assert` contexts.

### Absence and error behavior

`attribute_of(...)` is intentionally strict.

It is a checked projection from a declaration target to one concrete applied attribute, not a search primitive.

This RFC defines the following behavior:

1. `has_attribute(target, attribute_name)` returns `true` when the resolved attribute is applied to the target and `false` when it is not.
2. `has_attribute(...)` is still a semantic query, not a string lookup. Unknown or inaccessible attribute names are compile-time errors.
3. `has_attribute(...)` is a compile-time error when `attribute_name` cannot target the kind of `target` at all, for example `has_attribute(field_of(Packet, x), align)`. That misuse should not silently return `false`.
4. Outside a compiler-recognized presence-guarded context, `attribute_of(target, attribute_name)` is a compile-time error when the resolved attribute is not applied to the target.
5. `attribute_of(...)` is a compile-time error when `attribute_name` is unknown, inaccessible, or cannot target the kind of `target`.
6. `has_attribute(target, attribute_name)` is a presence guard for the same resolved target-and-attribute pair. In the right operand of `and`, and in the `then` branch of `if has_attribute(...)`, `attribute_of(target, attribute_name)` is treated as present and valid.
7. The compiler must apply that presence refinement during semantic analysis, not only during compile-time constant folding.
8. `attribute_arg[T](attribute, param_name)` is a compile-time error when `param_name` is not declared by that attribute.
9. `attribute_arg[T](...)` is a compile-time error when the queried argument type does not exactly match the declared parameter type.
10. `attribute_arg[T](...)` is a compile-time error when the attribute has no such argument because it is a zero-argument attribute or because the named parameter does not exist.

Recommended usage:

```mt
static_assert(
    has_attribute(Packet, align) and
    attribute_arg[ptr_uint](attribute_of(Packet, align), bytes) == 16,
    "Packet alignment changed"
)
```

The guard makes absence explicit. Because `has_attribute(...)` is specified as a compiler-recognized presence guard, the right-hand `attribute_of(...)` query is semantically valid only in the guarded path where that attribute is known to be present.

### Why no optional-handle variant in v1?

This RFC does not add `find_attribute(target, attribute_name) -> attribute_handle?` or a similar optional-handle variant in v1.

Reasons:

1. `has_attribute(...)` already covers the ordinary presence test.
2. `attribute_of(...)` is better as an assertion-like projection with precise diagnostics when the attribute is required.
3. Optional attribute handles would add another special compile-time carrier type without a demonstrated need for storing, passing, or transforming those handles beyond immediate queries.
4. Presence-guard refinement from `has_attribute(...)` already covers the main guarded-use case without adding an optional-handle carrier.
5. The smaller surface keeps the reflection model aligned with the rest of Milk Tea's compile-time queries.

If later real use cases need first-class optional attribute handles, a follow-on RFC can add `find_attribute(...)` as a separate query rather than weakening `attribute_of(...)`.

Examples:

```mt
static_assert(has_attribute(Packet, packed), "Packet must remain packed")
static_assert(
    has_attribute(Packet, align) and
    attribute_arg[ptr_uint](attribute_of(Packet, align), bytes) == 16,
    "Packet alignment changed"
)

static_assert(
    has_attribute(field_of(Packet, payload_len), rename),
    "payload_len must keep its rename metadata"
)

static_assert(
    attribute_arg[str](attribute_of(field_of(Packet, payload_len), rename), name) == "payload_len",
    "field rename changed"
)

static_assert(has_attribute(callable_of(parse_packet), inline), "parse_packet must stay inline")
```

### Why not `T.attributes`?

This RFC explicitly does not introduce a general declaration reflection model such as:

```mt
Packet.attributes
Packet.field(payload_len).attributes
parse_packet.attributes
```

That design would require new declaration-object types, new member-resolution rules, iteration APIs, and a larger compile-time object model. The narrower handle-plus-intrinsic surface is sufficient for the problems this RFC is trying to solve.

## Examples

### Layout-sensitive struct

```mt
@[packed]
@[align(16)]
public struct VertexBlock:
    position: array[float, 3]
    normal: array[float, 3]
    color: uint

static_assert(has_attribute(VertexBlock, packed), "VertexBlock layout changed")
static_assert(
    has_attribute(VertexBlock, align) and
    attribute_arg[ptr_uint](attribute_of(VertexBlock, align), bytes) == 16,
    "VertexBlock alignment changed"
)
```

### Field metadata

```mt
public attribute[field] rename(name: str)
public attribute[field] clamp(min_value: int, max_value: int)

public struct Config:
    @[rename("window_width")]
    width: int

    @[rename("window_height")]
    @[clamp(64, 8192)]
    height: int
```

### Callable metadata

```mt
public attribute[callable] inline
public attribute[callable] trace(label: str)

@[inline]
@[trace("packet.parse")]
public function parse_packet(data: str) -> Packet:
    ...
```

## Semantics and lowering

1. Parsed attribute applications are preserved on AST declaration nodes.
2. Semantic analysis resolves attribute names against declared attributes.
3. Built-in attributes continue to feed the existing struct layout and C-backend rules.
4. User-defined attributes are preserved as typed compile-time metadata for reflection queries and future tooling.
5. Lowering and runtime code generation ignore user-defined attributes unless a future compiler feature explicitly consumes them.

## Implementation outline

1. Add `@` as a lexer token and add `attribute` as a top-level declaration keyword.
2. Add attribute-name parsing for attribute applications and reflection queries. That parser must accept ordinary identifier names for user-defined attributes and the built-in attribute spellings `packed` and `align`.
3. Remove legacy `packed struct` and `align(...) struct` declaration grammar and parse those only through `@[packed]` and `@[align(...)]` applications.
4. Parse reusable attribute application lists before supported declarations and fields, preserving source order across stacked `@[...]` blocks.
5. Preserve documentation-comment attachment across intervening attribute blocks so docs continue to attach to the following declaration rather than to the attribute applications.
6. Add AST nodes for `AttributeDecl` and `AttributeApplication`, and attach attribute-application lists to struct declarations, struct fields, and callable declarations.
7. Introduce an attribute namespace in semantic analysis, resolve user-declared attributes there, and register compiler-built-in attributes `packed` and `align` there as reserved built-ins.
8. Enforce raw `external` file restrictions: only compiler-built-in ABI-relevant struct attributes are allowed there in v1.
9. Type-check attribute applications: visibility, target compatibility, duplicate rejection, arity, named-parameter validity, declared parameter types, and compile-time-constant argument requirements.
10. Normalize resolved applications into typed semantic metadata on each supported declaration target.
11. Map built-in struct attributes onto the existing layout representation so `packed`, `align`, `size_of`, `align_of`, `offset_of`, and C lowering keep their current behavior.
12. Add compile-time handle kinds for field, callable, and attribute reflection queries.
13. Implement the reflection queries in semantic analysis and compile-time evaluation: `has_attribute(...)`, `field_of(...)`, `callable_of(...)`, `attribute_of(...)`, and `attribute_arg[T](...)`.
14. Implement presence-guard refinement from `has_attribute(...)` to `attribute_of(...)` for the same target-and-attribute pair in guarded contexts such as the right operand of `and` and the `then` branch of `if`.
15. Implement the strict absence/error rules for `attribute_of(...)` and `attribute_arg[T](...)` outside those guarded contexts; do not add an optional-handle query in v1.
16. Keep reflection compile-time-only: these queries should fold during semantic analysis / compile-time evaluation and should not introduce new runtime IR or runtime values.
17. Update pretty-printing, formatting, diagnostics, tests, and the language reference to match the attribute-handle model.

## Open constraints

1. v1 keeps attribute targets intentionally narrow.
2. v1 rejects duplicate attributes on one target.
3. v1 keeps reflection compile-time-only.
4. v1 does not make user-defined attributes affect code generation unless explicitly specified by a future RFC.
5. v1 allows raw `external` files to use only compiler-built-in ABI-relevant struct attributes, not general user-defined metadata.
