## Signal — fixed-capacity observer / publish-subscribe.
##
## Connect callbacks to signals and fire typed payloads.
## Up to 16 subscribers per signal, stack-allocated.
##
##   import std.signal as sig
##   var on_damage = sig.Signal[int].create()
##   on_damage.connect(handle_damage)
##   on_damage.fire(25)

public struct Signal[Payload]:
    slots: array[fn(payload: Payload) -> void, 16]
    count: ptr_uint


# ── public API ──

extending Signal[Payload]:
    public static function create() -> Signal[Payload]:
        var s = Signal[Payload](
            slots = zero[array[fn(payload: Payload) -> void, 16]],
            count = 0
        )
        return s


    public editable function connect(callback: fn(payload: Payload) -> void) -> void:
        if this.count >= 16:
            return

        var i: ptr_uint = 0
        while i < this.count:
            unsafe:
                if this.slots[i] == callback:
                    return
            i += 1

        unsafe:
            this.slots[this.count] = callback
        this.count = this.count + 1


    public editable function disconnect(callback: fn(payload: Payload) -> void) -> void:
        var i: ptr_uint = 0
        while i < this.count:
            unsafe:
                if this.slots[i] == callback:
                    # swap-remove with last
                    this.count = this.count - 1
                    if i < this.count:
                        this.slots[i] = this.slots[this.count]
                    return
            i += 1


    public function fire(payload: Payload) -> void:
        var i: ptr_uint = 0
        while i < this.count:
            unsafe:
                let cb = this.slots[i]
                cb(payload)
            i += 1


    public function count() -> ptr_uint:
        return this.count