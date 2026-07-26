## Blackboard tests.
## Run via `mtc test test/mt/`.

import std.testing as t
import std.blackboard as bb


@[test]
function test_blackboard_set_get() -> t.Check:
    var board = bb.Blackboard[float].create()
    defer board.release()

    board.set("health", 100.0)
    let v = board.get("health")
    match v:
        Option.none:
            return t.fail("expected health value")
        Option.some as payload:
            t.expect(payload.value >= 99.9 and payload.value <= 100.1, "health is 100")?

    return t.ok()


@[test]
function test_blackboard_get_missing() -> t.Check:
    var board = bb.Blackboard[float].create()
    defer board.release()

    let v = board.get("nonexistent")
    match v:
        Option.none:
            return t.ok()
        Option.some:
            return t.fail("expected none for missing key")

    return t.ok()


@[test]
function test_blackboard_has() -> t.Check:
    var board = bb.Blackboard[float].create()
    defer board.release()

    t.expect_false(board.has("health"))?
    board.set("health", 50.0)
    t.expect_true(board.has("health"))?

    return t.ok()


@[test]
function test_blackboard_overwrite() -> t.Check:
    var board = bb.Blackboard[float].create()
    defer board.release()

    board.set("health", 100.0)
    board.set("health", 50.0)
    let v = board.get("health")
    match v:
        Option.none:
            return t.fail("expected value")
        Option.some as payload:
            t.expect(payload.value >= 49.9 and payload.value <= 50.1, "updated to 50")?

    return t.ok()


@[test]
function test_blackboard_remove() -> t.Check:
    var board = bb.Blackboard[float].create()
    defer board.release()

    board.set("health", 100.0)
    t.expect_true(board.has("health"))?
    board.remove("health")
    t.expect_false(board.has("health"))?

    return t.ok()


@[test]
function test_blackboard_count() -> t.Check:
    var board = bb.Blackboard[float].create()
    defer board.release()

    t.expect(board.count() == 0, "empty count")?
    board.set("a", 1.0)
    board.set("b", 2.0)
    board.set("c", 3.0)
    t.expect(board.count() == 3, "count is 3")?
    board.remove("a")
    t.expect(board.count() == 2, "count after remove")?

    return t.ok()


@[test]
function test_blackboard_clear() -> t.Check:
    var board = bb.Blackboard[float].create()
    defer board.release()

    board.set("a", 1.0)
    board.set("b", 2.0)
    board.clear()
    t.expect(board.count() == 0, "clear empties board")?
    t.expect_false(board.has("a"))?

    return t.ok()


@[test]
function test_blackboard_int_type() -> t.Check:
    var board = bb.Blackboard[int].create()
    defer board.release()

    board.set("score", 42)
    let v = board.get("score")
    match v:
        Option.none:
            return t.fail("expected score")
        Option.some as payload:
            t.expect(payload.value == 42, "int score is 42")?

    return t.ok()


@[test]
function test_blackboard_bool_type() -> t.Check:
    var board = bb.Blackboard[bool].create()
    defer board.release()

    board.set("ready", true)
    board.set("done", false)
    t.expect_true(board.has("ready"))?
    t.expect_true(board.has("done"))?

    return t.ok()
