## Box2D sample port: "Contact" (from box2d-upstream/samples/sample_events.cpp).
##
## A zero-gravity player circle driven with WASD collects debris on contact:
## each debris shape is copied onto the player and the debris body is
## destroyed. Contact begin events also reveal the contact manifold and
## impulse data, which is drawn on screen.
##   W / A / S / D     apply force to move the player
##   Left mouse    drag bodies (mouse joint)
##   P             pause, Space single-step

import std.box2d as b2
import std.raylib as rl
import examples.box2d.common as common

const DEBRIS_COUNT: int = 20
const CONTACT_CAPACITY: int = 8
const MAX_IMPULSE: int = 32

struct ImpulseSegment:
    p1: b2.Vec2
    p2: b2.Vec2

struct ContactEvent implements common.Sample:
    world: b2.WorldId
    player_id: b2.BodyId
    core_shape_id: b2.ShapeId
    debris_ids: array[b2.BodyId, DEBRIS_COUNT]
    impulse_segments: array[ImpulseSegment, MAX_IMPULSE]
    impulse_count: int
    force: float
    wait: float

function contact_event_create(world_id: b2.WorldId) -> ContactEvent:
    let ground = b2.create_body(world_id, b2.default_body_def())
    let wall_points: array[b2.Vec2, 4] = array[b2.Vec2, 4](
        b2.Vec2(x = 40.0, y = -40.0),
        b2.Vec2(x = -40.0, y = -40.0),
        b2.Vec2(x = -40.0, y = 40.0),
        b2.Vec2(x = 40.0, y = 40.0)
    )
    var chain_def = b2.default_chain_def()
    chain_def.count = 4
    chain_def.points = const_ptr_of(wall_points[0])
    chain_def.isLoop = true
    b2.create_chain(ground, chain_def)

    var body_def = b2.default_body_def()
    body_def.type = b2.BodyType.b2_dynamicBody
    body_def.gravityScale = 0.0
    body_def.linearDamping = 0.5
    body_def.angularDamping = 0.5
    body_def.isBullet = true
    let player = b2.create_body(world_id, body_def)

    let circle = b2.Circle(center = b2.b2Vec2_zero, radius = 1.0)
    var core_shape = b2.default_shape_def()
    core_shape.enableContactEvents = true
    let core_shape_id = b2.create_circle_shape(player, core_shape, circle)

    let sample = ContactEvent(
        world = world_id,
        player_id = player,
        core_shape_id = core_shape_id,
        debris_ids = zero[array[b2.BodyId, DEBRIS_COUNT]],
        impulse_segments = zero[array[ImpulseSegment, MAX_IMPULSE]],
        impulse_count = 0,
        force = 200.0,
        wait = 0.5
    )
    return sample

