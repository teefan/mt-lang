## Box2D sample port: "Vertical Stack" (from box2d-upstream/samples/sample_stacking.cpp).
##
## A stack of boxes/circles that falls onto a ground segment with a wall on the
## right. Ported controls (upstream used ImGui):
##   B            fire bullets
##   C            toggle stack shape (circle / box)
##   V            toggle bullet shape
##   Arrow Up/Dn  adjust row count
##   Arrow Lt/Rt  adjust column count
##   + / -        adjust bullet count
##   R            reset stack
##   D            destroy the lowest body of each column
##   P            pause, Space single-step
##   Left mouse    drag bodies (mouse joint)

import std.box2d as b2
import std.raylib as rl
import examples.box2d.common as common

const MAX_COLUMNS: int = 10
const MAX_ROWS: int = 15
const MAX_BULLETS: int = 8
const MAX_BODIES: int = MAX_COLUMNS * MAX_ROWS

enum ShapeKind:
    circle
    box

struct VerticalStack implements common.Sample:
    world: b2.WorldId
    shape_kind: ShapeKind
    bullet_kind: ShapeKind
    row_count: int
    column_count: int
    bullet_count: int
    bodies: array[b2.BodyId, MAX_BODIES]
    bullets: array[b2.BodyId, MAX_BULLETS]

function vertical_stack_create(world_id: b2.WorldId) -> VerticalStack:
    var body_def = b2.default_body_def()
    body_def.position = b2.Vec2(x = 0.0, y = 0.0)
    let ground = b2.create_body(world_id, body_def)

    let shape_def = b2.default_shape_def()
    var segment = b2.Segment(
        point1 = b2.Vec2(x = 10.0, y = 0.0),
        point2 = b2.Vec2(x = 10.0, y = 20.0)
    )
    b2.create_segment_shape(ground, shape_def, segment)
    segment = b2.Segment(
        point1 = b2.Vec2(x = -30.0, y = 0.0),
        point2 = b2.Vec2(x = 30.0, y = 0.0)
    )
    b2.create_segment_shape(ground, shape_def, segment)

    var sample = VerticalStack(
        world = world_id,
        shape_kind = ShapeKind.box,
        bullet_kind = ShapeKind.circle,
        row_count = 12,
        column_count = 1,
        bullet_count = 1,
        bodies = zero[array[b2.BodyId, MAX_BODIES]],
        bullets = zero[array[b2.BodyId, MAX_BULLETS]]
    )
    var index = 0
    while index < MAX_BODIES:
        sample.bodies[index] = b2.b2_nullBodyId
        index += 1
    index = 0
    while index < MAX_BULLETS:
        sample.bullets[index] = b2.b2_nullBodyId
        index += 1
    sample.create_stacks()
    return sample

