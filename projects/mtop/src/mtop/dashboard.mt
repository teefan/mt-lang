import std.fmt as fmt
import std.process as process
import std.str as text
import std.string as string
import std.terminal as terminal
import std.vec as vec


public struct Config:
    interval_ms: int
    mouse_enabled: bool


struct Snapshot:
    collected_at: string.String
    kernel: string.String
    uptime: string.String
    process_table: string.String
    refresh_count: int


struct EchoSession:
    active: bool
    child: process.ChildProcess
    transcript: string.String
    input: vec.Vec[ubyte]
    status: string.String


enum DashboardTab: int
    overview = 0
    processes = 1
    echo = 2


struct Rect:
    left: int
    top: int
    width: int
    height: int


const ascii_plus: ubyte = ubyte<-43
const ascii_dash: ubyte = ubyte<-45
const ascii_pipe: ubyte = ubyte<-124
const dashboard_body_top: int = 6
const dashboard_footer_rows: int = 2
const dashboard_gap: int = 1


function invalid_child_process() -> process.ChildProcess:
    return process.ChildProcess(pid = 0, stdin_fd = -1, stdout_fd = -1, stderr_fd = -1)


function write_stdout_text(value: str) -> int:
    match terminal.write_stdout(value):
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            return 1
        Result.success:
            return 0


function write_stderr_text(value: str) -> int:
    match terminal.write_stderr(value):
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            return 1
        Result.success:
            return 0


function terminal_bool_ok(result: Result[bool, terminal.Error]) -> bool:
    match result:
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            return false
        Result.success:
            return true


function terminal_write_ok(app_terminal: ref[terminal.Terminal], value: str) -> bool:
    match app_terminal.write(value):
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            return false
        Result.success:
            return true


function trim_output(value: str) -> str:
    return value.trim_ascii_whitespace()


function capture_shell_output(script: str) -> string.String:
    var command = vec.Vec[str].create()
    defer command.release()
    command.push("/bin/sh")
    command.push("-c")
    command.push(script)

    match process.capture(command.as_span()):
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            var message = string.String.from_str("<capture failed: ")
            message.append(error.message.as_str())
            message.append(">")
            return message
        Result.success as payload:
            var result = payload.value
            defer result.release()

            if result.status.success():
                match result.stdout_text():
                    Option.some as stdout_payload:
                        return string.String.from_str(trim_output(stdout_payload.value))
                    Option.none:
                        return string.String.from_str("<non-utf8 stdout>")

            match result.stderr_text():
                Option.some as stderr_payload:
                    var message = string.String.from_str("<command failed: ")
                    message.append(trim_output(stderr_payload.value))
                    message.append(">")
                    return message
                Option.none:
                    return string.String.from_str("<command failed>")


function collect_snapshot(refresh_count: int) -> Snapshot:
    return Snapshot(
        collected_at = capture_shell_output("date '+%Y-%m-%d %H:%M:%S'"),
        kernel = capture_shell_output("uname -sr"),
        uptime = capture_shell_output("uptime"),
        process_table = capture_shell_output("ps -eo pid,comm,%cpu,%mem --sort=-%cpu | head -n 6"),
        refresh_count = refresh_count,
    )


function append_label_line(output: ref[string.String], label: str, value: str) -> void:
    output.append("  ")
    output.append(label)
    output.append(": ")
    output.append(value)
    output.append("\n")


function set_status_message(target: ref[string.String], prefix: str, detail: str) -> void:
    var message = string.String.from_str(prefix)
    message.append(detail)
    read(target).assign(message.as_str())
    message.release()


function append_transcript(target: ref[string.String], value: str) -> void:
    if read(target).len > 4096:
        read(target).clear()
        read(target).append("[transcript reset]\n")

    read(target).append(value)


function byte_buffer_as_str(buffer: vec.Vec[ubyte]) -> Option[str]:
    return text.utf8_byte_span_as_str(buffer.as_span())


function key_name(code: terminal.KeyCode) -> str:
    if code == terminal.KeyCode.enter:
        return "Enter"
    if code == terminal.KeyCode.escape:
        return "Escape"
    if code == terminal.KeyCode.backspace:
        return "Backspace"
    if code == terminal.KeyCode.tab:
        return "Tab"
    if code == terminal.KeyCode.up:
        return "Up"
    if code == terminal.KeyCode.down:
        return "Down"
    if code == terminal.KeyCode.left:
        return "Left"
    if code == terminal.KeyCode.right:
        return "Right"
    if code == terminal.KeyCode.home:
        return "Home"
    if code == terminal.KeyCode.end:
        return "End"
    if code == terminal.KeyCode.page_up:
        return "PageUp"
    if code == terminal.KeyCode.page_down:
        return "PageDown"
    if code == terminal.KeyCode.insert:
        return "Insert"
    if code == terminal.KeyCode.delete:
        return "Delete"
    if code == terminal.KeyCode.function_1:
        return "F1"
    if code == terminal.KeyCode.function_2:
        return "F2"
    if code == terminal.KeyCode.function_3:
        return "F3"
    if code == terminal.KeyCode.function_4:
        return "F4"
    return "Unknown"


