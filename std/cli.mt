import std.fmt as fmt
import std.str as text
import std.string as string
import std.vec as vec

const byte_hyphen: ubyte = ubyte<-45
const byte_equals: ubyte = ubyte<-61

public enum OptionKind: int
    flag = 0
    value = 1

public struct OptionSpec:
    long_name: str
    short_name: Option[str]
    kind: OptionKind
    help: str
    value_name: Option[str]
    default_value: Option[str]
    required: bool

public struct CommandSpec:
    name: str
    summary: str
    help: str
    options: span[OptionSpec]
    positional_help: Option[str]

public struct AppSpec:
    name: str
    summary: str
    options: span[OptionSpec]
    commands: span[CommandSpec]
    positional_help: Option[str]

public struct OptionMatch:
    name: string.String
    present: bool
    value: string.String
    has_value: bool

public struct Match:
    command_name: string.String
    has_command: bool
    options: vec.Vec[OptionMatch]
    positionals: vec.Vec[string.String]
    show_help: bool

public struct Error:
    message: string.String


function create_error(message: str) -> Error:
    return Error(message = string.String.from_str(message))


function create_option_match(spec: OptionSpec) -> OptionMatch:
    var value = string.String.create()
    var has_value = false
    match spec.default_value:
        Option.some as payload:
            value = string.String.from_str(payload.value)
            has_value = true
        Option.none:
            pass

    return OptionMatch(
        name = string.String.from_str(spec.long_name),
        present = false,
        value = value,
        has_value = has_value
    )


function create_match() -> Match:
    return Match(
        command_name = string.String.create(),
        has_command = false,
        options = vec.Vec[OptionMatch].create(),
        positionals = vec.Vec[string.String].create(),
        show_help = false
    )


function append_line(output: ref[string.String], line: str) -> void:
    output.append_format(f"#{line}\n")


function append_switch_label(output: ref[string.String], spec: OptionSpec) -> void:
    match spec.short_name:
        Option.some as payload:
            output.append_format(f"-#{payload.value}, ")
        Option.none:
            pass

    output.append_format(f"--#{spec.long_name}")

    if spec.kind == OptionKind.value:
        match spec.value_name:
            Option.some as payload:
                output.append_format(f" #{payload.value}")
            Option.none:
                output.append(" VALUE")


function append_option_help(output: ref[string.String], spec: OptionSpec) -> void:
    output.append("  ")
    append_switch_label(output, spec)
    output.append_format(f" - #{spec.help}")
    match spec.default_value:
        Option.some as payload:
            output.append_format(f" (default: #{payload.value})")
        Option.none:
            pass
    if spec.required:
        output.append(" (required)")
    output.append("\n")


function append_help_header(output: ref[string.String], title: str, summary: str, usage: str) -> void:
    append_line(output, title)
    append_line(output, usage)
    append_line(output, "")
    append_line(output, summary)
    append_line(output, "")


function append_commands_section(output: ref[string.String], commands: span[CommandSpec]) -> void:
    if commands.len == 0:
        return

    append_line(output, "Commands:")
    var index: ptr_uint = 0
    while index < commands.len:
        let spec = unsafe: read(commands.data + index)
        output.append_format(f"  #{spec.name} - #{spec.summary}\n")
        index += 1
    append_line(output, "")


function append_options_section(
    output: ref[string.String],
    app_options: span[OptionSpec],
    command_options: span[OptionSpec]
) -> void:
    append_line(output, "Options:")
    append_line(output, "  -h, --help - Show this help")

    var index: ptr_uint = 0
    while index < app_options.len:
        append_option_help(output, unsafe: read(app_options.data + index))
        index += 1

    index = 0
    while index < command_options.len:
        append_option_help(output, unsafe: read(command_options.data + index))
        index += 1


function short_name_valid(short_name: str) -> bool:
    return short_name.len == 1


