#!/usr/bin/env bash
# Static checks for the repo (make check). No cluster and no VMs needed.
#   - every shell script through ShellCheck
#   - manifests, policy and fixtures through yamllint (.yamllint in the repo root sets the rules)
#   - k8s/ and friends through kubeconform against the Kubernetes API schema (unknown CRD kinds skipped)
#   - every relative link in the Markdown files points at a file that exists
# Missing ShellCheck or yamllint is reported as SKIP (install both with Homebrew);
# kubeconform falls back to its Docker image.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
KUBECONFORM_VERSION="${KUBECONFORM_VERSION:-v0.8.0}"
rc=0
step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
fail() { echo "FAIL: $*" >&2; rc=1; }
skip() { echo "SKIP: $*" >&2; }

step "shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
  # shellcheck disable=SC2046
  shellcheck -S warning $(find scripts security -name '*.sh') || fail "shellcheck"
else
  skip "shellcheck not installed (brew install shellcheck)"
fi

step "yamllint"
if command -v yamllint >/dev/null 2>&1; then
  yamllint -s k8s policy security/policies || fail "yamllint"
else
  skip "yamllint not installed (brew install yamllint)"
fi

step "kubeconform"
kc_args=(-strict -summary -ignore-missing-schemas)
if command -v kubeconform >/dev/null 2>&1; then
  kubeconform "${kc_args[@]}" k8s policy/examples policy/tests/fixtures security/policies || fail "kubeconform"
elif command -v docker >/dev/null 2>&1; then
  # Docker Desktop mounts shared paths only; this checkout may sit outside them
  WORK="$(mktemp -d)"
  cp -R k8s policy security "$WORK"/
  chmod -R a+rX "$WORK"   # mktemp -d is 0700 on Linux; the image may run as non-root
  docker run --rm -v "$WORK":/w -w /w "ghcr.io/yannh/kubeconform:${KUBECONFORM_VERSION}" \
    "${kc_args[@]}" k8s policy/examples policy/tests/fixtures security/policies || fail "kubeconform"
  rm -rf "$WORK"
else
  skip "neither kubeconform nor docker found"
fi

step "markdown links"
broken=0
while IFS= read -r file; do
  dir="$(dirname "$file")"
  # [text](target) with a relative target; strip any #fragment
  while IFS= read -r target; do
    target="${target%%#*}"
    [ -z "$target" ] && continue
    [ -e "$dir/$target" ] || { echo "$file -> $target (missing)"; broken=1; }
  done < <(grep -oE '\]\([^)]+\)' "$file" | sed -E 's/^\]\((.*)\)$/\1/' | grep -vE '^(https?:|mailto:|#)')
done < <(find . -name '*.md' -not -path './.git/*' -not -path './.vagrant/*')
[ "$broken" -eq 0 ] && echo "all relative links resolve" || fail "markdown links"

echo
[ "$rc" -eq 0 ] && echo "check: OK" || echo "check: FAILED"
exit "$rc"
