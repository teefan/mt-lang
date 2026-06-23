import compiler.context as ctx
import compiler.source as source_mod

function main() -> int:
    let source = source_mod.from_str("", "")
    let _ = ctx.create(source)
    return 0
