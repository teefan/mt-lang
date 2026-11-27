## `mtc build`, `mtc run`, and `mtc run-module` — build the C artifact (with
## packages, bundles/archives, wasm, and the cache) and execute it.  Extracted
## from main.mt.

import std.asset_pack as asset_pack
import std.fs as fs
import std.libc as libc
import std.fmt as fmt_mod
import std.parse as parse_mod
import std.path as path_ops
import std.process as process
import std.str as str
import std.string as string
import std.stdio as stdio
import std.tar as tar
import std.terminal as terminal
import std.time as time
import std.vec as vec

import mtc.lowering.lowering as lowering
import mtc.loader.module_loader as loader
import mtc.semantic.analyzer as analyzer
import mtc.loader.package_manifest as package_manifest
import mtc.loader.path_resolver as resolver
import mtc.build as build_driver
import mtc.build_cache as build_cache
import mtc.ir_verify as ir_verify
import mtc.wasm_preview as wasm_preview
import mtc.cli_help as cli_help
import mtc.main.format_cli as format_cli
import mtc.main.test_cli as test_cli
import mtc.main.watch_cli as watch_cli
import mtc.main as main


## Which command's flag set is being parsed.  `build` also accepts `--clean`
## and `--kind`; `run` forwards everything after `--` to the program.
enum BuildCommandMode: ubyte
    build = 0
    run = 1


## Parsed `build`/`run` flags, shared by both commands.
struct BuildOptions:
    output_override: Option[str]
    keep_c_path: Option[str]
    c_compiler: str
    profile_name: str
    has_cli_profile: bool
    platform: resolver.Platform
    has_cli_platform: bool
    clean_mode: bool
    use_cache: bool
    sanitize: bool
    debug_guards: Option[bool]
    kind: build_driver.BuildKind
    bundle_mode: bool
    archive_mode: bool
    locked_flag: bool
    frozen_flag: bool
    strict_types: bool
    split: bool
    verify_ir: bool


## The post-load build inputs shared by the one-shot path and the watch fork.
## All strings are borrowed from the caller's owners, which outlive the build.
struct BuildRun:
    options: BuildOptions
    roots: span[str]
    package_opt: Option[package_manifest.PackageBuild]
    build_template: Option[str]
    build_assets: span[string.String]
    output_owner: str
    bundle_root: str
    display_path: str
    output_dir: str
    cache_enabled: bool
    cache_key: str


## Parse the shared `build`/`run` flag set into [[BuildOptions]], appending
## positionals to `filtered` (seeded with the command name) and, in run mode,
## everything after `--` to `program_args`.  Prints the same errors as the two
## former inline parsers and returns none on failure.
function parse_command_options(
    args: span[str],
    mode: BuildCommandMode,
    command_name: str,
    filtered: ref[vec.Vec[str]],
    program_args: ref[vec.Vec[str]],
) -> Option[BuildOptions]:
    var options = BuildOptions(
        output_override = Option[str].none,
        keep_c_path = Option[str].none,
        c_compiler = "cc",
        profile_name = "debug",
        has_cli_profile = false,
        platform = resolver.Platform.linux,
        has_cli_platform = false,
        clean_mode = false,
        use_cache = true,
        sanitize = false,
        debug_guards = Option[bool].none,
        kind = build_driver.BuildKind.executable,
        bundle_mode = false,
        archive_mode = false,
        locked_flag = false,
        frozen_flag = false,
        strict_types = false,
        split = false,
        verify_ir = false,
    )
    read(filtered).push(command_name)
    var ai: ptr_uint = 1
    while ai < args.len:
        let arg = args[ai]
        if mode == BuildCommandMode.run and arg == "--":
            var rest = ai + 1
            while rest < args.len:
                read(program_args).push(args[rest])
                rest += 1
            break
        if arg == "-o" or arg == "--output":
            if ai + 1 >= args.len:
                test_cli.eprint_missing_option_value(arg)
                return Option[BuildOptions].none
            options.output_override = Option[str].some(value= args[ai + 1])
            ai += 2
            continue
        if mode == BuildCommandMode.build and arg == "--clean":
            options.clean_mode = true
            ai += 1
            continue
        if arg == "--bundle":
            options.bundle_mode = true
            ai += 1
            continue
        if arg == "--archive":
            options.bundle_mode = true
            options.archive_mode = true
            ai += 1
            continue
        if mode == BuildCommandMode.build and arg == "--kind":
            if ai + 1 >= args.len:
                main.eprint_line("missing value for --kind")
                cli_help.print_usage(true)
                return Option[BuildOptions].none
            let kind_name = args[ai + 1]
            if kind_name == "executable" or kind_name == "exe" or kind_name == "bin":
                options.kind = build_driver.BuildKind.executable
                ai += 2
                continue
            if kind_name == "static" or kind_name == "staticlib":
                options.kind = build_driver.BuildKind.kind_static
                ai += 2
                continue
            if kind_name == "shared" or kind_name == "dylib" or kind_name == "dll" or kind_name == "so":
                options.kind = build_driver.BuildKind.kind_shared
                ai += 2
                continue
            var bad_kind = string.String.create()
            defer: bad_kind.release()
            bad_kind.append("unknown build kind ")
            bad_kind.append(kind_name)
            bad_kind.append("; expected executable|static|shared")
            main.eprint_line(bad_kind.as_str())
            cli_help.print_usage(true)
            return Option[BuildOptions].none
        if arg == "--keep-c":
            if ai + 1 >= args.len:
                test_cli.eprint_missing_option_value(arg)
                return Option[BuildOptions].none
            options.keep_c_path = Option[str].some(value= args[ai + 1])
            ai += 2
            continue
        if arg == "--cc":
            if ai + 1 >= args.len:
                main.eprint_line("missing value for --cc")
                cli_help.print_usage(true)
                return Option[BuildOptions].none
            options.c_compiler = args[ai + 1]
            ai += 2
            continue
        if arg == "--no-cache":
            options.use_cache = false
            ai += 1
            continue
        if arg == "-I" or arg == "--include-path":
            read(filtered).push(arg)
            if ai + 1 < args.len:
                read(filtered).push(args[ai + 1])
            ai += 2
            continue
        if arg == "--sanitize":
            options.sanitize = true
            options.use_cache = false
            ai += 1
            continue
        if arg == "--debug-guards":
            options.debug_guards = Option[bool].some(value = true)
            ai += 1
            continue
        if arg == "--no-debug-guards":
            options.debug_guards = Option[bool].some(value = false)
            ai += 1
            continue
        # Accepted for CLI compatibility; the Ruby build also ignores it.
        if arg == "--timings":
            ai += 1
            continue
        if arg == "--strict-types":
            options.strict_types = true
            ai += 1
            continue
        if arg == "--split":
            options.split = true
            ai += 1
            continue
        if arg == "--verify-ir":
            options.verify_ir = true
            ai += 1
            continue
        if arg == "--locked":
            options.locked_flag = true
            ai += 1
            continue
        if arg == "--frozen":
            options.locked_flag = true
            options.frozen_flag = true
            ai += 1
            continue
        if arg == "--profile":
            if ai + 1 >= args.len:
                test_cli.eprint_missing_option_value(arg)
                return Option[BuildOptions].none
            options.profile_name = args[ai + 1]
            if not options.profile_name == "debug" and not options.profile_name == "release":
                var bad_profile = string.String.create()
                defer: bad_profile.release()
                bad_profile.append("unknown profile ")
                bad_profile.append(options.profile_name)
                bad_profile.append("; expected debug|release")
                main.eprint_line(bad_profile.as_str())
                return Option[BuildOptions].none
            options.has_cli_profile = true
            ai += 2
            continue
        if arg == "--platform":
            if ai + 1 >= args.len:
                test_cli.eprint_missing_option_value(arg)
                return Option[BuildOptions].none
            match main.parse_platform_name(args[ai + 1]):
                Option.some as plat:
                    options.platform = plat.value
                Option.none:
                    return Option[BuildOptions].none
            options.has_cli_platform = true
            ai += 2
            continue
        if arg.starts_with("-"):
            var unknown_opt = string.String.create()
            defer: unknown_opt.release()
            unknown_opt.append("unknown build option ")
            unknown_opt.append(arg)
            main.eprint_line(unknown_opt.as_str())
            cli_help.print_usage(true)
            return Option[BuildOptions].none
        read(filtered).push(arg)
        ai += 1
    return Option[BuildOptions].some(value = options)


