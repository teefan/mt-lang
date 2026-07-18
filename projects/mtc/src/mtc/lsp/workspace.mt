## Workspace state — open documents, module roots, and the root path.
##
## One Workspace instance lives for the lifetime of the server.  Document
## content is stored by URI using owned string.String keys (not borrowed str)
## because URI strings from incoming JSON messages are ephemeral.

import std.fs as fs_mod
import std.map as map_mod
import std.path as path_ops
import std.str
import std.string as string
import std.vec as vec

import mtc.lsp.uri as uri_ops


public struct Workspace:
    root_path: string.String
    module_roots: vec.Vec[string.String]
    open_docs: map_mod.Map[string.String, string.String]


extending Workspace:
    public static function create(root: str) -> Workspace:
        var roots = vec.Vec[string.String].create()
        discover_project_root(root, ref_of(roots))
        return Workspace(
            root_path = string.String.from_str(root),
            module_roots = roots,
            open_docs = map_mod.Map[string.String, string.String].create()
        )


    public editable function open(uri: str, text: str) -> void:
        let path_result = uri_ops.file_uri_to_path(uri)
        match path_result:
            Option.some as path_payload:
                this.open_docs.set(path_payload.value, string.String.from_str(text))
            Option.none:
                pass


    public editable function change(uri: str, text: str) -> void:
        let path_result = uri_ops.file_uri_to_path(uri)
        match path_result:
            Option.some as path_payload:
                this.open_docs.set(path_payload.value, string.String.from_str(text))
            Option.none:
                pass


    public editable function close(uri: str) -> void:
        let path_result = uri_ops.file_uri_to_path(uri)
        match path_result:
            Option.some as path_payload:
                this.open_docs.remove(path_payload.value)
            Option.none:
                pass


    ## Source text for a file: the open editor buffer when present, else disk.
    ## Returns an owned copy the caller must release.
    public function document_source(path: str) -> Option[string.String]:
        var key = string.String.from_str(path)
        defer key.release()
        let doc_ptr = this.open_docs.get(key)
        if doc_ptr != null:
            unsafe:
                return Option[string.String].some(value = string.String.from_str(read(doc_ptr).as_str()))

        match fs_mod.read_text(path):
            Result.success as content:
                return Option[string.String].some(value = content.value)
            Result.failure as failure_payload:
                var err = failure_payload.error
                err.release()
                return Option[string.String].none


    ## Resolve a source file path to the effective module roots for dependency
    ## loading.  Returns a span of root directory paths.
    public function effective_module_roots_for(path: str) -> vec.Vec[str]:
        var result = vec.Vec[str].create()
        var i: ptr_uint = 0
        while i < this.module_roots.len():
            let root_ptr = this.module_roots.get(i) else:
                break
            unsafe:
                result.push(read(root_ptr).as_str())
            i += 1
        return result


    public editable function release() -> void:
        this.root_path.release()
        release_module_roots(ref_of(this.module_roots))
        this.open_docs.release()


## Walk upward from source_path to find the project root (the directory
## containing std/ at the top of the source tree).  Pushes discovered roots
## into `roots` as owned string.String values.
public function discover_project_root(source_path: str, roots: ref[vec.Vec[string.String]]) -> void:
    var current = if fs_mod.is_directory(source_path): source_path else: path_ops.dirname(source_path)
    while true:
        var joined = path_ops.join(current, "std")
        defer joined.release()
        if fs_mod.is_directory(joined.as_str()):
            var i: ptr_uint = 0
            while i < roots.len():
                let ep_ptr = roots.get(i) else:
                    break
                unsafe:
                    if read(ep_ptr).as_str().equal(current):
                        return
                i += 1
            roots.push(string.String.from_str(current))
            return
        let parent = path_ops.dirname(current)
        if parent.equal(current):
            return
        current = parent


function release_module_roots(roots: ref[vec.Vec[string.String]]) -> void:
    var i: ptr_uint = 0
    while i < roots.len():
        let ptr = roots.get(i) else:
            break
        unsafe:
            read(ptr).release()
        i += 1
    roots.release()