function find_command(commands: span[CommandSpec], name: str) -> ptr[CommandSpec]?:
    var index: ptr_uint = 0
    while index < commands.len:
        let candidate = unsafe: commands.data + index
        if unsafe: read(candidate).name.equal(name):
            return candidate
        index += 1

    return null


function find_long_option(
    app_options: span[OptionSpec],
    command_options: span[OptionSpec],
    name: str
) -> ptr[OptionSpec]?:
    var index: ptr_uint = 0
    while index < command_options.len:
        let candidate = unsafe: command_options.data + index
        if unsafe: read(candidate).long_name.equal(name):
            return candidate
        index += 1

    index = 0
    while index < app_options.len:
        let candidate = unsafe: app_options.data + index
        if unsafe: read(candidate).long_name.equal(name):
            return candidate
        index += 1

    return null


function find_short_option(
    app_options: span[OptionSpec],
    command_options: span[OptionSpec],
    name: str
) -> ptr[OptionSpec]?:
    var index: ptr_uint = 0
    while index < command_options.len:
        let candidate = unsafe: command_options.data + index
        match unsafe: read(candidate).short_name:
            Option.some as payload:
                if payload.value.equal(name):
                    return candidate
            Option.none:
                pass
        index += 1

    index = 0
    while index < app_options.len:
        let candidate = unsafe: app_options.data + index
        match unsafe: read(candidate).short_name:
            Option.some as payload:
                if payload.value.equal(name):
                    return candidate
            Option.none:
                pass
        index += 1

    return null


function find_option_match(matches: vec.Vec[OptionMatch], name: str) -> ptr[OptionMatch]?:
    var index: ptr_uint = 0
    while true:
        if index >= matches.len():
            break

        let candidate = matches.get(index) else:
            return null

        if unsafe: read(candidate).name.as_str().equal(name):
            return candidate

        index += 1

    return null


function append_option_specs(matches: ptr[vec.Vec[OptionMatch]], specs: span[OptionSpec]) -> Result[bool, Error]:
    var index: ptr_uint = 0
    while index < specs.len:
        let spec = unsafe: read(specs.data + index)

        if spec.long_name.len == 0:
            return Result[bool, Error].failure(error= create_error("cli option long name cannot be empty"))

        match spec.short_name:
            Option.some as payload:
                if not short_name_valid(payload.value):
                    return Result[
                        bool,
                        Error
                    ].failure(error= create_error("cli short option names must be exactly one character"))
            Option.none:
                pass

        let current = unsafe: read(matches)
        if find_option_match(current, spec.long_name) != null:
            return Result[
                bool,
                Error
            ].failure(error= create_error("cli option names must be unique within the active command"))

        unsafe: read(matches).push(create_option_match(spec))
        index += 1

    return Result[bool, Error].success(value= true)


function set_option_flag(result: ptr[Match], spec: OptionSpec) -> Result[bool, Error]:
    let current = unsafe: read(result)
    let option_match = find_option_match(current.options, spec.long_name) else:
        return Result[bool, Error].failure(error= create_error("cli parser lost option state"))

    unsafe:
        read(option_match).present = true
        if spec.kind == OptionKind.flag:
            read(option_match).has_value = false
            read(option_match).value.clear()

    return Result[bool, Error].success(value= true)


function set_option_value(result: ptr[Match], spec: OptionSpec, value: str) -> Result[bool, Error]:
    let current = unsafe: read(result)
    let option_match = find_option_match(current.options, spec.long_name) else:
        return Result[bool, Error].failure(error= create_error("cli parser lost option state"))

    unsafe:
        read(option_match).present = true
        read(option_match).has_value = true
        read(option_match).value.assign(value)

    return Result[bool, Error].success(value= true)


function require_value_arg(option_name: str) -> Error:
    let message = fmt.format(f"missing value for #{option_name}")
    return Error(message = message)


