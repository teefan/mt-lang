## Command pattern — undo/redo with paired do/undo callbacks.
##
## Encapsulate reversible actions as value-objects. Stack-based
## history for linear undo/redo. Recording for replay capture.
##
##   import std.cmd as cmd
##   var hist = cmd.History[Editor].create()
##   hist.execute(cmd.Cmd[Editor].create(ctx, do_insert, undo_delete))
##   hist.undo()

import std.vec as vec


public struct Cmd[Context]:
    context: ptr[Context]
    do_fn: fn(context: ptr[Context]) -> void
    undo_fn: fn(context: ptr[Context]) -> void


public struct History[Context]:
    undos: vec.Vec[Cmd[Context]]
    redos: vec.Vec[Cmd[Context]]


public struct Recording[Context]:
    cmds: vec.Vec[Cmd[Context]]


# ── Cmd ──

extending Cmd[Context]:
    public static function create(
        context: ptr[Context],
        do_fn: fn(context: ptr[Context]) -> void,
        undo_fn: fn(context: ptr[Context]) -> void
    ) -> Cmd[Context]:
        return Cmd[Context](context = context, do_fn = do_fn, undo_fn = undo_fn)


    public function invoke() -> void:
        this.do_fn(this.context)


    public function revert() -> void:
        this.undo_fn(this.context)


# ── History ──

extending History[Context]:
    public static function create() -> History[Context]:
        return History[Context](
            undos = vec.Vec[Cmd[Context]].create(),
            redos = vec.Vec[Cmd[Context]].create()
        )


    public editable function execute(cmd: Cmd[Context]) -> void:
        cmd.invoke()
        this.undos.push(cmd)
        this.redos.clear()


    public editable function undo() -> bool:
        let cmd = this.undos.pop() else:
            return false
        cmd.revert()
        this.redos.push(cmd)
        return true


    public editable function redo() -> bool:
        let cmd = this.redos.pop() else:
            return false
        cmd.invoke()
        this.undos.push(cmd)
        return true


    public function can_undo() -> bool:
        return this.undos.len() > 0


    public function can_redo() -> bool:
        return this.redos.len() > 0


    public function undo_count() -> ptr_uint:
        return this.undos.len()


    public function redo_count() -> ptr_uint:
        return this.redos.len()


    public editable function clear() -> void:
        this.undos.clear()
        this.redos.clear()


    public editable function release() -> void:
        this.undos.release()
        this.redos.release()


# ── Recording ──

extending Recording[Context]:
    public static function create() -> Recording[Context]:
        return Recording[Context](cmds = vec.Vec[Cmd[Context]].create())


    public editable function record(cmd: Cmd[Context]) -> void:
        this.cmds.push(cmd)


    public editable function replay(history: ref[History[Context]]) -> void:
        for entry in this.cmds:
            unsafe:
                history.execute(read(entry))


    public function count() -> ptr_uint:
        return this.cmds.len()


    public editable function clear() -> void:
        this.cmds.clear()


    public editable function release() -> void:
        this.cmds.release()