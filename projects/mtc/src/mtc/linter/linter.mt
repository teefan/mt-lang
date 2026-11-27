## In-language linter for the self-hosted mtc compiler.
##
## Walks a parsed AST and reports style/correctness warnings, mirroring the Ruby
## linter's AST-only rules (those that need no semantic-analysis facts):
##
##   - self-assignment                (warning)  `x = x`
##   - self-comparison                (warning)  `x == x` / `x != x`
##   - redundant-bool-compare         (hint)     `x == true` and friends
##   - redundant-return               (hint)     final bare `return` in a `-> void` body
##   - useless-expression             (warning)  pure expression statement
##   - duplicate-if-condition         (warning)  duplicate branch condition
##   - noop-compound-assignment       (hint)     `x += 0`, `x *= 1`
##   - redundant-ignored-match-binding (hint)    `as _`
##   - redundant-else                 (hint)     else after branches that all return
##   - event-capacity                 (warning)  event capacity >= 128
##   - trailing-list-comma            (hint)     redundant comma before a call's `)`
##   - doc-tag                        (hint)     malformed / mismatched `## @param` / `## @return`
##   - dead-assignment                (warning)  value assigned is never read
##   - unreachable-code               (warning)  statement after return/fatal
##   - constant-condition             (hint)     `if true` / `while false`
##   - loop-single-iteration          (hint)     loop body always breaks/returns
##   - prefer-own-ptr                 (hint)     ptr[T] binding only used inside unsafe
##   - redundant-cast                 (hint)     cast to same type as declared
##
## The token-based trailing-list-comma pass re-lexes the source and doc-tag
## reads source lines; all others work from the AST alone.
##
## Rule checks are applied after visiting a node's children, matching the Ruby
## visitor's emission order.  The `lint` command renders each warning as
## `path:line: code: message`, so a warning only needs a line, code, message,
## and severity.

import std.vec as vec
import std.string as string
import std.str
import std.map as map_mod
import std.hash

import mtc.parser.ast as ast
import mtc.linter.structural as structural
import mtc.parser.parser as parser
import mtc.parser.state as pstate
import mtc.semantic.analyzer as analyzer
import mtc.semantic.types as types
import mtc.semantic.control_flow.builder as flow_builder
import mtc.semantic.control_flow.graph as flow_graph
import mtc.lexer.lexer as lexer_mod
import mtc.lexer.token as token_mod
import mtc.lexer.token_kinds as tk
import mtc.lexer.trivia as triv
import mtc.formatter.tidy as tidy
import mtc.linter.rules_doc_tag as rules_doc_tag
import mtc.linter.rules_trailing_comma as rules_trailing_comma
import mtc.linter.rules_redundant_else as rules_redundant_else
import mtc.linter.config as lint_config
import mtc.linter.scope_tracking as scope_tracking
import mtc.linter.platform_drift as platform_drift
import mtc.linter.nullcheck as nullcheck
import mtc.linter.own_ptr as own_ptr
import mtc.linter.constprop as constprop
import mtc.linter.redundant_cast as redundant_cast
import mtc.profile as profile_mod


## The host's `Linter::KNOWN_RULE_CODES`, in registry order.  `lint --init`
## emits this list, and rule validation uses the same table.
public function known_rule_codes() -> vec.Vec[str]:
    var codes = vec.Vec[str].create()
    codes.push("borrow-and-mutate")
    codes.push("constant-condition")
    codes.push("dead-assignment")
    codes.push("directional-ffi-arg")
    codes.push("doc-tag")
    codes.push("duplicate-if-condition")
    codes.push("event-capacity")
    codes.push("line-too-long")
    codes.push("loop-single-iteration")
    codes.push("missing-return")
    codes.push("noop-compound-assignment")
    codes.push("owning-release-double")
    codes.push("owning-release-leak")
    codes.push("platform-api-drift")
    codes.push("prefer-conditional-expression")
    codes.push("prefer-inline-if")
    codes.push("prefer-inline-methods")
    codes.push("prefer-is-variant")
    codes.push("prefer-let")
    codes.push("prefer-let-else")
    codes.push("prefer-or-pattern")
    codes.push("prefer-own-ptr")
    codes.push("prefer-struct-with")
    codes.push("prefer-try")
    codes.push("prefer-var-else")
    codes.push("redundant-bool-compare")
    codes.push("redundant-cast")
    codes.push("redundant-else")
    codes.push("redundant-ignored-match-binding")
    codes.push("redundant-null-check")
    codes.push("redundant-return")
    codes.push("redundant-type-annotation")
    codes.push("redundant-unsafe")
    codes.push("reserved-primitive-name")
    codes.push("self-assignment")
    codes.push("self-comparison")
    codes.push("shadow")
    codes.push("trailing-list-comma")
    codes.push("unreachable-code")
    codes.push("unused-import")
    codes.push("unused-local")
    codes.push("unused-param")
    codes.push("useless-expression")
    return codes

## `column` is the 1-based character column of the offending token and
## `length` its character length; both are 0 when the emitting rule does not
## track positions (most rules are line-granular).
public struct Warning:
    path: str
    line: ptr_uint
    column: ptr_uint
    length: ptr_uint
    code: str
    message: str
    severity: str

## The linter's two tiers (the host's `Linter.normalize_lint_tier`): the `full`
## tier runs every rule; `fast` skips the rules the host's `full_tier?` gates
## (the per-body flow rules, the If/Match preference rules, `prefer-struct-with`
## and `doc-tag`).  The CLI and the LSP both pass `full`.
public enum LintTier: ubyte
    fast = 0
    full = 1

## Options for one lint pass — the single funnel the CLI (`check`/`lint`), the
## LSP diagnostics path and the fix engine all go through.
##
## `select`/`ignore` hold explicit (CLI-flag) rule filters and override
## `.mt-lint.yml`; `max_line_length` of 0 means "resolve from the config, else
## the default".  `analysis` carries the semantic facts the type-backed rules
## use (`resolved_expr_types` keyed by expression pointer, `type_alias_types`,
## `resolved_call_kinds`).
public struct LintOptions:
    owning_type_names: span[str]
    unresolved_import_paths: span[str]
    editable_sites: span[analyzer.EditableSite]
    ## Identifier arguments passed to `out`/`inout` foreign parameters (the
    ## analyzer's `mutating_argument_sites`): those bindings are mutated by the
    ## call, so prefer-let must not fire on them.
    mutating_sites: span[analyzer.EditableSite]
    ## Identifier arguments recorded by the array/`str_buffer`→`span` coercion
    ## (the analyzer's `mutable_lvalue_sites`): the callee may write through the
    ## alias, so prefer-let must not fire on them either.
    mutable_lvalue_sites: span[analyzer.EditableSite]
    ## `directional-ffi-arg` sites recorded by the analyzer's call checks: the
    ## linter emits each at its call's visit, in the host's order.
    directional_ffi_sites: span[analyzer.DirectionalFfiSite]
    max_line_length: ptr_uint
    select: span[str]
    ignore: span[str]
    analysis: ptr[analyzer.Analysis]?
    ## One entry per import of the linted file (same order), built from the
    ## loader program's analyses: `unused-import` credits imports whose methods
    ## or hook functions are used indirectly.
    method_providers: span[scope_tracking.ImportMethodProvider]
    ## When set, the pass records per-rule phases into this profile (the
    ## `--timings` breakdown); null runs unprofiled.
    profile: ptr[profile_mod.Profile]?
    ## Which rule set to run (`full` by default, matching the host's CLI/LSP).
    lint_tier: LintTier


## All-default options: no owning types, no unresolved imports, every rule,
## the config's (or the default) line length.
public function default_lint_options() -> LintOptions:
    return LintOptions(
        owning_type_names = span[str](),
        unresolved_import_paths = span[str](),
        editable_sites = span[analyzer.EditableSite](),
        mutating_sites = span[analyzer.EditableSite](),
        mutable_lvalue_sites = span[analyzer.EditableSite](),
        directional_ffi_sites = span[analyzer.DirectionalFfiSite](),
        max_line_length = 0,
        select = span[str](),
        ignore = span[str](),
        analysis = null,
        method_providers = span[scope_tracking.ImportMethodProvider](),
        profile = null,
        lint_tier = LintTier.full,
    )


## Lint a parsed source file with default options, returning warnings in
## source (traversal) order.  `source` is the original text, re-lexed for the
## token-based passes.
public function lint_source(
    file: ast.SourceFile,
    source: str,
    path: str,
    owning_type_names: span[str]
) -> vec.Vec[Warning]:
    var options = default_lint_options()
    options.owning_type_names = owning_type_names
    return lint_source_with(file, source, path, options)


## Lint a parsed source file.  `options.unresolved_import_paths` are the module
## paths whose imports failed to resolve (the LSP hands over the loader's list):
## `unused-import` skips those imports, mirroring Ruby's `Linter`.
## `options.editable_sites` are the receivers of `editable` method calls
## recorded by the analyzer; the scope pass treats those bindings as mutated
## (prefer-let), which needs the analysis because method kinds are not visible
## in the AST.
##
## `.mt-lint.yml` is honored here, exactly like the host's `Linter.lint_source`:
## explicit select/ignore win over the config's lists, the config supplies the
## line-length limit, and `# lint: ignore` comments suppress warnings on the
## same or the preceding line.
public function lint_source_with(
    file: ast.SourceFile,
    source: str,
    path: str,
    options: LintOptions,
) -> vec.Vec[Warning]:
    var warnings = vec.Vec[Warning].create()

    var config = lint_config.load_for_path(path)
    defer: config.release()
    var max_line_length = options.max_line_length
    if max_line_length == 0:
        max_line_length = config.max_line_length
    if max_line_length == 0:
        max_line_length = DEFAULT_MAX_LINE_LENGTH

    # One lex for the token-based rules and the suppression comments.
    var lex_diags = vec.Vec[token_mod.LexDiagnostic].create()
    defer: lex_diags.release()
    var lexed = lexer_mod.lex_with_trivia(source, ref_of(lex_diags))
    var source_lines = vec.Vec[str].create()
    defer: source_lines.release()
    split_source_lines(source, ref_of(source_lines))
    lint_source_lines = ptr_of(source_lines)

    lint_loop_depth = 0
    lint_generic_depth = 0
    lint_unsafe_depth = 0
    lint_analysis = options.analysis
    lint_cast_drained = 0
    lint_owning_type_names = options.owning_type_names
    var cast_ctx = redundant_cast.ctx_create(source, options.analysis)
    defer: redundant_cast.ctx_release(ref_of(cast_ctx))
    lint_cast_ctx = ptr_of(cast_ctx)

    # The scope state the declaration walk drives.  Its entries live in a
    # growable store owned by the scope context, so nesting depth and the
    # per-scope binding count are unbounded; the walk emits the scope warnings
    # where the host's visitor does — `shadow` at each declaration,
    # `unused-local`/`unused-param`/`prefer-let`/`prefer-own-ptr` at each pop.
    var scope = scope_tracking.ctx_create()
    defer: scope_tracking.ctx_release(ref_of(scope))
    scope_tracking.ctx_set_sites(
        ref_of(scope),
        options.editable_sites,
        options.mutating_sites,
        options.mutable_lvalue_sites
    )
    lint_directional_sites = options.directional_ffi_sites
    lint_scope_ctx = ptr_of(scope)
    var ptr_state = own_ptr.PtrState.create()
    defer: ptr_state.release()
    lint_ptr_state = ptr_of(ptr_state)

    # The reserved-primitive-name rename fixes the seed and the declaration
    # walk collect (the host's `@reserved_primitive_name_fixes`).  The collector
    # API moves them out through `lint_reserved_out` instead of releasing them.
    var reserved_fixes = vec.Vec[ReservedNameFix].create()
    var reserved_module_fix = map_mod.Map[str, ptr_uint].create()
    lint_reserved_fixes = ptr_of(reserved_fixes)
    lint_reserved_module_fix = ptr_of(reserved_module_fix)

    # unused-import, before the declaration walk (the host's
    # `check_unused_imports`).
    lint_profile = options.profile
    lint_full_tier = options.lint_tier == LintTier.full
    var unused_imports = vec.Vec[scope_tracking.ScopeWarning].create()
    defer: unused_imports.release()
    let unused_started = lint_profile_mark()
    scope_tracking.lint_unused_imports(
        file,
        path,
        options.unresolved_import_paths,
        options.method_providers,
        options.analysis,
        ref_of(unused_imports)
    )
    lint_profile_done("rule.unused_import", unused_started)
    drain_scope_warnings(ref_of(unused_imports), ref_of(warnings))

    # platform-api-drift, after unused-import and before the declaration walk
    # (the host's `visit_source_file` order).
    if lint_full_tier:
        let drift_started = lint_profile_mark()
        var drift = platform_drift.check_platform_api_drift(file, path, source)
        defer: drift.release()
        var di: ptr_uint = 0
        while di < drift.len():
            let dp = drift.get(di) else:
                break
            di += 1
            unsafe:
                let d = read(dp)
                push_warning_at(warnings, path, d.line, d.column, d.length, d.code, d.message, d.severity)
        lint_profile_done("rule.platform_api_drift", drift_started)

    # Module-level reserved names (the host's `seed_module_bindings`).
    let reserved_started = lint_profile_mark()
    lint_reserved_module_names(file, path, ref_of(warnings))
    lint_profile_done("rule.reserved_primitive_name", reserved_started)

    let walk_started = lint_profile_mark()
    var i: ptr_uint = 0
    while i < file.declarations.len:
        unsafe:
            visit_decl(file.declarations.data + i, path, ref_of(warnings))
        i += 1
    lint_profile_done("visit_decl", walk_started)
    lint_scope_ctx = null
    lint_ptr_state = null
    lint_cast_ctx = null
    lint_source_lines = null
    lint_reserved_fixes = null
    lint_reserved_module_fix = null
    reserved_module_fix.release()
    if lint_reserved_out != null:
        # The collector takes the fixes (the caller releases them).
        unsafe:
            read(lint_reserved_out) = reserved_fixes
        lint_reserved_out = null
    else:
        release_reserved_name_fixes(ref_of(reserved_fixes))

    # Whole-file passes run after the walk, matching Ruby's emission order.
    # `doc-tag` is full-tier only (the host's `emit_doc_tag_warnings` gate).
    if lint_full_tier:
        let doc_tag_started = lint_profile_mark()
        rules_doc_tag.lint_doc_tags(file.declarations, source, path, ref_of(warnings))
        lint_profile_done("rule.doc_tag", doc_tag_started)
    let events_started = lint_profile_mark()
    lint_events(file.declarations, "", path, ref_of(warnings))
    lint_profile_done("rule.event_capacity", events_started)
    let commas_started = lint_profile_mark()
    rules_trailing_comma.lint_trailing_commas(file.declarations, lexed.tokens.as_span(), path, ref_of(warnings))
    lint_profile_done("rule.trailing_list_comma", commas_started)
    let inline_methods_started = lint_profile_mark()
    lint_prefer_inline_methods(file.declarations, path, ref_of(warnings))
    lint_profile_done("rule.prefer_inline_methods", inline_methods_started)
    let line_long_started = lint_profile_mark()
    lint_line_too_long(source, lexed.tokens, path, max_line_length, ref_of(warnings))
    lint_profile_done("rule.line_too_long", line_long_started)

    # `# lint: ignore` / `# lint: ignore(a, b)` comments, then the rule filter.
    apply_suppressions(ref_of(warnings), source, lexed.trivia.as_span())
    lexed.tokens.release()
    lexed.trivia.release()
    filter_rules(ref_of(warnings), options, ref_of(config))
    lint_profile = null
    return warnings

# =============================================================================
#  Rule filtering and `# lint: ignore` suppressions (host `linter.rb`)
# =============================================================================

## Keep only warnings the effective select/ignore lists allow.  Explicit
## option lists win over the config's (the host's `select ||= cfg[:select]`).
function filter_rules(
    warnings: ref[vec.Vec[Warning]],
    options: LintOptions,
    config: ref[lint_config.LintConfig]
) -> void:
    var lint_cfg = unsafe: read(config)
    var select = vec.Vec[str].create()
    defer: select.release()
    var ignore = vec.Vec[str].create()
    defer: ignore.release()

    if options.select.len > 0:
        var i: ptr_uint = 0
        while i < options.select.len:
            unsafe:
                select.push(read(options.select.data + i))
            i += 1
    else if lint_cfg.has_select:
        var i: ptr_uint = 0
        while i < lint_cfg.select.len():
            let cp = lint_cfg.select.get(i) else:
                break
            unsafe:
                select.push(read(cp).as_str())
            i += 1

    if options.ignore.len > 0:
        var i: ptr_uint = 0
        while i < options.ignore.len:
            unsafe:
                ignore.push(read(options.ignore.data + i))
            i += 1
    else if lint_cfg.has_ignore:
        var i: ptr_uint = 0
        while i < lint_cfg.ignore.len():
            let cp = lint_cfg.ignore.get(i) else:
                break
            unsafe:
                ignore.push(read(cp).as_str())
            i += 1

    if select.len() == 0 and ignore.len() == 0:
        return

    var kept = vec.Vec[Warning].create()
    var i: ptr_uint = 0
    while i < warnings.len():
        let wp = warnings.get(i) else:
            break
        unsafe:
            let w = read(wp)
            if warning_allowed(w.code, ref_of(select), ref_of(ignore)):
                kept.push(w)
        i += 1
    warnings.release()
    unsafe:
        read(warnings) = kept


## One rule code's verdict: `ignore` rejects, a non-empty `select` restricts.
function warning_allowed(code: str, select: ref[vec.Vec[str]], ignore: ref[vec.Vec[str]]) -> bool:
    if code_list_contains(code, ignore):
        return false
    if select.len() > 0 and not code_list_contains(code, select):
        return false
    return true


function code_list_contains(code: str, codes: ref[vec.Vec[str]]) -> bool:
    var i: ptr_uint = 0
    while i < codes.len():
        let cp = codes.get(i) else:
            break
        unsafe:
            if read(cp).equal(code):
                return true
        i += 1
    return false

struct Suppression:
    line: ptr_uint
    all: bool
    codes: vec.Vec[string.String]

struct SuppressionBody:
    all: bool
    codes: vec.Vec[string.String]


## Drop warnings carrying a `# lint: ignore` suppression on their own line or
## the line before them (the host's `apply_suppressions`).
function apply_suppressions(warnings: ref[vec.Vec[Warning]], source: str, trivia: span[triv.TriviaEntry]) -> void:
    if not source.contains_substring("lint:"):
        return
    var suppressions = collect_suppressions(source, trivia)
    defer: release_suppressions(ref_of(suppressions))
    if suppressions.len() == 0:
        return

    var kept = vec.Vec[Warning].create()
    var i: ptr_uint = 0
    while i < warnings.len():
        let wp = warnings.get(i) else:
            break
        unsafe:
            let w = read(wp)
            var suppressed = false
            var si: ptr_uint = 0
            while si < suppressions.len():
                let sp = suppressions.get(si) else:
                    break
                var s = read(sp)
                if s.line == w.line or (w.line > 0 and s.line + 1 == w.line):
                    if s.all or string_list_contains(w.code, ref_of(s.codes)):
                        suppressed = true
                        break
                si += 1
            if not suppressed:
                kept.push(w)
        i += 1
    warnings.release()
    unsafe:
        read(warnings) = kept


function collect_suppressions(source: str, trivia: span[triv.TriviaEntry]) -> vec.Vec[Suppression]:
    var result = vec.Vec[Suppression].create()
    var i: ptr_uint = 0
    while i < trivia.len:
        unsafe:
            let t = read(trivia.data + i)
            if t.kind == triv.TriviaKind.comment:
                let text = source.slice(t.start_offset, t.end_offset - t.start_offset)
                match parse_suppression(text):
                    Option.some as body:
                        result.push(Suppression(line = t.line, all = body.value.all, codes = body.value.codes))
                    Option.none:
                        pass
        i += 1
    return result


## `# lint: ignore` (all rules) or `# lint: ignore(a, b)` (those codes), after
## leading whitespace — the host's two `parse_suppressions` regexes.
function parse_suppression(text: str) -> Option[SuppressionBody]:
    var t = text.trim_ascii_whitespace()
    if t.len == 0 or t.byte_at(0) != '#':
        return Option[SuppressionBody].none
    var rest = t.slice(1, t.len - 1)
    rest = skip_spaces(rest)
    if not rest.starts_with("lint:"):
        return Option[SuppressionBody].none
    rest = skip_spaces(rest.slice(5, rest.len - 5))
    if not rest.starts_with("ignore"):
        return Option[SuppressionBody].none
    rest = rest.slice(6, rest.len - 6)
    if rest.len == 0:
        return Option[SuppressionBody].some(value = SuppressionBody(
            all = true,
            codes = vec.Vec[string.String].create()
        ))
    if rest.len >= 3 and rest.byte_at(0) == '(' and rest.byte_at(rest.len - 1) == ')':
        let inner = rest.slice(1, rest.len - 2)
        var codes = vec.Vec[string.String].create()
        var start: ptr_uint = 0
        var i: ptr_uint = 0
        while i <= inner.len:
            if i == inner.len or inner.byte_at(i) == ',':
                let item = inner.slice(start, i - start).trim_ascii_whitespace()
                if item.len == 0:
                    release_strings(ref_of(codes))
                    return Option[SuppressionBody].none
                codes.push(string.String.from_str(item))
                start = i + 1
            i += 1
        if codes.len() == 0:
            release_strings(ref_of(codes))
            return Option[SuppressionBody].none
        return Option[SuppressionBody].some(value = SuppressionBody(all = false, codes = codes))
    return Option[SuppressionBody].none


function skip_spaces(text: str) -> str:
    var i: ptr_uint = 0
    while i < text.len:
        let b = text.byte_at(i)
        if b != ' ' and b != '\t':
            break
        i += 1
    return text.slice(i, text.len - i)


function string_list_contains(code: str, codes: ref[vec.Vec[string.String]]) -> bool:
    var i: ptr_uint = 0
    while i < codes.len():
        let cp = codes.get(i) else:
            break
        unsafe:
            if read(cp).as_str().equal(code):
                return true
        i += 1
    return false


function release_suppressions(suppressions: ref[vec.Vec[Suppression]]) -> void:
    var i: ptr_uint = 0
    while i < suppressions.len():
        let sp = suppressions.get(i) else:
            break
        unsafe:
            var s = read(sp)
            release_strings(ref_of(s.codes))
        i += 1
    suppressions.release()


function release_strings(strings: ref[vec.Vec[string.String]]) -> void:
    var i: ptr_uint = 0
    while i < strings.len():
        let sp = strings.get(i) else:
            break
        unsafe:
            read(sp).release()
        i += 1
    strings.release()

# =============================================================================
#  prefer-inline-methods — `extending X:` blocks whose receiver struct is
#  declared in the same file (the methods can be written inline inside the
#  struct body, which desugars to the identical block).
# =============================================================================

