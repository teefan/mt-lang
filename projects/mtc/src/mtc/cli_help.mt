# Authored CLI help text.  The release version below is the single source of
# truth: `tools/release.sh` refuses a help banner that does not carry it.

import std.stdio as stdio
import std.terminal as terminal


## The CLI version string, printed by `mtc version`; `tools/release.sh` checks
## that the general help banner carries the same version.
public const VERSION: str = "0.6.1"


## Emit one line of a help block to stdout, or to stderr when `to_err`.
function emit_line(to_err: bool, text: str) -> void:
    if to_err:
        let _ = terminal.write_stderr(text)
        let _ = terminal.write_stderr("\n")
    else:
        stdio.print_line(text)


## The general help (`mtc`, `mtc help`, `mtc --help`).
public function print_help(to_err: bool) -> void:
    emit_line(to_err, "mtc 0.6.1 — the Milk Tea compiler")
    emit_line(to_err, "")
    emit_line(to_err, "Usage: mtc <command> [options]")
    emit_line(to_err, "")
    emit_line(to_err, "Commands:")
    emit_line(to_err, "  check        Type-check and lint source files")
    emit_line(to_err, "  build        Compile a source file or package")
    emit_line(to_err, "  run          Build and execute a program")
    emit_line(to_err, "  run-module   Resolve, build, and run a module by name")
    emit_line(to_err, "  test         Discover and run @[test] functions")
    emit_line(to_err, "  new          Scaffold a new package")
    emit_line(to_err, "  format       Format source files in place or check formatting")
    emit_line(to_err, "  lint         Lint source files and report warnings")
    emit_line(to_err, "  lex          Print the lexer token stream")
    emit_line(to_err, "  parse        Parse source and print the AST")
    emit_line(to_err, "  lower        Lower source to IR and print it")
    emit_line(to_err, "  emit-c       Compile source to C and print it")
    emit_line(to_err, "  debug        Print tokens, AST, facts, and diagnostics")
    emit_line(to_err, "  deps         Manage package dependencies")
    emit_line(to_err, "  toolchain    Manage the native toolchain")
    emit_line(to_err, "  bindgen      Generate a binding module from a C header")
    emit_line(to_err, "  cache        Inspect and manage the build cache")
    emit_line(to_err, "  docs         Serve the local documentation site")
    emit_line(to_err, "  std          List standard library modules and print their source")
    emit_line(to_err, "  snapshot     Render a highlighted HTML snapshot")
    emit_line(to_err, "  lsp          Start the Language Server Protocol server")
    emit_line(to_err, "  dap          Start the Debug Adapter Protocol server")
    emit_line(to_err, "  completions  Print a shell completion script")
    emit_line(to_err, "")
    emit_line(to_err, "Global options:")
    emit_line(to_err, "  -h, --help        Show this help (use `mtc help <command>` for command help)")
    emit_line(to_err, "  -V, --version     Print the compiler version")
    emit_line(to_err, "  -q, --quiet       Suppress informational output")
    emit_line(to_err, "  -v, --verbose     Print per-file progress")
    emit_line(to_err, "      --color WHEN  Colorize diagnostics: auto (default), always, never")
    emit_line(to_err, "")
    emit_line(to_err, "Run `mtc <command> --help` for detailed usage of a command.")
    emit_line(to_err, "")
    emit_line(to_err, "Usage: mtc lex PATH")
    emit_line(to_err, "       mtc parse PATH|DIR [PATH|DIR ...] [--locked] [--frozen] [-I PATH]")
    emit_line(to_err, "       mtc format PATH|DIR [PATH|DIR ...] [--check|--write] [--safe|--canonical|--preserve|--tidy] [--max-line-length N] [--timings]")
    emit_line(to_err, "       mtc lint PATH|DIR [--select RULES] [--ignore RULES] [--fix] [--ignore-generated] [--timings] [--locked] [--frozen] [-I PATH]")
    emit_line(to_err, "       mtc lint --init")
    emit_line(to_err, "       mtc check PATH|DIR [PATH|DIR ...] [--locked] [--frozen] [-Werror] [-I PATH]")
    emit_line(to_err, "       mtc debug PATH [--locked] [--frozen] [-I PATH]")
    emit_line(to_err, "       mtc lower PATH|DIR [PATH|DIR ...] [--locked] [--frozen] [-I PATH]")
    emit_line(to_err, "       mtc emit-c PATH|DIR [PATH|DIR ...] [--locked] [--frozen] [-I PATH]")
    emit_line(to_err, "       mtc build [PATH_OR_PACKAGE] [-o OUTPUT] [--cc COMPILER] [--keep-c C_PATH] [--profile debug|release] [--platform linux|windows|wasm] [--bundle] [--archive] [--locked] [--frozen] [--no-cache] [--debug-guards|--no-debug-guards] [--clean] [-I PATH]")
    emit_line(to_err, "       mtc new NAME")
    emit_line(to_err, "       mtc run [PATH_OR_PACKAGE] [-o OUTPUT] [--cc COMPILER] [--keep-c C_PATH] [--profile debug|release] [--platform linux|windows|wasm] [--locked] [--frozen] [-I PATH] [--debug-guards|--no-debug-guards]")
    emit_line(to_err, "       mtc test PATH|DIR [--cc COMPILER] [--profile debug|release] [--platform linux|windows|wasm] [--timeout SECONDS] [--mem MB] [--jobs N] [--sanitize] [-n SUBSTRING] [--format human|tap|junit] [--locked] [--frozen] [-I PATH]")
    emit_line(to_err, "       mtc run-module MODULE [--cc COMPILER] [--profile debug|release] [--platform linux|windows|wasm] [--locked] [--frozen] [-I PATH] [-- ARGS...]")
    emit_line(to_err, "       mtc toolchain bootstrap")
    emit_line(to_err, "       mtc toolchain doctor")
    emit_line(to_err, "       mtc toolchain tools")
    emit_line(to_err, "       mtc deps add [PATH_OR_PACKAGE] NAME[@VERSION_REQ] [--path PATH] [--git URL --rev REV [--subdir DIR]] [--version VERSION_REQ]")
    emit_line(to_err, "       mtc deps remove [PATH_OR_PACKAGE] NAME")
    emit_line(to_err, "       mtc deps update [PATH_OR_PACKAGE] [NAME ...]")
    emit_line(to_err, "       mtc deps tree [PATH_OR_PACKAGE]")
    emit_line(to_err, "       mtc deps lock [PATH_OR_PACKAGE] [--check]")
    emit_line(to_err, "       mtc deps publish [PATH_OR_PACKAGE] [--upstream]")
    emit_line(to_err, "       mtc deps fetch [PATH_OR_PACKAGE]")
    emit_line(to_err, "       mtc bindgen MODULE HEADER [-o OUTPUT] [--nullable-policy PATH] [--nullable-report PATH] [--link LIB] [--include HEADER] [--clang PATH] [--clang-arg ARG]")
    emit_line(to_err, "       mtc cache purge|status")
    emit_line(to_err, "       mtc docs [--open] [--port PORT]")
    emit_line(to_err, "       mtc std list [--json]")
    emit_line(to_err, "       mtc std show MODULE")
    emit_line(to_err, "       mtc snapshot INPUT.mt [--theme PATH] [-o OUTPUT]")
    emit_line(to_err, "       mtc lsp [--log-level LEVEL] [--stdio]")
    emit_line(to_err, "       mtc dap [--backend KIND] [--adapter-path PATH]")
    emit_line(to_err, "       mtc completions bash|zsh|fish")
    if to_err:
        let _ = terminal.flush_stderr()


