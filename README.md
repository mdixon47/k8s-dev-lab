# Kubernetes Dev Lab — VirtualBox + kubeadm + FastAPI/Postgres

A reproducible local development environment: three Ubuntu 22.04 VMs on VirtualBox
form a real kubeadm cluster (1 control plane, 2 workers), and a FastAPI + Postgres
sample app runs on it.

```
Host ──vagrant──▶ cp1  192.168.56.10  (control plane, Flannel CNI)
                  w1   192.168.56.11  (worker)
                  w2   192.168.56.12  (worker)
```

## Prerequisites (host)
- VirtualBox 7.x (7.1+ on Apple Silicon; the Vagrantfile picks an arm64 box automatically)
- `cp1` gets an XFCE desktop with Firefox (4 GB RAM, 4 CPUs) for hands-on learning: open it in the VirtualBox app and click **Show**. Set `K8S_DESKTOP=""` to skip it, or `K8S_DESKTOP=w1` to move it.
  - On Apple Silicon the VMs also get Ubuntu's HWE kernel so the VirtualBox console window works (one extra reboot per node during `make up`). Set `K8S_CONSOLE_KERNEL=0` to skip it.
- Vagrant 2.4+
- Docker (to build the API image)
- kubectl, make, curl
- ~6 GB free RAM, ~20 GB disk

## Quick start
```bash
make up        # provision VMs + cluster (first run pulls packages; 10–15 min)
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
Vagrantfile              VM + node definitions (edit NODES to resize)
scripts/common.sh        containerd, kubeadm, kubelet on every node
scripts/control-plane.sh kubeadm init, Flannel, writes kubeconfig + join.sh
scripts/worker.sh        waits for join.sh, joins the cluster
scripts/load-image.sh    build image on host → import into workers (no registry)
app/                     FastAPI service + Dockerfile
k8s/                     Namespace, Postgres StatefulSet, API Deployment + NodePort
docs/learn.md            Learning guide: concepts, walkthrough, exercises
```

## Notes & gotchas
- kubelet is pinned to `--node-ip` on the host-only NIC (`enp0s8`); VirtualBox's NAT
  interface gives every VM the same 10.0.2.15 address, which breaks pod networking otherwise.
- Flannel is likewise pinned via `--iface` to the interface that owns the node IP
  (`enp0s8` on `ubuntu/jammy64`), resolved during provisioning.
- Credentials in `k8s/10-postgres.yaml` are dev-only. For anything shared, move them
  to a sealed secret or external secrets store.
- To add a worker, append to `NODES` in the Vagrantfile and run `vagrant up <name>`.
