module projects.snake_duel

import std.raylib as rl
import src.game_types as gt
import src.game_logic as game_logic
import src.game_render as game_render


def main() -> i32:
    rl.init_window(gt.screen_width(), gt.screen_height(), "Snake Duel")
    defer rl.close_window()

    rl.set_target_fps(120)

    var game = game_logic.reset_game()
    var accumulator: f32 = 0.0

    while not rl.window_should_close():
        if game.state == gt.state_title() and rl.is_key_pressed(rl.KeyboardKey.KEY_ENTER):
            game = game_logic.reset_game()
            game.state = gt.state_playing()

        if game.state == gt.state_game_over() and rl.is_key_pressed(rl.KeyboardKey.KEY_R):
            game = game_logic.reset_game()
            game.state = gt.state_playing()

        if game.state == gt.state_playing():
            game.player = game_logic.update_player_direction(game.player)
            accumulator += rl.get_frame_time()

            while accumulator >= gt.tick_seconds() and game.state == gt.state_playing():
                game = game_logic.step_game(game)
                accumulator -= gt.tick_seconds()

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.BLACK)
        game_render.draw_board(game)
        game_render.draw_hud(game)

    return 0
