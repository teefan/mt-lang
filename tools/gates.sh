#!/usr/bin/env bash
# gates.sh — pick (and optionally run) the gate set a change actually needs.
#
# The parity program's gates are tiered so iteration stays cheap and the
# expensive proofs run once per commit:
#
#   tier 1  iteration, minutes   — a dev build plus the focused sweep(s) for
#                                  the area being changed
#   tier 2  once per commit      — the hard proofs (bootstrap fixed point) and
#                                  the wide sweeps, run against the frozen
#                                  sources
#
# Areas are inferred from `git diff --name-only` (or given with --areas).
# Discovery is the default; use --run to execute the list in order.
#
# Usage:
#   tools/gates.sh [--areas a,b,c] [--diff REF] [--tier 1|2|all] [--only id,…]
#                  [--run] [--quiet]
#
#   --areas LIST   comma-separated areas (analyzer,linter,lsp,codegen,parser,
#                  loader,cli,formatter,std,examples,bindings,dap,docs,tools,…)
#   --diff REF     infer the areas from `git diff REF --name-only` (default HEAD)
#   --tier N       print/run only that tier (default all)
#   --only LIST    restrict to these gate ids (comma-separated)
#   --run          execute (default: print the plan)
#   --quiet        print only the run summary
#
# Every gate writes tmp/gates/<id>.log.  A "hard" gate stops the run when it
# fails; a "meter" gate always continues — its numbers are compared by hand
# (the corpus-wide counters are expected to carry known differences).
#
# Session rules this script encodes:
#   * Rebuild before measuring (tier 1 starts with the dev build; tier 2 with
#     the bootstrap, which produces the stage2 every later gate uses).
#   * Iterate on tier 1, prove once per batch: the per-fix loop is the dev
#     build + the focused sweeps (seconds warm); the tier-2 proofs (bootstrap
#     fixed point, test/mt, examples) run on the frozen sources once per
#     landed batch, not once per fix.
#   * Never edit sources while a gate runs — bootstrap compiles the working
#     tree, so a mid-run edit silently corrupts the result.
#   * Do not re-measure a baseline the previous session verified at this same
#     commit; measure only the classes your change can move.
#   * Touch unrelated gates (linter, LSP, CLI, formatter, bindings) only when
#     the diff reaches those subsystems — area inference already does this.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

AREA_LIST=""
DIFF_REF=""
TIER="all"
ONLY=""
DO_RUN=0
QUIET=0

while [ $# -gt 0 ]; do
    case "$1" in
        --areas) AREA_LIST="${2:-}"; shift 2 ;;
        --diff)  DIFF_REF="${2:-}"; shift 2 ;;
        --tier)  TIER="${2:-}"; shift 2 ;;
        --only)  ONLY="${2:-}"; shift 2 ;;
        --run)   DO_RUN=1; shift ;;
        --quiet) QUIET=1; shift ;;
        -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "gates.sh: unknown option $1" >&2; exit 2 ;;
    esac
done

# ── area inference ──────────────────────────────────────────────────────────

