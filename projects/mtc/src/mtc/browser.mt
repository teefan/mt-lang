## The host's `Run#open_browser`: linux uses `xdg-open`, windows
## `cmd /c start`.  Failures are ignored (a headless session just keeps the URL).

import std.env as env
import std.process as process
import std.vec as vec


public function open(url: str) -> void:
    var command = vec.Vec[str].create()
    defer: command.release()
    if env.get("OS").is_some():
        command.push("cmd")
        command.push("/c")
        command.push("start")
        command.push("")
        command.push(url)
    else:
        command.push("xdg-open")
        command.push(url)
    match process.spawn_detached(command.as_span()):
        Result.success:
            pass
        Result.failure as failure:
            var error = failure.error
            error.release()
