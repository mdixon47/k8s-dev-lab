#!/usr/bin/env bash
set -euo pipefail

# Idempotent: a node that has already joined has a kubelet.conf; kubeadm join would
# fail its preflight checks, so skip it.
if [ -f /etc/kubernetes/kubelet.conf ]; then
  echo "Worker already joined; skipping kubeadm join"
  exit 0
fi

for i in $(seq 1 30); do
  [ -f /vagrant/join.sh ] && break
  echo "Waiting for join.sh..."; sleep 10
done
bash /vagrant/join.sh --node-name="$(hostname)"
