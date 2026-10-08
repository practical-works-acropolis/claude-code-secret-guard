#!/usr/bin/env bash
# Runs every test case against the hook and exits non-zero on any mismatch.
#
# usage: tests/run.sh [HOOK] [CASES_FILE...]
#   HOOK defaults to hooks/block-secret-print.sh
#   CASES_FILE defaults to every tests/cases/*.txt
#
# Case format, one per line:  EXPECTED_EXIT|MODE|COMMAND
#   EXPECTED_EXIT  0 = allow, 2 = block
#   MODE           jq   = run with your normal PATH (jq or python3 if present)
#                  nojq = run with a PATH holding only cat, tr, sed and grep,
#                         to test the plain-text JSON fallback
#
# Set FORCE_NOJQ=1 to run EVERY case in nojq mode (no jq, no python3).
#
# JSON is built in pure bash, so the runner itself needs no jq or python.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"

HOOK="${1:-$root/hooks/block-secret-print.sh}"
[ $# -gt 0 ] && shift
if [ $# -eq 0 ]; then
  set -- "$here"/cases/*.txt
fi

[ -f "$HOOK" ] || { echo "hook not found: $HOOK" >&2; exit 1; }

fail=0; n=0
MIN="$(mktemp -d)"
trap 'rm -rf "$MIN"' EXIT
for t in cat tr sed grep; do ln -s "$(command -v "$t")" "$MIN/$t"; done

enc() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "$s"; }

for f in "$@"; do
  while IFS='|' read -r exp mode c; do
    [ -z "$exp" ] && continue
    n=$((n+1))
    payload="{\"session_id\":\"t\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$(enc "$c")\"}}"
    if [ "$mode" = nojq ] || [ "${FORCE_NOJQ:-0}" = 1 ]; then
      printf '%s' "$payload" | PATH="$MIN" "$BASH" "$HOOK" >/dev/null 2>&1; rc=$?
    else
      printf '%s' "$payload" | bash "$HOOK" >/dev/null 2>&1; rc=$?
    fi
    v=ok; [ "$rc" = "$exp" ] || { v=MISS; fail=$((fail+1)); }
    [ "${FORCE_NOJQ:-0}" = 1 ] && mode=nojq
    printf '%-4s got=%s want=%s [%s] %s\n' "$v" "$rc" "$exp" "$mode" "$c"
  done < "$f"
done

echo "total=$n mismatches=$fail"
[ "$n" -gt 0 ] || { echo "no test cases found" >&2; exit 1; }
[ "$fail" -eq 0 ]
