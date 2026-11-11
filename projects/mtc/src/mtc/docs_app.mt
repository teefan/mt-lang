## The `mtc docs` documentation server, mirroring
## `lib/milk_tea/tooling/cli/commands/docs.rb` + `docs_app.rb`: `/` and
## `/reference/` serve `docs/index.html`; `/stdlib` lists discovered modules;
## `/stdlib/:name` shows each file's doc comment and declarations;
## `/stdlib/:name/source/:file` serves raw source; `/hl` runs the VS Code
## snapshot script; `/api/search?q=` returns JSON; `/css`/`/js` serve the copied
## assets.  HTML is generated directly (no ERB) and is functionally, not
## byte-, equal to the host's.

import std.async as aio
import std.fmt as fmt
import std.fs as fs
import std.net as net
import std.path as path_ops
import std.process as process
import std.stdio as stdio
import std.str as text
import std.string as string
import std.terminal as terminal
import std.url as url
import std.vec as vec

import mtc.browser as browser
import mtc.http_util as http_util


struct DocModule:
    name: string.String
    path: string.String
    is_dir: bool


struct Declaration:
    kind: string.String
    name: string.String
    line: string.String
    doc: string.String
    has_doc: bool


extending DocModule:
    public editable function release() -> void:
        this.name.release()
        this.path.release()


extending Declaration:
    public editable function release() -> void:
        this.kind.release()
        this.name.release()
        this.line.release()
        this.doc.release()


function release_modules(values: ref[vec.Vec[DocModule]]) -> void:
    var index: ptr_uint = 0
    while index < values.len():
        let value = values.get(index) else:
            break
        unsafe:
            read(value).release()
        index += 1
    values.release()


function release_declarations(values: ref[vec.Vec[Declaration]]) -> void:
    var index: ptr_uint = 0
    while index < values.len():
        let value = values.get(index) else:
            break
        unsafe:
            read(value).release()
        index += 1
    values.release()


## `MilkTea.data_root`'s checkout lookup: the nearest ancestor of the running
## binary that contains `std/`.
public function repo_root() -> Option[string.String]:
    match fs.canonicalize("/proc/self/exe"):
        Result.success as exe_payload:
            var exe = exe_payload.value
            defer: exe.release()
            return fs.find_ancestor_containing(exe.as_str(), "std")
        Result.failure:
            return Option[string.String].none


public function serve(root_dir: str, preferred_port: int, open_flag: bool) -> int:
    return aio.with_runtime[int](
        proc(runtime: aio.Runtime) -> int: serve_with_runtime(runtime, root_dir, preferred_port, open_flag)
    )


function serve_with_runtime(
    runtime: aio.Runtime,
    root_dir: str,
    preferred_port: int,
    open_flag: bool,
) -> int:
    var address = net.ipv4("127.0.0.1", preferred_port) else:
        stdio.print_line("failed to resolve docs address")
        return 1
    defer: address.release()

    var listener = net.listen_on(runtime, address, 128) else:
        stdio.print_line("failed to listen for docs")
        return 1

    var bound = listener.local_address() else:
        stdio.print_line("failed to read docs address")
        listener.release()
        return 1
    defer: bound.release()

    let actual_port = bound.port() else:
        stdio.print_line("failed to read docs port")
        listener.release()
        return 1

    var url_text = string.String.create()
    defer: url_text.release()
    url_text.append("http://127.0.0.1:")
    var port_text = fmt.to_string_int(actual_port)
    defer: port_text.release()
    url_text.append(port_text.as_str())
    url_text.push_byte('/')

    stdio.print_format(c"Serving Milk Tea docs at %.*s\n", int<-(url_text.len), url_text.data)
    stdio.print_line("Press Ctrl+C to stop.")
    let _ = terminal.flush_stdout()
    if open_flag:
        browser.open(url_text.as_str())

    let state = http_util.create_state()
    unsafe:
        read(state).listener = ptr_of(listener)
    http_util.reset_stop()
    http_util.install_stop_signals(state)

    while not http_util.should_stop():
        let accepted = aio.wait_on(runtime, listener.accept())
        match accepted:
            Result.failure as failure:
                var error = failure.error
                error.release()
                break
            Result.success as stream:
                var connection = stream.value
                aio.run_on_proc(
                    runtime, proc() -> Task[void]: handle_connection(connection, root_dir)
                )
                connection.release()

    http_util.close_listener(state, ref_of(listener))
    return 0


