module examples.raylib.textures.textures_fog_of_war

import std.c.raylib as rl
import std.mem.heap as heap

struct Map:
    tiles_x: i32
    tiles_y: i32
    tile_ids: ptr[u8]
    tile_fog: ptr[u8]

const map_tile_size: i32 = 32
const player_size: i32 = 16
const player_tile_visibility: i32 = 2
const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [textures] example - fog of war"
const current_tile_format: cstr = c"Current tile: [%i,%i]"
const help_text: cstr = c"ARROW KEYS to move"


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var map = zero[Map]()
    map.tiles_x = 25
    map.tiles_y = 15
    var player_position = rl.Vector2(x = 180.0, y = 130.0)
    var player_tile_x = 0
    var player_tile_y = 0
    let fog_of_war = rl.LoadRenderTexture(map.tiles_x, map.tiles_y)
    rl.SetTextureFilter(fog_of_war.texture, rl.TextureFilter.TEXTURE_FILTER_BILINEAR)
    rl.SetTextureWrap(fog_of_war.texture, rl.TextureWrap.TEXTURE_WRAP_CLAMP)

    defer rl.UnloadRenderTexture(fog_of_war)

    unsafe:
        let tile_count = map.tiles_x * map.tiles_y
        map.tile_ids = heap.must_alloc_zeroed[u8](usize<-tile_count)
        map.tile_fog = heap.must_alloc_zeroed[u8](usize<-tile_count)

        defer:
            heap.release(map.tile_fog)
            heap.release(map.tile_ids)

        for index in range(0, tile_count):
            read(map.tile_ids + index) = u8<-rl.GetRandomValue(0, 1)

        rl.SetTargetFPS(60)

        while not rl.WindowShouldClose():
            if rl.IsKeyDown(rl.KeyboardKey.KEY_RIGHT):
                player_position.x += 5.0
            if rl.IsKeyDown(rl.KeyboardKey.KEY_LEFT):
                player_position.x -= 5.0
            if rl.IsKeyDown(rl.KeyboardKey.KEY_DOWN):
                player_position.y += 5.0
            if rl.IsKeyDown(rl.KeyboardKey.KEY_UP):
                player_position.y -= 5.0

            if player_position.x < 0.0:
                player_position.x = 0.0
            elif player_position.x + player_size > f32<-(map.tiles_x * map_tile_size):
                player_position.x = f32<-(map.tiles_x * map_tile_size - player_size)

            if player_position.y < 0.0:
                player_position.y = 0.0
            elif player_position.y + player_size > f32<-(map.tiles_y * map_tile_size):
                player_position.y = f32<-(map.tiles_y * map_tile_size - player_size)

            for index in range(0, tile_count):
                if read(map.tile_fog + index) == 1:
                    read(map.tile_fog + index) = 2

            player_tile_x = i32<-((player_position.x + f32<-map_tile_size / 2.0) / f32<-map_tile_size)
            player_tile_y = i32<-((player_position.y + f32<-map_tile_size / 2.0) / f32<-map_tile_size)

            for y in range(player_tile_y - player_tile_visibility, player_tile_y + player_tile_visibility):
                for x in range(player_tile_x - player_tile_visibility, player_tile_x + player_tile_visibility):
                    if x >= 0 and x < map.tiles_x and y >= 0 and y < map.tiles_y:
                        read(map.tile_fog + (y * map.tiles_x + x)) = 1

            rl.BeginTextureMode(fog_of_war)
            rl.ClearBackground(rl.BLANK)
            for y in range(0, map.tiles_y):
                for x in range(0, map.tiles_x):
                    let fog_value = read(map.tile_fog + (y * map.tiles_x + x))
                    if fog_value == 0:
                        rl.DrawRectangle(x, y, 1, 1, rl.BLACK)
                    elif fog_value == 2:
                        rl.DrawRectangle(x, y, 1, 1, rl.Fade(rl.BLACK, 0.8))
            rl.EndTextureMode()

            rl.BeginDrawing()
            rl.ClearBackground(rl.RAYWHITE)

            for y in range(0, map.tiles_y):
                for x in range(0, map.tiles_x):
                    let tile_index = y * map.tiles_x + x
                    let tile_color = if read(map.tile_ids + tile_index) == 0: rl.BLUE else: rl.Fade(rl.BLUE, 0.9)
                    rl.DrawRectangle(x * map_tile_size, y * map_tile_size, map_tile_size, map_tile_size, tile_color)
                    rl.DrawRectangleLines(x * map_tile_size, y * map_tile_size, map_tile_size, map_tile_size, rl.Fade(rl.DARKBLUE, 0.5))

            rl.DrawRectangleV(player_position, rl.Vector2(x = f32<-player_size, y = f32<-player_size), rl.RED)
            rl.DrawTexturePro(
                fog_of_war.texture,
                rl.Rectangle(x = 0.0, y = 0.0, width = f32<-fog_of_war.texture.width, height = -f32<-fog_of_war.texture.height),
                rl.Rectangle(x = 0.0, y = 0.0, width = f32<-(map.tiles_x * map_tile_size), height = f32<-(map.tiles_y * map_tile_size)),
                rl.Vector2(x = 0.0, y = 0.0),
                0.0,
                rl.WHITE,
            )
            rl.DrawText(rl.TextFormat(current_tile_format, player_tile_x, player_tile_y), 10, 10, 20, rl.RAYWHITE)
            rl.DrawText(help_text, 10, screen_height - 25, 20, rl.RAYWHITE)

            rl.EndDrawing()

    return 0
