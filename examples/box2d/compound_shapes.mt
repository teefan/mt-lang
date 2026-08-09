## Box2D sample port: "Compound Shapes" (from box2d-upstream/samples/sample_shapes.cpp).
##
## Two tables and two spaceships built from multiple convex shapes per body.
## The "intrude" action drops an obstruction onto each structure to show how
## compound shapes handle being hit. Body AABBs can be toggled.
##   I             drop obstructions onto the structures
##   A             toggle body AABB display
##   Left mouse    drag bodies (mouse joint)
##   P             pause, Space single-step

import std.box2d as b2
import std.raylib as rl
import examples.box2d.common as common

struct CompoundShapes implements common.Sample:
    world: b2.WorldId
    table1_id: b2.BodyId
    table2_id: b2.BodyId
    ship1_id: b2.BodyId
    ship2_id: b2.BodyId
    draw_body_aabbs: bool

function compound_shapes_create(world_id: b2.WorldId) -> CompoundShapes:
    let body_def = b2.default_body_def()
    let ground = b2.create_body(world_id, body_def)

    let shape_def = b2.default_shape_def()
    let segment = b2.Segment(
        point1 = b2.Vec2(x = 50.0, y = 0.0),
        point2 = b2.Vec2(x = -50.0, y = 0.0)
    )
    b2.create_segment_shape(ground, shape_def, segment)

    var sample = CompoundShapes(
        world = world_id,
        table1_id = b2.b2_nullBodyId,
        table2_id = b2.b2_nullBodyId,
        ship1_id = b2.b2_nullBodyId,
        ship2_id = b2.b2_nullBodyId,
        draw_body_aabbs = false
    )

    # Table 1
    var table_def = b2.default_body_def()
    table_def.type = b2.BodyType.b2_dynamicBody
    table_def.position = b2.Vec2(x = -15.0, y = 1.0)
    sample.table1_id = b2.create_body(world_id, table_def)
    let top = b2.make_offset_box(3.0, 0.5, b2.Vec2(x = 0.0, y = 3.5), b2.b2Rot_identity)
    let left_leg = b2.make_offset_box(0.5, 1.5, b2.Vec2(x = -2.5, y = 1.5), b2.b2Rot_identity)
    let right_leg = b2.make_offset_box(0.5, 1.5, b2.Vec2(x = 2.5, y = 1.5), b2.b2Rot_identity)
    b2.create_polygon_shape(sample.table1_id, shape_def, top)
    b2.create_polygon_shape(sample.table1_id, shape_def, left_leg)
    b2.create_polygon_shape(sample.table1_id, shape_def, right_leg)

    # Table 2
    table_def = b2.default_body_def()
    table_def.type = b2.BodyType.b2_dynamicBody
    table_def.position = b2.Vec2(x = -5.0, y = 1.0)
    sample.table2_id = b2.create_body(world_id, table_def)
    let top2 = b2.make_offset_box(3.0, 0.5, b2.Vec2(x = 0.0, y = 3.5), b2.b2Rot_identity)
    let left_leg2 = b2.make_offset_box(0.5, 2.0, b2.Vec2(x = -2.5, y = 2.0), b2.b2Rot_identity)
    let right_leg2 = b2.make_offset_box(0.5, 2.0, b2.Vec2(x = 2.5, y = 2.0), b2.b2Rot_identity)
    b2.create_polygon_shape(sample.table2_id, shape_def, top2)
    b2.create_polygon_shape(sample.table2_id, shape_def, left_leg2)
    b2.create_polygon_shape(sample.table2_id, shape_def, right_leg2)

    # Spaceship 1
    var ship_def = b2.default_body_def()
    ship_def.type = b2.BodyType.b2_dynamicBody
    ship_def.position = b2.Vec2(x = 5.0, y = 1.0)
    sample.ship1_id = b2.create_body(world_id, ship_def)
    var vertices: array[b2.Vec2, 3]
    vertices[0] = b2.Vec2(x = -2.0, y = 0.0)
    vertices[1] = b2.Vec2(x = 0.0, y = 4.0 / 3.0)
    vertices[2] = b2.Vec2(x = 0.0, y = 4.0)
    var hull = b2.compute_hull(const_ptr_of(vertices[0]), 3)
    let ship1_left = b2.make_polygon(const_ptr_of(hull), 0.0)
    vertices[0] = b2.Vec2(x = 2.0, y = 0.0)
    vertices[1] = b2.Vec2(x = 0.0, y = 4.0 / 3.0)
    vertices[2] = b2.Vec2(x = 0.0, y = 4.0)
    hull = b2.compute_hull(const_ptr_of(vertices[0]), 3)
    let ship1_right = b2.make_polygon(const_ptr_of(hull), 0.0)
    b2.create_polygon_shape(sample.ship1_id, shape_def, ship1_left)
    b2.create_polygon_shape(sample.ship1_id, shape_def, ship1_right)

    # Spaceship 2
    ship_def = b2.default_body_def()
    ship_def.type = b2.BodyType.b2_dynamicBody
    ship_def.position = b2.Vec2(x = 15.0, y = 1.0)
    sample.ship2_id = b2.create_body(world_id, ship_def)
    vertices[0] = b2.Vec2(x = -2.0, y = 0.0)
    vertices[1] = b2.Vec2(x = 1.0, y = 2.0)
    vertices[2] = b2.Vec2(x = 0.0, y = 4.0)
    hull = b2.compute_hull(const_ptr_of(vertices[0]), 3)
    let ship2_left = b2.make_polygon(const_ptr_of(hull), 0.0)
    vertices[0] = b2.Vec2(x = 2.0, y = 0.0)
    vertices[1] = b2.Vec2(x = -1.0, y = 2.0)
    vertices[2] = b2.Vec2(x = 0.0, y = 4.0)
    hull = b2.compute_hull(const_ptr_of(vertices[0]), 3)
    let ship2_right = b2.make_polygon(const_ptr_of(hull), 0.0)
    b2.create_polygon_shape(sample.ship2_id, shape_def, ship2_left)
    b2.create_polygon_shape(sample.ship2_id, shape_def, ship2_right)

    return sample

