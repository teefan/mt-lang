## Command pattern tests.
## Run via `mtc test test/mt/`.

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
function test_cmd_invoke_revert() -> void:
    var ctr = Counter(value = 0)
    var c = cmd.Cmd[Counter].create(ptr_of(ctr), inc, dec)

    c.invoke()
    expect(ctr.value == 1, "invoke increments")

    c.revert()
    expect(ctr.value == 0, "revert decrements")



@[test]
function test_history_execute_undo() -> void:
    var ctr = Counter(value = 0)
    var hist = cmd.History[Counter].create()
    defer: hist.release()

    hist.execute(cmd.Cmd[Counter].create(ptr_of(ctr), inc, dec))
    expect(ctr.value == 1, "execute increments")
    expect(hist.can_undo(), "can undo after execute")

    hist.undo()
    expect(ctr.value == 0, "undo restores")
    expect(hist.can_redo(), "can redo after undo")



@[test]
function test_history_redo() -> void:
    var ctr = Counter(value = 0)
    var hist = cmd.History[Counter].create()
    defer: hist.release()

    hist.execute(cmd.Cmd[Counter].create(ptr_of(ctr), inc, dec))
    hist.undo()
    expect(ctr.value == 0, "undone")

    hist.redo()
    expect(ctr.value == 1, "redone")
    expect(hist.can_undo(), "can undo after redo")



@[test]
function test_history_redo_clears_redo_stack() -> void:
    var ctr = Counter(value = 0)
    var hist = cmd.History[Counter].create()
    defer: hist.release()

    hist.execute(cmd.Cmd[Counter].create(ptr_of(ctr), inc, dec))
    hist.undo()
    # Now redo stack has the undone command
    hist.execute(cmd.Cmd[Counter].create(ptr_of(ctr), inc, dec))
    # New execute should clear redo stack
    expect(not hist.can_redo(), "redo cleared by new execute")



@[test]
function test_history_clear() -> void:
    var ctr = Counter(value = 0)
    var hist = cmd.History[Counter].create()
    defer: hist.release()

    hist.execute(cmd.Cmd[Counter].create(ptr_of(ctr), inc, dec))
    hist.undo()
    hist.clear()
    expect(not hist.can_undo(), "undo cleared")
    expect(not hist.can_redo(), "redo cleared")



@[test]
function test_history_empty_undo() -> void:
    var hist = cmd.History[Counter].create()
    defer: hist.release()

    expect(not hist.can_undo(), "no undo available")
    expect(not hist.undo(), "undo returns false")



@[test]
function test_recording() -> void:
    var ctr = Counter(value = 0)
    var rec = cmd.Recording[Counter].create()
    defer: rec.release()

    rec.record(cmd.Cmd[Counter].create(ptr_of(ctr), inc, dec))
    rec.record(cmd.Cmd[Counter].create(ptr_of(ctr), inc, dec))
    rec.record(cmd.Cmd[Counter].create(ptr_of(ctr), inc, dec))
    expect(rec.count() == 3, "three commands recorded")

    # Replay through history
    var hist = cmd.History[Counter].create()
    defer: hist.release()
    rec.replay(ref_of(hist))
    expect(ctr.value == 3, "all three replayed")



@[test]
function test_history_counts() -> void:
    var ctr = Counter(value = 0)
    var hist = cmd.History[Counter].create()
    defer: hist.release()

    expect(hist.undo_count() == 0, "undo count 0")
    hist.execute(cmd.Cmd[Counter].create(ptr_of(ctr), inc, dec))
    expect(hist.undo_count() == 1, "undo count 1")
    hist.execute(cmd.Cmd[Counter].create(ptr_of(ctr), inc, dec))
    expect(hist.undo_count() == 2, "undo count 2")
    hist.undo()
    expect(hist.undo_count() == 1, "undo count 1 after undo")
    expect(hist.redo_count() == 1, "redo count 1 after undo")

