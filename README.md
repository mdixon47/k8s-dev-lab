# Kubernetes Dev Lab — VirtualBox + kubeadm + FastAPI/Postgres

A reproducible local development environment: three Ubuntu 22.04 VMs on VirtualBox
form a real kubeadm cluster (1 control plane, 2 workers), and a FastAPI + Postgres
sample app runs on it. One node also gets a lightweight desktop so you can work
inside the cluster from a VM window.

```
Host ──vagrant──▶ cp1  192.168.56.10  (control plane, Flannel CNI, XFCE desktop)
                  w1   192.168.56.11  (worker)
                  w2   192.168.56.12  (worker)
```

## Prerequisites (host)
- VirtualBox 7.x (7.1+ on Apple Silicon; the Vagrantfile picks an arm64 box automatically)
- Vagrant 2.4+
- Docker (to build the API image)
- kubectl, make, curl
- ~8 GB free RAM (~6 GB without the desktop), ~25 GB disk

## Quick start
```bash
make up        # provision VMs + cluster (first run pulls packages; 15–20 min)
make storage   # default StorageClass for the Postgres PVC
make image     # build devapp/api:dev and import into each worker's containerd
make deploy    # apply k8s/ manifests
make test      # curl the API via NodePort 30080
```

`kubectl` works from the host once the cluster is up:
```bash
export KUBECONFIG="$PWD/kubeconfig"
kubectl get nodes
```

`make up` (and `vagrant provision`) can be re-run safely: the scripts skip `kubeadm init`
and `kubeadm join` on nodes that are already part of the cluster.

## Console and desktop
Open the VirtualBox app, select `k8s-cp1`, and click **Show**. You land in an XFCE
session as `vagrant` (password `vagrant`, passwordless `sudo`) with a terminal, Firefox,
a working `kubectl`, and a clipboard shared with the host. The Swagger UI for the sample
app is at `http://192.168.56.11:30080/docs`.

- Close the window with **Continue running in background**. **Power off** halts the node;
  recover with `vagrant up cp1`.
- The screen is fixed at 1280x800 (VirtualBox's ARM64 display cannot resize).
- The desktop never locks; there is no screensaver password to remember.
- `w1` and `w2` have a text console only: log in as `vagrant` / `vagrant` (the banner
  says so; press Enter if boot messages have scrolled over the prompt, and note the
  password does not echo as you type). `vagrant ssh <node>` is the everyday way in.
- Tunables (environment variables read by the Vagrantfile):

| Variable | Default | Effect |
|----------|---------|--------|
| `K8S_DESKTOP` | `cp1` | Node that gets the desktop, 4 GB RAM and 4 CPUs. `""` for none. |
| `K8S_CONSOLE_KERNEL` | `1` on arm64, `0` otherwise | Install Ubuntu's HWE kernel so the VM console window shows output (one reboot per node during `make up`). Required for the desktop on arm64. |
| `K8S_BOX` | by host arch | Override the Vagrant box. |

## Dev loop
1. Edit `app/main.py`
2. `make image` (rebuild + reload onto workers)
3. `kubectl -n devapp rollout restart deployment/api`

The Postgres `notes` table persists across API restarts via the PVC.
`make clean` tears everything down.

## API
| Method | Path      | Purpose                     |
|--------|-----------|-----------------------------|
| GET    | /healthz  | liveness                    |
| GET    | /readyz   | readiness (checks Postgres) |
| GET    | /notes    | list notes                  |
| POST   | /notes    | create note `{"text": "…"}` |

Swagger UI: `http://192.168.56.11:30080/docs`

## Layout
```
Vagrantfile                VM + node definitions (edit NODES to resize), desktop/console switches
scripts/common.sh          containerd, kubeadm, kubelet on every node
scripts/console-kernel.sh  arm64: HWE kernel + rebuilt Guest Additions so the console works
scripts/control-plane.sh   kubeadm init, Flannel, writes kubeconfig + join.sh (idempotent)
scripts/worker.sh          waits for join.sh, joins the cluster (idempotent)
scripts/desktop.sh         XFCE + Firefox + auto-login on the desktop node
scripts/load-image.sh      build image on host → import into workers (no registry)
app/                       FastAPI service + Dockerfile
k8s/                       Namespace, Postgres StatefulSet, API Deployment + NodePort
docs/learn.md              Learning guide: concepts, walkthrough, exercises
security/                  Security test routines (make sectest); see security/README.md
```

## Security testing
```bash
make sectest                 # all routines: pod specs, runtime probe, RBAC, NetworkPolicy,
                             # secrets in etcd, Trivy, Pod Security Admission, kube-bench, exposure
make sectest ROUTINE=05      # just one
SKIP_SLOW=1 make sectest     # without Trivy and kube-bench
```
The stock lab fails several checks on purpose (plaintext `DATABASE_URL`, no NetworkPolicy
enforcement under Flannel, unencrypted etcd). [security/README.md](security/README.md) explains
each finding and how to fix it. Only ever point these at your own cluster.

## Notes & gotchas
- kubelet is pinned to `--node-ip` on the host-only NIC; VirtualBox's NAT interface gives
  every VM the same 10.0.2.15 address, which breaks pod networking otherwise.
- Flannel is likewise pinned via `--iface` to the interface that owns the node IP
  (`enp0s8` on `ubuntu/jammy64`, `eth1` on `bento/ubuntu-22.04`), resolved during
  provisioning. If every node's `flannel.alpha.coreos.com/public-ip` annotation reads
  10.0.2.15, the pin is missing and cross-node pod traffic (including DNS) fails.
- Credentials in `k8s/10-postgres.yaml` are dev-only. For anything shared, move them
  to a sealed secret or external secrets store.
- To add a worker, append to `NODES` in the Vagrantfile and run `vagrant up <name>`.
- On arm64, a full `vagrant provision` reboots each node (console-kernel step). Provisioners are
  named, so re-run one step without the reboot: `vagrant provision cp1 --provision-with control-plane`
  (others: `hosts`, `console-kernel`, `common`, `worker`, `desktop`).
- Troubleshooting table: see [CLAUDE.md](CLAUDE.md).
