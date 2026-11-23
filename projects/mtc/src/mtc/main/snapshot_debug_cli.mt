## `mtc snapshot` and `mtc debug` — the highlighted HTML snapshot and the CLI
## debug-info dump.  Extracted from main.mt.

import std.fs as fs
import std.path as path_ops
import std.process as process
import std.str as str
import std.string as string
import std.stdio as stdio
import std.terminal as terminal
import std.vec as vec

import mtc.loader.module_loader as loader
import mtc.lsp.debug_info as debug_info
import mtc.lsp.workspace as workspace
import mtc.lsp.semantic_tokens as semtok
import mtc.cli_help as cli_help
import mtc.main as main


public function snapshot_command(args: span[str]) -> int:
    var input_path_opt: Option[str] = Option[str].none
    var theme_path_opt: Option[str] = Option[str].none
    var output_path_opt: Option[str] = Option[str].none
    var textmate_only = false
    var ai: ptr_uint = 1
    while ai < args.len:
        let arg = args[ai]
        if arg == "--theme" or arg == "-t":
            if ai + 1 >= args.len:
                main.eprint_line("snapshot: missing value for --theme")
                return 1
            theme_path_opt = Option[str].some(value = args[ai + 1])
            ai += 2
            continue
        if arg == "--output" or arg == "-o":
            if ai + 1 >= args.len:
                main.eprint_line("snapshot: missing value for --output")
                return 1
            output_path_opt = Option[str].some(value = args[ai + 1])
            ai += 2
            continue
        if arg == "--textmate-only":
            textmate_only = true
            ai += 1
            continue
        if arg.starts_with("-"):
            var unknown = string.String.create()
            defer: unknown.release()
            unknown.append("snapshot: unknown option ")
            unknown.append(arg)
            main.eprint_line(unknown.as_str())
            return 1
        if input_path_opt.is_some():
            var unexpected = string.String.create()
            defer: unexpected.release()
            unexpected.append("snapshot: unexpected argument ")
            unexpected.append(arg)
            main.eprint_line(unexpected.as_str())
            return 1
        input_path_opt = Option[str].some(value = arg)
        ai += 1

    let input_path = input_path_opt else:
        main.eprint_line("snapshot: missing source file path")
        cli_help.print_usage(true)
        return 1

    if not fs.is_file(input_path):
        var missing = string.String.create()
        defer: missing.release()
        missing.append("snapshot: source file not found: ")
        missing.append(input_path)
        main.eprint_line(missing.as_str())
        return 1

    var roots = vec.Vec[str].create()
    defer: roots.release()
    var owned_roots = vec.Vec[string.String].create()
    defer: owned_roots.release()
    main.add_module_roots(input_path, ref_of(roots), ref_of(owned_roots))

    var project_root: Option[str] = Option[str].none
    if roots.len() > 0:
        unsafe:
            let rp = roots.get(roots.len() - 1) else:
                fatal(c"snapshot root missing")
            project_root = Option[str].some(value = read(rp))

    let pr = if project_root.is_some(): project_root.unwrap() else: path_ops.dirname(input_path)

    var snapshot_js = path_ops.join(pr, "bindings/vscode/scripts/snapshot.js")
    defer: snapshot_js.release()
    if not fs.is_file(snapshot_js.as_str()):
        stdio.print_format(
            c"snapshot: internal script not found at %.*s\n",
            int<-(snapshot_js.as_str().len), snapshot_js.as_str().data,
        )
        return 1

    var resolved_theme = string.String.create()
    defer: resolved_theme.release()
    match theme_path_opt:
        Option.some as tp:
            resolved_theme.append(tp.value)
        Option.none:
            var default_theme = path_ops.join(pr, "bindings/vscode/themes/2026-dark.json")
            resolved_theme.append(default_theme.as_str())
            default_theme.release()

    # The host expands the theme path before checking it, so the message and
    # the `-t` argument carry the absolute path.
    var theme_abs = loader.absolute_path(resolved_theme.as_str())
    defer: theme_abs.release()
    if not fs.is_file(theme_abs.as_str()):
        var theme_missing = string.String.create()
        defer: theme_missing.release()
        theme_missing.append("snapshot: theme file not found: ")
        theme_missing.append(theme_abs.as_str())
        main.eprint_line(theme_missing.as_str())
        return 1

    var ws = workspace.Workspace.create(pr)
    defer: ws.release()
    var ri: ptr_uint = roots.len()
    while ri > 0:
        ri -= 1
        let root_ptr = roots.get(ri) else:
            break
        ws.module_roots.insert(0, string.String.from_str(unsafe: read(root_ptr)))

    var semantic_json_owned: Option[string.String] = Option[string.String].none
    var semantic_temp_path: Option[string.String] = Option[string.String].none
    if not textmate_only:
        match fs.read_text(input_path):
            Result.success as src_payload:
                var source = src_payload.value
                defer: source.release()
                var entries_json = semtok.snapshot_entries_for(ref_of(ws), input_path, source.as_str())
                if entries_json.len() > 2:
                    match fs.create_temporary_file_in_system_temp("mt_semantic_", ".json"):
                        Result.success as tmp_payload:
                            var tmp_path = tmp_payload.value
                            match fs.write_text(tmp_path.as_str(), entries_json.as_str()):
                                Result.success:
                                    semantic_json_owned = Option[string.String].some(value = entries_json)
                                    semantic_temp_path = Option[string.String].some(value = tmp_path)
                                Result.failure as write_err:
                                    write_err.error.release()
                                    tmp_path.release()
                                    entries_json.release()
                        Result.failure as tmp_err:
                            tmp_err.error.release()
                            entries_json.release()
                else:
                    entries_json.release()
            Result.failure:
                pass

    var node_cmd = vec.Vec[str].create()
    defer: node_cmd.release()
    node_cmd.push("node")
    node_cmd.push(snapshot_js.as_str())
    node_cmd.push(input_path)
    node_cmd.push("-t")
    node_cmd.push(theme_abs.as_str())
    match output_path_opt:
        Option.some as op:
            node_cmd.push("-o")
            node_cmd.push(op.value)
        Option.none:
            pass
    match semantic_temp_path:
        Option.some as sem_path:
            node_cmd.push("-s")
            node_cmd.push(sem_path.value.as_str())
        Option.none:
            pass

    var exit_code: int = 1
    match process.capture(node_cmd.as_span()):
        Result.success as captured:
            var result = captured.value
            defer: result.release()
            let stdout_opt = result.stdout_text()
            if stdout_opt.is_some():
                let stdout_text = stdout_opt.unwrap()
                if output_path_opt.is_none():
                    stdio.print_format(c"%.*s", int<-(stdout_text.len), stdout_text.data)
            let stderr_opt = result.stderr_text()
            if stderr_opt.is_some():
                let stderr_text = stderr_opt.unwrap()
                if stderr_text.len > 0:
                    let _w = terminal.write_stderr(stderr_text)
            exit_code = int<-(result.status.exit_code)
        Result.failure:
            stdio.print_line("snapshot: node execution failed")

    match semantic_temp_path:
        Option.some as tp:
            let _ = fs.remove(tp.value.as_str())
            tp.value.release()
        Option.none:
            pass
    match semantic_json_owned:
        Option.some as j:
            j.value.release()
        Option.none:
            pass

    return exit_code


