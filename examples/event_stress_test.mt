## Event Stress Test
##
## Exercises the event feature from basic declaration through advanced
## patterns, including capacity exhaustion, multiple subscribers,
## stateful callbacks, subscribe_once auto-removal, nested struct
## events, and async wait integration.
##
## Each function exercises a specific scenario.  The entrypoint
## `main` calls them all and returns a status code where 0
## indicates all checks passed.
##
## NOTE: This file does NOT use `emit` from outside the declaring
## module — `emit` is restricted to the owning module by design.

import std.async as aio

# ---------------------------------------------------------------------------
# 1  Basic declarations
# ---------------------------------------------------------------------------

event no_payload_event[4]
event payload_event[4](int)

struct Resize:
    width: int
    height: int

struct Window:
    public event closed[4]
    public event resized[8](Resize)
    title: str

# --- nested struct with events
struct Container:
    id: int

    struct Inner:
        value: int
        event updated[4](int)

    inner: Inner

# ---------------------------------------------------------------------------
# 2  Stateless subscribe / subscribe_once / unsubscribe / emit
# ---------------------------------------------------------------------------

var no_payload_count: int = 0
var payload_count: int = 0
var once_count: int = 0

function on_no_payload() -> void:
    no_payload_count += 1

function on_payload(value: int) -> void:
    payload_count += value

function on_once() -> void:
    once_count += 1

function subscribe_and_emit() -> bool:
    let _ = no_payload_event.subscribe(on_no_payload) else:
        return false
    no_payload_event.emit()
    return no_payload_count == 1

function subscribe_once_and_emit_twice() -> bool:
    let _ = no_payload_event.subscribe_once(on_once) else:
        return false
    no_payload_event.emit()
    let after_first = once_count
    no_payload_event.emit()
    let after_second = once_count
    return after_first == 1 and after_second == 1

function subscribe_with_payload() -> bool:
    let _ = payload_event.subscribe(on_payload) else:
        return false
    payload_event.emit(5)
    return payload_count == 5

function unsubscribe_active_subscription() -> bool:
    let sub = no_payload_event.subscribe(on_no_payload) else:
        return false
    let removed = no_payload_event.unsubscribe(sub)
    no_payload_event.emit()
    return removed and no_payload_count == 0

function unsubscribe_twice_returns_false() -> bool:
    let sub = no_payload_event.subscribe(on_no_payload) else:
        return false
    no_payload_event.unsubscribe(sub)
    let second_remove = no_payload_event.unsubscribe(sub)
    return not second_remove

# ---------------------------------------------------------------------------
# 3  Struct member events
# ---------------------------------------------------------------------------

var closed_count: int = 0
var resized_total: int = 0

function on_close() -> void:
    closed_count += 1

function on_resize(value: Resize) -> void:
    resized_total += value.width + value.height

function struct_event_subscribe_and_emit(window: ref[Window]) -> bool:
    let _ = window.closed.subscribe(on_close) else:
        return false
    let _ = window.resized.subscribe(on_resize) else:
        return false
    window.closed.emit()
    window.resized.emit(Resize(width = 10, height = 20))
    return closed_count == 1 and resized_total == 30

# ---------------------------------------------------------------------------
# 4  Stateful subscribe
# ---------------------------------------------------------------------------

struct Counter:
    count: int

function on_tick(state: ptr[Counter]) -> void:
    unsafe:
        state.count += 1

function stateful_subscribe_and_emit() -> bool:
    var c = Counter(count = 0)
    let _ = no_payload_event.subscribe(ptr_of(c), on_tick) else:
        return false
    no_payload_event.emit()
    return c.count == 1

# ---------------------------------------------------------------------------
# 5  subscribe_once stateful
# ---------------------------------------------------------------------------

var stateful_once_count: int = 0

function on_tick_once(state: ptr[Counter]) -> void:
    unsafe:
        state.count += 1
    stateful_once_count += 1

function subscribe_once_stateful_and_emit() -> bool:
    var c = Counter(count = 0)
    let _ = no_payload_event.subscribe_once(ptr_of(c), on_tick_once) else:
        return false
    no_payload_event.emit()
    no_payload_event.emit()
    return c.count == 1 and stateful_once_count == 1

# ---------------------------------------------------------------------------
# 6  Multiple simultaneous subscribers
# ---------------------------------------------------------------------------