function unknown_option_error(option_name: str) -> Error:
    let message = fmt.format(f"unknown option #{option_name}")
    return Error(message = message)


function unknown_command_error(command_name: str) -> Error:
    let message = fmt.format(f"unknown command #{command_name}")
    return Error(message = message)


function option_takes_value(spec: OptionSpec) -> bool:
    return spec.kind == OptionKind.value


function split_long_option(arg: str) -> Option[ptr_uint]:
    match arg.find_byte(byte_equals):
        Option.some as payload:
            if payload.value > 2:
                return Option[ptr_uint].some(value= payload.value)
        Option.none:
            pass

    return Option[ptr_uint].none


function usage_for_app(app: AppSpec) -> string.String:
    var usage = string.String.create()
    usage.append_format(f"Usage: #{app.name}")
    if app.options.len != 0:
        usage.append(" [options]")
    if app.commands.len != 0:
        usage.append(" <command>")
    else:
        match app.positional_help:
            Option.some as payload:
                usage.append(" ")
                usage.append(payload.value)
            Option.none:
                pass
    return usage


function usage_for_command(app: AppSpec, command: CommandSpec) -> string.String:
    var usage = string.String.create()
    usage.append_format(f"Usage: #{app.name} #{command.name}")
    if app.options.len != 0 or command.options.len != 0:
        usage.append(" [options]")
    match command.positional_help:
        Option.some as payload:
            usage.append(" ")
            usage.append(payload.value)
        Option.none:
            pass
    return usage


function validate_required_options(
    result: Match,
    app_options: span[OptionSpec],
    command_options: span[OptionSpec]
) -> Result[bool, Error]:
    var index: ptr_uint = 0
    while index < app_options.len:
        let spec = unsafe: read(app_options.data + index)
        if spec.required:
            let option_match = find_option_match(result.options, spec.long_name) else:
                return Result[bool, Error].failure(error= create_error("cli parser lost global option state"))

            let current = unsafe: read(option_match)
            if not current.present and not current.has_value:
                return Result[bool, Error].failure(error= require_value_arg(spec.long_name))
        index += 1

    index = 0
    while index < command_options.len:
        let spec = unsafe: read(command_options.data + index)
        if spec.required:
            let option_match = find_option_match(result.options, spec.long_name) else:
                return Result[bool, Error].failure(error= create_error("cli parser lost command option state"))

            let current = unsafe: read(option_match)
            if not current.present and not current.has_value:
                return Result[bool, Error].failure(error= require_value_arg(spec.long_name))
        index += 1

    return Result[bool, Error].success(value= true)


public function flag_option(long_name: str, short_name: Option[str], help: str) -> OptionSpec:
    return OptionSpec(
        long_name = long_name,
        short_name = short_name,
        kind = OptionKind.flag,
        help = help,
        value_name = Option[str].none,
        default_value = Option[str].none,
        required = false
    )


public function value_option(
    long_name: str,
    short_name: Option[str],
    value_name: str,
    help: str,
    required: bool,
    default_value: Option[str]
) -> OptionSpec:
    return OptionSpec(
        long_name = long_name,
        short_name = short_name,
        kind = OptionKind.value,
        help = help,
        value_name = Option[str].some(value= value_name),
        default_value = default_value,
        required = required
    )


public function command_spec(
    name: str,
    summary: str,
    help: str,
    options: span[OptionSpec],
    positional_help: Option[str]
) -> CommandSpec:
    return CommandSpec(
        name = name,
        summary = summary,
        help = help,
        options = options,
        positional_help = positional_help
    )


public function app_spec(
    name: str,
    summary: str,
    options: span[OptionSpec],
    commands: span[CommandSpec],
    positional_help: Option[str]
) -> AppSpec:
    return AppSpec(
        name = name,
        summary = summary,
        options = options,
        commands = commands,
        positional_help = positional_help
    )


