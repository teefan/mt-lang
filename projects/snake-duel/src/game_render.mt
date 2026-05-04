module src.game_render

import std.raylib as rl
import src.game_types as gt


def cell_to_px(value: i32) -> i32:
    return value * gt.cell_size()


pub def draw_board(game: gt.Game):
    var y = 0
    while y < gt.grid_height():
        var x = 0
        while x < gt.grid_width():
            let tint = if (x + y) % 2 == 0: rl.Color(r = 18, g = 26, b = 34, a = 255) else: rl.Color(r = 14, g = 20, b = 28, a = 255)
            rl.draw_rectangle(cell_to_px(x), cell_to_px(y), gt.cell_size(), gt.cell_size(), tint)
            x += 1
        y += 1

    rl.draw_rectangle(cell_to_px(game.food.x) + 4, cell_to_px(game.food.y) + 4, gt.cell_size() - 8, gt.cell_size() - 8, rl.RED)

    var p = 0
    while p < game.player.length:
        rl.draw_rectangle(cell_to_px(game.player.body[p].x) + 1, cell_to_px(game.player.body[p].y) + 1, gt.cell_size() - 2, gt.cell_size() - 2, game.player.color)
        p += 1

    var e = 0
    while e < game.enemy.length:
        rl.draw_rectangle(cell_to_px(game.enemy.body[e].x) + 1, cell_to_px(game.enemy.body[e].y) + 1, gt.cell_size() - 2, gt.cell_size() - 2, game.enemy.color)
        e += 1


pub def draw_hud(game: gt.Game):
    rl.draw_rectangle(0, gt.grid_height() * gt.cell_size(), gt.screen_width(), gt.hud_height(), rl.Color(r = 10, g = 12, b = 16, a = 255))
    rl.draw_text(rl.text_format_i32_i32("P1 %d   AI %d", game.player.score, game.enemy.score), 16, (gt.grid_height() * gt.cell_size()) + 14, 28, rl.RAYWHITE)

    if game.state == gt.state_title():
        rl.draw_text("SNAKE DUEL", (gt.screen_width() / 2) - 120, (gt.screen_height() / 2) - 80, 44, rl.GOLD)
        rl.draw_text("Arrows or WASD to move", (gt.screen_width() / 2) - 150, (gt.screen_height() / 2) - 20, 24, rl.RAYWHITE)
        rl.draw_text("Press ENTER to start", (gt.screen_width() / 2) - 126, (gt.screen_height() / 2) + 14, 24, rl.LIME)

    if game.state == gt.state_game_over():
        if game.winner == gt.winner_player():
            rl.draw_text("PLAYER WINS", (gt.screen_width() / 2) - 162, (gt.screen_height() / 2) - 40, 48, rl.YELLOW)
        elif game.winner == gt.winner_enemy():
            rl.draw_text("AI WINS", (gt.screen_width() / 2) - 108, (gt.screen_height() / 2) - 40, 48, rl.YELLOW)
        else:
            rl.draw_text("DRAW", (gt.screen_width() / 2) - 70, (gt.screen_height() / 2) - 40, 48, rl.YELLOW)
        rl.draw_text("Press R to restart", (gt.screen_width() / 2) - 118, (gt.screen_height() / 2) + 18, 24, rl.RAYWHITE)
