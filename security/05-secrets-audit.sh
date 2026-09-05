#!/usr/bin/env bash
# Where do the database credentials live, and who can read them?
set -uo pipefail
. "$(dirname "$0")/lib.sh"; cluster_ok

section "Secrets in $NS"
for s in $(kubectl -n "$NS" get secrets -o name); do
  keys="$(kubectl -n "$NS" get "$s" -o json | jq -r '.data | keys | join(", ")')"
  info "$s keys: $keys (base64 only; kubectl get -o json shows them to anyone with 'get secrets')"
done

section "Encryption at rest"
if kubectl -n kube-system get pod -l component=kube-apiserver -o json | jq -e '.items[0].spec.containers[0].command | map(select(test("encryption-provider-config"))) | length > 0' >/dev/null; then
  pass "kube-apiserver has --encryption-provider-config"
else
  fail "no --encryption-provider-config on kube-apiserver: Secrets are stored in etcd as plaintext"
fi
ETCD="$(kubectl -n kube-system get pods -l component=etcd -o jsonpath='{.items[0].metadata.name}')"
raw="$(kubectl -n kube-system exec "$ETCD" -- sh -c 'ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key get /registry/secrets/'"$NS"'/postgres-credentials' 2>/dev/null | LC_ALL=C tr -c '[:print:]\n' '.')"
pw="$(kubectl -n "$NS" get secret postgres-credentials -o jsonpath='{.data.POSTGRES_PASSWORD}' 2>/dev/null | base64 -d)"
if [ -n "$pw" ] && grep -q -- "$pw" <<<"$raw"; then
  fail "the Postgres password is readable verbatim from etcd (anyone with the etcd certs or a disk image of cp1 has it)"
else
  [ -n "$raw" ] && pass "password not found in plaintext in etcd" || skip "could not read etcd (etcdctl missing?)"
fi

section "Where else the credentials appear"
grep -nE '^\s*(POSTGRES_PASSWORD|password)\s*:' "$ROOT"/k8s/*.yaml >/dev/null 2>&1 && warn "plaintext credentials committed in k8s/10-postgres.yaml (dev-only by design; use SealedSecrets/ExternalSecrets for anything shared)"
kubectl -n "$NS" get deploy api -o json | jq -e '.spec.template.spec.containers[].env[]? | select(.value != null) | select(.value | test("://.*:.*@"))' >/dev/null && fail "DATABASE_URL embeds the password as a literal in the Deployment spec (visible via get/describe/audit log); use a secretKeyRef" || pass "no connection strings with embedded credentials in the Deployment"
perm="$(stat -f '%Lp' "$KUBECONFIG" 2>/dev/null || stat -c '%a' "$KUBECONFIG")"
[ "$perm" = "600" ] && pass "kubeconfig is mode 600" || warn "kubeconfig is mode $perm; it is a cluster-admin credential: chmod 600 $KUBECONFIG"
git -C "$ROOT" check-ignore -q kubeconfig && pass "kubeconfig is git-ignored" || fail "kubeconfig is NOT git-ignored"

summary
