# Stateful Event Subscriptions

Status: draft RFC

This document proposes a follow-up extension to [docs/event-declarations.md](docs/event-declarations.md): explicit stateful event subscriptions without hidden closures.

The core idea is simple.
Instead of capturing environment state into a hidden closure object, a stateful subscription passes two explicit values:

- a non-null state pointer
- a listener function whose first parameter receives that state pointer

This matches the existing Milk Tea callback design direction for FFI: code pointer plus explicit state, not code pointer plus hidden heap object.

## Summary

This RFC extends the built-in event API with explicit stateful overloads:

For a no-payload event:

```mt
subscribe[State](state: ptr[State], listener: fn(ptr[State]) -> void) -> Result[Subscription, EventError]
subscribe_once[State](state: ptr[State], listener: fn(ptr[State]) -> void) -> Result[Subscription, EventError]
```

For an event with payload type `T`:

```mt
subscribe[State](state: ptr[State], listener: fn(ptr[State], T) -> void) -> Result[Subscription, EventError]
subscribe_once[State](state: ptr[State], listener: fn(ptr[State], T) -> void) -> Result[Subscription, EventError]
```

Example:

```mt
struct ResizeEvent:
    width: int
    height: int

struct ResizeCounter:
    count: int

function count_resize(state: ptr[ResizeCounter], event: ResizeEvent) -> void:
    unsafe:
        state[0].count += 1
        stdio.println(f"resize #{state[0].count}: #{event.width}x#{event.height}")

function attach(window: ref[Window]) -> Result[void, EventError]:
    var counter = ResizeCounter(count = 0)
    let sub = window.resized.subscribe(ptr_of(counter), count_resize)?
    defer window.resized.unsubscribe(sub)
    return Result[void, EventError].success()
```

The event system stores the state pointer verbatim.
It does not allocate, clone, retain, free, or otherwise manage the pointed-to state.

## Goals

1. Support per-listener state without hidden closures.
2. Reuse Milk Tea's explicit callback model instead of inventing a second callable runtime.
3. Keep state lifetime and allocation explicit at the call site.
4. Preserve the main event RFC's dispatch, capacity, and async-wait semantics.

## Non-goals

1. This RFC does not add capturing lambdas or hidden environment objects.
2. This RFC does not add compiler-managed state allocation or automatic state destruction.
3. This RFC does not add borrow-checked lifetime tracking for subscription state.
4. This RFC does not add method-value capture, delegate objects, or interface-based listeners.
5. This RFC does not change the event declaration syntax or the fixed-capacity event storage model.

## Rationale

The base event RFC intentionally stopped at stateless `fn(...) -> void` listeners.
That keeps the built-in surface small, but it leaves one practical gap: many real handlers need per-subscription state.

GC languages usually fill that gap with closures.
The closure captures local variables, the runtime allocates an environment object, and the event system keeps that object alive until the listener is removed.

Milk Tea should not do that.
That would conflict with the language's explicitness rules and its existing callback direction:

- no user-invisible allocation
- no garbage collector
- callbacks should map directly to explicit code-plus-state shapes

The correct model is the same one already used in C callback APIs: function pointer plus explicit state pointer.
This RFC simply gives that model a typed native surface for events.

### Decision on `ref[...]`-based forms

This RFC chooses a pointer-based model for stored stateful subscriptions and rejects a general stored `ref[...]` overload.

The rejected shape would look like this:

```mt
subscribe[State](state: ref[State], listener: fn(ref[State], T) -> void) -> Result[Subscription, EventError]
```

or, equivalently, any surface that encourages `subscribe(ref_of(value), listener)` for a listener that may outlive the current scope.

That shape is not sound under Milk Tea's current rules.
`ref[T]` means a safe non-null alias to one live object.
Event subscriptions, however, store listener state for later dispatch.
The language does not currently have a lifetime or escape-checking system that can prove the referent of a stored borrow remains live until unsubscribe.

If the event system stored a raw pointer internally but surfaced it back to the user as `ref[T]` during listener invocation, ordinary lifetime bugs would appear as safe code.
That is the wrong tradeoff.

The design is therefore tightened as follows:

- stored stateful subscriptions stay pointer-based
- listener state parameters stay pointer-based
- any future `ref[...]`-based form must be strictly scope-bounded and must not become the stored listener representation

This keeps the unsafety honest at the actual lifetime boundary.

## Syntax

### Stateful subscription overloads

Stateful subscription adds overloads to the existing event operations.

For a no-payload event:

```mt
subscribe[State](state: ptr[State], listener: fn(ptr[State]) -> void) -> Result[Subscription, EventError]
subscribe_once[State](state: ptr[State], listener: fn(ptr[State]) -> void) -> Result[Subscription, EventError]
```

For an event with payload type `T`:

```mt
subscribe[State](state: ptr[State], listener: fn(ptr[State], T) -> void) -> Result[Subscription, EventError]
subscribe_once[State](state: ptr[State], listener: fn(ptr[State], T) -> void) -> Result[Subscription, EventError]
```

`State` is inferred from the `state` argument and must match the listener's first parameter type.

Examples:

```mt
let sub = window.closed.subscribe(ptr_of(counter), on_close_with_counter)?
```