var multi_count_1: int = 0
var multi_count_2: int = 0
var multi_count_3: int = 0

function on_multi_1() -> void:
    multi_count_1 += 1

function on_multi_2() -> void:
    multi_count_2 += 1

function on_multi_3() -> void:
    multi_count_3 += 1

function multiple_subscribers() -> bool:
    let _ = no_payload_event.subscribe(on_multi_1) else:
        return false
    let _ = no_payload_event.subscribe(on_multi_2) else:
        return false
    let _ = no_payload_event.subscribe(on_multi_3) else:
        return false
    no_payload_event.emit()
    return multi_count_1 == 1 and multi_count_2 == 1 and multi_count_3 == 1

# ---------------------------------------------------------------------------
# 7  Capacity exhaustion (EventError.full)
# ---------------------------------------------------------------------------

event small_cap[2]

function on_small_1() -> void:
    pass

function on_small_2() -> void:
    pass

function on_small_3() -> void:
    pass

function capacity_exhaustion() -> bool:
    let _ = small_cap.subscribe(on_small_1) else:
        return false
    let _ = small_cap.subscribe(on_small_2) else:
        return false
    match small_cap.subscribe(on_small_3):
        Result.success:
            return false
        Result.failure as error:
            return error.error == EventError.full

# ---------------------------------------------------------------------------
# 8  Re-subscribe after unsubscribe (slot reuse)
# ---------------------------------------------------------------------------

var reuse_count: int = 0

function on_reuse() -> void:
    reuse_count += 1

function unsubscribe_and_resubscribe() -> bool:
    let sub = no_payload_event.subscribe(on_reuse) else:
        return false
    let removed = no_payload_event.unsubscribe(sub)
    let _ = no_payload_event.subscribe(on_reuse) else:
        return false
    no_payload_event.emit()
    return removed and reuse_count == 1

# ---------------------------------------------------------------------------
# 9  emit does not fire subscribed_once that was already unsubscribed
# ---------------------------------------------------------------------------

var stale_count: int = 0

function on_stale() -> void:
    stale_count += 1

function stale_unsubscribe_ignored_on_emit() -> bool:
    let sub = no_payload_event.subscribe(on_stale) else:
        return false
    no_payload_event.unsubscribe(sub)
    let current = stale_count
    no_payload_event.emit()
    return stale_count == current

# ---------------------------------------------------------------------------
# 10  Nested struct events
# ---------------------------------------------------------------------------

var nested_update_sum: int = 0

function on_nested_update(value: int) -> void:
    nested_update_sum += value

function nested_struct_event(container: ref[Container]) -> bool:
    let _ = container.inner.updated.subscribe(on_nested_update) else:
        return false
    container.inner.updated.emit(100)
    return nested_update_sum == 100

# ---------------------------------------------------------------------------
# 11  Async wait
# ---------------------------------------------------------------------------

async function wait_and_emit() -> int:
    let waited = no_payload_event.wait()
    no_payload_event.emit()
    match await waited:
        Result.success:
            return 1
        Result.failure:
            return 2

# ---------------------------------------------------------------------------
# 12  Entrypoint
# ---------------------------------------------------------------------------

function main() -> int:
    # basic operations
    if not subscribe_and_emit():
        return 1
    if not subscribe_once_and_emit_twice():
        return 2
    if not subscribe_with_payload():
        return 3
    if not unsubscribe_active_subscription():
        return 4
    if not unsubscribe_twice_returns_false():
        return 5

    # struct member events
    var window = Window(title = "test")
    if not struct_event_subscribe_and_emit(ref_of(window)):
        return 6

    # stateful subscribe
    if not stateful_subscribe_and_emit():
        return 7

    # subscribe_once stateful
    if not subscribe_once_stateful_and_emit():
        return 8

    # multiple subscribers
    if not multiple_subscribers():
        return 9

    # capacity exhaustion
    if not capacity_exhaustion():
        return 10

    # re-subscribe after unsubscribe
    if not unsubscribe_and_resubscribe():
        return 11

    # stale unsubscribe
    if not stale_unsubscribe_ignored_on_emit():
        return 12

    # nested struct events
    var container: Container
    container.id = 0
    container.inner.value = 0
    if not nested_struct_event(ref_of(container)):
        return 13

    # async wait
    let wait_result = aio.wait(wait_and_emit())
    if wait_result != 1:
        return 14

    return 0
