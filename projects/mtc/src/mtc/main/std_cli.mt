## `mtc std list|show|source` — the standard-library catalog commands.
## Extracted from main.mt.

import std.env as env
import std.fs as fs
import std.path as path_ops
import std.str as str
import std.string as string
import std.stdio as stdio
import std.vec as vec

import mtc.std_catalog as std_catalog
import mtc.cli_help as cli_help

import mtc.main as main


## A standard-library catalog entry (name, doc summary, category, source path).
struct StdCatalogEntry:
    name: string.String
    description: string.String
    category: string.String
    path: string.String


## `mtc std list|show` — list standard-library modules and print their source,
## mirroring the Ruby CLI's StdCatalog.
public function std_command(args: span[str]) -> int:
    if args.len < 2:
        main.eprint_line("missing std subcommand (expected list or show)")
        let _ = cli_help.print_command_help("std", true)
        return 1
    let sub = args[1]
    if sub == "list":
        var as_json = false
        var ai: ptr_uint = 2
        while ai < args.len:
            if args[ai] == "--json":
                as_json = true
            else:
                var unknown_opt = string.String.create()
                defer: unknown_opt.release()
                unknown_opt.append("unknown std list option ")
                unknown_opt.append(args[ai])
                main.eprint_line(unknown_opt.as_str())
                return 1
            ai += 1
        return std_list_command(as_json)
    if sub == "show":
        if args.len < 3:
            main.eprint_line("missing module name")
            let _ = cli_help.print_command_help("std", true)
            return 1
        return std_show_command(args[2])
    var unknown_sub = string.String.create()
    defer: unknown_sub.release()
    unknown_sub.append("unknown std subcommand ")
    unknown_sub.append(sub)
    main.eprint_line(unknown_sub.as_str())
    let _ = cli_help.print_command_help("std", true)
    return 1


## Locate the standard library directory: `$MILK_TEA_STD_ROOT` when set, else the
## `std/` directory under the current directory's project root.
function std_root_dir() -> Option[string.String]:
    match env.get("MILK_TEA_STD_ROOT"):
        Option.some as v:
            if fs.is_directory(v.value):
                return Option[string.String].some(value = string.String.from_str(v.value))
        Option.none:
            pass
    var cwd = string.String.create()
    defer: cwd.release()
    match fs.current_directory():
        Result.success as cwd_payload:
            cwd.release()
            cwd = cwd_payload.value
        Result.failure:
            pass
    var roots = vec.Vec[str].create()
    defer: roots.release()
    var owned_roots = vec.Vec[string.String].create()
    defer: owned_roots.release()
    if cwd.len() > 0:
        roots.push(cwd.as_str())
        main.add_module_roots(cwd.as_str(), ref_of(roots), ref_of(owned_roots))
    var i: ptr_uint = 0
    while i < roots.len():
        let rp = roots.get(i) else:
            break
        let root = unsafe: read(rp)
        var candidate = path_ops.join(root, "std")
        if fs.is_directory(candidate.as_str()):
            return Option[string.String].some(value = candidate)
        candidate.release()
        i += 1
    return Option[string.String].none


function std_list_command(as_json: bool) -> int:
    let root_opt = std_root_dir() else:
        stdio.print_line("std: cannot locate the standard library (set MILK_TEA_STD_ROOT)")
        return 1
    var root = root_opt
    defer: root.release()
    var entries = collect_std_entries(root.as_str())
    defer: release_std_entries(ref_of(entries))
    if as_json:
        emit_std_json(ref_of(entries))
        return 0
    print_std_entries(ref_of(entries))
    return 0


function std_module_not_found(name: str) -> void:
    var msg = string.String.create()
    defer: msg.release()
    msg.append("std module not found: ")
    msg.append(name)
    main.eprint_line(msg.as_str())


function std_show_command(name: str) -> int:
    if name.len == 0 or name.contains_substring(".."):
        std_module_not_found(name)
        return 1
    let root_opt = std_root_dir() else:
        stdio.print_line("std: cannot locate the standard library (set MILK_TEA_STD_ROOT)")
        return 1
    var root = root_opt
    defer: root.release()
    var relative = string.String.create()
    defer: relative.release()
    var i: ptr_uint = 0
    while i < name.len:
        let b = name.byte_at(i)
        if b == '.':
            relative.push_byte('/')
        else:
            relative.push_byte(b)
        i += 1
    var base_path = path_ops.join(root.as_str(), relative.as_str())
    # `.linux`/`.windows`/`.wasm` variants are preferred over the shared file,
    # matching the compiler's import resolution.
    var variant_path = string.String.create()
    defer: variant_path.release()
    variant_path.append(base_path.as_str())
    variant_path.append(".linux.mt")
    var shared_path = string.String.create()
    defer: shared_path.release()
    shared_path.append(base_path.as_str())
    shared_path.append(".mt")
    if fs.is_file(variant_path.as_str()):
        return print_std_source(variant_path.as_str(), name)
    if fs.is_file(shared_path.as_str()):
        return print_std_source(shared_path.as_str(), name)
    std_module_not_found(name)
    return 1