function describe_key_event(key: terminal.KeyEvent) -> string.String:
    var message = string.String.create()
    if key.ctrl:
        message.append("Ctrl+")
    if key.alt:
        message.append("Alt+")
    if key.shifted:
        message.append("Shift+")

    if key.code == terminal.KeyCode.character and key.has_byte and key.input_byte >= 32 and key.input_byte < 127:
        message.push_byte(key.input_byte)
        return message

    message.append(key_name(key.code))
    return message


function describe_mouse_event(mouse: terminal.MouseEvent) -> string.String:
    var message = string.String.from_str("mouse ")
    if mouse.action == terminal.MouseAction.press:
        message.append("press")
    else if mouse.action == terminal.MouseAction.release:
        message.append("release")
    else if mouse.action == terminal.MouseAction.move:
        message.append("move")
    else if mouse.action == terminal.MouseAction.scroll_up:
        message.append("scroll-up")
    else if mouse.action == terminal.MouseAction.scroll_down:
        message.append("scroll-down")
    else:
        message.append("none")

    message.append(" @ ")
    fmt.append_int(ref_of(message), mouse.column)
    message.append(",")
    fmt.append_int(ref_of(message), mouse.row)
    return message


function make_rect(left: int, top: int, width: int, height: int) -> Rect:
    return Rect(left = left, top = top, width = width, height = height)


function max_int(left: int, right: int) -> int:
    if left > right:
        return left

    return right


function min_int(left: int, right: int) -> int:
    if left < right:
        return left

    return right


function append_repeated_byte(output: ref[string.String], value: ubyte, repeat_count: int) -> void:
    if repeat_count <= 0:
        return

    var index = 0
    while index < repeat_count:
        output.push_byte(value)
        index += 1


function append_panel_line(output: ref[string.String], label: str, value: str) -> void:
    output.append(label)
    output.append(": ")
    output.append(value)
    output.append("\n")


function append_panel_int(output: ref[string.String], label: str, value: int) -> void:
    output.append(label)
    output.append(": ")
    fmt.append_int(output, value)
    output.append("\n")


function tab_name(tab: DashboardTab) -> str:
    if tab == DashboardTab.overview:
        return "Overview"
    if tab == DashboardTab.processes:
        return "Processes"
    return "Echo"


function next_tab(tab: DashboardTab) -> DashboardTab:
    if tab == DashboardTab.overview:
        return DashboardTab.processes
    if tab == DashboardTab.processes:
        return DashboardTab.echo
    return DashboardTab.overview


function previous_tab(tab: DashboardTab) -> DashboardTab:
    if tab == DashboardTab.overview:
        return DashboardTab.echo
    if tab == DashboardTab.echo:
        return DashboardTab.processes
    return DashboardTab.overview


function updates_label(paused: bool) -> str:
    if paused:
        return "paused"

    return "live"


function mouse_label(enabled: bool) -> str:
    if enabled:
        return "enabled"

    return "disabled"


function child_label(echo: EchoSession) -> str:
    if echo.active:
        return "connected"

    return "offline"


function panel_frame_color(base: terminal.Color, focused: bool) -> terminal.Color:
    if focused:
        return terminal.Color.bright_white

    return base


function text_line_count(value: str) -> int:
    if value.len == 0:
        return 0

    var count = 1
    var index: ptr_uint = 0
    while index < value.len:
        if value.byte_at(index) == 10:
            count += 1
        index += 1

    return count


function line_at(value: str, line_index: int) -> Option[str]:
    if line_index < 0 or value.len == 0:
        return Option[str].none

    var current_line = 0
    var start: ptr_uint = 0
    while true:
        var stop = start
        while stop < value.len and value.byte_at(stop) != 10:
            stop += 1

        if current_line == line_index:
            return Option[str].some(value= value.slice(start, stop - start))

        if stop == value.len:
            return Option[str].none

        current_line += 1
        start = stop + 1


function process_entry_count(process_table: str) -> int:
    let total_line_count = text_line_count(process_table)
    if total_line_count <= 1:
        return 0

    return total_line_count - 1


function clamp_process_selection(process_table: str, selected_index: int) -> int:
    let entry_count = process_entry_count(process_table)
    if entry_count <= 0:
        return 0

    return min_int(max_int(selected_index, 0), entry_count - 1)


function selected_process_line(process_table: str, selected_index: int) -> Option[str]:
    if process_entry_count(process_table) == 0:
        return Option[str].none

    return line_at(process_table, clamp_process_selection(process_table, selected_index) + 1)


function dashboard_body_height(size: terminal.Size) -> int:
    return size.height - dashboard_body_top - dashboard_footer_rows + 1


function rect_contains(rect: Rect, column: int, row: int) -> bool:
    if column < rect.left or row < rect.top:
        return false

    if column >= rect.left + rect.width or row >= rect.top + rect.height:
        return false

    return true


function overview_process_panel(size: terminal.Size) -> Rect:
    let body_height = dashboard_body_height(size)
    let top_height = 9
    let bottom_height = body_height - top_height - dashboard_gap
    return make_rect(1, dashboard_body_top + top_height + dashboard_gap, size.width, bottom_height)


function processes_main_panel(size: terminal.Size) -> Rect:
    let side_width = 26
    let main_width = size.width - side_width - dashboard_gap
    return make_rect(1, dashboard_body_top, main_width, dashboard_body_height(size))


