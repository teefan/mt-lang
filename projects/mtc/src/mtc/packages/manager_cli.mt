## `mtc deps` — the self-host port of
## `lib/milk_tea/packages/manager_cli.rb`: add, remove, update, tree, lock,
## publish and fetch, with the host's argument validation, output order and
## error text.

import std.fs as fs
import std.path as path_ops
import std.stdio as stdio
import std.str
import std.string as string
import std.terminal as terminal
import std.vec as vec

import mtc.cli_help as cli_help
import mtc.packages.editor as editor
import mtc.packages.graph as graph
import mtc.packages.lock as package_lock
import mtc.packages.manifest as manifest
import mtc.packages.registry as registry
import mtc.packages.source as pkg_source
import mtc.packages.version as version


function eprint(text: str) -> void:
    let _ = terminal.write_stderr(text)
    let _ = terminal.write_stderr("\n")


function print_help() -> void:
    let _ = cli_help.print_command_help("deps", true)


function fail_with_help(message: str) -> int:
    eprint(message)
    print_help()
    return 1


function fail_message(message: str) -> int:
    eprint(message)
    return 1


public function run(args: span[str]) -> int:
    if args.len < 2:
        return fail_with_help("missing deps subcommand")

    let subcommand = args[1]
    if subcommand.equal("add"):
        return deps_add(args)
    if subcommand.equal("remove"):
        return deps_remove(args)
    if subcommand.equal("update"):
        return deps_update(args)
    if subcommand.equal("tree"):
        return deps_tree(args)
    if subcommand.equal("lock"):
        return deps_lock(args)
    if subcommand.equal("publish"):
        return deps_publish(args)
    if subcommand.equal("fetch"):
        return deps_fetch_command(args)

    var message = string.String.from_str("unknown deps subcommand ")
    message.append(subcommand)
    let _ = fail_with_help(message.as_str())
    message.release()
    return 1


# =============================================================================
#  Path and option helpers
# =============================================================================

## `deps_target_path_from_argv!`: a leading operand wins when it names a path
## (`exists`, ends with package.toml, or contains a separator), else the
## current directory when it is a package root.
function target_path(args: span[str], index: ref[ptr_uint]) -> Result[string.String, string.String]:
    if unsafe: read(index) < args.len:
        let candidate = args[unsafe: read(index)]
        if not candidate.starts_with("-") and package_path_argument(candidate):
            unsafe: read(index) = read(index) + 1
            return Result[string.String, string.String].success(value = string.String.from_str(candidate))

    match fs.current_directory():
        Result.success as cwd_payload:
            var cwd = cwd_payload.value
            var manifest_path = path_ops.join(cwd.as_str(), "package.toml")
            let is_package = fs.is_file(manifest_path.as_str())
            manifest_path.release()
            if is_package:
                return Result[string.String, string.String].success(value = cwd)
            cwd.release()
        Result.failure as cwd_failure:
            var cwd_error = cwd_failure.error
            cwd_error.release()
    return Result[string.String, string.String].failure(error = string.String.from_str("missing package path"))


function package_path_argument(value: str) -> bool:
    if fs.exists(value):
        return true
    if value.ends_with("package.toml"):
        return true
    var i: ptr_uint = 0
    while i < value.len:
        if value.byte_at(i) == 47:
            return true
        i += 1
    return false


function unknown_option(message_prefix: str, option: str) -> int:
    var message = string.String.from_str(message_prefix)
    message.append(option)
    let result = fail_with_help(message.as_str())
    message.release()
    return result


# =============================================================================
#  tree
# =============================================================================

function deps_tree(args: span[str]) -> int:
    var index: ptr_uint = 2
    var path: string.String
    match target_path(args, ref_of(index)):
        Result.failure as path_failure:
            var message = path_failure.error
            let result = fail_with_help(message.as_str())
            message.release()
            return result
        Result.success as path_payload:
            path = path_payload.value
    defer: path.release()

    if index < args.len:
        return unknown_option("unknown deps option ", args[index])

    var resolver = pkg_source.create_resolver(pkg_source.ResolutionMode.materialize)
    defer: resolver.release()
    match graph.load(path.as_str(), ref_of(resolver)):
        Result.failure as load_failure:
            var message = load_failure.error
            let result = fail_message(message.as_str())
            message.release()
            return result
        Result.success as graph_payload:
            var package_graph = graph_payload.value
            defer: package_graph.release()
            var tree = graph.tree_text(ref_of(package_graph))
            defer: tree.release()
            stdio.print_line(tree.as_str())
    return 0


# =============================================================================
#  lock
# =============================================================================

