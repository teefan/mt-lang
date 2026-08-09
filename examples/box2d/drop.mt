## Box2D sample port: "Drop" (from box2d-upstream/samples/sample_continuous.cpp).
##
## Four scenes stress continuous collision with high-speed bodies:
##   Scene 1: a fast ball onto a saw-tooth ground
##   Scene 2: a spinning ruler onto a flat ground
##   Scene 3: a ragdoll dropped from height
##   Scene 4: a fast bullet into a stack of boxes against a wall
##   1 / 2 / 3 / 4     switch scene
##   C                 toggle continuous collision
##   V                 toggle speculative collision
##   Left mouse    drag bodies (mouse joint)
##   P             pause, Space single-step

import std.box2d as b2
import std.raylib as rl
import examples.box2d.common as common
import examples.box2d.human as human

const MAX_GROUND_BODIES: int = 4
const MAX_BODIES: int = 16

struct Drop implements common.Sample:
    world: b2.WorldId
    ground_ids: array[b2.BodyId, MAX_GROUND_BODIES]
    ground_count: int
    body_ids: array[b2.BodyId, MAX_BODIES]
    body_count: int
    person: human.Human
    continuous: bool
    speculative: bool

function drop_create(world_id: b2.WorldId) -> Drop:
    var sample = Drop(
        world = world_id,
        ground_ids = zero[array[b2.BodyId, MAX_GROUND_BODIES]],
        ground_count = 0,
        body_ids = zero[array[b2.BodyId, MAX_BODIES]],
        body_count = 0,
        person = human.Human(
            bones = zero[array[human.Bone, human.BONE_COUNT]],
            friction_torque = 0.0,
            scale = 0.0,
            spawned = false
        ),
        continuous = true,
        speculative = true
    )
    b2.world_enable_sleeping(world_id, false)
    b2.world_enable_continuous(world_id, true)
    b2.world_enable_speculative(world_id, true)
    sample.scene1()
    return sample

