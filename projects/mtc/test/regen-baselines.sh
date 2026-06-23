#!/bin/bash
# Regenerate C baselines from the Ruby reference compiler.
# Copies fixtures to flat paths to get clean module names (fixture_NN_xxx).
set -euo pipefail
cd "$(dirname "$0")/.."

echo "=== Regenerating baselines (Ruby compiler) ==="

rm -rf test/fixtures/c
mkdir -p test/fixtures/c

for f in test/fixtures/*.mt; do
    name=$(basename "$f" .mt)
    tmp="/tmp/fixture_$name.mt"
    cp "$f" "$tmp"
    if mtc emit-c "$tmp" > "test/fixtures/c/${name}.c" 2>/dev/null; then
        echo "  $name → $(wc -l < test/fixtures/c/${name}.c) lines"
    else
        echo "  $name FAILED"
    fi
    rm -f "$tmp"
done

echo "=== Done: $(ls test/fixtures/c/*.c | wc -l) baselines ==="