function deps_lock(args: span[str]) -> int:
    var check_mode = false
    var path_value: Option[string.String] = Option[string.String].none
    var index: ptr_uint = 2
    while index < args.len:
        let arg = args[index]
        if arg.equal("--check"):
            check_mode = true
            index += 1
            continue
        if arg.starts_with("-"):
            return unknown_option("unknown deps option ", arg)
        if path_value.is_some():
            return unknown_option("unknown deps option ", arg)
        path_value = Option[string.String].some(value = string.String.from_str(arg))
        index += 1

    var path: string.String
    if path_value.is_some():
        let owned = path_value.unwrap()
        path = owned
    else:
        var cursor: ptr_uint = index
        match target_path(args, ref_of(cursor)):
            Result.failure as path_failure:
                var message = path_failure.error
                let result = fail_with_help(message.as_str())
                message.release()
                return result
            Result.success as path_payload:
                path = path_payload.value
    defer: path.release()

    var resolver = pkg_source.create_resolver(pkg_source.ResolutionMode.materialize)
    defer: resolver.release()
    if check_mode:
        match package_lock.check(path.as_str(), ref_of(resolver)):
            Result.failure as check_failure:
                var message = check_failure.error
                let result = fail_message(message.as_str())
                message.release()
                return result
            Result.success as check_payload:
                var result = check_payload.value
                defer: result.release()
                if result.current():
                    stdio.print_line(f"up to date #{result.lock_path.as_str()}")
                    return 0
                if result.missing():
                    stdio.print_line(f"missing #{result.lock_path.as_str()}")
                    return 1
                stdio.print_line(f"out of date #{result.lock_path.as_str()}")
                return 1
    else:
        match package_lock.write(path.as_str(), ref_of(resolver)):
            Result.failure as write_failure:
                var message = write_failure.error
                let result = fail_message(message.as_str())
                message.release()
                return result
            Result.success as write_payload:
                var lock_path = write_payload.value
                defer: lock_path.release()
                stdio.print_line(f"wrote #{lock_path.as_str()}")
                return 0
    return 0


# =============================================================================
#  publish
# =============================================================================

function deps_publish(args: span[str]) -> int:
    var upstream = false
    var path_value: Option[string.String] = Option[string.String].none
    var index: ptr_uint = 2
    while index < args.len:
        let arg = args[index]
        if arg.equal("--upstream"):
            upstream = true
            index += 1
            continue
        if arg.starts_with("-"):
            return unknown_option("unknown deps option ", arg)
        if path_value.is_some():
            return unknown_option("unknown deps option ", arg)
        path_value = Option[string.String].some(value = string.String.from_str(arg))
        index += 1

    var path: string.String
    if path_value.is_some():
        path = path_value.unwrap()
    else:
        var cursor: ptr_uint = index
        match target_path(args, ref_of(cursor)):
            Result.failure as path_failure:
                var message = path_failure.error
                let result = fail_with_help(message.as_str())
                message.release()
                return result
            Result.success as path_payload:
                path = path_payload.value
    defer: path.release()

    match registry.publish_default(path.as_str(), upstream):
        Result.failure as publish_failure:
            var message = publish_failure.error
            let result = fail_message(message.as_str())
            message.release()
            return result
        Result.success as publish_payload:
            var result = publish_payload.value
            defer: result.release()
            stdio.print_line(f"published #{result.package_name.as_str()}@#{result.version.as_str()} -> #{result.path.as_str()}")
    return 0


# =============================================================================
#  fetch
# =============================================================================

function deps_fetch_command(args: span[str]) -> int:
    # The host parses `fetch` operands/flags first (`-` options are errors even
    # before the path check), then falls back to the current package root.
    var index: ptr_uint = 2
    var path_value: Option[string.String] = Option[string.String].none
    while index < args.len:
        let arg = args[index]
        if arg.starts_with("-"):
            return unknown_option("unknown deps option ", arg)
        match path_value:
            Option.some:
                return unknown_option("unknown deps option ", arg)
            Option.none:
                path_value = Option[string.String].some(value = string.String.from_str(arg))
        index += 1

    var path: string.String
    match path_value:
        Option.some as provided:
            path = provided.value
        Option.none:
            match fs.current_directory():
                Result.success as cwd_payload:
                    var manifest_path = path_ops.join(cwd_payload.value.as_str(), "package.toml")
                    let is_package = fs.is_file(manifest_path.as_str())
                    manifest_path.release()
                    if is_package:
                        path = cwd_payload.value
                    else:
                        cwd_payload.value.release()
                        return fail_with_help("missing package path")
                Result.failure:
                    return fail_with_help("missing package path")
    defer: path.release()

    match fetch_locked(path.as_str()):
        Result.failure as fetch_failure:
            var message = fetch_failure.error
            let result = fail_message(message.as_str())
            message.release()
            return result
        Result.success:
            return 0
    return 0


