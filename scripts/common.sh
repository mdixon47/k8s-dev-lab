#!/usr/bin/env bash
# Runs on every node: containerd + kubeadm/kubelet/kubectl
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Kernel prerequisites
cat >/etc/modules-load.d/k8s.conf <<'M'
overlay
br_netfilter
M
modprobe overlay && modprobe br_netfilter
cat >/etc/sysctl.d/k8s.conf <<'S'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
S
sysctl --system >/dev/null

# Text console: keep kernel/cloud-init chatter off the login prompt and print the lab
# credentials in the banner (dev-only box; the vagrant user is passwordless sudo anyway).
echo "kernel.printk = 3 4 1 3" >/etc/sysctl.d/k8s-console.conf
sysctl -q -p /etc/sysctl.d/k8s-console.conf
cat >/etc/issue <<'I'
\n (\l)  k8s-dev-lab node
Login: vagrant   Password: vagrant   (sudo needs no password)
Press Enter if this prompt is buried under boot messages.

I
# fstab is tab-separated; match any whitespace, and don't double-comment on re-runs
swapoff -a && sed -i -E '/[[:space:]]swap[[:space:]]/ s/^([^#])/#\1/' /etc/fstab

# containerd
apt-get update -q
apt-get install -y -q apt-transport-https ca-certificates curl gpg containerd
mkdir -p /etc/containerd
containerd config default >/etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd && systemctl enable containerd

# Kubernetes packages
mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" \
  | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" \
  >/etc/apt/sources.list.d/kubernetes.list
apt-get update -q
apt-get install -y -q kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

# VirtualBox NAT gives every VM the same eth0 IP; pin kubelet to the private-network IP
echo "KUBELET_EXTRA_ARGS=--node-ip=${NODE_IP}" >/etc/default/kubelet
systemctl enable kubelet
