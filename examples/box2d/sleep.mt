## Box2D sample port: "Sleep" (from box2d-upstream/samples/sample_bodies.cpp).
##
## Demonstrates body sleeping: bodies spawned asleep, sleep-disabled bodies,
## a long damped pendulum, sensors that detect ground touch, and a static
## body whose creation wakes a sleeping neighbor.
##   , / .         pendulum sleep velocity
##   - / =         pendulum angular damping
##   C             create / destroy the static invoker body
##   Left mouse    drag bodies (mouse joint)
##   P             pause, Space single-step

import std.box2d as b2
import std.raylib as rl
import examples.box2d.common as common

struct Sleep implements common.Sample:
    world: b2.WorldId
    pendulum_id: b2.BodyId
    static_body_id: b2.BodyId
    ground_shape_id: b2.ShapeId
    sensor_ids: array[b2.ShapeId, 2]
    sensor_touching: array[bool, 2]
    sleep_velocity: float
    angular_damping: float

function sleep_create(world_id: b2.WorldId) -> Sleep:
    let ground = b2.create_body(world_id, b2.default_body_def())
    var ground_shape_def = b2.default_shape_def()
    ground_shape_def.enableSensorEvents = true
    let segment = b2.Segment(
        point1 = b2.Vec2(x = -40.0, y = 0.0),
        point2 = b2.Vec2(x = 40.0, y = 0.0)
    )
    let ground_shape_id = b2.create_segment_shape(ground, ground_shape_def, segment)

    var sample = Sleep(
        world = world_id,
        pendulum_id = b2.b2_nullBodyId,
        static_body_id = b2.b2_nullBodyId,
        ground_shape_id = ground_shape_id,
        sensor_ids = zero[array[b2.ShapeId, 2]],
        sensor_touching = zero[array[bool, 2]],
        sleep_velocity = 0.05,
        angular_damping = 0.5
    )

    # two bodies created asleep with attached sensors
    var body_def = b2.default_body_def()
    body_def.type = b2.BodyType.b2_dynamicBody
    body_def.isAwake = false
    body_def.enableSleep = true
    var sensor_shape_def = b2.default_shape_def()
    var capsule = b2.Capsule(
        center1 = b2.Vec2(x = 0.0, y = 1.0),
        center2 = b2.Vec2(x = 1.0, y = 1.0),
        radius = 0.75
    )
    var index = 0
    while index < 2:
        body_def.position = b2.Vec2(x = -4.0, y = 3.0 + 2.0 * (index))
        let body = b2.create_body(world_id, body_def)
        b2.create_capsule_shape(body, sensor_shape_def, capsule)
        sensor_shape_def.isSensor = true
        sensor_shape_def.enableSensorEvents = true
        capsule = b2.Capsule(
            center1 = b2.Vec2(x = 0.0, y = 1.0),
            center2 = b2.Vec2(x = 1.0, y = 1.0),
            radius = 1.0
        )
        sample.sensor_ids[index] = b2.create_capsule_shape(body, sensor_shape_def, capsule)
        index += 1

    # sleeping body but sleep is disabled
    body_def = b2.default_body_def()
    body_def.type = b2.BodyType.b2_dynamicBody
    body_def.position = b2.Vec2(x = 0.0, y = 3.0)
    body_def.isAwake = false
    body_def.enableSleep = false
    let no_sleep_body = b2.create_body(world_id, body_def)
    let circle = b2.Circle(center = b2.Vec2(x = 1.0, y = 1.0), radius = 1.0)
    b2.create_circle_shape(no_sleep_body, sensor_shape_def, circle)

    # awake body and sleep is disabled
    body_def = b2.default_body_def()
    body_def.type = b2.BodyType.b2_dynamicBody
    body_def.position = b2.Vec2(x = 5.0, y = 3.0)
    body_def.isAwake = true
    body_def.enableSleep = false
    let no_sleep_awake = b2.create_body(world_id, body_def)
    let offset_box = b2.make_offset_box(1.0, 1.0, b2.Vec2(x = 0.0, y = 1.0), common.make_rot(0.25 * b2.B2_PI))
    b2.create_polygon_shape(no_sleep_awake, sensor_shape_def, offset_box)

    # sleeping body to test waking on collision
    body_def = b2.default_body_def()
    body_def.type = b2.BodyType.b2_dynamicBody
    body_def.position = b2.Vec2(x = 5.0, y = 1.0)
    body_def.isAwake = false
    body_def.enableSleep = true
    let wake_body = b2.create_body(world_id, body_def)
    let square = b2.make_square(1.0)
    b2.create_polygon_shape(wake_body, sensor_shape_def, square)

    # long pendulum
    body_def = b2.default_body_def()
    body_def.type = b2.BodyType.b2_dynamicBody
    body_def.position = b2.Vec2(x = 0.0, y = 100.0)
    body_def.angularDamping = sample.angular_damping
    body_def.sleepThreshold = sample.sleep_velocity
    sample.pendulum_id = b2.create_body(world_id, body_def)
    let pendulum_capsule = b2.Capsule(
        center1 = b2.Vec2(x = 0.0, y = 0.0),
        center2 = b2.Vec2(x = 90.0, y = 0.0),
        radius = 0.25
    )
    b2.create_capsule_shape(sample.pendulum_id, sensor_shape_def, pendulum_capsule)
    let pendulum_pivot = body_def.position
    var joint_def = b2.default_revolute_joint_def()
    joint_def.bodyIdA = ground
    joint_def.bodyIdB = sample.pendulum_id
    joint_def.localAnchorA = b2.body_get_local_point(ground, pendulum_pivot)
    joint_def.localAnchorB = b2.body_get_local_point(sample.pendulum_id, pendulum_pivot)
    b2.create_revolute_joint(world_id, joint_def)

    # sleeping body to test waking on contact destroyed
    body_def = b2.default_body_def()
    body_def.type = b2.BodyType.b2_dynamicBody
    body_def.position = b2.Vec2(x = -10.0, y = 1.0)
    body_def.isAwake = false
    body_def.enableSleep = true
    let contact_destroy_body = b2.create_body(world_id, body_def)
    b2.create_polygon_shape(contact_destroy_body, sensor_shape_def, square)

    return sample