## Materialize every cache-backed locked source and print the host's
## `kept`/`materialized` rows (or the no-sources line).
function fetch_locked(path: str) -> Result[bool, string.String]:
    var resolver = pkg_source.create_resolver(pkg_source.ResolutionMode.materialize)
    defer: resolver.release()

    var packages: vec.Vec[package_lock.LockedPackage]
    match package_lock.locked_packages(path, ref_of(resolver)):
        Result.failure as packages_failure:
            return Result[bool, string.String].failure(error = packages_failure.error)
        Result.success as packages_payload:
            packages = packages_payload.value
    defer: release_locked_packages(ref_of(packages))

    var printed = false
    var i: ptr_uint = 0
    while i < packages.len():
        let package_entry = packages.get(i) else:
            break
        var package = unsafe: read(package_entry)
        if not package.identity.cacheable():
            i += 1
            continue

        var expected_manifest: string.String
        match pkg_source.cache_manifest_path(resolver.cache_root.as_str(), package.identity):
            Result.failure as path_failure:
                return Result[bool, string.String].failure(error = path_failure.error)
            Result.success as path_payload:
                expected_manifest = path_payload.value
        defer: expected_manifest.release()
        if not package.manifest_path.as_str().equal(expected_manifest.as_str()):
            var message = string.String.from_str("package.lock manifest_path for ")
            message.append(package.package_name.as_str())
            message.append(" does not match the expected cache path ")
            message.append(expected_manifest.as_str())
            return Result[bool, string.String].failure(error = message)

        match pkg_source.materialize_identity(resolver.cache_root.as_str(), package.package_name.as_str(), ref_of(package.identity)):
            Result.failure as fetch_failure:
                return Result[bool, string.String].failure(error = fetch_failure.error)
            Result.success as fetch_payload:
                var result = fetch_payload.value
                defer: result.release()
                if result.present:
                    stdio.print_line(f"kept #{result.package_name.as_str()} -> #{result.path.as_str()}")
                else:
                    stdio.print_line(f"materialized #{result.package_name.as_str()} -> #{result.path.as_str()}")
                printed = true
        i += 1

    if not printed:
        var root_manifest = manifest.load(path)
        match root_manifest:
            Result.failure as manifest_failure:
                return Result[bool, string.String].failure(error = manifest_failure.error)
            Result.success as manifest_payload:
                var owned = manifest_payload.value
                var lock_path = path_ops.join(owned.root_dir.as_str(), "package.lock")
                defer: lock_path.release()
                owned.release()
                stdio.print_line(f"no cache-backed sources in #{lock_path.as_str()}")
    return Result[bool, string.String].success(value = true)


function release_locked_packages(packages: ref[vec.Vec[package_lock.LockedPackage]]) -> void:
    var i: ptr_uint = 0
    while i < packages.len():
        let package = packages.get(i) else:
            break
        unsafe: read(package).release()
        i += 1
    packages.release()


# =============================================================================
#  add
# =============================================================================

struct AddSpec:
    version_req: Option[string.String]
    path: Option[string.String]
    git: Option[string.String]
    rev: Option[string.String]
    subdir: Option[string.String]