extending ContactEvent:
    editable function spawn_debris() -> void:
        var index = 0
        while index < DEBRIS_COUNT:
            if this.debris_ids[index] == b2.b2_nullBodyId:
                break
            index += 1
        if index == DEBRIS_COUNT:
            return

        var body_def = b2.default_body_def()
        body_def.type = b2.BodyType.b2_dynamicBody
        body_def.position = b2.Vec2(
            x = common.random_float_range(-38.0, 38.0),
            y = common.random_float_range(-38.0, 38.0)
        )
        body_def.rotation = common.make_rot(common.random_float_range(-b2.B2_PI, b2.B2_PI))
        body_def.linearVelocity = b2.Vec2(
            x = common.random_float_range(-5.0, 5.0),
            y = common.random_float_range(-5.0, 5.0)
        )
        body_def.angularVelocity = common.random_float_range(-1.0, 1.0)
        body_def.gravityScale = 0.0
        let body = b2.create_body(this.world, body_def)

        var shape_def = b2.default_shape_def()
        shape_def.material.restitution = 0.8
        if (index + 1) % 3 == 0:
            let debris_circle = b2.Circle(center = b2.b2Vec2_zero, radius = 0.5)
            b2.create_circle_shape(body, shape_def, debris_circle)
        else if (index + 1) % 2 == 0:
            let debris_capsule = b2.Capsule(
                center1 = b2.Vec2(x = 0.0, y = -0.25),
                center2 = b2.Vec2(x = 0.0, y = 0.25),
                radius = 0.25
            )
            b2.create_capsule_shape(body, shape_def, debris_capsule)
        else:
            let debris_box = b2.make_box(0.4, 0.6)
            b2.create_polygon_shape(body, shape_def, debris_box)
        this.debris_ids[index] = body

    function find_debris_index(body_id: b2.BodyId) -> int:
        var index = 0
        while index < DEBRIS_COUNT:
            if this.debris_ids[index] == body_id:
                return index
            index += 1
        return -1

    editable function attach_debris(index: int) -> void:
        let debris_id = this.debris_ids[index]
        if debris_id == b2.b2_nullBodyId:
            return
        let player_transform = b2.body_get_transform(this.player_id)
        let debris_transform = b2.body_get_transform(debris_id)
        let relative = common.inv_mul_transforms(player_transform, debris_transform)

        let shape_count = b2.body_get_shape_count(debris_id)
        if shape_count == 0:
            return
        var shape_id: b2.ShapeId = b2.b2_nullShapeId
        b2.body_get_shapes(debris_id, ptr_of(shape_id), 1)

        var attach_shape = b2.default_shape_def()
        attach_shape.enableContactEvents = true

        let shape_kind = b2.shape_get_type(shape_id)
        if shape_kind == b2.ShapeType.b2_circleShape:
            let c = b2.shape_get_circle(shape_id)
            let moved = b2.Circle(center = relative.mul_point(c.center), radius = c.radius)
            b2.create_circle_shape(this.player_id, attach_shape, moved)
        else if shape_kind == b2.ShapeType.b2_capsuleShape:
            let c = b2.shape_get_capsule(shape_id)
            let moved = b2.Capsule(
                center1 = relative.mul_point(c.center1),
                center2 = relative.mul_point(c.center2),
                radius = c.radius
            )
            b2.create_capsule_shape(this.player_id, attach_shape, moved)
        else if shape_kind == b2.ShapeType.b2_polygonShape:
            let p = b2.shape_get_polygon(shape_id)
            let moved = common.transform_polygon(relative, p)
            b2.create_polygon_shape(this.player_id, attach_shape, moved)

        b2.destroy_body(debris_id)
        this.debris_ids[index] = b2.b2_nullBodyId

    editable function on_step() -> void:
        let position = b2.body_get_position(this.player_id)
        if rl.is_key_down(rl.KeyboardKey.KEY_A):
            b2.body_apply_force(this.player_id, b2.Vec2(x = -this.force, y = 0.0), position, true)
        if rl.is_key_down(rl.KeyboardKey.KEY_D):
            b2.body_apply_force(this.player_id, b2.Vec2(x = this.force, y = 0.0), position, true)
        if rl.is_key_down(rl.KeyboardKey.KEY_W):
            b2.body_apply_force(this.player_id, b2.Vec2(x = 0.0, y = this.force), position, true)
        if rl.is_key_down(rl.KeyboardKey.KEY_S):
            b2.body_apply_force(this.player_id, b2.Vec2(x = 0.0, y = -this.force), position, true)

        var debris_to_attach: array[int, DEBRIS_COUNT] = zero[array[int, DEBRIS_COUNT]]
        var attach_count = 0
        var shapes_to_destroy: array[b2.ShapeId, DEBRIS_COUNT] = zero[array[b2.ShapeId, DEBRIS_COUNT]]
        var destroy_count = 0
        var contact_buffer: array[b2.ContactData, CONTACT_CAPACITY] = zero[array[b2.ContactData, CONTACT_CAPACITY]]

        this.impulse_count = 0
        let contact_events = b2.world_get_contact_events(this.world)
        var index = 0
        while index < contact_events.beginCount:
            unsafe:
                let touch_event = read(contact_events.beginEvents + ptr_uint<-index)
                let body_a = b2.shape_get_body(touch_event.shapeIdA)
                let body_b = b2.shape_get_body(touch_event.shapeIdB)
                let capacity_a = b2.shape_get_contact_capacity(touch_event.shapeIdA)
                let capacity_b = b2.shape_get_contact_capacity(touch_event.shapeIdB)
                if capacity_a < capacity_b:
                    let data_count = b2.shape_get_contact_data(
                        touch_event.shapeIdA, ptr_of(contact_buffer[0]), CONTACT_CAPACITY
                    )
                    var j = 0
                    while j < data_count:
                        let data = contact_buffer[j]
                        if data.shapeIdA == touch_event.shapeIdB or data.shapeIdB == touch_event.shapeIdB:
                            this.collect_impulses(data)
                        j += 1
                else:
                    let data_count = b2.shape_get_contact_data(
                        touch_event.shapeIdB, ptr_of(contact_buffer[0]), CONTACT_CAPACITY
                    )
                    var j = 0
                    while j < data_count:
                        let data = contact_buffer[j]
                        if data.shapeIdA == touch_event.shapeIdA or data.shapeIdB == touch_event.shapeIdA:
                            this.collect_impulses(data)
                        j += 1
                if body_a == this.player_id:
                    let debris_index = this.find_debris_index(body_b)
                    if debris_index >= 0:
                        if attach_count < DEBRIS_COUNT:
                            debris_to_attach[attach_count] = debris_index
                            attach_count += 1
                    else if touch_event.shapeIdA != this.core_shape_id and destroy_count < DEBRIS_COUNT:
                        if not this.contains_shape(shapes_to_destroy, destroy_count, touch_event.shapeIdA):
                            shapes_to_destroy[destroy_count] = touch_event.shapeIdA
                            destroy_count += 1
                else if body_b == this.player_id:
                    let debris_index = this.find_debris_index(body_a)
                    if debris_index >= 0:
                        if attach_count < DEBRIS_COUNT:
                            debris_to_attach[attach_count] = debris_index
                            attach_count += 1
                    else if touch_event.shapeIdB != this.core_shape_id and destroy_count < DEBRIS_COUNT:
                        if not this.contains_shape(shapes_to_destroy, destroy_count, touch_event.shapeIdB):
                            shapes_to_destroy[destroy_count] = touch_event.shapeIdB
                            destroy_count += 1
            index += 1

        var i = 0
        while i < attach_count:
            this.attach_debris(debris_to_attach[i])
            i += 1
        i = 0
        while i < destroy_count:
            b2.destroy_shape(shapes_to_destroy[i], false)
            i += 1
        if destroy_count > 0:
            b2.body_apply_mass_from_shapes(this.player_id)

        this.wait -= 1.0 / common.HERTZ
        if this.wait < 0.0:
            this.spawn_debris()
            this.wait += 0.5

    function contains_shape(shapes: array[b2.ShapeId, DEBRIS_COUNT], count: int, shape_id: b2.ShapeId) -> bool:
        var index = 0
        while index < count:
            if shapes[index] == shape_id:
                return true
            index += 1
        return false

    editable function collect_impulses(data: b2.ContactData) -> void:
        let normal = data.manifold.normal
        var k = 0
        while k < data.manifold.pointCount:
            if this.impulse_count < MAX_IMPULSE:
                let point = data.manifold.points[k]
                this.impulse_segments[this.impulse_count] = ImpulseSegment(
                    p1 = point.point,
                    p2 = point.point.add(normal.scale(point.totalNormalImpulse))
                )
                this.impulse_count += 1
            k += 1

    function draw_overlay() -> void:
        var index = 0
        while index < this.impulse_count:
            let segment = this.impulse_segments[index]
            common.draw_world_segment(segment.p1, segment.p2, b2.HexColor.b2_colorBlueViolet)
            common.draw_world_point(segment.p1, 10.0, b2.HexColor.b2_colorWhite)
            index += 1
        common.draw_text_line("move using WASD")

function main() -> int:
    let world_id = common.create_world()
    var sample = contact_event_create(world_id)
    return common.run(
        adapt[common.Sample](ref_of(sample)),
        "Box2D - Contact",
        b2.Vec2(x = 0.0, y = 0.0),
        25.0 * 1.75,
        world_id
    )
