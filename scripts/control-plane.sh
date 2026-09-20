#!/usr/bin/env bash
set -euo pipefail

# Idempotent: `vagrant provision` / `vagrant up --provision` re-run this script on an
# existing VM. kubeadm init refuses to run on an initialized node (ports in use,
# manifests present, /var/lib/etcd not empty), so skip it and only refresh the
# artifacts below.
if [ -f /etc/kubernetes/admin.conf ]; then
  echo "Control plane already initialized; skipping kubeadm init"
else
  kubeadm init \
    --apiserver-advertise-address="${NODE_IP}" \
    --pod-network-cidr="${POD_CIDR}" \
    --node-name="$(hostname)"
fi

# kubectl for root + vagrant user, and a copy on the host via synced folder
for home in /root /home/vagrant; do
  mkdir -p "$home/.kube"
  cp /etc/kubernetes/admin.conf "$home/.kube/config"
done
chown -R vagrant:vagrant /home/vagrant/.kube
cp /etc/kubernetes/admin.conf /vagrant/kubeconfig
export KUBECONFIG=/etc/kubernetes/admin.conf

# On a re-run right after boot the API server may still be coming up
for _ in $(seq 1 60); do
  kubectl get --raw=/healthz >/dev/null 2>&1 && break
  echo "Waiting for API server..."; sleep 5
done

# CNI: Flannel, pinned to the private-network interface (the one that owns NODE_IP;
# eth1 on bento/ubuntu-26.04, which boots with net.ifnames=0). Every node uses the same
# box, so the name is cluster-wide.
# kubectl apply is idempotent, so re-running is safe.
IFACE="$(ip -o -4 addr show | awk -v ip="${NODE_IP}" '$4 ~ "^"ip"/" {print $2; exit}')"
IFACE="${IFACE:-eth1}"
echo "Pinning Flannel to interface ${IFACE}"
# The manifest is fetched from a release tag (FLANNEL_VERSION, set in the Vagrantfile), not
# master, so a fresh clone gets the same CNI as the last one. Upstream has used both a
# JSON-style args list ("--kube-subnet-mgr") and a YAML block list (- --kube-subnet-mgr);
# handle both, then refuse to apply if neither matched. Without --iface Flannel advertises
# the NAT address 10.0.2.15 for every node and cross-node pod traffic (including DNS)
# silently fails.
FLANNEL_VERSION="${FLANNEL_VERSION:-v0.28.9}"
echo "Applying Flannel ${FLANNEL_VERSION}"
FLANNEL_MANIFEST="$(mktemp)"
curl -fsSL "https://raw.githubusercontent.com/flannel-io/flannel/${FLANNEL_VERSION}/Documentation/kube-flannel.yml" \
  | sed -e "s|\"--kube-subnet-mgr\"|\"--kube-subnet-mgr\", \"--iface=${IFACE}\"|" \
        -e "s|^\(\s*\)- --kube-subnet-mgr\$|&\n\1- --iface=${IFACE}|" \
  >"${FLANNEL_MANIFEST}"
grep -q -- "--iface=${IFACE}" "${FLANNEL_MANIFEST}" \
  || { echo "ERROR: failed to inject --iface into the Flannel manifest; upstream format changed" >&2; exit 1; }
kubectl apply -f "${FLANNEL_MANIFEST}"
rm -f "${FLANNEL_MANIFEST}"

# Join command for workers (a fresh token each run; bootstrap tokens expire after 24h)
# "$@" lets worker.sh append flags such as --node-name
printf '%s "$@"\n' "$(kubeadm token create --print-join-command)" >/vagrant/join.sh
chmod +x /vagrant/join.sh
echo "Control plane ready. Join script written to /vagrant/join.sh"