function deps_add(args: span[str]) -> int:
    var index: ptr_uint = 2
    var path: string.String
    match target_path(args, ref_of(index)):
        Result.failure as path_failure:
            var message = path_failure.error
            let result = fail_message(message.as_str())
            message.release()
            return result
        Result.success as path_payload:
            path = path_payload.value
    defer: path.release()

    if index >= args.len:
        return fail_with_help("missing dependency name")
    let dependency_arg = args[index]
    index += 1

    var name: string.String
    var inline_requirement: Option[string.String] = Option[string.String].none
    match parse_dependency_argument(dependency_arg):
        Result.failure as parse_failure:
            var message = parse_failure.error
            let result = fail_with_help(message.as_str())
            message.release()
            return result
        Result.success as parsed:
            name = parsed.value.name
            inline_requirement = parsed.value.requirement
    defer: name.release()

    var spec: AddSpec
    match parse_add_spec(args, index, name.as_str(), inline_requirement):
        Result.failure as spec_failure:
            var message = spec_failure.error
            let result = fail_message(message.as_str())
            message.release()
            return result
        Result.success as spec_payload:
            spec = spec_payload.value
    defer: release_add_spec(ref_of(spec))

    var rendered = string.String.create()
    defer: rendered.release()
    render_add_spec(ref_of(rendered), ref_of(spec))

    var loaded: manifest.PackageManifest
    match manifest.load(path.as_str()):
        Result.failure as manifest_failure:
            var message = manifest_failure.error
            let result = fail_message(message.as_str())
            message.release()
            return result
        Result.success as manifest_payload:
            loaded = manifest_payload.value
    defer: loaded.release()

    var existing = false
    var i: ptr_uint = 0
    while i < loaded.dependencies.len():
        let dependency = loaded.dependencies.get(i) else:
            break
        if unsafe: read(dependency).name.as_str().equal(name.as_str()):
            existing = true
            break
        i += 1

    var manifest_path = string.String.from_str(loaded.manifest_path.as_str())
    defer: manifest_path.release()
    var original_manifest: string.String
    match fs.read_text(manifest_path.as_str()):
        Result.failure as read_failure:
            var read_error = read_failure.error
            let result = fail_message(read_error.message.as_str())
            read_error.release()
            return result
        Result.success as read_payload:
            original_manifest = read_payload.value
    defer: original_manifest.release()

    var lock_path = path_ops.join(loaded.root_dir.as_str(), "package.lock")
    defer: lock_path.release()
    var original_lock: Option[string.String] = Option[string.String].none
    if fs.is_file(lock_path.as_str()):
        match fs.read_text(lock_path.as_str()):
            Result.success as lock_payload:
                original_lock = Option[string.String].some(value = lock_payload.value)
            Result.failure:
                pass

    match editor.add_dependency(path.as_str(), name.as_str(), rendered.as_str()):
        Result.failure as edit_failure:
            var message = edit_failure.error
            let result = fail_message(message.as_str())
            message.release()
            release_option(ref_of(original_lock))
            return result
        Result.success as edit_payload:
            var updated = edit_payload.value
            updated.release()

    var resolver = pkg_source.create_resolver(pkg_source.ResolutionMode.materialize)
    defer: resolver.release()
    match package_lock.write(path.as_str(), ref_of(resolver)):
        Result.failure as write_failure:
            var message = write_failure.error
            rollback(manifest_path.as_str(), original_manifest.as_str(), lock_path.as_str(), ref_of(original_lock))
            let result = fail_message(message.as_str())
            message.release()
            return result
        Result.success as write_payload:
            var written = write_payload.value
            stdio.print_line(f"wrote #{written.as_str()}")
            written.release()

    match fetch_locked(path.as_str()):
        Result.failure as fetch_failure:
            var message = fetch_failure.error
            rollback(manifest_path.as_str(), original_manifest.as_str(), lock_path.as_str(), ref_of(original_lock))
            let result = fail_message(message.as_str())
            message.release()
            return result
        Result.success:
            pass
    release_option(ref_of(original_lock))

    if existing:
        stdio.print_line(f"updated #{name.as_str()} in #{manifest_path.as_str()}")
    else:
        stdio.print_line(f"added #{name.as_str()} in #{manifest_path.as_str()}")
    return 0


struct ParsedDependencyArgument:
    name: string.String
    requirement: Option[string.String]


function parse_dependency_argument(argument: str) -> Result[ParsedDependencyArgument, string.String]:
    var name_end = argument.len
    var i: ptr_uint = 0
    while i < argument.len:
        if argument.byte_at(i) == 64:
            name_end = i
            break
        i += 1
    let raw_name = argument.slice(0, name_end).trim_ascii_whitespace()
    if raw_name.len == 0:
        return Result[ParsedDependencyArgument, string.String].failure(
            error = string.String.from_str("dependency name cannot be empty")
        )
    var requirement: Option[string.String] = Option[string.String].none
    if name_end < argument.len:
        let raw_requirement = argument.slice(name_end + 1, argument.len - name_end - 1).trim_ascii_whitespace()
        if raw_requirement.len == 0:
            return Result[ParsedDependencyArgument, string.String].failure(
                error = string.String.from_str("dependency version requirement cannot be empty")
            )
        requirement = Option[string.String].some(value = string.String.from_str(raw_requirement))
    return Result[ParsedDependencyArgument, string.String].success(
        value = ParsedDependencyArgument(
            name = string.String.from_str(raw_name),
            requirement = requirement,
        )
    )