## Build a program (`mtc build`).  Supports both single `.mt` files and package
## directory targets (reads package.toml for the entry point).
public function build_command(args: span[str]) -> int:
    return build_command_impl(args, null)


## Build with an optional persistent module cache.  The watch command uses the
## cache for parse/analysis reuse; the one-shot command passes null.
function build_command_impl(args: span[str], watch_cache: ptr[loader.ModuleCache]?) -> int:
    var roots = vec.Vec[str].create()
    defer: roots.release()
    var owned_roots = vec.Vec[string.String].create()
    defer: owned_roots.release()
    var filtered = vec.Vec[str].create()
    defer: filtered.release()
    var program_args = vec.Vec[str].create()
    defer: program_args.release()
    var options = parse_command_options(
        args, BuildCommandMode.build, "build", ref_of(filtered), ref_of(program_args)
    ) else:
        return 1
    analyzer.set_strict_assignability(options.strict_types)
    let path = main.parse_source_operand(
        filtered.as_span(),
        ref_of(roots),
        ref_of(owned_roots),
        ref_of(options.platform)
    ) else:
        return 1

    if main.apply_package_resolution(
        path,
        options.locked_flag,
        options.frozen_flag,
        ref_of(roots),
        ref_of(owned_roots)
    ) != 0:
        return 1

    var entry_path_owner = string.String.create()
    defer: entry_path_owner.release()
    var source_root_owner = string.String.create()
    defer: source_root_owner.release()

    # Package manifest discovery: a directory operand uses its own manifest; a
    # source-file operand is a package build only when the manifest's entry is
    # that file (the host's `use_package_build_for?`).
    var package_opt = Option[package_manifest.PackageBuild].none
    var package_abs = loader.absolute_path(path)
    defer: package_abs.release()
    match package_manifest.load_package_for(package_abs.as_str()):
        Result.success as loaded:
            package_opt = loaded.value
        Result.failure as manifest_failure:
            let message = manifest_failure.error.as_str()
            main.eprint_line(message)
            manifest_failure.error.release()
            return 1
    defer: release_package_option(ref_of(package_opt))

    var build_template: Option[str] = Option[str].none
    var build_assets: span[string.String] = span[string.String]()
    match package_opt:
        Option.some as package_ref:
            let pkg = package_ref.value
            match pkg.html_template:
                Option.some as template:
                    build_template = Option[str].some(value = template.value.as_str())
                Option.none:
                    pass
            build_assets = pkg.assets.as_span()
        Option.none:
            pass

    var output_owner = string.String.create()
    defer: output_owner.release()
    var bundle_root = string.String.create()
    defer: bundle_root.release()
    var clean_target = string.String.create()
    defer: clean_target.release()
    let display_path = path

    let build_output = resolve_build_output(
        path, ref_of(options), package_opt, ref_of(roots), ref_of(entry_path_owner), ref_of(source_root_owner),
        ref_of(output_owner), ref_of(bundle_root), ref_of(clean_target)
    ) else:
        return 1
    let effective = build_output.effective

    # --clean removes the generated output artifact without compiling.
    if options.clean_mode:
        return run_build_clean(clean_target.as_str(), build_output.clean_target_is_tree)

    var program = if watch_cache != null:
        loader.check_program_with_source(
            effective, roots.as_span(), options.platform, "", false, watch_cache, null
        )
    else:
        loader.check_program(effective, roots.as_span(), options.platform)
    defer: program.release()

    let error_count = program.diagnostic_error_count()
    if error_count > 0 or (options.strict_types and program.diagnostic_warning_count() > 0):
        let _ = main.print_program_diagnostics(ref_of(program))
    if error_count > 0:
        return 1

    if main.reject_external_root(program):
        return 1

    let output_dir = path_ops.dirname(output_owner.as_str())
    match fs.create_directories(output_dir):
        Result.failure as dir_failure:
            var dir_error = dir_failure.error
            var message = string.String.create()
            defer: message.release()
            message.append("error: cannot create output directory ")
            message.append(output_dir)
            message.append(": ")
            message.append(dir_error.message.as_str())
            dir_error.release()
            main.eprint_line(message.as_str())
            return 1
        Result.success:
            pass

    # Binary cache: an unchanged program (same mtc executable, C compiler,
    # configuration, and module sources) reuses the previously built binary.
    # --keep-c always rebuilds so the saved C matches the produced binary.
    # Libraries are not cached (the cache materializes executables and its key
    # does not encode the artifact kind).  Asset staging and the bundle archive
    # are re-run on a hit, as the host's `build_cached` does.
    # The cache stores a single executable; emcc's `.js`/`.wasm`/`.data`
    # sidecars are not cached, so wasm builds always recompile.
    let cache_enabled = options.use_cache and not options.split and options.keep_c_path.is_none() and options.kind == build_driver.BuildKind.executable and options.platform != resolver.Platform.wasm
    var cache_key = string.String.create()
    defer: cache_key.release()
    if cache_enabled:
        var computed_key = compute_build_cache_key(ref_of(program), options)
        defer: computed_key.release()
        cache_key.append(computed_key.as_str())
        match try_cached_build(
            options, package_opt, output_owner.as_str(), display_path, bundle_root.as_str(), cache_key.as_str()
        ):
            Option.some as status:
                return status.value
            Option.none:
                pass

    let prepared = BuildRun(
        options = options,
        roots = roots.as_span(),
        package_opt = package_opt,
        build_template = build_template,
        build_assets = build_assets,
        output_owner = output_owner.as_str(),
        bundle_root = bundle_root.as_str(),
        display_path = display_path,
        output_dir = output_dir,
        cache_enabled = cache_enabled,
        cache_key = cache_key.as_str(),
    )
    if watch_cache == null:
        return finish_build(program, prepared)

    # The watch path keeps parse/analysis in this process and forks the
    # lowering/C/link phase.  The child's IR and compiler buffers die with it,
    # while this process retains the ModuleCache for the next edit.
    let _ = terminal.flush_stdout()
    let _ = terminal.flush_stderr()
    let child = libc.fork_process()
    if child < 0:
        main.eprint_line("error: fork failed")
        return 1
    if child == 0:
        let code = finish_build(program, prepared)
        let _ = terminal.flush_stdout()
        let _ = terminal.flush_stderr()
        libc.exit_process(code)
        return code
    var wait_status: int = 0
    let waited = libc.wait_process(child, ptr_of(wait_status), 0)
    if waited < 0:
        main.eprint_line("error: waitpid failed")
        return 1
    if wait_status == 0:
        return 0
    return 1


