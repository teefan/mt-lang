## Box2D sample port: "Bounce House" (from box2d-upstream/samples/sample_continuous.cpp).
##
## A high-speed body bounces inside a box of segments. Contact hit events are
## collected and the four most recent impacts are drawn with their approach
## speed.
##   1 / 2 / 3     circle / capsule / box
##   H             toggle hit events
##   Space         relaunch the body
##   Left mouse    drag bodies (mouse joint)
##   P             pause, Space single-step

import std.box2d as b2
import std.raylib as rl
import examples.box2d.common as common

enum ShapeKind:
    circle
    capsule
    box

struct HitEvent:
    point: b2.Vec2
    speed: float
    step_index: int

struct BounceHouse implements common.Sample:
    world: b2.WorldId
    body_id: b2.BodyId
    shape_kind: ShapeKind
    enable_hit_events: bool
    hit_events: array[HitEvent, 4]
    step_count: int

function bounce_house_create(world_id: b2.WorldId) -> BounceHouse:
    let ground = b2.create_body(world_id, b2.default_body_def())
    let shape_def = b2.default_shape_def()
    var segment = b2.Segment(
        point1 = b2.Vec2(x = -10.0, y = -10.0),
        point2 = b2.Vec2(x = 10.0, y = -10.0)
    )
    b2.create_segment_shape(ground, shape_def, segment)
    segment = b2.Segment(
        point1 = b2.Vec2(x = 10.0, y = -10.0),
        point2 = b2.Vec2(x = 10.0, y = 10.0)
    )
    b2.create_segment_shape(ground, shape_def, segment)
    segment = b2.Segment(
        point1 = b2.Vec2(x = 10.0, y = 10.0),
        point2 = b2.Vec2(x = -10.0, y = 10.0)
    )
    b2.create_segment_shape(ground, shape_def, segment)
    segment = b2.Segment(
        point1 = b2.Vec2(x = -10.0, y = 10.0),
        point2 = b2.Vec2(x = -10.0, y = -10.0)
    )
    b2.create_segment_shape(ground, shape_def, segment)

    var sample = BounceHouse(
        world = world_id,
        body_id = b2.b2_nullBodyId,
        shape_kind = ShapeKind.box,
        enable_hit_events = true,
        hit_events = zero[array[HitEvent, 4]],
        step_count = 0
    )
    sample.launch()
    return sample

extending BounceHouse:
    editable function launch() -> void:
        if this.body_id != b2.b2_nullBodyId:
            b2.destroy_body(this.body_id)

        var body_def = b2.default_body_def()
        body_def.type = b2.BodyType.b2_dynamicBody
        body_def.linearVelocity = b2.Vec2(x = 10.0, y = 20.0)
        body_def.position = b2.Vec2(x = 0.0, y = 0.0)
        body_def.gravityScale = 0.0
        body_def.allowFastRotation = this.shape_kind == ShapeKind.circle
        this.body_id = b2.create_body(this.world, body_def)

        var shape_def = b2.default_shape_def()
        shape_def.density = 1.0
        shape_def.material.restitution = 1.2
        shape_def.material.friction = 0.3
        shape_def.enableHitEvents = this.enable_hit_events

        match this.shape_kind:
            ShapeKind.circle:
                let circle = b2.Circle(center = b2.Vec2(x = 0.0, y = 0.0), radius = 0.5)
                b2.create_circle_shape(this.body_id, shape_def, circle)
            ShapeKind.capsule:
                let capsule = b2.Capsule(
                    center1 = b2.Vec2(x = -0.5, y = 0.0),
                    center2 = b2.Vec2(x = 0.5, y = 0.0),
                    radius = 0.25
                )
                b2.create_capsule_shape(this.body_id, shape_def, capsule)
            ShapeKind.box:
                let box = b2.make_box(2.0, 0.1)
                b2.create_polygon_shape(this.body_id, shape_def, box)

    editable function on_step() -> void:
        if rl.is_key_pressed(rl.KeyboardKey.KEY_ONE):
            this.shape_kind = ShapeKind.circle
            this.launch()
        if rl.is_key_pressed(rl.KeyboardKey.KEY_TWO):
            this.shape_kind = ShapeKind.capsule
            this.launch()
        if rl.is_key_pressed(rl.KeyboardKey.KEY_THREE):
            this.shape_kind = ShapeKind.box
            this.launch()
        if rl.is_key_pressed(rl.KeyboardKey.KEY_H):
            this.enable_hit_events = not this.enable_hit_events
            b2.body_enable_hit_events(this.body_id, this.enable_hit_events)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            this.launch()

        let events = b2.world_get_contact_events(this.world)
        var index = 0
        while index < events.hitCount:
            unsafe:
                let hit_event = read(events.hitEvents + ptr_uint<-index)
                var oldest = 0
                var slot = 1
                while slot < 4:
                    if this.hit_events[slot].step_index < this.hit_events[oldest].step_index:
                        oldest = slot
                    slot += 1
                this.hit_events[oldest].point = hit_event.point
                this.hit_events[oldest].speed = hit_event.approachSpeed
                this.hit_events[oldest].step_index = this.step_count
            index += 1
        this.step_count += 1

    function shape_label() -> str:
        return match this.shape_kind:
            ShapeKind.circle: "circle"
            ShapeKind.capsule: "capsule"
            ShapeKind.box: "box"

    function draw_overlay() -> void:
        var index = 0
        while index < 4:
            let e = this.hit_events[index]
            if e.step_index > 0 and this.step_count <= e.step_index + 30:
                common.draw_world_circle(e.point, 0.1, b2.HexColor.b2_colorOrangeRed)
                common.draw_world_string(e.point, f"#{e.speed:.1}", b2.HexColor.b2_colorOrangeRed)
            index += 1
        common.draw_text_line(f"shape = #{this.shape_label()} hit events = #{this.enable_hit_events}")
        common.draw_text_line("1/2/3: shape  H: hit events  Space: launch")

function main() -> int:
    let world_id = common.create_world()
    var sample = bounce_house_create(world_id)
    return common.run(
        adapt[common.Sample](ref_of(sample)),
        "Box2D - Bounce House",
        b2.Vec2(x = 0.0, y = 0.0),
        25.0 * 0.45,
        world_id
    )