## The usage block (unknown command, unsupported option).
public function print_usage(to_err: bool) -> void:
    emit_line(to_err, "Usage: mtc lex PATH")
    emit_line(to_err, "       mtc parse PATH|DIR [PATH|DIR ...] [--locked] [--frozen] [-I PATH]")
    emit_line(to_err, "       mtc format PATH|DIR [PATH|DIR ...] [--check|--write] [--safe|--canonical|--preserve|--tidy] [--max-line-length N] [--timings]")
    emit_line(to_err, "       mtc lint PATH|DIR [--select RULES] [--ignore RULES] [--fix] [--ignore-generated] [--timings] [--locked] [--frozen] [-I PATH]")
    emit_line(to_err, "       mtc lint --init")
    emit_line(to_err, "       mtc check PATH|DIR [PATH|DIR ...] [--locked] [--frozen] [-Werror] [-I PATH]")
    emit_line(to_err, "       mtc debug PATH [--locked] [--frozen] [-I PATH]")
    emit_line(to_err, "       mtc lower PATH|DIR [PATH|DIR ...] [--locked] [--frozen] [-I PATH]")
    emit_line(to_err, "       mtc emit-c PATH|DIR [PATH|DIR ...] [--locked] [--frozen] [-I PATH]")
    emit_line(to_err, "       mtc build [PATH_OR_PACKAGE] [-o OUTPUT] [--cc COMPILER] [--keep-c C_PATH] [--profile debug|release] [--platform linux|windows|wasm] [--bundle] [--archive] [--locked] [--frozen] [--no-cache] [--debug-guards|--no-debug-guards] [--clean] [-I PATH]")
    emit_line(to_err, "       mtc new NAME")
    emit_line(to_err, "       mtc run [PATH_OR_PACKAGE] [-o OUTPUT] [--cc COMPILER] [--keep-c C_PATH] [--profile debug|release] [--platform linux|windows|wasm] [--locked] [--frozen] [-I PATH] [--debug-guards|--no-debug-guards]")
    emit_line(to_err, "       mtc test PATH|DIR [--cc COMPILER] [--profile debug|release] [--platform linux|windows|wasm] [--timeout SECONDS] [--mem MB] [--jobs N] [--sanitize] [-n SUBSTRING] [--format human|tap|junit] [--locked] [--frozen] [-I PATH]")
    emit_line(to_err, "       mtc run-module MODULE [--cc COMPILER] [--profile debug|release] [--platform linux|windows|wasm] [--locked] [--frozen] [-I PATH] [-- ARGS...]")
    emit_line(to_err, "       mtc toolchain bootstrap")
    emit_line(to_err, "       mtc toolchain doctor")
    emit_line(to_err, "       mtc toolchain tools")
    emit_line(to_err, "       mtc deps add [PATH_OR_PACKAGE] NAME[@VERSION_REQ] [--path PATH] [--git URL --rev REV [--subdir DIR]] [--version VERSION_REQ]")
    emit_line(to_err, "       mtc deps remove [PATH_OR_PACKAGE] NAME")
    emit_line(to_err, "       mtc deps update [PATH_OR_PACKAGE] [NAME ...]")
    emit_line(to_err, "       mtc deps tree [PATH_OR_PACKAGE]")
    emit_line(to_err, "       mtc deps lock [PATH_OR_PACKAGE] [--check]")
    emit_line(to_err, "       mtc deps publish [PATH_OR_PACKAGE] [--upstream]")
    emit_line(to_err, "       mtc deps fetch [PATH_OR_PACKAGE]")
    emit_line(to_err, "       mtc bindgen MODULE HEADER [-o OUTPUT] [--nullable-policy PATH] [--nullable-report PATH] [--link LIB] [--include HEADER] [--clang PATH] [--clang-arg ARG]")
    emit_line(to_err, "       mtc cache purge|status")
    emit_line(to_err, "       mtc docs [--open] [--port PORT]")
    emit_line(to_err, "       mtc std list [--json]")
    emit_line(to_err, "       mtc std show MODULE")
    emit_line(to_err, "       mtc snapshot INPUT.mt [--theme PATH] [-o OUTPUT]")
    emit_line(to_err, "       mtc lsp [--log-level LEVEL] [--stdio]")
    emit_line(to_err, "       mtc dap [--backend KIND] [--adapter-path PATH]")
    emit_line(to_err, "       mtc completions bash|zsh|fish")
    if to_err:
        let _ = terminal.flush_stderr()