function parse_add_spec(
    args: span[str],
    start: ptr_uint,
    name: str,
    inline_requirement: Option[string.String],
) -> Result[AddSpec, string.String]:
    var spec = AddSpec(
        version_req = inline_requirement,
        path = Option[string.String].none,
        git = Option[string.String].none,
        rev = Option[string.String].none,
        subdir = Option[string.String].none,
    )
    var index = start
    while index < args.len:
        let arg = args[index]
        if arg.equal("--path"):
            match required_value(args, index):
                Result.failure as value_failure:
                    release_add_spec(ref_of(spec))
                    return Result[AddSpec, string.String].failure(error = value_failure.error)
                Result.success as value_payload:
                    release_option(ref_of(spec.path))
                    spec.path = Option[string.String].some(value = value_payload.value)
            index += 2
            continue
        if arg.equal("--git"):
            match required_value(args, index):
                Result.failure as value_failure:
                    release_add_spec(ref_of(spec))
                    return Result[AddSpec, string.String].failure(error = value_failure.error)
                Result.success as value_payload:
                    release_option(ref_of(spec.git))
                    spec.git = Option[string.String].some(value = value_payload.value)
            index += 2
            continue
        if arg.equal("--rev"):
            match required_value(args, index):
                Result.failure as value_failure:
                    release_add_spec(ref_of(spec))
                    return Result[AddSpec, string.String].failure(error = value_failure.error)
                Result.success as value_payload:
                    release_option(ref_of(spec.rev))
                    spec.rev = Option[string.String].some(value = value_payload.value)
            index += 2
            continue
        if arg.equal("--subdir"):
            match required_value(args, index):
                Result.failure as value_failure:
                    release_add_spec(ref_of(spec))
                    return Result[AddSpec, string.String].failure(error = value_failure.error)
                Result.success as value_payload:
                    release_option(ref_of(spec.subdir))
                    spec.subdir = Option[string.String].some(value = value_payload.value)
            index += 2
            continue
        if arg.equal("--version"):
            match required_value(args, index):
                Result.failure as value_failure:
                    release_add_spec(ref_of(spec))
                    return Result[AddSpec, string.String].failure(error = value_failure.error)
                Result.success as value_payload:
                    release_option(ref_of(spec.version_req))
                    spec.version_req = Option[string.String].some(value = value_payload.value)
            index += 2
            continue
        let result = unknown_option("unknown deps option ", arg)
        release_add_spec(ref_of(spec))
        var message = string.String.from_str("unknown deps option ")
        message.append(arg)
        return Result[AddSpec, string.String].failure(error = message)

    if spec.path.is_some() and spec.git.is_some():
        release_add_spec(ref_of(spec))
        var message = string.String.from_str("dependency ")
        message.append(name)
        message.append(" cannot use both --path and --git")
        return Result[AddSpec, string.String].failure(error = message)
    if spec.git.is_some():
        if spec.rev.is_none():
            release_add_spec(ref_of(spec))
            var message = string.String.from_str("dependency ")
            message.append(name)
            message.append(" is missing --rev")
            return Result[AddSpec, string.String].failure(error = message)
        if spec.version_req.is_some():
            release_add_spec(ref_of(spec))
            var message = string.String.from_str("dependency ")
            message.append(name)
            message.append(" cannot combine git resolution with a version requirement")
            return Result[AddSpec, string.String].failure(error = message)
        return Result[AddSpec, string.String].success(value = spec)
    if spec.path.is_some():
        let current = spec.version_req
        match normalize_requirement(current, name):
            Result.failure as req_failure:
                release_add_spec(ref_of(spec))
                return Result[AddSpec, string.String].failure(error = req_failure.error)
            Result.success as req_payload:
                release_option(ref_of(spec.version_req))
                spec.version_req = req_payload.value
        return Result[AddSpec, string.String].success(value = spec)
    if spec.version_req.is_none():
        release_add_spec(ref_of(spec))
        var message = string.String.from_str("dependency ")
        message.append(name)
        message.append(" is missing a version requirement")
        return Result[AddSpec, string.String].failure(error = message)
    let current = spec.version_req
    match normalize_requirement(current, name):
        Result.failure as req_failure:
            release_add_spec(ref_of(spec))
            return Result[AddSpec, string.String].failure(error = req_failure.error)
        Result.success as req_payload:
            release_option(ref_of(spec.version_req))
            spec.version_req = req_payload.value
    return Result[AddSpec, string.String].success(value = spec)


function required_value(args: span[str], index: ptr_uint) -> Result[string.String, string.String]:
    if index + 1 >= args.len:
        var message = string.String.from_str("missing value for ")
        message.append(args[index])
        return Result[string.String, string.String].failure(error = message)
    return Result[string.String, string.String].success(value = string.String.from_str(args[index + 1]))


## Replace the stripped requirement text with the exact version when the
## requirement has one arm (the host's `normalize_dependency_requirement_string`).
function normalize_requirement(value: Option[string.String], name: str) -> Result[Option[string.String], string.String]:
    match value:
        Option.none:
            return Result[Option[string.String], string.String].success(value = Option[string.String].none)
        Option.some as payload:
            var label = string.String.from_str("dependency ")
            label.append(name)
            label.append(" version requirement")
            defer: label.release()
            match version.parse_requirement(payload.value.as_str(), label.as_str()):
                Result.failure as req_failure:
                    return Result[Option[string.String], string.String].failure(error = req_failure.error)
                Result.success as req_payload:
                    var req = req_payload.value
                    defer: req.release()
                    if req.exact():
                        let exact = req.exact_version().expect("exact version")
                        var exact_text = exact.to_string()
                        return Result[Option[string.String], string.String].success(
                            value = Option[string.String].some(value = exact_text)
                        )
                    var copied = string.String.from_str(payload.value.as_str())
                    return Result[Option[string.String], string.String].success(
                        value = Option[string.String].some(value = copied)
                    )
    return Result[Option[string.String], string.String].success(value = Option[string.String].none)


