#!/usr/bin/env bash
# Pod Security Admission: is the namespace protected, and would our workloads pass 'restricted'?
set -uo pipefail
. "$(dirname "$0")/lib.sh"; cluster_ok
T=sec-psa
trap 'kubectl delete ns $T --ignore-not-found --wait=false >/dev/null 2>&1' EXIT

section "Namespace labels"
labels="$(kubectl get ns "$NS" -o json | jq -r '.metadata.labels | to_entries[] | select(.key | startswith("pod-security.kubernetes.io/")) | "\(.key)=\(.value)"' | tr '\n' ' ')"
[ -n "$labels" ] && pass "$NS has PSA labels: $labels" || warn "$NS has no pod-security.kubernetes.io labels: privileged pods would be admitted"

section "Enforcement check in a temporary namespace ($T, enforce=restricted)"
kubectl create ns "$T" >/dev/null 2>&1
kubectl label ns "$T" pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/warn=restricted --overwrite >/dev/null
if kubectl -n "$T" apply --dry-run=server -f "$ROOT/security/policies/privileged-pod.yaml" >/dev/null 2>&1; then
  fail "a privileged, hostPID, hostPath pod was admitted under enforce=restricted"
else
  pass "privileged pod rejected under enforce=restricted"
fi

section "Would the lab workloads pass 'restricted'?"
for kind_name in deployment/api statefulset/postgres; do
  spec="$(kubectl -n "$NS" get "$kind_name" -o json | jq '{apiVersion:"v1",kind:"Pod",metadata:{name:(.metadata.name+"-psa-check")},spec:.spec.template.spec}')"
  msg="$(kubectl -n "$T" apply --dry-run=server -f - <<<"$spec" 2>&1 >/dev/null)"
  if [ -z "$msg" ]; then pass "$kind_name would pass restricted"
  else
    warn "$kind_name violates restricted:"
    sed -E 's/.*violates PodSecurity "restricted:latest": //' <<<"$msg" | tr ',' '\n' | sed 's/^ */          /' | head -8
  fi
done
info "To enforce for real: kubectl label ns $NS pod-security.kubernetes.io/enforce=baseline pod-security.kubernetes.io/warn=restricted"

summary
