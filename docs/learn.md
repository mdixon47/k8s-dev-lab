# Learning Guide: k8s-dev-lab

This lab exists to teach how a Kubernetes cluster is actually assembled and how a
stateful application runs on it. Nothing is hidden behind a managed service: you
watch three VMs boot, get bootstrapped into a cluster with `kubeadm`, and serve a
FastAPI + Postgres app. This guide explains *why* each piece is there and gives
exercises to try.

Read alongside [README.md](../README.md) (quick start) and [CLAUDE.md](../CLAUDE.md)
(conventions and troubleshooting).

---

## 1. The big picture

```
┌──────────────────────── host (macOS / Linux) ────────────────────────┐
│  vagrant up ──▶ VirtualBox                                           │
│  docker build ──▶ devapp/api:dev ──▶ ctr import (per worker)         │
│  kubectl (KUBECONFIG=./kubeconfig) ──▶ https://192.168.56.10:6443    │
│                                                                      │
│   ┌──────── cp1 ────────┐  ┌──────── w1 ────────┐  ┌──── w2 ────┐    │
│   │ kube-apiserver      │  │ kubelet            │  │ kubelet    │    │
│   │ etcd, scheduler,    │  │ containerd         │  │ containerd │    │
│   │ controller-manager  │  │ flannel, kube-proxy│  │ flannel    │    │
│   │ kubelet, flannel    │  │ api pod  postgres  │  │ api pod    │    │
│   └─────────────────────┘  └────────────────────┘  └────────────┘    │
│        192.168.56.10            192.168.56.11         192.168.56.12  │
└──────────────────────────────────────────────────────────────────────┘
```

Layers, bottom to top:

| Layer | Tool | Files |
|-------|------|-------|
| Virtual machines | Vagrant + VirtualBox | `Vagrantfile` |
| Node preparation | bash provisioning | `scripts/common.sh` |
| Cluster bootstrap | kubeadm | `scripts/control-plane.sh`, `scripts/worker.sh` |
| Pod networking | Flannel (CNI) | applied in `control-plane.sh` |
| Storage | local-path-provisioner | `make storage` |
| Image distribution | docker save → ctr import | `scripts/load-image.sh` |
| Application | FastAPI + Postgres | `app/`, `k8s/` |

---

## 2. Layer by layer

### 2.1 Virtual machines (`Vagrantfile`)

- `NODES` is the single source of truth for the cluster shape: name, IP, CPUs, RAM, role.
- Each VM gets **two NICs**. VirtualBox always adds a NAT adapter (internet access), and
  `private_network` adds a host-only adapter on `192.168.56.0/24` so the VMs and the host
  can reach each other by fixed IP.
- The box is chosen by host CPU architecture. `ubuntu/jammy64` is amd64-only, so Apple
  Silicon hosts get `bento/ubuntu-22.04`, which ships an arm64 VirtualBox build.
- The synced folder `/vagrant` mirrors the repo inside every VM. This is how the control
  plane hands `kubeconfig` and `join.sh` to the host and to the workers with no extra tooling.

**Concept: the NAT trap.** Every VM's NAT interface has the *same* address, 10.0.2.15.
If kubelet or Flannel picks that interface, nodes cannot talk to each other. The lab
pins both to the host-only IP. This is the most common reason DIY clusters "look
healthy but pods can't reach each other".

### 2.2 Node preparation (`scripts/common.sh`)

Runs identically on all three nodes. Each block answers a kubeadm preflight check:

| Step | Why |
|------|-----|
| `overlay`, `br_netfilter` modules | containerd uses overlayfs; bridge traffic must pass through iptables for Services to work |
| `net.ipv4.ip_forward=1` | nodes route pod traffic |
| `swapoff -a` | kubelet refuses to start with swap on (memory accounting) |
| containerd with `SystemdCgroup = true` | kubelet and the runtime must agree on the cgroup driver; Ubuntu uses systemd |
| `pkgs.k8s.io` repo pinned to `v${K8S_VERSION}` | one minor version per repo; changing `K8S_VERSION` in the Vagrantfile is enough |
| `apt-mark hold` | prevents an unattended upgrade from skewing versions between nodes |
| `--node-ip=${NODE_IP}` in `/etc/default/kubelet` | the NAT trap fix for kubelet |