## Per-command help for the cli command family.
function print_cli_command_help(command: str, to_err: bool) -> bool:
    if command == "check":
        emit_line(to_err, "Usage: mtc check PATH|DIR [PATH|DIR ...] [--locked] [--frozen] [-Werror] [-I PATH]")
        emit_line(to_err, "")
        emit_line(to_err, "  Run semantic analysis on one or more source files and report errors.")
        emit_line(to_err, "")
        emit_line(to_err, "  Options:")
        emit_line(to_err, "    -Werror                     Treat warnings as errors.")
        emit_line(to_err, "    --locked / --frozen         Dependency resolution mode.")
        emit_line(to_err, "    -I, --include-path PATH     Add an extra module root.")
        if to_err:
            let _ = terminal.flush_stderr()
        return true
    if command == "build":
        emit_line(to_err, "Usage: mtc build [PATH_OR_PACKAGE] [OPTIONS]")
        emit_line(to_err, "")
        emit_line(to_err, "  Compile a source file or package. Defaults to current directory if a")
        emit_line(to_err, "  package.toml is present.")
        emit_line(to_err, "")
        emit_line(to_err, "  Options:")
        emit_line(to_err, "    -o, --output OUTPUT          Output path for the compiled artifact.")
        emit_line(to_err, "    --cc COMPILER                C compiler to use (default: $CC or cc).")
        emit_line(to_err, "    --keep-c C_PATH              Write the generated C source to this path.")
        emit_line(to_err, "    --profile PROFILE            debug (default) | release.")
        emit_line(to_err, "    --platform PLATFORM          linux (default) | windows | wasm.")
        emit_line(to_err, "    --bundle                     Package a native package build into a distributable directory.")
        emit_line(to_err, "    --archive                    Also write a .tar.gz archive for the native bundle (implies --bundle).")
        emit_line(to_err, "     --locked                     Resolve dependencies from package.lock.")
        emit_line(to_err, "     --frozen                     Require a current package.lock and use locked resolution.")
        emit_line(to_err, "     --no-cache                   Skip build cache, force rebuild from source.")
        emit_line(to_err, "     --debug-guards               Enable loop iteration and recursion guards (default: on in debug, off in release).")
        emit_line(to_err, "     --no-debug-guards            Disable loop iteration and recursion guards.")
        emit_line(to_err, "     --clean                      Remove existing build outputs and exit.")
        emit_line(to_err, "     -I, --include-path PATH      Add an extra module root.")
        if to_err:
            let _ = terminal.flush_stderr()
        return true
    if command == "run":
        emit_line(to_err, "Usage: mtc run [PATH_OR_PACKAGE] [OPTIONS]")
        emit_line(to_err, "")
        emit_line(to_err, "  Build and execute an executable target. For wasm targets this starts a")
        emit_line(to_err, "  local preview server, opens the generated HTML in your browser, and")
        emit_line(to_err, "  keeps serving until you press Ctrl-C.")
        emit_line(to_err, "  Defaults to current directory if a package.toml is present.")
        emit_line(to_err, "")
        emit_line(to_err, "  Options:")
        emit_line(to_err, "    -o, --output OUTPUT          Output path for the compiled binary.")
        emit_line(to_err, "    --cc COMPILER                C compiler to use (default: $CC or cc).")
        emit_line(to_err, "    --keep-c C_PATH              Write the generated C source to this path.")
        emit_line(to_err, "    --profile PROFILE            debug (default) | release.")
        emit_line(to_err, "    --platform PLATFORM          linux (default) | windows | wasm.")
        emit_line(to_err, "     --locked                     Resolve dependencies from package.lock.")
        emit_line(to_err, "     --frozen                     Require a current package.lock and use locked resolution.")
        emit_line(to_err, "     --no-cache                   Skip build cache, force rebuild from source.")
        emit_line(to_err, "     --debug-guards               Enable loop iteration and recursion guards (default: on in debug, off in release).")
        emit_line(to_err, "     --no-debug-guards            Disable loop iteration and recursion guards.")
        emit_line(to_err, "     -I, --include-path PATH      Add an extra module root.")
        if to_err:
            let _ = terminal.flush_stderr()
        return true
    if command == "run-module":
        emit_line(to_err, "Usage: mtc run-module MODULE [OPTIONS] [-- ARGS...]")
        emit_line(to_err, "")
        emit_line(to_err, "  Resolve a standard-library module by name, build it, and run it.")
        emit_line(to_err, "  Like `python -m module.name`, this finds the module in the module")
        emit_line(to_err, "  roots (e.g., std/http/server.mt for `http/server`), compiles it, and")
        emit_line(to_err, "  forwards remaining arguments to the program.")
        emit_line(to_err, "")
        emit_line(to_err, "  Module name can use / or . separators (e.g., http/server or http.server).")
        emit_line(to_err, "")
        emit_line(to_err, "  Options:")
        emit_line(to_err, "    --cc COMPILER                C compiler to use (default: $CC or cc).")
        emit_line(to_err, "    --profile PROFILE            debug (default) | release.")
        emit_line(to_err, "    --platform PLATFORM          linux (default) | windows | wasm.")
        emit_line(to_err, "    --locked                     Resolve dependencies from package.lock.")
        emit_line(to_err, "    --frozen                     Require a current package.lock and use locked resolution.")
        emit_line(to_err, "    -I, --include-path PATH      Add an extra module root.")
        emit_line(to_err, "")
        emit_line(to_err, "  Arguments after -- are forwarded to the module as-is.")
        if to_err:
            let _ = terminal.flush_stderr()
        return true
    return false