## The post-load half of a build.  The one-shot command calls it directly; the
## watch command calls it in a forked child so lowering/C/link allocations are
## released by process exit.
function finish_build(program: loader.Program, run: BuildRun) -> int:
    let lowering_outcome = lowering.lower_checked(program)
    if lowering_outcome.failed:
        lowering.print_lowering_error(lowering_outcome.error)
        return 1
    let ir_program = lowering_outcome.program
    if run.options.verify_ir:
        match ir_verify.verify(ir_program):
            Option.some as verification_error:
                main.eprint_line(verification_error.value.as_str())
                verification_error.value.release()
                return 1
            Option.none:
                pass

    if run.options.kind == build_driver.BuildKind.executable and main.reject_missing_entrypoint(program, ir_program):
        return 1

    match build_driver.build(
        program, ir_program, run.output_owner, run.options.c_compiler, run.roots, run.options.sanitize,
        run.options.profile_name, run.options.debug_guards, run.options.kind, run.options.platform, run.build_template, run.build_assets,
        run.options.keep_c_path, run.options.split, run.options.use_cache
    ):
        Result.success as built:
            var output = built.value
            defer: output.release()
            if run.cache_enabled:
                build_cache.store(run.cache_key, output.as_str())
            match stage_package_assets(run.package_opt, run.output_owner, run.options.bundle_mode, run.options.platform):
                Result.success:
                    pass
                Result.failure as asset_failure:
                    var asset_error = asset_failure.error
                    var message = string.String.create()
                    defer: message.release()
                    message.append("error: ")
                    message.append(asset_error.as_str())
                    asset_error.release()
                    main.eprint_line(message.as_str())
                    return 1
            var archive_owner = string.String.create()
            defer: archive_owner.release()
            if run.options.archive_mode:
                match write_bundle_archive(run.bundle_root, ref_of(archive_owner)):
                    Result.success:
                        pass
                    Result.failure as archive_failure:
                        var archive_error = archive_failure.error
                        var message = string.String.create()
                        defer: message.release()
                        message.append("error: ")
                        message.append(archive_error.as_str())
                        archive_error.release()
                        main.eprint_line(message.as_str())
                        return 1
            if not main.cli_is_quiet():
                if run.options.bundle_mode:
                    stdio.print_format(
                        c"built %.*s -> %.*s\n",
                        int<-(run.display_path.len), run.display_path.data,
                        int<-(run.output_dir.len), run.output_dir.data,
                    )
                    stdio.print_format(
                        c"entry executable %.*s\n",
                        int<-(run.output_owner.len), run.output_owner.data,
                    )
                    if run.options.archive_mode:
                        stdio.print_format(
                            c"archive %.*s\n",
                            int<-(archive_owner.as_str().len), archive_owner.as_str().data,
                        )
                else:
                    stdio.print_format(
                        c"built %.*s -> %.*s\n",
                        int<-(run.display_path.len), run.display_path.data,
                        int<-(run.output_owner.len), run.output_owner.data,
                    )
                if run.options.keep_c_path.is_some():
                    var saved_path = loader.absolute_path(run.options.keep_c_path.unwrap())
                    stdio.print_format(c"saved C to %.*s\n", int<-(saved_path.len), saved_path.data)
                    saved_path.release()
            return 0
        Result.failure as failure:
            var message = failure.error
            defer: message.release()
            let text = message.as_str()
            stdio.print_format(c"error: %.*s\n", int<-(text.len), text.data)
            return 1



## Print one policy-free status line for the watch cache.  Parse/analysis counts
## are the ModuleCache's verification counters: a leaf edit should move them,
## a no-op save should not re-parse.
function print_watch_cache(cache: ref[loader.ModuleCache]) -> void:
    if main.cli_is_quiet():
        return
    stdio.print_format(
        c"watch: cache parse=%zu analysis=%zu\n",
        cache.parse_count,
        cache.analysis_count
    )


## Build once through the shared command parser and the persistent cache.  The
## child build is forked inside build_command_impl; this process only parses,
## analyzes, and keeps the cache.
function watch_build_once(build_args: span[str], cache: ref[loader.ModuleCache]) -> bool:
    let status = build_command_impl(build_args, ptr_of(cache))
    loader.drain_retired_regions(ref_of(cache))
    print_watch_cache(cache)
    return status == 0


## Compile to a sibling temp path and atomically replace the final binary.  A
## user (or `--run`) can therefore never observe a partially written output.
function watch_build_atomic(
    build_args: span[str],
    cache: ref[loader.ModuleCache],
    temporary_output: str,
    final_output: str
) -> bool:
    match fs.remove(temporary_output):
        Result.success:
            pass
        Result.failure as removal:
            var error = removal.error
            error.release()
    if not watch_build_once(build_args, ref_of(cache)):
        return false
    match fs.rename(temporary_output, final_output):
        Result.success:
            return true
        Result.failure as rename_failure:
            var error = rename_failure.error
            var message = string.String.create()
            defer: message.release()
            message.append("watch: could not replace ")
            message.append(final_output)
            message.append(": ")
            message.append(error.message.as_str())
            error.release()
            stdio.print_line(message.as_str())
            return false


function run_watch_program(output: str) -> void:
    var command = vec.Vec[str].create()
    defer: command.release()
    command.push(output)
    match process.capture(command.as_span()):
        Result.failure as failure:
            var error = failure.error
            stdio.print_line("watch: could not launch program")
            error.release()
        Result.success as captured:
            var result = captured.value
            defer:
                result.stdout.release()
                result.stderr.release()
            let stdout_text = result.stdout.as_str()
            let stderr_text = result.stderr.as_str()
            if stdout_text.len > 0:
                stdio.print_format(c"%.*s", int<-stdout_text.len, stdout_text.data)
            if stderr_text.len > 0:
                stdio.print_format(c"%.*s", int<-stderr_text.len, stderr_text.data)