public function debug_command(args: span[str]) -> int:
    var roots = vec.Vec[str].create()
    defer: roots.release()
    var owned_roots = vec.Vec[string.String].create()
    defer: owned_roots.release()
    var stripped = vec.Vec[str].create()
    defer: stripped.release()
    main.split_include_pairs(unsafe: span[str](data = args.data + 1, len = args.len - 1), ref_of(roots), ref_of(stripped))
    if stripped.is_empty():
        main.eprint_line("missing source file path")
        cli_help.print_usage(true)
        return 1

    var inputs = vec.Vec[str].create()
    defer: inputs.release()
    let resolution = main.extract_resolution_flags_span(stripped.as_span(), ref_of(inputs))
    if main.validate_source_operands("debug", inputs.as_span()) != 0:
        return 1

    var paths = vec.Vec[str].create()
    defer: paths.release()
    var expanded_owner = vec.Vec[string.String].create()
    defer: expanded_owner.release()
    main.expand_source_operands(inputs.as_span(), ref_of(paths), ref_of(expanded_owner))
    if paths.len() == 0:
        var label = main.operand_label(inputs.as_span())
        defer: label.release()
        var msg = string.String.create()
        defer: msg.release()
        msg.append("no .mt files found in ")
        msg.append(label.as_str())
        main.eprint_line(msg.as_str())
        return 1
    let path_ptr = paths.get(0) else:
        return 1
    let path = unsafe: read(path_ptr)

    if main.apply_package_resolution(path, resolution.locked, resolution.frozen, ref_of(roots), ref_of(owned_roots)) != 0:
        return 1

    var entry_path_owner = string.String.create()
    var source_root_owner = string.String.create()
    defer: entry_path_owner.release()
    defer: source_root_owner.release()
    let effective = main.effective_source_path(path, ref_of(roots), ref_of(entry_path_owner), ref_of(source_root_owner)) else:
        return 1
    if not fs.exists(effective):
        var missing = string.String.create()
        defer: missing.release()
        missing.append("source file not found: ")
        missing.append(path)
        main.eprint_line(missing.as_str())
        return 1

    var display_path = loader.absolute_path(effective)
    defer: display_path.release()

    var ws = workspace.Workspace.create(effective)
    defer: ws.release()
    var ri: ptr_uint = roots.len()
    while ri > 0:
        ri -= 1
        let rp = roots.get(ri) else:
            break
        ws.module_roots.insert(0, string.String.from_str(unsafe: read(rp)))

    var text = debug_info.build_cli_debug_text(ref_of(ws), effective, display_path.as_str())
    defer: text.release()
    stdio.print_line(text.as_str())
    return 0