function print_std_source(path: str, name: str) -> int:
    match fs.read_text(path):
        Result.success as payload:
            var content = payload.value
            defer: content.release()
            stdio.print_format(c"%.*s", int<-(content.as_str().len), content.as_str().data)
            return 0
        Result.failure:
            std_module_not_found(name)
            return 1


function collect_std_entries(root: str) -> vec.Vec[StdCatalogEntry]:
    var entries = vec.Vec[StdCatalogEntry].create()
    match fs.list_entries(root):
        Result.success as names_payload:
            var names = names_payload.value
            defer: names.release()
            var i: ptr_uint = 0
            while i < names.len():
                let name = names.get(i) else:
                    break
                var full = path_ops.join(root, name)
                defer: full.release()
                if name.ends_with(".mt") and fs.is_file(full.as_str()):
                    std_add_entry(ref_of(entries), full.as_str(), std_logical_name(name))
                else if fs.is_directory(full.as_str()) and not name.equal("c"):
                    match fs.list_entries(full.as_str()):
                        Result.success as sub_payload:
                            var subs = sub_payload.value
                            defer: subs.release()
                            var si: ptr_uint = 0
                            while si < subs.len():
                                let sname = subs.get(si) else:
                                    break
                                if sname.ends_with(".mt"):
                                    var sfull = path_ops.join(full.as_str(), sname)
                                    if fs.is_file(sfull.as_str()):
                                        var logical = string.String.create()
                                        logical.append(name)
                                        logical.push_byte('.')
                                        logical.append(std_logical_name(sname))
                                        std_add_entry(ref_of(entries), sfull.as_str(), logical.as_str())
                                        logical.release()
                                    sfull.release()
                                si += 1
                        Result.failure:
                            pass
                i += 1
        Result.failure:
            pass
    entries.sort_by(std_entry_compare)
    return entries


function std_entry_compare(left: ptr[StdCatalogEntry], right: ptr[StdCatalogEntry]) -> int:
    let l = unsafe: read(left).name.as_str()
    let r = unsafe: read(right).name.as_str()
    return l.compare(r)


## The logical module name of a `std/*.mt` file: the stem with any platform
## suffix (`.linux`/`.windows`/`.wasm`) removed.
function std_logical_name(filename: str) -> str:
    var stem = filename.slice(0, filename.len - 3)
    if stem.ends_with(".linux"):
        return stem.slice(0, stem.len - 6)
    if stem.ends_with(".windows"):
        return stem.slice(0, stem.len - 8)
    if stem.ends_with(".wasm"):
        return stem.slice(0, stem.len - 5)
    return stem


## Add (or replace) an entry for a module file.  Generated modules are skipped;
## the shared file beats platform variants, and among variants the host platform
## (linux) wins.
function std_add_entry(entries: ref[vec.Vec[StdCatalogEntry]], path: str, name: str) -> void:
    match fs.read_text(path):
        Result.success as payload:
            var content = payload.value
            defer: content.release()
            let text = content.as_str()
            if text.starts_with("# generated by mtc"):
                return
            var description = string.String.create()
            defer: description.release()
            var category = string.String.create()
            defer: category.release()
            match std_catalog.std_registry_lookup(name):
                Option.some as info:
                    category.append(info.value.category)
                    description.append(info.value.description)
                Option.none:
                    description.append(std_doc_summary(text))
            # Replace an existing entry when this path is preferred.
            var existing: ptr[StdCatalogEntry]? = null
            var idx: ptr_uint = 0
            while idx < entries.len():
                let ep = entries.get(idx) else:
                    break
                if unsafe: read(ep).name.as_str() == name:
                    existing = ep
                    break
                idx += 1
            if existing != null:
                let old_path = unsafe: read(ptr[StdCatalogEntry]<-existing).path.as_str()
                if not std_path_preferred(path, old_path):
                    return
                var old = unsafe: read(ptr[StdCatalogEntry]<-existing)
                old.description.release()
                old.category.release()
                old.path.release()
                old.description = string.String.from_str(description.as_str())
                old.category = string.String.from_str(category.as_str())
                old.path = string.String.from_str(path)
                unsafe:
                    read(ptr[StdCatalogEntry]<-existing) = old
                return
            entries.push(StdCatalogEntry(
                name = string.String.from_str(name),
                description = string.String.from_str(description.as_str()),
                category = string.String.from_str(category.as_str()),
                path = string.String.from_str(path),
            ))
        Result.failure:
            pass


## Prefer a shared file over any platform variant; among variants the host
## platform (linux) wins, then the alphabetically smaller path.
function std_path_preferred(candidate: str, current: str) -> bool:
    let (c_variant, c_platform) = std_path_rank(candidate)
    let (u_variant, u_platform) = std_path_rank(current)
    if c_variant != u_variant:
        return c_variant < u_variant
    if c_platform != u_platform:
        return c_platform < u_platform
    return candidate.compare(current) < 0


