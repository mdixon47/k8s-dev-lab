#!/usr/bin/env bash
# Shared helpers for the security routines. Source this; do not run it.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$ROOT/kubeconfig}"
NS="${NS:-devapp}"
PASS=0; FAIL=0; WARN=0; SKIP=0

if [ -t 1 ]; then G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; C=$'\033[36m'; B=$'\033[1m'; N=$'\033[0m'
else G=""; R=""; Y=""; C=""; B=""; N=""; fi

pass()    { PASS=$((PASS+1)); printf '  %sPASS%s  %s\n' "$G" "$N" "$*"; }
fail()    { FAIL=$((FAIL+1)); printf '  %sFAIL%s  %s\n' "$R" "$N" "$*"; }
warn()    { WARN=$((WARN+1)); printf '  %sWARN%s  %s\n' "$Y" "$N" "$*"; }
skip()    { SKIP=$((SKIP+1)); printf '  %sSKIP%s  %s\n' "$C" "$N" "$*"; }
info()    { printf '        %s\n' "$*"; }
section() { printf '\n%s== %s ==%s\n' "$B" "$*" "$N"; }
need()    { command -v "$1" >/dev/null 2>&1 || { skip "$1 not installed ($2)"; return 1; }; }

# Prints the summary line and exits non-zero if anything failed.
summary() {
  printf '\n%s%s%s: %d pass, %d fail, %d warn, %d skip\n' "$B" "$(basename "$0")" "$N" "$PASS" "$FAIL" "$WARN" "$SKIP"
  [ "$FAIL" -eq 0 ]
}

cluster_ok() {
  kubectl get --raw=/healthz >/dev/null 2>&1 || { echo "Cluster not reachable via $KUBECONFIG" >&2; exit 2; }
}
