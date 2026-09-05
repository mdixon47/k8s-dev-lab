#!/usr/bin/env bash
# Can a pod in an unrelated namespace reach the database? And does a NetworkPolicy stop it?
set -uo pipefail
. "$(dirname "$0")/lib.sh"; cluster_ok
PROBE_NS=sec-probe
cleanup() { kubectl delete ns "$PROBE_NS" --ignore-not-found --wait=false >/dev/null 2>&1; kubectl -n "$NS" delete networkpolicy postgres-only-from-api --ignore-not-found >/dev/null 2>&1; }
trap cleanup EXIT

section "CNI and existing policies"
cni="$(kubectl get pods -A -o name | grep -oE 'calico|cilium|weave|flannel|antrea' | sort -u | tr '\n' ' ')"
info "CNI detected: ${cni:-unknown}"
n="$(kubectl -n "$NS" get networkpolicies -o name | wc -l | tr -d ' ')"
[ "$n" -gt 0 ] && pass "$n NetworkPolicy object(s) in $NS" || warn "no NetworkPolicy in $NS: every pod in the cluster can reach postgres:5432"

section "Cross-namespace reachability from $PROBE_NS"
kubectl create ns "$PROBE_NS" >/dev/null 2>&1
kubectl -n "$PROBE_NS" run probe --image=python:3.12-alpine --restart=Never --command -- sleep 600 >/dev/null
kubectl -n "$PROBE_NS" wait --for=condition=Ready pod/probe --timeout=90s >/dev/null || { fail "probe pod did not start"; summary; exit; }
reach() { kubectl -n "$PROBE_NS" exec probe -- python3 -c "import socket; socket.create_connection(('$1',$2),3)" >/dev/null 2>&1; }
pg="postgres.$NS.svc.cluster.local"; api="api.$NS.svc.cluster.local"
reach "$pg" 5432 && warn "postgres:5432 reachable from another namespace (no policy)" || pass "postgres:5432 unreachable from another namespace"
reach "$api" 8000 && info "api:8000 reachable from another namespace (expected for a service meant to be called)"

section "Does a deny policy take effect?"
kubectl apply -f "$ROOT/security/policies/netpol-postgres-only-from-api.yaml" >/dev/null
sleep 5
if reach "$pg" 5432; then
  fail "postgres still reachable with a NetworkPolicy applied: the CNI (${cni:-?}) does not enforce policies"
  info "Fix: replace Flannel with Calico or Cilium (see docs/learn.md, 'Where to go next'). The policy YAML is in security/policies/."
else
  pass "NetworkPolicy enforced: postgres unreachable from $PROBE_NS"
  APIPOD="$(kubectl -n "$NS" get pods -l app=api -o jsonpath='{.items[0].metadata.name}')"
  kubectl -n "$NS" exec "$APIPOD" -- python3 -c 'import socket; socket.create_connection(("postgres",5432),3)' >/dev/null 2>&1 && pass "api pods still allowed through" || fail "policy also blocked the api pods"
fi

summary
