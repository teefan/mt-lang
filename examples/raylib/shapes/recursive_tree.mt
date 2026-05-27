import std.math as math
import std.raygui as gui
import std.raylib as rl
import std.str as text


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const DEG_TO_RAD: float = rl.PI / 180.0
const MAX_BRANCH_CAPACITY: int = 1030


struct Branch:
    start: rl.Vector2
    end: rl.Vector2
    angle: float
    length: float


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shapes] example - recursive tree")
    defer rl.close_window()

    let start = rl.Vector2(x = float<-SCREEN_WIDTH / 2.0 - 125.0, y = float<-SCREEN_HEIGHT)
    var angle: float = 40.0
    var thick: float = 1.0
    var tree_depth: float = 10.0
    var branch_decay: float = 0.66
    var length: float = 120.0
    var bezier = false

    rl.set_target_fps(60)

    while not rl.window_should_close():
        let theta = angle * DEG_TO_RAD
        let max_branches = int<-math.pow(2.0, math.floor(double<-tree_depth))
        var branches: array[Branch, MAX_BRANCH_CAPACITY] = zero[array[Branch, MAX_BRANCH_CAPACITY]]
        var count = 0

        let initial_end = rl.Vector2(
            x = start.x + length * float<-math.sin(0.0),
            y = start.y - length * float<-math.cos(0.0),
        )
        branches[count] = Branch(start = start, end = initial_end, angle = 0.0, length = length)
        count += 1

        var index = 0
        while index < count:
            let branch = branches[index]
            if branch.length >= 2.0:
                let next_length = branch.length * branch_decay

                if count < max_branches and next_length >= 2.0:
                    let branch_start = branch.end

                    let angle1 = branch.angle + theta
                    let branch_end1 = rl.Vector2(
                        x = branch_start.x + next_length * float<-math.sin(double<-angle1),
                        y = branch_start.y - next_length * float<-math.cos(double<-angle1),
                    )
                    branches[count] = Branch(start = branch_start, end = branch_end1, angle = angle1, length = next_length)
                    count += 1

                    let angle2 = branch.angle - theta
                    let branch_end2 = rl.Vector2(
                        x = branch_start.x + next_length * float<-math.sin(double<-angle2),
                        y = branch_start.y - next_length * float<-math.cos(double<-angle2),
                    )
                    branches[count] = Branch(start = branch_start, end = branch_end2, angle = angle2, length = next_length)
                    count += 1
            index += 1

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        index = 0
        while index < count:
            let branch = branches[index]
            if branch.length >= 2.0:
                if bezier:
                    rl.draw_line_bezier(branch.start, branch.end, thick, rl.RED)
                else:
                    rl.draw_line_ex(branch.start, branch.end, thick, rl.RED)
            index += 1

        rl.draw_line(580, 0, 580, rl.get_screen_height(), rl.Color(r = ubyte<-218, g = ubyte<-218, b = ubyte<-218, a = ubyte<-255))
        rl.draw_rectangle(580, 0, rl.get_screen_width(), rl.get_screen_height(), rl.Color(r = ubyte<-232, g = ubyte<-232, b = ubyte<-232, a = ubyte<-255))

        gui.slider_bar(rl.Rectangle(x = 640.0, y = 40.0, width = 120.0, height = 20.0), "Angle", text.cstr_as_str(rl.text_format("%.0f", angle)), angle, 0.0, 180.0)
        gui.slider_bar(rl.Rectangle(x = 640.0, y = 70.0, width = 120.0, height = 20.0), "Length", text.cstr_as_str(rl.text_format("%.0f", length)), length, 12.0, 240.0)
        gui.slider_bar(rl.Rectangle(x = 640.0, y = 100.0, width = 120.0, height = 20.0), "Decay", text.cstr_as_str(rl.text_format("%.2f", branch_decay)), branch_decay, 0.1, 0.78)
        gui.slider_bar(rl.Rectangle(x = 640.0, y = 130.0, width = 120.0, height = 20.0), "Depth", text.cstr_as_str(rl.text_format("%.0f", tree_depth)), tree_depth, 1.0, 10.0)
        gui.slider_bar(rl.Rectangle(x = 640.0, y = 160.0, width = 120.0, height = 20.0), "Thick", text.cstr_as_str(rl.text_format("%.0f", thick)), thick, 1.0, 8.0)
        gui.check_box(rl.Rectangle(x = 640.0, y = 190.0, width = 20.0, height = 20.0), "Bezier", bezier)

        rl.draw_fps(10, 10)
        rl.end_drawing()

    return 0
