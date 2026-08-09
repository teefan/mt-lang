## Box2D sample port: "Mover" (from box2d-upstream/samples/sample_character.cpp).
##
## A Quake-style capsule mover driven by b2World_CastMover / b2World_CollideMover
## with a plane solver, a pogo-stick ground probe, a suspension bridge, and a
## kinematic elevator. The upstream SVG-path terrain is replaced with a simple
## sloped course.
##   A / D         move left / right
##   Space         jump
##   K             kick nearby debris
##   P             pause, Space single-step

import std.box2d as b2
import std.raylib as rl
import examples.box2d.common as common

const MAX_PLANES: int = 8
const PLANK_COUNT: int = 50

const MoverBit: int = 0x0002
const DynamicBit: int = 0x0004
const DebrisBit: int = 0x0008
const StaticBit: int = 0x0001

const PogoPoint: int = 0
const PogoCircle: int = 1
const PogoSegment: int = 2

struct CastResult:
    point: b2.Vec2
    normal: b2.Vec2
    body_id: b2.BodyId
    fraction: float
    hit: bool

struct Mover implements common.Sample:
    world: b2.WorldId
    transform: b2.Transform
    velocity: b2.Vec2
    capsule: b2.Capsule
    elevator_id: b2.BodyId
    friendly_shape_id: b2.ShapeId
    elevator_shape_id: b2.ShapeId
    plane_count: int
    total_iterations: int
    pogo_velocity: float
    time: float
    on_ground: bool
    jump_released: bool
    lock_camera: bool
    jump_speed: float
    max_speed: float
    min_speed: float
    stop_speed: float
    accelerate: float
    air_steer: float
    friction: float
    gravity: float
    pogo_hertz: float
    pogo_damping_ratio: float
    pogo_shape: int

var s_planes: array[b2.CollisionPlane, MAX_PLANES]
var s_plane_count: int = 0
var s_friendly_shape: b2.ShapeId = b2.b2_nullShapeId
var s_elevator_shape: b2.ShapeId = b2.b2_nullShapeId
var s_cast_result: CastResult
var s_mover_position: b2.Vec2

function plane_result_callback(
    shape_id: b2.ShapeId,
    plane_result: const_ptr[b2.PlaneResult],
    _context: ptr[void]
) -> bool:
    unsafe:
        let result = read(plane_result)
        if result.hit:
            var max_push = 1000000.0
            var clip_velocity = true
            if shape_id == s_friendly_shape:
                max_push = 0.025
                clip_velocity = false
            else if shape_id == s_elevator_shape:
                max_push = 0.1
            if s_plane_count < MAX_PLANES:
                s_planes[s_plane_count] = b2.CollisionPlane(
                    plane = result.plane,
                    pushLimit = max_push,
                    push = 0.0,
                    clipVelocity = clip_velocity
                )
                s_plane_count += 1
    return true

function cast_callback(
    _shape_id: b2.ShapeId,
    point: b2.Vec2,
    normal: b2.Vec2,
    fraction: float,
    _context: ptr[void]
) -> float:
    s_cast_result.point = point
    s_cast_result.normal = normal
    s_cast_result.body_id = b2.shape_get_body(_shape_id)
    s_cast_result.fraction = fraction
    s_cast_result.hit = true
    return fraction

function kick_callback(shape_id: b2.ShapeId, _context: ptr[void]) -> bool:
    let body_id = b2.shape_get_body(shape_id)
    if b2.body_get_type(body_id) == b2.BodyType.b2_dynamicBody:
        let center = b2.body_get_world_center_of_mass(body_id)
        let direction = center.sub(s_mover_position).normalize()
        b2.body_apply_linear_impulse_to_center(body_id, b2.Vec2(x = 2.0 * direction.x, y = 2.0), true)
    return true