```mt
let sub = window.resized.subscribe(ptr_of(counter), count_resize)?
```

### Why the state argument is a pointer

The state argument is a `ptr[State]`, not a value and not a hidden capture.

That decision is deliberate:

- the source must spell address-taking explicitly with `ptr_of(...)`
- the event runtime can store the state verbatim without allocation
- lifetime responsibility stays with the caller instead of moving into hidden runtime machinery

This surface is lower-level than closures in GC languages, but it is honest about what the event system needs to keep.

It is also the only general-purpose form that is compatible with the current type system without pretending borrowed-state lifetime problems have already been solved.

## State lifetime rules

The state pointer's lifetime is the caller's responsibility.

Rules:

1. The `state` argument must be a non-null `ptr[State]`.
2. The pointed-to storage must remain valid until the listener is unsubscribed or, for `subscribe_once(...)`, until it fires and removes itself.
3. The event system does not keep the state alive.
4. The event system does not free the state.
5. Passing a dangling pointer as event state is undefined behavior in the same way as any other dangling raw pointer usage.

This RFC keeps the responsibility explicit instead of pretending Milk Tea already has a general closure-lifetime system.

### Explicitly rejected pattern

This pattern is invalid by design, even though the type spelling might look attractive:

```mt
function attach_bad(window: ref[Window]) -> Result[Subscription, EventError]:
    var counter = ResizeCounter(count = 0)
    return window.resized.subscribe(ptr_of(counter), count_resize)
```

`counter` dies when `attach_bad` returns, so the returned subscription would hold a dangling state pointer.

The event API does not make this safe.
Code that needs a returned long-lived subscription must keep the state in storage whose lifetime really outlives that subscription, such as a field or explicit heap allocation.

## Examples

### Scope-bounded local state

```mt
struct ResizeCounter:
    count: int

function count_resize(state: ptr[ResizeCounter], event: ResizeEvent) -> void:
    unsafe:
        state[0].count += 1

function run(window: ref[Window]) -> Result[void, EventError]:
    var counter = ResizeCounter(count = 0)
    let sub = window.resized.subscribe(ptr_of(counter), count_resize)?
    defer window.resized.unsubscribe(sub)

    # do work while counter is still alive in this scope

    return Result[void, EventError].success()
```

This pattern is safe because the subscription is explicitly removed before `counter` leaves scope.

### Struct-owned state

```mt
struct App:
    window: Window
    resize_counter: ResizeCounter

function install(app: ref[App]) -> Result[Subscription, EventError]:
    return app.window.resized.subscribe(ptr_of(app.resize_counter), count_resize)
```

This pattern is appropriate when the subscription lifetime matches a field in a larger owner object.

## Possible future borrowed-state sugar

If Milk Tea later wants a safer convenience surface, it should not be a second stored representation.
It should be a scope-bounded helper that lowers to the same pointer-based runtime model while guaranteeing unsubscription before the borrowed state expires.

That future shape would need all of these properties:

- it accepts `ref[State]` or an ordinary mutable addressable `State`
- it does not return an unconstrained `Subscription` that can escape the borrow scope
- it guarantees unsubscribe before the borrowed state can go out of scope
- it lowers to the same pointer-based event slot layout defined in this RFC

This RFC does not define that surface because Milk Tea does not yet have a dedicated scope-resource syntax for such a guarantee.

## Semantics and lowering

1. A stateful listener slot stores the same slot metadata as a stateless listener plus one extra machine value: the state pointer.
2. The state pointer is erased internally to an untyped pointer representation for storage.
3. The stored call target is a typed adapter that restores the original `State` type and calls the user listener.
4. The adapter is compiler-generated static code. It is not a heap-allocated closure object.
5. `emit(...)` passes the stored state pointer and, when present, the event payload value to that adapter.
6. `unsubscribe(...)`, dispatch order, snapshot semantics, capacity handling, and `wait()` behavior are unchanged from the base event RFC.

Conceptually, a payload event slot lowers to a shape like this:

```mt
struct __stateful_listener_slot:
    active: bool
    once: bool
    state: ptr[void]
    call: fn(ptr[void], PayloadType) -> void
```

That is the same fundamental model as explicit C callbacks with `user_data`, but integrated into Milk Tea's typed event surface.

## Relationship to the base event RFC

If accepted, this RFC removes the main open point in [docs/event-declarations.md](docs/event-declarations.md): stateful subscriptions no longer require global/module-visible state.

This RFC does not change:

- event declaration syntax
- event capacity
- publisher-only `emit(...)`
- stateless `subscribe(...)`
- `wait()`

It only adds explicit stateful overloads to `subscribe(...)` and `subscribe_once(...)`.

## Open constraints

1. v1 and the general-purpose model stay pointer-based for stored listener state. A future `ref[...]`-based convenience form is acceptable only if it is scope-bounded sugar and cannot escape as a long-lived stored borrow.
2. v1 does not add `const_ptr[...]`-specialized overloads for read-only state.
3. v1 does not add automatic state boxing or other allocation helpers. If code needs long-lived state beyond stack or field storage, it must allocate that state explicitly using ordinary Milk Tea facilities.