infer_area() {
    local f="$1"
    case "$f" in
        projects/mtc/src/mtc/semantic/*)          echo analyzer ;;
        projects/mtc/src/mtc/linter/*)            echo linter ;;
        projects/mtc/src/mtc/lsp/*)               echo lsp ;;
        projects/mtc/src/mtc/lowering/*|projects/mtc/src/mtc/c_backend/*|projects/mtc/src/mtc/c_naming.mt|projects/mtc/src/mtc/pretty_printer/*) echo codegen ;;
        projects/mtc/src/mtc/parser/*)            echo parser ;;
        projects/mtc/src/mtc/loader/*)            echo loader ;;
        projects/mtc/src/mtc/formatter/*)         echo formatter ;;
        projects/mtc/src/mtc/dap/*)               echo dap ;;
        projects/mtc/src/mtc/imported_bindings/*|projects/mtc/src/mtc/bindgen.mt|bindings/*|lib/milk_tea/bindings/*) echo bindings ;;
        projects/mtc/src/mtc/packages/*)          echo packages ;;
        projects/mtc/src/mtc/docs_cli.mt|projects/mtc/src/mtc/docs_app.mt) echo docs_cli ;;
        projects/mtc/src/mtc/wasm*.mt|projects/mtc/src/mtc/wasm/*) echo wasm ;;
        projects/mtc/src/mtc/toolchain_cli.mt)    echo toolchain ;;
        projects/mtc/src/mtc/main.mt|projects/mtc/src/mtc/build*.mt|projects/mtc/src/mtc/build_cache.mt|projects/mtc/src/mtc/version_info.mt) echo cli ;;
        projects/mtc/test/*|test/mt/*)            echo tests ;;
        lib/*)                                    echo host ;;
        std/*)                                    echo std ;;
        examples/*)                               echo examples ;;
        docs/*)                                   echo docs ;;
        tools/*|Rakefile)                         echo tools ;;
        *)                                        echo other ;;
    esac
}

if [ -n "$AREA_LIST" ]; then
    AREAS="$(printf '%s' "$AREA_LIST" | tr ',' ' ')"
else
    ref="${DIFF_REF:-HEAD}"
    changed="$(git -C "$ROOT" diff "$ref" --name-only 2>/dev/null || true)"
    if [ -z "$changed" ]; then
        echo "gates.sh: no changes vs $ref — pass --areas or --diff REF" >&2
        exit 2
    fi
    AREAS="$(printf '%s\n' "$changed" | while read -r f; do [ -n "$f" ] && infer_area "$f"; done | sort -u | tr '\n' ' ')"
fi

# ── gate catalog ────────────────────────────────────────────────────────────

gate_kind() {
    case "$1" in
        bootstrap|test_mt|dev_build|dev_tests|unused_import|recovery|format|dap|tools_check|bindings|bindings_parity|bindgen_parity|wasm_smoke|docs_smoke|diag_parity) echo hard ;;
        *) echo meter ;;
    esac
}

gate_tier() {
    case "$1" in
        dev_build|dev_tests|tools_check) echo 1 ;;
        *) echo 2 ;;
    esac
}

gate_label() {
    case "$1" in
        dev_build)      echo "dev build to tmp/mtc-dev (~50 s)" ;;
        dev_tests)      echo "self-host suite, one process per file (~1 min)" ;;
        bootstrap)      echo "bootstrap --fast: fixed point only (~12 min)" ;;
        test_mt)        echo "test/mt under stage2 (60 files / 0 failed)" ;;
        sexpr_lex)      echo "sexpr lex parity (718/718)" ;;
        sexpr_parse)    echo "sexpr parse parity (714 match / 0 differ / 4 host-rejected of 718)" ;;
        sexpr_lower)    echo "sexpr lower parity (meter, ~1 min warm / ~4 min cold host cache)" ;;
        cli_parity)     echo "CLI parity (224 cases; 224 match; no allowlist)" ;;
        wasm_smoke)     echo "wasm preview end-to-end (host + self HTTP/signal smoke)" ;;
        docs_smoke)     echo "docs server end-to-end (host + self routes/SIGINT smoke)" ;;
        scoreboard)     echo "parity scoreboard (meter)" ;;
        format)         echo "formatter parity all modes (712/712)" ;;
        lint_parity)    echo "corpus-wide lint parity (meter, ~5 min)" ;;
        diag_parity)    echo "check diagnostic parity: verdict/message/position (~2 min)" ;;
        unused_import)  echo "unused-import parity (616/616, ~30 min)" ;;
        harness)        echo "LSP harness 30/30 + 4 documented entries (~3 min)" ;;
        recovery)       echo "LSP recovery probe (byte-compared)" ;;
        fixtures)       echo "LSP fixture sweep vs baselines (when tmp/ has it)" ;;
        audit)          echo "full LSP project audit (meter, ~5-15 min)" ;;
        examples)       echo "example emit-c sweeps: examples/*.mt + examples/sdl3" ;;
        valgrind_lsp)   echo "valgrind over an LSP drive (0 errors)" ;;
        neovim)         echo "headless-Neovim smoke (when tmp/ has the script)" ;;
        soak)           echo "long-session soak meter (~25 s): RSS slope for mixed requests" ;;
        bindings)       echo "imported-bindings --all --check (29/29)" ;;
        bindings_parity) echo "imported-bindings vs host parity report (29/29)" ;;
        bindgen_parity) echo "bindgen reproducibility vs the host (33 match / 1 custom)" ;;
        dap)            echo "DAP smoke + async launch-order probe (lldb-dap required)" ;;
        wasm_smoke)     echo "^wasm smoke:" ;;
        docs_smoke)     echo "^docs smoke:" ;;
        tools_check)    echo "Ruby/bash syntax check for the tools/ harnesses" ;;
        *)              echo "$1" ;;
    esac
}

gate_cmd() {
    case "$1" in
        dev_build)     echo "ruby -Ilib bin/mtc build projects/mtc -I . --no-cache -o tmp/mtc-dev" ;;
        dev_tests)     echo "gates_dev_tests" ;;
        bootstrap)     echo "tools/bootstrap.sh -j 16 --fast" ;;
        test_mt)       echo "build/stage2/mtc test test/mt -I ." ;;
        sexpr_lex)     echo "ruby tools/sexpr_parity.rb lex -q --host-cache tmp/sexpr-host-cache" ;;
        sexpr_parse)   echo "ruby tools/sexpr_parity.rb parse -q --host-cache tmp/sexpr-host-cache" ;;
        sexpr_lower)   echo "ruby tools/sexpr_parity.rb lower -q -j 16 --host-cache tmp/sexpr-host-cache" ;;
        cli_parity)    echo "ruby tools/cli_parity.rb -q" ;;
        scoreboard)    echo "rake parity:scoreboard" ;;
        format)        echo "ruby tools/format_parity.rb all -j 16" ;;
        lint_parity)   echo "ruby tools/lint_parity.rb -q" ;;
        unused_import) echo "ruby tools/unused_import_parity.rb" ;;
        harness)       echo "ruby tools/lsp_parity.rb record --server host --out tmp/lsp-host-gates.json --stress && ruby tools/lsp_parity.rb record --server self --out tmp/lsp-self-gates.json --stress && ruby tools/lsp_parity.rb compare tmp/lsp-host-gates.json tmp/lsp-self-gates.json" ;;
        recovery)      echo "ruby tools/lsp_recovery_probe.rb --check" ;;
        fixtures)      echo "[ -f tmp/fixtures_sweep.sh ] && bash tmp/fixtures_sweep.sh || echo 'skipped: no tmp/fixtures_sweep.sh (session-local)'" ;;
        audit)         echo "[ -d \${SIMPLEGAME:-\$HOME/Projects/MilkTea/SimpleGame} ] && { ruby tools/lsp_project_audit.rb --workspace \${SIMPLEGAME:-\$HOME/Projects/MilkTea/SimpleGame} --json tmp/audit-gates.json --max-diffs 0 --timeout 60 && ruby tools/lsp_audit_diffs.rb tmp/audit-gates.json; } || echo 'skipped: no SimpleGame workspace'" ;;
        examples)      echo "gates_examples" ;;
        valgrind_lsp)  echo "command -v valgrind >/dev/null && gates_valgrind || echo 'skipped: valgrind not installed'" ;;
        neovim)        echo "gates_neovim" ;;
        soak)          echo "ruby tools/lsp_soak.rb --quiet" ;;
        bindings)      echo "build/stage2/mtc imported-bindings --all --check" ;;
        bindings_parity) echo "ruby tools/imported_bindings_parity.rb --json tmp/gates/ib-parity.json" ;;
        bindgen_parity) echo "ruby tools/bindgen_parity.rb --self build/stage2/mtc -q" ;;
        dap)           echo "ruby tools/dap_smoke.rb && ruby tools/dap_async_probe.rb" ;;
        wasm_smoke)    echo "ruby tools/wasm_smoke.rb --self build/stage2/mtc" ;;
        docs_smoke)    echo "ruby tools/docs_smoke.rb --self build/stage2/mtc" ;;
        tools_check)   echo "for f in tools/*.rb; do ruby -c \"\$f\" >/dev/null || exit 1; done; bash -n tools/gates.sh tools/bootstrap.sh && echo 'tools syntax ok'" ;;
        *)             echo "true" ;;
    esac
}

gate_summary() {
    case "$1" in
        dev_build|bootstrap|dev_tests|test_mt) echo "fixed point|test file|built projects" ;;
        sexpr_lex)      echo "^mode=lex" ;;
        sexpr_parse)    echo "^mode=parse" ;;
        sexpr_lower)    echo "^mode=lower|match=" ;;
        cli_parity)     echo "^cases=" ;;
        scoreboard)     echo "^cli |^lex |^parse |^lint " ;;
        format)         echo "differ|match" ;;
        lint_parity)    echo "^files=" ;;
        diag_parity)    echo "^mode=" ;;
        unused_import)  echo "^files=" ;;
        harness)        echo "TOTAL differing|capabilities:" ;;
        recovery)       echo "recovery parity" ;;
        fixtures)       echo "added [1-9]|^== |total differing|skipped" ;;
        audit)          echo "TOTAL differing|skipped" ;;
        examples)       echo "^examples same=|DIFF " ;;
        valgrind_lsp)   echo "ERROR SUMMARY|skipped" ;;
        neovim)         echo "HOVER|Error|skipped" ;;
        soak)           echo "^label=" ;;
        bindings)       echo "verified|changed" ;;
        bindings_parity) echo "^bindings=" ;;
        bindgen_parity) echo "^files=" ;;
        dap)            echo "differing rows|dap async probe|stderr:" ;;
        tools_check)    echo "tools syntax ok" ;;
        *)              echo "." ;;
    esac
}

# Self-host suite, one process per test file.  Each test file runs as its own
# `mtc test <file>` invocation, so the workers are independent — the test path
# does not touch the build cache.  (The runner names carry the process id, so
# parallel invocations share the test directory safely.)  Two robustness rules,
# both learned the hard way: the fan-out is
# capped at half the cores (a 16-wide run under browser memory pressure aborted
# debug_info_test.mt, which passes serially), and a failing file is re-run once,
# alone, before it counts.
gates_dev_tests() {
    local d="tmp/gate-dev-tests" f name rc=0 failed=0 n=0
    local files=(projects/mtc/test/*.mt)
    local jobs=$(( $(nproc) / 2 ))
    [ "$jobs" -lt 1 ] && jobs=1
    rm -rf "$d"; mkdir -p "$d"
    printf '%s\n' "${files[@]}" \
        | xargs -P "$jobs" -I{} bash -c '
            f="$1"; d="$2"; name="$(basename "$f")"
            tmp/mtc-dev test "$f" -I . -I projects/mtc/src --timeout 120 \
                > "$d/$name.log" 2>&1
            echo $? > "$d/$name.rc"
        ' _ {} "$d"
    for f in "${files[@]}"; do
        name="$(basename "$f")"
        if [ "$(cat "$d/$name.rc")" != 0 ]; then
            tmp/mtc-dev test "$f" -I . -I projects/mtc/src --timeout 120 \
                > "$d/$name.log" 2>&1
            echo $? > "$d/$name.rc"
        fi
    done
    for f in "${files[@]}"; do
        name="$(basename "$f")"
        cat "$d/$name.log"
        n=$((n + 1))
        [ "$(cat "$d/$name.rc")" = 0 ] || { rc=1; failed=$((failed + 1)); }
    done
    echo "$n test file(s), $failed failed"
    rm -rf "$d"
    return $rc
}

# Inline example sweep: emit-c exit status + first diagnostic line, host vs self.
gates_examples() {
    local rc=0 same=0 differ=0 f out_h out_s line_h line_s
    for f in examples/*.mt examples/sdl3/*/*.mt; do
        [ -e "$f" ] || continue
        out_h="$(timeout 120 ruby -Ilib bin/mtc emit-c "$f" 2>&1 >/dev/null)"; line_h="$(printf '%s\n' "$out_h" | head -1)"
        out_s="$(timeout 120 build/stage2/mtc emit-c "$f" 2>&1 >/dev/null)"; line_s="$(printf '%s\n' "$out_s" | head -1)"
        if [ "$line_h" != "$line_s" ]; then
            rc=1; differ=$((differ + 1)); echo "DIFF $f"; echo "  host: $line_h"; echo "  self: $line_s"
        else
            same=$((same + 1))
        fi
    done
    echo "examples same=$same differ=$differ"
    return $rc
}