public function parse(app: AppSpec, args: span[str]) -> Result[Match, Error]:
    var result = create_match()

    match append_option_specs(ptr_of(result.options), app.options):
        Result.failure as append_error_payload:
            result.release()
            return Result[Match, Error].failure(error= append_error_payload.error)
        Result.success:
            pass

    var command_options: span[OptionSpec] = zero[span[OptionSpec]]
    var index: ptr_uint = 0
    var end_of_options = false

    while index < args.len:
        let arg = unsafe: read(args.data + index)

        if not end_of_options and arg.equal("--"):
            end_of_options = true
            index += 1
            continue

        if not end_of_options and (arg.equal("--help") or arg.equal("-h")):
            result.show_help = true
            return Result[Match, Error].success(value= result)

        if not end_of_options and arg.starts_with("--") and arg.len > 2:
            let split_index = split_long_option(arg)
            var option_name = arg.slice(2, arg.len - 2)
            var inline_value = Option[str].none
            match split_index:
                Option.some as payload:
                    option_name = arg.slice(2, payload.value - 2)
                    inline_value = Option[str].some(value= arg.slice(payload.value + 1, arg.len - payload.value - 1))
                Option.none:
                    pass

            let spec_ptr = find_long_option(app.options, command_options, option_name) else:
                result.release()
                return Result[Match, Error].failure(error= unknown_option_error(arg))

            let spec = unsafe: read(spec_ptr)
            if option_takes_value(spec):
                var consumed_next = false
                var value = arg
                match inline_value:
                    Option.some as payload:
                        value = payload.value
                    Option.none:
                        if index + 1 >= args.len:
                            result.release()
                            let missing = fmt.format(f"--#{spec.long_name}")
                            return Result[Match, Error].failure(error= require_value_arg(missing.as_str()))
                        value = unsafe: read(args.data + index + 1)
                        consumed_next = true

                match set_option_value(ptr_of(result), spec, value):
                    Result.failure as value_error_payload:
                        result.release()
                        return Result[Match, Error].failure(error= value_error_payload.error)
                    Result.success:
                        pass

                index += 1
                if consumed_next:
                    index += 1
                continue

            match inline_value:
                Option.some:
                    result.release()
                    return Result[Match, Error].failure(error= create_error("flag options do not accept inline values"))
                Option.none:
                    pass

            match set_option_flag(ptr_of(result), spec):
                Result.failure as flag_error_payload:
                    result.release()
                    return Result[Match, Error].failure(error= flag_error_payload.error)
                Result.success:
                    pass

            index += 1
            continue

        if not end_of_options and arg.starts_with("-") and arg.len > 1:
            var short_index: ptr_uint = 1
            var consumed_next = false
            while short_index < arg.len:
                let short_name = arg.slice(short_index, 1)
                if short_name.equal("h"):
                    result.show_help = true
                    return Result[Match, Error].success(value= result)

                let spec_ptr = find_short_option(app.options, command_options, short_name) else:
                    result.release()
                    return Result[Match, Error].failure(error= unknown_option_error(arg))

                let spec = unsafe: read(spec_ptr)
                if option_takes_value(spec):
                    var value = arg
                    if short_index + 1 < arg.len:
                        value = arg.slice(short_index + 1, arg.len - short_index - 1)
                    else:
                        if index + 1 >= args.len:
                            result.release()
                            let missing = fmt.format(f"-#{short_name}")
                            return Result[Match, Error].failure(error= require_value_arg(missing.as_str()))
                        value = unsafe: read(args.data + index + 1)
                        consumed_next = true

                    match set_option_value(ptr_of(result), spec, value):
                        Result.failure as value_error_payload:
                            result.release()
                            return Result[Match, Error].failure(error= value_error_payload.error)
                        Result.success:
                            pass

                    short_index = arg.len
                else:
                    match set_option_flag(ptr_of(result), spec):
                        Result.failure as flag_error_payload:
                            result.release()
                            return Result[Match, Error].failure(error= flag_error_payload.error)
                        Result.success:
                            pass
                    short_index += 1

            index += 1
            if consumed_next:
                index += 1
            continue

        if not result.has_command and app.commands.len != 0:
            let command_ptr = find_command(app.commands, arg) else:
                result.release()
                return Result[Match, Error].failure(error= unknown_command_error(arg))

            let command = unsafe: read(ptr[CommandSpec]<-command_ptr)
            result.has_command = true
            result.command_name.assign(command.name)
            command_options = command.options
            match append_option_specs(ptr_of(result.options), command.options):
                Result.failure as append_error_payload:
                    result.release()
                    return Result[Match, Error].failure(error= append_error_payload.error)
                Result.success:
                    pass
            index += 1
            continue

        result.positionals.push(string.String.from_str(arg))
        index += 1

    match validate_required_options(result, app.options, command_options):
        Result.failure as validate_payload:
            result.release()
            return Result[Match, Error].failure(error= validate_payload.error)
        Result.success:
            pass

    return Result[Match, Error].success(value= result)


