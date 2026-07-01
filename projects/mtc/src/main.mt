import std.cli as cli
import std.fmt as fmt
import std.fs
import std.string
import std.terminal as terminal
import std.log as log
import std.vec
import lexer
import parser
import parser.ast_types as ast
import printer


const VERSION: str = "0.1.0"


function write_stdout_text(value: str) -> int:
    match terminal.write_stdout(value):
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            return 1
        Result.success:
            pass

    match terminal.write_stdout("\n"):
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
            pass

    match terminal.write_stderr("\n"):
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            return 1
        Result.success:
            return 0


function print_error(message: str) -> int:
    var line = fmt.format(f"error: #{message}")
    defer line.release()
    return write_stderr_text(line.as_str())


function print_stderr(error_message: str) -> int:
    log.error(error_message)
    return 1


function require_positional(parsed: cli.Match, label: str) -> Option[str]:
    let name = parsed.positional(0)
    if name.is_none():
        var message = fmt.format(f"missing #{label}")
        defer message.release()
        let _ = print_error(message.as_str())
        return Option[str].none

    return name


function print_help(app: cli.AppSpec, command_name: Option[str]) -> int:
    match command_name:
        Option.some as payload:
            match cli.render_command_help(app, payload.value):
                Result.failure as error_payload:
                    var error = error_payload.error
                    defer error.release()
                    return write_stderr_text(error.message.as_str())
                Result.success as help_payload:
                    var help = help_payload.value
                    defer help.release()
                    return write_stdout_text(help.as_str())
        Option.none:
            var help = cli.render_help(app)
            defer help.release()
            return write_stdout_text(help.as_str())


function handle_check(parsed: cli.Match) -> int:
    if parsed.positionals_len() == 0:
        var msg = fmt.format("missing source file path")
        defer msg.release()
        return print_stderr(msg.as_str())

    log.info("check stub: would type-check source files")
    return 0


function handle_build(parsed: cli.Match) -> int:
    if parsed.flag("clean"):
        log.info("build stub: would clean")
        return 0

    log.info("build stub: would compile a source file or package")
    return 0


function handle_run(parsed: cli.Match) -> int:
    if parsed.flag("quiet"):
        log.set_level(log.Level.warn)

    log.info("run stub: would build and execute a program")
    return 0


function handle_test(parsed: cli.Match) -> int:
    if parsed.flag("sanitize"):
        log.info("test stub: would run with sanitizers enabled")

    log.info("test stub: would discover and run @[test] functions")
    return 0


function handle_new(parsed: cli.Match) -> int:
    match require_positional(parsed, "project name"):
        Option.some:
            log.info("new stub: would scaffold a new package")
        Option.none:
            return 1

    return 0


function handle_format(parsed: cli.Match) -> int:
    if parsed.flag("check"):
        log.debug("format stub: check mode")

    log.info("format stub: would format source files")
    return 0


function handle_lint(parsed: cli.Match) -> int:
    if parsed.flag("fix"):
        log.debug("lint stub: fix mode")

    log.info("lint stub: would lint source files")
    return 0


function handle_lex(parsed: cli.Match) -> int:
    match require_positional(parsed, "source file path"):
        Option.some as path_payload:
            let file_path = path_payload.value
            match fs.read_text(file_path):
                Result.failure as read_error:
                    var error = read_error.error
                    defer error.release()
                    return print_stderr(error.message.as_str())
                Result.success as read_payload:
                    var content = read_payload.value
                    defer content.release()
                    var tokens = lexer.lex(content.as_str(), file_path)
                    defer tokens.release()

                    let count = tokens.len()
                    var index: ptr_uint = 0
                    var output = string.String.create()
                    defer output.release()

                    while index < count:
                        lexer.write_token_line(ref_of(tokens), index, ref_of(output))
                        let _ = write_stdout_text(output.as_str())
                        index += 1

                    return 0
        Option.none:
            return 1

    return 0


