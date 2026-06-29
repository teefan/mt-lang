import std.stdio as stdio
import std.vec as vec

import cli.options
import cli.check
import cli.build

function main(args: span[str]) -> int:
    var argv = vec.Vec[str].create()
    var i: ptr_uint = 0
    while i < args.len:
        unsafe:
            argv.push(read(args.data + i))
        i += 1

    var opts = options.CliOptions.parse(argv)

    if opts.command == options.Command.cmd_check:
        return check.run_check(ref_of(opts))
    else if opts.command == options.Command.cmd_build:
        return build.run_build(ref_of(opts))
    else if opts.command == options.Command.cmd_help:
        stdio.print_format("usage: mtc check <path>\n")
        stdio.print_format("       mtc build <path> [-o output]\n")
        return 0

    if opts.command == options.Command.cmd_unknown and opts.source_path != "":
        return check.run_check(ref_of(opts))

    stdio.print_format("usage: mtc check <path>\n")
    return 1