async function handle_connection(connection: net.TcpStream, root_dir: str) -> void:
    var buffer = vec.Vec[ubyte].create()
    defer: buffer.release()

    var headers_done = false
    while not headers_done:
        match await connection.read_once(4096):
            Result.failure:
                return
            Result.success as chunk_result:
                var chunk = chunk_result.value
                if chunk.len == 0:
                    chunk.release()
                    return
                buffer.append_span(chunk.as_span())
                chunk.release()
                headers_done = http_util.has_header_end(buffer.as_span())
                if buffer.len() > 65536:
                    return

    let request_text = text.utf8_byte_span_as_str(buffer.as_span()) else:
        await http_util.send_text(connection, 400, "Bad Request", "bad request\n", false)
        return

    let first_line_end = http_util.find_byte(request_text, 10)
    if first_line_end >= request_text.len:
        await http_util.send_text(connection, 400, "Bad Request", "bad request\n", false)
        return

    var request_line = request_text.slice(0, first_line_end)
    if request_line.ends_with("\r"):
        request_line = request_line.slice(0, request_line.len - 1)

    let method_end = http_util.find_byte(request_line, 32)
    if method_end >= request_line.len:
        await http_util.send_text(connection, 400, "Bad Request", "bad request\n", false)
        return
    let method = request_line.slice(0, method_end)

    var target_start = method_end + 1
    while target_start < request_line.len and request_line.byte_at(target_start) == 32:
        target_start += 1
    let target_end = http_util.find_byte_from(request_line, 32, target_start)
    var target = request_line.slice(target_start, target_end - target_start)

    if not method.equal("GET") and not method.equal("HEAD"):
        await http_util.send_text(connection, 405, "Method Not Allowed", "method not allowed\n", false)
        return

    var path = target
    var query: str = ""
    let question = http_util.find_byte(target, 63)
    if question < target.len:
        path = target.slice(0, question)
        query = target.slice(question + 1, target.len - question - 1)

    let head_only = method.equal("HEAD")
    await dispatch(connection, root_dir, path, query, head_only)


async function dispatch(
    connection: net.TcpStream,
    root_dir: str,
    path: str,
    query: str,
    head_only: bool,
) -> void:
    if path.equal("/") or path.equal("/reference/"):
        await serve_reference(connection, root_dir, head_only)
        return
    if path.equal("/reference"):
        await http_util.send_redirect(connection, "/reference/")
        return
    if path.equal("/stdlib"):
        await serve_stdlib_index(connection, root_dir, head_only)
        return
    if path.equal("/api/search"):
        await serve_search(connection, root_dir, query)
        return
    if path.equal("/css/docs.css"):
        await serve_asset(connection, root_dir, "docs.css", "text/css; charset=utf-8", head_only)
        return
    if path.equal("/js/docs.js"):
        await serve_asset(connection, root_dir, "docs.js", "text/javascript; charset=utf-8", head_only)
        return

    if path.starts_with("/stdlib/"):
        let rest = path.slice(8, path.len - 8)
        let slash = http_util.find_byte(rest, 47)
        if slash >= rest.len:
            var name = url.percent_decode(rest) else:
                await not_found(connection, head_only)
                return
            defer: name.release()
            await serve_module(connection, root_dir, name.as_str(), head_only)
            return

        let module_name_raw = rest.slice(0, slash)
        var module_name = url.percent_decode(module_name_raw) else:
            await not_found(connection, head_only)
            return
        defer: module_name.release()

        let tail = rest.slice(slash + 1, rest.len - slash - 1)
        if not tail.starts_with("source/"):
            await not_found(connection, head_only)
            return
        let file_part = tail.slice(7, tail.len - 7)
        var highlighted = false
        var file_name_raw = file_part
        if file_part.ends_with("/hl"):
            highlighted = true
            file_name_raw = file_part.slice(0, file_part.len - 3)
        var file_name = url.percent_decode(file_name_raw) else:
            await not_found(connection, head_only)
            return
        defer: file_name.release()

        await serve_source(
            connection, root_dir, module_name.as_str(), file_name.as_str(), highlighted, head_only
        )
        return

    await not_found(connection, head_only)


async function serve_reference(connection: net.TcpStream, root_dir: str, head_only: bool) -> void:
    var path = path_ops.join(root_dir, "docs/index.html")
    defer: path.release()
    await serve_file(connection, path.as_str(), "text/html; charset=utf-8", head_only)


