#!/usr/bin/env bash
# OPA Gatekeeper: is admission policy installed, does it really reject a bad pod, and what
# does its audit say about the workloads that were already running?
set -uo pipefail
. "$(dirname "$0")/lib.sh"; cluster_ok
T=sec-gk
trap 'kubectl delete ns $T --ignore-not-found --wait=false >/dev/null 2>&1' EXIT

section "Installation"
if ! kubectl get ns gatekeeper-system >/dev/null 2>&1; then
  skip "Gatekeeper not installed (make policy); without an admission controller nothing enforces the lab's security posture"
  summary; exit
fi
ready="$(kubectl -n gatekeeper-system get deploy gatekeeper-controller-manager -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
[ "${ready:-0}" -ge 1 ] && pass "controller-manager ready (${ready} replica)" || fail "controller-manager has no ready replica: the webhook cannot answer"
audit="$(kubectl -n gatekeeper-system get deploy gatekeeper-audit -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
[ "${audit:-0}" -ge 1 ] && pass "audit ready" || warn "audit not ready: existing violations will not be reported"
fp="$(kubectl get validatingwebhookconfiguration gatekeeper-validating-webhook-configuration -o jsonpath='{.webhooks[?(@.name=="validation.gatekeeper.sh")].failurePolicy}' 2>/dev/null)"
case "$fp" in
  Fail)   pass "webhook failurePolicy=Fail" ;;
  Ignore) warn "webhook failurePolicy=Ignore: if Gatekeeper is down, every request is admitted unchecked (the upstream default; Fail is safer but can lock you out)" ;;
  *)      fail "validating webhook not found" ;;
esac

section "Templates and constraints"
for kind in K8sLabNoPrivilege K8sLabNonRoot K8sLabResourceLimits; do
  crd="$(tr '[:upper:]' '[:lower:]' <<<"$kind").constraints.gatekeeper.sh"
  if ! kubectl get crd "$crd" >/dev/null 2>&1; then fail "template $kind not installed"; continue; fi
  names="$(kubectl get "$kind" -o jsonpath='{range .items[*]}{.metadata.name}={.spec.enforcementAction}{" "}{end}' 2>/dev/null)"
  [ -n "$names" ] && pass "$kind: $names" || fail "$kind has no constraint: the template is inert"
done

section "Enforcement in a temporary namespace ($T, matched by the sec-* scope)"
kubectl create ns "$T" >/dev/null 2>&1
sleep 2
msg="$(kubectl -n "$T" apply --dry-run=server -f "$ROOT/security/policies/privileged-pod.yaml" 2>&1 >/dev/null)"
if [ -z "$msg" ]; then
  fail "privileged, hostPID, hostPath pod was admitted"
elif grep -q "no-privilege" <<<"$msg"; then
  pass "privileged pod denied by constraint no-privilege"
  grep -oE '\] [^:]*:.*' <<<"$msg" | sed 's/^\] /          /' | head -5
else
  fail "privileged pod rejected, but not by Gatekeeper: $msg"
fi
# warn-mode constraints: the request is admitted, the client is told why it should not be
spec="$(kubectl -n "$NS" get statefulset postgres -o json 2>/dev/null | jq '{apiVersion:"v1",kind:"Pod",metadata:{name:"postgres-gk-check"},spec:.spec.template.spec}')"
if [ -n "$spec" ] && [ "$spec" != "null" ]; then
  out="$(kubectl -n "$T" apply --dry-run=server -f - <<<"$spec" 2>&1)"
  if grep -q "^Warning:" <<<"$out"; then
    pass "postgres pod spec admitted with warnings (enforcementAction: warn)"
    grep "^Warning:" <<<"$out" | sed 's/^Warning: \[[^]]*\] /          /' | head -6
  elif grep -q "denied" <<<"$out"; then
    warn "postgres pod spec denied: a constraint was switched to deny; make deploy will fail until k8s/10-postgres.yaml complies"
  else
    warn "postgres pod spec admitted with no warning: non-root / limits constraints not active?"
  fi
fi
good="$(kubectl -n "$NS" get deploy web -o json 2>/dev/null | jq '{apiVersion:"v1",kind:"Pod",metadata:{name:"web-gk-check"},spec:.spec.template.spec}')"
if [ -n "$good" ] && [ "$good" != "null" ]; then
  out="$(kubectl -n "$T" apply --dry-run=server -f - <<<"$good" 2>&1)"
  grep -qE "denied|^Warning:" <<<"$out" && fail "the hardened web pod spec was flagged: $out" || pass "hardened web pod spec admitted cleanly"
fi

section "Audit: violations among workloads already running (refreshes every 60 s)"
total=0
for c in $(kubectl get constraints -o jsonpath='{range .items[*]}{.kind}/{.metadata.name}{"\n"}{end}' 2>/dev/null); do
  n="$(kubectl get "$c" -o jsonpath='{.status.totalViolations}' 2>/dev/null)"; n="${n:-0}"; total=$((total+n))
  if [ "$n" -eq 0 ]; then pass "$c: 0 violations"
  else
    warn "$c: $n violation(s)"
    kubectl get "$c" -o json | jq -r '.status.violations[]? | "          \(.namespace)/\(.kind)/\(.name): \(.message)"' | head -6
  fi
done
[ "$total" -gt 0 ] && info "Admission only judges new requests; audit is how you find what was already there. Fix k8s/10-postgres.yaml, redeploy, and flip the warn constraints to deny."

summary