function tab_hit_test(column: int, row: int) -> Option[DashboardTab]:
    if row != 2:
        return Option[DashboardTab].none

    var start = 1
    if column >= start and column < start + 10:
        return Option[DashboardTab].some(value= DashboardTab.overview)

    start += 11
    if column >= start and column < start + 11:
        return Option[DashboardTab].some(value= DashboardTab.processes)

    start += 12
    if column >= start and column < start + 6:
        return Option[DashboardTab].some(value= DashboardTab.echo)

    return Option[DashboardTab].none


function process_selection_from_mouse(panel: Rect, process_table: str, column: int, row: int) -> Option[int]:
    let inner = panel_inner_rect(panel)
    if not rect_contains(inner, column, row):
        return Option[int].none

    let selected_index = row - inner.top - 1
    if selected_index < 0 or selected_index >= process_entry_count(process_table):
        return Option[int].none

    return Option[int].some(value= selected_index)


function visible_width(width: int) -> ptr_uint:
    if width <= 0:
        return 0

    return ptr_uint<-width


function clipped_line_text(value: str, width: int) -> str:
    let max_width = visible_width(width)
    if value.len <= max_width:
        return value

    if max_width == 0:
        return value.slice(0, 0)

    var end = max_width
    while end > 0 and end < value.len and text.utf8_continuation_byte(value.byte_at(end)):
        end -= 1

    return value.slice(0, end)


function render_plain_line_at(app_terminal: ref[terminal.Terminal], column: int, row: int, width: int, value: str) -> bool:
    if column <= 0 or row <= 0 or width <= 0:
        return true

    if not terminal_bool_ok(terminal.move_cursor(row, column)):
        return false

    return terminal_write_ok(app_terminal, clipped_line_text(value, width))


function render_plain_line(app_terminal: ref[terminal.Terminal], size: terminal.Size, row: int, value: str) -> bool:
    if row <= 0 or row > size.height:
        return true

    return render_plain_line_at(app_terminal, 1, row, size.width, value)


function render_heading_line_at(app_terminal: ref[terminal.Terminal], column: int, row: int, width: int, color: terminal.Color, value: str) -> bool:
    if column <= 0 or row <= 0 or width <= 0:
        return true

    if not terminal_bool_ok(terminal.move_cursor(row, column)):
        return false
    if not terminal_bool_ok(terminal.set_bold(true)):
        return false
    if not terminal_bool_ok(terminal.set_foreground(color)):
        return false
    if not terminal_write_ok(app_terminal, clipped_line_text(value, width)):
        return false
    return terminal_bool_ok(terminal.reset_style())


function render_heading_line(app_terminal: ref[terminal.Terminal], size: terminal.Size, row: int, color: terminal.Color, value: str) -> bool:
    if row <= 0 or row > size.height:
        return true

    return render_heading_line_at(app_terminal, 1, row, size.width, color, value)


function render_text_block_at(app_terminal: ref[terminal.Terminal], column: int, start_row: int, width: int, max_rows: int, value: str) -> bool:
    if width <= 0 or max_rows <= 0:
        return true

    var row_index = 0
    var start: ptr_uint = 0
    var keep_rendering = true
    while keep_rendering and row_index < max_rows:
        var stop = start
        while stop < value.len and value.byte_at(stop) != 10:
            stop += 1

        let line = value.slice(start, stop - start)
        if not render_plain_line_at(app_terminal, column, start_row + row_index, width, line):
            return false

        row_index += 1
        if stop == value.len:
            keep_rendering = false
        else:
            start = stop + 1

    return true


function render_text_block(app_terminal: ref[terminal.Terminal], size: terminal.Size, start_row: int, value: str) -> int:
    if start_row > size.height:
        return start_row

    var row = start_row
    var start: ptr_uint = 0
    var keep_rendering = true
    while keep_rendering:
        var stop = start
        while stop < value.len and value.byte_at(stop) != 10:
            stop += 1

        let line = value.slice(start, stop - start)
        if not render_plain_line(app_terminal, size, row, line):
            return -1

        row += 1
        if stop == value.len or row > size.height:
            keep_rendering = false
        else:
            start = stop + 1

    return row


function render_heading_block(app_terminal: ref[terminal.Terminal], size: terminal.Size, start_row: int, color: terminal.Color, value: str) -> int:
    if not render_heading_line(app_terminal, size, start_row, color, value):
        return -1

    return start_row + 1


function panel_inner_rect(panel: Rect) -> Rect:
    return Rect(
        left = panel.left + 2,
        top = panel.top + 2,
        width = max_int(panel.width - 4, 0),
        height = max_int(panel.height - 3, 0),
    )


