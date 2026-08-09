## Box2D sample port: "Ragdoll" (from box2d-upstream/samples/sample_joints.cpp).
##
## A humanoid ragdoll built from eleven capsule bones and revolute joints drops
## onto the ground. Joint friction, spring hertz, and damping are adjustable.
##   R             respawn the ragdoll
##   [ / ]         joint friction torque
##   - / =         joint spring hertz
##   , / .         joint spring damping ratio
##   Left mouse    drag bodies (mouse joint)
##   P             pause, Space single-step

import std.box2d as b2
import std.raylib as rl
import examples.box2d.common as common
import examples.box2d.human as human

struct Ragdoll implements common.Sample:
    world: b2.WorldId
    human: human.Human
    friction_torque: float
    hertz: float
    damping_ratio: float

function ragdoll_create(world_id: b2.WorldId) -> Ragdoll:
    let body_def = b2.default_body_def()
    let ground = b2.create_body(world_id, body_def)
    let segment = b2.Segment(
        point1 = b2.Vec2(x = -20.0, y = 0.0),
        point2 = b2.Vec2(x = 20.0, y = 0.0)
    )
    b2.create_segment_shape(ground, b2.default_shape_def(), segment)

    let sample = Ragdoll(
        world = world_id,
        human = human.create_human(world_id, b2.Vec2(x = 0.0, y = 25.0), 1.0, 0.03, 5.0, 0.5, 1),
        friction_torque = 0.03,
        hertz = 5.0,
        damping_ratio = 0.5
    )

    b2.world_set_contact_tuning(world_id, 240.0, 0.0, 2.0)
    return sample

extending Ragdoll:
    editable function respawn() -> void:
        human.destroy_human(ref_of(this.human))
        this.human = human.create_human(
            this.world,
            b2.Vec2(x = 0.0, y = 25.0),
            1.0,
            this.friction_torque,
            this.hertz,
            this.damping_ratio,
            1
        )

    editable function on_step() -> void:
        if rl.is_key_pressed(rl.KeyboardKey.KEY_R):
            this.respawn()
        if rl.is_key_pressed(rl.KeyboardKey.KEY_LEFT_BRACKET):
            this.friction_torque = common.max_float(this.friction_torque - 0.01, 0.0)
            human.human_set_joint_friction_torque(ref_of(this.human), this.friction_torque)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_RIGHT_BRACKET):
            this.friction_torque = common.min_float(this.friction_torque + 0.01, 1.0)
            human.human_set_joint_friction_torque(ref_of(this.human), this.friction_torque)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_MINUS):
            this.hertz = common.max_float(this.hertz - 0.5, 0.0)
            human.human_set_joint_spring_hertz(ref_of(this.human), this.hertz)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_EQUAL):
            this.hertz = common.min_float(this.hertz + 0.5, 10.0)
            human.human_set_joint_spring_hertz(ref_of(this.human), this.hertz)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_COMMA):
            this.damping_ratio = common.max_float(this.damping_ratio - 0.1, 0.0)
            human.human_set_joint_damping_ratio(ref_of(this.human), this.damping_ratio)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_PERIOD):
            this.damping_ratio = common.min_float(this.damping_ratio + 0.1, 4.0)
            human.human_set_joint_damping_ratio(ref_of(this.human), this.damping_ratio)

    function draw_overlay() -> void:
        common.draw_text_line(f"friction = #{this.friction_torque:.3} hertz = #{this.hertz:.1}")
        common.draw_text_line(f"damping = #{this.damping_ratio:.1}  R: respawn  []: friction")
        common.draw_text_line("R: respawn  []: friction  -/=: hertz  ,/.: damping")

function main() -> int:
    let world_id = common.create_world()
    var sample = ragdoll_create(world_id)
    return common.run(
        adapt[common.Sample](ref_of(sample)),
        "Box2D - Ragdoll",
        b2.Vec2(x = 0.0, y = 12.0),
        16.0,
        world_id
    )
