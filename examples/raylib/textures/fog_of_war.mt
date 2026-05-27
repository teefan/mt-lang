import std.raylib as rl


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const MAP_TILE_SIZE: int = 32
const PLAYER_SIZE: int = 16
const PLAYER_TILE_VISIBILITY: int = 2
const MAP_TILES_X: int = 25
const MAP_TILES_Y: int = 15
const MAP_TILE_COUNT: int = MAP_TILES_X * MAP_TILES_Y


struct Map:
    tile_ids: array[ubyte, 375]
    tile_fog: array[ubyte, 375]


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [textures] example - fog of war")
    defer rl.close_window()

    var map: Map = zero[Map]
    var index = 0
    while index < MAP_TILE_COUNT:
        map.tile_ids[index] = ubyte<-rl.get_random_value(0, 1)
        index += 1

    var player_position = rl.Vector2(x = 180.0, y = 130.0)
    var player_tile_x = 0
    var player_tile_y = 0

    let fog_of_war = rl.load_render_texture(MAP_TILES_X, MAP_TILES_Y)
    defer rl.unload_render_texture(fog_of_war)
    rl.set_texture_filter(fog_of_war.texture, int<-rl.TextureFilter.TEXTURE_FILTER_BILINEAR)
    rl.set_texture_wrap(fog_of_war.texture, int<-rl.TextureWrap.TEXTURE_WRAP_CLAMP)

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
        else if player_position.x + float<-PLAYER_SIZE > float<-(MAP_TILES_X * MAP_TILE_SIZE):
            player_position.x = float<-(MAP_TILES_X * MAP_TILE_SIZE - PLAYER_SIZE)
        if player_position.y < 0.0:
            player_position.y = 0.0
        else if player_position.y + float<-PLAYER_SIZE > float<-(MAP_TILES_Y * MAP_TILE_SIZE):
            player_position.y = float<-(MAP_TILES_Y * MAP_TILE_SIZE - PLAYER_SIZE)

        index = 0
        while index < MAP_TILE_COUNT:
            if map.tile_fog[index] == 1:
                map.tile_fog[index] = 2
            index += 1

        player_tile_x = int<-((player_position.x + float<-MAP_TILE_SIZE / 2.0) / float<-MAP_TILE_SIZE)
        player_tile_y = int<-((player_position.y + float<-MAP_TILE_SIZE / 2.0) / float<-MAP_TILE_SIZE)

        var y = player_tile_y - PLAYER_TILE_VISIBILITY
        while y < player_tile_y + PLAYER_TILE_VISIBILITY:
            var x = player_tile_x - PLAYER_TILE_VISIBILITY
            while x < player_tile_x + PLAYER_TILE_VISIBILITY:
                if x >= 0 and x < MAP_TILES_X and y >= 0 and y < MAP_TILES_Y:
                    map.tile_fog[(y * MAP_TILES_X) + x] = 1
                x += 1
            y += 1

        rl.begin_texture_mode(fog_of_war)
        rl.clear_background(rl.BLANK)
        y = 0
        while y < MAP_TILES_Y:
            var x = 0
            while x < MAP_TILES_X:
                let fog_value = map.tile_fog[(y * MAP_TILES_X) + x]
                if fog_value == 0:
                    rl.draw_rectangle(x, y, 1, 1, rl.BLACK)
                else if fog_value == 2:
                    rl.draw_rectangle(x, y, 1, 1, rl.fade(rl.BLACK, 0.8))
                x += 1
            y += 1
        rl.end_texture_mode()

        let current_tile_text = rl.text_format("Current tile: [%i,%i]", player_tile_x, player_tile_y)

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        y = 0
        while y < MAP_TILES_Y:
            var x = 0
            while x < MAP_TILES_X:
                let tile_index = (y * MAP_TILES_X) + x
                let tile_color = if map.tile_ids[tile_index] == 0: rl.BLUE else: rl.fade(rl.BLUE, 0.9)
                rl.draw_rectangle(x * MAP_TILE_SIZE, y * MAP_TILE_SIZE, MAP_TILE_SIZE, MAP_TILE_SIZE, tile_color)
                rl.draw_rectangle_lines(x * MAP_TILE_SIZE, y * MAP_TILE_SIZE, MAP_TILE_SIZE, MAP_TILE_SIZE, rl.fade(rl.DARKBLUE, 0.5))
                x += 1
            y += 1

        rl.draw_rectangle_v(player_position, rl.Vector2(x = float<-PLAYER_SIZE, y = float<-PLAYER_SIZE), rl.RED)
        rl.draw_texture_pro(
            fog_of_war.texture,
            rl.Rectangle(x = 0.0, y = 0.0, width = float<-fog_of_war.texture.width, height = -float<-fog_of_war.texture.height),
            rl.Rectangle(x = 0.0, y = 0.0, width = float<-(MAP_TILES_X * MAP_TILE_SIZE), height = float<-(MAP_TILES_Y * MAP_TILE_SIZE)),
            rl.Vector2(x = 0.0, y = 0.0),
            0.0,
            rl.WHITE,
        )
        rl.draw_text(current_tile_text, 10, 10, 20, rl.RAYWHITE)
        rl.draw_text("ARROW KEYS to move", 10, SCREEN_HEIGHT - 25, 20, rl.RAYWHITE)

        rl.end_drawing()

    return 0
