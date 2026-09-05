#!/usr/bin/env bash
# Run every routine (or one: ./run-all.sh 04). SKIP_SLOW=1 skips kube-bench and Trivy.
set -uo pipefail
cd "$(dirname "$0")"
sel="${1:-}"
results=()
for f in [0-9][0-9]-*.sh; do
  [ -n "$sel" ] && [[ "$f" != "$sel"* ]] && continue
  if [ "${SKIP_SLOW:-0}" = "1" ] && [[ "$f" == 06-* || "$f" == 08-* ]]; then results+=("skipped  $f"); continue; fi
  printf '\n\033[1;34m######## %s ########\033[0m\n' "$f"
  bash "$f"; rc=$?
  results+=("$([ $rc -eq 0 ] && echo 'ok      ' || echo "FAIL($rc) ") $f")
done
printf '\n\033[1m######## Summary ########\033[0m\n'
printf '  %s\n' "${results[@]}"
