#!/usr/bin/env bash
# Unit-test the Gatekeeper policy in policy/ with `gator verify` (make policy-test).
# Needs no cluster. Uses a local `gator` binary if there is one, otherwise the
# openpolicyagent/gator image via Docker (pinned to GATEKEEPER_VERSION).
#
# gator takes exactly one object per file, so the lab's own workloads are extracted from
# the multi-document manifests in k8s/ into policy/tests/fixtures/lab/ (git-ignored,
# regenerated every run) and tested next to the hand-written fixtures.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATOR_VERSION="${GATEKEEPER_VERSION:-v3.23.1}"
SUITE="policy/tests/suite.yaml"
LAB="$ROOT/policy/tests/fixtures/lab"

# extract <file> <kind>: print the first YAML document of that kind
extract() {
  awk -v kind="$2" '
    /^---/ { if (found) exit; buf = ""; next }
    { buf = buf $0 "\n"; if ($0 == "kind: " kind) found = 1 }
    END { if (found) printf "%s", buf }' "$1"
}

rm -rf "$LAB" && mkdir -p "$LAB"
extract "$ROOT/k8s/10-postgres.yaml" StatefulSet >"$LAB/postgres-statefulset.yaml"
extract "$ROOT/k8s/20-api.yaml"      Deployment  >"$LAB/api-deployment.yaml"
extract "$ROOT/k8s/30-web.yaml"      Deployment  >"$LAB/web-deployment.yaml"
for f in "$LAB"/*.yaml; do
  [ -s "$f" ] || { echo "ERROR: could not extract the workload for $f from k8s/" >&2; exit 1; }
done

if command -v gator >/dev/null 2>&1; then
  echo "==> gator $(gator version 2>/dev/null | head -1 || echo '(local)')"
  (cd "$ROOT" && gator verify "$SUITE")
else
  command -v docker >/dev/null 2>&1 \
    || { echo "ERROR: neither gator nor docker found (brew install gator, or install Docker)" >&2; exit 1; }
  echo "==> openpolicyagent/gator:${GATOR_VERSION} (docker)"
  # Docker Desktop can only mount shared paths, and this checkout may live outside them
  # (an external drive, say), so work on a copy in the system temp dir.
  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT
  cp -R "$ROOT/policy" "$ROOT/k8s" "$WORK"/
  # mktemp -d is 0700 on Linux and the gator image runs as a non-root user
  chmod -R a+rX "$WORK"
  docker run --rm -v "$WORK":/w -w /w "openpolicyagent/gator:${GATOR_VERSION}" verify "$SUITE"
fi
