## Box3D sample port: "Revolute Joint" (from box3d-upstream/samples/sample_joint.cpp).
##
## A box hangs from a fixed anchor on a revolute joint and is spun by a motor,
## so it winds up and reverses as it gains speed.
##   Left mouse     drag bodies (ray spring)
##   Right mouse    orbit camera
##   Wheel          zoom
##   P              pause, Space single-step
import std.box3d as b3
import std.raygui as gui
import std.raylib as rl
import examples.box3d.common as common

struct RevoluteJoint implements common.Sample:
    world: b3.WorldId
    joint: b3.JointId
    motor_speed: float
    max_torque: float

function revolute_joint_create(world_id: b3.WorldId) -> RevoluteJoint:
    common.add_ground_box(20.0)
    var anchor_def = b3.default_body_def()
    anchor_def.position = b3.Vec3(x = 0.0, y = 6.0, z = 0.0)
    let anchor = b3.create_body(world_id, anchor_def)
    var body_def = b3.default_body_def()
    body_def.type = b3.BodyType.b3_dynamicBody
    body_def.position = b3.Vec3(x = 0.0, y = 4.0, z = 0.0)
    let body = b3.create_body(world_id, body_def)
    common.track_body(body)
    let box = b3.make_box_hull(0.25, 0.75, 0.25)
    let shape_def = b3.default_shape_def()
    b3.create_hull_shape(body, shape_def, box.base)
    var joint_def = b3.default_revolute_joint_def()
    joint_def.base.bodyIdA = anchor
    joint_def.base.bodyIdB = body
    joint_def.base.localFrameA.p = b3.Vec3(x = 0.0, y = -0.5, z = 0.0)
    joint_def.base.localFrameB.p = b3.Vec3(x = 0.0, y = 0.75, z = 0.0)
    joint_def.enableMotor = true
    joint_def.maxMotorTorque = 10000.0
    joint_def.motorSpeed = 5.0
    let joint = b3.create_revolute_joint(world_id, joint_def)
    return RevoluteJoint(world = world_id, joint = joint, motor_speed = 5.0, max_torque = 10000.0)

extending RevoluteJoint:
    editable function on_step() -> void:
        pass

    editable function draw_overlay() -> void:
        common.draw_text_line("revolute joint: motor pendulum")
        gui.label(rl.Rectangle(x = 20.0, y = 60.0, width = 200.0, height = 24.0), "motor speed (rad/s)")
        let before = this.motor_speed
        gui.slider(rl.Rectangle(x = 20.0, y = 84.0, width = 220.0, height = 20.0), "0", "20", this.motor_speed, 0.0, 20.0)
        if this.motor_speed != before:
            b3.revolute_joint_set_motor_speed(this.joint, this.motor_speed)

function main() -> int:
    let world_id = common.create_world()
    var sample = revolute_joint_create(world_id)
    return common.run(adapt[common.Sample](ref_of(sample)), "Box3D - Revolute Joint", b3.Vec3(x = 0.0, y = 3.0, z = 0.0), 15.0)