function handle_parse(parsed: cli.Match) -> int:
    if parsed.positionals_len() == 0:
        var msg = fmt.format("missing source file path")
        defer msg.release()
        return print_stderr(msg.as_str())

    let path_payload = parsed.positional(0)
    let file_path = path_payload else:
        return print_stderr("missing source file path")

    match fs.read_text(file_path):
        Result.failure as read_error:
            var error = read_error.error
            defer error.release()
            return print_stderr(error.message.as_str())
        Result.success as read_payload:
            var content = read_payload.value
            defer content.release()

            var tokens = lexer.lex(content.as_str(), file_path)
            defer tokens.release()

            var decls = vec.Vec[ast.Decl].create()
            defer decls.release()

            let result = parser.parse(ref_of(tokens), file_path, ref_of(decls))

            if result.success:
                var msg = fmt.format(f"parsed #{file_path}: #{result.total_decls} declaration(s), #{result.imports} import(s)")
                defer msg.release()
                let _ = write_stderr_text(msg.as_str())

                log.info(f"  structs=#{result.stats.structs} enums=#{result.stats.enums} consts=#{result.stats.consts}")
                log.info(f"  functions=#{result.stats.functions} vars=#{result.stats.vars} flags=#{result.stats.flags_count}")

                var output = string.String.create()
                defer output.release()
                printer.print_ast(ref_of(decls), content.as_str(), ref_of(output))
                let _ = write_stdout_text(output.as_str())
                return 0
            else:
                var msg = fmt.format(f"parse failed for #{file_path}")
                defer msg.release()
                let _ = write_stderr_text(msg.as_str())
                return 1

    return 0


function handle_lower(parsed: cli.Match) -> int:
    if parsed.flag("verbose"):
        log.debug("lower stub")
    log.info("lower stub: would lower source to IR and print it")
    return 0


function handle_emit_c(parsed: cli.Match) -> int:
    if parsed.flag("verbose"):
        log.debug("emit-c stub")
    log.info("emit-c stub: would compile source to C and print it")
    return 0


function handle_debug(parsed: cli.Match) -> int:
    if parsed.flag("verbose"):
        log.debug("debug stub")
    log.info("debug stub: would print tokens, AST, facts, and diagnostics")
    return 0


function handle_deps(parsed: cli.Match) -> int:
    if parsed.flag("verbose"):
        log.debug("deps stub")
    log.info("deps stub: would manage package dependencies")
    return 0


function handle_toolchain(parsed: cli.Match) -> int:
    if parsed.flag("verbose"):
        log.debug("toolchain stub")
    log.info("toolchain stub: would manage the native toolchain")
    return 0


function handle_bindgen(parsed: cli.Match) -> int:
    if parsed.flag("verbose"):
        log.debug("bindgen stub")
    log.info("bindgen stub: would generate a binding module from a C header")
    return 0


function handle_cache(parsed: cli.Match) -> int:
    if parsed.flag("verbose"):
        log.debug("cache stub")
    log.info("cache stub: would inspect and manage the build cache")
    return 0


function handle_docs(parsed: cli.Match) -> int:
    if parsed.flag("verbose"):
        log.debug("docs stub")
    log.info("docs stub: would serve the local documentation site")
    return 0


function handle_snapshot(parsed: cli.Match) -> int:
    if parsed.flag("verbose"):
        log.debug("snapshot stub")
    log.info("snapshot stub: would render a highlighted HTML snapshot")
    return 0


function handle_completions(parsed: cli.Match) -> int:
    match require_positional(parsed, "shell name (bash, zsh, or fish)"):
        Option.some as payload:
            let shell = payload.value
            if not shell == "bash" and not shell == "zsh" and not shell == "fish":
                var msg = fmt.format(f"completions: shell must be bash, zsh, or fish, got #{shell}")
                defer msg.release()
                return print_stderr(msg.as_str())

            log.info("completions stub: would print a shell completion script")
        Option.none:
            return 1

    return 0


