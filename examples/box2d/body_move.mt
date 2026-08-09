## Box2D sample port: "Body Move" (from box2d-upstream/samples/sample_events.cpp).
##
## Bodies are dropped in batches into a sloped arena. Each frame the body move
## events are processed: every moved body's transform is drawn and the sleeping
## bodies are tracked.
##   Space         explode
##   - / =         adjust explosion magnitude
##   Left mouse    drag bodies (mouse joint)
##   P             pause, Space single-step

import std.box2d as b2
import std.raylib as rl
import examples.box2d.common as common

const MAX_BODIES: int = 50
const MAX_TRANSFORMS: int = 64

struct BodyMove implements common.Sample:
    world: b2.WorldId
    body_ids: array[b2.BodyId, MAX_BODIES]
    sleeping: array[bool, MAX_BODIES]
    count: int
    sleep_count: int
    step_count: int
    move_transforms: array[b2.Transform, MAX_TRANSFORMS]
    move_transform_count: int
    explosion_position: b2.Vec2
    explosion_radius: float
    explosion_magnitude: float

function body_move_create(world_id: b2.WorldId) -> BodyMove:
    let ground = b2.create_body(world_id, b2.default_body_def())
    var shape_def = b2.default_shape_def()
    shape_def.material.friction = 0.1
    var box = b2.make_offset_box(12.0, 0.1, b2.Vec2(x = -10.0, y = -0.1), common.make_rot(-0.15 * b2.B2_PI))
    b2.create_polygon_shape(ground, shape_def, box)
    box = b2.make_offset_box(12.0, 0.1, b2.Vec2(x = 10.0, y = -0.1), common.make_rot(0.15 * b2.B2_PI))
    b2.create_polygon_shape(ground, shape_def, box)
    shape_def.material.restitution = 0.8
    box = b2.make_offset_box(0.1, 10.0, b2.Vec2(x = 19.9, y = 10.0), b2.b2Rot_identity)
    b2.create_polygon_shape(ground, shape_def, box)
    box = b2.make_offset_box(0.1, 10.0, b2.Vec2(x = -19.9, y = 10.0), b2.b2Rot_identity)
    b2.create_polygon_shape(ground, shape_def, box)
    box = b2.make_offset_box(20.0, 0.1, b2.Vec2(x = 0.0, y = 20.1), b2.b2Rot_identity)
    b2.create_polygon_shape(ground, shape_def, box)

    return BodyMove(
        world = world_id,
        body_ids = zero[array[b2.BodyId, MAX_BODIES]],
        sleeping = zero[array[bool, MAX_BODIES]],
        count = 0,
        sleep_count = 0,
        step_count = 0,
        move_transforms = zero[array[b2.Transform, MAX_TRANSFORMS]],
        move_transform_count = 0,
        explosion_position = b2.Vec2(x = 0.0, y = -5.0),
        explosion_radius = 10.0,
        explosion_magnitude = 10.0
    )

extending BodyMove:
    editable function create_bodies() -> void:
        let capsule = b2.Capsule(
            center1 = b2.Vec2(x = -0.25, y = 0.0),
            center2 = b2.Vec2(x = 0.25, y = 0.0),
            radius = 0.25
        )
        let circle = b2.Circle(center = b2.b2Vec2_zero, radius = 0.35)
        let square = b2.make_square(0.35)
        var body_def = b2.default_body_def()
        body_def.type = b2.BodyType.b2_dynamicBody
        let shape_def = b2.default_shape_def()

        var x = -5.0
        var index = 0
        while index < 10 and this.count < MAX_BODIES:
            body_def.position = b2.Vec2(x = x, y = 10.0)
            body_def.isBullet = this.count % 12 == 0
            let body = b2.create_body(this.world, body_def)
            this.body_ids[this.count] = body
            this.sleeping[this.count] = false
            let remainder = this.count % 4
            if remainder == 0:
                b2.create_capsule_shape(body, shape_def, capsule)
            else if remainder == 1:
                b2.create_circle_shape(body, shape_def, circle)
            else if remainder == 2:
                b2.create_polygon_shape(body, shape_def, square)
            else:
                var poly = common.random_polygon(0.75)
                poly.radius = 0.1
                b2.create_polygon_shape(body, shape_def, poly)
            this.count += 1
            x += 1.0
            index += 1

    editable function explode() -> void:
        var explosion_def = b2.default_explosion_def()
        explosion_def.position = this.explosion_position
        explosion_def.radius = this.explosion_radius
        explosion_def.falloff = 0.1
        explosion_def.impulsePerLength = this.explosion_magnitude
        b2.world_explode(this.world, explosion_def)

    editable function on_step() -> void:
        if not common.paused() and this.step_count % 16 == 15 and this.count < MAX_BODIES:
            this.create_bodies()

        this.move_transform_count = 0
        let events = b2.world_get_body_events(this.world)
        var index = 0
        while index < events.moveCount:
            unsafe:
                let move_event = read(events.moveEvents + ptr_uint<-index)
                if this.move_transform_count < MAX_TRANSFORMS:
                    this.move_transforms[this.move_transform_count] = move_event.transform
                    this.move_transform_count += 1
                let body_index = this.find_body_index(move_event.bodyId)
                if body_index >= 0:
                    if move_event.fellAsleep:
                        this.sleeping[body_index] = true
                        this.sleep_count += 1
                    else:
                        if this.sleeping[body_index]:
                            this.sleeping[body_index] = false
                            this.sleep_count -= 1
            index += 1

        if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            this.explode()
        if rl.is_key_pressed(rl.KeyboardKey.KEY_MINUS):
            this.explosion_magnitude = common.max_float(this.explosion_magnitude - 1.0, -20.0)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_EQUAL):
            this.explosion_magnitude = common.min_float(this.explosion_magnitude + 1.0, 20.0)
        this.step_count += 1

    function find_body_index(body_id: b2.BodyId) -> int:
        var index = 0
        while index < this.count:
            if this.body_ids[index] == body_id:
                return index
            index += 1
        return -1

    function draw_overlay() -> void:
        var index = 0
        while index < this.move_transform_count:
            common.draw_world_transform(this.move_transforms[index])
            index += 1
        common.draw_world_circle(this.explosion_position, this.explosion_radius, b2.HexColor.b2_colorAzure)
        common.draw_text_line(f"sleep count = #{this.sleep_count}")
        common.draw_text_line("Space: explode  -/=: magnitude")

function main() -> int:
    let world_id = common.create_world()
    var sample = body_move_create(world_id)
    return common.run(
        adapt[common.Sample](ref_of(sample)),
        "Box2D - Body Move",
        b2.Vec2(x = 2.0, y = 8.0),
        25.0 * 0.55,
        world_id
    )