gates_neovim() {
    local script="tmp/nvim_hover_smoke.lua"
    local target="${NEOVIM_TARGET:-$HOME/Projects/MilkTea/SimpleGame/docs/language_baseline.mt}"
    if [ ! -f "$script" ]; then echo "skipped: no tmp/nvim_hover_smoke.lua (session-local)"; return 0; fi
    if [ ! -f "$target" ]; then echo "skipped: no $target (set NEOVIM_TARGET)"; return 0; fi
    nvim --headless -u NONE -l "$script" build/stage2/mtc "$target" "${NEOVIM_LINE:-1586}" "${NEOVIM_COL:-15}"
}

gates_valgrind() {
    local wrapper="tmp/mtc-vg-gates.sh" log="tmp/mtc-vg-gates.log"
    cat > "$wrapper" <<EOF
#!/usr/bin/env bash
exec valgrind --error-exitcode=99 --log-file=$ROOT/$log $ROOT/build/stage2/mtc "\$@"
EOF
    chmod +x "$wrapper"
    # The wrapper is the self *binary* (spawned with the `lsp` argument), not a
    # server kind — passing it as `--server` would run it with no arguments.
    ruby tools/lsp_parity.rb record --server self --self "$wrapper" --out tmp/lsp-self-vg-gates.json --stress --timeout 120 >/dev/null 2>&1
    local rc=$?
    grep -A3 "ERROR SUMMARY" "$log" | tail -2
    [ $rc -eq 0 ] || return $rc
    ! grep -qE "ERROR SUMMARY: [1-9]" "$log"
}