function handle_version(parsed: cli.Match) -> int:
    if parsed.flag("verbose"):
        log.debug("version stub")
    var version_output = fmt.format(f"mtc #{VERSION}")
    defer version_output.release()
    return write_stdout_text(version_output.as_str())


function dispatch(app: cli.AppSpec, parsed: cli.Match) -> int:
    if parsed.flag("verbose"):
        log.debug(app.summary)
    match parsed.command():
        Option.some as command_payload:
            let command_name = command_payload.value
            if command_name == "check":
                return handle_check(parsed)
            else if command_name == "build":
                return handle_build(parsed)
            else if command_name == "run":
                return handle_run(parsed)
            else if command_name == "test":
                return handle_test(parsed)
            else if command_name == "new":
                return handle_new(parsed)
            else if command_name == "format":
                return handle_format(parsed)
            else if command_name == "lint":
                return handle_lint(parsed)
            else if command_name == "lex":
                return handle_lex(parsed)
            else if command_name == "parse":
                return handle_parse(parsed)
            else if command_name == "lower":
                return handle_lower(parsed)
            else if command_name == "emit-c":
                return handle_emit_c(parsed)
            else if command_name == "debug":
                return handle_debug(parsed)
            else if command_name == "deps":
                return handle_deps(parsed)
            else if command_name == "toolchain":
                return handle_toolchain(parsed)
            else if command_name == "bindgen":
                return handle_bindgen(parsed)
            else if command_name == "cache":
                return handle_cache(parsed)
            else if command_name == "docs":
                return handle_docs(parsed)
            else if command_name == "snapshot":
                return handle_snapshot(parsed)
            else if command_name == "completions":
                return handle_completions(parsed)
            else if command_name == "version":
                return handle_version(parsed)

        Option.none:
            return 0

    return 0