## Per-command help for the project command family.
function print_project_command_help(command: str, to_err: bool) -> bool:
    if command == "test":
        emit_line(to_err, "Usage: mtc test PATH|DIR [--cc COMPILER] [--profile debug|release] [--platform linux|windows|wasm] [--timeout SECONDS] [--mem MB] [--jobs N] [--sanitize] [-n SUBSTRING] [--format human|tap|junit] [--locked] [--frozen] [-I PATH]")
        emit_line(to_err, "")
        emit_line(to_err, "  Discover and run @[test] functions in a Milk Tea source file or directory.")
        emit_line(to_err, "")
        emit_line(to_err, "  Given a file, runs its @[test] functions. Given a directory (or a package")
        emit_line(to_err, "  root), recursively discovers every .mt file that contains @[test] functions,")
        emit_line(to_err, "  runs each as its own test binary, and prints an aggregate summary.")
        emit_line(to_err, "")
        emit_line(to_err, "  Functions annotated with @[test] must take no parameters and return void;")
        emit_line(to_err, "  a failing test aborts via the `assert`/`expect`/`expect_eq`/`expect_ne`")
        emit_line(to_err, "  intrinsics. `mtc test` synthesizes a runner that invokes each test in its")
        emit_line(to_err, "  own process (for isolation) and reports the results. A test file must not")
        emit_line(to_err, "  define `main`.")
        emit_line(to_err, "")
        emit_line(to_err, "  Each test binary runs under a wall-clock timeout and an address-space")
        emit_line(to_err, "  memory cap so a hanging or runaway test cannot stall or exhaust the host.")
        emit_line(to_err, "  Override them with --timeout SECONDS (default 30) and --mem MB (default 1024).")
        emit_line(to_err, "  For a directory, --jobs N builds and runs N files in parallel (default 1; output")
        emit_line(to_err, "  stays in file order).")
        emit_line(to_err, "  A file containing `# expect-error: <text>` is a compile-fail fixture: `mtc test`")
        emit_line(to_err, "  requires the compiler to reject it with a diagnostic containing that text.")
        emit_line(to_err, "  --sanitize builds test binaries with AddressSanitizer/UBSan (including leak")
        emit_line(to_err, "  detection); any sanitizer error fails the run.")
        emit_line(to_err, "  -n SUBSTRING runs only @[test] functions whose name contains SUBSTRING (and, in a")
        emit_line(to_err, "  directory, compile-fail fixtures whose filename matches).")
        emit_line(to_err, "  --format tap|junit emits machine-readable results (TAP / JUnit XML) instead of the")
        emit_line(to_err, "  human summary, for CI.")
        if to_err:
            let _ = terminal.flush_stderr()
        return true
    if command == "new":
        emit_line(to_err, "Usage: mtc new NAME")
        emit_line(to_err, "")
        emit_line(to_err, "  Create a new application package scaffold with package.toml and src/main.mt.")
        emit_line(to_err, "  NAME selects the target directory, and its basename is normalized to")
        emit_line(to_err, "  snake_case for package.name and the generated module declaration.")
        emit_line(to_err, "  The target may be a new directory or an existing empty directory.")
        if to_err:
            let _ = terminal.flush_stderr()
        return true
    if command == "format":
        emit_line(to_err, "Usage: mtc format PATH|DIR [PATH|DIR ...] [OPTIONS]")
        emit_line(to_err, "")
        emit_line(to_err, "  Format Milk Tea source files.")
        emit_line(to_err, "")
        emit_line(to_err, "  Options:")
        emit_line(to_err, "    --check          Report files that need formatting without writing them.")
        emit_line(to_err, "    --write, -w      Rewrite files in place.")
        emit_line(to_err, "    --safe           Format only unambiguous style changes (default).")
        emit_line(to_err, "    --canonical      Apply all canonical style normalisations.")
        emit_line(to_err, "    --preserve       Preserve existing formatting where possible.")
        emit_line(to_err, "    --tidy           Apply tidy formatting with line wrapping and blank-line normalization.")
        emit_line(to_err, "    --max-line-length N")
        emit_line(to_err, "                     Override the line length used by tidy mode.")
        emit_line(to_err, "    --timings        Print per-file format timing breakdown.")
        emit_line(to_err, "")
        emit_line(to_err, "  When formatting directories or multiple files, --check or --write is required.")
        if to_err:
            let _ = terminal.flush_stderr()
        return true
    return false


