## Box3D sample port: "Spherical Joint" (from box3d-upstream/samples/sample_joint.cpp).
##
## A box hangs from a fixed anchor on a spherical (ball-and-socket) joint with a
## soft spring, swinging freely in 3D with a cone limit.
##   Left mouse     drag bodies (ray spring)
##   Right mouse    orbit camera
##   Wheel          zoom
##   P              pause, Space single-step
import std.box3d as b3
import std.raygui as gui
import std.raylib as rl
import examples.box3d.common as common

struct SphericalJoint implements common.Sample:
    world: b3.WorldId
    joint: b3.JointId
    spring: bool
    hertz: float

function spherical_joint_create(world_id: b3.WorldId) -> SphericalJoint:
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
    var joint_def = b3.default_spherical_joint_def()
    joint_def.base.bodyIdA = anchor
    joint_def.base.bodyIdB = body
    joint_def.base.localFrameA.p = b3.Vec3(x = 0.0, y = -0.5, z = 0.0)
    joint_def.base.localFrameB.p = b3.Vec3(x = 0.0, y = 0.75, z = 0.0)
    joint_def.enableSpring = true
    joint_def.hertz = 2.0
    joint_def.dampingRatio = 0.7
    joint_def.enableConeLimit = true
    joint_def.coneAngle = 30.0 * common.DEG_TO_RAD
    let joint = b3.create_spherical_joint(world_id, joint_def)
    return SphericalJoint(world = world_id, joint = joint, spring = true, hertz = 2.0)

extending SphericalJoint:
    editable function on_step() -> void:
        pass

    editable function draw_overlay() -> void:
        common.draw_text_line("spherical joint: ball-and-socket with cone limit")
        let spring_before = this.spring
        gui.check_box(rl.Rectangle(x = 20.0, y = 60.0, width = 24.0, height = 24.0), "spring", this.spring)
        if this.spring != spring_before:
            b3.spherical_joint_enable_spring(this.joint, this.spring)
        gui.label(rl.Rectangle(x = 20.0, y = 96.0, width = 200.0, height = 24.0), "spring hertz")
        let before = this.hertz
        gui.slider(rl.Rectangle(x = 20.0, y = 120.0, width = 220.0, height = 20.0), "0", "10", this.hertz, 0.0, 10.0)
        if this.hertz != before:
            b3.spherical_joint_set_spring_hertz(this.joint, this.hertz)

function main() -> int:
    let world_id = common.create_world()
    var sample = spherical_joint_create(world_id)
    return common.run(adapt[common.Sample](ref_of(sample)), "Box3D - Spherical Joint", b3.Vec3(x = 0.0, y = 3.0, z = 0.0), 15.0)