function main(args: span[str]) -> int:
    # App-level option specs
    var app_opts = array[cli.OptionSpec, 12](
        cli.flag_option("quiet", Option[str].some(value= "q"), "Suppress informational output"),
        cli.flag_option("verbose", Option[str].some(value= "v"), "Print per-file progress"),
        cli.value_option(
            "color",
            Option[str].none,
            "WHEN",
            "Colorize diagnostics: auto (default), always, never",
            false,
            Option[str].some(value= "auto"),
        ),
        cli.value_option(
            "include-path",
            Option[str].some(value= "I"),
            "PATH",
            "Add an extra module root",
            false,
            Option[str].none,
        ),
        cli.value_option(
            "profile",
            Option[str].none,
            "PROFILE",
            "Build profile: debug (default) or release",
            false,
            Option[str].some(value= "debug"),
        ),
        cli.value_option(
            "platform",
            Option[str].none,
            "PLATFORM",
            "Target platform: linux (default), windows, or wasm",
            false,
            Option[str].some(value= "linux"),
        ),
        cli.value_option("cc", Option[str].none, "COMPILER", "C compiler to use", false, Option[str].none),
        cli.flag_option("locked", Option[str].none, "Resolve dependencies from package.lock"),
        cli.flag_option("frozen", Option[str].none, "Require a current package.lock"),
        cli.value_option("output", Option[str].some(value= "o"), "OUTPUT", "Output path for the compiled artifact", false, Option[str].none),
        cli.value_option("keep-c", Option[str].none, "C_PATH", "Write the generated C source to this path", false, Option[str].none),
        cli.flag_option("no-cache", Option[str].none, "Skip build cache, force rebuild from source"),
    )

    # Command-level option specs
    var check_opts = array[cli.OptionSpec, 1](
        cli.flag_option("warnings-as-errors", Option[str].none, "Treat warnings as errors"),
    )

    var build_opts = array[cli.OptionSpec, 4](
        cli.flag_option("bundle", Option[str].none, "Package a native build into a distributable directory"),
        cli.flag_option("archive", Option[str].none, "Also write a .tar.gz archive (implies --bundle)"),
        cli.flag_option("clean", Option[str].none, "Remove existing build outputs and exit"),
        cli.value_option("kind", Option[str].none, "KIND", "Build kind: executable, static, or shared", false, Option[str].some(value= "executable")),
    )

    var test_opts = array[cli.OptionSpec, 6](
        cli.value_option("timeout", Option[str].none, "SECONDS", "Test timeout in seconds (default 30)", false, Option[str].some(value= "30")),
        cli.value_option("mem", Option[str].none, "MB", "Memory limit in megabytes (default 1024)", false, Option[str].some(value= "1024")),
        cli.value_option("jobs", Option[str].none, "N", "Number of parallel test jobs (default 1)", false, Option[str].some(value= "1")),
        cli.flag_option("sanitize", Option[str].none, "Build test binaries with AddressSanitizer/UBSan"),
        cli.value_option("name", Option[str].some(value= "n"), "SUBSTRING", "Run only tests whose name contains SUBSTRING", false, Option[str].none),
        cli.value_option("format", Option[str].none, "FORMAT", "Output format: human (default), tap, or junit", false, Option[str].some(value= "human")),
    )

    var fmt_opts = array[cli.OptionSpec, 8](
        cli.flag_option("check", Option[str].none, "Report files that need formatting without writing them"),
        cli.flag_option("write", Option[str].some(value= "w"), "Rewrite files in place"),
        cli.flag_option("safe", Option[str].none, "Format only unambiguous style changes (default)"),
        cli.flag_option("canonical", Option[str].none, "Apply all canonical style normalisations"),
        cli.flag_option("preserve", Option[str].none, "Preserve existing formatting where possible"),
        cli.flag_option("tidy", Option[str].none, "Apply tidy formatting with line wrapping"),
        cli.value_option("max-line-length", Option[str].none, "N", "Override the line length used by tidy mode", false, Option[str].none),
        cli.flag_option("timings", Option[str].none, "Print per-file format timing breakdown"),
    )

    var lint_opts = array[cli.OptionSpec, 5](
        cli.value_option("select", Option[str].none, "RULES", "Comma-separated list of rule codes to enable", false, Option[str].none),
        cli.value_option("ignore", Option[str].none, "RULES", "Comma-separated list of rule codes to suppress", false, Option[str].none),
        cli.flag_option("fix", Option[str].none, "Apply auto-fixable changes in place"),
        cli.flag_option("init", Option[str].none, "Create a default .mt-lint.yml in the current directory"),
        cli.flag_option("ignore-generated", Option[str].none, "Skip files that start with '# generated by mtc'"),
    )

    var no_opts = zero[span[cli.OptionSpec]]

    # Command specs
    var commands = array[cli.CommandSpec, 20](
        cli.command_spec(
            "check",
            "Type-check source files",
            "Run semantic analysis on one or more source files and report errors.",
            check_opts,
            Option[str].some(value= "PATHS..."),
        ),
        cli.command_spec(
            "build",
            "Compile a source file or package",
            "Compile a source file or package to a native binary or wasm bundle.",
            build_opts,
            Option[str].some(value= "[TARGET]"),
        ),
        cli.command_spec(
            "run",
            "Build and execute a program",
            "Build and execute an executable target. For wasm targets, starts a local preview server.",
            no_opts,
            Option[str].some(value= "[TARGET] [-- ARGS...]"),
        ),
        cli.command_spec(
            "test",
            "Discover and run @[test] functions",
            "Discover and run @[test] functions in one or more source files or directories.",
            test_opts,
            Option[str].some(value= "PATH|DIR"),
        ),
        cli.command_spec(
            "new",
            "Scaffold a new package",
            "Create a new application package scaffold with package.toml and src/main.mt.",
            no_opts,
            Option[str].some(value= "NAME"),
        ),
        cli.command_spec(
            "format",
            "Format source files",
            "Format Milk Tea source files in place or check formatting.",
            fmt_opts,
            Option[str].some(value= "PATHS..."),
        ),
        cli.command_spec(
            "lint",
            "Lint source files and report warnings",
            "Lint Milk Tea source files and report warnings. Some rules and auto-fixes are semantic-aware.",
            lint_opts,
            Option[str].some(value= "PATHS..."),
        ),
        cli.command_spec(
            "lex",
            "Print the lexer token stream",
            "Tokenize a source file and print the token stream.",
            no_opts,
            Option[str].some(value= "PATH"),
        ),
        cli.command_spec(
            "parse",
            "Parse source and print the AST",
            "Parse one or more source files and print the AST.",
            no_opts,
            Option[str].some(value= "PATH|DIR..."),
        ),
        cli.command_spec(
            "lower",
            "Lower source to IR and print it",
            "Lower one or more source files to IR and print it.",
            no_opts,
            Option[str].some(value= "PATH|DIR..."),
        ),
        cli.command_spec(
            "emit-c",
            "Compile source to C and print it",
            "Compile one or more source files to C and print the output.",
            no_opts,
            Option[str].some(value= "PATH|DIR..."),
        ),
        cli.command_spec(
            "debug",
            "Print tokens, AST, facts, and diagnostics",
            "Print debug information for a source file: tokens, AST, semantic facts, and diagnostics.",
            no_opts,
            Option[str].some(value= "PATH"),
        ),
        cli.command_spec(
            "deps",
            "Manage package dependencies",
            "Manage package dependencies and package.lock state. Subcommands: tree, lock, add, remove, update, publish, fetch.",
            no_opts,
            Option[str].some(value= "SUBCOMMAND [ARGS...]"),
        ),
        cli.command_spec(
            "toolchain",
            "Manage the native toolchain",
            "Manage the local native toolchain and upstream native library checkouts. Subcommands: bootstrap, doctor, tools.",
            no_opts,
            Option[str].some(value= "SUBCOMMAND"),
        ),
        cli.command_spec(
            "bindgen",
            "Generate a binding module from a C header",
            "Generate a Milk Tea binding module from a C header file.",
            no_opts,
            Option[str].some(value= "MODULE HEADER"),
        ),
        cli.command_spec(
            "cache",
            "Inspect and manage the build cache",
            "Inspect and manage the build cache. Subcommands: purge, status.",
            no_opts,
            Option[str].some(value= "SUBCOMMAND"),
        ),
        cli.command_spec(
            "docs",
            "Serve the local documentation site",
            "Start a local documentation server for Milk Tea with language reference and standard library exploration.",
            no_opts,
            Option[str].some(value= "[OPTIONS]"),
        ),
        cli.command_spec(
            "snapshot",
            "Render a highlighted HTML snapshot",
            "Generate an HTML snapshot of a Milk Tea source file with syntax highlighting.",
            no_opts,
            Option[str].some(value= "INPUT.mt [OPTIONS]"),
        ),
        cli.command_spec(
            "completions",
            "Print a shell completion script",
            "Print a shell completion script for bash, zsh, or fish.",
            no_opts,
            Option[str].some(value= "bash|zsh|fish"),
        ),
        cli.command_spec(
            "version",
            "Print the compiler version",
            "Print the version of the Milk Tea compiler.",
            no_opts,
            Option[str].none,
        ),
    )

    let app = cli.app_spec(
        "mtc",
        "The Milk Tea compiler",
        app_opts,
        commands,
        Option[str].some(value= "<command> [options]"),
    )

    if args.len == 0:
        var help_args = array[str, 1]("--help")
        match cli.parse(app, help_args):
            Result.failure as payload:
                var error = payload.error
                defer error.release()
                return write_stderr_text(error.message.as_str())
            Result.success as parsed_payload:
                var help = cli.render_help(app)
                defer help.release()
                return write_stdout_text(help.as_str())

    match cli.parse(app, args):
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            return write_stderr_text(error.message.as_str())
        Result.success as parsed_payload:
            var parsed = parsed_payload.value
            defer parsed.release()

            if parsed.help_requested():
                return print_help(app, parsed.command())

            if parsed.command().is_none():
                var help = cli.render_help(app)
                defer help.release()
                return write_stdout_text(help.as_str())

            return dispatch(app, parsed)
