# Event Declarations

Status: finalized (implemented)

This document describes the built-in event declaration surface for Milk Tea.
It adds one new declaration form, `event`, and a small built-in event API with five canonical operations:

- `subscribe(...)`
- `subscribe_once(...)`
- `unsubscribe(...)`
- `emit(...)`
- `wait()`

The design is intentionally narrow.
Events are typed, fixed-capacity, synchronous by default, and explicit about their storage cost.
This RFC does not add hidden closures, string-named events, event bubbling, or a separate `next` keyword.

## Summary

Milk Tea should support event declarations with this surface:

```mt
struct ResizeEvent:
    width: int
    height: int

struct Window:
    public event closed[4]
    public event resized[8](ResizeEvent)

function on_close() -> void:
    stdio.println("closed")

function on_resize(event: ResizeEvent) -> void:
    stdio.println(f"resize -> #{event.width}x#{event.height}")

function attach(window: ref[Window]) -> Result[void, EventError]:
    let closed_sub = window.closed.subscribe(on_close)?
    let resized_sub = window.resized.subscribe(on_resize)?

    defer window.closed.unsubscribe(closed_sub)
    defer window.resized.unsubscribe(resized_sub)

    return Result[void, EventError].success()

function close(window: ref[Window]) -> void:
    window.closed.emit()

function resize(window: ref[Window], width: int, height: int) -> void:
    window.resized.emit(ResizeEvent(width = width, height = height))

async function wait_for_close(window: ref[Window]) -> Result[void, EventError]:
    await window.closed.wait()?
    return Result[void, EventError].success()

async function wait_for_resize(window: ref[Window]) -> Result[ResizeEvent, EventError]:
    let event = await window.resized.wait()?
    return Result[ResizeEvent, EventError].success(value = event)
```

## Goals

1. Provide a native typed publisher/subscriber surface without forcing each package to hand-roll listener tables.
2. Keep event storage cost explicit and fixed in source.
3. Keep the async bridge obvious by using `wait()` instead of a separate event-specific keyword.
4. Use one canonical subscription spelling that reads well next to `unsubscribe(...)`.
5. Preserve ordinary `fn(...) -> ...` callables as the listener model instead of introducing hidden delegate or closure objects.

## Non-goals

1. This RFC does not add string-named events similar to Node.js `EventEmitter`.
2. This RFC does not add DOM-style bubbling, capture, propagation, or cancellation phases.
3. This RFC does not add implicit asynchronous dispatch. Event delivery remains synchronous.
4. This RFC does not add hidden growable listener arrays or any other unbounded event storage in v1.
5. This RFC does not add multi-payload events. An event carries either no payload or exactly one payload value.
6. This RFC does not add listener return values, subscriber voting, or cancellable event protocols in v1.
7. This base RFC does not define stateful subscriptions. If the follow-up RFC in `docs/stateful-event-subscriptions.md` is accepted, stateful overloads are added there without changing the event declaration syntax in this document.
8. This RFC does not add alternate spellings such as `on(...)`, `off(...)`, `once(...)`, or a `next` keyword.

## Rationale

Milk Tea already has one justified control-flow rewrite surface in `async` / `await`.
Events are a smaller problem.
They need declaration syntax and one clean async bridge, but they do not need a second event-specific control-flow language.

The event model should stay aligned with the language design constraints:

- no user-invisible allocation for closures or method calls
- no garbage collector
- no hidden virtual dispatch
- what you see is what runs

That rules out the usual high-level designs from GC languages.
Milk Tea should not copy C# delegates, JavaScript event emitters, or DOM propagation rules literally.

The correct built-in shape is smaller:

- event declarations should be built in because the publisher owns the surface and only the publisher may raise it
- subscription should use `subscribe(...)` because it is clearer than `.on(...)` and pairs naturally with `unsubscribe(...)`
- the async bridge should use `wait()` because it says what the operation does and avoids colliding with the iterator protocol's existing `next()` meaning
- payloads should be limited to zero or one value so the result of `wait()` stays obvious and the language does not need synthetic tuple or argument-object types