## `mtc watch PATH [--run] [--interval MS] [BUILD OPTIONS]`.
public function watch_command(args: span[str]) -> int:
    var start: ptr_uint = 0
    if args.len > 0 and args[0] == "watch":
        start = 1

    var source = string.String.create()
    defer: source.release()
    var build_args = vec.Vec[str].create()
    defer: build_args.release()
    build_args.push("build")
    var interval_ms: ptr_uint = 500
    var run_after_build = false
    var i: ptr_uint = start
    while i < args.len:
        let arg = args[i]
        if arg == "--interval":
            if i + 1 >= args.len:
                stdio.print_line("missing value for --interval")
                return 1
            let parsed = parse_mod.parse_int(args[i + 1], 10)
            if parsed <= 0:
                stdio.print_line("--interval must be a positive number of milliseconds")
                return 1
            interval_ms = ptr_uint<-parsed
            i += 2
            continue
        if arg == "--run":
            run_after_build = true
            i += 1
            continue
        if (
            arg == "-I" or arg == "--include-path"
            or arg == "-o" or arg == "--output"
            or arg == "--cc" or arg == "--profile"
            or arg == "--platform" or arg == "--keep-c"
        ) and i + 1 < args.len:
            build_args.push(arg)
            build_args.push(args[i + 1])
            i += 2
            continue
        if not arg.starts_with("-") and source.len() == 0:
            source.append(arg)
        build_args.push(arg)
        i += 1
    if source.len() == 0:
        cli_help.print_command_help("watch", true)
        return 1

    var output = string.String.create()
    defer: output.release()
    var has_output = false
    var bi: ptr_uint = 1
    while bi < build_args.len():
        let arg_ptr = build_args.get(bi) else:
            break
        let arg = unsafe: read(arg_ptr)
        if (arg == "-o" or arg == "--output") and bi + 1 < build_args.len():
            let value_ptr = build_args.get(bi + 1) else:
                break
            output.append(unsafe: read(value_ptr))
            has_output = true
            bi += 2
            continue
        bi += 1
    if not has_output:
        var stem_name = string.String.create()
        defer: stem_name.release()
        stem_name.append(path_ops.stem(source.as_str()))
        stem_name.append(".watch")
        var default_output = path_ops.join(path_ops.dirname(source.as_str()), stem_name.as_str())
        defer: default_output.release()
        output.append(default_output.as_str())
        build_args.push("-o")
        build_args.push(output.as_str())

    var temp_output = string.String.create()
    defer: temp_output.release()
    temp_output.append(output.as_str())
    temp_output.append(".watch-tmp")

    # Clone the build arguments with the output redirected to the temp path.
    # The child builds there; the parent renames atomically on success.
    var atomic_args = vec.Vec[str].create()
    defer: atomic_args.release()
    bi = 0
    while bi < build_args.len():
        let arg_ptr = build_args.get(bi) else:
            break
        let arg = unsafe: read(arg_ptr)
        atomic_args.push(arg)
        if (arg == "-o" or arg == "--output") and bi + 1 < build_args.len():
            atomic_args.push(temp_output.as_str())
            bi += 2
            continue
        bi += 1

    var roots = vec.Vec[string.String].create()
    defer:
        var ri: ptr_uint = 0
        while ri < roots.len():
            let root_ptr = roots.get(ri) else:
                break
            unsafe: read(root_ptr).release()
            ri += 1
        roots.release()
    roots.push(string.String.from_str(path_ops.dirname(source.as_str())))
    bi = 1
    while bi < build_args.len():
        let arg_ptr = build_args.get(bi) else:
            break
        let arg = unsafe: read(arg_ptr)
        if (arg == "-I" or arg == "--include-path") and bi + 1 < build_args.len():
            let value_ptr = build_args.get(bi + 1) else:
                break
            let include_path = unsafe: read(value_ptr)
            if not watch_cli.watch_roots_has(ref_of(roots), include_path):
                roots.push(string.String.from_str(include_path))
            bi += 2
            continue
        bi += 1

    var cache = loader.create_module_cache()
    defer: loader.release_module_cache(ref_of(cache))

    let build_ok = watch_build_atomic(atomic_args.as_span(), ref_of(cache), temp_output.as_str(), output.as_str())
    if build_ok and run_after_build:
        run_watch_program(output.as_str())

    var files = vec.Vec[watch_cli.WatchFile].create()
    defer: watch_cli.watch_file_release(ref_of(files))
    watch_cli.collect_watch_files(ref_of(roots), ref_of(files))
    stdio.print_format(
        c"watching %zu .mt file(s); interval %zu ms; output %.*s\n",
        files.len(),
        interval_ms,
        int<-output.as_str().len,
        output.as_str().data
    )
    let _ = terminal.flush_stdout()

    while true:
        let _ = time.sleep_milliseconds(interval_ms)
        var fresh = vec.Vec[watch_cli.WatchFile].create()
        watch_cli.collect_watch_files(ref_of(roots), ref_of(fresh))
        if not watch_cli.snapshots_differ(ref_of(files), ref_of(fresh)):
            watch_cli.watch_file_release(ref_of(fresh))
            continue
        watch_cli.watch_file_release(ref_of(files))
        files = fresh
        var dirty = true
        while dirty:
            stdio.print_line("change detected; rebuilding")
            let _ = terminal.flush_stdout()
            let ok = watch_build_atomic(atomic_args.as_span(), ref_of(cache), temp_output.as_str(), output.as_str())
            if ok and run_after_build:
                run_watch_program(output.as_str())
            var after = vec.Vec[watch_cli.WatchFile].create()
            watch_cli.collect_watch_files(ref_of(roots), ref_of(after))
            dirty = watch_cli.snapshots_differ(ref_of(files), ref_of(after))
            watch_cli.watch_file_release(ref_of(files))
            files = after
            if dirty:
                stdio.print_line("source changed during rebuild; rebuilding")
            let _ = terminal.flush_stdout()
    return 0



## Release the optional package manifest (its owned strings) at scope exit.
function release_package_option(option: ref[Option[package_manifest.PackageBuild]]) -> void:
    match read(option):
        Option.some as package:
            package.value.release()
        Option.none:
            pass


## The host's bundle path rules (`Build#initialize`): `-o` or the manifest
## output is the bundle root; otherwise `build/dist/<platform>/<profile>/<name>`.
## The entry executable is `<bundle_root>/<name><extension>`.
function resolve_bundle_paths(
    package: package_manifest.PackageBuild,
    output_override: Option[str],
    platform: resolver.Platform,
    profile_name: str,
    bundle_root: ref[string.String],
    entry_output: ref[string.String],
) -> void:
    match output_override:
        Option.some as explicit_root:
            bundle_root.append(explicit_root.value)
        Option.none:
            match package.output_path:
                Option.some as manifest_output:
                    bundle_root.append(manifest_output.value.as_str())
                Option.none:
                    var computed = path_ops.join(package.root_dir.as_str(), "build/dist")
                    defer: computed.release()
                    var with_platform = path_ops.join(computed.as_str(), main.platform_label(platform))
                    defer: with_platform.release()
                    var with_profile = path_ops.join(with_platform.as_str(), profile_name)
                    defer: with_profile.release()
                    var with_name = path_ops.join(with_profile.as_str(), package.name.as_str())
                    defer: with_name.release()
                    bundle_root.append(with_name.as_str())
    entry_output.append(bundle_root.as_str())
    entry_output.push_byte('/')
    entry_output.append(package.name.as_str())
    if platform == resolver.Platform.windows:
        entry_output.append(".exe")


## The host's `Build#artifact_extension`: `.html` for wasm, `.exe` for windows.
function artifact_extension(platform: resolver.Platform) -> str:
    if platform == resolver.Platform.wasm:
        return ".html"
    if platform == resolver.Platform.windows:
        return ".exe"
    return ""


## The host's `normalize_output_path` for a wasm target: `.html` is required,
## an extensionless path gets `.html`, any other extension is rejected.
function normalize_wasm_output_path(path: ref[string.String]) -> Result[bool, string.String]:
    if read(path).ends_with(".html"):
        return Result[bool, string.String].success(value = true)

    match path_ops.extension(read(path).as_str()):
        Option.some:
            var message = string.String.from_str("wasm output path must end with .html or omit the extension: ")
            message.append(read(path).as_str())
            return Result[bool, string.String].failure(error = message)
        Option.none:
            read(path).append(".html")
            return Result[bool, string.String].success(value = true)


## Stage the bundle's assets and, for `--archive`, its tarball.  The host's
## `Build.build` re-stages on a cache hit; `build` and `run` share this step.
function stage_run_bundle(
    package_opt: Option[package_manifest.PackageBuild],
    output_path: str,
    bundle_root: str,
    bundle_mode: bool,
    archive_mode: bool,
    platform: resolver.Platform,
) -> Result[bool, string.String]:
    if not bundle_mode:
        return Result[bool, string.String].success(value = true)

    match stage_package_assets(package_opt, output_path, true, platform):
        Result.failure as asset_failure:
            return Result[bool, string.String].failure(error = asset_failure.error)
        Result.success:
            pass

    if archive_mode:
        var archive_owner = string.String.create()
        defer: archive_owner.release()
        match write_bundle_archive(bundle_root, ref_of(archive_owner)):
            Result.failure as archive_failure:
                return Result[bool, string.String].failure(error = archive_failure.error)
            Result.success:
                pass

    return Result[bool, string.String].success(value = true)


function platform_from_manifest(label: str) -> resolver.Platform:
    if label == "windows":
        return resolver.Platform.windows
    if label == "wasm":
        return resolver.Platform.wasm
    return resolver.Platform.linux


