module examples.idiomatic.raylib.fog_of_war

import std.mem.heap as heap
import std.raylib as rl
import std.span as sp

const map_tile_size: i32 = 32
const player_size: i32 = 16
const player_tile_visibility: i32 = 2
const screen_width: i32 = 800
const screen_height: i32 = 450

def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Fog Of War")
    defer rl.close_window()

    let tiles_x = 25
    let tiles_y = 15
    let tile_count = tiles_x * tiles_y
    let tile_ids_ptr = heap.must_alloc_zeroed[u8](usize<-tile_count)
    let tile_fog_ptr = heap.must_alloc_zeroed[u8](usize<-tile_count)
    defer:
        heap.release(tile_fog_ptr)
        heap.release(tile_ids_ptr)

    var tile_ids = sp.from_ptr[u8](tile_ids_ptr, usize<-tile_count)
    var tile_fog = sp.from_ptr[u8](tile_fog_ptr, usize<-tile_count)

    var player_position = rl.Vector2(x = 180.0, y = 130.0)
    var player_tile_x = 0
    var player_tile_y = 0
    let fog_of_war = rl.load_render_texture(tiles_x, tiles_y)
    rl.set_texture_filter(fog_of_war.texture, rl.TextureFilter.TEXTURE_FILTER_BILINEAR)
    rl.set_texture_wrap(fog_of_war.texture, rl.TextureWrap.TEXTURE_WRAP_CLAMP)
    defer rl.unload_render_texture(fog_of_war)

    for index in range(0, tile_count):
        tile_ids[index] = u8<-rl.get_random_value(0, 1)

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_key_down(rl.KeyboardKey.KEY_RIGHT):
            player_position.x += 5.0
        if rl.is_key_down(rl.KeyboardKey.KEY_LEFT):
            player_position.x -= 5.0
        if rl.is_key_down(rl.KeyboardKey.KEY_DOWN):
            player_position.y += 5.0
        if rl.is_key_down(rl.KeyboardKey.KEY_UP):
            player_position.y -= 5.0

        if player_position.x < 0.0:
            player_position.x = 0.0
        elif player_position.x + player_size > f32<-(tiles_x * map_tile_size):
            player_position.x = f32<-(tiles_x * map_tile_size - player_size)

        if player_position.y < 0.0:
            player_position.y = 0.0
        elif player_position.y + player_size > f32<-(tiles_y * map_tile_size):
            player_position.y = f32<-(tiles_y * map_tile_size - player_size)

        for index in range(0, tile_count):
            if tile_fog[index] == 1:
                tile_fog[index] = 2

        player_tile_x = i32<-((player_position.x + f32<-map_tile_size / 2.0) / f32<-map_tile_size)
        player_tile_y = i32<-((player_position.y + f32<-map_tile_size / 2.0) / f32<-map_tile_size)

        for y in range(player_tile_y - player_tile_visibility, player_tile_y + player_tile_visibility):
            for x in range(player_tile_x - player_tile_visibility, player_tile_x + player_tile_visibility):
                if x >= 0 and x < tiles_x and y >= 0 and y < tiles_y:
                    tile_fog[y * tiles_x + x] = 1

        rl.begin_texture_mode(fog_of_war)
        rl.clear_background(rl.BLANK)
        for y in range(0, tiles_y):
            for x in range(0, tiles_x):
                let fog_value = tile_fog[y * tiles_x + x]
                if fog_value == 0:
                    rl.draw_rectangle(x, y, 1, 1, rl.BLACK)
                elif fog_value == 2:
                    rl.draw_rectangle(x, y, 1, 1, rl.fade(rl.BLACK, 0.8))
        rl.end_texture_mode()

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)

        for y in range(0, tiles_y):
            for x in range(0, tiles_x):
                let tile_index = y * tiles_x + x
                let tile_color = if tile_ids[tile_index] == 0 then rl.BLUE else rl.fade(rl.BLUE, 0.9)
                rl.draw_rectangle(x * map_tile_size, y * map_tile_size, map_tile_size, map_tile_size, tile_color)
                rl.draw_rectangle_lines(x * map_tile_size, y * map_tile_size, map_tile_size, map_tile_size, rl.fade(rl.DARKBLUE, 0.5))

        rl.draw_rectangle_v(player_position, rl.Vector2(x = f32<-player_size, y = f32<-player_size), rl.RED)
        rl.draw_texture_pro(
            fog_of_war.texture,
            rl.Rectangle(x = 0.0, y = 0.0, width = f32<-fog_of_war.texture.width, height = -f32<-fog_of_war.texture.height),
            rl.Rectangle(x = 0.0, y = 0.0, width = f32<-(tiles_x * map_tile_size), height = f32<-(tiles_y * map_tile_size)),
            rl.Vector2(x = 0.0, y = 0.0),
            0.0,
            rl.WHITE,
        )
        rl.draw_text(rl.text_format_i32_i32("Current tile: [%i,%i]", player_tile_x, player_tile_y), 10, 10, 20, rl.RAYWHITE)
        rl.draw_text("ARROW KEYS to move", 10, screen_height - 25, 20, rl.RAYWHITE)

    return 0