extending Drop:
    editable function clear() -> void:
        var index = 0
        while index < this.body_count:
            b2.destroy_body(this.body_ids[index])
            this.body_ids[index] = b2.b2_nullBodyId
            index += 1
        this.body_count = 0
        if this.person.spawned:
            human.destroy_human(ref_of(this.person))

    editable function destroy_grounds() -> void:
        var index = 0
        while index < this.ground_count:
            b2.destroy_body(this.ground_ids[index])
            this.ground_ids[index] = b2.b2_nullBodyId
            index += 1
        this.ground_count = 0

    editable function add_ground(ground: b2.BodyId) -> void:
        this.ground_ids[this.ground_count] = ground
        this.ground_count += 1

    editable function create_ground1() -> void:
        this.destroy_grounds()
        let ground = b2.create_body(this.world, b2.default_body_def())
        let segment = b2.Segment(
            point1 = b2.Vec2(x = -5.0, y = 0.0),
            point2 = b2.Vec2(x = 5.0, y = 0.0)
        )
        b2.create_segment_shape(ground, b2.default_shape_def(), segment)
        this.add_ground(ground)

    editable function create_ground2() -> void:
        this.destroy_grounds()
        let ground = b2.create_body(this.world, b2.default_body_def())
        let w = 0.25
        let h = 0.05
        var x = -0.5 * 40.0 * w
        let count = 41
        var index = 0
        while index < count:
            let box = b2.make_offset_box(0.5 * w, h, b2.Vec2(x = x, y = 0.0), b2.b2Rot_identity)
            b2.create_polygon_shape(ground, b2.default_shape_def(), box)
            x += w
            index += 1
        this.add_ground(ground)

    editable function create_ground3() -> void:
        this.destroy_grounds()
        let ground = b2.create_body(this.world, b2.default_body_def())
        var segment = b2.Segment(
            point1 = b2.Vec2(x = -5.0, y = 0.0),
            point2 = b2.Vec2(x = 5.0, y = 0.0)
        )
        b2.create_segment_shape(ground, b2.default_shape_def(), segment)
        segment = b2.Segment(
            point1 = b2.Vec2(x = 3.0, y = 0.0),
            point2 = b2.Vec2(x = 3.0, y = 8.0)
        )
        b2.create_segment_shape(ground, b2.default_shape_def(), segment)
        this.add_ground(ground)

    editable function scene1() -> void:
        this.clear()
        this.create_ground2()
        var body_def = b2.default_body_def()
        body_def.type = b2.BodyType.b2_dynamicBody
        body_def.position = b2.Vec2(x = 0.0, y = 4.0)
        body_def.linearVelocity = b2.Vec2(x = 0.0, y = -100.0)
        let body = b2.create_body(this.world, body_def)
        let circle = b2.Circle(center = b2.Vec2(x = 0.0, y = 0.0), radius = 0.125)
        b2.create_circle_shape(body, b2.default_shape_def(), circle)
        this.body_ids[this.body_count] = body
        this.body_count += 1

    editable function scene2() -> void:
        this.clear()
        this.create_ground1()
        var body_def = b2.default_body_def()
        body_def.type = b2.BodyType.b2_dynamicBody
        body_def.position = b2.Vec2(x = 0.0, y = 4.0)
        body_def.rotation = common.make_rot(0.5 * b2.B2_PI)
        body_def.angularVelocity = -0.5
        let body = b2.create_body(this.world, body_def)
        let box = b2.make_box(0.75, 0.01)
        b2.create_polygon_shape(body, b2.default_shape_def(), box)
        this.body_ids[this.body_count] = body
        this.body_count += 1

    editable function scene3() -> void:
        this.clear()
        this.create_ground2()
        this.person = human.create_human(this.world, b2.Vec2(x = 0.0, y = 40.0), 1.0, 0.03, 1.0, 0.5, 1)

    editable function scene4() -> void:
        this.clear()
        this.create_ground3()
        let a = 0.25
        let box = b2.make_square(a)
        var shape_def = b2.default_shape_def()
        let offset = 0.01
        var index = 0
        while index < 5:
            var body_def = b2.default_body_def()
            body_def.type = b2.BodyType.b2_dynamicBody
            let shift = if index % 2 == 0: -offset else: offset
            body_def.position = b2.Vec2(x = 2.5 + shift, y = a + 2.0 * a * (index))
            let body = b2.create_body(this.world, body_def)
            b2.create_polygon_shape(body, shape_def, box)
            this.body_ids[this.body_count] = body
            this.body_count += 1
            index += 1

        var bullet_def = b2.default_body_def()
        bullet_def.type = b2.BodyType.b2_dynamicBody
        bullet_def.position = b2.Vec2(x = -7.7, y = 1.9)
        bullet_def.linearVelocity = b2.Vec2(x = 200.0, y = 0.0)
        bullet_def.isBullet = true
        let bullet = b2.create_body(this.world, bullet_def)
        let circle = b2.Circle(center = b2.Vec2(x = 0.0, y = 0.0), radius = 0.125)
        shape_def.density = 4.0
        b2.create_circle_shape(bullet, shape_def, circle)
        this.body_ids[this.body_count] = bullet
        this.body_count += 1

    editable function on_step() -> void:
        if rl.is_key_pressed(rl.KeyboardKey.KEY_ONE):
            this.scene1()
        if rl.is_key_pressed(rl.KeyboardKey.KEY_TWO):
            this.scene2()
        if rl.is_key_pressed(rl.KeyboardKey.KEY_THREE):
            this.scene3()
        if rl.is_key_pressed(rl.KeyboardKey.KEY_FOUR):
            this.scene4()
        if rl.is_key_pressed(rl.KeyboardKey.KEY_C):
            this.continuous = not this.continuous
            b2.world_enable_continuous(this.world, this.continuous)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_V):
            this.speculative = not this.speculative
            b2.world_enable_speculative(this.world, this.speculative)

    function draw_overlay() -> void:
        common.draw_text_line(f"continuous = #{this.continuous} speculative = #{this.speculative}")
        common.draw_text_line("1/2/3/4: scene  C: continuous  V: speculative")

function main() -> int:
    let world_id = common.create_world()
    var sample = drop_create(world_id)
    return common.run(
        adapt[common.Sample](ref_of(sample)),
        "Box2D - Drop",
        b2.Vec2(x = 0.0, y = 1.5),
        3.0,
        world_id
    )
