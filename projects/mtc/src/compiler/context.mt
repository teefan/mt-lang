import compiler.diagnostics as d
import compiler.source as source_mod
import std.intern
import std.mem.arena
import std.vec

public struct Context:
    diagnostics: vec.Vec[d.Diagnostic]
    interner: intern.Interner
    arena: arena.Arena
    source: source_mod.SourceFile


public function create(source: source_mod.SourceFile) -> Context:
    return Context(
        diagnostics = vec.Vec[d.Diagnostic].create(),
        interner = intern.create(),
        arena = arena.create(32 * 1024),
        source = source,
    )


extending Context:
    public editable function report(diagnostic: d.Diagnostic) -> void:
        this.diagnostics.push(diagnostic)


    public function error_count() -> ptr_uint:
        var count: ptr_uint = 0
        let span = this.diagnostics.as_span()
        for diag in span:
            if diag.severity == d.Severity.error:
                count += 1
        return count


    public function has_errors() -> bool:
        return this.error_count() != 0
