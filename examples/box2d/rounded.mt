## Box2D sample port: "Rounded" (from box2d-upstream/samples/sample_shapes.cpp).
##
## A 10x10 grid of random convex polygons with random skin radii and rolling
## resistance, falling onto a floor inside a walled arena.
##   Left mouse    drag bodies (mouse joint)
##   P             pause, Space single-step

import std.box2d as b2
import examples.box2d.common as common

struct RoundedShapes implements common.Sample:
    world: b2.WorldId

function rounded_shapes_create(world_id: b2.WorldId) -> RoundedShapes:
    let body_def = b2.default_body_def()
    let ground = b2.create_body(world_id, body_def)

    let shape_def = b2.default_shape_def()
    var box = b2.make_offset_box(20.0, 1.0, b2.Vec2(x = 0.0, y = -1.0), b2.b2Rot_identity)
    b2.create_polygon_shape(ground, shape_def, box)
    box = b2.make_offset_box(1.0, 5.0, b2.Vec2(x = 19.0, y = 5.0), b2.b2Rot_identity)
    b2.create_polygon_shape(ground, shape_def, box)
    box = b2.make_offset_box(1.0, 5.0, b2.Vec2(x = -19.0, y = 5.0), b2.b2Rot_identity)
    b2.create_polygon_shape(ground, shape_def, box)

    var poly_def = b2.default_body_def()
    poly_def.type = b2.BodyType.b2_dynamicBody

    var rounded_def = b2.default_shape_def()
    rounded_def.material.rollingResistance = 0.3

    let x_count = 10
    let y_count = 10
    var y = 2.0
    var row = 0
    while row < y_count:
        var x = -5.0
        var column = 0
        while column < x_count:
            poly_def.position = b2.Vec2(x = x, y = y)
            let body = b2.create_body(world_id, poly_def)
            var poly = common.random_polygon(0.5)
            poly.radius = common.random_float_range(0.05, 0.25)
            b2.create_polygon_shape(body, rounded_def, poly)
            x += 1.0
            column += 1
        y += 1.0
        row += 1

    return RoundedShapes(world = world_id)

extending RoundedShapes:
    editable function on_step() -> void:
        pass

    function draw_overlay() -> void:
        common.draw_text_line("100 random convex polygons with skin radii")

function main() -> int:
    let world_id = common.create_world()
    var sample = rounded_shapes_create(world_id)
    return common.run(
        adapt[common.Sample](ref_of(sample)),
        "Box2D - Rounded",
        b2.Vec2(x = 2.0, y = 8.0),
        25.0 * 0.55,
        world_id
    )