async function serve_asset(
    connection: net.TcpStream,
    root_dir: str,
    name: str,
    content_type: str,
    head_only: bool,
) -> void:
    var path = path_ops.join(root_dir, "projects/mtc/src/mtc/docs_public")
    var full = path_ops.join(path.as_str(), name)
    path.release()
    defer: full.release()
    await serve_file(connection, full.as_str(), content_type, head_only)


async function serve_file(
    connection: net.TcpStream,
    path: str,
    content_type: str,
    head_only: bool,
) -> void:
    match fs.read_bytes(path):
        Result.failure:
            await not_found(connection, head_only)
        Result.success as payload:
            var body = payload.value
            defer: body.release()
            await http_util.send_response(connection, 200, "OK", content_type, body.as_span(), head_only)


async function not_found(connection: net.TcpStream, head_only: bool) -> void:
    var body = page(
        "Not Found",
        "<div class=\"hero\" style=\"text-align:center\"><h1 style=\"font-size:4rem\">404</h1>" +
        "<p class=\"tagline\">Page not found.</p><p><a href=\"/\">Back to documentation</a></p></div>"
    )
    defer: body.release()
    await http_util.send_response(
        connection, 404, "Not Found", "text/html; charset=utf-8", text.as_byte_span(body.as_str()), head_only
    )


async function serve_stdlib_index(connection: net.TcpStream, root_dir: str, head_only: bool) -> void:
    var mods = discover_modules(root_dir)
    defer: release_modules(ref_of(mods))

    var rows = string.String.create()
    defer: rows.release()
    var index: ptr_uint = 0
    while index < mods.len():
        let mod_ptr = mods.get(index) else:
            break
        let mod = unsafe: read(mod_ptr)
        var primary = primary_file(mod)
        defer: primary.release()
        var doc_line = string.String.create()
        defer: doc_line.release()
        var count: ptr_uint = 0
        match fs.read_text(primary.as_str()):
            Result.success as source_payload:
                var source = source_payload.value
                defer: source.release()
                var doc = extract_doc_comment(source.as_str())
                defer: doc.release()
                append_first_line(ref_of(doc_line), doc.as_str())
                var decls = extract_declarations(source.as_str())
                count = decls.len()
                release_declarations(ref_of(decls))
            Result.failure:
                pass
        rows.append("<tr><td><a href=\"/stdlib/")
        append_url_escaped(ref_of(rows), mod.name.as_str())
        rows.append("\"><code>")
        append_html_escaped(ref_of(rows), mod.name.as_str())
        rows.append("</code></a></td><td>")
        append_html_escaped(ref_of(rows), doc_line.as_str())
        rows.append("</td><td>")
        rows.append_format(f"#{count}")
        rows.append("</td></tr>\n")
        index += 1

    var count_text = string.String.create()
    defer: count_text.release()
    count_text.append_format(f"#{mods.len()}")

    var body = string.String.create()
    defer: body.release()
    body.append("<div class=\"hero\"><h1>Standard <span>Library</span></h1><p class=\"tagline\">")
    body.append(count_text.as_str())
    body.append(" modules &mdash; collections, memory allocators, async runtime, text formatting, math, and FFI support.</p></div>")
    body.append("<section><div class=\"table-wrap\"><table class=\"attr-table\">")
    body.append("<tr><th>Module</th><th>Description</th><th>Declarations</th></tr>\n")
    body.append(rows.as_str())
    body.append("</table></div></section>")

    var html = page_with_modules("Standard Library", body.as_str(), root_dir)
    defer: html.release()
    await http_util.send_response(
        connection, 200, "OK", "text/html; charset=utf-8", text.as_byte_span(html.as_str()), head_only
    )


