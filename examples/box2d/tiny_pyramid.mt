## Box2D sample port: "Tiny Pyramid" (from box2d-upstream/samples/sample_robustness.cpp).
##
## A pyramid of 465 tiny squares (5 cm across) stacked to stress solver
## robustness with very small shapes.
##   Left mouse    drag bodies (mouse joint)
##   P             pause, Space single-step

import std.box2d as b2
import examples.box2d.common as common

const BASE_COUNT: int = 30

struct TinyPyramid implements common.Sample:
    world: b2.WorldId
    extent: float

function tiny_pyramid_create(world_id: b2.WorldId) -> TinyPyramid:
    let body_def = b2.default_body_def()
    let ground = b2.create_body(world_id, body_def)
    let ground_box = b2.make_offset_box(5.0, 1.0, b2.Vec2(x = 0.0, y = -1.0), b2.b2Rot_identity)
    b2.create_polygon_shape(ground, b2.default_shape_def(), ground_box)

    let extent = 0.025
    let sample = TinyPyramid(world = world_id, extent = extent)

    var body_def2 = b2.default_body_def()
    body_def2.type = b2.BodyType.b2_dynamicBody
    let shape_def = b2.default_shape_def()
    let box = b2.make_square(extent)

    var i = 0
    while i < BASE_COUNT:
        let y = (2.0 * (i) + 1.0) * extent
        var j = i
        while j < BASE_COUNT:
            let x = ((i + 1)) * extent + 2.0 * (j - i) * extent - (BASE_COUNT) * extent
            body_def2.position = b2.Vec2(x = x, y = y)
            let body = b2.create_body(world_id, body_def2)
            b2.create_polygon_shape(body, shape_def, box)
            j += 1
        i += 1

    return sample

extending TinyPyramid:
    editable function on_step() -> void:
        pass

    function draw_overlay() -> void:
        common.draw_text_line("5.0cm squares")

function main() -> int:
    let world_id = common.create_world()
    var sample = tiny_pyramid_create(world_id)
    return common.run(
        adapt[common.Sample](ref_of(sample)),
        "Box2D - Tiny Pyramid",
        b2.Vec2(x = 0.0, y = 0.8),
        1.0,
        world_id
    )
