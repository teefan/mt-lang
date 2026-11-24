## Headless Box2D 3.2 API smoke test.
##
## Exercises the binding surface the sample suite depends on without opening a
## window: world/body/shape creation, the shared joint-definition base, the
## motor-joint grab, chains, contact and sensor data, world queries, casts,
## shape distance, and the renamed body/shape helpers.  The box2d_smoke gate
## builds and runs this in CI.

import std.box2d as b2
import std.stdio as stdio

var g_dummy_context: int = 0
var g_overlaps: int = 0
var g_casts: int = 0
var g_planes: int = 0

function null_context() -> ptr[void]:
    return unsafe: reinterpret[ptr[void]](ptr_of(g_dummy_context))

function fail(message: str) -> int:
    stdio.print_format("box2d smoke: FAIL %s\n", message)
    return 1

function overlap_callback(shape_id: b2.ShapeId, _context: ptr[void]) -> bool:
    g_overlaps += 1
    return true

function cast_callback(
    shape_id: b2.ShapeId,
    point: b2.Pos,
    normal: b2.Vec2,
    fraction: float,
    _context: ptr[void]
) -> float:
    g_casts += 1
    return fraction

function plane_callback(
    shape_id: b2.ShapeId,
    plane: const_ptr[b2.PlaneResult],
    _context: ptr[void]
) -> bool:
    unsafe:
        if read(plane).hit:
            g_planes += 1
    return true