async function serve_module(
    connection: net.TcpStream,
    root_dir: str,
    module_name: str,
    head_only: bool,
) -> void:
    var mods = discover_modules(root_dir)
    defer: release_modules(ref_of(mods))

    var found = false
    var mod_index: ptr_uint = 0
    while mod_index < mods.len():
        let mod_ptr = mods.get(mod_index) else:
            break
        if unsafe: read(mod_ptr).name.as_str().equal(module_name):
            found = true
            break
        mod_index += 1
    if not found:
        await not_found(connection, head_only)
        return

    let mod_ptr = mods.get(mod_index) else:
        await not_found(connection, head_only)
        return
    let mod = unsafe: read(mod_ptr)

    var body = string.String.create()
    defer: body.release()
    body.append("<div class=\"hero\"><h1><code>")
    append_html_escaped(ref_of(body), mod.name.as_str())
    body.append("</code></h1><p class=\"tagline\">")
    if mod.is_dir:
        body.append("Package")
    else:
        body.append("Module")
    body.append("</p></div>")

    var files = module_files(mod)
    defer: release_modules(ref_of(files))
    var file_index: ptr_uint = 0
    while file_index < files.len():
        let file_ptr = files.get(file_index) else:
            break
        let file = unsafe: read(file_ptr)
        var source = string.String.create()
        defer: source.release()
        match fs.read_text(file.path.as_str()):
            Result.failure:
                file_index += 1
                continue
            Result.success as payload:
                source.release()
                source = payload.value

        var doc = extract_doc_comment(source.as_str())
        defer: doc.release()
        if doc.len() > 0:
            body.append("<div class=\"doc-block\">")
            append_html_escaped(ref_of(body), doc.as_str())
            body.append("</div>")

        body.append("<section><div class=\"section-header\"><h3>")
        append_html_escaped(ref_of(body), file.name.as_str())
        body.append(".mt</h3><a href=\"/stdlib/")
        append_url_escaped(ref_of(body), mod.name.as_str())
        body.append("/source/")
        append_url_escaped(ref_of(body), file.name.as_str())
        body.append("\" class=\"source-inline\">source</a><a href=\"/stdlib/")
        append_url_escaped(ref_of(body), mod.name.as_str())
        body.append("/source/")
        append_url_escaped(ref_of(body), file.name.as_str())
        body.append("/hl\" class=\"source-inline hl-inline\">highlighted</a></div>")

        var decls = extract_declarations(source.as_str())
        defer: release_declarations(ref_of(decls))
        body.append("<div class=\"table-wrap\"><table class=\"attr-table\">")
        body.append("<tr><th>Kind</th><th>Name</th><th>Declaration</th></tr>\n")
        var decl_index: ptr_uint = 0
        while decl_index < decls.len():
            let decl_ptr = decls.get(decl_index) else:
                break
            let decl = unsafe: read(decl_ptr)
            body.append("<tr><td><span class=\"kind-badge\">")
            append_html_escaped(ref_of(body), decl.kind.as_str())
            body.append("</span></td><td><code>")
            append_html_escaped(ref_of(body), decl.name.as_str())
            body.append("</code></td><td><code class=\"code-inline\">")
            append_html_escaped(ref_of(body), decl.line.as_str())
            body.append("</code>")
            if decl.has_doc:
                body.append("<div class=\"decl-doc\">")
                append_html_escaped(ref_of(body), decl.doc.as_str())
                body.append("</div>")
            body.append("</td></tr>\n")
            decl_index += 1
        body.append("</table></div></section>")
        file_index += 1

    var html = page_with_modules(mod.name.as_str(), body.as_str(), root_dir)
    defer: html.release()
    await http_util.send_response(
        connection, 200, "OK", "text/html; charset=utf-8", text.as_byte_span(html.as_str()), head_only
    )


async function serve_source(
    connection: net.TcpStream,
    root_dir: str,
    module_name: str,
    file_name: str,
    highlighted: bool,
    head_only: bool,
) -> void:
    var mods = discover_modules(root_dir)
    defer: release_modules(ref_of(mods))

    var mod_ptr_opt: ptr[DocModule]? = null
    var index: ptr_uint = 0
    while index < mods.len():
        let mod_ptr = mods.get(index) else:
            break
        if unsafe: read(mod_ptr).name.as_str().equal(module_name):
            mod_ptr_opt = mod_ptr
            break
        index += 1

    let mod_ptr = mod_ptr_opt else:
        await not_found(connection, head_only)
        return
    let mod = unsafe: read(mod_ptr)

    var files = module_files(mod)
    defer: release_modules(ref_of(files))
    var file_path: string.String = string.String.create()
    var found = false
    var file_index: ptr_uint = 0
    while file_index < files.len():
        let file_ptr = files.get(file_index) else:
            break
        let file = unsafe: read(file_ptr)
        if file.name.as_str().equal(file_name):
            file_path.release()
            file_path = string.String.from_str(file.path.as_str())
            found = true
            break
        file_index += 1
    if not found:
        file_path.release()
        await not_found(connection, head_only)
        return
    defer: file_path.release()

    if not highlighted:
        await serve_file(connection, file_path.as_str(), "text/plain", head_only)
        return

    var script = path_ops.join(root_dir, "bindings/vscode/scripts/snapshot.js")
    defer: script.release()
    var theme = path_ops.join(root_dir, "bindings/vscode/themes/2026-dark.json")
    defer: theme.release()

    var command = vec.Vec[str].create()
    defer: command.release()
    command.push("node")
    command.push(script.as_str())
    command.push(file_path.as_str())
    command.push("-t")
    command.push(theme.as_str())

    match process.capture(command.as_span()):
        Result.success as captured:
            var result = captured.value
            defer: result.release()
            if result.status.success():
                var html = result.stdout
                await http_util.send_response(
                    connection, 200, "OK", "text/html; charset=utf-8", text.as_byte_span(html.as_str()), head_only
                )
                return
        Result.failure:
            pass
    await http_util.send_text(
        connection, 503, "Service Unavailable",
        "Syntax highlighting unavailable (node.js or snapshot dependencies not found)", head_only
    )


