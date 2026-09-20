#!/usr/bin/env bash
# Install OPA Gatekeeper from its pinned release manifest, then apply the lab's policy:
# ConstraintTemplates (policy/templates/) and the Constraints that instantiate them
# (policy/constraints/). Re-runnable. Uninstall: scripts/gatekeeper.sh uninstall
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$ROOT/kubeconfig}"
GATEKEEPER_VERSION="${GATEKEEPER_VERSION:-v3.23.1}"
MANIFEST="https://raw.githubusercontent.com/open-policy-agent/gatekeeper/${GATEKEEPER_VERSION}/deploy/gatekeeper.yaml"

if [ "${1:-}" = "uninstall" ]; then
  kubectl delete -f "$ROOT/policy/constraints/" --ignore-not-found
  kubectl delete -f "$ROOT/policy/templates/" --ignore-not-found
  kubectl delete -f "$MANIFEST" --ignore-not-found
  exit 0
fi

echo "==> Gatekeeper ${GATEKEEPER_VERSION}"
# The release manifest runs 3 controller replicas at 512Mi each; a 2 GB lab worker cannot
# host that next to the app, and one replica is plenty here. Patch the manifest rather
# than scaling afterwards, so the applied (and last-applied) state says 1: a stray
# `kubectl scale --replicas=3` is then undone by the next `make policy`, and the three
# pods never exist even for a moment on a fresh install.
GK_MANIFEST="$(mktemp)"
curl -fsSL "$MANIFEST" | sed 's/^  replicas: 3$/  replicas: 1/' >"$GK_MANIFEST"
[ "$(grep -c '^  replicas: 1$' "$GK_MANIFEST")" -ge 2 ] \
  || { echo "ERROR: could not set the controller replicas in the Gatekeeper manifest; upstream format changed" >&2; exit 1; }
kubectl apply -f "$GK_MANIFEST"
rm -f "$GK_MANIFEST"
kubectl -n gatekeeper-system scale deploy gatekeeper-controller-manager --replicas=1
kubectl -n gatekeeper-system rollout status deploy/gatekeeper-controller-manager --timeout=300s
kubectl -n gatekeeper-system rollout status deploy/gatekeeper-audit --timeout=300s

echo "==> ConstraintTemplates"
kubectl apply -f "$ROOT/policy/templates/"
# Each template becomes a CRD; constraints cannot be created until those exist.
for kind in $(kubectl get constrainttemplates -o jsonpath='{.items[*].spec.crd.spec.names.kind}'); do
  crd="$(tr '[:upper:]' '[:lower:]' <<<"$kind").constraints.gatekeeper.sh"
  for _ in $(seq 1 30); do kubectl get crd "$crd" >/dev/null 2>&1 && break; sleep 2; done
  kubectl wait --for=condition=Established "crd/$crd" --timeout=60s >/dev/null
done

echo "==> Constraints"
kubectl apply -f "$ROOT/policy/constraints/"
kubectl get constraints
echo "Policy active for namespaces devapp and sec-*. Audit runs every 60 s: kubectl get constraints -o wide"