function render_panel_frame(app_terminal: ref[terminal.Terminal], panel: Rect, color: terminal.Color, title: str) -> bool:
    if panel.width < 4 or panel.height < 4:
        return true

    var border = string.String.create()
    defer border.release()
    border.push_byte(ascii_plus)
    append_repeated_byte(ref_of(border), ascii_dash, panel.width - 2)
    border.push_byte(ascii_plus)

    if not render_heading_line_at(app_terminal, panel.left, panel.top, panel.width, color, border.as_str()):
        return false
    if not render_heading_line_at(app_terminal, panel.left, panel.top + panel.height - 1, panel.width, color, border.as_str()):
        return false

    var row = panel.top + 1
    while row < panel.top + panel.height - 1:
        if not render_heading_line_at(app_terminal, panel.left, row, 1, color, "|"):
            return false
        if not render_heading_line_at(app_terminal, panel.left + panel.width - 1, row, 1, color, "|"):
            return false
        row += 1

    return render_heading_line_at(app_terminal, panel.left + 2, panel.top + 1, panel.width - 4, color, title)


function render_panel(app_terminal: ref[terminal.Terminal], panel: Rect, color: terminal.Color, title: str, body: str, focused: bool) -> bool:
    if not render_panel_frame(app_terminal, panel, panel_frame_color(color, focused), title):
        return false

    let inner = panel_inner_rect(panel)
    return render_text_block_at(app_terminal, inner.left, inner.top, inner.width, inner.height, body)


function render_process_table_panel(app_terminal: ref[terminal.Terminal], panel: Rect, color: terminal.Color, title: str, process_table: str, selected_index: int, focused: bool) -> bool:
    let frame_color = panel_frame_color(color, focused)
    if not render_panel_frame(app_terminal, panel, frame_color, title):
        return false

    let inner = panel_inner_rect(panel)
    match line_at(process_table, 0):
        Option.some as header_payload:
            if not render_heading_line_at(app_terminal, inner.left, inner.top, inner.width, color, header_payload.value):
                return false
        Option.none:
            return true

    let clamped_selection = clamp_process_selection(process_table, selected_index)
    var visual_row = 1
    while visual_row < inner.height:
        let line_payload = line_at(process_table, visual_row) else:
            return true

        var rendered_line = string.String.from_str("  ")
        let is_selected = visual_row - 1 == clamped_selection
        if is_selected:
            rendered_line.assign("> ")
        rendered_line.append(line_payload)

        var ok = true
        if is_selected:
            ok = render_heading_line_at(app_terminal, inner.left, inner.top + visual_row, inner.width, frame_color, rendered_line.as_str())
        else:
            ok = render_plain_line_at(app_terminal, inner.left, inner.top + visual_row, inner.width, rendered_line.as_str())

        rendered_line.release()
        if not ok:
            return false

        visual_row += 1

    return true


function render_footer(app_terminal: ref[terminal.Terminal], size: terminal.Size, active_tab: DashboardTab, config: Config, echo: EchoSession, process_table: str, selected_index: int, last_event: str) -> bool:
    var hint_line = string.String.create()
    defer hint_line.release()
    if active_tab == DashboardTab.overview:
        hint_line.append("  Mouse tabs are active. Click a preview row to jump into the process view.")
    else if active_tab == DashboardTab.processes:
        hint_line.append("  Up/Down moves selection. Mouse click selects a process row. Tab switches views.")
    else:
        hint_line.append("  Type into the input panel. Backspace edits, Enter submits, Ctrl+N restarts the child.")

    if not render_plain_line(app_terminal, size, size.height - 1, hint_line.as_str()):
        return false

    var status_line = string.String.create()
    defer status_line.release()
    status_line.append("  Mouse: ")
    status_line.append(mouse_label(config.mouse_enabled))
    status_line.append("  Child: ")
    status_line.append(child_label(echo))
    status_line.append("  Selected: ")
    let process_count = process_entry_count(process_table)
    if process_count == 0:
        status_line.append("none")
    else:
        fmt.append_int(ref_of(status_line), clamp_process_selection(process_table, selected_index) + 1)
        status_line.append("/")
        fmt.append_int(ref_of(status_line), process_count)
    status_line.append("  Last: ")
    status_line.append(last_event)

    return render_plain_line(app_terminal, size, size.height, status_line.as_str())


function render_tab_button(app_terminal: ref[terminal.Terminal], column: int, row: int, label: str, active: bool) -> int:
    let label_width = int<-label.len
    if active:
        if not render_heading_line_at(app_terminal, column, row, label_width, terminal.Color.bright_cyan, label):
            return -1
    else:
        if not render_plain_line_at(app_terminal, column, row, label_width, label):
            return -1

    return column + label_width + 1


function render_tab_bar(app_terminal: ref[terminal.Terminal], active_tab: DashboardTab) -> bool:
    var column = 1
    column = render_tab_button(app_terminal, column, 2, "[Overview]", active_tab == DashboardTab.overview)
    if column < 0:
        return false
    column = render_tab_button(app_terminal, column, 2, "[Processes]", active_tab == DashboardTab.processes)
    if column < 0:
        return false
    column = render_tab_button(app_terminal, column, 2, "[Echo]", active_tab == DashboardTab.echo)
    return column >= 0