async function serve_search(connection: net.TcpStream, root_dir: str, query: str) -> void:
    var query_value = query_param(query, "q")
    defer: query_value.release()
    let needle = query_value.as_str()
    if needle.len < 2:
        await http_util.send_response(
            connection, 200, "OK", "application/json; charset=utf-8", text.as_byte_span("[]"), false
        )
        return

    var mods = discover_modules(root_dir)
    defer: release_modules(ref_of(mods))

    var json = string.String.create()
    defer: json.release()
    json.push_byte(91)
    var first = true
    var index: ptr_uint = 0
    while index < mods.len():
        let mod_ptr = mods.get(index) else:
            break
        let mod = unsafe: read(mod_ptr)
        if ascii_contains_ignore_case(mod.name.as_str(), needle):
            if not first:
                json.push_byte(44)
            first = false
            json.append("{\"name\":")
            append_json_string(ref_of(json), mod.name.as_str())
            json.append(",\"kind\":")
            if mod.is_dir:
                append_json_string(ref_of(json), "dir")
            else:
                append_json_string(ref_of(json), "file")
            json.append(",\"summary\":")
            var summary = string.String.create()
            defer: summary.release()
            var primary = primary_file(mod)
            defer: primary.release()
            match fs.read_text(primary.as_str()):
                Result.success as payload:
                    var source = payload.value
                    defer: source.release()
                    var doc = extract_doc_comment(source.as_str())
                    defer: doc.release()
                    append_first_line(ref_of(summary), doc.as_str())
                Result.failure:
                    pass
            if summary.len() == 0:
                json.append("null")
            else:
                append_json_string(ref_of(json), summary.as_str())
            json.push_byte(125)
        index += 1
    json.push_byte(93)

    await http_util.send_response(
        connection, 200, "OK", "application/json; charset=utf-8", text.as_byte_span(json.as_str()), false
    )


function discover_modules(root_dir: str) -> vec.Vec[DocModule]:
    var result = vec.Vec[DocModule].create()
    var std_dir = path_ops.join(root_dir, "std")
    defer: std_dir.release()

    var entries = fs.list_entries(std_dir.as_str()) else:
        return result
    defer: entries.release()

    var index: ptr_uint = 0
    while index < entries.len():
        let name = entries.get(index) else:
            break
        var child = path_ops.join(std_dir.as_str(), name)
        if fs.is_directory(child.as_str()):
            var has_mt = false
            var child_entries = fs.list_entries(child.as_str()) else:
                child.release()
                index += 1
                continue
            var ci: ptr_uint = 0
            while ci < child_entries.len():
                let child_name = child_entries.get(ci) else:
                    break
                if child_name.ends_with(".mt"):
                    has_mt = true
                    break
                ci += 1
            child_entries.release()
            if has_mt:
                result.push(DocModule(
                    name = string.String.from_str(name),
                    path = child,
                    is_dir = true,
                ))
                child = string.String.create()
        child.release()
        index += 1

    index = 0
    while index < entries.len():
        let name = entries.get(index) else:
            break
        if name.ends_with(".mt") and not platform_suffix(name):
            let stem = name.slice(0, name.len - 3)
            var exists = false
            var ri: ptr_uint = 0
            while ri < result.len():
                let mod = result.get(ri) else:
                    break
                if unsafe: read(mod).name.as_str().equal(stem):
                    exists = true
                    break
                ri += 1
            if not exists:
                var full = path_ops.join(std_dir.as_str(), name)
                result.push(DocModule(
                    name = string.String.from_str(stem),
                    path = full,
                    is_dir = false,
                ))
                full = string.String.create()
        index += 1

    result.sort_by(proc(left: ptr[DocModule], right: ptr[DocModule]) -> int: compare_modules(left, right))
    return result


