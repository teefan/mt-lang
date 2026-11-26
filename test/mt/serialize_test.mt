# In-language tests for the opt-in raw struct serializer.

import std.bytes as bytes
import std.serialize as ser

@[ser.serializable]
struct Pod:
    x: int
    y: float

@[test]
function test_pod_round_trip() -> void:
    var original = Pod(x = 7, y = 2.5)
    var packet = ser.pack[Pod](ref_of(original))
    defer: packet.release()
    let decoded = ser.unpack[Pod](packet.as_span()).unwrap()
    expect_eq(decoded.x, 7)
    expect_eq(decoded.y, 2.5)

@[test]
function test_short_input_fails() -> void:
    var empty = bytes.Bytes.empty()
    defer: empty.release()
    let decoded = ser.unpack[Pod](empty.as_span())
    expect(decoded.is_failure())