function path_is_within(path: str, root: str) -> bool:
    if path.equal(root):
        return true
    if path.len <= root.len:
        return false
    if not path.slice(0, root.len).equal(root):
        return false
    return path.byte_at(root.len) == '/'


## Stage a package's `build.assets` beside the executable: packed into
## `assets.mtpack` in bundle mode, copied as-is otherwise (the host's
## `stage_runtime_assets`).
function stage_package_assets(
    option: Option[package_manifest.PackageBuild],
    output_path: str,
    bundle_mode: bool,
    platform: resolver.Platform,
) -> Result[bool, string.String]:
    # The host's `runtime_asset_mappings_for` is empty for wasm; emcc's
    # `--preload-file` packs the assets into the output `.data` instead.
    if platform == resolver.Platform.wasm:
        return Result[bool, string.String].success(value = true)

    match option:
        Option.none:
            return Result[bool, string.String].success(value = true)
        Option.some as package_ref:
            let package = package_ref.value
            if package.assets.len() == 0:
                return Result[bool, string.String].success(value = true)
            let output_dir = path_ops.dirname(output_path)
            if bundle_mode:
                var pack_path = path_ops.join(output_dir, "assets.mtpack")
                defer: pack_path.release()
                return asset_pack.write(pack_path.as_str(), package.assets.as_span())

            var i: ptr_uint = 0
            while i < package.assets.len():
                let asset_ptr = package.assets.get(i) else:
                    break
                let asset = unsafe: read(asset_ptr).as_str()
                var staged = path_ops.join(output_dir, path_ops.basename(asset))
                if staged.as_str().equal(asset):
                    staged.release()
                    i += 1
                    continue
                if fs.is_directory(asset) and path_is_within(staged.as_str(), asset):
                    var message = string.String.from_str("native runtime asset output would be written inside build.assets source tree: ")
                    message.append(staged.as_str())
                    staged.release()
                    return Result[bool, string.String].failure(error = message)
                if fs.exists(staged.as_str()):
                    match fs.remove_tree(staged.as_str()):
                        Result.failure as remove_failure:
                            var remove_error = remove_failure.error
                            var message = string.String.from_str(remove_error.message.as_str())
                            remove_error.release()
                            staged.release()
                            return Result[bool, string.String].failure(error = message)
                        Result.success:
                            pass
                match fs.copy_entry(asset, staged.as_str()):
                    Result.failure as copy_failure:
                        var copy_error = copy_failure.error
                        var message = string.String.from_str(copy_error.message.as_str())
                        copy_error.release()
                        staged.release()
                        return Result[bool, string.String].failure(error = message)
                    Result.success:
                        pass
                staged.release()
                i += 1
            return Result[bool, string.String].success(value = true)


## Write `<bundle_root>.tar.gz` (the host's `write_bundle_archive`).
function write_bundle_archive(bundle_root: str, archive_owner: ref[string.String]) -> Result[bool, string.String]:
    read(archive_owner).append(bundle_root)
    read(archive_owner).append(".tar.gz")
    match tar.archive_directory_gzip(bundle_root, path_ops.basename(bundle_root), true):
        Result.success as archive_payload:
            var data = archive_payload.value
            defer: data.release()
            match fs.write_bytes(read(archive_owner).as_str(), data.as_span()):
                Result.failure as write_failure:
                    var write_error = write_failure.error
                    var message = string.String.from_str("could not write archive: ")
                    message.append(write_error.message.as_str())
                    write_error.release()
                    return Result[bool, string.String].failure(error = message)
                Result.success:
                    return Result[bool, string.String].success(value = true)
        Result.failure as archive_failure:
            var archive_error = archive_failure.error
            var message = string.String.from_str(archive_error.message.as_str())
            archive_error.release()
            return Result[bool, string.String].failure(error = message)


## The resolved build destination: the effective source and what `--clean`
## removes.  The string owners stay in the caller.
struct BuildOutput:
    effective: str
    clean_target_is_tree: bool


## Resolve the effective source and the build/bundle/clean destinations.  A
## package manifest may override the CLI profile/platform and contribute the
## source root, so `options` is mutated through its ref.  Prints the same
## diagnostics as the former inline block and returns none on failure.
function resolve_build_output(
    path: str,
    options: ref[BuildOptions],
    package_opt: Option[package_manifest.PackageBuild],
    roots: ref[vec.Vec[str]],
    entry_path_owner: ref[string.String],
    source_root_owner: ref[string.String],
    output_owner: ref[string.String],
    bundle_root: ref[string.String],
    clean_target: ref[string.String],
) -> Option[BuildOutput]:
    var effective: str = ""
    var clean_target_is_tree = false

    match package_opt:
        Option.some as package_ref:
            let pkg = package_ref.value
            if (
                pkg.kind == package_manifest.PackageKind.library
                and read(options).kind == build_driver.BuildKind.executable
            ):
                var message = string.String.create()
                defer: message.release()
                message.append("cannot build library package ")
                message.append(pkg.name.as_str())
                message.append(" as an executable")
                main.eprint_line(message.as_str())
                return Option[BuildOutput].none
            match pkg.source_path:
                Option.some as declared_source:
                    effective = declared_source.value.as_str()
                Option.none:
                    var message = string.String.create()
                    defer: message.release()
                    message.append("application package ")
                    message.append(pkg.name.as_str())
                    message.append(" has no build entry; set build.entry or create src/main.mt")
                    main.eprint_line(message.as_str())
                    return Option[BuildOutput].none
            read(roots).push(pkg.source_root.as_str())
            if not read(options).has_cli_profile:
                read(options).profile_name = pkg.profile
            if not read(options).has_cli_platform:
                read(options).platform = platform_from_manifest(pkg.platform)
            let extension = artifact_extension(read(options).platform)
            if read(options).bundle_mode:
                if read(options).platform == resolver.Platform.wasm:
                    main.eprint_line("bundle mode is supported only for native package builds")
                    return Option[BuildOutput].none
                resolve_bundle_paths(
                    pkg, read(options).output_override, read(options).platform, read(options).profile_name, bundle_root,
                    output_owner
                )
                match read(options).output_override:
                    Option.some:
                        read(clean_target).append(read(bundle_root).as_str())
                        clean_target_is_tree = true
                    Option.none:
                        match pkg.output_path:
                            Option.some:
                                read(clean_target).append(read(bundle_root).as_str())
                                clean_target_is_tree = true
                            Option.none:
                                read(clean_target).append(pkg.root_dir.as_str())
                                read(clean_target).append("/build/dist")
                                clean_target_is_tree = true
            else:
                match read(options).output_override:
                    Option.some as explicit_output:
                        read(output_owner).append(explicit_output.value)
                        read(clean_target).append(explicit_output.value)
                    Option.none:
                        match pkg.output_path:
                            Option.some as manifest_output:
                                read(output_owner).append(manifest_output.value.as_str())
                                read(clean_target).append(manifest_output.value.as_str())
                            Option.none:
                                var computed = path_ops.join(pkg.root_dir.as_str(), "build/bin")
                                defer: computed.release()
                                var with_platform = path_ops.join(
                                    computed.as_str(),
                                    main.platform_label(read(options).platform)
                                )
                                defer: with_platform.release()
                                var with_profile = path_ops.join(with_platform.as_str(), read(options).profile_name)
                                defer: with_profile.release()
                                var with_name = path_ops.join(with_profile.as_str(), pkg.name.as_str())
                                defer: with_name.release()
                                read(output_owner).append(with_name.as_str())
                                read(output_owner).append(extension)
                                read(clean_target).append(pkg.root_dir.as_str())
                                read(clean_target).append("/build")
                                clean_target_is_tree = true
        Option.none:
            if read(options).bundle_mode:
                main.eprint_line("bundle mode requires a package build")
                return Option[BuildOutput].none
            let fallback = main.effective_source_path(path, roots, entry_path_owner, source_root_owner) else:
                return Option[BuildOutput].none
            effective = fallback
            match read(options).output_override:
                Option.some as explicit_output:
                    read(output_owner).append(explicit_output.value)
                    read(clean_target).append(explicit_output.value)
                Option.none:
                    var computed = format_cli.default_output_path(effective)
                    defer: computed.release()
                    read(output_owner).append(computed.as_str())
                    read(clean_target).append(computed.as_str())

    if read(options).platform == resolver.Platform.wasm:
        match normalize_wasm_output_path(output_owner):
            Result.failure as wasm_failure:
                let message = wasm_failure.error.as_str()
                main.eprint_line(message)
                wasm_failure.error.release()
                return Option[BuildOutput].none
            Result.success:
                pass

    if not fs.exists(effective):
        var missing = string.String.create()
        defer: missing.release()
        missing.append("source file not found: ")
        missing.append(path)
        main.eprint_line(missing.as_str())
        return Option[BuildOutput].none

    return Option[BuildOutput].some(value = BuildOutput(
        effective = effective,
        clean_target_is_tree = clean_target_is_tree,
    ))


