## Box3D sample port: "Ray Cast" (from box3d-upstream/samples/sample_collision.cpp).
##
## A ray sweeps in a circle around a pile of boxes. The closest hit point and
## normal are drawn in red, and the unblocked ray is drawn in yellow.
##   Left mouse     drag bodies (ray spring)
##   Right mouse    orbit camera
##   Wheel          zoom
##   P              pause, Space single-step
import std.box3d as b3
import std.math as math
import std.raylib as rl
import examples.box3d.common as common

const PILE_COUNT: int = 10

struct RayCast implements common.Sample:
    world: b3.WorldId
    time: float

function ray_cast_create(world_id: b3.WorldId) -> RayCast:
    common.add_ground_box(20.0)
    let box = b3.make_box_hull(0.5, 0.5, 0.5)
    var index = 0
    while index < PILE_COUNT:
        var box_body_def = b3.default_body_def()
        box_body_def.type = b3.BodyType.b3_dynamicBody
        box_body_def.position = b3.Vec3(x = common.random_float_range(-2.0, 2.0), y = 0.5 + 1.1 * (common.random_int() % 4), z = common.random_float_range(-2.0, 2.0))
        let body = b3.create_body(world_id, box_body_def)
        common.track_body(body)
        let shape_def = b3.default_shape_def()
        b3.create_hull_shape(body, shape_def, box.base)
        index += 1
    return RayCast(world = world_id, time = 0.0)

function draw_ray_scene() -> void:
    let origin = b3.Vec3(x = 0.0, y = 3.0, z = 0.0)
    let direction = b3.Vec3(x = float<-math.cos(double<-common.HERTZ * 0.5), y = 0.0, z = float<-math.sin(double<-common.HERTZ * 0.5)).normalize()
    let end = origin.add(direction.scale(10.0))
    # cast ray (uses the shared world from common)
    let filter = b3.default_query_filter()
    let result = b3.world_cast_ray_closest(common.world_id(), origin, direction.scale(10.0), filter)
    if result.hit:
        rl.draw_line_3d(common.to_rl_v3(origin), common.to_rl_v3(result.point), rl.YELLOW)
        rl.draw_sphere(common.to_rl_v3(result.point), 0.15, rl.RED)
        rl.draw_line_3d(common.to_rl_v3(result.point), common.to_rl_v3(result.point.add(result.normal)), rl.BLUE)
    else:
        rl.draw_line_3d(common.to_rl_v3(origin), common.to_rl_v3(end), rl.YELLOW)

extending RayCast:
    editable function on_step() -> void:
        this.time += 1.0 / common.HERTZ

    editable function draw_overlay() -> void:
        common.draw_text_line("ray cast: closest hit shown in red")

function main() -> int:
    let world_id = common.create_world()
    var sample = ray_cast_create(world_id)
    common.set_scene_draw(draw_ray_scene)
    return common.run(adapt[common.Sample](ref_of(sample)), "Box3D - Ray Cast", b3.Vec3(x = 0.0, y = 2.0, z = 0.0), 14.0)
