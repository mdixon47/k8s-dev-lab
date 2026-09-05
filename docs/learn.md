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
│   │ XFCE desktop (opt.) │  │                    │  │            │    │
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
| Console & desktop (optional) | HWE kernel, Guest Additions, XFCE | `scripts/console-kernel.sh`, `scripts/desktop.sh` |

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
  It is backed by the `vboxsf` kernel module from VirtualBox Guest Additions, which matters
  in section 2.7.
- The host-only interface is named `enp0s8` on `ubuntu/jammy64` and `eth1` on the bento
  arm64 box. The scripts never hard-code it; they look up which interface owns `NODE_IP`.
- One node (`DESKTOP_NODE`, default `cp1`) is sized up to 4 GB / 4 CPUs and gets a desktop.
  Three environment variables (`K8S_DESKTOP`, `K8S_CONSOLE_KERNEL`, `K8S_BOX`) tune this
  without editing the file; see the README.

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
| `swapoff -a` + comment the fstab line | kubelet refuses to start with swap on (memory accounting). `swapoff` alone is not enough: swap returns on reboot unless `/etc/fstab` is edited too, and the bento box writes that line tab-separated, so the pattern must match any whitespace |
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

The `--iface` flag is injected into the upstream manifest with `sed`, and the script refuses
to apply the manifest if the flag did not land. That guard exists because upstream once
changed the args from a JSON-style list to a YAML list, the `sed` silently matched nothing,
and the cluster came up *looking* healthy: nodes Ready, Flannel pods Running, but every node
advertised 10.0.2.15 and pods on w1 could not reach CoreDNS on cp1. The tell is
`kubectl get nodes -o custom-columns='NAME:.metadata.name,IP:.metadata.annotations.flannel\.alpha\.coreos\.com/public-ip'`.

**Idempotency.** Both scripts check for an existing cluster (`/etc/kubernetes/admin.conf` on
the control plane, `kubelet.conf` on workers) and skip `kubeadm init`/`join` if present, so
`vagrant provision` can be re-run to refresh Flannel, the kubeconfig copy, or the join token.
Without that check, kubeadm's preflight fails with "Port 6443 is in use" and
"/var/lib/etcd is not empty", which is kubeadm telling you the node is already initialized.

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

### 2.7 Console and desktop (`scripts/console-kernel.sh`, `scripts/desktop.sh`)

This layer is optional for the cluster but a good lesson in how firmware, kernel drivers,
and hypervisor tooling fit together.