extending VerticalStack:
    editable function create_stacks() -> void:
        var index = 0
        while index < MAX_BODIES:
            if this.bodies[index] != b2.b2_nullBodyId:
                b2.destroy_body(this.bodies[index])
                this.bodies[index] = b2.b2_nullBodyId
            index += 1

        let circle = b2.Circle(center = b2.Vec2(x = 0.0, y = 0.0), radius = 0.5)
        let box = b2.make_rounded_box(0.45, 0.45, 0.05)

        var shape_def = b2.default_shape_def()
        shape_def.density = 1.0
        shape_def.material.friction = 0.3

        let offset = if this.shape_kind == ShapeKind.circle: 0.0 else: 0.01

        let dx = -3.0
        let xroot = 8.0
        var column = 0
        while column < this.column_count:
            let x = xroot + column * dx
            var row = 0
            while row < this.row_count:
                var body_def = b2.default_body_def()
                body_def.type = b2.BodyType.b2_dynamicBody
                let n = column * this.row_count + row
                let shift = if row % 2 == 0: -offset else: offset
                body_def.position = b2.Vec2(x = x + shift, y = 0.5 + row)
                let body = b2.create_body(this.world, body_def)
                this.bodies[n] = body
                if this.shape_kind == ShapeKind.circle:
                    b2.create_circle_shape(body, shape_def, circle)
                else:
                    b2.create_polygon_shape(body, shape_def, box)
                row += 1
            column += 1

    editable function destroy_body() -> void:
        var column = 0
        while column < this.column_count:
            var row = 0
            while row < this.row_count:
                let n = column * this.row_count + row
                if this.bodies[n] != b2.b2_nullBodyId:
                    b2.destroy_body(this.bodies[n])
                    this.bodies[n] = b2.b2_nullBodyId
                    break
                row += 1
            column += 1

    editable function destroy_bullets() -> void:
        var index = 0
        while index < MAX_BULLETS:
            if this.bullets[index] != b2.b2_nullBodyId:
                b2.destroy_body(this.bullets[index])
                this.bullets[index] = b2.b2_nullBodyId
            index += 1

    editable function fire_bullets() -> void:
        let circle = b2.Circle(center = b2.Vec2(x = 0.0, y = 0.0), radius = 0.25)
        let box = b2.make_box(0.25, 0.25)

        var shape_def = b2.default_shape_def()
        shape_def.density = 4.0

        var index = 0
        while index < this.bullet_count:
            var body_def = b2.default_body_def()
            body_def.type = b2.BodyType.b2_dynamicBody
            body_def.position = b2.Vec2(x = -26.7 - index, y = 6.0)
            let speed = common.random_float_range(200.0, 300.0)
            body_def.linearVelocity = b2.Vec2(x = speed, y = 0.0)
            body_def.isBullet = true

            let bullet = b2.create_body(this.world, body_def)

            if this.bullet_kind == ShapeKind.box:
                b2.create_polygon_shape(bullet, shape_def, box)
            else:
                b2.create_circle_shape(bullet, shape_def, circle)
            this.bullets[index] = bullet
            index += 1

    editable function on_step() -> void:
        if rl.is_key_pressed(rl.KeyboardKey.KEY_B):
            this.destroy_bullets()
            this.fire_bullets()
        if rl.is_key_pressed(rl.KeyboardKey.KEY_R):
            this.destroy_bullets()
            this.create_stacks()
        if rl.is_key_pressed(rl.KeyboardKey.KEY_D):
            this.destroy_body()
        if rl.is_key_pressed(rl.KeyboardKey.KEY_C):
            this.shape_kind = if this.shape_kind == ShapeKind.circle: ShapeKind.box else: ShapeKind.circle
            this.destroy_bullets()
            this.create_stacks()
        if rl.is_key_pressed(rl.KeyboardKey.KEY_V):
            this.bullet_kind = if this.bullet_kind == ShapeKind.circle: ShapeKind.box else: ShapeKind.circle
        if rl.is_key_pressed(rl.KeyboardKey.KEY_UP):
            this.row_count = common.min_int(this.row_count + 1, MAX_ROWS)
            this.destroy_bullets()
            this.create_stacks()
        if rl.is_key_pressed(rl.KeyboardKey.KEY_DOWN):
            this.row_count = common.max_int(this.row_count - 1, 1)
            this.destroy_bullets()
            this.create_stacks()
        if rl.is_key_pressed(rl.KeyboardKey.KEY_LEFT):
            this.column_count = common.max_int(this.column_count - 1, 1)
            this.destroy_bullets()
            this.create_stacks()
        if rl.is_key_pressed(rl.KeyboardKey.KEY_RIGHT):
            this.column_count = common.min_int(this.column_count + 1, MAX_COLUMNS)
            this.destroy_bullets()
            this.create_stacks()
        if rl.is_key_pressed(rl.KeyboardKey.KEY_EQUAL) or rl.is_key_pressed(rl.KeyboardKey.KEY_KP_ADD):
            this.bullet_count = common.min_int(this.bullet_count + 1, MAX_BULLETS)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_MINUS) or rl.is_key_pressed(rl.KeyboardKey.KEY_KP_SUBTRACT):
            this.bullet_count = common.max_int(this.bullet_count - 1, 1)

    function draw_overlay() -> void:
        common.draw_text_line(f"rows = #{this.row_count} columns = #{this.column_count} bullets = #{this.bullet_count}")
        common.draw_text_line("B: fire bullets  C: toggle shape  V: toggle bullet shape")
        common.draw_text_line("Arrows: rows/columns  +/-: bullets  R: reset  D: destroy body")

function main() -> int:
    let world_id = common.create_world()
    var sample = vertical_stack_create(world_id)
    return common.run(
        adapt[common.Sample](ref_of(sample)),
        "Box2D - Vertical Stack",
        b2.Vec2(x = -7.0, y = 9.0),
        14.0,
        world_id
    )