function render_small_dashboard(app_terminal: ref[terminal.Terminal], size: terminal.Size, snapshot: Snapshot, echo: EchoSession, active_tab: DashboardTab, config: Config, selected_process_index: int, paused: bool, last_event: str) -> bool:
    if not render_heading_line(app_terminal, size, 1, terminal.Color.bright_cyan, "MTOP  Milk Tea CLI/TUI Demo"):
        return false
    if not render_tab_bar(app_terminal, active_tab):
        return false
    if not render_plain_line(app_terminal, size, 4, "Resize terminal to at least 72x24 for panel layout."):
        return false

    var status_line = string.String.create()
    defer status_line.release()
    status_line.append("  Updates: ")
    status_line.append(updates_label(paused))
    status_line.append("  Refresh: ")
    fmt.append_int(ref_of(status_line), snapshot.refresh_count)
    status_line.append("  Last: ")
    status_line.append(last_event)
    if not render_plain_line(app_terminal, size, 5, status_line.as_str()):
        return false

    let next_row = render_heading_block(app_terminal, size, 7, terminal.Color.bright_yellow, "Top Processes")
    if next_row < 0:
        return false
    if render_text_block(app_terminal, size, next_row, snapshot.process_table.as_str()) < 0:
        return false

    if not render_footer(app_terminal, size, active_tab, config, echo, snapshot.process_table.as_str(), selected_process_index, last_event):
        return false

    return terminal_bool_ok(app_terminal.flush())