function compare_modules(left: ptr[DocModule], right: ptr[DocModule]) -> int:
    let left_value = unsafe: read(left)
    let right_value = unsafe: read(right)
    return left_value.name.as_str().compare(right_value.name.as_str())


function platform_suffix(name: str) -> bool:
    return name.ends_with(".linux.mt") or name.ends_with(".windows.mt") or name.ends_with(".wasm.mt")


function primary_file(mod: DocModule) -> string.String:
    if not mod.is_dir:
        return string.String.from_str(mod.path.as_str())
    var name = string.String.from_str(mod.name.as_str())
    defer: name.release()
    name.append(".mt")
    return path_ops.join(mod.path.as_str(), name.as_str())


function module_files(mod: DocModule) -> vec.Vec[DocModule]:
    var result = vec.Vec[DocModule].create()
    if not mod.is_dir:
        result.push(DocModule(
            name = string.String.from_str(mod.name.as_str()),
            path = string.String.from_str(mod.path.as_str()),
            is_dir = false,
        ))
        return result

    var entries = fs.list_entries(mod.path.as_str()) else:
        return result
    defer: entries.release()

    # `Entries` is discovery order; gather and sort by name.
    var index: ptr_uint = 0
    while index < entries.len():
        let name = entries.get(index) else:
            break
        if name.ends_with(".mt") and not platform_suffix(name):
            var full = path_ops.join(mod.path.as_str(), name)
            result.push(DocModule(
                name = string.String.from_str(name.slice(0, name.len - 3)),
                path = full,
                is_dir = false,
            ))
            full = string.String.create()
        index += 1
    result.sort_by(proc(left: ptr[DocModule], right: ptr[DocModule]) -> int: compare_modules(left, right))
    return result


function extract_doc_comment(source: str) -> string.String:
    var result = string.String.create()
    var in_doc = false
    var start: ptr_uint = 0
    var pos: ptr_uint = 0
    while pos <= source.len:
        if pos == source.len or source.byte_at(pos) == 10:
            let line = source.slice(start, pos - start)
            let stripped = line.trim_ascii_whitespace()
            if stripped.starts_with("##"):
                var content = stripped.slice(2, stripped.len - 2)
                if content.starts_with(" "):
                    content = content.slice(1, content.len - 1)
                if result.len() > 0:
                    result.push_byte(10)
                result.append(content)
                in_doc = true
            else if in_doc:
                break
            start = pos + 1
        pos += 1
    return result


function extract_declarations(source: str) -> vec.Vec[Declaration]:
    var result = vec.Vec[Declaration].create()
    var pending_doc = string.String.create()
    defer: pending_doc.release()
    var extend_parent = string.String.create()
    defer: extend_parent.release()
    var has_extend = false
    var extend_indent: ptr_uint = 0

    var start: ptr_uint = 0
    var pos: ptr_uint = 0
    while pos <= source.len:
        if pos == source.len or source.byte_at(pos) == 10:
            let line = source.slice(start, pos - start)
            let indent = leading_spaces(line)
            let stripped = line.trim_ascii_whitespace()

            if stripped.len == 0 or stripped.starts_with("#") or stripped.starts_with("import"):
                start = pos + 1
                pos += 1
                continue

            if has_extend and indent <= extend_indent:
                has_extend = false

            if stripped.starts_with("##"):
                var content = stripped.slice(2, stripped.len - 2)
                if content.starts_with(" "):
                    content = content.slice(1, content.len - 1)
                if pending_doc.len() > 0:
                    pending_doc.push_byte(10)
                pending_doc.append(content)
                start = pos + 1
                pos += 1
                continue

            var kind = string.String.create()
            var name = string.String.create()
            let classified = classify_declaration(stripped, ref_of(kind), ref_of(name))
            if not classified:
                kind.release()
                name.release()
                pending_doc.assign("")
                start = pos + 1
                pos += 1
                continue

            if kind.as_str().equal("extend"):
                has_extend = true
                extend_indent = indent
                extend_parent.assign(name.as_str())
                kind.release()
                name.release()
                start = pos + 1
                pos += 1
                continue

            if has_extend and indent > extend_indent and extend_parent.len() > 0:
                var qualified = string.String.from_str(extend_parent.as_str())
                qualified.push_byte(46)
                qualified.append(name.as_str())
                name.release()
                name = qualified
                kind.assign("method")

            var doc = string.String.create()
            let has_doc = pending_doc.len() > 0
            if has_doc:
                doc.assign(pending_doc.as_str())
            pending_doc.assign("")

            result.push(Declaration(
                kind = kind,
                name = name,
                line = string.String.from_str(stripped),
                doc = doc,
                has_doc = has_doc,
            ))
            start = pos + 1
        pos += 1
    return result