# ── area → gate mapping ─────────────────────────────────────────────────────

gates_for_area() {
    case "$1" in
        analyzer)  echo "bootstrap test_mt cli_parity diag_parity scoreboard lint_parity unused_import harness recovery fixtures audit examples valgrind_lsp neovim" ;;
        linter)    echo "bootstrap test_mt cli_parity diag_parity scoreboard lint_parity unused_import harness fixtures audit" ;;
        lsp)       echo "bootstrap harness recovery fixtures audit valgrind_lsp neovim soak" ;;
        codegen)   echo "bootstrap test_mt sexpr_lower examples" ;;
        parser)    echo "bootstrap sexpr_lex sexpr_parse diag_parity recovery cli_parity scoreboard" ;;
        loader)    echo "bootstrap test_mt cli_parity audit examples" ;;
        cli)       echo "bootstrap test_mt cli_parity" ;;
        formatter) echo "bootstrap format" ;;
        bindings)  echo "bootstrap bindings bindings_parity bindgen_parity" ;;
        dap)       echo "bootstrap dap" ;;
        std)       echo "examples lint_parity" ;;
        examples)  echo "examples" ;;
        host)      echo "bootstrap" ;;
        tests)     echo "dev_build dev_tests" ;;
        wasm)      echo "bootstrap test_mt cli_parity wasm_smoke" ;;
        docs_cli)  echo "bootstrap test_mt cli_parity docs_smoke" ;;
        packages|toolchain) echo "bootstrap test_mt cli_parity" ;;
        tools)     echo "tools_check" ;;
        docs|other) echo "" ;;
        *)         echo "bootstrap test_mt scoreboard" ;;
    esac
}

