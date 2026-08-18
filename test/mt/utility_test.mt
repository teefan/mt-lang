## Utility AI tests.
## Run via `mtc test test/mt/`.

import std.utility as util


# ── test context ──

struct TestCtx:
    health: float
    ammo: float
    enemies: int
    distance: float


function health_score(ctx: ptr[TestCtx]) -> float:
    unsafe:
        let h = read(ctx).health
        if h >= 1.0:
            return 0.0
        return 1.0 - h


function ammo_score(ctx: ptr[TestCtx]) -> float:
    unsafe:
        let a = read(ctx).ammo
        if a <= 0.0:
            return 0.0
        return a


function enemies_score(ctx: ptr[TestCtx]) -> float:
    unsafe:
        let e = read(ctx).enemies
        if e == 0:
            return 0.0
        if e >= 2:
            return 1.0
        return 0.5


function distance_score(ctx: ptr[TestCtx]) -> float:
    unsafe:
        let d = read(ctx).distance
        if d <= 10.0:
            return 1.0
        if d >= 50.0:
            return 0.0
        return (50.0 - d) / 40.0


function build_selector() -> util.Selector[TestCtx]:
    var s = util.Selector[TestCtx].create()

    var attack = util.Action[TestCtx].create("attack", util.CombineMode.geometric)
    attack.add_consideration(util.Consideration[TestCtx].create("has_ammo", ammo_score))
    attack.add_consideration(util.Consideration[TestCtx].create("has_enemies", enemies_score))
    attack.add_consideration(util.Consideration[TestCtx].create("in_range", distance_score))
    s.add_action(attack)

    var flee = util.Action[TestCtx].create("flee", util.CombineMode.geometric)
    flee.add_consideration(util.Consideration[TestCtx].create("low_health", health_score))
    flee.add_consideration(util.Consideration[TestCtx].create("nearby_enemy", enemies_score))
    s.add_action(flee)

    var idle = util.Action[TestCtx].create("idle", util.CombineMode.maximum)
    idle.add_consideration(util.Consideration[TestCtx].create("always", idle_score))
    s.add_action(idle)

    return s


function idle_score(_ctx: ptr[TestCtx]) -> float:
    return 0.1


# ── tests ──

@[test]
function test_utility_select_attack() -> void:
    var ctx = TestCtx(health = 1.0, ammo = 0.8, enemies = 2, distance = 5.0)
    var selector = build_selector()
    defer: selector.release()

    let chosen = selector.select(ptr_of(ctx))
    expect(chosen.selected, "an action was selected")
    expect(chosen.name == "attack", "selects attack when in range with ammo")



@[test]
function test_utility_select_flee() -> void:
    var ctx = TestCtx(health = 0.01, ammo = 0.9, enemies = 2, distance = 5.0)
    var selector = build_selector()
    defer: selector.release()

    let chosen = selector.select(ptr_of(ctx))
    expect(chosen.selected, "an action was selected")
    expect(chosen.name == "flee", "selects flee when health is low")



@[test]
function test_utility_select_idle() -> void:
    var ctx = TestCtx(health = 1.0, ammo = 0.0, enemies = 0, distance = 100.0)
    var selector = build_selector()
    defer: selector.release()

    let chosen = selector.select(ptr_of(ctx))
    expect(chosen.selected, "an action was selected")
    expect(chosen.name == "idle", "selects idle when nothing to do")



@[test]
function test_utility_empty_selector() -> void:
    var ctx = TestCtx(health = 1.0, ammo = 0.5, enemies = 1, distance = 20.0)
    var selector = util.Selector[TestCtx].create()
    defer: selector.release()

    let chosen = selector.select(ptr_of(ctx))
    expect(not chosen.selected)



@[test]
function test_utility_combine_average() -> void:
    var ctx = TestCtx(health = 1.0, ammo = 0.0, enemies = 0, distance = 0.0)
    var selector = util.Selector[TestCtx].create()
    defer: selector.release()

    var a = util.Action[TestCtx].create("test", util.CombineMode.average)
    a.add_consideration(util.Consideration[TestCtx].create("half", half_score))
    a.add_consideration(util.Consideration[TestCtx].create("half2", half_score))
    selector.add_action(a)

    let chosen = selector.select(ptr_of(ctx))
    expect(chosen.selected, "an action was selected")
    expect(chosen.score >= 0.4 and chosen.score <= 0.6, "average of 0.5 + 0.5")



function half_score(_ctx: ptr[TestCtx]) -> float:
    return 0.5


@[test]
function test_utility_combine_minimum() -> void:
    var ctx = TestCtx(health = 1.0, ammo = 0.0, enemies = 0, distance = 0.0)
    var selector = util.Selector[TestCtx].create()
    defer: selector.release()

    var a = util.Action[TestCtx].create("test", util.CombineMode.minimum)
    a.add_consideration(util.Consideration[TestCtx].create("hi", score_high))
    a.add_consideration(util.Consideration[TestCtx].create("lo", score_low))
    selector.add_action(a)

    let chosen = selector.select(ptr_of(ctx))
    expect(chosen.score <= 0.3, "minimum picks the lower value")



function score_high(_ctx: ptr[TestCtx]) -> float:
    return 0.9


function score_low(_ctx: ptr[TestCtx]) -> float:
    return 0.2


@[test]
function test_utility_combine_maximum() -> void:
    var ctx = TestCtx(health = 1.0, ammo = 0.0, enemies = 0, distance = 0.0)
    var selector = util.Selector[TestCtx].create()
    defer: selector.release()

    var a = util.Action[TestCtx].create("test", util.CombineMode.maximum)
    a.add_consideration(util.Consideration[TestCtx].create("hi", score_high))
    a.add_consideration(util.Consideration[TestCtx].create("lo", score_low))
    selector.add_action(a)

    let chosen = selector.select(ptr_of(ctx))
    expect(chosen.score >= 0.8, "maximum picks the higher value")



@[test]
function test_utility_weight() -> void:
    var ctx = TestCtx(health = 1.0, ammo = 0.0, enemies = 0, distance = 0.0)
    var selector = util.Selector[TestCtx].create()
    defer: selector.release()

    var normal = util.Action[TestCtx].create("normal", util.CombineMode.geometric)
    normal.add_consideration(util.Consideration[TestCtx].create("a", half_score))
    normal.set_weight(0.5)
    selector.add_action(normal)

    var boosted = util.Action[TestCtx].create("boosted", util.CombineMode.geometric)
    boosted.add_consideration(util.Consideration[TestCtx].create("a", half_score))
    boosted.set_weight(2.0)
    selector.add_action(boosted)

    let chosen = selector.select(ptr_of(ctx))
    expect(chosen.name == "boosted", "weighted action wins over equal-scoring action")



@[test]
function test_utility_veto_by_zero() -> void:
    var ctx = TestCtx(health = 1.0, ammo = 0.0, enemies = 0, distance = 0.0)
    var selector = util.Selector[TestCtx].create()
    defer: selector.release()

    var a = util.Action[TestCtx].create("vetoed", util.CombineMode.geometric)
    a.add_consideration(util.Consideration[TestCtx].create("a", half_score))
    a.add_consideration(util.Consideration[TestCtx].create("b", score_zero))
    selector.add_action(a)

    let chosen = selector.select(ptr_of(ctx))
    expect(not chosen.selected)



function score_zero(_ctx: ptr[TestCtx]) -> float:
    return 0.0