struct DeclarationKeyword:
    keyword: str
    kind: str


function classify_declaration(stripped: str, kind: ref[string.String], name: ref[string.String]) -> bool:
    if stripped.starts_with("extending "):
        let rest = stripped.slice(10, stripped.len - 10)
        let end = declaration_name_end(rest)
        if end == 0:
            return false
        kind.assign("extend")
        name.assign(rest.slice(0, end))
        return true

    if stripped.starts_with("attribute["):
        let close = http_util.find_byte(stripped, 93)
        if close < stripped.len:
            var rest = stripped.slice(close + 1, stripped.len - close - 1).trim_ascii_whitespace()
            let end = declaration_name_end(rest)
            if end > 0:
                kind.assign("attr")
                name.assign(rest.slice(0, end))
                return true
        return false

    var rest = stripped
    while rest.starts_with("public "):
        rest = rest.slice(7, rest.len - 7)

    let modifier_list = modifiers()
    var stripped_modifier = true
    while stripped_modifier:
        stripped_modifier = false
        var modifier_index: ptr_uint = 0
        while modifier_index < 7:
            let modifier = modifier_list[modifier_index]
            if rest.starts_with(modifier):
                rest = rest.slice(modifier.len, rest.len - modifier.len)
                stripped_modifier = true
                break
            modifier_index += 1

    let declarations = declaration_keywords()
    var index: ptr_uint = 0
    while index < 11:
        let entry = declarations[index]
        if rest.starts_with(entry.keyword):
            let tail = rest.slice(entry.keyword.len, rest.len - entry.keyword.len)
            let end = declaration_name_end(tail)
            if end == 0:
                return false
            kind.assign(entry.kind)
            name.assign(tail.slice(0, end))
            return true
        index += 1
    return false


function declaration_keywords() -> array[DeclarationKeyword, 11]:
    return array[DeclarationKeyword, 11](
        DeclarationKeyword(keyword = "function ", kind = "func"),
        DeclarationKeyword(keyword = "const ", kind = "const"),
        DeclarationKeyword(keyword = "struct ", kind = "struct"),
        DeclarationKeyword(keyword = "enum ", kind = "enum"),
        DeclarationKeyword(keyword = "flags ", kind = "flags"),
        DeclarationKeyword(keyword = "variant ", kind = "variant"),
        DeclarationKeyword(keyword = "union ", kind = "union"),
        DeclarationKeyword(keyword = "opaque ", kind = "opaque"),
        DeclarationKeyword(keyword = "type ", kind = "type"),
        DeclarationKeyword(keyword = "interface ", kind = "interface"),
        DeclarationKeyword(keyword = "event ", kind = "event"),
    )


function modifiers() -> array[str, 7]:
    return array[str, 7]("external ", "foreign ", "async ", "const ", "static ", "editable ", "inline ")


function declaration_name_end(value: str) -> ptr_uint:
    var index: ptr_uint = 0
    while index < value.len:
        let ch = value.byte_at(index)
        if ch == 32 or ch == 58 or ch == 91 or ch == 40:
            return index
        index += 1
    return value.len


function leading_spaces(line: str) -> ptr_uint:
    var index: ptr_uint = 0
    while index < line.len and line.byte_at(index) == 32:
        index += 1
    return index


function append_first_line(target: ref[string.String], value: str) -> void:
    let end = http_util.find_byte(value, 10)
    target.append(value.slice(0, end))


function append_html_escaped(target: ref[string.String], value: str) -> void:
    var index: ptr_uint = 0
    while index < value.len:
        let ch = value.byte_at(index)
        if ch == 38:
            target.append("&amp;")
        else if ch == 60:
            target.append("&lt;")
        else if ch == 62:
            target.append("&gt;")
        else if ch == 34:
            target.append("&quot;")
        else:
            target.push_byte(ch)
        index += 1


function append_url_escaped(target: ref[string.String], value: str) -> void:
    append_html_escaped(target, value)