function release_add_spec(spec: ref[AddSpec]) -> void:
    release_option(ref_of(spec.version_req))
    release_option(ref_of(spec.path))
    release_option(ref_of(spec.git))
    release_option(ref_of(spec.rev))
    release_option(ref_of(spec.subdir))


function release_option(value: ref[Option[string.String]]) -> void:
    match read(value):
        Option.some as payload:
            var owned = payload.value
            owned.release()
        Option.none:
            pass


function render_add_spec(output: ref[string.String], spec: ref[AddSpec]) -> void:
    match spec.git:
        Option.some as git_value:
            output.append("{ git = ")
            append_toml_string(output, git_value.value.as_str())
            match spec.rev:
                Option.some as rev_value:
                    output.append(", rev = ")
                    append_toml_string(output, rev_value.value.as_str())
                Option.none:
                    pass
            match spec.subdir:
                Option.some as subdir_value:
                    output.append(", subdir = ")
                    append_toml_string(output, subdir_value.value.as_str())
                Option.none:
                    pass
            output.append(" }")
            return
        Option.none:
            pass
    match spec.path:
        Option.some as path_value:
            output.append("{ path = ")
            append_toml_string(output, path_value.value.as_str())
            match spec.version_req:
                Option.some as version_value:
                    output.append(", version = ")
                    append_toml_string(output, version_value.value.as_str())
                Option.none:
                    pass
            output.append(" }")
            return
        Option.none:
            pass
    match spec.version_req:
        Option.some as version_value:
            append_toml_string(output, version_value.value.as_str())
        Option.none:
            pass


function append_toml_string(output: ref[string.String], value: str) -> void:
    output.push_byte('"')
    var i: ptr_uint = 0
    while i < value.len:
        let byte_value = value.byte_at(i)
        if byte_value == 92:
            output.append("\\\\")
        else if byte_value == 34:
            output.append("\\\"")
        else if byte_value == 10:
            output.append("\\n")
        else if byte_value == 13:
            output.append("\\r")
        else if byte_value == 9:
            output.append("\\t")
        else:
            output.push_byte(byte_value)
        i += 1
    output.push_byte('"')


function rollback(
    manifest_path: str,
    original_manifest: str,
    lock_path: str,
    original_lock: ref[Option[string.String]],
) -> void:
    let _ = fs.write_text(manifest_path, original_manifest)
    match read(original_lock):
        Option.some as payload:
            let _ = fs.write_text(lock_path, payload.value.as_str())
        Option.none:
            if fs.is_file(lock_path):
                let _ = fs.remove(lock_path)


# =============================================================================
#  remove
# =============================================================================

function deps_remove(args: span[str]) -> int:
    var index: ptr_uint = 2
    var path: string.String
    match target_path(args, ref_of(index)):
        Result.failure as path_failure:
            var message = path_failure.error
            let result = fail_message(message.as_str())
            message.release()
            return result
        Result.success as path_payload:
            path = path_payload.value
    defer: path.release()

    if index >= args.len:
        return fail_with_help("missing dependency name")
    let name = args[index]
    index += 1
    if index < args.len:
        return unknown_option("unknown deps option ", args[index])

    var loaded: manifest.PackageManifest
    match manifest.load(path.as_str()):
        Result.failure as manifest_failure:
            var message = manifest_failure.error
            let result = fail_message(message.as_str())
            message.release()
            return result
        Result.success as manifest_payload:
            loaded = manifest_payload.value
    defer: loaded.release()

    var manifest_path = string.String.from_str(loaded.manifest_path.as_str())
    defer: manifest_path.release()
    var original_manifest: string.String
    match fs.read_text(manifest_path.as_str()):
        Result.failure as read_failure:
            var read_error = read_failure.error
            let result = fail_message(read_error.message.as_str())
            read_error.release()
            return result
        Result.success as read_payload:
            original_manifest = read_payload.value
    defer: original_manifest.release()

    var lock_path = path_ops.join(loaded.root_dir.as_str(), "package.lock")
    defer: lock_path.release()
    var original_lock: Option[string.String] = Option[string.String].none
    if fs.is_file(lock_path.as_str()):
        match fs.read_text(lock_path.as_str()):
            Result.success as lock_payload:
                original_lock = Option[string.String].some(value = lock_payload.value)
            Result.failure:
                pass

    match editor.remove_dependency(path.as_str(), name):
        Result.failure as edit_failure:
            var message = edit_failure.error
            let result = fail_message(message.as_str())
            message.release()
            release_option(ref_of(original_lock))
            return result
        Result.success as edit_payload:
            var updated = edit_payload.value
            updated.release()

    var resolver = pkg_source.create_resolver(pkg_source.ResolutionMode.materialize)
    defer: resolver.release()
    match package_lock.write(path.as_str(), ref_of(resolver)):
        Result.failure as write_failure:
            var message = write_failure.error
            rollback(manifest_path.as_str(), original_manifest.as_str(), lock_path.as_str(), ref_of(original_lock))
            let result = fail_message(message.as_str())
            message.release()
            return result
        Result.success as write_payload:
            var written = write_payload.value
            stdio.print_line(f"wrote #{written.as_str()}")
            written.release()

    match fetch_locked(path.as_str()):
        Result.failure as fetch_failure:
            var message = fetch_failure.error
            rollback(manifest_path.as_str(), original_manifest.as_str(), lock_path.as_str(), ref_of(original_lock))
            let result = fail_message(message.as_str())
            message.release()
            return result
        Result.success:
            pass
    release_option(ref_of(original_lock))
    stdio.print_line(f"removed #{name} from #{manifest_path.as_str()}")
    return 0