public function render_help(app: AppSpec) -> string.String:
    var output = string.String.create()
    var title = fmt.format(f"#{app.name} - #{app.summary}")
    var usage = usage_for_app(app)
    append_help_header(ref_of(output), title.as_str(), app.summary, usage.as_str())
    append_commands_section(ref_of(output), app.commands)
    append_options_section(ref_of(output), app.options, zero[span[OptionSpec]])
    title.release()
    usage.release()
    return output


public function render_command_help(app: AppSpec, command_name: str) -> Result[string.String, Error]:
    let command_ptr = find_command(app.commands, command_name) else:
        return Result[string.String, Error].failure(error= unknown_command_error(command_name))

    let command = unsafe: read(command_ptr)
    var output = string.String.create()
    var title = fmt.format(f"#{app.name} #{command.name} - #{command.help}")
    var usage = usage_for_command(app, command)
    append_help_header(ref_of(output), title.as_str(), command.help, usage.as_str())
    append_options_section(ref_of(output), app.options, command.options)
    title.release()
    usage.release()
    return Result[string.String, Error].success(value= output)


extending OptionMatch:
    public editable function release() -> void:
        this.name.release()
        this.value.release()


extending Match:
    public function command() -> Option[str]:
        if not this.has_command:
            return Option[str].none

        return Option[str].some(value= this.command_name.as_str())


    public function help_requested() -> bool:
        return this.show_help


    public function supplied(name: str) -> bool:
        let option_match = find_option_match(this.options, name) else:
            return false

        return unsafe: read(option_match).present


    public function flag(name: str) -> bool:
        return this.supplied(name)


    public function value(name: str) -> Option[str]:
        let option_match = find_option_match(this.options, name) else:
            return Option[str].none

        unsafe:
            if not read(option_match).has_value:
                return Option[str].none

            return Option[str].some(value= read(option_match).value.as_str())


    public function positionals_len() -> ptr_uint:
        return this.positionals.len()


    public function positional(index: ptr_uint) -> Option[str]:
        let value = this.positionals.get(index) else:
            return Option[str].none

        unsafe:
            return Option[str].some(value= read(value).as_str())


    public editable function release() -> void:
        this.command_name.release()

        var option_index: ptr_uint = 0
        while option_index < this.options.len():
            let value = this.options.get(option_index)
            if value == null:
                break

            unsafe:
                read(ptr[OptionMatch]<-value).release()

            option_index += 1

        this.options.release()

        var positional_index: ptr_uint = 0
        while positional_index < this.positionals.len():
            let value = this.positionals.get(positional_index)
            if value == null:
                break

            unsafe:
                read(ptr[string.String]<-value).release()

            positional_index += 1

        this.positionals.release()


extending Error:
    public editable function release() -> void:
        this.message.release()