function append_json_string(target: ref[string.String], value: str) -> void:
    target.push_byte(34)
    var index: ptr_uint = 0
    while index < value.len:
        let ch = value.byte_at(index)
        if ch == 34:
            target.append("\\\"")
        else if ch == 92:
            target.append("\\\\")
        else if ch == 10:
            target.append("\\n")
        else if ch == 13:
            target.append("\\r")
        else if ch == 9:
            target.append("\\t")
        else:
            target.push_byte(ch)
        index += 1
    target.push_byte(34)


function ascii_contains_ignore_case(haystack: str, needle: str) -> bool:
    if needle.len == 0:
        return true
    if needle.len > haystack.len:
        return false
    var start: ptr_uint = 0
    while start + needle.len <= haystack.len:
        var matched = true
        var index: ptr_uint = 0
        while index < needle.len:
            var left = haystack.byte_at(start + index)
            var right = needle.byte_at(index)
            if left >= 65 and left <= 90:
                left += 32
            if right >= 65 and right <= 90:
                right += 32
            if left != right:
                matched = false
                break
            index += 1
        if matched:
            return true
        start += 1
    return false


function query_param(query: str, key: str) -> string.String:
    var start: ptr_uint = 0
    var pos: ptr_uint = 0
    while pos <= query.len:
        if pos == query.len or query.byte_at(pos) == 38:
            let pair = query.slice(start, pos - start)
            let equals = http_util.find_byte(pair, 61)
            if equals < pair.len:
                let name = pair.slice(0, equals)
                if name.equal(key):
                    let raw_value = pair.slice(equals + 1, pair.len - equals - 1)
                    var plus_normalized = string.String.create()
                    defer: plus_normalized.release()
                    var index: ptr_uint = 0
                    while index < raw_value.len:
                        if raw_value.byte_at(index) == 43:
                            plus_normalized.push_byte(32)
                        else:
                            plus_normalized.push_byte(raw_value.byte_at(index))
                        index += 1
                    match url.percent_decode(plus_normalized.as_str()):
                        Option.some as decoded:
                            return decoded.value
                        Option.none:
                            return string.String.from_str(raw_value)
            start = pos + 1
        pos += 1
    return string.String.create()


function page(title: str, body: str) -> string.String:
    var result = string.String.create()
    result.append("<!DOCTYPE html><html lang=\"en\" data-theme=\"light\"><head><meta charset=\"UTF-8\">")
    result.append("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\"><title>")
    append_html_escaped(ref_of(result), title)
    result.append(" &mdash; Documentation</title><link rel=\"stylesheet\" href=\"/css/docs.css\"></head><body>")
    result.append("<div class=\"topbar\"><span class=\"logo-text\">&#127861; Milk Tea</span></div>")
    result.append("<main class=\"main\" id=\"main\">")
    result.append(body)
    result.append("</main><script src=\"/js/docs.js\"></script></body></html>")
    return result


function page_with_modules(title: str, body: str, root_dir: str) -> string.String:
    var result = string.String.create()
    result.append("<!DOCTYPE html><html lang=\"en\" data-theme=\"light\"><head><meta charset=\"UTF-8\">")
    result.append("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\"><title>")
    append_html_escaped(ref_of(result), title)
    result.append(" &mdash; Documentation</title><link rel=\"stylesheet\" href=\"/css/docs.css\"></head><body>")
    result.append("<div class=\"topbar\"><span class=\"logo-text\">&#127861; Milk Tea</span></div>")

    var mods = discover_modules(root_dir)
    defer: release_modules(ref_of(mods))
    result.append("<aside class=\"sidebar\"><div class=\"sidebar-logo\"><a href=\"/\">&#129483; Milk Tea</a></div>")
    result.append("<nav class=\"sidebar-nav\"><a href=\"/\">Reference</a>")
    var index: ptr_uint = 0
    while index < mods.len():
        let mod = mods.get(index) else:
            break
        result.append("<a href=\"/stdlib/")
        append_url_escaped(ref_of(result), unsafe: read(mod).name.as_str())
        result.append("\" class=\"mod-link\">")
        append_html_escaped(ref_of(result), unsafe: read(mod).name.as_str())
        result.append("</a>")
        index += 1
    result.append("</nav></aside><main class=\"main\" id=\"main\">")
    result.append(body)
    result.append("</main><script src=\"/js/docs.js\"></script></body></html>")
    return result