### Why capacity is part of the declaration

Most mainstream event systems hide a growable listener collection behind the runtime.

- DOM `EventTarget` exposes `addEventListener(...)` / `removeEventListener(...)` and relies on runtime-managed listener storage.
- C# events expose add/remove semantics over delegates and multicast invocation lists managed by the runtime.
- Node.js `EventEmitter` keeps an internal listener array and its default max-listener setting is only a warning threshold, not a hard rejection.

Milk Tea cannot copy that model directly.
The language explicitly rejects user-invisible allocation and garbage collection.
If built-in events used an unbounded listener list, the language would need either hidden allocation, hidden shared storage, or an implicit allocator dependency.

The built-in event surface therefore makes listener storage explicit in source with a fixed capacity.
That keeps the runtime model simple and local:

- event storage is inline and owned by the event instance
- listener growth is bounded and visible at declaration time
- overflow is reported as an ordinary `Result` failure instead of turning into hidden allocation

If code genuinely needs unbounded listener growth, that should be a separate library-owned event type with explicit allocator-backed storage rather than the built-in event surface.

## Syntax

### Event declaration syntax

An event declaration is written as one of these forms:

```mt
event name[capacity]
event name[capacity](PayloadType)
public event name[capacity]
public event name[capacity](PayloadType)
```

Examples:

```mt
public event shutdown_requested[8]
public event resized[16](ResizeEvent)
```

The capacity expression must be a compile-time positive integer literal.
It is part of the declaration because listener storage is fixed-size in v1.

### Placement rules

Valid placements in v1:

- top-level ordinary declarations
- member declarations inside `struct` bodies

Examples:

```mt
public event reload_requested[4]
```

```mt
struct Window:
    public event closed[4]
    public event resized[8](ResizeEvent)
```

This RFC does not add event declarations to `external` files, `union`, `variant`, `enum`, `flags`, `opaque`, interface bodies, local bindings, or statements.

### Payload rules

An event carries either:

- no payload
- exactly one payload value of one declared type

The payload type is written as a type expression inside `(...)`.
It is not a named parameter list.

Examples:

```mt
public event closed[4]
public event resized[8](ResizeEvent)
public event line_read[16](str)
```

The payload type must be a storable type.
`ref[T]` payload types are rejected in v1.
This keeps `wait()` and listener calls from manufacturing borrowed values whose lifetime would be unclear outside the dispatch.

### Visibility

Event declarations follow the ordinary declaration visibility rules:

- `public event ...` exports the event surface
- unqualified `event ...` remains module-private

Visibility controls who may name and subscribe to the event.
It does not change who may raise it.

### Built-in event operations

An event value exposes these built-in operations.

For a no-payload event:

```mt
subscribe(listener: fn() -> void) -> Result[Subscription, EventError]
subscribe_once(listener: fn() -> void) -> Result[Subscription, EventError]
unsubscribe(subscription: Subscription) -> bool
emit() -> void
wait() -> Task[Result[void, EventError]]
```

For an event with payload type `T`:

```mt
subscribe(listener: fn(T) -> void) -> Result[Subscription, EventError]
subscribe_once(listener: fn(T) -> void) -> Result[Subscription, EventError]
unsubscribe(subscription: Subscription) -> bool
emit(value: T) -> void
wait() -> Task[Result[T, EventError]]
```

This RFC intentionally standardizes only these names.
There are no aliases.

Listener values follow the existing callable rules for `fn(...) -> ...` types.
This RFC does not introduce any new callable coercion rules.

### Emission access control

`emit(...)` is publisher-only.

Rules:

1. The declaring module may call `emit(...)` on its own events.
2. Other modules may call `subscribe(...)`, `subscribe_once(...)`, `unsubscribe(...)`, and `wait()`, but may not call `emit(...)`.
3. For member events declared inside a `struct`, the same module-level rule applies. The event is still raised by code in the declaring module, not by arbitrary outside code that happens to hold a `ref[Struct]`.

This is the main reason the surface belongs in the language instead of being only a library wrapper around a public listener table.

## Semantics

### Storage model

Each event instance owns a fixed-capacity listener table.
The table size is determined by the declaration's capacity literal.

`subscribe(...)` and `subscribe_once(...)` fail with `EventError.full` when no free slot exists.

No listener is evicted, overwritten, or queued for later installation when an event is full.
The subscription attempt simply fails.

In v1, `EventError.full` is the only failure used by the built-in event subscription operations.

This RFC does not add dynamic growth.

### Subscription handles

`Subscription` is an opaque handle type returned by `subscribe(...)` and `subscribe_once(...)`.

Rules:

1. A subscription handle is meaningful only for the event instance that created it.
2. `unsubscribe(handle)` returns `true` when it disables an active listener.
3. `unsubscribe(handle)` returns `false` when the handle is already inactive, stale for that event instance, or was never valid for that event instance.
4. Calling `unsubscribe(...)` on the wrong event instance does not remove any listener.

The handle itself does not expose methods.
Unsubscription stays event-centered:

```mt
let sub = window.closed.subscribe(on_close)?
defer window.closed.unsubscribe(sub)
```

That shape keeps handle validity tied to a concrete event value rather than inventing a free-floating subscription object with its own lifetime rules.

### Dispatch semantics

Dispatch is synchronous and ordered.

Rules:

1. `emit(...)` calls listeners immediately in registration order.
2. Listener return values are ignored.
3. `subscribe_once(...)` listeners are removed automatically after the first successful dispatch that reaches them.
4. Dispatch uses snapshot semantics. The active listener set for the current `emit(...)` call is determined before the first listener runs.
5. A listener removed during an in-progress dispatch is still called later in that same dispatch if it was already part of the starting snapshot.
6. A listener added during an in-progress dispatch is not called until the next `emit(...)`.

Snapshot semantics match the least surprising behavior for ordered listener arrays and avoid control-flow changes in the middle of a dispatch.

### Async waiting

`wait()` is the async bridge.

Rules:

1. `wait()` installs a temporary one-shot listener.
2. When the next event fires, that temporary listener completes the returned task and removes itself.
3. On a no-payload event, the task result is `Result[void, EventError]`.
4. On a payload event with payload type `T`, the task result is `Result[T, EventError]`.
5. If `wait()` cannot install its temporary listener because the event is full, it returns an already-completed failed task with `EventError.full`.

Examples:

```mt
async function wait_for_close(window: ref[Window]) -> Result[void, EventError]:
    await window.closed.wait()?
    return Result[void, EventError].success()
```

```mt
async function wait_for_resize(window: ref[Window]) -> Result[ResizeEvent, EventError]:
    let event = await window.resized.wait()?
    return Result[ResizeEvent, EventError].success(value = event)
```

This RFC deliberately uses `wait()` instead of a new `next` keyword.
The operation reads directly from source and does not compete with the language's existing iterator `next()` meaning.

### Copy and assignment rules

Events are identity-bearing storage, not plain value fields.

Rules:

1. An event value is not assignable.
2. An event value is not a legal parameter or return type.
3. A `struct` containing one or more event declarations is non-copyable in v1.
4. Passing a `struct` that contains events by value is rejected.
5. Such structs must be manipulated through stored bindings, pointers, or `ref[...]` parameters.

This avoids accidental copying of listener tables, subscription identities, and pending waiter state.

## Examples

### Module-level event

```mt
public event reload_requested[4]

function request_reload() -> void:
    reload_requested.emit()

function log_reload() -> void:
    stdio.println("reload requested")

function install_reload_logger() -> Result[Subscription, EventError]:
    return reload_requested.subscribe(log_reload)
```