function render_dashboard(app_terminal: ref[terminal.Terminal], size: terminal.Size, snapshot: Snapshot, echo: EchoSession, config: Config, active_tab: DashboardTab, selected_process_index: int, paused: bool, last_event: str) -> bool:
    if not terminal_bool_ok(terminal.clear_screen()):
        return false

    let process_table = snapshot.process_table.as_str()
    if size.width < 72 or size.height < 24:
        return render_small_dashboard(app_terminal, size, snapshot, echo, active_tab, config, selected_process_index, paused, last_event)

    if not render_heading_line(app_terminal, size, 1, terminal.Color.bright_cyan, "MTOP  Milk Tea CLI/TUI Demo"):
        return false
    if not render_tab_bar(app_terminal, active_tab):
        return false
    if not render_plain_line(app_terminal, size, 3, "  Tab/Left/Right switch view  Ctrl+R refresh  Ctrl+P pause  Esc quit"):
        return false

    var status_line = string.String.create()
    defer status_line.release()
    status_line.append("  View: ")
    status_line.append(tab_name(active_tab))
    status_line.append("  Screen: ")
    fmt.append_int(ref_of(status_line), size.width)
    status_line.append("x")
    fmt.append_int(ref_of(status_line), size.height)
    status_line.append("  Refresh: ")
    fmt.append_int(ref_of(status_line), snapshot.refresh_count)
    status_line.append("  Updates: ")
    status_line.append(updates_label(paused))
    if not render_plain_line(app_terminal, size, 4, status_line.as_str()):
        return false

    let body_top = dashboard_body_top
    let body_height = dashboard_body_height(size)
    let gap = dashboard_gap

    if active_tab == DashboardTab.overview:
        let left_width = (size.width - gap) / 2
        let right_width = size.width - left_width - gap
        let top_height = 9
        let bottom_height = body_height - top_height - gap

        let system_panel = make_rect(1, body_top, left_width, top_height)
        let session_panel = make_rect(left_width + gap + 1, body_top, right_width, top_height)
        let process_panel = make_rect(1, body_top + top_height + gap, size.width, bottom_height)

        var system_body = string.String.create()
        defer system_body.release()
        append_panel_line(ref_of(system_body), "Collected", snapshot.collected_at.as_str())
        append_panel_line(ref_of(system_body), "Kernel", snapshot.kernel.as_str())
        append_panel_line(ref_of(system_body), "Uptime", snapshot.uptime.as_str())

        var session_body = string.String.create()
        defer session_body.release()
        append_panel_line(ref_of(session_body), "View", tab_name(active_tab))
        append_panel_line(ref_of(session_body), "Updates", updates_label(paused))
        append_panel_line(ref_of(session_body), "Mouse", mouse_label(config.mouse_enabled))
        append_panel_int(ref_of(session_body), "Refresh", snapshot.refresh_count)
        append_panel_line(ref_of(session_body), "Child", child_label(echo))
        let process_count = process_entry_count(process_table)
        if process_count == 0:
            append_panel_line(ref_of(session_body), "Selected", "none")
        else:
            var selected_label = string.String.create()
            defer selected_label.release()
            fmt.append_int(ref_of(selected_label), clamp_process_selection(process_table, selected_process_index) + 1)
            selected_label.append("/")
            fmt.append_int(ref_of(selected_label), process_count)
            append_panel_line(ref_of(session_body), "Selected", selected_label.as_str())
        append_panel_line(ref_of(session_body), "Last event", last_event)

        if not render_panel(app_terminal, system_panel, terminal.Color.bright_green, "System Snapshot", system_body.as_str(), false):
            return false
        if not render_panel(app_terminal, session_panel, terminal.Color.bright_blue, "Session", session_body.as_str(), true):
            return false
        if not render_process_table_panel(app_terminal, process_panel, terminal.Color.bright_yellow, "Top Processes Preview", process_table, selected_process_index, false):
            return false
    else if active_tab == DashboardTab.processes:
        let side_width = 26
        let main_width = size.width - side_width - gap
        let inspector_height = 10
        let activity_height = body_height - inspector_height - gap

        let process_panel = make_rect(1, body_top, main_width, body_height)
        let inspector_panel = make_rect(main_width + gap + 1, body_top, side_width, inspector_height)
        let activity_panel = make_rect(main_width + gap + 1, body_top + inspector_height + gap, side_width, activity_height)

        var inspector_body = string.String.create()
        defer inspector_body.release()
        append_panel_line(ref_of(inspector_body), "View", tab_name(active_tab))
        append_panel_line(ref_of(inspector_body), "Collected", snapshot.collected_at.as_str())
        append_panel_int(ref_of(inspector_body), "Refresh", snapshot.refresh_count)
        append_panel_line(ref_of(inspector_body), "Updates", updates_label(paused))
        append_panel_line(ref_of(inspector_body), "Mouse", mouse_label(config.mouse_enabled))
        let process_count = process_entry_count(process_table)
        if process_count == 0:
            append_panel_line(ref_of(inspector_body), "Selected", "none")
        else:
            var selected_label = string.String.create()
            defer selected_label.release()
            fmt.append_int(ref_of(selected_label), clamp_process_selection(process_table, selected_process_index) + 1)
            selected_label.append("/")
            fmt.append_int(ref_of(selected_label), process_count)
            append_panel_line(ref_of(inspector_body), "Selected", selected_label.as_str())
            match selected_process_line(process_table, selected_process_index):
                Option.some as selected_payload:
                    append_panel_line(ref_of(inspector_body), "Entry", selected_payload.value)
                Option.none:
                    append_panel_line(ref_of(inspector_body), "Entry", "unavailable")

        var activity_body = string.String.create()
        defer activity_body.release()
        append_panel_line(ref_of(activity_body), "Last event", last_event)
        append_panel_line(ref_of(activity_body), "Child", child_label(echo))
        append_panel_line(ref_of(activity_body), "Select", "Up/Down or mouse")
        append_panel_line(ref_of(activity_body), "Views", "Tab/Left/Right")
        append_panel_line(ref_of(activity_body), "Refresh", "Ctrl+R")
        append_panel_line(ref_of(activity_body), "Pause", "Ctrl+P")

        if not render_process_table_panel(app_terminal, process_panel, terminal.Color.bright_yellow, "Top Processes", process_table, selected_process_index, true):
            return false
        if not render_panel(app_terminal, inspector_panel, terminal.Color.bright_green, "Inspector", inspector_body.as_str(), false):
            return false
        if not render_panel(app_terminal, activity_panel, terminal.Color.bright_magenta, "Activity", activity_body.as_str(), false):
            return false
    else:
        let top_height = 8
        let bottom_height = body_height - top_height - gap
        let side_width = 26
        let transcript_width = size.width - side_width - gap

        let pipe_panel = make_rect(1, body_top, size.width, top_height)
        let transcript_panel = make_rect(1, body_top + top_height + gap, transcript_width, bottom_height)
        let help_panel = make_rect(transcript_width + gap + 1, body_top + top_height + gap, side_width, bottom_height)

        var pipe_body = string.String.create()
        defer pipe_body.release()
        append_panel_line(ref_of(pipe_body), "Child", child_label(echo))
        append_panel_line(ref_of(pipe_body), "Status", echo.status.as_str())
        match byte_buffer_as_str(echo.input):
            Option.some as input_payload:
                append_panel_line(ref_of(pipe_body), "Input", input_payload.value)
            Option.none:
                append_panel_line(ref_of(pipe_body), "Input", "<invalid utf-8>")

        var help_body = string.String.create()
        defer help_body.release()
        append_panel_line(ref_of(help_body), "Submit", "Enter")
        append_panel_line(ref_of(help_body), "Edit", "Backspace")
        append_panel_line(ref_of(help_body), "Restart", "Ctrl+N")
        append_panel_line(ref_of(help_body), "Views", "Tab / Shift+Tab")
        append_panel_line(ref_of(help_body), "Last event", last_event)

        if not render_panel(app_terminal, pipe_panel, terminal.Color.bright_magenta, "Interactive Pipe", pipe_body.as_str(), true):
            return false
        if not render_panel(app_terminal, transcript_panel, terminal.Color.bright_yellow, "Transcript", echo.transcript.as_str(), false):
            return false
        if not render_panel(app_terminal, help_panel, terminal.Color.bright_blue, "Help", help_body.as_str(), false):
            return false

    if not render_footer(app_terminal, size, active_tab, config, echo, process_table, selected_process_index, last_event):
        return false

    return terminal_bool_ok(app_terminal.flush())


function render_snapshot_text(snapshot: Snapshot) -> string.String:
    var output = string.String.create()
    output.append("MTOP snapshot\n\n")
    append_label_line(ref_of(output), "Collected", snapshot.collected_at.as_str())
    append_label_line(ref_of(output), "Kernel", snapshot.kernel.as_str())
    append_label_line(ref_of(output), "Uptime", snapshot.uptime.as_str())
    output.append("\nTop Processes\n")
    output.append(snapshot.process_table.as_str())
    output.append("\n")
    return output


extending Snapshot:
    mutable function release() -> void:
        this.collected_at.release()
        this.kernel.release()
        this.uptime.release()
        this.process_table.release()


