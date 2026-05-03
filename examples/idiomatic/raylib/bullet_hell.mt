module examples.idiomatic.raylib.bullet_hell

import std.mem.heap as heap
import std.raylib as rl
import std.raylib.math as math
import std.span as sp

struct Bullet:
    position: rl.Vector2
    acceleration: rl.Vector2
    disabled: bool
    color: rl.Color

const screen_width: i32 = 800
const screen_height: i32 = 450
const max_bullets: i32 = 500000

def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Bullet Hell")
    defer rl.close_window()

    let bullets = heap.must_alloc_zeroed[Bullet](usize<-max_bullets)
    defer heap.release(bullets)
    var bullets_view = sp.from_ptr[Bullet](bullets, usize<-max_bullets)

    var bullet_count = 0
    var bullet_disabled_count = 0
    let bullet_radius = 10
    var bullet_speed: f32 = 3.0
    var bullet_rows = 6
    let bullet_colors = array[rl.Color, 2](rl.RED, rl.BLUE)

    var base_direction: f32 = 0.0
    var angle_increment = 5
    var spawn_cooldown: f32 = 2.0
    var spawn_cooldown_timer: f32 = spawn_cooldown
    var magic_circle_rotation: f32 = 0.0

    let bullet_texture = rl.load_render_texture(24, 24)
    defer rl.unload_render_texture(bullet_texture)

    rl.begin_texture_mode(bullet_texture)
    rl.draw_circle(12, 12, f32<-bullet_radius, rl.WHITE)
    rl.draw_circle_lines(12, 12, f32<-bullet_radius, rl.BLACK)
    rl.end_texture_mode()

    var draw_in_performance_mode = true

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if bullet_count >= max_bullets:
            bullet_count = 0
            bullet_disabled_count = 0

        spawn_cooldown_timer -= 1.0
        if spawn_cooldown_timer < 0.0:
            spawn_cooldown_timer = spawn_cooldown

            let degrees_per_row = 360.0 / f32<-bullet_rows
            for row in range(0, bullet_rows):
                if bullet_count < max_bullets:
                    bullets_view[bullet_count].position = rl.Vector2(x = screen_width / 2.0, y = screen_height / 2.0)
                    bullets_view[bullet_count].disabled = false
                    bullets_view[bullet_count].color = bullet_colors[row % 2]

                    let bullet_direction = base_direction + degrees_per_row * f32<-row
                    let radians = bullet_direction * math.deg2rad
                    bullets_view[bullet_count].acceleration = rl.Vector2(
                        x = bullet_speed * math.cos(radians),
                        y = bullet_speed * math.sin(radians),
                    )

                    bullet_count += 1

            base_direction += f32<-angle_increment

        for index in range(0, bullet_count):
            if not bullets_view[index].disabled:
                bullets_view[index].position.x += bullets_view[index].acceleration.x
                bullets_view[index].position.y += bullets_view[index].acceleration.y

                let out_of_bounds = bullets_view[index].position.x < -f32<-(bullet_radius * 2) or bullets_view[index].position.x > f32<-(screen_width + bullet_radius * 2) or bullets_view[index].position.y < -f32<-(bullet_radius * 2) or bullets_view[index].position.y > f32<-(screen_height + bullet_radius * 2)
                if out_of_bounds:
                    bullets_view[index].disabled = true
                    bullet_disabled_count += 1

        if (rl.is_key_pressed(rl.KeyboardKey.KEY_RIGHT) or rl.is_key_pressed(rl.KeyboardKey.KEY_D)) and bullet_rows < 359:
            bullet_rows += 1
        if (rl.is_key_pressed(rl.KeyboardKey.KEY_LEFT) or rl.is_key_pressed(rl.KeyboardKey.KEY_A)) and bullet_rows > 1:
            bullet_rows -= 1
        if rl.is_key_pressed(rl.KeyboardKey.KEY_UP) or rl.is_key_pressed(rl.KeyboardKey.KEY_W):
            bullet_speed += 0.25
        if (rl.is_key_pressed(rl.KeyboardKey.KEY_DOWN) or rl.is_key_pressed(rl.KeyboardKey.KEY_S)) and bullet_speed > 0.50:
            bullet_speed -= 0.25
        if rl.is_key_pressed(rl.KeyboardKey.KEY_Z) and spawn_cooldown > 1.0:
            spawn_cooldown -= 1.0
        if rl.is_key_pressed(rl.KeyboardKey.KEY_X):
            spawn_cooldown += 1.0
        if rl.is_key_pressed(rl.KeyboardKey.KEY_ENTER):
            draw_in_performance_mode = not draw_in_performance_mode

        if rl.is_key_down(rl.KeyboardKey.KEY_SPACE):
            angle_increment += 1
            angle_increment = angle_increment % 360

        if rl.is_key_pressed(rl.KeyboardKey.KEY_C):
            bullet_count = 0
            bullet_disabled_count = 0

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)

        magic_circle_rotation += 1.0
        rl.draw_rectangle_pro(
            rl.Rectangle(x = screen_width / 2.0, y = screen_height / 2.0, width = 120.0, height = 120.0),
            rl.Vector2(x = 60.0, y = 60.0),
            magic_circle_rotation,
            rl.PURPLE,
        )
        rl.draw_rectangle_pro(
            rl.Rectangle(x = screen_width / 2.0, y = screen_height / 2.0, width = 120.0, height = 120.0),
            rl.Vector2(x = 60.0, y = 60.0),
            magic_circle_rotation + 45.0,
            rl.PURPLE,
        )
        rl.draw_circle_lines(screen_width / 2, screen_height / 2, 70.0, rl.BLACK)
        rl.draw_circle_lines(screen_width / 2, screen_height / 2, 50.0, rl.BLACK)
        rl.draw_circle_lines(screen_width / 2, screen_height / 2, 30.0, rl.BLACK)

        if draw_in_performance_mode:
            for index in range(0, bullet_count):
                if not bullets_view[index].disabled:
                    rl.draw_texture(
                        bullet_texture.texture,
                        i32<-(bullets_view[index].position.x - f32<-bullet_texture.texture.width * 0.5),
                        i32<-(bullets_view[index].position.y - f32<-bullet_texture.texture.height * 0.5),
                        bullets_view[index].color,
                    )
        else:
            for index in range(0, bullet_count):
                if not bullets_view[index].disabled:
                    rl.draw_circle_v(bullets_view[index].position, f32<-bullet_radius, bullets_view[index].color)
                    rl.draw_circle_lines_v(bullets_view[index].position, f32<-bullet_radius, rl.BLACK)

        let overlay_color = rl.Color(r = 0, g = 0, b = 0, a = 200)
        rl.draw_rectangle(10, 10, 280, 150, overlay_color)
        rl.draw_text("Controls:", 20, 20, 10, rl.LIGHTGRAY)
        rl.draw_text("- Right/Left or A/D: Change rows number", 40, 40, 10, rl.LIGHTGRAY)
        rl.draw_text("- Up/Down or W/S: Change bullet speed", 40, 60, 10, rl.LIGHTGRAY)
        rl.draw_text("- Z or X: Change spawn cooldown", 40, 80, 10, rl.LIGHTGRAY)
        rl.draw_text("- Space (Hold): Change the angle increment", 40, 100, 10, rl.LIGHTGRAY)
        rl.draw_text("- Enter: Switch draw method (Performance)", 40, 120, 10, rl.LIGHTGRAY)
        rl.draw_text("- C: Clear bullets", 40, 140, 10, rl.LIGHTGRAY)

        rl.draw_rectangle(610, 10, 170, 30, overlay_color)
        if draw_in_performance_mode:
            rl.draw_text("Draw method: DrawTexture(*)", 620, 20, 10, rl.GREEN)
        else:
            rl.draw_text("Draw method: DrawCircle(*)", 620, 20, 10, rl.RED)

        rl.draw_rectangle(135, 410, 530, 30, overlay_color)
        rl.draw_text(rl.text_format_i32("FPS: %d", rl.get_fps()), 155, 420, 10, rl.GREEN)
        rl.draw_text(rl.text_format_i32("Bullets: %d", bullet_count - bullet_disabled_count), 225, 420, 10, rl.GREEN)
        rl.draw_text(rl.text_format_i32("Rows: %d", bullet_rows), 325, 420, 10, rl.GREEN)
        rl.draw_text(rl.text_format_f32("Speed: %.2f", bullet_speed), 400, 420, 10, rl.GREEN)
        rl.draw_text(rl.text_format_i32("Angle: %d", angle_increment), 490, 420, 10, rl.GREEN)
        rl.draw_text(rl.text_format_f32("Cooldown: %.0f", spawn_cooldown), 565, 420, 10, rl.GREEN)

    return 0