function mover_create(world_id: b2.WorldId) -> Mover:
    common.enable_mouse_joint(false)
    let body_def = b2.default_body_def()

    # ground 1: sloped course
    let ground1 = b2.create_body(world_id, body_def)
    let shape_def = b2.default_shape_def()
    var segment = b2.Segment(
        point1 = b2.Vec2(x = -5.0, y = 0.0),
        point2 = b2.Vec2(x = 15.0, y = 0.0)
    )
    b2.create_segment_shape(ground1, shape_def, segment)
    segment = b2.Segment(
        point1 = b2.Vec2(x = 15.0, y = 0.0),
        point2 = b2.Vec2(x = 35.0, y = 4.0)
    )
    b2.create_segment_shape(ground1, shape_def, segment)
    segment = b2.Segment(
        point1 = b2.Vec2(x = 35.0, y = 4.0),
        point2 = b2.Vec2(x = 60.0, y = 4.0)
    )
    b2.create_segment_shape(ground1, shape_def, segment)

    # ground 2
    var ground2_def = b2.default_body_def()
    ground2_def.position = b2.Vec2(x = 98.0, y = 0.0)
    let ground2 = b2.create_body(world_id, ground2_def)
    let ground2_segment = b2.Segment(
        point1 = b2.Vec2(x = 60.0, y = 0.0),
        point2 = b2.Vec2(x = 120.0, y = 0.0)
    )
    b2.create_segment_shape(ground2, shape_def, ground2_segment)

    # suspension bridge
    let plank_box = b2.make_box(0.5, 0.125)
    let bridge_shape = b2.default_shape_def()
    var joint_def = b2.default_revolute_joint_def()
    joint_def.maxMotorTorque = 10.0
    joint_def.enableMotor = true
    joint_def.hertz = 3.0
    joint_def.dampingRatio = 0.8
    joint_def.enableSpring = true

    let x_base = 48.7
    let y_base = 9.2
    var prev_body = ground1
    var index = 0
    while index < PLANK_COUNT:
        var plank_def = b2.default_body_def()
        plank_def.type = b2.BodyType.b2_dynamicBody
        plank_def.position = b2.Vec2(x = x_base + 0.5 + (index), y = y_base)
        plank_def.angularDamping = 0.2
        let plank = b2.create_body(world_id, plank_def)
        b2.create_polygon_shape(plank, bridge_shape, plank_box)
        let pivot = b2.Vec2(x = x_base + (index), y = y_base)
        joint_def.bodyIdA = prev_body
        joint_def.bodyIdB = plank
        joint_def.localAnchorA = b2.body_get_local_point(prev_body, pivot)
        joint_def.localAnchorB = b2.body_get_local_point(plank, pivot)
        b2.create_revolute_joint(world_id, joint_def)
        prev_body = plank
        index += 1
    let end_pivot = b2.Vec2(x = x_base + (PLANK_COUNT), y = y_base)
    joint_def.bodyIdA = prev_body
    joint_def.bodyIdB = ground2
    joint_def.localAnchorA = b2.body_get_local_point(prev_body, end_pivot)
    joint_def.localAnchorB = b2.body_get_local_point(ground2, end_pivot)
    b2.create_revolute_joint(world_id, joint_def)

    # friendly capsule on the course
    var friendly_def = b2.default_body_def()
    friendly_def.position = b2.Vec2(x = 32.0, y = 4.5)
    let friendly_body = b2.create_body(world_id, friendly_def)
    var friendly_shape = b2.default_shape_def()
    friendly_shape.filter.categoryBits = uint<-MoverBit
    friendly_shape.filter.maskBits = 0xFFFFFFFF
    let friendly_capsule = b2.Capsule(
        center1 = b2.Vec2(x = 0.0, y = -0.5),
        center2 = b2.Vec2(x = 0.0, y = 0.5),
        radius = 0.3
    )
    let friendly_shape_id = b2.create_capsule_shape(friendly_body, friendly_shape, friendly_capsule)

    # debris ball
    var ball_def = b2.default_body_def()
    ball_def.type = b2.BodyType.b2_dynamicBody
    ball_def.position = b2.Vec2(x = 7.0, y = 7.0)
    let ball_body = b2.create_body(world_id, ball_def)
    var ball_shape = b2.default_shape_def()
    ball_shape.filter.categoryBits = uint<-DebrisBit
    ball_shape.filter.maskBits = 0xFFFFFFFF
    ball_shape.material.restitution = 0.7
    ball_shape.material.rollingResistance = 0.2
    let ball_circle = b2.Circle(center = b2.b2Vec2_zero, radius = 0.3)
    b2.create_circle_shape(ball_body, ball_shape, ball_circle)

    # elevator
    var elevator_def = b2.default_body_def()
    elevator_def.type = b2.BodyType.b2_kinematicBody
    elevator_def.position = b2.Vec2(x = 112.0, y = 6.0)
    let elevator = b2.create_body(world_id, elevator_def)
    var elevator_shape = b2.default_shape_def()
    elevator_shape.filter.categoryBits = uint<-DynamicBit
    elevator_shape.filter.maskBits = 0xFFFFFFFF
    let elevator_box = b2.make_box(2.0, 0.1)
    let elevator_shape_id = b2.create_polygon_shape(elevator, elevator_shape, elevator_box)

    s_friendly_shape = friendly_shape_id
    s_elevator_shape = elevator_shape_id
    s_plane_count = 0
    s_cast_result = CastResult(
        point = b2.b2Vec2_zero,
        normal = b2.b2Vec2_zero,
        body_id = b2.b2_nullBodyId,
        fraction = 0.0,
        hit = false
    )

    return Mover(
        world = world_id,
        transform = b2.Transform(p = b2.Vec2(x = 2.0, y = 8.0), q = b2.b2Rot_identity),
        velocity = b2.b2Vec2_zero,
        capsule = b2.Capsule(
            center1 = b2.Vec2(x = 0.0, y = -0.5),
            center2 = b2.Vec2(x = 0.0, y = 0.5),
            radius = 0.3
        ),
        elevator_id = elevator,
        friendly_shape_id = friendly_shape_id,
        elevator_shape_id = elevator_shape_id,
        plane_count = 0,
        total_iterations = 0,
        pogo_velocity = 0.0,
        time = 0.0,
        on_ground = false,
        jump_released = true,
        lock_camera = true,
        jump_speed = 10.0,
        max_speed = 6.0,
        min_speed = 0.1,
        stop_speed = 3.0,
        accelerate = 20.0,
        air_steer = 0.2,
        friction = 8.0,
        gravity = 30.0,
        pogo_hertz = 5.0,
        pogo_damping_ratio = 0.8,
        pogo_shape = PogoSegment
    )

