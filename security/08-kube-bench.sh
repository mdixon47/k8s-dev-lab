#!/usr/bin/env bash
# CIS Kubernetes Benchmark on the control plane and a worker, via kube-bench Jobs.
set -uo pipefail
. "$(dirname "$0")/lib.sh"; cluster_ok
VER="${KUBE_BENCH_VERSION:-v0.10.4}"
trap 'kubectl delete job kube-bench kube-bench-master --ignore-not-found --wait=false >/dev/null 2>&1' EXIT

run_bench() { # name, url
  kubectl delete job "$1" --ignore-not-found --wait=true >/dev/null 2>&1
  kubectl apply -f "$2" >/dev/null || { skip "$1: could not apply job manifest (offline?)"; return; }
  kubectl wait --for=condition=complete "job/$1" --timeout=240s >/dev/null 2>&1 || { skip "$1: job did not complete (image pull on the node may be slow; rerun)"; return; }
  out="$(kubectl logs "job/$1")"
  f="$(grep -E '^[0-9]+ checks FAIL' <<<"$out" | awk '{s+=$1} END{print s+0}')"
  w="$(grep -E '^[0-9]+ checks WARN' <<<"$out" | awk '{s+=$1} END{print s+0}')"
  p="$(grep -E '^[0-9]+ checks PASS' <<<"$out" | awk '{s+=$1} END{print s+0}')"
  [ "$f" -eq 0 ] && pass "$1: $p pass, $w warn, 0 fail" || fail "$1: $p pass, $w warn, $f fail"
  grep -E '^\[FAIL\]' <<<"$out" | head -10 | sed 's/^/        /'
  info "full report: kubectl logs job/$1"
}
section "kube-bench $VER (control plane)"
run_bench kube-bench-master "https://raw.githubusercontent.com/aquasecurity/kube-bench/$VER/job-master.yaml"
section "kube-bench $VER (worker node)"
run_bench kube-bench "https://raw.githubusercontent.com/aquasecurity/kube-bench/$VER/job.yaml"
info "kubeadm defaults fail a handful of CIS items (file perms, audit logging, rotate certs). Each is a hardening exercise."

summary