function std_path_rank(path: str) -> (int, int):
    var is_variant = false
    var platform = 0
    if path.ends_with(".linux.mt"):
        is_variant = true
        platform = 0
    else if path.ends_with(".windows.mt"):
        is_variant = true
        platform = 1
    else if path.ends_with(".wasm.mt"):
        is_variant = true
        platform = 2
    if is_variant:
        return (1, platform)
    return (0, 0)


## The first `##` doc-comment line of a module, or an empty string.
function std_doc_summary(source: str) -> str:
    var pos: ptr_uint = 0
    while pos < source.len:
        var line_end = pos
        while line_end < source.len and source.byte_at(line_end) != 10:
            line_end += 1
        let line = source.slice(pos, line_end - pos)
        var trimmed = line
        while trimmed.len > 0 and (trimmed.byte_at(0) == 32 or trimmed.byte_at(0) == 9):
            trimmed = trimmed.slice(1, trimmed.len - 1)
        if trimmed.len > 0:
            if trimmed.starts_with("##"):
                var text = trimmed.slice(2, trimmed.len - 2)
                while text.len > 0 and text.byte_at(0) == 32:
                    text = text.slice(1, text.len - 1)
                while text.len > 0 and (text.byte_at(text.len - 1) == 32 or text.byte_at(text.len - 1) == 13):
                    text = text.slice(0, text.len - 1)
                return text
            break
        pos = line_end + 1
    return ""


function release_std_entries(entries: ref[vec.Vec[StdCatalogEntry]]) -> void:
    var i: ptr_uint = 0
    while i < entries.len():
        let ep = entries.get(i) else:
            break
        unsafe:
            var e = read(ep)
            e.name.release()
            e.description.release()
            e.category.release()
            e.path.release()
        i += 1
    entries.release()


function append_padded(buf: ref[string.String], text: str, width: ptr_uint) -> void:
    buf.append(text)
    var pad = if text.len < width: width - text.len else: 0
    while pad > 0:
        buf.push_byte(' ')
        pad -= 1


function print_std_entries(entries: ref[vec.Vec[StdCatalogEntry]]) -> void:
    var name_width: ptr_uint = 0
    var description_width: ptr_uint = 0
    var i: ptr_uint = 0
    while i < entries.len():
        let ep = entries.get(i) else:
            break
        unsafe:
            let e = read(ep)
            if e.name.as_str().len > name_width:
                name_width = e.name.as_str().len
            if e.description.as_str().len > description_width:
                description_width = e.description.as_str().len
        i += 1
    var ci: ptr_uint = 0
    while ci < std_catalog.std_category_order_count():
        let category = std_catalog.std_category_order_at(ci)
        var printed_header = false
        var ei: ptr_uint = 0
        while ei < entries.len():
            let ep = entries.get(ei) else:
                break
            unsafe:
                let e = read(ep)
                if e.category.as_str() == category and category.len > 0:
                    if not printed_header:
                        stdio.print_format(c"%.*s:\n", int<-(category.len), category.data)
                        printed_header = true
                    var line = string.String.create()
                    defer: line.release()
                    line.append("  ")
                    append_padded(ref_of(line), e.name.as_str(), name_width)
                    line.append("  ")
                    let description = if e.description.as_str().len > 0: e.description.as_str() else: "(no description)"
                    append_padded(ref_of(line), description, description_width)
                    line.append("  ")
                    line.append(e.path.as_str())
                    stdio.print_format(c"%.*s\n", int<-(line.as_str().len), line.as_str().data)
            ei += 1
        if printed_header:
            stdio.print_line("")
        ci += 1


public function append_json_string(buf: ref[string.String], text: str) -> void:
    buf.push_byte('"')
    var i: ptr_uint = 0
    while i < text.len:
        let b = text.byte_at(i)
        if b == 34:
            buf.append("\\\"")
        else if b == 92:
            buf.append("\\\\")
        else if b == 10:
            buf.append("\\n")
        else if b == 13:
            buf.append("\\r")
        else if b == 9:
            buf.append("\\t")
        else:
            buf.push_byte(b)
        i += 1
    buf.push_byte('"')


function emit_std_json(entries: ref[vec.Vec[StdCatalogEntry]]) -> void:
    var buf = string.String.create()
    defer: buf.release()
    buf.push_byte('[')
    var i: ptr_uint = 0
    while i < entries.len():
        let ep = entries.get(i) else:
            break
        unsafe:
            let e = read(ep)
            if i > 0:
                buf.push_byte(',')
            buf.append("{\"name\":")
            append_json_string(ref_of(buf), e.name.as_str())
            buf.append(",\"description\":")
            if e.description.as_str().len > 0:
                append_json_string(ref_of(buf), e.description.as_str())
            else:
                buf.append("null")
            buf.append(",\"category\":")
            if e.category.as_str().len > 0:
                append_json_string(ref_of(buf), e.category.as_str())
            else:
                buf.append("null")
            buf.append(",\"path\":")
            append_json_string(ref_of(buf), e.path.as_str())
            buf.push_byte('}')
        i += 1
    buf.push_byte(']')
    stdio.print_format(c"%.*s\n", int<-(buf.as_str().len), buf.as_str().data)