extending Sleep:
    editable function toggle_invoker() -> void:
        if this.static_body_id == b2.b2_nullBodyId:
            var body_def = b2.default_body_def()
            body_def.position = b2.Vec2(x = -10.5, y = 3.0)
            this.static_body_id = b2.create_body(this.world, body_def)
            let box = b2.make_offset_box(2.0, 0.1, b2.Vec2(x = 0.0, y = 0.0), common.make_rot(0.25 * b2.B2_PI))
            var shape_def = b2.default_shape_def()
            shape_def.invokeContactCreation = true
            b2.create_polygon_shape(this.static_body_id, shape_def, box)
        else:
            b2.destroy_body(this.static_body_id)
            this.static_body_id = b2.b2_nullBodyId

    editable function on_step() -> void:
        let sensor_events = b2.world_get_sensor_events(this.world)
        var index = 0
        while index < sensor_events.beginCount:
            unsafe:
                let hit_event = read(sensor_events.beginEvents + ptr_uint<-index)
                if hit_event.visitorShapeId == this.ground_shape_id:
                    if hit_event.sensorShapeId == this.sensor_ids[0]:
                        this.sensor_touching[0] = true
                    else if hit_event.sensorShapeId == this.sensor_ids[1]:
                        this.sensor_touching[1] = true
            index += 1
        index = 0
        while index < sensor_events.endCount:
            unsafe:
                let hit_event = read(sensor_events.endEvents + ptr_uint<-index)
                if hit_event.visitorShapeId == this.ground_shape_id:
                    if hit_event.sensorShapeId == this.sensor_ids[0]:
                        this.sensor_touching[0] = false
                    else if hit_event.sensorShapeId == this.sensor_ids[1]:
                        this.sensor_touching[1] = false
            index += 1

        if rl.is_key_pressed(rl.KeyboardKey.KEY_C):
            this.toggle_invoker()
        if rl.is_key_pressed(rl.KeyboardKey.KEY_COMMA):
            this.sleep_velocity = common.max_float(this.sleep_velocity - 0.05, 0.0)
            b2.body_set_sleep_threshold(this.pendulum_id, this.sleep_velocity)
            b2.body_set_awake(this.pendulum_id, true)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_PERIOD):
            this.sleep_velocity = common.min_float(this.sleep_velocity + 0.05, 1.0)
            b2.body_set_sleep_threshold(this.pendulum_id, this.sleep_velocity)
            b2.body_set_awake(this.pendulum_id, true)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_MINUS):
            this.angular_damping = common.max_float(this.angular_damping - 0.1, 0.0)
            b2.body_set_angular_damping(this.pendulum_id, this.angular_damping)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_EQUAL):
            this.angular_damping = common.min_float(this.angular_damping + 0.1, 2.0)
            b2.body_set_angular_damping(this.pendulum_id, this.angular_damping)

    function draw_overlay() -> void:
        var index = 0
        while index < 2:
            common.draw_text_line(f"sensor touch #{index} = #{this.sensor_touching[index]}")
            index += 1
        common.draw_text_line(f"sleep velocity = #{this.sleep_velocity:.2}")
        common.draw_text_line(f"angular damping = #{this.angular_damping:.2}")
        common.draw_text_line("C: invoker  ,/.: sleep  -/=: damping")

function main() -> int:
    let world_id = common.create_world()
    var sample = sleep_create(world_id)
    return common.run(
        adapt[common.Sample](ref_of(sample)),
        "Box2D - Sleep",
        b2.Vec2(x = 3.0, y = 50.0),
        25.0 * 2.2,
        world_id
    )