### 2.3 Cluster bootstrap (`scripts/control-plane.sh`, `scripts/worker.sh`)

`kubeadm init` on cp1:
1. Generates the CA and certificates.
2. Writes static-pod manifests for etcd, apiserver, scheduler, controller-manager into
   `/etc/kubernetes/manifests/`. kubelet notices them and starts them without any
   scheduler involvement. This is why the control plane can bootstrap itself.
3. Produces `admin.conf`, copied to `/vagrant/kubeconfig` for the host.

Flannel is then applied with `--iface` set to the host-only interface (resolved from
`NODE_IP`). Until a CNI is running, every node stays `NotReady`. That is expected.

Finally `kubeadm token create --print-join-command` writes `join.sh`. Workers poll for
that file (up to five minutes) and run it. Join tokens expire after 24 hours; if you add a
worker much later, regenerate one with `vagrant ssh cp1 -c "sudo kubeadm token create --print-join-command"`.

**Try it:** inside cp1, `ls /etc/kubernetes/manifests` and `kubectl -n kube-system get pods -o wide`.
Match the static pods to the files.

### 2.4 Storage (`make storage`)

Bare kubeadm clusters have **no StorageClass**, so any PVC sits `Pending` forever.
`local-path-provisioner` creates a hostPath directory on whichever node the pod lands and
binds the PVC to it. Marking it default lets the Postgres PVC omit `storageClassName`.

Consequence worth understanding: the volume lives on one node. If that node dies, the
data is gone, and the pod cannot be rescheduled elsewhere. That is fine for a lab and
exactly the reason production clusters use networked or cloud block storage.

### 2.5 Image distribution (`scripts/load-image.sh`)

There is no registry. The image is built on the host, saved to a tarball in the synced
folder, and imported straight into containerd's `k8s.io` namespace on each worker.

Two details that trip people up:
- The `k8s.io` namespace matters. `ctr images ls` with no `-n` shows a different namespace,
  and kubelet only sees images in `k8s.io`.
- The manifest uses `imagePullPolicy: IfNotPresent` with a fixed tag. Because the tag never
  changes, a Deployment update does nothing; you must `rollout restart` after each reload.

### 2.6 The application (`app/`, `k8s/`)

`app/main.py` is deliberately small so the Kubernetes behaviour is what you study:

| Endpoint | Kubernetes role |
|----------|-----------------|
| `/healthz` | liveness probe. Returns the pod's hostname so you can see load balancing across replicas |
| `/readyz` | readiness probe. Runs `SELECT 1`; returns 503 until Postgres is reachable, so traffic is withheld until the pod can serve |
| `/notes` | proves persistence: data survives API restarts because it lives in the Postgres PVC |

Manifest walk-through:

- `00-namespace.yaml`: everything lives in `devapp`. Numbered prefixes give `kubectl apply -f k8s/` a deterministic order.
- `10-postgres.yaml`: **Secret** (env injection via `envFrom`), **PVC**, **StatefulSet**
  (stable pod name `postgres-0`, ordered restarts), **ClusterIP Service** (DNS name
  `postgres.devapp.svc.cluster.local`). A StatefulSet rather than a Deployment because the
  database must never have two pods writing the same volume during a rollout.
- `20-api.yaml`: **Deployment** with 2 replicas (stateless, safe to roll), resource requests
  and limits, both probes, a non-root `securityContext`, and a **NodePort Service** on 30080.
  NodePort opens the port on *every* node, which is why `make test` can hit w1 even though
  a pod may be on w2.

---

## 3. Guided walkthrough