### Struct member events

```mt
struct ResizeEvent:
    width: int
    height: int

struct Window:
    public event closed[4]
    public event resized[8](ResizeEvent)

function on_resize(event: ResizeEvent) -> void:
    stdio.println(f"#{event.width}x#{event.height}")

function attach(window: ref[Window]) -> Result[void, EventError]:
    let sub = window.resized.subscribe(on_resize)?
    defer window.resized.unsubscribe(sub)
    return Result[void, EventError].success()

function resize(window: ref[Window], width: int, height: int) -> void:
    window.resized.emit(ResizeEvent(width = width, height = height))
```

### One-shot subscription

```mt
function log_first_close() -> void:
    stdio.println("first close only")

function attach_once(window: ref[Window]) -> Result[Subscription, EventError]:
    return window.closed.subscribe_once(log_first_close)
```

### Async wait

```mt
async function wait_until_closed(window: ref[Window]) -> Result[void, EventError]:
    await window.closed.wait()?
    return Result[void, EventError].success()
```

## Semantics and lowering

1. Each event declaration lowers to compiler-managed fixed-size listener storage.
2. Each active listener slot stores whether the slot is active, whether it is one-shot, and the listener callable value.
3. `subscribe(...)` searches for a free slot, stores the listener, and returns an opaque handle that identifies that slot for the owning event instance.
4. `subscribe_once(...)` behaves the same way but marks the slot one-shot.
5. `unsubscribe(...)` validates the handle against the current event instance and clears the slot when it is active.
6. `emit(...)` captures the active-slot snapshot, then invokes listeners in registration order.
7. `wait()` lowers to a compiler/runtime helper that installs an internal one-shot listener and completes a task when that listener fires.
8. If the helper cannot install that listener because the event is full, `wait()` produces an already-completed failed task with `EventError.full`.

This lowering keeps the event runtime model small:

- fixed listener tables instead of growable collections
- direct listener calls instead of delegate chains
- task completion only where the source explicitly spells `wait()`

## Implementation outline

1. Add `event` as a declaration keyword in ordinary files.
2. Parse event declarations at top level and inside `struct` bodies.
3. Require a positive compile-time integer capacity literal in every event declaration.
4. Parse either the no-payload form or the single-payload type form.
5. Add AST nodes for event declarations and event member declarations.
6. Introduce a built-in event storage type in semantic analysis and mark it as non-copyable.
7. Reject event declarations in unsupported locations such as `external` files, `opaque`, `enum`, `variant`, interface bodies, and locals.
8. Reject direct value assignment or by-value passing of any type that contains event storage.
9. Add the built-in event operations `subscribe`, `subscribe_once`, `unsubscribe`, `emit`, and `wait` to member resolution for event values.
10. Type-check listener signatures against the event payload arity and type.
11. Enforce publisher-only access for `emit(...)` based on the declaring module.
12. Lower listener tables to fixed-capacity runtime storage with slot metadata and stable registration order.
13. Lower `wait()` to a helper that installs a one-shot listener and completes a task on the next dispatch.
14. Introduce the built-in opaque handle type `Subscription` and built-in error type `EventError`.
15. Update diagnostics, formatting, tests, and the language reference to reflect the event surface.

## Open constraints

1. The follow-up RFC in `docs/stateful-event-subscriptions.md` proposes explicit stateful subscriptions with a state pointer plus listener function. If that RFC is accepted, the canonical general-purpose stateful model remains pointer-based. Any future safer borrowed-state form must be scope-bounded sugar rather than a stored `ref[...]` listener representation.
2. v1 does not support multi-payload events.
3. v1 does not support cancellable events or listener return-value aggregation.
4. v1 makes event-bearing structs non-copyable.
5. v1 keeps `emit(...)` publisher-only even for public events.
6. v1 standardizes only the canonical names `subscribe`, `subscribe_once`, `unsubscribe`, `emit`, and `wait`.
