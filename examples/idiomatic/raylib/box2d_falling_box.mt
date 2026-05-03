module examples.idiomatic.raylib.box2d_falling_box

import std.box2d as b2
import std.raylib as rl
import std.raylib.math as math

struct BoxSprite:
    body_id: b2.BodyId
    half_width: f32
    half_height: f32
    color: rl.Color

const screen_width: i32 = 960
const screen_height: i32 = 640
const pixels_per_meter: f32 = 48.0
const time_step: f32 = 1.0 / 60.0
const sub_step_count: i32 = 4

def create_static_box(world_id: b2.WorldId, position: b2.Vec2, half_width: f32, half_height: f32) -> b2.BodyId:
    var body_def = b2.default_body_def()
    body_def.position = position
    let body_id = b2.create_body(world_id, in body_def)
    b2.body_set_type(body_id, b2.BodyType.b2_dynamicBody)
    let shape_def = b2.default_shape_def()
    let polygon = b2.make_box(half_width, half_height)
    b2.create_polygon_shape(body_id, in shape_def, in polygon)
    return body_id

def create_dynamic_box(world_id: b2.WorldId, position: b2.Vec2, half_width: f32, half_height: f32, density: f32) -> b2.BodyId:
    var body_def = b2.default_body_def()
    body_def.position = position
    let body_id = b2.create_body(world_id, in body_def)
    b2.body_set_type(body_id, b2.BodyType.b2_dynamicBody)

    var shape_def = b2.default_shape_def()
    shape_def.density = density
    let polygon = b2.make_box(half_width, half_height)
    b2.create_polygon_shape(body_id, in shape_def, in polygon)
    return body_id

def to_screen(position: b2.Vec2) -> rl.Vector2:
    return rl.Vector2(
        x = position.x * pixels_per_meter,
        y = position.y * pixels_per_meter,
    )

def body_angle_degrees(body_id: b2.BodyId) -> f32:
    let rotation = b2.body_get_rotation(body_id)
    return math.atan2(rotation.s, rotation.c) * math.rad2deg

def draw_box(sprite: BoxSprite) -> void:
    let center = to_screen(b2.body_get_position(sprite.body_id))
    let width = sprite.half_width * pixels_per_meter * 2.0
    let height = sprite.half_height * pixels_per_meter * 2.0

    rl.draw_rectangle_pro(
        rl.Rectangle(
            x = center.x,
            y = center.y,
            width = width,
            height = height,
        ),
        rl.Vector2(x = width * 0.5, y = height * 0.5),
        body_angle_degrees(sprite.body_id),
        sprite.color,
    )

def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Box2D Falling Box")
    defer rl.close_window()
    rl.set_target_fps(60)

    var world_def = b2.default_world_def()
    world_def.gravity = b2.Vec2(x = 0.0, y = 18.0)

    let world_id = b2.create_world(in world_def)
    defer b2.destroy_world(world_id)

    let ground_sprite = BoxSprite(
        body_id = create_static_box(world_id, b2.Vec2(x = 10.0, y = 12.2), 8.5, 0.45),
        half_width = 8.5,
        half_height = 0.45,
        color = rl.Color(r = 44, g = 62, b = 80, a = 255),
    )

    let start_position = b2.Vec2(x = 10.0, y = 3.0)
    let box_half_width: f32 = 0.6
    let box_half_height: f32 = 0.6
    let dynamic_body_id = create_dynamic_box(world_id, start_position, box_half_width, box_half_height, 1.0)
    let dynamic_sprite = BoxSprite(
        body_id = dynamic_body_id,
        half_width = box_half_width,
        half_height = box_half_height,
        color = rl.Color(r = 235, g = 137, b = 52, a = 255),
    )

    while not rl.window_should_close():
        if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            b2.body_apply_linear_impulse_to_center(dynamic_body_id, b2.Vec2(x = 5.0, y = -7.5), true)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_R):
            b2.body_set_transform(dynamic_body_id, start_position, b2.b2Rot_identity)
            b2.body_set_linear_velocity(dynamic_body_id, b2.b2Vec2_zero)
            b2.body_set_angular_velocity(dynamic_body_id, 0.0)
            b2.body_set_awake(dynamic_body_id, true)

        b2.world_step(world_id, time_step, sub_step_count)

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.Color(r = 245, g = 239, b = 230, a = 255))
        draw_box(ground_sprite)
        draw_box(dynamic_sprite)
        rl.draw_text("SPACE launches the box", 24, 20, 20, rl.DARKGRAY)
        rl.draw_text("R resets the body transform", 24, 48, 20, rl.DARKGRAY)
        rl.draw_fps(screen_width - 96, 16)

    return 0