extending EchoSession:
    static function create() -> EchoSession:
        var session = EchoSession(
            active = false,
            child = invalid_child_process(),
            transcript = string.String.create(),
            input = vec.Vec[ubyte].create(),
            status = string.String.from_str("spawning /bin/cat"),
        )
        session.restart()
        return session


    mutable function restart() -> void:
        this.shutdown()

        var command = vec.Vec[str].create()
        defer command.release()
        command.push("/bin/cat")

        match process.spawn(command.as_span()):
            Result.failure as payload:
                var error = payload.error
                defer error.release()
                this.active = false
                set_status_message(ref_of(this.status), "spawn failed: ", error.message.as_str())
            Result.success as payload:
                this.child = payload.value
                this.active = true
                this.status.assign("connected to /bin/cat")
                append_transcript(ref_of(this.transcript), "[child connected]\n")


    mutable function shutdown() -> void:
        if this.child.stdin_fd >= 0:
            match this.child.close_stdin():
                Result.failure as payload:
                    var error = payload.error
                    error.release()
                Result.success:
                    pass

        if this.child.pid > 0:
            match this.child.try_wait():
                Result.failure as payload:
                    var error = payload.error
                    error.release()
                Result.success as payload:
                    match payload.value:
                        Option.some:
                            pass
                        Option.none:
                            match this.child.kill(15):
                                Result.failure as kill_payload:
                                    var error = kill_payload.error
                                    error.release()
                                Result.success:
                                    pass
                            match this.child.wait():
                                Result.failure as wait_payload:
                                    var error = wait_payload.error
                                    error.release()
                                Result.success:
                                    pass

        this.child.release()
        this.child = invalid_child_process()
        this.active = false


    mutable function pump() -> void:
        if not this.active:
            return

        var attempts = 0
        while attempts < 4:
            match this.child.read_stdout(0):
                Result.failure as payload:
                    var error = payload.error
                    defer error.release()
                    this.active = false
                    set_status_message(ref_of(this.status), "read failed: ", error.message.as_str())
                    break
                Result.success as payload:
                    var chunk = payload.value
                    defer chunk.release()

                    if chunk.has_data():
                        match chunk.text():
                            Option.some as text_payload:
                                append_transcript(ref_of(this.transcript), text_payload.value)
                            Option.none:
                                append_transcript(ref_of(this.transcript), "[non-utf8 output]\n")

                    if chunk.closed:
                        this.active = false
                        this.status.assign("child exited")
                        break

                    if not chunk.ready:
                        break

            attempts += 1


    mutable function push_input_byte(value: ubyte) -> void:
        this.input.push(value)


    mutable function pop_input_byte() -> void:
        match this.input.pop():
            Option.some:
                pass
            Option.none:
                pass


    mutable function submit() -> void:
        if not this.active:
            this.restart()
            if not this.active:
                return

        var outgoing = string.String.create()
        defer outgoing.release()
        match byte_buffer_as_str(this.input):
            Option.some as payload:
                outgoing.append(payload.value)
            Option.none:
                this.status.assign("input buffer is not valid UTF-8")
                this.input.clear()
                return
        outgoing.append("\n")

        match this.child.write_stdin(outgoing.as_str()):
            Result.failure as payload:
                var error = payload.error
                defer error.release()
                set_status_message(ref_of(this.status), "write failed: ", error.message.as_str())
            Result.success:
                this.status.assign("sent line to child")

        this.input.clear()


    mutable function release() -> void:
        this.shutdown()
        this.transcript.release()
        this.input.release()
        this.status.release()


public function print_once() -> int:
    var snapshot = collect_snapshot(1)
    defer snapshot.release()
    var output = render_snapshot_text(snapshot)
    defer output.release()
    return write_stdout_text(output.as_str())