function main() -> int:
    let version = b2.get_version()
    if version.major != 3 or version.minor != 2:
        stdio.print_format(
            "box2d smoke: FAIL version %d.%d.%d\n",
            version.major,
            version.minor,
            version.revision
        )
        return 1

    var world_def = b2.default_world_def()
    world_def.workerCount = 1
    let world = b2.create_world(world_def)
    defer: b2.destroy_world(world)

    # Ground segment + falling circle.
    let ground = b2.create_body(world, b2.default_body_def())
    var ground_shape_def = b2.default_shape_def()
    ground_shape_def.enableContactEvents = true
    let ground_shape = b2.create_segment_shape(
        ground,
        ground_shape_def,
        b2.Segment(point1 = b2.Vec2(x = -10.0, y = 0.0), point2 = b2.Vec2(x = 10.0, y = 0.0))
    )

    var body_def = b2.default_body_def()
    body_def.type = b2.BodyType.b2_dynamicBody
    body_def.position = b2.Vec2(x = 0.0, y = 3.0)
    let body = b2.create_body(world, body_def)
    var shape_def = b2.default_shape_def()
    shape_def.density = 1.0
    shape_def.enableContactEvents = true
    let circle = b2.Circle(center = b2.Vec2(x = 0.0, y = 0.0), radius = 0.5)
    let body_shape = b2.create_circle_shape(body, shape_def, circle)

    var step = 0
    while step < 120:
        b2.world_step(world, 1.0 / 60.0, 4)
        step += 1

    let position = b2.body_get_position(body)
    if position.y > 3.0:
        return fail("dynamic body did not fall")

    # Contact data and the 3.2 contact-id API.
    if b2.shape_get_contact_capacity(body_shape) <= 0:
        return fail("no contact capacity")
    var contact_buffer: array[b2.ContactData, 8] = zero[array[b2.ContactData, 8]]
    let contact_count = b2.shape_get_contact_data(body_shape, ptr_of(contact_buffer[0]), 8)
    if contact_count <= 0:
        return fail("no contact data")
    let contact = contact_buffer[0]
    if contact.manifold.pointCount <= 0:
        return fail("empty contact manifold")
    let anchor = contact.manifold.points[0]
    let body_a = b2.shape_get_body(contact.shapeIdA)
    let center_a = b2.body_get_world_center(body_a)
    let _contact_point = b2.Vec2(
        x = center_a.x + anchor.anchorA.x,
        y = center_a.y + anchor.anchorA.y
    )
    if b2.contact_is_valid(contact.contactId):
        let by_id = b2.contact_get_data(contact.contactId)
        if by_id.manifold.pointCount <= 0:
            return fail("contact_get_data returned no points")

    # Sensor events and sensor overlap data.
    var sensor_def = b2.default_shape_def()
    sensor_def.isSensor = true
    sensor_def.enableSensorEvents = true
    let sensor_shape = b2.create_circle_shape(
        ground,
        sensor_def,
        b2.Circle(center = b2.Vec2(x = 0.0, y = 0.5), radius = 1.0)
    )
    b2.world_step(world, 1.0 / 60.0, 4)
    let sensor_events = b2.world_get_sensor_events(world)
    var visitor_ids: array[b2.ShapeId, 8] = zero[array[b2.ShapeId, 8]]
    let visitor_count = b2.shape_get_sensor_data(sensor_shape, ptr_of(visitor_ids[0]), 8)
    if sensor_events.beginCount > 0 and visitor_count <= 0:
        return fail("sensor event without overlap data")

    # Chain with materials.
    var chain_points: array[b2.Vec2, 4] = array[b2.Vec2, 4](
        b2.Vec2(x = -2.0, y = 0.0),
        b2.Vec2(x = 2.0, y = 0.0),
        b2.Vec2(x = 2.0, y = 2.0),
        b2.Vec2(x = -2.0, y = 2.0)
    )
    var chain_def = b2.default_chain_def()
    chain_def.points = const_ptr_of(chain_points[0])
    chain_def.pointCount = 4
    chain_def.isLoop = true
    let chain = b2.create_chain(ground, chain_def)
    let segment_count = b2.chain_get_segment_count(chain)
    if segment_count <= 0:
        return fail("chain has no segments")
    var segment_ids: array[b2.ShapeId, 8] = zero[array[b2.ShapeId, 8]]
    if b2.chain_get_segments(chain, ptr_of(segment_ids[0]), 8) != segment_count:
        return fail("chain segment count mismatch")
    var chain_material = b2.chain_get_surface_material(chain, 0)
    chain_material.friction = 0.3
    b2.chain_set_all_surface_materials(chain, chain_material)

    # Revolute joint through the shared base definition.
    var link_def = b2.default_body_def()
    link_def.type = b2.BodyType.b2_dynamicBody
    link_def.position = b2.Vec2(x = 5.0, y = 3.0)
    let link_body = b2.create_body(world, link_def)
    b2.create_circle_shape(link_body, shape_def, circle)
    var revolute = b2.default_revolute_joint_def()
    revolute.base.bodyIdA = ground
    revolute.base.bodyIdB = link_body
    revolute.base.localFrameA = b2.Transform(
        p = b2.Vec2(x = 5.0, y = 3.0),
        q = b2.b2Rot_identity
    )
    revolute.base.localFrameB = b2.Transform(
        p = b2.Vec2(x = 0.0, y = 0.0),
        q = b2.b2Rot_identity
    )
    revolute.enableLimit = true
    revolute.lowerAngle = -0.5 * b2.B2_PI
    revolute.upperAngle = 0.5 * b2.B2_PI
    revolute.enableMotor = true
    revolute.maxMotorTorque = 10.0
    revolute.motorSpeed = 0.5
    revolute.enableSpring = true
    revolute.hertz = 2.0
    revolute.dampingRatio = 0.5
    let joint = b2.create_revolute_joint(world, revolute)
    if not b2.joint_is_valid(joint):
        return fail("revolute joint invalid")
    if b2.joint_get_type(joint) != b2.JointType.b2_revoluteJoint:
        return fail("revolute joint wrong type")
    let frame = b2.joint_get_local_frame_a(joint)
    b2.joint_set_local_frame_a(joint, frame)
    b2.revolute_joint_set_target_motor_speed(joint, 0.25)
    b2.revolute_joint_enable_limit(joint, true)
    b2.world_step(world, 1.0 / 60.0, 4)
    let _angle = b2.revolute_joint_get_current_angle(joint)
    let _torque = b2.revolute_joint_get_current_motor_torque(joint)

    # Wheel joint: localFrameA's x-axis is the suspension axis.
    var wheel_body_def = b2.default_body_def()
    wheel_body_def.type = b2.BodyType.b2_dynamicBody
    wheel_body_def.position = b2.Vec2(x = 8.0, y = 3.0)
    let wheel_body = b2.create_body(world, wheel_body_def)
    b2.create_circle_shape(wheel_body, shape_def, circle)
    let cs = b2.compute_cos_sin(0.5 * b2.B2_PI)
    var wheel = b2.default_wheel_joint_def()
    wheel.base.bodyIdA = ground
    wheel.base.bodyIdB = wheel_body
    wheel.base.localFrameA = b2.Transform(
        p = b2.Vec2(x = 8.0, y = 4.0),
        q = b2.Rot(c = cs.cosine, s = cs.sine)
    )
    wheel.base.localFrameB = b2.Transform(
        p = b2.Vec2(x = 0.0, y = 1.0),
        q = b2.b2Rot_identity
    )
    wheel.enableMotor = true
    wheel.maxMotorTorque = 5.0
    wheel.motorSpeed = 1.0
    wheel.enableSpring = true
    wheel.hertz = 4.0
    wheel.dampingRatio = 0.7
    let wheel_joint = b2.create_wheel_joint(world, wheel)
    if b2.joint_get_type(wheel_joint) != b2.JointType.b2_wheelJoint:
        return fail("wheel joint wrong type")
    b2.wheel_joint_set_target_motor_speed(wheel_joint, 2.0)
    b2.world_step(world, 1.0 / 60.0, 4)
    let _wheel_torque = b2.wheel_joint_get_current_motor_torque(wheel_joint)

    # Motor-joint grab: kinematic body + spring toward the cursor.
    var grab_def = b2.default_body_def()
    grab_def.type = b2.BodyType.b2_kinematicBody
    grab_def.position = b2.Vec2(x = 0.0, y = 5.0)
    grab_def.enableSleep = false
    let grab_body = b2.create_body(world, grab_def)
    var motor = b2.default_motor_joint_def()
    motor.base.bodyIdA = grab_body
    motor.base.bodyIdB = body
    motor.base.localFrameB.p = b2.body_get_local_point(body, b2.Vec2(x = 0.0, y = 5.0))
    motor.linearHertz = 7.5
    motor.linearDampingRatio = 1.0
    motor.maxSpringForce = 100.0
    let grab_joint = b2.create_motor_joint(world, motor)
    b2.body_set_target_transform(
        grab_body,
        b2.Transform(p = b2.Vec2(x = 0.0, y = 5.0), q = b2.b2Rot_identity),
        1.0 / 60.0,
        true
    )
    b2.world_step(world, 1.0 / 60.0, 4)
    if not b2.joint_is_valid(grab_joint):
        return fail("grab joint invalid")
    b2.destroy_joint(grab_joint)
    b2.destroy_body(grab_body)

    # World queries take a b2Pos origin.
    let filter = b2.default_query_filter()
    let bounds = b2.AABB(
        lowerBound = b2.Vec2(x = -10.0, y = -10.0),
        upperBound = b2.Vec2(x = 10.0, y = 10.0)
    )
    let _overlap_stats = b2.world_overlap_aabb(
        world,
        b2.b2Vec2_zero,
        bounds,
        filter,
        overlap_callback,
        null_context()
    )
    if g_overlaps == 0:
        return fail("overlap query found nothing")

    let ray_origin = b2.Vec2(x = 0.0, y = 5.0)
    let ray_translation = b2.Vec2(x = 0.0, y = -10.0)
    let _ray_stats = b2.world_cast_ray(
        world,
        ray_origin,
        ray_translation,
        filter,
        cast_callback,
        null_context()
    )
    if g_casts == 0:
        return fail("ray cast found nothing")
    let closest = b2.world_cast_ray_closest(world, ray_origin, ray_translation, filter)
    let _closest_fraction = closest.fraction

    let proxy = b2.make_proxy(const_ptr_of(ray_origin), 1, 0.5)
    let _shape_stats = b2.world_cast_shape(
        world,
        b2.b2Vec2_zero,
        const_ptr_of(proxy),
        ray_translation,
        filter,
        cast_callback,
        null_context()
    )
    let mover = b2.Capsule(
        center1 = b2.Vec2(x = 0.0, y = 4.0),
        center2 = b2.Vec2(x = 0.0, y = 4.5),
        radius = 0.4
    )
    let _mover_fraction = b2.world_cast_mover(
        world,
        b2.b2Vec2_zero,
        const_ptr_of(mover),
        ray_translation,
        filter
    )
    b2.world_collide_mover(
        world,
        b2.b2Vec2_zero,
        const_ptr_of(mover),
        filter,
        plane_callback,
        null_context()
    )
    var planes: array[b2.CollisionPlane, 8] = zero[array[b2.CollisionPlane, 8]]
    let solved = b2.solve_planes(b2.Vec2(x = 0.0, y = -1.0), ptr_of(planes[0]), 0)
    let _solved_delta = solved.delta
    let _clipped = b2.clip_vector(b2.Vec2(x = 1.0, y = -1.0), ptr_of(planes[0]), 0)

    # Low-level collision functions are verb-first and shape-first.
    let ray_input = b2.RayCastInput(
        origin = b2.Vec2(x = 0.0, y = 2.0),
        translation = b2.Vec2(x = 0.0, y = -4.0),
        maxFraction = 1.0
    )
    let local_circle = b2.Circle(center = b2.Vec2(x = 0.0, y = 0.0), radius = 0.5)
    let circle_cast = b2.cast_ray_circle(const_ptr_of(local_circle), const_ptr_of(ray_input))
    if not circle_cast.hit:
        return fail("cast_ray_circle missed")
    let local_segment = b2.Segment(
        point1 = b2.Vec2(x = -2.0, y = 0.0),
        point2 = b2.Vec2(x = 2.0, y = 0.0)
    )
    let _segment_cast = b2.cast_ray_segment(
        const_ptr_of(local_segment),
        const_ptr_of(ray_input),
        false
    )

    let proxy_a = b2.make_proxy(const_ptr_of(local_circle.center), 1, local_circle.radius)
    let proxy_b = b2.make_proxy(const_ptr_of(local_segment.point1), 2, 0.0)
    let pair = b2.ShapeCastPairInput(
        proxyA = proxy_a,
        proxyB = proxy_b,
        transform = b2.b2Transform_identity,
        translationB = b2.Vec2(x = 0.0, y = -1.0),
        maxFraction = 1.0,
        canEncroach = false
    )
    let _pair_cast = b2.cast_shape(const_ptr_of(pair))
    let distance_input = b2.DistanceInput(
        proxyA = proxy_a,
        proxyB = proxy_b,
        transform = b2.b2Transform_identity,
        useRadii = true
    )
    var simplex_cache = b2.b2_emptySimplexCache
    var simplexes: array[b2.Simplex, 1] = zero[array[b2.Simplex, 1]]
    let distance = b2.compute_shape_distance(
        const_ptr_of(distance_input),
        ptr_of(simplex_cache),
        ptr_of(simplexes[0]),
        1
    )
    let _distance = distance.distance

    # Renamed body/shape helpers.
    b2.body_update_mass_from_shapes(body)
    let _body_bounds = b2.body_compute_bounds(body)
    let _body_center = b2.body_get_world_center(body)
    let _mass_data = b2.body_get_mass_data(body)
    let _shape_bounds = b2.shape_get_bounds(body_shape)
    let _shape_mass = b2.shape_compute_mass_data(body_shape)
    let _ground_shape = ground_shape

    var draw = b2.default_debug_draw()
    b2.world_draw(world, draw)

    stdio.print_format("box2d smoke: 3.2.0 ok\n")
    return 0