extending CompoundShapes:
    editable function spawn() -> void:
        var table_def = b2.default_body_def()
        table_def.type = b2.BodyType.b2_dynamicBody
        table_def.position = b2.body_get_position(this.table1_id)
        table_def.rotation = b2.body_get_rotation(this.table1_id)
        let table1_body = b2.create_body(this.world, table_def)
        let box1 = b2.make_offset_box(4.0, 0.1, b2.Vec2(x = 0.0, y = 3.0), b2.b2Rot_identity)
        b2.create_polygon_shape(table1_body, b2.default_shape_def(), box1)

        table_def = b2.default_body_def()
        table_def.type = b2.BodyType.b2_dynamicBody
        table_def.position = b2.body_get_position(this.table2_id)
        table_def.rotation = b2.body_get_rotation(this.table2_id)
        let table2_body = b2.create_body(this.world, table_def)
        let box2 = b2.make_offset_box(4.0, 0.1, b2.Vec2(x = 0.0, y = 3.0), b2.b2Rot_identity)
        b2.create_polygon_shape(table2_body, b2.default_shape_def(), box2)

        var ship_def = b2.default_body_def()
        ship_def.type = b2.BodyType.b2_dynamicBody
        ship_def.position = b2.body_get_position(this.ship1_id)
        ship_def.rotation = b2.body_get_rotation(this.ship1_id)
        let ship1_body = b2.create_body(this.world, ship_def)
        let circle = b2.Circle(center = b2.Vec2(x = 0.0, y = 2.0), radius = 0.5)
        b2.create_circle_shape(ship1_body, b2.default_shape_def(), circle)

        ship_def = b2.default_body_def()
        ship_def.type = b2.BodyType.b2_dynamicBody
        ship_def.position = b2.body_get_position(this.ship2_id)
        ship_def.rotation = b2.body_get_rotation(this.ship2_id)
        let ship2_body = b2.create_body(this.world, ship_def)
        b2.create_circle_shape(ship2_body, b2.default_shape_def(), circle)

    editable function on_step() -> void:
        if rl.is_key_pressed(rl.KeyboardKey.KEY_I):
            this.spawn()
        if rl.is_key_pressed(rl.KeyboardKey.KEY_A):
            this.draw_body_aabbs = not this.draw_body_aabbs

    function draw_overlay() -> void:
        if this.draw_body_aabbs:
            common.draw_world_aabb(b2.body_compute_aabb(this.table1_id), b2.HexColor.b2_colorYellow)
            common.draw_world_aabb(b2.body_compute_aabb(this.table2_id), b2.HexColor.b2_colorYellow)
            common.draw_world_aabb(b2.body_compute_aabb(this.ship1_id), b2.HexColor.b2_colorYellow)
            common.draw_world_aabb(b2.body_compute_aabb(this.ship2_id), b2.HexColor.b2_colorYellow)
        common.draw_text_line("I: intrude  A: toggle body AABBs")

function main() -> int:
    let world_id = common.create_world()
    var sample = compound_shapes_create(world_id)
    return common.run(
        adapt[common.Sample](ref_of(sample)),
        "Box2D - Compound Shapes",
        b2.Vec2(x = 0.0, y = 6.0),
        25.0 * 0.5,
        world_id
    )