# =============================================================================
#  update
# =============================================================================

function deps_update(args: span[str]) -> int:
    var index: ptr_uint = 2
    var path: string.String
    match target_path(args, ref_of(index)):
        Result.failure as path_failure:
            var message = path_failure.error
            let result = fail_message(message.as_str())
            message.release()
            return result
        Result.success as path_payload:
            path = path_payload.value
    defer: path.release()

    var names = vec.Vec[string.String].create()
    defer: pkg_source.release_strings(ref_of(names))
    while index < args.len:
        let arg = args[index]
        if arg.starts_with("-"):
            return unknown_option("unknown deps option ", arg)
        names.push(string.String.from_str(arg))
        index += 1

    var resolver = pkg_source.create_resolver(pkg_source.ResolutionMode.materialize)
    defer: resolver.release()
    if names.len() == 0:
        match package_lock.write(path.as_str(), ref_of(resolver)):
            Result.failure as write_failure:
                var message = write_failure.error
                let result = fail_message(message.as_str())
                message.release()
                return result
            Result.success as write_payload:
                var written = write_payload.value
                stdio.print_line(f"updated #{written.as_str()}")
                written.release()
        match fetch_locked(path.as_str()):
            Result.failure as fetch_failure:
                var message = fetch_failure.error
                let result = fail_message(message.as_str())
                message.release()
                return result
            Result.success:
                pass
        return 0

    return selective_update(path.as_str(), ref_of(names))


