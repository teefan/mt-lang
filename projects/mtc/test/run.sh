#!/bin/bash
set -euo pipefail
MTC="${MTC:-./build/bin/linux/debug/mtc}"
FIXTURES="test/fixtures"
PASS=0
FAIL=0

echo "=== Self-Hosted Compiler Test Suite ==="
echo ""

for f in "$FIXTURES"/*.mt; do
    name="$(basename "$f" .mt)"
    c_out="$(mktemp /tmp/mtc_XXXXXX.c)"
    bin_out="$(mktemp /tmp/mtc_XXXXXX)"
    
    if ! "$MTC" build "$f" > "$c_out" 2>/dev/null; then
        echo "FAIL $name — compiler error"
        FAIL=$((FAIL + 1))
        rm -f "$c_out" "$bin_out"
        continue
    fi
    
    if ! gcc "$c_out" -o "$bin_out" -w 2>/dev/null; then
        echo "FAIL $name — gcc error"
        FAIL=$((FAIL + 1))
        rm -f "$c_out" "$bin_out"
        continue
    fi
    
    set +e
    "$bin_out" >/dev/null 2>&1
    actual=$?
    set -e
    
    rm -f "$c_out" "$bin_out"
    
    echo "OK   $name — exit $actual"
    PASS=$((PASS + 1))
done

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
