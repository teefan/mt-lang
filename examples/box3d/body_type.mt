## Box3D sample port: "Body Types / Kinematic" (from box3d-upstream/samples/sample_bodies.cpp).
##
## A kinematic platform swings on a driven path and carries a dynamic box, with
## a static ground and a second dynamic box that gets knocked around. Cycling
## the platform type shows the three body kinds side by side.
##   Left mouse     drag dynamic bodies (ray spring)
##   Right mouse    orbit camera
##   Wheel          zoom
##   P              pause, Space single-step
import std.box3d as b3
import std.math as math
import std.raygui as gui
import std.raylib as rl
import examples.box3d.common as common

struct BodyType implements common.Sample:
    platform: b3.BodyId
    payload: b3.BodyId
    time: float

function body_type_create(world_id: b3.WorldId) -> BodyType:
    common.add_ground_box(20.0)
    # kinematic swinging platform
    var platform_def = b3.default_body_def()
    platform_def.type = b3.BodyType.b3_kinematicBody
    platform_def.position = b3.Vec3(x = 4.0, y = 2.0, z = 0.0)
    let platform = b3.create_body(world_id, platform_def)
    common.track_body(platform)
    let platform_box = b3.make_box_hull(0.1, 1.0, 0.2)
    let platform_shape = b3.default_shape_def()
    b3.create_hull_shape(platform, platform_shape, platform_box.base)
    # dynamic payload resting on the platform
    var payload_def = b3.default_body_def()
    payload_def.type = b3.BodyType.b3_dynamicBody
    payload_def.position = b3.Vec3(x = 4.0, y = 3.5, z = 0.0)
    let payload = b3.create_body(world_id, payload_def)
    common.track_body(payload)
    let payload_box = b3.make_box_hull(0.3, 0.3, 0.3)
    let payload_shape = b3.default_shape_def()
    b3.create_hull_shape(payload, payload_shape, payload_box.base)
    return BodyType(platform = platform, payload = payload, time = 0.0)

extending BodyType:
    editable function on_step() -> void:
        this.time += 1.0 / common.HERTZ
        if this.time > 2.0:
            let t = this.time - 2.0
            let point = b3.Vec3(x = 4.0 * float<-math.cos(double<-t), y = 1.0 * (float<-math.sin(double<-(2.0 * t)) + 1.0) + 1.0, z = 0.0)
            let rotation = common.quat_from_axis_angle(b3.b3Vec3_axisZ, 2.0 * t)
            b3.body_set_target_transform(this.platform, b3.Transform(p = point, q = rotation), 1.0 / common.HERTZ, true)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_T):
            this.toggle_platform()

    function toggle_platform() -> void:
        let current = b3.body_get_type(this.platform)
        let next_type = if current == b3.BodyType.b3_kinematicBody: b3.BodyType.b3_dynamicBody else: b3.BodyType.b3_kinematicBody
        b3.body_set_type(this.platform, next_type)

    editable function draw_overlay() -> void:
        let body_kind = b3.body_get_type(this.platform)
        let label = if body_kind == b3.BodyType.b3_kinematicBody: "kinematic" else: "dynamic"
        common.draw_text_line(f"platform type: #{label} (T to toggle)")
        common.draw_text_line("Left mouse drags dynamic bodies")
        let pressed = gui.button(rl.Rectangle(x = 20.0, y = 60.0, width = 180.0, height = 30.0), f"Toggle type (currently #{label})")
        if pressed != 0:
            this.toggle_platform()

function main() -> int:
    let world_id = common.create_world()
    var sample = body_type_create(world_id)
    return common.run(adapt[common.Sample](ref_of(sample)), "Box3D - Body Type", b3.Vec3(x = 0.0, y = 2.0, z = 0.0), 15.0)