function selective_update(path: str, names: ref[vec.Vec[string.String]]) -> int:
    var cache_resolver = pkg_source.create_resolver(pkg_source.ResolutionMode.cache)
    defer: cache_resolver.release()
    match package_lock.check(path, ref_of(cache_resolver)):
        Result.failure as check_failure:
            var message = check_failure.error
            let result = fail_message(message.as_str())
            message.release()
            return result
        Result.success as check_payload:
            var check = check_payload.value
            defer: check.release()
            if not check.current():
                return fail_message(
                    "selective deps update requires a current package.lock that matches the current manifest; run `mtc deps lock <dir>` or `mtc deps update <dir>` first"
                )

    var loaded: manifest.PackageManifest
    match manifest.load(path):
        Result.failure as manifest_failure:
            var message = manifest_failure.error
            let result = fail_message(message.as_str())
            message.release()
            return result
        Result.success as manifest_payload:
            loaded = manifest_payload.value
    defer: loaded.release()

    var materialize_resolver = pkg_source.create_resolver(pkg_source.ResolutionMode.materialize)
    defer: materialize_resolver.release()
    var packages: vec.Vec[package_lock.LockedPackage]
    match package_lock.locked_packages(path, ref_of(materialize_resolver)):
        Result.failure as packages_failure:
            var message = packages_failure.error
            let result = fail_message(message.as_str())
            message.release()
            return result
        Result.success as packages_payload:
            packages = packages_payload.value
    defer: release_locked_packages(ref_of(packages))

    # Known names: manifest dependencies plus every locked package name.
    var known = vec.Vec[string.String].create()
    defer: pkg_source.release_strings(ref_of(known))
    var i: ptr_uint = 0
    while i < loaded.dependencies.len():
        let dependency = loaded.dependencies.get(i) else:
            break
        push_unique(ref_of(known), unsafe: read(dependency).name.as_str())
        i += 1
    i = 0
    while i < packages.len():
        let package = packages.get(i) else:
            break
        push_unique(ref_of(known), unsafe: read(package).package_name.as_str())
        i += 1

    i = 0
    while i < names.len():
        let requested = names.get(i) else:
            break
        let requested_text = unsafe: read(requested).as_str()
        if not contains_text(ref_of(known), requested_text):
            var message = string.String.from_str("cannot selectively update unknown package ")
            message.append(requested_text)
            message.append(" in ")
            message.append(loaded.manifest_path.as_str())
            let result = fail_message(message.as_str())
            message.release()
            return result
        i += 1

    # Selected instance ids: the requested packages plus their transitive
    # dependency closure.
    var selected = vec.Vec[string.String].create()
    defer: pkg_source.release_strings(ref_of(selected))
    var queue = vec.Vec[string.String].create()
    defer: pkg_source.release_strings(ref_of(queue))
    i = 0
    while i < packages.len():
        let package = packages.get(i) else:
            break
        let value = unsafe: read(package)
        if contains_text(names, value.package_name.as_str()):
            queue.push(string.String.from_str(value.instance_id.as_str()))
        i += 1
    while queue.len() > 0:
        let popped = queue.pop() else:
            break
        var current_id = popped
        defer: current_id.release()
        if contains_text(ref_of(selected), current_id.as_str()):
            continue
        selected.push(string.String.from_str(current_id.as_str()))
        match find_package(ref_of(packages), current_id.as_str()):
            Option.some as package_index:
                let dependency_package = packages.get(package_index.value) else:
                    continue
                var di: ptr_uint = 0
                while di < unsafe: read(dependency_package).dependency_ids.len():
                    let id_entry = unsafe: read(dependency_package).dependency_ids.get(di) else:
                        break
                    queue.push(string.String.from_str(unsafe: read(id_entry).as_str()))
                    di += 1
            Option.none:
                pass

    # Pin the registry versions of every dependency outside the selected set.
    var pinned = vec.Vec[pkg_source.ResolvedVersion].create()
    defer: pkg_source.release_resolved_versions(ref_of(pinned))
    i = 0
    while i < packages.len():
        let package_entry = packages.get(i) else:
            break
        let package = unsafe: read(package_entry)
        var parent_key: string.String
        match pkg_source.source_key_for_identity(package.identity):
            Result.failure:
                i += 1
                continue
            Result.success as key_payload:
                parent_key = key_payload.value
        var pi: ptr_uint = 0
        while pi < package.dependency_ids.len():
            let id_entry = package.dependency_ids.get(pi) else:
                break
            let dependency_id = unsafe: read(id_entry).as_str()
            if not contains_text(ref_of(selected), dependency_id):
                match find_package(ref_of(packages), dependency_id):
                    Option.some as dependency_index:
                        let dependency_entry = packages.get(dependency_index.value) else:
                            break
                        let dependency = unsafe: read(dependency_entry)
                        if dependency.identity.kind == pkg_source.SourceKind.registry_:
                            var key = pkg_source.registry_dependency_key(parent_key.as_str(), dependency.package_name.as_str())
                            pinned.push(pkg_source.ResolvedVersion(
                                key = key,
                                package_name = string.String.from_str(dependency.package_name.as_str()),
                                version = string.String.from_str(dependency.identity.registry_version.as_str()),
                            ))
                    Option.none:
                        pass
            pi += 1
        parent_key.release()
        i += 1

    var resolver = pkg_source.with_resolved_versions(ref_of(materialize_resolver), ref_of(pinned))
    defer: resolver.release()
    match package_lock.write(path, ref_of(resolver)):
        Result.failure as write_failure:
            var message = write_failure.error
            let result = fail_message(message.as_str())
            message.release()
            return result
        Result.success as write_payload:
            var written = write_payload.value
            stdio.print_line(f"updated #{written.as_str()}")
            written.release()
    match fetch_locked(path):
        Result.failure as fetch_failure:
            var message = fetch_failure.error
            let result = fail_message(message.as_str())
            message.release()
            return result
        Result.success:
            pass
    return 0


function find_package(packages: ref[vec.Vec[package_lock.LockedPackage]], instance_id: str) -> Option[ptr_uint]:
    var i: ptr_uint = 0
    while i < packages.len():
        let package = packages.get(i) else:
            return Option[ptr_uint].none
        if unsafe: read(package).instance_id.as_str().equal(instance_id):
            return Option[ptr_uint].some(value = i)
        i += 1
    return Option[ptr_uint].none


function push_unique(values: ref[vec.Vec[string.String]], candidate: str) -> void:
    if contains_text(values, candidate):
        return
    values.push(string.String.from_str(candidate))


function contains_text(values: ref[vec.Vec[string.String]], candidate: str) -> bool:
    var i: ptr_uint = 0
    while i < values.len():
        let entry = values.get(i) else:
            return false
        if unsafe: read(entry).as_str().equal(candidate):
            return true
        i += 1
    return false
