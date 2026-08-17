## Box3D sample port: "Prismatic Joint" (from box3d-upstream/samples/sample_joint.cpp).
##
## A box slides along a horizontal prismatic joint driven by a motor, with a
## spring pulling it back toward its target translation.
##   Left mouse     drag bodies (ray spring)
##   Right mouse    orbit camera
##   Wheel          zoom
##   P              pause, Space single-step
import std.box3d as b3
import std.raygui as gui
import std.raylib as rl
import examples.box3d.common as common

struct PrismaticJoint implements common.Sample:
    world: b3.WorldId
    joint: b3.JointId
    motor_speed: float

function prismatic_joint_create(world_id: b3.WorldId) -> PrismaticJoint:
    common.add_ground_box(20.0)
    var ground_def = b3.default_body_def()
    ground_def.position = b3.Vec3(x = 0.0, y = 2.0, z = 0.0)
    let ground = b3.create_body(world_id, ground_def)
    var body_def = b3.default_body_def()
    body_def.type = b3.BodyType.b3_dynamicBody
    body_def.position = b3.Vec3(x = 0.0, y = 2.0, z = 0.0)
    let body = b3.create_body(world_id, body_def)
    common.track_body(body)
    let box = b3.make_box_hull(0.5, 0.5, 0.5)
    let shape_def = b3.default_shape_def()
    b3.create_hull_shape(body, shape_def, box.base)
    var joint_def = b3.default_prismatic_joint_def()
    joint_def.base.bodyIdA = ground
    joint_def.base.bodyIdB = body
    joint_def.base.localFrameA.p = b3.b3Vec3_zero
    joint_def.base.localFrameB.p = b3.b3Vec3_zero
    joint_def.enableSpring = true
    joint_def.hertz = 2.0
    joint_def.dampingRatio = 0.7
    joint_def.enableMotor = true
    joint_def.maxMotorForce = 10000.0
    joint_def.motorSpeed = 3.0
    let joint = b3.create_prismatic_joint(world_id, joint_def)
    return PrismaticJoint(world = world_id, joint = joint, motor_speed = 3.0)

extending PrismaticJoint:
    editable function on_step() -> void:
        pass

    editable function draw_overlay() -> void:
        let translation = b3.prismatic_joint_get_translation(this.joint)
        common.draw_text_line(f"prismatic joint translation = #{translation:.2}")
        gui.label(rl.Rectangle(x = 20.0, y = 60.0, width = 200.0, height = 24.0), "motor speed (m/s)")
        let before = this.motor_speed
        gui.slider(rl.Rectangle(x = 20.0, y = 84.0, width = 220.0, height = 20.0), "0", "10", this.motor_speed, 0.0, 10.0)
        if this.motor_speed != before:
            b3.prismatic_joint_set_motor_speed(this.joint, this.motor_speed)

function main() -> int:
    let world_id = common.create_world()
    var sample = prismatic_joint_create(world_id)
    return common.run(adapt[common.Sample](ref_of(sample)), "Box3D - Prismatic Joint", b3.Vec3(x = 0.0, y = 2.0, z = 0.0), 15.0)
