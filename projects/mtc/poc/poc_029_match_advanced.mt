# POC 029 — Struct pattern guards and equality patterns in match arms
# Tests: Variant arm destructuring with guards (hp > 0), equality patterns
# (status = idle), _ discard, as name binding with guards, transparent
# struct destructure through single struct-field arms.
variant Entity:
    player(hp: int, position: int)
    positioned(loc: struct pos):
        x: int
        y: int
    empty

function match_guards(entity: Entity) -> int:
    match entity:
        Entity.player(hp > 0, position):
            return position
        Entity.player:
            return -1
        Entity.positioned(x, y):
            return x + y
        Entity.empty:
            return 0
    return 0

function main() -> int:
    let p = Entity.player(hp = 10, position = 5)
    let r1 = match_guards(p)

    let dead = Entity.player(hp = 0, position = 5)
    let r2 = match_guards(dead)

    let pos = Entity.positioned(loc = struct pos(x = 3, y = 4))
    let r3 = match_guards(pos)

    let _r1 = r1
    let _r2 = r2
    let _r3 = r3
    return 0
