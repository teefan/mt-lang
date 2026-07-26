## Utility AI — score-based action selection.
##
## Agents evaluate candidate actions by scoring them against
## the current context. The action with the highest score wins.
## Considerations return 0..1 values, combined via geometric
## mean (default), average, min, max, or multiplicative.
##
##   import std.utility as util
##   var selector = util.Selector[MyContext].create()
##   selector.add_action(util.Action[MyContext].create("fight", util.CombineMode.geometric))
##   let chosen = selector.select(ptr_of(ctx))
##   if chosen.selected: execute(chosen.name)

import std.vec as vec
import std.math as math


public enum CombineMode: ubyte
    geometric = 0
    average = 1
    minimum = 2
    maximum = 3
    multiplicative = 4


public struct Consideration[Context]:
    name: str
    score: fn(context: ptr[Context]) -> float


public struct Action[Context]:
    name: str
    considerations: vec.Vec[Consideration[Context]]
    combine: CombineMode
    weight: float


public struct Selector[Context]:
    actions: vec.Vec[Action[Context]]


public struct Selection:
    index: ptr_uint
    name: str
    score: float
    selected: bool


# ── internal helpers ──

function combine_scores(mode: CombineMode, scores: ref[vec.Vec[float]]) -> float:
    let n = scores.len()
    if n == 0:
        return 0.0

    if mode == CombineMode.geometric:
        var product: float = 1.0
        var i: ptr_uint = 0
        while i < n:
            let s_ptr = scores.get(i) else:
                return 0.0
            let s = unsafe: read(s_ptr)
            if s <= 0.0:
                return 0.0
            product = product * s
            i += 1
        let exponent = 1.0 / float<-(n)
        return float<-(math.pow(double<-(product), double<-(exponent)))

    if mode == CombineMode.multiplicative:
        var product: float = 1.0
        var i: ptr_uint = 0
        while i < n:
            let s_ptr = scores.get(i) else:
                return 0.0
            let s = unsafe: read(s_ptr)
            if s <= 0.0:
                return 0.0
            product = product * s
            i += 1
        return product

    if mode == CombineMode.average:
        var sum: float = 0.0
        var i: ptr_uint = 0
        while i < n:
            let s_ptr = scores.get(i) else:
                break
            sum = sum + unsafe: read(s_ptr)
            i += 1
        return sum / float<-(n)

    if mode == CombineMode.minimum:
        var best: float = 1.0
        var i: ptr_uint = 0
        while i < n:
            let s_ptr = scores.get(i) else:
                break
            let s = unsafe: read(s_ptr)
            if s < best:
                best = s
            i += 1
        return best

    # CombineMode.maximum
    var best: float = 0.0
    var i: ptr_uint = 0
    while i < n:
        let s_ptr = scores.get(i) else:
            break
        let s = unsafe: read(s_ptr)
        if s > best:
            best = s
        i += 1
    return best


# ── public types: extensions ──

extending Consideration[Context]:
    public static function create(
        name: str,
        score: fn(context: ptr[Context]) -> float
    ) -> Consideration[Context]:
        return Consideration[Context](name = name, score = score)


extending Action[Context]:
    public static function create(
        name: str,
        combine: CombineMode
    ) -> Action[Context]:
        return Action[Context](
            name = name,
            considerations = vec.Vec[Consideration[Context]].create(),
            combine = combine,
            weight = 1.0
        )


    public editable function set_weight(w: float) -> void:
        this.weight = w


    public editable function add_consideration(c: Consideration[Context]) -> void:
        this.considerations.push(c)


    public function evaluate(context: ptr[Context]) -> float:
        let n = this.considerations.len()
        if n == 0:
            return 0.0

        var scores = vec.Vec[float].with_capacity(n)
        defer scores.release()

        for entry in this.considerations:
            unsafe:
                scores.push(read(entry).score(context))

        return combine_scores(this.combine, ref_of(scores)) * this.weight


    public editable function release() -> void:
        this.considerations.release()


extending Selector[Context]:
    public static function create() -> Selector[Context]:
        return Selector[Context](
            actions = vec.Vec[Action[Context]].create()
        )


    public editable function add_action(action: Action[Context]) -> void:
        this.actions.push(action)


    public function action_count() -> ptr_uint:
        return this.actions.len()


    public function select(context: ptr[Context]) -> Selection:
        var best_index: ptr_uint = 0
        var best_name: str = ""
        var best_score: float = -1.0
        var found: bool = false

        var i: ptr_uint = 0
        for entry in this.actions:
            unsafe:
                let action = read(entry)
                let score = action.evaluate(context)
                if score > 0.0 and score > best_score:
                    best_score = score
                    best_index = i
                    best_name = action.name
                    found = true
            i += 1

        return Selection(index = best_index, name = best_name, score = best_score, selected = found)


    public editable function release() -> void:
        for entry in this.actions:
            unsafe:
                read(entry).release()
        this.actions.release()