## Timer — countdown and repeating timers.
##
## Accumulate delta time and fire when duration is reached.
## Supports one-shot (auto-stop) and repeating (auto-reset).
##
##   import std.timer as time
##   var cooldown = time.Timer.create(0.5, false)
##   var regen = time.Timer.create(1.0, true)
##   ...
##   if cooldown.step(dt): do_ability()
##   if regen.step(dt): heal(1)


public struct Timer:
    duration: float
    elapsed: float
    active: bool
    repeating: bool


# ── public API ──

extending Timer:
    public static function create(duration: float, repeating: bool) -> Timer:
        return Timer(
            duration = duration,
            elapsed = 0.0,
            active = true,
            repeating = repeating
        )


    public editable function step(dt: float) -> bool:
        if not this.active:
            return false
        this.elapsed = this.elapsed + dt
        if this.elapsed >= this.duration:
            if this.repeating:
                this.elapsed = this.elapsed - this.duration
            else:
                this.elapsed = this.duration
                this.active = false
            return true
        return false


    public function progress() -> float:
        if this.duration <= 0.0:
            return 1.0
        let p = this.elapsed / this.duration
        if p > 1.0: return 1.0
        return p


    public function time_left() -> float:
        let t = this.duration - this.elapsed
        if t < 0.0: return 0.0
        return t


    public editable function reset() -> void:
        this.elapsed = 0.0
        this.active = true


    public editable function restart(duration: float) -> void:
        this.duration = duration
        this.elapsed = 0.0
        this.active = true


    public editable function stop() -> void:
        this.active = false


    public editable function pause() -> void:
        this.active = false


    public editable function resume() -> void:
        this.active = true