## Remove the `--clean` target and report it unless quiet.
function run_build_clean(clean_target: str, is_tree: bool) -> int:
    if is_tree:
        if fs.exists(clean_target):
            match fs.remove_tree(clean_target):
                Result.failure as failure:
                    var message = failure.error
                    defer: message.release()
                    stdio.print_format(c"error: cannot remove %.*s\n", int<-(clean_target.len), clean_target.data)
                    return 1
                Result.success:
                    pass
    else if fs.exists(clean_target):
        match fs.remove(clean_target):
            Result.failure as failure:
                var message = failure.error
                defer: message.release()
                stdio.print_format(c"error: cannot remove %.*s\n", int<-(clean_target.len), clean_target.data)
                return 1
            Result.success:
                pass
    if not main.cli_is_quiet():
        stdio.print_format(c"cleaned %.*s\n", int<-(clean_target.len), clean_target.data)
    return 0


## Compute the binary-cache key, applying the manifest/CLI guard default.
function compute_build_cache_key(program: ref[loader.Program], options: BuildOptions) -> string.String:
    var build_guards = options.profile_name == "debug"
    match options.debug_guards:
        Option.some as override:
            build_guards = override.value
        Option.none:
            pass
    return build_cache.compute_key(
        program, options.c_compiler, main.platform_label(options.platform), options.profile_name, options.sanitize,
        build_guards
    )


## On a cache hit, materialize the binary, stage assets/archive, report, and
## return the command status.  None means the caller must build.
function try_cached_build(
    options: BuildOptions,
    package_opt: Option[package_manifest.PackageBuild],
    output_path: str,
    display_path: str,
    bundle_root: str,
    cache_key: str,
) -> Option[int]:
    match build_cache.lookup(cache_key):
        Option.some as hit:
            var cached = hit.value
            let copied = build_cache.materialize(cached.as_str(), output_path)
            cached.release()
            if copied:
                let output_dir = path_ops.dirname(output_path)
                match stage_package_assets(package_opt, output_path, options.bundle_mode, options.platform):
                    Result.success:
                        pass
                    Result.failure as asset_failure:
                        var asset_error = asset_failure.error
                        var message = string.String.create()
                        defer: message.release()
                        message.append("error: ")
                        message.append(asset_error.as_str())
                        asset_error.release()
                        main.eprint_line(message.as_str())
                        return Option[int].some(value = 1)
                var cached_archive = string.String.create()
                defer: cached_archive.release()
                if options.archive_mode:
                    match write_bundle_archive(bundle_root, ref_of(cached_archive)):
                        Result.success:
                            pass
                        Result.failure as archive_failure:
                            var archive_error = archive_failure.error
                            var message = string.String.create()
                            defer: message.release()
                            message.append("error: ")
                            message.append(archive_error.as_str())
                            archive_error.release()
                            main.eprint_line(message.as_str())
                            return Option[int].some(value = 1)
                if not main.cli_is_quiet():
                    if options.bundle_mode:
                        stdio.print_format(
                            c"built %.*s -> %.*s\n",
                            int<-(display_path.len), display_path.data,
                            int<-(output_dir.len), output_dir.data,
                        )
                        stdio.print_format(
                            c"entry executable %.*s\n",
                            int<-(output_path.len), output_path.data,
                        )
                        stdio.print_line("  [cached]")
                        if options.archive_mode:
                            stdio.print_format(
                                c"archive %.*s\n",
                                int<-(cached_archive.as_str().len), cached_archive.as_str().data,
                            )
                    else:
                        stdio.print_format(
                            c"built %.*s -> %.*s  [cached]\n",
                            int<-(display_path.len), display_path.data,
                            int<-(output_path.len), output_path.data,
                        )
                return Option[int].some(value = 0)
        Option.none:
            pass
    return Option[int].none


## Resolve the `run` output destination: the bundle entry, a wasm build beside
## the source/package, the explicit `-o`, or a unique temp path.  A wasm output
## is normalized to `.html`.  Returns false after printing a diagnostic.
function resolve_run_output(
    options: BuildOptions,
    package_opt: Option[package_manifest.PackageBuild],
    effective: str,
    bundle_root: ref[string.String],
    output_path: ref[string.String],
) -> bool:
    if options.bundle_mode:
        match package_opt:
            Option.some as package_ref:
                let pkg = package_ref.value
                if options.platform == resolver.Platform.wasm:
                    main.eprint_line("bundle mode is supported only for native package builds")
                    return false
                resolve_bundle_paths(
                    pkg, options.output_override, options.platform, options.profile_name, bundle_root, output_path
                )
            Option.none:
                main.eprint_line("bundle mode requires a package build")
                return false
    else if options.platform == resolver.Platform.wasm:
        # The host's wasm run builds beside the source/package (a temp binary
        # makes no sense for a previewable `.html` + sidecars).
        match options.output_override:
            Option.some as explicit:
                read(output_path).release()
                read(output_path) = string.String.from_str(explicit.value)
            Option.none:
                match package_opt:
                    Option.some as package_ref:
                        let pkg = package_ref.value
                        match pkg.output_path:
                            Option.some as manifest_output:
                                read(output_path).release()
                                read(output_path) = string.String.from_str(manifest_output.value.as_str())
                            Option.none:
                                read(output_path).release()
                                var computed = path_ops.join(pkg.root_dir.as_str(), "build/bin")
                                defer: computed.release()
                                var with_platform = path_ops.join(
                                    computed.as_str(),
                                    main.platform_label(options.platform)
                                )
                                defer: with_platform.release()
                                var with_profile = path_ops.join(with_platform.as_str(), options.profile_name)
                                defer: with_profile.release()
                                var with_name = path_ops.join(with_profile.as_str(), pkg.name.as_str())
                                defer: with_name.release()
                                read(output_path) = string.String.from_str(with_name.as_str())
                    Option.none:
                        var default_out = format_cli.default_output_path(effective)
                        defer: default_out.release()
                        read(output_path).release()
                        read(output_path) = string.String.from_str(default_out.as_str())
    else if options.output_override.is_some():
        read(output_path).release()
        read(output_path) = string.String.from_str(options.output_override.unwrap())
    else:
        # Ruby's `run` builds into a temporary directory; use a unique /tmp
        # path so running an example does not drop a binary next to its source
        # (and parallel runs stay independent).
        var default_out = format_cli.default_output_path(effective)
        defer: default_out.release()
        read(output_path).release()
        read(output_path) = string.String.from_str("/tmp/mtc_run_")
        read(output_path).append(path_ops.basename(default_out.as_str()))
        read(output_path).push_byte('_')
        fmt_mod.append_long(output_path, long<-time.now())

    if options.platform == resolver.Platform.wasm:
        match normalize_wasm_output_path(output_path):
            Result.failure as wasm_failure:
                let message = wasm_failure.error.as_str()
                main.eprint_line(message)
                wasm_failure.error.release()
                return false
            Result.success:
                pass
    return true


