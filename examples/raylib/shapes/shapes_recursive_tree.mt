module examples.raylib.shapes.shapes_recursive_tree

import std.c.libm as math
import std.c.raygui as gui
import std.c.raylib as rl
import std.raylib.math as mt_math

struct Branch:
    start: rl.Vector2
    finish: rl.Vector2
    angle: f32
    length: f32

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [shapes] example - recursive tree"


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let start_position = rl.Vector2(x = screen_width / 2.0 - 125.0, y = f32<-screen_height)
    var angle: f32 = 40.0
    var thick: f32 = 1.0
    var tree_depth: f32 = 10.0
    var branch_decay: f32 = 0.66
    var length: f32 = 120.0
    var bezier = false

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        let theta = angle * mt_math.deg2rad
        let max_branches = i32<-math.powf(2.0, math.floorf(tree_depth))
        var branches = zero[array[Branch, 1030]]
        var count = 0

        let initial_end = rl.Vector2(
            x = start_position.x + length * math.sinf(0.0),
            y = start_position.y - length * math.cosf(0.0),
        )
        branches[count] = Branch(start = start_position, finish = initial_end, angle = 0.0, length = length)
        count += 1

        var index = 0
        while index < count:
            let branch = branches[index]
            if branch.length >= 2.0:
                let next_length = branch.length * branch_decay
                if count < max_branches and next_length >= 2.0:
                    let branch_start = branch.finish

                    let angle1 = branch.angle + theta
                    let branch_end1 = rl.Vector2(
                        x = branch_start.x + next_length * math.sinf(angle1),
                        y = branch_start.y - next_length * math.cosf(angle1),
                    )
                    branches[count] = Branch(start = branch_start, finish = branch_end1, angle = angle1, length = next_length)
                    count += 1

                    let angle2 = branch.angle - theta
                    let branch_end2 = rl.Vector2(
                        x = branch_start.x + next_length * math.sinf(angle2),
                        y = branch_start.y - next_length * math.cosf(angle2),
                    )
                    branches[count] = Branch(start = branch_start, finish = branch_end2, angle = angle2, length = next_length)
                    count += 1
            index += 1

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        for draw_index in 0..count:
            let branch = branches[draw_index]
            if branch.length >= 2.0:
                if bezier:
                    rl.DrawLineBezier(branch.start, branch.finish, thick, rl.RED)
                else:
                    rl.DrawLineEx(branch.start, branch.finish, thick, rl.RED)

        rl.DrawLine(580, 0, 580, rl.GetScreenHeight(), rl.Color(r = 218, g = 218, b = 218, a = 255))
        rl.DrawRectangle(580, 0, rl.GetScreenWidth(), rl.GetScreenHeight(), rl.Color(r = 232, g = 232, b = 232, a = 255))

        gui.GuiSliderBar(gui.Rectangle(x = 640.0, y = 40.0, width = 120.0, height = 20.0), c"Angle", rl.TextFormat(c"%.0f", angle), ptr_of(angle), 0.0, 180.0)
        gui.GuiSliderBar(gui.Rectangle(x = 640.0, y = 70.0, width = 120.0, height = 20.0), c"Length", rl.TextFormat(c"%.0f", length), ptr_of(length), 12.0, 240.0)
        gui.GuiSliderBar(gui.Rectangle(x = 640.0, y = 100.0, width = 120.0, height = 20.0), c"Decay", rl.TextFormat(c"%.2f", branch_decay), ptr_of(branch_decay), 0.1, 0.78)
        gui.GuiSliderBar(gui.Rectangle(x = 640.0, y = 130.0, width = 120.0, height = 20.0), c"Depth", rl.TextFormat(c"%.0f", tree_depth), ptr_of(tree_depth), 1.0, 10.0)
        gui.GuiSliderBar(gui.Rectangle(x = 640.0, y = 160.0, width = 120.0, height = 20.0), c"Thick", rl.TextFormat(c"%.0f", thick), ptr_of(thick), 1.0, 8.0)
        gui.GuiCheckBox(gui.Rectangle(x = 640.0, y = 190.0, width = 20.0, height = 20.0), c"Bezier", ptr_of(bezier))

        rl.DrawFPS(10, 10)

    return 0