Do these in order on a fresh clone and observe the cluster state changing.

```bash
make up                       # 10-15 min. Watch kubeadm's output on cp1.
export KUBECONFIG="$PWD/kubeconfig"
kubectl get nodes             # all Ready once Flannel is up
kubectl -n kube-flannel get pods -o wide

make deploy                   # deliberately BEFORE storage
kubectl -n devapp get pvc     # Pending
kubectl -n devapp describe pvc postgres-data | tail -5   # "no storage class"
make storage
kubectl -n devapp get pvc -w  # flips to Bound

kubectl -n devapp get pods    # api pods: ErrImageNeverPull or ImagePullBackOff
make image
kubectl -n devapp rollout restart deployment/api
kubectl -n devapp get pods -w # api pods reach Running, READY 1/1 once /readyz passes

make test
for i in 1 2 3 4; do curl -s 192.168.56.11:30080/healthz; echo; done   # pod name alternates
```

---

## 4. Exercises

Each exercise is designed to break something you can then diagnose with the
troubleshooting table in `CLAUDE.md`.

1. **Persistence.** POST a note, `kubectl -n devapp delete pod postgres-0`, wait, GET notes.
   The note is still there. Then delete the PVC and pod together and confirm it is gone.
2. **Readiness in action.** `kubectl -n devapp scale statefulset/postgres --replicas=0`, then
   `kubectl -n devapp get endpoints api`. The API pods drop out of the endpoints list because
   `/readyz` fails, and `curl` to 30080 gets connection refused rather than a 503. Scale back up.
3. **Scheduling.** `kubectl -n devapp get pods -o wide`. Cordon the node hosting one API pod
   (`kubectl cordon w2`), delete that pod, and watch it land on w1. Uncordon afterwards.
4. **Resource limits.** Lower the API memory limit to `32Mi` in `20-api.yaml`, apply, and watch
   pods get `OOMKilled`. Revert.
5. **Dev loop.** Add a `DELETE /notes/{id}` endpoint in `app/main.py`, `make image`,
   `rollout restart`, and test it through the NodePort.
6. **Add a worker.** Append `w3` at `192.168.56.13` to `NODES`, add it to the loop in
   `load-image.sh`, run `vagrant up w3`. If the join token has expired, regenerate it (see 2.3).
7. **Break networking on purpose.** In a VM, `sudo ip link set enp0s8 down` (or whatever
   `ip -o -4 addr` shows for the 192.168.56 address). Watch the node go `NotReady` and pods
   on it become unreachable. Bring it back up.
8. **Read the control plane.** `vagrant ssh cp1`, then `sudo cat /etc/kubernetes/manifests/kube-apiserver.yaml`.
   Find the `--advertise-address` and `--service-cluster-ip-range` flags and relate them to
   the Vagrantfile and `POD_CIDR`.

---

## 5. Mental model checklist

You have understood the lab when you can answer these without looking:

- Why does `kubectl get nodes` show `NotReady` right after `kubeadm init`?
- Why is the node IP pinned, and what breaks if it is not?
- Why does the Postgres PVC stay `Pending` before `make storage`?
- Why does changing `app/main.py` and running `make image` not change the running pods?
- Why is Postgres a StatefulSet but the API a Deployment?
- Why can you reach the API on w1's IP even when both API pods are on w2?
- What is in `join.sh`, and why does it stop working after a day?

---

## 6. Where to go next

- Replace `ctr import` with a local registry (`registry:2` as a Deployment plus a NodePort) and
  switch the manifest to a versioned tag. Then rolling updates work without `rollout restart`.
- Swap Flannel for Calico to get NetworkPolicy and write a policy that only lets `api` reach `postgres`.
- Move the plaintext Secret to Sealed Secrets or External Secrets.
- Install an Ingress controller (ingress-nginx via NodePort) and expose the API on a hostname.
- Add a second control-plane node and a load balancer to see why HA needs a stable endpoint.