**Why the console is blank on the stock kernel.** On Apple Silicon, VirtualBox gives ARM64
guests a very simple display device (QEMU's `ramfb`) and boots them with EFI. Ubuntu 22.04's
5.15 kernel has no driver that can take over that framebuffer after EFI hands off, so the
console window stops at "EFI stub: Exiting boot services" even though the OS is fully up
and SSH works. Inside the guest you can confirm it: there is no `/dev/fb0` and `dmesg` shows
only a dummy console.

**The fix, and what it costs.** Ubuntu's HWE kernel (6.8) ships `simpledrm`, which drives
the EFI-provided framebuffer, so a login prompt appears. Two things break when you change
the kernel, and the script handles both:

1. Guest Additions kernel modules (`vboxsf` for `/vagrant`, `vboxguest` for the clipboard)
   are built per kernel. The script installs the compiler the kernel was built with and
   rebuilds them with `rcvboxadd quicksetup <version>`.
2. Guest Additions 7.2 expects a kernel symbol rename to happen at 6.9, but Ubuntu
   backported it into 6.8. A one-line header patch fixes the build.

Vagrant then reboots the node so the new kernel is running before kubeadm touches it.

**The desktop.** `desktop.sh` installs XFCE, Firefox, and LightDM with auto-login as
`vagrant`, then runs Guest Additions' X11 setup for the shared clipboard. One more trap:
when the VirtualBox window opens it sends a "resize to fit" hint, the Guest Additions
display service tries to honour it, `ramfb` cannot change mode, and the only output is
left *disabled*: a black screen behind a running desktop. The script stops that service at
login and re-enables the output, and the VM is configured not to send the hint at all.

**Try it:** on cp1, `cat /sys/class/drm/card0-*/enabled` and `xrandr` from a desktop
terminal. Then `vagrant ssh cp1` and compare `uname -r` with w1 (both 6.8) against what a
fresh `bento/ubuntu-22.04` box ships (5.15).

---

## 3. Guided walkthrough

Do these in order on a fresh clone and observe the cluster state changing.

```bash
make up                       # 15-20 min. Watch kubeadm's output on cp1 (arm64: each node reboots once).
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

vagrant provision cp1         # safe re-run: "already initialized; skipping kubeadm init"
```

Then open the VirtualBox app, select `k8s-cp1`, click **Show**, and in the desktop:

- Open Firefox at `http://192.168.56.11:30080/docs` and POST a note from the Swagger UI.
- Open a terminal and run `kubectl -n devapp get pods -o wide`; the node has admin access
  through `~/.kube/config`.
- Paste something from your Mac into the terminal to confirm the shared clipboard.

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
7. **Break networking on purpose.** In a VM, `sudo ip link set eth1 down` (`enp0s8` on the
   amd64 box; check `ip -o -4 addr` for the 192.168.56 address). Watch the node go `NotReady` and pods
   on it become unreachable. Bring it back up.
8. **Read the control plane.** `vagrant ssh cp1`, then `sudo cat /etc/kubernetes/manifests/kube-apiserver.yaml`.
   Find the `--advertise-address` and `--service-cluster-ip-range` flags and relate them to
   the Vagrantfile and `POD_CIDR`.
9. **The NAT trap, live.** Remove the pin: `kubectl -n kube-flannel edit ds kube-flannel-ds`
   and delete the `--iface=...` arg. Wait for the Flannel pods to roll, then check the
   `public-ip` annotation on each node (see 2.3) and run
   `kubectl -n devapp run dns --rm -it --image=busybox:1.36 -- nslookup postgres.devapp`.
   Nodes stay Ready while DNS times out. Restore with `vagrant provision cp1`.
10. **Re-provision without fear.** Run `vagrant provision` and read the output: which steps
    say "already ...; skipping", which re-run anyway (apt, Flannel apply, join token), and
    why is that safe? On arm64, watch the nodes reboot and the cluster recover on its own.
11. **Swap on reboot.** On w1, uncomment the `/swap.img` line in `/etc/fstab`, `vagrant reload w1`,
    and read `journalctl -u kubelet`. Fix it by hand, then compare with what `common.sh` does.
12. **Kill the desktop's display.** In a cp1 desktop terminal, `xrandr --output None-1 --off`.
    The window goes black while the session keeps running. Bring it back with
    `xrandr --output None-1 --auto`, then read `/usr/local/bin/vbox-display-fix`.
13. **Power off from the window, on purpose.** Close w2's console window with "Power off".
    Watch `kubectl get nodes` mark it NotReady after about 40 s, see which pods were on it,
    then `vagrant up w2` and watch them come back.

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
- Nodes are Ready and Flannel pods are Running, but pods cannot resolve DNS across nodes.
  What single `kubectl` command exposes the cause?
- Why can `vagrant provision` be re-run on a live cluster, and which two files make that decision?
- Why does the VM console show only EFI messages on the stock kernel while SSH works fine?
- What breaks when you change a VM's kernel, and why does `/vagrant` depend on it?

---

## 6. Where to go next

- Replace `ctr import` with a local registry (`registry:2` as a Deployment plus a NodePort) and
  switch the manifest to a versioned tag. Then rolling updates work without `rollout restart`.
- Swap Flannel for Calico to get NetworkPolicy and write a policy that only lets `api` reach `postgres`.
- Move the plaintext Secret to Sealed Secrets or External Secrets.
- Install an Ingress controller (ingress-nginx via NodePort) and expose the API on a hostname.
- Add a second control-plane node and a load balancer to see why HA needs a stable endpoint.
