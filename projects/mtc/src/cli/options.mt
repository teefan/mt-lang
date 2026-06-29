import std.str
import std.vec as vec

public enum Command: ubyte
    cmd_check = 0
    cmd_build = 1
    cmd_help  = 2
    cmd_unknown = 3

public struct CliOptions:
    command: Command
    source_path: str
    output_path: str
    platform: str
    profile: str
    locked: bool

extending CliOptions:
    public static function parse(argv: vec.Vec[str]) -> CliOptions:
        var cmd: Command = Command.cmd_unknown
        var path: str = ""
        var output: str = ""
        var platform: str = "linux"
        var profile: str = "debug"
        var locked: bool = false

        var i: ptr_uint = 0
        while i < argv.len():
            let arg_ptr = argv.get(i) else:
                break
            unsafe:
                let arg = read(arg_ptr)
                if arg.equal("check"):
                    cmd = Command.cmd_check
                else if arg.equal("build"):
                    cmd = Command.cmd_build
                else if arg.equal("help") or arg.equal("--help") or arg.equal("-h"):
                    cmd = Command.cmd_help
                else if arg.equal("--platform"):
                    i += 1
                    if i < argv.len():
                        let pv = argv.get(i) else:
                            break
                        unsafe:
                            platform = read(pv)
                else if arg.equal("--profile"):
                    i += 1
                    if i < argv.len():
                        let pv = argv.get(i) else:
                            break
                        unsafe:
                            profile = read(pv)
                else if arg.equal("--locked"):
                    locked = true
                else if arg.equal("-o") or arg.equal("--output"):
                    i += 1
                    if i < argv.len():
                        let ov = argv.get(i) else:
                            break
                        unsafe:
                            output = read(ov)
                else if not arg.starts_with("--"):
                    path = arg
            i += 1

        return CliOptions(command = cmd, source_path = path, output_path = output, platform = platform, profile = profile, locked = locked)