function lint_prefer_inline_methods(decls: span[ast.Decl], path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    var struct_names = vec.Vec[str].create()
    defer: struct_names.release()
    var i: ptr_uint = 0
    while i < decls.len:
        unsafe:
            match read(decls.data + i):
                ast.Decl.decl_struct as s:
                    struct_names.push(s.name)
                _:
                    pass
        i += 1
    if struct_names.len() == 0:
        return

    i = 0
    while i < decls.len:
        unsafe:
            match read(decls.data + i):
                ast.Decl.decl_extending_block as ex:
                    if not ex.is_inline:
                        let tr = read(ex.type_name)
                        if tr.name.parts.len == 1 and tr.arguments.len == 0:
                            let name = read(tr.name.parts.data)
                            if rules_doc_tag.names_contains(ref_of(struct_names), name):
                                # The message buffer is intentionally leaked: the
                                # warning borrows its bytes (the linter's
                                # convention for stored messages).
                                var msg = string.String.create()
                                msg.append("methods on '")
                                msg.append(name)
                                msg.append("' can be written inline inside the struct declaration")
                                push_warning_at(
                                    warnings,
                                    path,
                                    ex.line,
                                    ex.column,
                                    name.len,
                                    "prefer-inline-methods",
                                    msg.as_str(),
                                    "hint"
                                )
                _:
                    pass
        i += 1

## Enclosing loop depth for the visitor — the host's `@loop_depth`, which
## suppresses the conciseness hints that would rewrite a loop body.
var lint_loop_depth: ptr_uint = 0

## Enclosing generic-body depth for the visitor — the host's
## `generic_function_context?` (`redundant-unsafe` skips those bodies: their
## required-unsafe facts are only complete once instantiated elsewhere).
var lint_generic_depth: ptr_uint = 0

## The analysis the visitor consults for facts-dependent rules (the host's
## `@sema_facts`) — currently `redundant-unsafe`'s required-unsafe lines.
var lint_analysis: ptr[analyzer.Analysis]? = null

## The scope state the declaration walk drives (the host's `@scopes` and
## `@module_bindings`): `null` outside a lint pass, and `null` for callers
## that only run a sub-rule.
var lint_scope_ctx: ptr[scope_tracking.ScopeContext]? = null

## prefer-own-ptr's walk state (the host's `@ptr_candidates` and
## `@binding_ptr_unsafe_uses`): candidates by name, uses counted at every
## identifier; the warning fires at a scope pop.
var lint_ptr_state: ptr[own_ptr.PtrState]? = null

## Enclosing `unsafe:` depth for the visitor (the host's `@unsafe_depth`):
## prefer-own-ptr counts identifier uses above it.
var lint_unsafe_depth: ptr_uint = 0

## redundant-cast's check context for the walk (the host checks each site
## inline, so the module's whole-file walk is gone).
var lint_cast_ctx: ptr[redundant_cast.Context]? = null

## How many of `lint_cast_ctx.diags` have already been emitted.
var lint_cast_drained: ptr_uint = 0

## The owning type names the ownership rule reports releases for (the caller's
## `LintOptions.owning_type_names`); the walk needs them per body.
var lint_owning_type_names: span[str] = span[str]()

## The file's source lines (the host's `@source_lines`), for the source-line
## spans the rules anchor on.  `null` outside a lint pass.
var lint_source_lines: ptr[vec.Vec[str]]? = null

## The `--timings` profile a lint pass records into (the caller's
## `LintOptions.profile`); null outside a profiled pass.
var lint_profile: ptr[profile_mod.Profile]? = null

## The active lint tier (the host's `full_tier?`): set by `lint_source_with`
## from the options; the walk's gated rules read it.
var lint_full_tier: bool = true

## The analyzer-recorded `directional-ffi-arg` sites (emitted at each call's
## visit so they interleave with the host's expression warnings).
var lint_directional_sites: span[analyzer.DirectionalFfiSite] = span[analyzer.DirectionalFfiSite]()


## A phase start for the profile (0 when not profiling, so instrumented sites
## pay nothing).
function lint_profile_mark() -> double:
    if lint_profile == null:
        return 0.0
    return profile_mod.now_ms()


## Record the phase `name` started at `mark`.
function lint_profile_done(name: str, mark: double) -> void:
    if lint_profile != null:
        profile_mod.record(lint_profile, name, profile_mod.now_ms() - mark)


## The host's `check_redundant_unsafe`: an `unsafe:` block or expression whose
## line the analyzer never recorded as *required* has nothing to do.
function check_redundant_unsafe(line: ptr_uint, column: ptr_uint, path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    if lint_generic_depth > 0:
        return
    let ap = lint_analysis else:
        return
    let lines = unsafe: read(ap).unsafe_statement_lines
    var i: ptr_uint = 0
    while i < lines.len():
        let lp = lines.get(i) else:
            break
        if unsafe: read(lp) == line:
            return
        i += 1
    push_warning_at(
        warnings,
        path,
        line,
        column,
        6,
        "redundant-unsafe",
        "unsafe block contains no unsafe operations and can be removed",
        "hint"
    )

const EVENT_CAPACITY_THRESHOLD: int = 128


## Warn on event declarations whose capacity forces emit() to copy a large
## listener array onto the stack.  Recurses into struct and nested-struct
## events, in declaration order (after the AST-visitor warnings).
function lint_events(decls: span[ast.Decl], owner: str, path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    var i: ptr_uint = 0
    while i < decls.len:
        unsafe:
            match read(decls.data + i):
                ast.Decl.decl_event as ev:
                    if ev.capacity >= EVENT_CAPACITY_THRESHOLD:
                        warn_event_capacity(ev.name, owner, ev.capacity, ev.line, path, warnings)
                ast.Decl.decl_struct as s:
                    lint_events(s.struct_events, s.name, path, warnings)
                    lint_events(s.nested_types, s.name, path, warnings)
                _:
                    pass
        i += 1


function warn_event_capacity(
    name: str,
    owner: str,
    capacity: int,
    line: ptr_uint,
    path: str,
    warnings: ref[vec.Vec[Warning]]
) -> void:
    var label = string.String.create()
    defer: label.release()
    if owner.len > 0:
        label.append(owner)
        label.append(".")
    label.append(name)
    var cap = int_to_decimal(capacity)
    defer: cap.release()
    let cap_s = cap.as_str()
    var msg = string.String.create()
    msg.append("event '")
    msg.append(label.as_str())
    msg.append("' capacity ")
    msg.append(cap_s)
    msg.append(" makes emit() copy up to ")
    msg.append(cap_s)
    msg.append(" listeners onto the stack; prefer a smaller fixed capacity or a managed queue abstraction")
    push_warning(warnings, path, line, "event-capacity", msg.as_str(), "warning")


function int_to_decimal(n: int) -> string.String:
    if n <= 0:
        return string.String.from_str("0")
    var digits = string.String.create()
    defer: digits.release()
    var v = n
    while v > 0:
        digits.push_byte(ubyte<-(48 + (v % 10)))
        v = v / 10
    var result = string.String.create()
    let ds = digits.as_str()
    var i = ds.len
    while i > 0:
        result.push_byte(ds.byte_at(i - 1))
        i -= 1
    return result


## Split the source into its lines (the host's `@source_lines`), each without
## its trailing newline.
function split_source_lines(source: str, sink: ref[vec.Vec[str]]) -> void:
    var start: ptr_uint = 0
    var i: ptr_uint = 0
    while i <= source.len:
        if i == source.len:
            sink.push(source.slice(start, i - start))
            break
        if source.byte_at(i) == 10:
            sink.push(source.slice(start, i - start))
            start = i + 1
        i += 1


public function push_warning(
    warnings: ref[vec.Vec[Warning]],
    path: str,
    line: ptr_uint,
    code: str,
    message: str,
    severity: str
) -> void:
    push_warning_at(warnings, path, line, 0, 0, code, message, severity)


## Like push_warning but extracts line and column from an AST expression.
function push_warning_expr(
    warnings: ref[vec.Vec[Warning]],
    path: str,
    expr: ptr[ast.Expr]?,
    code: str,
    message: str,
    severity: str
) -> void:
    let line = expression_line(expr)
    push_warning_at(warnings, path, line, expression_column(expr), 0, code, message, severity)


## Like push_warning but uses a statement's line and column position.
function push_warning_stmt(
    warnings: ref[vec.Vec[Warning]],
    path: str,
    line: ptr_uint,
    col: ptr_uint,
    code: str,
    message: str,
    severity: str
) -> void:
    push_warning_at(warnings, path, line, col, 0, code, message, severity)


public function push_warning_at(
    warnings: ref[vec.Vec[Warning]],
    path: str,
    line: ptr_uint,
    column: ptr_uint,
    length: ptr_uint,
    code: str,
    message: str,
    severity: str,
) -> void:
    warnings.push(Warning(
        path = path,
        line = line,
        column = column,
        length = length,
        code = code,
        message = message,
        severity = severity
    ))

# =============================================================================
#  Line resolution — descend to the first sub-expression that carries a line.
# =============================================================================

## The expression node's own `line` field, with no fallback into its children —
## the host reads `scrutinee.line` directly, so a node kind that carries no line
## (a call, binary, literal, …) reports 0 and the warning renders with no
## position (`path:: code: message`).
function expression_declared_line(expr: ptr[ast.Expr]?) -> ptr_uint:
    let ep = expr else:
        return 0
    unsafe:
        match read(ep):
            ast.Expr.expr_identifier as id:
                return id.line
            ast.Expr.expr_char_literal as ch:
                return ch.line
            ast.Expr.expr_member_access as m:
                return m.line
            ast.Expr.expr_match as mm:
                return mm.line
            ast.Expr.expr_null_literal as nl:
                return nl.line
            ast.Expr.expr_detach as dt:
                return dt.line
            ast.Expr.expr_expression_list as el:
                return el.line
            ast.Expr.expr_range as rg:
                return rg.line
            ast.Expr.expr_prefix_cast as pc:
                return pc.line
            ast.Expr.expr_unsafe as us:
                return us.line
            ast.Expr.expr_error as er:
                return er.line
            _:
                return 0


public function expression_line(expr: ptr[ast.Expr]?) -> ptr_uint:
    let ep = expr else:
        return 0
    unsafe:
        match read(ep):
            ast.Expr.expr_identifier as id:
                return id.line
            ast.Expr.expr_char_literal as ch:
                return ch.line
            ast.Expr.expr_member_access as m:
                return m.line
            ast.Expr.expr_match as mm:
                return mm.line
            ast.Expr.expr_null_literal as nl:
                return nl.line
            ast.Expr.expr_detach as dt:
                return dt.line
            ast.Expr.expr_expression_list as el:
                return el.line
            ast.Expr.expr_range as rg:
                return rg.line
            ast.Expr.expr_prefix_cast as pc:
                return pc.line
            ast.Expr.expr_unsafe as us:
                return us.line
            ast.Expr.expr_error as er:
                return er.line
            ast.Expr.expr_binary_op as b:
                let l = expression_line(b.left)
                if l != 0:
                    return l
                return expression_line(b.right)
            ast.Expr.expr_unary_op as u:
                return expression_line(u.operand)
            ast.Expr.expr_call as call:
                return expression_line(call.callee)
            ast.Expr.expr_index_access as ix:
                let l = expression_line(ix.receiver)
                if l != 0:
                    return l
                return expression_line(ix.index)
            ast.Expr.expr_specialization as sp:
                return expression_line(sp.callee)
            ast.Expr.expr_if as iff:
                let l = expression_line(iff.condition)
                if l != 0:
                    return l
                return expression_line(iff.then_expr)
            ast.Expr.expr_await as aw:
                return expression_line(aw.expression)
            _:
                return 0


public function expression_column(expr: ptr[ast.Expr]?) -> ptr_uint:
    let ep = expr else:
        return 0
    unsafe:
        match read(ep):
            ast.Expr.expr_identifier as id:
                return id.column
            ast.Expr.expr_char_literal as ch:
                return ch.column
            ast.Expr.expr_member_access as m:
                # The host checks the node's own `column` first, and its parser
                # stamps a member access with the *member* token's position.
                if m.column > 0:
                    return m.column
                return expression_column(m.receiver)
            ast.Expr.expr_match as mm:
                return mm.column
            ast.Expr.expr_null_literal as nl:
                return nl.column
            ast.Expr.expr_detach as dt:
                return dt.column
            ast.Expr.expr_expression_list as el:
                return el.column
            ast.Expr.expr_range as rg:
                return rg.column
            ast.Expr.expr_prefix_cast as pc:
                return pc.column
            ast.Expr.expr_unsafe as us:
                return us.column
            ast.Expr.expr_error as er:
                return er.column
            ast.Expr.expr_binary_op as b:
                let l = expression_column(b.left)
                if l != 0:
                    return l
                return expression_column(b.right)
            ast.Expr.expr_unary_op as u:
                return expression_column(u.operand)
            ast.Expr.expr_call as call:
                return expression_column(call.callee)
            ast.Expr.expr_index_access as ix:
                return expression_column(ix.receiver)
            ast.Expr.expr_specialization as sp:
                return expression_column(sp.callee)
            ast.Expr.expr_if as iff:
                let c = expression_column(iff.condition)
                if c != 0:
                    return c
                return expression_column(iff.then_expr)
            ast.Expr.expr_await as aw:
                return expression_column(aw.expression)
            _:
                return 0


## The host's `statement_column`: a statement's own anchor column, with the
## same structural fallbacks the host uses when a kind carries none.
function statement_column(stmt: ptr[ast.Stmt]) -> ptr_uint:
    unsafe:
        match read(stmt):
            ast.Stmt.stmt_local as loc:
                return loc.column
            ast.Stmt.stmt_assignment as a:
                return a.column
            ast.Stmt.stmt_if as iff:
                if iff.branches.len > 0:
                    let br = read(iff.branches.data + 0)
                    if br.column > 0:
                        return br.column
                return iff.else_column
            ast.Stmt.stmt_while as w:
                return w.column
            ast.Stmt.stmt_for as f:
                return f.column
            ast.Stmt.stmt_match as m:
                return m.column
            ast.Stmt.stmt_ret as r:
                return r.column
            ast.Stmt.stmt_defer as d:
                return d.column
            ast.Stmt.stmt_unsafe as u:
                return u.column
            ast.Stmt.stmt_expression as e:
                let col = expression_column(e.expression)
                if col != 0:
                    return col
                # The host's source fallback: the first non-space column.
                match source_code_line(e.line):
                    Option.some as text:
                        let line_text = text.value
                        var i: ptr_uint = 0
                        while i < line_text.len and (line_text.byte_at(i) == 32 or line_text.byte_at(i) == 9):
                            i += 1
                        return if i < line_text.len: i + 1 else: 0
                    Option.none:
                        return 0
            ast.Stmt.stmt_when as wn:
                return wn.column
            ast.Stmt.stmt_error_block as eb:
                return eb.column
            _:
                return 0


## The host's `statement_length`: the statement's own recorded length (the
## parser stamps `return`/`while` with their keyword), else the kind's fallback.
function statement_length(stmt: ptr[ast.Stmt]) -> ptr_uint:
    unsafe:
        match read(stmt):
            ast.Stmt.stmt_local as loc:
                return loc.name.len
            ast.Stmt.stmt_if as iff:
                if iff.branches.len > 0:
                    let br = read(iff.branches.data + 0)
                    if br.length > 0:
                        return br.length
                return if iff.else_column > 0: 4 else: 1
            ast.Stmt.stmt_while as w:
                if w.length > 0:
                    return w.length
                return expression_length(w.condition)
            ast.Stmt.stmt_for as f:
                if f.bindings.len > 0:
                    return read(f.bindings.data + 0).name.len
                return 1
            ast.Stmt.stmt_match as m:
                return expression_length(m.scrutinee)
            ast.Stmt.stmt_ret as r:
                if r.length > 0:
                    return r.length
                return expression_length(r.value)
            ast.Stmt.stmt_expression as e:
                return expression_length(e.expression)
            _:
                return 1


## A binary expression's length, the host's `expression_length` rule: from the
## left operand's column to the end of the right operand.
function binary_expression_length(left: ptr[ast.Expr], right: ptr[ast.Expr]) -> ptr_uint:
    let left_col = expression_column(left)
    let right_col = expression_column(right)
    if left_col > 0 and right_col > 0:
        return (right_col + expression_length(right)) - left_col
    return 1


## The host's `expression_length`: an identifier is its name, a literal its
## lexeme, a binary expression the distance from its left operand's column to
## the right operand's end, and anything else one column.
function expression_length(expr: ptr[ast.Expr]?) -> ptr_uint:
    let ep = expr else:
        return 1
    unsafe:
        match read(ep):
            ast.Expr.expr_identifier as id:
                return id.name.len
            ast.Expr.expr_integer_literal as il:
                return il.lexeme.len
            ast.Expr.expr_float_literal as fl:
                return fl.lexeme.len
            ast.Expr.expr_string_literal as sl:
                return sl.lexeme.len
            ast.Expr.expr_bool_literal as bl:
                return if bl.value: 4 else: 5
            ast.Expr.expr_null_literal:
                return 4
            ast.Expr.expr_binary_op as b:
                return binary_expression_length(b.left, b.right)
            ast.Expr.expr_unary_op as u:
                return expression_length(u.operand)
            ast.Expr.expr_specialization as sp:
                return expression_length(sp.callee)
            ast.Expr.expr_call as call:
                return expression_length(call.callee)
            ast.Expr.expr_await as aw:
                return expression_length(aw.expression)
            ast.Expr.expr_unsafe as un:
                return expression_length(un.expression)
            _:
                return 1

# =============================================================================
#  Rules
# =============================================================================

function is_identifier(expr: ptr[ast.Expr]) -> Option[str]:
    unsafe:
        match read(expr):
            ast.Expr.expr_identifier as id:
                return Option[str].some(value = id.name)
            _:
                return Option[str].none


function bool_literal_of(expr: ptr[ast.Expr]) -> Option[bool]:
    unsafe:
        match read(expr):
            ast.Expr.expr_bool_literal as b:
                return Option[bool].some(value = b.value)
            _:
                return Option[bool].none


## `x = x` — a variable assigned to itself.
function check_self_assignment(
    target: ptr[ast.Expr],
    operator: str,
    value: ptr[ast.Expr],
    path: str,
    warnings: ref[vec.Vec[Warning]]
) -> void:
    if operator != "=":
        return
    let target_name = is_identifier(target) else:
        return
    let value_name = is_identifier(value) else:
        return
    if not target_name.equal(value_name):
        return
    var buf = string.String.create()
    buf.append("'")
    buf.append(target_name)
    buf.append("' is assigned to itself")
    push_warning(warnings, path, expression_line(target), "self-assignment", buf.as_str(), "warning")


## `x == x` / `x != x` — a variable compared to itself.
function check_self_comparison(
    operator: str,
    left: ptr[ast.Expr],
    right: ptr[ast.Expr],
    path: str,
    warnings: ref[vec.Vec[Warning]]
) -> void:
    if operator != "==" and operator != "!=":
        return
    let left_name = is_identifier(left) else:
        return
    let right_name = is_identifier(right) else:
        return
    if not left_name.equal(right_name):
        return
    let always = if operator == "==": "always true" else: "always false"
    var buf = string.String.create()
    buf.append("'")
    buf.append(left_name)
    buf.append("' is compared to itself — ")
    buf.append(always)
    # The host anchors the warning on the whole binary expression
    # (`expression_line/column/length` of the comparison).
    push_warning_at(
        warnings,
        path,
        expression_line(left),
        expression_column(left),
        binary_expression_length(left, right),
        "self-comparison",
        buf.as_str(),
        "warning"
    )


## `x == true` / `x != false` and friends — comparison against a boolean literal.
function check_redundant_bool_compare(
    operator: str,
    left: ptr[ast.Expr],
    right: ptr[ast.Expr],
    path: str,
    warnings: ref[vec.Vec[Warning]]
) -> void:
    if operator != "==" and operator != "!=":
        return
    let left_bool = bool_literal_of(left)
    let right_bool = bool_literal_of(right)
    # Exactly one side must be a boolean literal.
    if left_bool.is_some() == right_bool.is_some():
        return

    let literal_value = if left_bool.is_some(): left_bool.unwrap() else: right_bool.unwrap()
    var use_directly = false
    if operator == "==":
        use_directly = literal_value
    else:
        use_directly = not literal_value
    let suggestion = if use_directly: "use the expression directly" else: "invert the expression with 'not'"

    var buf = string.String.create()
    buf.append("boolean comparison against literal is redundant; ")
    buf.append(suggestion)
    let line = if left_bool.is_some(): expression_line(right) else: expression_line(left)
    push_warning(warnings, path, line, "redundant-bool-compare", buf.as_str(), "hint")


## A pure expression statement with no side effects has a useless result.
function is_pure_expr(expr: ptr[ast.Expr]) -> bool:
    unsafe:
        match read(expr):
            ast.Expr.expr_integer_literal:
                return true
            ast.Expr.expr_float_literal:
                return true
            ast.Expr.expr_string_literal:
                return true
            ast.Expr.expr_format_string:
                return true
            ast.Expr.expr_bool_literal:
                return true
            ast.Expr.expr_null_literal:
                return true
            ast.Expr.expr_binary_op:
                return true
            ast.Expr.expr_unary_op:
                return true
            ast.Expr.expr_identifier:
                return true
            ast.Expr.expr_unsafe:
                return true
            _:
                return false


## True when `expr` contains a call, await, or `?` propagation — mirrors the
## Ruby `contains_side_effecting_expression?` (note: it does NOT descend into a
## plain unary operand).
function contains_side_effect(expr: ptr[ast.Expr]) -> bool:
    unsafe:
        match read(expr):
            ast.Expr.expr_call:
                return true
            ast.Expr.expr_await:
                return true
            ast.Expr.expr_unary_op as u:
                return u.operator == "?"
            ast.Expr.expr_binary_op as b:
                if contains_side_effect(b.left):
                    return true
                return contains_side_effect(b.right)
            ast.Expr.expr_unsafe as us:
                return contains_side_effect(us.expression)
            ast.Expr.expr_format_string as fs:
                var i: ptr_uint = 0
                while i < fs.parts.len:
                    match read(fs.parts.data + i):
                        ast.FormatStringPart.fmt_expr as fe:
                            if contains_side_effect(fe.expression):
                                return true
                        _:
                            pass
                    i += 1
                return false
            _:
                return false


function check_useless_expr(
    expr: ptr[ast.Expr],
    stmt_line: ptr_uint,
    path: str,
    warnings: ref[vec.Vec[Warning]]
) -> void:
    if not is_pure_expr(expr):
        return
    unsafe:
        match read(expr):
            ast.Expr.expr_unary_op as u:
                if u.operator == "?":
                    return
            _:
                pass
    if contains_side_effect(expr):
        return
    var line = expression_line(expr)
    if line == 0:
        line = stmt_line
    push_warning(
        warnings,
        path,
        line,
        "useless-expression",
        "expression result is unused and has no side effects",
        "warning"
    )


## The column of an if-chain's first branch (the `if` keyword) — the host's
## `statement.branches.first&.column`, its anchor for the conciseness hints.
function first_branch_column(branches: span[ast.IfBranch]) -> ptr_uint:
    if branches.len == 0:
        return 0
    return unsafe: read(branches.data + 0).column


## Compound assignment against an identity value (`x += 0`, `x *= 1`).
function check_noop_compound_assignment(
    line: ptr_uint,
    target: ptr[ast.Expr],
    operator: str,
    value: ptr[ast.Expr],
    path: str,
    warnings: ref[vec.Vec[Warning]]
) -> void:
    var is_identity = false
    if (
        operator == "+="
        or operator == "-="
        or operator == "|="
        or operator == "^="
        or operator == "<<="
        or operator == ">>="
    ):
        is_identity = integer_literal_matches(value, "0")
    else if operator == "*=" or operator == "/=":
        is_identity = numeric_literal_one(value)
    if is_identity:
        # The host anchors on the assignment's line and the target's column, with
        # the target identifier's own length.
        push_warning_at(
            warnings,
            path,
            line,
            expression_column(target),
            expression_length(target),
            "noop-compound-assignment",
            "compound assignment with identity value has no effect",
            "hint"
        )


function lexeme_without_underscores(lexeme: str) -> string.String:
    var b = string.String.create()
    var i: ptr_uint = 0
    while i < lexeme.len:
        let c = lexeme.byte_at(i)
        if c != 95:
            b.push_byte(c)
        i += 1
    return b


function integer_literal_matches(value: ptr[ast.Expr], target: str) -> bool:
    unsafe:
        match read(value):
            ast.Expr.expr_integer_literal as il:
                var stripped = lexeme_without_underscores(il.lexeme)
                defer: stripped.release()
                return stripped.as_str().equal(target)
            _:
                return false


function numeric_literal_one(value: ptr[ast.Expr]) -> bool:
    if integer_literal_matches(value, "1"):
        return true
    unsafe:
        match read(value):
            ast.Expr.expr_float_literal as fl:
                var stripped = lexeme_without_underscores(fl.lexeme)
                defer: stripped.release()
                let s = stripped.as_str()
                return s.equal("1.0") or s.equal("1.")
            _:
                return false


## Duplicate condition across the branches of one if/else-if chain.
function check_duplicate_if_conditions(
    branches: span[ast.IfBranch],
    path: str,
    warnings: ref[vec.Vec[Warning]]
) -> void:
    var seen = vec.Vec[str].create()
    defer: seen.release()
    var bi: ptr_uint = 0
    while bi < branches.len:
        unsafe:
            let br = read(branches.data + bi)
            match expression_signature(br.condition):
                Option.some as sig:
                    var dup = false
                    var k: ptr_uint = 0
                    while k < seen.len():
                        let sp = seen.get(k) else:
                            break
                        if read(sp).equal(sig.value):
                            dup = true
                            break
                        k += 1
                    if dup:
                        var line = expression_line(br.condition)
                        if line == 0:
                            line = br.line
                        push_warning_at(
                            warnings, path, line,
                            expression_column(br.condition),
                            expression_length(br.condition),
                            "duplicate-if-condition",
                            "duplicate condition matches an earlier if/else-if branch and is unreachable",
                            "warning",
                        )
                    else:
                        seen.push(sig.value)
                Option.none:
                    pass
        bi += 1


## A structural signature string for a condition, used to detect duplicate
## branches.  None for expressions the signature does not model.
function expression_signature(expr: ptr[ast.Expr]) -> Option[str]:
    unsafe:
        match read(expr):
            ast.Expr.expr_identifier as id:
                var b = string.String.create()
                b.append("id:")
                b.append(id.name)
                return Option[str].some(value = b.as_str())
            ast.Expr.expr_bool_literal as bl:
                var b = string.String.create()
                b.append("bool:")
                b.append(if bl.value: "true" else: "false")
                return Option[str].some(value = b.as_str())
            ast.Expr.expr_integer_literal as il:
                var b = string.String.create()
                b.append("lit:")
                b.append(il.lexeme)
                return Option[str].some(value = b.as_str())
            ast.Expr.expr_float_literal as fl:
                var b = string.String.create()
                b.append("lit:")
                b.append(fl.lexeme)
                return Option[str].some(value = b.as_str())
            ast.Expr.expr_string_literal as sl:
                var b = string.String.create()
                b.append("lit:")
                b.append(sl.lexeme)
                return Option[str].some(value = b.as_str())
            ast.Expr.expr_null_literal:
                return Option[str].some(value = "null")
            ast.Expr.expr_member_access as m:
                let recv = expression_signature(m.receiver) else:
                    return Option[str].none
                var b = string.String.create()
                b.append("member:(")
                b.append(recv)
                b.append(").")
                b.append(m.member_name)
                return Option[str].some(value = b.as_str())
            ast.Expr.expr_unary_op as u:
                let operand = expression_signature(u.operand) else:
                    return Option[str].none
                var b = string.String.create()
                b.append("unary:")
                b.append(u.operator)
                b.append("(")
                b.append(operand)
                b.append(")")
                return Option[str].some(value = b.as_str())
            ast.Expr.expr_binary_op as bo:
                let l = expression_signature(bo.left) else:
                    return Option[str].none
                let r = expression_signature(bo.right) else:
                    return Option[str].none
                var b = string.String.create()
                b.append("binary:(")
                b.append(l)
                b.append(")")
                b.append(bo.operator)
                b.append("(")
                b.append(r)
                b.append(")")
                return Option[str].some(value = b.as_str())
            _:
                return Option[str].none


## `Variant.arm as _` — an ignored match binding is redundant.
function warn_redundant_ignored_match_binding(
    binding_name: Option[str],
    binding_line: ptr_uint,
    fallback_line: ptr_uint,
    path: str,
    warnings: ref[vec.Vec[Warning]]
) -> void:
    match binding_name:
        Option.some as bn:
            if bn.value.equal("_"):
                let line = if binding_line != 0: binding_line else: fallback_line
                push_warning(
                    warnings,
                    path,
                    line,
                    "redundant-ignored-match-binding",
                    "ignored match binding is redundant; remove 'as _'",
                    "hint"
                )
        Option.none:
            pass


## Final bare `return` in an explicit `-> void` body is redundant.
function check_redundant_return(
    return_type: ptr[ast.TypeRef]?,
    body: ptr[ast.Stmt]?,
    path: str,
    warnings: ref[vec.Vec[Warning]]
) -> void:
    if not is_void_type(return_type):
        return
    let last = last_block_statement(body) else:
        return
    unsafe:
        match read(last):
            ast.Stmt.stmt_ret as r:
                if r.value == null:
                    # The host spans the statement's own `length` — the `return`
                    # keyword (its `final_statement.length || "return".length`).
                    push_warning_at(
                        warnings,
                        path,
                        r.line,
                        r.column,
                        6,
                        "redundant-return",
                        "final bare return in void function is redundant",
                        "hint"
                    )
            _:
                pass


public function is_void_type(return_type: ptr[ast.TypeRef]?) -> bool:
    let rp = return_type else:
        return false
    unsafe:
        let t = read(rp)
        if t.nullable:
            return false
        if t.name.parts.len != 1:
            return false
        return read(t.name.parts.data + 0) == "void"


function last_block_statement(body: ptr[ast.Stmt]?) -> ptr[ast.Stmt]?:
    let bp = body else:
        return null
    unsafe:
        match read(bp):
            ast.Stmt.stmt_block as blk:
                if blk.statements.len == 0:
                    return null
                return blk.statements.data + blk.statements.len - 1
            _:
                return null

# =============================================================================
#  Traversal
# =============================================================================

## The host's `visit_statement_list`: each statement in order, stopping the
## *visitation* after a terminator (`ControlFlow` reports the unreachable
## statements, and the statements after it are not walked).
function visit_stmt_list(stmts: span[ast.Stmt], path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    var i: ptr_uint = 0
    while i < stmts.len:
        unsafe:
            visit_stmt(stmts.data + i, path, warnings)
            if stmt_is_terminator(stmts.data + i):
                return
        i += 1


function stmt_is_terminator(stmt: ptr[ast.Stmt]) -> bool:
    unsafe:
        match read(stmt):
            ast.Stmt.stmt_ret:
                return true
            ast.Stmt.stmt_break:
                return true
            ast.Stmt.stmt_continue:
                return true
            _:
                return false


## A statement-list position that may hold a single statement or a block.
function visit_body(body: ptr[ast.Stmt]?, path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    let bp = body else:
        return
    unsafe:
        match read(bp):
            ast.Stmt.stmt_block as blk:
                visit_stmt_list(blk.statements, path, warnings)
            _:
                visit_stmt(bp, path, warnings)

# =============================================================================
#  Scope state — the linter owns the emission, scope_tracking owns the state,
#  so the scope-based warnings interleave with the rules in the host's order.
# =============================================================================

function scope_push() -> void:
    let c = lint_scope_ctx else:
        return
    let ctx = unsafe: ref_of(read(c))
    scope_tracking.ctx_push_scope(ctx)


## Move scope_tracking's emitted warnings (the `unused-import` prelude) into
## the lint pass's vector, in order.
function drain_scope_warnings(sink: ref[vec.Vec[scope_tracking.ScopeWarning]], warnings: ref[vec.Vec[Warning]]) -> void:
    var i: ptr_uint = 0
    while i < sink.len():
        let sp = sink.get(i) else:
            break
        let sw = unsafe: read(sp)
        warnings.push(Warning(
            path = sw.path,
            line = sw.line,
            column = if sw.column > 0: sw.column else: 0,
            length = sw.length,
            code = sw.code,
            message = sw.message,
            severity = sw.severity
        ))
        i += 1


## Pop a scope and emit its warnings: per binding, `unused-local`/`unused-param`
## or else `prefer-let`/`prefer-own-ptr` (the host's `emit_scope_warnings`).
function scope_pop(path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    let c = lint_scope_ctx else:
        return
    let ctx = unsafe: ref_of(read(c))
    let idx = scope_tracking.ctx_scope_top(ctx)
    if idx == scope_tracking.SCOPE_NONE:
        return
    let start = scope_tracking.ctx_scope_start(ctx, idx)
    let count = scope_tracking.ctx_scope_count(ctx, idx)
    var i: ptr_uint = 0
    while i < count:
        let bd = scope_tracking.ctx_entry(ctx, start, i)
        if not bd.used:
            let is_param = bd.binding_kind == scope_tracking.BINDING_PARAM
            var buf = string.String.create()
            buf.append("unused ")
            buf.append(if is_param: "parameter" else: "local")
            buf.append(" '")
            buf.append(bd.name)
            buf.append("'")
            push_warning_at(
                warnings,
                path,
                bd.line,
                bd.column,
                bd.name.len,
                if is_param: "unused-param" else: "unused-local",
                buf.as_str(),
                "warning"
            )
        else:
            if bd.allow_prefer_let and not bd.mutated:
                var buf = string.String.create()
                buf.append("variable '")
                buf.append(bd.name)
                buf.append("' is never reassigned, prefer 'let'")
                push_warning_at(warnings, path, bd.line, bd.column, bd.name.len, "prefer-let", buf.as_str(), "hint")
            if ptr_state_fires(bd.name, bd.binding_kind == scope_tracking.BINDING_PARAM):
                var buf = string.String.create()
                buf.append("binding '")
                buf.append(bd.name)
                buf.append("' is only used inside unsafe — consider converting its type from ptr to own for auto-deref")
                push_warning_at(warnings, path, bd.line, bd.column, bd.name.len, "prefer-own-ptr", buf.as_str(), "hint")
        i += 1
    # Reclaim the scope's entries now that they are reported.
    scope_tracking.ctx_drop_scope(ctx, idx)


function ptr_state_fires(name: str, is_param: bool) -> bool:
    let p = lint_ptr_state else:
        return false
    return unsafe: read(p).fires(name, is_param)


function ptr_state_record_local(name: str, stmt_type: ptr[ast.TypeRef]?, value: ptr[ast.Expr]?) -> void:
    let p = lint_ptr_state else:
        return
    unsafe: read(p).record_local(name, stmt_type, value)


function scope_declare_local(
    name: str,
    line: ptr_uint,
    column: ptr_uint,
    is_var: bool,
    path: str,
    warnings: ref[vec.Vec[Warning]]
) -> void:
    let c = lint_scope_ctx else:
        return
    if name.len == 0 or name.starts_with("_"):
        return
    reserved_resolve_conflicts(name)
    var reserved_fix: ptr_uint = 0
    if is_reserved_type_name(name):
        var visible = map_mod.Map[str, bool].create()
        defer: visible.release()
        reserved_visible_names(ref_of(visible))
        reserved_fix = reserved_register(path, line, column, name, "local", ref_of(visible), warnings)
    let ctx = unsafe: ref_of(read(c))
    if scope_tracking.ctx_shadows_outer(ctx, name):
        var buf = string.String.create()
        buf.append("local '")
        buf.append(name)
        buf.append("' shadows a binding from an outer scope")
        push_warning_at(warnings, path, line, column, name.len, "shadow", buf.as_str(), "warning")
    scope_tracking.ctx_declare_local(ctx, name, line, column, is_var, reserved_fix)


function scope_declare_param(
    name: str,
    line: ptr_uint,
    column: ptr_uint,
    path: str,
    warnings: ref[vec.Vec[Warning]]
) -> void:
    let c = lint_scope_ctx else:
        return
    if name.len == 0 or name.starts_with("_"):
        return
    reserved_resolve_conflicts(name)
    var reserved_fix: ptr_uint = 0
    if is_reserved_type_name(name):
        var visible = map_mod.Map[str, bool].create()
        defer: visible.release()
        reserved_visible_names(ref_of(visible))
        reserved_fix = reserved_register(path, line, column, name, "parameter", ref_of(visible), warnings)
    let ctx = unsafe: ref_of(read(c))
    scope_tracking.ctx_declare_param(ctx, name, line, column, reserved_fix)


## Mark `name` used at (line, column).  When no local binding matches, a
## module-level reserved-name binding may claim the use (the host's
## `mark_used` falls through to `@module_bindings`).
function scope_mark_used_at(name: str, line: ptr_uint, column: ptr_uint) -> void:
    let c = lint_scope_ctx else:
        return
    let ctx = unsafe: ref_of(read(c))
    let resolved = scope_tracking.ctx_mark_used(ctx, name)
    if resolved == 0 and line > 0 and column > 0:
        reserved_record_module_use(name, line, column)
    else if resolved > 1:
        reserved_record_use(resolved - 2, line, column)
    let p = lint_ptr_state else:
        return
    unsafe: read(p).record_use(name, lint_unsafe_depth)


## Record a use of a module-level binding that no local shadows.
function reserved_record_module_use(name: str, line: ptr_uint, column: ptr_uint) -> void:
    let module_fix = lint_reserved_module_fix else:
        return
    let index_ptr = unsafe: read(module_fix).get(name) else:
        return
    reserved_record_use(unsafe: read(index_ptr), line, column)


function scope_mark_mutated(target: ptr[ast.Expr]) -> void:
    let c = lint_scope_ctx else:
        return
    let ctx = unsafe: ref_of(read(c))
    scope_tracking.ctx_mark_mutated(ctx, target)


function scope_mark_editable_receiver(call: ptr[ast.Expr]) -> void:
    let c = lint_scope_ctx else:
        return
    let ctx = unsafe: ref_of(read(c))
    scope_tracking.ctx_mark_editable_receiver(call, ctx)


function scope_mark_mutating_args(call: ptr[ast.Expr]) -> void:
    let c = lint_scope_ctx else:
        return
    let ctx = unsafe: ref_of(read(c))
    scope_tracking.ctx_mark_mutating_args(call, ctx)


function scope_mark_alias_source(call: ptr[ast.Expr]) -> void:
    let c = lint_scope_ctx else:
        return
    let ctx = unsafe: ref_of(read(c))
    scope_tracking.ctx_mark_alias_source(call, ctx)


function scope_visit_typeref(tr: ptr[ast.TypeRef]) -> void:
    let c = lint_scope_ctx else:
        return
    let ctx = unsafe: ref_of(read(c))
    scope_tracking.visit_typeref(tr, ctx)


function scope_set_generic(depth: ptr_uint) -> void:
    let c = lint_scope_ctx else:
        return
    let ctx = unsafe: ref_of(read(c))
    scope_tracking.ctx_set_generic_depth(ctx, depth)


function scope_set_match_arm_depth(depth: ptr_uint) -> void:
    let c = lint_scope_ctx else:
        return
    let ctx = unsafe: ref_of(read(c))
    scope_tracking.ctx_set_match_arm_depth(ctx, depth)


function scope_match_arm_depth() -> ptr_uint:
    let c = lint_scope_ctx else:
        return 0
    return unsafe: read(c).match_arm_depth


## Assignment targets that read their sub-expressions (the host's
## `visit_assignment_target`): a member/index target reads its receiver, a bare
## identifier is a write only.
function visit_assignment_target(target: ptr[ast.Expr], path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    unsafe:
        match read(target):
            ast.Expr.expr_identifier:
                pass
            ast.Expr.expr_member_access as m:
                visit_expr(m.receiver, path, warnings)
            ast.Expr.expr_index_access as ix:
                visit_expr(ix.receiver, path, warnings)
                visit_expr(ix.index, path, warnings)
            _:
                visit_expr(target, path, warnings)

# =============================================================================
#  The per-function rule group (the host's `visit_function` tail)
# =============================================================================

## dead-assignment → unreachable → borrow → constant-condition →
## redundant-null-check → loop-single-iteration → owning-release →
## prefer-let-else/prefer-var-else, in the host's order, over one body.
##
## The graph is built once here and shared by the rules that need it — the
## host caches one `statement_flow_analysis` per statement list and reuses it
## across its rule group; each rule's own solve (liveness, constant
## propagation) still runs inside its rule, once per body.
function lint_body_rules(
    params: span[ast.Param],
    body: ptr[ast.Stmt]?,
    path: str,
    warnings: ref[vec.Vec[Warning]],
    proc_context: bool
) -> void:
    let b = body else:
        return
    var flow_cfg = flow_builder.empty_cfg()
    defer: flow_builder.cfg_release(ref_of(flow_cfg))
    var graph = flow_graph.empty_graph()
    defer: flow_graph.graph_release(ref_of(graph))
    # The Cfg borrows this span: it must outlive the graph build (a span into a
    # released Vector would dangle).
    var muts = vec.Vec[flow_builder.MutationSite].create()
    defer: muts.release()
    fill_mutating_sites(ref_of(muts))
    flow_builder.cfg_set_mutating_sites(ref_of(flow_cfg), muts.as_span())
    let graph_started = lint_profile_mark()
    flow_builder.build_graph_into(ref_of(flow_cfg), ref_of(graph), params, b)
    lint_profile_done("flow.graph", graph_started)
    # The per-body flow rules are full-tier only (the host's `full_tier?`).
    if lint_full_tier:
        let dead_started = lint_profile_mark()
        lint_dead_body(ref_of(flow_cfg), ref_of(graph), path, warnings)
        lint_profile_done("rule.dead_assignment", dead_started)
        let unreachable_started = lint_profile_mark()
        lint_unreachable_graph(ref_of(graph), path, warnings)
        lint_profile_done("rule.unreachable_code", unreachable_started)
        let borrow_started = lint_profile_mark()
        borrow_check_body(body, path, warnings)
        lint_profile_done("rule.borrow_and_mutate", borrow_started)
        let const_started = lint_profile_mark()
        lint_const_cond_in_body(ref_of(flow_cfg), ref_of(graph), path, warnings)
        lint_profile_done("rule.constant_condition", const_started)
        let null_started = lint_profile_mark()
        lint_null_check_body(body, path, warnings)
        lint_profile_done("rule.redundant_null_check", null_started)
        let loop_started = lint_profile_mark()
        lint_loop_single_in_body(body, path, warnings)
        lint_profile_done("rule.loop_single_iteration", loop_started)
    # The release rule runs for functions always; the host gates it for proc
    # bodies only (`visit_expression`'s ProcExpr arm).
    if lint_full_tier or not proc_context:
        let release_started = lint_profile_mark()
        ownership_walk_body(body, path, warnings, lint_owning_type_names, ref_of(graph))
        lint_profile_done("rule.owning_release", release_started)
    let prefer_started = lint_profile_mark()
    # The host's two passes: every prefer-let-else candidate first, then every
    # prefer-var-else candidate (each over the whole body).
    prefer_else_walk_body(body, true, path, warnings)
    prefer_else_walk_body(body, false, path, warnings)
    lint_profile_done("rule.prefer_let_else", prefer_started)


## Hand the linter's recorded mutating (`out`/`inout`) argument sites to the
## CFG builder (the host's `binding_resolution.mutating_argument_identifier_ids`).
## Fill `sink` from the linter's recorded mutating-argument sites.  The caller
## keeps `sink` alive for as long as the Cfg uses its span.
function fill_mutating_sites(sink: ref[vec.Vec[flow_builder.MutationSite]]) -> void:
    let cp = lint_scope_ctx else:
        return
    let sites = unsafe: read(cp).mutating_sites
    unsafe:
        var i: ptr_uint = 0
        while i < sites.len:
            let site = read(sites.data + i)
            sink.push(flow_builder.MutationSite(name = site.name, line = site.line, column = site.column))
            i += 1


function lint_null_check_body(body: ptr[ast.Stmt]?, path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    var diags = nullcheck.check_body_diags(body)
    defer: diags.release()
    var di: ptr_uint = 0
    while di < diags.len():
        let dp = diags.get(di) else:
            break
        unsafe:
            let d = read(dp)
            let span = condition_span(d.condition, d.line, false)
            var buf = string.String.create()
            buf.append("'")
            buf.append(d.name)
            buf.append("' is already known to be non-null here — this nil check is redundant")
            push_warning_at(
                warnings,
                path,
                span.line,
                span.column,
                span.length,
                "redundant-null-check",
                buf.as_str(),
                "hint"
            )
        di += 1

# =============================================================================
#  redundant-cast — the linter's walk calls the module's hooks (the host
#  checks each site inside its own visitor), draining the diagnostics in order.
# =============================================================================

function drain_cast_diags(path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    let cp = lint_cast_ctx else:
        return
    let diags = unsafe: read(cp).diags
    var i = lint_cast_drained
    while i < diags.len():
        let dp = diags.get(i) else:
            break
        unsafe:
            let d = read(dp)
            push_warning_at(warnings, path, d.line, d.column, 0, "redundant-cast", d.message, "hint")
        i += 1
    lint_cast_drained = diags.len()


function lint_redundant_cast_local(
    stmt_type: ptr[ast.TypeRef]?,
    value: ptr[ast.Expr]?,
    path: str,
    warnings: ref[vec.Vec[Warning]]
) -> void:
    let cp = lint_cast_ctx else:
        return
    redundant_cast.set_generic_body(unsafe: ref_of(read(cp)), lint_generic_depth > 0)
    redundant_cast.check_local(unsafe: ref_of(read(cp)), stmt_type, value)
    drain_cast_diags(path, warnings)


function lint_redundant_cast_value(value: ptr[ast.Expr], path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    let cp = lint_cast_ctx else:
        return
    redundant_cast.set_generic_body(unsafe: ref_of(read(cp)), lint_generic_depth > 0)
    redundant_cast.check_assignment(unsafe: ref_of(read(cp)), value)
    drain_cast_diags(path, warnings)


function lint_redundant_cast_return(value: ptr[ast.Expr]?, path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    let cp = lint_cast_ctx else:
        return
    redundant_cast.set_generic_body(unsafe: ref_of(read(cp)), lint_generic_depth > 0)
    redundant_cast.check_return(unsafe: ref_of(read(cp)), value)
    drain_cast_diags(path, warnings)


function lint_redundant_cast_prefix(expr: ptr[ast.Expr], path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    let cp = lint_cast_ctx else:
        return
    redundant_cast.set_generic_body(unsafe: ref_of(read(cp)), lint_generic_depth > 0)
    redundant_cast.check_prefix_cast(unsafe: ref_of(read(cp)), expr)
    drain_cast_diags(path, warnings)


function lint_redundant_cast_binary(
    op: str,
    left: ptr[ast.Expr],
    right: ptr[ast.Expr],
    path: str,
    warnings: ref[vec.Vec[Warning]]
) -> void:
    let cp = lint_cast_ctx else:
        return
    redundant_cast.set_generic_body(unsafe: ref_of(read(cp)), lint_generic_depth > 0)
    redundant_cast.check_binary_operands(unsafe: ref_of(read(cp)), op, left, right)
    drain_cast_diags(path, warnings)


## The host's `check_directional_ffi_call`: emit the sites recorded for this
## call's callee.  Each warning spans its argument expression.
function lint_directional_ffi(callee: ptr[ast.Expr], path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    let sites = lint_directional_sites
    if sites.len == 0:
        return
    let key = unsafe: reinterpret[ptr_uint](callee)
    var i: ptr_uint = 0
    while i < sites.len:
        unsafe:
            let site = read(sites.data + i)
            if site.callee_key == key:
                let arg_expr = reinterpret[ptr[ast.Expr]](site.argument_key)
                var buf = string.String.create()
                buf.append("pass the lvalue directly to '")
                buf.append(site.function_name)
                buf.append("'; parameter '")
                buf.append(site.parameter_name)
                buf.append("' already declares ")
                buf.append(site.mode_label)
                buf.append(" passing")
                push_warning_at(
                    warnings,
                    path,
                    expression_line(arg_expr),
                    expression_column(arg_expr),
                    expression_length(arg_expr),
                    "directional-ffi-arg",
                    buf.as_str(),
                    "hint"
                )
        i += 1


## One function or extending method: params, the statement walk with the
## nested scope pops inside it, the per-body rule group, `redundant-return`,
## the function scope's pop, then `missing-return` — the host's order.
function visit_function_decl(
    name: str,
    type_params: span[ast.TypeParam],
    params: span[ast.Param],
    return_type: ptr[ast.TypeRef]?,
    body: ptr[ast.Stmt]?,
    line: ptr_uint,
    generic_context: bool,
    path: str,
    warnings: ref[vec.Vec[Warning]],
) -> void:
    let generic_body = generic_context or type_params.len > 0
    if generic_body:
        lint_generic_depth += 1
        scope_set_generic(lint_generic_depth)
    scope_push()
    reserved_type_params_warn(type_params, path, warnings)
    unsafe:
        var pi: ptr_uint = 0
        while pi < params.len:
            let p = read(params.data + pi)
            scope_declare_param(p.name, p.line, p.column, path, warnings)
            pi += 1
    visit_body(body, path, warnings)
    lint_body_rules(params, body, path, warnings, false)
    check_redundant_return(return_type, body, path, warnings)
    scope_pop(path, warnings)
    let missing_started = lint_profile_mark()
    check_missing_return(name, line, return_type, body, path, warnings)
    lint_profile_done("rule.missing_return", missing_started)
    if generic_body:
        lint_generic_depth -= 1
        scope_set_generic(lint_generic_depth)


function visit_decl(decl: ptr[ast.Decl], path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    unsafe:
        match read(decl):
            ast.Decl.decl_function as fun:
                visit_function_decl(
                    fun.name,
                    fun.type_params,
                    fun.method_params,
                    fun.return_type,
                    fun.body,
                    fun.line,
                    false,
                    path,
                    warnings
                )
            ast.Decl.decl_extending_block as ex:
                # The host's `extending_block_generic?`: a receiver with type
                # arguments makes every method in it a generic context.
                let generic_block = read(ex.type_name).arguments.len > 0
                var j: ptr_uint = 0
                while j < ex.methods.len:
                    let m = read(ex.methods.data + j)
                    if is_reserved_type_name(m.name):
                        reserved_name_warn(path, m.line, m.column, m.name, "function", warnings)
                    visit_function_decl(
                        m.name,
                        m.type_params,
                        m.method_params,
                        m.return_type,
                        m.body,
                        m.line,
                        generic_block,
                        path,
                        warnings
                    )
                    j += 1
            ast.Decl.decl_const as c:
                visit_expr_opt(c.value, path, warnings)
            ast.Decl.decl_var as v:
                visit_expr_opt(v.value, path, warnings)
            ast.Decl.decl_static_assert as sa:
                visit_expr(sa.condition, path, warnings)
                visit_expr_opt(sa.message, path, warnings)
            ast.Decl.decl_when as w:
                visit_expr(w.discriminant, path, warnings)
                var bi: ptr_uint = 0
                while bi < w.branches.len:
                    let br = read(w.branches.data + bi)
                    var si: ptr_uint = 0
                    while si < br.body.len:
                        visit_decl(br.body.data + si, path, warnings)
                        si += 1
                    bi += 1
            _:
                pass


function visit_stmt_opt(stmt: ptr[ast.Stmt]?, path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    let sp = stmt else:
        return
    visit_stmt(sp, path, warnings)


function visit_stmt(stmt: ptr[ast.Stmt], path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    unsafe:
        match read(stmt):
            ast.Stmt.stmt_block as blk:
                visit_stmt_list(blk.statements, path, warnings)
            ast.Stmt.stmt_local as loc:
                visit_expr_opt(loc.value, path, warnings)
                scope_declare_local(loc.name, loc.line, loc.column, not loc.is_let, path, warnings)
                if loc.else_body != null or loc.else_binding.is_some():
                    scope_push()
                    match loc.else_binding:
                        Option.some as bn:
                            scope_declare_local(
                                bn.value,
                                loc.else_binding_line,
                                loc.else_binding_column,
                                false,
                                path,
                                warnings
                            )
                        Option.none:
                            pass
                    visit_body(loc.else_body, path, warnings)
                    scope_pop(path, warnings)
                check_redundant_type_annotation(
                    loc.is_let,
                    loc.name,
                    loc.stmt_type,
                    loc.value,
                    loc.line,
                    loc.column,
                    path,
                    warnings
                )
                if loc.stmt_type != null and loc.value != null:
                    lint_redundant_cast_local(loc.stmt_type, loc.value, path, warnings)
                ptr_state_record_local(loc.name, loc.stmt_type, loc.value)
            ast.Stmt.stmt_assignment as asgn:
                visit_expr(asgn.value, path, warnings)
                # A compound assignment reads the target (host
                # `mark_assignment_target_reads`); a plain `=` does not.
                if not asgn.operator.equal("="):
                    match read(asgn.target):
                        ast.Expr.expr_identifier as id:
                            scope_mark_used_at(id.name, id.line, id.column)
                        _:
                            pass
                visit_assignment_target(asgn.target, path, warnings)
                scope_mark_mutated(asgn.target)
                check_self_assignment(asgn.target, asgn.operator, asgn.value, path, warnings)
                check_noop_compound_assignment(asgn.line, asgn.target, asgn.operator, asgn.value, path, warnings)
                if asgn.operator.equal("="):
                    lint_redundant_cast_value(asgn.value, path, warnings)
            ast.Stmt.stmt_if as iff:
                var bi: ptr_uint = 0
                while bi < iff.branches.len:
                    let br = read(iff.branches.data + bi)
                    visit_expr(br.condition, path, warnings)
                    scope_push()
                    visit_body(br.body, path, warnings)
                    scope_pop(path, warnings)
                    bi += 1
                if iff.else_body != null:
                    scope_push()
                    visit_body(iff.else_body, path, warnings)
                    scope_pop(path, warnings)
                rules_redundant_else.check_redundant_else(
                    iff.branches,
                    iff.else_body,
                    iff.else_line,
                    iff.else_column,
                    path,
                    warnings
                )
                check_duplicate_if_conditions(iff.branches, path, warnings)
                # The If-preference rules are full-tier only.
                if lint_full_tier:
                    check_prefer_inline_if(
                        iff.branches,
                        iff.else_body,
                        iff.is_inline,
                        iff.line,
                        iff.else_line,
                        path,
                        warnings
                    )
                    check_prefer_conditional_expression_if(
                        iff.branches,
                        iff.else_body,
                        iff.line,
                        first_branch_column(iff.branches),
                        path,
                        warnings
                    )
            ast.Stmt.stmt_while as wh:
                lint_loop_depth += 1
                visit_expr(wh.condition, path, warnings)
                scope_push()
                visit_body(wh.body, path, warnings)
                scope_pop(path, warnings)
                lint_loop_depth -= 1
            ast.Stmt.stmt_for as fr:
                lint_loop_depth += 1
                var ii: ptr_uint = 0
                while ii < fr.iterables.len:
                    visit_expr(fr.iterables.data + ii, path, warnings)
                    ii += 1
                scope_push()
                var bi: ptr_uint = 0
                while bi < fr.bindings.len:
                    let b = read(fr.bindings.data + bi)
                    scope_declare_local(b.name, b.line, b.column, false, path, warnings)
                    bi += 1
                visit_body(fr.body, path, warnings)
                scope_pop(path, warnings)
                lint_loop_depth -= 1
            ast.Stmt.stmt_match as mt:
                visit_expr(mt.scrutinee, path, warnings)
                var ai: ptr_uint = 0
                let saved_arm_depth = scope_match_arm_depth()
                scope_set_match_arm_depth(1)
                while ai < mt.arms.len:
                    let arm = read(mt.arms.data + ai)
                    scope_push()
                    warn_redundant_ignored_match_binding(arm.binding_name, arm.binding_line, mt.line, path, warnings)
                    match arm.binding_name:
                        Option.some as bn:
                            scope_declare_local(bn.value, arm.binding_line, arm.binding_column, false, path, warnings)
                        Option.none:
                            pass
                    visit_body(arm.body, path, warnings)
                    scope_pop(path, warnings)
                    ai += 1
                scope_set_match_arm_depth(saved_arm_depth)
                # The Match-preference rules are full-tier only, in the host's
                # order: conditional-expression, or-pattern, try.
                if lint_full_tier:
                    check_prefer_conditional_expression_match(mt.arms, mt.line, mt.column, path, warnings)
                    check_prefer_or_pattern_stmt(mt.arms, path, warnings)
                    check_prefer_try_stmt(
                        mt.arms,
                        expression_declared_line(mt.scrutinee),
                        expression_column(mt.scrutinee),
                        path,
                        warnings
                    )
            ast.Stmt.stmt_ret as r:
                visit_expr_opt(r.value, path, warnings)
                if r.value != null:
                    lint_redundant_cast_return(r.value, path, warnings)
            ast.Stmt.stmt_defer as df:
                visit_expr_opt(df.expression, path, warnings)
                scope_push()
                visit_body(df.body, path, warnings)
                scope_pop(path, warnings)
            ast.Stmt.stmt_unsafe as un:
                check_redundant_unsafe(un.line, un.column, path, warnings)
                lint_unsafe_depth += 1
                scope_push()
                visit_body(un.body, path, warnings)
                scope_pop(path, warnings)
                lint_unsafe_depth -= 1
            ast.Stmt.stmt_expression as ex:
                visit_expr(ex.expression, path, warnings)
                check_useless_expr(ex.expression, ex.line, path, warnings)
            ast.Stmt.stmt_static_assert as sa:
                visit_expr(sa.condition, path, warnings)
                visit_expr_opt(sa.message, path, warnings)
            ast.Stmt.stmt_when as wn:
                visit_expr(wn.discriminant, path, warnings)
                var wbi: ptr_uint = 0
                while wbi < wn.branches.len:
                    let br = read(wn.branches.data + wbi)
                    scope_push()
                    visit_stmt_list(br.body, path, warnings)
                    scope_pop(path, warnings)
                    wbi += 1
                if wn.else_body != null:
                    scope_push()
                    visit_body(wn.else_body, path, warnings)
                    scope_pop(path, warnings)
            ast.Stmt.stmt_gather as g:
                var gi: ptr_uint = 0
                while gi < g.handles.len:
                    visit_expr(g.handles.data + gi, path, warnings)
                    gi += 1
            _:
                pass


function visit_expr_opt(expr: ptr[ast.Expr]?, path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    let ep = expr else:
        return
    visit_expr(ep, path, warnings)


function visit_expr(expr: ptr[ast.Expr], path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    unsafe:
        match read(expr):
            ast.Expr.expr_identifier as id:
                scope_mark_used_at(id.name, id.line, id.column)
            ast.Expr.expr_binary_op as b:
                visit_expr(b.left, path, warnings)
                visit_expr(b.right, path, warnings)
                check_self_comparison(b.operator, b.left, b.right, path, warnings)
                check_redundant_bool_compare(b.operator, b.left, b.right, path, warnings)
                lint_redundant_cast_binary(b.operator, b.left, b.right, path, warnings)
            ast.Expr.expr_unary_op as u:
                visit_expr(u.operand, path, warnings)
            ast.Expr.expr_member_access as m:
                visit_expr(m.receiver, path, warnings)
            ast.Expr.expr_call as call:
                visit_expr(call.callee, path, warnings)
                var i: ptr_uint = 0
                while i < call.args.len:
                    let arg = read(call.args.data + i)
                    visit_expr(arg.arg_value, path, warnings)
                    i += 1
                scope_mark_alias_source(expr)
                scope_mark_editable_receiver(expr)
                scope_mark_mutating_args(expr)
                lint_directional_ffi(call.callee, path, warnings)
            ast.Expr.expr_index_access as ix:
                visit_expr(ix.receiver, path, warnings)
                visit_expr(ix.index, path, warnings)
            ast.Expr.expr_specialization as sp:
                visit_expr(sp.callee, path, warnings)
                var sai: ptr_uint = 0
                while sai < sp.arguments.len:
                    scope_visit_typeref(read(sp.arguments.data + sai).value)
                    sai += 1
            ast.Expr.expr_sizeof as sz:
                scope_visit_typeref(sz.target_type)
            ast.Expr.expr_alignof as al:
                scope_visit_typeref(al.target_type)
            ast.Expr.expr_offsetof as off:
                scope_visit_typeref(off.target_type)
                scope_mark_used_at(off.field, 0, 0)
            ast.Expr.expr_if as iff:
                visit_expr(iff.condition, path, warnings)
                visit_expr(iff.then_expr, path, warnings)
                visit_expr(iff.else_expr, path, warnings)
            ast.Expr.expr_match as mm:
                visit_expr(mm.scrutinee, path, warnings)
                var ai: ptr_uint = 0
                let saved_arm_depth = scope_match_arm_depth()
                scope_set_match_arm_depth(1)
                while ai < mm.arms.len:
                    let arm = read(mm.arms.data + ai)
                    scope_push()
                    warn_redundant_ignored_match_binding(arm.binding_name, arm.binding_line, mm.line, path, warnings)
                    match arm.binding_name:
                        Option.some as bn:
                            scope_declare_local(bn.value, arm.binding_line, arm.binding_column, false, path, warnings)
                        Option.none:
                            pass
                    visit_expr(arm.value, path, warnings)
                    scope_pop(path, warnings)
                    ai += 1
                scope_set_match_arm_depth(saved_arm_depth)
            ast.Expr.expr_proc as pr:
                scope_push()
                unsafe:
                    var pi: ptr_uint = 0
                    while pi < pr.method_params.len:
                        let p = read(pr.method_params.data + pi)
                        scope_declare_param(p.name, p.line, p.column, path, warnings)
                        pi += 1
                visit_body(pr.body, path, warnings)
                lint_body_rules(pr.method_params, pr.body, path, warnings, true)
                scope_pop(path, warnings)
            ast.Expr.expr_await as aw:
                visit_expr(aw.expression, path, warnings)
            ast.Expr.expr_detach as dt:
                visit_expr(dt.expression, path, warnings)
            ast.Expr.expr_named as nm:
                visit_expr(nm.value, path, warnings)
            ast.Expr.expr_range as rg:
                visit_expr(rg.start_expr, path, warnings)
                visit_expr(rg.end_expr, path, warnings)
            ast.Expr.expr_prefix_cast as pc:
                visit_expr(pc.expression, path, warnings)
                lint_redundant_cast_prefix(expr, path, warnings)
            ast.Expr.expr_unsafe as us:
                check_redundant_unsafe(us.line, us.column, path, warnings)
                lint_unsafe_depth += 1
                visit_expr(us.expression, path, warnings)
                lint_unsafe_depth -= 1
            ast.Expr.expr_expression_list as el:
                var ei: ptr_uint = 0
                while ei < el.elements.len:
                    visit_expr(el.elements.data + ei, path, warnings)
                    ei += 1
            ast.Expr.expr_format_string as fs:
                var pi: ptr_uint = 0
                while pi < fs.parts.len:
                    match read(fs.parts.data + pi):
                        ast.FormatStringPart.fmt_expr as fe:
                            visit_expr(fe.expression, path, warnings)
                        _:
                            pass
                    pi += 1
            _:
                pass

    unsafe:
        match read(expr):
            ast.Expr.expr_call as call:
                if lint_full_tier:
                    check_prefer_struct_with(expr, call.callee, call.args, path, warnings)
            ast.Expr.expr_match as mm:
                # The Match-expression preference rules are full-tier only.
                if lint_full_tier:
                    check_prefer_is_variant_expr(
                        mm.arms,
                        mm.line,
                        mm.column,
                        mm.length,
                        mm.desugared_from_is,
                        path,
                        warnings
                    )
                    check_prefer_or_pattern_expr(mm.arms, path, warnings)
            _:
                pass

# =============================================================================
#  Helpers — statement / expression structural comparison
# =============================================================================

## Return the single statement from a block body, or none when the body is not
## a single-statement block (or is null).
function single_statement_body(body: ptr[ast.Stmt]?) -> ptr[ast.Stmt]?:
    let bp = body else:
        return null
    unsafe:
        match read(bp):
            ast.Stmt.stmt_block as blk:
                if blk.statements.len == 1:
                    return blk.statements.data + 0
                return null
            _:
                return bp


## Is `stmt` an inline-worthy simple statement (return, assign, expression,
## break, continue, local decl)?
function inline_simple_statement(stmt: ptr[ast.Stmt]) -> bool:
    unsafe:
        match read(stmt):
            ast.Stmt.stmt_ret:
                return true
            ast.Stmt.stmt_assignment:
                return true
            ast.Stmt.stmt_expression:
                return true
            ast.Stmt.stmt_break:
                return true
            ast.Stmt.stmt_continue:
                return true
            ast.Stmt.stmt_local:
                return true
            _:
                return false


## Structural equality of two statement pointers — the host's `node_fingerprint`
## comparison: every field except positions (`line`/`column`/`length`,
## `else_line`/`else_column`, `binding_line`/`binding_column`) must match.  The
## prefer-or-pattern rule relies on this to merge arms whose bodies were built
## as distinct nodes with the same shape.
## Structural equality of two `if` statements (branches and else).
## Structural equality of two `for` statements (bindings, iterables, body).
## Structural equality of format-string parts.
## Structural equality of call callees and arguments.
## Structural equality of match expressions (arms, bindings, desugaring flag).
## Structural equality of proc expressions (params, return type, body).
## Is `expr` a wildcard pattern (_)?
function wildcard_pattern(expr: ptr[ast.Expr]?) -> bool:
    let ep = expr else:
        return false
    unsafe:
        match read(ep):
            ast.Expr.expr_identifier as id:
                return id.name == "_"
            _:
                return false


## Extract boolean literal value from an expression, or none.
function boolean_literal_value(expr: ptr[ast.Expr]) -> Option[bool]:
    unsafe:
        match read(expr):
            ast.Expr.expr_bool_literal as b:
                return Option[bool].some(value = b.value)
            _:
                return Option[bool].none


## Extract identifier name from an expr, or none.
function identifier_name_of(expr: ptr[ast.Expr]) -> Option[str]:
    unsafe:
        match read(expr):
            ast.Expr.expr_identifier as id:
                return Option[str].some(value = id.name)
            _:
                return Option[str].none

# =============================================================================
#  missing-return — non-void function whose body does not always return.
# =============================================================================

## Emitted after the scope pass: the host checks each function once its scope
## frame has popped, so the function's `unused-local`/`prefer-let` warnings come
## first.
function check_missing_return(
    name: str,
    line: ptr_uint,
    return_type: ptr[ast.TypeRef]?,
    body: ptr[ast.Stmt]?,
    path: str,
    warnings: ref[vec.Vec[Warning]]
) -> void:
    if return_type == null:
        return
    if is_void_type(return_type):
        return
    let bp = body else:
        push_warning(warnings, path, line, "missing-return", mk_missing_return_msg(name), "error")
        return
    if not rules_redundant_else.always_returns_body(body):
        push_warning(warnings, path, line, "missing-return", mk_missing_return_msg(name), "error")


function mk_missing_return_msg(name: str) -> str:
    var buf = string.String.create()
    buf.append("function '")
    buf.append(name)
    buf.append("' does not always return a value")
    return buf.as_str()

# =============================================================================
#  prefer-inline-if — multi-line if/else where each branch is a single simple
#  statement that fits on one line.
# =============================================================================

function check_prefer_inline_if(
    branches: span[ast.IfBranch],
    else_body: ptr[ast.Stmt]?,
    is_inline: bool,
    line: ptr_uint,
    else_line: ptr_uint,
    path: str,
    warnings: ref[vec.Vec[Warning]]
) -> void:
    if is_inline:
        return
    if not rules_redundant_else.block_is_nonempty(else_body):
        return
    var bi: ptr_uint = 0
    while bi < branches.len:
        unsafe:
            let s = single_statement_body(read(branches.data + bi).body) else:
                return
            if not inline_simple_statement(s):
                return
        bi += 1
    let s = single_statement_body(else_body) else:
        return
    if not inline_simple_statement(s):
        return
    if visually_inline_if(branches, else_body, else_line):
        return
    if inline_if_too_wide(branches.len, line):
        return
    # The host anchors on the branch (the `if` keyword), not the condition.
    let first_branch = unsafe: read(branches.data + 0)
    push_warning_at(
        warnings,
        path,
        first_branch.line,
        first_branch.column,
        0,
        "prefer-inline-if",
        "if/else with single-statement branches can be written inline",
        "hint"
    )


## The host's `visually_inline_if?`: every branch body starts on its branch's own
## line and the else body on the else line — the source already writes the whole
## `if` on one line, and the host's `inline_if_too_wide?` reports exactly these
## as unjoinable, suppressing the block-form hints.
function visually_inline_if(branches: span[ast.IfBranch], else_body: ptr[ast.Stmt]?, else_line: ptr_uint) -> bool:
    var bi: ptr_uint = 0
    while bi < branches.len:
        unsafe:
            let br = read(branches.data + bi)
            let s = single_statement_body(br.body) else:
                return false
            if rules_redundant_else.statement_line(s) != br.line:
                return false
        bi += 1
    let es = single_statement_body(else_body) else:
        return false
    if else_line == 0 or rules_redundant_else.statement_line(es) != else_line:
        return false
    return true


## The host's `inline_if_too_wide?`: simulate the actual one-line join of the
## whole `if`/`else if`/`else` chain from the source text.  A chain whose
## branches are not each a single physical line, whose composed line exceeds
## the column budget (120 characters), or whose delimiters do not balance is
## unjoinable, so the conciseness hints are suppressed.
function inline_if_too_wide(branches_len: ptr_uint, line: ptr_uint) -> bool:
    if branches_len == 0:
        return false
    let lines_ptr = lint_source_lines else:
        return false
    var lines = unsafe: read(lines_ptr)
    if line == 0 or line > lines.len():
        return true
    let header_raw = source_line_at(ref_of(lines), line - 1)
    let header = header_raw.trim_ascii_whitespace()
    if not header.starts_with("if "):
        return true
    let indent_len = leading_whitespace_len(header_raw)

    var headers = vec.Vec[str].create()
    defer: headers.release()
    var bodies = vec.Vec[str].create()
    defer: bodies.release()
    var cur_header = header
    var cur_body = ""
    var has_body = false
    var idx = line
    while idx < lines.len():
        let text = right_trim_ascii(source_line_at(ref_of(lines), idx))
        if text.len == 0:
            break
        let text_indent = leading_whitespace_len(text)
        let stripped = text.trim_ascii_whitespace()
        if text_indent == indent_len and (stripped == "else:" or stripped.starts_with("else if ")):
            if not has_body:
                return true
            headers.push(cur_header)
            bodies.push(cur_body)
            cur_header = stripped
            cur_body = ""
            has_body = false
            idx += 1
            continue
        if text_indent <= indent_len:
            break
        if has_body:
            return true
        cur_body = stripped
        has_body = true
        idx += 1
    if not has_body:
        return true
    if not cur_header == "else:":
        return true
    headers.push(cur_header)
    bodies.push(cur_body)

    var joined = string.String.create()
    defer: joined.release()
    joined.append(header_raw.slice(0, indent_len))
    var si: ptr_uint = 0
    while si < headers.len():
        let hp = headers.get(si) else:
            break
        let bp = bodies.get(si) else:
            break
        if si > 0:
            joined.append(" ")
        joined.append(unsafe: read(hp))
        joined.append(" ")
        joined.append(unsafe: read(bp))
        si += 1
    let joined_text = joined.as_str()
    if utf8_char_count(joined_text) > 120:
        return true
    return not balanced_inline_line(joined_text)


function source_line_at(lines: ref[vec.Vec[str]], index: ptr_uint) -> str:
    let s = lines.get(index) else:
        return ""
    return unsafe: read(s)


function leading_whitespace_len(text: str) -> ptr_uint:
    var i: ptr_uint = 0
    while i < text.len:
        let b = text.byte_at(i)
        if b == 32 or b == 9:
            i += 1
            continue
        break
    return i


function right_trim_ascii(text: str) -> str:
    var end = text.len
    while end > 0:
        let b = text.byte_at(end - 1)
        if b == 32 or b == 9 or b == 13:
            end -= 1
            continue
        break
    return text.slice(0, end)


## Ruby's `String#length`: the number of UTF-8 characters, not bytes.
function utf8_char_count(text: str) -> ptr_uint:
    var count: ptr_uint = 0
    var i: ptr_uint = 0
    while i < text.len:
        if not str.utf8_continuation_byte(text.byte_at(i)):
            count += 1
        i += 1
    return count


function balanced_inline_line(text: str) -> bool:
    var depth: int = 0
    var i: ptr_uint = 0
    while i < text.len:
        let b = text.byte_at(i)
        if b == 40 or b == 91:
            depth += 1
        else if b == 41 or b == 93:
            depth -= 1
            if depth < 0:
                return false
        i += 1
    return depth == 0

# =============================================================================
#  prefer-or-pattern — adjacent match arms with identical bodies should merge
#  with |.
# =============================================================================

function check_prefer_or_pattern_stmt(arms: span[ast.MatchArm], path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    if arms.len < 2:
        return
    var i: ptr_uint = 1
    while i < arms.len:
        unsafe:
            let prev = read(arms.data + i - 1)
            let curr = read(arms.data + i)
            if prev.binding_name.is_some() or curr.binding_name.is_some():
                i += 1
                continue
            if prev.pattern == null or curr.pattern == null:
                i += 1
                continue
            if wildcard_pattern(prev.pattern) or wildcard_pattern(curr.pattern):
                i += 1
                continue
            # Expanded or-pattern alternatives (`A | B:`) share one body object;
            # the host's `.equal?` guard skips those (they are already merged).
            if prev.body == curr.body:
                i += 1
                continue
            if structural.stmts_structural_equal(prev.body, curr.body):
                let pat_line = expression_line(curr.pattern)
                if pat_line == 0:
                    i += 1
                    continue
                push_warning_expr(
                    warnings,
                    path,
                    curr.pattern,
                    "prefer-or-pattern",
                    "adjacent match arms have identical bodies; merge them with `|`",
                    "hint"
                )
        i += 1


function check_prefer_or_pattern_expr(arms: span[ast.MatchExprArm], path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    if arms.len < 2:
        return
    var i: ptr_uint = 1
    while i < arms.len:
        unsafe:
            let prev = read(arms.data + i - 1)
            let curr = read(arms.data + i)
            if prev.binding_name.is_some() or curr.binding_name.is_some():
                i += 1
                continue
            if prev.pattern == null or curr.pattern == null:
                i += 1
                continue
            if wildcard_pattern(prev.pattern) or wildcard_pattern(curr.pattern):
                i += 1
                continue
            if prev.value == curr.value:
                i += 1
                continue
            if structural.exprs_structural_equal(prev.value, curr.value):
                let pat_line = expression_line(curr.pattern)
                if pat_line != 0:
                    push_warning_expr(
                        warnings,
                        path,
                        curr.pattern,
                        "prefer-or-pattern",
                        "adjacent match arms have identical bodies; merge them with `|`",
                        "hint"
                    )
        i += 1

# =============================================================================
#  prefer-conditional-expression — if/match where every branch returns a value
#  or assigns to the same target.
# =============================================================================

function check_prefer_conditional_expression_if(
    branches: span[ast.IfBranch],
    else_body: ptr[ast.Stmt]?,
    line: ptr_uint,
    column: ptr_uint,
    path: str,
    warnings: ref[vec.Vec[Warning]]
) -> void:
    if lint_loop_depth > 0:
        return
    if not rules_redundant_else.block_is_nonempty(else_body):
        return
    # The host gates this arm on `inline_if_too_wide?`: an `if` whose one-line
    # join would not fit (or that is already written inline) is suppressed.
    if inline_if_too_wide(branches.len, line):
        return
    # Collect single statements from each branch.
    var stmts = vec.Vec[ptr[ast.Stmt]].create()
    defer: stmts.release()
    var bi: ptr_uint = 0
    while bi < branches.len:
        unsafe:
            let s = single_statement_body(read(branches.data + bi).body) else:
                return
            stmts.push(s)
        bi += 1
    let else_s = single_statement_body(else_body) else:
        return
    stmts.push(else_s)

    report_conditional_expr(ref_of(stmts), line, column, "if", path, warnings)


function check_prefer_conditional_expression_match(
    arms: span[ast.MatchArm],
    line: ptr_uint,
    column: ptr_uint,
    path: str,
    warnings: ref[vec.Vec[Warning]]
) -> void:
    if lint_loop_depth > 0:
        return
    # Only fires when there is a wildcard arm.
    var has_wild = false
    var ai: ptr_uint = 0
    while ai < arms.len:
        unsafe:
            let arm = read(arms.data + ai)
            if arm.pattern == null or wildcard_pattern(arm.pattern):
                has_wild = true
                break
        ai += 1
    if not has_wild:
        return

    var stmts = vec.Vec[ptr[ast.Stmt]].create()
    defer: stmts.release()
    ai = 0
    while ai < arms.len:
        unsafe:
            let arm = read(arms.data + ai)
            if arm.binding_name.is_some():
                return
            let s = single_statement_body(arm.body) else:
                return
            stmts.push(s)
        ai += 1

    report_conditional_expr(ref_of(stmts), line, column, "match", path, warnings)


## The host's `report_conditional_expr`: every single-statement branch
## either returns a value or assigns the same target, and the message names the
## kind and (for an assignment) the target.
function report_conditional_expr(
    stmts: ref[vec.Vec[ptr[ast.Stmt]]],
    line: ptr_uint,
    column: ptr_uint,
    kind: str,
    path: str,
    warnings: ref[vec.Vec[Warning]]
) -> void:
    if stmts.len() == 0:
        return
    if lint_loop_depth > 0:
        return
    var all_ret = true
    var all_assign = true
    var target_name: str = ""
    var si: ptr_uint = 0
    while si < stmts.len():
        let sp = stmts.get(si) else:
            break
        unsafe:
            match read(unsafe: read(sp)):
                ast.Stmt.stmt_ret as r:
                    if r.value == null:
                        return
                    all_assign = false
                ast.Stmt.stmt_assignment as a:
                    if a.operator != "=":
                        return
                    all_ret = false
                    let nm = identifier_name_of(a.target) else:
                        return
                    if target_name.len == 0:
                        target_name = nm
                    else if not nm.equal(target_name):
                        return
                _:
                    return
        si += 1

    if all_ret:
        var buf = string.String.create()
        buf.append("every ")
        buf.append(kind)
        buf.append(" branch returns a value; rewrite as `return ")
        buf.append(kind)
        buf.append(" …` expression")
        push_warning_at(warnings, path, line, column, 0, "prefer-conditional-expression", buf.as_str(), "hint")
    else if all_assign:
        var buf = string.String.create()
        buf.append("every ")
        buf.append(kind)
        buf.append(" branch assigns to '")
        buf.append(target_name)
        buf.append("'; rewrite as `let ")
        buf.append(target_name)
        buf.append(" = ")
        buf.append(kind)
        buf.append(" …` expression")
        push_warning_at(warnings, path, line, column, 0, "prefer-conditional-expression", buf.as_str(), "hint")


## A source-signature string for an expression, used for assignment-target
## identity comparison (node_fingerprint mirror).
function expr_source_sig(expr: ptr[ast.Expr]) -> str:
    unsafe:
        match read(expr):
            ast.Expr.expr_identifier as id:
                var buf = string.String.create()
                buf.append("id:")
                buf.append(id.name)
                return buf.as_str()
            ast.Expr.expr_member_access as m:
                var buf = string.String.create()
                buf.append(expr_source_sig(m.receiver))
                buf.append(".")
                buf.append(m.member_name)
                return buf.as_str()
            ast.Expr.expr_index_access as ix:
                var buf = string.String.create()
                buf.append(expr_source_sig(ix.receiver))
                buf.append("[]")
                return buf.as_str()
            _:
                return "unknown"

# =============================================================================
#  prefer-let-else — `let x = expr; if x == null: ...` should use let...else.
# =============================================================================

function prefer_else_walk_body(
    body: ptr[ast.Stmt]?,
    want_let: bool,
    path: str,
    warnings: ref[vec.Vec[Warning]]
) -> void:
    let bp = body else:
        return
    unsafe:
        match read(bp):
            ast.Stmt.stmt_block as blk:
                prefer_else_walk_stmts(blk.statements, want_let, path, warnings)
            _:
                pass


## The host's `ignored_binding_name?`: `_` and `_`-prefixed names never carry
## a prefer-else hint.
function prefer_else_ignored_name(name: str) -> bool:
    if name.len == 0:
        return true
    if name.byte_at(0) == 95:
        return true
    return false


function prefer_else_walk_stmts(
    stmts: span[ast.Stmt],
    want_let: bool,
    path: str,
    warnings: ref[vec.Vec[Warning]]
) -> void:
    # The host's `walk_statement_lists` yields the current list first and then
    # recurses into each statement's bodies, so outer candidates precede inner.
    var i: ptr_uint = 0
    while i + 1 < stmts.len:
        unsafe:
            match read(stmts.data + i):
                ast.Stmt.stmt_local as loc:
                    if loc.is_let != want_let:
                        i += 1
                        continue
                    if loc.value == null:
                        i += 1
                        continue
                    if loc.stmt_type != null:
                        i += 1
                        continue
                    if loc.else_binding.is_some() or loc.else_body != null:
                        i += 1
                        continue
                    if prefer_else_ignored_name(loc.name):
                        i += 1
                        continue
                    match read(stmts.data + i + 1):
                        ast.Stmt.stmt_if as iff:
                            if iff.branches.len != 1:
                                i += 1
                                continue
                            if rules_redundant_else.block_is_nonempty(iff.else_body):
                                i += 1
                                continue
                            let cond = read(iff.branches.data + 0).condition
                            let guard_name = prefer_else_guard_name(cond, loc.name) else:
                                i += 1
                                continue
                            # A `var ... else` only helps when the binding is
                            # actually reassigned (the host's
                            # `prefer_var_else_binding_mutated?`).
                            if not want_let and not prefer_else_binding_mutated(loc.name):
                                i += 1
                                continue
                            let guard_body = read(iff.branches.data + 0).body
                            if not prefer_else_body_terminates(guard_body):
                                i += 1
                                continue
                            let span = condition_span(cond, iff.line, false)
                            var buf = string.String.create()
                            buf.append("nullable guard for '")
                            buf.append(loc.name)
                            buf.append("' can use ")
                            buf.append(if want_let: "let" else: "var")
                            buf.append(" ... else")
                            push_warning_at(
                                warnings,
                                path,
                                span.line,
                                span.column,
                                span.length,
                                if want_let: "prefer-let-else" else: "prefer-var-else",
                                buf.as_str(),
                                "hint"
                            )
                        _:
                            pass
                _:
                    pass
        i += 1
    i = 0
    while i < stmts.len:
        unsafe:
            prefer_else_recurse_into(stmts.data + i, want_let, path, warnings)
        i += 1


## The host's `ControlFlow::Termination.block_always_terminates?`: a fresh
## graph over the guard body, whose continuation must be unreachable.
function prefer_else_body_terminates(body: ptr[ast.Stmt]?) -> bool:
    if body == null:
        return false
    var cfg = flow_builder.empty_cfg()
    defer: flow_builder.cfg_release(ref_of(cfg))
    var graph = flow_graph.empty_graph()
    defer: flow_graph.graph_release(ref_of(graph))
    flow_builder.build_graph_termination_into(ref_of(cfg), ref_of(graph), body)
    let entry = unsafe: read(ref_of(graph)).entry_id
    let exit = unsafe: read(ref_of(graph)).exit_id
    return not flow_graph.graph_reaches(ref_of(graph), entry, exit)


## The host's `prefer_var_else_binding_mutated?`: the innermost open scope's
## binding for `name` was reassigned.
function prefer_else_binding_mutated(name: str) -> bool:
    let cp = lint_scope_ctx else:
        return false
    return scope_tracking.ctx_binding_mutated(unsafe: ref_of(read(cp)), name)


## Check if `condition` is `name == null` or `null == name`, returning true
## if the guard matches the given name.
function prefer_else_guard_name(condition: ptr[ast.Expr], name: str) -> Option[bool]:
    unsafe:
        match read(condition):
            ast.Expr.expr_binary_op as b:
                if b.operator != "==":
                    return Option[bool].none
                let left_name = identifier_name_of(b.left)
                let right_name = identifier_name_of(b.right)
                var left_null = false
                var right_null = false
                match read(b.left):
                    ast.Expr.expr_null_literal:
                        left_null = true
                    _:
                        pass
                match read(b.right):
                    ast.Expr.expr_null_literal:
                        right_null = true
                    _:
                        pass
                if left_null and right_name.is_some() and right_name.unwrap().equal(name):
                    return Option[bool].some(value = true)
                if right_null and left_name.is_some() and left_name.unwrap().equal(name):
                    return Option[bool].some(value = true)
                return Option[bool].none
            _:
                return Option[bool].none


function prefer_else_recurse_into(
    stmt: ptr[ast.Stmt],
    want_let: bool,
    path: str,
    warnings: ref[vec.Vec[Warning]]
) -> void:
    unsafe:
        match read(stmt):
            ast.Stmt.stmt_if as iff:
                var bi: ptr_uint = 0
                while bi < iff.branches.len:
                    prefer_else_walk_body(read(iff.branches.data + bi).body, want_let, path, warnings)
                    bi += 1
                prefer_else_walk_body(iff.else_body, want_let, path, warnings)
            ast.Stmt.stmt_match as mt:
                var ai: ptr_uint = 0
                while ai < mt.arms.len:
                    prefer_else_walk_body(read(mt.arms.data + ai).body, want_let, path, warnings)
                    ai += 1
            ast.Stmt.stmt_while as wh:
                prefer_else_walk_body(wh.body, want_let, path, warnings)
            ast.Stmt.stmt_for as fr:
                prefer_else_walk_body(fr.body, want_let, path, warnings)
            ast.Stmt.stmt_unsafe as un:
                prefer_else_walk_body(un.body, want_let, path, warnings)
            ast.Stmt.stmt_defer as df:
                prefer_else_walk_body(df.body, want_let, path, warnings)
            ast.Stmt.stmt_block as blk:
                prefer_else_walk_stmts(blk.statements, want_let, path, warnings)
            _:
                pass

# =============================================================================
#  prefer-try — match over Option/Result that only propagates failure.
# =============================================================================

struct TryArmPair:
    early_is_first: bool
    base: str


function check_prefer_try_stmt(
    arms: span[ast.MatchArm],
    anchor_line: ptr_uint,
    anchor_column: ptr_uint,
    path: str,
    warnings: ref[vec.Vec[Warning]]
) -> void:
    # The host needs the scrutinee's resolved variant type, and the analyzer
    # records no expression types inside a generic body (see `resolve_expr_type`
    # in redundant_cast), so the rule never fires there.
    if lint_generic_depth > 0:
        return
    if arms.len != 2:
        return
    unsafe:
        let arm0 = read(arms.data + 0)
        let arm1 = read(arms.data + 1)
        let pair = classify_try_arms(arm0, arm1) else:
            return
        let early = if pair.early_is_first: arm0 else: arm1
        let s = single_statement_body(early.body) else:
            return
        match read(s):
            ast.Stmt.stmt_ret as r:
                let rv = r.value else:
                    return
                if is_propagation_return(rv, pair.base, early.binding_name):
                    var buf = string.String.create()
                    buf.append("this ")
                    buf.append(pair.base)
                    buf.append(" match only propagates the failure branch; consider `expr?`")
                    push_warning_at(warnings, path, anchor_line, anchor_column, 0, "prefer-try", buf.as_str(), "hint")
            _:
                pass


function classify_try_arms(arm0: ast.MatchArm, arm1: ast.MatchArm) -> Option[TryArmPair]:
    let p0 = arm0.pattern
    let p1 = arm1.pattern
    if p0 == null or p1 == null:
        return Option[TryArmPair].none
    let base_opt = try_short_circuit_base(p0, p1)
    match base_opt:
        Option.some as base:
            return Option[TryArmPair].some(value = TryArmPair(early_is_first = true, base = base.value))
        Option.none:
            pass
    let base_opt2 = try_short_circuit_base(p1, p0)
    match base_opt2:
        Option.some as base:
            return Option[TryArmPair].some(value = TryArmPair(early_is_first = false, base = base.value))
        Option.none:
            pass
    return Option[TryArmPair].none


## If `short_arm` is a short-circuit pattern (Result.failure or Option.none),
## and `other_arm` is the success arm, return the variant base name.
function try_short_circuit_base(short_pat: ptr[ast.Expr], other_pat: ptr[ast.Expr]) -> Option[str]:
    unsafe:
        match read(short_pat):
            ast.Expr.expr_member_access as m:
                # `Result[int, E].failure` names the head through a specialization
                # (`Result[int, E]`), so compare the written base name — the
                # host compares the resolved variant's base name instead.
                let recv_name = member_type_base_name(m.receiver) else:
                    return Option[str].none
                if m.member_name == "failure":
                    # Check that the other arm is success or some
                    match read(other_pat):
                        ast.Expr.expr_member_access as om:
                            let other_recv = member_type_base_name(om.receiver) else:
                                return Option[str].none
                            if om.member_name == "success" and other_recv.equal(recv_name):
                                return Option[str].some(value = "Result")
                            return Option[str].none
                        _:
                            return Option[str].none
                if m.member_name == "none":
                    match read(other_pat):
                        ast.Expr.expr_member_access as om:
                            let other_recv = member_type_base_name(om.receiver) else:
                                return Option[str].none
                            if om.member_name == "some" and other_recv.equal(recv_name):
                                return Option[str].some(value = "Option")
                            return Option[str].none
                        _:
                            return Option[str].none
                return Option[str].none
            _:
                return Option[str].none


## Check if `value` propagates the failure arm's error unchanged.
## For Option: `Option[..].none` or `.none()`. For Result:
## `.failure(error = <binding_name>.error)`.
function is_propagation_return(value: ptr[ast.Expr], base: str, binding_name: Option[str]) -> bool:
    if base.equal("Option"):
        return is_option_none_expr(value)
    if base.equal("Result"):
        return is_result_failure_propagation(value, binding_name)
    return false


function is_option_none_expr(value: ptr[ast.Expr]) -> bool:
    unsafe:
        match read(value):
            ast.Expr.expr_member_access as m:
                if m.member_name == "none":
                    return true
            _:
                return false
    return false


## The written `Type` of a `Type.member` / `Type[..].member` receiver: the bare
## identifier, or a specialization's base identifier.
function member_type_base_name(receiver: ptr[ast.Expr]) -> Option[str]:
    unsafe:
        match read(receiver):
            ast.Expr.expr_identifier as id:
                return Option[str].some(value = id.name)
            ast.Expr.expr_specialization as sp:
                return identifier_name_of(sp.callee)
            _:
                return Option[str].none
    return Option[str].none


function is_result_failure_propagation(value: ptr[ast.Expr], binding_name: Option[str]) -> bool:
    let bn = binding_name else:
        return false
    unsafe:
        match read(value):
            ast.Expr.expr_call as call:
                match read(call.callee):
                    ast.Expr.expr_member_access as m:
                        if m.member_name != "failure":
                            return false
                        let recv_name = member_type_base_name(m.receiver) else:
                            return false
                        if not recv_name.equal("Result"):
                            return false
                        # Check args: error=<binding>.error
                        if call.args.len == 1:
                            let arg_v = read(read(call.args.data + 0).arg_value)
                            match arg_v:
                                ast.Expr.expr_member_access as err_m:
                                    if err_m.member_name == "error":
                                        match read(err_m.receiver):
                                            ast.Expr.expr_identifier as id:
                                                return id.name.equal(bn)
                                            _:
                                                pass
                                _:
                                    pass
                        return false
                    _:
                        return false
            _:
                return false
    return false

# =============================================================================
#  prefer-is-variant — `match expr: Arm: true; _: false` → `expr is Arm`.
# =============================================================================

struct IsVariantPair:
    pat_is_first: bool
    want_true: bool


function check_prefer_is_variant_expr(
    arms: span[ast.MatchExprArm],
    match_line: ptr_uint,
    match_column: ptr_uint,
    match_length: ptr_uint,
    desugared_from_is: bool,
    path: str,
    warnings: ref[vec.Vec[Warning]]
) -> void:
    # The host skips a match the parser desugared from `is` (warning would be
    # circular) and anchors on the match expression itself.
    if desugared_from_is:
        return
    if arms.len != 2:
        return
    unsafe:
        let arm0 = read(arms.data + 0)
        let arm1 = read(arms.data + 1)
        let pair = classify_is_variant_arms(arm0, arm1) else:
            return
        let pat_arm = if pair.pat_is_first: arm0 else: arm1
        let pat_text = expr_source_name(pat_arm.pattern)
        var suggestion = string.String.create()
        if pair.want_true:
            suggestion.append("expr is ")
            suggestion.append(pat_text)
        else:
            suggestion.append("not (expr is ")
            suggestion.append(pat_text)
            suggestion.append(")")
        var buf = string.String.create()
        buf.append("prefer `")
        buf.append(suggestion.as_str())
        buf.append("` over a match that maps one variant arm to a boolean")
        push_warning_at(
            warnings,
            path,
            match_line,
            match_column,
            match_length,
            "prefer-is-variant",
            buf.as_str(),
            "hint"
        )


function classify_is_variant_arms(arm0: ast.MatchExprArm, arm1: ast.MatchExprArm) -> Option[IsVariantPair]:
    let p0_wild = arm0.pattern == null or (arm0.pattern != null and wildcard_pattern(arm0.pattern))
    let p1_wild = arm1.pattern == null or (arm1.pattern != null and wildcard_pattern(arm1.pattern))
    if p0_wild == p1_wild:
        return Option[IsVariantPair].none
    let wild_is_first = p0_wild
    let pat_arm = if wild_is_first: arm1 else: arm0
    let pat_is_true = boolean_literal_value(pat_arm.value)
    let wild_is_true = boolean_literal_value(if wild_is_first: arm0.value else: arm1.value)
    if wild_is_true.is_none() or pat_is_true.is_none():
        return Option[IsVariantPair].none
    if wild_is_true.unwrap() == pat_is_true.unwrap():
        return Option[IsVariantPair].none
    if pat_arm.binding_name.is_some():
        return Option[IsVariantPair].none
    let pat = pat_arm.pattern else:
        return Option[IsVariantPair].none
    var ok = false
    unsafe:
        match read(pat):
            ast.Expr.expr_member_access:
                ok = true
            _:
                pass
    if not ok:
        return Option[IsVariantPair].none
    if pat_arm.binding_name.is_some():
        return Option[IsVariantPair].none
    let want_true = pat_is_true.unwrap()
    return Option[IsVariantPair].some(value = IsVariantPair(pat_is_first = not wild_is_first, want_true = want_true))


## Reconstruct source text for an expression (best effort).
function expr_source_name(expr: ptr[ast.Expr]?) -> str:
    let ep = expr else:
        return ""
    unsafe:
        match read(ep):
            ast.Expr.expr_identifier as id:
                return id.name
            ast.Expr.expr_member_access as m:
                var buf = string.String.create()
                buf.append(expr_source_name(m.receiver))
                buf.append(".")
                buf.append(m.member_name)
                return buf.as_str()
            _:
                return ""

# =============================================================================
#  redundant-type-annotation — `let x: T = value` where T matches literal type.
# =============================================================================

function check_redundant_type_annotation(
    is_let: bool,
    name: str,
    stmt_type: ptr[ast.TypeRef]?,
    value: ptr[ast.Expr]?,
    line: ptr_uint,
    column: ptr_uint,
    path: str,
    warnings: ref[vec.Vec[Warning]],
) -> void:
    if not is_let:
        return
    let st = stmt_type else:
        return
    let val = value else:
        return
    # The host skips a nullable annotation outright (`return if
    # statement.type.nullable`): `let x: int? = 42` never warns.
    if unsafe: read(st).nullable:
        return
    let type_name = type_ref_leaf_name(st) else:
        return
    redundancy_match(type_name, name, val, line, column, path, warnings)


## If the expression's literal type matches the declared type name, emit a
## redundant-type-annotation warning.
function redundancy_match(
    declared: str,
    name: str,
    val: ptr[ast.Expr],
    line: ptr_uint,
    column: ptr_uint,
    path: str,
    warnings: ref[vec.Vec[Warning]]
) -> void:
    let inferred = expression_literal_type_name(val) else:
        return
    if declared.equal(inferred):
        var buf = string.String.create()
        buf.append("type annotation ': ")
        buf.append(declared)
        buf.append("' is redundant, inferred from initializer")
        # The host anchors on the declaration and spans the local's *name*.
        push_warning_at(warnings, path, line, column, name.len, "redundant-type-annotation", buf.as_str(), "hint")


## Extract the leaf name from a simple TypeRef even when nullable
## (stripping `?`). Returns none for compound types.
function type_ref_leaf_name_nullable(type_ref: ptr[ast.TypeRef]) -> Option[str]:
    unsafe:
        let t = read(type_ref)
        if t.arguments.len > 0:
            return Option[str].none
        if t.fn_params.len > 0:
            return Option[str].none
        if t.is_dyn or t.is_fn or t.is_proc or t.is_tuple:
            return Option[str].none
        if t.name.parts.len != 1:
            return Option[str].none
        return Option[str].some(value = read(t.name.parts.data + 0))


## Extract the leaf name from a simple TypeRef (e.g. `int` → `"int"`),
## or none when it has type arguments, is nullable, or is compound.
function type_ref_leaf_name(type_ref: ptr[ast.TypeRef]) -> Option[str]:
    unsafe:
        let t = read(type_ref)
        if t.arguments.len > 0:
            return Option[str].none
        if t.fn_params.len > 0:
            return Option[str].none
        if t.nullable or t.is_dyn or t.is_fn or t.is_proc or t.is_tuple:
            return Option[str].none
        if t.name.parts.len != 1:
            return Option[str].none
        return Option[str].some(value = read(t.name.parts.data + 0))


## Infer the literal type name of an expression, or none. Handles integer,
## float, string, bool, null, and char literals.
function expression_literal_type_name(expr: ptr[ast.Expr]) -> Option[str]:
    unsafe:
        match read(expr):
            ast.Expr.expr_integer_literal:
                return Option[str].some(value = "int")
            ast.Expr.expr_float_literal:
                return Option[str].some(value = "float")
            ast.Expr.expr_string_literal as s:
                if s.is_cstring:
                    return Option[str].some(value = "cstr")
                return Option[str].some(value = "str")
            ast.Expr.expr_bool_literal:
                return Option[str].some(value = "bool")
            ast.Expr.expr_null_literal:
                return Option[str].some(value = "null")
            ast.Expr.expr_char_literal:
                return Option[str].some(value = "ubyte")
            _:
                return Option[str].none

# =============================================================================
#  prefer-struct-with — struct construction with many copy-field args.
# =============================================================================

## The host's `check_prefer_struct_with`: a constructor literal that copies
## all-but-one field from the same source value can use `.with(...)`.  The
## gates matter as much as the shape: the callee must be an identifier or a
## member access (a specialized `Vec[T](…)` is neither), the target must be a
## *struct* (the host's `Types::Struct` — not a generic instance, union, enum
## or variant), the copied source's type must be that same struct, and the
## copied names must be exactly the struct's fields minus the changed ones.
function check_prefer_struct_with(
    call_expr: ptr[ast.Expr],
    callee: ptr[ast.Expr],
    args: span[ast.Argument],
    path: str,
    warnings: ref[vec.Vec[Warning]]
) -> void:
    let ap = lint_analysis else:
        return
    let analysis = unsafe: ref_of(read(ap))
    unsafe:
        match read(callee):
            ast.Expr.expr_identifier:
                pass
            ast.Expr.expr_member_access:
                pass
            _:
                return
    if args.len < 3:
        return
    var changed_count: ptr_uint = 0
    var copied_count: ptr_uint = 0
    var source_sig: Option[str] = Option[str].none
    var source_receiver: ptr[ast.Expr]? = null
    var changed_fields = vec.Vec[str].create()
    defer: changed_fields.release()
    var copied_fields = vec.Vec[str].create()
    defer: copied_fields.release()

    var ai: ptr_uint = 0
    while ai < args.len:
        unsafe:
            let arg = read(args.data + ai)
            let field_name = arg.arg_name else:
                return
            match read(arg.arg_value):
                ast.Expr.expr_member_access as m:
                    let field_sig = expr_source_sig(m.receiver)
                    if m.member_name.equal(field_name):
                        # This arg is a copy from a source struct.
                        copied_count += 1
                        copied_fields.push(field_name)
                        if source_receiver == null:
                            source_receiver = m.receiver
                        match source_sig:
                            Option.some as prev:
                                if not field_sig.equal(prev.value):
                                    return
                            Option.none:
                                source_sig = Option[str].some(value = field_sig)
                    else:
                        changed_count += 1
                        changed_fields.push(field_name)
                _:
                    changed_count += 1
                    changed_fields.push(field_name)
        ai += 1

    if changed_count == 0 or copied_count < 2:
        return

    let target_ty = prefer_struct_with_expr_type(analysis, call_expr) else:
        return
    let struct_fields = prefer_struct_with_fields(analysis, target_ty) else:
        return
    let receiver = source_receiver else:
        return
    let source_ty = prefer_struct_with_expr_type(analysis, receiver) else:
        return
    if not prefer_struct_with_same_type(source_ty, target_ty):
        return
    if not prefer_struct_with_partition_ok(struct_fields, ref_of(copied_fields), ref_of(changed_fields)):
        return

    let source_text = prefer_struct_with_source_name(receiver)
    var buf = string.String.create()
    buf.append("copies ")
    buf.append(uint_to_str(copied_count))
    buf.append(" field(s) from `")
    buf.append(source_text)
    buf.append("`; use `")
    buf.append(source_text)
    buf.append(".with(")
    var first = true
    var ci: ptr_uint = 0
    while ci < changed_fields.len():
        let fp = changed_fields.get(ci) else:
            break
        if not first:
            buf.append(", ")
        buf.append(unsafe: read(fp))
        first = false
        ci += 1
    buf.append(" = …)`")
    push_warning_at(
        warnings,
        path,
        expression_line(callee),
        expression_column(callee),
        0,
        "prefer-struct-with",
        buf.as_str(),
        "hint"
    )


## The resolved type of an expression from the analysis record.
function prefer_struct_with_expr_type(analysis: ref[analyzer.Analysis], expr: ptr[ast.Expr]) -> Option[types.Type]:
    let tp = unsafe: read(analysis).resolved_expr_types.get(reinterpret[ptr_uint](expr)) else:
        return Option[types.Type].none
    return Option[types.Type].some(value = unsafe: read(tp))


## The target struct's fields, or none when the type is not a plain struct:
## a `ty_named` only when the module's struct table carries it (enums, unions
## and variants are separate tables), and an imported instance only without
## type arguments (a generic instance is the host's `GenericInstance`, not a
## `Struct`).
function prefer_struct_with_fields(
    analysis: ref[analyzer.Analysis],
    ty: types.Type
) -> Option[span[analyzer.FieldEntry]]:
    match ty:
        types.Type.ty_named as n:
            let n_np = unsafe: read(n.payload)
            let fp = unsafe: read(analysis).structs.get(n_np.name) else:
                return Option[span[analyzer.FieldEntry]].none
            return Option[span[analyzer.FieldEntry]].some(value = unsafe: read(fp))
        types.Type.ty_imported as im:
            let im_bp = unsafe: read(im.payload)
            if im_bp.args.len > 0:
                return Option[span[analyzer.FieldEntry]].none
            return prefer_struct_with_binding_fields(im_bp.module_name, im_bp.name)
        _:
            return Option[span[analyzer.FieldEntry]].none


## An imported type's struct fields, resolved through the loader's binding
## table.  This deliberately does not read `Analysis.imported_type_members`:
## that map is collected only when `tooling_facts` is on (the LSP), so a plain
## `check` or `lint` leaves it empty and the rule would silently stop firing.
##
## A re-exported struct carries the alias module and name
## (`std.raylib.Vector3` aliasing `std.c.raylib.Vector3`), so an alias is
## followed to the binding that declares the struct.  The alias wins over a
## same-named struct or union, matching the order the map was built in.
function prefer_struct_with_binding_fields(module_name: str, type_name: str) -> Option[span[analyzer.FieldEntry]]:
    let ap = lint_analysis else:
        return Option[span[analyzer.FieldEntry]].none
    let analysis = unsafe: ref_of(read(ap))
    let bindings = unsafe: read(analysis).imported_modules else:
        return Option[span[analyzer.FieldEntry]].none
    let binding_ptr = unsafe: read(bindings).get(module_name) else:
        return Option[span[analyzer.FieldEntry]].none
    # Read every table through the binding pointer: a `ModuleBinding` is a by-value
    # struct of maps, and copying it would make each map lookup read a stale copy.
    unsafe:
        let alias_ptr = read(binding_ptr).type_alias_types.get(type_name)
        if alias_ptr != null:
            return prefer_struct_with_alias_fields(bindings, read(alias_ptr), module_name)
        let struct_ptr = read(binding_ptr).structs.get(type_name)
        if struct_ptr != null:
            return Option[span[analyzer.FieldEntry]].some(value = read(struct_ptr))
        let union_ptr = read(binding_ptr).unions.get(type_name)
        if union_ptr != null:
            return Option[span[analyzer.FieldEntry]].some(value = read(union_ptr))
    return Option[span[analyzer.FieldEntry]].none


## The struct fields a type alias resolves to: an imported target resolves in
## its own binding, a plain name in the alias' module.  An alias to anything
## else (a proc, a primitive, a generic instance) has no struct fields.
function prefer_struct_with_alias_fields(
    bindings: ptr[map_mod.Map[str, analyzer.ModuleBinding]],
    target: types.Type,
    alias_module: str
) -> Option[span[analyzer.FieldEntry]]:
    match target:
        types.Type.ty_imported as tim:
            let tim_bp = unsafe: read(tim.payload)
            let target_ptr = unsafe: read(bindings).get(tim_bp.module_name) else:
                return Option[span[analyzer.FieldEntry]].none
            let fp = unsafe: read(target_ptr).structs.get(tim_bp.name) else:
                return Option[span[analyzer.FieldEntry]].none
            return Option[span[analyzer.FieldEntry]].some(value = unsafe: read(fp))
        types.Type.ty_named as tn:
            let tn_np = unsafe: read(tn.payload)
            if not tn_np.module_name.equal(alias_module):
                return Option[span[analyzer.FieldEntry]].none
            let target_ptr = unsafe: read(bindings).get(alias_module) else:
                return Option[span[analyzer.FieldEntry]].none
            let fp = unsafe: read(target_ptr).structs.get(tn_np.name) else:
                return Option[span[analyzer.FieldEntry]].none
            return Option[span[analyzer.FieldEntry]].some(value = unsafe: read(fp))
        _:
            return Option[span[analyzer.FieldEntry]].none


## The host compares the copied source's type with the target struct's by
## qualified name (`source_type.to_s == struct_type.to_s`).  A local struct
## constructor records the moduleless `ty_named` form while an annotation
## carries the module, so an empty module matches any; a `ty_imported` and a
## `ty_named` naming the same module/type render identically and compare equal.
function prefer_struct_with_same_type(a: types.Type, b: types.Type) -> bool:
    match a:
        types.Type.ty_named as na:
            let na_np = unsafe: read(na.payload)
            match b:
                types.Type.ty_named as nb:
                    let nb_np = unsafe: read(nb.payload)
                    return named_modules_match(na_np.name, na_np.module_name, nb_np.name, nb_np.module_name)
                types.Type.ty_imported as ib:
                    let ib_bp = unsafe: read(ib.payload)
                    if ib_bp.args.len > 0:
                        return false
                    return named_modules_match(na_np.name, na_np.module_name, ib_bp.name, ib_bp.module_name)
                _:
                    return false
        types.Type.ty_imported as ia:
            let ia_bp = unsafe: read(ia.payload)
            if ia_bp.args.len > 0:
                return false
            match b:
                types.Type.ty_imported as ib:
                    let ib_bp = unsafe: read(ib.payload)
                    if ib_bp.args.len > 0:
                        return false
                    return named_modules_match(ia_bp.name, ia_bp.module_name, ib_bp.name, ib_bp.module_name)
                types.Type.ty_named as nb:
                    let nb_np = unsafe: read(nb.payload)
                    return named_modules_match(ia_bp.name, ia_bp.module_name, nb_np.name, nb_np.module_name)
                _:
                    return false
        _:
            return false


function named_modules_match(name_a: str, module_a: str, name_b: str, module_b: str) -> bool:
    if not name_a.equal(name_b):
        return false
    return module_a.equal(module_b) or module_a.len == 0 or module_b.len == 0


## The host's `(field_names - changed_names) == copied_names`: every copied
## name is a field that was not changed, and every field not changed is copied.
function prefer_struct_with_partition_ok(
    fields: span[analyzer.FieldEntry],
    copied: ref[vec.Vec[str]],
    changed: ref[vec.Vec[str]]
) -> bool:
    var ci: ptr_uint = 0
    while ci < copied.len():
        let cp = copied.get(ci) else:
            break
        let name = unsafe: read(cp)
        if ownership_contains(changed, name) or not prefer_struct_with_has_field(fields, name):
            return false
        ci += 1
    var fi: ptr_uint = 0
    while fi < fields.len:
        let field_name = unsafe: read(fields.data + fi).name
        if not ownership_contains(changed, field_name) and not ownership_contains(copied, field_name):
            return false
        fi += 1
    return true


function prefer_struct_with_has_field(fields: span[analyzer.FieldEntry], name: str) -> bool:
    var fi: ptr_uint = 0
    while fi < fields.len:
        if unsafe: read(fields.data + fi).name.equal(name):
            return true
        fi += 1
    return false


## The host's `expr_source_name`: identifiers and member chains render
## dotted, everything else is the ellipsis.
function prefer_struct_with_source_name(expr: ptr[ast.Expr]) -> str:
    unsafe:
        match read(expr):
            ast.Expr.expr_identifier as id:
                return id.name
            ast.Expr.expr_member_access as m:
                var buf = string.String.create()
                buf.append(prefer_struct_with_source_name(m.receiver))
                buf.append(".")
                buf.append(m.member_name)
                return buf.as_str()
            _:
                return "…"


function uint_to_str(n: ptr_uint) -> str:
    return analyzer.uint_to_str(n)

# =============================================================================
#  line-too-long — source-level check for lines exceeding the max length.
# =============================================================================

public const DEFAULT_MAX_LINE_LENGTH: ptr_uint = 120


function lint_line_too_long(
    source: str,
    tokens: vec.Vec[token_mod.Token],
    path: str,
    max_line_length: ptr_uint,
    warnings: ref[vec.Vec[Warning]]
) -> void:
    var start: ptr_uint = 0
    var line_index: ptr_uint = 0
    var i: ptr_uint = 0
    while i <= source.len:
        if i == source.len or source.byte_at(i) == 10:
            let line_text = source.slice(start, i - start)
            lint_one_long_line(source, tokens, path, line_index, line_text, max_line_length, warnings)
            line_index += 1
            start = i + 1
        i += 1


## One line: only wrappable over-long lines are reported (host
## `emit_line_too_long_warnings`), with the host's column/length and the
## `; wrap the expression` suffix when the formatter can wrap it.
function lint_one_long_line(
    source: str,
    tokens: vec.Vec[token_mod.Token],
    path: str,
    line_index: ptr_uint,
    line: str,
    max_line_length: ptr_uint,
    warnings: ref[vec.Vec[Warning]]
) -> void:
    if line.len == 0:
        return
    if is_external_or_foreign_function_header_line(line):
        return
    # Count UTF-8 characters rather than bytes for accurate column width.
    let char_count = utf8_char_width(line)
    if char_count <= max_line_length:
        return
    if not tidy.wrappable_long_line_candidate_text(line):
        return

    var message = string.String.create()
    message.append("line exceeds max length of ")
    message.append(uint_to_str(max_line_length))
    message.append(" columns (")
    message.append(uint_to_str(char_count))
    message.append(")")
    let maybe_fix = tidy.build_line_wrap_fix_with_tokens(source, tokens, line_index, max_line_length, path, false)
    if maybe_fix.is_some():
        message.append("; wrap the expression")
        var fix = maybe_fix.unwrap()
        fix.new_text.release()

    push_warning_at(
        warnings,
        path,
        line_index + 1,
        max_line_length + 1,
        char_count - max_line_length,
        "line-too-long",
        message.as_str(),
        "warning",
    )


## Host `external_or_foreign_function_header_line?`:
## `\A(?:[A-Za-z_]\w*\s+)*(?:external|foreign)\s+function\b` on the trimmed line.
function is_external_or_foreign_function_header_line(line: str) -> bool:
    let t = line.trim_ascii_whitespace()
    var pos: ptr_uint = 0
    while pos < t.len:
        var keyword = ""
        if word_matches(t, pos, "external"):
            keyword = "external"
        else if word_matches(t, pos, "foreign"):
            keyword = "foreign"
        if keyword.len > 0:
            let after = pos + keyword.len
            let ws = space_run_end(t, after)
            if ws == after:
                return false
            return word_matches(t, ws, "function")
        let word_len = identifier_word_len(t, pos)
        if word_len == 0:
            return false
        let ws = space_run_end(t, pos + word_len)
        if ws == pos + word_len:
            return false
        pos = ws
    return false


function word_matches(t: str, pos: ptr_uint, word: str) -> bool:
    if pos + word.len > t.len:
        return false
    var i: ptr_uint = 0
    while i < word.len:
        if t.byte_at(pos + i) != word.byte_at(i):
            return false
        i += 1
    if pos + word.len == t.len:
        return true
    return not is_word_byte(t.byte_at(pos + word.len))


function identifier_word_len(t: str, pos: ptr_uint) -> ptr_uint:
    if pos >= t.len:
        return 0
    if not is_word_start_byte(t.byte_at(pos)):
        return 0
    var i = pos + 1
    while i < t.len and is_word_byte(t.byte_at(i)):
        i += 1
    return i - pos


function is_word_start_byte(b: ubyte) -> bool:
    return (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or b == '_'


function is_word_byte(b: ubyte) -> bool:
    return is_word_start_byte(b) or (b >= '0' and b <= '9')


function space_run_end(t: str, pos: ptr_uint) -> ptr_uint:
    var i = pos
    while i < t.len:
        let b = t.byte_at(i)
        if b != ' ' and b != '\t':
            break
        i += 1
    return i


function utf8_char_width(s: str) -> ptr_uint:
    var count: ptr_uint = 0
    var i: ptr_uint = 0
    while i < s.len:
        let b = s.byte_at(i)
        if b < 0x80:
            i += 1
        else if b >= 0xC0 and b < 0xE0:
            i += 2
        else if b >= 0xE0 and b < 0xF0:
            i += 3
        else:
            i += 4
        count += 1
    return count

# =============================================================================
#  owning-release-leak / owning-release-double — AST-based ownership checks.
# =============================================================================

## A collected owning binding: where it was declared and which owning type it
## holds, so the leak warning anchors on the declaration and names the type
## (the host's `owning binding 'x' of type 'T' is never released`).
struct OwningBinding:
    line: ptr_uint
    type_name: str


## The owning type's name for a creation call (`vec.Vec[int].create()` -> `Vec`,
## `Counter.make()` -> `Counter`, `Sample(...)` -> `Sample`).
function own_created_type_name(value: ptr[ast.Expr]?, stmt_type: ptr[ast.TypeRef]?) -> str:
    let type_ref = stmt_type else:
        return own_call_type_name(value)
    return owning_annotation_type_name(type_ref)


## The base name of an owning annotation (`Map[str, str]` -> `Map`).
function owning_annotation_type_name(type_ref: ptr[ast.TypeRef]) -> str:
    unsafe:
        let t = read(type_ref)
        if t.name.parts.len == 0:
            return ""
        return read(t.name.parts.data + (t.name.parts.len - 1))


function own_call_type_name(value: ptr[ast.Expr]?) -> str:
    let ep = value else:
        return ""
    unsafe:
        match read(ep):
            ast.Expr.expr_call as call:
                return own_callee_type_name(call.callee)
            _:
                return ""


function own_callee_type_name(callee: ptr[ast.Expr]) -> str:
    unsafe:
        match read(callee):
            ast.Expr.expr_identifier as id:
                return id.name
            ast.Expr.expr_member_access as ma:
                if not is_create_method_name(ma.member_name) and not is_alloc_method_name(ma.member_name):
                    return ""
                match read(ma.receiver):
                    ast.Expr.expr_identifier as rid:
                        # `Counter.create()`: the receiver names the type.
                        return rid.name
                    ast.Expr.expr_member_access as inner:
                        # `alias.Counter.create()`.
                        return inner.member_name
                    ast.Expr.expr_specialization as recv_spec:
                        # `vec.Vec[int].create()` / `Vec[int].create()`.
                        match read(recv_spec.callee):
                            ast.Expr.expr_member_access as spec_member:
                                return spec_member.member_name
                            ast.Expr.expr_identifier as spec_id:
                                return spec_id.name
                            _:
                                return ""
                    _:
                        return ""
            ast.Expr.expr_specialization as spec:
                match read(spec.callee):
                    ast.Expr.expr_member_access as sma:
                        return sma.member_name
                    _:
                        return ""
            _:
                return ""

## Walk all function-like bodies to collect owning locals and release calls,
## then report leaks and double-releases.

# =============================================================================
#  The host's release rules tail: `own[T]` leaks and the sequential
#  double-release check (`release_rules.rb`).
# =============================================================================

struct OwnBinding:
    name: str
    line: ptr_uint
    column: ptr_uint
    type_name: str


## The host's `check_own_release_leaks`: every `own[T]`-typed local that is
## never released on any path and never transferred is a leak.
function ownership_own_leaks(body: ptr[ast.Stmt]?, path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    let b = body else:
        return
    var locals = vec.Vec[OwnBinding].create()
    defer: locals.release()
    ownership_collect_own_locals(b, ref_of(locals))
    var released = vec.Vec[str].create()
    defer: released.release()
    ownership_collect_own_released(b, ref_of(released))
    var i: ptr_uint = 0
    while i < locals.len():
        let lp = locals.get(i) else:
            break
        unsafe:
            let lb = read(lp)
            if not ownership_contains(ref_of(released), lb.name) and not ownership_own_transferred(b, lb.name):
                var buf = string.String.create()
                buf.append("owning binding '")
                buf.append(lb.name)
                buf.append("' of type '")
                buf.append(lb.type_name)
                buf.append("' is never released")
                push_warning_at(
                    warnings,
                    path,
                    lb.line,
                    lb.column,
                    lb.name.len,
                    "owning-release-leak",
                    buf.as_str(),
                    "warning"
                )
        i += 1


## The host's `_collect_own_typed_locals`.
function ownership_collect_own_locals(body: ptr[ast.Stmt], sink: ref[vec.Vec[OwnBinding]]) -> void:
    unsafe:
        match read(body):
            ast.Stmt.stmt_block as blk:
                var si: ptr_uint = 0
                while si < blk.statements.len:
                    ownership_collect_own_locals_stmt(blk.statements.data + si, sink)
                    si += 1
            _:
                ownership_collect_own_locals_stmt(body, sink)


function ownership_collect_own_locals_stmt(stmt: ptr[ast.Stmt], sink: ref[vec.Vec[OwnBinding]]) -> void:
    unsafe:
        match read(stmt):
            ast.Stmt.stmt_local as loc:
                if loc.name.len > 0:
                    match own_local_type(loc.value):
                        Option.some as type_name:
                            sink.push(OwnBinding(
                                name = loc.name,
                                line = loc.line,
                                column = loc.column,
                                type_name = type_name.value
                            ))
                        Option.none:
                            pass
            ast.Stmt.stmt_if as iff:
                var bi: ptr_uint = 0
                while bi < iff.branches.len:
                    ownership_collect_own_locals_body(read(iff.branches.data + bi).body, sink)
                    bi += 1
                ownership_collect_own_locals_body(iff.else_body, sink)
            ast.Stmt.stmt_while as wh:
                ownership_collect_own_locals_body(wh.body, sink)
            ast.Stmt.stmt_for as fr:
                ownership_collect_own_locals_body(fr.body, sink)
            ast.Stmt.stmt_match as mt:
                var ai: ptr_uint = 0
                while ai < mt.arms.len:
                    ownership_collect_own_locals_body(read(mt.arms.data + ai).body, sink)
                    ai += 1
            ast.Stmt.stmt_unsafe as un:
                ownership_collect_own_locals_body(un.body, sink)
            ast.Stmt.stmt_defer as df:
                ownership_collect_own_locals_body(df.body, sink)
            _:
                pass


function ownership_collect_own_locals_body(body: ptr[ast.Stmt]?, sink: ref[vec.Vec[OwnBinding]]) -> void:
    let b = body else:
        return
    ownership_collect_own_locals(b, sink)


## The host's `resolve_local_own_pointer_type`: a heap allocation is
## `own[<inferred>]`; otherwise the initializer's resolved type when it is an
## `own[T]` generic instance.
function own_local_type(value: ptr[ast.Expr]?) -> Option[str]:
    if release_heap_alloc_call(value):
        return Option[str].some(value = "own[<inferred>]")
    let v = value else:
        return Option[str].none
    let ap = lint_analysis else:
        return Option[str].none
    let ep = unsafe: read(ap).resolved_expr_types.get(reinterpret[ptr_uint](v)) else:
        return Option[str].none
    unsafe:
        match read(ep):
            types.Type.ty_generic as g:
                let g_bp = unsafe: read(g.payload)
                if g_bp.name.equal("own"):
                    return Option[str].some(value = types.type_to_string(read(ep)))
            types.Type.ty_imported as im:
                let im_bp = unsafe: read(im.payload)
                if im_bp.name.equal("own"):
                    return Option[str].some(value = types.type_to_string(read(ep)))
            _:
                pass
    return Option[str].none


## The linter's `is_heap_alloc_call?` — the allocation wrappers that yield an
## `own[T]` (`must_alloc` and friends; the plain `alloc` is *not* one here).
function release_heap_alloc_call(value: ptr[ast.Expr]?) -> bool:
    let vp = value else:
        return false
    unsafe:
        match read(vp):
            ast.Expr.expr_call as call:
                match read(call.callee):
                    ast.Expr.expr_member_access as ma:
                        return ma.member_name.equal("must_alloc") or ma.member_name.equal("must_alloc_aligned") or ma.member_name.equal("must_alloc_zeroed") or ma.member_name.equal("must_resize")
                    ast.Expr.expr_specialization as sp:
                        match read(sp.callee):
                            ast.Expr.expr_member_access as ma:
                                return ma.member_name.equal("must_alloc") or ma.member_name.equal("must_alloc_aligned") or ma.member_name.equal("must_alloc_zeroed") or ma.member_name.equal("must_resize")
                            _:
                                return false
                    _:
                        return false
            _:
                return false


## The host's `_collect_heap_release_names` / `heap_release_call_on_name?`:
## `heap.release(x)` / `heap.release_and_null(x)` (and `x.release()`), naming
## the last direct-identifier argument.
function ownership_collect_own_released(body: ptr[ast.Stmt], sink: ref[vec.Vec[str]]) -> void:
    unsafe:
        match read(body):
            ast.Stmt.stmt_block as blk:
                var si: ptr_uint = 0
                while si < blk.statements.len:
                    ownership_collect_own_released_stmt(blk.statements.data + si, sink)
                    si += 1
            _:
                ownership_collect_own_released_stmt(body, sink)


function ownership_collect_own_released_stmt(stmt: ptr[ast.Stmt], sink: ref[vec.Vec[str]]) -> void:
    unsafe:
        match read(stmt):
            ast.Stmt.stmt_expression as ex:
                ownership_collect_own_released_expr(ex.expression, sink)
            ast.Stmt.stmt_ret as r:
                ownership_collect_own_released_expr_opt(r.value, sink)
            ast.Stmt.stmt_local as loc:
                ownership_collect_own_released_expr_opt(loc.value, sink)
            ast.Stmt.stmt_assignment as a:
                ownership_collect_own_released_expr(a.value, sink)
            ast.Stmt.stmt_if as iff:
                var bi: ptr_uint = 0
                while bi < iff.branches.len:
                    ownership_collect_own_released_body(read(iff.branches.data + bi).body, sink)
                    bi += 1
                ownership_collect_own_released_body(iff.else_body, sink)
            ast.Stmt.stmt_while as wh:
                ownership_collect_own_released_body(wh.body, sink)
            ast.Stmt.stmt_for as fr:
                ownership_collect_own_released_body(fr.body, sink)
            ast.Stmt.stmt_match as mt:
                var ai: ptr_uint = 0
                while ai < mt.arms.len:
                    ownership_collect_own_released_body(read(mt.arms.data + ai).body, sink)
                    ai += 1
            ast.Stmt.stmt_unsafe as un:
                ownership_collect_own_released_body(un.body, sink)
            ast.Stmt.stmt_defer as df:
                ownership_collect_own_released_body(df.body, sink)
            _:
                pass


function ownership_collect_own_released_body(body: ptr[ast.Stmt]?, sink: ref[vec.Vec[str]]) -> void:
    let b = body else:
        return
    ownership_collect_own_released(b, sink)


function ownership_collect_own_released_expr_opt(expr: ptr[ast.Expr]?, sink: ref[vec.Vec[str]]) -> void:
    let ep = expr else:
        return
    ownership_collect_own_released_expr(ep, sink)


function ownership_collect_own_released_expr(expr: ptr[ast.Expr], sink: ref[vec.Vec[str]]) -> void:
    unsafe:
        match read(expr):
            ast.Expr.expr_call as call:
                let name = heap_release_target_name(expr)
                if name.len > 0:
                    if not ownership_contains(sink, name):
                        sink.push(name)
                ownership_collect_own_released_expr(call.callee, sink)
                var ai: ptr_uint = 0
                while ai < call.args.len:
                    ownership_collect_own_released_expr(read(call.args.data + ai).arg_value, sink)
                    ai += 1
            ast.Expr.expr_binary_op as b:
                ownership_collect_own_released_expr(b.left, sink)
                ownership_collect_own_released_expr(b.right, sink)
            ast.Expr.expr_unary_op as u:
                ownership_collect_own_released_expr(u.operand, sink)
            ast.Expr.expr_member_access as m:
                ownership_collect_own_released_expr(m.receiver, sink)
            ast.Expr.expr_index_access as ix:
                ownership_collect_own_released_expr(ix.receiver, sink)
                ownership_collect_own_released_expr(ix.index, sink)
            ast.Expr.expr_prefix_cast as pc:
                ownership_collect_own_released_expr(pc.expression, sink)
            ast.Expr.expr_unsafe as us:
                ownership_collect_own_released_expr(us.expression, sink)
            ast.Expr.expr_expression_list as el:
                var ei: ptr_uint = 0
                while ei < el.elements.len:
                    ownership_collect_own_released_expr(el.elements.data + ei, sink)
                    ei += 1
            _:
                pass


## The host's `heap_release_call_on_name?`: a `release`/`release_and_null`
## call with at least one argument, naming the last direct-identifier argument
## (or the identifier inside a `ref_of(...)`).
function heap_release_target_name(expr: ptr[ast.Expr]) -> str:
    unsafe:
        match read(expr):
            ast.Expr.expr_call as call:
                match read(call.callee):
                    ast.Expr.expr_member_access as ma:
                        if not (ma.member_name.equal("release") or ma.member_name.equal("release_and_null")):
                            return ""
                    _:
                        return ""
                if call.args.len < 1:
                    return ""
                var released: str = ""
                var ai: ptr_uint = 0
                while ai < call.args.len:
                    let value = read(call.args.data + ai).arg_value
                    var inner = value
                    unsafe:
                        match read(value):
                            ast.Expr.expr_unsafe as us:
                                inner = us.expression
                            _:
                                pass
                    match read(inner):
                        ast.Expr.expr_identifier as id:
                            released = id.name
                        ast.Expr.expr_call as ic:
                            match read(ic.callee):
                                ast.Expr.expr_identifier as cid:
                                    if cid.name.equal("ref_of") and ic.args.len == 1:
                                        match read(read(ic.args.data + 0).arg_value):
                                            ast.Expr.expr_identifier as rid:
                                                released = rid.name
                                            _:
                                                pass
                                _:
                                    pass
                        _:
                            pass
                    ai += 1
                return released
            _:
                return ""


## The host's `own_transferred?`.
function ownership_own_transferred(body: ptr[ast.Stmt], name: str) -> bool:
    unsafe:
        match read(body):
            ast.Stmt.stmt_block as blk:
                var si: ptr_uint = 0
                while si < blk.statements.len:
                    if ownership_own_transferred_stmt(blk.statements.data + si, name):
                        return true
                    si += 1
                return false
            _:
                return ownership_own_transferred_stmt(body, name)


function ownership_own_transferred_stmt(stmt: ptr[ast.Stmt], name: str) -> bool:
    if ownership_own_transferred_direct(stmt, name):
        return true
    unsafe:
        match read(stmt):
            ast.Stmt.stmt_if as iff:
                var bi: ptr_uint = 0
                while bi < iff.branches.len:
                    if ownership_own_transferred(read(iff.branches.data + bi).body, name):
                        return true
                    bi += 1
                return ownership_own_transferred_opt(iff.else_body, name)
            ast.Stmt.stmt_while as wh:
                return ownership_own_transferred_opt(wh.body, name)
            ast.Stmt.stmt_for as fr:
                return ownership_own_transferred_opt(fr.body, name)
            ast.Stmt.stmt_match as mt:
                var ai: ptr_uint = 0
                while ai < mt.arms.len:
                    if ownership_own_transferred_opt(read(mt.arms.data + ai).body, name):
                        return true
                    ai += 1
                return false
            ast.Stmt.stmt_unsafe as un:
                return ownership_own_transferred_opt(un.body, name)
            ast.Stmt.stmt_defer as df:
                return ownership_own_transferred_opt(df.body, name)
            _:
                return false


function ownership_own_transferred_opt(body: ptr[ast.Stmt]?, name: str) -> bool:
    let bp = body else:
        return false
    return ownership_own_transferred(bp, name)


## The direct predicates of the host's `own_transferred?` block.
function ownership_own_transferred_direct(stmt: ptr[ast.Stmt], name: str) -> bool:
    unsafe:
        match read(stmt):
            ast.Stmt.stmt_ret as r:
                let rv = r.value else:
                    return false
                match read(rv):
                    ast.Expr.expr_identifier as id:
                        if id.name.equal(name):
                            return true
                    ast.Expr.expr_unsafe as us:
                        match read(us.expression):
                            ast.Expr.expr_prefix_cast as pc:
                                match read(pc.expression):
                                    ast.Expr.expr_identifier as inner:
                                        if inner.name.equal(name):
                                            return true
                                    _:
                                        pass
                            _:
                                pass
                    _:
                        pass
                return ownership_transfer_call_on(r.value, name)
            ast.Stmt.stmt_assignment as a:
                let value = a.value
                match read(value):
                    ast.Expr.expr_identifier as id:
                        if id.name.equal(name):
                            return true
                    _:
                        pass
                return ownership_transfer_call_on(value, name)
            ast.Stmt.stmt_local as loc:
                return ownership_transfer_call_on(loc.value, name)
            ast.Stmt.stmt_expression as ex:
                return ownership_transfer_call_on(ex.expression, name)
            _:
                return false


## The host's `own_struct_field_transfer?`: a call with an argument that
## mentions the binding (through casts or nested calls).
function ownership_transfer_call_on(expr: ptr[ast.Expr]?, name: str) -> bool:
    let ep = expr else:
        return false
    unsafe:
        match read(ep):
            ast.Expr.expr_call as call:
                var ai: ptr_uint = 0
                while ai < call.args.len:
                    if own_transfer_identifier(read(call.args.data + ai).arg_value, name):
                        return true
                    ai += 1
                return false
            ast.Expr.expr_prefix_cast as pc:
                return own_transfer_identifier(pc.expression, name)
            _:
                return false


function own_transfer_identifier(value: ptr[ast.Expr], name: str) -> bool:
    unsafe:
        match read(value):
            ast.Expr.expr_identifier as id:
                return id.name.equal(name)
            ast.Expr.expr_prefix_cast as pc:
                return own_transfer_identifier(pc.expression, name)
            ast.Expr.expr_call as call:
                var ai: ptr_uint = 0
                while ai < call.args.len:
                    if own_transfer_identifier(read(call.args.data + ai).arg_value, name):
                        return true
                    ai += 1
                return false
            _:
                return false


## The host's `check_owning_release_double`: per statement list, the release
## sites per binding; two releases of one binding through the same sequence
## warn at the *last* release's line (the LSP recovers the range from the
## quoted name).  `unsafe:` and `defer:` bodies are separate sequences, and
## their results merge after the outer sequence.
function ownership_double_warnings(body: ptr[ast.Stmt]?, path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    let b = body else:
        return
    var result_names = vec.Vec[str].create()
    defer: result_names.release()
    var result_lines = map_mod.Map[str, ptr_uint].create()
    defer: result_lines.release()
    ownership_double_scope(b, ref_of(result_names), ref_of(result_lines))
    var i: ptr_uint = 0
    while i < result_names.len():
        let np = result_names.get(i) else:
            break
        let name = unsafe: read(np)
        var line: ptr_uint = 0
        let lp = result_lines.get(name)
        if lp != null:
            unsafe:
                line = read(lp)
        var buf = string.String.create()
        buf.append("owning binding '")
        buf.append(name)
        buf.append("' may be released more than once")
        push_warning(warnings, path, line, "owning-release-double", buf.as_str(), "warning")
        i += 1


function ownership_double_scope(
    body: ptr[ast.Stmt]?,
    result_names: ref[vec.Vec[str]],
    result_lines: ref[map_mod.Map[str, ptr_uint]]
) -> void:
    let b = body else:
        return
    unsafe:
        match read(b):
            ast.Stmt.stmt_block as blk:
                ownership_double_in_stmts(blk.statements, result_names, result_lines)
            _:
                pass


function ownership_double_in_stmts(
    stmts: span[ast.Stmt],
    result_names: ref[vec.Vec[str]],
    result_lines: ref[map_mod.Map[str, ptr_uint]]
) -> void:
    var names = vec.Vec[str].create()
    defer: names.release()
    var counts = map_mod.Map[str, ptr_uint].create()
    defer: counts.release()
    var lines = map_mod.Map[str, ptr_uint].create()
    defer: lines.release()
    var si: ptr_uint = 0
    while si < stmts.len:
        unsafe:
            let stmt = stmts.data + si
            ownership_double_note_stmt(stmt, ref_of(names), ref_of(counts), ref_of(lines))
            match read(stmt):
                ast.Stmt.stmt_unsafe as un:
                    ownership_double_scope(un.body, result_names, result_lines)
                ast.Stmt.stmt_defer as df:
                    ownership_double_scope(df.body, result_names, result_lines)
                _:
                    pass
        si += 1
    # Names with more than one release in this sequence (the host's
    # ).
    var i: ptr_uint = 0
    while i < names.len():
        let np = names.get(i) else:
            break
        let name = unsafe: read(np)
        let count_ptr = counts.get(name)
        let count = if count_ptr != null: unsafe: read(count_ptr) else: 0
        if count > 1 and not ownership_contains(result_names, name):
            result_names.push(name)
            let lp = lines.get(name)
            if lp != null:
                unsafe:
                    result_lines.set(name, read(lp))
        i += 1


## Record one statement's release (the host's ).
function ownership_double_note_stmt(
    stmt: ptr[ast.Stmt],
    names: ref[vec.Vec[str]],
    counts: ref[map_mod.Map[str, ptr_uint]],
    lines: ref[map_mod.Map[str, ptr_uint]]
) -> void:
    var name: str = ""
    match ownership_extract_expr(stmt):
        Option.some as ep:
            unsafe:
                if release_call_on_binding(ep.value):
                    match read(ep.value):
                        ast.Expr.expr_call as call:
                            match read(call.callee):
                                ast.Expr.expr_member_access as ma:
                                    match read(ma.receiver):
                                        ast.Expr.expr_identifier as id:
                                            name = id.name
                                        _:
                                            pass
                                _:
                                    pass
                        _:
                            pass
                else:
                    name = heap_release_target_name(ep.value)
        Option.none:
            pass
    if name.len > 0:
        let count_ptr = counts.get(name)
        let count = if count_ptr != null: unsafe: read(count_ptr) else: 0
        if count == 0:
            names.push(name)
        counts.set(name, count + 1)
        unsafe:
            lines.set(name, rules_redundant_else.statement_line(stmt))
    ownership_double_note_reassign(stmt, counts)


## The host's : an  assignment to a visible
## binding clears that binding's release history.
function ownership_double_note_reassign(stmt: ptr[ast.Stmt], counts: ref[map_mod.Map[str, ptr_uint]]) -> void:
    unsafe:
        match read(stmt):
            ast.Stmt.stmt_assignment as a:
                if not a.operator.equal("="):
                    return
                match read(a.target):
                    ast.Expr.expr_identifier as id:
                        if scope_name_visible(id.name):
                            counts.set(id.name, 0)
                    _:
                        pass
            _:
                pass


## The host's `extract_expr`: the expression a statement would be checked in.
function ownership_extract_expr(stmt: ptr[ast.Stmt]) -> Option[ptr[ast.Expr]]:
    unsafe:
        match read(stmt):
            ast.Stmt.stmt_expression as ex:
                return Option[ptr[ast.Expr]].some(value = ex.expression)
            ast.Stmt.stmt_ret as r:
                let rv = r.value else:
                    return Option[ptr[ast.Expr]].none
                return Option[ptr[ast.Expr]].some(value = rv)
            ast.Stmt.stmt_local as loc:
                let lv = loc.value else:
                    return Option[ptr[ast.Expr]].none
                return Option[ptr[ast.Expr]].some(value = lv)
            ast.Stmt.stmt_assignment as a:
                return Option[ptr[ast.Expr]].some(value = a.value)
            _:
                return Option[ptr[ast.Expr]].none


## The host's `release_call_on_binding?`: `x.release()` (no arguments).
function release_call_on_binding(expr: ptr[ast.Expr]) -> bool:
    unsafe:
        match read(expr):
            ast.Expr.expr_call as call:
                if call.args.len > 0:
                    return false
                match read(call.callee):
                    ast.Expr.expr_member_access as ma:
                        if not ma.member_name.equal("release"):
                            return false
                        match read(ma.receiver):
                            ast.Expr.expr_identifier:
                                return true
                            _:
                                return false
                    _:
                        return false
            _:
                return false


## Whether the name is a visible binding of the walk (the host's ).
function scope_name_visible(name: str) -> bool:
    let c = lint_scope_ctx else:
        return false
    let ctx = unsafe: ref_of(read(c))
    let count = unsafe: read(ctx).scope_count
    var si: ptr_uint = 0
    while si < count:
        let start = scope_tracking.ctx_scope_start(ctx, si)
        let n = scope_tracking.ctx_scope_count(ctx, si)
        var i: ptr_uint = 0
        while i < n:
            let bd = scope_tracking.ctx_entry(ctx, start, i)
            if bd.name.equal(name):
                return true
            i += 1
        si += 1
    return false


## The release rules' body entry (the host's `emit_owning_release_warnings`):
## the struct-owning analysis (`ownership_cfg_warnings` over F1's graph when
## the analysis is present, the simple AST fallback when it is not — the host's
## `cfg_available`), then the `own[T]` leaks, then the sequential double
## releases.
function ownership_walk_body(
    body: ptr[ast.Stmt]?,
    path: str,
    warnings: ref[vec.Vec[Warning]],
    owning_type_names: span[str],
    graph: ref[flow_graph.CfgGraph]
) -> void:
    let bp = body else:
        return
    if lint_analysis != null:
        ownership_cfg_warnings(bp, path, warnings, owning_type_names, graph)
    else:
        unsafe:
            match read(bp):
                ast.Stmt.stmt_block as blk:
                    ownership_walk_stmts(blk.statements, path, warnings, owning_type_names)
                _:
                    pass
    # The host's tail, in its order: the struct-owning warnings above, then
    # the own[T] leaks, then the sequential double releases.
    ownership_own_leaks(bp, path, warnings)
    ownership_double_warnings(bp, path, warnings)

# =============================================================================
#  The host's CFG release analysis (`release_rules.rb`'s
#  `emit_owning_release_cfg_warnings`): the struct-owning leak and
#  double-release checks over F1's graph.
# =============================================================================

## The host's `emit_owning_release_cfg_warnings`: per struct-owning local, in
## declaration order — a leak when some path from the declaration reaches an
## exit without a consumer, then a double release when a release node is
## reachable from another release before any reassignment.
function ownership_cfg_warnings(
    body: ptr[ast.Stmt],
    path: str,
    warnings: ref[vec.Vec[Warning]],
    owning_type_names: span[str],
    graph: ref[flow_graph.CfgGraph]
) -> void:
    var locals = vec.Vec[OwnBinding].create()
    defer: locals.release()
    var index = map_mod.Map[str, ptr_uint].create()
    defer: index.release()
    ownership_collect_owning_locals(body, ref_of(locals), ref_of(index), owning_type_names)
    if locals.len() == 0:
        return
    var reachable = ownership_reachable_ids(graph)
    defer: reachable.release()
    var i: ptr_uint = 0
    while i < locals.len():
        let lp = locals.get(i) else:
            break
        unsafe:
            let lb = read(lp)
            let decl_id = ownership_find_decl_node(graph, lb.name)
            if decl_id != 0 and ownership_ids_contain(ref_of(reachable), decl_id):
                ownership_cfg_warn_one(graph, ref_of(reachable), decl_id, lb, path, warnings)
        i += 1


## The per-local half of `emit_owning_release_cfg_warnings`: the leak, then the
## first reachable double release.
function ownership_cfg_warn_one(
    graph: ref[flow_graph.CfgGraph],
    reachable: ref[vec.Vec[ptr_uint]],
    decl_id: ptr_uint,
    lb: OwnBinding,
    path: str,
    warnings: ref[vec.Vec[Warning]]
) -> void:
    var releases = vec.Vec[ptr_uint].create()
    defer: releases.release()
    var consumers = vec.Vec[ptr_uint].create()
    defer: consumers.release()
    var reassigns = vec.Vec[ptr_uint].create()
    defer: reassigns.release()
    ownership_classify_nodes(graph, reachable, lb.name, ref_of(releases), ref_of(consumers), ref_of(reassigns))
    if not ownership_every_path_has_consumer(graph, decl_id, ref_of(consumers), reachable):
        var buf = string.String.create()
        buf.append("owning binding '")
        buf.append(lb.name)
        buf.append("' of type '")
        buf.append(lb.type_name)
        buf.append("' is never released")
        push_warning_at(warnings, path, lb.line, lb.column, lb.name.len, "owning-release-leak", buf.as_str(), "warning")
    var ri: ptr_uint = 0
    while ri < releases.len():
        let rip = releases.get(ri) else:
            break
        let rel_id = unsafe: read(rip)
        let hit = ownership_find_reachable_release(graph, rel_id, ref_of(releases), ref_of(reassigns), reachable)
        if hit != 0:
            let node = flow_graph.graph_node(graph, hit) else:
                break
            var dbuf = string.String.create()
            dbuf.append("owning binding '")
            dbuf.append(lb.name)
            dbuf.append("' may be released more than once")
            push_warning(warnings, path, unsafe: read(node).line, "owning-release-double", dbuf.as_str(), "warning")
            break
        ri += 1


## The host's `owning_local_bindings`: the struct-owning locals in declaration
## order.  A re-declaration updates the entry in place at its first position,
## as Ruby's hash update does.
function ownership_collect_owning_locals(
    body: ptr[ast.Stmt]?,
    sink: ref[vec.Vec[OwnBinding]],
    index: ref[map_mod.Map[str, ptr_uint]],
    owning_type_names: span[str]
) -> void:
    let bp = body else:
        return
    unsafe:
        match read(bp):
            ast.Stmt.stmt_block as blk:
                var si: ptr_uint = 0
                while si < blk.statements.len:
                    ownership_collect_owning_locals_stmt(blk.statements.data + si, sink, index, owning_type_names)
                    si += 1
            _:
                ownership_collect_owning_locals_stmt(bp, sink, index, owning_type_names)


function ownership_collect_owning_locals_stmt(
    stmt: ptr[ast.Stmt],
    sink: ref[vec.Vec[OwnBinding]],
    index: ref[map_mod.Map[str, ptr_uint]],
    owning_type_names: span[str]
) -> void:
    unsafe:
        match read(stmt):
            ast.Stmt.stmt_local as loc:
                if loc.name.len > 0:
                    match ownership_resolve_owning_type(loc.stmt_type, loc.value, owning_type_names):
                        Option.some as type_name:
                            ownership_note_owning_local(sink, index, loc.name, loc.line, loc.column, type_name.value)
                        Option.none:
                            pass
            ast.Stmt.stmt_if as iff:
                var bi: ptr_uint = 0
                while bi < iff.branches.len:
                    ownership_collect_owning_locals(read(iff.branches.data + bi).body, sink, index, owning_type_names)
                    bi += 1
                ownership_collect_owning_locals(iff.else_body, sink, index, owning_type_names)
            ast.Stmt.stmt_while as wh:
                ownership_collect_owning_locals(wh.body, sink, index, owning_type_names)
            ast.Stmt.stmt_for as fr:
                ownership_collect_owning_locals(fr.body, sink, index, owning_type_names)
            ast.Stmt.stmt_match as mt:
                var ai: ptr_uint = 0
                while ai < mt.arms.len:
                    ownership_collect_owning_locals(read(mt.arms.data + ai).body, sink, index, owning_type_names)
                    ai += 1
            ast.Stmt.stmt_unsafe as un:
                ownership_collect_owning_locals(un.body, sink, index, owning_type_names)
            ast.Stmt.stmt_defer as df:
                ownership_collect_owning_locals(df.body, sink, index, owning_type_names)
            _:
                pass


function ownership_note_owning_local(
    sink: ref[vec.Vec[OwnBinding]],
    index: ref[map_mod.Map[str, ptr_uint]],
    name: str,
    line: ptr_uint,
    column: ptr_uint,
    type_name: str
) -> void:
    let existing = index.get(name)
    if existing != null:
        let slot = unsafe: read(existing)
        let item = sink.get(slot) else:
            return
        unsafe:
            read(item).line = line
            read(item).column = column
            read(item).type_name = type_name
        return
    index.set(name, sink.len())
    sink.push(OwnBinding(name = name, line = line, column = column, type_name = type_name))


## The host's `resolve_local_owning_type`: the annotation's base name when it
## names an owning type, else the initializer's created type.
function ownership_resolve_owning_type(
    stmt_type: ptr[ast.TypeRef]?,
    value: ptr[ast.Expr]?,
    owning_type_names: span[str]
) -> Option[str]:
    let tp = stmt_type else:
        return ownership_initializer_owning_type(value, owning_type_names)
    let base = owning_annotation_type_name(tp)
    if is_owning_type_name(base, owning_type_names):
        return Option[str].some(value = base)
    return ownership_initializer_owning_type(value, owning_type_names)


function ownership_initializer_owning_type(value: ptr[ast.Expr]?, owning_type_names: span[str]) -> Option[str]:
    let vp = value else:
        return Option[str].none
    match ownership_initializer_type(vp):
        Option.some as name:
            if is_owning_type_name(name.value, owning_type_names):
                return Option[str].some(value = name.value)
        Option.none:
            pass
    return Option[str].none


## The host's `extract_initializer_type`: a zero-argument `create` /
## `with_capacity` / `empty` / `from_str` call whose receiver names the type.
function ownership_initializer_type(value: ptr[ast.Expr]) -> Option[str]:
    unsafe:
        match read(value):
            ast.Expr.expr_call as call:
                if call.args.len > 0:
                    return Option[str].none
                var method_name = ""
                var receiver: ptr[ast.Expr]? = null
                match read(call.callee):
                    ast.Expr.expr_member_access as ma:
                        method_name = ma.member_name
                        receiver = ma.receiver
                    ast.Expr.expr_specialization as sp:
                        match read(sp.callee):
                            ast.Expr.expr_member_access as sma:
                                method_name = sma.member_name
                            _:
                                pass
                        receiver = call.callee
                    _:
                        pass
                if not is_create_method_name(method_name):
                    return Option[str].none
                let recv = receiver else:
                    return Option[str].none
                let name = owning_type_from_receiver(recv)
                if name.len == 0:
                    return Option[str].none
                return Option[str].some(value = name)
            _:
                return Option[str].none


## The host's `owning_type_from_receiver` (for a specialization the host
## recurses into the specialization's callee).
function owning_type_from_receiver(receiver: ptr[ast.Expr]) -> str:
    unsafe:
        match read(receiver):
            ast.Expr.expr_identifier as id:
                return owning_base_name(id.name)
            ast.Expr.expr_member_access as ma:
                return owning_base_name(ma.member_name)
            ast.Expr.expr_specialization as sp:
                return owning_type_from_receiver(sp.callee)
            _:
                return ""


## The host's `owning_base_name`: the segment after the last dot.
function owning_base_name(qname: str) -> str:
    var start: ptr_uint = 0
    var i: ptr_uint = 0
    while i < qname.len:
        if qname.byte_at(i) == '.':
            start = i + 1
        i += 1
    if start == 0:
        return qname
    return qname.slice(start, qname.len - start)


## The reachability solver's result: every node reachable from the entry over
## successor edges (`ControlFlow::Reachability.solve`).
function ownership_reachable_ids(graph: ref[flow_graph.CfgGraph]) -> vec.Vec[ptr_uint]:
    var ids = vec.Vec[ptr_uint].create()
    var queue = vec.Vec[ptr_uint].create()
    defer: queue.release()
    queue.push(unsafe: read(graph).entry_id)
    var cursor: ptr_uint = 0
    while cursor < queue.len():
        let idp = queue.get(cursor) else:
            break
        let id = unsafe: read(idp)
        cursor += 1
        if ownership_ids_contain(ref_of(ids), id):
            continue
        ids.push(id)
        let node = flow_graph.graph_node(graph, id) else:
            continue
        let succs = unsafe: read(node).succs
        var si: ptr_uint = 0
        while si < succs.len():
            let sp = succs.get(si) else:
                break
            queue.push(unsafe: read(sp))
            si += 1
    return ids


## The host's `find_decl_node_id`: the `local_decl` node whose declaration
## write names the binding (0 = none).  The host's `statement_flow_analysis`
## builder writes a declaration only when the local has an initializer
## (`local_decl_write_targets`), so an uninitialized `var x: T` has no decl
## node here even though the self's shared builder records the write.
function ownership_find_decl_node(graph: ref[flow_graph.CfgGraph], name: str) -> ptr_uint:
    var i: ptr_uint = 0
    let count = unsafe: read(graph).nodes.len()
    while i < count:
        let slot = unsafe: read(graph).nodes.get(i) else:
            break
        let node = unsafe: read(slot)
        if unsafe: read(node).kind.equal("local_decl") and ownership_decl_has_initializer(unsafe: read(node).statement):
            let writes = unsafe: read(node).write_sites
            var wi: ptr_uint = 0
            while wi < writes.len():
                let wp = writes.get(wi) else:
                    break
                unsafe:
                    let w = read(wp)
                    if w.origin.equal("declaration") and w.name.equal(name):
                        return read(node).id
                wi += 1
        i += 1
    return 0


function ownership_decl_has_initializer(stmt_key: ptr_uint) -> bool:
    let stmt = unsafe: reinterpret[ptr[ast.Stmt]](stmt_key)
    unsafe:
        match read(stmt):
            ast.Stmt.stmt_local as loc:
                return loc.value != null
            _:
                return false


## The host's `classify_cfg_nodes`: the reachable nodes that release the
## binding (consumers; the non-defer ones also count as releases), the nodes
## that consume it by transfer (a by-name return or a struct-field transfer)
## and the nodes that reassign it.
function ownership_classify_nodes(
    graph: ref[flow_graph.CfgGraph],
    reachable: ref[vec.Vec[ptr_uint]],
    name: str,
    releases: ref[vec.Vec[ptr_uint]],
    consumers: ref[vec.Vec[ptr_uint]],
    reassigns: ref[vec.Vec[ptr_uint]]
) -> void:
    var i: ptr_uint = 0
    let count = unsafe: read(graph).nodes.len()
    while i < count:
        let slot = unsafe: read(graph).nodes.get(i) else:
            break
        let node = unsafe: read(slot)
        let id = unsafe: read(node).id
        unsafe:
            if ownership_ids_contain(reachable, id):
                let kind = read(node).kind
                let stmt_key = read(node).statement
                if stmt_key != 0 and ownership_statement_node_kind(kind):
                    let stmt = reinterpret[ptr[ast.Stmt]](stmt_key)
                    if ownership_release_call_in_stmt(stmt, name):
                        consumers.push(id)
                        if not kind.equal("defer"):
                            releases.push(id)
                    if ownership_return_for_name(stmt, name) or ownership_struct_transfer_in_stmt(stmt, name):
                        consumers.push(id)
                if kind.equal("assignment"):
                    let writes = read(node).write_sites
                    var wi: ptr_uint = 0
                    while wi < writes.len():
                        let wp = writes.get(wi) else:
                            break
                        let w = read(wp)
                        if w.origin.equal("assignment") and w.name.equal(name):
                            reassigns.push(id)
                        wi += 1
        i += 1


## Whether a node's `statement` field is an AST statement the release
## predicates can read.  The builder stores a branch/arm in `if_condition` and
## `match_binding` nodes, exactly as the host's builder does (whose predicates
## then simply do not match).
function ownership_statement_node_kind(kind: str) -> bool:
    return not kind.equal("if_condition") and not kind.equal("match_binding")


## The host's `release_call_in_stmt?`: a release of the binding inside the
## statement, including a defer body's statements.
function ownership_release_call_in_stmt(stmt: ptr[ast.Stmt], name: str) -> bool:
    unsafe:
        match read(stmt):
            ast.Stmt.stmt_defer as df:
                let body = df.body else:
                    return false
                match read(body):
                    ast.Stmt.stmt_block as blk:
                        var si: ptr_uint = 0
                        while si < blk.statements.len:
                            if ownership_release_call_in_stmt(blk.statements.data + si, name):
                                return true
                            si += 1
                        return false
                    _:
                        return ownership_release_call_in_stmt(body, name)
            _:
                match ownership_extract_expr(stmt):
                    Option.some as ep:
                        return ownership_expr_has_release(ep.value, name)
                    Option.none:
                        return false


## The host's `_expr_has_release?`: an `x.release()` on the binding, a
## `release_*` helper taking it through `ref_of`/`ptr_of`, or anything nested.
function ownership_expr_has_release(expr: ptr[ast.Expr], name: str) -> bool:
    unsafe:
        match read(expr):
            ast.Expr.expr_call as call:
                if release_call_on_binding(expr):
                    match read(call.callee):
                        ast.Expr.expr_member_access as ma:
                            match read(ma.receiver):
                                ast.Expr.expr_identifier as id:
                                    if id.name.equal(name):
                                        return true
                                _:
                                    pass
                        _:
                            pass
                else:
                    match read(call.callee):
                        ast.Expr.expr_identifier as cid:
                            if cid.name.starts_with("release_") and ownership_release_helper_has(call.args, name):
                                return true
                        _:
                            pass
                if ownership_expr_has_release(call.callee, name):
                    return true
                var ai: ptr_uint = 0
                while ai < call.args.len:
                    if ownership_expr_has_release(read(call.args.data + ai).arg_value, name):
                        return true
                    ai += 1
                return false
            ast.Expr.expr_member_access as m:
                return ownership_expr_has_release(m.receiver, name)
            ast.Expr.expr_binary_op as b:
                return ownership_expr_has_release(b.left, name) or ownership_expr_has_release(b.right, name)
            ast.Expr.expr_unary_op as u:
                return ownership_expr_has_release(u.operand, name)
            _:
                return false


## The host's `release_helper_binding_names`: a `release_*` helper's
## `ref_of(binding)` / `ptr_of(binding)` arguments name released bindings.
function ownership_release_helper_has(args: span[ast.Argument], name: str) -> bool:
    var ai: ptr_uint = 0
    while ai < args.len:
        let arg = unsafe: read(args.data + ai)
        unsafe:
            match read(arg.arg_value):
                ast.Expr.expr_call as vc:
                    match read(vc.callee):
                        ast.Expr.expr_identifier as cid:
                            if cid.name.equal("ref_of") or cid.name.equal("ptr_of"):
                                var ii: ptr_uint = 0
                                while ii < vc.args.len:
                                    match read(read(vc.args.data + ii).arg_value):
                                        ast.Expr.expr_identifier as inner:
                                            if inner.name.equal(name):
                                                return true
                                        _:
                                            pass
                                    ii += 1
                        _:
                            pass
                _:
                    pass
        ai += 1
    return false


## The host's `return_for_name?`.
function ownership_return_for_name(stmt: ptr[ast.Stmt], name: str) -> bool:
    unsafe:
        match read(stmt):
            ast.Stmt.stmt_ret as r:
                let value = r.value else:
                    return false
                match read(value):
                    ast.Expr.expr_identifier as id:
                        return id.name.equal(name)
                    _:
                        return false
            _:
                return false


## The host's `struct_transfer_in_stmt?`: a call statement that hands the
## binding to a named argument (through casts or nested calls).
function ownership_struct_transfer_in_stmt(stmt: ptr[ast.Stmt], name: str) -> bool:
    match ownership_extract_expr(stmt):
        Option.some as ep:
            return ownership_expr_contains_transfer(ep.value, name)
        Option.none:
            return false


## The host's `_expr_contains_transfer?`.
function ownership_expr_contains_transfer(expr: ptr[ast.Expr], name: str) -> bool:
    unsafe:
        match read(expr):
            ast.Expr.expr_call as call:
                var ai: ptr_uint = 0
                while ai < call.args.len:
                    let arg = read(call.args.data + ai)
                    if ownership_argument_transfers(arg.arg_value, name, arg.arg_name.is_some()):
                        return true
                    ai += 1
                return false
            _:
                return false


## The host's `argument_transfers?`: a named identifier transfers ownership; a
## pointer cast around one transfers regardless of the argument's name, and a
## nested call's named arguments are walked.
function ownership_argument_transfers(value: ptr[ast.Expr], name: str, named: bool) -> bool:
    unsafe:
        match read(value):
            ast.Expr.expr_identifier as id:
                return named and id.name.equal(name)
            ast.Expr.expr_prefix_cast as pc:
                match read(pc.expression):
                    ast.Expr.expr_identifier as inner:
                        return inner.name.equal(name)
                    _:
                        return false
            ast.Expr.expr_call as call:
                var ai: ptr_uint = 0
                while ai < call.args.len:
                    let arg = read(call.args.data + ai)
                    if ownership_argument_transfers(arg.arg_value, name, arg.arg_name.is_some()):
                        return true
                    ai += 1
                return false
            _:
                return false


## The host's `every_path_to_exit_has_consumer?`: walk from the declaration;
## a consumer ends the path, an exit node before any consumer is a leak.  An
## exhausted walk (no exit nodes reachable) is not a leak.
function ownership_every_path_has_consumer(
    graph: ref[flow_graph.CfgGraph],
    decl_id: ptr_uint,
    consumers: ref[vec.Vec[ptr_uint]],
    reachable: ref[vec.Vec[ptr_uint]]
) -> bool:
    var visited = vec.Vec[ptr_uint].create()
    defer: visited.release()
    var queue = vec.Vec[ptr_uint].create()
    defer: queue.release()
    let decl = flow_graph.graph_node(graph, decl_id) else:
        return true
    let succs = unsafe: read(decl).succs
    var si: ptr_uint = 0
    while si < succs.len():
        let sp = succs.get(si) else:
            break
        queue.push(unsafe: read(sp))
        si += 1
    var cursor: ptr_uint = 0
    while cursor < queue.len():
        let idp = queue.get(cursor) else:
            break
        let nid = unsafe: read(idp)
        cursor += 1
        if ownership_ids_contain(ref_of(visited), nid):
            continue
        visited.push(nid)
        if not ownership_ids_contain(reachable, nid):
            continue
        let node = flow_graph.graph_node(graph, nid) else:
            continue
        if ownership_ids_contain(consumers, nid):
            continue
        let kind = unsafe: read(node).kind
        if kind.equal("exit") or kind.equal("return"):
            return false
        let nexts = unsafe: read(node).succs
        var ni: ptr_uint = 0
        while ni < nexts.len():
            let np = nexts.get(ni) else:
                break
            queue.push(unsafe: read(np))
            ni += 1
    return true


## The host's `find_reachable_release`: the first release node reachable from
## another release for the same binding without passing a reassignment.
function ownership_find_reachable_release(
    graph: ref[flow_graph.CfgGraph],
    start_id: ptr_uint,
    releases: ref[vec.Vec[ptr_uint]],
    reassigns: ref[vec.Vec[ptr_uint]],
    reachable: ref[vec.Vec[ptr_uint]]
) -> ptr_uint:
    var visited = vec.Vec[ptr_uint].create()
    defer: visited.release()
    var queue = vec.Vec[ptr_uint].create()
    defer: queue.release()
    let start = flow_graph.graph_node(graph, start_id) else:
        return 0
    let succs = unsafe: read(start).succs
    var si: ptr_uint = 0
    while si < succs.len():
        let sp = succs.get(si) else:
            break
        queue.push(unsafe: read(sp))
        si += 1
    var cursor: ptr_uint = 0
    while cursor < queue.len():
        let idp = queue.get(cursor) else:
            break
        let nid = unsafe: read(idp)
        cursor += 1
        if ownership_ids_contain(ref_of(visited), nid):
            continue
        visited.push(nid)
        if not ownership_ids_contain(reachable, nid):
            continue
        if ownership_ids_contain(releases, nid) and nid != start_id:
            return nid
        if ownership_ids_contain(reassigns, nid):
            continue
        let node = flow_graph.graph_node(graph, nid) else:
            continue
        let nexts = unsafe: read(node).succs
        var ni: ptr_uint = 0
        while ni < nexts.len():
            let np = nexts.get(ni) else:
                break
            queue.push(unsafe: read(np))
            ni += 1
    return 0


function ownership_ids_contain(ids: ref[vec.Vec[ptr_uint]], id: ptr_uint) -> bool:
    var i: ptr_uint = 0
    while i < ids.len():
        let ip = ids.get(i) else:
            break
        if unsafe: read(ip) == id:
            return true
        i += 1
    return false


function ownership_walk_stmts(
    stmts: span[ast.Stmt],
    path: str,
    warnings: ref[vec.Vec[Warning]],
    owning_type_names: span[str]
) -> void:
    var created = vec.Vec[str].create()
    defer: created.release()
    var released = vec.Vec[str].create()
    defer: released.release()
    var transferred = vec.Vec[str].create()
    defer: transferred.release()
    var created_info = map_mod.Map[str, OwningBinding].create()
    defer: created_info.release()

    # Collect from statements.
    var si: ptr_uint = 0
    while si < stmts.len:
        unsafe:
            ownership_collect_stmt(
                stmts.data + si,
                ref_of(created),
                ref_of(created_info),
                ref_of(released),
                ref_of(transferred),
                path,
                warnings,
                owning_type_names
            )
        si += 1

    # Recurse into nested scopes.
    si = 0
    while si < stmts.len:
        unsafe:
            ownership_recurse_stmt(stmts.data + si, path, warnings)
        si += 1

    # Report leaks: created but never released and never transferred.  Anchor
    # the warning on the binding's declaration line and name its type, as the
    # host's release rules do.
    si = 0
    while si < created.len():
        let namep = created.get(si) else:
            break
        let name = unsafe: read(namep)
        if not ownership_contains(ref_of(released), name) and not ownership_contains(ref_of(transferred), name):
            var line: ptr_uint = 1
            var type_name: str = ""
            let info_ptr = created_info.get(name)
            if info_ptr != null:
                unsafe:
                    let info = read(info_ptr)
                    line = info.line
                    type_name = info.type_name
            var buf = string.String.create()
            buf.append("owning binding '")
            buf.append(name)
            buf.append("' of type '")
            buf.append(type_name)
            buf.append("' is never released")
            push_warning(warnings, path, line, "owning-release-leak", buf.as_str(), "warning")
        si += 1


function ownership_contains(vec_ref: ref[vec.Vec[str]], name: str) -> bool:
    var i: ptr_uint = 0
    while i < vec_ref.len():
        let ep = vec_ref.get(i) else:
            break
        if unsafe: read(ep).equal(name):
            return true
        i += 1
    return false


function ownership_collect_stmt(
    stmt: ptr[ast.Stmt],
    created: ref[vec.Vec[str]],
    created_info: ref[map_mod.Map[str, OwningBinding]],
    released: ref[vec.Vec[str]],
    transferred: ref[vec.Vec[str]],
    path: str,
    warnings: ref[vec.Vec[Warning]],
    owning_type_names: span[str]
) -> void:
    unsafe:
        match read(stmt):
            ast.Stmt.stmt_local as loc:
                if loc.value != null:
                    if own_creating_call(loc.value):
                        let created_type = own_created_type_name(loc.value, loc.stmt_type)
                        if is_owning_type_name(created_type, owning_type_names):
                            created.push(loc.name)
                            created_info.set(loc.name, OwningBinding(line = loc.line, type_name = created_type))
                    else if ownership_transfer_ctor(loc.value, loc.name):
                        transferred.push(loc.name)
                # Also detect owning bindings from type annotations (e.g. `var m: Map[str, str]`).
                if not ownership_contains(created, loc.name):
                    let vt = loc.stmt_type
                    if vt != null and is_owning_type_annotation(unsafe: read(vt), owning_type_names):
                        created.push(loc.name)
                        created_info.set(
                            loc.name,
                            OwningBinding(line = loc.line, type_name = own_created_type_name(null, loc.stmt_type))
                        )
                ownership_collect_expr_opt(loc.value, released, transferred, path, warnings)
                ownership_collect_body_opt(loc.else_body, path, warnings)
            ast.Stmt.stmt_expression as ex:
                ownership_collect_expr(ex.expression, released, transferred, path, warnings)
            ast.Stmt.stmt_assignment as asgn:
                # If assigned from a create call of an owning type, mark the
                # target as created.
                if own_creating_call(asgn.value):
                    if is_owning_type_name(own_created_type_name(asgn.value, null), owning_type_names):
                        match read(asgn.target):
                            ast.Expr.expr_identifier as id:
                                created.push(id.name)
                            _:
                                pass
                ownership_collect_expr(asgn.value, released, transferred, path, warnings)
                ownership_collect_expr(asgn.target, released, transferred, path, warnings)
                # Check for transferred ownership (e.g., passing to struct constructor).
                ownership_collect_transfer_in_args(asgn.value, asgn.target, transferred)
            ast.Stmt.stmt_ret as r:
                ownership_collect_expr_opt(r.value, released, transferred, path, warnings)
                ownership_collect_ret_transfer(r.value, transferred)
            _:
                pass


function ownership_collect_body(body: ptr[ast.Stmt]?, path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    let bp = body else:
        return
    unsafe:
        match read(bp):
            ast.Stmt.stmt_block as blk:
                ownership_walk_stmts(blk.statements, path, warnings, span[str]())
            _:
                var created = vec.Vec[str].create()
                defer: created.release()
                var released = vec.Vec[str].create()
                defer: released.release()
                var released_lines = map_mod.Map[str, ptr_uint].create()
                defer: released_lines.release()
                var transferred = vec.Vec[str].create()
                defer: transferred.release()
                var created_info = map_mod.Map[str, OwningBinding].create()
                defer: created_info.release()
                ownership_collect_stmt(
                    bp,
                    ref_of(created),
                    ref_of(created_info),
                    ref_of(released),
                    ref_of(transferred),
                    path,
                    warnings,
                    span[str]()
                )


function ownership_collect_body_opt(body: ptr[ast.Stmt]?, path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    let bp = body else:
        return
    ownership_collect_body(bp, path, warnings)


function ownership_collect_expr(
    expr: ptr[ast.Expr],
    released: ref[vec.Vec[str]],
    transferred: ref[vec.Vec[str]],
    path: str,
    warnings: ref[vec.Vec[Warning]]
) -> void:
    unsafe:
        match read(expr):
            ast.Expr.expr_call as call:
                # A `x.release()` marks x as released for the struct-leak half
                # (the host's `_collect_released_names_in_expr`).
                if release_call_on_binding(expr):
                    match read(call.callee):
                        ast.Expr.expr_member_access as ma:
                            match read(ma.receiver):
                                ast.Expr.expr_identifier as id:
                                    if not ownership_contains(released, id.name):
                                        released.push(id.name)
                                _:
                                    pass
                        _:
                            pass
                ownership_collect_expr(call.callee, released, transferred, path, warnings)
                var ai: ptr_uint = 0
                while ai < call.args.len:
                    ownership_collect_expr(read(call.args.data + ai).arg_value, released, transferred, path, warnings)
                    ai += 1
            ast.Expr.expr_member_access as m:
                ownership_collect_expr(m.receiver, released, transferred, path, warnings)
            ast.Expr.expr_binary_op as b:
                ownership_collect_expr(b.left, released, transferred, path, warnings)
                ownership_collect_expr(b.right, released, transferred, path, warnings)
            ast.Expr.expr_unary_op as u:
                ownership_collect_expr(u.operand, released, transferred, path, warnings)
            ast.Expr.expr_index_access as ix:
                ownership_collect_expr(ix.receiver, released, transferred, path, warnings)
                ownership_collect_expr(ix.index, released, transferred, path, warnings)
            ast.Expr.expr_if as iff:
                ownership_collect_expr(iff.condition, released, transferred, path, warnings)
                ownership_collect_expr(iff.then_expr, released, transferred, path, warnings)
                ownership_collect_expr(iff.else_expr, released, transferred, path, warnings)
            ast.Expr.expr_match as mm:
                ownership_collect_expr(mm.scrutinee, released, transferred, path, warnings)
                var mi: ptr_uint = 0
                while mi < mm.arms.len:
                    ownership_collect_expr(read(mm.arms.data + mi).value, released, transferred, path, warnings)
                    mi += 1
            ast.Expr.expr_prefix_cast as pc:
                ownership_collect_expr(pc.expression, released, transferred, path, warnings)
            ast.Expr.expr_unsafe as us:
                ownership_collect_expr(us.expression, released, transferred, path, warnings)
            ast.Expr.expr_await as aw:
                ownership_collect_expr(aw.expression, released, transferred, path, warnings)
            ast.Expr.expr_detach as dt:
                ownership_collect_expr(dt.expression, released, transferred, path, warnings)
            ast.Expr.expr_expression_list as el:
                var ei: ptr_uint = 0
                while ei < el.elements.len:
                    ownership_collect_expr(el.elements.data + ei, released, transferred, path, warnings)
                    ei += 1
            _:
                pass


function ownership_collect_expr_opt(
    expr: ptr[ast.Expr]?,
    released: ref[vec.Vec[str]],
    transferred: ref[vec.Vec[str]],
    path: str,
    warnings: ref[vec.Vec[Warning]]
) -> void:
    let ep = expr else:
        return
    ownership_collect_expr(ep, released, transferred, path, warnings)


function ownership_recurse_stmt(stmt: ptr[ast.Stmt], path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    unsafe:
        match read(stmt):
            ast.Stmt.stmt_if as iff:
                var bi: ptr_uint = 0
                while bi < iff.branches.len:
                    ownership_collect_body(read(iff.branches.data + bi).body, path, warnings)
                    bi += 1
                ownership_collect_body_opt(iff.else_body, path, warnings)
            ast.Stmt.stmt_match as mt:
                var ai: ptr_uint = 0
                while ai < mt.arms.len:
                    ownership_collect_body(read(mt.arms.data + ai).body, path, warnings)
                    ai += 1
            ast.Stmt.stmt_while as wh:
                ownership_collect_body_opt(wh.body, path, warnings)
            ast.Stmt.stmt_for as fr:
                ownership_collect_body_opt(fr.body, path, warnings)
            ast.Stmt.stmt_unsafe as un:
                ownership_collect_body_opt(un.body, path, warnings)
            ast.Stmt.stmt_defer as df:
                ownership_collect_body_opt(df.body, path, warnings)
            ast.Stmt.stmt_block as blk:
                ownership_walk_stmts(blk.statements, path, warnings, span[str]())
            ast.Stmt.stmt_when as wn:
                var wi: ptr_uint = 0
                while wi < wn.branches.len:
                    let wbr = read(wn.branches.data + wi)
                    var wsi: ptr_uint = 0
                    while wsi < wbr.body.len:
                        ownership_recurse_stmt(wbr.body.data + wsi, path, warnings)
                        wsi += 1
                    wi += 1
                ownership_collect_body_opt(wn.else_body, path, warnings)
            _:
                pass


## True when `expr` is an ownership-creating call (heap.must_alloc, Vec.create, etc.).
function own_creating_call(expr: ptr[ast.Expr]?) -> bool:
    let ep = expr else:
        return false
    unsafe:
        match read(ep):
            ast.Expr.expr_call as call:
                match read(call.callee):
                    ast.Expr.expr_member_access as ma:
                        if is_create_method_name(ma.member_name):
                            return true
                        return false
                    ast.Expr.expr_specialization as sp:
                        match read(sp.callee):
                            ast.Expr.expr_member_access as ma2:
                                if is_alloc_method_name(ma2.member_name):
                                    return true
                            _:
                                pass
                        return false
                    _:
                        return false
            _:
                return false


function is_create_method_name(name: str) -> bool:
    return name.equal("create") or name.equal("with_capacity") or name.equal("from_str") or name.equal("empty")


## True when a type annotation names an owning type (a type with a `.release()`
## method).  Walks the type-ref's top-level name, extracting the base type name
## (e.g. `Map` from `Map[str, str]`).
## True when `type_name` names a type that owns resources (it has a `release`
## method).  A `create` call on any other type (`Node.create(...)`) is not an
## owning creation and must not report a leak.
function is_owning_type_name(type_name: str, owning_type_names: span[str]) -> bool:
    if type_name.len == 0:
        return false
    var i: ptr_uint = 0
    while i < owning_type_names.len:
        unsafe:
            if read(owning_type_names.data + i).equal(type_name):
                return true
        i += 1
    return false


function is_owning_type_annotation(type_ref: ast.TypeRef, owning_type_names: span[str]) -> bool:
    var base_name: str
    unsafe:
        if type_ref.name.parts.len > 0:
            base_name = read(type_ref.name.parts.data + type_ref.name.parts.len - 1)
        else:
            return false
    var i: ptr_uint = 0
    while i < owning_type_names.len:
        unsafe:
            if read(owning_type_names.data + i).equal(base_name):
                return true
        i += 1
    return false


function is_alloc_method_name(name: str) -> bool:
    return name.equal("must_alloc") or name.equal("alloc") or name.equal("must_alloc_zeroed") or name.equal("must_resize") or name.equal("resize")


## True when `expr` is a `.release()` or `.release_and_null()` call.
## Record transfers: when `target` is an identifier (struct field assignment or
## similar), and `value` contains an owning name, that name is transferred.
function ownership_collect_transfer_in_args(
    value: ptr[ast.Expr],
    target: ptr[ast.Expr],
    transferred: ref[vec.Vec[str]]
) -> void:
    unsafe:
        match read(value):
            ast.Expr.expr_identifier as id:
                # Check if target is accessing a struct field (transfer ownership).
                match read(target):
                    ast.Expr.expr_member_access:
                        if not ownership_contains(transferred, id.name):
                            transferred.push(id.name)
                    _:
                        pass
            _:
                pass


## Record return transfers: a returned identifier transfers ownership.
function ownership_collect_ret_transfer(value: ptr[ast.Expr]?, transferred: ref[vec.Vec[str]]) -> void:
    let vp = value else:
        return
    unsafe:
        match read(vp):
            ast.Expr.expr_identifier as id:
                if not ownership_contains(transferred, id.name):
                    transferred.push(id.name)
            _:
                pass


## True when `expr` is a struct constructor call that takes an owning value
## (transfers ownership). For AST-only, we just record names passed to any call.
function ownership_transfer_ctor(expr: ptr[ast.Expr]?, target_name: str) -> bool:
    return false

# =============================================================================
#  reserved-primitive-name — warn when a binding shadows a built-in type name.
# =============================================================================

## The host's `Types::RESERVED_VALUE_TYPE_NAMES`: `BUILTIN_PRIMITIVE_NAMES` plus
## `Option`/`Result`.  Container type names (`ptr`, `ref`, `span`, `own`) are
## *not* reserved value names — `let ptr: ptr[int]? = null` is fine.
const RESERVED_VALUE_NAMES: array[str, 28] = array[str, 28](
    "bool", "byte", "short", "int", "long",
    "ubyte", "ushort", "uint", "ulong",
    "char", "float", "double",
    "void", "str", "cstr",
    "ptr_int", "ptr_uint",
    "vec2", "vec3", "vec4",
    "ivec2", "ivec3", "ivec4",
    "mat3", "mat4", "quat",
    "Option", "Result"
)


function is_reserved_type_name(name: str) -> bool:
    var i: ptr_uint = 0
    while i < 28:
        if name.equal(RESERVED_VALUE_NAMES[i]):
            return true
        i += 1
    return false


## The host's `RESERVED_IMPORT_ALIAS_NAMES`: an import alias only collides with
## the prelude type names, never with the primitives.
function is_reserved_import_alias_name(name: str) -> bool:
    return name.equal("Option") or name.equal("Result")


## The host's `seed_module_bindings` warning half plus its rename fixes: a
## module-level declaration (function, constant, module variable, event,
## extern/foreign function) or import alias whose name is a reserved value type
## is reported before the declaration walk, and registers a rename fix whose
## sites are the declaration and every identifier use (the host's
## `@reserved_primitive_name_fixes`).
function lint_reserved_module_names(file: ast.SourceFile, path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    # The host seeds the import aliases first, then the declarations.
    var import_names = map_mod.Map[str, bool].create()
    defer: import_names.release()
    reserved_collect_import_names(file, ref_of(import_names))

    var ii: ptr_uint = 0
    while ii < file.imports.len:
        unsafe:
            match read(file.imports.data + ii):
                ast.Decl.decl_import as imp:
                    let local_name = reserved_import_local_name(imp.path, imp.alias_name)
                    if local_name.len > 0 and not local_name.starts_with("_"):
                        # The host's `RESERVED_IMPORT_ALIAS_NAMES`: only
                        # `Option`/`Result`, not the primitive type names.
                        if is_reserved_import_alias_name(local_name):
                            reserved_register(
                                path,
                                imp.line,
                                imp.column,
                                local_name,
                                "import alias",
                                ref_of(import_names),
                                warnings
                            )
                _:
                    pass
        ii += 1

    var declared_names = map_mod.Map[str, bool].create()
    defer: declared_names.release()
    reserved_collect_declared_names(file, ref_of(declared_names))

    var i: ptr_uint = 0
    while i < file.declarations.len:
        unsafe:
            match read(file.declarations.data + i):
                ast.Decl.decl_function as fun:
                    if is_reserved_type_name(fun.name):
                        reserved_register(
                            path,
                            fun.line,
                            fun.column,
                            fun.name,
                            "function",
                            ref_of(declared_names),
                            warnings
                        )
                ast.Decl.decl_const as c:
                    if is_reserved_type_name(c.name):
                        reserved_register(path, c.line, c.column, c.name, "constant", ref_of(declared_names), warnings)
                ast.Decl.decl_var as v:
                    if is_reserved_type_name(v.name):
                        reserved_register(
                            path,
                            v.line,
                            v.column,
                            v.name,
                            "module variable",
                            ref_of(declared_names),
                            warnings
                        )
                ast.Decl.decl_event as ev:
                    if is_reserved_type_name(ev.name):
                        reserved_register(path, ev.line, ev.column, ev.name, "event", ref_of(declared_names), warnings)
                ast.Decl.decl_extern_function as ef:
                    if is_reserved_type_name(ef.name):
                        reserved_register(
                            path,
                            ef.line,
                            reserved_name_column(ef.line, ef.name),
                            ef.name,
                            "function",
                            ref_of(declared_names),
                            warnings
                        )
                ast.Decl.decl_foreign_function as ff:
                    if is_reserved_type_name(ff.name):
                        reserved_register(
                            path,
                            ff.line,
                            reserved_name_column(ff.line, ff.name),
                            ff.name,
                            "function",
                            ref_of(declared_names),
                            warnings
                        )
                _:
                    pass
        i += 1

## One reserved-name site: the 1-based position of the name and its length.
public struct ReservedNameSite:
    line: ptr_uint
    column: ptr_uint
    length: ptr_uint

## One binding's rename fix: every site that spells its name, and the
## replacement the sites become (the host's `ReservedPrimitiveNameFix`).
public struct ReservedNameFix:
    kind_label: str
    original_name: str
    replacement_base_name: str
    replacement_name: str
    sites: vec.Vec[ReservedNameSite]

## The fixes collected by the lint pass in flight (the host's
## `@reserved_primitive_name_fixes`), the module-level name → fix index
## (1-based; 0 = none), and the out-vector `collect_reserved_primitive_name_fixes`
## hands the fixes to.
var lint_reserved_fixes: ptr[vec.Vec[ReservedNameFix]]? = null
var lint_reserved_module_fix: ptr[map_mod.Map[str, ptr_uint]]? = null
var lint_reserved_out: ptr[vec.Vec[ReservedNameFix]]? = null


## Release the fixes and their site vectors.
public function release_reserved_name_fixes(fixes: ref[vec.Vec[ReservedNameFix]]) -> void:
    var i: ptr_uint = 0
    while i < fixes.len():
        let fp = fixes.get(i) else:
            break
        unsafe:
            var entry = read(fp)
            entry.sites.release()
        i += 1
    fixes.release()


## The host's `suggested_reserved_primitive_name`.
function reserved_suggested_name(name: str, kind_label: str) -> str:
    var buf = string.String.create()
    buf.append(name)
    if kind_label.equal("function"):
        buf.append("_fn")
    else if kind_label.equal("import alias"):
        buf.append("_module")
    else:
        buf.append("_value")
    return buf.as_str()


## The host's `next_available_reserved_primitive_name`: append `_2`, `_3`…
## until the candidate is not among the names in play.
function reserved_next_available(base: str, unavailable: ref[map_mod.Map[str, bool]]) -> str:
    if not unsafe: read(unavailable).contains(base):
        return base
    var suffix: ptr_uint = 2
    while true:
        var buf = string.String.create()
        buf.append(base)
        buf.append("_")
        buf.append_format(f"#{suffix}")
        let candidate = buf.as_str()
        if not unsafe: read(unavailable).contains(candidate):
            return candidate
        buf.release()
        suffix += 1


## The local name an import binds: its alias, else its path's last segment.
function reserved_import_local_name(path: ast.QualifiedName, alias_name: Option[str]) -> str:
    match alias_name:
        Option.some as alias:
            return alias.value
        Option.none:
            pass
    if path.parts.len == 0:
        return ""
    return unsafe: read(path.parts.data + path.parts.len - 1)


## The 1-based column of `name` as a whole word on 1-based line `line`, or 0
## when the line is unavailable or does not spell the name.  Extern and foreign
## declarations carry no column of their own.
function reserved_name_column(line: ptr_uint, name: str) -> ptr_uint:
    let lines = lint_source_lines else:
        return 0
    if line == 0 or line > unsafe: read(lines).len():
        return 0
    let lp = unsafe: read(lines).get(line - 1) else:
        return 0
    let text = unsafe: read(lp)
    if name.len == 0 or name.len > text.len:
        return 0
    var i: ptr_uint = 0
    while i + name.len <= text.len:
        if text.starts_with_at(i, name):
            let before_ok = i == 0 or not is_word_byte(text.byte_at(i - 1))
            let after = i + name.len
            let after_ok = after >= text.len or not is_word_byte(text.byte_at(after))
            if before_ok and after_ok:
                return i + 1
        i += 1
    return 0


## Every module-level declaration name in the file (the host's
## `declared_callable_names`).
function reserved_collect_declared_names(file: ast.SourceFile, names: ref[map_mod.Map[str, bool]]) -> void:
    var i: ptr_uint = 0
    while i < file.declarations.len:
        unsafe:
            match read(file.declarations.data + i):
                ast.Decl.decl_function as fun:
                    names.set(fun.name, true)
                ast.Decl.decl_const as c:
                    names.set(c.name, true)
                ast.Decl.decl_var as v:
                    names.set(v.name, true)
                ast.Decl.decl_event as ev:
                    names.set(ev.name, true)
                ast.Decl.decl_extern_function as ef:
                    names.set(ef.name, true)
                ast.Decl.decl_foreign_function as ff:
                    names.set(ff.name, true)
                _:
                    pass
        i += 1


## Every import's local name.
function reserved_collect_import_names(file: ast.SourceFile, names: ref[map_mod.Map[str, bool]]) -> void:
    var i: ptr_uint = 0
    while i < file.imports.len:
        unsafe:
            match read(file.imports.data + i):
                ast.Decl.decl_import as imp:
                    let name = reserved_import_local_name(imp.path, imp.alias_name)
                    if name.len > 0:
                        names.set(name, true)
                _:
                    pass
        i += 1


## The host's `visible_binding_names`: every module binding and in-scope local
## (their names and the replacements the fixes would rename them to).
function reserved_visible_names(visible: ref[map_mod.Map[str, bool]]) -> void:
    reserved_visible_fix_names(visible)
    reserved_visible_scope_names(visible)


function reserved_visible_fix_names(visible: ref[map_mod.Map[str, bool]]) -> void:
    let fixes_ptr = lint_reserved_fixes else:
        return
    var fi: ptr_uint = 0
    while fi < unsafe: read(fixes_ptr).len():
        let fp = unsafe: read(fixes_ptr).get(fi) else:
            break
        let fix = unsafe: read(fp)
        visible.set(fix.original_name, true)
        visible.set(fix.replacement_name, true)
        fi += 1


function reserved_visible_scope_names(visible: ref[map_mod.Map[str, bool]]) -> void:
    let c = lint_scope_ctx else:
        return
    let ctx = unsafe: ref_of(read(c))
    var si: ptr_uint = 0
    while si < unsafe: read(c).scope_count:
        let start = scope_tracking.ctx_scope_start(ctx, si)
        let count = scope_tracking.ctx_scope_count(ctx, si)
        var ei: ptr_uint = 0
        while ei < count:
            let binding = scope_tracking.ctx_entry(ctx, start, ei)
            if binding.name.len > 0:
                visible.set(binding.name, true)
            ei += 1
        si += 1


## The host's `resolve_reserved_primitive_name_conflicts!`: when a new
## declaration takes the name another fix would rename to, that fix's
## replacement is bumped past the names in play.
function reserved_resolve_conflicts(declared: str) -> void:
    let fixes_ptr = lint_reserved_fixes else:
        return
    var visible = map_mod.Map[str, bool].create()
    defer: visible.release()
    reserved_visible_names(ref_of(visible))

    var i: ptr_uint = 0
    while i < unsafe: read(fixes_ptr).len():
        let fp = unsafe: read(fixes_ptr).get(i) else:
            break
        let fix = unsafe: read(fp)
        if fix.replacement_name.equal(declared):
            let bumped = reserved_next_available(fix.replacement_base_name, ref_of(visible))
            unsafe:
                read(fp).replacement_name = bumped
            visible.set(bumped, true)
        i += 1


## Register a reserved-name warning and — for a binding a rename can reach —
## the fix itself (the host's `register_reserved_primitive_name_fix`).
## Returns 1 + the fix's index, or 0 when no fix was registered.
function reserved_register(
    path: str,
    line: ptr_uint,
    column: ptr_uint,
    name: str,
    kind_label: str,
    unavailable: ref[map_mod.Map[str, bool]],
    warnings: ref[vec.Vec[Warning]],
) -> ptr_uint:
    reserved_name_warn(path, line, column, name, kind_label, warnings)
    if line == 0 or column == 0:
        return 0
    let fixes_ptr = lint_reserved_fixes else:
        return 0
    let base = reserved_suggested_name(name, kind_label)
    let replacement = reserved_next_available(base, unavailable)

    var sites = vec.Vec[ReservedNameSite].create()
    sites.push(ReservedNameSite(line = line, column = column, length = name.len))
    let index = unsafe: read(fixes_ptr).len()
    unsafe:
        read(fixes_ptr).push(ReservedNameFix(
            kind_label = kind_label,
            original_name = name,
            replacement_base_name = base,
            replacement_name = replacement,
            sites = sites,
        ))
    # Module-level bindings answer identifier uses no local shadows.
    if (
        kind_label.equal("function")
        or kind_label.equal("constant")
        or kind_label.equal("module variable")
        or kind_label.equal("event")
        or kind_label.equal("import alias")
    ):
        let module_fix = lint_reserved_module_fix else:
            return index + 1
        unsafe: read(module_fix).set(name, index)
    return index + 1


## Record the identifier use at (line, column) against the fix at `index`.
function reserved_record_use(index: ptr_uint, line: ptr_uint, column: ptr_uint) -> void:
    if line == 0 or column == 0:
        return
    let fixes_ptr = lint_reserved_fixes else:
        return
    if index >= unsafe: read(fixes_ptr).len():
        return
    let fp = unsafe: read(fixes_ptr).get(index) else:
        return
    let fix = unsafe: read(fp)
    unsafe:
        read(fp).sites.push(ReservedNameSite(line = line, column = column, length = fix.original_name.len))


## Collect the reserved-primitive-name rename fixes for `source` — the host's
## `collect_reserved_primitive_name_fixes`.  The caller releases the result
## with `release_reserved_name_fixes`.
public function collect_reserved_primitive_name_fixes(
    source: str,
    path: str,
    options: LintOptions
) -> vec.Vec[ReservedNameFix]:
    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer: parse_diags.release()
    let file = parser.parse_source(source, ref_of(parse_diags))
    var collected = vec.Vec[ReservedNameFix].create()
    lint_reserved_out = ptr_of(collected)
    var warnings = lint_source_with(file, source, path, options)
    warnings.release()
    return collected


function reserved_type_params_warn(
    type_params: span[ast.TypeParam],
    path: str,
    warnings: ref[vec.Vec[Warning]]
) -> void:
    var i: ptr_uint = 0
    while i < type_params.len:
        unsafe:
            let tp = read(type_params.data + i)
            if is_reserved_type_name(tp.name):
                reserved_name_warn(path, tp.line, tp.column, tp.name, "type parameter", warnings)
        i += 1


function reserved_name_warn(
    path: str,
    line: ptr_uint,
    column: ptr_uint,
    name: str,
    kind_label: str,
    warnings: ref[vec.Vec[Warning]]
) -> void:
    var buf = string.String.create()
    buf.append(kind_label)
    buf.append(" '")
    buf.append(name)
    buf.append("' uses reserved built-in type name '")
    buf.append(name)
    buf.append("'; rename it before this becomes a hard error")
    push_warning_at(warnings, path, line, column, name.len, "reserved-primitive-name", buf.as_str(), "warning")

# =============================================================================
#  borrow-and-mutate — warn when a variable is borrowed and also mutated.
# =============================================================================

## The first `ref_of`/`ptr_of` site seen for a borrowed name.  The host finds
## the earliest site with `find_borrow_location`; recording it during collection
## gives the same anchor without a second walk.
struct BorrowSite:
    name: str
    line: ptr_uint
    column: ptr_uint
    length: ptr_uint


function borrow_check_body(body: ptr[ast.Stmt]?, path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    let bp = body else:
        return
    var borrows = vec.Vec[BorrowSite].create()
    defer: borrows.release()
    var writes = vec.Vec[str].create()
    defer: writes.release()
    borrow_collect_body(bp, ref_of(borrows), ref_of(writes))
    var i: ptr_uint = 0
    while i < borrows.len():
        let site_ptr = borrows.get(i) else:
            break
        let site = unsafe: read(site_ptr)
        if borrow_vec_contains(ref_of(writes), site.name):
            var buf = string.String.create()
            buf.append("'")
            buf.append(site.name)
            buf.append("' is borrowed via ref_of/ptr_of and also mutated in the same scope — potential aliasing hazard")
            push_warning_at(
                warnings, path, site.line, site.column, site.length,
                "borrow-and-mutate", buf.as_str(), "warning"
            )
        i += 1


function borrow_collect_body(body: ptr[ast.Stmt], borrows: ref[vec.Vec[BorrowSite]], writes: ref[vec.Vec[str]]) -> void:
    unsafe:
        match read(body):
            ast.Stmt.stmt_block as blk:
                borrow_collect_stmts(blk.statements, borrows, writes)
            _:
                borrow_collect_stmt(body, borrows, writes)


function borrow_collect_stmts(
    stmts: span[ast.Stmt],
    borrows: ref[vec.Vec[BorrowSite]],
    writes: ref[vec.Vec[str]]
) -> void:
    var i: ptr_uint = 0
    while i < stmts.len:
        unsafe:
            borrow_collect_stmt(stmts.data + i, borrows, writes)
        i += 1
    i = 0
    while i < stmts.len:
        unsafe:
            borrow_recurse_stmt(stmts.data + i, borrows, writes)
        i += 1


function borrow_collect_stmt(stmt: ptr[ast.Stmt], borrows: ref[vec.Vec[BorrowSite]], writes: ref[vec.Vec[str]]) -> void:
    unsafe:
        match read(stmt):
            ast.Stmt.stmt_assignment as asgn:
                borrow_collect_expr(asgn.value, borrows, writes, false)
                match read(asgn.target):
                    ast.Expr.expr_identifier as id:
                        if not borrow_vec_contains(writes, id.name):
                            writes.push(id.name)
                    _:
                        pass
            ast.Stmt.stmt_expression as ex:
                borrow_collect_expr(ex.expression, borrows, writes, false)
            ast.Stmt.stmt_local as loc:
                borrow_collect_expr_opt(loc.value, borrows, writes)
            ast.Stmt.stmt_ret as r:
                borrow_collect_expr_opt(r.value, borrows, writes)
            ast.Stmt.stmt_defer as df:
                borrow_collect_expr_opt(df.expression, borrows, writes)
            _:
                pass


function borrow_collect_expr(
    expr: ptr[ast.Expr],
    borrows: ref[vec.Vec[BorrowSite]],
    writes: ref[vec.Vec[str]],
    inside_call_argument: bool,
) -> void:
    unsafe:
        match read(expr):
            ast.Expr.expr_call as call:
                # The host ignores a `ref_of`/`ptr_of` that is itself a call
                # argument, and does not recurse into a recognized borrow call.
                if not inside_call_argument and borrow_is_ref_call(call.callee) and call.args.len > 0:
                    let first_arg = read(call.args.data + 0).arg_value
                    match read(first_arg):
                        ast.Expr.expr_identifier as id:
                            if not borrow_site_contains(borrows, id.name):
                                borrows.push(BorrowSite(
                                    name = id.name, line = id.line, column = id.column, length = id.name.len
                                ))
                        _:
                            pass
                else:
                    borrow_collect_expr(call.callee, borrows, writes, inside_call_argument)
                    var ai: ptr_uint = 0
                    while ai < call.args.len:
                        borrow_collect_expr(read(call.args.data + ai).arg_value, borrows, writes, true)
                        ai += 1
            ast.Expr.expr_binary_op as b:
                borrow_collect_expr(b.left, borrows, writes, inside_call_argument)
                borrow_collect_expr(b.right, borrows, writes, inside_call_argument)
            ast.Expr.expr_unary_op as u:
                borrow_collect_expr(u.operand, borrows, writes, inside_call_argument)
            ast.Expr.expr_member_access as m:
                borrow_collect_expr(m.receiver, borrows, writes, inside_call_argument)
            ast.Expr.expr_index_access as ix:
                borrow_collect_expr(ix.receiver, borrows, writes, inside_call_argument)
                borrow_collect_expr(ix.index, borrows, writes, inside_call_argument)
            ast.Expr.expr_if as iff:
                borrow_collect_expr(iff.condition, borrows, writes, inside_call_argument)
                borrow_collect_expr(iff.then_expr, borrows, writes, inside_call_argument)
                borrow_collect_expr(iff.else_expr, borrows, writes, inside_call_argument)
            ast.Expr.expr_unsafe as us:
                borrow_collect_expr(us.expression, borrows, writes, inside_call_argument)
            ast.Expr.expr_await as aw:
                borrow_collect_expr(aw.expression, borrows, writes, inside_call_argument)
            _:
                pass


function borrow_collect_expr_opt(
    expr: ptr[ast.Expr]?,
    borrows: ref[vec.Vec[BorrowSite]],
    writes: ref[vec.Vec[str]]
) -> void:
    let ep = expr else:
        return
    borrow_collect_expr(ep, borrows, writes, false)


function borrow_is_ref_call(callee: ptr[ast.Expr]) -> bool:
    unsafe:
        match read(callee):
            ast.Expr.expr_identifier as id:
                return id.name == "ref_of" or id.name == "ptr_of"
            _:
                return false


function borrow_recurse_stmt(stmt: ptr[ast.Stmt], borrows: ref[vec.Vec[BorrowSite]], writes: ref[vec.Vec[str]]) -> void:
    unsafe:
        match read(stmt):
            ast.Stmt.stmt_if as iff:
                var bi: ptr_uint = 0
                while bi < iff.branches.len:
                    borrow_collect_body_opt2(read(iff.branches.data + bi).body, borrows, writes)
                    bi += 1
                borrow_collect_body_opt2(iff.else_body, borrows, writes)
            ast.Stmt.stmt_match as mt:
                var ai: ptr_uint = 0
                while ai < mt.arms.len:
                    borrow_collect_body_opt2(read(mt.arms.data + ai).body, borrows, writes)
                    ai += 1
            ast.Stmt.stmt_while as wh:
                borrow_collect_body_opt2(wh.body, borrows, writes)
            ast.Stmt.stmt_for as fr:
                borrow_collect_body_opt2(fr.body, borrows, writes)
            ast.Stmt.stmt_unsafe as un:
                borrow_collect_body_opt2(un.body, borrows, writes)
            ast.Stmt.stmt_defer as df:
                borrow_collect_body_opt2(df.body, borrows, writes)
            ast.Stmt.stmt_block as blk:
                borrow_collect_stmts(blk.statements, borrows, writes)
            _:
                pass


function borrow_collect_body_opt2(
    body: ptr[ast.Stmt]?,
    borrows: ref[vec.Vec[BorrowSite]],
    writes: ref[vec.Vec[str]]
) -> void:
    let bp = body else:
        return
    borrow_collect_body(bp, borrows, writes)


function borrow_site_contains(values: ref[vec.Vec[BorrowSite]], name: str) -> bool:
    var i: ptr_uint = 0
    while i < values.len():
        let ep = values.get(i) else:
            break
        if unsafe: read(ep).name.equal(name):
            return true
        i += 1
    return false


function borrow_vec_contains(vec_ref: ref[vec.Vec[str]], name: str) -> bool:
    var i: ptr_uint = 0
    while i < vec_ref.len():
        let ep = vec_ref.get(i) else:
            break
        if unsafe: read(ep).equal(name):
            return true
        i += 1
    return false

# =============================================================================
#  Shared helpers for CFG-based rules
# =============================================================================

## Walk all function-like bodies in a source file (free functions and extending
## methods) and pass each body pointer to the given action.

# =============================================================================
#  dead-assignment — assignment whose value is never read
# =============================================================================

function lint_dead_body(
    flow_cfg: ref[flow_builder.Cfg],
    graph: ref[flow_graph.CfgGraph],
    path: str,
    warnings: ref[vec.Vec[Warning]],
) -> void:
    var live = flow_graph.liveness_create(0, 0)
    defer: flow_graph.liveness_release(ref_of(live))
    flow_graph.liveness_init_into(ref_of(live), read(flow_cfg).next_id, read(graph).next_id)
    flow_graph.solve_liveness(graph, ref_of(live))
    var readable = vec.Vec[ptr_uint].create()
    defer: readable.release()
    flow_graph.graph_read_keys(graph, ref_of(readable))
    var declared = vec.Vec[ptr_uint].create()
    defer: declared.release()
    flow_graph.graph_declared_keys(graph, ref_of(declared))
    var id: ptr_uint = 1
    while id < read(graph).next_id:
        let node = flow_graph.graph_node(graph, id) else:
            id += 1
            continue
        unsafe:
            var wi: ptr_uint = 0
            while wi < read(node).write_sites.len():
                let wp = read(node).write_sites.get(wi) else:
                    break
                let write = read(wp)
                # The host skips `declaration`/`call_argument` origins and then
                # requires a `locally_declared` key; under the host's
                # per-declaration ids no `for_binding`/`match_binding` key can
                # carry a declaration write, so an `assignment` origin is the
                # only origin that can fire.  The self keys bindings by name,
                # so that equivalence has to be stated directly.
                if write.origin == "assignment":
                    if key_in(ref_of(readable), write.key) and key_in(ref_of(declared), write.key):
                        if not flow_graph.live_out_has(ref_of(live), id, write.key):
                            var buf = string.String.create()
                            buf.append("value assigned to '")
                            buf.append(write.name)
                            buf.append("' is never read")
                            push_warning_at(
                                warnings,
                                path,
                                if write.line > 0: write.line else: 1,
                                if write.column > 0: write.column else: 0,
                                write.name.len,
                                "dead-assignment",
                                buf.as_str(),
                                "warning",
                            )
                wi += 1
        id += 1


function key_in(keys: ref[vec.Vec[ptr_uint]], key: ptr_uint) -> bool:
    var i: ptr_uint = 0
    while i < keys.len():
        let item = keys.get(i) else:
            break
        if unsafe: read(item) == key:
            return true
        i += 1
    return false

# =============================================================================
#  unreachable-code — statement after a terminating statement
# =============================================================================

## The host's `emit_unreachable_warnings`: every CFG node not reachable from
## the entry, except the exit node, anchored at its statement's own span.
function lint_unreachable_graph(graph: ref[flow_graph.CfgGraph], path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    var reachable = ownership_reachable_ids(graph)
    defer: reachable.release()
    var ni: ptr_uint = 0
    let count = unsafe: read(graph).nodes.len()
    while ni < count:
        let slot = unsafe: read(graph).nodes.get(ni) else:
            break
        let node = unsafe: read(slot)
        let id = unsafe: read(node).id
        let is_exit = unsafe: read(node).kind.equal("exit")
        let has_statement = unsafe: read(node).statement != 0
        if not ownership_ids_contain(ref_of(reachable), id) and not is_exit and has_statement:
            let line = unreachable_line(node)
            let column = unreachable_column(node)
            let length = unreachable_length(node)
            push_warning_at(warnings, path, line, column, length, "unreachable-code", "unreachable code", "warning")
        ni += 1


## The host's `statement.line` for the node's stored statement: an if-condition
## node holds its `IfBranch`, a match-binding node its `MatchArm` (whose line is
## the pattern's), every other node a statement.
function unreachable_line(node: ptr[flow_graph.CfgNode]) -> ptr_uint:
    unsafe:
        let kind = read(node).kind
        if kind.equal("match_binding"):
            let arm = reinterpret[ptr[ast.MatchArm]](read(node).statement)
            return expression_line(read(arm).pattern)
        return read(node).line


function unreachable_column(node: ptr[flow_graph.CfgNode]) -> ptr_uint:
    unsafe:
        let kind = read(node).kind
        if kind.equal("match_binding"):
            let arm = reinterpret[ptr[ast.MatchArm]](read(node).statement)
            return expression_column(read(arm).pattern)
        let column = read(node).column
        if column != 0:
            return column
        # The builder stamps 0 for expression statements; recover the host's
        # statement anchor from the AST.
        return statement_column(reinterpret[ptr[ast.Stmt]](read(node).statement))


function unreachable_length(node: ptr[flow_graph.CfgNode]) -> ptr_uint:
    unsafe:
        let kind = read(node).kind
        if kind.equal("if_condition"):
            let branch = reinterpret[ptr[ast.IfBranch]](read(node).statement)
            return read(branch).length
        if kind.equal("match_binding"):
            return 0
        return statement_length(reinterpret[ptr[ast.Stmt]](read(node).statement))

# =============================================================================
#  constant-condition — the host's `emit_constant_condition_warnings`
# =============================================================================

## The host's `source_code_line`: the line with trailing whitespace removed.
function source_code_line(line: ptr_uint) -> Option[str]:
    let lp = lint_source_lines else:
        return Option[str].none
    let lines = unsafe: read(lp)
    if line == 0 or line > lines.len():
        return Option[str].none
    let sp = lines.get(line - 1) else:
        return Option[str].none
    return Option[str].some(value = rstrip_line(unsafe: read(sp)))


## Trailing whitespace removed (the host's `rstrip`).
function rstrip_line(text: str) -> str:
    var end = text.len
    while end > 0:
        let b = text.byte_at(end - 1)
        if b == 32 or b == 9 or b == 13:
            end -= 1
        else:
            break
    return text.slice(0, end)

struct ConditionSpan:
    line: ptr_uint
    column: ptr_uint
    length: ptr_uint


## The host's `condition_span`: it prefers the *source line's* keyword-to-colon
## span over the expression's own position.
function condition_span(expr: ptr[ast.Expr], line: ptr_uint, is_while: bool) -> ConditionSpan:
    match source_condition_span(line, is_while):
        Option.some as sp:
            return sp.value
        Option.none:
            var eline = expression_line(expr)
            if eline == 0:
                eline = line
            return ConditionSpan(line = eline, column = expression_column(expr), length = expression_length(expr))


## The host's `source_condition_span`: on the given line, the keyword
## (`else if` / `if` / `while`) followed by the condition text up to the `:`.
function source_condition_span(line: ptr_uint, is_while: bool) -> Option[ConditionSpan]:
    let text = source_code_line(line) else:
        return Option[ConditionSpan].none
    var i: ptr_uint = 0
    while i < text.len and (text.byte_at(i) == 32 or text.byte_at(i) == 9):
        i += 1
    var after_keyword: ptr_uint = 0
    if is_while:
        if not text_matches_at(text, i, "while"):
            return Option[ConditionSpan].none
        after_keyword = i + 5
    else:
        if text_matches_at(text, i, "else if"):
            after_keyword = i + 7
        else if text_matches_at(text, i, "if"):
            after_keyword = i + 2
        else:
            return Option[ConditionSpan].none
    if after_keyword >= text.len:
        return Option[ConditionSpan].none
    let sep = text.byte_at(after_keyword)
    if not (sep == 32 or sep == 9):
        return Option[ConditionSpan].none
    var start = after_keyword
    while start < text.len and (text.byte_at(start) == 32 or text.byte_at(start) == 9):
        start += 1
    var colon = start
    var found = false
    while colon < text.len:
        if text.byte_at(colon) == 58:
            found = true
            break
        colon += 1
    if not found:
        return Option[ConditionSpan].none
    let cond = rstrip_line(text.slice(start, colon - start))
    if cond.len == 0:
        return Option[ConditionSpan].none
    return Option[ConditionSpan].some(value = ConditionSpan(line = line, column = start + 1, length = cond.len))


function text_matches_at(text: str, at: ptr_uint, needle: str) -> bool:
    if at + needle.len > text.len:
        return false
    var i: ptr_uint = 0
    while i < needle.len:
        if text.byte_at(at + i) != needle.byte_at(i):
            return false
        i += 1
    return true


## The host's `emit_constant_condition_warnings` over one body: the shared
## graph, the constant-propagation solver, the loop-body skip, then the
## source-line anchor.
function lint_const_cond_in_body(
    flow_cfg: ref[flow_builder.Cfg],
    graph: ref[flow_graph.CfgGraph],
    path: str,
    warnings: ref[vec.Vec[Warning]]
) -> void:
    var states = constprop.states_empty()
    defer: constprop.states_release(ref_of(states))
    constprop.solve_into(flow_cfg, graph, ref_of(states))
    var loop_bodies = vec.Vec[ptr_uint].create()
    defer: loop_bodies.release()
    constprop.loop_body_nodes(graph, ref_of(loop_bodies))
    var id: ptr_uint = 1
    while id < read(graph).next_id:
        let node = flow_graph.graph_node(graph, id) else:
            id += 1
            continue
        lint_const_cond_node(flow_cfg, ref_of(states), ref_of(loop_bodies), node, path, warnings)
        id += 1


function lint_const_cond_node(
    flow_cfg: ref[flow_builder.Cfg],
    states: ref[constprop.FlowStates],
    loop_bodies: ref[vec.Vec[ptr_uint]],
    node: ptr[flow_graph.CfgNode],
    path: str,
    warnings: ref[vec.Vec[Warning]],
) -> void:
    let kind = unsafe: read(node).kind
    let is_if = kind.equal("if_condition")
    let is_while = kind.equal("while_condition")
    if not (is_if or is_while):
        return
    if is_if and constprop.id_in(loop_bodies, unsafe: read(node).id):
        # An if-condition in a loop's reach: variables can change across
        # iterations, so the host does not warn.
        return
    if is_while and constprop.while_is_true(node):
        # `while true` is an idiomatic infinite loop.
        return
    let cond = constprop.node_condition(node) else:
        return
    match constprop.condition_value_of(flow_cfg, states, node):
        Option.some as val:
            let line = unsafe: read(node).line
            let span = condition_span(cond, line, is_while)
            var buf = string.String.create()
            if is_while:
                buf.append("loop condition is always ")
            else:
                buf.append("branch condition is always ")
            buf.append(if val.value: "true" else: "false")
            push_warning_at(
                warnings,
                path,
                span.line,
                span.column,
                span.length,
                "constant-condition",
                buf.as_str(),
                "warning"
            )
        Option.none:
            pass

# =============================================================================
#  loop-single-iteration — loop body always breaks/returns on first iteration
# =============================================================================

function lint_loop_single_in_body(body: ptr[ast.Stmt]?, path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    let bp = body else:
        return
    unsafe:
        match read(bp):
            ast.Stmt.stmt_block as blk:
                var si: ptr_uint = 0
                while si < blk.statements.len:
                    lint_loop_single_stmt(blk.statements.data + si, path, warnings)
                    si += 1
            _:
                pass


## The host's `Termination.loop_body_always_terminates?`: a fresh loop-body
## graph whose fall-through/`continue` target is unreachable from the entry.
## This is what excludes a body that can `continue` before its `return` — the
## AST return heuristic over-reported those.
function loop_body_always_terminates(body: ptr[ast.Stmt]?) -> bool:
    if body == null:
        return false
    var cfg = flow_builder.empty_cfg()
    defer: flow_builder.cfg_release(ref_of(cfg))
    var graph = flow_graph.empty_graph()
    defer: flow_graph.graph_release(ref_of(graph))
    flow_builder.build_graph_loop_body_into(ref_of(cfg), ref_of(graph), body)
    let entry = unsafe: read(ref_of(graph)).entry_id
    let exit = unsafe: read(ref_of(graph)).exit_id
    return not flow_graph.graph_reaches(ref_of(graph), entry, exit)


function lint_loop_single_stmt(sp: ptr[ast.Stmt], path: str, warnings: ref[vec.Vec[Warning]]) -> void:
    unsafe:
        match read(sp):
            ast.Stmt.stmt_while as wh:
                if loop_body_always_terminates(wh.body):
                    push_warning_at(
                        warnings, path, wh.line, wh.column,
                        if wh.length > 0: wh.length else: 5,
                        "loop-single-iteration",
                        "loop body always exits on the first iteration - consider replacing with an 'if' block",
                        "warning"
                    )
                lint_loop_single_in_body(wh.body, path, warnings)
            ast.Stmt.stmt_for as fr:
                if loop_body_always_terminates(fr.body):
                    push_warning_at(
                        warnings, path, fr.line, fr.column, 3,
                        "loop-single-iteration",
                        "loop body always exits on the first iteration - consider iterating directly without a loop",
                        "warning"
                    )
                lint_loop_single_in_body(fr.body, path, warnings)
            ast.Stmt.stmt_if as iff:
                var bi: ptr_uint = 0
                while bi < iff.branches.len:
                    lint_loop_single_in_body(read(iff.branches.data + bi).body, path, warnings)
                    bi += 1
                lint_loop_single_in_body(iff.else_body, path, warnings)
            ast.Stmt.stmt_match as mt:
                var ai: ptr_uint = 0
                while ai < mt.arms.len:
                    lint_loop_single_in_body(read(mt.arms.data + ai).body, path, warnings)
                    ai += 1
            ast.Stmt.stmt_unsafe as un:
                lint_loop_single_in_body(un.body, path, warnings)
            ast.Stmt.stmt_defer as df:
                lint_loop_single_in_body(df.body, path, warnings)
            ast.Stmt.stmt_when as wn:
                var wi: ptr_uint = 0
                while wi < wn.branches.len:
                    let branch = read(wn.branches.data + wi)
                    var bji: ptr_uint = 0
                    while bji < branch.body.len:
                        lint_loop_single_stmt(branch.body.data + bji, path, warnings)
                        bji += 1
                    wi += 1
                lint_loop_single_in_body(wn.else_body, path, warnings)
            ast.Stmt.stmt_block as blk:
                var bsi: ptr_uint = 0
                while bsi < blk.statements.len:
                    lint_loop_single_stmt(blk.statements.data + bsi, path, warnings)
                    bsi += 1
            _:
                pass

# =============================================================================
#  redundant-null-check — `x != null` where x is already narrowed non-null
# =============================================================================