## Per-command help for the source command family.
function print_source_command_help(command: str, to_err: bool) -> bool:
    if command == "lint":
        emit_line(to_err, "Usage: mtc lint PATH|DIR [OPTIONS]")
        emit_line(to_err, "       mtc lint --init")
        emit_line(to_err, "")
        emit_line(to_err, "  Lint Milk Tea source files and report warnings.")
        emit_line(to_err, "  Some rules and auto-fixes are semantic/import-aware, so lint can use")
        emit_line(to_err, "  the same dependency resolution mode as check/build.")
        emit_line(to_err, "")
        emit_line(to_err, "  Options:")
        emit_line(to_err, "    --init                  Create a default .mt-lint.yml in the current directory.")
        emit_line(to_err, "    --select RULES          Comma-separated list of rule codes to enable.")
        emit_line(to_err, "    --ignore RULES          Comma-separated list of rule codes to suppress.")
        emit_line(to_err, "    --fix                   Apply auto-fixable changes in place.")
        emit_line(to_err, "    --ignore-generated      Skip files that start with '# generated by mtc'.")
        emit_line(to_err, "    --timings               Print lint timing: per-file summary and per-rule breakdown.")
        emit_line(to_err, "    --locked                Use package.lock for semantic dependency resolution.")
        emit_line(to_err, "    --frozen                Require a current package.lock before semantic dependency resolution.")
        emit_line(to_err, "    -I, --include-path PATH Add an extra module root for semantic resolution.")
        if to_err:
            let _ = terminal.flush_stderr()
        return true
    if command == "lex":
        emit_line(to_err, "Usage: mtc lex PATH")
        emit_line(to_err, "")
        emit_line(to_err, "  Tokenize a source file and print the token stream.")
        if to_err:
            let _ = terminal.flush_stderr()
        return true
    if command == "parse":
        emit_line(to_err, "Usage: mtc parse PATH|DIR [PATH|DIR ...] [--locked] [--frozen] [-I PATH]")
        emit_line(to_err, "")
        emit_line(to_err, "  Parse one or more source files and print the AST.")
        emit_line(to_err, "")
        emit_line(to_err, "  Options:")
        emit_line(to_err, "    --locked               Resolve dependencies from package.lock.")
        emit_line(to_err, "    --frozen               Require a current package.lock.")
        emit_line(to_err, "    -I, --include-path     Add an extra module root.")
        if to_err:
            let _ = terminal.flush_stderr()
        return true
    if command == "lower":
        emit_line(to_err, "Usage: mtc lower PATH|DIR [PATH|DIR ...] [--locked] [--frozen] [-I PATH]")
        emit_line(to_err, "")
        emit_line(to_err, "  Lower one or more source files to IR and print it.")
        if to_err:
            let _ = terminal.flush_stderr()
        return true
    if command == "emit-c":
        emit_line(to_err, "Usage: mtc emit-c PATH|DIR [PATH|DIR ...] [--locked] [--frozen] [-I PATH]")
        emit_line(to_err, "")
        emit_line(to_err, "  Compile one or more source files to C and print the output.")
        if to_err:
            let _ = terminal.flush_stderr()
        return true
    if command == "debug":
        emit_line(to_err, "Usage: mtc debug PATH [--locked] [--frozen] [-I PATH]")
        emit_line(to_err, "")
        emit_line(to_err, "  Print debug information for a source file: tokens, AST, semantic facts,")
        emit_line(to_err, "  binding resolution, and diagnostics.")
        if to_err:
            let _ = terminal.flush_stderr()
        return true
    return false


