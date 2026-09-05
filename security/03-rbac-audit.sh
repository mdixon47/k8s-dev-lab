#!/usr/bin/env bash
# Who can do what: the app's service account, anonymous users, and cluster-admin bindings.
set -uo pipefail
. "$(dirname "$0")/lib.sh"; cluster_ok

section "Service account permissions (system:serviceaccount:$NS:default)"
SA="system:serviceaccount:$NS:default"
for verb_res in "get secrets" "list secrets" "create pods" "get pods" "create pods/exec" "list nodes"; do
  set -- $verb_res
  if [ "$(kubectl auth can-i "$1" "$2" -n "$NS" --as="$SA" 2>/dev/null)" = "yes" ]; then fail "$SA can $1 $2"; else pass "$SA cannot $1 $2"; fi
done
info "full list: kubectl auth can-i --list -n $NS --as=$SA"

section "Anonymous and unauthenticated access"
[ "$(kubectl auth can-i get pods --as=system:anonymous 2>/dev/null)" = "yes" ] && fail "anonymous can get pods" || pass "anonymous cannot get pods"
[ "$(kubectl auth can-i get secrets -A --as=system:anonymous 2>/dev/null)" = "yes" ] && fail "anonymous can get secrets" || pass "anonymous cannot get secrets"
extra="$(kubectl get clusterrolebindings -o json | jq -r '.items[] | select(.subjects[]? | .name=="system:unauthenticated" or .name=="system:anonymous") | .metadata.name' | grep -vE '^system:public-info-viewer$' | tr '\n' ' ')"
[ -n "$extra" ] && fail "unexpected bindings for unauthenticated users: $extra" || pass "only the default public-info-viewer binding for unauthenticated users"

section "cluster-admin bindings"
kubectl get clusterrolebindings -o json | jq -r '.items[] | select(.roleRef.name=="cluster-admin") | "  \(.metadata.name)\t-> \([.subjects[]? | "\(.kind):\(.name)"] | join(", "))"' | column -t -s $'\t'
nonsys="$(kubectl get clusterrolebindings -o json | jq -r '.items[] | select(.roleRef.name=="cluster-admin") | select(.metadata.name != "cluster-admin" and .metadata.name != "kubeadm:cluster-admins") | .metadata.name' | tr '\n' ' ')"
[ -n "$nonsys" ] && warn "cluster-admin granted beyond the bootstrap bindings: $nonsys" || pass "cluster-admin only via the kubeadm bootstrap bindings (system:masters, kubeadm:cluster-admins)"
info "The kubeconfig in this repo IS system:masters. Anyone who copies the file owns the cluster."

section "Service accounts with elevated roles"
kubectl get rolebindings,clusterrolebindings -A -o json | jq -r '.items[] | select(.subjects[]? | .kind=="ServiceAccount") | select(.roleRef.name | test("admin|edit|cluster-admin")) | "  \(.metadata.namespace // "cluster")/\(.metadata.name)\t\(.roleRef.name)\t\([.subjects[] | select(.kind=="ServiceAccount") | "\(.namespace)/\(.name)"] | join(","))"' | column -t -s $'\t'
info "Expected: local-path-provisioner and system controllers only."

summary
