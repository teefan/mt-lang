## Command pattern tests.
## Run via `mtc test test/mt/`.

import std.testing as t
import std.cmd as cmd


struct Counter:
    value: int


function inc(ctx: ptr[Counter]) -> void:
    unsafe:
        read(ctx).value = read(ctx).value + 1


function dec(ctx: ptr[Counter]) -> void:
    unsafe:
        read(ctx).value = read(ctx).value - 1


@[test]
function test_cmd_invoke_revert() -> t.Check:
    var ctr = Counter(value = 0)
    var c = cmd.Cmd[Counter].create(ptr_of(ctr), inc, dec)

    c.invoke()
    t.expect(ctr.value == 1, "invoke increments")?

    c.revert()
    t.expect(ctr.value == 0, "revert decrements")?

    return t.ok()


@[test]
function test_history_execute_undo() -> t.Check:
    var ctr = Counter(value = 0)
    var hist = cmd.History[Counter].create()
    defer hist.release()

    hist.execute(cmd.Cmd[Counter].create(ptr_of(ctr), inc, dec))
    t.expect(ctr.value == 1, "execute increments")?
    t.expect(hist.can_undo(), "can undo after execute")?

    hist.undo()
    t.expect(ctr.value == 0, "undo restores")?
    t.expect(hist.can_redo(), "can redo after undo")?

    return t.ok()


@[test]
function test_history_redo() -> t.Check:
    var ctr = Counter(value = 0)
    var hist = cmd.History[Counter].create()
    defer hist.release()

    hist.execute(cmd.Cmd[Counter].create(ptr_of(ctr), inc, dec))
    hist.undo()
    t.expect(ctr.value == 0, "undone")?

    hist.redo()
    t.expect(ctr.value == 1, "redone")?
    t.expect(hist.can_undo(), "can undo after redo")?

    return t.ok()


@[test]
function test_history_redo_clears_redo_stack() -> t.Check:
    var ctr = Counter(value = 0)
    var hist = cmd.History[Counter].create()
    defer hist.release()

    hist.execute(cmd.Cmd[Counter].create(ptr_of(ctr), inc, dec))
    hist.undo()
    # Now redo stack has the undone command
    hist.execute(cmd.Cmd[Counter].create(ptr_of(ctr), inc, dec))
    # New execute should clear redo stack
    t.expect(not hist.can_redo(), "redo cleared by new execute")?

    return t.ok()


@[test]
function test_history_clear() -> t.Check:
    var ctr = Counter(value = 0)
    var hist = cmd.History[Counter].create()
    defer hist.release()

    hist.execute(cmd.Cmd[Counter].create(ptr_of(ctr), inc, dec))
    hist.undo()
    hist.clear()
    t.expect(not hist.can_undo(), "undo cleared")?
    t.expect(not hist.can_redo(), "redo cleared")?

    return t.ok()


@[test]
function test_history_empty_undo() -> t.Check:
    var hist = cmd.History[Counter].create()
    defer hist.release()

    t.expect(not hist.can_undo(), "no undo available")?
    t.expect(not hist.undo(), "undo returns false")?

    return t.ok()


@[test]
function test_recording() -> t.Check:
    var ctr = Counter(value = 0)
    var rec = cmd.Recording[Counter].create()
    defer rec.release()

    rec.record(cmd.Cmd[Counter].create(ptr_of(ctr), inc, dec))
    rec.record(cmd.Cmd[Counter].create(ptr_of(ctr), inc, dec))
    rec.record(cmd.Cmd[Counter].create(ptr_of(ctr), inc, dec))
    t.expect(rec.count() == 3, "three commands recorded")?

    # Replay through history
    var hist = cmd.History[Counter].create()
    defer hist.release()
    rec.replay(ref_of(hist))
    t.expect(ctr.value == 3, "all three replayed")?

    return t.ok()


@[test]
function test_history_counts() -> t.Check:
    var ctr = Counter(value = 0)
    var hist = cmd.History[Counter].create()
    defer hist.release()

    t.expect(hist.undo_count() == 0, "undo count 0")?
    hist.execute(cmd.Cmd[Counter].create(ptr_of(ctr), inc, dec))
    t.expect(hist.undo_count() == 1, "undo count 1")?
    hist.execute(cmd.Cmd[Counter].create(ptr_of(ctr), inc, dec))
    t.expect(hist.undo_count() == 2, "undo count 2")?
    hist.undo()
    t.expect(hist.undo_count() == 1, "undo count 1 after undo")?
    t.expect(hist.redo_count() == 1, "redo count 1 after undo")?

    return t.ok()