GATES=""
for area in $AREAS; do
    for g in $(gates_for_area "$area"); do
        case " $GATES " in *" $g "*) ;; *) GATES="$GATES $g" ;; esac
    done
done
# The dev build leads the iteration tier; a docs/tools-only change has no gates.
[ -n "$GATES" ] && GATES="dev_build$GATES"

ordered=""
for t in 1 2; do
    [ "$TIER" = "all" ] || [ "$TIER" = "$t" ] || continue
    for g in $GATES; do
        [ "$(gate_tier "$g")" = "$t" ] || continue
        if [ -n "$ONLY" ]; then
            case ",$ONLY," in *",$g,"*) ;; *) continue ;; esac
        fi
        case " $ordered " in *" $g "*) ;; *) ordered="$ordered $g" ;; esac
    done
done
ordered="${ordered# }"

if [ -z "$ordered" ]; then
    echo "gates.sh: nothing to run (areas: ${AREAS:-none})"
    exit 0
fi

[ "$QUIET" = 1 ] || {
    echo "areas: $AREAS"
    echo "gates:"
    for g in $ordered; do
        printf '  [%s] %-14s %s\n' "$(gate_tier "$g")" "$g" "$(gate_label "$g")"
    done
}

[ "$DO_RUN" = 1 ] || exit 0

mkdir -p tmp/gates
overall=0
for g in $ordered; do
    cmd="$(gate_cmd "$g")"
    [ "$QUIET" = 1 ] || echo "── $g: $cmd"
    eval "$cmd" > "tmp/gates/$g.log" 2>&1
    rc=$?
    summary="$(grep -E "$(gate_summary "$g")" "tmp/gates/$g.log" 2>/dev/null | tail -2 | tr '\n' ' | ' | cut -c1-160)"
    printf '%-14s rc=%-3s %s\n' "$g" "$rc" "$summary"
    if [ "$(gate_kind "$g")" = "hard" ] && [ "$rc" != 0 ]; then
        echo "gates.sh: HARD gate failed: $g (log: tmp/gates/$g.log)" >&2
        overall=1
        break
    fi
done
exit $overall
