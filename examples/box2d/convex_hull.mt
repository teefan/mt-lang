## Box2D sample port: "Convex Hull" (from box2d-upstream/samples/sample_geometry.cpp).
##
## Generates random point sets, computes their convex hull, and validates it.
##   G             generate a new point set
##   A             toggle auto-generate each step
##   B             toggle bulk defect-hunting mode
##   Left mouse    drag bodies (mouse joint)
##   P             pause, Space single-step

import std.box2d as b2
import std.raylib as rl
import examples.box2d.common as common

const MAX_POINTS: int = 8

struct ConvexHull implements common.Sample:
    world: b2.WorldId
    points: array[b2.Vec2, MAX_POINTS]
    count: int
    hull: b2.Hull
    valid: bool
    generation: int
    auto: bool
    bulk: bool

function convex_hull_create(world_id: b2.WorldId) -> ConvexHull:
    var sample = ConvexHull(
        world = world_id,
        points = zero[array[b2.Vec2, MAX_POINTS]],
        count = MAX_POINTS,
        hull = b2.Hull(points = zero[array[b2.Vec2, 8]], count = 0),
        valid = false,
        generation = 0,
        auto = false,
        bulk = false
    )
    sample.generate()
    sample.compute_hull()
    return sample

extending ConvexHull:
    editable function generate() -> void:
        let angle = b2.B2_PI * common.random_float()
        let r = common.make_rot(angle)
        var index = 0
        while index < MAX_POINTS:
            let x = 10.0 * common.random_float()
            let y = 10.0 * common.random_float()
            let v = b2.Vec2(
                x = common.clamp_float(x, -4.0, 4.0),
                y = common.clamp_float(y, -4.0, 4.0)
            )
            this.points[index] = r.mul_vector(v)
            index += 1
        this.generation += 1

    editable function compute_hull() -> void:
        this.hull = b2.compute_hull(const_ptr_of(this.points[0]), this.count)
        if this.hull.count > 0: this.valid = b2.validate_hull(const_ptr_of(this.hull)) else: this.valid = false

    editable function on_step() -> void:
        if rl.is_key_pressed(rl.KeyboardKey.KEY_G):
            this.generate()
            this.compute_hull()
        if rl.is_key_pressed(rl.KeyboardKey.KEY_A):
            this.auto = not this.auto
        if rl.is_key_pressed(rl.KeyboardKey.KEY_B):
            this.bulk = not this.bulk
        if this.bulk:
            var still_valid = true
            var iteration = 0
            while iteration < 10000 and still_valid:
                this.generate()
                let hull = b2.compute_hull(const_ptr_of(this.points[0]), this.count)
                if hull.count > 0:
                    still_valid = b2.validate_hull(const_ptr_of(hull))
                iteration += 1
            this.bulk = still_valid
            this.compute_hull()
        else if this.auto:
            this.generate()
            this.compute_hull()

    function draw_overlay() -> void:
        common.draw_world_solid_polygon(
            b2.b2Transform_identity,
            const_ptr_of(this.hull.points[0]),
            this.hull.count,
            b2.HexColor.b2_colorGray
        )
        var index = 0
        while index < this.count:
            common.draw_world_point(this.points[index], 5.0, b2.HexColor.b2_colorBlue)
            index += 1
        index = 0
        while index < this.hull.count:
            common.draw_world_point(this.hull.points[index], 6.0, b2.HexColor.b2_colorGreen)
            index += 1
        if not this.valid:
            common.draw_text_line(f"generation = #{this.generation}, FAILED")
        else:
            common.draw_text_line(f"generation = #{this.generation}, count = #{this.hull.count}")
        common.draw_text_line("G: generate  A: auto  B: bulk")

function main() -> int:
    let world_id = common.create_world()
    var sample = convex_hull_create(world_id)
    return common.run(
        adapt[common.Sample](ref_of(sample)),
        "Box2D - Convex Hull",
        b2.Vec2(x = 0.0, y = 0.0),
        5.0,
        world_id
    )
