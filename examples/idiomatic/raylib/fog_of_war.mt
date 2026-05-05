module examples.idiomatic.raylib.fog_of_war

import std.mem.heap as heap
import std.raylib as rl
import std.span as sp

const map_tile_size: int = 32
const player_size: int = 16
const player_tile_visibility: int = 2
const screen_width: int = 800
const screen_height: int = 450


def main() -> int:
    rl.init_window(screen_width, screen_height, "Milk Tea Fog Of War")
    defer rl.close_window()

    let tiles_x = 25
    let tiles_y = 15
    let tile_count = tiles_x * tiles_y
    let tile_ids_ptr = heap.must_alloc_zeroed[ubyte](ptr_uint<-tile_count)
    let tile_fog_ptr = heap.must_alloc_zeroed[ubyte](ptr_uint<-tile_count)
    defer:
        heap.release(tile_fog_ptr)
        heap.release(tile_ids_ptr)

    var tile_ids = sp.from_ptr[ubyte](tile_ids_ptr, ptr_uint<-tile_count)
    var tile_fog = sp.from_ptr[ubyte](tile_fog_ptr, ptr_uint<-tile_count)

    var player_position = rl.Vector2(x = 180.0, y = 130.0)
    var player_tile_x = 0
    var player_tile_y = 0
    let fog_of_war = rl.load_render_texture(tiles_x, tiles_y)
    rl.set_texture_filter(fog_of_war.texture, rl.TextureFilter.TEXTURE_FILTER_BILINEAR)
    rl.set_texture_wrap(fog_of_war.texture, rl.TextureWrap.TEXTURE_WRAP_CLAMP)
    defer rl.unload_render_texture(fog_of_war)

    for index in 0..tile_count:
        tile_ids[index] = ubyte<-rl.get_random_value(0, 1)

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
        elif player_position.x + player_size > float<-(tiles_x * map_tile_size):
            player_position.x = float<-(tiles_x * map_tile_size - player_size)

        if player_position.y < 0.0:
            player_position.y = 0.0
        elif player_position.y + player_size > float<-(tiles_y * map_tile_size):
            player_position.y = float<-(tiles_y * map_tile_size - player_size)

        for index in 0..tile_count:
            if tile_fog[index] == 1:
                tile_fog[index] = 2

        player_tile_x = int<-((player_position.x + float<-map_tile_size / 2.0) / float<-map_tile_size)
        player_tile_y = int<-((player_position.y + float<-map_tile_size / 2.0) / float<-map_tile_size)

        for y in player_tile_y - player_tile_visibility..player_tile_y + player_tile_visibility:
            for x in player_tile_x - player_tile_visibility..player_tile_x + player_tile_visibility:
                if x >= 0 and x < tiles_x and y >= 0 and y < tiles_y:
                    tile_fog[y * tiles_x + x] = 1

        rl.begin_texture_mode(fog_of_war)
        rl.clear_background(rl.BLANK)
        for y in 0..tiles_y:
            for x in 0..tiles_x:
                let fog_value = tile_fog[y * tiles_x + x]
                if fog_value == 0:
                    rl.draw_rectangle(x, y, 1, 1, rl.BLACK)
                elif fog_value == 2:
                    rl.draw_rectangle(x, y, 1, 1, rl.fade(rl.BLACK, 0.8))
        rl.end_texture_mode()

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)

        for y in 0..tiles_y:
            for x in 0..tiles_x:
                let tile_index = y * tiles_x + x
                let tile_color = if tile_ids[tile_index] == 0: rl.BLUE else: rl.fade(rl.BLUE, 0.9)
                rl.draw_rectangle(x * map_tile_size, y * map_tile_size, map_tile_size, map_tile_size, tile_color)
                rl.draw_rectangle_lines(x * map_tile_size, y * map_tile_size, map_tile_size, map_tile_size, rl.fade(rl.DARKBLUE, 0.5))

        rl.draw_rectangle_v(player_position, rl.Vector2(x = float<-player_size, y = float<-player_size), rl.RED)
        rl.draw_texture_pro(
            fog_of_war.texture,
            rl.Rectangle(x = 0.0, y = 0.0, width = float<-fog_of_war.texture.width, height = -float<-fog_of_war.texture.height),
            rl.Rectangle(x = 0.0, y = 0.0, width = float<-(tiles_x * map_tile_size), height = float<-(tiles_y * map_tile_size)),
            rl.Vector2(x = 0.0, y = 0.0),
            0.0,
            rl.WHITE,
        )
        rl.draw_text(rl.text_format_int_int("Current tile: [%i,%i]", player_tile_x, player_tile_y), 10, 10, 20, rl.RAYWHITE)
        rl.draw_text("ARROW KEYS to move", 10, screen_height - 25, 20, rl.RAYWHITE)

    return 0
