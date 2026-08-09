## Box2D sample port: "Circle Stack" (from box2d-upstream/samples/sample_stacking.cpp).
##
## A stack of ten circles with increasing density that falls onto a ground
## segment. Contact hit events are collected each step and drawn as white
## points with the pair of shape indices listed as overlay text.
##   Left mouse    drag bodies (mouse joint)
##   P             pause, Space single-step

import std.box2d as b2
import examples.box2d.common as common

const CIRCLE_COUNT: int = 10
const SHAPE_COUNT: int = CIRCLE_COUNT + 1
const MAX_EVENTS: int = 256

struct CircleStack implements common.Sample:
    world: b2.WorldId
    shape_ids: array[b2.ShapeId, SHAPE_COUNT]
    event_index_a: array[int, MAX_EVENTS]
    event_index_b: array[int, MAX_EVENTS]
    event_count: int

function circle_stack_create(world_id: b2.WorldId) -> CircleStack:
    b2.world_set_gravity(world_id, b2.Vec2(x = 0.0, y = -20.0))
    b2.world_set_contact_tuning(world_id, 0.25 * 360.0, 10.0, 3.0)

    var body_def = b2.default_body_def()
    let ground = b2.create_body(world_id, body_def)

    var shape_def = b2.default_shape_def()
    let segment = b2.Segment(
        point1 = b2.Vec2(x = -10.0, y = 0.0),
        point2 = b2.Vec2(x = 10.0, y = 0.0)
    )
    let ground_shape = b2.create_segment_shape(ground, shape_def, segment)

    var sample = CircleStack(
        world = world_id,
        shape_ids = zero[array[b2.ShapeId, SHAPE_COUNT]],
        event_index_a = zero[array[int, MAX_EVENTS]],
        event_index_b = zero[array[int, MAX_EVENTS]],
        event_count = 0
    )
    sample.shape_ids[0] = ground_shape

    body_def.type = b2.BodyType.b2_dynamicBody
    shape_def = b2.default_shape_def()
    shape_def.enableHitEvents = true
    shape_def.material.friction = 0.0

    let circle = b2.Circle(center = b2.Vec2(x = 0.0, y = 0.0), radius = 0.5)

    var y = 0.75
    var index = 0
    while index < CIRCLE_COUNT:
        body_def.position = b2.Vec2(x = 0.0, y = y)
        let body = b2.create_body(world_id, body_def)
        shape_def.density = 1.0 + 4.0 * index
        let shape_id = b2.create_circle_shape(body, shape_def, circle)
        sample.shape_ids[index + 1] = shape_id
        y += 1.25
        index += 1

    return sample

extending CircleStack:
    function find_shape_index(shape_id: b2.ShapeId) -> int:
        var index = 0
        while index < SHAPE_COUNT:
            if this.shape_ids[index] == shape_id:
                return index
            index += 1
        return -1

    editable function on_step() -> void:
        let events = b2.world_get_contact_events(this.world)
        var index = 0
        while index < events.hitCount:
            unsafe:
                let hit_event = read(events.hitEvents + ptr_uint<-index)
                let index_a = this.find_shape_index(hit_event.shapeIdA)
                let index_b = this.find_shape_index(hit_event.shapeIdB)
                common.draw_world_point(hit_event.point, 10.0, b2.HexColor.b2_colorWhite)
                if this.event_count < MAX_EVENTS:
                    this.event_index_a[this.event_count] = index_a
                    this.event_index_b[this.event_count] = index_b
                    this.event_count += 1
            index += 1

    function draw_overlay() -> void:
        var index = 0
        while index < this.event_count:
            common.draw_text_line(f"#{this.event_index_a[index]}, #{this.event_index_b[index]}")
            index += 1
        common.draw_text_line("hit events: shape index pairs")

function main() -> int:
    let world_id = common.create_world()
    var sample = circle_stack_create(world_id)
    return common.run(
        adapt[common.Sample](ref_of(sample)),
        "Box2D - Circle Stack",
        b2.Vec2(x = 0.0, y = 5.0),
        6.0,
        world_id
    )
