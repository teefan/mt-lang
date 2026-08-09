## Box2D sample port: "Sensor Funnel" (from box2d-upstream/samples/sample_events.cpp).
##
## Humans are dropped into a funnel of rotating paddles; when one touches the
## bottom sensor it is destroyed. Sensor events are deferred so destruction
## never invalidates the event shape ids.
##   Left mouse    drag bodies (mouse joint)
##   P             pause, Space single-step

import std.box2d as b2
import examples.box2d.common as common
import examples.box2d.human as human

const MAX_ELEMENTS: int = 8
const FUNNEL_COUNT: int = 20

const FUNNEL_POINTS: array[b2.Vec2, FUNNEL_COUNT] = array[b2.Vec2, FUNNEL_COUNT](
    b2.Vec2(x = -16.8672504, y = 31.088623),
    b2.Vec2(x = 16.8672485, y = 31.088623),
    b2.Vec2(x = 16.8672485, y = 17.1978741),
    b2.Vec2(x = 8.26824951, y = 11.906374),
    b2.Vec2(x = 16.8672485, y = 11.906374),
    b2.Vec2(x = 16.8672485, y = -0.661376953),
    b2.Vec2(x = 8.26824951, y = -5.953125),
    b2.Vec2(x = 16.8672485, y = -5.953125),
    b2.Vec2(x = 16.8672485, y = -13.229126),
    b2.Vec2(x = 3.63799858, y = -23.151123),
    b2.Vec2(x = 3.63799858, y = -31.088623),
    b2.Vec2(x = -3.63800049, y = -31.088623),
    b2.Vec2(x = -3.63800049, y = -23.151123),
    b2.Vec2(x = -16.8672504, y = -13.229126),
    b2.Vec2(x = -16.8672504, y = -5.953125),
    b2.Vec2(x = -8.26825142, y = -5.953125),
    b2.Vec2(x = -16.8672504, y = -0.661376953),
    b2.Vec2(x = -16.8672504, y = 11.906374),
    b2.Vec2(x = -8.26825142, y = 11.906374),
    b2.Vec2(x = -16.8672504, y = 17.1978741)
)

struct SensorFunnel implements common.Sample:
    world: b2.WorldId
    humans: array[human.Human, MAX_ELEMENTS]
    spawned: array[bool, MAX_ELEMENTS]
    wait: float
    side: float

function sensor_funnel_create(world_id: b2.WorldId) -> SensorFunnel:
    let ground = b2.create_body(world_id, b2.default_body_def())

    var material = b2.default_surface_material()
    material.friction = 0.2
    var chain_def = b2.default_chain_def()
    chain_def.points = const_ptr_of(FUNNEL_POINTS[0])
    chain_def.count = FUNNEL_COUNT
    chain_def.isLoop = true
    chain_def.materials = const_ptr_of(material)
    chain_def.materialCount = 1
    b2.create_chain(ground, chain_def)

    var body_def = b2.default_body_def()
    var paddle_shape = b2.default_shape_def()
    paddle_shape.material.friction = 0.1
    paddle_shape.material.restitution = 1.0
    paddle_shape.density = 1.0
    let paddle_box = b2.make_box(6.0, 0.5)

    var y = 14.0
    var sign = 1.0
    var index = 0
    while index < 3:
        body_def.position = b2.Vec2(x = 0.0, y = y)
        body_def.type = b2.BodyType.b2_dynamicBody
        let body = b2.create_body(world_id, body_def)
        b2.create_polygon_shape(body, paddle_shape, paddle_box)
        var revolute = b2.default_revolute_joint_def()
        revolute.bodyIdA = ground
        revolute.bodyIdB = body
        revolute.localAnchorA = body_def.position
        revolute.localAnchorB = b2.b2Vec2_zero
        revolute.maxMotorTorque = 200.0
        revolute.motorSpeed = 2.0 * sign
        revolute.enableMotor = true
        b2.create_revolute_joint(world_id, revolute)
        y -= 14.0
        sign = -sign
        index += 1

    let sensor_box = b2.make_offset_box(4.0, 1.0, b2.Vec2(x = 0.0, y = -30.5), b2.b2Rot_identity)
    var sensor_shape = b2.default_shape_def()
    sensor_shape.isSensor = true
    sensor_shape.enableSensorEvents = true
    b2.create_polygon_shape(ground, sensor_shape, sensor_box)

    var sample = SensorFunnel(
        world = world_id,
        humans = zero[array[human.Human, MAX_ELEMENTS]],
        spawned = zero[array[bool, MAX_ELEMENTS]],
        wait = 0.5,
        side = -15.0
    )
    sample.spawn_element()
    return sample

extending SensorFunnel:
    editable function spawn_element() -> void:
        var index = 0
        while index < MAX_ELEMENTS:
            if not this.spawned[index]:
                break
            index += 1
        if index == MAX_ELEMENTS:
            return
        let center = b2.Vec2(x = this.side, y = 29.5)
        this.humans[index] = human.create_human(this.world, center, 2.0, 0.05, 6.0, 0.5, index + 1)
        human.human_enable_sensor_events(ref_of(this.humans[index]), true)
        this.spawned[index] = true
        this.side = -this.side

    editable function destroy_element(index: int) -> void:
        human.destroy_human(ref_of(this.humans[index]))
        this.spawned[index] = false

    function find_human_index(body_id: b2.BodyId) -> int:
        var h = 0
        while h < MAX_ELEMENTS:
            if this.spawned[h]:
                var bone = 0
                while bone < human.BONE_COUNT:
                    if this.humans[h].bones[bone].body_id == body_id:
                        return h
                    bone += 1
            h += 1
        return -1

    editable function on_step() -> void:
        var deferred: array[bool, MAX_ELEMENTS] = zero[array[bool, MAX_ELEMENTS]]
        let sensor_events = b2.world_get_sensor_events(this.world)
        var index = 0
        while index < sensor_events.beginCount:
            unsafe:
                let hit_event = read(sensor_events.beginEvents + ptr_uint<-index)
                let body_id = b2.shape_get_body(hit_event.visitorShapeId)
                let human_index = this.find_human_index(body_id)
                if human_index >= 0:
                    deferred[human_index] = true
            index += 1
        index = 0
        while index < MAX_ELEMENTS:
            if deferred[index]:
                this.destroy_element(index)
            index += 1

        this.wait -= 1.0 / common.HERTZ
        if this.wait < 0.0:
            this.spawn_element()
            this.wait += 0.5

    function draw_overlay() -> void:
        common.draw_text_line("humans are destroyed when they touch the bottom sensor")

function main() -> int:
    let world_id = common.create_world()
    var sample = sensor_funnel_create(world_id)
    return common.run(
        adapt[common.Sample](ref_of(sample)),
        "Box2D - Sensor Funnel",
        b2.Vec2(x = 0.0, y = 0.0),
        25.0 * 1.333,
        world_id
    )