## Per-command help for the tooling command family.
function print_tooling_command_help(command: str, to_err: bool) -> bool:
    if command == "deps":
        emit_line(to_err, "Usage: mtc deps SUBCOMMAND")
        emit_line(to_err, "")
        emit_line(to_err, "  Manage package dependencies and package.lock state.")
        emit_line(to_err, "")
        emit_line(to_err, "  Subcommands:")
        emit_line(to_err, "    add          Add or update a package dependency and refresh package.lock.")
        emit_line(to_err, "    remove       Remove a package dependency and refresh package.lock.")
        emit_line(to_err, "    update       Re-resolve dependencies and refresh package.lock.")
        emit_line(to_err, "    tree         Print the package dependency tree for a local package.")
        emit_line(to_err, "    lock         Write or verify a deterministic package.lock for a local package.")
        emit_line(to_err, "    publish      Publish an exact-version package into the local or configured upstream registry store.")
        emit_line(to_err, "    fetch        Materialize cache-backed sources from package.lock explicitly.")
        if to_err:
            let _ = terminal.flush_stderr()
        return true
    if command == "toolchain":
        emit_line(to_err, "Usage: mtc toolchain SUBCOMMAND")
        emit_line(to_err, "")
        emit_line(to_err, "  Manage the local native toolchain and upstream native library checkouts.")
        emit_line(to_err, "")
        emit_line(to_err, "  Subcommands:")
        emit_line(to_err, "    bootstrap    Download and prepare all upstream native libraries.")
        emit_line(to_err, "    doctor       Check that all required tools and libraries are available.")
        emit_line(to_err, "    tools        Build vendored tool binaries (e.g. tracy-profiler).")
        if to_err:
            let _ = terminal.flush_stderr()
        return true
    if command == "bindgen":
        emit_line(to_err, "Usage: mtc bindgen MODULE HEADER [OPTIONS]")
        emit_line(to_err, "")
        emit_line(to_err, "  Generate a Milk Tea binding module from a C header.")
        emit_line(to_err, "")
        emit_line(to_err, "  Options:")
        emit_line(to_err, "    -o, --output OUTPUT    Write the generated module to this file.")
        emit_line(to_err, "    --nullable-policy PATH Apply a JSON nullable policy of symbols documented as returning NULL.")
        emit_line(to_err, "    --nullable-report PATH Write the remaining manual nullable policy report to this file.")
        emit_line(to_err, "    --link LIB             Link against this library (repeatable).")
        emit_line(to_err, "    --include HEADER       Extra #include directive (repeatable).")
        emit_line(to_err, "    --clang PATH           Clang binary to use (default: $CLANG or clang).")
        emit_line(to_err, "    --clang-arg ARG        Extra argument to pass to clang (repeatable).")
        if to_err:
            let _ = terminal.flush_stderr()
        return true
    if command == "cache":
        emit_line(to_err, "Usage: mtc cache SUBCOMMAND")
        emit_line(to_err, "")
        emit_line(to_err, "  Inspect and manage the build cache.")
        emit_line(to_err, "")
        emit_line(to_err, "  Subcommands:")
        emit_line(to_err, "    purge        Remove the entire build cache.")
        emit_line(to_err, "    status       Show cache directory, entry counts, and total size.")
        if to_err:
            let _ = terminal.flush_stderr()
        return true
    return false