## On a run-cache hit, stage the bundle, execute the binary, and report the
## cached marker.  None means the caller must build.
function try_cached_run(
    options: BuildOptions,
    package_opt: Option[package_manifest.PackageBuild],
    output_path: str,
    bundle_root: str,
    cache_key: str,
    program_args: ref[vec.Vec[str]],
) -> Option[int]:
    match build_cache.lookup(cache_key):
        Option.some as hit:
            var cached = hit.value
            let copied = build_cache.materialize(cached.as_str(), output_path)
            cached.release()
            if copied:
                var cached_output = string.String.from_str(output_path)
                defer: cached_output.release()
                match stage_run_bundle(
                    package_opt, output_path, bundle_root, options.bundle_mode, options.archive_mode, options.platform
                ):
                    Result.success:
                        pass
                    Result.failure as bundle_failure:
                        var bundle_error = bundle_failure.error
                        let bundle_text = bundle_error.as_str()
                        stdio.print_format(c"error: %.*s\n", int<-(bundle_text.len), bundle_text.data)
                        bundle_error.release()
                        return Option[int].some(value = 1)
                let run_status = execute_binary(cached_output.as_str(), program_args)
                if not main.cli_is_quiet():
                    stdio.print_line("[cached]")
                return Option[int].some(value = run_status)
        Option.none:
            pass
    return Option[int].none


## Run a program (`mtc run`).  Builds and then executes the binary.
public function run_command(args: span[str]) -> int:
    var roots = vec.Vec[str].create()
    defer: roots.release()
    var owned_roots = vec.Vec[string.String].create()
    defer: owned_roots.release()
    var program_args = vec.Vec[str].create()
    defer: program_args.release()
    var filtered = vec.Vec[str].create()
    defer: filtered.release()
    var options = parse_command_options(
        args, BuildCommandMode.run, "run", ref_of(filtered), ref_of(program_args)
    ) else:
        return 1
    analyzer.set_strict_assignability(options.strict_types)
    let path = main.parse_source_operand(
        filtered.as_span(),
        ref_of(roots),
        ref_of(owned_roots),
        ref_of(options.platform)
    ) else:
        return 1
    if main.apply_package_resolution(
        path,
        options.locked_flag,
        options.frozen_flag,
        ref_of(roots),
        ref_of(owned_roots)
    ) != 0:
        return 1
    var entry_path_owner = string.String.create()
    defer: entry_path_owner.release()
    var source_root_owner = string.String.create()
    defer: source_root_owner.release()
    let effective = main.effective_source_path(
        path,
        ref_of(roots),
        ref_of(entry_path_owner),
        ref_of(source_root_owner)
    ) else:
        return 1
    if not fs.exists(effective):
        var missing_abs = loader.absolute_path(path)
        defer: missing_abs.release()
        var missing = string.String.create()
        defer: missing.release()
        missing.append("source file not found: ")
        missing.append(missing_abs.as_str())
        main.eprint_line(missing.as_str())
        return 1

    # `--bundle`/`--archive` are package builds (the host's
    # `validate_bundle_mode!`); load the manifest for the bundle root, assets,
    # and entry name.  A plain run does not need it.
    var package_opt = Option[package_manifest.PackageBuild].none
    defer: release_package_option(ref_of(package_opt))
    var package_abs = loader.absolute_path(path)
    defer: package_abs.release()
    match package_manifest.load_package_for(package_abs.as_str()):
        Result.success as loaded:
            package_opt = loaded.value
            match package_opt:
                Option.some as loaded_package:
                    let pkg = loaded_package.value
                    if not options.has_cli_profile:
                        options.profile_name = pkg.profile
                    if not options.has_cli_platform:
                        options.platform = platform_from_manifest(pkg.platform)
                Option.none:
                    pass
        Result.failure as manifest_failure:
            let message = manifest_failure.error.as_str()
            main.eprint_line(message)
            manifest_failure.error.release()
            return 1

    var run_template: Option[str] = Option[str].none
    var run_assets: span[string.String] = span[string.String]()
    match package_opt:
        Option.some as package_ref:
            let pkg = package_ref.value
            match pkg.html_template:
                Option.some as template:
                    run_template = Option[str].some(value = template.value.as_str())
                Option.none:
                    pass
            run_assets = pkg.assets.as_span()
        Option.none:
            pass

    var program = loader.check_program(effective, roots.as_span(), options.platform)
    defer: program.release()

    let error_count = program.diagnostic_error_count()
    if error_count > 0 or (options.strict_types and program.diagnostic_warning_count() > 0):
        let _ = main.print_program_diagnostics(ref_of(program))
    if error_count > 0:
        return 1

    if main.reject_external_root(program):
        return 1

    var bundle_root = string.String.create()
    defer: bundle_root.release()
    var output_path = string.String.create()
    defer: output_path.release()
    if not resolve_run_output(options, package_opt, effective, ref_of(bundle_root), ref_of(output_path)):
        return 1

    let output_dir = path_ops.dirname(output_path.as_str())
    match fs.create_directories(output_dir):
        Result.failure as dir_failure:
            var dir_error = dir_failure.error
            var message = string.String.create()
            defer: message.release()
            message.append("error: cannot create output directory ")
            message.append(output_dir)
            message.append(": ")
            message.append(dir_error.message.as_str())
            dir_error.release()
            main.eprint_line(message.as_str())
            return 1
        Result.success:
            pass

    # Binary cache: reuse the previously built binary when nothing changed.
    # --keep-c always rebuilds so the saved C matches the produced binary.
    let run_cache_enabled = options.use_cache and options.keep_c_path.is_none() and options.platform != resolver.Platform.wasm
    var cache_key = string.String.create()
    defer: cache_key.release()
    if run_cache_enabled:
        var computed_key = compute_build_cache_key(ref_of(program), options)
        defer: computed_key.release()
        cache_key.append(computed_key.as_str())
        match try_cached_run(
            options, package_opt, output_path.as_str(), bundle_root.as_str(), cache_key.as_str(), ref_of(program_args)
        ):
            Option.some as status:
                return status.value
            Option.none:
                pass

    let lowering_outcome = lowering.lower_checked(program)
    if lowering_outcome.failed:
        lowering.print_lowering_error(lowering_outcome.error)
        return 1
    let ir_program = lowering_outcome.program
    if options.verify_ir:
        match ir_verify.verify(ir_program):
            Option.some as verification_error:
                main.eprint_line(verification_error.value.as_str())
                verification_error.value.release()
                return 1
            Option.none:
                pass

    if main.reject_missing_entrypoint(program, ir_program):
        return 1

    match build_driver.build(
        program, ir_program, output_path.as_str(), options.c_compiler, roots.as_span(), options.sanitize,
        options.profile_name, options.debug_guards, build_driver.BuildKind.executable, options.platform,
        run_template, run_assets, options.keep_c_path, options.split, options.use_cache
    ):
        Result.success as built:
            var built_path = built.value
            defer: built_path.release()
            var owned_output = string.String.from_str(output_path.as_str())
            defer: owned_output.release()
            match stage_run_bundle(
                package_opt, owned_output.as_str(), bundle_root.as_str(), options.bundle_mode, options.archive_mode,
                options.platform
            ):
                Result.success:
                    pass
                Result.failure as bundle_failure:
                    var bundle_error = bundle_failure.error
                    let bundle_text = bundle_error.as_str()
                    stdio.print_format(c"error: %.*s\n", int<-(bundle_text.len), bundle_text.data)
                    bundle_error.release()
                    return 1
            if run_cache_enabled:
                build_cache.store(cache_key.as_str(), owned_output.as_str())
            if options.platform == resolver.Platform.wasm:
                var preview_dir = path_ops.dirname(owned_output.as_str())
                return wasm_preview.serve_preview(preview_dir, 0)
            return execute_binary(owned_output.as_str(), ref_of(program_args))
        Result.failure as failure:
            var message = failure.error
            defer: message.release()
            let text = message.as_str()
            stdio.print_format(c"error: %.*s\n", int<-(text.len), text.data)
            return 1