extending Mover:
    editable function solve_move(time_step: float, throttle: float) -> void:
        # friction
        let speed = this.velocity.length()
        if speed < this.min_speed:
            this.velocity = b2.b2Vec2_zero
        else if this.on_ground:
            let control = if speed < this.stop_speed: this.stop_speed else: speed
            let drop = control * this.friction * time_step
            let new_speed = common.max_float(0.0, speed - drop)
            this.velocity = this.velocity.scale(new_speed / speed)

        let desired_velocity = b2.Vec2(x = this.max_speed * throttle, y = 0.0)
        let (desired_speed, desired_direction) = common.get_length_and_normalize(desired_velocity)

        if this.on_ground:
            this.velocity = b2.Vec2(x = this.velocity.x, y = 0.0)

        let current_speed = this.velocity.dot(desired_direction)
        let add_speed = desired_speed - current_speed
        if add_speed > 0.0:
            let steer = if this.on_ground: 1.0 else: this.air_steer
            var accel_speed = steer * this.accelerate * this.max_speed * time_step
            if accel_speed > add_speed:
                accel_speed = add_speed
            this.velocity = this.velocity.add(desired_direction.scale(accel_speed))

        this.velocity = b2.Vec2(x = this.velocity.x, y = this.velocity.y - this.gravity * time_step)

        # pogo ground probe
        let pogo_rest_length = 3.0 * this.capsule.radius
        let ray_length = pogo_rest_length + this.capsule.radius
        let origin = this.transform.mul_point(this.capsule.center1)
        let probe_circle = b2.Circle(center = origin, radius = 0.5 * this.capsule.radius)
        let segment_offset = b2.Vec2(x = 0.75 * this.capsule.radius, y = 0.0)
        let probe_segment = b2.Segment(
            point1 = origin.sub(segment_offset),
            point2 = origin.add(segment_offset)
        )
        var proxy = b2.ShapeProxy(points = zero[array[b2.Vec2, 8]], count = 0, radius = 0.0)
        var translation: b2.Vec2
        let pogo_filter = b2.QueryFilter(categoryBits = uint<-MoverBit, maskBits = uint<-(StaticBit | DynamicBit))
        s_cast_result.hit = false
        if this.pogo_shape == PogoPoint:
            proxy = b2.make_proxy(const_ptr_of(origin), 1, 0.0)
            translation = b2.Vec2(x = 0.0, y = -ray_length)
        else if this.pogo_shape == PogoCircle:
            proxy = b2.make_proxy(const_ptr_of(origin), 1, probe_circle.radius)
            translation = b2.Vec2(x = 0.0, y = -ray_length + probe_circle.radius)
        else:
            proxy = b2.make_proxy(const_ptr_of(probe_segment.point1), 2, 0.0)
            translation = b2.Vec2(x = 0.0, y = -ray_length)
        let _stats = b2.world_cast_shape(
            this.world,
            const_ptr_of(proxy),
            translation,
            pogo_filter,
            cast_callback,
            common.null_context()
        )

        this.on_ground = s_cast_result.hit and (this.on_ground or this.velocity.y <= 0.01)

        if not s_cast_result.hit:
            this.pogo_velocity = 0.0
        else:
            let pogo_current_length = s_cast_result.fraction * ray_length
            let offset = pogo_current_length - pogo_rest_length
            this.pogo_velocity = common.spring_damper(
                this.pogo_hertz,
                this.pogo_damping_ratio,
                offset,
                this.pogo_velocity,
                time_step
            )
            b2.body_apply_force(s_cast_result.body_id, b2.Vec2(x = 0.0, y = -50.0), s_cast_result.point, true)

        # collide + cast solve
        let target = this.transform.p.add(this.velocity.scale(time_step)).add(
            b2.Vec2(x = 0.0, y = time_step * this.pogo_velocity)
        )
        let collide_filter = b2.QueryFilter(
            categoryBits = uint<-MoverBit, maskBits = uint<-(StaticBit | DynamicBit | MoverBit)
        )
        let cast_filter = b2.QueryFilter(categoryBits = uint<-MoverBit, maskBits = uint<-(StaticBit | DynamicBit))
        this.total_iterations = 0
        let tolerance = 0.01
        var iteration = 0
        while iteration < 5:
            s_plane_count = 0
            let mover = b2.Capsule(
                center1 = this.transform.mul_point(this.capsule.center1),
                center2 = this.transform.mul_point(this.capsule.center2),
                radius = this.capsule.radius
            )
            b2.world_collide_mover(
                this.world,
                const_ptr_of(mover),
                collide_filter,
                plane_result_callback,
                common.null_context()
            )
            let solve = b2.solve_planes(target.sub(this.transform.p), ptr_of(s_planes[0]), s_plane_count)
            this.total_iterations += solve.iterationCount
            let fraction = b2.world_cast_mover(this.world, const_ptr_of(mover), solve.translation, cast_filter)
            let delta = solve.translation.scale(fraction)
            this.transform.p = this.transform.p.add(delta)
            if delta.length_sq() < tolerance * tolerance:
                break
            iteration += 1
        this.velocity = b2.clip_vector(this.velocity, const_ptr_of(s_planes[0]), s_plane_count)

    editable function kick() -> void:
        let point = this.transform.mul_point(b2.Vec2(x = 0.0, y = this.capsule.center1.y - 3.0 * this.capsule.radius))
        let circle = b2.Circle(center = point, radius = 0.5)
        let proxy = b2.make_proxy(const_ptr_of(circle.center), 1, circle.radius)
        let filter = b2.QueryFilter(categoryBits = uint<-MoverBit, maskBits = uint<-DebrisBit)
        s_mover_position = this.transform.p
        let _stats = b2.world_overlap_shape(
            this.world,
            const_ptr_of(proxy),
            filter,
            kick_callback,
            common.null_context()
        )

    editable function on_step() -> void:
        if common.stepped():
            let cs = b2.compute_cos_sin(this.time + b2.B2_PI)
            let point = b2.Vec2(x = 112.0, y = 4.0 * cs.cosine + 10.0)
            b2.body_set_target_transform(
                this.elevator_id, b2.Transform(p = point, q = b2.b2Rot_identity), 1.0 / common.HERTZ
            )
            this.time += 1.0 / common.HERTZ

            var throttle = 0.0
            if rl.is_key_down(rl.KeyboardKey.KEY_A):
                throttle -= 1.0
            if rl.is_key_down(rl.KeyboardKey.KEY_D):
                throttle += 1.0
            if rl.is_key_down(rl.KeyboardKey.KEY_SPACE):
                if this.on_ground and this.jump_released:
                    this.velocity = b2.Vec2(x = this.velocity.x, y = this.jump_speed)
                    this.on_ground = false
                    this.jump_released = false
            else:
                this.jump_released = true
            this.solve_move(1.0 / common.HERTZ, throttle)
            if this.lock_camera:
                common.set_camera_center(b2.Vec2(x = this.transform.p.x, y = 9.0))

        if rl.is_key_pressed(rl.KeyboardKey.KEY_K):
            this.kick()

    function draw_overlay() -> void:
        var index = 0
        while index < s_plane_count:
            let plane = s_planes[index]
            let p1 = this.transform.p.add(plane.plane.normal.scale(plane.plane.offset - this.capsule.radius))
            let p2 = p1.add(plane.plane.normal.scale(0.1))
            common.draw_world_point(p1, 5.0, b2.HexColor.b2_colorYellow)
            common.draw_world_segment(p1, p2, b2.HexColor.b2_colorYellow)
            index += 1
        let capsule_p1 = this.transform.mul_point(this.capsule.center1)
        let capsule_p2 = this.transform.mul_point(this.capsule.center2)
        let color = if this.on_ground: b2.HexColor.b2_colorOrange else: b2.HexColor.b2_colorAquamarine
        common.draw_world_solid_capsule(capsule_p1, capsule_p2, this.capsule.radius, color)
        common.draw_world_segment(this.transform.p, this.transform.p.add(this.velocity), b2.HexColor.b2_colorPurple)
        common.draw_text_line(f"position #{this.transform.p.x:.2} #{this.transform.p.y:.2}")
        common.draw_text_line(f"velocity #{this.velocity.x:.2} #{this.velocity.y:.2}")
        common.draw_text_line(f"iterations #{this.total_iterations}")
        common.draw_text_line("A/D move  Space jump  K kick")

function main() -> int:
    let world_id = common.create_world()
    var sample = mover_create(world_id)
    return common.run(
        adapt[common.Sample](ref_of(sample)),
        "Box2D - Mover",
        b2.Vec2(x = 20.0, y = 9.0),
        10.0,
        world_id
    )
