## Box2D sample port: "Confined" (from box2d-upstream/samples/sample_stacking.cpp).
##
## A large grid of zero-gravity circles is spawned inside a capsule-walled box.
## With gravity disabled the circles jostle purely from spawn overlap.
##   Left mouse    drag bodies (mouse joint)
##   P             pause, Space single-step

import std.box2d as b2
import examples.box2d.common as common

const GRID_COUNT: int = 25
const MAX_COUNT: int = GRID_COUNT * GRID_COUNT

struct Confined implements common.Sample:
    world: b2.WorldId

function confined_create(world_id: b2.WorldId) -> Confined:
    let body_def = b2.default_body_def()
    let ground = b2.create_body(world_id, body_def)

    let shape_def = b2.default_shape_def()
    var capsule = b2.Capsule(
        center1 = b2.Vec2(x = -10.5, y = 0.0),
        center2 = b2.Vec2(x = 10.5, y = 0.0),
        radius = 0.5
    )
    b2.create_capsule_shape(ground, shape_def, capsule)
    capsule = b2.Capsule(
        center1 = b2.Vec2(x = -10.5, y = 0.0),
        center2 = b2.Vec2(x = -10.5, y = 20.5),
        radius = 0.5
    )
    b2.create_capsule_shape(ground, shape_def, capsule)
    capsule = b2.Capsule(
        center1 = b2.Vec2(x = 10.5, y = 0.0),
        center2 = b2.Vec2(x = 10.5, y = 20.5),
        radius = 0.5
    )
    b2.create_capsule_shape(ground, shape_def, capsule)
    capsule = b2.Capsule(
        center1 = b2.Vec2(x = -10.5, y = 20.5),
        center2 = b2.Vec2(x = 10.5, y = 20.5),
        radius = 0.5
    )
    b2.create_capsule_shape(ground, shape_def, capsule)

    var body = b2.default_body_def()
    body.type = b2.BodyType.b2_dynamicBody
    body.gravityScale = 0.0

    let circle_def = b2.default_shape_def()
    let circle = b2.Circle(center = b2.Vec2(x = 0.0, y = 0.0), radius = 0.5)

    let span = 18.0 / GRID_COUNT
    var count = 0
    var column = 0
    while count < MAX_COUNT:
        var row = 0
        var i = 0
        while i < GRID_COUNT:
            let x = -8.75 + column * span
            let y = 1.5 + row * span
            body.position = b2.Vec2(x = x, y = y)
            let body_id = b2.create_body(world_id, body)
            b2.create_circle_shape(body_id, circle_def, circle)
            count += 1
            row += 1
            i += 1
        column += 1

    return Confined(world = world_id)

extending Confined:
    editable function on_step() -> void:
        pass

    function draw_overlay() -> void:
        common.draw_text_line("625 zero-gravity circles confined in a capsule box")

function main() -> int:
    let world_id = common.create_world()
    var sample = confined_create(world_id)
    return common.run(
        adapt[common.Sample](ref_of(sample)),
        "Box2D - Confined",
        b2.Vec2(x = 0.0, y = 10.0),
        12.5,
        world_id
    )
