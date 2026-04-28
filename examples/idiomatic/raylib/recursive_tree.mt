module examples.idiomatic.raylib.recursive_tree

import std.raygui as gui
import std.raylib as rl
import std.raylib.math as math

struct Branch:
    start: rl.Vector2
    finish: rl.Vector2
    angle: f32
    length: f32

const screen_width: i32 = 800
const screen_height: i32 = 450

def branch_limit(depth: i32) -> i32:
    var limit = 1
    for _ in range(0, depth):
        limit *= 2
    return limit

def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Recursive Tree")
    defer rl.close_window()

    let start_position = rl.Vector2(x = screen_width / 2.0 - 125.0, y = cast[f32](screen_height))
    var angle: f32 = 40.0
    var thick: f32 = 1.0
    var tree_depth: f32 = 10.0
    var branch_decay: f32 = 0.66
    var length: f32 = 120.0
    var bezier = false

    rl.set_target_fps(60)

    while not rl.window_should_close():
        let theta = angle * math.deg2rad
        let max_branches = branch_limit(cast[i32](math.floor(tree_depth)))
        var branches = zero[array[Branch, 1030]]()
        var count = 0

        let initial_end = rl.Vector2(
            x = start_position.x + length * math.sin(0.0),
            y = start_position.y - length * math.cos(0.0),
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
                        x = branch_start.x + next_length * math.sin(angle1),
                        y = branch_start.y - next_length * math.cos(angle1),
                    )
                    branches[count] = Branch(start = branch_start, finish = branch_end1, angle = angle1, length = next_length)
                    count += 1

                    let angle2 = branch.angle - theta
                    let branch_end2 = rl.Vector2(
                        x = branch_start.x + next_length * math.sin(angle2),
                        y = branch_start.y - next_length * math.cos(angle2),
                    )
                    branches[count] = Branch(start = branch_start, finish = branch_end2, angle = angle2, length = next_length)
                    count += 1
            index += 1

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)

        for draw_index in range(0, count):
            let branch = branches[draw_index]
            if branch.length >= 2.0:
                if bezier:
                    rl.draw_line_bezier(branch.start, branch.finish, thick, rl.RED)
                else:
                    rl.draw_line_ex(branch.start, branch.finish, thick, rl.RED)

        rl.draw_line(580, 0, 580, rl.get_screen_height(), rl.Color(r = 218, g = 218, b = 218, a = 255))
        rl.draw_rectangle(580, 0, rl.get_screen_width(), rl.get_screen_height(), rl.Color(r = 232, g = 232, b = 232, a = 255))

        gui.slider_bar(rl.Rectangle(x = 640.0, y = 40.0, width = 120.0, height = 20.0), "Angle", rl.text_format_f32("%.0f", angle), inout angle, 0.0, 180.0)
        gui.slider_bar(rl.Rectangle(x = 640.0, y = 70.0, width = 120.0, height = 20.0), "Length", rl.text_format_f32("%.0f", length), inout length, 12.0, 240.0)
        gui.slider_bar(rl.Rectangle(x = 640.0, y = 100.0, width = 120.0, height = 20.0), "Decay", rl.text_format_f32("%.2f", branch_decay), inout branch_decay, 0.1, 0.78)
        gui.slider_bar(rl.Rectangle(x = 640.0, y = 130.0, width = 120.0, height = 20.0), "Depth", rl.text_format_f32("%.0f", tree_depth), inout tree_depth, 1.0, 10.0)
        gui.slider_bar(rl.Rectangle(x = 640.0, y = 160.0, width = 120.0, height = 20.0), "Thick", rl.text_format_f32("%.0f", thick), inout thick, 1.0, 8.0)
        gui.check_box(rl.Rectangle(x = 640.0, y = 190.0, width = 20.0, height = 20.0), "Bezier", inout bezier)
        rl.draw_fps(10, 10)

    return 0