public function run(config: Config) -> int:
    if not terminal.stdin_is_tty() or not terminal.stdout_is_tty():
        return write_stderr_text("mtop dashboard requires a TTY. Use `mtop once` for non-interactive output.\n")

    var app_terminal = terminal.Terminal.create()
    defer app_terminal.release()

    match app_terminal.refresh_size():
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            return 1
        Result.success:
            pass
    if not terminal_bool_ok(app_terminal.enter_alternate_screen()):
        return 1
    if not terminal_bool_ok(app_terminal.hide_cursor()):
        return 1
    if not terminal_bool_ok(app_terminal.enter_raw_mode()):
        return 1
    if config.mouse_enabled:
        if not terminal_bool_ok(app_terminal.enable_mouse()):
            return 1

    var current_size = app_terminal.current_size()
    var snapshot = collect_snapshot(1)
    defer snapshot.release()
    var echo = EchoSession.create()
    defer echo.release()
    var paused = false
    var running = true
    var refresh_count = 1
    var active_tab = DashboardTab.overview
    var selected_process_index = clamp_process_selection(snapshot.process_table.as_str(), 0)
    var last_event = string.String.from_str("startup")
    defer last_event.release()

    while running:
        echo.pump()
        if not render_dashboard(ref_of(app_terminal), current_size, snapshot, echo, config, active_tab, selected_process_index, paused, last_event.as_str()):
            return 1

        match app_terminal.poll_event(config.interval_ms):
            Result.failure as payload:
                var error = payload.error
                defer error.release()
                return write_stderr_text(error.message.as_str())
            Result.success as payload:
                match payload.value:
                    Option.none:
                        if not paused:
                            var next_snapshot = collect_snapshot(refresh_count + 1)
                            snapshot.release()
                            snapshot = next_snapshot
                            refresh_count += 1
                            selected_process_index = clamp_process_selection(snapshot.process_table.as_str(), selected_process_index)
                            last_event.assign("timer refresh")
                    Option.some as event_payload:
                        let event = event_payload.value
                        if event.kind == terminal.EventKind.resize:
                            current_size = event.size
                            var resize_message = string.String.from_str("resize ")
                            fmt.append_int(ref_of(resize_message), event.size.width)
                            resize_message.append("x")
                            fmt.append_int(ref_of(resize_message), event.size.height)
                            last_event.assign(resize_message.as_str())
                            resize_message.release()
                        else if event.kind == terminal.EventKind.mouse:
                            var mouse_message = describe_mouse_event(event.mouse)
                            last_event.assign(mouse_message.as_str())

                            if event.mouse.action == terminal.MouseAction.press and event.mouse.button == terminal.MouseButton.left:
                                match tab_hit_test(event.mouse.column, event.mouse.row):
                                    Option.some as tab_payload:
                                        active_tab = tab_payload.value
                                        mouse_message.release()
                                        continue
                                    Option.none:
                                        pass

                                if current_size.width >= 72 and current_size.height >= 24:
                                    if active_tab == DashboardTab.overview:
                                        match process_selection_from_mouse(overview_process_panel(current_size), snapshot.process_table.as_str(), event.mouse.column, event.mouse.row):
                                            Option.some as selection_payload:
                                                selected_process_index = selection_payload.value
                                                active_tab = DashboardTab.processes
                                                mouse_message.release()
                                                continue
                                            Option.none:
                                                pass
                                    else if active_tab == DashboardTab.processes:
                                        match process_selection_from_mouse(processes_main_panel(current_size), snapshot.process_table.as_str(), event.mouse.column, event.mouse.row):
                                            Option.some as selection_payload:
                                                selected_process_index = selection_payload.value
                                                mouse_message.release()
                                                continue
                                            Option.none:
                                                pass

                            mouse_message.release()
                        else if event.kind == terminal.EventKind.key:
                            var key_message = describe_key_event(event.key)
                            last_event.assign(key_message.as_str())

                            if event.key.code == terminal.KeyCode.tab or event.key.code == terminal.KeyCode.right:
                                active_tab = next_tab(active_tab)
                                key_message.release()
                                continue

                            if event.key.code == terminal.KeyCode.shift_tab or event.key.code == terminal.KeyCode.left:
                                active_tab = previous_tab(active_tab)
                                key_message.release()
                                continue

                            if event.key.code == terminal.KeyCode.escape or (event.key.ctrl and event.key.has_byte and event.key.input_byte == ubyte<-99):
                                key_message.release()
                                running = false
                                continue

                            if event.key.ctrl and event.key.has_byte and event.key.input_byte == ubyte<-114:
                                var next_snapshot = collect_snapshot(refresh_count + 1)
                                snapshot.release()
                                snapshot = next_snapshot
                                refresh_count += 1
                                selected_process_index = clamp_process_selection(snapshot.process_table.as_str(), selected_process_index)
                                key_message.release()
                                continue

                            if event.key.ctrl and event.key.has_byte and event.key.input_byte == ubyte<-112:
                                paused = not paused
                                key_message.release()
                                continue

                            if event.key.ctrl and event.key.has_byte and event.key.input_byte == ubyte<-110:
                                echo.restart()
                                key_message.release()
                                continue

                            if active_tab == DashboardTab.processes and event.key.code == terminal.KeyCode.up:
                                selected_process_index = clamp_process_selection(snapshot.process_table.as_str(), selected_process_index - 1)
                                key_message.release()
                                continue

                            if active_tab == DashboardTab.processes and event.key.code == terminal.KeyCode.down:
                                selected_process_index = clamp_process_selection(snapshot.process_table.as_str(), selected_process_index + 1)
                                key_message.release()
                                continue

                            if active_tab == DashboardTab.processes and event.key.code == terminal.KeyCode.home:
                                selected_process_index = 0
                                key_message.release()
                                continue

                            if active_tab == DashboardTab.processes and event.key.code == terminal.KeyCode.end:
                                selected_process_index = clamp_process_selection(snapshot.process_table.as_str(), process_entry_count(snapshot.process_table.as_str()) - 1)
                                key_message.release()
                                continue

                            if active_tab == DashboardTab.echo and event.key.code == terminal.KeyCode.enter:
                                echo.submit()
                                key_message.release()
                                continue

                            if active_tab == DashboardTab.echo and event.key.code == terminal.KeyCode.backspace:
                                echo.pop_input_byte()
                                key_message.release()
                                continue

                            if active_tab == DashboardTab.echo and event.key.code == terminal.KeyCode.character and event.key.has_byte and not event.key.ctrl and not event.key.alt and event.key.input_byte >= 32 and event.key.input_byte < 127:
                                echo.push_input_byte(event.key.input_byte)

                            key_message.release()

    return 0
