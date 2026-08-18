## Blackboard tests.
## Run via `mtc test test/mt/`.

import std.blackboard as bb


@[test]
function test_blackboard_set_get() -> void:
    var board = bb.Blackboard[float].create()
    defer: board.release()

    board.set("health", 100.0)
    let v = board.get("health")
    match v:
        Option.none:
            expect(false, "expected health value")
        Option.some as payload:
            expect(payload.value >= 99.9 and payload.value <= 100.1, "health is 100")



@[test]
function test_blackboard_get_missing() -> void:
    var board = bb.Blackboard[float].create()
    defer: board.release()

    let v = board.get("nonexistent")
    match v:
        Option.none:
        Option.some:
            expect(false, "expected none for missing key")



@[test]
function test_blackboard_has() -> void:
    var board = bb.Blackboard[float].create()
    defer: board.release()

    expect(not board.has("health"))
    board.set("health", 50.0)
    expect(board.has("health"))



@[test]
function test_blackboard_overwrite() -> void:
    var board = bb.Blackboard[float].create()
    defer: board.release()

    board.set("health", 100.0)
    board.set("health", 50.0)
    let v = board.get("health")
    match v:
        Option.none:
            expect(false, "expected value")
        Option.some as payload:
            expect(payload.value >= 49.9 and payload.value <= 50.1, "updated to 50")



@[test]
function test_blackboard_remove() -> void:
    var board = bb.Blackboard[float].create()
    defer: board.release()

    board.set("health", 100.0)
    expect(board.has("health"))
    board.remove("health")
    expect(not board.has("health"))



@[test]
function test_blackboard_count() -> void:
    var board = bb.Blackboard[float].create()
    defer: board.release()

    expect(board.count() == 0, "empty count")
    board.set("a", 1.0)
    board.set("b", 2.0)
    board.set("c", 3.0)
    expect(board.count() == 3, "count is 3")
    board.remove("a")
    expect(board.count() == 2, "count after remove")



@[test]
function test_blackboard_clear() -> void:
    var board = bb.Blackboard[float].create()
    defer: board.release()

    board.set("a", 1.0)
    board.set("b", 2.0)
    board.clear()
    expect(board.count() == 0, "clear empties board")
    expect(not board.has("a"))



@[test]
function test_blackboard_int_type() -> void:
    var board = bb.Blackboard[int].create()
    defer: board.release()

    board.set("score", 42)
    let v = board.get("score")
    match v:
        Option.none:
            expect(false, "expected score")
        Option.some as payload:
            expect(payload.value == 42, "int score is 42")



@[test]
function test_blackboard_bool_type() -> void:
    var board = bb.Blackboard[bool].create()
    defer: board.release()

    board.set("ready", true)
    board.set("done", false)
    expect(board.has("ready"))
    expect(board.has("done"))

