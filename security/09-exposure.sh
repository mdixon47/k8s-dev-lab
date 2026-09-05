#!/usr/bin/env bash
# From the host: which control-plane and node ports are reachable, and do they require auth?
set -uo pipefail
. "$(dirname "$0")/lib.sh"; cluster_ok

open() { nc -z -G 2 -w 2 "$1" "$2" >/dev/null 2>&1 || nc -z -w 2 "$1" "$2" >/dev/null 2>&1; }
NODES="$(kubectl get nodes -o json | jq -r '.items[] | "\(.metadata.name) \(.status.addresses[] | select(.type=="InternalIP") | .address) \(if (.metadata.labels | has("node-role.kubernetes.io/control-plane")) then "control-plane" else "worker" end)"')"

section "Port exposure on the host-only network (as an attacker on the same LAN)"
while read -r name ip role; do
  echo "$B$name ($ip, $role)$N"
  for port in 22 2379 2380 6443 10250 10255 10256 10257 10259 30080; do
    if open "$ip" "$port"; then
      case "$port" in
        22)    info "$port ssh open (Vagrant key auth)";;
        6443)  [ "$role" = control-plane ] && pass "$port API server open (TLS + RBAC)" || fail "$port open on a worker?";;
        2379|2380) warn "$port etcd reachable from the LAN (client cert required, but firewall it: etcd holds every Secret)";;
        10250) info "$port kubelet API reachable; auth checked below";;
        10255) fail "$port kubelet read-only port open: unauthenticated pod/spec dump";;
        10257|10259) warn "$port controller-manager/scheduler reachable (kubeadm binds them to 0.0.0.0; bind to 127.0.0.1)";;
        10256) info "$port kube-proxy healthz";;
        30080) info "$port NodePort api (intended)";;
      esac
    fi
  done
done <<<"$NODES"

section "Authentication on exposed endpoints"
CP="$(awk '$3=="control-plane"{print $2}' <<<"$NODES" | head -1)"
W="$(awk '$3=="worker"{print $2}' <<<"$NODES" | head -1)"
c="$(curl -sk -o /dev/null -w '%{http_code}' "https://$W:10250/pods" --max-time 5)"
case "$c" in 401|403) pass "kubelet /pods on $W requires auth (HTTP $c)";; 200) fail "kubelet /pods on $W is anonymous (HTTP 200)";; *) info "kubelet /pods returned $c";; esac
c="$(curl -sk -o /dev/null -w '%{http_code}' "https://$CP:6443/api/v1/secrets" --max-time 5)"
[ "$c" = "403" ] || [ "$c" = "401" ] && pass "API server rejects anonymous secret listing (HTTP $c)" || fail "anonymous secret listing returned HTTP $c"
c="$(curl -sk -o /dev/null -w '%{http_code}' "https://$CP:6443/version" --max-time 5)"
[ "$c" = "200" ] && info "/version is readable anonymously (default; reveals the exact Kubernetes version)"
c="$(curl -s -o /dev/null -w '%{http_code}' "http://$W:30080/docs" --max-time 5)"
[ "$c" = "200" ] && warn "Swagger UI (/docs) is exposed on the NodePort without auth; disable docs_url in prod"

summary
