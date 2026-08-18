## Signal tests.
## Run via `mtc test test/mt/`.

import std.signal as sig


var last_value: int = -1
var call_count: int = 0


function on_value(val: int) -> void:
    last_value = val
    call_count = call_count + 1


function on_double(val: int) -> void:
    call_count = call_count + 2


@[test]
function test_signal_connect_fire() -> void:
    var s = sig.Signal[int].create()

    last_value = -1
    call_count = 0

    s.connect(on_value)
    s.fire(42)

    expect(last_value == 42, "callback received value")
    expect(call_count == 1, "callback called once")



@[test]
function test_signal_multiple() -> void:
    var s = sig.Signal[int].create()

    last_value = -1
    call_count = 0

    s.connect(on_value)
    s.connect(on_double)
    s.fire(7)

    expect(call_count == 3, "two different callbacks: 1+2=3")



@[test]
function test_signal_disconnect() -> void:
    var s = sig.Signal[int].create()

    call_count = 0
    s.connect(on_value)
    s.disconnect(on_value)
    s.fire(1)

    expect(call_count == 0, "disconnected callback not called")



@[test]
function test_signal_count() -> void:
    var s = sig.Signal[int].create()

    expect(s.count() == 0, "empty signal has 0 subscribers")
    s.connect(on_value)
    expect(s.count() == 1, "one subscriber")
    s.connect(on_double)
    expect(s.count() == 2, "two subscribers")
    s.disconnect(on_value)
    expect(s.count() == 1, "one after disconnect")



@[test]
function test_signal_empty_fire() -> void:
    var s = sig.Signal[int].create()

    call_count = 0
    s.fire(999)
    expect(call_count == 0, "fire with no subscribers does nothing")



@[test]
function test_signal_disconnect_nonexistent() -> void:
    var s = sig.Signal[int].create()

    s.connect(on_value)
    s.disconnect(on_double)  # not connected
    expect(s.count() == 1, "disconnecting unregistered callback no-ops")