## Per-command help for the server command family.
function print_server_command_help(command: str, to_err: bool) -> bool:
    if command == "docs":
        emit_line(to_err, "Usage: mtc docs [OPTIONS]")
        emit_line(to_err, "")
        emit_line(to_err, "  Start a local documentation server for Milk Tea with language reference")
        emit_line(to_err, "  and standard library exploration.")
        emit_line(to_err, "")
        emit_line(to_err, "  Options:")
        emit_line(to_err, "    --open, -o            Open the docs in your default browser.")
        emit_line(to_err, "    --port, -p PORT       Listen on a specific port (default: random).")
        if to_err:
            let _ = terminal.flush_stderr()
        return true
    if command == "std":
        emit_line(to_err, "Usage: mtc std list [--json]")
        emit_line(to_err, "       mtc std show MODULE")
        emit_line(to_err, "")
        emit_line(to_err, "  Inspect the Milk Tea standard library shipped in std/.")
        emit_line(to_err, "")
        emit_line(to_err, "  list    Print every hand-written standard library module with a short")
        emit_line(to_err, "          description and its path on disk, grouped by category.")
        emit_line(to_err, "          Generated binding modules (std/c/* and imported-binding")
        emit_line(to_err, "          wrappers such as raylib or zstd) are not listed.")
        emit_line(to_err, "  show    Print the source of a module. Accepts dotted or slashed names")
        emit_line(to_err, "          (mem.arena, mem/arena) and resolves platform variants such as")
        emit_line(to_err, "          fs to the active platform file. Generated modules stay")
        emit_line(to_err, "          viewable here (for example c.cjson or raylib).")
        emit_line(to_err, "")
        emit_line(to_err, "  Options:")
        emit_line(to_err, "    --json    Emit list output as JSON.")
        if to_err:
            let _ = terminal.flush_stderr()
        return true
    if command == "snapshot":
        emit_line(to_err, "Usage: mtc snapshot INPUT.mt [OPTIONS]")
        emit_line(to_err, "")
        emit_line(to_err, "  Generate an HTML snapshot of a Milk Tea source file with VS Code syntax")
        emit_line(to_err, "  highlighting using the active TextMate grammar and the configured theme.")
        emit_line(to_err, "")
        emit_line(to_err, "  Options:")
        emit_line(to_err, "    --theme, -t PATH      VS Code theme JSON file (default: 2026 Dark).")
        emit_line(to_err, "    --output, -o PATH     Write HTML to PATH instead of stdout.")
        if to_err:
            let _ = terminal.flush_stderr()
        return true
    if command == "lsp":
        emit_line(to_err, "Usage: mtc lsp [OPTIONS]")
        emit_line(to_err, "")
        emit_line(to_err, "  Start the Milk Tea Language Server. Reads JSON-RPC messages from stdin")
        emit_line(to_err, "  and writes responses to stdout. Stderr is reserved for logging.")
        emit_line(to_err, "")
        emit_line(to_err, "  Options:")
        emit_line(to_err, "    --log-level LEVEL     Log verbosity: trace, debug, info, warn, or")
        emit_line(to_err, "                          error (default: warn, set by extension).")
        emit_line(to_err, "    --stdio               Enable stdio transport (default).")
        if to_err:
            let _ = terminal.flush_stderr()
        return true
    if command == "dap":
        emit_line(to_err, "Usage: mtc dap [OPTIONS]")
        emit_line(to_err, "")
        emit_line(to_err, "  Start the Milk Tea Debug Adapter. Reads DAP messages from stdin")
        emit_line(to_err, "  and writes responses to stdout.")
        emit_line(to_err, "")
        emit_line(to_err, "  Options:")
        emit_line(to_err, "    --backend KIND        Debug backend kind (default: process).")
        emit_line(to_err, "    --adapter-path PATH   Path to an lldb-dap or cppdbg adapter")
        emit_line(to_err, "                          executable or adapter script.")
        if to_err:
            let _ = terminal.flush_stderr()
        return true
    if command == "completions":
        emit_line(to_err, "Usage: mtc completions bash|zsh|fish")
        emit_line(to_err, "")
        emit_line(to_err, "  Print a shell completion script to stdout. Source it (or install it into")
        emit_line(to_err, "  your shell's completion directory) to get tab-completion for mtc commands.")
        emit_line(to_err, "")
        emit_line(to_err, "  Examples:")
        emit_line(to_err, "    mtc completions bash > /etc/bash_completion.d/mtc")
        emit_line(to_err, "    mtc completions zsh  > ~/.zsh/completions/_mtc")
        emit_line(to_err, "    mtc completions fish > ~/.config/fish/completions/mtc.fish")
        if to_err:
            let _ = terminal.flush_stderr()
        return true
    return false


## The per-command help (`mtc help <command>`, `mtc <command> --help`).
## Returns false when the command has no help block.
public function print_command_help(command: str, to_err: bool) -> bool:
    if print_cli_command_help(command, to_err):
        return true
    if print_project_command_help(command, to_err):
        return true
    if print_source_command_help(command, to_err):
        return true
    if print_tooling_command_help(command, to_err):
        return true
    if print_server_command_help(command, to_err):
        return true
    return false