## Execute a built binary with the forwarded program arguments, streaming its
## captured stdout/stderr and returning the normalized exit code.
function execute_binary(binary_path: str, program_args: ref[vec.Vec[str]]) -> int:
    var cmd = vec.Vec[str].create()
    defer: cmd.release()
    cmd.push(binary_path)
    var pai: ptr_uint = 0
    while pai < program_args.len():
        let pa_ptr = program_args.get(pai) else:
            break
        unsafe:
            cmd.push(read(pa_ptr))
        pai += 1

    match process.capture(cmd.as_span()):
        Result.success as captured:
            var capture_result = captured.value
            defer: capture_result.release()
            let stdout_text_opt = capture_result.stdout_text()
            if stdout_text_opt.is_some():
                let stdout_text = stdout_text_opt.unwrap()
                stdio.print_format(c"%.*s", int<-(stdout_text.len), stdout_text.data)
            let stderr_text_opt = capture_result.stderr_text()
            if stderr_text_opt.is_some():
                let stderr_text = stderr_text_opt.unwrap()
                let _w = terminal.write_stderr(stderr_text)
            return capture_result.status.normalized_code()
        Result.failure:
            stdio.print_format(c"error: cannot execute '%.*s'\n", int<-(binary_path.len), binary_path.data)
            return 1


## Resolve, build, and run a module by name (`mtc run-module std.tool.x`).
## The module name maps to `<name with . as />.mt`, resolved against each
## module root as `<root>/std/<rel>` then `<root>/<rel>` — mirroring Ruby's
## resolve_app_module.  The resolved file then flows through the ordinary
## `run` path with all other arguments preserved.
public function run_module_command(args: span[str]) -> int:
    var module_name: Option[str] = Option[str].none
    var module_index: ptr_uint = 0
    var roots = vec.Vec[str].create()
    defer: roots.release()

    var ai: ptr_uint = 1
    var separator_index: ptr_uint = 0
    var has_separator = false
    while ai < args.len:
        let arg = args[ai]
        if arg == "--":
            # `parse_build_options` turns everything after `--` into positionals.
            if ai + 1 < args.len:
                module_name = Option[str].some(value = args[ai + 1])
                module_index = ai + 1
                separator_index = ai
                has_separator = true
            break
        if arg == "-I" or arg == "--include-path":
            if ai + 1 >= args.len:
                stdio.print_line("error: -I requires a directory")
                return 1
            roots.push(args[ai + 1])
            ai += 2
            continue
        if (
            arg == "-o"
            or arg == "--output"
            or arg == "--cc"
            or arg == "--profile"
            or arg == "--platform"
            or arg == "--keep-c"
        ):
            if ai + 1 >= args.len:
                test_cli.eprint_missing_option_value(arg)
                return 1
            ai += 2
            continue
        if arg == "--kind":
            if ai + 1 >= args.len:
                test_cli.eprint_missing_option_value(arg)
                return 1
            let kind_name = args[ai + 1]
            if not test_cli.is_known_build_kind(kind_name):
                var bad_kind = string.String.create()
                defer: bad_kind.release()
                bad_kind.append("unknown build kind ")
                bad_kind.append(kind_name)
                bad_kind.append("; expected executable|static|shared")
                main.eprint_line(bad_kind.as_str())
                cli_help.print_usage(true)
                return 1
            ai += 2
            continue
        if (
            arg == "--bundle"
            or arg == "--archive"
            or arg == "--locked"
            or arg == "--frozen"
            or arg == "--no-cache"
            or arg == "--timings"
            or arg == "--debug-guards"
            or arg == "--no-debug-guards"
        ):
            ai += 1
            continue
        if arg.starts_with("-"):
            var unknown_opt = string.String.create()
            defer: unknown_opt.release()
            unknown_opt.append("unknown build option ")
            unknown_opt.append(arg)
            main.eprint_line(unknown_opt.as_str())
            cli_help.print_usage(true)
            return 1
        module_name = Option[str].some(value = arg)
        module_index = ai
        break

    let name = module_name else:
        main.eprint_line("missing module name")
        cli_help.print_usage(true)
        return 1

    # Ambient roots: the current directory plus its enclosing project root.
    var cwd = string.String.create()
    var owned_roots = vec.Vec[string.String].create()
    defer: owned_roots.release()
    defer: cwd.release()
    match fs.current_directory():
        Result.success as dir_payload:
            cwd.release()
            cwd = dir_payload.value
        Result.failure as dir_failure:
            var dir_error = dir_failure.error
            dir_error.release()
    if cwd.len() > 0:
        roots.push(cwd.as_str())
        main.add_module_roots(cwd.as_str(), ref_of(roots), ref_of(owned_roots))

    var resolved = resolve_app_module(name, ref_of(roots)) else:
        var not_found = string.String.create()
        defer: not_found.release()
        not_found.append("run-module module not found: ")
        not_found.append(name)
        main.eprint_line(not_found.as_str())
        return 1
    defer: resolved.release()

    var run_args = vec.Vec[str].create()
    defer: run_args.release()
    run_args.push("run")
    var ri: ptr_uint = 1
    while ri < args.len:
        if has_separator and ri == separator_index:
            # `parse_build_options` drops the `--` itself.
            ri += 1
            continue
        if ri == module_index:
            run_args.push(resolved.as_str())
        else:
            run_args.push(args[ri])
        ri += 1
    return run_command(run_args.as_span())


## Resolve a module name (`a.b.c`) to a source file against the module roots,
## preferring `<root>/std/a/b/c.mt` over `<root>/a/b/c.mt`.
function resolve_app_module(name: str, roots: ref[vec.Vec[str]]) -> Option[string.String]:
    var relative = string.String.create()
    defer: relative.release()
    var ni: ptr_uint = 0
    while ni < name.len:
        let b = name.byte_at(ni)
        if b == '.':
            relative.push_byte('/')
        else:
            relative.push_byte(b)
        ni += 1
    relative.append(".mt")

    var i: ptr_uint = 0
    while i < roots.len():
        let root_ptr = roots.get(i) else:
            break
        let root = unsafe: read(root_ptr)
        var std_prefix = path_ops.join(root, "std")
        var std_candidate = path_ops.join(std_prefix.as_str(), relative.as_str())
        std_prefix.release()
        if fs.is_file(std_candidate.as_str()):
            return Option[string.String].some(value = std_candidate)
        std_candidate.release()
        var candidate = path_ops.join(root, relative.as_str())
        if fs.is_file(candidate.as_str()):
            return Option[string.String].some(value = candidate)
        candidate.release()
        i += 1
    return Option[string.String].none
