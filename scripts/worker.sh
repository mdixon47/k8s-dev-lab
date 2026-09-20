#!/usr/bin/env bash
set -euo pipefail

# Idempotent: a node that has already joined has a kubelet.conf; kubeadm join would
# fail its preflight checks, so skip it.
if [ -f /etc/kubernetes/kubelet.conf ]; then
  echo "Worker already joined; skipping kubeadm join"
  exit 0
fi

for _ in $(seq 1 30); do
  [ -f /vagrant/join.sh ] && break
  echo "Waiting for join.sh..."; sleep 10
done
[ -f /vagrant/join.sh ] || { echo "ERROR: /vagrant/join.sh never appeared; provision cp1 first" >&2; exit 1; }

# join.sh is "kubeadm join <cp-ip>:6443 --token ..."; wait for that API server to answer
# before joining. kubeadm's own discovery gives up after 5 min, and a control plane that
# is rebooting at that moment (a "Power off" from its window, say) used to leave this
# worker out of the cluster for good, with nothing retrying.
API="$(awk '{print $3}' /vagrant/join.sh)"
for _ in $(seq 1 60); do
  curl -sk --max-time 3 "https://${API}/healthz" | grep -q ok && break
  echo "Waiting for API server ${API}..."; sleep 5
done

for attempt in 1 2 3; do
  if bash /vagrant/join.sh --node-name="$(hostname)"; then
    echo "Worker joined on attempt ${attempt}"
    exit 0
  fi
  echo "kubeadm join failed (attempt ${attempt}/3); cleaning up and retrying in 30 s" >&2
  kubeadm reset -f >/dev/null 2>&1 || true
  sleep 30
done
echo "ERROR: kubeadm join failed 3 times; re-run: vagrant provision $(hostname) --provision-with worker" >&2
exit 1
